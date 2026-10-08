/**
 * Quem está usando o app.
 *
 * Iniciais, tom do avatar e cores da raquete aparecem em várias telas e
 * quase nunca mudam. Uma chamada por sessão, compartilhada — e a tela
 * de perfil invalida o cache quando o jogador salva.
 */
import { profileSummary } from "./api";
import type { ProfileSummary } from "./types";

let cache: Promise<ProfileSummary> | null = null;

export function me(): Promise<ProfileSummary> {
  if (!cache) {
    cache = profileSummary().catch((cause: Error) => {
      cache = null;
      throw cause;
    });
  }
  return cache;
}

export function invalidateMe(): void {
  cache = null;
}

export const TONES = [
  { background: "#B13F16", color: "#FFFFFF" },
  { background: "#39678C", color: "#FFFFFF" },
  { background: "#C49051", color: "#0A0E0B" },
];

export const toneStyle = (tone: number | null | undefined) => TONES[(tone ?? 0) % TONES.length];
