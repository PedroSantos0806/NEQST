/**
 * Scan tokens (US-02): prova de presença de uso único com TTL curto.
 * O banco guarda apenas o SHA-256 — o valor em claro só trafega na
 * resposta do `scan-court` e fica na memória do app.
 */

export const SCAN_TOKEN_TTL_SECONDS = 30;

function base64UrlEncode(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

/** Token aleatório de 256 bits. */
export function generateScanToken(): string {
  return base64UrlEncode(crypto.getRandomValues(new Uint8Array(32)));
}

/** Mesmo algoritmo de `public.hash_scan_token` no Postgres. */
export async function hashScanToken(token: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export function expiresAt(ttlSeconds = SCAN_TOKEN_TTL_SECONDS, now = new Date()): Date {
  return new Date(now.getTime() + ttlSeconds * 1000);
}
