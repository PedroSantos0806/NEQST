# NEQST — Backend

Backend do **App de Fila para Quadras de Tênis**, atendendo a **web** e o
**app da Play Store** com a mesma API:

- [Sprint 1](docs/sprint1.md) — criar conta, escanear o QR Code da
  quadra, validar proximidade e entrar na fila (individual ou dupla) em
  tempo real.
- [Sprint 2](docs/sprint2.md) — histórico do usuário, avaliação da
  quadra, upload de fotos com moderação e mapa de calor cheio/vazio.
- [Sprint 3](docs/sprint3.md) — alinhamento com o protótipo de tela:
  parques acima das quadras, check-in do próprio jogador (QR ou NFC) e
  uma fila por jogador.
- [Sprint 4](docs/sprint4.md) — a vaga é do grupo: uma pessoa guarda o
  lugar e os amigos entram nela escaneando a quadra (o dono aceita, ou
  com o PIN do grupo), turno fixo sem "quem ganha fica", tolerância de 2
  minutos no check-in.
- [Sprint 5](docs/sprint5.md) — a fila com anfitrião: um piloto sem QR
  na placa. A primeira pessoa com o app abre a fila, quem chega depois
  entra pelo QR na tela de quem já está nela, e o painel do piloto conta
  a adesão.

O que difere entre web e app (push, QR Code, CORS, login) está em
[docs/plataformas.md](docs/plataformas.md).

Stack: **Supabase** (Postgres + Auth + Realtime + Edge Functions em Deno),
conforme as decisões técnicas recomendadas no documento da sprint.

```
┌──────────────┐           ┌─────────────────┐   RPC/SQL   ┌────────────┐
│ App Expo     │   HTTPS   │ Edge Functions  │────────────▶│ Postgres   │
│ (Play Store) │──────────▶│ (Deno)          │             │ + RLS      │
├──────────────┤           │ scan / join /   │             │ + Realtime │
│ Web / PWA    │◀──────────│ leave / fotos   │             │ + Storage  │
└──────────────┘ WebSocket │ push / QR       │             └────────────┘
    ▲      ▲    (Realtime) └─────────────────┘                   │
    │      │                        │                            │
    │      └── Web Push (VAPID) ◀───┤                            │
    └───────── Expo Push (FCM/APNs) ┴──────── outbox ◀───────────┘
```

## Setup local (meta do DoD: ≤ 15 minutos)

O repositório tem duas partes: o **backend** (Supabase) na raiz e o
**app web** em [`web/`](web). A Vercel publica o `web/`; o
[`vercel.json`](vercel.json) na raiz já aponta o build para lá.

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
scripts/test-sql.sh                             # migrations + as suítes de tests/local
deno test --allow-env supabase/functions/_shared/  # geo, QR, web push, CORS
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
                          dispatch-notifications register-web-push \
                          court-photo check-in match
