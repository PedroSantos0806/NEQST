import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/errors'
import type { Tables, TablesInsert } from '@/types/database'

export type Company = Tables<'companies'>
export type CompanyListItem = Company & {
  owner: { full_name: string | null; email: string | null } | null
  locations: { count: number }[]
  contacts: { count: number }[]
}

export function useCompanies() {
  return useQuery({
    queryKey: ['companies'],
    queryFn: async () =>
      unwrap(
        await supabase
          .from('companies')
          .select('*, owner:profiles(full_name, email), locations(count), contacts(count)')
          .order('name'),
      ) as CompanyListItem[],
  })
}

/** Lista leve para selects (empresa de um local/contato). */
export function useCompanyOptions() {
  return useQuery({
    queryKey: ['companies', 'options'],
    queryFn: async () => unwrap(await supabase.from('companies').select('id, name, type').order('name')),
  })
}

export function useCompany(id: string | undefined) {
  return useQuery({
    queryKey: ['companies', id],
    enabled: !!id,
    queryFn: async () =>
      unwrap(
        await supabase
          .from('companies')
          .select('*, owner:profiles(full_name, email)')
          .eq('id', id!)
          .maybeSingle(),
      ),
  })
}

export function useSaveCompany() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ id, values }: { id?: string; values: TablesInsert<'companies'> }) => {
      const query = id
        ? supabase.from('companies').update(values).eq('id', id)
        : supabase.from('companies').insert(values)
      // .single() lança erro se não vier exatamente uma linha, então aqui nunca é null.
      return unwrap(await query.select().single()) as Company
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['companies'] }),
  })
}

export function useDeleteCompany() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: string) => unwrap(await supabase.from('companies').delete().eq('id', id)),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['companies'] })
      qc.invalidateQueries({ queryKey: ['locations'] })
      qc.invalidateQueries({ queryKey: ['contacts'] })
    },
  })
}
