-- =====================================================================
-- Teste funcional do fluxo da Sprint 1 (US-01 a US-04).
-- Roda contra um Postgres com o stub de auth (scripts/test-sql.sh).
-- Qualquer falha aborta com exceção.
-- =====================================================================
\set ON_ERROR_STOP on
\timing off

begin;

-- ---------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('11111111-1111-1111-1111-111111111111', 'ana@example.com',   '{"full_name":"Ana Souza"}'),
  ('22222222-2222-2222-2222-222222222222', 'bruno@example.com', '{"full_name":"Bruno Lima"}'),
  ('33333333-3333-3333-3333-333333333333', 'caio@example.com',  '{"full_name":"Caio Melo"}'),
  ('44444444-4444-4444-4444-444444444444', 'staff@example.com', '{"full_name":"Operador"}');

insert into public.courts (id, slug, name, latitude, longitude, average_match_minutes)
values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'quadra-teste', 'Quadra Teste',
        -23.561414, -46.655881, 20);

update public.profiles set role = 'admin' where id = '44444444-4444-4444-4444-444444444444';

-- US-01: perfil criado automaticamente pelo trigger de signup
do $$
declare v_count integer; v_username text;
begin
  select count(*) into v_count from public.profiles;
  assert v_count = 4, format('esperava 4 perfis, obtive %s', v_count);

  select username into v_username from public.profiles
  where id = '11111111-1111-1111-1111-111111111111';
  assert v_username = 'ana', format('username derivado do e-mail incorreto: %s', v_username);
end $$;

-- US-02: Haversine — Av. Paulista até ~1,1 km ao norte
do $$
declare v_d double precision;
begin
  v_d := public.haversine_meters(-23.561414, -46.655881, -23.551414, -46.655881);
  assert v_d between 1100 and 1120, format('haversine fora do esperado: %s', v_d);

  v_d := public.haversine_meters(-23.561414, -46.655881, -23.561414, -46.655881);
  assert v_d < 0.001, 'distância de um ponto para ele mesmo deveria ser zero';
end $$;

-- Helper: emite um scan token válido (papel da Edge Function scan-court)
create or replace function pg_temp.issue_scan_token(p_user uuid, p_token text)
returns void language sql as $$
  insert into public.scan_tokens
    (token_hash, user_id, court_id, latitude, longitude, distance_meters, expires_at)
  values
    (public.hash_scan_token(p_token), p_user, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
     -23.561414, -46.655881, 12.5, now() + interval '30 seconds');
$$;

-- ---------------------------------------------------------------------
-- US-03: Ana entra na fila como individual
-- ---------------------------------------------------------------------
do $$ begin perform pg_temp.issue_scan_token('11111111-1111-1111-1111-111111111111', 'tok-ana'); end $$;
set local "request.jwt.claim.sub" = '11111111-1111-1111-1111-111111111111';

do $$
declare v jsonb;
begin
  v := public.join_queue('tok-ana', 'single');
  assert (v ->> 'position')::int = 1,    format('Ana deveria ser a 1ª: %s', v);
  assert (v ->> 'teams_ahead')::int = 0, format('Ana não deveria ter times na frente: %s', v);
  assert (v ->> 'estimated_wait_minutes')::int = 0, format('espera deveria ser 0: %s', v);
  assert jsonb_array_length(v -> 'players') = 1, 'individual deveria ter 1 jogador';
end $$;

-- Token de uso único não pode ser reaproveitado (US-02)
do $$
declare v_code text;
begin
  begin
    perform public.join_queue('tok-ana', 'single');
    assert false, 'reuso do scan token deveria falhar';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ002', format('esperava NQ002, obtive %s', v_code);
  end;
end $$;

-- ---------------------------------------------------------------------
-- Bruno entra como dupla com Caio
-- ---------------------------------------------------------------------
do $$ begin perform pg_temp.issue_scan_token('22222222-2222-2222-2222-222222222222', 'tok-bruno'); end $$;
set local "request.jwt.claim.sub" = '22222222-2222-2222-2222-222222222222';

