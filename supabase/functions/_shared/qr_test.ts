import { assert, assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import {
  buildCourtQrPayload,
  InvalidQrError,
  parseCourtQrPayload,
  signCourt,
  timingSafeEqual,
  verifyCourtQrPayload,
} from "./qr.ts";

const SECRET = "segredo-de-teste";
const COURT = "7c9e6679-7425-40de-944b-e07fc1f90ae7";

Deno.test("payload segue o formato neqst:v<versão>:<courtId>:<assinatura>", async () => {
  const payload = await buildCourtQrPayload(COURT, 1, SECRET);
  const parsed = parseCourtQrPayload(payload);

  assertEquals(parsed.courtId, COURT);
  assertEquals(parsed.version, 1);
  assertEquals(parsed.signature.length, 32);
  assert(payload.startsWith("neqst:v1:"));
});

Deno.test("assinatura é determinística e muda com a versão do segredo", async () => {
  const a = await signCourt(COURT, 1, SECRET);
  const b = await signCourt(COURT, 1, SECRET);
  const c = await signCourt(COURT, 2, SECRET);

  assertEquals(a, b);
  assert(a !== c, "rotacionar a versão deve invalidar o QR antigo");
});

Deno.test("assinatura muda com o segredo", async () => {
  const a = await signCourt(COURT, 1, SECRET);
  const b = await signCourt(COURT, 1, "outro-segredo");
  assert(a !== b);
});

Deno.test("verify aceita o payload íntegro", async () => {
  const payload = await buildCourtQrPayload(COURT, 3, SECRET);
  const parsed = await verifyCourtQrPayload(payload, SECRET);
  assertEquals(parsed.version, 3);
});

Deno.test("verify rejeita QR adulterado (troca de quadra)", async () => {
  const payload = await buildCourtQrPayload(COURT, 1, SECRET);
  const forged = payload.replace(COURT, "00000000-0000-0000-0000-000000000000");

  await assertRejects(() => verifyCourtQrPayload(forged, SECRET), InvalidQrError);
});

Deno.test("verify rejeita QR assinado com outro segredo", async () => {
  const payload = await buildCourtQrPayload(COURT, 1, "segredo-antigo");
  await assertRejects(() => verifyCourtQrPayload(payload, SECRET), InvalidQrError);
});

Deno.test("parse rejeita formatos inválidos", () => {
  assertThrows(() => parseCourtQrPayload("https://example.com"), InvalidQrError);
  assertThrows(() => parseCourtQrPayload("neqst:v1:nao-e-uuid:abc"), InvalidQrError);
  assertThrows(() => parseCourtQrPayload(`neqst:v0:${COURT}:${"a".repeat(32)}`), InvalidQrError);
  assertThrows(() => parseCourtQrPayload(`neqst:v1:${COURT}:curta`), InvalidQrError);
});

Deno.test("timingSafeEqual compara corretamente", () => {
  assert(timingSafeEqual("abc", "abc"));
  assert(!timingSafeEqual("abc", "abd"));
  assert(!timingSafeEqual("abc", "abcd"));
});
