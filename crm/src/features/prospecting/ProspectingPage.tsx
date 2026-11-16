import { useMemo, useState } from 'react'
import { useForm, useWatch } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { toast } from 'sonner'
import { FileUp, Plus, Search, Star } from 'lucide-react'
import { cn } from '@/lib/utils'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Field, NativeSelect } from '@/components/form'
import { EmptyState, PageHeader, actionButtonClass } from '@/components/common'
import { COMPANY_TYPE_LABEL, options } from '@/lib/format'
import { friendlyError } from '@/lib/errors'
import {
  PROSPECT_STATUS_LABEL,
  useProspectSearch,
  useProspects,
  useProspectsRealtime,
  type ProspectListItem,
  scoreClass,
  type ProspectStatus,
} from './api'
import { ProspectPanel } from './ProspectPanel'
import { AddProspectDialog, ImportProspectsDialog } from './ProspectDialogs'

const QUERY_HINT: Record<string, string> = {
  public_operator: 'parque com quadras de beach tennis',
  club: 'clube com quadra de beach tennis',
  condo: 'condomínio com quadra de beach tennis',
  builder: 'lançamento imobiliário com quadra de beach tennis',
  brand: 'loja de artigos esportivos',
}

const schema = z.object({
  company_type: z.string(),
  query: z.string().trim().min(3, 'O que buscar (mín. 3 letras)'),
  city: z
    .string()
    .trim()
    .refine((v) => /^[^,]{2,},\s*[A-Za-z]{2}$/.test(v), 'Cidade e UF, ex.: Campinas, SP'),
})
type FormValues = z.infer<typeof schema>

type Tab = 'queue' | 'qualified' | 'discarded' | 'all'
const TAB_STATUSES: Record<Tab, ProspectStatus[] | null> = {
  queue: ['new', 'researching', 'researched'],
  qualified: ['qualified'],
  discarded: ['discarded'],
  all: null,
}
const TAB_LABEL: Record<Tab, string> = { queue: 'Fila', qualified: 'Qualificados', discarded: 'Descartados', all: 'Todos' }


