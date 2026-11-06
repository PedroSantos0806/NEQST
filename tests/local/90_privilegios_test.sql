-- =====================================================================
-- Privilégios: a rede que impede a regressão da auditoria
--
-- Os outros arquivos de teste rodam como superusuário, então NENHUM
-- deles enxerga um grant errado — é por isso que 61 funções ficaram
-- executáveis por PUBLIC sem ninguém notar. Este arquivo testa
-- privilégio, não comportamento:
--
--   . nenhuma função nasce aberta para PUBLIC;
--   . tudo que o app chama continua chamável por quem o app é;
--   . o cliente não lê nem escreve o que não é dele;
--   . o anônimo não leva nome completo de ninguém.
-- =====================================================================
\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------
-- 1. Nenhuma função executável por PUBLIC
-- ---------------------------------------------------------------------
do $$
declare
  v_abertas text;
  v_quantas integer;
begin
  select count(*)::integer,
         string_agg(p.oid::regprocedure::text, ', ' order by p.oid::regprocedure::text)
  into v_quantas, v_abertas
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and has_function_privilege('public', p.oid, 'EXECUTE');

  assert v_quantas = 0, format(
    '%s função(ões) executável(eis) por PUBLIC. Falta `revoke execute ... from public` em: %s',
    v_quantas, v_abertas);
end $$;

-- ---------------------------------------------------------------------
-- 2. O que o app chama continua chamável
--
-- A lista vem do código: `rpc("...")` em web/src/lib/api.ts e
-- `.rpc("...")` nas Edge Functions. RPC nova entra aqui junto.
-- ---------------------------------------------------------------------
do $$
declare
  v_fn   text;
  v_erro text := '';
  -- Chamadas do app com a chave de usuário logado.
  v_authenticated text[] := array[
    'admin_court_devices', 'admin_create_court_device',
    'admin_overview', 'admin_pilot_stats', 'admin_revoke_court_device',
    'admin_set_match_time', 'admin_set_role', 'admin_upsert_court',
    'admin_upsert_park', 'admin_users', 'cancel_join_request', 'court_screen',
    'decide_join_request', 'host_add_offline', 'host_invite_opened',
    'host_mark_offline', 'issue_host_invite', 'join_with_pin', 'match_state',
    'my_profile_summary', 'my_queue_state', 'nudge_court', 'open_host_queue',
    'park_screen', 'parks_overview', 'request_join', 'update_my_profile',
    -- chamadas pelas Edge Functions com a chave do usuário
    'check_in_and_start', 'join_queue', 'leave_queue', 'finish_my_turn',
    'call_next', 'court_queue', 'court_photos_page'
  ];
  -- O totem, o QR e a placa da quadra não têm conta. O que autoriza
  -- cada um é um segredo: o token do aparelho, o scan token do código
  -- impresso, o party token guardado no navegador de quem entrou.
  v_anon text[] := array[
    'totem_screen', 'totem_join', 'totem_pause', 'totem_resume',
    'totem_continue', 'totem_exit_answer',
    'scan_join_party', 'party_screen', 'party_leave', 'party_exit_answer',
    'court_screen', 'court_queue',
    'court_queue_items', 'match_state', 'match_side_players', 'park_screen',
    'parks_overview'
  ];
begin
  foreach v_fn in array v_authenticated loop
    if not exists (
      select 1 from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = v_fn
        and has_function_privilege('authenticated', p.oid, 'EXECUTE')
    ) then
      v_erro := v_erro || format('%s (authenticated), ', v_fn);
    end if;
  end loop;

  foreach v_fn in array v_anon loop
    if not exists (
      select 1 from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = v_fn
        and has_function_privilege('anon', p.oid, 'EXECUTE')
    ) then
      v_erro := v_erro || format('%s (anon), ', v_fn);
    end if;
  end loop;

  assert v_erro = '', format('o app chama, mas o grant não existe: %s', v_erro);
end $$;

-- ---------------------------------------------------------------------
-- 3. profiles: o cliente não escreve identidade nem papel
-- ---------------------------------------------------------------------
do $$
declare
  v_col text;
