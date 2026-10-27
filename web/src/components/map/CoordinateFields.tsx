import { useState } from "react";
import { buttonStyle, fieldStyle } from "../ui";
import { isUsableCoordinate } from "../../lib/geocode";
import type { MapPosition } from "./useLeafletMap";

/**
 * A saída para quem já tem o par na mão — e para quando o mapa não
 * carrega. O cadastro não pode depender do mapa para acontecer: na
 * rede de um parque, às vezes não carrega mesmo.
 */
export function CoordinateFields({
  latitude,
  longitude,
  onApply,
}: {
  latitude: number | null;
  longitude: number | null;
  onApply: (position: MapPosition) => void;
}) {
  const [open, setOpen] = useState(false);
  const [lat, setLat] = useState(latitude != null ? latitude.toFixed(6) : "");
  const [lng, setLng] = useState(longitude != null ? longitude.toFixed(6) : "");
  const [error, setError] = useState<string | null>(null);

  if (!open) {
    return (
      <button
        type="button"
        className="press"
        onClick={() => {
          // Reabre já com o que o mapa marcou, não com o que foi
          // digitado da última vez.
          setLat(latitude != null ? latitude.toFixed(6) : "");
          setLng(longitude != null ? longitude.toFixed(6) : "");
          setOpen(true);
        }}
        style={{ alignSelf: "flex-start", padding: 0, background: "transparent", border: 0, fontSize: 11, fontWeight: 700, textDecoration: "underline", color: "var(--green)" }}
      >
        Digitar as coordenadas
      </button>
    );
  }

  function apply() {
    const parsedLat = Number(lat.replace(",", "."));
    const parsedLng = Number(lng.replace(",", "."));
    if (!isUsableCoordinate(parsedLat, parsedLng)) {
      setError("Latitude entre -90 e 90, longitude entre -180 e 180.");
      return;
    }
    setError(null);
    onApply({ latitude: parsedLat, longitude: parsedLng });
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 6, padding: 8, background: "var(--chalk)", border: "1.5px solid rgba(47,70,41,.25)", borderRadius: 8 }}>
      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8 }}>
        <label style={{ display: "flex", flexDirection: "column", gap: 4, fontSize: 11, fontWeight: 700 }}>
          Latitude
          <input value={lat} onChange={(e) => setLat(e.target.value)} inputMode="decimal" style={fieldStyle(40)} />
        </label>
        <label style={{ display: "flex", flexDirection: "column", gap: 4, fontSize: 11, fontWeight: 700 }}>
          Longitude
          <input value={lng} onChange={(e) => setLng(e.target.value)} inputMode="decimal" style={fieldStyle(40)} />
        </label>
      </div>
      {error && <p role="alert" style={{ margin: 0, fontSize: 12, color: "var(--rust)" }}>{error}</p>}
      <button type="button" className="press" onClick={apply} style={{ ...buttonStyle("ghost"), minHeight: 36, fontSize: 12 }}>
        Levar o alfinete para estas coordenadas
      </button>
    </div>
  );
}
