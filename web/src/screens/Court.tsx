import { useState } from "react";
import { Link, useParams } from "react-router-dom";
import { useLiveCourt, useTicker } from "../hooks/useLiveCourt";
import { SURFACE_COLOR, eta, mmss, surfaceTextColor } from "../lib/format";
import { Badge, ErrorState, Loading, buttonStyle } from "../components/ui";
import { RacketStack } from "../components/Racket";
import { ScanSheet } from "./ScanSheet";
import { leaveQueue, reportResult } from "../lib/api";
import type { CourtScreen, MatchSide, QueueItem } from "../lib/types";

export function Court() {
  const { courtId } = useParams<{ courtId: string }>();
  const { data, error, loading, refresh } = useLiveCourt(courtId);
  const [sheet, setSheet] = useState<"join" | "start" | null>(null);
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);

  // Cronômetro e contagem da chamada precisam de um tick local: o
  // backend manda os segundos restantes, e o relógio corre daqui.
  useTicker(Boolean(data?.is_live || data?.my_entry?.is_called));

  if (error) return <ErrorState title="Não conseguimos carregar a quadra" detail={error.message} onRetry={refresh} />;
  if (loading || !data) return <Loading what="Carregando a quadra" />;

  const mine = data.my_entry;
  const inLiveMatch = Boolean(
    data.match?.is_live &&
      mine == null &&
      data.my_state.state === "playing" &&
      data.my_state.court_id === data.court.id,
  );

  async function onLeave() {
    if (!mine || !confirm("Sair da fila? Você perde a posição.")) return;
    setBusy(true);
    try {
      await leaveQueue(mine.entry_id);
      await refresh();
      setNotice("Você saiu da fila.");
    } catch (cause) {
      setNotice((cause as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function onReport(winner: MatchSide) {
    const match = data?.match;
    if (!match) return;
    setBusy(true);
    try {
      await reportResult(match.match_id, winner);
      await refresh();
      setNotice("Resultado registrado.");
    } catch (cause) {
      setNotice((cause as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="screen" style={{ display: "flex", flexDirection: "column", gap: 16, padding: "22px 18px 40px" }}>
      <Link
        to={`/parque/${data.park.id}`}
        style={{ display: "inline-flex", alignItems: "center", gap: 6, fontSize: 13, fontWeight: 700, color: "var(--green)", textDecoration: "none", minHeight: 44 }}
      >
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
          <path d="M15 6l-6 6 6 6" />
        </svg>
        {data.park.name}
      </Link>

      <header style={{ display: "flex", alignItems: "flex-end", justifyContent: "space-between", gap: 10 }}>
        <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
          <h1 className="bb" style={{ margin: 0, fontSize: 44, lineHeight: 0.92 }}>{data.court.name}</h1>
          <Badge
            background={SURFACE_COLOR[data.court.surface] ?? "var(--green)"}
            color={surfaceTextColor(data.court.surface)}
          >
            {data.court.surface_label}
          </Badge>
        </div>
        <Badge background={data.is_live ? "var(--ocre)" : "var(--green)"} color={data.is_live ? "var(--ink)" : "var(--chalk)"}>
          {data.is_live && <span className="dot" style={{ background: "var(--ink)" }} />}
          {data.status_text}
        </Badge>
      </header>

      <Scoreboard court={data} />

      {notice && (
        <p role="status" style={{ margin: 0, padding: "10px 12px", borderRadius: 8, fontSize: 13, background: "rgba(116,182,157,.18)", color: "var(--green)" }}>
          {notice}
        </p>
      )}

      {/* Chamada: é a vez do meu time e o relógio do check-in corre */}
      {mine?.is_called && <CallCard item={mine} onCheckIn={() => setSheet("start")} />}

      {/* Estou em quadra: só falta dizer quem ganhou */}
      {inLiveMatch && data.match && (
        <div style={{ display: "flex", flexDirection: "column", gap: 10, padding: 14, background: "var(--chalk)", border: "2px solid var(--ocre)", borderRadius: 12 }}>
          <strong style={{ fontSize: 15 }}>Acabou a partida? Diga quem ganhou</strong>
          <span style={{ fontSize: 13, color: "var(--muted)", lineHeight: 1.4 }}>
            Quem ganha fica em quadra e enfrenta o próximo da fila. Sem resposta até o fim do
            slot, a quadra é liberada para os dois.
          </span>
          <div style={{ display: "flex", gap: 8 }}>
            <button type="button" className="press" disabled={busy} onClick={() => void onReport("a")} style={buttonStyle("dark", busy)}>
              {sideLabel(data.match.side_a.players)}
            </button>
            {!data.match.side_b.open && (
              <button type="button" className="press" disabled={busy} onClick={() => void onReport("b")} style={buttonStyle("dark", busy)}>
                {sideLabel(data.match.side_b.players)}
              </button>
            )}
          </div>
        </div>
      )}

      {/* Ações principais */}
      {!mine && !inLiveMatch && (
        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          <button
            type="button"
            className="press"
            disabled={!data.can_join}
            onClick={() => setSheet("join")}
            style={buttonStyle("primary", !data.can_join)}
          >
            {data.court_accepting ? "Entrar na fila" : "Quadra indisponível"}
          </button>
          {!data.can_join && data.court_accepting && data.my_state.state !== "free" && (
            <p style={{ margin: 0, fontSize: 13, color: "var(--muted)", textAlign: "center" }}>
              {data.my_state.where}. Saia de lá para entrar aqui.
            </p>
          )}
          {data.match?.side_b.open && data.my_state.state === "queued" && data.my_state.court_id === data.court.id && (
            <button type="button" className="press" onClick={() => setSheet("start")} style={buttonStyle("ghost")}>
              Ocupar o lado livre
            </button>
          )}
        </div>
      )}

      {mine && !mine.is_called && (
        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          <div style={{ display: "flex", alignItems: "center", gap: 12, padding: 14, background: "var(--green)", color: "var(--chalk)", borderRadius: 12 }}>
            <RacketStack rackets={mine.stack} more={mine.stack_more} face="var(--ink)" />
            <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
              <span className="bb" style={{ fontSize: 34, lineHeight: 1 }}>{mine.position_label}</span>
              <span style={{ fontSize: 12, fontWeight: 700, letterSpacing: ".06em", textTransform: "uppercase", color: "var(--mauve)" }}>
                na fila · {mine.teams_ahead === 0 ? "sua vez a seguir" : `${mine.teams_ahead} na frente`}
              </span>
              <span style={{ fontSize: 13 }}>Estimativa: {eta(mine.eta_seconds)}</span>
            </div>
          </div>
          <button type="button" className="press" disabled={busy} onClick={() => void onLeave()} style={buttonStyle("danger")}>
            Sair da fila
          </button>
        </div>
      )}

      <section style={{ display: "flex", flexDirection: "column", gap: 10 }}>
        <div style={{ display: "flex", alignItems: "baseline", justifyContent: "space-between", borderBottom: "2px solid var(--green)", paddingBottom: 6 }}>
          <h2 className="bb" style={{ margin: 0, fontSize: 24, color: "var(--green)" }}>Fila</h2>
          <span style={{ fontSize: 12, fontWeight: 600, color: "var(--green)" }}>{data.queue_text}</span>
        </div>

        {data.queue.length === 0
          ? <p style={{ margin: 0, fontSize: 14, color: "var(--muted)" }}>Ninguém esperando. A quadra é sua.</p>
          : data.queue.map((item) => <QueueRow key={item.entry_id} item={item} />)}
      </section>

      {sheet && (
        <ScanSheet
          court={data}
          purpose={sheet}
          onClose={() => setSheet(null)}
          onDone={async (message) => {
            setSheet(null);
            setNotice(message);
            await refresh();
          }}
        />
      )}
    </div>
  );
}

function sideLabel(players: { short_name: string }[]): string {
  if (players.length === 0) return "Adversário livre";
  return players.map((p) => p.short_name).join(" / ");
}

function Scoreboard({ court }: { court: CourtScreen }) {
  const match = court.match;

  if (!match?.is_live) {
    return (
      <div style={{ position: "relative", padding: 16, background: "var(--chalk)", border: "1px solid rgba(47,70,41,.2)", borderRadius: 12, overflow: "hidden" }}>
        <span className="ball" aria-hidden="true" />
        <p style={{ margin: "22px 0 0", fontSize: 14, fontWeight: 600, color: "var(--muted)" }}>
          {court.players_line}
        </p>
      </div>
    );
  }

  // started_at e expires_at são absolutos: contamos a partir deles, em
  // vez de somar os segundos que o servidor calculou no momento do
  // fetch — isso derrapava a cada atualização.
  const now = Date.now();
  const elapsed = Math.max(0, Math.floor((now - new Date(match.started_at).getTime()) / 1000));
  const remaining = Math.max(0, Math.floor((new Date(match.expires_at).getTime() - now) / 1000));

  return (
    <div
      style={{
        position: "relative",
        display: "flex",
        flexDirection: "column",
        gap: 12,
        padding: 16,
        background: SURFACE_COLOR[court.court.surface] ?? "var(--green)",
        color: surfaceTextColor(court.court.surface),
        borderRadius: 12,
        overflow: "hidden",
      }}
    >
      <span className="ball rally" aria-hidden="true" />

      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginTop: 18 }}>
        <span style={{ fontSize: 11, fontWeight: 700, letterSpacing: ".08em", textTransform: "uppercase", opacity: 0.85 }}>
          {match.mode === "double" ? "Duplas (2x2)" : "Simples (1x1)"}
        </span>
        <span style={{ fontSize: 11, fontWeight: 700, letterSpacing: ".08em", textTransform: "uppercase", opacity: 0.85 }}>
          slot de {match.slot_minutes} min
        </span>
      </div>

      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10 }}>
        <SideBlock title="Desafiante" players={match.side_a.players} />
        <span className="bb" style={{ fontSize: 22, opacity: 0.7 }}>×</span>
        <SideBlock title="Mandante" players={match.side_b.players} open={match.side_b.open} align="right" />
      </div>

      <div style={{ display: "flex", alignItems: "baseline", justifyContent: "space-between" }}>
        <span className="bb" style={{ fontSize: 40, lineHeight: 1 }}>{mmss(elapsed)}</span>
        <span style={{ fontSize: 13, fontWeight: 700 }}>
          {remaining > 0 ? `faltam ~${Math.ceil(remaining / 60)} min` : "slot encerrado"}
        </span>
      </div>
    </div>
  );
}

function SideBlock({
  title,
  players,
  open,
  align = "left",
}: {
  title: string;
  players: { short_name: string; initials: string }[];
  open?: boolean;
  align?: "left" | "right";
}) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 2, alignItems: align === "right" ? "flex-end" : "flex-start", flex: 1 }}>
      <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: ".1em", textTransform: "uppercase", opacity: 0.75 }}>
        {title}
      </span>
      {open
        ? <span style={{ fontSize: 15, fontWeight: 700, opacity: 0.8 }}>Adversário livre</span>
        : players.map((player) => (
          <span key={player.short_name} style={{ fontSize: 15, fontWeight: 700 }}>{player.short_name}</span>
        ))}
    </div>
  );
}

