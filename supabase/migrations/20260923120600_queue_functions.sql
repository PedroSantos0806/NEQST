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
