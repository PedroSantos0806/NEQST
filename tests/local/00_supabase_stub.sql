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

-- Esqueleto do schema storage, para as migrations que criam bucket e
-- policy serem executadas também nos testes — sem isso esse trecho de
-- SQL só rodaria direto em produção.
create schema if not exists storage;

create table if not exists storage.buckets (
  id                  text primary key,
  name                text not null,
  public              boolean not null default false,
  file_size_limit     bigint,
  allowed_mime_types  text[],
  created_at          timestamptz not null default now()
);

create table if not exists storage.objects (
  id          uuid primary key default gen_random_uuid(),
  bucket_id   text references storage.buckets (id) on delete cascade,
  name        text not null,
  owner       uuid,
  metadata    jsonb,
  created_at  timestamptz not null default now()
);

alter table storage.objects enable row level security;

do $$ begin create role anon          nologin; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
do $$ begin create role service_role  nologin bypassrls; exception when duplicate_object then null; end $$;

grant usage on schema public, storage to anon, authenticated, service_role;
