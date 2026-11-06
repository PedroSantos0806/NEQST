-- =====================================================================
-- Entrar no grupo de quem já está na fila, sem aprovação
--
-- E a pergunta que o Pedro fez junto: a fila é UMA por quadra, não
-- importa o caminho de entrada. Os dois caminhos existem —
--
--   . totem:  nome e sobrenome no aparelho da quadra
--   . QR/NFC: nome e sobrenome no celular, depois de escanear
--
-- — e aqui eles entram ALTERNADOS na mesma quadra, para o teste provar
-- a ordem única em vez de a gente afirmar.
--
-- Depois, o entrar no grupo: sem pedido, sem PIN, sem ninguém para
-- dizer sim. O que ainda é recusado tem motivo, e cada recusa tem um
-- caso aqui.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------
insert into public.parks (id, slug, name, district, latitude, longitude)
values ('88880000-0000-0000-0000-000000000008', 'teste-grupo-fila',
        'Parque do Grupo (teste)', 'Centro', -23.580000, -46.660000);

insert into public.courts (id, park_id, court_number, surface, slot_minutes, slug, name,
                           latitude, longitude, queue_mode)
values
  ('a8a80000-0000-0000-0000-0000000000a8', '88880000-0000-0000-0000-000000000008', 1, 'clay', 40,
   'teste-grupo-q1', 'Quadra 01', -23.580000, -46.660000, 'fixed_qr'),
  ('b8b80000-0000-0000-0000-0000000000b8', '88880000-0000-0000-0000-000000000008', 2, 'clay', 40,
   'teste-grupo-q2', 'Quadra 02', -23.580100, -46.660100, 'fixed_qr');

insert into public.court_devices (court_id, label, token_hash, last_seen_at)
values
  ('a8a80000-0000-0000-0000-0000000000a8', 'totem q1',
   public.hash_scan_token('grupo-totem-q1'), now()),
  ('b8b80000-0000-0000-0000-0000000000b8', 'totem q2',
   public.hash_scan_token('grupo-totem-q2'), now());

create or replace function pg_temp.q1() returns uuid language sql as $$
  select 'a8a80000-0000-0000-0000-0000000000a8'::uuid $$;
create or replace function pg_temp.q2() returns uuid language sql as $$
  select 'b8b80000-0000-0000-0000-0000000000b8'::uuid $$;

-- O token do totem de cada quadra, que é a credencial de quem está lá.
create or replace function pg_temp.totem_q1() returns text language sql as $$
  select 'grupo-totem-q1'::text $$;
create or replace function pg_temp.totem_q2() returns text language sql as $$
  select 'grupo-totem-q2'::text $$;

-- Um scan token sem conta, como o leitor de QR emite para quem não está
-- logado em nada.
create or replace function pg_temp.scan_sem_conta(p_court uuid, p_token text)
returns void language sql as $$
  insert into public.scan_tokens
    (token_hash, user_id, court_id, latitude, longitude, distance_meters, expires_at, method)
  select public.hash_scan_token(p_token), null, c.id, c.latitude, c.longitude, 8,
         now() + interval '30 seconds', 'qr'
  from public.courts c where c.id = p_court;
$$;

-- A fila por nome, na ordem da tela.
create or replace function pg_temp.fila(p_court uuid)
returns text language sql as $$
  select coalesce(string_agg(public.entry_label(qp.entry_id), ' | ' order by qp.position), '')
  from public.queue_positions qp where qp.court_id = p_court;
$$;

create or replace function pg_temp.vaga_de(p_court uuid, p_nome text)
returns uuid language sql as $$
  select e.id from public.queue_entries e
  join public.queue_party_members m on m.entry_id = e.id and m.left_at is null
  where e.court_id = p_court and btrim(m.name) = p_nome
    and e.status in ('waiting', 'ready', 'playing')
  order by e.queue_number desc
  limit 1;
$$;

