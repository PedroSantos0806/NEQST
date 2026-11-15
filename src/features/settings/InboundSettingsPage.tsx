import { useState, type ReactNode } from 'react'
import { Link } from 'react-router-dom'
import { Copy, Eye, EyeOff, RotateCcw } from 'lucide-react'
import { toast } from 'sonner'
import { cn } from '@/lib/utils'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { EmptyState, PageHeader } from '@/components/common'
import { formatPhone } from '@/lib/format'
import { friendlyError, toastError } from '@/lib/errors'
import { inboundUrl, useInboundEvents, useInboundRealtime, useInboundTokens, useReprocessEvent, type InboundEvent } from './api'

const SOURCE_LABEL: Record<InboundEvent['source'], string> = {
  site: 'Site',
  webhook: 'Webhook',
  google: 'Google Ads',
  meta: 'Meta',
  evolution: 'WhatsApp',
  gmail: 'Gmail',
}
const STATUS: Record<InboundEvent['status'], { label: string; cls: string }> = {
  pending: { label: 'Na fila', cls: 'bg-mist/25 text-ink' },
  processed: { label: 'Processado', cls: 'bg-sage/40 text-ink' },
  failed: { label: 'Falhou', cls: 'bg-destructive/15 text-destructive' },
  ignored: { label: 'Teste', cls: 'bg-muted text-muted-foreground' },
}
const dateTime = new Intl.DateTimeFormat('pt-BR', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })

function copy(text: string, what: string) {
  navigator.clipboard.writeText(text).then(
    () => toast.success(`${what} copiado`),
    () => toast.error('Não foi possível copiar'),
  )
}

function CopyValue({ label, value, secret }: { label: string; value: string | undefined; secret?: boolean }) {
  const [show, setShow] = useState(false)
  const shown = !value ? '—' : secret && !show ? '•'.repeat(24) : value
  return (
    <div className="flex flex-col gap-1">
      <span className="text-xs tracking-wide text-muted-foreground uppercase">{label}</span>
      <div className="flex items-center gap-1">
        <code className="min-w-0 flex-1 truncate rounded-md bg-muted px-2 py-1 text-xs">{shown}</code>
        {secret && value && (
          <Button variant="ghost" size="icon-sm" aria-label={show ? `Esconder ${label}` : `Mostrar ${label}`} onClick={() => setShow((v) => !v)}>
            {show ? <EyeOff aria-hidden /> : <Eye aria-hidden />}
          </Button>
        )}
        {value && (
          <Button variant="ghost" size="icon-sm" aria-label={`Copiar ${label}`} onClick={() => copy(value, label)}>
            <Copy aria-hidden />
          </Button>
        )}
      </div>
    </div>
  )
}

function Card({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="flex flex-col gap-3 rounded-xl border border-border bg-card p-4">
      <h2 className="text-2xl text-primary">{title}</h2>
      {children}
    </section>
  )
}

