/** Formatos devolvidos pelas RPCs do backend (ver docs/api.md). */

export type CourtSurface = "clay" | "hard" | "grass";
export type PlayerState = "free" | "queued" | "playing";

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
  role: "owner" | "partner";
  checked_in: boolean;
}

/** O turno de um grupo na quadra. Não há adversário: o grupo joga entre si. */
export interface MatchState {
  match_id: string;
  court_id: string;
  court_name: string;
  entry_id: string;
  players: Player[];
  group_size: number;
  group_label: string;
  slot_minutes: number;
  started_at: string;
  expires_at: string;
  ended_at: string | null;
  end_reason: string | null;
  is_live: boolean;
  elapsed_seconds: number;
  remaining_seconds: number;
  /** O administrador corrigiu o relógio deste turno. */
  time_adjusted_at?: string | null;
  time_adjusted_seconds?: number;
  /** Turno de um grupo sem app — quem já jogava quando a fila abriu, ou um registrado pelo anfitrião. */
  is_offline?: boolean;
  offline_label?: string | null;
}

export interface Racket {
  frame: string;
  grip: string;
}

export interface QueueItem {
  entry_id: string;
  position: number;
  position_label: string;
  group_size: number;
  group_label: string;
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
  /** Quantos turnos este grupo já tem na sequência: 2 ou mais = já jogou e voltou para o fim. */
  turn_number?: number;
  /** É este grupo que a quadra está chamando agora. */
  is_being_called?: boolean;
  /** Vaga de quem está na fila sem o app; só quem organiza a fila mexe nela. */
  is_offline?: boolean;
  offline_label?: string | null;
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
    /** A troca entre dois jogos: 1 min 30 s no handoff. */
    changeover_seconds: number;
    /** Quando o placar vira "Acabando, liberem a quadra": 60 s. */
    warn_seconds: number;
    /** "host": piloto sem nada na placa (Sprint 5). */
    queue_mode?: QueueMode;
    checkin_methods: Array<"qr" | "nfc" | "gps">;
    latitude: number;
    longitude: number;
    rating_avg: number | null;
    rating_count: number;
  };
  park: { id: string; name: string; district: string | null };
  match: MatchState | null;
  is_live: boolean;
  /** A quadra está na troca de 1:30 entre dois jogos. */
  is_handover?: boolean;
  handover?: Handover | null;
  /** Pausa de manutenção em curso. Sem duração: sai só por Retomar. */
  pause?: TotemPause | null;
  is_paused?: boolean;
  /** Pausa marcada para quando este jogo acabar. */
  armed_pause?: PauseKind | null;
  /** Quem acabou de jogar e ainda não respondeu se volta para a fila. */
  exit_ask?: { entry_id: string; name: string } | null;
  status_text: string;
  players_line: string;
  queue: QueueItem[];
  queue_length: number;
  queue_text: string;
  remaining_seconds: number;
  total_wait_seconds: number;
  /** Quanto custa uma rodada da quadra: o turno mais a troca. */
  turn_seconds?: number;
  next_position_label: string;
  my_entry: QueueItem | null;
  my_group: MyGroup | null;
  my_request: MyJoinRequest | null;
  /** A fila com anfitrião aberta nesta quadra, se houver. */
  host?: HostInfo | null;
  /** Quadra em modo anfitrião, sem fila aberta, e quem olha está livre. */
  can_open_host?: boolean;
  court_accepting: boolean;
  can_join: boolean;
  my_state: MyState;
}

export type QueueMode = "fixed_qr" | "host";

/** As três pausas de manutenção do handoff. */
export type PauseKind = "vassourao" | "rega" | "excecao";

export interface TotemPause {
  kind: PauseKind;
  label: string;
  desc?: string;
  since: string;
  seconds: number;
}

/** Os cinco estados da quadra no handoff. */
export type TotemStateName = "playing" | "ending" | "changeover" | "paused" | "free";

/** Uma pessoa dentro de uma party. O nome é o que a quadra chama. */
export interface PartyMember {
  id: string;
  name: string;
  source: string | null;
}

