import { useEffect, useRef, useState } from "react";
import { Arrow, Check, Close, Lock, Players, ScanFrame, Warn } from "../components/icons";
import { useTicker } from "../hooks/useLiveCourt";
import { joinQueue, joinWithPin, requestJoin } from "../lib/api";
import { SURFACE_COLOR, eta, mmss, surfaceTextColor } from "../lib/format";
import type { CourtScreen, Player, ScanResult } from "../lib/types";

export type JoinOutcome = "opened" | "requested" | "joined";

/** Um grupo da quadra em que dá para entrar: o que está em quadra e os da fila. */
interface Joinable {
  entryId: string;
  where: string;
  label: string;
  size: string;
  owner: string;
}

/**
 * A folha que abre depois de escanear a quadra. Três caminhos:
 *
 *   - abrir uma vaga — sozinho; os amigos entram nela depois;
 *   - pedir para entrar no grupo de alguém — o dono aceita;
 *   - entrar com o PIN do grupo — sem esperar ninguém.
 *
 * O scan vale 30 segundos e é de uso único. Por isso o relógio aparece
 * aqui, e um PIN errado (que gasta o scan) pede uma leitura nova.
 */
export function JoinSheet({
  court,
  scan,
  method,
  onClose,
  onRescan,
  onDone,
}: {
  court: CourtScreen;
  scan: ScanResult;
  method: "qr" | "nfc";
  onClose: () => void;
  onRescan: () => void;
  onDone: (outcome: JoinOutcome) => Promise<void> | void;
}) {
  const [pin, setPin] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [spent, setSpent] = useState(false);
  const [switchTo, setSwitchTo] = useState<Joinable | null>(null);
  const sheet = useRef<HTMLDivElement>(null);

  // O erro aparece no topo da folha; quem errou o PIN está lá embaixo.
  useEffect(() => {
    if (error) sheet.current?.scrollTo({ top: 0, behavior: "smooth" });
  }, [error]);

  useTicker(!spent);

  const secondsLeft = Math.max(0, Math.floor((new Date(scan.expiresAt).getTime() - Date.now()) / 1000));
  const expired = spent || secondsLeft === 0;
  const free = court.my_state.state === "free";

  const board = SURFACE_COLOR[court.court.surface] ?? "var(--green)";
  const boardText = surfaceTextColor(court.court.surface);
  const elapsed = court.match?.is_live
    ? Math.max(0, Math.floor((Date.now() - new Date(court.match.started_at).getTime()) / 1000))
    : 0;

  const groups: Joinable[] = [
    ...(court.match?.is_live
      ? [{
        entryId: court.match.entry_id,
        where: "Em quadra",
        label: teamLabel(court.match.players),
        size: court.match.group_label,
        owner: ownerName(court.match.players),
      }]
      : []),
    ...court.queue
      .filter((item) => !item.is_mine)
      .map((item) => ({
        entryId: item.entry_id,
        where: `${item.position_label} da fila`,
        label: item.team_label ?? "Grupo",
        size: item.group_label,
        owner: ownerName(item.players),
      })),
  ];

  async function run(action: () => Promise<void>, group?: Joinable) {
    if (busy || expired) return;
    setBusy(true);
    setError(null);
    try {
      await action();
    } catch (cause) {
      const failure = cause as { code?: string; message?: string };
      // Está em outra fila: o aviso pergunta se quer sair dela. A
      // chamada que falhou não gastou o scan, então dá para repetir.
      if (group && (failure.code === "NQ014" || failure.code === "ALREADY_IN_ANOTHER_QUEUE")) {
        setSwitchTo(group);
      } else {
        if (failure.code === "NQ002" || failure.code === "SCAN_TOKEN_INVALID") setSpent(true);
        setError(failure.message ?? "Não foi possível concluir.");
      }
    } finally {
      setBusy(false);
    }
  }

  function openSpot() {
    void run(async () => {
      await joinQueue(scan.scanToken);
      if (navigator.vibrate) navigator.vibrate([18, 40, 24]);
      await onDone("opened");
    });
  }

  function ask(group: Joinable, leaveCurrent = false) {
    void run(async () => {
      await requestJoin(scan.scanToken, group.entryId, leaveCurrent);
      await onDone("requested");
    }, group);
  }

  function enterWithPin(leaveCurrent = false) {
    const group: Joinable = { entryId: "", where: "", label: "", size: "", owner: "" };
    void run(async () => {
      const result = await joinWithPin(scan.scanToken, pin, leaveCurrent);
      if (!result.joined) {
        // PIN errado gasta o scan: tentar de novo exige estar na quadra.
        setSpent(true);
        setError(
          result.attempts_left > 0
            ? `${result.message} Restam ${result.attempts_left} tentativa(s).`
            : "PIN incorreto. As tentativas acabaram por agora — peça para entrar no grupo.",
        );
        return;
      }
      if (navigator.vibrate) navigator.vibrate([18, 40, 24]);
      await onDone("joined");
    }, group);
  }

  return (
    <div
      className="fade"
      role="dialog"
      aria-modal="true"
      aria-label="Entrar na fila"
      onClick={onClose}
      style={{
        position: "fixed",
        left: "50%",
        transform: "translateX(-50%)",
        top: 0,
        bottom: 0,
        width: "100%",
        maxWidth: 480,
        zIndex: 20,
        display: "flex",
        flexDirection: "column",
        justifyContent: "flex-end",
        background: "rgba(10,14,11,.62)",
      }}
    >
      <div
        ref={sheet}
        className="sheet scroll"
        onClick={(event) => event.stopPropagation()}
        style={{
          display: "flex",
          flexDirection: "column",
          gap: 16,
          maxHeight: "92dvh",
          overflowY: "auto",
          padding: "10px 18px 22px",
          background: "var(--bg)",
          borderRadius: "16px 16px 0 0",
        }}
      >
        <span style={{ alignSelf: "center", width: 44, height: 4, borderRadius: 2, background: "rgba(10,14,11,.25)" }} />

        <div style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between", gap: 10 }}>
          <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
            <span style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 12, fontWeight: 700, color: "var(--green)", letterSpacing: ".06em", textTransform: "uppercase" }}>
              <Check size={16} strokeWidth="2.6" />
              Check-in confirmado · {method === "qr" ? "QR Code" : "NFC"}
            </span>
            <span className="bb" style={{ fontSize: 36, lineHeight: 0.95 }}>
              {court.court.name} — {court.court.surface_label}
            </span>
          </div>
          <button
            type="button"
            className="press"
            onClick={onClose}
            aria-label="Fechar"
            style={{ display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0, width: 44, height: 44, background: "transparent", color: "var(--ink)", border: "1.5px solid rgba(10,14,11,.3)", borderRadius: 10 }}
          >
            <Close size={20} />
          </button>
        </div>

        <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "10px 12px", borderRadius: 10, background: board, color: boardText }}>
          <span className="bb" style={{ fontSize: 26, lineHeight: 1 }}>{mmss(elapsed)}</span>
          <span style={{ fontSize: 13, fontWeight: 600, flexGrow: 1 }}>{court.status_text} · {court.queue_text}</span>
          <span style={{ fontSize: 11, fontWeight: 700 }} aria-live="polite">
            {expired ? "Leitura vencida" : `Leitura vale ${mmss(secondsLeft)}`}
          </span>
        </div>

        {expired && (
          <button
            type="button"
            className="press"
            onClick={onRescan}
            style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: 10, width: "100%", minHeight: 52, background: "var(--ocre)", color: "var(--ink)", border: "2px solid var(--ink)", borderRadius: 10, fontSize: 15, fontWeight: 800 }}
          >
            <ScanFrame size={20} />
            Escanear a quadra de novo
          </button>
        )}

        {error && (
          <p role="alert" style={{ margin: 0, padding: "10px 12px", borderRadius: 8, fontSize: 13, lineHeight: 1.4, background: "rgba(177,63,22,.1)", color: "var(--rust)" }}>
            {error}
          </p>
        )}

        {/* --------------------------- abrir vaga --------------------------- */}
        <section style={{ display: "flex", flexDirection: "column", gap: 10 }}>
          <span style={{ fontSize: 13, fontWeight: 700 }}>Guardar lugar na fila</span>

          {!free && (
            <div style={{ display: "flex", alignItems: "flex-start", gap: 10, padding: 12, background: "var(--chalk)", border: "1.5px solid var(--rust)", borderRadius: 10, fontSize: 13, lineHeight: 1.4 }}>
              <span style={{ color: "var(--rust)", flexShrink: 0, display: "flex" }}><Warn size={20} /></span>
              <span>
                <strong>{court.my_state.where ?? "Você já está em uma fila."}</strong>{" "}
                Uma vaga por pessoa — saia da atual para abrir outra.
              </span>
            </div>
          )}

          <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", fontSize: 13 }}>
            <span style={{ color: "var(--green)", fontWeight: 600 }}>Sua posição prevista</span>
            <span style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
              <span className="bb" style={{ fontSize: 30, lineHeight: 1 }}>{court.next_position_label}</span>
              <span style={{ fontWeight: 600 }}>em {eta(court.total_wait_seconds)}</span>
            </span>
          </div>

          <button
            type="button"
            className="press"
            onClick={openSpot}
            disabled={!court.can_join || busy || expired}
            style={{
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              gap: 10,
              width: "100%",
              minHeight: 56,
              borderRadius: 10,
              fontSize: 16,
              fontWeight: 800,
              ...(!court.can_join || busy || expired
                ? { background: "var(--mauve)", color: "var(--muted)", border: "2px solid transparent" }
                : { background: "var(--ocre)", color: "var(--ink)", border: "2px solid var(--ink)" }),
            }}
          >
            {busy ? "Um instante…" : "Abrir vaga e entrar na fila"}
            {!busy && <Arrow size={20} />}
          </button>
          <span style={{ fontSize: 12, lineHeight: 1.4, color: "var(--green)" }}>
            Pode entrar sozinho. Seus amigos entram na mesma vaga escaneando a quadra — você
            aceita o pedido ou passa o PIN do grupo.
          </span>
        </section>

        {/* ------------------------ grupo de um amigo ------------------------ */}
        <section style={{ display: "flex", flexDirection: "column", gap: 10, paddingTop: 14, borderTop: "1px dashed rgba(47,70,41,.35)" }}>
          <span style={{ fontSize: 13, fontWeight: 700 }}>Entrar no grupo de um amigo</span>

          <div style={{ display: "flex", gap: 8 }}>
            <input
              aria-label="PIN do grupo"
              inputMode="numeric"
              autoComplete="one-time-code"
              maxLength={4}
              placeholder="PIN"
              value={pin}
              onChange={(event) => setPin(event.target.value.replace(/\D/g, "").slice(0, 4))}
              style={{ width: 0, flexGrow: 1, height: 52, padding: "0 14px", background: "var(--chalk)", border: "1.5px solid rgba(47,70,41,.35)", borderRadius: 8, fontSize: 24, letterSpacing: ".3em", fontWeight: 700, color: "var(--ink)" }}
            />
            <button
              type="button"
              className="press"
              onClick={() => enterWithPin()}
              disabled={pin.length !== 4 || busy || expired}
              style={{ minHeight: 52, padding: "0 16px", borderRadius: 8, fontSize: 14, fontWeight: 800, background: "var(--green)", color: "var(--chalk)", border: 0, opacity: pin.length !== 4 || busy || expired ? 0.5 : 1 }}
            >
              Entrar com PIN
            </button>
          </div>

          <div style={{ display: "flex", alignItems: "flex-start", gap: 8, padding: "10px 12px", background: "rgba(47,70,41,.08)", borderRadius: 8, fontSize: 12, lineHeight: 1.4 }}>
            <span style={{ flexShrink: 0, marginTop: 1, display: "flex" }}><Lock size={16} /></span>
            <span>
              <strong>Regra anti-fura-fila:</strong> cada pessoa escaneia a quadra para entrar no
              grupo. Sem o PIN, quem abriu a vaga precisa aceitar o seu pedido.
            </span>
          </div>

          {groups.length === 0 && (
            <span style={{ padding: 12, fontSize: 13, color: "var(--green)" }}>
              Nenhum grupo nesta quadra ainda.
            </span>
          )}

          {groups.map((group) => (
            <div
              key={group.entryId}
              style={{ display: "flex", alignItems: "center", gap: 12, minHeight: 60, padding: "8px 10px 8px 12px", borderRadius: 10, background: "var(--chalk)", border: "1.5px solid rgba(47,70,41,.2)" }}
            >
              <span style={{ display: "flex", color: "var(--green)" }}><Players size={20} /></span>
              <span style={{ display: "flex", flexDirection: "column", gap: 2, flexGrow: 1, minWidth: 0 }}>
                <span style={{ fontSize: 14, fontWeight: 700, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{group.label}</span>
                <span style={{ fontSize: 12, fontWeight: 600, color: "var(--green)" }}>{group.where} · {group.size}</span>
              </span>
              <button
                type="button"
                className="press"
                onClick={() => ask(group)}
                disabled={busy || expired}
                style={{ flexShrink: 0, minHeight: 44, padding: "0 12px", borderRadius: 8, fontSize: 13, fontWeight: 800, background: "var(--ocre)", color: "var(--ink)", border: "2px solid var(--ink)", opacity: busy || expired ? 0.5 : 1 }}
              >
                Pedir para entrar
              </button>
            </div>
          ))}
        </section>
      </div>

      {switchTo && (
        <SwitchQueuePrompt
          courtName={court.my_state.court_name ?? null}
          owner={switchTo.owner}
          viaPin={!switchTo.entryId}
          busy={busy}
          onCancel={() => setSwitchTo(null)}
          onConfirm={() => {
            const target = switchTo;
            setSwitchTo(null);
            if (target.entryId) ask(target, true);
            else enterWithPin(true);
          }}
        />
      )}
    </div>
  );
}

