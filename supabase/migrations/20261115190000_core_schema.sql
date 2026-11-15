-- S1 · Schema core do NEQST CRM
-- Tabelas: profiles, companies, locations, contacts, pipelines, stages, lost_reasons,
-- deals, deal_locations, deal_contacts, activities, notes, timeline_events, custom_fields.
-- Integrações (inbound_events, external_refs, e-mail, webhooks) entram na S4+.

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type public.app_role as enum ('admin', 'member');
create type public.company_type as enum ('public_operator', 'club', 'condo', 'builder', 'brand');
create type public.location_status as enum ('prospect', 'pilot', 'client');
create type public.lifecycle_stage as enum ('lead', 'qualified_lead', 'opportunity', 'customer');
create type public.pipeline_type as enum ('sales', 'onboarding');
create type public.deal_status as enum ('open', 'won', 'lost');
create type public.deal_contact_role as enum ('decision_maker', 'influencer', 'operational');
create type public.activity_type as enum ('task', 'call', 'meeting', 'visit', 'whatsapp', 'email');
create type public.timeline_entity as enum ('deal', 'contact', 'company', 'location');
create type public.timeline_event_type as enum (
  'created', 'stage_change', 'status_change', 'note', 'activity_done', 'conversion',
  'whatsapp_in', 'whatsapp_out', 'email_out', 'email_in'
);
create type public.custom_field_type as enum ('text', 'number', 'date', 'boolean', 'select', 'multiselect');

-- ---------------------------------------------------------------------------
-- profiles (time interno; 1:1 com auth.users)
-- ---------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text,
  avatar_url text,
  role public.app_role not null default 'member',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Cria o profile quando o usuário entra pela primeira vez (convite, link mágico ou Google).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name, avatar_url)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'),
    new.raw_user_meta_data ->> 'avatar_url'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Usuários que já existiam antes desta migration.
insert into public.profiles (id, full_name, avatar_url)
select u.id,
       coalesce(u.raw_user_meta_data ->> 'full_name', u.raw_user_meta_data ->> 'name'),
       u.raw_user_meta_data ->> 'avatar_url'
