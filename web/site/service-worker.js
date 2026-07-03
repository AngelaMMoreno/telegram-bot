/* ============================================================================
 * Aprentix · Service Worker
 *
 * Responsabilidades (fase 1):
 *   - Precachear el "app shell" para arranque offline y latencia baja.
 *   - Cachear estáticos con stale-while-revalidate.
 *   - Nunca tocar /api/* (siempre red, para no servir datos rancios).
 *   - Fallback SPA: si la navegación offline no encuentra un HTML, servir
 *     /index.html (el router del cliente pintará algo o mostrará login).
 *
 * Fases siguientes añadirán aquí:
 *   - handler 'push'   → notificaciones (repasos vencidos, retos, inactividad)
 *   - handler 'notificationclick' → deep-link a la vista correspondiente
 *
 * Convención de versionado:
 *   Sube CACHE_VERSION cada vez que cambies un fichero del shell para forzar
 *   invalidación en el próximo arranque. El SW hace skipWaiting +
 *   clients.claim para que la actualización se aplique al siguiente refresh.
 * ==========================================================================*/

const CACHE_VERSION = "aprentix-v1";
const SHELL_CACHE   = `${CACHE_VERSION}-shell`;
const RUNTIME_CACHE = `${CACHE_VERSION}-runtime`;

const SHELL_ASSETS = [
  "/",
  "/index.html",
  "/app.js",
  "/style.css",
  "/manifest.webmanifest",
  "/shared/tokens.css",
  "/shared/base.css",
  "/shared/header.css",
  "/shared/config.css",
  "/shared/header.js",
  "/shared/logo.svg",
  "/shared/pwa-icons/icon-any-192.png",
  "/shared/pwa-icons/icon-any-512.png",
  "/shared/pwa-icons/icon-any.svg",
  "/shared/pwa-icons/icon-mono.svg",
  "/shared/pwa-icons/apple-touch-icon.png",
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(SHELL_CACHE)
      // addAll rompe si falla cualquiera; usamos add individual con catch
      // para tolerar 404 de assets opcionales sin invalidar la instalación.
      .then((cache) =>
        Promise.all(
          SHELL_ASSETS.map((url) =>
            cache.add(new Request(url, { cache: "reload" })).catch(() => null)
          )
        )
      )
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    (async () => {
      const names = await caches.keys();
      await Promise.all(
        names
          .filter((n) => !n.startsWith(CACHE_VERSION))
          .map((n) => caches.delete(n))
      );
      await self.clients.claim();
    })()
  );
});

/* ── Estrategias por tipo de request ───────────────────────────────────── */
function isApi(url)      { return url.pathname.startsWith("/api/"); }
function isNavigation(r) { return r.mode === "navigate"; }
function isStatic(url) {
  return /\.(css|js|svg|png|jpg|jpeg|webp|ico|woff2?|ttf|webmanifest)$/i.test(
    url.pathname
  );
}

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  // Nunca cachear la API: siempre red.
  if (isApi(url)) return;

  // Navegaciones: network-first con fallback a index.html cacheado.
  if (isNavigation(req)) {
    event.respondWith(
      (async () => {
        try {
          const fresh = await fetch(req);
          const cache = await caches.open(RUNTIME_CACHE);
          cache.put(req, fresh.clone());
          return fresh;
        } catch (_) {
          const shell = await caches.match("/index.html");
          return shell || Response.error();
        }
      })()
    );
    return;
  }

  // Estáticos: stale-while-revalidate.
  if (isStatic(url)) {
    event.respondWith(
      (async () => {
        const cache = await caches.open(RUNTIME_CACHE);
        const cached = await cache.match(req);
        const network = fetch(req)
          .then((res) => {
            if (res && res.status === 200) cache.put(req, res.clone());
            return res;
          })
          .catch(() => null);
        return cached || (await network) || Response.error();
      })()
    );
  }
});

/* ── Canal para que la app pida "actualízate ya" ───────────────────────── */
self.addEventListener("message", (event) => {
  if (event.data === "SKIP_WAITING") self.skipWaiting();
});


/* ── Notificaciones Web Push ────────────────────────────────────────────
 *
 * El servidor envía payloads JSON con { title, body, tag, url, icon }.
 * - Si el JSON no parsea, mostramos un aviso genérico (nunca callar el
 *   push: navegadores desregistran suscripciones que "reciben pero no
 *   muestran nada").
 * - Usamos `tag` para que los avisos del mismo tipo (p. ej. "repaso") se
 *   agrupen en uno solo, no en un stack de N notificaciones.
 * - En notificationclick enfocamos una pestaña abierta si la hay, o
 *   abrimos una nueva apuntando a la URL indicada (los shortcuts
 *   `?atajo=repasar` los interpreta la SPA para llevar al usuario a la
 *   vista correspondiente).
 */
const ICON_DEFAULT = "/shared/pwa-icons/icon-any-192.png";
const BADGE_DEFAULT = "/shared/pwa-icons/icon-mono.svg";

self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (_) { data = {}; }

  const title = data.title || "Aprentix";
  const options = {
    body:  data.body  || "Tienes una novedad en Aprentix.",
    tag:   data.tag   || "aprentix",
    icon:  data.icon  || ICON_DEFAULT,
    badge: data.badge || BADGE_DEFAULT,
    data:  { url: data.url || "/" },
    renotify: true,      // vibra aunque haya una con el mismo tag
    requireInteraction: false,
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = (event.notification.data && event.notification.data.url) || "/";

  event.waitUntil((async () => {
    const clients = await self.clients.matchAll({
      type: "window",
      includeUncontrolled: true,
    });
    // Si ya hay una pestaña de Aprentix abierta, foco + navega.
    for (const c of clients) {
      try {
        const u = new URL(c.url);
        if (u.origin === self.location.origin) {
          await c.focus();
          if (c.url !== self.location.origin + url && "navigate" in c) {
            await c.navigate(url);
          }
          return;
        }
      } catch (_) { /* c.url puede ser about:blank */ }
    }
    // Si no, abrimos una nueva.
    await self.clients.openWindow(url);
  })());
});

// Cuando el navegador rota las claves de la suscripción, avísalo a la app
// para que re-registre. No hay backend action aquí: el frontend re-llamará
// a guardar_push_suscripcion() con la nueva.
self.addEventListener("pushsubscriptionchange", (event) => {
  event.waitUntil((async () => {
    const clients = await self.clients.matchAll({ includeUncontrolled: true });
    for (const c of clients) c.postMessage({ type: "PUSH_SUBSCRIPTION_CHANGE" });
  })());
});
