-- =====================================================================
-- A quadra anda sozinha
--
--   acabou o tempo  ->  1 min de troca  ->  o próximo começa sozinho
--                            e quem jogou vai para o fim da fila
--
-- O que estes testes provam, e é o ponto da mudança: entre o fim de um
-- turno e o começo do próximo, NINGUÉM chama nada. Só o cron
-- (advance_expired_queues) e, quando alguém está com a tela aberta,
-- nudge_court — que também não decide nada, só executa o que venceu.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('a6000000-0000-0000-0000-0000000000a6', 'r-ana@example.com',  '{"full_name":"Ana Rotação"}'),
  ('b6000000-0000-0000-0000-0000000000b6', 'r-bia@example.com',  '{"full_name":"Bia Rotação"}'),
  ('c6000000-0000-0000-0000-0000000000c6', 'r-caio@example.com', '{"full_name":"Caio Rotação"}'),
  ('d6000000-0000-0000-0000-0000000000d6', 'r-duda@example.com', '{"full_name":"Duda Sozinha"}'),
  ('e6000000-0000-0000-0000-0000000000e6', 'r-edu@example.com',  '{"full_name":"Edu Apressado"}'),
  ('f6000000-0000-0000-0000-0000000000f6', 'r-fe@example.com',   '{"full_name":"Fê Rotação"}'),
  ('96000000-0000-0000-0000-000000000096', 'r-gabi@example.com', '{"full_name":"Gabi Atrás"}');

insert into public.parks (id, slug, name, district, latitude, longitude)
values ('66660000-0000-0000-0000-000000000006', 'teste-rotacao', 'Parque da Rotação (teste)',
        'Centro', -23.570000, -46.650000);

insert into public.courts (id, park_id, court_number, surface, slot_minutes, slug, name,
                           latitude, longitude, queue_mode)
values
  ('a6a60000-0000-0000-0000-0000000000a6', '66660000-0000-0000-0000-000000000006', 1, 'hard', 40,
   'teste-rotacao-q1', 'Quadra 01', -23.570000, -46.650000, 'fixed_qr'),
  ('b6b60000-0000-0000-0000-0000000000b6', '66660000-0000-0000-0000-000000000006', 2, 'hard', 40,
   'teste-rotacao-q2', 'Quadra 02', -23.570100, -46.650100, 'fixed_qr'),
  ('c6c60000-0000-0000-0000-0000000000c6', '66660000-0000-0000-0000-000000000006', 3, 'hard', 40,
   'teste-rotacao-q3', 'Quadra 03', -23.570200, -46.650200, 'fixed_qr');

create or replace function pg_temp.as_user(p_user uuid)
returns void language sql as $$
  select set_config('request.jwt.claim.sub', p_user::text, true);
$$;

create or replace function pg_temp.scan(p_user uuid, p_court uuid, p_token text)
returns void language sql as $$
  insert into public.scan_tokens
    (token_hash, user_id, court_id, latitude, longitude, distance_meters, expires_at, method)
  select public.hash_scan_token(p_token), p_user, c.id, c.latitude, c.longitude, 8,
         now() + interval '30 seconds', 'qr'
  from public.courts c where c.id = p_court;
$$;

create or replace function pg_temp.q1() returns uuid language sql as $$
  select 'a6a60000-0000-0000-0000-0000000000a6'::uuid $$;
create or replace function pg_temp.q2() returns uuid language sql as $$
  select 'b6b60000-0000-0000-0000-0000000000b6'::uuid $$;
create or replace function pg_temp.q3() returns uuid language sql as $$
  select 'c6c60000-0000-0000-0000-0000000000c6'::uuid $$;

-- Entrar na fila: o scan e o join, que é o que a pessoa faz ao chegar.
create or replace function pg_temp.entra(p_user uuid, p_court uuid, p_token text)
returns uuid language plpgsql as $$
begin
  perform pg_temp.as_user(p_user);
  perform pg_temp.scan(p_user, p_court, p_token);
  return (public.join_queue(p_token) ->> 'entry_id')::uuid;
end $$;

