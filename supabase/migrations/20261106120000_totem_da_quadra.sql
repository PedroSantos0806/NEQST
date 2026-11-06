-- ---------------------------------------------------------------------
-- Sprint 8 — O totem da quadra: fila por party, sem conta
--
-- Handoff do mock (Gabriel Crespi, 05/11/2026) + a decisão do Pedro:
-- não existe mais conta de jogador. A pessoa digita nome e sobrenome e
-- entra na fila, pelo totem da quadra ou pelo QR/NFC no celular. Os
-- dois caminhos escrevem na MESMA fila.
--
-- O que isto troca do que existia:
--
--   • A fila era por pessoa com conta (queue_entries.created_by era
--     obrigatório e apontava para auth.users). Passa a ser por PARTY:
--     um nome em texto livre e uma quantidade de pessoas.
--   • A chamada de 15 segundos pelo nome, com os 30 segundos de
--     entrada, sai. No lugar entra a máquina do handoff: troca de 1:30
--     e a pergunta de saída para quem acabou de jogar.
--   • Entram as pausas de manutenção (vassourão, rega, exceção), que
--     não têm duração: ficam abertas até alguém apertar Retomar.
--
-- Quem autoriza a escrita, agora que não há login:
--
--   • o totem, pelo token do aparelho (court_devices, já em hash);
--   • o QR/NFC, pelo scan token, que prova posse do código impresso;
--   • a própria party, por um party token guardado no navegador de quem
--     entrou — é o que deixa a pessoa sair da fila pelo celular.
--
-- Nenhum caminho de jogador usa auth.uid(). O painel de admin continua
-- exigindo conta, que é o único lugar onde conta faz sentido.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- 1. A party na fila
-- ---------------------------------------------------------------------
alter table public.queue_entries
  add column if not exists party_name       text,
  add column if not exists party_size       smallint,
  add column if not exists party_token_hash text,
  add column if not exists source           text;

-- A conta deixa de ser obrigatória. As vagas antigas continuam com a
-- sua: ninguém precisa reescrever o histórico para o totem funcionar.
alter table public.queue_entries alter column created_by drop not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'queue_entries_party_name_len') then
    alter table public.queue_entries
      add constraint queue_entries_party_name_len
        check (party_name is null or char_length(btrim(party_name)) between 2 and 40);
  end if;

  if not exists (select 1 from pg_constraint where conname = 'queue_entries_party_size_range') then
    -- Teto de 20 como no mock: não existe limite real de party, o número
    -- grande só evita dedo preso no contador.
    alter table public.queue_entries
      add constraint queue_entries_party_size_range
        check (party_size is null or party_size between 1 and 20);
  end if;

  if not exists (select 1 from pg_constraint where conname = 'queue_entries_has_identity') then
    -- Toda vaga diz quem é de alguma forma: uma conta (as antigas) ou um
    -- nome digitado (as do totem e do QR).
    alter table public.queue_entries
      add constraint queue_entries_has_identity
        check (created_by is not null or party_name is not null);
  end if;

  if not exists (select 1 from pg_constraint where conname = 'queue_entries_source_check') then
    alter table public.queue_entries
      add constraint queue_entries_source_check
        check (source is null or source in ('totem', 'qr', 'nfc', 'app'));
  end if;
end $$;

create unique index if not exists queue_entries_party_token_idx
  on public.queue_entries (party_token_hash)
  where party_token_hash is not null;

comment on column public.queue_entries.party_name is
  'Nome digitado por quem entrou na fila. Sem conta, é tudo o que identifica a '
  'party — e de propósito: duas "Marina" em dias diferentes não têm relação.';
comment on column public.queue_entries.party_size is
  'Quantas pessoas vão jogar. Um grupo de 6 joga os mesmos minutos de quadra e '
  'reveza entre si lá dentro.';
comment on column public.queue_entries.party_token_hash is
  'Segredo devolvido UMA vez a quem entrou pelo QR, guardado no navegador dele. '
  'É o que autoriza sair da fila e responder a pergunta de saída pelo celular.';
comment on column public.queue_entries.source is
  'Por onde esta party entrou: totem, qr, nfc ou app (as vagas com conta).';

-- ---------------------------------------------------------------------
-- 2. As constantes e o estado da quadra, como no handoff
--
-- Cinco estados: Em jogo, Acabando, Troca 1:30, Pausada e Quadra livre.
-- Todos saem sozinhos pelo relógio, menos Pausada, que só sai por toque
-- humano em Retomar.
-- ---------------------------------------------------------------------
alter table public.courts
  add column if not exists warn_seconds     smallint not null default 60,
  add column if not exists pause_kind       text,
  add column if not exists paused_at        timestamptz,
  add column if not exists armed_pause_kind text,
  add column if not exists exit_ask_entry_id uuid
    references public.queue_entries (id) on delete set null;

-- Troca de 1 minuto e 30, não de 1 minuto: o número é do handoff.
alter table public.courts alter column changeover_seconds set default 90;
update public.courts set changeover_seconds = 90 where changeover_seconds = 60;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'courts_pause_kind_check') then
    alter table public.courts
      add constraint courts_pause_kind_check
        check (pause_kind is null or pause_kind in ('vassourao', 'rega', 'excecao'));
  end if;

  if not exists (select 1 from pg_constraint where conname = 'courts_armed_pause_kind_check') then
    alter table public.courts
      add constraint courts_armed_pause_kind_check
        check (armed_pause_kind is null or armed_pause_kind in ('vassourao', 'rega', 'excecao'));
  end if;

  if not exists (select 1 from pg_constraint where conname = 'courts_paused_at_check') then
    -- Pausa sem hora de início não tem cronômetro para contar para cima.
    alter table public.courts
      add constraint courts_paused_at_check
        check ((pause_kind is null) = (paused_at is null));
  end if;

  if not exists (select 1 from pg_constraint where conname = 'courts_warn_seconds_range') then
    alter table public.courts
      add constraint courts_warn_seconds_range check (warn_seconds between 10 and 600);
  end if;
end $$;

comment on column public.courts.warn_seconds is
  'Quando o placar muda de cor e o texto vira "Acabando, liberem a quadra". '
  'Handoff: 60 segundos.';
comment on column public.courts.pause_kind is
  'Pausa de manutenção em curso. Não tem duração: fica aberta até alguém '
  'apertar Retomar, e por isso o cronômetro dela conta para cima.';
comment on column public.courts.armed_pause_kind is
  'Pausa apertada durante o jogo. Não interrompe quem está jogando: só marca '
  'qual caminho o fim do tempo vai tomar.';
comment on column public.courts.exit_ask_entry_id is
  'A party que acabou de sair da quadra e ainda não respondeu se volta para o '
  'fim da fila ou vai embora. Sem resposta até o fim da troca, vai embora.';
