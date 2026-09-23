/**
 * POST /functions/v1/scan-court   (US-02)
 *
 * Valida o QR Code escaneado + a localização do jogador e devolve um
 * scan token de uso único (TTL 30s) que habilita `join-queue`.
 *
 * Body:  { payload: string, latitude: number, longitude: number, accuracy?: number }
 * 200:   { scanToken, expiresAt, distanceMeters, court }
 * 403:   TOO_FAR_FROM_COURT — "Você está longe demais desta quadra"
 */
import {
  ApiError,
  errorResponse,
  handlePreflight,
  json,
  readJson,
  requireEnv,
  requireMethod,
} from "../_shared/http.ts";
import { allowedRadiusMeters, assertCoordinates, haversineMeters } from "../_shared/geo.ts";
import { InvalidQrError, verifyCourtQrPayload } from "../_shared/qr.ts";
import {
  expiresAt,
  generateScanToken,
  hashScanToken,
  SCAN_TOKEN_TTL_SECONDS,
} from "../_shared/tokens.ts";
import { requireUser, serviceClient } from "../_shared/supabase.ts";
import type { CourtRow } from "../_shared/types.ts";

interface ScanRequest {
  payload?: string;
  latitude?: number;
  longitude?: number;
  accuracy?: number | null;
}

Deno.serve(async (req) => {
  const preflight = handlePreflight(req);
  if (preflight) return preflight;

  try {
    requireMethod(req, "POST");

    const { user } = await requireUser(req);
    const body = await readJson<ScanRequest>(req);

    if (!body.payload || typeof body.payload !== "string") {
      throw new ApiError("INVALID_QR", "Conteúdo do QR Code ausente.", 400);
    }

    let position;
    try {
      position = assertCoordinates(body);
    } catch {
      throw new ApiError(
        "LOCATION_REQUIRED",
        "Precisamos da sua localização para confirmar que você está na quadra.",
        400,
      );
    }

    // 1. Assinatura do QR Code
    let qr;
    try {
      qr = await verifyCourtQrPayload(body.payload, requireEnv("QR_SIGNING_SECRET"));
    } catch (error) {
      if (error instanceof InvalidQrError) {
        throw new ApiError("INVALID_QR", "Este QR Code não é válido.", 400);
      }
      throw error;
    }

    const admin = serviceClient();

    // 2. Quadra existe, está ativa e o QR não foi revogado
    const { data: court, error: courtError } = await admin
      .from("courts")
      .select(
        "id, slug, name, address, photo_url, status, is_active, latitude, longitude," +
          " max_distance_meters, gps_tolerance_meters, average_match_minutes, qr_secret_version",
      )
      .eq("id", qr.courtId)
      .maybeSingle<CourtRow>();

    if (courtError) throw new ApiError("DATABASE_ERROR", courtError.message, 500);
    if (!court) throw new ApiError("COURT_NOT_FOUND", "Quadra não encontrada.", 404);

    if (qr.version !== court.qr_secret_version) {
      throw new ApiError(
        "QR_REVOKED",
        "Este QR Code foi substituído. Procure o código atual afixado na quadra.",
        409,
      );
    }

    if (!court.is_active || court.status === "unavailable") {
      throw new ApiError("COURT_UNAVAILABLE", "Esta quadra está indisponível no momento.", 409);
    }

    // 3. Proximidade (Haversine)
    const distanceMeters = haversineMeters(position, {
      latitude: court.latitude,
      longitude: court.longitude,
    });

    const allowed = allowedRadiusMeters(
      court.max_distance_meters,
      court.gps_tolerance_meters,
      body.accuracy,
    );

    if (distanceMeters > allowed) {
      throw new ApiError(
        "TOO_FAR_FROM_COURT",
        "Você está longe demais desta quadra",
        403,
        {
          distanceMeters: Math.round(distanceMeters),
          allowedRadiusMeters: Math.round(allowed),
          courtName: court.name,
        },
      );
    }

    // 4. Emite o scan token de uso único
    const token = generateScanToken();
    const expiry = expiresAt(SCAN_TOKEN_TTL_SECONDS);

    const { error: insertError } = await admin.from("scan_tokens").insert({
      token_hash: await hashScanToken(token),
      user_id: user.id,
      court_id: court.id,
      latitude: position.latitude,
      longitude: position.longitude,
      accuracy_meters: body.accuracy ?? null,
      distance_meters: distanceMeters,
      expires_at: expiry.toISOString(),
    });

    if (insertError) throw new ApiError("DATABASE_ERROR", insertError.message, 500);

    return json({
      scanToken: token,
      expiresAt: expiry.toISOString(),
      ttlSeconds: SCAN_TOKEN_TTL_SECONDS,
      distanceMeters: Math.round(distanceMeters),
      court: {
        id: court.id,
        slug: court.slug,
        name: court.name,
        address: court.address,
        status: court.status,
        photoUrl: court.photo_url,
        averageMatchMinutes: court.average_match_minutes,
      },
    });
  } catch (error) {
    return errorResponse(error);
  }
});
