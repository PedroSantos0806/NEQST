-- =====================================================================
-- Regressão: a ordem da fila é estritamente a de chegada.
--
-- now() é constante dentro de uma transação — ordenar por joined_at
-- empatava times criados na mesma transação e a posição virava sorteio.
-- A ordem vem de queue_entries.queue_number (identity).
-- =====================================================================
\set ON_ERROR_STOP on

begin;

insert into auth.users (id, email) values
  ('aaaa1111-0000-0000-0000-000000000001', 'p1@example.com'),
  ('aaaa1111-0000-0000-0000-000000000002', 'p2@example.com'),
  ('aaaa1111-0000-0000-0000-000000000003', 'p3@example.com');

insert into public.courts (id, slug, name, latitude, longitude)
values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'quadra-ordem', 'Quadra Ordem',
        -23.561414, -46.655881);

create or replace function pg_temp.join_as(p_user uuid, p_token text)
returns jsonb language plpgsql as $$
declare v jsonb;
begin
  insert into public.scan_tokens
    (token_hash, user_id, court_id, latitude, longitude, distance_meters, expires_at)
  values
    (public.hash_scan_token(p_token), p_user, 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
     -23.561414, -46.655881, 5, now() + interval '30 seconds');

  perform set_config('request.jwt.claim.sub', p_user::text, true);
  v := public.join_queue(p_token, 'single');
  return v;
end;
$$;

do $$
declare
  v1 jsonb; v2 jsonb; v3 jsonb;
  v_same_instant boolean;
begin
  v1 := pg_temp.join_as('aaaa1111-0000-0000-0000-000000000001', 'ord-1');
  v2 := pg_temp.join_as('aaaa1111-0000-0000-0000-000000000002', 'ord-2');
  v3 := pg_temp.join_as('aaaa1111-0000-0000-0000-000000000003', 'ord-3');

  assert (v1 ->> 'position')::int = 1, format('1º time fora de ordem: %s', v1 ->> 'position');
  assert (v2 ->> 'position')::int = 2, format('2º time fora de ordem: %s', v2 ->> 'position');
  assert (v3 ->> 'position')::int = 3, format('3º time fora de ordem: %s', v3 ->> 'position');

  assert (v1 ->> 'teams_ahead')::int = 0;
  assert (v2 ->> 'teams_ahead')::int = 1;
  assert (v3 ->> 'teams_ahead')::int = 2;

  -- Espera estimada cresce com a posição (20 min por partida, padrão).
  assert (v3 ->> 'estimated_wait_minutes')::int
       > (v2 ->> 'estimated_wait_minutes')::int,
    'tempo estimado deveria crescer ao longo da fila';

  -- A ordem não pode depender do relógio: aqui os três podem ter o
  -- mesmo now(), e ainda assim a fila precisa estar correta.
  select count(distinct joined_at) = 1 into v_same_instant
  from public.queue_entries
  where court_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

  assert (select bool_and(ordenado) from (
    select queue_number > lag(queue_number) over (order by position) is not false as ordenado
    from public.queue_positions
    where court_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
  ) s), 'queue_number deveria crescer junto com a posição';
end $$;

-- O 2º time sai: o 3º sobe uma posição, o 1º não se move.
do $$
declare v_entry uuid; v jsonb;
begin
  select entry_id into v_entry
  from public.queue_positions
  where court_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb' and position = 2;

  perform set_config('request.jwt.claim.sub', 'aaaa1111-0000-0000-0000-000000000002', true);
  perform public.leave_queue(v_entry);

  v := public.court_queue('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
  assert (v ->> 'teams_waiting')::int = 2, format('deveriam restar 2 times: %s', v ->> 'teams_waiting');
  assert ((v -> 'queue' -> 1) -> 'players' -> 0 ->> 'user_id')
         = 'aaaa1111-0000-0000-0000-000000000003',
    'o 3º time deveria ter subido para a 2ª posição';
end $$;

rollback;

\echo '✔ tests/local/20_ordem_da_fila_test.sql — ordem da fila preservada'
