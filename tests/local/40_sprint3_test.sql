-- =====================================================================
-- Sprint 3: o fluxo do protótipo de ponta a ponta.
--   parques > quadras numeradas com superfície
--   partida lado A x lado B, quem ganha fica
--   check-in do próprio jogador, com janela de 5 min
--   uma fila por jogador em todo o app
-- =====================================================================
\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('a0000000-0000-0000-0000-00000000000a', 'ana@example.com',    '{"full_name":"Ana Souza"}'),
  ('b0000000-0000-0000-0000-00000000000b', 'bruno@example.com',  '{"full_name":"Bruno Lima"}'),
  ('c0000000-0000-0000-0000-00000000000c', 'caio@example.com',   '{"full_name":"Caio Melo"}'),
  ('d0000000-0000-0000-0000-00000000000d', 'duda@example.com',   '{"full_name":"Duda Reis"}'),
  ('e0000000-0000-0000-0000-00000000000e', 'elias@example.com',  '{"full_name":"Elias Prado"}'),
  ('f0000000-0000-0000-0000-00000000000f', 'flavia@example.com', '{"full_name":"Flávia Hara"}');

insert into public.parks (id, slug, name, district, latitude, longitude, tone_color, photo_alt)
values
  ('11110000-0000-0000-0000-000000000001', 'teste-ibirapuera', 'Parque Ibirapuera (teste)',
   'Vila Mariana · Zona Sul', -23.587416, -46.657634, '#2F4629', 'quadra de saibro'),
  ('22220000-0000-0000-0000-000000000002', 'teste-villa-lobos', 'Parque Villa-Lobos (teste)',
   'Alto de Pinheiros · Zona Oeste', -23.545000, -46.722000, '#39678C', 'quadra entre as árvores');

insert into public.courts (id, park_id, court_number, surface, slot_minutes, slug, name,
                           latitude, longitude)
values
  ('aaaa0000-0000-0000-0000-00000000000a', '11110000-0000-0000-0000-000000000001', 1, 'clay',  40,
   'teste-ibira-q1', 'Quadra 01', -23.587416, -46.657634),
  ('bbbb0000-0000-0000-0000-00000000000b', '11110000-0000-0000-0000-000000000001', 2, 'hard',  40,
   'teste-ibira-q2', 'Quadra 02', -23.587500, -46.657700),
  ('cccc0000-0000-0000-0000-00000000000c', '11110000-0000-0000-0000-000000000001', 3, 'grass', 60,
   'teste-ibira-q3', 'Quadra 03', -23.587600, -46.657800),
  ('dddd0000-0000-0000-0000-00000000000d', '22220000-0000-0000-0000-000000000002', 1, 'hard',  40,
   'teste-villa-q1', 'Quadra 01', -23.545000, -46.722000);

-- Helper: emite scan token (papel da Edge Function scan-court)
create or replace function pg_temp.scan(p_user uuid, p_court uuid, p_token text)
returns void language sql as $$
  insert into public.scan_tokens
    (token_hash, user_id, court_id, latitude, longitude, distance_meters, expires_at)
  select public.hash_scan_token(p_token), p_user, p_court, c.latitude, c.longitude, 8,
         now() + interval '30 seconds'
  from public.courts c where c.id = p_court;
$$;

-- =====================================================================
-- Rótulos e superfícies
-- =====================================================================
do $$ begin
  assert public.court_label(1::smallint) = 'Quadra 01', 'rótulo com zero à esquerda';
  assert public.court_label(12::smallint) = 'Quadra 12', 'rótulo de dois dígitos';
  assert public.initials_of('Diego Matsuo') = 'DM', format('iniciais: %s', public.initials_of('Diego Matsuo'));
  assert public.initials_of('Ana') = 'A', 'nome único';
  assert public.initials_of('') = '?', 'nome vazio';
  assert public.short_name_of('Diego Matsuo') = 'Diego M.', format('nome curto: %s', public.short_name_of('Diego Matsuo'));
  assert public.short_name_of('Ana') = 'Ana', 'nome curto de nome único';
end $$;

