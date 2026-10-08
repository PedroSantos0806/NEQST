import { assert, assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import {
  audienceOf,
  createVapidToken,
  encryptPushPayload,
  hkdf,
  serverKeyPairFrom,
  VAPID_EXPIRY_SECONDS,
  vapidHeaders,
  WebPushError,
} from "./webpush.ts";
import { base64UrlDecode, base64UrlEncode, utf8 } from "./bytes.ts";

/**
 * Vetor de referência gerado com chaves fixas e conferido contra a
 * biblioteca `http_ece` do npm — a mesma que o pacote `web-push` usa
 * para RFC 8188/8291. O `expectedBody` abaixo foi decifrado com sucesso
 * por ela, devolvendo exatamente o `plaintext`. Se este teste quebrar,
 * a criptografia saiu do padrão e nenhum navegador vai abrir o push.
 */
const VECTOR = {
  uaPublic:
    "BI6DydQru0N0H9nx-ZDzivuPBTKtTspZfR2io1FGIDz2nsiWyNxxhso_IUt5rLht-vhac2d3u2uQs-ZZBfjHnLE",
  authSecret: "624jYM1lMb8TvcXrOL1saw",
  serverPublic:
    "BCMs1wltDE_GfXo5RD5iBz92IDQF9VbHhuD8Y15tCRv9njegMWAiQe3KSwHY3BA_YSR0HJEU7Tf3RNcQzpX2cPc",
  serverPrivate: "lM_L2Oxa_G8c1Aj5G-0HstsDQVXCpnK8pDMMvOkQznM",
  salt: "k46rSHd2stMAZqn0sKG8WA",
  plaintext: '{"title":"Prepare-se!","body":"Falta 1 time para a sua vez na quadra Central."}',
  expectedBody:
    "k46rSHd2stMAZqn0sKG8WAAAEABBBCMs1wltDE_GfXo5RD5iBz92IDQF9VbHhuD8Y15tCRv9njegMWAiQe3KSwHY3BA_YSR0HJEU7Tf3RNcQzpX2cPcq0-rB86WKgw43RBSlUOdlryoSyPyVUoAfhpNvsTdEGPyRDL9dr1MBWzRSkkN0-Fezi4RntSrddaR2Aqis6xYwNGvJYWHoitC0grJ7s-X9F7_hsSNFkSUHDAsl37SVB_E",
};

Deno.test("encryptPushPayload reproduz o corpo validado pelo http_ece", async () => {
  const { body } = await encryptPushPayload({
    payload: VECTOR.plaintext,
    p256dh: VECTOR.uaPublic,
    auth: VECTOR.authSecret,
    salt: base64UrlDecode(VECTOR.salt),
    serverKeys: await serverKeyPairFrom(
      base64UrlDecode(VECTOR.serverPublic),
      base64UrlDecode(VECTOR.serverPrivate),
    ),
  });

  assertEquals(base64UrlEncode(body), VECTOR.expectedBody);
});

Deno.test("corpo segue o enquadramento aes128gcm: salt | rs | idlen | keyid | ciphertext", async () => {
  const { body, salt, serverPublicKey } = await encryptPushPayload({
    payload: "oi",
    p256dh: VECTOR.uaPublic,
    auth: VECTOR.authSecret,
  });

  assertEquals(body.slice(0, 16), salt, "primeiros 16 bytes devem ser o salt");

  const recordSize = new DataView(body.buffer, body.byteOffset + 16, 4).getUint32(0, false);
  assertEquals(recordSize, 4096);

  assertEquals(body[20], 65, "idlen deve ser 65 (ponto P-256 não comprimido)");
  assertEquals(body.slice(21, 86), serverPublicKey);

  // 2 bytes de texto + 1 delimitador + 16 de tag GCM.
  assertEquals(body.length, 86 + 19);
});

Deno.test("cada mensagem usa salt e chave efêmera novos", async () => {
  const first = await encryptPushPayload({
    payload: "x",
    p256dh: VECTOR.uaPublic,
    auth: VECTOR.authSecret,
  });
  const second = await encryptPushPayload({
    payload: "x",
    p256dh: VECTOR.uaPublic,
    auth: VECTOR.authSecret,
  });

  assert(base64UrlEncode(first.salt) !== base64UrlEncode(second.salt));
  assert(
    base64UrlEncode(first.serverPublicKey) !== base64UrlEncode(second.serverPublicKey),
    "reusar o par efêmero quebraria a garantia do RFC 8291",
  );
});

Deno.test("rejeita p256dh fora do formato esperado", async () => {
  await assertRejects(
    () =>
      encryptPushPayload({
        payload: "x",
        p256dh: base64UrlEncode(new Uint8Array(65)), // primeiro byte != 0x04
        auth: VECTOR.authSecret,
      }),
    Error,
    "p256dh inválida",
  );

  await assertRejects(
    () => encryptPushPayload({ payload: "x", p256dh: "YWJj", auth: VECTOR.authSecret }),
    Error,
    "p256dh inválida",
  );
});

Deno.test("recusa mensagem que não cabe num registro", async () => {
  await assertRejects(
    () =>
      encryptPushPayload({
        payload: "a".repeat(200),
        p256dh: VECTOR.uaPublic,
        auth: VECTOR.authSecret,
        recordSize: 100,
      }),
    Error,
    "grande demais",
  );
});

Deno.test("hkdf só atende saídas de até 32 bytes", async () => {
  const out = await hkdf(new Uint8Array(16), new Uint8Array(32), utf8("info"), 16);
  assertEquals(out.length, 16);

  await assertRejects(
    () => hkdf(new Uint8Array(16), new Uint8Array(32), utf8("info"), 64),
    Error,
  );
});

// -------------------------------------------------------------------
// VAPID (RFC 8292)
// -------------------------------------------------------------------

const VAPID = {
  publicKey: VECTOR.serverPublic,
  privateKey: VECTOR.serverPrivate,
  subject: "mailto:ops@neqst.app",
};

Deno.test("audienceOf devolve só a origem do endpoint", () => {
  assertEquals(
    audienceOf("https://fcm.googleapis.com/fcm/send/abc:123?x=1"),
    "https://fcm.googleapis.com",
  );
  assertEquals(
    audienceOf("https://updates.push.services.mozilla.com/wpush/v2/gAAA"),
    "https://updates.push.services.mozilla.com",
  );
});

Deno.test("token VAPID traz aud, sub e exp corretos", async () => {
  const now = new Date("2026-10-08T12:00:00.000Z");
  const token = await createVapidToken(
    "https://fcm.googleapis.com/fcm/send/abc",
    VAPID,
    now,
  );

  const [header, claims, signature] = token.split(".");
  assertEquals(
    JSON.parse(new TextDecoder().decode(base64UrlDecode(header))),
    { typ: "JWT", alg: "ES256" },
  );

  const parsed = JSON.parse(new TextDecoder().decode(base64UrlDecode(claims)));
  assertEquals(parsed.aud, "https://fcm.googleapis.com");
  assertEquals(parsed.sub, "mailto:ops@neqst.app");
  assertEquals(parsed.exp, Math.floor(now.getTime() / 1000) + VAPID_EXPIRY_SECONDS);

  // ES256 = r||s de 32 bytes cada.
  assertEquals(base64UrlDecode(signature).length, 64);
});

Deno.test("assinatura do token VAPID confere com a chave pública", async () => {
  const token = await createVapidToken("https://example.com/push/x", VAPID);
  const [header, claims, signature] = token.split(".");

  const publicKey = base64UrlDecode(VAPID.publicKey);
  const verifyKey = await crypto.subtle.importKey(
    "jwk",
    {
      kty: "EC",
      crv: "P-256",
      x: base64UrlEncode(publicKey.slice(1, 33)),
      y: base64UrlEncode(publicKey.slice(33, 65)),
      ext: true,
    },
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["verify"],
  );

  assert(
    await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      verifyKey,
      base64UrlDecode(signature) as BufferSource,
      utf8(`${header}.${claims}`) as BufferSource,
    ),
    "o push service precisa conseguir verificar a assinatura",
  );
});

Deno.test("header Authorization segue o esquema vapid t=..., k=...", async () => {
  const headers = await vapidHeaders("https://example.com/push/x", VAPID);
  assert(headers.Authorization.startsWith("vapid t="));
  assert(headers.Authorization.includes(`, k=${VAPID.publicKey}`));
});

Deno.test("subject sem mailto:/https: é recusado", async () => {
  await assertRejects(
    () =>
      createVapidToken("https://example.com/push/x", {
        ...VAPID,
        subject: "ops@neqst.app",
      }),
    Error,
    "mailto:",
  );
});

Deno.test("WebPushError identifica subscription descartada pelo navegador", () => {
  assert(new WebPushError("gone", 410, "https://x/y").isGone);
  assert(new WebPushError("not found", 404, "https://x/y").isGone);
  assert(!new WebPushError("rate limited", 429, "https://x/y").isGone);
});

Deno.test("base64url ida e volta preserva os bytes", () => {
  const bytes = crypto.getRandomValues(new Uint8Array(70));
  assertEquals(base64UrlDecode(base64UrlEncode(bytes)), bytes);
  assertThrows(() => {
    // Caractere fora do alfabeto base64url.
    base64UrlDecode("!!!!");
  });
});
