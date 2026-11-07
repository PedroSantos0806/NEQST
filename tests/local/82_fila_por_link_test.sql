-- =====================================================================
-- A fila é um link, e o QR só leva até ele
--
-- A decisão do Pedro depois de testar o totem no iPad: o QR não entra
-- na fila, ele leva à tela da quadra — e lá a pessoa entra do mesmo
-- jeito que entra no tablet, digitando nome e sobrenome.
--
-- Então o que este arquivo prova:
--
--   1. o link abre a fila da quadra pelo slug E pelo uuid;
--   2. entrar pelo link coloca na MESMA fila do totem, na ordem de
--      chegada, e devolve o segredo da pessoa (o totem não devolve);
--   3. entrar no grupo também funciona pelo link;
--   4. o link não opera a quadra: pausar, retomar e responder a
--      pergunta de saída continuam exigindo o token do aparelho;
--   5. as duas guardas que substituem o scan token de uso único — o
--      mesmo nome em sequência e o teto da fila;
--   6. o link de uma quadra não entra no grupo de outra.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------
insert into public.parks (id, slug, name, district, latitude, longitude)
values ('99990000-0000-0000-0000-000000000009', 'teste-link-fila',
        'Parque do Link (teste)', 'Centro', -23.570000, -46.650000);

insert into public.courts (id, park_id, court_number, surface, slot_minutes, slug, name,
                           latitude, longitude, queue_mode)
values
  ('c9c90000-0000-0000-0000-0000000000c9', '99990000-0000-0000-0000-000000000009', 1, 'clay', 40,
   'teste-link-q1', 'Quadra 01', -23.570000, -46.650000, 'fixed_qr'),
  ('d9d90000-0000-0000-0000-0000000000d9', '99990000-0000-0000-0000-000000000009', 2, 'clay', 40,
   'teste-link-q2', 'Quadra 02', -23.570100, -46.650100, 'fixed_qr');

insert into public.court_devices (court_id, label, token_hash, last_seen_at)
values ('c9c90000-0000-0000-0000-0000000000c9', 'totem q1',
        public.hash_scan_token('link-totem-q1'), now());

create or replace function pg_temp.q1() returns uuid language sql as $$
  select 'c9c90000-0000-0000-0000-0000000000c9'::uuid $$;
create or replace function pg_temp.q2() returns uuid language sql as $$
  select 'd9d90000-0000-0000-0000-0000000000d9'::uuid $$;
create or replace function pg_temp.totem_q1() returns text language sql as $$
  select 'link-totem-q1'::text $$;

/*
 * `jsonb -> 'chave'` de uma chave que existe com valor nulo devolve o
 * JSON `null`, que não é SQL NULL: `is null` dá falso e o teste passa
 * por engano (ou falha por engano, que foi o que aconteceu aqui).
 */
create or replace function pg_temp.vazio(p_value jsonb)
returns boolean language sql immutable as $$
  select p_value is null or jsonb_typeof(p_value) = 'null'
$$;

create or replace function pg_temp.fila(p_court uuid)
returns text language sql as $$
  select coalesce(string_agg(public.entry_label(qp.entry_id), ' | ' order by qp.position), '')
  from public.queue_positions qp where qp.court_id = p_court;
$$;

-- ---------------------------------------------------------------------
-- 1. O link abre a fila: pelo slug e pelo uuid
-- ---------------------------------------------------------------------
do $$
declare
  v_slug jsonb;
  v_uuid jsonb;
begin
  v_slug := public.queue_screen('teste-link-q1');
  v_uuid := public.queue_screen(pg_temp.q1()::text);

  assert v_slug -> 'court' ->> 'id' = pg_temp.q1()::text,
    format('o slug resolve a quadra: %s', v_slug -> 'court');
  assert v_uuid -> 'court' ->> 'id' = pg_temp.q1()::text,
    'o uuid também';
  assert v_slug ->> 'state' = 'free', format('quadra livre: %s', v_slug ->> 'state');
  assert v_slug -> 'court' ->> 'strip' is not null, 'com a faixa de identificação da tela';

  -- Link que não é quadra nenhuma não vira tela de nada.
  begin
    perform public.queue_screen('nao-existe-esta-quadra');
    raise exception 'devia ter recusado um link inexistente';
  exception when sqlstate 'NQ003' then null;
  end;

  begin
    perform public.queue_screen('   ');
    raise exception 'devia ter recusado um link vazio';
  exception when sqlstate 'NQ003' then null;
  end;
