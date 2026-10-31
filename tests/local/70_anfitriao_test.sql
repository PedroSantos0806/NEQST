-- =====================================================================
-- Sprint 5: a fila com anfitrião (docs/sprint5.md)
--   a primeira pessoa abre a fila, declarando turno em andamento e
--   grupos sem app à frente; quem vem depois entra pelo QR na tela de
--   alguém da fila; o check-in é pelo botão com GPS
--
-- A distância e o prazo de 10 min do convite são conferidos na Edge
-- Function scan-court; aqui os scan tokens entram prontos, como nos
-- outros testes, com o método que a função gravaria.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('a5000000-0000-0000-0000-0000000000a5', 'h-ana@example.com',   '{"full_name":"Ana Anfitriã"}'),
  ('b5000000-0000-0000-0000-0000000000b5', 'h-bia@example.com',   '{"full_name":"Bia Convidada"}'),
  ('c5000000-0000-0000-0000-0000000000c5', 'h-caio@example.com',  '{"full_name":"Caio Convidado"}'),
  ('d5000000-0000-0000-0000-0000000000d5', 'h-duda@example.com',  '{"full_name":"Duda Atrasada"}'),
  ('e5000000-0000-0000-0000-0000000000e5', 'h-admin@example.com', '{"full_name":"Admin Piloto"}');

update public.profiles set role = 'admin' where id = 'e5000000-0000-0000-0000-0000000000e5';

insert into public.parks (id, slug, name, district, latitude, longitude)
values ('55550000-0000-0000-0000-000000000005', 'teste-anfitriao', 'Parque do Piloto (teste)',
        'Centro', -23.560000, -46.640000);

insert into public.courts (id, park_id, court_number, surface, slot_minutes, slug, name,
                           latitude, longitude, queue_mode)
values
  ('a5a50000-0000-0000-0000-0000000000a5', '55550000-0000-0000-0000-000000000005', 1, 'clay', 40,
   'teste-anfitriao-q1', 'Quadra 01', -23.560000, -46.640000, 'host'),
  ('b5b50000-0000-0000-0000-0000000000b5', '55550000-0000-0000-0000-000000000005', 2, 'hard', 40,
   'teste-anfitriao-q2', 'Quadra 02', -23.560100, -46.640100, 'fixed_qr');

create or replace function pg_temp.as_user(p_user uuid)
returns void language sql as $$
  select set_config('request.jwt.claim.sub', p_user::text, true);
$$;

-- O que a scan-court grava depois de conferir a distância.
create or replace function pg_temp.scan(
  p_user uuid, p_court uuid, p_token text,
  p_method public.scan_method default 'qr', p_invite uuid default null
)
returns void language sql as $$
  insert into public.scan_tokens
    (token_hash, user_id, court_id, latitude, longitude, distance_meters, expires_at, method, invite_id)
  select public.hash_scan_token(p_token), p_user, c.id, c.latitude, c.longitude, 8,
         now() + interval '30 seconds', p_method, p_invite
  from public.courts c where c.id = p_court;
$$;

create or replace function pg_temp.invite_id_of(p_code text)
returns uuid language sql as $$
  select id from public.host_invites where code_hash = public.hash_scan_token(p_code);
$$;

create or replace function pg_temp.q1()
returns uuid language sql as $$ select 'a5a50000-0000-0000-0000-0000000000a5'::uuid $$;

-- A segunda quadra do parque, usada nos casos que precisam de uma
-- quadra limpa sem desarrumar a fila da primeira.
create or replace function pg_temp.q2()
returns uuid language sql as $$ select 'b5b50000-0000-0000-0000-0000000000b5'::uuid $$;

create or replace function pg_temp.offline_entries()
returns setof public.queue_entries language sql as $$
  select * from public.queue_entries
  where court_id = 'a5a50000-0000-0000-0000-0000000000a5' and is_offline
  order by queue_number;
$$;

