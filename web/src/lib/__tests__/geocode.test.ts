import { afterEach, describe, expect, it, vi } from "vitest";
import { isUsableCoordinate, searchAddress } from "../geocode";

/**
 * A resposta do Nominatim é dado de fora: serviço de terceiro, sem
 * contrato e sem aviso quando muda. Nada dela pode chegar ao mapa sem
 * passar por checagem de tipo e de faixa.
 */
const respondeCom = (body: unknown, status = 200) => {
  vi.stubGlobal("fetch", vi.fn(async () => ({
    ok: status === 200,
    status,
    json: async () => body,
  })));
};

afterEach(() => vi.unstubAllGlobals());

describe("searchAddress", () => {
  it("devolve o acerto de uma resposta bem formada", async () => {
    respondeCom([{ display_name: "Rua A, São Paulo", lat: "-23.5", lon: "-46.6" }]);
    const hits = await searchAddress("Rua A, 100");
    expect(hits).toEqual([{ label: "Rua A, São Paulo", latitude: -23.5, longitude: -46.6 }]);
  });

  it("descarta coordenada que não é número", async () => {
    respondeCom([{ display_name: "X", lat: "abc", lon: "-46.6" }]);
    expect(await searchAddress("Rua A, 100")).toEqual([]);
  });

  it("descarta Null Island (0,0), que é resposta de serviço perdido", async () => {
    respondeCom([{ display_name: "Null Island", lat: "0", lon: "0" }]);
    expect(await searchAddress("Rua A, 100")).toEqual([]);
  });

  it("sem display_name, mostra as coordenadas em vez de 'undefined'", async () => {
    respondeCom([{ lat: "-23.5", lon: "-46.6" }]);
    const hits = await searchAddress("Rua A, 100");
    expect(hits[0].label).toBe("-23.50000, -46.60000");
  });

  it("não quebra quando vem um objeto de erro em vez de uma lista", async () => {
    respondeCom({ error: "Unable to geocode" });
    expect(await searchAddress("Rua A, 100")).toEqual([]);
  });

  it("não quebra quando o corpo não é JSON", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => ({
      ok: true, status: 200, json: async () => { throw new SyntaxError("not json"); },
    })));
    expect(await searchAddress("Rua A, 100")).toEqual([]);
  });

  it("transforma HTTP 429 (limite de uso do Nominatim) em erro legível", async () => {
    respondeCom(null, 429);
    await expect(searchAddress("Rua A, 100")).rejects.toThrow(/429.*mapa/s);
  });

  it("transforma falha de rede em erro legível, sem jargão", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => { throw new TypeError("Failed to fetch"); }));
    await expect(searchAddress("Rua A, 100")).rejects.toThrow(/Marque a posição direto no mapa/);
  });

  it("recusa consulta curta antes de gastar uma chamada ao serviço", async () => {
    const fetchSpy = vi.fn();
    vi.stubGlobal("fetch", fetchSpy);
    await expect(searchAddress("ab")).rejects.toThrow(/detalhe/);
    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it("entrega o texto do serviço sem interpretar como HTML (o React escapa)", async () => {
    respondeCom([{ display_name: "<img src=x onerror=alert(1)>", lat: "-23.5", lon: "-46.6" }]);
    const hits = await searchAddress("Rua A, 100");
    expect(hits[0].label).toBe("<img src=x onerror=alert(1)>");
  });
});

describe("isUsableCoordinate", () => {
  it("aceita uma coordenada real", () => expect(isUsableCoordinate(-23.5, -46.6)).toBe(true));
  it("rejeita latitude fora da faixa", () => expect(isUsableCoordinate(91, 0)).toBe(false));
  it("rejeita longitude fora da faixa", () => expect(isUsableCoordinate(0, 181)).toBe(false));
  it("rejeita NaN", () => expect(isUsableCoordinate(Number.NaN, 0)).toBe(false));
});

describe("searchAddress — cancelamento", () => {
  it("desistir vira AbortError, que a tela não mostra como falha", async () => {
    const controller = new AbortController();
    vi.stubGlobal("fetch", vi.fn((_url: string, init: RequestInit) =>
      new Promise((_resolve, reject) => {
        init.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")));
      })));

    const pendente = searchAddress("Avenida Paulista, 1000", { signal: controller.signal });
    controller.abort();
    await expect(pendente).rejects.toMatchObject({ name: "AbortError" });
  });

  it("o tempo limite vira mensagem legível, não AbortError", async () => {
    vi.stubGlobal("fetch", vi.fn((_url: string, init: RequestInit) =>
      new Promise((_resolve, reject) => {
        init.signal?.addEventListener("abort", () => reject(new DOMException("timeout", "AbortError")));
      })));

    await expect(searchAddress("Avenida Paulista, 1000", { timeoutMs: 10 }))
      .rejects.toThrow(/Marque a posição direto no mapa/);
  });
});
