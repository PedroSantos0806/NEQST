import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import { expiresAt, generateScanToken, hashScanToken, SCAN_TOKEN_TTL_SECONDS } from "./tokens.ts";

Deno.test("scan token é aleatório e url-safe", () => {
  const a = generateScanToken();
  const b = generateScanToken();

  assertNotEquals(a, b);
  assert(/^[A-Za-z0-9_-]+$/.test(a), `token não é url-safe: ${a}`);
  assert(a.length >= 40, "token deveria ter ~256 bits");
});

Deno.test("hash é SHA-256 hex determinístico", async () => {
  const hash = await hashScanToken("tok-ana");

  assertEquals(hash.length, 64);
  assert(/^[0-9a-f]{64}$/.test(hash));
  assertEquals(await hashScanToken("tok-ana"), hash);
  assertNotEquals(await hashScanToken("tok-anb"), hash);
});

Deno.test("hash bate com o vetor conhecido de SHA-256", async () => {
  // echo -n "abc" | sha256sum
  assertEquals(
    await hashScanToken("abc"),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  );
});

Deno.test("TTL padrão do scan token é de 30 segundos (US-02)", () => {
  const now = new Date("2026-01-01T12:00:00.000Z");
  assertEquals(SCAN_TOKEN_TTL_SECONDS, 30);
  assertEquals(expiresAt(SCAN_TOKEN_TTL_SECONDS, now).toISOString(), "2026-01-01T12:00:30.000Z");
});
