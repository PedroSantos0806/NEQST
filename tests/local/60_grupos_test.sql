-- =====================================================================
-- Sprint 4: a vaga na fila é de um grupo.
--   uma pessoa abre a vaga; os amigos entram escaneando a quadra,
--   pedindo (o dono aprova) ou com o PIN
--   uma pessoa, uma vaga — sair da atual para entrar no grupo do amigo
--   um check-in basta; quem chega depois entra com o turno rolando
--   a vaga não se perde enquanto houver alguém nela
-- =====================================================================
\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('a1000000-0000-0000-0000-0000000000a1', 'g-ana@example.com',    '{"full_name":"Ana Grupo"}'),
  ('b1000000-0000-0000-0000-0000000000b1', 'g-bruno@example.com',  '{"full_name":"Bruno Grupo"}'),
  ('c1000000-0000-0000-0000-0000000000c1', 'g-caio@example.com',   '{"full_name":"Caio Grupo"}'),
  ('d1000000-0000-0000-0000-0000000000d1', 'g-duda@example.com',   '{"full_name":"Duda Grupo"}'),
  ('e1000000-0000-0000-0000-0000000000e1', 'g-elias@example.com',  '{"full_name":"Elias Grupo"}'),
  ('f1000000-0000-0000-0000-0000000000f1', 'g-flavia@example.com', '{"full_name":"Flávia Grupo"}'),
  ('91000000-0000-0000-0000-000000000091', 'g-gabi@example.com',   '{"full_name":"Gabi Grupo"}'),
  ('81000000-0000-0000-0000-000000000081', 'g-hugo@example.com',   '{"full_name":"Hugo Grupo"}'),
  ('71000000-0000-0000-0000-000000000071', 'g-ivo@example.com',    '{"full_name":"Ivo Grupo"}');

insert into public.parks (id, slug, name, district, latitude, longitude)
values ('33330000-0000-0000-0000-000000000003', 'teste-grupos', 'Parque dos Grupos (teste)',
        'Centro', -23.550000, -46.630000);

insert into public.courts (id, park_id, court_number, surface, slot_minutes, slug, name,
                           latitude, longitude)
values
  ('a1a10000-0000-0000-0000-0000000000a1', '33330000-0000-0000-0000-000000000003', 1, 'clay', 40,
   'teste-grupos-q1', 'Quadra 01', -23.550000, -46.630000),
  ('b1b10000-0000-0000-0000-0000000000b1', '33330000-0000-0000-0000-000000000003', 2, 'hard', 40,
   'teste-grupos-q2', 'Quadra 02', -23.550100, -46.630100);

create or replace function pg_temp.scan(p_user uuid, p_court uuid, p_token text)
returns void language sql as $$
  insert into public.scan_tokens
    (token_hash, user_id, court_id, latitude, longitude, distance_meters, expires_at)
  select public.hash_scan_token(p_token), p_user, c.id, c.latitude, c.longitude, 8,
         now() + interval '30 seconds'
  from public.courts c where c.id = p_court;
$$;

create or replace function pg_temp.as_user(p_user uuid)
returns void language sql as $$
  select set_config('request.jwt.claim.sub', p_user::text, true);
$$;

-- A vaga do grupo da Ana (o id muda a cada teste que recria a vaga)
create or replace function pg_temp.ana_entry()
returns uuid language sql as $$
  select e.id from public.queue_entries e
  where e.created_by = 'a1000000-0000-0000-0000-0000000000a1'
    and e.court_id = 'a1a10000-0000-0000-0000-0000000000a1'
  order by e.queue_number desc limit 1;
$$;

create or replace function pg_temp.pin_of(p_entry uuid)
returns text language sql as $$
  select pin from public.queue_entry_pins where entry_id = p_entry;
$$;

-- A tolerância nasce em 2 minutos
do $$ begin
  assert (select call_window_seconds from public.courts
          where id = 'a1a10000-0000-0000-0000-0000000000a1') = 120, 'tolerância padrão de 120s';
end $$;

