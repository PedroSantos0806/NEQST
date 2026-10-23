# Sprint 5 — a fila com anfitrião

> **Proposta.** Esta página descreve as regras antes do código, para
> revisão. Nada aqui foi implementado ainda.

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

`tests/local/70_anfitriao_test.sql` deve percorrer: abrir a fila com
turno em andamento e vagas sem app na frente; segunda abertura caindo
na fila existente; convite aceito dentro do raio e recusado fora;
convite vencido depois de 10 min; quadra em modo anfitrião recusando a
distância desligada; vaga sem app só no fim depois da abertura; vaga
sem app ignorando a tolerância; só o anfitrião marcando vaga sem app;
anfitrião saindo e o papel passando adiante; check-in pelo botão
recusado fora do raio; fila encerrando com 30 min de inatividade; e a
origem de cada entrada gravada para o painel.

Os testes da Sprint 4 continuam passando sem mudança, porque o modo QR
fixo é o padrão de toda quadra que já existe.
