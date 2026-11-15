import type { BoardDeal, Stage } from './api'

const DAY = 86_400_000

export function daysInStage(deal: Pick<BoardDeal, 'stage_entered_at'>, now = Date.now()) {
  return Math.max(0, Math.floor((now - new Date(deal.stage_entered_at).getTime()) / DAY))
}

/** Parado: now() - stage_entered_at > stages.alert_days */
export function isStale(deal: Pick<BoardDeal, 'stage_entered_at'>, stage: Pick<Stage, 'alert_days'> | undefined, now = Date.now()) {
  if (!stage?.alert_days) return false
  return now - new Date(deal.stage_entered_at).getTime() > stage.alert_days * DAY
}

export function nextActivity(deal: Pick<BoardDeal, 'activities'>) {
  return deal.activities[0] ?? null
}

export function isOverdue(dueAt: string | null, now = Date.now()) {
  return !!dueAt && new Date(dueAt).getTime() < now
}

const shortDate = new Intl.DateTimeFormat('pt-BR', { day: '2-digit', month: 'short' })
export const formatShortDate = (iso: string) => shortDate.format(new Date(iso)).replace('.', '')

const compactBrl = new Intl.NumberFormat('pt-BR', {
  style: 'currency',
  currency: 'BRL',
  notation: 'compact',
  maximumFractionDigits: 1,
})
export const formatCompactBRL = (n: number) => compactBrl.format(n)

/** Agrupa ids por etapa, ordenados pela posição. */
export function groupByStage(deals: BoardDeal[], stages: Stage[]) {
  const groups: Record<string, string[]> = Object.fromEntries(stages.map((s) => [s.id, []]))
  for (const d of [...deals].sort((a, b) => a.position - b.position)) {
    groups[d.stage_id]?.push(d.id)
  }
  return groups
}
