# Sprint 2 — o que o backend entrega

A Sprint 1 fechou a fundação (conta, QR Code, fila em tempo real). Esta
sprint implementa os quatro itens listados em **"O QUE VEM NA SPRINT 2"**
do documento de planejamento, mais o que a decisão de publicar **na web e
na Play Store** exige do backend.

## Histórico do usuário (lugares visitados, partidas jogadas)

Sem tabela nova: a Sprint 1 já grava `started_at`/`ended_at` em
`queue_entries`. O histórico é leitura sobre esse dado.

| RPC | Devolve |
|---|---|
| `my_match_history(limit, before)` | Partidas concluídas, com quadra, duração e com quem jogou. Paginação por cursor. |
| `my_visited_courts(limit)` | Quadras onde jogou, com nº de partidas, minutos e última visita. |
| `my_profile_summary()` | Uma chamada para a tela de perfil: dados, estatísticas e filas ativas. |

A paginação usa cursor (`before` = `ended_at` da última linha) em vez de
`offset`: com `offset`, uma partida nova entrando no topo faria a página
seguinte repetir uma linha.

## Sistema de avaliação da quadra

`court_reviews`: nota de 1 a 5 e comentário opcional, uma por jogador por
quadra, editável.

**Só avalia quem jogou.** `rate_court` exige uma partida concluída
naquela quadra (`NQ010` caso contrário) — o dado para checar isso já
existe, e sem a regra a nota mede qualquer coisa menos a quadra. Vale
para o parceiro de dupla também: ele jogou.

`courts.rating_avg` e `courts.rating_count` são mantidos por trigger, para
a lista de quadras não precisar de join nem subquery.

| RPC | Para quê |
|---|---|
| `rate_court(court_id, rating, comment)` | Cria ou atualiza a própria avaliação |
| `delete_my_court_review(court_id)` | Remove a própria |
| `court_reviews_page(court_id, limit, before)` | Resumo, distribuição por nota, a minha e a lista |
| `can_review_court(court_id)` | Habilita ou não o botão na tela |

## Upload de fotos da quadra

O arquivo vai **direto do device para o Storage**, por URL assinada — não
passa pela Edge Function. Em 3G isso é a diferença entre um upload e um
timeout.

```
POST /court-photo            -> { photoId, uploadUrl, token }
PUT  <uploadUrl>             (o arquivo, direto no Storage)
POST /court-photo?action=confirm -> entra na fila de moderação
```

Fotos entram como `pending` e só aparecem no app depois de aprovadas —
conteúdo enviado por usuário em app de loja precisa desse caminho, e
tanto a Play Store quanto a App Store pedem moderação de UGC na revisão.

O `confirm` não acredita no cliente: confere no Storage se o objeto
existe antes de marcar como enviado. O bucket é **privado**; o app recebe
URLs assinadas, o que faz uma foto rejeitada deixar de ser acessível —
coisa que bucket público não permite.

Também há cota de 5 fotos pendentes por jogador por quadra (`NQ012`), e a
foto de capa aprovada alimenta `courts.cover_photo_path` automaticamente
— coluna separada de `courts.photo_url` porque ali vai um **caminho** no
bucket privado, que o cliente troca por URL assinada, e não uma URL.
Para a lista de quadras, `GET /court-photo?courtIds=a,b,c` assina todas
as capas de uma vez.

| RPC / rota | Para quê |
|---|---|
| `GET /court-photo?courtId=` | Fotos aprovadas com URL assinada de leitura |
| `GET /court-photo?courtIds=a,b,c` | Capas assinadas em lote (lista de quadras) |
| `court_photos_page(court_id, limit)` | O mesmo, via RPC |
| `moderate_court_photo(photo_id, approve, reason)` | Aprovar ou rejeitar (staff) |
| `set_primary_court_photo(photo_id)` | Definir a capa (staff) |
| `pending_court_photos(limit)` | Fila de moderação (staff) |

## Mapa de calor — indicador cheio/vazio

Duas leituras, e nenhuma delas faz cálculo no cliente:

**Agora** — derivado da fila ao vivo. `courts_heatmap(lat, lng, raio)`
devolve cada quadra com `occupancy` em `empty` / `low` / `busy` / `full`,
times na fila e espera estimada. Os limites são por quadra
(`busy_threshold`, `full_threshold`): 2 times numa quadra de clube é
tranquilo, numa quadra pública é fila.

As coordenadas são **opcionais** — a web costuma abrir antes de o usuário
conceder a localização, e aí o mapa mostra todas as quadras.

**Típico** — `court_occupancy_snapshots` guarda uma amostra por quadra a
cada rodada de manutenção (15 min). `court_occupancy_pattern(court_id)`
agrega por dia da semana e hora, respondendo "costuma encher nesse
horário". 90 dias de retenção.

## Web + Play Store

O documento de planejamento assumia só app nativo. Com a web no escopo,
quatro pontos do backend mudaram — detalhe em
[`docs/plataformas.md`](plataformas.md).

1. **Web Push (VAPID).** A Expo Push API não entrega em navegador.
   `dispatch-notifications` agora tem dois canais e entrega nos dois; a
   criptografia (RFC 8291) está em `_shared/webpush.ts`, validada contra
   a biblioteca `http_ece` do npm — a mesma que o pacote `web-push` usa.
2. **QR Code como App Link https.** Um QR `neqst:...` não abre nada na
   câmera nativa do Android. O que vai impresso agora é
   `https://<app>/q/<courtId>?v=1&s=<assinatura>`, que abre o app
   instalado ou o site. O formato antigo continua aceito.
3. **CORS por allow-list** (`ALLOWED_ORIGINS`), em vez de `*`. Sem isso,
   qualquer site poderia chamar a API pelo navegador de quem está logado.
4. **Redirects de auth para web** e credenciais OAuth separadas para web
   e Android.

## Verificação

- `tests/local/30_sprint2_test.sql` — histórico com paginação, regra de
  "só avalia quem jogou", agregados de nota, moderação de foto (incluindo
  a capa voltando a nula quando a foto é rejeitada), cota de uploads,
  classificação de ocupação, filtro geográfico, snapshots e canais de push.
- `webpush_test.ts` — vetor de referência conferido com `http_ece`,
  enquadramento `aes128gcm`, unicidade do par efêmero por mensagem e
  assinatura VAPID verificável com a chave pública.
- `http_test.ts` — allow-list de CORS, inclusive origem não autorizada.
- `qr_test.ts` — os dois formatos de QR e rejeição de link adulterado.

## O que não entrou

Nada do documento ficou de fora. Ficam como sugestão para depois:

- **Rate limiting** em `scan-court`. A proteção hoje é a assinatura do QR
  mais a distância; na web, abrir a API ao navegador facilita tentativa em
  volume.
- **Redimensionamento das fotos** no servidor. Hoje o device envia o que
  quiser até 10 MB; gerar thumbnail economizaria banda na listagem.
- **Notificação de avaliação**: pedir a nota por push ao fim da partida.
