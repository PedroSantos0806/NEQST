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
| `VITE_SUPABASE_URL` | `https://<project-ref>.supabase.co` | sim |
| `VITE_SUPABASE_ANON_KEY` | a chave **anon public** | sim |
| `VITE_VAPID_PUBLIC_KEY` | chave pública do Web Push | não |

Sem as duas primeiras o app abre numa tela explicando o que falta, em
vez de uma página branca.

> **Nunca** coloque a `service_role` aqui. Ela ignora o RLS e qualquer
> pessoa consegue lê-la no bundle que o navegador baixa.

Mudou variável? A Vercel só aplica no **próximo build** — é preciso um
Redeploy, não só salvar.

## Do lado do Supabase

Três coisas precisam apontar para o domínio da Vercel:

```bash
# 1. CORS das Edge Functions
supabase secrets set ALLOWED_ORIGINS="https://<seu-dominio>.vercel.app"

# 2. Base dos QR Codes impressos
supabase secrets set APP_BASE_URL="https://<seu-dominio>.vercel.app"
```

**3. Redirect de login** — Dashboard › Authentication › URL
Configuration:

- Site URL: `https://<seu-dominio>.vercel.app`
- Redirect URLs: `https://<seu-dominio>.vercel.app/auth/callback`
  (e `http://localhost:5173/auth/callback` para o desenvolvimento)

Sem isso o login com Google volta para o lugar errado e a sessão se
perde.

Se o domínio mudar (ou sair do `*.vercel.app` para um domínio próprio),
os três precisam ser atualizados — e os QR Codes já impressos param de
abrir o app, porque a URL assinada aponta para o domínio antigo. O
`scan-court` continua aceitando qualquer host (o que autentica é a
assinatura), mas a câmera do celular vai abrir o endereço velho.

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
