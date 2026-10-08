/**
 * POST /functions/v1/scan-court   (US-02)
 *
 * Valida o QR Code escaneado + a localização do jogador e devolve um
 * scan token de uso único (TTL 30s) que habilita `join-queue`.
 *
 * Body:  { payload, latitude, longitude, accuracy?, method?, purpose? }
 *   method  "qr" (padrão) | "nfc" — o totem NFC grava a mesma URL
 *           assinada do QR, então a validação é idêntica.
 *   purpose "join" (padrão) | "start" — só informativo: o token serve
 *           para os dois, e quem decide é a RPC chamada depois
 *           (join_queue ou check_in_and_start).
 *
 * 200:   { scanToken, expiresAt, distanceMeters, court }
 * 403:   TOO_FAR_FROM_COURT — "Você está longe demais desta quadra"
 */
import { ApiError, json, readJson, requireEnv, requireMethod, serve } from "../_shared/http.ts";
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

type ScanMethod = "qr" | "nfc";
type ScanPurpose = "join" | "start";

interface ScanRequest {
  payload?: string;
  latitude?: number;
  longitude?: number;
  accuracy?: number | null;
  method?: ScanMethod;
  purpose?: ScanPurpose;
}

serve(async (req) => {
  requireMethod(req, "POST");

  const { user } = await requireUser(req);
  const body = await readJson<ScanRequest>(req);

  if (!body.payload || typeof body.payload !== "string") {
    throw new ApiError("INVALID_QR", "Conteúdo do QR Code ausente.", 400);
  }

  // O totem NFC grava a mesma URL assinada do QR: só muda o caminho
  // por onde o payload chegou.
  const method: ScanMethod = body.method ?? "qr";
  if (method !== "qr" && method !== "nfc") {
    throw new ApiError("INVALID_METHOD", "method deve ser 'qr' ou 'nfc'.", 400);
  }

  const purpose: ScanPurpose = body.purpose ?? "join";
  if (purpose !== "join" && purpose !== "start") {
    throw new ApiError("INVALID_PURPOSE", "purpose deve ser 'join' ou 'start'.", 400);
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
        " max_distance_meters, gps_tolerance_meters, slot_minutes, qr_secret_version," +
        " court_number, surface, has_qr_code, has_nfc_tag, park_id",
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

  if (method === "nfc" && !court.has_nfc_tag) {
    throw new ApiError("METHOD_UNAVAILABLE", "Esta quadra não tem totem NFC. Use o QR Code.", 409);
  }
  if (method === "qr" && !court.has_qr_code) {
    throw new ApiError("METHOD_UNAVAILABLE", "Esta quadra não tem QR Code. Use o totem NFC.", 409);
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
    method,
    expires_at: expiry.toISOString(),
  });

  if (insertError) throw new ApiError("DATABASE_ERROR", insertError.message, 500);

  return json({
    scanToken: token,
    expiresAt: expiry.toISOString(),
    ttlSeconds: SCAN_TOKEN_TTL_SECONDS,
    distanceMeters: Math.round(distanceMeters),
    method,
    purpose,
    court: {
      id: court.id,
      parkId: court.park_id,
      number: court.court_number,
      // O app mostra "Quadra 01", derivado do número dentro do parque.
      name: `Quadra ${String(court.court_number).padStart(2, "0")}`,
      slug: court.slug,
      surface: court.surface,
      status: court.status,
      slotMinutes: court.slot_minutes,
      checkinMethods: [
        ...(court.has_qr_code ? ["qr"] : []),
        ...(court.has_nfc_tag ? ["nfc"] : []),
      ],
    },
  });
});
