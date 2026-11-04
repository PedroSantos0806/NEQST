# Sprint 7 — a chamada no tablet, com som

A [Sprint 6](sprint6.md) fez a quadra andar sozinha: no fim do tempo, 1
minuto de troca e o turno do próximo começava. Faltava a parte que
acontece na quadra de verdade — **alguém dizer em voz alta "é a vez de
vocês"**, e alguém do grupo responder.

Agora a quadra tem um **tablet**: um aparelho parado na quadra que chama
os próximos pelo nome, mostra o relógio em letra grande e tem o botão
**JOGAR**.

```
   acabou o tempo
        │
        ├─▶ quem jogou vai para o FIM da fila
        │
        └─▶ o tablet chama o 1º da fila pelo nome, por 15 s
              │
              ├─ alguém do grupo aperta JOGAR ──▶ 30 s para entrar
              │                                      │
              │                                      ▼
              │                             começa o tempo do turno
              │
              └─ ninguém aperta em 15 s ──▶ esse grupo vai para o fim
                   da fila e a chamada desce para o seguinte
```

**Basta uma pessoa apertar.** Não é check-in de cada jogador: é o grupo
respondendo à chamada.

## As três decisões que faltavam

| Pergunta | Resposta |
|---|---|
| Como o tablet entra no app? | **Link próprio da quadra, sem login.** Um aparelho num parque público não pode carregar a conta de ninguém. |
| Quem não aceita em 15 s? | **Vai para o fim da fila.** Não perde a vaga, perde a posição. |
| A chamada passou a fila inteira e ninguém aceitou? | **A quadra fica livre e o anúncio para.** Volta a andar quando alguém apertar JOGAR. |

## Onde a chamada vale — e por que não vale em todo lugar

Chamar por 15 segundos só faz sentido se alguém estiver **gritando os
nomes**. Numa quadra em modo anfitrião não há tablet nenhum: ali a
chamada passaria a fila inteira para trás a cada 15 s, sem ninguém ouvir,
e no fim a quadra ficaria livre do mesmo jeito — depois de embaralhar a
fila por nada.

Então a quadra tem dois jeitos de trocar de turno, e quem escolhe é a
presença de um tablet **aceso**:

| | Com tablet aceso | Sem tablet |
|---|---|---|
| Fim do turno | chamada de 15 s, descendo a fila | troca automática de 1 min |
| Para o turno começar | alguém aperta **JOGAR** + 30 s para entrar | começa **sozinho** |
| Quem não responde | vai para o fim da fila | não se aplica |

"Aceso" é ter falado com o servidor nos últimos **2 minutos**. A tela do
tablet conversa a cada 5 s, então tablet desligado, sem internet ou com a
aba fechada volta sozinho para a troca automática. É a diferença entre a
quadra parar e a quadra andar.

## O tablet

### Como instalar

1. **/admin**, na quadra → botão **Tablet** → **Gerar link de um tablet**.
2. O link aparece **uma única vez**. Copie e abra no tablet.
3. No tablet, toque em **Ativar som** uma vez. O navegador não deixa um
   site tocar som antes de alguém tocar na tela — depois disso o resto
   acontece sozinho.
4. Deixe a tela aberta. Vale ligar o "manter a tela acesa" do aparelho.

Perdeu o link ou o aparelho? **Revogar** no mesmo painel: o tablet para
na hora, e nenhuma conta foi exposta.

### O que o link pode fazer

Exatamente duas coisas: **ver aquela quadra** e **aceitar a vez de quem
está sendo chamado**. Não tem perfil, não abre `/admin`, não entra na
fila por ninguém, não remove ninguém.

Quem tiver o link e estiver longe pode, no máximo, começar o turno de
quem já era o próximo da fila — não pula a vez de ninguém. É um estrago
pequeno e revogável num clique, e é o mesmo raciocínio do QR impresso: a
prova de presença é o aparelho estar na quadra.

O banco guarda só o **hash** do token (`court_devices.token_hash`), como
faz com o segredo do QR. O que não é guardado não vaza.

## O som

Nenhum arquivo de áudio: tudo sai do próprio navegador.

