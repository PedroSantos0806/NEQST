import { Link } from 'react-router-dom'
import { Pencil } from 'lucide-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { ConfirmDelete } from '@/components/common'
import { LOCATION_STATUS_LABEL } from '@/lib/format'
import { toastError } from '@/lib/errors'
import { useDeleteLocation, type LocationListItem } from './api'

const STATUS_CLASS: Record<LocationListItem['status'], string> = {
  prospect: 'bg-mist/20 text-ink',
  pilot: 'bg-ochre/25 text-ink',
  client: 'bg-sage/30 text-ink',
}

export function LocationsTable({
  rows,
  showCompany = true,
  onEdit,
}: {
  rows: LocationListItem[]
  showCompany?: boolean
  onEdit: (l: LocationListItem) => void
}) {
  const remove = useDeleteLocation()
  return (
    <div className="rounded-xl border border-border bg-card">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Local</TableHead>
            {showCompany && <TableHead>Empresa</TableHead>}
            <TableHead className="hidden md:table-cell">Cidade</TableHead>
            <TableHead className="text-right">Quadras</TableHead>
            <TableHead className="hidden lg:table-cell">Pisos</TableHead>
            <TableHead className="hidden sm:table-cell">Internet</TableHead>
            <TableHead>Status</TableHead>
            <TableHead className="w-20" />
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((l) => (
            <TableRow key={l.id}>
              <TableCell className="font-medium">{l.name}</TableCell>
              {showCompany && (
                <TableCell>
                  {l.company ? (
                    <Link to={`/empresas/${l.company.id}`} className="underline-offset-4 hover:underline">
                      {l.company.name}
                    </Link>
                  ) : (
                    '—'
                  )}
                </TableCell>
              )}
              <TableCell className="hidden text-muted-foreground md:table-cell">
                {[l.city, l.state].filter(Boolean).join(' / ') || '—'}
              </TableCell>
              <TableCell className="text-right font-display text-lg">{l.court_count ?? '—'}</TableCell>
              <TableCell className="hidden text-muted-foreground lg:table-cell">{l.surfaces.join(', ') || '—'}</TableCell>
              <TableCell className="hidden text-muted-foreground sm:table-cell">
                {l.has_internet == null ? '—' : l.has_internet ? 'Tem' : 'Não tem'}
              </TableCell>
              <TableCell>
                <Badge className={STATUS_CLASS[l.status]}>{LOCATION_STATUS_LABEL[l.status]}</Badge>
              </TableCell>
              <TableCell>
                <div className="flex justify-end gap-1">
                  <Button variant="ghost" size="icon-sm" aria-label={`Editar ${l.name}`} title="Editar" onClick={() => onEdit(l)}>
                    <Pencil aria-hidden />
                  </Button>
                  <ConfirmDelete
                    compact
                    label={`Excluir ${l.name}`}
                    title={`Excluir ${l.name}?`}
                    description="O local sai também dos negócios ligados a ele. Isso não pode ser desfeito."
                    onConfirm={() =>
                      remove.mutateAsync(l.id, {
                        onSuccess: () => toast.success('Local excluído'),
                        onError: toastError('Não foi possível excluir'),
                      }).catch(() => undefined)
                    }
                  />
                </div>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  )
}
