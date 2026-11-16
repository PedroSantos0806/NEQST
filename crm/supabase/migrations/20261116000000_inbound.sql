-- S4 · Entrada de leads: fila bruta (inbound_events), dedupe/idempotência (external_refs),
-- processamento no banco, tokens dos webhooks no Vault e contato → negócio.

create type public.inbound_source as enum ('meta', 'google', 'site', 'webhook', 'evolution', 'gmail');
create type public.inbound_status as enum ('pending', 'processed', 'failed', 'ignored');

-- ---------------------------------------------------------------------------
-- inbound_events: todo evento externo entra aqui primeiro (payload bruto), depois é processado.
-- ---------------------------------------------------------------------------
create table public.inbound_events (
  id uuid primary key default gen_random_uuid(),
  source public.inbound_source not null,
  external_id text,
  payload jsonb not null,
  normalized jsonb not null default '{}'::jsonb,
  status public.inbound_status not null default 'pending',
  attempts integer not null default 0,
  error text,
  is_test boolean not null default false,
  contact_id uuid references public.contacts (id) on delete set null,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on column public.inbound_events.external_id is 'ID do lead na origem (leadgen_id do Meta, lead_id do Google...). Repetido = mesmo evento.';
comment on column public.inbound_events.normalized is 'Campos já padronizados pela Edge Function: name, email, phone (E.164), company, job_title, city, message, form, campaign, utm_*.';
create unique index inbound_events_source_external_key on public.inbound_events (source, external_id) where external_id is not null;
create index inbound_events_status_idx on public.inbound_events (status, received_at desc);

-- ---------------------------------------------------------------------------
-- external_refs: liga IDs de sistemas externos às nossas entidades (dedupe e idempotência).
-- ---------------------------------------------------------------------------
create table public.external_refs (
  id uuid primary key default gen_random_uuid(),
  entity public.timeline_entity not null,
  entity_id uuid not null,
  system text not null,
  external_id text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (system, external_id)
);
create index external_refs_entity_idx on public.external_refs (entity, entity_id);

create trigger inbound_events_set_updated_at before update on public.inbound_events
  for each row execute function public.set_updated_at();
create trigger external_refs_set_updated_at before update on public.external_refs
  for each row execute function public.set_updated_at();

-- Leitura pelo app; escrita só pelas Edge Functions (service role) e pelas funções abaixo.
alter table public.inbound_events enable row level security;
create policy inbound_events_select on public.inbound_events for select to authenticated using (true);
alter table public.external_refs enable row level security;
create policy external_refs_select on public.external_refs for select to authenticated using (true);

alter publication supabase_realtime add table public.inbound_events;

-- ---------------------------------------------------------------------------
-- Processamento idempotente: dedupe por external_ref → e-mail (minúsculo) → telefone (E.164).
-- Achou → completa campos vazios e registra conversão. Não achou → cria contato `lead`.
-- ---------------------------------------------------------------------------
create or replace function public.process_inbound_event(p_event_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  e public.inbound_events;
  n jsonb;
  v_email text;
  v_phone text;
  v_contact uuid;
  v_created boolean := false;
begin
  select * into e from public.inbound_events where id = p_event_id for update;
  if e.id is null then
    raise exception 'Evento % não encontrado', p_event_id;
  end if;
  if e.status in ('processed', 'ignored') then
    return e.contact_id; -- idempotente
  end if;

  begin
    n := e.normalized;
    v_email := nullif(lower(trim(n ->> 'email')), '');
    v_phone := nullif(trim(n ->> 'phone'), '');
    if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v_email := null; end if;
    if v_phone is not null and v_phone !~ '^\+[1-9]\d{7,14}$' then v_phone := null; end if;

    if v_email is null and v_phone is null then
      raise exception 'Lead sem e-mail nem telefone válidos';
    end if;

    if e.external_id is not null then
      select r.entity_id into v_contact from public.external_refs r
      where r.system = e.source::text and r.external_id = e.external_id and r.entity = 'contact';
    end if;
    if v_contact is null and v_email is not null then
      select c.id into v_contact from public.contacts c where c.email = v_email;
    end if;
    if v_contact is null and v_phone is not null then
      select c.id into v_contact from public.contacts c where c.phone = v_phone;
    end if;

    if v_contact is null then
      insert into public.contacts (
        name, email, phone, job_title, lifecycle_stage, legal_basis, source,
        utm_source, utm_medium, utm_campaign, utm_term, utm_content, meta_lead_id, custom
      ) values (
        coalesce(nullif(trim(n ->> 'name'), ''), v_email, v_phone),
        v_email, v_phone, nullif(trim(n ->> 'job_title'), ''), 'lead',
        'Consentimento (formulário de contato)', e.source::text,
        n ->> 'utm_source', n ->> 'utm_medium', n ->> 'utm_campaign', n ->> 'utm_term', n ->> 'utm_content',
        case when e.source = 'meta' then e.external_id end,
        jsonb_strip_nulls(jsonb_build_object('company_name', nullif(trim(n ->> 'company'), ''), 'city', nullif(trim(n ->> 'city'), '')))
      )
      returning id into v_contact;
      v_created := true;
    else
      -- Completa só o que está vazio; nunca sobrescreve o que o time já preencheu.
      update public.contacts c set
        email = coalesce(c.email, v_email),
        phone = coalesce(c.phone, v_phone),
        job_title = coalesce(c.job_title, nullif(trim(n ->> 'job_title'), '')),
        utm_source = coalesce(c.utm_source, n ->> 'utm_source'),
        utm_medium = coalesce(c.utm_medium, n ->> 'utm_medium'),
        utm_campaign = coalesce(c.utm_campaign, n ->> 'utm_campaign'),
        meta_lead_id = coalesce(c.meta_lead_id, case when e.source = 'meta' then e.external_id end),
        custom = jsonb_strip_nulls(jsonb_build_object('company_name', nullif(trim(n ->> 'company'), ''))) || c.custom
      where c.id = v_contact;
    end if;

    perform public.log_timeline('contact', v_contact, 'conversion', jsonb_strip_nulls(jsonb_build_object(
      'source', e.source,
      'inbound_event_id', e.id,
      'new_contact', v_created,
      'form', n ->> 'form',
      'campaign', n ->> 'campaign',
      'message', n ->> 'message',
      'utm_source', n ->> 'utm_source',
      'utm_campaign', n ->> 'utm_campaign'
    )));

    if e.external_id is not null then
      insert into public.external_refs (entity, entity_id, system, external_id)
      values ('contact', v_contact, e.source::text, e.external_id)
      on conflict (system, external_id) do nothing;
    end if;

    update public.inbound_events
    set status = 'processed', contact_id = v_contact, processed_at = now(), attempts = attempts + 1, error = null
    where id = e.id;
    return v_contact;
  exception when others then
    update public.inbound_events
    set status = 'failed', attempts = attempts + 1, error = sqlerrm
    where id = e.id;
    return null;
  end;
end;
$$;
revoke execute on function public.process_inbound_event(uuid) from public, anon;
grant execute on function public.process_inbound_event(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Contato vira oportunidade → negócio na 1ª etapa do funil escolhido.
-- ---------------------------------------------------------------------------
create or replace function public.create_deal_from_contact(p_contact_id uuid, p_pipeline_id uuid)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  c public.contacts;
  v_company_name text;
  v_stage uuid;
  v_deal uuid;
begin
  select * into c from public.contacts where id = p_contact_id;
  if c.id is null then
    raise exception 'Contato não encontrado';
  end if;

  select s.id into v_stage from public.stages s where s.pipeline_id = p_pipeline_id order by s.sort_order limit 1;
  if v_stage is null then
    raise exception 'Funil sem etapas';
  end if;

  select co.name into v_company_name from public.companies co where co.id = c.company_id;

  insert into public.deals (pipeline_id, stage_id, title, company_id)
  values (p_pipeline_id, v_stage, coalesce(v_company_name, c.custom ->> 'company_name', c.name), c.company_id)
  returning id into v_deal;

  insert into public.deal_contacts (deal_id, contact_id) values (v_deal, c.id);

  update public.contacts set lifecycle_stage = 'opportunity'
  where id = c.id and lifecycle_stage in ('lead', 'qualified_lead');

  return v_deal;
end;
$$;

-- ---------------------------------------------------------------------------
-- Tokens dos webhooks: gerados aleatoriamente no próprio banco e guardados no Vault.
-- ---------------------------------------------------------------------------
do $$
declare
  s record;
begin
  for s in
    select * from (values
      ('inbound_site_token', 'Token do header x-neqst-token (formulário do site / webhook genérico)'),
      ('inbound_google_key', 'google_key configurada no formulário de lead do Google Ads'),
      ('inbound_meta_verify_token', 'Verify token do webhook do Meta (hub.verify_token)')
    ) as t(name, description)
  loop
    if not exists (select 1 from vault.secrets where name = s.name) then
      perform vault.create_secret(encode(extensions.gen_random_bytes(24), 'hex'), s.name, s.description);
    end if;
  end loop;
end;
$$;

-- Só as Edge Functions (service role) leem os tokens para validar as chamadas.
create or replace function public.inbound_secret(p_name text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select ds.decrypted_secret from vault.decrypted_secrets ds where ds.name = 'inbound_' || p_name;
$$;
revoke execute on function public.inbound_secret(text) from public, anon, authenticated;
grant execute on function public.inbound_secret(text) to service_role;

-- Admin vê os tokens na tela de configuração (para colar no site, Google Ads e Meta).
create or replace function public.inbound_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin') then
    raise exception 'Só administradores veem os tokens de integração' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'site_token', public.inbound_secret('site_token'),
    'google_key', public.inbound_secret('google_key'),
    'meta_verify_token', public.inbound_secret('meta_verify_token')
  );
end;
$$;
revoke execute on function public.inbound_settings() from public, anon;
grant execute on function public.inbound_settings() to authenticated;

-- Primeiro usuário do time vira admin, se ainda não houver nenhum.
update public.profiles set role = 'admin'
where id = (select id from public.profiles order by created_at limit 1)
  and not exists (select 1 from public.profiles where role = 'admin');