-- =====================================================================
-- Hugo está jogando: a fila da Quadra 01 espera
-- =====================================================================
do $$
declare v jsonb;
begin
  perform pg_temp.as_user('81000000-0000-0000-0000-000000000081');
  perform pg_temp.scan('81000000-0000-0000-0000-000000000081', 'a1a10000-0000-0000-0000-0000000000a1', 'g-hugo-1');
  perform public.join_queue('g-hugo-1');
  perform pg_temp.scan('81000000-0000-0000-0000-000000000081', 'a1a10000-0000-0000-0000-0000000000a1', 'g-hugo-2');
  v := public.check_in_and_start('g-hugo-2');
  assert (v ->> 'is_live')::boolean, format('Hugo em quadra: %s', v);
end $$;

-- =====================================================================
-- Ana guarda o lugar sozinha
-- =====================================================================
do $$
declare v jsonb; v_group jsonb;
begin
  perform pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
  perform pg_temp.scan('a1000000-0000-0000-0000-0000000000a1', 'a1a10000-0000-0000-0000-0000000000a1', 'g-ana-1');
  v := public.join_queue('g-ana-1');
  assert (v ->> 'position')::int = 1, format('Ana é a 1ª: %s', v);
  assert jsonb_array_length(v -> 'players') = 1, 'sozinha';

  v := public.court_screen('a1a10000-0000-0000-0000-0000000000a1');
  v_group := v -> 'my_group';
  assert v_group ->> 'pin' ~ '^[0-9]{4}$', format('a Ana vê o PIN do grupo: %s', v_group);
  assert (v_group ->> 'is_owner')::boolean, 'a Ana é a dona';
  assert v -> 'my_entry' ->> 'group_label' = 'Solo', format('rótulo: %s', v -> 'my_entry');
end $$;

-- Quem está fora do grupo não vê o PIN em lugar nenhum
do $$
declare v jsonb; v_pin text;
begin
  v_pin := pg_temp.pin_of(pg_temp.ana_entry());
  perform pg_temp.as_user('b1000000-0000-0000-0000-0000000000b1');

  v := public.court_screen('a1a10000-0000-0000-0000-0000000000a1');
  assert v -> 'my_group' = 'null'::jsonb or v -> 'my_group' is null, 'Bruno não tem grupo aqui';
  assert v::text not like '%"pin"%', format('o PIN não sai para quem é de fora: %s', v);
  assert public.my_group(pg_temp.ana_entry()) is null, 'my_group recusa quem é de fora';
  assert public.my_queue_state()::text not like '%' || v_pin || '%', 'nem pelo my_queue_state';
end $$;

-- =====================================================================
-- Bruno pede para entrar; Ana recusa, depois aceita
-- =====================================================================
do $$
declare v jsonb;
begin
  perform pg_temp.as_user('b1000000-0000-0000-0000-0000000000b1');
  perform pg_temp.scan('b1000000-0000-0000-0000-0000000000b1', 'a1a10000-0000-0000-0000-0000000000a1', 'g-bru-1');
  v := public.request_join('g-bru-1', pg_temp.ana_entry());
  assert v ->> 'status' = 'pending', format('pedido pendente: %s', v);

  v := public.court_screen('a1a10000-0000-0000-0000-0000000000a1');
  assert v -> 'my_request' ->> 'owner_name' = 'Ana G.', format('Bruno vê o pedido: %s', v -> 'my_request');
  assert (public.player_state('b1000000-0000-0000-0000-0000000000b1') ->> 'state') = 'free',
    'pedir não ocupa vaga';

  assert exists (select 1 from public.notification_outbox
                 where user_id = 'a1000000-0000-0000-0000-0000000000a1' and type = 'group_join_request'),
    'a dona recebe o pedido';
end $$;

-- O pedido precisa de presença: o scan é da quadra do grupo
do $$
declare v_code text;
begin
  perform pg_temp.as_user('c1000000-0000-0000-0000-0000000000c1');
  perform pg_temp.scan('c1000000-0000-0000-0000-0000000000c1', 'b1b10000-0000-0000-0000-0000000000b1', 'g-caio-outra');
  begin
    perform public.request_join('g-caio-outra', pg_temp.ana_entry());
    assert false, 'scan de outra quadra não serve';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ002', format('esperava NQ002, obtive %s', v_code);
  end;
end $$;