-- Dois "Quadra 01" no mesmo parque não podem coexistir
do $$ begin
  begin
    insert into public.courts (park_id, court_number, surface, slug, name, latitude, longitude)
    values ('11110000-0000-0000-0000-000000000001', 1, 'clay', 'teste-dup', 'Dup', -23.5, -46.6);
    assert false, 'número de quadra duplicado no parque deveria falhar';
  exception when unique_violation then null;
  end;
end $$;

-- =====================================================================
-- Lista de parques
-- =====================================================================
set local "request.jwt.claim.sub" = 'a0000000-0000-0000-0000-00000000000a';

do $$
declare v jsonb; v_ibira jsonb;
begin
  v := public.parks_overview();
  assert (select count(*) from jsonb_array_elements(v) p
          where p ->> 'slug' like 'teste-%') = 2,
    format('2 parques de teste: %s', v);

  select p into v_ibira from jsonb_array_elements(v) p where p ->> 'slug' = 'teste-ibirapuera';
  assert (v_ibira ->> 'courts_count')::int = 3, format('Ibirapuera tem 3 quadras: %s', v_ibira);
  assert (v_ibira ->> 'live_count')::int = 0, 'nenhum jogo ainda';
  assert (v_ibira ->> 'queue_count')::int = 0, 'nenhuma fila ainda';
  assert v_ibira ->> 'live_text' = 'Quadras livres', format('texto: %s', v_ibira ->> 'live_text');
  assert jsonb_array_length(v_ibira -> 'surfaces') = 3, 'três superfícies distintas';
  assert not (v_ibira ->> 'is_mine')::boolean, 'ainda não estou em fila aqui';
  assert v_ibira ->> 'district' = 'Vila Mariana · Zona Sul', 'distrito';

  -- Filtro geográfico
  v := public.parks_overview(-23.587416, -46.657634, 300);
  assert (select count(*) from jsonb_array_elements(v) p
          where p ->> 'slug' like 'teste-%') = 1,
    format('raio curto pega só o Ibirapuera de teste: %s', v);
end $$;

-- =====================================================================
-- Ana entra na fila da Quadra 01
-- =====================================================================
do $$
declare v jsonb;
begin
  perform pg_temp.scan('a0000000-0000-0000-0000-00000000000a',
                       'aaaa0000-0000-0000-0000-00000000000a', 'tok-ana-1');
  v := public.join_queue('tok-ana-1', 'single');
  assert (v ->> 'position')::int = 1, format('Ana é a 1ª: %s', v);
end $$;

-- Uma fila por jogador em TODO o app: outra quadra, outro parque, nada
do $$
declare v_code text; v_msg text;
begin
  perform pg_temp.scan('a0000000-0000-0000-0000-00000000000a',
                       'bbbb0000-0000-0000-0000-00000000000b', 'tok-ana-2');
  begin
    perform public.join_queue('tok-ana-2', 'single');
    assert false, 'entrar em duas filas deveria falhar';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate, v_msg = message_text;
    assert v_code = 'NQ014', format('esperava NQ014, obtive %s', v_code);
    assert v_msg like '%Quadra 01%', format('a mensagem deveria citar a quadra: %s', v_msg);
  end;

  -- Mesmo em outro parque
  perform pg_temp.scan('a0000000-0000-0000-0000-00000000000a',
                       'dddd0000-0000-0000-0000-00000000000d', 'tok-ana-3');
  begin
    perform public.join_queue('tok-ana-3', 'single');
    assert false, 'outro parque também deveria bloquear';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ014', format('esperava NQ014, obtive %s', v_code);
  end;
end $$;

-- A lista de parceiros reflete a indisponibilidade
set local "request.jwt.claim.sub" = 'b0000000-0000-0000-0000-00000000000b';
do $$
declare v jsonb; v_ana jsonb;
begin
  v := public.search_partners();
  select p into v_ana from jsonb_array_elements(v) p where p ->> 'username' = 'ana';

  assert v_ana ->> 'state' = 'queued', format('Ana está na fila: %s', v_ana);
  assert not (v_ana ->> 'available')::boolean, 'Ana indisponível';
  assert v_ana ->> 'where' = 'Na fila · Quadra 01', format('onde: %s', v_ana ->> 'where');
  assert v_ana ->> 'handle' = '@ana', 'handle com arroba';

  -- Busca por texto
  v := public.search_partners('cai');
  assert jsonb_array_length(v) = 1, format('busca por "cai": %s', v);
  assert (v -> 0 ->> 'username') = 'caio', 'achou o Caio';
  assert (v -> 0 ->> 'state') = 'free', 'Caio livre';

  -- Com arroba também funciona
  v := public.search_partners('@duda');
  assert jsonb_array_length(v) = 1, 'busca com @ deveria funcionar';
