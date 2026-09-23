/**
 * POST /functions/v1/leave-queue   (US-03)
 * Body: { entryId: string, reason?: string }
 */
import {
  ApiError,
  errorResponse,
  handlePreflight,
  json,
  postgrestError,
  readJson,
  requireMethod,
} from "../_shared/http.ts";
import { requireUser } from "../_shared/supabase.ts";

interface LeaveRequest {
  entryId?: string;
  reason?: string | null;
}

Deno.serve(async (req) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  try {
    requireMethod(req, "POST");

    const { client } = await requireUser(req);
    const body = await readJson<LeaveRequest>(req);

    if (!body.entryId) {
      throw new ApiError("ENTRY_ID_REQUIRED", "Informe o time que deve sair da fila.", 400);
    }

    const { data, error } = await client.rpc("leave_queue", {
      p_entry_id: body.entryId,
      p_reason: body.reason ?? null,
    });

    if (error) postgrestError(error);

    return json(data);
  } catch (error) {
    return errorResponse(error);
  }
});