-- Só a dona decide
do $$
declare v_code text; v_request uuid;
begin
  select id into v_request from public.queue_join_requests
  where user_id = 'b1000000-0000-0000-0000-0000000000b1' and status = 'pending';

  perform pg_temp.as_user('c1000000-0000-0000-0000-0000000000c1');
  begin
    perform public.decide_join_request(v_request, true);
    assert false, 'quem não é dono não aprova';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ008', format('esperava NQ008, obtive %s', v_code);
  end;

  perform pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
  assert jsonb_array_length(public.my_group(pg_temp.ana_entry()) -> 'pending_requests') = 1,
    'a Ana vê 1 pedido';
  assert (public.decide_join_request(v_request, false)) ->> 'status' = 'rejected', 'recusado';
  assert jsonb_array_length(public.my_group(pg_temp.ana_entry()) -> 'players') = 1, 'grupo continua com 1';
end $$;

do $$
declare v jsonb; v_request uuid;
begin
  perform pg_temp.as_user('b1000000-0000-0000-0000-0000000000b1');
  perform pg_temp.scan('b1000000-0000-0000-0000-0000000000b1', 'a1a10000-0000-0000-0000-0000000000a1', 'g-bru-2');
  v := public.request_join('g-bru-2', pg_temp.ana_entry());
  v_request := (v ->> 'request_id')::uuid;

  perform pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
  v := public.decide_join_request(v_request, true);
  assert v ->> 'status' = 'approved', format('aceito: %s', v);

  v := public.queue_entry_state(pg_temp.ana_entry());
  assert jsonb_array_length(v -> 'players') = 2, format('grupo com 2: %s', v);
  assert (v ->> 'position')::int = 1, 'mesma posição';
  assert (public.player_state('b1000000-0000-0000-0000-0000000000b1') ->> 'entry_id')::uuid = pg_temp.ana_entry(),
    'Bruno está na vaga da Ana';

  assert exists (select 1 from public.notification_outbox
                 where user_id = 'b1000000-0000-0000-0000-0000000000b1' and type = 'group_join_approved'),
    'Bruno é avisado';

  -- Pedido já decidido não volta
  begin
    perform public.decide_join_request(v_request, true);
    assert false, 'decidir duas vezes deveria falhar';
  exception when others then
    assert sqlstate = 'NQ027', format('esperava NQ027, obtive %s', sqlstate);
  end;
end $$;

-- Bruno, agora no grupo, não abre outra vaga
do $$
declare v_code text;
begin
  perform pg_temp.as_user('b1000000-0000-0000-0000-0000000000b1');
  perform pg_temp.scan('b1000000-0000-0000-0000-0000000000b1', 'b1b10000-0000-0000-0000-0000000000b1', 'g-bru-3');
  begin
    perform public.join_queue('g-bru-3');
    assert false, 'uma pessoa, uma vaga';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ014', format('esperava NQ014, obtive %s', v_code);
  end;
end $$;

-- =====================================================================
-- Caio está em outra fila: precisa sair dela para entrar com a Ana
-- =====================================================================
do $$
declare v jsonb; v_code text; v_msg text; v_old uuid;
begin
  perform pg_temp.as_user('c1000000-0000-0000-0000-0000000000c1');
  perform pg_temp.scan('c1000000-0000-0000-0000-0000000000c1', 'b1b10000-0000-0000-0000-0000000000b1', 'g-caio-1');
  v := public.join_queue('g-caio-1');
  v_old := (v ->> 'entry_id')::uuid;

  perform pg_temp.scan('c1000000-0000-0000-0000-0000000000c1', 'a1a10000-0000-0000-0000-0000000000a1', 'g-caio-2');
  begin
    perform public.request_join('g-caio-2', pg_temp.ana_entry());
    assert false, 'em outra fila, o pedido deveria ser barrado';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate, v_msg = message_text;
    assert v_code = 'NQ014', format('esperava NQ014, obtive %s', v_code);
    assert v_msg like '%saia da sua fila atual%quadra 02%', format('o aviso diz de onde sair: %s', v_msg);
  end;

  -- Confirmou o aviso e pediu. A exceção acima desfez tudo, então o
  -- mesmo scan ainda vale. Enquanto espera, continua na fila dele.
  v := public.request_join('g-caio-2', pg_temp.ana_entry(), true);
  assert v ->> 'status' = 'pending', format('pedido feito: %s', v);
  assert (select status from public.queue_entries where id = v_old) in ('waiting', 'ready'),
    'esperando resposta, o Caio não perde a vaga dele';
  assert (public.player_state('c1000000-0000-0000-0000-0000000000c1') ->> 'entry_id')::uuid = v_old,
    'continua na Quadra 02';

  -- Recusado: nada muda para ele
  perform pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
  perform public.decide_join_request((v ->> 'request_id')::uuid, false);
  assert (select status from public.queue_entries where id = v_old) in ('waiting', 'ready'),
    'recusado, segue na fila em que estava';

  -- Pede de novo e é aceito: só agora sai da fila antiga
  perform pg_temp.as_user('c1000000-0000-0000-0000-0000000000c1');
  perform pg_temp.scan('c1000000-0000-0000-0000-0000000000c1', 'a1a10000-0000-0000-0000-0000000000a1', 'g-caio-2b');
  v := public.request_join('g-caio-2b', pg_temp.ana_entry(), true);

  perform pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
  assert public.decide_join_request((v ->> 'request_id')::uuid, true) ->> 'status' = 'approved', 'aceito';
  assert (select status from public.queue_entries where id = v_old) = 'cancelled',
    'aceito, a vaga que era só dele sumiu';
  assert (public.player_state('c1000000-0000-0000-0000-0000000000c1') ->> 'entry_id')::uuid = pg_temp.ana_entry(),
    'o Caio está no grupo da Ana';
  assert jsonb_array_length(public.my_group(pg_temp.ana_entry()) -> 'players') = 3, 'grupo com 3';
