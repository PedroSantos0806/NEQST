-- =====================================================================
-- Administração: um único admin, criação de parque/quadra e papéis
-- =====================================================================
begin;

-- Fixtures próprias: o teste roda igual em banco limpo ou já semeado.
insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-00000000000a', 'chefe@teste.local'),
  ('a2000000-0000-0000-0000-00000000000b', 'jogador@teste.local'),
  ('a3000000-0000-0000-0000-00000000000c', 'outro@teste.local')
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- promote_to_admin
-- ---------------------------------------------------------------------
do $$
declare v jsonb; v_code text;
begin
  v := public.promote_to_admin('chefe@teste.local');
  assert v ->> 'role' = 'admin', format('deveria promover: %s', v);

  assert (select role from public.profiles where id = 'a1000000-0000-0000-0000-00000000000a')
         = 'admin'::public.app_role, 'o perfil ficou admin';

  -- Idempotente para o mesmo e-mail
  v := public.promote_to_admin('chefe@teste.local');
  assert v ->> 'role' = 'admin', 'promover de novo o mesmo não quebra';

  -- E-mail inexistente
  begin
    perform public.promote_to_admin('ninguem@teste.local');
    assert false, 'e-mail inexistente deveria falhar';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ021', format('esperava NQ021, obtive %s', v_code);
  end;

  -- Segundo admin: barrado pela função
  begin
    perform public.promote_to_admin('jogador@teste.local');
    assert false, 'um segundo admin deveria falhar';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ022', format('esperava NQ022, obtive %s', v_code);
  end;
end $$;

-- Segundo admin por UPDATE direto: barrado pelo índice único
do $$
declare v_code text;
begin
  begin
    update public.profiles set role = 'admin'::public.app_role
    where id = 'a2000000-0000-0000-0000-00000000000b';
    assert false, 'o índice único deveria impedir o segundo admin';
  exception when unique_violation then
    null;
  end;
end $$;

-- ---------------------------------------------------------------------
-- RPCs de admin: só o admin passa
-- ---------------------------------------------------------------------
set local role authenticated;
set local "request.jwt.claim.sub" = 'a2000000-0000-0000-0000-00000000000b';

do $$
declare v_code text;
begin
  begin
    perform public.admin_overview();
    assert false, 'jogador comum não pode ver o painel';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ023', format('esperava NQ023, obtive %s', v_code);
  end;

  begin
    perform public.admin_upsert_park(null, 'Parque Pirata', null, null, null, -23.5, -46.6);
    assert false, 'jogador comum não cria parque';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ023', format('esperava NQ023, obtive %s', v_code);
  end;
end $$;

-- ---------------------------------------------------------------------
-- Como admin: cadastrar parque e quadras
-- ---------------------------------------------------------------------
set local "request.jwt.claim.sub" = 'a1000000-0000-0000-0000-00000000000a';

do $$
declare
  v_park jsonb; v_court jsonb; v_court2 jsonb; v jsonb;
  v_park_id uuid;
