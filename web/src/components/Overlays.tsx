/**
 * As telas cheias do protótipo: entrou na fila, chamaram você, o jogo
 * começou. São momentos — aparecem, dizem uma coisa só e saem.
 */
import type { CSSProperties } from "react";
import { Racket, stackStyle } from "./Racket";
import { Check, ScanFrame } from "./icons";
import { mmss } from "../lib/format";
import type { Racket as RacketColors } from "../lib/types";

const CENTERED: CSSProperties = {
  position: "fixed",
  left: "50%",
  transform: "translateX(-50%)",
  top: 0,
  bottom: 0,
  width: "100%",
  maxWidth: 480,
};

/** Entrou na fila: a raquete cai no topo da pilha. */
export function SuccessOverlay({
  stack,
  positionLabel,
  courtName,
  eta,
}: {
  stack: RacketColors[];
  positionLabel: string;
  courtName: string;
  eta: string;
}) {
  return (
    <div
      className="fade"
      role="status"
      aria-live="polite"
      style={{
        ...CENTERED,
        zIndex: 30,
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        gap: 26,
        padding: 24,
        background: "var(--green)",
        color: "var(--chalk)",
        textAlign: "center",
      }}
    >
      <div style={{ position: "relative", width: 198, height: 150 }}>
        <span className="ring" aria-hidden="true" />
        <div
          style={{
            position: "absolute",
            left: 0,
            top: 0,
            width: 88,
            height: 66,
            transform: "scale(2.25)",
            transformOrigin: "0 0",
            background: "var(--ink)",
            borderRadius: 6,
            overflow: "hidden",
          }}
        >
          <span style={{ position: "absolute", left: 6, right: 6, bottom: 5, height: 2, background: "rgba(241,236,239,.35)" }} />
          {stack.map((racket, index) => (
            <span
              key={index}
              className={index === stack.length - 1 ? "drop" : undefined}
              style={stackStyle(index)}
            >
              <Racket frame={racket.frame} grip={racket.grip} face="#0A0E0B" />
            </span>
          ))}
        </div>
      </div>

      <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 8 }}>
        <Chip>
          <Check size={14} />
          RAQUETE NA PILHA
        </Chip>
        <span className="bb" style={{ fontSize: 54, lineHeight: 0.9 }}>Você está na fila</span>
        <span style={{ fontSize: 15, fontWeight: 600 }}>
          {positionLabel} na {courtName} · previsão {eta}
        </span>
      </div>

      <span style={{ fontSize: 12, color: "var(--mauve)" }}>Voltando ao placar…</span>
    </div>
  );
}

/** Check-in feito: o cronômetro zera e o jogo começa. */
export function StartedOverlay({
  courtName,
  background,
  color,
}: {
  courtName: string;
  background: string;
  color: string;
}) {
  return (
    <div
      className="fade"
      role="status"
      aria-live="polite"
      style={{
        ...CENTERED,
        zIndex: 30,
        display: "flex",
        flexDirection: "column",
        alignItems: "center",
        justifyContent: "center",
        gap: 20,
        padding: 24,
        textAlign: "center",
        background,
        color,
      }}
    >
      <Chip>
        <Check size={14} />
        CHECK-IN CONFIRMADO
      </Chip>
      <div style={{ position: "relative", width: 260, height: 34, borderBottom: "2px solid rgba(255,255,255,.6)" }} aria-hidden="true">
        <span className="ball rally" />
      </div>
      <span className="bb" style={{ fontSize: 110, lineHeight: 0.85 }}>00:00</span>
      <span className="bb" style={{ fontSize: 44, lineHeight: 0.9 }}>Jogo iniciado</span>
      <span style={{ fontSize: 15, fontWeight: 600 }}>{courtName} · bom jogo!</span>
    </div>
  );
}

