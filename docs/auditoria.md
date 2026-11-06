# Resposta à auditoria de segurança

Auditoria estática de 100% do repositório, feita no HEAD `6b905f5`
(55 commits, 23/09 a 02/11/2026). Este documento registra o que foi
corrigido, **o que foi medido diferente do relatório** e o que ficou de
fora com o motivo.

Nada aqui foi aceito sem reprodução: cada achado crítico e alto foi
testado num Postgres 16 descartável antes de virar correção, e o que
virou correção ganhou teste.

## O que foi reproduzido, e o que não

| Achado | Reproduzido? | Observação |
|---|---|---|
| **C1** escalação a admin por e-mail forjado | **parcialmente** | o primeiro passo é real: qualquer conta logada gravava `email = 'admin@neqst.com'` no próprio perfil. O segundo é **um sorteio, não uma certeza** — ver abaixo |
| **C2** SSRF com vazamento da chave VAPID | sim | a única validação era o prefixo `https://` |
| **C3** roubo de canal de push | sim | `upsert` por `endpoint`/`token` com `service_role` |
| **C4** 61 funções com EXECUTE para PUBLIC | sim, exatamente 61 | e **nenhuma** delas dependia só disso: todas tinham grant para `authenticated`, então revogar não quebrou nada |
| **A1** nome completo sem login | sim | `anon` executava `court_queue_items` e `match_side_players` |
| **A2** `expire_stale_queue_entries` | sim | os dois defeitos |
| **A4** CORS `*` no `admin-court-qr` | sim | única função fora do wrapper `serve()` |
| **A5** CORS fail-open sem `ALLOWED_ORIGINS` | sim | — |
| **A6** CVEs nas devDependencies | sim, mas **a correção proposta não corrige** | ver abaixo |
| **A7** jsQR no chunk crítico | sim | medido: −48 kB gzip |

### C1: é sorteio, não exploit determinístico

O relatório afirma que o operador "promove o atacante". Na reprodução,
com duas linhas carregando o mesmo e-mail, o Postgres escolheu **o admin
de verdade** — `select ... into` sem `order by` devolve uma linha
arbitrária, e qual depende do plano e da ordem física.

Isso não torna o achado menos grave: um sorteio para dar acesso de
administrador a um desconhecido é tão inaceitável quanto a certeza. Mas
a diferença importa para quem for reproduzir e achar que o relatório
errou.

### A6: o bump de patch não fecha as críticas

O relatório diz que `vitest → 2.1.9` e `vite → 5.4.21` matam as duas
críticas "sem breaking change". Medido hoje, não matam: a advisory
crítica do vitest cobre **`<3.2.6`** e a do `tinypool` cobre `<2.1.2`.
Ou seja, a linha 2.x inteira está afetada — provavelmente o relatório
leu a faixa de uma advisory anterior.

O que de fato fechou:

| | Antes | Depois |
|---|---|---|
| vitest | 2.1.8 | **5.1.0** |
| vite | 5.4.11 | **8.3.5** |
| @vitejs/plugin-react | 4.3.4 | **6.2.1** |
| Vulnerabilidades | 8 (2 críticas, 1 alta, 5 moderadas) | **2 moderadas** |

São majors, e por isso foram verificados: 89 testes passando, `tsc -b`
limpo, build limpo. São ferramental — não vão para o navegador de
ninguém.

As 2 moderadas que sobram são do `react-router-dom` (open redirect com
contrabarra em `<Link>`/`useNavigate`). Essa é dependência de
**produção** e a correção exige `react-router-dom@7`, um major
user-facing: vai em PR próprio, não junto de uma correção de segurança
de banco. Atenuante que já existia: `lib/after-login.ts` trata o
caminho de redirect como entrada hostil e barra `//evil` e `/\evil`, com
teste — e é o único lugar do app que tira caminho da URL.

## O que mudou

### Banco (`20261104140000_auditoria_seguranca.sql`)

- **`profiles` por coluna.** O grant era de tabela inteira. Agora o
  cliente escreve só aparência e nome de exibição; `email`, `username`,
  `role` e `id` saem da escrita, e `email` e `role` saem também da
  **leitura** — `select email, full_name, role from profiles` entregava
  a base de contatos com um "qual conta é admin" de brinde, que é o
  passo de reconhecimento do C1.
