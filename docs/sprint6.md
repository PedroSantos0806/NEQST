# Sprint 6 — a quadra anda sozinha

Até a Sprint 5, o fim de um turno fazia três coisas: liberava a quadra,
tirava da fila quem tinha jogado e chamava o próximo, que tinha a
tolerância da quadra para **fazer check-in** e começar o relógio dele.

Na quadra pública, isso dependia de todo mundo estar com o celular na
mão no minuto da troca — e quem acabou de jogar quer voltar para o fim
da fila e jogar de novo, não sair da fila.

A regra passa a ser:

```
   acabou o tempo          troca de 1 min             começa o turno
   do grupo em quadra  ──▶  sai quem jogou,       ──▶  do próximo,
                            entra o próximo            com o slot inteiro
                                   │
                   quem jogou vai para o FIM da fila
```

**Ninguém precisa tocar em nada para a fila andar.** O grupo entra na
fila quando chega e sai quando vai embora. Quem faz a quadra andar é o
`advance_expired_queues()`, agendado de minuto em minuto
([deploy.md](deploy.md)), com um empurrão de quem está com a tela aberta
(abaixo).

## O que acontece em cada caso

| Como o turno termina | Quem jogou | A quadra | O próximo |
|---|---|---|---|
| **Acabou o tempo**, com fila atrás | vai para o **fim da fila** | entra em **troca** por 1 min | começa o turno **sozinho**, slot inteiro |
| **Acabou o tempo**, sem ninguém atrás | sai da fila | **libera** | — |
| **Devolveu a quadra** antes da hora | sai da fila | libera | é **chamado**, com a tolerância, e entra pelo check-in |
| **Último do grupo saiu** da fila | sai da fila | libera | é chamado, com a tolerância |

As duas últimas linhas são de propósito. Quem devolve a quadra escolheu
parar, então não volta para o fim da fila. E o próximo, nesses casos,
não estava olhando o relógio: começar o turno dele sozinho queimaria o
slot de um grupo que pode nem estar na quadra ainda.

## O que o check-in ainda faz

Dois lugares, só:

1. **O primeiro turno de uma fila.** Quem abre a fila cadastra quem já
   estava jogando, cadastra quem já esperava sem app, passa o PIN para
   os amigos e **então** marca "Entrando na quadra" — é esse toque que
   começa o relógio ([Sprint 5](sprint5.md)). É também o único lugar em
   que não aparecer ainda custa a vez: sem isso, quem abre a fila e vai
   embora travaria a quadra.
2. **Como atalho, durante a troca.** O grupo que está entrando pode
   tocar em "Já estamos em quadra · começar agora" e não esperar o
   contador. É um atalho, nunca uma obrigação: a vez não se perde se
   ninguém tocar.

## A troca de 1 minuto

Fica na quadra, como o slot e a tolerância:
`courts.changeover_seconds`, padrão **60 s**, faixa de 15 s a 10 min.
Não está no formulário do admin ainda — para mudar numa quadra:

```sql
update public.courts set changeover_seconds = 90
 where slug = 'ibirapuera-q1';
```

Enquanto `courts.changeover_until` está no futuro, a quadra está
trocando de grupo: sem partida, mas também não livre. A tela mostra
`Troca de grupo`, a contagem regressiva e quem está entrando.

### Por que existe um empurrão do app

O cron roda de minuto em minuto. Uma troca de 60 s esperando o próximo
tique duraria, na pior hora, quase dois minutos — e quem está na quadra
veria o contador zerar e nada acontecer.

Então a tela da quadra chama `nudge_court(court_id)` quando o contador
zera. Essa função **não decide nada**: ela executa o que já estava
vencido (o turno, a troca, uma chamada) e devolve a tela. Chamar fora de
hora não faz nada, então não dá para pular a vez de ninguém com ela.

## Cada turno é uma vaga nova

`queue_entries.queue_number` é `generated always as identity`: não dá
para empurrar uma vaga para o fim mudando o número dela. E nem seria
certo — cada turno tem o seu próprio histórico. Então o grupo que sai de
quadra **ganha uma vaga nova no fim da fila**, carregando:

- os mesmos integrantes (menos quem saiu no meio do turno);
- o **mesmo PIN** — quem recebeu os 4 dígitos há meia hora continua
  entrando. Só troca se outro grupo da quadra já estiver com aquele
  número;
- `first_joined_at`, a hora em que o grupo chegou de verdade. É isso que
  a tela mostra como "na fila desde", e é isso que a regra da fila
  esquecida lê — uma vaga recriada a cada turno não pode fazer uma fila
  de fantasmas parecer viva;
- `turn_number`, que a tela usa para dizer *"vocês já jogaram e voltaram
  para o fim da fila"* em vez de deixar parecer que a vaga foi perdida.

`requeued_from` aponta para a vaga do turno anterior.

### O painel do piloto conta chegadas, não rodadas

"Quantos grupos entraram na fila" e "por onde cada pessoa chegou" são
perguntas sobre **chegada**. Com a rotação, o mesmo grupo passa a ter
uma vaga por turno: numa tarde de três horas, o grupo da manhã inteira
apareceria quatro vezes. Então `app_entries`, `offline_entries` e
`origins` leem só as vagas com `requeued_from is null`.

