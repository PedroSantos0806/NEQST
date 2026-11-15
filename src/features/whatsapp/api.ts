import { useEffect } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { FunctionsHttpError } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/errors'
import type { TimelineEvent } from '@/features/timeline/api'

export type WaPayload = { wa_id?: string; text?: string; type?: string; push_name?: string; sent_via?: 'crm' | 'phone'; ts?: string }

/** Conversa do contato (mensagens recebidas e enviadas), em ordem de tempo, com atualização ao vivo. */
export function useWhatsAppThread(contactId: string | undefined) {
  const qc = useQueryClient()
  useEffect(() => {
    if (!contactId) return
    const channel = supabase
      .channel(`wa-${contactId}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'timeline_events', filter: `entity_id=eq.${contactId}` }, () => {
        qc.invalidateQueries({ queryKey: ['whatsapp', contactId] })
        qc.invalidateQueries({ queryKey: ['timeline'] })
      })
      .subscribe()
    return () => {
      void supabase.removeChannel(channel)
    }
  }, [contactId, qc])

  return useQuery({
    queryKey: ['whatsapp', contactId],
    enabled: !!contactId,
    queryFn: async () => {
      const rows = unwrap(
        await supabase
          .from('timeline_events')
          .select('*, actor:profiles(full_name, email)')
          .eq('entity', 'contact')
          .eq('entity_id', contactId!)
          .in('type', ['whatsapp_in', 'whatsapp_out'])
          .order('occurred_at', { ascending: false })
          .limit(300),
      ) as TimelineEvent[]
      return rows.reverse()
    },
  })
}

export function useSendWhatsApp(contactId: string | undefined) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (text: string) => {
      const { data, error } = await supabase.functions.invoke('whatsapp-send', { body: { contact_id: contactId, text } })
      if (error) {
        if (error instanceof FunctionsHttpError) {
          const payload = await error.context.json().catch(() => null)
          throw new Error(payload?.error ?? error.message)
        }
        throw error
      }
      return data as { ok: boolean; wa_id: string | null }
    },
    onSettled: () => {
      qc.invalidateQueries({ queryKey: ['whatsapp', contactId] })
      qc.invalidateQueries({ queryKey: ['timeline'] })
    },
  })
}
