# Sprint 8 — o totem da quadra, e a fila sem conta

Esta sprint é a maior virada de produto desde a Sprint 1, e ela não
nasceu de uma ideia nossa: veio do **handoff do mock do totem** (Gabriel
Crespi, 05/11/2026) mais uma decisão do Pedro em cima dele —

> "tem clientes que vão usar o tablet e outros vão usar a NFC e QR Code,
> mas tudo alimenta o mesmo app. Mas não teremos conta mais, a pessoa
> apenas coloca nome e sobrenome."

Duas frases que mudam a base: **a fila deixa de ser de contas e passa a
ser de parties**, e **a quadra deixa de chamar por nome e passa a trocar
de grupo em 1:30**.

A [Sprint 7](sprint7.md) tinha acabado de entregar a chamada de 15
segundos com o botão JOGAR. O handoff substituiu esse fluxo, e a
decisão foi explícita ("vale o handoff"). O que está escrito aqui é o
que vale.

---

## A máquina de estados

Cinco estados. **Todos saem sozinhos pelo relógio, menos Pausada**, que
só sai por toque humano em Retomar.

| De | Para | Gatilho |
|---|---|---|
| Em jogo | Acabando | faltam 60 s |
| Acabando | Em jogo | botão Continuar jogando, **só com a fila vazia** |
| Acabando | Troca 1:30 | tempo zera, sem pausa agendada |
| Acabando | Pausada | tempo zera, **com** pausa agendada |
| Troca 1:30 | Pausada | alguém aperta uma pausa |
| Pausada | Troca 1:30 | alguém aperta Retomar (com os 1:30 **cheios**) |
| Troca 1:30 | Em jogo | entra a próxima party, **sozinha** |
| Troca 1:30 | Quadra livre | fila vazia |
| Quadra livre | Em jogo | alguém entra na fila |

A pausa apertada durante o jogo não aparece como transição porque ela
**não muda o estado**: só marca qual caminho o fim do tempo vai tomar.

```
   acabou o tempo (40 min)
        │
        ├─▶ pergunta para quem jogou:
        │      "acabou seu tempo. Quer sair ou voltar pro fim da fila?"
        │      · respondeu "voltar"  ──▶ vai para o FIM da fila
        │      · não respondeu em 1:30 ──▶ sai (decisão em aberto nº 2)
        │
        └─▶ troca de 1:30 e, no fim dela, o turno da próxima party
             começa SOZINHO — ninguém aperta nada
```

### Constantes

| Constante | Valor | Onde mora |
|---|---|---|
| Duração da partida | 40 min | `courts.slot_minutes` (já era 40) |
| Troca entre jogos | 1 min 30 s | `courts.changeover_seconds` (era 60) |
| Aviso de fim | 60 s | `courts.warn_seconds` |
| Reset do scroll da fila | 12 s sem toque | só na tela |
| Nome | 2 a 40 caracteres | `queue_entries.party_name` |
| Party | 1 a 20 pessoas | `queue_entries.party_size` |

O mock parava o nome em 16 caracteres, porque era só o primeiro nome. O
Pedro pediu **nome e sobrenome**, então são 40.

---

## A fila sem conta

`queue_entries.created_by` deixou de ser obrigatório. Uma vaga agora se
identifica de um de dois jeitos, e uma constraint cobra isso:

- **party**: `party_name` + `party_size`, digitados;
- **conta**: as vagas antigas, que seguem funcionando.

O nome é texto livre de propósito, como no handoff: duas "Marina" em
dias diferentes não têm relação entre si. Isso é aceitável agora e vira
problema na fase de stats — está na seção 8 do handoff e não foi
implementado.

### Quem autoriza a escrita, agora que não há login

Esta é a parte que mais merece atenção de quem for mexer aqui. Sem
conta, **a autorização deixou de ser "quem você é" e passou a ser "de
onde você está escrevendo"**. São três segredos, e nada mais escreve na
fila:

| Segredo | Prova | Vale para |
|---|---|---|
| token do totem | posse do aparelho da quadra (`court_devices`, em hash, revogável) | ver a quadra, entrar na fila, pausar, retomar, continuar, responder a saída |
| scan token | posse do **QR impresso** na quadra + localização conferida | uma entrada na fila, 30 s, uso único |
| party token | o navegador de quem entrou (devolvido UMA vez, guardado em hash) | ver a própria vaga, sair da fila, responder a saída |

Nenhum caminho de jogador usa `auth.uid()`. As funções internas
(`join_party`, `pause_court`, `open_match`, `advance_court`…) continuam
**fechadas para `anon` e `authenticated`** — se `join_party` ficasse
aberta, qualquer um com a chave publicável encheria a fila de qualquer
quadra. O teste `tests/local/90_privilegios_test.sql` cobra isso
nominalmente, função por função.

**O que isto aumenta:** a superfície chamável sem conta passou de 2 RPCs
de leitura para 10 (6 do totem, 4 do celular). Todas exigem um segredo,
mas **rate limiting deixou de ser higiene e passou a ser pendência
real** — um scan token válido ainda pode ser usado em sequência por um
script. Está anotado em [auditoria.md](auditoria.md).