- **`promote_to_admin` resolve pela conta, não pelo perfil.** O alvo vem
  de `auth.users`, que o cliente não escreve, e mais de uma linha agora
  é erro. Quem quiser certeza usa `promote_to_admin_by_id(uuid)`. A
  recusa de um segundo admin (NQ022) foi mantida de propósito: trocar de
  administrador continua sendo ato deliberado, não efeito colateral de
  um e-mail digitado errado.
- **`expire_stale_queue_entries`** passa a medir **ausência de sinal**,
  não tempo de espera: só sai quem nunca foi chamado, não se mexeu desde
  que chegou (`first_joined_at`, não `joined_at`) e está numa quadra
  parada. E chama `call_next_team` no fim — era a única função que mexia
  em status de fila sem isso, e era o que deixava a quadra travada.
- **`EXECUTE` revogado de PUBLIC** nas 61, com
  `alter default privileges` para as próximas nascerem fechadas.
- **`anon` não leva nome completo.** `match_side_players` e
  `queue_entry_players` entregam, sem login, só `short_name` e
  `initials` — que é o que a placa da quadra mostraria e o que o tablet
  fala em voz alta. Com login, nada mudou.
- **`claim_notifications`** com `for update skip locked`: dois workers
  sobrepostos levam lotes diferentes em vez do mesmo.
- **`rotate_court_qr_secret`** incrementa a versão no banco, de forma
  atômica. Era read-modify-write, e invalidar QR já impresso não pode
  ter lost update.

### Borda HTTP

- **Allow-list de hosts de push** (`isPushEndpoint`), conferida no
  registro **e de novo antes de enviar** — é no envio que o JWT VAPID
  sai do projeto. Endpoint fora da lista é desativado em vez de ficar
  sendo tentado.
- **Roubo de canal de push:** tomar um endpoint de outra conta agora
  exige apresentar as chaves `p256dh`/`auth` do aparelho. A troca de
  conta no mesmo navegador continua funcionando, porque `subscribe()`
  com a mesma `applicationServerKey` devolve as mesmas chaves.
- **`admin-court-qr` no wrapper `serve()`** — fim do
  `Access-Control-Allow-Origin: *` numa rota que devolve assinatura HMAC
  de QR impresso.
- **CORS fail-closed:** sem `ALLOWED_ORIGINS` e fora do desenvolvimento
  local, nenhuma origem é liberada. A web quebra de forma visível, que é
  melhor que ficar aberta em silêncio.
- **`action` do `call-next` validado** contra a lista fechada: o default
  era `finish_match`, então um erro de digitação encerrava o turno em
  andamento e tirava gente da quadra.
- **`requireUuid`/`requireUuids`** em todos os ids de URL e corpo.
- **Mensagem crua do Postgres não sai mais** para erro sem tradução: ia
  com nome de tabela, de coluna e de constraint. Os SQLSTATEs
  NQ021–NQ026, NQ036 e NQ037 ganharam tradução (NQ023 virou 403, não
  400).
- **Worker de push:** as cinco escritas de desfecho passam a checar
  erro, os tickets da Expo são conferidos em quantidade antes de casar
  por índice (casar errado desativava o token de **outro** usuário), e
  um lote que falha no meio devolve os tickets dos que já saíram, em vez
  de o retry reenviar o que já foi entregue.
- **`service_role` trocado pela chave anônima** em `queue-status` e no
  GET do `match`, que são leituras públicas.

### Frontend e configuração

- **jsQR por import dinâmico:** chunk de entrada de 80,25 kB → **32,40
  kB** gzipado. Ele só roda no fallback de Safari/Firefox, e ia para o
  chunk que todo mundo baixa.
- **Sem sourcemap em produção:** os `.map` publicavam o TypeScript
  original inteiro, comentários e tudo.
- **`VITE_PLAY_STORE_URL` no `define`:** estava no `.env.example`, era
  lida e consumida, mas nunca chegava ao bundle — `playStoreUrl()`
  devolvia `null` sempre.
- **HSTS e Permissions-Policy** no `vercel.json` (câmera e localização
  liberadas só para a própria origem).

### Governança

- **`LICENSE`** explícito (proprietário). A ausência significava o
  mesmo, mas em silêncio. Abrir o projeto é decisão de produto: trocar
  este arquivo e o campo `license`.
