import { beforeEach, describe, expect, it } from "vitest";
import { callbackUrl, nextFromUrl, peekAfterLogin, rememberAfterLogin, takeAfterLogin } from "../after-login";

/**
 * Para onde o app manda a pessoa depois do login. Caminho vindo da URL
 * é entrada de fora: quem monta o link escolhe o destino. Um `//evil`
 * ou `/\evil` é lido pelo navegador como outro site — era a brecha de
 * redirecionamento aberto que o aviso do react-router descrevia.
 */
beforeEach(() => sessionStorage.clear());

describe("rememberAfterLogin", () => {
  it("guarda um caminho interno", () => {
    rememberAfterLogin("/quadra/abc");
    expect(peekAfterLogin()).toBe("/quadra/abc");
  });

  it("recusa URL absoluta para outro site", () => {
    rememberAfterLogin("https://evil.example/pix");
    expect(peekAfterLogin()).toBeNull();
  });

  it("recusa a barra dupla, que o navegador lê como outro domínio", () => {
    rememberAfterLogin("//evil.example/pix");
    expect(peekAfterLogin()).toBeNull();
  });

  it("recusa a contrabarra, que alguns navegadores normalizam para barra", () => {
    rememberAfterLogin("/\\evil.example");
    expect(peekAfterLogin()).toBeNull();
    rememberAfterLogin("/quadra\\..\\admin");
    expect(peekAfterLogin()).toBeNull();
  });

  it("recusa caminho que não começa com barra", () => {
    rememberAfterLogin("quadra/abc");
    expect(peekAfterLogin()).toBeNull();
  });

  it("take() entrega uma vez e depois cai na home", () => {
    rememberAfterLogin("/perfil");
    expect(takeAfterLogin()).toBe("/perfil");
    // Por contrato devolve "/" e não null: quem chama navega direto
    // com o resultado, e navegar para null não existe.
    expect(takeAfterLogin()).toBe("/");
  });

  it("take() cai na home quando o guardado é hostil", () => {
    sessionStorage.setItem("neqst:after-login", "//evil.example");
    expect(takeAfterLogin()).toBe("/");
  });
});

describe("nextFromUrl", () => {
  const comBusca = (search: string) => {
    window.history.replaceState(null, "", `/entrar${search}`);
    return nextFromUrl();
  };

  it("aceita um caminho interno", () => expect(comBusca("?next=%2Fadmin")).toBe("/admin"));
  it("recusa destino externo", () => expect(comBusca("?next=https%3A%2F%2Fevil.example")).toBeNull());
  it("recusa barra dupla", () => expect(comBusca("?next=%2F%2Fevil.example")).toBeNull());
  it("sem o parâmetro, não inventa destino", () => expect(comBusca("")).toBeNull());
});

describe("callbackUrl", () => {
  it("aponta para a própria origem, nunca para um host de fora", () => {
    expect(callbackUrl()).toBe(`${window.location.origin}/auth/callback`);
  });

  it("carrega o destino guardado, já higienizado", () => {
    rememberAfterLogin("/quadra/abc");
    expect(callbackUrl()).toBe(`${window.location.origin}/auth/callback?next=%2Fquadra%2Fabc`);
  });
});
