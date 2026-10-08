-- =====================================================================
-- NEQST — Sprint 3 (alinhamento com o protótipo de frontend)
-- 15. Parques: o nível acima das quadras
--
-- O protótipo abre numa lista de parques (Ibirapuera, Villa-Lobos,
-- Aclimação, Povo), cada um com várias quadras numeradas e com
-- superfícies diferentes. A quadra deixa de ser a entidade de topo.
-- =====================================================================

do $$ begin
  create type public.court_surface as enum ('clay', 'hard', 'grass');
exception when duplicate_object then null; end $$;

comment on type public.court_surface is
  'clay = saibro, hard = rápida, grass = grama. Rótulo e cor ficam no app.';

create table if not exists public.parks (
  id              uuid primary key default gen_random_uuid(),
  slug            extensions.citext not null unique,
  name            text not null,
  -- "Vila Mariana · Zona Sul" — aparece sob o nome na lista
  district        text,
  city            text,
  address         text,
  latitude        double precision not null check (latitude between -90 and 90),
  longitude       double precision not null check (longitude between -180 and 180),
  -- Cor de fundo do cartão quando não há foto
  tone_color      text check (tone_color is null or tone_color ~ '^#[0-9A-Fa-f]{6}$'),
  photo_url       text,
  photo_alt       text,
  is_active       boolean not null default true,
  opens_at        time,
  closes_at       time,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),

  constraint parks_name_length check (char_length(name) between 2 and 120),
  constraint parks_slug_format check (slug ~ '^[a-z0-9-]{3,60}$')
);

comment on table  public.parks is 'Parque ou complexo esportivo que abriga várias quadras.';
comment on column public.parks.photo_alt is
  'Texto alternativo da foto — o protótipo descreve a imagem ("quadra de saibro").';

create index if not exists parks_active_idx  on public.parks (is_active);
create index if not exists parks_latlng_idx  on public.parks (latitude, longitude);

drop trigger if exists parks_set_updated_at on public.parks;
create trigger parks_set_updated_at
  before update on public.parks
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------
-- A quadra agora pertence a um parque, tem número e superfície
-- ---------------------------------------------------------------------
alter table public.courts add column if not exists park_id      uuid references public.parks (id) on delete cascade;
alter table public.courts add column if not exists court_number smallint;
alter table public.courts add column if not exists surface      public.court_surface;

comment on column public.courts.court_number is
  'Número dentro do parque: o app mostra "Quadra 01", "Quadra 02".';

-- Quadras que existiam antes do conceito de parque ganham um parque
-- derivado dos próprios dados, para a coluna poder virar obrigatória.
do $$
declare
  v_court record;
  v_park  uuid;
  v_slug  text;
begin
  for v_court in
    select id, name, slug, city, address, latitude, longitude
    from public.courts
    where park_id is null
    order by created_at
  loop
    v_slug := left('parque-' || v_court.slug::text, 60);

    select p.id into v_park from public.parks p where p.slug = v_slug::extensions.citext;

    if v_park is null then
      insert into public.parks (slug, name, city, address, latitude, longitude)
      values (v_slug, v_court.name, v_court.city, v_court.address,
              v_court.latitude, v_court.longitude)
      returning id into v_park;
    end if;

    update public.courts
       set park_id = v_park,
           court_number = coalesce(court_number, 1)
     where id = v_court.id;
  end loop;
end $$;

update public.courts set court_number = 1 where court_number is null;
update public.courts set surface = 'clay' where surface is null;

alter table public.courts alter column park_id      set not null;
alter table public.courts alter column court_number set not null;
alter table public.courts alter column surface      set not null;
alter table public.courts alter column surface      set default 'clay';

do $$ begin
  alter table public.courts
    add constraint courts_number_positive check (court_number between 1 and 99);
exception when duplicate_object then null; end $$;

-- Dois "Quadra 01" no mesmo parque confundiriam o jogador na hora de
-- achar a quadra física.
create unique index if not exists courts_number_per_park
  on public.courts (park_id, court_number);

create index if not exists courts_park_idx on public.courts (park_id);

-- ---------------------------------------------------------------------
-- Rótulo da quadra, do jeito que o app mostra
-- ---------------------------------------------------------------------
create or replace function public.court_label(p_number smallint)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'Quadra ' || lpad(p_number::text, 2, '0');
$$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.parks enable row level security;

drop policy if exists "parques: leitura pública" on public.parks;
create policy "parques: leitura pública"
  on public.parks for select
  to anon, authenticated
  using (is_active or public.is_staff());

drop policy if exists "parques: admin gerencia" on public.parks;
create policy "parques: admin gerencia"
  on public.parks for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

revoke all on public.parks from anon, authenticated;
grant select on public.parks to anon, authenticated;

grant execute on function public.court_label(smallint) to anon, authenticated;
