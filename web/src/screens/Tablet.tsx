import { useCallback, useEffect, useRef, useState } from "react";
import { useParams } from "react-router-dom";
import { tabletAcceptTurn, tabletScreen } from "../lib/api";
import { mmss } from "../lib/format";
import { SOUNDS, soundReady, unlockSound } from "../lib/sound";
import type { QueueItem, TabletScreen as Screen } from "../lib/types";

/**
 * A tela do tablet da quadra.
 *
 * Fica aberta o dia inteiro num aparelho parado na quadra, sem conta de
 * ninguém: a credencial é o token do link. Ela faz três coisas, e só:
 *
 *   . mostra quem está em quadra, quanto falta e quem é o próximo;
 *   . avisa em voz alta — 1 minuto para o fim, fim do turno, chamada
 *     dos próximos pelo nome, começo do turno;
 *   . tem o botão JOGAR, que uma pessoa do grupo chamado aperta.
 *
 * Tudo em letra grande: quem lê isto está a alguns metros de distância,
 * de pé, com uma raquete na mão.
 */
export function Tablet() {
  const { token } = useParams<{ token: string }>();
  const [data, setData] = useState<Screen | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [sound, setSound] = useState(soundReady());
  const [, setTick] = useState(0);

  // Memória do que já foi falado, para não repetir a cada leitura.
  const saidOneMinute = useRef<string | null>(null);
  const saidTurnOver = useRef<string | null>(null);
  const saidStart = useRef<string | null>(null);
  const calledAt = useRef<{ entry: string; at: number } | null>(null);
  const saidAccepted = useRef<string | null>(null);

  const load = useCallback(async () => {
    if (!token) return;
    try {
      const fresh = await tabletScreen(token);
      setData(fresh);
      setError(null);
    } catch (cause) {
      setError((cause as Error).message);
    }
  }, [token]);

  // O tablet conversa com o servidor de 5 em 5 segundos. É o que marca
  // o aparelho como aceso — e é esse sinal que faz a quadra chamar os
  // nomes em vez de trocar de turno sozinha. Tablet desligado, a quadra
  // volta sozinha para a troca automática.
  useEffect(() => {
    void load();
    const id = setInterval(() => void load(), 5000);
    return () => clearInterval(id);
  }, [load]);

  // Relógio de 1 segundo: os contadores da tela andam entre leituras.
  useEffect(() => {
    const id = setInterval(() => setTick((t) => t + 1), 1000);
    return () => clearInterval(id);
  }, []);

  const match = data?.match ?? null;
  const live = Boolean(data?.is_live && match);
  const handover = data?.handover ?? null;
  const now = Date.now();

  const remaining = live && match
    ? Math.max(0, Math.floor((new Date(match.expires_at).getTime() - now) / 1000))
    : 0;
  const handoverLeft = handover
    ? Math.max(0, Math.floor((new Date(handover.until).getTime() - now) / 1000))
    : 0;

  // ------------------------------------------------------------------
  // Os avisos em voz alta
  // ------------------------------------------------------------------
  useEffect(() => {
    if (!sound || !data) return;
    const id = match?.match_id ?? null;

    // Falta 1 minuto. A janela de 5 s é a do próprio refresh: o aviso
    // sai uma vez, no primeiro refresh depois de cruzar o minuto.
    if (live && id && remaining <= 60 && remaining > 50 && saidOneMinute.current !== id) {
      saidOneMinute.current = id;
      SOUNDS.oneMinute();
      return;
    }

    // Acabou o turno: a tela deixou de ter partida e passou a ter
    // chamada. É o momento em que a quadra vira.
    if (!live && handover && saidTurnOver.current !== handover.entry_id) {
      saidTurnOver.current = handover.entry_id;
      SOUNDS.turnOver();
      return;
    }

    // Começou o turno.
    if (live && id && saidStart.current !== id) {
      saidStart.current = id;
      SOUNDS.turnStart();
    }
  }, [data, sound, live, match?.match_id, remaining, handover]);

  // A chamada pelo nome, repetida enquanto os 15 segundos correm.
  useEffect(() => {
    if (!sound || !handover) return;

    if (handover.phase === "calling") {
      const previous = calledAt.current;
      const fresh = !previous || previous.entry !== handover.entry_id;
      // Repete a cada 6 s: quem estava de costas ouve na segunda.
      if (fresh || Date.now() - previous.at > 6000) {
        calledAt.current = { entry: handover.entry_id, at: Date.now() };
        SOUNDS.calling(handover.spoken_names, handover.group_size);
      }
      return;
    }

    if (handover.phase === "entering" && saidAccepted.current !== handover.entry_id) {
      saidAccepted.current = handover.entry_id;
      SOUNDS.accepted(handover.seconds_left || 30);
    }
  }, [sound, handover, handoverLeft]);

  async function accept() {
    if (!token) return;
    setBusy(true);
    try {
      setData(await tabletAcceptTurn(token));
      setError(null);
    } catch (cause) {
      setError((cause as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function enableSound() {
    const ok = await unlockSound();
    setSound(ok);
    if (ok) SOUNDS.calling("Som ligado", 1);
  }

  return (
    <TabletBoard
      data={data}
      error={error}
      busy={busy}
      sound={sound}
      onAccept={() => void accept()}
      onEnableSound={() => void enableSound()}
    />
  );
}

/**
 * O desenho da tela, separado de quem busca os dados e toca os sons.
 *
 * Fica à parte para poder ser renderizado num teste: é a tela que vai
 * ficar ligada o dia inteiro num parque, e o que ela escreve em letra
 * grande importa mais que o resto.
 */
export function TabletBoard({
  data,
  error,
  busy,
  sound,
  onAccept,
  onEnableSound,
}: {
  data: Screen | null;
  error: string | null;
  busy: boolean;
  sound: boolean;
  onAccept: () => void;
  onEnableSound: () => void;
}) {
  const match = data?.match ?? null;
  const live = Boolean(data?.is_live && match);
  const handover = data?.handover ?? null;
  const now = Date.now();

  const remaining = live && match
    ? Math.max(0, Math.floor((new Date(match.expires_at).getTime() - now) / 1000))
    : 0;
  const handoverLeft = handover
    ? Math.max(0, Math.floor((new Date(handover.until).getTime() - now) / 1000))
    : 0;

  if (error && !data) {
    return (
      <div style={screenStyle}>
        <h1 className="bb" style={{ fontSize: 48, margin: 0, color: "var(--rust)" }}>Tablet sem quadra</h1>
        <p style={{ fontSize: 22, lineHeight: 1.4, maxWidth: 680 }}>{error}</p>
        <p style={{ fontSize: 18, opacity: 0.8 }}>
          Peça um link novo em <strong>/admin</strong>, na quadra, e abra neste aparelho.
        </p>
      </div>
    );
  }

  if (!data) {
    return (
      <div style={screenStyle}>
        <span className="bb" style={{ fontSize: 40 }}>Carregando a quadra…</span>
      </div>
    );
  }

  const calling = handover?.phase === "calling";
  const entering = handover?.phase === "entering";
  const queue = data.queue ?? [];

  return (
    <div style={screenStyle}>
      {/* ---------------------------------------------- cabeçalho */}
      <div style={{ display: "flex", alignItems: "baseline", justifyContent: "space-between", gap: 16 }}>
        <span className="bb" style={{ fontSize: 40, lineHeight: 1 }}>
          {data.park.name} · {data.court.name}
        </span>
        <span style={{ display: "flex", alignItems: "center", gap: 14 }}>
          {!sound && (
            <button type="button" className="press" onClick={onEnableSound} style={soundButton}>
              Ativar som
            </button>
          )}
          <span style={{ fontSize: 18, fontWeight: 700, opacity: 0.75 }}>
            {data.status_text}
          </span>
        </span>
      </div>

      {/* ---------------------------------------------- o palco */}
      {calling || entering
        ? (
          <div
            className="flash"
            style={{
              display: "flex", flexDirection: "column", alignItems: "center", gap: 18,
              padding: "36px 24px", borderRadius: 24,
              background: calling ? "var(--ocre)" : "var(--green)",
              color: calling ? "var(--ink)" : "var(--chalk)",
              border: "4px solid var(--ink)",
            }}
          >
            <span style={{ fontSize: 22, fontWeight: 800, letterSpacing: ".14em", textTransform: "uppercase" }}>
              {calling ? "É a vez de" : "Entrando na quadra"}
            </span>
            <span className="bb" style={{ fontSize: 86, lineHeight: 0.95, textAlign: "center" }}>
              {handover?.label ?? "Próximo grupo"}
            </span>
            <span className="bb" role="timer" style={{ fontSize: 120, lineHeight: 0.9 }}>
              {mmss(handoverLeft)}
            </span>

            {calling
              ? (
                <>
                  <button
                    type="button"
                    className="press"
                    disabled={busy}
                    onClick={onAccept}
                    style={jogarButton}
                  >
                    JOGAR
                  </button>
                  <span style={{ fontSize: 20, textAlign: "center", maxWidth: 760, lineHeight: 1.35 }}>
                    Basta <strong>uma pessoa</strong> do grupo apertar. Se ninguém apertar,
                    a vez passa para o próximo da fila.
                  </span>
                </>
              )
              : (
                <span style={{ fontSize: 24, textAlign: "center", maxWidth: 760, lineHeight: 1.35 }}>
                  Entrem na quadra. Quando zerar, o tempo de jogo começa.
                </span>
              )}
          </div>
        )
        : (
          <div
            style={{
              display: "flex", flexDirection: "column", alignItems: "center", gap: 10,
              padding: "28px 24px", borderRadius: 24,
              background: live ? "var(--green)" : "var(--chalk)",
              color: live ? "var(--chalk)" : "var(--green)",
              border: "4px solid var(--green)",
            }}
          >
            <span style={{ fontSize: 20, fontWeight: 800, letterSpacing: ".14em", textTransform: "uppercase" }}>
              {live ? "Em quadra" : "Quadra livre"}
            </span>
            <span className="bb" style={{ fontSize: 56, lineHeight: 1, textAlign: "center" }}>
              {live ? data.players_line : "Ninguém jogando"}
            </span>
            <span className="bb" role="timer" style={{ fontSize: 132, lineHeight: 0.9 }}>
              {live ? mmss(remaining) : "--:--"}
            </span>
            {live && match?.time_adjusted_at && (
              <span style={{ fontSize: 18, opacity: 0.85 }}>tempo ajustado pela organização</span>
            )}
            {!live && queue.length > 0 && (
              <button
                type="button"
                className="press"
                disabled={busy}
                onClick={onAccept}
                style={jogarButton}
              >
                JOGAR
              </button>
            )}
          </div>
        )}

      {/* ---------------------------------------------- a fila */}
      <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
        <span style={{ fontSize: 20, fontWeight: 800, letterSpacing: ".12em", textTransform: "uppercase", opacity: 0.75 }}>
          Fila · {data.queue_text}
        </span>
        {queue.length === 0
          ? <span style={{ fontSize: 24, opacity: 0.7 }}>Ninguém esperando. Escaneie o QR da quadra para entrar.</span>
          : queue.slice(0, 6).map((item) => <Row key={item.entry_id} item={item} />)}
      </div>

      {error && (
        <p role="alert" style={{ margin: 0, fontSize: 20, color: "var(--rust)" }}>{error}</p>
      )}
    </div>
  );
}

function Row({ item }: { item: QueueItem }) {
  const next = item.is_being_called || item.position === 1;
  return (
    <div
      style={{
        display: "flex", alignItems: "center", gap: 18, padding: "14px 18px",
        borderRadius: 14,
        background: next ? "rgba(196,144,81,.22)" : "var(--chalk)",
        border: `2px solid ${next ? "var(--ocre)" : "rgba(47,70,41,.25)"}`,
      }}
    >
      <span className="bb" style={{ fontSize: 34, minWidth: 64 }}>{item.position_label}</span>
      <span style={{ flex: 1, fontSize: 28, fontWeight: 700 }}>
        {item.team_label ?? item.group_label}
      </span>
      <span style={{ fontSize: 20, opacity: 0.75 }}>
        {item.eta_seconds > 0 ? `~${Math.max(1, Math.round(item.eta_seconds / 60))} min` : "agora"}
      </span>
    </div>
  );
}

const screenStyle = {
  display: "flex",
  flexDirection: "column",
  gap: 22,
  minHeight: "100vh",
  padding: "28px 32px",
  background: "var(--bg)",
  color: "var(--ink)",
} as const;

const soundButton = {
  minHeight: 56,
  padding: "0 22px",
  background: "var(--ocre)",
  color: "var(--ink)",
  border: "3px solid var(--ink)",
  borderRadius: 12,
  fontSize: 20,
  fontWeight: 800,
} as const;

const jogarButton = {
  minHeight: 92,
  padding: "0 72px",
  background: "var(--chalk)",
  color: "var(--green)",
  border: "4px solid var(--ink)",
  borderRadius: 16,
  fontSize: 44,
  fontWeight: 900,
  letterSpacing: ".06em",
} as const;
