import { renderToStaticMarkup } from "react-dom/server";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { TotemQueueRow } from "../../lib/types";

/**
 * A fila no celular de quem entrou pelo QR.
 *
 * O que estes testes protegem é o que a pessoa vê antes de existir
 * qualquer conta: a tela de digitar nome e sobrenome, e a de quem já
 * está na fila. Se esta tela não se explicar sozinha, o QR da placa não
 * serve para nada.
 */

const stored = vi.hoisted(() => ({ current: null as unknown }));

vi.mock("react-router-dom", () => ({
  useNavigate: () => () => undefined,
  useLocation: () => ({ pathname: "/fila", state: stored.current, search: "", hash: "", key: "t" }),
}));

vi.mock("../../lib/party", () => ({
  savedParty: () => null,
  rememberParty: () => undefined,
  forgetParty: () => undefined,
}));

const { Fila, Grupos } = await import("../Fila");

const scan = {
  scanToken: "tok-1",
  expiresAt: new Date(Date.now() + 30_000).toISOString(),
  distanceMeters: 8,
  court: {
    id: "court-1",
    slug: "ibira-3",
    name: "Quadra 03",
    status: "available",
    slot_minutes: 40,
    queue_mode: "fixed_qr",
    surface: "clay",
    court_number: 3,
  },
};

describe("a fila no celular", () => {
  beforeEach(() => {
    stored.current = null;
  });

  it("depois do QR, pede nome e sobrenome — e nenhum cadastro", () => {
    stored.current = { scan };
    const html = renderToStaticMarkup(<Fila />);

    expect(html).toContain("Entrar na fila");
    expect(html).toContain("Seu nome e sobrenome");
    expect(html).toContain("Sem cadastro");
    expect(html).toContain("QUADRA 03");
    expect(html).toContain("Quantas pessoas vão jogar");
    // Começa em 2, como no mock.
    expect(html).toContain(">2<");
    expect(html).toContain("Dá para passar de 4");
    // Nada de senha, e-mail ou login em lugar nenhum desta tela.
    expect(html).not.toContain("senha");
    expect(html).not.toContain("E-mail");
  });

  it("sem QR e sem vaga guardada, diz o que fazer", () => {
    const html = renderToStaticMarkup(<Fila />);
    expect(html).toContain("Você não está em nenhuma fila");
    expect(html).toContain("Escaneie o QR Code da quadra");
    expect(html).toContain("totem");
  });
});

/** Uma linha da fila como o banco devolve, para o seletor de grupos. */
function row(over: Partial<TotemQueueRow> = {}): TotemQueueRow {
  return {
    entry_id: "e1",
    name: "Marina Souza",
    size: 2,
    label: "Simples",
    members: [{ id: "m0", name: "Marina Souza", source: "totem" }],
    position: 1,
    is_next: true,
    source: "totem",
    joined_at: new Date().toISOString(),
    can_join: true,
    eta_seconds: 684,
    eta_at: new Date(Date.now() + 684_000).toISOString(),
    ...over,
  };
}

describe("entrar em um grupo pelo celular", () => {
  it("lista quem está esperando, com a posição e o rótulo", () => {
    const html = renderToStaticMarkup(
      <Grupos
        queue={[
          row(),
          row({ entry_id: "e2", name: "Zé do Ibira", position: 2, size: 6, label: "Grupo de 6, revezando", is_next: false }),
        ]}
        ready
        nameReady
        onJoin={() => undefined}
      />,
    );

    expect(html).toContain("Ou entre em um grupo que já está na fila");
    expect(html).toContain("Não precisa de");
    expect(html).toContain("aprovação de ninguém");
    expect(html).toContain("Marina Souza");
    expect(html).toContain("1º da fila · Simples");
    expect(html).toContain("Zé do Ibira");
    expect(html).toContain("2º da fila · Grupo de 6, revezando");
    // Dois grupos, dois botões de entrar.
    expect(html.match(/>Entrar</g)).toHaveLength(2);
  });

  it("sem nome escrito, os botões ficam travados e a tela diz por quê", () => {
    const html = renderToStaticMarkup(
      <Grupos queue={[row()]} ready={false} nameReady={false} onJoin={() => undefined} />,
    );
    expect(html).toContain("Escreva o seu nome acima");
    expect(html).toContain("disabled");
  });

  it("quem já está jogando não é um grupo para entrar", () => {
    // `can_join` é do banco: a party em quadra vem com ele falso, e
    // então o bloco inteiro desaparece em vez de oferecer o impossível.
    const html = renderToStaticMarkup(
      <Grupos queue={[row({ can_join: false })]} ready nameReady onJoin={() => undefined} />,
    );
    expect(html).toBe("");
  });

  it("fila vazia não mostra seção nenhuma", () => {
    const html = renderToStaticMarkup(
      <Grupos queue={[]} ready nameReady onJoin={() => undefined} />,
    );
    expect(html).toBe("");
  });
});