end $$;

-- Pediu estando livre e abriu outra vaga enquanto esperava: o pedido
-- morre ali, e aceitar depois não o arranca da vaga que escolheu.
do $$
declare v jsonb;
begin
  perform pg_temp.as_user('91000000-0000-0000-0000-000000000091');
  perform pg_temp.scan('91000000-0000-0000-0000-000000000091', 'a1a10000-0000-0000-0000-0000000000a1', 'g-gabi-0');
  v := public.request_join('g-gabi-0', pg_temp.ana_entry());
  perform pg_temp.scan('91000000-0000-0000-0000-000000000091', 'b1b10000-0000-0000-0000-0000000000b1', 'g-gabi-q2');
  perform public.join_queue('g-gabi-q2');

  assert (select status from public.queue_join_requests
          where id = (v ->> 'request_id')::uuid) = 'cancelled', 'abrir vaga cancela o pedido';

  perform pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
  begin
    perform public.decide_join_request((v ->> 'request_id')::uuid, true);
    assert false, 'pedido cancelado não pode ser aceito';
  exception when others then
    assert sqlstate = 'NQ027', format('esperava NQ027, obtive %s', sqlstate);
  end;
  assert (public.player_state('91000000-0000-0000-0000-000000000091') ->> 'court_name') = 'Quadra 02',
    'Gabi segue na fila que escolheu';

  perform pg_temp.as_user('91000000-0000-0000-0000-000000000091');
  perform public.leave_queue((public.player_state('91000000-0000-0000-0000-000000000091') ->> 'entry_id')::uuid);
end $$;

-- =====================================================================
-- PIN: errar conta tentativa e gasta o scan; acertar entra direto
-- =====================================================================
do $$
declare v jsonb; v_pin text; v_wrong text;
begin
  v_pin := pg_temp.pin_of(pg_temp.ana_entry());
  v_wrong := lpad(((v_pin::int + 1) % 10000)::text, 4, '0');

  perform pg_temp.as_user('d1000000-0000-0000-0000-0000000000d1');
  perform pg_temp.scan('d1000000-0000-0000-0000-0000000000d1', 'a1a10000-0000-0000-0000-0000000000a1', 'g-duda-1');
  v := public.join_with_pin('g-duda-1', v_wrong);
  assert not (v ->> 'joined')::boolean, format('PIN errado não entra: %s', v);
  assert v ->> 'code' = 'PIN_INVALID', 'código do erro';
  assert (v ->> 'attempts_left')::int = 4, format('restam 4: %s', v);

  -- O scan foi gasto: tentar de novo exige outra leitura na quadra
  begin
    perform public.join_with_pin('g-duda-1', v_pin);
    assert false, 'scan gasto não vale';
  exception when others then
    assert sqlstate = 'NQ002', format('esperava NQ002, obtive %s', sqlstate);
  end;

  perform pg_temp.scan('d1000000-0000-0000-0000-0000000000d1', 'a1a10000-0000-0000-0000-0000000000a1', 'g-duda-2');
  v := public.join_with_pin('g-duda-2', v_pin);
  assert (v ->> 'joined')::boolean, format('PIN certo entra: %s', v);
  assert (v ->> 'entry_id')::uuid = pg_temp.ana_entry(), 'na vaga da Ana';
