/**
 * POST /functions/v1/call-next   (operação da quadra — staff/admin)
 *
 * Body: { courtId: string }                  -> encerra a partida atual e inicia a próxima
 *       { action: "start"|"finish", entryId } -> controle manual
 */
import { ApiError, json, postgrestError, readJson, requireMethod, serve } from "../_shared/http.ts";
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

  if (action === "next") {
    if (!body.courtId) throw new ApiError("COURT_REQUIRED", "Informe courtId.", 400);
    const { data, error } = await client.rpc("call_next", { p_court_id: body.courtId });
    if (error) postgrestError(error);
    return json(data);
  }

  if (!body.entryId) throw new ApiError("ENTRY_ID_REQUIRED", "Informe entryId.", 400);

  const rpc = action === "start" ? "start_match" : "finish_match";
  const { data, error } = await client.rpc(rpc, { p_entry_id: body.entryId });
  if (error) postgrestError(error);

  return json(data);
});
