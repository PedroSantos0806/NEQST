/**
 * POST /functions/v1/scan-court   (US-02)
 *
 * Valida o QR Code escaneado + a localização do jogador e devolve um
 * scan token de uso único (TTL 30s) que habilita `join-queue`.
 *
 * Body:  { payload?, courtId?, latitude, longitude, accuracy?, method?, purpose? }
 *   method  "qr" (padrão) | "nfc" | "gps"
 *           qr   o QR da placa, ou o QR na tela de alguém da fila
 *                (Sprint 5) — o formato do payload diz qual é
 *           nfc  o totem grava a mesma URL assinada do QR
 *           gps  sem payload, com courtId: só a localização. Só nas
 *                quadras em modo anfitrião, para abrir a fila e para o
 *                botão "Entrando na quadra". O banco não aceita esse
 *                token para entrar na fila de ninguém.
 *   purpose "join" (padrão) | "start" | "open" — só informativo: quem
 *           decide é a RPC chamada depois (join_queue,
 *           check_in_and_start ou open_host_queue).
 *
 * 200:   { scanToken, expiresAt, distanceMeters, court }
 * 403:   TOO_FAR_FROM_COURT — "Você está longe demais desta quadra"
 * 409:   HOST_QUEUE_CLOSED  — o convite é de uma fila que já fechou
 * 410:   HOST_INVITE_EXPIRED — o convite passou dos 10 minutos
 */
import { ApiError, json, readJson, requireEnv, requireMethod, serve } from "../_shared/http.ts";
import { allowedRadiusMeters, assertCoordinates, haversineMeters } from "../_shared/geo.ts";
import { InvalidQrError, parseHostInvitePayload, verifyCourtQrPayload } from "../_shared/qr.ts";
import {
  expiresAt,
  generateScanToken,
  hashScanToken,
  SCAN_TOKEN_TTL_SECONDS,
} from "../_shared/tokens.ts";
import { requireUser, serviceClient } from "../_shared/supabase.ts";
import type { CourtRow } from "../_shared/types.ts";

type ScanMethod = "qr" | "nfc" | "gps";
type ScanPurpose = "join" | "start" | "open";

const COURT_COLUMNS =
  "id, slug, name, address, photo_url, status, is_active, latitude, longitude," +
  " max_distance_meters, gps_tolerance_meters, enforce_proximity," +
  " slot_minutes, qr_secret_version, queue_mode," +
  " court_number, surface, has_qr_code, has_nfc_tag, park_id";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface HostInviteRow {
  id: string;
  court_id: string;
  expires_at: string;
  host_sessions: { closed_at: string | null } | null;
}

interface ScanRequest {
  payload?: string;
  courtId?: string;
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

  // O totem NFC grava a mesma URL assinada do QR: só muda o caminho
  // por onde o payload chegou.
  const method: ScanMethod = body.method ?? "qr";
  if (method !== "qr" && method !== "nfc" && method !== "gps") {
    throw new ApiError("INVALID_METHOD", "method deve ser 'qr', 'nfc' ou 'gps'.", 400);
  }

  if (method !== "gps" && (!body.payload || typeof body.payload !== "string")) {
    throw new ApiError("INVALID_QR", "Conteúdo do QR Code ausente.", 400);
  }
  if (method === "gps" && (typeof body.courtId !== "string" || !UUID_RE.test(body.courtId))) {
    throw new ApiError("INVALID_COURT", "Informe a quadra para confirmar a localização.", 400);
  }