-- =====================================================================
-- 1. A fila é UMA por quadra, qualquer que seja o caminho de entrada
-- =====================================================================
do $$
declare v jsonb; v_tela jsonb;
begin
  perform set_config('request.jwt.claim.sub', '', true);

  -- 1º pelo totem: a quadra estava vazia, então esta já entra jogando.
  v := public.totem_join(pg_temp.totem_q1(), 'Rafael Lima', 2);
  assert (v ->> 'playing')::boolean, format('quadra vazia: joga na hora: %s', v);

  -- 2º pelo QR, no celular.
  perform pg_temp.scan_sem_conta(pg_temp.q1(), 'qr-marina');
  v := public.scan_join_party('qr-marina', 'Marina Souza', 2);
  assert (v ->> 'party_token') is not null, 'o celular recebe o segredo dela';

  -- 3º pelo totem de novo.
  perform public.totem_join(pg_temp.totem_q1(), 'Zé do Ibira', 6);

  -- 4º pelo QR de novo.
  perform pg_temp.scan_sem_conta(pg_temp.q1(), 'qr-priscila');
  perform public.scan_join_party('qr-priscila', 'Priscila Alves', 4);

  -- Uma fila, na ordem de chegada, sem separar por caminho.
  assert pg_temp.fila(pg_temp.q1()) = 'Marina Souza | Zé do Ibira | Priscila Alves',
    format('uma fila só, na ordem de chegada: %s', pg_temp.fila(pg_temp.q1()));

  v_tela := public.totem_screen(pg_temp.totem_q1());
  assert (v_tela ->> 'queue_count')::int = 3, format('3 na fila: %s', v_tela ->> 'queue_count');
  assert v_tela -> 'playing' ->> 'name' = 'Rafael Lima', 'e o Rafael em quadra';
  -- A origem fica registrada, mas não muda o lugar de ninguém.
  assert v_tela -> 'queue' -> 0 ->> 'source' = 'qr', 'a 1ª veio do QR';
  assert v_tela -> 'queue' -> 1 ->> 'source' = 'totem', 'a 2ª veio do totem';
end $$;

-- =====================================================================
-- 2. Entrar no grupo pelo totem: toca no grupo, escreve o nome, entrou
-- =====================================================================
do $$
declare v jsonb; v_tela jsonb; v_entry uuid;
begin
  v_entry := pg_temp.vaga_de(pg_temp.q1(), 'Marina Souza');

  v := public.totem_join_group(pg_temp.totem_q1(), v_entry, 'Bruno Dias');

  assert (v ->> 'joined_group')::boolean, format('entrou no grupo: %s', v);
  assert (v ->> 'party_size')::int = 3, format('a party cresceu: %s', v ->> 'party_size');
  assert (v ->> 'party_token') is null, 'o totem não devolve segredo de ninguém';
  assert (v ->> 'entry_id') = v_entry::text, 'na vaga de quem já estava na fila';

  -- O nome que a quadra chama passa a ser os dois.
  assert public.entry_label(v_entry) = 'Marina Souza + Bruno Dias',
    format('rótulo: %s', public.entry_label(v_entry));

  v_tela := v -> 'screen';
  assert (v_tela ->> 'queue_count')::int = 3, 'ninguém virou linha nova na fila';
  assert v_tela -> 'queue' -> 0 ->> 'name' = 'Marina Souza + Bruno Dias',
    format('a linha da fila: %s', v_tela -> 'queue' -> 0);
  assert v_tela -> 'queue' -> 0 ->> 'label' = 'Grupo de 3, revezando',
    format('rótulo de 3: %s', v_tela -> 'queue' -> 0 ->> 'label');
  assert jsonb_array_length(v_tela -> 'queue' -> 0 -> 'members') = 2,
    'com os dois membros na tela';
end $$;

-- =====================================================================
-- 3. Entrar no grupo pelo celular: o QR mostra a fila antes de escolher
-- =====================================================================
do $$
declare v jsonb; v_tela jsonb; v_entry uuid; v_token text;
begin
  v_entry := pg_temp.vaga_de(pg_temp.q1(), 'Zé do Ibira');

  perform pg_temp.scan_sem_conta(pg_temp.q1(), 'qr-dudu');

  -- Ver a fila NÃO gasta o scan token: é o que deixa a pessoa escolher
  -- entre criar uma party e entrar num grupo.
  v_tela := public.scan_queue('qr-dudu');
  assert (v_tela ->> 'queue_count')::int = 3, format('a fila inteira: %s', v_tela ->> 'queue_count');
  assert (v_tela -> 'queue' -> 1 ->> 'can_join')::boolean,
    'e cada grupo diz se ainda cabe gente';

  v := public.scan_join_group('qr-dudu', v_entry, 'Dudu Alves');

  assert (v ->> 'joined_group')::boolean, format('entrou no grupo: %s', v);
  assert (v ->> 'party_size')::int = 7, format('6 do Zé mais o Dudu: %s', v ->> 'party_size');
  assert length(v ->> 'party_token') = 64, 'e o celular dele recebe o PRÓPRIO segredo';
  v_token := v ->> 'party_token';

  -- Com o segredo dele, ele vê a vaga do grupo e o próprio nome dentro.
  v_tela := public.party_screen(v_token);
  assert v_tela -> 'my_party' ->> 'my_name' = 'Dudu Alves',
    format('o nome dele: %s', v_tela -> 'my_party');
  assert v_tela -> 'my_party' ->> 'name' = 'Zé do Ibira + Dudu Alves',
    format('o grupo: %s', v_tela -> 'my_party' ->> 'name');
  assert (v_tela -> 'my_party' ->> 'in_group')::boolean, 'e ele sabe que está num grupo';
  assert (v_tela -> 'my_party' ->> 'position')::int = 2, 'na posição do grupo, não numa nova';

  -- O token já foi gasto: um scan, uma entrada.
  begin
    perform public.scan_join_group('qr-dudu', v_entry, 'Outro Nome');
    assert false, 'scan token já usado deveria ser recusado';
  exception when sqlstate 'NQ002' then null;
  end;
