import { useState } from 'react'
import { useForm, useWatch } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { toast } from 'sonner'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Field, NativeSelect } from '@/components/form'
import { actionButtonClass } from '@/components/common'
import { DEAL_CONTACT_ROLE_LABEL, emptyToNull, formatBRL, options, profileLabel } from '@/lib/format'
import { friendlyError, requiredFieldLabel } from '@/lib/errors'
import { useAuth } from '@/features/auth/auth-context'
import { useCompanyOptions } from '@/features/companies/api'
import { useLocations } from '@/features/locations/api'
import { useContacts } from '@/features/contacts/api'
import { useProfiles } from '@/features/team/api'
import type { Enums } from '@/types/database'
import { useDeal, useSaveDeal, type Pipeline } from './api'

type Role = Enums<'deal_contact_role'>

const decimal = (msg: string) =>
  z
    .string()
    .trim()
    .refine((v) => v === '' || (parseMoney(v) ?? -1) >= 0, msg)

const schema = z.object({
  title: z.string().trim().min(1, 'Informe o título'),
  stage_id: z.string().min(1, 'Escolha a etapa'),
  company_id: z.string(),
  court_count: z
    .string()
    .trim()
    .refine((v) => v === '' || /^\d+$/.test(v), 'Número inteiro'),
  price_per_court: decimal('Valor inválido'),
  value: decimal('Valor inválido'),
  expected_close_date: z.string(),
  owner_id: z.string(),
})
type FormValues = z.infer<typeof schema>

/** Aceita "1.234,56", "1234,56" e "1234.56". */
function parseMoney(v: string): number | null {
  const s = v.trim()
  if (!s) return null
  const normalized = s.includes(',') ? s.replace(/\./g, '').replace(',', '.') : s
  const n = Number(normalized)
  return Number.isFinite(n) ? n : null
}

const moneyInput = (n: number | null | undefined) => (n == null ? '' : String(n).replace('.', ','))

type Props = {
  open: boolean
  onOpenChange: (open: boolean) => void
  pipeline: Pipeline
  dealId?: string
  /** Etapa inicial ao criar (ex.: "+" no topo da coluna). */
  stageId?: string
  /** Campos que o banco exigiu ao tentar avançar (mostrados em destaque). */
  missing?: string[]
  /** Chamado após criar (para pedir a próxima atividade). */
  onCreated?: (dealId: string, title: string) => void
}

export function DealFormDialog({ open, onOpenChange, pipeline, dealId, stageId, missing, onCreated }: Props) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[92svh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle className="font-display text-2xl tracking-wide">
            {dealId ? 'Editar negócio' : 'Novo negócio'}
          </DialogTitle>
          <DialogDescription>{pipeline.name}</DialogDescription>
        </DialogHeader>
        {missing && missing.length > 0 && (
          <p role="alert" className="rounded-lg bg-accent/20 p-3 text-sm">
            Para avançar de etapa, preencha: <strong>{missing.map(requiredFieldLabel).join(', ')}</strong>.
          </p>
        )}
        {open && (
          <DealFormLoader
            pipeline={pipeline}
            dealId={dealId}
            stageId={stageId}
            onDone={() => onOpenChange(false)}
            onCreated={onCreated}
          />
        )}
      </DialogContent>
    </Dialog>
  )
}

function DealFormLoader({
  pipeline,
  dealId,
  stageId,
  onDone,
  onCreated,
}: {
  pipeline: Pipeline
  dealId?: string
  stageId?: string
  onDone: () => void
  onCreated?: Props['onCreated']
}) {
  const deal = useDeal(dealId)
  const companies = useCompanyOptions()
  const profiles = useProfiles()
  if ((dealId && deal.isLoading) || companies.isLoading || profiles.isLoading) {
    return <p className="text-sm text-muted-foreground">Carregando…</p>
  }
  if (deal.error) return <p className="text-sm text-destructive">{friendlyError(deal.error)}</p>
  return (
    <DealForm
      key={dealId ?? 'new'}
      pipeline={pipeline}
      deal={deal.data}
      stageId={stageId}
      companies={companies.data ?? []}
      profiles={profiles.data ?? []}
      onDone={onDone}
      onCreated={onCreated}
    />
  )
}

