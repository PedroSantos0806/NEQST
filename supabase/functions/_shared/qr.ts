/**
 * QR Code das quadras (US-02).
 *
 * O QR impresso é estático e carrega o ID da quadra + uma assinatura
 * HMAC-SHA256 truncada. Sem o segredo (`QR_SIGNING_SECRET`) ninguém
 * consegue forjar um QR válido para uma quadra que não existe.
 *
 * Dois formatos, com a mesma assinatura:
 *
 *   1. Esquema próprio   neqst:v1:<courtId>:<assinatura>
 *   2. App Link https    https://app.neqst.com.br/q/<courtId>?v=1&s=<assinatura>
 *
 * O formato 2 é o que vai impresso nas quadras. Como o NEQST roda na web
 * e como app na Play Store, o QR precisa funcionar nos dois: a câmera
 * nativa do Android abre o app instalado (App Links, via
 * assetlinks.json) e, se não houver app, cai no site. Um QR com esquema
 * `neqst:` não é clicável pela câmera do sistema — só pelo scanner de
 * dentro do app. O formato 1 continua aceito para não invalidar código
 * já impresso.
 *
 * O "timeout de 30s" do critério de aceite NÃO vive no QR (que é
 * impresso e imutável): ele é o TTL do scan token emitido por
 * `scan-court` depois de validar assinatura + distância.
 */

export const QR_PREFIX = "neqst";
export const QR_URL_PATH = "/q";
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

/** Formato 1 — esquema próprio, lido pelo scanner de dentro do app. */
export async function buildCourtQrPayload(
  courtId: string,
  version: number,
  secret: string,
): Promise<string> {
  const signature = await signCourt(courtId, version, secret);
  return `${QR_PREFIX}:v${version}:${courtId.toLowerCase()}:${signature}`;
}

/**
 * Formato 2 — App Link https, que é o que deve ser impresso.
 * `baseUrl` é a origem pública do app web (ex.: https://app.neqst.com.br).
 */
export async function buildCourtQrUrl(
  courtId: string,
  version: number,
  secret: string,
  baseUrl: string,
): Promise<string> {
  const signature = await signCourt(courtId, version, secret);
  const base = baseUrl.replace(/\/+$/, "");
  return `${base}${QR_URL_PATH}/${courtId.toLowerCase()}?v=${version}&s=${signature}`;
}

function parseSchemePayload(value: string): CourtQrPayload {
  const parts = value.split(":");

  if (parts.length !== 4 || parts[0] !== QR_PREFIX) {
    throw new InvalidQrError("Formato do QR Code não reconhecido");
  }

  return assertPayload(parts[1].replace(/^v/, ""), parts[2], parts[3]);
}

function parseUrlPayload(value: string): CourtQrPayload {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new InvalidQrError("Formato do QR Code não reconhecido");
  }

  // Aceita /q/<courtId> em qualquer host: o host é só o atalho de
  // abertura; o que autentica a quadra é a assinatura.
  const match = url.pathname.match(/\/q\/([^/]+)\/?$/);
  if (!match) {
    throw new InvalidQrError("Formato do QR Code não reconhecido");
  }

  return assertPayload(
    url.searchParams.get("v") ?? "",
    match[1],
    url.searchParams.get("s") ?? "",
  );
}

function assertPayload(
  rawVersion: string,
  rawCourtId: string,
  signature: string,
): CourtQrPayload {
  const version = Number(rawVersion);

  if (!Number.isInteger(version) || version < 1) {
    throw new InvalidQrError("Versão do QR Code inválida");
  }
  if (!UUID_RE.test(rawCourtId)) {
    throw new InvalidQrError("Identificador de quadra inválido");
  }
  if (signature.length !== SIGNATURE_LENGTH) {
    throw new InvalidQrError("Assinatura do QR Code inválida");
  }

  return { version, courtId: rawCourtId.toLowerCase(), signature };
}

/** Faz o parse de qualquer um dos dois formatos, sem validar a assinatura. */
export function parseCourtQrPayload(raw: string): CourtQrPayload {
  const value = raw.trim();
  return /^https?:\/\//i.test(value) ? parseUrlPayload(value) : parseSchemePayload(value);
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
