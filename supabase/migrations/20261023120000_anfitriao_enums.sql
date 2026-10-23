-- =====================================================================
-- NEQST — Sprint 5
-- 28. Tipos novos da fila com anfitrião
--
-- Separado da migration seguinte pelo mesmo motivo da Sprint 4: um
-- valor novo de enum não pode ser usado na transação que o criou.
-- =====================================================================

-- Como a presença foi provada:
--   host_invite  o QR na tela de alguém da fila
--   gps          só a localização — o botão "Entrando na quadra" e a
--                abertura da fila, nas quadras sem nada na placa
alter type public.scan_method add value if not exists 'host_invite';
alter type public.scan_method add value if not exists 'gps';

-- Chegou a vez de um grupo sem app: quem organiza a fila marca a entrada.
alter type public.notification_type add value if not exists 'host_offline_called';
