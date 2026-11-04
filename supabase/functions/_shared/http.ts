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
 * Sem a variável configurada, só o desenvolvimento local cai em "*".
 * Em produção, origem liberada sem lista é fail-open silencioso: as 12
 * funções ficariam abertas para qualquer site, sem nenhum sinal de que
 * alguém esqueceu de configurar. As variáveis das Edge Functions são
 * configuradas separadamente do .env, então esquecer é fácil.
 */
export function allowedOrigins(): string[] {
  return (Deno.env.get("ALLOWED_ORIGINS") ?? "")
    .split(",")
    .map((origin) => origin.trim().replace(/\/+$/, ""))
    .filter((origin) => origin.length > 0);
}

/**
 * Ambiente onde "sem allow-list" ainda pode significar "libera tudo".
 *
 * O Supabase CLI local define SUPABASE_URL para localhost; num projeto
 * hospedado é o domínio do projeto. Então o fallback permissivo vale
 * para quem está rodando na própria máquina, e só.
 */
function isLocalDev(): boolean {
  const url = Deno.env.get("SUPABASE_URL") ?? "";
  return /^https?:\/\/(localhost|127\.0\.0\.1|\[::1\]|host\.docker\.internal)(:|\/|$)/.test(url);
}

export function corsHeadersFor(req: Request | null): Record<string, string> {
  const allowList = allowedOrigins();
  const origin = req?.headers.get("Origin") ?? null;

  // Fail-closed: sem lista e fora do desenvolvimento local, nenhuma
  // origem é liberada. O app nativo não manda Origin e segue
  // funcionando; a web quebra de forma visível, que é o ponto — melhor
  // que ficar aberta em silêncio.
  const allowOrigin = allowList.length === 0
    ? (isLocalDev() ? "*" : "null")
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
 * Traduz o SQLSTATE das RPCs (NQ001..NQ035) para erro de API.
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
  NQ010: { code: "NEVER_PLAYED_HERE", status: 403 },
  NQ011: { code: "INVALID_RATING", status: 400 },
  NQ012: { code: "PHOTO_QUOTA_REACHED", status: 429 },
  NQ013: { code: "PHOTO_NOT_FOUND", status: 404 },
  NQ014: { code: "ALREADY_IN_ANOTHER_QUEUE", status: 409 },
  NQ015: { code: "NOT_YOUR_TURN", status: 409 },
  NQ016: { code: "CALL_EXPIRED", status: 410 },
  NQ017: { code: "COURT_BUSY", status: 409 },
  NQ018: { code: "MATCH_NOT_FOUND", status: 404 },
  NQ019: { code: "COLOR_NOT_IN_PALETTE", status: 400 },
  NQ020: { code: "PARK_NOT_FOUND", status: 404 },
  // NQ021-NQ026 e NQ036-NQ037 ficaram de fora do mapa e caíam em
  // DATABASE_ERROR/400 com a mensagem crua do Postgres — inclusive o
  // "Ação restrita ao administrador", que é 403, não 400.
  NQ021: { code: "PROFILE_NOT_FOUND", status: 404 },
  NQ022: { code: "ADMIN_ALREADY_EXISTS", status: 409 },
  NQ023: { code: "ADMIN_ONLY", status: 403 },
  NQ024: { code: "INVALID_INPUT", status: 400 },
  NQ025: { code: "COURT_NUMBER_TAKEN", status: 409 },
  NQ026: { code: "PARK_SLUG_TAKEN", status: 409 },
  NQ027: { code: "JOIN_REQUEST_NOT_PENDING", status: 409 },
  NQ028: { code: "PIN_ATTEMPTS_EXCEEDED", status: 429 },
  NQ029: { code: "PARTNER_MUST_SCAN", status: 400 },
  NQ030: { code: "NOT_HOST_MODE", status: 409 },
  NQ031: { code: "HOST_QUEUE_ALREADY_OPEN", status: 409 },
  NQ032: { code: "HOST_QUEUE_INVALID", status: 400 },
  NQ033: { code: "NOT_THE_HOST", status: 403 },
  NQ034: { code: "HOST_QUEUE_CLOSED", status: 409 },
  NQ035: { code: "HOST_MODE_NEEDS_PROXIMITY", status: 400 },
  NQ036: { code: "INVALID_MATCH_TIME", status: 400 },
  NQ037: { code: "TABLET_NOT_LINKED", status: 403 },
};

/**
 * Erro do Postgres virando erro de API.
 *
 * O que é regra de negócio (os SQLSTATEs NQ*, as CHECK constraints) tem
 * tradução e vai para a pessoa: a mensagem diz o que fazer. O que NÃO
 * está no mapa é defeito nosso, e aí a mensagem crua do Postgres
 * entrega nome de tabela, de coluna e de constraint para quem mandou um
 * id malformado de propósito — enumeração de schema de graça. Nesse
 * caso o cliente recebe uma frase genérica, e o detalhe fica no log.
 */
export function postgrestError(
  error: { code?: string; message?: string; details?: string },
): never {
  const mapped = error.code ? PG_ERROR_MAP[error.code] : undefined;

  if (!mapped) {
    console.error("postgrest sem tradução", {
      code: error.code,
      message: error.message,
      details: error.details,
    });
    throw new ApiError(
      "DATABASE_ERROR",
      "Não foi possível concluir a operação. Tente de novo.",
      500,
    );
  }

  throw new ApiError(mapped.code, error.message ?? "Falha ao executar a operação.", mapped.status, error.details);
}

/**
 * Um id que vem da URL ou do corpo precisa ser UUID antes de chegar ao
 * banco: string arbitrária volta como erro cru do Postgres, e um id
 * malformado numa lista derrubava o lote inteiro (as capas das quadras
 * na home, por exemplo).
 */
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function requireUuid(value: unknown, field: string): string {
  const text = typeof value === "string" ? value.trim() : "";
  if (!UUID.test(text)) {
    throw new ApiError("INVALID_ID", `${field} deve ser um UUID válido.`, 400);
  }
  return text;
}

/** Vários ids de uma vez, como em ?courtIds=a,b,c. */
export function requireUuids(values: unknown, field: string, max = 100): string[] {
  const list = Array.isArray(values)
    ? values
    : typeof values === "string"
    ? values.split(",")
    : [];

  if (list.length === 0) {
    throw new ApiError("INVALID_ID", `${field} está vazio.`, 400);
  }
  if (list.length > max) {
    throw new ApiError("INVALID_ID", `${field} aceita até ${max} ids.`, 400);
  }

  return list.map((value) => requireUuid(value, field));
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
