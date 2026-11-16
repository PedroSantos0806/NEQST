import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { toast } from 'sonner'
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { Field, NativeSelect } from '@/components/form'
import { actionButtonClass } from '@/components/common'
import { friendlyError } from '@/lib/errors'
import { usePipelines } from '@/features/deals/api'
import { useCreateDealFromContact } from './api'


/** Contato vira oportunidade: abre negócio na 1ª etapa do funil escolhido, com o contato ligado. */
export function CreateDealFromContactDialog({
  contact,
  onClose,
}: {
  contact: { id: string; name: string } | null
  onClose: () => void
}) {
  const navigate = useNavigate()
  const pipelines = usePipelines()
  const create = useCreateDealFromContact()
  const sales = (pipelines.data ?? []).filter((p) => p.type === 'sales')
  const [pipelineId, setPipelineId] = useState('')
  const effective = pipelineId || sales[0]?.id || ''

  return (
    <Dialog open={!!contact} onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle className="font-display text-2xl tracking-wide">Criar negócio</DialogTitle>
          <DialogDescription>{contact?.name} vira oportunidade e entra na 1ª etapa do funil.</DialogDescription>
        </DialogHeader>
        <Field label="Funil" htmlFor="cd-pipeline">
          <NativeSelect id="cd-pipeline" value={effective} onChange={(e) => setPipelineId(e.target.value)}>
            {sales.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name}
              </option>
            ))}
          </NativeSelect>
        </Field>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancelar
          </Button>
          <Button
            className={actionButtonClass}
            disabled={!effective || create.isPending || !contact}
            onClick={() =>
              contact &&
              create.mutate(
                { contactId: contact.id, pipelineId: effective },
                {
                  onSuccess: (dealId) => {
                    toast.success('Negócio criado')
                    onClose()
                    navigate(`/negocios/${dealId}`)
                  },
                  onError: (err) => toast.error('Não foi possível criar o negócio', { description: friendlyError(err) }),
                },
              )
            }
          >
            {create.isPending ? 'Criando…' : 'Criar negócio'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
