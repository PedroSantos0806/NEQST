# Sprint 3 — alinhamento com o protótipo de frontend

O protótipo de tela mostrou que o produto é diferente do que as Sprints
1 e 2 presumiram em quatro pontos de modelo. Esta sprint acerta o
backend com ele. Nada do que existia foi descartado — a fila, o QR com
proximidade, o histórico, as avaliações, as fotos e o mapa de calor
continuam; o que mudou é a forma do mundo em volta.

## O que o protótipo revelou

| Ponto | Sprints 1-2 | Protótipo |
|---|---|---|
| Hierarquia | quadra é a entidade de topo | **parque** com várias quadras numeradas |
| Quadra | sem tipo de piso | **superfície**: saibro, rápida, grama |
| Partida | um time "em quadra" | **lado A × lado B**, e quem ganha fica |
| Quem inicia | operador (`staff`) | **o próprio jogador**, com check-in na quadra |
| Fila | uma por quadra | **uma por jogador**, em todo o app |
| Duração | média para estimar | **slot rígido** que encerra a partida |
| Check-in | QR Code | **QR ou totem NFC** |
| Chamada | sem prazo | **5 minutos** para comparecer |

## 1. Parques

`parks` (nome, distrito, foto, cor) e, na quadra, `park_id`,
`court_number` e `surface`. O nome que o app mostra vem do número:
`court_label(1)` = "Quadra 01". Um índice único impede dois "Quadra 01"
no mesmo parque — o jogador precisa achar a quadra física.

As quadras que já existiam ganharam um parque derivado dos próprios
dados, para `park_id` poder ser obrigatório sem perder nada.

## 2. Partida com dois lados

```
mandante (lado B) ──── vence ────▶ continua em quadra
desafiante (lado A) ── perde ────▶ sai
                                    ▲
                  próximo da fila ──┘
```

`matches` guarda os dois lados, o vencedor e o motivo do encerramento.
`courts.holder_entry_id` aponta para quem ficou.

Quando a quadra está vazia, o primeiro time entra como lado A e o lado B
fica aberto — é o **"Adversário livre"** do protótipo. Outro time da fila
pode ocupá-lo (`join_open_side`) sem esperar a vez.

**O protótipo não tem tela para informar quem ganhou** — ele assume que o
mandante vence. Implementei `report_match_result(match_id, winner)`,
que qualquer jogador dos dois lados pode chamar. Se ninguém reportar até
o slot acabar, a partida encerra **sem vencedor**, os dois lados saem e a
quadra fica sem mandante. É a decisão conservadora: inventar um vencedor
daria vantagem a quem não jogou melhor, só ficou mais tempo.

Essa tela é o que falta para o fluxo fechar.

## 3. Check-in do jogador

Num parque público não existe operador. O protótipo é explícito: quando
é a sua vez, você escaneia o QR da quadra para "confirmar que você
chegou e liberar o placar".

`check_in_and_start(scan_token)` exige um scan token **novo** — o mesmo
mecanismo de proximidade do `join_queue`. Sem isso, alguém de casa
travaria a quadra iniciando uma partida que não vai acontecer.

`start_match` (operador) continua, agora sobre o mesmo núcleo
(`open_match`): antes ela marcava a inscrição como "em jogo" sem criar
partida, o que deixaria a tela dizendo "Livre" com gente jogando.

## 4. Chamada com prazo

Encerrada a partida, `call_next_team` põe o próximo time em `ready` e
abre uma janela de `call_window_seconds` (padrão 300). Quem não faz
check-in nesse prazo é expirado com `cancel_reason = 'no_show'` e a vez
passa. Quem entra numa quadra **livre** é chamado na hora — é a sua vez
desde o primeiro momento.

A notificação "É a sua vez!" passou a sair na chamada (não mais quando a
posição chega a zero), e traz o prazo no texto.

## 5. Uma fila por jogador