```

Passo a passo completo (SSO Google/Apple, pg_cron, QR Codes impressos):
[`docs/deploy.md`](docs/deploy.md).

## Estrutura

| Caminho | O que é |
|---|---|
| `web/` | App web (Vite + React), o que a Vercel publica — ver [docs/web.md](docs/web.md) |
| `supabase/migrations/` | Schema versionado: tabelas, RLS, RPCs, triggers, Realtime |
| `db/full_setup.sql` | Todas as migrations concatenadas (gerado por `scripts/build-full-setup.sh`) |
| `supabase/functions/` | Edge Functions em Deno (API HTTP) |
| `supabase/functions/_shared/` | Haversine, assinatura de QR, scan tokens, Expo Push, tipos |
| `supabase/seed.sql` | Quadras de exemplo para dev/staging |
| `tests/local/` | Testes funcionais em SQL (fila, ordem, Sprints 2, 3 e 4, admin) |
| `scripts/` | Runner de testes, geradores de QR e de chaves VAPID, build do full_setup |
| `docs/` | Arquitetura, API, banco, deploy, QR Codes, plataformas |
| `docs/app-links/` | Modelos de `assetlinks.json` e `apple-app-site-association` |

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
| `/functions/v1/register-web-push` | GET / POST / DELETE | jogador (web) | Sprint 2 |
| `/functions/v1/court-photo` | GET / POST | jogador | Sprint 2 |
| `/functions/v1/check-in` | POST | jogador | Sprint 3 / 4 |
| `/functions/v1/match` | GET / POST | jogador (devolver a quadra) | Sprint 3 / 4 |

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
- **Push confiável nos dois mundos.** Notificações vão para um *outbox*
  transacional; um worker (`dispatch-notifications`) entrega via Expo Push
  (app) **e** Web Push/VAPID (navegador), com backoff e desativação de
  canais mortos. A Expo Push API não entrega em navegador — sem o segundo
  canal, o "Prepare-se!" nunca chegaria para quem usa o site.
- **QR Code que a câmera do celular abre.** O código impresso é um App
  Link `https://<app>/q/<courtId>?v=1&s=<assinatura>`: abre o app da Play
  Store se instalado, senão o site. Um QR com esquema `neqst:` não abre
  nada na câmera nativa.
- **Fotos moderadas.** Upload direto para o Storage por URL assinada
  (sem passar pela função, o que importa no 3G), bucket privado e
  aprovação obrigatória antes de aparecer no app.
- **A vaga é do grupo, e cada um prova que está lá.** Uma pessoa guarda
  o lugar; os amigos entram na mesma vaga escaneando a quadra — pedindo
  (quem abriu aceita) ou com o PIN do grupo. Sem a aprovação, qualquer
  um que escaneasse o QR entraria no grupo do 1º da fila.
- **Turno fixo, sem adversário da fila.** O grupo joga entre si; cada
  vaga vale o slot da quadra, para 1 ou para 8. Num parque público não há
  operador: chamado o grupo, um check-in (QR ou NFC) basta, com 2
  minutos de tolerância — ajustável pelo admin.
- **Uma vaga por pessoa.** Em todo o app, não por quadra. Para entrar no
  grupo do amigo, quem está em outra fila sai dela.

## Escopo

**Sprint 1:** US-01 (perfis/auth), US-02 (QR + geolocalização), US-03
(fila individual e dupla, tempo real, push), US-04 (dados da quadra).
US-05 é infra de app (EAS Build/TestFlight), fora do backend — o que cabe
aqui (CI, ambientes, `.env`, README) está em `.github/workflows/ci.yml` e
[`docs/deploy.md`](docs/deploy.md).

**Sprint 2:** histórico do usuário, avaliação da quadra, upload de fotos
e mapa de calor — mais o que a publicação na web exige do backend
([`docs/plataformas.md`](docs/plataformas.md)).

**Sprint 3:** o modelo que o protótipo de frontend mostrou — parques,
superfícies, check-in do jogador, chamada com prazo, slot rígido, NFC e
a pilha de raquetes ([`docs/sprint3.md`](docs/sprint3.md)). Uma RPC por
tela.

**Sprint 4:** grupos na fila — pedido de entrada com aprovação, PIN do
grupo, saída da fila atual para entrar no grupo do amigo, herança da
vaga, turno fixo e tolerância de check-in configurável
([`docs/sprint4.md`](docs/sprint4.md)).

**Sprint 5:** a fila com anfitrião — modo da quadra sem nada na placa,
vagas sem app, convite que troca a cada 30 s com a distância conferida
na hora de entrar, check-in pelo botão com GPS e a aba Piloto na
administração ([`docs/sprint5.md`](docs/sprint5.md)).

Sugestões que ficaram registradas para depois, em
[`docs/sprint2.md`](docs/sprint2.md#o-que-não-entrou): rate limiting no
`scan-court`, thumbnails das fotos e push pedindo avaliação ao fim da
partida.