export function ProspectingPage() {
  const prospects = useProspects()
  const [status, setStatus] = useState<string | null>(null)
  const search = useProspectSearch(setStatus)
  const [adding, setAdding] = useState(false)
  const [importing, setImporting] = useState(false)
  useProspectsRealtime()
  const [tab, setTab] = useState<Tab>('queue')
  const [filter, setFilter] = useState('')
  const [selectedId, setSelectedId] = useState<string | null>(null)

  const {
    register,
    handleSubmit,
    control,
    formState: { errors },
  } = useForm<FormValues>({ resolver: zodResolver(schema), defaultValues: { company_type: 'club', query: '', city: '' } })
  const type = useWatch({ control, name: 'company_type' })

  const counts = useMemo(() => {
    const c: Record<Tab, number> = { queue: 0, qualified: 0, discarded: 0, all: 0 }
    for (const p of prospects.data ?? []) {
      c.all++
      for (const t of ['queue', 'qualified', 'discarded'] as const) if (TAB_STATUSES[t]!.includes(p.status)) c[t]++
    }
    return c
  }, [prospects.data])

  const rows = useMemo(() => {
    const statuses = TAB_STATUSES[tab]
    const term = filter.trim().toLowerCase()
    return (prospects.data ?? [])
      .filter((p) => !statuses || statuses.includes(p.status))
      .filter((p) => !term || [p.name, p.city, p.address].some((v) => (v ?? '').toLowerCase().includes(term)))
      .sort((a, b) => (b.research[0]?.score ?? -1) - (a.research[0]?.score ?? -1))
  }, [prospects.data, tab, filter])

  const selected = (prospects.data ?? []).find((p) => p.id === selectedId) ?? null

  const onSearch = (v: FormValues) =>
    search.mutate(
      { query: v.query, city: v.city, company_type: (v.company_type || null) as ProspectListItem['company_type'] },
      {
        onSuccess: (r) => {
          const via = r.source === 'openstreetmap' ? ' no OpenStreetMap' : r.source === 'gemini_search' ? ' pela IA' : ' no Google'
          toast.success(`${r.found} lugares encontrados${via}`, {
            description: r.new === r.found ? 'Todos novos na fila.' : `${r.new} novos; ${r.found - r.new} já estavam na fila.`,
          })
          setTab('queue')
        },
        onError: (err) => toast.error('A busca falhou', { description: friendlyError(err) }),
      },
    )

  return (
    <section className="flex flex-col gap-5">
      <PageHeader
        title="Prospecção"
        count={counts.queue}
        actions={
          <>
            <Button variant="outline" onClick={() => setImporting(true)}>
              <FileUp aria-hidden /> Importar planilha
            </Button>
            <Button className={actionButtonClass} onClick={() => setAdding(true)}>
              <Plus aria-hidden /> Adicionar lead
            </Button>
          </>
        }
      />

      <form onSubmit={handleSubmit(onSearch)} className="grid gap-3 rounded-xl border border-border bg-card p-4 sm:grid-cols-2 sm:items-end xl:grid-cols-[12rem_1fr_14rem_auto]" noValidate>
        <Field label="Tipo" htmlFor="ps-type">
          <NativeSelect id="ps-type" {...register('company_type')}>
            {options(COMPANY_TYPE_LABEL).map((o) => (
              <option key={o.value} value={o.value}>
                {o.label}
              </option>
            ))}
          </NativeSelect>
        </Field>
        <Field label="O que buscar" htmlFor="ps-query" error={errors.query?.message}>
          <Input id="ps-query" placeholder={`Ex.: ${QUERY_HINT[type] ?? ''}`} aria-invalid={!!errors.query} {...register('query')} />
        </Field>
        <Field label="Cidade" htmlFor="ps-city" error={errors.city?.message}>
          <Input id="ps-city" placeholder="Ex.: Campinas, SP" aria-invalid={!!errors.city} {...register('city')} />
        </Field>
        <Button type="submit" disabled={search.isPending} className={cn(actionButtonClass, 'h-8')}>
          <Search aria-hidden /> {search.isPending ? 'Buscando…' : 'Buscar lugares'}
        </Button>
      </form>
      {status && (
        <p role="status" className="-mt-2 text-sm text-muted-foreground">
          {status}
        </p>
      )}

      <div className="grid gap-5 lg:grid-cols-[minmax(0,24rem)_1fr]">
        <div className="flex min-w-0 flex-col gap-3">
          <div role="tablist" aria-label="Situação" className="flex flex-wrap gap-1">
            {(Object.keys(TAB_LABEL) as Tab[]).map((t) => (
              <button
                key={t}
                role="tab"
                type="button"
                aria-selected={tab === t}
                onClick={() => setTab(t)}
                className={cn(
                  'rounded-md px-2.5 py-1 text-sm font-medium',
                  tab === t ? 'bg-primary text-primary-foreground' : 'bg-card text-muted-foreground hover:text-foreground',
                )}
              >
                {TAB_LABEL[t]} <span className="opacity-70">{counts[t]}</span>
              </button>
            ))}
          </div>
          <Input value={filter} onChange={(e) => setFilter(e.target.value)} placeholder="Filtrar por nome ou cidade" className="bg-card" aria-label="Filtrar leads" />

          {prospects.error ? (
            <EmptyState title="Erro ao carregar" description={friendlyError(prospects.error)} />
          ) : prospects.isLoading ? (
            <p className="text-sm text-muted-foreground">Carregando…</p>
          ) : rows.length === 0 ? (
            <EmptyState
              title={prospects.data?.length ? 'Nada aqui' : 'Fila vazia'}
              description={prospects.data?.length ? 'Troque a aba ou o filtro.' : 'Faça uma busca acima para encher a fila.'}
            />
          ) : (
            <ul className="flex max-h-[70svh] flex-col gap-1.5 overflow-y-auto pr-1">
              {rows.map((p) => {
                const score = p.research[0]?.score
                return (
                  <li key={p.id}>
                    <button
                      type="button"
                      onClick={() => setSelectedId(p.id)}
                      aria-current={p.id === selectedId ? 'true' : undefined}
                      className={cn(
                        'flex w-full items-start gap-3 rounded-lg border bg-card px-3 py-2 text-left transition-colors focus-visible:ring-3 focus-visible:ring-ring/50 focus-visible:outline-none',
                        p.id === selectedId ? 'border-primary ring-1 ring-primary' : 'border-border hover:bg-muted/60',
                      )}
                    >
                      <span className="min-w-0 flex-1">
                        <span className="block truncate text-sm font-semibold">{p.name}</span>
                        <span className="flex items-center gap-2 text-xs text-muted-foreground">
                          <span className="truncate">{[p.city, p.state].filter(Boolean).join(' / ')}</span>
                          {p.rating != null && (
                            <span className="flex shrink-0 items-center gap-0.5">
                              <Star className="size-3" aria-hidden /> {p.rating}
                            </span>
                          )}
                          <span className="shrink-0">· {PROSPECT_STATUS_LABEL[p.status]}</span>
                        </span>
                      </span>
                      <span
                        className={cn('grid h-7 min-w-9 place-items-center rounded-md px-1 font-display text-lg leading-none', scoreClass(score))}
                        title={score != null ? 'Aderência ao NEQST (IA)' : 'Ainda sem dossiê'}
                      >
                        {score ?? '—'}
                      </span>
                    </button>
                  </li>
                )
              })}
            </ul>
          )}
        </div>

        <div className="min-w-0">
          {selected ? (
            <ProspectPanel key={selected.id} prospect={selected} />
          ) : (
            <EmptyState title="Selecione um lead" description="O dossiê com ganchos e oportunidades aparece aqui." />
          )}
        </div>
      </div>

      <p className="text-xs text-muted-foreground">
        Lugares do mapa:{' '}
        <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noreferrer" className="underline underline-offset-4">
          © OpenStreetMap contributors
        </a>
        . Parques e clubes/arenas com quadras mapeadas; a cobertura varia por cidade.
      </p>

      <AddProspectDialog open={adding} onOpenChange={setAdding} onAdded={(id) => { setTab('queue'); setSelectedId(id) }} />
      <ImportProspectsDialog open={importing} onOpenChange={setImporting} />
    </section>
  )
}
