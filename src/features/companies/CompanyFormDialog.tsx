import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { toast } from 'sonner'
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Field, NativeSelect } from '@/components/form'
import { actionButtonClass } from '@/components/common'
import { COMPANY_TYPE_LABEL, emptyToNull, formatCnpj, isValidCnpj, onlyDigits, options, profileLabel } from '@/lib/format'
import { toastError } from '@/lib/errors'
import { useProfiles } from '@/features/team/api'
import { useAuth } from '@/features/auth/auth-context'
import { useSaveCompany, type Company } from './api'

const schema = z.object({
  name: z.string().trim().min(1, 'Informe o nome'),
  type: z.enum(['public_operator', 'club', 'condo', 'builder', 'brand'], { error: 'Escolha o tipo' }),
  cnpj: z
    .string()
    .trim()
    .refine((v) => v === '' || isValidCnpj(v), 'CNPJ inválido'),
  website: z.string().trim(),
  owner_id: z.string(),
})
type FormValues = z.infer<typeof schema>

type Props = {
  open: boolean
  onOpenChange: (open: boolean) => void
  company?: Company
  onSaved?: (company: Company) => void
}

export function CompanyFormDialog({ open, onOpenChange, company, onSaved }: Props) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle className="font-display text-2xl tracking-wide">
            {company ? 'Editar empresa' : 'Nova empresa'}
          </DialogTitle>
        </DialogHeader>
        {open && <CompanyFormLoader company={company} onOpenChange={onOpenChange} onSaved={onSaved} />}
      </DialogContent>
    </Dialog>
  )
}

/** Espera a lista do time carregar: o select nativo perde o valor padrão se as opções chegarem depois. */
function CompanyFormLoader({ company, onOpenChange, onSaved }: Omit<Props, 'open'>) {
  const profiles = useProfiles()
  if (profiles.isLoading) return <p className="text-sm text-muted-foreground">Carregando…</p>
  return (
    <CompanyForm
      key={company?.id ?? 'new'}
      company={company}
      onDone={(saved) => {
        onOpenChange(false)
        onSaved?.(saved)
      }}
      onCancel={() => onOpenChange(false)}
    />
  )
}

function CompanyForm({
  company,
  onDone,
  onCancel,
}: {
  company?: Company
  onDone: (c: Company) => void
  onCancel: () => void
}) {
  const { user } = useAuth()
  const profiles = useProfiles()
  const save = useSaveCompany()
  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: {
      name: company?.name ?? '',
      type: company?.type,
      cnpj: company?.cnpj ? formatCnpj(company.cnpj) : '',
      website: company?.website ?? '',
      owner_id: company ? (company.owner_id ?? '') : (user?.id ?? ''),
    },
  })

  const onSubmit = async (v: FormValues) => {
    await save.mutateAsync(
      {
        id: company?.id,
        values: {
          name: v.name,
          type: v.type,
          cnpj: emptyToNull(onlyDigits(v.cnpj)),
          website: emptyToNull(v.website),
          owner_id: emptyToNull(v.owner_id),
        },
      },
      {
        onSuccess: (saved) => {
          toast.success(company ? 'Empresa atualizada' : 'Empresa criada')
          onDone(saved)
        },
        onError: toastError('Não foi possível salvar a empresa'),
      },
    ).catch(() => undefined)
  }

  return (
    <form onSubmit={handleSubmit(onSubmit)} className="grid gap-4" noValidate>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Nome" htmlFor="company-name" error={errors.name?.message} className="sm:col-span-2">
          <Input id="company-name" autoFocus placeholder="Ex.: Urbia Parques" aria-invalid={!!errors.name} {...register('name')} />
        </Field>
        <Field label="Tipo" htmlFor="company-type" error={errors.type?.message}>
          <NativeSelect id="company-type" aria-invalid={!!errors.type} {...register('type')}>
            <option value="">Selecione…</option>
            {options(COMPANY_TYPE_LABEL).map((o) => (
              <option key={o.value} value={o.value}>
                {o.label}
              </option>
            ))}
          </NativeSelect>
        </Field>
        <Field label="CNPJ" htmlFor="company-cnpj" error={errors.cnpj?.message}>
          <Input id="company-cnpj" inputMode="numeric" placeholder="00.000.000/0000-00" aria-invalid={!!errors.cnpj} {...register('cnpj')} />
        </Field>
        <Field label="Site" htmlFor="company-website">
          <Input id="company-website" type="url" placeholder="https://" {...register('website')} />
        </Field>
        <Field label="Responsável" htmlFor="company-owner">
          <NativeSelect id="company-owner" {...register('owner_id')}>
            <option value="">Ninguém</option>
            {profiles.data?.map((p) => (
              <option key={p.id} value={p.id}>
                {profileLabel(p)}
              </option>
            ))}
          </NativeSelect>
        </Field>
      </div>
      <DialogFooter>
        <Button type="button" variant="outline" onClick={onCancel}>
          Cancelar
        </Button>
        <Button type="submit" disabled={isSubmitting} className={actionButtonClass}>
          {isSubmitting ? 'Salvando…' : 'Salvar'}
        </Button>
      </DialogFooter>
    </form>
  )
}
