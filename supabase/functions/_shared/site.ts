// Lê o texto de um site público (para o dossiê sem busca no Google).
// Só http(s), sem IPs/hosts internos, com tempo e tamanho limitados.
// Sites de clube costumam ser lentos (ex.: 19 s na home do TCC): por isso os tempos são folgados.

const BLOCKED_HOST = /^(localhost|.*\.local|.*\.internal|0\.0\.0\.0|127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|\[?::1\]?$|metadata\.google)/i

const HOME_TIMEOUT = 30_000
const PAGE_TIMEOUT = 15_000
const MAX_EXTRA_PAGES = 4
const MAX_TEXT = 24_000

// Páginas internas úteis ao dossiê: 1 link por grupo, na ordem; dentro do grupo, o 1º padrão que achar.
const PRIORITY: { patterns: RegExp[]; articles?: boolean }[] = [
  { patterns: [/beach/i, /padel/i, /quadras?\b/i, /futev|volei/i, /t[eê]nis|tenis/i] },
  { patterns: [/infraestrutura|estrutura/i, /instalac|espacos?/i] },
  { patterns: [/diretoria/i, /conselho|gestao|administra|presidente/i] },
  { patterns: [/noticia|novidade/i, /evento|torneio|agenda/i], articles: true },
  { patterns: [/contato|fale-?conosco/i] },
  { patterns: [/sobre|quem-?somos/i, /institucional|historia/i] },
]

/** Slug com cara de notícia/post (muitas palavras) — só serve no grupo de notícias. */
const looksLikeArticle = (u: URL) => (u.pathname.split('/').filter(Boolean).pop() ?? '').split('-').length > 4

function safeUrl(raw: string): URL | null {
  try {
    const u = new URL(/^https?:\/\//i.test(raw) ? raw : `https://${raw}`)
    if (!['http:', 'https:'].includes(u.protocol)) return null
    if (BLOCKED_HOST.test(u.hostname)) return null
    return u
  } catch {
    return null
  }
}

function decodeEntities(s: string) {
  const named: Record<string, string> = { nbsp: ' ', amp: '&', quot: '"', apos: "'", lt: '<', gt: '>', ndash: '–', mdash: '—', hellip: '…' }
  return s
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)))
    .replace(/&([a-z]+);/gi, (m, n) => named[n.toLowerCase()] ?? m)
}

function htmlToText(html: string) {
  return decodeEntities(
    html
      .replace(/<script[\s\S]*?<\/script>/gi, ' ')
      .replace(/<style[\s\S]*?<\/style>/gi, ' ')
      .replace(/<noscript[\s\S]*?<\/noscript>/gi, ' ')
      .replace(/<svg[\s\S]*?<\/svg>/gi, ' ')
      .replace(/<(br|\/p|\/div|\/li|\/h\d|\/tr)>/gi, '\n')
      .replace(/<[^>]+>/g, ' '),
  )
    .replace(/[ \t]+/g, ' ')
    .replace(/\n\s*\n+/g, '\n')
    .trim()
}

async function fetchHtml(u: URL, timeout: number): Promise<{ html: string; finalUrl: URL } | null> {
  try {
    const res = await fetch(u, {
      headers: {
        // UA de navegador: vários sites bloqueiam robôs genéricos.
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36',
        Accept: 'text/html,application/xhtml+xml',
        'Accept-Language': 'pt-BR,pt;q=0.9',
      },
      redirect: 'follow',
      signal: AbortSignal.timeout(timeout),
    })
    if (!res.ok || !(res.headers.get('content-type') ?? '').includes('text/html')) return null
    return { html: (await res.text()).slice(0, 2_000_000), finalUrl: new URL(res.url || u.toString()) }
  } catch {
    return null
  }
}

/** Links internos úteis: 1 por grupo de prioridade (quadras → estrutura → diretoria → notícias → contato → sobre). */
function usefulLinks(html: string, base: URL): URL[] {
  const candidates: { u: URL; hay: string }[] = []
  const seen = new Set<string>()
  for (const m of html.matchAll(/<a\b[^>]*href=["']([^"'#]+)["'][^>]*>([\s\S]*?)<\/a>/gi)) {
    let u: URL
    try {
      u = new URL(m[1], base)
    } catch {
      continue
    }
    if (u.hostname.replace(/^www\./, '') !== base.hostname.replace(/^www\./, '')) continue
    if (/\.(pdf|jpe?g|png|gif|webp|zip|docx?|xlsx?)$/i.test(u.pathname)) continue
    if (u.pathname === '/' || u.pathname === base.pathname) continue
    u.hash = ''
    if (seen.has(u.toString())) continue
    seen.add(u.toString())
    const label = htmlToText(m[2]).slice(0, 80)
    const hay = `${decodeURIComponent(u.pathname)} ${label}`.normalize('NFD').replace(/[̀-ͯ]/g, '')
    candidates.push({ u, hay })
  }
  const picked: URL[] = []
  for (const group of PRIORITY) {
    for (const re of group.patterns) {
      // Prefere o link mais "raso" (ex.: /beach-tennis/ antes de /beach-tennis/turma-x/).
      const match = candidates
        .filter((c) => re.test(c.hay) && (group.articles || !looksLikeArticle(c.u)))
        .filter((c) => !picked.some((p) => p.toString() === c.u.toString()))
        .sort((a, b) => a.u.pathname.split('/').length - b.u.pathname.split('/').length)[0]
      if (match) {
        picked.push(match.u)
        break
      }
    }
    if (picked.length >= MAX_EXTRA_PAGES) break
  }
  return picked
}

/** Texto da home + até 4 páginas internas úteis, até ~24 mil caracteres. */
export async function readSite(raw: string | null | undefined): Promise<{ url: string; text: string; pages: string[] } | null> {
  const start = raw ? safeUrl(raw) : null
  if (!start) return null
  const home = await fetchHtml(start, HOME_TIMEOUT)
  if (!home) return null

  const links = usefulLinks(home.html, home.finalUrl)
  const extras = await Promise.all(links.map(async (u) => ({ u, page: await fetchHtml(u, PAGE_TIMEOUT) })))

  const parts = [`[Página inicial ${home.finalUrl}]\n${htmlToText(home.html)}`]
  const pages = [home.finalUrl.toString()]
  for (const { u, page } of extras) {
    if (!page) continue
    const text = htmlToText(page.html)
    if (text.length < 200) continue
    parts.push(`[${u.pathname}]\n${text.slice(0, 6_000)}`)
    pages.push(u.toString())
  }
  return { url: home.finalUrl.toString(), text: parts.join('\n\n---\n\n').slice(0, MAX_TEXT), pages }
}
