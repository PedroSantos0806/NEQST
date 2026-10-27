# Login, e-mails e administração

Três coisas que vivem no painel do Supabase, não no código — e o que o
app espera encontrar de cada uma.

---

## 1. Login com Google

São dois lados: um cliente OAuth no Google e a chave dele no Supabase.
O código do app já está pronto (`signInWithOAuth`), não há nada a mudar
ali.

### a) No Supabase, pegue o endereço de retorno

**Authentication › Sign In / Providers › Google.** Copie o
**Callback URL (for OAuth)** que aparece ali. Ele tem esta cara:

```
https://iqspcnjjmkzkhulrefpa.supabase.co/auth/v1/callback
```

Deixe a aba aberta — você volta nela no passo (c).

### b) No Google Cloud, crie o cliente OAuth

Em <https://console.cloud.google.com>:

1. **Crie (ou escolha) um projeto** no seletor do topo.
2. **APIs & Services › OAuth consent screen**
   - User type: **External**, depois *Create*.
   - App name: `NEQST`. E-mail de suporte e e-mail do desenvolvedor: o seu.
   - *Save and continue* até o fim. Em **Scopes** não precisa adicionar
     nada: `email`, `profile` e `openid` já vêm por padrão.
   - Enquanto o app estiver em **Testing**, só os e-mails listados em
     *Test users* conseguem entrar. Para liberar para qualquer pessoa,
     use **Publish app** — sem escopos sensíveis, não há verificação.
3. **APIs & Services › Credentials › Create credentials › OAuth client ID**
   - Application type: **Web application**
   - Name: `NEQST Web`
   - **Authorized JavaScript origins**:
     ```
     https://<seu-dominio>.vercel.app
     http://localhost:5173
     ```
   - **Authorized redirect URIs** — cole aqui o endereço do passo (a):
     ```
     https://<project-ref>.supabase.co/auth/v1/callback
     ```
     Só este. O endereço do app **não** entra aqui: quem recebe o Google
     é o Supabase, que depois devolve para o app.
4. Copie o **Client ID** e o **Client secret**.

### c) De volta ao Supabase

Em **Authentication › Sign In / Providers › Google**: ligue o provedor,
cole Client ID e Client Secret, e salve.

### d) Confira as Redirect URLs

**Authentication › URL Configuration** precisa ter o domínio do app na
lista, senão o Google devolve a pessoa para o lugar errado:

```
https://<seu-dominio>.vercel.app/**
http://localhost:5173/**
```

### Quando der errado

| Erro | O que é |
|---|---|
| `redirect_uri_mismatch` | o Authorized redirect URI do Google não é exatamente o Callback URL do Supabase (confira `https`, barra no fim, project-ref) |
| `Access blocked: app not verified` | o consent screen está em Testing e o e-mail não está nos Test users |
| Entra e volta para `localhost:3000` | falta o domínio nas Redirect URLs do Supabase |
| `Unsupported provider` | o provedor não foi salvo como habilitado |

> Quem entra pelo Google não passa por confirmação de e-mail — o Google
> já garantiu o endereço. O perfil é criado pelo mesmo gatilho do
> cadastro por senha, aproveitando nome e foto da conta Google.

---

## 2. Personalizar os e-mails

Os templates prontos estão em
[`supabase/templates/`](../supabase/templates/), na identidade visual do
app. Para usar:

**Authentication › Emails › Templates**, uma aba por tipo. Cole o
conteúdo do arquivo no campo *Message body* e ajuste o *Subject* com o
assunto sugerido no comentário da primeira linha de cada arquivo.

| Aba no painel | Arquivo |
|---|---|
| Confirm signup | `confirm-signup.html` |
| Reset password | `reset-password.html` |
| Magic Link | `magic-link.html` |
| Change Email Address | `change-email.html` |
| Invite user | `invite.html` |

As variáveis `{{ .ConfirmationURL }}`, `{{ .Email }}` e
`{{ .Data.full_name }}` precisam ficar como estão — é o Supabase que as
preenche no envio.

> **O e-mail nativo do Supabase é só para desenvolvimento**: são poucos
> envios por hora, e nada garante a entrega. Antes de abrir para o
> público, configure um SMTP próprio em **Project Settings › Auth ›
> SMTP Settings** (Resend, Brevo, Amazon SES, Postmark — todos têm plano
> grátis suficiente para começar). Sem isso, numa manhã movimentada os
> cadastros simplesmente param de receber o e-mail.

---

## 3. O administrador

O NEQST tem **um único administrador**, garantido por um índice no
banco: a segunda tentativa de criar outro falha. Ele é quem cadastra
parques e quadras, gera os QR Codes para imprimir e promove moderadores.

### Criar a conta

**Authentication › Users › Add user › Create new user**:

- E-mail: o que for usar para administrar
- Senha: defina uma forte
- **Marque `Auto Confirm User`** — assim a conta já nasce confirmada e
  não depende do e-mail chegar

