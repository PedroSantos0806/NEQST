-- =====================================================================
-- O totem da quadra: 40 min de jogo, troca de 1:30 e pausas
--
-- Handoff do mock (05/11/2026) + a fila sem conta: a party digita nome e
-- quantidade, no totem ou pelo QR, e os dois caminhos escrevem na mesma
-- fila. Cinco estados, e só Pausada não sai sozinha pelo relógio.
--
-- Os casos cobrem, nesta ordem: entrar numa quadra vazia, a fila com
-- previsão, o aviso de 1 minuto, a troca de 1:30, a pergunta de saída
-- (sem resposta e com), Continuar jogando, as três pausas, o QR sem
-- login, o admin e a limpeza por inatividade.
-- =====================================================================
begin;

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
   'teste-rotacao-q6', 'Quadra 06', -23.570500, -46.650500, 'fixed_qr'),
  -- E a q7 para a pausa, que precisa de uma quadra que ninguém mexe.
  ('a7a70000-0000-0000-0000-0000000000a7', '66660000-0000-0000-0000-000000000006', 7, 'hard', 40,
   'teste-rotacao-q7', 'Quadra 07', -23.570600, -46.650600, 'fixed_qr');

-- Um totem por quadra, como no handoff. Não existe mais "quadra com
-- tablet" e "quadra sem": a troca de 1:30 é a mesma em todas, e o totem
-- é só quem escreve nela.
insert into public.court_devices (court_id, label, token_hash, last_seen_at)
values
  ('a6a60000-0000-0000-0000-0000000000a6', 'totem q1',
   public.hash_scan_token('totem-q1-token'), now()),
  ('b6b60000-0000-0000-0000-0000000000b6', 'totem q2',
   public.hash_scan_token('totem-q2-token'), now()),
  ('c6c60000-0000-0000-0000-0000000000c6', 'totem q3',
   public.hash_scan_token('totem-q3-token'), now());

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
create or replace function pg_temp.q7() returns uuid language sql as $$
  select 'a7a70000-0000-0000-0000-0000000000a7'::uuid $$;

-- O token do totem de cada quadra, que é a credencial de quem está lá.
create or replace function pg_temp.totem_q1() returns text language sql as $$
  select 'totem-q1-token'::text $$;
create or replace function pg_temp.totem_q2() returns text language sql as $$
  select 'totem-q2-token'::text $$;

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

create or replace function pg_temp.vence_a_troca(p_court uuid)
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

-- Vazio de verdade: `->` devolve o null de JSON, que não é NULL de SQL.
create or replace function pg_temp.vazio(p jsonb)
returns boolean language sql immutable as $$
  select p is null or jsonb_typeof(p) = 'null';
$$;

-- Quem está entrando na quadra agora, pelo primeiro nome.
create or replace function pg_temp.entrando(p_court uuid)
returns text language sql as $$
  select coalesce(
    (select split_part(
              coalesce(pr.full_name, e.party_name, e.offline_label, 'sem app'), ' ', 1)
       from public.courts c
       join public.queue_entries e on e.id = c.handover_entry_id
       left join public.queue_entry_members m
              on m.entry_id = e.id and m.is_active and m.role = 'owner'
       left join public.profiles pr on pr.id = m.user_id
      where c.id = p_court and c.handover_phase = 'changeover'),
    'ninguém');
$$;

-- =====================================================================
-- 1. Quadra livre → Em jogo: quem chega numa quadra vazia já joga
--
-- A party é digitada no totem: nome e quantidade, sem conta nenhuma.
-- =====================================================================
do $$
declare v jsonb; v_tela jsonb;
begin
  perform set_config('request.jwt.claim.sub', '', true);
  v := public.totem_join(pg_temp.totem_q1(), 'Rafael Lima', 2);

  assert (v ->> 'playing')::boolean, format('quadra vazia: joga na hora: %s', v);
  assert (v ->> 'party_token') is null, 'o totem não devolve o segredo da party';

  v_tela := v -> 'screen';
  assert v_tela ->> 'state' = 'playing', format('estado: %s', v_tela ->> 'state');
  assert v_tela -> 'playing' ->> 'name' = 'Rafael Lima',
    format('em quadra: %s', v_tela -> 'playing');
  assert v_tela -> 'playing' ->> 'label' = 'Simples', format('rótulo: %s', v_tela -> 'playing');
  assert (v_tela ->> 'queue_count')::int = 0, 'fila vazia';
  assert (v_tela ->> 'remaining_seconds')::int between 2390 and 2400,
    format('40 minutos: %s', v_tela ->> 'remaining_seconds');
  assert v_tela -> 'court' ->> 'strip' = 'Quadra 01 · Rápida · Parque da Rotação (teste)',
    format('a linha fina do topo sai do banco: %s', v_tela -> 'court' ->> 'strip');
