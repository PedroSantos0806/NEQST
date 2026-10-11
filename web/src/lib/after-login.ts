/**
 * Para onde voltar depois do login.
 *
 * Guardado quando alguém cai numa rota protegida sem sessão — tipicamente
 * o `/q/<quadra>` de um QR escaneado. Como vira destino de navegação, o
 * valor é tratado como entrada hostil: só caminhos internos passam.
 * `//evil.com` e `/\evil.com` são lidos como URL absoluta pelo navegador
 * e levariam a pessoa para fora do app.
 */
const KEY = "neqst:after-login";

function internalPath(value: string | null | undefined): string | null {
  if (!value) return null;
  // Precisa começar com uma única barra, e não com barra seguida de
  // barra ou de contrabarra.
  if (!/^\/(?![/\\])/.test(value)) return null;
  if (value.includes("\\")) return null;
  return value;
}

export function rememberAfterLogin(path: string): void {
  const safe = internalPath(path);
  if (!safe) return;
  try {
    sessionStorage.setItem(KEY, safe);
  } catch {
    /* modo privado: a pessoa só cai na home depois de entrar */
  }
}

/** Espia o destino sem consumir — para montar o link do e-mail. */
export function peekAfterLogin(): string | null {
  try {
    return internalPath(sessionStorage.getItem(KEY));
  } catch {
    return null;
  }
}

/**
 * O destino sobrevive à ida ao e-mail.
 *
 * O link de confirmação costuma abrir noutra aba — às vezes noutro
 * navegador — e ali a sessionStorage não existe. Quem escaneou o QR da
 * quadra e criou a conta tem de voltar para aquela quadra, então o
 * destino viaja na própria URL de retorno.
 */
export function callbackUrl(extra?: Record<string, string>): string {
  const url = new URL("/auth/callback", window.location.origin);
  const next = peekAfterLogin();
  if (next) url.searchParams.set("next", next);
  for (const [key, value] of Object.entries(extra ?? {})) {
    url.searchParams.set(key, value);
  }
  return url.toString();
}

/** O `next` da URL, se for um caminho interno. */
export function nextFromUrl(search = window.location.search): string | null {
  return internalPath(new URLSearchParams(search).get("next"));
}

/** Lê e consome o destino. Devolve "/" quando não há um válido. */
export function takeAfterLogin(): string {
  let stored: string | null = null;
  try {
    stored = sessionStorage.getItem(KEY);
    sessionStorage.removeItem(KEY);
  } catch {
    /* idem */
  }
  return internalPath(stored) ?? "/";
}
