import { Link } from 'react-router-dom'
import { Pencil } from 'lucide-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { ConfirmDelete } from '@/components/common'
import { LIFECYCLE_LABEL, formatPhone, profileLabel } from '@/lib/format'
import { toastError } from '@/lib/errors'
import { useDeleteContact, type ContactListItem } from './api'

export function ContactsTable({
  rows,
  showCompany = true,
  onEdit,
}: {
  rows: ContactListItem[]
  showCompany?: boolean
  onEdit: (c: ContactListItem) => void
}) {
  const remove = useDeleteContact()
  return (
    <div className="rounded-xl border border-border bg-card">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Nome</TableHead>
            {showCompany && <TableHead>Empresa</TableHead>}
            <TableHead className="hidden md:table-cell">Cargo</TableHead>
            <TableHead className="hidden lg:table-cell">E-mail</TableHead>
            <TableHead className="hidden sm:table-cell">Telefone</TableHead>
            <TableHead>Estágio</TableHead>
            <TableHead className="hidden xl:table-cell">Responsável</TableHead>
            <TableHead className="w-20" />
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((c) => (
            <TableRow key={c.id}>
              <TableCell className="font-medium">
                <Link to={`/contatos/${c.id}`} className="underline-offset-4 hover:underline">
                  {c.name}
                </Link>
              </TableCell>
              {showCompany && (
                <TableCell>
                  {c.company ? (
                    <Link to={`/empresas/${c.company.id}`} className="underline-offset-4 hover:underline">
                      {c.company.name}
                    </Link>
                  ) : (
                    '—'
                  )}
                </TableCell>
              )}
              <TableCell className="hidden text-muted-foreground md:table-cell">{c.job_title ?? '—'}</TableCell>
              <TableCell className="hidden text-muted-foreground lg:table-cell">
                {c.email ? (
                  <a href={`mailto:${c.email}`} className="underline-offset-4 hover:underline">
                    {c.email}
                  </a>
                ) : (
                  '—'
                )}
              </TableCell>
              <TableCell className="hidden text-muted-foreground sm:table-cell">{formatPhone(c.phone) || '—'}</TableCell>
              <TableCell>
                <Badge variant="secondary">{LIFECYCLE_LABEL[c.lifecycle_stage]}</Badge>
              </TableCell>
              <TableCell className="hidden text-muted-foreground xl:table-cell">{profileLabel(c.owner)}</TableCell>
              <TableCell>
                <div className="flex justify-end gap-1">
                  <Button variant="ghost" size="icon-sm" aria-label={`Editar ${c.name}`} title="Editar" onClick={() => onEdit(c)}>
                    <Pencil aria-hidden />
                  </Button>
                  <ConfirmDelete
                    compact
                    label={`Excluir ${c.name}`}
                    title={`Excluir ${c.name}?`}
                    description="O contato sai também dos negócios e perde as notas ligadas a ele. Isso não pode ser desfeito."
                    onConfirm={() =>
                      remove.mutateAsync(c.id, {
                        onSuccess: () => toast.success('Contato excluído'),
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