end $$;

-- Parceiro indisponível é recusado na formação da dupla
do $$
declare v_code text; v_msg text;
begin
  perform pg_temp.scan('b0000000-0000-0000-0000-00000000000b',
                       'bbbb0000-0000-0000-0000-00000000000b', 'tok-bru-x');
  begin
    perform public.join_queue('tok-bru-x', 'double', '@ana');
    assert false, 'dupla com parceiro na fila deveria falhar';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate, v_msg = message_text;
    assert v_code = 'NQ006', format('esperava NQ006, obtive %s', v_code);
    assert v_msg like '%na fila%', format('mensagem deveria dizer onde: %s', v_msg);
  end;
end $$;

-- =====================================================================
-- Check-in da Ana inicia a partida, com o lado B aberto
-- =====================================================================
set local "request.jwt.claim.sub" = 'a0000000-0000-0000-0000-00000000000a';

do $$
declare v jsonb; v_status public.court_status;
begin
  perform pg_temp.scan('a0000000-0000-0000-0000-00000000000a',
                       'aaaa0000-0000-0000-0000-00000000000a', 'tok-ana-start');
  v := public.check_in_and_start('tok-ana-start');

  assert (v ->> 'is_live')::boolean, format('partida deveria estar ao vivo: %s', v);
  assert jsonb_array_length(v -> 'side_a' -> 'players') = 1, 'lado A com a Ana';
  assert (v -> 'side_b' ->> 'open')::boolean, 'lado B aberto (adversário livre)';
  assert (v ->> 'slot_minutes')::int = 40, 'slot da quadra';
  assert (v ->> 'remaining_seconds')::int between 2390 and 2400, format('restante ~40 min: %s', v ->> 'remaining_seconds');

  select status into v_status from public.courts where id = 'aaaa0000-0000-0000-0000-00000000000a';
  assert v_status = 'in_game', format('quadra em jogo: %s', v_status);
end $$;

-- Token de check-in é de uso único
do $$
declare v_code text;
begin
  begin
    perform public.check_in_and_start('tok-ana-start');
    assert false, 'reusar o token do check-in deveria falhar';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ002', format('esperava NQ002, obtive %s', v_code);
  end;
end $$;

-- =====================================================================
-- Bruno entra na fila e ocupa o lado livre
-- =====================================================================
set local "request.jwt.claim.sub" = 'b0000000-0000-0000-0000-00000000000b';

do $$
declare v jsonb;
begin
  perform pg_temp.scan('b0000000-0000-0000-0000-00000000000b',
                       'aaaa0000-0000-0000-0000-00000000000a', 'tok-bru-1');
  v := public.join_queue('tok-bru-1', 'single');
  assert (v ->> 'position')::int = 1, format('Bruno é o 1º da espera: %s', v);
  assert (v ->> 'teams_ahead')::int = 1, format('1 time à frente (a partida em curso): %s', v);
end $$;

-- Não pode iniciar outra partida: a quadra está ocupada
do $$
declare v_code text;
begin
  perform pg_temp.scan('b0000000-0000-0000-0000-00000000000b',
                       'aaaa0000-0000-0000-0000-00000000000a', 'tok-bru-2');
  begin
    perform public.check_in_and_start('tok-bru-2');
    assert false, 'iniciar com quadra ocupada deveria falhar';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ017', format('esperava NQ017, obtive %s', v_code);
  end;
end $$;

-- Mas pode ocupar o lado livre da partida em andamento
do $$
declare v jsonb;
begin
  perform pg_temp.scan('b0000000-0000-0000-0000-00000000000b',
                       'aaaa0000-0000-0000-0000-00000000000a', 'tok-bru-3');
  v := public.join_open_side('tok-bru-3');

  assert not (v -> 'side_b' ->> 'open')::boolean, 'lado B agora ocupado';
  assert jsonb_array_length(v -> 'side_b' -> 'players') = 1, 'Bruno no lado B';
