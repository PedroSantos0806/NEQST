// Busca leads frios no Google Places (Text Search New) e grava na fila `prospects` sem duplicar.
// Secret: GOOGLE_PLACES_API_KEY
import { HttpError, json, requireEnv, serve, userClient } from '../_shared/http.ts'

const COMPANY_TYPES = ['public_operator', 'club', 'condo', 'builder', 'brand'] as const
type CompanyType = (typeof COMPANY_TYPES)[number]

// Billing do Places é pelo campo mais caro pedido: site, telefone e avaliação entram no SKU Enterprise.
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

const MAX_PAGES = 3 // até 60 resultados por busca

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

function component(p: Place, type: string, short = false) {
  const c = p.addressComponents?.find((a) => a.types.includes(type))
  return c ? (short ? c.shortText : c.longText) : null
}

function e164(phone: string | undefined) {
  if (!phone) return null
  const digits = phone.replace(/\D/g, '')
  return digits.length >= 8 ? `+${digits}` : null
}

serve(async (req) => {
  const body = await req.json().catch(() => ({}))
  const query = String(body.query ?? '').trim()
  const city = String(body.city ?? '').trim()
  const companyType = COMPANY_TYPES.includes(body.company_type) ? (body.company_type as CompanyType) : null
  if (query.length < 3 || city.length < 2) throw new HttpError(400, 'Informe o que buscar e a cidade.')

  const supabase = await userClient(req)
  const apiKey = requireEnv('GOOGLE_PLACES_API_KEY')

  const places: Place[] = []
  let pageToken: string | undefined
  for (let page = 0; page < MAX_PAGES; page++) {
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

  const { data: search, error: searchError } = await supabase
    .from('prospect_searches')
    .insert({ query, city, company_type: companyType, total_found: places.length })
    .select('id')
    .single()
  if (searchError) throw searchError

  const rows = places.map((p) => ({
    name: p.displayName?.text ?? 'Sem nome',
    company_type: companyType,
    address: p.formattedAddress ?? null,
    city: component(p, 'administrative_area_level_2') ?? component(p, 'locality') ?? city,
    state: (component(p, 'administrative_area_level_1', true) ?? '').slice(0, 2).toUpperCase() || null,
    website: p.websiteUri ?? null,
    phone: e164(p.internationalPhoneNumber),
    google_place_id: p.id,
    google_maps_uri: p.googleMapsUri ?? null,
    rating: p.rating ?? null,
    rating_count: p.userRatingCount ?? null,
    raw: p,
    search_id: search.id,
  }))

  // Dedupe: lugar já na fila (qualquer status) não entra de novo.
  let inserted = 0
  if (rows.length) {
    const { data, error } = await supabase
      .from('prospects')
      .upsert(rows, { onConflict: 'google_place_id', ignoreDuplicates: true })
      .select('id')
    if (error) throw error
    inserted = data?.length ?? 0
  }

  await supabase.from('prospect_searches').update({ total_new: inserted }).eq('id', search.id)

  return json({ search_id: search.id, found: places.length, new: inserted })
})