end $$;

-- Cinco erros travam por 15 minutos, mesmo com o PIN certo depois
do $$
declare v jsonb; v_pin text; v_wrong text;
begin
  v_pin := pg_temp.pin_of(pg_temp.ana_entry());
  v_wrong := lpad(((v_pin::int + 1) % 10000)::text, 4, '0');
  perform pg_temp.as_user('71000000-0000-0000-0000-000000000071');

  for i in 1..5 loop
    perform pg_temp.scan('71000000-0000-0000-0000-000000000071', 'a1a10000-0000-0000-0000-0000000000a1', 'g-ivo-' || i);
    v := public.join_with_pin('g-ivo-' || i, v_wrong);
    assert not (v ->> 'joined')::boolean, 'errado';
  end loop;
  assert (v ->> 'attempts_left')::int = 0, format('sem tentativas: %s', v);

  perform pg_temp.scan('71000000-0000-0000-0000-000000000071', 'a1a10000-0000-0000-0000-0000000000a1', 'g-ivo-6');
  begin
    perform public.join_with_pin('g-ivo-6', v_pin);
    assert false, 'travado deveria falhar';
  exception when others then
    assert sqlstate = 'NQ028', format('esperava NQ028, obtive %s', sqlstate);
  end;
end $$;

-- Sem limite de tamanho: cinco pessoas na mesma vaga
do $$
declare v jsonb;
begin
  perform pg_temp.as_user('e1000000-0000-0000-0000-0000000000e1');
  perform pg_temp.scan('e1000000-0000-0000-0000-0000000000e1', 'a1a10000-0000-0000-0000-0000000000a1', 'g-elias-1');
  v := public.join_with_pin('g-elias-1', pg_temp.pin_of(pg_temp.ana_entry()));
  assert (v ->> 'joined')::boolean, format('Elias entra: %s', v);

  v := public.court_screen('a1a10000-0000-0000-0000-0000000000a1');
  assert (v -> 'my_entry' ->> 'group_size')::int = 5, format('5 na vaga: %s', v -> 'my_entry');
  assert v -> 'my_entry' ->> 'group_label' = '5 jogadores', 'rótulo';
  assert v -> 'my_entry' ->> 'team_label' = 'Ana G. + Bruno G. + 3', format('linha: %s', v -> 'my_entry' ->> 'team_label');
  assert (v -> 'my_entry' ->> 'position')::int = 1, 'continua em 1º';
end $$;

-- =====================================================================
-- A dona sai antes do turno: o grupo fica, e o mais antigo herda
-- =====================================================================
do $$
declare v jsonb; v_entry uuid;
begin
  v_entry := pg_temp.ana_entry();
  perform pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
  v := public.leave_queue(v_entry);
  assert v ->> 'status' = 'waiting', format('a vaga continua: %s', v);
  assert (v ->> 'remaining_members')::int = 4, 'restam 4';
  assert (public.player_state('a1000000-0000-0000-0000-0000000000a1') ->> 'state') = 'free', 'Ana livre';

  assert (select m.user_id from public.queue_entry_members m
          where m.entry_id = v_entry and m.is_active and m.role = 'owner')
         = 'b1000000-0000-0000-0000-0000000000b1', 'Bruno herda a vaga';
  assert not exists (select 1 from public.queue_entry_members
                     where entry_id = v_entry and user_id = 'a1000000-0000-0000-0000-0000000000a1'),
    'quem sai antes do turno não fica no grupo';

  perform pg_temp.as_user('b1000000-0000-0000-0000-0000000000b1');
  assert (public.my_group(v_entry) ->> 'is_owner')::boolean, 'Bruno é o dono agora';
end $$;

