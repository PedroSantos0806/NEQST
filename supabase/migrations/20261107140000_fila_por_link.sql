-- ---------------------------------------------------------------------
-- Sprint 10 — a fila é um link, e o QR só leva até ele
--
-- Decisão do Pedro, depois de testar o totem no iPad:
--
--   "Aquele link que foi gerado no sistema a gente vai abrir no tablet,
--    e quando abrir ele tem que ir direto pra tela da fila, com um
--    botão ENTRAR NA FILA para a pessoa colocar nome e sobrenome. O QR
--    Code serve apenas para a pessoa ser redirecionada para o site, não
--    como meio de entrar na fila: ele só leva direto pro link da fila
--    daquela quadra, para a pessoa entrar igual entra pelo tablet."
--
-- Isso apaga o scan token do caminho de entrada. Antes, entrar pelo
-- celular exigia provar presença: escanear o QR impresso gerava um
-- token de 30 segundos, de uso único, atrelado ao GPS. Agora o que
-- autoriza entrar na fila é **saber o link da quadra** — e o link é
-- público por definição, porque está impresso numa placa.
--
-- O que se perde, dito em voz alta: alguém de casa, com o link, entra
-- na fila de uma quadra onde não está. O remédio não é mais
-- criptográfico, é humano e operacional:
--
--   * quem está na quadra vê a fila na tela e chama o próximo nome;
--   * quem não aparece na troca de 1:30 perde a vez para o seguinte;
--   * o `/admin` remove quem não está lá;
--   * `expire_stale_queue_entries` limpa quem ficou esperando sem
--     aparecer.
--
-- E duas guardas novas, que não existiam porque o scan token as
-- tornava desnecessárias:
--
--   * teto de parties esperando por quadra (NQ043), contra inundar a
--     fila de uma quadra pública de longe;
--   * o mesmo nome duas vezes em poucos minutos é recusado (NQ004),
--     que é o toque duplo no tablet e o refresh do celular.
--
-- As funções `totem_*` continuam existindo e continuam sendo as únicas
-- que pausam, retomam, continuam o jogo e respondem a pergunta de
-- saída: isso é poder de operação e segue exigindo o token do aparelho
-- que o `/admin` gerou. O link público só sabe ler a fila e entrar
-- nela.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- 1. A quadra pelo link: uuid ou slug
-- ---------------------------------------------------------------------
-- O QR impresso fica melhor com o slug (`/fila/ibira-3` dá para digitar
-- à mão quando a câmera não colabora), e os links que já existem usam o
-- uuid. As duas formas resolvem para a mesma quadra.
create or replace function public.court_by_ref(p_ref text)
returns uuid
language plpgsql
security definer
stable
set search_path = ''
as $$
declare
  v_ref  text := nullif(btrim(coalesce(p_ref, '')), '');
  v_id   uuid;
begin
  if v_ref is null then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;

  -- `uuid` lança 22P02 em texto que não é uuid; aqui isso não é erro,
  -- é só a resposta "não era um id, então é um slug".
  begin
    v_id := v_ref::uuid;
  exception when invalid_text_representation then
    v_id := null;
  end;

  if v_id is not null then
    if exists (select 1 from public.courts c where c.id = v_id) then
      return v_id;
    end if;
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;

  select c.id into v_id
  from public.courts c
  where c.slug = v_ref::extensions.citext;

  if v_id is null then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;

  return v_id;
end;
$$;