-- =====================================================================
-- O modo anfitrião não aceita a distância desligada
-- =====================================================================
do $$
declare v_code text;
begin
  perform pg_temp.as_user('e5000000-0000-0000-0000-0000000000e5');

  begin
    perform public.admin_upsert_court(p_id => pg_temp.q1(), p_enforce_proximity => false);
    assert false, 'desligar a distância no modo anfitrião deveria falhar';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ035', format('esperava NQ035, obtive %s', v_code);
  end;

  begin
    perform public.admin_upsert_court(p_id => 'b5b50000-0000-0000-0000-0000000000b5',
                                      p_enforce_proximity => false, p_queue_mode => 'host');
    assert false, 'ligar o modo anfitrião com a distância desligada deveria falhar';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ035', format('esperava NQ035, obtive %s', v_code);
  end;

  -- E a constraint segura quem passar por fora da função.
  begin
    update public.courts set enforce_proximity = false where id = pg_temp.q1();
    assert false, 'a constraint deveria barrar';
  exception when check_violation then
    null;
  end;
end $$;

-- =====================================================================
-- Antes de abrir: a quadra mostra "Começar a fila aqui"
-- =====================================================================
do $$
declare v jsonb;
begin
  perform pg_temp.as_user('a5000000-0000-0000-0000-0000000000a5');
  v := public.court_screen(pg_temp.q1());
  assert (v ->> 'can_open_host')::boolean, format('a Ana pode abrir: %s', v);
  assert not (v ->> 'can_join')::boolean, 'sem fila aberta, não há em que entrar';
  assert v -> 'host' = 'null'::jsonb or v -> 'host' is null, 'ninguém organiza ainda';
  assert v -> 'court' -> 'checkin_methods' = '["gps"]'::jsonb,
    format('check-in pelo botão: %s', v -> 'court' -> 'checkin_methods');

  -- A quadra com placa continua como sempre.
  v := public.court_screen('b5b50000-0000-0000-0000-0000000000b5');
  assert not (v ->> 'can_open_host')::boolean, 'quadra com placa não abre fila de anfitrião';
  assert (v ->> 'can_join')::boolean, 'quadra com placa aceita fila';
end $$;

-- O GPS sozinho não abre fila numa quadra com placa
do $$
declare v_code text;
begin
  perform pg_temp.as_user('a5000000-0000-0000-0000-0000000000a5');
  perform pg_temp.scan('a5000000-0000-0000-0000-0000000000a5', 'b5b50000-0000-0000-0000-0000000000b5',
                       'h-ana-q2', 'gps');
  begin
    perform public.open_host_queue('h-ana-q2');
    assert false, 'quadra com placa deveria recusar';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ030', format('esperava NQ030, obtive %s', v_code);
  end;
end $$;

-- Mais de 10 grupos declarados é recusado
do $$
declare v_code text;
begin
  perform pg_temp.as_user('a5000000-0000-0000-0000-0000000000a5');
  perform pg_temp.scan('a5000000-0000-0000-0000-0000000000a5', pg_temp.q1(), 'h-ana-11', 'gps');
  begin
    perform public.open_host_queue('h-ana-11', null, array_fill(''::text, array[11]));
    assert false, '11 grupos deveria falhar';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ032', format('esperava NQ032, obtive %s', v_code);
  end;
end $$;

-- =====================================================================
-- A Ana abre: faltam 15 min para quem está jogando, e 2 grupos esperam
-- =====================================================================
do $$
declare v jsonb; v_q jsonb;
begin
  perform pg_temp.as_user('a5000000-0000-0000-0000-0000000000a5');
  perform pg_temp.scan('a5000000-0000-0000-0000-0000000000a5', pg_temp.q1(), 'h-ana-1', 'gps');
  v := public.open_host_queue('h-ana-1', 15, array['dupla de boné azul', '']);

  assert (v ->> 'is_live')::boolean, format('o turno de quem já jogava está no ar: %s', v);
  assert (v -> 'match' ->> 'is_offline')::boolean, 'é um turno sem app';
  assert (v -> 'match' ->> 'remaining_seconds')::int between 14 * 60 and 15 * 60,
    format('acaba em 15 min: %s', v -> 'match');
  assert v ->> 'players_line' = 'Já estavam jogando', format('placar: %s', v ->> 'players_line');

  v_q := v -> 'queue';
  assert jsonb_array_length(v_q) = 3, format('2 sem app + a Ana: %s', v_q);
  assert (v_q -> 0 ->> 'is_offline')::boolean and v_q -> 0 ->> 'team_label' = 'dupla de boné azul',
    format('1º é a dupla de boné azul: %s', v_q -> 0);
  assert (v_q -> 1 ->> 'is_offline')::boolean and v_q -> 1 ->> 'team_label' = 'Grupo sem app',
    format('2º é um grupo sem app sem rótulo: %s', v_q -> 1);
  assert v_q -> 1 ->> 'group_label' = 'Sem app', 'rótulo do grupo sem app';
  assert (v_q -> 2 ->> 'is_mine')::boolean and (v_q -> 2 ->> 'position')::int = 3,
    format('a Ana é a 3ª, depois de quem declarou: %s', v_q -> 2);
  assert jsonb_array_length(v_q -> 2 -> 'stack') = 3, 'a pilha tem uma raquete por vaga';

  assert (v -> 'host' ->> 'is_me')::boolean, format('a Ana organiza: %s', v -> 'host');
  assert (v -> 'host' ->> 'can_show_invite')::boolean, 'a Ana pode mostrar o QR';
  assert not (v ->> 'can_open_host')::boolean, 'já está aberta';

  assert (select origin from public.queue_entry_members
           where user_id = 'a5000000-0000-0000-0000-0000000000a5' and is_active) = 'host_open',
    'a entrada da Ana conta como abertura';
