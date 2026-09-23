-- =====================================================================
-- NEQST — Sprint 1
-- 07. Row Level Security + permissões
--
-- Princípio: leitura direta pelas tabelas (o app usa Realtime), escrita
-- somente via RPC SECURITY DEFINER da migration 06.
-- =====================================================================

alter table public.profiles            enable row level security;
alter table public.courts              enable row level security;
alter table public.scan_tokens         enable row level security;
alter table public.queue_entries       enable row level security;
alter table public.queue_entry_members enable row level security;
alter table public.push_tokens         enable row level security;
alter table public.notification_outbox enable row level security;

-- ---------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------
drop policy if exists "profiles: leitura autenticada" on public.profiles;
create policy "profiles: leitura autenticada"
  on public.profiles for select
  to authenticated
  using (true);

drop policy if exists "profiles: dono atualiza" on public.profiles;
create policy "profiles: dono atualiza"
  on public.profiles for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid() and role = public.current_app_role());

drop policy if exists "profiles: admin gerencia" on public.profiles;
create policy "profiles: admin gerencia"
  on public.profiles for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ---------------------------------------------------------------------
-- courts — leitura pública (a home do app funciona antes do login)
-- ---------------------------------------------------------------------
drop policy if exists "courts: leitura pública" on public.courts;
create policy "courts: leitura pública"
  on public.courts for select
  to anon, authenticated
  using (is_active or public.is_staff());

drop policy if exists "courts: staff atualiza status" on public.courts;
create policy "courts: staff atualiza status"
  on public.courts for update
  to authenticated
  using (public.is_staff())
  with check (public.is_staff());

drop policy if exists "courts: admin gerencia" on public.courts;
create policy "courts: admin gerencia"
  on public.courts for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- ---------------------------------------------------------------------
-- scan_tokens — o dono vê os próprios; ninguém escreve pelo cliente
-- ---------------------------------------------------------------------
drop policy if exists "scan_tokens: dono lê" on public.scan_tokens;
create policy "scan_tokens: dono lê"
  on public.scan_tokens for select
  to authenticated
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------
-- queue_entries / members — a fila é visível para quem está autenticado
-- ---------------------------------------------------------------------
drop policy if exists "queue_entries: leitura autenticada" on public.queue_entries;
create policy "queue_entries: leitura autenticada"
  on public.queue_entries for select
  to authenticated
  using (true);

drop policy if exists "queue_members: leitura autenticada" on public.queue_entry_members;
create policy "queue_members: leitura autenticada"
  on public.queue_entry_members for select
  to authenticated
  using (true);

drop policy if exists "queue_entries: staff gerencia" on public.queue_entries;
create policy "queue_entries: staff gerencia"
  on public.queue_entries for update
  to authenticated
  using (public.is_staff())
  with check (public.is_staff());

-- ---------------------------------------------------------------------
-- push_tokens — cada jogador gerencia os próprios devices
-- ---------------------------------------------------------------------
drop policy if exists "push_tokens: dono lê" on public.push_tokens;
create policy "push_tokens: dono lê"
  on public.push_tokens for select
  to authenticated
  using (user_id = auth.uid());

drop policy if exists "push_tokens: dono registra" on public.push_tokens;
create policy "push_tokens: dono registra"
  on public.push_tokens for insert
  to authenticated
  with check (user_id = auth.uid());

drop policy if exists "push_tokens: dono atualiza" on public.push_tokens;
create policy "push_tokens: dono atualiza"
  on public.push_tokens for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists "push_tokens: dono remove" on public.push_tokens;
create policy "push_tokens: dono remove"
  on public.push_tokens for delete
  to authenticated
  using (user_id = auth.uid());

-- ---------------------------------------------------------------------
-- notification_outbox — leitura apenas do próprio histórico
-- ---------------------------------------------------------------------
drop policy if exists "notifications: dono lê" on public.notification_outbox;
create policy "notifications: dono lê"
  on public.notification_outbox for select
  to authenticated
  using (user_id = auth.uid());

-- =====================================================================
-- Permissões de tabela: nenhuma escrita direta na fila
-- =====================================================================
revoke all on public.queue_entries       from anon, authenticated;
revoke all on public.queue_entry_members from anon, authenticated;
revoke all on public.scan_tokens         from anon, authenticated;
revoke all on public.notification_outbox from anon, authenticated;
revoke all on public.courts              from anon, authenticated;
revoke all on public.profiles            from anon, authenticated;
revoke all on public.push_tokens         from anon, authenticated;

grant select on public.queue_entries       to authenticated;
grant select on public.queue_entry_members to authenticated;
grant select on public.queue_positions     to authenticated;
grant select on public.scan_tokens         to authenticated;
grant select on public.notification_outbox to authenticated;
grant select on public.courts              to anon, authenticated;
grant select, update on public.profiles    to authenticated;
grant select, insert, update, delete on public.push_tokens to authenticated;

-- =====================================================================
-- Execução das RPCs
-- =====================================================================
revoke all on function public.join_queue(text, public.queue_mode, text)        from public;
revoke all on function public.leave_queue(uuid, text)                          from public;
revoke all on function public.start_match(uuid)                                from public;
revoke all on function public.finish_match(uuid)                               from public;
revoke all on function public.call_next(uuid)                                  from public;
revoke all on function public.expire_stale_queue_entries(interval)             from public;
revoke all on function public.purge_expired_scan_tokens(interval)              from public;
revoke all on function public.refresh_queue_notifications(uuid)                from public;
revoke all on function public.enqueue_team_notification(uuid, public.notification_type, text, text, jsonb) from public;
revoke all on function public.generate_unique_username(text)                   from public;

grant execute on function public.join_queue(text, public.queue_mode, text)  to authenticated;
grant execute on function public.leave_queue(uuid, text)                    to authenticated;
grant execute on function public.start_match(uuid)                          to authenticated;
grant execute on function public.finish_match(uuid)                         to authenticated;
grant execute on function public.call_next(uuid)                            to authenticated;
grant execute on function public.court_queue(uuid)                          to anon, authenticated;
grant execute on function public.queue_entry_state(uuid)                    to authenticated;
grant execute on function public.queue_entry_players(uuid)                  to anon, authenticated;
grant execute on function public.my_active_entries()                        to authenticated;
grant execute on function public.nearby_courts(double precision, double precision, double precision, integer)
  to anon, authenticated;
grant execute on function public.haversine_meters(double precision, double precision, double precision, double precision)
  to anon, authenticated;
grant execute on function public.court_allowed_radius_meters(uuid, double precision) to authenticated;
grant execute on function public.current_app_role() to authenticated;
grant execute on function public.is_staff()         to authenticated;
grant execute on function public.is_admin()         to authenticated;
