# App web — build e deploy na Vercel

O app web vive em [`web/`](../web): Vite + React + TypeScript, falando
com o Supabase por `supabase-js`. É uma SPA estática — não há servidor
próprio, porque não existe segredo a guardar: a chave `anon` é pública
por definição e tudo que ela alcança é limitado pelo RLS.

## Por que o deploy dava 404

A Vercel publicava a raiz do repositório, que tinha só o backend
(migrations, Edge Functions, docs). Sem `index.html` e sem build, não
havia página para servir. O [`vercel.json`](../vercel.json) na raiz
resolve isso apontando o build para `web/`.

## Variáveis de ambiente (Vercel › Settings › Environment Variables)

| Variável | Valor | Obrigatória |
|---|---|---|
| `VITE_SUPABASE_URL` (ou `SUPABASE_URL`) | `https://<project-ref>.supabase.co` | sim |
| `VITE_SUPABASE_ANON_KEY` (ou `SUPABASE_ANON_KEY`) | a chave **anon public** | sim |
| `VITE_VAPID_PUBLIC_KEY` (ou `VAPID_PUBLIC_KEY`) | chave pública do Web Push | não |
| `VITE_MAP_TILE_URL` (ou `MAP_TILE_URL`) | azulejos do mapa do cadastro, no formato `.../{z}/{x}/{y}.png` | não |
| `VITE_MAP_TILE_ATTRIBUTION` (ou `MAP_TILE_ATTRIBUTION`) | crédito exibido no canto do mapa | não |

Sem as duas do mapa o cadastro usa o OpenStreetMap, que não pede
chave — não há nada a configurar para o mapa funcionar. Elas existem
para quem quiser trocar por imagem de satélite (ajuda a achar a quadra
dentro do parque); nesse caso a atribuição do provedor é exigência de
licença, não enfeite.

O Vite só entrega ao navegador o que começa com `VITE_`. Como na Vercel
elas acabaram nomeadas sem o prefixo, o
[`web/vite.config.ts`](../web/vite.config.ts) injeta uma a uma
explicitamente aceitando os dois nomes — é uma lista fechada, e não um
prefixo genérico, justamente para que uma eventual
`SUPABASE_SERVICE_ROLE_KEY` no projeto jamais entre no bundle.

Sem as duas primeiras o app abre numa tela explicando o que falta, em
vez de uma página branca: o `main.tsx` confere a configuração **antes**
de carregar qualquer coisa que toque o Supabase, e um handler global de
erro pinta uma mensagem legível se algo quebrar depois disso.

> **Nunca** coloque a `service_role` aqui. Ela ignora o RLS e qualquer
> pessoa consegue lê-la no bundle que o navegador baixa.

Mudou variável? A Vercel só aplica no **próximo build** — é preciso um
Redeploy, não só salvar.

## Serviços de terceiros que a tela de cadastro usa

Duas coisas no cadastro de quadras saem do app para fora do Supabase.
Estão aqui porque ninguém deveria descobrir isso lendo o código.

| Serviço | Quando | O que sai daqui |
|---|---|---|
| Azulejos do mapa (`VITE_MAP_TILE_URL`, padrão OpenStreetMap) | sempre que o mapa do cadastro abre | as coordenadas da área visível, como em qualquer mapa |
| Nominatim (`nominatim.openstreetmap.org`) | **só** quando o administrador aperta "Buscar endereço" | o texto digitado no campo de endereço |

A busca nunca dispara enquanto se digita — é um clique, uma consulta.
Isso é exigência da política de uso do Nominatim (no máximo uma por
segundo) e também mantém o que sai daqui previsível. Nenhum dos dois
recebe dado de jogador: a tela é de administração.

Quem não quiser depender deles: `VITE_MAP_TILE_URL` aponta para outro
provedor, e o cadastro funciona inteiro sem a busca — "Estou na
quadra" usa o GPS do aparelho e "Digitar as coordenadas" não consulta
nada.

