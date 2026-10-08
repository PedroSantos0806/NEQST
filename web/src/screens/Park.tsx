import { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { parkScreen } from "../lib/api";
import { SURFACE_COLOR, eta, surfaceTextColor } from "../lib/format";
import { Badge, ErrorState, Loading } from "../components/ui";
import type { ParkScreen } from "../lib/types";

export function Park() {
  const { parkId } = useParams<{ parkId: string }>();
  const [data, setData] = useState<ParkScreen | null>(null);
  const [error, setError] = useState<Error | null>(null);

  async function load() {
    if (!parkId) return;
    setError(null);
    try {
      setData(await parkScreen(parkId));
    } catch (cause) {
      setError(cause as Error);
    }
  }

  useEffect(() => {
    void load();
    // A home do parque não precisa de tempo real: entrar numa quadra
    // leva ao court_screen, que é ao vivo. Aqui um refresh periódico
    // basta e gasta menos bateria.
    const id = setInterval(() => void load(), 20000);
    return () => clearInterval(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [parkId]);

  if (error) return <ErrorState title="Não conseguimos carregar o parque" detail={error.message} onRetry={load} />;
  if (!data) return <Loading what="Carregando quadras" />;

  return (
    <div className="screen" style={{ display: "flex", flexDirection: "column", gap: 16, padding: "22px 18px 32px" }}>
      <Link to="/" style={{ display: "inline-flex", alignItems: "center", gap: 6, fontSize: 13, fontWeight: 700, color: "var(--green)", textDecoration: "none", minHeight: 44 }}>
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
          <path d="M15 6l-6 6 6 6" />
        </svg>
        Parques
      </Link>

      <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
        <h1 className="bb" style={{ margin: 0, fontSize: 42, lineHeight: 0.92 }}>{data.park.name}</h1>
        <span style={{ fontSize: 13, fontWeight: 600, color: "var(--green)" }}>{data.park.district}</span>
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", background: "var(--green)", borderRadius: 10, color: "var(--chalk)" }}>
        <Summary value={data.summary.courts} label="Quadras" divider />
        <Summary value={data.summary.live} label="Em jogo" divider />
        <Summary value={data.summary.queued} label="Na fila" />
      </div>

      {data.my_state.state !== "free" && (
        <Link
          to={`/quadra/${data.my_state.court_id}`}
          className="press"
          style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            gap: 10,
            padding: "12px 14px",
            background: "var(--ocre)",
            border: "2px solid var(--ink)",
            borderRadius: 10,
            color: "var(--ink)",
            textDecoration: "none",
            fontSize: 14,
            fontWeight: 700,
          }}
        >
          {data.my_state.where}
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" aria-hidden="true">
            <path d="M9 6l6 6-6 6" />
          </svg>
        </Link>
      )}

      <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
        {data.courts.map((court) => (
          <Link
            key={court.court.id}
            to={`/quadra/${court.court.id}`}
            className="press"
            style={{
              display: "flex",
              flexDirection: "column",
              gap: 10,
              padding: 14,
              background: "var(--chalk)",
              border: "1px solid rgba(47,70,41,.2)",
              borderRadius: 12,
              textDecoration: "none",
              color: "var(--ink)",
            }}
          >
            <span style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10 }}>
              <span style={{ display: "flex", alignItems: "center", gap: 8 }}>
                <span className="bb" style={{ fontSize: 28, lineHeight: 1 }}>{court.court.name}</span>
                <Badge
                  background={SURFACE_COLOR[court.court.surface] ?? "var(--green)"}
                  color={surfaceTextColor(court.court.surface)}
                >
                  {court.court.surface_label}
                </Badge>
              </span>
              <Badge background={court.is_live ? "var(--ocre)" : "var(--green)"} color={court.is_live ? "var(--ink)" : "var(--chalk)"}>
                {court.is_live && <span className="dot" style={{ background: "var(--ink)" }} />}
                {court.status_text}
              </Badge>
            </span>

            <span style={{ fontSize: 13, color: "var(--muted)", lineHeight: 1.4 }}>{court.players_line}</span>

            <span style={{ display: "flex", alignItems: "center", justifyContent: "space-between", fontSize: 12, fontWeight: 700, color: "var(--green)" }}>
              <span>{court.queue_text}</span>
              <span>{court.queue_length > 0 ? `espera ~${eta(court.total_wait_seconds)}` : "livre agora"}</span>
            </span>
          </Link>
        ))}
      </div>
    </div>
  );
}

function Summary({ value, label, divider }: { value: number; label: string; divider?: boolean }) {
  return (
    <span style={{ display: "flex", flexDirection: "column", padding: "10px 12px", borderRight: divider ? "1px solid rgba(241,236,239,.2)" : undefined }}>
      <span className="bb" style={{ fontSize: 28, lineHeight: 1 }}>{String(value).padStart(2, "0")}</span>
      <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: ".08em", textTransform: "uppercase", color: "var(--mauve)" }}>{label}</span>
    </span>
  );
}
