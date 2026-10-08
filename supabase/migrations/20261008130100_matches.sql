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
