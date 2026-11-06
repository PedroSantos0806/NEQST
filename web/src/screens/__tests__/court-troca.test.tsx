import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { CourtScreen } from "../../lib/types";

/**
 * A troca de turno na tela do celular, agora em uma forma só.
 *
 * Saíram a chamada de 15 s e o JOGAR: desde o totem, o turno de quem
 * está entrando começa sozinho no fim dos 1:30. O que estes testes
 * protegem é a frase que decide se a fila anda na quadra de verdade —
 * que não há nada a apertar — e o aviso de pausa, que explica por que a
 * fila parou.
 *
 * Renderizado com `renderToStaticMarkup` de propósito: o projeto não
 * tem biblioteca de testes de componente, e para ler o que a tela
 * escreve um render puro basta — efeitos não rodam, e nenhum deles
 * desenha nada.
 */

const screen = vi.hoisted(() => ({ current: null as CourtScreen | null }));

vi.mock("react-router-dom", () => ({
  useParams: () => ({ courtId: "court-1" }),
  useNavigate: () => () => undefined,
  useLocation: () => ({ pathname: "/quadra/court-1", state: null, search: "", hash: "", key: "t" }),
  Link: ({ children }: { children?: unknown }) => children as never,
  useSearchParams: () => [new URLSearchParams(), () => undefined],
}));

// A sessão: é ela que separa quem lê a quadra de quem tem conta.
const auth = vi.hoisted(() => ({ session: null as unknown }));

vi.mock("../../hooks/useAuth", () => ({
  useAuth: () => ({ session: auth.session, loading: false, signOut: () => Promise.resolve() }),
}));

vi.mock("../../lib/party", () => ({
  savedParty: () => null,
  rememberParty: () => undefined,
  forgetParty: () => undefined,
}));

vi.mock("../../hooks/useLiveCourt", () => ({
  useLiveCourt: () => ({
    data: screen.current,
    error: null,
    loading: screen.current === null,
    refresh: () => Promise.resolve(screen.current),
  }),
  useTicker: () => 0,
}));

const { Court } = await import("../Court");

function base(): CourtScreen {
  return {
    court: {
      id: "court-1",
      name: "Quadra 01",
      number: 1,
      surface: "hard",
      surface_label: "Rápida",
      status: "available",
      is_active: true,
      slot_minutes: 40,
      call_window_seconds: 120,
      changeover_seconds: 90,
      warn_seconds: 60,
      queue_mode: "fixed_qr",
      checkin_methods: ["qr"],
      latitude: -23.5,
      longitude: -46.6,
      rating_avg: null,
      rating_count: 0,
    },
    park: { id: "park-1", name: "Parque do Teste", district: "Centro" },
    match: null,
    is_live: false,
    is_handover: false,
    handover: null,
    pause: null,
    is_paused: false,
    armed_pause: null,
    exit_ask: null,
    status_text: "Livre",
    players_line: "Sem jogo agora — check-in libera a quadra",
    queue: [],
    queue_length: 0,
    queue_text: "Fila vazia",
    remaining_seconds: 0,
    total_wait_seconds: 0,
    turn_seconds: 40 * 60 + 90,
    next_position_label: "1º",
    my_entry: null,
    my_group: null,
    my_request: null,
    host: null,
    can_open_host: false,
    court_accepting: true,
    can_join: true,
    my_state: { state: "free" },
  };
}

function item(overrides: Partial<CourtScreen["queue"][number]> = {}): CourtScreen["queue"][number] {
  return {
    entry_id: "entry-1",
    position: 1,
    position_label: "1º",
    group_size: 1,
    group_label: "Solo",
    status: "ready",
    is_called: true,
    call_expires_at: null,
    teams_ahead: 0,
    is_mine: true,
    racket: { frame: "#2F4629", grip: "#F1ECEF" },
    players: [],
    team_label: "Bia S.",
    stack: [],
    stack_more: 0,
    eta_seconds: 45,
    turn_number: 1,
    ...overrides,
  };
}

function render(state: CourtScreen): string {
  screen.current = state;
  return renderToStaticMarkup(<Court />);
}

