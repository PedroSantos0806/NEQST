import { describe, expect, it } from "vitest";
import { callText } from "../sound";

/**
 * A frase que o tablet grita no parque.
 *
 * Ela sai por caixa de som a alguns metros de quem está jogando, e um
 * "é a sua vez" para uma dupla soa errado o dia inteiro. Como é o único
 * texto do app que ninguém LÊ — só ouve — o teste é o lugar onde ele é
 * conferido.
 */
describe("callText", () => {
  it("fala no plural quando o grupo tem mais de uma pessoa", () => {
    expect(callText("Ana e Bruno", 2)).toBe("Ana e Bruno, é a vez de vocês. Aperte jogar no tablet.");
  });

  it("fala no singular para quem está sozinho", () => {
    expect(callText("Ana S.", 1)).toBe("Ana S., é a sua vez. Aperte jogar no tablet.");
  });

  it("um nome com 'e' no meio já é plural, mesmo sem o tamanho do grupo", () => {
    // O servidor manda "Ana, Bruno e Carla"; o tamanho pode vir 0 numa
    // vaga sem app, e a frase não pode sair no singular por isso.
    expect(callText("Ana, Bruno e Carla")).toContain("é a vez de vocês");
  });

  it("sem nome nenhum, ainda chama alguém", () => {
    expect(callText(null)).toBe("Próximo grupo da fila, é a vez de vocês. Aperte jogar no tablet.");
    expect(callText("   ")).toContain("Próximo grupo da fila");
  });

  it("a frase sempre diz o que fazer", () => {
    for (const text of [callText("Ana", 1), callText("Ana e Bia", 2), callText(undefined)]) {
      expect(text).toContain("Aperte jogar");
    }
  });
});
