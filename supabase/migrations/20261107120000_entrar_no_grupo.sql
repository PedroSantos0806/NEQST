-- ---------------------------------------------------------------------
-- Entrar no grupo de quem já está na fila, sem aprovação
--
-- Pedido do Pedro (06/11), em cima do totem:
--
--   "Poderá entrar em um grupo (igual já fazemos hoje de ter equipe)
--    mas sem a parte de aprovação de uma pessoa, ele apenas clica no
--    grupo (pelo celular ou direto no tablet) e entra."
--
-- O que isto muda no modelo: até agora uma party era UMA linha com um
-- nome e um número. Para alguém entrar num grupo e a quadra continuar
-- chamando pelo nome certo, a party passa a ter MEMBROS — um nome por
-- pessoa.
--
-- E o segredo do navegador deixa de ser da vaga e passa a ser da
-- PESSOA: quem entra num grupo recebe o seu, e com ele vê a posição e
-- sai sozinho, sem poder derrubar a vaga de quem o convidou. No totem
-- não há segredo nenhum: a tela é compartilhada e quem responde pelo
-- grupo é quem está ali.
--
-- A fila continua sendo UMA por quadra, qualquer que seja o caminho de
-- entrada — `queue_positions` ordena por `queue_number` particionado
-- por `court_id`, e os dois caminhos chamam a mesma `join_party`. O
-- teste 81 prova isso em vez de a gente afirmar.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- 1. Os membros da party
-- ---------------------------------------------------------------------
create table if not exists public.queue_party_members (
  id         uuid primary key default gen_random_uuid(),
  entry_id   uuid not null references public.queue_entries (id) on delete cascade,
  name       text not null,
  -- Nulo quando a pessoa entrou pelo totem: lá não há navegador a
  -- lembrar de ninguém.
  token_hash text,
  source     text not null default 'totem',
  joined_at  timestamptz not null default clock_timestamp(),
  left_at    timestamptz,

  constraint queue_party_members_name_len
    check (char_length(btrim(name)) between 2 and 40),
  constraint queue_party_members_source_check
    check (source in ('totem', 'qr', 'nfc', 'app'))
);

-- Um segredo vale para uma pessoa ativa. Quem sai devolve o dele, e é
-- isso que deixa a mesma pessoa voltar para a fila com o token novo.
create unique index if not exists queue_party_members_token_idx
  on public.queue_party_members (token_hash)
  where token_hash is not null and left_at is null;

create index if not exists queue_party_members_entry_idx
  on public.queue_party_members (entry_id)
  where left_at is null;

comment on table public.queue_party_members is
  'Quem está em cada party da fila, um nome por pessoa. É daqui que sai o nome '
  'que a quadra chama: "Rafael + Marina", e não só o nome de quem digitou primeiro.';
comment on column public.queue_party_members.token_hash is
  'O segredo do navegador DESTA pessoa, em hash. Com ele ela vê a posição e sai '
  'da fila — e não derruba a vaga de quem a deixou entrar no grupo.';

alter table public.queue_party_members enable row level security;
revoke all on public.queue_party_members from anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. As parties que já existem viram parties com um membro
--
-- O segredo que estava na vaga passa a ser da pessoa que o tem no
-- navegador. Depois disso a coluna da vaga sai: duas fontes de verdade
-- para a mesma coisa é como se perde uma.
-- ---------------------------------------------------------------------
insert into public.queue_party_members (entry_id, name, token_hash, source, joined_at)
select e.id, btrim(e.party_name), e.party_token_hash,
       coalesce(e.source, 'totem'), e.first_joined_at
from public.queue_entries e
where e.party_name is not null
  and not exists (
    select 1 from public.queue_party_members m where m.entry_id = e.id
  );

drop index if exists public.queue_entries_party_token_idx;
alter table public.queue_entries drop column if exists party_token_hash;

-- ---------------------------------------------------------------------
-- 3. O nome que a quadra chama
--
-- Um membro: o nome dele. Dois: "Rafael + Marina" — é o que o mock
-- desenha e o que cabe numa linha. Mais que dois: "Rafael + Marina + 2",
-- porque a linha da fila é uma linha, e o totem é lido a cinco metros.
-- ---------------------------------------------------------------------
create or replace function public.party_members(p_entry_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(jsonb_build_object('id', m.id, 'name', btrim(m.name), 'source', m.source)
              order by m.joined_at, m.id),
    '[]'::jsonb)
  from public.queue_party_members m
  where m.entry_id = p_entry_id and m.left_at is null;
$$;

