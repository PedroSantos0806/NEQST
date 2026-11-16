import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/errors'
import type { Enums, Tables, TablesInsert } from '@/types/database'

export type Stage = Tables<'stages'>
export type Pipeline = Tables<'pipelines'> & { stages: Stage[] }

export type BoardDeal = Pick<
  Tables<'deals'>,
  | 'id'
  | 'title'
  | 'pipeline_id'
  | 'stage_id'
  | 'position'
  | 'value'
  | 'court_count'
  | 'price_per_court'
  | 'expected_close_date'
  | 'stage_entered_at'
  | 'owner_id'
  | 'company_id'
  | 'status'
  | 'custom'
> & {
  company: { id: string; name: string } | null
  owner: { full_name: string | null; email: string | null; avatar_url: string | null } | null
  deal_locations: { location: { id: string; name: string } | null }[]
  deal_contacts: { contact_id: string; role: Enums<'deal_contact_role'> | null }[]
  activities: { id: string; title: string; type: Enums<'activity_type'>; due_at: string | null }[]
}

export const boardKey = (pipelineId: string | undefined) => ['board', pipelineId] as const

export function usePipelines() {
  return useQuery({
    queryKey: ['pipelines'],
    staleTime: 10 * 60_000,
    queryFn: async () =>
      unwrap(
        await supabase
          .from('pipelines')
          .select('*, stages(*)')
          .order('sort_order')
          .order('sort_order', { referencedTable: 'stages' }),
      ) as Pipeline[],
  })
}

export function useLostReasons() {
  return useQuery({
    queryKey: ['lost_reasons'],
    staleTime: 10 * 60_000,
    queryFn: async () =>
      unwrap(await supabase.from('lost_reasons').select('id, name').eq('active', true).order('sort_order')),
  })
}

const BOARD_SELECT = `
  id, title, pipeline_id, stage_id, position, value, court_count, price_per_court,
  expected_close_date, stage_entered_at, owner_id, company_id, status, custom,
  company:companies(id, name),
  owner:profiles(full_name, email, avatar_url),
  deal_locations(location:locations(id, name)),
  deal_contacts(contact_id, role),
  activities(id, title, type, due_at)
`

/** Negócios abertos de um funil, com a próxima atividade em aberto de cada um. */
export function useBoard(pipelineId: string | undefined) {
  return useQuery({
    queryKey: boardKey(pipelineId),
    enabled: !!pipelineId,
    queryFn: async () =>
      unwrap(
        await supabase
          .from('deals')
          .select(BOARD_SELECT)
          .eq('pipeline_id', pipelineId!)
          .eq('status', 'open')
          .is('activities.done_at', null)
          .order('position')
          .order('due_at', { referencedTable: 'activities', ascending: true, nullsFirst: false }),
      ) as unknown as BoardDeal[],
  })
}

/** Move o card: grava etapa + posição. */
export function useMoveDeal(pipelineId: string | undefined) {
  const qc = useQueryClient()
  const key = boardKey(pipelineId)
  return useMutation({
    mutationFn: async (v: { id: string; stage_id: string; position: number }) =>
      unwrap(await supabase.from('deals').update({ stage_id: v.stage_id, position: v.position }).eq('id', v.id)),
    // O update otimista é feito de forma síncrona na tela (BoardPage.onMove), com rollback no onError dela.
    onSettled: () => qc.invalidateQueries({ queryKey: key }),
  })
}

export function useCloseDeal() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (
      v:
        | { id: string; status: 'won' }
        | { id: string; status: 'lost'; lost_reason_id: string; lost_note: string | null },
    ) => unwrap(await supabase.from('deals').update(v).eq('id', v.id)),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['board'] })
      qc.invalidateQueries({ queryKey: ['deals'] })
      qc.invalidateQueries({ queryKey: ['timeline'] })
    },
  })
}

export type DealDetail = Tables<'deals'> & {
  deal_locations: { location_id: string }[]
  deal_contacts: { contact_id: string; role: Enums<'deal_contact_role'> | null }[]
}

export function useDeal(id: string | undefined) {
  return useQuery({
    queryKey: ['deals', id],
    enabled: !!id,
    queryFn: async () =>
      unwrap(
        await supabase
          .from('deals')
          .select('*, deal_locations(location_id), deal_contacts(contact_id, role)')
          .eq('id', id!)
          .single(),
      ) as DealDetail,
  })
}

export type SaveDealInput = {
  id?: string
  values: TablesInsert<'deals'>
  locationIds: string[]
  contacts: { contact_id: string; role: Enums<'deal_contact_role'> | null }[]
}

