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
