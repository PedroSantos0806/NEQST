# NEQST CRM

CRM interno do NEQST para gerenciar a venda B2B (parques, clubes, condomínios, anunciantes) e a implantação dos totens. Inspirado no RD Station (CRM + Marketing), com Pipedrive e HubSpot como referência de modelo de dados e de API. **Uso interno: um workspace só, sem cobrança nem multi-tenant.**

Docs de referência (fonte da verdade do produto):
- Estudo base (plataforma, integrações, modelo de dados, sprints): https://claude.ai/artifact/HJq3J4ckSvNwbNQQy4PbMo
- Pipelines (funis, etapas, critérios de saída, objeto Local): https://claude.ai/artifact/Mktoo2X6frf1mQaAjT7a8t

---

## Stack

| Camada | Tecnologia |
| --- | --- |
| Front | React + Vite + TypeScript + Tailwind + shadcn/ui |
| Kanban | dnd-kit |
| Dados no front | TanStack Query + supabase-js |
| Formulários | react-hook-form + zod |
| Banco, auth, storage | Supabase (Postgres, Auth, RLS, Storage, Realtime) |
| Endpoints de webhook | Supabase Edge Functions (Deno) |
| Jobs e automações | pg_cron + Edge Functions; N8N (VPS) só quando fizer sentido |
| WhatsApp | Evolution API (já roda no VPS) |
| E-mail | Gmail API com OAuth da conta NEQST (só follow-up e remarketing, nunca campanha) |
| Prospecção | Modo grátis (padrão, sem faturamento no Google Cloud): leads do OpenStreetMap (Overpass, consultado **no navegador** porque bloqueia o servidor do Supabase) + lead manual + importação de CSV. Se `GOOGLE_PLACES_API_KEY` existir, a busca usa o Places; com `GEMINI_GROUNDING=on`, usa o Gemini com busca no Google. `prospects.source` guarda a origem |
| IA | Gemini API (conta grátis do AI Studio, `gemini-3.8-flash`). Dossiê lê o site do lead; busca no Google (grounding) só com faturamento e `GEMINI_GROUNDING=on`. Chave só em secrets das Edge Functions. Na conta grátis o Google pode usar o conteúdo enviado para melhorar produtos |
| Deploy | Front estático no Easypanel (VPS Hostinger); Supabase na nuvem |

## Comandos

```bash
npm run dev          # front local
npm run build        # build de produção
npm run typecheck    # tsc --noEmit
npm run lint
supabase start       # banco local
supabase db reset    # recria o banco local aplicando todas as migrations + seed
supabase migration new <nome>
supabase gen types typescript --local > src/types/database.ts
supabase functions serve
```

## Estrutura

```
src/
  components/        # UI reutilizável (shadcn em components/ui)
  features/          # uma pasta por domínio: deals, contacts, companies, locations, activities, pipelines, inbox, settings
  lib/               # supabase client, helpers, formatadores
  types/database.ts  # gerado pelo Supabase, nunca editar à mão
supabase/
  migrations/        # SQL versionado
  seed.sql           # funis, etapas, motivos de perda, dados de teste
  functions/         # Edge Functions (webhooks de entrada, envio, jobs)
```

## Convenções (obrigatórias)

- **Banco só por migration.** Nunca alterar schema pelo painel do Supabase. Nunca editar uma migration já aplicada; criar uma nova.
- **RLS ligado em toda tabela**, com policy para `authenticated`. Nenhuma tabela sem policy.
- Banco em `snake_case`, inglês. Interface em **português do Brasil**.
- IDs `uuid` (`gen_random_uuid()`), `created_at`/`updated_at` `timestamptz` em toda tabela; trigger de `updated_at`.
- Valores monetários em `numeric(12,2)`, BRL.
- Campos customizados: definição em `custom_fields`, valor em coluna `custom jsonb` da entidade, chave legível (`snake_case`). Nunca hash.
- Toda mudança relevante gera linha em `timeline_events` (por trigger no banco, não no front).
- Todo evento externo entra primeiro em `inbound_events` (payload bruto) e só depois é processado. Processamento idempotente.
- Segredos (tokens Meta, Google, Evolution, Gmail) só em secrets das Edge Functions ou Supabase Vault. Nunca no front, nunca no repo.
- Depois de mudar o schema: rodar `supabase db reset` e regenerar `types/database.ts`.
- Antes de dizer que terminou: `npm run typecheck` e `npm run lint` passando.
- Um commit por tarefa, mensagem curta em pt-BR.
- Perguntar antes de qualquer coisa destrutiva (drop de tabela/coluna, apagar dados, force push).

