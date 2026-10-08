/**
 * Web Push para a versão web do NEQST.
 *
 * A Expo Push API cobre Android (FCM) e iOS (APNs), mas não entrega em
 * navegador. O PWA usa o protocolo padrão:
 *
 *   - RFC 8291: criptografia da mensagem (ECDH P-256 + HKDF + AES-128-GCM)
 *   - RFC 8188: enquadramento `aes128gcm`
 *   - RFC 8292: autenticação do servidor via VAPID (JWT ES256)
 *
 * Tudo com WebCrypto — nenhuma dependência externa.
 */
import { base64UrlDecode, base64UrlEncode, concatBytes, uint32BE, utf8 } from "./bytes.ts";

export const DEFAULT_RECORD_SIZE = 4096;
export const DEFAULT_TTL_SECONDS = 900;
/** VAPID permite até 24h; 12h dá folga sem esticar a validade do token. */
export const VAPID_EXPIRY_SECONDS = 12 * 60 * 60;

export interface WebPushSubscription {
  endpoint: string;
  /** Chave pública da subscription (ponto P-256 não comprimido, 65 bytes). */
  p256dh: string;
  /** Segredo de autenticação da subscription (16 bytes). */
  auth: string;
}

export interface VapidKeys {
  publicKey: string;
  privateKey: string;
  /** mailto: ou https: de contato, exigido pelos push services. */
  subject: string;
}

export class WebPushError extends Error {
  constructor(
    message: string,
    readonly status: number,
    readonly endpoint: string,
  ) {
    super(message);
    this.name = "WebPushError";
  }

  /** 404/410: o navegador descartou a subscription — desative-a. */
  get isGone(): boolean {
    return this.status === 404 || this.status === 410;
  }
}

// ---------------------------------------------------------------------
// HKDF (RFC 5869) sobre HMAC-SHA-256
// ---------------------------------------------------------------------

async function hmacSha256(key: Uint8Array, data: Uint8Array): Promise<Uint8Array> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    key as BufferSource,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  return new Uint8Array(await crypto.subtle.sign("HMAC", cryptoKey, data as BufferSource));
}

/** HKDF-Extract + Expand para um único bloco (saída <= 32 bytes). */
export async function hkdf(
  salt: Uint8Array,
  ikm: Uint8Array,
  info: Uint8Array,
  length: number,
): Promise<Uint8Array> {
  if (length > 32) {
    throw new Error("hkdf: esta implementação cobre apenas saídas de até 32 bytes");
  }
  const prk = await hmacSha256(salt, ikm);
  const okm = await hmacSha256(prk, concatBytes(info, new Uint8Array([1])));
  return okm.slice(0, length);
}

// ---------------------------------------------------------------------
// Chaves
// ---------------------------------------------------------------------

/**
 * Importa uma chave privada P-256 crua (32 bytes) para ECDH.
 * Precisa do ponto público para montar a JWK — WebCrypto não aceita
 * chave privada EC sem as coordenadas.
 */
async function importEcdhPrivateKey(
  privateKey: Uint8Array,
  publicKey: Uint8Array,
): Promise<CryptoKey> {
  return await crypto.subtle.importKey(
    "jwk",
    {
      kty: "EC",
      crv: "P-256",
      d: base64UrlEncode(privateKey),
      x: base64UrlEncode(publicKey.slice(1, 33)),
      y: base64UrlEncode(publicKey.slice(33, 65)),
      ext: true,
    },
    { name: "ECDH", namedCurve: "P-256" },
    false,
    ["deriveBits"],
  );
}

async function importEcdhPublicKey(publicKey: Uint8Array): Promise<CryptoKey> {
  return await crypto.subtle.importKey(
    "raw",
    publicKey as BufferSource,
    { name: "ECDH", namedCurve: "P-256" },
    false,
    [],
  );
}

export interface ServerKeyPair {
  publicKey: Uint8Array;
  privateKey: CryptoKey;
}

/** Par efêmero usado em uma única mensagem (RFC 8291 exige novo par por mensagem). */
export async function generateServerKeyPair(): Promise<ServerKeyPair> {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDH", namedCurve: "P-256" },
    true,
    ["deriveBits"],
  );
  const publicKey = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
  return { publicKey, privateKey: pair.privateKey };
}

/** Par fixo, para testes determinísticos. */
export async function serverKeyPairFrom(
  publicKey: Uint8Array,
  privateKey: Uint8Array,
): Promise<ServerKeyPair> {
  return {
    publicKey,
    privateKey: await importEcdhPrivateKey(privateKey, publicKey),
  };
}

// ---------------------------------------------------------------------
// Criptografia da mensagem (RFC 8291 §3, enquadramento RFC 8188 §2.1)
// ---------------------------------------------------------------------

export interface EncryptResult {
  body: Uint8Array;
  salt: Uint8Array;
  serverPublicKey: Uint8Array;
}

