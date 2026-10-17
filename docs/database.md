# Banco de dados

Postgres gerenciado pelo Supabase. Schema versionado em
`supabase/migrations/`; o mesmo conteúdo, concatenado e pronto para colar
no SQL Editor, fica em `db/full_setup.sql`.

## Diagrama

```
                                             parks
                                               │
auth.users ──1:1── profiles                    ▼
                      │                      courts ──< court_reviews
                      ├──< queue_entry_members      ──< court_photos
                      │         │                   ──< court_occupancy_snapshots
                      │         ▼                        │
                      │    queue_entries ───────────────┘
                      │         │   │
                      │         │   ├──< matches (o turno do grupo)
                      │         │   ├──< queue_join_requests
                      │         │   └──1 queue_entry_pins
                      ├──< push_tokens
                      ├──< web_push_subscriptions
                      └──< notification_outbox

                 scan_tokens ──▶ courts   (prova de presença, QR ou NFC)
```

## Tabelas

### `profiles` (US-01)
Perfil público, criado automaticamente pelo trigger `on_auth_user_created`
a cada signup — e-mail/senha, Google ou Apple. O `username` é derivado do
e-mail (ou do nome do provedor SSO) com sufixo numérico em caso de colisão,
e é o identificador público do jogador.

`role` (`player` / `staff` / `admin`) governa as permissões: só `staff` e
`admin` operam a quadra; só `admin` gera e rotaciona QR Codes.

### `parks` (Sprint 3)
Parque ou complexo que abriga as quadras: nome, distrito
("Vila Mariana · Zona Sul"), foto com texto alternativo e cor de fundo
para o cartão sem foto. É por aqui que o app começa.

### `courts` (US-02 / US-04 / Sprint 3)
Quadra de um parque, com número (`court_number` → "Quadra 01", único por
parque) e superfície (`clay` / `hard` / `grass`). Coordenadas e regras de
proximidade:

| Coluna | Papel |
|---|---|
| `max_distance_meters` | Raio de entrada — padrão 1000 m (US-02) |
| `gps_tolerance_meters` | Margem extra para GPS impreciso — padrão 200 m |
| `slot_minutes` | **Limite** do turno de um grupo (padrão 40, faixa 20-90) |
| `average_match_minutes` | Espelha o slot por trigger (compatibilidade) |
| `call_window_seconds` | Tolerância do check-in depois de chamado (padrão 120, faixa 60-1800; o admin ajusta) |
| `holder_entry_id` | Legado do "quem ganha fica" (Sprint 3) — sempre nulo desde a Sprint 4 |
| `has_qr_code` / `has_nfc_tag` | Quais formas de check-in a quadra oferece |
| `status` | `available` / `in_game` / `unavailable` |
| `qr_secret_version` | Permite rotacionar o QR de uma quadra sem afetar as demais |

### `scan_tokens` (US-02)
Prova de presença de uso único, TTL de 30s. Guarda só o SHA-256 do token,
mais a distância e as coordenadas usadas na validação — útil para auditar
tentativas suspeitas.

### `queue_entries` + `queue_entry_members` (US-03, revisto na Sprint 4)
Uma *vaga* na fila e o grupo que joga nela — de qualquer tamanho: dois
no simples, quatro nas duplas, cinco revezando. O turno é fixo, quantos
forem. `queue_entries.mode` é legado e não decide nada.

Em cada membro: `joined_via` (`owner` abriu a vaga, `approval` foi
aceito, `pin` usou o PIN), `checked_in_at` (escaneou a quadra para
jogar) e `left_at` (saiu com o turno rolando — quem sai antes do turno
deixa de fazer parte do grupo). Saindo o dono (`role = owner`), o membro
mais antigo herda; a vaga só some quando sai o último.

Garantias no próprio schema:

- `matches_one_live_per_court` — no máximo uma partida em andamento por
  quadra.
- `queue_entry_members_one_active_per_player` — um jogador em **uma fila
  só, em qualquer quadra de qualquer parque**, seja abrindo a vaga ou no
  grupo de alguém. Para entrar no grupo do amigo, quem já está numa fila
  sai dela primeiro.