## Identidade visual

- Cores: verde-floresta `#2F4629` (estrutura), quase-preto `#0A0E0B` (texto), malva claro `#E6DDE2` (fundo), ocre `#C49051` (ação/destaque). Apoio: sálvia `#74B69D`, azul névoa `#6D9CB7`.
- Tipografia: Bebas Neue (títulos, números, totais de coluna) + Archivo (texto).
- Cantos 8–12 px, sem gradiente, sem sombra pesada. Números grandes estilo placar.

---

## Modelo de dados

| Tabela | Campos principais | Notas |
| --- | --- | --- |
| `profiles` | id (= auth.users.id), nome, email, avatar, papel | Time interno; acesso só por convite |
| `companies` | nome, tipo (`public_operator`, `club`, `condo`, `builder`, `brand`), cnpj, site, owner_id, custom | Organização |
| `locations` | company_id, nome (ex.: Ibirapuera), endereço, nº de quadras, pisos (array), tem_internet, status (`prospect`, `pilot`, `client`) | Objeto próprio do NEQST: operador tem vários parques |
| `contacts` | nome, email, telefone (E.164), company_id, cargo, lifecycle_stage (`lead`, `qualified_lead`, `opportunity`, `customer`), base_legal, origem/UTM, meta_lead_id, owner_id, custom | Lead e contato são a mesma coisa |
| `pipelines` | nome, ordem, tipo (`sales`, `onboarding`) | 4 funis no seed |
| `stages` | pipeline_id, nome, ordem, probabilidade, dias_alerta, campos_obrigatorios (jsonb), criterio_saida (texto) | |
| `deals` | pipeline_id, stage_id, position (numeric), titulo, company_id, valor, n_quadras, preco_quadra, data_prevista, owner_id, status (`open`, `won`, `lost`), lost_reason_id, lost_note, closed_at, stage_entered_at, source_deal_id, custom | Valor = n_quadras × preco_quadra × 12. `source_deal_id` = negócio de venda que gerou a Implantação |
| `deal_locations` | deal_id, location_id | N:N |
| `deal_contacts` | deal_id, contact_id, papel (`decision_maker`, `influencer`, `operational`) | Vários contatos por negócio |
| `lost_reasons` | nome | Seed |
| `activities` | tipo (`task`, `call`, `meeting`, `visit`, `whatsapp`, `email`), titulo, due_at, done_at, deal_id, contact_id, company_id, owner_id | Atividade de negócio herda contato e empresa |
| `notes` | corpo, deal_id/contact_id/company_id, author_id, anexos | |
| `timeline_events` | entidade, entidade_id, tipo (`stage_change`, `status_change`, `note`, `activity_done`, `conversion`, `whatsapp_in`, `whatsapp_out`, `email_out`, `email_in`, `created`), payload jsonb, actor_id | Histórico único; base dos relatórios |
| `custom_fields` | entidade, chave, label, tipo, opcoes, grupo | |
| `inbound_events` | origem (`meta`, `google`, `site`, `webhook`, `evolution`, `gmail`), payload, status, tentativas, erro, processed_at | Fila de entrada reprocessável |
| `external_refs` | entidade, entidade_id, sistema, external_id | Dedupe e idempotência |
| `integrations` | tipo, config jsonb, status | Credenciais ficam no Vault |
| `email_templates` / `email_messages` | modelo, assunto, corpo / contato, status, gmail_message_id, thread_id | |
| `email_suppressions` | email, motivo, data | Checada antes de todo envio |
| `webhook_subscriptions` | url, eventos, segredo, status, falhas_seguidas | Webhooks de saída |
| `prospects` | nome, tipo (mesmo enum de companies), endereço, cidade, uf, site, telefone, google_place_id (único), rating, dados_brutos jsonb, status (`new`, `researching`, `researched`, `qualified`, `discarded`), motivo_descarte, company_id (ao qualificar), busca_id | Fila de leads frios da prospecção |
| `prospect_searches` | consulta, tipo, cidade, total, criado_por | Cada busca feita na tela |
| `prospect_research` | prospect_id, resumo, ganchos jsonb, oportunidades jsonb, decisores jsonb, quadras_estimadas, mensagem_sugerida, fontes jsonb, score (0–100), modelo, custo, gerado_em | Dossiê gerado pela IA; pode ter versões |