comment on column public.courts.changeover_seconds is
  'A troca entre dois jogos: 1 min 30 s. Tempo de quem jogou sair e de quem '
  'entra ocupar a quadra.';

-- ---------------------------------------------------------------------
-- 3. O rótulo da party, com as palavras do handoff
-- ---------------------------------------------------------------------
create or replace function public.party_label(p_size integer)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when coalesce(p_size, 0) <= 1 then 'Sozinho'
    when p_size = 2 then 'Simples'
    when p_size = 4 then 'Duplas'
    else 'Grupo de ' || p_size || ', revezando'
  end;
$$;

comment on function public.party_label(integer) is
  'Simples, Duplas, Sozinho ou Grupo de N, revezando. As palavras são as do '
  'handoff: o totem fala com quem está na quadra, não com quem lê schema.';

-- Quantas pessoas a vaga tem, seja party digitada ou vaga antiga com
-- conta. Uma conta só é uma pessoa quando não há membros registrados.
create or replace function public.entry_size(p_entry_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select e.party_size from public.queue_entries e where e.id = p_entry_id),
    (select count(*)::integer from public.queue_entry_members m
      where m.entry_id = p_entry_id and m.is_active),
    1
  );
$$;

-- O nome que a tela mostra: o digitado, o rótulo da vaga sem app, ou os
-- primeiros nomes de quem tem conta.
create or replace function public.entry_label(p_entry_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select btrim(e.party_name) from public.queue_entries e
      where e.id = p_entry_id and e.party_name is not null),
    (select e.offline_label from public.queue_entries e
      where e.id = p_entry_id and e.is_offline),
    (select string_agg(pl ->> 'short_name', ' + ' order by ord)
       from jsonb_array_elements(public.match_side_players(p_entry_id))
            with ordinality as t(pl, ord)),
    'Quadra livre'
  );
$$;

-- ---------------------------------------------------------------------
-- 4. Voltar para a fila leva o nome e o token junto
--
-- Sem isto, quem apertou "Voltar pra fila" perderia o nome digitado e o
-- segredo guardado no navegador — e a vaga nova nasceria sem ninguém.
-- ---------------------------------------------------------------------
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

  -- O token é único entre as vagas que o têm, então a vaga velha o
  -- devolve ANTES de a nova nascer com ele. Ao contrário, as duas o
  -- teriam ao mesmo tempo e o índice recusaria a volta para a fila.
  update public.queue_entries set party_token_hash = null where id = p_entry_id;

  insert into public.queue_entries
    (court_id, mode, status, created_by, scan_token_id,
     is_offline, offline_label, offline_kind, host_session_id,
     first_joined_at, requeued_from, turn_number,
     party_name, party_size, party_token_hash, source)
  values
    (v_old.court_id, v_old.mode, 'waiting', v_old.created_by, null,
     v_old.is_offline, v_old.offline_label, v_old.offline_kind, v_old.host_session_id,
     v_old.first_joined_at, v_old.id,
     case when p_played then v_old.turn_number + 1 else v_old.turn_number end,
     v_old.party_name, v_old.party_size, v_old.party_token_hash, v_old.source)
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

