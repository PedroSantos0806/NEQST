// Entrada de leads: POST /functions/v1/inbound/{source}
//   site | webhook → header x-neqst-token (token no Vault: inbound_site_token)
//   google         → Google Ads lead form webhook; valida google_key (Vault: inbound_google_key); is_test fica à parte
//   meta           → GET verificação (hub.challenge, Vault: inbound_meta_verify_token);
//                    POST leadgen (assinatura X-Hub-Signature-256 com META_APP_SECRET) e busca o lead no Graph API (META_PAGE_TOKEN)
// Fluxo: grava o payload bruto em inbound_events → normaliza → process_inbound_event (idempotente, no banco).
// Deploy com --no-verify-jwt: quem chama são sistemas externos; a autenticação é o token/assinatura acima.
import { createClient } from 'npm:@supabase/supabase-js@2'

type Source = 'site' | 'webhook' | 'google' | 'meta' | 'evolution'
type Normalized = Record<string, string | null>

const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false },
})

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'content-type, x-neqst-token',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
}
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })

// ---------------------------------------------------------------------------
// Utilidades
// ---------------------------------------------------------------------------
async function secret(name: string): Promise<string> {
  const { data, error } = await db.rpc('inbound_secret', { p_name: name })
  if (error || !data) throw new Error(`Token ${name} indisponível`)
  return data as string
}

/** Comparação em tempo constante. */
function safeEqual(a: string, b: string) {
  const x = new TextEncoder().encode(a)
  const y = new TextEncoder().encode(b)
  if (x.length !== y.length) return false
  let diff = 0
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i]
  return diff === 0
}

async function hmacSha256Hex(key: string, body: string) {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(key), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const sig = await crypto.subtle.sign('HMAC', k, new TextEncoder().encode(body))
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, '0')).join('')
}

function phoneE164(v: unknown) {
  const raw = String(v ?? '').trim()
  const digits = raw.replace(/\D/g, '')
  if (digits.length < 10) return null
  if (raw.startsWith('+')) return `+${digits}`
  if (digits.length === 10 || digits.length === 11) return `+55${digits}`
  if ((digits.length === 12 || digits.length === 13) && digits.startsWith('55')) return `+${digits}`
  return null
}

const str = (v: unknown) => {
  const s = Array.isArray(v) ? v[0] : v
  const t = typeof s === 'string' ? s.trim() : typeof s === 'number' ? String(s) : ''
  return t || null
}

/** Pega o primeiro campo presente entre vários nomes possíveis (pt/en). */
function pick(o: Record<string, unknown>, ...keys: string[]) {
  for (const k of keys) {
    const v = str(o[k])
    if (v) return v
  }
  return null
}

function normalizeGeneric(o: Record<string, unknown>): Normalized {
  const first = pick(o, 'first_name', 'primeiro_nome')
  const last = pick(o, 'last_name', 'sobrenome')
  return {
    name: pick(o, 'name', 'nome', 'full_name', 'nome_completo') ?? ([first, last].filter(Boolean).join(' ') || null),
    email: pick(o, 'email', 'e-mail', 'work_email')?.toLowerCase() ?? null,
    phone: phoneE164(pick(o, 'phone', 'telefone', 'whatsapp', 'celular', 'phone_number', 'work_phone')),
    company: pick(o, 'company', 'empresa', 'company_name', 'organizacao'),
    job_title: pick(o, 'job_title', 'cargo', 'title'),
    city: pick(o, 'city', 'cidade'),
    message: pick(o, 'message', 'mensagem', 'comentario', 'observacoes'),
    form: pick(o, 'form', 'formulario', 'form_name', 'page'),
    campaign: pick(o, 'campaign', 'campanha'),
    utm_source: pick(o, 'utm_source'),
    utm_medium: pick(o, 'utm_medium'),
    utm_campaign: pick(o, 'utm_campaign'),
    utm_term: pick(o, 'utm_term'),
    utm_content: pick(o, 'utm_content'),
  }
}

