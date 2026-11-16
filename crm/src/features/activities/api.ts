import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/errors'
import type { Tables, TablesInsert } from '@/types/database'

export type Activity = Tables<'activities'>
export type ActivityItem = Activity & {
  deal: { id: string; title: string; status: Tables<'deals'>['status'] } | null
  company: { id: string; name: string } | null
  owner: { full_name: string | null; email: string | null } | null
}

const SELECT = '*, deal:deals(id, title, status), company:companies(id, name), owner:profiles(full_name, email)'

/** Atividades de um negócio (abertas primeiro, por data; depois concluídas). */
export function useDealActivities(dealId: string | undefined) {
  return useQuery({
    queryKey: ['activities', { dealId }],
    enabled: !!dealId,
    queryFn: async () =>
      unwrap(
        await supabase
          .from('activities')
          .select(SELECT)
          .eq('deal_id', dealId!)
          .order('done_at', { ascending: false, nullsFirst: true })
          .order('due_at', { ascending: true, nullsFirst: false }),
      ) as ActivityItem[],
  })
}

/** Tarefas em aberto (de um dono ou de todos) + concluídas nos últimos 7 dias. */
export function useTasks(ownerId: string | null) {
  return useQuery({
    queryKey: ['activities', { ownerId }],
    queryFn: async () => {
      const since = new Date(Date.now() - 7 * 86_400_000).toISOString()
      let q = supabase
        .from('activities')
        .select(SELECT)
        .or(`done_at.is.null,done_at.gte.${since}`)
        .order('due_at', { ascending: true, nullsFirst: false })
        .limit(500)
      if (ownerId) q = q.eq('owner_id', ownerId)
      return unwrap(await q) as ActivityItem[]
    },
  })
}

function useInvalidateActivities() {
  const qc = useQueryClient()
  return () => {
    qc.invalidateQueries({ queryKey: ['activities'] })
    qc.invalidateQueries({ queryKey: ['board'] })
    qc.invalidateQueries({ queryKey: ['deals-table'] })
    qc.invalidateQueries({ queryKey: ['timeline'] })
  }
}

export function useSaveActivity() {
  const invalidate = useInvalidateActivities()
  return useMutation({
    mutationFn: async ({ id, values }: { id?: string; values: TablesInsert<'activities'> }) =>
      unwrap(
        await (id ? supabase.from('activities').update(values).eq('id', id) : supabase.from('activities').insert(values))
          .select()
          .single(),
      ) as Activity,
    onSuccess: invalidate,
  })
}

/**
 * Concluir/reabrir. Devolve se o negócio ficou sem nenhuma atividade aberta
 * (para pedir a próxima atividade).
 */
export function useToggleActivity() {
  const invalidate = useInvalidateActivities()
  return useMutation({
    mutationFn: async ({ activity, done }: { activity: Pick<Activity, 'id' | 'deal_id'>; done: boolean }) => {
      unwrap(
        await supabase
          .from('activities')
          .update({ done_at: done ? new Date().toISOString() : null })
          .eq('id', activity.id),
      )
      if (!done || !activity.deal_id) return { dealWithoutNext: null as string | null }
      const { count, error } = await supabase
        .from('activities')
        .select('id', { count: 'exact', head: true })
        .eq('deal_id', activity.deal_id)
        .is('done_at', null)
      if (error) throw error
      const { data: deal } = await supabase.from('deals').select('status').eq('id', activity.deal_id).single()
      return { dealWithoutNext: count === 0 && deal?.status === 'open' ? activity.deal_id : null }
    },
    onSuccess: invalidate,
  })
}

export function useDeleteActivity() {
  const invalidate = useInvalidateActivities()
  return useMutation({
    mutationFn: async (id: string) => unwrap(await supabase.from('activities').delete().eq('id', id)),
    onSuccess: invalidate,
  })
}
