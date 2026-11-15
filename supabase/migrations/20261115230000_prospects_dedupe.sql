-- S3.5 · Busca de leads pelo Gemini (sem Google Places): origem do lead e dedupe por nome + cidade.

alter table public.prospects
  add column source text not null default 'google_places' check (source in ('google_places', 'gemini_search', 'manual')),
  add column dedupe_key text;

comment on column public.prospects.dedupe_key is
  'nome|cidade normalizados (minúsculo, sem acento/pontuação). Dedupe quando não há google_place_id.';

create unique index prospects_dedupe_key_key on public.prospects (dedupe_key) where dedupe_key is not null;
