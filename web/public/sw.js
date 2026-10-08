/**
 * Service worker do NEQST.
 *
 * Dois papéis:
 *   1. Receber o Web Push ("Prepare-se!", "É a sua vez!") — sem service
 *      worker registrado o navegador não entrega push nenhum.
 *   2. Cache leve do shell, para o app abrir no 3G ruim. A FILA NUNCA é
 *      cacheada: mostrar posição velha é pior que mostrar erro.
 */

const SHELL_CACHE = "neqst-shell-v1";
const SHELL_FILES = ["/", "/index.html", "/manifest.webmanifest", "/icons/icon-192.png"];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(SHELL_CACHE).then((cache) => cache.addAll(SHELL_FILES)).then(() => self.skipWaiting()),
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== SHELL_CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const { request } = event;
  if (request.method !== "GET") return;

  const url = new URL(request.url);

  // Nada de API/Supabase no cache: dado de fila tem que ser fresco.
  if (url.origin !== self.location.origin) return;
  if (url.pathname.startsWith("/rest/") || url.pathname.startsWith("/functions/")) return;

  // Navegação: rede primeiro, cache como rede de segurança (SPA).
  if (request.mode === "navigate") {
    event.respondWith(
      fetch(request).catch(() => caches.match("/index.html").then((r) => r ?? Response.error())),
    );
    return;
  }

  // Assets com hash no nome: cache primeiro.
  if (url.pathname.startsWith("/assets/") || url.pathname.startsWith("/icons/")) {
    event.respondWith(
      caches.match(request).then((cached) =>
        cached ??
          fetch(request).then((response) => {
            const copy = response.clone();
            caches.open(SHELL_CACHE).then((cache) => cache.put(request, copy));
            return response;
          })
      ),
    );
  }
});

// ---------------------------------------------------------------------
// Push
// ---------------------------------------------------------------------

self.addEventListener("push", (event) => {
  if (!event.data) return;

  let payload = {};
  try {
    payload = event.data.json();
  } catch {
    payload = { title: "NEQST", body: event.data.text() };
  }

  const data = payload.data ?? {};

  event.waitUntil(
    self.registration.showNotification(payload.title ?? "NEQST", {
      body: payload.body ?? "",
      icon: "/icons/icon-192.png",
      badge: "/icons/icon-192.png",
      // Mesma tag por time: o aviso novo substitui o anterior em vez de
      // empilhar três "Prepare-se!" na gaveta.
      tag: data.entryId ?? "neqst",
      renotify: true,
      requireInteraction: data.type === "queue_turn",
      vibrate: data.type === "queue_turn" ? [60, 40, 60, 40, 120] : [40, 30, 40],
      data,
    }),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();

  const courtId = event.notification.data?.courtId;
  const target = courtId ? `/quadra/${courtId}` : "/";

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clients) => {
      const open = clients.find((client) => client.url.includes(target));
      if (open) return open.focus();

      const any = clients[0];
      if (any) {
        any.navigate(target);
        return any.focus();
      }
      return self.clients.openWindow(target);
    }),
  );
});
