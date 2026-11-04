-- =====================================================================
-- NEQST — script único de criação do banco (Sprint 1)
--
-- GERADO AUTOMATICAMENTE por scripts/build-full-setup.sh.
-- Não edite este arquivo: altere supabase/migrations/*.sql e rode o
-- script novamente.
--
-- Como usar:
--   Supabase Dashboard > SQL Editor > New query > cole tudo > Run.
--   Ou:  psql "$DATABASE_URL" -f db/full_setup.sql
--
-- É idempotente: pode ser executado mais de uma vez no mesmo projeto.
-- =====================================================================



-- ####################################################################
-- Origem: supabase/migrations/20260923120000_extensions_and_enums.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 1
-- 00. Extensões, schemas auxiliares e tipos enumerados
-- =====================================================================

create schema if not exists extensions;

create extension if not exists pgcrypto  with schema extensions;
create extension if not exists citext     with schema extensions;
create extension if not exists pg_trgm    with schema extensions;

-- ---------------------------------------------------------------------
-- Tipos enumerados
-- ---------------------------------------------------------------------

-- Papel do usuário dentro do produto.
do $$ begin
  create type public.app_role as enum ('player', 'staff', 'admin');
exception when duplicate_object then null; end $$;

-- Status operacional da quadra (US-04).
do $$ begin
  create type public.court_status as enum ('available', 'in_game', 'unavailable');
exception when duplicate_object then null; end $$;

-- Modalidade da entrada na fila (US-03).
do $$ begin
  create type public.queue_mode as enum ('single', 'double');
exception when duplicate_object then null; end $$;

-- Ciclo de vida de um time na fila:
--   waiting   -> aguardando na fila
--   ready     -> chamado ("Prepare-se!" / próximo a entrar)
--   playing   -> em quadra
--   done      -> partida encerrada
--   cancelled -> saiu da fila por vontade própria
--   expired   -> removido por inatividade / não compareceu
do $$ begin
  create type public.queue_entry_status as enum
    ('waiting', 'ready', 'playing', 'done', 'cancelled', 'expired');
exception when duplicate_object then null; end $$;

-- Papel do jogador dentro de um time da fila.
do $$ begin
  create type public.queue_member_role as enum ('owner', 'partner');
exception when duplicate_object then null; end $$;

-- Tipos de notificação push emitidos pelo backend.
do $$ begin
  create type public.notification_type as enum
    ('queue_almost_ready', 'queue_turn', 'queue_cancelled', 'queue_partner_added');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.notification_status as enum ('pending', 'sent', 'failed');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- Função utilitária: updated_at automático
-- ---------------------------------------------------------------------
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

comment on function public.set_updated_at() is
  'Trigger BEFORE UPDATE: mantém a coluna updated_at sempre sincronizada.';


-- ####################################################################
-- Origem: supabase/migrations/20260923120100_profiles.sql
-- ####################################################################

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


-- ####################################################################
-- Origem: supabase/migrations/20260923120200_courts.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 1
-- 02. Quadras + geolocalização  (US-02 / US-04)
-- =====================================================================

create table if not exists public.courts (
  id                      uuid primary key default gen_random_uuid(),
  slug                    extensions.citext not null unique,
  name                    text not null,
  description             text,
  address                 text,
  city                    text,
  latitude                double precision not null check (latitude between -90 and 90),
  longitude               double precision not null check (longitude between -180 and 180),
  status                  public.court_status not null default 'available',
  is_active               boolean not null default true,

  -- Regras de proximidade (US-02)
  max_distance_meters     integer not null default 1000 check (max_distance_meters between 10 and 20000),
  gps_tolerance_meters    integer not null default 200  check (gps_tolerance_meters between 0 and 2000),

  -- Base para o tempo estimado de espera (US-03)
  average_match_minutes   integer not null default 20 check (average_match_minutes between 1 and 240),

  -- Versão do segredo usado para assinar o QR Code impresso (US-02)
  qr_secret_version       integer not null default 1 check (qr_secret_version > 0),
  qr_rotated_at           timestamptz,

  opens_at                time,
  closes_at               time,
  photo_url               text,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),

  constraint courts_name_length check (char_length(name) between 2 and 120),
  constraint courts_slug_format check (slug ~ '^[a-z0-9-]{3,60}$')
);

comment on table  public.courts is 'Quadras de tênis atendidas pelo app.';
comment on column public.courts.max_distance_meters is
  'Raio máximo (US-02: 1 km) dentro do qual o jogador pode entrar na fila.';
comment on column public.courts.gps_tolerance_meters is
  'Margem extra (US-02: +200 m) aplicada quando o GPS reporta baixa precisão.';
comment on column public.courts.qr_secret_version is
  'Permite rotacionar o segredo de assinatura sem reimprimir todos os QR Codes de uma vez.';

create index if not exists courts_active_status_idx on public.courts (is_active, status);
create index if not exists courts_latlng_idx        on public.courts (latitude, longitude);

drop trigger if exists courts_set_updated_at on public.courts;
create trigger courts_set_updated_at
  before update on public.courts
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------
-- Distância Haversine em metros (US-02)
-- ---------------------------------------------------------------------
create or replace function public.haversine_meters(
  p_lat1 double precision,
  p_lng1 double precision,
  p_lat2 double precision,
  p_lng2 double precision
)
returns double precision
language sql
immutable
parallel safe
set search_path = ''
as $$
  select 2 * 6371000 * asin(
    sqrt(
      power(sin(radians(p_lat2 - p_lat1) / 2), 2) +
      cos(radians(p_lat1)) * cos(radians(p_lat2)) *
      power(sin(radians(p_lng2 - p_lng1) / 2), 2)
    )
  );
$$;

comment on function public.haversine_meters is
  'Distância ortodrômica em metros entre dois pontos (raio médio da Terra = 6.371.000 m).';

-- ---------------------------------------------------------------------
-- Raio efetivo aceito para uma quadra, considerando a precisão do GPS
-- ---------------------------------------------------------------------
create or replace function public.court_allowed_radius_meters(
  p_court_id        uuid,
  p_accuracy_meters double precision default null
)
returns double precision
language sql
stable
set search_path = ''
as $$
  select c.max_distance_meters
       + least(coalesce(p_accuracy_meters, 0), c.gps_tolerance_meters)
  from public.courts c
  where c.id = p_court_id;
$$;


-- ####################################################################
-- Origem: supabase/migrations/20260923120300_scan_tokens.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 1
-- 03. Tokens de escaneamento  (US-02)
--
-- O QR Code impresso na quadra é estático e assinado (HMAC-SHA256).
-- O "timeout de 30s" do critério de aceite é implementado como um
-- token de escaneamento de uso único, emitido pela Edge Function
-- `scan-court` somente após validar assinatura + proximidade. Sem esse
-- token, `join_queue` recusa a entrada — o que impede reuso offline de
-- uma foto do QR Code tirada longe da quadra.
-- =====================================================================

create table if not exists public.scan_tokens (
  id               uuid primary key default gen_random_uuid(),
  token_hash       text not null unique,
  user_id          uuid not null references auth.users (id) on delete cascade,
  court_id         uuid not null references public.courts (id) on delete cascade,
  latitude         double precision not null,
  longitude        double precision not null,
  accuracy_meters  double precision,
  distance_meters  double precision not null,
  expires_at       timestamptz not null,
  consumed_at      timestamptz,
  consumed_by_entry uuid,
  created_at       timestamptz not null default now()
);

comment on table  public.scan_tokens is
  'Prova de presença de uso único (TTL padrão 30s) emitida após validar QR Code + distância.';
comment on column public.scan_tokens.token_hash is
  'SHA-256 hex do token. O valor em claro só existe na resposta HTTP e no device.';

create index if not exists scan_tokens_user_idx    on public.scan_tokens (user_id, created_at desc);
create index if not exists scan_tokens_expiry_idx  on public.scan_tokens (expires_at) where consumed_at is null;

-- ---------------------------------------------------------------------
-- Hash determinístico do token (mesmo algoritmo usado na Edge Function)
-- ---------------------------------------------------------------------
create or replace function public.hash_scan_token(p_token text)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
$$;

-- ---------------------------------------------------------------------
-- Limpeza de tokens vencidos (chamada por cron / Edge Function)
-- ---------------------------------------------------------------------
create or replace function public.purge_expired_scan_tokens(p_older_than interval default '1 day')
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_deleted integer;
begin
  delete from public.scan_tokens
  where created_at < now() - p_older_than;
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;


-- ####################################################################
-- Origem: supabase/migrations/20260923120400_queue.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 1
-- 04. Fila da quadra — individual e duplas  (US-03)
-- =====================================================================

create table if not exists public.queue_entries (
  id                 uuid primary key default gen_random_uuid(),

  -- Ordem de chegada. Uma sequência, e não joined_at: now() é constante
  -- dentro de uma transação, o que empataria dois times e deixaria a
  -- posição na fila indefinida.
  queue_number       bigint generated always as identity,

  court_id           uuid not null references public.courts (id) on delete cascade,
  mode               public.queue_mode not null default 'single',
  status             public.queue_entry_status not null default 'waiting',
  created_by         uuid not null references auth.users (id) on delete cascade,
  scan_token_id      uuid references public.scan_tokens (id) on delete set null,

  joined_at          timestamptz not null default clock_timestamp(),
  ready_notified_at  timestamptz,
  called_at          timestamptz,
  started_at         timestamptz,
  ended_at           timestamptz,
  left_at            timestamptz,
  cancel_reason      text,

  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

comment on table  public.queue_entries is 'Um time (individual ou dupla) na fila de uma quadra.';
comment on column public.queue_entries.queue_number is
  'Ordem de chegada global, estritamente crescente. Define a posição na fila.';
comment on column public.queue_entries.ready_notified_at is
  'Marca o envio do push "Prepare-se!" para evitar notificação duplicada.';

-- Uma única partida em andamento por quadra.
create unique index if not exists queue_entries_one_playing_per_court
  on public.queue_entries (court_id)
  where status = 'playing';

create index if not exists queue_entries_active_idx
  on public.queue_entries (court_id, queue_number)
  where status in ('waiting', 'ready');

create index if not exists queue_entries_court_status_idx on public.queue_entries (court_id, status);
create index if not exists queue_entries_created_by_idx   on public.queue_entries (created_by, queue_number desc);

drop trigger if exists queue_entries_set_updated_at on public.queue_entries;
create trigger queue_entries_set_updated_at
  before update on public.queue_entries
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------
-- Integrantes do time
-- ---------------------------------------------------------------------
create table if not exists public.queue_entry_members (
  id          uuid primary key default gen_random_uuid(),
  entry_id    uuid not null references public.queue_entries (id) on delete cascade,
  court_id    uuid not null references public.courts (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  role        public.queue_member_role not null default 'owner',
  is_active   boolean not null default true,
  created_at  timestamptz not null default clock_timestamp(),

  unique (entry_id, user_id)
);

comment on table public.queue_entry_members is
  'Jogadores de um time. Individual = 1 linha; dupla = 2 linhas (owner + partner).';
comment on column public.queue_entry_members.court_id is
  'Desnormalizado para permitir o índice único "um time ativo por jogador por quadra".';

-- Um jogador não pode estar em dois times ativos da mesma quadra.
create unique index if not exists queue_entry_members_one_active_per_court
  on public.queue_entry_members (court_id, user_id)
  where is_active;

create index if not exists queue_entry_members_entry_idx on public.queue_entry_members (entry_id);
create index if not exists queue_entry_members_user_idx  on public.queue_entry_members (user_id) where is_active;

-- ---------------------------------------------------------------------
-- Consistência: duplas têm exatamente 2 jogadores, individual tem 1
-- ---------------------------------------------------------------------
create or replace function public.enforce_queue_team_size()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_entry_id uuid := coalesce(new.entry_id, old.entry_id);
  v_mode     public.queue_mode;
  v_count    integer;
begin
  select e.mode into v_mode from public.queue_entries e where e.id = v_entry_id;
  if v_mode is null then
    return coalesce(new, old);
  end if;

  select count(*) into v_count
  from public.queue_entry_members m
  where m.entry_id = v_entry_id;

  if v_mode = 'single' and v_count > 1 then
    raise exception 'Fila individual aceita apenas 1 jogador' using errcode = 'check_violation';
  end if;

  if v_mode = 'double' and v_count > 2 then
    raise exception 'Fila de duplas aceita no máximo 2 jogadores' using errcode = 'check_violation';
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists queue_entry_members_team_size on public.queue_entry_members;
create constraint trigger queue_entry_members_team_size
  after insert or update on public.queue_entry_members
  deferrable initially deferred
  for each row execute function public.enforce_queue_team_size();

-- ---------------------------------------------------------------------
-- Ao encerrar um time, libera seus jogadores para novas filas
-- ---------------------------------------------------------------------
create or replace function public.sync_queue_member_activity()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status in ('done', 'cancelled', 'expired')
     and old.status not in ('done', 'cancelled', 'expired') then
    update public.queue_entry_members
       set is_active = false
     where entry_id = new.id and is_active;
  end if;
  return new;
end;
$$;

drop trigger if exists queue_entries_sync_members on public.queue_entries;
create trigger queue_entries_sync_members
  after update of status on public.queue_entries
  for each row execute function public.sync_queue_member_activity();

-- ---------------------------------------------------------------------
-- View de posições (posição 1 = próximo a jogar)
-- ---------------------------------------------------------------------
-- Recriada do zero: create or replace não aceita mudança na lista de colunas.
drop view if exists public.queue_positions;

create view public.queue_positions
with (security_invoker = true) as
select
  e.id        as entry_id,
  e.court_id,
  e.mode,
  e.status,
  e.joined_at,
  e.queue_number,
  row_number() over (partition by e.court_id order by e.queue_number) as position,
  (
    select count(*)
    from public.queue_entries p
    where p.court_id = e.court_id and p.status = 'playing'
  ) as playing_count
from public.queue_entries e
where e.status in ('waiting', 'ready');

comment on view public.queue_positions is
  'Posição de cada time aguardando, por ordem de chegada (queue_number). '
  'teams_ahead = position - 1 + (1 se houver partida em andamento).';


-- ####################################################################
-- Origem: supabase/migrations/20260923120500_push_notifications.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 1
-- 05. Push notifications  (US-03 — "Prepare-se!")
--
-- O banco apenas enfileira a notificação (outbox). O envio efetivo é
-- feito pela Edge Function `dispatch-notifications`, que fala com a
-- Expo Push API (FCM no Android + APNs no iOS).
-- =====================================================================

create table if not exists public.push_tokens (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  token         text not null unique,
  platform      text not null check (platform in ('ios', 'android', 'web')),
  device_name   text,
  is_active     boolean not null default true,
  last_seen_at  timestamptz not null default now(),
  created_at    timestamptz not null default now(),

  constraint push_tokens_expo_format
    check (token ~ '^(ExponentPushToken\[.+\]|ExpoPushToken\[.+\])$')
);

comment on table public.push_tokens is 'Tokens Expo Push por device. Um usuário pode ter vários.';

create index if not exists push_tokens_user_idx on public.push_tokens (user_id) where is_active;

-- ---------------------------------------------------------------------
-- Outbox de notificações
-- ---------------------------------------------------------------------
create table if not exists public.notification_outbox (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users (id) on delete cascade,
  entry_id       uuid references public.queue_entries (id) on delete cascade,
  court_id       uuid references public.courts (id) on delete cascade,
  type           public.notification_type not null,
  title          text not null,
  body           text not null,
  data           jsonb not null default '{}'::jsonb,
  status         public.notification_status not null default 'pending',
  attempts       integer not null default 0,
  last_error     text,
  scheduled_for  timestamptz not null default now(),
  sent_at        timestamptz,
  created_at     timestamptz not null default now()
);

comment on table public.notification_outbox is
  'Fila de pushes a enviar. Garante entrega mesmo se a Edge Function estiver indisponível no momento do evento.';

create index if not exists notification_outbox_pending_idx
  on public.notification_outbox (scheduled_for)
  where status = 'pending';

create index if not exists notification_outbox_user_idx
  on public.notification_outbox (user_id, created_at desc);

-- Evita duplicar o mesmo aviso para o mesmo time.
create unique index if not exists notification_outbox_unique_event
  on public.notification_outbox (entry_id, user_id, type)
  where entry_id is not null;

-- ---------------------------------------------------------------------
-- Enfileira uma notificação para todos os jogadores de um time
-- ---------------------------------------------------------------------
create or replace function public.enqueue_team_notification(
  p_entry_id uuid,
  p_type     public.notification_type,
  p_title    text,
  p_body     text,
  p_data     jsonb default '{}'::jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inserted integer;
begin
  insert into public.notification_outbox (user_id, entry_id, court_id, type, title, body, data)
  select m.user_id, m.entry_id, m.court_id, p_type, p_title, p_body, p_data
  from public.queue_entry_members m
  where m.entry_id = p_entry_id
  on conflict do nothing;

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;


-- ####################################################################
-- Origem: supabase/migrations/20260923120600_queue_functions.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 1
-- 06. Regras de negócio da fila (RPC)  (US-02 / US-03 / US-04)
--
-- Toda escrita na fila acontece por estas funções. As tabelas ficam
-- sem INSERT/UPDATE/DELETE para o cliente (ver migration 07), de forma
-- que nenhuma regra (presença validada, 1 time por jogador, ordem da
-- fila) possa ser burlada pelo app.
--
-- Códigos de erro (SQLSTATE) devolvidos ao cliente:
--   NQ001 usuário não autenticado
--   NQ002 token de escaneamento inválido, expirado ou já usado
--   NQ003 quadra inativa ou indisponível
--   NQ004 jogador já está na fila desta quadra
--   NQ005 parceiro não encontrado
--   NQ006 parceiro inválido (você mesmo / já está na fila)
--   NQ007 time não encontrado
--   NQ008 operação não permitida para este usuário
--   NQ009 transição de status inválida
-- =====================================================================

-- ---------------------------------------------------------------------
-- Estado detalhado da fila de uma quadra (US-03 / US-04)
-- ---------------------------------------------------------------------
create or replace function public.court_queue(p_court_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_court    public.courts%rowtype;
  v_playing  jsonb;
  v_teams    jsonb;
  v_elapsed  integer := 0;
  v_remaining integer := 0;
  v_waiting  integer;
begin
  select * into v_court from public.courts c where c.id = p_court_id;
  if not found then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;

  select
    jsonb_build_object(
      'entry_id',   e.id,
      'mode',       e.mode,
      'started_at', e.started_at,
      'players',    public.queue_entry_players(e.id)
    ),
    greatest(0, floor(extract(epoch from (now() - coalesce(e.started_at, now()))) / 60))::integer
  into v_playing, v_elapsed
  from public.queue_entries e
  where e.court_id = p_court_id and e.status = 'playing'
  limit 1;

  v_remaining := greatest(v_court.average_match_minutes - coalesce(v_elapsed, 0), 0);

  select count(*)::integer into v_waiting
  from public.queue_entries e
  where e.court_id = p_court_id and e.status in ('waiting', 'ready');

  select coalesce(jsonb_agg(s.t order by s.position), '[]'::jsonb)
  into v_teams
  from (
    select qp.position, jsonb_build_object(
      'entry_id',                 qp.entry_id,
      'mode',                     qp.mode,
      'status',                   qp.status,
      'joined_at',                qp.joined_at,
      'position',                 qp.position,
      'teams_ahead',              (qp.position - 1) + qp.playing_count,
      'estimated_wait_minutes',   case
                                    when (qp.position - 1) = 0 and qp.playing_count = 0 then 0
                                    else (qp.position - 1) * v_court.average_match_minutes
                                         + (qp.playing_count * v_remaining)
                                  end,
      'players',                  public.queue_entry_players(qp.entry_id)
    ) as t
    from public.queue_positions qp
    where qp.court_id = p_court_id
  ) s;

  return jsonb_build_object(
    'court', jsonb_build_object(
      'id',                     v_court.id,
      'slug',                   v_court.slug,
      'name',                   v_court.name,
      'address',                v_court.address,
      'status',                 v_court.status,
      'is_active',              v_court.is_active,
      'latitude',               v_court.latitude,
      'longitude',              v_court.longitude,
      'average_match_minutes',  v_court.average_match_minutes,
      'photo_url',              v_court.photo_url
    ),
    'can_join',            v_court.is_active and v_court.status <> 'unavailable',
    'teams_waiting',       v_waiting,
    'current_match',       v_playing,
    'current_match_remaining_minutes', case when v_playing is null then null else v_remaining end,
    'queue',               v_teams,
    'generated_at',        now()
  );
end;
$$;

-- Jogadores de um time, em formato público.
create or replace function public.queue_entry_players(p_entry_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'user_id',   m.user_id,
        'role',      m.role,
        'username',  p.username,
        'full_name', p.full_name,
        'avatar_url', p.avatar_url
      )
      order by m.role, m.created_at
    ),
    '[]'::jsonb
  )
  from public.queue_entry_members m
  left join public.profiles p on p.id = m.user_id
  where m.entry_id = p_entry_id;
$$;

-- ---------------------------------------------------------------------
-- Quadras próximas (home do app)
-- ---------------------------------------------------------------------
create or replace function public.nearby_courts(
  p_latitude      double precision,
  p_longitude     double precision,
  p_radius_meters double precision default 5000,
  p_limit         integer default 20
)
returns table (
  id              uuid,
  slug            text,
  name            text,
  address         text,
  status          public.court_status,
  latitude        double precision,
  longitude       double precision,
  distance_meters double precision,
  teams_waiting   integer
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    c.id,
    c.slug::text,
    c.name,
    c.address,
    c.status,
    c.latitude,
    c.longitude,
    public.haversine_meters(p_latitude, p_longitude, c.latitude, c.longitude),
    (select count(*)::integer
       from public.queue_entries q
      where q.court_id = c.id and q.status in ('waiting', 'ready'))
  from public.courts c
  where c.is_active
    and public.haversine_meters(p_latitude, p_longitude, c.latitude, c.longitude) <= p_radius_meters
  order by 8
  limit greatest(coalesce(p_limit, 20), 1);
$$;

-- ---------------------------------------------------------------------
-- Entrar na fila  (US-03)
-- ---------------------------------------------------------------------
create or replace function public.join_queue(
  p_scan_token text,
  p_mode       public.queue_mode default 'single',
  p_partner    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user       uuid := auth.uid();
  v_token      public.scan_tokens%rowtype;
  v_court      public.courts%rowtype;
  v_partner_id uuid;
  v_entry_id   uuid;
  v_needle     text;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  -- 1. Prova de presença (QR Code + geolocalização validados na Edge Function)
  select * into v_token
  from public.scan_tokens t
  where t.token_hash = public.hash_scan_token(p_scan_token)
  for update;

  if not found
     or v_token.user_id <> v_user
     or v_token.consumed_at is not null
     or v_token.expires_at <= now() then
    raise exception 'Escaneie o QR Code da quadra novamente para entrar na fila'
      using errcode = 'NQ002';
  end if;

  -- 2. Quadra disponível
  select * into v_court from public.courts c where c.id = v_token.court_id for update;

  if not found or not v_court.is_active or v_court.status = 'unavailable' then
    raise exception 'Esta quadra está indisponível no momento' using errcode = 'NQ003';
  end if;

  -- 3. Jogador ainda não está na fila desta quadra
  if exists (
    select 1 from public.queue_entry_members m
    where m.court_id = v_court.id and m.user_id = v_user and m.is_active
  ) then
    raise exception 'Você já está na fila desta quadra' using errcode = 'NQ004';
  end if;

  -- 4. Parceiro de dupla
  if p_mode = 'double' then
    v_needle := lower(trim(coalesce(p_partner, '')));
    v_needle := regexp_replace(v_needle, '^@', '');

    if v_needle = '' then
      raise exception 'Informe o @username ou e-mail do parceiro' using errcode = 'NQ005';
    end if;

    select p.id into v_partner_id
    from public.profiles p
    where p.username = v_needle::extensions.citext
       or p.email    = v_needle::extensions.citext
    limit 1;

    if v_partner_id is null then
      raise exception 'Parceiro não encontrado: %', p_partner using errcode = 'NQ005';
    end if;

    if v_partner_id = v_user then
      raise exception 'Escolha outro jogador como parceiro' using errcode = 'NQ006';
    end if;

    if exists (
      select 1 from public.queue_entry_members m
      where m.court_id = v_court.id and m.user_id = v_partner_id and m.is_active
    ) then
      raise exception 'Seu parceiro já está em outro time nesta quadra' using errcode = 'NQ006';
    end if;
  end if;

  -- 5. Cria o time
  insert into public.queue_entries (court_id, mode, created_by, scan_token_id)
  values (v_court.id, p_mode, v_user, v_token.id)
  returning id into v_entry_id;

  insert into public.queue_entry_members (entry_id, court_id, user_id, role)
  values (v_entry_id, v_court.id, v_user, 'owner');

  if v_partner_id is not null then
    insert into public.queue_entry_members (entry_id, court_id, user_id, role)
    values (v_entry_id, v_court.id, v_partner_id, 'partner');

    perform public.enqueue_team_notification(
      v_entry_id,
      'queue_partner_added',
      'Você entrou numa dupla',
      format('Você foi adicionado a um time na quadra %s.', v_court.name),
      jsonb_build_object('court_id', v_court.id, 'entry_id', v_entry_id)
    );
  end if;

  -- 6. Consome o token (uso único)
  update public.scan_tokens
     set consumed_at = now(), consumed_by_entry = v_entry_id
   where id = v_token.id;

  return public.queue_entry_state(v_entry_id);
end;
$$;

-- ---------------------------------------------------------------------
-- Estado de um time específico (posição, tempo estimado)
-- ---------------------------------------------------------------------
create or replace function public.queue_entry_state(p_entry_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_entry       public.queue_entries%rowtype;
  v_court       public.courts%rowtype;
  v_position    integer;
  v_playing     integer := 0;
  v_teams_ahead integer;
  v_elapsed     integer := 0;
  v_remaining   integer := 0;
begin
  select * into v_entry from public.queue_entries e where e.id = p_entry_id;
  if not found then
    raise exception 'Time não encontrado' using errcode = 'NQ007';
  end if;

  select * into v_court from public.courts c where c.id = v_entry.court_id;

  select qp.position::integer, qp.playing_count::integer
  into v_position, v_playing
  from public.queue_positions qp
  where qp.entry_id = p_entry_id;

  select greatest(0, floor(extract(epoch from (now() - e.started_at)) / 60))::integer
  into v_elapsed
  from public.queue_entries e
  where e.court_id = v_entry.court_id and e.status = 'playing'
  limit 1;

  v_remaining   := greatest(v_court.average_match_minutes - coalesce(v_elapsed, 0), 0);
  v_teams_ahead := case
                     when v_position is null then null
                     else (v_position - 1) + coalesce(v_playing, 0)
                   end;

  return jsonb_build_object(
    'entry_id',    v_entry.id,
    'court_id',    v_entry.court_id,
    'court_name',  v_court.name,
    'mode',        v_entry.mode,
    'status',      v_entry.status,
    'joined_at',   v_entry.joined_at,
    'started_at',  v_entry.started_at,
    'position',    v_position,
    'teams_ahead', v_teams_ahead,
    'estimated_wait_minutes', case
      when v_teams_ahead is null then null
      when v_teams_ahead = 0 then 0
      else greatest(v_teams_ahead - coalesce(v_playing, 0), 0) * v_court.average_match_minutes
           + coalesce(v_playing, 0) * v_remaining
    end,
    'players',     public.queue_entry_players(v_entry.id)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Time ativo do usuário logado (reconexão após queda de rede — US-03)
-- ---------------------------------------------------------------------
create or replace function public.my_active_entries()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(public.queue_entry_state(m.entry_id)), '[]'::jsonb)
  from public.queue_entry_members m
  where m.user_id = auth.uid() and m.is_active;
$$;

-- ---------------------------------------------------------------------
-- Sair da fila  (US-03 — qualquer integrante pode desfazer o time)
-- ---------------------------------------------------------------------
create or replace function public.leave_queue(
  p_entry_id uuid,
  p_reason   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user  uuid := auth.uid();
  v_entry public.queue_entries%rowtype;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  select * into v_entry from public.queue_entries e where e.id = p_entry_id for update;
  if not found then
    raise exception 'Time não encontrado' using errcode = 'NQ007';
  end if;

  if not exists (
    select 1 from public.queue_entry_members m
    where m.entry_id = p_entry_id and m.user_id = v_user
  ) and not public.is_staff() then
    raise exception 'Você não faz parte deste time' using errcode = 'NQ008';
  end if;

  if v_entry.status not in ('waiting', 'ready') then
    raise exception 'Este time não está mais na fila' using errcode = 'NQ009';
  end if;

  update public.queue_entries
     set status        = 'cancelled',
         left_at       = now(),
         cancel_reason = coalesce(p_reason, 'left_by_user')
   where id = p_entry_id;

  return jsonb_build_object('entry_id', p_entry_id, 'status', 'cancelled', 'left_at', now());
end;
$$;

-- ---------------------------------------------------------------------
-- Operação da quadra (staff/admin): iniciar e encerrar partidas
-- ---------------------------------------------------------------------
create or replace function public.start_match(p_entry_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry public.queue_entries%rowtype;
begin
  if not public.is_staff() then
    raise exception 'Apenas a operação da quadra pode iniciar partidas' using errcode = 'NQ008';
  end if;

  select * into v_entry from public.queue_entries e where e.id = p_entry_id for update;
  if not found then
    raise exception 'Time não encontrado' using errcode = 'NQ007';
  end if;

  if v_entry.status not in ('waiting', 'ready') then
    raise exception 'Este time não pode iniciar uma partida agora' using errcode = 'NQ009';
  end if;

  update public.queue_entries
     set status     = 'playing',
         called_at  = coalesce(called_at, now()),
         started_at = now()
   where id = p_entry_id;

  update public.courts set status = 'in_game'::public.court_status where id = v_entry.court_id;

  return public.queue_entry_state(p_entry_id);
end;
$$;

create or replace function public.finish_match(p_entry_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry public.queue_entries%rowtype;
begin
  if not public.is_staff() then
    raise exception 'Apenas a operação da quadra pode encerrar partidas' using errcode = 'NQ008';
  end if;

  select * into v_entry from public.queue_entries e where e.id = p_entry_id for update;
  if not found then
    raise exception 'Time não encontrado' using errcode = 'NQ007';
  end if;

  if v_entry.status <> 'playing' then
    raise exception 'Este time não está em quadra' using errcode = 'NQ009';
  end if;

  update public.queue_entries
     set status = 'done', ended_at = now()
   where id = p_entry_id;

  update public.courts
     set status = case
                    when status = 'unavailable' then 'unavailable'::public.court_status
                    else 'available'::public.court_status
                  end
   where id = v_entry.court_id;

  return jsonb_build_object('entry_id', p_entry_id, 'status', 'done', 'ended_at', now());
end;
$$;

-- Atalho: encerra a partida atual e coloca o próximo time em quadra.
create or replace function public.call_next(p_court_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current uuid;
  v_next    uuid;
begin
  if not public.is_staff() then
    raise exception 'Apenas a operação da quadra pode chamar o próximo time' using errcode = 'NQ008';
  end if;

  select e.id into v_current
  from public.queue_entries e
  where e.court_id = p_court_id and e.status = 'playing'
  limit 1;

  if v_current is not null then
    perform public.finish_match(v_current);
  end if;

  select qp.entry_id into v_next
  from public.queue_positions qp
  where qp.court_id = p_court_id
  order by qp.position
  limit 1;

  if v_next is null then
    return jsonb_build_object('court_id', p_court_id, 'next_entry', null,
                              'message', 'Não há times na fila');
  end if;

  return public.start_match(v_next);
end;
$$;

-- ---------------------------------------------------------------------
-- Expira times que não compareceram
-- ---------------------------------------------------------------------
create or replace function public.expire_stale_queue_entries(p_max_wait interval default '3 hours')
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  update public.queue_entries
     set status = 'expired', cancel_reason = 'expired_by_system', left_at = now()
   where status in ('waiting', 'ready')
     and joined_at < now() - p_max_wait;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------
-- Gatilho de notificações: "Prepare-se!" e "É a sua vez!"
-- ---------------------------------------------------------------------
create or replace function public.refresh_queue_notifications(p_court_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court    public.courts%rowtype;
  v_row      record;
  v_ahead    integer;
  v_inserted integer;
begin
  select * into v_court from public.courts c where c.id = p_court_id;
  if not found then
    return;
  end if;

  -- A deduplicação real é feita pelo índice único
  -- notification_outbox_unique_event (entry_id, user_id, type): a função
  -- pode rodar várias vezes por evento sem gerar push repetido, e um
  -- parceiro adicionado depois ainda recebe o aviso.
  for v_row in
    select qp.entry_id, qp.position, qp.playing_count, e.ready_notified_at
    from public.queue_positions qp
    join public.queue_entries e on e.id = qp.entry_id
    where qp.court_id = p_court_id and qp.position <= 2
  loop
    v_ahead := (v_row.position - 1) + v_row.playing_count;

    if v_ahead = 1 then
      v_inserted := public.enqueue_team_notification(
        v_row.entry_id,
        'queue_almost_ready',
        'Prepare-se!',
        format('Falta 1 time para a sua vez na quadra %s.', v_court.name),
        jsonb_build_object('court_id', p_court_id, 'entry_id', v_row.entry_id, 'teams_ahead', 1)
      );

      if v_inserted > 0 and v_row.ready_notified_at is null then
        update public.queue_entries set ready_notified_at = now() where id = v_row.entry_id;
      end if;
    end if;

    if v_ahead = 0 then
      perform public.enqueue_team_notification(
        v_row.entry_id,
        'queue_turn',
        'É a sua vez!',
        format('A quadra %s está liberada para o seu time.', v_court.name),
        jsonb_build_object('court_id', p_court_id, 'entry_id', v_row.entry_id, 'teams_ahead', 0)
      );
    end if;
  end loop;
end;
$$;

create or replace function public.queue_entries_notify_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if pg_trigger_depth() <= 1 then
    perform public.refresh_queue_notifications(coalesce(new.court_id, old.court_id));
  end if;
  return coalesce(new, old);
end;
$$;

drop trigger if exists queue_entries_notify on public.queue_entries;
create trigger queue_entries_notify
  after insert or update of status or delete on public.queue_entries
  for each row execute function public.queue_entries_notify_trigger();

-- Um time só existe de fato depois que seus jogadores entram. Este
-- gatilho garante que o push saia com o time já formado — inclusive
-- para o parceiro de dupla, inserido logo após o dono.
drop trigger if exists queue_members_notify on public.queue_entry_members;
create trigger queue_members_notify
  after insert on public.queue_entry_members
  for each row execute function public.queue_entries_notify_trigger();


-- ####################################################################
-- Origem: supabase/migrations/20260923120700_rls_policies.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 1
-- 07. Row Level Security + permissões
--
-- Princípio: leitura direta pelas tabelas (o app usa Realtime), escrita
-- somente via RPC SECURITY DEFINER da migration 06.
-- =====================================================================

alter table public.profiles            enable row level security;
alter table public.courts              enable row level security;
alter table public.scan_tokens         enable row level security;
alter table public.queue_entries       enable row level security;
alter table public.queue_entry_members enable row level security;
alter table public.push_tokens         enable row level security;
alter table public.notification_outbox enable row level security;

-- ---------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------
drop policy if exists "profiles: leitura autenticada" on public.profiles;
create policy "profiles: leitura autenticada"
  on public.profiles for select
  to authenticated
  using (true);

drop policy if exists "profiles: dono atualiza" on public.profiles;
create policy "profiles: dono atualiza"
  on public.profiles for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid() and role = public.current_app_role());

drop policy if exists "profiles: admin gerencia" on public.profiles;
create policy "profiles: admin gerencia"
  on public.profiles for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ---------------------------------------------------------------------
-- courts — leitura pública (a home do app funciona antes do login)
-- ---------------------------------------------------------------------
drop policy if exists "courts: leitura pública" on public.courts;
create policy "courts: leitura pública"
  on public.courts for select
  to anon, authenticated
  using (is_active or public.is_staff());

drop policy if exists "courts: staff atualiza status" on public.courts;
create policy "courts: staff atualiza status"
  on public.courts for update
  to authenticated
  using (public.is_staff())
  with check (public.is_staff());

drop policy if exists "courts: admin gerencia" on public.courts;
create policy "courts: admin gerencia"
  on public.courts for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ---------------------------------------------------------------------
-- scan_tokens — o dono vê os próprios; ninguém escreve pelo cliente
-- ---------------------------------------------------------------------
drop policy if exists "scan_tokens: dono lê" on public.scan_tokens;
create policy "scan_tokens: dono lê"
  on public.scan_tokens for select
  to authenticated
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------
-- queue_entries / members — a fila é visível para quem está autenticado
-- ---------------------------------------------------------------------
drop policy if exists "queue_entries: leitura autenticada" on public.queue_entries;
create policy "queue_entries: leitura autenticada"
  on public.queue_entries for select
  to authenticated
  using (true);

drop policy if exists "queue_members: leitura autenticada" on public.queue_entry_members;
create policy "queue_members: leitura autenticada"
  on public.queue_entry_members for select
  to authenticated
  using (true);

drop policy if exists "queue_entries: staff gerencia" on public.queue_entries;
create policy "queue_entries: staff gerencia"
  on public.queue_entries for update
  to authenticated
  using (public.is_staff())
  with check (public.is_staff());

-- ---------------------------------------------------------------------
-- push_tokens — cada jogador gerencia os próprios devices
-- ---------------------------------------------------------------------
drop policy if exists "push_tokens: dono lê" on public.push_tokens;
create policy "push_tokens: dono lê"
  on public.push_tokens for select
  to authenticated
  using (user_id = auth.uid());

drop policy if exists "push_tokens: dono registra" on public.push_tokens;
create policy "push_tokens: dono registra"
  on public.push_tokens for insert
  to authenticated
  with check (user_id = auth.uid());

drop policy if exists "push_tokens: dono atualiza" on public.push_tokens;
create policy "push_tokens: dono atualiza"
  on public.push_tokens for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists "push_tokens: dono remove" on public.push_tokens;
create policy "push_tokens: dono remove"
  on public.push_tokens for delete
  to authenticated
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------
-- notification_outbox — leitura apenas do próprio histórico
-- ---------------------------------------------------------------------
drop policy if exists "notifications: dono lê" on public.notification_outbox;
create policy "notifications: dono lê"
  on public.notification_outbox for select
  to authenticated
  using (user_id = auth.uid());

-- =====================================================================
-- Permissões de tabela: nenhuma escrita direta na fila
-- =====================================================================
revoke all on public.queue_entries       from anon, authenticated;
revoke all on public.queue_entry_members from anon, authenticated;
revoke all on public.scan_tokens         from anon, authenticated;
revoke all on public.notification_outbox from anon, authenticated;
revoke all on public.courts              from anon, authenticated;
revoke all on public.profiles            from anon, authenticated;
revoke all on public.push_tokens         from anon, authenticated;

grant select on public.queue_entries       to authenticated;
grant select on public.queue_entry_members to authenticated;
grant select on public.queue_positions     to authenticated;
grant select on public.scan_tokens         to authenticated;
grant select on public.notification_outbox to authenticated;
grant select on public.courts              to anon, authenticated;
grant select, update on public.profiles    to authenticated;
grant select, insert, update, delete on public.push_tokens to authenticated;

-- =====================================================================
-- Execução das RPCs
-- =====================================================================
revoke all on function public.join_queue(text, public.queue_mode, text)        from public;
revoke all on function public.leave_queue(uuid, text)                          from public;
revoke all on function public.start_match(uuid)                                from public;
revoke all on function public.finish_match(uuid)                               from public;
revoke all on function public.call_next(uuid)                                  from public;
revoke all on function public.expire_stale_queue_entries(interval)             from public;
revoke all on function public.purge_expired_scan_tokens(interval)              from public;
revoke all on function public.refresh_queue_notifications(uuid)                from public;
revoke all on function public.enqueue_team_notification(uuid, public.notification_type, text, text, jsonb) from public;
revoke all on function public.generate_unique_username(text)                   from public;

grant execute on function public.join_queue(text, public.queue_mode, text)  to authenticated;
grant execute on function public.leave_queue(uuid, text)                    to authenticated;
grant execute on function public.start_match(uuid)                          to authenticated;
grant execute on function public.finish_match(uuid)                         to authenticated;
grant execute on function public.call_next(uuid)                            to authenticated;
grant execute on function public.court_queue(uuid)                          to anon, authenticated;
grant execute on function public.queue_entry_state(uuid)                    to authenticated;
grant execute on function public.queue_entry_players(uuid)                  to anon, authenticated;
grant execute on function public.my_active_entries()                        to authenticated;
grant execute on function public.nearby_courts(double precision, double precision, double precision, integer)
  to anon, authenticated;
grant execute on function public.haversine_meters(double precision, double precision, double precision, double precision)
  to anon, authenticated;
grant execute on function public.court_allowed_radius_meters(uuid, double precision) to authenticated;
grant execute on function public.current_app_role() to authenticated;
grant execute on function public.is_staff()         to authenticated;
grant execute on function public.is_admin()         to authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20260923120800_realtime.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 1
-- 08. Realtime (WebSocket) — fila em tempo real  (US-03 / US-04)
--
-- O app assina `queue_entries` e `courts` filtrando por court_id.
-- Isso substitui o polling de 10s citado no critério de aceite.
-- =====================================================================

alter table public.queue_entries       replica identity full;
alter table public.queue_entry_members replica identity full;
alter table public.courts              replica identity full;

do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'queue_entries'
  ) then
    alter publication supabase_realtime add table public.queue_entries;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'queue_entry_members'
  ) then
    alter publication supabase_realtime add table public.queue_entry_members;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'courts'
  ) then
    alter publication supabase_realtime add table public.courts;
  end if;
end $$;


-- ####################################################################
-- Origem: supabase/migrations/20260923120900_jobs.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 1
-- 09. Rotinas de manutenção e suporte ao worker de push
-- =====================================================================

-- Usada pela Edge Function `dispatch-notifications` quando um envio falha.
create or replace function public.increment_notification_attempts(
  p_ids   uuid[],
  p_error text default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  update public.notification_outbox
     set attempts   = attempts + 1,
         last_error = left(coalesce(p_error, ''), 500),
         status     = case when attempts + 1 >= 5 then 'failed'::public.notification_status
                           else 'pending'::public.notification_status end,
         -- backoff exponencial simples: 10s, 20s, 40s, 80s
         scheduled_for = now() + make_interval(secs => least(10 * power(2, attempts)::integer, 300))
   where id = any(p_ids);

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.increment_notification_attempts(uuid[], text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Rotina de manutenção agregada (chamada por cron)
-- ---------------------------------------------------------------------
create or replace function public.run_maintenance()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_expired integer;
  v_purged  integer;
begin
  v_expired := public.expire_stale_queue_entries();
  v_purged  := public.purge_expired_scan_tokens();

  delete from public.notification_outbox
  where status in ('sent', 'failed') and created_at < now() - interval '30 days';

  return jsonb_build_object(
    'expired_entries', v_expired,
    'purged_scan_tokens', v_purged,
    'ran_at', now()
  );
end;
$$;

revoke all on function public.run_maintenance() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Agendamento (opcional — requer pg_cron habilitado no projeto Supabase)
--
-- Habilite em Dashboard > Database > Extensions (pg_cron, pg_net) e
-- rode o bloco abaixo trocando <PROJECT_REF> e <CRON_SECRET>:
--
--   select cron.schedule(
--     'neqst-dispatch-notifications', '10 seconds',
--     $cron$
--       select net.http_post(
--         url     := 'https://<PROJECT_REF>.supabase.co/functions/v1/dispatch-notifications',
--         headers := jsonb_build_object(
--                      'Content-Type', 'application/json',
--                      'x-cron-secret', '<CRON_SECRET>'),
--         body    := '{}'::jsonb
--       );
--     $cron$);
--
--   select cron.schedule('neqst-maintenance', '*/15 * * * *',
--                        $cron$ select public.run_maintenance(); $cron$);
-- ---------------------------------------------------------------------


-- ####################################################################
-- Origem: supabase/migrations/20261008120000_history.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 2
-- 10. Histórico do usuário (quadras visitadas, partidas jogadas)
--
-- Não precisa de tabela nova: a Sprint 1 já grava started_at/ended_at
-- em queue_entries. O histórico é uma leitura sobre esses dados.
-- =====================================================================

-- Índice que sustenta a paginação do histórico por jogador.
create index if not exists queue_entries_history_idx
  on public.queue_entries (court_id, ended_at desc)
  where status = 'done';

create index if not exists queue_entry_members_history_idx
  on public.queue_entry_members (user_id, created_at desc);

-- ---------------------------------------------------------------------
-- Partidas jogadas pelo usuário logado, mais recentes primeiro.
--
-- p_before: cursor de paginação — passe o ended_at da última linha da
-- página anterior (keyset pagination, estável mesmo com novas partidas).
-- ---------------------------------------------------------------------
create or replace function public.my_match_history(
  p_limit  integer default 20,
  p_before timestamptz default null
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with played as (
    select
      e.id          as entry_id,
      e.court_id,
      c.name        as court_name,
      c.slug        as court_slug,
      c.photo_url   as court_photo_url,
      e.mode,
      e.joined_at,
      e.started_at,
      e.ended_at,
      m.role        as my_role,
      greatest(
        round(extract(epoch from (e.ended_at - e.started_at)) / 60)::integer,
        0
      )             as duration_minutes
    from public.queue_entry_members m
    join public.queue_entries e on e.id = m.entry_id
    join public.courts c        on c.id = e.court_id
    where m.user_id = auth.uid()
      and e.status = 'done'
      and e.ended_at is not null
      and (p_before is null or e.ended_at < p_before)
    order by e.ended_at desc
    limit least(greatest(coalesce(p_limit, 20), 1), 100)
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'entry_id',         p.entry_id,
        'court_id',         p.court_id,
        'court_name',       p.court_name,
        'court_slug',       p.court_slug,
        'court_photo_url',  p.court_photo_url,
        'mode',             p.mode,
        'joined_at',        p.joined_at,
        'started_at',       p.started_at,
        'ended_at',         p.ended_at,
        'duration_minutes', p.duration_minutes,
        'my_role',          p.my_role,
        -- Com quem joguei (vazio quando foi individual).
        'teammates', (
          select coalesce(
            jsonb_agg(jsonb_build_object(
              'user_id',    pr.id,
              'username',   pr.username,
              'full_name',  pr.full_name,
              'avatar_url', pr.avatar_url
            )),
            '[]'::jsonb
          )
          from public.queue_entry_members om
          join public.profiles pr on pr.id = om.user_id
          where om.entry_id = p.entry_id and om.user_id <> auth.uid()
        )
      )
      order by p.ended_at desc
    ),
    '[]'::jsonb
  )
  from played p;
$$;

comment on function public.my_match_history(integer, timestamptz) is
  'Partidas concluídas do usuário logado, com paginação por cursor (p_before = ended_at da última linha).';

-- ---------------------------------------------------------------------
-- Quadras visitadas pelo usuário logado, com contagem e última visita.
-- ---------------------------------------------------------------------
create or replace function public.my_visited_courts(p_limit integer default 50)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'court_id',       v.court_id,
        'court_name',     v.court_name,
        'court_slug',     v.court_slug,
        'photo_url',      v.photo_url,
        'latitude',       v.latitude,
        'longitude',      v.longitude,
        'matches_played', v.matches_played,
        'minutes_played', v.minutes_played,
        'first_visit_at', v.first_visit_at,
        'last_visit_at',  v.last_visit_at
      )
      order by v.last_visit_at desc
    ),
    '[]'::jsonb
  )
  from (
    select
      c.id        as court_id,
      c.name      as court_name,
      c.slug      as court_slug,
      c.photo_url,
      c.latitude,
      c.longitude,
      count(*)::integer as matches_played,
      coalesce(sum(
        greatest(round(extract(epoch from (e.ended_at - e.started_at)) / 60)::integer, 0)
      ), 0)::integer   as minutes_played,
      min(e.ended_at)  as first_visit_at,
      max(e.ended_at)  as last_visit_at
    from public.queue_entry_members m
    join public.queue_entries e on e.id = m.entry_id
    join public.courts c        on c.id = e.court_id
    where m.user_id = auth.uid()
      and e.status = 'done'
      and e.ended_at is not null
    group by c.id, c.name, c.slug, c.photo_url, c.latitude, c.longitude
    order by max(e.ended_at) desc
    limit least(greatest(coalesce(p_limit, 50), 1), 200)
  ) v;
$$;

comment on function public.my_visited_courts(integer) is
  'Quadras onde o usuário logado já jogou, com partidas, minutos e última visita.';

-- ---------------------------------------------------------------------
-- Resumo para a tela de perfil (US-01 + histórico da Sprint 2).
-- ---------------------------------------------------------------------
create or replace function public.my_profile_summary()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'profile', (
      select jsonb_build_object(
        'user_id',    p.id,
        'username',   p.username,
        'full_name',  p.full_name,
        'email',      p.email,
        'avatar_url', p.avatar_url,
        'role',       p.role,
        'created_at', p.created_at
      )
      from public.profiles p where p.id = auth.uid()
    ),
    'stats', (
      select jsonb_build_object(
        'matches_played', count(*)::integer,
        'minutes_played', coalesce(sum(
          greatest(round(extract(epoch from (e.ended_at - e.started_at)) / 60)::integer, 0)
        ), 0)::integer,
        'courts_visited', count(distinct e.court_id)::integer,
        'last_match_at',  max(e.ended_at)
      )
      from public.queue_entry_members m
      join public.queue_entries e on e.id = m.entry_id
      where m.user_id = auth.uid() and e.status = 'done' and e.ended_at is not null
    ),
    'active_entries', public.my_active_entries()
  );
$$;

comment on function public.my_profile_summary() is
  'Uma chamada para a tela de perfil: dados, estatísticas e filas ativas.';

revoke all on function public.my_match_history(integer, timestamptz) from public;
revoke all on function public.my_visited_courts(integer)             from public;
revoke all on function public.my_profile_summary()                   from public;

grant execute on function public.my_match_history(integer, timestamptz) to authenticated;
grant execute on function public.my_visited_courts(integer)             to authenticated;
grant execute on function public.my_profile_summary()                   to authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20261008120100_court_reviews.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 2
-- 11. Sistema de avaliação da quadra
--
-- Só avalia quem jogou: exigir uma partida concluída na quadra é o que
-- separa avaliação de opinião aleatória, e não custa nada verificar —
-- o histórico da migration 10 já tem esse dado.
-- =====================================================================

create table if not exists public.court_reviews (
  id          uuid primary key default gen_random_uuid(),
  court_id    uuid not null references public.courts (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  rating      smallint not null check (rating between 1 and 5),
  comment     text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  -- Uma avaliação por jogador por quadra (editável).
  unique (court_id, user_id),

  constraint court_reviews_comment_length
    check (comment is null or char_length(comment) <= 1000)
);

comment on table public.court_reviews is
  'Avaliação de 1 a 5 por jogador por quadra, com comentário opcional.';

create index if not exists court_reviews_court_idx on public.court_reviews (court_id, created_at desc);
create index if not exists court_reviews_user_idx  on public.court_reviews (user_id, created_at desc);

drop trigger if exists court_reviews_set_updated_at on public.court_reviews;
create trigger court_reviews_set_updated_at
  before update on public.court_reviews
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------
-- Agregados desnormalizados na quadra (a tela de lista não faz join)
-- ---------------------------------------------------------------------
alter table public.courts add column if not exists rating_avg   numeric(3,2);
alter table public.courts add column if not exists rating_count integer not null default 0;

comment on column public.courts.rating_avg is
  'Média das avaliações, mantida por trigger. Null quando ainda não há avaliação.';

create or replace function public.refresh_court_rating(p_court_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.courts c
     set rating_avg   = agg.avg_rating,
         rating_count = agg.total
    from (
      select round(avg(r.rating)::numeric, 2) as avg_rating,
             count(*)::integer                as total
      from public.court_reviews r
      where r.court_id = p_court_id
    ) agg
   where c.id = p_court_id;
$$;

create or replace function public.court_reviews_sync_rating()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.refresh_court_rating(coalesce(new.court_id, old.court_id));
  return coalesce(new, old);
end;
$$;

drop trigger if exists court_reviews_sync on public.court_reviews;
create trigger court_reviews_sync
  after insert or update or delete on public.court_reviews
  for each row execute function public.court_reviews_sync_rating();

-- ---------------------------------------------------------------------
-- Pode avaliar? (precisa de pelo menos uma partida concluída na quadra)
-- ---------------------------------------------------------------------
create or replace function public.can_review_court(p_court_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.queue_entry_members m
    join public.queue_entries e on e.id = m.entry_id
    where m.user_id = auth.uid()
      and e.court_id = p_court_id
      and e.status = 'done'
  );
$$;

-- ---------------------------------------------------------------------
-- Criar ou atualizar a própria avaliação
--   NQ010 — ainda não jogou nesta quadra
-- ---------------------------------------------------------------------
create or replace function public.rate_court(
  p_court_id uuid,
  p_rating   smallint,
  p_comment  text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user   uuid := auth.uid();
  v_review public.court_reviews%rowtype;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  if p_rating is null or p_rating < 1 or p_rating > 5 then
    raise exception 'A nota deve ficar entre 1 e 5' using errcode = 'NQ011';
  end if;

  if not exists (select 1 from public.courts c where c.id = p_court_id) then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;

  if not public.can_review_court(p_court_id) then
    raise exception 'Jogue nesta quadra antes de avaliá-la' using errcode = 'NQ010';
  end if;

  insert into public.court_reviews (court_id, user_id, rating, comment)
  values (p_court_id, v_user, p_rating, nullif(trim(coalesce(p_comment, '')), ''))
  on conflict (court_id, user_id) do update
    set rating  = excluded.rating,
        comment = excluded.comment
  returning * into v_review;

  return jsonb_build_object(
    'review_id',    v_review.id,
    'court_id',     v_review.court_id,
    'rating',       v_review.rating,
    'comment',      v_review.comment,
    'created_at',   v_review.created_at,
    'updated_at',   v_review.updated_at,
    'court_rating', (
      select jsonb_build_object('average', c.rating_avg, 'count', c.rating_count)
      from public.courts c where c.id = p_court_id
    )
  );
end;
$$;

create or replace function public.delete_my_court_review(p_court_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_deleted integer;
begin
  if auth.uid() is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  delete from public.court_reviews
  where court_id = p_court_id and user_id = auth.uid();
  get diagnostics v_deleted = row_count;

  return jsonb_build_object('court_id', p_court_id, 'deleted', v_deleted > 0);
end;
$$;

-- ---------------------------------------------------------------------
-- Avaliações de uma quadra (lista pública, paginada)
-- ---------------------------------------------------------------------
create or replace function public.court_reviews_page(
  p_court_id uuid,
  p_limit    integer default 20,
  p_before   timestamptz default null
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'court_id', p_court_id,
    'summary', (
      select jsonb_build_object(
        'average', c.rating_avg,
        'count',   c.rating_count,
        'distribution', (
          select coalesce(jsonb_object_agg(d.rating::text, d.total), '{}'::jsonb)
          from (
            select r.rating, count(*)::integer as total
            from public.court_reviews r
            where r.court_id = p_court_id
            group by r.rating
          ) d
        )
      )
      from public.courts c where c.id = p_court_id
    ),
    'my_review', (
      select jsonb_build_object('rating', r.rating, 'comment', r.comment, 'updated_at', r.updated_at)
      from public.court_reviews r
      where r.court_id = p_court_id and r.user_id = auth.uid()
    ),
    'can_review', public.can_review_court(p_court_id),
    'reviews', (
      select coalesce(
        jsonb_agg(jsonb_build_object(
          'review_id',  s.id,
          'rating',     s.rating,
          'comment',    s.comment,
          'created_at', s.created_at,
          'updated_at', s.updated_at,
          'author', jsonb_build_object(
            'user_id',    s.user_id,
            'username',   s.username,
            'full_name',  s.full_name,
            'avatar_url', s.avatar_url
          )
        ) order by s.created_at desc),
        '[]'::jsonb
      )
      from (
        select r.id, r.rating, r.comment, r.created_at, r.updated_at,
               r.user_id, p.username, p.full_name, p.avatar_url
        from public.court_reviews r
        left join public.profiles p on p.id = r.user_id
        where r.court_id = p_court_id
          and (p_before is null or r.created_at < p_before)
        order by r.created_at desc
        limit least(greatest(coalesce(p_limit, 20), 1), 100)
      ) s
    )
  );
$$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.court_reviews enable row level security;

drop policy if exists "reviews: leitura pública" on public.court_reviews;
create policy "reviews: leitura pública"
  on public.court_reviews for select
  to anon, authenticated
  using (true);

drop policy if exists "reviews: dono gerencia" on public.court_reviews;
create policy "reviews: dono gerencia"
  on public.court_reviews for all
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists "reviews: staff remove abuso" on public.court_reviews;
create policy "reviews: staff remove abuso"
  on public.court_reviews for delete
  to authenticated
  using (public.is_staff());

revoke all on public.court_reviews from anon, authenticated;
grant select on public.court_reviews to anon, authenticated;

revoke all on function public.refresh_court_rating(uuid)        from public;
revoke all on function public.rate_court(uuid, smallint, text)  from public;
revoke all on function public.delete_my_court_review(uuid)      from public;

grant execute on function public.rate_court(uuid, smallint, text)                    to authenticated;
grant execute on function public.delete_my_court_review(uuid)                        to authenticated;
grant execute on function public.can_review_court(uuid)                              to authenticated;
grant execute on function public.court_reviews_page(uuid, integer, timestamptz)      to anon, authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20261008120200_court_photos.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 2
-- 12. Upload de fotos da quadra
--
-- O arquivo vai para o Supabase Storage; o banco guarda o metadado e o
-- estado de moderação. Fotos entram como 'pending' e só aparecem no app
-- depois de aprovadas — conteúdo enviado por usuário em app de loja
-- precisa de um caminho de moderação.
-- =====================================================================

do $$ begin
  create type public.photo_status as enum ('pending', 'approved', 'rejected');
exception when duplicate_object then null; end $$;

create table if not exists public.court_photos (
  id            uuid primary key default gen_random_uuid(),
  court_id      uuid not null references public.courts (id) on delete cascade,
  user_id       uuid not null references auth.users (id) on delete cascade,
  storage_path  text not null unique,
  status        public.photo_status not null default 'pending',
  caption       text,
  content_type  text not null default 'image/jpeg',
  size_bytes    integer,
  width         integer,
  height        integer,
  is_uploaded   boolean not null default false,
  is_primary    boolean not null default false,
  moderated_by  uuid references auth.users (id) on delete set null,
  moderated_at  timestamptz,
  reject_reason text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  constraint court_photos_caption_length
    check (caption is null or char_length(caption) <= 300),
  constraint court_photos_content_type
    check (content_type in ('image/jpeg', 'image/png', 'image/webp')),
  constraint court_photos_size
    check (size_bytes is null or size_bytes between 1 and 10485760)
);

comment on table public.court_photos is
  'Fotos enviadas pelos jogadores. Só status=approved e is_uploaded chegam ao app.';
comment on column public.court_photos.is_uploaded is
  'A linha nasce antes do upload (para gerar a URL assinada) e é confirmada depois.';

create index if not exists court_photos_court_idx
  on public.court_photos (court_id, created_at desc);

create index if not exists court_photos_approved_idx
  on public.court_photos (court_id, created_at desc)
  where status = 'approved' and is_uploaded;

create index if not exists court_photos_moderation_idx
  on public.court_photos (created_at)
  where status = 'pending' and is_uploaded;

-- Uma foto principal por quadra.
create unique index if not exists court_photos_one_primary_per_court
  on public.court_photos (court_id)
  where is_primary;

drop trigger if exists court_photos_set_updated_at on public.court_photos;
create trigger court_photos_set_updated_at
  before update on public.court_photos
  for each row execute function public.set_updated_at();

-- Limite de fotos pendentes por jogador por quadra, para conter flood.
create or replace function public.enforce_photo_quota()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_pending integer;
begin
  select count(*) into v_pending
  from public.court_photos p
  where p.user_id = new.user_id
    and p.court_id = new.court_id
    and p.status = 'pending';

  if v_pending >= 5 then
    raise exception 'Você já tem 5 fotos aguardando moderação nesta quadra'
      using errcode = 'NQ012';
  end if;

  return new;
end;
$$;

drop trigger if exists court_photos_quota on public.court_photos;
create trigger court_photos_quota
  before insert on public.court_photos
  for each row execute function public.enforce_photo_quota();

-- ---------------------------------------------------------------------
-- Foto principal aprovada alimenta courts.cover_photo_path
--
-- Coluna separada de courts.photo_url de propósito: aqui vai o CAMINHO
-- no Storage (bucket privado), que o cliente troca por uma URL assinada.
-- photo_url continua sendo uma URL pública externa, quando houver.
-- ---------------------------------------------------------------------
alter table public.courts add column if not exists cover_photo_path text;

comment on column public.courts.cover_photo_path is
  'Caminho no bucket court-photos da foto de capa aprovada. Precisa de URL assinada.';
create or replace function public.sync_court_primary_photo()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court uuid := coalesce(new.court_id, old.court_id);
  v_path  text;
begin
  select p.storage_path into v_path
  from public.court_photos p
  where p.court_id = v_court
    and p.status = 'approved'
    and p.is_uploaded
  order by p.is_primary desc, p.created_at
  limit 1;

  update public.courts
     set cover_photo_path = v_path
   where id = v_court
     and cover_photo_path is distinct from v_path;

  return coalesce(new, old);
end;
$$;

drop trigger if exists court_photos_sync_primary on public.court_photos;
create trigger court_photos_sync_primary
  after insert or update or delete on public.court_photos
  for each row execute function public.sync_court_primary_photo();

comment on function public.sync_court_primary_photo() is
  'Mantém courts.cover_photo_path no caminho da foto de capa aprovada (ou nulo).';

-- ---------------------------------------------------------------------
-- Fotos aprovadas de uma quadra (consumo público)
-- ---------------------------------------------------------------------
create or replace function public.court_photos_page(
  p_court_id uuid,
  p_limit    integer default 20
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(jsonb_build_object(
      'photo_id',     s.id,
      'storage_path', s.storage_path,
      'caption',      s.caption,
      'width',        s.width,
      'height',       s.height,
      'is_primary',   s.is_primary,
      'created_at',   s.created_at,
      'author', jsonb_build_object(
        'user_id',  s.user_id,
        'username', s.username
      )
    ) order by s.is_primary desc, s.created_at desc),
    '[]'::jsonb
  )
  from (
    select p.id, p.storage_path, p.caption, p.width, p.height, p.is_primary,
           p.created_at, p.user_id, pr.username
    from public.court_photos p
    left join public.profiles pr on pr.id = p.user_id
    where p.court_id = p_court_id
      and p.status = 'approved'
      and p.is_uploaded
    order by p.is_primary desc, p.created_at desc
    limit least(greatest(coalesce(p_limit, 20), 1), 100)
  ) s;
$$;

-- ---------------------------------------------------------------------
-- Moderação (staff/admin)
-- ---------------------------------------------------------------------
create or replace function public.moderate_court_photo(
  p_photo_id uuid,
  p_approve  boolean,
  p_reason   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_photo public.court_photos%rowtype;
begin
  if not public.is_staff() then
    raise exception 'Ação restrita à operação' using errcode = 'NQ008';
  end if;

  update public.court_photos
     set status        = case when p_approve then 'approved'::public.photo_status
                                             else 'rejected'::public.photo_status end,
         moderated_by  = auth.uid(),
         moderated_at  = now(),
         reject_reason = case when p_approve then null else p_reason end
   where id = p_photo_id
  returning * into v_photo;

  if not found then
    raise exception 'Foto não encontrada' using errcode = 'NQ013';
  end if;

  return jsonb_build_object(
    'photo_id', v_photo.id,
    'court_id', v_photo.court_id,
    'status',   v_photo.status
  );
end;
$$;

create or replace function public.set_primary_court_photo(p_photo_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_photo public.court_photos%rowtype;
begin
  if not public.is_staff() then
    raise exception 'Ação restrita à operação' using errcode = 'NQ008';
  end if;

  select * into v_photo from public.court_photos where id = p_photo_id;
  if not found then
    raise exception 'Foto não encontrada' using errcode = 'NQ013';
  end if;

  if v_photo.status <> 'approved' or not v_photo.is_uploaded then
    raise exception 'Só uma foto aprovada pode ser a principal' using errcode = 'NQ009';
  end if;

  update public.court_photos set is_primary = false
   where court_id = v_photo.court_id and is_primary and id <> p_photo_id;

  update public.court_photos set is_primary = true where id = p_photo_id;

  return jsonb_build_object('photo_id', p_photo_id, 'court_id', v_photo.court_id, 'is_primary', true);
end;
$$;

-- Fila de moderação
create or replace function public.pending_court_photos(p_limit integer default 50)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case when public.is_staff() then coalesce(
    (select jsonb_agg(jsonb_build_object(
        'photo_id',     p.id,
        'court_id',     p.court_id,
        'court_name',   c.name,
        'storage_path', p.storage_path,
        'caption',      p.caption,
        'created_at',   p.created_at,
        'author',       jsonb_build_object('user_id', p.user_id, 'username', pr.username)
      ) order by p.created_at)
     from public.court_photos p
     join public.courts c on c.id = p.court_id
     left join public.profiles pr on pr.id = p.user_id
     where p.status = 'pending' and p.is_uploaded
     limit least(greatest(coalesce(p_limit, 50), 1), 200)),
    '[]'::jsonb
  ) else '[]'::jsonb end;
$$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.court_photos enable row level security;

drop policy if exists "fotos: aprovadas são públicas" on public.court_photos;
create policy "fotos: aprovadas são públicas"
  on public.court_photos for select
  to anon, authenticated
  using ((status = 'approved' and is_uploaded) or user_id = auth.uid() or public.is_staff());

drop policy if exists "fotos: dono remove a própria" on public.court_photos;
create policy "fotos: dono remove a própria"
  on public.court_photos for delete
  to authenticated
  using (user_id = auth.uid() or public.is_staff());

revoke all on public.court_photos from anon, authenticated;
grant select on public.court_photos to anon, authenticated;
grant delete on public.court_photos to authenticated;

revoke all on function public.moderate_court_photo(uuid, boolean, text) from public;
revoke all on function public.set_primary_court_photo(uuid)             from public;

grant execute on function public.court_photos_page(uuid, integer)             to anon, authenticated;
grant execute on function public.moderate_court_photo(uuid, boolean, text)    to authenticated;
grant execute on function public.set_primary_court_photo(uuid)                to authenticated;
grant execute on function public.pending_court_photos(integer)                to authenticated;

-- ---------------------------------------------------------------------
-- Bucket do Storage
--
-- Privado: o app recebe URLs assinadas. Assim uma foto rejeitada deixa
-- de ser acessível, o que um bucket público não permitiria.
-- Em Postgres puro (CI) o schema storage não existe — daí o guard.
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from information_schema.tables
             where table_schema = 'storage' and table_name = 'buckets') then

    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('court-photos', 'court-photos', false, 10485760,
            array['image/jpeg', 'image/png', 'image/webp'])
    on conflict (id) do update
      set file_size_limit    = excluded.file_size_limit,
          allowed_mime_types = excluded.allowed_mime_types;

    -- Leitura apenas de objetos cuja linha correspondente está aprovada.
    execute $pol$
      drop policy if exists "court-photos: leitura de aprovadas" on storage.objects;
      create policy "court-photos: leitura de aprovadas"
        on storage.objects for select
        to authenticated
        using (
          bucket_id = 'court-photos'
          and exists (
            select 1 from public.court_photos p
            where p.storage_path = storage.objects.name
              and ((p.status = 'approved' and p.is_uploaded)
                   or p.user_id = auth.uid()
                   or public.is_staff())
          )
        );
    $pol$;

    -- O upload em si acontece por URL assinada emitida pela Edge
    -- Function, que usa service_role. O cliente não escreve direto.
    execute $pol$
      drop policy if exists "court-photos: sem escrita direta" on storage.objects;
    $pol$;
  end if;
end $$;


-- ####################################################################
-- Origem: supabase/migrations/20261008120300_heatmap.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 2
-- 13. Mapa de calor — indicador simples cheio/vazio por quadra
--
-- Duas leituras:
--   agora      -> derivado da fila ao vivo (sem tabela nova)
--   típico     -> snapshots horários, para "costuma encher nesse horário"
-- =====================================================================

do $$ begin
  create type public.occupancy_level as enum ('empty', 'low', 'busy', 'full');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- Classificação do nível de ocupação
--
-- Os limites vivem na quadra, não no código: uma quadra de clube com 2
-- times na fila está tranquila; uma quadra pública, cheia.
-- ---------------------------------------------------------------------
alter table public.courts add column if not exists busy_threshold integer not null default 2;
alter table public.courts add column if not exists full_threshold integer not null default 5;

do $$ begin
  alter table public.courts
    add constraint courts_thresholds_order check (busy_threshold < full_threshold);
exception when duplicate_object then null; end $$;

comment on column public.courts.busy_threshold is
  'A partir de quantos times na fila a quadra é considerada movimentada.';
comment on column public.courts.full_threshold is
  'A partir de quantos times na fila a quadra é considerada cheia.';

create or replace function public.occupancy_of(
  p_teams_waiting integer,
  p_has_match     boolean,
  p_busy          integer default 2,
  p_full          integer default 5
)
returns public.occupancy_level
language sql
immutable
set search_path = ''
as $$
  select case
    when coalesce(p_teams_waiting, 0) >= coalesce(p_full, 5) then 'full'::public.occupancy_level
    when coalesce(p_teams_waiting, 0) >= coalesce(p_busy, 2) then 'busy'::public.occupancy_level
    when coalesce(p_teams_waiting, 0) > 0 or coalesce(p_has_match, false)
      then 'low'::public.occupancy_level
    else 'empty'::public.occupancy_level
  end;
$$;

-- ---------------------------------------------------------------------
-- Snapshots horários (movimento típico por dia da semana e hora)
-- ---------------------------------------------------------------------
create table if not exists public.court_occupancy_snapshots (
  id             bigint generated always as identity primary key,
  court_id       uuid not null references public.courts (id) on delete cascade,
  captured_at    timestamptz not null default now(),
  day_of_week    smallint not null check (day_of_week between 0 and 6),
  hour_of_day    smallint not null check (hour_of_day between 0 and 23),
  teams_waiting  integer not null,
  has_match      boolean not null,
  level          public.occupancy_level not null
);

comment on table public.court_occupancy_snapshots is
  'Amostras periódicas da fila, usadas para o movimento típico de cada quadra.';

create index if not exists court_occupancy_snapshots_court_idx
  on public.court_occupancy_snapshots (court_id, day_of_week, hour_of_day);

create index if not exists court_occupancy_snapshots_captured_idx
  on public.court_occupancy_snapshots (captured_at);

-- Chamada pelo cron (run_maintenance).
create or replace function public.capture_occupancy_snapshots()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare v_count integer;
begin
  insert into public.court_occupancy_snapshots
    (court_id, day_of_week, hour_of_day, teams_waiting, has_match, level)
  select
    c.id,
    extract(dow  from now())::smallint,
    extract(hour from now())::smallint,
    q.teams_waiting,
    q.has_match,
    public.occupancy_of(q.teams_waiting, q.has_match, c.busy_threshold, c.full_threshold)
  from public.courts c
  cross join lateral (
    select
      count(*) filter (where e.status in ('waiting', 'ready'))::integer as teams_waiting,
      count(*) filter (where e.status = 'playing') > 0                  as has_match
    from public.queue_entries e
    where e.court_id = c.id
  ) q
  where c.is_active;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------
-- Mapa de calor: ocupação atual de todas as quadras de uma região
--
-- p_latitude/p_longitude/p_radius_meters são opcionais: sem eles,
-- devolve todas as quadras ativas (a web costuma abrir sem GPS).
-- ---------------------------------------------------------------------
create or replace function public.courts_heatmap(
  p_latitude      double precision default null,
  p_longitude     double precision default null,
  p_radius_meters double precision default null,
  p_limit         integer default 200
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(jsonb_build_object(
      'court_id',        s.id,
      'slug',            s.slug,
      'name',            s.name,
      'latitude',        s.latitude,
      'longitude',       s.longitude,
      'status',          s.status,
      'occupancy',       s.level,
      'teams_waiting',   s.teams_waiting,
      'has_match',       s.has_match,
      'estimated_wait_minutes', s.teams_waiting * s.average_match_minutes,
      'rating_avg',      s.rating_avg,
      'rating_count',    s.rating_count,
      'photo_url',       s.photo_url,
      'cover_photo_path', s.cover_photo_path,
      'distance_meters', s.distance_meters
    ) order by coalesce(s.distance_meters, 0), s.name),
    '[]'::jsonb
  )
  from (
    select
      c.id, c.slug, c.name, c.latitude, c.longitude, c.status,
      c.average_match_minutes, c.rating_avg, c.rating_count, c.photo_url,
      c.cover_photo_path,
      q.teams_waiting,
      q.has_match,
      public.occupancy_of(q.teams_waiting, q.has_match, c.busy_threshold, c.full_threshold) as level,
      case
        when p_latitude is null or p_longitude is null then null
        else public.haversine_meters(p_latitude, p_longitude, c.latitude, c.longitude)
      end as distance_meters
    from public.courts c
    cross join lateral (
      select
        count(*) filter (where e.status in ('waiting', 'ready'))::integer as teams_waiting,
        count(*) filter (where e.status = 'playing') > 0                  as has_match
      from public.queue_entries e
      where e.court_id = c.id
    ) q
    where c.is_active
      and (
        p_latitude is null or p_longitude is null or p_radius_meters is null
        or public.haversine_meters(p_latitude, p_longitude, c.latitude, c.longitude) <= p_radius_meters
      )
    limit least(greatest(coalesce(p_limit, 200), 1), 500)
  ) s;
$$;

comment on function public.courts_heatmap(double precision, double precision, double precision, integer) is
  'Ocupação atual (empty/low/busy/full) de cada quadra, opcionalmente filtrada por raio.';

-- ---------------------------------------------------------------------
-- Movimento típico de uma quadra, por dia da semana e hora
-- ---------------------------------------------------------------------
create or replace function public.court_occupancy_pattern(
  p_court_id uuid,
  p_days     integer default 28
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'court_id', p_court_id,
    'window_days', p_days,
    'samples', (
      select count(*)::integer
      from public.court_occupancy_snapshots s
      where s.court_id = p_court_id
        and s.captured_at >= now() - make_interval(days => greatest(coalesce(p_days, 28), 1))
    ),
    'pattern', (
      select coalesce(
        jsonb_agg(jsonb_build_object(
          'day_of_week',        a.day_of_week,
          'hour_of_day',        a.hour_of_day,
          'avg_teams_waiting',  a.avg_teams,
          'samples',            a.samples,
          'typical_occupancy',  a.typical_level
        ) order by a.day_of_week, a.hour_of_day),
        '[]'::jsonb
      )
      from (
        select
          s.day_of_week,
          s.hour_of_day,
          round(avg(s.teams_waiting)::numeric, 2) as avg_teams,
          count(*)::integer                       as samples,
          public.occupancy_of(
            round(avg(s.teams_waiting))::integer,
            bool_or(s.has_match),
            (select c.busy_threshold from public.courts c where c.id = p_court_id),
            (select c.full_threshold from public.courts c where c.id = p_court_id)
          ) as typical_level
        from public.court_occupancy_snapshots s
        where s.court_id = p_court_id
          and s.captured_at >= now() - make_interval(days => greatest(coalesce(p_days, 28), 1))
        group by s.day_of_week, s.hour_of_day
      ) a
    )
  );
$$;

-- ---------------------------------------------------------------------
-- Manutenção: captura snapshots e descarta os antigos
-- ---------------------------------------------------------------------
create or replace function public.run_maintenance()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_expired   integer;
  v_purged    integer;
  v_snapshots integer;
begin
  v_expired   := public.expire_stale_queue_entries();
  v_purged    := public.purge_expired_scan_tokens();
  v_snapshots := public.capture_occupancy_snapshots();

  delete from public.notification_outbox
  where status in ('sent', 'failed') and created_at < now() - interval '30 days';

  -- 90 dias de snapshots bastam para o padrão semanal.
  delete from public.court_occupancy_snapshots
  where captured_at < now() - interval '90 days';

  return jsonb_build_object(
    'expired_entries',    v_expired,
    'purged_scan_tokens', v_purged,
    'occupancy_snapshots', v_snapshots,
    'ran_at', now()
  );
end;
$$;

revoke all on function public.run_maintenance()               from public, anon, authenticated;
revoke all on function public.capture_occupancy_snapshots()   from public, anon, authenticated;

alter table public.court_occupancy_snapshots enable row level security;

drop policy if exists "snapshots: leitura pública" on public.court_occupancy_snapshots;
create policy "snapshots: leitura pública"
  on public.court_occupancy_snapshots for select
  to anon, authenticated
  using (true);

revoke all on public.court_occupancy_snapshots from anon, authenticated;
grant select on public.court_occupancy_snapshots to anon, authenticated;

grant execute on function public.occupancy_of(integer, boolean, integer, integer) to anon, authenticated;
grant execute on function public.courts_heatmap(double precision, double precision, double precision, integer)
  to anon, authenticated;
grant execute on function public.court_occupancy_pattern(uuid, integer) to anon, authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20261008120400_web_push.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 2
-- 14. Web Push para a versão web
--
-- A Expo Push API cobre o app da Play Store (FCM) e da App Store
-- (APNs), mas não entrega em navegador. O PWA usa o Web Push padrão
-- (RFC 8291 + VAPID), que tem outro formato de credencial: endpoint do
-- push service do navegador + duas chaves por subscription.
-- =====================================================================

create table if not exists public.web_push_subscriptions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  endpoint      text not null unique,
  p256dh        text not null,
  auth          text not null,
  user_agent    text,
  is_active     boolean not null default true,
  last_seen_at  timestamptz not null default now(),
  failure_count integer not null default 0,
  created_at    timestamptz not null default now(),

  constraint web_push_endpoint_https check (endpoint ~ '^https://'),
  constraint web_push_keys_length    check (char_length(p256dh) between 1 and 255
                                        and char_length(auth)   between 1 and 255)
);

comment on table public.web_push_subscriptions is
  'Subscriptions de Web Push (navegador). O equivalente de push_tokens para a versão web.';
comment on column public.web_push_subscriptions.endpoint is
  'URL do push service do navegador (FCM, Mozilla, WNS). Identifica a subscription.';

create index if not exists web_push_user_idx
  on public.web_push_subscriptions (user_id) where is_active;

-- ---------------------------------------------------------------------
-- O usuário tem algum canal de push? (app ou navegador)
-- ---------------------------------------------------------------------
create or replace function public.has_push_channel(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.push_tokens t
    where t.user_id = p_user_id and t.is_active
  ) or exists (
    select 1 from public.web_push_subscriptions w
    where w.user_id = p_user_id and w.is_active
  );
$$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.web_push_subscriptions enable row level security;

drop policy if exists "web push: dono lê" on public.web_push_subscriptions;
create policy "web push: dono lê"
  on public.web_push_subscriptions for select
  to authenticated
  using (user_id = auth.uid());

drop policy if exists "web push: dono remove" on public.web_push_subscriptions;
create policy "web push: dono remove"
  on public.web_push_subscriptions for delete
  to authenticated
  using (user_id = auth.uid());

revoke all on public.web_push_subscriptions from anon, authenticated;
grant select, delete on public.web_push_subscriptions to authenticated;

-- Só o backend (service_role) usa: para o cliente, saber se OUTRO
-- usuário tem push registrado não serve a nada e vaza informação.
revoke all on function public.has_push_channel(uuid) from public, anon, authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20261008130000_parks.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 3 (alinhamento com o protótipo de frontend)
-- 15. Parques: o nível acima das quadras
--
-- O protótipo abre numa lista de parques (Ibirapuera, Villa-Lobos,
-- Aclimação, Povo), cada um com várias quadras numeradas e com
-- superfícies diferentes. A quadra deixa de ser a entidade de topo.
-- =====================================================================

do $$ begin
  create type public.court_surface as enum ('clay', 'hard', 'grass');
exception when duplicate_object then null; end $$;

comment on type public.court_surface is
  'clay = saibro, hard = rápida, grass = grama. Rótulo e cor ficam no app.';

create table if not exists public.parks (
  id              uuid primary key default gen_random_uuid(),
  slug            extensions.citext not null unique,
  name            text not null,
  -- "Vila Mariana · Zona Sul" — aparece sob o nome na lista
  district        text,
  city            text,
  address         text,
  latitude        double precision not null check (latitude between -90 and 90),
  longitude       double precision not null check (longitude between -180 and 180),
  -- Cor de fundo do cartão quando não há foto
  tone_color      text check (tone_color is null or tone_color ~ '^#[0-9A-Fa-f]{6}$'),
  photo_url       text,
  photo_alt       text,
  is_active       boolean not null default true,
  opens_at        time,
  closes_at       time,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint parks_name_length check (char_length(name) between 2 and 120),
  constraint parks_slug_format check (slug ~ '^[a-z0-9-]{3,60}$')
);

comment on table  public.parks is 'Parque ou complexo esportivo que abriga várias quadras.';
comment on column public.parks.photo_alt is
  'Texto alternativo da foto — o protótipo descreve a imagem ("quadra de saibro").';

create index if not exists parks_active_idx  on public.parks (is_active);
create index if not exists parks_latlng_idx  on public.parks (latitude, longitude);

drop trigger if exists parks_set_updated_at on public.parks;
create trigger parks_set_updated_at
  before update on public.parks
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------
-- A quadra agora pertence a um parque, tem número e superfície
-- ---------------------------------------------------------------------
alter table public.courts add column if not exists park_id      uuid references public.parks (id) on delete cascade;
alter table public.courts add column if not exists court_number smallint;
alter table public.courts add column if not exists surface      public.court_surface;

comment on column public.courts.court_number is
  'Número dentro do parque: o app mostra "Quadra 01", "Quadra 02".';

-- Quadras que existiam antes do conceito de parque ganham um parque
-- derivado dos próprios dados, para a coluna poder virar obrigatória.
do $$
declare
  v_court record;
  v_park  uuid;
  v_slug  text;
begin
  for v_court in
    select id, name, slug, city, address, latitude, longitude
    from public.courts
    where park_id is null
    order by created_at
  loop
    v_slug := left('parque-' || v_court.slug::text, 60);

    select p.id into v_park from public.parks p where p.slug = v_slug::extensions.citext;

    if v_park is null then
      insert into public.parks (slug, name, city, address, latitude, longitude)
      values (v_slug, v_court.name, v_court.city, v_court.address,
              v_court.latitude, v_court.longitude)
      returning id into v_park;
    end if;

    update public.courts
       set park_id = v_park,
           court_number = coalesce(court_number, 1)
     where id = v_court.id;
  end loop;
end $$;

update public.courts set court_number = 1 where court_number is null;
update public.courts set surface = 'clay' where surface is null;

alter table public.courts alter column park_id      set not null;
alter table public.courts alter column court_number set not null;
alter table public.courts alter column surface      set not null;
alter table public.courts alter column surface      set default 'clay';

do $$ begin
  alter table public.courts
    add constraint courts_number_positive check (court_number between 1 and 99);
exception when duplicate_object then null; end $$;

-- Dois "Quadra 01" no mesmo parque confundiriam o jogador na hora de
-- achar a quadra física.
create unique index if not exists courts_number_per_park
  on public.courts (park_id, court_number);

create index if not exists courts_park_idx on public.courts (park_id);

-- ---------------------------------------------------------------------
-- Rótulo da quadra, do jeito que o app mostra
-- ---------------------------------------------------------------------
create or replace function public.court_label(p_number smallint)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'Quadra ' || lpad(p_number::text, 2, '0');
$$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.parks enable row level security;

drop policy if exists "parques: leitura pública" on public.parks;
create policy "parques: leitura pública"
  on public.parks for select
  to anon, authenticated
  using (is_active or public.is_staff());

drop policy if exists "parques: admin gerencia" on public.parks;
create policy "parques: admin gerencia"
  on public.parks for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

revoke all on public.parks from anon, authenticated;
grant select on public.parks to anon, authenticated;

grant execute on function public.court_label(smallint) to anon, authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20261008130100_matches.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 3
-- 16. Partida com dois lados e "quem ganha fica"
--
-- A Sprint 1 modelava um time em quadra. O protótipo mostra o jogo real:
-- lado A contra lado B, e no fim do slot o vencedor permanece como
-- mandante enquanto o próximo time da fila entra como desafiante.
--
--   mandante (lado B)  ──── vence ────▶ continua como mandante
--   desafiante (lado A) ─── perde ────▶ sai
--                                        ▲
--                      próximo da fila ──┘
--
-- Quando a quadra está livre, o primeiro time entra como lado A e o
-- lado B fica aberto — é o "Adversário livre" do protótipo.
-- =====================================================================

do $$ begin
  create type public.match_side as enum ('a', 'b');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.match_end_reason as enum
    ('reported', 'slot_expired', 'abandoned', 'cancelled');
exception when duplicate_object then null; end $$;

create table if not exists public.matches (
  id                 uuid primary key default gen_random_uuid(),
  court_id           uuid not null references public.courts (id) on delete cascade,

  -- Lado A é sempre o desafiante que veio da fila.
  side_a_entry_id    uuid not null references public.queue_entries (id) on delete cascade,
  -- Lado B é o mandante. Nulo = "Adversário livre": a quadra estava
  -- vazia e ninguém ocupou o outro lado ainda.
  side_b_entry_id    uuid references public.queue_entries (id) on delete set null,

  mode               public.queue_mode not null,
  slot_minutes       smallint not null check (slot_minutes between 5 and 240),

  started_at         timestamptz not null default now(),
  expires_at         timestamptz not null,
  ended_at           timestamptz,
  winner_side        public.match_side,
  end_reason         public.match_end_reason,
  reported_by        uuid references auth.users (id) on delete set null,

  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  constraint matches_sides_differ
    check (side_b_entry_id is null or side_b_entry_id <> side_a_entry_id),
  -- Vencedor só existe em partida encerrada, e um lado vazio não vence.
  constraint matches_winner_needs_end
    check ((winner_side is null) or (ended_at is not null)),
  constraint matches_end_needs_reason
    check ((ended_at is null) = (end_reason is null)),
  constraint matches_winner_b_needs_side_b
    check (winner_side is distinct from 'b' or side_b_entry_id is not null)
);

comment on table  public.matches is 'Uma partida em quadra: desafiante (lado A) contra mandante (lado B).';
comment on column public.matches.side_b_entry_id is
  'Mandante. Nulo quando a quadra estava livre e o outro lado segue aberto.';
comment on column public.matches.expires_at is
  'started_at + slot da quadra. Chegando aqui, a partida encerra e a fila anda.';

-- Uma partida em andamento por quadra. É esta a invariante agora: o
-- índice da Sprint 1 (queue_entries_one_playing_per_court) presumia um
-- único time em quadra e impediria os dois lados de jogarem.
create unique index if not exists matches_one_live_per_court
  on public.matches (court_id)
  where ended_at is null;

drop index if exists public.queue_entries_one_playing_per_court;

create index if not exists matches_court_idx    on public.matches (court_id, started_at desc);
create index if not exists matches_live_idx     on public.matches (expires_at) where ended_at is null;
create index if not exists matches_side_a_idx   on public.matches (side_a_entry_id);
create index if not exists matches_side_b_idx   on public.matches (side_b_entry_id);

drop trigger if exists matches_set_updated_at on public.matches;
create trigger matches_set_updated_at
  before update on public.matches
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------
-- O mandante atual da quadra
--
-- Fica numa coluna, e não calculado a cada leitura: a tela da quadra e
-- o mapa de calor consultam isso toda hora.
-- ---------------------------------------------------------------------
alter table public.courts add column if not exists holder_entry_id uuid
  references public.queue_entries (id) on delete set null;

comment on column public.courts.holder_entry_id is
  'Time que venceu a última partida e segue em quadra. Nulo = quadra sem mandante.';

-- ---------------------------------------------------------------------
-- Slot de tempo: limite rígido, não média
--
-- O protótipo trata slotMinutes como prazo ("Faltam ~12 min", e no fim
-- chama o próximo). average_match_minutes continua existindo para não
-- quebrar o que já consome, mas passa a espelhar o slot.
-- ---------------------------------------------------------------------
alter table public.courts add column if not exists slot_minutes smallint;

update public.courts
   set slot_minutes = coalesce(slot_minutes, greatest(least(average_match_minutes, 90), 20))
 where slot_minutes is null;

alter table public.courts alter column slot_minutes set default 40;
alter table public.courts alter column slot_minutes set not null;

do $$ begin
  alter table public.courts
    add constraint courts_slot_minutes_range check (slot_minutes between 20 and 90);
exception when duplicate_object then null; end $$;

comment on column public.courts.slot_minutes is
  'Duração máxima de uma partida (protótipo: 40 min, faixa 20-90).';

create or replace function public.courts_sync_slot()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Mantém average_match_minutes (usado nas estimativas da Sprint 1 e 2)
  -- alinhado ao slot, para as duas leituras não divergirem.
  if new.slot_minutes is distinct from old.slot_minutes
     or new.average_match_minutes is distinct from old.average_match_minutes then
    new.average_match_minutes := new.slot_minutes;
  end if;
  return new;
end;
$$;

drop trigger if exists courts_sync_slot_trigger on public.courts;
create trigger courts_sync_slot_trigger
  before update on public.courts
  for each row execute function public.courts_sync_slot();

update public.courts set average_match_minutes = slot_minutes
where average_match_minutes <> slot_minutes;

-- Iniciais e nome curto, como o protótipo monta ("D. Matsuo", "DM")
create or replace function public.initials_of(p_name text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when coalesce(trim(p_name), '') = '' then '?'
    else upper(
      left(split_part(trim(p_name), ' ', 1), 1) ||
      case
        when array_length(regexp_split_to_array(trim(p_name), '\s+'), 1) > 1
          then left((regexp_split_to_array(trim(p_name), '\s+'))[
            array_length(regexp_split_to_array(trim(p_name), '\s+'), 1)], 1)
        else ''
      end
    )
  end;
$$;

create or replace function public.short_name_of(p_name text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when coalesce(trim(p_name), '') = '' then 'Jogador'
    when array_length(regexp_split_to_array(trim(p_name), '\s+'), 1) > 1
      then split_part(trim(p_name), ' ', 1) || ' ' ||
           left((regexp_split_to_array(trim(p_name), '\s+'))[
             array_length(regexp_split_to_array(trim(p_name), '\s+'), 1)], 1) || '.'
    else trim(p_name)
  end;
$$;

-- ---------------------------------------------------------------------
-- Jogadores de um lado, no formato que o placar usa
-- ---------------------------------------------------------------------
create or replace function public.match_side_players(p_entry_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'user_id',   m.user_id,
        'username',  p.username,
        'full_name', p.full_name,
        'initials',  public.initials_of(coalesce(p.full_name, p.username::text)),
        'short_name', public.short_name_of(coalesce(p.full_name, p.username::text))
      )
      order by m.role, m.created_at
    ),
    '[]'::jsonb
  )
  from public.queue_entry_members m
  left join public.profiles p on p.id = m.user_id
  where m.entry_id = p_entry_id;
$$;

grant execute on function public.initials_of(text)        to anon, authenticated;
grant execute on function public.short_name_of(text)      to anon, authenticated;
grant execute on function public.match_side_players(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.matches enable row level security;

drop policy if exists "partidas: leitura pública" on public.matches;
create policy "partidas: leitura pública"
  on public.matches for select
  to anon, authenticated
  using (true);

revoke all on public.matches from anon, authenticated;
grant select on public.matches to anon, authenticated;

-- Realtime: o placar da quadra é ao vivo.
alter table public.matches replica identity full;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'matches'
  ) then
    alter publication supabase_realtime add table public.matches;
  end if;
end $$;


-- ####################################################################
-- Origem: supabase/migrations/20261008130200_queue_rules.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 3
-- 17. Regras da fila alinhadas ao protótipo
--
-- Três mudanças de comportamento:
--
--   1. Uma fila por jogador em TODO o app, não por quadra. O protótipo
--      recusa entrar em qualquer fila com "Você já está na fila da
--      Quadra 04".
--   2. Quem inicia a partida é o próprio jogador, escaneando o QR/NFC
--      da quadra. Não existe operador num parque público.
--   3. Chamado tem prazo: 5 minutos para o check-in, senão a vez passa.
--
-- Códigos novos:
--   NQ014 jogador já está em uma fila (em qualquer quadra)
--   NQ015 não é a vez deste time
--   NQ016 chamada expirada
--   NQ017 a quadra ainda está ocupada
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Uma fila por jogador em todo o app
-- ---------------------------------------------------------------------
drop index if exists public.queue_entry_members_one_active_per_court;

create unique index if not exists queue_entry_members_one_active_per_player
  on public.queue_entry_members (user_id)
  where is_active;

comment on index public.queue_entry_members_one_active_per_player is
  'Um jogador em uma fila só, em qualquer quadra de qualquer parque.';

-- ---------------------------------------------------------------------
-- 2. Prazo da chamada
-- ---------------------------------------------------------------------
alter table public.courts add column if not exists call_window_seconds integer not null default 300;

do $$ begin
  alter table public.courts
    add constraint courts_call_window_range
    check (call_window_seconds between 60 and 1800);
exception when duplicate_object then null; end $$;

comment on column public.courts.call_window_seconds is
  'Tempo para comparecer depois de ser chamado (protótipo: 300s).';

alter table public.queue_entries add column if not exists call_expires_at timestamptz;

comment on column public.queue_entries.call_expires_at is
  'Fim da janela de check-in. Passou disso, o time é expirado e a vez anda.';

create index if not exists queue_entries_called_idx
  on public.queue_entries (call_expires_at)
  where status = 'ready';

-- ---------------------------------------------------------------------
-- Onde o jogador está agora (usado na busca de parceiro e no bloqueio)
-- ---------------------------------------------------------------------
create or replace function public.player_state(p_user_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      select jsonb_build_object(
        'state', case
                   when e.status = 'playing' then 'playing'
                   else 'queued'
                 end,
        'entry_id',   e.id,
        'court_id',   c.id,
        'court_name', public.court_label(c.court_number),
        'park_id',    pk.id,
        'park_name',  pk.name,
        'where', case
                   when e.status = 'playing'
                     then 'Em jogo · ' || public.court_label(c.court_number)
                   else 'Na fila · ' || public.court_label(c.court_number)
                 end
      )
      from public.queue_entry_members m
      join public.queue_entries e on e.id = m.entry_id
      join public.courts c        on c.id = e.court_id
      join public.parks pk        on pk.id = c.park_id
      where m.user_id = p_user_id and m.is_active
      limit 1
    ),
    jsonb_build_object('state', 'free')
  );
$$;

comment on function public.player_state(uuid) is
  'free / queued / playing, com a quadra onde está. Alimenta a lista de parceiros.';

-- ---------------------------------------------------------------------
-- join_queue: agora recusa quem já está em qualquer fila
-- ---------------------------------------------------------------------
create or replace function public.join_queue(
  p_scan_token text,
  p_mode       public.queue_mode default 'single',
  p_partner    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user       uuid := auth.uid();
  v_token      public.scan_tokens%rowtype;
  v_court      public.courts%rowtype;
  v_partner_id uuid;
  v_entry_id   uuid;
  v_needle     text;
  v_state      jsonb;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  -- 1. Prova de presença (QR ou NFC validados na Edge Function)
  select * into v_token
  from public.scan_tokens t
  where t.token_hash = public.hash_scan_token(p_scan_token)
  for update;

  if not found
     or v_token.user_id <> v_user
     or v_token.consumed_at is not null
     or v_token.expires_at <= now() then
    raise exception 'Escaneie o QR Code da quadra novamente para entrar na fila'
      using errcode = 'NQ002';
  end if;

  -- 2. Quadra disponível
  select * into v_court from public.courts c where c.id = v_token.court_id for update;

  if not found or not v_court.is_active or v_court.status = 'unavailable' then
    raise exception 'Esta quadra está indisponível no momento' using errcode = 'NQ003';
  end if;

  -- 3. Uma fila por jogador em todo o app
  v_state := public.player_state(v_user);

  if v_state ->> 'state' <> 'free' then
    if (v_state ->> 'court_id')::uuid = v_court.id then
      raise exception 'Você já está nesta fila' using errcode = 'NQ004';
    end if;
    raise exception 'Você já está na fila da %', v_state ->> 'court_name'
      using errcode = 'NQ014';
  end if;

  -- 4. Parceiro de dupla
  if p_mode = 'double' then
    v_needle := regexp_replace(lower(trim(coalesce(p_partner, ''))), '^@', '');

    if v_needle = '' then
      raise exception 'Informe o @username ou e-mail do parceiro' using errcode = 'NQ005';
    end if;

    select p.id into v_partner_id
    from public.profiles p
    where p.username = v_needle::extensions.citext
       or p.email    = v_needle::extensions.citext
    limit 1;

    if v_partner_id is null then
      raise exception 'Parceiro não encontrado: %', p_partner using errcode = 'NQ005';
    end if;

    if v_partner_id = v_user then
      raise exception 'Escolha outro jogador como parceiro' using errcode = 'NQ006';
    end if;

    v_state := public.player_state(v_partner_id);
    if v_state ->> 'state' <> 'free' then
      raise exception 'Seu parceiro está %', lower(coalesce(v_state ->> 'where', 'indisponível'))
        using errcode = 'NQ006';
    end if;
  end if;

  -- 5. Cria o time
  insert into public.queue_entries (court_id, mode, created_by, scan_token_id)
  values (v_court.id, p_mode, v_user, v_token.id)
  returning id into v_entry_id;

  insert into public.queue_entry_members (entry_id, court_id, user_id, role)
  values (v_entry_id, v_court.id, v_user, 'owner');

  if v_partner_id is not null then
    insert into public.queue_entry_members (entry_id, court_id, user_id, role)
    values (v_entry_id, v_court.id, v_partner_id, 'partner');

    perform public.enqueue_team_notification(
      v_entry_id,
      'queue_partner_added',
      'Você entrou numa dupla',
      format('Você foi adicionado a um time na %s.', public.court_label(v_court.court_number)),
      jsonb_build_object('court_id', v_court.id, 'entry_id', v_entry_id)
    );
  end if;

  -- 6. Consome o token (uso único)
  update public.scan_tokens
     set consumed_at = now(), consumed_by_entry = v_entry_id
   where id = v_token.id;

  -- 7. Quadra livre e fila vazia? Então já é a vez deste time: chama
  -- agora, abrindo a janela de check-in. Sem isso, quem chega numa
  -- quadra vazia ficaria esperando um chamado que nunca vem.
  perform public.call_next_team(v_court.id);

  return public.queue_entry_state(v_entry_id);
end;
$$;

-- ---------------------------------------------------------------------
-- Núcleo de abrir partida
--
-- Compartilhado pelo check-in do jogador e pela operação do parque, para
-- os dois caminhos não divergirem: a Sprint 1 marcava a inscrição como
-- 'playing' sem criar partida, o que deixaria a tela da quadra dizendo
-- "Livre" com gente jogando.
-- ---------------------------------------------------------------------
create or replace function public.open_match(p_entry_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry    public.queue_entries%rowtype;
  v_court    public.courts%rowtype;
  v_first    uuid;
  v_live     public.matches%rowtype;
  v_match_id uuid;
  v_holder   uuid;
begin
  select * into v_entry from public.queue_entries e where e.id = p_entry_id for update;
  if not found then
    raise exception 'Time não encontrado' using errcode = 'NQ007';
  end if;
  if v_entry.status not in ('waiting', 'ready') then
    raise exception 'Este time não pode iniciar uma partida agora' using errcode = 'NQ009';
  end if;

  select * into v_court from public.courts c where c.id = v_entry.court_id for update;
  if not v_court.is_active or v_court.status = 'unavailable' then
    raise exception 'Esta quadra está indisponível no momento' using errcode = 'NQ003';
  end if;

  -- É a vez deste time?
  select qp.entry_id into v_first
  from public.queue_positions qp
  where qp.court_id = v_court.id
  order by qp.position
  limit 1;

  if v_first is distinct from v_entry.id then
    raise exception 'Ainda não é a vez do seu time' using errcode = 'NQ015';
  end if;

  -- A partida anterior precisa ter acabado (ou o slot estourado)
  select * into v_live
  from public.matches mt
  where mt.court_id = v_court.id and mt.ended_at is null
  for update;

  if found then
    if v_live.expires_at > now() then
      raise exception 'A quadra está ocupada por mais % minuto(s)',
        greatest(1, ceil(extract(epoch from (v_live.expires_at - now())) / 60)::integer)
        using errcode = 'NQ017';
    end if;
    -- Slot estourado sem ninguém reportar: encerra sem vencedor.
    perform public.close_match(v_live.id, null, 'slot_expired');
  end if;

  select c.holder_entry_id into v_holder from public.courts c where c.id = v_court.id;

  insert into public.matches
    (court_id, side_a_entry_id, side_b_entry_id, mode, slot_minutes, expires_at)
  values
    (v_court.id, v_entry.id, v_holder, v_entry.mode, v_court.slot_minutes,
     now() + make_interval(mins => v_court.slot_minutes))
  returning id into v_match_id;

  update public.queue_entries
     set status = 'playing', called_at = coalesce(called_at, now()), started_at = now()
   where id = v_entry.id;

  update public.courts set status = 'in_game' where id = v_court.id;

  return public.match_state(v_match_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Check-in do jogador: libera o placar e inicia a partida
--
-- É o "Check-in para jogar" do protótipo. Exige um scan token novo —
-- escanear de longe para iniciar uma partida que não vai acontecer
-- travaria a quadra para todo mundo.
-- ---------------------------------------------------------------------
create or replace function public.check_in_and_start(p_scan_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user  uuid := auth.uid();
  v_token public.scan_tokens%rowtype;
  v_entry public.queue_entries%rowtype;
  v_state jsonb;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  select * into v_token
  from public.scan_tokens t
  where t.token_hash = public.hash_scan_token(p_scan_token)
  for update;

  if not found
     or v_token.user_id <> v_user
     or v_token.consumed_at is not null
     or v_token.expires_at <= now() then
    raise exception 'Escaneie o QR Code da quadra para confirmar que você chegou'
      using errcode = 'NQ002';
  end if;

  select e.* into v_entry
  from public.queue_entry_members m
  join public.queue_entries e on e.id = m.entry_id
  where m.user_id = v_user and m.is_active and e.court_id = v_token.court_id;

  if not found then
    raise exception 'Você não está na fila desta quadra' using errcode = 'NQ007';
  end if;

  -- Chamada expirada: a vez já passou
  if v_entry.status = 'ready'
     and v_entry.call_expires_at is not null
     and v_entry.call_expires_at <= now() then
    raise exception 'O tempo para o check-in terminou' using errcode = 'NQ016';
  end if;

  v_state := public.open_match(v_entry.id);

  update public.scan_tokens
     set consumed_at = now(), consumed_by_entry = v_entry.id
   where id = v_token.id;

  return v_state;
end;
$$;

-- ---------------------------------------------------------------------
-- Encerrar a partida (uso interno: aplica o "quem ganha fica")
-- ---------------------------------------------------------------------
create or replace function public.close_match(
  p_match_id uuid,
  p_winner   public.match_side,
  p_reason   public.match_end_reason,
  p_reporter uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_match  public.matches%rowtype;
  v_winner uuid;
  v_loser  uuid;
begin
  select * into v_match from public.matches mt where mt.id = p_match_id for update;
  if not found then
    raise exception 'Partida não encontrada' using errcode = 'NQ018';
  end if;
  if v_match.ended_at is not null then
    return public.match_state(p_match_id);
  end if;

  update public.matches
     set ended_at    = now(),
         winner_side = p_winner,
         end_reason  = p_reason,
         reported_by = p_reporter
   where id = p_match_id;

  -- Quem ganha fica; quem perde (e quem jogou sem vencedor) sai.
  if p_winner = 'a' then
    v_winner := v_match.side_a_entry_id;
    v_loser  := v_match.side_b_entry_id;
  elsif p_winner = 'b' then
    v_winner := v_match.side_b_entry_id;
    v_loser  := v_match.side_a_entry_id;
  end if;

  if v_loser is not null then
    update public.queue_entries
       set status = 'done', ended_at = now()
     where id = v_loser and status = 'playing';
  end if;

  if v_winner is null then
    -- Sem vencedor: os dois lados saem e a quadra fica sem mandante.
    update public.queue_entries
       set status = 'done', ended_at = now()
     where id in (v_match.side_a_entry_id, v_match.side_b_entry_id)
       and status = 'playing';
  end if;

  update public.courts
     set holder_entry_id = v_winner,
         status = case
                    when status = 'unavailable' then 'unavailable'::public.court_status
                    else 'available'::public.court_status
                  end
   where id = v_match.court_id;

  -- Com a quadra livre, o próximo time é chamado na hora.
  perform public.call_next_team(v_match.court_id);

  return public.match_state(p_match_id);
end;
$$;

-- ---------------------------------------------------------------------
-- Reportar o resultado — qualquer jogador das duas equipes
-- ---------------------------------------------------------------------
create or replace function public.report_match_result(
  p_match_id uuid,
  p_winner   public.match_side
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user  uuid := auth.uid();
  v_match public.matches%rowtype;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;
  if p_winner is null then
    raise exception 'Informe o lado vencedor' using errcode = 'NQ011';
  end if;

  select * into v_match from public.matches mt where mt.id = p_match_id;
  if not found then
    raise exception 'Partida não encontrada' using errcode = 'NQ018';
  end if;
  if v_match.ended_at is not null then
    raise exception 'Esta partida já foi encerrada' using errcode = 'NQ009';
  end if;

  if not exists (
    select 1 from public.queue_entry_members m
    where m.user_id = v_user
      and m.entry_id in (v_match.side_a_entry_id, v_match.side_b_entry_id)
  ) and not public.is_staff() then
    raise exception 'Só quem está em quadra reporta o resultado' using errcode = 'NQ008';
  end if;

  if p_winner = 'b' and v_match.side_b_entry_id is null then
    raise exception 'A partida não tem adversário no lado B' using errcode = 'NQ009';
  end if;

  return public.close_match(p_match_id, p_winner, 'reported', v_user);
end;
$$;

-- ---------------------------------------------------------------------
-- Ocupar o lado livre de uma partida ("Adversário livre")
-- ---------------------------------------------------------------------
create or replace function public.join_open_side(p_scan_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user  uuid := auth.uid();
  v_token public.scan_tokens%rowtype;
  v_match public.matches%rowtype;
  v_entry public.queue_entries%rowtype;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  select * into v_token
  from public.scan_tokens t
  where t.token_hash = public.hash_scan_token(p_scan_token)
  for update;

  if not found or v_token.user_id <> v_user
     or v_token.consumed_at is not null or v_token.expires_at <= now() then
    raise exception 'Escaneie o QR Code da quadra novamente' using errcode = 'NQ002';
  end if;

  select * into v_match
  from public.matches mt
  where mt.court_id = v_token.court_id and mt.ended_at is null
  for update;

  if not found then
    raise exception 'Não há partida em andamento nesta quadra' using errcode = 'NQ017';
  end if;
  if v_match.side_b_entry_id is not null then
    raise exception 'Esta partida já tem os dois lados' using errcode = 'NQ009';
  end if;

  select e.* into v_entry
  from public.queue_entry_members m
  join public.queue_entries e on e.id = m.entry_id
  where m.user_id = v_user and m.is_active and e.court_id = v_token.court_id
  for update of e;

  if not found then
    raise exception 'Entre na fila desta quadra antes' using errcode = 'NQ007';
  end if;
  if v_entry.id = v_match.side_a_entry_id then
    raise exception 'Seu time já está no lado A' using errcode = 'NQ009';
  end if;
  if v_entry.mode <> v_match.mode then
    raise exception 'A partida em andamento é %',
      case when v_match.mode = 'double' then 'de duplas' else 'de simples' end
      using errcode = 'NQ009';
  end if;

  update public.matches set side_b_entry_id = v_entry.id where id = v_match.id;

  update public.queue_entries
     set status = 'playing', called_at = coalesce(called_at, now()), started_at = now()
   where id = v_entry.id;

  update public.scan_tokens
     set consumed_at = now(), consumed_by_entry = v_entry.id
   where id = v_token.id;

  return public.match_state(v_match.id);
end;
$$;

-- ---------------------------------------------------------------------
-- Chamar o próximo time (abre a janela de check-in)
-- ---------------------------------------------------------------------
create or replace function public.call_next_team(p_court_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court public.courts%rowtype;
  v_next  uuid;
begin
  select * into v_court from public.courts c where c.id = p_court_id;
  if not found then
    return null;
  end if;

  -- Só chama se a quadra estiver livre.
  if exists (select 1 from public.matches mt
             where mt.court_id = p_court_id and mt.ended_at is null) then
    return null;
  end if;

  select qp.entry_id into v_next
  from public.queue_positions qp
  where qp.court_id = p_court_id
  order by qp.position
  limit 1;

  if v_next is null then
    return null;
  end if;

  update public.queue_entries
     set status          = 'ready',
         called_at       = coalesce(called_at, now()),
         call_expires_at = now() + make_interval(secs => v_court.call_window_seconds)
   where id = v_next and status = 'waiting';

  return v_next;
end;
$$;

-- ---------------------------------------------------------------------
-- Rotina: encerra slot estourado e expira chamada não atendida
-- ---------------------------------------------------------------------
create or replace function public.advance_expired_queues()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_match   record;
  v_entry   record;
  v_closed  integer := 0;
  v_expired integer := 0;
begin
  -- Slot estourado: encerra sem vencedor e chama o próximo.
  for v_match in
    select id from public.matches
    where ended_at is null and expires_at <= now()
  loop
    perform public.close_match(v_match.id, null, 'slot_expired');
    v_closed := v_closed + 1;
  end loop;

  -- Chamado e não compareceu: perde a vez, e o próximo é chamado.
  for v_entry in
    select e.id, e.court_id
    from public.queue_entries e
    where e.status = 'ready'
      and e.call_expires_at is not null
      and e.call_expires_at <= now()
  loop
    update public.queue_entries
       set status = 'expired', cancel_reason = 'no_show', left_at = now()
     where id = v_entry.id;

    perform public.call_next_team(v_entry.court_id);
    v_expired := v_expired + 1;
  end loop;

  return jsonb_build_object(
    'matches_closed', v_closed,
    'entries_expired', v_expired,
    'ran_at', now()
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
revoke all on function public.close_match(uuid, public.match_side, public.match_end_reason, uuid)
  from public, anon, authenticated;
revoke all on function public.call_next_team(uuid)       from public, anon, authenticated;
revoke all on function public.advance_expired_queues()   from public, anon, authenticated;

grant execute on function public.check_in_and_start(text)                       to authenticated;
grant execute on function public.join_open_side(text)                           to authenticated;
grant execute on function public.report_match_result(uuid, public.match_side)   to authenticated;
grant execute on function public.player_state(uuid)                             to authenticated;

-- ---------------------------------------------------------------------
-- Operação do parque (staff/admin), sobre o mesmo modelo
--
-- Um parque público não tem operador — o caminho principal é o check-in
-- do jogador. Estas ficam para quem administra uma quadra de clube.
-- ---------------------------------------------------------------------
create or replace function public.start_match(p_entry_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_staff() then
    raise exception 'Apenas a operação da quadra pode iniciar partidas sem check-in'
      using errcode = 'NQ008';
  end if;
  return public.open_match(p_entry_id);
end;
$$;

-- A versão da Sprint 1 tinha um argumento só; mantê-la deixaria a
-- chamada com um argumento ambígua (42725).
drop function if exists public.finish_match(uuid);

create or replace function public.finish_match(
  p_entry_id uuid,
  p_winner   public.match_side default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_match public.matches%rowtype;
begin
  if not public.is_staff() then
    raise exception 'Apenas a operação da quadra pode encerrar partidas' using errcode = 'NQ008';
  end if;

  select * into v_match
  from public.matches mt
  where mt.ended_at is null
    and p_entry_id in (mt.side_a_entry_id, mt.side_b_entry_id);

  if not found then
    raise exception 'Este time não está em quadra' using errcode = 'NQ009';
  end if;

  return public.close_match(v_match.id, p_winner, 'cancelled', auth.uid());
end;
$$;

-- Encerra a partida atual (sem vencedor) e chama o próximo time.
create or replace function public.call_next(p_court_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_live uuid;
  v_next uuid;
begin
  if not public.is_staff() then
    raise exception 'Apenas a operação da quadra pode chamar o próximo time' using errcode = 'NQ008';
  end if;

  select mt.id into v_live
  from public.matches mt
  where mt.court_id = p_court_id and mt.ended_at is null;

  if v_live is not null then
    perform public.close_match(v_live, null, 'cancelled', auth.uid());
  else
    v_next := public.call_next_team(p_court_id);
  end if;

  select qp.entry_id into v_next
  from public.queue_positions qp
  where qp.court_id = p_court_id
  order by qp.position
  limit 1;

  if v_next is null then
    return jsonb_build_object('court_id', p_court_id, 'next_entry', null,
                              'message', 'Não há times na fila');
  end if;

  return public.queue_entry_state(v_next);
end;
$$;

revoke all on function public.open_match(uuid) from public, anon, authenticated;

grant execute on function public.start_match(uuid)                               to authenticated;
grant execute on function public.finish_match(uuid, public.match_side)           to authenticated;
grant execute on function public.call_next(uuid)                                 to authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20261008130300_profile_and_partners.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 3
-- 18. Perfil e busca de parceiro
--
-- A fila é desenhada como uma pilha de raquetes, uma por time, com as
-- cores que o jogador escolhe no perfil. Sem isso, a tela principal não
-- consegue desenhar a pilha.
-- =====================================================================

alter table public.profiles add column if not exists racket_frame_color text not null default '#C49051';
alter table public.profiles add column if not exists racket_grip_color  text not null default '#F1ECEF';
alter table public.profiles add column if not exists avatar_tone        smallint not null default 0;

do $$ begin
  alter table public.profiles
    add constraint profiles_racket_colors
    check (racket_frame_color ~ '^#[0-9A-Fa-f]{6}$' and racket_grip_color ~ '^#[0-9A-Fa-f]{6}$');
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.profiles
    add constraint profiles_avatar_tone_range check (avatar_tone between 0 and 2);
exception when duplicate_object then null; end $$;

comment on column public.profiles.racket_frame_color is 'Cor do aro da raquete na pilha da fila.';
comment on column public.profiles.racket_grip_color  is 'Cor do grip da raquete na pilha da fila.';
comment on column public.profiles.avatar_tone        is 'Índice do tom de fundo do avatar (0-2).';

-- Paleta do protótipo. Fica no banco para o app e o backend não
-- divergirem, e para a validação recusar cor fora do conjunto.
create table if not exists public.racket_palette (
  color       text primary key check (color ~ '^#[0-9A-Fa-f]{6}$'),
  name        text not null,
  for_frame   boolean not null default true,
  for_grip    boolean not null default true,
  sort_order  smallint not null default 0
);

insert into public.racket_palette (color, name, sort_order) values
  ('#C49051', 'Ocre',        1),
  ('#F1ECEF', 'Giz',         2),
  ('#B13F16', 'Ferrugem',    3),
  ('#6D9CB7', 'Azul névoa',  4),
  ('#D0C0C9', 'Malva',       5),
  ('#74B69D', 'Sálvia',      6)
on conflict (color) do update set name = excluded.name, sort_order = excluded.sort_order;

-- ---------------------------------------------------------------------
-- Atualizar o próprio perfil
-- ---------------------------------------------------------------------
create or replace function public.update_my_profile(
  p_full_name   text default null,
  p_frame_color text default null,
  p_grip_color  text default null,
  p_avatar_tone smallint default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_row  public.profiles%rowtype;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  if p_frame_color is not null
     and not exists (select 1 from public.racket_palette rp
                     where rp.color = upper(p_frame_color) and rp.for_frame) then
    raise exception 'Cor de aro fora da paleta: %', p_frame_color using errcode = 'NQ019';
  end if;

  if p_grip_color is not null
     and not exists (select 1 from public.racket_palette rp
                     where rp.color = upper(p_grip_color) and rp.for_grip) then
    raise exception 'Cor de grip fora da paleta: %', p_grip_color using errcode = 'NQ019';
  end if;

  update public.profiles p
     set full_name          = coalesce(nullif(trim(p_full_name), ''), p.full_name),
         racket_frame_color = coalesce(upper(p_frame_color), p.racket_frame_color),
         racket_grip_color  = coalesce(upper(p_grip_color), p.racket_grip_color),
         avatar_tone        = coalesce(p_avatar_tone, p.avatar_tone)
   where p.id = v_user
  returning * into v_row;

  return jsonb_build_object(
    'user_id',            v_row.id,
    'username',           v_row.username,
    'full_name',          v_row.full_name,
    'initials',           public.initials_of(v_row.full_name),
    'avatar_tone',        v_row.avatar_tone,
    'racket_frame_color', v_row.racket_frame_color,
    'racket_grip_color',  v_row.racket_grip_color
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Buscar parceiro, com disponibilidade
--
-- O protótipo mostra cada candidato como "Disponível · @handle" ou
-- "Na fila · Quadra 04 — indisponível", e bloqueia a seleção. A
-- disponibilidade vem junto para a tela não fazer N consultas.
-- ---------------------------------------------------------------------
create or replace function public.search_partners(
  p_query text default null,
  p_limit integer default 20
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with needle as (
    select regexp_replace(lower(trim(coalesce(p_query, ''))), '^@', '') as q
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'user_id',            s.id,
        'username',           s.username,
        'handle',             '@' || s.username,
        'full_name',          s.full_name,
        'initials',           public.initials_of(coalesce(s.full_name, s.username::text)),
        'avatar_tone',        s.avatar_tone,
        'racket_frame_color', s.racket_frame_color,
        'racket_grip_color',  s.racket_grip_color,
        'state',              s.st ->> 'state',
        'available',          (s.st ->> 'state') = 'free',
        'where',              s.st ->> 'where'
      )
      order by (s.st ->> 'state') = 'free' desc, s.full_name, s.username
    ),
    '[]'::jsonb
  )
  from (
    select p.id, p.username, p.full_name, p.avatar_tone,
           p.racket_frame_color, p.racket_grip_color,
           public.player_state(p.id) as st
    from public.profiles p, needle n
    where p.id <> auth.uid()
      and p.role = 'player'
      and (
        n.q = ''
        or p.username ilike '%' || n.q || '%'
        or p.full_name ilike '%' || n.q || '%'
      )
    order by p.full_name, p.username
    limit least(greatest(coalesce(p_limit, 20), 1), 50)
  ) s;
$$;

comment on function public.search_partners(text, integer) is
  'Candidatos a parceiro de dupla, com disponibilidade (free/queued/playing).';

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
alter table public.racket_palette enable row level security;

drop policy if exists "paleta: leitura pública" on public.racket_palette;
create policy "paleta: leitura pública"
  on public.racket_palette for select
  to anon, authenticated
  using (true);

revoke all on public.racket_palette from anon, authenticated;
grant select on public.racket_palette to anon, authenticated;

grant execute on function public.update_my_profile(text, text, text, smallint) to authenticated;
grant execute on function public.search_partners(text, integer)                to authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20261008130400_screens.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 3
-- 19. Leituras das telas do protótipo
--
-- Uma RPC por tela, para cada uma resolver com uma chamada só — o
-- critério de 2s no 3G não sobrevive a cinco round-trips.
--
--   parks_overview   -> lista de parques
--   park_screen      -> home do parque (resumo + quadras)
--   court_screen     -> tela da quadra (placar + fila em pilha)
--   match_state      -> placar de uma partida
--   my_queue_state   -> o cartão "você está na fila" / chamada
-- =====================================================================

-- ---------------------------------------------------------------------
-- A view de posições volta a contar "existe partida ao vivo" como UM
-- time à frente. Antes contava entradas com status 'playing' — e agora
-- uma partida tem dois lados, o que faria o próximo da fila achar que
-- tem dois times na frente.
-- ---------------------------------------------------------------------
drop view if exists public.queue_positions;

create view public.queue_positions
with (security_invoker = true) as
select
  e.id        as entry_id,
  e.court_id,
  e.mode,
  e.status,
  e.joined_at,
  e.queue_number,
  row_number() over (partition by e.court_id order by e.queue_number) as position,
  (
    select count(*)
    from public.matches mt
    where mt.court_id = e.court_id and mt.ended_at is null
  ) as playing_count
from public.queue_entries e
where e.status in ('waiting', 'ready');

comment on view public.queue_positions is
  'Posição de cada time aguardando, por ordem de chegada. '
  'playing_count é 0 ou 1: a partida em andamento conta como um time à frente.';

grant select on public.queue_positions to authenticated;

-- ---------------------------------------------------------------------
-- Placar de uma partida
-- ---------------------------------------------------------------------
create or replace function public.match_state(p_match_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_match public.matches%rowtype;
  v_court public.courts%rowtype;
  v_a     jsonb;
  v_b     jsonb;
begin
  select * into v_match from public.matches mt where mt.id = p_match_id;
  if not found then
    raise exception 'Partida não encontrada' using errcode = 'NQ018';
  end if;

  select * into v_court from public.courts c where c.id = v_match.court_id;

  v_a := public.match_side_players(v_match.side_a_entry_id);
  v_b := case
           when v_match.side_b_entry_id is null then '[]'::jsonb
           else public.match_side_players(v_match.side_b_entry_id)
         end;

  return jsonb_build_object(
    'match_id',     v_match.id,
    'court_id',     v_match.court_id,
    'court_name',   public.court_label(v_court.court_number),
    'mode',         v_match.mode,
    'slot_minutes', v_match.slot_minutes,
    'started_at',   v_match.started_at,
    'expires_at',   v_match.expires_at,
    'ended_at',     v_match.ended_at,
    'winner_side',  v_match.winner_side,
    'end_reason',   v_match.end_reason,
    'is_live',      v_match.ended_at is null,
    'elapsed_seconds',   greatest(0, floor(extract(epoch from (
                           coalesce(v_match.ended_at, now()) - v_match.started_at)))::integer),
    'remaining_seconds', case
                           when v_match.ended_at is not null then 0
                           else greatest(0, floor(extract(epoch from (
                             v_match.expires_at - now())))::integer)
                         end,
    'side_a', jsonb_build_object(
      'entry_id', v_match.side_a_entry_id,
      'role',     'challenger',
      'players',  v_a
    ),
    'side_b', jsonb_build_object(
      'entry_id', v_match.side_b_entry_id,
      'role',     'holder',
      'open',     v_match.side_b_entry_id is null,
      'players',  v_b
    )
  );
end;
$$;

-- ---------------------------------------------------------------------
-- A fila como pilha de raquetes
--
-- Cada item traz as raquetes dos times à frente (no máximo 5, como no
-- protótipo, mais a contagem do que sobra) e a cor da própria.
-- ---------------------------------------------------------------------
create or replace function public.court_queue_items(p_court_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with court as (
    select c.id, c.slot_minutes,
           (select count(*) from public.matches mt
             where mt.court_id = c.id and mt.ended_at is null) as live,
           (select greatest(0, floor(extract(epoch from (mt.expires_at - now())))::integer)
              from public.matches mt
             where mt.court_id = c.id and mt.ended_at is null
             limit 1) as remaining
    from public.courts c where c.id = p_court_id
  ),
  q as (
    select qp.entry_id, qp.position, qp.mode, qp.status, qp.joined_at,
           e.call_expires_at,
           -- A raquete do time é a do dono da inscrição.
           (select jsonb_build_object(
                     'frame', pr.racket_frame_color,
                     'grip',  pr.racket_grip_color)
              from public.queue_entry_members mm
              join public.profiles pr on pr.id = mm.user_id
             where mm.entry_id = qp.entry_id and mm.role = 'owner'
             limit 1) as racket,
           public.match_side_players(qp.entry_id) as players
    from public.queue_positions qp
    join public.queue_entries e on e.id = qp.entry_id
    where qp.court_id = p_court_id
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'entry_id',    q.entry_id,
        'position',    q.position,
        'position_label', q.position || 'º',
        'mode',        q.mode,
        'mode_label',  case when q.mode = 'double' then 'Duplas 2x2' else 'Simples 1x1' end,
        'status',      q.status,
        'is_called',   q.status = 'ready',
        'call_expires_at', q.call_expires_at,
        'joined_at',   q.joined_at,
        'teams_ahead', (q.position - 1) + (select live from court),
        'is_mine',     exists (
                         select 1 from public.queue_entry_members mm
                         where mm.entry_id = q.entry_id and mm.user_id = auth.uid()
                       ),
        'racket',      q.racket,
        'players',     q.players,
        'team_label',  (
          select string_agg(pl ->> 'short_name', ' + ' order by ord)
          from jsonb_array_elements(q.players) with ordinality as t(pl, ord)
        ),
        -- Raquetes à frente, no máximo 5, mais quantas sobraram atrás.
        'stack', (
          select coalesce(jsonb_agg(s.racket order by s.position), '[]'::jsonb)
          from (
            select q2.racket, q2.position
            from q q2
            where q2.position <= q.position
            order by q2.position desc
            limit 5
          ) s
        ),
        'stack_more', greatest(q.position - 5, 0),
        'eta_seconds', (select remaining from court) + (q.position - 1) * (select slot_minutes from court) * 60
      )
      order by q.position
    ),
    '[]'::jsonb
  )
  from q;
$$;

-- ---------------------------------------------------------------------
-- Tela da quadra
-- ---------------------------------------------------------------------
create or replace function public.court_screen(p_court_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_court  public.courts%rowtype;
  v_park   public.parks%rowtype;
  v_match  uuid;
  v_items  jsonb;
  v_queue  integer;
  v_rem    integer := 0;
  v_mine   jsonb;
begin
  select * into v_court from public.courts c where c.id = p_court_id;
  if not found then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;

  select * into v_park from public.parks pk where pk.id = v_court.park_id;

  select mt.id,
         greatest(0, floor(extract(epoch from (mt.expires_at - now())))::integer)
  into v_match, v_rem
  from public.matches mt
  where mt.court_id = p_court_id and mt.ended_at is null
  limit 1;

  v_items := public.court_queue_items(p_court_id);
  v_queue := jsonb_array_length(v_items);

  select i into v_mine
  from jsonb_array_elements(v_items) i
  where (i ->> 'is_mine')::boolean
  limit 1;

  return jsonb_build_object(
    'court', jsonb_build_object(
      'id',            v_court.id,
      'name',          public.court_label(v_court.court_number),
      'number',        v_court.court_number,
      'surface',       v_court.surface,
      'surface_label', case v_court.surface
                         when 'clay'  then 'Saibro'
                         when 'hard'  then 'Rápida'
                         else 'Grama'
                       end,
      'status',        v_court.status,
      'is_active',     v_court.is_active,
      'slot_minutes',  v_court.slot_minutes,
      'call_window_seconds', v_court.call_window_seconds,
      'checkin_methods', (
        select coalesce(jsonb_agg(m order by m), '[]'::jsonb)
        from (
          select 'qr'::text as m where v_court.has_qr_code
          union all
          select 'nfc'::text where v_court.has_nfc_tag
        ) s
      ),
      'latitude',      v_court.latitude,
      'longitude',     v_court.longitude,
      'rating_avg',    v_court.rating_avg,
      'rating_count',  v_court.rating_count,
      'cover_photo_path', v_court.cover_photo_path
    ),
    'park', jsonb_build_object(
      'id',       v_park.id,
      'name',     v_park.name,
      'district', v_park.district
    ),
    'match',        case when v_match is null then null else public.match_state(v_match) end,
    'is_live',      v_match is not null,
    'status_text',  case when v_match is not null then 'Em jogo' else 'Livre' end,
    'players_line', case
                      when v_match is null then 'Sem jogo agora — check-in libera a quadra'
                      else (
                        select coalesce(string_agg(side, ' × '), '')
                        from (
                          select (
                            select coalesce(string_agg(pl ->> 'short_name', ' / ' order by ord), 'Adversário livre')
                            from jsonb_array_elements(
                              public.match_state(v_match) -> s.key -> 'players'
                            ) with ordinality as t(pl, ord)
                          ) as side
                          from (values ('side_a', 1), ('side_b', 2)) as s(key, ord)
                          order by s.ord
                        ) sides
                      )
                    end,
    'queue',        v_items,
    'queue_length', v_queue,
    'queue_text',   case
                      when v_queue = 0 then 'Fila vazia'
                      else v_queue || ' na espera'
                    end,
    'remaining_seconds', coalesce(v_rem, 0),
    'total_wait_seconds', coalesce(v_rem, 0) + v_queue * v_court.slot_minutes * 60,
    'next_position_label', (v_queue + 1) || 'º',
    'my_entry',     v_mine,
    -- A quadra aceita entradas (fato da quadra)
    'court_accepting', v_court.is_active and v_court.status <> 'unavailable',
    -- Eu posso entrar agora (fato do jogador: uma fila por pessoa)
    'can_join',     v_court.is_active
                    and v_court.status <> 'unavailable'
                    and (public.player_state(auth.uid()) ->> 'state') = 'free',
    'my_state',     public.player_state(auth.uid()),
    'generated_at', now()
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Home do parque
-- ---------------------------------------------------------------------
create or replace function public.park_screen(p_park_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_park   public.parks%rowtype;
  v_courts jsonb;
begin
  select * into v_park from public.parks pk where pk.id = p_park_id;
  if not found then
    raise exception 'Parque não encontrado' using errcode = 'NQ020';
  end if;

  select coalesce(jsonb_agg(s.screen order by s.court_number), '[]'::jsonb)
  into v_courts
  from (
    select c.court_number, public.court_screen(c.id) as screen
    from public.courts c
    where c.park_id = p_park_id and c.is_active
  ) s;

  return jsonb_build_object(
    'park', jsonb_build_object(
      'id',         v_park.id,
      'slug',       v_park.slug,
      'name',       v_park.name,
      'district',   v_park.district,
      'photo_url',  v_park.photo_url,
      'photo_alt',  v_park.photo_alt,
      'tone_color', v_park.tone_color,
      'latitude',   v_park.latitude,
      'longitude',  v_park.longitude
    ),
    'summary', jsonb_build_object(
      'courts', jsonb_array_length(v_courts),
      'live',   (select count(*) from jsonb_array_elements(v_courts) c
                  where (c -> 'is_live')::boolean),
      'queued', (select coalesce(sum((c ->> 'queue_length')::integer), 0)
                   from jsonb_array_elements(v_courts) c)
    ),
    'courts',   v_courts,
    'my_state', public.player_state(auth.uid()),
    'generated_at', now()
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Lista de parques
-- ---------------------------------------------------------------------
create or replace function public.parks_overview(
  p_latitude      double precision default null,
  p_longitude     double precision default null,
  p_radius_meters double precision default null,
  p_limit         integer default 50
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with my as (
    select public.player_state(auth.uid()) as st
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'park_id',    s.id,
        'slug',       s.slug,
        'name',       s.name,
        'district',   s.district,
        'photo_url',  s.photo_url,
        'photo_alt',  s.photo_alt,
        'tone_color', s.tone_color,
        'latitude',   s.latitude,
        'longitude',  s.longitude,
        'distance_meters', s.distance_meters,
        'courts_count', s.courts_count,
        'live_count',   s.live_count,
        'queue_count',  s.queue_count,
        'any_live',     s.live_count > 0,
        'live_text',    case
                          when s.live_count = 0 then 'Quadras livres'
                          when s.live_count = 1 then 'Ao vivo · 1 jogo'
                          else 'Ao vivo · ' || s.live_count || ' jogos'
                        end,
        'surfaces',     s.surfaces,
        'is_mine',      s.is_mine
      )
      order by coalesce(s.distance_meters, 0), s.name
    ),
    '[]'::jsonb
  )
  from (
    select
      pk.id, pk.slug, pk.name, pk.district, pk.photo_url, pk.photo_alt,
      pk.tone_color, pk.latitude, pk.longitude,
      case
        when p_latitude is null or p_longitude is null then null
        else public.haversine_meters(p_latitude, p_longitude, pk.latitude, pk.longitude)
      end as distance_meters,
      (select count(*)::integer from public.courts c
        where c.park_id = pk.id and c.is_active) as courts_count,
      (select count(*)::integer from public.courts c
         join public.matches mt on mt.court_id = c.id and mt.ended_at is null
        where c.park_id = pk.id and c.is_active) as live_count,
      (select count(*)::integer from public.courts c
         join public.queue_entries e on e.court_id = c.id
        where c.park_id = pk.id and c.is_active
          and e.status in ('waiting', 'ready')) as queue_count,
      (select coalesce(jsonb_agg(distinct jsonb_build_object(
                 'surface', c.surface,
                 'label', case c.surface
                            when 'clay' then 'Saibro'
                            when 'hard' then 'Rápida'
                            else 'Grama'
                          end)), '[]'::jsonb)
         from public.courts c where c.park_id = pk.id and c.is_active) as surfaces,
      coalesce(((select st from my) ->> 'park_id') = pk.id::text, false) as is_mine
    from public.parks pk
    where pk.is_active
      and (
        p_latitude is null or p_longitude is null or p_radius_meters is null
        or public.haversine_meters(p_latitude, p_longitude, pk.latitude, pk.longitude) <= p_radius_meters
      )
    limit least(greatest(coalesce(p_limit, 50), 1), 200)
  ) s;
$$;

-- ---------------------------------------------------------------------
-- O cartão "você está na fila" e a chamada
-- ---------------------------------------------------------------------
create or replace function public.my_queue_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user   uuid := auth.uid();
  v_entry  public.queue_entries%rowtype;
  v_court  public.courts%rowtype;
  v_park   public.parks%rowtype;
  v_item   jsonb;
  v_match  uuid;
begin
  if v_user is null then
    return jsonb_build_object('state', 'free');
  end if;

  select e.* into v_entry
  from public.queue_entry_members m
  join public.queue_entries e on e.id = m.entry_id
  where m.user_id = v_user and m.is_active
  limit 1;

  if not found then
    return jsonb_build_object('state', 'free');
  end if;

  select * into v_court from public.courts c where c.id = v_entry.court_id;
  select * into v_park  from public.parks pk where pk.id = v_court.park_id;

  select i into v_item
  from jsonb_array_elements(public.court_queue_items(v_entry.court_id)) i
  where (i ->> 'entry_id')::uuid = v_entry.id;

  select mt.id into v_match
  from public.matches mt
  where mt.court_id = v_entry.court_id
    and mt.ended_at is null
    and v_entry.id in (mt.side_a_entry_id, mt.side_b_entry_id);

  return jsonb_build_object(
    'state',      case
                    when v_entry.status = 'playing' then 'playing'
                    when v_entry.status = 'ready'   then 'called'
                    else 'queued'
                  end,
    'entry_id',   v_entry.id,
    'mode',       v_entry.mode,
    'court_id',   v_court.id,
    'court_name', public.court_label(v_court.court_number),
    'park_id',    v_park.id,
    'park_name',  v_park.name,
    'position',        (v_item ->> 'position')::integer,
    'position_label',  v_item ->> 'position_label',
    'teams_ahead',     (v_item ->> 'teams_ahead')::integer,
    'eta_seconds',     (v_item ->> 'eta_seconds')::integer,
    'stack',           v_item -> 'stack',
    'stack_more',      (v_item ->> 'stack_more')::integer,
    'players',         public.match_side_players(v_entry.id),
    -- Chamado: quanto resta para fazer o check-in
    'call_expires_at',      v_entry.call_expires_at,
    'call_remaining_seconds', case
                                when v_entry.status <> 'ready' or v_entry.call_expires_at is null then null
                                else greatest(0, floor(extract(epoch from
                                       (v_entry.call_expires_at - now())))::integer)
                              end,
    'match',      case when v_match is null then null else public.match_state(v_match) end,
    'generated_at', now()
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Notificações: a chamada é o gatilho de "É a sua vez!"
-- ---------------------------------------------------------------------
create or replace function public.refresh_queue_notifications(p_court_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court    public.courts%rowtype;
  v_row      record;
  v_ahead    integer;
  v_inserted integer;
  v_label    text;
begin
  select * into v_court from public.courts c where c.id = p_court_id;
  if not found then
    return;
  end if;

  v_label := public.court_label(v_court.court_number);

  for v_row in
    select qp.entry_id, qp.position, qp.playing_count, qp.status, e.ready_notified_at
    from public.queue_positions qp
    join public.queue_entries e on e.id = qp.entry_id
    where qp.court_id = p_court_id and qp.position <= 2
  loop
    v_ahead := (v_row.position - 1) + v_row.playing_count;

    -- Chamado: é a vez, e o check-in tem prazo.
    if v_row.status = 'ready' then
      perform public.enqueue_team_notification(
        v_row.entry_id,
        'queue_turn',
        'É a sua vez!',
        format('Faça o check-in na %s em até %s minutos.',
               v_label, greatest(1, v_court.call_window_seconds / 60)),
        jsonb_build_object('court_id', p_court_id, 'entry_id', v_row.entry_id, 'teams_ahead', 0)
      );
    elsif v_ahead = 1 then
      v_inserted := public.enqueue_team_notification(
        v_row.entry_id,
        'queue_almost_ready',
        'Prepare-se!',
        format('Falta 1 time para a sua vez na %s.', v_label),
        jsonb_build_object('court_id', p_court_id, 'entry_id', v_row.entry_id, 'teams_ahead', 1)
      );

      if v_inserted > 0 and v_row.ready_notified_at is null then
        update public.queue_entries set ready_notified_at = now() where id = v_row.entry_id;
      end if;
    end if;
  end loop;
end;
$$;

-- A chamada e o fim da partida também mexem na fila.
drop trigger if exists matches_notify on public.matches;
create trigger matches_notify
  after insert or update of ended_at or delete on public.matches
  for each row execute function public.queue_entries_notify_trigger();

-- ---------------------------------------------------------------------
-- Manutenção passa a avançar as filas
-- ---------------------------------------------------------------------
create or replace function public.run_maintenance()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_expired   integer;
  v_purged    integer;
  v_snapshots integer;
  v_advanced  jsonb;
begin
  v_advanced  := public.advance_expired_queues();
  v_expired   := public.expire_stale_queue_entries();
  v_purged    := public.purge_expired_scan_tokens();
  v_snapshots := public.capture_occupancy_snapshots();

  delete from public.notification_outbox
  where status in ('sent', 'failed') and created_at < now() - interval '30 days';

  delete from public.court_occupancy_snapshots
  where captured_at < now() - interval '90 days';

  return jsonb_build_object(
    'matches_closed',     v_advanced -> 'matches_closed',
    'calls_expired',      v_advanced -> 'entries_expired',
    'expired_entries',    v_expired,
    'purged_scan_tokens', v_purged,
    'occupancy_snapshots', v_snapshots,
    'ran_at', now()
  );
end;
$$;

revoke all on function public.run_maintenance() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Permissões das leituras
-- ---------------------------------------------------------------------
grant execute on function public.match_state(uuid)            to anon, authenticated;
grant execute on function public.court_queue_items(uuid)      to anon, authenticated;
grant execute on function public.court_screen(uuid)           to anon, authenticated;
grant execute on function public.park_screen(uuid)            to anon, authenticated;
grant execute on function public.my_queue_state()             to authenticated;
grant execute on function public.parks_overview(double precision, double precision, double precision, integer)
  to anon, authenticated;

-- ---------------------------------------------------------------------
-- court_queue: mantida para quem já consome (Edge Function queue-status
-- e o app da Sprint 1), agora lendo a partida da tabela matches. Sem
-- isso ela reportaria "Livre" com os dois lados em quadra.
--
-- Telas novas devem usar court_screen, que traz placar, pilha e parque.
-- ---------------------------------------------------------------------
create or replace function public.court_queue(p_court_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_screen jsonb;
begin
  v_screen := public.court_screen(p_court_id);

  return jsonb_build_object(
    'court', jsonb_build_object(
      'id',                    v_screen -> 'court' -> 'id',
      'slug',                  (select c.slug from public.courts c where c.id = p_court_id),
      'name',                  v_screen -> 'court' -> 'name',
      'address',               (select c.address from public.courts c where c.id = p_court_id),
      'status',                v_screen -> 'court' -> 'status',
      'is_active',             v_screen -> 'court' -> 'is_active',
      'latitude',              v_screen -> 'court' -> 'latitude',
      'longitude',             v_screen -> 'court' -> 'longitude',
      'average_match_minutes', v_screen -> 'court' -> 'slot_minutes',
      'photo_url',             (select c.photo_url from public.courts c where c.id = p_court_id)
    ),
    'can_join',      v_screen -> 'court_accepting',
    'teams_waiting', v_screen -> 'queue_length',
    'current_match', case
                       when (v_screen ->> 'is_live')::boolean then jsonb_build_object(
                         'entry_id',   v_screen -> 'match' -> 'side_a' -> 'entry_id',
                         'mode',       v_screen -> 'match' -> 'mode',
                         'started_at', v_screen -> 'match' -> 'started_at',
                         'players',    v_screen -> 'match' -> 'side_a' -> 'players'
                       )
                       else null
                     end,
    'current_match_remaining_minutes', case
                                         when (v_screen ->> 'is_live')::boolean
                                           then ceil((v_screen ->> 'remaining_seconds')::numeric / 60)::integer
                                         else null
                                       end,
    'queue', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'entry_id',               i -> 'entry_id',
               'mode',                   i -> 'mode',
               'status',                 i -> 'status',
               'joined_at',              i -> 'joined_at',
               'position',               i -> 'position',
               'teams_ahead',            i -> 'teams_ahead',
               'estimated_wait_minutes', ceil((i ->> 'eta_seconds')::numeric / 60)::integer,
               'players',                i -> 'players'
             ) order by (i ->> 'position')::integer), '[]'::jsonb)
      from jsonb_array_elements(v_screen -> 'queue') i
    ),
    'generated_at', v_screen -> 'generated_at'
  );
end;
$$;

grant execute on function public.court_queue(uuid) to anon, authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20261008130500_nfc.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 3
-- 20. Check-in por NFC, ao lado do QR Code
--
-- O protótipo oferece as duas formas na mesma tela: "Aponte para o QR"
-- e "Aproxime do totem". A tag NFC grava exatamente a mesma URL
-- assinada do QR (registro NDEF do tipo URI), então a validação é a
-- mesma — o que muda é só por onde o payload chegou.
--
-- Guardar o método serve para operação: se um totem for arrancado ou
-- clonado, dá para ver por onde vieram os check-ins daquela quadra.
-- =====================================================================

do $$ begin
  create type public.scan_method as enum ('qr', 'nfc');
exception when duplicate_object then null; end $$;

alter table public.scan_tokens add column if not exists method public.scan_method;

update public.scan_tokens set method = 'qr' where method is null;

alter table public.scan_tokens alter column method set default 'qr';
alter table public.scan_tokens alter column method set not null;

comment on column public.scan_tokens.method is
  'Por onde o payload chegou: QR Code impresso ou tag NFC.';

create index if not exists scan_tokens_method_idx
  on public.scan_tokens (court_id, method, created_at desc);

-- Quais métodos cada quadra oferece — a tela esconde a aba que não
-- existe naquela quadra em vez de oferecer um totem inexistente.
alter table public.courts add column if not exists has_qr_code boolean not null default true;
alter table public.courts add column if not exists has_nfc_tag boolean not null default false;

comment on column public.courts.has_nfc_tag is
  'Se existe totem NFC instalado nesta quadra.';

do $$ begin
  alter table public.courts
    add constraint courts_needs_one_checkin_method
    check (has_qr_code or has_nfc_tag);
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- Uso dos métodos por quadra (operação)
-- ---------------------------------------------------------------------
create or replace function public.court_checkin_methods(p_court_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'court_id', c.id,
    'qr',  jsonb_build_object(
      'available', c.has_qr_code,
      'scans_7d', (select count(*) from public.scan_tokens t
                    where t.court_id = c.id and t.method = 'qr'
                      and t.created_at > now() - interval '7 days')
    ),
    'nfc', jsonb_build_object(
      'available', c.has_nfc_tag,
      'scans_7d', (select count(*) from public.scan_tokens t
                    where t.court_id = c.id and t.method = 'nfc'
                      and t.created_at > now() - interval '7 days')
    )
  )
  from public.courts c
  where c.id = p_court_id;
$$;

grant execute on function public.court_checkin_methods(uuid) to authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20261009120000_profile_summary_racket.sql
-- ####################################################################

-- =====================================================================
-- A tela de perfil precisa das cores da raquete e do tom do avatar.
--
-- my_profile_summary() nasceu na Sprint 2, antes de a Sprint 3 criar as
-- colunas. Sem elas na resposta, a tela abria sempre com a raquete
-- padrão e descartava, na primeira edição, o que o jogador já tinha
-- escolhido. Aqui ela passa a devolver o que o app precisa para
-- desenhar o jogador do jeito que ele se configurou.
-- =====================================================================

create or replace function public.my_profile_summary()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'profile', (
      select jsonb_build_object(
        'user_id',            p.id,
        'username',           p.username,
        'full_name',          p.full_name,
        'email',              p.email,
        'avatar_url',         p.avatar_url,
        'role',               p.role,
        'created_at',         p.created_at,
        'avatar_tone',        p.avatar_tone,
        'racket_frame_color', p.racket_frame_color,
        'racket_grip_color',  p.racket_grip_color
      )
      from public.profiles p where p.id = auth.uid()
    ),
    'stats', (
      select jsonb_build_object(
        'matches_played', count(*)::integer,
        'minutes_played', coalesce(sum(
          greatest(round(extract(epoch from (e.ended_at - e.started_at)) / 60)::integer, 0)
        ), 0)::integer,
        'courts_visited', count(distinct e.court_id)::integer,
        'last_match_at',  max(e.ended_at)
      )
      from public.queue_entry_members m
      join public.queue_entries e on e.id = m.entry_id
      where m.user_id = auth.uid() and e.status = 'done' and e.ended_at is not null
    ),
    'active_entries', public.my_active_entries()
  );
$$;

comment on function public.my_profile_summary() is
  'Uma chamada para a tela de perfil: dados, raquete, estatísticas e filas ativas.';

revoke all on function public.my_profile_summary() from public;
grant execute on function public.my_profile_summary() to authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20261010120000_admin.sql
-- ####################################################################

-- =====================================================================
-- NEQST — administração
--
-- O modelo de papéis já existia (player / staff / admin) e o RLS já
-- dava ao admin o controle de parques, quadras e perfis. Faltavam três
-- coisas: garantir que exista no máximo UM admin, um caminho seguro
-- para criar o primeiro, e as RPCs que a tela /admin usa.
--
-- Nada aqui permite que alguém se promova: `promote_to_admin` só é
-- executável pelo service_role (o SQL Editor do painel), e a política
-- "profiles: dono atualiza" continua exigindo que o papel fique igual
-- ao que já era.
-- =====================================================================

-- ---------------------------------------------------------------------
-- No máximo um admin
--
-- Índice único sobre uma constante, restrito às linhas de admin: a
-- segunda tentativa de criar um admin falha no banco, não na aplicação.
-- ---------------------------------------------------------------------
create unique index if not exists profiles_single_admin_idx
  on public.profiles ((true))
  where role = 'admin'::public.app_role;

comment on index public.profiles_single_admin_idx is
  'Garante um único administrador. Para trocar de admin, rebaixe o atual antes.';

-- ---------------------------------------------------------------------
-- Criar o primeiro admin
--
-- Executada do SQL Editor (service_role). Deliberadamente NÃO é
-- concedida a `authenticated`: se fosse, qualquer pessoa logada
-- poderia se promover.
-- ---------------------------------------------------------------------
create or replace function public.promote_to_admin(p_email text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id      uuid;
  v_current uuid;
begin
  select id into v_id from public.profiles where lower(email) = lower(trim(p_email));

  if v_id is null then
    raise exception 'Nenhum perfil com o e-mail %. Crie o usuário em Authentication > Users primeiro.', p_email
      using errcode = 'NQ021';
  end if;

  select id into v_current from public.profiles where role = 'admin'::public.app_role;

  if v_current is not null and v_current <> v_id then
    raise exception 'Já existe um admin. Rebaixe-o antes: update public.profiles set role = ''player'' where id = ''%'';', v_current
      using errcode = 'NQ022';
  end if;

  update public.profiles set role = 'admin'::public.app_role where id = v_id;

  return jsonb_build_object('user_id', v_id, 'email', p_email, 'role', 'admin');
end;
$$;

comment on function public.promote_to_admin(text) is
  'Promove um perfil a admin. Só pelo SQL Editor — nunca exposta ao app.';

revoke all on function public.promote_to_admin(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Slug a partir do nome, sem colidir com o que já existe
-- ---------------------------------------------------------------------
-- `unaccent` é uma extensão opcional; esta tradução cobre o português
-- sem depender dela.
create or replace function public.unaccent_text(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select translate(
    p_text,
    'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
    'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCN'
  );
$$;

create or replace function public.slugify(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(
    trim(both '-' from
      regexp_replace(
        lower(public.unaccent_text(coalesce(p_text, ''))),
        '[^a-z0-9]+', '-', 'g'
      )
    ),
    ''
  );
$$;

create or replace function public.unique_slug(p_table text, p_base text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_base  text := coalesce(public.slugify(p_base), 'item');
  v_slug  text := v_base;
  v_n     integer := 1;
  v_taken boolean;
begin
  -- Mínimo de 3 caracteres (as duas tabelas exigem isso no check).
  if char_length(v_base) < 3 then
    v_base := v_base || '-nq';
    v_slug := v_base;
  end if;

  loop
    if p_table = 'parks' then
      select exists(select 1 from public.parks where slug = v_slug) into v_taken;
    else
      select exists(select 1 from public.courts where slug = v_slug) into v_taken;
    end if;

    exit when not v_taken;

    v_n := v_n + 1;
    v_slug := left(v_base, 55) || '-' || v_n;
  end loop;

  return v_slug;
end;
$$;

-- ---------------------------------------------------------------------
-- Guarda comum das RPCs de admin
-- ---------------------------------------------------------------------
create or replace function public.require_admin()
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Ação restrita ao administrador.' using errcode = 'NQ023';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Tela /admin: parques com as quadras
-- ---------------------------------------------------------------------
create or replace function public.admin_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.require_admin();

  return jsonb_build_object(
    'parks', coalesce((
      select jsonb_agg(p order by p.name)
      from (
        select jsonb_build_object(
          'id',        pk.id,
          'slug',      pk.slug::text,
          'name',      pk.name,
          'district',  pk.district,
          'city',      pk.city,
          'latitude',  pk.latitude,
          'longitude', pk.longitude,
          'tone_color', pk.tone_color,
          'photo_alt', pk.photo_alt,
          'is_active', pk.is_active,
          'courts', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'id',            c.id,
                'slug',          c.slug::text,
                'name',          c.name,
                'court_number',  c.court_number,
                'surface',       c.surface,
                'surface_label', case c.surface
                                   when 'clay' then 'Saibro'
                                   when 'hard' then 'Rápida'
                                   else 'Grama'
                                 end,
                'latitude',      c.latitude,
                'longitude',     c.longitude,
                'slot_minutes',  c.slot_minutes,
                'is_active',     c.is_active,
                'status',        c.status,
                'has_qr_code',   c.has_qr_code,
                'has_nfc_tag',   c.has_nfc_tag,
                'queue_length',  (
                  select count(*) from public.queue_entries q
                  where q.court_id = c.id and q.status in ('waiting', 'ready')
                )
              ) order by c.court_number
            )
            from public.courts c where c.park_id = pk.id
          ), '[]'::jsonb)
        ) as p, pk.name
        from public.parks pk
      ) p
    ), '[]'::jsonb),
    'totals', (
      select jsonb_build_object(
        'parks',  (select count(*) from public.parks),
        'courts', (select count(*) from public.courts),
        'users',  (select count(*) from public.profiles)
      )
    )
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Criar / editar parque
-- ---------------------------------------------------------------------
create or replace function public.admin_upsert_park(
  p_id        uuid    default null,
  p_name      text    default null,
  p_district  text    default null,
  p_city      text    default null,
  p_latitude  double precision default null,
  p_longitude double precision default null,
  p_tone_color text   default null,
  p_photo_alt text    default null,
  p_is_active boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_row public.parks;
begin
  perform public.require_admin();

  if p_id is null then
    if coalesce(trim(p_name), '') = '' then
      raise exception 'Informe o nome do parque.' using errcode = 'NQ024';
    end if;
    if p_latitude is null or p_longitude is null then
      raise exception 'Informe a localização do parque.' using errcode = 'NQ024';
    end if;

    insert into public.parks (slug, name, district, city, latitude, longitude, tone_color, photo_alt)
    values (
      public.unique_slug('parks', p_name),
      trim(p_name), nullif(trim(p_district), ''), nullif(trim(p_city), ''),
      p_latitude, p_longitude, nullif(trim(p_tone_color), ''), nullif(trim(p_photo_alt), '')
    )
    returning * into v_row;
  else
    update public.parks set
      name       = coalesce(nullif(trim(p_name), ''), name),
      district   = coalesce(nullif(trim(p_district), ''), district),
      city       = coalesce(nullif(trim(p_city), ''), city),
      latitude   = coalesce(p_latitude, latitude),
      longitude  = coalesce(p_longitude, longitude),
      tone_color = coalesce(nullif(trim(p_tone_color), ''), tone_color),
      photo_alt  = coalesce(nullif(trim(p_photo_alt), ''), photo_alt),
      is_active  = coalesce(p_is_active, is_active)
    where id = p_id
    returning * into v_row;

    if v_row.id is null then
      raise exception 'Parque não encontrado.' using errcode = 'NQ025';
    end if;
  end if;

  return to_jsonb(v_row);
end;
$$;

-- ---------------------------------------------------------------------
-- Criar / editar quadra
--
-- O número da quadra, quando não informado, é o próximo livre do
-- parque — é assim que o operador espera cadastrar ("mais uma quadra").
-- ---------------------------------------------------------------------
create or replace function public.admin_upsert_court(
  p_id           uuid    default null,
  p_park_id      uuid    default null,
  p_court_number smallint default null,
  p_surface      text    default null,
  p_name         text    default null,
  p_latitude     double precision default null,
  p_longitude    double precision default null,
  p_slot_minutes smallint default null,
  p_has_qr_code  boolean default null,
  p_has_nfc_tag  boolean default null,
  p_is_active    boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row    public.courts;
  v_park   public.parks;
  v_number smallint;
  v_name   text;
begin
  perform public.require_admin();

  if p_id is null then
    select * into v_park from public.parks where id = p_park_id;
    if v_park.id is null then
      raise exception 'Parque não encontrado.' using errcode = 'NQ025';
    end if;

    v_number := coalesce(
      p_court_number,
      (select coalesce(max(court_number), 0) + 1 from public.courts where park_id = v_park.id)::smallint
    );
    v_name := coalesce(nullif(trim(p_name), ''), 'Quadra ' || lpad(v_number::text, 2, '0'));

    insert into public.courts (
      park_id, court_number, surface, slug, name,
      latitude, longitude, city, slot_minutes, has_qr_code, has_nfc_tag
    )
    values (
      v_park.id, v_number,
      coalesce(p_surface, 'clay')::public.court_surface,
      public.unique_slug('courts', v_park.slug::text || '-q' || v_number),
      v_name,
      coalesce(p_latitude, v_park.latitude),
      coalesce(p_longitude, v_park.longitude),
      v_park.city,
      coalesce(p_slot_minutes, 40::smallint),
      coalesce(p_has_qr_code, true),
      coalesce(p_has_nfc_tag, false)
    )
    returning * into v_row;
  else
    update public.courts set
      court_number = coalesce(p_court_number, court_number),
      surface      = coalesce(p_surface::public.court_surface, surface),
      name         = coalesce(nullif(trim(p_name), ''), name),
      latitude     = coalesce(p_latitude, latitude),
      longitude    = coalesce(p_longitude, longitude),
      slot_minutes = coalesce(p_slot_minutes, slot_minutes),
      has_qr_code  = coalesce(p_has_qr_code, has_qr_code),
      has_nfc_tag  = coalesce(p_has_nfc_tag, has_nfc_tag),
      is_active    = coalesce(p_is_active, is_active)
    where id = p_id
    returning * into v_row;

    if v_row.id is null then
      raise exception 'Quadra não encontrada.' using errcode = 'NQ025';
    end if;
  end if;

  return to_jsonb(v_row);
end;
$$;

-- ---------------------------------------------------------------------
-- Usuários
-- ---------------------------------------------------------------------
create or replace function public.admin_users(
  p_query text default null,
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_q text := nullif(trim(coalesce(p_query, '')), '');
begin
  perform public.require_admin();

  return coalesce((
    select jsonb_agg(u order by u.created_at desc)
    from (
      select jsonb_build_object(
        'user_id',   p.id,
        'username',  p.username::text,
        'full_name', p.full_name,
        'email',     p.email,
        'role',      p.role,
        'initials',  public.initials_of(coalesce(p.full_name, p.username::text)),
        'created_at', p.created_at,
        'state',     public.player_state(p.id) ->> 'state'
      ) as u, p.created_at
      from public.profiles p
      where v_q is null
         or p.email ilike '%' || v_q || '%'
         or p.username::text ilike '%' || v_q || '%'
         or coalesce(p.full_name, '') ilike '%' || v_q || '%'
      order by p.created_at desc
      limit greatest(1, least(coalesce(p_limit, 50), 200))
    ) u
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------
-- Promover a staff ou rebaixar a player
--
-- `admin` fica de fora de propósito: o índice único já impediria o
-- segundo, e trocar de administrador é operação de banco, não de tela.
-- ---------------------------------------------------------------------
create or replace function public.admin_set_role(p_user_id uuid, p_role text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_row public.profiles;
begin
  perform public.require_admin();

  if p_role not in ('player', 'staff') then
    raise exception 'Papel inválido. Use player ou staff.' using errcode = 'NQ026';
  end if;

  if p_user_id = auth.uid() then
    raise exception 'Você não pode mudar o próprio papel.' using errcode = 'NQ026';
  end if;

  update public.profiles
     set role = p_role::public.app_role
   where id = p_user_id
  returning * into v_row;

  if v_row.id is null then
    raise exception 'Usuário não encontrado.' using errcode = 'NQ025';
  end if;

  return jsonb_build_object('user_id', v_row.id, 'role', v_row.role);
end;
$$;

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
revoke all on function public.admin_overview()                              from public;
revoke all on function public.admin_upsert_park(uuid, text, text, text, double precision, double precision, text, text, boolean) from public;
revoke all on function public.admin_upsert_court(uuid, uuid, smallint, text, text, double precision, double precision, smallint, boolean, boolean, boolean) from public;
revoke all on function public.admin_users(text, integer)                    from public;
revoke all on function public.admin_set_role(uuid, text)                    from public;
revoke all on function public.require_admin()                               from public;
revoke all on function public.unique_slug(text, text)                       from public;

grant execute on function public.admin_overview()                              to authenticated;
grant execute on function public.admin_upsert_park(uuid, text, text, text, double precision, double precision, text, text, boolean) to authenticated;
grant execute on function public.admin_upsert_court(uuid, uuid, smallint, text, text, double precision, double precision, smallint, boolean, boolean, boolean) to authenticated;
grant execute on function public.admin_users(text, integer)                    to authenticated;
grant execute on function public.admin_set_role(uuid, text)                    to authenticated;
grant execute on function public.require_admin()                               to authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20261011120000_admin_court_distance.sql
-- ####################################################################

-- =====================================================================
-- Raio de proximidade na tela de administração
--
-- `max_distance_meters` e `gps_tolerance_meters` decidem se a leitura
-- do QR é aceita. São eles que impedem alguém de entrar na fila de
-- casa — e são também o que trava um teste feito longe da quadra.
-- Estavam só no banco; agora o admin regula por quadra.
-- =====================================================================

-- O overview ganha os dois campos.
create or replace function public.admin_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.require_admin();

  return jsonb_build_object(
    'parks', coalesce((
      select jsonb_agg(p order by p.name)
      from (
        select jsonb_build_object(
          'id',        pk.id,
          'slug',      pk.slug::text,
          'name',      pk.name,
          'district',  pk.district,
          'city',      pk.city,
          'latitude',  pk.latitude,
          'longitude', pk.longitude,
          'tone_color', pk.tone_color,
          'photo_alt', pk.photo_alt,
          'is_active', pk.is_active,
          'courts', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'id',            c.id,
                'slug',          c.slug::text,
                'name',          c.name,
                'court_number',  c.court_number,
                'surface',       c.surface,
                'surface_label', case c.surface
                                   when 'clay' then 'Saibro'
                                   when 'hard' then 'Rápida'
                                   else 'Grama'
                                 end,
                'latitude',      c.latitude,
                'longitude',     c.longitude,
                'slot_minutes',  c.slot_minutes,
                'is_active',     c.is_active,
                'status',        c.status,
                'has_qr_code',   c.has_qr_code,
                'has_nfc_tag',   c.has_nfc_tag,
                'max_distance_meters',  c.max_distance_meters,
                'gps_tolerance_meters', c.gps_tolerance_meters,
                'qr_secret_version',    c.qr_secret_version,
                'queue_length',  (
                  select count(*) from public.queue_entries q
                  where q.court_id = c.id and q.status in ('waiting', 'ready')
                )
              ) order by c.court_number
            )
            from public.courts c where c.park_id = pk.id
          ), '[]'::jsonb)
        ) as p, pk.name
        from public.parks pk
      ) p
    ), '[]'::jsonb),
    'totals', (
      select jsonb_build_object(
        'parks',  (select count(*) from public.parks),
        'courts', (select count(*) from public.courts),
        'users',  (select count(*) from public.profiles)
      )
    )
  );
end;
$$;

-- A assinatura muda, então a antiga sai de cena antes.
drop function if exists public.admin_upsert_court(
  uuid, uuid, smallint, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean
);

create or replace function public.admin_upsert_court(
  p_id           uuid    default null,
  p_park_id      uuid    default null,
  p_court_number smallint default null,
  p_surface      text    default null,
  p_name         text    default null,
  p_latitude     double precision default null,
  p_longitude    double precision default null,
  p_slot_minutes smallint default null,
  p_has_qr_code  boolean default null,
  p_has_nfc_tag  boolean default null,
  p_is_active    boolean default null,
  p_max_distance_meters  integer default null,
  p_gps_tolerance_meters integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row    public.courts;
  v_park   public.parks;
  v_number smallint;
  v_name   text;
begin
  perform public.require_admin();

  if p_id is null then
    select * into v_park from public.parks where id = p_park_id;
    if v_park.id is null then
      raise exception 'Parque não encontrado.' using errcode = 'NQ025';
    end if;

    v_number := coalesce(
      p_court_number,
      (select coalesce(max(court_number), 0) + 1 from public.courts where park_id = v_park.id)::smallint
    );
    v_name := coalesce(nullif(trim(p_name), ''), 'Quadra ' || lpad(v_number::text, 2, '0'));

    insert into public.courts (
      park_id, court_number, surface, slug, name,
      latitude, longitude, city, slot_minutes, has_qr_code, has_nfc_tag,
      max_distance_meters, gps_tolerance_meters
    )
    values (
      v_park.id, v_number,
      coalesce(p_surface, 'clay')::public.court_surface,
      public.unique_slug('courts', v_park.slug::text || '-q' || v_number),
      v_name,
      coalesce(p_latitude, v_park.latitude),
      coalesce(p_longitude, v_park.longitude),
      v_park.city,
      coalesce(p_slot_minutes, 40::smallint),
      coalesce(p_has_qr_code, true),
      coalesce(p_has_nfc_tag, false),
      coalesce(p_max_distance_meters, 1000),
      coalesce(p_gps_tolerance_meters, 200)
    )
    returning * into v_row;
  else
    update public.courts set
      court_number = coalesce(p_court_number, court_number),
      surface      = coalesce(p_surface::public.court_surface, surface),
      name         = coalesce(nullif(trim(p_name), ''), name),
      latitude     = coalesce(p_latitude, latitude),
      longitude    = coalesce(p_longitude, longitude),
      slot_minutes = coalesce(p_slot_minutes, slot_minutes),
      has_qr_code  = coalesce(p_has_qr_code, has_qr_code),
      has_nfc_tag  = coalesce(p_has_nfc_tag, has_nfc_tag),
      is_active    = coalesce(p_is_active, is_active),
      max_distance_meters  = coalesce(p_max_distance_meters, max_distance_meters),
      gps_tolerance_meters = coalesce(p_gps_tolerance_meters, gps_tolerance_meters)
    where id = p_id
    returning * into v_row;

    if v_row.id is null then
      raise exception 'Quadra não encontrada.' using errcode = 'NQ025';
    end if;
  end if;

  return to_jsonb(v_row);
end;
$$;

comment on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer
) is
  'Cria ou edita uma quadra. O raio de proximidade entra aqui para que um '
  'ambiente de teste possa afrouxá-lo sem passar pelo SQL Editor.';

revoke all on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer
) from public;

grant execute on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer
) to authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20261011130000_proximity_toggle.sql
-- ####################################################################

-- =====================================================================
-- Interruptor de proximidade por quadra
--
-- A verificação de distância é o que impede alguém de entrar na fila
-- de casa. Ela também impede o QA de testar sentado na mesa, e
-- aumentar o raio para 20 km numa cidade só troca um problema por
-- outro: a quadra vizinha passa a aceitar.
--
-- Um interruptor explícito é mais honesto que um raio gigante. Nasce
-- LIGADO: desligar é uma decisão por quadra, visível na tela de
-- administração, e não acontece por descuido.
-- =====================================================================

alter table public.courts
  add column if not exists enforce_proximity boolean not null default true;

comment on column public.courts.enforce_proximity is
  'Quando falso, o scan-court aceita a leitura de qualquer distância. '
  'Só para quadras de teste — a distância continua sendo registrada.';

-- ---------------------------------------------------------------------
-- O overview mostra o estado do interruptor
-- ---------------------------------------------------------------------
create or replace function public.admin_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.require_admin();

  return jsonb_build_object(
    'parks', coalesce((
      select jsonb_agg(p order by p.name)
      from (
        select jsonb_build_object(
          'id',        pk.id,
          'slug',      pk.slug::text,
          'name',      pk.name,
          'district',  pk.district,
          'city',      pk.city,
          'latitude',  pk.latitude,
          'longitude', pk.longitude,
          'tone_color', pk.tone_color,
          'photo_alt', pk.photo_alt,
          'is_active', pk.is_active,
          'courts', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'id',            c.id,
                'slug',          c.slug::text,
                'name',          c.name,
                'court_number',  c.court_number,
                'surface',       c.surface,
                'surface_label', case c.surface
                                   when 'clay' then 'Saibro'
                                   when 'hard' then 'Rápida'
                                   else 'Grama'
                                 end,
                'latitude',      c.latitude,
                'longitude',     c.longitude,
                'slot_minutes',  c.slot_minutes,
                'is_active',     c.is_active,
                'status',        c.status,
                'has_qr_code',   c.has_qr_code,
                'has_nfc_tag',   c.has_nfc_tag,
                'max_distance_meters',  c.max_distance_meters,
                'gps_tolerance_meters', c.gps_tolerance_meters,
                'enforce_proximity',    c.enforce_proximity,
                'qr_secret_version',    c.qr_secret_version,
                'queue_length',  (
                  select count(*) from public.queue_entries q
                  where q.court_id = c.id and q.status in ('waiting', 'ready')
                )
              ) order by c.court_number
            )
            from public.courts c where c.park_id = pk.id
          ), '[]'::jsonb)
        ) as p, pk.name
        from public.parks pk
      ) p
    ), '[]'::jsonb),
    'totals', (
      select jsonb_build_object(
        'parks',  (select count(*) from public.parks),
        'courts', (select count(*) from public.courts),
        'users',  (select count(*) from public.profiles)
      )
    )
  );
end;
$$;

-- ---------------------------------------------------------------------
-- E o formulário regula
-- ---------------------------------------------------------------------
drop function if exists public.admin_upsert_court(
  uuid, uuid, smallint, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer
);

create or replace function public.admin_upsert_court(
  p_id           uuid    default null,
  p_park_id      uuid    default null,
  p_court_number smallint default null,
  p_surface      text    default null,
  p_name         text    default null,
  p_latitude     double precision default null,
  p_longitude    double precision default null,
  p_slot_minutes smallint default null,
  p_has_qr_code  boolean default null,
  p_has_nfc_tag  boolean default null,
  p_is_active    boolean default null,
  p_max_distance_meters  integer default null,
  p_gps_tolerance_meters integer default null,
  p_enforce_proximity    boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row    public.courts;
  v_park   public.parks;
  v_number smallint;
  v_name   text;
begin
  perform public.require_admin();

  if p_id is null then
    select * into v_park from public.parks where id = p_park_id;
    if v_park.id is null then
      raise exception 'Parque não encontrado.' using errcode = 'NQ025';
    end if;

    v_number := coalesce(
      p_court_number,
      (select coalesce(max(court_number), 0) + 1 from public.courts where park_id = v_park.id)::smallint
    );
    v_name := coalesce(nullif(trim(p_name), ''), 'Quadra ' || lpad(v_number::text, 2, '0'));

    insert into public.courts (
      park_id, court_number, surface, slug, name,
      latitude, longitude, city, slot_minutes, has_qr_code, has_nfc_tag,
      max_distance_meters, gps_tolerance_meters, enforce_proximity
    )
    values (
      v_park.id, v_number,
      coalesce(p_surface, 'clay')::public.court_surface,
      public.unique_slug('courts', v_park.slug::text || '-q' || v_number),
      v_name,
      coalesce(p_latitude, v_park.latitude),
      coalesce(p_longitude, v_park.longitude),
      v_park.city,
      coalesce(p_slot_minutes, 40::smallint),
      coalesce(p_has_qr_code, true),
      coalesce(p_has_nfc_tag, false),
      coalesce(p_max_distance_meters, 1000),
      coalesce(p_gps_tolerance_meters, 200),
      coalesce(p_enforce_proximity, true)
    )
    returning * into v_row;
  else
    update public.courts set
      court_number = coalesce(p_court_number, court_number),
      surface      = coalesce(p_surface::public.court_surface, surface),
      name         = coalesce(nullif(trim(p_name), ''), name),
      latitude     = coalesce(p_latitude, latitude),
      longitude    = coalesce(p_longitude, longitude),
      slot_minutes = coalesce(p_slot_minutes, slot_minutes),
      has_qr_code  = coalesce(p_has_qr_code, has_qr_code),
      has_nfc_tag  = coalesce(p_has_nfc_tag, has_nfc_tag),
      is_active    = coalesce(p_is_active, is_active),
      max_distance_meters  = coalesce(p_max_distance_meters, max_distance_meters),
      gps_tolerance_meters = coalesce(p_gps_tolerance_meters, gps_tolerance_meters),
      enforce_proximity    = coalesce(p_enforce_proximity, enforce_proximity)
    where id = p_id
    returning * into v_row;

    if v_row.id is null then
      raise exception 'Quadra não encontrada.' using errcode = 'NQ025';
    end if;
  end if;

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean
) from public;

grant execute on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean
) to authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20261011140000_address_and_pin.sql
-- ####################################################################

-- =====================================================================
-- Endereço escrito + alfinete no mapa
--
-- O cadastro pedia latitude e longitude cruas, e quem cadastra não tem
-- isso na mão. Pior: a quadra herdava calada a posição do parque, e em
-- parque grande — quadra no meio, longe da rua — isso é a diferença
-- entre o check-in funcionar e não funcionar, porque é a posição da
-- QUADRA que o scan-court compara com a do jogador.
--
-- Então o formulário passa a ter duas coisas separadas:
--   . o endereço, que é referência de quem vai chegar de carro;
--   . a posição, marcada no mapa, que é o que vale no check-in.
--
-- Aqui embaixo isso significa: `p_address` nos dois upserts (a coluna
-- `address` já existia nas duas tabelas, só não havia como preenchê-la
-- pelo app), o endereço do parque herdado pela quadra nova, e o
-- `admin_overview` devolvendo `address` para o formulário reabrir
-- preenchido.
-- =====================================================================

-- ---------------------------------------------------------------------
-- O overview devolve o endereço de parques e quadras
-- ---------------------------------------------------------------------
create or replace function public.admin_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.require_admin();

  return jsonb_build_object(
    'parks', coalesce((
      select jsonb_agg(p order by p.name)
      from (
        select jsonb_build_object(
          'id',        pk.id,
          'slug',      pk.slug::text,
          'name',      pk.name,
          'district',  pk.district,
          'city',      pk.city,
          'address',   pk.address,
          'latitude',  pk.latitude,
          'longitude', pk.longitude,
          'tone_color', pk.tone_color,
          'photo_alt', pk.photo_alt,
          'is_active', pk.is_active,
          'courts', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'id',            c.id,
                'slug',          c.slug::text,
                'name',          c.name,
                'court_number',  c.court_number,
                'surface',       c.surface,
                'surface_label', case c.surface
                                   when 'clay' then 'Saibro'
                                   when 'hard' then 'Rápida'
                                   else 'Grama'
                                 end,
                'address',       c.address,
                'latitude',      c.latitude,
                'longitude',     c.longitude,
                'slot_minutes',  c.slot_minutes,
                'is_active',     c.is_active,
                'status',        c.status,
                'has_qr_code',   c.has_qr_code,
                'has_nfc_tag',   c.has_nfc_tag,
                'max_distance_meters',  c.max_distance_meters,
                'gps_tolerance_meters', c.gps_tolerance_meters,
                'enforce_proximity',    c.enforce_proximity,
                'qr_secret_version',    c.qr_secret_version,
                'queue_length',  (
                  select count(*) from public.queue_entries q
                  where q.court_id = c.id and q.status in ('waiting', 'ready')
                )
              ) order by c.court_number
            )
            from public.courts c where c.park_id = pk.id
          ), '[]'::jsonb)
        ) as p, pk.name
        from public.parks pk
      ) p
    ), '[]'::jsonb),
    'totals', (
      select jsonb_build_object(
        'parks',  (select count(*) from public.parks),
        'courts', (select count(*) from public.courts),
        'users',  (select count(*) from public.profiles)
      )
    )
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Parque: endereço junto do resto
--
-- A assinatura antiga sai de cena: com todos os parâmetros opcionais,
-- duas versões conviventes deixariam a chamada por nome ambígua.
-- ---------------------------------------------------------------------
drop function if exists public.admin_upsert_park(
  uuid, text, text, text, double precision, double precision, text, text, boolean
);

create or replace function public.admin_upsert_park(
  p_id        uuid    default null,
  p_name      text    default null,
  p_district  text    default null,
  p_city      text    default null,
  p_address   text    default null,
  p_latitude  double precision default null,
  p_longitude double precision default null,
  p_tone_color text   default null,
  p_photo_alt text    default null,
  p_is_active boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_row public.parks;
begin
  perform public.require_admin();

  if p_id is null then
    if coalesce(trim(p_name), '') = '' then
      raise exception 'Informe o nome do parque.' using errcode = 'NQ024';
    end if;
    if p_latitude is null or p_longitude is null then
      raise exception 'Marque no mapa onde fica o parque.' using errcode = 'NQ024';
    end if;

    insert into public.parks (
      slug, name, district, city, address, latitude, longitude, tone_color, photo_alt
    )
    values (
      public.unique_slug('parks', p_name),
      trim(p_name), nullif(trim(p_district), ''), nullif(trim(p_city), ''),
      nullif(trim(p_address), ''),
      p_latitude, p_longitude, nullif(trim(p_tone_color), ''), nullif(trim(p_photo_alt), '')
    )
    returning * into v_row;
  else
    update public.parks set
      name       = coalesce(nullif(trim(p_name), ''), name),
      district   = coalesce(nullif(trim(p_district), ''), district),
      city       = coalesce(nullif(trim(p_city), ''), city),
      address    = coalesce(nullif(trim(p_address), ''), address),
      latitude   = coalesce(p_latitude, latitude),
      longitude  = coalesce(p_longitude, longitude),
      tone_color = coalesce(nullif(trim(p_tone_color), ''), tone_color),
      photo_alt  = coalesce(nullif(trim(p_photo_alt), ''), photo_alt),
      is_active  = coalesce(p_is_active, is_active)
    where id = p_id
    returning * into v_row;

    if v_row.id is null then
      raise exception 'Parque não encontrado.' using errcode = 'NQ025';
    end if;
  end if;

  return to_jsonb(v_row);
end;
$$;

-- ---------------------------------------------------------------------
-- Quadra: endereço de referência e posição própria
--
-- A posição continua caindo para a do parque quando não vem nada — é o
-- que mantém o cadastro antigo válido. A diferença é que agora o
-- formulário sempre manda a posição marcada no mapa, então a quadra do
-- meio do parque deixa de ficar com a coordenada do portão.
-- ---------------------------------------------------------------------
drop function if exists public.admin_upsert_court(
  uuid, uuid, smallint, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean
);

create or replace function public.admin_upsert_court(
  p_id           uuid    default null,
  p_park_id      uuid    default null,
  p_court_number smallint default null,
  p_surface      text    default null,
  p_name         text    default null,
  p_address      text    default null,
  p_latitude     double precision default null,
  p_longitude    double precision default null,
  p_slot_minutes smallint default null,
  p_has_qr_code  boolean default null,
  p_has_nfc_tag  boolean default null,
  p_is_active    boolean default null,
  p_max_distance_meters  integer default null,
  p_gps_tolerance_meters integer default null,
  p_enforce_proximity    boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row    public.courts;
  v_park   public.parks;
  v_number smallint;
  v_name   text;
begin
  perform public.require_admin();

  if p_id is null then
    select * into v_park from public.parks where id = p_park_id;
    if v_park.id is null then
      raise exception 'Parque não encontrado.' using errcode = 'NQ025';
    end if;

    v_number := coalesce(
      p_court_number,
      (select coalesce(max(court_number), 0) + 1 from public.courts where park_id = v_park.id)::smallint
    );
    v_name := coalesce(nullif(trim(p_name), ''), 'Quadra ' || lpad(v_number::text, 2, '0'));

    insert into public.courts (
      park_id, court_number, surface, slug, name,
      address, latitude, longitude, city, slot_minutes, has_qr_code, has_nfc_tag,
      max_distance_meters, gps_tolerance_meters, enforce_proximity
    )
    values (
      v_park.id, v_number,
      coalesce(p_surface, 'clay')::public.court_surface,
      public.unique_slug('courts', v_park.slug::text || '-q' || v_number),
      v_name,
      coalesce(nullif(trim(p_address), ''), v_park.address),
      coalesce(p_latitude, v_park.latitude),
      coalesce(p_longitude, v_park.longitude),
      v_park.city,
      coalesce(p_slot_minutes, 40::smallint),
      coalesce(p_has_qr_code, true),
      coalesce(p_has_nfc_tag, false),
      coalesce(p_max_distance_meters, 1000),
      coalesce(p_gps_tolerance_meters, 200),
      coalesce(p_enforce_proximity, true)
    )
    returning * into v_row;
  else
    update public.courts set
      court_number = coalesce(p_court_number, court_number),
      surface      = coalesce(p_surface::public.court_surface, surface),
      name         = coalesce(nullif(trim(p_name), ''), name),
      address      = coalesce(nullif(trim(p_address), ''), address),
      latitude     = coalesce(p_latitude, latitude),
      longitude    = coalesce(p_longitude, longitude),
      slot_minutes = coalesce(p_slot_minutes, slot_minutes),
      has_qr_code  = coalesce(p_has_qr_code, has_qr_code),
      has_nfc_tag  = coalesce(p_has_nfc_tag, has_nfc_tag),
      is_active    = coalesce(p_is_active, is_active),
      max_distance_meters  = coalesce(p_max_distance_meters, max_distance_meters),
      gps_tolerance_meters = coalesce(p_gps_tolerance_meters, gps_tolerance_meters),
      enforce_proximity    = coalesce(p_enforce_proximity, enforce_proximity)
    where id = p_id
    returning * into v_row;

    if v_row.id is null then
      raise exception 'Quadra não encontrada.' using errcode = 'NQ025';
    end if;
  end if;

  return to_jsonb(v_row);
end;
$$;

-- ---------------------------------------------------------------------
-- Permissões das novas assinaturas
-- ---------------------------------------------------------------------
revoke all on function public.admin_upsert_park(
  uuid, text, text, text, text, double precision, double precision, text, text, boolean
) from public;

grant execute on function public.admin_upsert_park(
  uuid, text, text, text, text, double precision, double precision, text, text, boolean
) to authenticated;

revoke all on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean
) from public;

grant execute on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean
) to authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20261017120000_grupos_enums.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 4
-- 25. Tipos novos dos grupos na fila
--
-- Separado da migration seguinte de propósito: um valor novo de enum
-- não pode ser usado na mesma transação que o criou, e o Supabase roda
-- cada migration numa transação.
-- =====================================================================

-- Pedido para entrar no grupo de alguém que já está na fila.
do $$ begin
  create type public.join_request_status as enum
    ('pending', 'approved', 'rejected', 'cancelled', 'expired');
exception when duplicate_object then null; end $$;

-- Pushes do fluxo de grupo: o dono recebe o pedido, quem pediu recebe
-- a resposta.
alter type public.notification_type add value if not exists 'group_join_request';
alter type public.notification_type add value if not exists 'group_join_approved';

-- O grupo devolveu a quadra antes do fim do turno.
alter type public.match_end_reason add value if not exists 'finished_by_group';


-- ####################################################################
-- Origem: supabase/migrations/20261017120100_grupos_na_fila.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 4
-- 26. A vaga na fila é de um grupo, e cada um prova que está lá
--
-- O modelo da Sprint 3 era "lado A × lado B, quem ganha fica": cada
-- inscrição era um time de 1 ou 2 e o adversário vinha da fila. Nos
-- parques não é assim. Quem entra na quadra é um grupo de conhecidos
-- que joga entre si — dois no simples, quatro nas duplas, às vezes
-- cinco revezando — e cada vaga da fila vale um turno fixo de quadra.
--
--   1. Uma pessoa abre a vaga sozinha e guarda o lugar.
--   2. Os amigos entram nessa mesma vaga escaneando o QR da quadra:
--      pedindo para entrar (o dono aprova) ou digitando o PIN do grupo.
--      Vale até o fim do turno — quem chega atrasado entra com o jogo
--      rolando, e o relógio não para.
--   3. Uma pessoa, uma vaga. Quem já está em outra fila precisa sair
--      dela para entrar no grupo do amigo.
--   4. Chamado o grupo, a tolerância para o check-in é curta (2 min,
--      ajustável pelo admin). Basta um check-in para o turno começar.
--   5. Não há vencedor nem adversário: o turno acaba no fim do slot, ou
--      antes, se o grupo devolver a quadra.
--   6. A vaga não se perde enquanto houver alguém nela. Saiu o dono,
--      outro membro herda; saíram todos, a vez passa.
--
-- O furo que o pedido de entrada fecha: sem aprovação, qualquer pessoa
-- que escaneasse o QR escolheria o grupo do 1º da fila e passaria na
-- frente de todo mundo.
--
-- Códigos novos:
--   NQ027 pedido de entrada não encontrado ou não está mais pendente
--   NQ028 muitas tentativas de PIN
--   NQ029 parceiro não é mais adicionado pelo @ — ele escaneia a quadra
--
-- A tabela matches continua: uma linha agora é o turno de um grupo
-- (side_a_entry_id). O lado B, o vencedor e o mandante deixam de ser
-- usados, mas as colunas ficam para o histórico já gravado.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Sem limite de pessoas por vaga
-- ---------------------------------------------------------------------
drop trigger if exists queue_entry_members_team_size on public.queue_entry_members;
drop function if exists public.enforce_queue_team_size();

comment on table public.queue_entry_members is
  'Pessoas de um grupo na fila. Sem limite de tamanho: o turno é fixo, quantos forem.';
comment on column public.queue_entries.mode is
  'Legado (Sprint 1-3). A vaga é de um grupo de qualquer tamanho; o campo não decide nada.';

alter table public.queue_entry_members
  add column if not exists joined_via    text,
  add column if not exists checked_in_at timestamptz,
  add column if not exists left_at       timestamptz;

do $$ begin
  alter table public.queue_entry_members
    add constraint queue_entry_members_joined_via_check
    check (joined_via is null or joined_via in ('owner', 'approval', 'pin', 'partner'));
exception when duplicate_object then null; end $$;

comment on column public.queue_entry_members.joined_via is
  'Como entrou: abriu a vaga (owner), foi aprovado (approval) ou usou o PIN (pin). '
  '"partner" é o parceiro adicionado pelo @ antes da Sprint 4.';
comment on column public.queue_entry_members.checked_in_at is
  'Quando escaneou a quadra para jogar. Quem entra com o turno rolando já chega com check-in.';
comment on column public.queue_entry_members.left_at is
  'Saiu do grupo com o turno em andamento. Quem sai antes do turno é removido do grupo.';

update public.queue_entry_members
   set joined_via = case when role = 'owner' then 'owner' else 'partner' end
 where joined_via is null;

-- ---------------------------------------------------------------------
-- 2. PIN do grupo
--
-- Mostrado só para quem está no grupo; quem tem o PIN e escaneia a
-- quadra entra sem esperar aprovação. É o que resolve o amigo que chega
-- com o jogo rolando: o dono está em quadra e não vai olhar o celular.
--
-- Fica numa tabela à parte porque queue_entries é legível por qualquer
-- pessoa logada (e passa pelo Realtime). Cada vaga tem o seu — um PIN
-- que vazou num grupo de WhatsApp na semana passada não serve hoje.
-- ---------------------------------------------------------------------
create table if not exists public.queue_entry_pins (
  entry_id   uuid primary key references public.queue_entries (id) on delete cascade,
  pin        text not null check (pin ~ '^[0-9]{4}$'),
  created_at timestamptz not null default now()
);

comment on table public.queue_entry_pins is
  'PIN de 4 dígitos de cada vaga. Sem acesso direto do cliente: só sai pelas RPCs, para os membros.';

alter table public.queue_entry_pins enable row level security;
revoke all on public.queue_entry_pins from anon, authenticated;

create or replace function public.new_group_pin(p_court_id uuid)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_pin text;
begin
  -- Único entre as vagas ativas da quadra: o PIN é procurado por quadra.
  for i in 1..50 loop
    v_pin := lpad((floor(random() * 10000))::integer::text, 4, '0');
    exit when not exists (
      select 1
      from public.queue_entry_pins p
      join public.queue_entries e on e.id = p.entry_id
      where e.court_id = p_court_id
        and e.status in ('waiting', 'ready', 'playing')
        and p.pin = v_pin
    );
  end loop;
  return v_pin;
end;
$$;

revoke all on function public.new_group_pin(uuid) from public, anon, authenticated;

-- Tentativas de PIN: cada uma exige um scan novo na quadra, e um erro
-- a mais que o limite trava por 15 minutos.
create table if not exists public.queue_pin_attempts (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  court_id   uuid not null references public.courts (id) on delete cascade,
  entry_id   uuid references public.queue_entries (id) on delete set null,
  success    boolean not null,
  created_at timestamptz not null default now()
);

create index if not exists queue_pin_attempts_user_idx
  on public.queue_pin_attempts (user_id, created_at desc);

alter table public.queue_pin_attempts enable row level security;
revoke all on public.queue_pin_attempts from anon, authenticated;

-- Vagas que já estavam na fila ganham o seu.
insert into public.queue_entry_pins (entry_id, pin)
select e.id, public.new_group_pin(e.court_id)
from public.queue_entries e
where e.status in ('waiting', 'ready', 'playing')
on conflict (entry_id) do nothing;

-- ---------------------------------------------------------------------
-- 3. Pedido para entrar num grupo
-- ---------------------------------------------------------------------
create table if not exists public.queue_join_requests (
  id            uuid primary key default gen_random_uuid(),
  entry_id      uuid not null references public.queue_entries (id) on delete cascade,
  court_id      uuid not null references public.courts (id) on delete cascade,
  user_id       uuid not null references auth.users (id) on delete cascade,
  scan_token_id uuid references public.scan_tokens (id) on delete set null,
  status        public.join_request_status not null default 'pending',
  leave_current boolean not null default false,
  expires_at    timestamptz not null,
  decided_at    timestamptz,
  decided_by    uuid references auth.users (id) on delete set null,
  created_at    timestamptz not null default clock_timestamp()
);

comment on table public.queue_join_requests is
  'Quem escaneou a quadra e pediu para entrar no grupo de alguém. O dono do grupo aprova.';
comment on column public.queue_join_requests.leave_current is
  'Quem pediu estava em outra fila e confirmou que sai dela. Sai só quando for aceito.';

-- Um pedido pendente por pessoa: pedir outro cancela o anterior.
create unique index if not exists queue_join_requests_one_pending_per_user
  on public.queue_join_requests (user_id)
  where status = 'pending';

create index if not exists queue_join_requests_entry_idx
  on public.queue_join_requests (entry_id)
  where status = 'pending';

create index if not exists queue_join_requests_expiry_idx
  on public.queue_join_requests (expires_at)
  where status = 'pending';

alter table public.queue_join_requests enable row level security;

-- Quem pediu e quem está no grupo enxergam o pedido. É o que deixa o
-- Realtime avisar o dono na hora.
create or replace function public.is_entry_member(p_entry_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.queue_entry_members m
    where m.entry_id = p_entry_id and m.user_id = p_user_id and m.is_active
  );
$$;

grant execute on function public.is_entry_member(uuid, uuid) to authenticated;

drop policy if exists "pedidos: quem pediu e o grupo leem" on public.queue_join_requests;
create policy "pedidos: quem pediu e o grupo leem"
  on public.queue_join_requests for select
  to authenticated
  using (user_id = auth.uid() or public.is_entry_member(entry_id, auth.uid()));

revoke all on public.queue_join_requests from anon, authenticated;
grant select on public.queue_join_requests to authenticated;

alter table public.queue_join_requests replica identity full;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'queue_join_requests'
  ) then
    alter publication supabase_realtime add table public.queue_join_requests;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 4. Tolerância do check-in: 2 minutos, ajustável por quadra
-- ---------------------------------------------------------------------
alter table public.courts alter column call_window_seconds set default 120;

-- Só muda quem ainda estava no padrão antigo: um valor que o admin
-- escolheu continua valendo.
update public.courts set call_window_seconds = 120 where call_window_seconds = 300;

comment on column public.courts.call_window_seconds is
  'Tolerância para o check-in depois de chamado. Padrão 120s; o admin ajusta por quadra.';

-- ---------------------------------------------------------------------
-- Notificações
-- ---------------------------------------------------------------------

-- Só para quem continua no grupo.
create or replace function public.enqueue_team_notification(
  p_entry_id uuid,
  p_type     public.notification_type,
  p_title    text,
  p_body     text,
  p_data     jsonb default '{}'::jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inserted integer;
begin
  insert into public.notification_outbox (user_id, entry_id, court_id, type, title, body, data)
  select m.user_id, m.entry_id, m.court_id, p_type, p_title, p_body, p_data
  from public.queue_entry_members m
  where m.entry_id = p_entry_id and m.is_active
  on conflict do nothing;

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;

-- Para uma pessoa só. Sem entry_id de propósito: a deduplicação por
-- (entry_id, user_id, type) engoliria o segundo pedido para o mesmo
-- dono.
create or replace function public.enqueue_user_notification(
  p_user_id  uuid,
  p_court_id uuid,
  p_type     public.notification_type,
  p_title    text,
  p_body     text,
  p_data     jsonb default '{}'::jsonb
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.notification_outbox (user_id, court_id, type, title, body, data)
  values (p_user_id, p_court_id, p_type, p_title, p_body, p_data);
$$;

revoke all on function public.enqueue_user_notification(uuid, uuid, public.notification_type, text, text, jsonb)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Rótulo do grupo
-- ---------------------------------------------------------------------
create or replace function public.group_label(p_size integer)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when coalesce(p_size, 0) <= 1 then 'Solo'
    when p_size = 2 then 'Dupla'
    else p_size || ' jogadores'
  end;
$$;

grant execute on function public.group_label(integer) to anon, authenticated;

-- Quem está no grupo. Numa vaga ativa, só quem continua nela; num turno
-- encerrado, todo mundo que jogou.
create or replace function public.match_side_players(p_entry_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'user_id',    m.user_id,
        'username',   p.username,
        'full_name',  p.full_name,
        'initials',   public.initials_of(coalesce(p.full_name, p.username::text)),
        'short_name', public.short_name_of(coalesce(p.full_name, p.username::text)),
        'role',       m.role,
        'checked_in', m.checked_in_at is not null
      )
      order by m.role, m.created_at
    ),
    '[]'::jsonb
  )
  from public.queue_entry_members m
  join public.queue_entries e on e.id = m.entry_id
  left join public.profiles p on p.id = m.user_id
  where m.entry_id = p_entry_id
    and (m.is_active or e.status not in ('waiting', 'ready', 'playing'));
$$;

create or replace function public.queue_entry_players(p_entry_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'user_id',    m.user_id,
        'role',       m.role,
        'username',   p.username,
        'full_name',  p.full_name,
        'avatar_url', p.avatar_url
      )
      order by m.role, m.created_at
    ),
    '[]'::jsonb
  )
  from public.queue_entry_members m
  join public.queue_entries e on e.id = m.entry_id
  left join public.profiles p on p.id = m.user_id
  where m.entry_id = p_entry_id
    and (m.is_active or e.status not in ('waiting', 'ready', 'playing'));
$$;

-- ---------------------------------------------------------------------
-- Encerrar o turno (uso interno)
--
-- Sem vencedor: o grupo sai e o próximo da fila é chamado. p_winner
-- fica na assinatura só para não quebrar quem já chama a função.
-- ---------------------------------------------------------------------
create or replace function public.close_match(
  p_match_id uuid,
  p_winner   public.match_side,
  p_reason   public.match_end_reason,
  p_reporter uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_match public.matches%rowtype;
begin
  select * into v_match from public.matches mt where mt.id = p_match_id for update;
  if not found then
    raise exception 'Partida não encontrada' using errcode = 'NQ018';
  end if;
  if v_match.ended_at is not null then
    return public.match_state(p_match_id);
  end if;

  update public.matches
     set ended_at    = now(),
         winner_side = null,
         end_reason  = p_reason,
         reported_by = p_reporter
   where id = p_match_id;

  -- O lado B só existe em turnos gravados antes da Sprint 4.
  update public.queue_entries
     set status = 'done', ended_at = now()
   where id in (v_match.side_a_entry_id, v_match.side_b_entry_id)
     and status = 'playing';

  update public.courts
     set holder_entry_id = null,
         status = case
                    when status = 'unavailable' then 'unavailable'::public.court_status
                    else 'available'::public.court_status
                  end
   where id = v_match.court_id;

  update public.queue_join_requests
     set status = 'expired', decided_at = now()
   where status = 'pending'
     and entry_id in (v_match.side_a_entry_id, v_match.side_b_entry_id);

  -- Com a quadra livre, o próximo grupo é chamado na hora.
  perform public.call_next_team(v_match.court_id);

  return public.match_state(p_match_id);
end;
$$;

-- ---------------------------------------------------------------------
-- Abrir o turno: o grupo da vez, sem adversário
-- ---------------------------------------------------------------------
create or replace function public.open_match(p_entry_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry    public.queue_entries%rowtype;
  v_court    public.courts%rowtype;
  v_first    uuid;
  v_live     public.matches%rowtype;
  v_match_id uuid;
begin
  select * into v_entry from public.queue_entries e where e.id = p_entry_id for update;
  if not found then
    raise exception 'Grupo não encontrado' using errcode = 'NQ007';
  end if;
  if v_entry.status not in ('waiting', 'ready') then
    raise exception 'Este grupo não pode iniciar o turno agora' using errcode = 'NQ009';
  end if;

  select * into v_court from public.courts c where c.id = v_entry.court_id for update;
  if not v_court.is_active or v_court.status = 'unavailable' then
    raise exception 'Esta quadra está indisponível no momento' using errcode = 'NQ003';
  end if;

  select qp.entry_id into v_first
  from public.queue_positions qp
  where qp.court_id = v_court.id
  order by qp.position
  limit 1;

  if v_first is distinct from v_entry.id then
    raise exception 'Ainda não é a vez do seu grupo' using errcode = 'NQ015';
  end if;

  select * into v_live
  from public.matches mt
  where mt.court_id = v_court.id and mt.ended_at is null
  for update;

  if found then
    if v_live.expires_at > now() then
      raise exception 'A quadra está ocupada por mais % minuto(s)',
        greatest(1, ceil(extract(epoch from (v_live.expires_at - now())) / 60)::integer)
        using errcode = 'NQ017';
    end if;
    perform public.close_match(v_live.id, null, 'slot_expired');
  end if;

  insert into public.matches
    (court_id, side_a_entry_id, side_b_entry_id, mode, slot_minutes, expires_at)
  values
    (v_court.id, v_entry.id, null, v_entry.mode, v_court.slot_minutes,
     now() + make_interval(mins => v_court.slot_minutes))
  returning id into v_match_id;

  update public.queue_entries
     set status = 'playing', called_at = coalesce(called_at, now()), started_at = now()
   where id = v_entry.id;

  update public.courts set status = 'in_game', holder_entry_id = null where id = v_court.id;

  return public.match_state(v_match_id);
end;
$$;

-- ---------------------------------------------------------------------
-- Andar a fila de uma quadra: turno vencido sai, chamada não atendida
-- perde a vez. Roda antes do check-in e da entrada na fila — com uma
-- tolerância de 2 minutos, esperar o cron de 15 em 15 deixaria a quadra
-- parada. advance_expired_queues() deve ser agendada a cada minuto
-- (docs/deploy.md), para o "É a sua vez!" do próximo sair sozinho.
-- ---------------------------------------------------------------------
create or replace function public.advance_court(p_court_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_match   record;
  v_entry   record;
  v_closed  integer := 0;
  v_expired integer := 0;
begin
  for v_match in
    select id from public.matches
    where court_id = p_court_id and ended_at is null and expires_at <= now()
  loop
    perform public.close_match(v_match.id, null, 'slot_expired');
    v_closed := v_closed + 1;
  end loop;

  for v_entry in
    select e.id
    from public.queue_entries e
    where e.court_id = p_court_id
      and e.status = 'ready'
      and e.call_expires_at is not null
      and e.call_expires_at <= now()
    order by e.queue_number
  loop
    update public.queue_entries
       set status = 'expired', cancel_reason = 'no_show', left_at = now()
     where id = v_entry.id and status = 'ready';

    update public.queue_join_requests
       set status = 'expired', decided_at = now()
     where status = 'pending' and entry_id = v_entry.id;

    perform public.call_next_team(p_court_id);
    v_expired := v_expired + 1;
  end loop;

  return jsonb_build_object('matches_closed', v_closed, 'entries_expired', v_expired);
end;
$$;

create or replace function public.advance_expired_queues()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court    record;
  v_result   jsonb;
  v_closed   integer := 0;
  v_expired  integer := 0;
  v_requests integer;
begin
  for v_court in
    select distinct court_id from (
      select court_id from public.matches
      where ended_at is null and expires_at <= now()
      union all
      select court_id from public.queue_entries
      where status = 'ready' and call_expires_at is not null and call_expires_at <= now()
    ) s
  loop
    v_result  := public.advance_court(v_court.court_id);
    v_closed  := v_closed + (v_result ->> 'matches_closed')::integer;
    v_expired := v_expired + (v_result ->> 'entries_expired')::integer;
  end loop;

  -- Pedido que ninguém respondeu, ou de um grupo que já saiu da fila.
  update public.queue_join_requests r
     set status = 'expired', decided_at = now()
   where r.status = 'pending'
     and (r.expires_at <= now()
          or not exists (select 1 from public.queue_entries e
                         where e.id = r.entry_id
                           and e.status in ('waiting', 'ready', 'playing')));
  get diagnostics v_requests = row_count;

  return jsonb_build_object(
    'matches_closed',   v_closed,
    'entries_expired',  v_expired,
    'requests_expired', v_requests,
    'ran_at', now()
  );
end;
$$;

revoke all on function public.advance_court(uuid)      from public, anon, authenticated;
revoke all on function public.advance_expired_queues() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Sair do grupo (uso interno)
--
-- Antes do turno, quem sai deixa de fazer parte do grupo. Com o turno
-- rolando, fica registrado que jogou. A vaga só some quando sai o
-- último; saindo o dono, o membro mais antigo herda.
-- ---------------------------------------------------------------------
create or replace function public.leave_entry(
  p_entry_id uuid,
  p_user_id  uuid,
  p_reason   text default 'left_by_user'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry     public.queue_entries%rowtype;
  v_member    public.queue_entry_members%rowtype;
  v_remaining integer;
  v_heir      uuid;
  v_match     uuid;
begin
  select * into v_entry from public.queue_entries e where e.id = p_entry_id for update;
  if not found then
    raise exception 'Grupo não encontrado' using errcode = 'NQ007';
  end if;
  if v_entry.status not in ('waiting', 'ready', 'playing') then
    raise exception 'Este grupo não está mais na fila' using errcode = 'NQ009';
  end if;

  select * into v_member
  from public.queue_entry_members m
  where m.entry_id = p_entry_id and m.user_id = p_user_id and m.is_active
  for update;

  if not found then
    raise exception 'Você não faz parte deste grupo' using errcode = 'NQ008';
  end if;

  if v_entry.status = 'playing' then
    update public.queue_entry_members
       set is_active = false, left_at = now()
     where id = v_member.id;
  else
    delete from public.queue_entry_members where id = v_member.id;
  end if;

  select count(*)::integer into v_remaining
  from public.queue_entry_members m
  where m.entry_id = p_entry_id and m.is_active;

  if v_remaining = 0 then
    update public.queue_join_requests
       set status = 'expired', decided_at = now()
     where status = 'pending' and entry_id = p_entry_id;

    if v_entry.status = 'playing' then
      select mt.id into v_match
      from public.matches mt
      where mt.ended_at is null
        and p_entry_id in (mt.side_a_entry_id, mt.side_b_entry_id);

      if v_match is not null then
        perform public.close_match(v_match, null, 'abandoned', p_user_id);
      else
        update public.queue_entries set status = 'done', ended_at = now() where id = p_entry_id;
      end if;
    else
      update public.queue_entries
         set status = 'cancelled', left_at = now(), cancel_reason = coalesce(p_reason, 'left_by_user')
       where id = p_entry_id;

      -- Era a vez deste grupo: a vez passa agora, sem esperar o prazo.
      if v_entry.status = 'ready' then
        perform public.call_next_team(v_entry.court_id);
      end if;
    end if;
  elsif v_member.role = 'owner' then
    select m.id into v_heir
    from public.queue_entry_members m
    where m.entry_id = p_entry_id and m.is_active
    order by m.created_at
    limit 1;

    update public.queue_entry_members set role = 'owner' where id = v_heir;
  end if;

  select * into v_entry from public.queue_entries e where e.id = p_entry_id;

  return jsonb_build_object(
    'entry_id',          p_entry_id,
    'status',            v_entry.status,
    'left_at',           now(),
    'remaining_members', v_remaining
  );
end;
$$;

revoke all on function public.leave_entry(uuid, uuid, text) from public, anon, authenticated;

-- Sair da fila: agora sai quem pediu, não o grupo inteiro.
create or replace function public.leave_queue(
  p_entry_id uuid,
  p_reason   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user  uuid := auth.uid();
  v_entry public.queue_entries%rowtype;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  if public.is_entry_member(p_entry_id, v_user) then
    return public.leave_entry(p_entry_id, v_user, coalesce(p_reason, 'left_by_user'));
  end if;

  -- A operação do parque ainda pode tirar um grupo inteiro da fila.
  if not public.is_staff() then
    raise exception 'Você não faz parte deste grupo' using errcode = 'NQ008';
  end if;

  select * into v_entry from public.queue_entries e where e.id = p_entry_id for update;
  if not found then
    raise exception 'Grupo não encontrado' using errcode = 'NQ007';
  end if;
  if v_entry.status not in ('waiting', 'ready') then
    raise exception 'Este grupo não está mais na fila' using errcode = 'NQ009';
  end if;

  update public.queue_entries
     set status = 'cancelled', left_at = now(), cancel_reason = coalesce(p_reason, 'removed_by_staff')
   where id = p_entry_id;

  if v_entry.status = 'ready' then
    perform public.call_next_team(v_entry.court_id);
  end if;

  return jsonb_build_object('entry_id', p_entry_id, 'status', 'cancelled', 'left_at', now(),
                            'remaining_members', 0);
end;
$$;

-- ---------------------------------------------------------------------
-- Prova de presença: o scan token, igual para todas as entradas
-- ---------------------------------------------------------------------
create or replace function public.take_scan_token(p_scan_token text, p_message text)
returns public.scan_tokens
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token public.scan_tokens%rowtype;
begin
  select * into v_token
  from public.scan_tokens t
  where t.token_hash = public.hash_scan_token(p_scan_token)
  for update;

  if not found
     or v_token.user_id is distinct from auth.uid()
     or v_token.consumed_at is not null
     or v_token.expires_at <= now() then
    raise exception '%', p_message using errcode = 'NQ002';
  end if;

  return v_token;
end;
$$;

revoke all on function public.take_scan_token(text, text) from public, anon, authenticated;

-- Quem já está em outra fila precisa sair dela para entrar no grupo. Sem
-- p_leave_current, a chamada é recusada com o aviso (NQ014); o app
-- pergunta e repete com a confirmação. Com p_leave_now = false só
-- confere — é o pedido de entrada, que sai da fila antiga apenas quando
-- for aceito.
create or replace function public.free_player_for(
  p_user_id       uuid,
  p_target_entry  uuid,
  p_leave_current boolean,
  p_leave_now     boolean default true
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_state jsonb;
begin
  v_state := public.player_state(p_user_id);

  if v_state ->> 'state' = 'free' then
    return;
  end if;

  if (v_state ->> 'entry_id')::uuid = p_target_entry then
    raise exception 'Você já está neste grupo' using errcode = 'NQ004';
  end if;

  if not coalesce(p_leave_current, false) then
    raise exception 'Para entrar neste grupo, saia da sua fila atual (%).',
      lower(coalesce(v_state ->> 'where', 'outra quadra'))
      using errcode = 'NQ014';
  end if;

  if coalesce(p_leave_now, true) then
    perform public.leave_entry((v_state ->> 'entry_id')::uuid, p_user_id, 'switched_group');
  end if;
end;
$$;

revoke all on function public.free_player_for(uuid, uuid, boolean, boolean) from public, anon, authenticated;

-- Coloca a pessoa no grupo (aprovada ou pelo PIN).
create or replace function public.add_group_member(
  p_entry_id uuid,
  p_user_id  uuid,
  p_via      text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry public.queue_entries%rowtype;
begin
  select * into v_entry from public.queue_entries e where e.id = p_entry_id;

  -- Quem entra com o turno rolando está na quadra: o scan que fez para
  -- entrar já é o check-in.
  insert into public.queue_entry_members
    (entry_id, court_id, user_id, role, joined_via, checked_in_at)
  values
    (p_entry_id, v_entry.court_id, p_user_id, 'partner', p_via,
     case when v_entry.status = 'playing' then now() end)
  on conflict (entry_id, user_id) do update
    set is_active     = true,
        left_at       = null,
        role          = 'partner',
        joined_via    = excluded.joined_via,
        checked_in_at = coalesce(public.queue_entry_members.checked_in_at, excluded.checked_in_at);

  update public.queue_join_requests
     set status = 'cancelled', decided_at = now()
   where status = 'pending' and user_id = p_user_id and entry_id <> p_entry_id;
end;
$$;

revoke all on function public.add_group_member(uuid, uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Abrir uma vaga na fila
--
-- A assinatura antiga continua aceita (o app em produção ainda manda
-- p_mode), mas o parceiro pelo @ acabou: ele não provava que a pessoa
-- estava na quadra.
-- ---------------------------------------------------------------------
create or replace function public.join_queue(
  p_scan_token text,
  p_mode       public.queue_mode default 'single',
  p_partner    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid := auth.uid();
  v_token    public.scan_tokens%rowtype;
  v_court    public.courts%rowtype;
  v_entry_id uuid;
  v_state    jsonb;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  if nullif(trim(coalesce(p_partner, '')), '') is not null then
    raise exception 'O parceiro entra escaneando a quadra e pedindo para entrar no seu grupo'
      using errcode = 'NQ029';
  end if;

  v_token := public.take_scan_token(p_scan_token,
    'Escaneie o QR Code da quadra novamente para entrar na fila');

  select * into v_court from public.courts c where c.id = v_token.court_id for update;

  if not found or not v_court.is_active or v_court.status = 'unavailable' then
    raise exception 'Esta quadra está indisponível no momento' using errcode = 'NQ003';
  end if;

  v_state := public.player_state(v_user);

  if v_state ->> 'state' <> 'free' then
    if (v_state ->> 'court_id')::uuid = v_court.id then
      raise exception 'Você já está nesta fila' using errcode = 'NQ004';
    end if;
    raise exception 'Você já está na fila da %', v_state ->> 'court_name'
      using errcode = 'NQ014';
  end if;

  -- Antes de calcular a vez: uma chamada vencida nesta quadra não pode
  -- segurar a fila.
  perform public.advance_court(v_court.id);

  insert into public.queue_entries (court_id, mode, created_by, scan_token_id)
  values (v_court.id, coalesce(p_mode, 'single'), v_user, v_token.id)
  returning id into v_entry_id;

  insert into public.queue_entry_members (entry_id, court_id, user_id, role, joined_via)
  values (v_entry_id, v_court.id, v_user, 'owner', 'owner');

  insert into public.queue_entry_pins (entry_id, pin)
  values (v_entry_id, public.new_group_pin(v_court.id));

  -- Abriu a própria vaga: um pedido para entrar em outro grupo perde o sentido.
  update public.queue_join_requests
     set status = 'cancelled', decided_at = now()
   where status = 'pending' and user_id = v_user;

  update public.scan_tokens
     set consumed_at = now(), consumed_by_entry = v_entry_id
   where id = v_token.id;

  perform public.call_next_team(v_court.id);

  return public.queue_entry_state(v_entry_id);
end;
$$;

-- ---------------------------------------------------------------------
-- Pedir para entrar no grupo de alguém
-- ---------------------------------------------------------------------
create or replace function public.request_join(
  p_scan_token    text,
  p_entry_id      uuid,
  p_leave_current boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user    uuid := auth.uid();
  v_token   public.scan_tokens%rowtype;
  v_entry   public.queue_entries%rowtype;
  v_court   public.courts%rowtype;
  v_owner   uuid;
  v_name    text;
  v_request public.queue_join_requests%rowtype;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  v_token := public.take_scan_token(p_scan_token,
    'Escaneie o QR Code da quadra novamente para pedir para entrar');

  select * into v_entry from public.queue_entries e where e.id = p_entry_id for update;
  if not found then
    raise exception 'Grupo não encontrado' using errcode = 'NQ007';
  end if;
  if v_entry.court_id <> v_token.court_id then
    raise exception 'Escaneie o QR Code da quadra deste grupo' using errcode = 'NQ002';
  end if;
  if v_entry.status not in ('waiting', 'ready', 'playing') then
    raise exception 'Este grupo não está mais na fila' using errcode = 'NQ009';
  end if;

  -- Quem está em outra fila continua nela enquanto espera: só sai quando
  -- for aceito. Aqui só se confere que confirmou o aviso.
  perform public.free_player_for(v_user, p_entry_id, p_leave_current, false);

  update public.queue_join_requests
     set status = 'cancelled', decided_at = now()
   where status = 'pending' and user_id = v_user;

  insert into public.queue_join_requests
    (entry_id, court_id, user_id, scan_token_id, expires_at, leave_current)
  values
    (p_entry_id, v_entry.court_id, v_user, v_token.id, now() + interval '10 minutes',
     public.player_state(v_user) ->> 'state' <> 'free')
  returning * into v_request;

  update public.scan_tokens
     set consumed_at = now(), consumed_by_entry = p_entry_id
   where id = v_token.id;

  select m.user_id into v_owner
  from public.queue_entry_members m
  where m.entry_id = p_entry_id and m.is_active and m.role = 'owner'
  limit 1;

  select * into v_court from public.courts c where c.id = v_entry.court_id;
  select public.short_name_of(coalesce(p.full_name, p.username::text)) into v_name
  from public.profiles p where p.id = v_user;

  if v_owner is not null then
    perform public.enqueue_user_notification(
      v_owner, v_entry.court_id, 'group_join_request',
      'Pedido para entrar no seu grupo',
      format('%s quer entrar no seu grupo na %s.', coalesce(v_name, 'Alguém'),
             public.court_label(v_court.court_number)),
      jsonb_build_object('request_id', v_request.id, 'entry_id', p_entry_id,
                         'court_id', v_entry.court_id)
    );
  end if;

  return jsonb_build_object(
    'request_id', v_request.id,
    'status',     v_request.status,
    'entry_id',   p_entry_id,
    'court_id',   v_entry.court_id,
    'expires_at', v_request.expires_at
  );
end;
$$;

-- ---------------------------------------------------------------------
-- O dono aceita ou recusa
-- ---------------------------------------------------------------------
create or replace function public.decide_join_request(
  p_request_id uuid,
  p_approve    boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user    uuid := auth.uid();
  v_request public.queue_join_requests%rowtype;
  v_entry   public.queue_entries%rowtype;
  v_court   public.courts%rowtype;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  select * into v_request from public.queue_join_requests r where r.id = p_request_id for update;
  if not found or v_request.status <> 'pending' or v_request.expires_at <= now() then
    raise exception 'Este pedido não está mais pendente' using errcode = 'NQ027';
  end if;

  select * into v_entry from public.queue_entries e where e.id = v_request.entry_id for update;

  if not exists (
    select 1 from public.queue_entry_members m
    where m.entry_id = v_entry.id and m.user_id = v_user and m.is_active and m.role = 'owner'
  ) then
    raise exception 'Só quem abriu o grupo aceita pedidos' using errcode = 'NQ008';
  end if;

  if not coalesce(p_approve, false) then
    update public.queue_join_requests
       set status = 'rejected', decided_at = now(), decided_by = v_user
     where id = p_request_id;
    return jsonb_build_object('request_id', p_request_id, 'status', 'rejected');
  end if;

  if v_entry.status not in ('waiting', 'ready', 'playing') then
    raise exception 'Este grupo não está mais na fila' using errcode = 'NQ009';
  end if;

  -- Quem pediu estando em outra fila e confirmou o aviso sai dela agora,
  -- na mesma transação em que entra no grupo.
  if public.player_state(v_request.user_id) ->> 'state' <> 'free' and v_request.leave_current then
    perform public.free_player_for(v_request.user_id, v_entry.id, true);
  end if;

  -- Estava livre ao pedir e entrou em outra fila enquanto esperava.
  if public.player_state(v_request.user_id) ->> 'state' <> 'free' then
    update public.queue_join_requests
       set status = 'cancelled', decided_at = now(), decided_by = v_user
     where id = p_request_id;
    return jsonb_build_object('request_id', p_request_id, 'status', 'cancelled',
                              'reason', 'requester_in_another_queue');
  end if;

  perform public.add_group_member(v_entry.id, v_request.user_id, 'approval');

  update public.queue_join_requests
     set status = 'approved', decided_at = now(), decided_by = v_user
   where id = p_request_id;

  select * into v_court from public.courts c where c.id = v_entry.court_id;

  perform public.enqueue_user_notification(
    v_request.user_id, v_entry.court_id, 'group_join_approved',
    'Você entrou no grupo',
    format('Seu pedido foi aceito. Você está no grupo da %s.',
           public.court_label(v_court.court_number)),
    jsonb_build_object('entry_id', v_entry.id, 'court_id', v_entry.court_id)
  );

  return jsonb_build_object('request_id', p_request_id, 'status', 'approved',
                            'entry_id', v_entry.id);
end;
$$;

create or replace function public.cancel_join_request(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.queue_join_requests
     set status = 'cancelled', decided_at = now()
   where id = p_request_id and user_id = auth.uid() and status = 'pending';

  if not found then
    raise exception 'Este pedido não está mais pendente' using errcode = 'NQ027';
  end if;

  return jsonb_build_object('request_id', p_request_id, 'status', 'cancelled');
end;
$$;

-- ---------------------------------------------------------------------
-- Entrar com o PIN do grupo
--
-- PIN errado não é exceção: a tentativa precisa ficar gravada (e o scan
-- gasto) para o limite funcionar, e uma exceção desfaria as duas coisas.
-- ---------------------------------------------------------------------
create or replace function public.join_with_pin(
  p_scan_token    text,
  p_pin           text,
  p_leave_current boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user    uuid := auth.uid();
  v_token   public.scan_tokens%rowtype;
  v_entry   public.queue_entries%rowtype;
  v_failed  integer;
  v_limit   constant integer := 5;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  v_token := public.take_scan_token(p_scan_token,
    'Escaneie o QR Code da quadra novamente para entrar com o PIN');

  select count(*)::integer into v_failed
  from public.queue_pin_attempts a
  where a.user_id = v_user and not a.success and a.created_at > now() - interval '15 minutes';

  if v_failed >= v_limit then
    raise exception 'Muitas tentativas de PIN. Tente de novo em alguns minutos ou peça para entrar.'
      using errcode = 'NQ028';
  end if;

  select e.* into v_entry
  from public.queue_entry_pins p
  join public.queue_entries e on e.id = p.entry_id
  where e.court_id = v_token.court_id
    and e.status in ('waiting', 'ready', 'playing')
    and p.pin = trim(coalesce(p_pin, ''))
  for update of e;

  if not found then
    insert into public.queue_pin_attempts (user_id, court_id, success)
    values (v_user, v_token.court_id, false);

    update public.scan_tokens set consumed_at = now() where id = v_token.id;

    return jsonb_build_object(
      'joined',        false,
      'code',          'PIN_INVALID',
      'message',       'PIN incorreto. Confira com quem está no grupo e escaneie de novo.',
      'attempts_left', greatest(v_limit - v_failed - 1, 0)
    );
  end if;

  perform public.free_player_for(v_user, v_entry.id, p_leave_current);
  perform public.add_group_member(v_entry.id, v_user, 'pin');

  update public.queue_join_requests
     set status = 'cancelled', decided_at = now()
   where status = 'pending' and user_id = v_user;

  insert into public.queue_pin_attempts (user_id, court_id, entry_id, success)
  values (v_user, v_token.court_id, v_entry.id, true);

  update public.scan_tokens
     set consumed_at = now(), consumed_by_entry = v_entry.id
   where id = v_token.id;

  return jsonb_build_object(
    'joined',   true,
    'entry_id', v_entry.id,
    'court_id', v_entry.court_id,
    'status',   (select e.status from public.queue_entries e where e.id = v_entry.id)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Check-in na quadra
--
-- Um check-in basta para o turno começar. Quem é do grupo e chega
-- depois escaneia também: fica registrado que está em quadra.
-- ---------------------------------------------------------------------
create or replace function public.check_in_and_start(p_scan_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user  uuid := auth.uid();
  v_token public.scan_tokens%rowtype;
  v_entry public.queue_entries%rowtype;
  v_match uuid;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  v_token := public.take_scan_token(p_scan_token,
    'Escaneie o QR Code da quadra para confirmar que você chegou');

  select e.* into v_entry
  from public.queue_entry_members m
  join public.queue_entries e on e.id = m.entry_id
  where m.user_id = v_user and m.is_active and e.court_id = v_token.court_id;

  if not found then
    raise exception 'Você não está na fila desta quadra' using errcode = 'NQ007';
  end if;

  if v_entry.status <> 'playing' then
    if v_entry.status = 'ready'
       and v_entry.call_expires_at is not null
       and v_entry.call_expires_at <= now() then
      raise exception 'O tempo para o check-in terminou' using errcode = 'NQ016';
    end if;

    -- O turno anterior pode ter vencido sem o cron ter passado ainda.
    perform public.advance_court(v_entry.court_id);
    perform public.open_match(v_entry.id);
  end if;

  update public.queue_entry_members
     set checked_in_at = coalesce(checked_in_at, now())
   where entry_id = v_entry.id and user_id = v_user and is_active;

  update public.scan_tokens
     set consumed_at = now(), consumed_by_entry = v_entry.id
   where id = v_token.id;

  select mt.id into v_match
  from public.matches mt
  where mt.ended_at is null and v_entry.id in (mt.side_a_entry_id, mt.side_b_entry_id);

  return case when v_match is null then public.queue_entry_state(v_entry.id)
              else public.match_state(v_match) end;
end;
$$;

-- ---------------------------------------------------------------------
-- O grupo devolve a quadra antes do fim do turno
-- ---------------------------------------------------------------------
create or replace function public.finish_my_turn(p_match_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user  uuid := auth.uid();
  v_match public.matches%rowtype;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  select * into v_match from public.matches mt where mt.id = p_match_id;
  if not found then
    raise exception 'Partida não encontrada' using errcode = 'NQ018';
  end if;
  if v_match.ended_at is not null then
    raise exception 'Este turno já foi encerrado' using errcode = 'NQ009';
  end if;

  if not public.is_entry_member(v_match.side_a_entry_id, v_user) and not public.is_staff() then
    raise exception 'Só quem está no grupo encerra o turno' using errcode = 'NQ008';
  end if;

  return public.close_match(p_match_id, null, 'finished_by_group', v_user);
end;
$$;

-- Fim do "quem ganha fica".
drop function if exists public.report_match_result(uuid, public.match_side);
drop function if exists public.join_open_side(text);
drop function if exists public.finish_match(uuid, public.match_side);

create or replace function public.finish_match(p_entry_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_match public.matches%rowtype;
begin
  if not public.is_staff() then
    raise exception 'Apenas a operação da quadra pode encerrar turnos' using errcode = 'NQ008';
  end if;

  select * into v_match
  from public.matches mt
  where mt.ended_at is null
    and p_entry_id in (mt.side_a_entry_id, mt.side_b_entry_id);

  if not found then
    raise exception 'Este grupo não está em quadra' using errcode = 'NQ009';
  end if;

  return public.close_match(v_match.id, null, 'cancelled', auth.uid());
end;
$$;

-- ---------------------------------------------------------------------
-- Leituras
-- ---------------------------------------------------------------------
create or replace function public.match_state(p_match_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_match   public.matches%rowtype;
  v_court   public.courts%rowtype;
  v_players jsonb;
begin
  select * into v_match from public.matches mt where mt.id = p_match_id;
  if not found then
    raise exception 'Partida não encontrada' using errcode = 'NQ018';
  end if;

  select * into v_court from public.courts c where c.id = v_match.court_id;

  v_players := public.match_side_players(v_match.side_a_entry_id);

  return jsonb_build_object(
    'match_id',     v_match.id,
    'court_id',     v_match.court_id,
    'court_name',   public.court_label(v_court.court_number),
    'entry_id',     v_match.side_a_entry_id,
    'players',      v_players,
    'group_size',   jsonb_array_length(v_players),
    'group_label',  public.group_label(jsonb_array_length(v_players)),
    'slot_minutes', v_match.slot_minutes,
    'started_at',   v_match.started_at,
    'expires_at',   v_match.expires_at,
    'ended_at',     v_match.ended_at,
    'end_reason',   v_match.end_reason,
    'is_live',      v_match.ended_at is null,
    'elapsed_seconds',   greatest(0, floor(extract(epoch from (
                           coalesce(v_match.ended_at, now()) - v_match.started_at)))::integer),
    'remaining_seconds', case
                           when v_match.ended_at is not null then 0
                           else greatest(0, floor(extract(epoch from (
                             v_match.expires_at - now())))::integer)
                         end
  );
end;
$$;

create or replace function public.court_queue_items(p_court_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with court as (
    select c.id, c.slot_minutes,
           (select count(*) from public.matches mt
             where mt.court_id = c.id and mt.ended_at is null) as live,
           (select greatest(0, floor(extract(epoch from (mt.expires_at - now())))::integer)
              from public.matches mt
             where mt.court_id = c.id and mt.ended_at is null
             limit 1) as remaining
    from public.courts c where c.id = p_court_id
  ),
  q as (
    select qp.entry_id, qp.position, qp.status, qp.joined_at,
           e.call_expires_at,
           -- A raquete do grupo é a de quem está à frente dele.
           (select jsonb_build_object(
                     'frame', pr.racket_frame_color,
                     'grip',  pr.racket_grip_color)
              from public.queue_entry_members mm
              join public.profiles pr on pr.id = mm.user_id
             where mm.entry_id = qp.entry_id and mm.is_active and mm.role = 'owner'
             limit 1) as racket,
           public.match_side_players(qp.entry_id) as players
    from public.queue_positions qp
    join public.queue_entries e on e.id = qp.entry_id
    where qp.court_id = p_court_id
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'entry_id',    q.entry_id,
        'position',    q.position,
        'position_label', q.position || 'º',
        'group_size',  jsonb_array_length(q.players),
        'group_label', public.group_label(jsonb_array_length(q.players)),
        -- Mantido para o app anterior à Sprint 4.
        'mode_label',  public.group_label(jsonb_array_length(q.players)),
        'status',      q.status,
        'is_called',   q.status = 'ready',
        'call_expires_at', q.call_expires_at,
        'joined_at',   q.joined_at,
        'teams_ahead', (q.position - 1) + coalesce((select live from court), 0),
        'is_mine',     exists (
                         select 1 from public.queue_entry_members mm
                         where mm.entry_id = q.entry_id and mm.user_id = auth.uid() and mm.is_active
                       ),
        'racket',      q.racket,
        'players',     q.players,
        -- "Ana S. + Bruno L. + 3": o nome de todo mundo não cabe na linha.
        'team_label',  (
          select string_agg(pl ->> 'short_name', ' + ' order by ord)
                   || case when jsonb_array_length(q.players) > 2
                           then ' + ' || (jsonb_array_length(q.players) - 2)
                           else '' end
          from jsonb_array_elements(q.players) with ordinality as t(pl, ord)
          where ord <= 2
        ),
        'stack', (
          select coalesce(jsonb_agg(s.racket order by s.position), '[]'::jsonb)
          from (
            select q2.racket, q2.position
            from q q2
            where q2.position <= q.position
            order by q2.position desc
            limit 5
          ) s
        ),
        'stack_more', greatest(q.position - 5, 0),
        'eta_seconds', coalesce((select remaining from court), 0)
                       + (q.position - 1) * (select slot_minutes from court) * 60
      )
      order by q.position
    ),
    '[]'::jsonb
  )
  from q;
$$;

-- O grupo de quem está olhando: PIN, membros e pedidos pendentes. Só
-- sai para quem está no grupo.
create or replace function public.my_group(p_entry_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when not public.is_entry_member(p_entry_id, auth.uid()) then null
    else jsonb_build_object(
      'entry_id', p_entry_id,
      'status',   (select e.status from public.queue_entries e where e.id = p_entry_id),
      'pin',      (select p.pin from public.queue_entry_pins p where p.entry_id = p_entry_id),
      'is_owner', exists (
                    select 1 from public.queue_entry_members m
                    where m.entry_id = p_entry_id and m.user_id = auth.uid()
                      and m.is_active and m.role = 'owner'),
      'checked_in', exists (
                    select 1 from public.queue_entry_members m
                    where m.entry_id = p_entry_id and m.user_id = auth.uid()
                      and m.is_active and m.checked_in_at is not null),
      'players',  public.match_side_players(p_entry_id),
      'group_size', jsonb_array_length(public.match_side_players(p_entry_id)),
      'pending_requests', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'request_id', r.id,
                 'user_id',    r.user_id,
                 'full_name',  pr.full_name,
                 'short_name', public.short_name_of(coalesce(pr.full_name, pr.username::text)),
                 'initials',   public.initials_of(coalesce(pr.full_name, pr.username::text)),
                 'created_at', r.created_at,
                 'expires_at', r.expires_at
               ) order by r.created_at), '[]'::jsonb)
        from public.queue_join_requests r
        left join public.profiles pr on pr.id = r.user_id
        where r.entry_id = p_entry_id and r.status = 'pending' and r.expires_at > now()
      )
    )
  end;
$$;

-- O pedido que eu fiz e ainda espera resposta.
create or replace function public.my_join_request()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select (
    select jsonb_build_object(
      'request_id', r.id,
      'entry_id',   r.entry_id,
      'court_id',   r.court_id,
      'court_name', public.court_label(c.court_number),
      'expires_at', r.expires_at,
      'owner_name', (
        select public.short_name_of(coalesce(pr.full_name, pr.username::text))
        from public.queue_entry_members m
        join public.profiles pr on pr.id = m.user_id
        where m.entry_id = r.entry_id and m.is_active and m.role = 'owner'
        limit 1)
    )
    from public.queue_join_requests r
    join public.courts c on c.id = r.court_id
    where r.user_id = auth.uid() and r.status = 'pending' and r.expires_at > now()
    limit 1
  );
$$;

grant execute on function public.my_group(uuid)    to authenticated;
grant execute on function public.my_join_request() to authenticated;

create or replace function public.court_screen(p_court_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_court  public.courts%rowtype;
  v_park   public.parks%rowtype;
  v_match  uuid;
  v_items  jsonb;
  v_queue  integer;
  v_rem    integer := 0;
  v_mine   jsonb;
  v_state  jsonb;
  v_group  jsonb;
  v_req    jsonb;
  v_live   jsonb;
begin
  select * into v_court from public.courts c where c.id = p_court_id;
  if not found then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;

  select * into v_park from public.parks pk where pk.id = v_court.park_id;

  select mt.id,
         greatest(0, floor(extract(epoch from (mt.expires_at - now())))::integer)
  into v_match, v_rem
  from public.matches mt
  where mt.court_id = p_court_id and mt.ended_at is null
  limit 1;

  v_live  := case when v_match is null then null else public.match_state(v_match) end;
  v_items := public.court_queue_items(p_court_id);
  v_queue := jsonb_array_length(v_items);

  select i into v_mine
  from jsonb_array_elements(v_items) i
  where (i ->> 'is_mine')::boolean
  limit 1;

  v_state := public.player_state(auth.uid());

  if (v_state ->> 'court_id')::uuid = p_court_id then
    v_group := public.my_group((v_state ->> 'entry_id')::uuid);
  end if;

  v_req := public.my_join_request();
  if (v_req ->> 'court_id')::uuid is distinct from p_court_id then
    v_req := null;
  end if;

  return jsonb_build_object(
    'court', jsonb_build_object(
      'id',            v_court.id,
      'name',          public.court_label(v_court.court_number),
      'number',        v_court.court_number,
      'surface',       v_court.surface,
      'surface_label', case v_court.surface
                         when 'clay'  then 'Saibro'
                         when 'hard'  then 'Rápida'
                         else 'Grama'
                       end,
      'status',        v_court.status,
      'is_active',     v_court.is_active,
      'slot_minutes',  v_court.slot_minutes,
      'call_window_seconds', v_court.call_window_seconds,
      'checkin_methods', (
        select coalesce(jsonb_agg(m order by m), '[]'::jsonb)
        from (
          select 'qr'::text as m where v_court.has_qr_code
          union all
          select 'nfc'::text where v_court.has_nfc_tag
        ) s
      ),
      'latitude',      v_court.latitude,
      'longitude',     v_court.longitude,
      'rating_avg',    v_court.rating_avg,
      'rating_count',  v_court.rating_count,
      'cover_photo_path', v_court.cover_photo_path
    ),
    'park', jsonb_build_object(
      'id',       v_park.id,
      'name',     v_park.name,
      'district', v_park.district
    ),
    'match',        v_live,
    'is_live',      v_match is not null,
    'status_text',  case when v_match is not null then 'Em jogo' else 'Livre' end,
    'players_line', case
                      when v_match is null then 'Sem jogo agora — check-in libera a quadra'
                      else (
                        select coalesce(string_agg(pl ->> 'short_name', ' · ' order by ord), 'Grupo em quadra')
                        from jsonb_array_elements(v_live -> 'players') with ordinality as t(pl, ord)
                      )
                    end,
    'queue',        v_items,
    'queue_length', v_queue,
    'queue_text',   case
                      when v_queue = 0 then 'Fila vazia'
                      else v_queue || ' na espera'
                    end,
    'remaining_seconds', coalesce(v_rem, 0),
    'total_wait_seconds', coalesce(v_rem, 0) + v_queue * v_court.slot_minutes * 60,
    'next_position_label', (v_queue + 1) || 'º',
    'my_entry',     v_mine,
    'my_group',     v_group,
    'my_request',   v_req,
    'court_accepting', v_court.is_active and v_court.status <> 'unavailable',
    'can_join',     v_court.is_active
                    and v_court.status <> 'unavailable'
                    and (v_state ->> 'state') = 'free',
    'my_state',     v_state,
    'generated_at', now()
  );
end;
$$;

create or replace function public.my_queue_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user   uuid := auth.uid();
  v_entry  public.queue_entries%rowtype;
  v_court  public.courts%rowtype;
  v_park   public.parks%rowtype;
  v_item   jsonb;
  v_match  uuid;
begin
  if v_user is null then
    return jsonb_build_object('state', 'free');
  end if;

  select e.* into v_entry
  from public.queue_entry_members m
  join public.queue_entries e on e.id = m.entry_id
  where m.user_id = v_user and m.is_active
  limit 1;

  if not found then
    return jsonb_build_object('state', 'free', 'pending_request', public.my_join_request());
  end if;

  select * into v_court from public.courts c where c.id = v_entry.court_id;
  select * into v_park  from public.parks pk where pk.id = v_court.park_id;

  select i into v_item
  from jsonb_array_elements(public.court_queue_items(v_entry.court_id)) i
  where (i ->> 'entry_id')::uuid = v_entry.id;

  select mt.id into v_match
  from public.matches mt
  where mt.court_id = v_entry.court_id
    and mt.ended_at is null
    and mt.side_a_entry_id = v_entry.id;

  return jsonb_build_object(
    'state',      case
                    when v_entry.status = 'playing' then 'playing'
                    when v_entry.status = 'ready'   then 'called'
                    else 'queued'
                  end,
    'entry_id',   v_entry.id,
    'court_id',   v_court.id,
    'court_name', public.court_label(v_court.court_number),
    'park_id',    v_park.id,
    'park_name',  v_park.name,
    'position',        (v_item ->> 'position')::integer,
    'position_label',  v_item ->> 'position_label',
    'teams_ahead',     (v_item ->> 'teams_ahead')::integer,
    'eta_seconds',     (v_item ->> 'eta_seconds')::integer,
    'stack',           v_item -> 'stack',
    'stack_more',      (v_item ->> 'stack_more')::integer,
    'players',         public.match_side_players(v_entry.id),
    'group',           public.my_group(v_entry.id),
    'call_expires_at',      v_entry.call_expires_at,
    'call_remaining_seconds', case
                                when v_entry.status <> 'ready' or v_entry.call_expires_at is null then null
                                else greatest(0, floor(extract(epoch from
                                       (v_entry.call_expires_at - now())))::integer)
                              end,
    'match',      case when v_match is null then null else public.match_state(v_match) end,
    'generated_at', now()
  );
end;
$$;

-- Compatível com a Sprint 1 (Edge Function queue-status).
create or replace function public.court_queue(p_court_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_screen jsonb;
begin
  v_screen := public.court_screen(p_court_id);

  return jsonb_build_object(
    'court', jsonb_build_object(
      'id',                    v_screen -> 'court' -> 'id',
      'slug',                  (select c.slug from public.courts c where c.id = p_court_id),
      'name',                  v_screen -> 'court' -> 'name',
      'address',               (select c.address from public.courts c where c.id = p_court_id),
      'status',                v_screen -> 'court' -> 'status',
      'is_active',             v_screen -> 'court' -> 'is_active',
      'latitude',              v_screen -> 'court' -> 'latitude',
      'longitude',             v_screen -> 'court' -> 'longitude',
      'average_match_minutes', v_screen -> 'court' -> 'slot_minutes',
      'photo_url',             (select c.photo_url from public.courts c where c.id = p_court_id)
    ),
    'can_join',      v_screen -> 'court_accepting',
    'teams_waiting', v_screen -> 'queue_length',
    'current_match', case
                       when (v_screen ->> 'is_live')::boolean then jsonb_build_object(
                         'entry_id',   v_screen -> 'match' -> 'entry_id',
                         'started_at', v_screen -> 'match' -> 'started_at',
                         'players',    v_screen -> 'match' -> 'players'
                       )
                       else null
                     end,
    'current_match_remaining_minutes', case
                                         when (v_screen ->> 'is_live')::boolean
                                           then ceil((v_screen ->> 'remaining_seconds')::numeric / 60)::integer
                                         else null
                                       end,
    'queue', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'entry_id',               i -> 'entry_id',
               'group_size',             i -> 'group_size',
               'status',                 i -> 'status',
               'joined_at',              i -> 'joined_at',
               'position',               i -> 'position',
               'teams_ahead',            i -> 'teams_ahead',
               'estimated_wait_minutes', ceil((i ->> 'eta_seconds')::numeric / 60)::integer,
               'players',                i -> 'players'
             ) order by (i ->> 'position')::integer), '[]'::jsonb)
      from jsonb_array_elements(v_screen -> 'queue') i
    ),
    'generated_at', v_screen -> 'generated_at'
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Administração: a tolerância do check-in no formulário da quadra
-- ---------------------------------------------------------------------
create or replace function public.admin_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.require_admin();

  return jsonb_build_object(
    'parks', coalesce((
      select jsonb_agg(p order by p.name)
      from (
        select jsonb_build_object(
          'id',        pk.id,
          'slug',      pk.slug::text,
          'name',      pk.name,
          'district',  pk.district,
          'city',      pk.city,
          'latitude',  pk.latitude,
          'longitude', pk.longitude,
          'tone_color', pk.tone_color,
          'photo_alt', pk.photo_alt,
          'is_active', pk.is_active,
          'courts', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'id',            c.id,
                'slug',          c.slug::text,
                'name',          c.name,
                'court_number',  c.court_number,
                'surface',       c.surface,
                'surface_label', case c.surface
                                   when 'clay' then 'Saibro'
                                   when 'hard' then 'Rápida'
                                   else 'Grama'
                                 end,
                'latitude',      c.latitude,
                'longitude',     c.longitude,
                'slot_minutes',  c.slot_minutes,
                'call_window_seconds', c.call_window_seconds,
                'is_active',     c.is_active,
                'status',        c.status,
                'has_qr_code',   c.has_qr_code,
                'has_nfc_tag',   c.has_nfc_tag,
                'max_distance_meters',  c.max_distance_meters,
                'gps_tolerance_meters', c.gps_tolerance_meters,
                'enforce_proximity',    c.enforce_proximity,
                'qr_secret_version',    c.qr_secret_version,
                'queue_length',  (
                  select count(*) from public.queue_entries q
                  where q.court_id = c.id and q.status in ('waiting', 'ready')
                )
              ) order by c.court_number
            )
            from public.courts c where c.park_id = pk.id
          ), '[]'::jsonb)
        ) as p, pk.name
        from public.parks pk
      ) p
    ), '[]'::jsonb),
    'totals', (
      select jsonb_build_object(
        'parks',  (select count(*) from public.parks),
        'courts', (select count(*) from public.courts),
        'users',  (select count(*) from public.profiles)
      )
    )
  );
end;
$$;

drop function if exists public.admin_upsert_court(
  uuid, uuid, smallint, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean
);

create or replace function public.admin_upsert_court(
  p_id           uuid    default null,
  p_park_id      uuid    default null,
  p_court_number smallint default null,
  p_surface      text    default null,
  p_name         text    default null,
  p_latitude     double precision default null,
  p_longitude    double precision default null,
  p_slot_minutes smallint default null,
  p_has_qr_code  boolean default null,
  p_has_nfc_tag  boolean default null,
  p_is_active    boolean default null,
  p_max_distance_meters  integer default null,
  p_gps_tolerance_meters integer default null,
  p_enforce_proximity    boolean default null,
  p_call_window_seconds  integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row    public.courts;
  v_park   public.parks;
  v_number smallint;
  v_name   text;
begin
  perform public.require_admin();

  if p_id is null then
    select * into v_park from public.parks where id = p_park_id;
    if v_park.id is null then
      raise exception 'Parque não encontrado.' using errcode = 'NQ025';
    end if;

    v_number := coalesce(
      p_court_number,
      (select coalesce(max(court_number), 0) + 1 from public.courts where park_id = v_park.id)::smallint
    );
    v_name := coalesce(nullif(trim(p_name), ''), 'Quadra ' || lpad(v_number::text, 2, '0'));

    insert into public.courts (
      park_id, court_number, surface, slug, name,
      latitude, longitude, city, slot_minutes, has_qr_code, has_nfc_tag,
      max_distance_meters, gps_tolerance_meters, enforce_proximity, call_window_seconds
    )
    values (
      v_park.id, v_number,
      coalesce(p_surface, 'clay')::public.court_surface,
      public.unique_slug('courts', v_park.slug::text || '-q' || v_number),
      v_name,
      coalesce(p_latitude, v_park.latitude),
      coalesce(p_longitude, v_park.longitude),
      v_park.city,
      coalesce(p_slot_minutes, 40::smallint),
      coalesce(p_has_qr_code, true),
      coalesce(p_has_nfc_tag, false),
      coalesce(p_max_distance_meters, 1000),
      coalesce(p_gps_tolerance_meters, 200),
      coalesce(p_enforce_proximity, true),
      coalesce(p_call_window_seconds, 120)
    )
    returning * into v_row;
  else
    update public.courts set
      court_number = coalesce(p_court_number, court_number),
      surface      = coalesce(p_surface::public.court_surface, surface),
      name         = coalesce(nullif(trim(p_name), ''), name),
      latitude     = coalesce(p_latitude, latitude),
      longitude    = coalesce(p_longitude, longitude),
      slot_minutes = coalesce(p_slot_minutes, slot_minutes),
      has_qr_code  = coalesce(p_has_qr_code, has_qr_code),
      has_nfc_tag  = coalesce(p_has_nfc_tag, has_nfc_tag),
      is_active    = coalesce(p_is_active, is_active),
      max_distance_meters  = coalesce(p_max_distance_meters, max_distance_meters),
      gps_tolerance_meters = coalesce(p_gps_tolerance_meters, gps_tolerance_meters),
      enforce_proximity    = coalesce(p_enforce_proximity, enforce_proximity),
      call_window_seconds  = coalesce(p_call_window_seconds, call_window_seconds)
    where id = p_id
    returning * into v_row;

    if v_row.id is null then
      raise exception 'Quadra não encontrada.' using errcode = 'NQ025';
    end if;
  end if;

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean, integer
) from public;

grant execute on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean, integer
) to authenticated;

-- ---------------------------------------------------------------------
-- Dados que já existiam
-- ---------------------------------------------------------------------

-- Um mandante do "quem ganha fica" está 'playing' sem turno aberto. No
-- modelo novo isso não existe: o turno dele acabou.
update public.queue_entries e
   set status = 'done', ended_at = coalesce(e.ended_at, now())
 where e.status = 'playing'
   and not exists (
     select 1 from public.matches mt
     where mt.ended_at is null and mt.side_a_entry_id = e.id
   );

-- Um turno aberto com lado B (gravado antes desta migration) segue até
-- o fim do slot; close_match encerra os dois lados.
update public.courts set holder_entry_id = null where holder_entry_id is not null;

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
grant execute on function public.request_join(text, uuid, boolean)       to authenticated;
grant execute on function public.decide_join_request(uuid, boolean)      to authenticated;
grant execute on function public.cancel_join_request(uuid)               to authenticated;
grant execute on function public.join_with_pin(text, text, boolean)      to authenticated;
grant execute on function public.finish_my_turn(uuid)                    to authenticated;
grant execute on function public.finish_match(uuid)                      to authenticated;
grant execute on function public.check_in_and_start(text)                to authenticated;
grant execute on function public.leave_queue(uuid, text)                 to authenticated;
grant execute on function public.join_queue(text, public.queue_mode, text) to authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20261019120000_endereco_e_tolerancia.sql
-- ####################################################################

-- =====================================================================
-- Reconciliação: endereço + alfinete (PR #12) e tolerância de chamada
-- (PR #13) na mesma função
--
-- As duas entregas mexeram em `admin_upsert_court` e `admin_overview`
-- ao mesmo tempo, em ramos diferentes. A resolução do conflito manteve
-- as duas versões lado a lado, e o estrago foi este:
--
--   . o `drop function` do ramo dos grupos nomeia a assinatura de 14
--     parâmetros, que deixou de existir quando o endereço entrou. Ele
--     não derruba nada ("does not exist, skipping") e, logo abaixo,
--     cria uma SEGUNDA versão. Com todos os parâmetros opcionais, o
--     Postgres não tem como escolher entre as duas:
--     `function public.admin_upsert_court(unknown, uuid) is not unique`;
--   . o `admin_overview` do ramo dos grupos é uma cópia de antes do
--     endereço, com `call_window_seconds` somado. Ao rodar por último,
--     ele apaga o `address` que o formulário de administração lê — os
--     campos de endereço reabrem vazios.
--
-- Esta migration faz o que a resolução deveria ter feito: derruba as
-- DUAS assinaturas pelo nome completo e deixa uma só função, com
-- endereço e tolerância juntos. O `admin_overview` volta a devolver
-- `address` sem perder `call_window_seconds`.
-- =====================================================================

-- ---------------------------------------------------------------------
-- O painel devolve as duas coisas
-- ---------------------------------------------------------------------
create or replace function public.admin_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.require_admin();

  return jsonb_build_object(
    'parks', coalesce((
      select jsonb_agg(p order by p.name)
      from (
        select jsonb_build_object(
          'id',        pk.id,
          'slug',      pk.slug::text,
          'name',      pk.name,
          'district',  pk.district,
          'city',      pk.city,
          'address',   pk.address,
          'latitude',  pk.latitude,
          'longitude', pk.longitude,
          'tone_color', pk.tone_color,
          'photo_alt', pk.photo_alt,
          'is_active', pk.is_active,
          'courts', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'id',            c.id,
                'slug',          c.slug::text,
                'name',          c.name,
                'court_number',  c.court_number,
                'surface',       c.surface,
                'surface_label', case c.surface
                                   when 'clay' then 'Saibro'
                                   when 'hard' then 'Rápida'
                                   else 'Grama'
                                 end,
                'address',       c.address,
                'latitude',      c.latitude,
                'longitude',     c.longitude,
                'slot_minutes',  c.slot_minutes,
                'call_window_seconds', c.call_window_seconds,
                'is_active',     c.is_active,
                'status',        c.status,
                'has_qr_code',   c.has_qr_code,
                'has_nfc_tag',   c.has_nfc_tag,
                'max_distance_meters',  c.max_distance_meters,
                'gps_tolerance_meters', c.gps_tolerance_meters,
                'enforce_proximity',    c.enforce_proximity,
                'qr_secret_version',    c.qr_secret_version,
                'queue_length',  (
                  select count(*) from public.queue_entries q
                  where q.court_id = c.id and q.status in ('waiting', 'ready')
                )
              ) order by c.court_number
            )
            from public.courts c where c.park_id = pk.id
          ), '[]'::jsonb)
        ) as p, pk.name
        from public.parks pk
      ) p
    ), '[]'::jsonb),
    'totals', (
      select jsonb_build_object(
        'parks',  (select count(*) from public.parks),
        'courts', (select count(*) from public.courts),
        'users',  (select count(*) from public.profiles)
      )
    )
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Uma função só, com endereço e tolerância
--
-- Os dois `drop` abaixo são o conserto: cada um nomeia uma das versões
-- que ficaram vivas. Rodar de novo não dói — o `if exists` cobre.
-- ---------------------------------------------------------------------

-- a que o endereço criou
drop function if exists public.admin_upsert_court(
  uuid, uuid, smallint, text, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean
);

-- a que os grupos criaram
drop function if exists public.admin_upsert_court(
  uuid, uuid, smallint, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean, integer
);

create or replace function public.admin_upsert_court(
  p_id           uuid    default null,
  p_park_id      uuid    default null,
  p_court_number smallint default null,
  p_surface      text    default null,
  p_name         text    default null,
  p_address      text    default null,
  p_latitude     double precision default null,
  p_longitude    double precision default null,
  p_slot_minutes smallint default null,
  p_has_qr_code  boolean default null,
  p_has_nfc_tag  boolean default null,
  p_is_active    boolean default null,
  p_max_distance_meters  integer default null,
  p_gps_tolerance_meters integer default null,
  p_enforce_proximity    boolean default null,
  p_call_window_seconds  integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row    public.courts;
  v_park   public.parks;
  v_number smallint;
  v_name   text;
begin
  perform public.require_admin();

  if p_id is null then
    select * into v_park from public.parks where id = p_park_id;
    if v_park.id is null then
      raise exception 'Parque não encontrado.' using errcode = 'NQ025';
    end if;

    v_number := coalesce(
      p_court_number,
      (select coalesce(max(court_number), 0) + 1 from public.courts where park_id = v_park.id)::smallint
    );
    v_name := coalesce(nullif(trim(p_name), ''), 'Quadra ' || lpad(v_number::text, 2, '0'));

    insert into public.courts (
      park_id, court_number, surface, slug, name,
      address, latitude, longitude, city, slot_minutes, has_qr_code, has_nfc_tag,
      max_distance_meters, gps_tolerance_meters, enforce_proximity, call_window_seconds
    )
    values (
      v_park.id, v_number,
      coalesce(p_surface, 'clay')::public.court_surface,
      public.unique_slug('courts', v_park.slug::text || '-q' || v_number),
      v_name,
      coalesce(nullif(trim(p_address), ''), v_park.address),
      coalesce(p_latitude, v_park.latitude),
      coalesce(p_longitude, v_park.longitude),
      v_park.city,
      coalesce(p_slot_minutes, 40::smallint),
      coalesce(p_has_qr_code, true),
      coalesce(p_has_nfc_tag, false),
      coalesce(p_max_distance_meters, 1000),
      coalesce(p_gps_tolerance_meters, 200),
      coalesce(p_enforce_proximity, true),
      coalesce(p_call_window_seconds, 120)
    )
    returning * into v_row;
  else
    update public.courts set
      court_number = coalesce(p_court_number, court_number),
      surface      = coalesce(p_surface::public.court_surface, surface),
      name         = coalesce(nullif(trim(p_name), ''), name),
      address      = coalesce(nullif(trim(p_address), ''), address),
      latitude     = coalesce(p_latitude, latitude),
      longitude    = coalesce(p_longitude, longitude),
      slot_minutes = coalesce(p_slot_minutes, slot_minutes),
      has_qr_code  = coalesce(p_has_qr_code, has_qr_code),
      has_nfc_tag  = coalesce(p_has_nfc_tag, has_nfc_tag),
      is_active    = coalesce(p_is_active, is_active),
      max_distance_meters  = coalesce(p_max_distance_meters, max_distance_meters),
      gps_tolerance_meters = coalesce(p_gps_tolerance_meters, gps_tolerance_meters),
      enforce_proximity    = coalesce(p_enforce_proximity, enforce_proximity),
      call_window_seconds  = coalesce(p_call_window_seconds, call_window_seconds)
    where id = p_id
    returning * into v_row;

    if v_row.id is null then
      raise exception 'Quadra não encontrada.' using errcode = 'NQ025';
    end if;
  end if;

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean, integer
) from public;

grant execute on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean, integer
) to authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20261023120000_anfitriao_enums.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 5
-- 28. Tipos novos da fila com anfitrião
--
-- Separado da migration seguinte pelo mesmo motivo da Sprint 4: um
-- valor novo de enum não pode ser usado na transação que o criou.
-- =====================================================================

-- Como a presença foi provada:
--   host_invite  o QR na tela de alguém da fila
--   gps          só a localização — o botão "Entrando na quadra" e a
--                abertura da fila, nas quadras sem nada na placa
alter type public.scan_method add value if not exists 'host_invite';
alter type public.scan_method add value if not exists 'gps';

-- Chegou a vez de um grupo sem app: quem organiza a fila marca a entrada.
alter type public.notification_type add value if not exists 'host_offline_called';


-- ####################################################################
-- Origem: supabase/migrations/20261023120100_fila_com_anfitriao.sql
-- ####################################################################

-- =====================================================================
-- NEQST — Sprint 5
-- 29. A fila com anfitrião (docs/sprint5.md)
--
-- Um piloto sem nada colado no parque. A primeira pessoa com o app abre
-- a fila da quadra e vira o anfitrião: informa quem já está jogando e
-- quem espera sem app. Quem chega depois entra pelo QR na tela de
-- alguém da fila — um convite que troca a cada 30 s e vale 10 min —, e
-- a presença continua provada pelo GPS contra a coordenada da quadra,
-- conferido na Edge Function scan-court.
--
--   1. Cada quadra tem um modo: 'fixed_qr' (o de sempre) ou 'host'.
--      No modo anfitrião a distância não pode ser desligada.
--   2. Uma fila com anfitrião aberta por quadra.
--   3. Vagas sem app: na frente, só na abertura; depois, só no fim.
--      Só o anfitrião mexe nelas, e elas não seguem a tolerância.
--   4. O anfitrião que sai da fila passa o papel ao próximo com app.
--   5. Check-in pelo botão "Entrando na quadra" (scan token 'gps').
--   6. A fila esquecida encerra com 30 min sem ninguém e sem turno.
--   7. A origem de cada entrada fica gravada para o painel do piloto.
--
-- Códigos novos:
--   NQ030 a quadra não está no modo anfitrião
--   NQ031 já existe uma fila aberta nesta quadra
--   NQ032 dados da fila com anfitrião inválidos
--   NQ033 só quem organiza a fila faz isso
--   NQ034 a fila desta quadra não está aberta
--   NQ035 no modo anfitrião a distância não pode ser desligada
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. O modo da quadra
-- ---------------------------------------------------------------------
alter table public.courts
  add column if not exists queue_mode text not null default 'fixed_qr';

do $$ begin
  alter table public.courts
    add constraint courts_queue_mode_check check (queue_mode in ('fixed_qr', 'host'));
exception when duplicate_object then null; end $$;

-- Sem a distância, o print do QR mandado no WhatsApp funcionaria de casa.
do $$ begin
  alter table public.courts
    add constraint courts_host_mode_needs_proximity
    check (queue_mode <> 'host' or enforce_proximity);
exception when duplicate_object then null; end $$;

comment on column public.courts.queue_mode is
  'fixed_qr: entra pelo QR impresso ou NFC. host: piloto sem nada na placa — '
  'a primeira pessoa abre a fila e os próximos entram pelo QR na tela de quem já está nela.';

-- ---------------------------------------------------------------------
-- 2. A fila aberta por um anfitrião
-- ---------------------------------------------------------------------
create table if not exists public.host_sessions (
  id                 uuid primary key default gen_random_uuid(),
  court_id           uuid not null references public.courts (id) on delete cascade,
  opened_by          uuid not null references auth.users (id) on delete cascade,
  host_user_id       uuid references auth.users (id) on delete set null,
  playing_minutes    smallint,
  waiting_declared   smallint not null default 0,
  opened_at          timestamptz not null default clock_timestamp(),
  closed_at          timestamptz,
  close_reason       text
);

comment on table public.host_sessions is
  'Uma fila aberta pelo anfitrião numa quadra sem QR na placa. host_user_id é quem organiza agora.';
comment on column public.host_sessions.playing_minutes is
  'Quanto faltava para o turno de quem já estava jogando, como o anfitrião informou.';

-- Duas pessoas abrindo ao mesmo tempo: a segunda cai na fila da primeira.
create unique index if not exists host_sessions_one_open_per_court
  on public.host_sessions (court_id)
  where closed_at is null;

create index if not exists host_sessions_opened_idx on public.host_sessions (opened_at);

alter table public.host_sessions enable row level security;
revoke all on public.host_sessions from anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Vagas sem app
--
-- Uma vaga sem membros: as pessoas que já estavam na fila antes do app.
-- created_by é o anfitrião que a registrou — ele não vira membro dela,
-- então continua livre para a própria vaga.
-- ---------------------------------------------------------------------
alter table public.queue_entries
  add column if not exists is_offline      boolean not null default false,
  add column if not exists offline_label   text,
  add column if not exists offline_kind    text,
  add column if not exists host_session_id uuid references public.host_sessions (id) on delete set null;

do $$ begin
  alter table public.queue_entries
    add constraint queue_entries_offline_label_check
    check (offline_label is null or char_length(offline_label) <= 40);
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.queue_entries
    add constraint queue_entries_offline_kind_check
    check ((offline_kind is null) = (not is_offline)
           and (offline_kind is null or offline_kind in ('playing', 'waiting')));
exception when duplicate_object then null; end $$;

comment on column public.queue_entries.is_offline is
  'Vaga de quem está na fila sem o app. Só o anfitrião anda com ela; não segue a tolerância.';
comment on column public.queue_entries.offline_label is
  'Como o anfitrião reconhece o grupo ("dupla de boné azul"). Visível na fila.';
comment on column public.queue_entries.offline_kind is
  'playing: o turno de quem já jogava quando a fila abriu. waiting: um grupo sem app na fila.';

create index if not exists queue_entries_host_session_idx
  on public.queue_entries (host_session_id)
  where host_session_id is not null;

-- Toda vaga aberta numa quadra com fila de anfitrião pertence a ela.
create or replace function public.queue_entry_set_host_session()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.host_session_id is null then
    select s.id into new.host_session_id
    from public.host_sessions s
    where s.court_id = new.court_id and s.closed_at is null;
  end if;
  return new;
end;
$$;

drop trigger if exists queue_entries_set_host_session on public.queue_entries;
create trigger queue_entries_set_host_session
  before insert on public.queue_entries
  for each row execute function public.queue_entry_set_host_session();

-- ---------------------------------------------------------------------
-- 4. O convite do QR na tela
-- ---------------------------------------------------------------------
create table if not exists public.host_invites (
  id          uuid primary key default gen_random_uuid(),
  session_id  uuid not null references public.host_sessions (id) on delete cascade,
  court_id    uuid not null references public.courts (id) on delete cascade,
  issued_by   uuid not null references auth.users (id) on delete cascade,
  -- Cada vez que alguém abre o QR na tela é uma exibição; o código
  -- troca a cada 30 s dentro dela.
  display_id  uuid not null,
  code_hash   text not null unique,
  issued_at   timestamptz not null default clock_timestamp(),
  expires_at  timestamptz not null
);

comment on table public.host_invites is
  'Códigos do QR mostrado na tela de quem está na fila. O banco guarda só o SHA-256.';
comment on column public.host_invites.expires_at is
  '10 min: o tempo de baixar o app e criar a conta. A presença é conferida depois, pelo GPS.';

create index if not exists host_invites_court_idx  on public.host_invites (court_id, issued_at desc);
create index if not exists host_invites_issuer_idx on public.host_invites (issued_by);

alter table public.host_invites enable row level security;
revoke all on public.host_invites from anon, authenticated;

alter table public.scan_tokens
  add column if not exists invite_id uuid references public.host_invites (id) on delete set null;

-- ---------------------------------------------------------------------
-- 5. A origem de cada entrada
--
-- scan_tokens é apagado depois de um dia, então a origem vai para a
-- própria linha do membro, que fica.
-- ---------------------------------------------------------------------
alter table public.queue_entry_members
  add column if not exists origin    text,
  add column if not exists invite_id uuid references public.host_invites (id) on delete set null;

comment on column public.queue_entry_members.origin is
  'Como a pessoa provou presença ao entrar: qr, nfc, host_invite (QR na tela de alguém) '
  'ou host_open (abriu a fila como anfitrião).';

-- O scan que trouxe a pessoa, na ordem em que dá para ter certeza:
--   1. quem abriu a vaga: o token gravado nela;
--   2. quem foi aceito: o token do pedido, gasto até 10 min antes;
--   3. quem entrou com o PIN: o token que a mesma transação ainda vai
--      gastar — o único dela nesta quadra que segue valendo.
create or replace function public.queue_member_set_origin()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token  uuid;
  v_method public.scan_method;
  v_invite uuid;
begin
  if new.origin is not null then
    return new;
  end if;

  select e.scan_token_id into v_token
  from public.queue_entries e
  where e.id = new.entry_id and e.created_by = new.user_id;

  if v_token is null then
    select r.scan_token_id into v_token
    from public.queue_join_requests r
    where r.entry_id = new.entry_id and r.user_id = new.user_id and r.status = 'pending'
    order by r.created_at desc
    limit 1;
  end if;

  if v_token is not null then
    select t.method, t.invite_id into v_method, v_invite
    from public.scan_tokens t where t.id = v_token;
  else
    select t.method, t.invite_id into v_method, v_invite
    from public.scan_tokens t
    where t.user_id = new.user_id
      and t.court_id = new.court_id
      and t.created_at > now() - interval '30 minutes'
    order by (t.consumed_at is null) desc, (t.expires_at > now()) desc, t.created_at desc
    limit 1;
  end if;

  new.origin := case
                  when v_method is null  then 'unknown'
                  when v_method = 'gps'  then 'host_open'
                  else v_method::text
                end;
  new.invite_id := v_invite;
  return new;
end;
$$;

drop trigger if exists queue_entry_members_set_origin on public.queue_entry_members;
create trigger queue_entry_members_set_origin
  before insert on public.queue_entry_members
  for each row execute function public.queue_member_set_origin();

-- ---------------------------------------------------------------------
-- 6. O que acontece com o convite antes de virar uma entrada
-- ---------------------------------------------------------------------
create table if not exists public.pilot_events (
  id              bigint generated always as identity primary key,
  court_id        uuid references public.courts (id) on delete cascade,
  invite_id       uuid references public.host_invites (id) on delete set null,
  user_id         uuid references auth.users (id) on delete set null,
  visitor         text check (visitor is null or char_length(visitor) <= 64),
  event           text not null check (event in ('invite_opened', 'invite_scanned', 'invite_too_far')),
  distance_meters double precision,
  created_at      timestamptz not null default now()
);

comment on table public.pilot_events is
  'Funil do convite: aberto (antes do login), validado pelo GPS e recusado por distância.';

-- Recarregar a página não conta duas vezes.
create unique index if not exists pilot_events_open_once
  on public.pilot_events (invite_id, visitor)
  where event = 'invite_opened';

create index if not exists pilot_events_court_idx on public.pilot_events (court_id, created_at);

alter table public.pilot_events enable row level security;
revoke all on public.pilot_events from anon, authenticated;

-- ---------------------------------------------------------------------
-- Quem organiza a fila
-- ---------------------------------------------------------------------

-- Ainda tem alguém com o app nesta quadra (na fila ou jogando)?
create or replace function public.court_has_app_players(p_court_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.queue_entry_members m
    join public.queue_entries e on e.id = m.entry_id
    where e.court_id = p_court_id
      and m.is_active
      and not e.is_offline
      and e.status in ('waiting', 'ready', 'playing')
  );
$$;

-- Esquecida: ninguém com o app, nenhum turno rolando e 30 min sem
-- nada acontecer. As vagas sem app não seguram a fila aberta — sem
-- ninguém com o app, não há quem ande com elas.
create or replace function public.host_session_is_idle(p_session_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not public.court_has_app_players(s.court_id)
     and not exists (
       select 1 from public.matches mt
       where mt.court_id = s.court_id and mt.ended_at is null and mt.expires_at > now()
     )
     and greatest(
           s.opened_at,
           (select max(greatest(e.joined_at, e.started_at, e.ended_at, e.left_at))
              from public.queue_entries e
             where e.host_session_id = s.id and not e.is_offline)
         ) < now() - interval '30 minutes'
  from public.host_sessions s
  where s.id = p_session_id;
$$;

-- A fila aberta desta quadra, se ainda estiver valendo.
create or replace function public.current_host_session(p_court_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select s.id
  from public.host_sessions s
  where s.court_id = p_court_id
    and s.closed_at is null
    and not public.host_session_is_idle(s.id);
$$;

-- Quem organiza agora: o anfitrião enquanto estiver na fila; saiu, o
-- dono da próxima vaga com app (quem espera antes de quem está jogando).
create or replace function public.effective_host(p_court_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      select s.host_user_id
      from public.host_sessions s
      where s.id = public.current_host_session(p_court_id)
        and exists (
          select 1
          from public.queue_entry_members m
          join public.queue_entries e on e.id = m.entry_id
          where m.user_id = s.host_user_id
            and m.is_active
            and e.court_id = p_court_id
            and not e.is_offline
            and e.status in ('waiting', 'ready', 'playing')
        )
    ),
    (
      select m.user_id
      from public.queue_entry_members m
      join public.queue_entries e on e.id = m.entry_id
      where public.current_host_session(p_court_id) is not null
        and e.court_id = p_court_id
        and m.is_active
        and m.role = 'owner'
        and not e.is_offline
        and e.status in ('waiting', 'ready', 'playing')
      order by (e.status = 'playing'), e.queue_number, m.created_at
      limit 1
    )
  );
$$;

-- Confere que quem chama organiza a fila e grava a herança, se houve.
create or replace function public.require_host(p_court_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user    uuid := auth.uid();
  v_session uuid;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  v_session := public.current_host_session(p_court_id);
  if v_session is null then
    raise exception 'A fila desta quadra não está aberta' using errcode = 'NQ034';
  end if;

  perform 1 from public.host_sessions s where s.id = v_session for update;

  if public.effective_host(p_court_id) is distinct from v_user then
    raise exception 'Só quem organiza a fila desta quadra faz isso' using errcode = 'NQ033';
  end if;

  update public.host_sessions
     set host_user_id = v_user
   where id = v_session and host_user_id is distinct from v_user;

  return v_session;
end;
$$;

-- Fecha a fila: as vagas sem app que ainda esperavam saem junto.
create or replace function public.close_host_session(p_session_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session public.host_sessions%rowtype;
  v_called  boolean;
begin
  update public.host_sessions
     set closed_at = now(), close_reason = p_reason
   where id = p_session_id and closed_at is null
  returning * into v_session;

  if not found then
    return;
  end if;

  select exists (
    select 1 from public.queue_entries e
    where e.court_id = v_session.court_id and e.is_offline and e.status = 'ready'
  ) into v_called;

  update public.queue_entries
     set status = 'cancelled', left_at = now(), cancel_reason = 'session_closed'
   where court_id = v_session.court_id
     and is_offline
     and status in ('waiting', 'ready');

  if v_called then
    perform public.call_next_team(v_session.court_id);
  end if;
end;
$$;

create or replace function public.close_idle_host_sessions(p_court_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session record;
  v_closed  integer := 0;
begin
  for v_session in
    select s.id
    from public.host_sessions s
    where s.closed_at is null
      and (p_court_id is null or s.court_id = p_court_id)
      and public.host_session_is_idle(s.id)
  loop
    perform public.close_host_session(v_session.id, 'idle');
    v_closed := v_closed + 1;
  end loop;

  return v_closed;
end;
$$;

revoke all on function public.court_has_app_players(uuid)        from public, anon, authenticated;
revoke all on function public.host_session_is_idle(uuid)         from public, anon, authenticated;
revoke all on function public.current_host_session(uuid)         from public, anon, authenticated;
revoke all on function public.effective_host(uuid)               from public, anon, authenticated;
revoke all on function public.require_host(uuid)                 from public, anon, authenticated;
revoke all on function public.close_host_session(uuid, text)     from public, anon, authenticated;
revoke all on function public.close_idle_host_sessions(uuid)     from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Chamar o próximo: a vaga sem app não tem tolerância
--
-- Ninguém nela tem como fazer check-in. A fila espera o anfitrião marcar
-- que entraram (ou que desistiram), e é ele quem recebe o aviso.
-- ---------------------------------------------------------------------
create or replace function public.call_next_team(p_court_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court   public.courts%rowtype;
  v_next    public.queue_entries%rowtype;
  v_host    uuid;
begin
  select * into v_court from public.courts c where c.id = p_court_id;
  if not found then
    return null;
  end if;

  -- Só chama se a quadra estiver livre.
  if exists (select 1 from public.matches mt
             where mt.court_id = p_court_id and mt.ended_at is null) then
    return null;
  end if;

  select e.* into v_next
  from public.queue_positions qp
  join public.queue_entries e on e.id = qp.entry_id
  where qp.court_id = p_court_id
  order by qp.position
  limit 1;

  if v_next.id is null then
    return null;
  end if;

  update public.queue_entries
     set status          = 'ready',
         called_at       = coalesce(called_at, now()),
         call_expires_at = case
                             when is_offline then null
                             else now() + make_interval(secs => v_court.call_window_seconds)
                           end
   where id = v_next.id and status = 'waiting';

  if found and v_next.is_offline then
    v_host := public.effective_host(p_court_id);
    if v_host is not null then
      perform public.enqueue_user_notification(
        v_host, p_court_id, 'host_offline_called',
        'Vez do grupo sem app',
        format('%s pode entrar na %s. Marque no app quando entrarem.',
               coalesce(v_next.offline_label, 'O grupo sem app'),
               public.court_label(v_court.court_number)),
        jsonb_build_object('court_id', p_court_id, 'entry_id', v_next.id)
      );
    end if;
  end if;

  return v_next.id;
end;
$$;

revoke all on function public.call_next_team(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Prova de presença: o token 'gps' só serve para abrir a fila e para o
-- check-in. Entrar na fila de alguém continua exigindo o QR — o da
-- placa ou o da tela de quem já está nela.
-- ---------------------------------------------------------------------
drop function if exists public.take_scan_token(text, text);

create or replace function public.take_scan_token(
  p_scan_token text,
  p_message    text,
  p_allow_gps  boolean default false
)
returns public.scan_tokens
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token public.scan_tokens%rowtype;
begin
  select * into v_token
  from public.scan_tokens t
  where t.token_hash = public.hash_scan_token(p_scan_token)
  for update;

  if not found
     or v_token.user_id is distinct from auth.uid()
     or v_token.consumed_at is not null
     or v_token.expires_at <= now()
     or (v_token.method = 'gps' and not coalesce(p_allow_gps, false)) then
    raise exception '%', p_message using errcode = 'NQ002';
  end if;

  return v_token;
end;
$$;

revoke all on function public.take_scan_token(text, text, boolean) from public, anon, authenticated;

-- Check-in: igual ao da Sprint 4, aceitando o botão "Entrando na quadra".
create or replace function public.check_in_and_start(p_scan_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user  uuid := auth.uid();
  v_token public.scan_tokens%rowtype;
  v_entry public.queue_entries%rowtype;
  v_match uuid;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  v_token := public.take_scan_token(p_scan_token,
    'Confirme na quadra que você chegou', true);

  select e.* into v_entry
  from public.queue_entry_members m
  join public.queue_entries e on e.id = m.entry_id
  where m.user_id = v_user and m.is_active and e.court_id = v_token.court_id;

  if not found then
    raise exception 'Você não está na fila desta quadra' using errcode = 'NQ007';
  end if;

  if v_entry.status <> 'playing' then
    if v_entry.status = 'ready'
       and v_entry.call_expires_at is not null
       and v_entry.call_expires_at <= now() then
      raise exception 'O tempo para o check-in terminou' using errcode = 'NQ016';
    end if;

    -- O turno anterior pode ter vencido sem o cron ter passado ainda.
    perform public.advance_court(v_entry.court_id);
    perform public.open_match(v_entry.id);
  end if;

  update public.queue_entry_members
     set checked_in_at = coalesce(checked_in_at, now())
   where entry_id = v_entry.id and user_id = v_user and is_active;

  update public.scan_tokens
     set consumed_at = now(), consumed_by_entry = v_entry.id
   where id = v_token.id;

  select mt.id into v_match
  from public.matches mt
  where mt.ended_at is null and v_entry.id in (mt.side_a_entry_id, mt.side_b_entry_id);

  return case when v_match is null then public.queue_entry_state(v_entry.id)
              else public.match_state(v_match) end;
end;
$$;

-- ---------------------------------------------------------------------
-- Abrir a fila
-- ---------------------------------------------------------------------
create or replace function public.open_host_queue(
  p_scan_token      text,
  p_playing_minutes integer default null,
  p_waiting_labels  text[]  default '{}'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid := auth.uid();
  v_token    public.scan_tokens%rowtype;
  v_court    public.courts%rowtype;
  v_session  uuid;
  v_entry_id uuid;
  v_waiting  integer := coalesce(cardinality(p_waiting_labels), 0);
  v_label    text;
  v_state    jsonb;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  v_token := public.take_scan_token(p_scan_token,
    'Confirme a sua localização na quadra para abrir a fila', true);

  -- A trava da quadra serializa duas aberturas ao mesmo tempo.
  select * into v_court from public.courts c where c.id = v_token.court_id for update;

  if not found or not v_court.is_active or v_court.status = 'unavailable' then
    raise exception 'Esta quadra está indisponível no momento' using errcode = 'NQ003';
  end if;
  if v_court.queue_mode <> 'host' then
    raise exception 'Esta quadra usa o QR Code da placa' using errcode = 'NQ030';
  end if;

  perform public.close_idle_host_sessions(v_court.id);

  if exists (select 1 from public.host_sessions s
             where s.court_id = v_court.id and s.closed_at is null) then
    raise exception 'Alguém já abriu a fila desta quadra. Peça o QR para quem está nela.'
      using errcode = 'NQ031';
  end if;

  v_state := public.player_state(v_user);
  if v_state ->> 'state' <> 'free' then
    raise exception 'Você já está na fila da %', v_state ->> 'court_name'
      using errcode = 'NQ014';
  end if;

  if v_waiting > 10 then
    raise exception 'Informe até 10 grupos esperando' using errcode = 'NQ032';
  end if;

  perform public.advance_court(v_court.id);

  if p_playing_minutes is not null then
    if p_playing_minutes < 1 or p_playing_minutes > v_court.slot_minutes then
      raise exception 'O turno em andamento vai de 1 a % minutos', v_court.slot_minutes
        using errcode = 'NQ032';
    end if;
    if exists (select 1 from public.matches mt
               where mt.court_id = v_court.id and mt.ended_at is null) then
      raise exception 'A quadra já tem um turno em andamento no app' using errcode = 'NQ032';
    end if;
  end if;

  insert into public.host_sessions
    (court_id, opened_by, host_user_id, playing_minutes, waiting_declared)
  values
    (v_court.id, v_user, v_user, p_playing_minutes, v_waiting)
  returning id into v_session;

  -- Quem já estava jogando: um turno sem app que acaba sozinho.
  if p_playing_minutes is not null then
    insert into public.queue_entries
      (court_id, created_by, status, is_offline, offline_kind, offline_label, host_session_id,
       called_at, started_at)
    values
      (v_court.id, v_user, 'playing', true, 'playing', 'Já estavam jogando', v_session, now(), now())
    returning id into v_entry_id;

    insert into public.matches (court_id, side_a_entry_id, mode, slot_minutes, expires_at)
    values (v_court.id, v_entry_id, 'single', v_court.slot_minutes,
            now() + make_interval(mins => p_playing_minutes));

    update public.courts set status = 'in_game', holder_entry_id = null where id = v_court.id;
  end if;

  -- Quem já esperava sem app: na frente do anfitrião, na ordem dada.
  if v_waiting > 0 then
    foreach v_label in array p_waiting_labels loop
      insert into public.queue_entries
        (court_id, created_by, is_offline, offline_kind, offline_label, host_session_id)
      values
        (v_court.id, v_user, true, 'waiting', nullif(left(trim(coalesce(v_label, '')), 40), ''), v_session);
    end loop;
  end if;

  -- A vaga do próprio anfitrião, depois de todos os declarados.
  insert into public.queue_entries (court_id, created_by, scan_token_id, host_session_id)
  values (v_court.id, v_user, v_token.id, v_session)
  returning id into v_entry_id;

  insert into public.queue_entry_members (entry_id, court_id, user_id, role, joined_via)
  values (v_entry_id, v_court.id, v_user, 'owner', 'owner');

  insert into public.queue_entry_pins (entry_id, pin)
  values (v_entry_id, public.new_group_pin(v_court.id));

  update public.queue_join_requests
     set status = 'cancelled', decided_at = now()
   where status = 'pending' and user_id = v_user;

  update public.scan_tokens
     set consumed_at = now(), consumed_by_entry = v_entry_id
   where id = v_token.id;

  perform public.call_next_team(v_court.id);

  return public.court_screen(v_court.id);
end;
$$;

-- ---------------------------------------------------------------------
-- O anfitrião e as vagas sem app
-- ---------------------------------------------------------------------

-- Quem chega sem app depois da abertura entra no fim da fila.
create or replace function public.host_add_offline(p_court_id uuid, p_label text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session uuid;
begin
  v_session := public.require_host(p_court_id);

  perform 1 from public.courts c where c.id = p_court_id for update;
  perform public.advance_court(p_court_id);

  insert into public.queue_entries
    (court_id, created_by, is_offline, offline_kind, offline_label, host_session_id)
  values
    (p_court_id, auth.uid(), true, 'waiting', nullif(left(trim(coalesce(p_label, '')), 40), ''), v_session);

  perform public.call_next_team(p_court_id);

  return public.court_screen(p_court_id);
end;
$$;

-- arrived: entraram na quadra · gave_up: desistiram · finished: saíram
create or replace function public.host_mark_offline(p_entry_id uuid, p_action text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry public.queue_entries%rowtype;
  v_match uuid;
begin
  select * into v_entry from public.queue_entries e where e.id = p_entry_id for update;
  if not found or not v_entry.is_offline then
    raise exception 'Vaga sem app não encontrada' using errcode = 'NQ007';
  end if;

  perform public.require_host(v_entry.court_id);

  if p_action = 'arrived' then
    if v_entry.status not in ('waiting', 'ready') then
      raise exception 'Esta vaga não está mais na fila' using errcode = 'NQ009';
    end if;
    perform public.advance_court(v_entry.court_id);
    perform public.open_match(v_entry.id);

  elsif p_action = 'gave_up' then
    if v_entry.status not in ('waiting', 'ready') then
      raise exception 'Esta vaga não está mais na fila' using errcode = 'NQ009';
    end if;
    update public.queue_entries
       set status = 'cancelled', left_at = now(), cancel_reason = 'offline_gave_up'
     where id = v_entry.id;
    if v_entry.status = 'ready' then
      perform public.call_next_team(v_entry.court_id);
    end if;

  elsif p_action = 'finished' then
    select mt.id into v_match
    from public.matches mt
    where mt.ended_at is null and mt.side_a_entry_id = v_entry.id;
    if v_match is null then
      raise exception 'Este grupo não está em quadra' using errcode = 'NQ009';
    end if;
    perform public.close_match(v_match, null, 'finished_by_group', auth.uid());

  else
    raise exception 'Ação desconhecida: %', p_action using errcode = 'NQ032';
  end if;

  return public.court_screen(v_entry.court_id);
end;
$$;

-- O grupo devolve a quadra; num turno sem app, quem devolve é o anfitrião.
create or replace function public.finish_my_turn(p_match_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user    uuid := auth.uid();
  v_match   public.matches%rowtype;
  v_offline boolean;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  select * into v_match from public.matches mt where mt.id = p_match_id;
  if not found then
    raise exception 'Partida não encontrada' using errcode = 'NQ018';
  end if;
  if v_match.ended_at is not null then
    raise exception 'Este turno já foi encerrado' using errcode = 'NQ009';
  end if;

  select e.is_offline into v_offline from public.queue_entries e where e.id = v_match.side_a_entry_id;

  if v_offline and not public.is_staff() then
    perform public.require_host(v_match.court_id);
  elsif not v_offline
        and not public.is_entry_member(v_match.side_a_entry_id, v_user)
        and not public.is_staff() then
    raise exception 'Só quem está no grupo encerra o turno' using errcode = 'NQ008';
  end if;

  return public.close_match(p_match_id, null, 'finished_by_group', v_user);
end;
$$;

-- ---------------------------------------------------------------------
-- O QR na tela
-- ---------------------------------------------------------------------
create or replace function public.issue_host_invite(p_court_id uuid, p_display_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user    uuid := auth.uid();
  v_court   public.courts%rowtype;
  v_session uuid;
  v_code    text;
  v_invite  public.host_invites%rowtype;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;
  if p_display_id is null then
    raise exception 'Exibição do QR sem identificador' using errcode = 'NQ032';
  end if;

  select * into v_court from public.courts c where c.id = p_court_id;
  if not found or v_court.queue_mode <> 'host' then
    raise exception 'Esta quadra usa o QR Code da placa' using errcode = 'NQ030';
  end if;

  v_session := public.current_host_session(p_court_id);
  if v_session is null then
    raise exception 'A fila desta quadra não está aberta' using errcode = 'NQ034';
  end if;

  -- Quem mostra já provou presença ao entrar: qualquer pessoa da fila.
  if not exists (
    select 1
    from public.queue_entry_members m
    join public.queue_entries e on e.id = m.entry_id
    where m.user_id = v_user and m.is_active
      and e.court_id = p_court_id
      and e.status in ('waiting', 'ready', 'playing')
  ) then
    raise exception 'Só quem está na fila desta quadra mostra o QR' using errcode = 'NQ008';
  end if;

  -- 18 bytes viram 24 caracteres de base64url, sem preenchimento.
  v_code := translate(encode(extensions.gen_random_bytes(18), 'base64'), '+/', '-_');

  insert into public.host_invites (session_id, court_id, issued_by, display_id, code_hash, expires_at)
  values (v_session, p_court_id, v_user, p_display_id, public.hash_scan_token(v_code),
          now() + interval '10 minutes')
  returning * into v_invite;

  return jsonb_build_object(
    'code',           v_code,
    'invite_id',      v_invite.id,
    'expires_at',     v_invite.expires_at,
    'rotate_seconds', 30,
    'valid_seconds',  600
  );
end;
$$;

-- Aberto antes do login: só conta, não dá acesso a nada.
create or replace function public.host_invite_opened(p_code text, p_visitor text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_invite public.host_invites%rowtype;
begin
  if p_visitor is null or char_length(p_visitor) > 64 then
    return;
  end if;

  select * into v_invite
  from public.host_invites i
  where i.code_hash = public.hash_scan_token(p_code);

  if not found then
    return;
  end if;

  insert into public.pilot_events (court_id, invite_id, user_id, visitor, event)
  values (v_invite.court_id, v_invite.id, auth.uid(), p_visitor, 'invite_opened')
  on conflict do nothing;
end;
$$;

-- ---------------------------------------------------------------------
-- Leituras
-- ---------------------------------------------------------------------
create or replace function public.match_state(p_match_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_match   public.matches%rowtype;
  v_court   public.courts%rowtype;
  v_entry   public.queue_entries%rowtype;
  v_players jsonb;
begin
  select * into v_match from public.matches mt where mt.id = p_match_id;
  if not found then
    raise exception 'Partida não encontrada' using errcode = 'NQ018';
  end if;

  select * into v_court from public.courts c where c.id = v_match.court_id;
  select * into v_entry from public.queue_entries e where e.id = v_match.side_a_entry_id;

  v_players := public.match_side_players(v_match.side_a_entry_id);

  return jsonb_build_object(
    'match_id',      v_match.id,
    'court_id',      v_match.court_id,
    'court_name',    public.court_label(v_court.court_number),
    'entry_id',      v_match.side_a_entry_id,
    'players',       v_players,
    'group_size',    jsonb_array_length(v_players),
    'group_label',   case when v_entry.is_offline then 'Sem app'
                          else public.group_label(jsonb_array_length(v_players)) end,
    'is_offline',    coalesce(v_entry.is_offline, false),
    'offline_label', v_entry.offline_label,
    'slot_minutes',  v_match.slot_minutes,
    'started_at',    v_match.started_at,
    'expires_at',    v_match.expires_at,
    'ended_at',      v_match.ended_at,
    'end_reason',    v_match.end_reason,
    'is_live',       v_match.ended_at is null,
    'elapsed_seconds',   greatest(0, floor(extract(epoch from (
                           coalesce(v_match.ended_at, now()) - v_match.started_at)))::integer),
    'remaining_seconds', case
                           when v_match.ended_at is not null then 0
                           else greatest(0, floor(extract(epoch from (
                             v_match.expires_at - now())))::integer)
                         end
  );
end;
$$;

create or replace function public.court_queue_items(p_court_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with court as (
    select c.id, c.slot_minutes,
           (select count(*) from public.matches mt
             where mt.court_id = c.id and mt.ended_at is null) as live,
           (select greatest(0, floor(extract(epoch from (mt.expires_at - now())))::integer)
              from public.matches mt
             where mt.court_id = c.id and mt.ended_at is null
             limit 1) as remaining
    from public.courts c where c.id = p_court_id
  ),
  q as (
    select qp.entry_id, qp.position, qp.status, qp.joined_at,
           e.call_expires_at, e.is_offline, e.offline_label,
           -- A raquete do grupo é a de quem está à frente dele. A vaga
           -- sem app não tem raquete: entra uma cinza na pilha.
           coalesce(
             (select jsonb_build_object(
                       'frame', pr.racket_frame_color,
                       'grip',  pr.racket_grip_color)
                from public.queue_entry_members mm
                join public.profiles pr on pr.id = mm.user_id
               where mm.entry_id = qp.entry_id and mm.is_active and mm.role = 'owner'
               limit 1),
             case when e.is_offline
                  then jsonb_build_object('frame', '#9AA39C', 'grip', '#F1ECEF') end
           ) as racket,
           public.match_side_players(qp.entry_id) as players
    from public.queue_positions qp
    join public.queue_entries e on e.id = qp.entry_id
    where qp.court_id = p_court_id
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'entry_id',    q.entry_id,
        'position',    q.position,
        'position_label', q.position || 'º',
        'group_size',  jsonb_array_length(q.players),
        'group_label', case when q.is_offline then 'Sem app'
                            else public.group_label(jsonb_array_length(q.players)) end,
        -- Mantido para o app anterior à Sprint 4.
        'mode_label',  case when q.is_offline then 'Sem app'
                            else public.group_label(jsonb_array_length(q.players)) end,
        'status',      q.status,
        'is_called',   q.status = 'ready',
        'call_expires_at', q.call_expires_at,
        'joined_at',   q.joined_at,
        'teams_ahead', (q.position - 1) + coalesce((select live from court), 0),
        'is_mine',     exists (
                         select 1 from public.queue_entry_members mm
                         where mm.entry_id = q.entry_id and mm.user_id = auth.uid() and mm.is_active
                       ),
        'is_offline',  q.is_offline,
        'offline_label', q.offline_label,
        'racket',      q.racket,
        'players',     q.players,
        -- "Ana S. + Bruno L. + 3": o nome de todo mundo não cabe na linha.
        'team_label',  case
          when q.is_offline then coalesce(q.offline_label, 'Grupo sem app')
          else (
            select string_agg(pl ->> 'short_name', ' + ' order by ord)
                     || case when jsonb_array_length(q.players) > 2
                             then ' + ' || (jsonb_array_length(q.players) - 2)
                             else '' end
            from jsonb_array_elements(q.players) with ordinality as t(pl, ord)
            where ord <= 2
          )
        end,
        'stack', (
          select coalesce(jsonb_agg(s.racket order by s.position), '[]'::jsonb)
          from (
            select q2.racket, q2.position
            from q q2
            where q2.position <= q.position and q2.racket is not null
            order by q2.position desc
            limit 5
          ) s
        ),
        'stack_more', greatest(q.position - 5, 0),
        'eta_seconds', coalesce((select remaining from court), 0)
                       + (q.position - 1) * (select slot_minutes from court) * 60
      )
      order by q.position
    ),
    '[]'::jsonb
  )
  from q;
$$;

create or replace function public.court_screen(p_court_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_court   public.courts%rowtype;
  v_park    public.parks%rowtype;
  v_match   uuid;
  v_items   jsonb;
  v_queue   integer;
  v_rem     integer := 0;
  v_mine    jsonb;
  v_state   jsonb;
  v_group   jsonb;
  v_req     jsonb;
  v_live    jsonb;
  v_session public.host_sessions%rowtype;
  v_host_id uuid;
  v_host    jsonb;
begin
  select * into v_court from public.courts c where c.id = p_court_id;
  if not found then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;

  select * into v_park from public.parks pk where pk.id = v_court.park_id;

  select mt.id,
         greatest(0, floor(extract(epoch from (mt.expires_at - now())))::integer)
  into v_match, v_rem
  from public.matches mt
  where mt.court_id = p_court_id and mt.ended_at is null
  limit 1;

  v_live  := case when v_match is null then null else public.match_state(v_match) end;
  v_items := public.court_queue_items(p_court_id);
  v_queue := jsonb_array_length(v_items);

  select i into v_mine
  from jsonb_array_elements(v_items) i
  where (i ->> 'is_mine')::boolean
  limit 1;

  v_state := public.player_state(auth.uid());

  if (v_state ->> 'court_id')::uuid = p_court_id then
    v_group := public.my_group((v_state ->> 'entry_id')::uuid);
  end if;

  v_req := public.my_join_request();
  if (v_req ->> 'court_id')::uuid is distinct from p_court_id then
    v_req := null;
  end if;

  -- A fila com anfitrião: quem organiza e o que quem olha pode fazer.
  if v_court.queue_mode = 'host' then
    select * into v_session
    from public.host_sessions s
    where s.id = public.current_host_session(p_court_id);

    if v_session.id is not null then
      v_host_id := public.effective_host(p_court_id);
      v_host := jsonb_build_object(
        'session_id', v_session.id,
        'opened_at',  v_session.opened_at,
        'host_name',  (select public.short_name_of(coalesce(pr.full_name, pr.username::text))
                         from public.profiles pr where pr.id = v_host_id),
        'is_me',      v_host_id is not null and v_host_id = auth.uid(),
        'can_show_invite', v_group is not null
      );
    end if;
  end if;

  return jsonb_build_object(
    'court', jsonb_build_object(
      'id',            v_court.id,
      'name',          public.court_label(v_court.court_number),
      'number',        v_court.court_number,
      'surface',       v_court.surface,
      'surface_label', case v_court.surface
                         when 'clay'  then 'Saibro'
                         when 'hard'  then 'Rápida'
                         else 'Grama'
                       end,
      'status',        v_court.status,
      'is_active',     v_court.is_active,
      'slot_minutes',  v_court.slot_minutes,
      'call_window_seconds', v_court.call_window_seconds,
      'queue_mode',    v_court.queue_mode,
      'checkin_methods', (
        select coalesce(jsonb_agg(m order by m), '[]'::jsonb)
        from (
          select 'qr'::text as m where v_court.has_qr_code and v_court.queue_mode = 'fixed_qr'
          union all
          select 'nfc'::text where v_court.has_nfc_tag and v_court.queue_mode = 'fixed_qr'
          union all
          select 'gps'::text where v_court.queue_mode = 'host'
        ) s
      ),
      'latitude',      v_court.latitude,
      'longitude',     v_court.longitude,
      'rating_avg',    v_court.rating_avg,
      'rating_count',  v_court.rating_count,
      'cover_photo_path', v_court.cover_photo_path
    ),
    'park', jsonb_build_object(
      'id',       v_park.id,
      'name',     v_park.name,
      'district', v_park.district
    ),
    'match',        v_live,
    'is_live',      v_match is not null,
    'status_text',  case when v_match is not null then 'Em jogo' else 'Livre' end,
    'players_line', case
                      when v_match is null then 'Sem jogo agora — check-in libera a quadra'
                      when (v_live ->> 'is_offline')::boolean
                        then coalesce(v_live ->> 'offline_label', 'Grupo sem app')
                      else (
                        select coalesce(string_agg(pl ->> 'short_name', ' · ' order by ord), 'Grupo em quadra')
                        from jsonb_array_elements(v_live -> 'players') with ordinality as t(pl, ord)
                      )
                    end,
    'queue',        v_items,
    'queue_length', v_queue,
    'queue_text',   case
                      when v_queue = 0 then 'Fila vazia'
                      else v_queue || ' na espera'
                    end,
    'remaining_seconds', coalesce(v_rem, 0),
    'total_wait_seconds', coalesce(v_rem, 0) + v_queue * v_court.slot_minutes * 60,
    'next_position_label', (v_queue + 1) || 'º',
    'my_entry',     v_mine,
    'my_group',     v_group,
    'my_request',   v_req,
    'host',         v_host,
    'can_open_host', v_court.queue_mode = 'host'
                     and v_host is null
                     and v_court.is_active
                     and v_court.status <> 'unavailable'
                     and (v_state ->> 'state') = 'free',
    'court_accepting', v_court.is_active and v_court.status <> 'unavailable',
    'can_join',     v_court.is_active
                    and v_court.status <> 'unavailable'
                    and (v_state ->> 'state') = 'free'
                    and (v_court.queue_mode = 'fixed_qr' or v_host is not null),
    'my_state',     v_state,
    'generated_at', now()
  );
end;
$$;

-- ---------------------------------------------------------------------
-- A rotina de minuto em minuto também fecha a fila esquecida
-- ---------------------------------------------------------------------
create or replace function public.advance_expired_queues()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court    record;
  v_result   jsonb;
  v_closed   integer := 0;
  v_expired  integer := 0;
  v_requests integer;
  v_sessions integer;
begin
  for v_court in
    select distinct court_id from (
      select court_id from public.matches
      where ended_at is null and expires_at <= now()
      union all
      select court_id from public.queue_entries
      where status = 'ready' and call_expires_at is not null and call_expires_at <= now()
    ) s
  loop
    v_result  := public.advance_court(v_court.court_id);
    v_closed  := v_closed + (v_result ->> 'matches_closed')::integer;
    v_expired := v_expired + (v_result ->> 'entries_expired')::integer;
  end loop;

  -- Pedido que ninguém respondeu, ou de um grupo que já saiu da fila.
  update public.queue_join_requests r
     set status = 'expired', decided_at = now()
   where r.status = 'pending'
     and (r.expires_at <= now()
          or not exists (select 1 from public.queue_entries e
                         where e.id = r.entry_id
                           and e.status in ('waiting', 'ready', 'playing')));
  get diagnostics v_requests = row_count;

  v_sessions := public.close_idle_host_sessions();

  return jsonb_build_object(
    'matches_closed',   v_closed,
    'entries_expired',  v_expired,
    'requests_expired', v_requests,
    'sessions_closed',  v_sessions,
    'ran_at', now()
  );
end;
$$;

revoke all on function public.advance_expired_queues() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Administração: o modo no formulário da quadra
-- ---------------------------------------------------------------------
create or replace function public.admin_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.require_admin();

  return jsonb_build_object(
    'parks', coalesce((
      select jsonb_agg(p order by p.name)
      from (
        select jsonb_build_object(
          'id',        pk.id,
          'slug',      pk.slug::text,
          'name',      pk.name,
          'district',  pk.district,
          'city',      pk.city,
          'address',   pk.address,
          'latitude',  pk.latitude,
          'longitude', pk.longitude,
          'tone_color', pk.tone_color,
          'photo_alt', pk.photo_alt,
          'is_active', pk.is_active,
          'courts', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'id',            c.id,
                'slug',          c.slug::text,
                'name',          c.name,
                'court_number',  c.court_number,
                'surface',       c.surface,
                'surface_label', case c.surface
                                   when 'clay' then 'Saibro'
                                   when 'hard' then 'Rápida'
                                   else 'Grama'
                                 end,
                'address',       c.address,
                'latitude',      c.latitude,
                'longitude',     c.longitude,
                'slot_minutes',  c.slot_minutes,
                'call_window_seconds', c.call_window_seconds,
                'is_active',     c.is_active,
                'status',        c.status,
                'has_qr_code',   c.has_qr_code,
                'has_nfc_tag',   c.has_nfc_tag,
                'max_distance_meters',  c.max_distance_meters,
                'gps_tolerance_meters', c.gps_tolerance_meters,
                'enforce_proximity',    c.enforce_proximity,
                'qr_secret_version',    c.qr_secret_version,
                'queue_mode',    c.queue_mode,
                'host_session_open', public.current_host_session(c.id) is not null,
                'queue_length',  (
                  select count(*) from public.queue_entries q
                  where q.court_id = c.id and q.status in ('waiting', 'ready')
                )
              ) order by c.court_number
            )
            from public.courts c where c.park_id = pk.id
          ), '[]'::jsonb)
        ) as p, pk.name
        from public.parks pk
      ) p
    ), '[]'::jsonb),
    'totals', (
      select jsonb_build_object(
        'parks',  (select count(*) from public.parks),
        'courts', (select count(*) from public.courts),
        'users',  (select count(*) from public.profiles)
      )
    )
  );
end;
$$;

drop function if exists public.admin_upsert_court(
  uuid, uuid, smallint, text, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean, integer
);

create or replace function public.admin_upsert_court(
  p_id           uuid    default null,
  p_park_id      uuid    default null,
  p_court_number smallint default null,
  p_surface      text    default null,
  p_name         text    default null,
  p_address      text    default null,
  p_latitude     double precision default null,
  p_longitude    double precision default null,
  p_slot_minutes smallint default null,
  p_has_qr_code  boolean default null,
  p_has_nfc_tag  boolean default null,
  p_is_active    boolean default null,
  p_max_distance_meters  integer default null,
  p_gps_tolerance_meters integer default null,
  p_enforce_proximity    boolean default null,
  p_call_window_seconds  integer default null,
  p_queue_mode           text    default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row     public.courts;
  v_before  public.courts;
  v_park    public.parks;
  v_number  smallint;
  v_name    text;
  v_session uuid;
begin
  perform public.require_admin();

  if p_queue_mode is not null and p_queue_mode not in ('fixed_qr', 'host') then
    raise exception 'Modo de fila desconhecido: %', p_queue_mode using errcode = 'NQ032';
  end if;

  if p_id is not null then
    select * into v_before from public.courts where id = p_id;
  end if;

  -- O banco recusaria pela constraint; aqui a mensagem diz o porquê.
  if coalesce(p_queue_mode, v_before.queue_mode, 'fixed_qr') = 'host'
     and not coalesce(p_enforce_proximity, v_before.enforce_proximity, true) then
    raise exception 'No modo anfitrião, a conferência de distância não pode ser desligada: '
                    'sem ela, o print do QR funcionaria de casa.'
      using errcode = 'NQ035';
  end if;

  if p_id is null then
    select * into v_park from public.parks where id = p_park_id;
    if v_park.id is null then
      raise exception 'Parque não encontrado.' using errcode = 'NQ025';
    end if;

    v_number := coalesce(
      p_court_number,
      (select coalesce(max(court_number), 0) + 1 from public.courts where park_id = v_park.id)::smallint
    );
    v_name := coalesce(nullif(trim(p_name), ''), 'Quadra ' || lpad(v_number::text, 2, '0'));

    insert into public.courts (
      park_id, court_number, surface, slug, name,
      address, latitude, longitude, city, slot_minutes, has_qr_code, has_nfc_tag,
      max_distance_meters, gps_tolerance_meters, enforce_proximity, call_window_seconds,
      queue_mode
    )
    values (
      v_park.id, v_number,
      coalesce(p_surface, 'clay')::public.court_surface,
      public.unique_slug('courts', v_park.slug::text || '-q' || v_number),
      v_name,
      coalesce(nullif(trim(p_address), ''), v_park.address),
      coalesce(p_latitude, v_park.latitude),
      coalesce(p_longitude, v_park.longitude),
      v_park.city,
      coalesce(p_slot_minutes, 40::smallint),
      coalesce(p_has_qr_code, true),
      coalesce(p_has_nfc_tag, false),
      coalesce(p_max_distance_meters, 1000),
      coalesce(p_gps_tolerance_meters, 200),
      coalesce(p_enforce_proximity, true),
      coalesce(p_call_window_seconds, 120),
      coalesce(p_queue_mode, 'fixed_qr')
    )
    returning * into v_row;
  else
    update public.courts set
      court_number = coalesce(p_court_number, court_number),
      surface      = coalesce(p_surface::public.court_surface, surface),
      name         = coalesce(nullif(trim(p_name), ''), name),
      address      = coalesce(nullif(trim(p_address), ''), address),
      latitude     = coalesce(p_latitude, latitude),
      longitude    = coalesce(p_longitude, longitude),
      slot_minutes = coalesce(p_slot_minutes, slot_minutes),
      has_qr_code  = coalesce(p_has_qr_code, has_qr_code),
      has_nfc_tag  = coalesce(p_has_nfc_tag, has_nfc_tag),
      is_active    = coalesce(p_is_active, is_active),
      max_distance_meters  = coalesce(p_max_distance_meters, max_distance_meters),
      gps_tolerance_meters = coalesce(p_gps_tolerance_meters, gps_tolerance_meters),
      enforce_proximity    = coalesce(p_enforce_proximity, enforce_proximity),
      call_window_seconds  = coalesce(p_call_window_seconds, call_window_seconds),
      queue_mode           = coalesce(p_queue_mode, queue_mode)
    where id = p_id
    returning * into v_row;

    if v_row.id is null then
      raise exception 'Quadra não encontrada.' using errcode = 'NQ025';
    end if;

    -- Saiu do modo anfitrião (a placa chegou): a fila aberta fecha, e as
    -- vagas sem app que esperavam saem com ela — sem anfitrião, ninguém
    -- teria como andar com elas.
    if v_before.queue_mode = 'host' and v_row.queue_mode <> 'host' then
      for v_session in
        select s.id from public.host_sessions s where s.court_id = v_row.id and s.closed_at is null
      loop
        perform public.close_host_session(v_session, 'mode_changed');
      end loop;
    end if;
  end if;

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean, integer, text
) from public;

grant execute on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean, integer, text
) to authenticated;

-- ---------------------------------------------------------------------
-- O painel do piloto
--
-- Contagens, não nomes: é o que vai na tela para a organização do
-- parque. Os dias são os de São Paulo.
-- ---------------------------------------------------------------------
create or replace function public.admin_pilot_stats(
  p_park_id uuid default null,
  p_from    date default null,
  p_to      date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz    constant text := 'America/Sao_Paulo';
  v_today date := (now() at time zone 'America/Sao_Paulo')::date;
  v_from  date;
  v_to    date;
  v_start timestamptz;
  v_end   timestamptz;
begin
  perform public.require_admin();

  v_to    := coalesce(p_to, v_today);
  v_from  := coalesce(p_from, v_to - 29);
  if v_from > v_to then
    raise exception 'O período começa depois de terminar' using errcode = 'NQ032';
  end if;
  if v_to - v_from > 366 then
    raise exception 'O período vai até um ano' using errcode = 'NQ032';
  end if;

  v_start := v_from::timestamp at time zone v_tz;
  v_end   := (v_to + 1)::timestamp at time zone v_tz;

  return (
    with courts as (
      select c.id, c.court_number, c.park_id, pk.name as park_name
      from public.courts c
      join public.parks pk on pk.id = c.park_id
      where p_park_id is null or c.park_id = p_park_id
    ),
    entries as (
      select e.*
      from public.queue_entries e
      join courts c on c.id = e.court_id
      where e.joined_at >= v_start and e.joined_at < v_end
    ),
    members as (
      select m.*, e.joined_at as entry_joined_at
      from public.queue_entry_members m
      join entries e on e.id = m.entry_id
      where not e.is_offline
    ),
    invites as (
      select i.*
      from public.host_invites i
      join courts c on c.id = i.court_id
      where i.issued_at >= v_start and i.issued_at < v_end
    ),
    events as (
      select ev.*
      from public.pilot_events ev
      join courts c on c.id = ev.court_id
      where ev.created_at >= v_start and ev.created_at < v_end
    ),
    turns as (
      select mt.*, e.is_offline
      from public.matches mt
      join courts c on c.id = mt.court_id
      join public.queue_entries e on e.id = mt.side_a_entry_id
      where mt.started_at >= v_start and mt.started_at < v_end
    ),
    waits as (
      select extract(epoch from (e.started_at - e.joined_at)) / 60.0 as minutes
      from entries e
      where not e.is_offline and e.started_at is not null
    ),
    invite_joins as (
      select m.user_id, i.issued_by, i.issued_at
      from members m
      join public.host_invites i on i.id = m.invite_id
      where m.origin = 'host_invite'
    ),
    spreaders as (
      select issued_by, count(distinct user_id) as brought
      from invite_joins
      group by issued_by
    )
    select jsonb_build_object(
      'period', jsonb_build_object('from', v_from, 'to', v_to),
      'totals', jsonb_build_object(
        'people',          (select count(distinct user_id) from members),
        'app_entries',     (select count(*) from entries where not is_offline),
        'offline_entries', (select count(*) from entries where is_offline
                              and offline_kind = 'waiting'),
        'sessions',        (select count(*) from public.host_sessions s
                              join courts c on c.id = s.court_id
                             where s.opened_at >= v_start and s.opened_at < v_end),
        'turns',           (select count(*) from turns where not is_offline),
        'hours_played',    round(coalesce((
                             select sum(extract(epoch from (least(coalesce(ended_at, now()), expires_at) - started_at)))
                             from turns
                           ), 0)::numeric / 3600, 1)
      ),
      'daily', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'day',             d.day,
                 'people',          (select count(distinct m.user_id) from members m
                                      where (m.entry_joined_at at time zone v_tz)::date = d.day),
                 'app_entries',     (select count(*) from entries e
                                      where not e.is_offline and (e.joined_at at time zone v_tz)::date = d.day),
                 'offline_entries', (select count(*) from entries e
                                      where e.is_offline and e.offline_kind = 'waiting'
                                        and (e.joined_at at time zone v_tz)::date = d.day)
               ) order by d.day), '[]'::jsonb)
        from (select generate_series(v_from, v_to, interval '1 day')::date as day) d
      ),
      'origins', (
        select coalesce(jsonb_object_agg(origin, n), '{}'::jsonb)
        from (select coalesce(origin, 'unknown') as origin, count(*) as n from members group by 1) o
      ),
      'funnel', jsonb_build_object(
        'shown',        (select count(distinct display_id) from invites),
        'opened',       (select count(distinct visitor) from events where event = 'invite_opened'),
        'scanned',      (select count(distinct user_id) from events where event = 'invite_scanned'),
        'too_far',      (select count(*) from events where event = 'invite_too_far'),
        'new_accounts', (select count(distinct ev.user_id)
                           from events ev
                           join auth.users u on u.id = ev.user_id
                           join public.host_invites i on i.id = ev.invite_id
                          where ev.event = 'invite_scanned' and u.created_at >= i.issued_at),
        'joined',       (select count(distinct user_id) from invite_joins)
      ),
      'wait', jsonb_build_object(
        'samples',    (select count(*) from waits),
        'median_min', (select round(percentile_cont(0.5) within group (order by minutes)::numeric, 1) from waits),
        'p90_min',    (select round(percentile_cont(0.9) within group (order by minutes)::numeric, 1) from waits)
      ),
      'by_hour', (
        select coalesce(jsonb_agg(jsonb_build_object('hour', h.hour, 'turns', h.turns) order by h.hour), '[]'::jsonb)
        from (
          select g.hour,
                 (select count(*) from turns t
                   where extract(hour from (t.started_at at time zone v_tz)) = g.hour) as turns
          from generate_series(0, 23) as g(hour)
        ) h
      ),
      'calls', jsonb_build_object(
        'called', (select count(*) from entries where not is_offline and called_at is not null),
        'missed', (select count(*) from entries where not is_offline and cancel_reason = 'no_show')
      ),
      'offline_hold', jsonb_build_object(
        'samples', (select count(*) from entries
                     where is_offline and called_at is not null
                       and coalesce(started_at, left_at) is not null
                       and offline_kind = 'waiting'),
        'avg_min', (select round(avg(extract(epoch from (coalesce(started_at, left_at) - called_at)) / 60.0)::numeric, 1)
                      from entries
                     where is_offline and called_at is not null
                       and coalesce(started_at, left_at) is not null
                       and offline_kind = 'waiting'),
        'max_min', (select round(max(extract(epoch from (coalesce(started_at, left_at) - called_at)) / 60.0)::numeric, 1)
                      from entries
                     where is_offline and called_at is not null
                       and coalesce(started_at, left_at) is not null
                       and offline_kind = 'waiting')
      ),
      'spreaders', jsonb_build_object(
        'people', (select count(*) from spreaders),
        'top',    (select coalesce(jsonb_agg(s.brought order by s.brought desc), '[]'::jsonb)
                     from (select brought from spreaders order by brought desc limit 5) s)
      ),
      'courts', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'court_id',        c.id,
                 'label',           c.park_name || ' · ' || public.court_label(c.court_number),
                 'people',          (select count(distinct m.user_id) from members m where m.court_id = c.id),
                 'app_entries',     (select count(*) from entries e where e.court_id = c.id and not e.is_offline),
                 'offline_entries', (select count(*) from entries e where e.court_id = c.id and e.is_offline
                                       and e.offline_kind = 'waiting')
               ) order by c.park_name, c.court_number), '[]'::jsonb)
        from courts c
      )
    )
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
grant execute on function public.open_host_queue(text, integer, text[]) to authenticated;
grant execute on function public.host_add_offline(uuid, text)           to authenticated;
grant execute on function public.host_mark_offline(uuid, text)          to authenticated;
grant execute on function public.issue_host_invite(uuid, uuid)          to authenticated;
grant execute on function public.host_invite_opened(text, text)         to anon, authenticated;
grant execute on function public.check_in_and_start(text)               to authenticated;
grant execute on function public.finish_my_turn(uuid)                   to authenticated;
grant execute on function public.admin_pilot_stats(uuid, date, date)    to authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20261027120000_painel_sem_copia.sql
-- ####################################################################

-- =====================================================================
-- O painel de administração deixa de ser copiado inteiro a cada mudança
--
-- `admin_overview` já foi recriada por inteiro em SEIS migrations. Cada
-- campo novo obrigava a recopiar ~90 linhas de `jsonb_build_object`, e
-- foi assim que o endereço se perdeu: o ramo dos grupos partiu de uma
-- cópia anterior ao endereço, somou `call_window_seconds` e, rodando
-- por último, apagou `address` do painel.
--
-- A forma de uma quadra e a de um parque passam a morar em duas funções
-- pequenas. Quem acrescentar um campo amanhã mexe numa linha de uma
-- delas, e as duas não podem divergir porque só existe uma de cada.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A forma de uma quadra no painel
--
-- SECURITY INVOKER de propósito: chamada de dentro de `admin_overview`,
-- que é DEFINER, ela já roda com os privilégios de lá. Sozinha, não dá
-- a ninguém nada que o RLS não desse.
-- ---------------------------------------------------------------------
create or replace function public.admin_court_json(c public.courts)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id',            c.id,
    'slug',          c.slug::text,
    'name',          c.name,
    'court_number',  c.court_number,
    'surface',       c.surface,
    'surface_label', case c.surface
                       when 'clay' then 'Saibro'
                       when 'hard' then 'Rápida'
                       else 'Grama'
                     end,
    'address',       c.address,
    'latitude',      c.latitude,
    'longitude',     c.longitude,
    'slot_minutes',  c.slot_minutes,
    'call_window_seconds', c.call_window_seconds,
    'queue_mode',    c.queue_mode,
    'host_session_open', public.current_host_session(c.id) is not null,
    'is_active',     c.is_active,
    'status',        c.status,
    'has_qr_code',   c.has_qr_code,
    'has_nfc_tag',   c.has_nfc_tag,
    'max_distance_meters',  c.max_distance_meters,
    'gps_tolerance_meters', c.gps_tolerance_meters,
    'enforce_proximity',    c.enforce_proximity,
    'qr_secret_version',    c.qr_secret_version,
    'queue_length',  (
      select count(*) from public.queue_entries q
      where q.court_id = c.id and q.status in ('waiting', 'ready')
    )
  );
$$;

comment on function public.admin_court_json(public.courts) is
  'Forma de uma quadra na tela de administração. Campo novo no painel '
  'entra AQUI, não numa cópia de admin_overview — foi recopiando esta '
  'estrutura em seis migrations que o endereço se perdeu uma vez e o '
  'modo anfitrião quase se perdeu outra.';

-- ---------------------------------------------------------------------
-- A forma de um parque, com as quadras dentro
-- ---------------------------------------------------------------------
create or replace function public.admin_park_json(p public.parks)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id',         p.id,
    'slug',       p.slug::text,
    'name',       p.name,
    'district',   p.district,
    'city',       p.city,
    'address',    p.address,
    'latitude',   p.latitude,
    'longitude',  p.longitude,
    'tone_color', p.tone_color,
    'photo_alt',  p.photo_alt,
    'is_active',  p.is_active,
    'courts', coalesce((
      select jsonb_agg(public.admin_court_json(c) order by c.court_number)
      from public.courts c where c.park_id = p.id
    ), '[]'::jsonb)
  );
$$;

comment on function public.admin_park_json(public.parks) is
  'Forma de um parque na tela de administração, com as quadras dentro.';

-- ---------------------------------------------------------------------
-- E o painel vira o que sempre devia ter sido: uma lista
-- ---------------------------------------------------------------------
create or replace function public.admin_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.require_admin();

  return jsonb_build_object(
    'parks', coalesce(
      (select jsonb_agg(public.admin_park_json(p) order by p.name) from public.parks p),
      '[]'::jsonb
    ),
    'totals', jsonb_build_object(
      'parks',  (select count(*) from public.parks),
      'courts', (select count(*) from public.courts),
      'users',  (select count(*) from public.profiles)
    )
  );
end;
$$;

revoke all on function public.admin_court_json(public.courts) from public;
revoke all on function public.admin_park_json(public.parks)   from public;
grant execute on function public.admin_court_json(public.courts) to authenticated;
grant execute on function public.admin_park_json(public.parks)   to authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20261027120100_endereco_editavel.sql
-- ####################################################################

-- =====================================================================
-- Endereço: apagável, com tamanho, e coordenada que anda em par
--
-- Três correções de revisão no mesmo lugar, porque mexem nas mesmas
-- duas funções:
--
--   . `coalesce(nullif(trim(p_address), ''), address)` nunca limpava
--     nada. Quem digitou o endereço errado apagava o campo, salvava,
--     via "Quadra atualizada" e reabria com o texto velho de volta.
--     Agora nulo e vazio querem dizer coisas diferentes: NULO é "não
--     mexi nisso" e VAZIO é "apague".
--
--   . `address` era `text` sem limite — gravei 100.000 caracteres pelo
--     RPC. `name` já tinha 2..120; o endereço não tinha nada.
--
--   . Passar só a latitude misturava com a longitude do parque, e o
--     resultado era um ponto que não é nem um nem outro. Alfinete é
--     par: ou vêm os dois, ou não vem nenhum.
--
-- NOTA DO MERGE: esta migration roda DEPOIS da do modo anfitrião, então
-- ela parte da versão de lá (17 parâmetros, com `p_queue_mode` e o
-- fechamento da fila quando a quadra sai do modo anfitrião) e enxerta as
-- correções acima. Recriar a versão de 16 parâmetros aqui teria deixado
-- duas assinaturas vivas — e apagado o modo anfitrião do cadastro. Foi
-- exatamente assim que o endereço se perdeu no merge anterior.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Tamanho do endereço
--
-- NOT VALID de propósito: vale para tudo que for gravado daqui em
-- diante sem reprovar linha antiga que por acaso seja maior.
-- ---------------------------------------------------------------------
do $$ begin
  alter table public.courts
    add constraint courts_address_length check (char_length(address) <= 200) not valid;
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.parks
    add constraint parks_address_length check (char_length(address) <= 200) not valid;
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- Um lugar só para decidir o que fazer com o endereço recebido
-- ---------------------------------------------------------------------
create or replace function public.merge_address(p_informado text, p_atual text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_informado is null      then p_atual          -- não veio: mantém
    when trim(p_informado) = ''   then null             -- veio vazio: apaga
    else trim(p_informado)
  end;
$$;

comment on function public.merge_address(text, text) is
  'Nulo mantém o endereço atual; string vazia apaga; texto substitui. '
  'É o que permite corrigir um endereço errado para "nenhum".';

-- ---------------------------------------------------------------------
-- Parque
-- ---------------------------------------------------------------------
create or replace function public.admin_upsert_park(
  p_id        uuid    default null,
  p_name      text    default null,
  p_district  text    default null,
  p_city      text    default null,
  p_address   text    default null,
  p_latitude  double precision default null,
  p_longitude double precision default null,
  p_tone_color text   default null,
  p_photo_alt text    default null,
  p_is_active boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_row public.parks;
begin
  perform public.require_admin();

  if (p_latitude is null) <> (p_longitude is null) then
    raise exception 'Informe latitude e longitude juntas.' using errcode = 'NQ024';
  end if;

  if p_id is null then
    if coalesce(trim(p_name), '') = '' then
      raise exception 'Informe o nome do parque.' using errcode = 'NQ024';
    end if;
    if p_latitude is null or p_longitude is null then
      raise exception 'Marque no mapa onde fica o parque.' using errcode = 'NQ024';
    end if;

    insert into public.parks (
      slug, name, district, city, address, latitude, longitude, tone_color, photo_alt
    )
    values (
      public.unique_slug('parks', p_name),
      trim(p_name), nullif(trim(p_district), ''), nullif(trim(p_city), ''),
      public.merge_address(p_address, null),
      p_latitude, p_longitude, nullif(trim(p_tone_color), ''), nullif(trim(p_photo_alt), '')
    )
    returning * into v_row;
  else
    update public.parks set
      name       = coalesce(nullif(trim(p_name), ''), name),
      district   = coalesce(nullif(trim(p_district), ''), district),
      city       = coalesce(nullif(trim(p_city), ''), city),
      address    = public.merge_address(p_address, address),
      latitude   = coalesce(p_latitude, latitude),
      longitude  = coalesce(p_longitude, longitude),
      tone_color = coalesce(nullif(trim(p_tone_color), ''), tone_color),
      photo_alt  = coalesce(nullif(trim(p_photo_alt), ''), photo_alt),
      is_active  = coalesce(p_is_active, is_active)
    where id = p_id
    returning * into v_row;

    if v_row.id is null then
      raise exception 'Parque não encontrado.' using errcode = 'NQ025';
    end if;
  end if;

  return to_jsonb(v_row);
end;
$$;

-- ---------------------------------------------------------------------
-- Quadra
-- ---------------------------------------------------------------------
create or replace function public.admin_upsert_court(
  p_id           uuid    default null,
  p_park_id      uuid    default null,
  p_court_number smallint default null,
  p_surface      text    default null,
  p_name         text    default null,
  p_address      text    default null,
  p_latitude     double precision default null,
  p_longitude    double precision default null,
  p_slot_minutes smallint default null,
  p_has_qr_code  boolean default null,
  p_has_nfc_tag  boolean default null,
  p_is_active    boolean default null,
  p_max_distance_meters  integer default null,
  p_gps_tolerance_meters integer default null,
  p_enforce_proximity    boolean default null,
  p_call_window_seconds  integer default null,
  p_queue_mode           text    default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row     public.courts;
  v_before  public.courts;
  v_park    public.parks;
  v_number  smallint;
  v_name    text;
  v_session uuid;
begin
  perform public.require_admin();

  -- Alfinete é par: meia coordenada se misturava com a do parque e
  -- produzia um ponto que não é nem um nem outro.
  if (p_latitude is null) <> (p_longitude is null) then
    raise exception 'Informe latitude e longitude juntas.' using errcode = 'NQ024';
  end if;

  if p_queue_mode is not null and p_queue_mode not in ('fixed_qr', 'host') then
    raise exception 'Modo de fila desconhecido: %', p_queue_mode using errcode = 'NQ032';
  end if;

  if p_id is not null then
    select * into v_before from public.courts where id = p_id;
  end if;

  -- O banco recusaria pela constraint; aqui a mensagem diz o porquê.
  if coalesce(p_queue_mode, v_before.queue_mode, 'fixed_qr') = 'host'
     and not coalesce(p_enforce_proximity, v_before.enforce_proximity, true) then
    raise exception 'No modo anfitrião, a conferência de distância não pode ser desligada: '
                    'sem ela, o print do QR funcionaria de casa.'
      using errcode = 'NQ035';
  end if;

  if p_id is null then
    select * into v_park from public.parks where id = p_park_id;
    if v_park.id is null then
      raise exception 'Parque não encontrado.' using errcode = 'NQ025';
    end if;

    v_number := coalesce(
      p_court_number,
      (select coalesce(max(court_number), 0) + 1 from public.courts where park_id = v_park.id)::smallint
    );
    v_name := coalesce(nullif(trim(p_name), ''), 'Quadra ' || lpad(v_number::text, 2, '0'));

    insert into public.courts (
      park_id, court_number, surface, slug, name,
      address, latitude, longitude, city, slot_minutes, has_qr_code, has_nfc_tag,
      max_distance_meters, gps_tolerance_meters, enforce_proximity, call_window_seconds,
      queue_mode
    )
    values (
      v_park.id, v_number,
      coalesce(p_surface, 'clay')::public.court_surface,
      public.unique_slug('courts', v_park.slug::text || '-q' || v_number),
      v_name,
      -- Sem endereço informado, a quadra nasce com o do parque; com o
      -- campo apagado de propósito, nasce sem nenhum.
      public.merge_address(p_address, v_park.address),
      coalesce(p_latitude, v_park.latitude),
      coalesce(p_longitude, v_park.longitude),
      v_park.city,
      coalesce(p_slot_minutes, 40::smallint),
      coalesce(p_has_qr_code, true),
      coalesce(p_has_nfc_tag, false),
      coalesce(p_max_distance_meters, 1000),
      coalesce(p_gps_tolerance_meters, 200),
      coalesce(p_enforce_proximity, true),
      coalesce(p_call_window_seconds, 120),
      coalesce(p_queue_mode, 'fixed_qr')
    )
    returning * into v_row;
  else
    update public.courts set
      court_number = coalesce(p_court_number, court_number),
      surface      = coalesce(p_surface::public.court_surface, surface),
      name         = coalesce(nullif(trim(p_name), ''), name),
      address      = public.merge_address(p_address, address),
      latitude     = coalesce(p_latitude, latitude),
      longitude    = coalesce(p_longitude, longitude),
      slot_minutes = coalesce(p_slot_minutes, slot_minutes),
      has_qr_code  = coalesce(p_has_qr_code, has_qr_code),
      has_nfc_tag  = coalesce(p_has_nfc_tag, has_nfc_tag),
      is_active    = coalesce(p_is_active, is_active),
      max_distance_meters  = coalesce(p_max_distance_meters, max_distance_meters),
      gps_tolerance_meters = coalesce(p_gps_tolerance_meters, gps_tolerance_meters),
      enforce_proximity    = coalesce(p_enforce_proximity, enforce_proximity),
      call_window_seconds  = coalesce(p_call_window_seconds, call_window_seconds),
      queue_mode           = coalesce(p_queue_mode, queue_mode)
    where id = p_id
    returning * into v_row;

    if v_row.id is null then
      raise exception 'Quadra não encontrada.' using errcode = 'NQ025';
    end if;

    -- Saiu do modo anfitrião (a placa chegou): a fila aberta fecha, e as
    -- vagas sem app que esperavam saem com ela — sem anfitrião, ninguém
    -- teria como andar com elas.
    if v_before.queue_mode = 'host' and v_row.queue_mode <> 'host' then
      for v_session in
        select s.id from public.host_sessions s where s.court_id = v_row.id and s.closed_at is null
      loop
        perform public.close_host_session(v_session, 'mode_changed');
      end loop;
    end if;
  end if;

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.merge_address(text, text) from public;
grant execute on function public.merge_address(text, text) to authenticated;

revoke all on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean, integer, text
) from public;

grant execute on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean, integer, text
) to authenticated;

revoke all on function public.admin_upsert_park(
  uuid, text, text, text, text, double precision, double precision, text, text, boolean
) from public;

grant execute on function public.admin_upsert_park(
  uuid, text, text, text, text, double precision, double precision, text, text, boolean
) to authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20261031120000_montar_grupo_sem_pressa.sql
-- ####################################################################

-- =====================================================================
-- Montar o grupo não é corrida contra a tolerância
--
-- Quem abre a fila de uma quadra no modo anfitrião recebia, no mesmo
-- instante, o prazo de check-in da quadra (padrão: 120 s). Só que a
-- pessoa que abriu a fila acabou de chegar e ainda vai fazer o que o
-- app pede que ela faça: cadastrar quem já estava jogando, cadastrar
-- quem já esperava sem app, passar o PIN para os amigos que vieram
-- junto e só então tocar em "Entrando na quadra".
--
-- Passados os 120 s, o cron expirava a vaga dela. O resultado, medido:
--
--     status da vaga de quem abriu: expired
--     check-in: RECUSADO -> "Você não está na fila desta quadra"
--     fila aberta nesta quadra: ainda aberta
--
-- Ou seja: expulsa da fila que ela mesma abriu, sem poder entrar e sem
-- poder reabrir, com a quadra travada até a sessão ser considerada
-- esquecida.
--
-- A correção parte do que a tolerância é para quê. Ela existe para
-- destravar a fila quando quem foi chamado não aparece. Se não há
-- ninguém atrás, não há fila travada — e não há por que haver relógio.
--
--   . primeiro grupo da fila, com a quadra livre e NINGUÉM atrás:
--     fica pronto para entrar, sem prazo. Monta o grupo com calma.
--   . no instante em que um segundo grupo entra, o prazo passa a
--     valer, contado dali. Quem está na frente tem a tolerância da
--     quadra para fazer o check-in, como sempre teve.
--
-- O tempo de jogo continua começando no check-in, não na abertura:
-- isso já era assim e os testes seguem provando.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Chamar o próximo — agora com o prazo condicionado a haver fila
-- ---------------------------------------------------------------------
create or replace function public.call_next_team(p_court_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court    public.courts%rowtype;
  v_next     public.queue_entries%rowtype;
  v_behind   boolean;
  v_deadline timestamptz;
  v_host     uuid;
begin
  select * into v_court from public.courts c where c.id = p_court_id;
  if not found then
    return null;
  end if;

  -- Só chama se a quadra estiver livre.
  if exists (select 1 from public.matches mt
             where mt.court_id = p_court_id and mt.ended_at is null) then
    return null;
  end if;

  select e.* into v_next
  from public.queue_positions qp
  join public.queue_entries e on e.id = qp.entry_id
  where qp.court_id = p_court_id
  order by qp.position
  limit 1;

  if v_next.id is null then
    return null;
  end if;

  -- Tem alguém esperando atrás? É isso que faz o relógio existir.
  v_behind := exists (
    select 1 from public.queue_positions qp
    where qp.court_id = p_court_id and qp.entry_id <> v_next.id
  );

  v_deadline := case
                  -- Vaga sem app nunca teve prazo: quem marca é o anfitrião.
                  when v_next.is_offline then null
                  -- Sozinho na fila: monta o grupo sem relógio correndo.
                  when not v_behind     then null
                  else now() + make_interval(secs => v_court.call_window_seconds)
                end;

  if v_next.status = 'waiting' then
    update public.queue_entries
       set status          = 'ready',
           called_at       = coalesce(called_at, now()),
           call_expires_at = v_deadline
     where id = v_next.id and status = 'waiting';

    if found and v_next.is_offline then
      v_host := public.effective_host(p_court_id);
      if v_host is not null then
        perform public.enqueue_user_notification(
          v_host, p_court_id, 'host_offline_called',
          'Vez do grupo sem app',
          format('%s pode entrar na %s. Marque no app quando entrarem.',
                 coalesce(v_next.offline_label, 'O grupo sem app'),
                 public.court_label(v_court.court_number)),
          jsonb_build_object('court_id', p_court_id, 'entry_id', v_next.id)
        );
      end if;
    end if;

  elsif v_next.status = 'ready'
        and v_next.call_expires_at is null
        and v_deadline is not null then
    -- Estava montando o grupo sozinho e agora chegou gente atrás: o
    -- relógio começa AQUI, com a tolerância inteira.
    --
    -- Sem notificação nova aqui de propósito: a tela de quem está na
    -- frente já mostra a tolerância assim que ela passa a existir, e
    -- um tipo de aviso novo exigiria mexer no enum por um caso que a
    -- própria tela cobre.
    update public.queue_entries
       set call_expires_at = v_deadline
     where id = v_next.id and status = 'ready' and call_expires_at is null;
  end if;

  return v_next.id;
end;
$$;

revoke all on function public.call_next_team(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- A fila esquecida, agora que o primeiro grupo pode ficar sem prazo
--
-- Antes, qualquer grupo com app na fila impedia a sessão de ser
-- considerada esquecida — e tudo bem, porque um grupo parado acabava
-- expirando pelo prazo. Sem prazo, quem abre a fila e vai embora sem
-- fazer check-in seguraria a quadra para sempre.
--
-- Então a presença passa a ter validade: só conta quem se mexeu nos
-- últimos 30 minutos. É o mesmo relógio que a regra já usava para
-- decidir se a sessão foi abandonada, aplicado também a quem está nela.
-- ---------------------------------------------------------------------
create or replace function public.host_session_is_idle(p_session_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not exists (
           select 1
           from public.queue_entries e
           where e.court_id = s.court_id
             and not e.is_offline
             and e.status in ('waiting', 'ready', 'playing')
             and greatest(e.joined_at,
                          coalesce(e.called_at, e.joined_at),
                          coalesce(e.started_at, e.joined_at)) > now() - interval '30 minutes'
         )
     and not exists (
           select 1 from public.matches mt
           where mt.court_id = s.court_id and mt.ended_at is null and mt.expires_at > now()
         )
     and greatest(
           s.opened_at,
           (select max(greatest(e.joined_at, e.started_at, e.ended_at, e.left_at))
              from public.queue_entries e
             where e.host_session_id = s.id and not e.is_offline)
         ) < now() - interval '30 minutes'
  from public.host_sessions s
  where s.id = p_session_id;
$$;

-- `court_has_app_players` existia só para a regra acima, que agora
-- precisa da validade de 30 minutos embutida. Sem outro chamador, ela
-- sai de cena em vez de ficar como armadilha para quem vier depois.
drop function if exists public.court_has_app_players(uuid);


-- ####################################################################
-- Origem: supabase/migrations/20261102120000_rotacao_automatica.sql
-- ####################################################################

-- =====================================================================
-- NEQST — a quadra anda sozinha
--
-- Até aqui, o fim do turno liberava a quadra e o próximo grupo tinha de
-- fazer check-in para o relógio dele começar. Quem jogou saía da fila.
-- Na quadra pública real isso não acontece: ninguém está com o celular
-- na mão no minuto da troca, e quem acabou de jogar quer voltar para o
-- fim da fila e jogar de novo.
--
-- A regra passa a ser esta:
--
--     terminou o tempo          troca de 1 min            começa
--     do grupo em quadra  ──▶   sai quem jogou,     ──▶   o turno do
--                               entra o próximo           próximo
--                                     │
--                     quem jogou vai para o FIM da fila
--
-- Ninguém precisa tocar em nada para isso andar: o grupo entra na fila
-- quando chega e sai da fila quando vai embora. O resto é o cron de
-- minuto em minuto (advance_expired_queues).
--
-- Duas decisões que valem estar escritas:
--
--   . A rotação só existe quando há fila atrás. Sozinho na quadra, o
--     fim do turno encerra o turno como sempre encerrou — a quadra fica
--     livre em vez de ficar rodando um carrossel de um grupo só, e um
--     grupo que foi embora sem sair da fila para de segurar a quadra.
--
--   . O check-in continua existindo para o PRIMEIRO turno de uma fila
--     (quem abre a fila cadastra quem já jogava, monta o grupo e aí
--     marca "Entrando na quadra" — Sprint 5). Depois do primeiro turno,
--     nenhum turno precisa de check-in.
--
-- O que NÃO dá para resolver aqui, e está em docs/sprint6.md: um grupo
-- que vai embora sem sair da fila continua na roda. Com fila atrás, ele
-- volta a ocupar a quadra a cada rodada e ninguém de fora tem como
-- saber que não há ninguém lá. Hoje a saída é humana: qualquer pessoa
-- do grupo toca em "Sair da fila", e a operação do parque remove o
-- grupo. Detectar isso sozinho exigiria pedir uma confirmação a cada
-- turno — exatamente o que esta mudança tira do caminho.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. A troca de quadra
--
-- Fica na quadra, e não numa constante, pelo mesmo motivo do slot e da
-- tolerância: quadra de saibro com rede para ajeitar não troca no mesmo
-- tempo que uma quadra rápida. O padrão é 1 minuto.
-- ---------------------------------------------------------------------
alter table public.courts
  add column if not exists changeover_seconds smallint not null default 60,
  add column if not exists changeover_until   timestamptz;

do $$ begin
  alter table public.courts
    add constraint courts_changeover_seconds_range
    check (changeover_seconds between 15 and 600);
exception when duplicate_object then null; end $$;

comment on column public.courts.changeover_seconds is
  'Quanto dura a troca entre um turno e o próximo (padrão 60s).';
comment on column public.courts.changeover_until is
  'Enquanto estiver no futuro, a quadra está trocando de grupo: ninguém entra. '
  'Chegando a hora, o cron começa o turno do próximo sozinho.';

create index if not exists courts_changeover_idx
  on public.courts (changeover_until) where changeover_until is not null;

-- ---------------------------------------------------------------------
-- 2. Uma vaga que volta para o fim da fila
--
-- queue_number é `generated always as identity`: não dá para empurrar
-- uma vaga para o fim mudando o número dela. E nem seria certo — cada
-- turno é um turno, com o seu próprio histórico. Então a vaga que sai
-- de quadra gera uma vaga nova no fim, carregando o grupo.
--
-- first_joined_at preserva a hora em que o grupo chegou de verdade:
-- joined_at da vaga nova é agora, e a tela mostraria "chegou agora"
-- para quem está no parque há uma hora.
-- ---------------------------------------------------------------------
alter table public.queue_entries
  add column if not exists first_joined_at timestamptz,
  add column if not exists requeued_from   uuid references public.queue_entries (id) on delete set null,
  add column if not exists turn_number     integer not null default 1;

update public.queue_entries set first_joined_at = joined_at where first_joined_at is null;

alter table public.queue_entries alter column first_joined_at set default clock_timestamp();
alter table public.queue_entries alter column first_joined_at set not null;

do $$ begin
  alter table public.queue_entries
    add constraint queue_entries_turn_number_check check (turn_number >= 1);
exception when duplicate_object then null; end $$;

comment on column public.queue_entries.first_joined_at is
  'Quando o grupo entrou na fila pela primeira vez. Sobrevive às rotações.';
comment on column public.queue_entries.requeued_from is
  'A vaga do turno anterior deste mesmo grupo.';
comment on column public.queue_entries.turn_number is
  'Quantos turnos este grupo já tem nesta sequência. 1 = ainda não jogou.';

create index if not exists queue_entries_requeued_idx
  on public.queue_entries (requeued_from) where requeued_from is not null;

-- ---------------------------------------------------------------------
-- 3. Recolocar o grupo no fim da fila
--
-- Só é chamada com a vaga antiga já encerrada: é o encerramento que
-- solta os membros (trigger queue_entries_sync_members), e sem isso o
-- índice "um time ativo por jogador por quadra" recusaria a vaga nova.
-- ---------------------------------------------------------------------
create or replace function public.requeue_entry(p_entry_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old public.queue_entries%rowtype;
  v_new uuid;
begin
  select * into v_old from public.queue_entries e where e.id = p_entry_id;
  if not found then
    return null;
  end if;

  insert into public.queue_entries
    (court_id, mode, status, created_by, scan_token_id,
     is_offline, offline_label, offline_kind, host_session_id,
     first_joined_at, requeued_from, turn_number)
  values
    (v_old.court_id, v_old.mode, 'waiting', v_old.created_by, null,
     v_old.is_offline, v_old.offline_label, v_old.offline_kind, v_old.host_session_id,
     v_old.first_joined_at, v_old.id, v_old.turn_number + 1)
  returning id into v_new;

  -- Quem saiu no meio do turno não volta junto: left_at marca isso.
  -- origin vai copiado para o gatilho de origem não tentar adivinhar de
  -- novo a partir de um scan que já foi gasto.
  insert into public.queue_entry_members
    (entry_id, court_id, user_id, role, origin, invite_id, joined_via, checked_in_at)
  select v_new, m.court_id, m.user_id, m.role,
         coalesce(m.origin, 'requeued'), m.invite_id, m.joined_via, m.checked_in_at
  from public.queue_entry_members m
  where m.entry_id = p_entry_id and m.left_at is null;

  -- O PIN acompanha: quem recebeu os 4 dígitos do grupo há meia hora
  -- continua entrando. Só troca se outro grupo da quadra já estiver com
  -- esse número — dois grupos com o mesmo PIN mandariam a pessoa para o
  -- grupo errado.
  insert into public.queue_entry_pins (entry_id, pin)
  select v_new,
         case
           when exists (
             select 1
             from public.queue_entry_pins p2
             join public.queue_entries e2 on e2.id = p2.entry_id
             where e2.court_id = v_old.court_id
               and e2.status in ('waiting', 'ready', 'playing')
               and e2.id <> v_new
               and p2.pin = p.pin
           ) then public.new_group_pin(v_old.court_id)
           else p.pin
         end
  from public.queue_entry_pins p
  where p.entry_id = p_entry_id;

  return v_new;
end;
$$;

revoke all on function public.requeue_entry(uuid) from public, anon, authenticated;

comment on function public.requeue_entry(uuid) is
  'Devolve o grupo da vaga informada para o fim da fila, numa vaga nova. '
  'Mantém membros, PIN e a hora de chegada original.';

-- ---------------------------------------------------------------------
-- 4. Encerrar o turno — agora abrindo a troca e rodando a fila
-- ---------------------------------------------------------------------
create or replace function public.close_match(
  p_match_id uuid,
  p_winner   public.match_side,
  p_reason   public.match_end_reason,
  p_reporter uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_match   public.matches%rowtype;
  v_court   public.courts%rowtype;
  v_waiting boolean;
begin
  select * into v_match from public.matches mt where mt.id = p_match_id for update;
  if not found then
    raise exception 'Partida não encontrada' using errcode = 'NQ018';
  end if;
  if v_match.ended_at is not null then
    return public.match_state(p_match_id);
  end if;

  select * into v_court from public.courts c where c.id = v_match.court_id for update;

  update public.matches
     set ended_at    = now(),
         winner_side = null,
         end_reason  = p_reason,
         reported_by = p_reporter
   where id = p_match_id;

  -- O lado B só existe em turnos gravados antes da Sprint 4.
  update public.queue_entries
     set status = 'done', ended_at = now()
   where id in (v_match.side_a_entry_id, v_match.side_b_entry_id)
     and status = 'playing';

  update public.queue_join_requests
     set status = 'expired', decided_at = now()
   where status = 'pending'
     and entry_id in (v_match.side_a_entry_id, v_match.side_b_entry_id);

  -- Tem gente esperando? É isso que decide entre rodar e liberar.
  select exists (
    select 1 from public.queue_positions qp where qp.court_id = v_match.court_id
  ) into v_waiting;

  if v_waiting and p_reason = 'slot_expired' then
    -- Acabou o tempo com fila atrás: quem jogou vai para o fim e a
    -- quadra entra na troca. O turno do próximo começa sozinho quando
    -- ela terminar (advance_court).
    perform public.requeue_entry(v_match.side_a_entry_id);

    update public.courts
       set changeover_until = now() + make_interval(secs => v_court.changeover_seconds),
           holder_entry_id  = null,
           status = case
                      when status = 'unavailable' then 'unavailable'::public.court_status
                      else 'available'::public.court_status
                    end
     where id = v_match.court_id;

  else
    -- Devolveu a quadra antes da hora, abandonou, ou não havia ninguém
    -- atrás: a quadra libera, como sempre liberou.
    --
    -- Devolver a quadra no meio do turno não entra na rotação de
    -- propósito. Quem devolve escolheu parar, então não volta para o
    -- fim da fila; e o próximo não estava olhando o relógio, então
    -- continua sendo chamado com a tolerância e entrando pelo
    -- check-in — começar o turno dele sozinho seria queimar o slot de
    -- quem pode nem estar na quadra ainda. Sozinho na fila também não
    -- há o que rodar.
    update public.courts
       set changeover_until = null,
           holder_entry_id  = null,
           status = case
                      when status = 'unavailable' then 'unavailable'::public.court_status
                      else 'available'::public.court_status
                    end
     where id = v_match.court_id;
  end if;

  -- Com a quadra livre, o próximo grupo é chamado na hora. Durante a
  -- troca ele é chamado sem prazo: não há nada que ele precise fazer.
  perform public.call_next_team(v_match.court_id);

  return public.match_state(p_match_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 5. Chamar o próximo — sem relógio durante a troca
--
-- A tolerância existe para destravar a fila quando quem foi chamado não
-- aparece (Sprint 5) e para o primeiro turno de uma fila, que ainda
-- depende do check-in. Na troca entre turnos ela não tem função: o
-- turno do próximo começa sozinho.
-- ---------------------------------------------------------------------
create or replace function public.call_next_team(p_court_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court    public.courts%rowtype;
  v_next     public.queue_entries%rowtype;
  v_behind   boolean;
  v_trading  boolean;
  v_deadline timestamptz;
  v_host     uuid;
begin
  select * into v_court from public.courts c where c.id = p_court_id;
  if not found then
    return null;
  end if;

  -- Só chama se a quadra estiver livre.
  if exists (select 1 from public.matches mt
             where mt.court_id = p_court_id and mt.ended_at is null) then
    return null;
  end if;

  select e.* into v_next
  from public.queue_positions qp
  join public.queue_entries e on e.id = qp.entry_id
  where qp.court_id = p_court_id
  order by qp.position
  limit 1;

  if v_next.id is null then
    return null;
  end if;

  -- Tem alguém esperando atrás? É isso que faz o relógio existir.
  v_behind := exists (
    select 1 from public.queue_positions qp
    where qp.court_id = p_court_id and qp.entry_id <> v_next.id
  );

  v_trading := v_court.changeover_until is not null and v_court.changeover_until > now();

  v_deadline := case
                  -- Vaga sem app nunca teve prazo: quem marca é o anfitrião.
                  when v_next.is_offline then null
                  -- Troca de quadra: o turno começa sozinho no fim dela.
                  when v_trading        then null
                  -- Sozinho na fila: monta o grupo sem relógio correndo.
                  when not v_behind     then null
                  else now() + make_interval(secs => v_court.call_window_seconds)
                end;

  if v_next.status = 'waiting' then
    update public.queue_entries
       set status          = 'ready',
           called_at       = coalesce(called_at, now()),
           call_expires_at = v_deadline
     where id = v_next.id and status = 'waiting';

    if found and v_next.is_offline then
      v_host := public.effective_host(p_court_id);
      if v_host is not null then
        perform public.enqueue_user_notification(
          v_host, p_court_id, 'host_offline_called',
          'Vez do grupo sem app',
          format('%s pode entrar na %s. Marque no app quando entrarem.',
                 coalesce(v_next.offline_label, 'O grupo sem app'),
                 public.court_label(v_court.court_number)),
          jsonb_build_object('court_id', p_court_id, 'entry_id', v_next.id)
        );
      end if;
    end if;

  elsif v_next.status = 'ready'
        and v_next.call_expires_at is null
        and v_deadline is not null then
    -- Estava montando o grupo sozinho e agora chegou gente atrás: o
    -- relógio começa AQUI, com a tolerância inteira.
    update public.queue_entries
       set call_expires_at = v_deadline
     where id = v_next.id and status = 'ready' and call_expires_at is null;
  end if;

  return v_next.id;
end;
$$;

revoke all on function public.call_next_team(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. Abrir o turno — reordenada por causa da rotação
--
-- Encerrar o turno vencido pode mudar a fila embaixo de quem chamou
-- (o grupo que saiu vai para o fim), então a conferência de "é a sua
-- vez" passa a ser feita DEPOIS desse encerramento, e não antes.
-- ---------------------------------------------------------------------
create or replace function public.open_match(p_entry_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry    public.queue_entries%rowtype;
  v_court    public.courts%rowtype;
  v_first    uuid;
  v_live     public.matches%rowtype;
  v_match_id uuid;
begin
  select * into v_entry from public.queue_entries e where e.id = p_entry_id for update;
  if not found then
    raise exception 'Grupo não encontrado' using errcode = 'NQ007';
  end if;
  if v_entry.status not in ('waiting', 'ready') then
    raise exception 'Este grupo não pode iniciar o turno agora' using errcode = 'NQ009';
  end if;

  select * into v_court from public.courts c where c.id = v_entry.court_id;
  if not v_court.is_active or v_court.status = 'unavailable' then
    raise exception 'Esta quadra está indisponível no momento' using errcode = 'NQ003';
  end if;

  -- 1. O turno anterior já venceu? Encerra agora — é isso que roda a
  --    fila e abre a troca.
  select * into v_live
  from public.matches mt
  where mt.court_id = v_court.id and mt.ended_at is null
  for update;

  if found then
    if v_live.expires_at > now() then
      raise exception 'A quadra está ocupada por mais % minuto(s)',
        greatest(1, ceil(extract(epoch from (v_live.expires_at - now())) / 60)::integer)
        using errcode = 'NQ017';
    end if;
    perform public.close_match(v_live.id, null, 'slot_expired');
  end if;

  -- 2. A troca não bloqueia quem diz que já está em quadra.
  --
  --    O minuto da troca é uma garantia, não uma cancela: ele existe
  --    para o turno do próximo começar SOZINHO se ninguém fizer nada.
  --    Quem está na quadra e toca em "entramos" — ou o anfitrião, que
  --    está vendo a quadra — sabe mais que o cronômetro, e começar o
  --    turno ali só antecipa o que ia acontecer de qualquer forma.
  --    Começar o turno limpa a troca (no fim desta função).
  select * into v_court from public.courts c where c.id = v_entry.court_id;

  -- 3. Só agora dá para saber de quem é a vez: o encerramento acima
  --    pode ter mandado o grupo que jogava para o fim da fila.
  select qp.entry_id into v_first
  from public.queue_positions qp
  where qp.court_id = v_court.id
  order by qp.position
  limit 1;

  if v_first is distinct from v_entry.id then
    raise exception 'Ainda não é a vez do seu grupo' using errcode = 'NQ015';
  end if;

  insert into public.matches
    (court_id, side_a_entry_id, side_b_entry_id, mode, slot_minutes, expires_at)
  values
    (v_court.id, v_entry.id, null, v_entry.mode, v_court.slot_minutes,
     now() + make_interval(mins => v_court.slot_minutes))
  returning id into v_match_id;

  update public.queue_entries
     set status = 'playing', called_at = coalesce(called_at, now()), started_at = now()
   where id = v_entry.id;

  update public.courts
     set status = 'in_game', holder_entry_id = null, changeover_until = null
   where id = v_court.id;

  return public.match_state(v_match_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Andar a quadra: encerra o vencido, começa o do próximo
-- ---------------------------------------------------------------------
create or replace function public.advance_court(p_court_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court   public.courts%rowtype;
  v_match   record;
  v_entry   record;
  v_next    uuid;
  v_closed  integer := 0;
  v_expired integer := 0;
  v_started integer := 0;
begin
  for v_match in
    select id from public.matches
    where court_id = p_court_id and ended_at is null and expires_at <= now()
  loop
    perform public.close_match(v_match.id, null, 'slot_expired');
    v_closed := v_closed + 1;
  end loop;

  -- Acabou a troca: o próximo entra sozinho. É o único lugar do app em
  -- que um turno começa sem ninguém tocar em nada.
  select * into v_court from public.courts c where c.id = p_court_id for update;

  if found
     and v_court.changeover_until is not null
     and v_court.changeover_until <= now() then

    update public.courts set changeover_until = null where id = p_court_id;

    if v_court.is_active
       and v_court.status <> 'unavailable'
       and not exists (select 1 from public.matches mt
                       where mt.court_id = p_court_id and mt.ended_at is null) then

      select qp.entry_id into v_next
      from public.queue_positions qp
      where qp.court_id = p_court_id
      order by qp.position
      limit 1;

      if v_next is not null then
        perform public.open_match(v_next);
        v_started := v_started + 1;
      end if;
    end if;
  end if;

  -- Chamada não atendida: só sobrou para o primeiro turno de uma fila,
  -- o único que ainda depende do check-in de quem abriu.
  for v_entry in
    select e.id
    from public.queue_entries e
    where e.court_id = p_court_id
      and e.status = 'ready'
      and e.call_expires_at is not null
      and e.call_expires_at <= now()
    order by e.queue_number
  loop
    update public.queue_entries
       set status = 'expired', cancel_reason = 'no_show', left_at = now()
     where id = v_entry.id and status = 'ready';

    update public.queue_join_requests
       set status = 'expired', decided_at = now()
     where status = 'pending' and entry_id = v_entry.id;

    perform public.call_next_team(p_court_id);
    v_expired := v_expired + 1;
  end loop;

  return jsonb_build_object('matches_closed', v_closed,
                            'entries_expired', v_expired,
                            'turns_started', v_started);
end;
$$;

revoke all on function public.advance_court(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 8. O cron de minuto em minuto também acorda para a troca
-- ---------------------------------------------------------------------
create or replace function public.advance_expired_queues()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court    record;
  v_result   jsonb;
  v_closed   integer := 0;
  v_expired  integer := 0;
  v_started  integer := 0;
  v_requests integer;
  v_sessions integer;
begin
  for v_court in
    select distinct court_id from (
      select court_id from public.matches
      where ended_at is null and expires_at <= now()
      union all
      select court_id from public.queue_entries
      where status = 'ready' and call_expires_at is not null and call_expires_at <= now()
      union all
      select id as court_id from public.courts
      where changeover_until is not null and changeover_until <= now()
    ) s
  loop
    v_result  := public.advance_court(v_court.court_id);
    v_closed  := v_closed  + (v_result ->> 'matches_closed')::integer;
    v_expired := v_expired + (v_result ->> 'entries_expired')::integer;
    v_started := v_started + (v_result ->> 'turns_started')::integer;
  end loop;

  -- Pedido que ninguém respondeu, ou de um grupo que já saiu da fila.
  update public.queue_join_requests r
     set status = 'expired', decided_at = now()
   where r.status = 'pending'
     and (r.expires_at <= now()
          or not exists (select 1 from public.queue_entries e
                         where e.id = r.entry_id
                           and e.status in ('waiting', 'ready', 'playing')));
  get diagnostics v_requests = row_count;

  v_sessions := public.close_idle_host_sessions();

  return jsonb_build_object(
    'matches_closed',   v_closed,
    'entries_expired',  v_expired,
    'turns_started',    v_started,
    'requests_expired', v_requests,
    'sessions_closed',  v_sessions,
    'ran_at', now()
  );
end;
$$;

revoke all on function public.advance_expired_queues() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 9. O check-in não pode atropelar a rotação
--
-- Entre o momento em que a função leu a vaga e o momento em que ela
-- chama open_match, o advance_court do meio pode ter começado o turno
-- deste mesmo grupo sozinho. Sem reler, open_match recusaria com "este
-- grupo não pode iniciar o turno agora" — um erro na cara de quem fez
-- tudo certo.
-- ---------------------------------------------------------------------
create or replace function public.check_in_and_start(p_scan_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user  uuid := auth.uid();
  v_token public.scan_tokens%rowtype;
  v_entry public.queue_entries%rowtype;
  v_match uuid;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  v_token := public.take_scan_token(p_scan_token,
    'Confirme na quadra que você chegou', true);

  select e.* into v_entry
  from public.queue_entry_members m
  join public.queue_entries e on e.id = m.entry_id
  where m.user_id = v_user and m.is_active and e.court_id = v_token.court_id;

  if not found then
    raise exception 'Você não está na fila desta quadra' using errcode = 'NQ007';
  end if;

  if v_entry.status <> 'playing' then
    if v_entry.status = 'ready'
       and v_entry.call_expires_at is not null
       and v_entry.call_expires_at <= now() then
      raise exception 'O tempo para o check-in terminou' using errcode = 'NQ016';
    end if;

    -- O turno anterior pode ter vencido sem o cron ter passado ainda.
    perform public.advance_court(v_entry.court_id);

    -- A rotação pode ter começado o turno deste grupo nesse meio tempo.
    select e.* into v_entry from public.queue_entries e where e.id = v_entry.id;

    if v_entry.status <> 'playing' then
      perform public.open_match(v_entry.id);
    end if;
  end if;

  update public.queue_entry_members
     set checked_in_at = coalesce(checked_in_at, now())
   where entry_id = v_entry.id and user_id = v_user and is_active;

  update public.scan_tokens
     set consumed_at = now(), consumed_by_entry = v_entry.id
   where id = v_token.id;

  select mt.id into v_match
  from public.matches mt
  where mt.ended_at is null and v_entry.id in (mt.side_a_entry_id, mt.side_b_entry_id);

  return case when v_match is null then public.queue_entry_state(v_entry.id)
              else public.match_state(v_match) end;
end;
$$;

-- ---------------------------------------------------------------------
-- 10. A fila esquecida não pode ser mascarada pela rotação
--
-- A regra da Sprint 5 usa joined_at como sinal de presença. Com a
-- rotação, a vaga nova nasce com joined_at = agora a cada turno, e uma
-- fila de fantasmas pareceria viva para sempre. first_joined_at é a
-- chegada de verdade.
-- ---------------------------------------------------------------------
create or replace function public.host_session_is_idle(p_session_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not exists (
           select 1
           from public.queue_entries e
           where e.court_id = s.court_id
             and not e.is_offline
             and e.status in ('waiting', 'ready', 'playing')
             and greatest(e.first_joined_at,
                          coalesce(e.called_at, e.first_joined_at),
                          coalesce(e.started_at, e.first_joined_at)) > now() - interval '30 minutes'
         )
     and not exists (
           select 1 from public.matches mt
           where mt.court_id = s.court_id and mt.ended_at is null and mt.expires_at > now()
         )
     and greatest(
           s.opened_at,
           (select max(greatest(e.first_joined_at, e.started_at, e.ended_at, e.left_at))
              from public.queue_entries e
             where e.host_session_id = s.id and not e.is_offline)
         ) < now() - interval '30 minutes'
  from public.host_sessions s
  where s.id = p_session_id;
$$;

-- ---------------------------------------------------------------------
-- 11. A fila na tela: a troca aparece, e a espera soma a troca
--
-- Uma rodada da quadra passa a custar slot + troca. Sem isso, a
-- estimativa de espera erra 1 minuto por grupo à frente — e numa fila
-- de seis grupos isso é meia volta de relógio.
-- ---------------------------------------------------------------------
create or replace function public.court_queue_items(p_court_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with court as (
    select c.id, c.slot_minutes, c.changeover_seconds, c.changeover_until,
           (select count(*) from public.matches mt
             where mt.court_id = c.id and mt.ended_at is null) as live,
           (select greatest(0, floor(extract(epoch from (mt.expires_at - now())))::integer)
              from public.matches mt
             where mt.court_id = c.id and mt.ended_at is null
             limit 1) as remaining
    from public.courts c where c.id = p_court_id
  ),
  gap as (
    -- Quanto falta para a quadra estar livre para o primeiro da fila.
    select case
             when live > 0 then coalesce(remaining, 0) + changeover_seconds
             when changeover_until is not null and changeover_until > now()
               then greatest(0, ceil(extract(epoch from (changeover_until - now())))::integer)
             else 0
           end as to_head,
           slot_minutes * 60 + changeover_seconds as per_turn
    from court
  ),
  q as (
    select qp.entry_id, qp.position, qp.status, e.first_joined_at as joined_at,
           e.call_expires_at, e.is_offline, e.offline_label, e.turn_number,
           coalesce(
             (select jsonb_build_object(
                       'frame', pr.racket_frame_color,
                       'grip',  pr.racket_grip_color)
                from public.queue_entry_members mm
                join public.profiles pr on pr.id = mm.user_id
               where mm.entry_id = qp.entry_id and mm.is_active and mm.role = 'owner'
               limit 1),
             case when e.is_offline
                  then jsonb_build_object('frame', '#9AA39C', 'grip', '#F1ECEF') end
           ) as racket,
           public.match_side_players(qp.entry_id) as players
    from public.queue_positions qp
    join public.queue_entries e on e.id = qp.entry_id
    where qp.court_id = p_court_id
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'entry_id',    q.entry_id,
        'position',    q.position,
        'position_label', q.position || 'º',
        'group_size',  jsonb_array_length(q.players),
        'group_label', case when q.is_offline then 'Sem app'
                            else public.group_label(jsonb_array_length(q.players)) end,
        'mode_label',  case when q.is_offline then 'Sem app'
                            else public.group_label(jsonb_array_length(q.players)) end,
        'status',      q.status,
        'is_called',   q.status = 'ready',
        'call_expires_at', q.call_expires_at,
        'joined_at',   q.joined_at,
        'turn_number', q.turn_number,
        'teams_ahead', (q.position - 1) + coalesce((select live from court), 0),
        'is_mine',     exists (
                         select 1 from public.queue_entry_members mm
                         where mm.entry_id = q.entry_id and mm.user_id = auth.uid() and mm.is_active
                       ),
        'is_offline',  q.is_offline,
        'offline_label', q.offline_label,
        'racket',      q.racket,
        'players',     q.players,
        'team_label',  case
          when q.is_offline then coalesce(q.offline_label, 'Grupo sem app')
          else (
            select string_agg(pl ->> 'short_name', ' + ' order by ord)
                     || case when jsonb_array_length(q.players) > 2
                             then ' + ' || (jsonb_array_length(q.players) - 2)
                             else '' end
            from jsonb_array_elements(q.players) with ordinality as t(pl, ord)
            where ord <= 2
          )
        end,
        'stack', (
          select coalesce(jsonb_agg(s.racket order by s.position), '[]'::jsonb)
          from (
            select q2.racket, q2.position
            from q q2
            where q2.position <= q.position and q2.racket is not null
            order by q2.position desc
            limit 5
          ) s
        ),
        'stack_more', greatest(q.position - 5, 0),
        'eta_seconds', (select to_head from gap)
                       + (q.position - 1) * (select per_turn from gap)
      )
      order by q.position
    ),
    '[]'::jsonb
  )
  from q;
$$;

grant execute on function public.court_queue_items(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 12. A tela da quadra: o minuto da troca e quem entra nele
--
-- Durante a troca a quadra não tem partida, mas também não está livre.
-- Sem um estado próprio, a tela diria "Livre" no exato minuto em que
-- um grupo está entrando — e o próximo acharia que precisa correr para
-- fazer check-in.
-- ---------------------------------------------------------------------
create or replace function public.court_screen(p_court_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_court   public.courts%rowtype;
  v_park    public.parks%rowtype;
  v_match   uuid;
  v_items   jsonb;
  v_queue   integer;
  v_rem     integer := 0;
  v_mine    jsonb;
  v_state   jsonb;
  v_group   jsonb;
  v_req     jsonb;
  v_live    jsonb;
  v_session public.host_sessions%rowtype;
  v_host_id uuid;
  v_host    jsonb;
  v_trading boolean;
  v_left    integer := 0;
  v_next    jsonb;
  v_change  jsonb;
  v_to_head integer;
  v_per_turn integer;
begin
  select * into v_court from public.courts c where c.id = p_court_id;
  if not found then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;

  select * into v_park from public.parks pk where pk.id = v_court.park_id;

  select mt.id,
         greatest(0, floor(extract(epoch from (mt.expires_at - now())))::integer)
  into v_match, v_rem
  from public.matches mt
  where mt.court_id = p_court_id and mt.ended_at is null
  limit 1;

  v_live  := case when v_match is null then null else public.match_state(v_match) end;
  v_items := public.court_queue_items(p_court_id);
  v_queue := jsonb_array_length(v_items);

  v_trading := v_match is null
               and v_court.changeover_until is not null
               and v_court.changeover_until > now();

  if v_trading then
    v_left := greatest(0, ceil(extract(epoch from (v_court.changeover_until - now())))::integer);
    -- Quem entra na quadra agora é o primeiro da fila.
    select i into v_next from jsonb_array_elements(v_items) i
    where (i ->> 'position')::integer = 1
    limit 1;

    v_change := jsonb_build_object(
      'until',        v_court.changeover_until,
      'seconds_left', v_left,
      'next_entry_id', v_next ->> 'entry_id',
      'next_label',   v_next ->> 'team_label',
      'next_is_mine', coalesce((v_next ->> 'is_mine')::boolean, false),
      'text',         'Troca de grupo — o próximo entra em quadra'
    );
  end if;

  -- O que uma rodada da quadra custa, para as estimativas.
  v_per_turn := v_court.slot_minutes * 60 + v_court.changeover_seconds;
  v_to_head  := case
                  when v_match is not null then coalesce(v_rem, 0) + v_court.changeover_seconds
                  when v_trading           then v_left
                  else 0
                end;

  select i into v_mine
  from jsonb_array_elements(v_items) i
  where (i ->> 'is_mine')::boolean
  limit 1;

  v_state := public.player_state(auth.uid());

  if (v_state ->> 'court_id')::uuid = p_court_id then
    v_group := public.my_group((v_state ->> 'entry_id')::uuid);
  end if;

  v_req := public.my_join_request();
  if (v_req ->> 'court_id')::uuid is distinct from p_court_id then
    v_req := null;
  end if;

  -- A fila com anfitrião: quem organiza e o que quem olha pode fazer.
  if v_court.queue_mode = 'host' then
    select * into v_session
    from public.host_sessions s
    where s.id = public.current_host_session(p_court_id);

    if v_session.id is not null then
      v_host_id := public.effective_host(p_court_id);
      v_host := jsonb_build_object(
        'session_id', v_session.id,
        'opened_at',  v_session.opened_at,
        'host_name',  (select public.short_name_of(coalesce(pr.full_name, pr.username::text))
                         from public.profiles pr where pr.id = v_host_id),
        'is_me',      v_host_id is not null and v_host_id = auth.uid(),
        'can_show_invite', v_group is not null
      );
    end if;
  end if;

  return jsonb_build_object(
    'court', jsonb_build_object(
      'id',            v_court.id,
      'name',          public.court_label(v_court.court_number),
      'number',        v_court.court_number,
      'surface',       v_court.surface,
      'surface_label', case v_court.surface
                         when 'clay'  then 'Saibro'
                         when 'hard'  then 'Rápida'
                         else 'Grama'
                       end,
      'status',        v_court.status,
      'is_active',     v_court.is_active,
      'slot_minutes',  v_court.slot_minutes,
      'call_window_seconds',  v_court.call_window_seconds,
      'changeover_seconds',   v_court.changeover_seconds,
      'queue_mode',    v_court.queue_mode,
      'checkin_methods', (
        select coalesce(jsonb_agg(m order by m), '[]'::jsonb)
        from (
          select 'qr'::text as m where v_court.has_qr_code and v_court.queue_mode = 'fixed_qr'
          union all
          select 'nfc'::text where v_court.has_nfc_tag and v_court.queue_mode = 'fixed_qr'
          union all
          select 'gps'::text where v_court.queue_mode = 'host'
        ) s
      ),
      'latitude',      v_court.latitude,
      'longitude',     v_court.longitude,
      'rating_avg',    v_court.rating_avg,
      'rating_count',  v_court.rating_count,
      'cover_photo_path', v_court.cover_photo_path
    ),
    'park', jsonb_build_object(
      'id',       v_park.id,
      'name',     v_park.name,
      'district', v_park.district
    ),
    'match',        v_live,
    'is_live',      v_match is not null,
    'changeover',   v_change,
    'is_changeover', v_trading,
    'status_text',  case
                      when v_match is not null then 'Em jogo'
                      when v_trading           then 'Troca de grupo'
                      else 'Livre'
                    end,
    'players_line', case
                      when v_trading
                        then coalesce('Entrando: ' || (v_next ->> 'team_label'),
                                      'Entrando em quadra')
                      when v_match is null then 'Sem jogo agora — check-in libera a quadra'
                      when (v_live ->> 'is_offline')::boolean
                        then coalesce(v_live ->> 'offline_label', 'Grupo sem app')
                      else (
                        select coalesce(string_agg(pl ->> 'short_name', ' · ' order by ord), 'Grupo em quadra')
                        from jsonb_array_elements(v_live -> 'players') with ordinality as t(pl, ord)
                      )
                    end,
    'queue',        v_items,
    'queue_length', v_queue,
    'queue_text',   case
                      when v_queue = 0 then 'Fila vazia'
                      else v_queue || ' na espera'
                    end,
    'remaining_seconds', coalesce(v_rem, 0),
    -- Quem entrar na fila agora espera a quadra liberar mais uma rodada
    -- inteira por grupo à frente — e cada rodada inclui a troca.
    'total_wait_seconds', v_to_head + v_queue * v_per_turn,
    'turn_seconds',       v_per_turn,
    'next_position_label', (v_queue + 1) || 'º',
    'my_entry',     v_mine,
    'my_group',     v_group,
    'my_request',   v_req,
    'host',         v_host,
    'can_open_host', v_court.queue_mode = 'host'
                     and v_host is null
                     and v_court.is_active
                     and v_court.status <> 'unavailable'
                     and (v_state ->> 'state') = 'free',
    'court_accepting', v_court.is_active and v_court.status <> 'unavailable',
    'can_join',     v_court.is_active
                    and v_court.status <> 'unavailable'
                    and (v_state ->> 'state') = 'free'
                    and (v_court.queue_mode = 'fixed_qr' or v_host is not null),
    'my_state',     v_state,
    'generated_at', now()
  );
end;
$$;

grant execute on function public.court_screen(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 13. Um empurrãozinho de quem está com a tela aberta
--
-- O cron roda de minuto em minuto. Uma troca de 60 s esperando o
-- próximo tique duraria, na pior hora, quase dois minutos — e quem está
-- na quadra veria o contador zerar e nada acontecer.
--
-- Esta função deixa o próprio app fechar essa diferença: a tela da
-- quadra chama quando o contador zera. Ela não decide nada; só executa
-- o que JÁ estava vencido. Chamar fora de hora não adianta nada, então
-- não dá para pular a vez de ninguém com ela.
-- ---------------------------------------------------------------------
create or replace function public.nudge_court(p_court_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_due boolean;
begin
  select exists (
           select 1 from public.courts c
           where c.id = p_court_id
             and c.changeover_until is not null
             and c.changeover_until <= now()
         )
      or exists (
           select 1 from public.matches mt
           where mt.court_id = p_court_id
             and mt.ended_at is null
             and mt.expires_at <= now()
         )
      or exists (
           select 1 from public.queue_entries e
           where e.court_id = p_court_id
             and e.status = 'ready'
             and e.call_expires_at is not null
             and e.call_expires_at <= now()
         )
    into v_due;

  if v_due then
    perform public.advance_court(p_court_id);
  end if;

  return public.court_screen(p_court_id);
end;
$$;

revoke all on function public.nudge_court(uuid) from public, anon, authenticated;
grant execute on function public.nudge_court(uuid) to authenticated;

comment on function public.nudge_court(uuid) is
  'Executa o que já venceu na quadra (turno, troca, chamada) e devolve a tela. '
  'Chamada pelo app quando o contador zera, para não esperar o cron.';

-- ---------------------------------------------------------------------
-- 14. O painel do piloto não pode contar o mesmo grupo a cada rodada
--
-- "Quantos grupos entraram na fila" e "por onde cada pessoa chegou" são
-- perguntas sobre chegada. Com a rotação, o mesmo grupo passa a ter uma
-- vaga por turno — numa tarde de 3 horas, o grupo da manhã inteira
-- apareceria quatro vezes e o painel diria que o piloto teve quatro
-- vezes mais gente do que teve.
--
-- Já "turnos", "espera" e "chamadas" são medidas POR TURNO: essas
-- continuam lendo todas as vagas, porque é isso que elas medem.
-- ---------------------------------------------------------------------
create or replace function public.admin_pilot_stats(
  p_park_id uuid default null,
  p_from    date default null,
  p_to      date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz    constant text := 'America/Sao_Paulo';
  v_today date := (now() at time zone 'America/Sao_Paulo')::date;
  v_from  date;
  v_to    date;
  v_start timestamptz;
  v_end   timestamptz;
begin
  perform public.require_admin();

  v_to    := coalesce(p_to, v_today);
  v_from  := coalesce(p_from, v_to - 29);
  if v_from > v_to then
    raise exception 'O período começa depois de terminar' using errcode = 'NQ032';
  end if;
  if v_to - v_from > 366 then
    raise exception 'O período vai até um ano' using errcode = 'NQ032';
  end if;

  v_start := v_from::timestamp at time zone v_tz;
  v_end   := (v_to + 1)::timestamp at time zone v_tz;

  return (
    with courts as (
      select c.id, c.court_number, c.park_id, pk.name as park_name
      from public.courts c
      join public.parks pk on pk.id = c.park_id
      where p_park_id is null or c.park_id = p_park_id
    ),
    entries as (
      select e.*
      from public.queue_entries e
      join courts c on c.id = e.court_id
      where e.joined_at >= v_start and e.joined_at < v_end
    ),
    -- A rotação cria uma vaga nova a cada turno do mesmo grupo. Para
    -- "quantos entraram na fila" e para a origem de cada pessoa, o que
    -- conta é a chegada: a vaga sem requeued_from.
    arrivals as (
      select e.* from entries e where e.requeued_from is null
    ),
    members as (
      select m.*, e.joined_at as entry_joined_at
      from public.queue_entry_members m
      join arrivals e on e.id = m.entry_id
      where not e.is_offline
    ),
    invites as (
      select i.*
      from public.host_invites i
      join courts c on c.id = i.court_id
      where i.issued_at >= v_start and i.issued_at < v_end
    ),
    events as (
      select ev.*
      from public.pilot_events ev
      join courts c on c.id = ev.court_id
      where ev.created_at >= v_start and ev.created_at < v_end
    ),
    turns as (
      select mt.*, e.is_offline
      from public.matches mt
      join courts c on c.id = mt.court_id
      join public.queue_entries e on e.id = mt.side_a_entry_id
      where mt.started_at >= v_start and mt.started_at < v_end
    ),
    waits as (
      select extract(epoch from (e.started_at - e.joined_at)) / 60.0 as minutes
      from entries e
      where not e.is_offline and e.started_at is not null
    ),
    invite_joins as (
      select m.user_id, i.issued_by, i.issued_at
      from members m
      join public.host_invites i on i.id = m.invite_id
      where m.origin = 'host_invite'
    ),
    spreaders as (
      select issued_by, count(distinct user_id) as brought
      from invite_joins
      group by issued_by
    )
    select jsonb_build_object(
      'period', jsonb_build_object('from', v_from, 'to', v_to),
      'totals', jsonb_build_object(
        'people',          (select count(distinct user_id) from members),
        'app_entries',     (select count(*) from arrivals where not is_offline),
        'offline_entries', (select count(*) from arrivals where is_offline
                              and offline_kind = 'waiting'),
        'sessions',        (select count(*) from public.host_sessions s
                              join courts c on c.id = s.court_id
                             where s.opened_at >= v_start and s.opened_at < v_end),
        'turns',           (select count(*) from turns where not is_offline),
        'hours_played',    round(coalesce((
                             select sum(extract(epoch from (least(coalesce(ended_at, now()), expires_at) - started_at)))
                             from turns
                           ), 0)::numeric / 3600, 1)
      ),
      'daily', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'day',             d.day,
                 'people',          (select count(distinct m.user_id) from members m
                                      where (m.entry_joined_at at time zone v_tz)::date = d.day),
                 'app_entries',     (select count(*) from arrivals e
                                      where not e.is_offline and (e.joined_at at time zone v_tz)::date = d.day),
                 'offline_entries', (select count(*) from arrivals e
                                      where e.is_offline and e.offline_kind = 'waiting'
                                        and (e.joined_at at time zone v_tz)::date = d.day)
               ) order by d.day), '[]'::jsonb)
        from (select generate_series(v_from, v_to, interval '1 day')::date as day) d
      ),
      'origins', (
        select coalesce(jsonb_object_agg(origin, n), '{}'::jsonb)
        from (select coalesce(origin, 'unknown') as origin, count(*) as n from members group by 1) o
      ),
      'funnel', jsonb_build_object(
        'shown',        (select count(distinct display_id) from invites),
        'opened',       (select count(distinct visitor) from events where event = 'invite_opened'),
        'scanned',      (select count(distinct user_id) from events where event = 'invite_scanned'),
        'too_far',      (select count(*) from events where event = 'invite_too_far'),
        'new_accounts', (select count(distinct ev.user_id)
                           from events ev
                           join auth.users u on u.id = ev.user_id
                           join public.host_invites i on i.id = ev.invite_id
                          where ev.event = 'invite_scanned' and u.created_at >= i.issued_at),
        'joined',       (select count(distinct user_id) from invite_joins)
      ),
      'wait', jsonb_build_object(
        'samples',    (select count(*) from waits),
        'median_min', (select round(percentile_cont(0.5) within group (order by minutes)::numeric, 1) from waits),
        'p90_min',    (select round(percentile_cont(0.9) within group (order by minutes)::numeric, 1) from waits)
      ),
      'by_hour', (
        select coalesce(jsonb_agg(jsonb_build_object('hour', h.hour, 'turns', h.turns) order by h.hour), '[]'::jsonb)
        from (
          select g.hour,
                 (select count(*) from turns t
                   where extract(hour from (t.started_at at time zone v_tz)) = g.hour) as turns
          from generate_series(0, 23) as g(hour)
        ) h
      ),
      'calls', jsonb_build_object(
        'called', (select count(*) from entries where not is_offline and called_at is not null),
        'missed', (select count(*) from entries where not is_offline and cancel_reason = 'no_show')
      ),
      'offline_hold', jsonb_build_object(
        'samples', (select count(*) from entries
                     where is_offline and called_at is not null
                       and coalesce(started_at, left_at) is not null
                       and offline_kind = 'waiting'),
        'avg_min', (select round(avg(extract(epoch from (coalesce(started_at, left_at) - called_at)) / 60.0)::numeric, 1)
                      from entries
                     where is_offline and called_at is not null
                       and coalesce(started_at, left_at) is not null
                       and offline_kind = 'waiting'),
        'max_min', (select round(max(extract(epoch from (coalesce(started_at, left_at) - called_at)) / 60.0)::numeric, 1)
                      from entries
                     where is_offline and called_at is not null
                       and coalesce(started_at, left_at) is not null
                       and offline_kind = 'waiting')
      ),
      'spreaders', jsonb_build_object(
        'people', (select count(*) from spreaders),
        'top',    (select coalesce(jsonb_agg(s.brought order by s.brought desc), '[]'::jsonb)
                     from (select brought from spreaders order by brought desc limit 5) s)
      ),
      'courts', (
        select coalesce(jsonb_agg(jsonb_build_object(
                 'court_id',        c.id,
                 'label',           c.park_name || ' · ' || public.court_label(c.court_number),
                 'people',          (select count(distinct m.user_id) from members m where m.court_id = c.id),
                 'app_entries',     (select count(*) from arrivals e where e.court_id = c.id and not e.is_offline),
                 'offline_entries', (select count(*) from arrivals e where e.court_id = c.id and e.is_offline
                                       and e.offline_kind = 'waiting')
               ) order by c.park_name, c.court_number), '[]'::jsonb)
        from courts c
      )
    )
  );
end;
$$;

revoke all on function public.admin_pilot_stats(uuid, date, date) from public, anon, authenticated;
grant execute on function public.admin_pilot_stats(uuid, date, date) to authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20261102130000_admin_ajusta_o_tempo.sql
-- ####################################################################

-- =====================================================================
-- O admin ajusta o tempo do turno em andamento
--
-- O relógio da quadra é o do banco, e ele começa quando o turno começa.
-- Na quadra real isso sai errado de vez em quando: o grupo entrou cinco
-- minutos antes de alguém marcar, a troca demorou mais que o minuto, o
-- anfitrião marcou "entraram" com o grupo ainda juntando as raquetes.
-- Quando isso acontece, hoje não há nada a fazer: ou se espera um turno
-- errado até o fim, ou se devolve a quadra e a fila anda cedo.
--
-- Então o administrador passa a poder dizer quanto falta. É uma
-- correção de relógio, não um favor: fica registrado quem mexeu, quando
-- e quanto, e a tela de todo mundo mostra que o tempo foi ajustado.
--
-- Zerar o tempo encerra o turno na hora — a quadra entra na troca de 1
-- minuto e o próximo começa sozinho, como em qualquer fim de turno
-- (docs/sprint6.md).
-- =====================================================================

alter table public.matches
  add column if not exists time_adjusted_at      timestamptz,
  add column if not exists time_adjusted_by      uuid references auth.users (id) on delete set null,
  add column if not exists time_adjusted_seconds integer not null default 0;

comment on column public.matches.time_adjusted_at is
  'Último ajuste de relógio feito pelo administrador neste turno.';
comment on column public.matches.time_adjusted_seconds is
  'Soma dos ajustes, em segundos. Positivo = o turno ganhou tempo.';

-- ---------------------------------------------------------------------
-- Quanto falta, dito pelo administrador
--
-- O contrato é "faltam N minutos", e não "+5" nem "-5": assim duas
-- pessoas mexendo ao mesmo tempo não somam ajustes sem perceber, e
-- repetir a chamada não muda nada. Os botões de +5 e -5 do app mandam o
-- total já calculado.
-- ---------------------------------------------------------------------
create or replace function public.admin_set_match_time(
  p_match_id          uuid,
  p_remaining_minutes integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_match public.matches%rowtype;
  v_new   timestamptz;
  v_delta integer;
begin
  perform public.require_admin();

  if p_remaining_minutes is null
     or p_remaining_minutes < 0
     or p_remaining_minutes > 240 then
    raise exception 'O tempo restante vai de 0 a 240 minutos' using errcode = 'NQ036';
  end if;

  select * into v_match from public.matches mt where mt.id = p_match_id for update;
  if not found then
    raise exception 'Partida não encontrada' using errcode = 'NQ018';
  end if;
  if v_match.ended_at is not null then
    raise exception 'Este turno já foi encerrado' using errcode = 'NQ009';
  end if;

  -- Zero significa "acabou agora". Um segundo para trás, para o
  -- advance_court logo abaixo ver o turno como vencido — now() é o
  -- mesmo instante dentro da transação, e `expires_at <= now()` com os
  -- dois exatamente iguais depende de arredondamento.
  v_new := case
             when p_remaining_minutes = 0 then now() - interval '1 second'
             else now() + make_interval(mins => p_remaining_minutes)
           end;

  v_delta := round(extract(epoch from (v_new - v_match.expires_at)))::integer;

  update public.matches
     set expires_at            = v_new,
         time_adjusted_at      = now(),
         time_adjusted_by      = auth.uid(),
         time_adjusted_seconds = time_adjusted_seconds + v_delta
   where id = p_match_id;

  if p_remaining_minutes = 0 then
    perform public.advance_court(v_match.court_id);
  end if;

  return public.court_screen(v_match.court_id);
end;
$$;

revoke all on function public.admin_set_match_time(uuid, integer) from public, anon, authenticated;
grant execute on function public.admin_set_match_time(uuid, integer) to authenticated;

comment on function public.admin_set_match_time(uuid, integer) is
  'Administrador corrige quanto falta no turno em andamento. 0 encerra agora. '
  'Registra quem ajustou, quando e quanto.';

-- ---------------------------------------------------------------------
-- O ajuste aparece para todo mundo
--
-- Um relógio que pula sem explicação é pior que um relógio errado: quem
-- está em quadra acha que o app quebrou. A tela mostra que o tempo foi
-- ajustado pela organização.
-- ---------------------------------------------------------------------
create or replace function public.match_state(p_match_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_match   public.matches%rowtype;
  v_court   public.courts%rowtype;
  v_entry   public.queue_entries%rowtype;
  v_players jsonb;
begin
  select * into v_match from public.matches mt where mt.id = p_match_id;
  if not found then
    raise exception 'Partida não encontrada' using errcode = 'NQ018';
  end if;

  select * into v_court from public.courts c where c.id = v_match.court_id;
  select * into v_entry from public.queue_entries e where e.id = v_match.side_a_entry_id;

  v_players := public.match_side_players(v_match.side_a_entry_id);

  return jsonb_build_object(
    'match_id',      v_match.id,
    'court_id',      v_match.court_id,
    'court_name',    public.court_label(v_court.court_number),
    'entry_id',      v_match.side_a_entry_id,
    'players',       v_players,
    'group_size',    jsonb_array_length(v_players),
    'group_label',   case when v_entry.is_offline then 'Sem app'
                          else public.group_label(jsonb_array_length(v_players)) end,
    'is_offline',    coalesce(v_entry.is_offline, false),
    'offline_label', v_entry.offline_label,
    'slot_minutes',  v_match.slot_minutes,
    'started_at',    v_match.started_at,
    'expires_at',    v_match.expires_at,
    'ended_at',      v_match.ended_at,
    'end_reason',    v_match.end_reason,
    'is_live',       v_match.ended_at is null,
    'time_adjusted_at',      v_match.time_adjusted_at,
    'time_adjusted_seconds', v_match.time_adjusted_seconds,
    'elapsed_seconds',   greatest(0, floor(extract(epoch from (
                           coalesce(v_match.ended_at, now()) - v_match.started_at)))::integer),
    'remaining_seconds', case
                           when v_match.ended_at is not null then 0
                           else greatest(0, floor(extract(epoch from (
                             v_match.expires_at - now())))::integer)
                         end
  );
end;
$$;

grant execute on function public.match_state(uuid) to anon, authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20261104120000_chamada_do_turno.sql
-- ####################################################################

-- =====================================================================
-- A chamada do turno: 15 segundos para aceitar, 30 para entrar
--
-- A rotação automática (Sprint 6) trocava de grupo sozinha, com 1 minuto
-- de troca. Na quadra real falta uma coisa no meio: alguém tem de dizer
-- "é a vez de vocês" em voz alta, e alguém do grupo tem de responder.
-- Sem isso, o turno começava para um grupo que podia nem estar ali.
--
-- Agora o fim do turno abre uma CHAMADA:
--
--   acabou o tempo
--        │
--        ├─▶ quem jogou vai para o FIM da fila (como na Sprint 6)
--        │
--        └─▶ chama o 1º da fila pelo nome, por 15 s
--              │
--              ├─ alguém do grupo aperta JOGAR ──▶ 30 s para entrar
--              │                                      │
--              │                                      ▼
--              │                             começa o tempo do turno
--              │
--              └─ ninguém aperta em 15 s ──▶ esse grupo vai para o
--                   fim da fila e a chamada desce para o seguinte
--
-- Passada a fila inteira sem ninguém aceitar, a quadra fica livre e a
-- chamada para — senão o tablet ficaria gritando nomes a noite toda num
-- parque vazio.
--
-- Decisões que o pedido deixou abertas, respondidas pelo Pedro:
--   . quem não aceita em 15 s VAI PARA O FIM DA FILA (não perde a vaga,
--     mas perde a posição);
--   . uma volta na fila sem aceite libera a quadra.
--
-- E uma regra que o pedido já trazia: basta UMA pessoa do grupo apertar.
-- Não é check-in de cada jogador; é o grupo respondendo à chamada.
--
-- ONDE A CHAMADA VALE
--
-- Chamar por 15 segundos só faz sentido se alguém estiver GRITANDO os
-- nomes. Numa quadra em modo anfitrião não há tablet nenhum: a chamada
-- ali passaria a fila inteira para trás a cada 15 s, sem ninguém ouvir,
-- e no fim a quadra ficaria livre do mesmo jeito — depois de embaralhar
-- a fila por nada.
--
-- Então a quadra tem dois jeitos de trocar de turno, e quem escolhe é a
-- presença de um tablet aceso:
--
--   . COM tablet acordado (falou com o servidor nos últimos 2 min):
--     chamada de 15 s descendo a fila, JOGAR, 30 s para entrar.
--   . SEM tablet: a troca automática de 1 minuto da Sprint 6 — o turno
--     do próximo começa sozinho, sem ninguém precisar tocar em nada.
--
-- Tablet desligado ou sem internet volta sozinho para a troca
-- automática: é a diferença entre a quadra parar e a quadra andar.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. O tablet da quadra
--
-- Um aparelho compartilhado não pode carregar a conta de ninguém: se o
-- tablet do parque for levado, não vai sessão de admin com ele. Então
-- ele tem identidade própria — um token por quadra, guardado aqui só
-- como hash, revogável, e que não serve para mais nada além de ver a
-- quadra e aceitar a vez de quem está sendo chamado.
-- ---------------------------------------------------------------------
create table if not exists public.court_devices (
  id           uuid primary key default gen_random_uuid(),
  court_id     uuid not null references public.courts (id) on delete cascade,
  label        text,
  token_hash   text not null unique,
  created_by   uuid references auth.users (id) on delete set null,
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz,
  revoked_at   timestamptz,

  constraint court_devices_label_check
    check (label is null or char_length(label) <= 60)
);

comment on table public.court_devices is
  'O tablet (ou TV, ou telefone velho) que fica na quadra chamando os próximos. '
  'Sem conta: o acesso é um token por aparelho, guardado em hash.';
comment on column public.court_devices.last_seen_at is
  'Última vez que este aparelho falou com o servidor. É o que diz se a quadra '
  'tem alguém para gritar os nomes.';

create index if not exists court_devices_court_idx
  on public.court_devices (court_id) where revoked_at is null;

alter table public.court_devices enable row level security;
revoke all on public.court_devices from anon, authenticated;

-- ---------------------------------------------------------------------
-- A quadra tem quem grite os nomes?
--
-- Dois minutos: a tela do tablet conversa com o servidor a cada poucos
-- segundos, então dois minutos de silêncio significam tablet desligado,
-- sem internet ou com a aba fechada.
-- ---------------------------------------------------------------------
create or replace function public.court_tablet_awake(p_court_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.court_devices d
    where d.court_id = p_court_id
      and d.revoked_at is null
      and d.last_seen_at > now() - interval '2 minutes'
  );
$$;

revoke all on function public.court_tablet_awake(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 1. Os dois relógios da chamada
--
-- Substituem a troca única de 1 minuto da Sprint 6. changeover_seconds
-- e changeover_until saem de cena: duraram dois dias e não têm mais
-- função, e deixar coluna morta no banco é pegadinha para quem vier.
-- ---------------------------------------------------------------------
alter table public.courts
  add column if not exists handover_call_seconds  smallint not null default 15,
  add column if not exists handover_entry_seconds smallint not null default 30,
  add column if not exists handover_phase         text,
  add column if not exists handover_entry_id      uuid
    references public.queue_entries (id) on delete set null,
  add column if not exists handover_until         timestamptz,
  add column if not exists handover_calls_left    smallint not null default 0;

do $$ begin
  alter table public.courts
    add constraint courts_handover_call_seconds_range
    check (handover_call_seconds between 5 and 120);
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.courts
    add constraint courts_handover_entry_seconds_range
    check (handover_entry_seconds between 5 and 300);
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.courts
    add constraint courts_handover_phase_check
    check (handover_phase is null or handover_phase in ('changeover', 'calling', 'entering'));
exception when duplicate_object then null; end $$;

-- Os três andam juntos: fase, quem e até quando. Meio preenchido é
-- estado impossível, e é melhor o banco recusar do que o app adivinhar.
do $$ begin
  alter table public.courts
    add constraint courts_handover_complete
    check ((handover_phase is null and handover_entry_id is null and handover_until is null)
           or (handover_phase is not null and handover_entry_id is not null
               and handover_until is not null));
exception when duplicate_object then null; end $$;

comment on column public.courts.handover_call_seconds is
  'Quanto tempo a quadra chama um grupo antes de passar para o seguinte (padrão 15s).';
comment on column public.courts.handover_entry_seconds is
  'Depois do JOGAR, quanto tempo o grupo tem para entrar na quadra (padrão 30s).';
comment on column public.courts.handover_phase is
  'changeover: quadra sem tablet, o turno do próximo começa sozinho no fim. '
  'calling: o tablet está chamando o grupo. entering: aceitou e está entrando.';
comment on column public.courts.handover_calls_left is
  'Quantos grupos ainda podem ser chamados nesta volta da fila. Zerou, a quadra libera.';

create index if not exists courts_handover_idx
  on public.courts (handover_until) where handover_until is not null;

-- changeover_until sai: quem guarda o prazo agora é handover_until, para
-- os três jeitos de trocar de turno terem um relógio só.
-- changeover_seconds FICA: é a duração da troca automática das quadras
-- sem tablet.
alter table public.courts drop column if exists changeover_until;
drop index if exists public.courts_changeover_idx;

comment on column public.courts.changeover_seconds is
  'Troca automática das quadras SEM tablet: quanto o próximo espera antes de o '
  'turno dele começar sozinho (padrão 60s).';

-- ---------------------------------------------------------------------
-- 2. Quem respondeu pelo grupo
--
-- Basta uma pessoa. Fica gravado quem foi — não para cobrar ninguém,
-- mas porque "o grupo aceitou" sem saber por quem é o tipo de dado que
-- falta justo no dia em que alguém reclama.
-- ---------------------------------------------------------------------
alter table public.queue_entries
  add column if not exists accepted_at timestamptz,
  add column if not exists accepted_by uuid references auth.users (id) on delete set null;

comment on column public.queue_entries.accepted_at is
  'Quando alguém do grupo apertou JOGAR nesta chamada.';
comment on column public.queue_entries.accepted_by is
  'Quem apertou. Nulo quando foi o tablet da quadra, que não tem conta.';

-- ---------------------------------------------------------------------
-- 3. Recolocar no fim da fila — agora também sem ter jogado
--
-- Perder a vez por não responder não é a mesma coisa que ter jogado: o
-- turno não conta, então turn_number não anda. A assinatura de um
-- argumento sai de cena para não ficarem duas vivas ao mesmo tempo —
-- com todos os parâmetros com padrão, uma chamada nomeada ficaria
-- ambígua ("is not unique"), que foi exatamente o erro que travou o
-- deploy no PR #14.
-- ---------------------------------------------------------------------
drop function if exists public.requeue_entry(uuid);

create or replace function public.requeue_entry(
  p_entry_id uuid,
  p_played   boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old public.queue_entries%rowtype;
  v_new uuid;
begin
  select * into v_old from public.queue_entries e where e.id = p_entry_id;
  if not found then
    return null;
  end if;

  insert into public.queue_entries
    (court_id, mode, status, created_by, scan_token_id,
     is_offline, offline_label, offline_kind, host_session_id,
     first_joined_at, requeued_from, turn_number)
  values
    (v_old.court_id, v_old.mode, 'waiting', v_old.created_by, null,
     v_old.is_offline, v_old.offline_label, v_old.offline_kind, v_old.host_session_id,
     v_old.first_joined_at, v_old.id,
     case when p_played then v_old.turn_number + 1 else v_old.turn_number end)
  returning id into v_new;

  insert into public.queue_entry_members
    (entry_id, court_id, user_id, role, origin, invite_id, joined_via, checked_in_at)
  select v_new, m.court_id, m.user_id, m.role,
         coalesce(m.origin, 'requeued'), m.invite_id, m.joined_via, m.checked_in_at
  from public.queue_entry_members m
  where m.entry_id = p_entry_id and m.left_at is null;

  insert into public.queue_entry_pins (entry_id, pin)
  select v_new,
         case
           when exists (
             select 1
             from public.queue_entry_pins p2
             join public.queue_entries e2 on e2.id = p2.entry_id
             where e2.court_id = v_old.court_id
               and e2.status in ('waiting', 'ready', 'playing')
               and e2.id <> v_new
               and p2.pin = p.pin
           ) then public.new_group_pin(v_old.court_id)
           else p.pin
         end
  from public.queue_entry_pins p
  where p.entry_id = p_entry_id;

  return v_new;
end;
$$;

revoke all on function public.requeue_entry(uuid, boolean) from public, anon, authenticated;

comment on function public.requeue_entry(uuid, boolean) is
  'Devolve o grupo da vaga informada para o fim da fila, numa vaga nova. '
  'p_played = false quando ele não jogou (não respondeu à chamada): o turno não conta.';

-- ---------------------------------------------------------------------
-- 4. Abrir a chamada
--
-- handover_calls_left começa valendo o tamanho da fila: como cada grupo
-- que não responde vai para o fim, a fila não encurta, e contar as
-- chamadas é o jeito simples de saber que já se deu uma volta inteira.
-- ---------------------------------------------------------------------
create or replace function public.start_handover(p_court_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court   public.courts%rowtype;
  v_next    uuid;
  v_size    integer;
  v_offline boolean;
  v_label   text;
  v_host    uuid;
begin
  select * into v_court from public.courts c where c.id = p_court_id for update;
  if not found then
    return null;
  end if;

  -- Quadra ocupada não chama ninguém.
  if exists (select 1 from public.matches mt
             where mt.court_id = p_court_id and mt.ended_at is null) then
    return null;
  end if;

  select qp.entry_id into v_next
  from public.queue_positions qp
  where qp.court_id = p_court_id
  order by qp.position
  limit 1;

  if v_next is null then
    update public.courts
       set handover_phase = null, handover_entry_id = null,
           handover_until = null, handover_calls_left = 0
     where id = p_court_id;
    return null;
  end if;

  select e.is_offline, e.offline_label into v_offline, v_label
  from public.queue_entries e where e.id = v_next;

  -- Grupo sem app chegando na vez: quem responde por ele é o anfitrião,
  -- e ele precisa saber. Vale nos dois jeitos de trocar de turno — sem
  -- este aviso, a vaga sem app andaria sozinha e ninguém entenderia por
  -- que a quadra mudou de grupo.
  if v_offline then
    v_host := public.effective_host(p_court_id);
  end if;

  -- Quadra sem tablet aceso: ninguém tem como gritar o nome de ninguém.
  -- Volta a ser a troca automática da Sprint 6 — o turno do próximo
  -- começa sozinho no fim dela.
  if not public.court_tablet_awake(p_court_id) then
    update public.courts
       set handover_phase      = 'changeover',
           handover_entry_id   = v_next,
           handover_until      = now() + make_interval(secs => v_court.changeover_seconds),
           handover_calls_left = 0,
           holder_entry_id     = null,
           status = case
                      when status = 'unavailable' then 'unavailable'::public.court_status
                      else 'available'::public.court_status
                    end
     where id = p_court_id;

    update public.queue_entries
       set status = 'ready', called_at = coalesce(called_at, now()), call_expires_at = null
     where id = v_next and status = 'waiting';

    if v_host is not null then
      perform public.enqueue_user_notification(
        v_host, p_court_id, 'host_offline_called',
        'Vez do grupo sem app',
        format('%s pode entrar na %s. Marque no app quando entrarem.',
               coalesce(v_label, 'O grupo sem app'),
               public.court_label(v_court.court_number)),
        jsonb_build_object('court_id', p_court_id, 'entry_id', v_next)
      );
    end if;

    return v_next;
  end if;

  -- Já está contando uma volta? Continua a mesma; senão, começa uma.
  if v_court.handover_calls_left <= 0 then
    select count(*)::integer into v_size
    from public.queue_positions qp where qp.court_id = p_court_id;
  else
    v_size := v_court.handover_calls_left;
  end if;

  update public.courts
     set handover_phase      = 'calling',
         handover_entry_id   = v_next,
         handover_until      = now() + make_interval(secs => v_court.handover_call_seconds),
         handover_calls_left = v_size,
         holder_entry_id     = null,
         status = case
                    when status = 'unavailable' then 'unavailable'::public.court_status
                    else 'available'::public.court_status
                  end
   where id = p_court_id;

  -- A vaga chamada aparece como chamada. Sem call_expires_at: o relógio
  -- desta chamada é o da quadra, e quem expira é a chamada, não a vaga.
  update public.queue_entries
     set status = 'ready', called_at = coalesce(called_at, now()), call_expires_at = null
   where id = v_next and status = 'waiting';

  -- Push para quem tem app: o tablet grita o nome, mas quem foi ao
  -- banheiro tem o celular no bolso.
  perform public.enqueue_team_notification(
    v_next, 'queue_turn', 'É a sua vez!',
    format('Aperte JOGAR: a %s está chamando o seu grupo.',
           public.court_label(v_court.court_number)),
    jsonb_build_object('court_id', p_court_id, 'entry_id', v_next, 'teams_ahead', 0)
  );

  if v_host is not null then
    perform public.enqueue_user_notification(
      v_host, p_court_id, 'host_offline_called',
      'Vez do grupo sem app',
      format('%s está sendo chamado na %s. Aperte JOGAR por eles.',
             coalesce(v_label, 'O grupo sem app'),
             public.court_label(v_court.court_number)),
      jsonb_build_object('court_id', p_court_id, 'entry_id', v_next)
    );
  end if;

  return v_next;
end;
$$;

revoke all on function public.start_handover(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. Ninguém aceitou em 15 s: desce a fila
-- ---------------------------------------------------------------------
create or replace function public.skip_handover(p_court_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court public.courts%rowtype;
  v_left  integer;
begin
  select * into v_court from public.courts c where c.id = p_court_id for update;
  if not found or v_court.handover_phase is distinct from 'calling' then
    return null;
  end if;

  -- Não respondeu: vai para o fim da fila, com o turno NÃO contado.
  update public.queue_entries
     set status = 'expired', cancel_reason = 'no_answer', left_at = now()
   where id = v_court.handover_entry_id and status in ('waiting', 'ready');

  update public.queue_join_requests
     set status = 'expired', decided_at = now()
   where status = 'pending' and entry_id = v_court.handover_entry_id;

  perform public.requeue_entry(v_court.handover_entry_id, false);

  v_left := v_court.handover_calls_left - 1;

  update public.courts
     set handover_phase = null, handover_entry_id = null, handover_until = null,
         handover_calls_left = greatest(v_left, 0)
   where id = p_court_id;

  if v_left <= 0 then
    -- Deu a volta na fila e ninguém aceitou: a quadra fica livre e o
    -- anúncio para. Volta a andar quando alguém apertar JOGAR.
    update public.courts set handover_calls_left = 0 where id = p_court_id;
    return null;
  end if;

  return public.start_handover(p_court_id);
end;
$$;

revoke all on function public.skip_handover(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. Alguém do grupo apertou JOGAR
--
-- Uma pessoa basta. Não confere se o grupo todo está na quadra: quem
-- está lá sabe disso melhor que o app, e exigir o aceite de cada um era
-- justamente o que fazia a fila travar.
-- ---------------------------------------------------------------------
create or replace function public.accept_handover(
  p_court_id uuid,
  p_user_id  uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court public.courts%rowtype;
  v_head  uuid;
begin
  select * into v_court from public.courts c where c.id = p_court_id for update;
  if not found then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;
  if not v_court.is_active or v_court.status = 'unavailable' then
    raise exception 'Esta quadra está indisponível no momento' using errcode = 'NQ003';
  end if;

  -- Já aceitou e está entrando: apertar de novo não atrasa nem adianta.
  if v_court.handover_phase = 'entering' then
    return public.court_screen(p_court_id);
  end if;

  -- Na troca automática (quadra sem tablet) o turno já vai começar
  -- sozinho; apertar JOGAR só antecipa. É o atalho de quem já está em
  -- quadra e não quer esperar o contador.
  if v_court.handover_phase = 'changeover' then
    update public.queue_entries
       set accepted_at = now(), accepted_by = p_user_id
     where id = v_court.handover_entry_id;
    perform public.open_match(v_court.handover_entry_id);
    return public.court_screen(p_court_id);
  end if;

  if v_court.handover_phase = 'calling' then
    update public.courts
       set handover_phase = 'entering',
           handover_until = now() + make_interval(secs => v_court.handover_entry_seconds)
     where id = p_court_id;

    update public.queue_entries
       set accepted_at = now(), accepted_by = p_user_id
     where id = v_court.handover_entry_id;

    return public.court_screen(p_court_id);
  end if;

  -- Sem chamada aberta: se a quadra está livre e há fila, JOGAR começa
  -- o turno na hora. É o mesmo gesto do check-in, e vale para o
  -- primeiro turno de uma fila, em que não houve chamada nenhuma.
  if exists (select 1 from public.matches mt
             where mt.court_id = p_court_id and mt.ended_at is null) then
    raise exception 'A quadra já está em jogo' using errcode = 'NQ017';
  end if;

  select qp.entry_id into v_head
  from public.queue_positions qp
  where qp.court_id = p_court_id
  order by qp.position
  limit 1;

  if v_head is null then
    raise exception 'Não há ninguém na fila desta quadra' using errcode = 'NQ007';
  end if;

  update public.queue_entries
     set accepted_at = now(), accepted_by = p_user_id
   where id = v_head;

  perform public.open_match(v_head);
  return public.court_screen(p_court_id);
end;
$$;

revoke all on function public.accept_handover(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. JOGAR a partir do app de quem está na fila
--
-- O tablet tem a função dele (migration seguinte). Esta é para o
-- celular: quem é do grupo chamado, o anfitrião — que responde pelo
-- grupo sem app — ou a operação do parque.
-- ---------------------------------------------------------------------
create or replace function public.accept_turn(p_court_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user  uuid := auth.uid();
  v_court public.courts%rowtype;
  v_entry uuid;
begin
  if v_user is null then
    raise exception 'Autenticação obrigatória' using errcode = 'NQ001';
  end if;

  select * into v_court from public.courts c where c.id = p_court_id;
  if not found then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;

  v_entry := coalesce(
    v_court.handover_entry_id,
    (select qp.entry_id from public.queue_positions qp
      where qp.court_id = p_court_id order by qp.position limit 1)
  );

  if v_entry is null then
    raise exception 'Não há ninguém na fila desta quadra' using errcode = 'NQ007';
  end if;

  if not public.is_entry_member(v_entry, v_user)
     and not public.is_staff()
     and public.effective_host(p_court_id) is distinct from v_user then
    raise exception 'Só quem está no grupo chamado pode aceitar a vez' using errcode = 'NQ008';
  end if;

  return public.accept_handover(p_court_id, v_user);
end;
$$;

revoke all on function public.accept_turn(uuid) from public, anon, authenticated;
grant execute on function public.accept_turn(uuid) to authenticated;

comment on function public.accept_turn(uuid) is
  'Uma pessoa do grupo chamado (ou o anfitrião, ou a operação) aceita a vez. '
  'Abre os segundos de entrada; sem chamada aberta e com a quadra livre, começa o turno.';

-- ---------------------------------------------------------------------
-- 8. Encerrar o turno — agora abrindo a chamada
-- ---------------------------------------------------------------------
create or replace function public.close_match(
  p_match_id uuid,
  p_winner   public.match_side,
  p_reason   public.match_end_reason,
  p_reporter uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_match   public.matches%rowtype;
  v_waiting boolean;
begin
  select * into v_match from public.matches mt where mt.id = p_match_id for update;
  if not found then
    raise exception 'Partida não encontrada' using errcode = 'NQ018';
  end if;
  if v_match.ended_at is not null then
    return public.match_state(p_match_id);
  end if;

  update public.matches
     set ended_at    = now(),
         winner_side = null,
         end_reason  = p_reason,
         reported_by = p_reporter
   where id = p_match_id;

  -- O lado B só existe em turnos gravados antes da Sprint 4.
  update public.queue_entries
     set status = 'done', ended_at = now()
   where id in (v_match.side_a_entry_id, v_match.side_b_entry_id)
     and status = 'playing';

  update public.queue_join_requests
     set status = 'expired', decided_at = now()
   where status = 'pending'
     and entry_id in (v_match.side_a_entry_id, v_match.side_b_entry_id);

  -- A quadra fica livre em qualquer caso. A chamada, não.
  update public.courts
     set holder_entry_id   = null,
         handover_phase    = null,
         handover_entry_id = null,
         handover_until    = null,
         status = case
                    when status = 'unavailable' then 'unavailable'::public.court_status
                    else 'available'::public.court_status
                  end
   where id = v_match.court_id;

  select exists (
    select 1 from public.queue_positions qp where qp.court_id = v_match.court_id
  ) into v_waiting;

  if v_waiting and p_reason = 'slot_expired' then
    -- Acabou o tempo com fila atrás: quem jogou vai para o fim e a
    -- quadra começa a chamar o próximo.
    perform public.requeue_entry(v_match.side_a_entry_id, true);
    update public.courts set handover_calls_left = 0 where id = v_match.court_id;
    perform public.start_handover(v_match.court_id);

  else
    -- Devolveu a quadra antes da hora, abandonou, ou não havia ninguém
    -- atrás. Quem devolve escolheu parar, então não volta para o fim da
    -- fila; e o próximo não estava esperando a chamada, então continua
    -- sendo chamado com a tolerância e entrando pelo check-in (ou pelo
    -- JOGAR, que faz o mesmo).
    update public.courts set handover_calls_left = 0 where id = v_match.court_id;
    perform public.call_next_team(v_match.court_id);
  end if;

  return public.match_state(p_match_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 9. Chamar o próximo pela regra antiga — só onde não há chamada
--
-- Com a chamada do turno aberta, quem manda é ela: o relógio é o da
-- quadra e quem não responde desce na fila. call_next_team continua
-- para o primeiro turno de uma fila, em que ninguém foi chamado por
-- nada e a tolerância existe para a quadra não travar.
-- ---------------------------------------------------------------------
create or replace function public.call_next_team(p_court_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court    public.courts%rowtype;
  v_next     public.queue_entries%rowtype;
  v_behind   boolean;
  v_deadline timestamptz;
  v_host     uuid;
begin
  select * into v_court from public.courts c where c.id = p_court_id;
  if not found then
    return null;
  end if;

  -- Só chama se a quadra estiver livre.
  if exists (select 1 from public.matches mt
             where mt.court_id = p_court_id and mt.ended_at is null) then
    return null;
  end if;

  -- Chamada do turno em andamento: não há o que fazer aqui.
  if v_court.handover_phase is not null and v_court.handover_until > now() then
    return v_court.handover_entry_id;
  end if;

  select e.* into v_next
  from public.queue_positions qp
  join public.queue_entries e on e.id = qp.entry_id
  where qp.court_id = p_court_id
  order by qp.position
  limit 1;

  if v_next.id is null then
    return null;
  end if;

  -- Tem alguém esperando atrás? É isso que faz o relógio existir.
  v_behind := exists (
    select 1 from public.queue_positions qp
    where qp.court_id = p_court_id and qp.entry_id <> v_next.id
  );

  v_deadline := case
                  -- Vaga sem app nunca teve prazo: quem marca é o anfitrião.
                  when v_next.is_offline then null
                  -- Sozinho na fila: monta o grupo sem relógio correndo.
                  when not v_behind     then null
                  else now() + make_interval(secs => v_court.call_window_seconds)
                end;

  if v_next.status = 'waiting' then
    update public.queue_entries
       set status          = 'ready',
           called_at       = coalesce(called_at, now()),
           call_expires_at = v_deadline
     where id = v_next.id and status = 'waiting';

    if found and v_next.is_offline then
      v_host := public.effective_host(p_court_id);
      if v_host is not null then
        perform public.enqueue_user_notification(
          v_host, p_court_id, 'host_offline_called',
          'Vez do grupo sem app',
          format('%s pode entrar na %s. Marque no app quando entrarem.',
                 coalesce(v_next.offline_label, 'O grupo sem app'),
                 public.court_label(v_court.court_number)),
          jsonb_build_object('court_id', p_court_id, 'entry_id', v_next.id)
        );
      end if;
    end if;

  elsif v_next.status = 'ready'
        and v_next.call_expires_at is null
        and v_deadline is not null then
    update public.queue_entries
       set call_expires_at = v_deadline
     where id = v_next.id and status = 'ready' and call_expires_at is null;
  end if;

  return v_next.id;
end;
$$;

revoke all on function public.call_next_team(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 10. Abrir o turno — limpando a chamada
-- ---------------------------------------------------------------------
create or replace function public.open_match(p_entry_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry    public.queue_entries%rowtype;
  v_court    public.courts%rowtype;
  v_first    uuid;
  v_live     public.matches%rowtype;
  v_match_id uuid;
begin
  select * into v_entry from public.queue_entries e where e.id = p_entry_id for update;
  if not found then
    raise exception 'Grupo não encontrado' using errcode = 'NQ007';
  end if;
  if v_entry.status not in ('waiting', 'ready') then
    raise exception 'Este grupo não pode iniciar o turno agora' using errcode = 'NQ009';
  end if;

  select * into v_court from public.courts c where c.id = v_entry.court_id;
  if not v_court.is_active or v_court.status = 'unavailable' then
    raise exception 'Esta quadra está indisponível no momento' using errcode = 'NQ003';
  end if;

  -- O turno anterior já venceu? Encerra agora — é isso que roda a fila
  -- e abre a chamada.
  select * into v_live
  from public.matches mt
  where mt.court_id = v_court.id and mt.ended_at is null
  for update;

  if found then
    if v_live.expires_at > now() then
      raise exception 'A quadra está ocupada por mais % minuto(s)',
        greatest(1, ceil(extract(epoch from (v_live.expires_at - now())) / 60)::integer)
        using errcode = 'NQ017';
    end if;
    perform public.close_match(v_live.id, null, 'slot_expired');
  end if;

  -- Só agora dá para saber de quem é a vez: o encerramento acima pode
  -- ter mandado o grupo que jogava para o fim da fila.
  select qp.entry_id into v_first
  from public.queue_positions qp
  where qp.court_id = v_court.id
  order by qp.position
  limit 1;

  if v_first is distinct from v_entry.id then
    raise exception 'Ainda não é a vez do seu grupo' using errcode = 'NQ015';
  end if;

  insert into public.matches
    (court_id, side_a_entry_id, side_b_entry_id, mode, slot_minutes, expires_at)
  values
    (v_court.id, v_entry.id, null, v_entry.mode, v_court.slot_minutes,
     now() + make_interval(mins => v_court.slot_minutes))
  returning id into v_match_id;

  update public.queue_entries
     set status = 'playing', called_at = coalesce(called_at, now()), started_at = now()
   where id = v_entry.id;

  -- Começou o turno: a chamada acabou, e a volta da fila recomeça do
  -- zero na próxima.
  update public.courts
     set status = 'in_game', holder_entry_id = null,
         handover_phase = null, handover_entry_id = null, handover_until = null,
         handover_calls_left = 0
   where id = v_court.id;

  return public.match_state(v_match_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 11. Andar a quadra: a chamada vence, desce a fila; a entrada vence,
--     começa o turno
-- ---------------------------------------------------------------------
create or replace function public.advance_court(p_court_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court   public.courts%rowtype;
  v_match   record;
  v_entry   record;
  v_closed  integer := 0;
  v_expired integer := 0;
  v_started integer := 0;
  v_skipped integer := 0;
begin
  for v_match in
    select id from public.matches
    where court_id = p_court_id and ended_at is null and expires_at <= now()
  loop
    perform public.close_match(v_match.id, null, 'slot_expired');
    v_closed := v_closed + 1;
  end loop;

  select * into v_court from public.courts c where c.id = p_court_id;

  if found and v_court.handover_phase is not null and v_court.handover_until <= now() then
    if v_court.handover_phase = 'changeover' then
      -- Quadra sem tablet: o turno do próximo começa sozinho, como na
      -- Sprint 6. Quem está na fila não precisa fazer nada.
      if v_court.is_active
         and v_court.status <> 'unavailable'
         and not exists (select 1 from public.matches mt
                         where mt.court_id = p_court_id and mt.ended_at is null) then
        perform public.open_match(v_court.handover_entry_id);
        v_started := 1;
      else
        update public.courts
           set handover_phase = null, handover_entry_id = null, handover_until = null
         where id = p_court_id;
      end if;

    elsif v_court.handover_phase = 'calling' then
      -- Ninguém apertou JOGAR: este grupo vai para o fim e a chamada
      -- desce. Uma por vez, mesmo que o cron tenha atrasado: cada grupo
      -- merece os 15 segundos inteiros de chamada.
      perform public.skip_handover(p_court_id);
      v_skipped := 1;

    elsif v_court.handover_phase = 'entering' then
      -- Aceitaram e os segundos de entrada acabaram: o tempo de quadra
      -- começa agora, como o Pedro pediu.
      if v_court.is_active
         and v_court.status <> 'unavailable'
         and not exists (select 1 from public.matches mt
                         where mt.court_id = p_court_id and mt.ended_at is null) then
        perform public.open_match(v_court.handover_entry_id);
        v_started := 1;
      else
        update public.courts
           set handover_phase = null, handover_entry_id = null, handover_until = null
         where id = p_court_id;
      end if;
    end if;
  end if;

  -- Chamada não atendida pela regra antiga: só sobrou para o primeiro
  -- turno de uma fila, o único que ainda depende do check-in.
  for v_entry in
    select e.id
    from public.queue_entries e
    where e.court_id = p_court_id
      and e.status = 'ready'
      and e.call_expires_at is not null
      and e.call_expires_at <= now()
    order by e.queue_number
  loop
    update public.queue_entries
       set status = 'expired', cancel_reason = 'no_show', left_at = now()
     where id = v_entry.id and status = 'ready';

    update public.queue_join_requests
       set status = 'expired', decided_at = now()
     where status = 'pending' and entry_id = v_entry.id;

    perform public.call_next_team(p_court_id);
    v_expired := v_expired + 1;
  end loop;

  return jsonb_build_object('matches_closed', v_closed,
                            'entries_expired', v_expired,
                            'calls_skipped', v_skipped,
                            'turns_started', v_started);
end;
$$;

revoke all on function public.advance_court(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 12. O cron acorda para a chamada também
-- ---------------------------------------------------------------------
create or replace function public.advance_expired_queues()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court    record;
  v_result   jsonb;
  v_closed   integer := 0;
  v_expired  integer := 0;
  v_started  integer := 0;
  v_skipped  integer := 0;
  v_requests integer;
  v_sessions integer;
begin
  for v_court in
    select distinct court_id from (
      select court_id from public.matches
      where ended_at is null and expires_at <= now()
      union all
      select court_id from public.queue_entries
      where status = 'ready' and call_expires_at is not null and call_expires_at <= now()
      union all
      select id as court_id from public.courts
      where handover_until is not null and handover_until <= now()
    ) s
  loop
    v_result  := public.advance_court(v_court.court_id);
    v_closed  := v_closed  + (v_result ->> 'matches_closed')::integer;
    v_expired := v_expired + (v_result ->> 'entries_expired')::integer;
    v_started := v_started + (v_result ->> 'turns_started')::integer;
    v_skipped := v_skipped + (v_result ->> 'calls_skipped')::integer;
  end loop;

  update public.queue_join_requests r
     set status = 'expired', decided_at = now()
   where r.status = 'pending'
     and (r.expires_at <= now()
          or not exists (select 1 from public.queue_entries e
                         where e.id = r.entry_id
                           and e.status in ('waiting', 'ready', 'playing')));
  get diagnostics v_requests = row_count;

  v_sessions := public.close_idle_host_sessions();

  return jsonb_build_object(
    'matches_closed',   v_closed,
    'entries_expired',  v_expired,
    'calls_skipped',    v_skipped,
    'turns_started',    v_started,
    'requests_expired', v_requests,
    'sessions_closed',  v_sessions,
    'ran_at', now()
  );
end;
$$;

revoke all on function public.advance_expired_queues() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 13. O empurrão de quem está com a tela aberta
--
-- Com chamadas de 15 segundos, esperar o cron de minuto em minuto não
-- serve mais: a chamada precisa descer a fila na hora. Quem está com a
-- tela aberta (o tablet, acima de todos) fecha essa diferença. A função
-- continua só executando o que JÁ venceu.
-- ---------------------------------------------------------------------
create or replace function public.nudge_court(p_court_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_due boolean;
begin
  select exists (
           select 1 from public.courts c
           where c.id = p_court_id
             and c.handover_until is not null
             and c.handover_until <= now()
         )
      or exists (
           select 1 from public.matches mt
           where mt.court_id = p_court_id
             and mt.ended_at is null
             and mt.expires_at <= now()
         )
      or exists (
           select 1 from public.queue_entries e
           where e.court_id = p_court_id
             and e.status = 'ready'
             and e.call_expires_at is not null
             and e.call_expires_at <= now()
         )
    into v_due;

  if v_due then
    perform public.advance_court(p_court_id);
  end if;

  return public.court_screen(p_court_id);
end;
$$;

revoke all on function public.nudge_court(uuid) from public, anon, authenticated;
grant execute on function public.nudge_court(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 14. A fila na tela: a chamada, os nomes a falar e a espera
-- ---------------------------------------------------------------------
create or replace function public.court_queue_items(p_court_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with court as (
    select c.id, c.slot_minutes,
           c.handover_call_seconds, c.handover_entry_seconds,
           c.handover_phase, c.handover_until,
           case when public.court_tablet_awake(c.id)
                then c.handover_call_seconds + c.handover_entry_seconds
                else c.changeover_seconds
           end as handover_cost,
           (select count(*) from public.matches mt
             where mt.court_id = c.id and mt.ended_at is null) as live,
           (select greatest(0, floor(extract(epoch from (mt.expires_at - now())))::integer)
              from public.matches mt
             where mt.court_id = c.id and mt.ended_at is null
             limit 1) as remaining
    from public.courts c where c.id = p_court_id
  ),
  gap as (
    -- Quanto falta para o primeiro da fila estar em quadra: o resto do
    -- turno mais o que a troca de turno custa nesta quadra — chamada +
    -- entrada onde há tablet, a troca automática onde não há.
    select case
             when live > 0 then coalesce(remaining, 0) + handover_cost
             when handover_phase = 'calling' and handover_until > now()
               then greatest(0, ceil(extract(epoch from (handover_until - now())))::integer)
                    + handover_entry_seconds
             when handover_phase is not null and handover_until > now()
               then greatest(0, ceil(extract(epoch from (handover_until - now())))::integer)
             else 0
           end as to_head,
           slot_minutes * 60 + handover_cost as per_turn
    from court
  ),
  q as (
    select qp.entry_id, qp.position, qp.status, e.first_joined_at as joined_at,
           e.call_expires_at, e.is_offline, e.offline_label, e.turn_number,
           coalesce(
             (select jsonb_build_object(
                       'frame', pr.racket_frame_color,
                       'grip',  pr.racket_grip_color)
                from public.queue_entry_members mm
                join public.profiles pr on pr.id = mm.user_id
               where mm.entry_id = qp.entry_id and mm.is_active and mm.role = 'owner'
               limit 1),
             case when e.is_offline
                  then jsonb_build_object('frame', '#9AA39C', 'grip', '#F1ECEF') end
           ) as racket,
           public.match_side_players(qp.entry_id) as players
    from public.queue_positions qp
    join public.queue_entries e on e.id = qp.entry_id
    where qp.court_id = p_court_id
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'entry_id',    q.entry_id,
        'position',    q.position,
        'position_label', q.position || 'º',
        'group_size',  jsonb_array_length(q.players),
        'group_label', case when q.is_offline then 'Sem app'
                            else public.group_label(jsonb_array_length(q.players)) end,
        'mode_label',  case when q.is_offline then 'Sem app'
                            else public.group_label(jsonb_array_length(q.players)) end,
        'status',      q.status,
        'is_called',   q.status = 'ready',
        'is_being_called', q.entry_id = (select handover_entry_id from public.courts
                                          where id = p_court_id),
        'call_expires_at', q.call_expires_at,
        'joined_at',   q.joined_at,
        'turn_number', q.turn_number,
        'teams_ahead', (q.position - 1) + coalesce((select live from court), 0),
        'is_mine',     exists (
                         select 1 from public.queue_entry_members mm
                         where mm.entry_id = q.entry_id and mm.user_id = auth.uid() and mm.is_active
                       ),
        'is_offline',  q.is_offline,
        'offline_label', q.offline_label,
        'racket',      q.racket,
        'players',     q.players,
        'team_label',  case
          when q.is_offline then coalesce(q.offline_label, 'Grupo sem app')
          else (
            select string_agg(pl ->> 'short_name', ' + ' order by ord)
                     || case when jsonb_array_length(q.players) > 2
                             then ' + ' || (jsonb_array_length(q.players) - 2)
                             else '' end
            from jsonb_array_elements(q.players) with ordinality as t(pl, ord)
            where ord <= 2
          )
        end,
        'stack', (
          select coalesce(jsonb_agg(s.racket order by s.position), '[]'::jsonb)
          from (
            select q2.racket, q2.position
            from q q2
            where q2.position <= q.position and q2.racket is not null
            order by q2.position desc
            limit 5
          ) s
        ),
        'stack_more', greatest(q.position - 5, 0),
        'eta_seconds', (select to_head from gap)
                       + (q.position - 1) * (select per_turn from gap)
      )
      order by q.position
    ),
    '[]'::jsonb
  )
  from q;
$$;
grant execute on function public.court_queue_items(uuid) to anon, authenticated;

create or replace function public.court_screen(p_court_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_court   public.courts%rowtype;
  v_park    public.parks%rowtype;
  v_match   uuid;
  v_items   jsonb;
  v_queue   integer;
  v_rem     integer := 0;
  v_mine    jsonb;
  v_state   jsonb;
  v_group   jsonb;
  v_req     jsonb;
  v_live    jsonb;
  v_session public.host_sessions%rowtype;
  v_host_id uuid;
  v_host    jsonb;
  v_phase   text;
  v_left    integer := 0;
  v_next    jsonb;
  v_hand    jsonb;
  v_to_head integer;
  v_per_turn integer;
  v_names   text;
begin
  select * into v_court from public.courts c where c.id = p_court_id;
  if not found then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;

  select * into v_park from public.parks pk where pk.id = v_court.park_id;

  select mt.id,
         greatest(0, floor(extract(epoch from (mt.expires_at - now())))::integer)
  into v_match, v_rem
  from public.matches mt
  where mt.court_id = p_court_id and mt.ended_at is null
  limit 1;

  v_live  := case when v_match is null then null else public.match_state(v_match) end;
  v_items := public.court_queue_items(p_court_id);
  v_queue := jsonb_array_length(v_items);

  -- A chamada do turno. Fica fora do ar enquanto houver partida: uma
  -- chamada aberta com a quadra em jogo é estado impossível, e se
  -- aparecer é bug — a tela não finge que está tudo bem.
  v_phase := case when v_match is null and v_court.handover_until > now()
                  then v_court.handover_phase end;

  if v_phase is not null then
    v_left := greatest(0, ceil(extract(epoch from (v_court.handover_until - now())))::integer);

    select i into v_next from jsonb_array_elements(v_items) i
    where i ->> 'entry_id' = v_court.handover_entry_id::text
    limit 1;

    -- Os nomes como o tablet vai falar: "Ana, Bruno e Carla".
    select case
             when (v_next ->> 'is_offline')::boolean
               then coalesce(v_next ->> 'offline_label', 'grupo sem app')
             else nullif(
               regexp_replace(
                 string_agg(pl ->> 'short_name', ', ' order by ord),
                 ', ([^,]*)$', ' e \\1'),
               '')
           end
    into v_names
    from jsonb_array_elements(coalesce(v_next -> 'players', '[]'::jsonb)) with ordinality as t(pl, ord);

    v_hand := jsonb_build_object(
      'phase',        v_phase,
      'until',        v_court.handover_until,
      'seconds_left', v_left,
      'entry_id',     v_court.handover_entry_id,
      'label',        v_next ->> 'team_label',
      'spoken_names', coalesce(v_names, v_next ->> 'team_label', 'o próximo grupo'),
      'group_size',   coalesce((v_next ->> 'group_size')::integer, 0),
      'is_mine',      coalesce((v_next ->> 'is_mine')::boolean, false),
      'calls_left',   v_court.handover_calls_left,
      'text',         case v_phase
                        when 'calling'    then 'Chamando o próximo grupo'
                        when 'changeover' then 'Troca de grupo — o próximo entra sozinho'
                        else 'Entrando na quadra'
                      end,
      'needs_accept', v_phase = 'calling'
    );
  end if;

  -- O que uma rodada da quadra custa, para as estimativas: o turno mais
  -- a chamada mais a entrada.
  v_per_turn := v_court.slot_minutes * 60
                + case when public.court_tablet_awake(p_court_id)
                       then v_court.handover_call_seconds + v_court.handover_entry_seconds
                       else v_court.changeover_seconds
                  end;
  v_to_head  := case
                  when v_match is not null
                    then coalesce(v_rem, 0)
                         + case when public.court_tablet_awake(p_court_id)
                                then v_court.handover_call_seconds + v_court.handover_entry_seconds
                                else v_court.changeover_seconds
                           end
                  when v_phase = 'calling'  then v_left + v_court.handover_entry_seconds
                  when v_phase is not null  then v_left
                  else 0
                end;

  select i into v_mine
  from jsonb_array_elements(v_items) i
  where (i ->> 'is_mine')::boolean
  limit 1;

  v_state := public.player_state(auth.uid());

  if (v_state ->> 'court_id')::uuid = p_court_id then
    v_group := public.my_group((v_state ->> 'entry_id')::uuid);
  end if;

  v_req := public.my_join_request();
  if (v_req ->> 'court_id')::uuid is distinct from p_court_id then
    v_req := null;
  end if;

  -- A fila com anfitrião: quem organiza e o que quem olha pode fazer.
  if v_court.queue_mode = 'host' then
    select * into v_session
    from public.host_sessions s
    where s.id = public.current_host_session(p_court_id);

    if v_session.id is not null then
      v_host_id := public.effective_host(p_court_id);
      v_host := jsonb_build_object(
        'session_id', v_session.id,
        'opened_at',  v_session.opened_at,
        'host_name',  (select public.short_name_of(coalesce(pr.full_name, pr.username::text))
                         from public.profiles pr where pr.id = v_host_id),
        'is_me',      v_host_id is not null and v_host_id = auth.uid(),
        'can_show_invite', v_group is not null
      );
    end if;
  end if;

  return jsonb_build_object(
    'court', jsonb_build_object(
      'id',            v_court.id,
      'name',          public.court_label(v_court.court_number),
      'number',        v_court.court_number,
      'surface',       v_court.surface,
      'surface_label', case v_court.surface
                         when 'clay'  then 'Saibro'
                         when 'hard'  then 'Rápida'
                         else 'Grama'
                       end,
      'status',        v_court.status,
      'is_active',     v_court.is_active,
      'slot_minutes',  v_court.slot_minutes,
      'call_window_seconds',  v_court.call_window_seconds,
      'handover_call_seconds',  v_court.handover_call_seconds,
      'handover_entry_seconds', v_court.handover_entry_seconds,
      'changeover_seconds',     v_court.changeover_seconds,
      'has_tablet',             public.court_tablet_awake(p_court_id),
      'queue_mode',    v_court.queue_mode,
      'checkin_methods', (
        select coalesce(jsonb_agg(m order by m), '[]'::jsonb)
        from (
          select 'qr'::text as m where v_court.has_qr_code and v_court.queue_mode = 'fixed_qr'
          union all
          select 'nfc'::text where v_court.has_nfc_tag and v_court.queue_mode = 'fixed_qr'
          union all
          select 'gps'::text where v_court.queue_mode = 'host'
        ) s
      ),
      'latitude',      v_court.latitude,
      'longitude',     v_court.longitude,
      'rating_avg',    v_court.rating_avg,
      'rating_count',  v_court.rating_count,
      'cover_photo_path', v_court.cover_photo_path
    ),
    'park', jsonb_build_object(
      'id',       v_park.id,
      'name',     v_park.name,
      'district', v_park.district
    ),
    'match',        v_live,
    'is_live',      v_match is not null,
    'handover',     v_hand,
    'is_handover',  v_phase is not null,
    'status_text',  case
                      when v_match is not null    then 'Em jogo'
                      when v_phase = 'calling'    then 'Chamando o próximo'
                      when v_phase = 'entering'   then 'Entrando na quadra'
                      when v_phase = 'changeover' then 'Troca de grupo'
                      else 'Livre'
                    end,
    'players_line', case
                      when v_phase = 'calling'
                        then coalesce('Chamando: ' || (v_next ->> 'team_label'),
                                      'Chamando o próximo grupo')
                      when v_phase in ('entering', 'changeover')
                        then coalesce('Entrando: ' || (v_next ->> 'team_label'),
                                      'Entrando em quadra')
                      when v_match is null then 'Sem jogo agora — aperte JOGAR para começar'
                      when (v_live ->> 'is_offline')::boolean
                        then coalesce(v_live ->> 'offline_label', 'Grupo sem app')
                      else (
                        select coalesce(string_agg(pl ->> 'short_name', ' · ' order by ord), 'Grupo em quadra')
                        from jsonb_array_elements(v_live -> 'players') with ordinality as t(pl, ord)
                      )
                    end,
    'queue',        v_items,
    'queue_length', v_queue,
    'queue_text',   case
                      when v_queue = 0 then 'Fila vazia'
                      else v_queue || ' na espera'
                    end,
    'remaining_seconds', coalesce(v_rem, 0),
    -- Quem entrar na fila agora espera a quadra liberar mais uma rodada
    -- inteira por grupo à frente — e cada rodada inclui a troca.
    'total_wait_seconds', v_to_head + v_queue * v_per_turn,
    'turn_seconds',       v_per_turn,
    'next_position_label', (v_queue + 1) || 'º',
    'my_entry',     v_mine,
    'my_group',     v_group,
    'my_request',   v_req,
    'host',         v_host,
    'can_open_host', v_court.queue_mode = 'host'
                     and v_host is null
                     and v_court.is_active
                     and v_court.status <> 'unavailable'
                     and (v_state ->> 'state') = 'free',
    'court_accepting', v_court.is_active and v_court.status <> 'unavailable',
    'can_join',     v_court.is_active
                    and v_court.status <> 'unavailable'
                    and (v_state ->> 'state') = 'free'
                    and (v_court.queue_mode = 'fixed_qr' or v_host is not null),
    'my_state',     v_state,
    'generated_at', now()
  );
end;
$$;
grant execute on function public.court_screen(uuid) to anon, authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20261104130000_tablet_da_quadra.sql
-- ####################################################################

-- =====================================================================
-- O tablet da quadra: identidade própria, sem conta de ninguém
--
-- O tablet fica num parque público. Se ele carregasse a conta de admin,
-- quem pegasse o aparelho entraria no painel, editaria quadras e tiraria
-- gente da fila. Então ele não entra como pessoa: entra como APARELHO.
--
--   . o administrador gera um link da quadra, que aparece UMA vez;
--   . o tablet abre esse link e fica nele;
--   . com esse link dá para fazer exatamente duas coisas: ver a quadra
--     e apertar JOGAR por quem está sendo chamado.
--
-- Nada de perfil, nada de /admin, nada de entrar na fila por alguém.
-- Perdeu o tablet? Revoga o link e pronto; nenhuma conta foi exposta.
--
-- Por que o link pode aceitar a vez de um grupo: a prova de presença
-- aqui é o aparelho estar na quadra, igual à do QR impresso. Quem tem o
-- link e está longe pode, no máximo, começar o turno de quem já era o
-- próximo da fila — não pula a vez de ninguém, não entra na fila, não
-- remove ninguém. É um estrago pequeno, e revogável num clique.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. A tela do tablet
--
-- Volatile de propósito: cada leitura marca que o aparelho está vivo, e
-- é esse sinal que decide se a quadra chama os nomes ou volta para a
-- troca automática. Também executa o que já venceu — com chamadas de 15
-- segundos, esperar o cron de minuto em minuto não serve.
-- ---------------------------------------------------------------------
create or replace function public.tablet_screen(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_device public.court_devices%rowtype;
  v_screen jsonb;
begin
  select * into v_device
  from public.court_devices d
  where d.token_hash = public.hash_scan_token(p_token)
    and d.revoked_at is null;

  if not found then
    raise exception 'Este tablet não está mais ligado a uma quadra. Peça um link novo.'
      using errcode = 'NQ037';
  end if;

  update public.court_devices set last_seen_at = now() where id = v_device.id;

  v_screen := public.nudge_court(v_device.court_id);

  return v_screen || jsonb_build_object(
    'device', jsonb_build_object(
      'id',    v_device.id,
      'label', v_device.label
    )
  );
end;
$$;

revoke all on function public.tablet_screen(text) from public, anon, authenticated;
grant execute on function public.tablet_screen(text) to anon, authenticated;

comment on function public.tablet_screen(text) is
  'A tela da quadra para o tablet, pelo token do aparelho. Marca o aparelho como '
  'vivo e executa o que já venceu (turno, chamada, entrada).';

-- ---------------------------------------------------------------------
-- 2. O JOGAR do tablet
--
-- Basta uma pessoa apertar, e no tablet não há "pessoa": quem aperta é
-- quem está na quadra. O aceite vale para o grupo que está sendo
-- chamado — nunca para outro, porque a função nem recebe qual grupo é.
-- ---------------------------------------------------------------------
create or replace function public.tablet_accept_turn(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_device public.court_devices%rowtype;
begin
  select * into v_device
  from public.court_devices d
  where d.token_hash = public.hash_scan_token(p_token)
    and d.revoked_at is null;

  if not found then
    raise exception 'Este tablet não está mais ligado a uma quadra. Peça um link novo.'
      using errcode = 'NQ037';
  end if;

  update public.court_devices set last_seen_at = now() where id = v_device.id;

  -- p_user_id nulo: foi o tablet, não uma pessoa com conta. Fica
  -- registrado assim mesmo em accepted_at.
  return public.accept_handover(v_device.court_id, null)
         || jsonb_build_object('device', jsonb_build_object('id', v_device.id,
                                                            'label', v_device.label));
end;
$$;

revoke all on function public.tablet_accept_turn(text) from public, anon, authenticated;
grant execute on function public.tablet_accept_turn(text) to anon, authenticated;

comment on function public.tablet_accept_turn(text) is
  'O botão JOGAR do tablet: aceita a vez do grupo que está sendo chamado naquela quadra.';

-- ---------------------------------------------------------------------
-- 3. Administração: gerar, listar e revogar o link
--
-- O token aparece UMA vez, na resposta de quem o criou. Depois só fica
-- o hash — perdeu o link, gera outro e revoga o antigo. É a mesma regra
-- do segredo do QR, pelo mesmo motivo: o que o banco não guarda não
-- vaza.
-- ---------------------------------------------------------------------
create or replace function public.admin_create_court_device(
  p_court_id uuid,
  p_label    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token text;
  v_id    uuid;
  v_label text := nullif(trim(coalesce(p_label, '')), '');
begin
  perform public.require_admin();

  if not exists (select 1 from public.courts c where c.id = p_court_id) then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;

  if v_label is not null and char_length(v_label) > 60 then
    raise exception 'O nome do aparelho vai até 60 caracteres' using errcode = 'NQ024';
  end if;

  -- 32 bytes de aleatório em hex: o mesmo tamanho dos tokens de scan.
  v_token := encode(extensions.gen_random_bytes(32), 'hex');

  insert into public.court_devices (court_id, label, token_hash, created_by)
  values (p_court_id, v_label, public.hash_scan_token(v_token), auth.uid())
  returning id into v_id;

  return jsonb_build_object(
    'device_id', v_id,
    'court_id',  p_court_id,
    'label',     v_label,
    -- Única vez que este valor existe fora do tablet.
    'token',     v_token,
    'path',      '/tablet/' || v_token
  );
end;
$$;

revoke all on function public.admin_create_court_device(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_create_court_device(uuid, text) to authenticated;

create or replace function public.admin_court_devices(p_court_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.require_admin();

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'device_id',    d.id,
             'court_id',     d.court_id,
             'court_label',  public.court_label(c.court_number),
             'park_name',    pk.name,
             'label',        d.label,
             'created_at',   d.created_at,
             'last_seen_at', d.last_seen_at,
             'awake',        d.last_seen_at > now() - interval '2 minutes',
             'revoked_at',   d.revoked_at
           ) order by pk.name, c.court_number, d.created_at)
    from public.court_devices d
    join public.courts c on c.id = d.court_id
    join public.parks pk on pk.id = c.park_id
    where (p_court_id is null or d.court_id = p_court_id)
      and d.revoked_at is null
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.admin_court_devices(uuid) from public, anon, authenticated;
grant execute on function public.admin_court_devices(uuid) to authenticated;

create or replace function public.admin_revoke_court_device(p_device_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court uuid;
begin
  perform public.require_admin();

  update public.court_devices
     set revoked_at = now()
   where id = p_device_id and revoked_at is null
  returning court_id into v_court;

  if v_court is null then
    raise exception 'Aparelho não encontrado' using errcode = 'NQ003';
  end if;

  return jsonb_build_object('device_id', p_device_id, 'revoked', true, 'court_id', v_court);
end;
$$;

revoke all on function public.admin_revoke_court_device(uuid) from public, anon, authenticated;
grant execute on function public.admin_revoke_court_device(uuid) to authenticated;


-- ####################################################################
-- Origem: supabase/migrations/20261104140000_auditoria_seguranca.sql
-- ####################################################################

-- =====================================================================
-- Auditoria de segurança: fechando o que estava aberto no banco
--
-- Uma auditoria estática do repositório apontou três furos exploráveis
-- de autorização e um bug funcional que trava quadra. Os quatro foram
-- reproduzidos num Postgres descartável antes desta migration existir,
-- e é isso que cada bloco aqui fecha.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. profiles: o cliente escrevia a linha inteira, inclusive o e-mail
--
-- O grant era `select, update on public.profiles` — tabela inteira, sem
-- lista de colunas — e a policy do dono só protegia o papel:
--
--     with check (id = auth.uid() and role = public.current_app_role())
--
-- Reproduzido: qualquer conta logada gravava
-- `email = 'admin@neqst.com'` no PRÓPRIO perfil. A sincronia com
-- auth.users é de mão única, então nada corrigia depois — e isso é
-- metade da escalação do item 2.
--
-- Agora o grant é por coluna. `email`, `username`, `role` e `id` saem da
-- escrita do cliente; `email` e `role` saem também da LEITURA, porque
-- `select email, full_name, role from profiles` entregava a base inteira
-- com um "qual conta é admin" de brinde.
--
-- O app não perde nada: ele nunca leu profiles direto, sempre por RPC
-- (`my_profile_summary`, `admin_users`), e essas são SECURITY DEFINER.
-- ---------------------------------------------------------------------
revoke select, update on public.profiles from authenticated;

grant select (id, username, full_name, avatar_url, created_at,
              avatar_tone, racket_frame_color, racket_grip_color)
  on public.profiles to authenticated;

-- O que a pessoa muda no próprio perfil. username fica de fora de
-- propósito: quem valida o formato e a unicidade é `update_my_profile`.
grant update (full_name, avatar_url, avatar_tone,
              racket_frame_color, racket_grip_color)
  on public.profiles to authenticated;

comment on column public.profiles.email is
  'Espelho de auth.users.email, mantido pelo gatilho. Fora do alcance do '
  'cliente: nem leitura nem escrita. Quem decide quem é quem é auth.users.';

-- ---------------------------------------------------------------------
-- 2. promote_to_admin resolvia o alvo por um e-mail forjável
--
-- A busca era em `public.profiles`, coluna com índice NÃO único, com
-- `select ... into` — que com duas linhas não levanta erro: pega uma e
-- segue. Somado ao item 1, o ataque era: gravo o e-mail do admin no meu
-- perfil, e o operador que roda `promote_to_admin('admin@…')` no SQL
-- Editor promove, na melhor das hipóteses, uma linha ao acaso.
--
-- Medido: na reprodução o Postgres escolheu o admin de verdade, não o
-- atacante — a ordem das linhas decide. Ou seja, não é um exploit
-- determinístico; é um sorteio. Um sorteio para dar admin a um
-- desconhecido é tão inaceitável quanto a certeza.
--
-- Duas correções, e a primeira já basta sozinha:
--
--   . o alvo passa a ser resolvido em `auth.users`, que o cliente não
--     escreve e onde o e-mail é único de verdade;
--   . mais de uma linha agora é erro, nunca uma escolha silenciosa.
--
-- E quem quiser certeza absoluta usa `promote_to_admin_by_id(uuid)`,
-- com o id copiado de Authentication > Users. Nome diferente de
-- propósito: duas funções `promote_to_admin` com um argumento cada
-- deixariam a chamada ambígua ("is not unique"), que foi exatamente o
-- erro que travou o deploy no PR #14.
-- ---------------------------------------------------------------------
create or replace function public.promote_to_admin_by_id(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current uuid;
begin
  if p_user_id is null then
    raise exception 'Informe o id do usuário (Authentication > Users).'
      using errcode = 'NQ021';
  end if;

  if not exists (select 1 from auth.users u where u.id = p_user_id) then
    raise exception 'Nenhum usuário com o id %.', p_user_id using errcode = 'NQ021';
  end if;

  -- Um admin por vez, e a troca continua sendo um ato deliberado: a
  -- função recusa em vez de rebaixar o admin atual sozinha. Um erro de
  -- digitação aqui transferiria a administração em silêncio.
  select p.id into v_current
  from public.profiles p where p.role = 'admin'::public.app_role;

  if v_current is not null and v_current <> p_user_id then
    raise exception 'Já existe um admin. Rebaixe-o antes: update public.profiles set role = ''player'' where id = ''%'';', v_current
      using errcode = 'NQ022';
  end if;

  update public.profiles set role = 'admin'::public.app_role where id = p_user_id;

  if not found then
    raise exception 'Nenhum perfil para o id %. O gatilho de criação de perfil pode não ter rodado.', p_user_id
      using errcode = 'NQ021';
  end if;

  return jsonb_build_object('user_id', p_user_id, 'role', 'admin');
end;
$$;

revoke all on function public.promote_to_admin_by_id(uuid) from public, anon, authenticated;

comment on function public.promote_to_admin_by_id(uuid) is
  'Promove a admin pelo id do usuário. É a forma sem ambiguidade: copie o id '
  'em Authentication > Users. Só pelo SQL Editor.';

create or replace function public.promote_to_admin(p_email text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id    uuid;
  v_count integer;
  v_email text := lower(trim(coalesce(p_email, '')));
begin
  if v_email = '' then
    raise exception 'Informe o e-mail da conta.' using errcode = 'NQ021';
  end if;

  -- auth.users, não profiles: aquele e-mail o cliente não escreve.
  select count(*)::integer into v_count
  from auth.users u where lower(u.email) = v_email;

  if v_count = 0 then
    raise exception 'Nenhuma conta com o e-mail %. Crie o usuário em Authentication > Users primeiro.', p_email
      using errcode = 'NQ021';
  end if;

  if v_count > 1 then
    raise exception 'Há % contas com o e-mail %. Use promote_to_admin_by_id(<uuid>) com o id de Authentication > Users.',
      v_count, p_email
      using errcode = 'NQ021';
  end if;

  select u.id into v_id from auth.users u where lower(u.email) = v_email;

  return public.promote_to_admin_by_id(v_id) || jsonb_build_object('email', p_email);
end;
$$;

revoke all on function public.promote_to_admin(text) from public, anon, authenticated;

comment on function public.promote_to_admin(text) is
  'Promove a admin pelo e-mail da CONTA (auth.users), não pelo e-mail do perfil. '
  'Mais de uma conta com o mesmo e-mail é erro, nunca uma escolha ao acaso.';

-- ---------------------------------------------------------------------
-- 3. expire_stale_queue_entries expulsava quem só esperou — e travava
--    a quadra
--
-- Era isto:
--
--     where status in ('waiting','ready') and joined_at < now() - '3 hours'
--
-- Dois defeitos, ambos reproduzidos:
--
--   . esperar 3 horas numa fila movimentada é o comportamento NORMAL de
--     uma fila movimentada — é o cenário que o app existe para
--     gerenciar. E desde a rotação automática `joined_at` renasce a cada
--     turno (é por isso que `first_joined_at` existe), então a função
--     ficou medindo a coisa errada de duas formas ao mesmo tempo.
--
--   . era a ÚNICA função que mudava status de fila sem chamar
--     `call_next_team`. Expirar um grupo em `ready` deixava a quadra
--     `available` com gente em `waiting` e zero partidas: ninguém
--     destravava, porque `nudge_court` só age sobre o que já venceu, e
--     nada estava vencido. A quadra ficava inutilizável.
--
-- Agora a regra é ausência de SINAL, não tempo de espera: só sai quem
-- nunca foi chamado e não se mexeu desde que chegou. Quem está na fila
-- esperando a vez chegar tem sinal — o grupo da frente jogando é sinal.
-- ---------------------------------------------------------------------
create or replace function public.expire_stale_queue_entries(p_max_wait interval default '3 hours')
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count  integer := 0;
  v_courts uuid[];
  v_court  uuid;
begin
  -- Sai quem nunca foi chamado, não se mexeu desde que chegou, e está
  -- numa quadra PARADA. Alguém jogando é sinal de fila viva: ali quem
  -- espera está esperando certo, não abandonado.
  with expirados as (
    update public.queue_entries e
       set status = 'expired', cancel_reason = 'expired_by_system', left_at = now()
     where e.status in ('waiting', 'ready')
       and e.first_joined_at < now() - p_max_wait
       and e.called_at is null
       and not exists (
         select 1 from public.matches mt
         where mt.court_id = e.court_id and mt.ended_at is null
       )
    returning e.court_id
  )
  select coalesce(array_agg(distinct court_id), '{}'::uuid[]), count(*)::integer
  into v_courts, v_count
  from expirados;

  -- E a fila anda. Sem isto a quadra ficava `available` com gente em
  -- `waiting` e ninguém para destravar: era a única função que mexia em
  -- status de fila sem chamar o próximo.
  foreach v_court in array v_courts loop
    perform public.call_next_team(v_court);
  end loop;

  return v_count;
end;
$$;

revoke all on function public.expire_stale_queue_entries(interval) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Nome completo e presença em tempo real sem login (LGPD)
--
-- `court_queue` roda sem JWT e `court_queue_items`, `court_screen`,
-- `queue_entry_players` e `match_side_players` têm grant para anon. Com
-- o slug da quadra — que é previsível — qualquer pessoa, sem conta,
-- lia nome completo, posição na fila e horário de todo mundo que está
-- numa quadra pública. Nome completo mais local mais horário é rotina
-- de pessoa identificada.
--
-- O que o anônimo passa a receber é o que a placa da quadra mostraria
-- de qualquer forma: primeiro nome e inicial ("Ana S."), que é o que a
-- fila precisa para você se reconhecer nela — e é o que o tablet fala
-- em voz alta. `full_name`, `username` e `user_id` ficam só para quem
-- está logado.
-- ---------------------------------------------------------------------
create or replace function public.match_side_players(p_entry_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(
      -- `role` e `checked_in` ficam nos dois casos: o placar precisa
      -- deles para desenhar igual, e não dizem quem a pessoa é.
      case
        when auth.uid() is null then
          jsonb_build_object(
            'initials',   public.initials_of(coalesce(p.full_name, p.username::text)),
            'short_name', public.short_name_of(coalesce(p.full_name, p.username::text)),
            'role',       m.role,
            'checked_in', m.checked_in_at is not null
          )
        else
          jsonb_build_object(
            'user_id',    m.user_id,
            'username',   p.username,
            'full_name',  p.full_name,
            'initials',   public.initials_of(coalesce(p.full_name, p.username::text)),
            'short_name', public.short_name_of(coalesce(p.full_name, p.username::text)),
            'role',       m.role,
            'checked_in', m.checked_in_at is not null
          )
      end
      order by m.role, m.created_at
    ),
    '[]'::jsonb
  )
  from public.queue_entry_members m
  join public.queue_entries e on e.id = m.entry_id
  left join public.profiles p on p.id = m.user_id
  where m.entry_id = p_entry_id
    and (m.is_active or e.status not in ('waiting', 'ready', 'playing'));
$$;

grant execute on function public.match_side_players(uuid) to anon, authenticated;

create or replace function public.queue_entry_players(p_entry_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(
      case
        when auth.uid() is null then
          jsonb_build_object(
            'role',       m.role,
            'initials',   public.initials_of(coalesce(p.full_name, p.username::text)),
            'short_name', public.short_name_of(coalesce(p.full_name, p.username::text))
          )
        else
          jsonb_build_object(
            'user_id',    m.user_id,
            'role',       m.role,
            'username',   p.username,
            'full_name',  p.full_name,
            'avatar_url', p.avatar_url,
            'initials',   public.initials_of(coalesce(p.full_name, p.username::text)),
            'short_name', public.short_name_of(coalesce(p.full_name, p.username::text))
          )
      end
      order by m.role, m.created_at
    ),
    '[]'::jsonb
  )
  from public.queue_entry_members m
  join public.queue_entries e on e.id = m.entry_id
  left join public.profiles p on p.id = m.user_id
  where m.entry_id = p_entry_id
    and (m.is_active or e.status not in ('waiting', 'ready', 'playing'));
$$;

grant execute on function public.queue_entry_players(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. 61 funções nasceram executáveis por PUBLIC
--
-- Em Postgres, função nova é executável por PUBLIC. O padrão correto do
-- repositório é `revoke all ... from public` antes do grant, e ele é
-- seguido na maior parte do código — mas numa leva de RPCs o revoke não
-- foi escrito, e ali o grant é decorativo.
--
-- Não havia exploit anônimo: as RPCs sensíveis recusam por dentro
-- (`auth.uid() is null` → NQ001, ou checagem de papel). O risco era
-- arquitetural: a defesa inteira repousava numa checagem manual dentro
-- de cada função, e a próxima que esquecesse já nascia aberta.
--
-- Conferido antes de revogar: nenhuma das 61 depende SÓ do PUBLIC —
-- todas têm grant explícito para authenticated. Então revogar não
-- quebra nada, e o teste de privilégios (tests/local/90) passa a impedir
-- a regressão.
--
-- O laço abaixo é SQL dinâmico, o único do repositório, e é aqui de
-- propósito: ele roda uma vez, numa migration, sobre identificadores
-- vindos do catálogo (`oid::regprocedure`, já citados pelo Postgres).
-- Listar 61 assinaturas à mão envelheceria errado na primeira função
-- nova.
-- ---------------------------------------------------------------------
do $$
declare
  v_fn record;
begin
  for v_fn in
    select p.oid::regprocedure as assinatura
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and has_function_privilege('public', p.oid, 'EXECUTE')
  loop
    execute format('revoke execute on function %s from public', v_fn.assinatura);
  end loop;
end $$;

-- E as próximas nascem fechadas, em vez de depender de alguém lembrar.
alter default privileges in schema public revoke execute on functions from public;

-- ---------------------------------------------------------------------
-- 6. O worker de push reenviava o mesmo aviso
--
-- O `select ... where status = 'pending'` não tinha claim nem lease, e o
-- worker é chamado de 10 em 10 segundos enquanto um lote de 200 leva
-- mais que isso: duas execuções sobrepostas mandavam o mesmo push duas
-- vezes. "É a sua vez!" duplicado na quadra é ruído; e se a escrita de
-- `status = 'sent'` falhar, a linha fica `pending` para sempre e o
-- reenvio não tem fim.
--
-- claimed_at em vez de um valor novo no enum: valor novo de enum não
-- pode ser usado na mesma transação que o criou, o que custaria duas
-- migrations por uma coluna que resolve igual.
-- ---------------------------------------------------------------------
alter table public.notification_outbox
  add column if not exists claimed_at timestamptz;

comment on column public.notification_outbox.claimed_at is
  'Quando um worker pegou esta linha. Outro worker só pega de novo depois de '
  '2 minutos — o bastante para o primeiro ter morrido no meio.';

create index if not exists notification_outbox_claim_idx
  on public.notification_outbox (claimed_at)
  where status = 'pending';

create or replace function public.claim_notifications(
  p_limit        integer default 200,
  p_max_attempts integer default 5
)
returns setof public.notification_outbox
language sql
volatile
security definer
set search_path = ''
as $$
  update public.notification_outbox o
     set claimed_at = now()
   where o.id in (
     select c.id
     from public.notification_outbox c
     where c.status = 'pending'
       -- Os mesmos filtros que o worker fazia na mão, agora de um lado
       -- só: aviso agendado para o futuro não sai antes da hora, e o
       -- que já falhou cinco vezes para de ser tentado.
       and c.scheduled_for <= now()
       and c.attempts < coalesce(p_max_attempts, 5)
       and (c.claimed_at is null or c.claimed_at < now() - interval '2 minutes')
     order by c.scheduled_for
     -- É isto que faz dois workers sobrepostos pegarem lotes
     -- diferentes em vez do mesmo.
     for update skip locked
     limit greatest(1, least(coalesce(p_limit, 200), 500))
   )
  returning o.*;
$$;

revoke all on function public.claim_notifications(integer, integer) from public, anon, authenticated;

comment on function public.claim_notifications(integer, integer) is
  'Pega um lote de notificações pendentes para um worker, marcando o claim. '
  'Dois workers ao mesmo tempo levam lotes diferentes (for update skip locked).';

-- ---------------------------------------------------------------------
-- 7. Rotação do segredo do QR com lost update
--
-- A Edge Function fazia read-modify-write: lia `qr_secret_version`,
-- somava 1 e gravava. Dois POSTs concorrentes liam v1 e gravavam v2 — e
-- o segundo administrador achava que havia invalidado o QR impresso do
-- primeiro sem ter invalidado nada.
--
-- Invalidar papel já colado na quadra é irreversível: tem de ser
-- atômico. Aqui o incremento é feito pelo banco e devolve a versão que
-- de fato vale.
-- ---------------------------------------------------------------------
create or replace function public.rotate_court_qr_secret(p_court_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_version integer;
begin
  perform public.require_admin();

  update public.courts
     set qr_secret_version = qr_secret_version + 1,
         qr_rotated_at     = now()
   where id = p_court_id
  returning qr_secret_version into v_version;

  if v_version is null then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;

  return v_version;
end;
$$;

revoke all on function public.rotate_court_qr_secret(uuid) from public, anon, authenticated;
grant execute on function public.rotate_court_qr_secret(uuid) to authenticated;

comment on function public.rotate_court_qr_secret(uuid) is
  'Incrementa a versão do segredo do QR da quadra de forma atômica e devolve a '
  'versão nova. Invalidar QR impresso é irreversível: não pode ter lost update.';