Regras de negócio no banco:
- Mudou `stage_id` → atualiza `stage_entered_at` e grava `timeline_events` (`stage_change`).
- Negócio marcado `won` num funil `sales` → cria negócio no funil **Implantação**, etapa "Contrato assinado", com a mesma empresa e locais.
- `lost` exige `lost_reason_id`.
- Campos obrigatórios (`stages.required_fields`, array de chaves: colunas de `deals`, `locations`, `contacts`, `decision_maker`, `custom.<chave>`) valem ao **avançar** para a etapa de destino; voltar etapa nunca bloqueia. Erro `P0422` com as chaves que faltam em `detail`.
- Funil `onboarding` não tem ganho/perda no app; a etapa final é "Em operação".
- Contato que vira oportunidade (lifecycle `opportunity`) pode gerar negócio na 1ª etapa do funil escolhido.

---

## Funis (seed)

Probabilidade em %, alerta em dias parado na etapa. Critério de saída = o que precisa ser verdade para avançar.

### 1. Parques e operadores públicos (`sales`)
| Etapa | Critério de saída | Prob. | Alerta |
| --- | --- | --- | --- |
| Mapeado | Decisor identificado (nome + cargo) e canal de contato | 5 | 14 |
| Primeiro contato | Decisor respondeu | 10 | 7 |
| Apresentação | Reunião feita e próximo passo com data | 20 | 14 |
| Visita técnica | Nº de quadras, internet e ponto do totem validados | 35 | 14 |
| Proposta de piloto | Aceite formal do piloto | 50 | 14 |
| Piloto rodando | Relatório de resultado entregue e reunião feita | 70 | 30 |
| Contrato | Contrato assinado | 90 | 21 |

Piloto gratuito **não** é Ganho: o negócio só fecha no contrato.

### 2. Clubes, condomínios e construtoras (`sales`)
| Etapa | Critério de saída | Prob. | Alerta |
| --- | --- | --- | --- |
| Lead | Contato respondeu | 5 | 7 |
| Qualificado | Nº de quadras, decisor e verba confirmados | 15 | 10 |
| Demo | Demo do totem/tablet feita | 30 | 10 |
| Proposta | Proposta enviada e recebida | 50 | 14 |
| Aprovação interna | Aprovado em diretoria ou assembleia | 75 | 30 |

### 3. Anunciantes e patrocínio (`sales`)
| Etapa | Critério de saída | Prob. | Alerta |
| --- | --- | --- | --- |
| Mapeado | Contato de marketing identificado | 5 | 14 |
| Contato | Resposta da marca | 15 | 7 |
| Mídia kit enviado | Reunião ou pedido de proposta | 35 | 10 |
| Negociação | PI ou contrato assinado | 60 | 14 |

