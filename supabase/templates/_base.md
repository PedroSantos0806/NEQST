# Templates de e-mail do NEQST

Os arquivos ao lado são colados em **Supabase Dashboard → Authentication →
Emails → Templates**, um por aba. Cada um tem o seu assunto sugerido no
comentário da primeira linha.

As variáveis entre `{{ }}` são do Supabase e precisam ficar como estão:

| Variável | O que vira |
|---|---|
| `{{ .ConfirmationURL }}` | o link que confirma a ação |
| `{{ .Email }}` | o e-mail do destinatário |
| `{{ .Token }}` | o código de 6 dígitos (alternativa ao link) |
| `{{ .Data.full_name }}` | o nome digitado no cadastro |

**Antes de testar**: o link só volta para o app se o Site URL e as
Redirect URLs estiverem certos (ver `docs/web.md`). Com o Site URL
padrão, todo link aponta para `localhost:3000`.

O e-mail é renderizado por clientes antigos (Outlook, Gmail nativo),
então aqui vale HTML de 2005: tabelas, estilo inline, nada de flexbox e
nada de fonte da web — a assinatura usa Georgia itálico, que existe em
todo lugar.
