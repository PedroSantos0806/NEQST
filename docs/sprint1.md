# Sprint 1 — o que o backend entrega

Rastreabilidade entre os critérios de aceite do documento de planejamento
e o código deste repositório. O que é de frontend/mobile está marcado
como tal — o backend entrega o contrato que a tela consome.

## US-01 — Criação de conta e login (8 pts)

| Critério | Onde |
|---|---|
| Cadastro via e-mail + senha com validação | Supabase Auth (`supabase.auth.signUp`); política de senha no Dashboard |
| Login social Google e Apple | Supabase Auth Providers — `supabase/config.toml` + [deploy.md](deploy.md#2-autenticação-us-01) |
| JWT no Keychain/Keystore | App (`expo-secure-store`) — backend emite o JWT |
| Perfil com nome, avatar e data de cadastro | `public.profiles` + trigger `on_auth_user_created` |
| Esqueci minha senha por e-mail | `supabase.auth.resetPasswordForEmail()` + template configurado |

Nota técnica da sprint ("avaliar Supabase ou Firebase para reduzir backend
customizado") atendida: nenhuma linha de código de autenticação própria.

## US-02 — QR Code e validação de proximidade (13 pts)

| Critério | Onde |
|---|---|
| Câmera nativa ao tocar em "Escanear quadra" | App (`expo-camera`) |
| QR com ID único da quadra + hash de segurança | `_shared/qr.ts` — HMAC-SHA256 sobre `v<versão>:<courtId>` |
| Permissão de localização + distância por Haversine | `_shared/geo.ts` e `public.haversine_meters` |
| `> 1 km` ⇒ "Você está longe demais desta quadra" | `scan-court` → `TOO_FAR_FROM_COURT` (mensagem literal) |
| `≤ 1 km` + QR válido ⇒ tela da fila | `scan-court` 200 com `court` e `scanToken` |
| Timeout de 30s para evitar reuso offline | `scan_tokens` — uso único, TTL 30s ([qr-codes.md](qr-codes.md#e-o-timeout-de-30s-do-critério-de-aceite)) |
| One-shot GPS, não `watchPosition` | API pede uma coordenada por chamada; nenhum stream |
| QR gerados no admin/backend e impressos | `admin-court-qr` + `scripts/generate-qr.ts` |
| Tolerância de +200 m configurável | `courts.gps_tolerance_meters` (default 200) |

## US-03 — Entrar e gerenciar a fila (13 pts)

| Critério | Onde |
|---|---|
| Escolher "Individual" ou "Dupla (2x2)" | `join_queue(p_mode)` — enum `queue_mode` |
| Dupla por `@username` ou e-mail do parceiro | `join_queue(p_partner)` — busca em `profiles.username`/`email` |
| Posição, times na frente e espera estimada | `queue_entry_state` / `court_queue` |
| Push quando restar 1 time na frente | `refresh_queue_notifications` → "Prepare-se!" |
| Sair da fila a qualquer momento | `leave_queue` (a confirmação é da tela) |
| Tempo real via WebSocket ou polling 10s | Realtime em `queue_entries` + `queue-status` como fallback |
| Reconnect após queda de rede | `my_active_entries()` + reconexão do `supabase-js` |
| FCM + APNs via Expo Notifications | `dispatch-notifications` → Expo Push API |

Além do "Prepare-se!", o backend envia "É a sua vez!" quando não há mais
ninguém na frente, e avisa o parceiro quando ele é adicionado a uma dupla.

## US-04 — Tela da quadra (3 pts)

| Critério | Onde |
|---|---|
| Nome e status (Livre / Em jogo / Indisponível) | `courts.status` — `available` / `in_game` / `unavailable` |
| Contador de times aguardando | `court_queue.teams_waiting` |
| Botão desabilitado se indisponível | `court_queue.can_join` |
| Carregar em menos de 2s no 3G | Uma chamada RPC; resposta com cache de 10s em `queue-status` |
| Loading e erro tratados | Erros com `code` estável ([api.md](api.md)) |
| Cache local de 60s | App (MMKV/AsyncStorage) — resposta traz `generated_at` |

## US-05 — Infraestrutura (3 pts)

Majoritariamente mobile (EAS Build, TestFlight, Play Console). A parte de
backend:

| Critério | Onde |
|---|---|
| CI/CD básico | `.github/workflows/ci.yml` |
| Ambientes dev / staging / produção | Um projeto Supabase por ambiente ([deploy.md](deploy.md)) |
| `.env` + secrets do CI | `.env.example` + `supabase secrets set` |
| README com setup ≤ 15 min | [`README.md`](../README.md#setup-local-meta-do-dod-15-minutos) |

## Definition of Done — o que o backend já cumpre

- ✅ Variáveis sensíveis fora do código (`.env.example`, `.gitignore`, secrets)
- ✅ Sem erros no console: `deno check`, `deno lint`, `deno fmt --check` limpos
- ✅ Comportamento com sinal fraco documentado ([architecture.md](architecture.md#resiliência-em-sinal-fraco))
- ✅ Documentação de arquitetura atualizada (`docs/`)
- ⏳ Revisão por outro dev (PR aberto)
- ⏳ Teste em device físico iOS e Android (depende do app)
- ⏳ Área tocável de 44px (frontend)

## Fora do escopo, como combinado

Mapa de calor, avaliação de quadra, fotos e histórico do usuário ficam
para a Sprint 2. O schema atual já registra `started_at`/`ended_at` de
cada partida, então o histórico nasce dos dados que a Sprint 1 produz.
