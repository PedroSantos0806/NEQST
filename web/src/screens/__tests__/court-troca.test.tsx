import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { CourtScreen } from "../../lib/types";

/**
 * A troca de quadra na tela.
 *
 * O que estes testes protegem é a frase mais importante da rotação
 * automática: quem é o próximo não precisa fazer nada. Se um dia a tela
 * voltar a pedir check-in no minuto da troca, é aqui que quebra.
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
      changeover_seconds: 60,
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
    is_changeover: false,
    changeover: null,
    status_text: "Livre",
    players_line: "Sem jogo agora — check-in libera a quadra",
    queue: [],
    queue_length: 0,
    queue_text: "Fila vazia",
    remaining_seconds: 0,
    total_wait_seconds: 0,
    turn_seconds: 40 * 60 + 60,
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

describe("a troca de quadra na tela", () => {
  beforeEach(() => {
    screen.current = null;
  });

  it("quadra livre não fala de troca", () => {
    const html = render(base());
    expect(html).toContain("QUADRA LIVRE");
    expect(html).not.toContain("Troca de grupo");
  });

  it("na troca, o placar mostra a contagem e quem está entrando", () => {
    const state = base();
    state.is_changeover = true;
    state.status_text = "Troca de grupo";
    state.changeover = {
      until: new Date(Date.now() + 45_000).toISOString(),
      seconds_left: 45,
      next_entry_id: "entry-9",
      next_label: "Bia S.",
      next_is_mine: false,
      text: "Troca de grupo — o próximo entra em quadra",
    };

    const html = render(state);
    expect(html).toContain("TROCA DE GRUPO");
    expect(html).toContain("Troca de grupo · o próximo entra sozinho");
    expect(html).toContain("Entrando: Bia S.");
    // O cronômetro grande conta para baixo, em mm:ss.
    expect(html).toMatch(/00:4\d/);
    expect(html).not.toContain("QUADRA LIVRE");
  });

  it("para quem entra agora, a tela diz que não há nada a fazer", () => {
    const state = base();
    state.is_changeover = true;
    state.changeover = {
      until: new Date(Date.now() + 38_000).toISOString(),
      seconds_left: 38,
      next_entry_id: "entry-1",
      next_label: "Bia S.",
      next_is_mine: true,
      text: "Troca de grupo — o próximo entra em quadra",
    };
    state.my_entry = item();
    state.queue = [state.my_entry];
    state.queue_length = 1;

    const html = render(state);
    expect(html).toContain("Seu turno começa sozinho");
    expect(html).toContain("você não precisa fazer nada");
    // O botão existe, mas como atalho — e nunca como obrigação.
    expect(html).toContain("Já estamos em quadra");
    expect(html).not.toContain("Faça check-in para jogar");
    expect(html).not.toContain("DE TOLERÂNCIA");
  });

  it("fora da troca, quem foi chamado continua vendo o check-in", () => {
    const state = base();
    state.my_entry = item({ call_expires_at: new Date(Date.now() + 90_000).toISOString() });
    state.queue = [state.my_entry];
    state.queue_length = 1;

    const html = render(state);
    expect(html).toContain("Faça check-in para jogar");
    expect(html).toContain("DE TOLERÂNCIA");
    expect(html).not.toContain("Seu turno começa sozinho");
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
});