end $$;

-- =====================================================================
-- Resultado: quem ganha fica
-- =====================================================================

-- Quem não está em quadra não reporta
set local "request.jwt.claim.sub" = 'c0000000-0000-0000-0000-00000000000c';
do $$
declare v_code text; v_match uuid;
begin
  select id into v_match from public.matches where ended_at is null;
  begin
    perform public.report_match_result(v_match, 'a');
    assert false, 'quem não jogou não deveria reportar';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ008', format('esperava NQ008, obtive %s', v_code);
  end;
end $$;

-- Caio e Duda entram na fila (um deles será chamado)
do $$
declare v jsonb;
begin
  perform pg_temp.scan('c0000000-0000-0000-0000-00000000000c',
                       'aaaa0000-0000-0000-0000-00000000000a', 'tok-caio-1');
  v := public.join_queue('tok-caio-1', 'single');
  assert (v ->> 'position')::int = 1, format('Caio é o 1º da espera: %s', v);
end $$;

set local "request.jwt.claim.sub" = 'd0000000-0000-0000-0000-00000000000d';
do $$
declare v jsonb;
begin
  perform pg_temp.scan('d0000000-0000-0000-0000-00000000000d',
                       'aaaa0000-0000-0000-0000-00000000000a', 'tok-duda-1');
  v := public.join_queue('tok-duda-1', 'single');
  assert (v ->> 'position')::int = 2, format('Duda é a 2ª: %s', v);
end $$;

-- Ana (lado A) vence: ela fica, o Bruno sai, e o Caio é chamado
set local "request.jwt.claim.sub" = 'a0000000-0000-0000-0000-00000000000a';
do $$
declare
  v_match uuid; v jsonb; v_holder uuid; v_ana uuid; v_bruno uuid;
  v_caio_status public.queue_entry_status; v_call timestamptz;
begin
  select id into v_match from public.matches where ended_at is null;
  select side_a_entry_id, side_b_entry_id into v_ana, v_bruno
  from public.matches where id = v_match;

  v := public.report_match_result(v_match, 'a');
  assert v ->> 'winner_side' = 'a', format('vencedor lado A: %s', v);
  assert v ->> 'end_reason' = 'reported', 'encerrada por relato';
  assert not (v ->> 'is_live')::boolean, 'partida encerrada';

  -- Ana segue mandante, com a inscrição ainda em jogo
  select holder_entry_id into v_holder from public.courts
  where id = 'aaaa0000-0000-0000-0000-00000000000a';
  assert v_holder = v_ana, 'a vencedora deveria virar mandante';

  assert (select status from public.queue_entries where id = v_ana) = 'playing',
    'a mandante continua em jogo';
  assert (select status from public.queue_entries where id = v_bruno) = 'done',
    'quem perdeu saiu';

  -- Caio foi chamado, com prazo
  select e.status, e.call_expires_at into v_caio_status, v_call
  from public.queue_entries e
  where e.created_by = 'c0000000-0000-0000-0000-00000000000c';

  assert v_caio_status = 'ready', format('Caio deveria estar chamado: %s', v_caio_status);
  assert v_call > now() and v_call <= now() + interval '301 seconds',
    format('janela de ~5 min: %s', v_call);
end $$;

-- A notificação da vez saiu
do $$
declare v_turn integer;
begin
  select count(*) into v_turn
  from public.notification_outbox o
  join public.queue_entry_members m on m.entry_id = o.entry_id
  where o.type = 'queue_turn' and m.user_id = 'c0000000-0000-0000-0000-00000000000c';
  assert v_turn = 1, format('Caio deveria ter 1 push "É a sua vez!": %s', v_turn);
end $$;

-- =====================================================================
-- Caio faz o check-in e encara a mandante
-- =====================================================================
set local "request.jwt.claim.sub" = 'c0000000-0000-0000-0000-00000000000c';
do $$
declare v jsonb;
begin
  perform pg_temp.scan('c0000000-0000-0000-0000-00000000000c',
                       'aaaa0000-0000-0000-0000-00000000000a', 'tok-caio-start');
  v := public.check_in_and_start('tok-caio-start');

  assert (v ->> 'is_live')::boolean, 'nova partida ao vivo';
  assert not (v -> 'side_b' ->> 'open')::boolean, 'lado B é a mandante';
  assert (v -> 'side_b' -> 'players' -> 0 ->> 'username') = 'ana',
    format('a Ana deveria estar no lado B: %s', v -> 'side_b');
  assert (v -> 'side_a' -> 'players' -> 0 ->> 'username') = 'caio', 'Caio no lado A';
