/**
 * POST /functions/v1/join-queue   (US-03)
 *
 * Body: { scanToken: string, mode?: "single" | "double", partner?: string }
 * 200:  estado do time (posição, times na frente, tempo estimado)
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

interface JoinRequest {
  scanToken?: string;
  mode?: "single" | "double";
  partner?: string | null;
}

Deno.serve(async (req) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  try {
    requireMethod(req, "POST");

    const { client } = await requireUser(req);
    const body = await readJson<JoinRequest>(req);
    const mode = body.mode ?? "single";

    if (!body.scanToken) {
      throw new ApiError(
        "SCAN_TOKEN_REQUIRED",
        "Escaneie o QR Code da quadra antes de entrar na fila.",
        400,
      );
    }
    if (mode !== "single" && mode !== "double") {
      throw new ApiError("INVALID_MODE", "Modalidade deve ser 'single' ou 'double'.", 400);
    }
    if (mode === "double" && !body.partner?.trim()) {
      throw new ApiError("PARTNER_REQUIRED", "Informe o @username ou e-mail do parceiro.", 400);
    }

    const { data, error } = await client.rpc("join_queue", {
      p_scan_token: body.scanToken,
      p_mode: mode,
      p_partner: body.partner ?? null,
    });

    if (error) postgrestError(error);

    return json(data, 201);
  } catch (error) {
    return errorResponse(error);
  }
});