/** Salva o negócio e sincroniza locais e contatos. */
export function useSaveDeal() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ id, values, locationIds, contacts }: SaveDealInput) => {
      const deal = unwrap(
        await (id ? supabase.from('deals').update(values).eq('id', id) : supabase.from('deals').insert(values))
          .select('id')
          .single(),
      ) as { id: string }

      // Locais
      const currentLocs = unwrap(await supabase.from('deal_locations').select('location_id').eq('deal_id', deal.id))
      const curLocIds = (currentLocs ?? []).map((r) => r.location_id)
      const removeLocs = curLocIds.filter((l) => !locationIds.includes(l))
      const addLocs = locationIds.filter((l) => !curLocIds.includes(l))
      if (removeLocs.length)
        unwrap(await supabase.from('deal_locations').delete().eq('deal_id', deal.id).in('location_id', removeLocs))
      if (addLocs.length)
        unwrap(await supabase.from('deal_locations').insert(addLocs.map((location_id) => ({ deal_id: deal.id, location_id }))))

      // Contatos (upsert mantém o papel atualizado)
      const currentContacts = unwrap(await supabase.from('deal_contacts').select('contact_id').eq('deal_id', deal.id))
      const keep = contacts.map((c) => c.contact_id)
      const removeContacts = (currentContacts ?? []).map((r) => r.contact_id).filter((c) => !keep.includes(c))
      if (removeContacts.length)
        unwrap(await supabase.from('deal_contacts').delete().eq('deal_id', deal.id).in('contact_id', removeContacts))
      if (contacts.length)
        unwrap(
          await supabase
            .from('deal_contacts')
            .upsert(contacts.map((c) => ({ deal_id: deal.id, ...c })), { onConflict: 'deal_id,contact_id' }),
        )

      return deal
    },
    onSuccess: (deal) => {
      qc.invalidateQueries({ queryKey: ['board'] })
      qc.invalidateQueries({ queryKey: ['deals', deal.id] })
    },
  })
}

/** Posição fracionária: média entre os vizinhos (ou ±1000 nas pontas). */
export function positionBetween(before: number | undefined, after: number | undefined) {
  if (before == null && after == null) return 1000
  if (before == null) return after! - 1000
  if (after == null) return before + 1000
  return (before + after) / 2
}

export type DealFull = Tables<'deals'> & {
  company: { id: string; name: string } | null
  owner: { full_name: string | null; email: string | null } | null
  lost_reason: { name: string } | null
  deal_locations: { location: { id: string; name: string; court_count: number | null } | null }[]
  deal_contacts: {
    role: Enums<'deal_contact_role'> | null
    contact: { id: string; name: string; email: string | null; phone: string | null; job_title: string | null } | null
  }[]
}

/** Negócio com tudo que a ficha mostra. */
export function useDealFull(id: string | undefined) {
  return useQuery({
    queryKey: ['deals', id, 'full'],
    enabled: !!id,
    queryFn: async () =>
      unwrap(
        await supabase
          .from('deals')
          .select(
            `*, company:companies(id, name), owner:profiles(full_name, email), lost_reason:lost_reasons(name),
             deal_locations(location:locations(id, name, court_count)),
             deal_contacts(role, contact:contacts(id, name, email, phone, job_title))`,
          )
          .eq('id', id!)
          .maybeSingle(),
      ) as DealFull | null,
  })
}

/** Muda só a etapa (ficha do negócio). */
export function useSetStage() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (v: { id: string; stage_id: string }) =>
      unwrap(await supabase.from('deals').update({ stage_id: v.stage_id }).eq('id', v.id)),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: ['deals'] })
      qc.invalidateQueries({ queryKey: ['board'] })
      qc.invalidateQueries({ queryKey: ['timeline'] })
    },
  })
}

export function useReopenDeal() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: string) => unwrap(await supabase.from('deals').update({ status: 'open' }).eq('id', id)),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['deals'] })
      qc.invalidateQueries({ queryKey: ['board'] })
      qc.invalidateQueries({ queryKey: ['timeline'] })
    },
  })
}

/** Vista tabela: negócios de um funil por situação (inclui ganhos/perdidos). */
export function useDealsTable(pipelineId: string | undefined, status: Enums<'deal_status'> | 'all') {
  return useQuery({
    queryKey: ['deals-table', pipelineId, status],
    enabled: !!pipelineId,
    queryFn: async () => {
      let q = supabase
        .from('deals')
        .select(BOARD_SELECT)
        .eq('pipeline_id', pipelineId!)
        .is('activities.done_at', null)
        .order('updated_at', { ascending: false })
        .order('due_at', { referencedTable: 'activities', ascending: true, nullsFirst: false })
      if (status !== 'all') q = q.eq('status', status)
      return unwrap(await q) as unknown as BoardDeal[]
    },
  })
}

/** Negócios abertos (todos os funis) sem nenhuma atividade em aberto. */
export function useDealsWithoutNext() {
  return useQuery({
    queryKey: ['deals-table', 'without-next'],
    queryFn: async () => {
      const rows = unwrap(
        await supabase
          .from('deals')
          .select('id, title, pipeline_id, company:companies(name), activities(id)')
          .eq('status', 'open')
          .is('activities.done_at', null),
      ) as unknown as { id: string; title: string; pipeline_id: string; company: { name: string } | null; activities: { id: string }[] }[]
      return rows.filter((r) => r.activities.length === 0)
    },
  })
}
