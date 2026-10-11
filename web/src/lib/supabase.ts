import { createClient } from "@supabase/supabase-js";
import { env } from "./env";

/**
 * PKCE é o fluxo correto para app que roda no navegador: o code verifier
 * fica no device e o token nunca aparece na URL.
 */
export const supabase = createClient(env.supabaseUrl, env.supabaseAnonKey, {
  auth: {
    flowType: "pkce",
    detectSessionInUrl: true,
    persistSession: true,
    autoRefreshToken: true,
  },
});

/** Chama uma Edge Function com o JWT do usuário logado. */
export async function callFunction<T>(
  path: string,
  init: { method?: string; body?: unknown } = {},
): Promise<T> {
  const { data: { session } } = await supabase.auth.getSession();

  const response = await fetch(`${env.supabaseUrl}/functions/v1/${path}`, {
    method: init.method ?? "POST",
    headers: {
      "Content-Type": "application/json",
      apikey: env.supabaseAnonKey,
      ...(session ? { Authorization: `Bearer ${session.access_token}` } : {}),
    },
    body: init.body === undefined ? undefined : JSON.stringify(init.body),
  });

  const payload = await response.json().catch(() => null);

  if (!response.ok) {
    throw functionError(response.status, path, payload);
  }

  return payload as T;
}

/**
 * Erro de uma Edge Function.
 *
 * Dois formatos convivem: o nosso (`{ error: { code, message } }`) e o
 * do próprio Supabase, que responde `{ code, message }` na raiz quando
 * a requisição nem chega à função. O segundo caía no texto genérico
 * "A chamada falhou (404)", que não dizia o principal: a função não
 * está publicada no projeto.
 */
function functionError(status: number, path: string, payload: unknown): ApiError {
  const body = (payload ?? {}) as {
    error?: { code?: string; message?: string };
    code?: number | string;
    message?: string;
  };

  const ours = body.error;
  if (ours?.message) return new ApiError(ours.code ?? "REQUEST_FAILED", ours.message);

  const name = path.split("?")[0];

  if (status === 404) {
    return new ApiError(
      "FUNCTION_NOT_DEPLOYED",
      `A função "${name}" não está publicada neste projeto do Supabase. `
        + "Publique as Edge Functions (supabase functions deploy) — ver docs/deploy.md.",
    );
  }

  if (status === 401 || status === 403) {
    return new ApiError(
      "FORBIDDEN",
      body.message ?? "Você não tem permissão para esta ação.",
    );
  }

  if (status >= 500) {
    return new ApiError(
      "FUNCTION_ERROR",
      `A função "${name}" respondeu com erro (${status}). `
        + "Veja os logs em Supabase › Edge Functions › Logs.",
    );
  }

  return new ApiError("REQUEST_FAILED", body.message ?? `A chamada falhou (${status}).`);
}

export class ApiError extends Error {
  constructor(readonly code: string, message: string) {
    super(message);
    this.name = "ApiError";
  }
}

/**
 * Traduz o erro das RPCs do Postgres. O backend sinaliza regra de
 * negócio por SQLSTATE (NQ001..NQ020) — ver docs/api.md.
 */
const RPC_MESSAGES: Record<string, string> = {
  NQ001: "Faça login para continuar.",
  NQ002: "Escaneie o QR Code da quadra novamente.",
  NQ003: "Esta quadra está indisponível no momento.",
  NQ004: "Você já está nesta fila.",
  NQ014: "Você já está na fila de outra quadra.",
  NQ015: "Ainda não é a vez do seu time.",
  NQ016: "O tempo para o check-in terminou.",
  NQ017: "A quadra ainda está ocupada.",
  NQ019: "Cor fora da paleta.",
};

export function rpcError(error: { code?: string; message?: string } | null): ApiError {
  const code = error?.code ?? "DATABASE_ERROR";
  // A mensagem do banco já vem em português e costuma ser mais específica.
  return new ApiError(code, error?.message || RPC_MESSAGES[code] || "Não foi possível concluir.");
}
