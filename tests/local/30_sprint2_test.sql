-- =====================================================================
-- Teste funcional da Sprint 2: histórico, avaliações, fotos e mapa de
-- calor. Roda sobre o mesmo stub de auth da Sprint 1.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- Fixtures: duas quadras, três jogadores, um operador
-- ---------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('aaaa0000-0000-0000-0000-00000000000a', 'ana@example.com',   '{"full_name":"Ana Souza"}'),
  ('bbbb0000-0000-0000-0000-00000000000b', 'bruno@example.com', '{"full_name":"Bruno Lima"}'),
  ('cccc0000-0000-0000-0000-00000000000c', 'caio@example.com',  '{"full_name":"Caio Melo"}'),
  ('dddd0000-0000-0000-0000-00000000000d', 'staff@example.com', '{"full_name":"Operador"}');

insert into public.parks (id, slug, name, district, latitude, longitude)
values
  ('7f7f0000-0000-0000-0000-00000000f001', 'parque-central', 'Parque Central',
   'Centro', -23.561414, -46.655881),
  ('7f7f0000-0000-0000-0000-00000000f002', 'parque-norte', 'Parque Norte',
   'Zona Norte', -23.545000, -46.640000);

insert into public.courts (id, park_id, court_number, surface, slug, name,
                           latitude, longitude, slot_minutes,
                           busy_threshold, full_threshold)
values
  ('1111aaaa-0000-0000-0000-000000000001', '7f7f0000-0000-0000-0000-00000000f001',
   1, 'clay', 'quadra-central', 'Quadra Central', -23.561414, -46.655881, 20, 2, 4),
  ('2222bbbb-0000-0000-0000-000000000002', '7f7f0000-0000-0000-0000-00000000f002',
   1, 'hard', 'quadra-norte', 'Quadra Norte', -23.545000, -46.640000, 30, 3, 6);

update public.profiles set role = 'admin' where id = 'dddd0000-0000-0000-0000-00000000000d';

-- Helper: partida concluída, do jeito que a Sprint 1 grava
create or replace function pg_temp.played(
  p_court   uuid,
  p_user    uuid,
  p_partner uuid default null,
  p_ago     interval default '1 day',
  p_minutes integer default 20
)
returns uuid language plpgsql as $$
declare v_entry uuid;
begin
  insert into public.queue_entries
    (court_id, mode, status, created_by, joined_at, started_at, ended_at)
  values
    (p_court,
     case when p_partner is null then 'single'::public.queue_mode
                                  else 'double'::public.queue_mode end,
     'done'::public.queue_entry_status, p_user,
     now() - p_ago - make_interval(mins => p_minutes),
     now() - p_ago - make_interval(mins => p_minutes),
     now() - p_ago)
  returning id into v_entry;

  insert into public.queue_entry_members (entry_id, court_id, user_id, role, is_active)
  values (v_entry, p_court, p_user, 'owner', false);

  if p_partner is not null then
    insert into public.queue_entry_members (entry_id, court_id, user_id, role, is_active)
    values (v_entry, p_court, p_partner, 'partner', false);
  end if;

  return v_entry;
end;
$$;

-- Ana: 2 partidas na Central (uma em dupla com Bruno) e 1 na Norte
do $$ begin
  perform pg_temp.played('1111aaaa-0000-0000-0000-000000000001',
                         'aaaa0000-0000-0000-0000-00000000000a', null, '3 days', 25);
  perform pg_temp.played('1111aaaa-0000-0000-0000-000000000001',
                         'aaaa0000-0000-0000-0000-00000000000a',
                         'bbbb0000-0000-0000-0000-00000000000b', '1 day', 40);
  perform pg_temp.played('2222bbbb-0000-0000-0000-000000000002',
                         'aaaa0000-0000-0000-0000-00000000000a', null, '2 hours', 30);
end $$;

-- =====================================================================
-- Histórico do usuário
-- =====================================================================
set local "request.jwt.claim.sub" = 'aaaa0000-0000-0000-0000-00000000000a';