do $$
declare v jsonb;
begin
  v := public.join_queue('tok-bruno', 'double', '@caio');
  assert (v ->> 'position')::int = 2,    format('Bruno deveria ser o 2º: %s', v);
  assert (v ->> 'teams_ahead')::int = 1, format('Bruno deveria ter 1 time na frente: %s', v);
  assert (v ->> 'estimated_wait_minutes')::int = 20, format('espera deveria ser 20 min: %s', v);
  assert jsonb_array_length(v -> 'players') = 2, 'dupla deveria ter 2 jogadores';
end $$;

-- Caio já está na fila (como parceiro) e não pode formar outro time
do $$ begin perform pg_temp.issue_scan_token('33333333-3333-3333-3333-333333333333', 'tok-caio'); end $$;
set local "request.jwt.claim.sub" = '33333333-3333-3333-3333-333333333333';

do $$
declare v_code text;
begin
  begin
    perform public.join_queue('tok-caio', 'single');
    assert false, 'Caio não deveria conseguir entrar duas vezes';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ004', format('esperava NQ004, obtive %s', v_code);
  end;
end $$;

-- Parceiro inexistente
do $$ begin perform pg_temp.issue_scan_token('33333333-3333-3333-3333-333333333333', 'tok-caio-2'); end $$;
do $$
declare v_code text;
begin
  begin
    perform public.join_queue('tok-caio-2', 'double', 'ninguem@example.com');
    assert false, 'parceiro inexistente deveria falhar';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code in ('NQ004', 'NQ005'), format('esperava NQ005, obtive %s', v_code);
  end;
end $$;

-- ---------------------------------------------------------------------
-- US-03: notificações "É a sua vez!" e "Prepare-se!"
-- ---------------------------------------------------------------------
do $$
declare v_turn integer; v_ready integer;
begin
  select count(*) into v_turn  from public.notification_outbox where type = 'queue_turn';
  select count(*) into v_ready from public.notification_outbox where type = 'queue_almost_ready';

  assert v_turn = 1,  format('esperava 1 push "É a sua vez!" (Ana), obtive %s', v_turn);
  assert v_ready = 2, format('esperava 2 pushes "Prepare-se!" (dupla Bruno+Caio), obtive %s', v_ready);
end $$;

