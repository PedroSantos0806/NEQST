-- =====================================================================
-- Endereço: apagável, com tamanho, e coordenada que anda em par
--
-- Três correções de revisão no mesmo lugar, porque mexem nas mesmas
-- duas funções:
--
--   . `coalesce(nullif(trim(p_address), ''), address)` nunca limpava
--     nada. Quem digitou o endereço errado apagava o campo, salvava,
--     via "Quadra atualizada" e reabria com o texto velho de volta.
--     Agora nulo e vazio querem dizer coisas diferentes: NULO é "não
--     mexi nisso" e VAZIO é "apague".
--
--   . `address` era `text` sem limite — gravei 100.000 caracteres pelo
--     RPC. `name` já tinha 2..120; o endereço não tinha nada.
--
--   . Passar só a latitude misturava com a longitude do parque, e o
--     resultado era um ponto que não é nem um nem outro. Alfinete é
--     par: ou vêm os dois, ou não vem nenhum.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Tamanho do endereço
--
-- NOT VALID de propósito: vale para tudo que for gravado daqui em
-- diante sem reprovar linha antiga que por acaso seja maior.
-- ---------------------------------------------------------------------
do $$ begin
  alter table public.courts
    add constraint courts_address_length check (char_length(address) <= 200) not valid;
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.parks
    add constraint parks_address_length check (char_length(address) <= 200) not valid;
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- Um lugar só para decidir o que fazer com o endereço recebido
-- ---------------------------------------------------------------------
create or replace function public.merge_address(p_informado text, p_atual text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_informado is null      then p_atual          -- não veio: mantém
    when trim(p_informado) = ''   then null             -- veio vazio: apaga
    else trim(p_informado)
  end;
$$;

comment on function public.merge_address(text, text) is
  'Nulo mantém o endereço atual; string vazia apaga; texto substitui. '
  'É o que permite corrigir um endereço errado para "nenhum".';

-- ---------------------------------------------------------------------
-- Parque
-- ---------------------------------------------------------------------
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

  if (p_latitude is null) <> (p_longitude is null) then
    raise exception 'Informe latitude e longitude juntas.' using errcode = 'NQ024';
  end if;

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
      public.merge_address(p_address, null),
      p_latitude, p_longitude, nullif(trim(p_tone_color), ''), nullif(trim(p_photo_alt), '')
    )
    returning * into v_row;
  else
    update public.parks set
      name       = coalesce(nullif(trim(p_name), ''), name),
      district   = coalesce(nullif(trim(p_district), ''), district),
      city       = coalesce(nullif(trim(p_city), ''), city),
      address    = public.merge_address(p_address, address),
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
-- Quadra
-- ---------------------------------------------------------------------
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

  if (p_latitude is null) <> (p_longitude is null) then
    raise exception 'Informe latitude e longitude juntas.' using errcode = 'NQ024';
  end if;

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
      -- Sem endereço informado, a quadra nasce com o do parque; com o
      -- campo apagado de propósito, nasce sem nenhum.
      public.merge_address(p_address, v_park.address),
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
      address      = public.merge_address(p_address, address),
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

revoke all on function public.merge_address(text, text) from public;
grant execute on function public.merge_address(text, text) to authenticated;
