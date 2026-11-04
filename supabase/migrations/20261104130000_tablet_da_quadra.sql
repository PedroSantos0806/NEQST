-- =====================================================================
-- O tablet da quadra: identidade própria, sem conta de ninguém
--
-- O tablet fica num parque público. Se ele carregasse a conta de admin,
-- quem pegasse o aparelho entraria no painel, editaria quadras e tiraria
-- gente da fila. Então ele não entra como pessoa: entra como APARELHO.
--
--   . o administrador gera um link da quadra, que aparece UMA vez;
--   . o tablet abre esse link e fica nele;
--   . com esse link dá para fazer exatamente duas coisas: ver a quadra
--     e apertar JOGAR por quem está sendo chamado.
--
-- Nada de perfil, nada de /admin, nada de entrar na fila por alguém.
-- Perdeu o tablet? Revoga o link e pronto; nenhuma conta foi exposta.
--
-- Por que o link pode aceitar a vez de um grupo: a prova de presença
-- aqui é o aparelho estar na quadra, igual à do QR impresso. Quem tem o
-- link e está longe pode, no máximo, começar o turno de quem já era o
-- próximo da fila — não pula a vez de ninguém, não entra na fila, não
-- remove ninguém. É um estrago pequeno, e revogável num clique.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. A tela do tablet
--
-- Volatile de propósito: cada leitura marca que o aparelho está vivo, e
-- é esse sinal que decide se a quadra chama os nomes ou volta para a
-- troca automática. Também executa o que já venceu — com chamadas de 15
-- segundos, esperar o cron de minuto em minuto não serve.
-- ---------------------------------------------------------------------
create or replace function public.tablet_screen(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_device public.court_devices%rowtype;
  v_screen jsonb;
begin
  select * into v_device
  from public.court_devices d
  where d.token_hash = public.hash_scan_token(p_token)
    and d.revoked_at is null;

  if not found then
    raise exception 'Este tablet não está mais ligado a uma quadra. Peça um link novo.'
      using errcode = 'NQ037';
  end if;

  update public.court_devices set last_seen_at = now() where id = v_device.id;

  v_screen := public.nudge_court(v_device.court_id);

  return v_screen || jsonb_build_object(
    'device', jsonb_build_object(
      'id',    v_device.id,
      'label', v_device.label
    )
  );
end;
$$;

revoke all on function public.tablet_screen(text) from public, anon, authenticated;
grant execute on function public.tablet_screen(text) to anon, authenticated;

comment on function public.tablet_screen(text) is
  'A tela da quadra para o tablet, pelo token do aparelho. Marca o aparelho como '
  'vivo e executa o que já venceu (turno, chamada, entrada).';

-- ---------------------------------------------------------------------
-- 2. O JOGAR do tablet
--
-- Basta uma pessoa apertar, e no tablet não há "pessoa": quem aperta é
-- quem está na quadra. O aceite vale para o grupo que está sendo
-- chamado — nunca para outro, porque a função nem recebe qual grupo é.
-- ---------------------------------------------------------------------
create or replace function public.tablet_accept_turn(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_device public.court_devices%rowtype;
begin
  select * into v_device
  from public.court_devices d
  where d.token_hash = public.hash_scan_token(p_token)
    and d.revoked_at is null;

  if not found then
    raise exception 'Este tablet não está mais ligado a uma quadra. Peça um link novo.'
      using errcode = 'NQ037';
  end if;

  update public.court_devices set last_seen_at = now() where id = v_device.id;

  -- p_user_id nulo: foi o tablet, não uma pessoa com conta. Fica
  -- registrado assim mesmo em accepted_at.
  return public.accept_handover(v_device.court_id, null)
         || jsonb_build_object('device', jsonb_build_object('id', v_device.id,
                                                            'label', v_device.label));
end;
$$;

revoke all on function public.tablet_accept_turn(text) from public, anon, authenticated;
grant execute on function public.tablet_accept_turn(text) to anon, authenticated;

comment on function public.tablet_accept_turn(text) is
  'O botão JOGAR do tablet: aceita a vez do grupo que está sendo chamado naquela quadra.';

-- ---------------------------------------------------------------------
-- 3. Administração: gerar, listar e revogar o link
--
-- O token aparece UMA vez, na resposta de quem o criou. Depois só fica
-- o hash — perdeu o link, gera outro e revoga o antigo. É a mesma regra
-- do segredo do QR, pelo mesmo motivo: o que o banco não guarda não
-- vaza.
-- ---------------------------------------------------------------------
create or replace function public.admin_create_court_device(
  p_court_id uuid,
  p_label    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token text;
  v_id    uuid;
  v_label text := nullif(trim(coalesce(p_label, '')), '');
begin
  perform public.require_admin();

  if not exists (select 1 from public.courts c where c.id = p_court_id) then
    raise exception 'Quadra não encontrada' using errcode = 'NQ003';
  end if;

  if v_label is not null and char_length(v_label) > 60 then
    raise exception 'O nome do aparelho vai até 60 caracteres' using errcode = 'NQ024';
  end if;

  -- 32 bytes de aleatório em hex: o mesmo tamanho dos tokens de scan.
  v_token := encode(extensions.gen_random_bytes(32), 'hex');

  insert into public.court_devices (court_id, label, token_hash, created_by)
  values (p_court_id, v_label, public.hash_scan_token(v_token), auth.uid())
  returning id into v_id;

  return jsonb_build_object(
    'device_id', v_id,
    'court_id',  p_court_id,
    'label',     v_label,
    -- Única vez que este valor existe fora do tablet.
    'token',     v_token,
    'path',      '/tablet/' || v_token
  );
end;
$$;

revoke all on function public.admin_create_court_device(uuid, text) from public, anon, authenticated;
grant execute on function public.admin_create_court_device(uuid, text) to authenticated;

create or replace function public.admin_court_devices(p_court_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.require_admin();

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'device_id',    d.id,
             'court_id',     d.court_id,
             'court_label',  public.court_label(c.court_number),
             'park_name',    pk.name,
             'label',        d.label,
             'created_at',   d.created_at,
             'last_seen_at', d.last_seen_at,
             'awake',        d.last_seen_at > now() - interval '2 minutes',
             'revoked_at',   d.revoked_at
           ) order by pk.name, c.court_number, d.created_at)
    from public.court_devices d
    join public.courts c on c.id = d.court_id
    join public.parks pk on pk.id = c.park_id
    where (p_court_id is null or d.court_id = p_court_id)
      and d.revoked_at is null
  ), '[]'::jsonb);
end;
$$;

revoke all on function public.admin_court_devices(uuid) from public, anon, authenticated;
grant execute on function public.admin_court_devices(uuid) to authenticated;

create or replace function public.admin_revoke_court_device(p_device_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court uuid;
begin
  perform public.require_admin();

  update public.court_devices
     set revoked_at = now()
   where id = p_device_id and revoked_at is null
  returning court_id into v_court;

  if v_court is null then
    raise exception 'Aparelho não encontrado' using errcode = 'NQ003';
  end if;

  return jsonb_build_object('device_id', p_device_id, 'revoked', true, 'court_id', v_court);
end;
$$;

revoke all on function public.admin_revoke_court_device(uuid) from public, anon, authenticated;
grant execute on function public.admin_revoke_court_device(uuid) to authenticated;