-- ---------------------------------------------------------------------
-- US-04: estado da quadra consumido pela tela
-- ---------------------------------------------------------------------
do $$
declare v jsonb;
begin
  v := public.court_queue('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  assert (v ->> 'teams_waiting')::int = 2, format('deveriam existir 2 times: %s', v ->> 'teams_waiting');
  assert (v -> 'current_match') = 'null'::jsonb or v -> 'current_match' is null,
         'não deveria haver partida em andamento';
  assert (v ->> 'can_join')::boolean, 'quadra livre deveria aceitar entrada';
  assert jsonb_array_length(v -> 'queue') = 2, 'fila deveria listar 2 times';
  assert ((v -> 'queue' -> 0) ->> 'position')::int = 1, 'primeira posição fora de ordem';
end $$;

-- ---------------------------------------------------------------------
-- Operação: staff inicia a partida da Ana
-- ---------------------------------------------------------------------
set local "request.jwt.claim.sub" = '44444444-4444-4444-4444-444444444444';

do $$
declare v_entry uuid; v jsonb; v_status public.court_status;
begin
  select id into v_entry from public.queue_entries
  where created_by = '11111111-1111-1111-1111-111111111111';

  v := public.start_match(v_entry);
  assert v ->> 'status' = 'playing', format('partida deveria estar em andamento: %s', v);

  select status into v_status from public.courts
  where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  assert v_status = 'in_game', format('quadra deveria estar em jogo: %s', v_status);

  -- Com a Ana em quadra, a dupla continua com 1 time na frente.
  v := public.court_queue('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  assert (v ->> 'teams_waiting')::int = 1, format('deveria restar 1 time na fila: %s', v ->> 'teams_waiting');
  assert ((v -> 'queue' -> 0) ->> 'teams_ahead')::int = 1,
         format('dupla deveria ter 1 time na frente: %s', v -> 'queue' -> 0);
end $$;

-- Apenas staff pode operar a quadra
set local "request.jwt.claim.sub" = '22222222-2222-2222-2222-222222222222';
do $$
declare v_code text; v_entry uuid;
begin
  select id into v_entry from public.queue_entries where status = 'playing';
  begin
    perform public.finish_match(v_entry);
    assert false, 'jogador comum não deveria encerrar partidas';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ008', format('esperava NQ008, obtive %s', v_code);
  end;
end $$;

-- ---------------------------------------------------------------------
-- call_next: encerra a partida atual e promove a dupla
-- ---------------------------------------------------------------------
set local "request.jwt.claim.sub" = '44444444-4444-4444-4444-444444444444';
do $$
declare v jsonb;
begin
  v := public.call_next('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  assert v ->> 'status' = 'playing', format('dupla deveria entrar em quadra: %s', v);
  assert jsonb_array_length(v -> 'players') = 2, 'a dupla deveria ter 2 jogadores';
end $$;

-- Ana terminou: pode entrar na fila de novo
do $$
declare v_active integer;
begin
  select count(*) into v_active from public.queue_entry_members
  where user_id = '11111111-1111-1111-1111-111111111111' and is_active;
  assert v_active = 0, 'após a partida o jogador deveria ficar livre para nova fila';
end $$;

-- ---------------------------------------------------------------------
-- Sair da fila
-- ---------------------------------------------------------------------
do $$ begin perform pg_temp.issue_scan_token('11111111-1111-1111-1111-111111111111', 'tok-ana-2'); end $$;
set local "request.jwt.claim.sub" = '11111111-1111-1111-1111-111111111111';

do $$
declare v jsonb; v_entry uuid; v_status public.queue_entry_status;
begin
  v := public.join_queue('tok-ana-2', 'single');
  v_entry := (v ->> 'entry_id')::uuid;

  v := public.leave_queue(v_entry, 'mudou de ideia');
  assert v ->> 'status' = 'cancelled', format('saída da fila falhou: %s', v);

  select status into v_status from public.queue_entries where id = v_entry;
  assert v_status = 'cancelled', 'status deveria ser cancelled';
end $$;

-- Token expirado é recusado (US-02 — timeout de 30s)
do $$
declare v_code text;
begin
  insert into public.scan_tokens
    (token_hash, user_id, court_id, latitude, longitude, distance_meters, expires_at)
  values
    (public.hash_scan_token('tok-velho'), '11111111-1111-1111-1111-111111111111',
     'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', -23.561414, -46.655881, 10,
     now() - interval '1 second');
  begin
    perform public.join_queue('tok-velho', 'single');
    assert false, 'token expirado deveria ser recusado';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ002', format('esperava NQ002, obtive %s', v_code);
  end;
end $$;

-- Quadra indisponível bloqueia entrada (US-04)
update public.courts set status = 'unavailable'
where id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

do $$ begin perform pg_temp.issue_scan_token('11111111-1111-1111-1111-111111111111', 'tok-ana-3'); end $$;
do $$
declare v_code text; v jsonb;
begin
  begin
    perform public.join_queue('tok-ana-3', 'single');
    assert false, 'quadra indisponível deveria recusar entrada';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ003', format('esperava NQ003, obtive %s', v_code);
  end;

  v := public.court_queue('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa');
  assert not (v ->> 'can_join')::boolean, 'can_join deveria ser falso';
end $$;

rollback;

\echo '✔ tests/local/10_queue_flow_test.sql — todos os cenários passaram'
