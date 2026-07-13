/*
 * Aprentix · router SPA entre tests y teoría.
 *
 * Objetivo: al pulsar el switch de modo (o cualquier <a href="/tests/">
 * / <a href="/teoria/">) NO recargar la página, sino:
 *   1) fetch de la HTML del otro modo,
 *   2) extraer el contenido de <body> menos la cabecera compartida,
 *   3) reemplazar el contenido en la página actual con view-transition,
 *   4) actualizar los atributos de <aprentix-header> para reflejar el
 *      nuevo modo activo,
 *   5) desmontar la app actual y montar la del modo destino,
 *   6) history.pushState.
 *
 * Contrato: cada app expone en la ventana:
 *   window.APRENTIX_TESTS  = { mount, unmount, name: 'tests'  }
 *   window.APRENTIX_TEORIA = { mount, unmount, name: 'teoria' }
 *
 * Los dos ficheros app.js se cargan preventivamente desde ambas HTMLs
 * (tienen un guard de idempotencia interno, así que cargarlos dos veces
 * no vuelve a registrar listeners). En la primera carga sólo se auto-
 * monta la app que coincide con la URL; la otra queda dormida y la
 * activa el router al saltar.
 *
 * IMPORTANTE: los apps.js SÓLO deben hacer fetch a rutas absolutas
 * (/tests/api/... o /teoria/api/...). Como el router cambia
 * `location.pathname` pero no las bases de las peticiones, los apps
 * seguirían apuntando al backend correcto aun estando la barra de la
 * URL "en el otro modo" durante la transición.
 */