> **A atribuição é interpretada como HTML.** O Leaflet escreve
> `VITE_MAP_TILE_ATTRIBUTION` com `innerHTML`, porque os provedores
> publicam o crédito como um link pronto. Só quem controla o build
> define essa variável, mas trate-a como código: nada de colar ali
> texto vindo de terceiros sem ler.

## Cabeçalhos de segurança

O `vercel.json` manda uma `Content-Security-Policy` junto de toda
resposta. O que ela decide, em uma linha cada:

- `script-src 'self'` — só o bundle do próprio deploy executa. É o que
  fecha a porta do XSS, e é o motivo de o app não ter script inline.
- `style-src 'self' 'unsafe-inline' …googleapis` — o app todo é estilo
  inline (atributo `style`), e as fontes da marca vêm do Google Fonts.
- `img-src 'self' data: blob: https:` — azulejos de mapa e fotos de
  quadra vêm de fora, e o provedor de azulejos é configurável; o que
  esta linha garante é que imagem nenhuma vire script.
- `connect-src` — Supabase (REST, auth, realtime, storage) e o
  Nominatim. **Trocar o provedor de azulejos por um que faça chamadas
  (e não só sirva imagens) exige acrescentar o domínio aqui.**
- `frame-ancestors 'none'` — ninguém embute o app num iframe.

Verificado contra o bundle de produção em Chromium: a tela de
administração abre, o mapa monta e os azulejos carregam, sem nenhuma
violação no console. Vale testar assim de novo a cada mudança — CSP
errada não derruba o build, derrube a tela do usuário.

## Do lado do Supabase

Três coisas precisam apontar para o domínio da Vercel:

```bash
# 1. CORS das Edge Functions
supabase secrets set ALLOWED_ORIGINS="https://<seu-dominio>.vercel.app"

# 2. Base dos QR Codes impressos
supabase secrets set APP_BASE_URL="https://<seu-dominio>.vercel.app"
```

**3. Redirect de login** — Dashboard › Authentication › URL
Configuration. **Este é o passo que mais dá problema**, porque o
Supabase nasce com `http://localhost:3000` no Site URL.

- **Site URL**: `https://<seu-dominio>.vercel.app`
- **Redirect URLs**, uma por linha:

  ```
  https://<seu-dominio>.vercel.app/**
  http://localhost:5173/**
  ```

Como o link de confirmação de e-mail usa o Site URL: o app passa o
endereço de volta em `emailRedirectTo`, mas o Supabase só obedece se
esse endereço casar com alguma das Redirect URLs. Quando não casa, ele
**ignora em silêncio e cai no Site URL**. É exatamente por isso que o
e-mail de confirmação chega apontando para
`localhost:3000/?code=...` e o navegador mostra "não foi possível
conectar ao servidor": o cadastro foi confirmado no servidor, só a
volta é que foi para o endereço errado.

Depois de corrigir, peça um e-mail novo — o link antigo continua
apontando para o endereço velho.

> O app aguenta o código chegar em **qualquer rota** (`/`, `/entrar`,
> `/auth/callback`): o `detectSessionInUrl` do supabase-js troca o
> código pela sessão onde quer que ele caia. O que ele não consegue
> adivinhar é um domínio que não existe.

Se o domínio mudar (ou sair do `*.vercel.app` para um domínio próprio),
os três precisam ser atualizados — e os QR Codes já impressos param de
abrir o app, porque a URL assinada aponta para o domínio antigo. O
`scan-court` continua aceitando qualquer host (o que autentica é a
assinatura), mas a câmera do celular vai abrir o endereço velho.

## Login com Google, e-mails e administração

Cada um desses tem um passo no painel do Supabase, reunidos em
[`docs/auth.md`](auth.md): o cliente OAuth do Google, os templates de
e-mail da marca (em [`supabase/templates/`](../supabase/templates/)) e
como criar o administrador único.

## Rodando local

```bash
cd web
cp .env.example .env     # preencha a anon key
npm install
npm run dev              # http://localhost:5173
```

## Rotas

