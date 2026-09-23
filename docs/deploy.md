# Deploy e ambientes

A Sprint 1 pede três ambientes separados (US-05). No Supabase, cada um é
um **projeto** próprio — bancos e chaves isolados:

| Ambiente | Projeto Supabase | Uso |
|---|---|---|
| `dev` | `neqst-dev` (ou `supabase start` local) | Desenvolvimento |
| `staging` | `neqst-staging` | TestFlight / Play Internal Track |
| `prod` | `neqst-prod` | Loja |

O projeto informado pelo time (`iqspcnjjmkzkhulrefpa`) é o ponto de
partida — trate-o como **staging** e crie um projeto separado antes do
lançamento em produção.

## 1. Schema

```bash
supabase link --project-ref <PROJECT_REF>
supabase db push          # aplica supabase/migrations/
```

Alternativa sem CLI: cole `db/full_setup.sql` no SQL Editor do Dashboard.

Verifique depois:

```sql
select tablename from pg_tables where schemaname = 'public' order by 1;
select proname   from pg_proc  where pronamespace = 'public'::regnamespace order by 1;
select tablename, rowsecurity from pg_tables where schemaname = 'public';  -- tudo true
```

## 2. Autenticação (US-01)

Dashboard → **Authentication → Providers**:

- **Email**: habilitado. Senha mínima de 8 caracteres.
- **Google**: Client ID e Secret do Google Cloud Console (OAuth 2.0).
- **Apple**: Services ID + chave `.p8` do Apple Developer.
  Obrigatório na App Store para qualquer app com login social.

**URL Configuration** → Redirect URLs:

```
neqst://auth-callback
exp://127.0.0.1:19000       (apenas dev)
```

O fluxo de "esqueci minha senha" é o
`supabase.auth.resetPasswordForEmail()` — configure o template em
**Authentication → Email Templates** apontando para `neqst://reset-password`.

## 3. Segredos das Edge Functions

```bash
supabase secrets set --env-file .env
supabase secrets list
```

Obrigatórios: `QR_SIGNING_SECRET`, `CRON_SECRET`.
`SUPABASE_URL`, `SUPABASE_ANON_KEY` e `SUPABASE_SERVICE_ROLE_KEY` são
injetados automaticamente pelo runtime.

> `QR_SIGNING_SECRET` precisa ser **diferente** por ambiente, e um QR de
> staging jamais deve funcionar em produção.

## 4. Deploy das funções

```bash
supabase functions deploy scan-court join-queue leave-queue queue-status \
                          call-next register-push-token admin-court-qr \
                          dispatch-notifications
```

`queue-status` e `dispatch-notifications` são declaradas com
`verify_jwt = false` em `supabase/config.toml`: a primeira é pública, a
segunda se autentica pelo header `x-cron-secret`.

## 5. Agendamentos

Dashboard → **Database → Extensions**: habilite `pg_cron` e `pg_net`.
Depois, no SQL Editor (trocando os placeholders):

```sql
select cron.schedule(
  'neqst-dispatch-notifications', '10 seconds',
  $$ select net.http_post(
       url     := 'https://<PROJECT_REF>.supabase.co/functions/v1/dispatch-notifications',
       headers := jsonb_build_object('Content-Type','application/json',
                                     'x-cron-secret','<CRON_SECRET>'),
       body    := '{}'::jsonb) $$);

select cron.schedule('neqst-maintenance', '*/15 * * * *',
                     $$ select public.run_maintenance(); $$);
```

Conferir: `select * from cron.job;` e `select * from cron.job_run_details order by start_time desc limit 20;`

## 6. Push notifications

O Expo cuida de FCM e APNs. No app:

```ts
const { data } = await Notifications.getExpoPushTokenAsync({ projectId });
await fetch(`${SUPABASE_URL}/functions/v1/register-push-token`, {
  method: "POST",
  headers: { Authorization: `Bearer ${session.access_token}`, "Content-Type": "application/json" },
  body: JSON.stringify({ token: data, platform: Platform.OS }),
});
```

No lado das lojas: credenciais APNs (`.p8`) no Expo e o `google-services.json`
do Firebase para Android — `eas credentials` cuida dos dois.

## 7. Quadras e QR Codes

```sql
insert into public.courts (slug, name, address, latitude, longitude)
values ('quadra-central', 'Quadra Central', 'Av. Paulista, 1000', -23.561414, -46.655881);

-- promova o primeiro operador
update public.profiles set role = 'admin' where email = 'voce@example.com';
```

Depois gere e imprima os códigos: [`qr-codes.md`](qr-codes.md).

## 8. CI

`.github/workflows/ci.yml` roda a cada push/PR:

1. `deno fmt --check`, `deno lint`, `deno check` nas Edge Functions
2. `deno test` (Haversine, assinatura de QR, scan tokens, Expo Push)
3. `scripts/test-sql.sh` — migrations + fluxo da fila num Postgres 16
4. Verificação de que `db/full_setup.sql` está em dia com as migrations

As versões das dependências Deno ficam fixas em `deno.lock` (commitado) e
o `supabase-js` é importado com versão exata. Sem isso, um release novo do
`supabase-js` quebra o CI sozinho: o Deno recusa dependências publicadas há
menos de 24h por política de supply chain. Para atualizar, troque a versão
nos imports e rode `deno check` para regenerar o lockfile.

Para deploy automático, adicione um job com `SUPABASE_ACCESS_TOKEN` e
`SUPABASE_PROJECT_REF` nos secrets do repositório e rode `supabase db push`
+ `supabase functions deploy` na branch de staging.

## Checklist de produção

- [ ] Projeto Supabase separado de staging
- [ ] `QR_SIGNING_SECRET` e `CRON_SECRET` exclusivos, guardados no gerenciador de segredos
- [ ] `service_role` nunca embarcada no app (só `anon`)
- [ ] RLS ativo em todas as tabelas (`pg_tables.rowsecurity`)
- [ ] Google e Apple SSO testados em device físico
- [ ] `pg_cron` agendado e verificado em `cron.job_run_details`
- [ ] Backup diário (Dashboard → Database → Backups)
- [ ] QR Codes de produção impressos e instalados nas quadras
