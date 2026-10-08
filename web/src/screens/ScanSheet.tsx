import { useEffect, useRef, useState } from "react";
import { Sheet, Spinner, buttonStyle } from "../components/ui";
import { checkIn, joinQueue, scanCourt, searchPartners } from "../lib/api";
import { getPosition, LocationError } from "../lib/geo";
import { nfcSupported, qrSupported, readNfcTag, ScanError, startQrScanner } from "../lib/scan";
import type { CourtScreen, PartnerCandidate, QueueMode } from "../lib/types";

type Step = "scan" | "mode" | "working";

/**
 * O check-in do protótipo: escanear o QR (ou encostar no totem) e, em
 * seguida, escolher a modalidade. O scan token vale 30 segundos, então
 * a escolha de modalidade vem DEPOIS da leitura — e só então entramos
 * na fila, para o token não vencer durante a busca do parceiro.
 */
export function ScanSheet({
  court,
  purpose,
  onClose,
  onDone,
}: {
  court: CourtScreen;
  purpose: "join" | "start";
  onClose: () => void;
  onDone: (message: string) => Promise<void> | void;
}) {
  const methods = court.court.checkin_methods;
  const [method, setMethod] = useState<"qr" | "nfc">(methods[0] ?? "qr");
  const [step, setStep] = useState<Step>("scan");
  const [error, setError] = useState<string | null>(null);
  const [scanToken, setScanToken] = useState<string | null>(null);
  const [mode, setMode] = useState<QueueMode>("single");
  const [partner, setPartner] = useState<PartnerCandidate | null>(null);
  const [query, setQuery] = useState("");
  const [candidates, setCandidates] = useState<PartnerCandidate[]>([]);
  const videoRef = useRef<HTMLVideoElement>(null);
  const abortRef = useRef<AbortController | null>(null);

  // Leitura do payload (câmera ou NFC) → valida no backend → scan token.
  async function handlePayload(payload: string) {
    setStep("working");
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
        setError(`Este código é da ${result.court.name}, não desta quadra.`);
        setStep("scan");
        return;
      }

      if (purpose === "start") {
        await checkIn(result.scanToken, court.match?.side_b.open ? "open" : "auto");
        await onDone("Check-in confirmado. Bom jogo!");
        return;
      }

      setScanToken(result.scanToken);
      setStep("mode");
    } catch (cause) {
      setError(
        cause instanceof LocationError || cause instanceof ScanError
          ? cause.message
          : (cause as Error).message,
      );
      setStep("scan");
    }
  }

  // Câmera
  useEffect(() => {
    if (step !== "scan" || method !== "qr") return;
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
  }, [step, method]);

  // NFC
  useEffect(() => {
    if (step !== "scan" || method !== "nfc") return;
    const controller = new AbortController();
    abortRef.current = controller;

    readNfcTag(controller.signal)
      .then((value) => void handlePayload(value))
      .catch((cause: ScanError) => setError(cause.message));

    return () => controller.abort();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [step, method]);

  // Busca de parceiro
  useEffect(() => {
    if (step !== "mode" || mode !== "double") return;
    const id = setTimeout(() => {
      void searchPartners(query).then(setCandidates).catch(() => setCandidates([]));
    }, 250);
    return () => clearTimeout(id);
  }, [step, mode, query]);

  async function confirm() {
    if (!scanToken) return;
    setStep("working");
    setError(null);
    try {
      await joinQueue({
        scanToken,
        mode,
        partner: mode === "double" ? partner?.handle ?? null : null,
      });
      if (navigator.vibrate) navigator.vibrate([18, 40, 24]);
      await onDone("Você entrou na fila.");
    } catch (cause) {
      setError((cause as Error).message);
      setStep("mode");
    }
  }

  const title = purpose === "start" ? "Check-in para jogar" : "Entrar na fila";

  return (
    <Sheet title={title} onClose={onClose}>
      {error && (
        <p role="alert" style={{ margin: "0 0 12px", padding: "10px 12px", borderRadius: 8, fontSize: 13, lineHeight: 1.4, background: "rgba(177,63,22,.1)", color: "var(--rust)" }}>
          {error}
        </p>
      )}

      {step === "working" && (
        <div style={{ display: "flex", alignItems: "center", gap: 10, padding: 20 }}>
          <Spinner />
          <span style={{ fontSize: 14, fontWeight: 600 }}>Confirmando que você está na quadra…</span>
        </div>
      )}

      {step === "scan" && (
        <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
          {methods.length > 1 && (
            <div style={{ display: "flex", gap: 6, padding: 4, background: "var(--green)", borderRadius: 10 }}>
              {methods.map((option) => (
                <button
                  key={option}
                  type="button"
                  onClick={() => { setMethod(option); setError(null); }}
                  className="press tap"
                  style={{
                    flex: 1,
                    borderRadius: 8,
                    border: "none",
                    fontSize: 13,
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

          <p style={{ margin: 0, fontSize: 14, lineHeight: 1.45, color: "var(--green)" }}>
            {method === "qr"
              ? "Enquadre o código fixado no poste da rede. A leitura é automática."
              : "Encoste o celular na placa NFC ao lado do banco da quadra."}
          </p>

          {method === "qr"
            ? (
              <div style={{ position: "relative", borderRadius: 12, overflow: "hidden", background: "var(--ink)", aspectRatio: "1 / 1" }}>
                <video ref={videoRef} muted playsInline style={{ width: "100%", height: "100%", objectFit: "cover" }} />
                <span className="scanline" aria-hidden="true" />
                {!qrSupported() && (
                  <p style={{ position: "absolute", inset: 0, display: "grid", placeItems: "center", margin: 0, padding: 20, textAlign: "center", color: "var(--chalk)", fontSize: 14 }}>
                    Este navegador não dá acesso à câmera. Aponte a câmera do celular para o QR
                    Code da quadra — ele abre o app direto.
                  </p>
                )}
              </div>
            )
            : (
              <div style={{ position: "relative", display: "grid", placeItems: "center", height: 220, borderRadius: 12, background: "var(--ink)" }}>
                <span style={{ position: "relative", width: 90, height: 90, display: "grid", placeItems: "center" }}>
                  <span className="wave" aria-hidden="true" />
                  <span className="wave w2" aria-hidden="true" />
                  <span className="wave w3" aria-hidden="true" />
                  <svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke="var(--chalk)" strokeWidth="2" strokeLinecap="round" aria-hidden="true">
                    <path d="M5 8a9 9 0 0 1 0 8M9 6a13 13 0 0 1 0 12M13 4a17 17 0 0 1 0 16" />
                  </svg>
                </span>
                {!nfcSupported() && (
                  <p style={{ position: "absolute", bottom: 14, left: 14, right: 14, margin: 0, textAlign: "center", color: "var(--chalk)", fontSize: 13 }}>
                    Este navegador não lê NFC. Use o QR Code.
                  </p>
                )}
              </div>
            )}
        </div>
      )}

      {step === "mode" && (
        <div style={{ display: "flex", flexDirection: "column", gap: 14 }}>
          <div style={{ display: "flex", gap: 8 }}>
            {(["single", "double"] as const).map((option) => (
              <button
                key={option}
                type="button"
                onClick={() => { setMode(option); if (option === "single") setPartner(null); }}
                className="press"
                style={{
                  flex: 1,
                  minHeight: 48,
                  borderRadius: 10,
                  fontSize: 14,
                  fontWeight: 700,
                  background: mode === option ? "var(--green)" : "var(--chalk)",
                  color: mode === option ? "var(--chalk)" : "var(--ink)",
                  border: mode === option ? "2px solid var(--green)" : "1.5px solid rgba(47,70,41,.35)",
                }}
              >
                {option === "single" ? "Individual" : "Dupla (2x2)"}
              </button>
            ))}
          </div>

          {mode === "double" && (
            <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
              <label style={{ display: "flex", flexDirection: "column", gap: 6 }}>
                <span style={{ fontSize: 13, fontWeight: 700, color: "var(--green)" }}>Parceiro</span>
                <input
                  value={query}
                  onChange={(event) => setQuery(event.target.value)}
                  placeholder="Nome ou @username"
                  style={{ minHeight: 48, padding: "12px 14px", background: "var(--chalk)", border: "1.5px solid rgba(47,70,41,.3)", borderRadius: 10, fontSize: 15 }}
                />
              </label>

              <div style={{ display: "flex", flexDirection: "column", gap: 6, maxHeight: 220, overflowY: "auto" }} className="scroll">
                {candidates.length === 0 && (
                  <p style={{ margin: 0, fontSize: 13, color: "var(--muted)" }}>Nenhum jogador encontrado.</p>
                )}
                {candidates.map((candidate) => {
                  const selected = partner?.user_id === candidate.user_id;
                  return (
                    <button
                      key={candidate.user_id}
                      type="button"
                      disabled={!candidate.available}
                      onClick={() => setPartner(selected ? null : candidate)}
                      className="press"
                      style={{
                        display: "flex",
                        alignItems: "center",
                        gap: 10,
                        minHeight: 56,
                        padding: "8px 10px",
                        borderRadius: 10,
                        textAlign: "left",
                        background: selected ? "var(--green)" : candidate.available ? "var(--chalk)" : "transparent",
                        color: selected ? "var(--chalk)" : candidate.available ? "var(--ink)" : "var(--muted)",
                        border: selected
                          ? "2px solid var(--green)"
                          : candidate.available
                          ? "1.5px solid rgba(47,70,41,.2)"
                          : "1.5px dashed rgba(10,14,11,.35)",
                      }}
                    >
                      <span
                        style={{
                          width: 36,
                          height: 36,
                          display: "grid",
                          placeItems: "center",
                          borderRadius: 8,
                          fontSize: 13,
                          fontWeight: 700,
                          background: selected ? "var(--ocre)" : candidate.available ? "var(--green)" : "rgba(10,14,11,.1)",
                          color: selected ? "var(--ink)" : candidate.available ? "var(--chalk)" : "var(--muted)",
                        }}
                      >
                        {candidate.initials}
                      </span>
                      <span style={{ display: "flex", flexDirection: "column", minWidth: 0 }}>
                        <span style={{ fontSize: 14, fontWeight: 700 }}>{candidate.full_name ?? candidate.handle}</span>
                        <span style={{ fontSize: 12 }}>
                          {candidate.available ? `Disponível · ${candidate.handle}` : `${candidate.where} — indisponível`}
                        </span>
                      </span>
                    </button>
                  );
                })}
              </div>
            </div>
          )}

          <div style={{ display: "flex", alignItems: "baseline", justifyContent: "space-between", fontSize: 13, fontWeight: 700, color: "var(--green)" }}>
            <span>Sua posição: {court.next_position_label}</span>
            <span>Entra em ~{Math.max(1, Math.ceil(court.total_wait_seconds / 60))} min</span>
          </div>

          <button
            type="button"
            className="press"
            disabled={mode === "double" && !partner}
            onClick={() => void confirm()}
            style={buttonStyle("primary", mode === "double" && !partner)}
          >
            {mode === "double" && !partner ? "Escolha um parceiro" : "Confirmar entrada"}
          </button>
        </div>
      )}
    </Sheet>
  );
}