- `queue_entries_sync_members` — encerrada a vaga, seus jogadores voltam
  a poder entrar na fila.

A Sprint 4 removeu `queue_entry_members_team_size` (o limite de 2).

Ordem da fila = `queue_entries.queue_number`, uma coluna *identity*
estritamente crescente, exposta pela view `queue_positions`. Não usamos
`joined_at`: `now()` é constante dentro de uma transação, então dois times
criados na mesma transação empatariam e a posição ficaria indefinida.
`joined_at` usa `clock_timestamp()` e serve para exibição e estimativas.

### `queue_entry_pins` (Sprint 4)
O PIN de 4 dígitos de cada vaga, único entre as vagas ativas da quadra.
Quem tem o PIN e escaneia a quadra entra no grupo sem esperar
aprovação — inclusive com o turno rolando. Sem nenhum grant para o
cliente: `queue_entries` é legível por todos e passa pelo Realtime, então
o PIN mora à parte e só sai pelas RPCs, para quem é do grupo.

`queue_pin_attempts` registra cada tentativa. Cada uma gasta um scan
(é preciso estar na quadra), e 5 erros em 15 minutos travam (`NQ028`).

### `queue_join_requests` (Sprint 4)
Quem escaneou a quadra e pediu para entrar no grupo de alguém. O dono
aceita ou recusa. Se a pessoa estava em outra fila e confirmou o aviso
(`leave_current`), ela continua lá enquanto espera e só sai quando for
aceita. Um pendente por pessoa (`queue_join_requests_one_pending_per_user`);
expira em 10 minutos, quando o grupo sai da fila ou quando a pessoa entra
em outra vaga. O RLS deixa ler só quem pediu e quem está no grupo — é o
que permite o Realtime avisar o dono sem expor o pedido ao parque.

Sem esse passo, qualquer pessoa que escaneasse o QR escolheria o grupo do
1º da fila e passaria na frente de todo mundo.

### `push_tokens` / `notification_outbox` (US-03)
Devices Expo por usuário e a fila de pushes a enviar. O outbox é
transacional: o gatilho enfileira junto com a mudança da fila, e o worker
entrega depois — se a Expo estiver fora do ar, nada se perde.

O índice `notification_outbox_unique_event (entry_id, user_id, type)`
garante que o "Prepare-se!" saia **uma vez só** por pessoa do grupo,
mesmo com o gatilho rodando a cada evento da fila. Os pushes do pedido
de entrada (`group_join_request`, `group_join_approved`) vão sem
`entry_id`, para dois pedidos ao mesmo dono não se engolirem.

### `court_reviews` (Sprint 2)
Nota de 1 a 5 e comentário, uma por jogador por quadra (`unique (court_id,
user_id)`), editável. `rate_court` exige partida concluída naquela quadra
— todo mundo que estava no grupo conta como quem jogou.

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

### `matches` (Sprint 3, revisto na Sprint 4)
O turno de um grupo na quadra: `side_a_entry_id` é a vaga. Não há
adversário vindo da fila nem vencedor — `side_b_entry_id`,
`winner_side` e `courts.holder_entry_id` ficaram do "quem ganha fica" da
Sprint 3 e não são mais preenchidos.

`expires_at` nasce de `started_at + slot_minutes` e não muda: quem chega
atrasado entra com o turno rolando, e o relógio não para. Chegando lá,
o turno encerra (`slot_expired`) e a fila anda. O grupo também pode
devolver a quadra antes (`finished_by_group`), e se todos saem o turno
acaba (`abandoned`).

Um índice único garante uma partida ao vivo por quadra. O índice da
Sprint 1 (`queue_entries_one_playing_per_court`) foi removido: ele
presumia um time só em quadra e impediria os dois lados de jogarem.

### `racket_palette` (Sprint 3)
As seis cores do protótipo (Ocre, Giz, Ferrugem, Azul névoa, Malva,
Sálvia). Fica no banco para o app não hardcodar e para a validação
recusar cor fora do conjunto.

