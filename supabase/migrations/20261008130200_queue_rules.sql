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
