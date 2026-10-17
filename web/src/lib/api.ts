/**
 * Camada de API: uma função por chamada do backend.
 *
 * Leituras vão direto por RPC (menos round-trips, que é o que importa no
 * 3G). O que precisa de segredo — validar o QR e a proximidade — passa
 * pelas Edge Functions.
 */
import { ApiError, callFunction, rpcError, supabase } from "./supabase";
import type {
  AdminOverview,
  AdminUser,
  AppRole,
  CourtQr,
  CourtScreen,
  MatchState,
  MyQueueState,
  PaletteColor,
  ParkCard,
  ParkScreen,
  PinResult,
  ProfileSummary,
  ScanResult,
} from "./types";

async function rpc<T>(name: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw rpcError(error);
  return data as T;
}

// ---------------------------------------------------------------------
// Telas
// ---------------------------------------------------------------------

export function parksOverview(coords?: { latitude: number; longitude: number } | null) {
  return rpc<ParkCard[]>("parks_overview", {
    p_latitude: coords?.latitude ?? null,
    p_longitude: coords?.longitude ?? null,
    p_radius_meters: coords ? 20000 : null,
  });
}

export const parkScreen = (parkId: string) => rpc<ParkScreen>("park_screen", { p_park_id: parkId });

export const courtScreen = (courtId: string) =>
  rpc<CourtScreen>("court_screen", { p_court_id: courtId });

export const myQueueState = () => rpc<MyQueueState>("my_queue_state");

export const matchState = (matchId: string) => rpc<MatchState>("match_state", { p_match_id: matchId });

export const profileSummary = () => rpc<ProfileSummary>("my_profile_summary");

export async function racketPalette(): Promise<PaletteColor[]> {
  const { data, error } = await supabase
    .from("racket_palette")
    .select("color, name, sort_order")
    .order("sort_order");
  if (error) throw rpcError(error);
  return (data ?? []) as PaletteColor[];
}

export const updateProfile = (patch: {
  fullName?: string;
  frameColor?: string;
  gripColor?: string;
  avatarTone?: number;
}) =>
  rpc("update_my_profile", {
    p_full_name: patch.fullName ?? null,
    p_frame_color: patch.frameColor ?? null,
    p_grip_color: patch.gripColor ?? null,
    p_avatar_tone: patch.avatarTone ?? null,
  });

// ---------------------------------------------------------------------
// Fila, grupo e turno
// ---------------------------------------------------------------------

/**
 * Valida o QR (ou a tag NFC) e a proximidade, devolvendo um token de
 * uso único com 30s de validade. É a Edge Function que guarda o segredo
 * da assinatura — por isso não dá para fazer isso no cliente.
 */
export function scanCourt(input: {
  payload: string;
  latitude: number;
  longitude: number;
  accuracy?: number | null;
  method?: "qr" | "nfc";
  purpose?: "join" | "start";
}) {
  return callFunction<ScanResult>("scan-court", { body: input });
}

/** Abre uma vaga na fila — sozinho; os amigos entram nela depois. */
export const joinQueue = (scanToken: string) =>
  callFunction("join-queue", { body: { scanToken } });

/**
 * Pede para entrar no grupo de alguém. Quem já está em outra fila
 * recebe NQ014; com `leaveCurrent`, sai dela e pede na mesma chamada.
 */
export const requestJoin = (scanToken: string, entryId: string, leaveCurrent = false) =>
  rpc<{ request_id: string; status: string }>("request_join", {
    p_scan_token: scanToken,
    p_entry_id: entryId,
    p_leave_current: leaveCurrent,
  });

/** Entra direto com o PIN do grupo. PIN errado volta como resultado, não como erro. */
export const joinWithPin = (scanToken: string, pin: string, leaveCurrent = false) =>
  rpc<PinResult>("join_with_pin", {
    p_scan_token: scanToken,
    p_pin: pin,
    p_leave_current: leaveCurrent,
  });

export const decideJoinRequest = (requestId: string, approve: boolean) =>
  rpc<{ request_id: string; status: string; reason?: string }>("decide_join_request", {
    p_request_id: requestId,
    p_approve: approve,
  });

export const cancelJoinRequest = (requestId: string) =>
  rpc("cancel_join_request", { p_request_id: requestId });

/** Sai do grupo. A vaga continua com quem ficou; só some quando sai o último. */
export const leaveQueue = (entryId: string, reason?: string) =>
  callFunction("leave-queue", { body: { entryId, reason: reason ?? null } });

