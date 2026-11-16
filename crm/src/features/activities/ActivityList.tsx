import { Link } from 'react-router-dom'
import { CalendarClock, Mail, MapPin, MessageCircle, Pencil, Phone, SquareCheck, Users } from 'lucide-react'
import { toast } from 'sonner'
import { cn } from '@/lib/utils'
import { Button } from '@/components/ui/button'
import { ConfirmDelete } from '@/components/common'
import { ACTIVITY_TYPE_LABEL, profileLabel } from '@/lib/format'
import { toastError } from '@/lib/errors'
import type { Enums } from '@/types/database'
import { isOverdue } from '@/features/deals/board-utils'
import { useDeleteActivity, useToggleActivity, type ActivityItem } from './api'

const ICON: Record<Enums<'activity_type'>, typeof Phone> = {
  task: SquareCheck,
  call: Phone,
  meeting: Users,
  visit: MapPin,
  whatsapp: MessageCircle,
  email: Mail,
}

const dateTime = new Intl.DateTimeFormat('pt-BR', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })
const formatDue = (iso: string) => dateTime.format(new Date(iso)).replace('.', '')

export function ActivityList({
  items,
  showDeal = true,
  onEdit,
  onDealWithoutNext,
}: {
  items: ActivityItem[]
  showDeal?: boolean
  onEdit: (a: ActivityItem) => void
  /** Chamado quando concluir deixou o negócio sem atividade aberta. */
  onDealWithoutNext?: (dealId: string, dealTitle: string | undefined) => void
}) {
  const toggle = useToggleActivity()
  const remove = useDeleteActivity()

  return (
    <ul className="divide-y divide-border rounded-xl border border-border bg-card">
      {items.map((a) => {
        const Icon = ICON[a.type]
        const done = !!a.done_at
        const overdue = !done && isOverdue(a.due_at)
        return (
          <li key={a.id} className="flex items-start gap-3 px-3 py-2.5">
            <input
              type="checkbox"
              className="mt-1 size-4 shrink-0 accent-forest"
              checked={done}
              aria-label={done ? `Reabrir: ${a.title}` : `Concluir: ${a.title}`}
              onChange={(e) =>
                toggle.mutate(
                  { activity: a, done: e.target.checked },
                  {
                    onSuccess: ({ dealWithoutNext }) => {
                      if (e.target.checked) toast.success('Atividade concluída')
                      if (dealWithoutNext) onDealWithoutNext?.(dealWithoutNext, a.deal?.title)
                    },
                    onError: toastError('Não foi possível atualizar'),
                  },
                )
              }
            />
            <div className="min-w-0 flex-1">
              <p className={cn('flex items-center gap-1.5 text-sm font-medium', done && 'text-muted-foreground line-through')}>
                <Icon className="size-3.5 shrink-0 text-muted-foreground" aria-label={ACTIVITY_TYPE_LABEL[a.type]} />
                <span className="truncate">{a.title}</span>
              </p>
              <p className="mt-0.5 flex flex-wrap items-center gap-x-3 gap-y-0.5 text-xs text-muted-foreground">
                {a.due_at && (
                  <span className={cn('flex items-center gap-1', overdue && 'font-semibold text-destructive')}>
                    <CalendarClock className="size-3" aria-hidden />
                    {formatDue(a.due_at)}
                    {overdue && ' · atrasada'}
                  </span>
                )}
                {showDeal && a.deal && (
                  <Link to={`/negocios/${a.deal.id}`} className="truncate underline-offset-4 hover:text-foreground hover:underline">
                    {a.deal.title}
                  </Link>
                )}
                {showDeal && !a.deal && a.company && <span className="truncate">{a.company.name}</span>}
                <span>{profileLabel(a.owner)}</span>
              </p>
              {a.description && <p className="mt-1 text-xs whitespace-pre-line text-foreground/80">{a.description}</p>}
            </div>
            <div className="flex shrink-0 gap-1">
              <Button variant="ghost" size="icon-sm" aria-label={`Editar ${a.title}`} title="Editar" onClick={() => onEdit(a)}>
                <Pencil aria-hidden />
              </Button>
              <ConfirmDelete
                compact
                label={`Excluir ${a.title}`}
                title="Excluir atividade?"
                description="Isso não pode ser desfeito."
                onConfirm={() =>
                  remove.mutateAsync(a.id, { onError: toastError('Não foi possível excluir') }).catch(() => undefined)
                }
              />
            </div>
          </li>
        )
      })}
    </ul>
  )
}
