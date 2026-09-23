/**
 * Tipos compartilhados entre as Edge Functions (e reutilizáveis pelo app
 * Expo/React Native). Refletem o schema de supabase/migrations.
 */

export type AppRole = "player" | "staff" | "admin";
export type CourtStatus = "available" | "in_game" | "unavailable";
export type QueueMode = "single" | "double";
export type QueueEntryStatus =
  | "waiting"
  | "ready"
  | "playing"
  | "done"
  | "cancelled"
  | "expired";
export type QueueMemberRole = "owner" | "partner";
export type NotificationType =
  | "queue_almost_ready"
  | "queue_turn"
  | "queue_cancelled"
  | "queue_partner_added";

export interface CourtRow {
  id: string;
  slug: string;
  name: string;
  address: string | null;
  photo_url: string | null;
  status: CourtStatus;
  is_active: boolean;
  latitude: number;
  longitude: number;
  max_distance_meters: number;
  gps_tolerance_meters: number;
  average_match_minutes: number;
  qr_secret_version: number;
}

export interface QueuePlayer {
  user_id: string;
  role: QueueMemberRole;
  username: string | null;
  full_name: string | null;
  avatar_url: string | null;
}

/** Retorno de `public.queue_entry_state` / `join_queue`. */
export interface QueueEntryState {
  entry_id: string;
  court_id: string;
  court_name: string;
  mode: QueueMode;
  status: QueueEntryStatus;
  joined_at: string;
  started_at: string | null;
  position: number | null;
  teams_ahead: number | null;
  estimated_wait_minutes: number | null;
  players: QueuePlayer[];
}

/** Retorno de `public.court_queue`. */
export interface CourtQueueState {
  court: {
    id: string;
    slug: string;
    name: string;
    address: string | null;
    status: CourtStatus;
    is_active: boolean;
    latitude: number;
    longitude: number;
    average_match_minutes: number;
    photo_url: string | null;
  };
  can_join: boolean;
  teams_waiting: number;
  current_match: {
    entry_id: string;
    mode: QueueMode;
    started_at: string | null;
    players: QueuePlayer[];
  } | null;
  current_match_remaining_minutes: number | null;
  queue: Array<{
    entry_id: string;
    mode: QueueMode;
    status: QueueEntryStatus;
    joined_at: string;
    position: number;
    teams_ahead: number;
    estimated_wait_minutes: number;
    players: QueuePlayer[];
  }>;
  generated_at: string;
}

export interface OutboxRow {
  id: string;
  user_id: string;
  entry_id: string | null;
  court_id: string | null;
  type: NotificationType;
  title: string;
  body: string;
  data: Record<string, unknown>;
  attempts: number;
}

export interface PushTokenRow {
  user_id: string;
  token: string;
}
