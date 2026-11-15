// Envia WhatsApp para um contato pela Evolution API e registra na linha do tempo.
// Secrets: EVOLUTION_URL (ex.: https://evo.seudominio.com), EVOLUTION_API_KEY, EVOLUTION_INSTANCE.
import { createClient } from 'npm:@supabase/supabase-js@2'
import { HttpError, json, requireEnv, serve, userClient } from '../_shared/http.ts'

serve(async (req) => {
  const { contact_id, text } = await req.json().catch(() => ({}))
  const body = String(text ?? '').trim()
  if (!contact_id || !body) throw new HttpError(400, 'Informe o contato e a mensagem.')
  if (body.length > 4000) throw new HttpError(400, 'Mensagem longa demais (máx. 4.000 caracteres).')

  const supabase = await userClient(req)
  const { data: auth } = await supabase.auth.getUser()
  const { data: contact, error } = await supabase.from('contacts').select('id, name, phone').eq('id', contact_id).single()
  if (error || !contact) throw new HttpError(404, 'Contato não encontrado.')
  if (!contact.phone) throw new HttpError(400, 'Este contato não tem telefone.')

  const base = requireEnv('EVOLUTION_URL').replace(/\/+$/, '')
  const instance = requireEnv('EVOLUTION_INSTANCE')
  const number = contact.phone.replace(/\D/g, '')

  // v2 aceita `text`; versões que seguem o schema antigo usam `textMessage.text`. Mandamos os dois.
  const res = await fetch(`${base}/message/sendText/${encodeURIComponent(instance)}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: requireEnv('EVOLUTION_API_KEY') },
    body: JSON.stringify({ number, text: body, textMessage: { text: body } }),
    signal: AbortSignal.timeout(30_000),
  })
  const out = await res.json().catch(() => ({}))
  if (!res.ok) {
    const detail = out?.response?.message ?? out?.message ?? out?.error ?? res.statusText
    throw new HttpError(502, `Evolution: ${Array.isArray(detail) ? JSON.stringify(detail) : detail}`)
  }
  const waId: string | undefined = out?.key?.id ?? out?.data?.key?.id

  // Registra com service role (a timeline só é escrita pelo servidor). O eco do webhook cai na mesma linha (wa_id).
  const admin = createClient(requireEnv('SUPABASE_URL'), requireEnv('SUPABASE_SERVICE_ROLE_KEY'), { auth: { persistSession: false } })
  const { error: logError } = await admin.rpc('log_whatsapp', {
    p_contact: contact.id,
    p_direction: 'out',
    p_payload: {
      ...(waId ? { wa_id: waId } : {}),
      text: body,
      type: 'text',
      phone: contact.phone,
      sent_via: 'crm',
      ts: String(Math.floor(Date.now() / 1000)),
    },
    p_actor: auth.user?.id ?? null,
  })
  if (logError) throw logError

  return json({ ok: true, wa_id: waId ?? null })
})