do $$
declare v jsonb; v_first jsonb;
begin
  v := public.my_match_history();
  assert jsonb_array_length(v) = 3, format('Ana deveria ter 3 partidas: %s', jsonb_array_length(v));

  v_first := v -> 0;
  assert v_first ->> 'court_name' = 'Quadra Norte',
    format('a mais recente deveria ser a Norte: %s', v_first ->> 'court_name');
  assert (v_first ->> 'duration_minutes')::int = 30,
    format('duração calculada errada: %s', v_first ->> 'duration_minutes');
  assert jsonb_array_length(v_first -> 'teammates') = 0, 'individual não tem parceiro';

  -- A partida de dupla lista o Bruno como parceiro
  assert exists (
    select 1 from jsonb_array_elements(v) m
    where jsonb_array_length(m -> 'teammates') = 1
      and (m -> 'teammates' -> 0 ->> 'username') = 'bruno'
  ), format('a dupla deveria listar o bruno: %s', v);
end $$;

-- Paginação por cursor
do $$
declare v_page1 jsonb; v_page2 jsonb; v_cursor timestamptz;
begin
  v_page1 := public.my_match_history(2);
  assert jsonb_array_length(v_page1) = 2, 'primeira página deveria ter 2';

  v_cursor := ((v_page1 -> 1) ->> 'ended_at')::timestamptz;
  v_page2  := public.my_match_history(2, v_cursor);

  assert jsonb_array_length(v_page2) = 1, format('segunda página deveria ter 1: %s', v_page2);
  assert (v_page2 -> 0 ->> 'entry_id') <> (v_page1 -> 0 ->> 'entry_id'),
    'a paginação não deveria repetir linhas';
end $$;

do $$
declare v jsonb;
begin
  v := public.my_visited_courts();
  assert jsonb_array_length(v) = 2, format('Ana visitou 2 quadras: %s', jsonb_array_length(v));
  assert (v -> 0 ->> 'court_name') = 'Quadra Norte', 'ordenar pela visita mais recente';

  -- Central: 25 + 40 minutos em 2 partidas
  assert exists (
    select 1 from jsonb_array_elements(v) c
    where c ->> 'court_name' = 'Quadra Central'
      and (c ->> 'matches_played')::int = 2
      and (c ->> 'minutes_played')::int = 65
  ), format('agregado da Central errado: %s', v);
end $$;

do $$
declare v jsonb;
begin
  v := public.my_profile_summary();
  assert (v -> 'profile' ->> 'username') = 'ana', 'perfil errado';
  assert (v -> 'stats' ->> 'matches_played')::int = 3, 'total de partidas errado';
  assert (v -> 'stats' ->> 'courts_visited')::int = 2, 'total de quadras errado';
  assert (v -> 'stats' ->> 'minutes_played')::int = 95, 'total de minutos errado';
end $$;

-- Caio nunca jogou: histórico vazio, sem erro
set local "request.jwt.claim.sub" = 'cccc0000-0000-0000-0000-00000000000c';
do $$ begin
  assert public.my_match_history() = '[]'::jsonb, 'quem nunca jogou tem histórico vazio';
  assert public.my_visited_courts() = '[]'::jsonb, 'quem nunca jogou não visitou quadras';
end $$;

-- =====================================================================
-- Avaliação da quadra
-- =====================================================================

-- Caio não jogou na Central, então não pode avaliar
do $$
declare v_code text;
begin
  assert not public.can_review_court('1111aaaa-0000-0000-0000-000000000001'),
    'Caio não deveria poder avaliar';
  begin
    perform public.rate_court('1111aaaa-0000-0000-0000-000000000001', 5::smallint, 'top');
    assert false, 'avaliação sem ter jogado deveria falhar';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ010', format('esperava NQ010, obtive %s', v_code);
  end;
end $$;

