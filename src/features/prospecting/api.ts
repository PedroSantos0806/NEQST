import { useEffect } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { FunctionsHttpError } from '@supabase/supabase-js'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/errors'
import type { Enums, Tables, TablesInsert } from '@/types/database'
import { dedupeKey, searchOsmAndSave } from './osm'

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

export type SearchResult = { found: number; new: number; source: 'google_places' | 'gemini_search' | 'openstreetmap' }

/**
 * Busca de leads. O servidor usa Google Places ou Gemini quando configurados;
 * senão devolve `delegate: 'openstreetmap'` e a busca grátis roda aqui no navegador.
 */
export function useProspectSearch(onStatus?: (msg: string | null) => void) {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (v: { query: string; city: string; company_type: Enums<'company_type'> | null }): Promise<SearchResult> => {
      const r = await invoke<{ found?: number; new?: number; source?: SearchResult['source']; delegate?: 'openstreetmap' }>(
        'prospect-search',
        v,
      )
      if (r.delegate === 'openstreetmap') {
        const res = await searchOsmAndSave(v, (msg) => onStatus?.(msg))
        return { ...res, source: 'openstreetmap' }
      }
      return { found: r.found ?? 0, new: r.new ?? 0, source: r.source ?? 'google_places' }
    },
    onSettled: () => {
      onStatus?.(null)
      qc.invalidateQueries({ queryKey: ['prospects'] })
    },
  })
}

/** Lead cadastrado à mão (indicação, evento, lista). */
export function useAddProspect() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (v: Omit<TablesInsert<'prospects'>, 'dedupe_key' | 'source'> & { source?: 'manual' | 'import' }) => {
      const key = dedupeKey(v.name, v.city ?? '')
      const { data: dup } = await supabase.from('prospects').select('id, status').eq('dedupe_key', key).maybeSingle()
      if (dup) throw new Error('Este lead já está na prospecção (mesmo nome e cidade).')
      return unwrap(
        await supabase
          .from('prospects')
          .insert({ ...v, source: v.source ?? 'manual', dedupe_key: key })
          .select('id')
          .single(),
      ) as { id: string }
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: ['prospects'] }),
  })
}

/** Importa linhas de planilha, pulando quem já está na fila. */
export function useImportProspects() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (rows: Omit<TablesInsert<'prospects'>, 'dedupe_key' | 'source'>[]) => {
      const withKeys = rows.map((r) => ({ ...r, source: 'import', dedupe_key: dedupeKey(r.name, r.city ?? '') }))
      const unique = [...new Map(withKeys.map((r) => [r.dedupe_key, r])).values()]
      const existing = new Set<string>()
      for (let i = 0; i < unique.length; i += 200) {
        const { data } = await supabase
          .from('prospects')
          .select('dedupe_key')
          .in('dedupe_key', unique.slice(i, i + 200).map((r) => r.dedupe_key))
        for (const r of data ?? []) if (r.dedupe_key) existing.add(r.dedupe_key)
      }
      const fresh = unique.filter((r) => !existing.has(r.dedupe_key))
      for (let i = 0; i < fresh.length; i += 200) unwrap(await supabase.from('prospects').insert(fresh.slice(i, i + 200)))
      return { total: rows.length, inserted: fresh.length, skipped: rows.length - fresh.length }
    },
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