/**
 * Check-in na quadra. O primeiro do grupo chamado começa o turno; quem
 * é do grupo e chega depois só registra que está em quadra.
 */
export const checkIn = (scanToken: string) =>
  callFunction<MatchState>("check-in", { body: { scanToken } });

/** O grupo devolve a quadra antes do fim do turno. */
export const finishTurn = (matchId: string) =>
  callFunction<MatchState>("match", { body: { matchId } });

export const registerWebPush = (subscription: PushSubscriptionJSON) =>
  callFunction("register-web-push", { body: subscription });

export const vapidPublicKey = () =>
  callFunction<{ publicKey: string }>("register-web-push", { method: "GET" });

// ---------------------------------------------------------------------
// Administração (só o admin passa — a checagem é no banco)
// ---------------------------------------------------------------------

export const adminOverview = () => rpc<AdminOverview>("admin_overview");

export const adminUsers = (query = "") =>
  rpc<AdminUser[]>("admin_users", { p_query: query || null, p_limit: 100 });

export const adminSetRole = (userId: string, role: Exclude<AppRole, "admin">) =>
  rpc<{ user_id: string; role: AppRole }>("admin_set_role", {
    p_user_id: userId,
    p_role: role,
  });

export const adminUpsertPark = (park: {
  id?: string;
  name?: string;
  district?: string;
  city?: string;
  latitude?: number;
  longitude?: number;
  toneColor?: string;
  photoAlt?: string;
  isActive?: boolean;
}) =>
  rpc("admin_upsert_park", {
    p_id: park.id ?? null,
    p_name: park.name ?? null,
    p_district: park.district ?? null,
    p_city: park.city ?? null,
    p_latitude: park.latitude ?? null,
    p_longitude: park.longitude ?? null,
    p_tone_color: park.toneColor ?? null,
    p_photo_alt: park.photoAlt ?? null,
    p_is_active: park.isActive ?? null,
  });

export const adminUpsertCourt = (court: {
  id?: string;
  parkId?: string;
  courtNumber?: number;
  surface?: string;
  name?: string;
  latitude?: number;
  longitude?: number;
  slotMinutes?: number;
  hasQrCode?: boolean;
  hasNfcTag?: boolean;
  isActive?: boolean;
  maxDistanceMeters?: number;
  gpsToleranceMeters?: number;
  enforceProximity?: boolean;
  callWindowSeconds?: number;
}) =>
  rpc("admin_upsert_court", {
    p_id: court.id ?? null,
    p_park_id: court.parkId ?? null,
    p_court_number: court.courtNumber ?? null,
    p_surface: court.surface ?? null,
    p_name: court.name ?? null,
    p_latitude: court.latitude ?? null,
    p_longitude: court.longitude ?? null,
    p_slot_minutes: court.slotMinutes ?? null,
    p_has_qr_code: court.hasQrCode ?? null,
    p_has_nfc_tag: court.hasNfcTag ?? null,
    p_is_active: court.isActive ?? null,
    p_max_distance_meters: court.maxDistanceMeters ?? null,
    p_gps_tolerance_meters: court.gpsToleranceMeters ?? null,
    p_enforce_proximity: court.enforceProximity ?? null,
    p_call_window_seconds: court.callWindowSeconds ?? null,
  });

/**
 * O conteúdo assinado que vai impresso na quadra.
 *
 * A função responde `{ courts: [...] }` mesmo quando se pede uma só —
 * o mesmo endpoint lista todas quando não vem `courtId`. Tratar isso
 * como objeto deixava nome, versão e URL `undefined`, e o QR não
 * desenhava.
 */
export async function courtQr(courtId: string): Promise<CourtQr> {
  const result = await callFunction<{ courts?: CourtQr[] } & Partial<CourtQr>>(
    `admin-court-qr?courtId=${encodeURIComponent(courtId)}`,
    { method: "GET" },
  );

  const found: Partial<CourtQr> | undefined = result.courts
    ? result.courts.find((court) => court.courtId === courtId) ?? result.courts[0]
    : result;

  if (!found?.printUrl) {
    throw new ApiError(
      "COURT_QR_EMPTY",
      "A função respondeu sem o código desta quadra. Confira se ela está ativa "
        + "e se QR_SIGNING_SECRET e APP_BASE_URL estão definidos no Supabase.",
    );
  }

  return found as CourtQr;
}
