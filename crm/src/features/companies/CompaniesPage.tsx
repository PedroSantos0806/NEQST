import { useMemo, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Plus, Search } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Badge } from '@/components/ui/badge'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { NativeSelect } from '@/components/form'
import { EmptyState, PageHeader, actionButtonClass } from '@/components/common'
import { COMPANY_TYPE_LABEL, formatCnpj, options, profileLabel } from '@/lib/format'
import { friendlyError } from '@/lib/errors'
import { useCompanies } from './api'
import { CompanyFormDialog } from './CompanyFormDialog'

export function CompaniesPage() {
  const navigate = useNavigate()
  const { data, isLoading, error } = useCompanies()
  const [search, setSearch] = useState('')
  const [type, setType] = useState('')
  const [creating, setCreating] = useState(false)

  const rows = useMemo(() => {
    const term = search.trim().toLowerCase()
    return (data ?? []).filter(
      (c) =>
        (!type || c.type === type) &&
        (!term || c.name.toLowerCase().includes(term) || (c.cnpj ?? '').includes(term.replace(/\D/g, '') || '§')),
    )
  }, [data, search, type])

  return (
    <section>
      <PageHeader
        title="Empresas"
        count={data?.length}
        actions={
          <Button className={actionButtonClass} onClick={() => setCreating(true)}>
            <Plus aria-hidden /> Nova empresa
          </Button>
        }
      />

      <div className="mb-4 flex flex-wrap gap-2">
        <div className="relative min-w-56 flex-1 sm:max-w-sm">
          <Search className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" aria-hidden />
          <Input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Buscar por nome ou CNPJ" className="bg-card pl-8" aria-label="Buscar empresas" />
        </div>
        <NativeSelect value={type} onChange={(e) => setType(e.target.value)} className="w-auto bg-card" aria-label="Filtrar por tipo">
          <option value="">Todos os tipos</option>
          {options(COMPANY_TYPE_LABEL).map((o) => (
            <option key={o.value} value={o.value}>
              {o.label}
            </option>
          ))}
        </NativeSelect>
      </div>

      {error ? (
        <EmptyState title="Erro ao carregar" description={friendlyError(error)} />
      ) : isLoading ? (
        <p className="text-sm text-muted-foreground">Carregando…</p>
      ) : rows.length === 0 ? (
        <EmptyState
          title={data?.length ? 'Nada encontrado' : 'Nenhuma empresa ainda'}
          description={data?.length ? 'Ajuste a busca ou o filtro.' : 'Cadastre o primeiro operador, clube ou marca.'}
          action={
            !data?.length && (
              <Button className={actionButtonClass} onClick={() => setCreating(true)}>
                <Plus aria-hidden /> Nova empresa
              </Button>
            )
          }
        />
      ) : (
        <div className="rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Nome</TableHead>
                <TableHead>Tipo</TableHead>
                <TableHead className="hidden md:table-cell">CNPJ</TableHead>
                <TableHead className="text-right">Locais</TableHead>
                <TableHead className="text-right">Contatos</TableHead>
                <TableHead className="hidden lg:table-cell">Responsável</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((c) => (
                <TableRow
                  key={c.id}
                  className="cursor-pointer"
                  tabIndex={0}
                  onClick={() => navigate(`/empresas/${c.id}`)}
                  onKeyDown={(e) => e.key === 'Enter' && navigate(`/empresas/${c.id}`)}
                >
                  <TableCell className="font-medium">{c.name}</TableCell>
                  <TableCell>
                    <Badge variant="secondary">{COMPANY_TYPE_LABEL[c.type]}</Badge>
                  </TableCell>
                  <TableCell className="hidden text-muted-foreground md:table-cell">{formatCnpj(c.cnpj) || '—'}</TableCell>
                  <TableCell className="text-right font-display text-lg">{c.locations[0]?.count ?? 0}</TableCell>
                  <TableCell className="text-right font-display text-lg">{c.contacts[0]?.count ?? 0}</TableCell>
                  <TableCell className="hidden text-muted-foreground lg:table-cell">{profileLabel(c.owner)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}

      <CompanyFormDialog open={creating} onOpenChange={setCreating} onSaved={(c) => navigate(`/empresas/${c.id}`)} />
    </section>
  )
}
