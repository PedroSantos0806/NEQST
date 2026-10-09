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