-- O relógio do turno, empurrado para trás. É o que o tempo real faria.
create or replace function pg_temp.vence_o_turno(p_court uuid)
returns void language sql as $$
  update public.matches set expires_at = now() - interval '1 second'
  where court_id = p_court and ended_at is null;
$$;

create or replace function pg_temp.acaba_a_troca(p_court uuid)
returns void language sql as $$
  update public.courts set changeover_until = now() - interval '1 second'
  where id = p_court and changeover_until is not null;
$$;

-- A vaga ativa de uma pessoa nesta quadra.
create or replace function pg_temp.vaga_de(p_user uuid, p_court uuid)
returns public.queue_entries language sql as $$
  select e.* from public.queue_entries e
  join public.queue_entry_members m on m.entry_id = e.id
  where m.user_id = p_user and m.is_active and e.court_id = p_court
    and e.status in ('waiting', 'ready', 'playing')
  order by e.queue_number desc
  limit 1;
$$;

-- A ordem da fila, por nome, para os testes lerem como a tela.
create or replace function pg_temp.ordem(p_court uuid)
returns text language sql as $$
  select coalesce(string_agg(split_part(coalesce(pr.full_name, 'sem app'), ' ', 1), ',' order by qp.position), '')
  from public.queue_positions qp
  left join public.queue_entry_members m
         on m.entry_id = qp.entry_id and m.is_active and m.role = 'owner'
  left join public.profiles pr on pr.id = m.user_id
  where qp.court_id = p_court;
$$;

create or replace function pg_temp.em_quadra(p_court uuid)
returns text language sql as $$
  select coalesce(string_agg(split_part(coalesce(pr.full_name, 'sem app'), ' ', 1), ','), 'ninguém')
  from public.matches mt
  join public.queue_entry_members m on m.entry_id = mt.side_a_entry_id
  join public.profiles pr on pr.id = m.user_id
  where mt.court_id = p_court and mt.ended_at is null;
$$;

-- =====================================================================
-- 1. Ana chega primeiro, Bia atrás. O turno da Ana começa no check-in,
--    como a Sprint 5 definiu — é o único turno que depende disso.
-- =====================================================================
do $$
declare
  v_ana uuid;
  v_bia uuid;
  v_e   public.queue_entries;
begin
  v_ana := pg_temp.entra('a6000000-0000-0000-0000-0000000000a6', pg_temp.q1(), 'r-ana-1');

  v_e := pg_temp.vaga_de('a6000000-0000-0000-0000-0000000000a6', pg_temp.q1());
  assert v_e.status = 'ready', format('Ana chamada: %s', v_e.status);
  assert v_e.call_expires_at is null, 'sozinha na fila, sem relógio correndo';
  assert v_e.turn_number = 1, format('primeiro turno: %s', v_e.turn_number);

  v_bia := pg_temp.entra('b6000000-0000-0000-0000-0000000000b6', pg_temp.q1(), 'r-bia-1');

  v_e := pg_temp.vaga_de('a6000000-0000-0000-0000-0000000000a6', pg_temp.q1());
  assert v_e.call_expires_at is not null, 'com fila atrás, a tolerância passa a valer';

  -- Check-in da Ana: o relógio da quadra começa aqui.
  perform pg_temp.as_user('a6000000-0000-0000-0000-0000000000a6');
  perform pg_temp.scan('a6000000-0000-0000-0000-0000000000a6', pg_temp.q1(), 'r-ana-ci');
  perform public.check_in_and_start('r-ana-ci');

  assert pg_temp.em_quadra(pg_temp.q1()) = 'Ana', format('em quadra: %s', pg_temp.em_quadra(pg_temp.q1()));
  assert pg_temp.ordem(pg_temp.q1()) = 'Bia', format('fila: %s', pg_temp.ordem(pg_temp.q1()));
end $$;

-- =====================================================================
-- 2. Acabou o tempo: abre a troca de 1 minuto, a Ana vai para o fim e
--    NINGUÉM entra em quadra ainda
-- =====================================================================
do $$
declare
  v_court public.courts;
  v_nova  public.queue_entries;
  v_tela  jsonb;
  v_res   jsonb;