-- Ivo entra na fila atrás do grupo
do $$
begin
  delete from public.queue_pin_attempts where user_id = '71000000-0000-0000-0000-000000000071';
  perform pg_temp.as_user('71000000-0000-0000-0000-000000000071');
  perform pg_temp.scan('71000000-0000-0000-0000-000000000071', 'a1a10000-0000-0000-0000-0000000000a1', 'g-ivo-fila');
  assert (public.join_queue('g-ivo-fila') ->> 'position')::int = 2, 'Ivo é o 2º';
end $$;

-- =====================================================================
-- Hugo termina; o grupo é chamado e um check-in basta
-- =====================================================================
do $$
declare v jsonb; v_entry uuid; v_call timestamptz; v_match uuid; v_expires timestamptz;
begin
  v_entry := pg_temp.ana_entry();
  perform pg_temp.as_user('81000000-0000-0000-0000-000000000081');
  perform public.finish_my_turn((select id from public.matches
                                  where court_id = 'a1a10000-0000-0000-0000-0000000000a1' and ended_at is null));

  select call_expires_at into v_call from public.queue_entries where id = v_entry;
  assert (select status from public.queue_entries where id = v_entry) = 'ready', 'grupo chamado';
  assert v_call <= now() + interval '121 seconds', format('tolerância de 2 min: %s', v_call);

  -- Bruno chega sozinho e faz o check-in: o turno começa
  perform pg_temp.as_user('b1000000-0000-0000-0000-0000000000b1');
  perform pg_temp.scan('b1000000-0000-0000-0000-0000000000b1', 'a1a10000-0000-0000-0000-0000000000a1', 'g-bru-start');
  v := public.check_in_and_start('g-bru-start');
  assert (v ->> 'is_live')::boolean, format('turno ao vivo: %s', v);
  assert (v ->> 'group_size')::int = 4, format('o grupo inteiro está no turno: %s', v);
  assert (select count(*) from jsonb_array_elements(v -> 'players') p
          where (p ->> 'checked_in')::boolean) = 1, 'só o Bruno fez check-in';

  v_match := (v ->> 'match_id')::uuid;
  v_expires := (v ->> 'expires_at')::timestamptz;

  -- Elias, do grupo, chega depois: o check-in só registra que chegou
  perform pg_temp.as_user('e1000000-0000-0000-0000-0000000000e1');
  perform pg_temp.scan('e1000000-0000-0000-0000-0000000000e1', 'a1a10000-0000-0000-0000-0000000000a1', 'g-elias-start');
  v := public.check_in_and_start('g-elias-start');
  assert (v ->> 'match_id')::uuid = v_match, 'mesmo turno';
  assert (v ->> 'expires_at')::timestamptz = v_expires, 'o relógio não reinicia';
  assert (select count(*) from jsonb_array_elements(v -> 'players') p
          where (p ->> 'checked_in')::boolean) = 2, 'Bruno e Elias em quadra';
end $$;

-- Flávia chega atrasada e entra com o PIN, com o turno rolando
do $$
declare v jsonb; v_expires timestamptz;
begin
  select expires_at into v_expires from public.matches
  where court_id = 'a1a10000-0000-0000-0000-0000000000a1' and ended_at is null;

  perform pg_temp.as_user('f1000000-0000-0000-0000-0000000000f1');
  perform pg_temp.scan('f1000000-0000-0000-0000-0000000000f1', 'a1a10000-0000-0000-0000-0000000000a1', 'g-fla-1');
  v := public.join_with_pin('g-fla-1', pg_temp.pin_of(pg_temp.ana_entry()));
  assert (v ->> 'joined')::boolean and v ->> 'status' = 'playing', format('entra em quadra: %s', v);

  assert (select checked_in_at from public.queue_entry_members
          where entry_id = pg_temp.ana_entry() and user_id = 'f1000000-0000-0000-0000-0000000000f1') is not null,
    'quem entra com o turno rolando já está em quadra';
  assert (select expires_at from public.matches
          where court_id = 'a1a10000-0000-0000-0000-0000000000a1' and ended_at is null) = v_expires,
    'o tempo segue normal';
  assert (public.my_queue_state() ->> 'state') = 'playing', 'Flávia está jogando';
end $$;

