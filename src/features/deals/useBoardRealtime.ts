import { useEffect } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { supabase } from '@/lib/supabase'

/**
 * Realtime do quadro: qualquer mudança em negócios, locais do negócio ou atividades
 * de outro usuário invalida o quadro (o refetch traz os dados já com RLS aplicado).
 */
export function useBoardRealtime() {
  const qc = useQueryClient()
  useEffect(() => {
    let timer: ReturnType<typeof setTimeout> | undefined
    const refresh = () => {
      clearTimeout(timer)
      timer = setTimeout(() => {
        qc.invalidateQueries({ queryKey: ['board'] })
        qc.invalidateQueries({ queryKey: ['deals-table'] })
        qc.invalidateQueries({ queryKey: ['activities'] })
      }, 150)
    }
    const channel = supabase
      .channel('board')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'deals' }, refresh)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'deal_locations' }, refresh)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'activities' }, refresh)
      .subscribe()
    return () => {
      clearTimeout(timer)
      void supabase.removeChannel(channel)
    }
  }, [qc])
}
