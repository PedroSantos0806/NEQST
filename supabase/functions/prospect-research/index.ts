// Gera o dossiê de um lead frio com o Gemini + busca no Google.
// Duas chamadas: (1) pesquisa com google_search → notas com fontes; (2) organiza em JSON, sem ferramentas.
// Secrets: GEMINI_API_KEY; opcional GEMINI_MODEL (padrão abaixo).
import { HttpError, json, requireEnv, serve, userClient } from '../_shared/http.ts'

const DEFAULT_MODEL = 'gemini-3.8-flash'

// O que o NEQST vende (base do CLAUDE.md). Ajuste aqui se o pitch mudar.
const NEQST_CONTEXT = `O NEQST instala totens com tela e QR code fixado em cada quadra esportiva (beach tennis, tênis,
padel, futevôlei, vôlei de praia, poliesportivas) em parques públicos, clubes, condomínios e empreendimentos.
O local paga uma mensalidade por quadra (normalmente começa com um piloto gratuito) e o NEQST também vende
mídia/patrocínio de marcas exibida nos totens. Para instalar, o local precisa de ponto elétrico e internet perto
das quadras. Decisores típicos: gestor/administrador do parque ou concessionária, diretoria de esportes do clube,
síndico/administradora do condomínio, marketing da construtora; para marcas, o time de marketing.`

type GeminiPart = { text?: string }
type GeminiResponse = {
  candidates?: {
    content?: { parts?: GeminiPart[] }
    groundingMetadata?: {
      webSearchQueries?: string[]
      groundingChunks?: { web?: { uri?: string; title?: string } }[]
    }
  }[]
  error?: { message?: string }
}

async function gemini(model: string, body: unknown): Promise<GeminiResponse> {
  const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-goog-api-key': requireEnv('GEMINI_API_KEY') },
    body: JSON.stringify(body),
  })
  const data = (await res.json()) as GeminiResponse
  if (!res.ok) throw new HttpError(502, `Gemini: ${data?.error?.message ?? res.statusText}`)
  return data
}

const textOf = (r: GeminiResponse) => (r.candidates?.[0]?.content?.parts ?? []).map((p) => p.text ?? '').join('').trim()

type Item = { title: string; detail?: string }
type Dossier = {
  summary: string
  hooks: Item[]
  opportunities: Item[]
  decision_makers: { name?: string; role: string; how_to_reach?: string }[]
  estimated_courts: number | null
  court_types: string[]
  has_internet_hint: string | null
  suggested_message: string
  score: number
  score_reason: string
}

const JSON_SHAPE = `{
  "summary": "2 a 4 frases: o que é o lugar, porte, público",
  "hooks": [{"title": "gancho curto", "detail": "fato concreto e recente que abre conversa, com data se houver"}],
  "opportunities": [{"title": "oportunidade para o NEQST", "detail": "por que e como (piloto, mais quadras, mídia, outros locais do mesmo operador)"}],
  "decision_makers": [{"name": "nome se público, senão omitir", "role": "cargo", "how_to_reach": "canal público (site, Instagram, telefone geral)"}],
  "estimated_courts": 0,
  "court_types": ["beach tennis"],
  "has_internet_hint": "o que se sabe sobre internet/Wi-Fi no local, ou null",
  "suggested_message": "primeira mensagem de WhatsApp, 3 a 5 linhas, tom humano, cita 1 gancho, termina com pergunta simples",
  "score": 0,
  "score_reason": "por que essa nota de 0 a 100 de aderência ao NEQST"
}`

function asItems(v: unknown): Item[] {
  return Array.isArray(v)
    ? v
        .filter((x) => x && typeof x === 'object' && typeof (x as Item).title === 'string')
        .map((x) => ({ title: String((x as Item).title), detail: (x as Item).detail ? String((x as Item).detail) : undefined }))
        .slice(0, 8)
    : []
}

function parseDossier(raw: string): Dossier {
  const cleaned = raw.replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/, '')
  let d: Record<string, unknown>
  try {
    d = JSON.parse(cleaned)
  } catch {
    throw new HttpError(502, 'A IA devolveu um formato inválido. Tente de novo.')
  }
  const courts = Number(d.estimated_courts)
  const score = Number(d.score)
  return {
    summary: String(d.summary ?? ''),
    hooks: asItems(d.hooks),
    opportunities: asItems(d.opportunities),
    decision_makers: Array.isArray(d.decision_makers)
      ? (d.decision_makers as Dossier['decision_makers']).filter((x) => x && typeof x.role === 'string').slice(0, 6)
      : [],
    estimated_courts: Number.isFinite(courts) && courts > 0 ? Math.round(courts) : null,
    court_types: Array.isArray(d.court_types) ? (d.court_types as unknown[]).map((x) => String(x).toLowerCase()).slice(0, 6) : [],
    has_internet_hint: d.has_internet_hint ? String(d.has_internet_hint) : null,
    suggested_message: String(d.suggested_message ?? ''),
    score: Number.isFinite(score) ? Math.max(0, Math.min(100, Math.round(score))) : 0,
    score_reason: String(d.score_reason ?? ''),
  }
}

