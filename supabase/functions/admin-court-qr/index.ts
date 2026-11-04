/**
 * GET /functions/v1/admin-court-qr?courtId=<uuid>   (admin)
 * GET /functions/v1/admin-court-qr                  — todas as quadras ativas
 *
 * Devolve o conteúdo assinado que deve ser impresso no QR Code de cada
 * quadra (US-02: "QR Codes são gerados no admin/backend e impressos
 * fisicamente nas quadras").
 *
 * Dois formatos por quadra:
 *   printUrl — App Link https, o que vai impresso. A câmera do Android
 *              abre o app da Play Store se instalado, senão o site.
 *   payload  — esquema neqst:, lido pelo scanner de dentro do app.
 *              Mantido para os códigos já impressos na Sprint 1.
 *
 * POST /functions/v1/admin-court-qr  { courtId, rotate: true }
 *   Incrementa qr_secret_version, invalidando os códigos antigos.
 */
import {
  ApiError,
  json,
  readJson,
  requireEnv,
  requireUuid,
  serve,
} from "../_shared/http.ts";
import { buildCourtQrPayload, buildCourtQrUrl } from "../_shared/qr.ts";
import { requireStaff, requireUser, serviceClient } from "../_shared/supabase.ts";

interface Court {
  id: string;
  slug: string;
  name: string;
  qr_secret_version: number;
}

/*
 * No wrapper `serve()`, como as outras onze.
 *
 * Esta era a única com `Deno.serve` cru: o preflight respeitava a
 * allow-list, mas `json()` e `errorResponse()` sem o `cors` caíam na
 * constante permissiva — `Access-Control-Allow-Origin: *`, sem
 * `Vary: Origin`, numa rota que devolve a assinatura HMAC de TODOS os
 * QR impressos. É exatamente o bug que centralizar o CORS no wrapper
 * existe para evitar (ver o comentário em _shared/http.ts).
 */
serve(async (req) => {
  const { user } = await requireUser(req);
  const role = await requireStaff(user.id);
  if (role !== "admin") {
    throw new ApiError("FORBIDDEN", "Ação restrita a administradores.", 403);
  }

  const secret = requireEnv("QR_SIGNING_SECRET");
  const admin = serviceClient();

  if (req.method === "POST") {
    const body = await readJson<{ courtId?: string; rotate?: boolean }>(req);
    const courtId = requireUuid(body.courtId, "courtId");

    const { data: current, error: readError } = await admin
      .from("courts")
      .select("id, slug, name, qr_secret_version")
      .eq("id", courtId)
      .maybeSingle<Court>();

    if (readError) throw new ApiError("DATABASE_ERROR", readError.message, 500);
    if (!current) throw new ApiError("COURT_NOT_FOUND", "Quadra não encontrada.", 404);

    const appBaseUrl = requireEnv("APP_BASE_URL");

    // A rotação incrementa no BANCO, não aqui.
    //
    // Era read-modify-write sem lock: dois POSTs ao mesmo tempo liam
    // v1 e gravavam v2, e o segundo admin achava que havia invalidado
    // o QR do primeiro sem ter invalidado. Operação irreversível
    // (invalida papel já impresso) precisa ser atômica.
    const { data: rotated, error: updateError } = await admin
      .rpc("rotate_court_qr_secret", { p_court_id: courtId })
      .returns<number>();

    if (updateError) throw new ApiError("DATABASE_ERROR", updateError.message, 500);

    const nextVersion = rotated as unknown as number;

    return json({
      courtId: current.id,
      name: current.name,
      version: nextVersion,
      printUrl: await buildCourtQrUrl(current.id, nextVersion, secret, appBaseUrl),
      payload: await buildCourtQrPayload(current.id, nextVersion, secret),
      warning: "Os QR Codes impressos da versão anterior deixaram de funcionar.",
    });
  }

  if (req.method !== "GET") {
    throw new ApiError("METHOD_NOT_ALLOWED", "Use GET ou POST nesta rota.", 405);
  }

  const asked = new URL(req.url).searchParams.get("courtId");

  let query = admin.from("courts").select("id, slug, name, qr_secret_version").order("name");
  if (asked) query = query.eq("id", requireUuid(asked, "courtId"));
  else query = query.eq("is_active", true);

  const { data, error } = await query.returns<Court[]>();
  if (error) throw new ApiError("DATABASE_ERROR", error.message, 500);

  const appBaseUrl = requireEnv("APP_BASE_URL");

  const courts = await Promise.all(
    (data ?? []).map(async (court) => ({
      courtId: court.id,
      slug: court.slug,
      name: court.name,
      version: court.qr_secret_version,
      printUrl: await buildCourtQrUrl(court.id, court.qr_secret_version, secret, appBaseUrl),
      payload: await buildCourtQrPayload(court.id, court.qr_secret_version, secret),
    })),
  );

  return json({ courts });
});
