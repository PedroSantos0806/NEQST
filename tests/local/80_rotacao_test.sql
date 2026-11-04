-- =====================================================================
-- A chamada do turno: 15 s para aceitar, 30 s para entrar
--
--   acabou o tempo ─▶ quem jogou vai para o FIM da fila
--                  ─▶ chama o 1º por 15 s
--                       ├─ aceitou ─▶ 30 s para entrar ─▶ começa o turno
--                       └─ não ────▶ vai para o fim e chama o seguinte
--
-- Uma volta na fila sem ninguém aceitar libera a quadra.
-- Basta UMA pessoa do grupo aceitar.
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
  ('96000000-0000-0000-0000-000000000096', 'r-gabi@example.com', '{"full_name":"Gabi Atrás"}'),
  ('16000000-0000-0000-0000-000000000016', 'r-admin@example.com', '{"full_name":"Admin Quadra"}'),
  ('26000000-0000-0000-0000-000000000026', 'r-hugo@example.com', '{"full_name":"Hugo Primeiro"}'),
  ('36000000-0000-0000-0000-000000000036', 'r-iris@example.com', '{"full_name":"Iris Atrás"}'),
  ('46000000-0000-0000-0000-000000000046', 'r-joca@example.com', '{"full_name":"Joca Jogando"}'),
  ('56000000-0000-0000-0000-000000000056', 'r-kiko@example.com', '{"full_name":"Kiko Esperando"}'),
  ('66000000-0000-0000-0000-000000000066', 'r-lia@example.com',  '{"full_name":"Lia Esquecida"}'),
  ('76000000-0000-0000-0000-000000000076', 'r-mano@example.com', '{"full_name":"Mano Esquecido"}'),
  ('86000000-0000-0000-0000-000000000086', 'r-nina@example.com', '{"full_name":"Nina Esquecida"}'),
  ('06000000-0000-0000-0000-000000000006', 'r-oli@example.com',  '{"full_name":"Oli Presente"}');

update public.profiles set role = 'admin' where id = '16000000-0000-0000-0000-000000000016';

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
   'teste-rotacao-q3', 'Quadra 03', -23.570200, -46.650200, 'fixed_qr'),
  -- Quadra limpa, sem tablet, para o caso da tolerância do primeiro turno.
  ('d6d60000-0000-0000-0000-0000000000d6', '66660000-0000-0000-0000-000000000006', 4, 'hard', 40,
   'teste-rotacao-q4', 'Quadra 04', -23.570300, -46.650300, 'fixed_qr'),
  -- E outra para a limpeza por inatividade, que precisa de estado próprio.
  ('e6e60000-0000-0000-0000-0000000000e6', '66660000-0000-0000-0000-000000000006', 5, 'hard', 40,
   'teste-rotacao-q5', 'Quadra 05', -23.570400, -46.650400, 'fixed_qr'),
  ('f6f60000-0000-0000-0000-0000000000f6', '66660000-0000-0000-0000-000000000006', 6, 'hard', 40,
   'teste-rotacao-q6', 'Quadra 06', -23.570500, -46.650500, 'fixed_qr');

-- A q1 e a q3 têm tablet aceso; a q2 não tem nenhum, de propósito: é
-- ela que prova que a quadra sem tablet volta para a troca automática.
insert into public.court_devices (court_id, label, token_hash, last_seen_at)
values
  ('a6a60000-0000-0000-0000-0000000000a6', 'tablet q1',
   public.hash_scan_token('tablet-q1-token'), now()),
  ('c6c60000-0000-0000-0000-0000000000c6', 'tablet q3',
   public.hash_scan_token('tablet-q3-token'), now());

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
create or replace function pg_temp.q4() returns uuid language sql as $$
  select 'd6d60000-0000-0000-0000-0000000000d6'::uuid $$;
create or replace function pg_temp.q5() returns uuid language sql as $$
  select 'e6e60000-0000-0000-0000-0000000000e6'::uuid $$;
create or replace function pg_temp.q6() returns uuid language sql as $$
  select 'f6f60000-0000-0000-0000-0000000000f6'::uuid $$;

-- Entrar na fila: o scan e o join, que é o que a pessoa faz ao chegar.
create or replace function pg_temp.entra(p_user uuid, p_court uuid, p_token text)
returns uuid language plpgsql as $$
begin
  perform pg_temp.as_user(p_user);
  perform pg_temp.scan(p_user, p_court, p_token);
  return (public.join_queue(p_token) ->> 'entry_id')::uuid;
end $$;

-- Os relógios, empurrados para trás. É o que o tempo real faria.
create or replace function pg_temp.vence_o_turno(p_court uuid)
returns void language sql as $$
  update public.matches set expires_at = now() - interval '1 second'
  where court_id = p_court and ended_at is null;
$$;

create or replace function pg_temp.vence_a_chamada(p_court uuid)
returns void language sql as $$
  update public.courts set handover_until = now() - interval '1 second'
  where id = p_court and handover_until is not null;
$$;

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

-- Quem está sendo chamado agora, pelo primeiro nome.
create or replace function pg_temp.chamando(p_court uuid)
returns text language sql as $$
  select coalesce(
    (select split_part(coalesce(pr.full_name, coalesce(e.offline_label, 'sem app')), ' ', 1)
       from public.courts c
       join public.queue_entries e on e.id = c.handover_entry_id
       left join public.queue_entry_members m
              on m.entry_id = e.id and m.is_active and m.role = 'owner'
       left join public.profiles pr on pr.id = m.user_id
      where c.id = p_court and c.handover_phase = 'calling'),
    'ninguém');
