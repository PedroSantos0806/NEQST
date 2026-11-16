import { useMemo, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { ArrowLeft, CircleAlert, Pencil, Plus, RotateCcw, Trophy, XCircle } from 'lucide-react'
import { toast } from 'sonner'
import { cn } from '@/lib/utils'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Textarea } from '@/components/ui/textarea'
import { EmptyState, actionButtonClass } from '@/components/common'
import { DEAL_CONTACT_ROLE_LABEL, formatBRL, formatPhone, profileLabel } from '@/lib/format'
import { friendlyError, missingRequiredFields, toastError } from '@/lib/errors'
import { useDealActivities, type ActivityItem } from '@/features/activities/api'
import { ActivityList } from '@/features/activities/ActivityList'
import { ActivityFormDialog } from '@/features/activities/ActivityFormDialog'
import { useAddNote, useNotes } from '@/features/notes/api'
import { useTimeline } from '@/features/timeline/api'
import { Timeline } from '@/features/timeline/Timeline'
import { useDealFull, useLostReasons, usePipelines, useReopenDeal, useSetStage } from './api'
import { DealFormDialog } from './DealFormDialog'
import { LostDealDialog, WonDealDialog } from './CloseDealDialogs'
import { daysInStage, isStale } from './board-utils'

const STATUS_LABEL = { open: 'Aberto', won: 'Ganho', lost: 'Perdido' } as const
const dateFmt = new Intl.DateTimeFormat('pt-BR', { day: '2-digit', month: 'short', year: 'numeric' })

