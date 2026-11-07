# Sprint 10 — a fila é um link, e o QR só leva até ele

O Pedro abriu o totem no iPad dele e a tela respondeu
`Missing authorization header`. O erro tinha causa específica (está na
seção 1), mas o pedido que veio junto é maior que o erro:

> "Aquele link que foi gerado no sistema a gente vai abrir no tablet; e
> quando abrir, ele tem que ir direto pra tela da fila, com um botão
> ENTRAR NA FILA para a pessoa colocar o nome e o sobrenome. O QR Code
> serve apenas para a pessoa ser redirecionada para o site, **não como
> meio de entrar na fila**: ele só vai levar direto pro link da fila
> daquela quadra, para a pessoa entrar igual entra pelo tablet."

É uma simplificação de produto com consequência de segurança, e as duas
coisas estão escritas aqui.

---

## 1. O erro: `Missing authorization header`

Não era o banco, não era o link do totem e não era falta de SQL. Era
uma linha do `supabase/config.toml`:

```toml
[functions.scan-court]
verify_jwt = true
```

A Sprint 8 reescreveu `scan-court` para funcionar **sem conta**
(`optionalUser` em vez de `requireUser`), porque escanear a quadra
deixou de exigir login. O código da função ficou certo e a configuração
ficou errada: com `verify_jwt = true`, o gateway do Supabase recusa a
chamada **antes de a função rodar** quando não há um JWT de usuário. A
resposta é um 401 com `{"message":"Missing authorization header"}` — e
foi isso que apareceu na tela.

Quem caía nisso era exatamente quem o produto queria atender: a pessoa
que lê o QR da placa e não tem conta nenhuma.

Duas correções, nas duas pontas:

- `verify_jwt = false` para `scan-court`. A função valida o QR, a
  assinatura, a distância e o corpo da requisição por conta própria —
  ela nunca dependeu do gateway para isso.
- `callFunction` passa a mandar `Authorization: Bearer <chave anon>`
  quando não há sessão, que é o que o `supabase-js` já faz nas chamadas
  de banco. Isso fecha a classe inteira do erro: qualquer função que
  um dia volte a exigir JWT responde "não autorizado" pela regra dela,
  em português, em vez de um 401 cru de infraestrutura.

**Para valer no projeto hospedado, `scan-court` precisa de um
`npx supabase functions deploy`** — `config.toml` é lido na publicação.

---

## 2. Uma tela, dois caminhos de entrada

A tela da fila da quadra agora atende dois endereços:

| Endereço | Quem abre | O que pode |
|---|---|---|
| `/totem/<token do aparelho>` | o tablet parado na quadra, com o link que o `/admin` gerou | ler a fila, entrar nela, **e operar a quadra**: pausar, retomar, continuar o jogo, responder a pergunta de saída |
| `/fila/<quadra>` | o celular de quem leu o QR da placa — e qualquer pessoa com o link | ler a fila e entrar nela |

É a **mesma** tela e o **mesmo** botão: `ENTRAR NA FILA` abre o campo de
nome e sobrenome, e quem confirma entra na fila da quadra. `<quadra>` é
o slug (`/fila/ibira-3`) ou o uuid, o que estiver na URL.

O que o quadro desenha depende do que ele recebe: sem as funções de
operação, os botões de pausa, o Retomar, o Continuar jogando e a
pergunta de saída simplesmente não existem na tela pública. Não é um
botão escondido com `display: none` — é um botão que não foi desenhado.

Duas diferenças pensadas para o celular:

- **o teclado é o do celular.** No totem o teclado é desenhado na tela,
  porque em modo quiosque o teclado do sistema costuma estar bloqueado
  e, quando não está, é uma rota de fuga da aplicação. No aparelho da
  própria pessoa isso não vale: o teclado dela já sabe acento,
  sobrenome e corretor.
- **quem entra pelo link fica com a vaga.** O banco devolve o token da
  pessoa (uma única vez), o navegador guarda, e aparece um atalho
  **Minha vaga** que leva a `/fila` — onde ela vê a posição e sai da
  fila sozinha. No tablet isso nunca aparece: a tela é de todos e não
  guarda segredo de ninguém.