async function readBody(req: Request): Promise<{ raw: string; data: Record<string, unknown> }> {
  const raw = await req.text()
  const type = req.headers.get('content-type') ?? ''
  if (type.includes('application/x-www-form-urlencoded')) {
    return { raw, data: Object.fromEntries(new URLSearchParams(raw)) }
  }
  try {
    return { raw, data: raw ? JSON.parse(raw) : {} }
  } catch {
    throw new HttpError(400, 'Corpo inválido: envie JSON ou formulário (x-www-form-urlencoded).')
  }
}

class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message)
  }
}

/**
 * Grava o evento bruto (idempotente por source + external_id) e processa.
 * Reenvio do mesmo lead não duplica: devolve o evento existente.
 */
async function ingest(source: Source, payload: unknown, normalized: Normalized, opts: { externalId?: string | null; isTest?: boolean; skipProcess?: boolean } = {}) {
  const row = {
    source: source === 'site' ? 'site' : source,
    external_id: opts.externalId ?? null,
    payload,
    normalized,
    is_test: !!opts.isTest,
    status: opts.isTest ? 'ignored' : 'pending',
  }
  let eventId: string
  const { data, error } = await db.from('inbound_events').insert(row).select('id').single()
  if (error) {
    if (error.code !== '23505' || !opts.externalId) throw error
    const { data: existing } = await db
      .from('inbound_events')
      .select('id')
      .eq('source', row.source)
      .eq('external_id', opts.externalId)
      .single()
    eventId = existing!.id
  } else {
    eventId = data.id
  }
  if (opts.isTest) return { event_id: eventId, status: 'ignored' as const, contact_id: null }
  if (opts.skipProcess) return { event_id: eventId, status: 'pending' as const, contact_id: null }

  const { data: contactId, error: procError } = await db.rpc('process_inbound_event', { p_event_id: eventId })
  if (procError) throw procError
  const { data: ev } = await db.from('inbound_events').select('status, error').eq('id', eventId).single()
  return { event_id: eventId, status: ev?.status, error: ev?.error ?? undefined, contact_id: contactId }
}

// ---------------------------------------------------------------------------
// Origens
// ---------------------------------------------------------------------------
async function handleGeneric(req: Request, source: 'site' | 'webhook') {
  const token = req.headers.get('x-neqst-token') ?? ''
  if (!safeEqual(token, await secret('site_token'))) throw new HttpError(401, 'Token inválido (header x-neqst-token).')
  const { data } = await readBody(req)
  const externalId = pick(data, 'external_id', 'lead_id', 'id')
  return json(await ingest(source, data, normalizeGeneric(data), { externalId }))
}

// Google Ads: https://developers.google.com/google-ads/webhook/docs/implementation
async function handleGoogle(req: Request) {
  const { data } = await readBody(req)
  if (!safeEqual(String(data.google_key ?? ''), await secret('google_key'))) throw new HttpError(401, 'google_key inválida.')
  const cols = Array.isArray(data.user_column_data) ? (data.user_column_data as { column_id?: string; column_name?: string; string_value?: string }[]) : []
  const byId: Record<string, unknown> = {}
  for (const c of cols) {
    if (c.column_id) byId[c.column_id.toLowerCase()] = c.string_value
    if (c.column_name) byId[c.column_name.toLowerCase()] = c.string_value
  }
  const normalized: Normalized = {
    ...normalizeGeneric({
      full_name: byId.full_name,
      first_name: byId.first_name,
      last_name: byId.last_name,
      email: byId.email ?? byId.work_email,
      phone_number: byId.phone_number ?? byId.work_phone,
      company_name: byId.company_name,
      job_title: byId.job_title,
      city: byId.city,
    }),
    form: str(data.form_id),
    campaign: str(data.campaign_id),
    utm_source: 'google',
    utm_medium: 'cpc',
    utm_campaign: str(data.campaign_id),
  }
  const { google_key: _omit, ...payload } = data // não guarda a chave junto com o payload
  return json(await ingest('google', payload, normalized, { externalId: str(data.lead_id), isTest: data.is_test === true }))
}

