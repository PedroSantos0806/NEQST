-- S3.5 · Prospecção sem custo: leads do OpenStreetMap, manuais e importados de planilha.

alter table public.prospects drop constraint prospects_source_check;
alter table public.prospects
  add constraint prospects_source_check
  check (source in ('google_places', 'gemini_search', 'openstreetmap', 'manual', 'import'));

alter table public.prospects add column osm_id text unique;
comment on column public.prospects.osm_id is 'Elemento do OpenStreetMap (ex.: way/123456). Dedupe da busca no OSM.';

alter table public.prospects add column instagram text;

-- Quantas quadras o mapa mostra dentro do lugar (OSM), antes de qualquer dossiê.
alter table public.prospects add column mapped_courts integer;
alter table public.prospects add column mapped_sports text[] not null default '{}';
