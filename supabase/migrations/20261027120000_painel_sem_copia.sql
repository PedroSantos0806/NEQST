-- =====================================================================
-- O painel de administração deixa de ser copiado inteiro a cada mudança
--
-- `admin_overview` já foi recriada por inteiro em SEIS migrations. Cada
-- campo novo obrigava a recopiar ~90 linhas de `jsonb_build_object`, e
-- foi assim que o endereço se perdeu: o ramo dos grupos partiu de uma
-- cópia anterior ao endereço, somou `call_window_seconds` e, rodando
-- por último, apagou `address` do painel.
--
-- A forma de uma quadra e a de um parque passam a morar em duas funções
-- pequenas. Quem acrescentar um campo amanhã mexe numa linha de uma
-- delas, e as duas não podem divergir porque só existe uma de cada.
-- =====================================================================

-- ---------------------------------------------------------------------
-- A forma de uma quadra no painel
--
-- SECURITY INVOKER de propósito: chamada de dentro de `admin_overview`,
-- que é DEFINER, ela já roda com os privilégios de lá. Sozinha, não dá
-- a ninguém nada que o RLS não desse.
-- ---------------------------------------------------------------------
create or replace function public.admin_court_json(c public.courts)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
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
  );
$$;

comment on function public.admin_court_json(public.courts) is
  'Forma de uma quadra na tela de administração. Campo novo no painel '
  'entra AQUI, não numa cópia de admin_overview.';

-- ---------------------------------------------------------------------
-- A forma de um parque, com as quadras dentro
-- ---------------------------------------------------------------------
create or replace function public.admin_park_json(p public.parks)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id',         p.id,
    'slug',       p.slug::text,
    'name',       p.name,
    'district',   p.district,
    'city',       p.city,
    'address',    p.address,
    'latitude',   p.latitude,
    'longitude',  p.longitude,
    'tone_color', p.tone_color,
    'photo_alt',  p.photo_alt,
    'is_active',  p.is_active,
    'courts', coalesce((
      select jsonb_agg(public.admin_court_json(c) order by c.court_number)
      from public.courts c where c.park_id = p.id
    ), '[]'::jsonb)
  );
$$;

comment on function public.admin_park_json(public.parks) is
  'Forma de um parque na tela de administração, com as quadras dentro.';

-- ---------------------------------------------------------------------
-- E o painel vira o que sempre devia ter sido: uma lista
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
    'parks', coalesce(
      (select jsonb_agg(public.admin_park_json(p) order by p.name) from public.parks p),
      '[]'::jsonb
    ),
    'totals', jsonb_build_object(
      'parks',  (select count(*) from public.parks),
      'courts', (select count(*) from public.courts),
      'users',  (select count(*) from public.profiles)
    )
  );
end;
$$;

revoke all on function public.admin_court_json(public.courts) from public;
revoke all on function public.admin_park_json(public.parks)   from public;
grant execute on function public.admin_court_json(public.courts) to authenticated;
grant execute on function public.admin_park_json(public.parks)   to authenticated;
