/* ============================================================================
 * Aprentix · SPA contra PostgREST.  Sin Flask, sin adaptadores: el JS llama
 * directamente a /api/... (Caddy reenvía a PostgREST) y a /api/rpc/...
 * ========================================================================== */
(() => {
"use strict";

/* ── Sesión compartida (cookie en .aprentix.es) ─────────────────────────── */
const COOKIE_NAME = "aprentix_token";
const COOKIE_HORAS = 12;
// La app vive en aprentix.es/tests/*; para volver a la landing basta con
// navegar a "/" (mismo origen). Mantener una URL absoluta rompe la sensación
// de app unificada y hace que la PWA salga de scope.
const LANDING_URL = "/";

function cookieDomain() {
  // '.aprentix.es' desde cualquier subdominio; vacío en localhost.
  const parts = location.hostname.split(".");
  return parts.length >= 2 ? "." + parts.slice(-2).join(".") : "";
}
function getCookie(name) {
  for (const raw of document.cookie.split(";")) {
    const [k, ...v] = raw.trim().split("=");
    if (k === name) return decodeURIComponent(v.join("="));
  }
  return null;
}
function setCookie(name, value, horas) {
  const dom = cookieDomain();
  const attrs = [
    `Max-Age=${Math.round(horas * 3600)}`,
    "Path=/",
    "SameSite=Lax",
    location.protocol === "https:" ? "Secure" : "",
    dom ? `Domain=${dom}` : "",
  ].filter(Boolean);
  document.cookie = `${name}=${encodeURIComponent(value)}; ${attrs.join("; ")}`;
}
function deleteCookie(name) {
  const dom = cookieDomain();
  document.cookie = `${name}=; Max-Age=0; Path=/; ${dom ? "Domain=" + dom : ""}`;
  document.cookie = `${name}=; Max-Age=0; Path=/`;
}

/* ── Estado global ───────────────────────────────────────────────────────── */
const state = {
  // Legacy: si el JWT quedó en localStorage por una sesión anterior, lo
  // trasladamos a la cookie compartida para que el resto de subdominios
  // (landing, teoria) lo vean.
  jwt:       getCookie(COOKIE_NAME) || localStorage.getItem("jwt") || null,
  user:      JSON.parse(localStorage.getItem("user") || "null"),
  quiz:      null,
  qi:        0,
  testsPage: 1,
  testsCache: [],
  filtroTests: "",
  filtroEtiquetaTests: null,
  filtroVisTests: "todos",          // todos | favoritos | pendientes
  ordenTests: "reciente",            // reciente | antiguo | intentos_desc | intentos_asc
  filtroEtiquetaBuscar: null,          // legado (single-tag), no se usa ya
  filtroEtiquetasBuscar: [],            // multi-tag actual
  etiquetasCache: [],
  // Fase 5: oposición seleccionada actualmente (uuid | null = todas).
  // Se persiste por usuario en localStorage: aprentix.oposicion.<user_id>
  currentOposicion: null,
  currentOposicionNombre: null,
  misOposicionesCache: [],
};

/* ── Helpers DOM ─────────────────────────────────────────────────────────── */
const $  = (s, p=document) => p.querySelector(s);
const $$ = (s, p=document) => Array.from(p.querySelectorAll(s));
const esc = s => String(s ?? "").replace(/[&<>"']/g, c => (
  { "&":"&amp;", "<":"&lt;", ">":"&gt;", "\"":"&quot;", "'":"&#39;" }[c]
));

function toast(msg) {
  const t = $("#toast");
  t.textContent = msg;
  t.classList.remove("hidden");
  clearTimeout(t._t);
  t._t = setTimeout(() => t.classList.add("hidden"), 2800);
}

/* ── Notificaciones de logros (gamificación) ─────────────────────────
 * `logros` viene del backend como array de objetos:
 *   { codigo, titulo, descripcion, icono, xp, objetivo, progreso }
 * Renderizamos una tarjeta apilada por logro con la barra verde que
 * se completa animándose de 0 a 100%.  Cada tarjeta se descarta sola
 * a los ~5s (y se puede tocar para cerrar antes).
 */
function notificarLogros(logros) {
  if (!Array.isArray(logros) || !logros.length) return;
  const stack = $("#logros-notif-stack");
  if (!stack) return;
  logros.forEach((l, i) => {
    const esReto = l.tipo === "reto";
    const titular = esReto ? "¡Reto completado!" : "¡Logro desbloqueado!";
    const card = document.createElement("article");
    card.className = "logro-notif" + (esReto ? " es-reto" : "");
    card.setAttribute("role", "status");
    card.innerHTML = `
      <div class="logro-notif-icono" aria-hidden="true">${esc(l.icono || (esReto ? "🎯" : "🏆"))}</div>
      <div class="logro-notif-body">
        <div class="logro-notif-head">
          <strong>${titular}</strong>
          <span class="logro-notif-xp">+${Number(l.xp) || 0} XP</span>
        </div>
        <div class="logro-notif-desc"><strong>${esc(l.titulo || "")}</strong>${
          l.descripcion ? " · " + esc(l.descripcion) : ""
        }</div>
        <div class="logro-notif-bar" role="progressbar"
             aria-valuenow="${l.progreso || l.objetivo || 1}"
             aria-valuemin="0"
             aria-valuemax="${l.objetivo || 1}"><span></span></div>
      </div>`;
    stack.appendChild(card);
    // Barra: la CSS parte de width:0 y anima hasta 100% cuando añadimos .done.
    // Escalonamos un pelín cada tarjeta para que el efecto encadene.
    setTimeout(() => card.classList.add("done"), 60 + i * 120);
    const cerrar = () => {
      if (card._closed) return;
      card._closed = true;
      card.classList.add("out");
      setTimeout(() => card.remove(), 350);
    };
    card.addEventListener("click", cerrar);
    setTimeout(cerrar, 5000 + i * 400);
  });
}

/* Extrae logros_desbloqueados de una respuesta RPC y los notifica. */
function notificarDesdeRPC(res) {
  const l = res && res.logros_desbloqueados;
  if (Array.isArray(l) && l.length) notificarLogros(l);
}

/* Desglose de XP del test recién terminado: base + volumen + nota + racha.
 * Se pinta como una tarjeta más en el stack, con el icono grande del zorro
 * y el detalle en el cuerpo. Si xp === 0 (intento ya finalizado o test
 * vacío), no molestamos. */
function notificarXpTest(res) {
  if (!res || typeof res !== "object") return;
  const xp = Number(res.xp) || 0;
  if (xp <= 0 || res.ya_finalizado) return;
  const stack = document.getElementById("logros-notif-stack");
  if (!stack) return;
  const partes = [];
  if (res.base)    partes.push(`Base ${res.base}`);
  if (res.volumen) partes.push(`Volumen ${res.volumen}`);
  if (res.nota)    partes.push(`Nota ${res.nota}`);
  if (res.racha)   partes.push(`Racha ${res.racha}`);
  const card = document.createElement("article");
  card.className = "logro-notif";
  card.setAttribute("role", "status");
  card.innerHTML = `
    <div class="logro-notif-icono" aria-hidden="true">🦊</div>
    <div class="logro-notif-body">
      <div class="logro-notif-head">
        <strong>¡Test terminado!</strong>
        <span class="logro-notif-xp">+${xp} XP</span>
      </div>
      <div class="logro-notif-desc">${partes.join(" · ") || "Sigue así"}</div>
      <div class="logro-notif-bar" role="progressbar"
           aria-valuenow="${xp}" aria-valuemin="0" aria-valuemax="${xp}"><span></span></div>
    </div>`;
  stack.appendChild(card);
  setTimeout(() => card.classList.add("done"), 60);
  const cerrar = () => {
    if (card._closed) return;
    card._closed = true;
    card.classList.add("out");
    setTimeout(() => card.remove(), 350);
  };
  card.addEventListener("click", cerrar);
  setTimeout(cerrar, 6000);
}

/* ── Llamada HTTP a PostgREST ────────────────────────────────────────────── */
async function pg(path, opts = {}) {
  const headers = { "Accept": "application/json" };
  if (opts.body !== undefined) headers["Content-Type"] = "application/json";
  if (state.jwt) headers["Authorization"] = "Bearer " + state.jwt;
  if (opts.headers) Object.assign(headers, opts.headers);

  // Ruta relativa: resuelve contra el <base href> (/tests/), así el
  // request va a /tests/api/... y el Caddy de la landing lo desnuda hasta
  // /api/... en el contenedor web, que reenvía a PostgREST.
  const res = await fetch("api" + path, {
    method: opts.method || "GET",
    headers,
    body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
    signal: opts.signal,
  });
  if (!res.ok) {
    let detail = "";
    try { const e = await res.json(); detail = e.message || e.hint || e.details || ""; } catch (_) {}
    if (res.status === 401) {
      logout(false);
      throw new Error(detail || "Sesión caducada");
    }
    throw new Error(detail || `HTTP ${res.status}`);
  }
  if (res.status === 204) return null;
  const ct = res.headers.get("content-type") || "";
  return ct.includes("application/json") ? res.json() : res.text();
}

/* RPC = POST /rpc/<nombre> */
const rpc = (name, args = {}) =>
  pg(`/rpc/${name}`, { method: "POST", body: args });

/* ── Sesión ──────────────────────────────────────────────────────────────── */
function persistSession() {
  // JWT en cookie compartida entre subdominios (.aprentix.es); el resto de
  // metadatos del usuario en localStorage (fáciles de recomputar via
  // mi_sesion() si se pierden).
  if (state.jwt) setCookie(COOKIE_NAME, state.jwt, COOKIE_HORAS);
  else deleteCookie(COOKIE_NAME);
  // Limpia el localStorage legado con el token (ya vive en la cookie).
  localStorage.removeItem("jwt");
  if (state.user) localStorage.setItem("user", JSON.stringify(state.user));
  else localStorage.removeItem("user");
}

function jwtSub(token) {
  try {
    const b64 = token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    const pad = b64.length % 4 ? b64 + "=".repeat(4 - (b64.length % 4)) : b64;
    return JSON.parse(atob(pad)).sub || null;
  } catch (_) { return null; }
}

async function refrescarUsuarioDesdeJwt() {
  // Cuando entramos con cookie válida pero sin user en localStorage (típico
  // tras hacer login en la landing y volver aquí), reconstruimos el user
  // consultando mi_sesion() de PostgREST. También detectamos el caso en el
  // que otro usuario ha iniciado sesión en otro subdominio (landing/teoría):
  // la cookie compartida trae un JWT distinto al user cacheado en el
  // localStorage de este subdominio, así que descartamos el user viejo.
  if (!state.jwt) return;
  const sub = jwtSub(state.jwt);
  if (state.user && sub && String(state.user.user_id) !== String(sub)) {
    state.user = null;
    localStorage.removeItem("user");
  }
  if (state.user) return;
  try {
    const r = await rpc("mi_sesion", {});
    if (r && r.user_id) {
      state.user = {
        user_id: r.user_id,
        username: r.username,
        puede_gestionar: !!r.puede_gestionar,
        roles: r.roles || [],
      };
      persistSession();
    }
  } catch (_) { /* si falla, el flujo de navigate() manda a login */ }
}

function applySession() {
  const logged = !!state.jwt && !!state.user;
  $("#topbar").classList.toggle("hidden", !logged);
  // El bottom-nav lo pinta <aprentix-header>: también empieza oculto
  // (por start-hidden) y hay que revelarlo al confirmar sesión.
  $("#bottom-nav")?.classList.toggle("hidden", !logged);
  $("#sidebar").classList.toggle("hidden", !logged);
  document.body.classList.toggle("puede-gestionar", !!(state.user && state.user.puede_gestionar));
  document.body.classList.toggle("es-admin", !!(state.user && (state.user.roles || []).includes("admin")));
  if (logged) {
    const u = state.user.username || "";
    $("#user-name").textContent = u;
    $("#user-avatar").textContent = (u.trim()[0] || "?").toUpperCase();
    $("#hello-name").textContent = u;
    // Muestra el enlace a Teoría en el header si el usuario tiene el permiso.
    // (chequea roles; el bit real "teoria.acceder" vive en la BBDD, pero los
    // roles del JWT incluyen 'teoria' o 'admin' cuando aplica).
    const roles = state.user.roles || [];
    const puedeTeoria = roles.includes("admin") || roles.includes("teoria");
    const navT = $("#nav-teoria");
    if (navT) navT.hidden = !puedeTeoria;
    // Recuerda que el último modo fue "tests": la landing lo usa para
    // volver aquí directamente en la próxima visita.
    setCookie("aprentix_ultimo_modo", "tests", 365 * 24);
  }
}

async function login(username, password) {
  const r = await rpc("login_web", { p_username: username, p_password: password });
  state.jwt  = r.token;
  state.user = { user_id: r.user_id, username: r.username, puede_gestionar: r.puede_gestionar, roles: r.roles };
  persistSession();
  applySession();
  navigate("home");
}

async function register(form) {
  const r = await rpc("registrar_web", {
    p_username: form.username,
    p_password: form.password,
    p_email:    form.email || null,
    p_chat_id:  null,
  });
  state.jwt  = r.token;
  state.user = { user_id: r.user_id, username: r.username, puede_gestionar: r.puede_gestionar, roles: r.roles };
  persistSession();
  applySession();
  navigate("home");
}

function logout(navigateAway = true) {
  state.jwt = null; state.user = null;
  state.progresoCache = null;
  // Reinicia la oposición seleccionada (nueva sesión, quizás otro usuario).
  state.currentOposicion = null;
  state.currentOposicionNombre = null;
  state.misOposicionesCache = [];
  document.body.classList.remove("has-oposiciones");
  persistSession(); applySession();
  if (navigateAway) {
    // La sesión es global; salir del stack manda a la landing para que la
    // decisión de volver a los tests o ir a teoría la tome allí.
    location.href = LANDING_URL;
    return;
  }
}

/* ── Navegación ──────────────────────────────────────────────────────────── */
function navigate(view) {
  // Si ya estamos en la vista pedida, no vuelvas a lanzar el loader (evita
  // llamadas innecesarias cuando el usuario hace clic sobre la opción activa).
  const yaActiva = $("#view-" + view)?.classList.contains("active");
  $$(".view").forEach(v => v.classList.remove("active"));
  const el = $("#view-" + view);
  if (el) el.classList.add("active");
  $$(".nav-item").forEach(b => b.classList.toggle("active", b.dataset.view === view));
  $("#sidebar").classList.remove("open");
  if (view !== "login" && (!state.jwt || !state.user)) { navigate("login"); return; }
  if (yaActiva) return;
  const loader = loaders[view];
  if (loader) loader().catch(e => toast(e.message));
}

document.addEventListener("click", e => {
  const navBtn = e.target.closest("[data-view]");
  if (navBtn) {
    navigate(navBtn.dataset.view);
    setSidebar(false);
  }
});

$("#btn-logout")?.addEventListener("click", () => logout());

/* ── Sidebar (solo desktop; en móvil manda la bottom-nav) ── */
function setSidebar(open) {
  $("#sidebar")?.classList.toggle("open", open);
  $("#sidebar-backdrop")?.classList.toggle("hidden", !open);
}
// El botón hamburguesa ha desaparecido con el rediseño móvil. Si algún
// atajo antiguo (URL con estado, teclado…) lo dispara, seguirá funcionando
// via optional chaining.
$("#btn-menu")?.addEventListener("click", () => setSidebar(!$("#sidebar")?.classList.contains("open")));
$("#sidebar-backdrop")?.addEventListener("click", () => setSidebar(false));

/* ── Tiempo por pregunta (sincronizado entre vistas vía localStorage) ── */
function getTiempo() {
  return parseInt(localStorage.getItem("tiempoPregunta") || "20", 10);
}
function setTiempo(n) {
  if (!Number.isFinite(n) || n < 3 || n > 3600) return;
  localStorage.setItem("tiempoPregunta", String(n));
  $$(".tiempo-input").forEach(i => { if (Number(i.value) !== n) i.value = n; });
}
function inicializarInputsTiempo() {
  const t = getTiempo();
  $$(".tiempo-input").forEach(i => {
    i.value = t;
    i.addEventListener("change", () => setTiempo(parseInt(i.value, 10)));
    i.addEventListener("input",  () => {
      const v = parseInt(i.value, 10);
      if (Number.isFinite(v)) setTiempo(v);
    });
  });
}

/* ── Login / registro ────────────────────────────────────────────────────── */
$$(".tab").forEach(tab => tab.addEventListener("click", () => {
  $$(".tab").forEach(t => t.classList.toggle("active", t === tab));
  $$(".tabpanel").forEach(p => p.classList.toggle("active",
    p.id === ("form-" + tab.dataset.tab)));
}));

$("#form-login").addEventListener("submit", async e => {
  e.preventDefault();
  try { await login($("#login-user").value.trim(), $("#login-pass").value); }
  catch (err) { toast(err.message); }
});

$("#form-register").addEventListener("submit", async e => {
  e.preventDefault();
  const p1 = $("#reg-pass").value, p2 = $("#reg-pass2").value;
  if (p1 !== p2) return toast("Las contraseñas no coinciden");
  try {
    await register({
      username: $("#reg-user").value.trim(),
      password: p1,
      email:    $("#reg-email").value.trim(),
    });
  } catch (err) { toast(err.message); }
});

/* ─────────────────────────────────────────────────────────────────────────
 * VIEWS
 * ──────────────────────────────────────────────────────────────────────── */

const loaders = {
  home:        loadHome,
  tests:       loadTests,
  fallos:      loadFallos,
  favoritas:   loadFavoritas,
  buscar:      () => runBuscarView($("#buscar-input").value.trim()),
  upload:      async () => {},
  etiquetas:   loadEtiquetas,
  usuarios:    loadUsuarios,
  retos:       loadRetos,
};

/* ── Home ── */
async function loadHome() {
  // Cargamos progreso + gamificación + el próximo reto sin completar en
  // paralelo: son RPCs independientes y hacen la vista sensiblemente más
  // rápida al arrancar la app.
  const [p, g, retos] = await Promise.all([
    rpc("mi_progreso"),
    rpc("mi_gamificacion").catch(() => null),
    rpc("mis_retos_activos").catch(() => []),
  ]);

  renderGamifCard("#home-gamif", g, null);

  $("#stats-grid").innerHTML = `
    <div class="stat-card"><div class="v">${p.respondidas_hoy}</div><div class="l">Hoy</div></div>
    <div class="stat-card"><div class="v">${Number(p.nota_general).toFixed(1)}</div><div class="l">Nota</div></div>
    <div class="stat-card"><div class="v">${p.preguntas_falladas}</div><div class="l">Fallos</div></div>
    <div class="stat-card"><div class="v">${p.preguntas_favoritas}</div><div class="l">Favoritas</div></div>
  `;
}

/* Escoge un reto para mostrar en Home: preferimos uno diario en progreso;
 * si no, cualquiera diario aún no completado; si todos completos, el más
 * cercano a completar de semanal/mensual. */
function pickHomeReto(retos) {
  if (!Array.isArray(retos) || retos.length === 0) return null;
  const activos = retos.filter(r => !r.completado);
  if (activos.length === 0) return null;
  const enProgreso = activos.filter(r => r.progreso > 0);
  const pool = enProgreso.length ? enProgreso : activos;
  // Ordena: diarios primero, después por % de progreso descendente.
  pool.sort((a, b) => {
    const pa = a.progreso / a.objetivo, pb = b.progreso / b.objetivo;
    const rank = p => p === "diario" ? 0 : p === "semanal" ? 1 : 2;
    return rank(a.periodo) - rank(b.periodo) || pb - pa;
  });
  return pool[0];
}

function renderGamifCard(sel, g, retoDestacado) {
  const box = $(sel);
  if (!box) return;
  if (!g) { box.innerHTML = ""; return; }
  const rango = Math.max(1, (g.xp_siguiente || 0) - (g.xp_nivel_actual || 0));
  const pctNivel = Math.min(100, Math.round(
    100 * ((g.xp_total - g.xp_nivel_actual) / rango)
  ));
  const rachaTxt = g.racha_actual > 0
    ? `🔥 <strong>${g.racha_actual}</strong> día${g.racha_actual === 1 ? "" : "s"} seguido${g.racha_actual === 1 ? "" : "s"}`
    : `😴 Sin racha — hoy es un buen día para empezar`;

  const retoHtml = retoDestacado ? `
    <div class="gamif-reto">
      <span class="gamif-reto-icono" aria-hidden="true">${esc(retoDestacado.icono || "🎯")}</span>
      <div class="gamif-reto-body">
        <strong>${esc(retoDestacado.titulo)}</strong>
        <div class="progress-bar" role="progressbar"
             aria-valuenow="${retoDestacado.progreso}"
             aria-valuemin="0" aria-valuemax="${retoDestacado.objetivo}">
          <span style="width:${Math.round(100 * retoDestacado.progreso / retoDestacado.objetivo)}%"></span>
        </div>
        <span class="muted small">${retoDestacado.progreso} / ${retoDestacado.objetivo} · +${retoDestacado.xp} XP</span>
      </div>
    </div>` : "";

  box.innerHTML = `
    <div class="gamif-head">
      <div class="gamif-level">
        <span class="gamif-nivel-num" title="Nivel">${g.nivel}</span>
        <div>
          <strong>Nivel ${g.nivel}</strong>
          <span class="muted small">${g.xp_total} / ${g.xp_siguiente} XP</span>
        </div>
      </div>
      <div class="gamif-racha">${rachaTxt}</div>
    </div>
    <div class="progress-bar level" role="progressbar"
         aria-valuenow="${pctNivel}" aria-valuemin="0" aria-valuemax="100">
      <span style="width:${pctNivel}%"></span>
    </div>
    ${retoHtml}
  `;
}

/* ── Retos y logros ─────────────────────────────────────────────────────── */
async function loadRetos() {
  const [g, retos, logros] = await Promise.all([
    rpc("mi_gamificacion").catch(() => null),
    rpc("mis_retos_activos"),
    rpc("mis_logros"),
  ]);
  state.retosCache  = retos  || [];
  state.logrosCache = logros || [];
  renderGamifCard("#retos-gamif", g, pickHomeReto(retos));
  activarPestanaRetos(state.retosTab || "diario");
}

function activarPestanaRetos(tab) {
  state.retosTab = tab;
  $$(".retos-tab").forEach(b =>
    b.classList.toggle("active", b.dataset.retosTab === tab));
  const list   = $("#retos-list");
  const logros = $("#logros-list");
  if (tab === "logros") {
    list.classList.add("hidden");
    logros.classList.remove("hidden");
    logros.innerHTML = (state.logrosCache || []).map(l => `
      <article class="logro-card ${l.obtenido ? "obtenido" : ""}">
        <div class="logro-icono">${esc(l.icono || "🏆")}</div>
        <div class="logro-body">
          <strong>${esc(l.titulo)}</strong>
          <p class="muted small">${esc(l.descripcion)}</p>
          <div class="progress-bar" role="progressbar"
               aria-valuenow="${l.progreso}" aria-valuemin="0" aria-valuemax="${l.objetivo}">
            <span style="width:${Math.min(100, Math.round(100 * l.progreso / l.objetivo))}%"></span>
          </div>
          <span class="muted small">
            ${l.progreso} / ${l.objetivo} · +${l.xp} XP
            ${l.obtenido ? "· ✅ desbloqueado" : ""}
          </span>
        </div>
      </article>
    `).join("") || "<p class='muted'>Aún no hay logros configurados.</p>";
    return;
  }
  logros.classList.add("hidden");
  list.classList.remove("hidden");
  const rs = (state.retosCache || []).filter(r => r.periodo === tab);
  list.innerHTML = rs.map(r => {
    const pct = Math.min(100, Math.round(100 * r.progreso / r.objetivo));
    return `
      <article class="reto-card ${r.completado ? "completado" : ""}">
        <div class="reto-icono">${esc(r.icono || "🎯")}</div>
        <div class="reto-body">
          <strong>${esc(r.titulo)}</strong>
          <p class="muted small">${esc(r.descripcion)}</p>
          <div class="progress-bar" role="progressbar"
               aria-valuenow="${r.progreso}" aria-valuemin="0" aria-valuemax="${r.objetivo}">
            <span style="width:${pct}%"></span>
          </div>
          <span class="muted small">
            ${r.progreso} / ${r.objetivo} · +${r.xp} XP
            ${r.completado ? "· ✅ hecho" : ""}
          </span>
        </div>
      </article>
    `;
  }).join("") || "<p class='muted'>No hay retos en este periodo.</p>";
}

document.addEventListener("click", e => {
  const t = e.target.closest(".retos-tab");
  if (t) activarPestanaRetos(t.dataset.retosTab);
});

/* ── Tests ── */
async function loadTests() {
  $("#tests-list").innerHTML = "<p class='muted'>Cargando…</p>";
  // ensureEtiquetasCache alimenta el editor/quiz con TODAS las etiquetas.
  await ensureEtiquetasCache();
  // Para el filtro del listado, sólo mostramos las etiquetas presentes
  // en tests de la oposición seleccionada. Así si el usuario no tiene
  // ningún test con "java" en su oposición, tampoco puede filtrar por
  // "java". Con oposición = null (Todas) se muestran todas.
  const etsTests = await rpc("listar_etiquetas", {
    p_oposicion_id: state.currentOposicion || null,
  });
  const etsList = Array.isArray(etsTests) ? etsTests : [];
  if (state.filtroEtiquetaTests && !etsList.some(e => e.nombre === state.filtroEtiquetaTests)) {
    state.filtroEtiquetaTests = null;
  }
  renderTagChips("#tests-tag-chips", state.filtroEtiquetaTests, et => {
    state.filtroEtiquetaTests = et;
    state.testsPage = 1;
    loadTests();
  }, etsList);
  const r = await rpc("listar_tests", {
    p_solo_favoritos:  state.filtroVisTests === "favoritos",
    p_solo_pendientes: state.filtroVisTests === "pendientes",
    p_page:            state.testsPage,
    p_size:            12,
    p_etiqueta:        state.filtroEtiquetaTests || null,
    p_orden:           state.ordenTests,
    p_oposicion_id:    state.currentOposicion || null,
  });
  state.testsCache = r.tests;
  renderTests();
  renderPagination(r);
}

function renderTests() {
  const f = state.filtroTests.toLowerCase();
  const lista = state.testsCache.filter(t => !f || t.title.toLowerCase().includes(f));
  $("#tests-list").innerHTML = lista.map(t => `
    <div class="test-row" data-id="${t.id}">
      <span class="star" data-fav="${t.id}">${t.favorito ? "⭐" : "☆"}</span>
      <span class="titulo">
        ${t.tiene_pendiente ? '<span title="Tienes este test a medias">⏳</span> ' : ""}
        ${esc(t.title)}
      </span>
      <span class="tags">${(t.etiquetas||[]).map(e => `<span class="tag">${esc(e)}</span>`).join("")}</span>
      <span class="meta">${t.num_preguntas} preg. · ${t.num_intentos || 0} intentos</span>
      <button class="stats-btn" data-stats="${t.id}" data-titulo="${esc(t.title)}" aria-label="Ver estadísticas" title="Ver estadísticas de este test">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="4" y1="20" x2="20" y2="20"/><rect x="6" y="10" width="3" height="10"/><rect x="11" y="6" width="3" height="14"/><rect x="16" y="13" width="3" height="7"/></svg>
      </button>
    </div>
  `).join("") || "<p class='muted'>Sin tests con estos filtros.</p>";
}

/* ── Estadísticas por test (modal) ──────────────────────────────────
 * Reutiliza mi_progreso_detallado (ya devuelve intentos por test) y
 * cachea el resultado para que abrir varios tests seguidos no repita
 * la llamada. Se invalida en logout y al terminar un quiz. */
async function abrirStatsTest(testId, titulo) {
  const modal = $("#modal-stats-test");
  const cont  = $("#modal-stats-test-body");
  const tit   = $("#modal-stats-test-titulo");
  if (!modal || !cont || !tit) return;
  tit.textContent = titulo || "Estadísticas";
  cont.innerHTML = "<p class='muted'>Cargando…</p>";
  modal.classList.remove("hidden");
  try {
    if (!state.progresoCache) {
      state.progresoCache = await rpc("mi_progreso_detallado");
    }
    const p = state.progresoCache;
    const entry = (p.por_test || []).find(x => String(x.quiz_id) === String(testId));
    const intentos = (entry && entry.intentos) || [];
    if (!intentos.length) {
      cont.innerHTML = `
        <p class="muted">Todavía no has terminado ningún intento de este test.</p>
        <p class="muted small">Empieza el test y sus estadísticas aparecerán aquí.</p>`;
      return;
    }
    const notas = intentos.map(i => Number(i.nota) || 0);
    const suma = notas.reduce((a, b) => a + b, 0);
    const media = suma / notas.length;
    const mejor = Math.max(...notas);
    const ult   = notas[notas.length - 1];
    const cell = (v, l, tone = "") => `
      <div class="stat-tile ${tone}">
        <div class="stat-tile-v">${v}</div>
        <div class="stat-tile-l">${l}</div>
      </div>`;
    // Mini "sparkline" de barras con las últimas 12 notas.
    const ultimos = notas.slice(-12);
    const barras = ultimos.map(n => {
      const alto = Math.round((Math.max(0, Math.min(10, n)) / 10) * 100);
      return `<span class="bar" style="height:${alto}%" title="${n.toFixed(2)}"></span>`;
    }).join("");
    cont.innerHTML = `
      <div class="stat-grid">
        ${cell(intentos.length, "Veces intentado")}
        ${cell(media.toFixed(2), "Nota media", media >= 5 ? "ok" : "warn")}
        ${cell(ult.toFixed(2), "Última nota", ult >= 5 ? "ok" : "warn")}
        ${cell(mejor.toFixed(2), "Mejor nota", "hi")}
      </div>
      <h4 class="stats-sub">Últimos intentos</h4>
      <div class="stats-spark" aria-label="Notas de los últimos intentos">${barras}</div>
      <p class="muted small stats-hint">Cada barra es un intento. Escala 0 – 10.</p>
    `;
  } catch (e) {
    cont.innerHTML = `<p class='muted'>No se pudieron cargar las estadísticas: ${esc(e.message)}</p>`;
  }
}
function cerrarStatsTest() {
  $("#modal-stats-test")?.classList.add("hidden");
}
$("#tests-list")?.addEventListener("click", (e) => {
  const btn = e.target.closest(".stats-btn");
  if (!btn) return;
  e.stopPropagation();  // que no dispare la navegación al detalle
  abrirStatsTest(btn.dataset.stats, btn.dataset.titulo);
});
// La X y el cierre por Esc/click-backdrop los gestiona <ap-modal closable>.

/* Listeners de los nuevos controles */
$("#tests-vis-chips").addEventListener("click", e => {
  const chip = e.target.closest(".chip");
  if (!chip) return;
  state.filtroVisTests = chip.dataset.vis;
  $$("#tests-vis-chips .chip").forEach(c => c.classList.toggle("active", c === chip));
  state.testsPage = 1;
  loadTests();
});

$("#tests-orden").addEventListener("change", e => {
  state.ordenTests = e.target.value;
  state.testsPage = 1;
  loadTests();
});

/* ── Cache de etiquetas y render de chips ── */
async function ensureEtiquetasCache(force = false) {
  if (!force && state.etiquetasCache.length) return;
  state.etiquetasCache = await rpc("listar_etiquetas");
}

function renderTagChips(selector, valorActual, onClick, lista) {
  const wrap = $(selector);
  if (!wrap) return;
  const src = Array.isArray(lista) ? lista : state.etiquetasCache;
  const opciones = [{ nombre: "Todas", _all: true }, ...src];
  wrap.innerHTML = opciones.map(e => {
    const isActive = e._all ? !valorActual : (valorActual === e.nombre);
    return `<span class="chip ${isActive ? "active" : ""}" data-tag="${e._all ? "" : esc(e.nombre)}">${esc(e.nombre)}</span>`;
  }).join("");
  wrap.onclick = ev => {
    const c = ev.target.closest(".chip");
    if (!c) return;
    onClick(c.dataset.tag || null);
  };
}

/* Chips multi-selección: el chip "Todas" limpia la selección; el resto
 * alternan en/fuera del array. onChange recibe el nuevo array. */
function renderTagChipsMulti(selector, valoresActuales, onChange) {
  const wrap = $(selector);
  if (!wrap) return;
  const sel = new Set(valoresActuales || []);
  const opciones = [{ nombre: "Todas", _all: true }, ...state.etiquetasCache];
  wrap.innerHTML = opciones.map(e => {
    const isActive = e._all ? sel.size === 0 : sel.has(e.nombre);
    return `<span class="chip ${isActive ? "active" : ""}" data-tag="${e._all ? "" : esc(e.nombre)}">${esc(e.nombre)}</span>`;
  }).join("");
  wrap.onclick = ev => {
    const c = ev.target.closest(".chip");
    if (!c) return;
    const t = c.dataset.tag;
    if (!t) { onChange([]); return; }
    if (sel.has(t)) sel.delete(t); else sel.add(t);
    onChange(Array.from(sel));
  };
}

function renderPagination(r) {
  let html = "";
  for (let i = 1; i <= r.total_pages; i++) {
    html += `<button class="page ${i===r.page?'active':''}" data-page="${i}">${i}</button>`;
  }
  $("#tests-pagination").innerHTML = html;
}

$("#tests-filter").addEventListener("input", e => {
  state.filtroTests = e.target.value;
  renderTests();
});

$("#tests-pagination").addEventListener("click", e => {
  const b = e.target.closest(".page");
  if (!b) return;
  state.testsPage = parseInt(b.dataset.page, 10);
  loadTests();
});

$("#tests-list").addEventListener("click", e => {
  // El botón de estadísticas está dentro de .test-row; NO debe abrir el
  // detalle del test — se maneja en su propio listener, aquí bailamos.
  if (e.target.closest(".stats-btn")) return;
  const star = e.target.closest("[data-fav]");
  if (star) {
    rpc("toggle_favorita_test", { p_test_id: star.dataset.fav })
      .then(() => loadTests())
      .catch(err => toast(err.message));
    return;
  }
  const row = e.target.closest(".test-row");
  if (row) loadTestDetail(row.dataset.id);
});

/* ── Detalle de un test ── */
async function loadTestDetail(testId) {
  navigate("test-detail");
  $("#test-detail-questions").innerHTML = "<p class='muted'>Cargando…</p>";
  const [d, tRow] = await Promise.all([
    rpc("obtener_preguntas_test", { p_test_id: testId }),
    pg(`/tests?id=eq.${testId}&select=etiquetas,etiquetas_bloqueadas`)
      .then(r => r[0] || {})
      .catch(() => ({})),   // columnas nuevas: si aún no está migrada la BBDD, no rompas
  ]);
  state.currentTestId = testId;
  state.currentTestTags = Array.isArray(tRow.etiquetas) ? [...tRow.etiquetas] : [];
  state.currentTestBloq = Array.isArray(tRow.etiquetas_bloqueadas) ? [...tRow.etiquetas_bloqueadas] : [];
  $("#test-detail-title").textContent = d.quiz.title;
  $("#test-detail-meta").textContent = `${d.questions.length} preguntas`;
  await ensureEtiquetasCache();
  $("#td-tag-datalist").innerHTML = state.etiquetasCache
    .map(t => `<option value="${esc(t.nombre)}">`).join("");
  pintarEtiquetasTest();
  $("#test-detail-questions").innerHTML = d.questions.map(q => `
    <li class="q-row" data-pid="${q.id}">
      <div class="q-text">${esc(q.text)}</div>
      <div class="tags">${(q.etiquetas||[]).map(t => `<span class="tag">${esc(t)}</span>`).join("")}</div>
      <div class="q-actions gestion">
        <button class="btn btn-ghost btn-sm" data-action="edit-q">✏️ Editar</button>
      </div>
    </li>
  `).join("");
  state.currentTest = d;
}

function pintarEtiquetasTest() {
  const tags = state.currentTestTags || [];
  const chipsDiv = $("#td-tags-chips");
  if (!chipsDiv) return;
  if (!tags.length) {
    chipsDiv.innerHTML = `<span class="muted small">— sin etiquetas —</span>`;
  } else {
    chipsDiv.innerHTML = tags.map(t => `
      <span class="tag removable" data-tag="${esc(t)}">
        ${esc(t)}<span class="x" data-rm="${esc(t)}" title="Quitar">×</span>
      </span>
    `).join("");
  }
  pintarSugerenciasTest();
}

// Sugerencias: etiquetas que llevan las PREGUNTAS del test pero que aún no
// están asignadas al test. Con un clic se promocionan al nivel test.
function pintarSugerenciasTest() {
  const box = $("#td-tags-sugeridas");
  if (!box) return;
  const enTest = new Set(state.currentTestTags || []);
  const bloqueadas = new Set(state.currentTestBloq || []);
  const acumulado = new Map();          // nombre -> nº preguntas
  for (const q of (state.currentTest?.questions || [])) {
    for (const t of (q.etiquetas || [])) {
      if (enTest.has(t) || bloqueadas.has(t)) continue;
      acumulado.set(t, (acumulado.get(t) || 0) + 1);
    }
  }
  const sug = [...acumulado.entries()]
    .sort((a,b) => b[1] - a[1]);
  if (!sug.length) { box.innerHTML = ""; return; }
  box.innerHTML = `
    <span class="muted small">Sugeridas de las preguntas:</span>
    ${sug.map(([t,n]) => `
      <span class="tag chip" data-add="${esc(t)}" title="Añadir al test (aparece en ${n} pregunta${n===1?"":"s"})">
        + ${esc(t)} <span class="muted small">·${n}</span>
      </span>
    `).join("")}
  `;
}

async function guardarEtiquetasTest() {
  if (!state.currentTestId) return;
  try {
    await rpc("set_etiquetas_test", {
      p_test_id:   state.currentTestId,
      p_etiquetas: state.currentTestTags || [],
    });
  } catch (e) { toast(e.message); }
}

$("#test-detail-questions").addEventListener("click", e => {
  const btn = e.target.closest("[data-action=edit-q]");
  if (!btn) return;
  const li = e.target.closest("[data-pid]");
  const q = state.currentTest.questions.find(x => x.id === li.dataset.pid);
  if (q) abrirEditorPregunta(q);
});

/* ── Etiquetas del test (admin/editor/autor) ── */
$("#td-tags-chips")?.addEventListener("click", async e => {
  const rm = e.target.closest("[data-rm]");
  if (!rm) return;
  state.currentTestTags = (state.currentTestTags || []).filter(t => t !== rm.dataset.rm);
  pintarEtiquetasTest();
  await guardarEtiquetasTest();
});

$("#td-tags-sugeridas")?.addEventListener("click", async e => {
  const add = e.target.closest("[data-add]");
  if (!add) return;
  const t = add.dataset.add;
  if ((state.currentTestTags || []).includes(t)) return;
  state.currentTestTags = [...(state.currentTestTags || []), t];
  pintarEtiquetasTest();
  await guardarEtiquetasTest();
});

$("#td-tag-add")?.addEventListener("keydown", async e => {
  if (e.key !== "Enter") return;
  e.preventDefault();
  const inp = e.target;
  const tag = inp.value.trim().toLowerCase();
  if (!tag) return;
  if ((state.currentTestTags || []).includes(tag)) {
    toast("El test ya tiene esa etiqueta");
    inp.value = "";
    return;
  }
  if (!state.etiquetasCache.some(t => t.nombre === tag)) {
    if (!confirm(`"${tag}" no existe en el catálogo. ¿Añadirla igualmente?`)) return;
  }
  state.currentTestTags = [...(state.currentTestTags || []), tag];
  inp.value = "";
  pintarEtiquetasTest();
  await guardarEtiquetasTest();
});

/* ── Editor de pregunta (modal) ──
   Acepta tanto la forma del frontend ({text, options:[{text,isCorrect}], ...})
   como la forma cruda de Postgres ({enunciado, opciones:[{texto,correcta}]}).
   Guarda en state.editingQ el id y un callback opcional para "refrescar
   en sitio" después de guardar.
*/
async function abrirEditorPregunta(q, opciones = {}) {
  const text   = q.text   ?? q.enunciado ?? "";
  const optsIn = q.options ?? (q.opciones || []).map(o => ({ text: o.texto, isCorrect: !!o.correcta }));
  const expl   = q.explicacion ?? "";
  const tags   = q.etiquetas ?? [];

  state.editingQ = {
    id: q.id,
    refrescar: opciones.refrescar || null,
    etiquetas: [...tags],
  };
  $("#pq-enunciado").value = text;
  $("#pq-opciones").value  = optsIn
    .map(o => (o.isCorrect ? "*" : "") + o.text)
    .join("\n");
  $("#pq-explicacion").value = expl || "";
  $("#pq-tag-add").value = "";

  // Pinta los chips de etiquetas y rellena el datalist con el catálogo.
  await ensureEtiquetasCache();
  $("#pq-tag-datalist").innerHTML = state.etiquetasCache
    .map(t => `<option value="${esc(t.nombre)}">`).join("");
  pintarModalTagChips();

  $("#modal-pregunta").classList.remove("hidden");
}

function pintarModalTagChips() {
  if (!state.editingQ) return;
  const tags = state.editingQ.etiquetas || [];
  const chipsDiv = $("#pq-tags-chips");
  if (!tags.length) {
    chipsDiv.innerHTML = `<span class="muted small">— sin etiquetas —</span>`;
  } else {
    chipsDiv.innerHTML = tags.map(t => `
      <span class="tag removable" data-tag="${esc(t)}">
        ${esc(t)}<span class="x" data-rm="${esc(t)}" title="Quitar">×</span>
      </span>
    `).join("");
  }
}

$("#pq-tags-chips").addEventListener("click", e => {
  const rm = e.target.closest("[data-rm]");
  if (!rm || !state.editingQ) return;
  state.editingQ.etiquetas = (state.editingQ.etiquetas || [])
    .filter(t => t !== rm.dataset.rm);
  pintarModalTagChips();
});

$("#pq-tag-add").addEventListener("keydown", e => {
  if (e.key !== "Enter") return;
  e.preventDefault();
  if (!state.editingQ) return;
  const inp = e.target;
  const tag = inp.value.trim().toLowerCase();
  if (!tag) return;
  if ((state.editingQ.etiquetas || []).includes(tag)) {
    toast("Ya tiene esa etiqueta");
    inp.value = "";
    return;
  }
  if (!state.etiquetasCache.some(t => t.nombre === tag)) {
    if (!confirm(`"${tag}" no existe en el catálogo. ¿Añadirla igualmente?`)) return;
  }
  state.editingQ.etiquetas = [...(state.editingQ.etiquetas || []), tag];
  inp.value = "";
  pintarModalTagChips();
});

/* Fetch + abrir editor por id (para el buscador y demás listas) */
async function editarPorId(id, refrescar = null) {
  try {
    const r = await pg(`/preguntas?id=eq.${id}&select=id,enunciado,opciones,explicacion,etiquetas`);
    if (r.length) abrirEditorPregunta(r[0], { refrescar });
    else toast("Pregunta no encontrada");
  } catch (e) { toast(e.message); }
}

function cerrarModal() {
  $("#modal-pregunta").classList.add("hidden");
  state.editingQ = null;
}

// La X del modal-pregunta la pinta y gestiona <ap-modal closable>.
$("#pq-cancelar").addEventListener("click", cerrarModal);
// Si el usuario cierra por Esc, X o backdrop en vez de por "Cancelar",
// también hay que resetear el estado de edición.
$("#modal-pregunta").addEventListener("ap-close", () => { state.editingQ = null; });

$("#form-pregunta").addEventListener("submit", async e => {
  e.preventDefault();
  if (!state.editingQ) return;
  // Parsea las opciones: cada línea es una opción; "*" al principio = correcta.
  const opciones = $("#pq-opciones").value.split("\n")
    .map(l => l.trim()).filter(l => l.length)
    .map(l => l.startsWith("*")
      ? { texto: l.slice(1).trim(), correcta: true }
      : { texto: l, correcta: false });
  if (opciones.length < 2) return toast("Necesitas al menos 2 opciones");
  if (!opciones.some(o => o.correcta)) return toast("Marca al menos una opción como correcta con *");

  const etiquetas = state.editingQ.etiquetas || [];

  try {
    // Enunciado/opciones/explicación se guardan por PATCH normal, pero
    // las etiquetas van por RPC dedicada que calcula el diff y actualiza
    // 'etiquetas_manuales' / 'etiquetas_bloqueadas' (la corrección humana
    // debe pesar más que el auto-tagger).
    await pg("/preguntas?id=eq." + state.editingQ.id, {
      method: "PATCH",
      headers: { "Prefer": "return=minimal" },
      body: {
        enunciado:   $("#pq-enunciado").value.trim(),
        opciones,
        explicacion: $("#pq-explicacion").value.trim() || null,
      },
    });
    await rpc("set_etiquetas_pregunta", {
      p_id:        state.editingQ.id,
      p_etiquetas: etiquetas,
    });
    toast("Pregunta actualizada");
    const cb = state.editingQ.refrescar;
    cerrarModal();
    if (cb) cb();
    else if (state.currentTestId) loadTestDetail(state.currentTestId);
  } catch (err) { toast(err.message); }
});

$("#pq-borrar").addEventListener("click", async () => {
  if (!state.editingQ) return;
  if (!confirm("¿Borrar esta pregunta? Desaparecerá de TODOS los tests donde aparezca.")) return;
  try {
    await pg("/preguntas?id=eq." + state.editingQ.id, { method: "DELETE" });
    toast("Pregunta borrada");
    const cb = state.editingQ.refrescar;
    cerrarModal();
    if (cb) cb();
    else if (state.currentTestId) loadTestDetail(state.currentTestId);
  } catch (err) { toast(err.message); }
});

/* ── Editar desde el quiz (botón visible tras responder) ── */
$("#btn-edit-q").addEventListener("click", () => {
  if (!state.quiz) return;
  const q = state.quiz.questions[state.qi];
  editarPorId(q.id, async () => {
    // Refresca la pregunta en memoria (texto, opciones, explicación)
    const r = await pg(`/preguntas?id=eq.${q.id}&select=id,enunciado,opciones,explicacion,etiquetas`);
    if (r.length) {
      const p = r[0];
      q.text = p.enunciado;
      q.explicacion = p.explicacion;
      q.etiquetas = p.etiquetas || [];
      q.options = (p.opciones || []).map(o => ({ text: o.texto, isCorrect: !!o.correcta }));
      $("#quiz-question").textContent = q.text;
      if (q.explicacion) {
        const e = $("#quiz-explanation");
        e.textContent = q.explicacion;
        e.classList.remove("hidden");
      }
    }
  });
});

$("#btn-start-test").addEventListener("click", async () => {
  if (!state.currentTest) return;
  await iniciarConPosibleReanudacion({
    tipo: "quiz",
    testId: state.currentTestId,
    title: state.currentTest.quiz.title,
    questions: state.currentTest.questions,
  });
});

/* ── Diálogo de reanudación ──
   Si hay un intento abierto del mismo (tipo, test), pregunta al usuario.
   - Reanudar: carga las preguntas pendientes con sus acumulados.
   - Empezar de nuevo: descarta el intento anterior y arranca limpio.
   - Cancelar: no hace nada.
*/
async function iniciarConPosibleReanudacion({ tipo, testId, title, questions, opts }) {
  try {
    const r = await rpc("intento_pendiente", { p_tipo: tipo, p_test_id: testId || null });
    const a = r && r.attempt;
    if (a && a.pendientes > 0) {
      const eleccion = await mostrarDialogoReanudar(a);
      if (eleccion === "cancelar") return;
      if (eleccion === "reanudar") {
        const d = await rpc("reanudar_intento", { p_intento_id: a.id });
        if (!d.questions || d.questions.length === 0) {
          toast("Ese intento ya no tiene preguntas pendientes");
          return;
        }
        iniciarQuizDesdeReanudacion(d);
        return;
      }
      if (eleccion === "reiniciar") {
        await rpc("descartar_intento", { p_intento_id: a.id });
        // continúa abajo a un quiz limpio
      }
    }
    startQuiz(title, testId, questions, tipo, opts || {});
  } catch (e) { toast(e.message); }
}

function mostrarDialogoReanudar(att) {
  const partes = [];
  partes.push(`Tienes ${att.respondidas} respondida(s) y ${att.pendientes} pendiente(s).`);
  if (att.invalidas > 0) {
    partes.push(`${att.invalidas} pregunta(s) editada(s) se repetirán.`);
  }
  $("#reanudar-resumen").textContent = partes.join(" ");
  $("#modal-reanudar").classList.remove("hidden");
  return new Promise(resolve => {
    const cleanup = () => {
      $("#modal-reanudar").classList.add("hidden");
      $("#btn-reanudar").onclick = null;
      $("#btn-reiniciar").onclick = null;
      $("#btn-cancelar-reanudar").onclick = null;
    };
    $("#btn-reanudar").onclick      = () => { cleanup(); resolve("reanudar"); };
    $("#btn-reiniciar").onclick     = () => { cleanup(); resolve("reiniciar"); };
    $("#btn-cancelar-reanudar").onclick = () => { cleanup(); resolve("cancelar"); };
  });
}

function iniciarQuizDesdeReanudacion(d) {
  cancelarTimerQuiz();
  // Baraja las opciones (no las preguntas: vienen ya en orden original)
  const shuffled = d.questions.map(q => {
    const opts = q.options.map((o, i) => ({ ...o, origIdx: i }));
    opts.sort(() => Math.random() - 0.5);
    return { ...q, options: opts };
  });
  const adelantada = d.attempt_type === "repaso_adelantado";
  state.quiz = {
    title:    d.nombre || "Test",
    testId:   d.quiz_id || null,
    tipo:     d.attempt_type || "quiz",
    questions: shuffled,
    correct:  d.correct || 0,
    wrong:    d.wrong   || 0,
    blank:    0,
    respondidasPrevias: (d.correct || 0) + (d.wrong || 0),
    answered: false,
    intentoId: d.attempt_id,
    tiempoPorPregunta: getTiempo(),
    totalEfectivo: d.total_efectivo,
    adelantada,
    favoritas: new Set(),
  };
  state.qi = 0;
  cargarFavoritasQuiz();  // no bloquea el render inicial
  navigate("quiz");
  $("#quiz-title").textContent = state.quiz.title +
    (adelantada ? "  ·  ⏩ adelantado" : "");
  renderPregunta();
  toast(`Reanudado: ${d.correct} aciertos, ${d.wrong} fallos previos`);
}

$("#btn-delete-test").addEventListener("click", () => {
  if (!state.currentTestId) return;
  $("#modal-borrar-test").classList.remove("hidden");
});

function cerrarModalBorrarTest() {
  $("#modal-borrar-test").classList.add("hidden");
}

// La X del header y el cierre con Esc / click en el backdrop los pinta y
// gestiona <ap-modal closable>; aquí solo el botón textual "Cancelar".
$("#btn-borrar-test-cancelar").addEventListener("click", cerrarModalBorrarTest);

$("#btn-borrar-solo-test").addEventListener("click", async () => {
  if (!state.currentTestId) return;
  try {
    await pg("/tests?id=eq." + state.currentTestId, { method: "DELETE" });
    toast("Test borrado (preguntas conservadas)");
    cerrarModalBorrarTest();
    navigate("tests");
  } catch (e) { toast(e.message); }
});

$("#btn-borrar-test-y-preguntas").addEventListener("click", async () => {
  if (!state.currentTestId) return;
  if (!confirm("Vas a borrar el test y todas las preguntas EXCLUSIVAS de este test. Las preguntas compartidas con otros tests se mantienen. ¿Continuar?")) return;
  try {
    const r = await rpc("borrar_test_y_preguntas", {
      p_test_id:           state.currentTestId,
      p_borrar_preguntas:  true,
    });
    toast(`Test borrado · ${r.preguntas_borradas} pregunta(s) eliminada(s), ${r.preguntas_compartidas} conservada(s) por compartir`);
    cerrarModalBorrarTest();
    navigate("tests");
  } catch (e) { toast(e.message); }
});

/* ── Quiz engine ── */
async function startQuiz(title, testId, questions, tipo = "quiz", opts = {}) {
  cancelarTimerQuiz();
  // Baraja preguntas y opciones de cada una
  const shuffled = [...questions].sort(() => Math.random() - 0.5).map(q => {
    const opts = q.options.map((o, i) => ({ ...o, origIdx: i }));
    opts.sort(() => Math.random() - 0.5);
    return { ...q, options: opts };
  });

  // Crea el intento ANTES de mostrar la primera pregunta para no perder
  // respuestas si el usuario va rápido.
  let intentoId = null;
  try {
    const r = await rpc("iniciar_intento", {
      p_test_id:      testId || null,
      p_tipo:         tipo,
      p_nombre:       title,
      p_question_ids: shuffled.map(q => q.id),
    });
    intentoId = r.attempt_id;
  } catch (e) {
    toast("No se pudo iniciar el intento: " + e.message);
    return;
  }

  state.quiz = {
    title, testId, tipo,
    questions: shuffled,
    correct: 0, wrong: 0, blank: 0,
    respondidasPrevias: 0,
    totalEfectivo: shuffled.length,
    answered: false,
    intentoId,
    tiempoPorPregunta: getTiempo(),
    adelantada: !!opts.adelantada,
    favoritas: new Set(),
  };
  state.qi = 0;
  await cargarFavoritasQuiz();
  navigate("quiz");
  $("#quiz-title").textContent = title +
    (opts.adelantada ? "  ·  ⏩ adelantado" : "");
  renderPregunta();
}

/* Trae el conjunto de preguntas favoritas del usuario al iniciar/reanudar
 * un quiz. Se guarda en state.quiz.favoritas para poder pintar el estado
 * del botón ⭐ en cada pregunta sin una RPC por render. */
async function cargarFavoritasQuiz() {
  if (!state.quiz) return;
  try {
    const r = await rpc("mis_favoritas_ids");
    state.quiz.favoritas = new Set((r && r.question_ids) || []);
  } catch {
    state.quiz.favoritas = new Set();
  }
}

function renderPregunta() {
  const q = state.quiz.questions[state.qi];
  state.quiz.answered = false;
  // Posición absoluta sobre el total real (incluye las ya respondidas en
  // sesiones previas si esto es una reanudación).
  const posicion = (state.quiz.respondidasPrevias || 0) + state.qi + 1;
  const total = state.quiz.totalEfectivo || state.quiz.questions.length;
  $("#quiz-progress").textContent = `${posicion} / ${total}`;
  $("#quiz-question").textContent = q.text;
  $("#quiz-explanation").classList.add("hidden");
  $("#btn-next").classList.add("hidden");
  $("#btn-edit-q").classList.add("hidden");
  $("#quiz-tags-inline").classList.add("hidden");
  $("#quiz-options").innerHTML = q.options.map((o, i) => `
    <button class="option-btn" data-i="${i}">${esc(o.text)}</button>
  `).join("");

  // Refresca el estado visual del botón ⭐ para esta pregunta.
  const esFav = !!(state.quiz.favoritas && state.quiz.favoritas.has(q.id));
  pintarBotonFavQ(esFav);

  // Temporizador configurable.  El id vive en una variable de módulo
  // (no en state.quiz) para evitar timers huérfanos cuando se reasigna
  // state.quiz entre quizzes.
  let t = state.quiz.tiempoPorPregunta || 20;
  $("#quiz-timer").textContent = t + "s";
  cancelarTimerQuiz();
  quizTimer = setInterval(() => {
    if (t <= 0) { cancelarTimerQuiz(); responder(null); return; }
    t--;
    $("#quiz-timer").textContent = t + "s";
  }, 1000);
}

let quizTimer = null;
function cancelarTimerQuiz() {
  if (quizTimer) { clearInterval(quizTimer); quizTimer = null; }
}

$("#quiz-options").addEventListener("click", e => {
  const btn = e.target.closest(".option-btn");
  if (!btn || state.quiz.answered) return;
  responder(parseInt(btn.dataset.i, 10));
});

$("#btn-skip").addEventListener("click", () => responder(null, true));
$("#btn-next").addEventListener("click", () => {
  state.qi++;
  if (state.qi >= state.quiz.questions.length) finalizarQuiz();
  else renderPregunta();
});

$("#btn-fav-q").addEventListener("click", async () => {
  const q = state.quiz.questions[state.qi];
  const btn = $("#btn-fav-q");
  if (btn.disabled) return;
  btn.disabled = true;
  try {
    const r = await rpc("toggle_favorita_pregunta", { p_pregunta_id: q.id });
    const ahora = !!(r && r.favorito);
    if (!state.quiz.favoritas) state.quiz.favoritas = new Set();
    if (ahora) state.quiz.favoritas.add(q.id);
    else       state.quiz.favoritas.delete(q.id);
    pintarBotonFavQ(ahora);
    toast(ahora ? "Añadida a favoritas" : "Quitada de favoritas");
  } catch (e) { toast(e.message); }
  finally { btn.disabled = false; }
});

function pintarBotonFavQ(activa) {
  const btn = $("#btn-fav-q");
  if (!btn) return;
  btn.classList.toggle("fav-on", activa);
  btn.setAttribute("aria-pressed", activa ? "true" : "false");
  btn.textContent = activa ? "⭐ Favorita" : "☆ Favorita";
}

async function responder(idx, saltada = false) {
  if (state.quiz.answered) return;
  state.quiz.answered = true;
  cancelarTimerQuiz();

  const q = state.quiz.questions[state.qi];
  const correctIdx = q.options.findIndex(o => o.isCorrect);
  const correcta = idx === correctIdx;
  const textoSel = idx == null ? (saltada ? "Saltada" : "Sin respuesta") : q.options[idx].text;

  $$(".option-btn").forEach((b, i) => {
    b.classList.add("disabled");
    if (i === correctIdx) b.classList.add("correct");
    if (i === idx && !correcta) b.classList.add("wrong");
  });

  if (correcta) state.quiz.correct++;
  else if (idx == null) state.quiz.blank++;
  else state.quiz.wrong++;

  if (q.explicacion) {
    const e = $("#quiz-explanation");
    e.textContent = q.explicacion;
    e.classList.remove("hidden");
  }
  $("#btn-next").classList.remove("hidden");
  $("#btn-edit-q").classList.remove("hidden");
  renderQuizTagsInline(q);

  if (state.quiz.intentoId) {
    try {
      const res = await rpc("registrar_respuesta", {
        p_intento_id:  state.quiz.intentoId,
        p_pregunta_id: q.id,
        p_texto:       textoSel,
        p_correcta:    correcta,
        p_adelantada:  !!state.quiz.adelantada,
      });
      notificarDesdeRPC(res);
    } catch (_) {}
  }
}

async function finalizarQuiz() {
  cancelarTimerQuiz();
  if (state.quiz.intentoId) {
    try {
      const res = await rpc("finalizar_intento", { p_intento_id: state.quiz.intentoId });
      notificarDesdeRPC(res);
      notificarXpTest(res);
    } catch (_) {}
  }
  // Nota sobre 10 con penalización 1/3.  Si veníamos de una reanudación,
  // 'totalEfectivo' = respondidas previas + pendientes (sin contar las
  // preguntas borradas, que no afectan).  En quiz nuevo coincide con la
  // longitud de questions.
  const total = state.quiz.totalEfectivo ?? state.quiz.questions.length;
  const nota = total ? Math.max(((state.quiz.correct - state.quiz.wrong/3) / total) * 10, 0) : 0;
  $("#quiz-summary-stats").innerHTML = `
    <div class="stat-card"><div class="v">${state.quiz.correct}</div><div class="l">Aciertos</div></div>
    <div class="stat-card"><div class="v">${state.quiz.wrong}</div><div class="l">Fallos</div></div>
    <div class="stat-card"><div class="v">${state.quiz.blank}</div><div class="l">En blanco</div></div>
    <div class="stat-card"><div class="v">${nota.toFixed(2)}</div><div class="l">Nota</div></div>
  `;
  state.quiz = null;
  // Las estadísticas por test cachean mi_progreso_detallado; al terminar
  // un intento, invalidamos para reflejar la última nota inmediatamente.
  state.progresoCache = null;
  navigate("quiz-summary");
}

document.addEventListener("keydown", e => {
  if (!state.quiz || $("#view-quiz").classList.contains("active") === false) return;
  // No interferir si el foco está en un input/textarea (modal de edición, etc.)
  const tag = (e.target.tagName || "").toLowerCase();
  if (tag === "input" || tag === "textarea") return;

  if (state.quiz.answered) {
    if (e.key === "Enter" || e.key === " " || e.key === "Escape") {
      e.preventDefault();
      $("#btn-next").click();
    }
    return;
  }
  const k = parseInt(e.key, 10);
  if (k >= 1 && k <= state.quiz.questions[state.qi].options.length) {
    $$(".option-btn")[k - 1]?.click();
  }
});

/* ── Fallos y favoritas ── */
async function loadFallos() {
  $("#list-fallos").innerHTML = "<p class='muted'>Cargando…</p>";
  const d = await rpc("mis_fallos");
  $("#list-fallos").innerHTML = (d.questions || []).map(q => `
    <li class="q-row" data-pid="${q.id}">
      <div class="q-text">${esc(q.text)}</div>
      <div class="q-meta">Fallada ${q.veces_fallada} veces</div>
      <div class="tags">${(q.etiquetas||[]).map(t => `<span class="tag">${esc(t)}</span>`).join("")}</div>
      <div class="q-actions gestion">
        <button class="btn btn-ghost btn-sm" data-action="edit-q">✏️ Editar</button>
      </div>
    </li>
  `).join("") || "<p class='muted'>Sin fallos aún.</p>";
  state.lastFallos = d.questions || [];
}

$("#list-fallos").addEventListener("click", e => {
  const btn = e.target.closest("[data-action=edit-q]");
  if (!btn) return;
  const li = e.target.closest("[data-pid]");
  if (li) editarPorId(li.dataset.pid, loadFallos);
});

$("#btn-start-fallos").addEventListener("click", async () => {
  if (!state.lastFallos || !state.lastFallos.length)
    return toast("No tienes fallos");
  await iniciarConPosibleReanudacion({
    tipo: "test_fallos",
    testId: null,
    title: "Test de fallos",
    questions: state.lastFallos,
  });
});

async function loadFavoritas() {
  $("#list-fav").innerHTML = "<p class='muted'>Cargando…</p>";
  const d = await rpc("mis_favoritas");
  $("#list-fav").innerHTML = (d.questions || []).map(q => `
    <li class="q-row" data-pid="${q.id}">
      <div class="q-text">${esc(q.text)}</div>
      <div class="tags">${(q.etiquetas||[]).map(t => `<span class="tag">${esc(t)}</span>`).join("")}</div>
      <div class="q-actions gestion">
        <button class="btn btn-ghost btn-sm" data-action="edit-q">✏️ Editar</button>
      </div>
    </li>
  `).join("") || "<p class='muted'>Aún no marcaste favoritas.</p>";
  state.lastFav = d.questions || [];
}

$("#list-fav").addEventListener("click", e => {
  const btn = e.target.closest("[data-action=edit-q]");
  if (!btn) return;
  const li = e.target.closest("[data-pid]");
  if (li) editarPorId(li.dataset.pid, loadFavoritas);
});

$("#btn-start-fav").addEventListener("click", async () => {
  if (!state.lastFav || !state.lastFav.length) return toast("Sin favoritas");
  await iniciarConPosibleReanudacion({
    tipo: "test_favoritas",
    testId: null,
    title: "Test de favoritas",
    questions: state.lastFav,
  });
});

/* ── Buscador (vista) ── */
$("#buscar-input").addEventListener("input", e => {
  clearTimeout(state._buscarDebounce);
  state._buscarDebounce = setTimeout(() => runBuscarView(e.target.value.trim()), 250);
});

async function runBuscarView(q) {
  await ensureEtiquetasCache();
  renderTagChipsMulti("#buscar-tag-chips", state.filtroEtiquetasBuscar, ets => {
    state.filtroEtiquetasBuscar = ets;
    runBuscarView($("#buscar-input").value.trim());
  });

  // Bloque "generar test temático" visible cuando hay etiquetas seleccionadas.
  $("#buscar-tematico").classList.toggle("hidden", state.filtroEtiquetasBuscar.length === 0);

  if (!q && state.filtroEtiquetasBuscar.length === 0) { $("#buscar-results").innerHTML = ""; return; }
  $("#buscar-results").innerHTML = "<p class='muted'>Buscando…</p>";
  try {
    const r = await rpc("buscar_preguntas_multi", {
      p_q: q || "", p_lim: 40,
      p_etiquetas: state.filtroEtiquetasBuscar.length ? state.filtroEtiquetasBuscar : null,
    });
    $("#buscar-results").innerHTML = r.map(p => `
      <li class="q-row" data-pid="${p.id}">
        <div class="q-text">${esc(p.enunciado)}</div>
        <div class="q-meta">Relevancia: ${Number(p.score).toFixed(2)}</div>
        <div class="q-actions gestion">
          <button class="btn btn-ghost btn-sm" data-action="edit-q">✏️ Editar</button>
        </div>
      </li>
    `).join("") || "<p class='muted'>Sin resultados.</p>";
  } catch (e) { toast(e.message); }
}

$("#btn-tematico").addEventListener("click", async () => {
  if (state.filtroEtiquetasBuscar.length === 0) return toast("Selecciona al menos una etiqueta");
  const n = parseInt($("#buscar-tem-n").value, 10);
  if (!n || n < 1) return toast("Indica un nº de preguntas válido");
  const btn = $("#btn-tematico");
  btn.disabled = true;
  try {
    const testId = await rpc("crear_test_tematico_multi", {
      p_etiquetas: state.filtroEtiquetasBuscar,
      p_n:         n,
    });
    toast("Test temático creado, cargando…");
    loadTestDetail(testId);
    navigate("test-detail");
  } catch (e) {
    toast(e.message.includes("sin_preguntas") ? "No hay preguntas para esas etiquetas" : e.message);
  } finally {
    btn.disabled = false;
  }
});

$("#buscar-results").addEventListener("click", e => {
  const btn = e.target.closest("[data-action=edit-q]");
  if (!btn) return;
  const li = e.target.closest("[data-pid]");
  if (li) editarPorId(li.dataset.pid, () => runBuscarView($("#buscar-input").value.trim()));
});

/* ── Subir test ── */
$("#upload-file").addEventListener("change", async e => {
  const f = e.target.files[0];
  if (!f) return;
  $("#upload-textarea").value = await f.text();
});

$("#btn-upload").addEventListener("click", async () => {
  let parsed;
  try { parsed = JSON.parse($("#upload-textarea").value); }
  catch (e) { return toast("JSON inválido"); }
  let titulo, descripcion = null, preguntas;
  if (Array.isArray(parsed)) {
    titulo = prompt("Nombre del test:") || "Test sin nombre";
    preguntas = parsed;
  } else {
    titulo = parsed.titulo || "Test sin nombre";
    descripcion = parsed.descripcion || null;
    preguntas = parsed.preguntas || [];
  }
  if (!preguntas.length) return toast("El JSON no tiene preguntas");
  try {
    await rpc("importar_test_normalizado", {
      p_titulo: titulo, p_descripcion: descripcion, p_preguntas: preguntas,
    });
    toast(`Importado: ${titulo}`);
    $("#upload-textarea").value = "";
    navigate("tests");
  } catch (e) { toast(e.message); }
});

/* ── Etiquetas ── */
async function loadEtiquetas() {
  const [tags, est] = await Promise.all([
    rpc("listar_etiquetas"),
    rpc("estado_embeddings"),
  ]);
  state.etiquetasCache = tags;
  $("#etiquetas-status").innerHTML = `
    Estado del worker:
    <strong>${est.preguntas_vectorizadas}</strong>/${est.preguntas_total} preguntas vectorizadas ·
    <strong>${est.etiquetas_vectorizadas}</strong>/${est.etiquetas_total} etiquetas ·
    cola: <strong>${est.cola_pendiente}</strong>
  `;

  // Rellena el <select> de padre con todas las etiquetas existentes.
  const sel = $("#et-padre");
  const padreActual = sel.value;
  sel.innerHTML = `<option value="">— sin padre —</option>` +
    tags.map(t => `<option value="${esc(t.nombre)}">${esc(t.nombre)}</option>`).join("");
  sel.value = padreActual;

  $("#etiquetas-list").innerHTML = tags.map(t => `
    <li class="etiqueta-row" data-nombre="${esc(t.nombre)}">
      <span class="dot ${t.vectorizada ? "ok" : ""}" title="${t.vectorizada ? "Vectorizada" : "Pendiente"}"></span>
      <div style="flex:1">
        <div class="nombre">
          ${esc(t.nombre)}
          ${t.padre ? `<span class="muted" style="font-weight:normal">⊂ ${esc(t.padre)}</span>` : ""}
          ${t.num_hijas ? `<span class="muted" style="font-weight:normal">· ${t.num_hijas} hija${t.num_hijas === 1 ? "" : "s"}</span>` : ""}
        </div>
        <div class="descripcion">${esc(t.descripcion || "(sin descripción)")}</div>
        ${(t.palabras_clave && t.palabras_clave.length)
          ? `<div class="tags" style="margin-top:0.3rem">${t.palabras_clave.map(k => `<span class="tag">${esc(k)}</span>`).join("")}</div>`
          : ""}
      </div>
      <span class="count">${t.num_preguntas} preg · ${t.num_tests || 0} tests</span>
      <button class="btn btn-ghost btn-sm" data-edit="${esc(t.nombre)}">✏️</button>
      <button class="btn btn-ghost btn-sm" data-del="${esc(t.nombre)}">🗑️</button>
    </li>
  `).join("") || "<p class='muted'>Crea tu primera etiqueta para que el auto-tagger empiece a clasificar.</p>";
}

$("#form-etiqueta").addEventListener("submit", async e => {
  e.preventDefault();
  const palabras = $("#et-palabras").value.split(",")
    .map(s => s.trim().toLowerCase()).filter(Boolean);
  try {
    await rpc("crear_etiqueta", {
      p_nombre:          $("#et-nombre").value.trim(),
      p_descripcion:     $("#et-descripcion").value.trim() || null,
      p_palabras_clave:  palabras,
      p_padre:           $("#et-padre").value || null,
    });
    $("#et-nombre").value = ""; $("#et-descripcion").value = "";
    $("#et-palabras").value = ""; $("#et-padre").value = "";
    toast("Etiqueta guardada");
    state.etiquetasCache = [];  // invalida cache
    loadEtiquetas();
  } catch (e) { toast(e.message); }
});

$("#etiquetas-list").addEventListener("click", async e => {
  const del = e.target.closest("[data-del]");
  const edit = e.target.closest("[data-edit]");
  if (del) {
    if (!confirm(`¿Borrar la etiqueta "${del.dataset.del}"? Se quitará de todas las preguntas y tests.`)) return;
    try {
      await rpc("borrar_etiqueta", { p_nombre: del.dataset.del });
      toast("Borrada");
      state.etiquetasCache = [];
      loadEtiquetas();
    } catch (e) { toast(e.message); }
  }
  if (edit) {
    const tag = state.etiquetasCache.find(t => t.nombre === edit.dataset.edit);
    $("#et-nombre").value = tag?.nombre || "";
    $("#et-descripcion").value = tag?.descripcion || "";
    $("#et-palabras").value = (tag?.palabras_clave || []).join(", ");
    $("#et-padre").value = tag?.padre || "";
    $("#et-nombre").focus();
  }
});

/* Importación masiva de etiquetas: JSON array con {nombre, descripcion?,
   palabras_clave?, padre?}. La RPC ordena por padres, así que se puede
   subir el árbol entero en un solo fichero. */
$("#btn-et-import").addEventListener("click", () => $("#et-import-file").click());
$("#et-import-file").addEventListener("change", async e => {
  const file = e.target.files[0];
  if (!file) return;
  try {
    const texto = await file.text();
    let json;
    try { json = JSON.parse(texto); }
    catch { toast("JSON inválido"); return; }
    if (!Array.isArray(json)) { toast("Debe ser un array JSON"); return; }
    if (!confirm(`Importar ${json.length} etiquetas? Las existentes se actualizarán.`)) return;
    const r = await rpc("importar_etiquetas", { p_json: json });
    const items = r.items || [];
    const nuevas = items.filter(x => x.estado === "creada").length;
    const upd    = items.filter(x => x.estado === "actualizada").length;
    const errs   = items.filter(x => x.estado === "error");
    let msg = `${nuevas} creadas · ${upd} actualizadas`;
    if (errs.length) {
      msg += ` · ${errs.length} error${errs.length === 1 ? "" : "es"}`;
      console.warn("Errores importando etiquetas:", errs);
    }
    toast(msg);
    state.etiquetasCache = [];
    loadEtiquetas();
  } catch (err) { toast(err.message); }
  finally { e.target.value = ""; }
});

$("#btn-reclasificar").addEventListener("click", async () => {
  if (!confirm("Esto recorrerá TODOS los tests y preguntas, etiquetándolos por nombre, palabras clave y similitud vectorial. ¿Seguir?")) return;
  try {
    $("#btn-reclasificar").disabled = true;
    const r = await rpc("reclasificar_todo");
    toast(`${r.tests_procesados} tests · ${r.preguntas_procesadas} preguntas procesadas`);
    state.etiquetasCache = [];
    loadEtiquetas();
  } catch (e) { toast(e.message); }
  finally { $("#btn-reclasificar").disabled = false; }
});

/* ── Editor inline de etiquetas en el quiz ──────────────────────────────────
 * Se muestra tras revelar la respuesta. Cada chip lleva una ✕ para quitarla;
 * el input usa un <datalist> con el catálogo completo. Toda edición persiste
 * con un PATCH a /preguntas y la pregunta editada queda como "ejemplo" para
 * el k-NN: la próxima pregunta parecida que llegue al worker heredará estas
 * etiquetas vía reclasificar_pregunta. */
async function renderQuizTagsInline(q) {
  const cont = $("#quiz-tags-inline");
  cont.classList.remove("hidden");
  await ensureEtiquetasCache();

  // Refresca las etiquetas reales por si el auto-tagger las cambió desde
  // que se cargó el test en memoria.
  try {
    const r = await pg(`/preguntas?id=eq.${q.id}&select=etiquetas`);
    if (r.length) q.etiquetas = r[0].etiquetas || [];
  } catch (_) { /* no bloqueante */ }

  pintarQuizTagChips(q);

  // Datalist con todas las etiquetas conocidas para autocomplete.
  $("#quiz-tag-datalist").innerHTML = state.etiquetasCache
    .map(t => `<option value="${esc(t.nombre)}">`).join("");
  $("#quiz-tag-add").value = "";
}

function pintarQuizTagChips(q) {
  const chipsDiv = $("#quiz-tags-chips");
  const tags = q.etiquetas || [];
  if (!tags.length) {
    chipsDiv.innerHTML = `<span class="muted small">— sin etiquetas —</span>`;
  } else {
    chipsDiv.innerHTML = tags.map(t => `
      <span class="tag removable" data-tag="${esc(t)}">
        ${esc(t)}<span class="x" data-rm="${esc(t)}" title="Quitar">×</span>
      </span>
    `).join("");
  }
}

async function actualizarEtiquetasPregunta(qId, nuevas) {
  // Vía RPC para que las etiquetas quitadas queden como 'bloqueadas' y el
  // auto-tagger no vuelva a ponerlas; las añadidas quedan como 'manuales'
  // y educan al kNN.
  await rpc("set_etiquetas_pregunta", { p_id: qId, p_etiquetas: nuevas });
}

$("#quiz-tags-chips").addEventListener("click", async e => {
  const rm = e.target.closest("[data-rm]");
  if (!rm || !state.quiz) return;
  const q = state.quiz.questions[state.qi];
  const tag = rm.dataset.rm;
  const nuevas = (q.etiquetas || []).filter(t => t !== tag);
  try {
    await actualizarEtiquetasPregunta(q.id, nuevas);
    q.etiquetas = nuevas;
    pintarQuizTagChips(q);
  } catch (err) { toast(err.message); }
});

$("#quiz-tag-add").addEventListener("keydown", async e => {
  if (e.key !== "Enter") return;
  e.preventDefault();
  if (!state.quiz) return;
  const inp = e.target;
  const tag = inp.value.trim().toLowerCase();
  if (!tag) return;
  const q = state.quiz.questions[state.qi];
  if ((q.etiquetas || []).includes(tag)) {
    toast("Ya tiene esa etiqueta");
    inp.value = "";
    return;
  }
  // Avisa si la etiqueta no existe en el catálogo: se guarda igual, pero
  // queda fuera de la jerarquía y del auto-tagger hasta que la crees.
  if (!state.etiquetasCache.some(t => t.nombre === tag)) {
    if (!confirm(`"${tag}" no existe en el catálogo. ¿Añadirla igualmente a esta pregunta?`)) return;
  }
  const nuevas = [...(q.etiquetas || []), tag];
  try {
    await actualizarEtiquetasPregunta(q.id, nuevas);
    q.etiquetas = nuevas;
    inp.value = "";
    pintarQuizTagChips(q);
  } catch (err) { toast(err.message); }
});


/* ── Usuarios (solo admin) ──────────────────────────────────────────────── */
async function loadUsuarios() {
  $("#usuarios-list").innerHTML = "<p class='muted'>Cargando…</p>";
  try {
    const [users, roles] = await Promise.all([
      rpc("listar_usuarios"),
      rpc("listar_roles"),
    ]);
    state.usuariosCache = users;
    state.rolesCache = roles;
    renderUsuarios();
  } catch (e) {
    $("#usuarios-list").innerHTML = `<p class='muted'>${esc(e.message)}</p>`;
  }
}

function renderUsuarios() {
  const f = ($("#usuarios-filtro").value || "").toLowerCase();
  const lista = (state.usuariosCache || []).filter(u =>
    !f || u.username.toLowerCase().includes(f) || (u.email||"").toLowerCase().includes(f)
  );
  $("#usuarios-list").innerHTML = lista.map(u => {
    const ini = (u.username[0] || "?").toUpperCase();
    const roles = (u.roles || []).map(r =>
      `<span class="role-chip ${r === 'admin' ? 'admin' : ''}">${esc(r)}</span>`
    ).join("");
    return `
      <li class="usuario-row ${u.activo ? "" : "inactivo"}" data-id="${u.id}">
        <span class="avatar-row">${esc(ini)}</span>
        <div>
          <div class="nombre">${esc(u.username)}</div>
          <div class="meta">${esc(u.email || "(sin email)")} ${u.chat_id ? `· chat ${esc(u.chat_id)}` : ""}</div>
          <div class="roles-chips">${roles || `<span class="meta">(sin roles)</span>`}</div>
        </div>
        <span class="meta">${u.tiene_pass ? "🔑" : "—"}</span>
      </li>
    `;
  }).join("") || "<p class='muted'>Sin usuarios.</p>";
}

$("#usuarios-filtro").addEventListener("input", renderUsuarios);

$("#usuarios-list").addEventListener("click", e => {
  const row = e.target.closest(".usuario-row");
  if (!row) return;
  const u = state.usuariosCache.find(x => x.id === row.dataset.id);
  if (u) abrirModalUsuario(u);
});

function abrirModalUsuario(u) {
  $("#modal-usuario-titulo").textContent = u.username;
  const rolesActivos = new Set(u.roles || []);
  const todosRoles = state.rolesCache || [];

  $("#modal-usuario-body").innerHTML = `
    <div>
      <h4>Roles</h4>
      <div class="roles-grid">
        ${todosRoles.map(r => `
          <button class="role-toggle ${rolesActivos.has(r.id) ? "active" : ""}" data-rol="${esc(r.id)}">
            ${esc(r.id)}
          </button>
        `).join("")}
      </div>
    </div>

    <div>
      <h4>Resetear contraseña</h4>
      <div class="input-row">
        <input id="modal-pass" type="password" placeholder="Nueva contraseña (≥ 6 carac.)">
        <button class="btn btn-primary btn-sm" id="modal-reset-pass">Resetear</button>
      </div>
    </div>

    <div>
      <h4>Estado</h4>
      <div class="input-row">
        <button class="btn btn-${u.activo ? "danger" : "primary"} btn-sm" id="modal-toggle-activo">
          ${u.activo ? "Desactivar" : "Activar"}
        </button>
        <span class="muted" style="align-self:center">
          ${u.activo ? "Usuario activo, puede iniciar sesión" : "Usuario desactivado"}
        </span>
      </div>
    </div>

    <div>
      <h4>Oposiciones asignadas</h4>
      <div class="input-row">
        <button class="btn btn-sec btn-sm" data-action="oposiciones-usuario"
                data-usuario-id="${esc(u.user_id || u.id)}" data-usuario-nombre="${esc(u.username)}">
          🎓 Gestionar oposiciones
        </button>
        <span class="muted small" style="align-self:center">
          Marca a qué oposiciones puede acceder este usuario.
        </span>
      </div>
    </div>
  `;

  $$(".role-toggle", $("#modal-usuario-body")).forEach(btn => {
    btn.addEventListener("click", async () => {
      const rol = btn.dataset.rol;
      const tieneEseRol = btn.classList.contains("active");
      try {
        if (tieneEseRol) {
          await rpc("quitar_rol", { p_usuario_id: u.id, p_rol_id: rol });
        } else {
          await rpc("asignar_rol", { p_usuario_id: u.id, p_rol_id: rol });
        }
        btn.classList.toggle("active");
        toast(tieneEseRol ? `Rol '${rol}' quitado` : `Rol '${rol}' añadido`);
        // refresca cache local
        if (tieneEseRol) u.roles = u.roles.filter(r => r !== rol);
        else u.roles = [...u.roles, rol];
      } catch (e) { toast(e.message); }
    });
  });

  $("#modal-reset-pass").addEventListener("click", async () => {
    const v = $("#modal-pass").value;
    if (!v || v.length < 6) return toast("Mínimo 6 caracteres");
    try {
      await rpc("resetear_contrasena", { p_usuario_id: u.id, p_nueva_pass: v });
      $("#modal-pass").value = "";
      u.tiene_pass = true;
      toast("Contraseña reseteada");
    } catch (e) { toast(e.message); }
  });

  $("#modal-toggle-activo").addEventListener("click", async () => {
    try {
      await rpc("set_usuario_activo", { p_usuario_id: u.id, p_activo: !u.activo });
      u.activo = !u.activo;
      cerrarModalUsuario();
      renderUsuarios();
      toast(u.activo ? "Activado" : "Desactivado");
    } catch (e) { toast(e.message); }
  });

  $("#modal-usuario").classList.remove("hidden");
}

function cerrarModalUsuario() {
  $("#modal-usuario").classList.add("hidden");
  renderUsuarios();
}

// La X la pinta y gestiona <ap-modal closable>.
// El listener de "ap-close" recarga la lista de usuarios al cerrar el modal
// desde el propio componente (Esc, X o click en backdrop).
$("#modal-usuario").addEventListener("ap-close", renderUsuarios);


/* ── Repaso espaciado ────────────────────────────────────────────────────
 *
 * Dos entradas: "Repasar test" (individual, botón en el detalle del test)
 * y "Repasar todo" (global, botón en la pestaña de tests). Ambos usan el
 * mismo motor.
 *
 * Cuando NO hay vencidas, se muestra un modal con la fecha del siguiente
 * repaso y opción de "Adelantar" (que arranca el quiz con adelantada=true,
 * de forma que los aciertos NO reprograman la caja).
 */

function fmtFechaRelativa(iso) {
  if (!iso) return "—";
  const ms = new Date(iso).getTime() - Date.now();
  if (ms <= 0) return "vencido";
  const min = Math.round(ms / 60000);
  if (min < 60) return `en ${min} min`;
  const h = Math.round(min / 60);
  if (h < 48) return `en ${h} h`;
  const d = Math.round(h / 24);
  return `en ${d} d`;
}

/* Botón "Repasar todo" en la pestaña de tests */
$("#btn-repasar-todo")?.addEventListener("click", async () => {
  try {
    const r = await rpc("resumen_repaso_global");
    abrirModalRepasoN({
      titulo: "Repasar todo (vencidas globales)",
      info: `${r.vencidas} vencidas · ${r.total_repasos} preguntas en repaso.`,
      onEmpezar: async (n) => arrancarRepasoGlobal(n, false),
      sinVencidas: r.vencidas === 0,
      siguiente:   r.siguiente,
      onAdelantar: (n) => arrancarRepasoGlobal(n, true),
    });
  } catch (e) { toast(e.message); }
});

/* Botón "Repasar" en el detalle del test */
$("#btn-repasar-test")?.addEventListener("click", async () => {
  if (!state.currentTestId) return;
  try {
    const r = await rpc("resumen_repaso_test", { p_test_id: state.currentTestId });
    if (!r.test_realizado) {
      toast("Aún no has hecho este test. Empieza por 'Empezar test'.");
      return;
    }
    abrirModalRepasoN({
      titulo: `Repasar: ${state.currentTest?.quiz?.title || "test"}`,
      info: `${r.vencidas} vencidas de ${r.total_repasos} en repaso · ${r.dominadas} dominadas.`,
      onEmpezar: async (n) => arrancarRepasoTest(state.currentTestId, n, false),
      sinVencidas: r.vencidas === 0,
      siguiente:   r.siguiente,
      onAdelantar: (n) => arrancarRepasoTest(state.currentTestId, n, true),
    });
  } catch (e) { toast(e.message); }
});

/* Modal de "elige N y empieza". Si no hay vencidas, salta al modal de adelantar. */
function abrirModalRepasoN({ titulo, info, onEmpezar, sinVencidas, siguiente, onAdelantar }) {
  if (sinVencidas) {
    abrirModalSinVencidas({ titulo, siguiente, onAdelantar });
    return;
  }
  $("#repaso-n-titulo").textContent = titulo;
  $("#repaso-n-info").textContent   = info;
  const modal = $("#modal-repaso-n");
  modal.classList.remove("hidden");
  const cerrar = () => {
    modal.classList.add("hidden");
    $("#btn-repaso-n-empezar").onclick   = null;
    $("#btn-repaso-n-cancelar").onclick  = null;
  };
  $("#btn-repaso-n-empezar").onclick = async () => {
    const n = Math.max(1, parseInt($("#repaso-n-n").value, 10) || 20);
    cerrar();
    await onEmpezar(n);
  };
  $("#btn-repaso-n-cancelar").onclick = cerrar;
  // Cierre por Esc/X/backdrop: <ap-modal closable> ya oculta el modal;
  // aquí sólo desenganchamos los onclick para no dejarlos disparándose
  // con estado obsoleto la próxima vez que se abra.
  modal.addEventListener("ap-close", () => {
    $("#btn-repaso-n-empezar").onclick  = null;
    $("#btn-repaso-n-cancelar").onclick = null;
  }, { once: true });
}

function abrirModalSinVencidas({ titulo, siguiente, onAdelantar }) {
  $("#repaso-sv-titulo").textContent = titulo;
  const fecha = siguiente ? fmtFechaRelativa(siguiente) : "sin más preguntas programadas";
  $("#repaso-sv-msg").textContent =
    `Sin vencidas ahora mismo. Siguiente vence ${fecha}.`;
  const modal = $("#modal-repaso-sin-vencidas");
  modal.classList.remove("hidden");
  const cerrar = () => {
    modal.classList.add("hidden");
    $("#btn-repaso-sv-adelantar").onclick = null;
    $("#btn-repaso-sv-cancelar").onclick  = null;
  };
  $("#btn-repaso-sv-adelantar").onclick = async () => {
    const n = Math.max(1, parseInt($("#repaso-sv-n").value, 10) || 20);
    cerrar();
    await onAdelantar(n);
  };
  $("#btn-repaso-sv-cancelar").onclick = cerrar;
  // Cierre por Esc/X/backdrop: <ap-modal closable> ya oculta el modal;
  // aquí sólo desenganchamos los onclick para no dejarlos disparándose
  // con estado obsoleto la próxima vez que se abra.
  modal.addEventListener("ap-close", () => {
    $("#btn-repaso-sv-adelantar").onclick = null;
    $("#btn-repaso-sv-cancelar").onclick  = null;
  }, { once: true });
}

async function arrancarRepasoTest(testId, n, adelantar) {
  try {
    const d = await rpc("preguntas_repaso_test", {
      p_test_id: testId, p_n: n, p_adelantar: !!adelantar,
    });
    if (!d.questions || d.questions.length === 0) {
      toast("No hay preguntas para repasar");
      return;
    }
    const tipo  = adelantar ? "repaso_adelantado" : "repaso_test";
    const title = "Repaso · " + (d.quiz?.title || "test");
    await iniciarConPosibleReanudacion({
      tipo, testId, title,
      questions: d.questions,
      opts: { adelantada: !!adelantar },
    });
  } catch (e) { toast(e.message); }
}

async function arrancarRepasoGlobal(n, adelantar) {
  try {
    const d = await rpc("preguntas_repaso_global", {
      p_n: n, p_adelantar: !!adelantar,
    });
    if (!d.questions || d.questions.length === 0) {
      toast("No hay preguntas para repasar");
      return;
    }
    const tipo  = adelantar ? "repaso_adelantado" : "repaso_global";
    const title = "Repaso global";
    await iniciarConPosibleReanudacion({
      tipo, testId: null, title,
      questions: d.questions,
      opts: { adelantada: !!adelantar },
    });
  } catch (e) { toast(e.message); }
}

/* Actualizar contadores (badges) al cargar tests o abrir detalle */
async function refrescarBadgeGlobal() {
  const badge = $("#repaso-global-badge");
  if (!badge) return;
  try {
    const r = await rpc("resumen_repaso_global");
    if (r.vencidas > 0) {
      badge.textContent = r.vencidas;
      badge.classList.remove("hidden", "calma");
    } else {
      badge.classList.add("hidden");
    }
  } catch (_) { badge.classList.add("hidden"); }
}

async function refrescarBadgeTest(testId) {
  const badge = $("#repaso-test-badge");
  const boton = $("#btn-repasar-test");
  if (!badge || !boton) return;
  try {
    const r = await rpc("resumen_repaso_test", { p_test_id: testId });
    if (!r.test_realizado) {
      boton.classList.add("hidden");
      return;
    }
    boton.classList.remove("hidden");
    if (r.vencidas > 0) {
      badge.textContent = r.vencidas;
      badge.classList.remove("hidden", "calma");
    } else {
      badge.textContent = "0";
      badge.classList.remove("hidden");
      badge.classList.add("calma");
    }
  } catch (_) { badge.classList.add("hidden"); }
}

/* Hook: cuando se carga la lista de tests, refrescamos badge global */
(function hookLoadTests() {
  if (typeof loadTests !== "function") return;
  const orig = loadTests;
  loadTests = async function(...args) {
    const r = await orig.apply(this, args);
    refrescarBadgeGlobal();
    return r;
  };
})();

/* Hook: cuando se carga el detalle de un test, refrescamos su badge */
(function hookLoadTestDetail() {
  if (typeof loadTestDetail !== "function") return;
  const orig = loadTestDetail;
  loadTestDetail = async function(testId, ...rest) {
    const r = await orig.call(this, testId, ...rest);
    refrescarBadgeTest(testId);
    return r;
  };
})();

/* ── Configuración unificada ─────────────────────────────────────────────
 * La configuración (apariencia + notificaciones + ritmo + reset) la
 * gestiona shared/config.js: es el mismo modal en landing, tests y
 * teoría. Aquí solo la inicializamos y sincronizamos la home tras un
 * reset. AprentixConfig lee/escribe la cookie aprentix_theme.
 */
if (window.AprentixConfig) {
  window.AprentixConfig.init({ token: () => state.jwt, api: "/tests/api" });
} else {
  window.addEventListener("load", () => {
    window.AprentixConfig?.init({ token: () => state.jwt, api: "/tests/api" });
  });
}


/* ── Cambios de sesión en otra pestaña ───────────────────────────────────
 * La cookie `aprentix_token` vive en .aprentix.es y la comparten tests y
 * teoría. Si el usuario hace logout o entra con otra cuenta en otra
 * pestaña (o subdominio), esta pestaña sigue con el state.jwt viejo. Al
 * volver a esta pestaña recargamos si la cookie ya no coincide con lo que
 * teníamos, para no operar con la sesión anterior. */
document.addEventListener("visibilitychange", () => {
  if (document.hidden) return;
  const cookieNow = getCookie(COOKIE_NAME);
  if (cookieNow !== state.jwt) location.reload();
});

/* ── Arranque ───────────────────────────────────────────────────────────── */
inicializarInputsTiempo();
(async () => {
  await refrescarUsuarioDesdeJwt();
  if (state.jwt && localStorage.getItem("jwt")) {
    // Migración legada: token en localStorage → cookie compartida.
    persistSession();
  }
  applySession();

  // Atajos desde el manifest (Repasar / Fallos / Tests) o desde click en
  // notificación. Solo respetamos el atajo si hay sesión válida.
  const atajo = new URLSearchParams(location.search).get("atajo");
  const destino = atajoAVista(atajo);
  navigate(state.jwt && state.user ? (destino || "home") : "login");

  // Fase 5: cargar oposiciones accesibles del usuario y decidir si hay
  // que mostrar el selector inicial.
  if (state.jwt && state.user) {
    cargarMisOposiciones().catch(() => {});
  }

  // Si ya hay permiso concedido, sincronizamos silenciosamente la
  // suscripción con el backend (por si se creó en otro dispositivo o
  // el navegador rotó las claves).
  if (state.jwt && state.user) sincronizarPushSilencioso();
})();


/* ═════════════════════════════════════════════════════════════════════════
 *  Fase 5: oposiciones y perfiles
 * ═════════════════════════════════════════════════════════════════════════ */

function kOposicion() {
  const uid = state.user && state.user.user_id;
  return uid ? `aprentix.oposicion.${uid}` : null;
}
function leerOposicionPersistida() {
  const k = kOposicion();
  if (!k) return null;
  try {
    const raw = localStorage.getItem(k);
    return raw ? JSON.parse(raw) : null;
  } catch { return null; }
}
function guardarOposicionPersistida(op) {
  const k = kOposicion();
  if (!k) return;
  try {
    if (op) localStorage.setItem(k, JSON.stringify({ id: op.id, nombre: op.nombre }));
    else    localStorage.removeItem(k);
  } catch {}
}

async function cargarMisOposiciones() {
  const ops = await rpc("mis_oposiciones");
  state.misOposicionesCache = Array.isArray(ops) ? ops : [];
  // Marca en el body si hay >1 para que <aprentix-header> muestre la
  // fila "Cambiar oposición" en el sheet.
  document.body.classList.toggle("has-oposiciones", state.misOposicionesCache.length > 1);

  // Restaura la selección persistida si sigue accesible.
  const guardada = leerOposicionPersistida();
  if (guardada && state.misOposicionesCache.some(o => o.id === guardada.id)) {
    state.currentOposicion = guardada.id;
    state.currentOposicionNombre = guardada.nombre;
  } else if (state.misOposicionesCache.length === 1) {
    // Con una sola oposición accesible no hay decisión que tomar.
    const o = state.misOposicionesCache[0];
    state.currentOposicion = o.id;
    state.currentOposicionNombre = o.nombre;
    guardarOposicionPersistida(o);
  } else if (state.misOposicionesCache.length > 1 && !state.currentOposicion) {
    abrirSelectorOposicion();
  }
  refrescarHintOposicion();
}

function refrescarHintOposicion() {
  const el = document.getElementById("sheet-oposicion-actual");
  if (el) el.textContent = state.currentOposicionNombre || "Todas";
  // Cabecera de Home: chip con la oposición actual + acceso rápido a cambiar.
  const chip = document.getElementById("ap-op-actual");
  if (chip) chip.textContent = state.currentOposicionNombre || "Todas";
  const btnHome = document.getElementById("btn-cambiar-oposicion-home");
  // Solo tiene sentido si el usuario tiene más de una oposición para elegir.
  const varias = (state.misOposicionesCache || []).length > 1;
  if (btnHome) btnHome.hidden = !varias;
}

function abrirSelectorOposicion() {
  const selector = $("#modal-elegir-oposicion");
  if (!selector) return;
  selector.setOptions(state.misOposicionesCache, state.currentOposicion);
  selector.open();
}

// La lista, el modal y el cierre los pinta y gestiona <ap-op-selector>;
// aquí sólo reaccionamos al evento de elección.
$("#modal-elegir-oposicion")?.addEventListener("ap-op-selection-required", () => {
  toast("Debes seleccionar una oposición para continuar.");
});

$("#modal-elegir-oposicion")?.addEventListener("ap-op-select", (e) => {
  const { id, nombre } = e.detail;
  const op = id ? state.misOposicionesCache.find(o => o.id === id) : null;
  state.currentOposicion = id;
  state.currentOposicionNombre = op ? op.nombre : (id ? nombre : null);
  guardarOposicionPersistida(op);
  refrescarHintOposicion();
  // Recarga los tests con el nuevo filtro.
  if ($("#view-tests")?.classList.contains("active")) {
    state.testsPage = 1;
    loadTests();
  }
});

document.getElementById("btn-cambiar-oposicion")?.addEventListener("click", abrirSelectorOposicion);
document.getElementById("btn-cambiar-oposicion-home")?.addEventListener("click", abrirSelectorOposicion);

/* ── Vista Oposiciones (admin) ──────────────────────────────────────────── */
loaders.oposiciones = loadOposicionesAdmin;

async function loadOposicionesAdmin() {
  try {
    const ops = await rpc("listar_oposiciones_admin").catch(() => []);
    state.oposAdminCache = Array.isArray(ops) ? ops : [];
    renderOposicionesAdmin();
  } catch (e) { toast(e.message); }
}

function renderOposicionesAdmin() {
  $("#oposiciones-list").innerHTML = (state.oposAdminCache || []).map(o => `
    <li class="opos-item" data-id="${o.id}">
      <div class="opos-head">
        <strong>${esc(o.nombre)}</strong>
        ${o.activa ? "" : `<span class="tag">Inactiva</span>`}
        <span class="muted small">${o.num_tests} tests · ${o.num_usuarios || 0} usuarios</span>
      </div>
      ${o.descripcion ? `<div class="muted small">${esc(o.descripcion)}</div>` : ""}
      <div class="opos-actions">
        <button class="btn btn-primary btn-sm" data-action="bulk-tests">🧩 Asignar tests</button>
        <button class="btn btn-ghost btn-sm" data-action="editar-op">✏️ Editar</button>
        <button class="btn btn-ghost btn-sm" data-action="toggle-op">${o.activa ? "🚫 Desactivar" : "✅ Activar"}</button>
        <button class="btn btn-ghost btn-sm" data-action="borrar-op">🗑️ Borrar</button>
      </div>
    </li>
  `).join("") || "<p class='muted'>Sin oposiciones aún.</p>";
}

$("#form-oposicion")?.addEventListener("submit", async (e) => {
  e.preventDefault();
  const nombre = $("#op-nombre").value.trim();
  const desc   = $("#op-desc").value.trim();
  if (!nombre) return;
  try {
    await rpc("crear_oposicion", { p_nombre: nombre, p_descripcion: desc || null });
    toast("Oposición creada");
    $("#op-nombre").value = ""; $("#op-desc").value = "";
    loadOposicionesAdmin();
    cargarMisOposiciones();
  } catch (err) { toast(err.message); }
});

$("#oposiciones-list")?.addEventListener("click", async (e) => {
  const btn = e.target.closest("[data-action]");
  if (!btn) return;
  const li = btn.closest(".opos-item");
  const id = li?.dataset.id;
  const o = (state.oposAdminCache || []).find(x => x.id === id);
  if (!o) return;
  const action = btn.dataset.action;
  if (action === "editar-op") {
    const nombre = prompt("Nuevo nombre:", o.nombre);
    if (nombre == null) return;
    const desc = prompt("Descripción (vacío para no tocar):", o.descripcion || "");
    try {
      await rpc("editar_oposicion", {
        p_id: id, p_nombre: nombre.trim(), p_descripcion: desc && desc.trim(),
      });
      loadOposicionesAdmin();
    } catch (err) { toast(err.message); }
  }
  if (action === "toggle-op") {
    try {
      await rpc("editar_oposicion", { p_id: id, p_nombre: o.nombre, p_activa: !o.activa });
      loadOposicionesAdmin();
    } catch (err) { toast(err.message); }
  }
  if (action === "borrar-op") {
    if (!confirm(`¿Borrar "${o.nombre}"? Se desasignará de sus tests y usuarios.`)) return;
    try {
      await rpc("borrar_oposicion", { p_id: id });
      loadOposicionesAdmin();
      cargarMisOposiciones();
    } catch (err) { toast(err.message); }
  }
  if (action === "bulk-tests") {
    abrirModalBulkTests(o);
  }
});

/* ── Modal BULK: asignar tests a una oposición ─────────────────────────
 * Carga todos los tests (listar_tests_min) y los tests ya asignados
 * (tests_de_oposicion) para pre-marcar. Filtro por título + etiqueta
 * en cliente. Guarda con set_oposicion_tests (reemplaza el conjunto). */
const BULK = { oposicion: null, tests: [], seleccion: new Set() };

async function abrirModalBulkTests(oposicion) {
  const modal = $("#modal-bulk-tests");
  $("#modal-bulk-titulo").textContent = `Tests de "${oposicion.nombre}"`;
  BULK.oposicion = oposicion;
  BULK.tests = [];
  BULK.seleccion = new Set();
  $("#bulk-tests-list").innerHTML = "<li class='muted'>Cargando…</li>";
  modal.classList.remove("hidden");
  try {
    const [all, actuales] = await Promise.all([
      rpc("listar_tests_min").catch(() => []),
      rpc("tests_de_oposicion", { p_oposicion_id: oposicion.id }).catch(() => []),
    ]);
    BULK.tests = Array.isArray(all) ? all : [];
    (Array.isArray(actuales) ? actuales : []).forEach(id => BULK.seleccion.add(id));
    // Cache de etiquetas ya la tenemos por otra vía; para robustez usamos las
    // etiquetas que aparecen en la lista de tests.
    const etsSet = new Set();
    BULK.tests.forEach(t => (t.etiquetas || []).forEach(e => etsSet.add(e)));
    const opts = ['<option value="">Todas las etiquetas</option>']
      .concat([...etsSet].sort().map(t => `<option value="${esc(t)}">${esc(t)}</option>`));
    $("#bulk-filter-etiqueta").innerHTML = opts.join("");
    $("#bulk-filter-nombre").value = "";
    pintarBulkTests();
  } catch (e) {
    $("#bulk-tests-list").innerHTML = `<li class='muted'>${esc(e.message)}</li>`;
  }
}

function bulkFiltrar() {
  const q  = ($("#bulk-filter-nombre").value || "").trim().toLowerCase();
  const et = $("#bulk-filter-etiqueta").value || "";
  return BULK.tests.filter(t => {
    if (q && !t.titulo.toLowerCase().includes(q)) return false;
    if (et && !(t.etiquetas || []).includes(et))  return false;
    return true;
  });
}

function pintarBulkTests() {
  const lista = $("#bulk-tests-list");
  const filtrados = bulkFiltrar();
  lista.innerHTML = filtrados.map(t => `
    <li>
      <label class="check-item">
        <input type="checkbox" data-test-id="${t.id}" ${BULK.seleccion.has(t.id) ? "checked" : ""}>
        <span>
          <strong>${esc(t.titulo)}</strong>
          <span class="muted small">${t.num_preguntas || 0} preguntas${(t.etiquetas || []).length ? " · " + (t.etiquetas || []).map(esc).join(", ") : ""}</span>
        </span>
      </label>
    </li>
  `).join("") || "<li class='muted'>Sin tests con esos filtros.</li>";
  $("#bulk-counter").textContent =
    `${BULK.seleccion.size} / ${BULK.tests.length} seleccionados` +
    (filtrados.length !== BULK.tests.length ? ` · ${filtrados.length} visibles` : "");
}

$("#bulk-filter-nombre")?.addEventListener("input", pintarBulkTests);
$("#bulk-filter-etiqueta")?.addEventListener("change", pintarBulkTests);
$("#bulk-tests-list")?.addEventListener("change", (e) => {
  const cb = e.target.closest("input[type=checkbox][data-test-id]");
  if (!cb) return;
  if (cb.checked) BULK.seleccion.add(cb.dataset.testId);
  else            BULK.seleccion.delete(cb.dataset.testId);
  $("#bulk-counter").textContent = `${BULK.seleccion.size} / ${BULK.tests.length} seleccionados`;
});
$("#bulk-select-visible")?.addEventListener("click", () => {
  bulkFiltrar().forEach(t => BULK.seleccion.add(t.id));
  pintarBulkTests();
});
$("#bulk-clear-visible")?.addEventListener("click", () => {
  bulkFiltrar().forEach(t => BULK.seleccion.delete(t.id));
  pintarBulkTests();
});
// La X y el cierre por Esc/backdrop los gestiona <ap-modal closable>.
$("#modal-bulk-cancelar")?.addEventListener("click", () => $("#modal-bulk-tests").classList.add("hidden"));
$("#modal-bulk-guardar")?.addEventListener("click", async () => {
  if (!BULK.oposicion) return;
  try {
    await rpc("set_oposicion_tests", {
      p_oposicion_id: BULK.oposicion.id,
      p_test_ids: [...BULK.seleccion],
    });
    toast(`${BULK.seleccion.size} tests asignados a "${BULK.oposicion.nombre}"`);
    $("#modal-bulk-tests").classList.add("hidden");
    loadOposicionesAdmin();
  } catch (e) { toast(e.message); }
});

async function pintarPickerOposiciones(seleccionadas) {
  const ops = state.oposAdminCache && state.oposAdminCache.length
    ? state.oposAdminCache
    : await rpc("listar_oposiciones_admin").catch(() => []);
  const sel = new Set(seleccionadas || []);
  $("#modal-test-op-list").innerHTML = (ops || []).map(o => `
    <li>
      <label class="check-item">
        <input type="checkbox" data-op-id="${o.id}" ${sel.has(o.id) ? "checked" : ""}>
        <span><strong>${esc(o.nombre)}</strong>${o.descripcion ? `<br><span class="muted small">${esc(o.descripcion)}</span>` : ""}</span>
      </label>
    </li>
  `).join("") || "<p class='muted'>Sin oposiciones creadas.</p>";
}

/* ── Detalle del test: asignar oposiciones ───────────────────────────── */
$("#btn-test-oposiciones")?.addEventListener("click", async () => {
  if (!state.currentTestId) return;
  const modal = $("#modal-test-oposiciones");
  modal.querySelector("h3").textContent = "Oposiciones del test";
  try {
    const asignadas = await rpc("oposiciones_de_test", { p_test_id: state.currentTestId });
    await pintarPickerOposiciones((asignadas || []).map(o => o.id));
    modal.classList.remove("hidden");
  } catch (e) { toast(e.message); }
});
// La X y el cierre por Esc/backdrop los gestiona <ap-modal closable>.
$("#modal-test-op-cancelar")?.addEventListener("click", () => $("#modal-test-oposiciones").classList.add("hidden"));
$("#modal-test-op-guardar")?.addEventListener("click", async () => {
  const modal = $("#modal-test-oposiciones");
  const ids = $$("#modal-test-op-list input[type=checkbox]:checked").map(x => x.dataset.opId);
  try {
    await rpc("set_test_oposiciones", { p_test_id: state.currentTestId, p_oposicion_ids: ids });
    toast("Oposiciones del test actualizadas");
    modal.classList.add("hidden");
  } catch (e) { toast(e.message); }
});

/* ── Modal usuario: asignar OPOSICIONES directamente ─────────────────
 * Sustituye el flujo antiguo de "perfiles". Delegación desde el modal
 * de usuario existente. */
async function abrirOposicionesDeUsuario(usuarioId, nombreUsuario) {
  const modal = $("#modal-oposiciones-usuario");
  modal.dataset.usuarioId = usuarioId;
  $("#modal-op-usuario-titulo").textContent = `Oposiciones de ${nombreUsuario || "usuario"}`;
  try {
    const [todas, asignadas] = await Promise.all([
      rpc("listar_oposiciones_admin").catch(() => []),
      rpc("oposiciones_de_usuario", { p_usuario_id: usuarioId }).catch(() => []),
    ]);
    const sel = new Set((asignadas || []).map(x => x.id));
    $("#modal-op-usuario-list").innerHTML = (todas || []).map(o => `
      <li>
        <label class="check-item">
          <input type="checkbox" data-op-id="${o.id}" ${sel.has(o.id) ? "checked" : ""}>
          <span>
            <strong>${esc(o.nombre)}</strong>
            ${o.descripcion ? `<span class="muted small">${esc(o.descripcion)}</span>` : ""}
          </span>
        </label>
      </li>
    `).join("") || "<p class='muted'>No hay oposiciones creadas. Crea alguna primero.</p>";
    modal.classList.remove("hidden");
  } catch (e) { toast(e.message); }
}
// La X y el cierre por Esc/backdrop los gestiona <ap-modal closable>.
$("#modal-op-usuario-cancelar")?.addEventListener("click", () => $("#modal-oposiciones-usuario").classList.add("hidden"));
$("#modal-op-usuario-guardar")?.addEventListener("click", async () => {
  const modal = $("#modal-oposiciones-usuario");
  const ids = $$("#modal-op-usuario-list input[type=checkbox]:checked").map(x => x.dataset.opId);
  try {
    await rpc("set_usuario_oposiciones", { p_usuario_id: modal.dataset.usuarioId, p_oposicion_ids: ids });
    toast("Oposiciones asignadas");
    modal.classList.add("hidden");
  } catch (e) { toast(e.message); }
});
// Botón "Oposiciones" del modal usuario. El HTML del modal se rellena
// dinámicamente en renderUsuarios(), así que delegamos.
$("#modal-usuario-body")?.addEventListener("click", (e) => {
  const btn = e.target.closest("[data-action=oposiciones-usuario]");
  if (!btn) return;
  const uid = btn.dataset.usuarioId;
  const nombre = btn.dataset.usuarioNombre || "";
  abrirOposicionesDeUsuario(uid, nombre);
});


/* ─────────────────────────────────────────────────────────────────────────
 * Notificaciones Web Push
 *
 * Contrato con el backend:
 *   - push_config_publica()      → clave pública VAPID
 *   - guardar_push_suscripcion() → upsert de suscripción del navegador
 *   - borrar_push_suscripcion()  → al desactivar desde ajustes
 *
 * El motor de disparo vive fuera de la SPA (servicio 'notificador');
 * aquí solo suscribimos, mostramos estado y limpiamos.
 * ──────────────────────────────────────────────────────────────────────── */

function pushSoportado() {
  return "serviceWorker" in navigator &&
         "PushManager"    in window     &&
         "Notification"   in window;
}

// La suscripción y el toggle Activar/Desactivar los pinta shared/config.js.
// Aquí sólo mantenemos la sincronización silenciosa: si el navegador ya
// tenía una suscripción de una sesión anterior, la reenviamos al backend.
async function enviarSubAlBackend(sub) {
  const j = sub.toJSON();
  await rpc("guardar_push_suscripcion", {
    p_endpoint: j.endpoint,
    p_p256dh:   j.keys?.p256dh || "",
    p_auth:     j.keys?.auth   || "",
    p_ua:       navigator.userAgent,
    p_tz:       Intl.DateTimeFormat().resolvedOptions().timeZone || "Europe/Madrid",
  });
}

async function sincronizarPushSilencioso() {
  if (!pushSoportado()) return;
  if (Notification.permission !== "granted") return;
  try {
    const reg = await navigator.serviceWorker.ready;
    const sub = await reg.pushManager.getSubscription();
    if (sub) await enviarSubAlBackend(sub);
  } catch (_) { /* silencioso a propósito */ }
}

function atajoAVista(a) {
  return ({
    repasar:   "tests",     // la vista Tests trae el botón "Repasar todo"
    fallos:    "fallos",
    tests:     "tests",
    home:      "home",
    retos:     "retos",
    // Panel admin (accesible desde teoría vía /tests/?atajo=…): abrimos
    // la vista correspondiente y confiamos en que el guardia de rol de
    // cada vista bloquee al usuario que no le corresponda.
    usuarios:  "usuarios",
    etiquetas: "etiquetas",
    upload:    "upload",
    buscar:    "buscar",
    favoritas: "favoritas",
  })[a] || null;
}

// base64url → Uint8Array; el navegador exige la clave pública en ese formato.
function b64urlToBytes(s) {
  const pad = "=".repeat((4 - (s.length % 4)) % 4);
  const raw = atob((s + pad).replace(/-/g, "+").replace(/_/g, "/"));
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

// Helper de consola para pruebas manuales: window.__probarLogro()
window.__probarLogro = (n = 1) => notificarLogros(
  Array.from({ length: n }, (_, i) => ({
    titulo: `Logro de prueba ${i + 1}`, descripcion: "Simulación", icono: "🏆",
    xp: 100, objetivo: 1, progreso: 1,
  }))
);

// El service worker avisa cuando el navegador rota la suscripción para que
// re-registremos con las nuevas claves sin intervención del usuario.
if ("serviceWorker" in navigator) {
  navigator.serviceWorker.addEventListener("message", e => {
    if (e.data?.type === "PUSH_SUBSCRIPTION_CHANGE") sincronizarPushSilencioso();
  });
}

})();