set local "request.jwt.claim.sub" = 'aaaa0000-0000-0000-0000-00000000000a';

do $$
declare v jsonb; v_code text;
begin
  assert public.can_review_court('1111aaaa-0000-0000-0000-000000000001'), 'Ana jogou, logo pode avaliar';

  v := public.rate_court('1111aaaa-0000-0000-0000-000000000001', 4::smallint, 'Saibro bem cuidado.');
  assert (v ->> 'rating')::int = 4, format('nota não gravada: %s', v);
  assert (v -> 'court_rating' ->> 'count')::int = 1, 'contagem deveria ser 1';
  assert (v -> 'court_rating' ->> 'average')::numeric = 4.00, 'média deveria ser 4';

  -- Nota fora da faixa
  begin
    perform public.rate_court('1111aaaa-0000-0000-0000-000000000001', 6::smallint);
    assert false, 'nota 6 deveria falhar';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ011', format('esperava NQ011, obtive %s', v_code);
  end;

  -- Reavaliar atualiza, não duplica
  v := public.rate_court('1111aaaa-0000-0000-0000-000000000001', 2::smallint, 'Choveu, encharcou.');
  assert (v -> 'court_rating' ->> 'count')::int = 1, 'reavaliar não deveria criar outra linha';
  assert (v -> 'court_rating' ->> 'average')::numeric = 2.00, 'média deveria cair para 2';
end $$;

-- Bruno jogou na Central (como parceiro) e também avalia
set local "request.jwt.claim.sub" = 'bbbb0000-0000-0000-0000-00000000000b';
do $$
declare v jsonb;
begin
  assert public.can_review_court('1111aaaa-0000-0000-0000-000000000001'),
    'parceiro de dupla também jogou';

  v := public.rate_court('1111aaaa-0000-0000-0000-000000000001', 5::smallint);
  assert (v -> 'court_rating' ->> 'count')::int = 2, 'agora são 2 avaliações';
  assert (v -> 'court_rating' ->> 'average')::numeric = 3.50, 'média de 2 e 5 é 3.5';
end $$;

do $$
declare v jsonb;
begin
  v := public.court_reviews_page('1111aaaa-0000-0000-0000-000000000001');
  assert (v -> 'summary' ->> 'count')::int = 2, 'resumo com 2 avaliações';
  assert (v -> 'summary' -> 'distribution' ->> '5')::int = 1, 'distribuição deveria ter um 5';
  assert (v -> 'my_review' ->> 'rating')::int = 5, 'my_review deveria ser do Bruno';
  assert jsonb_array_length(v -> 'reviews') = 2, 'lista com 2 avaliações';
  assert (v -> 'reviews' -> 0 -> 'author' ->> 'username') is not null, 'autor deveria vir preenchido';
end $$;

-- Remover a própria avaliação recalcula o agregado
do $$
declare v jsonb; v_avg numeric;
begin
  v := public.delete_my_court_review('1111aaaa-0000-0000-0000-000000000001');
  assert (v ->> 'deleted')::boolean, 'remoção deveria acontecer';

  select rating_avg into v_avg from public.courts
  where id = '1111aaaa-0000-0000-0000-000000000001';
  assert v_avg = 2.00, format('média deveria voltar para 2: %s', v_avg);
end $$;

-- =====================================================================
-- Fotos da quadra
-- =====================================================================
set local "request.jwt.claim.sub" = 'aaaa0000-0000-0000-0000-00000000000a';

do $$
declare v_photo uuid; v jsonb;
begin
  -- A Edge Function cria a linha; aqui simulamos o que ela faz.
  insert into public.court_photos (court_id, user_id, storage_path, content_type)
  values ('1111aaaa-0000-0000-0000-000000000001',
          'aaaa0000-0000-0000-0000-00000000000a',
          '1111aaaa-0000-0000-0000-000000000001/foto-1.jpg', 'image/jpeg')
  returning id into v_photo;

  -- Pendente e sem upload confirmado não aparece para o app
  v := public.court_photos_page('1111aaaa-0000-0000-0000-000000000001');
  assert v = '[]'::jsonb, format('foto pendente não deveria aparecer: %s', v);

  update public.court_photos set is_uploaded = true where id = v_photo;

  v := public.court_photos_page('1111aaaa-0000-0000-0000-000000000001');
  assert v = '[]'::jsonb, 'foto sem aprovação ainda não aparece';
