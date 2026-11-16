// Busca grátis de leads no OpenStreetMap (Overpass), feita no navegador.
// O Overpass bloqueia chamadas vindas do servidor do Supabase, mas aceita o navegador (CORS).
// Licença ODbL: a tela mostra "© OpenStreetMap contributors".
import { supabase } from '@/lib/supabase'
import { normalizePhone } from '@/lib/format'
import type { Enums, TablesInsert } from '@/types/database'

const OVERPASS = 'https://overpass-api.de/api/interpreter'
const COURT_SPORTS = 'beach_tennis|tennis|padel|beachvolleyball|footvolley|volleyball|multi|pickleball'

// Código IBGE da UF = 2 primeiros dígitos do código do município (tag IBGE:GEOCODIGO no OSM).
const IBGE_UF: Record<string, string> = {
  RO: '11', AC: '12', AM: '13', RR: '14', PA: '15', AP: '16', TO: '17', MA: '21', PI: '22', CE: '23', RN: '24', PB: '25',
  PE: '26', AL: '27', SE: '28', BA: '29', MG: '31', ES: '32', RJ: '33', SP: '35', PR: '41', SC: '42', RS: '43', MS: '50',
  MT: '51', GO: '52', DF: '53',
}

type Bounds = { minlat: number; minlon: number; maxlat: number; maxlon: number }
type El = {
  type: 'node' | 'way' | 'relation' | 'area'
  id: number
  lat?: number
  lon?: number
  center?: { lat: number; lon: number }
  bounds?: Bounds
  tags?: Record<string, string>
}

export class OsmError extends Error {}

/** "Campinas, SP" → { city: "Campinas", uf: "SP" } */
export function parseCity(input: string) {
  const [city, rest] = input.split(',').map((s) => s.trim())
  const uf = /^[A-Za-z]{2}$/.test(rest ?? '') ? rest!.toUpperCase() : null
  return { city: city || input.trim(), uf }
}

const stripAccents = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '')

/** Regex do Overpass que aceita o nome sem acento e em qualquer caixa ("sao paulo" = "São Paulo"). */
function nameRegex(name: string) {
  const map: Record<string, string> = { a: '[aáàâã]', e: '[eéê]', i: '[ií]', o: '[oóôõ]', u: '[uúü]', c: '[cç]' }
  return stripAccents(name)
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9 '-]/g, '')
    .replace(/[aeiouc]/g, (ch) => map[ch])
}

/** Mesma regra do servidor: nome|cidade sem acento/pontuação. */
export function dedupeKey(name: string, city: string) {
  const norm = (s: string) =>
    stripAccents(s)
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, ' ')
      .trim()
  return `${norm(name)}|${norm(city.split(/[,/-]/)[0] ?? city)}`
}

/** Overpass público vive cheio: tenta de novo com espera crescente (3s, 6s, 12s, 24s). */
async function overpass(query: string, onStatus?: (msg: string) => void): Promise<El[]> {
  let wait = 3_000
  let last = ''
  for (let attempt = 1; attempt <= 5; attempt++) {
    try {
      const res = await fetch(OVERPASS, {
        method: 'POST',
        body: new URLSearchParams({ data: query }),
        signal: AbortSignal.timeout(150_000),
      })
      const text = await res.text()
      if (res.ok && text.startsWith('{')) return (JSON.parse(text).elements ?? []) as El[]
      last = `HTTP ${res.status}`
    } catch (err) {
      last = err instanceof Error ? err.message : String(err)
    }
    if (attempt < 5) {
      onStatus?.(`Mapa gratuito ocupado; tentando de novo em ${wait / 1000}s (${attempt}/4)…`)
      await new Promise((r) => setTimeout(r, wait))
      wait *= 2
    }
  }
  throw new OsmError(`O servidor gratuito do OpenStreetMap está ocupado (${last}). Tente de novo em alguns minutos.`)
}

const inside = (b: Bounds | undefined, c: { lat: number; lon: number }) =>
  !!b && c.lat >= b.minlat && c.lat <= b.maxlat && c.lon >= b.minlon && c.lon <= b.maxlon
const area = (b: Bounds) => (b.maxlat - b.minlat) * (b.maxlon - b.minlon)

function address(t: Record<string, string>) {
  const street = [t['addr:street'], t['addr:housenumber']].filter(Boolean).join(', ')
  return [street, t['addr:suburb']].filter(Boolean).join(' - ') || null
}

