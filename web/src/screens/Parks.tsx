import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { parksOverview } from "../lib/api";
import { getPosition } from "../lib/geo";
import { Badge, ErrorState, Loading } from "../components/ui";
import { distance, firstName, greeting, SURFACE_COLOR, surfaceTextColor } from "../lib/format";
import type { ParkCard } from "../lib/types";
import { useAuth } from "../hooks/useAuth";

export function Parks() {
  const { session } = useAuth();
  const [parks, setParks] = useState<ParkCard[] | null>(null);
  const [error, setError] = useState<Error | null>(null);

  async function load() {
    setError(null);
    try {
      // A localização é um plus para ordenar por distância: sem ela o
      // app abre do mesmo jeito, com todos os parques.
      const coords = await getPosition(6000).catch(() => null);
      setParks(await parksOverview(coords));
    } catch (cause) {
      setError(cause as Error);
    }
  }

  useEffect(() => {
    void load();
  }, []);

  const name = (session?.user.user_metadata?.full_name as string | undefined) ??
    session?.user.email?.split("@")[0];

  if (error) {
    return <ErrorState title="Não conseguimos carregar os parques" detail={error.message} onRetry={load} />;
  }
  if (!parks) return <Loading what="Procurando parques perto de você" />;

  return (
    <div className="screen" style={{ display: "flex", flexDirection: "column", gap: 18, padding: "26px 18px 32px" }}>
      <header style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
          <span className="script" style={{ fontSize: 40, lineHeight: 1, color: "var(--green)" }}>Neqst</span>
          <span
            style={{
              width: 10,
              height: 10,
              borderRadius: "50%",
              background: "var(--ocre)",
              border: "1.5px solid var(--green)",
            }}
          />
        </div>
        <Link to="/perfil" style={{ fontSize: 12, fontWeight: 700, color: "var(--green)" }}>
          Meu perfil
        </Link>
      </header>

      <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        <div style={{ fontSize: 14, fontWeight: 500, color: "var(--green)" }}>
          {greeting()}, {firstName(name)}
        </div>
        <h1 className="bb" style={{ margin: 0, fontSize: 50, lineHeight: 0.9 }}>
          Onde você vai jogar hoje?
        </h1>
        <p style={{ margin: 0, fontSize: 14, lineHeight: 1.45, color: "var(--green)" }}>
          Escolha o parque para ver as quadras, o placar e a fila ao vivo.
        </p>
      </div>

      <div
        style={{
          display: "flex",
          alignItems: "baseline",
          justifyContent: "space-between",
          borderBottom: "2px solid var(--green)",
          paddingBottom: 6,
        }}
      >
        <h2 className="bb" style={{ margin: 0, fontSize: 26, color: "var(--green)" }}>Parques</h2>
        <span style={{ fontSize: 12, fontWeight: 600, color: "var(--green)" }}>
          {parks.length} com NEQST
        </span>
      </div>

      {parks.length === 0 && (
        <p style={{ margin: 0, fontSize: 14, color: "var(--muted)" }}>
          Nenhum parque cadastrado ainda.
        </p>
      )}

      <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
        {parks.map((park) => <ParkRow key={park.park_id} park={park} />)}
      </div>
    </div>
  );
}