$$;

-- =====================================================================
-- 1. Ana chega primeiro, Bia atrás. O primeiro turno de uma fila ainda
--    começa no check-in — ninguém foi chamado por nada ainda.
-- =====================================================================
do $$
declare v_e public.queue_entries;
begin
  perform pg_temp.entra('a6000000-0000-0000-0000-0000000000a6', pg_temp.q1(), 'r-ana-1');

  v_e := pg_temp.vaga_de('a6000000-0000-0000-0000-0000000000a6', pg_temp.q1());
  assert v_e.status = 'ready', format('Ana chamada: %s', v_e.status);
  assert v_e.call_expires_at is null, 'sozinha na fila, sem relógio correndo';
  assert v_e.turn_number = 1, format('primeiro turno: %s', v_e.turn_number);

  perform pg_temp.entra('b6000000-0000-0000-0000-0000000000b6', pg_temp.q1(), 'r-bia-1');

  v_e := pg_temp.vaga_de('a6000000-0000-0000-0000-0000000000a6', pg_temp.q1());
  assert v_e.call_expires_at is not null, 'com fila atrás, a tolerância passa a valer';

  perform pg_temp.as_user('a6000000-0000-0000-0000-0000000000a6');
  perform pg_temp.scan('a6000000-0000-0000-0000-0000000000a6', pg_temp.q1(), 'r-ana-ci');
  perform public.check_in_and_start('r-ana-ci');

  assert pg_temp.em_quadra(pg_temp.q1()) = 'Ana', format('em quadra: %s', pg_temp.em_quadra(pg_temp.q1()));
  assert pg_temp.ordem(pg_temp.q1()) = 'Bia', format('fila: %s', pg_temp.ordem(pg_temp.q1()));
end $$;

-- =====================================================================
-- 2. Acabou o tempo: a Ana vai para o fim e a quadra CHAMA a Bia por
--    15 segundos. Ninguém entra em quadra ainda.
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

  assert (v_res ->> 'matches_closed')::integer = 1, format('um turno encerrado: %s', v_res);
  assert (v_res ->> 'turns_started')::integer = 0,
    format('ninguém entra em quadra sem aceitar: %s', v_res);

  assert not exists (select 1 from public.matches mt
                     where mt.court_id = pg_temp.q1() and mt.ended_at is null),
    'durante a chamada não há partida';

  select * into v_court from public.courts c where c.id = pg_temp.q1();
  assert v_court.handover_phase = 'calling', format('fase: %s', v_court.handover_phase);
  assert v_court.handover_until > now(), 'a chamada está correndo';
  assert v_court.handover_until <= now() + interval '16 seconds',
    format('a chamada é de 15 s: %s', v_court.handover_until - now());
  assert pg_temp.chamando(pg_temp.q1()) = 'Bia', format('chamando: %s', pg_temp.chamando(pg_temp.q1()));

  -- A fila inteira tem 2 grupos: é o tamanho de uma volta de chamadas.
  assert v_court.handover_calls_left = 2, format('volta de 2 chamadas: %s', v_court.handover_calls_left);

  -- A Ana voltou para o fim da fila, no segundo turno dela.
  assert pg_temp.ordem(pg_temp.q1()) = 'Bia,Ana', format('fila: %s', pg_temp.ordem(pg_temp.q1()));

  v_nova := pg_temp.vaga_de('a6000000-0000-0000-0000-0000000000a6', pg_temp.q1());
  assert v_nova.turn_number = 2, format('segundo turno da Ana: %s', v_nova.turn_number);
  assert v_nova.requeued_from is not null, 'a vaga nova aponta para a do turno anterior';
  assert v_nova.first_joined_at < v_nova.joined_at,
    'a hora de chegada original sobrevive à rotação';
  assert (select p2.pin from public.queue_entry_pins p2 where p2.entry_id = v_nova.id)
       = (select p1.pin from public.queue_entry_pins p1 where p1.entry_id = v_nova.requeued_from),
    'o PIN do grupo acompanha a rotação';

  -- A Bia recebeu o push da vez.
  assert exists (
    select 1 from public.notification_outbox o
    where o.user_id = 'b6000000-0000-0000-0000-0000000000b6' and o.type = 'queue_turn'
  ), 'quem foi chamado recebe push, não só o grito do tablet';

  -- A tela diz o que está acontecendo, e com que nomes falar.
  perform pg_temp.as_user('b6000000-0000-0000-0000-0000000000b6');
  v_tela := public.court_screen(pg_temp.q1());
  assert (v_tela ->> 'is_handover')::boolean, format('a tela mostra a chamada: %s', v_tela);
  assert v_tela ->> 'status_text' = 'Chamando o próximo', format('status: %s', v_tela ->> 'status_text');
  assert v_tela -> 'handover' ->> 'phase' = 'calling', format('fase: %s', v_tela -> 'handover');
  assert (v_tela -> 'handover' ->> 'seconds_left')::integer between 1 and 15,
    format('contagem da chamada: %s', v_tela -> 'handover');
  assert (v_tela -> 'handover' ->> 'label') like 'Bia%',
    format('quem é chamado: %s', v_tela -> 'handover' ->> 'label');
  assert (v_tela -> 'handover' ->> 'spoken_names') like 'Bia%',
    format('o nome a falar: %s', v_tela -> 'handover' ->> 'spoken_names');
  assert (v_tela -> 'handover' ->> 'is_mine')::boolean, 'a Bia vê que é ela';