### O QR

O QR impresso passa a carregar **só o link da fila**. Antes ele
carregava uma URL assinada (`/q/<uuid>?v=2&s=<assinatura>`) que a borda
conferia junto com o GPS.

- O `/admin` → quadra → QR já desenha o QR novo, e o mesmo endereço
  serve para gravar na tag NFC.
- Os **QRs já impressos continuam valendo**: `/q/<quadra>` redireciona
  para `/fila/<quadra>`. A assinatura deixa de ser conferida porque não
  gateia mais nada.
- O slug deixa o QR com menos módulos — lê de mais longe, e dá para
  digitar à mão quando a câmera não colabora.

---

## 3. O que isso custa em segurança, dito em voz alta

Antes, entrar na fila pelo celular exigia **provar presença**: escanear
o QR impresso gerava um token de 30 segundos, de uso único, atrelado à
coordenada de quem escaneou. Agora o que autoriza entrar na fila é
**saber o link da quadra** — e o link está impresso numa placa, em
lugar público, o que significa que ele não é segredo de ninguém.

Em termos práticos: **alguém de casa, com o link, entra na fila de uma
quadra onde não está.**

Foi uma decisão de produto, e tem defesa: o remédio deixou de ser
criptográfico e passou a ser o que já existia no mundo real.

- quem está na quadra vê a fila na tela e chama o próximo nome;
- quem não aparece na troca de 1:30 perde a vez para o seguinte;
- o `/admin` remove quem não está lá;
- `expire_stale_queue_entries` limpa quem ficou esperando sem aparecer.

O que o banco ganhou, porque o token de uso único fazia isso de graça e
agora ninguém faz:

| Guarda | Código | Regra |
|---|---|---|
| Teto da fila | `NQ043` | 50 parties esperando por quadra. Nenhuma fila real chega perto (a 40 min por party são mais de 33 horas de jogo); existe contra inundação. |
| Nome repetido | `NQ004` | O mesmo nome entrando duas vezes em 3 minutos é recusado. É o toque duplo no tablet, o refresh do celular, a conexão que caiu depois de gravar. A janela é curta de propósito: dois homônimos de verdade continuam podendo entrar. |

As duas valem para **todos** os caminhos, o totem incluído: o teto é da
quadra, não do caminho.

E o que **não** mudou: operar a quadra continua exigindo o token do
aparelho que o `/admin` registrou. Pausar, retomar, continuar o jogo e
responder pela saída de alguém nunca ficam atrás de um link público.

---

## 4. O que foi verificado

- **11 suítes SQL** em Postgres 16 de verdade, com a
  [82](../tests/local/82_fila_por_link_test.sql) nova: o link abrindo
  por slug e por uuid, a fila única com totem e link alternados, o
  segredo que só o link devolve, entrar no grupo pelo link, as três
  funções de operação recusando o link (`NQ037`), as duas guardas novas
  e a quadra desligada que abre a tela mas não aceita ninguém.
- `db/full_setup.sql` regenerado, aplicado **duas vezes** num banco
  limpo, com **0 funções executáveis por PUBLIC**.
- **103 testes** de front, incluindo o quadro público que não desenha
  comando de operação nenhum.
- `tsc -b --noEmit` e `npm run build` limpos.

---

## Depois do merge

1. **SQL Editor: colar `db/full_setup.sql`.** Sem isso, `queue_screen`,
   `queue_join` e `queue_join_group` não existem e a tela pública
   responde que o banco está na versão anterior.
2. **`npx supabase functions deploy scan-court`** — é o que faz valer o
   `verify_jwt = false` e mata o `Missing authorization header` no
   caminho antigo do QR.
3. No tablet, **recarregar a página do totem**.
4. `/admin` → quadra → **QR**: o endereço mostrado já é o novo. Imprimir
   de novo é opcional — o QR antigo redireciona.
