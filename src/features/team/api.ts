import { useQuery } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'
import { unwrap } from '@/lib/errors'

export function useProfiles() {
  return useQuery({
    queryKey: ['profiles'],
    staleTime: 5 * 60_000,
    queryFn: async () =>
      unwrap(await supabase.from('profiles').select('id, full_name, email, avatar_url').order('full_name')),
  })
}
