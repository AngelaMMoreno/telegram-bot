/* ============================================================================
 * Aprentix · SPA contra PostgREST.  Sin Flask, sin adaptadores: el JS llama
 * directamente a /api/... (Caddy reenvía a PostgREST) y a /api/rpc/...
 * ========================================================================== */
(() => {
"use strict";

/* ── Estado global ───────────────────────────────────────────────────────── */
const state = {
  jwt:       localStorage.getItem("jwt") || null,
  user:      JSON.parse(localStorage.getItem("user") || "null"),
  quiz:      null,
  qi:        0,
  testsPage: 1,
  testsCache: [],
  filtroTests: "",
  filtroEtiquetaTests: null,
  filtroEtiquetaBuscar: null,
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
  if (state.jwt) localStorage.setItem("jwt", state.jwt);
  else localStorage.removeItem("jwt");
  if (state.user) localStorage.setItem("user", JSON.stringify(state.user));
  else localStorage.removeItem("user");
}

function applySession() {
  const logged = !!state.jwt && !!state.user;
  $("#topbar").classList.toggle("hidden", !logged);
  $("#sidebar").classList.toggle("hidden", !logged);
  document.body.classList.toggle("puede-gestionar", !!(state.user && state.user.puede_gestionar));
  if (logged) {
    const u = state.user.username || "";
    $("#user-name").textContent = u;
    $("#user-avatar").textContent = (u.trim()[0] || "?").toUpperCase();
    $("#hello-name").textContent = u;
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
  if (navigateAway) navigate("login");
}

/* ── Navegación ──────────────────────────────────────────────────────────── */
function navigate(view) {
  $$(".view").forEach(v => v.classList.remove("active"));
  const el = $("#view-" + view);
  if (el) el.classList.add("active");
  $$(".nav-item").forEach(b => b.classList.toggle("active", b.dataset.view === view));
  $("#sidebar").classList.remove("open");
  if (view !== "login" && (!state.jwt || !state.user)) { navigate("login"); return; }
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
    p_solo_favoritos: false,
    p_page: state.testsPage, p_size: 12,
    p_etiqueta: state.filtroEtiquetaTests || null,
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
      <span class="titulo">${esc(t.title)}</span>
      <span class="tags">${(t.etiquetas||[]).map(e => `<span class="tag">${esc(e)}</span>`).join("")}</span>
      <span class="meta">${t.num_preguntas} preguntas</span>
    </div>
  `).join("") || "<p class='muted'>Sin tests.</p>";
}

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
function abrirEditorPregunta(q, opciones = {}) {
  const text   = q.text   ?? q.enunciado ?? "";
  const optsIn = q.options ?? (q.opciones || []).map(o => ({ text: o.texto, isCorrect: !!o.correcta }));
  const expl   = q.explicacion ?? "";
  const tags   = q.etiquetas ?? [];

  state.editingQ = { id: q.id, refrescar: opciones.refrescar || null };
  $("#pq-enunciado").value = text;
  $("#pq-opciones").value  = optsIn
    .map(o => (o.isCorrect ? "*" : "") + o.text)
    .join("\n");
  $("#pq-explicacion").value = expl || "";
  $("#pq-etiquetas").value   = (tags || []).join(", ");
  $("#modal-pregunta").classList.remove("hidden");
}

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

  const etiquetas = $("#pq-etiquetas").value.split(",")
    .map(t => t.trim().toLowerCase()).filter(t => t.length);

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

$("#btn-start-test").addEventListener("click", () => {
  if (!state.currentTest) return;
  startQuiz(state.currentTest.quiz.title, state.currentTestId, state.currentTest.questions, "quiz");
});

$("#btn-delete-test").addEventListener("click", async () => {
  if (!state.currentTestId) return;
  if (!confirm("¿Borrar este test? La acción no se puede deshacer.")) return;
  try {
    await pg("/tests?id=eq." + state.currentTestId, { method: "DELETE" });
    toast("Test borrado"); navigate("tests");
  } catch (e) { toast(e.message); }
});

/* ── Quiz engine ── */
function startQuiz(title, testId, questions, tipo = "quiz") {
  // Baraja las preguntas y las opciones de cada una
  const shuffled = [...questions].sort(() => Math.random() - 0.5).map(q => {
    const opts = q.options.map((o, i) => ({ ...o, origIdx: i }));
    opts.sort(() => Math.random() - 0.5);
    return { ...q, options: opts };
  });
  state.quiz = {
    title, testId, tipo,
    questions: shuffled,
    correct: 0, wrong: 0, blank: 0,
    answered: false,
    intentoId: null,
    tiempoPorPregunta: getTiempo(),
  };
  state.qi = 0;

  rpc("iniciar_intento", {
    p_test_id:      testId || null,
    p_tipo:         tipo,
    p_nombre:       title,
    p_question_ids: shuffled.map(q => q.id),
  }).then(r => { state.quiz.intentoId = r.attempt_id; }).catch(e => toast(e.message));

  navigate("quiz");
  $("#quiz-title").textContent = title;
  renderPregunta();
}

function renderPregunta() {
  const q = state.quiz.questions[state.qi];
  state.quiz.answered = false;
  $("#quiz-progress").textContent = `${state.qi + 1} / ${state.quiz.questions.length}`;
  $("#quiz-question").textContent = q.text;
  $("#quiz-explanation").classList.add("hidden");
  $("#btn-next").classList.add("hidden");
  $("#btn-edit-q").classList.add("hidden");
  $("#quiz-options").innerHTML = q.options.map((o, i) => `
    <button class="option-btn" data-i="${i}">${esc(o.text)}</button>
  `).join("");

  // Temporizador configurable (se fija al iniciar el test, no cambia entre preguntas).
  let t = state.quiz.tiempoPorPregunta || 20;
  $("#quiz-timer").textContent = t + "s";
  clearInterval(state.quiz._timer);
  state.quiz._timer = setInterval(() => {
    t--;
    $("#quiz-timer").textContent = t + "s";
    if (t <= 0) { clearInterval(state.quiz._timer); responder(null); }
  }, 1000);
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
  clearInterval(state.quiz._timer);

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

  if (state.quiz.intentoId) {
    try {
      await rpc("registrar_respuesta", {
        p_intento_id:  state.quiz.intentoId,
        p_pregunta_id: q.id,
        p_texto:       textoSel,
        p_correcta:    correcta,
      });
    } catch (_) {}
  }
}

async function finalizarQuiz() {
  if (state.quiz.intentoId) {
    try { await rpc("finalizar_intento", { p_intento_id: state.quiz.intentoId }); }
    catch (_) {}
  }
  const total = state.quiz.questions.length;
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
    <li class="q-row">
      <div class="q-text">${esc(q.text)}</div>
      <div class="q-meta">Fallada ${q.veces_fallada} veces</div>
      <div class="tags">${(q.etiquetas||[]).map(t => `<span class="tag">${esc(t)}</span>`).join("")}</div>
    </li>
  `).join("") || "<p class='muted'>Sin fallos aún.</p>";
  state.lastFallos = d.questions || [];
}

$("#btn-start-fallos").addEventListener("click", () => {
  if (!state.lastFallos || !state.lastFallos.length)
    return toast("No tienes fallos");
  startQuiz("Test de fallos", null, state.lastFallos, "test_fallos");
});

async function loadFavoritas() {
  $("#list-fav").innerHTML = "<p class='muted'>Cargando…</p>";
  const d = await rpc("mis_favoritas");
  $("#list-fav").innerHTML = (d.questions || []).map(q => `
    <li class="q-row">
      <div class="q-text">${esc(q.text)}</div>
      <div class="tags">${(q.etiquetas||[]).map(t => `<span class="tag">${esc(t)}</span>`).join("")}</div>
    </li>
  `).join("") || "<p class='muted'>Aún no marcaste favoritas.</p>";
  state.lastFav = d.questions || [];
}

$("#btn-start-fav").addEventListener("click", () => {
  if (!state.lastFav || !state.lastFav.length) return toast("Sin favoritas");
  startQuiz("Test de favoritas", null, state.lastFav, "test_favoritas");
});

/* ── Buscador (vista) ── */
$("#buscar-input").addEventListener("input", e => {
  clearTimeout(state._buscarDebounce);
  state._buscarDebounce = setTimeout(() => runBuscarView(e.target.value.trim()), 250);
});

async function runBuscarView(q) {
  await ensureEtiquetasCache();
  renderTagChips("#buscar-tag-chips", state.filtroEtiquetaBuscar, et => {
    state.filtroEtiquetaBuscar = et;
    runBuscarView($("#buscar-input").value.trim());
  });
  if (!q && !state.filtroEtiquetaBuscar) { $("#buscar-results").innerHTML = ""; return; }
  $("#buscar-results").innerHTML = "<p class='muted'>Buscando…</p>";
  try {
    const r = await rpc("buscar_preguntas", {
      p_q: q || "", p_lim: 40,
      p_etiqueta: state.filtroEtiquetaBuscar || null,
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
  $("#etiquetas-list").innerHTML = tags.map(t => `
    <li class="etiqueta-row" data-nombre="${esc(t.nombre)}">
      <span class="dot ${t.vectorizada ? "ok" : ""}" title="${t.vectorizada ? "Vectorizada" : "Pendiente"}"></span>
      <div style="flex:1">
        <div class="nombre">${esc(t.nombre)}</div>
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
    });
    $("#et-nombre").value = ""; $("#et-descripcion").value = ""; $("#et-palabras").value = "";
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

/* ── Arranque ───────────────────────────────────────────────────────────── */
inicializarInputsTiempo();
applySession();
navigate(state.jwt && state.user ? "home" : "login");

})();