end $$;

-- =====================================================================
-- 2. A fila por party: tamanho livre, rótulo pelas palavras do handoff
-- =====================================================================
do $$
declare v_tela jsonb; v_q jsonb;
begin
  perform public.totem_join(pg_temp.totem_q1(), 'Marina Souza', 2);
  perform public.totem_join(pg_temp.totem_q1(), 'Zé do Ibira', 6);
  v_tela := public.totem_screen(pg_temp.totem_q1());

  assert (v_tela ->> 'queue_count')::int = 2, format('duas na fila: %s', v_tela ->> 'queue_count');

  v_q := v_tela -> 'queue' -> 0;
  assert v_q ->> 'name' = 'Marina Souza', format('1ª da fila: %s', v_q);
  assert (v_q ->> 'is_next')::boolean, 'a 1ª é a próxima';
  assert v_q ->> 'label' = 'Simples', format('rótulo de 2: %s', v_q ->> 'label');
  -- Previsão: o que falta do jogo + a troca de 1:30.
  assert (v_q ->> 'eta_seconds')::int between 2450 and 2490,
    format('previsão da 1ª: %s', v_q ->> 'eta_seconds');

  v_q := v_tela -> 'queue' -> 1;
  assert v_q ->> 'label' = 'Grupo de 6, revezando', format('rótulo de 6: %s', v_q ->> 'label');
  -- Mais uma rodada inteira: 40 min + 1:30.
  assert (v_q ->> 'eta_seconds')::int - (v_tela -> 'queue' -> 0 ->> 'eta_seconds')::int = 2490,
    'cada posição custa uma rodada';
  assert v_q ->> 'source' = 'totem', 'entrou pelo totem';

  -- Nome curto e party impossível são recusados.
  begin
    perform public.totem_join(pg_temp.totem_q1(), 'A', 2);
    assert false, 'nome de 1 letra deveria ser recusado';
  exception when sqlstate 'NQ041' then null;
  end;
  begin
    perform public.totem_join(pg_temp.totem_q1(), 'Party Grande', 21);
    assert false, '21 pessoas deveria ser recusado';
  exception when sqlstate 'NQ042' then null;
  end;
end $$;

-- =====================================================================
-- 3. Aviso de 1 minuto: o placar muda, e Continuar não existe com fila
-- =====================================================================
do $$
declare v_tela jsonb; v_code text;
begin
  update public.matches set expires_at = now() + interval '45 seconds'
   where court_id = pg_temp.q1() and ended_at is null;

  v_tela := public.totem_screen(pg_temp.totem_q1());
  assert v_tela ->> 'state' = 'ending', format('estado: %s', v_tela ->> 'state');
  assert not (v_tela ->> 'can_continue')::boolean,
    'com gente esperando, ninguém segura a quadra por 80 minutos';

  begin
    perform public.totem_continue(pg_temp.totem_q1());
    assert false, 'Continuar com fila deveria ser recusado';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ040', format('esperava NQ040, obtive %s', v_code);
  end;
end $$;