end $$;

-- Jogador comum não modera
do $$
declare v_code text; v_photo uuid;
begin
  select id into v_photo from public.court_photos limit 1;
  begin
    perform public.moderate_court_photo(v_photo, true);
    assert false, 'jogador comum não deveria moderar';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ008', format('esperava NQ008, obtive %s', v_code);
  end;
end $$;

-- Operador aprova; a foto passa a aparecer e vira capa da quadra
set local "request.jwt.claim.sub" = 'dddd0000-0000-0000-0000-00000000000d';
do $$
declare v_photo uuid; v jsonb; v_cover text;
begin
  select id into v_photo from public.court_photos limit 1;

  v := public.moderate_court_photo(v_photo, true);
  assert v ->> 'status' = 'approved', format('deveria aprovar: %s', v);

  v := public.court_photos_page('1111aaaa-0000-0000-0000-000000000001');
  assert jsonb_array_length(v) = 1, format('foto aprovada deveria aparecer: %s', v);

  select cover_photo_path into v_cover from public.courts
  where id = '1111aaaa-0000-0000-0000-000000000001';
  assert v_cover = '1111aaaa-0000-0000-0000-000000000001/foto-1.jpg',
    format('capa da quadra deveria apontar para a foto: %s', v_cover);

  -- Rejeitar tira do ar e limpa a capa
  v := public.moderate_court_photo(v_photo, false, 'fora de foco');
  assert v ->> 'status' = 'rejected', 'deveria rejeitar';

  v := public.court_photos_page('1111aaaa-0000-0000-0000-000000000001');
  assert v = '[]'::jsonb, 'foto rejeitada não aparece';

  select cover_photo_path into v_cover from public.courts
  where id = '1111aaaa-0000-0000-0000-000000000001';
  assert v_cover is null, format('capa deveria voltar a ser nula: %s', v_cover);
end $$;

-- O bucket e a policy do Storage foram criados pela migration
do $$
declare v_public boolean; v_limit bigint; v_types text[];
begin
  select public, file_size_limit, allowed_mime_types
  into v_public, v_limit, v_types
  from storage.buckets where id = 'court-photos';

  assert found, 'o bucket court-photos deveria existir';
  assert not v_public, 'o bucket precisa ser privado (foto rejeitada sai do ar)';
  assert v_limit = 10485760, format('limite de tamanho errado: %s', v_limit);
  assert 'image/webp' = any(v_types), format('mime types: %s', v_types);

  assert exists (
    select 1 from pg_policies
    where schemaname = 'storage' and tablename = 'objects'
      and policyname = 'court-photos: leitura de aprovadas'
  ), 'a policy de leitura do bucket deveria existir';
end $$;

-- Cota de fotos pendentes por jogador por quadra
set local "request.jwt.claim.sub" = 'bbbb0000-0000-0000-0000-00000000000b';
do $$
declare v_code text;
begin
  for i in 1..5 loop
    insert into public.court_photos (court_id, user_id, storage_path)
    values ('2222bbbb-0000-0000-0000-000000000002',
            'bbbb0000-0000-0000-0000-00000000000b',
            format('2222bbbb-0000-0000-0000-000000000002/b-%s.jpg', i));
  end loop;

  begin
    insert into public.court_photos (court_id, user_id, storage_path)
    values ('2222bbbb-0000-0000-0000-000000000002',
            'bbbb0000-0000-0000-0000-00000000000b',
            '2222bbbb-0000-0000-0000-000000000002/b-6.jpg');
    assert false, 'a sexta foto pendente deveria ser recusada';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ012', format('esperava NQ012, obtive %s', v_code);
  end;
