/**
 * A fila com anfitrião (Sprint 5): o piloto sem nada colado na placa.
 *
 *   HostOpenSheet  a primeira pessoa com o app abre a fila e conta o que
 *                  já existia: quem está jogando e quem espera sem app
 *   InviteQr       o QR na tela de quem está na fila, para quem chegou
 *   HostPanel      quem organiza anda com as vagas sem app
 *
 * A presença continua provada pelo GPS contra a coordenada da quadra.
 * O QR só entrega o convite.
 */
import { useEffect, useRef, useState, type ReactNode } from "react";
import { confirmAtCourt, hostAddOffline, hostMarkOffline, issueHostInvite, openHostQueue } from "../lib/api";
import { LocationError } from "../lib/geo";
import { mmss } from "../lib/format";
import { buttonStyle } from "../components/ui";
import { Close, Players, QrIcon } from "../components/icons";
import type { CourtScreen, QueueItem } from "../lib/types";

const MAX_WAITING = 10;

const field = {
  width: "100%",
  height: 44,
  padding: "0 12px",
  background: "var(--chalk)",
  border: "1.5px solid rgba(47,70,41,.3)",
  borderRadius: 8,
  fontSize: 14,
  color: "var(--ink)",
};

function Sheet({ label, onClose, children }: { label: string; onClose: () => void; children: ReactNode }) {
  return (
    <div
      className="fade"
      role="dialog"
      aria-modal="true"
      aria-label={label}
      onClick={onClose}
      style={{ position: "fixed", left: "50%", transform: "translateX(-50%)", top: 0, bottom: 0, width: "100%", maxWidth: 480, zIndex: 20, display: "flex", flexDirection: "column", justifyContent: "flex-end", background: "rgba(10,14,11,.62)" }}
    >
      <div
        className="sheet scroll"
        onClick={(event) => event.stopPropagation()}
        style={{ display: "flex", flexDirection: "column", gap: 16, maxHeight: "92dvh", overflowY: "auto", padding: "10px 18px 22px", background: "var(--bg)", borderRadius: "16px 16px 0 0" }}
      >
        <span style={{ alignSelf: "center", width: 44, height: 4, borderRadius: 2, background: "rgba(10,14,11,.25)" }} />
        {children}
      </div>
    </div>
  );
}

function SheetHeader({ kicker, title, onClose }: { kicker: string; title: string; onClose: () => void }) {
  return (
    <div style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between", gap: 10 }}>
      <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
        <span style={{ fontSize: 12, fontWeight: 700, color: "var(--green)", letterSpacing: ".06em", textTransform: "uppercase" }}>
          {kicker}
        </span>
        <span className="bb" style={{ fontSize: 34, lineHeight: 0.95 }}>{title}</span>
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
  );
}

function Stepper({
  value,
  min,
  max,
  onChange,
  label,
  unit,
}: {
  value: number;
  min: number;
  max: number;
  onChange: (value: number) => void;
  label: string;
  unit?: string;
}) {
  const step = (delta: number) => onChange(Math.min(max, Math.max(min, value + delta)));
  const button = { width: 48, height: 48, background: "var(--chalk)", border: "1.5px solid rgba(47,70,41,.3)", borderRadius: 8, fontSize: 22, fontWeight: 800, color: "var(--ink)" };

  return (
    <div role="group" aria-label={label} style={{ display: "flex", alignItems: "center", gap: 10 }}>
      <button type="button" className="press" onClick={() => step(-1)} disabled={value <= min} aria-label={`Menos — ${label}`} style={button}>−</button>
      <span className="bb" aria-live="polite" style={{ minWidth: 72, fontSize: 34, lineHeight: 1, textAlign: "center" }}>
        {value}{unit ? <span style={{ fontSize: 16 }}> {unit}</span> : null}
      </span>
      <button type="button" className="press" onClick={() => step(1)} disabled={value >= max} aria-label={`Mais — ${label}`} style={button}>+</button>
    </div>
  );
}