### 4. Implantação (`onboarding`)
| Etapa | Critério de saída | Alerta |
| --- | --- | --- |
| Contrato assinado | Data de instalação combinada | 7 |
| Levantamento | Planta das quadras, ponto elétrico e internet checados | 7 |
| Equipamento | Totem, tablet e chip prontos e configurados | 10 |
| Instalação | Totem ligado e QR fixado em cada quadra | 3 |
| Treinamento | Equipe do local treinada | 7 |
| Go-live | Primeira semana rodando sem suporte | 7 |
| Em operação | Final; renovação vira atividade com data | — |

Motivos de perda (seed): Sem verba, Sem decisor, Escolheu concorrente, Sem resposta, Regras do local não permitem, Timing, Outro.

---

## Funcionalidades-chave (padrões a seguir)

- **Kanban é a tela inicial.** Arrastar card grava etapa e posição (`position` fracionário: média entre vizinhos), com update otimista e rollback se falhar. Total de negócios e valor no topo de cada coluna.
- **Alerta de parado:** `now() - stage_entered_at > stages.dias_alerta` → card muda de cor.
- **Próxima atividade obrigatória:** negócio aberto sem atividade futura é sinalizado; ao mover card, pedir a próxima atividade.
- **Campos obrigatórios por etapa:** bloquear avanço se `stages.campos_obrigatorios` não estiver preenchido.
- **Realtime** no quadro: mudança de um usuário aparece para os outros.

## Integrações

| Integração | Como |
| --- | --- |
| Meta Lead Ads | Webhook `leadgen` da Página manda só `leadgen_id`; buscar o lead no Graph API (`GET /{leadgen_id}`) com token de Página de longa duração. Guardar `meta_lead_id` no contato. Rodar leitura em lote diária de reconciliação (webhook não é 100%). Endpoint precisa responder ao desafio de verificação (`hub.challenge`). |
| Google Ads lead form | POST com `lead_id`, `user_column_data`, `form_id`, `campaign_id`, `gcl_id`, `google_key`. Rejeitar se `google_key` não bater. Ignorar/gravar à parte se `is_test`. |
| Formulário do site / webhook genérico | `POST /functions/v1/inbound/{source}` com token no header. |
| WhatsApp (Evolution) | Webhook de mensagens → `inbound_events` → `timeline_events` do contato (vínculo por telefone E.164). Envio pela ficha via API da Evolution. |
| Gmail | OAuth da conta NEQST, envio via Gmail API, 1 e-mail por contato. Conta grátis: máx. 500 destinatários / 24 h → fila com teto bem abaixo disso (ex.: 300/dia) e espaçamento. Ler respostas pela API e gravar na linha do tempo. Link de descadastro + checar `email_suppressions`. |
| Webhooks de saída | Payload `{ meta: { action, entity, entity_id, timestamp, attempt }, data, previous }` (`previous` = só campos alterados). Header `X-NEQST-Signature` = HMAC-SHA256 de `timestamp + body` com o segredo da assinatura + `X-NEQST-Timestamp`. Retentativas com espera crescente; desativar após falhas seguidas. |

Dedupe na entrada: e-mail (lowercase) e telefone (E.164). Achou → atualiza e registra conversão; não achou → cria contato `lead`.

Implementação (S4): Edge Function `inbound` (pública, `verify_jwt = false`) em `/functions/v1/inbound/{site|webhook|google|meta}` grava o bruto em `inbound_events` e chama `process_inbound_event` (no banco, idempotente: external_ref → e-mail → telefone; só completa campos vazios; conversão na timeline). Tokens próprios (`site_token`, `google_key`, `meta_verify_token`) gerados no Vault; só admin vê na tela Entrada de leads. Meta ainda precisa dos secrets `META_APP_SECRET` e `META_PAGE_TOKEN`. Empresa informada no formulário fica em `contacts.custom.company_name` (não cria empresa, pois falta o tipo). Contato → negócio: `create_deal_from_contact`.

