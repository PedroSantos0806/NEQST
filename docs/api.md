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

## POST /join-queue — entrar na fila (US-03)

```json
{ "scanToken": "s3Kf9...", "mode": "single" }
```

```json
{ "scanToken": "s3Kf9...", "mode": "double", "partner": "@bruno" }
```

`partner` aceita `@username`, `username` ou e-mail.

**201**

```json
{
  "entry_id": "9f1c...",
  "court_id": "7c9e...",
  "court_name": "Quadra Central",
  "mode": "double",
  "status": "waiting",
  "joined_at": "2026-09-23T18:30:12.000Z",
  "started_at": null,
  "position": 2,
  "teams_ahead": 1,
  "estimated_wait_minutes": 20,
  "players": [
    { "user_id": "...", "role": "owner",   "username": "ana",   "full_name": "Ana Souza",  "avatar_url": null },
    { "user_id": "...", "role": "partner", "username": "bruno", "full_name": "Bruno Lima", "avatar_url": null }
  ]
}
```

| Código | HTTP | Quando |
|---|---|---|
| `SCAN_TOKEN_REQUIRED` | 400 | Chamou sem escanear |
| `SCAN_TOKEN_INVALID` | 400 | Token expirado (>30s), já usado ou de outro usuário |
| `PARTNER_REQUIRED` / `PARTNER_NOT_FOUND` | 400 / 404 | Dupla sem parceiro ou com parceiro inexistente |
| `PARTNER_INVALID` | 409 | Parceiro é você mesmo ou já está na fila desta quadra |
| `ALREADY_IN_QUEUE` | 409 | Você já está em um time nesta quadra |
| `ALREADY_IN_ANOTHER_QUEUE` | 409 | Você já está na fila de outra quadra — a mensagem diz qual |
| `COURT_UNAVAILABLE` | 409 | Quadra indisponível |

---

## POST /check-in — liberar o placar e iniciar (Sprint 3)

```json
{ "scanToken": "s3Kf9...", "side": "auto" }
```

É o "Check-in para jogar": quando é a vez do seu time, você escaneia o
QR (ou encosta no totem) e a partida começa. Num parque público não há
operador — quem libera o placar é quem vai jogar.

`side` é `"auto"` (padrão) para iniciar a partida com o time na vez, ou
`"open"` para ocupar o lado livre de uma partida em andamento (o
"Adversário livre" da tela).

**201** devolve o placar (`match_state`):

```json
{
  "match_id": "...",
  "court_name": "Quadra 01",
  "mode": "double",
  "slot_minutes": 40,
  "is_live": true,
  "remaining_seconds": 2398,
  "side_a": { "entry_id": "...", "role": "challenger", "players": [ ] },
  "side_b": { "entry_id": "...", "role": "holder", "open": false, "players": [ ] }
}
```

| Código | HTTP | Quando |
|---|---|---|
| `NOT_YOUR_TURN` | 409 | Outro time está na vez |
| `COURT_BUSY` | 409 | A partida atual ainda tem slot pela frente |
| `CALL_EXPIRED` | 410 | Passou dos 5 minutos da chamada |
| `SCAN_TOKEN_INVALID` | 400 | Token expirado, já usado ou de outro usuário |

---

## POST / GET /match — resultado da partida (Sprint 3)

```json
{ "matchId": "...", "winner": "a" }
```

Quem ganha fica: o lado vencedor segue em quadra como mandante e o
próximo da fila entra como desafiante. Qualquer jogador dos dois lados
reporta. Se ninguém reportar até o slot acabar, a partida encerra **sem
vencedor** e a quadra fica sem mandante.

`GET /match?matchId=<uuid>` devolve o placar (útil após reconexão).

---

## POST /leave-queue — sair da fila (US-03)

```json
{ "entryId": "9f1c...", "reason": "mudou de ideia" }
```

**200** `{ "entry_id": "9f1c...", "status": "cancelled", "left_at": "..." }`

Qualquer integrante do time pode sair — a saída desfaz o time inteiro.
Confirme com o usuário antes de chamar (critério de aceite da US-03).

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

`join_queue` também é RPC (`p_scan_token`, `p_mode`, `p_partner`), mas o
`scanToken` só existe depois de `scan-court` — a Edge Function continua
sendo o caminho natural para entrar na fila.

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

// Escolher parceiro, com disponibilidade
await supabase.rpc("search_partners", { p_query: "@bru" });

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
| `players_line` | "D. Matsuo / M. Costa × T. Lima / J. Prado" |
| `match.remaining_seconds` | Cronômetro do slot |
| `queue[].stack` | Raquetes à frente (máx. 5) para desenhar a pilha |
| `queue[].stack_more` | Quantas sobraram atrás da pilha |
| `queue[].is_mine` | Destaca a linha do próprio time |
| `court_accepting` | A quadra aceita entradas |
| `can_join` | **Eu** posso entrar (não estou em outra fila) |
| `my_state` | `free` / `queued` / `playing`, com onde |

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
| `NQ005` | Parceiro não encontrado |
| `NQ006` | Parceiro inválido |
| `NQ007` | Time não encontrado |
| `NQ008` | Sem permissão |
| `NQ009` | Transição de estado inválida |
| `NQ010` | Avaliar quadra onde ainda não jogou |
| `NQ011` | Nota fora da faixa de 1 a 5 |
| `NQ012` | Cota de fotos pendentes atingida |
| `NQ013` | Foto não encontrada |
| `NQ014` | Já está na fila de outra quadra |
| `NQ015` | Não é a vez deste time |
| `NQ016` | Janela de check-in expirada |
| `NQ017` | Quadra ocupada |
| `NQ018` | Partida não encontrada |
| `NQ019` | Cor fora da paleta |
| `NQ020` | Parque não encontrado |
