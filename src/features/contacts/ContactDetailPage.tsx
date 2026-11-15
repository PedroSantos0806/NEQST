import { useMemo, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'
import { ArrowLeft, Briefcase, Mail, MessageCircle, Pencil, Phone } from 'lucide-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Textarea } from '@/components/ui/textarea'
import { EmptyState, actionButtonClass } from '@/components/common'
import { DEAL_CONTACT_ROLE_LABEL, LIFECYCLE_LABEL, formatBRL, formatPhone, profileLabel } from '@/lib/format'
import { friendlyError, toastError, unwrap } from '@/lib/errors'
import { supabase } from '@/lib/supabase'
import { useAddNote, useNotes } from '@/features/notes/api'
import { useTimeline } from '@/features/timeline/api'
import { Timeline } from '@/features/timeline/Timeline'
import { useLostReasons, usePipelines } from '@/features/deals/api'
import type { Enums } from '@/types/database'
import { ContactFormDialog } from './ContactFormDialog'
import { CreateDealFromContactDialog } from './CreateDealFromContactDialog'
import type { ContactListItem } from './api'

const STATUS_LABEL = { open: 'Aberto', won: 'Ganho', lost: 'Perdido' } as const
const dateFmt = new Intl.DateTimeFormat('pt-BR', { day: '2-digit', month: 'short', year: 'numeric' })

function useContact(id: string | undefined) {
  return useQuery({
    queryKey: ['contacts', id, 'detail'],
    enabled: !!id,
    queryFn: async () =>
      unwrap(
        await supabase
          .from('contacts')
          .select('*, company:companies(id, name), owner:profiles(full_name, email)')
          .eq('id', id!)
          .maybeSingle(),
      ) as ContactListItem | null,
  })
}

type ContactDeal = {
  role: Enums<'deal_contact_role'> | null
  deal: { id: string; title: string; value: number | null; status: Enums<'deal_status'>; stage_id: string } | null
}

function useContactDeals(id: string | undefined) {
  return useQuery({
    queryKey: ['contact-deals', id],
    enabled: !!id,
    queryFn: async () =>
      unwrap(
        await supabase.from('deal_contacts').select('role, deal:deals(id, title, value, status, stage_id)').eq('contact_id', id!),
      ) as unknown as ContactDeal[],
  })
}

export function ContactDetailPage() {
  const { id } = useParams<{ id: string }>()
  const contact = useContact(id)
  const deals = useContactDeals(id)
  const notes = useNotes({ contactId: id })
  const timeline = useTimeline('contact', id)
  const pipelines = usePipelines()
  const lostReasons = useLostReasons()
  const addNote = useAddNote()
  const [editing, setEditing] = useState(false)
  const [creatingDeal, setCreatingDeal] = useState(false)
  const [note, setNote] = useState('')

  const allStages = useMemo(() => (pipelines.data ?? []).flatMap((p) => p.stages), [pipelines.data])
  const lookup = useMemo(
    () => ({
      stageName: (sid: string | undefined) => allStages.find((s) => s.id === sid)?.name,
      lostReasonName: (rid: string | undefined) => lostReasons.data?.find((r) => r.id === rid)?.name,
    }),
    [allStages, lostReasons.data],
  )

  if (contact.isLoading) return <p className="text-sm text-muted-foreground">Carregando…</p>
  if (contact.error) return <EmptyState title="Erro ao carregar" description={friendlyError(contact.error)} />
  if (!contact.data) return <EmptyState title="Contato não encontrado" />

  const c = contact.data
  const custom = (c.custom ?? {}) as Record<string, string>
  const utm = [c.utm_source, c.utm_medium, c.utm_campaign].filter(Boolean).join(' / ')

  return (
    <section className="flex flex-col gap-6">
      <div>
        <Link to="/contatos" className="mb-3 inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground">
          <ArrowLeft className="size-4" aria-hidden /> Contatos
        </Link>
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div className="min-w-0">
            <h1 className="text-5xl leading-none text-primary">{c.name}</h1>
            <div className="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-muted-foreground">
              <Badge variant="secondary">{LIFECYCLE_LABEL[c.lifecycle_stage]}</Badge>
              {c.job_title && <span>{c.job_title}</span>}
              {c.company ? (
                <Link to={`/empresas/${c.company.id}`} className="font-medium text-foreground/80 underline-offset-4 hover:underline">
                  {c.company.name}
                </Link>
              ) : (
                custom.company_name && <span>Empresa informada: {custom.company_name}</span>
              )}
              <span>Responsável: {profileLabel(c.owner)}</span>
            </div>
          </div>
          <div className="flex flex-wrap gap-2">
            <Button variant="outline" onClick={() => setEditing(true)}>
              <Pencil aria-hidden /> Editar
            </Button>
            <Button className={actionButtonClass} onClick={() => setCreatingDeal(true)}>
              <Briefcase aria-hidden /> Criar negócio
            </Button>
          </div>
        </div>
      </div>

      <dl className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Info label="E-mail">
          {c.email ? (
            <a href={`mailto:${c.email}`} className="inline-flex items-center gap-1 underline-offset-4 hover:underline">
              <Mail className="size-3.5" aria-hidden /> {c.email}
            </a>
          ) : (
            '—'
          )}
        </Info>
        <Info label="Telefone">
          {c.phone ? (
            <span className="inline-flex flex-wrap items-center gap-2">
              <span className="inline-flex items-center gap-1">
                <Phone className="size-3.5" aria-hidden /> {formatPhone(c.phone)}
              </span>
              <a href={`https://wa.me/${c.phone.replace(/\D/g, '')}`} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1 text-primary underline-offset-4 hover:underline">
                <MessageCircle className="size-3.5" aria-hidden /> WhatsApp
              </a>
            </span>
          ) : (
            '—'
          )}
        </Info>
        <Info label="Origem">{c.source ?? '—'}</Info>
        <Info label="Campanha (UTM)">{utm || '—'}</Info>
      </dl>

      <div className="grid gap-6 lg:grid-cols-[1fr_minmax(0,24rem)]">
        <div className="flex flex-col gap-6">
          <div>
            <h2 className="mb-3 text-3xl text-primary">Negócios</h2>
            {deals.data?.length ? (
              <ul className="flex flex-col gap-2">
                {deals.data.map(({ deal: d, role }) =>
                  d ? (
                    <li key={d.id} className="flex flex-wrap items-center justify-between gap-2 rounded-xl border border-border bg-card px-3 py-2 text-sm">
                      <Link to={`/negocios/${d.id}`} className="font-medium underline-offset-4 hover:underline">
                        {d.title}
                      </Link>
                      <span className="flex items-center gap-2 text-muted-foreground">
                        {allStages.find((s) => s.id === d.stage_id)?.name}
                        <Badge variant="secondary">{STATUS_LABEL[d.status]}</Badge>
                        {role && <Badge variant="outline">{DEAL_CONTACT_ROLE_LABEL[role]}</Badge>}
                        <span className="font-display text-lg text-primary">{formatBRL(d.value)}</span>
                      </span>
                    </li>
                  ) : null,
                )}
              </ul>
            ) : (
              <p className="text-sm text-muted-foreground">Nenhum negócio ligado. Use “Criar negócio” quando virar oportunidade.</p>
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
                  { body, contact_id: c.id, company_id: c.company_id },
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
              <Textarea aria-label="Nova nota" rows={3} value={note} onChange={(e) => setNote(e.target.value)} className="bg-card" />
              <Button type="submit" disabled={!note.trim() || addNote.isPending} className={`${actionButtonClass} self-end`}>
                Salvar nota
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

      <ContactFormDialog open={editing} onOpenChange={setEditing} contact={c} />
      <CreateDealFromContactDialog contact={creatingDeal ? c : null} onClose={() => setCreatingDeal(false)} />
    </section>
  )
}

function Info({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="rounded-xl border border-border bg-card px-3 py-2.5">
      <dt className="text-xs tracking-wide text-muted-foreground uppercase">{label}</dt>
      <dd className="mt-0.5 text-sm">{children}</dd>
    </div>
  )
}
