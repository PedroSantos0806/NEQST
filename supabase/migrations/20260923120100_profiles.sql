-- =====================================================================
-- NEQST — Sprint 1
-- 01. Perfis de usuário  (US-01 — Criação de conta e login)
--
-- A autenticação (e-mail+senha, Google SSO, Apple SSO, reset de senha)
-- é delegada ao Supabase Auth. Esta tabela guarda apenas o perfil
-- público do jogador, criado automaticamente a cada novo auth.users.
-- =====================================================================

create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  username    extensions.citext unique,
  full_name   text,
  email       extensions.citext,
  avatar_url  text,
  role        public.app_role not null default 'player',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  constraint profiles_username_format
    check (username is null or username ~ '^[a-zA-Z0-9._]{3,30}$'),
  constraint profiles_full_name_length
    check (full_name is null or char_length(full_name) between 1 and 120)
);

comment on table  public.profiles is 'Perfil público do jogador (1:1 com auth.users).';
comment on column public.profiles.username is '@username único usado para convidar o parceiro de dupla (US-03).';
comment on column public.profiles.role is 'player = jogador; staff = operador da quadra; admin = gestão total.';

create index if not exists profiles_username_trgm_idx
  on public.profiles using gin (username extensions.gin_trgm_ops);

create index if not exists profiles_email_idx on public.profiles (email);

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------
-- Geração de username único a partir do e-mail / nome
-- ---------------------------------------------------------------------
create or replace function public.generate_unique_username(p_seed text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_base      text;
  v_candidate text;
  v_suffix    integer := 0;
begin
  v_base := lower(regexp_replace(coalesce(p_seed, ''), '[^a-zA-Z0-9._]', '', 'g'));

  if char_length(v_base) < 3 then
    v_base := 'player' || v_base;
  end if;

  v_base      := left(v_base, 24);
  v_candidate := v_base;

  while exists (select 1 from public.profiles p where p.username = v_candidate::extensions.citext) loop
    v_suffix    := v_suffix + 1;
    v_candidate := left(v_base, 24) || v_suffix::text;
  end loop;

  return v_candidate;
end;
$$;

-- ---------------------------------------------------------------------
-- Criação automática do perfil no signup (e-mail/senha, Google, Apple)
-- ---------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_meta      jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_full_name text;
  v_avatar    text;
  v_seed      text;
begin
  v_full_name := nullif(trim(coalesce(
    v_meta ->> 'full_name',
    v_meta ->> 'name',
    concat_ws(' ', v_meta ->> 'given_name', v_meta ->> 'family_name')
  )), '');

  v_avatar := nullif(coalesce(v_meta ->> 'avatar_url', v_meta ->> 'picture'), '');

  v_seed := coalesce(
    nullif(v_meta ->> 'username', ''),
    split_part(coalesce(new.email, ''), '@', 1),
    replace(lower(coalesce(v_full_name, '')), ' ', ''),
    'player'
  );

  insert into public.profiles (id, username, full_name, email, avatar_url)
  values (
    new.id,
    public.generate_unique_username(v_seed),
    v_full_name,
    new.email,
    v_avatar
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Mantém e-mail do perfil sincronizado quando o usuário troca de e-mail.
create or replace function public.handle_user_email_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.email is distinct from old.email then
    update public.profiles set email = new.email where id = new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_email_updated on auth.users;
create trigger on_auth_user_email_updated
  after update of email on auth.users
  for each row execute function public.handle_user_email_change();

-- ---------------------------------------------------------------------
-- Helpers de autorização usados pelas policies de RLS
-- ---------------------------------------------------------------------
create or replace function public.current_app_role()
returns public.app_role
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select p.role from public.profiles p where p.id = auth.uid()),
    'player'::public.app_role
  );
$$;

create or replace function public.is_staff()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.current_app_role() in ('staff'::public.app_role, 'admin'::public.app_role);
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.current_app_role() = 'admin'::public.app_role;
$$;
