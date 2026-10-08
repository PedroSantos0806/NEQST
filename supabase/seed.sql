-- =====================================================================
-- NEQST — dados de exemplo para dev / staging
--
-- Reproduz o cenário do protótipo de frontend: quatro parques de São
-- Paulo com quadras numeradas e superfícies diferentes.
-- Não executar em produção.
-- =====================================================================

insert into public.parks (slug, name, district, city, latitude, longitude, tone_color, photo_alt)
values
  ('parque-ibirapuera',  'Parque Ibirapuera',  'Vila Mariana · Zona Sul',
   'São Paulo', -23.587416, -46.657634, '#2F4629', 'quadra de saibro'),
  ('parque-villa-lobos', 'Parque Villa-Lobos', 'Alto de Pinheiros · Zona Oeste',
   'São Paulo', -23.545030, -46.722800, '#39678C', 'quadra entre as árvores'),
  ('parque-aclimacao',   'Parque da Aclimação', 'Aclimação · Centro-Sul',
   'São Paulo', -23.568300, -46.635400, '#7A6339', 'quadra com telado verde'),
  ('parque-do-povo',     'Parque do Povo',     'Itaim Bibi · Zona Oeste',
   'São Paulo', -23.593900, -46.681700, '#B13F16', 'rede e quadra rápida')
on conflict (slug) do nothing;

-- Quadras: numeradas dentro do parque, como o app mostra.
insert into public.courts
  (park_id, court_number, surface, slug, name, latitude, longitude,
   slot_minutes, has_qr_code, has_nfc_tag)
select pk.id, c.number, c.surface::public.court_surface,
       pk.slug || '-q' || c.number, 'Quadra ' || lpad(c.number::text, 2, '0'),
       pk.latitude + c.dlat, pk.longitude + c.dlng,
       c.slot, true, c.nfc
from public.parks pk
join (values
  ('parque-ibirapuera',  1, 'clay',  40, 0.00000,  0.00000, true),
  ('parque-ibirapuera',  2, 'hard',  40, 0.00020,  0.00015, true),
  ('parque-ibirapuera',  3, 'grass', 60, 0.00035, -0.00010, false),
  ('parque-ibirapuera',  4, 'clay',  40, 0.00050,  0.00025, false),
  ('parque-villa-lobos', 1, 'hard',  40, 0.00000,  0.00000, false),
  ('parque-villa-lobos', 2, 'clay',  40, 0.00025,  0.00020, false),
  ('parque-villa-lobos', 3, 'clay',  40, 0.00040, -0.00015, false),
  ('parque-aclimacao',   1, 'grass', 60, 0.00000,  0.00000, false),
  ('parque-aclimacao',   2, 'clay',  40, 0.00018,  0.00012, false),
  ('parque-do-povo',     1, 'hard',  30, 0.00000,  0.00000, false),
  ('parque-do-povo',     2, 'hard',  30, 0.00022, -0.00018, false)
) as c(park_slug, number, surface, slot, dlat, dlng, nfc)
  on c.park_slug = pk.slug::text
on conflict (slug) do nothing;