export interface TotemParty {
  entry_id: string;
  name: string;
  size: number;
  label: string;
  members: PartyMember[];
}

export interface TotemQueueRow extends TotemParty {
  position: number;
  is_next: boolean;
  source: string | null;
  joined_at: string;
  /** Ainda cabe gente neste grupo? O teto da party é 20. */
  can_join: boolean;
  /** Nulo = depois da pausa: com pausa em curso ou agendada não dá conta. */
  eta_seconds: number | null;
  eta_at: string | null;
}

/**
 * A tela do totem inteira, resolvida no banco.
 *
 * Uma chamada traz estado, relógio, quem está em quadra, quem entra, a
 * pausa, a pergunta de saída e a fila com previsão — para a tela não
 * recalcular regra nenhuma por conta própria.
 */
export interface TotemState {
  court: {
    id: string;
    name: string;
    number: number;
    surface_label: string;
    park: string | null;
    /** A linha fina do topo: "Quadra 3 · Saibro · Ibirapuera". */
    strip: string;
    is_active: boolean;
    status: string;
  };
  state: TotemStateName;
  slot_seconds: number;
  slot_minutes: number;
  changeover_seconds: number;
  warn_seconds: number;
  remaining_seconds: number;
  changeover_left: number;
  elapsed_seconds: number;
  playing: TotemParty | null;
  next: TotemParty | null;
  exit_ask: { entry_id: string; name: string; text: string } | null;
  pause: TotemPause | null;
  armed_pause: { kind: PauseKind; label: string } | null;
  can_continue: boolean;
  queue: TotemQueueRow[];
  queue_count: number;
  turn_seconds: number;
  generated_at: string;
}

/** O que a entrada na fila devolve: a posição e a tela já atualizada. */
export interface TotemJoinResult {
  entry_id: string;
  party_name: string;
  party_size: number;
  position: number | null;
  playing: boolean;
  /** Entrou no grupo de alguém, em vez de criar uma party nova. */
  joined_group: boolean;
  screen: TotemState;
}

/**
 * Entrar na fila pelo link da quadra.
 *
 * É o `TotemJoinResult` mais duas coisas que só existem fora do totem:
 * a quadra (o link pode ter vindo por slug) e o token da pessoa, que o
 * banco devolve uma única vez e o navegador guarda.
 */
export interface QueueJoinResult extends TotemJoinResult {
  court_id: string;
  /** Nulo quando o toque veio do próprio totem: lá ninguém guarda nada. */
  party_token: string | null;
}

/** A tela de quem entrou pelo QR, no celular. */
export interface PartyScreen extends TotemState {
  my_party: {
    entry_id: string;
    /** O nome do GRUPO: "Marina Souza + Bruno Dias". */
    name: string;
    /** O nome de quem está olhando, dentro do grupo. */
    my_name: string;
    size: number;
    label: string;
    members: PartyMember[];
    in_group: boolean;
    status: string;
    position: number | null;
    is_playing: boolean;
    can_answer_exit: boolean;
  };
}

/** A entrada na fila pelo QR: o party token só existe aqui, uma vez. */
export interface PartyJoinResult {
  entry_id: string;
  party_name: string;
  party_size: number;
  position: number | null;
  playing: boolean;
  joined_group: boolean;
  party_token: string;
  court_id: string;
}

/** Um totem ligado a uma quadra. O token só existe na hora de criar. */
export interface CourtDevice {
  device_id: string;
  court_id: string;
  court_label: string;
  park_name: string;
  label: string | null;
  created_at: string;
  last_seen_at: string | null;
  awake: boolean;
  revoked_at: string | null;
}

export interface NewCourtDevice {
  device_id: string;
  court_id: string;
  label: string | null;
  /** Aparece uma única vez: depois o banco só tem o hash. */
  token: string;
  path: string;
}

/**
 * A troca entre dois jogos.
 *
 * Só existe uma fase desde o totem: `changeover`, de 1 min 30 s, no fim
 * da qual o turno de quem está entrando começa sozinho. As fases da
 * chamada de 15 segundos saíram com ela, e `needs_accept` ficou para
 * não quebrar quem lê o payload — é sempre falso.
 */
