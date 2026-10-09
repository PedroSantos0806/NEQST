-- =====================================================================
-- NEQST — administração
--
-- O modelo de papéis já existia (player / staff / admin) e o RLS já
-- dava ao admin o controle de parques, quadras e perfis. Faltavam três
-- coisas: garantir que exista no máximo UM admin, um caminho seguro
-- para criar o primeiro, e as RPCs que a tela /admin usa.
--
-- Nada aqui permite que alguém se promova: `promote_to_admin` só é
-- executável pelo service_role (o SQL Editor do painel), e a política
-- "profiles: dono atualiza" continua exigindo que o papel fique igual
-- ao que já era.
-- =====================================================================

-- ---------------------------------------------------------------------
-- No máximo um admin
--
-- Índice único sobre uma constante, restrito às linhas de admin: a
-- segunda tentativa de criar um admin falha no banco, não na aplicação.
-- ---------------------------------------------------------------------
create unique index if not exists profiles_single_admin_idx
  on public.profiles ((true))
  where role = 'admin'::public.app_role;

comment on index public.profiles_single_admin_idx is
  'Garante um único administrador. Para trocar de admin, rebaixe o atual antes.';

-- ---------------------------------------------------------------------
-- Criar o primeiro admin
--
-- Executada do SQL Editor (service_role). Deliberadamente NÃO é
-- concedida a `authenticated`: se fosse, qualquer pessoa logada
-- poderia se promover.
-- ---------------------------------------------------------------------
create or replace function public.promote_to_admin(p_email text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id      uuid;
  v_current uuid;
begin
  select id into v_id from public.profiles where lower(email) = lower(trim(p_email));

  if v_id is null then
    raise exception 'Nenhum perfil com o e-mail %. Crie o usuário em Authentication > Users primeiro.', p_email
      using errcode = 'NQ021';
  end if;

  select id into v_current from public.profiles where role = 'admin'::public.app_role;

  if v_current is not null and v_current <> v_id then
    raise exception 'Já existe um admin. Rebaixe-o antes: update public.profiles set role = ''player'' where id = ''%'';', v_current
      using errcode = 'NQ022';
  end if;

  update public.profiles set role = 'admin'::public.app_role where id = v_id;

  return jsonb_build_object('user_id', v_id, 'email', p_email, 'role', 'admin');
end;
$$;

comment on function public.promote_to_admin(text) is
  'Promove um perfil a admin. Só pelo SQL Editor — nunca exposta ao app.';

revoke all on function public.promote_to_admin(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Slug a partir do nome, sem colidir com o que já existe
-- ---------------------------------------------------------------------
-- `unaccent` é uma extensão opcional; esta tradução cobre o português
-- sem depender dela.
create or replace function public.unaccent_text(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select translate(
    p_text,
    'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑ',
    'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCN'
  );
$$;

create or replace function public.slugify(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(
    trim(both '-' from
      regexp_replace(
        lower(public.unaccent_text(coalesce(p_text, ''))),
        '[^a-z0-9]+', '-', 'g'
      )
    ),
    ''
  );
$$;

create or replace function public.unique_slug(p_table text, p_base text)
returns text
language plpgsql
set search_path = ''
as $$
declare
  v_base  text := coalesce(public.slugify(p_base), 'item');
  v_slug  text := v_base;
  v_n     integer := 1;
  v_taken boolean;
begin
  -- Mínimo de 3 caracteres (as duas tabelas exigem isso no check).
  if char_length(v_base) < 3 then
    v_base := v_base || '-nq';
    v_slug := v_base;
  end if;

  loop
    if p_table = 'parks' then
      select exists(select 1 from public.parks where slug = v_slug) into v_taken;
    else
      select exists(select 1 from public.courts where slug = v_slug) into v_taken;
    end if;

    exit when not v_taken;

    v_n := v_n + 1;
    v_slug := left(v_base, 55) || '-' || v_n;
  end loop;

  return v_slug;
end;
$$;

-- ---------------------------------------------------------------------
-- Guarda comum das RPCs de admin
-- ---------------------------------------------------------------------
create or replace function public.require_admin()
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Ação restrita ao administrador.' using errcode = 'NQ023';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Tela /admin: parques com as quadras
-- ---------------------------------------------------------------------
create or replace function public.admin_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.require_admin();

  return jsonb_build_object(
    'parks', coalesce((
      select jsonb_agg(p order by p.name)
      from (
        select jsonb_build_object(
          'id',        pk.id,
          'slug',      pk.slug::text,
          'name',      pk.name,
          'district',  pk.district,
          'city',      pk.city,
          'latitude',  pk.latitude,
          'longitude', pk.longitude,
          'tone_color', pk.tone_color,
          'photo_alt', pk.photo_alt,
          'is_active', pk.is_active,
          'courts', coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'id',            c.id,
                'slug',          c.slug::text,
                'name',          c.name,
                'court_number',  c.court_number,
                'surface',       c.surface,
                'surface_label', case c.surface
                                   when 'clay' then 'Saibro'
                                   when 'hard' then 'Rápida'
                                   else 'Grama'
                                 end,
                'latitude',      c.latitude,
                'longitude',     c.longitude,
                'slot_minutes',  c.slot_minutes,
                'is_active',     c.is_active,
                'status',        c.status,
                'has_qr_code',   c.has_qr_code,
                'has_nfc_tag',   c.has_nfc_tag,
                'queue_length',  (
                  select count(*) from public.queue_entries q
                  where q.court_id = c.id and q.status in ('waiting', 'ready')
                )
              ) order by c.court_number
            )
            from public.courts c where c.park_id = pk.id
          ), '[]'::jsonb)
        ) as p, pk.name
        from public.parks pk
      ) p
    ), '[]'::jsonb),
    'totals', (
      select jsonb_build_object(
        'parks',  (select count(*) from public.parks),
        'courts', (select count(*) from public.courts),
        'users',  (select count(*) from public.profiles)
      )
    )
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Criar / editar parque
-- ---------------------------------------------------------------------
create or replace function public.admin_upsert_park(
  p_id        uuid    default null,
  p_name      text    default null,
  p_district  text    default null,
  p_city      text    default null,
  p_latitude  double precision default null,
  p_longitude double precision default null,
  p_tone_color text   default null,
  p_photo_alt text    default null,
  p_is_active boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_row public.parks;
begin
  perform public.require_admin();

  if p_id is null then
    if coalesce(trim(p_name), '') = '' then
      raise exception 'Informe o nome do parque.' using errcode = 'NQ024';
    end if;
    if p_latitude is null or p_longitude is null then
      raise exception 'Informe a localização do parque.' using errcode = 'NQ024';
    end if;

    insert into public.parks (slug, name, district, city, latitude, longitude, tone_color, photo_alt)
    values (
      public.unique_slug('parks', p_name),
      trim(p_name), nullif(trim(p_district), ''), nullif(trim(p_city), ''),
      p_latitude, p_longitude, nullif(trim(p_tone_color), ''), nullif(trim(p_photo_alt), '')
    )
    returning * into v_row;
  else
    update public.parks set
      name       = coalesce(nullif(trim(p_name), ''), name),
      district   = coalesce(nullif(trim(p_district), ''), district),
      city       = coalesce(nullif(trim(p_city), ''), city),
      latitude   = coalesce(p_latitude, latitude),
      longitude  = coalesce(p_longitude, longitude),
      tone_color = coalesce(nullif(trim(p_tone_color), ''), tone_color),
      photo_alt  = coalesce(nullif(trim(p_photo_alt), ''), photo_alt),
      is_active  = coalesce(p_is_active, is_active)
    where id = p_id
    returning * into v_row;

    if v_row.id is null then
      raise exception 'Parque não encontrado.' using errcode = 'NQ025';
    end if;
  end if;

  return to_jsonb(v_row);
end;
$$;

-- ---------------------------------------------------------------------
-- Criar / editar quadra
--
-- O número da quadra, quando não informado, é o próximo livre do
-- parque — é assim que o operador espera cadastrar ("mais uma quadra").
-- ---------------------------------------------------------------------
create or replace function public.admin_upsert_court(
  p_id           uuid    default null,
  p_park_id      uuid    default null,
  p_court_number smallint default null,
  p_surface      text    default null,
  p_name         text    default null,
  p_latitude     double precision default null,
  p_longitude    double precision default null,
  p_slot_minutes smallint default null,
  p_has_qr_code  boolean default null,
  p_has_nfc_tag  boolean default null,
  p_is_active    boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row    public.courts;
  v_park   public.parks;
  v_number smallint;
  v_name   text;
begin
  perform public.require_admin();

  if p_id is null then
    select * into v_park from public.parks where id = p_park_id;
    if v_park.id is null then
      raise exception 'Parque não encontrado.' using errcode = 'NQ025';
    end if;

    v_number := coalesce(
      p_court_number,
      (select coalesce(max(court_number), 0) + 1 from public.courts where park_id = v_park.id)::smallint
    );
    v_name := coalesce(nullif(trim(p_name), ''), 'Quadra ' || lpad(v_number::text, 2, '0'));

    insert into public.courts (
      park_id, court_number, surface, slug, name,
      latitude, longitude, city, slot_minutes, has_qr_code, has_nfc_tag
    )
    values (
      v_park.id, v_number,
      coalesce(p_surface, 'clay')::public.court_surface,
      public.unique_slug('courts', v_park.slug::text || '-q' || v_number),
      v_name,
      coalesce(p_latitude, v_park.latitude),
      coalesce(p_longitude, v_park.longitude),
      v_park.city,
      coalesce(p_slot_minutes, 40::smallint),
      coalesce(p_has_qr_code, true),
      coalesce(p_has_nfc_tag, false)
    )
    returning * into v_row;
  else
    update public.courts set
      court_number = coalesce(p_court_number, court_number),
      surface      = coalesce(p_surface::public.court_surface, surface),
      name         = coalesce(nullif(trim(p_name), ''), name),
      latitude     = coalesce(p_latitude, latitude),
      longitude    = coalesce(p_longitude, longitude),
      slot_minutes = coalesce(p_slot_minutes, slot_minutes),
      has_qr_code  = coalesce(p_has_qr_code, has_qr_code),
      has_nfc_tag  = coalesce(p_has_nfc_tag, has_nfc_tag),
      is_active    = coalesce(p_is_active, is_active)
    where id = p_id
    returning * into v_row;

    if v_row.id is null then
      raise exception 'Quadra não encontrada.' using errcode = 'NQ025';
    end if;
  end if;

  return to_jsonb(v_row);
end;
$$;

-- ---------------------------------------------------------------------
-- Usuários
-- ---------------------------------------------------------------------
create or replace function public.admin_users(
  p_query text default null,
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_q text := nullif(trim(coalesce(p_query, '')), '');
begin
  perform public.require_admin();

  return coalesce((
    select jsonb_agg(u order by u.created_at desc)
    from (
      select jsonb_build_object(
        'user_id',   p.id,
        'username',  p.username::text,
        'full_name', p.full_name,
        'email',     p.email,
        'role',      p.role,
        'initials',  public.initials_of(coalesce(p.full_name, p.username::text)),
        'created_at', p.created_at,
        'state',     public.player_state(p.id) ->> 'state'
      ) as u, p.created_at
      from public.profiles p
      where v_q is null
         or p.email ilike '%' || v_q || '%'
         or p.username::text ilike '%' || v_q || '%'
         or coalesce(p.full_name, '') ilike '%' || v_q || '%'
      order by p.created_at desc
      limit greatest(1, least(coalesce(p_limit, 50), 200))
    ) u
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------
-- Promover a staff ou rebaixar a player
--
-- `admin` fica de fora de propósito: o índice único já impediria o
-- segundo, e trocar de administrador é operação de banco, não de tela.
-- ---------------------------------------------------------------------
create or replace function public.admin_set_role(p_user_id uuid, p_role text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_row public.profiles;
begin
  perform public.require_admin();

  if p_role not in ('player', 'staff') then
    raise exception 'Papel inválido. Use player ou staff.' using errcode = 'NQ026';
  end if;

  if p_user_id = auth.uid() then
    raise exception 'Você não pode mudar o próprio papel.' using errcode = 'NQ026';
  end if;

  update public.profiles
     set role = p_role::public.app_role
   where id = p_user_id
  returning * into v_row;

  if v_row.id is null then
    raise exception 'Usuário não encontrado.' using errcode = 'NQ025';
  end if;

  return jsonb_build_object('user_id', v_row.id, 'role', v_row.role);
end;
$$;

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
revoke all on function public.admin_overview()                              from public;
revoke all on function public.admin_upsert_park(uuid, text, text, text, double precision, double precision, text, text, boolean) from public;
revoke all on function public.admin_upsert_court(uuid, uuid, smallint, text, text, double precision, double precision, smallint, boolean, boolean, boolean) from public;
revoke all on function public.admin_users(text, integer)                    from public;
revoke all on function public.admin_set_role(uuid, text)                    from public;
revoke all on function public.require_admin()                               from public;
revoke all on function public.unique_slug(text, text)                       from public;

grant execute on function public.admin_overview()                              to authenticated;
grant execute on function public.admin_upsert_park(uuid, text, text, text, double precision, double precision, text, text, boolean) to authenticated;
grant execute on function public.admin_upsert_court(uuid, uuid, smallint, text, text, double precision, double precision, smallint, boolean, boolean, boolean) to authenticated;
grant execute on function public.admin_users(text, integer)                    to authenticated;
grant execute on function public.admin_set_role(uuid, text)                    to authenticated;
grant execute on function public.require_admin()                               to authenticated;