### `web_push_subscriptions` (Sprint 2)
O equivalente de `push_tokens` para o navegador: endpoint do push service
mais as chaves `p256dh` e `auth`. Existe porque a Expo Push API não
entrega em navegador — ver [`plataformas.md`](plataformas.md).

## Funções (RPC)

| Função | Quem chama | O que faz |
|---|---|---|
| `join_queue(scan_token)` | jogador | Valida presença e abre uma vaga (pode estar sozinho) |
| `request_join(scan_token, entry_id, leave_current)` | jogador | Pede para entrar no grupo de alguém (Sprint 4) |
| `decide_join_request(request_id, approve)` | dono do grupo | Aceita ou recusa o pedido (Sprint 4) |
| `cancel_join_request(request_id)` | jogador | Desiste do pedido (Sprint 4) |
| `join_with_pin(scan_token, pin, leave_current)` | jogador | Entra com o PIN do grupo (Sprint 4) |
| `leave_queue(entry_id, reason)` | jogador | Sai do grupo; a vaga fica com quem ficou |
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
| `parks_overview` / `park_screen` / `court_screen` / `my_queue_state` | app | Uma por tela (Sprint 3) |
| `check_in_and_start` | jogador | Um check-in inicia o turno; quem chega depois registra presença |
| `finish_my_turn(match_id)` | grupo | Devolve a quadra antes do fim do turno (Sprint 4) |
| `my_group(entry_id)` / `my_join_request()` | app | PIN, membros e pedidos — só para o grupo (Sprint 4) |
| `search_partners` / `update_my_profile` | app | Lista de jogadores e raquete (Sprint 3) |
| `advance_expired_queues` / `advance_court(court_id)` | cron / interno | Turno vencido e chamada não atendida |
| `court_label` / `initials_of` / `short_name_of` | interno | Rótulos do jeito que o app mostra |

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
| `queue_join_requests` | — | lê quem pediu e quem está no grupo |
| `queue_entry_pins` / `queue_pin_attempts` | — | — (só pelas RPCs) |
| `scan_tokens` | — | lê apenas os próprios |
| `push_tokens` | — | CRUD apenas dos próprios devices |
| `notification_outbox` | — | lê apenas as próprias notificações |
| `court_reviews` | leitura | leitura; escreve só a própria |
| `court_photos` | leitura das aprovadas | aprovadas + as próprias; remove as próprias |
| `court_occupancy_snapshots` | leitura | leitura |
| `web_push_subscriptions` | — | lê e remove apenas as próprias |
| `parks` | leitura das ativas | leitura; escrita só admin |
| `matches` | leitura | **somente leitura** (escrita via RPC) |
| `racket_palette` | leitura | leitura |

`INSERT/UPDATE/DELETE` na fila foram **revogados** de `anon` e
`authenticated`: só as funções `SECURITY DEFINER` escrevem. Um cliente com
a chave `anon` em mãos não consegue furar fila, entrar sem escanear nem
remover o time de outra pessoa.

## Realtime

`queue_entries`, `queue_entry_members`, `queue_join_requests`, `courts` e
`matches` estão na publicação `supabase_realtime` com `replica identity full`. O placar da
quadra é ao vivo: assine `matches` filtrando por `court_id`. O app filtra por
`court_id` — ver [`api.md`](api.md#tempo-real-us-03).

## Rotinas agendadas

`advance_expired_queues()` (a cada minuto) encerra turnos vencidos e
passa a vez de quem não fez check-in na tolerância. Com 2 minutos de
tolerância, esperar a rotina de 15 em 15 deixaria a quadra parada; por
isso o check-in e a entrada na fila também andam a fila daquela quadra
na hora (`advance_court`).

`run_maintenance()` (a cada 15 min) expira vagas paradas há mais de 3h,
limpa scan tokens antigos, captura os snapshots de ocupação e descarta
notificações com mais de 30 dias e snapshots com mais de 90 dias.
`dispatch-notifications` roda a cada ~10s. Agendamento em
`supabase/migrations/20260923120900_jobs.sql`.