  const purpose: ScanPurpose = body.purpose ?? "join";
  if (purpose !== "join" && purpose !== "start" && purpose !== "open") {
    throw new ApiError("INVALID_PURPOSE", "purpose deve ser 'join', 'start' ou 'open'.", 400);
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

  const admin = serviceClient();

  // 1. De onde veio a quadra: o convite na tela de alguém, só o GPS,
  //    ou o QR assinado da placa.
  let inviteCode: string | null = null;
  if (method !== "gps") {
    try {
      inviteCode = parseHostInvitePayload(body.payload!);
    } catch (error) {
      if (error instanceof InvalidQrError) {
        throw new ApiError("INVALID_QR", "Este QR Code não é válido.", 400);
      }
      throw error;
    }
  }

  let courtId: string;
  let qrVersion: number | null = null;
  let invite: HostInviteRow | null = null;

  if (method === "gps") {
    courtId = body.courtId!;
  } else if (inviteCode) {
    const { data, error } = await admin
      .from("host_invites")
      .select("id, court_id, expires_at, host_sessions(closed_at)")
      .eq("code_hash", await hashScanToken(inviteCode))
      .maybeSingle<HostInviteRow>();

    if (error) throw new ApiError("DATABASE_ERROR", error.message, 500);
    if (!data) throw new ApiError("INVALID_QR", "Este QR Code não é válido.", 400);

    // 10 min dão tempo de baixar o app e criar a conta. A presença é
    // conferida agora, pelo GPS, e não quando o código foi gerado.
    if (new Date(data.expires_at).getTime() <= Date.now()) {
      throw new ApiError(
        "HOST_INVITE_EXPIRED",
        "Este QR venceu. Peça para alguém da fila mostrar o QR de novo.",
        410,
      );
    }
    if (data.host_sessions?.closed_at) {
      throw new ApiError(
        "HOST_QUEUE_CLOSED",
        "A fila deste QR já foi encerrada. Abra a quadra no app para ver como está agora.",
        409,
      );
    }

    invite = data;
    courtId = data.court_id;
  } else {
    let qr;
    try {
      qr = await verifyCourtQrPayload(body.payload!, requireEnv("QR_SIGNING_SECRET"));
    } catch (error) {
      if (error instanceof InvalidQrError) {
        throw new ApiError("INVALID_QR", "Este QR Code não é válido.", 400);
      }
      throw error;
    }
    courtId = qr.courtId;
    qrVersion = qr.version;
  }

  // 2. Quadra existe, está ativa e o QR não foi revogado
  const { data: court, error: courtError } = await admin
    .from("courts")
    .select(COURT_COLUMNS)
    .eq("id", courtId)
    .maybeSingle<CourtRow>();

  if (courtError) throw new ApiError("DATABASE_ERROR", courtError.message, 500);
  if (!court) throw new ApiError("COURT_NOT_FOUND", "Quadra não encontrada.", 404);

  if (qrVersion !== null && qrVersion !== court.qr_secret_version) {
    throw new ApiError(
      "QR_REVOKED",
      "Este QR Code foi substituído. Procure o código atual afixado na quadra.",
      409,
    );
  }

  if (!court.is_active || court.status === "unavailable") {
    throw new ApiError("COURT_UNAVAILABLE", "Esta quadra está indisponível no momento.", 409);
  }

  if (method === "gps" || invite) {
    // O piloto sem nada na placa: o banco garante que a distância está
    // ligada em toda quadra nesse modo.
    if (court.queue_mode !== "host") {
      throw new ApiError(
        invite ? "HOST_QUEUE_CLOSED" : "METHOD_UNAVAILABLE",
        "Esta quadra usa o QR Code da placa. Escaneie o código afixado nela.",
        409,
      );
    }
  } else if (method === "nfc" && !court.has_nfc_tag) {
    throw new ApiError("METHOD_UNAVAILABLE", "Esta quadra não tem totem NFC. Use o QR Code.", 409);
  } else if (method === "qr" && !court.has_qr_code) {
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

  // `enforce_proximity = false` é uma escolha do admin, quadra a quadra,
  // para que o time de testes não precise estar na quadra. A distância
  // continua medida e registrada — só não barra.
  if (court.enforce_proximity !== false && distanceMeters > allowed) {
    // O print do QR mandado para quem está longe: conta no painel.
    if (invite) {
      await admin.from("pilot_events").insert({
        court_id: court.id,
        invite_id: invite.id,
        user_id: user.id,
        event: "invite_too_far",
        distance_meters: distanceMeters,
      });
    }
    throw new ApiError(
      "TOO_FAR_FROM_COURT",
      `Você está a ${Math.round(distanceMeters)} m da ${court.name}, e o limite é ` +
        `${Math.round(allowed)} m. Chegue até a quadra e ` +
        `${method === "gps" ? "tente de novo" : "escaneie de novo"}.`,
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
    method: invite ? "host_invite" : method,
    invite_id: invite?.id ?? null,
    expires_at: expiry.toISOString(),
  });

  if (insertError) throw new ApiError("DATABASE_ERROR", insertError.message, 500);

  if (invite) {
    await admin.from("pilot_events").insert({
      court_id: court.id,
      invite_id: invite.id,
      user_id: user.id,
      event: "invite_scanned",
      distance_meters: distanceMeters,
    });
  }

  return json({
    scanToken: token,
    expiresAt: expiry.toISOString(),
    ttlSeconds: SCAN_TOKEN_TTL_SECONDS,
    distanceMeters: Math.round(distanceMeters),
    method: invite ? "host_invite" : method,
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
      queueMode: court.queue_mode,
      checkinMethods: court.queue_mode === "host" ? ["gps"] : [
        ...(court.has_qr_code ? ["qr"] : []),
        ...(court.has_nfc_tag ? ["nfc"] : []),
      ],
    },
  });
});