end $$;

-- ---------------------------------------------------------------------
-- 2. A mesma fila, na ordem de chegada, pelos dois caminhos
-- ---------------------------------------------------------------------
do $$
declare
  v_tela  jsonb;
  v_link  jsonb;
  v_totem jsonb;
begin
  -- Pelo link (quadra vazia): entra e já começa a jogar.
  v_link := public.queue_join('teste-link-q1', 'Marina Souza', 2);
  assert (v_link ->> 'playing')::boolean, 'a quadra estava livre, então ela joga';
  assert v_link ->> 'party_token' is not null and char_length(v_link ->> 'party_token') = 64,
    format('e ela sai com o próprio segredo: %s', v_link ->> 'party_token');
  assert v_link -> 'screen' ->> 'state' = 'playing',
    'a resposta já traz a tela nova, sem outra ida ao banco';
  assert v_link ->> 'court_id' = pg_temp.q1()::text, 'e diz de qual quadra é a vaga';

  -- Pelo totem, em seguida: mesma fila.
  v_totem := public.totem_join(pg_temp.totem_q1(), 'Zé do Ibira', 3);
  assert v_totem ->> 'party_token' is null,
    'o totem é tela compartilhada: não devolve segredo de ninguém';

  -- E pelo link outra vez, depois dele.
  perform public.queue_join(pg_temp.q1()::text, 'Priscila Alves', 4);

  assert pg_temp.fila(pg_temp.q1()) = 'Zé do Ibira | Priscila Alves',
    format('uma fila só, na ordem de chegada: %s', pg_temp.fila(pg_temp.q1()));

  -- A origem fica gravada, que é a única diferença entre os caminhos.
  assert (select e.source from public.queue_entries e
          where e.court_id = pg_temp.q1() and e.party_name = 'Marina Souza') = 'qr',
    'quem veio do link entra como qr';
  assert (select e.source from public.queue_entries e
          where e.court_id = pg_temp.q1() and e.party_name = 'Zé do Ibira') = 'totem',
    'quem veio do aparelho entra como totem';

  v_tela := public.queue_screen('teste-link-q1');
  assert (v_tela ->> 'queue_count')::int = 2, format('dois esperando: %s', v_tela ->> 'queue_count');
  assert v_tela -> 'playing' ->> 'name' = 'Marina Souza', 'e a Marina em quadra';
end $$;

-- ---------------------------------------------------------------------
-- 3. Entrar no grupo pelo link
-- ---------------------------------------------------------------------
do $$
declare
  v_entry uuid;
  v_join  jsonb;
begin
  select qp.entry_id into v_entry
  from public.queue_positions qp
  where qp.court_id = pg_temp.q1() and qp.position = 1;

  v_join := public.queue_join_group('teste-link-q1', v_entry, 'Bruno Dias');

  assert (v_join ->> 'joined_group')::boolean, 'entrou no grupo';
  assert v_join ->> 'party_name' = 'Zé do Ibira + Bruno Dias',
    format('e o rótulo cresceu: %s', v_join ->> 'party_name');
  assert v_join ->> 'party_token' is not null,
    'quem entra pelo celular fica com o próprio segredo';
  assert (v_join ->> 'party_size')::int = 4, 'o grupo era 3, agora é 4';

  -- Não furou fila: a posição do grupo é a mesma.
  assert (v_join ->> 'position')::int = 1, format('segue primeiro: %s', v_join ->> 'position');

  -- O grupo de OUTRA quadra não é acessível por este link.
  begin
    perform public.queue_join_group('teste-link-q2', v_entry, 'Intruso Silva');
    raise exception 'devia ter recusado um grupo de outra quadra';
  exception when sqlstate 'NQ007' then null;
  end;
end $$;

-- ---------------------------------------------------------------------
-- 4. O link lê e entra; operar a quadra segue sendo do aparelho
-- ---------------------------------------------------------------------
do $$
declare
  v_tipo text;