end $$;

-- Duda ainda não é a vez
set local "request.jwt.claim.sub" = 'd0000000-0000-0000-0000-00000000000d';
do $$
declare v_code text;
begin
  perform pg_temp.scan('d0000000-0000-0000-0000-00000000000d',
                       'aaaa0000-0000-0000-0000-00000000000a', 'tok-duda-2');
  begin
    perform public.check_in_and_start('tok-duda-2');
    assert false, 'fora da vez deveria falhar';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code in ('NQ015', 'NQ017'), format('esperava NQ015/NQ017, obtive %s', v_code);
  end;
end $$;

-- =====================================================================
-- Slot estourado: encerra sem vencedor e a fila anda
-- =====================================================================
do $$
declare v jsonb; v_match uuid; v_holder uuid; v_duda_status public.queue_entry_status;
begin
  select id into v_match from public.matches where ended_at is null;
  -- Simula o relógio: o slot venceu e ninguém reportou.
  update public.matches set expires_at = now() - interval '1 second' where id = v_match;

  v := public.advance_expired_queues();
  assert (v ->> 'matches_closed')::int = 1, format('1 partida encerrada: %s', v);

  assert (select end_reason from public.matches where id = v_match) = 'slot_expired',
    'motivo deveria ser slot_expired';
  assert (select winner_side from public.matches where id = v_match) is null,
    'sem vencedor quando ninguém reporta';

  -- Sem vencedor, a quadra fica sem mandante e os dois lados saem
  select holder_entry_id into v_holder from public.courts
  where id = 'aaaa0000-0000-0000-0000-00000000000a';
  assert v_holder is null, format('quadra deveria ficar sem mandante: %s', v_holder);

  -- E a Duda foi chamada
  select status into v_duda_status from public.queue_entries
  where created_by = 'd0000000-0000-0000-0000-00000000000d';
  assert v_duda_status = 'ready', format('Duda deveria ser chamada: %s', v_duda_status);
end $$;

-- =====================================================================
-- Chamada não atendida: perde a vez
-- =====================================================================
set local "request.jwt.claim.sub" = 'e0000000-0000-0000-0000-00000000000e';
do $$
declare v jsonb;
begin
  perform pg_temp.scan('e0000000-0000-0000-0000-00000000000e',
                       'aaaa0000-0000-0000-0000-00000000000a', 'tok-elias-1');
  v := public.join_queue('tok-elias-1', 'single');
  assert (v ->> 'position')::int = 2, format('Elias é o 2º: %s', v);
end $$;

do $$
declare v jsonb; v_duda public.queue_entry_status; v_elias public.queue_entry_status;
begin
  -- A janela da Duda venceu
  update public.queue_entries set call_expires_at = now() - interval '1 second'
  where created_by = 'd0000000-0000-0000-0000-00000000000d' and status = 'ready';

  v := public.advance_expired_queues();
  assert (v ->> 'entries_expired')::int = 1, format('1 chamada expirada: %s', v);

  select status into v_duda  from public.queue_entries where created_by = 'd0000000-0000-0000-0000-00000000000d';
  select status into v_elias from public.queue_entries where created_by = 'e0000000-0000-0000-0000-00000000000e';

  assert v_duda = 'expired', format('Duda perdeu a vez: %s', v_duda);
  assert (select cancel_reason from public.queue_entries
          where created_by = 'd0000000-0000-0000-0000-00000000000d') = 'no_show',
    'motivo no_show';
  assert v_elias = 'ready', format('Elias assume a vez: %s', v_elias);
end $$;

