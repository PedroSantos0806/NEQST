import { useState } from 'react'
import { toast } from 'sonner'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Textarea } from '@/components/ui/textarea'
import { Field, NativeSelect } from '@/components/form'
import { actionButtonClass } from '@/components/common'
import { formatBRL } from '@/lib/format'
import { toastError } from '@/lib/errors'
import { useCloseDeal, useLostReasons, type BoardDeal } from './api'

export function LostDealDialog({ deal, onClose }: { deal: BoardDeal | null; onClose: () => void }) {
  const reasons = useLostReasons()
  const close = useCloseDeal()
  const [reasonId, setReasonId] = useState('')
  const [note, setNote] = useState('')
  const [error, setError] = useState<string | null>(null)

  const reset = () => {
    setReasonId('')
    setNote('')
    setError(null)
    onClose()
  }

  const submit = async () => {
    if (!deal) return
    if (!reasonId) {
      setError('Escolha o motivo da perda')
      return
    }
    await close
      .mutateAsync(
        { id: deal.id, status: 'lost', lost_reason_id: reasonId, lost_note: note.trim() || null },
        {
          onSuccess: () => {
            toast.success('Negócio marcado como perdido')
            reset()
          },
          onError: toastError('Não foi possível marcar como perdido'),
        },
      )
      .catch(() => undefined)
  }

  return (
    <Dialog open={!!deal} onOpenChange={(o) => !o && reset()}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle className="font-display text-2xl tracking-wide">Marcar como perdido</DialogTitle>
          <DialogDescription>{deal?.title}</DialogDescription>
        </DialogHeader>
        <div className="grid gap-4">
          <Field label="Motivo" htmlFor="lost-reason" error={error ?? undefined}>
            <NativeSelect
              id="lost-reason"
              value={reasonId}
              aria-invalid={!!error}
              onChange={(e) => {
                setReasonId(e.target.value)
                setError(null)
              }}
            >
              <option value="">Selecione…</option>
              {reasons.data?.map((r) => (
                <option key={r.id} value={r.id}>
                  {r.name}
                </option>
              ))}
            </NativeSelect>
          </Field>
          <Field label="Observação" htmlFor="lost-note" hint="Opcional. O que aprendemos com essa perda?">
            <Textarea id="lost-note" rows={3} value={note} onChange={(e) => setNote(e.target.value)} />
          </Field>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={reset}>
            Cancelar
          </Button>
          <Button variant="destructive" disabled={close.isPending} onClick={submit}>
            {close.isPending ? 'Salvando…' : 'Marcar como perdido'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}

export function WonDealDialog({ deal, onClose }: { deal: BoardDeal | null; onClose: () => void }) {
  const close = useCloseDeal()
  const submit = async () => {
    if (!deal) return
    await close
      .mutateAsync(
        { id: deal.id, status: 'won' },
        {
          onSuccess: () => {
            toast.success('Negócio ganho!', { description: 'Criado no funil de Implantação, etapa "Contrato assinado".' })
            onClose()
          },
          onError: toastError('Não foi possível marcar como ganho'),
        },
      )
      .catch(() => undefined)
  }

  return (
    <Dialog open={!!deal} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle className="font-display text-2xl tracking-wide">Marcar como ganho</DialogTitle>
          <DialogDescription>
            {deal?.title}
            {deal?.value != null && ` · ${formatBRL(deal.value)}`}
          </DialogDescription>
        </DialogHeader>
        <p className="text-sm">
          O contrato foi assinado? Piloto gratuito não conta como ganho. Ao confirmar, o negócio sai deste quadro e um
          novo negócio é criado no funil de <strong>Implantação</strong>, com a mesma empresa, locais e contatos.
        </p>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancelar
          </Button>
          <Button className={actionButtonClass} disabled={close.isPending} onClick={submit}>
            {close.isPending ? 'Salvando…' : 'Confirmar ganho'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
