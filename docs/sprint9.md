# Sprint 9 — a fila é única, e dá para entrar no grupo

Duas frases do Pedro, em cima da [Sprint 8](sprint8.md):

> "Para entrar na fila teremos 2 opções: via QR Code, que leva pra tela
> direto da quadra, onde ele coloca o nome e o sobrenome, ou apenas
> colocando o nome e sobrenome direto do tablet. Mas independente de
> qual dos jeitos a pessoa use para entrar na fila, **a fila é ÚNICA por
> quadra**."

> "Poderá **entrar em um grupo** (igual já fazemos hoje de ter 'equipe'),
> mas **sem a parte de aprovação** de uma pessoa: ele apenas clica no
> grupo (pelo celular ou direto no tablet) e entra."

A primeira já era verdade no banco e esta sprint prova isso com teste. A
segunda é código novo: `queue_party_members`, duas RPCs e dois botões.

---

## 1. A fila é única por quadra

Não há "fila do totem" e "fila do QR". Há **uma** fila por quadra, e a
origem é só um campo de quem entrou:

| Caminho | Como entra | `source` |
|---|---|---|
| Tablet na quadra | digita nome e sobrenome no totem | `totem` |
| QR impresso na placa | o QR abre a tela da quadra no celular, digita nome e sobrenome | `qr` |
| NFC (tag na placa) | aproxima o celular, mesma tela | `nfc` |

As três entradas chamam a mesma função (`join_party`) e caem na mesma
tabela (`queue_entries`), ordenada por `joined_at`. Quem chegou primeiro
joga primeiro, tenha chegado pelo tablet ou pelo celular. O
[teste 81](../tests/local/81_grupo_na_fila_test.sql), seção 1, monta uma
fila alternando totem e QR e confere que a ordem sai `Marina Souza | Zé
do Ibira | Priscila Alves` — a ordem de chegada, não a de caminho.

O que muda por caminho é só **onde a vaga é lembrada**:

- Pelo **totem** não há navegador para lembrar de ninguém. O nome fica
  na tela da quadra e é isso.
- Pelo **QR/NFC** a pessoa recebe um token no `localStorage` do próprio
  celular, e por isso consegue acompanhar a posição e sair sozinha.

---

## 2. Entrar no grupo, sem aprovação

Antes, entrar junto significava uma party com `party_size` maior: quem
digitou o nome respondia por todos, e os outros não existiam no banco.
Agora cada pessoa do grupo é uma linha:

```sql
create table public.queue_party_members (
  id         uuid primary key default gen_random_uuid(),
  entry_id   uuid not null references public.queue_entries (id) on delete cascade,
  name       text not null,
  -- Nulo quando a pessoa entrou pelo totem: lá não há navegador a
  -- lembrar de ninguém.
  token_hash text,
  source     text not null default 'totem',
  joined_at  timestamptz not null default clock_timestamp(),
  left_at    timestamptz
);
```

**Sem aprovação de ninguém.** Toca no grupo, escreve o nome, está
dentro. Não existe pedido, nem fila de pedidos, nem dono do grupo: o
grupo é uma vaga na fila, e quem está ao lado dela na quadra pode somar.
O que protege o lugar na fila não é aprovação, é o relógio — entrar num
grupo **não muda** o `joined_at` da vaga, então ninguém fura fila
entrando num grupo que está na frente, e também ninguém perde posição
por aceitar gente.

Duas portas, a mesma função:

| Quem toca | RPC | O que gasta |
|---|---|---|
| alguém no tablet | `totem_join_group(device_token, entry_id, name)` | nada; o tablet tem token fixo |
| alguém no celular, depois do QR | `scan_join_group(scan_token, entry_id, name)` | o scan token, de uso único |

Ambas chamam `join_group(entry_id, name, source)`, que é onde as recusas
vivem:

| Situação | Código | Mensagem |
|---|---|---|
| o grupo já está em quadra | `NQ009` | não dá para entrar em quem já está jogando |
| a vaga não está mais na fila | `NQ009` | o grupo saiu |
| o grupo chegaria a mais de 20 pessoas | `NQ042` | limite da quadra |
| nome com menos de 2 ou mais de 40 letras | `NQ041` | escreva o nome com 2 a 40 letras |
| o totem/QR é de **outra** quadra | `NQ007` | grupo não encontrado |

