import { forwardRef, type HTMLAttributes } from 'react'
import { AlarmClock, CalendarClock, CircleAlert, MapPin, MoreHorizontal } from 'lucide-react'
import { cn } from '@/lib/utils'
import { formatBRL, profileLabel } from '@/lib/format'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import type { BoardDeal, Stage } from './api'
import { daysInStage, formatShortDate, isOverdue, isStale, nextActivity } from './board-utils'

export type CardActions = {
  /** Clique no card: abre a ficha. */
  onOpen: (deal: BoardDeal) => void
  onEdit: (deal: BoardDeal) => void
  onWon?: (deal: BoardDeal) => void
  onLost?: (deal: BoardDeal) => void
}

type Props = HTMLAttributes<HTMLDivElement> & {
  deal: BoardDeal
  stage: Stage | undefined
  actions?: CardActions
  dragging?: boolean
  overlay?: boolean
}

function initials(text: string) {
  return text
    .split(/[\s@.]+/)
    .filter(Boolean)
    .slice(0, 2)
    .map((p) => p[0]?.toUpperCase())
    .join('')
}

export const DealCard = forwardRef<HTMLDivElement, Props>(function DealCard(
  { deal, stage, actions, dragging, overlay, className, ...props },
  ref,
) {
  const stale = isStale(deal, stage)
  const days = daysInStage(deal)
  const next = nextActivity(deal)
  const locations = deal.deal_locations.map((l) => l.location?.name).filter(Boolean) as string[]
  const owner = profileLabel(deal.owner)

  return (
    <div
      ref={ref}
      {...props}
      className={cn(
        'group relative flex touch-none flex-col gap-2 rounded-lg border bg-card p-3 text-left text-sm outline-none select-none',
        'cursor-grab focus-visible:ring-3 focus-visible:ring-ring/50 active:cursor-grabbing',
        stale ? 'border-ochre bg-[#f7ece0]' : 'border-border',
        dragging && 'opacity-40',
        overlay && 'rotate-1 shadow-md',
        className,
      )}
      data-stale={stale || undefined}
    >
      <div className="flex items-start gap-2">
        <p className="min-w-0 flex-1 leading-snug font-semibold">{deal.title}</p>
        {actions && (
          // Eventos do menu (inclusive do portal) não podem chegar ao card, que abre a edição no clique.
          <span onClick={(e) => e.stopPropagation()} onKeyDown={(e) => e.stopPropagation()} onPointerDown={(e) => e.stopPropagation()}>
          <DropdownMenu>
            <DropdownMenuTrigger
              aria-label={`Ações de ${deal.title}`}
              className="-mt-1 -mr-1 rounded-md p-1 text-muted-foreground opacity-70 outline-none hover:bg-muted hover:opacity-100 focus-visible:ring-2 focus-visible:ring-ring"
            >
              <MoreHorizontal className="size-4" aria-hidden />
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" className="min-w-40">
              <DropdownMenuItem onClick={() => actions.onOpen(deal)}>Abrir ficha</DropdownMenuItem>
              <DropdownMenuItem onClick={() => actions.onEdit(deal)}>Editar</DropdownMenuItem>
              {(actions.onWon || actions.onLost) && <DropdownMenuSeparator />}
              {actions.onWon && <DropdownMenuItem onClick={() => actions.onWon?.(deal)}>Marcar como ganho</DropdownMenuItem>}
              {actions.onLost && (
                <DropdownMenuItem variant="destructive" onClick={() => actions.onLost?.(deal)}>
                  Marcar como perdido
                </DropdownMenuItem>
              )}
            </DropdownMenuContent>
          </DropdownMenu>
          </span>
        )}
      </div>

      {(deal.company || locations.length > 0) && (
        <div className="flex flex-col gap-0.5 text-xs text-muted-foreground">
          {deal.company && <span className="font-medium text-foreground/80">{deal.company.name}</span>}
          {locations.length > 0 && (
            <span className="flex items-center gap-1">
              <MapPin className="size-3 shrink-0" aria-hidden />
              <span className="truncate">{locations.join(', ')}</span>
            </span>
          )}
        </div>
      )}

      <div className="flex items-end justify-between gap-2">
        <span className="font-display text-2xl leading-none text-primary">{deal.value != null ? formatBRL(deal.value) : '—'}</span>
        {deal.court_count != null && (
          <span className="text-xs text-muted-foreground">
            <span className="font-display text-base text-foreground">{deal.court_count}</span> quadras
          </span>
        )}
      </div>

      {next ? (
        <p
          className={cn(
            'flex items-center gap-1 text-xs',
            isOverdue(next.due_at) ? 'font-medium text-destructive' : 'text-muted-foreground',
          )}
        >
          <CalendarClock className="size-3 shrink-0" aria-hidden />
          <span className="truncate">
            {next.due_at ? `${formatShortDate(next.due_at)} · ` : ''}
            {next.title}
          </span>
        </p>
      ) : (
        <p className="flex items-center gap-1 text-xs font-medium text-destructive">
          <CircleAlert className="size-3 shrink-0" aria-hidden /> Sem próxima atividade
        </p>
      )}

      <div className="flex items-center justify-between gap-2 border-t border-border/70 pt-2 text-xs">
        <span
          className={cn('flex items-center gap-1', stale ? 'font-semibold text-[#8a5a1f]' : 'text-muted-foreground')}
          title={stage?.alert_days ? `Alerta após ${stage.alert_days} dias na etapa` : undefined}
        >
          <AlarmClock className="size-3" aria-hidden />
          {days} {days === 1 ? 'dia' : 'dias'} na etapa{stale && ' · parado'}
        </span>
        {deal.owner && (
          <span
            className="grid size-6 place-items-center rounded-full bg-primary text-[10px] font-semibold text-primary-foreground"
            title={owner}
            aria-label={`Responsável: ${owner}`}
          >
            {initials(owner)}
          </span>
        )}
      </div>
    </div>
  )
})