begin
  v_park := public.admin_upsert_park(
    null, 'Parque São João Acentuação', 'Centro', 'São Paulo',
    'Av. das Quadras, 100', -23.55, -46.63, '#2F4629', 'quadra nova'
  );
  v_park_id := (v_park ->> 'id')::uuid;

  assert v_park ->> 'address' = 'Av. das Quadras, 100',
    format('o endereço digitado é gravado: %s', v_park ->> 'address');

  assert v_park ->> 'slug' = 'parque-sao-joao-acentuacao',
    format('slug sem acento: %s', v_park ->> 'slug');
  assert (v_park ->> 'is_active')::boolean, 'parque nasce ativo';

  -- Primeira quadra: número e nome automáticos
  v_court := public.admin_upsert_court(null, v_park_id);
  assert (v_court ->> 'court_number')::int = 1, format('primeira quadra é a 1: %s', v_court);
  assert v_court ->> 'name' = 'Quadra 01', format('nome automático: %s', v_court ->> 'name');
  assert v_court ->> 'surface' = 'clay', 'saibro por padrão';
  assert (v_court ->> 'latitude')::double precision = -23.55, 'herda a posição do parque';
  assert v_court ->> 'address' = 'Av. das Quadras, 100', 'e herda o endereço do parque';
  assert (v_court ->> 'slot_minutes')::int = 40, 'slot padrão de 40 min';

  -- Segunda quadra: o número anda sozinho
  v_court2 := public.admin_upsert_court(null, v_park_id, null, 'hard');
  assert (v_court2 ->> 'court_number')::int = 2, format('segunda quadra é a 2: %s', v_court2);
  assert v_court2 ->> 'surface' = 'hard', 'piso informado vale';
  assert v_court2 ->> 'slug' <> v_court ->> 'slug', 'slugs diferentes';

  -- Editar
  v := public.admin_upsert_court((v_court2 ->> 'id')::uuid, null, null, 'grass', 'Quadra do Fundo');
  assert v ->> 'name' = 'Quadra do Fundo', 'renomeou';
  assert v ->> 'surface' = 'grass', 'trocou o piso';
  assert (v ->> 'court_number')::int = 2, 'número preservado';

  -- Desativar
  v := public.admin_upsert_court((v_court2 ->> 'id')::uuid, p_is_active => false);
  assert not (v ->> 'is_active')::boolean, 'desativou';

  -- Raio de proximidade: padrão ao criar, editável depois
  assert (v_court ->> 'max_distance_meters')::int = 1000, 'raio padrão de 1 km';
  assert (v_court ->> 'gps_tolerance_meters')::int = 200, 'tolerância padrão de 200 m';

  v := public.admin_upsert_court(
    (v_court ->> 'id')::uuid,
    p_max_distance_meters => 20000,
    p_gps_tolerance_meters => 2000
  );
  assert (v ->> 'max_distance_meters')::int = 20000, format('raio afrouxado: %s', v ->> 'max_distance_meters');
  assert (v ->> 'gps_tolerance_meters')::int = 2000, 'tolerância afrouxada';

  -- Interruptor de proximidade: nasce ligado, desliga por quadra
  assert (v_court ->> 'enforce_proximity')::boolean, 'a verificação nasce ligada';

  v := public.admin_upsert_court((v_court ->> 'id')::uuid, p_enforce_proximity => false);
  assert not (v ->> 'enforce_proximity')::boolean, 'desligou a verificação';

  v := public.admin_upsert_court((v_court ->> 'id')::uuid, p_enforce_proximity => true);
  assert (v ->> 'enforce_proximity')::boolean, 'e liga de volta';

  -- Mexer noutro campo não mexe no interruptor
  v := public.admin_upsert_court((v_court ->> 'id')::uuid, p_enforce_proximity => false);
  v := public.admin_upsert_court((v_court ->> 'id')::uuid, p_slot_minutes => 30::smallint);
  assert not (v ->> 'enforce_proximity')::boolean,
    'editar o slot não pode religar a verificação sozinho';
  assert (v ->> 'slot_minutes')::int = 30, 'slot mudou';

  -- Alfinete próprio: a quadra no meio do parque não fica com a
  -- coordenada do portão. É esta posição que o check-in compara.
  v := public.admin_upsert_court(
    null, v_park_id, null, 'clay', 'Quadra do Bosque',
    'Portaria 2 — Av. das Quadras, 100', -23.5531, -46.6342
  );
  assert (v ->> 'latitude')::double precision = -23.5531,
    format('a quadra guarda o alfinete marcado: %s', v ->> 'latitude');
  assert (v ->> 'longitude')::double precision = -46.6342, 'e a longitude também';
  assert v ->> 'address' = 'Portaria 2 — Av. das Quadras, 100', 'com o endereço de referência';

  -- Mover o alfinete de uma quadra já cadastrada
  v := public.admin_upsert_court(
    (v ->> 'id')::uuid, p_latitude => -23.5540, p_longitude => -46.6350
  );
  assert (v ->> 'latitude')::double precision = -23.5540, 'o alfinete se move na edição';
  assert v ->> 'address' = 'Portaria 2 — Av. das Quadras, 100',
    'e mexer no alfinete não apaga o endereço';

  -- O painel enxerga o que foi criado
  v := public.admin_overview();
  assert (
    select count(*) from jsonb_array_elements(v -> 'parks') pk
    where pk ->> 'id' = v_park_id::text
  ) = 1, 'o parque novo aparece no painel';

  assert (
    select jsonb_array_length(pk -> 'courts')
    from jsonb_array_elements(v -> 'parks') pk
    where pk ->> 'id' = v_park_id::text
  ) = 3, 'com as três quadras';

  -- O formulário reabre preenchido porque o painel devolve o endereço
  assert (
    select pk ->> 'address'
    from jsonb_array_elements(v -> 'parks') pk
    where pk ->> 'id' = v_park_id::text
  ) = 'Av. das Quadras, 100', 'o painel devolve o endereço do parque';

  assert (
    select count(*)
    from jsonb_array_elements(v -> 'parks') pk,
         jsonb_array_elements(pk -> 'courts') c
    where pk ->> 'id' = v_park_id::text and c ->> 'address' is not null
  ) = 3, 'e o endereço de cada quadra';

  -- Endereço e tolerância de chamada convivem: as duas entregas
  -- mexeram nesta função ao mesmo tempo e a resolução do conflito
  -- perdeu uma delas.
  assert (
    select (c ->> 'call_window_seconds')::int
    from jsonb_array_elements(v -> 'parks') pk,
         jsonb_array_elements(pk -> 'courts') c
    where pk ->> 'id' = v_park_id::text and c ->> 'name' = 'Quadra do Bosque'
  ) = 120, 'e a tolerância de chamada de cada quadra';
