/**
 * Camada de API: uma função por chamada do backend.
 *
 * Leituras vão direto por RPC (menos round-trips, que é o que importa no
 * 3G). O que precisa de segredo — validar o QR e a proximidade — passa
 * pelas Edge Functions.
 */
import { callFunction, rpcError, supabase } from "./supabase";
import type {
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
