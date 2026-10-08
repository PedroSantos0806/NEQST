/**
 * Helpers de HTTP compartilhados pelas Edge Functions do NEQST.
 */

const ALLOWED_HEADERS = "authorization, x-client-info, apikey, content-type, x-cron-secret";
const ALLOWED_METHODS = "POST, GET, PATCH, DELETE, OPTIONS";

/**
 * Origens liberadas, de ALLOWED_ORIGINS (lista separada por vírgula).
 *
 * O app nativo não manda Origin, então CORS não o afeta. Quem precisa
 * disso é a versão web: com a allow-list, um site de terceiros não
 * consegue chamar a API a partir do navegador de quem está logado.
 * Sem a variável configurada, cai em "*" — serve para desenvolvimento,
 * mas produção deve declarar as origens (ver docs/deploy.md).
 */
export function allowedOrigins(): string[] {
  return (Deno.env.get("ALLOWED_ORIGINS") ?? "")
    .split(",")
    .map((origin) => origin.trim().replace(/\/+$/, ""))
    .filter((origin) => origin.length > 0);
}

export function corsHeadersFor(req: Request | null): Record<string, string> {
  const allowList = allowedOrigins();
  const origin = req?.headers.get("Origin") ?? null;

  const allowOrigin = allowList.length === 0
    ? "*"
    : origin && allowList.includes(origin.replace(/\/+$/, ""))
    ? origin
    : allowList[0];

  return {
    "Access-Control-Allow-Origin": allowOrigin,
    "Access-Control-Allow-Headers": ALLOWED_HEADERS,
    "Access-Control-Allow-Methods": ALLOWED_METHODS,
    "Access-Control-Max-Age": "86400",
    // Sem Vary, um cache compartilhado devolveria a origem de outro site.
    "Vary": "Origin",
  };
}

/** Compatibilidade: cabeçalhos permissivos sem acesso ao request. */
export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": ALLOWED_HEADERS,
  "Access-Control-Allow-Methods": ALLOWED_METHODS,
};

export function json(
  body: unknown,
  status = 200,
  cors: Record<string, string> = corsHeaders,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

/** Erro de negócio com código estável, consumido pelo app. */
export class ApiError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly status = 400,
    readonly details?: unknown,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

export function errorResponse(
  error: unknown,
  cors: Record<string, string> = corsHeaders,
): Response {
  if (error instanceof ApiError) {
    return json(
      { error: { code: error.code, message: error.message, details: error.details } },
      error.status,
      cors,
    );
  }

  console.error("unhandled_error", error);
  return json(
    { error: { code: "INTERNAL_ERROR", message: "Erro inesperado. Tente novamente." } },
    500,
    cors,
  );
}

export function handlePreflight(
  req: Request,
  cors: Record<string, string> = corsHeadersFor(req),
): Response | null {
  return req.method === "OPTIONS" ? new Response(null, { status: 204, headers: cors }) : null;
}

export function requireMethod(req: Request, method: string): void {
  if (req.method !== method) {
    throw new ApiError("METHOD_NOT_ALLOWED", `Use ${method} nesta rota.`, 405);
  }
}

export async function readJson<T>(req: Request): Promise<T> {
  try {
    return (await req.json()) as T;
  } catch {
    throw new ApiError("INVALID_JSON", "Corpo da requisição deve ser JSON válido.", 400);
  }
}

export function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    throw new ApiError("MISSING_CONFIG", `Variável de ambiente ausente: ${name}`, 500);
  }
  return value;
}

/**
 * Traduz o SQLSTATE das RPCs (NQ001..NQ009) para erro de API.
 * Ver supabase/migrations/20260923120600_queue_functions.sql.
 */
const PG_ERROR_MAP: Record<string, { code: string; status: number }> = {
  NQ001: { code: "UNAUTHENTICATED", status: 401 },
  NQ002: { code: "SCAN_TOKEN_INVALID", status: 400 },
  NQ003: { code: "COURT_UNAVAILABLE", status: 409 },
  NQ004: { code: "ALREADY_IN_QUEUE", status: 409 },
  NQ005: { code: "PARTNER_NOT_FOUND", status: 404 },
  NQ006: { code: "PARTNER_INVALID", status: 409 },
  NQ007: { code: "ENTRY_NOT_FOUND", status: 404 },
  NQ008: { code: "FORBIDDEN", status: 403 },
  NQ009: { code: "INVALID_STATE", status: 409 },
};

export function postgrestError(
  error: { code?: string; message?: string; details?: string },
): never {
  const mapped = error.code ? PG_ERROR_MAP[error.code] : undefined;
  throw new ApiError(
    mapped?.code ?? "DATABASE_ERROR",
    error.message ?? "Falha ao executar a operação.",
    mapped?.status ?? 400,
    error.details,
  );
}

// ---------------------------------------------------------------------
// Wrapper das Edge Functions
// ---------------------------------------------------------------------

/** Reescreve os cabeçalhos de CORS de uma resposta já montada. */
export function withCorsHeaders(
  response: Response,
  cors: Record<string, string>,
): Response {
  const headers = new Headers(response.headers);
  for (const [name, value] of Object.entries(cors)) headers.set(name, value);
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

/**
 * Ponto de entrada de toda Edge Function: resolve o CORS da origem que
 * chamou, responde ao preflight e traduz exceções em erro de API.
 *
 * Centralizar isso é o que garante que a versão web receba os
 * cabeçalhos certos em todas as rotas — inclusive nas de erro, onde
 * esquecer o CORS faz o navegador esconder a mensagem do usuário.
 */
export function serve(handler: (req: Request) => Promise<Response>): void {
  Deno.serve(async (req) => {
    const cors = corsHeadersFor(req);

    const preflight = handlePreflight(req, cors);
    if (preflight) return preflight;

    try {
      return withCorsHeaders(await handler(req), cors);
    } catch (error) {
      return errorResponse(error, cors);
    }
  });
}