begin
  perform pg_temp.vence_o_turno(pg_temp.q1());
  v_res := public.advance_expired_queues();

  assert (v_res ->> 'matches_closed')::integer = 1,
    format('um turno encerrado: %s', v_res);
  assert (v_res ->> 'turns_started')::integer = 0,
    format('o próximo não começa no mesmo instante: %s', v_res);

  assert not exists (select 1 from public.matches mt
                     where mt.court_id = pg_temp.q1() and mt.ended_at is null),
    'durante a troca não há partida';

  select * into v_court from public.courts c where c.id = pg_temp.q1();
  assert v_court.changeover_until is not null, 'a troca abriu';
  assert v_court.changeover_until > now(), 'a troca ainda está correndo';
  assert v_court.changeover_until <= now() + interval '61 seconds',
    format('a troca é de 1 minuto: %s', v_court.changeover_until - now());

  -- A Ana voltou para o fim da fila, no segundo turno dela.
  assert pg_temp.ordem(pg_temp.q1()) = 'Bia,Ana', format('fila: %s', pg_temp.ordem(pg_temp.q1()));

  v_nova := pg_temp.vaga_de('a6000000-0000-0000-0000-0000000000a6', pg_temp.q1());
  assert v_nova.turn_number = 2, format('segundo turno da Ana: %s', v_nova.turn_number);
  assert v_nova.requeued_from is not null, 'a vaga nova aponta para a do turno anterior';
  assert v_nova.status = 'waiting', format('status da vaga nova: %s', v_nova.status);
  assert v_nova.first_joined_at < v_nova.joined_at,
    'a hora de chegada original sobrevive à rotação';

  -- O PIN que a Ana passou para os amigos continua valendo.
  assert (select p2.pin from public.queue_entry_pins p2 where p2.entry_id = v_nova.id)
       = (select p1.pin from public.queue_entry_pins p1 where p1.entry_id = v_nova.requeued_from),
    'o PIN do grupo acompanha a rotação';

  -- A Bia foi chamada sem relógio: não há nada que ela precise fazer.
  assert (select e.status from public.queue_entries e
          where e.id = (select qp.entry_id from public.queue_positions qp
                        where qp.court_id = pg_temp.q1() order by qp.position limit 1)) = 'ready',
    'a Bia está chamada';
  assert (select e.call_expires_at from public.queue_entries e
          where e.id = (select qp.entry_id from public.queue_positions qp
                        where qp.court_id = pg_temp.q1() order by qp.position limit 1)) is null,
    'na troca não existe prazo de check-in';

  -- A tela diz o que está acontecendo.
  perform pg_temp.as_user('b6000000-0000-0000-0000-0000000000b6');
  v_tela := public.court_screen(pg_temp.q1());
  assert (v_tela ->> 'is_changeover')::boolean, format('a tela mostra a troca: %s', v_tela ->> 'status_text');
  assert v_tela ->> 'status_text' = 'Troca de grupo', format('status: %s', v_tela ->> 'status_text');
  assert (v_tela -> 'changeover' ->> 'seconds_left')::integer between 1 and 60,
    format('contagem da troca: %s', v_tela -> 'changeover');
  assert (v_tela -> 'changeover' ->> 'next_label') like 'Bia%',
    format('quem entra: %s', v_tela -> 'changeover' ->> 'next_label');
  assert (v_tela -> 'changeover' ->> 'next_is_mine')::boolean, 'a Bia vê que é ela quem entra';
end $$;

-- =====================================================================
-- 3. O Caio chega no meio da troca e entra na fila normalmente
-- =====================================================================
do $$
begin
  perform pg_temp.entra('c6000000-0000-0000-0000-0000000000c6', pg_temp.q1(), 'r-caio-1');
  assert pg_temp.ordem(pg_temp.q1()) = 'Bia,Ana,Caio', format('fila: %s', pg_temp.ordem(pg_temp.q1()));
end $$;

