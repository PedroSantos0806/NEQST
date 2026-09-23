-- =====================================================================
-- Stub do ambiente Supabase para testar as migrations num Postgres puro.
-- NÃO faz parte do schema da aplicação — usado apenas por
-- scripts/test-sql.sh e pela CI.
-- =====================================================================

create schema if not exists auth;

create table if not exists auth.users (
  id                  uuid primary key default gen_random_uuid(),
  email               text unique,
  raw_user_meta_data  jsonb default '{}'::jsonb,
  created_at          timestamptz not null default now()
);

-- auth.uid() real lê o JWT; aqui lemos uma GUC que o teste define.
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

do $$ begin create role anon          nologin; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
do $$ begin create role service_role  nologin bypassrls; exception when duplicate_object then null; end $$;

grant usage on schema public to anon, authenticated, service_role;
