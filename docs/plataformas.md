# Web e Play Store — o que muda no backend

O NEQST roda em dois lugares: um app publicado na Play Store (e,
opcionalmente, na App Store) e um site/PWA. O backend é o mesmo, mas
quatro coisas não são iguais nos dois mundos. Esta página é o resumo
delas.

| Assunto | App (Play Store) | Web (navegador) |
|---|---|---|
| Push | Expo Push API → FCM/APNs | Web Push (VAPID), RFC 8291 |
| QR Code | scanner dentro do app | câmera do sistema abre o App Link |
| CORS | não se aplica (sem `Origin`) | allow-list em `ALLOWED_ORIGINS` |
| Login | redirect `neqst://auth-callback` | redirect `https://.../auth/callback` |

---

## 1. Push notifications

A Expo Push API **não entrega em navegador**. Se a versão web dependesse
só dela, o "Prepare-se!" nunca chegaria para quem usa o site — que é
justamente quem está com o celular na mão, de pé ao lado da quadra.

Por isso o backend tem dois canais, e `dispatch-notifications` entrega
nos dois:

```
notification_outbox
   ├── push_tokens            -> Expo Push API  (ExponentPushToken[...])
   └── web_push_subscriptions -> Web Push/VAPID (endpoint + p256dh + auth)
```

Uma notificação conta como entregue se **qualquer** canal aceitou. Quem
usa o app no celular e o site no notebook não gera reenvio.

### No front web

```js
// 1. Service worker (precisa existir para receber push)
const registration = await navigator.serviceWorker.register("/sw.js");

// 2. Chave pública VAPID — o backend serve
const { publicKey } = await fetch(`${FUNCTIONS_URL}/register-web-push`).then((r) => r.json());

// 3. Permissão + subscription
const subscription = await registration.pushManager.subscribe({
  userVisibleOnly: true,
  applicationServerKey: publicKey,
});

// 4. Registra no backend (toJSON já devolve endpoint + keys)
await fetch(`${FUNCTIONS_URL}/register-web-push`, {
  method: "POST",
  headers: { Authorization: `Bearer ${session.access_token}`, "Content-Type": "application/json" },
  body: JSON.stringify(subscription.toJSON()),
});
```

No `sw.js`, o payload chega como JSON `{ title, body, data }`:

```js
self.addEventListener("push", (event) => {
  const { title, body, data } = event.data.json();
  event.waitUntil(self.registration.showNotification(title, {
    body,
    data,
    icon: "/icons/icon-192.png",
    tag: data.entryId,          // substitui o aviso anterior do mesmo time
  }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(clients.openWindow(`/quadra/${event.notification.data.courtId}`));
});
```

**Limitações do Web Push que valem avisar ao usuário:** no iOS só
funciona se o site estiver instalado na tela de início (PWA), a partir do
iOS 16.4. No Android/Chrome funciona direto. Em qualquer plataforma, o
usuário precisa conceder permissão — e se recusar, não há como reverter
pelo app.

### No app Expo

Igual à Sprint 1: `register-push-token` com o `ExponentPushToken`.

---

## 2. QR Code

Um QR com o esquema `neqst:...` **não abre nada** quando lido pela câmera
nativa do Android ou do iOS — só pelo scanner de dentro do app. Como o
QR fica impresso na quadra e qualquer pessoa pode apontar a câmera do
sistema para ele, o que vai no papel é um **App Link https**:

```
https://app.neqst.com.br/q/<courtId>?v=1&s=<assinatura>
```

Com `assetlinks.json` publicado, o Android abre o app instalado; sem app,
abre o site, que faz o mesmo fluxo. Os dois formatos continuam aceitos
pelo `scan-court` — códigos impressos na Sprint 1 seguem válidos.

Configuração dos arquivos `.well-known`:
[`docs/app-links/README.md`](app-links/README.md).

### Câmera na web

A web não tem `expo-camera`. Duas opções:

```js
// Chrome/Android: nativo e rápido
if ("BarcodeDetector" in window) {
  const detector = new BarcodeDetector({ formats: ["qr_code"] });
  const [code] = await detector.detect(videoElement);
  if (code) handlePayload(code.rawValue);
}
// Safari/Firefox: fallback com jsQR sobre um <canvas>
```

Na prática, a maioria dos acessos web vem de quem **já escaneou** com a
câmera do sistema e caiu na rota `/q/:courtId` — nesse caso não há
scanner nenhum, só a URL. Trate esse caminho como o principal.

### Precisão do GPS no navegador

`navigator.geolocation` costuma ser bem menos preciso que o GPS do app,
especialmente em desktop (onde vem de IP e erra quilômetros). O backend
já lida com isso: mande `accuracy` no `scan-court` e a tolerância da
quadra (`gps_tolerance_meters`, padrão +200 m) é aplicada. Em desktop,
espere `TOO_FAR_FROM_COURT` com frequência — e isso está correto: entrar
na fila exige estar na quadra.

---

## 3. CORS

Configure `ALLOWED_ORIGINS` com as origens da web (vírgula separando).
Sem isso, as funções respondem `Access-Control-Allow-Origin: *`, o que
serve para desenvolvimento mas deixa qualquer site chamar a API a partir
do navegador de quem está logado.

```bash
supabase secrets set ALLOWED_ORIGINS="https://app.neqst.com.br,https://staging.neqst.com.br"
```

O app nativo não manda `Origin` e não é afetado pela allow-list.

---

## 4. Autenticação

| | App | Web |
|---|---|---|
| Redirect | `neqst://auth-callback` | `https://app.neqst.com.br/auth/callback` |
| Armazenamento | `expo-secure-store` (Keychain/Keystore) | cookie/localStorage do `supabase-js` |
| Fluxo OAuth | PKCE (`WebBrowser.openAuthSessionAsync`) | PKCE (`signInWithOAuth`) |

Cadastre **os dois** redirects em Authentication → URL Configuration.

No Google Cloud Console, crie credenciais OAuth separadas:

- **Web application** → usada pelo site e pelo próprio Supabase Auth
- **Android** → com o package name e o fingerprint SHA-1 da chave de
  assinatura (o mesmo cuidado do `assetlinks.json`: com Play App Signing,
  use o fingerprint do Play Console)

O Apple SSO só é exigido pela App Store. Se a primeira entrega é só
Play Store + web, ele pode esperar — mas deixe o provider configurado,
porque a Apple reprova app com login social que não ofereça o dela.

---

## PWA

Para o site virar instalável (e, no iOS, poder receber push):

```json
{
  "name": "NEQST — Fila de Quadras",
  "short_name": "NEQST",
  "start_url": "/",
  "display": "standalone",
  "background_color": "#ffffff",
  "theme_color": "#111111",
  "icons": [
    { "src": "/icons/icon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "/icons/icon-512.png", "sizes": "512x512", "type": "image/png" }
  ]
}
```

O service worker precisa existir de qualquer forma para o push. Cachear a
tela da quadra por 60s (como a US-04 pede) cabe bem nele; a fila, não —
ela precisa de conexão, e o estado de erro tem que ser explícito.
