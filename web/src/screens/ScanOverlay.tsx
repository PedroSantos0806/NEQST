import { useEffect, useRef, useState } from "react";
import { Close, NfcIcon } from "../components/icons";
import { scanCourt } from "../lib/api";
import { getPosition, LocationError } from "../lib/geo";
import { nfcSupported, qrSupported, readNfcTag, ScanError, startQrScanner } from "../lib/scan";
import type { CourtScreen, ScanResult } from "../lib/types";

/**
 * A tela cheia de leitura do protótipo: abas QR/NFC, a moldura com os
 * cantos em ocre e a linha varrendo. A leitura é real — a câmera ou a
 * tag alimentam a Edge Function, que confere assinatura e proximidade
 * e devolve o token de 30 segundos.
 */
export function ScanOverlay({
  court,
  purpose,
  onRead,
  onClose,
}: {
  court: CourtScreen;
  purpose: "join" | "start";
  onRead: (result: ScanResult, method: "qr" | "nfc") => void;
  onClose: () => void;
}) {
  const methods = court.court.checkin_methods;
  const [method, setMethod] = useState<"qr" | "nfc">(methods[0] ?? "qr");
  const [error, setError] = useState<string | null>(null);
  const [working, setWorking] = useState(false);
  const videoRef = useRef<HTMLVideoElement>(null);
  const done = useRef(false);

  async function handlePayload(payload: string) {
    if (done.current) return;
    done.current = true;
    setWorking(true);
    setError(null);
    try {
      const position = await getPosition();
      const result = await scanCourt({
        payload,
        latitude: position.latitude,
        longitude: position.longitude,
        accuracy: position.accuracy,
        method,
        purpose,
      });

      if (result.court.id !== court.court.id) {
        throw new Error(`Este código é da ${result.court.name}, não desta quadra.`);
      }

      onRead(result, method);
    } catch (cause) {
      setError(
        cause instanceof LocationError || cause instanceof ScanError
          ? cause.message
          : (cause as Error).message,
      );
      done.current = false;
      setWorking(false);
    }
  }

  // Câmera
  useEffect(() => {
    if (method !== "qr" || working) return;
    const video = videoRef.current;
    if (!video) return;

    let scanner: { stop(): void } | null = null;
    let cancelled = false;

    startQrScanner(video, (value) => void handlePayload(value))
      .then((started) => {
        if (cancelled) started.stop();
        else scanner = started;
      })
      .catch((cause: ScanError) => setError(cause.message));

    return () => {
      cancelled = true;
      scanner?.stop();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [method, working]);

  // NFC
  useEffect(() => {
    if (method !== "nfc" || working) return;
    const controller = new AbortController();
    readNfcTag(controller.signal)
      .then((value) => void handlePayload(value))
      .catch((cause: ScanError) => setError(cause.message));
    return () => controller.abort();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [method, working]);

  const title = purpose === "start"
    ? method === "qr" ? "Check-in para jogar" : "Toque para jogar"
    : method === "qr" ? "Aponte para o QR" : "Aproxime do totem";

  const help = purpose === "start"
    ? method === "qr"
      ? "Escaneie o QR da quadra para confirmar que você chegou e liberar o placar."
      : "Encoste o celular na placa NFC da quadra para confirmar presença e iniciar o jogo."
    : method === "qr"
      ? "Enquadre o código fixado no poste da rede. A leitura é automática."
      : "Encoste o celular na placa NFC ao lado do banco da quadra.";

  return (
    <div
      className="fade"
      role="dialog"
      aria-modal="true"
      aria-label="Check-in na quadra"
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
        gap: 22,
        padding: "18px 20px 28px",
        background: "var(--ink)",
        color: "var(--chalk)",
        overflowY: "auto",
      }}
    >
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
        <span className="bb" style={{ fontSize: 28, lineHeight: 1 }}>
          {purpose === "start" ? "Check-in · início de jogo" : "Check-in"}
        </span>
        <button
          type="button"
          className="press"
          onClick={onClose}
          aria-label="Fechar"
          style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            width: 44,
            height: 44,
            flexShrink: 0,
            background: "transparent",
            color: "var(--chalk)",
            border: "1.5px solid rgba(241,236,239,.4)",
            borderRadius: 10,
          }}
        >
          <Close size={20} />
        </button>
      </div>

      {methods.length > 1 && (
        <div style={{ display: "grid", gridTemplateColumns: "repeat(2, minmax(0, 1fr))", padding: 4, background: "rgba(241,236,239,.1)", borderRadius: 10 }}>
          {(["qr", "nfc"] as const).map((option) => (
            <button
              key={option}
              type="button"
              className="press"
              onClick={() => { setMethod(option); setError(null); }}
              aria-pressed={method === option}
              style={{
                minHeight: 44,
                border: 0,
                borderRadius: 8,
                fontSize: 14,
                fontWeight: 700,
                background: method === option ? "var(--chalk)" : "transparent",
                color: method === option ? "var(--ink)" : "var(--chalk)",
              }}
            >
              {option === "qr" ? "QR Code" : "NFC"}
            </button>
          ))}
        </div>
      )}

      <div style={{ flexGrow: 1, display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center", gap: 22 }}>
        {method === "qr"
          ? (
            <div style={{ position: "relative", width: 250, height: 250, borderRadius: 12, background: "#16211A", overflow: "hidden" }}>
              <video
                ref={videoRef}
                muted
                playsInline
                style={{ position: "absolute", inset: 0, width: "100%", height: "100%", objectFit: "cover", opacity: qrSupported() ? 1 : 0 }}
              />
              {/* O desenho apagado atrás da câmera, como no protótipo. */}
              <svg
                width="130"
                height="130"
                viewBox="0 0 24 24"
                fill="none"
                stroke="rgba(241,236,239,.28)"
                strokeWidth="1.4"
                aria-hidden="true"
                style={{ position: "absolute", left: 60, top: 60 }}
              >
                <rect x="3" y="3" width="7" height="7" rx="1" />
                <rect x="14" y="3" width="7" height="7" rx="1" />
                <rect x="3" y="14" width="7" height="7" rx="1" />
                <path d="M14 14h3v3M21 14v.01M14 21h7M18 18h3M5.5 5.5h2v2h-2zM16.5 5.5h2v2h-2zM5.5 16.5h2v2h-2z" />
              </svg>
              <Corner top left />
              <Corner top />
              <Corner left />
              <Corner />
              <span className="scanline" aria-hidden="true" />
              {!qrSupported() && (
                <p style={{ position: "absolute", inset: 20, display: "grid", placeItems: "center", margin: 0, textAlign: "center", fontSize: 13, lineHeight: 1.45, color: "var(--mauve)" }}>
                  Este navegador não dá acesso à câmera. Aponte a câmera do próprio celular para o
                  QR da quadra — ele abre o NEQST direto.
                </p>
              )}
            </div>
          )
          : (
            <div style={{ position: "relative", width: 250, height: 250, display: "flex", alignItems: "center", justifyContent: "center" }}>
              <span className="wave" aria-hidden="true" />
              <span className="wave w2" aria-hidden="true" />
              <span className="wave w3" aria-hidden="true" />
              <span style={{ display: "flex", alignItems: "center", justifyContent: "center", width: 96, height: 96, background: "var(--ocre)", color: "var(--ink)", borderRadius: 14 }}>
                <NfcIcon size={44} />
              </span>
              {!nfcSupported() && (
                <p style={{ position: "absolute", bottom: 0, left: 0, right: 0, margin: 0, textAlign: "center", fontSize: 13, color: "var(--mauve)" }}>
                  Este navegador não lê NFC. Use o QR Code.
                </p>
              )}
            </div>
          )}

        <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 6, textAlign: "center" }}>
          <span className="bb" style={{ fontSize: 30, lineHeight: 1 }}>{title}</span>
          <span style={{ fontSize: 14, lineHeight: 1.45, color: "var(--mauve)", maxWidth: 280 }}>{help}</span>
        </div>

        <span style={{ display: "flex", alignItems: "center", gap: 8, padding: "6px 10px", border: "1px solid rgba(241,236,239,.3)", borderRadius: 6, fontSize: 12, fontWeight: 600, color: "var(--mauve)" }}>
          <span className="dot" style={{ background: "var(--ocre)" }} />
          {working ? "Conferindo que você está na quadra…" : `Procurando ${court.court.name}…`}
        </span>
      </div>

      {error
        ? (
          <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
            <p role="alert" style={{ margin: 0, fontSize: 13, lineHeight: 1.4, color: "var(--ocre)" }}>{error}</p>
            <button
              type="button"
              className="press"
              onClick={() => { setError(null); done.current = false; }}
              style={{ minHeight: 52, background: "transparent", color: "var(--chalk)", border: "1.5px solid rgba(241,236,239,.6)", borderRadius: 10, fontSize: 15, fontWeight: 700 }}
            >
              Tentar de novo
            </button>
          </div>
        )
        : (
          <p style={{ margin: 0, textAlign: "center", fontSize: 12, lineHeight: 1.45, color: "var(--mauve)" }}>
            A leitura precisa da sua localização: é ela que prova que você está na quadra.
          </p>
        )}
    </div>
  );
}

/** Um dos quatro cantos em ocre da moldura de leitura. */
function Corner({ top, left }: { top?: boolean; left?: boolean }) {
  return (
    <span
      aria-hidden="true"
      style={{
        position: "absolute",
        width: 42,
        height: 42,
        [top ? "top" : "bottom"]: 0,
        [left ? "left" : "right"]: 0,
        [top ? "borderTop" : "borderBottom"]: "4px solid var(--ocre)",
        [left ? "borderLeft" : "borderRight"]: "4px solid var(--ocre)",
        borderRadius: top && left ? "12px 0 0 0"
          : top ? "0 12px 0 0"
          : left ? "0 0 0 12px"
          : "0 0 12px 0",
      }}
    />
  );
}
