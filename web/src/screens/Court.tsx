import { useEffect, useRef, useState } from "react";
import { useLocation, useNavigate, useParams } from "react-router-dom";
import { useLiveCourt, useTicker } from "../hooks/useLiveCourt";
import { SURFACE_COLOR, eta, hhmm, mmss, surfaceTextColor } from "../lib/format";
import { rememberCourt, rememberPark } from "../lib/nav";
import { ErrorState, Loading } from "../components/ui";
import { RacketStack } from "../components/Racket";
import { BottomNav } from "../components/BottomNav";
import { CallOverlay, StartedOverlay, SuccessOverlay } from "../components/Overlays";
import { ChevronLeft, Check, Clock, Pin, Players, QrIcon, ScanFrame, SurfaceIcon, Warn } from "../components/icons";
import { ScanOverlay } from "./ScanOverlay";
import { JoinSheet, type JoinOutcome } from "./JoinSheet";
import { AskForQr, HostOpenSheet, HostPanel, InviteQr } from "./Host";
import { cancelJoinRequest, checkIn, confirmAtCourt, decideJoinRequest, finishTurn, leaveQueue } from "../lib/api";
import { LocationError } from "../lib/geo";
import type { CourtScreen, MyGroup, MyJoinRequest, Player, QueueItem, ScanResult } from "../lib/types";

type Flow =
  | { kind: "none" }
  | { kind: "scan"; purpose: "join" | "start" }
  | { kind: "join"; scan: ScanResult; method: "qr" | "nfc" }
  | { kind: "success"; item: QueueItem }
  | { kind: "started" }
  | { kind: "call" }
  | { kind: "host-open" }
  | { kind: "invite" };

