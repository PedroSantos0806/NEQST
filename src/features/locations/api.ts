import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/errors'
import type { Tables, TablesInsert } from '@/types/database'

export type Location = Tables<'locations'>
export type LocationListItem = Location & { company: { id: string; name: string } | null }

export function useLocations(filter: { companyId?: string } = {}) {
  return useQuery({
    queryKey: ['locations', filter],
    queryFn: async () => {
      let q = supabase.from('locations').select('*, company:companies(id, name)').order('name')
      if (filter.companyId) q = q.eq('company_id', filter.companyId)
      return unwrap(await q) as LocationListItem[]
    },
  })
}

export function useSaveLocation() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ id, values }: { id?: string; values: TablesInsert<'locations'> }) => {
      const query = id
        ? supabase.from('locations').update(values).eq('id', id)
        : supabase.from('locations').insert(values)
      return unwrap(await query.select().single())
    },
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['locations'] })
      qc.invalidateQueries({ queryKey: ['companies'] })
    },
  })
}

export function useDeleteLocation() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: string) => unwrap(await supabase.from('locations').delete().eq('id', id)),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['locations'] })
      qc.invalidateQueries({ queryKey: ['companies'] })
    },
  })
}