end $$;

-- O Caio chega no meio da chamada e entra na fila normalmente
do $$
begin
  perform pg_temp.entra('c6000000-0000-0000-0000-0000000000c6', pg_temp.q1(), 'r-caio-1');
  assert pg_temp.ordem(pg_temp.q1()) = 'Bia,Ana,Caio', format('fila: %s', pg_temp.ordem(pg_temp.q1()));
end $$;

-- =====================================================================
-- 3. A Bia não aperta JOGAR em 15 s: vai para o fim e a chamada desce
-- =====================================================================
do $$
declare
  v_res   jsonb;
  v_court public.courts;
  v_bia   public.queue_entries;
begin
  perform pg_temp.vence_a_chamada(pg_temp.q1());
  v_res := public.advance_expired_queues();

  assert (v_res ->> 'calls_skipped')::integer = 1, format('uma chamada passou: %s', v_res);
  assert (v_res ->> 'turns_started')::integer = 0, 'e ninguém entrou em quadra';

  assert pg_temp.chamando(pg_temp.q1()) = 'Ana',
    format('agora chama a Ana: %s', pg_temp.chamando(pg_temp.q1()));
  assert pg_temp.ordem(pg_temp.q1()) = 'Ana,Caio,Bia', format('fila: %s', pg_temp.ordem(pg_temp.q1()));

  -- A Bia perdeu a posição, não a vaga — e o turno dela não contou.
  v_bia := pg_temp.vaga_de('b6000000-0000-0000-0000-0000000000b6', pg_temp.q1());
  assert v_bia.turn_number = 1, format('não jogou, o turno não conta: %s', v_bia.turn_number);
  assert (select cancel_reason from public.queue_entries where id = v_bia.requeued_from) = 'no_answer',
    'fica registrado que a chamada não foi respondida';

  select * into v_court from public.courts c where c.id = pg_temp.q1();
  -- A volta começou com 2 grupos na fila (Bia e Ana); o Caio chegou
  -- depois e entra na volta seguinte. Gasta uma chamada, resta uma: a
  -- da Ana, que está correndo agora.
  assert v_court.handover_calls_left = 1, format('resta 1 chamada na volta: %s', v_court.handover_calls_left);
  assert v_court.handover_until > now(), 'a chamada da Ana tem os 15 s inteiros';
end $$;

-- =====================================================================
-- 4. A Ana aperta JOGAR: 30 segundos para entrar, e aí começa o tempo
-- =====================================================================
do $$
declare
  v_court public.courts;
  v_tela  jsonb;
  v_match public.matches;
  v_res   jsonb;
begin
  perform pg_temp.as_user('a6000000-0000-0000-0000-0000000000a6');
  v_tela := public.accept_turn(pg_temp.q1());

  assert v_tela -> 'handover' ->> 'phase' = 'entering',
    format('aceitou, está entrando: %s', v_tela -> 'handover');
  assert (v_tela -> 'handover' ->> 'seconds_left')::integer between 1 and 30,
    format('30 s para entrar: %s', v_tela -> 'handover');
  assert v_tela ->> 'status_text' = 'Entrando na quadra', format('status: %s', v_tela ->> 'status_text');
  assert not (v_tela ->> 'is_live')::boolean, 'o tempo de quadra ainda não começou';

  -- Apertar de novo não atrasa nem adianta.
  v_tela := public.accept_turn(pg_temp.q1());
  assert v_tela -> 'handover' ->> 'phase' = 'entering', 'segue entrando';

  -- Ficou gravado quem respondeu pelo grupo.
  assert (select accepted_by from public.queue_entries
           where id = (v_tela -> 'handover' ->> 'entry_id')::uuid)
         = 'a6000000-0000-0000-0000-0000000000a6', 'quem aceitou fica registrado';

  -- Acabaram os 30 s: o tempo de quadra começa, inteiro.
  perform pg_temp.vence_a_chamada(pg_temp.q1());
  v_res := public.advance_expired_queues();
  assert (v_res ->> 'turns_started')::integer = 1, format('o turno começou: %s', v_res);

  assert pg_temp.em_quadra(pg_temp.q1()) = 'Ana', format('em quadra: %s', pg_temp.em_quadra(pg_temp.q1()));
  assert pg_temp.ordem(pg_temp.q1()) = 'Caio,Bia', format('fila: %s', pg_temp.ordem(pg_temp.q1()));

  select * into v_match from public.matches mt
  where mt.court_id = pg_temp.q1() and mt.ended_at is null;
  assert v_match.expires_at > now() + interval '39 minutes',
    format('o turno da Ana começa inteiro: %s', v_match.expires_at - now());

  select * into v_court from public.courts c where c.id = pg_temp.q1();
  assert v_court.handover_phase is null, 'a chamada terminou';
  assert v_court.handover_calls_left = 0, 'a volta da fila recomeça do zero na próxima';
  assert v_court.status = 'in_game', format('status da quadra: %s', v_court.status);

  -- O turno começou pelo JOGAR, não por check-in. A marca de check-in
  -- da Ana vem do primeiro turno dela e viaja com a vaga de propósito
  -- (Sprint 6), para a tela não voltar a pedir check-in de quem já
  -- provou que está na quadra. Quem prova que não precisa de check-in
  -- nenhum é o Caio, no caso 5: ele nunca fez um.
  assert (select accepted_at from public.queue_entries where id = v_match.side_a_entry_id)
         is not null,
    'o que começou o turno foi o aceite da chamada';
