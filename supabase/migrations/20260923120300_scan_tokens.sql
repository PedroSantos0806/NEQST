-- =====================================================================
-- NEQST — Sprint 1
-- 03. Tokens de escaneamento  (US-02)
--
-- O QR Code impresso na quadra é estático e assinado (HMAC-SHA256).
-- O "timeout de 30s" do critério de aceite é implementado como um
-- token de escaneamento de uso único, emitido pela Edge Function
-- `scan-court` somente após validar assinatura + proximidade. Sem esse
-- token, `join_queue` recusa a entrada — o que impede reuso offline de
-- uma foto do QR Code tirada longe da quadra.
-- =====================================================================

create table if not exists public.scan_tokens (
  id               uuid primary key default gen_random_uuid(),
  token_hash       text not null unique,
  user_id          uuid not null references auth.users (id) on delete cascade,
  court_id         uuid not null references public.courts (id) on delete cascade,
  latitude         double precision not null,
  longitude        double precision not null,
  accuracy_meters  double precision,
  distance_meters  double precision not null,
  expires_at       timestamptz not null,
  consumed_at      timestamptz,
  consumed_by_entry uuid,
  created_at       timestamptz not null default now()
);

comment on table  public.scan_tokens is
  'Prova de presença de uso único (TTL padrão 30s) emitida após validar QR Code + distância.';
comment on column public.scan_tokens.token_hash is
  'SHA-256 hex do token. O valor em claro só existe na resposta HTTP e no device.';

create index if not exists scan_tokens_user_idx    on public.scan_tokens (user_id, created_at desc);
create index if not exists scan_tokens_expiry_idx  on public.scan_tokens (expires_at) where consumed_at is null;

-- ---------------------------------------------------------------------
-- Hash determinístico do token (mesmo algoritmo usado na Edge Function)
-- ---------------------------------------------------------------------
create or replace function public.hash_scan_token(p_token text)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex');
$$;

-- ---------------------------------------------------------------------
-- Limpeza de tokens vencidos (chamada por cron / Edge Function)
-- ---------------------------------------------------------------------
create or replace function public.purge_expired_scan_tokens(p_older_than interval default '1 day')
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_deleted integer;
begin
  delete from public.scan_tokens
  where created_at < now() - p_older_than;
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;
