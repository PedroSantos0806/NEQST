import { useEffect, useState } from "react";
import { Arrow, Check, Close, Lock, Search, Warn } from "../components/icons";
import { joinQueue, searchPartners } from "../lib/api";
import { SURFACE_COLOR, eta, mmss, surfaceTextColor } from "../lib/format";
import type { CourtScreen, PartnerCandidate, QueueMode, ScanResult } from "../lib/types";

/**
 * A folha "entrar na fila" do protótipo: check-in já confirmado,
 * escolha da modalidade, busca do parceiro e a posição prevista.
 *
 * A ordem importa: o token do scan vale 30 segundos, mas o relógio só
 * aperta no envio — por isso a escolha vem depois da leitura, e o
 * join sai de uma vez quando o jogador confirma.
 */
export function JoinSheet({
  court,
  scan,
  method,
  onClose,
  onJoined,
}: {
  court: CourtScreen;
  scan: ScanResult;
  method: "qr" | "nfc";
  onClose: () => void;
  onJoined: () => Promise<void> | void;
}) {
  const [mode, setMode] = useState<QueueMode>("double");
  const [query, setQuery] = useState("");
  const [partner, setPartner] = useState<PartnerCandidate | null>(null);
  const [candidates, setCandidates] = useState<PartnerCandidate[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (mode !== "double") return;
    const id = setTimeout(() => {
      void searchPartners(query).then(setCandidates).catch(() => setCandidates([]));
    }, 250);
    return () => clearTimeout(id);
  }, [mode, query]);

  const blocked = !court.can_join;
  const needPartner = mode === "double" && !partner;
  const cannotConfirm = blocked || needPartner || busy;

  const board = SURFACE_COLOR[court.court.surface] ?? "var(--green)";
  const boardText = surfaceTextColor(court.court.surface);
  const elapsed = court.match?.is_live
    ? Math.max(0, Math.floor((Date.now() - new Date(court.match.started_at).getTime()) / 1000))
    : 0;

  async function confirm() {
    if (cannotConfirm) return;
    setBusy(true);
    setError(null);
    try {
      await joinQueue({
        scanToken: scan.scanToken,
        mode,
        partner: mode === "double" ? partner?.handle ?? null : null,
      });
      if (navigator.vibrate) navigator.vibrate([18, 40, 24]);
      await onJoined();
    } catch (cause) {
      setError((cause as Error).message);
      setBusy(false);
    }
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
            style={{
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
              flexShrink: 0,
              width: 44,
              height: 44,
              background: "transparent",
              color: "var(--ink)",
              border: "1.5px solid rgba(10,14,11,.3)",
              borderRadius: 10,
            }}
          >
            <Close size={20} />
          </button>
        </div>

        <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "10px 12px", borderRadius: 10, background: board, color: boardText }}>
          <span className="bb" style={{ fontSize: 26, lineHeight: 1 }}>{mmss(elapsed)}</span>
          <span style={{ fontSize: 13, fontWeight: 600 }}>{court.status_text} · {court.queue_text}</span>
        </div>

        {blocked && (
          <div style={{ display: "flex", alignItems: "flex-start", gap: 10, padding: 12, background: "var(--chalk)", border: "1.5px solid var(--rust)", borderRadius: 10, fontSize: 13, lineHeight: 1.4 }}>
            <span style={{ color: "var(--rust)", flexShrink: 0, display: "flex" }}><Warn size={20} /></span>
            <span>
              <strong>{court.my_state.where ?? "Você não pode entrar nesta fila agora."}</strong>{" "}
              {court.my_state.state !== "free" ? "Uma fila por vez — saia da atual para entrar aqui." : ""}
            </span>
          </div>
        )}

        <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
          <span style={{ fontSize: 13, fontWeight: 700 }}>Modalidade</span>
          <div style={{ display: "grid", gridTemplateColumns: "repeat(2, minmax(0, 1fr))", gap: 10 }}>
            <ModeCard
              label="Simples"
              big="1x1"
              selected={mode === "single"}
              onClick={() => { setMode("single"); setPartner(null); }}
            />
            <ModeCard
              label="Duplas"
              big="2x2"
              selected={mode === "double"}
              onClick={() => setMode("double")}
            />
          </div>
        </div>

        {mode === "double" && (
          <div className="fade" style={{ display: "flex", flexDirection: "column", gap: 10 }}>
            <label htmlFor="partner-q" style={{ fontSize: 13, fontWeight: 700 }}>Parceiro de jogo</label>
            <div style={{ position: "relative" }}>
              <span style={{ position: "absolute", left: 14, top: 15, color: "var(--green)", display: "flex" }}>
                <Search size={18} />
              </span>
              <input
                id="partner-q"
                type="search"
                placeholder="Buscar por nome ou @usuário"
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                style={{ width: "100%", height: 48, padding: "0 14px 0 42px", background: "var(--chalk)", border: "1.5px solid rgba(47,70,41,.35)", borderRadius: 8, fontSize: 15, color: "var(--ink)" }}
              />
            </div>

            <div style={{ display: "flex", alignItems: "flex-start", gap: 8, padding: "10px 12px", background: "rgba(47,70,41,.08)", borderRadius: 8, fontSize: 12, lineHeight: 1.4 }}>
              <span style={{ flexShrink: 0, marginTop: 1, display: "flex" }}><Lock size={16} /></span>
              <span>
                <strong>Regra anti-fura-fila:</strong> parceiros que já estão em jogo ou em outra
                fila não podem ser adicionados.
              </span>
            </div>

            <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
              {candidates.map((candidate) => (
                <PartnerRow
                  key={candidate.user_id}
                  candidate={candidate}
                  selected={partner?.user_id === candidate.user_id}
                  onPick={() =>
                    setPartner(partner?.user_id === candidate.user_id ? null : candidate)}
                />
              ))}
              {candidates.length === 0 && (
                <span style={{ padding: 12, fontSize: 13, color: "var(--green)" }}>
                  Nenhum jogador encontrado.
                </span>
              )}
            </div>
          </div>
        )}

        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", padding: "12px 0 0", borderTop: "1px dashed rgba(47,70,41,.35)" }}>
          <span style={{ fontSize: 13, fontWeight: 600, color: "var(--green)" }}>Sua posição prevista</span>
          <span style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
            <span className="bb" style={{ fontSize: 30, lineHeight: 1 }}>{court.next_position_label}</span>
            <span style={{ fontSize: 13, fontWeight: 600 }}>em {eta(court.total_wait_seconds)}</span>
          </span>
        </div>

        {error && (
          <p role="alert" style={{ margin: 0, padding: "10px 12px", borderRadius: 8, fontSize: 13, lineHeight: 1.4, background: "rgba(177,63,22,.1)", color: "var(--rust)" }}>
            {error}
          </p>
        )}

        <button
          type="button"
          className="press"
          onClick={() => void confirm()}
          disabled={cannotConfirm}
          style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            gap: 10,
            width: "100%",
            minHeight: 58,
            borderRadius: 10,
            fontSize: 16,
            fontWeight: 800,
            ...(cannotConfirm
              ? { background: "var(--mauve)", color: "var(--muted)", border: "2px solid transparent" }
              : { background: "var(--ocre)", color: "var(--ink)", border: "2px solid var(--ink)" }),
          }}
        >
          {busy ? "Entrando na fila…" : "Confirmar e Entrar na Fila"}
          {!busy && <Arrow size={20} />}
        </button>

        {needPartner && !blocked && (
          <span style={{ marginTop: -8, textAlign: "center", fontSize: 12, fontWeight: 600, color: "var(--green)" }}>
            Escolha um parceiro disponível para continuar.
          </span>
        )}
      </div>
    </div>
  );
}