-- Quem não é o primeiro não entra na frente, nem na troca
do $$
declare v_code text;
begin
  perform pg_temp.as_user('c6000000-0000-0000-0000-0000000000c6');
  perform pg_temp.scan('c6000000-0000-0000-0000-0000000000c6', pg_temp.q1(), 'r-caio-furando');
  begin
    perform public.check_in_and_start('r-caio-furando');
    assert false, 'o 3º da fila não entra em quadra';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ015', format('esperava NQ015, obtive %s', v_code);
  end;
end $$;

-- =====================================================================
-- 4. Acabou o minuto: o turno da Bia começa SOZINHO, com o slot inteiro
-- =====================================================================
do $$
declare
  v_res   jsonb;
  v_match public.matches;
  v_court public.courts;
begin
  perform pg_temp.acaba_a_troca(pg_temp.q1());
  v_res := public.advance_expired_queues();

  assert (v_res ->> 'turns_started')::integer = 1,
    format('a quadra começou o turno do próximo sozinha: %s', v_res);
  assert (v_res ->> 'entries_expired')::integer = 0,
    format('ninguém perdeu a vez por não fazer nada: %s', v_res);

  assert pg_temp.em_quadra(pg_temp.q1()) = 'Bia',
    format('em quadra: %s', pg_temp.em_quadra(pg_temp.q1()));
  assert pg_temp.ordem(pg_temp.q1()) = 'Ana,Caio', format('fila: %s', pg_temp.ordem(pg_temp.q1()));

  select * into v_match from public.matches mt
  where mt.court_id = pg_temp.q1() and mt.ended_at is null;
  assert v_match.slot_minutes = 40, format('slot: %s', v_match.slot_minutes);
  assert v_match.expires_at > now() + interval '39 minutes',
    format('o turno da Bia começa inteiro: %s', v_match.expires_at - now());

  select * into v_court from public.courts c where c.id = pg_temp.q1();
  assert v_court.changeover_until is null, 'a troca terminou';
  assert v_court.status = 'in_game', format('status da quadra: %s', v_court.status);

  -- A Bia não fez check-in nenhum: ninguém marcou presença.
  assert not exists (
    select 1 from public.queue_entry_members m
    where m.entry_id = v_match.side_a_entry_id and m.checked_in_at is not null
  ), 'o turno começou sem ninguém fazer check-in';
end $$;

-- =====================================================================
-- 5. A roda continua: a Bia vai para o fim e a Ana volta a jogar
-- =====================================================================
do $$
begin
  perform pg_temp.vence_o_turno(pg_temp.q1());
  perform public.advance_expired_queues();
  assert pg_temp.ordem(pg_temp.q1()) = 'Ana,Caio,Bia', format('fila: %s', pg_temp.ordem(pg_temp.q1()));

  perform pg_temp.acaba_a_troca(pg_temp.q1());
  perform public.advance_expired_queues();
  assert pg_temp.em_quadra(pg_temp.q1()) = 'Ana',
    format('em quadra: %s', pg_temp.em_quadra(pg_temp.q1()));
  assert pg_temp.ordem(pg_temp.q1()) = 'Caio,Bia', format('fila: %s', pg_temp.ordem(pg_temp.q1()));

  -- O segundo turno da Ana é o terceiro turno da vaga dela.
  assert (pg_temp.vaga_de('a6000000-0000-0000-0000-0000000000a6', pg_temp.q1())).turn_number = 2,
    'a Ana está no segundo turno dela';
end $$;

-- =====================================================================
-- 6. Sem ninguém atrás, nada de carrossel: o turno encerra e a quadra
--    libera, como sempre liberou. É o que impede um grupo que foi
--    embora sem sair da fila de segurar a quadra para sempre.
-- =====================================================================
do $$
declare
  v_court public.courts;
  v_tela  jsonb;
