// Busca leads frios e grava na fila `prospects` sem duplicar.
// Fonte: Google Places (Text Search New) se GOOGLE_PLACES_API_KEY existir; senão Gemini com busca no Google.
// Secrets: GEMINI_API_KEY; opcional GOOGLE_PLACES_API_KEY, GEMINI_MODEL.
import { HttpError, json, requireEnv, serve, userClient } from '../_shared/http.ts'
import { NEQST_CONTEXT, geminiModel, searchWithGoogle, toJson, type Source } from '../_shared/gemini.ts'

const COMPANY_TYPES = ['public_operator', 'club', 'condo', 'builder', 'brand'] as const
type CompanyType = (typeof COMPANY_TYPES)[number]

const TYPE_LABEL: Record<CompanyType, string> = {
  public_operator: 'parques e espaços públicos (ou concessionárias que os administram)',
  club: 'clubes e arenas esportivas',
  condo: 'condomínios residenciais',
  builder: 'construtoras e lançamentos imobiliários',
  brand: 'marcas e empresas que patrocinam esporte',
}

type Candidate = {
  name: string
  address: string | null
  city: string
  state: string | null
  website: string | null
  phone: string | null
  google_place_id: string | null
  google_maps_uri: string | null
  rating: number | null
  rating_count: number | null
  raw: Record<string, unknown>
}

// ---------------------------------------------------------------------------
// Normalização
// ---------------------------------------------------------------------------
export function dedupeKey(name: string, city: string) {
  const norm = (s: string) =>
    s
      .normalize('NFD')
      .replace(/[̀-ͯ]/g, '')
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, ' ')
      .trim()
  return `${norm(name)}|${norm(city.split(/[,/-]/)[0] ?? city)}`
}

function phoneE164(phone: string | null | undefined) {
  const raw = (phone ?? '').trim()
  const digits = raw.replace(/\D/g, '')
  if (digits.length < 10) return null
  if (raw.startsWith('+')) return `+${digits}`
  if (digits.length === 10 || digits.length === 11) return `+55${digits}`
  if ((digits.length === 12 || digits.length === 13) && digits.startsWith('55')) return `+${digits}`
  return null
}

function url(v: unknown) {
  const s = typeof v === 'string' ? v.trim() : ''
  if (!s) return null
  const withProto = /^https?:\/\//i.test(s) ? s : `https://${s}`
  try {
    return new URL(withProto).toString()
  } catch {
    return null
  }
}

// ---------------------------------------------------------------------------
// Fonte 1: Google Places
// ---------------------------------------------------------------------------
const FIELD_MASK = [
  'places.id',
  'places.displayName',
  'places.formattedAddress',
  'places.addressComponents',
  'places.websiteUri',
  'places.internationalPhoneNumber',
  'places.rating',
  'places.userRatingCount',
  'places.googleMapsUri',
  'places.types',
  'places.primaryTypeDisplayName',
  'nextPageToken',
].join(',')

type Place = {
  id: string
  displayName?: { text: string }
  formattedAddress?: string
  addressComponents?: { longText: string; shortText: string; types: string[] }[]
  websiteUri?: string
  internationalPhoneNumber?: string
  rating?: number
  userRatingCount?: number
  googleMapsUri?: string
}

async function fromPlaces(apiKey: string, query: string, city: string): Promise<Candidate[]> {
  const places: Place[] = []
  let pageToken: string | undefined
  for (let page = 0; page < 3; page++) {
    const res = await fetch('https://places.googleapis.com/v1/places:searchText', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Goog-Api-Key': apiKey, 'X-Goog-FieldMask': FIELD_MASK },
      body: JSON.stringify({
        textQuery: `${query} em ${city}`,
        languageCode: 'pt-BR',
        regionCode: 'BR',
        pageSize: 20,
        ...(pageToken ? { pageToken } : {}),
      }),
    })
    const data = await res.json()
    if (!res.ok) throw new HttpError(502, `Google Places: ${data?.error?.message ?? res.statusText}`)
    places.push(...((data.places ?? []) as Place[]))
    pageToken = data.nextPageToken
    if (!pageToken) break
  }
  const comp = (p: Place, type: string, short = false) => {
    const c = p.addressComponents?.find((a) => a.types.includes(type))
    return c ? (short ? c.shortText : c.longText) : null
  }
  return places.map((p) => ({
    name: p.displayName?.text ?? 'Sem nome',
    address: p.formattedAddress ?? null,
    city: comp(p, 'administrative_area_level_2') ?? comp(p, 'locality') ?? city,
    state: (comp(p, 'administrative_area_level_1', true) ?? '').slice(0, 2).toUpperCase() || null,
    website: p.websiteUri ?? null,
    phone: phoneE164(p.internationalPhoneNumber),
    google_place_id: p.id,
    google_maps_uri: p.googleMapsUri ?? null,
    rating: p.rating ?? null,
    rating_count: p.userRatingCount ?? null,
    raw: p as unknown as Record<string, unknown>,
  }))
}

