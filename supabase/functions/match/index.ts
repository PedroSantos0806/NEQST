/**
 * Turno de um grupo na quadra (Sprint 3, revisto na Sprint 4).
 *
 * POST /functions/v1/match
 *   { matchId: string }
 *
 * O grupo devolve a quadra antes do fim do turno. Não há vencedor nem
 * "quem ganha fica": o grupo sai e o próximo da fila é chamado. Se
 * ninguém encerrar, o turno acaba sozinho no fim do slot.
 *
 * GET /functions/v1/match?matchId=<uuid>
 *   O turno (para o app conferir depois de reconectar).
 */
import { ApiError, json, postgrestError, readJson, requireUuid, serve } from "../_shared/http.ts";
import { anonClient, requireUser } from "../_shared/supabase.ts";

interface FinishRequest {
  matchId?: string;
}

serve(async (req) => {
  const url = new URL(req.url);

  if (req.method === "GET") {
    const matchId = requireUuid(url.searchParams.get("matchId"), "matchId");

    // Leitura pública do placar: a chave anônima basta, e o
    // service_role aqui só aumentaria o estrago de um bug futuro nesta
    // rota — ela ignora RLS por definição.
    const { data, error } = await anonClient().rpc("match_state", { p_match_id: matchId });
    if (error) postgrestError(error);

    return json(data);
  }

  if (req.method !== "POST") {
    throw new ApiError("METHOD_NOT_ALLOWED", "Use GET ou POST nesta rota.", 405);
  }

  const { client } = await requireUser(req);
  const body = await readJson<FinishRequest>(req);

  const { data, error } = await client.rpc("finish_my_turn", {
    p_match_id: requireUuid(body.matchId, "matchId"),
  });

  if (error) postgrestError(error);

  return json(data);
});
