/**
 * POST /functions/v1/leave-queue   (US-03, revisto na Sprint 4)
 *
 * Sai do grupo quem chamou — não o grupo inteiro. A vaga continua com
 * quem ficou (saindo o dono, o membro mais antigo herda) e só some
 * quando sai o último; aí a vez passa para o próximo da fila.
 *
 * Body: { entryId: string, reason?: string }
 */
import { ApiError, json, postgrestError, readJson, requireMethod, serve } from "../_shared/http.ts";
import { requireUser } from "../_shared/supabase.ts";

interface LeaveRequest {
  entryId?: string;
  reason?: string | null;
}

serve(async (req) => {
  requireMethod(req, "POST");

  const { client } = await requireUser(req);
  const body = await readJson<LeaveRequest>(req);

  if (!body.entryId) {
    throw new ApiError("ENTRY_ID_REQUIRED", "Informe o grupo de que você quer sair.", 400);
  }

  const { data, error } = await client.rpc("leave_queue", {
    p_entry_id: body.entryId,
    p_reason: body.reason ?? null,
  });

  if (error) postgrestError(error);

  return json(data);
});
