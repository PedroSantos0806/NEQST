/**
 * Localização one-shot, como o critério da US-02 pede: nada de
 * watchPosition, que drena bateria sem necessidade aqui.
 *
 * Na web a precisão é bem pior que no app (em desktop vem do IP e erra
 * quilômetros). Mandamos `accuracy` ao backend, que aplica a tolerância
 * da quadra — e é esperado que no desktop dê "longe demais".
 */
export interface Position {
  latitude: number;
  longitude: number;
  accuracy: number | null;
}

export class LocationError extends Error {
  constructor(message: string, readonly kind: "denied" | "unavailable" | "timeout" | "unsupported") {
    super(message);
    this.name = "LocationError";
  }
}

export function getPosition(timeoutMs = 12000): Promise<Position> {
  return new Promise((resolve, reject) => {
    if (!("geolocation" in navigator)) {
      reject(new LocationError("Este navegador não informa a localização.", "unsupported"));
      return;
    }

    navigator.geolocation.getCurrentPosition(
      ({ coords }) =>
        resolve({
          latitude: coords.latitude,
          longitude: coords.longitude,
          accuracy: Number.isFinite(coords.accuracy) ? coords.accuracy : null,
        }),
      (error) => {
        if (error.code === error.PERMISSION_DENIED) {
          reject(new LocationError(
            "Precisamos da sua localização para confirmar que você está na quadra.",
            "denied",
          ));
        } else if (error.code === error.TIMEOUT) {
          reject(new LocationError("Não conseguimos sua localização a tempo.", "timeout"));
        } else {
          reject(new LocationError("Localização indisponível agora.", "unavailable"));
        }
      },
      { enableHighAccuracy: true, timeout: timeoutMs, maximumAge: 0 },
    );
  });
}
