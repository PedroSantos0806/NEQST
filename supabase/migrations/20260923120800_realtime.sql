-- =====================================================================
-- NEQST — Sprint 1
-- 08. Realtime (WebSocket) — fila em tempo real  (US-03 / US-04)
--
-- O app assina `queue_entries` e `courts` filtrando por court_id.
-- Isso substitui o polling de 10s citado no critério de aceite.
-- =====================================================================

alter table public.queue_entries       replica identity full;
alter table public.queue_entry_members replica identity full;
alter table public.courts              replica identity full;

do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'queue_entries'
  ) then
    alter publication supabase_realtime add table public.queue_entries;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'queue_entry_members'
  ) then
    alter publication supabase_realtime add table public.queue_entry_members;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'courts'
  ) then
    alter publication supabase_realtime add table public.courts;
  end if;
end $$;