-- =====================================================================
-- 4. Acabou o tempo: troca de 1:30 e a pergunta de saída
-- =====================================================================
do $$
declare v_tela jsonb;
begin
  perform pg_temp.vence_o_turno(pg_temp.q1());
  v_tela := public.totem_screen(pg_temp.totem_q1());

  assert v_tela ->> 'state' = 'changeover', format('estado: %s', v_tela ->> 'state');
  assert (v_tela ->> 'changeover_left')::int between 80 and 90,
    format('1:30 de troca: %s', v_tela ->> 'changeover_left');

  -- A faixa é de quem acabou de sair, com o texto do handoff.
  assert v_tela -> 'exit_ask' ->> 'name' = 'Rafael Lima',
    format('a pergunta é do Rafael: %s', v_tela -> 'exit_ask');
  assert v_tela -> 'exit_ask' ->> 'text' =
    'Rafael Lima, acabou seu tempo. Quer sair ou voltar pro fim da fila?',
    format('texto da faixa: %s', v_tela -> 'exit_ask' ->> 'text');

  -- A próxima aparece nos dois lugares de propósito: ela ainda espera.
  assert v_tela -> 'next' ->> 'name' = 'Marina Souza', format('entra: %s', v_tela -> 'next');
  assert v_tela -> 'queue' -> 0 ->> 'name' = 'Marina Souza', 'e segue como 1ª da fila';
  assert (v_tela ->> 'queue_count')::int = 2, 'ninguém saiu da fila ainda';

  -- O Rafael não voltou sozinho para o fim: isso agora é resposta dele.
  assert not exists (
    select 1 from public.queue_entries e
    where e.court_id = pg_temp.q1() and e.party_name = 'Rafael Lima'
      and e.status in ('waiting', 'ready')),
    'quem jogou não volta para a fila sem responder';
end $$;

-- =====================================================================
-- 5. Sem resposta em 1:30, o padrão é sair — e o próximo entra sozinho
-- =====================================================================
do $$
declare v_tela jsonb;
begin
  perform pg_temp.vence_a_troca(pg_temp.q1());
  v_tela := public.totem_screen(pg_temp.totem_q1());

  assert v_tela ->> 'state' = 'playing', format('estado: %s', v_tela ->> 'state');
  assert v_tela -> 'playing' ->> 'name' = 'Marina Souza',
    format('a Marina entrou sozinha, sem apertar nada: %s', v_tela -> 'playing');
  assert pg_temp.vazio(v_tela -> 'exit_ask'), 'a faixa sumiu quando a próxima entrou';
  assert (v_tela ->> 'queue_count')::int = 1, 'sobrou o Zé na fila';
  assert not exists (
    select 1 from public.queue_entries e
    where e.court_id = pg_temp.q1() and e.party_name = 'Rafael Lima'
      and e.status in ('waiting', 'ready')),
    'sem resposta, o Rafael foi embora';
end $$;

-- =====================================================================
-- 6. "Voltar pra fila": vai para o FIM, com o turno contado
-- =====================================================================
do $$
declare v_tela jsonb; v_marina public.queue_entries;
begin
  perform pg_temp.vence_o_turno(pg_temp.q1());
  v_tela := public.totem_screen(pg_temp.totem_q1());
  assert v_tela -> 'exit_ask' ->> 'name' = 'Marina Souza', format('a vez dela: %s', v_tela -> 'exit_ask');

  v_tela := public.totem_exit_answer(pg_temp.totem_q1(), true);

  assert pg_temp.vazio(v_tela -> 'exit_ask'), 'respondida, a faixa sai';
  assert v_tela ->> 'state' = 'changeover', 'a troca continua correndo';
  assert v_tela -> 'next' ->> 'name' = 'Zé do Ibira', format('entra o Zé: %s', v_tela -> 'next');

  select * into v_marina from public.queue_entries e
  where e.court_id = pg_temp.q1() and e.party_name = 'Marina Souza'
    and e.status in ('waiting', 'ready');
  assert v_marina.turn_number = 2, format('segundo turno dela: %s', v_marina.turn_number);
  assert (select qp.position from public.queue_positions qp where qp.entry_id = v_marina.id) = 2,
    'atrás do Zé, que esperou';
  assert v_marina.party_size = 2, 'o tamanho da party viaja com ela';
end $$;

-- =====================================================================
-- 7. Continuar jogando: só com a fila vazia, e aí são mais 40 minutos
-- =====================================================================
do $$
declare v jsonb; v_tela jsonb;
begin
  v := public.totem_join(pg_temp.totem_q2(), 'Duda Única', 1);
  assert (v ->> 'playing')::boolean, 'quadra vazia: entra jogando';
  assert v -> 'screen' -> 'playing' ->> 'label' = 'Sozinho',
    format('rótulo de 1: %s', v -> 'screen' -> 'playing');

  update public.matches set expires_at = now() + interval '45 seconds'
   where court_id = pg_temp.q2() and ended_at is null;

  v_tela := public.totem_screen(pg_temp.totem_q2());
  assert v_tela ->> 'state' = 'ending', format('estado: %s', v_tela ->> 'state');
  assert (v_tela ->> 'can_continue')::boolean, 'sozinha na quadra, pode continuar';

  v_tela := public.totem_continue(pg_temp.totem_q2());
  assert v_tela ->> 'state' = 'playing', 'voltou a jogar';
  assert (v_tela ->> 'remaining_seconds')::int between 2390 and 2400,
    format('mais 40 minutos: %s', v_tela ->> 'remaining_seconds');
