-- =====================================================================
-- Reconciliação: endereço + alfinete (PR #12) e tolerância de chamada
-- (PR #13) na mesma função
--
-- As duas entregas mexeram em `admin_upsert_court` e `admin_overview`
-- ao mesmo tempo, em ramos diferentes. A resolução do conflito manteve
-- as duas versões lado a lado, e o estrago foi este:
--
--   . o `drop function` do ramo dos grupos nomeia a assinatura de 14
--     parâmetros, que deixou de existir quando o endereço entrou. Ele
--     não derruba nada ("does not exist, skipping") e, logo abaixo,
--     cria uma SEGUNDA versão. Com todos os parâmetros opcionais, o
--     Postgres não tem como escolher entre as duas:
--     `function public.admin_upsert_court(unknown, uuid) is not unique`;
--   . o `admin_overview` do ramo dos grupos é uma cópia de antes do
--     endereço, com `call_window_seconds` somado. Ao rodar por último,
--     ele apaga o `address` que o formulário de administração lê — os
--     campos de endereço reabrem vazios.
--
-- Esta migration faz o que a resolução deveria ter feito: derruba as
-- DUAS assinaturas pelo nome completo e deixa uma só função, com
-- endereço e tolerância juntos. O `admin_overview` volta a devolver
-- `address` sem perder `call_window_seconds`.
-- =====================================================================

-- ---------------------------------------------------------------------
-- O painel devolve as duas coisas
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
                'call_window_seconds', c.call_window_seconds,
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
-- Uma função só, com endereço e tolerância
--
-- Os dois `drop` abaixo são o conserto: cada um nomeia uma das versões
-- que ficaram vivas. Rodar de novo não dói — o `if exists` cobre.
-- ---------------------------------------------------------------------

-- a que o endereço criou
drop function if exists public.admin_upsert_court(
  uuid, uuid, smallint, text, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean
);

-- a que os grupos criaram
drop function if exists public.admin_upsert_court(
  uuid, uuid, smallint, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean, integer
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
  p_enforce_proximity    boolean default null,
  p_call_window_seconds  integer default null
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
      max_distance_meters, gps_tolerance_meters, enforce_proximity, call_window_seconds
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
      coalesce(p_enforce_proximity, true),
      coalesce(p_call_window_seconds, 120)
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
      enforce_proximity    = coalesce(p_enforce_proximity, enforce_proximity),
      call_window_seconds  = coalesce(p_call_window_seconds, call_window_seconds)
    where id = p_id
    returning * into v_row;

    if v_row.id is null then
      raise exception 'Quadra não encontrada.' using errcode = 'NQ025';
    end if;
  end if;

  return to_jsonb(v_row);
end;
$$;

revoke all on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean, integer
) from public;

grant execute on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer, boolean, integer
) to authenticated;