Já `turnos`, `espera` e `chamadas` são medidas **por turno**: continuam
lendo todas as vagas, porque é isso que elas medem.

## A espera estimada

Uma rodada da quadra passa a custar **slot + troca**. Sem isso, a
estimativa erraria 1 minuto por grupo à frente — numa fila de seis
grupos, meia volta de relógio. `court_screen` devolve `turn_seconds` e
já soma a troca em `total_wait_seconds` e no `eta_seconds` de cada
grupo da fila.

## O que isto não resolve

**Um grupo que vai embora sem sair da fila continua na roda.** Com fila
atrás, ele volta a ocupar a quadra a cada rodada, e ninguém de fora tem
como saber que não há ninguém lá.

Não há como o app descobrir isso sozinho: qualquer regra de "sem sinal
há X minutos" também derrubaria um grupo que está simplesmente jogando,
sem mexer no celular. Detectar de verdade exigiria pedir uma confirmação
a cada turno — exatamente o que esta sprint tira do caminho.

As saídas são humanas, e as duas já existem:

- qualquer pessoa do grupo toca em **"Sair da fila"** ao ir embora — é a
  única coisa que o app pede de quem está na fila;
- a **operação do parque** (papel `staff` ou `admin`) remove o grupo
  pelo `leave_queue`, e o anfitrião tira uma vaga sem app com
  "desistiram".

Vale medir no piloto: se a fila de uma quadra movimentada acumular
grupos fantasmas, o caminho mais provável é uma confirmação leve a cada
N rodadas — e não a cada turno.

> **A [Sprint 7](sprint7.md) atacou isto por dois lados.** Numa quadra
> com tablet, o grupo que foi embora não aperta JOGAR quando é chamado,
> então desce a fila a cada rodada em vez de ocupar a quadra. E a conta
> de administrador passou a ter um **×** em cada grupo da fila, para
> limpar de vez.

## O admin ajusta o relógio do turno

O relógio da quadra é o do banco e começa quando o turno começa. Na
quadra real isso sai errado de vez em quando: o grupo entrou cinco
minutos antes de alguém marcar, a troca demorou mais que o minuto, o
anfitrião marcou "entraram" com o grupo ainda juntando as raquetes.
Antes, não havia o que fazer — ou se esperava um turno errado até o fim,
ou se devolvia a quadra e a fila andava cedo.

Com o turno em andamento, quem entra com a **conta de administrador** vê
na tela da quadra um bloco `ADMIN · TEMPO DO TURNO` com o que falta e os
passos de −5, −1, +1 e +5 minutos, além de **Encerrar o turno agora**.

```sql
-- "faltam 12 minutos neste turno"
select public.admin_set_match_time('<match_id>', 12);
```

Três decisões:

- **O contrato é o total, não o passo.** A RPC recebe "faltam N
  minutos", de 0 a 240. Dois administradores mexendo ao mesmo tempo não
  somam ajustes sem perceber, e repetir a chamada não muda nada. Os
  botões de ±5 mandam o total já calculado.
- **Zero encerra agora**, e a quadra anda como em qualquer fim de tempo:
  1 minuto de troca, o próximo entra sozinho, quem jogava vai para o fim
  da fila.
- **O ajuste é público.** `matches.time_adjusted_at`,
  `time_adjusted_by` e `time_adjusted_seconds` ficam gravados, e a tela
  de todo mundo mostra *"o tempo deste turno foi ajustado pela
  organização da quadra"*. Um relógio que pula sem explicação parece app
  quebrado — e quem está em quadra merece saber que foi uma correção.

Só `admin` (`NQ023` para qualquer outra pessoa). Se um dia a operação do
parque (`staff`) precisar disso, é trocar `require_admin()` por uma
checagem de `is_staff()`.

## Como ficou no código

| Onde | O que |
|---|---|
| `supabase/migrations/20261102120000_rotacao_automatica.sql` | a sprint inteira |
| `courts.changeover_seconds` / `changeover_until` | a troca |
| `queue_entries.first_joined_at` / `requeued_from` / `turn_number` | a vaga que volta |
| `requeue_entry(entry_id)` | recoloca o grupo no fim |
| `close_match(...)` | abre a troca e roda a fila no fim do tempo |
| `advance_court(court_id)` | começa o turno do próximo quando a troca acaba |
| `nudge_court(court_id)` | o empurrão de quem está com a tela aberta |
| `court_screen` / `court_queue_items` | a troca na tela e a espera com ela |
| `web/src/screens/Court.tsx` | o cartão da troca e a contagem |
| `tests/local/80_rotacao_test.sql` | a rotação ponta a ponta |
| `web/src/screens/__tests__/court-troca.test.tsx` | a tela na troca |
| `supabase/migrations/20261102130000_admin_ajusta_o_tempo.sql` | o ajuste de relógio |
| `admin_set_match_time(match_id, minutos)` | quanto falta, dito pelo admin |
| `stepMatchMinutes()` em `web/src/lib/limits.ts` | o passo dos botões, preso na faixa |
