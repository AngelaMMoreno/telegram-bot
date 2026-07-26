/* ============================================================================
 * Aprentix · Service Worker (root)
 *
 * Se sirve en aprentix.es/service-worker.js con scope "/". La única SPA es
 * /estudio/*; la raíz redirige ahí. El SW cubre todo el origin para que la
 * PWA quede instalable desde aprentix.es y desde /estudio/ indistintamente.
 *
 * Responsabilidades:
 *   - Precachear el "app shell" de /estudio (arranque offline mínimo).
 *   - Cachear estáticos con stale-while-revalidate.
 *   - Nunca tocar /api/*  (siempre red, para no servir datos rancios).
 *   - Fallback SPA: si la navegación offline no encuentra un HTML,
 *     servir el index de /estudio cacheado.
 *
 * Push notifications: mismo comportamiento que antes.
 *
 * Convención de versionado:
 *   Sube CACHE_VERSION al cambiar el shell para forzar invalidación en el
 *   próximo arranque. skipWaiting + clients.claim aplican la actualización
 *   en el siguiente refresh.
 * ==========================================================================*/

// Retirada de landing y /tests: v18 invalida cachés que apuntaban a esas
// rutas para que los clientes existentes se limpien en el siguiente arranque.
const CACHE_VERSION = "aprentix-v18";
const SHELL_CACHE   = `${CACHE_VERSION}-shell`;
const RUNTIME_CACHE = `${CACHE_VERSION}-runtime`;

// Con scope "/" BASE apunta al origin root. Todas las rutas del shell son
// absolutas (empiezan por "/") para no depender del path del SW.
const BASE = new URL("/", self.location.href);
function urlAt(p) { return new URL(p, BASE).toString(); }

// Precache: la SPA de estudio + el manifest + los assets compartidos que
// arrancan en el primer render. Todo lo demás (vendor, css secundarios) se
// cachea al vuelo con stale-while-revalidate.
const SHELL_ASSETS = [
  "/estudio/",
  "/estudio/index.html",
  "/estudio/app.js",
  "/estudio/style.css",
  "/manifest.webmanifest",
  "/shared/tokens.css",
  "/shared/base.css",
  "/shared/components.css",
  "/shared/modal.css",
  "/shared/header.css",
  "/shared/auth/session.js",
  "/shared/header.js",
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
// El SW cubre todo el origin. La API vive bajo /api/ (postgrest) y
// /teoria/api/ (uvicorn); las dos las cubre includes("/api/") para no
// cachear nunca datos dinámicos.
function isApi(url)      { return url.pathname.includes("/api/"); }
function isNavigation(r) { return r.mode === "navigate"; }
function isStatic(url) {
  return /\.(css|js|svg|png|jpg|jpeg|webp|ico|woff2?|ttf|webmanifest)$/i.test(
    url.pathname
  );
}

// Fallback HTML offline: siempre el index de /estudio (la única SPA).
async function navigationFallback() {
  for (const path of ["/estudio/index.html", "/estudio/"]) {
    const hit = await caches.match(urlAt(path));
    if (hit) return hit;
  }
  return Response.error();
}

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  // Nunca cachear la API: siempre red.
  if (isApi(url)) return;

  // Navegaciones: network-first con fallback a un HTML cacheado.
  if (isNavigation(req)) {
    event.respondWith(
      (async () => {
        try {
          const fresh = await fetch(req);
          const cache = await caches.open(RUNTIME_CACHE);
          cache.put(req, fresh.clone());
          return fresh;
        } catch (_) {
          return navigationFallback();
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
const ICON_DEFAULT = urlAt("/shared/pwa-icons/icon-any-192.png");
const BADGE_DEFAULT = urlAt("/shared/pwa-icons/icon-mono.svg");

self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (_) { data = {}; }

  const title = data.title || "Aprentix";
  const options = {
    body:  data.body  || "Tienes una novedad en Aprentix.",
    tag:   data.tag   || "aprentix",
    icon:  data.icon  || ICON_DEFAULT,
    badge: data.badge || BADGE_DEFAULT,
    data:  { url: data.url || "/estudio/" },
    renotify: true,      // vibra aunque haya una con el mismo tag
    requireInteraction: false,
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = (event.notification.data && event.notification.data.url) || "/estudio/";

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
