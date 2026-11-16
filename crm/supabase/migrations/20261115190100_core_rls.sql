-- S1 · RLS em todas as tabelas core.
-- Workspace único e interno: todo usuário autenticado (convidado) lê e escreve os dados do CRM.
-- anon não tem nenhuma policy → bloqueado.

do $$
declare t text;
begin
  foreach t in array array[
    'companies', 'locations', 'contacts', 'pipelines', 'stages', 'lost_reasons',
    'deals', 'deal_locations', 'deal_contacts', 'activities', 'notes', 'custom_fields'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy %I on public.%I for all to authenticated using (true) with check (true)',
      t || '_authenticated_all', t
    );
  end loop;
end;
$$;

-- profiles: todos veem o time; cada um edita só o próprio perfil (papel não muda pelo app).
alter table public.profiles enable row level security;

create policy profiles_select on public.profiles
  for select to authenticated using (true);

create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

-- Revogar só a coluna não basta quando há grant de tabela: troca por grant por coluna.
revoke insert, update, delete on public.profiles from authenticated, anon;
grant update (full_name, avatar_url) on public.profiles to authenticated;

-- timeline_events: só leitura pelo app; escrita apenas via triggers (security definer).
alter table public.timeline_events enable row level security;

create policy timeline_events_select on public.timeline_events
  for select to authenticated using (true);
