import { ArrowRight, CircleCheck, CircleDot, Inbox, MessageCircle, MessageSquareText, Plus, Trophy, XCircle } from 'lucide-react'
import { profileLabel } from '@/lib/format'
import type { TimelineEvent } from './api'

const dateTime = new Intl.DateTimeFormat('pt-BR', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' })

type Lookup = {
  stageName: (id: string | undefined) => string | undefined
  lostReasonName: (id: string | undefined) => string | undefined
}

function str(payload: unknown, key: string): string | undefined {
  const v = (payload as Record<string, unknown> | null)?.[key]
  return typeof v === 'string' ? v : typeof v === 'number' || typeof v === 'boolean' ? String(v) : undefined
}

function describe(e: TimelineEvent, l: Lookup) {
  const p = e.payload
  switch (e.type) {
    case 'created':
      return { icon: Plus, text: str(p, 'source_deal_id') ? 'Criado a partir do negócio ganho' : 'Criado' }
    case 'stage_change': {
      const from = l.stageName(str(p, 'from_stage_id'))
      const to = l.stageName(str(p, 'to_stage_id'))
      const days = Number(str(p, 'days_in_stage') ?? NaN)
      return {
        icon: ArrowRight,
        text: `Etapa: ${from ?? '—'} → ${to ?? '—'}`,
        detail: Number.isFinite(days) ? `${Math.floor(days)} ${Math.floor(days) === 1 ? 'dia' : 'dias'} na etapa anterior` : undefined,
      }
    }
    case 'status_change': {
      const to = str(p, 'to')
      if (to === 'won') return { icon: Trophy, text: 'Negócio ganho' }
      if (to === 'lost')
        return {
          icon: XCircle,
          text: `Negócio perdido · ${l.lostReasonName(str(p, 'lost_reason_id')) ?? 'sem motivo'}`,
          detail: str(p, 'lost_note'),
        }
      return { icon: CircleDot, text: 'Negócio reaberto' }
    }
    case 'note':
      return { icon: MessageSquareText, text: 'Nota', detail: str(p, 'excerpt') }
    case 'conversion': {
      const SOURCE: Record<string, string> = { site: 'site', webhook: 'webhook', google: 'Google Ads', meta: 'Meta' }
      const src = SOURCE[str(p, 'source') ?? ''] ?? str(p, 'source') ?? ''
      const camp = str(p, 'utm_campaign') ?? str(p, 'campaign')
      return {
        icon: Inbox,
        text: `${str(p, 'new_contact') === 'true' ? 'Lead novo' : 'Nova conversão'} pelo ${src}${camp ? ` · ${camp}` : ''}`,
        detail: str(p, 'message'),
      }
    }
    case 'whatsapp_in':
      return { icon: MessageCircle, text: 'WhatsApp recebido', detail: str(p, 'text') }
    case 'whatsapp_out':
      return { icon: MessageCircle, text: str(p, 'sent_via') === 'phone' ? 'WhatsApp enviado pelo celular' : 'WhatsApp enviado', detail: str(p, 'text') }
    case 'activity_done':
      return { icon: CircleCheck, text: `Atividade concluída: ${str(p, 'title') ?? ''}` }
    default:
      return { icon: CircleDot, text: e.type }
  }
}

export function Timeline({ events, lookup }: { events: TimelineEvent[]; lookup: Lookup }) {
  if (events.length === 0) return <p className="text-sm text-muted-foreground">Nada registrado ainda.</p>
  return (
    <ol className="relative flex flex-col gap-4 border-l border-border pl-5">
      {events.map((e) => {
        const d = describe(e, lookup)
        const Icon = d.icon
        return (
          <li key={e.id} className="relative">
            <span className="absolute top-0.5 -left-[29px] grid size-[18px] place-items-center rounded-full bg-background text-primary ring-1 ring-border">
              <Icon className="size-3" aria-hidden />
            </span>
            <p className="text-sm font-medium">{d.text}</p>
            {d.detail && <p className="mt-0.5 text-sm whitespace-pre-line text-foreground/80">{d.detail}</p>}
            <p className="mt-0.5 text-xs text-muted-foreground">
              {dateTime.format(new Date(e.occurred_at)).replace('.', '')} · {e.actor ? profileLabel(e.actor) : 'Sistema'}
            </p>
          </li>
        )
      })}
    </ol>
  )
}
