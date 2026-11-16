import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { toast } from 'sonner'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Textarea } from '@/components/ui/textarea'
import { Field, NativeSelect } from '@/components/form'
import { actionButtonClass } from '@/components/common'
import { ACTIVITY_TYPE_LABEL, emptyToNull, options, profileLabel } from '@/lib/format'
import { toastError } from '@/lib/errors'
import { useAuth } from '@/features/auth/auth-context'
import { useProfiles } from '@/features/team/api'
import { useSaveActivity, type Activity } from './api'

const schema = z.object({
  type: z.enum(['task', 'call', 'meeting', 'visit', 'whatsapp', 'email']),
  title: z.string().trim().min(1, 'Descreva a atividade'),
  date: z.string().min(1, 'Informe a data'),
  time: z.string(),
  description: z.string(),
  owner_id: z.string(),
})
type FormValues = z.infer<typeof schema>

const pad = (n: number) => String(n).padStart(2, '0')
const toDateInput = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
const toTimeInput = (d: Date) => `${pad(d.getHours())}:${pad(d.getMinutes())}`

/** Próximo dia útil às 10h (sugestão padrão). */
function suggestedDate() {
  const d = new Date()
  d.setDate(d.getDate() + 1)
  while (d.getDay() === 0 || d.getDay() === 6) d.setDate(d.getDate() + 1)
  d.setHours(10, 0, 0, 0)
  return d
}

type Props = {
  open: boolean
  onOpenChange: (open: boolean) => void
  dealId?: string
  dealTitle?: string
  activity?: Activity
  /** Modo "próxima atividade": texto e sugestão de título específicos. */
  next?: { reason: string; suggestedTitle?: string }
}

export function ActivityFormDialog({ open, onOpenChange, dealId, dealTitle, activity, next }: Props) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-lg">
        <DialogHeader>
          <DialogTitle className="font-display text-2xl tracking-wide">
            {activity ? 'Editar atividade' : next ? 'Qual é a próxima atividade?' : 'Nova atividade'}
          </DialogTitle>
          <DialogDescription>{next ? `${next.reason}${dealTitle ? ` · ${dealTitle}` : ''}` : dealTitle}</DialogDescription>
        </DialogHeader>
        {open && <ActivityFormLoader key={activity?.id ?? 'new'} dealId={dealId} activity={activity} next={next} onDone={() => onOpenChange(false)} />}
      </DialogContent>
    </Dialog>
  )
}

function ActivityFormLoader(props: { dealId?: string; activity?: Activity; next?: Props['next']; onDone: () => void }) {
  const profiles = useProfiles()
  if (profiles.isLoading) return <p className="text-sm text-muted-foreground">Carregando…</p>
  return <ActivityForm {...props} profiles={profiles.data ?? []} />
}

function ActivityForm({
  dealId,
  activity,
  next,
  onDone,
  profiles,
}: {
  dealId?: string
  activity?: Activity
  next?: Props['next']
  onDone: () => void
  profiles: { id: string; full_name: string | null; email: string | null }[]
}) {
  const { user } = useAuth()
  const save = useSaveActivity()
  const due = activity?.due_at ? new Date(activity.due_at) : suggestedDate()
  const {
    register,
    handleSubmit,
    formState: { errors, isSubmitting },
  } = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: {
      type: activity?.type ?? 'task',
      title: activity?.title ?? next?.suggestedTitle ?? '',
      date: toDateInput(due),
      time: activity?.due_at || !activity ? toTimeInput(due) : '',
      description: activity?.description ?? '',
      owner_id: activity ? (activity.owner_id ?? '') : (user?.id ?? ''),
    },
  })

  const onSubmit = async (v: FormValues) => {
    const dueAt = new Date(`${v.date}T${v.time || '09:00'}`)
    await save
      .mutateAsync(
        {
          id: activity?.id,
          values: {
            type: v.type,
            title: v.title,
            due_at: dueAt.toISOString(),
            description: emptyToNull(v.description),
            owner_id: emptyToNull(v.owner_id),
            deal_id: activity?.deal_id ?? dealId ?? null,
          },
        },
        {
          onSuccess: () => {
            toast.success(activity ? 'Atividade atualizada' : 'Atividade agendada')
            onDone()
          },
          onError: toastError('Não foi possível salvar a atividade'),
        },
      )
      .catch(() => undefined)
  }

  return (
    <form onSubmit={handleSubmit(onSubmit)} className="grid gap-4" noValidate>
      <div className="grid gap-4 sm:grid-cols-6">
        <Field label="Tipo" htmlFor="act-type" className="sm:col-span-2">
          <NativeSelect id="act-type" {...register('type')}>
            {options(ACTIVITY_TYPE_LABEL).map((o) => (
              <option key={o.value} value={o.value}>
                {o.label}
              </option>
            ))}
          </NativeSelect>
        </Field>
        <Field label="O que fazer" htmlFor="act-title" error={errors.title?.message} className="sm:col-span-4">
          <Input id="act-title" autoFocus placeholder="Ex.: Ligar para confirmar a visita" aria-invalid={!!errors.title} {...register('title')} />
        </Field>
        <Field label="Data" htmlFor="act-date" error={errors.date?.message} className="sm:col-span-2">
          <Input id="act-date" type="date" aria-invalid={!!errors.date} {...register('date')} />
        </Field>
        <Field label="Hora" htmlFor="act-time" className="sm:col-span-2">
          <Input id="act-time" type="time" {...register('time')} />
        </Field>
        <Field label="Responsável" htmlFor="act-owner" className="sm:col-span-2">
          <NativeSelect id="act-owner" {...register('owner_id')}>
            <option value="">Ninguém</option>
            {profiles.map((p) => (
              <option key={p.id} value={p.id}>
                {profileLabel(p)}
              </option>
            ))}
          </NativeSelect>
        </Field>
        <Field label="Detalhes" htmlFor="act-desc" className="sm:col-span-6">
          <Textarea id="act-desc" rows={2} {...register('description')} />
        </Field>
      </div>
      <DialogFooter>
        <Button type="button" variant="outline" onClick={onDone}>
          {next ? 'Agora não' : 'Cancelar'}
        </Button>
        <Button type="submit" disabled={isSubmitting} className={actionButtonClass}>
          {isSubmitting ? 'Salvando…' : 'Agendar'}
        </Button>
      </DialogFooter>
    </form>
  )
}
