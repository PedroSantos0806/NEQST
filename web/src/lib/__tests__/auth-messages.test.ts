import { describe, expect, it } from "vitest";
import { authMessage } from "../auth-messages";

/**
 * O que a pessoa lê quando o Supabase recusa. O servidor responde em
 * inglês e com termos de quem escreveu o servidor; a tela precisa
 * dizer o que fazer agora.
 */
const erro = (message: string) => authMessage({ message } as Error);

describe("authMessage", () => {
  it("limite de e-mail aponta a saída que funciona na hora", () => {
    const texto = erro("email rate limit exceeded");
    expect(texto).toMatch(/Google/);
    // Dizer só "espere" deixava a pessoa parada na quadra sem opção.
    expect(texto).not.toBe("Muitos e-mails enviados em sequência. Espere alguns minutos e tente de novo.");
  });

  it("reconhece o código novo do Supabase para o mesmo limite", () => {
    expect(erro("over_email_send_rate_limit")).toMatch(/Google/);
  });

  it("senha curta cita o mínimo que o servidor exige", () => {
    expect(erro("Password should be at least 6 characters")).toMatch(/6/);
  });

  it("credencial errada não entrega se o e-mail existe", () => {
    const texto = erro("Invalid login credentials");
    expect(texto).toBe("E-mail ou senha não conferem.");
  });

  it("link expirado manda pedir outro", () => {
    expect(erro("Token has expired or is invalid")).toMatch(/expirou/);
  });

  it("erro desconhecido passa direto — é o contrato de hoje", () => {
    // Deliberado: o texto do GoTrue costuma ser mais útil que um
    // "não foi possível concluir". O preço é que erro desconhecido
    // chega em inglês à beira da quadra. Se algum dia trouxer jargão
    // de banco, é aqui que se filtra.
    expect(erro("Database error saving new user")).toBe("Database error saving new user");
  });

  it("sem mensagem nenhuma, ainda diz alguma coisa", () => {
    expect(authMessage(null)).toBe("Não foi possível concluir. Tente de novo.");
    expect(erro("")).toBe("Não foi possível concluir. Tente de novo.");
  });
});
