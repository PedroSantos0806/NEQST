/**
 * Camada de API: uma função por chamada do backend.
 *
 * Leituras vão direto por RPC (menos round-trips, que é o que importa no
 * 3G). O que precisa de segredo — validar o QR e a proximidade — passa
 * pelas Edge Functions.
 */
import { callFunction, rpcError, supabase } from "./supabase";
import type {
  AdminOverview,
  AdminUser,
  AppRole,
  CourtQr,
  CourtScreen,
  MatchSide,
  MatchState,
  MyQueueState,
  PaletteColor,
  ParkCard,
  ParkScreen,
  PartnerCandidate,
  ProfileSummary,
  QueueMode,
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

export const searchPartners = (query: string) =>
  rpc<PartnerCandidate[]>("search_partners", { p_query: query || null, p_limit: 20 });

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
// Fila e partida
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

export const joinQueue = (input: { scanToken: string; mode: QueueMode; partner?: string | null }) =>
  callFunction("join-queue", { body: input });

export const leaveQueue = (entryId: string, reason?: string) =>
  callFunction("leave-queue", { body: { entryId, reason: reason ?? null } });

/** Check-in na quadra: libera o placar e inicia a partida. */
export const checkIn = (scanToken: string, side: "auto" | "open" = "auto") =>
  callFunction<MatchState>("check-in", { body: { scanToken, side } });

export const reportResult = (matchId: string, winner: MatchSide) =>
  callFunction<MatchState>("match", { body: { matchId, winner } });

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
  });

/** O conteúdo assinado que vai impresso na quadra. */
export const courtQr = (courtId: string) =>
  callFunction<CourtQr>(`admin-court-qr?courtId=${encodeURIComponent(courtId)}`, {
    method: "GET",
  });
