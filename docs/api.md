# API — NEQST Sprint 1

Base: `https://<PROJECT_REF>.supabase.co/functions/v1`

Todas as rotas de jogador exigem o JWT do Supabase Auth:

```http
Authorization: Bearer <access_token>
apikey: <SUPABASE_ANON_KEY>
Content-Type: application/json
```

Erros seguem sempre o mesmo formato:

```json
{ "error": { "code": "TOO_FAR_FROM_COURT", "message": "Você está longe demais desta quadra", "details": { } } }
```

---

## POST /scan-court — validar QR Code ou NFC e proximidade (US-02)

```json
{
  "payload": "https://app.neqst.com.br/q/7c9e6679-7425-40de-944b-e07fc1f90ae7?v=1&s=Yk3f...",
  "latitude": -23.561414,
  "longitude": -46.655881,
  "accuracy": 18.5,
  "method": "qr",
  "purpose": "join"
}
```

`method` é `"qr"` (padrão) ou `"nfc"` — o totem NFC grava a mesma URL
assinada, então a validação é idêntica. `purpose` é `"join"` (padrão) ou
`"start"`: o token serve para os dois, e quem decide é a chamada
seguinte (`/join-queue` ou `/check-in`).

**Sprint 5.** O `payload` também pode ser o convite na tela de alguém da
fila (`https://.../q/h/<código>`): a resposta traz `method:
"host_invite"`, e o convite vencido ou de fila encerrada volta
`HOST_INVITE_EXPIRED` (410) ou `HOST_QUEUE_CLOSED` (409). Nas quadras em
modo anfitrião há ainda `method: "gps"`, sem `payload` e com `courtId`:
serve para `open_host_queue` e para o check-in, nunca para entrar na
fila de alguém ([sprint5.md](sprint5.md)).

`accuracy` é o erro em metros reportado pelo GPS
(`Location.getCurrentPositionAsync` → `coords.accuracy`). Quando presente,
amplia o raio aceito até o teto de tolerância da quadra (padrão +200 m).

**200**

```json
{
  "scanToken": "s3Kf9...",
  "expiresAt": "2026-09-23T18:30:30.000Z",
  "ttlSeconds": 30,
  "distanceMeters": 12,
  "method": "qr",
  "purpose": "join",
  "court": {
    "id": "7c9e6679-7425-40de-944b-e07fc1f90ae7",
    "parkId": "1a2b...",
    "number": 1,
    "name": "Quadra 01",
    "slug": "parque-ibirapuera-q1",
    "surface": "clay",
    "status": "available",
    "slotMinutes": 40,
    "checkinMethods": ["qr", "nfc"]
  }
}
```

O `scanToken` é de **uso único** e vale **30 segundos** — é ele que
habilita `join-queue`. Guarde apenas em memória.

| Código | HTTP | Quando |
|---|---|---|
| `INVALID_QR` | 400 | QR fora do formato ou assinatura inválida |
| `LOCATION_REQUIRED` | 400 | Coordenadas ausentes ou inválidas |
| `QR_REVOKED` | 409 | QR de uma versão antiga do segredo da quadra |
| `COURT_NOT_FOUND` | 404 | Quadra do QR não existe |
| `COURT_UNAVAILABLE` | 409 | Quadra inativa ou marcada como indisponível |
| `TOO_FAR_FROM_COURT` | 403 | Fora do raio — `details` traz `distanceMeters` e `allowedRadiusMeters` |
| `METHOD_UNAVAILABLE` | 409 | Pediu NFC numa quadra sem totem (ou QR numa sem código) |

---

## POST /join-queue — abrir uma vaga na fila (US-03, revisto na Sprint 4)

```json
{ "scanToken": "s3Kf9..." }
```

