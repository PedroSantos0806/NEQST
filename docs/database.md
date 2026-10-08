# Banco de dados

Postgres gerenciado pelo Supabase. Schema versionado em
`supabase/migrations/`; o mesmo conteúdo, concatenado e pronto para colar
no SQL Editor, fica em `db/full_setup.sql`.

## Diagrama

```
auth.users ──1:1── profiles
                      │
                      ├──< queue_entry_members >── queue_entries >── courts
                      │                                   │            │
                      ├──< push_tokens                    │            ├──< court_reviews
                      ├──< web_push_subscriptions         │            ├──< court_photos
                      └──< notification_outbox <──────────┘            ├──< court_occupancy_snapshots
                                                                       │
                                            scan_tokens ───────────────┘
```

## Tabelas

### `profiles` (US-01)
Perfil público, criado automaticamente pelo trigger `on_auth_user_created`
a cada signup — e-mail/senha, Google ou Apple. O `username` é derivado do
e-mail (ou do nome do provedor SSO) com sufixo numérico em caso de colisão,
e é o identificador usado para convidar o parceiro de dupla.

`role` (`player` / `staff` / `admin`) governa as permissões: só `staff` e
`admin` operam a quadra; só `admin` gera e rotaciona QR Codes.

### `courts` (US-02 / US-04)
Quadra, coordenadas e regras de proximidade:

| Coluna | Papel |
|---|---|
| `max_distance_meters` | Raio de entrada — padrão 1000 m (US-02) |
| `gps_tolerance_meters` | Margem extra para GPS impreciso — padrão 200 m |
| `average_match_minutes` | Base do tempo estimado de espera |
| `status` | `available` / `in_game` / `unavailable` |
| `qr_secret_version` | Permite rotacionar o QR de uma quadra sem afetar as demais |

### `scan_tokens` (US-02)
Prova de presença de uso único, TTL de 30s. Guarda só o SHA-256 do token,
mais a distância e as coordenadas usadas na validação — útil para auditar
tentativas suspeitas.

### `queue_entries` + `queue_entry_members` (US-03)
Um *time* na fila e seus jogadores. Individual = 1 membro, dupla = 2.

Garantias no próprio schema:

- `queue_entries_one_playing_per_court` — no máximo uma partida em
  andamento por quadra.
- `queue_entry_members_one_active_per_court` — um jogador não pode estar
  em dois times ativos da mesma quadra (inclusive como parceiro).
- `queue_entry_members_team_size` — dupla nunca passa de 2 jogadores.
- `queue_entries_sync_members` — encerrado o time, seus jogadores voltam
  a poder entrar na fila.

Ordem da fila = `queue_entries.queue_number`, uma coluna *identity*
estritamente crescente, exposta pela view `queue_positions`. Não usamos
`joined_at`: `now()` é constante dentro de uma transação, então dois times
criados na mesma transação empatariam e a posição ficaria indefinida.
`joined_at` usa `clock_timestamp()` e serve para exibição e estimativas.

### `push_tokens` / `notification_outbox` (US-03)
Devices Expo por usuário e a fila de pushes a enviar. O outbox é
transacional: o gatilho enfileira junto com a mudança da fila, e o worker
entrega depois — se a Expo estiver fora do ar, nada se perde.

O índice `notification_outbox_unique_event (entry_id, user_id, type)`
garante que o "Prepare-se!" saia **uma vez só** por time, mesmo com o
gatilho rodando a cada evento da fila.

### `court_reviews` (Sprint 2)
Nota de 1 a 5 e comentário, uma por jogador por quadra (`unique (court_id,
user_id)`), editável. `rate_court` exige partida concluída naquela quadra
— o parceiro de dupla conta como quem jogou.

`courts.rating_avg` e `courts.rating_count` são mantidos por trigger, para
a lista de quadras não precisar de join.

### `court_photos` (Sprint 2)
Metadado das fotos; o arquivo vive no bucket privado `court-photos`. A
linha nasce `pending` e `is_uploaded = false` (ela precisa existir antes
do upload, para gerar a URL assinada), e só aparece no app quando está
`approved` **e** confirmada.

- `court_photos_one_primary_per_court` — uma capa por quadra
- `court_photos_quota` — 5 pendentes por jogador por quadra
- `court_photos_sync_primary` — mantém `courts.cover_photo_path` na capa
  aprovada (um **caminho** do Storage, não uma URL — `courts.photo_url`
  segue reservado para URL externa), e volta a nulo se ela for rejeitada