| Quando | O que toca |
|---|---|
| Falta **1 minuto** para o turno acabar | dois apitos + "Falta um minuto" |
| **Acabou** o turno | três apitos descendo + "Tempo esgotado" |
| **Chamando** os próximos | apito subindo + *"Ana e Bruno, é a vez de vocês. Aperte jogar no tablet."*, repetido a cada 6 s enquanto os 15 s correm |
| **Aceitaram** | apito + "Vocês têm 30 segundos para entrar na quadra" |
| **Começou** o turno | três apitos subindo + "Começou o tempo de quadra. Bom jogo!" |

Os apitos são gerados na hora com WebAudio — sem arquivo para baixar,
sem licença, e funcionam offline. Os nomes saem por `speechSynthesis` em
pt-BR, que é a única forma de falar "Ana e Bruno": áudio gravado nunca
saberia o nome de quem chegou hoje.

A frase da chamada é montada em `callText()` e tem teste próprio
(`web/src/lib/__tests__/sound.test.ts`). É o único texto do app que
ninguém **lê** — só ouve —, então é no teste que ele é conferido: um "é a
sua vez" para uma dupla soaria errado o dia inteiro.

## O admin tira gente da fila

Na tela da quadra, quem entra com a conta de administrador vê um **×** em
cada grupo da fila. Pergunta antes, porque é a vez de outra pessoa que
está sendo apagada, e grava o motivo (`removido_pelo_admin`).

O caso real é o grupo que **foi embora sem sair da fila**: era a lacuna
conhecida da Sprint 6 ([o que ela não resolvia](sprint6.md#o-que-isto-não-resolve)).
Com a chamada, esse grupo já se resolve melhor sozinho — ninguém aperta
JOGAR por ele e ele desce a fila a cada rodada —, mas quem organiza passa
a ter como limpar de vez.

## O que mudou no banco

| Onde | O que |
|---|---|
| `court_devices` | o tablet de cada quadra: token em hash, `last_seen_at`, revogação |
| `court_tablet_awake(court)` | tem alguém para gritar os nomes? |
| `courts.handover_phase` | `calling`, `entering` ou `changeover` |
| `courts.handover_entry_id` / `handover_until` | quem está sendo chamado e até quando |
| `courts.handover_calls_left` | quantas chamadas ainda cabem nesta volta da fila |
| `courts.handover_call_seconds` / `handover_entry_seconds` | 15 s e 30 s, por quadra |
| `queue_entries.accepted_at` / `accepted_by` | quem respondeu pelo grupo (nulo = foi o tablet) |
| `start_handover` / `skip_handover` / `accept_handover` | a máquina de estados |
| `accept_turn(court)` | o JOGAR do celular |
| `tablet_screen(token)` / `tablet_accept_turn(token)` | o JOGAR e a tela do tablet, sem conta |
| `admin_create_court_device` / `admin_court_devices` / `admin_revoke_court_device` | o link do tablet |

`courts.changeover_until` saiu: quem guarda o prazo agora é
`handover_until`, para os três jeitos de trocar de turno terem um relógio
só. `changeover_seconds` ficou — é a duração da troca automática.

Para mudar os tempos de uma quadra:

```sql
update public.courts
   set handover_call_seconds = 20,    -- chamada
       handover_entry_seconds = 45    -- entrada
 where slug = 'ibirapuera-q1';
```

## Como ficou no código

| Onde | O que |
|---|---|
| `supabase/migrations/20261104120000_chamada_do_turno.sql` | a máquina de estados e o `court_devices` |
| `supabase/migrations/20261104130000_tablet_da_quadra.sql` | as RPCs do tablet e do admin |
| `web/src/screens/Tablet.tsx` | a tela da quadra, em `/tablet/:token` |
| `web/src/lib/sound.ts` | apitos e fala |
| `web/src/screens/Court.tsx` | o cartão da chamada no celular e o × do admin |
| `web/src/screens/Admin.tsx` | gerar, listar e revogar o link do tablet |
| `tests/local/80_rotacao_test.sql` | a chamada ponta a ponta, a volta da fila, o tablet |
| `web/src/screens/__tests__/tablet.test.tsx` | a tela do tablet |
| `web/src/screens/__tests__/court-chamada.test.tsx` | as três formas da troca no celular |