end $$;

-- =====================================================================
-- 5. Quem não é do grupo chamado não aceita por ele
-- =====================================================================
do $$
declare v_code text;
begin
  perform pg_temp.vence_o_turno(pg_temp.q1());
  perform public.advance_expired_queues();
  assert pg_temp.chamando(pg_temp.q1()) = 'Caio', format('chamando: %s', pg_temp.chamando(pg_temp.q1()));

  -- A Bia está na fila, mas a vez é do Caio.
  perform pg_temp.as_user('b6000000-0000-0000-0000-0000000000b6');
  begin
    perform public.accept_turn(pg_temp.q1());
    assert false, 'quem não é do grupo chamado não deveria aceitar';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ008', format('esperava NQ008, obtive %s', v_code);
  end;

  -- O admin pode: é a operação do parque resolvendo na quadra.
  perform pg_temp.as_user('16000000-0000-0000-0000-000000000016');
  perform public.accept_turn(pg_temp.q1());
  assert (select handover_phase from public.courts where id = pg_temp.q1()) = 'entering',
    'a operação aceitou pelo grupo';

  perform pg_temp.vence_a_chamada(pg_temp.q1());
  perform public.advance_expired_queues();
  assert pg_temp.em_quadra(pg_temp.q1()) = 'Caio', format('em quadra: %s', pg_temp.em_quadra(pg_temp.q1()));

  -- O Caio entrou na fila e jogou sem fazer check-in nenhum: uma pessoa
  -- apertou JOGAR por ele, e bastou.
  assert not exists (
    select 1 from public.queue_entry_members m
    join public.matches mt on mt.side_a_entry_id = m.entry_id
    where mt.court_id = pg_temp.q1() and mt.ended_at is null and m.checked_in_at is not null
  ), 'o turno do Caio começou sem check-in de ninguém';
end $$;

-- =====================================================================
-- 6. A volta inteira sem ninguém aceitar libera a quadra
-- =====================================================================
do $$
declare
  v_court public.courts;
  v_tela  jsonb;
begin
  -- Fila na q1: Bia e Ana esperando, Caio em quadra.
  assert pg_temp.ordem(pg_temp.q1()) = 'Bia,Ana', format('fila: %s', pg_temp.ordem(pg_temp.q1()));

  perform pg_temp.vence_o_turno(pg_temp.q1());
  perform public.advance_expired_queues();
  -- Agora a fila tem 3 (Bia, Ana, Caio) e a volta tem 3 chamadas.
  assert (select handover_calls_left from public.courts where id = pg_temp.q1()) = 3,
    'a volta cobre a fila inteira';

  -- Ninguém aceita, três vezes.
  for i in 1..3 loop
    perform pg_temp.vence_a_chamada(pg_temp.q1());
    perform public.advance_expired_queues();
  end loop;

  select * into v_court from public.courts c where c.id = pg_temp.q1();
  assert v_court.handover_phase is null, format('a chamada parou: %s', v_court.handover_phase);
  assert v_court.handover_calls_left = 0, 'a volta terminou';
  assert v_court.status = 'available', format('a quadra ficou livre: %s', v_court.status);

  v_tela := public.court_screen(pg_temp.q1());
  assert not (v_tela ->> 'is_handover')::boolean, 'o tablet para de chamar';

  -- Ninguém perdeu a vaga: todos seguem na fila, só mudaram de lugar.
  assert pg_temp.ordem(pg_temp.q1()) = 'Bia,Ana,Caio',
    format('fila intacta, na mesma ordem relativa: %s', pg_temp.ordem(pg_temp.q1()));
end $$;

-- E o JOGAR volta a andar com a quadra livre: começa o turno na hora
do $$
declare v_tela jsonb;
begin
  perform pg_temp.as_user('b6000000-0000-0000-0000-0000000000b6');
  v_tela := public.accept_turn(pg_temp.q1());
  assert (v_tela ->> 'is_live')::boolean, format('a Bia entrou em quadra: %s', v_tela ->> 'status_text');
  assert pg_temp.em_quadra(pg_temp.q1()) = 'Bia', format('em quadra: %s', pg_temp.em_quadra(pg_temp.q1()));
end $$;

-- =====================================================================
-- 7. Sem ninguém atrás, nada de chamada: o turno encerra e a quadra
--    libera, como sempre liberou
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
  assert v_court.handover_phase is null, 'sem fila atrás, não há quem chamar';
  assert v_court.status = 'available', format('a quadra liberou: %s', v_court.status);
  assert pg_temp.ordem(pg_temp.q2()) = '', format('fila vazia: %s', pg_temp.ordem(pg_temp.q2()));
  assert not exists (select 1 from public.queue_entries e
                     where e.court_id = pg_temp.q2() and e.requeued_from is not null),
    'ninguém foi recolocado numa fila que não existe';

  v_tela := public.court_screen(pg_temp.q2());
  assert v_tela ->> 'status_text' = 'Livre', format('status: %s', v_tela ->> 'status_text');