// ---------------------------------------------------------------------------
// Fonte 2: Gemini com busca no Google
// ---------------------------------------------------------------------------
type GeminiPlace = {
  name?: string
  address?: string | null
  city?: string | null
  state?: string | null
  website?: string | null
  phone?: string | null
  instagram?: string | null
  why?: string | null
}

async function fromGemini(query: string, city: string, type: CompanyType | null): Promise<{ list: Candidate[]; sources: Source[] }> {
  const research = await searchWithGoogle(
    `Você ajuda o time de vendas do NEQST a montar uma lista de prospecção.\n\nContexto do NEQST:\n${NEQST_CONTEXT}\n\n` +
      `Pesquise na web e liste até 20 lugares reais que correspondam a: "${query}", na cidade de ${city}, Brasil` +
      (type ? ` (foco: ${TYPE_LABEL[type]})` : '') +
      `.\nPara cada um, traga: nome oficial, endereço, cidade, UF, site, telefone/WhatsApp, Instagram e uma frase de por que entrou na lista.\n` +
      `Inclua só lugares que você encontrou em fontes (Google, sites, redes, notícias). Não invente lugares, telefones ou endereços: se não achar um dado, deixe em branco.`,
  )

  const parsed = await toJson<{ places?: GeminiPlace[] }>(
    `Transforme a lista abaixo em JSON exatamente neste formato, só JSON:\n` +
      `{"places":[{"name":"","address":null,"city":"","state":"UF","website":null,"phone":null,"instagram":null,"why":""}]}\n` +
      `Use só o que está no texto. Dado ausente = null. Máximo 20 itens. Cidade padrão: ${city}.\n\nLista:\n${research.text}`,
  )

  const list: Candidate[] = (parsed.places ?? [])
    .filter((p) => typeof p.name === 'string' && p.name.trim().length > 1)
    .slice(0, 20)
    .map((p) => ({
      name: p.name!.trim(),
      address: p.address?.trim() || null,
      city: p.city?.trim() || city,
      state: /^[A-Za-z]{2}$/.test(p.state?.trim() ?? '') ? p.state!.trim().toUpperCase() : null,
      website: url(p.website),
      phone: phoneE164(p.phone),
      google_place_id: null,
      google_maps_uri: null,
      rating: null,
      rating_count: null,
      raw: { instagram: p.instagram ?? null, why: p.why ?? null, model: geminiModel() },
    }))
  return { list, sources: research.sources }
}

// ---------------------------------------------------------------------------
serve(async (req) => {
  const body = await req.json().catch(() => ({}))
  const query = String(body.query ?? '').trim()
  const city = String(body.city ?? '').trim()
  const companyType = COMPANY_TYPES.includes(body.company_type) ? (body.company_type as CompanyType) : null
  if (query.length < 3 || city.length < 2) throw new HttpError(400, 'Informe o que buscar e a cidade.')

  const supabase = await userClient(req)
  const placesKey = Deno.env.get('GOOGLE_PLACES_API_KEY')
  const source = placesKey ? 'google_places' : 'gemini_search'

  let candidates: Candidate[]
  let sources: Source[] = []
  if (placesKey) {
    candidates = await fromPlaces(placesKey, query, city)
  } else {
    requireEnv('GEMINI_API_KEY')
    ;({ list: candidates, sources } = await fromGemini(query, city, companyType))
  }

  const { data: search, error: searchError } = await supabase
    .from('prospect_searches')
    .insert({ query, city, company_type: companyType, total_found: candidates.length })
    .select('id')
    .single()
  if (searchError) throw searchError

  // Dedupe: pelo ID do Google (quando houver) e por nome + cidade normalizados.
  const rows = candidates.map((c) => ({
    ...c,
    company_type: companyType,
    source,
    dedupe_key: dedupeKey(c.name, c.city),
    raw: { ...c.raw, search_sources: sources.slice(0, 10) },
    search_id: search.id,
  }))
  const uniqueRows = [...new Map(rows.map((r) => [r.dedupe_key, r])).values()]

  const keys = uniqueRows.map((r) => r.dedupe_key)
  const placeIds = uniqueRows.map((r) => r.google_place_id).filter((v): v is string => !!v)
  const existing = new Set<string>()
  if (keys.length) {
    const { data } = await supabase.from('prospects').select('dedupe_key').in('dedupe_key', keys)
    for (const r of data ?? []) if (r.dedupe_key) existing.add(r.dedupe_key)
  }
  if (placeIds.length) {
    const { data } = await supabase.from('prospects').select('google_place_id').in('google_place_id', placeIds)
    for (const r of data ?? []) if (r.google_place_id) existing.add(r.google_place_id)
  }
  const fresh = uniqueRows.filter((r) => !existing.has(r.dedupe_key) && !(r.google_place_id && existing.has(r.google_place_id)))

  if (fresh.length) {
    const { error } = await supabase.from('prospects').insert(fresh)
    if (error) throw error
  }
  await supabase.from('prospect_searches').update({ total_new: fresh.length }).eq('id', search.id)

  return json({ search_id: search.id, source, found: candidates.length, new: fresh.length })
})