begin
  perform pg_temp.entra('d6000000-0000-0000-0000-0000000000d6', pg_temp.q2(), 'r-duda-1');

  perform pg_temp.as_user('d6000000-0000-0000-0000-0000000000d6');
  perform pg_temp.scan('d6000000-0000-0000-0000-0000000000d6', pg_temp.q2(), 'r-duda-ci');
  perform public.check_in_and_start('r-duda-ci');
  assert pg_temp.em_quadra(pg_temp.q2()) = 'Duda', 'a Duda está em quadra';

  perform pg_temp.vence_o_turno(pg_temp.q2());
  perform public.advance_expired_queues();

  select * into v_court from public.courts c where c.id = pg_temp.q2();
  assert v_court.changeover_until is null, 'sem fila atrás, não há troca a fazer';
  assert v_court.status = 'available', format('a quadra liberou: %s', v_court.status);
  assert pg_temp.ordem(pg_temp.q2()) = '', format('fila vazia: %s', pg_temp.ordem(pg_temp.q2()));
  assert not exists (select 1 from public.queue_entries e
                     where e.court_id = pg_temp.q2() and e.requeued_from is not null),
    'ninguém foi recolocado numa fila que não existe';

  v_tela := public.court_screen(pg_temp.q2());
  assert v_tela ->> 'status_text' = 'Livre', format('status: %s', v_tela ->> 'status_text');
end $$;

-- =====================================================================
-- 7. nudge_court: quem está com a tela aberta não espera o cron
-- =====================================================================
do $$
declare
  v_tela jsonb;
begin
  -- Fila na q1: Caio em quadra (turno 5), Bia esperando... conferindo.
  perform pg_temp.vence_o_turno(pg_temp.q1());

  perform pg_temp.as_user('c6000000-0000-0000-0000-0000000000c6');
  v_tela := public.nudge_court(pg_temp.q1());

  assert (v_tela ->> 'is_changeover')::boolean,
    format('o empurrão encerrou o turno vencido e abriu a troca: %s', v_tela ->> 'status_text');

  perform pg_temp.acaba_a_troca(pg_temp.q1());
  v_tela := public.nudge_court(pg_temp.q1());
  assert (v_tela ->> 'is_live')::boolean,
    format('o empurrão começou o turno do próximo: %s', v_tela ->> 'status_text');
  assert not (v_tela ->> 'is_changeover')::boolean, 'a troca terminou';
end $$;

-- Fora de hora, o empurrão não faz nada: não dá para pular a vez
do $$
declare
  v_antes uuid;
  v_depois uuid;
begin
  select mt.id into v_antes from public.matches mt
  where mt.court_id = pg_temp.q1() and mt.ended_at is null;

  perform pg_temp.as_user('b6000000-0000-0000-0000-0000000000b6');
  perform public.nudge_court(pg_temp.q1());
  perform public.nudge_court(pg_temp.q1());

  select mt.id into v_depois from public.matches mt
  where mt.court_id = pg_temp.q1() and mt.ended_at is null;

  assert v_antes = v_depois, 'o turno em andamento não se mexe';
end $$;

-- =====================================================================
-- 8. A espera estimada passa a contar a troca de cada rodada
-- =====================================================================
do $$
declare
  v_tela jsonb;
  v_fila jsonb;
  v_turno integer;
begin
  perform pg_temp.as_user('a6000000-0000-0000-0000-0000000000a6');
  v_tela := public.court_screen(pg_temp.q1());
  v_turno := (v_tela ->> 'turn_seconds')::integer;

  assert v_turno = 40 * 60 + 60, format('uma rodada custa slot + troca: %s', v_turno);

  v_fila := v_tela -> 'queue';
  assert jsonb_array_length(v_fila) >= 2, format('fila com gente: %s', v_fila);

  -- O segundo da fila espera uma rodada inteira mais que o primeiro.
  assert ((v_fila -> 1 ->> 'eta_seconds')::integer - (v_fila -> 0 ->> 'eta_seconds')::integer)
         = v_turno,
    format('a diferença entre posições é uma rodada: %s e %s',
           v_fila -> 0 ->> 'eta_seconds', v_fila -> 1 ->> 'eta_seconds');

  -- E quem está em quadra agora não entra na conta de espera de novo.
  assert (v_tela ->> 'total_wait_seconds')::integer
         >= (v_tela ->> 'remaining_seconds')::integer,
    format('espera total: %s', v_tela ->> 'total_wait_seconds');
end $$;

