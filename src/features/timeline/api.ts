import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/errors'
import type { Enums, Tables } from '@/types/database'

export type TimelineEvent = Tables<'timeline_events'> & {
  actor: { full_name: string | null; email: string | null } | null
}

export function useTimeline(entity: Enums<'timeline_entity'>, entityId: string | undefined) {
  return useQuery({
    queryKey: ['timeline', entity, entityId],
    enabled: !!entityId,
    queryFn: async () =>
      unwrap(
        await supabase
          .from('timeline_events')
          .select('*, actor:profiles(full_name, email)')
          .eq('entity', entity)
          .eq('entity_id', entityId!)
          .order('occurred_at', { ascending: false })
          .limit(200),
      ) as TimelineEvent[],
  })
}
