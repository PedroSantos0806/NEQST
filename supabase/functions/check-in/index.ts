/**
 * POST /functions/v1/check-in   (Sprint 3)
 *
 * O "Check-in para jogar" do protótipo: o jogador chamado escaneia o QR
 * ou encosta no totem NFC da quadra, e a partida começa. Num parque
 * público não existe operador — quem libera o placar é quem vai jogar.
 *
 * Body: { scanToken: string, side?: "auto" | "open" }
 *   "auto" (padrão) inicia a partida com o time na vez.
 *   "open" ocupa o lado livre de uma partida em andamento
 *          ("Adversário livre" na tela).
 *
 * 200: o placar da partida (match_state)
 */
import { ApiError, json, postgrestError, readJson, requireMethod, serve } from "../_shared/http.ts";
import { requireUser } from "../_shared/supabase.ts";

interface CheckInRequest {
  scanToken?: string;
  side?: "auto" | "open";
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

  const side = body.side ?? "auto";
  if (side !== "auto" && side !== "open") {
    throw new ApiError("INVALID_SIDE", "side deve ser 'auto' ou 'open'.", 400);
  }

  const rpc = side === "open" ? "join_open_side" : "check_in_and_start";
  const { data, error } = await client.rpc(rpc, { p_scan_token: body.scanToken });

  if (error) postgrestError(error);

  return json(data, 201);
});