end $$;

-- Ninguém abre uma segunda fila na mesma quadra
do $$
declare v_code text;
begin
  perform pg_temp.as_user('b5000000-0000-0000-0000-0000000000b5');
  perform pg_temp.scan('b5000000-0000-0000-0000-0000000000b5', pg_temp.q1(), 'h-bia-open', 'gps');
  begin
    perform public.open_host_queue('h-bia-open');
    assert false, 'a segunda abertura deveria falhar';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ031', format('esperava NQ031, obtive %s', v_code);
  end;
end $$;

-- O GPS sozinho não põe ninguém na fila: precisa do QR de alguém dela
do $$
declare v_code text;
begin
  perform pg_temp.as_user('b5000000-0000-0000-0000-0000000000b5');
  perform pg_temp.scan('b5000000-0000-0000-0000-0000000000b5', pg_temp.q1(), 'h-bia-gps', 'gps');
  begin
    perform public.join_queue('h-bia-gps');
    assert false, 'token gps não entra na fila';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ002', format('esperava NQ002, obtive %s', v_code);
  end;
end $$;

-- =====================================================================
-- O convite: só quem está na fila mostra
-- =====================================================================
do $$
declare v_code text;
begin
  perform pg_temp.as_user('b5000000-0000-0000-0000-0000000000b5');
  begin
    perform public.issue_host_invite(pg_temp.q1(), gen_random_uuid());
    assert false, 'quem está fora da fila não mostra QR';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ008', format('esperava NQ008, obtive %s', v_code);
  end;
end $$;

create temp table invite_codes (who text primary key, code text not null) on commit drop;
grant all on invite_codes to public;

do $$
declare v jsonb; v_display uuid := gen_random_uuid(); v2 jsonb;
begin
  perform pg_temp.as_user('a5000000-0000-0000-0000-0000000000a5');
  v := public.issue_host_invite(pg_temp.q1(), v_display);
  assert v ->> 'code' ~ '^[A-Za-z0-9_-]{24}$', format('código de 24 caracteres: %s', v);
  assert (v ->> 'rotate_seconds')::int = 30 and (v ->> 'valid_seconds')::int = 600, format('prazos: %s', v);
  assert (select expires_at - issued_at from public.host_invites
           where id = (v ->> 'invite_id')::uuid) between interval '9 minutes 59 seconds' and interval '10 minutes 1 second',
    'o convite vale 10 minutos';

  -- O código em claro não fica no banco.
  assert not exists (select 1 from public.host_invites where code_hash = v ->> 'code'), 'só o hash';

  -- Trocou depois de 30 s: código novo, mesma exibição.
  v2 := public.issue_host_invite(pg_temp.q1(), v_display);
  assert v2 ->> 'code' <> v ->> 'code', 'o código troca';

  insert into invite_codes values ('ana', v ->> 'code');
end $$;

-- Aberto antes do login (anon): conta uma vez por visitante
do $$
declare v_code text := (select code from invite_codes where who = 'ana');
begin
  perform set_config('request.jwt.claim.sub', '', true);
  perform public.host_invite_opened(v_code, 'visitante-1');
  perform public.host_invite_opened(v_code, 'visitante-1');
  perform public.host_invite_opened(v_code, 'visitante-2');
  perform public.host_invite_opened('codigo-que-nao-existe', 'visitante-3');
  assert (select count(*) from public.pilot_events where event = 'invite_opened') = 2,
    'duas aberturas, sem repetir e sem código inventado';