### `court_occupancy_snapshots` (Sprint 2)
Uma amostra da fila por quadra a cada rodada de manutenção, com dia da
semana e hora. Alimenta `court_occupancy_pattern` ("costuma encher nesse
horário"). Retenção de 90 dias.

Os limites de ocupação ficam na quadra (`busy_threshold`,
`full_threshold`), não no código: 2 times na fila é tranquilo num clube e
cheio numa quadra pública.

### `web_push_subscriptions` (Sprint 2)
O equivalente de `push_tokens` para o navegador: endpoint do push service
mais as chaves `p256dh` e `auth`. Existe porque a Expo Push API não
entrega em navegador — ver [`plataformas.md`](plataformas.md).

## Funções (RPC)

| Função | Quem chama | O que faz |
|---|---|---|
| `join_queue(scan_token, mode, partner)` | jogador | Valida presença, monta o time, entra na fila |
| `leave_queue(entry_id, reason)` | jogador | Sai da fila |
| `court_queue(court_id)` | app | Estado completo da quadra + fila |
| `queue_entry_state(entry_id)` | app | Posição, times na frente, espera estimada |
| `my_active_entries()` | app | Times ativos do usuário (reconexão) |
| `nearby_courts(lat, lng, raio, limite)` | app | Quadras próximas + fila de cada uma |
| `haversine_meters(lat1, lng1, lat2, lng2)` | interno | Distância em metros |
| `start_match` / `finish_match` / `call_next` | staff | Operação da quadra |
| `expire_stale_queue_entries` / `purge_expired_scan_tokens` / `run_maintenance` | cron | Limpeza |
| `refresh_queue_notifications(court_id)` | trigger | Enfileira "Prepare-se!" e "É a sua vez!" |
| `my_match_history` / `my_visited_courts` / `my_profile_summary` | app | Histórico e perfil (Sprint 2) |
| `rate_court` / `court_reviews_page` / `can_review_court` | app | Avaliações (Sprint 2) |
| `courts_heatmap` / `court_occupancy_pattern` | app | Mapa de calor (Sprint 2) |
| `court_photos_page` | app | Fotos aprovadas (Sprint 2) |
| `moderate_court_photo` / `set_primary_court_photo` / `pending_court_photos` | staff | Moderação (Sprint 2) |
| `capture_occupancy_snapshots` | cron | Amostra da ocupação (Sprint 2) |

Todas são `SECURITY DEFINER` com `search_path = ''` — cada objeto é
referenciado pelo nome completo, o que fecha a porta para sequestro de
`search_path`.

## Segurança (RLS)

RLS ativo em todas as tabelas. O resumo:

| Tabela | `anon` | `authenticated` |
|---|---|---|
| `courts` | leitura das ativas | leitura; escrita só staff/admin |
| `profiles` | — | leitura de todos; escreve só o próprio (sem trocar `role`) |
| `queue_entries` / `queue_entry_members` | — | **somente leitura** |
| `scan_tokens` | — | lê apenas os próprios |
| `push_tokens` | — | CRUD apenas dos próprios devices |
| `notification_outbox` | — | lê apenas as próprias notificações |
| `court_reviews` | leitura | leitura; escreve só a própria |
| `court_photos` | leitura das aprovadas | aprovadas + as próprias; remove as próprias |
| `court_occupancy_snapshots` | leitura | leitura |
| `web_push_subscriptions` | — | lê e remove apenas as próprias |

`INSERT/UPDATE/DELETE` na fila foram **revogados** de `anon` e
`authenticated`: só as funções `SECURITY DEFINER` escrevem. Um cliente com
a chave `anon` em mãos não consegue furar fila, entrar sem escanear nem
remover o time de outra pessoa.

## Realtime

`queue_entries`, `queue_entry_members` e `courts` estão na publicação
`supabase_realtime` com `replica identity full`. O app filtra por
`court_id` — ver [`api.md`](api.md#tempo-real-us-03).

## Rotinas agendadas

`run_maintenance()` (a cada 15 min) expira times parados há mais de 3h,
limpa scan tokens antigos, captura os snapshots de ocupação e descarta
notificações com mais de 30 dias e snapshots com mais de 90 dias.
`dispatch-notifications` roda a cada ~10s. Agendamento em
`supabase/migrations/20260923120900_jobs.sql`.