-- Check-in depois da janela é recusado
do $$
declare v_code text;
begin
  update public.queue_entries set call_expires_at = now() - interval '1 second'
  where created_by = 'e0000000-0000-0000-0000-00000000000e';

  perform pg_temp.scan('e0000000-0000-0000-0000-00000000000e',
                       'aaaa0000-0000-0000-0000-00000000000a', 'tok-elias-2');
  begin
    perform public.check_in_and_start('tok-elias-2');
    assert false, 'check-in fora da janela deveria falhar';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ016', format('esperava NQ016, obtive %s', v_code);
  end;
end $$;

-- =====================================================================
-- Telas
-- =====================================================================
do $$
declare v jsonb; v_q jsonb;
begin
  v := public.court_screen('aaaa0000-0000-0000-0000-00000000000a');

  assert v -> 'court' ->> 'name' = 'Quadra 01', format('nome: %s', v -> 'court' ->> 'name');
  assert v -> 'court' ->> 'surface_label' = 'Saibro', 'superfície traduzida';
  assert (v -> 'court' ->> 'slot_minutes')::int = 40, 'slot na tela';
  assert v -> 'park' ->> 'district' = 'Vila Mariana · Zona Sul', 'distrito do parque';
  assert not (v ->> 'is_live')::boolean, 'quadra livre agora';
  assert v ->> 'status_text' = 'Livre', 'texto de status';
  assert v ->> 'players_line' = 'Sem jogo agora — check-in libera a quadra',
    format('linha de jogadores: %s', v ->> 'players_line');

  -- O Elias segue na fila
  assert (v ->> 'queue_length')::int = 1, format('1 na fila: %s', v ->> 'queue_length');
  v_q := v -> 'queue' -> 0;
  assert (v_q ->> 'position')::int = 1, 'posição 1';
  assert v_q ->> 'position_label' = '1º', 'rótulo da posição';
  assert v_q ->> 'mode_label' = 'Simples 1x1', 'rótulo da modalidade';
  assert v_q -> 'racket' ->> 'frame' is not null, 'raquete com cor de aro';
  assert jsonb_array_length(v_q -> 'stack') = 1, 'pilha com a própria raquete';
  assert (v_q ->> 'stack_more')::int = 0, 'nada atrás';
  assert v_q ->> 'team_label' = 'Elias P.', format('rótulo do time: %s', v_q ->> 'team_label');
end $$;

-- Tela do parque agrega as quadras
do $$
declare v jsonb;
begin
  v := public.park_screen('11110000-0000-0000-0000-000000000001');
  assert jsonb_array_length(v -> 'courts') = 3, format('3 quadras: %s', jsonb_array_length(v -> 'courts'));
  assert (v -> 'summary' ->> 'courts')::int = 3, 'resumo de quadras';
  assert (v -> 'summary' ->> 'live')::int = 0, 'nenhuma em jogo';
  assert (v -> 'summary' ->> 'queued')::int = 1, 'um time na fila';
  assert v -> 'park' ->> 'name' = 'Parque Ibirapuera (teste)', 'nome do parque';
end $$;

-- my_queue_state para quem está chamado
do $$
declare v jsonb;
begin
  v := public.my_queue_state();
  assert v ->> 'state' = 'called', format('Elias está chamado: %s', v ->> 'state');
  assert v ->> 'court_name' = 'Quadra 01', 'quadra';
  assert v ->> 'park_name' = 'Parque Ibirapuera (teste)', 'parque';
  assert (v ->> 'position')::int = 1, 'posição 1';
  assert v -> 'call_remaining_seconds' is not null, 'contagem da chamada presente';
end $$;

-- Quem não está em fila nenhuma
set local "request.jwt.claim.sub" = 'f0000000-0000-0000-0000-00000000000f';
do $$
declare v jsonb;
begin
  v := public.my_queue_state();
  assert v ->> 'state' = 'free', format('Flávia livre: %s', v);

  v := public.court_screen('bbbb0000-0000-0000-0000-00000000000b');
  assert (v ->> 'can_join')::boolean, 'Flávia pode entrar';

  v := public.court_screen('aaaa0000-0000-0000-0000-00000000000a');
  assert (v ->> 'can_join')::boolean, 'e também aqui';
end $$;