async function handleMeta(req: Request) {
  // Verificação do webhook (GET)
  if (req.method === 'GET') {
    const u = new URL(req.url)
    const mode = u.searchParams.get('hub.mode')
    const token = u.searchParams.get('hub.verify_token') ?? ''
    if (mode === 'subscribe' && safeEqual(token, await secret('meta_verify_token'))) {
      return new Response(u.searchParams.get('hub.challenge') ?? '', { status: 200, headers: cors })
    }
    return new Response('Forbidden', { status: 403, headers: cors })
  }

  const { raw, data } = await readBody(req)
  const appSecret = Deno.env.get('META_APP_SECRET')
  if (!appSecret) throw new HttpError(503, 'META_APP_SECRET não configurado.')
  const signature = (req.headers.get('x-hub-signature-256') ?? '').replace(/^sha256=/, '')
  if (!signature || !safeEqual(signature, await hmacSha256Hex(appSecret, raw))) throw new HttpError(401, 'Assinatura do Meta inválida.')

  const pageToken = Deno.env.get('META_PAGE_TOKEN')
  const results = []
  const entries = Array.isArray(data.entry) ? (data.entry as { changes?: { field?: string; value?: Record<string, unknown> }[] }[]) : []
  for (const entry of entries) {
    for (const change of entry.changes ?? []) {
      if (change.field !== 'leadgen' || !change.value) continue
      const leadgenId = str(change.value.leadgen_id)
      if (!leadgenId) continue
      // O webhook só manda o ID: o lead vem do Graph API.
      let normalized: Normalized = { form: str(change.value.form_id), campaign: str(change.value.ad_id) }
      let lead: unknown = null
      if (pageToken) {
        const res = await fetch(`https://graph.facebook.com/${encodeURIComponent(leadgenId)}?access_token=${encodeURIComponent(pageToken)}`)
        lead = await res.json()
        const fields = ((lead as { field_data?: { name: string; values: string[] }[] }).field_data ?? []).reduce(
          (acc, f) => ({ ...acc, [f.name.toLowerCase()]: f.values?.[0] }),
          {} as Record<string, unknown>,
        )
        normalized = { ...normalizeGeneric(fields), ...normalized, utm_source: 'facebook', utm_medium: 'lead_ads' }
      }
      const r = pageToken
        ? await ingest('meta', { change: change.value, lead }, normalized, { externalId: leadgenId })
        : await ingest('meta', { change: change.value }, normalized, { externalId: leadgenId, skipProcess: true }).then((x) => ({
            ...x,
            error: 'META_PAGE_TOKEN não configurado: o lead ficou na fila para reprocessar.',
          }))
      results.push(r)
    }
  }
  return json({ received: results.length, results })
}

// ---------------------------------------------------------------------------
// WhatsApp (Evolution API v2): evento messages.upsert. Token na URL (?token=) ou no header x-neqst-token.
// Só mensagens 1:1 de números que já são contatos viram timeline; grupos e status são descartados.
// ---------------------------------------------------------------------------
type WaKey = { remoteJid?: string; remoteJidAlt?: string; senderPn?: string; participantAlt?: string; fromMe?: boolean; id?: string }
type WaMessage = Record<string, Record<string, unknown> | string | undefined>
type WaData = { key?: WaKey; pushName?: string; message?: WaMessage; messageType?: string; messageTimestamp?: number | string | { low?: number } }