describe("a troca de quadra na tela do celular", () => {
  beforeEach(() => {
    screen.current = null;
    auth.session = { user: { id: "user-1" } };
  });

  it("quadra livre não fala de chamada nem de troca", () => {
    const html = render(base());
    expect(html).toContain("QUADRA LIVRE");
    expect(html).not.toContain("CHAMANDO");
    expect(html).not.toContain("Troca de grupo");
  });

  it("na troca, o placar conta e diz quem entra", () => {
    const state = base();
    state.is_handover = true;
    state.status_text = "Troca de grupo";
    state.handover = {
      phase: "changeover",
      until: new Date(Date.now() + 82_600).toISOString(),
      seconds_left: 82,
      entry_id: "entry-9",
      label: "Bia S.",
      spoken_names: "Bia S.",
      group_size: 1,
      is_mine: false,
      text: "Troca de grupo — o próximo entra sozinho",
      needs_accept: false,
    };

    const html = render(state);
    expect(html).toContain("TROCA DE GRUPO");
    expect(html).toContain("Entra: Bia S.");
    expect(html).toMatch(/01:2\d/);
    expect(html).not.toContain("QUADRA LIVRE");
    // O que ninguém pode ver: um botão de aceitar que não existe mais.
    expect(html).not.toContain("JOGAR");
    expect(html).not.toContain("CHAMANDO");
  });

  it("é a vez do meu grupo: entra sozinho, sem nada a apertar", () => {
    const state = base();
    state.is_handover = true;
    state.handover = {
      phase: "changeover",
      until: new Date(Date.now() + 45_600).toISOString(),
      seconds_left: 45,
      entry_id: "entry-1",
      label: "Bia S.",
      spoken_names: "Bia S.",
      group_size: 2,
      is_mine: true,
      text: "Troca de grupo — o próximo entra sozinho",
      needs_accept: false,
    };
    state.my_entry = item({ is_called: false, status: "ready" });
    state.queue = [state.my_entry];
    state.queue_length = 1;

    const html = render(state);
    expect(html).toContain("Seu turno começa sozinho");
    expect(html).toContain("você não precisa fazer nada");
    expect(html).toContain("PARA COMEÇAR");
    expect(html).not.toContain("JOGAR");
    expect(html).not.toContain("Faça check-in para jogar");
  });

  it("pausada: a tela explica por que a fila parou, e quem libera", () => {
    const state = base();
    state.is_paused = true;
    state.status_text = "Pausada";
    state.pause = {
      kind: "vassourao",
      label: "Vassourão",
      since: new Date(Date.now() - 140_000).toISOString(),
      seconds: 140,
    };
    state.my_entry = item({ is_called: false, status: "waiting" });
    state.queue = [state.my_entry];
    state.queue_length = 1;

    const html = render(state);
    expect(html).toContain("Vassourão");
    expect(html).toContain("A fila está parada");
    expect(html).toContain("liberada no totem");
    // 2 min 20 s de pausa, contados para cima.
    expect(html).toContain("02:20");
  });

  it("sem troca aberta, quem foi chamado continua vendo o check-in", () => {
    const state = base();
    state.my_entry = item({ call_expires_at: new Date(Date.now() + 90_000).toISOString() });
    state.queue = [state.my_entry];
    state.queue_length = 1;

    const html = render(state);
    expect(html).toContain("Faça check-in para jogar");
    expect(html).toContain("DE TOLERÂNCIA");
    expect(html).not.toContain("Seu turno começa sozinho");
    expect(html).not.toContain("É a vez de vocês");
  });

  it("o grupo que já jogou entende que voltou para o fim, não que perdeu a vaga", () => {
    const state = base();
    state.is_live = true;
    state.my_entry = item({ position: 2, position_label: "2º", is_called: false, status: "waiting", turn_number: 3 });
    state.queue = [state.my_entry];
    state.queue_length = 1;
    state.my_group = {
      entry_id: "entry-1",
      status: "waiting",
      pin: "1234",
      is_owner: true,
      checked_in: false,
      players: [{
        user_id: "user-1",
        username: "bia",
        full_name: "Bia Souza",
        short_name: "Bia S.",
        initials: "BS",
        role: "owner",
        checked_in: false,
      }],
      group_size: 1,
      pending_requests: [],
    };

    const html = render(state);
    expect(html).toContain("voltaram para o fim da fila");
    expect(html).toContain("ninguém sai da fila por ter jogado");
  });

  it("quem abre a quadra sem conta lê tudo e é mandado para o totem", () => {
    auth.session = null;
    const state = base();
    state.is_live = true;
    state.match = null;
    state.queue = [item({ is_mine: false, is_called: false, status: "waiting", team_label: "Marina Souza" })];
    state.queue_length = 1;

    const html = render(state);
    // O caminho de escrita, dito onde a pessoa está olhando.
    expect(html).toContain("Para entrar na fila");
    expect(html).toContain("totem que fica na quadra");
    expect(html).toContain("QR Code impresso");
    expect(html).toContain("Não precisa de cadastro");
    // E nenhuma porta para uma conta que não existe mais.
    expect(html).not.toContain("Entrar na Fila");
    expect(html).not.toContain("Entrar no grupo de um amigo");
    // Mas a fila continua visível: é para isso que ele abriu a tela.
    expect(html).toContain("Marina Souza");
  });

  it("com conta, o caminho antigo de entrar na fila continua ali", () => {
    const state = base();
    const html = render(state);
    expect(html).toContain("Entrar na Fila");
    expect(html).not.toContain("Para entrar na fila");
  });
});