from auth.users u
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- companies
-- ---------------------------------------------------------------------------
create table public.companies (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  type public.company_type not null,
  cnpj text unique check (cnpj is null or cnpj ~ '^\d{14}$'),
  website text,
  owner_id uuid references public.profiles (id) on delete set null,
  custom jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on column public.companies.cnpj is 'Só dígitos (14).';

-- ---------------------------------------------------------------------------
-- locations (parque/unidade; um operador tem vários)
-- ---------------------------------------------------------------------------
create table public.locations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  name text not null check (length(trim(name)) > 0),
  address text,
  city text,
  state char(2),
  court_count integer check (court_count is null or court_count >= 0),
  surfaces text[] not null default '{}',
  has_internet boolean,
  status public.location_status not null default 'prospect',
  custom jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index locations_company_id_idx on public.locations (company_id);

-- ---------------------------------------------------------------------------
-- contacts (lead e contato são a mesma coisa)
-- ---------------------------------------------------------------------------
create table public.contacts (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  email text check (email is null or email = lower(trim(email))),
  phone text check (phone is null or phone ~ '^\+[1-9]\d{7,14}$'),
  company_id uuid references public.companies (id) on delete set null,
  job_title text,
  lifecycle_stage public.lifecycle_stage not null default 'lead',
  legal_basis text,
  source text,
  utm_source text,
  utm_medium text,
  utm_campaign text,
  utm_term text,
  utm_content text,
  meta_lead_id text unique,
  owner_id uuid references public.profiles (id) on delete set null,
  custom jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on column public.contacts.email is 'Sempre minúsculo (dedupe).';
comment on column public.contacts.phone is 'E.164, ex.: +5511999999999 (dedupe e vínculo com WhatsApp).';
create unique index contacts_email_key on public.contacts (email) where email is not null;
create unique index contacts_phone_key on public.contacts (phone) where phone is not null;
create index contacts_company_id_idx on public.contacts (company_id);

create or replace function public.normalize_contact()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.email := nullif(lower(trim(new.email)), '');
  new.phone := nullif(regexp_replace(coalesce(new.phone, ''), '[^\d+]', '', 'g'), '');
  return new;
end;
$$;

create trigger contacts_normalize
  before insert or update of email, phone on public.contacts
  for each row execute function public.normalize_contact();

-- ---------------------------------------------------------------------------
-- pipelines e stages
-- ---------------------------------------------------------------------------
create table public.pipelines (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  sort_order integer not null,
  type public.pipeline_type not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.stages (
  id uuid primary key default gen_random_uuid(),
  pipeline_id uuid not null references public.pipelines (id) on delete cascade,
  name text not null,
  sort_order integer not null,
  probability integer check (probability is null or probability between 0 and 100),
  alert_days integer check (alert_days is null or alert_days > 0),
  required_fields jsonb not null default '[]'::jsonb check (jsonb_typeof(required_fields) = 'array'),
  exit_criteria text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (pipeline_id, name),
  unique (id, pipeline_id)
);
create index stages_pipeline_id_idx on public.stages (pipeline_id, sort_order);

create table public.lost_reasons (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  sort_order integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- deals
-- ---------------------------------------------------------------------------
create table public.deals (
  id uuid primary key default gen_random_uuid(),
  pipeline_id uuid not null references public.pipelines (id),
  stage_id uuid not null,
  position numeric not null default 0,
  title text not null check (length(trim(title)) > 0),
  company_id uuid references public.companies (id) on delete set null,
  value numeric(12, 2) check (value is null or value >= 0),
  court_count integer check (court_count is null or court_count >= 0),
  price_per_court numeric(12, 2) check (price_per_court is null or price_per_court >= 0),
  expected_close_date date,
  owner_id uuid references public.profiles (id) on delete set null,
  status public.deal_status not null default 'open',
  lost_reason_id uuid references public.lost_reasons (id),
  lost_note text,
  closed_at timestamptz,
  stage_entered_at timestamptz not null default now(),
  source_deal_id uuid references public.deals (id) on delete set null,
  custom jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- etapa precisa pertencer ao funil do negócio
  foreign key (stage_id, pipeline_id) references public.stages (id, pipeline_id),
  constraint deals_lost_requires_reason check (status <> 'lost' or lost_reason_id is not null)
);
comment on column public.deals.value is 'BRL. Calculado como court_count × price_per_court × 12 quando os dois estão preenchidos.';
comment on column public.deals.source_deal_id is 'Negócio de venda que originou este negócio de Implantação.';
create index deals_board_idx on public.deals (pipeline_id, stage_id, position);
create index deals_company_id_idx on public.deals (company_id);
create unique index deals_one_onboarding_per_source on public.deals (source_deal_id) where source_deal_id is not null;

create table public.deal_locations (
  id uuid primary key default gen_random_uuid(),
  deal_id uuid not null references public.deals (id) on delete cascade,
  location_id uuid not null references public.locations (id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (deal_id, location_id)
);
create index deal_locations_location_id_idx on public.deal_locations (location_id);

create table public.deal_contacts (
  id uuid primary key default gen_random_uuid(),
  deal_id uuid not null references public.deals (id) on delete cascade,
  contact_id uuid not null references public.contacts (id) on delete cascade,
  role public.deal_contact_role,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (deal_id, contact_id)
);
create index deal_contacts_contact_id_idx on public.deal_contacts (contact_id);

-- ---------------------------------------------------------------------------
-- activities e notes
-- ---------------------------------------------------------------------------
create table public.activities (
  id uuid primary key default gen_random_uuid(),
  type public.activity_type not null default 'task',
  title text not null check (length(trim(title)) > 0),
  description text,
  due_at timestamptz,
  done_at timestamptz,
  deal_id uuid references public.deals (id) on delete cascade,
  contact_id uuid references public.contacts (id) on delete set null,
  company_id uuid references public.companies (id) on delete set null,
  owner_id uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index activities_deal_id_idx on public.activities (deal_id);
create index activities_owner_open_idx on public.activities (owner_id, due_at) where done_at is null;

create table public.notes (
  id uuid primary key default gen_random_uuid(),
  body text not null check (length(trim(body)) > 0),
  deal_id uuid references public.deals (id) on delete cascade,
  contact_id uuid references public.contacts (id) on delete cascade,
  company_id uuid references public.companies (id) on delete cascade,
  author_id uuid references public.profiles (id) on delete set null default auth.uid(),
  attachments jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint notes_has_target check (num_nonnulls(deal_id, contact_id, company_id) >= 1)
);
create index notes_deal_id_idx on public.notes (deal_id);
create index notes_contact_id_idx on public.notes (contact_id);
create index notes_company_id_idx on public.notes (company_id);

-- ---------------------------------------------------------------------------
-- timeline_events (histórico único; só triggers escrevem)
-- ---------------------------------------------------------------------------
create table public.timeline_events (
  id uuid primary key default gen_random_uuid(),
  entity public.timeline_entity not null,
  entity_id uuid not null,
  type public.timeline_event_type not null,
  payload jsonb not null default '{}'::jsonb,
  actor_id uuid references public.profiles (id) on delete set null,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index timeline_events_entity_idx on public.timeline_events (entity, entity_id, occurred_at desc);
create index timeline_events_type_idx on public.timeline_events (type, occurred_at);

create or replace function public.log_timeline(
  p_entity public.timeline_entity,
  p_entity_id uuid,
  p_type public.timeline_event_type,
  p_payload jsonb default '{}'::jsonb
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.timeline_events (entity, entity_id, type, payload, actor_id)
  values (
    p_entity, p_entity_id, p_type, coalesce(p_payload, '{}'::jsonb),
    (select p.id from public.profiles p where p.id = auth.uid())
  );
$$;
revoke execute on function public.log_timeline(public.timeline_entity, uuid, public.timeline_event_type, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- custom_fields (definição; valor fica em <entidade>.custom)
-- ---------------------------------------------------------------------------
create table public.custom_fields (
  id uuid primary key default gen_random_uuid(),
  entity public.timeline_entity not null,
  key text not null check (key ~ '^[a-z][a-z0-9_]*$'),
  label text not null,
  field_type public.custom_field_type not null default 'text',
  options jsonb not null default '[]'::jsonb,
  group_name text,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (entity, key)
);

-- ---------------------------------------------------------------------------
-- updated_at em toda tabela
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'profiles', 'companies', 'locations', 'contacts', 'pipelines', 'stages', 'lost_reasons',
    'deals', 'deal_locations', 'deal_contacts', 'activities', 'notes', 'timeline_events', 'custom_fields'
  ] loop
    execute format(
      'create trigger %I before update on public.%I for each row execute function public.set_updated_at()',
      t || '_set_updated_at', t
    );
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- Regras de negócio: deals
-- ---------------------------------------------------------------------------
create or replace function public.deals_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Valor = nº de quadras × preço por quadra × 12 (quando os dois existem)
  if new.court_count is not null and new.price_per_court is not null then
    new.value := round(new.court_count * new.price_per_court * 12, 2);
  end if;

  if tg_op = 'INSERT' then
    new.stage_entered_at := coalesce(new.stage_entered_at, now());
    -- Sem posição informada: vai para o fim da coluna
    if new.position is null or new.position = 0 then
      select coalesce(max(d.position), 0) + 1000 into new.position
      from public.deals d where d.stage_id = new.stage_id;
    end if;
  else
    if new.stage_id is distinct from old.stage_id then
      new.stage_entered_at := now();
    end if;
  end if;

  if new.status = 'open' then
    new.closed_at := null;
    new.lost_reason_id := null;
    new.lost_note := null;
  elsif tg_op = 'INSERT' or new.status is distinct from old.status then
    new.closed_at := now();
  end if;
  if new.status = 'won' then
    new.lost_reason_id := null;
  end if;

  return new;
end;
$$;

create trigger deals_before_write
  before insert or update on public.deals
  for each row execute function public.deals_before_write();

-- Ganho num funil de venda → cria negócio no funil de Implantação, etapa "Contrato assinado".
create or replace function public.create_onboarding_deal(p_source public.deals)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pipeline uuid;
  v_stage uuid;
  v_new uuid;
begin
  if exists (select 1 from public.deals d where d.source_deal_id = p_source.id) then
    return; -- idempotente
  end if;

  select p.id into v_pipeline from public.pipelines p where p.type = 'onboarding' order by p.sort_order limit 1;
  if v_pipeline is null then
    return;
  end if;
  select s.id into v_stage from public.stages s
  where s.pipeline_id = v_pipeline
  order by (s.name = 'Contrato assinado') desc, s.sort_order
  limit 1;
  if v_stage is null then
    return;
  end if;

  insert into public.deals (pipeline_id, stage_id, title, company_id, court_count, price_per_court, value,
                            owner_id, source_deal_id)
  values (v_pipeline, v_stage, p_source.title, p_source.company_id, p_source.court_count,
          p_source.price_per_court, p_source.value, p_source.owner_id, p_source.id)
  returning id into v_new;

  insert into public.deal_locations (deal_id, location_id)
  select v_new, dl.location_id from public.deal_locations dl where dl.deal_id = p_source.id;

  insert into public.deal_contacts (deal_id, contact_id, role)
  select v_new, dc.contact_id, dc.role from public.deal_contacts dc where dc.deal_id = p_source.id;
end;
$$;
revoke execute on function public.create_onboarding_deal(public.deals) from public, anon, authenticated;

create or replace function public.deals_after_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pipeline_type public.pipeline_type;
begin
  if tg_op = 'INSERT' then
    perform public.log_timeline('deal', new.id, 'created',
      jsonb_build_object('pipeline_id', new.pipeline_id, 'stage_id', new.stage_id, 'title', new.title,
                         'source_deal_id', new.source_deal_id));
  else
    if new.stage_id is distinct from old.stage_id then
      perform public.log_timeline('deal', new.id, 'stage_change',
        jsonb_build_object('pipeline_id', new.pipeline_id,
                           'from_pipeline_id', old.pipeline_id,
                           'from_stage_id', old.stage_id,
                           'to_stage_id', new.stage_id,
                           'days_in_stage', extract(epoch from (now() - old.stage_entered_at)) / 86400));
    end if;
    if new.status is distinct from old.status then
      perform public.log_timeline('deal', new.id, 'status_change',
        jsonb_build_object('from', old.status, 'to', new.status, 'stage_id', new.stage_id,
                           'lost_reason_id', new.lost_reason_id, 'lost_note', new.lost_note,
                           'value', new.value));
    end if;
  end if;

  if new.status = 'won' and (tg_op = 'INSERT' or old.status is distinct from 'won') then
    select p.type into v_pipeline_type from public.pipelines p where p.id = new.pipeline_id;
    if v_pipeline_type = 'sales' then
      perform public.create_onboarding_deal(new);
    end if;
  end if;

  return null;
end;
$$;

create trigger deals_after_write
  after insert or update on public.deals
  for each row execute function public.deals_after_write();

-- ---------------------------------------------------------------------------
-- Regras de negócio: atividades herdam contato e empresa do negócio
-- ---------------------------------------------------------------------------
create or replace function public.activities_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.deal_id is not null then
    if new.company_id is null then
      select d.company_id into new.company_id from public.deals d where d.id = new.deal_id;
    end if;
    if new.contact_id is null then
      select dc.contact_id into new.contact_id
      from public.deal_contacts dc
      where dc.deal_id = new.deal_id
      order by (dc.role = 'decision_maker') desc nulls last, dc.created_at
      limit 1;
    end if;
  end if;
  return new;
end;
$$;

create trigger activities_before_write
  before insert or update of deal_id on public.activities
  for each row execute function public.activities_before_write();

create or replace function public.activities_after_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb;
begin
  if new.done_at is not null and (tg_op = 'INSERT' or old.done_at is null) then
    v_payload := jsonb_build_object('activity_id', new.id, 'type', new.type, 'title', new.title);
    if new.deal_id is not null then
      perform public.log_timeline('deal', new.deal_id, 'activity_done', v_payload);
    end if;
    if new.contact_id is not null then
      perform public.log_timeline('contact', new.contact_id, 'activity_done', v_payload);
    end if;
    if new.deal_id is null and new.contact_id is null and new.company_id is not null then
      perform public.log_timeline('company', new.company_id, 'activity_done', v_payload);
    end if;
  end if;
  return null;
end;
$$;

create trigger activities_after_write
  after insert or update of done_at on public.activities
  for each row execute function public.activities_after_write();

-- ---------------------------------------------------------------------------
-- Timeline: criação de empresa/contato/local e notas
-- ---------------------------------------------------------------------------
create or replace function public.log_created()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.log_timeline(tg_argv[0]::public.timeline_entity, new.id, 'created',
    jsonb_build_object('name', new.name));
  return null;
end;
$$;

create trigger companies_log_created after insert on public.companies
  for each row execute function public.log_created('company');
create trigger contacts_log_created after insert on public.contacts
  for each row execute function public.log_created('contact');
create trigger locations_log_created after insert on public.locations
  for each row execute function public.log_created('location');

create or replace function public.notes_after_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb := jsonb_build_object('note_id', new.id, 'excerpt', left(new.body, 280));
begin
  if new.deal_id is not null then
    perform public.log_timeline('deal', new.deal_id, 'note', v_payload);
  end if;
  if new.contact_id is not null then
    perform public.log_timeline('contact', new.contact_id, 'note', v_payload);
  end if;
  if new.company_id is not null then
    perform public.log_timeline('company', new.company_id, 'note', v_payload);
  end if;
  return null;
end;
$$;

create trigger notes_after_insert
  after insert on public.notes
  for each row execute function public.notes_after_insert();
