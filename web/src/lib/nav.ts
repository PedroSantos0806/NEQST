/**
 * Onde o jogador estava.
 *
 * O protótipo tem a barra inferior (Quadras · Placar · Perfil) sempre
 * dentro de um parque, e o Placar aponta para a última quadra aberta.
 * Guardamos isso na sessão: é navegação, não dado — não vale uma
 * chamada ao backend nem polui a URL.
 */
const PARK_KEY = "neqst:park";
const COURT_KEY = (parkId: string) => `neqst:court:${parkId}`;

function read(key: string): string | null {
  try {
    return sessionStorage.getItem(key);
  } catch {
    return null;
  }
}

function write(key: string, value: string): void {
  try {
    sessionStorage.setItem(key, value);
  } catch {
    /* modo privado: a navegação só perde a memória, nada quebra */
  }
}

export const rememberPark = (parkId: string) => write(PARK_KEY, parkId);
export const lastPark = () => read(PARK_KEY);

export const rememberCourt = (parkId: string, courtId: string) => write(COURT_KEY(parkId), courtId);
export const lastCourt = (parkId: string) => read(COURT_KEY(parkId));