export function Court() {
  const { courtId } = useParams<{ courtId: string }>();
  const navigate = useNavigate();
  const location = useLocation();
  const { data, error, loading, refresh } = useLiveCourt(courtId);
  const [flow, setFlow] = useState<Flow>({ kind: "none" });
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
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

  // Chamaram o nosso grupo: a tela cheia do protótipo aparece uma vez
  // por chamada — depois dela o cartão na própria quadra basta.
  useEffect(() => {
    const entry = data?.my_entry;
    if (!entry?.is_called) return;
    if (calledFor.current === entry.entry_id) return;
    calledFor.current = entry.entry_id;
    setFlow({ kind: "call" });
  }, [data]);

  useEffect(() => () => timers.current.forEach(clearTimeout), []);

  /**
   * Chegou do QR impresso com a leitura já validada: abre a folha de
   * entrar na fila direto, em vez de pedir uma segunda leitura. O
   * estado é consumido na hora — recarregar a página não deve repetir
   * isso com um token já gasto.
   */
  useEffect(() => {
    const handoff = location.state as
      | { scan?: ScanResult; method?: "qr" | "nfc"; openScan?: boolean }
      | null;
    if (!handoff?.scan && !handoff?.openScan) return;

    navigate(location.pathname, { replace: true, state: null });

    // Veio da barra inferior: abre a câmera em vez da folha.
    if (!handoff.scan) {
      setFlow({ kind: "scan", purpose: "join" });
      return;
    }

    const expired = new Date(handoff.scan.expiresAt).getTime() <= Date.now();
    if (expired) return;

    setFlow({ kind: "join", scan: handoff.scan, method: handoff.method ?? "qr" });
  }, [location.state, location.pathname, navigate]);

  function later(fn: () => void, ms: number) {
    timers.current.push(window.setTimeout(fn, ms));
  }

  if (error) return <ErrorState title="Não conseguimos carregar a quadra" detail={error.message} onRetry={refresh} />;
  if (loading || !data) return <Loading what="Carregando a quadra" />;

  const court = data.court;
  const match = data.match;
  const live = Boolean(match?.is_live);
  const mine = data.my_entry;
  const group = data.my_group;
  const request = data.my_request;
  // Piloto sem nada na placa: entra-se pelo QR na tela de alguém da
  // fila, e o check-in é o botão "Entrando na quadra".
  const hostMode = court.queue_mode === "host";
  const host = data.host ?? null;
  const board = SURFACE_COLOR[court.surface] ?? "var(--green)";
  const boardText = surfaceTextColor(court.surface);

  const now = Date.now();
  const elapsed = live && match
    ? Math.max(0, Math.floor((now - new Date(match.started_at).getTime()) / 1000))
    : 0;
  const remaining = live && match
    ? Math.max(0, Math.floor((new Date(match.expires_at).getTime() - now) / 1000))
    : 0;

  const playingHere = group?.status === "playing";
  const needsMyCheckIn = Boolean(playingHere && !group?.checked_in);
  const nextUpHere = Boolean(mine && !mine.is_called && mine.position === 1 && live);
  const joinedElsewhere = Boolean(!group && data.my_state.state !== "free" && data.my_state.court_id !== court.id);

  async function act(action: () => Promise<unknown>, done?: string) {
    setBusy(true);
    try {
      await action();
      await refresh();
      if (done) setNotice(done);
    } catch (cause) {
      setNotice((cause as Error).message);
    } finally {
      setBusy(false);
    }
  }

  function onLeave() {
    if (!group) return;
    const alone = group.group_size <= 1;
    const question = playingHere
      ? alone
        ? "Sair da quadra? O turno acaba e a vez passa para o próximo."
        : "Sair do grupo? O turno continua com os outros."
      : alone
        ? "Sair da fila? Você perde a posição."
        : "Sair do grupo? A vaga continua com os outros.";
    if (!confirm(question)) return;
    calledFor.current = null;
    void act(() => leaveQueue(group.entry_id), alone ? "Você saiu da fila." : "Você saiu do grupo.");
  }

  function onFinish() {
    if (!match || !confirm("Devolver a quadra agora? O turno acaba para o grupo todo.")) return;
    void act(() => finishTurn(match.match_id), "Turno encerrado. O próximo da fila foi chamado.");
  }

  // Leitura válida: ou abre a folha da fila, ou faz o check-in.
  async function onRead(result: ScanResult, method: "qr" | "nfc") {
    if (result.purpose === "join") {
      setFlow({ kind: "join", scan: result, method });
      return;
    }
    await finishCheckIn(result.scanToken);
  }

  /**
   * Na quadra com placa, o check-in é escanear o QR ou o NFC. No modo
   * anfitrião não há o que escanear: o botão manda a localização, e o
   * servidor confere a distância antes de começar o turno.
   */
  async function startCheckIn() {
    if (!hostMode) {
      setFlow({ kind: "scan", purpose: "start" });
      return;
    }
    setBusy(true);
    try {
      const scan = await confirmAtCourt(court.id, "start");
      await finishCheckIn(scan.scanToken);
    } catch (cause) {
      setNotice(
        cause instanceof LocationError && cause.kind === "denied"
          ? "Libere a localização para o site — é assim que confirmamos que você está na quadra."
          : (cause as Error).message,
      );
      setFlow({ kind: "none" });
    } finally {
      setBusy(false);
    }
  }

  async function finishCheckIn(scanToken: string) {
    try {
      const wasPlaying = playingHere;
      await checkIn(scanToken);
      calledFor.current = null;
      if (wasPlaying) {
        setFlow({ kind: "none" });
        setNotice("Check-in feito. Bom jogo!");
      } else {
        setFlow({ kind: "started" });
        later(() => setFlow({ kind: "none" }), 2600);
      }
      await refresh();
    } catch (cause) {
      setNotice((cause as Error).message);
      setFlow({ kind: "none" });
    }
  }

  async function onJoined(outcome: JoinOutcome) {
    if (outcome !== "opened") {
      setFlow({ kind: "none" });
      await refresh();
      setNotice(
        outcome === "joined"
          ? "Você entrou no grupo."
          : "Pedido enviado. Quando quem abriu a vaga aceitar, você entra no grupo — se estiver em outra fila, só sai dela nessa hora.",
      );
      return;
    }

    // A primeira leitura pode ser uma que já estava no ar quando o join
    // saiu; nesse caso ela ainda não enxerga a entrada.
    let fresh = await refresh();
    if (!fresh?.my_entry) fresh = await refresh();

    const item = fresh?.my_entry ?? null;
    if (!item) {
      setFlow({ kind: "none" });
      return;
    }
    setFlow({ kind: "success", item });
    later(() => setFlow({ kind: "none" }), 2300);
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
              {live ? `Tempo de quadra · turno de ${court.slot_minutes} min` : "Aguardando check-in"}
            </span>
          </div>

          <GroupBoard
            players={live ? match?.players ?? [] : []}
            empty={live
              ? match?.is_offline ? match.offline_label ?? "Grupo sem app" : "Grupo em quadra"
              : "Sem jogo em andamento"}
          />

          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginTop: 12 }}>
            <span style={{ display: "flex", alignItems: "center", gap: 6, padding: "5px 9px", background: "rgba(10,14,11,.28)", borderRadius: 6, fontSize: 12, fontWeight: 700 }}>
              <Players size={14} />
              {live ? match?.group_label : "Sem grupo em quadra"}
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

        {/* ------------------------ fila com anfitrião ------------------------ */}
        {data.can_open_host && (
          <div style={{ display: "flex", flexDirection: "column", gap: 10, padding: 14, background: "var(--chalk)", border: "2px solid var(--green)", borderRadius: 12 }}>
            <span style={{ display: "flex", flexDirection: "column", gap: 4, fontSize: 13, lineHeight: 1.4 }}>
              <strong style={{ fontSize: 15 }}>Ninguém abriu a fila desta quadra ainda</strong>
              Você é o primeiro com o app. Conte quem está jogando e quem já espera, e a fila
              passa a andar pelo app — quem chegar depois entra pelo QR na sua tela.
            </span>
            <button
              type="button"
              className="press"
              onClick={() => setFlow({ kind: "host-open" })}
              style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 10, width: "100%", minHeight: 56, background: "var(--ocre)", color: "var(--ink)", border: "2px solid var(--ink)", borderRadius: 10, fontSize: 16, fontWeight: 800 }}
            >
              <Players size={20} />
              Começar a fila aqui
            </button>
          </div>
        )}

        {host?.is_me && (
          <HostPanel court={data} busy={busy} onAct={(action, done) => void act(action, done)} />
        )}

        {host?.can_show_invite && (
          <button
            type="button"
            className="press"
            onClick={() => setFlow({ kind: "invite" })}
            style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 10, width: "100%", minHeight: 52, background: "var(--green)", color: "var(--chalk)", border: "2px solid var(--ink)", borderRadius: 10, fontSize: 15, fontWeight: 800 }}
          >
            <QrIcon size={20} />
            Mostrar QR para quem chegou
          </button>
        )}

        {/* ----------------------------- ações ----------------------------- */}
        {playingHere && match && group && (
          <div style={{ display: "flex", flexDirection: "column", gap: 10, padding: 12, background: "var(--ink)", color: "var(--chalk)", borderRadius: 10 }}>
            <span style={{ display: "flex", flexDirection: "column", gap: 2 }}>
              <span style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 11, fontWeight: 800, letterSpacing: ".1em", color: "var(--sage)" }}>
                <span className="dot" style={{ background: "var(--sage)" }} />SEU GRUPO ESTÁ EM QUADRA
              </span>
              <span style={{ fontSize: 14, fontWeight: 600 }}>
                {needsMyCheckIn
                  ? hostMode
                    ? "Chegou? Toque em “Entrando na quadra” para registrar que você está jogando."
                    : "Chegou? Escaneie a quadra para registrar que você está jogando."
                  : "Bom jogo! Quem chegar atrasado entra com o PIN — o tempo segue normal."}
              </span>
            </span>

            {needsMyCheckIn && (
              <button
                type="button"
                className="press"
                disabled={busy}
                onClick={() => void startCheckIn()}
                style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 10, minHeight: 48, background: "var(--ocre)", color: "var(--ink)", border: "2px solid var(--chalk)", borderRadius: 8, fontSize: 14, fontWeight: 800 }}
              >
                {hostMode ? <Pin size={18} /> : <ScanFrame size={18} />}
                {hostMode ? "Entrando na quadra" : "Fazer meu check-in"}
              </button>
            )}

            <GroupPanel group={group} busy={busy} dark onDecide={(id, approve) =>
              void act(() => decideJoinRequest(id, approve), approve ? "Pedido aceito." : "Pedido recusado.")} />

            <div style={{ display: "flex", gap: 8 }}>
              <button
                type="button"
                className="press"
                disabled={busy}
                onClick={onFinish}
                style={{ flex: 1, minHeight: 44, padding: "0 12px", background: "transparent", color: "var(--chalk)", border: "1.5px solid rgba(241,236,239,.6)", borderRadius: 8, fontSize: 13, fontWeight: 700 }}
              >
                Devolver a quadra
              </button>
              <button
                type="button"
                className="press"
                disabled={busy}
                onClick={onLeave}
                style={{ flex: 1, minHeight: 44, padding: "0 12px", background: "transparent", color: "var(--chalk)", border: "1.5px solid rgba(241,236,239,.6)", borderRadius: 8, fontSize: 13, fontWeight: 700 }}
              >
                Sair do grupo
              </button>
            </div>
          </div>
        )}

        {mine?.is_called && (
          <div className="flash" style={{ display: "flex", flexDirection: "column", gap: 12, padding: 14, background: "var(--green)", color: "var(--chalk)", border: "2px solid var(--ocre)", borderRadius: 12 }}>
            <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10 }}>
              <span style={{ display: "flex", flexDirection: "column", gap: 2 }}>
                <span style={{ fontSize: 11, fontWeight: 800, letterSpacing: ".1em", color: "var(--ocre)" }}>
                  VEZ DO SEU GRUPO · QUADRA LIBERADA
                </span>
                <span className="bb" style={{ fontSize: 30, lineHeight: 1 }}>Faça check-in para jogar</span>
              </span>
              <span style={{ display: "flex", flexDirection: "column", alignItems: "flex-end" }}>
                <span className="bb" role="timer" style={{ fontSize: 34, lineHeight: 1 }}>{mmss(callLeft(mine))}</span>
                <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: ".08em", color: "var(--mauve)" }}>DE TOLERÂNCIA</span>
              </span>
            </div>
            <span style={{ fontSize: 13, lineHeight: 1.4 }}>
              {hostMode
                ? "Basta um do grupo tocar no botão, já na quadra. Quem chegar depois entra com o turno rolando."
                : "Basta um do grupo escanear. Quem chegar depois entra com o turno rolando."}
            </span>
            <button
              type="button"
              className="press"
              disabled={busy}
              onClick={() => void startCheckIn()}
              style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 10, width: "100%", minHeight: 56, background: "var(--ocre)", color: "var(--ink)", border: "2px solid var(--ink)", borderRadius: 10, fontSize: 16, fontWeight: 800 }}
            >
              {hostMode ? <Pin size={20} /> : <ScanFrame size={20} />}
              {hostMode ? "Entrando na quadra" : "Check-in QR / NFC e iniciar turno"}
            </button>
          </div>
        )}

        {nextUpHere && (
          <div style={{ display: "flex", alignItems: "center", gap: 10, padding: 12, background: "var(--chalk)", border: "1.5px solid var(--green)", borderRadius: 10 }}>
            <span className="bb" style={{ display: "flex", alignItems: "center", justifyContent: "center", minWidth: 44, height: 44, background: "var(--ocre)", color: "var(--ink)", borderRadius: 8, fontSize: 24 }}>
              1º
            </span>
            <span style={{ display: "flex", flexDirection: "column", gap: 2, fontSize: 13, lineHeight: 1.35 }}>
              <strong style={{ fontSize: 14 }}>Seu grupo é o próximo</strong>
              Faltam ~{Math.max(1, Math.ceil(remaining / 60))} min para acabar o turno atual.
              Avisamos quando a quadra liberar — aí são {Math.round(court.call_window_seconds / 60)} min para o check-in.
            </span>
          </div>
        )}

        {mine && group && !playingHere && (
          <div style={{ display: "flex", flexDirection: "column", gap: 10, padding: "10px 12px", background: "var(--green)", color: "var(--chalk)", borderRadius: 10 }}>
            <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10 }}>
              <span style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 14, fontWeight: 600 }}>
                <span style={{ color: "var(--sage)", display: "flex" }}><Check size={18} strokeWidth="2.6" /></span>
                Seu grupo é o {mine.position_label} da fila
              </span>
              <button
                type="button"
                className="press"
                disabled={busy}
                onClick={onLeave}
                style={{ minHeight: 40, padding: "0 12px", background: "transparent", color: "var(--chalk)", border: "1.5px solid rgba(241,236,239,.6)", borderRadius: 8, fontSize: 13, fontWeight: 600 }}
              >
                {group.group_size <= 1 ? "Sair da fila" : "Sair do grupo"}
              </button>
            </div>
            <GroupPanel group={group} busy={busy} onDecide={(id, approve) =>
              void act(() => decideJoinRequest(id, approve), approve ? "Pedido aceito." : "Pedido recusado.")} />
          </div>
        )}

        {request && !group && (
          <PendingRequest
            request={request}
            busy={busy}
            onCancel={() => void act(() => cancelJoinRequest(request.request_id), "Pedido cancelado.")}
          />
        )}

        {hostMode && host && !group && (data.can_join || joinedElsewhere) && (
          <AskForQr hostName={host.host_name} />
        )}

        {!group && (data.can_join || joinedElsewhere) && (
          <button
            type="button"
            className="press"
            onClick={() => setFlow({ kind: "scan", purpose: "join" })}
            style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 10, width: "100%", minHeight: 56, background: "var(--ocre)", color: "var(--ink)", border: "2px solid var(--ink)", borderRadius: 10, fontSize: 16, fontWeight: 800 }}
          >
            <ScanFrame size={20} />
            {hostMode
              ? "Escanear o QR de alguém da fila"
              : data.can_join ? "Entrar na Fila" : "Entrar no grupo de um amigo"}
          </button>
        )}

        {!group && !data.can_join && !joinedElsewhere && !data.court_accepting && !data.can_open_host && (
          <div style={{ padding: 12, background: "var(--chalk)", border: "1.5px dashed rgba(47,70,41,.4)", borderRadius: 10, fontSize: 13, color: "var(--green)", textAlign: "center" }}>
            Esta quadra não está aceitando fila agora.
          </div>
        )}

        {joinedElsewhere && (
          <div style={{ display: "flex", alignItems: "flex-start", gap: 10, padding: 12, background: "var(--chalk)", border: "1.5px solid var(--rust)", borderRadius: 10, fontSize: 13, lineHeight: 1.4 }}>
            <span style={{ color: "var(--rust)", flexShrink: 0, display: "flex" }}><Warn size={20} /></span>
            <span>
              <strong>Você já está na fila da {data.my_state.court_name}.</strong> Uma vaga por pessoa:
              para entrar no grupo de um amigo aqui, você sai de lá.
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
              {hostMode && !host
                ? "A fila desta quadra ainda não começou no app."
                : "Ninguém na fila. Faça check-in e jogue agora."}
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
        onScan={() => (mine?.is_called || needsMyCheckIn ? void startCheckIn() : setFlow({ kind: "scan", purpose: "join" }))}
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
          onRescan={() => setFlow({ kind: "scan", purpose: "join" })}
          onDone={onJoined}
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
          groupLabel={mine.group_label}
          locationCheckIn={hostMode}
          onCheckIn={() => void startCheckIn()}
          onLater={() => setFlow({ kind: "none" })}
        />
      )}

      {flow.kind === "host-open" && (
        <HostOpenSheet
          court={data}
          onClose={() => setFlow({ kind: "none" })}
          onOpened={() => {
            setFlow({ kind: "none" });
            setNotice("Fila aberta. Mostre o QR para quem chegar — e marque aqui quando os grupos sem app entrarem.");
            void refresh();
          }}
          onAlreadyOpen={(message) => {
            setFlow({ kind: "none" });
            setNotice(message);
            void refresh();
          }}
        />
      )}

      {flow.kind === "invite" && <InviteQr court={data} onClose={() => setFlow({ kind: "none" })} />}
    </>
  );
}