export interface Handover {
  phase: "changeover";
  until: string;
  seconds_left: number;
  entry_id: string;
  label: string | null;
  /** Os nomes como a quadra chama: "Ana e Bruno". */
  spoken_names: string;
  group_size: number;
  is_mine: boolean;
  text: string;
  needs_accept: boolean;
}

export interface HostInfo {
  session_id: string;
  opened_at: string;
  host_name: string | null;
  /** Quem olha é quem organiza a fila agora. */
  is_me: boolean;
  /** Quem olha está na fila desta quadra e pode mostrar o QR. */
  can_show_invite: boolean;
}

export interface HostInvite {
  code: string;
  invite_id: string;
  expires_at: string;
  rotate_seconds: number;
  valid_seconds: number;
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

/** O grupo de quem está olhando — só vem para quem faz parte dele. */
export interface MyGroup {
  entry_id: string;
  status: "waiting" | "ready" | "playing";
  pin: string;
  is_owner: boolean;
  checked_in: boolean;
  players: Player[];
  group_size: number;
  pending_requests: JoinRequestItem[];
}

export interface JoinRequestItem {
  request_id: string;
  user_id: string;
  full_name: string | null;
  short_name: string;
  initials: string;
  created_at: string;
  expires_at: string;
}

/** O pedido que eu fiz para entrar no grupo de alguém. */
export interface MyJoinRequest {
  request_id: string;
  entry_id: string;
  court_id: string;
  court_name: string;
  expires_at: string;
  owner_name: string | null;
}

export type PinResult =
  | { joined: true; entry_id: string; court_id: string; status: string }
  | { joined: false; code: "PIN_INVALID"; message: string; attempts_left: number };

export interface MyQueueState {
  state: "free" | "queued" | "called" | "playing";
  entry_id?: string;
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
  group?: MyGroup | null;
  pending_request?: MyJoinRequest | null;
  call_expires_at?: string | null;
  call_remaining_seconds?: number | null;
  match?: MatchState | null;
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
  method: "qr" | "nfc" | "gps" | "host_invite";
  purpose: "join" | "start" | "open";
  court: {
    id: string;
    parkId: string;
    number: number;
    name: string;
    slug: string;
    surface: CourtSurface;
    status: string;
    slotMinutes: number;
    queueMode?: QueueMode;
    checkinMethods: Array<"qr" | "nfc" | "gps">;
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
  address: string | null;
  latitude: number;
  longitude: number;
  slot_minutes: number;
  call_window_seconds: number;
  is_active: boolean;
  status: string;
  has_qr_code: boolean;
  has_nfc_tag: boolean;
  max_distance_meters: number;
  gps_tolerance_meters: number;
  enforce_proximity: boolean;
  qr_secret_version: number;
  queue_mode?: QueueMode;
  host_session_open?: boolean;
  queue_length: number;
}

export interface AdminPark {
  id: string;
  slug: string;
  name: string;
  district: string | null;
  city: string | null;
  address: string | null;
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
  slug?: string;
  name: string;
  version: number;
  printUrl: string;
  payload: string;
}

/** admin_pilot_stats: contagens do piloto, sem nomes. */
export interface PilotStats {
  period: { from: string; to: string };
  totals: {
    people: number;
    app_entries: number;
    offline_entries: number;
    sessions: number;
    turns: number;
    hours_played: number;
  };
  daily: Array<{ day: string; people: number; app_entries: number; offline_entries: number }>;
  origins: Partial<Record<"qr" | "nfc" | "host_invite" | "host_open" | "unknown", number>>;
  funnel: {
    shown: number;
    opened: number;
    scanned: number;
    too_far: number;
    new_accounts: number;
    joined: number;
  };
  wait: { samples: number; median_min: number | null; p90_min: number | null };
  by_hour: Array<{ hour: number; turns: number }>;
  calls: { called: number; missed: number };
  offline_hold: { samples: number; avg_min: number | null; max_min: number | null };
  spreaders: { people: number; top: number[] };
  courts: Array<{ court_id: string; label: string; people: number; app_entries: number; offline_entries: number }>;
}
