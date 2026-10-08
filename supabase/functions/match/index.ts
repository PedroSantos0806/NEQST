/**
 * Resultado da partida (Sprint 3).
 *
 * POST /functions/v1/match?action=result
 *   { matchId: string, winner: "a" | "b" }
 *
 * Quem ganha fica: o lado vencedor segue em quadra como mandante e o
 * próximo time da fila entra como desafiante. Qualquer jogador dos dois
 * lados pode reportar — num parque público não há árbitro.
 *
 * Se ninguém reportar até o slot acabar, a rotina de manutenção encerra
 * a partida sem vencedor e a quadra fica sem mandante.
 *
 * GET /functions/v1/match?matchId=<uuid>
 *   Placar de uma partida (para o app conferir depois de reconectar).
 */
import { ApiError, json, postgrestError, readJson, serve } from "../_shared/http.ts";
import { requireUser, serviceClient } from "../_shared/supabase.ts";
import type { MatchSide } from "../_shared/types.ts";

interface ResultRequest {
  matchId?: string;
  winner?: MatchSide;
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
  const body = await readJson<ResultRequest>(req);

  if (!body.matchId) throw new ApiError("MATCH_ID_REQUIRED", "Informe matchId.", 400);
  if (body.winner !== "a" && body.winner !== "b") {
    throw new ApiError("INVALID_WINNER", "winner deve ser 'a' ou 'b'.", 400);
  }

  const { data, error } = await client.rpc("report_match_result", {
    p_match_id: body.matchId,
    p_winner: body.winner,
  });

  if (error) postgrestError(error);

  return json(data);
});