begin
  -- Nenhuma função de operação aceita um link de quadra: elas pedem o
  -- token do aparelho, e o link não é um.
  begin
    perform public.totem_pause('teste-link-q1', 'rega');
    raise exception 'o link não devia pausar a quadra';
  exception when sqlstate 'NQ037' then null;
  end;

  begin
    perform public.totem_resume(pg_temp.q1()::text);
    raise exception 'o link não devia retomar a quadra';
  exception when sqlstate 'NQ037' then null;
  end;

  begin
    perform public.totem_exit_answer('teste-link-q1', true);
    raise exception 'o link não devia responder pela saída de ninguém';
  exception when sqlstate 'NQ037' then null;
  end;

  -- E o aparelho continua podendo tudo. Com jogo em andamento, apertar
  -- uma pausa AGENDA: ela começa quando este jogo acabar, que é o que o
  -- handoff pede. O link vê o agendamento, só não pode criá-lo.
  select public.totem_pause(pg_temp.totem_q1(), 'rega') -> 'armed_pause' ->> 'kind' into v_tipo;
  assert v_tipo = 'rega', format('o totem agenda a pausa: %s', v_tipo);
  assert public.queue_screen('teste-link-q1') -> 'armed_pause' ->> 'kind' = 'rega',
    'e o link vê o agendamento na tela';

  -- Toque de novo cancela, e o link acompanha isso também.
  perform public.totem_pause(pg_temp.totem_q1(), 'rega');
  assert pg_temp.vazio(public.queue_screen('teste-link-q1') -> 'armed_pause'),
    'cancelou — o link vê o resultado, só não comanda';
end $$;

-- ---------------------------------------------------------------------
-- 5. As guardas que o scan token de uso único dispensava
-- ---------------------------------------------------------------------
do $$
declare
  v_i integer;
begin
  -- O mesmo nome em sequência é o toque duplo, o refresh, a conexão que
  -- caiu depois de gravar. Recusado.
  begin
    perform public.queue_join('teste-link-q1', 'Priscila Alves', 2);
    raise exception 'devia ter recusado o nome repetido';
  exception when sqlstate 'NQ004' then null;
  end;

  -- Com espaço a mais e outra caixa, é o mesmo nome.
  begin
    perform public.queue_join('teste-link-q1', '  priscila alves  ', 2);
    raise exception 'devia ter recusado o mesmo nome com outra caixa';
  exception when sqlstate 'NQ004' then null;
  end;

  -- Passada a janela de 3 minutos, ela pode entrar de novo: pode ser
  -- outra Priscila, ou a mesma voltando depois de jogar.
  update public.queue_entries set joined_at = now() - interval '5 minutes'
   where court_id = pg_temp.q1() and party_name = 'Priscila Alves';
  perform public.queue_join('teste-link-q1', 'Priscila Alves', 2);

  -- O teto da fila: 50 parties esperando. Enche e confere a recusa.
  insert into public.queue_entries (court_id, mode, status, party_name, party_size, source, joined_at)
  select pg_temp.q1(), 'double', 'waiting', 'Enchendo ' || g, 2, 'qr',
         now() - interval '1 hour' + (g || ' seconds')::interval
  from generate_series(1, 60) g
  where (select count(*) from public.queue_entries e
         where e.court_id = pg_temp.q1() and e.status in ('waiting', 'ready')) + g <= 50;

  select count(*) into v_i from public.queue_entries e
   where e.court_id = pg_temp.q1() and e.status in ('waiting', 'ready');
  assert v_i = 50, format('a fila está no teto: %s', v_i);

  begin
    perform public.queue_join('teste-link-q1', 'Último da Fila', 2);
    raise exception 'devia ter recusado: a fila está cheia';
  exception when sqlstate 'NQ043' then null;
  end;

  -- E o totem cai na mesma guarda: o teto é da quadra, não do caminho.
  begin
    perform public.totem_join(pg_temp.totem_q1(), 'Outro Qualquer', 2);
    raise exception 'o teto vale para o totem também';
  exception when sqlstate 'NQ043' then null;
  end;
end $$;

-- ---------------------------------------------------------------------
-- 6. Quadra desligada não aceita ninguém, por link nenhum
-- ---------------------------------------------------------------------
do $$
begin
  update public.courts set is_active = false where id = pg_temp.q2();

  begin
    perform public.queue_join('teste-link-q2', 'Alguém Qualquer', 2);
    raise exception 'devia ter recusado: a quadra está desligada';
  exception when sqlstate 'NQ003' then null;
  end;

  -- Mas a tela continua abrindo: quem chegou tem direito de saber por
  -- que não dá para entrar.
  assert public.queue_screen('teste-link-q2') -> 'court' ->> 'id' = pg_temp.q2()::text,
    'a tela da quadra desligada ainda abre';
end $$;

rollback;

\echo '✔ tests/local/82_fila_por_link_test.sql — a fila pelo link da quadra, e o que o link não faz'