function callLeft(item: QueueItem): number {
  if (!item.call_expires_at) return 0;
  return Math.max(0, Math.floor((new Date(item.call_expires_at).getTime() - Date.now()) / 1000));
}

/** O grupo em quadra: iniciais num quadrado, o nome curto e quem já fez check-in. */
function GroupBoard({ players, empty }: { players: Player[]; empty: string }) {
  return (
    <div style={{ display: "grid", gridTemplateColumns: "repeat(2, minmax(0, 1fr))", gap: 8, padding: 10, border: "2px solid rgba(255,255,255,.75)", borderRadius: 6, minHeight: 92, alignContent: "center" }}>
      {players.map((player) => (
        <span key={player.user_id} style={{ display: "flex", alignItems: "center", gap: 8, minWidth: 0, fontSize: 13, fontWeight: 600 }}>
          <span className="bb" style={{ display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0, width: 28, height: 28, background: "rgba(255,255,255,.18)", border: "1.5px solid currentColor", borderRadius: 6, fontSize: 16, opacity: player.checked_in ? 1 : 0.55 }}>
            {player.initials}
          </span>
          <span style={{ whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", opacity: player.checked_in ? 1 : 0.7 }}>
            {player.short_name}
          </span>
        </span>
      ))}
      {players.length === 0 && (
        <span style={{ gridColumn: "1 / -1", fontSize: 12, fontWeight: 600 }}>{empty}</span>
      )}
    </div>
  );
}

/**
 * O que só o grupo vê: o PIN para passar aos amigos, quem já está nele e
 * os pedidos esperando resposta (só o dono aceita).
 */
function GroupPanel({
  group,
  busy,
  dark,
  onDecide,
}: {
  group: MyGroup;
  busy: boolean;
  dark?: boolean;
  onDecide: (requestId: string, approve: boolean) => void;
}) {
  const line = dark ? "rgba(241,236,239,.3)" : "rgba(241,236,239,.35)";

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 10, paddingTop: 10, borderTop: `1px dashed ${line}` }}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10 }}>
        <span style={{ display: "flex", flexDirection: "column", gap: 2, fontSize: 12, lineHeight: 1.35 }}>
          <span style={{ fontSize: 10, fontWeight: 800, letterSpacing: ".1em", color: "var(--ocre)" }}>PIN DO GRUPO</span>
          Passe para quem vai jogar com você. Com ele, entra direto — mesmo com o turno rolando.
        </span>
        <span className="bb" aria-label={`PIN ${group.pin.split("").join(" ")}`} style={{ flexShrink: 0, padding: "4px 10px", background: "var(--chalk)", color: "var(--ink)", borderRadius: 8, fontSize: 32, lineHeight: 1, letterSpacing: ".18em" }}>
          {group.pin}
        </span>
      </div>

      <span style={{ fontSize: 12, fontWeight: 600 }}>
        {group.players.map((player) => player.short_name).join(" · ")}
      </span>

      {group.pending_requests.map((request) => (
        <div key={request.request_id} style={{ display: "flex", alignItems: "center", gap: 10, padding: "8px 10px", background: "rgba(241,236,239,.12)", border: "1.5px solid var(--ocre)", borderRadius: 8 }}>
          <span className="bb" style={{ display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0, width: 32, height: 32, background: "var(--ocre)", color: "var(--ink)", borderRadius: 6, fontSize: 16 }}>
            {request.initials}
          </span>
          <span style={{ flexGrow: 1, minWidth: 0, fontSize: 13, lineHeight: 1.3 }}>
            <strong>{request.full_name ?? request.short_name}</strong> quer entrar no grupo
          </span>
          {group.is_owner
            ? (
              <span style={{ display: "flex", gap: 6, flexShrink: 0 }}>
                <button
                  type="button"
                  className="press"
                  disabled={busy}
                  onClick={() => onDecide(request.request_id, false)}
                  style={{ minHeight: 40, padding: "0 10px", background: "transparent", color: "var(--chalk)", border: "1.5px solid rgba(241,236,239,.6)", borderRadius: 8, fontSize: 12, fontWeight: 700 }}
                >
                  Recusar
                </button>
                <button
                  type="button"
                  className="press"
                  disabled={busy}
                  onClick={() => onDecide(request.request_id, true)}
                  style={{ minHeight: 40, padding: "0 12px", background: "var(--ocre)", color: "var(--ink)", border: "2px solid var(--ink)", borderRadius: 8, fontSize: 12, fontWeight: 800 }}
                >
                  Aceitar
                </button>
              </span>
            )
            : <span style={{ flexShrink: 0, fontSize: 11, fontWeight: 700 }}>Quem abriu a vaga decide</span>}
        </div>
      ))}
    </div>
  );
}

