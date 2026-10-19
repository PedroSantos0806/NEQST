# Sprint 4 — a vaga é do grupo, e cada um prova que está lá

A Sprint 3 modelou o jogo como **lado A × lado B, quem ganha fica**: cada
inscrição era um time de 1 ou 2, e o adversário vinha da fila. Não é
assim que os parques funcionam. Quem entra na quadra é um grupo de
conhecidos que joga **entre si** — dois no simples, quatro nas duplas, às
vezes cinco revezando — e cada vaga da fila vale um turno fixo de
quadra.

E o parceiro de dupla entrava digitando o @ dele, sem escanear nada. Um
amigo em casa podia "estar na fila". Esta sprint fecha os dois pontos.

## As regras

| Regra | Como ficou |
|---|---|
| Quem guarda o lugar | **Uma pessoa** abre a vaga, mesmo sozinha |
| Como os amigos entram | Escaneando a quadra e **pedindo para entrar** (o dono aceita) ou com o **PIN do grupo** |
| Até quando | Até o fim do turno — quem chega atrasado entra com o jogo rolando |
| Uma vaga por pessoa | Quem já está em outra fila vê "para entrar na fila do colega, saia da sua fila". No pedido, só sai quando for aceito; no PIN, sai na hora |
| Tamanho do grupo | **Sem limite** |
| Tempo de quadra | **Fixo** (slot da quadra, 40 min): solo, dupla ou grupo de 8 |
| Adversário vindo da fila | **Não existe.** Sem lado B, sem vencedor, sem "quem ganha fica" |
| Começar o turno | Chamado o grupo, **um** check-in basta |
| Tolerância do check-in | **2 minutos**, ajustável por quadra na administração |
| Dono saiu | O membro mais antigo **herda** a vaga |
| Todos saíram | A vaga some e a vez passa ao próximo |

## O furo que o pedido de entrada fecha

Se qualquer pessoa que escaneia o QR pudesse escolher em qual vaga
entrar, um desconhecido entraria no grupo do 1º da fila e passaria na
frente de todo mundo. Por isso entrar num grupo exige **uma das duas**:

- **Aprovação do dono** — o pedido aparece na tela dele (Realtime) e
  chega por push; ou
- **O PIN do grupo** — 4 dígitos, que só quem está no grupo vê. É o que
  resolve o amigo que chega com o jogo rolando: o dono está em quadra e
  não vai olhar o celular.

E as duas exigem **um scan novo da quadra do grupo**: a mesma prova de
presença (QR/NFC + GPS) de abrir uma vaga.

O PIN:

- é próprio de cada vaga — o PIN que vazou num grupo de WhatsApp na
  semana passada não serve hoje;
- é único entre as vagas ativas da quadra;
- mora numa tabela sem acesso do cliente (`queue_entries` é legível por
  todos e passa pelo Realtime) e só sai para quem é do grupo;
- errado, **gasta o scan** — tentar de novo exige estar na quadra — e 5
  erros em 15 minutos travam a pessoa.

PIN errado não é exceção no banco: a tentativa precisa ficar gravada
para o limite funcionar, e uma exceção desfaria a gravação. A RPC
devolve `{ joined: false, attempts_left }`.

## "Saia da sua fila"

Quem está em outra fila e tenta entrar no grupo do amigo recebe `NQ014`
com o lugar de onde precisa sair. O app mostra o aviso; confirmado,
repete a mesma chamada com `p_leave_current = true`. A chamada que
falhou não gastou o scan, então ele ainda vale.

- **Pelo pedido**, a pessoa **continua na fila atual enquanto espera** e
  só sai dela quando o dono aceita — na mesma transação em que entra no
  grupo (`queue_join_requests.leave_current`). Recusado ou expirado, ela
  não perdeu nada.
- **Pelo PIN**, a entrada é na hora, então a saída também.

Enquanto o pedido espera, a pessoa ocupa uma vaga só (a antiga); a nova
só passa a valer com a aprovação. Se ela abrir outra vaga nesse meio
tempo, o pedido é cancelado.

## O turno

`matches` continua, agora como o turno de um grupo (`side_a_entry_id`).
As colunas do lado B, do vencedor e do mandante ficaram para o histórico
já gravado.

- `expires_at = started_at + slot_minutes`, e não muda. Quem entra
  depois do início não estende nada.
- O grupo pode **devolver a quadra** antes (`finish_my_turn`,
  `finished_by_group`); o próximo é chamado na hora.
- Se todos saem com o turno rolando, ele acaba (`abandoned`).
- Quem é do grupo e chega depois do check-in escaneia também; fica
  registrado em `checked_in_at` e aparece no placar.

## A fila precisa andar de minuto em minuto

Com 2 minutos de tolerância, a rotina de manutenção de 15 em 15 deixaria
uma quadra parada por um grupo que não apareceu. Duas mudanças:

1. `advance_court(court_id)` anda a fila daquela quadra (turno vencido,
   chamada vencida) e roda **antes do check-in e da abertura de vaga**.
   Quem é o próximo e escaneia não depende do cron.
2. Um agendamento novo, `advance_expired_queues()` a cada minuto
   ([deploy.md](deploy.md#5-agendamentos)), para o "É a sua vez!" do
   próximo sair sem ninguém precisar escanear.

## Dados que já existiam

A migration converte o que estiver no banco:

- todo mundo em `playing` sem turno aberto (os mandantes do "quem ganha
  fica") vira `done`, e `courts.holder_entry_id` volta a nulo;
- toda vaga ativa ganha um PIN;
- quadras com a chamada no padrão antigo (300s) passam para 120s — um
  valor que o admin escolheu continua valendo;
- duplas que já estavam na fila viram grupos de 2.

Um turno aberto com lado B (de antes da migration) segue até o fim do
slot, e `close_match` encerra os dois lados.

## Compatibilidade

- `join_queue(p_scan_token, p_mode, p_partner)` mantém a assinatura: o
  app anterior ainda manda `p_mode`, que é ignorado. `p_partner` é
  recusado com `NQ029`.
- `court_queue_items` continua mandando `mode_label` (agora com o rótulo
  do grupo) além de `group_label`.
- `report_match_result` e `join_open_side` foram removidas;
  `finish_match` (staff) perdeu o parâmetro do vencedor.

## O que ficou de fora

- **Remover alguém do grupo.** Hoje o dono aceita ou recusa a entrada,
  mas não tira quem já entrou. Num grupo de amigos isso não deve fazer
  falta; se fizer, é uma RPC a mais.
- **Trocar o PIN** a pedido do dono (por exemplo, se ele vazou no meio
  do turno). Cada vaga já nasce com o seu.

## Verificação

`tests/local/60_grupos_test.sql` percorre o fluxo inteiro: PIN visível
só para o grupo, pedido recusado e aceito, só o dono decide, scan da
quadra errada recusado, "saia da sua fila" com e sem confirmação, PIN
errado gastando o scan, trava de 5 tentativas, grupo de 5, dono saindo e
outro herdando, um check-in iniciando o turno, check-in de quem chega
depois sem reiniciar o relógio, PIN com o turno rolando, saídas com o
turno em andamento, chamada não atendida andando a fila sem o cron,
pedido expirando com o grupo, e a tolerância no formulário do admin.

`10_queue_flow_test.sql` e `40_sprint3_test.sql` foram ajustados: o
parceiro entra pedindo e sendo aceito, e o "quem ganha fica" deu lugar ao
turno do grupo.