begin
  -- Escrita permitida só no que é aparência e nome de exibição.
  foreach v_col in array array['full_name', 'avatar_url', 'avatar_tone',
                               'racket_frame_color', 'racket_grip_color'] loop
    assert has_column_privilege('authenticated', 'public.profiles', v_col, 'UPDATE'),
      format('o dono precisa poder editar %s', v_col);
  end loop;

  -- E nada no que decide quem a pessoa é.
  foreach v_col in array array['email', 'username', 'role', 'id'] loop
    assert not has_column_privilege('authenticated', 'public.profiles', v_col, 'UPDATE'),
      format('%s não pode ser escrita pelo cliente — era o primeiro passo da escalação', v_col);
  end loop;

  -- Leitura: nem o e-mail (base de contatos) nem o papel (saber quem é
  -- admin era o reconhecimento antes de tentar escalar).
  assert not has_column_privilege('authenticated', 'public.profiles', 'email', 'SELECT'),
    'o cliente não lê e-mail de ninguém';
  assert not has_column_privilege('authenticated', 'public.profiles', 'role', 'SELECT'),
    'o cliente não lê o papel de ninguém';
  assert has_column_privilege('authenticated', 'public.profiles', 'full_name', 'SELECT'),
    'nome de exibição continua legível para quem está logado';
end $$;

-- ---------------------------------------------------------------------
-- 4. A escalação a admin, pelos dois lados
-- ---------------------------------------------------------------------
insert into auth.users (id, email, raw_user_meta_data) values
  ('a9000000-0000-0000-0000-0000000000a9', 'chefe@auditoria.local', '{"full_name":"Chefe Real"}'),
  ('b9000000-0000-0000-0000-0000000000b9', 'atacante@auditoria.local', '{"full_name":"Atacante"}');

-- Lado 1: gravar o e-mail do chefe no próprio perfil não é mais possível.
do $$
begin
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', 'b9000000-0000-0000-0000-0000000000b9', true);

  begin
    update public.profiles set email = 'chefe@auditoria.local'
     where id = 'b9000000-0000-0000-0000-0000000000b9';
    assert false, 'gravar e-mail alheio no próprio perfil deveria ser negado';
  exception when insufficient_privilege then
    null;
  end;

  reset role;
end $$;

-- Lado 2: mesmo com dois perfis com o mesmo e-mail, a promoção resolve
-- pela conta (auth.users), não pelo perfil — e recusa ambiguidade.
do $$
declare v jsonb; v_code text;
begin
  -- Forçado pelo dono da tabela, simulando dados já estragados.
  update public.profiles set email = 'chefe@auditoria.local'
   where id = 'b9000000-0000-0000-0000-0000000000b9';

  assert (select count(*) from public.profiles
           where lower(email) = 'chefe@auditoria.local') = 2,
    'dois perfis com o mesmo e-mail, como no cenário da auditoria';

  v := public.promote_to_admin('chefe@auditoria.local');
  assert v ->> 'user_id' = 'a9000000-0000-0000-0000-0000000000a9',
    format('promoveu a conta certa, não o perfil forjado: %s', v);

  -- E o atacante não vira admin nem pedindo pelo id dele.
  begin
    perform public.promote_to_admin_by_id('b9000000-0000-0000-0000-0000000000b9');
    assert false, 'um segundo admin deveria falhar';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ022', format('esperava NQ022, obtive %s', v_code);
  end;
end $$;

-- ---------------------------------------------------------------------
-- 5. O anônimo não leva nome completo
-- ---------------------------------------------------------------------
insert into public.parks (id, slug, name, district, latitude, longitude)
values ('99990000-0000-0000-0000-000000000009', 'teste-privilegio', 'Parque do Privilégio',
        'Centro', -23.58, -46.66);

insert into public.courts (id, park_id, court_number, surface, slot_minutes, slug, name,
                           latitude, longitude, queue_mode)
values ('a9a90000-0000-0000-0000-0000000000a9', '99990000-0000-0000-0000-000000000009', 1,
        'hard', 40, 'teste-privilegio-q1', 'Quadra 01', -23.58, -46.66, 'fixed_qr');