function PendingRequest({
  request,
  busy,
  onCancel,
}: {
  request: MyJoinRequest;
  busy: boolean;
  onCancel: () => void;
}) {
  return (
    <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10, padding: 12, background: "var(--chalk)", border: "1.5px solid var(--green)", borderRadius: 10 }}>
      <span style={{ display: "flex", flexDirection: "column", gap: 2, fontSize: 13, lineHeight: 1.35 }}>
        <strong style={{ fontSize: 14 }}>Pedido enviado</strong>
        Esperando {request.owner_name ?? "quem abriu a vaga"} aceitar você no grupo.
      </span>
      <button
        type="button"
        className="press"
        disabled={busy}
        onClick={onCancel}
        style={{ flexShrink: 0, minHeight: 40, padding: "0 12px", background: "transparent", color: "var(--green)", border: "1.5px solid var(--green)", borderRadius: 8, fontSize: 13, fontWeight: 700 }}
      >
        Cancelar
      </button>
    </div>
  );
}

function QueueRow({ item }: { item: QueueItem }) {
  const players = item.is_offline
    ? "Sem o app no celular"
    : item.players.map((player) => player.full_name ?? player.short_name).join(" · ");

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
          {item.team_label ?? "Grupo"}
          {item.is_offline && (
            <span style={{ padding: "2px 6px", border: "1.5px solid currentColor", borderRadius: 4, fontSize: 10, fontWeight: 800, letterSpacing: ".08em" }}>
              SEM APP
            </span>
          )}
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
          {!item.is_offline && <span>{item.group_label}</span>}
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