end $$;

-- A Bia escaneia o QR da Ana (dentro do raio) e abre a própria vaga
do $$
declare v jsonb; v_invite uuid := pg_temp.invite_id_of((select code from invite_codes where who = 'ana'));
begin
  perform pg_temp.as_user('b5000000-0000-0000-0000-0000000000b5');
  perform pg_temp.scan('b5000000-0000-0000-0000-0000000000b5', pg_temp.q1(), 'h-bia-1', 'host_invite', v_invite);
  v := public.join_queue('h-bia-1');
  assert (v ->> 'position')::int = 4, format('a Bia é a 4ª: %s', v);

  assert (select origin from public.queue_entry_members
           where user_id = 'b5000000-0000-0000-0000-0000000000b5' and is_active) = 'host_invite',
    'a Bia entrou pelo convite';
  assert (select invite_id from public.queue_entry_members
           where user_id = 'b5000000-0000-0000-0000-0000000000b5' and is_active) = v_invite,
    'e o convite fica gravado na vaga';

  v := public.court_screen(pg_temp.q1());
  assert not (v -> 'host' ->> 'is_me')::boolean, 'a Bia não organiza';
  assert (v -> 'host' ->> 'can_show_invite')::boolean, 'mas mostra o QR para os próximos';
end $$;

-- O Caio entra no grupo da Bia pelo QR dela, com o PIN
do $$
declare v jsonb; v_pin text; v_invite uuid;
begin
  perform pg_temp.as_user('b5000000-0000-0000-0000-0000000000b5');
  v := public.issue_host_invite(pg_temp.q1(), gen_random_uuid());
  v_invite := (v ->> 'invite_id')::uuid;
  v_pin := public.court_screen(pg_temp.q1()) -> 'my_group' ->> 'pin';

  perform pg_temp.as_user('c5000000-0000-0000-0000-0000000000c5');
  perform pg_temp.scan('c5000000-0000-0000-0000-0000000000c5', pg_temp.q1(), 'h-caio-1', 'host_invite', v_invite);
  v := public.join_with_pin('h-caio-1', v_pin);
  assert (v ->> 'joined')::boolean, format('o Caio entrou: %s', v);
  assert (select issued_by from public.host_invites i
           join public.queue_entry_members m on m.invite_id = i.id
           where m.user_id = 'c5000000-0000-0000-0000-0000000000c5' and m.is_active)
         = 'b5000000-0000-0000-0000-0000000000b5', 'quem trouxe o Caio foi a Bia';
end $$;

-- =====================================================================
-- Vagas sem app: só no fim, e só o anfitrião mexe
-- =====================================================================
do $$
declare v jsonb; v_code text;
begin
  perform pg_temp.as_user('b5000000-0000-0000-0000-0000000000b5');
  begin
    perform public.host_add_offline(pg_temp.q1(), 'amigos do Caio');
    assert false, 'só o anfitrião registra quem está sem app';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ033', format('esperava NQ033, obtive %s', v_code);
  end;

  begin
    perform public.host_mark_offline((select id from pg_temp.offline_entries() where offline_kind = 'waiting' limit 1), 'gave_up');
    assert false, 'só o anfitrião tira um grupo sem app';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ033', format('esperava NQ033, obtive %s', v_code);
  end;

  perform pg_temp.as_user('a5000000-0000-0000-0000-0000000000a5');
  v := public.host_add_offline(pg_temp.q1(), '  trio da raquete vermelha que chegou agora e ficou sem celular  ');
  assert jsonb_array_length(v -> 'queue') = 5, format('5 na fila: %s', v -> 'queue');
  assert (v -> 'queue' -> 4 ->> 'is_offline')::boolean, 'o grupo sem app entrou no fim';
  assert char_length(v -> 'queue' -> 4 ->> 'offline_label') = 40, 'o rótulo é cortado em 40';
end $$;