end $$;

-- =====================================================================
-- 4. Sair do grupo não derruba a vaga de quem ficou
--
-- É o cuidado que o "sem aprovação" exige: se qualquer um pode entrar
-- num grupo, sair não pode tirar os outros da fila.
-- =====================================================================
do $$
declare v_entry uuid; v_token text; v_tela jsonb;
begin
  -- Entra alguém novo com token conhecido para poder sair depois.
  v_entry := pg_temp.vaga_de(pg_temp.q1(), 'Marina Souza');
  perform pg_temp.scan_sem_conta(pg_temp.q1(), 'qr-carla');
  v_token := public.scan_join_group('qr-carla', v_entry, 'Carla Dias') ->> 'party_token';

  assert public.entry_size(v_entry) = 4, format('a party está em 4: %s', public.entry_size(v_entry));

  v_tela := public.party_leave(v_token);

  assert public.entry_size(v_entry) = 3, format('voltou para 3: %s', public.entry_size(v_entry));
  assert (select status from public.queue_entries where id = v_entry) in ('waiting', 'ready'),
    'e a vaga do grupo continua na fila';
  assert public.entry_label(v_entry) = 'Marina Souza + Bruno Dias',
    format('o rótulo volta a ser dos dois: %s', public.entry_label(v_entry));
  assert (v_tela ->> 'queue_count')::int = 3, 'a fila não mudou de tamanho';

  -- O segredo dela não vale mais.
  begin
    perform public.party_screen(v_token);
    assert false, 'quem saiu não enxerga mais a vaga';
  exception when sqlstate 'NQ007' then null;
  end;
end $$;

-- E quando sai o ÚLTIMO, a vaga sai da fila
do $$
declare v_entry uuid; v_token text;
begin
  perform pg_temp.scan_sem_conta(pg_temp.q2(), 'qr-sozinha');
  v_token := public.scan_join_party('qr-sozinha', 'Duda Única', 1) ->> 'party_token';
  v_entry := pg_temp.vaga_de(pg_temp.q2(), 'Duda Única');

  -- A q2 estava vazia: ela entrou jogando.
  assert (select status from public.queue_entries where id = v_entry) = 'playing',
    'a Duda está em quadra';

  perform public.party_leave(v_token);

  assert (select ended_at from public.matches where side_a_entry_id = v_entry) is not null,
    'saindo o último, o turno encerra';
  assert pg_temp.fila(pg_temp.q2()) = '', format('e a fila fica vazia: %s', pg_temp.fila(pg_temp.q2()));
end $$;

-- =====================================================================
-- 5. O que é recusado, e por quê
-- =====================================================================
do $$
declare v_code text; v_entry uuid; v_jogando uuid;
begin
  perform set_config('request.jwt.claim.sub', '', true);

  -- Grupo que já está em quadra: o turno está correndo e o placar já
  -- mostra o tamanho dele.
  v_jogando := pg_temp.vaga_de(pg_temp.q1(), 'Rafael Lima');
  begin
    perform public.totem_join_group(pg_temp.totem_q1(), v_jogando, 'Atrasado Silva');
    assert false, 'grupo em quadra deveria ser recusado';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ009', format('esperava NQ009, obtive %s', v_code);
  end;

  -- Nome de uma letra.
  v_entry := pg_temp.vaga_de(pg_temp.q1(), 'Marina Souza');
  begin
    perform public.totem_join_group(pg_temp.totem_q1(), v_entry, 'A');
    assert false, 'nome de 1 letra deveria ser recusado';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ041', format('esperava NQ041, obtive %s', v_code);
  end;

  -- O token do totem é de UMA quadra: com o da q2 não se escreve na q1.
  begin
    perform public.totem_join_group(pg_temp.totem_q2(), v_entry, 'Intruso Silva');
    assert false, 'o totem de outra quadra deveria ser recusado';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ007', format('esperava NQ007, obtive %s', v_code);
  end;
end $$;

