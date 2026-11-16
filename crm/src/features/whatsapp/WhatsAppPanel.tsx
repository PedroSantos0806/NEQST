import { useEffect, useRef, useState } from 'react'
import { MessageCircle, Send } from 'lucide-react'
import { toast } from 'sonner'
import { cn } from '@/lib/utils'
import { Button } from '@/components/ui/button'
import { Textarea } from '@/components/ui/textarea'
import { formatPhone, profileLabel } from '@/lib/format'
import { friendlyError } from '@/lib/errors'
import { useSendWhatsApp, useWhatsAppThread, type WaPayload } from './api'

const time = new Intl.DateTimeFormat('pt-BR', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })

/** Conversa de WhatsApp de um contato + envio pela Evolution. */
export function WhatsAppPanel({ contact }: { contact: { id: string; name: string; phone: string | null } }) {
  const thread = useWhatsAppThread(contact.id)
  const send = useSendWhatsApp(contact.id)
  const [text, setText] = useState('')
  const endRef = useRef<HTMLDivElement>(null)
  const count = thread.data?.length ?? 0

  useEffect(() => {
    endRef.current?.scrollIntoView({ block: 'nearest' })
  }, [count])

  const submit = () => {
    const body = text.trim()
    if (!body) return
    send.mutate(body, {
      onSuccess: () => setText(''),
      onError: (err) => toast.error('Mensagem não enviada', { description: friendlyError(err) }),
    })
  }

  return (
    <section className="flex flex-col rounded-xl border border-border bg-card">
      <header className="flex items-center justify-between gap-2 border-b border-border px-4 py-3">
        <h2 className="flex items-center gap-2 text-2xl text-primary">
          <MessageCircle className="size-5" aria-hidden /> WhatsApp
        </h2>
        <span className="text-sm text-muted-foreground">{contact.phone ? formatPhone(contact.phone) : 'sem telefone'}</span>
      </header>

      <div className="flex max-h-[28rem] min-h-40 flex-col gap-2 overflow-y-auto bg-mauve/40 p-3" aria-live="polite">
        {thread.isLoading ? (
          <p className="text-sm text-muted-foreground">Carregando…</p>
        ) : thread.error ? (
          <p className="text-sm text-destructive">{friendlyError(thread.error)}</p>
        ) : count === 0 ? (
          <p className="m-auto max-w-xs text-center text-sm text-muted-foreground">
            Nenhuma mensagem ainda. As conversas com {contact.name} aparecem aqui, enviadas pelo CRM ou pelo celular.
          </p>
        ) : (
          thread.data!.map((m) => {
            const p = m.payload as WaPayload
            const out = m.type === 'whatsapp_out'
            return (
              <div key={m.id} className={cn('flex max-w-[85%] flex-col', out ? 'self-end items-end' : 'self-start items-start')}>
                <p
                  className={cn(
                    'rounded-xl px-3 py-2 text-sm whitespace-pre-line',
                    out ? 'rounded-br-sm bg-primary text-primary-foreground' : 'rounded-bl-sm bg-card text-foreground',
                  )}
                >
                  {p.text || '[mensagem]'}
                </p>
                <span className="mt-0.5 px-1 text-[11px] text-muted-foreground">
                  {time.format(new Date(m.occurred_at)).replace('.', '')}
                  {out && (p.sent_via === 'crm' && m.actor ? ` · ${profileLabel(m.actor)}` : p.sent_via === 'phone' ? ' · pelo celular' : '')}
                  {!out && p.push_name ? ` · ${p.push_name}` : ''}
                </span>
              </div>
            )
          })
        )}
        <div ref={endRef} />
      </div>

      <form
        className="flex items-end gap-2 border-t border-border p-3"
        onSubmit={(e) => {
          e.preventDefault()
          submit()
        }}
      >
        <Textarea
          aria-label={`Mensagem para ${contact.name}`}
          placeholder={contact.phone ? 'Escreva a mensagem… (Ctrl+Enter envia)' : 'Cadastre o telefone do contato para enviar'}
          rows={2}
          value={text}
          disabled={!contact.phone}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
              e.preventDefault()
              submit()
            }
          }}
          className="min-h-10 flex-1 bg-background"
        />
        <Button type="submit" disabled={!contact.phone || !text.trim() || send.isPending} aria-label="Enviar mensagem">
          <Send aria-hidden /> {send.isPending ? 'Enviando…' : 'Enviar'}
        </Button>
      </form>
    </section>
  )
}
