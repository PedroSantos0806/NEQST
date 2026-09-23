-- =====================================================================
-- NEQST — dados de exemplo para ambiente local / staging
-- Não executar em produção.
-- =====================================================================

insert into public.courts
  (slug, name, description, address, city, latitude, longitude, status, average_match_minutes)
values
  ('quadra-central',  'Quadra Central',    'Saibro, iluminação noturna', 'Av. Paulista, 1000', 'São Paulo', -23.561414, -46.655881, 'available',   20),
  ('quadra-norte',    'Quadra Norte',      'Piso rápido, coberta',       'R. das Palmeiras, 55', 'São Paulo', -23.545000, -46.640000, 'available',   25),
  ('quadra-sul',      'Quadra Sul',        'Saibro',                     'R. Domingos de Morais, 300', 'São Paulo', -23.600000, -46.639000, 'unavailable', 20)
on conflict (slug) do nothing;
