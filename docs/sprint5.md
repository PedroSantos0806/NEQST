# Sprint 5 — a fila com anfitrião

> As regras foram aprovadas no PR #15 e implementadas em seguida. A
> parte técnica está em [Como ficou no código](#como-ficou-no-código).

Até aqui, toda entrada na fila começa no QR impresso (ou no totem NFC)
colado na quadra. Para colar alguma coisa no parque é preciso falar com
a organização, e queremos chegar nessa conversa com números: quantas
pessoas usaram a fila, quanto esperaram, quantas baixaram o app no
próprio parque.

Esta sprint deixa o app rodar num parque **sem nada instalado**. A
primeira pessoa que chega com o app abre a fila daquela quadra e passa
a ser o **anfitrião**. Ela informa quem já está jogando e quantos estão
esperando, e quem vem depois entra escaneando um QR que aparece **na
tela de quem já está na fila**.

Quando a organização liberar o QR na placa, a quadra muda de modo e
tudo continua funcionando como na [Sprint 4](sprint4.md).

## Por que o QR na tela não abre uma brecha

O QR impresso nunca foi a trava sozinho. O `scan-court` confere a
assinatura e depois **o GPS de quem escaneou contra a coordenada da
quadra**. Só então emite o scan token de 30 s
([qr-codes.md](qr-codes.md)). Um print do QR mandado para quem está em
casa já não funciona hoje, porque o GPS recusa.

O QR do anfitrião é só outro jeito de entregar o código. A conferência
de distância continua a mesma, e é ela que impede o amigo em casa de
entrar.

## Os dois modos da quadra

| Modo | Como se entra na fila | Como se faz o check-in |
|---|---|---|
| **Anfitrião** (piloto) | QR na tela de alguém da fila + GPS | Botão "Entrando na quadra" + GPS |
| **QR fixo** (como hoje) | QR impresso ou NFC + GPS | QR impresso ou NFC + GPS |

O modo é escolhido quadra a quadra, no admin. No modo anfitrião, a
conferência de distância é **obrigatória**: o admin não consegue salvar
a quadra com `enforce_proximity = false` nesse modo, porque sem ela o
print do QR funcionaria de casa.

## As regras

| Regra | Como fica |
|---|---|
| Quem cadastra parque e quadras | **Nós**, pelo admin, antes de ir ao parque, com a coordenada tirada do mapa |
| Quem abre a fila | A primeira pessoa com o app, **validada por GPS** naquela quadra |
| Na abertura | Informa "em quadra, faltam X min" e "N grupos esperando antes de mim" |
| Quem já estava jogando | Vira um turno **sem app** que acaba sozinho no horário informado |
| Quem esperava sem app | Vira N vagas **sem app**, na ordem, antes da vaga do anfitrião |
| Quem chega sem app depois | O anfitrião registra, **só no fim da fila** |
| Quem mostra o QR | **Qualquer pessoa da fila** já validada naquela quadra |
| O QR | Assinado pelo servidor, **troca a cada 30 s**, e o convite vale **10 min** |
| Entrar na fila | Escaneia, faz login se precisar, e o **GPS é conferido na hora de entrar**. Daí em diante vale o fluxo da Sprint 4: abrir vaga, pedir para entrar, PIN, "saia da sua fila" |
| Check-in | Botão **"Entrando na quadra"**, com o GPS conferido no toque. Basta um do grupo, e a tolerância de 2 min continua valendo |
| Duas aberturas ao mesmo tempo | **Uma fila por quadra**: a segunda pessoa cai na que já existe |
| Fila abandonada | Encerra depois de **30 min** sem ninguém na fila e sem turno rolando, e a próxima pessoa abre uma nova |

## Abrir a fila

A tela "Começar a fila aqui" só aparece numa quadra em modo anfitrião
sem fila ativa. Antes dela, o app pede a localização e o servidor
confere a distância, com a mesma regra do scan.

O anfitrião informa:

- **Em quadra agora?** Se sim, quantos minutos faltam (de 1 até o slot
  da quadra). Vira um turno sem app, com `expires_at` no horário
  informado. Quando vence, a fila anda como qualquer turno vencido.
- **Quantos grupos esperando antes de você?** De 0 a 10. Cada um vira
  uma vaga sem app, com um rótulo opcional ("dupla de boné azul") para
  o anfitrião saber quem é quem.

A vaga do próprio anfitrião entra logo depois dessas, na mesma
transação. Ele não consegue se colocar na frente de quem declarou.

## As vagas sem app

São as pessoas que estavam na fila antes do app existir para elas.
Elas não podem perder a vez para quem tem o app, ou o piloto vira
motivo de briga no parque antes da conversa com a organização.

- Quem cria e quem mexe é **só o anfitrião**: "entraram na quadra" ou
  "desistiram".
- **Não seguem a tolerância de 2 min**, porque não têm como fazer
  check-in. Quando é a vez delas, a fila espera o anfitrião marcar.
- Depois da abertura, só entram **no fim da fila**.
- O anfitrião **nunca remove nem reordena** vaga de quem tem app.
- Cada criação, entrada e desistência fica registrada com quem fez e
  quando.

Se o anfitrião sai da fila com vagas sem app pendentes, quem herda o
papel é o próximo da fila com app, na mesma regra do "dono saiu" da
Sprint 4.

## O QR na tela

Qualquer pessoa da fila, validada por GPS naquela quadra, vê o botão
"Mostrar QR para quem chegou". O QR:

- é um **convite** emitido pelo servidor, com a quadra, quem mostrou e
  quando;
- **troca a cada 30 s** enquanto está na tela;
- usa o mesmo App Link da Sprint 3 (`https://.../q/...`), então a câmera
  do Android abre o app instalado ou cai no site com o aviso de baixar.

### Por que o convite vale 10 min, e não 30 s

Quem nunca usou o app precisa baixar, criar conta e às vezes confirmar
o e-mail. Isso passa de 30 s com folga. Com um convite de 30 s, a
pessoa voltaria com o código vencido justo no primeiro uso, que é o
momento que mais queremos medir.

Então as duas coisas ficam separadas:

- **O convite** só precisa estar dentro dos 10 min para ser aberto.
  O destino já sobrevive à ida ao e-mail (`after-login.ts`).
- **A presença** é conferida na hora de entrar, depois do login. O
  servidor troca o convite por um scan token de 30 s, como no QR fixo,
  só se o GPS estiver dentro do raio da quadra.

Um print mandado no WhatsApp dentro dos 10 min continua sem servir para
quem está em casa, porque a trava é o GPS.

## O check-in sem QR

No modo anfitrião, não há QR na placa para escanear quando o grupo é
chamado. Exigir o QR de outra pessoa da fila deixaria o check-in
dependendo de alguém que pode estar jogando.

Cada pessoa do grupo chamado vê o botão **"Entrando na quadra"**. O
toque manda a localização, e o servidor confere a distância antes de
iniciar o turno. Sem essa conferência, quem foi chamado poderia tocar
de casa e prender a quadra o turno inteiro.

O resto é a Sprint 4: um check-in basta, quem chega depois toca também
e aparece no placar, e o relógio não reinicia.

No modo QR fixo, o check-in por QR ou NFC volta a ser o único caminho.

## Os números do piloto

Cada entrada guarda a sua **origem**: convite de quem (e de qual
anfitrião), QR fixo ou NFC. Com isso, o admin ganha uma aba **Piloto**,
um painel para apresentar à organização do parque:

| Indicador | O que mostra |
|---|---|
| Pessoas na fila pelo app | Total e por dia, por parque e por quadra |
| Vagas com app × sem app | A adesão: quanto da fila real já passa pelo app |
| Funil do convite | QR mostrado → aberto → conta criada → entrou na fila |
| Espera real | Mediana e p90 entre entrar na fila e começar o turno |
| Uso da quadra | Horas de turno por dia e horário de pico (o mapa de calor já existe) |
| Chamadas perdidas | Grupos chamados que não apareceram na tolerância |
| Quem espalha o app | Pessoas que entraram pelo convite de cada usuário |

Os números saem de uma RPC só de admin, sem expor quem é quem: a
organização vê contagens, não nomes.

## Brechas e como ficaram fechadas

| Brecha | Fechamento |
|---|---|
| Print do QR mandado para quem está em casa | GPS conferido na hora de entrar; QR trocando a cada 30 s |
| Quadra em modo anfitrião com a distância desligada | O admin não salva essa combinação |
| Quadra sem coordenada | Não entra no modo anfitrião sem latitude e longitude |
| Convite vencendo durante o cadastro | Convite de 10 min, presença conferida depois do login |
| Anfitrião inventando vagas sem app na frente | Na frente, só na abertura. Depois, só no fim da fila |
| Anfitrião tirando ou reordenando quem tem app | Não existe essa ação |
| Check-in de casa | Botão confere o GPS no toque |
| Anfitrião indo embora | O próximo da fila com app herda o papel |
| QR dependendo só do anfitrião | Qualquer pessoa da fila validada mostra |
| Duas filas abertas na mesma quadra | Uma fila ativa por quadra, garantida no banco |
| Fila esquecida aberta | Encerra com 30 min sem ninguém ativo |
| Vaga sem app travando a fila | Só o anfitrião anda com ela, e o painel mostra quanto tempo ficou parada |

## O que fica de fora

- **GPS falsificado.** Um app de localização falsa engana o raio, aqui
  e no QR fixo. É o mesmo risco de hoje. Se aparecer no piloto, o
  próximo passo é cruzar com o histórico de distância já gravado em
  `scan_tokens`.
- **Remover alguém do grupo** e **trocar o PIN**, que já ficaram de
  fora na Sprint 4.
- **Exportar o painel** em PDF ou planilha. Por enquanto a
  apresentação é a própria tela.

## Verificação

`tests/local/70_anfitriao_test.sql` percorre: a distância que não
desliga no modo anfitrião (pela função e pela constraint); abrir a fila
com turno em andamento e vagas sem app na frente; a segunda abertura
recusada; o token só de GPS recusado para entrar na fila; o convite que
só quem está na fila emite, que troca de código e vale 10 min; a
abertura do convite contada uma vez por visitante; entrar pelo convite
abrindo a própria vaga e com o PIN, com a origem gravada; vaga sem app
só no fim e só pelo anfitrião; o turno de quem já jogava acabando
sozinho; a vaga sem app chamada sem tolerância e esperando o anfitrião;
entraram, saíram e desistiram; o check-in pelo botão; o anfitrião indo
embora e o papel passando adiante; o painel do piloto, só para o admin e
sem nomes; a fila fechando com 30 min sem ninguém; e a troca para QR
fixo fechando a fila aberta.

A distância e o prazo do convite são conferidos na Edge Function
`scan-court`, fora do alcance do teste SQL. O parser do convite tem
testes em `supabase/functions/_shared/qr_test.ts`.

Os testes da Sprint 4 continuam passando sem mudança, porque o modo QR
fixo é o padrão de toda quadra que já existe.

## Como ficou no código

### Banco

Duas migrations: `20261023120000_anfitriao_enums.sql` (valores novos de
enum, separados pelo mesmo motivo da Sprint 4) e
`20261023120100_fila_com_anfitriao.sql`.

| O quê | Onde |
|---|---|
| Modo da quadra | `courts.queue_mode` (`fixed_qr` / `host`) e a constraint `courts_host_mode_needs_proximity` |
| A fila aberta | `host_sessions`, uma aberta por quadra (índice único parcial). `host_user_id` é quem organiza agora |
| Vagas sem app | `queue_entries.is_offline`, `offline_kind` (`playing` = quem já jogava, `waiting` = na fila) e `offline_label`. Não têm membros: o anfitrião é `created_by`, mas não entra nelas |
| O convite | `host_invites`, só com o SHA-256 do código. `display_id` agrupa os códigos de uma mesma exibição do QR |
| A prova de presença | `scan_tokens.method` ganhou `host_invite` e `gps`, e `scan_tokens.invite_id` |
| A origem | `queue_entry_members.origin` e `invite_id`, gravados por gatilho. `scan_tokens` é apagado depois de um dia, e o membro fica |
| O funil | `pilot_events`: convite aberto (antes do login), validado pelo GPS, recusado pela distância |

RPCs novas: `open_host_queue`, `host_add_offline`, `host_mark_offline`,
`issue_host_invite`, `host_invite_opened` (aberta a `anon`, só conta) e
`admin_pilot_stats`. Mudaram: `take_scan_token` (o token `gps` só passa
onde for pedido), `check_in_and_start` e `finish_my_turn` (o anfitrião
devolve a quadra de um turno sem app), `call_next_team` (vaga sem app
sem tolerância, com aviso para o anfitrião), `court_screen`,
`court_queue_items` e `match_state` (campos do modo anfitrião),
`advance_expired_queues` (fecha a fila esquecida), `admin_overview` e
`admin_upsert_court` (o modo da quadra).

Quem organiza é calculado, não guardado: `effective_host` devolve o
anfitrião enquanto ele estiver na fila e, se ele saiu, o dono da próxima
vaga com app. A primeira ação do herdeiro grava a herança em
`host_sessions.host_user_id`.

Códigos novos:

| SQLSTATE | Significado |
|---|---|
| `NQ030` | A quadra não está no modo anfitrião |
| `NQ031` | Já existe uma fila aberta nesta quadra |
| `NQ032` | Dados da fila com anfitrião inválidos |
| `NQ033` | Só quem organiza a fila faz isso |
| `NQ034` | A fila desta quadra não está aberta |
| `NQ035` | No modo anfitrião a distância não pode ser desligada |

### Edge Function

`scan-court` aceita dois caminhos novos:

- **O convite** (`https://.../q/h/<código>` ou `neqst:h1:<código>`):
  confere se o código existe, se não venceu (`HOST_INVITE_EXPIRED`, 410)
  e se a fila dele continua aberta (`HOST_QUEUE_CLOSED`, 409). Depois
  vem a mesma conferência de distância do QR da placa. Recusado pela
  distância, fica gravado em `pilot_events`.
- **Só o GPS** (`method: "gps"` com `courtId`, sem payload): só nas
  quadras em modo anfitrião, para abrir a fila e para o botão "Entrando
  na quadra".

### Web

- `/q/h/:code` cai na mesma tela do QR da placa. Sem login, mostra
  "Chamaram você para a fila", com a instalação do app (PWA no
  Android, instrução no iPhone e, com `VITE_PLAY_STORE_URL`, o link da
  loja) antes do login.
- Na quadra: "Começar a fila aqui", o painel de quem organiza, "Mostrar
  QR para quem chegou" (o código troca a cada 30 s) e o botão "Entrando
  na quadra" no lugar do scan do check-in.
- Na administração: o modo da quadra no formulário e a aba **Piloto**.

### Para publicar

1. Rodar as migrations no Supabase (`supabase db push`, ou colar o
   `db/full_setup.sql` no SQL Editor). Nenhum agendamento novo: a
   rotina de minuto em minuto da Sprint 4 já fecha a fila esquecida.
2. `supabase functions deploy`, para a `scan-court` nova.
3. No admin, cadastrar o parque e as quadras do teste com o alfinete no
   lugar certo, e trocar o modo para **Anfitrião (piloto)**.
