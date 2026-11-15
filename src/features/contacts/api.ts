import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/errors'
import type { Tables, TablesInsert } from '@/types/database'

export type Contact = Tables<'contacts'>
export type ContactListItem = Contact & {
  company: { id: string; name: string } | null
  owner: { full_name: string | null; email: string | null } | null
}

export function useContacts({ enabled = true, ...filter }: { companyId?: string; enabled?: boolean } = {}) {
  return useQuery({
    queryKey: ['contacts', filter],
    enabled,
    queryFn: async () => {
      let q = supabase
        .from('contacts')
        .select('*, company:companies(id, name), owner:profiles(full_name, email)')
        .order('name')
      if (filter.companyId) q = q.eq('company_id', filter.companyId)
      return unwrap(await q) as ContactListItem[]
    },
  })
}

export function useSaveContact() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ id, values }: { id?: string; values: TablesInsert<'contacts'> }) => {
      const query = id
        ? supabase.from('contacts').update(values).eq('id', id)
        : supabase.from('contacts').insert(values)
      return unwrap(await query.select().single())
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['contacts'] })
      qc.invalidateQueries({ queryKey: ['companies'] })
    },
  })
}

export function useDeleteContact() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: string) => unwrap(await supabase.from('contacts').delete().eq('id', id)),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['contacts'] })
      qc.invalidateQueries({ queryKey: ['companies'] })
    },
  })
}
