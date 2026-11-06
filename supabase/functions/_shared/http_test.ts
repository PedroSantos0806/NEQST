import { assert, assertEquals } from "jsr:@std/assert@1";
import { allowedOrigins, corsHeadersFor, handlePreflight, json } from "./http.ts";

const WEB = "https://app.neqst.com.br";
const STAGING = "https://staging.neqst.com.br";
/** Como SUPABASE_URL fica num projeto hospedado (não é localhost). */
const HOSPEDADO = "https://projeto.supabase.co";
const LOCAL = "http://localhost:54321";

function requestFrom(origin: string | null, method = "POST"): Request {
  return new Request("https://edge.test/x", {
    method,
    headers: origin ? { Origin: origin } : {},
  });
}

function withEnvVars(vars: Record<string, string | null>, run: () => void): void {
  const previous = new Map<string, string | undefined>();

  for (const [name, value] of Object.entries(vars)) {
    previous.set(name, Deno.env.get(name));
    if (value === null) Deno.env.delete(name);
    else Deno.env.set(name, value);
  }

  try {
    run();
  } finally {
    for (const [name, value] of previous) {
      if (value === undefined) Deno.env.delete(name);
      else Deno.env.set(name, value);
    }
  }
}

/**
 * Caso comum: só a allow-list varia, e SUPABASE_URL fica como num
 * projeto hospedado — que é onde o fail-closed precisa valer.
 */
function withEnv(value: string | null, run: () => void): void {
  withEnvVars({ ALLOWED_ORIGINS: value, SUPABASE_URL: HOSPEDADO }, run);
}

Deno.test("sem ALLOWED_ORIGINS, projeto hospedado não libera origem nenhuma", () => {
  // Este teste exigia "*" aqui, e era o "*" que a auditoria apontou:
  // esquecer a variável nas Edge Functions (configuradas separadamente
  // do .env) abria as 12 funções para qualquer site, em silêncio.
  withEnv(null, () => {
    assertEquals(allowedOrigins(), []);
    assertEquals(corsHeadersFor(requestFrom(WEB))["Access-Control-Allow-Origin"], "null");
  });
});

Deno.test("sem ALLOWED_ORIGINS, desenvolvimento local ainda cai em *", () => {
  // O CLI local define SUPABASE_URL para localhost; quem roda na
  // própria máquina não precisa configurar allow-list para testar.
  withEnvVars({ ALLOWED_ORIGINS: null, SUPABASE_URL: LOCAL }, () => {
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
