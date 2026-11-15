// Gera o dossiê de um lead frio com o Gemini + busca no Google.
// Duas chamadas: (1) pesquisa com google_search → notas com fontes; (2) organiza em JSON, sem ferramentas.
// Secrets: GEMINI_API_KEY; opcional GEMINI_MODEL.
import { HttpError, json, serve, userClient } from '../_shared/http.ts'
import { NEQST_CONTEXT, geminiModel, searchWithGoogle, toJson } from '../_shared/gemini.ts'

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

function normalize(d: Record<string, unknown>): Dossier {
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
  const { data: p, error } = await supabase.from('prospects').select('*').eq('id', prospect_id).single()
  if (error || !p) throw new HttpError(404, 'Lead não encontrado')

  await supabase.from('prospects').update({ status: 'researching', last_error: null }).eq('id', p.id)

  try {
    const raw = (p.raw ?? {}) as Record<string, unknown>
    const lead = [
      `Nome: ${p.name}`,
      p.city && `Cidade: ${p.city}${p.state ? `/${p.state}` : ''}`,
      p.address && `Endereço: ${p.address}`,
      p.website && `Site: ${p.website}`,
      p.phone && `Telefone: ${p.phone}`,
      typeof raw.instagram === 'string' && `Instagram: ${raw.instagram}`,
      p.google_maps_uri && `Google Maps: ${p.google_maps_uri}`,
      p.rating && `Avaliação no Google: ${p.rating} (${p.rating_count ?? 0} avaliações)`,
      typeof raw.why === 'string' && `Por que entrou na lista: ${raw.why}`,
    ]
      .filter(Boolean)
      .join('\n')

    // 1) Pesquisa com busca no Google
    const research = await searchWithGoogle(
      `Você é um pesquisador de vendas B2B do NEQST.\n\nContexto do NEQST:\n${NEQST_CONTEXT}\n\n` +
        `Pesquise na web este possível cliente e escreva notas objetivas em português do Brasil:\n${lead}\n\n` +
        `Levante: o que é o lugar e quem administra; quantas quadras e de quais modalidades; notícias, reformas, eventos, ` +
        `torneios ou mudanças de gestão recentes; presença em redes sociais; pistas sobre internet/Wi-Fi; quem decide e ` +
        `por qual canal público falar; se o mesmo operador tem outros locais. Diga explicitamente o que não encontrou. ` +
        `Não invente nomes de pessoas nem números.`,
    )

    // 2) Organiza em JSON (sem ferramentas)
    const d = normalize(
      await toJson<Record<string, unknown>>(
        `Contexto do NEQST:\n${NEQST_CONTEXT}\n\nLead: ${p.name}\n\nNotas de pesquisa:\n${research.text}\n\n` +
          `Transforme as notas em JSON exatamente neste formato (só JSON, sem comentários). Use apenas o que está nas notas; ` +
          `quando não souber, use null, lista vazia ou 0:\n${JSON_SHAPE}`,
      ),
    )

    const { data: saved, error: saveError } = await supabase
      .from('prospect_research')
      .insert({
        prospect_id: p.id,
        ...d,
        sources: research.sources,
        search_queries: research.queries,
        model: geminiModel(),
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
