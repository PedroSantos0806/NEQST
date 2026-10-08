import { useEffect, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { parkScreen } from "../lib/api";
import { SURFACE_COLOR, firstName, greeting, initialsOf, mmss, surfaceTextColor } from "../lib/format";
import { toneStyle } from "../lib/me";
import { rememberCourt, rememberPark } from "../lib/nav";
import { ErrorState, Loading } from "../components/ui";
import { BottomNav } from "../components/BottomNav";
import { ChevronRight, Pin, RacketIcon, SurfaceIcon } from "../components/icons";
import { useMe } from "../hooks/useMe";
import { useTicker } from "../hooks/useLiveCourt";
import type { CourtScreen, ParkScreen } from "../lib/types";

export function Park() {
  const { parkId } = useParams<{ parkId: string }>();
  const navigate = useNavigate();
  const profile = useMe();
  const [data, setData] = useState<ParkScreen | null>(null);
  const [error, setError] = useState<Error | null>(null);

  // Os cronômetros dos cartões correm aqui; os dados chegam de 20 em
  // 20 segundos. Dentro da quadra é que o Realtime entra.
  useTicker(true);

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
    const id = setInterval(() => void load(), 20000);
    return () => clearInterval(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [parkId]);

  useEffect(() => {
    if (!data) return;
    rememberPark(data.park.id);
    const first = data.courts[0];
    if (first) rememberCourt(data.park.id, first.court.id);
  }, [data]);

  if (error) return <ErrorState title="Não conseguimos carregar o parque" detail={error.message} onRetry={load} />;
  if (!data) return <Loading what="Carregando quadras" />;

  const name = profile?.profile?.full_name ?? profile?.profile?.username;
  const avatar = toneStyle(profile?.profile?.avatar_tone);
  const joined = data.my_state.state !== "free" ? data.my_state : null;

  return (
    <>
      <div className="screen" style={{ display: "flex", flexDirection: "column", gap: 18, padding: "22px 18px 28px" }}>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <span className="script" style={{ fontSize: 38, lineHeight: 1, color: "var(--green)" }}>Neqst</span>
            <span style={{ width: 10, height: 10, borderRadius: "50%", background: "var(--ocre)", border: "1.5px solid var(--green)" }} />
          </div>
          <button
            type="button"
            className="press"
            onClick={() => navigate("/perfil")}
            aria-label="Abrir perfil"
            style={{ width: 44, height: 44, borderRadius: 10, border: "2px solid var(--green)", fontSize: 15, fontWeight: 700, ...avatar }}
          >
            {initialsOf(name)}
          </button>
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
          <div style={{ fontSize: 14, fontWeight: 500, color: "var(--green)" }}>
            {greeting()}, {firstName(name)}
          </div>
          <h1 className="bb" style={{ margin: 0, fontSize: 46, lineHeight: 0.92 }}>Escolha sua quadra</h1>
          <button
            type="button"
            className="press"
            onClick={() => navigate("/")}
            aria-label="Trocar de parque"
            style={{ alignSelf: "flex-start", display: "flex", alignItems: "center", gap: 8, minHeight: 44, padding: "0 14px", background: "transparent", border: "1.5px solid var(--green)", borderRadius: 10, color: "var(--green)", fontSize: 14, fontWeight: 600 }}
          >
            <Pin size={18} />
            <span>{data.park.name}</span>
            <span style={{ fontSize: 12, fontWeight: 500 }}>· trocar parque</span>
          </button>
        </div>

        <div style={{ display: "grid", gridTemplateColumns: "repeat(3, minmax(0, 1fr))", background: "var(--green)", borderRadius: 12, overflow: "hidden" }}>
          <Summary value={data.summary.courts} label="Quadras" divider />
          <Summary value={data.summary.live} label="Em jogo" divider />
          <Summary value={data.summary.queued} label="Na fila" />
        </div>

        {joined?.court_id && (
          <button
            type="button"
            className="press"
            onClick={() => navigate(`/quadra/${joined.court_id}`)}
            style={{ display: "flex", alignItems: "center", gap: 12, width: "100%", textAlign: "left", padding: "12px 14px", background: "var(--ink)", color: "var(--chalk)", border: 0, borderRadius: 12 }}
          >
            <span className="bb" style={{ display: "flex", alignItems: "center", justifyContent: "center", minWidth: 48, height: 48, background: "var(--ocre)", color: "var(--ink)", borderRadius: 8, fontSize: 28, lineHeight: 1 }}>
              {positionOf(data, joined.court_id) ?? "•"}
            </span>
            <span style={{ display: "flex", flexDirection: "column", gap: 2, flexGrow: 1 }}>
              <span style={{ fontSize: 11, fontWeight: 700, letterSpacing: ".1em", textTransform: "uppercase", color: "var(--sage)" }}>
                {joined.state === "playing" ? "Você está em quadra" : "Você está na fila"}
              </span>
              <span style={{ fontSize: 14, fontWeight: 600 }}>{joined.where}</span>
            </span>
            <ChevronRight size={20} />
          </button>
        )}

        <div style={{ display: "flex", alignItems: "baseline", justifyContent: "space-between", borderBottom: "2px solid var(--green)", paddingBottom: 6 }}>
          <h2 className="bb" style={{ margin: 0, fontSize: 26, color: "var(--green)" }}>Quadras</h2>
          <span style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12, fontWeight: 600, color: "var(--green)" }}>
            <span className="dot" style={{ background: "var(--rust)" }} />Ao vivo
          </span>
        </div>

        <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
          {data.courts.map((court) => (
            <CourtCard
              key={court.court.id}
              court={court}
              onOpen={() => navigate(`/quadra/${court.court.id}`)}
            />
          ))}
          {data.courts.length === 0 && (
            <p style={{ margin: 0, fontSize: 14, color: "var(--muted)" }}>
              Este parque ainda não tem quadras cadastradas.
            </p>
          )}
        </div>
      </div>

      <BottomNav parkId={data.park.id} tab="home" courtId={data.courts[0]?.court.id} />
    </>
  );
}

