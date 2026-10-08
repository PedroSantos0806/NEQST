# App Links e Universal Links

Modelos dos dois arquivos que o **app web** precisa servir para que o QR
Code impresso abra o aplicativo instalado em vez do navegador.

| Arquivo | Servir em | Plataforma |
|---|---|---|
| `assetlinks.json` | `https://<APP_BASE_URL>/.well-known/assetlinks.json` | Android (Play Store) |
| `apple-app-site-association` | `https://<APP_BASE_URL>/.well-known/apple-app-site-association` | iOS |

Requisitos dos dois: `Content-Type: application/json`, servidos por HTTPS
sem redirecionamento e sem autenticação.

## Como preencher

**Android** — o fingerprint é o da chave que realmente assina o APP na
loja. Com EAS Build, a chave é gerenciada pelo Expo:

```bash
eas credentials            # Android > Keystore > mostra o SHA-256
```

Se o app usa Play App Signing (o padrão), use o fingerprint que aparece
no **Play Console → Configuração → Integridade do app**, não o da chave
de upload. Errar esse ponto é a causa mais comum de App Link que não
abre: o link simplesmente cai no navegador, sem erro visível.

Dá para ter mais de um fingerprint na lista — útil para manter o build de
debug funcionando junto com o de produção.

**iOS** — `appID` é `<TeamID>.<bundleIdentifier>`. O Team ID está no
Apple Developer Portal (Membership).

## No app Expo

```json
{
  "expo": {
    "android": {
      "intentFilters": [
        {
          "action": "VIEW",
          "autoVerify": true,
          "data": [{ "scheme": "https", "host": "app.neqst.com.br", "pathPrefix": "/q" }],
          "category": ["BROWSABLE", "DEFAULT"]
        }
      ]
    },
    "ios": {
      "associatedDomains": ["applinks:app.neqst.com.br"]
    }
  }
}
```

`autoVerify: true` é o que faz o Android abrir o app direto, sem a
pergunta "abrir com". A verificação acontece na instalação e consulta o
`assetlinks.json` — então publique o arquivo **antes** de subir o build.

## Conferindo

```bash
# O arquivo está acessível e com o tipo certo?
curl -sI https://app.neqst.com.br/.well-known/assetlinks.json | head -3

# O Google valida a associação?
curl -s "https://digitalassetlinks.googleapis.com/v1/statements:list?source.web.site=https://app.neqst.com.br&relation=delegate_permission/common.handle_all_urls"

# No device, com o app instalado:
adb shell am start -a android.intent.action.VIEW \
  -d "https://app.neqst.com.br/q/<COURT_ID>?v=1&s=<ASSINATURA>"
```

## E na rota /q/:courtId do site

A página precisa funcionar nos dois mundos, porque quem não tem o app
instalado cai ali:

1. Lê `courtId`, `v` e `s` da URL.
2. Pede a localização (`navigator.geolocation.getCurrentPosition`).
3. Chama `POST /functions/v1/scan-court` com
   `payload` = a URL inteira, mais latitude, longitude e accuracy.
4. Com o `scanToken` em mãos, segue para a tela da fila.

O backend aceita a URL completa como `payload` — não é preciso
desmontá-la no front (ver `supabase/functions/_shared/qr.ts`).
