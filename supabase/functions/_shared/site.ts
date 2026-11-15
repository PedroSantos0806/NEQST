// Lê o texto de um site público (para o dossiê sem busca no Google).
// Só http(s), sem IPs/hosts internos, com tempo e tamanho limitados.

const BLOCKED_HOST = /^(localhost|.*\.local|.*\.internal|0\.0\.0\.0|127\.|10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|\[?::1\]?$|metadata\.google)/i

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

function htmlToText(html: string) {
  return html
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<noscript[\s\S]*?<\/noscript>/gi, ' ')
    .replace(/<(br|\/p|\/div|\/li|\/h\d)>/gi, '\n')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/[ \t]+/g, ' ')
    .replace(/\n\s*\n+/g, '\n')
    .trim()
}

async function fetchText(u: URL): Promise<string | null> {
  try {
    const res = await fetch(u, {
      headers: { 'User-Agent': 'Mozilla/5.0 (compatible; NEQST-CRM/1.0)', Accept: 'text/html' },
      redirect: 'follow',
      signal: AbortSignal.timeout(12_000),
    })
    if (!res.ok || !(res.headers.get('content-type') ?? '').includes('text/html')) return null
    const html = (await res.text()).slice(0, 1_500_000)
    return htmlToText(html)
  } catch {
    return null
  }
}

/** Texto da home + páginas óbvias (sobre/contato/estrutura), até ~20 mil caracteres. */
export async function readSite(raw: string | null | undefined): Promise<{ url: string; text: string } | null> {
  const base = raw ? safeUrl(raw) : null
  if (!base) return null
  const home = await fetchText(base)
  if (!home) return null
  const extras = ['/sobre', '/quem-somos', '/contato', '/estrutura', '/esportes']
  const more = await Promise.all(extras.map((p) => fetchText(new URL(p, base))))
  const text = [home, ...more.filter((t): t is string => !!t && t.length > 200)].join('\n\n---\n\n').slice(0, 20_000)
  return { url: base.toString(), text }
}
