/**
 * As faixas que o banco aceita, escritas uma vez só.
 *
 * Cada número aqui corresponde a uma CHECK constraint em
 * `supabase/migrations/`. Antes disto o formulário mandava qualquer
 * coisa e o operador recebia de volta a mensagem crua do Postgres —
 * em inglês e com o nome interno da constraint:
 *
 *   new row for relation "courts" violates check constraint
 *   "courts_slot_minutes_range"
 *
 * Mantendo a faixa do lado de cá, o erro vira uma frase que diz o que
 * fazer, e a dica embaixo do campo diz o limite ANTES de a pessoa
 * digitar. Se uma constraint mudar no banco, muda aqui também — a
 * tradução de `23514` em `supabase.ts` continua sendo a rede de
 * segurança para quando isso for esquecido.
 */
export interface Range {
  min: number;
  max: number;
  /** Como o campo se chama na tela, para montar a mensagem. */
  label: string;
  unit: string;
}

export const LIMITS = {
  /** courts_slot_minutes_range */
  slotMinutes: { min: 20, max: 90, label: "O slot de jogo", unit: "minutos" },
  /** courts_max_distance_meters_check */
  maxDistanceMeters: { min: 10, max: 20000, label: "O raio de proximidade", unit: "metros" },
  /** courts_call_window_range, convertido de segundos para minutos */
  callWindowMinutes: { min: 1, max: 30, label: "A tolerância para o check-in", unit: "minutos" },
} satisfies Record<string, Range>;

export type Parsed = { ok: true; value: number } | { ok: false; message: string };

/** A faixa escrita para caber numa dica de campo. */
export const rangeHint = (range: Range) =>
  `De ${range.min} a ${range.max} ${range.unit}.`;

/**
 * Lê um campo de texto como número dentro da faixa.
 *
 * Aceita vírgula decimal (é como se digita em português) e recusa tudo
 * o mais com a faixa na mensagem. Recusar é de propósito: a versão
 * anterior fazia `Number(texto) || padrão`, então "abc" virava 40 e
 * "0" virava 1000 — o formulário salvava um valor que ninguém pediu e
 * não avisava ninguém.
 */
export function readNumber(text: string, range: Range): Parsed {
  const clean = text.trim().replace(",", ".");
  const value = clean === "" ? Number.NaN : Number(clean);

  if (!Number.isFinite(value) || value < range.min || value > range.max) {
    return {
      ok: false,
      message: `${range.label} precisa ser um número de ${range.min} a ${range.max} ${range.unit}.`,
    };
  }
  return { ok: true, value };
}
