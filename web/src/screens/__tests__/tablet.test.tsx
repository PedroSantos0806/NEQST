import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { TabletBoard } from "../Tablet";
import type { TabletScreen } from "../../lib/types";

/**
 * A tela que fica ligada na quadra.
 *
 * Quem lê isto está a alguns metros, de pé, com uma raquete na mão —
 * então o que ela precisa mostrar é: quem está jogando, quanto falta,
 * quem é o próximo, e o botão JOGAR quando a quadra chama.
 */
function base(): TabletScreen {
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
    players_line: "Sem jogo agora — aperte JOGAR para começar",
    queue: [],
    queue_length: 0,
    queue_text: "Fila vazia",
    remaining_seconds: 0,
    total_wait_seconds: 0,
    turn_seconds: 40 * 60 + 45,
    next_position_label: "1º",
    my_entry: null,
    my_group: null,
    my_request: null,
    host: null,
    can_open_host: false,
    court_accepting: true,
    can_join: true,
    my_state: { state: "free" },
    device: { id: "device-1", label: "tablet da quadra 1" },
  };
}

const board = (data: TabletScreen | null, extra: Partial<{ error: string | null; sound: boolean }> = {}) =>
  renderToStaticMarkup(
    <TabletBoard
      data={data}
      error={extra.error ?? null}
      busy={false}
      sound={extra.sound ?? true}
      onAccept={() => undefined}
      onEnableSound={() => undefined}
    />,
  );

function queueItem(overrides: Partial<TabletScreen["queue"][number]> = {}): TabletScreen["queue"][number] {
  return {
    entry_id: "entry-1",
    position: 1,
    position_label: "1º",
    group_size: 2,
    group_label: "Dupla",
    status: "ready",
    is_called: true,
    call_expires_at: null,
    teams_ahead: 0,
    is_mine: false,
    racket: null,
    players: [],
    team_label: "Ana S. + Bruno L.",
    stack: [],
    stack_more: 0,
    eta_seconds: 0,
    ...overrides,
  };
}

describe("a tela do tablet", () => {
  it("sem token válido, explica o que fazer em vez de ficar em branco", () => {
    const html = board(null, { error: "Este tablet não está mais ligado a uma quadra." });
    expect(html).toContain("Tablet sem quadra");
    expect(html).toContain("/admin");
  });

  it("chamando, mostra o nome do grupo e o botão JOGAR", () => {
    const data = base();
    data.is_handover = true;
    data.status_text = "Chamando o próximo";
    data.handover = {
      phase: "calling",
      until: new Date(Date.now() + 11_600).toISOString(),
      seconds_left: 11,
      entry_id: "entry-1",
      label: "Ana S. + Bruno L.",
      spoken_names: "Ana S. e Bruno L.",
      group_size: 2,
      is_mine: false,
      calls_left: 3,
      text: "Chamando o próximo grupo",
      needs_accept: true,
    };
    data.queue = [queueItem({ is_being_called: true })];
    data.queue_length = 1;

    const html = board(data);
    expect(html).toContain("É a vez de");
    expect(html).toContain("Ana S. + Bruno L.");
    expect(html).toContain("JOGAR");
    expect(html).toContain("uma pessoa");
    expect(html).toMatch(/00:1\d/);
  });

  it("entrando, troca o JOGAR pela instrução de entrar", () => {
    const data = base();
    data.is_handover = true;
    data.handover = {
      phase: "entering",
      until: new Date(Date.now() + 28_600).toISOString(),
      seconds_left: 28,
      entry_id: "entry-1",
      label: "Ana S. + Bruno L.",
      spoken_names: "Ana S. e Bruno L.",
      group_size: 2,
      is_mine: false,
      calls_left: 3,
      text: "Entrando na quadra",
      needs_accept: false,
    };

    const html = board(data);
    expect(html).toContain("Entrando na quadra");
    expect(html).toContain("o tempo de jogo começa");
    expect(html).not.toContain(">JOGAR<");
  });

  it("em jogo, mostra o cronômetro e quem está em quadra", () => {
    const data = base();
    data.is_live = true;
    data.status_text = "Em jogo";
    data.players_line = "Ana S. · Bruno L.";
    data.match = {
      match_id: "match-1",
      court_id: "court-1",
      court_name: "Quadra 01",
      entry_id: "entry-1",
      players: [],
      group_size: 2,
      group_label: "Dupla",
      slot_minutes: 40,
      started_at: new Date(Date.now() - 60_000).toISOString(),
      expires_at: new Date(Date.now() + 15 * 60_000).toISOString(),
      ended_at: null,
      end_reason: null,
      is_live: true,
      elapsed_seconds: 60,
      remaining_seconds: 900,
    };

    const html = board(data);
    expect(html).toContain("Em quadra");
    expect(html).toContain("Ana S. · Bruno L.");
    expect(html).toMatch(/1[45]:\d\d/);
  });

  it("som desligado, oferece o toque que libera o áudio", () => {
    const html = board(base(), { sound: false });
    expect(html).toContain("Ativar som");
  });

  it("com o som ligado, não fica pedindo nada", () => {
    expect(board(base(), { sound: true })).not.toContain("Ativar som");
  });

  it("quadra livre com fila, oferece JOGAR para começar logo", () => {
    const data = base();
    data.queue = [queueItem()];
    data.queue_length = 1;
    data.queue_text = "1 na espera";

    const html = board(data);
    expect(html).toContain("Quadra livre");
    expect(html).toContain("JOGAR");
    expect(html).toContain("Ana S. + Bruno L.");
  });
});