end $$;

-- =====================================================================
-- 7b. Quadra SEM tablet: volta a ser a troca automática de 1 minuto
--
-- Chamar por 15 s sem ninguém para gritar o nome embaralharia a fila
-- por nada. Sem tablet, o turno do próximo começa sozinho, como na
-- Sprint 6 — e ninguém precisa tocar em nada.
-- =====================================================================
do $$
declare
  v_court public.courts;
  v_tela  jsonb;
begin
  perform pg_temp.entra('d6000000-0000-0000-0000-0000000000d6', pg_temp.q2(), 'r-duda-sem-tablet');
  perform pg_temp.entra('96000000-0000-0000-0000-000000000096', pg_temp.q2(), 'r-gabi-sem-tablet');

  perform pg_temp.as_user('d6000000-0000-0000-0000-0000000000d6');
  perform pg_temp.scan('d6000000-0000-0000-0000-0000000000d6', pg_temp.q2(), 'r-duda-ci2');
  perform public.check_in_and_start('r-duda-ci2');

  v_tela := public.court_screen(pg_temp.q2());
  assert not (v_tela -> 'court' ->> 'has_tablet')::boolean, 'a q2 não tem tablet';

  perform pg_temp.vence_o_turno(pg_temp.q2());
  perform public.advance_expired_queues();

  select * into v_court from public.courts c where c.id = pg_temp.q2();
  assert v_court.handover_phase = 'changeover',
    format('sem tablet, troca automática: %s', v_court.handover_phase);
  assert v_court.handover_until <= now() + interval '61 seconds',
    format('a troca é de 1 minuto: %s', v_court.handover_until - now());

  -- E começa sozinha, sem JOGAR de ninguém.
  perform pg_temp.vence_a_chamada(pg_temp.q2());
  assert (public.advance_expired_queues() ->> 'turns_started')::integer = 1,
    'o turno do próximo começou sozinho';
  assert pg_temp.em_quadra(pg_temp.q2()) = 'Gabi',
    format('em quadra: %s', pg_temp.em_quadra(pg_temp.q2()));

end $$;

-- =====================================================================
-- 8. nudge_court: o tablet não espera o cron para a chamada descer
-- =====================================================================
do $$
declare v_tela jsonb;
begin
  perform pg_temp.entra('e6000000-0000-0000-0000-0000000000e6', pg_temp.q3(), 'r-edu-1');
  perform pg_temp.entra('f6000000-0000-0000-0000-0000000000f6', pg_temp.q3(), 'r-fe-1');

  perform pg_temp.as_user('e6000000-0000-0000-0000-0000000000e6');
  perform pg_temp.scan('e6000000-0000-0000-0000-0000000000e6', pg_temp.q3(), 'r-edu-ci');
  perform public.check_in_and_start('r-edu-ci');

  perform pg_temp.vence_o_turno(pg_temp.q3());
  v_tela := public.nudge_court(pg_temp.q3());
  assert (v_tela ->> 'is_handover')::boolean,
    format('o empurrão encerrou o turno e abriu a chamada: %s', v_tela ->> 'status_text');
  assert pg_temp.chamando(pg_temp.q3()) = 'Fê', format('chamando: %s', pg_temp.chamando(pg_temp.q3()));

  perform pg_temp.as_user('f6000000-0000-0000-0000-0000000000f6');
  perform public.accept_turn(pg_temp.q3());
  perform pg_temp.vence_a_chamada(pg_temp.q3());
  v_tela := public.nudge_court(pg_temp.q3());
  assert (v_tela ->> 'is_live')::boolean,
    format('o empurrão começou o turno: %s', v_tela ->> 'status_text');
end $$;

-- Fora de hora, o empurrão não faz nada: não dá para pular a vez
do $$
declare v_antes uuid; v_depois uuid;
begin
  select mt.id into v_antes from public.matches mt
  where mt.court_id = pg_temp.q3() and mt.ended_at is null;

  perform pg_temp.as_user('e6000000-0000-0000-0000-0000000000e6');
  perform public.nudge_court(pg_temp.q3());
  perform public.nudge_court(pg_temp.q3());

  select mt.id into v_depois from public.matches mt
  where mt.court_id = pg_temp.q3() and mt.ended_at is null;
  assert v_antes = v_depois, 'o turno em andamento não se mexe';
end $$;

-- =====================================================================
-- 9. A espera estimada conta a chamada e a entrada de cada rodada
-- =====================================================================
do $$
declare
  v_tela  jsonb;
  v_fila  jsonb;
  v_turno integer;
begin
  perform pg_temp.as_user('e6000000-0000-0000-0000-0000000000e6');
  v_tela := public.court_screen(pg_temp.q3());
  v_turno := (v_tela ->> 'turn_seconds')::integer;

  assert v_turno = 40 * 60 + 15 + 30,
    format('uma rodada custa turno + chamada + entrada: %s', v_turno);

  v_fila := v_tela -> 'queue';
  assert jsonb_array_length(v_fila) >= 1, format('fila com gente: %s', v_fila);
  assert (v_tela ->> 'total_wait_seconds')::integer
         >= (v_tela ->> 'remaining_seconds')::integer,
    format('espera total: %s', v_tela ->> 'total_wait_seconds');
end $$;