function errorText(cause: unknown): string {
  if (cause instanceof LocationError) {
    return cause.kind === "denied"
      ? "Libere a localização para o site e tente de novo — é assim que confirmamos que você está na quadra."
      : cause.message;
  }
  return (cause as Error).message || "Não foi possível concluir.";
}

// =====================================================================
// Abrir a fila
// =====================================================================

export function HostOpenSheet({
  court,
  onClose,
  onOpened,
  onAlreadyOpen,
}: {
  court: CourtScreen;
  onClose: () => void;
  onOpened: () => void;
  onAlreadyOpen: (message: string) => void;
}) {
  const slot = court.court.slot_minutes;
  const [playing, setPlaying] = useState(true);
  const [minutes, setMinutes] = useState(Math.min(20, slot));
  const [waiting, setWaiting] = useState(0);
  const [labels, setLabels] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function setLabel(index: number, value: string) {
    setLabels((current) => {
      const next = [...current];
      next[index] = value;
      return next;
    });
  }

  async function open() {
    setBusy(true);
    setError(null);
    try {
      const scan = await confirmAtCourt(court.court.id, "open");
      const waitingLabels = Array.from({ length: waiting }, (_, i) => (labels[i] ?? "").trim());
      await openHostQueue(scan.scanToken, playing ? minutes : null, waitingLabels);
      onOpened();
    } catch (cause) {
      const code = (cause as { code?: string }).code;
      // Alguém abriu um instante antes: a pessoa entra na fila dele.
      if (code === "NQ031") {
        onAlreadyOpen(errorText(cause));
        return;
      }
      setError(errorText(cause));
      setBusy(false);
    }
  }

  return (
    <Sheet label="Começar a fila desta quadra" onClose={onClose}>
      <SheetHeader kicker="Você é o primeiro com o app" title={`Começar a fila da ${court.court.name}`} onClose={onClose} />

      <p style={{ margin: 0, fontSize: 14, lineHeight: 1.45 }}>
        Conte como a quadra está agora. Quem já esperava continua na frente — o app só
        organiza dali em diante. Depois, quem chegar entra pelo QR na sua tela.
      </p>

      <div style={{ display: "flex", flexDirection: "column", gap: 10, padding: 12, background: "var(--chalk)", borderRadius: 10 }}>
        <span style={{ fontSize: 13, fontWeight: 700 }}>Tem gente jogando agora?</span>
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 6 }}>
          {[true, false].map((option) => (
            <button
              key={String(option)}
              type="button"
              className="press"
              aria-pressed={playing === option}
              onClick={() => setPlaying(option)}
              style={{ minHeight: 44, borderRadius: 8, fontSize: 13, fontWeight: 700, background: playing === option ? "var(--green)" : "transparent", color: playing === option ? "var(--chalk)" : "var(--ink)", border: playing === option ? "2px solid var(--green)" : "1.5px solid rgba(47,70,41,.3)" }}
            >
              {option ? "Sim" : "Quadra livre"}
            </button>
          ))}
        </div>
        {playing && (
          <>
            <span style={{ fontSize: 12, color: "var(--muted)" }}>Quanto falta para o turno deles acabar? (até {slot} min)</span>
            <Stepper value={minutes} min={1} max={slot} onChange={setMinutes} label="Minutos que faltam" unit="min" />
          </>
        )}
      </div>

      <div style={{ display: "flex", flexDirection: "column", gap: 10, padding: 12, background: "var(--chalk)", borderRadius: 10 }}>
        <span style={{ fontSize: 13, fontWeight: 700 }}>Quantos grupos estão esperando antes de você?</span>
        <Stepper value={waiting} min={0} max={MAX_WAITING} onChange={setWaiting} label="Grupos esperando" />
        {waiting > 0 && (
          <>
            <span style={{ fontSize: 12, color: "var(--muted)" }}>
              Um apelido ajuda você a saber quem é quem quando chegar a vez deles. Opcional.
            </span>
            {Array.from({ length: waiting }, (_, i) => (
              <input
                key={i}
                value={labels[i] ?? ""}
                maxLength={40}
                onChange={(event) => setLabel(i, event.target.value)}
                placeholder={`${i + 1}º grupo — ex.: dupla de boné azul`}
                aria-label={`Apelido do ${i + 1}º grupo`}
                style={field}
              />
            ))}
          </>
        )}
      </div>

      <p style={{ margin: 0, fontSize: 12, lineHeight: 1.45, color: "var(--muted)" }}>
        Você vai organizar as vagas de quem está sem app: marcar quando entram e quando
        desistem. Se sair da fila, quem organiza passa a ser o próximo com o app.
      </p>

      {error && (
        <p role="alert" style={{ margin: 0, padding: "10px 12px", borderRadius: 8, fontSize: 13, lineHeight: 1.4, background: "rgba(177,63,22,.1)", color: "var(--rust)" }}>
          {error}
        </p>
      )}

      <button type="button" className="press" disabled={busy} onClick={() => void open()} style={{ ...buttonStyle("primary", busy), minHeight: 54, fontSize: 16 }}>
        {busy ? "Confirmando a sua localização…" : "Começar a fila e entrar nela"}
      </button>
    </Sheet>
  );
}