/** Chamaram o seu time: a quadra liberou e o relógio do check-in corre. */
export function CallOverlay({
  courtName,
  parkName,
  secondsLeft,
  modeLabel,
  onCheckIn,
  onLater,
}: {
  courtName: string;
  parkName: string;
  secondsLeft: number;
  modeLabel: string;
  onCheckIn: () => void;
  onLater: () => void;
}) {
  return (
    <div
      className="fade"
      role="alertdialog"
      aria-modal="true"
      aria-label="Sua vez de jogar"
      style={{
        ...CENTERED,
        zIndex: 25,
        display: "flex",
        flexDirection: "column",
        gap: 22,
        padding: "28px 20px 26px",
        background: "var(--green)",
        color: "var(--chalk)",
        overflowY: "auto",
      }}
    >
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
        <Chip>
          <span className="dot" />
          SUA VEZ
        </Chip>
        <span style={{ fontSize: 12, fontWeight: 600, color: "var(--mauve)" }}>{parkName}</span>
      </div>

      <div style={{ position: "relative", height: 34, borderBottom: "2px solid rgba(241,236,239,.5)" }} aria-hidden="true">
        <span className="ball rally" />
      </div>

      <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        <span className="bb" style={{ fontSize: 64, lineHeight: 0.86 }}>{courtName} liberada</span>
        <span style={{ fontSize: 15, lineHeight: 1.45 }}>
          A partida anterior acabou e você é o 1º da fila. Vá até a quadra e faça o check-in por
          QR ou NFC para iniciar o seu jogo.
        </span>
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "repeat(2, minmax(0, 1fr))", border: "1.5px solid rgba(241,236,239,.35)", borderRadius: 10 }}>
        <div style={{ display: "flex", flexDirection: "column", gap: 2, padding: 12, borderRight: "1.5px solid rgba(241,236,239,.35)" }}>
          <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: ".1em", color: "var(--mauve)" }}>TEMPO PARA CONFIRMAR</span>
          <span className="bb" role="timer" style={{ fontSize: 44, lineHeight: 1 }}>{mmss(secondsLeft)}</span>
        </div>
        <div style={{ display: "flex", flexDirection: "column", gap: 2, padding: 12 }}>
          <span style={{ fontSize: 10, fontWeight: 700, letterSpacing: ".1em", color: "var(--mauve)" }}>MODALIDADE</span>
          <span style={{ fontSize: 14, fontWeight: 700, lineHeight: 1.3 }}>{modeLabel}</span>
        </div>
      </div>

      {secondsLeft === 0 && (
        <div style={{ display: "flex", alignItems: "center", gap: 8, padding: "10px 12px", background: "var(--chalk)", color: "var(--ink)", border: "1.5px solid var(--rust)", borderRadius: 8, fontSize: 13, fontWeight: 600 }}>
          <span style={{ color: "var(--rust)", display: "flex" }}>
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
              <path d="M12 3l10 18H2z" />
              <path d="M12 10v5M12 18h.01" />
            </svg>
          </span>
          Tempo esgotado — confirme agora ou a vez passa para o próximo.
        </div>
      )}

      <span style={{ flexGrow: 1 }} />

      <button
        type="button"
        className="press"
        onClick={onCheckIn}
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          gap: 10,
          width: "100%",
          minHeight: 60,
          background: "var(--ocre)",
          color: "var(--ink)",
          border: "2px solid var(--ink)",
          borderRadius: 10,
          fontSize: 17,
          fontWeight: 800,
        }}
      >
        <ScanFrame size={22} />
        Fazer check-in e iniciar jogo
      </button>
      <button
        type="button"
        className="press"
        onClick={onLater}
        style={{
          minHeight: 48,
          background: "transparent",
          color: "var(--chalk)",
          border: "1.5px solid rgba(241,236,239,.5)",
          borderRadius: 10,
          fontSize: 14,
          fontWeight: 700,
        }}
      >
        Estou a caminho — ver placar
      </button>
    </div>
  );
}

function Chip({ children }: { children: React.ReactNode }) {
  return (
    <span
      style={{
        display: "flex",
        alignItems: "center",
        gap: 6,
        padding: "5px 10px",
        background: "var(--ocre)",
        color: "var(--ink)",
        borderRadius: 6,
        fontSize: 12,
        fontWeight: 800,
        letterSpacing: ".1em",
      }}
    >
      {children}
    </span>
  );
}