-- =====================================================================
-- 10. A tolerância do PRIMEIRO turno continua existindo
--
-- Quem abre a fila e nunca entra em quadra travaria a fila inteira: é o
-- único lugar onde não aparecer ainda custa a vaga (Sprint 5).
-- =====================================================================
do $$
declare
  v_res  jsonb;
  v_hugo public.queue_entries;
begin
  perform pg_temp.entra('26000000-0000-0000-0000-000000000026', pg_temp.q4(), 'r-hugo-1');
  perform pg_temp.entra('36000000-0000-0000-0000-000000000036', pg_temp.q4(), 'r-iris-1');

  select e.* into v_hugo from public.queue_entries e
  join public.queue_entry_members m on m.entry_id = e.id
  where m.user_id = '26000000-0000-0000-0000-000000000026' and m.is_active
    and e.court_id = pg_temp.q4();
  assert v_hugo.call_expires_at is not null,
    'com gente atrás, quem está na frente tem a tolerância para entrar';

  update public.queue_entries set call_expires_at = now() - interval '1 second'
  where id = v_hugo.id;

  v_res := public.advance_expired_queues();
  assert (v_res ->> 'entries_expired')::integer = 1, format('a vez passou: %s', v_res);
  assert (select status from public.queue_entries where id = v_hugo.id) = 'expired',
    'quem não apareceu perdeu a vez';
end $$;

-- =====================================================================
-- 11. O admin corrige o relógio do turno em andamento
-- =====================================================================
do $$
declare
  v_match public.matches;
  v_code  text;
  v_tela  jsonb;
begin
  select * into v_match from public.matches mt
  where mt.court_id = pg_temp.q3() and mt.ended_at is null;
  assert v_match.id is not null, 'tem turno em andamento na q3';

  perform pg_temp.as_user('e6000000-0000-0000-0000-0000000000e6');
  begin
    perform public.admin_set_match_time(v_match.id, 10);
    assert false, 'jogador comum não ajusta o tempo';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ023', format('esperava NQ023, obtive %s', v_code);
  end;

  perform pg_temp.as_user('16000000-0000-0000-0000-000000000016');

  begin
    perform public.admin_set_match_time(v_match.id, 999);
    assert false, '999 minutos deveria ser recusado';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ036', format('esperava NQ036, obtive %s', v_code);
  end;

  v_tela := public.admin_set_match_time(v_match.id, 12);
  assert (v_tela -> 'match' ->> 'remaining_seconds')::integer between 700 and 720,
    format('faltam ~12 min: %s', v_tela -> 'match' ->> 'remaining_seconds');
  assert (v_tela -> 'match' ->> 'time_adjusted_at') is not null,
    'o ajuste fica visível na tela de todo mundo';

  v_tela := public.admin_set_match_time(v_match.id, 12);
  assert (v_tela -> 'match' ->> 'remaining_seconds')::integer between 700 and 720,
    format('repetir não soma: %s', v_tela -> 'match' ->> 'remaining_seconds');

  select * into v_match from public.matches mt where mt.id = v_match.id;
  assert v_match.time_adjusted_by = '16000000-0000-0000-0000-000000000016',
    'quem mexeu no relógio fica registrado';
end $$;

-- Zerar o tempo encerra o turno agora, e a quadra passa a chamar
do $$
declare v_match uuid; v_tela jsonb;
begin
  select mt.id into v_match from public.matches mt
  where mt.court_id = pg_temp.q3() and mt.ended_at is null;

  perform pg_temp.as_user('16000000-0000-0000-0000-000000000016');
  v_tela := public.admin_set_match_time(v_match, 0);

  assert not (v_tela ->> 'is_live')::boolean, 'o turno encerrou na hora';
  assert (v_tela ->> 'is_handover')::boolean,
    format('a quadra começou a chamar: %s', v_tela ->> 'status_text');
  assert (select end_reason from public.matches where id = v_match) = 'slot_expired',
    'encerrou como fim de tempo';
  assert pg_temp.chamando(pg_temp.q3()) = 'Edu', format('chamando: %s', pg_temp.chamando(pg_temp.q3()));
end $$;

-- Turno já encerrado não se ajusta
do $$
declare v_match uuid; v_code text;
begin
  select mt.id into v_match from public.matches mt
  where mt.court_id = pg_temp.q3() and mt.ended_at is not null
  order by mt.ended_at desc limit 1;

  perform pg_temp.as_user('16000000-0000-0000-0000-000000000016');
  begin
    perform public.admin_set_match_time(v_match, 20);
    assert false, 'turno encerrado não volta';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ009', format('esperava NQ009, obtive %s', v_code);
  end;
end $$;

-- =====================================================================
-- 12. O admin tira da fila quem foi embora sem avisar
-- =====================================================================
do $$
declare
  v_iris uuid;
  v_code text;
begin
  select e.id into v_iris from public.queue_entries e
  join public.queue_entry_members m on m.entry_id = e.id
  where m.user_id = '36000000-0000-0000-0000-000000000036' and m.is_active
    and e.court_id = pg_temp.q4() and e.status in ('waiting', 'ready');
  assert v_iris is not null, 'a Iris está na fila da q4';

  -- Jogador comum não remove ninguém.
  perform pg_temp.as_user('26000000-0000-0000-0000-000000000026');
  begin
    perform public.leave_queue(v_iris, 'sumiu');
    assert false, 'jogador comum não remove outro grupo';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ008', format('esperava NQ008, obtive %s', v_code);
  end;

  perform pg_temp.as_user('16000000-0000-0000-0000-000000000016');
  perform public.leave_queue(v_iris, 'removido_pelo_admin');

  assert (select status from public.queue_entries where id = v_iris) = 'cancelled',
    'a vaga saiu da fila';
  assert (select cancel_reason from public.queue_entries where id = v_iris) = 'removido_pelo_admin',
    'com o motivo gravado';
  assert not exists (
    select 1 from public.queue_entry_members m
    where m.entry_id = v_iris and m.is_active
  ), 'e a pessoa está livre para entrar em outra fila';