// =====================================================================
// O QR na tela
// =====================================================================

function newDisplayId(): string {
  if (typeof crypto.randomUUID === "function") return crypto.randomUUID();
  // Sem randomUUID (navegador antigo): só precisa não repetir.
  const bytes = Array.from(crypto.getRandomValues(new Uint8Array(16)));
  const hex = bytes.map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-4${hex.slice(13, 16)}-a${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
}

export function InviteQr({
  court,
  onClose,
}: {
  court: CourtScreen;
  onClose: () => void;
}) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const displayId = useRef(newDisplayId());
  const [url, setUrl] = useState<string | null>(null);
  const [nextAt, setNextAt] = useState(0);
  const [now, setNow] = useState(Date.now());
  const [error, setError] = useState<string | null>(null);

  // Um código novo a cada 30 s enquanto a tela estiver aberta.
  useEffect(() => {
    let alive = true;
    let timer = 0;

    const issue = async () => {
      try {
        const invite = await issueHostInvite(court.court.id, displayId.current);
        if (!alive) return;
        setUrl(`${window.location.origin}/q/h/${invite.code}`);
        setNextAt(Date.now() + invite.rotate_seconds * 1000);
        setError(null);
        timer = window.setTimeout(() => void issue(), invite.rotate_seconds * 1000);
      } catch (cause) {
        if (!alive) return;
        setError(errorText(cause));
        timer = window.setTimeout(() => void issue(), 10000);
      }
    };

    void issue();
    return () => {
      alive = false;
      clearTimeout(timer);
    };
  }, [court.court.id]);

  useEffect(() => {
    const tick = window.setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(tick);
  }, []);

  useEffect(() => {
    if (!url) return;
    let alive = true;
    void import("qrcode").then(({ default: QRCode }) => {
      if (!alive || !canvas.current) return;
      return QRCode.toCanvas(canvas.current, url, {
        width: 260,
        margin: 1,
        color: { dark: "#0A0E0B", light: "#FFFFFF" },
        errorCorrectionLevel: "M",
      });
    }).catch(() => { if (alive) setError("Não foi possível desenhar o QR. Tente fechar e abrir de novo."); });
    return () => { alive = false; };
  }, [url]);

  const secondsLeft = Math.max(0, Math.ceil((nextAt - now) / 1000));

  return (
    <Sheet label="QR para quem chegou" onClose={onClose}>
      <SheetHeader kicker={`${court.park.name} · ${court.court.name}`} title="Aponte a câmera para o QR" onClose={onClose} />

      <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 10, padding: 16, background: "#FFFFFF", borderRadius: 12 }}>
        {url
          ? <canvas ref={canvas} aria-label="QR Code para entrar na fila desta quadra" style={{ width: 260, height: 260 }} />
          : <span style={{ display: "flex", alignItems: "center", justifyContent: "center", width: 260, height: 260, fontSize: 13, color: "var(--muted)" }}>Gerando o QR…</span>}
        <span style={{ fontSize: 12, fontWeight: 700, color: "var(--green)" }} aria-live="off">
          {url ? `Troca em ${mmss(secondsLeft)}` : " "}
        </span>
      </div>

      {error && (
        <p role="alert" style={{ margin: 0, padding: "10px 12px", borderRadius: 8, fontSize: 13, lineHeight: 1.4, background: "rgba(177,63,22,.1)", color: "var(--rust)" }}>
          {error}
        </p>
      )}

      <ul style={{ margin: 0, paddingLeft: 18, display: "flex", flexDirection: "column", gap: 6, fontSize: 13, lineHeight: 1.45 }}>
        <li>A câmera do celular abre o app — ou o site, com a opção de instalar.</li>
        <li>Quem nunca usou cria a conta na hora; o convite espera 10 minutos.</li>
        <li>Só entra quem estiver aqui na quadra: o app confere a localização. Print mandado para quem está em casa não funciona.</li>
      </ul>
    </Sheet>
  );
}

