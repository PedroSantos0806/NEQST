import { assert, assertEquals } from "jsr:@std/assert@1";
import { allowedOrigins, corsHeadersFor, handlePreflight, json } from "./http.ts";

const WEB = "https://app.neqst.com.br";
const STAGING = "https://staging.neqst.com.br";

function requestFrom(origin: string | null, method = "POST"): Request {
  return new Request("https://edge.test/x", {
    method,
    headers: origin ? { Origin: origin } : {},
  });
}

function withEnv(value: string | null, run: () => void): void {
  const previous = Deno.env.get("ALLOWED_ORIGINS");
  if (value === null) Deno.env.delete("ALLOWED_ORIGINS");
  else Deno.env.set("ALLOWED_ORIGINS", value);
  try {
    run();
  } finally {
    if (previous === undefined) Deno.env.delete("ALLOWED_ORIGINS");
    else Deno.env.set("ALLOWED_ORIGINS", previous);
  }
}

Deno.test("sem ALLOWED_ORIGINS cai em * (desenvolvimento)", () => {
  withEnv(null, () => {
    assertEquals(allowedOrigins(), []);
    assertEquals(corsHeadersFor(requestFrom(WEB))["Access-Control-Allow-Origin"], "*");
  });
});

Deno.test("origem na allow-list é refletida", () => {
  withEnv(`${WEB},${STAGING}`, () => {
    assertEquals(corsHeadersFor(requestFrom(WEB))["Access-Control-Allow-Origin"], WEB);
    assertEquals(corsHeadersFor(requestFrom(STAGING))["Access-Control-Allow-Origin"], STAGING);
  });
});

Deno.test("origem fora da allow-list não é refletida", () => {
  withEnv(`${WEB}`, () => {
    const headers = corsHeadersFor(requestFrom("https://site-malicioso.test"));
    assertEquals(headers["Access-Control-Allow-Origin"], WEB);
    assert(headers["Access-Control-Allow-Origin"] !== "https://site-malicioso.test");
  });
});

Deno.test("allow-list tolera espaços e barra final", () => {
  withEnv(` ${WEB}/ ,  ${STAGING} `, () => {
    assertEquals(allowedOrigins(), [WEB, STAGING]);
    assertEquals(corsHeadersFor(requestFrom(WEB))["Access-Control-Allow-Origin"], WEB);
  });
});

Deno.test("app nativo (sem Origin) recebe a primeira origem configurada", () => {
  withEnv(`${WEB},${STAGING}`, () => {
    // Requisições do app não passam por CORS; o valor só não pode quebrar.
    assertEquals(corsHeadersFor(requestFrom(null))["Access-Control-Allow-Origin"], WEB);
  });
});

Deno.test("sempre manda Vary: Origin", () => {
  withEnv(`${WEB},${STAGING}`, () => {
    assertEquals(corsHeadersFor(requestFrom(WEB))["Vary"], "Origin");
  });
});

Deno.test("preflight responde 204 com os cabeçalhos de CORS", () => {
  withEnv(WEB, () => {
    const response = handlePreflight(requestFrom(WEB, "OPTIONS"));
    assert(response, "OPTIONS deveria ser respondido");
    assertEquals(response.status, 204);
    assertEquals(response.headers.get("Access-Control-Allow-Origin"), WEB);
    assert(response.headers.get("Access-Control-Allow-Methods")?.includes("PATCH"));
  });
});

Deno.test("preflight ignora métodos que não são OPTIONS", () => {
  assertEquals(handlePreflight(requestFrom(WEB, "POST")), null);
});

Deno.test("json propaga os cabeçalhos de CORS recebidos", async () => {
  withEnv(WEB, () => {});
  const cors = { "Access-Control-Allow-Origin": WEB };
  const response = json({ ok: true }, 201, cors);

  assertEquals(response.status, 201);
  assertEquals(response.headers.get("Access-Control-Allow-Origin"), WEB);
  assertEquals(response.headers.get("Content-Type"), "application/json");
  assertEquals(await response.json(), { ok: true });
});