/** A posição do jogador na fila, se ele estiver numa das quadras daqui. */
function positionOf(data: ParkScreen, courtId: string): string | null {
  const court = data.courts.find((item) => item.court.id === courtId);
  return court?.my_entry?.position_label ?? null;
}

function CourtCard({ court, onOpen }: { court: CourtScreen; onOpen: () => void }) {
  const surface = court.court.surface;
  const color = SURFACE_COLOR[surface] ?? "var(--green)";
  const live = Boolean(court.match?.is_live);
  const elapsed = live && court.match
    ? Math.max(0, Math.floor((Date.now() - new Date(court.match.started_at).getTime()) / 1000))
    : 0;

  return (
    <button
      type="button"
      className="press"
      onClick={onOpen}
      style={{
        display: "flex",
        flexDirection: "column",
        gap: 12,
        width: "100%",
        textAlign: "left",
        padding: 14,
        background: "var(--chalk)",
        border: "1px solid rgba(47,70,41,.18)",
        borderRadius: 12,
        color: "var(--ink)",
      }}
    >
      <span style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8, width: "100%" }}>
        <span className="bb" style={{ fontSize: 27, lineHeight: 1 }}>
          {court.court.name} <span style={{ color: "#7A6339" }}>— {court.court.surface_label}</span>
        </span>
        <span style={{ display: "flex", alignItems: "center", gap: 5, padding: "5px 8px", borderRadius: 6, fontSize: 11, fontWeight: 700, letterSpacing: ".06em", textTransform: "uppercase", background: color, color: surfaceTextColor(surface) }}>
          <SurfaceIcon surface={surface} />
          {court.court.surface_label}
        </span>
      </span>

      <span style={{ display: "flex", alignItems: "stretch", gap: 10, width: "100%" }}>
        <span style={{ display: "flex", flexDirection: "column", justifyContent: "center", gap: 2, minWidth: 128, padding: "8px 12px", background: "var(--green)", borderRadius: 8, color: "var(--chalk)" }}>
          <span style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 10, fontWeight: 700, letterSpacing: ".1em", textTransform: "uppercase", color: live ? "var(--ocre)" : "var(--chalk)" }}>
            {live && <span className="dot" style={{ background: "var(--ocre)" }} />}
            {court.status_text}
          </span>
          <span className="bb" style={{ fontSize: 32, lineHeight: 1 }}>{mmss(elapsed)}</span>
        </span>

        <span style={{ display: "flex", flexDirection: "column", justifyContent: "center", gap: 4, flexGrow: 1, minWidth: 0 }}>
          <span style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 14, fontWeight: 700 }}>
            <RacketIcon size={16} />
            {court.queue_text}
          </span>
          <span style={{ fontSize: 12, color: "var(--green)", lineHeight: 1.3 }}>{court.players_line}</span>
        </span>
      </span>

      <span style={{ display: "flex", alignItems: "center", justifyContent: "space-between", width: "100%", paddingTop: 10, borderTop: "1px dashed rgba(47,70,41,.3)", fontSize: 12, fontWeight: 600, color: "var(--green)" }}>
        <span>
          {live
            ? court.match?.mode === "double" ? "Duplas (2x2) em quadra" : "Simples (1x1) em quadra"
            : "Quadra livre"}
        </span>
        <span style={{ display: "flex", alignItems: "center", gap: 4, flexShrink: 0 }}>
          Ver placar e fila
          <ChevronRight size={16} />
        </span>
      </span>
    </button>
  );
}

function Summary({ value, label, divider }: { value: number; label: string; divider?: boolean }) {
  return (
    <div style={{ padding: "12px 14px", borderRight: divider ? "1px solid rgba(241,236,239,.2)" : undefined }}>
      <div className="bb" style={{ fontSize: 34, lineHeight: 1, color: "var(--chalk)" }}>
        {String(value).padStart(2, "0")}
      </div>
      <div style={{ fontSize: 11, fontWeight: 600, letterSpacing: ".08em", textTransform: "uppercase", color: "var(--mauve)" }}>
        {label}
      </div>
    </div>
  );
}
