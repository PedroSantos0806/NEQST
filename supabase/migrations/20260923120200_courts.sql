-- =====================================================================
-- NEQST — Sprint 1
-- 02. Quadras + geolocalização  (US-02 / US-04)
-- =====================================================================

create table if not exists public.courts (
  id                      uuid primary key default gen_random_uuid(),
  slug                    extensions.citext not null unique,
  name                    text not null,
  description             text,
  address                 text,
  city                    text,
  latitude                double precision not null check (latitude between -90 and 90),
  longitude               double precision not null check (longitude between -180 and 180),
  status                  public.court_status not null default 'available',
  is_active               boolean not null default true,

  -- Regras de proximidade (US-02)
  max_distance_meters     integer not null default 1000 check (max_distance_meters between 10 and 20000),
  gps_tolerance_meters    integer not null default 200  check (gps_tolerance_meters between 0 and 2000),

  -- Base para o tempo estimado de espera (US-03)
  average_match_minutes   integer not null default 20 check (average_match_minutes between 1 and 240),

  -- Versão do segredo usado para assinar o QR Code impresso (US-02)
  qr_secret_version       integer not null default 1 check (qr_secret_version > 0),
  qr_rotated_at           timestamptz,

  opens_at                time,
  closes_at               time,
  photo_url               text,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),

  constraint courts_name_length check (char_length(name) between 2 and 120),
  constraint courts_slug_format check (slug ~ '^[a-z0-9-]{3,60}$')
);

comment on table  public.courts is 'Quadras de tênis atendidas pelo app.';
comment on column public.courts.max_distance_meters is
  'Raio máximo (US-02: 1 km) dentro do qual o jogador pode entrar na fila.';
comment on column public.courts.gps_tolerance_meters is
  'Margem extra (US-02: +200 m) aplicada quando o GPS reporta baixa precisão.';
comment on column public.courts.qr_secret_version is
  'Permite rotacionar o segredo de assinatura sem reimprimir todos os QR Codes de uma vez.';

create index if not exists courts_active_status_idx on public.courts (is_active, status);
create index if not exists courts_latlng_idx        on public.courts (latitude, longitude);

drop trigger if exists courts_set_updated_at on public.courts;
create trigger courts_set_updated_at
  before update on public.courts
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------
-- Distância Haversine em metros (US-02)
-- ---------------------------------------------------------------------
create or replace function public.haversine_meters(
  p_lat1 double precision,
  p_lng1 double precision,
  p_lat2 double precision,
  p_lng2 double precision
)
returns double precision
language sql
immutable
parallel safe
set search_path = ''
as $$
  select 2 * 6371000 * asin(
    sqrt(
      power(sin(radians(p_lat2 - p_lat1) / 2), 2) +
      cos(radians(p_lat1)) * cos(radians(p_lat2)) *
      power(sin(radians(p_lng2 - p_lng1) / 2), 2)
    )
  );
$$;

comment on function public.haversine_meters is
  'Distância ortodrômica em metros entre dois pontos (raio médio da Terra = 6.371.000 m).';

-- ---------------------------------------------------------------------
-- Raio efetivo aceito para uma quadra, considerando a precisão do GPS
-- ---------------------------------------------------------------------
create or replace function public.court_allowed_radius_meters(
  p_court_id        uuid,
  p_accuracy_meters double precision default null
)
returns double precision
language sql
stable
set search_path = ''
as $$
  select c.max_distance_meters
       + least(coalesce(p_accuracy_meters, 0), c.gps_tolerance_meters)
  from public.courts c
  where c.id = p_court_id;
$$;