export function InboundSettingsPage() {
  const tokens = useInboundTokens()
  const events = useInboundEvents()
  const reprocess = useReprocessEvent()
  useInboundRealtime()
  const t = tokens.data

  const siteExample = `curl -X POST ${inboundUrl('site')} \\
  -H "Content-Type: application/json" \\
  -H "x-neqst-token: SEU_TOKEN" \\
  -d '{"nome":"Ana Souza","email":"ana@clube.com.br","telefone":"(19) 99999-0000","empresa":"Clube X","mensagem":"Quero conhecer","utm_source":"site"}'`

  return (
    <section className="flex flex-col gap-6">
      <PageHeader title="Entrada de leads" />

      {tokens.error && (
        <p role="alert" className="rounded-lg bg-muted p-3 text-sm">
          {friendlyError(tokens.error)}. Os endereços abaixo funcionam, mas os tokens só aparecem para administradores.
        </p>
      )}

      <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
        <Card title="Site e webhook genérico">
          <CopyValue label="URL do site" value={inboundUrl('site')} />
          <CopyValue label="URL de webhook" value={inboundUrl('webhook')} />
          <CopyValue label="Token (header x-neqst-token)" value={t?.site_token} secret />
          <p className="text-xs text-muted-foreground">
            Envie POST em JSON ou formulário com nome, email, telefone, empresa, cargo, cidade, mensagem e utm_*. Contato é
            deduplicado por e-mail e telefone.
          </p>
        </Card>
        <Card title="Google Ads">
          <CopyValue label="URL do webhook" value={inboundUrl('google')} />
          <CopyValue label="Chave (google_key)" value={t?.google_key} secret />
          <p className="text-xs text-muted-foreground">
            No formulário de lead da campanha: Exportar leads → Webhook. Cole a URL e a chave e use “Enviar dados de teste”:
            o teste fica marcado como Teste e não cria contato.
          </p>
        </Card>
        <Card title="Meta Lead Ads">
          <CopyValue label="URL de callback" value={inboundUrl('meta')} />
          <CopyValue label="Verify token" value={t?.meta_verify_token} secret />
          <p className="text-xs text-muted-foreground">
            No app do Meta: Webhooks → Page → campo <code>leadgen</code>. Depois grave nos secrets do Supabase o{' '}
            <code>META_APP_SECRET</code> (do app) e o <code>META_PAGE_TOKEN</code> (token de longa duração da Página).
          </p>
        </Card>
        <Card title="WhatsApp (Evolution)">
          <CopyValue
            label="URL do webhook (com token)"
            value={t ? `${inboundUrl('evolution')}?token=${t.evolution_token}` : undefined}
            secret
          />
          <p className="text-xs text-muted-foreground">
            No Evolution Manager → instância → Webhook: ative, cole a URL, marque o evento <code>MESSAGES_UPSERT</code> e deixe
            “Webhook base64” desligado. Para enviar pela ficha, grave nos secrets do Supabase <code>EVOLUTION_URL</code>,{' '}
            <code>EVOLUTION_API_KEY</code> e <code>EVOLUTION_INSTANCE</code>. Só mensagens de números que já são contatos entram no
            CRM.
          </p>
        </Card>
      </div>

      <details className="rounded-xl border border-border bg-card p-4 text-sm">
        <summary className="cursor-pointer font-medium">Exemplo de envio do site (para o desenvolvedor do site)</summary>
        <pre className="mt-3 overflow-x-auto rounded-lg bg-ink p-3 text-xs text-mauve">{siteExample}</pre>
        <Button size="sm" variant="outline" className="mt-2" onClick={() => copy(siteExample, 'Exemplo')}>
          <Copy aria-hidden /> Copiar exemplo
        </Button>
      </details>

      <div>
        <h2 className="mb-3 text-3xl text-primary">O que chegou</h2>
        {events.error ? (
          <EmptyState title="Erro ao carregar" description={friendlyError(events.error)} />
        ) : events.isLoading ? (
          <p className="text-sm text-muted-foreground">Carregando…</p>
        ) : !events.data?.length ? (
          <EmptyState title="Nenhum lead recebido ainda" description="Os envios do site, Google e Meta aparecem aqui em tempo real." />
        ) : (
          <div className="rounded-xl border border-border bg-card">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Quando</TableHead>
                  <TableHead>Origem</TableHead>
                  <TableHead>Lead</TableHead>
                  <TableHead>Situação</TableHead>
                  <TableHead className="w-28" />
                </TableRow>
              </TableHeader>
              <TableBody>
                {events.data.map((e) => {
                  const n = e.normalized as Record<string, string | null>
                  const st = STATUS[e.status]
                  return (
                    <TableRow key={e.id}>
                      <TableCell className="whitespace-nowrap text-muted-foreground">{dateTime.format(new Date(e.received_at)).replace('.', '')}</TableCell>
                      <TableCell>{SOURCE_LABEL[e.source]}</TableCell>
                      <TableCell className="max-w-72">
                        {e.contact ? (
                          <Link to={`/contatos/${e.contact.id}`} className="font-medium underline-offset-4 hover:underline">
                            {e.contact.name}
                          </Link>
                        ) : (
                          <span className="font-medium">{n.name ?? '—'}</span>
                        )}
                        <span className="block truncate text-xs text-muted-foreground">
                          {[n.email, formatPhone(n.phone), n.company].filter(Boolean).join(' · ')}
                        </span>
                        {e.error && <span className="block text-xs text-destructive">{e.error}</span>}
                      </TableCell>
                      <TableCell>
                        <Badge className={cn(st.cls)}>{st.label}</Badge>
                        {e.attempts > 1 && <span className="ml-1 text-xs text-muted-foreground">{e.attempts}×</span>}
                      </TableCell>
                      <TableCell>
                        {(e.status === 'failed' || e.status === 'pending' || (e.source === 'evolution' && e.status === 'ignored')) && (
                          <Button
                            size="sm"
                            variant="outline"
                            disabled={reprocess.isPending}
                            onClick={() =>
                              reprocess.mutate(e.id, {
                                onSuccess: () => toast.success('Reprocessado'),
                                onError: toastError('Não foi possível reprocessar'),
                              })
                            }
                          >
                            <RotateCcw aria-hidden /> Reprocessar
                          </Button>
                        )}
                      </TableCell>
                    </TableRow>
                  )
                })}
              </TableBody>
            </Table>
          </div>
        )}
      </div>
    </section>
  )
}
