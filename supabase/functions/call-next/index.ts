/**
 * POST /functions/v1/call-next   (operação da quadra — staff/admin)
 *
 * Body: { courtId: string }                  -> encerra a partida atual e inicia a próxima
 *       { action: "start"|"finish", entryId } -> controle manual
 */
import {
  ApiError,
  json,
  postgrestError,
  readJson,
  requireMethod,
  requireUuid,
  serve,
} from "../_shared/http.ts";
import { requireStaff, requireUser } from "../_shared/supabase.ts";

interface CallNextRequest {
  courtId?: string;
  entryId?: string;
  action?: "next" | "start" | "finish";
}

serve(async (req) => {
  requireMethod(req, "POST");

  const { user, client } = await requireUser(req);
  await requireStaff(user.id);

  const body = await readJson<CallNextRequest>(req);
  const action = body.action ?? "next";

  // Validado contra a lista fechada ANTES de qualquer coisa.
  //
  // Era `action === "start" ? "start_match" : "finish_match"`: qualquer
  // valor fora de next/start — incluindo um erro de digitação, como
  // "finis" ou "Start" — caía no default e ENCERRAVA o turno em
  // andamento, tirando gente da quadra. Default destrutivo em valor que
  // vem do cliente.
  if (action !== "next" && action !== "start" && action !== "finish") {
    throw new ApiError(
      "INVALID_ACTION",
      'action deve ser "next", "start" ou "finish".',
      400,
    );
  }

  if (action === "next") {
    const { data, error } = await client.rpc("call_next", {
      p_court_id: requireUuid(body.courtId, "courtId"),
    });
    if (error) postgrestError(error);
    return json(data);
  }

  const entryId = requireUuid(body.entryId, "entryId");
  const rpc = action === "start" ? "start_match" : "finish_match";
  const { data, error } = await client.rpc(rpc, { p_entry_id: entryId });
  if (error) postgrestError(error);

  return json(data);
});
