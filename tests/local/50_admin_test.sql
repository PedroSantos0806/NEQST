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
    perform public.admin_upsert_park(null, 'Parque Pirata', null, null, -23.5, -46.6);
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
    null, 'Parque São João Acentuação', 'Centro', 'São Paulo', -23.55, -46.63, '#2F4629', 'quadra nova'
  );
  v_park_id := (v_park ->> 'id')::uuid;

  assert v_park ->> 'slug' = 'parque-sao-joao-acentuacao',
    format('slug sem acento: %s', v_park ->> 'slug');
  assert (v_park ->> 'is_active')::boolean, 'parque nasce ativo';

  -- Primeira quadra: número e nome automáticos
  v_court := public.admin_upsert_court(null, v_park_id);
  assert (v_court ->> 'court_number')::int = 1, format('primeira quadra é a 1: %s', v_court);
  assert v_court ->> 'name' = 'Quadra 01', format('nome automático: %s', v_court ->> 'name');
  assert v_court ->> 'surface' = 'clay', 'saibro por padrão';
  assert (v_court ->> 'latitude')::double precision = -23.55, 'herda a posição do parque';
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
  ) = 2, 'com as duas quadras';
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