function CallCard({ item, onCheckIn }: { item: QueueItem; onCheckIn: () => void }) {
  const left = item.call_expires_at
    ? Math.max(0, Math.floor((new Date(item.call_expires_at).getTime() - Date.now()) / 1000))
    : 0;

  return (
    <div
      style={{
        position: "relative",
        display: "flex",
        flexDirection: "column",
        gap: 10,
        padding: 16,
        background: "var(--ink)",
        color: "var(--chalk)",
        borderRadius: 14,
      }}
    >
      <span className="ring" aria-hidden="true" />
      <strong className="bb" style={{ fontSize: 32, lineHeight: 1, color: "var(--ocre)" }}>É a sua vez!</strong>
      <span style={{ fontSize: 14, lineHeight: 1.45 }}>
        Faça o check-in na quadra para liberar o placar. Se o tempo acabar, a vez passa para o
        próximo time.
      </span>
      <span className="bb" style={{ fontSize: 36, lineHeight: 1, color: left <= 60 ? "var(--rust)" : "var(--chalk)" }}>
        {mmss(left)}
      </span>
      <button type="button" className="press" onClick={onCheckIn} style={buttonStyle("primary")}>
        Fazer check-in
      </button>
    </div>
  );
}

function QueueRow({ item }: { item: QueueItem }) {
  return (
    <div
      className={item.is_mine ? "flash" : undefined}
      style={{
        display: "flex",
        alignItems: "center",
        gap: 12,
        padding: "10px 12px",
        borderRadius: 12,
        background: item.is_mine ? "var(--green)" : "var(--chalk)",
        color: item.is_mine ? "var(--chalk)" : "var(--ink)",
        border: item.is_mine ? "2px solid var(--ocre)" : "1px solid rgba(47,70,41,.18)",
      }}
    >
      <RacketStack
        rackets={item.stack}
        more={item.stack_more}
        face={item.is_mine ? "var(--ink)" : "var(--green)"}
        label={`Pilha com ${item.stack.length} raquete(s)${item.stack_more ? `, mais ${item.stack_more} antes` : ""}`}
      />
      <div style={{ display: "flex", flexDirection: "column", gap: 2, flex: 1, minWidth: 0 }}>
        <span style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
          <span className="bb" style={{ fontSize: 24, lineHeight: 1 }}>{item.position_label}</span>
          <span style={{ fontSize: 14, fontWeight: 700, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
            {item.team_label ?? "Time"}
          </span>
        </span>
        <span style={{ fontSize: 12, opacity: 0.85 }}>{item.mode_label}</span>
        <span style={{ fontSize: 12, fontWeight: 700 }}>
          {item.is_called ? "chamado — check-in pendente" : `entra em ~${eta(item.eta_seconds)}`}
        </span>
      </div>
    </div>
  );
}
