import { useEffect, useRef, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { useLiveCourt, useTicker } from "../hooks/useLiveCourt";
import { SURFACE_COLOR, eta, hhmm, mmss, surfaceTextColor } from "../lib/format";
import { rememberCourt, rememberPark } from "../lib/nav";
import { ErrorState, Loading } from "../components/ui";
import { RacketStack } from "../components/Racket";
import { BottomNav } from "../components/BottomNav";
import { CallOverlay, StartedOverlay, SuccessOverlay } from "../components/Overlays";
import { ChevronLeft, Check, Clock, Players, ScanFrame, SurfaceIcon, Warn } from "../components/icons";
import { ScanOverlay } from "./ScanOverlay";
import { JoinSheet } from "./JoinSheet";
import { checkIn, leaveQueue, reportResult } from "../lib/api";
import type { CourtScreen, MatchSide, Player, QueueItem, ScanResult } from "../lib/types";

type Flow =
  | { kind: "none" }
  | { kind: "scan"; purpose: "join" | "start" }
  | { kind: "join"; scan: ScanResult; method: "qr" | "nfc" }
  | { kind: "success"; item: QueueItem }
  | { kind: "started" }
  | { kind: "call" };

export function Court() {
  const { courtId } = useParams<{ courtId: string }>();
  const navigate = useNavigate();
  const { data, error, loading, refresh } = useLiveCourt(courtId);
  const [flow, setFlow] = useState<Flow>({ kind: "none" });
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [ending, setEnding] = useState(false);
  const calledFor = useRef<string | null>(null);
  const timers = useRef<number[]>([]);

  useTicker(Boolean(data?.is_live || data?.my_entry?.is_called));

  // A barra inferior precisa saber onde o jogador está.
  useEffect(() => {
    if (data) {
      rememberPark(data.park.id);
      rememberCourt(data.park.id, data.court.id);
    }
  }, [data]);

  // Chamaram o nosso time: a tela cheia do protótipo aparece uma vez
  // por chamada — depois dela o cartão na própria quadra basta.
  useEffect(() => {
    const entry = data?.my_entry;
    if (!entry?.is_called) return;
    if (calledFor.current === entry.entry_id) return;
    calledFor.current = entry.entry_id;
    setFlow({ kind: "call" });
  }, [data]);

  useEffect(() => () => timers.current.forEach(clearTimeout), []);

  function later(fn: () => void, ms: number) {
    timers.current.push(window.setTimeout(fn, ms));
  }

  if (error) return <ErrorState title="Não conseguimos carregar a quadra" detail={error.message} onRetry={refresh} />;
  if (loading || !data) return <Loading what="Carregando a quadra" />;

  const court = data.court;
  const match = data.match;
  const live = Boolean(match?.is_live);
  const mine = data.my_entry;
  const board = SURFACE_COLOR[court.surface] ?? "var(--green)";
  const boardText = surfaceTextColor(court.surface);

  const now = Date.now();
  const elapsed = live && match
    ? Math.max(0, Math.floor((now - new Date(match.started_at).getTime()) / 1000))
    : 0;
  const remaining = live && match
    ? Math.max(0, Math.floor((new Date(match.expires_at).getTime() - now) / 1000))
    : 0;

  const playingHere = Boolean(
    live && !mine && data.my_state.state === "playing" && data.my_state.court_id === court.id,
  );
  const nextUpHere = Boolean(mine && !mine.is_called && mine.position === 1 && live);
  const joinedElsewhere = Boolean(
    !mine && data.my_state.state === "queued" && data.my_state.court_id !== court.id,
  );

  async function onLeave() {
    if (!mine || !confirm("Sair da fila? Você perde a posição.")) return;
    setBusy(true);
    try {
      await leaveQueue(mine.entry_id);
      calledFor.current = null;
      await refresh();
      setNotice("Você saiu da fila.");
    } catch (cause) {
      setNotice((cause as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function onReport(winner: MatchSide) {
    if (!match) return;
    setBusy(true);
    try {
      await reportResult(match.match_id, winner);
      setEnding(false);
      await refresh();
      setNotice("Resultado registrado. Quem ganhou fica em quadra.");
    } catch (cause) {
      setNotice((cause as Error).message);
    } finally {
      setBusy(false);
    }
  }

  // Leitura válida: ou abre a folha da fila, ou faz o check-in e começa.
  async function onRead(result: ScanResult, method: "qr" | "nfc") {
    if (result.purpose === "join") {
      setFlow({ kind: "join", scan: result, method });
      return;
    }
    try {
      await checkIn(result.scanToken, data?.match?.side_b.open ? "open" : "auto");
      calledFor.current = null;
      setFlow({ kind: "started" });
      later(() => setFlow({ kind: "none" }), 2600);
      await refresh();
    } catch (cause) {
      setNotice((cause as Error).message);
      setFlow({ kind: "none" });
    }
  }

  return (
    <>
      <div className="screen" style={{ display: "flex", flexDirection: "column", gap: 16, padding: "14px 16px 28px" }}>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
          <button
            type="button"
            className="press"
            onClick={() => navigate(`/parque/${data.park.id}`)}
            style={{ display: "flex", alignItems: "center", gap: 4, minHeight: 44, padding: "0 10px 0 4px", background: "transparent", border: 0, color: "var(--green)", fontSize: 14, fontWeight: 600 }}
          >
            <ChevronLeft size={20} />
            Quadras
          </button>
          <span style={{ fontSize: 12, fontWeight: 600, color: "var(--green)" }}>{data.park.name}</span>
        </div>

        {/* ---------------------------- placar ---------------------------- */}
        <div style={{ position: "relative", padding: "14px 14px 16px", borderRadius: 12, background: board, color: boardText }}>
          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10 }}>
            <div style={{ display: "flex", flexDirection: "column", gap: 2 }}>
              <span className="bb" style={{ fontSize: 30, lineHeight: 1 }}>{court.name}</span>
              <span style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 11, fontWeight: 700, letterSpacing: ".1em", textTransform: "uppercase" }}>
                <SurfaceIcon surface={court.surface} />
                Piso {court.surface_label}
              </span>
            </div>
            {live
              ? (
                <span style={{ display: "flex", alignItems: "center", gap: 6, padding: "6px 10px", background: "var(--ocre)", color: "var(--ink)", borderRadius: 6, fontSize: 11, fontWeight: 800, letterSpacing: ".1em" }}>
                  <span className="dot" />AO VIVO
                </span>
              )
              : (
                <span style={{ display: "flex", alignItems: "center", gap: 6, padding: "5px 9px", border: "1.5px solid currentColor", borderRadius: 6, fontSize: 11, fontWeight: 800, letterSpacing: ".1em" }}>
                  <Check size={12} />QUADRA LIVRE
                </span>
              )}
          </div>

          <div style={{ position: "relative", height: 28, marginTop: 10, borderBottom: "2px solid rgba(255,255,255,.6)" }} aria-hidden="true">
            <span className={live ? "ball rally" : "ball"} />
          </div>

          <div style={{ display: "flex", flexDirection: "column", alignItems: "center", padding: "10px 0 12px" }}>
            <span className="bb" role="timer" aria-live="off" style={{ fontSize: 104, lineHeight: 0.86, letterSpacing: ".03em" }}>
              {mmss(elapsed)}
            </span>
            <span style={{ fontSize: 11, fontWeight: 700, letterSpacing: ".12em", textTransform: "uppercase", opacity: 0.92 }}>
              {live ? `Tempo de jogo · slot de ${court.slot_minutes} min` : "Aguardando check-in"}
            </span>
          </div>

          <div style={{ display: "grid", gridTemplateColumns: "repeat(2, minmax(0, 1fr))", border: "2px solid rgba(255,255,255,.75)", borderRadius: 6, minHeight: 92 }}>
            <Side players={match?.side_a.players ?? []} divider />
            <Side
              players={match?.side_b.players ?? []}
              empty={!live ? "Sem jogo em andamento" : match?.side_b.open ? "Lado livre — entre nele" : undefined}
            />
          </div>

          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginTop: 12 }}>
            <span style={{ display: "flex", alignItems: "center", gap: 6, padding: "5px 9px", background: "rgba(10,14,11,.28)", borderRadius: 6, fontSize: 12, fontWeight: 700 }}>
              <Players size={14} />
              {live
                ? match?.mode === "double" ? "Duplas (2x2)" : "Jogo Simples (1x1)"
                : "Sem modalidade"}
            </span>
            <span style={{ fontSize: 12, fontWeight: 600 }}>
              {live ? `Faltam ~${Math.max(1, Math.ceil(remaining / 60))} min` : "Pronta para jogar"}
            </span>
          </div>
        </div>

        {notice && (
          <p role="status" style={{ margin: 0, padding: "10px 12px", borderRadius: 8, fontSize: 13, background: "rgba(116,182,157,.18)", color: "var(--green)" }}>
            {notice}
          </p>
        )}

        {/* ----------------------------- ações ----------------------------- */}
        {playingHere && match && (
          <div style={{ display: "flex", flexDirection: "column", gap: 10, padding: 12, background: "var(--ink)", color: "var(--chalk)", borderRadius: 10 }}>
            <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10 }}>
              <span style={{ display: "flex", flexDirection: "column", gap: 2 }}>
                <span style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 11, fontWeight: 800, letterSpacing: ".1em", color: "var(--sage)" }}>
                  <span className="dot" style={{ background: "var(--sage)" }} />VOCÊ ESTÁ EM QUADRA
                </span>
                <span style={{ fontSize: 14, fontWeight: 600 }}>Bom jogo! O placar é seu.</span>
              </span>
              <button
                type="button"
                className="press"
                onClick={() => setEnding((value) => !value)}
                style={{ minHeight: 44, padding: "0 12px", background: "transparent", color: "var(--chalk)", border: "1.5px solid rgba(241,236,239,.6)", borderRadius: 8, fontSize: 13, fontWeight: 700 }}
              >
                Encerrar partida
              </button>
            </div>

            {ending && (
              <div className="fade" style={{ display: "flex", flexDirection: "column", gap: 8, paddingTop: 10, borderTop: "1px dashed rgba(241,236,239,.3)" }}>
                <span style={{ fontSize: 13, lineHeight: 1.4 }}>
                  Quem ganhou? Quem ganha fica em quadra e enfrenta o próximo da fila.
                </span>
                <div style={{ display: "flex", gap: 8 }}>
                  <WinnerButton
                    disabled={busy}
                    onClick={() => void onReport("a")}
                    label={sideLabel(match.side_a.players)}
                  />
                  {!match.side_b.open && (
                    <WinnerButton
                      disabled={busy}
                      onClick={() => void onReport("b")}
                      label={sideLabel(match.side_b.players)}
                    />
                  )}
                </div>
              </div>
            )}
          </div>
        )}

        {mine?.is_called && (
          <div className="flash" style={{ display: "flex", flexDirection: "column", gap: 12, padding: 14, background: "var(--green)", color: "var(--chalk)", border: "2px solid var(--ocre)", borderRadius: 12 }}>
            <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10 }}>
              <span style={{ display: "flex", flexDirection: "column", gap: 2 }}>
                <span style={{ fontSize: 11, fontWeight: 800, letterSpacing: ".1em", color: "var(--ocre)" }}>
                  SUA VEZ · QUADRA LIBERADA
                </span>
                <span className="bb" style={{ fontSize: 30, lineHeight: 1 }}>Faça check-in para jogar</span>
              </span>
              <span style={{ display: "flex", flexDirection: "column", alignItems: "flex-end" }}>
                <span className="bb" role="timer" style={{ fontSize: 34, lineHeight: 1 }}>{mmss(callLeft(mine))}</span>
                <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: ".08em", color: "var(--mauve)" }}>PARA CONFIRMAR</span>
              </span>
            </div>
            <button
              type="button"
              className="press"
              onClick={() => setFlow({ kind: "scan", purpose: "start" })}
              style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 10, width: "100%", minHeight: 56, background: "var(--ocre)", color: "var(--ink)", border: "2px solid var(--ink)", borderRadius: 10, fontSize: 16, fontWeight: 800 }}
            >
              <ScanFrame size={20} />
              Check-in QR / NFC e iniciar jogo
            </button>
          </div>
        )}

        {nextUpHere && (
          <div style={{ display: "flex", alignItems: "center", gap: 10, padding: 12, background: "var(--chalk)", border: "1.5px solid var(--green)", borderRadius: 10 }}>
            <span className="bb" style={{ display: "flex", alignItems: "center", justifyContent: "center", minWidth: 44, height: 44, background: "var(--ocre)", color: "var(--ink)", borderRadius: 8, fontSize: 24 }}>
              1º
            </span>
            <span style={{ display: "flex", flexDirection: "column", gap: 2, fontSize: 13, lineHeight: 1.35 }}>
              <strong style={{ fontSize: 14 }}>Você é o próximo</strong>
              Faltam ~{Math.max(1, Math.ceil(remaining / 60))} min para acabar a partida atual.
              Avisamos quando a quadra liberar para o check-in.
            </span>
          </div>
        )}

        {!mine && !playingHere && data.can_join && (
          <button
            type="button"
            className="press"
            onClick={() => setFlow({ kind: "scan", purpose: "join" })}
            style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 10, width: "100%", minHeight: 56, background: "var(--ocre)", color: "var(--ink)", border: "2px solid var(--ink)", borderRadius: 10, fontSize: 16, fontWeight: 800 }}
          >
            <ScanFrame size={20} />
            Entrar na Fila
          </button>
        )}

        {!mine && !playingHere && !data.can_join && !joinedElsewhere && !data.court_accepting && (
          <div style={{ padding: 12, background: "var(--chalk)", border: "1.5px dashed rgba(47,70,41,.4)", borderRadius: 10, fontSize: 13, color: "var(--green)", textAlign: "center" }}>
            Esta quadra não está aceitando fila agora.
          </div>
        )}

        {mine && !mine.is_called && (
          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10, padding: "10px 12px", background: "var(--green)", color: "var(--chalk)", borderRadius: 10 }}>
            <span style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 14, fontWeight: 600 }}>
              <span style={{ color: "var(--sage)", display: "flex" }}><Check size={18} strokeWidth="2.6" /></span>
              Você é o {mine.position_label} da fila
            </span>
            <button
              type="button"
              className="press"
              disabled={busy}
              onClick={() => void onLeave()}
              style={{ minHeight: 40, padding: "0 12px", background: "transparent", color: "var(--chalk)", border: "1.5px solid rgba(241,236,239,.6)", borderRadius: 8, fontSize: 13, fontWeight: 600 }}
            >
              Sair da fila
            </button>
          </div>
        )}

        {joinedElsewhere && (
          <div style={{ display: "flex", alignItems: "flex-start", gap: 10, padding: 12, background: "var(--chalk)", border: "1.5px solid var(--rust)", borderRadius: 10, fontSize: 13, lineHeight: 1.4 }}>
            <span style={{ color: "var(--rust)", flexShrink: 0, display: "flex" }}><Warn size={20} /></span>
            <span>
              <strong>Você já está na fila da {data.my_state.court_name}.</strong> Saia de lá para
              entrar nesta — uma fila por vez.
            </span>
          </div>
        )}

        {/* ------------------------------ fila ------------------------------ */}
        <div style={{ display: "flex", alignItems: "flex-end", justifyContent: "space-between", borderBottom: "2px solid var(--green)", paddingBottom: 6 }}>
          <h2 className="bb" style={{ margin: 0, fontSize: 28, lineHeight: 1, color: "var(--green)", whiteSpace: "nowrap" }}>
            Próximos da Fila
          </h2>
          <span style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12, fontWeight: 600, color: "var(--green)", whiteSpace: "nowrap" }}>
            <Clock size={15} />
            Espera total{" "}
            <span className="bb" style={{ fontSize: 20, lineHeight: 1, color: "var(--ink)" }}>
              {hhmm(data.total_wait_seconds)}
            </span>
          </span>
        </div>

        {data.queue.length === 0
          ? (
            <div style={{ padding: 20, border: "1.5px dashed rgba(47,70,41,.4)", borderRadius: 12, textAlign: "center", fontSize: 14, color: "var(--green)" }}>
              Ninguém na fila. Faça check-in e jogue agora.
            </div>
          )
          : (
            <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
              {data.queue.map((item) => <QueueRow key={item.entry_id} item={item} />)}
            </div>
          )}
      </div>

      <BottomNav
        parkId={data.park.id}
        courtId={court.id}
        tab="court"
        onScan={() => setFlow({ kind: "scan", purpose: mine?.is_called ? "start" : "join" })}
      />

      {/* --------------------------- sobreposições --------------------------- */}
      {flow.kind === "scan" && (
        <ScanOverlay
          court={data}
          purpose={flow.purpose}
          onRead={(result, method) => void onRead(result, method)}
          onClose={() => setFlow({ kind: "none" })}
        />
      )}

      {flow.kind === "join" && (
        <JoinSheet
          court={data}
          scan={flow.scan}
          method={flow.method}
          onClose={() => setFlow({ kind: "none" })}
          onJoined={async () => {
            // A primeira leitura pode ser uma que já estava no ar quando
            // o join saiu; nesse caso ela ainda não enxerga a entrada.
            let fresh = await refresh();
            if (!fresh?.my_entry) fresh = await refresh();

            const item = fresh?.my_entry ?? null;
            if (!item) {
              setFlow({ kind: "none" });
              return;
            }
            setFlow({ kind: "success", item });
            later(() => setFlow({ kind: "none" }), 2300);
          }}
        />
      )}

      {flow.kind === "success" && (
        <SuccessOverlay
          stack={flow.item.stack}
          positionLabel={flow.item.position_label}
          courtName={court.name}
          eta={eta(flow.item.eta_seconds)}
        />
      )}

      {flow.kind === "started" && (
        <StartedOverlay courtName={court.name} background={board} color={boardText} />
      )}

      {flow.kind === "call" && mine?.is_called && (
        <CallOverlay
          courtName={court.name}
          parkName={data.park.name}
          secondsLeft={callLeft(mine)}
          modeLabel={mine.mode_label}
          onCheckIn={() => setFlow({ kind: "scan", purpose: "start" })}
          onLater={() => setFlow({ kind: "none" })}
        />
      )}
    </>
  );
}

