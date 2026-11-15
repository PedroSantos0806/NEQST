import { useCallback, useMemo, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useQueryClient } from '@tanstack/react-query'
import { Plus } from 'lucide-react'
import { toast } from 'sonner'
import { cn } from '@/lib/utils'
import { Button } from '@/components/ui/button'
import { EmptyState, actionButtonClass } from '@/components/common'
import { formatBRL } from '@/lib/format'
import { friendlyError, missingRequiredFields } from '@/lib/errors'
import { boardKey, useBoard, useMoveDeal, usePipelines, type BoardDeal } from './api'
import { Board, type MoveRequest } from './Board'
import { DealFormDialog } from './DealFormDialog'
import { LostDealDialog, WonDealDialog } from './CloseDealDialogs'
import type { CardActions } from './DealCard'
import { isStale } from './board-utils'
import { useBoardRealtime } from './useBoardRealtime'

type EditState = { dealId?: string; stageId?: string; missing?: string[] } | null

export function BoardPage() {
  const pipelines = usePipelines()
  const [params, setParams] = useSearchParams()
  const pipeline = useMemo(
    () => pipelines.data?.find((p) => p.id === params.get('funil')) ?? pipelines.data?.[0],
    [pipelines.data, params],
  )
  const board = useBoard(pipeline?.id)
  const move = useMoveDeal(pipeline?.id)
  const qc = useQueryClient()
  useBoardRealtime()

  const [editing, setEditing] = useState<EditState>(null)
  const [losing, setLosing] = useState<BoardDeal | null>(null)
  const [winning, setWinning] = useState<BoardDeal | null>(null)

  const isSales = pipeline?.type === 'sales'
  const actions = useMemo<CardActions>(
    () => ({
      onEdit: (d) => setEditing({ dealId: d.id }),
      onWon: isSales ? setWinning : undefined,
      onLost: isSales ? setLosing : undefined,
    }),
    [isSales],
  )

  const onMove = useCallback(
    ({ deal, stageId, position }: MoveRequest) => {
      if (!pipeline) return
      const key = boardKey(pipeline.id)
      // Update otimista síncrono (sem "pulo" do card ao soltar); rollback se o banco recusar.
      const previous = qc.getQueryData<BoardDeal[]>(key)
      void qc.cancelQueries({ queryKey: key })
      qc.setQueryData<BoardDeal[]>(key, (old) =>
        old
          ?.map((d) =>
            d.id === deal.id
              ? {
                  ...d,
                  stage_id: stageId,
                  position,
                  stage_entered_at: d.stage_id === stageId ? d.stage_entered_at : new Date().toISOString(),
                }
              : d,
          )
          .sort((a, b) => a.position - b.position),
      )
      move.mutate(
        { id: deal.id, stage_id: stageId, position },
        {
          onError: (err) => {
            if (previous) qc.setQueryData(key, previous)
            const missing = missingRequiredFields(err)
            if (missing) {
              toast.error('Faltam campos para avançar', { description: friendlyError(err) })
              setEditing({ dealId: deal.id, missing })
            } else {
              toast.error('Não foi possível mover o negócio', { description: friendlyError(err) })
            }
          },
        },
      )
    },
    [pipeline, qc, move],
  )

  if (pipelines.isLoading) return <p className="text-sm text-muted-foreground">Carregando…</p>
  if (pipelines.error) return <EmptyState title="Erro ao carregar" description={friendlyError(pipelines.error)} />
  if (!pipeline) return <EmptyState title="Nenhum funil configurado" />

  const deals = board.data ?? []
  const total = deals.reduce((acc, d) => acc + (d.value ?? 0), 0)
  const stageById = new Map(pipeline.stages.map((s) => [s.id, s]))
  const weighted = deals.reduce((acc, d) => acc + ((d.value ?? 0) * (stageById.get(d.stage_id)?.probability ?? 0)) / 100, 0)
  const stale = deals.filter((d) => isStale(d, stageById.get(d.stage_id))).length
  const withoutNext = deals.filter((d) => d.activities.length === 0).length

  return (
    <section className="flex flex-col gap-4">
      <header className="flex flex-wrap items-end justify-between gap-3">
        <h1 className="text-5xl leading-none text-primary">Funis</h1>
        <Button className={actionButtonClass} onClick={() => setEditing({})}>
          <Plus aria-hidden /> Novo negócio
        </Button>
      </header>

      <nav aria-label="Funis" className="flex flex-wrap gap-1.5">
        {pipelines.data?.map((p) => (
          <button
            key={p.id}
            type="button"
            aria-current={p.id === pipeline.id ? 'page' : undefined}
            onClick={() => setParams({ funil: p.id })}
            className={cn(
              'rounded-lg border px-3 py-1.5 text-sm font-medium transition-colors focus-visible:ring-3 focus-visible:ring-ring/50 focus-visible:outline-none',
              p.id === pipeline.id
                ? 'border-primary bg-primary text-primary-foreground'
                : 'border-border bg-card hover:bg-muted',
            )}
          >
            {p.name}
          </button>
        ))}
      </nav>

      <dl className="flex flex-wrap gap-x-8 gap-y-2">
        <Stat label="Negócios abertos" value={String(deals.length)} />
        <Stat label="Valor em aberto" value={formatBRL(total)} />
        {isSales && <Stat label="Previsão ponderada" value={formatBRL(weighted)} />}
        <Stat label="Parados" value={String(stale)} warn={stale > 0} />
        <Stat label="Sem próxima atividade" value={String(withoutNext)} warn={withoutNext > 0} />
      </dl>

      {board.error ? (
        <EmptyState title="Erro ao carregar o quadro" description={friendlyError(board.error)} />
      ) : board.isLoading ? (
        <p className="text-sm text-muted-foreground">Carregando…</p>
      ) : (
        <Board
          pipeline={pipeline}
          deals={deals}
          actions={actions}
          onMove={onMove}
          onAdd={(stageId) => setEditing({ stageId })}
        />
      )}

      <DealFormDialog
        open={editing !== null}
        onOpenChange={(o) => !o && setEditing(null)}
        pipeline={pipeline}
        dealId={editing?.dealId}
        stageId={editing?.stageId}
        missing={editing?.missing}
      />
      <LostDealDialog deal={losing} onClose={() => setLosing(null)} />
      <WonDealDialog deal={winning} onClose={() => setWinning(null)} />
    </section>
  )
}

function Stat({ label, value, warn }: { label: string; value: string; warn?: boolean }) {
  return (
    <div>
      <dt className="text-xs tracking-wide text-muted-foreground uppercase">{label}</dt>
      <dd className={cn('font-display text-3xl leading-none', warn ? 'text-[#8a5a1f]' : 'text-primary')}>{value}</dd>
    </div>
  )
}
