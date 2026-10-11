-- =====================================================================
-- Raio de proximidade na tela de administração
--
-- `max_distance_meters` e `gps_tolerance_meters` decidem se a leitura
-- do QR é aceita. São eles que impedem alguém de entrar na fila de
-- casa — e são também o que trava um teste feito longe da quadra.
-- Estavam só no banco; agora o admin regula por quadra.
-- =====================================================================

-- O overview ganha os dois campos.
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
                'max_distance_meters',  c.max_distance_meters,
                'gps_tolerance_meters', c.gps_tolerance_meters,
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

-- A assinatura muda, então a antiga sai de cena antes.
drop function if exists public.admin_upsert_court(
  uuid, uuid, smallint, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean
);

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
  p_is_active    boolean default null,
  p_max_distance_meters  integer default null,
  p_gps_tolerance_meters integer default null
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
      latitude, longitude, city, slot_minutes, has_qr_code, has_nfc_tag,
      max_distance_meters, gps_tolerance_meters
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
      coalesce(p_has_nfc_tag, false),
      coalesce(p_max_distance_meters, 1000),
      coalesce(p_gps_tolerance_meters, 200)
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
      is_active    = coalesce(p_is_active, is_active),
      max_distance_meters  = coalesce(p_max_distance_meters, max_distance_meters),
      gps_tolerance_meters = coalesce(p_gps_tolerance_meters, gps_tolerance_meters)
    where id = p_id
    returning * into v_row;

    if v_row.id is null then
      raise exception 'Quadra não encontrada.' using errcode = 'NQ025';
    end if;
  end if;

  return to_jsonb(v_row);
end;
$$;

comment on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer
) is
  'Cria ou edita uma quadra. O raio de proximidade entra aqui para que um '
  'ambiente de teste possa afrouxá-lo sem passar pelo SQL Editor.';

revoke all on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer
) from public;

grant execute on function public.admin_upsert_court(
  uuid, uuid, smallint, text, text, double precision, double precision,
  smallint, boolean, boolean, boolean, integer, integer
) to authenticated;
