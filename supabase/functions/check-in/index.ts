/**
 * POST /functions/v1/check-in   (Sprint 3, revisto na Sprint 4)
 *
 * O "Check-in para jogar": quem é do grupo chamado escaneia o QR ou
 * encosta no totem NFC da quadra. Um check-in basta para o turno
 * começar; quem é do grupo e chega depois escaneia também, e fica
 * registrado que está em quadra.
 *
 * Body: { scanToken: string }
 * 201:  o turno (match_state)
 */
import { ApiError, json, postgrestError, readJson, requireMethod, serve } from "../_shared/http.ts";
import { requireUser } from "../_shared/supabase.ts";

interface CheckInRequest {
  scanToken?: string;
}

serve(async (req) => {
  requireMethod(req, "POST");

  const { client } = await requireUser(req);
  const body = await readJson<CheckInRequest>(req);

  if (!body.scanToken) {
    throw new ApiError(
      "SCAN_TOKEN_REQUIRED",
      "Escaneie o QR Code da quadra para confirmar que você chegou.",
      400,
    );
  }

  const { data, error } = await client.rpc("check_in_and_start", {
    p_scan_token: body.scanToken,
  });

  if (error) postgrestError(error);

  return json(data, 201);
});