---

## As pausas de manutenção

Três: **vassourão** (limpeza do saibro), **rega** e **exceção** (parada
do parque). Na call apareceu também pausa de hidratação, que não entrou.

**Pausa não tem duração.** Fica aberta até alguém apertar Retomar, e o
cronômetro dela conta **para cima**, sem barra de progresso, porque não
existe fim previsto.

- apertada **durante o jogo**: agenda. O jogo não é interrompido, e a
  pausa começa quando o tempo zerar. Apertar de novo cancela;
- apertada **na troca ou com a quadra livre**: começa na hora;
- **um comando de cada vez**: com a quadra pausada, os três botões de
  pausa somem e entra o Retomar. O custo é não dar para trocar de
  vassourão para rega direto — precisa retomar e pausar de novo.

Com pausa em curso **ou agendada**, a previsão de entrada deixa de ser
calculável: a coluna mostra `--:--` com "depois da pausa". Isso vale na
tela do totem, na tela do celular e no payload do app.

Um detalhe que só aparece em produção: **quadra pausada não expira a
fila de ninguém**. A limpeza por inatividade (3 h) apagaria a fila
inteira de uma quadra parada de propósito — e a pausa existe justamente
para segurar a fila. O teste cobre uma pausa de 4 horas.

---

## A pergunta de saída

Quando o tempo zera, aparece uma faixa com o nome da party e duas
opções:

> **Rafael Lima**, acabou seu tempo. Quer sair ou voltar pro fim da
> fila?

`Voltar pra fila` empurra a party para o fim **com o turno contado**;
`Sair` encerra. A faixa vive durante a troca e **some quando a próxima
party entra**. Se alguém pausar logo depois do fim do jogo, a pergunta
**espera o Retomar** e aparece na troca seguinte, com os 1:30 cheios.

**Sem resposta em 1:30, o padrão é sair.** Essa é a decisão em aberto
nº 2 do handoff, e está implementada como escolha, não como certeza: o
contrário traz de volta o problema de equidade de alguém ficar 80
minutos em quadra.

A mesma frase é **falada** pelo totem. É de propósito: quem está de
costas ouve, quem está de frente lê, e os dois recebem a pergunta
idêntica. O texto mora numa função testada (`exitAskText`), porque é o
único texto do app que ninguém lê — só ouve.

---

## O totem

Rota `/totem/:token` (e `/tablet/:token`, que é o caminho dos links já
gerados — quem identifica o aparelho é o token, não a rota).

- 3:4 em retrato, **unidades de container (`cqh`) em tudo**: a tela
  escala inteira para qualquer tablet sem refazer medida;
- paleta e escala tipográfica do handoff. Archivo passou a ser carregada
  como **variável** (`wdth 100..125`, `wght 400..900`) porque o placar
  usa o eixo de largura;
- **teclado QWERTY próprio na tela**: o do sistema costuma estar
  bloqueado em modo quiosque e, quando não está, é rota de fuga da
  aplicação;
- scroll da fila **contido** (não arrasta a página nem dispara o puxar
  para atualizar) e com reset automático ao topo depois de 12 s sem
  toque, para a próxima pessoa não encontrar a tela no meio da lista;
- **nada de menu, voltar, configurações, perfil ou troca de quadra**.
  Uma tela só, sempre a mesma;
- a linha fina do topo ("Quadra 03 · Saibro · Ibirapuera") **sai do
  banco**, não está mais chumbada como no mock — era a decisão em aberto
  nº 5.

Os três controles de demonstração do mock (adiantar, acelerar 60×,
reiniciar) **não existem**: eram andaime do protótipo.

Toda a regra mora no banco: `totem_screen` devolve estado, relógio,
quem está em quadra, quem entra, a pausa, a pergunta e a fila com
previsão, tudo resolvido. A tela faz três coisas que só o navegador
pode: contar segundos entre leituras, falar em voz alta e desenhar.

### O som

Nenhum arquivo de áudio: apitos gerados com WebAudio e nomes por
`speechSynthesis` em pt-BR. Avisa: **1 minuto para o fim** (com
"liberem a quadra" quando há fila), **fim do turno** (a pergunta de
saída, por nome), **começo do turno**, **pausa** e **liberação**.

O navegador exige um toque antes de tocar som, então a tela pede
**Ativar som** uma vez e depois disso o resto acontece sozinho.

---

## O celular

| | Antes | Agora |
|---|---|---|
| Entrar na fila | login + QR + grupo | QR/NFC → nome e sobrenome |
| Acompanhar a fila | só logado | **sem conta** |
| JOGAR / check-in | no app | não existe: o turno começa sozinho |
| Pausar a quadra | não existia | só no totem |

- `/q/:courtId` (o QR impresso) e `/q/h/:code` não passam mais pelo
  login: validam o código + a localização e levam direto para "digite
  seu nome e sobrenome";
- `/fila` é a tela de quem entrou: posição, estado da quadra, previsão
  de cada posição, a pergunta de saída quando é a sua, e sair da fila;
