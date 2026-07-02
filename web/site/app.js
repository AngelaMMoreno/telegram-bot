/* ============================================================================
 * Aprentix · SPA contra PostgREST.  Sin Flask, sin adaptadores: el JS llama
 * directamente a /api/... (Caddy reenvía a PostgREST) y a /api/rpc/...
 * ========================================================================== */
(() => {
"use strict";

/* ── Sesión compartida (cookie en .aprentix.es) ─────────────────────────── */
const COOKIE_NAME = "aprentix_token";
const COOKIE_HORAS = 12;
const LANDING_URL = "https://aprentix.es";
const THEME_COOKIE = "aprentix_theme";

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
  searchAbort: null,
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

/* ── Llamada HTTP a PostgREST ────────────────────────────────────────────── */
async function pg(path, opts = {}) {
  const headers = { "Accept": "application/json" };
  if (opts.body !== undefined) headers["Content-Type"] = "application/json";
  if (state.jwt) headers["Authorization"] = "Bearer " + state.jwt;
  if (opts.headers) Object.assign(headers, opts.headers);

  const res = await fetch("/api" + path, {
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

async function refrescarUsuarioDesdeJwt() {
  // Cuando entramos con cookie válida pero sin user en localStorage (típico
  // tras hacer login en la landing y volver aquí), reconstruimos el user
  // consultando mi_sesion() de PostgREST.
  if (!state.jwt || state.user) return;
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

$("#btn-logout").addEventListener("click", () => logout());

/* ── Sidebar drawer (móvil) ── */
function setSidebar(open) {
  $("#sidebar").classList.toggle("open", open);
  $("#sidebar-backdrop").classList.toggle("hidden", !open);
}
$("#btn-menu").addEventListener("click", () => setSidebar(!$("#sidebar").classList.contains("open")));
$("#sidebar-backdrop").addEventListener("click", () => setSidebar(false));

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

/* ── Búsqueda global en topbar ───────────────────────────────────────────── */
const searchInput = $("#global-search");
const searchResults = $("#search-results");

let searchDebounce;
searchInput.addEventListener("input", e => {
  clearTimeout(searchDebounce);
  const q = e.target.value.trim();
  if (!q) { searchResults.classList.add("hidden"); return; }
  searchDebounce = setTimeout(() => doSearch(q), 220);
});

async function doSearch(q) {
  if (state.searchAbort) state.searchAbort.abort();
  state.searchAbort = new AbortController();
  try {
    const preguntas = await pg(`/rpc/buscar_preguntas`, {
      method: "POST", body: { p_q: q, p_lim: 6 }, signal: state.searchAbort.signal
    });
    const tests = await pg(
      `/tests?titulo=ilike.*${encodeURIComponent(q)}*&select=id,titulo&limit=4`,
      { signal: state.searchAbort.signal }
    );
    let html = "";
    if (tests.length) {
      html += `<div class="item label">TESTS</div>`;
      html += tests.map(t => `<div class="item" data-kind="test" data-id="${t.id}">${esc(t.titulo)}</div>`).join("");
    }
    if (preguntas.length) {
      html += `<div class="item label">PREGUNTAS</div>`;
      html += preguntas.map(p => `<div class="item" data-kind="preg" data-id="${p.id}">${esc(p.enunciado.slice(0,90))}…</div>`).join("");
    }
    if (!html) html = `<div class="item muted">Sin resultados</div>`;
    searchResults.innerHTML = html;
    searchResults.classList.remove("hidden");
  } catch (e) {
    if (e.name !== "AbortError") toast(e.message);
  }
}

searchResults.addEventListener("click", e => {
  const it = e.target.closest(".item[data-kind]");
  if (!it) return;
  searchResults.classList.add("hidden");
  searchInput.value = "";
  if (it.dataset.kind === "test") loadTestDetail(it.dataset.id);
  if (it.dataset.kind === "preg") {
    navigate("buscar");
    $("#buscar-input").value = it.textContent.replace(/…$/, "");
    runBuscarView(it.textContent.replace(/…$/, ""));
  }
});

document.addEventListener("click", e => {
  if (!searchResults.contains(e.target) && e.target !== searchInput)
    searchResults.classList.add("hidden");
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
  progreso:    loadProgreso,
};

/* ── Home ── */
async function loadHome() {
  const p = await rpc("mi_progreso");
  $("#stats-grid").innerHTML = `
    <div class="stat-card"><div class="v">${p.respondidas_hoy}</div><div class="l">Hoy</div></div>
    <div class="stat-card"><div class="v">${Number(p.nota_general).toFixed(1)}</div><div class="l">Nota</div></div>
    <div class="stat-card"><div class="v">${p.preguntas_falladas}</div><div class="l">Fallos</div></div>
    <div class="stat-card"><div class="v">${p.preguntas_favoritas}</div><div class="l">Favoritas</div></div>
  `;
}

/* ── Tests ── */
async function loadTests() {
  $("#tests-list").innerHTML = "<p class='muted'>Cargando…</p>";
  await ensureEtiquetasCache();
  renderTagChips("#tests-tag-chips", state.filtroEtiquetaTests, et => {
    state.filtroEtiquetaTests = et;
    state.testsPage = 1;
    loadTests();
  });
  const r = await rpc("listar_tests", {
    p_solo_favoritos:  state.filtroVisTests === "favoritos",
    p_solo_pendientes: state.filtroVisTests === "pendientes",
    p_page:            state.testsPage,
    p_size:            12,
    p_etiqueta:        state.filtroEtiquetaTests || null,
    p_orden:           state.ordenTests,
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
    </div>
  `).join("") || "<p class='muted'>Sin tests con estos filtros.</p>";
}

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

function renderTagChips(selector, valorActual, onClick) {
  const wrap = $(selector);
  if (!wrap) return;
  const opciones = [{ nombre: "Todas", _all: true }, ...state.etiquetasCache];
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
  const d = await rpc("obtener_preguntas_test", { p_test_id: testId });
  state.currentTestId = testId;
  $("#test-detail-title").textContent = d.quiz.title;
  $("#test-detail-meta").textContent = `${d.questions.length} preguntas`;
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

$("#test-detail-questions").addEventListener("click", e => {
  const btn = e.target.closest("[data-action=edit-q]");
  if (!btn) return;
  const li = e.target.closest("[data-pid]");
  const q = state.currentTest.questions.find(x => x.id === li.dataset.pid);
  if (q) abrirEditorPregunta(q);
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

$("#modal-close").addEventListener("click", cerrarModal);
$("#pq-cancelar").addEventListener("click", cerrarModal);

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
    await pg("/preguntas?id=eq." + state.editingQ.id, {
      method: "PATCH",
      headers: { "Prefer": "return=minimal" },
      body: {
        enunciado:   $("#pq-enunciado").value.trim(),
        opciones,
        explicacion: $("#pq-explicacion").value.trim() || null,
        etiquetas,
      },
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
  };
  state.qi = 0;
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

$("#modal-borrar-test-close").addEventListener("click", cerrarModalBorrarTest);
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
  };
  state.qi = 0;
  navigate("quiz");
  $("#quiz-title").textContent = title +
    (opts.adelantada ? "  ·  ⏩ adelantado" : "");
  renderPregunta();
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
  try {
    await rpc("toggle_favorita_pregunta", { p_pregunta_id: q.id });
    toast("Favorita actualizada");
  } catch (e) { toast(e.message); }
});

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
      await rpc("registrar_respuesta", {
        p_intento_id:  state.quiz.intentoId,
        p_pregunta_id: q.id,
        p_texto:       textoSel,
        p_correcta:    correcta,
        p_adelantada:  !!state.quiz.adelantada,
      });
    } catch (_) {}
  }
}

async function finalizarQuiz() {
  cancelarTimerQuiz();
  if (state.quiz.intentoId) {
    try { await rpc("finalizar_intento", { p_intento_id: state.quiz.intentoId }); }
    catch (_) {}
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
  await pg(`/preguntas?id=eq.${qId}`, {
    method: "PATCH",
    headers: { "Prefer": "return=minimal" },
    body: { etiquetas: nuevas },
  });
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


/* ── Progreso ── */
async function loadProgreso() {
  const p = await rpc("mi_progreso_detallado");
  $("#progreso-stats").innerHTML = `
    <div class="stat-card"><div class="v">${p.respondidas_hoy}</div><div class="l">Hoy</div></div>
    <div class="stat-card"><div class="v">${Number(p.nota_general).toFixed(2)}</div><div class="l">Nota</div></div>
    <div class="stat-card"><div class="v">${p.total_respondidas}</div><div class="l">Total respondidas</div></div>
    <div class="stat-card"><div class="v">${p.preguntas_falladas}</div><div class="l">Fallos pendientes</div></div>
  `;
  $("#progreso-por-test").innerHTML = (p.por_test || []).map(t => {
    const ult = t.intentos[t.intentos.length - 1];
    return `<li>
      <strong>${esc(t.titulo)}</strong>
      &nbsp;·&nbsp; ${t.intentos.length} intento(s)
      &nbsp;·&nbsp; última nota: <strong>${Number(ult?.nota || 0).toFixed(2)}</strong>
    </li>`;
  }).join("") || "<p class='muted'>Sin tests terminados aún.</p>";
}

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

$("#modal-usuario-close").addEventListener("click", cerrarModalUsuario);


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

const RITMO_LABELS = {
  intensivo: { emoji: "🔥", nombre: "Intensivo",
               desc: "Para semanas previas a examen. Verás preguntas nuevas varias veces el mismo día." },
  normal:    { emoji: "🎯", nombre: "Normal",
               desc: "Leitner clásico. Para aprendizaje continuo." },
  relajado:  { emoji: "🌱", nombre: "Relajado",
               desc: "Mantenimiento. Para no oxidarte cuando ya te sabes el temario." },
};

function fmtHoras(h) {
  if (h < 24) return h + " h";
  const d = Math.round(h / 24);
  if (d < 30) return d + " d";
  const m = Math.round(d / 30);
  return m + " mes" + (m > 1 ? "es" : "");
}

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
    $("#repaso-n-close").onclick         = null;
  };
  $("#btn-repaso-n-empezar").onclick = async () => {
    const n = Math.max(1, parseInt($("#repaso-n-n").value, 10) || 20);
    cerrar();
    await onEmpezar(n);
  };
  $("#btn-repaso-n-cancelar").onclick = cerrar;
  $("#repaso-n-close").onclick        = cerrar;
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
    $("#repaso-sv-close").onclick         = null;
  };
  $("#btn-repaso-sv-adelantar").onclick = async () => {
    const n = Math.max(1, parseInt($("#repaso-sv-n").value, 10) || 20);
    cerrar();
    await onAdelantar(n);
  };
  $("#btn-repaso-sv-cancelar").onclick = cerrar;
  $("#repaso-sv-close").onclick        = cerrar;
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

/* ── Tema (compartido en .aprentix.es) ────────────────────────────────── */
function currentTheme() {
  const c = getCookie(THEME_COOKIE);
  if (c === "dark" || c === "light" || c === "auto") return c;
  return "auto";
}
function effectiveTheme(t) {
  if (t === "auto") return matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  return t;
}
function applyTheme(t) {
  const eff = effectiveTheme(t);
  if (eff === "dark") document.documentElement.setAttribute("data-theme", "dark");
  else document.documentElement.removeAttribute("data-theme");
}
function setThemePref(t) {
  setCookie(THEME_COOKIE, t, 365 * 24);
  applyTheme(t);
}
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
  if (currentTheme() === "auto") applyTheme("auto");
});
applyTheme(currentTheme());

/* ── Configuración (apariencia + ritmo + reset) ───────────────────────── */
async function abrirModalConfig() {
  // Tema
  const t = currentTheme();
  $$('input[name="theme"]').forEach(r => { r.checked = (r.value === t); });
  // Ritmo
  await cargarRitmoOpcionesConfig();
  $("#modal-config").classList.remove("hidden");
}
function cerrarModalConfig() { $("#modal-config").classList.add("hidden"); }

async function cargarRitmoOpcionesConfig() {
  const cont = $("#ritmo-opciones");
  cont.innerHTML = "<p class='muted small'>Cargando…</p>";
  try {
    const d = await rpc("mi_ritmo_repaso");
    const actual = d.ritmo || "normal";
    const curvas = d.curvas || {};
    cont.innerHTML = ["intensivo", "normal", "relajado"].map(k => {
      const meta = RITMO_LABELS[k];
      const horas = curvas[k] || [];
      const preview = horas.map(fmtHoras).join(" → ");
      return `
        <div class="ritmo-card ${k===actual?"active":""}" data-ritmo="${k}">
          <div class="titulo">${meta.emoji} ${meta.nombre} ${k===actual?"<span class='muted small'>(actual)</span>":""}</div>
          <div class="muted small">${meta.desc}</div>
          <div class="curva">${esc(preview)}</div>
        </div>`;
    }).join("");
  } catch (e) {
    cont.innerHTML = `<p class='muted small'>No se pudo cargar el ritmo: ${esc(e.message)}</p>`;
  }
}

$("#btn-abrir-config")?.addEventListener("click", abrirModalConfig);
$("#btn-config")?.addEventListener("click", abrirModalConfig);
$("#btn-user-menu")?.addEventListener("click", abrirModalConfig);
$("#modal-config-close")?.addEventListener("click", cerrarModalConfig);
$("#btn-config-cerrar")?.addEventListener("click", cerrarModalConfig);
$("#modal-config")?.addEventListener("click", e => {
  if (e.target.id === "modal-config") cerrarModalConfig();
});

$$('input[name="theme"]').forEach(r => {
  r.addEventListener("change", () => {
    setThemePref(r.value);
    toast(`Modo ${r.value === "dark" ? "oscuro" : r.value === "light" ? "claro" : "automático"} activado`);
  });
});

$("#ritmo-opciones")?.addEventListener("click", async e => {
  const card = e.target.closest("[data-ritmo]");
  if (!card) return;
  try {
    await rpc("set_ritmo_repaso", { p_ritmo: card.dataset.ritmo });
    toast(`Ritmo cambiado a ${RITMO_LABELS[card.dataset.ritmo].nombre}`);
    cargarRitmoOpcionesConfig();
  } catch (err) { toast(err.message); }
});

/* ── Reset de repasos ───────────────────────────────────────────────────── */
$("#btn-resetear-repasos")?.addEventListener("click", () => {
  $("#modal-reset-repasos").classList.remove("hidden");
});
$("#btn-reset-cancelar")?.addEventListener("click", () => {
  $("#modal-reset-repasos").classList.add("hidden");
});
$("#btn-reset-confirmar")?.addEventListener("click", async (e) => {
  const btn = e.currentTarget;
  btn.disabled = true;
  try {
    const r = await rpc("resetear_mis_repasos", { p_test_id: null });
    const n = r && typeof r.borradas === "number" ? r.borradas : 0;
    toast(n === 0
      ? "No había repasos que borrar"
      : `Repaso reseteado (${n} pregunta${n === 1 ? "" : "s"})`);
    $("#modal-reset-repasos").classList.add("hidden");
    $("#modal-config").classList.add("hidden");
    // Refresca la home si estamos ahí para que se actualicen los contadores.
    if ($("#view-home")?.classList.contains("active")) {
      navigate("home");
    }
  } catch (err) {
    toast(err.message);
  } finally {
    btn.disabled = false;
  }
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
  navigate(state.jwt && state.user ? "home" : "login");
})();

})();
