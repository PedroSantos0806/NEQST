-- =====================================================================
-- NEQST — Sprint 4
-- 25. Tipos novos dos grupos na fila
--
-- Separado da migration seguinte de propósito: um valor novo de enum
-- não pode ser usado na mesma transação que o criou, e o Supabase roda
-- cada migration numa transação.
-- =====================================================================

-- Pedido para entrar no grupo de alguém que já está na fila.
do $$ begin
  create type public.join_request_status as enum
    ('pending', 'approved', 'rejected', 'cancelled', 'expired');
exception when duplicate_object then null; end $$;

-- Pushes do fluxo de grupo: o dono recebe o pedido, quem pediu recebe
-- a resposta.
alter type public.notification_type add value if not exists 'group_join_request';
alter type public.notification_type add value if not exists 'group_join_approved';

-- O grupo devolveu a quadra antes do fim do turno.
alter type public.match_end_reason add value if not exists 'finished_by_group';