-- =====================================================================
-- O turno de quem já jogava acaba sozinho; a vez do sem app espera
-- =====================================================================
do $$
declare v jsonb; v_first uuid;
begin
  -- 15 min depois
  update public.matches set expires_at = now() - interval '1 second'
   where court_id = pg_temp.q1() and ended_at is null;

  perform public.advance_court(pg_temp.q1());

  select id into v_first from pg_temp.offline_entries() where offline_kind = 'waiting' order by queue_number limit 1;
  assert (select status from public.queue_entries where id = v_first) = 'ready', 'a dupla de boné azul foi chamada';
  assert (select call_expires_at from public.queue_entries where id = v_first) is null,
    'sem tolerância para quem não tem app';
  assert exists (select 1 from public.notification_outbox
                  where user_id = 'a5000000-0000-0000-0000-0000000000a5' and type = 'host_offline_called'),
    'a Ana recebe o aviso para marcar';

  -- Mesmo muito depois, a vaga não expira sozinha.
  update public.queue_entries set called_at = now() - interval '20 minutes' where id = v_first;
  perform public.advance_court(pg_temp.q1());
  perform public.advance_expired_queues();
  assert (select status from public.queue_entries where id = v_first) = 'ready', 'continua esperando o anfitrião';

  -- Entraram.
  perform pg_temp.as_user('a5000000-0000-0000-0000-0000000000a5');
  v := public.host_mark_offline(v_first, 'arrived');
  assert (v -> 'match' ->> 'is_offline')::boolean and (v ->> 'is_live')::boolean, format('em quadra: %s', v -> 'match');
  assert v ->> 'players_line' = 'dupla de boné azul', format('placar: %s', v ->> 'players_line');

  -- Devolveram a quadra antes: o anfitrião marca que saíram.
  v := public.host_mark_offline(v_first, 'finished');
  assert not (v ->> 'is_live')::boolean, 'quadra livre';
  assert (select status from public.queue_entries
           where id = (select id from pg_temp.offline_entries() where offline_kind = 'waiting'
                        order by queue_number offset 1 limit 1)) = 'ready',
    'o grupo sem app seguinte foi chamado';
end $$;

-- O segundo grupo sem app desistiu: a vez passa para a Ana
do $$
declare v jsonb; v_second uuid;
begin
  select id into v_second from pg_temp.offline_entries() where status = 'ready';
  perform pg_temp.as_user('a5000000-0000-0000-0000-0000000000a5');
  v := public.host_mark_offline(v_second, 'gave_up');
  assert (select cancel_reason from public.queue_entries where id = v_second) = 'offline_gave_up', 'saiu da fila';
  assert (v -> 'my_entry' ->> 'is_called')::boolean, format('chamaram a Ana: %s', v -> 'my_entry');
end $$;

-- =====================================================================
-- O check-in pelo botão "Entrando na quadra"
-- =====================================================================
do $$
declare v jsonb; v_code text;
begin
  -- O token gps não serve para quem não está na fila desta quadra.
  perform pg_temp.as_user('d5000000-0000-0000-0000-0000000000d5');
  perform pg_temp.scan('d5000000-0000-0000-0000-0000000000d5', pg_temp.q1(), 'h-duda-gps', 'gps');
  begin
    perform public.check_in_and_start('h-duda-gps');
    assert false, 'a Duda não está na fila';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ007', format('esperava NQ007, obtive %s', v_code);
  end;

  perform pg_temp.as_user('a5000000-0000-0000-0000-0000000000a5');
  perform pg_temp.scan('a5000000-0000-0000-0000-0000000000a5', pg_temp.q1(), 'h-ana-checkin', 'gps');
  v := public.check_in_and_start('h-ana-checkin');
  assert (v ->> 'is_live')::boolean, format('o turno da Ana começou: %s', v);
  assert not (v ->> 'is_offline')::boolean, 'é um turno com app';
end $$;

-- =====================================================================
-- A Ana vai embora: quem organiza passa a ser a Bia, a próxima com app
-- =====================================================================
do $$
declare v jsonb; v_code text; v_ana_entry uuid;
begin
  perform pg_temp.as_user('a5000000-0000-0000-0000-0000000000a5');
  select e.id into v_ana_entry from public.queue_entries e
   where e.created_by = 'a5000000-0000-0000-0000-0000000000a5' and not e.is_offline and e.status = 'playing';
  perform public.leave_queue(v_ana_entry);

  perform pg_temp.as_user('b5000000-0000-0000-0000-0000000000b5');
  v := public.court_screen(pg_temp.q1());
  assert (v -> 'host' ->> 'is_me')::boolean, format('a Bia herdou: %s', v -> 'host');

  -- E agora é ela quem anda com o grupo sem app do fim da fila.
  v := public.host_mark_offline((select id from pg_temp.offline_entries() where status = 'waiting'), 'gave_up');
  assert (select host_user_id from public.host_sessions where court_id = pg_temp.q1() and closed_at is null)
         = 'b5000000-0000-0000-0000-0000000000b5', 'a herança fica gravada';

  -- A Ana, fora da fila, não organiza mais.
  perform pg_temp.as_user('a5000000-0000-0000-0000-0000000000a5');
  begin
    perform public.host_add_offline(pg_temp.q1(), null);
    assert false, 'a Ana saiu: não organiza mais';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ033', format('esperava NQ033, obtive %s', v_code);
  end;