end $$;

-- =====================================================================
-- 8. Pausa apertada durante o jogo: agenda, não interrompe
--
-- E a previsão deixa de ser calculável: a pausa não tem duração.
-- =====================================================================
do $$
declare v_tela jsonb;
begin
  perform public.totem_join(pg_temp.totem_q2(), 'Fila da Pausa', 2);

  v_tela := public.totem_pause(pg_temp.totem_q2(), 'vassourao');
  assert v_tela ->> 'state' = 'playing', 'o jogo em curso não é interrompido';
  assert v_tela -> 'armed_pause' ->> 'kind' = 'vassourao',
    format('vassourão agendado: %s', v_tela -> 'armed_pause');
  assert (v_tela -> 'queue' -> 0 ->> 'eta_seconds') is null,
    'com pausa agendada a previsão não é calculável';

  -- Apertar de novo cancela o agendamento.
  v_tela := public.totem_pause(pg_temp.totem_q2(), 'vassourao');
  assert pg_temp.vazio(v_tela -> 'armed_pause'), 'o mesmo botão cancela';

  v_tela := public.totem_pause(pg_temp.totem_q2(), 'rega');
  assert v_tela -> 'armed_pause' ->> 'kind' = 'rega', 'e troca de motivo';
end $$;

-- O tempo zera com pausa agendada: entra Pausada, e não a troca
do $$
declare v_tela jsonb;
begin
  perform pg_temp.vence_o_turno(pg_temp.q2());
  v_tela := public.totem_screen(pg_temp.totem_q2());

  assert v_tela ->> 'state' = 'paused', format('estado: %s', v_tela ->> 'state');
  assert v_tela -> 'pause' ->> 'kind' = 'rega', format('pausa em curso: %s', v_tela -> 'pause');
  assert v_tela -> 'pause' ->> 'desc' = 'Estão regando a quadra.', 'com o texto da tela';
  assert (v_tela ->> 'changeover_left')::int = 0, 'a troca não começou';
  assert pg_temp.vazio(v_tela -> 'armed_pause'), 'o agendamento virou pausa';
  assert (v_tela -> 'queue' -> 0 ->> 'eta_seconds') is null, 'previsão: depois da pausa';

  -- A pausa não anda sozinha: o relógio pode passar e nada muda.
  perform pg_temp.vence_a_troca(pg_temp.q2());
  v_tela := public.totem_screen(pg_temp.totem_q2());
  assert v_tela ->> 'state' = 'paused', 'pausa só sai por toque humano em Retomar';
end $$;

-- Retomar: a troca recomeça com os 1:30 cheios, e a pergunta que
-- esperava aparece agora
do $$
declare v_tela jsonb;
begin
  v_tela := public.totem_resume(pg_temp.totem_q2());

  assert v_tela ->> 'state' = 'changeover', format('estado: %s', v_tela ->> 'state');
  assert (v_tela ->> 'changeover_left')::int between 80 and 90,
    format('os 1:30 cheios: %s', v_tela ->> 'changeover_left');
  assert pg_temp.vazio(v_tela -> 'pause'), 'sem pausa em curso';
  assert v_tela -> 'exit_ask' ->> 'name' = 'Duda Única',
    format('a pergunta esperou o Retomar: %s', v_tela -> 'exit_ask');
  assert v_tela -> 'next' ->> 'name' = 'Fila da Pausa', 'e a fila andou';
end $$;

