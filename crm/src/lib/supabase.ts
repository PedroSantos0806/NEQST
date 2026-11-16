import { createClient } from '@supabase/supabase-js'
import type { Database } from '@/types/database'

const url = import.meta.env.VITE_SUPABASE_URL
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

if (!url || !anonKey) {
  throw new Error('Defina VITE_SUPABASE_URL e VITE_SUPABASE_ANON_KEY no .env.local (veja .env.example).')
}

export const supabase = createClient<Database>(url, anonKey, {
  // 'implicit': links de convite gerados pelo painel/admin voltam com tokens no hash,
  // que o fluxo 'pkce' rejeita ("Not a valid PKCE flow url").
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, flowType: 'implicit' },
})