Quem abre a vaga pode estar sozinho e guarda o lugar do grupo. Os
amigos entram **nessa mesma vaga** depois, cada um escaneando a quadra:
pedindo para entrar (`request_join`, o dono aceita) ou com o PIN do
grupo (`join_with_pin`) — ver [RPCs da Sprint 4](#rpcs-da-sprint-4--grupos).

`mode` ainda é aceito e ignorado. `partner` é recusado com
`PARTNER_MUST_SCAN`: o parceiro pelo @ não provava que a pessoa estava na
quadra.

**201**

```json
{
  "entry_id": "9f1c...",
  "court_id": "7c9e...",
  "court_name": "Quadra Central",
  "status": "waiting",
  "joined_at": "2026-09-23T18:30:12.000Z",
  "started_at": null,
  "position": 2,
  "teams_ahead": 1,
  "estimated_wait_minutes": 40,
  "players": [
    { "user_id": "...", "role": "owner", "username": "ana", "full_name": "Ana Souza", "avatar_url": null }
  ]
}
```

| Código | HTTP | Quando |
|---|---|---|
| `SCAN_TOKEN_REQUIRED` | 400 | Chamou sem escanear |
| `SCAN_TOKEN_INVALID` | 400 | Token expirado (>30s), já usado ou de outro usuário |
| `PARTNER_MUST_SCAN` | 400 | Mandou `partner` — o amigo entra escaneando a quadra |
| `ALREADY_IN_QUEUE` | 409 | Você já está numa vaga desta quadra |
| `ALREADY_IN_ANOTHER_QUEUE` | 409 | Você já está na fila de outra quadra — a mensagem diz qual |
| `COURT_UNAVAILABLE` | 409 | Quadra indisponível |

---

## POST /check-in — check-in na quadra (Sprint 3, revisto na Sprint 4)

```json
{ "scanToken": "s3Kf9..." }
```

Quando o grupo é chamado, **basta um** check-in (QR ou totem NFC) para o
turno começar. Quem é do grupo e chega depois escaneia também: o turno
não reinicia, só fica registrado que a pessoa está em quadra
(`players[].checked_in`). A tolerância depois da chamada é
`court.call_window_seconds` — 2 minutos por padrão, ajustável pelo admin.

**201** devolve o turno (`match_state`):

```json
{
  "match_id": "...",
  "court_name": "Quadra 01",
  "entry_id": "...",
  "group_size": 4,
  "group_label": "4 jogadores",
  "slot_minutes": 40,
  "is_live": true,
  "remaining_seconds": 2398,
  "players": [
    { "user_id": "...", "short_name": "Ana S.", "initials": "AS", "role": "owner", "checked_in": true }
  ]
}
```

| Código | HTTP | Quando |
|---|---|---|
| `NOT_YOUR_TURN` | 409 | Outro grupo está na vez |
| `COURT_BUSY` | 409 | O turno atual ainda tem tempo pela frente |
| `CALL_EXPIRED` | 410 | Passou a tolerância da chamada |
| `SCAN_TOKEN_INVALID` | 400 | Token expirado, já usado ou de outro usuário |

---

## POST / GET /match — devolver a quadra (Sprint 3, revisto na Sprint 4)

```json
{ "matchId": "..." }
```

Qualquer pessoa do grupo em quadra encerra o turno antes do fim
(`end_reason = finished_by_group`) e o próximo da fila é chamado. Não há
vencedor nem "quem ganha fica": cada vaga vale um turno fixo de
`slot_minutes`, para um grupo de qualquer tamanho. Se ninguém encerrar,
o turno acaba sozinho no fim do slot.

`GET /match?matchId=<uuid>` devolve o turno (útil após reconexão).

---

## POST /leave-queue — sair da fila (US-03)

```json
{ "entryId": "9f1c...", "reason": "mudou de ideia" }
```

**200** `{ "entry_id": "9f1c...", "status": "waiting", "left_at": "...", "remaining_members": 3 }`

Sai **quem chamou**, não o grupo inteiro. A vaga continua com quem
ficou — saindo o dono, o membro mais antigo herda — e só some quando
sai o último (`status` vira `cancelled`, ou `done` se o turno estava
rolando, e a vez passa na hora). Confirme com o usuário antes de chamar
(critério de aceite da US-03).

---

## GET /queue-status — estado da quadra (US-03 / US-04)

`GET /queue-status?courtId=<uuid>` ou `GET /queue-status?slug=quadra-central`

Rota pública (não exige login), com `Cache-Control: public, max-age=10`.
É o **fallback** de polling — em condições normais use o Realtime.

**200**

```json
{
  "court": { "id": "...", "slug": "quadra-central", "name": "Quadra Central", "status": "in_game", "is_active": true, "latitude": -23.56, "longitude": -46.65, "average_match_minutes": 20, "photo_url": null, "address": "Av. Paulista, 1000" },
  "can_join": true,
  "teams_waiting": 2,
  "current_match": { "entry_id": "...", "mode": "single", "started_at": "...", "players": [ ] },
  "current_match_remaining_minutes": 7,
  "queue": [
    { "entry_id": "...", "position": 1, "teams_ahead": 1, "estimated_wait_minutes": 7, "mode": "single", "status": "waiting", "joined_at": "...", "players": [ ] }
  ],
  "generated_at": "2026-09-23T18:31:00.000Z"
}
```

`can_join: false` ⇒ botão "Entrar na fila" desabilitado (US-04).

---

## POST / DELETE /register-push-token — device para push (US-03)

```json
{ "token": "ExponentPushToken[xxxxxxxx]", "platform": "ios", "deviceName": "iPhone da Ana" }
```

`DELETE` com `{ "token": "..." }` desativa o device (logout).

---

## POST /call-next — operação da quadra (staff/admin)

```json
{ "courtId": "7c9e..." }                       // encerra a atual e chama a próxima
{ "action": "start",  "entryId": "9f1c..." }   // coloca um time em quadra
{ "action": "finish", "entryId": "9f1c..." }   // encerra a partida
```

Requer `profiles.role` = `staff` ou `admin` (`FORBIDDEN` caso contrário).

---

## GET / POST /admin-court-qr — QR Codes para impressão (admin)

`GET` devolve o payload assinado de cada quadra ativa.
`POST { "courtId": "...", "rotate": true }` incrementa a versão do segredo
e **invalida os QR Codes já impressos** daquela quadra.

Ver [`docs/qr-codes.md`](qr-codes.md).

---

## POST / DELETE / GET /register-web-push — push na web (Sprint 2)

`GET` (sem login) devolve a chave pública VAPID que o front usa em
`pushManager.subscribe({ applicationServerKey })`:

```json
{ "publicKey": "BL3f..." }
```

`POST` registra a subscription do navegador — mande o
`PushSubscription.toJSON()` como veio:

```json
{ "endpoint": "https://fcm.googleapis.com/fcm/send/abc", "keys": { "p256dh": "BI6D...", "auth": "624j..." } }
```

`DELETE` com `{ "endpoint": "..." }` desativa (logout, permissão revogada).

A Expo Push API não entrega em navegador — ver
[`plataformas.md`](plataformas.md#1-push-notifications).

---

## Fotos da quadra (Sprint 2)

### POST /court-photo — pedir URL de upload

```json
{ "courtId": "7c9e...", "contentType": "image/jpeg", "caption": "Quadra 2 ao anoitecer" }
```

**201**

```json
{
  "photoId": "e1f2...",
  "courtId": "7c9e...",
  "storagePath": "7c9e.../a1b2.jpg",
  "uploadUrl": "https://...supabase.co/storage/v1/object/upload/sign/court-photos/...",
  "token": "eyJ...",
  "contentType": "image/jpeg",
  "expiresInSeconds": 300
}
```

O arquivo vai **direto** para `uploadUrl` (`PUT`, com o header
`Content-Type` igual ao declarado) — não passa pela função. Depois:

### POST /court-photo?action=confirm

```json
{ "photoId": "e1f2...", "sizeBytes": 184320, "width": 1080, "height": 1440 }
```

**200** — a foto entra na fila de moderação e só aparece no app depois de
aprovada.

| Código | HTTP | Quando |
|---|---|---|
| `UNSUPPORTED_MEDIA_TYPE` | 415 | Fora de JPEG/PNG/WebP |
| `UPLOAD_NOT_FOUND` | 409 | `confirm` sem o arquivo ter chegado ao Storage |
| `PHOTO_NOT_FOUND` / `FORBIDDEN` | 404 / 403 | Foto inexistente ou de outro usuário |

Cota: 5 fotos pendentes por jogador por quadra (`NQ012`).

### GET /court-photo?courtIds=a,b,c — capas em lote

Para a lista de quadras e o mapa de calor, que devolvem
`cover_photo_path` (um caminho no bucket privado, não uma URL):

```json
{ "covers": { "7c9e...": "https://...signed...", "8d0f...": null }, "expiresInSeconds": 3600 }
```

### GET /court-photo?courtId=&lt;uuid&gt;

Fotos aprovadas com URL assinada de leitura (1h):

```json
{
  "courtId": "7c9e...",
  "photos": [
    { "photo_id": "e1f2...", "url": "https://...", "caption": "...", "is_primary": true, "author": { "username": "ana" } }
  ],
  "expiresInSeconds": 3600
}
```

---

## POST /dispatch-notifications — worker de push (cron)

Header `x-cron-secret: <CRON_SECRET>`. Sem JWT de usuário.
Processa até 200 notificações pendentes por chamada.

**200**

```json
{
  "processed": 12,
  "sent": 11,
  "failed": 1,
  "channels": { "expo_messages": 9, "web_push_subscriptions": 4, "vapid_configured": true },
  "deactivated": { "push_tokens": 1, "web_push": 0 }
}
```

Entrega nos dois canais (Expo para o app, Web Push para o navegador). Uma
notificação conta como enviada se qualquer canal aceitou.

---

## RPC direto

O app pode chamar o Postgres sem passar pelas Edge Functions — mais
rápido e com menos round-trips (relevante em 3G):

```ts
const { data } = await supabase.rpc("court_queue", { p_court_id: courtId });
const { data } = await supabase.rpc("my_active_entries");
const { data } = await supabase.rpc("nearby_courts", {
  p_latitude: coords.latitude,
  p_longitude: coords.longitude,
  p_radius_meters: 5000,
});
const { data } = await supabase.rpc("leave_queue", { p_entry_id: entryId });
```

`join_queue` também é RPC (`p_scan_token`), mas o `scanToken` só existe
depois de `scan-court` — a Edge Function continua sendo o caminho
natural para abrir uma vaga.

### RPCs da Sprint 2

```ts
// Histórico e perfil
await supabase.rpc("my_profile_summary");
await supabase.rpc("my_match_history", { p_limit: 20, p_before: cursor });
await supabase.rpc("my_visited_courts");

// Avaliações
await supabase.rpc("rate_court", { p_court_id: id, p_rating: 4, p_comment: "Saibro ótimo" });
await supabase.rpc("court_reviews_page", { p_court_id: id });
await supabase.rpc("can_review_court", { p_court_id: id });
await supabase.rpc("delete_my_court_review", { p_court_id: id });

// Mapa de calor — lat/lng opcionais (a web abre antes de ter GPS)
await supabase.rpc("courts_heatmap", {
  p_latitude: coords?.latitude ?? null,
  p_longitude: coords?.longitude ?? null,
  p_radius_meters: 5000,
});
await supabase.rpc("court_occupancy_pattern", { p_court_id: id, p_days: 28 });

// Fotos
await supabase.rpc("court_photos_page", { p_court_id: id });

// Operação
await supabase.rpc("pending_court_photos");
await supabase.rpc("moderate_court_photo", { p_photo_id: id, p_approve: true });
await supabase.rpc("set_primary_court_photo", { p_photo_id: id });
```

`courts_heatmap` devolve `occupancy` em `empty` / `low` / `busy` / `full`
— é o indicador cheio/vazio da Sprint 2.

### RPCs da Sprint 3 — uma por tela

```ts
// Lista de parques (lat/lng opcionais: a web abre antes de ter GPS)
await supabase.rpc("parks_overview", {
  p_latitude: coords?.latitude ?? null,
  p_longitude: coords?.longitude ?? null,
  p_radius_meters: 8000,
});

// Home do parque: resumo + todas as quadras já no formato da tela
await supabase.rpc("park_screen", { p_park_id: parkId });

// Tela da quadra: placar, fila em pilha de raquetes, meu estado
await supabase.rpc("court_screen", { p_court_id: courtId });

// O cartão "você está na fila" e a contagem da chamada
await supabase.rpc("my_queue_state");

// Perfil: raquete e tom do avatar
await supabase.rpc("update_my_profile", {
  p_full_name: "Rafael Moura",
  p_frame_color: "#C49051",
  p_grip_color: "#F1ECEF",
  p_avatar_tone: 1,
});

// Paleta disponível (o app não precisa hardcodar as cores)
await supabase.from("racket_palette").select("*").order("sort_order");
```

**Campos que a tela da quadra usa** (`court_screen`):

| Campo | Para quê |
|---|---|
| `court.name` | "Quadra 01" (derivado do número no parque) |
| `court.surface_label` | "Saibro" / "Rápida" / "Grama" |
| `court.checkin_methods` | `["qr"]` ou `["qr","nfc"]` — quais abas mostrar |
| `status_text` | "Em jogo" / "Livre" |
| `players_line` | "Diego M. · Mara C. · Téo L." — o grupo em quadra |
| `match.remaining_seconds` | Cronômetro do slot |
| `queue[].stack` | Raquetes à frente (máx. 5) para desenhar a pilha |
| `queue[].stack_more` | Quantas sobraram atrás da pilha |
| `queue[].is_mine` | Destaca a linha do próprio grupo |
| `queue[].group_label` | "Solo" / "Dupla" / "5 jogadores" |
| `my_group` | Só para quem é do grupo: `pin`, `is_owner`, `players`, `pending_requests` |
| `my_request` | O pedido que eu fiz para entrar num grupo desta quadra |
| `court_accepting` | A quadra aceita entradas |
| `can_join` | **Eu** posso entrar (não estou em outra fila) |
| `my_state` | `free` / `queued` / `playing`, com onde |

### RPCs da Sprint 4 — grupos

Toda entrada num grupo exige um scan novo da quadra do grupo (o mesmo
`scanToken` de `scan-court`): é a prova de que a pessoa está lá.

```ts
// Pedir para entrar no grupo de alguém (o dono recebe push e vê na tela)
await supabase.rpc("request_join", { p_scan_token: token, p_entry_id: entryId });

// Já está em outra fila? Volta NQ014 com "saia da sua fila atual (…)".
// O app pergunta; confirmado, repete com p_leave_current (o scan, que
// não foi gasto, ainda vale). A pessoa continua na fila atual enquanto
// espera e só sai dela quando o dono aceitar.
await supabase.rpc("request_join", { p_scan_token: token, p_entry_id: entryId, p_leave_current: true });

// O dono aceita ou recusa
await supabase.rpc("decide_join_request", { p_request_id: id, p_approve: true });

// Quem pediu desiste
await supabase.rpc("cancel_join_request", { p_request_id: id });

// Entrar direto com o PIN do grupo. Com p_leave_current, sai da fila
// atual na hora — a entrada é imediata.
const { data } = await supabase.rpc("join_with_pin", { p_scan_token: token, p_pin: "4821" });
// PIN errado NÃO é erro — a tentativa precisa ficar gravada:
// { joined: false, code: "PIN_INVALID", message, attempts_left }
// O scan é gasto, e 5 erros em 15 minutos travam com NQ028.
```

O PIN tem 4 dígitos, é único entre as vagas ativas da quadra e é
próprio de cada vaga — o PIN de semana passada não serve hoje. Fica numa
tabela sem acesso direto do cliente; só sai em `court_screen.my_group` e
`my_queue_state.group`, para quem é do grupo.

Pedido pendente expira em 10 minutos, quando o grupo sai da fila ou
quando a pessoa entra em outra vaga.

### RPCs da Sprint 5 — fila com anfitrião

```ts
// Abrir a fila (token de scan-court com method "gps"): faltam 15 min
// para quem joga, e dois grupos sem app esperam na frente.
await supabase.rpc("open_host_queue", {
  p_scan_token: token, p_playing_minutes: 15, p_waiting_labels: ["dupla de boné azul", ""],
});

// Quem organiza: grupo sem app no fim da fila, e a vez dele.
await supabase.rpc("host_add_offline", { p_court_id: courtId, p_label: "trio da raquete vermelha" });
await supabase.rpc("host_mark_offline", { p_entry_id: entryId, p_action: "arrived" }); // gave_up | finished

// Qualquer pessoa da fila: um código para o QR na tela. Trocar a cada
// rotate_seconds (30), com o mesmo p_display_id enquanto o QR estiver aberto.
const { data } = await supabase.rpc("issue_host_invite", { p_court_id: courtId, p_display_id: crypto.randomUUID() });
// { code, invite_id, expires_at, rotate_seconds: 30, valid_seconds: 600 }

// Aberto antes do login (anon). Só conta para o painel.
await supabase.rpc("host_invite_opened", { p_code: code, p_visitor: visitorId });

// O painel do piloto (admin). Contagens, sem nomes.
await supabase.rpc("admin_pilot_stats", { p_park_id: null, p_from: "2026-10-01", p_to: "2026-10-30" });
```

`court_screen` ganhou `court.queue_mode`, `host` (`is_me`,
`can_show_invite`, `host_name`) e `can_open_host`; os itens da fila e o
turno, `is_offline` e `offline_label`.

### Tempo real (US-03)

```ts
const channel = supabase
  .channel(`court:${courtId}`)
  .on("postgres_changes", {
    event: "*",
    schema: "public",
    table: "queue_entries",
    filter: `court_id=eq.${courtId}`,
  }, () => refetchQueue())
  .on("postgres_changes", {
    event: "UPDATE",
    schema: "public",
    table: "courts",
    filter: `id=eq.${courtId}`,
  }, (payload) => setCourt(payload.new))
  // Sprint 4: alguém entrou ou saiu de um grupo, e pedidos de entrada.
  // O RLS de queue_join_requests só entrega ao grupo e a quem pediu.
  .on("postgres_changes", {
    event: "*",
    schema: "public",
    table: "queue_entry_members",
    filter: `court_id=eq.${courtId}`,
  }, () => refetchQueue())
  .on("postgres_changes", {
    event: "*",
    schema: "public",
    table: "queue_join_requests",
    filter: `court_id=eq.${courtId}`,
  }, () => refetchQueue())
  .subscribe();
```

O evento carrega a linha alterada, não a fila inteira. Recalcule chamando
`court_queue` (uma RPC leve) a cada evento — assim posição e tempo
estimado ficam sempre corretos, inclusive após reconexão.

## Códigos de erro do banco

As RPCs sinalizam erros de negócio por `SQLSTATE`. O `supabase-js`
entrega em `error.code`; as Edge Functions já traduzem para os códigos da
tabela acima.

| SQLSTATE | Significado |
|---|---|
| `NQ001` | Não autenticado |
| `NQ002` | Scan token inválido, expirado ou já usado |
| `NQ003` | Quadra indisponível |
| `NQ004` | Jogador já está na fila desta quadra |
| `NQ005` | Parceiro não encontrado (legado: parceiro pelo @) |
| `NQ006` | Parceiro inválido (legado: parceiro pelo @) |
| `NQ007` | Grupo não encontrado |
| `NQ008` | Sem permissão |
| `NQ009` | Transição de estado inválida |
| `NQ010` | Avaliar quadra onde ainda não jogou |
| `NQ011` | Nota fora da faixa de 1 a 5 |
| `NQ012` | Cota de fotos pendentes atingida |
| `NQ013` | Foto não encontrada |
| `NQ014` | Já está na fila de outra quadra |
| `NQ015` | Não é a vez deste grupo |
| `NQ016` | Tolerância do check-in expirada |
| `NQ017` | Quadra ocupada |
| `NQ018` | Partida não encontrada |
| `NQ019` | Cor fora da paleta |
| `NQ020` | Parque não encontrado |
| `NQ027` | Pedido de entrada não está mais pendente |
| `NQ028` | Muitas tentativas de PIN (5 em 15 min) |
| `NQ029` | Parceiro pelo @ — ele entra escaneando a quadra |
| `NQ030` | A quadra não está no modo anfitrião |
| `NQ031` | Já existe uma fila aberta nesta quadra |
| `NQ032` | Dados da fila com anfitrião inválidos |
| `NQ033` | Só quem organiza a fila faz isso |
| `NQ034` | A fila desta quadra não está aberta |
| `NQ035` | No modo anfitrião a distância não pode ser desligada |
