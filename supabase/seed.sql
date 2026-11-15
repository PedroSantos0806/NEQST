-- Seed do NEQST CRM: 4 funis, etapas e motivos de perda (CLAUDE.md > Funis).
-- Idempotente: pode rodar mais de uma vez (db reset local ou `supabase db push --include-seed`).
-- Probabilidade em %, alert_days = dias parado na etapa até alertar.
-- required_fields fica vazio por enquanto; os campos obrigatórios por etapa entram na S2.

insert into public.pipelines (name, sort_order, type) values
  ('Parques e operadores públicos', 1, 'sales'),
  ('Clubes, condomínios e construtoras', 2, 'sales'),
  ('Anunciantes e patrocínio', 3, 'sales'),
  ('Implantação', 4, 'onboarding')
on conflict (name) do update
  set sort_order = excluded.sort_order, type = excluded.type;

insert into public.stages (pipeline_id, name, sort_order, probability, alert_days, exit_criteria)
select p.id, s.name, s.sort_order, s.probability, s.alert_days, s.exit_criteria
from (values
  ('Parques e operadores públicos', 'Mapeado', 1, 5, 14, 'Decisor identificado (nome + cargo) e canal de contato'),
  ('Parques e operadores públicos', 'Primeiro contato', 2, 10, 7, 'Decisor respondeu'),
  ('Parques e operadores públicos', 'Apresentação', 3, 20, 14, 'Reunião feita e próximo passo com data'),
  ('Parques e operadores públicos', 'Visita técnica', 4, 35, 14, 'Nº de quadras, internet e ponto do totem validados'),
  ('Parques e operadores públicos', 'Proposta de piloto', 5, 50, 14, 'Aceite formal do piloto'),
  ('Parques e operadores públicos', 'Piloto rodando', 6, 70, 30, 'Relatório de resultado entregue e reunião feita'),
  ('Parques e operadores públicos', 'Contrato', 7, 90, 21, 'Contrato assinado'),

  ('Clubes, condomínios e construtoras', 'Lead', 1, 5, 7, 'Contato respondeu'),
  ('Clubes, condomínios e construtoras', 'Qualificado', 2, 15, 10, 'Nº de quadras, decisor e verba confirmados'),
  ('Clubes, condomínios e construtoras', 'Demo', 3, 30, 10, 'Demo do totem/tablet feita'),
  ('Clubes, condomínios e construtoras', 'Proposta', 4, 50, 14, 'Proposta enviada e recebida'),
  ('Clubes, condomínios e construtoras', 'Aprovação interna', 5, 75, 30, 'Aprovado em diretoria ou assembleia'),

  ('Anunciantes e patrocínio', 'Mapeado', 1, 5, 14, 'Contato de marketing identificado'),
  ('Anunciantes e patrocínio', 'Contato', 2, 15, 7, 'Resposta da marca'),
  ('Anunciantes e patrocínio', 'Mídia kit enviado', 3, 35, 10, 'Reunião ou pedido de proposta'),
  ('Anunciantes e patrocínio', 'Negociação', 4, 60, 14, 'PI ou contrato assinado'),

  ('Implantação', 'Contrato assinado', 1, null, 7, 'Data de instalação combinada'),
  ('Implantação', 'Levantamento', 2, null, 7, 'Planta das quadras, ponto elétrico e internet checados'),
  ('Implantação', 'Equipamento', 3, null, 10, 'Totem, tablet e chip prontos e configurados'),
  ('Implantação', 'Instalação', 4, null, 3, 'Totem ligado e QR fixado em cada quadra'),
  ('Implantação', 'Treinamento', 5, null, 7, 'Equipe do local treinada'),
  ('Implantação', 'Go-live', 6, null, 7, 'Primeira semana rodando sem suporte'),
  ('Implantação', 'Em operação', 7, null, null, 'Final; renovação vira atividade com data')
) as s(pipeline_name, name, sort_order, probability, alert_days, exit_criteria)
join public.pipelines p on p.name = s.pipeline_name
on conflict (pipeline_id, name) do update
  set sort_order = excluded.sort_order,
      probability = excluded.probability,
      alert_days = excluded.alert_days,
      exit_criteria = excluded.exit_criteria;

insert into public.lost_reasons (name, sort_order) values
  ('Sem verba', 1),
  ('Sem decisor', 2),
  ('Escolheu concorrente', 3),
  ('Sem resposta', 4),
  ('Regras do local não permitem', 5),
  ('Timing', 6),
  ('Outro', 7)
on conflict (name) do update set sort_order = excluded.sort_order;
