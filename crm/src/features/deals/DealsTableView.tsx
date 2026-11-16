import { useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Search } from 'lucide-react'
import { cn } from '@/lib/utils'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { NativeSelect } from '@/components/form'
import { EmptyState } from '@/components/common'
import { formatBRL, profileLabel } from '@/lib/format'
import { friendlyError } from '@/lib/errors'
import { useProfiles } from '@/features/team/api'
import type { Enums } from '@/types/database'
import { useDealsTable, type Pipeline } from './api'
import { daysInStage, formatShortDate, isOverdue, isStale } from './board-utils'

const STATUS_LABEL: Record<Enums<'deal_status'>, string> = { open: 'Aberto', won: 'Ganho', lost: 'Perdido' }

export function DealsTableView({ pipeline }: { pipeline: Pipeline }) {
  const navigate = useNavigate()
  const profiles = useProfiles()
  const [status, setStatus] = useState<Enums<'deal_status'> | 'all'>('open')
  const [stageId, setStageId] = useState('')
  const [ownerId, setOwnerId] = useState('')
  const [flag, setFlag] = useState<'' | 'stale' | 'no-next'>('')
  const [search, setSearch] = useState('')
  const deals = useDealsTable(pipeline.id, status)
  const stageById = useMemo(() => new Map(pipeline.stages.map((s) => [s.id, s])), [pipeline.stages])

  const rows = useMemo(() => {
    const term = search.trim().toLowerCase()
    return (deals.data ?? []).filter((d) => {
      if (stageId && d.stage_id !== stageId) return false
      if (ownerId && d.owner_id !== ownerId) return false
      if (flag === 'stale' && !(d.status === 'open' && isStale(d, stageById.get(d.stage_id)))) return false
      if (flag === 'no-next' && !(d.status === 'open' && d.activities.length === 0)) return false
      if (term && ![d.title, d.company?.name].some((v) => (v ?? '').toLowerCase().includes(term))) return false
      return true
    })
  }, [deals.data, stageId, ownerId, flag, search, stageById])

  const total = rows.reduce((acc, d) => acc + (d.value ?? 0), 0)

  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-wrap items-center gap-2">
        <div className="relative min-w-52 flex-1 sm:max-w-xs">
          <Search className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" aria-hidden />
          <Input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Buscar negócio ou empresa" className="bg-card pl-8" aria-label="Buscar negócios" />
        </div>
        <NativeSelect value={status} onChange={(e) => setStatus(e.target.value as typeof status)} className="w-auto bg-card" aria-label="Situação">
          <option value="open">Abertos</option>
          <option value="won">Ganhos</option>
          <option value="lost">Perdidos</option>
          <option value="all">Todos</option>
        </NativeSelect>
        <NativeSelect value={stageId} onChange={(e) => setStageId(e.target.value)} className="w-auto bg-card" aria-label="Etapa">
          <option value="">Todas as etapas</option>
          {pipeline.stages.map((s) => (
            <option key={s.id} value={s.id}>
              {s.name}
            </option>
          ))}
        </NativeSelect>
        <NativeSelect value={ownerId} onChange={(e) => setOwnerId(e.target.value)} className="w-auto bg-card" aria-label="Responsável">
          <option value="">Todos os responsáveis</option>
          {profiles.data?.map((p) => (
            <option key={p.id} value={p.id}>
              {profileLabel(p)}
            </option>
          ))}
        </NativeSelect>
        <NativeSelect value={flag} onChange={(e) => setFlag(e.target.value as typeof flag)} className="w-auto bg-card" aria-label="Alertas">
          <option value="">Sem filtro de alerta</option>
          <option value="stale">Só parados</option>
          <option value="no-next">Só sem próxima atividade</option>
        </NativeSelect>
        <p className="ml-auto text-sm text-muted-foreground">
          <span className="font-display text-xl text-primary">{rows.length}</span> negócios ·{' '}
          <span className="font-display text-xl text-primary">{formatBRL(total)}</span>
        </p>
      </div>

      {deals.error ? (
        <EmptyState title="Erro ao carregar" description={friendlyError(deals.error)} />
      ) : deals.isLoading ? (
        <p className="text-sm text-muted-foreground">Carregando…</p>
      ) : rows.length === 0 ? (
        <EmptyState title="Nenhum negócio" description="Ajuste os filtros ou crie um negócio." />
      ) : (
        <div className="rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Negócio</TableHead>
                <TableHead>Etapa</TableHead>
                <TableHead className="text-right">Valor</TableHead>
                <TableHead className="hidden text-right md:table-cell">Quadras</TableHead>
                <TableHead className="hidden lg:table-cell">Responsável</TableHead>
                <TableHead className="text-right">Dias</TableHead>
                <TableHead>Próxima atividade</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((d) => {
                const stage = stageById.get(d.stage_id)
                const stale = d.status === 'open' && isStale(d, stage)
                const next = d.activities[0]
                return (
                  <TableRow
                    key={d.id}
                    tabIndex={0}
                    className="cursor-pointer"
                    onClick={() => navigate(`/negocios/${d.id}`)}
                    onKeyDown={(e) => e.key === 'Enter' && navigate(`/negocios/${d.id}`)}
                  >
                    <TableCell>
                      <span className="font-medium">{d.title}</span>
                      {d.company && <span className="block text-xs text-muted-foreground">{d.company.name}</span>}
                    </TableCell>
                    <TableCell>
                      {stage?.name}
                      {d.status !== 'open' && (
                        <Badge variant="secondary" className="ml-2">
                          {STATUS_LABEL[d.status]}
                        </Badge>
                      )}
                    </TableCell>
                    <TableCell className="text-right font-display text-lg">{d.value != null ? formatBRL(d.value) : '—'}</TableCell>
                    <TableCell className="hidden text-right md:table-cell">{d.court_count ?? '—'}</TableCell>
                    <TableCell className="hidden text-muted-foreground lg:table-cell">{profileLabel(d.owner)}</TableCell>
                    <TableCell className={cn('text-right', stale && 'font-semibold text-[#8a5a1f]')}>
                      {d.status === 'open' ? daysInStage(d) : '—'}
                    </TableCell>
                    <TableCell className="max-w-56">
                      {d.status !== 'open' ? (
                        <span className="text-muted-foreground">—</span>
                      ) : next ? (
                        <span className={cn('block truncate text-xs', isOverdue(next.due_at) && 'font-semibold text-destructive')}>
                          {next.due_at && `${formatShortDate(next.due_at)} · `}
                          {next.title}
                        </span>
                      ) : (
                        <span className="text-xs font-semibold text-destructive">Sem próxima atividade</span>
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
  )
}