-- =====================================================================
-- 9. Pausa apertada na troca começa na hora
-- =====================================================================
do $$
declare v_tela jsonb;
begin
  v_tela := public.totem_pause(pg_temp.totem_q2(), 'excecao');
  assert v_tela ->> 'state' = 'paused', format('estado: %s', v_tela ->> 'state');
  assert v_tela -> 'pause' ->> 'label' = 'Exceção', format('pausa: %s', v_tela -> 'pause');
  assert (v_tela ->> 'changeover_left')::int = 0, 'a troca parou de contar';

  -- E ninguém entra em quadra pausada.
  perform pg_temp.vence_a_troca(pg_temp.q2());
  v_tela := public.totem_screen(pg_temp.totem_q2());
  assert v_tela ->> 'state' = 'paused', 'o relógio da troca não vale na pausa';
  assert pg_temp.vazio(v_tela -> 'playing'), 'quadra vazia';

  -- Retomar devolve a troca, e no fim dela o turno começa.
  v_tela := public.totem_resume(pg_temp.totem_q2());
  assert v_tela ->> 'state' = 'changeover', 'volta para a troca';
  perform pg_temp.vence_a_troca(pg_temp.q2());
  v_tela := public.totem_screen(pg_temp.totem_q2());
  assert v_tela -> 'playing' ->> 'name' = 'Fila da Pausa',
    format('entrou quem esperava: %s', v_tela -> 'playing');
end $$;

-- =====================================================================
-- 10. O QR e a tag NFC: entrar na fila pelo celular, sem login
-- =====================================================================
do $$
declare v jsonb; v_tela jsonb; v_token text; v_code text;
begin
  -- Scan token SEM conta: é o que o leitor de QR emite para quem não
  -- está logado em nada.
  insert into public.scan_tokens
    (token_hash, user_id, court_id, latitude, longitude, distance_meters, expires_at, method)
  select public.hash_scan_token('qr-sem-conta-1'), null, c.id, c.latitude, c.longitude, 8,
         now() + interval '30 seconds', 'qr'
  from public.courts c where c.id = pg_temp.q1();

  perform set_config('request.jwt.claim.sub', '', true);
  v := public.scan_join_party('qr-sem-conta-1', 'Priscila Alves', 4);

  assert (v ->> 'entry_id') is not null, format('entrou na fila: %s', v);
  assert length(v ->> 'party_token') = 64, 'o celular recebe o segredo dela, uma vez';
  assert v ->> 'court_id' = pg_temp.q1()::text, 'na quadra do QR';
  v_token := v ->> 'party_token';

  -- O token não pode ser reusado: um scan, uma entrada.
  begin
    perform public.scan_join_party('qr-sem-conta-1', 'Outro Nome', 2);
    assert false, 'scan token já usado deveria ser recusado';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ002', format('esperava NQ002, obtive %s', v_code);
  end;

  -- A tela do celular: a mesma quadra, mais a própria vaga.
  v_tela := public.party_screen(v_token);
  assert v_tela -> 'my_party' ->> 'name' = 'Priscila Alves', format('minha vaga: %s', v_tela -> 'my_party');
  assert v_tela -> 'my_party' ->> 'label' = 'Duplas', 'rótulo de 4';
  assert (v_tela -> 'my_party' ->> 'position')::int >= 1, 'com posição na fila';
  assert v_tela -> 'court' ->> 'id' = pg_temp.q1()::text, 'e a quadra inteira';

  -- E sair da fila pelo celular, que é o que o party token autoriza.
  v_tela := public.party_leave(v_token);
  assert not exists (
    select 1 from public.queue_entries e
    where e.court_id = pg_temp.q1() and e.party_name = 'Priscila Alves'
      and e.status in ('waiting', 'ready')),
    'saiu da fila pelo celular';

  -- Token de party inventado não abre nada.
  begin
    perform public.party_screen('nao-sou-um-token');
    assert false, 'party token inválido deveria ser recusado';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ007', format('esperava NQ007, obtive %s', v_code);
  end;
end $$;

-- =====================================================================
-- 11. Estado para os casos do admin: q3 e q4 com conta, como antes
--
-- A fila aceita os dois mundos: party digitada e vaga com conta.
-- =====================================================================
do $$
begin
  perform pg_temp.entra('f6000000-0000-0000-0000-0000000000f6', pg_temp.q3(), 'r-fe-1');
  perform pg_temp.as_user('f6000000-0000-0000-0000-0000000000f6');
  perform pg_temp.scan('f6000000-0000-0000-0000-0000000000f6', pg_temp.q3(), 'r-fe-ci');
  perform public.check_in_and_start('r-fe-ci');
  perform pg_temp.entra('e6000000-0000-0000-0000-0000000000e6', pg_temp.q3(), 'r-edu-1');

  perform pg_temp.entra('26000000-0000-0000-0000-000000000026', pg_temp.q4(), 'r-hugo-1');
  perform pg_temp.as_user('26000000-0000-0000-0000-000000000026');
  perform pg_temp.scan('26000000-0000-0000-0000-000000000026', pg_temp.q4(), 'r-hugo-ci');
  perform public.check_in_and_start('r-hugo-ci');
  perform pg_temp.entra('36000000-0000-0000-0000-000000000036', pg_temp.q4(), 'r-iris-1');

  assert pg_temp.em_quadra(pg_temp.q3()) = 'Fê', format('q3: %s', pg_temp.em_quadra(pg_temp.q3()));
  assert pg_temp.ordem(pg_temp.q3()) = 'Edu', format('fila da q3: %s', pg_temp.ordem(pg_temp.q3()));
  assert pg_temp.ordem(pg_temp.q4()) = 'Iris', format('fila da q4: %s', pg_temp.ordem(pg_temp.q4()));
