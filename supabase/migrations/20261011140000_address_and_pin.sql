-- =====================================================================
-- Endereço escrito + alfinete no mapa
--
-- O cadastro pedia latitude e longitude cruas, e quem cadastra não tem
-- isso na mão. Pior: a quadra herdava calada a posição do parque, e em
-- parque grande — quadra no meio, longe da rua — isso é a diferença
-- entre o check-in funcionar e não funcionar, porque é a posição da
-- QUADRA que o scan-court compara com a do jogador.
--
-- Então o formulário passa a ter duas coisas separadas:
--   . o endereço, que é referência de quem vai chegar de carro;
--   . a posição, marcada no mapa, que é o que vale no check-in.
--
-- Aqui embaixo isso significa: `p_address` nos dois upserts (a coluna
-- `address` já existia nas duas tabelas, só não havia como preenchê-la
-- pelo app), o endereço do parque herdado pela quadra nova, e o
-- `admin_overview` devolvendo `address` para o formulário reabrir
-- preenchido.
-- =====================================================================

-- ---------------------------------------------------------------------
-- O overview devolve o endereço de parques e quadras
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
          'address',   pk.address,
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
                'address',       c.address,
                'latitude',      c.latitude,
                'longitude',     c.longitude,
                'slot_minutes',  c.slot_minutes,
                'is_active',     c.is_active,
                'status',        c.status,
                'has_qr_code',   c.has_qr_code,
                'has_nfc_tag',   c.has_nfc_tag,
                'max_distance_meters',  c.max_distance_meters,
                'gps_tolerance_meters', c.gps_tolerance_meters,
                'enforce_proximity',    c.enforce_proximity,
                'qr_secret_version',    c.qr_secret_version,
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
-- Parque: endereço junto do resto
--
-- A assinatura antiga sai de cena: com todos os parâmetros opcionais,
-- duas versões conviventes deixariam a chamada por nome ambígua.
-- ---------------------------------------------------------------------
drop function if exists public.admin_upsert_park(
  uuid, text, text, text, double precision, double precision, text, text, boolean
);

create or replace function public.admin_upsert_park(
  p_id        uuid    default null,
  p_name      text    default null,
  p_district  text    default null,
  p_city      text    default null,
  p_address   text    default null,
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
      raise exception 'Marque no mapa onde fica o parque.' using errcode = 'NQ024';
    end if;

    insert into public.parks (
      slug, name, district, city, address, latitude, longitude, tone_color, photo_alt
    )
    values (
      public.unique_slug('parks', p_name),
      trim(p_name), nullif(trim(p_district), ''), nullif(trim(p_city), ''),
      nullif(trim(p_address), ''),
      p_latitude, p_longitude, nullif(trim(p_tone_color), ''), nullif(trim(p_photo_alt), '')
    )
    returning * into v_row;
  else
    update public.parks set
      name       = coalesce(nullif(trim(p_name), ''), name),
      district   = coalesce(nullif(trim(p_district), ''), district),
      city       = coalesce(nullif(trim(p_city), ''), city),
      address    = coalesce(nullif(trim(p_address), ''), address),
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
-- Quadra: endereço de referência e posição própria
--
-- A posição continua caindo para a do parque quando não vem nada — é o
-- que mantém o cadastro antigo válido. A diferença é que agora o
-- formulário sempre manda a posição marcada no mapa, então a quadra do
-- meio do parque deixa de ficar com a coordenada do portão.
-- ---------------------------------------------------------------------
drop function if exists public.admin_upsert_court(
  uuid, uuid, smallint, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean
);

create or replace function public.admin_upsert_court(
  p_id           uuid    default null,
  p_park_id      uuid    default null,
  p_court_number smallint default null,
  p_surface      text    default null,
  p_name         text    default null,
  p_address      text    default null,
  p_latitude     double precision default null,
  p_longitude    double precision default null,
  p_slot_minutes smallint default null,
  p_has_qr_code  boolean default null,
  p_has_nfc_tag  boolean default null,
  p_is_active    boolean default null,
  p_max_distance_meters  integer default null,
  p_gps_tolerance_meters integer default null,
  p_enforce_proximity    boolean default null
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
      address, latitude, longitude, city, slot_minutes, has_qr_code, has_nfc_tag,
      max_distance_meters, gps_tolerance_meters, enforce_proximity
    )
    values (
      v_park.id, v_number,
      coalesce(p_surface, 'clay')::public.court_surface,
      public.unique_slug('courts', v_park.slug::text || '-q' || v_number),
      v_name,
      coalesce(nullif(trim(p_address), ''), v_park.address),
      coalesce(p_latitude, v_park.latitude),
      coalesce(p_longitude, v_park.longitude),
      v_park.city,
      coalesce(p_slot_minutes, 40::smallint),
      coalesce(p_has_qr_code, true),
      coalesce(p_has_nfc_tag, false),
      coalesce(p_max_distance_meters, 1000),
      coalesce(p_gps_tolerance_meters, 200),
      coalesce(p_enforce_proximity, true)
    )
    returning * into v_row;
  else
    update public.courts set
      court_number = coalesce(p_court_number, court_number),
      surface      = coalesce(p_surface::public.court_surface, surface),
      name         = coalesce(nullif(trim(p_name), ''), name),
      address      = coalesce(nullif(trim(p_address), ''), address),
      latitude     = coalesce(p_latitude, latitude),
      longitude    = coalesce(p_longitude, longitude),
      slot_minutes = coalesce(p_slot_minutes, slot_minutes),
      has_qr_code  = coalesce(p_has_qr_code, has_qr_code),
      has_nfc_tag  = coalesce(p_has_nfc_tag, has_nfc_tag),
      is_active    = coalesce(p_is_active, is_active),
      max_distance_meters  = coalesce(p_max_distance_meters, max_distance_meters),
      gps_tolerance_meters = coalesce(p_gps_tolerance_meters, gps_tolerance_meters),
      enforce_proximity    = coalesce(p_enforce_proximity, enforce_proximity)
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
-- Permissões das novas assinaturas
-- ---------------------------------------------------------------------
revoke all on function public.admin_upsert_park(
  uuid, text, text, text, text, double precision, double precision, text, text, boolean
) from public;

grant execute on function public.admin_upsert_park(
  uuid, text, text, text, text, double precision, double precision, text, text, boolean
) to authenticated;

revoke all on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean
) from public;

grant execute on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean
) to authenticated;