- `/`, `/parque/:id` e `/quadra/:id` abrem sem conta. Sem sessão, a tela
  da quadra esconde as ações de conta e aponta para o totem ou o QR;
- `/perfil` e `/admin` continuam atrás de conta.

**O que não foi demolido, de propósito:** perfil, grupos com convite,
modo anfitrião e push por usuário continuam no código e funcionando para
quem tem conta. "Não teremos conta" foi dito sobre *entrar na fila*;
apagar essas quatro features é decisão de produto, não consequência
técnica.

---

## O que mudou no banco

Migration: `supabase/migrations/20261106120000_totem_da_quadra.sql`.

**Colunas novas**

| Tabela | Coluna | Para quê |
|---|---|---|
| `queue_entries` | `party_name`, `party_size` | a party digitada |
| `queue_entries` | `party_token_hash` | o segredo do navegador de quem entrou |
| `queue_entries` | `source` | `totem`, `qr`, `nfc` ou `app` |
| `courts` | `warn_seconds` | o aviso de 1 minuto |
| `courts` | `pause_kind`, `paused_at` | a pausa em curso |
| `courts` | `armed_pause_kind` | a pausa agendada |
| `courts` | `exit_ask_entry_id` | de quem é a pergunta de saída |

`queue_entries.created_by` e `scan_tokens.user_id` deixaram de ser
obrigatórios.

**RPCs novas**

| Função | Quem chama |
|---|---|
| `totem_screen`, `totem_join`, `totem_pause`, `totem_resume`, `totem_continue`, `totem_exit_answer` | o totem, com o token do aparelho |
| `scan_join_party` | o celular, com o scan token do QR/NFC |
| `party_screen`, `party_leave`, `party_exit_answer` | o celular, com o party token |
| `join_party`, `pause_court`, `resume_court`, `continue_playing`, `answer_exit_ask`, `totem_state`, `tick_court`, `entry_label`, `entry_size`, `party_label`, `take_anon_scan_token`, `take_party_entry`, `totem_court` | internas, fechadas para o cliente |

**O que saiu**

`skip_handover`, `accept_handover`, `accept_turn`, `tablet_accept_turn`,
`tablet_screen`, `court_tablet_awake`, as colunas
`handover_call_seconds`, `handover_entry_seconds`, `handover_calls_left`
e `queue_entries.accepted_at`/`accepted_by`. Era o fluxo da Sprint 7, e
código que não vale mais confunde mais do que ajuda.

`handover_phase` sobreviveu, mas agora só tem um valor:
`'changeover'`.

**Dois defeitos que os testes pegaram antes do push**

1. `requeue_entry` inseria a vaga nova com o party token **antes** de
   liberar o da vaga velha, e o índice único recusava a volta para a
   fila;
2. `expire_stale_queue_entries` esvaziaria a fila de uma quadra pausada
   por mais de 3 h.

---

## Decisões do handoff que continuam em aberto

O handoff lista seis, e o mock chutou um valor para cada. O que está
implementado é o chute dele, e nenhuma está fechada:

- [ ] **Quem pode apertar a pausa.** Hoje: qualquer um no totem. Como a
      pausa não tem duração, uma pessoa trava a quadra por tempo
      indefinido. Provavelmente vira perfil — em clube, tecla de
      funcionário com PIN; em praça pública, do jogador.
- [ ] **Padrão da pergunta de saída sem resposta.** Hoje: sai.
- [ ] **Jogador solo.** O totem aceita party de 1 e trata igual às
      outras; não existe regra de solo entrando para completar jogo
      alheio, que é o atrito relatado no Ibirapuera.
- [ ] **Grupo ímpar.** Parte do grupo cumpriu os 40 minutos e trava o
      parceiro. Não tem representação: a fila é por party, não por
      pessoa.
- [x] **Rótulo da quadra por perfil.** Resolvido: sai do banco.
- [ ] **Brilho e película.** Decisão de hardware. Sob sol direto pedem-se
      800 a 1000 nits e tablet comum entrega 400 a 500.

E as fases futuras mapeadas no handoff e **não implementadas**: app como
extensão de leitura com notificação por quadra (não por pessoa), código
de entrada de 4 dígitos, stats do jogador, e dados de ocupação para a
Úrbia e para os clubes — este último independe de cadastro e **custa só
gravar os eventos com data e hora desde o primeiro dia**, que é o que já
acontece.

---

## Depois do merge

1. **SQL Editor:** colar `db/full_setup.sql`. Ele revoga grants e troca
   a máquina de estados — aplicar é o que faz valer.
2. **`/admin` → quadra → Totem → Gerar link.** Abra no tablet, em modo
   quiosque, e toque **Ativar som** uma vez.
3. **Imprima o QR da quadra** se ainda não estiver na placa: é o segundo
   caminho de entrada, e agora funciona sem conta.
4. Conferir o cron: `select * from cron.job;`
5. `npx supabase functions deploy` — `scan-court` mudou (aceita scan sem
   conta).
