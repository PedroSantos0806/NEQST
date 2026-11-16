import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/errors'
import type { Tables } from '@/types/database'

export type Note = Tables<'notes'> & { author: { full_name: string | null; email: string | null } | null }

type Target = { dealId?: string; contactId?: string; companyId?: string }

export function useNotes(target: Target) {
  return useQuery({
    queryKey: ['notes', target],
    enabled: !!(target.dealId || target.contactId || target.companyId),
    queryFn: async () => {
      let q = supabase.from('notes').select('*, author:profiles(full_name, email)').order('created_at', { ascending: false })
      if (target.dealId) q = q.eq('deal_id', target.dealId)
      if (target.contactId) q = q.eq('contact_id', target.contactId)
      if (target.companyId) q = q.eq('company_id', target.companyId)
      return unwrap(await q) as Note[]
    },
  })
}

export function useAddNote() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (v: { body: string; deal_id?: string | null; contact_id?: string | null; company_id?: string | null }) =>
      unwrap(await supabase.from('notes').insert(v)),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['notes'] })
      qc.invalidateQueries({ queryKey: ['timeline'] })
    },
  })
}

export function useDeleteNote() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: string) => unwrap(await supabase.from('notes').delete().eq('id', id)),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['notes'] }),
  })
}
