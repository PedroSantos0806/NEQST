-- S3.5 · Prospecção de leads frios (Google Places → fila → dossiê por IA → qualificar/descartar).

create type public.prospect_status as enum ('new', 'researching', 'researched', 'qualified', 'discarded');

-- Cada busca feita na tela
create table public.prospect_searches (
  id uuid primary key default gen_random_uuid(),
  query text not null,
  city text not null,
  company_type public.company_type,
  total_found integer not null default 0,
  total_new integer not null default 0,
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Fila de leads frios
create table public.prospects (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  company_type public.company_type,
  address text,
  city text,
  state char(2),
  website text,
  phone text,
  google_place_id text unique,
  google_maps_uri text,
  rating numeric(2, 1),
  rating_count integer,
  raw jsonb not null default '{}'::jsonb,
  status public.prospect_status not null default 'new',
  discard_reason text,
  last_error text,
  search_id uuid references public.prospect_searches (id) on delete set null,
  company_id uuid references public.companies (id) on delete set null,
  deal_id uuid references public.deals (id) on delete set null,
  owner_id uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on column public.prospects.raw is 'Resposta bruta do Google Places para o lugar.';
create index prospects_status_idx on public.prospects (status, created_at desc);
create index prospects_city_idx on public.prospects (city);

-- Dossiê gerado pela IA (pode haver mais de uma versão por lead; vale a mais recente)
create table public.prospect_research (
  id uuid primary key default gen_random_uuid(),
  prospect_id uuid not null references public.prospects (id) on delete cascade,
  summary text,
  hooks jsonb not null default '[]'::jsonb,
  opportunities jsonb not null default '[]'::jsonb,
  decision_makers jsonb not null default '[]'::jsonb,
  estimated_courts integer,
  court_types text[] not null default '{}',
  has_internet_hint text,
  suggested_message text,
  score integer check (score is null or score between 0 and 100),
  score_reason text,
  sources jsonb not null default '[]'::jsonb,
  search_queries jsonb not null default '[]'::jsonb,
  model text,
  created_by uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index prospect_research_prospect_idx on public.prospect_research (prospect_id, created_at desc);

do $$
declare t text;
begin
  foreach t in array array['prospect_searches', 'prospects', 'prospect_research'] loop
    execute format(
      'create trigger %I before update on public.%I for each row execute function public.set_updated_at()',
      t || '_set_updated_at', t
    );
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy %I on public.%I for all to authenticated using (true) with check (true)',
      t || '_authenticated_all', t
    );
  end loop;
end;
$$;

alter publication supabase_realtime add table public.prospects;

-- ---------------------------------------------------------------------------
-- Qualificar: cria (ou usa) a empresa, cria o local, abre o negócio na 1ª etapa do funil,
-- liga o local ao negócio e guarda o dossiê como nota. Tudo numa transação.
-- ---------------------------------------------------------------------------
create or replace function public.qualify_prospect(
  p_prospect_id uuid,
  p_pipeline_id uuid,
  p_company_id uuid default null,
  p_company_type public.company_type default null
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_p public.prospects;
  v_r public.prospect_research;
  v_company uuid := p_company_id;
  v_location uuid;
  v_stage uuid;
  v_deal uuid;
  v_note text;
begin
  select * into v_p from public.prospects where id = p_prospect_id for update;
  if v_p.id is null then
    raise exception 'Lead não encontrado';
  end if;
  if v_p.status = 'qualified' then
    raise exception 'Este lead já foi qualificado';
  end if;

  select * into v_r from public.prospect_research
  where prospect_id = p_prospect_id order by created_at desc limit 1;

  if v_company is null then
    insert into public.companies (name, type, website)
    values (v_p.name, coalesce(p_company_type, v_p.company_type, 'club'), v_p.website)
    returning id into v_company;
  end if;

  insert into public.locations (company_id, name, address, city, state, court_count, surfaces, custom)
  values (
    v_company, v_p.name, v_p.address, v_p.city, v_p.state, v_r.estimated_courts,
    coalesce(v_r.court_types, '{}'),
    jsonb_strip_nulls(jsonb_build_object('google_place_id', v_p.google_place_id, 'google_maps_uri', v_p.google_maps_uri))
  )
  returning id into v_location;

  select s.id into v_stage from public.stages s where s.pipeline_id = p_pipeline_id order by s.sort_order limit 1;
  if v_stage is null then
    raise exception 'Funil sem etapas';
  end if;

  insert into public.deals (pipeline_id, stage_id, title, company_id, court_count)
  values (p_pipeline_id, v_stage, v_p.name, v_company, v_r.estimated_courts)
  returning id into v_deal;

  insert into public.deal_locations (deal_id, location_id) values (v_deal, v_location);

  if v_r.id is not null then
    v_note := concat_ws(E'\n\n',
      'Dossiê da prospecção (IA)',
      v_r.summary,
      case when jsonb_array_length(v_r.hooks) > 0 then
        'Ganchos:' || E'\n' || (select string_agg('• ' || (h ->> 'title') || coalesce(': ' || (h ->> 'detail'), ''), E'\n') from jsonb_array_elements(v_r.hooks) h)
      end,
      case when jsonb_array_length(v_r.opportunities) > 0 then
        'Oportunidades:' || E'\n' || (select string_agg('• ' || (o ->> 'title') || coalesce(': ' || (o ->> 'detail'), ''), E'\n') from jsonb_array_elements(v_r.opportunities) o)
      end,
      case when v_r.suggested_message is not null then 'Mensagem sugerida:' || E'\n' || v_r.suggested_message end
    );
    insert into public.notes (body, deal_id, company_id) values (v_note, v_deal, v_company);
  end if;

  update public.prospects
  set status = 'qualified', company_id = v_company, deal_id = v_deal, last_error = null
  where id = p_prospect_id;

  return v_deal;
end;
$$;
