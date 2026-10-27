import { Close } from "../icons";
import type { GeocodeHit } from "../../lib/geocode";

/**
 * Quando a busca devolve mais de um lugar, quem escolhe é o operador —
 * "Rua das Flores" existe em toda cidade do Brasil.
 */
export function AddressResults({
  hits,
  onPick,
  onClose,
}: {
  hits: GeocodeHit[];
  onPick: (hit: GeocodeHit) => void;
  onClose: () => void;
}) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 6, padding: 8, background: "var(--chalk)", border: "1.5px solid rgba(47,70,41,.25)", borderRadius: 8 }}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8 }}>
        <span style={{ fontSize: 11, fontWeight: 800, letterSpacing: ".06em", textTransform: "uppercase", color: "var(--green)" }}>
          Qual destes?
        </span>
        <button
          type="button"
          className="press"
          onClick={onClose}
          aria-label="Fechar a lista de endereços"
          style={{ display: "flex", width: 26, height: 26, alignItems: "center", justifyContent: "center", background: "transparent", border: "1.5px solid rgba(10,14,11,.2)", borderRadius: 6, color: "var(--ink)" }}
        >
          <Close size={13} />
        </button>
      </div>
      {hits.map((hit) => (
        <button
          key={`${hit.latitude},${hit.longitude}`}
          type="button"
          className="press"
          onClick={() => onPick(hit)}
          style={{ padding: "8px 10px", background: "transparent", border: "1px solid rgba(47,70,41,.2)", borderRadius: 6, fontSize: 12, lineHeight: 1.4, textAlign: "left", color: "var(--ink)" }}
        >
          {hit.label}
        </button>
      ))}
    </div>
  );
}