end $$;

-- =====================================================================
-- 13. O tablet: identidade própria, e só duas coisas a fazer
-- =====================================================================
do $$
declare
  v_novo  jsonb;
  v_token text;
  v_tela  jsonb;
  v_code  text;
begin
  -- Só o admin gera o link.
  perform pg_temp.as_user('e6000000-0000-0000-0000-0000000000e6');
  begin
    perform public.admin_create_court_device(pg_temp.q4(), 'tablet da q4');
    assert false, 'jogador comum não gera link de tablet';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ023', format('esperava NQ023, obtive %s', v_code);
  end;

  perform pg_temp.as_user('16000000-0000-0000-0000-000000000016');
  v_novo := public.admin_create_court_device(pg_temp.q4(), 'tablet da q4');
  v_token := v_novo ->> 'token';

  assert length(v_token) = 64, format('token de 32 bytes em hex: %s', length(v_token));
  assert v_novo ->> 'path' = '/tablet/' || v_token, format('o caminho do link: %s', v_novo ->> 'path');

  -- O banco não guarda o token, só o hash.
  assert not exists (
    select 1 from public.court_devices d where d.token_hash = v_token
  ), 'o token em claro não fica no banco';
  assert exists (
    select 1 from public.court_devices d
    where d.token_hash = public.hash_scan_token(v_token)
  ), 'o hash fica';

  -- O tablet lê a quadra sem estar logado como ninguém.
  perform set_config('request.jwt.claim.sub', '', true);
  v_tela := public.tablet_screen(v_token);
  assert v_tela -> 'court' ->> 'id' = pg_temp.q4()::text, format('a quadra certa: %s', v_tela -> 'court');
  assert v_tela -> 'device' ->> 'label' = 'tablet da q4', format('o aparelho: %s', v_tela -> 'device');

  -- E ler marca o aparelho como vivo: é isso que liga a chamada por nome.
  assert (select last_seen_at from public.court_devices
           where id = (v_novo ->> 'device_id')::uuid) is not null,
    'a leitura marca o tablet como aceso';
  assert public.court_tablet_awake(pg_temp.q4()), 'agora a q4 tem quem grite os nomes';

  -- Token inventado não abre nada.
  begin
    perform public.tablet_screen('nao-sou-um-token');
    assert false, 'token inválido deveria ser recusado';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ037', format('esperava NQ037, obtive %s', v_code);
  end;

  -- Revogado para de funcionar.
  perform pg_temp.as_user('16000000-0000-0000-0000-000000000016');
  perform public.admin_revoke_court_device((v_novo ->> 'device_id')::uuid);
  perform set_config('request.jwt.claim.sub', '', true);
  begin
    perform public.tablet_screen(v_token);
    assert false, 'tablet revogado deveria ser recusado';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ037', format('esperava NQ037, obtive %s', v_code);
  end;
end $$;

-- O JOGAR do tablet aceita a vez de quem está sendo chamado
do $$
declare
  v_token text;
  v_tela  jsonb;
begin
  perform pg_temp.as_user('16000000-0000-0000-0000-000000000016');
  v_token := public.admin_create_court_device(pg_temp.q1(), 'tablet novo da q1') ->> 'token';

  -- A q1 está com a Bia em quadra (caso 6). Acaba o tempo: a quadra
  -- chama, e o tablet responde por quem está lá.
  perform pg_temp.vence_o_turno(pg_temp.q1());

  perform set_config('request.jwt.claim.sub', '', true);
  v_tela := public.tablet_screen(v_token);
  assert (v_tela ->> 'is_handover')::boolean,
    format('o tablet abriu a chamada: %s', v_tela ->> 'status_text');
  assert v_tela -> 'handover' ->> 'phase' = 'calling', format('fase: %s', v_tela -> 'handover');
  assert (v_tela -> 'handover' ->> 'spoken_names') is not null, 'tem nome para falar';

  v_tela := public.tablet_accept_turn(v_token);
  assert v_tela -> 'handover' ->> 'phase' = 'entering',
    format('o tablet aceitou pelo grupo: %s', v_tela -> 'handover');

  -- Ninguém com conta aceitou: foi o aparelho.
  assert (select accepted_by from public.queue_entries
           where id = (v_tela -> 'handover' ->> 'entry_id')::uuid) is null,
    'o aceite do tablet não tem pessoa atrás';
  assert (select accepted_at from public.queue_entries
           where id = (v_tela -> 'handover' ->> 'entry_id')::uuid) is not null,
    'mas fica registrado que houve aceite';

  perform pg_temp.vence_a_chamada(pg_temp.q1());
  v_tela := public.tablet_screen(v_token);
  assert (v_tela ->> 'is_live')::boolean, format('o turno começou: %s', v_tela ->> 'status_text');
end $$;

