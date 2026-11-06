import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { emMin, pessoas, sizeHint, TotemBoard } from "../Totem";
import type { TotemState } from "../../lib/types";

/**
 * A tela do totem, nos cinco estados do handoff.
 *
 * Esta é a única tela que fica sozinha num parque público, de frente
 * para quem não leu manual nenhum: o que ela escreve É o produto. Então
 * o teste lê o texto, e não a estrutura.
 *
 * `TotemBoard` é a parte sem rede de propósito — recebe o estado já
 * resolvido pelo banco e desenha. Renderizado com
 * `renderToStaticMarkup` porque o projeto não tem biblioteca de testes
 * de componente e, para ler texto, um render puro basta.
 */

function base(): TotemState {
  return {
    court: {
      id: "court-1",
      name: "Quadra 03",
      number: 3,
      surface_label: "Saibro",
      park: "Ibirapuera",
      strip: "Quadra 03 · Saibro · Ibirapuera",
      is_active: true,
      status: "available",
    },
    state: "free",
    slot_seconds: 2400,
    slot_minutes: 40,
    changeover_seconds: 90,
    warn_seconds: 60,
    remaining_seconds: 0,
    changeover_left: 0,
    elapsed_seconds: 0,
    playing: null,
    next: null,
    exit_ask: null,
    pause: null,
    armed_pause: null,
    can_continue: false,
    queue: [],
    queue_count: 0,
    turn_seconds: 2490,
    generated_at: new Date().toISOString(),
  };
}

function row(over: Partial<TotemState["queue"][number]> = {}): TotemState["queue"][number] {
  return {
    entry_id: "e1",
    position: 1,
    name: "Marina Souza",
    size: 2,
    label: "Simples",
    is_next: true,
    source: "totem",
    joined_at: new Date().toISOString(),
    eta_seconds: 684,
    eta_at: new Date(Date.now() + 684_000).toISOString(),
    ...over,
  };
}

const render = (data: TotemState) => renderToStaticMarkup(<TotemBoard data={data} />);

