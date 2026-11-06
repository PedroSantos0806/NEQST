/**
 * O som da quadra.
 *
 * O totem fica numa quadra pública, a cinco metros de quem está
 * jogando: é por ele que a quadra avisa que o tempo está acabando e
 * pergunta a quem acabou se volta para a fila. Quem está em quadra não
 * vai olhar tela.
 *
 * Dois recursos do próprio navegador, nenhum arquivo de áudio:
 *
 *   . WebAudio para os apitos. Um bip gerado na hora não depende de
 *     arquivo baixado, não tem licença e toca mesmo offline.
 *   . speechSynthesis para os nomes. É a única forma de falar "Rafael
 *     Lima" — áudio gravado nunca saberia o nome de quem chegou hoje.
 *
 * O navegador não deixa tocar som antes de alguém tocar na tela, então
 * a tela do totem pede um toque uma vez ("Ativar som") e depois disso
 * o resto acontece sozinho.
 */

let audio: AudioContext | null = null;
let unlocked = false;

function context(): AudioContext | null {
  if (audio) return audio;
  const Ctor = window.AudioContext
    ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
  if (!Ctor) return null;
  try {
    audio = new Ctor();
  } catch {
    audio = null;
  }
  return audio;
}

/** O som está liberado neste aparelho? */
export const soundReady = (): boolean => unlocked;

/**
 * Libera o áudio. Precisa ser chamada de dentro de um toque na tela —
 * é a regra do navegador, não uma escolha nossa.
 */
export async function unlockSound(): Promise<boolean> {
  const ctx = context();
  if (ctx) {
    try {
      if (ctx.state === "suspended") await ctx.resume();
    } catch {
      // Segue mesmo assim: a fala pode funcionar sem o WebAudio.
    }
  }

  // O iOS só libera a fala se a primeira chamada vier de um gesto. Uma
  // fala vazia resolve sem fazer barulho.
  try {
    const empty = new SpeechSynthesisUtterance(" ");
    empty.volume = 0;
    window.speechSynthesis?.speak(empty);
  } catch {
    // Sem fala: os apitos continuam valendo.
  }

  unlocked = Boolean(ctx) || Boolean(window.speechSynthesis);
  return unlocked;
}

type Note = { hz: number; ms: number; gap?: number };

function play(notes: Note[]): void {
  const ctx = context();
  if (!ctx || ctx.state !== "running") return;

  let at = ctx.currentTime;
  for (const note of notes) {
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.type = "sine";
    osc.frequency.value = note.hz;

    // Sobe e desce o volume: um oscilador ligado e desligado seco
    // estala, e estalo a cinco metros parece defeito.
    const seconds = note.ms / 1000;
    gain.gain.setValueAtTime(0, at);
    gain.gain.linearRampToValueAtTime(0.6, at + 0.015);
    gain.gain.setValueAtTime(0.6, at + seconds - 0.03);
    gain.gain.linearRampToValueAtTime(0, at + seconds);

    osc.connect(gain).connect(ctx.destination);
    osc.start(at);
    osc.stop(at + seconds);
    at += seconds + (note.gap ?? 0.06) ;
  }
}

/** Fala um texto em português. Uma fala por vez: a última manda. */
export function say(text: string): void {
  const speech = window.speechSynthesis;
  if (!speech || !text) return;

  try {
    speech.cancel();
    const utterance = new SpeechSynthesisUtterance(text);
    utterance.lang = "pt-BR";
    utterance.rate = 0.95;
    utterance.volume = 1;

    const voice = speech.getVoices().find((v) => v.lang?.toLowerCase().startsWith("pt"));
    if (voice) utterance.voice = voice;

    speech.speak(utterance);
  } catch {
    // Aparelho sem voz instalada: ficam os apitos.
  }
}

/**
 * O que a quadra fala quando o tempo de alguém acaba.
 *
 * Separado do resto para poder ser testado: é a frase que vai ecoar no
 * parque, e é a mesma da faixa na tela — quem está de costas ouve, quem
 * está de frente lê, e os dois recebem a mesma pergunta.
 */
export function exitAskText(name: string | null | undefined): string {
  const who = (name ?? "").trim();
  return who
    ? `${who}, acabou seu tempo. Quer sair ou voltar pro fim da fila?`
    : "Acabou o tempo. Liberem a quadra, por favor.";
}

/** O que a quadra fala quando a troca acaba e o próximo entra. */
export function turnStartText(name: string | null | undefined): string {
  const who = (name ?? "").trim();
  return who
    ? `Começou o tempo da quadra. Bom jogo, ${who}!`
    : "Começou o tempo de quadra. Bom jogo!";
}

export const SOUNDS = {
  /** Falta 1 minuto para o turno acabar. */
  oneMinute(hasQueue: boolean): void {
    play([{ hz: 880, ms: 140 }, { hz: 880, ms: 140 }]);
    say(hasQueue ? "Falta um minuto. Liberem a quadra." : "Falta um minuto.");
  },

  /** Acabou o tempo: a pergunta de saída, em voz alta. */
  turnOver(name: string | null | undefined): void {
    play([{ hz: 660, ms: 220 }, { hz: 520, ms: 220 }, { hz: 400, ms: 420 }]);
    say(exitAskText(name));
  },

  /** Começou o tempo de quadra. */
  turnStart(name: string | null | undefined): void {
    play([{ hz: 520, ms: 150 }, { hz: 660, ms: 150 }, { hz: 880, ms: 320 }]);
    say(turnStartText(name));
  },

  /** A quadra parou para manutenção. */
  paused(label: string): void {
    play([{ hz: 440, ms: 180 }, { hz: 330, ms: 300 }]);
    say(`Quadra pausada: ${label}. A fila está parada.`);
  },

  /** E voltou. */
  resumed(): void {
    play([{ hz: 660, ms: 140 }, { hz: 880, ms: 220 }]);
    say("Quadra liberada. A fila voltou a andar.");
  },
};