-- Grupo cheio: o teto da party é 20, o mesmo da entrada
do $$
declare v_entry uuid; v_code text; v_i integer;
begin
  v_entry := pg_temp.vaga_de(pg_temp.q1(), 'Priscila Alves');
  -- A party da Priscila tem 4. Enche até 20.
  for v_i in 5..20 loop
    perform public.totem_join_group(pg_temp.totem_q1(), v_entry,
                                    'Pessoa ' || lpad(v_i::text, 2, '0'));
  end loop;

  assert public.entry_size(v_entry) = 20, format('cheia: %s', public.entry_size(v_entry));
  assert not (
    select (i ->> 'can_join')::boolean
    from jsonb_array_elements(public.totem_state(pg_temp.q1()) -> 'queue') i
    where i ->> 'entry_id' = v_entry::text
  ), 'e a tela para de oferecer o grupo';

  begin
    perform public.totem_join_group(pg_temp.totem_q1(), v_entry, 'Vigésima Primeira');
    assert false, 'a 21ª pessoa deveria ser recusada';
  exception when others then
    get stacked diagnostics v_code = returned_sqlstate;
    assert v_code = 'NQ042', format('esperava NQ042, obtive %s', v_code);
  end;
end $$;

-- =====================================================================
-- 6. "Voltar pra fila" leva o grupo inteiro, com os segredos
--
-- O grupo se monta NA FILA, que é onde dá: em quadra o turno já está
-- correndo. Então a quadra começa ocupada de propósito.
-- =====================================================================
do $$
declare
  v_entry uuid;
  v_token text;
  v_nova  uuid;
  v_tela  jsonb;
  v_ocupa uuid;
begin
  perform set_config('request.jwt.claim.sub', '', true);

  -- Alguém ocupa a q2, que ficou vazia no caso 4.
  perform public.totem_join(pg_temp.totem_q2(), 'Ocupante Silva', 2);
  v_ocupa := pg_temp.vaga_de(pg_temp.q2(), 'Ocupante Silva');

  -- A Ana entra na fila e a Bia entra no grupo dela, as duas esperando.
  perform pg_temp.scan_sem_conta(pg_temp.q2(), 'qr-ana-grupo');
  v_token := public.scan_join_party('qr-ana-grupo', 'Ana Prado', 2) ->> 'party_token';
  v_entry := pg_temp.vaga_de(pg_temp.q2(), 'Ana Prado');

  perform public.totem_join_group(pg_temp.totem_q2(), v_entry, 'Bia Prado');
  assert public.entry_label(v_entry) = 'Ana Prado + Bia Prado', 'as duas no rótulo';
  assert public.entry_size(v_entry) = 3, format('2 declaradas + a Bia: %s', public.entry_size(v_entry));

  -- Acaba o tempo de quem estava jogando: troca de 1:30, e no fim dela
  -- o grupo da Ana entra sozinho.
  update public.matches set expires_at = now() - interval '1 second'
   where court_id = pg_temp.q2() and ended_at is null;
  perform public.totem_screen(pg_temp.totem_q2());

  update public.courts set handover_until = now() - interval '1 second'
   where id = pg_temp.q2();
  v_tela := public.totem_screen(pg_temp.totem_q2());
  assert v_tela -> 'playing' ->> 'name' = 'Ana Prado + Bia Prado',
    format('o grupo entrou junto: %s', v_tela -> 'playing');
  assert jsonb_array_length(v_tela -> 'playing' -> 'members') = 2,
    'com os dois nomes em quadra';

  -- Agora acaba o tempo DELAS, e elas escolhem voltar.
  update public.matches set expires_at = now() - interval '1 second'
   where court_id = pg_temp.q2() and ended_at is null;
  v_tela := public.totem_screen(pg_temp.totem_q2());
  assert v_tela -> 'exit_ask' ->> 'name' = 'Ana Prado + Bia Prado',
    format('a pergunta é do grupo: %s', v_tela -> 'exit_ask');

  perform public.totem_exit_answer(pg_temp.totem_q2(), true);

  v_nova := pg_temp.vaga_de(pg_temp.q2(), 'Ana Prado');
  assert v_nova is distinct from v_entry, 'a vaga é nova';
  assert public.entry_label(v_nova) = 'Ana Prado + Bia Prado',
    format('e o grupo veio inteiro: %s', public.entry_label(v_nova));
  assert public.entry_size(v_nova) = 3, 'com o tamanho de antes';

  -- E o segredo da Ana continua valendo, agora apontando para a vaga nova.
  v_tela := public.party_screen(v_token);
  assert v_tela -> 'my_party' ->> 'entry_id' = v_nova::text,
    format('o segredo dela viajou com o grupo: %s', v_tela -> 'my_party');
  assert v_tela -> 'my_party' ->> 'my_name' = 'Ana Prado', 'e ainda é ela';
  assert (v_tela -> 'my_party' ->> 'in_group')::boolean, 'e segue em grupo';
end $$;

rollback;

\echo '✔ tests/local/81_grupo_na_fila_test.sql — fila única por quadra e entrar no grupo sem aprovação'
