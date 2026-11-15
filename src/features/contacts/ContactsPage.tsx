import { useMemo, useState } from 'react'
import { Plus, Search } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { NativeSelect } from '@/components/form'
import { EmptyState, PageHeader, actionButtonClass } from '@/components/common'
import { LIFECYCLE_LABEL, options } from '@/lib/format'
import { friendlyError } from '@/lib/errors'
import { useContacts, type ContactListItem } from './api'
import { ContactFormDialog } from './ContactFormDialog'
import { ContactsTable } from './ContactsTable'

export function ContactsPage() {
  const { data, isLoading, error } = useContacts()
  const [search, setSearch] = useState('')
  const [stage, setStage] = useState('')
  const [editing, setEditing] = useState<ContactListItem | 'new' | null>(null)

  const rows = useMemo(() => {
    const term = search.trim().toLowerCase()
    const digits = term.replace(/\D/g, '')
    return (data ?? []).filter(
      (c) =>
        (!stage || c.lifecycle_stage === stage) &&
        (!term ||
          [c.name, c.email, c.company?.name, c.job_title].some((v) => (v ?? '').toLowerCase().includes(term)) ||
          (digits.length >= 4 && (c.phone ?? '').includes(digits))),
    )
  }, [data, search, stage])

  return (
    <section>
      <PageHeader
        title="Contatos"
        count={data?.length}
        actions={
          <Button className={actionButtonClass} onClick={() => setEditing('new')}>
            <Plus aria-hidden /> Novo contato
          </Button>
        }
      />

      <div className="mb-4 flex flex-wrap gap-2">
        <div className="relative min-w-56 flex-1 sm:max-w-sm">
          <Search className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" aria-hidden />
          <Input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Buscar por nome, e-mail, telefone ou empresa" className="bg-card pl-8" aria-label="Buscar contatos" />
        </div>
        <NativeSelect value={stage} onChange={(e) => setStage(e.target.value)} className="w-auto bg-card" aria-label="Filtrar por estágio">
          <option value="">Todos os estágios</option>
          {options(LIFECYCLE_LABEL).map((o) => (
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
          title={data?.length ? 'Nada encontrado' : 'Nenhum contato ainda'}
          description={data?.length ? 'Ajuste a busca ou o filtro.' : 'Cadastre decisores e contatos das empresas.'}
        />
      ) : (
        <ContactsTable rows={rows} onEdit={setEditing} />
      )}

      <ContactFormDialog
        open={editing !== null}
        onOpenChange={(o) => !o && setEditing(null)}
        contact={editing && editing !== 'new' ? editing : undefined}
      />
    </section>
  )
}