function ParkRow({ park }: { park: ParkCard }) {
  const far = distance(park.distance_meters);

  return (
    <Link
      to={`/parque/${park.park_id}`}
      className="press"
      style={{
        display: "flex",
        flexDirection: "column",
        width: "100%",
        textDecoration: "none",
        background: "var(--chalk)",
        border: park.is_mine ? "2px solid var(--ocre)" : "1px solid rgba(47,70,41,.2)",
        borderRadius: 12,
        overflow: "hidden",
        color: "var(--ink)",
      }}
    >
      <span
        style={{
          position: "relative",
          display: "block",
          width: "100%",
          height: 150,
          background: park.tone_color ?? "var(--green)",
        }}
      >
        {park.photo_url
          ? (
            <img
              src={park.photo_url}
              alt={`${park.name} — ${park.photo_alt ?? "quadra"}`}
              style={{ display: "block", width: "100%", height: 150, objectFit: "cover" }}
            />
          )
          : (
            <span
              style={{
                position: "absolute",
                inset: 14,
                display: "flex",
                flexDirection: "column",
                alignItems: "center",
                justifyContent: "center",
                gap: 6,
                border: "1.5px solid rgba(241,236,239,.45)",
                borderRadius: 6,
                color: "var(--chalk)",
              }}
            >
              <span style={{ position: "absolute", left: "50%", top: 0, bottom: 0, width: 1.5, background: "rgba(241,236,239,.25)" }} />
              <svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round" aria-hidden="true" style={{ position: "relative" }}>
                <path d="M4 8h3l2-3h6l2 3h3v11H4z" />
                <circle cx="12" cy="13" r="3.5" />
              </svg>
            </span>
          )}

        <span style={{ position: "absolute", left: 10, top: 10 }}>
          <Badge background="var(--ink)" color="var(--chalk)">
            {park.any_live && <span className="dot" style={{ background: "var(--ocre)" }} />}
            {park.live_text}
          </Badge>
        </span>

        {park.is_mine && (
          <span style={{ position: "absolute", right: 10, top: 10 }}>
            <Badge background="var(--ocre)" color="var(--ink)">Você está aqui</Badge>
          </span>
        )}
      </span>

      <span style={{ display: "flex", flexDirection: "column", gap: 10, width: "100%", padding: "12px 14px 14px" }}>
        <span style={{ display: "flex", alignItems: "flex-end", justifyContent: "space-between", gap: 10 }}>
          <span style={{ display: "flex", flexDirection: "column", gap: 2 }}>
            <span className="bb" style={{ fontSize: 30, lineHeight: 0.95 }}>{park.name}</span>
            <span style={{ display: "flex", alignItems: "center", gap: 5, fontSize: 12, fontWeight: 600, color: "var(--green)" }}>
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                <path d="M12 21s-7-6.5-7-12a7 7 0 0 1 14 0c0 5.5-7 12-7 12z" />
                <circle cx="12" cy="9" r="2.5" />
              </svg>
              {park.district ?? "—"}{far ? ` · ${far}` : ""}
            </span>
          </span>
          <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="var(--green)" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
            <path d="M9 6l6 6-6 6" />
          </svg>
        </span>

        <span
          style={{
            display: "grid",
            gridTemplateColumns: "repeat(3, minmax(0, 1fr))",
            background: "var(--green)",
            borderRadius: 8,
            color: "var(--chalk)",
          }}
        >
          <Stat value={park.courts_count} label="Quadras" divider />
          <Stat value={park.live_count} label="Em jogo" divider />
          <Stat value={park.queue_count} label="Na fila" />
        </span>

        {park.surfaces.length > 0 && (
          <span style={{ display: "flex", gap: 6, flexWrap: "wrap" }}>
            {park.surfaces.map((surface) => (
              <Badge
                key={surface.surface}
                background={SURFACE_COLOR[surface.surface] ?? "var(--green)"}
                color={surfaceTextColor(surface.surface)}
              >
                {surface.label}
              </Badge>
            ))}
          </span>
        )}
      </span>
    </Link>
  );
}

function Stat({ value, label, divider }: { value: number; label: string; divider?: boolean }) {
  return (
    <span
      style={{
        display: "flex",
        flexDirection: "column",
        padding: "8px 10px",
        borderRight: divider ? "1px solid rgba(241,236,239,.2)" : undefined,
      }}
    >
      <span className="bb" style={{ fontSize: 26, lineHeight: 1 }}>
        {String(value).padStart(2, "0")}
      </span>
      <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: ".08em", textTransform: "uppercase", color: "var(--mauve)" }}>
        {label}
      </span>
    </span>
  );
}