-- Um pedido aberto para um grupo que está jogando também funciona
do $$
declare v jsonb;
begin
  perform pg_temp.as_user('91000000-0000-0000-0000-000000000091');
  perform pg_temp.scan('91000000-0000-0000-0000-000000000091', 'a1a10000-0000-0000-0000-0000000000a1', 'g-gabi-1');
  v := public.request_join('g-gabi-1', pg_temp.ana_entry());
  assert v ->> 'status' = 'pending', format('Gabi pede: %s', v);
end $$;

-- O pedido é visível para o grupo (é o que o Realtime entrega ao dono)
-- e para quem pediu — não para o resto do parque.
set local "request.jwt.claim.sub" = 'c1000000-0000-0000-0000-0000000000c1';
set local role authenticated;
do $$ begin
  assert (select count(*) from public.queue_join_requests
          where user_id = '91000000-0000-0000-0000-000000000091' and status = 'pending') = 1,
    'quem está no grupo vê o pedido';
end $$;
reset role;

set local "request.jwt.claim.sub" = '71000000-0000-0000-0000-000000000071';
set local role authenticated;
do $$ begin
  assert (select count(*) from public.queue_join_requests
          where user_id = '91000000-0000-0000-0000-000000000091') = 0,
    'quem é de fora não vê';

  begin
    perform 1 from public.queue_entry_pins;
    assert false, 'a tabela de PIN não pode ser lida direto';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- =====================================================================
-- Saídas com o turno rolando
-- =====================================================================
do $$
declare v jsonb; v_entry uuid; v_match uuid;
begin
  v_entry := pg_temp.ana_entry();
  select id into v_match from public.matches
  where court_id = 'a1a10000-0000-0000-0000-0000000000a1' and ended_at is null;

  -- Elias vai embora: fica registrado que jogou
  perform pg_temp.as_user('e1000000-0000-0000-0000-0000000000e1');
  v := public.leave_queue(v_entry);
  assert v ->> 'status' = 'playing', 'o turno segue';
  assert (select left_at from public.queue_entry_members
          where entry_id = v_entry and user_id = 'e1000000-0000-0000-0000-0000000000e1') is not null,
    'saída registrada';
  assert jsonb_array_length(public.match_state(v_match) -> 'players') = 4, 'placar sem o Elias';

  -- Saem todos: o turno acaba e o Ivo é chamado na hora
  foreach v_entry in array array[pg_temp.ana_entry()] loop
    perform pg_temp.as_user('b1000000-0000-0000-0000-0000000000b1');
    perform public.leave_queue(v_entry);
    perform pg_temp.as_user('c1000000-0000-0000-0000-0000000000c1');
    perform public.leave_queue(v_entry);
    perform pg_temp.as_user('d1000000-0000-0000-0000-0000000000d1');
    perform public.leave_queue(v_entry);
    perform pg_temp.as_user('f1000000-0000-0000-0000-0000000000f1');
    v := public.leave_queue(v_entry);
  end loop;

  assert v ->> 'status' = 'done', format('vaga encerrada: %s', v);
  assert (select end_reason from public.matches where id = v_match) = 'abandoned', 'turno abandonado';
  assert (select status from public.queue_entries
          where created_by = '71000000-0000-0000-0000-000000000071'
            and court_id = 'a1a10000-0000-0000-0000-0000000000a1') = 'ready', 'Ivo chamado';
  assert (select status from public.queue_join_requests
          where user_id = '91000000-0000-0000-0000-000000000091'
          order by created_at desc limit 1) = 'expired',
    'o pedido da Gabi morre com o grupo';
end $$;

