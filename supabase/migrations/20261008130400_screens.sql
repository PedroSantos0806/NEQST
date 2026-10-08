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
