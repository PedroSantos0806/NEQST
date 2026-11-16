import { HttpError, requireEnv } from './http.ts'

export const DEFAULT_MODEL = 'gemini-3.8-flash'
export const geminiModel = () => Deno.env.get('GEMINI_MODEL') || DEFAULT_MODEL

// O que o NEQST vende (base do CLAUDE.md). Ajuste aqui se o pitch mudar.
export const NEQST_CONTEXT = `O NEQST instala totens com tela e QR code fixado em cada quadra esportiva (beach tennis, tênis,
padel, futevôlei, vôlei de praia, poliesportivas) em parques públicos, clubes, condomínios e empreendimentos.
O local paga uma mensalidade por quadra (normalmente começa com um piloto gratuito) e o NEQST também vende
mídia/patrocínio de marcas exibida nos totens. Para instalar, o local precisa de ponto elétrico e internet perto
das quadras. Decisores típicos: gestor/administrador do parque ou concessionária, diretoria de esportes do clube,
síndico/administradora do condomínio, marketing da construtora; para marcas, o time de marketing.`

type GeminiResponse = {
  candidates?: {
    content?: { parts?: { text?: string }[] }
    groundingMetadata?: {
      webSearchQueries?: string[]
      groundingChunks?: { web?: { uri?: string; title?: string } }[]
    }
  }[]
  error?: { message?: string }
}

export type Source = { uri: string; title: string }

async function call(body: unknown): Promise<GeminiResponse> {
  const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${geminiModel()}:generateContent`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-goog-api-key': requireEnv('GEMINI_API_KEY') },
    body: JSON.stringify(body),
  })
  const data = (await res.json()) as GeminiResponse
  if (res.status === 429) {
    throw new HttpError(
      429,
      'Cota do Gemini esgotada. Ative o faturamento no projeto do Google Cloud dono da chave (AI Studio → Faturamento) ou aguarde a cota renovar.',
    )
  }
  if (!res.ok) throw new HttpError(502, `Gemini: ${data?.error?.message ?? res.statusText}`)
  return data
}

const textOf = (r: GeminiResponse) => (r.candidates?.[0]?.content?.parts ?? []).map((p) => p.text ?? '').join('').trim()

/** Pesquisa com busca no Google: devolve o texto, as fontes e as consultas feitas. */
export async function searchWithGoogle(prompt: string) {
  const r = await call({ contents: [{ role: 'user', parts: [{ text: prompt }] }], tools: [{ google_search: {} }] })
  const text = textOf(r)
  if (!text) throw new HttpError(502, 'A IA não retornou a pesquisa.')
  const meta = r.candidates?.[0]?.groundingMetadata
  const sources: Source[] = (meta?.groundingChunks ?? [])
    .map((c) => c.web)
    .filter((w): w is { uri: string; title?: string } => !!w?.uri)
    .map((w) => ({ uri: w.uri, title: w.title ?? w.uri }))
  return { text, sources, queries: meta?.webSearchQueries ?? [] }
}

/**
 * Organiza um texto em JSON (sem ferramentas). Feito em chamada separada porque
 * busca + JSON na mesma chamada tem falhas conhecidas.
 */
export async function toJson<T>(prompt: string): Promise<T> {
  const r = await call({
    contents: [{ role: 'user', parts: [{ text: prompt }] }],
    generationConfig: { responseMimeType: 'application/json', temperature: 0.2 },
  })
  const raw = textOf(r).replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/, '')
  try {
    return JSON.parse(raw) as T
  } catch {
    throw new HttpError(502, 'A IA devolveu um formato inválido. Tente de novo.')
  }
}
