import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2'

export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

export function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

export class HttpError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message)
  }
}

export function requireEnv(name: string): string {
  const v = Deno.env.get(name)
  if (!v) throw new HttpError(500, `Secret ${name} não configurado nas Edge Functions.`)
  return v
}

/**
 * Cliente Supabase com o JWT de quem chamou: tudo respeita RLS e
 * auth.uid() funciona nos defaults/triggers (created_by, actor_id...).
 */
export async function userClient(req: Request): Promise<SupabaseClient> {
  const auth = req.headers.get('Authorization')
  if (!auth) throw new HttpError(401, 'Não autenticado')
  const client = createClient(requireEnv('SUPABASE_URL'), requireEnv('SUPABASE_ANON_KEY'), {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false },
  })
  const { data, error } = await client.auth.getUser()
  if (error || !data.user) throw new HttpError(401, 'Sessão inválida')
  return client
}

/** Envolve o handler com CORS, preflight e tratamento de erro padrão. */
export function serve(handler: (req: Request) => Promise<Response>) {
  Deno.serve(async (req) => {
    if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
    if (req.method !== 'POST') return json({ error: 'Use POST' }, 405)
    try {
      return await handler(req)
    } catch (err) {
      const status = err instanceof HttpError ? err.status : 500
      const message = err instanceof Error ? err.message : String(err)
      console.error(message)
      return json({ error: message }, status)
    }
  })
}