| Rota | Tela |
|---|---|
| `/entrar` | Login (e-mail/senha, Google, recuperar senha) |
| `/` | Lista de parques |
| `/parque/:parkId` | Home do parque |
| `/quadra/:courtId` | Quadra: placar, fila e ações |
| `/perfil` | Perfil, raquete e notificações |
| `/q/:courtId` | **Onde o QR Code impresso cai** |
| `/auth/callback` | Volta do OAuth e dos links de e-mail |

A rota `/q/:courtId` é o caminho principal de entrada: a pessoa aponta a
câmera do celular para o QR da quadra e cai direto ali. Não há scanner
nessa tela — a URL inteira já é o payload assinado; o app só pede a
localização e valida. Quem não está logado é mandado para `/entrar` e
volta para o QR depois do login.

Dentro de um parque (`/parque/:parkId`, `/quadra/:courtId`, `/perfil`)
a barra inferior do protótipo fica visível: Quadras · Placar · QR/NFC ·
Perfil. O botão central abre a leitura; o "Placar" aponta para a última
quadra aberta, lembrada na sessão.

## O que o app faz com o backend

```
/q/:courtId  ──▶ scan-court (valida assinatura + distância)
                     │
                     ▼
tela da quadra ──▶ court_screen (placar + fila + meu estado)
                     │  Realtime em matches, queue_entries e courts
                     ▼
"Entrar na fila" ─▶ scan-court ─▶ join-queue
"É a sua vez!"  ─▶ scan-court ─▶ check-in   (libera o placar)
fim da partida  ─▶ match (quem ganhou)
```

Quem recalcula posição, tempo estimado e pilha de raquetes é o backend:
o Realtime só avisa que mudou algo, e a tela refaz `court_screen`. Assim
ela nunca monta a fila a partir de um evento parcial, e reconectar é só
um refetch.

## PWA e notificações

`manifest.webmanifest` + `sw.js` tornam o app instalável e habilitam o
Web Push. O service worker:

- cacheia só o shell e os assets com hash — **nunca** a fila, porque
  posição velha é pior que erro;
- mostra a notificação com `tag` por time, então um "Prepare-se!" novo
  substitui o anterior em vez de empilhar;
- abre a tela da quadra no clique.

No iPhone o push só funciona com o site **instalado na tela de início**
(iOS 16.4+). O app detecta e avisa em vez de prometer o que não vai
acontecer.

## Android, depois

Quando a licença da Play Store sair, o mesmo QR Code já serve: ele é um
App Link `https://<dominio>/q/<courtId>`. Basta publicar
`/.well-known/assetlinks.json` (modelo em
[`docs/app-links/`](app-links/README.md)) **antes** do build da loja, e
o Android passa a abrir o app em vez do site. Nada muda no backend.

## A tipografia da marca

O protótipo escreve "Neqst" na **Chancery Cursive - DGL**, que é
`© 1998 Digital Graphic Labs, All Rights Reserved` — sem licença de
redistribuição, ela não pode ser publicada junto com o site. No lugar
dela usamos a **Italianno** (Google Fonts, licença aberta), que foi
escolhida comparando as duas lado a lado: é a parente livre que acerta
o traço do N e o rabo do q.

Se o cliente tiver a licença, é um arquivo: coloque o TTF em
`web/public/fonts/chancery-cursive.ttf`. O `@font-face` em
`src/index.css` já aponta para lá, e a assinatura fica idêntica à do
protótipo sem mexer em código.

## Limitações conhecidas

- **GPS no desktop** vem do IP e erra quilômetros, então `scan-court`
  responde "longe demais". Está correto: entrar na fila exige estar na
  quadra. Para testar no computador, aumente `gps_tolerance_meters` da
  quadra de teste.
- **Câmera** precisa de HTTPS (a Vercel já serve assim) e de permissão.
  No Safari/Firefox usamos `jsQR`; no Chrome, o `BarcodeDetector` nativo.
- **Web NFC** só existe no Chrome Android. Em outros navegadores a aba
  NFC aparece desabilitada com a explicação.
- **Bundle de ~175 KB gzip**, quase todo `supabase-js`. Cabe no 3G, mas
  se virar problema dá para code-split por rota.