describe("o totem", () => {
  it("quadra livre convida a entrar e não mostra relógio", () => {
    const html = render(base());
    expect(html).toContain("Quadra livre");
    expect(html).toContain("--:--");
    expect(html).toContain("Entrar na fila");
    expect(html).toContain("Ninguém na fila. Quem entrar agora joga em seguida.");
    expect(html).toContain("Quadra 03 · Saibro · Ibirapuera");
    // Com a quadra livre não existe barra de progresso de nada.
    expect(html).not.toContain("Continuar jogando");
  });

  it("em jogo mostra quem está em quadra, o rótulo e o tempo", () => {
    const data = base();
    data.state = "playing";
    data.remaining_seconds = 684;
    data.elapsed_seconds = 1716;
    data.playing = { entry_id: "p1", name: "Rafael Lima", size: 2, label: "Simples" };

    const html = render(data);
    expect(html).toContain("Em jogo, faltam");
    expect(html).toContain("11:24");
    expect(html).toContain("Rafael Lima");
    expect(html).toContain("Simples · 2 pessoas");
    expect(html).toContain("em quadra há 28:36");
    expect(html).toContain("partida de 40 min");
  });

  it("no último minuto, com fila, pede a quadra de volta e não oferece continuar", () => {
    const data = base();
    data.state = "ending";
    data.remaining_seconds = 45;
    data.elapsed_seconds = 2355;
    data.playing = { entry_id: "p1", name: "Rafael Lima", size: 2, label: "Simples" };
    data.next = { entry_id: "e1", name: "Marina Souza", size: 2, label: "Simples" };
    data.queue = [row()];
    data.queue_count = 1;

    const html = render(data);
    expect(html).toContain("Acabando, liberem a quadra");
    expect(html).toContain("Entra em seguida: Marina Souza");
    expect(html).toContain("00:45");
    expect(html).not.toContain("Continuar jogando");
  });

  it("no último minuto, sem fila, o Continuar aparece", () => {
    const data = base();
    data.state = "ending";
    data.remaining_seconds = 30;
    data.playing = { entry_id: "p1", name: "Duda Única", size: 1, label: "Sozinho" };
    data.can_continue = true;

    const html = render(data);
    expect(html).toContain("Acabando");
    expect(html).toContain("Continuar jogando");
    expect(html).toContain("Mais 40 min, só com a fila vazia");
  });

  it("na troca, a pergunta de saída traz as duas opções e quem entra", () => {
    const data = base();
    data.state = "changeover";
    data.changeover_left = 82;
    data.next = { entry_id: "e1", name: "Marina Souza", size: 2, label: "Simples" };
    data.queue = [row()];
    data.queue_count = 1;
    data.exit_ask = {
      entry_id: "p1",
      name: "Rafael Lima",
      text: "Rafael Lima, acabou seu tempo. Quer sair ou voltar pro fim da fila?",
    };

    const html = render(data);
    expect(html).toContain("Trocando de jogo");
    expect(html).toContain("01:22");
    expect(html).toContain("Entra: Marina Souza");
    // A faixa, com a pergunta inteira e os dois caminhos.
    expect(html).toContain("acabou seu tempo. Quer sair ou voltar pro fim da fila?");
    expect(html).toContain("Voltar pra fila");
    expect(html).toContain("Sair");
    // A próxima aparece nos dois lugares: ela ainda é alguém esperando.
    expect(html).toContain("· próximo");
  });

  it("pausada: cronômetro para cima, Retomar no lugar das pausas", () => {
    const data = base();
    data.state = "paused";
    data.pause = {
      kind: "rega",
      label: "Rega da quadra",
      desc: "Estão regando a quadra.",
      since: new Date(Date.now() - 140_000).toISOString(),
      seconds: 140,
    };
    data.queue = [row({ eta_seconds: null, eta_at: null })];
    data.queue_count = 1;

    const html = render(data);
    expect(html).toContain("Pausada · Rega da quadra");
    expect(html).toContain("02:20");
    expect(html).toContain("Ninguém entra agora");
    expect(html).toContain("Estão regando a quadra.");
    expect(html).toContain("volta quando alguém retomar");
    expect(html).toContain("Retomar a quadra");
    // Um comando de cada vez: com a quadra pausada não há o que pausar.
    expect(html).not.toContain("Pausar a quadra");
    expect(html).not.toContain("Vassourão");
    // E a previsão não é calculável.
    expect(html).toContain("depois da pausa");
  });

  it("pausa agendada avisa que começa no fim do jogo e que dá para cancelar", () => {
    const data = base();
    data.state = "playing";
    data.remaining_seconds = 600;
    data.playing = { entry_id: "p1", name: "Rafael Lima", size: 2, label: "Simples" };
    data.armed_pause = { kind: "vassourao", label: "Vassourão" };

    const html = render(data);
    expect(html).toContain("Vassourão agendado.");
    expect(html).toContain("Começa quando este jogo acabar");
    expect(html).toContain("Toque de novo para cancelar");
    // Agendar não interrompe o jogo em curso.
    expect(html).toContain("Em jogo, faltam");
  });

  it("a fila mostra o rótulo do handoff para cada tamanho de party", () => {
    const data = base();
    data.state = "playing";
    data.remaining_seconds = 600;
    data.playing = { entry_id: "p1", name: "Rafael Lima", size: 2, label: "Simples" };
    data.queue = [
      row({ entry_id: "e1", position: 1, name: "Zé do Ibira", size: 6, label: "Grupo de 6, revezando" }),
      row({ entry_id: "e2", position: 2, name: "Priscila Alves", size: 4, label: "Duplas", is_next: false }),
      row({ entry_id: "e3", position: 3, name: "Dudu", size: 1, label: "Sozinho", is_next: false }),
    ];
    data.queue_count = 3;

    const html = render(data);
    expect(html).toContain("3 parties esperando");
    expect(html).toContain("Zé do Ibira");
    expect(html).toContain("6 pessoas");
    expect(html).toContain("Priscila Alves");
    expect(html).toContain("Dudu");
    expect(html).toContain("1 pessoa");
  });
});

describe("os textos da entrada na fila", () => {
  it("conta pessoas no singular e no plural", () => {
    expect(pessoas(1)).toBe("1 pessoa");
    expect(pessoas(6)).toBe("6 pessoas");
  });

  it("a previsão fala como gente", () => {
    expect(emMin(20)).toBe("agora");
    expect(emMin(684)).toBe("em 11 min");
    expect(emMin(3900)).toBe("em 1h05");
  });

  it("a dica do contador muda quando a party passa de 4", () => {
    expect(sizeHint(2)).toContain("Dá para passar de 4");
    expect(sizeHint(6)).toContain("revezar entre as 6 pessoas");
  });
});