revoke all on function public.court_by_ref(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. As guardas que o scan token dispensava
-- ---------------------------------------------------------------------
-- Teto de parties esperando por quadra. Um número que nenhuma fila real
-- alcança: a 40 minutos por party, 50 parties são mais de 33 horas de
-- jogo. Existe contra inundação, não para limitar gente.
create or replace function public.queue_room_left(p_court_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_waiting integer;
begin
  select count(*) into v_waiting
  from public.queue_entries e
  where e.court_id = p_court_id
    and e.status in ('waiting', 'ready');

  if v_waiting >= 50 then
    raise exception 'A fila desta quadra está cheia. Tente de novo mais tarde.'
      using errcode = 'NQ043';
  end if;
end;
$$;

revoke all on function public.queue_room_left(uuid) from public, anon, authenticated;

/*
 * `join_party` de novo, com as duas guardas.
 *
 * O resto é igual à Sprint 9 — o token por pessoa, o membro inicial, a
 * quadra livre que começa a jogar. O que entra aqui é o teto da fila e
 * a recusa do mesmo nome em sequência, que o scan token de uso único
 * resolvia sozinho e agora ninguém resolve.
 */
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

  perform public.queue_room_left(p_court_id);

  /*
   * O mesmo nome entrando duas vezes em três minutos é quase sempre o
   * mesmo toque contado duas vezes: o dedo no tablet, o refresh do
   * celular, a conexão que caiu depois de gravar. A janela é curta de
   * propósito — dois Joões de verdade, em dias diferentes ou na mesma
   * tarde, continuam podendo entrar.
   */
  if exists (
    select 1
    from public.queue_entries e
    where e.court_id = p_court_id
      and e.status in ('waiting', 'ready', 'playing')
      and lower(btrim(e.party_name)) = lower(v_name)
      and e.joined_at > now() - interval '3 minutes'
  ) then
    raise exception 'Esse nome acabou de entrar na fila desta quadra'
      using errcode = 'NQ004';
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

revoke all on function public.join_party(uuid, text, integer, text, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Ler a fila da quadra pelo link
-- ---------------------------------------------------------------------
-- Mesmo payload de `totem_screen`, sem token de aparelho: é a mesma
-- tela, e por isso é a mesma função de estado. A leitura também dá o
-- `tick`, que é o que faz o relógio andar para quem está olhando — num
-- parque onde o tablet está apagado, o celular de quem passa segura a
-- quadra andando.
create or replace function public.queue_screen(p_court_ref text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court uuid := public.court_by_ref(p_court_ref);
begin
  perform public.tick_court(v_court);
  return public.totem_state(v_court);
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Entrar na fila pelo link
-- ---------------------------------------------------------------------
-- `p_source` separa os dois caminhos que a mesma tela atende: 'totem'
-- quando o toque veio do aparelho da quadra (e aí não há navegador a
-- lembrar de ninguém, nem token devolvido) e 'qr' quando veio do
-- celular de quem leu a placa (e aí a pessoa fica com o próprio
-- segredo, acompanha a posição e sai sozinha).
--
-- Quem abre o link no tablet usa o token do aparelho e cai em
-- `totem_join`; esta função é a do link público, então o padrão é 'qr'.
create or replace function public.queue_join(
  p_court_ref text,
  p_name      text,
  p_size      integer,
  p_source    text default 'qr'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court uuid := public.court_by_ref(p_court_ref);
  v_src   text := case when p_source in ('qr', 'nfc') then p_source else 'qr' end;
  v_join  jsonb;
begin
  perform public.tick_court(v_court);
  v_join := public.join_party(v_court, p_name, p_size, v_src, null);

  return v_join || jsonb_build_object(
    'court_id', v_court,
    'screen',   public.totem_state(v_court)
  );
end;
$$;

create or replace function public.queue_join_group(
  p_court_ref text,
  p_entry_id  uuid,
  p_name      text,
  p_source    text default 'qr'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court uuid := public.court_by_ref(p_court_ref);
  v_src   text := case when p_source in ('qr', 'nfc') then p_source else 'qr' end;
  v_entry public.queue_entries%rowtype;
  v_join  jsonb;
begin
  -- O grupo tem de ser da quadra do link. Sem isso, saber um entry_id
  -- (que aparece na tela) deixaria entrar no grupo de outra quadra.
  select * into v_entry from public.queue_entries e where e.id = p_entry_id;
  if not found or v_entry.court_id is distinct from v_court then
    raise exception 'Grupo não encontrado' using errcode = 'NQ007';
  end if;

  perform public.tick_court(v_court);
  v_join := public.join_group(p_entry_id, p_name, v_src);

  return v_join || jsonb_build_object(
    'court_id', v_court,
    'screen',   public.totem_state(v_court)
  );
end;
$$;

revoke all on function public.queue_screen(text)                     from public, anon, authenticated;
revoke all on function public.queue_join(text, text, integer, text)  from public, anon, authenticated;
revoke all on function public.queue_join_group(text, uuid, text, text) from public, anon, authenticated;

grant execute on function public.queue_screen(text)                     to anon, authenticated;
grant execute on function public.queue_join(text, text, integer, text)  to anon, authenticated;
grant execute on function public.queue_join_group(text, uuid, text, text) to anon, authenticated;

comment on function public.queue_screen(text) is
  'A fila da quadra pelo link público (uuid ou slug). Mesmo payload de totem_screen.';
comment on function public.queue_join(text, text, integer, text) is
  'Entrar na fila sabendo só o link da quadra. Devolve o token da pessoa (origem qr/nfc).';
comment on function public.queue_join_group(text, uuid, text, text) is
  'Entrar no grupo de quem já está na fila, pelo link público da quadra.';