end $$;

-- =====================================================================
-- Mapa de calor
-- =====================================================================

-- Classificação pura
do $$ begin
  assert public.occupancy_of(0, false, 2, 4) = 'empty', 'sem fila e sem jogo = vazia';
  assert public.occupancy_of(0, true,  2, 4) = 'low',   'em jogo sem fila = baixa';
  assert public.occupancy_of(1, false, 2, 4) = 'low',   '1 time = baixa';
  assert public.occupancy_of(2, false, 2, 4) = 'busy',  '2 times = movimentada';
  assert public.occupancy_of(4, false, 2, 4) = 'full',  '4 times = cheia';
  -- Limites por quadra: a Norte só enche com 6
  assert public.occupancy_of(4, false, 3, 6) = 'busy',  'limites da quadra são respeitados';
end $$;

-- Fila ao vivo na Central: 1 em jogo + 2 aguardando
do $$
declare v_entry uuid;
begin
  -- Partida ao vivo: agora é uma linha em matches (a ocupação lê de lá).
  insert into public.queue_entries (court_id, mode, status, created_by, started_at)
  values ('1111aaaa-0000-0000-0000-000000000001', 'single', 'playing',
          'aaaa0000-0000-0000-0000-00000000000a', now())
  returning id into v_entry;
  insert into public.queue_entry_members (entry_id, court_id, user_id)
  values (v_entry, '1111aaaa-0000-0000-0000-000000000001', 'aaaa0000-0000-0000-0000-00000000000a');
  insert into public.matches (court_id, side_a_entry_id, mode, slot_minutes, expires_at)
  values ('1111aaaa-0000-0000-0000-000000000001', v_entry, 'single', 20, now() + interval '20 minutes');

  insert into public.queue_entries (court_id, mode, status, created_by)
  values ('1111aaaa-0000-0000-0000-000000000001', 'single', 'waiting',
          'bbbb0000-0000-0000-0000-00000000000b')
  returning id into v_entry;
  insert into public.queue_entry_members (entry_id, court_id, user_id)
  values (v_entry, '1111aaaa-0000-0000-0000-000000000001', 'bbbb0000-0000-0000-0000-00000000000b');

  insert into public.queue_entries (court_id, mode, status, created_by)
  values ('1111aaaa-0000-0000-0000-000000000001', 'single', 'waiting',
          'cccc0000-0000-0000-0000-00000000000c')
  returning id into v_entry;
  insert into public.queue_entry_members (entry_id, court_id, user_id)
  values (v_entry, '1111aaaa-0000-0000-0000-000000000001', 'cccc0000-0000-0000-0000-00000000000c');
end $$;

do $$
declare v jsonb; v_central jsonb; v_norte jsonb;
begin
  v := public.courts_heatmap();
  -- Escopado aos nomes do teste: a suíte pode rodar num banco com seed.
  assert (select count(*) from jsonb_array_elements(v) c
          where c ->> 'name' in ('Quadra Central', 'Quadra Norte')) = 2,
    format('as 2 quadras do teste deveriam aparecer: %s', v);

  select c into v_central from jsonb_array_elements(v) c where c ->> 'name' = 'Quadra Central';
  select c into v_norte   from jsonb_array_elements(v) c where c ->> 'name' = 'Quadra Norte';

  assert (v_central ->> 'teams_waiting')::int = 2, format('Central com 2 na fila: %s', v_central);
  assert (v_central ->> 'has_match')::boolean, 'Central está em jogo';
  assert v_central ->> 'occupancy' = 'busy',
    format('Central deveria estar movimentada: %s', v_central ->> 'occupancy');
  assert (v_central ->> 'estimated_wait_minutes')::int = 40, '2 times x 20 min';

  assert v_norte ->> 'occupancy' = 'empty', 'Norte está vazia';
  assert (v_norte ->> 'teams_waiting')::int = 0, 'Norte sem fila';

  -- Sem GPS, distance_meters vem nula (a web costuma abrir sem permissão)
  assert v_central -> 'distance_meters' = 'null'::jsonb, 'sem coordenadas não há distância';
