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
 * negócio por SQLSTATE (NQ001..NQ035) — ver docs/api.md.
 */
const RPC_MESSAGES: Record<string, string> = {
  NQ001: "Faça login para continuar.",
  NQ002: "Escaneie o QR Code da quadra novamente.",
  NQ003: "Esta quadra está indisponível no momento.",
  NQ004: "Você já está nesta fila.",
  NQ014: "Você já está na fila de outra quadra.",
  NQ015: "Ainda não é a vez do seu grupo.",
  NQ016: "O tempo para o check-in terminou.",
  NQ017: "A quadra ainda está ocupada.",
  NQ019: "Cor fora da paleta.",
  NQ027: "Este pedido não está mais pendente.",
  NQ028: "Muitas tentativas de PIN. Tente de novo em alguns minutos.",
  NQ029: "O parceiro entra escaneando a quadra e pedindo para entrar no seu grupo.",
  NQ030: "Esta quadra usa o QR Code da placa.",
  NQ031: "Alguém já abriu a fila desta quadra. Peça o QR para quem está nela.",
  NQ033: "Só quem organiza a fila desta quadra faz isso.",
  NQ034: "A fila desta quadra não está aberta.",
};

/**
 * As CHECK constraints do banco, traduzidas.
 *
 * O PostgREST devolve `23514` com a mensagem crua do Postgres — em
 * inglês e citando o nome interno da constraint. Quem opera um parque
 * não tem o que fazer com isso. O formulário valida antes de enviar
 * (ver `lib/limits.ts`), e isto aqui é a rede: cobre o que escapar da
 * tela, de outra tela, ou de uma faixa que mudou no banco e não na
 * constante.
 */
const CHECK_MESSAGES: Array<[RegExp, string]> = [
  [/courts_slot_minutes_range/, "O slot de jogo precisa ficar entre 20 e 90 minutos."],
  [/courts_max_distance_meters_check/, "O raio de proximidade precisa ficar entre 10 e 20000 metros."],
  [/courts_call_window_range/, "A tolerância para o check-in precisa ficar entre 1 e 30 minutos."],
  [/courts_gps_tolerance_meters_check/, "A tolerância de GPS precisa ficar entre 0 e 2000 metros."],
  [/(courts|parks)_latitude_check/, "A latitude precisa ficar entre -90 e 90."],
  [/(courts|parks)_longitude_check/, "A longitude precisa ficar entre -180 e 180."],
  [/courts_name_length/, "O nome da quadra precisa ter de 2 a 120 caracteres."],
  [/(courts|parks)_address_length/, "O endereço precisa ter no máximo 200 caracteres."],
  [/courts_average_match_minutes_check/, "A duração média precisa ficar entre 1 e 240 minutos."],
];

export function rpcError(error: { code?: string; message?: string } | null): ApiError {
  const code = error?.code ?? "DATABASE_ERROR";

  if (code === "23514") {
    const raw = error?.message ?? "";
    const known = CHECK_MESSAGES.find(([pattern]) => pattern.test(raw));
    return new ApiError(
      code,
      known
        ? known[1]
        : "Algum valor do formulário está fora do que o banco aceita. Confira os números e tente de novo.",
    );
  }

  /*
   * PGRST202 é o PostgREST dizendo que não achou a função com aqueles
   * parâmetros. Na prática significa quase sempre a mesma coisa: o app
   * foi publicado com uma versão nova e o banco ficou na antiga.
   * Publicar na Vercel não roda SQL nenhum — e a mensagem crua do
   * PostgREST (em inglês, com a assinatura inteira) não diz isso a
   * ninguém.
   */
  if (code === "PGRST202") {
    return new ApiError(
      code,
      "O banco ainda está na versão anterior desta função. Cole o db/full_setup.sql "
      + "no SQL Editor do Supabase e tente de novo — publicar o app não mexe no banco.",
    );
  }

  // A mensagem do banco já vem em português e costuma ser mais específica.
  return new ApiError(code, error?.message || RPC_MESSAGES[code] || "Não foi possível concluir.");
}
