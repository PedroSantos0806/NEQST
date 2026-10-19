/**
 * Endereço → coordenadas (geocodificação), pelo Nominatim do
 * OpenStreetMap.
 *
 * Serve para o cadastro de quadra: o operador escreve o endereço de
 * referência, o mapa pula para perto e aí ele arrasta o alfinete até a
 * quadra em si. Em parque grande o endereço nunca é a quadra — ele só
 * economiza o trabalho de achar o bairro no mapa.
 *
 * Sem chave de API de propósito: é uma tela de administração, usada por
 * uma pessoa, algumas vezes por semana. A política do Nominatim pede uso
 * leve e no máximo uma consulta por segundo, e é por isso que a busca
 * acontece só quando se aprieta o botão — nunca enquanto se digita.
 *
 * A resposta é dado de fora: nada é usado sem checar tipo e faixa.
 */
export interface GeocodeHit {
  label: string;
  latitude: number;
  longitude: number;
}

const ENDPOINT = "https://nominatim.openstreetmap.org/search";

/** Coordenada que cabe no mundo real. Protege o mapa e o banco de lixo. */
export function isUsableCoordinate(latitude: number, longitude: number): boolean {
  return (
    Number.isFinite(latitude)
    && Number.isFinite(longitude)
    && Math.abs(latitude) <= 90
    && Math.abs(longitude) <= 180
    && !(latitude === 0 && longitude === 0)
  );
}

export async function searchAddress(query: string, timeoutMs = 10000): Promise<GeocodeHit[]> {
  const text = query.trim();
  if (text.length < 4) {
    throw new Error("Escreva o endereço com um pouco mais de detalhe.");
  }

  const url = new URL(ENDPOINT);
  url.searchParams.set("q", text);
  url.searchParams.set("format", "jsonv2");
  url.searchParams.set("limit", "5");
  url.searchParams.set("accept-language", "pt-BR");
  // O produto é brasileiro; restringir evita que "Rua das Flores"
  // devolva uma rua em Portugal no primeiro resultado.
  url.searchParams.set("countrycodes", "br");

  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), timeoutMs);

  let response: Response;
  try {
    response = await fetch(url.toString(), { signal: abort.signal });
  } catch {
    throw new Error(
      "Não conseguimos consultar a busca de endereços agora. Marque a posição direto no mapa.",
    );
  } finally {
    clearTimeout(timer);
  }

  if (!response.ok) {
    throw new Error(
      `A busca de endereços respondeu ${response.status}. Marque a posição direto no mapa.`,
    );
  }

  const body: unknown = await response.json().catch(() => null);
  if (!Array.isArray(body)) return [];

  const hits: GeocodeHit[] = [];
  for (const item of body) {
    if (typeof item !== "object" || item === null) continue;
    const record = item as { display_name?: unknown; lat?: unknown; lon?: unknown };
    const latitude = Number(record.lat);
    const longitude = Number(record.lon);
    if (!isUsableCoordinate(latitude, longitude)) continue;
    hits.push({
      label: typeof record.display_name === "string" && record.display_name
        ? record.display_name
        : `${latitude.toFixed(5)}, ${longitude.toFixed(5)}`,
      latitude,
      longitude,
    });
  }
  return hits;
}