export function DealDetailPage() {
  const { id } = useParams<{ id: string }>()
  const deal = useDealFull(id)
  const pipelines = usePipelines()
  const lostReasons = useLostReasons()
  const activities = useDealActivities(id)
  const notes = useNotes({ dealId: id })
  const timeline = useTimeline('deal', id)
  const setStage = useSetStage()
  const reopen = useReopenDeal()
  const addNote = useAddNote()

  const [editing, setEditing] = useState<{ missing?: string[] } | null>(null)
  const [activityForm, setActivityForm] = useState<{ activity?: ActivityItem; next?: { reason: string; suggestedTitle?: string } } | null>(null)
  const [closing, setClosing] = useState<'won' | 'lost' | null>(null)
  const [note, setNote] = useState('')
  const [showDone, setShowDone] = useState(false)

  const allStages = useMemo(() => (pipelines.data ?? []).flatMap((p) => p.stages), [pipelines.data])
  const lookup = useMemo(
    () => ({
      stageName: (sid: string | undefined) => allStages.find((s) => s.id === sid)?.name,
      lostReasonName: (rid: string | undefined) => lostReasons.data?.find((r) => r.id === rid)?.name,
    }),
    [allStages, lostReasons.data],
  )

  if (deal.isLoading || pipelines.isLoading) return <p className="text-sm text-muted-foreground">Carregando…</p>
  if (deal.error) return <EmptyState title="Erro ao carregar" description={friendlyError(deal.error)} />
  if (!deal.data) return <EmptyState title="Negócio não encontrado" />

  const d = deal.data
  const pipeline = pipelines.data?.find((p) => p.id === d.pipeline_id)
  const stage = pipeline?.stages.find((s) => s.id === d.stage_id)
  const isOpen = d.status === 'open'
  const isSales = pipeline?.type === 'sales'
  const open = (activities.data ?? []).filter((a) => !a.done_at)
  const done = (activities.data ?? []).filter((a) => a.done_at)
  const stale = isOpen && isStale(d, stage)

  const askNext = (reason: string, nextStageId?: string) => {
    const target = pipeline?.stages.find((s) => s.id === (nextStageId ?? d.stage_id))
    setActivityForm({ next: { reason, suggestedTitle: target?.exit_criteria ?? undefined } })
  }

  const moveTo = (stageId: string) => {
    if (!isOpen || stageId === d.stage_id) return
    setStage.mutate(
      { id: d.id, stage_id: stageId },
      {
        onSuccess: () => {
          const name = pipeline?.stages.find((s) => s.id === stageId)?.name
          toast.success(`Movido para ${name}`)
          askNext(`Agora em ${name}`, stageId)
        },
        onError: (err) => {
          const missing = missingRequiredFields(err)
          if (missing) setEditing({ missing })
          toast.error('Não foi possível mudar a etapa', { description: friendlyError(err) })
        },
      },
    )
  }

  return (
    <section className="flex flex-col gap-6">
      <div>
        <Link
          to={`/?funil=${d.pipeline_id}`}
          className="mb-3 inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground"
        >
          <ArrowLeft className="size-4" aria-hidden /> {pipeline?.name ?? 'Funis'}
        </Link>
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div className="min-w-0">
            <h1 className="text-5xl leading-none text-primary">{d.title}</h1>
            <div className="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-muted-foreground">
              <Badge
                className={cn(
                  d.status === 'won' && 'bg-sage/40 text-ink',
                  d.status === 'lost' && 'bg-destructive/15 text-destructive',
                  d.status === 'open' && 'bg-secondary text-secondary-foreground',
                )}
              >
                {STATUS_LABEL[d.status]}
              </Badge>
              {d.company && (
                <Link to={`/empresas/${d.company.id}`} className="font-medium text-foreground/80 underline-offset-4 hover:underline">
                  {d.company.name}
                </Link>
              )}
              <span>Responsável: {profileLabel(d.owner)}</span>
              {d.status === 'lost' && d.lost_reason && <span>Motivo: {d.lost_reason.name}</span>}
            </div>
          </div>
          <div className="flex flex-wrap gap-2">
            <Button variant="outline" onClick={() => setEditing({})}>
              <Pencil aria-hidden /> Editar
            </Button>
            {isOpen && isSales && (
              <>
                <Button className="bg-sage text-ink hover:bg-sage/85" onClick={() => setClosing('won')}>
                  <Trophy aria-hidden /> Ganho
                </Button>
                <Button variant="destructive" onClick={() => setClosing('lost')}>
                  <XCircle aria-hidden /> Perdido
                </Button>
              </>
            )}
            {!isOpen && (
              <Button
                variant="outline"
                disabled={reopen.isPending}
                onClick={() =>
                  reopen.mutate(d.id, {
                    onSuccess: () => toast.success('Negócio reaberto'),
                    onError: toastError('Não foi possível reabrir'),
                  })
                }
              >
                <RotateCcw aria-hidden /> Reabrir
              </Button>
            )}
          </div>
        </div>
      </div>

      {pipeline && (
        <nav aria-label="Etapas" className="flex gap-1 overflow-x-auto pb-1">
          {pipeline.stages.map((s) => {
            const current = s.id === d.stage_id
            const passed = s.sort_order < (stage?.sort_order ?? 0)
            return (
              <button
                key={s.id}
                type="button"
                disabled={!isOpen || setStage.isPending}
                aria-current={current ? 'step' : undefined}
                title={s.exit_criteria ?? undefined}
                onClick={() => moveTo(s.id)}
                className={cn(
                  'min-w-28 flex-1 rounded-md px-2 py-1.5 text-xs font-medium whitespace-nowrap transition-colors focus-visible:ring-3 focus-visible:ring-ring/50 focus-visible:outline-none disabled:cursor-default',
                  current
                    ? 'bg-primary text-primary-foreground'
                    : passed
                      ? 'bg-primary/25 text-primary hover:bg-primary/35'
                      : 'bg-secondary text-muted-foreground hover:bg-muted',
                )}
              >
                {s.name}
              </button>
            )
          })}
        </nav>
      )}

      {isOpen && open.length === 0 && (
        <div role="alert" className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm">
          <span className="flex items-center gap-2 font-medium text-destructive">
            <CircleAlert className="size-4" aria-hidden /> Este negócio não tem próxima atividade.
          </span>
          <Button size="sm" className={actionButtonClass} onClick={() => askNext('Todo negócio aberto precisa de um próximo passo')}>
            Agendar agora
          </Button>
        </div>
      )}

      <dl className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
        <Info label="Valor anual" value={formatBRL(d.value)} big />
        <Info label="Quadras" value={d.court_count != null ? String(d.court_count) : '—'} big />
        <Info label="Preço / quadra / mês" value={formatBRL(d.price_per_court)} />
        <Info label="Previsão de fechamento" value={d.expected_close_date ? dateFmt.format(new Date(`${d.expected_close_date}T12:00`)) : '—'} />
        <Info label="Etapa" value={stage?.name ?? '—'} />
        <Info
          label="Dias na etapa"
          value={isOpen ? String(daysInStage(d)) : '—'}
          warn={stale}
          hint={stale ? `Parado (alerta: ${stage?.alert_days} dias)` : undefined}
        />
      </dl>

      <div className="grid gap-6 lg:grid-cols-[1fr_minmax(0,24rem)]">
        <div className="flex flex-col gap-6">
          <div className="grid gap-4 sm:grid-cols-2">
            <div className="rounded-xl border border-border bg-card p-4">
              <h2 className="mb-2 text-xl text-primary">Locais</h2>
              {d.deal_locations.length ? (
                <ul className="flex flex-col gap-1 text-sm">
                  {d.deal_locations.map(({ location: l }) =>
                    l ? (
                      <li key={l.id}>
                        {l.name}
                        {l.court_count != null && <span className="text-muted-foreground"> · {l.court_count} quadras</span>}
                      </li>
                    ) : null,
                  )}
                </ul>
              ) : (
                <p className="text-sm text-muted-foreground">Nenhum local ligado.</p>
              )}
            </div>
            <div className="rounded-xl border border-border bg-card p-4">
              <h2 className="mb-2 text-xl text-primary">Contatos</h2>
              {d.deal_contacts.length ? (
                <ul className="flex flex-col gap-2 text-sm">
                  {d.deal_contacts.map(({ contact: c, role }) =>
                    c ? (
                      <li key={c.id}>
                        <span className="font-medium">{c.name}</span>
                        {role && <Badge variant="secondary" className="ml-2">{DEAL_CONTACT_ROLE_LABEL[role]}</Badge>}
                        <span className="block text-xs text-muted-foreground">
                          {[c.job_title, formatPhone(c.phone), c.email].filter(Boolean).join(' · ')}
                        </span>
                      </li>
                    ) : null,
                  )}
                </ul>
              ) : (
                <p className="text-sm text-muted-foreground">Nenhum contato ligado.</p>
              )}
            </div>
          </div>

          <div>
            <div className="mb-3 flex items-center justify-between gap-2">
              <h2 className="text-3xl text-primary">Atividades</h2>
              <Button className={actionButtonClass} onClick={() => setActivityForm({})}>
                <Plus aria-hidden /> Nova atividade
              </Button>
            </div>
            {open.length > 0 ? (
              <ActivityList
                items={open}
                showDeal={false}
                onEdit={(a) => setActivityForm({ activity: a })}
                onDealWithoutNext={() => askNext('Atividade concluída. Qual o próximo passo?')}
              />
            ) : (
              <p className="text-sm text-muted-foreground">Nenhuma atividade em aberto.</p>
            )}
            {done.length > 0 && (
              <div className="mt-3">
                <button type="button" className="text-sm text-primary underline underline-offset-4" onClick={() => setShowDone((v) => !v)}>
                  {showDone ? 'Esconder' : 'Ver'} concluídas ({done.length})
                </button>
                {showDone && (
                  <div className="mt-2">
                    <ActivityList items={done} showDeal={false} onEdit={(a) => setActivityForm({ activity: a })} />
                  </div>
                )}
              </div>
            )}
          </div>

          <div>
            <h2 className="mb-3 text-3xl text-primary">Notas</h2>
            <form
              className="flex flex-col gap-2"
              onSubmit={(e) => {
                e.preventDefault()
                const body = note.trim()
                if (!body) return
                addNote.mutate(
                  { body, deal_id: d.id, company_id: d.company_id },
                  {
                    onSuccess: () => {
                      setNote('')
                      toast.success('Nota salva')
                    },
                    onError: toastError('Não foi possível salvar a nota'),
                  },
                )
              }}
            >
              <Textarea
                aria-label="Nova nota"
                placeholder="O que aconteceu? Combinados, objeções, contexto…"
                rows={3}
                value={note}
                onChange={(e) => setNote(e.target.value)}
                className="bg-card"
              />
              <Button type="submit" disabled={!note.trim() || addNote.isPending} className={cn(actionButtonClass, 'self-end')}>
                {addNote.isPending ? 'Salvando…' : 'Salvar nota'}
              </Button>
            </form>
            <ul className="mt-4 flex flex-col gap-3">
              {(notes.data ?? []).map((n) => (
                <li key={n.id} className="rounded-xl border border-border bg-card p-3">
                  <p className="text-sm whitespace-pre-line">{n.body}</p>
                  <p className="mt-1 text-xs text-muted-foreground">
                    {profileLabel(n.author)} · {dateFmt.format(new Date(n.created_at))}
                  </p>
                </li>
              ))}
            </ul>
          </div>
        </div>

        <aside>
          <h2 className="mb-3 text-3xl text-primary">Linha do tempo</h2>
          {timeline.isLoading ? (
            <p className="text-sm text-muted-foreground">Carregando…</p>
          ) : (
            <Timeline events={timeline.data ?? []} lookup={lookup} />
          )}
        </aside>
      </div>

      {pipeline && (
        <DealFormDialog
          open={editing !== null}
          onOpenChange={(o) => !o && setEditing(null)}
          pipeline={pipeline}
          dealId={d.id}
          missing={editing?.missing}
        />
      )}
      <ActivityFormDialog
        open={activityForm !== null}
        onOpenChange={(o) => !o && setActivityForm(null)}
        dealId={d.id}
        dealTitle={d.title}
        activity={activityForm?.activity}
        next={activityForm?.next}
      />
      <WonDealDialog deal={closing === 'won' ? d : null} onClose={() => setClosing(null)} />
      <LostDealDialog deal={closing === 'lost' ? d : null} onClose={() => setClosing(null)} />
    </section>
  )
}

function Info({ label, value, big, warn, hint }: { label: string; value: string; big?: boolean; warn?: boolean; hint?: string }) {
  return (
    <div className={cn('rounded-xl border bg-card px-3 py-2.5', warn ? 'border-ochre bg-[#f7ece0]' : 'border-border')} title={hint}>
      <dt className="text-xs tracking-wide text-muted-foreground uppercase">{label}</dt>
      <dd className={cn('mt-0.5 leading-tight', big ? 'font-display text-3xl text-primary' : 'text-sm font-medium', warn && 'text-[#8a5a1f]')}>
        {value}
      </dd>
      {hint && <p className="mt-0.5 text-xs text-[#8a5a1f]">{hint}</p>}
    </div>
  )
}
