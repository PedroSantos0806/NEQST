-- =====================================================================
-- NEQST — Sprint 3
-- 20. Check-in por NFC, ao lado do QR Code
--
-- O protótipo oferece as duas formas na mesma tela: "Aponte para o QR"
-- e "Aproxime do totem". A tag NFC grava exatamente a mesma URL
-- assinada do QR (registro NDEF do tipo URI), então a validação é a
-- mesma — o que muda é só por onde o payload chegou.
--
-- Guardar o método serve para operação: se um totem for arrancado ou
-- clonado, dá para ver por onde vieram os check-ins daquela quadra.
-- =====================================================================

do $$ begin
  create type public.scan_method as enum ('qr', 'nfc');
exception when duplicate_object then null; end $$;

alter table public.scan_tokens add column if not exists method public.scan_method;

update public.scan_tokens set method = 'qr' where method is null;

alter table public.scan_tokens alter column method set default 'qr';
alter table public.scan_tokens alter column method set not null;

comment on column public.scan_tokens.method is
  'Por onde o payload chegou: QR Code impresso ou tag NFC.';

create index if not exists scan_tokens_method_idx
  on public.scan_tokens (court_id, method, created_at desc);

-- Quais métodos cada quadra oferece — a tela esconde a aba que não
-- existe naquela quadra em vez de oferecer um totem inexistente.
alter table public.courts add column if not exists has_qr_code boolean not null default true;
alter table public.courts add column if not exists has_nfc_tag boolean not null default false;

comment on column public.courts.has_nfc_tag is
  'Se existe totem NFC instalado nesta quadra.';

do $$ begin
  alter table public.courts
    add constraint courts_needs_one_checkin_method
    check (has_qr_code or has_nfc_tag);
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- Uso dos métodos por quadra (operação)
-- ---------------------------------------------------------------------
create or replace function public.court_checkin_methods(p_court_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'court_id', c.id,
    'qr',  jsonb_build_object(
      'available', c.has_qr_code,
      'scans_7d', (select count(*) from public.scan_tokens t
                    where t.court_id = c.id and t.method = 'qr'
                      and t.created_at > now() - interval '7 days')
    ),
    'nfc', jsonb_build_object(
      'available', c.has_nfc_tag,
      'scans_7d', (select count(*) from public.scan_tokens t
                    where t.court_id = c.id and t.method = 'nfc'
                      and t.created_at > now() - interval '7 days')
    )
  )
  from public.courts c
  where c.id = p_court_id;
$$;

grant execute on function public.court_checkin_methods(uuid) to authenticated;