end $$;

-- =====================================================================
-- O painel do piloto
-- =====================================================================
do $$
declare v jsonb; v_code text;
begin
  perform pg_temp.as_user('b5000000-0000-0000-0000-0000000000b5');
  begin
    perform public.admin_pilot_stats();
    assert false, 'só o admin vê o painel';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code is not null, 'recusado';
  end;

  perform pg_temp.as_user('e5000000-0000-0000-0000-0000000000e5');
  v := public.admin_pilot_stats('55550000-0000-0000-0000-000000000005');

  assert (v -> 'totals' ->> 'people')::int = 3, format('Ana, Bia e Caio: %s', v -> 'totals');
  assert (v -> 'totals' ->> 'offline_entries')::int = 3, format('3 grupos sem app na fila: %s', v -> 'totals');
  assert (v -> 'totals' ->> 'sessions')::int = 1, 'uma fila aberta';
  assert (v -> 'origins' ->> 'host_invite')::int = 2 and (v -> 'origins' ->> 'host_open')::int = 1,
    format('origens: %s', v -> 'origins');
  assert (v -> 'funnel' ->> 'shown')::int = 2, format('duas exibições do QR: %s', v -> 'funnel');
  assert (v -> 'funnel' ->> 'opened')::int = 2, format('dois visitantes: %s', v -> 'funnel');
  assert (v -> 'funnel' ->> 'joined')::int = 2, format('dois entraram pelo convite: %s', v -> 'funnel');
  assert (v -> 'spreaders' ->> 'people')::int = 2 and v -> 'spreaders' -> 'top' = '[1, 1]'::jsonb,
    format('a Ana trouxe a Bia, a Bia trouxe o Caio: %s', v -> 'spreaders');
  assert (v -> 'offline_hold' ->> 'samples')::int = 2, format('dois sem app chamados: %s', v -> 'offline_hold');
  assert jsonb_array_length(v -> 'daily') = 30, 'trinta dias por padrão';
  assert jsonb_array_length(v -> 'by_hour') = 24, 'as 24 horas';
  assert v::text not like '%Ana%' and v::text not like '%Bia%', 'sem nomes';

  -- O admin vê o modo e a fila aberta no formulário.
  v := public.admin_overview();
  assert exists (
    select 1 from jsonb_array_elements(v -> 'parks') p, jsonb_array_elements(p -> 'courts') c
    where c ->> 'id' = 'a5a50000-0000-0000-0000-0000000000a5'
      and c ->> 'queue_mode' = 'host' and (c ->> 'host_session_open')::boolean
  ), 'a quadra aparece no modo anfitrião, com a fila aberta';
end $$;

-- =====================================================================
-- A fila esquecida fecha com 30 min sem ninguém
-- =====================================================================
do $$
declare v jsonb; v_entry uuid;
begin
  -- A Bia registra um grupo sem app e todo mundo com o app vai embora.
  perform pg_temp.as_user('b5000000-0000-0000-0000-0000000000b5');
  perform public.host_add_offline(pg_temp.q1(), 'ficaram sem app');

  for v_entry in
    select distinct m.entry_id from public.queue_entry_members m
    join public.queue_entries e on e.id = m.entry_id
    where e.court_id = pg_temp.q1() and m.is_active
  loop
    update public.queue_entries set status = 'done', ended_at = now() where id = v_entry;
  end loop;

  -- Faz 10 min: ainda aberta.
  update public.host_sessions set opened_at = now() - interval '2 hours' where court_id = pg_temp.q1();
  update public.queue_entries
     set joined_at = now() - interval '1 hour', started_at = null,
         ended_at = case when ended_at is null then null else now() - interval '10 minutes' end,
         left_at  = case when left_at  is null then null else now() - interval '10 minutes' end
   where court_id = pg_temp.q1();
  assert (public.advance_expired_queues() ->> 'sessions_closed')::int = 0, 'com 10 min, continua aberta';

  -- Faz 31 min: fecha, e o grupo sem app sai junto.
  update public.queue_entries
     set ended_at = case when ended_at is null then null else now() - interval '31 minutes' end,
         left_at  = case when left_at  is null then null else now() - interval '31 minutes' end
   where court_id = pg_temp.q1();
  assert (public.advance_expired_queues() ->> 'sessions_closed')::int = 1, 'com 31 min, fecha';

  assert not exists (select 1 from public.host_sessions where court_id = pg_temp.q1() and closed_at is null),
    'nenhuma fila aberta';
  assert not exists (select 1 from pg_temp.offline_entries() where status in ('waiting', 'ready')),
    'os grupos sem app saem com a fila';

  perform pg_temp.as_user('d5000000-0000-0000-0000-0000000000d5');
  v := public.court_screen(pg_temp.q1());
  assert (v ->> 'can_open_host')::boolean, 'a próxima pessoa abre uma nova';