function callLeft(item: QueueItem): number {
  if (!item.call_expires_at) return 0;
  return Math.max(0, Math.floor((new Date(item.call_expires_at).getTime() - Date.now()) / 1000));
}

function sideLabel(players: Player[]): string {
  if (players.length === 0) return "Adversário livre";
  return players.map((player) => player.short_name).join(" / ");
}

function WinnerButton({ label, disabled, onClick }: { label: string; disabled: boolean; onClick: () => void }) {
  return (
    <button
      type="button"
      className="press"
      disabled={disabled}
      onClick={onClick}
      style={{
        flex: 1,
        minHeight: 48,
        background: "var(--ocre)",
        color: "var(--ink)",
        border: "2px solid var(--ink)",
        borderRadius: 8,
        fontSize: 14,
        fontWeight: 800,
        opacity: disabled ? 0.6 : 1,
      }}
    >
      {label}
    </button>
  );
}

/** Um dos lados do placar: iniciais num quadrado e o nome curto. */
function Side({ players, divider, empty }: { players: Player[]; divider?: boolean; empty?: string }) {
  return (
    <div
      style={{
        display: "flex",
        flexDirection: "column",
        justifyContent: "center",
        gap: 8,
        padding: 10,
        borderRight: divider ? "2px solid rgba(255,255,255,.75)" : undefined,
      }}
    >
      {players.map((player) => (
        <span key={player.user_id} style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, fontWeight: 600 }}>
          <span className="bb" style={{ display: "flex", alignItems: "center", justifyContent: "center", width: 28, height: 28, background: "rgba(255,255,255,.18)", border: "1.5px solid currentColor", borderRadius: 6, fontSize: 16 }}>
            {player.initials}
          </span>
          {player.short_name}
        </span>
      ))}
      {players.length === 0 && empty && (
        <span style={{ fontSize: 12, fontWeight: 600 }}>{empty}</span>
      )}
    </div>
  );
}

