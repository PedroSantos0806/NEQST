# NEQST — Backend

Backend do **App de Fila para Quadras de Tênis**, implementando a
[Sprint 1](docs/sprint1.md): criar conta, escanear o QR Code da quadra,
validar proximidade e entrar na fila (individual ou dupla) em tempo real.

Stack: **Supabase** (Postgres + Auth + Realtime + Edge Functions em Deno),
conforme as decisões técnicas recomendadas no documento da sprint.

```
┌──────────────┐   HTTPS   ┌─────────────────┐   RPC/SQL   ┌────────────┐
│ App Expo     │──────────▶│ Edge Functions  │────────────▶│ Postgres   │
│ (RN)         │           │ (Deno)          │             │ + RLS      │
│              │◀──────────│ scan / join /   │             │ + Realtime │
└──────────────┘ WebSocket │ leave / push    │             └────────────┘
       ▲         (Realtime)└─────────────────┘                    │
       │                            │                             │
       └──── push (FCM/APNs) ◀──────┴── Expo Push API ◀── outbox ──┘
```

## Setup local (meta do DoD: ≤ 15 minutos)

```bash
# 1. Pré-requisitos
npm install -g supabase   # CLI do Supabase
# Deno vem embutido no runtime de Edge Functions do Supabase CLI

# 2. Variáveis de ambiente
cp .env.example .env
openssl rand -base64 48 | tr -d '\n' && echo   # -> QR_SIGNING_SECRET
openssl rand -hex 32                            # -> CRON_SECRET

# 3. Banco local (Postgres + Auth + Realtime + Studio em :54323)
supabase start
supabase db reset            # aplica migrations + seed

# 4. Edge Functions
supabase functions serve --env-file .env

# 5. Testes
scripts/test-sql.sh                        # migrations + fluxo da fila
deno test supabase/functions/_shared/      # geolocalização, QR, push
```

## Aplicar o schema num projeto Supabase existente

Duas opções — as duas produzem exatamente o mesmo schema:

**a) Script único** (mais rápido, não exige CLI):
Dashboard → **SQL Editor** → **New query** → cole
[`db/full_setup.sql`](db/full_setup.sql) → **Run**. É idempotente.

**b) Migrations versionadas** (recomendado para o time):

```bash
supabase link --project-ref <PROJECT_REF>
supabase db push
```

Depois, em qualquer um dos casos:

```bash
# Segredos das Edge Functions
supabase secrets set --env-file .env

# Deploy das funções
supabase functions deploy scan-court join-queue leave-queue queue-status \
                          call-next register-push-token admin-court-qr \
                          dispatch-notifications
```

Passo a passo completo (SSO Google/Apple, pg_cron, QR Codes impressos):
[`docs/deploy.md`](docs/deploy.md).

## Estrutura

| Caminho | O que é |
|---|---|
| `supabase/migrations/` | Schema versionado: tabelas, RLS, RPCs, triggers, Realtime |
| `db/full_setup.sql` | Todas as migrations concatenadas (gerado por `scripts/build-full-setup.sh`) |
| `supabase/functions/` | Edge Functions em Deno (API HTTP) |
| `supabase/functions/_shared/` | Haversine, assinatura de QR, scan tokens, Expo Push, tipos |
| `supabase/seed.sql` | Quadras de exemplo para dev/staging |
| `tests/local/` | Testes funcionais em SQL (fluxo completo da fila) |
| `scripts/` | Runner de testes, gerador de QR Codes, build do full_setup |
| `docs/` | Arquitetura, API, banco, deploy, QR Codes |

## API

| Rota | Método | Quem usa | História |
|---|---|---|---|
| `/functions/v1/scan-court` | POST | jogador | US-02 |
| `/functions/v1/join-queue` | POST | jogador | US-03 |
| `/functions/v1/leave-queue` | POST | jogador | US-03 |
| `/functions/v1/queue-status` | GET | jogador (fallback do Realtime) | US-03 / US-04 |
| `/functions/v1/register-push-token` | POST / DELETE | jogador | US-03 |
| `/functions/v1/call-next` | POST | operação da quadra | US-03 |
| `/functions/v1/admin-court-qr` | GET / POST | admin | US-02 |
| `/functions/v1/dispatch-notifications` | POST | cron | US-03 |

Contratos, exemplos de request/response e códigos de erro:
[`docs/api.md`](docs/api.md).

O app também fala direto com o Postgres via `supabase-js` (RPC + Realtime),
sem passar pelas Edge Functions — ver [`docs/api.md`](docs/api.md#rpc-direto).

## Decisões que valem destaque

- **A fila só aceita quem está na quadra.** `join_queue` exige um *scan
  token* de uso único com TTL de 30s, emitido apenas depois que a Edge
  Function conferiu a assinatura do QR Code e a distância (Haversine).
  Uma foto do QR Code tirada em casa não serve.
- **Nenhuma escrita direta na fila.** `queue_entries` e
  `queue_entry_members` não têm `INSERT/UPDATE/DELETE` para `anon` nem
  `authenticated`: tudo passa por funções `SECURITY DEFINER`. As regras de
  ordem, unicidade e presença não dependem do cliente.
- **Tempo real sem polling.** O app assina `queue_entries` via Realtime
  (WebSocket). `queue-status` existe como fallback para sinal fraco.
- **Push confiável.** Notificações vão para um *outbox* transacional; um
  worker (`dispatch-notifications`) entrega via Expo Push com backoff e
  desativa tokens mortos.

## Escopo

Implementado: US-01 (perfis/auth), US-02 (QR + geolocalização), US-03
(fila individual e dupla, tempo real, push), US-04 (dados da quadra).
US-05 é infra de app (EAS Build/TestFlight), fora do backend — o que cabe
aqui (CI, ambientes, `.env`, README) está em `.github/workflows/ci.yml` e
[`docs/deploy.md`](docs/deploy.md).

Fora do escopo da Sprint 1, como definido no documento: histórico do
usuário, avaliação de quadra, fotos e mapa de calor.
