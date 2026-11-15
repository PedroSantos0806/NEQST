import { useMemo, useRef, useState } from 'react'
import {
  DndContext,
  DragOverlay,
  KeyboardSensor,
  PointerSensor,
  closestCorners,
  useDroppable,
  useSensor,
  useSensors,
  type DragEndEvent,
  type DragOverEvent,
  type DragStartEvent,
} from '@dnd-kit/core'
import { SortableContext, arrayMove, sortableKeyboardCoordinates, useSortable, verticalListSortingStrategy } from '@dnd-kit/sortable'
import { CSS } from '@dnd-kit/utilities'
import { Plus } from 'lucide-react'
import { cn } from '@/lib/utils'
import { positionBetween, type BoardDeal, type Pipeline, type Stage } from './api'
import { DealCard, type CardActions } from './DealCard'
import { formatCompactBRL, groupByStage, isStale } from './board-utils'

export type MoveRequest = { deal: BoardDeal; stageId: string; position: number }

type Props = {
  pipeline: Pipeline
  deals: BoardDeal[]
  actions: CardActions
  onMove: (req: MoveRequest) => void
  onAdd: (stageId: string) => void
}

export function Board({ pipeline, deals, actions, onMove, onAdd }: Props) {
  const stages = pipeline.stages
  const dealsById = useMemo(() => new Map(deals.map((d) => [d.id, d])), [deals])
  const stageById = useMemo(() => new Map(stages.map((s) => [s.id, s])), [stages])
  const grouped = useMemo(() => groupByStage(deals, stages), [deals, stages])

  // Durante o arraste, a ordem vive aqui; fora dele, vem dos dados.
  const [dragItems, setDragItems] = useState<Record<string, string[]> | null>(null)
  const [activeId, setActiveId] = useState<string | null>(null)
  const items = dragItems ?? grouped

  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 6 } }),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }),
  )

  const findContainer = (id: string, source = items) =>
    id in source ? id : Object.keys(source).find((key) => source[key].includes(id))

  const onDragStart = ({ active }: DragStartEvent) => {
    setActiveId(String(active.id))
    setDragItems(grouped)
  }

  const onDragOver = ({ active, over }: DragOverEvent) => {
    if (!over) return
    const activeKey = String(active.id)
    const overKey = String(over.id)
    setDragItems((prev) => {
      const current = prev ?? grouped
      const from = findContainer(activeKey, current)
      const to = findContainer(overKey, current)
      if (!from || !to || from === to) return current
      const toItems = current[to]
      const overIndex = overKey in current ? toItems.length : toItems.indexOf(overKey)
      return {
        ...current,
        [from]: current[from].filter((id) => id !== activeKey),
        [to]: [...toItems.slice(0, overIndex), activeKey, ...toItems.slice(overIndex)],
      }
    })
  }

  const reset = () => {
    lastDragEnd.current = Date.now()
    setActiveId(null)
    setDragItems(null)
  }

  const onDragEnd = ({ active, over }: DragEndEvent) => {
    const current = dragItems ?? grouped
    const activeKey = String(active.id)
    const deal = dealsById.get(activeKey)
    const to = over ? findContainer(String(over.id), current) : undefined
    if (!deal || !to) return reset()

    let list = current[to]
    const oldIndex = list.indexOf(activeKey)
    const overKey = String(over!.id)
    const newIndex = overKey in current ? list.length - 1 : list.indexOf(overKey)
    if (oldIndex !== -1 && newIndex !== -1 && oldIndex !== newIndex) list = arrayMove(list, oldIndex, newIndex)

    const index = list.indexOf(activeKey)
    const unchanged = deal.stage_id === to && grouped[to]?.indexOf(activeKey) === index
    if (unchanged) return reset()

    const before = list[index - 1] ? dealsById.get(list[index - 1])?.position : undefined
    const after = list[index + 1] ? dealsById.get(list[index + 1])?.position : undefined
    onMove({ deal, stageId: to, position: positionBetween(before, after) })
    reset()
  }

  // Soltar um card dispara um "click" nele: ignora cliques logo após um arraste.
  const lastDragEnd = useRef(0)
  const cardActions = useMemo<CardActions>(
    () => ({
      ...actions,
      onOpen: (deal) => {
        if (Date.now() - lastDragEnd.current > 250) actions.onOpen(deal)
      },
    }),
    [actions],
  )

  const activeDeal = activeId ? dealsById.get(activeId) : undefined

  return (
    <DndContext
      sensors={sensors}
      collisionDetection={closestCorners}
      onDragStart={onDragStart}
      onDragOver={onDragOver}
      onDragEnd={onDragEnd}
      onDragCancel={reset}
      accessibility={{
        screenReaderInstructions: {
          draggable: 'Para mover um negócio, pressione espaço, use as setas e pressione espaço de novo para soltar. Esc cancela.',
        },
      }}
    >
      <div className="-mx-4 flex min-h-[60svh] gap-3 overflow-x-auto px-4 pb-4 md:-mx-8 md:px-8">
        {stages.map((stage) => (
          <Column
            key={stage.id}
            stage={stage}
            ids={items[stage.id] ?? []}
            dealsById={dealsById}
            actions={cardActions}
            onAdd={() => onAdd(stage.id)}
            showProbability={pipeline.type === 'sales'}
          />
        ))}
      </div>
      <DragOverlay dropAnimation={null}>
        {activeDeal ? <DealCard deal={activeDeal} stage={stageById.get(activeDeal.stage_id)} overlay /> : null}
      </DragOverlay>
    </DndContext>
  )
}