- **`.github/dependabot.yml`** para npm e github-actions, agrupado
  (ferramental junto e rápido; o que o usuário baixa em PR próprio).
  É a causa-raiz do A6: nada vigiava.
- **`SECURITY.md`** com canal privado e o que conta como falha.
- **`permissions: contents: read`** no workflow, e um job
  **`npm audit --audit-level=high`** que falha em alta ou crítica.

## Testes novos

`tests/local/90_privilegios_test.sql` testa **privilégio, não
comportamento** — e existe porque os outros arquivos rodam como
superusuário e por isso nenhum deles jamais enxergaria um grant errado.
Foi assim que as 61 funções ficaram abertas sem ninguém notar.

Ele cobre: nenhuma função executável por PUBLIC; toda RPC que o app
chama continua chamável por quem o app é (lista extraída do código); as
colunas de `profiles` que o cliente pode e não pode ler e escrever; a
escalação do C1 pelos dois lados; e o `anon` não levando nome completo.

`tests/local/80_rotacao_test.sql` ganhou os três casos do A2: quem
esperou 4 h numa fila **viva** não é expulso, a vaga esquecida em quadra
**parada** sai, e expirar o grupo chamado passa a vez em vez de travar a
quadra.

## O que ficou de fora, e por quê

| Item | Por quê |
|---|---|
| `react-router-dom@7` | major de produção; PR próprio. O atenuante está acima |
| Pinar as 4 actions por SHA | não consigo buscar os SHAs reais deste ambiente, e **inventar SHA quebra a CI**. Fica para quem tiver rede: `gh api repos/actions/checkout/commits/v4 --jq .sha` |
| Rate limiting nas 12 funções | é desenho novo, não ajuste. Merece PR com teste de carga. **Subiu de prioridade na Sprint 8** — ver a nota abaixo |
| `useAsyncData`, `Sheet` com focus trap, quebrar `Court.tsx` | refatoração de frontend, nenhuma com furo de segurança. Valem muito, e valem PR próprio |
| Policies explícitas nas 5 tabelas deny-all | hoje seguras por ausência de grant; o risco é um grant futuro. Vale `force row level security`, junto do próximo trabalho de RLS |
| Retenção de `host_invites`, `pilot_events`, `queue_pin_attempts`, `host_sessions` | crescimento, não segurança |
| Fonte única do mapa de erros NQ* | o mapa está em três lugares; gerar do SQL é um gerador novo |
| `architecture.md`, `database.md`, `api.md` em drift | pararam na Sprint 4/5 e as Sprints 6 e 7 entraram depois. Atualizar é trabalho de documentação, não de correção |
| Contraste do `--ocre` (WCAG AA) | achado real (3,67:1); mexer na paleta é decisão de design |

---

## Nota da Sprint 8: a fila sem conta mudou o peso do rate limiting

Esta auditoria foi feita quando toda escrita na fila exigia conta. Desde
o [totem](sprint8.md) não exige mais: entrar na fila é digitar nome e
sobrenome, no aparelho da quadra ou pelo QR impresso nela.

O que **não** mudou: cada escrita continua exigindo um segredo — token
do aparelho, scan token de uso único com localização conferida, ou o
party token do navegador de quem entrou. E as funções internas seguem
fechadas para `anon` e `authenticated`, com o teste 90 cobrando isso
função por função, nominalmente.

O que mudou é o **custo de um abuso**:

- a superfície chamável sem conta passou de 2 RPCs de leitura para 10;
- `user_id` deixou de existir no caminho do jogador, então a janela
  deslizante que a correção pendente desenharia **não pode ser por
  usuário**. Tem de ser por token de aparelho, por scan token e por IP;
- um scan token é de uso único, mas nada impede um script de pedir
  vários em sequência da mesma coordenada — o freio hoje é só a
  distância conferida.

Nenhum desses é furo novo de autorização: ninguém escreve sem segredo. É
disponibilidade — encher a fila de uma quadra. Com o piloto numa quadra
só, o risco é baixo e visível (o admin remove da fila pelo painel). Com
várias quadras abertas ao público, **rate limiting deixa de ser higiene
e passa a ser requisito**, e o desenho dele mudou de chave.
