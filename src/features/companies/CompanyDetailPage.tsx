import { useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { ArrowLeft, ExternalLink, Pencil, Plus } from 'lucide-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { ConfirmDelete, EmptyState, actionButtonClass } from '@/components/common'
import { COMPANY_TYPE_LABEL, formatCnpj, profileLabel } from '@/lib/format'
import { friendlyError, toastError } from '@/lib/errors'
import { useLocations, type LocationListItem } from '@/features/locations/api'
import { LocationsTable } from '@/features/locations/LocationsTable'
import { LocationFormDialog } from '@/features/locations/LocationFormDialog'
import { useContacts, type ContactListItem } from '@/features/contacts/api'
import { ContactsTable } from '@/features/contacts/ContactsTable'
import { ContactFormDialog } from '@/features/contacts/ContactFormDialog'
import { useCompany, useDeleteCompany } from './api'
import { CompanyFormDialog } from './CompanyFormDialog'

export function CompanyDetailPage() {
  const { id } = useParams<{ id: string }>()
  const navigate = useNavigate()
  const company = useCompany(id)
  const locations = useLocations({ companyId: id })
  const contacts = useContacts({ companyId: id })
  const remove = useDeleteCompany()

  const [editingCompany, setEditingCompany] = useState(false)
  const [editingLocation, setEditingLocation] = useState<LocationListItem | 'new' | null>(null)
  const [editingContact, setEditingContact] = useState<ContactListItem | 'new' | null>(null)

  if (company.isLoading) return <p className="text-sm text-muted-foreground">Carregando…</p>
  if (company.error) return <EmptyState title="Erro ao carregar" description={friendlyError(company.error)} />
  if (!company.data) {
    return (
      <EmptyState
        title="Empresa não encontrada"
        action={
          <Button variant="outline" onClick={() => navigate('/empresas')}>
            Voltar para empresas
          </Button>
        }
      />
    )
  }

  const c = company.data
  const courts = (locations.data ?? []).reduce((acc, l) => acc + (l.court_count ?? 0), 0)

  return (
    <section className="flex flex-col gap-8">
      <div>
        <Link to="/empresas" className="mb-3 inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground">
          <ArrowLeft className="size-4" aria-hidden /> Empresas
        </Link>
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h1 className="text-5xl leading-none text-primary">{c.name}</h1>
            <div className="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-muted-foreground">
              <Badge variant="secondary">{COMPANY_TYPE_LABEL[c.type]}</Badge>
              {c.cnpj && <span>CNPJ {formatCnpj(c.cnpj)}</span>}
              {c.website && (
                <a href={c.website} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1 hover:text-foreground">
                  {c.website.replace(/^https?:\/\//, '')} <ExternalLink className="size-3" aria-hidden />
                </a>
              )}
              <span>Responsável: {profileLabel(c.owner)}</span>
            </div>
          </div>
          <div className="flex gap-2">
            <Button variant="outline" onClick={() => setEditingCompany(true)}>
              <Pencil aria-hidden /> Editar
            </Button>
            <ConfirmDelete
              title={`Excluir ${c.name}?`}
              description="Os locais da empresa também serão excluídos. Contatos e negócios ficam, mas sem empresa. Isso não pode ser desfeito."
              onConfirm={() =>
                remove
                  .mutateAsync(c.id, {
                    onSuccess: () => {
                      toast.success('Empresa excluída')
                      navigate('/empresas')
                    },
                    onError: toastError('Não foi possível excluir'),
                  })
                  .catch(() => undefined)
              }
            />
          </div>
        </div>

        <dl className="mt-6 grid max-w-xl grid-cols-3 gap-3">
          {[
            ['Locais', locations.data?.length ?? 0],
            ['Quadras', courts],
            ['Contatos', contacts.data?.length ?? 0],
          ].map(([label, value]) => (
            <div key={label} className="rounded-xl border border-border bg-card px-4 py-3">
              <dt className="text-xs tracking-wide text-muted-foreground uppercase">{label}</dt>
              <dd className="font-display text-4xl leading-none text-primary">{value}</dd>
            </div>
          ))}
        </dl>
      </div>

      <div>
        <div className="mb-3 flex items-center justify-between gap-2">
          <h2 className="text-3xl text-primary">Locais</h2>
          <Button className={actionButtonClass} onClick={() => setEditingLocation('new')}>
            <Plus aria-hidden /> Novo local
          </Button>
        </div>
        {locations.data?.length ? (
          <LocationsTable rows={locations.data} showCompany={false} onEdit={setEditingLocation} />
        ) : (
          <EmptyState title="Nenhum local" description="Cadastre os parques ou unidades desta empresa." />
        )}
      </div>

      <div>
        <div className="mb-3 flex items-center justify-between gap-2">
          <h2 className="text-3xl text-primary">Contatos</h2>
          <Button className={actionButtonClass} onClick={() => setEditingContact('new')}>
            <Plus aria-hidden /> Novo contato
          </Button>
        </div>
        {contacts.data?.length ? (
          <ContactsTable rows={contacts.data} showCompany={false} onEdit={setEditingContact} />
        ) : (
          <EmptyState title="Nenhum contato" description="Cadastre o decisor e as pessoas de contato." />
        )}
      </div>

      <CompanyFormDialog open={editingCompany} onOpenChange={setEditingCompany} company={c} />
      <LocationFormDialog
        open={editingLocation !== null}
        onOpenChange={(o) => !o && setEditingLocation(null)}
        location={editingLocation && editingLocation !== 'new' ? editingLocation : undefined}
        companyId={c.id}
      />
      <ContactFormDialog
        open={editingContact !== null}
        onOpenChange={(o) => !o && setEditingContact(null)}
        contact={editingContact && editingContact !== 'new' ? editingContact : undefined}
        companyId={c.id}
      />
    </section>
  )
}