do $$
declare
  v_entry uuid;
  v_logado   jsonb;
  v_anonimo  jsonb;
begin
  insert into public.queue_entries (court_id, mode, created_by)
  values ('a9a90000-0000-0000-0000-0000000000a9', 'single', 'a9000000-0000-0000-0000-0000000000a9')
  returning id into v_entry;

  insert into public.queue_entry_members (entry_id, court_id, user_id, role, origin)
  values (v_entry, 'a9a90000-0000-0000-0000-0000000000a9',
          'a9000000-0000-0000-0000-0000000000a9', 'owner', 'qr');

  -- Logado: vê o nome completo, como sempre.
  perform set_config('request.jwt.claim.sub', 'a9000000-0000-0000-0000-0000000000a9', true);
  v_logado := public.match_side_players(v_entry);
  assert v_logado -> 0 ->> 'full_name' = 'Chefe Real',
    format('quem está logado continua vendo o nome: %s', v_logado);

  -- Anônimo: só o nome curto e as iniciais.
  perform set_config('request.jwt.claim.sub', '', true);
  v_anonimo := public.match_side_players(v_entry);
  assert v_anonimo -> 0 ->> 'full_name' is null,
    format('o anônimo não leva nome completo: %s', v_anonimo);
  assert v_anonimo -> 0 ->> 'username' is null, 'nem username';
  assert v_anonimo -> 0 ->> 'user_id' is null, 'nem o id, que liga uma pessoa entre dias';
  assert v_anonimo -> 0 ->> 'short_name' = 'Chefe R.',
    format('mas o nome curto fica — é o que a fila e o tablet falam: %s', v_anonimo);

  -- E o mesmo vale no payload da fila pública.
  v_anonimo := public.queue_entry_players(v_entry);
  assert v_anonimo -> 0 ->> 'full_name' is null,
    format('queue_entry_players também: %s', v_anonimo);
  assert v_anonimo -> 0 ->> 'short_name' is not null, 'com o nome curto';
end $$;

-- ---------------------------------------------------------------------
-- 6. Sem conta não quer dizer sem porteiro
--
-- A fila passou a aceitar escrita de quem não está logado, e é por isso
-- que estas funções NÃO podem estar abertas: quem escreve na fila tem de
-- passar por um dos três segredos (token do totem, scan token do QR,
-- party token do navegador). Se `join_party` ficasse chamável pelo anon,
-- qualquer um com a chave publicável encheria a fila de qualquer quadra.
-- ---------------------------------------------------------------------
do $$
declare
  v_fn    text;
  v_papel text;
  v_erro  text := '';
  v_internas text[] := array[
    'join_party', 'pause_court', 'resume_court', 'continue_playing',
    'answer_exit_ask', 'start_handover', 'advance_court', 'tick_court',
    'open_match', 'close_match', 'requeue_entry', 'totem_court',
    'take_party_entry', 'take_anon_scan_token', 'totem_state',
    'expire_stale_queue_entries', 'advance_expired_queues'
  ];
begin
  foreach v_fn in array v_internas loop
    foreach v_papel in array array['anon', 'authenticated'] loop
      if exists (
        select 1 from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = v_fn
          and has_function_privilege(v_papel, p.oid, 'EXECUTE')
      ) then
        v_erro := v_erro || format('%s (%s), ', v_fn, v_papel);
      end if;
    end loop;
  end loop;

  assert v_erro = '', format(
    'estas são internas e não podem ser chamadas pelo cliente: %s', v_erro);
end $$;

-- E o token do totem é o que separa uma quadra da outra: com o token de
-- uma, não se escreve na fila de outra.
do $$
declare v_code text;
begin
  perform set_config('request.jwt.claim.sub', '', true);
  begin
    perform public.totem_screen('token-que-ninguem-emitiu');
    assert false, 'token inventado deveria ser recusado';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ037', format('esperava NQ037, obtive %s', v_code);
  end;
end $$;

rollback;

\echo '✔ tests/local/90_privilegios_test.sql — grants, colunas de profiles e o que o anônimo lê'