(function () {
  'use strict';

  if (window.APRENTIX_ROUTER) return;

  const MODES = {
    tests:  { url: '/tests/',  global: 'APRENTIX_TESTS',  script: '/tests/app.js'  },
    teoria: { url: '/teoria/', global: 'APRENTIX_TEORIA', script: '/teoria/app.js' },
  };

  /* Devuelve 'tests' | 'teoria' | null según la URL actual. */
  function detectMode(pathname) {
    if (/^\/tests(\/|$)/.test(pathname))  return 'tests';
    if (/^\/teoria(\/|$)/.test(pathname)) return 'teoria';
    return null;
  }

  /* Carga un script de forma perezosa. Devuelve una promesa que resuelve
   * cuando el script ha ejecutado (los IIFE de cada app son síncronos,
   * así que en cuanto onload dispara ya podemos llamar a su mount()). */
  function loadScript(src) {
    return new Promise((resolve, reject) => {
      // ¿Ya lo cargamos antes? Aunque tengan guard interno, evitamos
      // meter otro <script> igual en el DOM.
      if (document.querySelector(`script[data-spa-loaded="${src}"]`)) {
        resolve();
        return;
      }
      const s = document.createElement('script');
      s.src = src;
      s.defer = false;
      s.dataset.spaLoaded = src;
      s.onload = () => resolve();
      s.onerror = () => reject(new Error('No se pudo cargar ' + src));
      document.head.appendChild(s);
    });
  }

  /* Añade al <head> actual los stylesheets del documento destino que
   * aún no estén cargados. Cada app tiene su propio style.css con las
   * reglas de sus vistas (grid de carpetas en teoría, quiz-card en
   * tests, etc.). Sin esto, tras el swap el DOM del modo destino
   * saldría sin estilar. Comparamos por href absoluto para no meter
   * duplicados de las hojas compartidas (tokens/base/header/…). */
  function mergeStylesheets(nextDoc) {
    const yaCargados = new Set(
      Array.from(document.styleSheets).map(s => s.href).filter(Boolean)
    );
    const nuevos = Array.from(nextDoc.querySelectorAll('link[rel="stylesheet"]'));
    nuevos.forEach(link => {
      const abs = new URL(link.getAttribute('href'), nextDoc.baseURI || location.origin).href;
      if (yaCargados.has(abs)) return;
      const l = document.createElement('link');
      l.rel = 'stylesheet';
      l.href = abs;
      l.dataset.spaMode = 'true';
      document.head.appendChild(l);
      yaCargados.add(abs);
    });
  }

  /* Reemplaza el contenido "app-específico" del <body> con el del
   * documento destino. Preserva la cabecera <aprentix-header>, los
   * modales fijos que también viven fuera de contenido (toast,
   * logros-notif-stack) y el propio <script> del router. */
  function swapAppContent(nextDoc, nextMode) {
    // Nodos que se conservan tal cual entre modos.
    const KEEP = new Set(['APRENTIX-HEADER', 'SCRIPT', 'STYLE', 'LINK']);
    // ap-user-home-header: saludo + gamificación. Se preserva para que
    // el "Hola, X" y el nivel/XP no parpadeen al saltar entre tests y
    // teoría — su contenido es idéntico en ambas apps.
    const KEEP_IDS = new Set(['toast', 'logros-notif-stack', 'ap-user-home-header']);

    const body = document.body;
    const nextBody = nextDoc.body;

    // Quita del body actual todo lo que no sea persistente.
    Array.from(body.children).forEach(el => {
      if (KEEP.has(el.tagName)) return;
      if (el.id && KEEP_IDS.has(el.id)) return;
      el.remove();
    });

    // Inserta, en el mismo orden, los hijos del body destino que no sean
    // ni persistentes ni la cabecera duplicada.
    Array.from(nextBody.children).forEach(el => {
      if (el.tagName === 'APRENTIX-HEADER') return;   // ya está viva
      if (KEEP.has(el.tagName)) return;               // scripts/link/style: los ignoramos
      if (el.id && KEEP_IDS.has(el.id)) return;       // ya están vivos
      // Clonamos para no arrastrar referencias al documento parseado.
      body.appendChild(document.importNode(el, true));
    });

    // Marca el modo activo en el <body> para que las CSS específicas de
    // teoría/tests puedan usarlo si les hace falta.
    body.setAttribute('data-active-mode', nextMode);
  }

  /* Actualiza los atributos de <aprentix-header> para que se re-renderice
   * como si estuviéramos en el modo destino. Reemplaza el nodo entero:
   * la clase AprentixHeader monta todo en connectedCallback, así que
   * cambiar atributos + reconectar es la forma más simple de repintar
   * pestañas activas, nav-items y sheets. */
  function refreshHeader(nextDoc) {
    const cur = document.querySelector('aprentix-header');
    const next = nextDoc.querySelector('aprentix-header');
    if (!cur || !next) return;
    const nuevo = document.createElement('aprentix-header');
    for (const { name, value } of Array.from(next.attributes)) {
      nuevo.setAttribute(name, value);
    }
    cur.replaceWith(nuevo);
  }

  /* Ejecución concreta de un cambio de modo. Envuelto en
   * document.startViewTransition cuando el navegador la soporta para
   * que el swap se vea como cross-fade. */
  async function switchTo(nextMode, targetUrl) {
    if (!MODES[nextMode]) return false;
    if (window.__aprentix_switching) return false;
    window.__aprentix_switching = true;

    try {
      // 1) Descarga la HTML destino. Ha sido pre-renderizada por la
      //    Speculation Rules API en Chromium, o al menos prefetch: rapidísima.
      const res = await fetch(targetUrl, { credentials: 'same-origin' });
      if (!res.ok) throw new Error('HTTP ' + res.status);
      const html = await res.text();
      const doc = new DOMParser().parseFromString(html, 'text/html');

      // 2) Desmonta la app actual (si tiene unmount()).
      const curMode = detectMode(location.pathname);
      if (curMode && window[MODES[curMode].global]?.unmount) {
        try { window[MODES[curMode].global].unmount(); } catch (_) {}
      }

      // 2b) Añade los stylesheets del modo destino que aún no estén
      //     cargados. Se hace antes del swap para evitar un flash de
      //     contenido sin estilo (FOUC) durante el cross-fade.
      mergeStylesheets(doc);

      // 3) Swap del DOM y de la cabecera. Envuelto en la view transition.
      const paint = () => {
        refreshHeader(doc);
        swapAppContent(doc, nextMode);
        // Actualiza la URL sin recargar. Preserva la query string (por
        // ejemplo, ?atajo=…) sólo si el destino la traía.
        history.pushState({ mode: nextMode }, '', targetUrl);
        // Scroll al principio: sensación de "página nueva".
        window.scrollTo(0, 0);
      };
      if ('startViewTransition' in document) {
        await document.startViewTransition(paint).finished.catch(() => {});
      } else {
        paint();
      }

      // 4) Carga el script del modo destino si aún no lo tenemos (para
      //    primeras visitas, cuando ambos scripts no vinieron precargados).
      if (!window[MODES[nextMode].global]) {
        await loadScript(MODES[nextMode].script);
      }

      // 5) Monta la app destino.
      const app = window[MODES[nextMode].global];
      if (app && typeof app.mount === 'function') {
        await Promise.resolve(app.mount()).catch(err => {
          console.error('[spa-router] mount error', err);
        });
      }
      return true;
    } catch (err) {
      console.error('[spa-router] switch error', err);
      // Fallback: navegación clásica.
      location.href = targetUrl;
      return false;
    } finally {
      window.__aprentix_switching = false;
    }
  }

  /* Interceptor global de clicks: cualquier <a> que apunte a /tests/
   * o /teoria/ (misma-origen) se convierte en un cambio SPA. Respetamos
   * modificadores del teclado, target y otras señales de navegación
   * externa. */
  document.addEventListener('click', (e) => {
    if (e.defaultPrevented) return;
    if (e.button !== 0) return;
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    const a = e.target.closest('a[href]');
    if (!a) return;
    if (a.target && a.target !== '_self') return;

    // Sólo mismo origen.
    let url;
    try { url = new URL(a.href, location.href); }
    catch { return; }
    if (url.origin !== location.origin) return;

    const nextMode = detectMode(url.pathname);
    const curMode  = detectMode(location.pathname);
    if (!nextMode) return;            // link a otra cosa (landing, etc.)
    if (nextMode === curMode && url.pathname === location.pathname && !url.search) return; // link al mismo sitio

    // Cambio de modo → SPA.
    if (nextMode !== curMode) {
      e.preventDefault();
      switchTo(nextMode, url.pathname + url.search + url.hash);
    }
  }, /* capture */ true);

  /* Botón atrás/adelante: si la nueva URL corresponde al otro modo,
   * hacemos el swap SPA en lugar de dejar que el navegador recargue. */
  window.addEventListener('popstate', () => {
    const nextMode = detectMode(location.pathname);
    const curMode  = document.body.getAttribute('data-active-mode') || detectMode(location.pathname);
    if (nextMode && nextMode !== curMode) {
      switchTo(nextMode, location.pathname + location.search + location.hash);
    }
  });

  // Al montar el router, marca el modo activo en el body para las CSS.
  const initialMode = detectMode(location.pathname);
  if (initialMode) {
    document.body.setAttribute('data-active-mode', initialMode);
  }

  window.APRENTIX_ROUTER = { switchTo, detectMode };
})();
