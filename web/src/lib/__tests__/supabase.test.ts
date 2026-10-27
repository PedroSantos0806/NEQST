import { describe, expect, it } from "vitest";
import { rpcError } from "../supabase";

/**
 * O que o operador do parque lê quando o banco recusa. A versão
 * anterior repassava a mensagem crua do Postgres:
 *
 *   new row for relation "courts" violates check constraint
 *   "courts_slot_minutes_range"
 */
describe("rpcError", () => {
  const violacao = (constraint: string) => rpcError({
    code: "23514",
    message: `new row for relation "courts" violates check constraint "${constraint}"`,
  });

  it("traduz o slot fora da faixa", () => {
    expect(violacao("courts_slot_minutes_range").message)
      .toBe("O slot de jogo precisa ficar entre 20 e 90 minutos.");
  });

  it("traduz o raio fora da faixa", () => {
    expect(violacao("courts_max_distance_meters_check").message)
      .toBe("O raio de proximidade precisa ficar entre 10 e 20000 metros.");
  });

  it("traduz a tolerância fora da faixa", () => {
    expect(violacao("courts_call_window_range").message)
      .toBe("A tolerância para o check-in precisa ficar entre 1 e 30 minutos.");
  });

  it("traduz latitude e longitude", () => {
    expect(violacao("courts_latitude_check").message).toMatch(/latitude.*-90 e 90/);
    expect(violacao("parks_longitude_check").message).toMatch(/longitude.*-180 e 180/);
  });

  it("nunca deixa escapar o nome da constraint, mesmo numa que não conhece", () => {
    const erro = violacao("alguma_constraint_nova_de_2027");
    expect(erro.message).not.toMatch(/constraint|relation|violates/);
    expect(erro.message).toMatch(/Confira os números/);
  });

  it("explica o PGRST202 como banco desatualizado, não como função sumida", () => {
    const erro = rpcError({
      code: "PGRST202",
      message: "Could not find the function public.admin_upsert_court(...) in the schema cache",
    });
    expect(erro.message).toMatch(/full_setup\.sql/);
    expect(erro.message).not.toMatch(/schema cache/);
  });

  it("mantém a mensagem do banco quando ela já é nossa e em português", () => {
    expect(rpcError({ code: "NQ025", message: "Quadra não encontrada." }).message)
      .toBe("Quadra não encontrada.");
  });

  it("tem um último recurso quando não vem mensagem nenhuma", () => {
    expect(rpcError(null).message).toBe("Não foi possível concluir.");
  });
});
