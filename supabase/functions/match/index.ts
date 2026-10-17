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
import { ApiError, json, postgrestError, readJson, serve } from "../_shared/http.ts";
import { requireUser, serviceClient } from "../_shared/supabase.ts";

interface FinishRequest {
  matchId?: string;
}

serve(async (req) => {
  const url = new URL(req.url);

  if (req.method === "GET") {
    const matchId = url.searchParams.get("matchId");
    if (!matchId) throw new ApiError("MATCH_ID_REQUIRED", "Informe matchId.", 400);

    const { data, error } = await serviceClient().rpc("match_state", { p_match_id: matchId });
    if (error) postgrestError(error);

    return json(data);
  }

  if (req.method !== "POST") {
    throw new ApiError("METHOD_NOT_ALLOWED", "Use GET ou POST nesta rota.", 405);
  }

  const { client } = await requireUser(req);
  const body = await readJson<FinishRequest>(req);

  if (!body.matchId) throw new ApiError("MATCH_ID_REQUIRED", "Informe matchId.", 400);

  const { data, error } = await client.rpc("finish_my_turn", { p_match_id: body.matchId });

  if (error) postgrestError(error);

  return json(data);
});
