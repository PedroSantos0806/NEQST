import { useEffect } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/errors'
import type { Tables } from '@/types/database'

export type InboundEvent = Tables<'inbound_events'> & { contact: { id: string; name: string } | null }
export type InboundTokens = { site_token: string; google_key: string; meta_verify_token: string; evolution_token: string }

export const inboundUrl = (source: string) => `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/inbound/${source}`

/** Tokens dos webhooks (só admin; o banco recusa os demais). */
export function useInboundTokens() {
  return useQuery({
    queryKey: ['inbound-tokens'],
    retry: false,
    staleTime: Infinity,
    queryFn: async () => unwrap(await supabase.rpc('inbound_settings')) as unknown as InboundTokens,
  })
}

export function useInboundEvents() {
  return useQuery({
    queryKey: ['inbound-events'],
    queryFn: async () =>
      unwrap(
        await supabase
          .from('inbound_events')
          .select('*, contact:contacts(id, name)')
          .order('received_at', { ascending: false })
          .limit(100),
      ) as InboundEvent[],
  })
}

export function useReprocessEvent() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: string) => unwrap(await supabase.rpc('reprocess_inbound_event', { p_event_id: id })),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: ['inbound-events'] })
      qc.invalidateQueries({ queryKey: ['contacts'] })
    },
  })
}

export function useInboundRealtime() {
  const qc = useQueryClient()
  useEffect(() => {
    const channel = supabase
      .channel('inbound-events')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'inbound_events' }, () => {
        qc.invalidateQueries({ queryKey: ['inbound-events'] })
        qc.invalidateQueries({ queryKey: ['contacts'] })
      })
      .subscribe()
    return () => {
      void supabase.removeChannel(channel)
    }
  }, [qc])
}
