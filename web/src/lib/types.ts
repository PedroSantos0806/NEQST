/** Formatos devolvidos pelas RPCs do backend (ver docs/api.md). */

export type CourtSurface = "clay" | "hard" | "grass";
export type QueueMode = "single" | "double";
export type PlayerState = "free" | "queued" | "playing";
export type MatchSide = "a" | "b";

export interface ParkCard {
  park_id: string;
  slug: string;
  name: string;
  district: string | null;
  photo_url: string | null;
  photo_alt: string | null;
  tone_color: string | null;
  latitude: number;
  longitude: number;
  distance_meters: number | null;
  courts_count: number;
  live_count: number;
  queue_count: number;
  any_live: boolean;
  live_text: string;
  surfaces: Array<{ surface: CourtSurface; label: string }>;
  is_mine: boolean;
}

export interface Player {
  user_id: string;
  username: string | null;
  full_name: string | null;
  initials: string;
  short_name: string;
}

export interface MatchState {
  match_id: string;
  court_id: string;
  court_name: string;
  mode: QueueMode;
  slot_minutes: number;
  started_at: string;
  expires_at: string;
  ended_at: string | null;
  winner_side: MatchSide | null;
  is_live: boolean;
  elapsed_seconds: number;
  remaining_seconds: number;
  side_a: { entry_id: string; role: "challenger"; players: Player[] };
  side_b: { entry_id: string | null; role: "holder"; open: boolean; players: Player[] };
}

export interface Racket {
  frame: string;
  grip: string;
}

export interface QueueItem {
  entry_id: string;
  position: number;
  position_label: string;
  mode: QueueMode;
  mode_label: string;
  status: string;
  is_called: boolean;
  call_expires_at: string | null;
  teams_ahead: number;
  is_mine: boolean;
  racket: Racket | null;
  players: Player[];
  team_label: string | null;
  stack: Racket[];
  stack_more: number;
  eta_seconds: number;
}

export interface CourtScreen {
  court: {
    id: string;
    name: string;
    number: number;
    surface: CourtSurface;
    surface_label: string;
    status: string;
    is_active: boolean;
    slot_minutes: number;
    call_window_seconds: number;
    checkin_methods: Array<"qr" | "nfc">;
    latitude: number;
    longitude: number;
    rating_avg: number | null;
    rating_count: number;
  };
  park: { id: string; name: string; district: string | null };
  match: MatchState | null;
  is_live: boolean;
  status_text: string;
  players_line: string;
  queue: QueueItem[];
  queue_length: number;
  queue_text: string;
  remaining_seconds: number;
  total_wait_seconds: number;
  next_position_label: string;
  my_entry: QueueItem | null;
  court_accepting: boolean;
  can_join: boolean;
  my_state: MyState;
}

export interface ParkScreen {
  park: ParkCard & { id: string };
  summary: { courts: number; live: number; queued: number };
  courts: CourtScreen[];
  my_state: MyState;
}

export interface MyState {
  state: PlayerState;
  entry_id?: string;
  court_id?: string;
  court_name?: string;
  park_id?: string;
  park_name?: string;
  where?: string;
}

export interface MyQueueState {
  state: "free" | "queued" | "called" | "playing";
  entry_id?: string;
  mode?: QueueMode;
  court_id?: string;
  court_name?: string;
  park_id?: string;
  park_name?: string;
  position?: number;
  position_label?: string;
  teams_ahead?: number;
  eta_seconds?: number;
  stack?: Racket[];
  stack_more?: number;
  players?: Player[];
  call_expires_at?: string | null;
  call_remaining_seconds?: number | null;
  match?: MatchState | null;
}

export interface PartnerCandidate {
  user_id: string;
  username: string;
  handle: string;
  full_name: string | null;
  initials: string;
  avatar_tone: number;
  racket_frame_color: string;
  racket_grip_color: string;
  state: PlayerState;
  available: boolean;
  where: string | null;
}

export interface ProfileSummary {
  profile: {
    user_id: string;
    username: string;
    full_name: string | null;
    email: string;
    avatar_url: string | null;
    role: string;
    created_at: string;
    avatar_tone: number;
    racket_frame_color: string;
    racket_grip_color: string;
  } | null;
  stats: {
    matches_played: number;
    minutes_played: number;
    courts_visited: number;
    last_match_at: string | null;
  };
  active_entries: unknown[];
}

export interface ScanResult {
  scanToken: string;
  expiresAt: string;
  ttlSeconds: number;
  distanceMeters: number;
  method: "qr" | "nfc";
  purpose: "join" | "start";
  court: {
    id: string;
    parkId: string;
    number: number;
    name: string;
    slug: string;
    surface: CourtSurface;
    status: string;
    slotMinutes: number;
    checkinMethods: Array<"qr" | "nfc">;
  };
}

export interface PaletteColor {
  color: string;
  name: string;
  sort_order: number;
}

// ---------------------------------------------------------------------
// Administração
// ---------------------------------------------------------------------

export type AppRole = "player" | "staff" | "admin";

export interface AdminCourt {
  id: string;
  slug: string;
  name: string;
  court_number: number;
  surface: CourtSurface;
  surface_label: string;
  latitude: number;
  longitude: number;
  slot_minutes: number;
  is_active: boolean;
  status: string;
  has_qr_code: boolean;
  has_nfc_tag: boolean;
  queue_length: number;
}

export interface AdminPark {
  id: string;
  slug: string;
  name: string;
  district: string | null;
  city: string | null;
  latitude: number;
  longitude: number;
  tone_color: string | null;
  photo_alt: string | null;
  is_active: boolean;
  courts: AdminCourt[];
}

export interface AdminOverview {
  parks: AdminPark[];
  totals: { parks: number; courts: number; users: number };
}

export interface AdminUser {
  user_id: string;
  username: string;
  full_name: string | null;
  email: string;
  role: AppRole;
  initials: string;
  created_at: string;
  state: PlayerState;
}

export interface CourtQr {
  courtId: string;
  name: string;
  version: number;
  printUrl: string;
  payload: string;
}
