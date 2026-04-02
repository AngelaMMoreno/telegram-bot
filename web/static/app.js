/* ── Aprentix Tests – SPA ── */
(function () {
  "use strict";

  const PENALIZACION = 1 / 3;
  const PREGUNTAS_P1 = 80;

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
    favQuestionIds: new Set(),
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

  /* ── Menu actions ── */
  document.querySelector(".menu-grid").addEventListener("click", (e) => {
    const card = e.target.closest(".menu-card");
    if (!card) return;
    const action = card.dataset.action;
    if (action === "tests") { state.favFilter = false; loadTests(1); }
    else if (action === "upload") showView("upload");
    else if (action === "fallos") startFailuresTest();
    else if (action === "favoritas") startFavoritesTest();
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
    showView("tests");
    const listEl = document.getElementById("test-list");
    const pagEl = document.getElementById("test-pagination");
    const titleEl = document.getElementById("tests-title");
    listEl.innerHTML = '<div class="spinner"></div>';
    pagEl.innerHTML = "";

    const filterBtn = document.getElementById("btn-toggle-fav-filter");
    filterBtn.classList.toggle("active", state.favFilter);
    titleEl.textContent = state.favFilter ? "Tests favoritos" : "Mis tests";

    try {
      const endpoint = state.favFilter
        ? `/tests/favoritos?user_id=${state.userId}&page=${page}`
        : `/tests?user_id=${state.userId}&page=${page}`;
      const d = await api(endpoint);
      if (!d.tests.length) {
        listEl.innerHTML = '<div class="empty-state"><p>No hay tests</p></div>';
        return;
      }
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
    if (item) startQuiz(parseInt(item.dataset.id));
  });

  document.getElementById("test-pagination").addEventListener("click", (e) => {
    const btn = e.target.closest("[data-p]");
    if (btn) loadTests(parseInt(btn.dataset.p));
  });

  document.getElementById("btn-toggle-fav-filter").addEventListener("click", () => {
    state.favFilter = !state.favFilter;
    loadTests(1);
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
      const d = await api(`/tests/${quizId}/questions`);
      if (!d.questions.length) { toast("El test no tiene preguntas"); return; }
      const att = await api("/attempts/start", {
        method: "POST",
        body: { user_id: state.userId, quiz_id: quizId, attempt_type: "quiz" },
      });
      state.quiz = {
        questions: shuffle(d.questions),
        title: d.quiz.title,
        attemptId: att.attempt_id,
        type: "quiz",
        quizId: quizId,
      };
      state.qi = 0;
      state.correct = 0;
      state.wrong = 0;
      state.blank = 0;
      state.answered = false;
      document.getElementById("quiz-title").textContent = d.quiz.title;
      showView("quiz");
      renderQuestion();
    } catch (err) { toast(err.message); }
  }

  /* ── Failures test ── */
  async function startFailuresTest() {
    try {
      const d = await api("/failures/questions?user_id=" + state.userId);
      if (!d.questions.length) { toast("No tienes preguntas falladas"); return; }
      const att = await api("/attempts/start", {
        method: "POST",
        body: { user_id: state.userId, quiz_id: null, attempt_type: "test_fallos" },
      });
      state.quiz = {
        questions: shuffle(d.questions),
        title: "Test de fallos",
        attemptId: att.attempt_id,
        type: "test_fallos",
      };
      state.qi = 0; state.correct = 0; state.wrong = 0; state.blank = 0; state.answered = false;
      document.getElementById("quiz-title").textContent = "Test de fallos";
      showView("quiz");
      renderQuestion();
    } catch (err) { toast(err.message); }
  }

  /* ── Favorites test ── */
  async function startFavoritesTest() {
    try {
      const d = await api("/favorites/questions?user_id=" + state.userId);
      if (!d.questions.length) { toast("No tienes preguntas favoritas"); return; }
      const att = await api("/attempts/start", {
        method: "POST",
        body: { user_id: state.userId, quiz_id: null, attempt_type: "test_favoritas" },
      });
      state.quiz = {
        questions: shuffle(d.questions),
        title: "Test de favoritas",
        attemptId: att.attempt_id,
        type: "test_favoritas",
      };
      state.qi = 0; state.correct = 0; state.wrong = 0; state.blank = 0; state.answered = false;
      document.getElementById("quiz-title").textContent = "Test de favoritas";
      showView("quiz");
      renderQuestion();
    } catch (err) { toast(err.message); }
  }

  /* ── Render question ── */
  function renderQuestion() {
    const q = state.quiz.questions[state.qi];
    const total = state.quiz.questions.length;

    document.getElementById("quiz-counter").textContent = `${state.qi + 1} / ${total}`;
    document.getElementById("quiz-progress").style.width = `${((state.qi + 1) / total) * 100}%`;
    document.getElementById("question-text").textContent = q.text;
    document.getElementById("question-explanation").classList.add("hidden");
    state.answered = false;

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

    document.getElementById("btn-next-question").textContent =
      state.qi < total - 1 ? "Siguiente" : "Finalizar";
    document.getElementById("btn-next-question").classList.add("hidden");
  }

  /* ── Option click ── */
  document.getElementById("options-list").addEventListener("click", async (e) => {
    const btn = e.target.closest(".option-btn");
    if (!btn || state.answered) return;
    state.answered = true;

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

  /* ── Quit quiz ── */
  document.getElementById("btn-quit-quiz").addEventListener("click", async () => {
    if (await confirm("Salir del test", "Se guardara tu progreso actual.")) {
      await finishQuiz();
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

  /* ── Finish quiz ── */
  async function finishQuiz() {
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
            <button class="btn-icon sim-del-btn" data-sim-del="${s.id}" title="Borrar">
              <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 01-2 2H8a2 2 0 01-2-2L5 6"/></svg>
            </button>
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
          await api(`/simulacros/${simId}`, { method: "DELETE" });
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