function Column({
  stage,
  ids,
  dealsById,
  actions,
  onAdd,
  showProbability,
}: {
  stage: Stage
  ids: string[]
  dealsById: Map<string, BoardDeal>
  actions: CardActions
  onAdd: () => void
  showProbability: boolean
}) {
  const { setNodeRef, isOver } = useDroppable({ id: stage.id })
  const deals = ids.map((id) => dealsById.get(id)).filter(Boolean) as BoardDeal[]
  const total = deals.reduce((acc, d) => acc + (d.value ?? 0), 0)
  const staleCount = deals.filter((d) => isStale(d, stage)).length

  return (
    <section aria-label={stage.name} className="flex w-72 shrink-0 flex-col rounded-xl bg-secondary/60">
      <header className="flex flex-col gap-1 border-b border-border/70 px-3 pt-3 pb-2" title={stage.exit_criteria ?? undefined}>
        <div className="flex items-center justify-between gap-2">
          <h2 className="truncate text-xl leading-none text-primary">{stage.name}</h2>
          <button
            type="button"
            onClick={onAdd}
            className="grid size-6 place-items-center rounded-md text-muted-foreground hover:bg-muted hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring focus-visible:outline-none"
            aria-label={`Novo negócio em ${stage.name}`}
          >
            <Plus className="size-4" aria-hidden />
          </button>
        </div>
        <div className="flex items-baseline justify-between gap-2">
          <span className="font-display text-2xl leading-none">
            {deals.length}
            <span className="ml-2 text-lg text-accent">{formatCompactBRL(total)}</span>
          </span>
          <span className="text-xs text-muted-foreground">
            {staleCount > 0 && <span className="mr-2 font-semibold text-[#8a5a1f]">{staleCount} parado{staleCount > 1 ? 's' : ''}</span>}
            {showProbability && stage.probability != null && `${stage.probability}%`}
          </span>
        </div>
      </header>
      <SortableContext id={stage.id} items={ids} strategy={verticalListSortingStrategy}>
        <div
          ref={setNodeRef}
          className={cn('flex min-h-24 flex-1 flex-col gap-2 p-2 transition-colors', isOver && 'bg-accent/10')}
        >
          {deals.map((deal) => (
            <SortableCard key={deal.id} deal={deal} stage={stage} actions={actions} />
          ))}
          {deals.length === 0 && (
            <p className="px-2 py-6 text-center text-xs text-muted-foreground">Arraste um negócio para cá</p>
          )}
        </div>
      </SortableContext>
    </section>
  )
}

function SortableCard({ deal, stage, actions }: { deal: BoardDeal; stage: Stage; actions: CardActions }) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({ id: deal.id })
  return (
    <DealCard
      ref={setNodeRef}
      deal={deal}
      stage={stage}
      actions={actions}
      dragging={isDragging}
      style={{ transform: CSS.Transform.toString(transform), transition }}
      onClick={() => actions.onOpen(deal)}
      onKeyDown={(e) => {
        if (e.key === 'Enter') actions.onOpen(deal)
        listeners?.onKeyDown?.(e)
      }}
      {...attributes}
      {...Object.fromEntries(Object.entries(listeners ?? {}).filter(([k]) => k !== 'onKeyDown'))}
    />
  )
}
