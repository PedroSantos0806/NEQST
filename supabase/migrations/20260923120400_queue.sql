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
