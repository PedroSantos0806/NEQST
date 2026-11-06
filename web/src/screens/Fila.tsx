import { useCallback, useEffect, useState } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { partyExitAnswer, partyLeave, partyScreen, scanJoinParty } from "../lib/api";
import { mmss } from "../lib/format";
import { forgetParty, rememberParty, savedParty } from "../lib/party";
import { buttonStyle, ErrorState, fieldStyle, Loading } from "../components/ui";
import type { PartyScreen, ScanResult } from "../lib/types";

/**
 * A fila no celular de quem entrou pelo QR ou pela tag NFC.
 *
 * Sem conta: a pessoa leu o código impresso na quadra, digitou nome e
 * sobrenome, e é isso. O que a liga à vaga é um segredo guardado no
 * navegador dela — ver a posição, sair da fila e responder a pergunta de
 * saída, e mais nada.
 *
 * Esta tela não manda na quadra: quem manda é o totem. Aqui dá para
 * acompanhar a fila de onde a pessoa estiver, que é a fase 1 do app no
 * handoff — "ler não quer dizer passivo".
 */

const NAME_MIN = 2;
const NAME_MAX = 40;

type Mode = { kind: "join"; scan: ScanResult } | { kind: "watch" } | { kind: "lost" };

export function Fila() {
  const location = useLocation();
  const navigate = useNavigate();

  const handoff = (location.state as { scan?: ScanResult } | null)?.scan ?? null;
  const [mode, setMode] = useState<Mode>(() => {
    if (handoff) return { kind: "join", scan: handoff };
    return savedParty() ? { kind: "watch" } : { kind: "lost" };
  });

  const [name, setName] = useState("");
  const [size, setSize] = useState(2);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [data, setData] = useState<PartyScreen | null>(null);
  const [, setTick] = useState(0);

  // O scan token vale 30 segundos e é de uso único: consumido aqui, não
  // pode voltar pela navegação. Limpa o state da rota na entrada.
  useEffect(() => {
    if (handoff) navigate(location.pathname, { replace: true, state: null });
  }, [handoff, location.pathname, navigate]);

  const refresh = useCallback(async () => {
    const saved = savedParty();
    if (!saved) return;
    try {
      setData(await partyScreen(saved.token));
      setError(null);
    } catch (cause) {
      // Vaga que saiu da fila (o tempo acabou, o admin removeu, a pessoa
      // saiu noutro aparelho): o token não vale mais, e insistir só
      // mostraria erro para sempre.
      forgetParty();
      setMode({ kind: "lost" });
      setError((cause as Error).message);
    }
  }, []);

  useEffect(() => {
    if (mode.kind !== "watch") return;
    void refresh();
    const id = setInterval(() => void refresh(), 10_000);
    return () => clearInterval(id);
  }, [mode.kind, refresh]);

  // Relógio de 1 segundo, para os contadores andarem entre leituras.
  useEffect(() => {
    if (mode.kind !== "watch") return;
    const id = setInterval(() => setTick((t) => t + 1), 1000);
    return () => clearInterval(id);
  }, [mode.kind]);

  async function join() {
    if (mode.kind !== "join") return;
    const clean = name.trim();
    if (clean.length < NAME_MIN) return;

    setBusy(true);
    try {
      const result = await scanJoinParty(mode.scan.scanToken, clean, size);
      rememberParty({
        token: result.party_token,
        courtId: result.court_id,
        name: result.party_name,
        size: result.party_size,
      });
      setMode({ kind: "watch" });
      setError(null);
      await refresh();
    } catch (cause) {
      setError((cause as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function leave() {
    const saved = savedParty();
    if (!saved) return;
    if (!window.confirm("Sair da fila? Para voltar você precisa escanear o QR de novo.")) return;

    setBusy(true);
    try {
      await partyLeave(saved.token);
      forgetParty();
      setMode({ kind: "lost" });
    } catch (cause) {
      setError((cause as Error).message);
    } finally {
      setBusy(false);
    }
  }

  async function answerExit(back: boolean) {
    const saved = savedParty();
    if (!saved) return;
    setBusy(true);
    try {
      await partyExitAnswer(saved.token, back);
      if (!back) forgetParty();
      await refresh();
      if (!back) setMode({ kind: "lost" });
    } catch (cause) {
      setError((cause as Error).message);
      await refresh();
    } finally {
      setBusy(false);
    }
  }

  // ------------------------------------------------------------------
  if (mode.kind === "lost") {
    return (
      <div style={{ display: "flex", flexDirection: "column", gap: 14, padding: 20 }}>
        <ErrorState
          title="Você não está em nenhuma fila"
          detail={
            error
              ?? "Escaneie o QR Code da quadra, ou use o totem que fica nela, para entrar na fila."
          }
        />
      </div>
    );
  }

  if (mode.kind === "join") {
    const ready = name.trim().length >= NAME_MIN;
    return (
      <div style={{ display: "flex", flexDirection: "column", gap: 16, padding: 20 }}>
        <header style={{ display: "flex", flexDirection: "column", gap: 4 }}>
          <span style={{ fontSize: 11, fontWeight: 800, letterSpacing: ".1em", color: "var(--green)" }}>
            {mode.scan.court.name.toUpperCase()}
          </span>
          <h1 className="bb" style={{ margin: 0, fontSize: 34, lineHeight: 1 }}>
            Entrar na fila
          </h1>
          <p style={{ margin: 0, fontSize: 13, lineHeight: 1.45, color: "var(--muted)" }}>
            Sem cadastro: escreva como a quadra vai te chamar e quantas pessoas vão jogar.
          </p>
        </header>

        <label style={{ display: "flex", flexDirection: "column", gap: 6 }}>
          <span style={{ fontSize: 12, fontWeight: 700 }}>Seu nome e sobrenome</span>
          <input
            value={name}
            onChange={(event) => setName(event.target.value.slice(0, NAME_MAX))}
            maxLength={NAME_MAX}
            autoComplete="name"
            autoCapitalize="words"
            placeholder="Ex.: Marina Souza"
            style={fieldStyle()}
          />
        </label>

        <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
          <span style={{ fontSize: 12, fontWeight: 700 }}>Quantas pessoas vão jogar</span>
          <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
            <button
              type="button"
              className="press"
              onClick={() => setSize((n) => Math.max(1, n - 1))}
              style={{ ...buttonStyle("ghost"), minWidth: 56 }}
              aria-label="Menos uma pessoa"
            >
              −
            </button>
            <span className="bb" style={{ fontSize: 40, minWidth: 48, textAlign: "center" }}>
              {size}
            </span>
            <button
              type="button"
              className="press"
              onClick={() => setSize((n) => Math.min(20, n + 1))}
              style={{ ...buttonStyle("ghost"), minWidth: 56 }}
              aria-label="Mais uma pessoa"
            >
              +
            </button>
          </div>
          <span style={{ fontSize: 12, color: "var(--muted)", lineHeight: 1.4 }}>
            {size > 4
              ? `Vocês têm os mesmos minutos de quadra para revezar entre as ${size} pessoas.`
              : "Conte todo mundo, você incluso. Dá para passar de 4."}
          </span>
        </div>

        {error && <div role="alert" style={{ fontSize: 13, color: "var(--rust)" }}>{error}</div>}

        <button
          type="button"
          className="press"
          disabled={!ready || busy}
          onClick={() => void join()}
          style={buttonStyle("primary", !ready || busy)}
        >
          {busy ? "Entrando…" : "Entrar na fila"}
        </button>
      </div>
    );
  }

  // ------------------------------------------------------------------
  if (!data) return <Loading what="Carregando a fila" />;

  const me = data.my_party;
  const playing = me.is_playing;

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 16, padding: 20 }}>
      <header style={{ display: "flex", flexDirection: "column", gap: 4 }}>
        <span style={{ fontSize: 11, fontWeight: 800, letterSpacing: ".1em", color: "var(--green)" }}>
          {data.court.strip}
        </span>
        <h1 className="bb" style={{ margin: 0, fontSize: 34, lineHeight: 1 }}>
          {playing
            ? "É a sua vez — bom jogo!"
            : me.position
              ? `Você é o ${me.position}º da fila`
              : "Você está na fila"}
        </h1>
        <p style={{ margin: 0, fontSize: 13, color: "var(--muted)" }}>
          {me.name} · {me.label}
        </p>
      </header>

      {/* O estado da quadra, com as palavras do totem. */}
      <div
        style={{ display: "flex", flexDirection: "column", gap: 6, padding: 14, background: "var(--green)", color: "var(--chalk)", borderRadius: 12 }}
      >
        <span style={{ fontSize: 11, fontWeight: 800, letterSpacing: ".1em", color: "var(--ocre)" }}>
          {data.state === "paused"
            ? `PAUSADA · ${data.pause?.label ?? ""}`
            : data.state === "changeover"
              ? "TROCA DE GRUPO"
              : data.state === "free"
                ? "QUADRA LIVRE"
                : "EM JOGO"}
        </span>
        <span className="bb" role="timer" style={{ fontSize: 48, lineHeight: 1 }}>
          {data.state === "paused"
            ? mmss(data.pause?.seconds ?? 0)
            : data.state === "changeover"
              ? mmss(data.changeover_left)
              : data.state === "free"
                ? "--:--"
                : mmss(data.remaining_seconds)}
        </span>
        <span style={{ fontSize: 13, lineHeight: 1.4 }}>
          {data.state === "paused"
            ? "A fila está parada e volta a andar quando a quadra for liberada no totem."
            : data.state === "changeover"
              ? `Entra: ${data.next?.name ?? "o próximo da fila"}`
              : data.playing
                ? `Em quadra: ${data.playing.name} · ${data.playing.label}`
                : "Ninguém em quadra agora."}
        </span>
      </div>

      {/* A pergunta de saída, quando é a desta party. */}
      {me.can_answer_exit && (
        <div
          className="flash"
          style={{ display: "flex", flexDirection: "column", gap: 10, padding: 14, background: "var(--ocre)", color: "var(--ink)", border: "2px solid var(--ink)", borderRadius: 12 }}
        >
          <span style={{ fontSize: 14, fontWeight: 700, lineHeight: 1.35 }}>
            {me.name}, acabou seu tempo. Quer sair ou voltar pro fim da fila?
          </span>
          <div style={{ display: "flex", gap: 10 }}>
            <button
              type="button"
              className="press"
              disabled={busy}
              onClick={() => void answerExit(true)}
              style={{ ...buttonStyle("primary", busy), flex: 2 }}
            >
              Voltar pra fila
            </button>
            <button
              type="button"
              className="press"
              disabled={busy}
              onClick={() => void answerExit(false)}
              style={{ ...buttonStyle("ghost", busy), flex: 1 }}
            >
              Sair
            </button>
          </div>
        </div>
      )}

      {/* A fila inteira: a pessoa confere a posição sem ir até a quadra. */}
      <section style={{ display: "flex", flexDirection: "column", gap: 8 }}>
        <div style={{ display: "flex", alignItems: "baseline", justifyContent: "space-between" }}>
          <h2 style={{ margin: 0, fontSize: 13, fontWeight: 800, letterSpacing: ".1em", textTransform: "uppercase" }}>
            Fila
          </h2>
          <span style={{ fontSize: 12, color: "var(--muted)" }}>
            {data.queue_count === 0 ? "vazia" : `${data.queue_count} na espera`}
          </span>
        </div>

        {data.queue.map((row) => (
          <div
            key={row.entry_id}
            style={{ display: "grid", gridTemplateColumns: "28px 1fr auto", alignItems: "center", gap: 10, padding: "10px 12px", background: row.entry_id === me.entry_id ? "var(--ocre)" : "var(--chalk)", borderRadius: 8 }}
          >
            <span className="bb" style={{ fontSize: 18 }}>{row.position}</span>
            <span style={{ display: "flex", flexDirection: "column" }}>
              <strong style={{ fontSize: 14 }}>{row.name}</strong>
              <span style={{ fontSize: 11, color: "var(--muted)" }}>{row.label}</span>
            </span>
            <span style={{ fontSize: 12, fontWeight: 700, textAlign: "right" }}>
              {row.eta_seconds === null
                ? "depois da pausa"
                : row.eta_at
                  ? new Date(row.eta_at).toLocaleTimeString("pt-BR", {
                      hour: "2-digit",
                      minute: "2-digit",
                    })
                  : "—"}
            </span>
          </div>
        ))}
      </section>

      {error && <div role="alert" style={{ fontSize: 13, color: "var(--rust)" }}>{error}</div>}

      <button
        type="button"
        className="press"
        disabled={busy}
        onClick={() => void leave()}
        style={buttonStyle("ghost", busy)}
      >
        {playing ? "Encerrar e sair da quadra" : "Sair da fila"}
      </button>

      <p style={{ margin: 0, fontSize: 12, color: "var(--muted)", lineHeight: 1.45 }}>
        Esta tela acompanha a fila. Quem pausa a quadra e quem confirma a entrada é o totem
        que fica nela.
      </p>
    </div>
  );
}
