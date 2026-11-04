import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { CourtScreen } from "../../lib/types";

/**
 * A troca de turno na tela, nas três formas dela.
 *
 * O que estes testes protegem são as duas frases que decidem se a fila
 * anda na quadra de verdade:
 *
 *   . na chamada, que basta UMA pessoa apertar JOGAR;
 *   . na troca automática (quadra sem tablet), que não há nada a fazer.
 *
 * Trocar uma pela outra deixa todo mundo esperando que o outro aperte.
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
      handover_call_seconds: 15,
      handover_entry_seconds: 30,
      changeover_seconds: 60,
      has_tablet: true,
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

  it("quadra livre não fala de chamada nem de troca", () => {
    const html = render(base());
    expect(html).toContain("QUADRA LIVRE");
    expect(html).not.toContain("CHAMANDO");
    expect(html).not.toContain("Troca de grupo");
  });

  it("na chamada, o placar mostra a contagem e quem está sendo chamado", () => {
    const state = base();
    state.is_handover = true;
    state.status_text = "Chamando o próximo";
    state.handover = {
      phase: "calling",
      until: new Date(Date.now() + 12_600).toISOString(),
      seconds_left: 12,
      entry_id: "entry-9",
      label: "Bia S.",
      spoken_names: "Bia S.",
      group_size: 1,
      is_mine: false,
      calls_left: 2,
      text: "Chamando o próximo grupo",
      needs_accept: true,
    };

    const html = render(state);
    expect(html).toContain("CHAMANDO");
    expect(html).toContain("Chamando: Bia S.");
    expect(html).toMatch(/00:1\d/);
    expect(html).not.toContain("QUADRA LIVRE");
    // Quem olha de fora entende o que acontece se ninguém aceitar.
    expect(html).toContain("a vez passa para o seguinte");
  });

  it("chamado, o grupo vê JOGAR e que basta uma pessoa", () => {
    const state = base();
    state.is_handover = true;
    state.handover = {
      phase: "calling",
      until: new Date(Date.now() + 9_600).toISOString(),
      seconds_left: 9,
      entry_id: "entry-1",
      label: "Bia S.",
      spoken_names: "Bia S.",
      group_size: 2,
      is_mine: true,
      calls_left: 2,
      text: "Chamando o próximo grupo",
      needs_accept: true,
    };
    state.my_entry = item();
    state.queue = [state.my_entry];
    state.queue_length = 1;

    const html = render(state);
    expect(html).toContain("É a vez de vocês");
    expect(html).toContain("JOGAR");
    expect(html).toContain("uma pessoa");
    expect(html).toContain("voltam para o fim da fila");
    expect(html).not.toContain("Faça check-in para jogar");
  });

  it("aceita, a tela diz para entrar e que o tempo começa no fim", () => {
    const state = base();
    state.is_handover = true;
    state.handover = {
      phase: "entering",
      until: new Date(Date.now() + 26_600).toISOString(),
      seconds_left: 26,
      entry_id: "entry-1",
      label: "Bia S.",
      spoken_names: "Bia S.",
      group_size: 2,
      is_mine: true,
      calls_left: 2,
      text: "Entrando na quadra",
      needs_accept: false,
    };
    state.my_entry = item({ is_called: false, status: "ready" });
    state.queue = [state.my_entry];
    state.queue_length = 1;

    const html = render(state);
    expect(html).toContain("Seu tempo começa agora");
    expect(html).toContain("PARA ENTRAR");
    expect(html).toMatch(/00:2\d/);
    expect(html).not.toContain("JOGAR");
  });

  it("quadra sem tablet: a troca automática não pede nada", () => {
    const state = base();
    state.court.has_tablet = false;
    state.is_handover = true;
    state.handover = {
      phase: "changeover",
      until: new Date(Date.now() + 45_600).toISOString(),
      seconds_left: 45,
      entry_id: "entry-1",
      label: "Bia S.",
      spoken_names: "Bia S.",
      group_size: 1,
      is_mine: true,
      calls_left: 0,
      text: "Troca de grupo — o próximo entra sozinho",
      needs_accept: false,
    };
    state.my_entry = item({ is_called: false, status: "ready" });
    state.queue = [state.my_entry];
    state.queue_length = 1;

    const html = render(state);
    expect(html).toContain("Seu turno começa sozinho");
    expect(html).toContain("você não precisa fazer nada");
    expect(html).toContain("Já estamos em quadra");
    expect(html).not.toContain("É a vez de vocês");
  });

  it("sem chamada aberta, quem foi chamado continua vendo o check-in", () => {
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
});
