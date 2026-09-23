/**
 * Helpers de HTTP compartilhados pelas Edge Functions do NEQST.
 */

export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-cron-secret",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
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

export function errorResponse(error: unknown): Response {
  if (error instanceof ApiError) {
    return json(
      { error: { code: error.code, message: error.message, details: error.details } },
      error.status,
    );
  }

  console.error("unhandled_error", error);
  return json(
    { error: { code: "INTERNAL_ERROR", message: "Erro inesperado. Tente novamente." } },
    500,
  );
}

export function handlePreflight(req: Request): Response | null {
  return req.method === "OPTIONS" ? new Response("ok", { headers: corsHeaders }) : null;
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