WhatsApp (S5): webhook da Evolution em `/inbound/evolution?token=...` (token no Vault), evento `MESSAGES_UPSERT`. Só mensagens 1:1 de números que já são contatos entram (`process_whatsapp_event`, casa com/sem o 9 do celular via `br_phone_variants`); outros números ficam `ignored` e podem ser reprocessados depois de cadastrar o contato. Grupos/status/canais são descartados. Uma linha de timeline por mensagem (`wa_id` único; o eco do envio não duplica). Envio pela ficha: Edge Function `whatsapp-send` (secrets `EVOLUTION_URL`, `EVOLUTION_API_KEY`, `EVOLUTION_INSTANCE`).

---

## Sprints (1 semana cada)

| Sprint | Entregas | Pronto quando |
| --- | --- | --- |
| **S0 Fundação** | Repo, Supabase local + nuvem, login (Supabase Auth: Google ou link mágico), layout com menu (Funis, Contatos, Empresas, Locais, Tarefas), tokens visuais, deploy no Easypanel | Time loga e vê o app no ar |
| **S1 Dados core** | Migrations de todas as tabelas core + RLS + triggers; seed dos 4 funis e motivos de perda; CRUD de empresa, local e contato | Cadastrar a Urbia com parques e contatos |
| **S2 Kanban** | Quadro dnd-kit, troca de funil, card (empresa, local, nº quadras, valor, dono, dias na etapa, próxima atividade), totais, alerta de parado, campos obrigatórios, modal de perda, Realtime | Mover card grava etapa + histórico e aparece ao vivo para outro usuário |
| **S3 Ficha e atividades** | Ficha do negócio com linha do tempo, notas, tarefas, próxima atividade obrigatória, "Minhas tarefas hoje", vista tabela com filtros | Nenhum negócio aberto sem próxima atividade |
| **S3.5 Prospecção** | Tela Prospecção: busca manual (tipo + cidade) no Google Places → fila de leads frios sem duplicar (`google_place_id`); selecionar lead → dossiê por IA sob demanda (resumo, ganchos, oportunidades, decisores, quadras estimadas, mensagem sugerida, fontes, score); Qualificar (cria empresa + local + negócio em "Mapeado") ou Descartar com motivo. Chaves só em secrets das Edge Functions | Buscar "clubes com quadra de beach tennis em Campinas", pesquisar 3 leads e qualificar 1 que vira negócio no quadro |
| **S4 Entrada de leads** | `inbound_events` + Edge Functions (genérico, site, Meta, Google), dedupe, lifecycle, marcar oportunidade → negócio | Lead de teste do Meta e do Google cai sem duplicar |
| **S5 WhatsApp** | Webhook Evolution → linha do tempo; envio pela ficha | Conversa com um lead aparece inteira na ficha |
| **S6 E-mail + automação** | Gmail OAuth, modelos com variáveis, envio 1:1, fila com teto, leitura de respostas; regra "parado X dias → e-mail + tarefa" (pg_cron) | Remarketing roda sozinho por 1 semana |
| **S7 Relatórios** | Conversão e tempo por etapa, motivos de perda, forecast ponderado; webhooks de saída; backup | Revisão semanal do funil feita só pelo CRM |

Fora do escopo agora: campanhas de e-mail em massa, landing pages, lead scoring de leads de entrada (inbound), segmentação (Fase 3+). O score do dossiê da prospecção é só uma nota de aderência do lead frio.

Ambiente: só Supabase na nuvem (projeto `neqst-crm`), sem Docker/banco local. Comandos do CLI com `--remote` (`npm run db:push`, `db:diff`, `db:types`); não existe `db reset` aqui. Se e-mail virar campanha, plano B é Postal (open source) no VPS com domínio próprio.

## Como trabalhar neste repo

1. Ler este arquivo antes de cada tarefa.
2. Trabalhar uma sprint por vez; dentro dela, uma entrega por vez.
3. Schema primeiro (migration + RLS + tipos), depois UI.
4. Rodar typecheck e lint, testar no navegador, commitar.
5. Se uma decisão de produto não estiver aqui nem nos docs, perguntar em vez de inventar.