function DealForm({
  pipeline,
  deal,
  stageId,
  companies,
  profiles,
  onDone,
  onCreated,
}: {
  pipeline: Pipeline
  deal?: ReturnType<typeof useDeal>['data']
  stageId?: string
  companies: { id: string; name: string }[]
  profiles: { id: string; full_name: string | null; email: string | null }[]
  onDone: () => void
  onCreated?: Props['onCreated']
}) {
  const { user } = useAuth()
  const save = useSaveDeal()
  const [locationIds, setLocationIds] = useState<string[]>(deal?.deal_locations.map((l) => l.location_id) ?? [])
  const [contactRoles, setContactRoles] = useState<Record<string, Role | null>>(
    Object.fromEntries(deal?.deal_contacts.map((c) => [c.contact_id, c.role]) ?? []),
  )

  const {
    register,
    handleSubmit,
    control,
    setValue,
    formState: { errors, isSubmitting },
  } = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: {
      title: deal?.title ?? '',
      stage_id: deal?.stage_id ?? stageId ?? pipeline.stages[0]?.id ?? '',
      company_id: deal?.company_id ?? '',
      court_count: deal?.court_count != null ? String(deal.court_count) : '',
      price_per_court: moneyInput(deal?.price_per_court),
      value: moneyInput(deal?.value),
      expected_close_date: deal?.expected_close_date ?? '',
      owner_id: deal ? (deal.owner_id ?? '') : (user?.id ?? ''),
    },
  })

  const companyId = useWatch({ control, name: 'company_id' })
  const courtCount = useWatch({ control, name: 'court_count' })
  const pricePerCourt = useWatch({ control, name: 'price_per_court' })
  const locations = useLocations({ companyId, enabled: !!companyId })
  const contacts = useContacts({ companyId, enabled: !!companyId })

  const courts = /^\d+$/.test(courtCount) ? Number(courtCount) : null
  const price = parseMoney(pricePerCourt)
  const computedValue = courts != null && price != null ? courts * price * 12 : null
  const courtsFromLocations = (locations.data ?? [])
    .filter((l) => locationIds.includes(l.id))
    .reduce((acc, l) => acc + (l.court_count ?? 0), 0)

  const onCompanyChange = () => {
    // Locais e contatos são da empresa: trocar a empresa limpa a seleção.
    setLocationIds([])
    setContactRoles({})
  }

  const onSubmit = async (v: FormValues) => {
    await save
      .mutateAsync(
        {
          id: deal?.id,
          values: {
            pipeline_id: pipeline.id,
            stage_id: v.stage_id,
            title: v.title,
            company_id: emptyToNull(v.company_id),
            court_count: courts,
            price_per_court: price,
            value: computedValue ?? parseMoney(v.value),
            expected_close_date: emptyToNull(v.expected_close_date),
            owner_id: emptyToNull(v.owner_id),
          },
          locationIds,
          contacts: Object.entries(contactRoles).map(([contact_id, role]) => ({ contact_id, role })),
        },
        {
          onSuccess: (saved) => {
            toast.success(deal ? 'Negócio atualizado' : 'Negócio criado')
            onDone()
            if (!deal) onCreated?.(saved.id, v.title)
          },
          onError: (err) => toast.error('Não foi possível salvar o negócio', { description: friendlyError(err) }),
        },
      )
      .catch(() => undefined)
  }

  return (
    <form onSubmit={handleSubmit(onSubmit)} className="grid gap-4" noValidate>
      <div className="grid gap-4 sm:grid-cols-6">
        <Field label="Título" htmlFor="deal-title" error={errors.title?.message} className="sm:col-span-4">
          <Input id="deal-title" autoFocus placeholder="Ex.: Urbia · Ibirapuera" aria-invalid={!!errors.title} {...register('title')} />
        </Field>
        <Field label="Etapa" htmlFor="deal-stage" error={errors.stage_id?.message} className="sm:col-span-2">
          <NativeSelect id="deal-stage" {...register('stage_id')}>
            {pipeline.stages.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </NativeSelect>
        </Field>

        <Field label="Empresa" htmlFor="deal-company" className="sm:col-span-4">
          <NativeSelect id="deal-company" {...register('company_id', { onChange: onCompanyChange })}>
            <option value="">Sem empresa</option>
            {companies.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </NativeSelect>
        </Field>
        <Field label="Responsável" htmlFor="deal-owner" className="sm:col-span-2">
          <NativeSelect id="deal-owner" {...register('owner_id')}>
            <option value="">Ninguém</option>
            {profiles.map((p) => (
              <option key={p.id} value={p.id}>
                {profileLabel(p)}
              </option>
            ))}
          </NativeSelect>
        </Field>

        {companyId && (
          <fieldset className="grid gap-2 sm:col-span-3">
            <legend className="mb-1 text-sm font-medium">Locais</legend>
            {locations.isLoading ? (
              <p className="text-xs text-muted-foreground">Carregando…</p>
            ) : locations.data?.length ? (
              locations.data.map((l) => (
                <label key={l.id} className="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    className="size-4 accent-forest"
                    checked={locationIds.includes(l.id)}
                    onChange={(e) =>
                      setLocationIds((ids) => (e.target.checked ? [...ids, l.id] : ids.filter((i) => i !== l.id)))
                    }
                  />
                  {l.name}
                  {l.court_count != null && <span className="text-muted-foreground">· {l.court_count} quadras</span>}
                </label>
              ))
            ) : (
              <p className="text-xs text-muted-foreground">Empresa sem locais cadastrados.</p>
            )}
          </fieldset>
        )}

        {companyId && (
          <fieldset className="grid gap-2 sm:col-span-3">
            <legend className="mb-1 text-sm font-medium">Contatos</legend>
            {contacts.isLoading ? (
              <p className="text-xs text-muted-foreground">Carregando…</p>
            ) : contacts.data?.length ? (
              contacts.data.map((c) => {
                const checked = c.id in contactRoles
                return (
                  <div key={c.id} className="flex flex-wrap items-center gap-2 text-sm">
                    <label className="flex min-w-0 flex-1 items-center gap-2">
                      <input
                        type="checkbox"
                        className="size-4 accent-forest"
                        checked={checked}
                        onChange={(e) =>
                          setContactRoles((r) => {
                            const next = { ...r }
                            if (e.target.checked) next[c.id] = null
                            else delete next[c.id]
                            return next
                          })
                        }
                      />
                      <span className="truncate">{c.name}</span>
                    </label>
                    {checked && (
                      <NativeSelect
                        aria-label={`Papel de ${c.name}`}
                        className="h-7 w-auto text-xs"
                        value={contactRoles[c.id] ?? ''}
                        onChange={(e) => setContactRoles((r) => ({ ...r, [c.id]: (e.target.value || null) as Role | null }))}
                      >
                        <option value="">Papel…</option>
                        {options(DEAL_CONTACT_ROLE_LABEL).map((o) => (
                          <option key={o.value} value={o.value}>
                            {o.label}
                          </option>
                        ))}
                      </NativeSelect>
                    )}
                  </div>
                )
              })
            ) : (
              <p className="text-xs text-muted-foreground">Empresa sem contatos cadastrados.</p>
            )}
          </fieldset>
        )}

        <Field label="Nº de quadras" htmlFor="deal-courts" error={errors.court_count?.message} className="sm:col-span-2">
          <Input id="deal-courts" inputMode="numeric" aria-invalid={!!errors.court_count} {...register('court_count')} />
          {courtsFromLocations > 0 && String(courtsFromLocations) !== courtCount && (
            <button
              type="button"
              className="self-start text-xs text-primary underline underline-offset-4"
              onClick={() => setValue('court_count', String(courtsFromLocations), { shouldValidate: true })}
            >
              Usar soma dos locais ({courtsFromLocations})
            </button>
          )}
        </Field>
        <Field label="Preço por quadra / mês (R$)" htmlFor="deal-price" error={errors.price_per_court?.message} className="sm:col-span-2">
          <Input id="deal-price" inputMode="decimal" placeholder="0,00" aria-invalid={!!errors.price_per_court} {...register('price_per_court')} />
        </Field>
        <div className="flex flex-col gap-1.5 sm:col-span-2">
          <Label htmlFor="deal-value">Valor anual (R$)</Label>
          {computedValue != null ? (
            <p id="deal-value" className="flex h-8 items-center font-display text-2xl leading-none text-primary">
              {formatBRL(computedValue)}
            </p>
          ) : (
            <Input id="deal-value" inputMode="decimal" placeholder="0,00" aria-invalid={!!errors.value} {...register('value')} />
          )}
          <p className="text-xs text-muted-foreground">
            {computedValue != null ? 'Quadras × preço × 12' : 'Preencha quadras e preço, ou o valor direto'}
          </p>
        </div>

        <Field label="Data prevista de fechamento" htmlFor="deal-date" className="sm:col-span-2">
          <Input id="deal-date" type="date" {...register('expected_close_date')} />
        </Field>
      </div>

      <DialogFooter>
        <Button type="button" variant="outline" onClick={onDone}>
          Cancelar
        </Button>
        <Button type="submit" disabled={isSubmitting} className={actionButtonClass}>
          {isSubmitting ? 'Salvando…' : 'Salvar'}
        </Button>
      </DialogFooter>
    </form>
  )
}