-- =====================================================================
-- 14. A limpeza por inatividade não pode expulsar quem só esperou, nem
--     deixar a quadra travada
--
-- A auditoria reproduziu os dois defeitos: um grupo que esperou 3h numa
-- fila movimentada era marcado `expired`, e expirar um grupo `ready`
-- deixava a quadra `available` com gente em `waiting` e ninguém para
-- chamar — inutilizável até alguém rodar call_next_team à mão.
-- =====================================================================
do $$
declare
  v_kiko uuid;
  v_saiu integer;
begin
  -- Fila viva na q5: o Joca em quadra e o Kiko esperando há 4 horas.
  perform pg_temp.entra('46000000-0000-0000-0000-000000000046', pg_temp.q5(), 'r-joca-1');
  perform pg_temp.as_user('46000000-0000-0000-0000-000000000046');
  perform pg_temp.scan('46000000-0000-0000-0000-000000000046', pg_temp.q5(), 'r-joca-ci');
  perform public.check_in_and_start('r-joca-ci');
  assert pg_temp.em_quadra(pg_temp.q5()) = 'Joca', 'o Joca está em quadra';

  perform pg_temp.entra('56000000-0000-0000-0000-000000000056', pg_temp.q5(), 'r-kiko-1');

  select e.id into v_kiko from public.queue_entries e
  join public.queue_entry_members m on m.entry_id = e.id
  where m.user_id = '56000000-0000-0000-0000-000000000056' and m.is_active
    and e.court_id = pg_temp.q5();

  update public.queue_entries
     set first_joined_at = now() - interval '4 hours',
         joined_at = now() - interval '4 hours',
         called_at = null
   where court_id = pg_temp.q5() and status in ('waiting', 'ready');

  v_saiu := public.expire_stale_queue_entries('3 hours');

  assert v_saiu = 0, format(
    'com alguém em quadra, esperar 4 h é o normal de uma fila movimentada: %s saíram', v_saiu);
  assert (select status from public.queue_entries where id = v_kiko)
         in ('waiting', 'ready'),
    'quem esperou não é expulso';
end $$;

-- Já numa quadra parada, sem ninguém chamado, a vaga esquecida sai —
-- e a fila ANDA
do $$
declare
  v_court public.courts;
  v_saiu  integer;
begin
  -- Quadra parada: dois grupos que chegaram há 4 horas, ninguém em
  -- quadra, ninguém chamado. Esses sim foram embora.
  perform pg_temp.entra('66000000-0000-0000-0000-000000000066', pg_temp.q6(), 'r-lia-1');
  perform pg_temp.entra('76000000-0000-0000-0000-000000000076', pg_temp.q6(), 'r-mano-1');

  update public.queue_entries
     set first_joined_at = now() - interval '4 hours',
         joined_at = now() - interval '4 hours',
         called_at = null,
         status = 'waiting',
         call_expires_at = null
   where court_id = pg_temp.q6() and status in ('waiting', 'ready');

  v_saiu := public.expire_stale_queue_entries('3 hours');
  assert v_saiu = 2, format('as duas vagas esquecidas saem: %s', v_saiu);

  select * into v_court from public.courts c where c.id = pg_temp.q6();
  assert v_court.status = 'available', format('a quadra fica livre: %s', v_court.status);
  assert pg_temp.ordem(pg_temp.q6()) = '', format('e a fila vazia: %s', pg_temp.ordem(pg_temp.q6()));
end $$;

-- Com fila atrás, expirar o grupo chamado passa a vez em vez de travar
do $$
declare
  v_nina  uuid;
  v_saiu  integer;
  v_court public.courts;
begin
  -- A q6 está vazia depois do bloco acima. Nina chegou há 4 horas e
  -- nunca foi chamada; Oli chegou agora e está ali.
  perform pg_temp.entra('86000000-0000-0000-0000-000000000086', pg_temp.q6(), 'r-nina-1');
  perform pg_temp.entra('06000000-0000-0000-0000-000000000006', pg_temp.q6(), 'r-oli-1');

  select e.id into v_nina from public.queue_entries e
  join public.queue_entry_members m on m.entry_id = e.id
  where m.user_id = '86000000-0000-0000-0000-000000000086' and m.is_active
    and e.court_id = pg_temp.q6();

  update public.queue_entries
     set first_joined_at = now() - interval '4 hours', called_at = null,
         status = 'ready', call_expires_at = null
   where id = v_nina;

  v_saiu := public.expire_stale_queue_entries('3 hours');
  assert v_saiu = 1, format('só a vaga esquecida sai: %s', v_saiu);

  -- E a quadra não ficou travada: o próximo foi chamado.
  assert pg_temp.ordem(pg_temp.q6()) = 'Oli', format('fila: %s', pg_temp.ordem(pg_temp.q6()));
  assert (select status from public.queue_entries e
          join public.queue_entry_members m on m.entry_id = e.id
          where m.user_id = '06000000-0000-0000-0000-000000000006' and m.is_active
            and e.court_id = pg_temp.q6()) = 'ready',
    'a vez passou para quem ficou, em vez de a quadra travar';

  select * into v_court from public.courts c where c.id = pg_temp.q6();
  assert v_court.status = 'available', format('quadra livre e chamável: %s', v_court.status);
end $$;

rollback;

\echo '✔ tests/local/80_rotacao_test.sql — chamada de 15s, aceite, 30s para entrar, rotação e admin'