function waText(m: WaMessage | undefined): { text: string | null; type: string } | null {
  if (!m) return null
  const sub = (k: string) => (typeof m[k] === 'object' ? (m[k] as Record<string, unknown>) : undefined)
  if (typeof m.conversation === 'string') return { text: m.conversation, type: 'text' }
  if (sub('extendedTextMessage')) return { text: String(sub('extendedTextMessage')!.text ?? ''), type: 'text' }
  if (sub('reactionMessage') || sub('protocolMessage') || sub('senderKeyDistributionMessage')) return null // reação, apagar, chaves: não entram
  const media: [string, string][] = [
    ['imageMessage', 'imagem'],
    ['videoMessage', 'vídeo'],
    ['audioMessage', 'áudio'],
    ['documentMessage', 'documento'],
    ['stickerMessage', 'figurinha'],
    ['locationMessage', 'localização'],
    ['contactMessage', 'contato'],
  ]
  for (const [k, label] of media) {
    const s = sub(k)
    if (s) {
      const extra = str(s.caption) ?? str(s.fileName) ?? str(s.displayName)
      return { text: `[${label}]${extra ? ` ${extra}` : ''}`, type: k.replace('Message', '') }
    }
  }
  return { text: '[mensagem]', type: 'other' }
}

async function handleEvolution(req: Request) {
  const token = new URL(req.url).searchParams.get('token') ?? req.headers.get('x-neqst-token') ?? ''
  if (!safeEqual(token, await secret('evolution_token'))) throw new HttpError(401, 'Token inválido.')
  const { data } = await readBody(req)
  const event = String(data.event ?? '').toLowerCase().replace('_', '.')
  if (event !== 'messages.upsert') return json({ ignored: event || 'sem evento' })

  const items: WaData[] = Array.isArray(data.data) ? (data.data as WaData[]) : data.data ? [data.data as WaData] : []
  const results = []
  for (const d of items) {
    const key = d.key ?? {}
    const jids = [key.remoteJid, key.remoteJidAlt, key.senderPn, key.participantAlt].filter((j): j is string => !!j)
    if (jids.some((j) => j.endsWith('@g.us') || j.endsWith('@broadcast') || j.endsWith('@newsletter'))) continue // grupos, status, canais
    const content = waText(d.message)
    if (!content || !key.id) continue
    const phoneJid = jids.find((j) => j.endsWith('@s.whatsapp.net'))
    const ts = typeof d.messageTimestamp === 'object' ? d.messageTimestamp?.low : Number(d.messageTimestamp)
    const normalized: Normalized = {
      phone: phoneJid ? `+${phoneJid.split('@')[0].replace(/\D/g, '')}` : null,
      text: content.text,
      type: content.type,
      from_me: key.fromMe ? 'true' : 'false',
      wa_id: key.id,
      push_name: str(d.pushName),
      ts: ts && Number.isFinite(ts) ? String(ts) : null,
    }
    const row = { source: 'evolution', external_id: key.id, payload: { ...data, data: d }, normalized }
    const { data: ins, error } = await db.from('inbound_events').insert(row).select('id').single()
    let eventId = ins?.id as string | undefined
    if (error) {
      if (error.code !== '23505') throw error
      const { data: existing } = await db.from('inbound_events').select('id').eq('source', 'evolution').eq('external_id', key.id).single()
      eventId = existing?.id
    }
    if (!eventId) continue
    const { data: contactId } = await db.rpc('process_whatsapp_event', { p_event_id: eventId })
    results.push({ event_id: eventId, contact_id: contactId })
  }
  return json({ received: results.length, results })
}

// ---------------------------------------------------------------------------
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  const source = new URL(req.url).pathname.split('/').filter(Boolean).pop() as Source | 'inbound'
  try {
    if (source === 'meta') return await handleMeta(req)
    if (req.method !== 'POST') return json({ error: 'Use POST' }, 405)
    if (source === 'site' || source === 'webhook') return await handleGeneric(req, source)
    if (source === 'google') return await handleGoogle(req)
    if (source === 'evolution') return await handleEvolution(req)
    return json({ error: 'Use /inbound/site, /inbound/webhook, /inbound/google, /inbound/meta ou /inbound/evolution' }, 404)
  } catch (err) {
    const status = err instanceof HttpError ? err.status : 500
    const message = err instanceof Error ? err.message : String(err)
    console.error(source, message)
    return json({ error: message }, status)
  }
})
