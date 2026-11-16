import { useMemo, useState } from 'react'
import { Plus, Search } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { NativeSelect } from '@/components/form'
import { EmptyState, PageHeader, actionButtonClass } from '@/components/common'
import { LOCATION_STATUS_LABEL, options } from '@/lib/format'
import { friendlyError } from '@/lib/errors'
import { useLocations, type LocationListItem } from './api'
import { LocationFormDialog } from './LocationFormDialog'
import { LocationsTable } from './LocationsTable'

export function LocationsPage() {
  const { data, isLoading, error } = useLocations()
  const [search, setSearch] = useState('')
  const [status, setStatus] = useState('')
  const [editing, setEditing] = useState<LocationListItem | 'new' | null>(null)

  const rows = useMemo(() => {
    const term = search.trim().toLowerCase()
    return (data ?? []).filter(
      (l) =>
        (!status || l.status === status) &&
        (!term ||
          [l.name, l.company?.name, l.city].some((v) => (v ?? '').toLowerCase().includes(term))),
    )
  }, [data, search, status])

  const totalCourts = rows.reduce((acc, l) => acc + (l.court_count ?? 0), 0)

  return (
    <section>
      <PageHeader
        title="Locais"
        count={data?.length}
        actions={
          <Button className={actionButtonClass} onClick={() => setEditing('new')}>
            <Plus aria-hidden /> Novo local
          </Button>
        }
      />

      <div className="mb-4 flex flex-wrap items-center gap-2">
        <div className="relative min-w-56 flex-1 sm:max-w-sm">
          <Search className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" aria-hidden />
          <Input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Buscar por local, empresa ou cidade" className="bg-card pl-8" aria-label="Buscar locais" />
        </div>
        <NativeSelect value={status} onChange={(e) => setStatus(e.target.value)} className="w-auto bg-card" aria-label="Filtrar por status">
          <option value="">Todos os status</option>
          {options(LOCATION_STATUS_LABEL).map((o) => (
            <option key={o.value} value={o.value}>
              {o.label}
            </option>
          ))}
        </NativeSelect>
        {rows.length > 0 && (
          <p className="ml-auto text-sm text-muted-foreground">
            <span className="font-display text-xl text-primary">{totalCourts}</span> quadras
          </p>
        )}
      </div>

      {error ? (
        <EmptyState title="Erro ao carregar" description={friendlyError(error)} />
      ) : isLoading ? (
        <p className="text-sm text-muted-foreground">Carregando…</p>
      ) : rows.length === 0 ? (
        <EmptyState
          title={data?.length ? 'Nada encontrado' : 'Nenhum local ainda'}
          description={data?.length ? 'Ajuste a busca ou o filtro.' : 'Cadastre os parques e unidades de cada empresa.'}
        />
      ) : (
        <LocationsTable rows={rows} onEdit={setEditing} />
      )}

      <LocationFormDialog
        open={editing !== null}
        onOpenChange={(o) => !o && setEditing(null)}
        location={editing && editing !== 'new' ? editing : undefined}
      />
    </section>
  )
}
