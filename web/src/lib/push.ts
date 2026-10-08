/**
 * Web Push. A Expo Push API não entrega em navegador, então a versão web
 * usa o protocolo padrão com a chave VAPID do backend.
 *
 * No iOS só funciona com o site instalado na tela de início (PWA), a
 * partir do iOS 16.4 — o app avisa em vez de prometer o que não vai
 * acontecer.
 */
import { registerWebPush, vapidPublicKey } from "./api";
import { env } from "./env";

export const pushSupported = () =>
  "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;

/** PWA instalado? No iOS é o que separa push de nada. */
export const isStandalone = () =>
  window.matchMedia("(display-mode: standalone)").matches ||
  (window.navigator as { standalone?: boolean }).standalone === true;

export const isIos = () => /iPad|iPhone|iPod/.test(navigator.userAgent);

function urlBase64ToUint8Array(base64: string): Uint8Array {
  const padded = base64.replace(/-/g, "+").replace(/_/g, "/") +
    "=".repeat((4 - (base64.length % 4)) % 4);
  const raw = atob(padded);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  return bytes;
}

export async function registerServiceWorker(): Promise<ServiceWorkerRegistration | null> {
  if (!("serviceWorker" in navigator)) return null;
  try {
    return await navigator.serviceWorker.register("/sw.js", { scope: "/" });
  } catch {
    return null;
  }
}

export type PushResult = "subscribed" | "denied" | "unsupported" | "needs-install" | "no-vapid";

export async function enablePush(): Promise<PushResult> {
  if (!pushSupported()) return "unsupported";
  if (isIos() && !isStandalone()) return "needs-install";

  const registration = (await navigator.serviceWorker.getRegistration()) ??
    (await registerServiceWorker());
  if (!registration) return "unsupported";

  const permission = await Notification.requestPermission();
  if (permission !== "granted") return "denied";

  // A chave pública pode vir do build ou do próprio backend.
  let key = env.vapidPublicKey;
  if (!key) {
    key = await vapidPublicKey().then((r) => r.publicKey).catch(() => undefined);
  }
  if (!key) return "no-vapid";

  const existing = await registration.pushManager.getSubscription();
  const subscription = existing ??
    (await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(key) as BufferSource,
    }));

  await registerWebPush(subscription.toJSON());
  return "subscribed";
}
