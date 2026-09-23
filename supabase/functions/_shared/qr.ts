/**
 * QR Code das quadras (US-02).
 *
 * O QR impresso é estático e carrega o ID da quadra + uma assinatura
 * HMAC-SHA256 truncada. Sem o segredo (`QR_SIGNING_SECRET`) ninguém
 * consegue forjar um QR válido para uma quadra que não existe.
 *
 * Formato:  neqst:v<versão>:<courtId>:<assinatura>
 * Exemplo:  neqst:v1:7c9e6679-7425-40de-944b-e07fc1f90ae7:Yk3f...
 *
 * O "timeout de 30s" do critério de aceite NÃO vive no QR (que é
 * impresso e imutável): ele é o TTL do scan token emitido por
 * `scan-court` depois de validar assinatura + distância.
 */

export const QR_PREFIX = "neqst";
export const SIGNATURE_LENGTH = 32;

export interface CourtQrPayload {
  version: number;
  courtId: string;
  signature: string;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export class InvalidQrError extends Error {
  constructor(message = "QR Code inválido") {
    super(message);
    this.name = "InvalidQrError";
  }
}

function base64UrlEncode(bytes: ArrayBuffer): string {
  const binary = String.fromCharCode(...new Uint8Array(bytes));
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function hmacKey(secret: string): Promise<CryptoKey> {
  return await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

/** Assinatura canônica de uma quadra numa dada versão de segredo. */
export async function signCourt(
  courtId: string,
  version: number,
  secret: string,
): Promise<string> {
  const key = await hmacKey(secret);
  const message = new TextEncoder().encode(`v${version}:${courtId.toLowerCase()}`);
  const signature = await crypto.subtle.sign("HMAC", key, message);
  return base64UrlEncode(signature).slice(0, SIGNATURE_LENGTH);
}

/** Conteúdo que vai impresso no QR Code da quadra. */
export async function buildCourtQrPayload(
  courtId: string,
  version: number,
  secret: string,
): Promise<string> {
  const signature = await signCourt(courtId, version, secret);
  return `${QR_PREFIX}:v${version}:${courtId.toLowerCase()}:${signature}`;
}

/** Faz o parse sem validar a assinatura. */
export function parseCourtQrPayload(raw: string): CourtQrPayload {
  const value = raw.trim();
  const parts = value.split(":");

  if (parts.length !== 4 || parts[0] !== QR_PREFIX) {
    throw new InvalidQrError("Formato do QR Code não reconhecido");
  }

  const version = Number(parts[1].replace(/^v/, ""));
  const courtId = parts[2];
  const signature = parts[3];

  if (!Number.isInteger(version) || version < 1) {
    throw new InvalidQrError("Versão do QR Code inválida");
  }
  if (!UUID_RE.test(courtId)) {
    throw new InvalidQrError("Identificador de quadra inválido");
  }
  if (signature.length !== SIGNATURE_LENGTH) {
    throw new InvalidQrError("Assinatura do QR Code inválida");
  }

  return { version, courtId: courtId.toLowerCase(), signature };
}

/** Comparação em tempo constante — evita timing attack na assinatura. */
export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

/** Parse + verificação da assinatura. */
export async function verifyCourtQrPayload(
  raw: string,
  secret: string,
): Promise<CourtQrPayload> {
  const payload = parseCourtQrPayload(raw);
  const expected = await signCourt(payload.courtId, payload.version, secret);

  if (!timingSafeEqual(payload.signature, expected)) {
    throw new InvalidQrError("Assinatura do QR Code não confere");
  }

  return payload;
}
