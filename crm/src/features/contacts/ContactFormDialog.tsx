import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { toast } from 'sonner'
import { Dialog, DialogContent, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Field, NativeSelect } from '@/components/form'
import { actionButtonClass } from '@/components/common'
import { E164, LIFECYCLE_LABEL, emptyToNull, formatPhone, normalizePhone, options, profileLabel } from '@/lib/format'
import { toastError } from '@/lib/errors'
import { useCompanyOptions } from '@/features/companies/api'
import { useProfiles } from '@/features/team/api'
import { useAuth } from '@/features/auth/auth-context'
import { useSaveContact, type Contact } from './api'

const schema = z.object({
    name: z.string().trim().min(1, 'Informe o nome'),
    email: z
      .string()
      .trim()
      .refine((v) => v === '' || z.email().safeParse(v).success, 'E-mail inválido'),
    phone: z
      .string()
      .trim()
      .refine((v) => v === '' || E164.test(normalizePhone(v) ?? ''), 'Telefone inválido. Use DDD + número'),
    company_id: z.string(),
    job_title: z.string().trim(),
    lifecycle_stage: z.enum(['lead', 'qualified_lead', 'opportunity', 'customer']),
    owner_id: z.string(),
    source: z.string().trim(),
  })
type FormValues = z.infer<typeof schema>

type Props = {
  open: boolean
  onOpenChange: (open: boolean) => void
  contact?: Contact
  companyId?: string
}

export function ContactFormDialog({ open, onOpenChange, contact, companyId }: Props) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle className="font-display text-2xl tracking-wide">
            {contact ? 'Editar contato' : 'Novo contato'}
          </DialogTitle>
        </DialogHeader>
        {open && (
          <ContactForm
            key={contact?.id ?? 'new'}
            contact={contact}
            companyId={companyId}
            onDone={() => onOpenChange(false)}
          />
        )}
      </DialogContent>
    </Dialog>
  )
}

type FormProps = { contact?: Contact; companyId?: string; onDone: () => void }

/** Espera empresas e time carregarem: o select nativo perde o valor padrão se as opções chegarem depois. */
function ContactForm(props: FormProps) {
  const companies = useCompanyOptions()
  const profiles = useProfiles()
  if (companies.isLoading || profiles.isLoading) return <p className="text-sm text-muted-foreground">Carregando…</p>
  return <ContactFormFields {...props} companies={companies.data ?? []} profiles={profiles.data ?? []} />
}

function ContactFormFields({
  contact,
  companyId,
  onDone,
  companies,
  profiles,
}: FormProps & {
  companies: { id: string; name: string }[]
  profiles: { id: string; full_name: string | null; email: string | null }[]
}) {
  const { user } = useAuth()
  const save = useSaveContact()
  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: {
      name: contact?.name ?? '',
      email: contact?.email ?? '',
      phone: formatPhone(contact?.phone),
      company_id: contact?.company_id ?? companyId ?? '',
      job_title: contact?.job_title ?? '',
      lifecycle_stage: contact?.lifecycle_stage ?? 'lead',
      owner_id: contact ? (contact.owner_id ?? '') : (user?.id ?? ''),
      source: contact?.source ?? (contact ? '' : 'manual'),
    },
  })

  const onSubmit = async (v: FormValues) => {
    await save
      .mutateAsync(
        {
          id: contact?.id,
          values: {
            name: v.name,
            email: emptyToNull(v.email.toLowerCase()),
            phone: normalizePhone(v.phone),
            company_id: emptyToNull(v.company_id),
            job_title: emptyToNull(v.job_title),
            lifecycle_stage: v.lifecycle_stage,
            owner_id: emptyToNull(v.owner_id),
            source: emptyToNull(v.source),
          },
        },
        {
          onSuccess: () => {
            toast.success(contact ? 'Contato atualizado' : 'Contato criado')
            onDone()
          },
          onError: toastError('Não foi possível salvar o contato'),
        },
      )
      .catch(() => undefined)
  }

  return (
    <form onSubmit={handleSubmit(onSubmit)} className="grid gap-4" noValidate>
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Nome" htmlFor="contact-name" error={errors.name?.message} className="sm:col-span-2">
          <Input id="contact-name" autoFocus aria-invalid={!!errors.name} {...register('name')} />
        </Field>
        <Field label="E-mail" htmlFor="contact-email" error={errors.email?.message}>
          <Input id="contact-email" type="email" autoComplete="off" aria-invalid={!!errors.email} {...register('email')} />
        </Field>
        <Field label="Telefone / WhatsApp" htmlFor="contact-phone" error={errors.phone?.message} hint="DDD + número. Sem DDI = Brasil.">
          <Input id="contact-phone" type="tel" placeholder="(11) 99999-0000" aria-invalid={!!errors.phone} {...register('phone')} />
        </Field>
        {!companyId && (
          <Field label="Empresa" htmlFor="contact-company">
            <NativeSelect id="contact-company" {...register('company_id')}>
              <option value="">Sem empresa</option>
              {companies.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name}
                </option>
              ))}
            </NativeSelect>
          </Field>
        )}
        <Field label="Cargo" htmlFor="contact-title">
          <Input id="contact-title" placeholder="Ex.: Gerente de operações" {...register('job_title')} />
        </Field>
        <Field label="Estágio" htmlFor="contact-lifecycle">
          <NativeSelect id="contact-lifecycle" {...register('lifecycle_stage')}>
            {options(LIFECYCLE_LABEL).map((o) => (
              <option key={o.value} value={o.value}>
                {o.label}
              </option>
            ))}
          </NativeSelect>
        </Field>
        <Field label="Responsável" htmlFor="contact-owner">
          <NativeSelect id="contact-owner" {...register('owner_id')}>
            <option value="">Ninguém</option>
            {profiles.map((p) => (
              <option key={p.id} value={p.id}>
                {profileLabel(p)}
              </option>
            ))}
          </NativeSelect>
        </Field>
        <Field label="Origem" htmlFor="contact-source" hint="Ex.: manual, indicação, evento" className="sm:col-span-2">
          <Input id="contact-source" {...register('source')} />
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