/**
 * O aviso de uma vaga por pessoa. Pelo PIN a entrada é na hora, então a
 * saída também; no pedido, a pessoa só sai da fila atual quando for
 * aceita — se for recusada, não perde nada.
 */
function SwitchQueuePrompt({
  courtName,
  owner,
  viaPin,
  busy,
  onCancel,
  onConfirm,
}: {
  courtName: string | null;
  owner: string;
  viaPin: boolean;
  busy: boolean;
  onCancel: () => void;
  onConfirm: () => void;
}) {
  return (
    <div
      role="alertdialog"
      aria-modal="true"
      aria-label="Sair da fila atual"
      onClick={(event) => { event.stopPropagation(); onCancel(); }}
      style={{ position: "absolute", inset: 0, zIndex: 30, display: "flex", alignItems: "center", justifyContent: "center", padding: 16, background: "rgba(10,14,11,.55)" }}
    >
      <div
        className="fade"
        onClick={(event) => event.stopPropagation()}
        style={{ display: "flex", flexDirection: "column", gap: 14, width: "100%", padding: 18, background: "var(--bg)", border: "2px solid var(--rust)", borderRadius: 14 }}
      >
        <span style={{ display: "flex", alignItems: "center", gap: 8, color: "var(--rust)", fontSize: 12, fontWeight: 800, letterSpacing: ".08em" }}>
          <Warn size={18} />
          UMA VAGA POR PESSOA
        </span>
        <span className="bb" style={{ fontSize: 28, lineHeight: 1 }}>Você já está numa fila</span>
        <span style={{ fontSize: 14, lineHeight: 1.45 }}>
          Você está <strong>{courtName ? `na fila da ${courtName}` : "em outra fila"}</strong>. Para entrar na fila
          {owner ? ` de ${owner}` : " deste grupo"}, você precisa sair da sua fila atual.{" "}
          {viaPin
            ? "Com o PIN a entrada é na hora, e você perde o lugar que tinha lá."
            : "Você só sai dela quando aceitarem o seu pedido — até lá, seu lugar continua guardado."}
        </span>
        <button
          type="button"
          className="press"
          disabled={busy}
          onClick={onConfirm}
          style={{ minHeight: 52, borderRadius: 10, fontSize: 15, fontWeight: 800, background: "var(--ocre)", color: "var(--ink)", border: "2px solid var(--ink)" }}
        >
          {viaPin ? "Sair da minha fila e entrar" : "Pedir para entrar"}
        </button>
        <button
          type="button"
          className="press"
          onClick={onCancel}
          style={{ minHeight: 48, borderRadius: 10, fontSize: 14, fontWeight: 700, background: "transparent", color: "var(--ink)", border: "1.5px solid rgba(10,14,11,.3)" }}
        >
          Continuar na minha fila
        </button>
      </div>
    </div>
  );
}

function ownerName(players: Player[]): string {
  const owner = players.find((player) => player.role === "owner") ?? players[0];
  return owner?.short_name ?? "seu amigo";
}

function teamLabel(players: Player[]): string {
  const names = players.slice(0, 2).map((player) => player.short_name).join(" + ");
  return players.length > 2 ? `${names} + ${players.length - 2}` : names || "Grupo";
}