end $$;

-- Filtro geográfico
do $$
declare v jsonb;
begin
  -- 500 m da Central: só ela entra
  v := public.courts_heatmap(-23.561414, -46.655881, 500);
  assert jsonb_array_length(v) = 1, format('raio de 500 m deveria pegar 1 quadra: %s', v);
  assert (v -> 0 ->> 'name') = 'Quadra Central', 'a quadra mais próxima é a Central';
  assert (v -> 0 ->> 'distance_meters')::numeric < 1, 'distância deveria ser ~0';

  -- 5 km: as duas do teste, ordenadas por distância
  v := public.courts_heatmap(-23.561414, -46.655881, 5000);
  assert (select count(*) from jsonb_array_elements(v) c
          where c ->> 'name' in ('Quadra Central', 'Quadra Norte')) = 2,
    'raio de 5 km pega as duas do teste';
  assert (v -> 0 ->> 'name') = 'Quadra Central', 'ordenação por distância';
end $$;

-- Snapshots e movimento típico
do $$
declare v_count integer; v jsonb;
begin
  v_count := public.capture_occupancy_snapshots();
  assert v_count >= 2, format('ao menos 1 snapshot por quadra ativa: %s', v_count);

  v := public.court_occupancy_pattern('1111aaaa-0000-0000-0000-000000000001');
  assert (v ->> 'samples')::int = 1, format('1 amostra: %s', v);
  assert jsonb_array_length(v -> 'pattern') = 1, 'um par dia/hora';
  assert (v -> 'pattern' -> 0 ->> 'avg_teams_waiting')::numeric = 2.00, 'média de 2 times';
  assert (v -> 'pattern' -> 0 ->> 'typical_occupancy') = 'busy', 'horário típico movimentado';
end $$;

-- run_maintenance agrega as rotinas
set local "request.jwt.claim.sub" = 'dddd0000-0000-0000-0000-00000000000d';
do $$
declare v jsonb;
begin
  v := public.run_maintenance();
  assert (v ->> 'occupancy_snapshots')::int >= 2, format('manutenção deveria capturar snapshots: %s', v);
  assert v ? 'expired_entries' and v ? 'purged_scan_tokens', 'manutenção mantém as rotinas da Sprint 1';
end $$;

-- =====================================================================
-- Web Push
-- =====================================================================
do $$
begin
  insert into public.web_push_subscriptions (user_id, endpoint, p256dh, auth)
  values ('aaaa0000-0000-0000-0000-00000000000a',
          'https://fcm.googleapis.com/fcm/send/abc123', 'BI6Dyd', '624jYM');

  assert public.has_push_channel('aaaa0000-0000-0000-0000-00000000000a'),
    'Ana tem canal web';
  assert not public.has_push_channel('cccc0000-0000-0000-0000-00000000000c'),
    'Caio não tem canal nenhum';

  -- Token de app também conta
  insert into public.push_tokens (user_id, token, platform)
  values ('cccc0000-0000-0000-0000-00000000000c', 'ExponentPushToken[abc]', 'android');

  assert public.has_push_channel('cccc0000-0000-0000-0000-00000000000c'),
    'agora Caio tem canal de app';
end $$;

do $$
declare v_code text;
begin
  begin
    insert into public.web_push_subscriptions (user_id, endpoint, p256dh, auth)
    values ('aaaa0000-0000-0000-0000-00000000000a', 'http://inseguro.test/push', 'x', 'y');
    assert false, 'endpoint sem https deveria ser recusado';
  exception when check_violation then
    null; -- esperado
  end;
end $$;

rollback;

\echo '✔ tests/local/30_sprint2_test.sql — histórico, avaliações, fotos, mapa de calor e web push'