end $$;

-- =====================================================================
-- A placa chegou: trocar para QR fixo fecha a fila aberta
-- =====================================================================
do $$
declare v jsonb;
begin
  perform pg_temp.as_user('d5000000-0000-0000-0000-0000000000d5');
  perform pg_temp.scan('d5000000-0000-0000-0000-0000000000d5', pg_temp.q1(), 'h-duda-open', 'gps');
  perform public.open_host_queue('h-duda-open', null, array['esperando']);

  perform pg_temp.as_user('e5000000-0000-0000-0000-0000000000e5');
  perform public.admin_upsert_court(p_id => pg_temp.q1(), p_queue_mode => 'fixed_qr');

  assert (select close_reason from public.host_sessions
           where court_id = pg_temp.q1() order by opened_at desc limit 1) = 'mode_changed', 'fechou pela troca';
  assert not exists (select 1 from pg_temp.offline_entries() where status in ('waiting', 'ready')),
    'o grupo sem app sai junto';
  assert exists (select 1 from public.queue_entry_members
                  where user_id = 'd5000000-0000-0000-0000-0000000000d5' and is_active),
    'a Duda, com o app, continua na fila';

  perform pg_temp.as_user('d5000000-0000-0000-0000-0000000000d5');
  v := public.court_screen(pg_temp.q1());
  assert v -> 'court' ->> 'queue_mode' = 'fixed_qr', 'modo QR fixo';
  assert v -> 'court' -> 'checkin_methods' = '["qr"]'::jsonb, 'check-in pelo QR da placa';
end $$;

-- ---------------------------------------------------------------------
-- Montar o grupo não é corrida contra a tolerância
--
-- Quem abre a fila ainda vai cadastrar quem já jogava, quem já
-- esperava sem app e passar o PIN aos amigos. Com o prazo de check-in
-- correndo desde a abertura, o cron expulsava a pessoa da fila que ela
-- mesma tinha aberto — e ela não conseguia nem entrar nem reabrir.
-- ---------------------------------------------------------------------
do $$
declare
  v_entry uuid; v_pin text; v_code text; v_prazo timestamptz; v jsonb;
  v_ana  uuid := 'a5000000-0000-0000-0000-0000000000a5';
  v_bia  uuid := 'b5000000-0000-0000-0000-0000000000b5';
  v_caio uuid := 'c5000000-0000-0000-0000-0000000000c5';
