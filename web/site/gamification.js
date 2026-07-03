/* ============================================================================
 * gamification.js — retos diarios, amigos, racha, notificaciones push.
 *
 * Se acopla a la SPA por window.aprentix (definido al final de app.js):
 *   aprentix.rpc, aprentix.toast, aprentix.navigate,
 *   aprentix.state, aprentix.registerLoader.
 *
 * Registra dos vistas nuevas ('retos' y 'amigos') y engancha:
 *   - Home widget con racha + retos completados
 *   - Service Worker + Web Push (VAPID)
 *   - Deep links desde push notifications (postMessage del SW)
 * ==========================================================================*/
(() => {
"use strict";

const A = window.aprentix;
if (!A) { console.warn("gamification.js: aprentix API no expuesta todavía"); return; }

const $  = (s, p=document) => p.querySelector(s);
const $$ = (s, p=document) => Array.from(p.querySelectorAll(s));

/* ── Estado local ────────────────────────────────────────────────────────── */
const g = {
  retos: [],
  racha: { actual: 0, maxima: 0, puntos: 0 },
  amigos: [],
  solicitudes: { recibidas: [], enviadas: [] },
  vapidKey: null,
  pushSubscribed: null,          // se calcula bajo demanda
  buscarTimer: null,
};

/* ── Utilidades ──────────────────────────────────────────────────────────── */
function b64UrlToUint8Array(b64) {
  const pad = "=".repeat((4 - (b64.length % 4)) % 4);
  const b = (b64 + pad).replace(/-/g, "+").replace(/_/g, "/");
  const raw = atob(b);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

/* ── Registro del Service Worker ─────────────────────────────────────────── */
async function ensureSw() {
  if (!("serviceWorker" in navigator)) return null;
  try {
    const reg = await navigator.serviceWorker.register("/sw.js", { scope: "/" });
    return reg;
  } catch (e) {
    console.warn("SW register error:", e);
    return null;
  }
}

navigator.serviceWorker?.addEventListener("message", (evt) => {
  const d = evt.data || {};
  if (d.type === "aprentix:navigate") {
    // Deep-link desde una notificación clic.
    const u = String(d.url || "/");
    const hash = u.includes("#") ? u.slice(u.indexOf("#") + 1) : "";
    if (hash === "amigos" || hash === "retos" || hash === "repaso") {
      A.navigate(hash === "repaso" ? "tests" : hash);
    }
  } else if (d.type === "aprentix:resubscribe") {
    subscribePush(true).catch(() => {});
  }
});

/* ── Web Push ────────────────────────────────────────────────────────────── */
async function loadVapidKey() {
  if (g.vapidKey) return g.vapidKey;
  const k = await A.rpc("vapid_public_key", {});
  g.vapidKey = typeof k === "string" ? k : (k && k[0]) || null;
  return g.vapidKey;
}

async function currentSubscription() {
  if (!("serviceWorker" in navigator)) return null;
  const reg = await navigator.serviceWorker.ready;
  return reg.pushManager.getSubscription();
}

async function subscribePush(silent = false) {
  if (!("Notification" in window) || !("serviceWorker" in navigator) || !("PushManager" in window)) {
    if (!silent) A.toast("Este navegador no soporta notificaciones push");
    return false;
  }
  const key = await loadVapidKey();
  if (!key) {
    if (!silent) A.toast("Servidor sin clave VAPID configurada");
    return false;
  }
  let perm = Notification.permission;
  if (perm === "default") perm = await Notification.requestPermission();
  if (perm !== "granted") {
    if (!silent) A.toast("No podemos enviarte notificaciones sin permiso");
    return false;
  }
  const reg = await navigator.serviceWorker.ready;
  let sub = await reg.pushManager.getSubscription();
  if (!sub) {
    sub = await reg.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: b64UrlToUint8Array(key),
    });
  }
  const j = sub.toJSON();
  await A.rpc("registrar_suscripcion_push", {
    p_endpoint:   j.endpoint,
    p_p256dh:     j.keys && j.keys.p256dh,
    p_auth:       j.keys && j.keys.auth,
    p_user_agent: navigator.userAgent.slice(0, 200),
  });
  g.pushSubscribed = true;
  actualizarHintPush();
  if (!silent) A.toast("¡Notificaciones activadas!");
  return true;
}

async function unsubscribePush() {
  const sub = await currentSubscription();
  if (!sub) return;
  try {
    await A.rpc("borrar_suscripcion_push", { p_endpoint: sub.endpoint });
  } catch (_) { /* seguimos y desuscribimos igual */ }
  await sub.unsubscribe();
  g.pushSubscribed = false;
  actualizarHintPush();
}

function actualizarHintPush() {
  const hint = $("#retos-push-hint");
  if (!hint) return;
  const puede = "Notification" in window && "serviceWorker" in navigator && "PushManager" in window;
  const perm = puede ? Notification.permission : "denied";
  const enPantallaInicio = window.matchMedia("(display-mode: standalone)").matches
                        || navigator.standalone === true;
  const esIos = /iP(hone|ad|od)/.test(navigator.userAgent);
  // iOS solo permite push si la PWA está instalada en pantalla de inicio.
  const iosNoPwa = esIos && !enPantallaInicio;

  if (iosNoPwa) {
    hint.classList.remove("hidden");
    hint.innerHTML = `
      <strong>📱 Instala Aprentix en tu iPhone</strong>
      <p class="muted small">
        En iOS solo llegan notificaciones si añades la web a la pantalla
        de inicio: pulsa <em>Compartir</em> → <em>Añadir a pantalla de inicio</em>,
        abre la app desde su icono y luego vuelve aquí para activar los
        avisos.
      </p>`;
    return;
  }
  if (!puede || perm === "denied") {
    hint.classList.add("hidden");
    return;
  }
  hint.classList.toggle("hidden", g.pushSubscribed === true);
}

/* ── HOME widget: racha + retos resumen ──────────────────────────────────── */
function pintarHomeWidget() {
  const el = $("#home-gamif");
  if (!el) return;
  if (!g.retos.length) { el.classList.add("hidden"); return; }
  const hechos = g.retos.filter(r => r.completado).length;
  el.classList.remove("hidden");
  el.innerHTML = `
    <div class="gamif-racha">
      <span class="racha-flame" aria-hidden="true">🔥</span>
      <div>
        <strong>${g.racha.actual}</strong>
        <span class="muted small">día${g.racha.actual === 1 ? "" : "s"} de racha · ${g.racha.puntos} pts</span>
      </div>
    </div>
    <div class="gamif-retos-mini">
      <strong>${hechos}/${g.retos.length}</strong>
      <span class="muted small">retos hoy</span>
      <div class="gamif-mini-list">
        ${g.retos.map(r => {
          const pct = Math.round((r.progreso / r.objetivo) * 100);
          return `<div class="mini-reto ${r.completado ? "done" : ""}"
                       title="${A.esc(r.titulo)} · ${r.progreso}/${r.objetivo}">
            <span class="mini-reto-bar" style="width:${pct}%"></span>
          </div>`;
        }).join("")}
      </div>
      <button class="btn btn-ghost btn-sm" data-view="retos">Ver retos</button>
    </div>`;
}

/* ── Vista Retos ─────────────────────────────────────────────────────────── */
function pintarRetos() {
  $("#retos-fecha").textContent =
    new Date().toLocaleDateString("es-ES",
      { weekday:"long", day:"numeric", month:"long" });

  $("#racha-panel").innerHTML = `
    <div class="racha-card">
      <div class="racha-flame-big" aria-hidden="true">🔥</div>
      <div>
        <div class="racha-num">${g.racha.actual}</div>
        <div class="muted small">racha actual</div>
      </div>
      <div>
        <div class="racha-num">${g.racha.maxima}</div>
        <div class="muted small">racha máxima</div>
      </div>
      <div>
        <div class="racha-num">${g.racha.puntos}</div>
        <div class="muted small">puntos totales</div>
      </div>
    </div>`;

  const ul = $("#retos-list");
  ul.innerHTML = g.retos.length ? g.retos.map(r => {
    const pct = Math.min(100, Math.round((r.progreso / r.objetivo) * 100));
    return `
      <li class="reto-card ${r.completado ? "done" : ""}">
        <div class="reto-head">
          <strong>${A.esc(r.titulo)}</strong>
          <span class="reto-puntos">+${r.puntos} pts</span>
        </div>
        <p class="muted small">${A.esc(r.descripcion)}</p>
        <div class="reto-progress"><div class="reto-progress-bar" style="width:${pct}%"></div></div>
        <div class="reto-meta">
          <span class="muted small">${r.progreso} / ${r.objetivo}</span>
          <span class="reto-estado">${r.completado ? "✅ Completado" : "En marcha"}</span>
        </div>
      </li>`;
  }).join("") : "<li class='muted'>Aún no hay retos para hoy.</li>";

  actualizarHintPush();
}

async function loadRetos() {
  const r = await A.rpc("mis_retos_hoy", {});
  g.retos = r.retos || [];
  g.racha = r.racha || g.racha;
  pintarRetos();
  pintarHomeWidget();
  actualizarBadges();
}

/* ── Vista Amigos ────────────────────────────────────────────────────────── */
function pintarAmigos() {
  const ul = $("#amigos-lista");
  ul.innerHTML = g.amigos.length ? g.amigos.map(a => `
    <li class="amigo-card">
      <span class="avatar">${A.esc((a.username || "?").trim()[0]).toUpperCase()}</span>
      <div class="amigo-info">
        <strong>${A.esc(a.username)}</strong>
        <span class="muted small">🔥 ${a.racha_actual}d · ${a.puntos} pts · ${a.retos_hoy_completados} reto${a.retos_hoy_completados === 1 ? "" : "s"} hoy</span>
      </div>
      <button class="btn btn-ghost btn-sm" data-cancelar="${A.esc(a.id)}">Quitar</button>
    </li>`).join("") : "<li class='muted'>Aún no tienes amigos. Busca a alguien por su username arriba.</li>";

  const rec = g.solicitudes.recibidas || [];
  const env = g.solicitudes.enviadas  || [];
  const titSol = $("#amigos-solicitudes-titulo");
  const ulSol = $("#amigos-solicitudes");
  const hayAlgo = rec.length + env.length > 0;
  titSol.classList.toggle("hidden", !hayAlgo);
  ulSol.innerHTML = "";
  rec.forEach(s => {
    const li = document.createElement("li");
    li.className = "amigo-card";
    li.innerHTML = `
      <span class="avatar">${A.esc((s.username||"?").trim()[0]).toUpperCase()}</span>
      <div class="amigo-info">
        <strong>${A.esc(s.username)}</strong>
        <span class="muted small">te ha enviado una solicitud</span>
      </div>
      <button class="btn btn-primary btn-sm" data-aceptar="${A.esc(s.id)}">Aceptar</button>
      <button class="btn btn-ghost   btn-sm" data-rechazar="${A.esc(s.id)}">Rechazar</button>`;
    ulSol.appendChild(li);
  });
  env.forEach(s => {
    const li = document.createElement("li");
    li.className = "amigo-card";
    li.innerHTML = `
      <span class="avatar">${A.esc((s.username||"?").trim()[0]).toUpperCase()}</span>
      <div class="amigo-info">
        <strong>${A.esc(s.username)}</strong>
        <span class="muted small">solicitud enviada · pendiente</span>
      </div>
      <button class="btn btn-ghost btn-sm" data-cancelar-sol="${A.esc(s.id)}">Cancelar</button>`;
    ulSol.appendChild(li);
  });
  actualizarBadges();
}

async function loadAmigos() {
  const [amigos, sol] = await Promise.all([
    A.rpc("mis_amigos", {}),
    A.rpc("mis_solicitudes_amistad", {}),
  ]);
  g.amigos = Array.isArray(amigos) ? amigos : [];
  g.solicitudes = sol || { recibidas: [], enviadas: [] };
  pintarAmigos();
}

/* ── Buscador de usuarios ────────────────────────────────────────────────── */
async function buscarUsuarios(q) {
  const cont = $("#amigos-buscar-resultados");
  if (!q || q.length < 2) { cont.innerHTML = ""; return; }
  const res = await A.rpc("buscar_usuarios", { p_q: q, p_lim: 12 });
  cont.innerHTML = (res || []).map(u => {
    let boton;
    if (u.estado === "aceptada") {
      boton = `<span class="muted small">Ya sois amigos</span>`;
    } else if (u.estado === "pendiente" && u.yo_solicite) {
      boton = `<button class="btn btn-ghost btn-sm" data-cancelar-sol="${A.esc(u.id)}">Cancelar solicitud</button>`;
    } else if (u.estado === "pendiente") {
      boton = `<button class="btn btn-primary btn-sm" data-aceptar="${A.esc(u.id)}">Aceptar</button>`;
    } else {
      boton = `<button class="btn btn-primary btn-sm" data-enviar="${A.esc(u.id)}">Enviar solicitud</button>`;
    }
    return `<div class="amigo-card compact">
      <span class="avatar">${A.esc((u.username||"?").trim()[0]).toUpperCase()}</span>
      <strong>${A.esc(u.username)}</strong>
      <span style="flex:1"></span>
      ${boton}
    </div>`;
  }).join("");
}

/* ── Handlers de amigos (event delegation) ───────────────────────────────── */
document.addEventListener("click", async (e) => {
  const t = e.target;
  try {
    if (t.matches("[data-enviar]")) {
      await A.rpc("enviar_solicitud_amistad", { p_otro: t.dataset.enviar });
      A.toast("Solicitud enviada");
      await loadAmigos();
      buscarUsuarios($("#amigos-buscar").value.trim());
    } else if (t.matches("[data-aceptar]")) {
      await A.rpc("responder_solicitud_amistad",
        { p_otro: t.dataset.aceptar, p_aceptar: true });
      A.toast("Solicitud aceptada");
      await loadAmigos();
    } else if (t.matches("[data-rechazar]")) {
      await A.rpc("responder_solicitud_amistad",
        { p_otro: t.dataset.rechazar, p_aceptar: false });
      await loadAmigos();
    } else if (t.matches("[data-cancelar]") || t.matches("[data-cancelar-sol]")) {
      const id = t.dataset.cancelar || t.dataset.cancelarSol;
      await A.rpc("cancelar_amistad", { p_otro: id });
      await loadAmigos();
      buscarUsuarios($("#amigos-buscar").value.trim());
    }
  } catch (err) {
    A.toast(err.message || String(err));
  }
});

/* ── Badges (solicitudes recibidas + retos completados) ──────────────────── */
function actualizarBadges() {
  const solPend = (g.solicitudes.recibidas || []).length;
  const bAmigos = $("#nav-amigos-badge");
  if (bAmigos) {
    bAmigos.textContent = solPend > 0 ? String(solPend) : "";
    bAmigos.classList.toggle("hidden", solPend === 0);
  }
  const hechos = g.retos.filter(r => r.completado).length;
  const total  = g.retos.length;
  const bRetos = $("#nav-retos-badge");
  if (bRetos && total) {
    bRetos.textContent = `${hechos}/${total}`;
    bRetos.classList.remove("hidden");
  } else if (bRetos) {
    bRetos.classList.add("hidden");
  }
}

/* ── Registro de loaders y arranque ──────────────────────────────────────── */
A.registerLoader("retos",  loadRetos);
A.registerLoader("amigos", loadAmigos);

$("#amigos-buscar")?.addEventListener("input", (e) => {
  clearTimeout(g.buscarTimer);
  const q = e.target.value.trim();
  g.buscarTimer = setTimeout(() => buscarUsuarios(q), 200);
});

$("#btn-activar-push")?.addEventListener("click", async () => {
  try { await subscribePush(false); } catch (e) { A.toast(e.message); }
});

/* Arranque: cuando app.js declara sesión, cargamos retos y registramos SW. */
document.addEventListener("aprentix:session", async (ev) => {
  if (!ev.detail || !ev.detail.loggedIn) return;
  await ensureSw();
  try {
    g.pushSubscribed = !!(await currentSubscription());
    actualizarHintPush();
  } catch (_) {}
  try { await loadRetos(); }   catch (_) {}
  try { await loadAmigos(); }  catch (_) {}

  // Deep-link por hash al arrancar (shortcut de PWA o notificación).
  const h = location.hash.replace("#", "");
  if (h === "amigos" || h === "retos") A.navigate(h);
});

/* Refresca al volver a la pestaña, por si un amigo hizo cosas fuera. */
document.addEventListener("visibilitychange", () => {
  if (document.hidden) return;
  if (A.state.jwt && A.state.user) {
    loadRetos().catch(() => {});
    if ($("#view-amigos")?.classList.contains("active")) loadAmigos().catch(() => {});
  }
});

})();
