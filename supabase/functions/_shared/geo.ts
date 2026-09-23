/**
 * Validação de proximidade (US-02).
 *
 * Mesma fórmula da função SQL `public.haversine_meters`, replicada aqui
 * para que a Edge Function rejeite a tentativa antes de tocar o banco.
 */

export const EARTH_RADIUS_METERS = 6_371_000;

export interface Coordinates {
  latitude: number;
  longitude: number;
}

const toRadians = (degrees: number): number => (degrees * Math.PI) / 180;

/** Distância ortodrômica em metros entre dois pontos. */
export function haversineMeters(from: Coordinates, to: Coordinates): number {
  const dLat = toRadians(to.latitude - from.latitude);
  const dLng = toRadians(to.longitude - from.longitude);

  const a = Math.sin(dLat / 2) ** 2 +
    Math.cos(toRadians(from.latitude)) *
      Math.cos(toRadians(to.latitude)) *
      Math.sin(dLng / 2) ** 2;

  return 2 * EARTH_RADIUS_METERS * Math.asin(Math.min(1, Math.sqrt(a)));
}

export function isValidCoordinate(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

export function assertCoordinates(input: Partial<Coordinates>): Coordinates {
  const { latitude, longitude } = input;

  if (
    !isValidCoordinate(latitude) || !isValidCoordinate(longitude) ||
    latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180
  ) {
    throw new Error("Coordenadas inválidas");
  }

  return { latitude, longitude };
}

/**
 * Raio aceito = raio da quadra + a menor parte entre o erro reportado
 * pelo GPS e a tolerância configurada (US-02: +200 m configurável).
 */
export function allowedRadiusMeters(
  maxDistanceMeters: number,
  gpsToleranceMeters: number,
  accuracyMeters?: number | null,
): number {
  const accuracy = typeof accuracyMeters === "number" && accuracyMeters > 0 ? accuracyMeters : 0;
  return maxDistanceMeters + Math.min(accuracy, gpsToleranceMeters);
}