A última é a que importa para a segurança: o `entry_id` é público (sai
na tela da quadra), então a autorização não é saber o id — é **estar na
quadra**, provado pelo token do aparelho ou pelo scan do QR impresso.

### O que a pessoa vê

No **totem**, cada linha da fila ganha um `+ Entrar` ao lado do nome.
Tocar nele abre o mesmo teclado de sempre, só que sem o contador de
pessoas (o tamanho é do grupo, não dela) e com um aviso dizendo em qual
grupo ela está entrando.

No **celular**, depois do QR, a tela mostra os dois caminhos na mesma
rolagem: o botão **Entrar na fila** (party nova) e, abaixo, **"Ou entre
em um grupo que já está na fila"** com uma linha por grupo — nome,
posição e rótulo. Quem entra pelo celular recebe o **próprio** token, e
passa a ver a posição e a sair sozinho: sair do grupo não derruba os
outros, e o último a sair cancela a vaga.

O nome da vaga passa a sair dos membros: `"Marina Souza"`, `"Marina
Souza + Bruno Dias"`, e `"Marina Souza + Bruno Dias + 3"` da terceira
pessoa em diante. É `entry_label`, a mesma função que o totem, o
celular e a chamada por voz usam — um lugar só.

### Voltar pra fila leva o grupo inteiro

Quando o tempo acaba e o grupo responde "voltar pro fim da fila",
`requeue_entry` copia cada membro para a vaga nova, um por um, mantendo
o `joined_at` de cada um e **o token de cada celular**. Quem acompanhava
pelo celular continua acompanhando, sem escanear de novo.

O token é movido, não duplicado: o índice único de
`queue_party_members.token_hash` (parcial, só para quem não saiu) exige
limpar o da linha antiga **antes** de inserir a nova. Foi o primeiro bug
real desta sprint.

---

## 3. O bug que o teste achou: quadra livre não começava jogo

Fora da entrada na fila, **nada** fazia uma quadra livre com gente na
fila começar o turno de alguém. A transição "Quadra livre → Em jogo"
existia só dentro de `join_party`: se a última party saísse e a fila
não estivesse vazia, a quadra ficava livre com gente esperando até que
alguém novo entrasse na fila.

Dava para não ver isso enquanto cada party era uma pessoa só, porque na
prática quem estava na fila era quem acabava de entrar. Com grupos, o
teste 81 caiu em cima: Ana entra num grupo que está na fila de uma
quadra que acabou de vazar, e ninguém começa a jogar.

A correção é `start_free_court(court_id)`:

- só para **parties** (`party_name is not null`), que é a fila sem
  conta; quem tem conta continua com check-in e tolerância, que é outra
  máquina;
- só para quem está **primeiro** na fila;
- chamada em `tick_court` (fora do `if` de "algo expirou", porque aqui
  nada expirou — a quadra só está vazia) e no fim de `advance_court`.

---

## 4. O que foi verificado

- **10 suítes SQL** em Postgres 16 de verdade, incluindo a 81 nova com
  6 cenários: fila única alternando totem e QR, entrar pelo totem (sem
  token devolvido), entrar pelo celular (com token, sem gastar o scan na
  leitura da fila), sair sem derrubar o grupo, as cinco recusas, e
  "voltar pra fila" carregando o grupo e os segredos.
- `db/full_setup.sql` regenerado por `scripts/build-full-setup.sh`,
  aplicado **duas vezes** num banco limpo, com **0 funções executáveis
  por PUBLIC**.
- **102 testes** de front (`vitest`), incluindo o `+ Entrar` de cada
  linha do totem e a lista de grupos do celular.
- `tsc -b --noEmit` e `npm run build` limpos.

---

## Depois do merge

1. **SQL Editor:** colar `db/full_setup.sql`. Sem isso, nada desta
   sprint existe — o merge publica só o app web.
2. Nada muda nas Edge Functions nesta sprint: não precisa de
   `functions deploy`.
3. No tablet, recarregar a página do totem uma vez para pegar o `+
   Entrar`.