end $$;

-- =====================================================================
-- 12. O admin corrige o relógio do turno em andamento
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
  assert pg_temp.entrando(pg_temp.q3()) = 'Edu', format('entrando: %s', pg_temp.entrando(pg_temp.q3()));
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
-- 13. O admin tira da fila quem foi embora sem avisar
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
-- 14. O totem: identidade de aparelho, e o link que o admin gera
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
    perform public.admin_create_court_device(pg_temp.q4(), 'totem da q4');
    assert false, 'jogador comum não gera link de totem';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ023', format('esperava NQ023, obtive %s', v_code);
  end;

  perform pg_temp.as_user('16000000-0000-0000-0000-000000000016');
  v_novo := public.admin_create_court_device(pg_temp.q4(), 'totem da q4');
  v_token := v_novo ->> 'token';

  assert length(v_token) = 64, format('token de 32 bytes em hex: %s', length(v_token));
  assert v_novo ->> 'path' = '/totem/' || v_token, format('o caminho do link: %s', v_novo ->> 'path');

  -- O banco não guarda o token, só o hash.
  assert not exists (
    select 1 from public.court_devices d where d.token_hash = v_token
  ), 'o token em claro não fica no banco';
  assert exists (
    select 1 from public.court_devices d
    where d.token_hash = public.hash_scan_token(v_token)
  ), 'o hash fica';

  -- O totem lê a quadra sem estar logado como ninguém.
  perform set_config('request.jwt.claim.sub', '', true);
  v_tela := public.totem_screen(v_token);
  assert v_tela -> 'court' ->> 'id' = pg_temp.q4()::text, format('a quadra certa: %s', v_tela -> 'court');
  assert v_tela ->> 'state' = 'playing', format('o Hugo está em quadra: %s', v_tela ->> 'state');

  -- E ler marca o aparelho como vivo.
  assert (select last_seen_at from public.court_devices
           where id = (v_novo ->> 'device_id')::uuid) is not null,
    'a leitura marca o totem como aceso';

  -- Token inventado não abre nada.
  begin
    perform public.totem_screen('nao-sou-um-token');
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
    perform public.totem_screen(v_token);
    assert false, 'totem revogado deveria ser recusado';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ037', format('esperava NQ037, obtive %s', v_code);
  end;
end $$;

-- 15. A limpeza por inatividade não pode expulsar quem só esperou, nem
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


-- Quadra pausada não expira a fila de ninguém: a pausa não tem duração,
-- e é justamente ela que segura a fila
do $$
declare v_saiu integer;
begin
  perform pg_temp.entra('f6000000-0000-0000-0000-0000000000f6', pg_temp.q7(), 'r-fe-pausa');
  perform pg_temp.as_user('16000000-0000-0000-0000-000000000016');
  perform public.pause_court(pg_temp.q7(), 'excecao');

  update public.queue_entries
     set first_joined_at = now() - interval '4 hours',
         joined_at = now() - interval '4 hours',
         called_at = null, status = 'waiting', call_expires_at = null
   where court_id = pg_temp.q7();

  v_saiu := public.expire_stale_queue_entries('3 hours');
  assert v_saiu = 0, format('pausa de 4 h não é fila esquecida: %s saíram', v_saiu);
  assert pg_temp.ordem(pg_temp.q7()) = 'Fê', format('a fila fica: %s', pg_temp.ordem(pg_temp.q7()));
end $$;

rollback;

\echo '✔ tests/local/80_rotacao_test.sql — totem: troca de 1:30, pergunta de saída, pausas e fila sem conta'
