/**
 * "Instalar o app" para quem chega pelo QR na tela de alguém da fila.
 *
 * No Android, o Chrome oferece a instalação do site (PWA) pelo evento
 * `beforeinstallprompt`, que dispara uma vez, cedo. Guardamos o evento
 * no import do módulo para o botão poder usá-lo quando a pessoa tocar.
 * No iPhone não existe esse evento: o caminho é o menu Compartilhar, e
 * o app só explica. Com VITE_PLAY_STORE_URL definido, o link da loja
 * aparece também.
 */
import { env } from "./env";
import { isIos, isStandalone } from "./push";

interface InstallPromptEvent extends Event {
  prompt(): Promise<void>;
  userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
}

let deferred: InstallPromptEvent | null = null;

if (typeof window !== "undefined") {
  window.addEventListener("beforeinstallprompt", (event) => {
    // Sem isto o Chrome mostra a própria barra num momento qualquer; o
    // convite oferece a instalação na hora certa.
    event.preventDefault();
    deferred = event as InstallPromptEvent;
  });
}

export type InstallOption = "installed" | "prompt" | "ios" | "none";

export function installOption(): InstallOption {
  if (isStandalone()) return "installed";
  if (deferred) return "prompt";
  if (isIos()) return "ios";
  return "none";
}

/** Abre o diálogo de instalação do navegador. true se a pessoa aceitou. */
export async function promptInstall(): Promise<boolean> {
  if (!deferred) return false;
  const event = deferred;
  deferred = null;
  await event.prompt();
  const choice = await event.userChoice;
  return choice.outcome === "accepted";
}

export const playStoreUrl = () => env.playStoreUrl;

/**
 * Um identificador por navegador, só para contar aberturas do convite
 * sem repetir quem recarrega a página. Não identifica ninguém.
 */
export function visitorId(): string {
  const KEY = "neqst:visitor";
  try {
    const known = localStorage.getItem(KEY);
    if (known) return known;
    const fresh = Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => b.toString(16).padStart(2, "0")).join("");
    localStorage.setItem(KEY, fresh);
    return fresh;
  } catch {
    // Modo privado: conta a abertura desta visita.
    return Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => b.toString(16).padStart(2, "0")).join("");
  }
}
