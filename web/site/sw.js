/* Aprentix service worker.
 *
 * Objetivos:
 *   1) Recibir push notifications y mostrarlas al usuario.
 *   2) Dar respuesta cuando pulsa la notificación (abre la app en la
 *      ruta correspondiente).
 *   3) NO cachear nada agresivamente (la SPA es pequeña y a Caddy le
 *      damos zstd/gzip). Estrategia network-first con fallback offline
 *      básico solo para el shell (index.html + iconos).
 */

const CACHE = 'aprentix-shell-v1';
const SHELL = [
  '/',
  '/index.html',
  '/style.css',
  '/app.js',
  '/gamification.js',
  '/shared/tokens.css',
  '/shared/base.css',
  '/shared/header.css',
  '/shared/config.css',
  '/shared/header.js',
  '/shared/logo.svg',
  '/icons/icon-192.png',
  '/icons/icon-512.png',
  '/icons/apple-touch-icon.png',
  '/manifest.webmanifest',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE).then((c) => c.addAll(SHELL)).catch(() => {})
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  // Nunca cachear llamadas a la API.
  if (url.pathname.startsWith('/api/')) return;

  // Estrategia network-first para la SPA; fallback al cache si offline.
  if (req.mode === 'navigate' || req.destination === 'document') {
    event.respondWith((async () => {
      try {
        const fresh = await fetch(req);
        const c = await caches.open(CACHE);
        c.put('/index.html', fresh.clone());
        return fresh;
      } catch (_) {
        const cached = await caches.match('/index.html');
        return cached || Response.error();
      }
    })());
    return;
  }

  // Assets: stale-while-revalidate.
  if (SHELL.includes(url.pathname) || url.pathname.startsWith('/icons/')) {
    event.respondWith((async () => {
      const c = await caches.open(CACHE);
      const cached = await c.match(req);
      const fetching = fetch(req).then((r) => { c.put(req, r.clone()); return r; })
                                 .catch(() => cached);
      return cached || fetching;
    })());
  }
});

/* ─── Web Push ─────────────────────────────────────────────────────────── */

self.addEventListener('push', (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (_) {
    data = { title: 'Aprentix', body: event.data ? event.data.text() : '' };
  }

  const title = data.title || 'Aprentix';
  const options = {
    body:  data.body || '',
    icon:  '/icons/icon-192.png',
    badge: '/icons/icon-monochrome-512.png',
    // Un solo tipo agrupa (el digest de repasos reemplaza al anterior).
    tag:   data.tipo || 'aprentix',
    renotify: data.tipo === 'amigo_reto' || data.tipo === 'amistad_solicitud',
    data:  { url: data.url || '/', tipo: data.tipo, datos: data.datos || {} },
    // iOS ignora estas dos pero no pasa nada por incluirlas.
    vibrate: [40, 80, 40],
    silent:  data.silent === true,
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const targetUrl = (event.notification.data && event.notification.data.url) || '/';

  event.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    // Si ya hay una ventana de nuestra app abierta, la enfocamos y le
    // decimos qué ruta cargar.
    for (const w of wins) {
      try {
        await w.focus();
        w.postMessage({ type: 'aprentix:navigate', url: targetUrl });
        return;
      } catch (_) { /* fall through to openWindow */ }
    }
    await self.clients.openWindow(targetUrl);
  })());
});

/* Si la suscripción caduca, avisar a la app cuando arranque. */
self.addEventListener('pushsubscriptionchange', (event) => {
  event.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const w of wins) w.postMessage({ type: 'aprentix:resubscribe' });
  })());
});
