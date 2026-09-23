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

## POST /scan-court — validar QR Code e proximidade (US-02)

```json
{
  "payload": "neqst:v1:7c9e6679-7425-40de-944b-e07fc1f90ae7:Yk3fQ2...",
  "latitude": -23.561414,
  "longitude": -46.655881,
  "accuracy": 18.5
}
```

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
  "court": {
    "id": "7c9e6679-7425-40de-944b-e07fc1f90ae7",
    "slug": "quadra-central",
    "name": "Quadra Central",
    "address": "Av. Paulista, 1000",
    "status": "available",
    "photoUrl": null,
    "averageMatchMinutes": 20
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
| `COURT_UNAVAILABLE` | 409 | Quadra indisponível |

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

## POST /dispatch-notifications — worker de push (cron)

Header `x-cron-secret: <CRON_SECRET>`. Sem JWT de usuário.
Processa até 200 notificações pendentes por chamada.

**200** `{ "processed": 12, "sent": 11, "failed": 1, "deactivatedTokens": 1 }`

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