-- =====================================================================
-- Chamado e ninguém aparece: a vez passa, e os pedidos expiram
-- =====================================================================
do $$
declare v_ivo uuid; v_ana uuid;
begin
  select id into v_ivo from public.queue_entries
  where created_by = '71000000-0000-0000-0000-000000000071' and status = 'ready';

  -- Ana entra atrás do Ivo; Gabi pede para entrar no grupo do Ivo
  perform pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
  perform pg_temp.scan('a1000000-0000-0000-0000-0000000000a1', 'a1a10000-0000-0000-0000-0000000000a1', 'g-ana-2');
  v_ana := (public.join_queue('g-ana-2') ->> 'entry_id')::uuid;

  perform pg_temp.as_user('91000000-0000-0000-0000-000000000091');
  perform pg_temp.scan('91000000-0000-0000-0000-000000000091', 'a1a10000-0000-0000-0000-0000000000a1', 'g-gabi-2');
  perform public.request_join('g-gabi-2', v_ivo);

  -- Os 2 minutos do Ivo passaram. Não precisa esperar o cron: o próximo
  -- check-in da quadra anda a fila.
  update public.queue_entries set call_expires_at = now() - interval '1 second' where id = v_ivo;

  perform pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
  perform pg_temp.scan('a1000000-0000-0000-0000-0000000000a1', 'a1a10000-0000-0000-0000-0000000000a1', 'g-ana-3');
  assert (public.check_in_and_start('g-ana-3') ->> 'is_live')::boolean, 'Ana assume a quadra';

  assert (select status from public.queue_entries where id = v_ivo) = 'expired', 'Ivo perdeu a vez';
  assert (select cancel_reason from public.queue_entries where id = v_ivo) = 'no_show', 'no_show';
  assert (select status from public.queue_join_requests
          where user_id = '91000000-0000-0000-0000-000000000091' and entry_id = v_ivo) = 'expired',
    'pedido para um grupo que perdeu a vez expira';
  assert pg_temp.pin_of(v_ana) is not null, 'cada vaga nova tem o seu PIN';
end $$;

-- Quem era o único chamado e sai: a vez passa na hora
do $$
declare v_ana uuid; v_bruno uuid;
begin
  perform pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');
  perform public.finish_my_turn((select id from public.matches
                                  where court_id = 'a1a10000-0000-0000-0000-0000000000a1' and ended_at is null));

  perform pg_temp.as_user('b1000000-0000-0000-0000-0000000000b1');
  perform pg_temp.scan('b1000000-0000-0000-0000-0000000000b1', 'a1a10000-0000-0000-0000-0000000000a1', 'g-bru-4');
  v_bruno := (public.join_queue('g-bru-4') ->> 'entry_id')::uuid;
  assert (select status from public.queue_entries where id = v_bruno) = 'ready', 'quadra vazia: Bruno chamado';

  perform pg_temp.as_user('c1000000-0000-0000-0000-0000000000c1');
  perform pg_temp.scan('c1000000-0000-0000-0000-0000000000c1', 'a1a10000-0000-0000-0000-0000000000a1', 'g-caio-3');
  perform public.join_queue('g-caio-3');

  perform pg_temp.as_user('b1000000-0000-0000-0000-0000000000b1');
  perform public.leave_queue(v_bruno);
  assert (select status from public.queue_entries where id = v_bruno) = 'cancelled', 'vaga do Bruno sumiu';
  assert (select status from public.queue_entries
          where created_by = 'c1000000-0000-0000-0000-0000000000c1'
            and court_id = 'a1a10000-0000-0000-0000-0000000000a1'
          order by queue_number desc limit 1) = 'ready', 'Caio chamado sem esperar o prazo';
end $$;

-- =====================================================================
-- Admin ajusta a tolerância
-- =====================================================================
do $$
declare v jsonb; v_court jsonb;
begin
  update public.profiles set role = 'player' where role = 'admin';
  update public.profiles set role = 'admin' where id = 'a1000000-0000-0000-0000-0000000000a1';
  perform pg_temp.as_user('a1000000-0000-0000-0000-0000000000a1');

  perform public.admin_upsert_court(p_id => 'a1a10000-0000-0000-0000-0000000000a1',
                                    p_call_window_seconds => 180);
  assert (select call_window_seconds from public.courts
          where id = 'a1a10000-0000-0000-0000-0000000000a1') = 180, 'tolerância de 3 min';

  v := public.admin_overview();
  select c into v_court
  from jsonb_array_elements(v -> 'parks') p, jsonb_array_elements(p -> 'courts') c
  where c ->> 'id' = 'a1a10000-0000-0000-0000-0000000000a1';
  assert (v_court ->> 'call_window_seconds')::int = 180, format('no painel: %s', v_court);

  begin
    perform public.admin_upsert_court(p_id => 'a1a10000-0000-0000-0000-0000000000a1',
                                      p_call_window_seconds => 30);
    assert false, 'abaixo de 60s deveria falhar';
  exception when check_violation then null;
  end;
end $$;

rollback;

\echo '✔ tests/local/60_grupos_test.sql — grupos, pedido de entrada, PIN, tolerância e saídas'