O índice único saiu de `(court_id, user_id)` para `(user_id)`. Tentar
entrar em outra fila devolve `NQ014` com o nome da quadra onde você já
está — o texto que o protótipo mostra. Vale para o parceiro de dupla
também: `search_partners` marca quem está `queued` ou `playing` como
indisponível, com o lugar.

## 6. Slot de tempo

`courts.slot_minutes` (padrão 40, faixa 20-90, como o controle do
protótipo) é limite, não média: `matches.expires_at` nasce de
`started_at + slot` e, chegando lá, `advance_expired_queues` encerra a
partida e chama o próximo. `average_match_minutes` continua espelhando o
slot por trigger, para as estimativas das Sprints 1-2 não divergirem.

## 7. NFC

A tag NFC grava **a mesma URL assinada** do QR (registro NDEF do tipo
URI), então a validação é idêntica — muda só por onde o payload chegou.
`scan_tokens.method` registra isso, e `courts.has_qr_code` /
`has_nfc_tag` dizem quais abas a tela deve mostrar. Se um totem for
clonado, `court_checkin_methods` mostra por onde vieram os check-ins.

## 8. Perfil e a pilha de raquetes

A fila é desenhada como uma pilha de raquetes, uma por time, com as
cores que o jogador escolhe. Sem isso a tela principal não desenha nada:
`profiles.racket_frame_color`, `racket_grip_color` e `avatar_tone`, com a
paleta do protótipo em `racket_palette` (Ocre, Giz, Ferrugem, Azul
névoa, Malva, Sálvia). Cor fora da paleta é recusada (`NQ019`).

`court_queue_items` devolve, por item, as raquetes dos times à frente
(no máximo 5, como no protótipo) e quantos sobraram atrás.

## Uma RPC por tela

| Tela do protótipo | Chamada |
|---|---|
| Lista de parques | `parks_overview(lat, lng, raio)` |
| Home do parque | `park_screen(park_id)` |
| Tela da quadra | `court_screen(court_id)` |
| Cartão "você está na fila" / chamada | `my_queue_state()` |
| Placar | `match_state(match_id)` |
| Escolher parceiro | `search_partners(busca)` |
| Perfil | `my_profile_summary()` + `update_my_profile(...)` |

Cada tela resolve em **uma** chamada: o critério de 2s em 3G não
sobrevive a cinco round-trips.

`court_screen` traz dois campos parecidos de propósito:
`court_accepting` é o fato da quadra (ativa e não indisponível) e
`can_join` é o fato do jogador (pode entrar, porque não está em outra
fila). O protótipo desabilita o botão pelos dois motivos, com textos
diferentes.

## Verificação

`tests/local/40_sprint3_test.sql` percorre o fluxo inteiro:

- lista de parques com contagens, superfícies e filtro geográfico
- bloqueio de segunda fila, inclusive em outro parque, com a mensagem
- parceiro indisponível recusado, com o lugar onde está
- check-in abrindo partida com o lado B aberto, e o token de uso único
- ocupar o lado livre
- resultado reportado: vencedor fica, perdedor sai, próximo chamado
- slot estourado sem relato: sem vencedor, quadra sem mandante
- chamada não atendida: `no_show` e a vez passa
- check-in fora da janela recusado
- as telas (`court_screen`, `park_screen`, `my_queue_state`)
- paleta da raquete e a cor aparecendo na pilha

As três suítes anteriores foram atualizadas para o novo modelo e seguem
passando — inclusive `court_queue`, que agora lê a partida de `matches`
em vez de inferir de `queue_entries.status`.

## O que o backend ainda não cobre

- **Tela de resultado.** Falta no protótipo; a RPC existe.
- **Dois lados simultâneos numa quadra vazia.** Hoje o segundo time
  ocupa o lado livre de uma partida já começada (o relógio corre desde o
  primeiro check-in). Se o desejado for esperar os dois para iniciar o
  slot, é uma mudança pequena em `open_match` — mas o protótipo mostra o
  cronômetro correndo desde o check-in.
- **Placar de games/sets.** O protótipo só cronometra o slot.
