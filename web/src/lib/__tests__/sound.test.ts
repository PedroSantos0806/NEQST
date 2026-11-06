import { describe, expect, it } from "vitest";
import { exitAskText, turnStartText } from "../sound";

/**
 * As frases que o totem fala no parque.
 *
 * Saem por caixa de som a alguns metros de quem está jogando, e são o
 * único texto do app que ninguém LÊ — só ouve. Então o teste é o lugar
 * onde elas são conferidas.
 */
describe("exitAskText", () => {
  it("é a mesma pergunta da faixa na tela", () => {
    // Quem está de costas ouve, quem está de frente lê. Os dois precisam
    // receber a mesma pergunta, palavra por palavra.
    expect(exitAskText("Rafael Lima")).toBe(
      "Rafael Lima, acabou seu tempo. Quer sair ou voltar pro fim da fila?",
    );
  });

  it("sem nome, ainda pede a quadra de volta", () => {
    expect(exitAskText(null)).toBe("Acabou o tempo. Liberem a quadra, por favor.");
    expect(exitAskText("   ")).toContain("Liberem a quadra");
  });

  it("sempre oferece as duas saídas, que são as dos botões", () => {
    const text = exitAskText("Marina");
    expect(text).toContain("sair");
    expect(text).toContain("voltar pro fim da fila");
  });
});

describe("turnStartText", () => {
  it("chama pelo nome quem acabou de entrar", () => {
    expect(turnStartText("Zé do Ibira")).toBe("Começou o tempo da quadra. Bom jogo, Zé do Ibira!");
  });

  it("sem nome, fala com quem está lá", () => {
    expect(turnStartText(undefined)).toBe("Começou o tempo de quadra. Bom jogo!");
  });
});
