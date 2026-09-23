-- =====================================================================
-- NEQST — Sprint 1
-- 05. Push notifications  (US-03 — "Prepare-se!")
--
-- O banco apenas enfileira a notificação (outbox). O envio efetivo é
-- feito pela Edge Function `dispatch-notifications`, que fala com a
-- Expo Push API (FCM no Android + APNs no iOS).
-- =====================================================================

create table if not exists public.push_tokens (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  token         text not null unique,
  platform      text not null check (platform in ('ios', 'android', 'web')),
  device_name   text,
  is_active     boolean not null default true,
  last_seen_at  timestamptz not null default now(),
  created_at    timestamptz not null default now(),

  constraint push_tokens_expo_format
    check (token ~ '^(ExponentPushToken\[.+\]|ExpoPushToken\[.+\])$')
);

comment on table public.push_tokens is 'Tokens Expo Push por device. Um usuário pode ter vários.';

create index if not exists push_tokens_user_idx on public.push_tokens (user_id) where is_active;

-- ---------------------------------------------------------------------
-- Outbox de notificações
-- ---------------------------------------------------------------------
create table if not exists public.notification_outbox (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references auth.users (id) on delete cascade,
  entry_id       uuid references public.queue_entries (id) on delete cascade,
  court_id       uuid references public.courts (id) on delete cascade,
  type           public.notification_type not null,
  title          text not null,
  body           text not null,
  data           jsonb not null default '{}'::jsonb,
  status         public.notification_status not null default 'pending',
  attempts       integer not null default 0,
  last_error     text,
  scheduled_for  timestamptz not null default now(),
  sent_at        timestamptz,
  created_at     timestamptz not null default now()
);

comment on table public.notification_outbox is
  'Fila de pushes a enviar. Garante entrega mesmo se a Edge Function estiver indisponível no momento do evento.';

create index if not exists notification_outbox_pending_idx
  on public.notification_outbox (scheduled_for)
  where status = 'pending';

create index if not exists notification_outbox_user_idx
  on public.notification_outbox (user_id, created_at desc);

-- Evita duplicar o mesmo aviso para o mesmo time.
create unique index if not exists notification_outbox_unique_event
  on public.notification_outbox (entry_id, user_id, type)
  where entry_id is not null;

-- ---------------------------------------------------------------------
-- Enfileira uma notificação para todos os jogadores de um time
-- ---------------------------------------------------------------------
create or replace function public.enqueue_team_notification(
  p_entry_id uuid,
  p_type     public.notification_type,
  p_title    text,
  p_body     text,
  p_data     jsonb default '{}'::jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_inserted integer;
begin
  insert into public.notification_outbox (user_id, entry_id, court_id, type, title, body, data)
  select m.user_id, m.entry_id, m.court_id, p_type, p_title, p_body, p_data
  from public.queue_entry_members m
  where m.entry_id = p_entry_id
  on conflict do nothing;

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$$;