begin
  -- O bloco anterior trocou esta quadra para o QR da placa; aqui ela
  -- volta ao modo anfitrião, com a fila limpa.
  perform pg_temp.as_user('e5000000-0000-0000-0000-0000000000e5');
  perform public.admin_upsert_court(p_id => pg_temp.q1(), p_queue_mode => 'host');
  update public.queue_entries set status = 'done', ended_at = now()
   where court_id = pg_temp.q1() and status in ('waiting', 'ready', 'playing');
  update public.matches set ended_at = now()
   where court_id = pg_temp.q1() and ended_at is null;
  update public.host_sessions set closed_at = now(), close_reason = 'test_reset'
   where court_id = pg_temp.q1() and closed_at is null;

  perform pg_temp.as_user(v_ana);
  perform pg_temp.scan(v_ana, pg_temp.q1(), 'sp-open', 'gps');
  perform public.open_host_queue('sp-open', null, '{}');

  select e.id, e.call_expires_at into v_entry, v_prazo
  from public.queue_entry_members m join public.queue_entries e on e.id = m.entry_id
  where m.user_id = v_ana and m.is_active;

  assert v_prazo is null,
    format('sozinha na fila, a vaga de quem abriu não tem prazo; veio %s', v_prazo);
  assert (select status from public.queue_entries where id = v_entry) = 'ready',
    'e já fica pronta para o check-in';
  assert not exists (select 1 from public.matches where court_id = pg_temp.q1() and ended_at is null),
    'abrir a fila não começa o jogo: o tempo conta a partir do check-in';

  -- doze minutos montando o grupo, com o cron passando
  update public.queue_entries
     set joined_at = now() - interval '12 minutes', called_at = now() - interval '12 minutes'
   where id = v_entry;
  perform public.advance_expired_queues();
  assert (select status from public.queue_entries where id = v_entry) = 'ready',
    'doze minutos montando o grupo não podem expulsar quem abriu a fila';

  -- o amigo entra pelo PIN, na mesma vaga
  select p.pin into v_pin from public.queue_entry_pins p where p.entry_id = v_entry;
  perform pg_temp.as_user(v_bia);
  perform pg_temp.scan(v_bia, pg_temp.q1(), 'sp-bia');
  v := public.join_with_pin('sp-bia', v_pin);
  assert (v ->> 'joined')::boolean, 'o amigo entra na party antes do check-in';
  assert (select count(*) from public.queue_entry_members where entry_id = v_entry and is_active) = 2,
    'os dois na mesma vaga, mesma posição';

  -- chega um segundo grupo: aí sim o relógio começa
  perform pg_temp.as_user(v_ana);
  v_code := public.issue_host_invite(pg_temp.q1(), gen_random_uuid()) ->> 'code';
  perform pg_temp.as_user(v_caio);
  perform pg_temp.scan(v_caio, pg_temp.q1(), 'sp-caio', 'qr', pg_temp.invite_id_of(v_code));
  perform public.join_queue('sp-caio', 'double');

  select e.call_expires_at into v_prazo from public.queue_entries e where e.id = v_entry;
  assert v_prazo is not null, 'com gente atrás, a tolerância passa a valer';
  assert v_prazo > now() + interval '30 seconds',
    format('e começa inteira a partir dali, não vencida; veio %s', v_prazo);

  -- e continua protegendo a fila: quem não aparece perde a vez
  update public.queue_entries set call_expires_at = now() - interval '1 second' where id = v_entry;
  perform public.advance_expired_queues();
  assert (select status from public.queue_entries where id = v_entry) = 'expired',
    'passado o prazo com gente atrás, a vez passa';
  assert (select e.status from public.queue_entries e
           where e.court_id = pg_temp.q1() and e.created_by = v_caio) = 'ready',
    'e o próximo é chamado';
end $$;

-- A fila aberta e abandonada não pode travar a quadra para sempre,
-- agora que quem monta o grupo sozinho fica sem prazo.
do $$
declare v_sess uuid; v_ana uuid := 'a5000000-0000-0000-0000-0000000000a5';
begin
  perform pg_temp.as_user('e5000000-0000-0000-0000-0000000000e5');
  perform public.admin_upsert_court(p_id => pg_temp.q2(), p_queue_mode => 'host');

  perform pg_temp.as_user(v_ana);
  perform pg_temp.scan(v_ana, pg_temp.q2(), 'sp-aband', 'gps');
  perform public.open_host_queue('sp-aband', null, '{}');
  select s.id into v_sess from public.host_sessions s
   where s.court_id = pg_temp.q2() and s.closed_at is null;

  assert not public.host_session_is_idle(v_sess), 'recém-aberta, não está esquecida';

  update public.host_sessions set opened_at = now() - interval '40 minutes' where id = v_sess;
  update public.queue_entries
     set joined_at = now() - interval '40 minutes', called_at = now() - interval '40 minutes'
   where host_session_id = v_sess;

  assert public.host_session_is_idle(v_sess),
    'quarenta minutos sem ninguém se mexer: a fila está esquecida';
  perform public.advance_expired_queues();
  assert not exists (select 1 from public.host_sessions
                      where court_id = pg_temp.q2() and closed_at is null),
    'e o cron libera a quadra';
end $$;

rollback;

\echo '✔ tests/local/70_anfitriao_test.sql — fila com anfitrião, convite, vagas sem app e painel do piloto'
