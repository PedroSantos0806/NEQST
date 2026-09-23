-- =====================================================================
-- NEQST — Sprint 1
-- 09. Rotinas de manutenção e suporte ao worker de push
-- =====================================================================

-- Usada pela Edge Function `dispatch-notifications` quando um envio falha.
create or replace function public.increment_notification_attempts(
  p_ids   uuid[],
  p_error text default null
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  update public.notification_outbox
     set attempts   = attempts + 1,
         last_error = left(coalesce(p_error, ''), 500),
         status     = case when attempts + 1 >= 5 then 'failed'::public.notification_status
                           else 'pending'::public.notification_status end,
         -- backoff exponencial simples: 10s, 20s, 40s, 80s
         scheduled_for = now() + make_interval(secs => least(10 * power(2, attempts)::integer, 300))
   where id = any(p_ids);

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.increment_notification_attempts(uuid[], text) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Rotina de manutenção agregada (chamada por cron)
-- ---------------------------------------------------------------------
create or replace function public.run_maintenance()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_expired integer;
  v_purged  integer;
begin
  v_expired := public.expire_stale_queue_entries();
  v_purged  := public.purge_expired_scan_tokens();

  delete from public.notification_outbox
  where status in ('sent', 'failed') and created_at < now() - interval '30 days';

  return jsonb_build_object(
    'expired_entries', v_expired,
    'purged_scan_tokens', v_purged,
    'ran_at', now()
  );
end;
$$;

revoke all on function public.run_maintenance() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Agendamento (opcional — requer pg_cron habilitado no projeto Supabase)
--
-- Habilite em Dashboard > Database > Extensions (pg_cron, pg_net) e
-- rode o bloco abaixo trocando <PROJECT_REF> e <CRON_SECRET>:
--
--   select cron.schedule(
--     'neqst-dispatch-notifications', '10 seconds',
--     $cron$
--       select net.http_post(
--         url     := 'https://<PROJECT_REF>.supabase.co/functions/v1/dispatch-notifications',
--         headers := jsonb_build_object(
--                      'Content-Type', 'application/json',
--                      'x-cron-secret', '<CRON_SECRET>'),
--         body    := '{}'::jsonb
--       );
--     $cron$);
--
--   select cron.schedule('neqst-maintenance', '*/15 * * * *',
--                        $cron$ select public.run_maintenance(); $cron$);
-- ---------------------------------------------------------------------
