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
    const error = (payload as { error?: { code?: string; message?: string } } | null)?.error;
    throw new ApiError(
      error?.code ?? "REQUEST_FAILED",
      error?.message ?? `A chamada falhou (${response.status}).`,
    );
  }

  return payload as T;
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