function toUrl(v: string | undefined) {
  const s = (v ?? '').trim()
  if (!s) return null
  try {
    return new URL(/^https?:\/\//i.test(s) ? s : `https://${s}`).toString()
  } catch {
    return null
  }
}

type CompanyType = Enums<'company_type'>

/**
 * Busca no mapa e grava na fila sem duplicar. Parques (operador público) ou clubes/arenas.
 */
export async function searchOsmAndSave(
  v: { query: string; city: string; company_type: CompanyType | null },
  onStatus?: (msg: string) => void,
): Promise<{ found: number; new: number }> {
  const type = v.company_type
  if (type === 'condo' || type === 'builder' || type === 'brand') {
    throw new OsmError(
      'O mapa gratuito (OpenStreetMap) só cobre parques e clubes/arenas. Para condomínios, construtoras e marcas, use "Adicionar lead" ou importe uma planilha.',
    )
  }
  const { city, uf } = parseCity(v.city)
  if (!uf || !IBGE_UF[uf]) throw new OsmError('Informe a cidade com a UF, ex.: "Campinas, SP".')

  const containers =
    type === 'public_operator'
      ? `wr["leisure"~"^(park|recreation_ground)$"]["name"](area.city);`
      : `wr["leisure"="sports_centre"]["name"](area.city); wr["club"="sport"]["name"](area.city); wr["leisure"="sports_club"]["name"](area.city);`

  onStatus?.('Consultando o mapa (pode levar até 1 minuto)…')
  const els = await overpass(
    `[out:json][timeout:120];
area["boundary"="administrative"]["admin_level"="8"]["name"~"^${nameRegex(city)}$",i]["IBGE:GEOCODIGO"~"^${IBGE_UF[uf]}"]->.city;
.city out ids tags;
nwr["leisure"="pitch"]["sport"~"${COURT_SPORTS}"](area.city);
out center tags;
(${containers});
out center bb tags;`,
    onStatus,
  )

  const cityEl = els.find((e) => e.type === 'area')
  if (!cityEl) throw new OsmError(`Não achei a cidade "${city}, ${uf}" no mapa. Confira o nome.`)
  const cityName = cityEl.tags?.name ?? city

  const pitches = els.filter((e) => e.tags?.leisure === 'pitch')
  const places = els.filter((e) => e.type !== 'area' && e.tags?.leisure !== 'pitch' && e.tags?.name)

  // Cada quadra conta para o menor lugar com nome que a contém.
  const agg = new Map<string, { el: El; courts: number; sports: Set<string> }>()
  for (const p of pitches) {
    const c = p.center ?? (p.lat != null && p.lon != null ? { lat: p.lat, lon: p.lon } : null)
    if (!c) continue
    let best: El | undefined
    for (const k of places) if (inside(k.bounds, c) && (!best || area(k.bounds!) < area(best.bounds!))) best = k
    if (!best) continue
    const key = `${best.type}/${best.id}`
    const a = agg.get(key) ?? { el: best, courts: 0, sports: new Set<string>() }
    a.courts++
    for (const s of (p.tags?.sport ?? '').split(';')) if (s) a.sports.add(s)
    agg.set(key, a)
  }

  // Clubes/arenas sem quadras mapeadas entram se o nome/esporte combinam com a busca.
  if (type !== 'public_operator') {
    const words = v.query.toLowerCase().split(/\s+/).filter((w) => w.length > 3)
    for (const k of places) {
      const key = `${k.type}/${k.id}`
      if (agg.has(key)) continue
      const hay = stripAccents(`${k.tags?.name ?? ''} ${k.tags?.sport ?? ''}`.toLowerCase())
      if (/(beach|tenis|tennis|padel|arena|volei|volley|futev)/.test(hay) || words.some((w) => hay.includes(stripAccents(w)))) {
        agg.set(key, { el: k, courts: 0, sports: new Set((k.tags?.sport ?? '').split(';').filter(Boolean)) })
      }
    }
  }

  const found = [...agg.values()].sort((a, b) => b.courts - a.courts).slice(0, 60)

  const { data: search, error: searchError } = await supabase
    .from('prospect_searches')
    .insert({ query: v.query, city: v.city, company_type: type, total_found: found.length })
    .select('id')
    .single()
  if (searchError) throw searchError

  const rows: TablesInsert<'prospects'>[] = found.map(({ el, courts, sports }) => {
    const t = el.tags ?? {}
    const site = toUrl(t.website ?? t['contact:website'] ?? t.url)
    const isInstagram = !!site && /instagram\.com/i.test(site)
    const c = el.center ?? (el.lat != null && el.lon != null ? { lat: el.lat, lon: el.lon } : null)
    const rowCity = t['addr:city'] ?? cityName
    return {
      name: t.name,
      company_type: type,
      address: address(t),
      city: rowCity,
      state: uf,
      website: isInstagram ? null : site,
      instagram: isInstagram ? site : (t['contact:instagram'] ?? null),
      phone: normalizePhone(t.phone ?? t['contact:phone'] ?? t['contact:whatsapp']),
      google_maps_uri: `https://www.openstreetmap.org/${el.type}/${el.id}`,
      osm_id: `${el.type}/${el.id}`,
      mapped_courts: courts || null,
      mapped_sports: [...sports],
      source: 'openstreetmap',
      dedupe_key: dedupeKey(t.name, rowCity),
      raw: { osm_tags: t, lat: c?.lat ?? null, lon: c?.lon ?? null },
      search_id: search.id,
    }
  })

  // Dedupe: já na fila pelo id do mapa ou por nome + cidade.
  const unique = [...new Map(rows.map((r) => [r.dedupe_key!, r])).values()]
  const existing = new Set<string>()
  if (unique.length) {
    const [byKey, byOsm] = await Promise.all([
      supabase.from('prospects').select('dedupe_key').in('dedupe_key', unique.map((r) => r.dedupe_key!)),
      supabase.from('prospects').select('osm_id').in('osm_id', unique.map((r) => r.osm_id!)),
    ])
    for (const r of byKey.data ?? []) if (r.dedupe_key) existing.add(r.dedupe_key)
    for (const r of byOsm.data ?? []) if (r.osm_id) existing.add(r.osm_id)
  }
  const fresh = unique.filter((r) => !existing.has(r.dedupe_key!) && !existing.has(r.osm_id!))
  if (fresh.length) {
    const { error } = await supabase.from('prospects').insert(fresh)
    if (error) throw error
  }
  await supabase.from('prospect_searches').update({ total_new: fresh.length }).eq('id', search.id)
  return { found: found.length, new: fresh.length }
}
