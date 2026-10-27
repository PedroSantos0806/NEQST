import { describe, expect, it } from "vitest";
import { LIMITS, rangeHint, readNumber } from "../limits";

/**
 * O formulário de quadra tinha `Number(campo) || padrão`: texto virava
 * o padrão em silêncio e número fora da faixa ia até o banco só para
 * voltar como `check constraint "courts_slot_minutes_range"` em inglês.
 * Estes casos são exatamente os que a banca de revisão reproduziu.
 */
describe("readNumber", () => {
  it("aceita um número dentro da faixa", () => {
    expect(readNumber("40", LIMITS.slotMinutes)).toEqual({ ok: true, value: 40 });
  });

  it("aceita vírgula decimal, que é como se digita em português", () => {
    expect(readNumber("2,5", LIMITS.callWindowMinutes)).toEqual({ ok: true, value: 2.5 });
  });

  it("recusa texto em vez de trocar por um padrão calado", () => {
    const parsed = readNumber("abc", LIMITS.slotMinutes);
    expect(parsed.ok).toBe(false);
    expect(parsed.ok === false && parsed.message).toContain("20 a 90");
  });

  it("recusa zero — parecia uma escolha e virava 1000", () => {
    expect(readNumber("0", LIMITS.maxDistanceMeters).ok).toBe(false);
  });

  it("recusa campo vazio", () => {
    expect(readNumber("   ", LIMITS.slotMinutes).ok).toBe(false);
  });

  it("recusa abaixo do mínimo que o banco aceita", () => {
    expect(readNumber("10", LIMITS.slotMinutes).ok).toBe(false);
  });

  it("recusa acima do máximo que o banco aceita", () => {
    expect(readNumber("50000", LIMITS.maxDistanceMeters).ok).toBe(false);
  });

  it("aceita exatamente as pontas da faixa", () => {
    expect(readNumber("20", LIMITS.slotMinutes).ok).toBe(true);
    expect(readNumber("90", LIMITS.slotMinutes).ok).toBe(true);
    expect(readNumber("10", LIMITS.maxDistanceMeters).ok).toBe(true);
    expect(readNumber("20000", LIMITS.maxDistanceMeters).ok).toBe(true);
  });

  it("recusa infinito e notação que o Number() aceitaria", () => {
    expect(readNumber("Infinity", LIMITS.slotMinutes).ok).toBe(false);
    expect(readNumber("1e9", LIMITS.maxDistanceMeters).ok).toBe(false);
  });

  it("a mensagem diz o que fazer, não o nome da constraint", () => {
    const parsed = readNumber("5", LIMITS.maxDistanceMeters);
    expect(parsed.ok === false && parsed.message).toBe(
      "O raio de proximidade precisa ser um número de 10 a 20000 metros.",
    );
  });
});

describe("rangeHint", () => {
  it("escreve a faixa para caber na dica do campo", () => {
    expect(rangeHint(LIMITS.slotMinutes)).toBe("De 20 a 90 minutos.");
  });
});