function ModeCard({
  label,
  big,
  selected,
  onClick,
}: {
  label: string;
  big: string;
  selected: boolean;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      className="press"
      onClick={onClick}
      aria-pressed={selected}
      style={{
        display: "flex",
        flexDirection: "column",
        alignItems: "flex-start",
        gap: 2,
        minHeight: 76,
        padding: "10px 12px",
        borderRadius: 10,
        textAlign: "left",
        ...(selected
          ? { background: "var(--green)", color: "var(--chalk)", border: "2px solid var(--green)" }
          : { background: "var(--chalk)", color: "var(--ink)", border: "1.5px solid rgba(47,70,41,.35)" }),
      }}
    >
      <span style={{ display: "flex", alignItems: "center", justifyContent: "space-between", width: "100%", fontSize: 14, fontWeight: 700 }}>
        {label}
        {selected && <span style={{ color: "var(--ocre)", display: "flex" }}><Check size={18} /></span>}
      </span>
      <span className="bb" style={{ fontSize: 30, lineHeight: 1 }}>{big}</span>
    </button>
  );
}

function PartnerRow({
  candidate,
  selected,
  onPick,
}: {
  candidate: PartnerCandidate;
  selected: boolean;
  onPick: () => void;
}) {
  const blocked = !candidate.available;

  const row = selected
    ? { background: "var(--green)", color: "var(--chalk)", border: "2px solid var(--green)" }
    : blocked
      ? { background: "transparent", color: "var(--muted)", border: "1.5px dashed rgba(10,14,11,.35)" }
      : { background: "var(--chalk)", color: "var(--ink)", border: "1.5px solid rgba(47,70,41,.2)" };

  const avatar = blocked
    ? { background: "rgba(10,14,11,.1)", color: "var(--muted)" }
    : selected
      ? { background: "var(--ocre)", color: "var(--ink)" }
      : { background: "var(--green)", color: "var(--chalk)" };

  return (
    <button
      type="button"
      className="press"
      onClick={onPick}
      disabled={blocked}
      aria-pressed={selected}
      style={{
        display: "flex",
        alignItems: "center",
        gap: 12,
        width: "100%",
        minHeight: 56,
        padding: "8px 12px",
        borderRadius: 10,
        textAlign: "left",
        ...row,
      }}
    >
      <span className="bb" style={{ display: "flex", alignItems: "center", justifyContent: "center", flexShrink: 0, width: 36, height: 36, borderRadius: 8, fontSize: 18, ...avatar }}>
        {candidate.initials}
      </span>
      <span style={{ display: "flex", flexDirection: "column", gap: 2, flexGrow: 1, minWidth: 0 }}>
        <span style={{ fontSize: 14, fontWeight: 700 }}>{candidate.full_name ?? candidate.handle}</span>
        <span style={{ display: "flex", alignItems: "center", gap: 5, fontSize: 12, fontWeight: 600 }}>
          {blocked
            ? <Lock size={12} strokeWidth="2.4" />
            : <span style={{ width: 8, height: 8, borderRadius: "50%", background: "var(--sage)", border: "1.5px solid currentColor" }} />}
          {blocked ? `${candidate.where} — indisponível` : `Disponível · ${candidate.handle}`}
        </span>
      </span>
      {selected && <span style={{ color: "var(--sage)", display: "flex" }}><Check size={20} /></span>}
    </button>
  );
}
