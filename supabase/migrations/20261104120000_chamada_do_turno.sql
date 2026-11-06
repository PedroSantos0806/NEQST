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
