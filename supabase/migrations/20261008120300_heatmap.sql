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