> Use um endereço que você realmente receba. Se um dia precisar
> recuperar a senha, o link vai para ele — e um domínio que não existe
> deixa a conta sem volta.

### Promover

> **Antes**: `promote_to_admin` vem da migration `20261010120000_admin.sql`.
> Se o schema do projeto ainda não foi atualizado, o SQL Editor responde
> `function public.promote_to_admin(unknown) does not exist` — o merge do
> PR publica o app, não o banco. Aplique o schema primeiro (ver
> [`docs/deploy.md`](deploy.md#1-schema)): o caminho mais curto é colar
> `db/full_setup.sql` inteiro, que é idempotente.

**SQL Editor › New query**, trocando o e-mail pelo que você usou:

```sql
select public.promote_to_admin('admin@seu-dominio.com');
```

A função devolve o `user_id` e o papel. Ela existe de propósito só no
SQL Editor: não é exposta ao app, então ninguém se promove de dentro do
site.

### Usar

Entre no app com essa conta e vá em **Perfil › Administração**, ou
direto em `/admin`. De lá dá para:

- criar e editar parques — endereço escrito e posição marcada no mapa
  (ver [Endereço e alfinete](#endereço-e-alfinete));
- criar e editar quadras — número e nome saem automáticos, e o piso, o
  slot de jogo, o endereço de referência, o alfinete no mapa e a tag
  NFC são por quadra;
- **gerar o QR Code de cada quadra**, já assinado e pronto para
  imprimir (e o conteúdo para gravar numa tag NFC, quando o parque
  topar instalar uma);
- promover alguém a **moderador** (encerra partida travada, chama o
  próximo, aprova fotos) ou rebaixar de volta a jogador.

> Se o botão "QR para imprimir" responder que a função não está
> publicada, é porque as Edge Functions ainda não foram para o
> Supabase — ver [`docs/deploy.md`](deploy.md#4-deploy-das-funções).
> O mesmo vale para ler o QR e entrar na fila.

### Endereço e alfinete

O cadastro não pede mais latitude e longitude cruas. São duas coisas
separadas, e elas servem a públicos diferentes:

- **Endereço** — é referência de quem vai chegar de carro. Texto
  livre: rua, número, bairro, "Portaria 2".
- **Posição no mapa** — o alfinete. É o que o check-in compara com a
  localização do jogador.

Em parque grande as duas não coincidem: a quadra fica no meio do
parque e o endereço é o do portão. Por isso **cada quadra tem o seu
próprio alfinete**. Ao criar uma quadra ele nasce na posição do parque
(era o que o banco fazia calado); arrastar o mapa é o que o põe em
cima da quadra de verdade.

No mapa:

- o alfinete fica **parado no centro** e quem se move é o mapa, como
  no aplicativo de corrida;
- **Estou na quadra** usa o GPS do aparelho — é o caminho mais curto
  quando se está no local;
- **Buscar endereço** procura o que foi digitado no campo acima e leva
  o mapa para perto. O texto do campo é enviado ao Nominatim do
  OpenStreetMap — só nesse clique, nunca enquanto se digita (ver
  [serviços de terceiros](web.md#serviços-de-terceiros-que-a-tela-de-cadastro-usa));
- o **círculo verde** é o raio do check-in e o **ponto vermelho** é o
  parque; **Ver o raio inteiro** afasta a câmera até o círculo caber,
  para conferir se a área cobre a quadra sem pegar a rua;
- **Digitar as coordenadas** continua ali para quem já tem o par na
  mão — e é a saída quando o mapa não carrega.

Marcou errado? Reabra **Editar quadra**, arraste e salve: o alfinete
velho é substituído.

### Testar sem estar na quadra

A verificação de distância é o que impede alguém de entrar na fila de
casa — e é também o que trava o time de testes. Em vez de aumentar o
raio (o que faria a quadra vizinha também aceitar), cada quadra tem um
interruptor: **Editar quadra › Exigir estar perto da quadra**.

Desligado, a leitura é aceita de qualquer lugar e a quadra passa a
exibir um aviso em vermelho na tela de administração. A distância
continua sendo medida e gravada — só não barra.

> Ligue de volta antes de abrir a quadra ao público. Com ele desligado,
> qualquer pessoa entra na fila sem sair de casa.

### Trocar de administrador

Como só pode haver um, rebaixe o atual antes:

```sql
update public.profiles set role = 'player' where role = 'admin';
select public.promote_to_admin('novo-admin@seu-dominio.com');
```

### O que impede uma escalada de privilégio

- A política `profiles: dono atualiza` exige que o papel continue o
  mesmo, então ninguém se promove editando o próprio perfil.
- `promote_to_admin` não é concedida a `authenticated` — só roda com a
  chave de serviço, isto é, no SQL Editor.
- `admin_set_role` aceita apenas `player` e `staff`, e recusa mexer no
  próprio papel.
- O índice `profiles_single_admin_idx` é a última linha: nem um `UPDATE`
  direto cria o segundo admin.

Tudo isso tem teste em `tests/local/50_admin_test.sql`.
