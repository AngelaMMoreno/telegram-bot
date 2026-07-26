/*
 * Aprentix · SPA /estudio  (MVP funcional del rediseño).
 *
 * Fusiona lo que antes eran /tests y /teoria en una única SPA con
 * jerarquía Oposición → Tema → Módulo → Sección. Router hash simple.
 *
 * Vistas:
 *   #/          #/home             Home de la oposición activa.
 *   #/tema/:id                     Módulos del tema + esquema.
 *   #/modulo/:id                   Secciones + esquema.
 *   #/seccion/:id/teoria           Render markdown + CTA "hacer test".
 *   #/seccion/:id/test             Flujo test (10 preguntas).
 *   #/repaso/:oposicion_id         40 preguntas repaso global.
 *   #/tablon/:oposicion_id         Enlaces útiles.
 *   #/estadisticas                 Placeholder.
 *   #/mi-cuenta                    Datos, cambiar pass, sesiones activas.
 *   #/verify?token=…               Verificación de email.
 *   #/reset?token=…                Reset password.
 *   #/login                        Login/registro si no hay sesión.
 *
 * Sesión: usa window.AprentixSession (access en memoria + refresh
 * transparente).
 */
'use strict';

(function () {
  const S = window.AprentixSession;
  if (!S) { console.error('AprentixSession no cargado'); return; }

  const root = document.getElementById('root');
  const toast = document.getElementById('toast');

  // ── Utilidades ─────────────────────────────────────────────────────

  const esc = (s) => String(s ?? '').replace(/[&<>"']/g,
    c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

  function showToast(msg, ms = 2500) {
    toast.textContent = msg;
    toast.classList.remove('hidden');
    clearTimeout(showToast._t);
    showToast._t = setTimeout(() => toast.classList.add('hidden'), ms);
  }

  function html(strings, ...values) {
    // Template helper: escapa valores por defecto salvo que sean HTMLElements.
    let out = '';
    strings.forEach((s, i) => {
      out += s;
      if (i < values.length) {
        const v = values[i];
        out += (v && v.__raw) ? v.value : esc(v);
      }
    });
    return out;
  }
  const raw = (v) => ({ __raw: true, value: String(v ?? '') });

  function parseHash() {
    const h = location.hash.replace(/^#/, '') || '/';
    const [path, query] = h.split('?');
    const params = new URLSearchParams(query || '');
    return { path, params };
  }

  function navigate(hash) {
    if (location.hash === hash) _render();
    else location.hash = hash;
  }

  function loading() { root.innerHTML = '<div class="loading">Cargando…</div>'; }
  function empty(msg = 'Sin datos.') { root.innerHTML = `<div class="empty">${esc(msg)}</div>`; }

  function renderMarkdown(md) {
    if (!window.marked || !window.DOMPurify) return `<pre>${esc(md)}</pre>`;
    return window.DOMPurify.sanitize(window.marked.parse(md || ''));
  }

  // ── Persistencia mínima del contexto (oposición activa) ───────────
  const CTX_KEY = 'aprentix_ctx_estudio';
  function getCtx() {
    try { return JSON.parse(localStorage.getItem(CTX_KEY) || '{}'); }
    catch { return {}; }
  }
  function setCtx(patch) {
    const cur = getCtx();
    localStorage.setItem(CTX_KEY, JSON.stringify({ ...cur, ...patch }));
  }

  // ── Endpoint del microservicio de contenido (teoría markdown) ─────
  // El servicio 'contenido/' (antes 'teoria/') sirve GET /teoria/api/leer?ruta=…
  // para ficheros y expone otros endpoints admin (upload, mv, rm).
  async function fetchMarkdown(ruta) {
    // Refresca el access token proactivamente vía cualquier rpc barata,
    // así el Bearer que enviamos al microservicio de contenido está fresco.
    try { await S.rpc('leer_config'); } catch (_) { /* ignoramos */ }
    const tok = S.getAccess?.();
    const r = await fetch(`/teoria/api/leer?ruta=${encodeURIComponent(ruta)}`, {
      headers: tok ? { Authorization: `Bearer ${tok}` } : {},
    });
    if (!r.ok) throw new Error('no_pudo_leer_teoria');
    return await r.text();
  }

  // ── Router ─────────────────────────────────────────────────────────

  const routes = [
    { re: /^\/(?:home)?$/,                   view: viewHome },
    { re: /^\/tema\/([0-9a-f-]+)$/,          view: viewTema },
    { re: /^\/modulo\/([0-9a-f-]+)$/,        view: viewModulo },
    { re: /^\/seccion\/([0-9a-f-]+)\/teoria$/,view: viewTeoria },
    { re: /^\/seccion\/([0-9a-f-]+)\/test$/, view: viewTestSeccion },
    { re: /^\/repaso\/([0-9a-f-]+)$/,        view: viewRepaso },
    { re: /^\/tablon\/([0-9a-f-]+)$/,        view: viewTablon },
    { re: /^\/estadisticas$/,                view: viewEstadisticas },
    { re: /^\/mi-cuenta$/,                   view: viewMiCuenta },
    { re: /^\/admin\/usuarios$/,             view: viewAdminUsuarios },
    { re: /^\/admin\/duplicados$/,           view: viewAdminDuplicados },
    { re: /^\/verify$/,                      view: viewVerify,     pub: true },
    { re: /^\/reset$/,                       view: viewReset,      pub: true },
    { re: /^\/login$/,                       view: viewLogin,      pub: true },
  ];

  async function _render() {
    const { path, params } = parseHash();
    const route = routes.find(r => r.re.test(path));
    if (!route) { navigate('#/'); return; }

    // Rutas privadas: si no hay sesión, al login.
    if (!route.pub && !S.getUser()) { navigate('#/login'); return; }

    const m = path.match(route.re) || [];
    try {
      await route.view(m.slice(1), params);
    } catch (e) {
      console.error('view error', e);
      root.innerHTML = `<div class="empty">Error: ${esc(e.message || 'ver consola')}</div>`;
    }
  }
  window.addEventListener('hashchange', _render);


  // ── Vista: login/registro ──────────────────────────────────────────
  function viewLogin() {
    root.innerHTML = html`
      <div class="view-head"><h2>Aprentix — Estudio</h2></div>
      <div class="tema-card" style="cursor:default">
        <div style="display:flex; gap:.5rem; margin-bottom: 1rem">
          <button class="btn btn-pri" id="tab-login">Iniciar sesión</button>
          <button class="btn"          id="tab-reg">Crear cuenta</button>
          <button class="btn"          id="tab-forgot" style="margin-left:auto">¿Olvidaste?</button>
        </div>
        <form id="form-login">
          <input class="input" name="email"    type="email"    placeholder="Email"       required style="width:100%;margin:.3rem 0">
          <input class="input" name="password" type="password" placeholder="Contraseña"  required style="width:100%;margin:.3rem 0">
          <input class="input" name="totp"     type="text"     placeholder="Código 2FA (si tienes)" style="width:100%;margin:.3rem 0">
          <button class="btn btn-pri" style="width:100%;margin-top:.6rem">Entrar</button>
          <div class="muted small" id="err-login" style="color:#b83a3a;margin-top:.4rem"></div>
        </form>
        <form id="form-reg" hidden>
          <input class="input" name="email"          type="email"    placeholder="Email"           required style="width:100%;margin:.3rem 0">
          <input class="input" name="nombre_visible" type="text"     placeholder="Nombre a mostrar" required style="width:100%;margin:.3rem 0">
          <input class="input" name="password"       type="password" placeholder="Contraseña (≥10 chars)" required style="width:100%;margin:.3rem 0">
          <button class="btn btn-pri" style="width:100%;margin-top:.6rem">Crear cuenta</button>
          <div class="muted small" id="err-reg" style="color:#b83a3a;margin-top:.4rem"></div>
        </form>
        <form id="form-forgot" hidden>
          <input class="input" name="email" type="email" placeholder="Email" required style="width:100%;margin:.3rem 0">
          <button class="btn btn-pri" style="width:100%;margin-top:.6rem">Recibir enlace de reset</button>
          <div class="muted small" id="msg-forgot" style="margin-top:.4rem"></div>
        </form>
      </div>
    `;
    const $ = (s) => root.querySelector(s);
    const show = (id) => {
      $('#form-login').hidden  = id !== 'login';
      $('#form-reg').hidden    = id !== 'reg';
      $('#form-forgot').hidden = id !== 'forgot';
    };
    $('#tab-login').onclick  = () => show('login');
    $('#tab-reg').onclick    = () => show('reg');
    $('#tab-forgot').onclick = () => show('forgot');

    $('#form-login').onsubmit = async (e) => {
      e.preventDefault();
      const f = new FormData(e.target);
      try {
        await S.login(f.get('email'), f.get('password'), f.get('totp') || null);
        navigate('#/');
      } catch (err) {
        $('#err-login').textContent = _msgError(err.message);
      }
    };
    $('#form-reg').onsubmit = async (e) => {
      e.preventDefault();
      const f = new FormData(e.target);
      try {
        const r = await S.registrar(f.get('email'), f.get('password'), f.get('nombre_visible'));
        showToast(r.mensaje || 'Revisa tu correo para verificar la cuenta.', 5000);
        show('login');
      } catch (err) {
        $('#err-reg').textContent = _msgError(err.message);
      }
    };
    $('#form-forgot').onsubmit = async (e) => {
      e.preventDefault();
      const f = new FormData(e.target);
      try {
        const r = await S.solicitarReset(f.get('email'));
        $('#msg-forgot').textContent = r.mensaje || 'Si el email existe, recibirás un correo.';
      } catch (err) {
        $('#msg-forgot').textContent = _msgError(err.message);
      }
    };
  }

  function _msgError(code) {
    return ({
      credenciales_invalidas: 'Email o contraseña incorrectos.',
      cuenta_bloqueada:       'Cuenta bloqueada temporalmente por intentos fallidos.',
      totp_requerido:         'Introduce el código 2FA de tu app.',
      totp_invalido:          'Código 2FA incorrecto.',
      email_no_verificado:    'Tienes que verificar tu email antes de entrar.',
      password_debil:         'La contraseña no cumple la política (≥10 caracteres y 3 de 4 categorías).',
      email_invalido:         'Email inválido.',
      nombre_visible_invalido:'El nombre debe tener al menos 2 caracteres.',
      token_invalido:         'El enlace ha caducado o ya se usó.',
      no_autenticado:         'Sesión caducada. Vuelve a entrar.',
    })[code] || code;
  }


  // ── Vista: verificar email ─────────────────────────────────────────
  async function viewVerify(_, params) {
    root.innerHTML = '<div class="loading">Verificando…</div>';
    const token = params.get('token');
    if (!token) return empty('Enlace inválido.');
    try {
      await S.verificarEmail(token);
      root.innerHTML = html`
        <div class="resultado-card">
          <h2>Email verificado ✓</h2>
          <p>Ya puedes iniciar sesión.</p>
          <button class="btn btn-pri" onclick="location.hash='#/login'">Entrar</button>
        </div>`;
    } catch (e) {
      empty(_msgError(e.message));
    }
  }


  // ── Vista: reset password ──────────────────────────────────────────
  async function viewReset(_, params) {
    const token = params.get('token');
    if (!token) return empty('Enlace inválido.');
    root.innerHTML = html`
      <div class="view-head"><h2>Nueva contraseña</h2></div>
      <div class="tema-card" style="cursor:default">
        <form id="form-reset">
          <input class="input" name="nueva" type="password"
                 placeholder="Nueva contraseña (≥10 chars)" required
                 style="width:100%;margin:.3rem 0">
          <button class="btn btn-pri" style="width:100%;margin-top:.6rem">Guardar</button>
          <div class="muted small" id="err" style="color:#b83a3a;margin-top:.4rem"></div>
        </form>
      </div>`;
    root.querySelector('#form-reset').onsubmit = async (e) => {
      e.preventDefault();
      const nueva = new FormData(e.target).get('nueva');
      try {
        await S.resetearPassword(token, nueva);
        showToast('Contraseña actualizada. Ya puedes entrar.', 4000);
        navigate('#/login');
      } catch (err) {
        root.querySelector('#err').textContent = _msgError(err.message);
      }
    };
  }


  // ── Vista: home ────────────────────────────────────────────────────
  async function viewHome() {
    loading();
    // Averigua la oposición activa: preferencia local, o la primera del usuario.
    let opId = getCtx().oposicion_id;
    if (!opId) {
      const rs = await S.rpc('mis_oposiciones').catch(() => ({ oposiciones: [] }));
      const list = rs.oposiciones || rs || [];
      if (Array.isArray(list) && list.length) opId = list[0].id;
    }
    if (!opId) {
      root.innerHTML = html`
        <div class="empty">
          <p>No tienes ninguna oposición asignada todavía.</p>
          <p class="muted small">Habla con un administrador o revisa tu cuenta.</p>
        </div>`;
      return;
    }
    setCtx({ oposicion_id: opId });

    const home = await S.rpc('mi_home_oposicion', { p_oposicion_id: opId });
    const op = home.oposicion || {};
    const temas = home.temas || [];

    root.innerHTML = html`
      <button class="oposicion-picker" id="btn-cambiar-op">
        <span>📚</span>
        <span>${op.nombre || 'Elige una oposición'}</span>
        <span class="caret">▾</span>
      </button>
      <button class="btn-repasar" id="btn-repasar-op">
        🔁 Repasar toda la oposición (40 preguntas)
      </button>
      ${raw(temas.map(t => html`
        <div class="tema-card" data-tema="${t.id}">
          <div class="tema-head">
            <span class="tema-titulo">${t.nombre}</span>
            <span class="tema-pct">${t.pct}%</span>
          </div>
          <div class="barra"><i style="width:${t.pct}%"></i></div>
          <div class="modulos">
            ${(t.modulos || []).length} módulo(s)
          </div>
        </div>
      `).join(''))}
      ${temas.length === 0 ? '<div class="empty">Esta oposición aún no tiene temas asignados.</div>' : ''}
    `;

    root.querySelectorAll('.tema-card').forEach(c => {
      c.onclick = () => navigate(`#/tema/${c.dataset.tema}`);
    });
    root.querySelector('#btn-repasar-op').onclick = () => navigate(`#/repaso/${opId}`);
    root.querySelector('#btn-cambiar-op').onclick = () => _abrirSelectorOposicion();
  }

  async function _abrirSelectorOposicion() {
    const rs = await S.rpc('mis_oposiciones').catch(() => ({ oposiciones: [] }));
    const list = rs.oposiciones || rs || [];
    if (!list.length) return showToast('No tienes más oposiciones asignadas.');
    // Modal muy simple con opciones.
    const nombres = list.map((o, i) => `${i+1}. ${o.nombre}`).join('\n');
    const sel = prompt(`Elige oposición:\n${nombres}\n\nEscribe el número:`);
    const idx = parseInt(sel, 10) - 1;
    if (!isNaN(idx) && list[idx]) {
      setCtx({ oposicion_id: list[idx].id });
      navigate('#/');
    }
  }


  // ── Vista: tema (módulos + esquema) ────────────────────────────────
  async function viewTema([temaId]) {
    loading();
    const opId = getCtx().oposicion_id;
    const home = opId ? await S.rpc('mi_home_oposicion', { p_oposicion_id: opId }) : { temas: [] };
    const tema = (home.temas || []).find(t => t.id === temaId);
    if (!tema) return empty('Tema no encontrado en tu oposición actual.');

    root.innerHTML = html`
      <div class="view-head">
        <div class="breadcrumbs">
          <a href="#/">${home.oposicion?.nombre || 'Inicio'}</a> / <strong>${tema.nombre}</strong>
        </div>
      </div>
      <h2>${tema.nombre}</h2>
      <div class="barra" style="height:8px;margin-bottom:1rem">
        <i style="display:block;height:100%;background:var(--accent);width:${tema.pct}%"></i>
      </div>
      <a class="btn" href="#/repaso/${opId}?tema=${tema.id}" style="margin-bottom:1rem;display:inline-block">
        📄 Ver esquema del tema
      </a>
      ${raw((tema.modulos || []).map(m => html`
        <div class="modulo-row" data-modulo="${m.id}">
          <span class="modulo-titulo">${m.nombre}</span>
          <span class="modulo-progreso">${m.secciones_ok}/${m.secciones_total} secciones</span>
          <span>›</span>
        </div>
      `).join(''))}
      ${tema.pct >= 100 ? html`
        <button class="btn-repasar" id="btn-repaso-tema">🔁 Repasar tema completo</button>
      ` : ''}
    `;

    root.querySelectorAll('.modulo-row').forEach(r => {
      r.onclick = () => navigate(`#/modulo/${r.dataset.modulo}`);
    });
    const btnRT = root.querySelector('#btn-repaso-tema');
    if (btnRT) {
      btnRT.onclick = async () => {
        try {
          const r = await S.rpc('iniciar_intento_tema', { p_tema_id: temaId });
          _iniciarFlujoTest(r);
        } catch (e) { showToast(_msgError(e.message)); }
      };
    }
  }


  // ── Vista: módulo (secciones) ──────────────────────────────────────
  async function viewModulo([modId]) {
    loading();
    const opId = getCtx().oposicion_id;
    const home = opId ? await S.rpc('mi_home_oposicion', { p_oposicion_id: opId }) : { temas: [] };
    let tema = null, modulo = null;
    for (const t of (home.temas || [])) {
      for (const m of (t.modulos || [])) if (m.id === modId) { modulo = m; tema = t; }
    }
    if (!modulo) return empty('Módulo no encontrado.');

    const totalOk = modulo.secciones_ok || 0;
    const totalT  = modulo.secciones_total || 0;
    const completado = totalOk >= totalT && totalT > 0;

    root.innerHTML = html`
      <div class="view-head">
        <div class="breadcrumbs">
          <a href="#/">${home.oposicion?.nombre || 'Inicio'}</a> /
          <a href="#/tema/${tema.id}">${tema.nombre}</a> /
          <strong>${modulo.nombre}</strong>
        </div>
      </div>
      <h2>${modulo.nombre}</h2>
      <p class="muted">${totalOk}/${totalT} secciones completadas.</p>

      ${raw((modulo.secciones || []).map(s => html`
        <div class="seccion-item ${s.completada ? 'completada' : ''}">
          <span class="seccion-titulo">${s.nombre}</span>
          ${s.nota_max != null ? html`<span class="muted small">Nota: ${Math.round(s.nota_max)}</span>` : ''}
          <span class="seccion-badge">${s.completada ? '✓ Completada' : 'Pendiente'}</span>
          <button class="btn btn-mini" data-teoria="${s.id}">Teoría</button>
          <button class="btn btn-pri btn-mini" data-test="${s.id}">Test</button>
        </div>
      `).join(''))}

      ${completado ? html`
        <button class="btn-repasar" id="btn-repaso-mod">🔁 Repasar todo el módulo</button>
      ` : ''}
    `;

    root.querySelectorAll('[data-teoria]').forEach(b => {
      b.onclick = () => navigate(`#/seccion/${b.dataset.teoria}/teoria`);
    });
    root.querySelectorAll('[data-test]').forEach(b => {
      b.onclick = () => navigate(`#/seccion/${b.dataset.test}/test`);
    });
    const btnRM = root.querySelector('#btn-repaso-mod');
    if (btnRM) {
      btnRM.onclick = async () => {
        try {
          const r = await S.rpc('iniciar_intento_modulo', { p_modulo_id: modId });
          _iniciarFlujoTest(r);
        } catch (e) { showToast(_msgError(e.message)); }
      };
    }
  }


  // ── Vista: teoría de una sección ───────────────────────────────────
  async function viewTeoria([seccId]) {
    loading();
    // Placeholder: obtener la ruta del documento y renderizar el markdown.
    // En MVP mostramos un aviso si el backend de contenido no está
    // preparado — la ruta real la resuelve el microservicio 'contenido/'.
    try {
      // TODO: RPC para obtener metadatos del documento por sección.
      const doc = await S.rpc('documento_de_seccion', { p_seccion_id: seccId })
        .catch(() => null);
      let md = '';
      if (doc && doc.ruta) md = await fetchMarkdown(doc.ruta);
      else md = '## Sin teoría todavía\n\nEsta sección no tiene documento de teoría subido.';

      // Marca la teoría como vista (idempotente).
      S.rpc('marcar_teoria_vista', { p_seccion_id: seccId }).catch(() => {});

      root.innerHTML = html`
        <div class="view-head">
          <div class="breadcrumbs"><a href="#/">Inicio</a> / Teoría</div>
        </div>
        <div class="teoria-body">${raw(renderMarkdown(md))}</div>
        <div class="teoria-cta">
          <button class="btn btn-pri" id="btn-test">📝 ¿Te examinas ahora?</button>
        </div>
      `;
      root.querySelector('#btn-test').onclick = () => navigate(`#/seccion/${seccId}/test`);
    } catch (e) {
      empty('No se pudo cargar la teoría: ' + e.message);
    }
  }


  // ── Vista: test de sección ─────────────────────────────────────────
  async function viewTestSeccion([seccId]) {
    loading();
    try {
      const r = await S.rpc('iniciar_intento_seccion', { p_seccion_id: seccId });
      _iniciarFlujoTest(r);
    } catch (e) {
      empty(_msgError(e.message));
    }
  }

  async function viewRepaso([opId]) {
    loading();
    try {
      const r = await S.rpc('iniciar_intento_repaso', { p_oposicion_id: opId, p_n: 40 });
      _iniciarFlujoTest(r);
    } catch (e) {
      empty(_msgError(e.message));
    }
  }


  // ── Flujo genérico de test (usado por sección/módulo/tema/repaso) ─
  async function _iniciarFlujoTest({ intento_id, question_ids }) {
    if (!intento_id) return empty('No se pudo iniciar el test.');
    const preguntas = await S.rpc('preguntas_de_intento', { p_intento_id: intento_id });
    if (!preguntas || preguntas.length === 0) return empty('El test no tiene preguntas.');

    const respuestas = new Map();  // pregunta_id → { opcion, correcta }
    let idx = 0;

    async function pintar() {
      const p = preguntas[idx];
      const dado = respuestas.get(p.id);
      root.innerHTML = html`
        <div class="test-progreso">
          <span>${idx + 1} / ${preguntas.length}</span>
          <div class="barra"><i style="width:${(idx / preguntas.length) * 100}%"></i></div>
        </div>
        <div class="pregunta">
          <div class="enunciado">${p.enunciado}</div>
          <div class="opciones">
            ${raw((p.opciones || []).map((o, i) => html`
              <button class="opcion" data-i="${i}"
                      ${dado ? 'disabled' : ''}
                      >${o.texto}</button>
            `).join(''))}
          </div>
          ${dado ? html`
            <div class="explicacion">
              ${dado.correcta ? '✓ Correcta.' : '✗ Incorrecta.'}
              ${p.explicacion ? html` — ${p.explicacion}` : ''}
            </div>
          ` : ''}
          <div style="margin-top:1rem; display:flex; gap:.5rem">
            <button class="btn" id="btn-prev" ${idx === 0 ? 'disabled' : ''}>← Anterior</button>
            ${idx < preguntas.length - 1
              ? '<button class="btn btn-pri" id="btn-next" style="margin-left:auto">Siguiente →</button>'
              : '<button class="btn btn-pri" id="btn-fin" style="margin-left:auto">Finalizar</button>'}
          </div>
        </div>
      `;
      if (dado) {
        // Marca visualmente correcta/incorrecta.
        root.querySelectorAll('.opcion').forEach((btn, i) => {
          const opt = p.opciones[i];
          if (opt.correcta)      btn.classList.add('correcta');
          else if (i === dado.i) btn.classList.add('mala');
        });
      } else {
        root.querySelectorAll('.opcion').forEach((btn, i) => {
          btn.onclick = () => elegir(p, i);
        });
      }
      const bp = root.querySelector('#btn-prev');
      if (bp) bp.onclick = () => { idx--; pintar(); };
      const bn = root.querySelector('#btn-next');
      if (bn) bn.onclick = () => { idx++; pintar(); };
      const bf = root.querySelector('#btn-fin');
      if (bf) bf.onclick = () => finalizar();
    }

    async function elegir(p, i) {
      const opt = p.opciones[i];
      const dado = { i, opcion: opt.texto, correcta: !!opt.correcta };
      respuestas.set(p.id, dado);
      try {
        await S.rpc('registrar_respuesta', {
          p_intento_id: intento_id, p_pregunta_id: p.id,
          p_opcion: opt.texto, p_correcta: !!opt.correcta,
        });
      } catch (e) { showToast('Fallo guardando respuesta: ' + e.message); }
      pintar();
    }

    async function finalizar() {
      loading();
      try {
        const r = await S.rpc('finalizar_intento', { p_intento_id: intento_id });
        _pintarResultado(r, intento_id);
      } catch (e) {
        empty('Error finalizando: ' + e.message);
      }
    }

    pintar();
  }

  function _pintarResultado(r, intentoId) {
    const nota = r.nota || 0;
    const pasa = nota >= 70;
    root.innerHTML = html`
      <div class="resultado-card">
        <div class="subt">Resultado</div>
        <div class="nota ${pasa ? 'pasa' : 'falla'}">${nota}</div>
        <div class="subt">${r.aciertos || 0}/${r.total || 0} aciertos</div>
        <div style="margin-top:1.5rem; display:flex; gap:.5rem; justify-content:center; flex-wrap:wrap">
          <button class="btn" onclick="location.hash='#/'">Volver al inicio</button>
          ${pasa
            ? '<button class="btn btn-pri" id="btn-repasar-otro">Repasar más</button>'
            : '<button class="btn btn-pri" id="btn-teoria">Repasar teoría</button>'}
        </div>
        ${!pasa ? '<p class="muted small" style="margin-top:1rem">Sugerimos revisar la teoría de las preguntas que has fallado antes de repetir.</p>' : ''}
      </div>
    `;
    const bt = root.querySelector('#btn-teoria');
    if (bt) bt.onclick = () => history.back();
    const br = root.querySelector('#btn-repasar-otro');
    if (br) br.onclick = () => location.hash = '#/';
  }


  // ── Vista: tablón (v1 mínimo, sólo enlaces) ───────────────────────
  async function viewTablon([opId]) {
    loading();
    try {
      const enlaces = await S.rpc('enlaces_de_oposicion', { p_oposicion_id: opId });
      if (!enlaces || enlaces.length === 0) {
        return root.innerHTML = html`
          <div class="view-head"><h2>Tablón</h2></div>
          <div class="empty">No hay enlaces publicados para esta oposición.</div>`;
      }
      root.innerHTML = html`
        <div class="view-head"><h2>Tablón — enlaces útiles</h2></div>
        ${raw(enlaces.map(e => html`
          <a class="modulo-row" href="${e.url}" target="_blank" rel="noopener">
            <span class="modulo-titulo">${e.titulo}</span>
            <span class="muted small">${e.tipo}</span>
            <span>↗</span>
          </a>
        `).join(''))}
      `;
    } catch (e) {
      empty(e.message);
    }
  }


  // ── Vista: mi cuenta (autoservicio) ────────────────────────────────
  async function viewMiCuenta() {
    loading();
    try {
      const me = await S.rpc('mi_cuenta');
      const ss = await S.rpc('mis_sesiones');
      root.innerHTML = html`
        <div class="view-head"><h2>Mi cuenta</h2></div>

        <div class="tema-card" style="cursor:default">
          <div><strong>Email:</strong> ${me.email}
            ${me.email_verificado ? '<span style="color:#4a8f2a">✓ verificado</span>'
                                  : '<span style="color:#b83a3a">— sin verificar</span>'}</div>
          <div><strong>Nombre:</strong> ${me.nombre_visible}</div>
          <div><strong>Roles:</strong> ${(me.roles || []).join(', ') || '—'}</div>
          <div><strong>2FA:</strong> ${me.totp_activo ? 'activo' : 'no configurado'}</div>
          <div><strong>Último acceso:</strong> ${me.ultimo_login_en || '—'}</div>
        </div>

        <h3>Cambiar contraseña</h3>
        <div class="tema-card" style="cursor:default">
          <form id="form-pass">
            <input class="input" name="actual" type="password" placeholder="Contraseña actual" required
                   style="width:100%;margin:.3rem 0">
            <input class="input" name="nueva" type="password" placeholder="Nueva contraseña (≥10 chars)" required
                   style="width:100%;margin:.3rem 0">
            <button class="btn btn-pri">Guardar</button>
            <div class="muted small" id="err-pass" style="color:#b83a3a;margin-top:.4rem"></div>
          </form>
        </div>

        <h3>Sesiones activas (${ss.length})</h3>
        <div class="tema-card" style="cursor:default">
          ${raw((ss || []).map(s => html`
            <div style="display:flex; gap:.5rem; padding:.4rem 0; border-bottom:1px solid var(--glass-border)">
              <div style="flex:1">
                <div>Emitida: ${new Date(s.emitida_en).toLocaleString()}</div>
                <div class="muted small">Expira: ${new Date(s.expira_en).toLocaleDateString()}</div>
              </div>
              ${s.actual ? '<span class="seccion-badge">Esta sesión</span>'
                        : `<button class="btn btn-mini" data-jti="${s.jti}">Revocar</button>`}
            </div>
          `).join(''))}
          <div style="margin-top:1rem; display:flex; gap:.5rem">
            <button class="btn" id="btn-logout-global">Cerrar TODAS las sesiones</button>
          </div>
        </div>

        <h3 style="color:#b83a3a">Zona peligrosa</h3>
        <div class="tema-card" style="cursor:default; border-color:#b83a3a">
          <p class="muted small">Borrar tu cuenta es irreversible. Se anonimiza tu email y nombre; tu progreso se pierde.</p>
          <button class="btn" id="btn-borrar" style="background:#b83a3a; color:white">Borrar mi cuenta</button>
        </div>
      `;

      root.querySelector('#form-pass').onsubmit = async (e) => {
        e.preventDefault();
        const f = new FormData(e.target);
        try {
          await S.rpc('cambiar_password', { p_actual: f.get('actual'), p_nueva: f.get('nueva') });
          showToast('Contraseña actualizada. Se han cerrado las demás sesiones.');
          viewMiCuenta();
        } catch (err) {
          root.querySelector('#err-pass').textContent = _msgError(err.message);
        }
      };
      root.querySelectorAll('[data-jti]').forEach(b => {
        b.onclick = async () => {
          await S.rpc('revocar_sesion', { p_jti: b.dataset.jti });
          viewMiCuenta();
        };
      });
      root.querySelector('#btn-logout-global').onclick = async () => {
        if (!confirm('¿Cerrar TODAS las sesiones (incluida esta)?')) return;
        await S.rpc('logout_global');
        await S.logout();
        navigate('#/login');
      };
      root.querySelector('#btn-borrar').onclick = async () => {
        const p = prompt('Escribe tu contraseña para confirmar el borrado:');
        if (!p) return;
        try {
          await S.rpc('borrar_mi_cuenta', { p_password: p });
          S.clear();
          alert('Cuenta borrada.');
          navigate('#/login');
        } catch (err) { showToast(_msgError(err.message)); }
      };
    } catch (e) {
      empty(e.message);
    }
  }


  // ── Vista: admin/usuarios ──────────────────────────────────────────
  async function viewAdminUsuarios(_, params) {
    const u = S.getUser();
    if (!u || !(u.roles || []).includes('admin')) return empty('Acceso restringido.');
    loading();
    const q = params.get('q') || '';
    const page = +(params.get('page') || 1);
    const rs = await S.rpc('listar_usuarios', { p_q: q || null, p_page: page, p_size: 20 });
    const [ROLES, ...restRoles] = [await S.rpc('listar_roles')];  // avoid var shadow

    root.innerHTML = html`
      <div class="view-head"><h2>Administración de usuarios</h2></div>
      <form id="form-search" style="margin-bottom:1rem; display:flex; gap:.5rem">
        <input class="input" name="q" value="${q}" placeholder="Buscar por email o nombre"
               style="flex:1">
        <button class="btn btn-pri">Buscar</button>
      </form>
      <div class="muted small">Total: ${rs.total} — página ${rs.page}/${rs.total_pages}</div>
      ${raw((rs.usuarios || []).map(u => html`
        <div class="tema-card" style="cursor:default" data-uid="${u.id}">
          <div style="display:flex; align-items:baseline; gap:.5rem; flex-wrap:wrap">
            <strong>${u.nombre_visible}</strong>
            <span class="muted small">${u.email}</span>
            ${u.email_verificado ? '<span style="color:#4a8f2a">✓</span>' : '<span style="color:#b83a3a">sin verificar</span>'}
            ${u.totp_activo ? '<span class="seccion-badge">2FA</span>' : ''}
            ${!u.activo ? '<span class="seccion-badge" style="background:#b83a3a;color:white">DESACTIVADO</span>' : ''}
          </div>
          <div class="muted small" style="margin-top:.3rem">
            Último login: ${u.ultimo_login_en || '—'} · Sesiones activas: ${u.sesiones_activas} ·
            Roles: ${(u.roles || []).join(', ') || '—'}
          </div>
          <div style="margin-top:.6rem; display:flex; gap:.4rem; flex-wrap:wrap">
            <button class="btn btn-mini" data-act="reset">Enviar reset pass</button>
            <button class="btn btn-mini" data-act="logout">Forzar logout global</button>
            <button class="btn btn-mini" data-act="toggle-activo">${u.activo ? 'Desactivar' : 'Activar'}</button>
            <button class="btn btn-mini" data-act="roles">Editar roles</button>
            <button class="btn btn-mini" data-act="borrar" style="color:#b83a3a">Borrar</button>
          </div>
        </div>
      `).join(''))}
    `;

    root.querySelector('#form-search').onsubmit = (e) => {
      e.preventDefault();
      const nq = new FormData(e.target).get('q');
      navigate(`#/admin/usuarios?q=${encodeURIComponent(nq)}`);
    };

    root.querySelectorAll('.tema-card[data-uid]').forEach(card => {
      const uid = card.dataset.uid;
      card.querySelectorAll('[data-act]').forEach(btn => {
        btn.onclick = async () => {
          const act = btn.dataset.act;
          try {
            if (act === 'reset') {
              await S.rpc('forzar_reset_password', { p_usuario_id: uid });
              showToast('Reset enviado por email.');
            } else if (act === 'logout') {
              await S.rpc('forzar_logout_global', { p_usuario_id: uid });
              showToast('Sesiones revocadas.');
            } else if (act === 'toggle-activo') {
              const u = (rs.usuarios || []).find(x => x.id === uid);
              await S.rpc('set_usuario_activo', { p_usuario_id: uid, p_activo: !u.activo });
              viewAdminUsuarios(_, params);
            } else if (act === 'roles') {
              const actuales = (rs.usuarios || []).find(x => x.id === uid)?.roles || [];
              const nombres = (ROLES || []).map(r => r.id).join(', ');
              const nuevos = prompt(
                `Roles disponibles: ${nombres}\nActuales: ${actuales.join(', ') || '—'}\n\nEscribe la nueva lista separada por comas:`,
                actuales.join(', '));
              if (nuevos === null) return;
              const setNuevos = new Set(nuevos.split(',').map(s => s.trim()).filter(Boolean));
              const setActuales = new Set(actuales);
              for (const r of setNuevos) if (!setActuales.has(r))
                await S.rpc('asignar_rol', { p_usuario_id: uid, p_rol_id: r });
              for (const r of setActuales) if (!setNuevos.has(r))
                await S.rpc('quitar_rol', { p_usuario_id: uid, p_rol_id: r });
              viewAdminUsuarios(_, params);
            } else if (act === 'borrar') {
              if (!confirm('¿Borrar la cuenta? Esta acción es irreversible (soft-delete).')) return;
              await S.rpc('borrar_usuario_admin', { p_usuario_id: uid });
              viewAdminUsuarios(_, params);
            }
          } catch (e) { showToast(_msgError(e.message)); }
        };
      });
    });
  }


  // ── Vista: admin/duplicados ────────────────────────────────────────
  async function viewAdminDuplicados() {
    const u = S.getUser();
    if (!u || !((u.roles || []).includes('admin') || (u.roles || []).includes('editor')))
      return empty('Acceso restringido.');
    loading();
    const rs = await S.rpc('listar_propuestas_fusion', { p_page: 1, p_size: 30 });
    root.innerHTML = html`
      <div class="view-head"><h2>Preguntas duplicadas — propuestas</h2></div>
      <div class="muted small">Pendientes: ${rs.total}</div>
      ${raw((rs.items || []).map(p => html`
        <div class="tema-card" style="cursor:default" data-a="${p.a.id}" data-b="${p.b.id}">
          <div class="muted small">Similitud: ${(p.similitud * 100).toFixed(1)}%</div>
          <div style="margin-top:.4rem"><strong>A:</strong> ${p.a.enunciado}</div>
          <div style="margin-top:.4rem"><strong>B:</strong> ${p.b.enunciado}</div>
          <div style="margin-top:.6rem; display:flex; gap:.4rem; flex-wrap:wrap">
            <button class="btn btn-mini" data-act="keep-a">Conservar A, borrar B</button>
            <button class="btn btn-mini" data-act="keep-b">Conservar B, borrar A</button>
            <button class="btn btn-mini" data-act="descartar">Descartar (no son iguales)</button>
          </div>
        </div>
      `).join(''))}
      ${(rs.items || []).length === 0 ? '<div class="empty">No hay duplicados pendientes.</div>' : ''}
    `;

    root.querySelectorAll('.tema-card[data-a]').forEach(card => {
      const a = card.dataset.a, b = card.dataset.b;
      card.querySelectorAll('[data-act]').forEach(btn => {
        btn.onclick = async () => {
          try {
            if (btn.dataset.act === 'keep-a')
              await S.rpc('fusionar_propuesta', { p_a_id: a, p_b_id: b, p_keep: 'a' });
            else if (btn.dataset.act === 'keep-b')
              await S.rpc('fusionar_propuesta', { p_a_id: a, p_b_id: b, p_keep: 'b' });
            else
              await S.rpc('descartar_propuesta', { p_a_id: a, p_b_id: b });
            card.remove();
          } catch (e) { showToast(_msgError(e.message)); }
        };
      });
    });
  }


  // ── Vista: estadísticas (placeholder) ──────────────────────────────
  async function viewEstadisticas() {
    root.innerHTML = html`
      <div class="view-head"><h2>Estadísticas</h2></div>
      <div class="empty">
        <p>Próximamente: tu progreso global, mejores y peores secciones,
           gráficas de aciertos y racha.</p>
      </div>`;
  }


  // ── Bootstrap ──────────────────────────────────────────────────────

  window.addEventListener('aprentix:nav', (e) => {
    const id = e.detail?.id;
    if (id === 'home')          navigate('#/');
    if (id === 'estadisticas')  navigate('#/estadisticas');
    if (id === 'tablon') {
      const op = getCtx().oposicion_id;
      if (op) navigate(`#/tablon/${op}`);
      else showToast('Elige primero una oposición.');
    }
  });

  // El sheet del avatar dispara clicks por data-view; los cazamos aquí.
  document.addEventListener('click', (e) => {
    const el = e.target.closest('[data-view]');
    if (!el) return;
    const v = el.dataset.view;
    if (v === 'home')             navigate('#/');
    if (v === 'estadisticas')     navigate('#/estadisticas');
    if (v === 'mi-cuenta')        navigate('#/mi-cuenta');
    if (v === 'admin-usuarios')   navigate('#/admin/usuarios');
    if (v === 'admin-duplicados') navigate('#/admin/duplicados');
  });

  (async function main() {
    // Rehidratación silenciosa: si hay refresh, obtiene un access nuevo.
    await S.bootstrap();
    if (!location.hash) location.hash = '#/';
    else _render();
  })();
})();
