# QR Codes das quadras (US-02)

> **Desde a [Sprint 10](sprint10.md) o QR impresso não é mais este.**
>
> O que vai no papel agora é o **link da fila daquela quadra**
> (`https://.../fila/<slug>`), e nada além disso: a câmera abre a mesma
> tela do aparelho da quadra, com o botão de entrar na fila, e a pessoa
> digita nome e sobrenome. Não há assinatura a conferir, não há scan
> token e não há GPS no caminho de entrada — o que autoriza entrar é
> saber o link, que está impresso numa placa pública. O preço dessa
> escolha está escrito na seção 3 da [Sprint 10](sprint10.md).
>
> Os QRs **já impressos continuam valendo**: `/q/<quadra>` redireciona
> para `/fila/<quadra>`.
>
> O que está descrito abaixo — o QR assinado, o scan token de 30
> segundos, a validação de distância — **continua existindo** e continua
> sendo o caminho do app com conta (modo anfitrião, "Entrando na
> quadra", check-in). Só deixou de ser o caminho de quem chega na quadra
> e quer entrar na fila.

## Como funciona (o QR assinado, do fluxo com conta)

O QR impresso é **estático e assinado**:

```
neqst:v1:7c9e6679-7425-40de-944b-e07fc1f90ae7:Yk3fQ2rLm8xHn4pT9vWb1cZd5eFg7hJk
└─┬──┘ └┬┘ └──────────────┬───────────────┘ └──────────────┬──────────────┘
 app  versão          id da quadra          HMAC-SHA256 truncado (32 chars)
```

A assinatura usa `QR_SIGNING_SECRET`, que só existe nas Edge Functions.
Sem ele não há como fabricar um QR válido para uma quadra.

## E o "timeout de 30s" do critério de aceite?

Um código impresso não pode expirar sozinho — ele fica colado na parede.
O timeout vive um passo adiante: `scan-court` valida assinatura **e**
distância e devolve um *scan token* de **uso único com 30 segundos de
validade**. Sem esse token, `join_queue` recusa a entrada.

O efeito prático é o desejado pelo critério: uma foto do QR Code tirada
em casa não coloca ninguém na fila, porque o token só é emitido para quem
está dentro do raio, e some 30 segundos depois.

## Gerar os códigos

Via script (imprime os payloads e, opcionalmente, uma folha HTML):

```bash
export SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... QR_SIGNING_SECRET=...
deno run --allow-env --allow-net --allow-write scripts/generate-qr.ts --html qrcodes.html
open qrcodes.html   # Ctrl+P para imprimir
```

Via API (admin logado):

```bash
curl "$SUPABASE_URL/functions/v1/admin-court-qr" \
  -H "Authorization: Bearer $ADMIN_JWT" -H "apikey: $SUPABASE_ANON_KEY"
```

## Impressão

- Mínimo **15 × 15 cm** para leitura confortável a ~1 m de distância.
- Plastifique ou use adesivo UV: quadra é sol e chuva.
- Inclua o nome da quadra e a instrução "Escaneie para entrar na fila" —
  o script de geração já faz isso na folha HTML.
- Fixe em altura de ~1,4 m, longe de reflexo direto.

## Rotacionar um QR comprometido

```bash
curl -X POST "$SUPABASE_URL/functions/v1/admin-court-qr" \
  -H "Authorization: Bearer $ADMIN_JWT" -H "apikey: $SUPABASE_ANON_KEY" \
  -H "Content-Type: application/json" \
  -d '{"courtId":"7c9e...","rotate":true}'
```

Incrementa `qr_secret_version` daquela quadra: os códigos antigos passam a
devolver `QR_REVOKED` e precisam ser reimpressos. As demais quadras não
são afetadas.

> Trocar o `QR_SIGNING_SECRET` global invalida **todos** os QR Codes de
> todas as quadras de uma vez. Faça isso apenas em caso de vazamento do
> segredo, e reimprima tudo antes de virar a chave.
