import { describe, expect, it } from "vitest";
import { MIN_PASSWORD, PASSWORD_HINT, checkPassword } from "../password";

/**
 * A regra pedida: mínimo baixo, letras e números, PIN permitido.
 *
 * O mínimo é 6 e não 4 porque o Supabase Auth eleva qualquer valor
 * menor ao chegar no servidor (`defaultMinPasswordLength = 6`). Pedir
 * 4 na tela faria o cadastro passar aqui e ser recusado lá, em inglês.
 */
describe("checkPassword", () => {
  it("aceita um PIN só de dígitos — é o caso que motivou a mudança", () => {
    expect(checkPassword("123456")).toEqual({ ok: true });
  });

  it("aceita letras e números misturados", () => {
    expect(checkPassword("neqst1")).toEqual({ ok: true });
    expect(checkPassword("Quadra07")).toEqual({ ok: true });
  });

  it("não exige maiúscula, símbolo nem mistura de tipos", () => {
    expect(checkPassword("abcdef")).toEqual({ ok: true });
  });

  it("aceita exatamente o mínimo", () => {
    expect(checkPassword("a".repeat(MIN_PASSWORD)).ok).toBe(true);
  });

  it("recusa um caractere abaixo do mínimo, dizendo que pode ser PIN", () => {
    const parsed = checkPassword("a".repeat(MIN_PASSWORD - 1));
    expect(parsed.ok).toBe(false);
    expect(parsed.ok === false && parsed.message).toContain(String(MIN_PASSWORD));
    expect(parsed.ok === false && parsed.message).toMatch(/PIN/);
  });

  it("recusa 4 dígitos — o servidor recusaria depois, em inglês", () => {
    expect(checkPassword("1234").ok).toBe(false);
  });

  it("recusa espaço, acento e símbolo: erro de digitação no sol", () => {
    for (const ruim of ["senha 1", "sensação", "senha!", "a-b-c-d", "café123"]) {
      expect(checkPassword(ruim).ok, ruim).toBe(false);
    }
  });

  it("recusa campo vazio", () => {
    expect(checkPassword("").ok).toBe(false);
  });

  it("a mensagem do tamanho não vira a de caractere inválido", () => {
    // Curta E com símbolo: a primeira coisa a corrigir é o tamanho.
    const parsed = checkPassword("a!");
    expect(parsed.ok === false && parsed.message).toMatch(/pelo menos/);
  });

  it("a dica do campo diz as três coisas que a pessoa precisa saber", () => {
    expect(PASSWORD_HINT).toMatch(new RegExp(String(MIN_PASSWORD)));
    expect(PASSWORD_HINT).toMatch(/letras e números/);
    expect(PASSWORD_HINT).toMatch(/PIN/);
  });
});