function QueueRow({ item }: { item: QueueItem }) {
  const players = item.players.map((player) => player.full_name ?? player.short_name).join(" · ");

  return (
    <div
      className={item.is_mine ? "flash" : undefined}
      style={{
        display: "flex",
        alignItems: "center",
        gap: 12,
        padding: "10px 10px 10px 12px",
        borderRadius: 12,
        ...(item.is_mine
          ? { background: "var(--green)", color: "var(--chalk)", border: "2px solid var(--ocre)" }
          : { background: "var(--chalk)", color: "var(--ink)", border: "1px solid rgba(47,70,41,.18)" }),
      }}
    >
      <div style={{ display: "flex", flexDirection: "column", alignItems: "center", width: 40 }}>
        <span className="bb" style={{ fontSize: 36, lineHeight: 0.9 }}>{item.position_label}</span>
      </div>

      <div style={{ display: "flex", flexDirection: "column", gap: 3, flexGrow: 1, minWidth: 0 }}>
        <span style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 14, fontWeight: 700 }}>
          {item.team_label ?? "Time"}
          {item.is_mine && (
            <span style={{ padding: "2px 6px", background: "var(--ocre)", color: "var(--ink)", borderRadius: 4, fontSize: 10, fontWeight: 800, letterSpacing: ".08em" }}>
              VOCÊ
            </span>
          )}
        </span>
        <span style={{ fontSize: 12, opacity: 0.85, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
          {players}
        </span>
        <span style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 11, fontWeight: 700, letterSpacing: ".06em", textTransform: "uppercase" }}>
          <span>{item.mode_label}</span>
          <span style={{ display: "flex", alignItems: "center", gap: 4 }}>
            <Clock size={12} strokeWidth="2.4" />
            <span className="bb" style={{ fontSize: 17, lineHeight: 1, letterSpacing: ".03em", textTransform: "none" }}>
              {item.is_called ? "Agora" : eta(item.eta_seconds)}
            </span>
          </span>
        </span>
      </div>

      <RacketStack
        rackets={item.stack}
        more={item.stack_more}
        face={item.is_mine ? "#0A0E0B" : "#2F4629"}
        highlightLast={item.is_mine}
      />
    </div>
  );
}

export type { CourtScreen };
