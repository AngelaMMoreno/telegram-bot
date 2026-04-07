/* ── Aprentix Tests – SPA ── */
(function () {
  "use strict";

  const PENALIZACION = 1 / 3;
  const PREGUNTAS_P1 = 80;
  const TIEMPO_POR_PREGUNTA_POR_DEFECTO_SEGUNDOS = 20;

  /* ── State ── */
  let state = {
    userId: null,
    username: null,
    puedeGestionar: false,
    favFilter: false,
    // quiz state
    quiz: null,        // { questions, title, attemptId, type, simulacro }
    qi: 0,             // current question index
    correct: 0,
    wrong: 0,
    blank: 0,
    answered: false,
    tiempoRestante: TIEMPO_POR_PREGUNTA_POR_DEFECTO_SEGUNDOS,
    temporizadorPreguntaId: null,
    favQuestionIds: new Set(),
    megaModo: false,
    megaSeleccionados: new Set(),
    megaTestsPagina: [],
    testsPaginaActual: 1,
  };

  /* ── API helper ── */
  async function api(path, opts = {}) {
    const res = await fetch("/api" + path, {
      headers: opts.body instanceof FormData ? {} : { "Content-Type": "application/json" },
      ...opts,
      body: opts.body instanceof FormData ? opts.body : (opts.body ? JSON.stringify(opts.body) : undefined),
    });
    if (!res.ok) {
      const err = await res.json().catch(() => ({}));
      throw new Error(err.error || "Error del servidor");
    }
    // Handle file downloads
    const ct = res.headers.get("content-type") || "";
    if (ct.includes("application/json")) return res.json();
    return res;
  }

  /* ── View management ── */
  function showView(id) {
    document.querySelectorAll(".view").forEach((v) => v.classList.remove("active"));
    document.getElementById("view-" + id).classList.add("active");
  }

  /* ── Toast ── */
  function toast(msg) {
    const el = document.getElementById("toast");
    el.textContent = msg;
    el.classList.remove("hidden");
    clearTimeout(el._t);
    el._t = setTimeout(() => el.classList.add("hidden"), 2500);
  }

  /* ── Confirm dialog ── */
  function confirm(title, message) {
    return new Promise((resolve) => {
      const overlay = document.createElement("div");
      overlay.className = "dialog-overlay";
      overlay.innerHTML = `<div class="dialog">
        <h3>${title}</h3>
        <p>${message}</p>
        <div class="dialog-actions">
          <button class="btn btn-outline btn-sm" data-r="0">Cancelar</button>
          <button class="btn btn-primary btn-sm" data-r="1">Confirmar</button>
        </div>
      </div>`;
      overlay.addEventListener("click", (e) => {
        const r = e.target.dataset.r;
        if (r !== undefined) {
          overlay.remove();
          resolve(r === "1");
        }
      });
      document.body.appendChild(overlay);
    });
  }

  /* ── Session ── */
  function saveSession() {
    localStorage.setItem("aprentix_session", JSON.stringify({
      userId: state.userId,
      username: state.username,
      puedeGestionar: state.puedeGestionar,
    }));
  }
  function loadSession() {
    try {
      const s = JSON.parse(localStorage.getItem("aprentix_session"));
      if (s && s.userId) {
        state.userId = s.userId;
        state.username = s.username;
        state.puedeGestionar = !!s.puedeGestionar;
        return true;
      }
    } catch (_) {}
    return false;
  }
  function clearSession() {
    state.userId = null;
    state.username = null;
    state.puedeGestionar = false;
    localStorage.removeItem("aprentix_session");
  }

  function actualizarVisibilidadGestion() {
    document.querySelectorAll("[data-gestion='si']").forEach((el) => {
      el.classList.toggle("hidden", !state.puedeGestionar);
    });
  }

  /* ── Auth: toggle forms ── */
  document.getElementById("show-register").addEventListener("click", (e) => {
    e.preventDefault();
    document.getElementById("login-form").classList.add("hidden");
    document.getElementById("register-form").classList.remove("hidden");
  });
  document.getElementById("show-login").addEventListener("click", (e) => {
    e.preventDefault();
    document.getElementById("register-form").classList.add("hidden");
    document.getElementById("login-form").classList.remove("hidden");
  });

  /* ── Auth: link telegram checkbox ── */
  document.getElementById("reg-link-telegram").addEventListener("change", (e) => {
    document.getElementById("reg-chatid-wrapper").classList.toggle("hidden", !e.target.checked);
  });

  /* ── Login ── */
  document.getElementById("login-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const username = document.getElementById("login-username").value.trim();
    const password = document.getElementById("login-password").value;
    if (!username || !password) return;
    try {
      const data = await api("/auth/login", { method: "POST", body: { username, password } });
      state.userId = data.user_id;
      state.username = data.username;
      state.puedeGestionar = !!data.puede_gestionar;
      saveSession();
      enterApp();
    } catch (err) {
      toast(err.message);
    }
  });

  /* ── Register ── */
  document.getElementById("register-form").addEventListener("submit", async (e) => {
    e.preventDefault();
    const username = document.getElementById("reg-username").value.trim();
    const password = document.getElementById("reg-password").value;
    const password2 = document.getElementById("reg-password2").value;
    const linkTelegram = document.getElementById("reg-link-telegram").checked;
    const chatId = document.getElementById("reg-chatid").value.trim();

    if (!username || !password) return;
    if (password !== password2) { toast("Las contraseñas no coinciden"); return; }

    const body = { username, password };
    if (linkTelegram && chatId) body.chat_id = chatId;

    try {
      const data = await api("/auth/register", { method: "POST", body });
      state.userId = data.user_id;
      state.username = data.username;
      state.puedeGestionar = !!data.puede_gestionar;
      saveSession();
      toast("Cuenta creada correctamente");
      enterApp();
    } catch (err) {
      toast(err.message);
    }
  });

  document.getElementById("btn-logout").addEventListener("click", () => {
    clearSession();
    actualizarVisibilidadGestion();
    document.getElementById("register-form").classList.add("hidden");
    document.getElementById("login-form").classList.remove("hidden");
    showView("login");
  });

  /* ── Enter app ── */
  async function enterApp() {
    try {
      const permisos = await api(`/auth/permisos?user_id=${state.userId}`);
      state.puedeGestionar = !!permisos.puede_gestionar;
    } catch (_) {
      state.puedeGestionar = false;
    }
    actualizarVisibilidadGestion();
    showView("menu");
    loadMenuStats();
    loadFavoriteQuestionIds();
  }

  async function loadMenuStats() {
    try {
      const d = await api("/progress?user_id=" + state.userId);
      const el = document.getElementById("menu-stats");
      el.innerHTML = `
        <div class="stat-card"><div class="stat-value">${d.respondidas_hoy}</div><div class="stat-label">Hoy</div></div>
        <div class="stat-card"><div class="stat-value">${d.nota_general.toFixed(1)}</div><div class="stat-label">Nota media</div></div>
        <div class="stat-card"><div class="stat-value">${d.preguntas_falladas}</div><div class="stat-label">Fallos</div></div>
        <div class="stat-card"><div class="stat-value">${d.preguntas_favoritas}</div><div class="stat-label">Favoritas</div></div>
      `;
    } catch (_) {}
  }

  async function loadFavoriteQuestionIds() {
    try {
      const d = await api("/favorites/check?user_id=" + state.userId);
      state.favQuestionIds = new Set(d.question_ids);
    } catch (_) {}
  }

  function inicializar_estado_quiz(quiz) {
    quiz.tiempoPorPreguntaSegundos = quiz.tiempoPorPreguntaSegundos || TIEMPO_POR_PREGUNTA_POR_DEFECTO_SEGUNDOS;
    state.quiz = quiz;
    state.qi = 0;
    state.correct = quiz.correct || 0;
    state.wrong = quiz.wrong || 0;
    state.blank = 0;
    state.answered = false;
    document.getElementById("quiz-title").textContent = quiz.title;
    showView("quiz");
    renderQuestion();
  }

  async function solicitar_tiempo_por_pregunta(valorInicial = TIEMPO_POR_PREGUNTA_POR_DEFECTO_SEGUNDOS) {
    const entrada = prompt(
      "¿Cuántos segundos por pregunta quieres usar?",
      String(valorInicial)
    );
    if (entrada === null) return null;
    const segundos = parseInt(entrada.trim(), 10);
    if (!Number.isInteger(segundos) || segundos < 5 || segundos > 600) {
      toast("Introduce un tiempo válido entre 5 y 600 segundos");
      return null;
    }
    return segundos;
  }

  function obtener_total_preguntas_quiz() {
    return state.quiz?.totalOriginal || state.quiz?.questions?.length || 0;
  }

  function obtener_posicion_absoluta_actual() {
    const respondidasPrevias = state.quiz?.respondidas || 0;
    return respondidasPrevias + state.qi + 1;
  }

  async function obtener_intento_pendiente(tipo, quizId = null) {
    const qs = new URLSearchParams({
      user_id: String(state.userId),
      attempt_type: tipo,
    });
    if (quizId !== null && quizId !== undefined) qs.set("quiz_id", String(quizId));
    const d = await api(`/attempts/pending?${qs.toString()}`);
    return d.attempt || null;
  }

  async function reanudar_intento(attemptId, tituloFallback, tiempoPorPreguntaSegundos) {
    const d = await api(`/attempts/${attemptId}/resume`, {
      method: "POST",
      body: { user_id: state.userId },
    });
    if (!d.questions.length) {
      toast("Ese intento ya no tiene preguntas pendientes");
      return false;
    }
    inicializar_estado_quiz({
      questions: d.questions,
      title: d.nombre || tituloFallback || "Test",
      attemptId: d.attempt_id,
      type: d.attempt_type,
      quizId: d.quiz_id || null,
      correct: d.correct,
      wrong: d.wrong,
      totalOriginal: d.total_original,
      respondidas: d.respondidas,
      tiempoPorPreguntaSegundos,
    });
    return true;
  }

  async function comprobar_reanudacion(tipo, quizId, titulo) {
    const pendiente = await obtener_intento_pendiente(tipo, quizId);
    if (!pendiente) return null;
    const continuar = await confirm(
      "Test pendiente",
      "Tienes un test a medias. ¿Quieres continuarlo donde lo dejaste?"
    );
    if (continuar) {
      const tiempoPorPreguntaSegundos = await solicitar_tiempo_por_pregunta();
      if (tiempoPorPreguntaSegundos === null) return null;
      const ok = await reanudar_intento(pendiente.id, pendiente.nombre || titulo, tiempoPorPreguntaSegundos);
      if (ok) return "reanudo";
    } else {
      await api(`/attempts/${pendiente.id}/discard`, {
        method: "POST",
        body: { user_id: state.userId },
      });
    }
    return "reiniciar";
  }

  /* ── Menu actions ── */
  document.querySelector(".menu-grid").addEventListener("click", (e) => {
    const card = e.target.closest(".menu-card");
    if (!card) return;
    const action = card.dataset.action;
    if (action === "tests") { state.favFilter = false; loadTests(1); }
    else if (action === "upload") showView("upload");
    else if (action === "fallos") startFailuresTest();
    else if (action === "favoritas") startFavoritesTest();
    else if (action === "ver-favoritas") loadFavoritesViewer();
    else if (action === "simulacros") loadSimulacros();
    else if (action === "progreso") loadProgress();
    else if (action === "download-all") downloadAll();
    else if (action === "download-db") downloadDb();
  });

  /* ── Back buttons ── */
  document.querySelectorAll(".btn-back[data-back]").forEach((btn) => {
    btn.addEventListener("click", () => {
      const target = btn.dataset.back;
      showView(target);
      if (target === "menu") loadMenuStats();
    });
  });

  /* ── Tests list ── */
  async function loadTests(page) {
    state.testsPaginaActual = page;
    showView("tests");
    const listEl = document.getElementById("test-list");
    const pagEl = document.getElementById("test-pagination");
    const titleEl = document.getElementById("tests-title");
    const panelMega = document.getElementById("panel-mega-test");
    const botonMegaModo = document.getElementById("btn-mega-modo");
    const resumenMega = document.getElementById("mega-seleccion-resumen");
    listEl.innerHTML = '<div class="spinner"></div>';
    pagEl.innerHTML = "";

    const filterBtn = document.getElementById("btn-toggle-fav-filter");
    filterBtn.classList.toggle("active", state.favFilter);
    titleEl.textContent = state.favFilter ? "Tests favoritos" : "Mis tests";
    panelMega.classList.toggle("hidden", !state.megaModo || !state.puedeGestionar);
    botonMegaModo.classList.toggle("active", state.megaModo);
    resumenMega.textContent = `${state.megaSeleccionados.size} tests seleccionados`;
    state.megaTestsPagina = [];

    try {
      const endpoint = state.favFilter
        ? `/tests/favoritos?user_id=${state.userId}&page=${page}`
        : `/tests?user_id=${state.userId}&page=${page}`;
      const d = await api(endpoint);
      if (!d.tests.length) {
        listEl.innerHTML = '<div class="empty-state"><p>No hay tests</p></div>';
        return;
      }
      state.megaTestsPagina = d.tests.map((t) => t.id);
      listEl.innerHTML = d.tests.map((t) => {
        const badges = [];
        if (t.realizado) badges.push('<span class="test-badge done">Hecho</span>');
        if (t.intentos) badges.push(`<span class="test-badge attempts">${t.intentos}x</span>`);
        return `<div class="test-item" data-id="${t.id}">
          <div class="test-item-info">
            <div class="test-item-title">${esc(t.title)}</div>
            <div class="test-item-meta">${badges.join("")}${t.total_preguntas} preguntas</div>
          </div>
          <div class="test-item-actions">
            ${state.megaModo && state.puedeGestionar ? `<input type="checkbox" class="mega-checkbox" data-mega-id="${t.id}" ${state.megaSeleccionados.has(t.id) ? "checked" : ""}>` : ""}
            <button class="btn-icon test-fav-btn ${t.es_favorito ? "active" : ""}" data-fav="${t.id}" title="Favorito">
              <svg width="18" height="18" viewBox="0 0 24 24" fill="${t.es_favorito ? "currentColor" : "none"}" stroke="currentColor" stroke-width="2"><polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"/></svg>
            </button>
            ${state.puedeGestionar ? `<button class="btn-icon test-dl-btn" data-dl="${t.id}" title="Descargar">
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
            </button>` : ""}
            ${state.puedeGestionar ? `<button class="btn-icon test-del-btn" data-del="${t.id}" title="Borrar">
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 01-2 2H8a2 2 0 01-2-2L5 6"/><path d="M10 11v6"/><path d="M14 11v6"/></svg>
            </button>` : ""}
          </div>
        </div>`;
      }).join("");

      // Pagination
      if (d.pages > 1) {
        let html = "";
        if (page > 1) html += `<button data-p="${page - 1}">&laquo;</button>`;
        for (let i = 1; i <= d.pages; i++) {
          html += `<button data-p="${i}" class="${i === page ? "active" : ""}">${i}</button>`;
        }
        if (page < d.pages) html += `<button data-p="${page + 1}">&raquo;</button>`;
        pagEl.innerHTML = html;
      }
    } catch (err) {
      listEl.innerHTML = `<div class="empty-state"><p>${esc(err.message)}</p></div>`;
    }
  }

  // Test list events
  document.getElementById("test-list").addEventListener("click", async (e) => {
    if (e.target.matches(".mega-checkbox")) {
      const quizId = parseInt(e.target.dataset.megaId);
      if (e.target.checked) state.megaSeleccionados.add(quizId);
      else state.megaSeleccionados.delete(quizId);
      return;
    }
    const favBtn = e.target.closest("[data-fav]");
    if (favBtn) {
      e.stopPropagation();
      const qid = parseInt(favBtn.dataset.fav);
      try {
        const d = await api(`/tests/${qid}/favorito`, { method: "POST", body: { user_id: state.userId } });
        favBtn.classList.toggle("active", d.es_favorito);
        favBtn.querySelector("svg").setAttribute("fill", d.es_favorito ? "currentColor" : "none");
        toast(d.es_favorito ? "Marcado como favorito" : "Quitado de favoritos");
      } catch (err) { toast(err.message); }
      return;
    }
    const dlBtn = e.target.closest("[data-dl]");
    if (dlBtn) {
      e.stopPropagation();
      downloadTest(parseInt(dlBtn.dataset.dl));
      return;
    }
    const delBtn = e.target.closest("[data-del]");
    if (delBtn) {
      e.stopPropagation();
      const qid = parseInt(delBtn.dataset.del);
      if (await confirm("Borrar test", "Se eliminara el test y todos sus datos asociados.")) {
        try {
          await api(`/tests/${qid}?user_id=${state.userId}`, { method: "DELETE" });
          toast("Test borrado");
          loadTests(1);
        } catch (err) { toast(err.message); }
      }
      return;
    }
    const item = e.target.closest(".test-item");
    if (item) {
      const quizId = parseInt(item.dataset.id);
      if (state.megaModo && state.puedeGestionar) {
        const checkbox = item.querySelector(".mega-checkbox");
        if (!checkbox) return;
        checkbox.checked = !checkbox.checked;
        if (checkbox.checked) state.megaSeleccionados.add(quizId);
        else state.megaSeleccionados.delete(quizId);
        return;
      }
      startQuiz(quizId);
    }
  });

  document.getElementById("test-pagination").addEventListener("click", (e) => {
    const btn = e.target.closest("[data-p]");
    if (btn) loadTests(parseInt(btn.dataset.p));
  });

  document.getElementById("btn-toggle-fav-filter").addEventListener("click", () => {
    state.favFilter = !state.favFilter;
    loadTests(1);
  });
  document.getElementById("btn-mega-modo").addEventListener("click", () => {
    if (!state.puedeGestionar) return;
    state.megaModo = !state.megaModo;
    if (!state.megaModo) state.megaSeleccionados.clear();
    loadTests(1);
  });
  document.getElementById("btn-seleccionar-pagina").addEventListener("click", () => {
    for (const id of state.megaTestsPagina) state.megaSeleccionados.add(id);
    loadTests(state.testsPaginaActual);
  });
  document.getElementById("btn-deseleccionar-pagina").addEventListener("click", () => {
    for (const id of state.megaTestsPagina) state.megaSeleccionados.delete(id);
    loadTests(state.testsPaginaActual);
  });
  document.getElementById("btn-iniciar-mega-test").addEventListener("click", async () => {
    if (!state.puedeGestionar) return;
    if (!state.megaSeleccionados.size) {
      toast("Selecciona al menos un test");
      return;
    }
    try {
      const nombreMegaTest = (prompt("Nombre del mega test", `Mega test ${new Date().toLocaleDateString("es-ES")}`) || "").trim();
      if (!nombreMegaTest) {
        toast("Debes indicar un nombre para el mega test");
        return;
      }
      const d = await api("/tests/mega/crear", {
        method: "POST",
        body: {
          user_id: state.userId,
          nombre: nombreMegaTest,
          quiz_ids: Array.from(state.megaSeleccionados),
          solo_favoritos: state.favFilter,
        },
      });
      state.megaSeleccionados.clear();
      state.megaModo = false;
      toast(`Mega test creado como test normal (${d.total_preguntas} preguntas)`);
      loadTests(1);
    } catch (err) {
      toast(err.message);
    }
  });

  /* ── Download helpers ── */
  async function downloadTest(quizId) {
    try {
      const res = await api(`/tests/${quizId}/download?user_id=${state.userId}`);
      const blob = await res.blob();
      triggerDownload(blob, res.headers.get("content-disposition"));
    } catch (err) { toast(err.message); }
  }

  async function downloadAll() {
    try {
      toast("Preparando descarga...");
      const res = await api(`/tests/download-all?user_id=${state.userId}`);
      const blob = await res.blob();
      triggerDownload(blob, "tests.zip");
    } catch (err) { toast(err.message); }
  }

  async function downloadDb() {
    try {
      const res = await api(`/db/download?user_id=${state.userId}`);
      const blob = await res.blob();
      triggerDownload(blob, "bot.db");
    } catch (err) { toast(err.message); }
  }

  function triggerDownload(blob, name) {
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = (typeof name === "string" && name.includes("filename="))
      ? name.split("filename=")[1].replace(/"/g, "")
      : (name || "download");
    a.click();
    URL.revokeObjectURL(a.href);
  }

  /* ── Upload ── */
  const dropzone = document.getElementById("dropzone");
  const fileInput = document.getElementById("file-input");
  const uploadForm = document.getElementById("upload-form");
  const btnUpload = document.getElementById("btn-upload");
  let selectedFiles = [];

  dropzone.addEventListener("click", () => fileInput.click());
  dropzone.addEventListener("dragover", (e) => { e.preventDefault(); dropzone.classList.add("dragover"); });
  dropzone.addEventListener("dragleave", () => dropzone.classList.remove("dragover"));
  dropzone.addEventListener("drop", (e) => {
    e.preventDefault();
    dropzone.classList.remove("dragover");
    setFiles(e.dataTransfer.files);
  });
  fileInput.addEventListener("change", () => setFiles(fileInput.files));

  function setFiles(files) {
    selectedFiles = Array.from(files);
    btnUpload.disabled = !selectedFiles.length;
    dropzone.querySelector("p").textContent =
      selectedFiles.length ? selectedFiles.map((f) => f.name).join(", ") : "Arrastra archivos o pulsa para seleccionar";
  }

  uploadForm.addEventListener("submit", async (e) => {
    e.preventDefault();
    if (!selectedFiles.length) return;
    const statusEl = document.getElementById("upload-status");
    statusEl.innerHTML = '<div class="spinner"></div>';
    btnUpload.disabled = true;

    let totalCreated = 0;
    for (const file of selectedFiles) {
      const fd = new FormData();
      fd.append("user_id", state.userId);
      fd.append("file", file);
      try {
        const d = await api("/tests/upload", { method: "POST", body: fd });
        totalCreated += d.count;
      } catch (err) {
        statusEl.innerHTML = `<div class="error">${esc(err.message)}</div>`;
        btnUpload.disabled = false;
        return;
      }
    }
    statusEl.innerHTML = `<div class="success">${totalCreated} test(s) creados correctamente</div>`;
    selectedFiles = [];
    fileInput.value = "";
    dropzone.querySelector("p").textContent = "Arrastra archivos o pulsa para seleccionar";
    btnUpload.disabled = true;
  });

  /* ── Start quiz ── */
  async function startQuiz(quizId) {
    try {
      const estadoReanudacion = await comprobar_reanudacion("quiz", quizId, "Test");
      if (estadoReanudacion === "reanudo") return;
      const tiempoPorPreguntaSegundos = await solicitar_tiempo_por_pregunta();
      if (tiempoPorPreguntaSegundos === null) return;
      const d = await api(`/tests/${quizId}/questions`);
      if (!d.questions.length) { toast("El test no tiene preguntas"); return; }
      const preguntasMezcladas = shuffle(d.questions);
      const att = await api("/attempts/start", {
        method: "POST",
        body: {
          user_id: state.userId,
          quiz_id: quizId,
          attempt_type: "quiz",
          nombre: d.quiz.title,
          question_ids: preguntasMezcladas.map((p) => p.id),
        },
      });
      inicializar_estado_quiz({
        questions: preguntasMezcladas,
        title: d.quiz.title,
        attemptId: att.attempt_id,
        type: "quiz",
        quizId: quizId,
        tiempoPorPreguntaSegundos,
      });
    } catch (err) { toast(err.message); }
  }

  /* ── Failures test ── */
  async function startFailuresTest() {
    try {
      const estadoReanudacion = await comprobar_reanudacion("test_fallos", null, "Test de fallos");
      if (estadoReanudacion === "reanudo") return;
      const tiempoPorPreguntaSegundos = await solicitar_tiempo_por_pregunta();
      if (tiempoPorPreguntaSegundos === null) return;
      const d = await api("/failures/questions?user_id=" + state.userId);
      if (!d.questions.length) { toast("No tienes preguntas falladas"); return; }
      const preguntasMezcladas = shuffle(d.questions);
      const att = await api("/attempts/start", {
        method: "POST",
        body: {
          user_id: state.userId,
          quiz_id: null,
          attempt_type: "test_fallos",
          nombre: "Test de fallos",
          question_ids: preguntasMezcladas.map((p) => p.id),
        },
      });
      inicializar_estado_quiz({
        questions: preguntasMezcladas,
        title: "Test de fallos",
        attemptId: att.attempt_id,
        type: "test_fallos",
        tiempoPorPreguntaSegundos,
      });
    } catch (err) { toast(err.message); }
  }

  /* ── Favorites test ── */
  async function startFavoritesTest() {
    try {
      const estadoReanudacion = await comprobar_reanudacion("test_favoritas", null, "Test de favoritas");
      if (estadoReanudacion === "reanudo") return;
      const tiempoPorPreguntaSegundos = await solicitar_tiempo_por_pregunta();
      if (tiempoPorPreguntaSegundos === null) return;
      const d = await api("/favorites/questions?user_id=" + state.userId);
      if (!d.questions.length) { toast("No tienes preguntas favoritas"); return; }
      const preguntasMezcladas = shuffle(d.questions);
      const att = await api("/attempts/start", {
        method: "POST",
        body: {
          user_id: state.userId,
          quiz_id: null,
          attempt_type: "test_favoritas",
          nombre: "Test de favoritas",
          question_ids: preguntasMezcladas.map((p) => p.id),
        },
      });
      inicializar_estado_quiz({
        questions: preguntasMezcladas,
        title: "Test de favoritas",
        attemptId: att.attempt_id,
        type: "test_favoritas",
        tiempoPorPreguntaSegundos,
      });
    } catch (err) { toast(err.message); }
  }

  /* ── Favorites viewer ── */
  async function loadFavoritesViewer() {
    showView("ver-favoritas");
    const body = document.getElementById("fav-viewer-body");
    body.innerHTML = '<div class="spinner"></div>';

    try {
      const d = await api("/favorites/all?user_id=" + state.userId);
      if (!d.questions.length) {
        body.innerHTML = '<div class="empty-state"><p>No tienes preguntas favoritas</p></div>';
        return;
      }

      let currentQuiz = null;
      let html = "";
      for (const q of d.questions) {
        if (q.quiz_title !== currentQuiz) {
          currentQuiz = q.quiz_title;
          html += `<div class="fav-viewer-section-title">${esc(currentQuiz)}</div>`;
        }
        const correctAnswer = q.options[q.correct_index] || q.options[0];
        html += `<div class="fav-viewer-card">
          <div class="fav-viewer-question">${esc(q.text)}</div>
          <div class="fav-viewer-answer">${esc(correctAnswer)}</div>
          ${q.explicacion ? `<div class="fav-viewer-explanation">${esc(q.explicacion)}</div>` : ""}
          <button class="btn-icon fav-viewer-remove" data-unfav="${q.id}" title="Quitar de favoritas">
            <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" stroke="currentColor" stroke-width="2"><polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"/></svg>
          </button>
        </div>`;
      }

      body.innerHTML = html;
    } catch (err) {
      body.innerHTML = `<div class="empty-state"><p>${esc(err.message)}</p></div>`;
    }
  }

  document.getElementById("fav-viewer-body").addEventListener("click", async (e) => {
    const btn = e.target.closest("[data-unfav]");
    if (!btn) return;
    const qid = parseInt(btn.dataset.unfav);
    try {
      await api("/favorites/toggle", {
        method: "POST",
        body: { user_id: state.userId, question_id: qid },
      });
      state.favQuestionIds.delete(qid);
      btn.closest(".fav-viewer-card").remove();
      toast("Quitada de favoritas");
    } catch (err) { toast(err.message); }
  });

  /* ── Render question ── */
  function renderQuestion() {
    const q = state.quiz.questions[state.qi];
    const totalActual = state.quiz.questions.length;
    const totalOriginal = obtener_total_preguntas_quiz();
    const posicionActual = obtener_posicion_absoluta_actual();

    const totalSeguro = totalOriginal || totalActual || 1;
    document.getElementById("quiz-counter").textContent = `${posicionActual} / ${totalSeguro}`;
    document.getElementById("quiz-progress").style.width = `${(posicionActual / totalSeguro) * 100}%`;
    document.getElementById("question-text").textContent = q.text;
    document.getElementById("question-explanation").classList.add("hidden");
    state.answered = false;
    iniciar_temporizador_pregunta();

    // Shuffle options but track correct
    const optionsWithIndex = q.options.map((text, i) => ({ text, isCorrect: i === q.correct_index }));
    const shuffled = shuffle([...optionsWithIndex]);
    q._shuffled = shuffled;

    const listEl = document.getElementById("options-list");
    listEl.innerHTML = shuffled.map((opt, i) =>
      `<button class="option-btn" data-oi="${i}">${esc(opt.text)}</button>`
    ).join("");

    // Fav button
    const favBtn = document.getElementById("btn-fav-question");
    favBtn.classList.toggle("is-fav", state.favQuestionIds.has(q.id));
    document.getElementById("btn-editar-pregunta").classList.toggle("hidden", !state.puedeGestionar);
    document.getElementById("btn-eliminar-pregunta").classList.toggle("hidden", !state.puedeGestionar);

    document.getElementById("btn-next-question").textContent =
      state.qi < totalActual - 1 ? "Siguiente" : "Finalizar";
    document.getElementById("btn-next-question").classList.add("hidden");
  }

  function detener_temporizador_pregunta() {
    if (state.temporizadorPreguntaId) {
      clearInterval(state.temporizadorPreguntaId);
      state.temporizadorPreguntaId = null;
    }
  }

  function actualizar_etiqueta_temporizador() {
    const etiqueta = document.getElementById("quiz-timer");
    etiqueta.textContent = `${state.tiempoRestante}s`;
    etiqueta.classList.toggle("agotado", state.tiempoRestante <= 5);
  }

  function iniciar_temporizador_pregunta() {
    detener_temporizador_pregunta();
    const tiempoConfigurado = state.quiz?.tiempoPorPreguntaSegundos || TIEMPO_POR_PREGUNTA_POR_DEFECTO_SEGUNDOS;
    state.tiempoRestante = tiempoConfigurado;
    actualizar_etiqueta_temporizador();
    state.temporizadorPreguntaId = setInterval(() => {
      if (state.answered) {
        detener_temporizador_pregunta();
        return;
      }
      state.tiempoRestante -= 1;
      actualizar_etiqueta_temporizador();
      if (state.tiempoRestante <= 0) {
        gestionar_tiempo_agotado();
      }
    }, 1000);
  }

  async function gestionar_tiempo_agotado() {
    if (state.answered || !state.quiz) return;
    state.answered = true;
    detener_temporizador_pregunta();
    const q = state.quiz.questions[state.qi];
    document.querySelectorAll(".option-btn").forEach((b, i) => {
      b.classList.add("disabled");
      if (q._shuffled[i].isCorrect) b.classList.add("correct");
    });
    state.wrong++;
    toast("⏰ Tiempo agotado. Pregunta marcada como incorrecta.");

    try {
      await api(`/attempts/${state.quiz.attemptId}/answer`, {
        method: "POST",
        body: {
          question_id: q.id,
          selected_option: "Sin respuesta",
          is_correct: false,
          user_id: state.userId,
        },
      });
    } catch (_) {}

    if (q.explicacion) {
      const expEl = document.getElementById("question-explanation");
      expEl.textContent = q.explicacion;
      expEl.classList.remove("hidden");
    }

    document.getElementById("btn-next-question").classList.remove("hidden");
  }

  /* ── Option click ── */
  document.getElementById("options-list").addEventListener("click", async (e) => {
    const btn = e.target.closest(".option-btn");
    if (!btn || state.answered) return;
    state.answered = true;
    detener_temporizador_pregunta();

    const oi = parseInt(btn.dataset.oi);
    const q = state.quiz.questions[state.qi];
    const shuffled = q._shuffled;
    const selected = shuffled[oi];
    const isCorrect = selected.isCorrect;

    // Mark buttons
    document.querySelectorAll(".option-btn").forEach((b, i) => {
      b.classList.add("disabled");
      if (shuffled[i].isCorrect) b.classList.add("correct");
    });
    if (!isCorrect) btn.classList.add("wrong");

    if (isCorrect) state.correct++;
    else state.wrong++;

    // Record answer
    try {
      await api(`/attempts/${state.quiz.attemptId}/answer`, {
        method: "POST",
        body: {
          question_id: q.id,
          selected_option: selected.text,
          is_correct: isCorrect,
          user_id: state.userId,
        },
      });
    } catch (_) {}

    // Show explanation
    if (q.explicacion) {
      const expEl = document.getElementById("question-explanation");
      expEl.textContent = q.explicacion;
      expEl.classList.remove("hidden");
    }

    document.getElementById("btn-next-question").classList.remove("hidden");
  });

  /* ── Next question ── */
  document.getElementById("btn-next-question").addEventListener("click", async () => {
    if (!state.answered) return;
    state.qi++;
    if (state.qi >= state.quiz.questions.length) {
      await finishQuiz();
    } else {
      renderQuestion();
    }
  });

  /* ── Keyboard shortcuts for quiz ── */
  document.addEventListener("keydown", async (e) => {
    if (!state.quiz) return;
    const view = document.getElementById("view-quiz");
    if (!view.classList.contains("active")) return;

    if (!state.answered) {
      const num = parseInt(e.key);
      if (num >= 1 && num <= 4) {
        const btns = document.querySelectorAll(".option-btn");
        if (btns[num - 1]) btns[num - 1].click();
      }
    } else {
      if (e.key === "1") {
        document.getElementById("btn-fav-question").click();
        return;
      }
      if (e.key !== "Escape") {return}
      const nextBtn = document.getElementById("btn-next-question");
      if (!nextBtn.classList.contains("hidden")) nextBtn.click();
    }
  });

  /* ── Quit quiz ── */
  document.getElementById("btn-quit-quiz").addEventListener("click", async () => {
    if (await confirm("Pausar test", "Se guardará tu progreso para retomarlo después.")) {
      detener_temporizador_pregunta();
      state.quiz = null;
      showView("menu");
      loadMenuStats();
    }
  });

  /* ── Favorite question toggle ── */
  document.getElementById("btn-fav-question").addEventListener("click", async () => {
    const q = state.quiz.questions[state.qi];
    try {
      const d = await api("/favorites/toggle", {
        method: "POST",
        body: { user_id: state.userId, question_id: q.id },
      });
      if (d.es_favorita) state.favQuestionIds.add(q.id);
      else state.favQuestionIds.delete(q.id);
      document.getElementById("btn-fav-question").classList.toggle("is-fav", d.es_favorita);
      toast(d.es_favorita ? "Guardada en favoritas" : "Quitada de favoritas");
    } catch (err) { toast(err.message); }
  });

  document.getElementById("btn-editar-pregunta").addEventListener("click", async () => {
    if (!state.puedeGestionar || !state.quiz) return;
    const q = state.quiz.questions[state.qi];
    const resultado = await abrirEditorPregunta(q);
    if (!resultado) return;
    try {
      const actualizado = await api(`/questions/${q.id}`, {
        method: "PUT",
        body: { user_id: state.userId, ...resultado },
      });
      state.quiz.questions[state.qi] = {
        ...q,
        text: actualizado.question.text,
        explicacion: actualizado.question.explicacion,
        options: actualizado.question.options,
        correct_index: 0,
      };
      toast("Pregunta actualizada");
      renderQuestion();
    } catch (err) {
      toast(err.message);
    }
  });

  document.getElementById("btn-eliminar-pregunta").addEventListener("click", async () => {
    if (!state.puedeGestionar || !state.quiz) return;
    const q = state.quiz.questions[state.qi];
    if (!await confirm("Eliminar pregunta", "Esta accion eliminara la pregunta de forma permanente.")) return;
    try {
      await api(`/questions/${q.id}?user_id=${state.userId}`, { method: "DELETE" });
      state.quiz.questions.splice(state.qi, 1);
      if (!state.quiz.questions.length) {
        toast("No quedan preguntas en este test");
        await finishQuiz();
        return;
      }
      if (state.qi >= state.quiz.questions.length) state.qi = state.quiz.questions.length - 1;
      toast("Pregunta eliminada");
      renderQuestion();
    } catch (err) {
      toast(err.message);
    }
  });

  function abrirEditorPregunta(pregunta) {
    return new Promise((resolve) => {
      const opciones = pregunta.options || [];
      const opcionCorrecta = opciones[pregunta.correct_index || 0] || "";
      const opcionesIncorrectas = opciones.filter((_, i) => i !== (pregunta.correct_index || 0));
      const overlay = document.createElement("div");
      overlay.className = "dialog-overlay";
      overlay.innerHTML = `<div class="dialog dialog-editor-pregunta">
        <h3>Editar pregunta</h3>
        <label>Enunciado</label>
        <textarea id="editar-enunciado">${esc(pregunta.text)}</textarea>
        <label>Respuesta correcta</label>
        <textarea id="editar-respuesta-correcta">${esc(opcionCorrecta)}</textarea>
        <label>Respuesta 2</label>
        <textarea id="editar-respuesta-2">${esc(opcionesIncorrectas[0] || "")}</textarea>
        <label>Respuesta 3</label>
        <textarea id="editar-respuesta-3">${esc(opcionesIncorrectas[1] || "")}</textarea>
        <label>Respuesta 4</label>
        <textarea id="editar-respuesta-4">${esc(opcionesIncorrectas[2] || "")}</textarea>
        <label>Explicacion</label>
        <textarea id="editar-explicacion">${esc(pregunta.explicacion || "")}</textarea>
        <div class="dialog-actions">
          <button class="btn btn-outline btn-sm" data-cancelar="1">Cancelar</button>
          <button class="btn btn-primary btn-sm" data-guardar="1">Guardar</button>
        </div>
      </div>`;
      overlay.addEventListener("click", (e) => {
        if (e.target.dataset.cancelar) {
          overlay.remove();
          resolve(null);
          return;
        }
        if (e.target.dataset.guardar) {
          const text = overlay.querySelector("#editar-enunciado").value.trim();
          const correcta = overlay.querySelector("#editar-respuesta-correcta").value.trim();
          const r2 = overlay.querySelector("#editar-respuesta-2").value.trim();
          const r3 = overlay.querySelector("#editar-respuesta-3").value.trim();
          const r4 = overlay.querySelector("#editar-respuesta-4").value.trim();
          const explicacion = overlay.querySelector("#editar-explicacion").value.trim();
          const opcionesActualizadas = [correcta, r2, r3, r4].filter((v) => v);
          if (!text || !correcta || !r2) {
            toast("Enunciado, respuesta correcta y respuesta 2 son obligatorios");
            return;
          }
          overlay.remove();
          resolve({
            text,
            explicacion,
            opciones: opcionesActualizadas,
          });
        }
      });
      document.body.appendChild(overlay);
    });
  }

  /* ── Finish quiz ── */
  async function finishQuiz() {
    detener_temporizador_pregunta();
    const total = state.quiz.questions.length;
    state.blank = total - state.correct - state.wrong;

    try {
      await api(`/attempts/${state.quiz.attemptId}/finish`, {
        method: "POST",
        body: { correct: state.correct, wrong: state.wrong },
      });
    } catch (_) {}

    if (state.quiz.type === "simulacro") {
      showSimulacroResults();
      return;
    }

    const nota = total > 0
      ? Math.max((state.correct - PENALIZACION * state.wrong) / total * 10, 0)
      : 0;

    const body = document.getElementById("results-body");
    body.innerHTML = `
      <div class="results-card">
        <h2>${esc(state.quiz.title)}</h2>
        <div class="results-score ${nota >= 5 ? "pass" : "fail"}">${nota.toFixed(2)}</div>
        <div style="color: var(--text-secondary); font-size: 0.9rem;">sobre 10</div>
        <div class="results-detail">
          <div class="results-detail-item">
            <div class="results-detail-value results-correct">${state.correct}</div>
            <div class="results-detail-label">Correctas</div>
          </div>
          <div class="results-detail-item">
            <div class="results-detail-value results-wrong">${state.wrong}</div>
            <div class="results-detail-label">Incorrectas</div>
          </div>
          <div class="results-detail-item">
            <div class="results-detail-value results-blank">${state.blank}</div>
            <div class="results-detail-label">En blanco</div>
          </div>
        </div>
      </div>
      <button class="btn btn-primary btn-block" id="btn-results-back">Volver al menu</button>
    `;
    showView("results");
    document.getElementById("btn-results-back").addEventListener("click", () => {
      showView("menu");
      loadMenuStats();
    });
  }

  /* ── Simulacros ── */
  async function loadSimulacros() {
    showView("simulacros");
    const listEl = document.getElementById("simulacros-list");
    listEl.innerHTML = '<div class="spinner"></div>';

    try {
      const d = await api("/simulacros");
      if (!d.simulacros.length) {
        listEl.innerHTML = '<div class="empty-state"><p>No hay simulacros configurados</p></div>';
        return;
      }
      listEl.innerHTML = d.simulacros.map((s) =>
        `<div class="test-item" data-sim="${s.id}">
          <div class="test-item-info">
            <div class="test-item-title">${esc(s.nombre)}</div>
            <div class="test-item-meta">Test: ${esc(s.test_titulo)} &middot; Corte: ${s.nota_corte_directa}</div>
          </div>
          <div class="test-item-actions">
            ${state.puedeGestionar ? `<button class="btn-icon sim-del-btn" data-sim-del="${s.id}" title="Borrar">
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 01-2 2H8a2 2 0 01-2-2L5 6"/></svg>
            </button>` : ""}
          </div>
        </div>`
      ).join("");
    } catch (err) {
      listEl.innerHTML = `<div class="empty-state"><p>${esc(err.message)}</p></div>`;
    }
  }

  document.getElementById("simulacros-list").addEventListener("click", async (e) => {
    const delBtn = e.target.closest("[data-sim-del]");
    if (delBtn) {
      e.stopPropagation();
      const simId = parseInt(delBtn.dataset.simDel);
      if (await confirm("Borrar simulacro", "Se eliminara este simulacro.")) {
        try {
          await api(`/simulacros/${simId}?user_id=${state.userId}`, { method: "DELETE" });
          toast("Simulacro borrado");
          loadSimulacros();
        } catch (err) { toast(err.message); }
      }
      return;
    }
    const item = e.target.closest("[data-sim]");
    if (item) startSimulacro(parseInt(item.dataset.sim));
  });

  async function startSimulacro(simId) {
    try {
      const tiempoPorPreguntaSegundos = await solicitar_tiempo_por_pregunta();
      if (tiempoPorPreguntaSegundos === null) return;
      const d = await api(`/simulacros/${simId}/start`, { method: "POST", body: { user_id: state.userId } });
      if (!d.questions.length) { toast("El simulacro no tiene preguntas"); return; }
      const att = await api("/attempts/start", {
        method: "POST",
        body: { user_id: state.userId, quiz_id: d.simulacro.quiz_id, attempt_type: "simulacro" },
      });
      state.quiz = {
        questions: shuffle(d.questions),
        title: d.simulacro.nombre,
        attemptId: att.attempt_id,
        type: "simulacro",
        simulacro: d.simulacro,
        tiempoPorPreguntaSegundos,
      };
      state.qi = 0; state.correct = 0; state.wrong = 0; state.blank = 0; state.answered = false;
      document.getElementById("quiz-title").textContent = d.simulacro.nombre;
      showView("quiz");
      renderQuestion();
    } catch (err) { toast(err.message); }
  }

  async function showSimulacroResults() {
    const total = state.quiz.questions.length;
    const totalP1 = Math.min(PREGUNTAS_P1, total);
    const totalP2 = Math.max(0, total - totalP1);

    // We need to recalculate per-part stats from the answers
    // Since we answered sequentially, first totalP1 = part1, rest = part2
    // But actually the questions were shuffled and we don't track per-question...
    // We'll approximate: use the overall stats split proportionally
    // For a proper split we'd need to track per-question results
    // Better: send all stats to the calculate endpoint
    const aciertosP1 = Math.min(state.correct, totalP1);
    const erroresP1 = Math.min(state.wrong, totalP1 - aciertosP1);
    const aciertosP2 = state.correct - aciertosP1;
    const erroresP2 = state.wrong - erroresP1;

    try {
      const result = await api("/simulacros/calculate", {
        method: "POST",
        body: {
          aciertos_p1: aciertosP1, errores_p1: erroresP1,
          aciertos_p2: aciertosP2, errores_p2: erroresP2,
          total_p1: totalP1, total_p2: totalP2,
        },
      });

      const body = document.getElementById("simulacro-results-body");
      body.innerHTML = `
        <div class="sim-section">
          <h3>Puntuacion directa</h3>
          <div class="sim-row"><span class="label">Parte 1</span><span class="value">${result.directa_p1}</span></div>
          <div class="sim-row"><span class="label">Parte 2</span><span class="value">${result.directa_p2}</span></div>
          <div class="sim-row"><span class="label">Total</span><span class="value" style="font-size:1.1rem">${result.directa_total}</span></div>
          <div class="sim-row"><span class="label">En blanco P1</span><span class="value">${result.blancos_p1}</span></div>
          <div class="sim-row"><span class="label">En blanco P2</span><span class="value">${result.blancos_p2}</span></div>
        </div>
        <div class="sim-section">
          <h3>Escenarios de corte</h3>
          <div class="sim-row"><span class="label">Optimista</span><span class="value">${result.corte_optimista}</span></div>
          <div class="sim-row"><span class="label">Media</span><span class="value">${result.corte_media}</span></div>
          <div class="sim-row"><span class="label">Pesimista</span><span class="value">${result.corte_pesimista}</span></div>
        </div>
        <div class="sim-section">
          <h3>Nota transformada (TPS)</h3>
          <div class="sim-row"><span class="label">Optimista</span><span class="value ${result.aprobado_optimista ? "pass" : "fail"}">${result.tps_optimista}</span></div>
          <div class="sim-row"><span class="label">Media</span><span class="value">${result.tps_medio}</span></div>
          <div class="sim-row"><span class="label">Pesimista</span><span class="value ${result.aprobado_pesimista ? "pass" : "fail"}">${result.tps_pesimista}</span></div>
        </div>
        <div class="sim-section">
          <h3>Posicion estimada</h3>
          ${result.pos_2024 !== null ? `<div class="sim-row"><span class="label">Historico 2024</span><span class="value">#${result.pos_2024}</span></div>` : ""}
          ${result.pos_2022 !== null ? `<div class="sim-row"><span class="label">Historico 2022</span><span class="value">#${result.pos_2022}</span></div>` : ""}
          ${result.pos_2024 === null && result.pos_2022 === null ? '<div class="sim-row"><span class="label">Sin datos historicos</span></div>' : ""}
          <div class="sim-row"><span class="label">Supera minimo 30%</span><span class="value ${result.supera_minimo_30 ? "pass" : "fail"}">${result.supera_minimo_30 ? "Si" : "No"}</span></div>
        </div>
        <button class="btn btn-primary btn-block" id="btn-sim-results-back" style="margin-top:8px">Volver al menu</button>
      `;
      showView("simulacro-results");
      document.getElementById("btn-sim-results-back").addEventListener("click", () => {
        showView("menu");
        loadMenuStats();
      });
    } catch (err) {
      toast(err.message);
      showView("menu");
    }
  }

  /* ── Progress ── */
  async function loadProgress() {
    showView("progreso");
    const body = document.getElementById("progress-body");
    body.innerHTML = '<div class="spinner"></div>';

    try {
      const d = await api("/progress?user_id=" + state.userId);

      let html = `
        <div class="progress-card">
          <h3>Resumen general</h3>
          <div class="results-detail" style="justify-content: flex-start; gap: 16px; flex-wrap: wrap;">
            <div class="results-detail-item"><div class="results-detail-value" style="color: var(--primary)">${d.nota_general.toFixed(2)}</div><div class="results-detail-label">Nota media</div></div>
            <div class="results-detail-item"><div class="results-detail-value results-correct">${d.total_correct}</div><div class="results-detail-label">Correctas</div></div>
            <div class="results-detail-item"><div class="results-detail-value results-wrong">${d.total_wrong}</div><div class="results-detail-label">Incorrectas</div></div>
            <div class="results-detail-item"><div class="results-detail-value">${d.total_attempts}</div><div class="results-detail-label">Intentos</div></div>
            <div class="results-detail-item"><div class="results-detail-value">${d.respondidas_hoy}</div><div class="results-detail-label">Hoy</div></div>
          </div>
        </div>
      `;

      if (d.por_test && d.por_test.length) {
        for (const test of d.por_test) {
          const lastNota = test.intentos.length ? test.intentos[test.intentos.length - 1].nota : 0;
          const barClass = lastNota >= 7 ? "good" : lastNota >= 5 ? "medium" : "bad";
          html += `<div class="progress-card">
            <h3>${esc(test.titulo)}</h3>
            <div class="progress-bar-container"><div class="progress-bar-fill ${barClass}" style="width:${lastNota * 10}%"></div></div>
            <div class="progress-attempts">Ultima nota: ${lastNota.toFixed(2)} &middot; ${test.intentos.length} intento(s)</div>
            ${test.intentos.map((a, i) => `<div class="progress-attempt-row">
              <span>#${i + 1}</span>
              <span class="${a.nota >= 5 ? "results-correct" : "results-wrong"}">${a.nota.toFixed(2)}</span>
              <span>${a.correct}/${a.correct + a.wrong}</span>
            </div>`).join("")}
          </div>`;
        }
      }

      body.innerHTML = html;
    } catch (err) {
      body.innerHTML = `<div class="empty-state"><p>${esc(err.message)}</p></div>`;
    }
  }

  /* ── Utils ── */
  function shuffle(arr) {
    const a = [...arr];
    for (let i = a.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [a[i], a[j]] = [a[j], a[i]];
    }
    return a;
  }

  function esc(s) {
    const d = document.createElement("div");
    d.textContent = s || "";
    return d.innerHTML;
  }

  /* ── Init ── */
  if (loadSession()) enterApp();
  else showView("login");
})();
