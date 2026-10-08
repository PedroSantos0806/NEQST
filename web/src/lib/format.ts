/** Formatações do protótipo: mm:ss, hh:mm e o ETA legível. */

const pad = (n: number) => String(n).padStart(2, "0");

export function mmss(totalSeconds: number): string {
  const s = Math.max(0, Math.floor(totalSeconds));
  return `${pad(Math.floor(s / 60))}:${pad(s % 60)}`;
}

export function hhmm(totalSeconds: number): string {
  const s = Math.max(0, Math.floor(totalSeconds));
  return `${pad(Math.floor(s / 3600))}:${pad(Math.floor((s % 3600) / 60))}`;
}

export function eta(totalSeconds: number): string {
  if (totalSeconds <= 0) return "Agora";
  const minutes = Math.ceil(totalSeconds / 60);
  return minutes < 60 ? `${minutes} min` : hhmm(totalSeconds);
}

export function greeting(date = new Date()): string {
  const hour = date.getHours();
  if (hour < 12) return "Bom dia";
  if (hour < 18) return "Boa tarde";
  return "Boa noite";
}

export function firstName(name: string | null | undefined): string {
  return (name ?? "").trim().split(/\s+/)[0] || "jogador";
}

export function initialsOf(name: string | null | undefined): string {
  const parts = (name ?? "").trim().split(/\s+/).filter(Boolean);
  if (parts.length === 0) return "?";
  const last = parts.length > 1 ? parts[parts.length - 1][0] : "";
  return (parts[0][0] + last).toUpperCase();
}

/** Distância em metros, do jeito que cabe num rótulo. */
export function distance(meters: number | null): string | null {
  if (meters == null) return null;
  return meters < 1000 ? `${Math.round(meters)} m` : `${(meters / 1000).toFixed(1)} km`;
}

export const SURFACE_COLOR: Record<string, string> = {
  clay: "#B13F16",
  hard: "#39678C",
  grass: "#778845",
};

/** Em grama o texto escuro lê melhor que o branco. */
export const surfaceTextColor = (surface: string) => (surface === "grass" ? "#0A0E0B" : "#FFFFFF");
