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
