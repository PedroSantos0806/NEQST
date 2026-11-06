import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { useParams } from "react-router-dom";
import {
  totemContinue,
  totemExitAnswer,
  totemJoin,
  totemPause,
  totemResume,
  totemScreen,
} from "../lib/api";
import { mmss } from "../lib/format";
import { SOUNDS, soundReady, unlockSound } from "../lib/sound";
import type { PauseKind, TotemQueueRow, TotemState } from "../lib/types";
import "./totem.css";

/**
 * O totem da quadra.
 *
 * Um aparelho por quadra, retrato, travado em modo quiosque, aberto o
 * dia inteiro. Não tem conta de ninguém: a credencial é o token do
 * link, e a pessoa que chega digita nome e sobrenome no teclado da
 * própria tela.
 *
 * Uma tela só, sempre a mesma: nada de menu, voltar, configurações,
 * perfil ou troca de quadra. O handoff é explícito nisso, e é o que faz
 * um quiosque não virar um navegador aberto no parque.
 *
 * Toda a regra mora no banco (`totem_screen` devolve estado, relógio,
 * fila e previsão já resolvidos). Aqui ficam três coisas que só o
 * navegador pode fazer: contar os segundos entre leituras, falar em voz
 * alta, e desenhar.
 */

const PAUSES: Array<{ kind: PauseKind; title: string; desc: string }> = [
  { kind: "vassourao", title: "Vassourão", desc: "Limpeza do saibro" },
  { kind: "rega", title: "Rega", desc: "Molhando a quadra" },
  { kind: "excecao", title: "Exceção", desc: "Parada do parque" },
];

const ROWS = ["QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"];

/** Nome e sobrenome cabem em 40; o mock parava em 16, que era só nome. */
const NAME_MAX = 40;
const NAME_MIN = 2;

/** A lista volta sozinha ao topo depois disto, sem ninguém tocar. */
const SCROLL_RESET_MS = 12_000;

const hhmmOf = (date: Date) =>
  `${String(date.getHours()).padStart(2, "0")}:${String(date.getMinutes()).padStart(2, "0")}`;

/** "em 12 min", "agora", "em 1h05" — como no mock. */
export function emMin(seconds: number): string {
  const minutes = Math.round(seconds / 60);
  if (minutes < 1) return "agora";
  if (minutes < 60) return `em ${minutes} min`;
  return `em ${Math.floor(minutes / 60)}h${String(minutes % 60).padStart(2, "0")}`;
}

export function pessoas(n: number): string {
  return `${n} ${n === 1 ? "pessoa" : "pessoas"}`;
}

/** A dica do contador, que muda quando a party passa de 4. */
export function sizeHint(size: number): string {
  return size > 4
    ? `Vocês têm os mesmos 40 minutos para revezar entre as ${size} pessoas.`
    : "Conte todo mundo, você incluso. Dá para passar de 4.";
}

type Pending = { name: string; size: number };

