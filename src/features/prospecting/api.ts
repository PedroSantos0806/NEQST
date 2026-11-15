import { useEffect } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { FunctionsHttpError } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/errors'
import type { Enums, Tables } from '@/types/database'

export type Prospect = Tables<'prospects'>
export type ProspectResearch = Tables<'prospect_research'>
export type ProspectStatus = Enums<'prospect_status'>
export type DossierItem = { title: string; detail?: string }
export type DecisionMaker = { name?: string; role: string; how_to_reach?: string }
export type Source = { uri: string; title: string }

export const PROSPECT_STATUS_LABEL: Record<ProspectStatus, string> = {
  new: 'Novo',
  researching: 'Pesquisando…',
  researched: 'Pesquisado',
  qualified: 'Qualificado',
  discarded: 'Descartado',
}

/** Erros das Edge Functions vêm no corpo `{ error }`. */
async function invoke<T>(name: string, body: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.functions.invoke(name, { body })
  if (error) {
    if (error instanceof FunctionsHttpError) {
      const payload = await error.context.json().catch(() => null)
      throw new Error(payload?.error ?? error.message)
    }
    throw error
  }
  return data as T
}

export type ProspectListItem = Prospect & { research: Pick<ProspectResearch, 'score' | 'created_at'>[] }

export function useProspects() {
  return useQuery({
    queryKey: ['prospects'],
    queryFn: async () =>
      unwrap(
        await supabase
          .from('prospects')
          .select('*, research:prospect_research(score, created_at)')
          .order('created_at', { ascending: false })
          .order('created_at', { referencedTable: 'prospect_research', ascending: false })
          .limit(500),
      ) as ProspectListItem[],
  })
}

/** Dossiê mais recente do lead. */
export function useLatestResearch(prospectId: string | undefined) {
  return useQuery({
    queryKey: ['prospect_research', prospectId],
    enabled: !!prospectId,
    queryFn: async () =>
      unwrap(
        await supabase
          .from('prospect_research')
          .select('*')
          .eq('prospect_id', prospectId!)
          .order('created_at', { ascending: false })
          .limit(1)
          .maybeSingle(),
      ),
  })
}

export function useProspectSearch() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (v: { query: string; city: string; company_type: Enums<'company_type'> | null }) =>
      invoke<{ found: number; new: number }>('prospect-search', v),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['prospects'] }),
  })
}

export function useResearchProspect() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (prospectId: string) => invoke<{ research_id: string }>('prospect-research', { prospect_id: prospectId }),
    onMutate: (prospectId) => {
      qc.setQueryData<ProspectListItem[]>(['prospects'], (old) =>
        old?.map((p) => (p.id === prospectId ? { ...p, status: 'researching' } : p)),
      )
    },
    onSettled: (_d, _e, prospectId) => {
      qc.invalidateQueries({ queryKey: ['prospects'] })
      qc.invalidateQueries({ queryKey: ['prospect_research', prospectId] })
    },
  })
}

export function useDiscardProspect() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (v: { id: string; reason: string }) =>
      unwrap(await supabase.from('prospects').update({ status: 'discarded', discard_reason: v.reason }).eq('id', v.id)),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['prospects'] }),
  })
}

export function useRestoreProspect() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (p: Pick<Prospect, 'id'> & { hasResearch: boolean }) =>
      unwrap(
        await supabase
          .from('prospects')
          .update({ status: p.hasResearch ? 'researched' : 'new', discard_reason: null })
          .eq('id', p.id),
      ),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['prospects'] }),
  })
}

export function useQualifyProspect() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (v: {
      prospectId: string
      pipelineId: string
      companyId: string | null
      companyType: Enums<'company_type'> | null
    }) =>
      unwrap(
        await supabase.rpc('qualify_prospect', {
          p_prospect_id: v.prospectId,
          p_pipeline_id: v.pipelineId,
          p_company_id: v.companyId ?? undefined,
          p_company_type: v.companyType ?? undefined,
        }),
      ) as string,
    onSuccess: () => {
      for (const key of ['prospects', 'companies', 'locations', 'board', 'deals-table']) qc.invalidateQueries({ queryKey: [key] })
    },
  })
}

/** Outro usuário pesquisou/qualificou → a fila atualiza sozinha. */
export function useProspectsRealtime() {
  const qc = useQueryClient()
  useEffect(() => {
    const channel = supabase
      .channel('prospects')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'prospects' }, () => {
        qc.invalidateQueries({ queryKey: ['prospects'] })
        qc.invalidateQueries({ queryKey: ['prospect_research'] })
      })
      .subscribe()
    return () => {
      void supabase.removeChannel(channel)
    }
  }, [qc])
}

/** Cor da nota de aderência (0–100). */
export function scoreClass(score: number | null | undefined) {
  if (score == null) return 'bg-muted text-muted-foreground'
  if (score >= 70) return 'bg-sage/40 text-ink'
  if (score >= 40) return 'bg-ochre/30 text-ink'
  return 'bg-destructive/15 text-destructive'
}
