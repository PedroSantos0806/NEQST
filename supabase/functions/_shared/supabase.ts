/**
 * Clientes Supabase usados pelas Edge Functions.
 */
import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2.116.0";
import { ApiError, requireEnv } from "./http.ts";

/**
 * Cliente que atua *como o usuário logado* — RLS e auth.uid() valem.
 * Use este para chamar as RPCs da fila.
 */
export function userClient(req: Request): SupabaseClient {
  const authorization = req.headers.get("Authorization") ?? "";

  if (!authorization.toLowerCase().startsWith("bearer ")) {
    throw new ApiError("UNAUTHENTICATED", "Faça login para continuar.", 401);
  }

  return createClient(
    requireEnv("SUPABASE_URL"),
    requireEnv("SUPABASE_ANON_KEY"),
    {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    },
  );
}

/**
 * Cliente com service_role — ignora RLS.
 * Use apenas onde o backend precisa de privilégio (emitir scan token,
 * despachar push), nunca para repassar dados brutos ao cliente.
 */
export function serviceClient(): SupabaseClient {
  return createClient(
    requireEnv("SUPABASE_URL"),
    requireEnv("SUPABASE_SERVICE_ROLE_KEY"),
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
}

export interface AuthenticatedUser {
  id: string;
  email?: string;
}

/** Valida o JWT do request e devolve o usuário. */
export async function requireUser(req: Request): Promise<{
  user: AuthenticatedUser;
  client: SupabaseClient;
}> {
  const client = userClient(req);
  const { data, error } = await client.auth.getUser();

  if (error || !data?.user) {
    throw new ApiError("UNAUTHENTICATED", "Sessão inválida ou expirada.", 401);
  }

  return { user: { id: data.user.id, email: data.user.email }, client };
}

/** Exige papel staff/admin (operação da quadra). */
export async function requireStaff(userId: string): Promise<"staff" | "admin"> {
  const { data, error } = await serviceClient()
    .from("profiles")
    .select("role")
    .eq("id", userId)
    .single();

  if (error || !data) {
    throw new ApiError("FORBIDDEN", "Perfil não encontrado.", 403);
  }
  if (data.role !== "staff" && data.role !== "admin") {
    throw new ApiError("FORBIDDEN", "Ação restrita à operação da quadra.", 403);
  }

  return data.role;
}