-- Quem já está em fila não pode entrar em outra (reflete na tela)
set local "request.jwt.claim.sub" = 'e0000000-0000-0000-0000-00000000000e';
do $$
declare v jsonb;
begin
  v := public.court_screen('bbbb0000-0000-0000-0000-00000000000b');
  assert not (v ->> 'can_join')::boolean, 'Elias já está em uma fila';
  assert (v ->> 'court_accepting')::boolean,
    'a quadra aceita entradas — o bloqueio é do jogador, não dela';
  assert v -> 'my_state' ->> 'where' like 'Na fila%', format('estado: %s', v -> 'my_state');
end $$;

-- =====================================================================
-- Perfil: raquete e paleta
-- =====================================================================
do $$
declare v jsonb; v_code text;
begin
  v := public.update_my_profile('Elias Prado Neto', '#B13F16', '#74B69D', 2::smallint);
  assert v ->> 'racket_frame_color' = '#B13F16', format('aro: %s', v);
  assert v ->> 'racket_grip_color'  = '#74B69D', 'grip';
  assert (v ->> 'avatar_tone')::int = 2, 'tom do avatar';
  assert v ->> 'full_name' = 'Elias Prado Neto', 'nome atualizado';
  assert v ->> 'initials' = 'EN', format('iniciais recalculadas: %s', v ->> 'initials');

  -- Cor fora da paleta
  begin
    perform public.update_my_profile(null, '#123456');
    assert false, 'cor fora da paleta deveria falhar';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ019', format('esperava NQ019, obtive %s', v_code);
  end;
end $$;

-- A raquete nova aparece na pilha da fila
do $$
declare v jsonb;
begin
  v := public.court_screen('aaaa0000-0000-0000-0000-00000000000a');
  assert v -> 'queue' -> 0 -> 'racket' ->> 'frame' = '#B13F16',
    format('a pilha deveria usar a cor escolhida: %s', v -> 'queue' -> 0 -> 'racket');
end $$;

-- =====================================================================
-- Saída da fila libera o jogador para outra quadra
-- =====================================================================
do $$
declare v_entry uuid; v jsonb;
begin
  select id into v_entry from public.queue_entries
  where created_by = 'e0000000-0000-0000-0000-00000000000e' and status in ('waiting','ready');

  perform public.leave_queue(v_entry, 'mudou de ideia');

  assert (public.player_state('e0000000-0000-0000-0000-00000000000e') ->> 'state') = 'free',
    'depois de sair, o jogador fica livre';

  perform pg_temp.scan('e0000000-0000-0000-0000-00000000000e',
                       'bbbb0000-0000-0000-0000-00000000000b', 'tok-elias-3');
  v := public.join_queue('tok-elias-3', 'single');
  assert (v ->> 'position')::int = 1, 'agora pode entrar em outra quadra';
end $$;

-- =====================================================================
-- Duplas: os dois jogadores ficam presos à mesma fila
-- =====================================================================
set local "request.jwt.claim.sub" = 'f0000000-0000-0000-0000-00000000000f';
do $$
declare v jsonb; v_code text;
begin
  perform pg_temp.scan('f0000000-0000-0000-0000-00000000000f',
                       'cccc0000-0000-0000-0000-00000000000c', 'tok-fla-1');
  v := public.join_queue('tok-fla-1', 'double', '@caio');
  assert jsonb_array_length(v -> 'players') = 2, format('dupla com 2: %s', v);

  -- O parceiro também fica indisponível
  assert (public.player_state('c0000000-0000-0000-0000-00000000000c') ->> 'state') = 'queued',
    'o parceiro entra na mesma fila';
  assert (public.player_state('c0000000-0000-0000-0000-00000000000c') ->> 'court_name') = 'Quadra 03',
    'na quadra certa';
end $$;

-- Slot de 60 min da Quadra 03 vale na estimativa
do $$
declare v jsonb;
begin
  v := public.court_screen('cccc0000-0000-0000-0000-00000000000c');
  assert (v -> 'court' ->> 'slot_minutes')::int = 60, 'slot próprio da quadra';
  assert v -> 'court' ->> 'surface_label' = 'Grama', 'grama';
  assert (v ->> 'total_wait_seconds')::int = 3600, format('1 time x 60 min: %s', v ->> 'total_wait_seconds');
end $$;

rollback;

\echo '✔ tests/local/40_sprint3_test.sql — parques, partidas com dois lados, check-in e chamada'
