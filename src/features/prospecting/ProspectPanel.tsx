import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { toast } from 'sonner'
import { Ban, Copy, ExternalLink, Globe, MapPin, MessageCircle, Phone, RefreshCw, Sparkles, Undo2, UserCheck } from 'lucide-react'
import { cn } from '@/lib/utils'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Textarea } from '@/components/ui/textarea'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Field, NativeSelect } from '@/components/form'
import { actionButtonClass } from '@/components/common'
import { COMPANY_TYPE_LABEL, formatPhone, options } from '@/lib/format'
import { friendlyError } from '@/lib/errors'
import { usePipelines } from '@/features/deals/api'
import { useCompanyOptions } from '@/features/companies/api'
import type { Enums } from '@/types/database'
import {
  PROSPECT_STATUS_LABEL,
  scoreClass,
  useDiscardProspect,
  useLatestResearch,
  useQualifyProspect,
  useResearchProspect,
  useRestoreProspect,
  type DecisionMaker,
  type DossierItem,
  type ProspectListItem,
  type Source,
} from './api'

const dateTime = new Intl.DateTimeFormat('pt-BR', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })

export function ProspectPanel({ prospect: p }: { prospect: ProspectListItem }) {
  const navigate = useNavigate()
  const research = useLatestResearch(p.id)
  const run = useResearchProspect()
  const restore = useRestoreProspect()
  const [qualifying, setQualifying] = useState(false)
  const [discarding, setDiscarding] = useState(false)

  const r = research.data
  const researching = p.status === 'researching' || run.isPending
  const closed = p.status === 'qualified' || p.status === 'discarded'

  const startResearch = () =>
    run.mutate(p.id, {
      onSuccess: () => toast.success('Dossiê pronto'),
      onError: (err) => toast.error('A pesquisa falhou', { description: friendlyError(err) }),
    })

  const whatsappUrl = p.phone && r?.suggested_message
    ? `https://wa.me/${p.phone.replace(/\D/g, '')}?text=${encodeURIComponent(r.suggested_message)}`
    : null

  return (
    <article className="flex flex-col gap-5 rounded-xl border border-border bg-card p-5">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 className="text-4xl leading-none text-primary">{p.name}</h2>
          <div className="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-muted-foreground">
            <Badge variant="secondary">{PROSPECT_STATUS_LABEL[p.status]}</Badge>
            {p.company_type && <span>{COMPANY_TYPE_LABEL[p.company_type]}</span>}
            {p.address && (
              <span className="flex items-center gap-1">
                <MapPin className="size-3.5" aria-hidden /> {p.address}
              </span>
            )}
          </div>
          <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-sm">
            {p.website && (
              <a href={p.website} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1 text-primary underline-offset-4 hover:underline">
                <Globe className="size-3.5" aria-hidden /> Site
              </a>
            )}
            {p.google_maps_uri && (
              <a href={p.google_maps_uri} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1 text-primary underline-offset-4 hover:underline">
                <ExternalLink className="size-3.5" aria-hidden /> {p.source === 'openstreetmap' ? 'Ver no mapa' : 'Google Maps'}
              </a>
            )}
            {p.instagram && (
              <a
                href={p.instagram.startsWith('http') ? p.instagram : `https://instagram.com/${p.instagram.replace(/^@/, '')}`}
                target="_blank"
                rel="noreferrer"
                className="inline-flex items-center gap-1 text-primary underline-offset-4 hover:underline"
              >
                <ExternalLink className="size-3.5" aria-hidden /> Instagram
              </a>
            )}
            {p.phone && (
              <span className="inline-flex items-center gap-1">
                <Phone className="size-3.5" aria-hidden /> {formatPhone(p.phone)}
              </span>
            )}
            {p.mapped_courts != null && (
              <span className="text-muted-foreground">
                {p.mapped_courts} quadras no mapa{p.mapped_sports.length ? ` (${p.mapped_sports.join(', ')})` : ''}
              </span>
            )}
            {p.rating != null && (
              <span className="text-muted-foreground">
                ★ {p.rating} ({p.rating_count ?? 0})
              </span>
            )}
          </div>
        </div>

        <div className="flex flex-wrap gap-2">
          {!closed && (
            <Button variant="outline" disabled={researching} onClick={startResearch}>
              {r ? <RefreshCw aria-hidden className={cn(researching && 'animate-spin')} /> : <Sparkles aria-hidden />}
              {researching ? 'Pesquisando…' : r ? 'Refazer pesquisa' : 'Pesquisar com IA'}
            </Button>
          )}
          {!closed && (
            <>
              <Button className={actionButtonClass} onClick={() => setQualifying(true)}>
                <UserCheck aria-hidden /> Qualificar
              </Button>
              <Button variant="destructive" onClick={() => setDiscarding(true)}>
                <Ban aria-hidden /> Descartar
              </Button>
            </>
          )}
          {p.status === 'qualified' && p.deal_id && (
            <Button className={actionButtonClass} onClick={() => navigate(`/negocios/${p.deal_id}`)}>
              Abrir negócio
            </Button>
          )}
          {p.status === 'discarded' && (
            <Button
              variant="outline"
              onClick={() =>
                restore.mutate(
                  { id: p.id, hasResearch: !!r },
                  { onError: (err) => toast.error('Não foi possível restaurar', { description: friendlyError(err) }) },
                )
              }
            >
              <Undo2 aria-hidden /> Voltar para a fila
            </Button>
          )}
        </div>
      </header>

      {p.status === 'discarded' && p.discard_reason && (
        <p className="rounded-lg bg-muted p-3 text-sm">
          <strong>Descartado:</strong> {p.discard_reason}
        </p>
      )}
      {p.last_error && !researching && (
        <p role="alert" className="rounded-lg bg-destructive/10 p-3 text-sm text-destructive">
          Última pesquisa falhou: {p.last_error}
        </p>
      )}

      {researching && !r && (
        <p className="rounded-lg bg-muted p-4 text-sm text-muted-foreground">
          Lendo o site do lead e montando o dossiê. Leva de 20 a 60 segundos.
        </p>
      )}

      {research.isLoading ? (
        <p className="text-sm text-muted-foreground">Carregando dossiê…</p>
      ) : !r ? (
        !researching && (
          <p className="rounded-lg bg-muted p-4 text-sm text-muted-foreground">
            Sem dossiê ainda. Clique em <strong>Pesquisar com IA</strong> para levantar ganchos, oportunidades e decisores.
            {!p.website && ' Este lead não tem site cadastrado: o dossiê vai usar só nome, cidade e dados do mapa.'}
          </p>
        )
      ) : (
        <div className="flex flex-col gap-5">
          <div className="flex flex-wrap items-start gap-4">
            <div className={cn('rounded-xl px-4 py-3 text-center', scoreClass(r.score))}>
              <p className="font-display text-5xl leading-none">{r.score ?? '—'}</p>
              <p className="text-xs">aderência</p>
            </div>
            <div className="min-w-0 flex-1">
              <p className="text-sm">{r.summary}</p>
              {r.score_reason && <p className="mt-1 text-xs text-muted-foreground">{r.score_reason}</p>}
              <p className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-sm">
                <span>
                  <span className="font-display text-xl text-primary">{r.estimated_courts ?? '—'}</span> quadras estimadas
                </span>
                {r.court_types.length > 0 && <span className="text-muted-foreground">{r.court_types.join(', ')}</span>}
              </p>
              {r.has_internet_hint && <p className="mt-1 text-xs text-muted-foreground">Internet: {r.has_internet_hint}</p>}
            </div>
          </div>

          <div className="grid gap-4 md:grid-cols-2">
            <ItemList title="Ganchos" items={r.hooks as DossierItem[]} />
            <ItemList title="Oportunidades" items={r.opportunities as DossierItem[]} />
          </div>

          <div>
            <h3 className="mb-2 text-2xl text-primary">Decisores</h3>
            {(r.decision_makers as DecisionMaker[]).length ? (
              <ul className="flex flex-col gap-1.5 text-sm">
                {(r.decision_makers as DecisionMaker[]).map((d, i) => (
                  <li key={i}>
                    <span className="font-medium">{d.role}</span>
                    {d.name && <span> · {d.name}</span>}
                    {d.how_to_reach && <span className="block text-xs text-muted-foreground">{d.how_to_reach}</span>}
                  </li>
                ))}
              </ul>
            ) : (
              <p className="text-sm text-muted-foreground">A pesquisa não identificou decisores.</p>
            )}
          </div>

          {r.suggested_message && (
            <div>
              <h3 className="mb-2 text-2xl text-primary">Primeira mensagem sugerida</h3>
              <p className="rounded-lg bg-mauve/60 p-3 text-sm whitespace-pre-line">{r.suggested_message}</p>
              <div className="mt-2 flex flex-wrap gap-2">
                <Button
                  size="sm"
                  variant="outline"
                  onClick={() =>
                    navigator.clipboard.writeText(r.suggested_message ?? '').then(
                      () => toast.success('Mensagem copiada'),
                      () => toast.error('Não foi possível copiar'),
                    )
                  }
                >
                  <Copy aria-hidden /> Copiar
                </Button>
                {whatsappUrl && (
                  <a
                    href={whatsappUrl}
                    target="_blank"
                    rel="noreferrer"
                    className="inline-flex h-7 items-center gap-1 rounded-lg border border-border px-2.5 text-[0.8rem] font-medium hover:bg-muted"
                  >
                    <MessageCircle className="size-3.5" aria-hidden /> Abrir no WhatsApp
                  </a>
                )}
              </div>
              <p className="mt-1 text-xs text-muted-foreground">Revise antes de enviar: é um rascunho da IA.</p>
            </div>
          )}

          <details className="text-sm">
            <summary className="cursor-pointer text-muted-foreground">
              Fontes ({(r.sources as Source[]).length}) · {r.model} · {dateTime.format(new Date(r.created_at)).replace('.', '')}
            </summary>
            <ul className="mt-2 flex flex-col gap-1">
              {(r.sources as Source[]).map((s, i) => (
                <li key={i}>
                  <a href={s.uri} target="_blank" rel="noreferrer" className="text-primary underline-offset-4 hover:underline">
                    {s.title}
                  </a>
                </li>
              ))}
            </ul>
          </details>
        </div>
      )}

      <QualifyDialog open={qualifying} onOpenChange={setQualifying} prospect={p} />
      <DiscardDialog open={discarding} onOpenChange={setDiscarding} prospect={p} />
    </article>
  )
}