end $$;

-- ---------------------------------------------------------------------
-- Endereço: dá para corrigir, inclusive para "nenhum"
--
-- O `coalesce(nullif(trim(...), ''), address)` antigo nunca limpava:
-- quem apagava o campo e salvava via o texto velho voltar.
-- ---------------------------------------------------------------------
do $$
declare v_park jsonb; v_pid uuid; v jsonb; v_cid uuid; v_code text;
begin
  v_park := public.admin_upsert_park(
    null, 'Parque do Endereço', null, 'São Paulo', 'Rua Velha, 1', -23.6, -46.7
  );
  v_pid := (v_park ->> 'id')::uuid;

  -- nulo não mexe
  v := public.admin_upsert_park(v_pid, p_district => 'Centro');
  assert v ->> 'address' = 'Rua Velha, 1', 'nulo mantém o endereço';

  -- texto substitui
  v := public.admin_upsert_park(v_pid, p_address => '  Rua Nova, 2  ');
  assert v ->> 'address' = 'Rua Nova, 2', format('texto substitui e apara: %s', v ->> 'address');

  -- vazio apaga
  v := public.admin_upsert_park(v_pid, p_address => '');
  assert v ->> 'address' is null, format('vazio deveria apagar, veio: %s', v ->> 'address');

  -- a quadra herda o do parque quando nada é informado...
  v := public.admin_upsert_park(v_pid, p_address => 'Portaria 1');
  v := public.admin_upsert_court(null, v_pid, null, 'clay', 'Q herdeira');
  v_cid := (v ->> 'id')::uuid;
  assert v ->> 'address' = 'Portaria 1', 'quadra nova herda o endereço do parque';

  -- ...e nasce sem nenhum quando o campo foi apagado de propósito
  v := public.admin_upsert_court(null, v_pid, null, 'clay', 'Q sem endereço', '');
  assert v ->> 'address' is null, 'campo apagado na criação nasce sem endereço';

  -- apagar o da quadra também funciona
  v := public.admin_upsert_court(v_cid, p_address => '');
  assert v ->> 'address' is null, 'dá para apagar o endereço da quadra';

  -- endereço grande demais é recusado pelo banco (a tela corta em 200)
  begin
    perform public.admin_upsert_court(v_cid, p_address => repeat('A', 201));
    assert false, 'endereço de 201 caracteres deveria ser recusado';
  exception when check_violation then null;
  end;

  -- alfinete é par: meia coordenada não entra
  begin
    perform public.admin_upsert_court(v_cid, p_latitude => -23.9);
    assert false, 'latitude sem longitude deveria ser recusada';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ024', format('esperava NQ024, obtive %s', v_code);
  end;

  begin
    perform public.admin_upsert_park(v_pid, p_longitude => -46.1);
    assert false, 'longitude sem latitude deveria ser recusada';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ024', format('esperava NQ024, obtive %s', v_code);
  end;

  -- e o par completo continua entrando
  v := public.admin_upsert_court(v_cid, p_latitude => -23.95, p_longitude => -46.75);
  assert (v ->> 'latitude')::double precision = -23.95, 'o par completo move o alfinete';
  assert (v ->> 'longitude')::double precision = -46.75, 'nos dois eixos';
