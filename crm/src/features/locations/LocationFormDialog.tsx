import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { toast } from 'sonner'
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Field, NativeSelect } from '@/components/form'
import { actionButtonClass } from '@/components/common'
import { LOCATION_STATUS_LABEL, emptyToNull, options } from '@/lib/format'
import { toastError } from '@/lib/errors'
import { useCompanyOptions } from '@/features/companies/api'
import { useSaveLocation, type Location } from './api'

const schema = z.object({
  company_id: z.string().min(1, 'Escolha a empresa'),
  name: z.string().trim().min(1, 'Informe o nome do local'),
  address: z.string().trim(),
  city: z.string().trim(),
  state: z
    .string()
    .trim()
    .refine((v) => v === '' || /^[A-Za-z]{2}$/.test(v), 'Use a sigla (ex.: SP)'),
  court_count: z
    .string()
    .trim()
    .refine((v) => v === '' || /^\d+$/.test(v), 'Número inteiro'),
  surfaces: z.string(),
  has_internet: z.enum(['', 'yes', 'no']),
  status: z.enum(['prospect', 'pilot', 'client']),
})
type FormValues = z.infer<typeof schema>

type Props = {
  open: boolean
  onOpenChange: (open: boolean) => void
  location?: Location
  /** Fixa a empresa (cadastro a partir da ficha da empresa). */
  companyId?: string
}

export function LocationFormDialog({ open, onOpenChange, location, companyId }: Props) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle className="font-display text-2xl tracking-wide">
            {location ? 'Editar local' : 'Novo local'}
          </DialogTitle>
        </DialogHeader>
        {open && (
          <LocationForm
            key={location?.id ?? 'new'}
            location={location}
            companyId={companyId}
            onDone={() => onOpenChange(false)}
          />
        )}
      </DialogContent>
    </Dialog>
  )
}

function LocationForm({
  location,
  companyId,
  onDone,
}: {
  location?: Location
  companyId?: string
  onDone: () => void
}) {
  const companies = useCompanyOptions()
  if (companies.isLoading) return <p className="text-sm text-muted-foreground">Carregando…</p>
  return <LocationFormFields location={location} companyId={companyId} companies={companies.data ?? []} onDone={onDone} />
}

function LocationFormFields({
  location,
  companyId,
  companies,
  onDone,
}: {
  location?: Location
  companyId?: string
  companies: { id: string; name: string }[]
  onDone: () => void
}) {
  const save = useSaveLocation()
  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: {
      company_id: location?.company_id ?? companyId ?? '',
      name: location?.name ?? '',
      address: location?.address ?? '',
      city: location?.city ?? '',
      state: location?.state ?? '',
      court_count: location?.court_count != null ? String(location.court_count) : '',
      surfaces: location?.surfaces.join(', ') ?? '',
      has_internet: location?.has_internet == null ? '' : location.has_internet ? 'yes' : 'no',
      status: location?.status ?? 'prospect',
    },
  })

  const onSubmit = async (v: FormValues) => {
    await save
      .mutateAsync(
        {
          id: location?.id,
          values: {
            company_id: v.company_id,
            name: v.name,
            address: emptyToNull(v.address),
            city: emptyToNull(v.city),
            state: emptyToNull(v.state.toUpperCase()),
            court_count: v.court_count === '' ? null : Number(v.court_count),
            surfaces: v.surfaces
              .split(',')
              .map((s) => s.trim().toLowerCase())
              .filter(Boolean),
            has_internet: v.has_internet === '' ? null : v.has_internet === 'yes',
            status: v.status,
          },
        },
        {
          onSuccess: () => {
            toast.success(location ? 'Local atualizado' : 'Local criado')
            onDone()
          },
          onError: toastError('Não foi possível salvar o local'),
        },
      )
      .catch(() => undefined)
  }

  return (
    <form onSubmit={handleSubmit(onSubmit)} className="grid gap-4" noValidate>
      <div className="grid gap-4 sm:grid-cols-6">
        {!companyId && (
          <Field label="Empresa" htmlFor="loc-company" error={errors.company_id?.message} className="sm:col-span-6">
            <NativeSelect id="loc-company" aria-invalid={!!errors.company_id} {...register('company_id')}>
              <option value="">Selecione…</option>
              {companies.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name}
                </option>
              ))}
            </NativeSelect>
          </Field>
        )}
        <Field label="Nome do local" htmlFor="loc-name" error={errors.name?.message} className="sm:col-span-6">
          <Input id="loc-name" autoFocus placeholder="Ex.: Parque Ibirapuera" aria-invalid={!!errors.name} {...register('name')} />
        </Field>
        <Field label="Endereço" htmlFor="loc-address" className="sm:col-span-6">
          <Input id="loc-address" {...register('address')} />
        </Field>
        <Field label="Cidade" htmlFor="loc-city" className="sm:col-span-4">
          <Input id="loc-city" {...register('city')} />
        </Field>
        <Field label="UF" htmlFor="loc-state" error={errors.state?.message} className="sm:col-span-2">
          <Input id="loc-state" maxLength={2} className="uppercase" aria-invalid={!!errors.state} {...register('state')} />
        </Field>
        <Field label="Nº de quadras" htmlFor="loc-courts" error={errors.court_count?.message} className="sm:col-span-2">
          <Input id="loc-courts" inputMode="numeric" aria-invalid={!!errors.court_count} {...register('court_count')} />
        </Field>
        <Field label="Internet no local" htmlFor="loc-internet" className="sm:col-span-2">
          <NativeSelect id="loc-internet" {...register('has_internet')}>
            <option value="">Não sei</option>
            <option value="yes">Tem</option>
            <option value="no">Não tem</option>
          </NativeSelect>
        </Field>
        <Field label="Status" htmlFor="loc-status" className="sm:col-span-2">
          <NativeSelect id="loc-status" {...register('status')}>
            {options(LOCATION_STATUS_LABEL).map((o) => (
              <option key={o.value} value={o.value}>
                {o.label}
              </option>
            ))}
          </NativeSelect>
        </Field>
        <Field label="Pisos" htmlFor="loc-surfaces" hint="Separe por vírgula. Ex.: areia, saibro" className="sm:col-span-6">
          <Input id="loc-surfaces" {...register('surfaces')} />
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