function ItemList({ title, items }: { title: string; items: DossierItem[] }) {
  return (
    <div>
      <h3 className="mb-2 text-2xl text-primary">{title}</h3>
      {items.length ? (
        <ul className="flex flex-col gap-2 text-sm">
          {items.map((it, i) => (
            <li key={i} className="rounded-lg border border-border/70 bg-background/50 p-2.5">
              <p className="font-medium">{it.title}</p>
              {it.detail && <p className="mt-0.5 text-foreground/80">{it.detail}</p>}
            </li>
          ))}
        </ul>
      ) : (
        <p className="text-sm text-muted-foreground">Nada encontrado.</p>
      )}
    </div>
  )
}

function QualifyDialog({ open, onOpenChange, prospect: p }: { open: boolean; onOpenChange: (o: boolean) => void; prospect: ProspectListItem }) {
  const navigate = useNavigate()
  const pipelines = usePipelines()
  const companies = useCompanyOptions()
  const qualify = useQualifyProspect()
  const salesPipelines = (pipelines.data ?? []).filter((x) => x.type === 'sales')
  const [pipelineId, setPipelineId] = useState('')
  const [companyId, setCompanyId] = useState('')
  const [companyType, setCompanyType] = useState<string>(p.company_type ?? '')

  const effectivePipeline = pipelineId || salesPipelines[0]?.id || ''

  const submit = () =>
    qualify.mutate(
      {
        prospectId: p.id,
        pipelineId: effectivePipeline,
        companyId: companyId || null,
        companyType: (companyType || null) as Enums<'company_type'> | null,
      },
      {
        onSuccess: (dealId) => {
          onOpenChange(false)
          toast.success('Lead qualificado', {
            description: 'Empresa, local e negócio criados na 1ª etapa do funil.',
            action: { label: 'Abrir negócio', onClick: () => navigate(`/negocios/${dealId}`) },
          })
        },
        onError: (err) => toast.error('Não foi possível qualificar', { description: friendlyError(err) }),
      },
    )

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle className="font-display text-2xl tracking-wide">Qualificar lead</DialogTitle>
          <DialogDescription>{p.name}</DialogDescription>
        </DialogHeader>
        <div className="grid gap-4">
          <Field label="Funil" htmlFor="q-pipeline">
            <NativeSelect id="q-pipeline" value={effectivePipeline} onChange={(e) => setPipelineId(e.target.value)}>
              {salesPipelines.map((x) => (
                <option key={x.id} value={x.id}>
                  {x.name}
                </option>
              ))}
            </NativeSelect>
          </Field>
          <Field label="Empresa" htmlFor="q-company" hint="Use uma existente se o lugar é de um operador já cadastrado (ex.: outro parque da Urbia).">
            <NativeSelect id="q-company" value={companyId} onChange={(e) => setCompanyId(e.target.value)}>
              <option value="">Criar nova: {p.name}</option>
              {companies.data?.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name}
                </option>
              ))}
            </NativeSelect>
          </Field>
          {!companyId && (
            <Field label="Tipo da nova empresa" htmlFor="q-type">
              <NativeSelect id="q-type" value={companyType} onChange={(e) => setCompanyType(e.target.value)}>
                <option value="">Selecione…</option>
                {options(COMPANY_TYPE_LABEL).map((o) => (
                  <option key={o.value} value={o.value}>
                    {o.label}
                  </option>
                ))}
              </NativeSelect>
            </Field>
          )}
          <p className="text-xs text-muted-foreground">
            Cria o local com as quadras estimadas, abre o negócio na 1ª etapa e guarda o dossiê como nota. Contatos você
            cadastra depois, confirmando os dados.
          </p>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancelar
          </Button>
          <Button
            className={actionButtonClass}
            disabled={qualify.isPending || !effectivePipeline || (!companyId && !companyType)}
            onClick={submit}
          >
            {qualify.isPending ? 'Qualificando…' : 'Qualificar'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

function DiscardDialog({ open, onOpenChange, prospect: p }: { open: boolean; onOpenChange: (o: boolean) => void; prospect: ProspectListItem }) {
  const discard = useDiscardProspect()
  const [reason, setReason] = useState('')
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle className="font-display text-2xl tracking-wide">Descartar lead</DialogTitle>
          <DialogDescription>{p.name}</DialogDescription>
        </DialogHeader>
        <Field label="Motivo" htmlFor="d-reason" hint="Ex.: não tem quadra, fora do perfil, já é cliente, fechado.">
          <Textarea id="d-reason" rows={2} value={reason} onChange={(e) => setReason(e.target.value)} />
        </Field>
        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Cancelar
          </Button>
          <Button
            variant="destructive"
            disabled={!reason.trim() || discard.isPending}
            onClick={() =>
              discard.mutate(
                { id: p.id, reason: reason.trim() },
                {
                  onSuccess: () => {
                    onOpenChange(false)
                    toast.success('Lead descartado')
                  },
                  onError: (err) => toast.error('Não foi possível descartar', { description: friendlyError(err) }),
                },
              )
            }
          >
            Descartar
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
