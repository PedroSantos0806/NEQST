/**
 * GET /functions/v1/admin-court-qr?courtId=<uuid>   (admin)
 * GET /functions/v1/admin-court-qr                  — todas as quadras ativas
 *
 * Devolve o conteúdo assinado que deve ser impresso no QR Code de cada
 * quadra (US-02: "QR Codes são gerados no admin/backend e impressos
 * fisicamente nas quadras").
 *
 * POST /functions/v1/admin-court-qr  { courtId, rotate: true }
 *   Incrementa qr_secret_version, invalidando os códigos antigos.
 */
import {
  ApiError,
  errorResponse,
  handlePreflight,
  json,
  readJson,
  requireEnv,
} from "../_shared/http.ts";
import { buildCourtQrPayload } from "../_shared/qr.ts";
import { requireStaff, requireUser, serviceClient } from "../_shared/supabase.ts";

interface Court {
  id: string;
  slug: string;
  name: string;
  qr_secret_version: number;
}

Deno.serve(async (req) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  try {
    const { user } = await requireUser(req);
    const role = await requireStaff(user.id);
    if (role !== "admin") {
      throw new ApiError("FORBIDDEN", "Ação restrita a administradores.", 403);
    }

    const secret = requireEnv("QR_SIGNING_SECRET");
    const admin = serviceClient();

    if (req.method === "POST") {
      const body = await readJson<{ courtId?: string; rotate?: boolean }>(req);
      if (!body.courtId) throw new ApiError("COURT_REQUIRED", "Informe courtId.", 400);

      const { data: current, error: readError } = await admin
        .from("courts")
        .select("id, slug, name, qr_secret_version")
        .eq("id", body.courtId)
        .maybeSingle<Court>();

      if (readError) throw new ApiError("DATABASE_ERROR", readError.message, 500);
      if (!current) throw new ApiError("COURT_NOT_FOUND", "Quadra não encontrada.", 404);

      const nextVersion = current.qr_secret_version + 1;

      const { error: updateError } = await admin
        .from("courts")
        .update({ qr_secret_version: nextVersion, qr_rotated_at: new Date().toISOString() })
        .eq("id", current.id);

      if (updateError) throw new ApiError("DATABASE_ERROR", updateError.message, 500);

      return json({
        courtId: current.id,
        name: current.name,
        version: nextVersion,
        payload: await buildCourtQrPayload(current.id, nextVersion, secret),
        warning: "Os QR Codes impressos da versão anterior deixaram de funcionar.",
      });
    }

    if (req.method !== "GET") {
      throw new ApiError("METHOD_NOT_ALLOWED", "Use GET ou POST nesta rota.", 405);
    }

    const courtId = new URL(req.url).searchParams.get("courtId");

    let query = admin.from("courts").select("id, slug, name, qr_secret_version").order("name");
    if (courtId) query = query.eq("id", courtId);
    else query = query.eq("is_active", true);

    const { data, error } = await query.returns<Court[]>();
    if (error) throw new ApiError("DATABASE_ERROR", error.message, 500);

    const courts = await Promise.all(
      (data ?? []).map(async (court) => ({
        courtId: court.id,
        slug: court.slug,
        name: court.name,
        version: court.qr_secret_version,
        payload: await buildCourtQrPayload(court.id, court.qr_secret_version, secret),
      })),
    );

    return json({ courts });
  } catch (error) {
    return errorResponse(error);
  }
});
