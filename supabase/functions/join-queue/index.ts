/**
 * POST /functions/v1/join-queue   (US-03)
 *
 * Abre uma vaga na fila. Quem abre pode estar sozinho: os amigos entram
 * na mesma vaga depois, escaneando a quadra (RPC request_join ou
 * join_with_pin — ver docs/api.md).
 *
 * Body:  { scanToken: string }
 *   `mode` ainda é aceito e ignorado (app anterior à Sprint 4).
 *   `partner` é recusado: o parceiro pelo @ não provava presença.
 * 200:   estado da vaga (posição, grupos na frente, tempo estimado)
 */
import { ApiError, json, postgrestError, readJson, requireMethod, serve } from "../_shared/http.ts";
import { requireUser } from "../_shared/supabase.ts";

interface JoinRequest {
  scanToken?: string;
  partner?: string | null;
}

serve(async (req) => {
  requireMethod(req, "POST");

  const { client } = await requireUser(req);
  const body = await readJson<JoinRequest>(req);

  if (!body.scanToken) {
    throw new ApiError(
      "SCAN_TOKEN_REQUIRED",
      "Escaneie o QR Code da quadra antes de entrar na fila.",
      400,
    );
  }

  const { data, error } = await client.rpc("join_queue", {
    p_scan_token: body.scanToken,
    p_partner: body.partner ?? null,
  });

  if (error) postgrestError(error);

  return json(data, 201);
});