// =====================================================================
// O painel de quem organiza
// =====================================================================

export function HostPanel({
  court,
  busy,
  onAct,
}: {
  court: CourtScreen;
  busy: boolean;
  onAct: (action: () => Promise<unknown>, done?: string) => void;
}) {
  const [label, setLabel] = useState("");
  const offline = court.queue.filter((item) => item.is_offline);
  const offlineMatch = court.match?.is_live && court.match.is_offline ? court.match : null;

  const small = { minHeight: 40, padding: "0 10px", borderRadius: 8, fontSize: 12, fontWeight: 800 } as const;

  function row(item: QueueItem) {
    return (
      <div key={item.entry_id} style={{ display: "flex", flexWrap: "wrap", alignItems: "center", gap: 10, padding: "8px 10px", background: item.is_called ? "rgba(196,144,81,.22)" : "rgba(241,236,239,.12)", border: item.is_called ? "1.5px solid var(--ocre)" : "1px solid rgba(241,236,239,.25)", borderRadius: 8 }}>
        <span className="bb" style={{ fontSize: 24, lineHeight: 1, minWidth: 32 }}>{item.position_label}</span>
        <span style={{ display: "flex", flexDirection: "column", gap: 2, flexGrow: 1, minWidth: 0, fontSize: 13, lineHeight: 1.3 }}>
          <strong style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{item.team_label}</strong>
          <span style={{ fontSize: 11, opacity: 0.8 }}>{item.is_called ? "É a vez deles — marque quando entrarem" : "Esperando"}</span>
        </span>
        {/* Na vez deles, os dois botões descem para uma linha própria: o nome não pode sumir. */}
        <span style={{ display: "flex", gap: 6, flexShrink: 0, ...(item.is_called ? { flexBasis: "100%" } : {}) }}>
          <button
            type="button"
            className="press"
            disabled={busy}
            onClick={() => onAct(() => hostMarkOffline(item.entry_id, "gave_up"), "Grupo tirado da fila.")}
            style={{ ...small, ...(item.is_called ? { flex: 1 } : {}), background: "transparent", color: "var(--chalk)", border: "1.5px solid rgba(241,236,239,.6)" }}
          >
            Desistiram
          </button>
          {item.is_called && (
            <button
              type="button"
              className="press"
              disabled={busy}
              onClick={() => onAct(() => hostMarkOffline(item.entry_id, "arrived"), "Turno iniciado.")}
              style={{ ...small, flex: 2, background: "var(--ocre)", color: "var(--ink)", border: "2px solid var(--ink)" }}
            >
              Entraram
            </button>
          )}
        </span>
      </div>
    );
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 10, padding: 12, background: "var(--ink)", color: "var(--chalk)", borderRadius: 10 }}>
      <span style={{ display: "flex", flexDirection: "column", gap: 2 }}>
        <span style={{ display: "flex", alignItems: "center", gap: 6, fontSize: 11, fontWeight: 800, letterSpacing: ".1em", color: "var(--ocre)" }}>
          <Players size={14} />VOCÊ ORGANIZA ESTA FILA
        </span>
        <span style={{ fontSize: 13, lineHeight: 1.4 }}>
          As vagas de quem está sem app andam com você. Quem tem o app anda sozinho.
        </span>
      </span>

      {offlineMatch && (
        <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "8px 10px", background: "rgba(241,236,239,.12)", border: "1px solid rgba(241,236,239,.25)", borderRadius: 8 }}>
          <span style={{ display: "flex", flexDirection: "column", gap: 2, flexGrow: 1, minWidth: 0, fontSize: 13, lineHeight: 1.3 }}>
            <strong>Em quadra: {offlineMatch.offline_label ?? "grupo sem app"}</strong>
            <span style={{ fontSize: 11, opacity: 0.8 }}>Acaba sozinho em ~{Math.max(1, Math.ceil(offlineMatch.remaining_seconds / 60))} min</span>
          </span>
          <button
            type="button"
            className="press"
            disabled={busy}
            onClick={() => onAct(() => hostMarkOffline(offlineMatch.entry_id, "finished"), "Quadra liberada. O próximo foi chamado.")}
            style={{ ...small, flexShrink: 0, background: "transparent", color: "var(--chalk)", border: "1.5px solid rgba(241,236,239,.6)" }}
          >
            Saíram
          </button>
        </div>
      )}

      {offline.map(row)}

      <form
        onSubmit={(event) => {
          event.preventDefault();
          const text = label.trim();
          onAct(() => hostAddOffline(court.court.id, text), "Grupo sem app no fim da fila.");
          setLabel("");
        }}
        style={{ display: "flex", flexDirection: "column", gap: 6, paddingTop: 10, borderTop: "1px dashed rgba(241,236,239,.3)" }}
      >
        <label htmlFor="offline-label" style={{ fontSize: 12, fontWeight: 700 }}>Chegou alguém sem o app?</label>
        <div style={{ display: "flex", gap: 6 }}>
          <input
            id="offline-label"
            value={label}
            maxLength={40}
            onChange={(event) => setLabel(event.target.value)}
            placeholder="Apelido (opcional)"
            style={{ ...field, flexGrow: 1, minWidth: 0 }}
          />
          <button type="submit" className="press" disabled={busy} style={{ ...small, minHeight: 44, flexShrink: 0, background: "var(--ocre)", color: "var(--ink)", border: "2px solid var(--chalk)" }}>
            Pôr no fim
          </button>
        </div>
        <span style={{ fontSize: 11, opacity: 0.75 }}>
          Entra no fim da fila, depois de todo mundo que já está nela.
        </span>
      </form>
    </div>
  );
}

/** Para quem está livre numa quadra com a fila aberta: o QR está com quem está nela. */
export function AskForQr({ hostName }: { hostName: string | null }) {
  return (
    <div style={{ display: "flex", alignItems: "flex-start", gap: 10, padding: 12, background: "var(--chalk)", border: "1.5px solid var(--green)", borderRadius: 10, fontSize: 13, lineHeight: 1.4 }}>
      <span style={{ color: "var(--green)", flexShrink: 0, display: "flex" }}><QrIcon size={20} /></span>
      <span>
        <strong>Peça o QR para alguém da fila.</strong> Esta quadra ainda não tem código na
        placa: quem já está na fila{hostName ? ` (como ${hostName})` : ""} mostra o QR no
        celular, e você escaneia aqui.
      </span>
    </div>
  );
}