create or replace function public.entry_label(p_entry_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_names    text[];
  v_total    integer;
  v_fallback text;
begin
  select array_agg(btrim(m.name) order by m.joined_at, m.id)
  into v_names
  from public.queue_party_members m
  where m.entry_id = p_entry_id and m.left_at is null;

  v_total := coalesce(array_length(v_names, 1), 0);

  if v_total = 1 then
    return v_names[1];
  elsif v_total = 2 then
    return v_names[1] || ' + ' || v_names[2];
  elsif v_total > 2 then
    return v_names[1] || ' + ' || v_names[2] || ' + ' || (v_total - 2);
  end if;

  -- Sem membros: o nome digitado antes de existirem membros, a vaga sem
  -- app, ou a vaga com conta.
  select btrim(e.party_name) into v_fallback
  from public.queue_entries e
  where e.id = p_entry_id and e.party_name is not null;
  if v_fallback is not null then
    return v_fallback;
  end if;

  -- Vaga sem app pode não ter rótulo: o anfitrião marcou "tem gente aí"
  -- sem dizer quem. "Quadra livre" no lugar disso seria mentira na tela.
  select case when e.is_offline then coalesce(e.offline_label, 'Grupo sem app') end
  into v_fallback
  from public.queue_entries e where e.id = p_entry_id;
  if v_fallback is not null then
    return v_fallback;
  end if;

  -- Vaga com conta: a MESMA regra dos nomes — dois e o resto em número —
  -- porque a linha da fila é a mesma linha.
  select array_agg(pl ->> 'short_name' order by ord)
  into v_names
  from jsonb_array_elements(public.match_side_players(p_entry_id))
       with ordinality as t(pl, ord);

  v_total := coalesce(array_length(v_names, 1), 0);

  if v_total = 1 then
    return v_names[1];
  elsif v_total = 2 then
    return v_names[1] || ' + ' || v_names[2];
  elsif v_total > 2 then
    return v_names[1] || ' + ' || v_names[2] || ' + ' || (v_total - 2);
  end if;

  return 'Quadra livre';
end;
$$;

revoke all on function public.party_members(uuid) from public, anon, authenticated;
revoke all on function public.entry_label(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Entrar na fila cria a party com o primeiro membro
-- ---------------------------------------------------------------------
create or replace function public.join_party(
  p_court_id      uuid,
  p_name          text,
  p_size          integer,
  p_source        text default 'totem',
  p_scan_token_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court public.courts%rowtype;
  v_name  text := nullif(btrim(coalesce(p_name, '')), '');
  v_size  integer := coalesce(p_size, 2);
  v_token text;
  v_entry uuid;
  v_free  boolean;
  v_pos   integer;
begin
  if v_name is null or char_length(v_name) < 2 or char_length(v_name) > 40 then
    raise exception 'Escreva o nome com 2 a 40 letras' using errcode = 'NQ041';
  end if;
  if v_size < 1 or v_size > 20 then
    raise exception 'A party vai de 1 a 20 pessoas' using errcode = 'NQ042';
  end if;
  if p_source is null or p_source not in ('totem', 'qr', 'nfc', 'app') then
    raise exception 'Origem inválida' using errcode = 'NQ024';
  end if;

  select * into v_court from public.courts c where c.id = p_court_id for update;
  if not found then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;
  if not v_court.is_active or v_court.status = 'unavailable' then
    raise exception 'Esta quadra está indisponível no momento' using errcode = 'NQ003';
  end if;

  -- O totem não guarda segredo de ninguém: a tela é compartilhada, e
  -- quem responde pelo grupo é quem está na quadra.
  v_token := case when p_source = 'totem' then null
                  else encode(extensions.gen_random_bytes(32), 'hex') end;

  insert into public.queue_entries
    (court_id, mode, status, created_by, scan_token_id,
     party_name, party_size, source)
  values
    (p_court_id,
     case when v_size <= 1 then 'single'::public.queue_mode
          else 'double'::public.queue_mode end,
     'waiting', null, p_scan_token_id,
     v_name, v_size, p_source)
  returning id into v_entry;

  insert into public.queue_party_members (entry_id, name, token_hash, source)
  values (v_entry, v_name,
          case when v_token is null then null
               else public.hash_scan_token(v_token) end,
          p_source);

  if p_scan_token_id is not null then
    update public.scan_tokens
       set consumed_at = now(), consumed_by_entry = v_entry
     where id = p_scan_token_id;
  end if;

  -- Quadra livre → Em jogo: quem entra numa quadra vazia começa a jogar.
  v_free := v_court.pause_kind is null
            and v_court.handover_phase is null
            and not exists (select 1 from public.matches mt
                            where mt.court_id = p_court_id and mt.ended_at is null);

  if v_free then
    perform public.open_match(v_entry);
  end if;

  select qp.position into v_pos
  from public.queue_positions qp
  where qp.court_id = p_court_id and qp.entry_id = v_entry;

  return jsonb_build_object(
    'entry_id',    v_entry,
    'party_name',  v_name,
    'party_size',  v_size,
    'position',    v_pos,
    'playing',     v_free,
    'joined_group', false,
    -- Única vez que este valor existe fora do navegador de quem entrou.
    'party_token', v_token
  );
end;
$$;

revoke all on function public.join_party(uuid, text, integer, text, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. Entrar no grupo de quem já está na fila
--
-- Sem aprovação: toca no grupo, escreve o nome, está dentro. Não existe
-- pedido, não existe PIN, não existe alguém para dizer sim — era isso o
-- pedido, e é o que faz a diferença numa quadra onde todo mundo está de
-- pé esperando.
--
-- O que ainda é recusado, e por quê:
--
--   . grupo que já está em quadra: o turno está correndo e o placar já
--     mostra o tamanho dele. Quem chegou atrasado entra na próxima;
--   . grupo que já tem 20: é o teto da party, o mesmo da entrada;
--   . vaga que saiu da fila: não há grupo onde entrar.
-- ---------------------------------------------------------------------
create or replace function public.join_group(
  p_entry_id uuid,
  p_name     text,
  p_source   text default 'totem'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry public.queue_entries%rowtype;
  v_name  text := nullif(btrim(coalesce(p_name, '')), '');
  v_token text;
  v_size  integer;
  v_pos   integer;
begin
  if v_name is null or char_length(v_name) < 2 or char_length(v_name) > 40 then
    raise exception 'Escreva o nome com 2 a 40 letras' using errcode = 'NQ041';
  end if;
  if p_source is null or p_source not in ('totem', 'qr', 'nfc', 'app') then
    raise exception 'Origem inválida' using errcode = 'NQ024';
  end if;

  select * into v_entry
  from public.queue_entries e where e.id = p_entry_id for update;

  if not found then
    raise exception 'Grupo não encontrado' using errcode = 'NQ007';
  end if;
  if v_entry.status = 'playing' then
    raise exception 'Este grupo já está em quadra. Entre na fila para a próxima.'
      using errcode = 'NQ009';
  end if;
  if v_entry.status not in ('waiting', 'ready') then
    raise exception 'Este grupo não está mais na fila' using errcode = 'NQ009';
  end if;

  v_size := public.entry_size(p_entry_id) + 1;
  if v_size > 20 then
    raise exception 'Este grupo já está com 20 pessoas' using errcode = 'NQ042';
  end if;

  v_token := case when p_source = 'totem' then null
                  else encode(extensions.gen_random_bytes(32), 'hex') end;

  insert into public.queue_party_members (entry_id, name, token_hash, source)
  values (p_entry_id, v_name,
          case when v_token is null then null
               else public.hash_scan_token(v_token) end,
          p_source);

  -- O tamanho da party é quantas pessoas vão jogar, e agora é uma mais.
  update public.queue_entries
     set party_size = v_size,
         mode = case when v_size <= 1 then 'single'::public.queue_mode
                     else 'double'::public.queue_mode end
   where id = p_entry_id;

  select qp.position into v_pos
  from public.queue_positions qp
  where qp.court_id = v_entry.court_id and qp.entry_id = p_entry_id;

  return jsonb_build_object(
    'entry_id',     p_entry_id,
    'party_name',   public.entry_label(p_entry_id),
    'party_size',   v_size,
    'position',     v_pos,
    'playing',      false,
    'joined_group', true,
    'party_token',  v_token
  );
end;
$$;

revoke all on function public.join_group(uuid, text, text) from public, anon, authenticated;

comment on function public.join_group(uuid, text, text) is
  'Entra no grupo de quem já está na fila, sem aprovação de ninguém. '
  'Recusa grupo em quadra, grupo cheio e vaga que já saiu da fila.';

-- ---------------------------------------------------------------------
-- 6. O segredo agora é da pessoa, não da vaga
-- ---------------------------------------------------------------------
create or replace function public.take_party_member(p_party_token text)
returns public.queue_party_members
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member public.queue_party_members%rowtype;
begin
  select * into v_member
  from public.queue_party_members m
  where m.token_hash = public.hash_scan_token(coalesce(p_party_token, ''))
    and m.left_at is null
  limit 1;

  if not found then
    raise exception 'Não encontramos a sua vaga na fila' using errcode = 'NQ007';
  end if;

  return v_member;
end;
$$;

create or replace function public.take_party_entry(p_party_token text)
returns public.queue_entries
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member public.queue_party_members%rowtype;
  v_entry  public.queue_entries%rowtype;
begin
  v_member := public.take_party_member(p_party_token);

  select * into v_entry from public.queue_entries e where e.id = v_member.entry_id;
  if not found then
    raise exception 'Não encontramos a sua vaga na fila' using errcode = 'NQ007';
  end if;

  return v_entry;
end;
$$;

revoke all on function public.take_party_member(text) from public, anon, authenticated;
revoke all on function public.take_party_entry(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 7. Sair é sair: de um grupo, ou da fila
--
-- Com grupo, "sair" deixou de ter um só significado. Quem sai de um
-- grupo de quatro não tira os outros três da fila — isso seria uma
-- pessoa derrubando a vaga alheia por tocar no botão errado. A vaga só
-- sai da fila quando o último membro sai dela.
-- ---------------------------------------------------------------------
create or replace function public.party_leave(p_party_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member public.queue_party_members%rowtype;
  v_entry  public.queue_entries%rowtype;
  v_match  uuid;
  v_court  uuid;
  v_left   integer;
begin
  v_member := public.take_party_member(p_party_token);

  select * into v_entry from public.queue_entries e where e.id = v_member.entry_id for update;
  v_court := v_entry.court_id;

  update public.queue_party_members
     set left_at = now(), token_hash = null
   where id = v_member.id;

  select count(*)::integer into v_left
  from public.queue_party_members m
  where m.entry_id = v_entry.id and m.left_at is null;

  if v_left > 0 then
    -- Sobrou gente no grupo: a vaga fica, com uma pessoa menos.
    update public.queue_entries
       set party_size = greatest(1, coalesce(party_size, v_left + 1) - 1)
     where id = v_entry.id;

    return public.totem_state(v_court);
  end if;

  -- Era o último: aí sim a vaga sai da fila.
  if v_entry.status = 'playing' then
    select mt.id into v_match
    from public.matches mt
    where mt.court_id = v_court and mt.ended_at is null
      and mt.side_a_entry_id = v_entry.id;

    if v_match is not null then
      perform public.close_match(v_match, null, 'abandoned');
    end if;

  elsif v_entry.status in ('waiting', 'ready') then
    update public.queue_entries
       set status = 'cancelled', cancel_reason = 'left_by_party', left_at = now()
     where id = v_entry.id;

    -- Saiu quem estava entrando: a troca recomeça com quem ficou.
    if exists (select 1 from public.courts c
               where c.id = v_court and c.handover_entry_id = v_entry.id) then
      perform public.start_handover(v_court);
    end if;
  end if;

  return public.totem_state(v_court);
end;
$$;

revoke all on function public.party_leave(text) from public, anon, authenticated;
grant execute on function public.party_leave(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 8. Voltar para a fila leva o grupo inteiro
--
-- Os membros viajam com a vaga nova, e com os segredos deles: quem
-- estava acompanhando pelo celular continua acompanhando. Os da vaga
-- velha são marcados como saídos ANTES, senão o índice único dos
-- segredos recusaria a volta — foi o defeito que o teste pegou na
-- Sprint 8, agora uma camada acima.
-- ---------------------------------------------------------------------
create or replace function public.requeue_entry(
  p_entry_id uuid,
  p_played   boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old    public.queue_entries%rowtype;
  v_new    uuid;
  v_member record;
begin
  select * into v_old from public.queue_entries e where e.id = p_entry_id;
  if not found then
    return null;
  end if;

  insert into public.queue_entries
    (court_id, mode, status, created_by, scan_token_id,
     is_offline, offline_label, offline_kind, host_session_id,
     first_joined_at, requeued_from, turn_number,
     party_name, party_size, source)
  values
    (v_old.court_id, v_old.mode, 'waiting', v_old.created_by, null,
     v_old.is_offline, v_old.offline_label, v_old.offline_kind, v_old.host_session_id,
     v_old.first_joined_at, v_old.id,
     case when p_played then v_old.turn_number + 1 else v_old.turn_number end,
     v_old.party_name, v_old.party_size, v_old.source)
  returning id into v_new;

  -- Um membro por vez, e nesta ordem: o antigo devolve o segredo, e só
  -- então o novo nasce com ele. Ao contrário, os dois estariam ativos
  -- com o mesmo token e o índice único recusaria a volta para a fila.
  --
  -- Em bloco não dá: no Postgres 16 o RETURNING de um UPDATE devolve o
  -- valor NOVO, e o valor novo do token é nulo — justamente o que
  -- precisamos carregar.
  for v_member in
    select m.id, m.name, m.token_hash, m.source, m.joined_at
    from public.queue_party_members m
    where m.entry_id = p_entry_id and m.left_at is null
    order by m.joined_at, m.id
  loop
    update public.queue_party_members
       set left_at = now(), token_hash = null
     where id = v_member.id;

    insert into public.queue_party_members (entry_id, name, token_hash, source, joined_at)
    values (v_new, v_member.name, v_member.token_hash, v_member.source, v_member.joined_at);
  end loop;

  insert into public.queue_entry_members
    (entry_id, court_id, user_id, role, origin, invite_id, joined_via, checked_in_at)
  select v_new, m.court_id, m.user_id, m.role,
         coalesce(m.origin, 'requeued'), m.invite_id, m.joined_via, m.checked_in_at
  from public.queue_entry_members m
  where m.entry_id = p_entry_id and m.left_at is null;

  insert into public.queue_entry_pins (entry_id, pin)
  select v_new,
         case
           when exists (
             select 1
             from public.queue_entry_pins p2
             join public.queue_entries e2 on e2.id = p2.entry_id
             where e2.court_id = v_old.court_id
               and e2.status in ('waiting', 'ready', 'playing')
               and e2.id <> v_new
               and p2.pin = p.pin
           ) then public.new_group_pin(v_old.court_id)
           else p.pin
         end
  from public.queue_entry_pins p
  where p.entry_id = p_entry_id;

  return v_new;
end;
$$;

revoke all on function public.requeue_entry(uuid, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 9. As telas: cada linha da fila mostra quem é o grupo
-- ---------------------------------------------------------------------
create or replace function public.totem_state(p_court_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_court    public.courts%rowtype;
  v_park     public.parks%rowtype;
  v_match    public.matches%rowtype;
  v_state    text;
  v_rem      integer := 0;
  v_gap      integer := 0;
  v_base     integer;
  v_per_turn integer;
  v_queue    jsonb;
  v_count    integer;
  v_playing  jsonb;
  v_next     jsonb;
  v_exit     jsonb;
  v_pause    jsonb;
  v_next_id  uuid;
begin
  select * into v_court from public.courts c where c.id = p_court_id;
  if not found then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;

  select * into v_park from public.parks pk where pk.id = v_court.park_id;

  select * into v_match
  from public.matches mt
  where mt.court_id = p_court_id and mt.ended_at is null
  limit 1;

  if v_match.id is not null then
    v_rem := greatest(0, floor(extract(epoch from (v_match.expires_at - now())))::integer);
  end if;

  if v_court.handover_until is not null and v_court.handover_until > now() then
    v_gap := greatest(0, ceil(extract(epoch from (v_court.handover_until - now())))::integer);
  end if;

  v_state := case
               when v_court.pause_kind is not null then 'paused'
               when v_match.id is not null and v_rem <= v_court.warn_seconds then 'ending'
               when v_match.id is not null then 'playing'
               when v_court.handover_phase = 'changeover' and v_gap > 0 then 'changeover'
               else 'free'
             end;

  if v_match.id is not null then
    v_playing := jsonb_build_object(
      'entry_id', v_match.side_a_entry_id,
      'name',     public.entry_label(v_match.side_a_entry_id),
      'size',     public.entry_size(v_match.side_a_entry_id),
      'label',    public.party_label(public.entry_size(v_match.side_a_entry_id)),
      'members',  public.party_members(v_match.side_a_entry_id)
    );
  end if;

  select qp.entry_id into v_next_id
  from public.queue_positions qp
  where qp.court_id = p_court_id
  order by qp.position
  limit 1;

  if v_next_id is not null then
    v_next := jsonb_build_object(
      'entry_id', v_next_id,
      'name',     public.entry_label(v_next_id),
      'size',     public.entry_size(v_next_id),
      'label',    public.party_label(public.entry_size(v_next_id)),
      'members',  public.party_members(v_next_id)
    );
  end if;

  -- A faixa vale na troca, na pausa que a interrompeu, e também com a
  -- quadra livre: sem fila atrás a pergunta continua sendo a mesma, e
  -- "voltar pra fila" com a quadra vazia é entrar de novo na hora.
  if v_court.exit_ask_entry_id is not null
     and v_state in ('changeover', 'paused', 'free') then
    v_exit := jsonb_build_object(
      'entry_id', v_court.exit_ask_entry_id,
      'name',     public.entry_label(v_court.exit_ask_entry_id),
      'text',     public.entry_label(v_court.exit_ask_entry_id)
                  || ', acabou seu tempo. Quer sair ou voltar pro fim da fila?'
    );
  end if;

  if v_court.pause_kind is not null then
    v_pause := jsonb_build_object(
      'kind',    v_court.pause_kind,
      'label',   case v_court.pause_kind
                   when 'vassourao' then 'Vassourão'
                   when 'rega'      then 'Rega da quadra'
                   else 'Exceção'
                 end,
      'desc',    case v_court.pause_kind
                   when 'vassourao' then 'Estão passando o vassourão no saibro.'
                   when 'rega'      then 'Estão regando a quadra.'
                   else 'Parada autorizada pelo parque.'
                 end,
      'since',   v_court.paused_at,
      'seconds', greatest(0, floor(extract(epoch from (now() - v_court.paused_at)))::integer)
    );
  end if;

  v_per_turn := v_court.slot_minutes * 60 + v_court.changeover_seconds;

  v_base := case
              when v_court.pause_kind is not null then null
              when v_court.armed_pause_kind is not null then null
              when v_match.id is not null then v_rem + v_court.changeover_seconds
              when v_state = 'changeover' then v_gap
              else 0
            end;

  select coalesce(jsonb_agg(item order by position), '[]'::jsonb), count(*)
  into v_queue, v_count
  from (
    select qp.position,
           jsonb_build_object(
             'entry_id',    qp.entry_id,
             'position',    qp.position,
             'name',        public.entry_label(qp.entry_id),
             'size',        public.entry_size(qp.entry_id),
             'label',       public.party_label(public.entry_size(qp.entry_id)),
             'members',     public.party_members(qp.entry_id),
             'is_next',     qp.position = 1,
             'source',      e.source,
             'joined_at',   e.first_joined_at,
             -- Entrar no grupo é sem aprovação, então a tela só precisa
             -- saber se CABE mais gente: o teto da party é 20.
             'can_join',    public.entry_size(qp.entry_id) < 20,
             'eta_seconds', case when v_base is null then null
                                 else v_base + (qp.position - 1) * v_per_turn end,
             'eta_at',      case when v_base is null then null
                                 else now() + make_interval(
                                        secs => v_base + (qp.position - 1) * v_per_turn) end
           ) as item
    from public.queue_positions qp
    join public.queue_entries e on e.id = qp.entry_id
    where qp.court_id = p_court_id
  ) s;

  return jsonb_build_object(
    'court', jsonb_build_object(
      'id',      v_court.id,
      'name',    public.court_label(v_court.court_number),
      'number',  v_court.court_number,
      'surface_label', case v_court.surface
                         when 'clay' then 'Saibro'
                         when 'hard' then 'Rápida'
                         else 'Grama'
                       end,
      'park',    v_park.name,
      'strip',   concat_ws(' · ',
                   public.court_label(v_court.court_number),
                   case v_court.surface
                     when 'clay' then 'Saibro'
                     when 'hard' then 'Rápida'
                     else 'Grama'
                   end,
                   v_park.name),
      'is_active', v_court.is_active,
      'status',    v_court.status
    ),
    'state',            v_state,
    'slot_seconds',     v_court.slot_minutes * 60,
    'slot_minutes',     v_court.slot_minutes,
    'changeover_seconds', v_court.changeover_seconds,
    'warn_seconds',     v_court.warn_seconds,
    'remaining_seconds', v_rem,
    'changeover_left',  v_gap,
    'elapsed_seconds',  case when v_match.id is null then 0
                             else greatest(0, v_court.slot_minutes * 60 - v_rem) end,
    'playing',          v_playing,
    'next',             v_next,
    'exit_ask',         v_exit,
    'pause',            v_pause,
    'armed_pause',      case when v_court.armed_pause_kind is null then null
                             else jsonb_build_object(
                                    'kind', v_court.armed_pause_kind,
                                    'label', case v_court.armed_pause_kind
                                               when 'vassourao' then 'Vassourão'
                                               when 'rega'      then 'Rega da quadra'
                                               else 'Exceção'
                                             end)
                        end,
    'can_continue',     v_match.id is not null
                        and v_rem <= v_court.warn_seconds
                        and v_count = 0,
    'queue',            v_queue,
    'queue_count',      v_count,
    'turn_seconds',     v_per_turn,
    'generated_at',     now()
  );
end;
$$;

revoke all on function public.totem_state(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 10. Entrar no grupo pelo totem e pelo celular
-- ---------------------------------------------------------------------
create or replace function public.totem_join_group(
  p_token    text,
  p_entry_id uuid,
  p_name     text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court uuid := public.totem_court(p_token);
  v_entry public.queue_entries%rowtype;
  v_join  jsonb;
begin
  perform public.tick_court(v_court);

  -- O token do totem é de UMA quadra: com ele não se escreve na fila de
  -- outra, nem por id adivinhado.
  select * into v_entry from public.queue_entries e where e.id = p_entry_id;
  if not found or v_entry.court_id is distinct from v_court then
    raise exception 'Grupo não encontrado' using errcode = 'NQ007';
  end if;

  v_join := public.join_group(p_entry_id, p_name, 'totem');

  return (v_join - 'party_token')
         || jsonb_build_object('screen', public.totem_state(v_court));
end;
$$;

-- A fila da quadra pelo scan token, SEM consumir o token: é o que deixa
-- a tela do celular mostrar os grupos para escolher antes de escrever o
-- nome. Quem consome o token é a entrada, logo depois.
create or replace function public.scan_queue(p_scan_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token public.scan_tokens%rowtype;
begin
  v_token := public.take_anon_scan_token(
    p_scan_token, 'Escaneie o QR Code da quadra de novo');

  perform public.tick_court(v_token.court_id);

  return public.totem_state(v_token.court_id);
end;
$$;

create or replace function public.scan_join_group(
  p_scan_token text,
  p_entry_id   uuid,
  p_name       text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token public.scan_tokens%rowtype;
  v_entry public.queue_entries%rowtype;
  v_src   text;
  v_join  jsonb;
begin
  v_token := public.take_anon_scan_token(
    p_scan_token, 'Escaneie o QR Code da quadra de novo para entrar no grupo');

  select * into v_entry from public.queue_entries e where e.id = p_entry_id;
  if not found or v_entry.court_id is distinct from v_token.court_id then
    raise exception 'Grupo não encontrado' using errcode = 'NQ007';
  end if;

  v_src := case when v_token.method = 'nfc' then 'nfc' else 'qr' end;

  perform public.tick_court(v_token.court_id);
  v_join := public.join_group(p_entry_id, p_name, v_src);

  -- O scan token é de uso único: entrar num grupo gasta ele igual a
  -- criar uma party.
  update public.scan_tokens
     set consumed_at = now(), consumed_by_entry = p_entry_id
   where id = v_token.id;

  return v_join || jsonb_build_object('court_id', v_token.court_id);
end;
$$;

revoke all on function public.totem_join_group(text, uuid, text) from public, anon, authenticated;
revoke all on function public.scan_queue(text)                  from public, anon, authenticated;
revoke all on function public.scan_join_group(text, uuid, text)  from public, anon, authenticated;

grant execute on function public.totem_join_group(text, uuid, text) to anon, authenticated;
grant execute on function public.scan_queue(text)                   to anon, authenticated;
grant execute on function public.scan_join_group(text, uuid, text)   to anon, authenticated;

-- ---------------------------------------------------------------------
-- 11. A tela do celular: a minha vaga é a MINHA, dentro do grupo
-- ---------------------------------------------------------------------
create or replace function public.party_screen(p_party_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_member public.queue_party_members%rowtype;
  v_entry  public.queue_entries%rowtype;
  v_pos    integer;
begin
  v_member := public.take_party_member(p_party_token);

  select * into v_entry from public.queue_entries e where e.id = v_member.entry_id;

  perform public.tick_court(v_entry.court_id);

  -- A vaga pode ter virado outra: quem voltou para a fila tem vaga
  -- nova, e o segredo viaja com ela.
  v_member := public.take_party_member(p_party_token);
  select * into v_entry from public.queue_entries e where e.id = v_member.entry_id;

  select qp.position into v_pos
  from public.queue_positions qp
  where qp.court_id = v_entry.court_id and qp.entry_id = v_entry.id;

  return public.totem_state(v_entry.court_id) || jsonb_build_object(
    'my_party', jsonb_build_object(
      'entry_id',  v_entry.id,
      'name',      public.entry_label(v_entry.id),
      'my_name',   btrim(v_member.name),
      'size',      public.entry_size(v_entry.id),
      'label',     public.party_label(public.entry_size(v_entry.id)),
      'members',   public.party_members(v_entry.id),
      'in_group',  jsonb_array_length(public.party_members(v_entry.id)) > 1,
      'status',    v_entry.status,
      'position',  v_pos,
      'is_playing', v_entry.status = 'playing',
      'can_answer_exit', exists (select 1 from public.courts c
                                 where c.id = v_entry.court_id
                                   and c.exit_ask_entry_id = v_entry.id)
    )
  );
end;
$$;

revoke all on function public.party_screen(text) from public, anon, authenticated;
grant execute on function public.party_screen(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 12. A fila do app também mostra os membros
-- ---------------------------------------------------------------------
create or replace function public.court_queue_items(p_court_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with court as (
    select c.id, c.slot_minutes,
           c.handover_phase, c.handover_until,
           c.changeover_seconds as handover_cost,
           (c.pause_kind is not null or c.armed_pause_kind is not null) as frozen,
           (select count(*) from public.matches mt
             where mt.court_id = c.id and mt.ended_at is null) as live,
           (select greatest(0, floor(extract(epoch from (mt.expires_at - now())))::integer)
              from public.matches mt
             where mt.court_id = c.id and mt.ended_at is null
             limit 1) as remaining
    from public.courts c where c.id = p_court_id
  ),
  gap as (
    select case
             when frozen then null
             when live > 0 then coalesce(remaining, 0) + handover_cost
             when handover_phase is not null and handover_until > now()
               then greatest(0, ceil(extract(epoch from (handover_until - now())))::integer)
             else 0
           end as to_head,
           slot_minutes * 60 + handover_cost as per_turn
    from court
  ),
  q as (
    select qp.entry_id, qp.position, qp.status, e.first_joined_at as joined_at,
           e.call_expires_at, e.is_offline, e.offline_label, e.turn_number,
           e.party_name, e.party_size, e.source,
           coalesce(
             (select jsonb_build_object(
                       'frame', pr.racket_frame_color,
                       'grip',  pr.racket_grip_color)
                from public.queue_entry_members mm
                join public.profiles pr on pr.id = mm.user_id
               where mm.entry_id = qp.entry_id and mm.is_active and mm.role = 'owner'
               limit 1),
             case when e.is_offline
                  then jsonb_build_object('frame', '#9AA39C', 'grip', '#F1ECEF') end
           ) as racket,
           public.match_side_players(qp.entry_id) as players
    from public.queue_positions qp
    join public.queue_entries e on e.id = qp.entry_id
    where qp.court_id = p_court_id
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'entry_id',    q.entry_id,
        'position',    q.position,
        'position_label', q.position || 'º',
        'group_size',  public.entry_size(q.entry_id),
        'group_label', case when q.party_name is not null
                              then public.party_label(q.party_size)
                            when q.is_offline then 'Sem app'
                            else public.group_label(jsonb_array_length(q.players)) end,
        'mode_label',  case when q.party_name is not null
                              then public.party_label(q.party_size)
                            when q.is_offline then 'Sem app'
                            else public.group_label(jsonb_array_length(q.players)) end,
        'party_name',  q.party_name,
        'party_members', public.party_members(q.entry_id),
        'source',      q.source,
        'status',      q.status,
        'is_called',   q.status = 'ready',
        'is_being_called', q.entry_id = (select handover_entry_id from public.courts
                                          where id = p_court_id),
        'call_expires_at', q.call_expires_at,
        'joined_at',   q.joined_at,
        'turn_number', q.turn_number,
        'teams_ahead', (q.position - 1) + coalesce((select live from court), 0),
        'is_mine',     exists (
                         select 1 from public.queue_entry_members mm
                         where mm.entry_id = q.entry_id and mm.user_id = auth.uid() and mm.is_active
                       ),
        'is_offline',  q.is_offline,
        'offline_label', q.offline_label,
        'racket',      q.racket,
        'players',     q.players,
        'team_label',  public.entry_label(q.entry_id),
        'stack', (
          select coalesce(jsonb_agg(s.racket order by s.position), '[]'::jsonb)
          from (
            select q2.racket, q2.position
            from q q2
            where q2.position <= q.position and q2.racket is not null
            order by q2.position desc
            limit 5
          ) s
        ),
        'stack_more', greatest(q.position - 5, 0),
        'eta_seconds', case when (select to_head from gap) is null then null
                            else (select to_head from gap)
                                 + (q.position - 1) * (select per_turn from gap)
                       end
      )
      order by q.position
    ),
    '[]'::jsonb
  )
  from q;
$$;

grant execute on function public.court_queue_items(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 13. Fechado para PUBLIC, como manda a auditoria
-- ---------------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and has_function_privilege('public', p.oid, 'execute')
  loop
    execute format('revoke execute on function %s from public', r.sig);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 14. Quadra livre com gente na fila: a transição que faltava
--
-- O handoff tem "Quadra livre → Em jogo: alguém entra na fila", e só o
-- `join_party` fazia isso — quando a party nascia. Faltava o caminho de
-- volta: quem responde "voltar pra fila" com a quadra vazia, ou quem
-- fica na frente depois do admin remover a vaga da vez, ficava
-- esperando um relógio que não existia. A quadra podia ficar livre com
-- fila atrás por tempo indefinido.
--
-- Vale só para PARTY, e isso é de propósito: quem digitou no totem ou
-- escaneou o QR está na quadra, então não há quem fazer check-in. A
-- vaga com conta continua com o check-in e a tolerância da Sprint 3 —
-- essa pessoa pode estar a dez minutos de distância.
-- ---------------------------------------------------------------------
create or replace function public.start_free_court(p_court_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court public.courts%rowtype;
  v_next  uuid;
begin
  select * into v_court from public.courts c where c.id = p_court_id;
  if not found
     or v_court.pause_kind is not null
     or v_court.handover_phase is not null
     or not v_court.is_active
     or v_court.status = 'unavailable' then
    return null;
  end if;

  if exists (select 1 from public.matches mt
             where mt.court_id = p_court_id and mt.ended_at is null) then
    return null;
  end if;

  select qp.entry_id into v_next
  from public.queue_positions qp
  join public.queue_entries e on e.id = qp.entry_id
  where qp.court_id = p_court_id and e.party_name is not null
  order by qp.position
  limit 1;

  -- Só se a party for a PRIMEIRA da fila: começar o turno de quem está
  -- atrás passaria a vez de alguém.
  if v_next is null
     or v_next is distinct from (
          select qp.entry_id from public.queue_positions qp
          where qp.court_id = p_court_id order by qp.position limit 1) then
    return null;
  end if;

  perform public.open_match(v_next);
  return v_next;
end;
$$;

revoke all on function public.start_free_court(uuid) from public, anon, authenticated;

create or replace function public.tick_court(p_court_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.courts c
             where c.id = p_court_id
               and c.handover_until is not null and c.handover_until <= now())
     or exists (select 1 from public.matches mt
                where mt.court_id = p_court_id
                  and mt.ended_at is null and mt.expires_at <= now())
     or exists (select 1 from public.queue_entries e
                where e.court_id = p_court_id
                  and e.status = 'ready'
                  and e.call_expires_at is not null and e.call_expires_at <= now())
  then
    perform public.advance_court(p_court_id);
  end if;

  -- Quadra livre com party esperando: começa o turno dela. Fora do `if`
  -- de propósito — aqui não há prazo vencido para detectar, o estado
  -- parado já é o problema.
  perform public.start_free_court(p_court_id);
end;
$$;

revoke all on function public.tick_court(uuid) from public, anon, authenticated;

create or replace function public.advance_court(p_court_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court   public.courts%rowtype;
  v_match   record;
  v_entry   record;
  v_closed  integer := 0;
  v_expired integer := 0;
  v_started integer := 0;
  v_ready   boolean;
begin
  for v_match in
    select id from public.matches
    where court_id = p_court_id and ended_at is null and expires_at <= now()
  loop
    perform public.close_match(v_match.id, null, 'slot_expired');
    v_closed := v_closed + 1;
  end loop;

  select * into v_court from public.courts c where c.id = p_court_id;

  if found
     and v_court.handover_phase = 'changeover'
     and v_court.handover_until is not null
     and v_court.handover_until <= now() then

    -- Ninguém respondeu a pergunta de saída dentro da troca: o padrão
    -- hoje é sair.
    if v_court.exit_ask_entry_id is not null then
      update public.courts set exit_ask_entry_id = null where id = p_court_id;
    end if;

    v_ready := v_court.handover_entry_id is not null
               and exists (select 1 from public.queue_entries e
                           where e.id = v_court.handover_entry_id
                             and e.status in ('waiting', 'ready'));

    if v_ready
       and v_court.pause_kind is null
       and v_court.is_active
       and v_court.status <> 'unavailable'
       and not exists (select 1 from public.matches mt
                       where mt.court_id = p_court_id and mt.ended_at is null) then
      perform public.open_match(v_court.handover_entry_id);
      v_started := 1;
    else
      update public.courts
         set handover_phase = null, handover_entry_id = null, handover_until = null
       where id = p_court_id;
      perform public.start_handover(p_court_id);
    end if;
  end if;

  -- Chamada da regra antiga, que só atende o primeiro turno de quem
  -- entrou com conta.
  for v_entry in
    select e.id
    from public.queue_entries e
    where e.court_id = p_court_id
      and e.status = 'ready'
      and e.call_expires_at is not null
      and e.call_expires_at <= now()
    order by e.queue_number
  loop
    update public.queue_entries
       set status = 'expired', cancel_reason = 'no_show', left_at = now()
     where id = v_entry.id and status = 'ready';

    update public.queue_join_requests
       set status = 'expired', decided_at = now()
     where status = 'pending' and entry_id = v_entry.id;

    perform public.call_next_team(p_court_id);
    v_expired := v_expired + 1;
  end loop;

  -- E a quadra não fica livre com party esperando.
  if public.start_free_court(p_court_id) is not null then
    v_started := v_started + 1;
  end if;

  return jsonb_build_object('matches_closed', v_closed,
                            'entries_expired', v_expired,
                            'calls_skipped', 0,
                            'turns_started', v_started);
end;
$$;

revoke all on function public.advance_court(uuid) from public, anon, authenticated;
