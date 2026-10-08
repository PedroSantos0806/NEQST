-- =====================================================================
-- NEQST — Sprint 2
-- 14. Web Push para a versão web
--
-- A Expo Push API cobre o app da Play Store (FCM) e da App Store
-- (APNs), mas não entrega em navegador. O PWA usa o Web Push padrão
-- (RFC 8291 + VAPID), que tem outro formato de credencial: endpoint do
-- push service do navegador + duas chaves por subscription.
-- =====================================================================

create table if not exists public.web_push_subscriptions (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  endpoint      text not null unique,
  p256dh        text not null,
  auth          text not null,
  user_agent    text,
  is_active     boolean not null default true,
  last_seen_at  timestamptz not null default now(),
  failure_count integer not null default 0,
  created_at    timestamptz not null default now(),

  constraint web_push_endpoint_https check (endpoint ~ '^https://'),
  constraint web_push_keys_length    check (char_length(p256dh) between 1 and 255
                                        and char_length(auth)   between 1 and 255)
);

comment on table public.web_push_subscriptions is
  'Subscriptions de Web Push (navegador). O equivalente de push_tokens para a versão web.';
comment on column public.web_push_subscriptions.endpoint is
  'URL do push service do navegador (FCM, Mozilla, WNS). Identifica a subscription.';

create index if not exists web_push_user_idx
  on public.web_push_subscriptions (user_id) where is_active;

-- ---------------------------------------------------------------------
-- O usuário tem algum canal de push? (app ou navegador)
-- ---------------------------------------------------------------------
create or replace function public.has_push_channel(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.push_tokens t
    where t.user_id = p_user_id and t.is_active
  ) or exists (
    select 1 from public.web_push_subscriptions w
    where w.user_id = p_user_id and w.is_active
  );
$$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.web_push_subscriptions enable row level security;

drop policy if exists "web push: dono lê" on public.web_push_subscriptions;
create policy "web push: dono lê"
  on public.web_push_subscriptions for select
  to authenticated
  using (user_id = auth.uid());

drop policy if exists "web push: dono remove" on public.web_push_subscriptions;
create policy "web push: dono remove"
  on public.web_push_subscriptions for delete
  to authenticated
  using (user_id = auth.uid());

revoke all on public.web_push_subscriptions from anon, authenticated;
grant select, delete on public.web_push_subscriptions to authenticated;

-- Só o backend (service_role) usa: para o cliente, saber se OUTRO
-- usuário tem push registrado não serve a nada e vaza informação.
revoke all on function public.has_push_channel(uuid) from public, anon, authenticated;