export async function encryptPushPayload(options: {
  payload: string | Uint8Array;
  p256dh: string;
  auth: string;
  salt?: Uint8Array;
  serverKeys?: ServerKeyPair;
  recordSize?: number;
}): Promise<EncryptResult> {
  const plaintext = typeof options.payload === "string" ? utf8(options.payload) : options.payload;
  const uaPublic = base64UrlDecode(options.p256dh);
  const authSecret = base64UrlDecode(options.auth);
  const recordSize = options.recordSize ?? DEFAULT_RECORD_SIZE;

  if (uaPublic.length !== 65 || uaPublic[0] !== 0x04) {
    throw new Error("p256dh inválida: esperado ponto P-256 não comprimido de 65 bytes");
  }

  const salt = options.salt ?? crypto.getRandomValues(new Uint8Array(16));
  const serverKeys = options.serverKeys ?? await generateServerKeyPair();

  // 1. Segredo compartilhado ECDH.
  const sharedSecret = new Uint8Array(
    await crypto.subtle.deriveBits(
      { name: "ECDH", public: await importEcdhPublicKey(uaPublic) },
      serverKeys.privateKey,
      256,
    ),
  );

  // 2. IKM, com o contexto amarrando as duas chaves públicas (RFC 8291 §3.3).
  const keyInfo = concatBytes(
    utf8("WebPush: info"),
    new Uint8Array([0]),
    uaPublic,
    serverKeys.publicKey,
  );
  const ikm = await hkdf(authSecret, sharedSecret, keyInfo, 32);

  // 3. Chave e nonce do AES-GCM.
  const cek = await hkdf(salt, ikm, utf8("Content-Encoding: aes128gcm\0"), 16);
  const nonce = await hkdf(salt, ikm, utf8("Content-Encoding: nonce\0"), 12);

  // 4. Registro único: texto + delimitador final 0x02 (RFC 8188 §2).
  const padded = concatBytes(plaintext, new Uint8Array([2]));
  if (padded.length + 16 > recordSize) {
    throw new Error(`Mensagem grande demais para um registro de ${recordSize} bytes`);
  }

  const aesKey = await crypto.subtle.importKey(
    "raw",
    cek as BufferSource,
    { name: "AES-GCM" },
    false,
    ["encrypt"],
  );
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: nonce as BufferSource, tagLength: 128 },
      aesKey,
      padded as BufferSource,
    ),
  );

  // 5. Cabeçalho aes128gcm: salt | rs | idlen | keyid | ciphertext.
  const body = concatBytes(
    salt,
    uint32BE(recordSize),
    new Uint8Array([serverKeys.publicKey.length]),
    serverKeys.publicKey,
    ciphertext,
  );

  return { body, salt, serverPublicKey: serverKeys.publicKey };
}

// ---------------------------------------------------------------------
// VAPID (RFC 8292)
// ---------------------------------------------------------------------

/** Origem do endpoint — é o `aud` do JWT. */
export function audienceOf(endpoint: string): string {
  return new URL(endpoint).origin;
}

export async function createVapidToken(
  endpoint: string,
  keys: VapidKeys,
  now: Date = new Date(),
): Promise<string> {
  if (!/^(mailto:|https:)/.test(keys.subject)) {
    throw new Error("VAPID subject deve começar com mailto: ou https:");
  }

  const header = { typ: "JWT", alg: "ES256" };
  const claims = {
    aud: audienceOf(endpoint),
    exp: Math.floor(now.getTime() / 1000) + VAPID_EXPIRY_SECONDS,
    sub: keys.subject,
  };

  const signingInput = [
    base64UrlEncode(utf8(JSON.stringify(header))),
    base64UrlEncode(utf8(JSON.stringify(claims))),
  ].join(".");

  const publicKey = base64UrlDecode(keys.publicKey);
  const signingKey = await crypto.subtle.importKey(
    "jwk",
    {
      kty: "EC",
      crv: "P-256",
      d: base64UrlEncode(base64UrlDecode(keys.privateKey)),
      x: base64UrlEncode(publicKey.slice(1, 33)),
      y: base64UrlEncode(publicKey.slice(33, 65)),
      ext: true,
    },
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );

  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      signingKey,
      utf8(signingInput) as BufferSource,
    ),
  );

  return `${signingInput}.${base64UrlEncode(signature)}`;
}

export async function vapidHeaders(
  endpoint: string,
  keys: VapidKeys,
  now?: Date,
): Promise<Record<string, string>> {
  const token = await createVapidToken(endpoint, keys, now);
  return { Authorization: `vapid t=${token}, k=${keys.publicKey}` };
}

// ---------------------------------------------------------------------
// Envio
// ---------------------------------------------------------------------

export async function sendWebPush(
  subscription: WebPushSubscription,
  payload: string,
  keys: VapidKeys,
  options: { ttlSeconds?: number; urgency?: "very-low" | "low" | "normal" | "high" } = {},
): Promise<void> {
  const { body } = await encryptPushPayload({
    payload,
    p256dh: subscription.p256dh,
    auth: subscription.auth,
  });

  const response = await fetch(subscription.endpoint, {
    method: "POST",
    headers: {
      ...(await vapidHeaders(subscription.endpoint, keys)),
      "Content-Encoding": "aes128gcm",
      "Content-Type": "application/octet-stream",
      "TTL": String(options.ttlSeconds ?? DEFAULT_TTL_SECONDS),
      "Urgency": options.urgency ?? "high",
    },
    body: body as BodyInit,
  });

  if (!response.ok) {
    const detail = await response.text().catch(() => "");
    throw new WebPushError(
      `Push service respondeu ${response.status}: ${detail.slice(0, 200)}`,
      response.status,
      subscription.endpoint,
    );
  }
}