-- =====================================================================
-- 9. A troca é garantia, não cancela: quem já está em quadra pode
--    começar antes
--
-- O minuto existe para o turno começar sozinho se ninguém fizer nada.
-- Se o grupo da vez toca em "entramos" no meio dele, não há motivo
-- para fazer essa pessoa esperar o cronômetro.
-- =====================================================================
do $$
declare
  v_court public.courts;
  v_match public.matches;
begin
  perform pg_temp.entra('e6000000-0000-0000-0000-0000000000e6', pg_temp.q3(), 'r-edu-1');
  perform pg_temp.entra('f6000000-0000-0000-0000-0000000000f6', pg_temp.q3(), 'r-fe-1');

  -- O Edu joga primeiro.
  perform pg_temp.as_user('e6000000-0000-0000-0000-0000000000e6');
  perform pg_temp.scan('e6000000-0000-0000-0000-0000000000e6', pg_temp.q3(), 'r-edu-ci');
  perform public.check_in_and_start('r-edu-ci');
  assert pg_temp.em_quadra(pg_temp.q3()) = 'Edu', 'o Edu está em quadra';

  -- Acabou o tempo: troca aberta, Edu no fim, Fê chamada sem prazo.
  perform pg_temp.vence_o_turno(pg_temp.q3());
  perform public.advance_expired_queues();

  select * into v_court from public.courts c where c.id = pg_temp.q3();
  assert v_court.changeover_until > now(), 'a troca está correndo';
  assert pg_temp.ordem(pg_temp.q3()) = 'Fê,Edu', format('fila: %s', pg_temp.ordem(pg_temp.q3()));

  -- A Fê já está na quadra e avisa. O turno dela começa agora.
  perform pg_temp.as_user('f6000000-0000-0000-0000-0000000000f6');
  perform pg_temp.scan('f6000000-0000-0000-0000-0000000000f6', pg_temp.q3(), 'r-fe-ci');
  perform public.check_in_and_start('r-fe-ci');

  assert pg_temp.em_quadra(pg_temp.q3()) = 'Fê',
    format('em quadra: %s', pg_temp.em_quadra(pg_temp.q3()));

  select * into v_court from public.courts c where c.id = pg_temp.q3();
  assert v_court.changeover_until is null, 'começar o turno encerra a troca';

  select * into v_match from public.matches mt
  where mt.court_id = pg_temp.q3() and mt.ended_at is null;
  assert v_match.expires_at > now() + interval '39 minutes',
    format('o slot da Fê é inteiro: %s', v_match.expires_at - now());

  -- E o cron depois não arruma nada nem começa turno nenhum.
  assert (public.advance_expired_queues() ->> 'turns_started')::integer = 0,
    'o cron não tem o que fazer';
end $$;

-- =====================================================================
-- 10. A tolerância do PRIMEIRO turno continua existindo
--
-- Quem abre a fila e nunca entra em quadra travaria a fila inteira: é o
-- único lugar onde não aparecer ainda custa a vez (Sprint 5).
-- =====================================================================
do $$
declare
  v_res   jsonb;
  v_duda  public.queue_entries;
begin
  -- A q2 ficou livre e vazia depois do caso 6.
  perform pg_temp.entra('d6000000-0000-0000-0000-0000000000d6', pg_temp.q2(), 'r-duda-2');
  perform pg_temp.entra('96000000-0000-0000-0000-000000000096', pg_temp.q2(), 'r-gabi-1');

  select e.* into v_duda from public.queue_entries e
  join public.queue_entry_members m on m.entry_id = e.id
  where m.user_id = 'd6000000-0000-0000-0000-0000000000d6' and m.is_active
    and e.court_id = pg_temp.q2();
  assert v_duda.call_expires_at is not null,
    'com gente atrás, quem está na frente tem a tolerância para entrar';

  update public.queue_entries set call_expires_at = now() - interval '1 second'
  where id = v_duda.id;

  v_res := public.advance_expired_queues();
  assert (v_res ->> 'entries_expired')::integer = 1, format('a vez passou: %s', v_res);
  assert (select status from public.queue_entries where id = v_duda.id) = 'expired',
    'quem não apareceu perdeu a vez';
end $$;

rollback;

\echo '✔ tests/local/80_rotacao_test.sql — troca de 1 min, rotação automática e espera com a troca'