serve(async (req) => {
  const { prospect_id } = await req.json().catch(() => ({}))
  if (!prospect_id) throw new HttpError(400, 'prospect_id obrigatório')

  const supabase = await userClient(req)
  const model = Deno.env.get('GEMINI_MODEL') || DEFAULT_MODEL

  const { data: p, error } = await supabase.from('prospects').select('*').eq('id', prospect_id).single()
  if (error || !p) throw new HttpError(404, 'Lead não encontrado')

  await supabase.from('prospects').update({ status: 'researching', last_error: null }).eq('id', p.id)

  try {
    const lead = [
      `Nome: ${p.name}`,
      p.address && `Endereço: ${p.address}`,
      p.website && `Site: ${p.website}`,
      p.phone && `Telefone: ${p.phone}`,
      p.google_maps_uri && `Google Maps: ${p.google_maps_uri}`,
      p.rating && `Avaliação no Google: ${p.rating} (${p.rating_count ?? 0} avaliações)`,
    ]
      .filter(Boolean)
      .join('\n')

    // 1) Pesquisa com busca no Google
    const research = await gemini(model, {
      contents: [
        {
          role: 'user',
          parts: [
            {
              text: `Você é um pesquisador de vendas B2B do NEQST.\n\nContexto do NEQST:\n${NEQST_CONTEXT}\n\nPesquise na web este possível cliente e escreva notas objetivas em português do Brasil:\n${lead}\n\nLevante: o que é o lugar e quem administra; quantas quadras e de quais modalidades; notícias, reformas, eventos, torneios ou mudanças de gestão recentes; presença em redes sociais; pistas sobre internet/Wi-Fi; quem decide e por qual canal público falar; se o mesmo operador tem outros locais. Diga explicitamente o que não encontrou. Não invente nomes de pessoas nem números.`,
            },
          ],
        },
      ],
      tools: [{ google_search: {} }],
    })
    const notes = textOf(research)
    if (!notes) throw new HttpError(502, 'A IA não retornou a pesquisa.')
    const meta = research.candidates?.[0]?.groundingMetadata
    const sources = (meta?.groundingChunks ?? [])
      .map((c) => c.web)
      .filter((w): w is { uri: string; title?: string } => !!w?.uri)
      .map((w) => ({ uri: w.uri, title: w.title ?? w.uri }))

    // 2) Organiza em JSON (sem ferramentas)
    const formatted = await gemini(model, {
      contents: [
        {
          role: 'user',
          parts: [
            {
              text: `Contexto do NEQST:\n${NEQST_CONTEXT}\n\nLead: ${p.name}\n\nNotas de pesquisa:\n${notes}\n\nTransforme as notas em JSON exatamente neste formato (só JSON, sem comentários). Use apenas o que está nas notas; quando não souber, use null, lista vazia ou 0:\n${JSON_SHAPE}`,
            },
          ],
        },
      ],
      generationConfig: { responseMimeType: 'application/json', temperature: 0.3 },
    })
    const d = parseDossier(textOf(formatted))

    const { data: saved, error: saveError } = await supabase
      .from('prospect_research')
      .insert({
        prospect_id: p.id,
        summary: d.summary,
        hooks: d.hooks,
        opportunities: d.opportunities,
        decision_makers: d.decision_makers,
        estimated_courts: d.estimated_courts,
        court_types: d.court_types,
        has_internet_hint: d.has_internet_hint,
        suggested_message: d.suggested_message,
        score: d.score,
        score_reason: d.score_reason,
        sources,
        search_queries: meta?.webSearchQueries ?? [],
        model,
      })
      .select('id')
      .single()
    if (saveError) throw saveError

    await supabase.from('prospects').update({ status: 'researched' }).eq('id', p.id)
    return json({ research_id: saved.id })
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    await supabase
      .from('prospects')
      .update({ status: p.status === 'researching' ? 'new' : p.status, last_error: message })
      .eq('id', p.id)
    throw err
  }
})