-- ---------------------------------------------------------------------
-- 5. A troca de 1:30
--
-- Era a chamada de 15 segundos descendo a fila. O handoff trocou por
-- uma troca só: a próxima party tem 1 min 30 s para ocupar a quadra e o
-- turno dela começa sozinho no fim — ninguém precisa apertar nada.
--
-- A próxima party NÃO sai da lista agora: enquanto a quadra não liberou
-- de fato, ela ainda é alguém esperando, e aparece nos dois lugares
-- (linha 1 da fila e "Entra: Nome" no painel).
-- ---------------------------------------------------------------------
create or replace function public.start_handover(p_court_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court public.courts%rowtype;
  v_next  uuid;
  v_host  uuid;
  v_label text;
begin
  select * into v_court from public.courts c where c.id = p_court_id for update;
  if not found then
    return null;
  end if;

  -- Quadra ocupada não troca de grupo.
  if exists (select 1 from public.matches mt
             where mt.court_id = p_court_id and mt.ended_at is null) then
    return null;
  end if;

  -- Pausa segura a fila: a troca só começa depois do Retomar, e aí
  -- começa com os 1:30 cheios.
  if v_court.pause_kind is not null then
    update public.courts
       set handover_phase = null, handover_entry_id = null, handover_until = null
     where id = p_court_id;
    return null;
  end if;

  select qp.entry_id into v_next
  from public.queue_positions qp
  where qp.court_id = p_court_id
  order by qp.position
  limit 1;

  if v_next is null then
    -- Fila vazia: quadra livre, e o relógio para.
    update public.courts
       set handover_phase = null, handover_entry_id = null, handover_until = null,
           holder_entry_id = null,
           status = case
                      when status = 'unavailable' then 'unavailable'::public.court_status
                      else 'available'::public.court_status
                    end
     where id = p_court_id;
    return null;
  end if;

  update public.courts
     set handover_phase    = 'changeover',
         handover_entry_id = v_next,
         handover_until    = now() + make_interval(secs => v_court.changeover_seconds),
         holder_entry_id   = null,
         status = case
                    when status = 'unavailable' then 'unavailable'::public.court_status
                    else 'available'::public.court_status
                  end
   where id = p_court_id;

  -- A vaga da vez aparece como chamada. Sem call_expires_at: o relógio
  -- desta troca é o da quadra, e não vence a vaga de ninguém.
  update public.queue_entries
     set status = 'ready', called_at = coalesce(called_at, now()), call_expires_at = null
   where id = v_next and status = 'waiting';

  -- Quem tem app (as vagas antigas) continua recebendo o aviso; para a
  -- party digitada no totem não há a quem notificar, e a função não
  -- insere nada.
  perform public.enqueue_team_notification(
    v_next, 'queue_turn', 'É a sua vez!',
    format('Entre na %s: a troca já começou.', public.court_label(v_court.court_number)),
    jsonb_build_object('court_id', p_court_id, 'entry_id', v_next, 'teams_ahead', 0)
  );

  select e.offline_label into v_label
  from public.queue_entries e where e.id = v_next and e.is_offline;

  if v_label is not null then
    v_host := public.effective_host(p_court_id);
    if v_host is not null then
      perform public.enqueue_user_notification(
        v_host, p_court_id, 'host_offline_called',
        'Vez do grupo sem app',
        format('%s pode entrar na %s.', v_label, public.court_label(v_court.court_number)),
        jsonb_build_object('court_id', p_court_id, 'entry_id', v_next)
      );
    end if;
  end if;

  return v_next;
end;
$$;

revoke all on function public.start_handover(uuid) from public, anon, authenticated;

comment on function public.start_handover(uuid) is
  'Começa a troca de 1:30. No fim dela o turno da próxima party começa sozinho.';

-- ---------------------------------------------------------------------
-- 6. Acabou o tempo: a pergunta de saída, ou a pausa que estava marcada
--
-- A rotação automática mandava quem jogou direto para o fim da fila. O
-- handoff pergunta: "Nome, acabou seu tempo. Quer sair ou voltar pro
-- fim da fila?". Sem resposta até o fim da troca, o padrão é sair —
-- decisão em aberto no handoff, anotada em docs/.
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
  v_match public.matches%rowtype;
  v_armed text;
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

  update public.courts
     set holder_entry_id   = null,
         handover_phase    = null,
         handover_entry_id = null,
         handover_until    = null,
         status = case
                    when status = 'unavailable' then 'unavailable'::public.court_status
                    else 'available'::public.court_status
                  end,
         -- A pergunta é de quem acabou de sair, e só quando o tempo zerou:
         -- quem devolveu a quadra antes da hora já escolheu parar.
         exit_ask_entry_id = case when p_reason = 'slot_expired'
                                  then v_match.side_a_entry_id end
   where id = v_match.court_id
  returning armed_pause_kind into v_armed;

  if v_armed is not null then
    -- A pausa marcada durante o jogo começa agora e segura a fila até
    -- alguém apertar Retomar.
    update public.courts
       set pause_kind = v_armed, paused_at = now(), armed_pause_kind = null
     where id = v_match.court_id;
    return public.match_state(p_match_id);
  end if;

  if p_reason = 'slot_expired' then
    perform public.start_handover(v_match.court_id);
  else
    -- Fim fora de hora: a fila anda pela regra antiga, que é a única que
    -- ainda atende o primeiro turno de quem entrou com conta.
    perform public.call_next_team(v_match.court_id);
  end if;

  return public.match_state(p_match_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 7. Abrir o turno — a quadra pausada não abre, e a faixa de saída some
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
  if v_court.pause_kind is not null then
    raise exception 'A quadra está pausada. Ninguém entra até alguém retomar.'
      using errcode = 'NQ038';
  end if;

  -- O turno anterior já venceu? Encerra agora — é isso que roda a fila.
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
  -- ter mudado a cabeça da fila.
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

  -- Entrou gente na quadra: a troca acabou e a faixa da party anterior
  -- some, como no handoff.
  update public.courts
     set status = 'in_game', holder_entry_id = null,
         handover_phase = null, handover_entry_id = null, handover_until = null,
         exit_ask_entry_id = null
   where id = v_court.id;

  return public.match_state(v_match_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 8. As pausas de manutenção
--
-- Não têm duração: ficam abertas até alguém apertar Retomar, e o
-- cronômetro delas conta para cima, sem barra de progresso, porque não
-- existe fim previsto.
--
--   • apertada durante o jogo: agenda. O jogo não é interrompido, a
--     pausa começa quando o tempo zerar. Apertar de novo cancela.
--   • apertada na troca ou com a quadra livre: começa na hora.
--   • um comando de cada vez: com a quadra pausada só existe Retomar.
-- ---------------------------------------------------------------------
create or replace function public.pause_court(p_court_id uuid, p_kind text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court public.courts%rowtype;
  v_live  boolean;
begin
  if p_kind is null or p_kind not in ('vassourao', 'rega', 'excecao') then
    raise exception 'Pausa desconhecida' using errcode = 'NQ039';
  end if;

  select * into v_court from public.courts c where c.id = p_court_id for update;
  if not found then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;

  v_live := exists (select 1 from public.matches mt
                    where mt.court_id = p_court_id and mt.ended_at is null);

  if v_court.pause_kind is not null then
    -- Já pausada: o mesmo botão retoma, outro botão troca o motivo.
    if v_court.pause_kind = p_kind then
      return public.resume_court(p_court_id);
    end if;
    update public.courts set pause_kind = p_kind, paused_at = now()
     where id = p_court_id;

  elsif v_live then
    -- Durante o jogo, agenda. Toque de novo cancela o agendamento.
    update public.courts
       set armed_pause_kind = case when v_court.armed_pause_kind = p_kind
                                   then null else p_kind end
     where id = p_court_id;

  else
    -- Na troca ou com a quadra livre, começa na hora e para o relógio
    -- da troca: quando retomarem, a troca recomeça inteira.
    update public.courts
       set pause_kind = p_kind, paused_at = now(), armed_pause_kind = null,
           handover_phase = null, handover_entry_id = null, handover_until = null
     where id = p_court_id;
  end if;

  return public.court_screen(p_court_id);
end;
$$;

create or replace function public.resume_court(p_court_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court public.courts%rowtype;
begin
  select * into v_court from public.courts c where c.id = p_court_id for update;
  if not found then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;

  if v_court.pause_kind is null then
    -- Nada pausado: o Retomar também desfaz o agendamento, que é o que
    -- quem aperta espera.
    update public.courts set armed_pause_kind = null where id = p_court_id;
    return public.court_screen(p_court_id);
  end if;

  update public.courts
     set pause_kind = null, paused_at = null, armed_pause_kind = null
   where id = p_court_id;

  -- Pausada → Troca 1:30, com os 1:30 cheios. É nesta troca que aparece
  -- a pergunta de saída que ficou esperando.
  perform public.start_handover(p_court_id);

  return public.court_screen(p_court_id);
end;
$$;

revoke all on function public.pause_court(uuid, text) from public, anon, authenticated;
revoke all on function public.resume_court(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 9. Continuar jogando — só com a fila vazia
--
-- O botão existe para não interromper quem está sozinho na quadra, e
-- não existe com gente esperando: ninguém segura a quadra por 80
-- minutos enquanto outros esperam.
-- ---------------------------------------------------------------------
create or replace function public.continue_playing(p_court_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court public.courts%rowtype;
  v_match public.matches%rowtype;
begin
  select * into v_court from public.courts c where c.id = p_court_id;
  if not found then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;

  select * into v_match
  from public.matches mt
  where mt.court_id = p_court_id and mt.ended_at is null
  for update;

  if not found then
    raise exception 'Não há jogo em andamento nesta quadra' using errcode = 'NQ018';
  end if;

  if exists (select 1 from public.queue_positions qp where qp.court_id = p_court_id) then
    raise exception 'Tem gente esperando: a quadra não pode continuar.'
      using errcode = 'NQ040';
  end if;

  if extract(epoch from (v_match.expires_at - now())) > v_court.warn_seconds then
    raise exception 'O botão vale no último minuto do jogo' using errcode = 'NQ040';
  end if;

  update public.matches
     set expires_at = now() + make_interval(mins => v_court.slot_minutes)
   where id = v_match.id;

  return public.court_screen(p_court_id);
end;
$$;

revoke all on function public.continue_playing(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 10. A pergunta de saída
-- ---------------------------------------------------------------------
create or replace function public.answer_exit_ask(p_court_id uuid, p_back boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry uuid;
begin
  select c.exit_ask_entry_id into v_entry
  from public.courts c where c.id = p_court_id for update;

  if v_entry is null then
    -- Já respondida, ou a próxima party entrou e a faixa sumiu.
    return public.court_screen(p_court_id);
  end if;

  update public.courts set exit_ask_entry_id = null where id = p_court_id;

  if p_back then
    -- Volta para o FIM da fila, com o turno contado.
    perform public.requeue_entry(v_entry, true);
  end if;

  return public.court_screen(p_court_id);
end;
$$;

revoke all on function public.answer_exit_ask(uuid, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 11. Entrar na fila sem conta
--
-- O nome é texto livre, como no handoff: duas pessoas de mesmo nome em
-- dias diferentes não têm relação entre si. O que autoriza a escrita não
-- é quem a pessoa é, é de onde ela está escrevendo — o totem da quadra
-- ou o QR/NFC impresso nela.
-- ---------------------------------------------------------------------
alter table public.scan_tokens alter column user_id drop not null;

comment on column public.scan_tokens.user_id is
  'A conta que escaneou, quando existe. Nulo = escaneou sem login, que é o '
  'caminho normal desde o totem: o que o token prova é posse do QR da quadra.';

-- Variante sem conta do take_scan_token: o token vale por si, não por
-- quem o pegou. Exige user_id nulo de propósito — token de uma conta
-- continua só servindo para ela.
create or replace function public.take_anon_scan_token(p_scan_token text, p_message text)
returns public.scan_tokens
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token public.scan_tokens%rowtype;
begin
  select * into v_token
  from public.scan_tokens t
  where t.token_hash = public.hash_scan_token(p_scan_token)
  for update;

  if not found
     or v_token.user_id is not null
     or v_token.consumed_at is not null
     or v_token.expires_at <= now() then
    raise exception '%', p_message using errcode = 'NQ002';
  end if;

  return v_token;
end;
$$;

revoke all on function public.take_anon_scan_token(text, text) from public, anon, authenticated;

create or replace function public.join_party(
  p_court_id      uuid,
  p_name          text,
  p_size          integer,
  p_source        text default 'totem',
  p_scan_token_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court public.courts%rowtype;
  v_name  text := nullif(btrim(coalesce(p_name, '')), '');
  v_size  integer := coalesce(p_size, 2);
  v_token text;
  v_entry uuid;
  v_free  boolean;
  v_pos   integer;
begin
  if v_name is null or char_length(v_name) < 2 or char_length(v_name) > 40 then
    raise exception 'Escreva o nome com 2 a 40 letras' using errcode = 'NQ041';
  end if;
  if v_size < 1 or v_size > 20 then
    raise exception 'A party vai de 1 a 20 pessoas' using errcode = 'NQ042';
  end if;
  if p_source is null or p_source not in ('totem', 'qr', 'nfc', 'app') then
    raise exception 'Origem inválida' using errcode = 'NQ024';
  end if;

  select * into v_court from public.courts c where c.id = p_court_id for update;
  if not found then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;
  if not v_court.is_active or v_court.status = 'unavailable' then
    raise exception 'Esta quadra está indisponível no momento' using errcode = 'NQ003';
  end if;

  -- 32 bytes de aleatório: o mesmo tamanho do token do tablet.
  v_token := encode(extensions.gen_random_bytes(32), 'hex');

  -- mode existe desde a Sprint 1 e só tem dois valores; quem carrega a
  -- verdade do tamanho agora é party_size.
  insert into public.queue_entries
    (court_id, mode, status, created_by, scan_token_id,
     party_name, party_size, party_token_hash, source)
  values
    (p_court_id,
     case when v_size <= 1 then 'single'::public.queue_mode
          else 'double'::public.queue_mode end,
     'waiting', null, p_scan_token_id,
     v_name, v_size, public.hash_scan_token(v_token), p_source)
  returning id into v_entry;

  if p_scan_token_id is not null then
    update public.scan_tokens
       set consumed_at = now(), consumed_by_entry = v_entry
     where id = p_scan_token_id;
  end if;

  -- Quadra livre → Em jogo: quem entra numa quadra vazia começa a jogar,
  -- sem esperar troca nenhuma.
  v_free := v_court.pause_kind is null
            and v_court.handover_phase is null
            and not exists (select 1 from public.matches mt
                            where mt.court_id = p_court_id and mt.ended_at is null);

  if v_free then
    perform public.open_match(v_entry);
  end if;

  select qp.position into v_pos
  from public.queue_positions qp
  where qp.court_id = p_court_id and qp.entry_id = v_entry;

  return jsonb_build_object(
    'entry_id',    v_entry,
    'party_name',  v_name,
    'party_size',  v_size,
    'position',    v_pos,
    'playing',     v_free,
    -- Única vez que este valor existe fora do navegador de quem entrou.
    'party_token', v_token
  );
end;
$$;

revoke all on function public.join_party(uuid, text, integer, text, uuid) from public, anon, authenticated;

-- A vaga de uma party, pelo segredo guardado no navegador dela.
create or replace function public.take_party_entry(p_party_token text)
returns public.queue_entries
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry public.queue_entries%rowtype;
begin
  select * into v_entry
  from public.queue_entries e
  where e.party_token_hash = public.hash_scan_token(coalesce(p_party_token, ''))
  limit 1;

  if not found then
    raise exception 'Não encontramos a sua vaga na fila' using errcode = 'NQ007';
  end if;

  return v_entry;
end;
$$;

revoke all on function public.take_party_entry(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 12. O totem: tudo pelo token do aparelho
--
-- Quem aperta no totem não é uma pessoa, é quem está na quadra. Então
-- nenhuma destas funções recebe ou precisa de identidade: o token do
-- aparelho diz de qual quadra ele fala, e é só o que importa.
-- ---------------------------------------------------------------------
create or replace function public.totem_court(p_token text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_device public.court_devices%rowtype;
begin
  select * into v_device
  from public.court_devices d
  where d.token_hash = public.hash_scan_token(coalesce(p_token, ''))
    and d.revoked_at is null;

  if not found then
    raise exception 'Este totem não está mais ligado a uma quadra. Peça um link novo.'
      using errcode = 'NQ037';
  end if;

  update public.court_devices set last_seen_at = now() where id = v_device.id;

  return v_device.court_id;
end;
$$;

revoke all on function public.totem_court(text) from public, anon, authenticated;

-- Executa o que já venceu, sem montar a tela do app inteira.
create or replace function public.tick_court(p_court_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.courts c
             where c.id = p_court_id
               and c.handover_until is not null and c.handover_until <= now())
     or exists (select 1 from public.matches mt
                where mt.court_id = p_court_id
                  and mt.ended_at is null and mt.expires_at <= now())
     or exists (select 1 from public.queue_entries e
                where e.court_id = p_court_id
                  and e.status = 'ready'
                  and e.call_expires_at is not null and e.call_expires_at <= now())
  then
    perform public.advance_court(p_court_id);
  end if;
end;
$$;

revoke all on function public.tick_court(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 13. A tela do totem
--
-- Uma chamada devolve tudo o que a tela desenha, já resolvido: o estado,
-- o número grande, a barra, quem está em quadra, quem entra, a pausa, a
-- pergunta de saída e a fila com a previsão de cada posição.
--
-- Previsão (handoff): para a posição N, o tempo restante do jogo atual,
-- mais a troca, mais N vezes (partida + troca). Com pausa em curso ou
-- agendada não é calculável, e a coluna mostra dois traços.
-- ---------------------------------------------------------------------
create or replace function public.totem_state(p_court_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_court    public.courts%rowtype;
  v_park     public.parks%rowtype;
  v_match    public.matches%rowtype;
  v_state    text;
  v_rem      integer := 0;
  v_gap      integer := 0;
  v_base     integer;
  v_per_turn integer;
  v_queue    jsonb;
  v_count    integer;
  v_playing  jsonb;
  v_next     jsonb;
  v_exit     jsonb;
  v_pause    jsonb;
  v_next_id  uuid;
begin
  select * into v_court from public.courts c where c.id = p_court_id;
  if not found then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;

  select * into v_park from public.parks pk where pk.id = v_court.park_id;

  select * into v_match
  from public.matches mt
  where mt.court_id = p_court_id and mt.ended_at is null
  limit 1;

  if v_match.id is not null then
    v_rem := greatest(0, floor(extract(epoch from (v_match.expires_at - now())))::integer);
  end if;

  if v_court.handover_until is not null and v_court.handover_until > now() then
    v_gap := greatest(0, ceil(extract(epoch from (v_court.handover_until - now())))::integer);
  end if;

  v_state := case
               when v_court.pause_kind is not null then 'paused'
               when v_match.id is not null and v_rem <= v_court.warn_seconds then 'ending'
               when v_match.id is not null then 'playing'
               when v_court.handover_phase = 'changeover' and v_gap > 0 then 'changeover'
               else 'free'
             end;

  -- Quem está em quadra agora.
  if v_match.id is not null then
    v_playing := jsonb_build_object(
      'entry_id', v_match.side_a_entry_id,
      'name',     public.entry_label(v_match.side_a_entry_id),
      'size',     public.entry_size(v_match.side_a_entry_id),
      'label',    public.party_label(public.entry_size(v_match.side_a_entry_id))
    );
  end if;

  -- Quem entra em seguida: a primeira da fila, que durante a troca
  -- aparece nos dois lugares de propósito.
  select qp.entry_id into v_next_id
  from public.queue_positions qp
  where qp.court_id = p_court_id
  order by qp.position
  limit 1;

  if v_next_id is not null then
    v_next := jsonb_build_object(
      'entry_id', v_next_id,
      'name',     public.entry_label(v_next_id),
      'size',     public.entry_size(v_next_id),
      'label',    public.party_label(public.entry_size(v_next_id))
    );
  end if;

  if v_court.exit_ask_entry_id is not null and v_state in ('changeover', 'paused') then
    v_exit := jsonb_build_object(
      'entry_id', v_court.exit_ask_entry_id,
      'name',     public.entry_label(v_court.exit_ask_entry_id),
      'text',     public.entry_label(v_court.exit_ask_entry_id)
                  || ', acabou seu tempo. Quer sair ou voltar pro fim da fila?'
    );
  end if;

  if v_court.pause_kind is not null then
    v_pause := jsonb_build_object(
      'kind',    v_court.pause_kind,
      'label',   case v_court.pause_kind
                   when 'vassourao' then 'Vassourão'
                   when 'rega'      then 'Rega da quadra'
                   else 'Exceção'
                 end,
      'desc',    case v_court.pause_kind
                   when 'vassourao' then 'Estão passando o vassourão no saibro.'
                   when 'rega'      then 'Estão regando a quadra.'
                   else 'Parada autorizada pelo parque.'
                 end,
      'since',   v_court.paused_at,
      'seconds', greatest(0, floor(extract(epoch from (now() - v_court.paused_at)))::integer)
    );
  end if;

  v_per_turn := v_court.slot_minutes * 60 + v_court.changeover_seconds;

  -- Nulo = indefinido: pausa em curso ou agendada, e pausa só acaba
  -- quando alguém retoma.
  v_base := case
              when v_court.pause_kind is not null then null
              when v_court.armed_pause_kind is not null then null
              when v_match.id is not null then v_rem + v_court.changeover_seconds
              when v_state = 'changeover' then v_gap
              else 0
            end;

  select coalesce(jsonb_agg(item order by position), '[]'::jsonb), count(*)
  into v_queue, v_count
  from (
    select qp.position,
           jsonb_build_object(
             'entry_id',    qp.entry_id,
             'position',    qp.position,
             'name',        public.entry_label(qp.entry_id),
             'size',        public.entry_size(qp.entry_id),
             'label',       public.party_label(public.entry_size(qp.entry_id)),
             'is_next',     qp.position = 1,
             'source',      e.source,
             'joined_at',   e.first_joined_at,
             'eta_seconds', case when v_base is null then null
                                 else v_base + (qp.position - 1) * v_per_turn end,
             'eta_at',      case when v_base is null then null
                                 else now() + make_interval(
                                        secs => v_base + (qp.position - 1) * v_per_turn) end
           ) as item
    from public.queue_positions qp
    join public.queue_entries e on e.id = qp.entry_id
    where qp.court_id = p_court_id
  ) s;

  return jsonb_build_object(
    'court', jsonb_build_object(
      'id',      v_court.id,
      'name',    public.court_label(v_court.court_number),
      'number',  v_court.court_number,
      'surface_label', case v_court.surface
                         when 'clay' then 'Saibro'
                         when 'hard' then 'Rápida'
                         else 'Grama'
                       end,
      'park',    v_park.name,
      -- A linha fina do topo do totem, que estava chumbada no mock.
      'strip',   concat_ws(' · ',
                   public.court_label(v_court.court_number),
                   case v_court.surface
                     when 'clay' then 'Saibro'
                     when 'hard' then 'Rápida'
                     else 'Grama'
                   end,
                   v_park.name),
      'is_active', v_court.is_active,
      'status',    v_court.status
    ),
    'state',            v_state,
    'slot_seconds',     v_court.slot_minutes * 60,
    'slot_minutes',     v_court.slot_minutes,
    'changeover_seconds', v_court.changeover_seconds,
    'warn_seconds',     v_court.warn_seconds,
    'remaining_seconds', v_rem,
    'changeover_left',  v_gap,
    'elapsed_seconds',  case when v_match.id is null then 0
                             else greatest(0, v_court.slot_minutes * 60 - v_rem) end,
    'playing',          v_playing,
    'next',             v_next,
    'exit_ask',         v_exit,
    'pause',            v_pause,
    'armed_pause',      case when v_court.armed_pause_kind is null then null
                             else jsonb_build_object(
                                    'kind', v_court.armed_pause_kind,
                                    'label', case v_court.armed_pause_kind
                                               when 'vassourao' then 'Vassourão'
                                               when 'rega'      then 'Rega da quadra'
                                               else 'Exceção'
                                             end)
                        end,
    -- Só no último minuto e só com a fila vazia.
    'can_continue',     v_match.id is not null
                        and v_rem <= v_court.warn_seconds
                        and v_count = 0,
    'queue',            v_queue,
    'queue_count',      v_count,
    'turn_seconds',     v_per_turn,
    'generated_at',     now()
  );
end;
$$;

revoke all on function public.totem_state(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 14. As seis coisas que o totem faz
-- ---------------------------------------------------------------------
create or replace function public.totem_screen(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court uuid := public.totem_court(p_token);
begin
  perform public.tick_court(v_court);
  return public.totem_state(v_court);
end;
$$;

create or replace function public.totem_join(p_token text, p_name text, p_size integer)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court uuid := public.totem_court(p_token);
  v_join  jsonb;
begin
  perform public.tick_court(v_court);
  v_join := public.join_party(v_court, p_name, p_size, 'totem', null);

  -- O party token não sai pelo totem: a tela é compartilhada, e no totem
  -- ninguém precisa dele — quem responde pelo grupo é quem está ali.
  return (v_join - 'party_token') || jsonb_build_object('screen', public.totem_state(v_court));
end;
$$;

create or replace function public.totem_pause(p_token text, p_kind text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court uuid := public.totem_court(p_token);
begin
  perform public.tick_court(v_court);
  perform public.pause_court(v_court, p_kind);
  return public.totem_state(v_court);
end;
$$;

create or replace function public.totem_resume(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court uuid := public.totem_court(p_token);
begin
  perform public.resume_court(v_court);
  return public.totem_state(v_court);
end;
$$;

create or replace function public.totem_continue(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court uuid := public.totem_court(p_token);
begin
  perform public.tick_court(v_court);
  perform public.continue_playing(v_court);
  return public.totem_state(v_court);
end;
$$;

create or replace function public.totem_exit_answer(p_token text, p_back boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court uuid := public.totem_court(p_token);
begin
  perform public.tick_court(v_court);
  perform public.answer_exit_ask(v_court, coalesce(p_back, false));
  return public.totem_state(v_court);
end;
$$;

revoke all on function public.totem_screen(text)             from public, anon, authenticated;
revoke all on function public.totem_join(text, text, integer) from public, anon, authenticated;
revoke all on function public.totem_pause(text, text)        from public, anon, authenticated;
revoke all on function public.totem_resume(text)             from public, anon, authenticated;
revoke all on function public.totem_continue(text)           from public, anon, authenticated;
revoke all on function public.totem_exit_answer(text, boolean) from public, anon, authenticated;

-- O totem não tem login: o token do aparelho é a credencial, e é por
-- isso que estas seis são as únicas que o anon pode chamar com ele.
grant execute on function public.totem_screen(text)              to anon, authenticated;
grant execute on function public.totem_join(text, text, integer)  to anon, authenticated;
grant execute on function public.totem_pause(text, text)          to anon, authenticated;
grant execute on function public.totem_resume(text)               to anon, authenticated;
grant execute on function public.totem_continue(text)             to anon, authenticated;
grant execute on function public.totem_exit_answer(text, boolean) to anon, authenticated;

comment on function public.totem_screen(text) is
  'A tela do totem inteira, pelo token do aparelho. Marca o aparelho como vivo '
  'e executa o que já venceu (turno e troca).';

-- ---------------------------------------------------------------------
-- 15. O QR e a tag NFC: entrar na fila pelo celular, sem login
--
-- O scan token prova que a pessoa tem o código impresso da quadra na
-- mão. É ele que autoriza a escrita, e ele vale 30 segundos.
-- ---------------------------------------------------------------------
create or replace function public.scan_join_party(
  p_scan_token text,
  p_name       text,
  p_size       integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token public.scan_tokens%rowtype;
  v_src   text;
begin
  v_token := public.take_anon_scan_token(
    p_scan_token, 'Escaneie o QR Code da quadra de novo para entrar na fila');

  v_src := case when v_token.method = 'nfc' then 'nfc' else 'qr' end;

  perform public.tick_court(v_token.court_id);

  return public.join_party(v_token.court_id, p_name, p_size, v_src, v_token.id)
         || jsonb_build_object('court_id', v_token.court_id);
end;
$$;

-- A tela de quem entrou pelo celular: a mesma quadra que o totem mostra,
-- mais a própria vaga, para a pessoa saber a posição de onde estiver.
create or replace function public.party_screen(p_party_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry public.queue_entries%rowtype;
  v_pos   integer;
begin
  v_entry := public.take_party_entry(p_party_token);

  perform public.tick_court(v_entry.court_id);

  -- A vaga pode ter virado outra: quem voltou para a fila tem vaga nova,
  -- e o token viaja com ela.
  v_entry := public.take_party_entry(p_party_token);

  select qp.position into v_pos
  from public.queue_positions qp
  where qp.court_id = v_entry.court_id and qp.entry_id = v_entry.id;

  return public.totem_state(v_entry.court_id) || jsonb_build_object(
    'my_party', jsonb_build_object(
      'entry_id',  v_entry.id,
      'name',      v_entry.party_name,
      'size',      v_entry.party_size,
      'label',     public.party_label(v_entry.party_size),
      'status',    v_entry.status,
      'position',  v_pos,
      'is_playing', v_entry.status = 'playing',
      'can_answer_exit', exists (select 1 from public.courts c
                                 where c.id = v_entry.court_id
                                   and c.exit_ask_entry_id = v_entry.id)
    )
  );
end;
$$;

create or replace function public.party_leave(p_party_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry public.queue_entries%rowtype;
  v_match uuid;
  v_court uuid;
begin
  v_entry := public.take_party_entry(p_party_token);
  v_court := v_entry.court_id;

  if v_entry.status = 'playing' then
    select mt.id into v_match
    from public.matches mt
    where mt.court_id = v_court and mt.ended_at is null
      and mt.side_a_entry_id = v_entry.id;

    if v_match is not null then
      perform public.close_match(v_match, null, 'abandoned');
    end if;

  elsif v_entry.status in ('waiting', 'ready') then
    update public.queue_entries
       set status = 'cancelled', cancel_reason = 'left_by_party',
           left_at = now(), party_token_hash = null
     where id = v_entry.id;

    -- Saiu quem estava entrando: a troca recomeça com quem ficou.
    if exists (select 1 from public.courts c
               where c.id = v_court and c.handover_entry_id = v_entry.id) then
      perform public.start_handover(v_court);
    end if;
  end if;

  return public.totem_state(v_court);
end;
$$;

create or replace function public.party_exit_answer(p_party_token text, p_back boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry public.queue_entries%rowtype;
begin
  v_entry := public.take_party_entry(p_party_token);

  if not exists (select 1 from public.courts c
                 where c.id = v_entry.court_id and c.exit_ask_entry_id = v_entry.id) then
    raise exception 'Esta pergunta já foi respondida' using errcode = 'NQ009';
  end if;

  perform public.answer_exit_ask(v_entry.court_id, coalesce(p_back, false));

  return public.totem_state(v_entry.court_id);
end;
$$;

revoke all on function public.scan_join_party(text, text, integer)   from public, anon, authenticated;
revoke all on function public.party_screen(text)                     from public, anon, authenticated;
revoke all on function public.party_leave(text)                      from public, anon, authenticated;
revoke all on function public.party_exit_answer(text, boolean)       from public, anon, authenticated;

grant execute on function public.scan_join_party(text, text, integer) to anon, authenticated;
grant execute on function public.party_screen(text)                   to anon, authenticated;
grant execute on function public.party_leave(text)                    to anon, authenticated;
grant execute on function public.party_exit_answer(text, boolean)     to anon, authenticated;

-- ---------------------------------------------------------------------
-- 16. Andar a quadra: só a troca, agora
--
-- Saíram as duas fases que a chamada de 15 segundos trouxe. Sobrou a
-- troca, que termina abrindo o turno de quem estava entrando — e a
-- pergunta de saída não respondida, que vence com ela.
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
  v_ready   boolean;
begin
  for v_match in
    select id from public.matches
    where court_id = p_court_id and ended_at is null and expires_at <= now()
  loop
    perform public.close_match(v_match.id, null, 'slot_expired');
    v_closed := v_closed + 1;
  end loop;

  select * into v_court from public.courts c where c.id = p_court_id;

  if found
     and v_court.handover_phase = 'changeover'
     and v_court.handover_until is not null
     and v_court.handover_until <= now() then

    -- Ninguém respondeu a pergunta de saída dentro da troca: o padrão
    -- hoje é sair. É a decisão em aberto nº 2 do handoff.
    if v_court.exit_ask_entry_id is not null then
      update public.courts set exit_ask_entry_id = null where id = p_court_id;
    end if;

    v_ready := v_court.handover_entry_id is not null
               and exists (select 1 from public.queue_entries e
                           where e.id = v_court.handover_entry_id
                             and e.status in ('waiting', 'ready'));

    if v_ready
       and v_court.pause_kind is null
       and v_court.is_active
       and v_court.status <> 'unavailable'
       and not exists (select 1 from public.matches mt
                       where mt.court_id = p_court_id and mt.ended_at is null) then
      -- Fim da troca: o turno de quem entrou começa agora, sozinho.
      perform public.open_match(v_court.handover_entry_id);
      v_started := 1;
    else
      update public.courts
         set handover_phase = null, handover_entry_id = null, handover_until = null
       where id = p_court_id;
      -- A vaga da vez pode ter saído no meio da troca: quem ficou tem
      -- direito à troca inteira.
      perform public.start_handover(p_court_id);
    end if;
  end if;

  -- Chamada da regra antiga, que só atende o primeiro turno de quem
  -- entrou com conta.
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
                            'calls_skipped', 0,
                            'turns_started', v_started);
end;
$$;

revoke all on function public.advance_court(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 17. Quadra pausada não expira a fila de ninguém
--
-- A pausa não tem duração: pode passar das três horas. Sem esta
-- exceção, a regra que limpa fila esquecida esvaziaria a fila inteira
-- de uma quadra parada de propósito — e a pausa existe justamente para
-- segurar a fila.
-- ---------------------------------------------------------------------
create or replace function public.expire_stale_queue_entries(p_max_wait interval default '3 hours')
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count  integer := 0;
  v_courts uuid[];
  v_court  uuid;
begin
  with expirados as (
    update public.queue_entries e
       set status = 'expired', cancel_reason = 'expired_by_system', left_at = now()
     where e.status in ('waiting', 'ready')
       and e.first_joined_at < now() - p_max_wait
       and e.called_at is null
       and not exists (
         select 1 from public.matches mt
         where mt.court_id = e.court_id and mt.ended_at is null
       )
       and not exists (
         select 1 from public.courts c
         where c.id = e.court_id and c.pause_kind is not null
       )
    returning e.court_id
  )
  select coalesce(array_agg(distinct court_id), '{}'::uuid[]), count(*)::integer
  into v_courts, v_count
  from expirados;

  foreach v_court in array v_courts loop
    perform public.call_next_team(v_court);
  end loop;

  return v_count;
end;
$$;

revoke all on function public.expire_stale_queue_entries(interval) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 18. A fila do app: a party digitada aparece como qualquer outra
--
-- O painel do admin e as telas que acompanham a fila continuam lendo
-- daqui. O que muda é que uma vaga pode não ter conta nenhuma: o nome
-- vem de party_name e o tamanho de party_size.
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
           c.handover_phase, c.handover_until,
           c.changeover_seconds as handover_cost,
           -- Com pausa em curso ou agendada a previsão não é calculável:
           -- a pausa só acaba quando alguém retoma.
           (c.pause_kind is not null or c.armed_pause_kind is not null) as frozen,
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
    -- turno mais a troca de 1:30. Nulo com a quadra pausada ou com pausa
    -- agendada, que é o "depois da pausa" do handoff.
    select case
             when frozen then null
             when live > 0 then coalesce(remaining, 0) + handover_cost
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
           e.party_name, e.party_size, e.source,
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
        'group_size',  public.entry_size(q.entry_id),
        'group_label', case when q.party_name is not null
                              then public.party_label(q.party_size)
                            when q.is_offline then 'Sem app'
                            else public.group_label(jsonb_array_length(q.players)) end,
        'mode_label',  case when q.party_name is not null
                              then public.party_label(q.party_size)
                            when q.is_offline then 'Sem app'
                            else public.group_label(jsonb_array_length(q.players)) end,
        'party_name',  q.party_name,
        'source',      q.source,
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
          when q.party_name is not null then q.party_name
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
        'eta_seconds', case when (select to_head from gap) is null then null
                            else (select to_head from gap)
                                 + (q.position - 1) * (select per_turn from gap)
                       end
      )
      order by q.position
    ),
    '[]'::jsonb
  )
  from q;
$$;
grant execute on function public.court_queue_items(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 19. A tela da quadra no app: sem chamada, com pausa e pergunta
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
  v_phase   text;
  v_left    integer := 0;
  v_pause   jsonb;
  v_exit    jsonb;
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

  -- A troca de turno. Fica fora do ar enquanto houver partida: uma troca
  -- aberta com a quadra em jogo é estado impossível, e se aparecer é bug
  -- — a tela não finge que está tudo bem.
  v_phase := case when v_match is null and v_court.handover_until > now()
                  then v_court.handover_phase end;

  if v_phase is not null then
    v_left := greatest(0, ceil(extract(epoch from (v_court.handover_until - now())))::integer);

    select i into v_next from jsonb_array_elements(v_items) i
    where i ->> 'entry_id' = v_court.handover_entry_id::text
    limit 1;

    -- Os nomes como a quadra chama: "Ana, Bruno e Carla".
    select case
             when (v_next ->> 'party_name') is not null
               then v_next ->> 'party_name'
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
      'text',         'Troca de grupo — o próximo entra sozinho',
      'needs_accept', false
    );
  end if;

  -- A pausa de manutenção e a pergunta de saída, que o totem desenha e
  -- o app precisa só mostrar.
  if v_court.pause_kind is not null then
    v_pause := jsonb_build_object(
      'kind',    v_court.pause_kind,
      'label',   case v_court.pause_kind
                   when 'vassourao' then 'Vassourão'
                   when 'rega'      then 'Rega da quadra'
                   else 'Exceção'
                 end,
      'since',   v_court.paused_at,
      'seconds', greatest(0, floor(extract(epoch from (now() - v_court.paused_at)))::integer)
    );
  end if;

  if v_court.exit_ask_entry_id is not null then
    v_exit := jsonb_build_object(
      'entry_id', v_court.exit_ask_entry_id,
      'name',     public.entry_label(v_court.exit_ask_entry_id)
    );
  end if;

  -- O que uma rodada da quadra custa, para as estimativas: o turno mais
  -- a troca de 1:30.
  v_per_turn := v_court.slot_minutes * 60 + v_court.changeover_seconds;
  v_to_head  := case
                  when v_match is not null then coalesce(v_rem, 0) + v_court.changeover_seconds
                  when v_phase is not null then v_left
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
      'warn_seconds',         v_court.warn_seconds,
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
    'pause',        v_pause,
    'exit_ask',     v_exit,
    'is_paused',    v_court.pause_kind is not null,
    'armed_pause',  v_court.armed_pause_kind,
    'status_text',  case
                      when v_court.pause_kind is not null then 'Pausada'
                      when v_match is not null    then 'Em jogo'
                      when v_phase = 'changeover' then 'Troca de grupo'
                      else 'Livre'
                    end,
    'players_line', case
                      when v_court.pause_kind is not null
                        then 'Ninguém entra agora — a quadra está pausada'
                      when v_phase = 'changeover'
                        then coalesce('Entrando: ' || (v_next ->> 'team_label'),
                                      'Entrando em quadra')
                      when v_match is null then 'Sem jogo agora — entre na fila para começar'
                      when (v_live ->> 'is_offline')::boolean
                        then coalesce(v_live ->> 'offline_label', 'Grupo sem app')
                      when public.entry_label((v_live ->> 'entry_id')::uuid) is not null
                           and exists (select 1 from public.queue_entries e
                                       where e.id = (v_live ->> 'entry_id')::uuid
                                         and e.party_name is not null)
                        then public.entry_label((v_live ->> 'entry_id')::uuid)
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
    'total_wait_seconds', case
                            when v_court.pause_kind is not null
                                 or v_court.armed_pause_kind is not null then null
                            else v_to_head + v_queue * v_per_turn
                          end,
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
-- 20. O link que o admin gera aponta para o totem
-- ---------------------------------------------------------------------
create or replace function public.admin_create_court_device(
  p_court_id uuid,
  p_label    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token text;
  v_id    uuid;
  v_label text := nullif(trim(coalesce(p_label, '')), '');
begin
  perform public.require_admin();

  if not exists (select 1 from public.courts c where c.id = p_court_id) then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;

  if v_label is not null and char_length(v_label) > 60 then
    raise exception 'O nome do aparelho vai até 60 caracteres' using errcode = 'NQ024';
  end if;

  -- 32 bytes de aleatório em hex: o mesmo tamanho dos tokens de scan.
  v_token := encode(extensions.gen_random_bytes(32), 'hex');

  insert into public.court_devices (court_id, label, token_hash, created_by)
  values (p_court_id, v_label, public.hash_scan_token(v_token), auth.uid())
  returning id into v_id;

  return jsonb_build_object(
    'device_id', v_id,
    'court_id',  p_court_id,
    'label',     v_label,
    -- Única vez que este valor existe fora do totem.
    'token',     v_token,
    'path',      '/totem/' || v_token
  );
end;
$$;

revoke all on function public.admin_create_court_device(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_create_court_device(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- 21. Sai a chamada de 15 segundos
--
-- Era o fluxo da Sprint 7: o tablet gritava o nome por 15 s, alguém
-- apertava JOGAR e tinha 30 s para entrar. O handoff trocou por uma
-- troca só, e código que não vale mais confunde mais do que ajuda.
-- ---------------------------------------------------------------------
drop function if exists public.tablet_accept_turn(text);
drop function if exists public.tablet_screen(text);
drop function if exists public.accept_turn(uuid);
drop function if exists public.accept_handover(uuid, uuid);
drop function if exists public.skip_handover(uuid);
drop function if exists public.court_tablet_awake(uuid);

alter table public.courts
  drop column if exists handover_call_seconds,
  drop column if exists handover_entry_seconds,
  drop column if exists handover_calls_left;

alter table public.queue_entries
  drop column if exists accepted_at,
  drop column if exists accepted_by;

comment on column public.courts.handover_phase is
  'Só ''changeover'' desde o totem: a troca de 1:30. As fases da chamada de '
  '15 segundos saíram com ela.';

-- ---------------------------------------------------------------------
-- 22. Fechado para PUBLIC, como manda a auditoria
--
-- As funções novas nascem com execute para public por padrão do
-- Postgres; a migration da auditoria revogou isso das que existiam e
-- mudou o default, mas um alter default privileges só vale para o que
-- vem depois dele no MESMO papel. Este bloco é a garantia, e é o que o
-- teste 90 cobra.
-- ---------------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and has_function_privilege('public', p.oid, 'execute')
  loop
    execute format('revoke execute on function %s from public', r.sig);
  end loop;
end $$;
