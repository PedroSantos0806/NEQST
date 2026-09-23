-- =====================================================================
-- NEQST — Sprint 1
-- 00. Extensões, schemas auxiliares e tipos enumerados
-- =====================================================================

create schema if not exists extensions;

create extension if not exists pgcrypto  with schema extensions;
create extension if not exists citext     with schema extensions;
create extension if not exists pg_trgm    with schema extensions;

-- ---------------------------------------------------------------------
-- Tipos enumerados
-- ---------------------------------------------------------------------

-- Papel do usuário dentro do produto.
do $$ begin
  create type public.app_role as enum ('player', 'staff', 'admin');
exception when duplicate_object then null; end $$;

-- Status operacional da quadra (US-04).
do $$ begin
  create type public.court_status as enum ('available', 'in_game', 'unavailable');
exception when duplicate_object then null; end $$;

-- Modalidade da entrada na fila (US-03).
do $$ begin
  create type public.queue_mode as enum ('single', 'double');
exception when duplicate_object then null; end $$;

-- Ciclo de vida de um time na fila:
--   waiting   -> aguardando na fila
--   ready     -> chamado ("Prepare-se!" / próximo a entrar)
--   playing   -> em quadra
--   done      -> partida encerrada
--   cancelled -> saiu da fila por vontade própria
--   expired   -> removido por inatividade / não compareceu
do $$ begin
  create type public.queue_entry_status as enum
    ('waiting', 'ready', 'playing', 'done', 'cancelled', 'expired');
exception when duplicate_object then null; end $$;

-- Papel do jogador dentro de um time da fila.
do $$ begin
  create type public.queue_member_role as enum ('owner', 'partner');
exception when duplicate_object then null; end $$;

-- Tipos de notificação push emitidos pelo backend.
do $$ begin
  create type public.notification_type as enum
    ('queue_almost_ready', 'queue_turn', 'queue_cancelled', 'queue_partner_added');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.notification_status as enum ('pending', 'sent', 'failed');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- Função utilitária: updated_at automático
-- ---------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

comment on function public.set_updated_at() is
  'Trigger BEFORE UPDATE: mantém a coluna updated_at sempre sincronizada.';