end $$;

-- ---------------------------------------------------------------------
-- Uma assinatura de cada: duas versões conviventes travam tudo
--
-- Com todos os parâmetros opcionais, duas versões da mesma função
-- deixam qualquer chamada ambígua ("is not unique"). Foi o que
-- aconteceu quando dois ramos criaram cada um a sua `admin_upsert_court`
-- e o `drop` de um nomeava uma assinatura que o outro já havia
-- derrubado. É barato garantir que não volte.
-- ---------------------------------------------------------------------
do $$
declare v_name text; v_count int;
begin
  foreach v_name in array array['admin_upsert_court', 'admin_upsert_park', 'admin_overview']
  loop
    select count(*) into v_count
    from pg_proc
    where pronamespace = 'public'::regnamespace and proname = v_name;

    assert v_count = 1, format(
      '%s tem %s assinaturas vivas; deveria ter 1. Alguma migration criou uma '
      'versão nova sem derrubar a anterior pelo nome completo. Assinaturas: %s',
      v_name, v_count,
      (select string_agg(pg_get_function_identity_arguments(oid), ' | ')
         from pg_proc
        where pronamespace = 'public'::regnamespace and proname = v_name)
    );
  end loop;

  -- E a que sobrou é a completa
  assert (
    select pg_get_function_identity_arguments(oid) like '%p_address%'
       and pg_get_function_identity_arguments(oid) like '%p_call_window_seconds%'
    from pg_proc
    where pronamespace = 'public'::regnamespace and proname = 'admin_upsert_court'
  ), 'admin_upsert_court precisa de p_address e p_call_window_seconds juntos';
end $$;

-- ---------------------------------------------------------------------
-- Usuários e papéis
-- ---------------------------------------------------------------------
do $$
declare v jsonb; v_code text;
begin
  v := public.admin_users('jogador@teste.local');
  assert jsonb_array_length(v) = 1, format('busca por e-mail: %s', v);
  assert v -> 0 ->> 'role' = 'player', 'nasce como player';

  v := public.admin_set_role('a2000000-0000-0000-0000-00000000000b', 'staff');
  assert v ->> 'role' = 'staff', format('promoveu a staff: %s', v);

  -- A tela não cria um segundo admin
  begin
    perform public.admin_set_role('a3000000-0000-0000-0000-00000000000c', 'admin');
    assert false, 'admin pela tela deveria ser recusado';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ026', format('esperava NQ026, obtive %s', v_code);
  end;

  -- Nem o admin mexe no próprio papel
  begin
    perform public.admin_set_role('a1000000-0000-0000-0000-00000000000a', 'player');
    assert false, 'mudar o próprio papel deveria ser recusado';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ026', format('esperava NQ026, obtive %s', v_code);
  end;
end $$;

-- ---------------------------------------------------------------------
-- Ninguém se promove sozinho pelo RLS
-- ---------------------------------------------------------------------
set local "request.jwt.claim.sub" = 'a3000000-0000-0000-0000-00000000000c';

do $$
begin
  -- O WITH CHECK da política "profiles: dono atualiza" exige que o papel
  -- continue o mesmo, então a tentativa nem chega a gravar.
  begin
    update public.profiles set role = 'admin'::public.app_role
    where id = 'a3000000-0000-0000-0000-00000000000c';
    assert false, 'o RLS deveria bloquear a auto-promoção';
  exception when insufficient_privilege then
    null;
  end;
end $$;

-- E o papel continua o que era
do $$
begin
  assert (select role from public.profiles where id = 'a3000000-0000-0000-0000-00000000000c')
         = 'player'::public.app_role, 'continua player';
end $$;

rollback;

\echo '✔ tests/local/50_admin_test.sql — um único admin, cadastro de quadras e papéis'