export function Totem() {
  const { token } = useParams<{ token: string }>();
  const [data, setData] = useState<TotemState | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [fail, setFail] = useState<string | null>(null);
  const [sound, setSound] = useState(soundReady());
  const [joining, setJoining] = useState<Pending | null>(null);
  const [toast, setToast] = useState<{ position: number; text: string } | null>(null);
  const [, setTick] = useState(0);

  // Memória do que já foi falado, para não repetir a cada leitura.
  const saidOneMinute = useRef<string | null>(null);
  const saidTurnOver = useRef<string | null>(null);
  const saidStart = useRef<string | null>(null);
  const saidPause = useRef<string | null>(null);
  const wasPaused = useRef(false);

  const load = useCallback(async () => {
    if (!token) return;
    try {
      const fresh = await totemScreen(token);
      setData(fresh);
      setError(null);
    } catch (cause) {
      setError((cause as Error).message);
    }
  }, [token]);

  // O totem conversa com o servidor de 5 em 5 segundos: é essa leitura
  // que marca o aparelho como vivo e executa o que já venceu (o fim do
  // turno, o fim da troca) sem esperar o cron de minuto em minuto.
  useEffect(() => {
    void load();
    const id = setInterval(() => void load(), 5000);
    return () => clearInterval(id);
  }, [load]);

  // Relógio de 1 segundo: os contadores andam entre leituras.
  useEffect(() => {
    const id = setInterval(() => setTick((t) => t + 1), 1000);
    return () => clearInterval(id);
  }, []);

  const act = useCallback(
    async (run: () => Promise<TotemState>) => {
      try {
        setData(await run());
        setFail(null);
      } catch (cause) {
        setFail((cause as Error).message);
        // Mostra o erro e some: ninguém fica para fechar aviso num totem.
        setTimeout(() => setFail(null), 6000);
        void load();
      }
    },
    [load],
  );

  // ---------------- som ----------------
  // Os avisos saem da MUDANÇA de estado, nunca do estado em si: a tela
  // relê de 5 em 5 segundos, e falar o estado atual repetiria a frase.
  const live = data?.playing?.entry_id ?? null;
  const remaining = data?.remaining_seconds ?? 0;
  const warn = data?.warn_seconds ?? 60;

  useEffect(() => {
    if (!sound || !data) return;

    if (data.state === "ending" && live && saidOneMinute.current !== live) {
      saidOneMinute.current = live;
      SOUNDS.oneMinute(data.queue_count > 0);
    }

    const asking = data.exit_ask;
    if (asking && saidTurnOver.current !== asking.entry_id) {
      saidTurnOver.current = asking.entry_id;
      SOUNDS.turnOver(asking.name);
    }

    if (data.state === "playing" && live && saidStart.current !== live) {
      // Só anuncia o começo de quem entrou agora: no primeiro
      // carregamento da tela o jogo já pode estar correndo há 20 min.
      if (data.elapsed_seconds <= 15) SOUNDS.turnStart(data.playing?.name);
      saidStart.current = live;
    }

    if (data.pause && saidPause.current !== data.pause.kind) {
      saidPause.current = data.pause.kind;
      wasPaused.current = true;
      if (data.pause.seconds <= 15) SOUNDS.paused(data.pause.label);
    }
    if (!data.pause && wasPaused.current) {
      wasPaused.current = false;
      saidPause.current = null;
      SOUNDS.resumed();
    }
  }, [sound, data, live, remaining, warn]);

  const enableSound = async () => {
    const ok = await unlockSound();
    setSound(ok);
  };

  // ---------------- entrar na fila ----------------
  const confirmJoin = async () => {
    if (!token || !joining) return;
    const name = joining.name.trim();
    if (name.length < NAME_MIN) return;

    try {
      const result = await totemJoin(token, name, joining.size);
      setData(result.screen);
      setJoining(null);
      setFail(null);

      const row = result.screen.queue.find((q) => q.entry_id === result.entry_id);
      const when = row?.eta_at ? hhmmOf(new Date(row.eta_at)) : null;
      setToast({
        position: result.position ?? result.screen.queue_count,
        text: result.playing
          ? `${name}, ${pessoas(joining.size)}. A quadra estava livre: podem entrar agora.`
          : when
            ? `${name}, ${pessoas(joining.size)}. Previsão de entrar às ${when}. Fique perto da quadra.`
            : `${name}, ${pessoas(joining.size)}. A quadra está pausada, a previsão volta quando alguém retomar.`,
      });
      setTimeout(() => setToast(null), 4500);
    } catch (cause) {
      setFail((cause as Error).message);
      setTimeout(() => setFail(null), 6000);
    }
  };

  if (!token) return <div className="totem"><div className="totem-boot">Link do totem inválido.</div></div>;

  if (!data) {
    return (
      <div className="totem">
        <div className="totem-boot">
          {error ?? "Carregando a quadra…"}
        </div>
      </div>
    );
  }

  return (
    <div className="totem">
      <TotemBoard
        data={data}
        onJoin={() => setJoining({ name: "", size: 2 })}
        onContinue={() => void act(() => totemContinue(token))}
        onPause={(kind) => void act(() => totemPause(token, kind))}
        onResume={() => void act(() => totemResume(token))}
        onExitAnswer={(back) => void act(() => totemExitAnswer(token, back))}
      />

      {joining && (
        <JoinOverlay
          draft={joining}
          onChange={setJoining}
          onCancel={() => setJoining(null)}
          onConfirm={() => void confirmJoin()}
        />
      )}

      {toast && (
        <div className="totem-toast">
          <div className="k">{toast.position}º</div>
          <div className="t">{toast.position === 1 && data.playing ? "Você é o próximo" : "Você está na fila"}</div>
          <div className="s">{toast.text}</div>
        </div>
      )}

      {fail && <div className="totem-fail">{fail}</div>}

      {!sound && (
        <button type="button" className="totem-sound" onClick={() => void enableSound()}>
          Ativar som
        </button>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------
// A tela, sem nada de rede: é esta parte que os testes desenham.
// ---------------------------------------------------------------------

export interface TotemBoardProps {
  data: TotemState;
  onJoin?: () => void;
  onContinue?: () => void;
  onPause?: (kind: PauseKind) => void;
  onResume?: () => void;
  onExitAnswer?: (back: boolean) => void;
}

export function TotemBoard({
  data,
  onJoin,
  onContinue,
  onPause,
  onResume,
  onExitAnswer,
}: TotemBoardProps) {
  const paused = data.state === "paused";
  const gap = data.state === "changeover";
  const last = data.state === "ending";
  const live = data.state === "playing" || last;

  const stageClass = [
    "totem-stage",
    last ? "is-last" : "",
    gap || data.state === "free" ? "is-gap" : "",
    paused ? "is-paused" : "",
  ]
    .filter(Boolean)
    .join(" ");

  const big = paused
    ? mmss(data.pause?.seconds ?? 0)
    : live
      ? mmss(data.remaining_seconds)
      : gap
        ? mmss(data.changeover_left)
        : "--:--";

  const eyebrow = paused
    ? `Pausada · ${data.pause?.label ?? ""}`
    : last
      ? data.queue_count > 0
        ? "Acabando, liberem a quadra"
        : "Acabando"
      : live
        ? "Em jogo, faltam"
        : gap
          ? "Trocando de jogo"
          : "Quadra livre";

  const who = paused
    ? "Ninguém entra agora"
    : live
      ? (data.playing?.name ?? "Em quadra")
      : gap
        ? data.next
          ? `Entra: ${data.next.name}`
          : "Quadra livre"
        : "Ninguém em quadra";

  const sub = paused
    ? `${data.pause?.desc ?? ""} A fila está parada.`
    : last && data.next
      ? `Entra em seguida: ${data.next.name}`
      : live && data.playing
        ? `${data.playing.label} · ${pessoas(data.playing.size)}`
        : gap
          ? data.next
            ? "Pode ir entrando na quadra"
            : "Nenhuma party na fila"
          : "Entre na fila e comece a jogar";

  const elapsed = paused
    ? `pausada há ${mmss(data.pause?.seconds ?? 0)}\nvolta quando alguém retomar`
    : live
      ? `em quadra há ${mmss(data.elapsed_seconds)}\npartida de ${data.slot_minutes} min`
      : gap
        ? `troca de ${mmss(data.changeover_seconds)}`
        : "";

  const progress = live
    ? (data.slot_seconds - data.remaining_seconds) / Math.max(1, data.slot_seconds)
    : gap
      ? 1 - data.changeover_left / Math.max(1, data.changeover_seconds)
      : 0;

  return (
    <div className="totem-inner">
      <div className="totem-strip">
        <div className="id">{data.court.strip}</div>
        <div className="clock">{hhmmOf(new Date())}</div>
      </div>

      <div className={stageClass}>
        <div className="totem-eyebrow">{eyebrow}</div>
        <div className="totem-bigtime">{big}</div>
        <div className="totem-stagerow">
          <div className="totem-players">
            {who}
            <small>{sub}</small>
          </div>
          <div className="totem-elapsed">{elapsed}</div>
        </div>
        <div className={live ? "totem-lane" : "totem-lane off"}>
          <div className="totem-ball" />
        </div>
        {!paused && data.state !== "free" && (
          <div className="totem-bar">
            <i style={{ width: `${Math.min(100, Math.max(0, progress * 100))}%` }} />
          </div>
        )}
      </div>

      {data.armed_pause && (
        <div className="totem-notice">
          <b>{data.armed_pause.label} agendado.</b> Começa quando este jogo acabar e segura a
          fila até alguém retomar. Toque de novo para cancelar.
        </div>
      )}

      {data.exit_ask && (
        <div className="totem-exitask">
          <div className="q">
            <b>{data.exit_ask.name}</b>
            {", acabou seu tempo. Quer sair ou voltar pro fim da fila?"}
          </div>
          <div className="opts">
            <button type="button" className="back" onClick={() => onExitAnswer?.(true)}>
              Voltar pra fila
            </button>
            <button type="button" className="out" onClick={() => onExitAnswer?.(false)}>
              Sair
            </button>
          </div>
        </div>
      )}

      <div className="totem-queuehead">
        <h2>Fila</h2>
        <span>
          {data.queue_count === 0
            ? "vazia"
            : `${data.queue_count} ${data.queue_count === 1 ? "party esperando" : "parties esperando"}`}
        </span>
      </div>

      <QueueList rows={data.queue} />

      <div className="totem-actions">
        {data.can_continue && (
          <button type="button" className="totem-btn totem-continue" onClick={() => onContinue?.()}>
            <b>Continuar jogando</b>
            <span>Mais {data.slot_minutes} min, só com a fila vazia</span>
          </button>
        )}

        <button type="button" className="totem-btn totem-join" onClick={() => onJoin?.()}>
          <b>Entrar na fila</b>
          <span>Seu nome e quantas pessoas vão jogar</span>
        </button>

        {/* Um comando de cada vez: com a quadra pausada o grupo de
            pausar sai e entra o Retomar. Três botões de pausar ao lado
            de um de despausar é confusão garantida. */}
        {paused ? (
          <button type="button" className="totem-btn totem-resume" onClick={() => onResume?.()}>
            <b>Retomar a quadra</b>
          </button>
        ) : (
          <div className="totem-pausegroup">
            <div className="lbl">Pausar a quadra</div>
            <div className="totem-pauses">
              {PAUSES.map((p) => (
                <button
                  key={p.kind}
                  type="button"
                  className={
                    data.armed_pause?.kind === p.kind
                      ? "totem-btn totem-pause armed"
                      : "totem-btn totem-pause"
                  }
                  onClick={() => onPause?.(p.kind)}
                >
                  <b>{p.title}</b>
                  <span>{p.desc}</span>
                </button>
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

/**
 * A fila inteira, rolável.
 *
 * Volta sozinha para o topo depois de 12 segundos sem toque: a próxima
 * pessoa não pode encontrar a tela no meio da lista.
 */
function QueueList({ rows }: { rows: TotemQueueRow[] }) {
  const box = useRef<HTMLDivElement | null>(null);
  const lastTouch = useRef(0);

  useEffect(() => {
    const id = setInterval(() => {
      const el = box.current;
      if (!el) return;
      if (el.scrollTop > 0 && Date.now() - lastTouch.current > SCROLL_RESET_MS) {
        el.scrollTop = 0;
      }
    }, 1000);
    return () => clearInterval(id);
  }, []);

  const scrollable = useMemo(() => rows.length > 4, [rows.length]);

  return (
    <div
      ref={box}
      className={scrollable ? "totem-queue scrollable" : "totem-queue"}
      onScroll={() => {
        lastTouch.current = Date.now();
      }}
    >
      {rows.length === 0 && (
        <div className="totem-empty">Ninguém na fila. Quem entrar agora joga em seguida.</div>
      )}

      {rows.map((row) => (
        <div key={row.entry_id} className={row.is_next ? "totem-row next" : "totem-row"}>
          <div className="pos">{row.position}</div>
          <div className="who">
            <b>{row.name}</b>
            <span>
              {pessoas(row.size)}
              {row.is_next ? " · próximo" : ""}
            </span>
          </div>
          <div className="when">
            {row.eta_seconds === null ? (
              <>
                <b>--:--</b>
                <span>depois da pausa</span>
              </>
            ) : (
              <>
                <b>{row.eta_at ? hhmmOf(new Date(row.eta_at)) : "--:--"}</b>
                <span>{emMin(row.eta_seconds)}</span>
              </>
            )}
          </div>
        </div>
      ))}
    </div>
  );
}

/**
 * Entrar na fila: nome no teclado da tela e quantas pessoas.
 *
 * O teclado é desenhado aqui, e não é o do sistema: em modo quiosque o
 * teclado do sistema costuma estar bloqueado, e quando não está é uma
 * rota de fuga da aplicação.
 */
function JoinOverlay({
  draft,
  onChange,
  onCancel,
  onConfirm,
}: {
  draft: Pending;
  onChange: (next: Pending) => void;
  onCancel: () => void;
  onConfirm: () => void;
}) {
  const type = (key: string) => {
    if (key === "DEL") {
      onChange({ ...draft, name: draft.name.slice(0, -1) });
      return;
    }
    if (draft.name.length >= NAME_MAX) return;
    onChange({ ...draft, name: draft.name + key });
  };

  const step = (delta: number) =>
    onChange({ ...draft, size: Math.max(1, Math.min(20, draft.size + delta)) });

  const ready = draft.name.trim().length >= NAME_MIN;

  return (
    <div className="totem-overlay">
      <h2>Entrar na fila</h2>

      <div className="totem-field">
        <label htmlFor="totem-name">Seu nome e sobrenome</label>
        <div className={draft.name.trim() ? "val" : "val ph"} id="totem-name">
          {draft.name.trim() ? draft.name : "toque nas letras"}
          <span className="totem-caret" />
        </div>
      </div>

      <div className="totem-field">
        <label htmlFor="totem-size">Quantas pessoas vão jogar</label>
        <div className="totem-stepper" id="totem-size">
          <button
            type="button"
            className="totem-st"
            disabled={draft.size <= 1}
            onClick={() => step(-1)}
          >
            −
          </button>
          <div className="totem-stval">{draft.size}</div>
          <button type="button" className="totem-st" onClick={() => step(1)}>
            +
          </button>
        </div>
        <div className="totem-hint">{sizeHint(draft.size)}</div>
      </div>

      <div className="totem-kb">
        {ROWS.map((row, i) => (
          <div key={row} className="totem-kbrow">
            {i === 2 && (
              <button type="button" className="totem-key del" onClick={() => type("DEL")}>
                apagar
              </button>
            )}
            {row.split("").map((c) => (
              <button key={c} type="button" className="totem-key" onClick={() => type(c)}>
                {c}
              </button>
            ))}
          </div>
        ))}
        <div className="totem-kbrow">
          <button type="button" className="totem-key wide" onClick={() => type(" ")}>
            espaço
          </button>
        </div>
      </div>

      <div className="totem-ovfoot">
        <button type="button" className="totem-cancel" onClick={onCancel}>
          Cancelar
        </button>
        <button type="button" className="totem-confirm" disabled={!ready} onClick={onConfirm}>
          Confirmar
        </button>
      </div>
    </div>
  );
}
