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
  const appHeader = document.getElementById('app-header');

  // Vistas "públicas" que se pintan sin cabecera (login, reset, verify): la
  // XP, la racha y el avatar sólo tienen sentido con sesión iniciada.
  function setHeaderVisible(visible) {
    if (!appHeader) return;
    appHeader.hidden = !visible;
    document.body.classList.toggle('no-header', !visible);
  }

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
    // Template helper: escapa valores por defecto. Reconoce como HTML "en
    // crudo" tanto los marcadores devueltos por raw() como los resultados
    // de otro html`` anidado (String objeto con __raw = true), para que un
    // `${x ? html`<i>…</i>` : ''}` no salga escapado a texto plano.
    let out = '';
    strings.forEach((s, i) => {
      out += s;
      if (i < values.length) {
        const v = values[i];
        if (v && v.__raw) {
          out += (v.value !== undefined) ? v.value : String(v);
        } else {
          out += esc(v);
        }
      }
    });
    const result = new String(out);
    result.__raw = true;
    return result;
  }
  const raw = (v) => ({ __raw: true, value: (v && v.__raw) ? String(v) : String(v ?? '') });

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

  // Modal ligero. `contenido` es HTML ya escapado (usa el template html``).
  // `onMount(modalEl)` corre tras insertar; devuelve foco al primer input.
  function _mostrarModal({ titulo, contenido, onMount, onClose }) {
    _cerrarModal();
    const back = document.createElement('div');
    back.className = 'aprentix-modal-back';
    back.innerHTML = `
      <div class="aprentix-modal" role="dialog" aria-modal="true" aria-label="${esc(titulo || '')}">
        <div class="modal-head">
          <h3>${esc(titulo || '')}</h3>
          <button class="modal-close" aria-label="Cerrar">✕</button>
        </div>
        <div class="modal-body">${contenido || ''}</div>
      </div>`;
    document.body.appendChild(back);
    const close = () => { _cerrarModal(); if (onClose) onClose(); };
    back.querySelector('.modal-close').onclick = close;
    back.addEventListener('click', (e) => { if (e.target === back) close(); });
    document.addEventListener('keydown', _mostrarModal._esc = (e) => {
      if (e.key === 'Escape') close();
    });
    if (onMount) onMount(back.querySelector('.aprentix-modal'));
    // Foco al primer control focusable.
    const first = back.querySelector('input,textarea,select,button:not(.modal-close)');
    if (first) first.focus();
  }
  function _cerrarModal() {
    document.querySelectorAll('.aprentix-modal-back').forEach(n => n.remove());
    if (_mostrarModal._esc) {
      document.removeEventListener('keydown', _mostrarModal._esc);
      _mostrarModal._esc = null;
    }
  }

  // Tema (light/dark). La cookie `aprentix_theme` la lee el pre-render en
  // index.html para evitar el "flash" al cargar; aquí sólo la mantenemos.
  const THEME_COOKIE = 'aprentix_theme';
  function getTheme() {
    const m = document.cookie.match(/(?:^|;\s*)aprentix_theme=(dark|light|system)/);
    return m ? m[1] : 'system';
  }
  function setTheme(t) {
    document.cookie = `${THEME_COOKIE}=${t}; path=/; max-age=${60*60*24*365}; SameSite=Lax`;
    const effective = t === 'system'
      ? (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')
      : t;
    if (effective === 'dark') document.documentElement.setAttribute('data-theme', 'dark');
    else document.documentElement.removeAttribute('data-theme');
  }

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
    { re: /^\/elegir-oposicion$/,            view: viewElegirOposicion },
    { re: /^\/admin\/usuarios$/,             view: viewAdminUsuarios },
    { re: /^\/admin\/duplicados$/,           view: viewAdminDuplicados },
    { re: /^\/admin\/contenido$/,                              view: viewAdminOposiciones },
    { re: /^\/admin\/contenido\/oposicion\/([0-9a-f-]+)$/,     view: viewAdminOposicion },
    { re: /^\/admin\/contenido\/tema\/([0-9a-f-]+)$/,          view: viewAdminTema },
    { re: /^\/admin\/contenido\/modulo\/([0-9a-f-]+)$/,        view: viewAdminModulo },
    { re: /^\/admin\/contenido\/seccion\/([0-9a-f-]+)$/,       view: viewAdminSeccion },
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

    // La cabecera con XP/racha/avatar sólo aparece cuando hay sesión y
    // no estamos en una vista pública de auth. En login/reset/verify la
    // ocultamos para dejar todo el foco en el formulario.
    const publicView = ['/login', '/reset', '/verify'].includes(path);
    setHeaderVisible(!!S.getUser() && !publicView);

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
  // Delegamos toda la UI en <ap-auth-form>, un web component compartido
  // que ya trae la estética solarpunk (hero con logo, gradientes de marca,
  // indicador de fortaleza, aviso de coincidencia de email y contraseña).
  // Aquí sólo cableamos los eventos que emite hacia las RPC de sesión.
  function viewLogin(_, params) {
    const initial = params.get('mode') || 'login';
    root.innerHTML = `
      <section class="auth-section">
        <ap-auth-form mode="${esc(initial)}"></ap-auth-form>
      </section>
    `;
    const form = root.querySelector('ap-auth-form');

    form.addEventListener('ap-auth-login', async (e) => {
      const { email, password } = e.detail;
      try {
        await S.login(email, password);
        form.reset();
        navigate('#/');
      } catch (err) {
        form.showError(_msgError(err.message), 'login');
      }
    });

    form.addEventListener('ap-auth-register', async (e) => {
      const { email, password, nombre_visible } = e.detail;
      try {
        const r = await S.registrar(email, password, nombre_visible);
        form.showInfo(r.mensaje || 'Cuenta creada. Revisa tu correo para verificarla antes de entrar.', 'register');
        showToast('Cuenta creada. Revisa tu correo para verificar.', 5000);
        setTimeout(() => form.setMode('login'), 1500);
      } catch (err) {
        form.showError(_msgError(err.message), 'register');
      }
    });

    form.addEventListener('ap-auth-forgot', async (e) => {
      const { email } = e.detail;
      try {
        const r = await S.solicitarReset(email);
        form.showInfo(r.mensaje || 'Si el email existe, recibirás un correo con el enlace de reset.', 'forgot');
      } catch (err) {
        form.showError(_msgError(err.message), 'forgot');
      }
    });
  }

  function _msgError(code) {
    return ({
      credenciales_invalidas: 'Email o contraseña incorrectos.',
      cuenta_bloqueada:       'Cuenta bloqueada temporalmente por intentos fallidos.',
      email_no_verificado:    'Tienes que verificar tu email antes de entrar.',
      password_debil:         'La contraseña no cumple la política (≥10 caracteres y 3 de 4 categorías).',
      email_invalido:         'Email inválido.',
      email_en_uso:           'Ya existe una cuenta con ese email.',
      nombre_visible_invalido:'El nombre debe tener al menos 2 caracteres.',
      token_invalido:         'El enlace ha caducado o ya se usó.',
      no_autenticado:         'Sesión caducada. Vuelve a entrar.',
    })[code] || code;
  }


  // ── Vista: verificar email ─────────────────────────────────────────
  async function viewVerify(_, params) {
    const token = params.get('token');
    if (!token) return _authCard('Enlace inválido', 'El token de verificación falta o está mal formado.');
    root.innerHTML = _authCardHtml('Verificando email', '<p class="tagline">Un momento…</p>');
    try {
      await S.verificarEmail(token);
      root.innerHTML = _authCardHtml(
        'Cuenta confirmada correctamente',
        `<p class="info" style="display:block">Tu correo ha quedado verificado.
         Ya puedes iniciar sesión con tu contraseña.</p>
         <button class="btn btn-primary" id="btn-goto-login" style="width:100%">Iniciar sesión</button>`
      );
      root.querySelector('#btn-goto-login').onclick = () => navigate('#/login');
    } catch (e) {
      root.innerHTML = _authCardHtml(
        'Enlace no válido',
        `<p class="err" style="display:block">${esc(_msgError(e.message))}</p>
         <button class="btn btn-primary" id="btn-goto-login" style="width:100%">Volver al inicio de sesión</button>`
      );
      root.querySelector('#btn-goto-login').onclick = () => navigate('#/login');
    }
  }


  // ── Vista: reset password ──────────────────────────────────────────
  async function viewReset(_, params) {
    const token = params.get('token');
    if (!token) {
      root.innerHTML = _authCardHtml(
        'Enlace inválido',
        `<p class="err" style="display:block">El enlace de recuperación no es válido.</p>
         <button class="btn btn-primary" id="btn-goto-login" style="width:100%">Volver</button>`
      );
      root.querySelector('#btn-goto-login').onclick = () => navigate('#/login');
      return;
    }
    root.innerHTML = _authCardHtml(
      'Nueva contraseña',
      `<p class="tagline">Elige una contraseña fuerte (mínimo 10 caracteres).</p>
       <form id="form-reset" autocomplete="off" novalidate>
         <label>Nueva contraseña
           <input id="reset-pass" name="nueva" type="password"
                  autocomplete="new-password" minlength="10" required>
         </label>
         <label>Repite la contraseña
           <input id="reset-pass2" name="nueva2" type="password"
                  autocomplete="new-password" minlength="10" required>
         </label>
         <p class="pw-match" id="reset-match" hidden></p>
         <button class="btn btn-primary" type="submit" style="width:100%">Guardar contraseña</button>
         <p class="err" id="reset-err" hidden></p>
       </form>`
    );
    const $ = (s) => root.querySelector(s);
    const p1 = $('#reset-pass'), p2 = $('#reset-pass2'), match = $('#reset-match');
    function refreshMatch() {
      if (!p2.value) { match.hidden = true; return; }
      match.hidden = false;
      if (p1.value === p2.value) {
        match.textContent = '✓ Las contraseñas coinciden';
        match.classList.remove('err'); match.classList.add('ok');
      } else {
        match.textContent = '✗ No coinciden';
        match.classList.remove('ok'); match.classList.add('err');
      }
    }
    p1.oninput = refreshMatch;
    p2.oninput = refreshMatch;

    $('#form-reset').onsubmit = async (e) => {
      e.preventDefault();
      $('#reset-err').hidden = true;
      if (p1.value !== p2.value) {
        $('#reset-err').textContent = 'Las contraseñas no coinciden.';
        $('#reset-err').hidden = false;
        return;
      }
      try {
        await S.resetearPassword(token, p1.value);
        showToast('Contraseña actualizada. Ya puedes entrar.', 4000);
        navigate('#/login');
      } catch (err) {
        $('#reset-err').textContent = _msgError(err.message);
        $('#reset-err').hidden = false;
      }
    };
  }

  // Envoltura común: tarjeta solarpunk sin formulario, útil para pantallas
  // "de estado" (verificar email, reset OK/KO, enlace inválido…).
  function _authCardHtml(titulo, cuerpo) {
    return `
      <section class="auth-section">
        <div class="auth-card">
          <div class="auth-hero">
            <span class="brand-logo" aria-hidden="true"></span>
            <h1>Aprentix</h1>
            <p class="tagline">${esc(titulo)}</p>
          </div>
          <div class="auth-panel active">${cuerpo}</div>
        </div>
      </section>`;
  }
  function _authCard(titulo, mensaje) {
    root.innerHTML = _authCardHtml(titulo, `<p class="err" style="display:block">${esc(mensaje)}</p>`);
  }


  // ── Vista: home ────────────────────────────────────────────────────
  async function viewHome() {
    loading();
    // Averigua la oposición activa: preferencia local, o la primera del usuario.
    let opId = getCtx().oposicion_id;
    // Siempre pedimos la lista al backend para poder validar la preferida y
    // detectar el caso "primer login sin oposición".
    const list = await _misOposiciones();
    if (opId && !list.some(o => o.id === opId)) opId = null;   // stale ctx
    if (!opId && list.length) opId = list[0].id;
    if (!opId) {
      // Primer login (o borrado de sus oposiciones): mandamos al picker.
      navigate('#/elegir-oposicion');
      return;
    }
    setCtx({ oposicion_id: opId });

    const home = await S.rpc('mi_home_oposicion', { p_oposicion_id: opId });
    const op = home.oposicion || {};
    const temas = home.temas || [];

    const admin = _esAdmin();
    root.innerHTML = html`
      <button class="oposicion-picker" id="btn-cambiar-op">
        <span>📚</span>
        <span>${op.nombre || 'Elige una oposición'}</span>
        <span class="caret">▾</span>
      </button>
      ${raw(temas.length > 0
        ? '<button class="btn-repasar" id="btn-repasar-op">🔁 Repasar toda la oposición (40 preguntas)</button>'
        : '')}
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
      ${raw(temas.length === 0
        ? (admin
            ? html`
              <div class="empty">
                <p>Esta oposición aún no tiene temas asignados.</p>
                <button class="btn btn-pri" id="btn-gestionar-op">
                  ➕ Añadir temas desde el panel admin
                </button>
              </div>`
            : '<div class="empty">Esta oposición aún no tiene temas asignados.</div>')
        : '')}
    `;

    root.querySelectorAll('.tema-card').forEach(c => {
      c.onclick = () => navigate(`#/tema/${c.dataset.tema}`);
    });
    const btnR = root.querySelector('#btn-repasar-op');
    if (btnR) btnR.onclick = () => navigate(`#/repaso/${opId}`);
    root.querySelector('#btn-cambiar-op').onclick = () => _abrirSelectorOposicion();
    const btnG = root.querySelector('#btn-gestionar-op');
    if (btnG) btnG.onclick = () => navigate(`#/admin/contenido/oposicion/${opId}`);
  }

  // Devuelve `mis_oposiciones` como un array simple.
  async function _misOposiciones() {
    const rs = await S.rpc('mis_oposiciones').catch(() => []);
    const list = rs?.oposiciones || rs || [];
    return Array.isArray(list) ? list : [];
  }

  // Abre el picker "cambiar oposición". Siempre modal — así el botón
  // "Añadir otra oposición" queda visible aunque el usuario solo tenga una;
  // antes le mandábamos directo a #/elegir-oposicion y, si terminaba
  // apuntándose a la misma que ya tenía, parecía que "no había pasado nada"
  // (volvía a home sin feedback).
  async function _abrirSelectorOposicion() {
    const list = await _misOposiciones();
    if (list.length === 0) {
      navigate('#/elegir-oposicion');
      return;
    }
    const actual = getCtx().oposicion_id;
    _mostrarModal({
      titulo: 'Tus oposiciones',
      contenido: html`
        <div class="form-grid">
          ${raw(list.map(o => html`
            <button class="op-tile ${actual === o.id ? 'selected' : ''}"
                    type="button" data-opid="${o.id}">
              <span class="ico">📚</span>
              <strong>${o.nombre}</strong>
              ${raw(actual === o.id ? '<div class="desc"><em>✓ Activa</em></div>' : '')}
              ${o.descripcion ? html`<div class="desc">${o.descripcion}</div>` : ''}
            </button>
          `).join(''))}
          <button class="btn btn-pri" id="btn-add-op" type="button">➕ Añadir otra oposición</button>
        </div>`,
      onMount(modal) {
        modal.querySelectorAll('[data-opid]').forEach(b => {
          b.onclick = () => {
            const nueva = b.dataset.opid;
            _cerrarModal();
            if (nueva === actual) return;                // sin cambios reales
            setCtx({ oposicion_id: nueva });
            navigate('#/');
          };
        });
        modal.querySelector('#btn-add-op').onclick = () => {
          _cerrarModal();
          navigate('#/elegir-oposicion');
        };
      },
    });
  }


  // ── Vista: elegir oposición (primer login o "añadir otra") ────────
  async function viewElegirOposicion() {
    loading();
    const disp = await S.rpc('listar_oposiciones_disponibles')
      .catch((e) => {
        console.error('listar_oposiciones_disponibles falló:', e);
        return [];
      });
    const list = Array.isArray(disp) ? disp : [];
    const mias = await _misOposiciones();
    const misIds = new Set(mias.map(o => o.id));

    // Solo pedimos el solapamiento para oposiciones que el usuario NO tiene ya
    // asignadas. Ninguna de estas llamadas es crítica: si fallan, el tile
    // sigue apareciendo, solo sin la banda "tienes X% estudiado".
    const solapadas = new Map();
    if (mias.length > 0) {
      await Promise.all(list
        .filter(o => !misIds.has(o.id))
        .map(o => S.rpc('sugerir_solapamiento', { p_oposicion_id: o.id })
          .then(r => { if (r && r.total > 0 && r.pct > 0) solapadas.set(o.id, r); })
          .catch(() => {})));
    }

    root.innerHTML = html`
      <div class="view-head">
        <h2>${mias.length === 0 ? '¡Bienvenida!' : 'Añadir otra oposición'}</h2>
      </div>
      <p class="muted" style="margin-top:-.5rem">
        ${mias.length === 0
          ? '¿A qué oposición te presentas? Puedes cambiarla o añadir más desde tu cuenta.'
          : 'Selecciona cualquier oposición del catálogo para sumarla a tu plan.'}
      </p>
      ${raw(list.length === 0
        ? (_esAdmin()
            ? html`
              <div class="empty">
                <p>Aún no hay oposiciones publicadas.</p>
                <button class="btn btn-pri" id="btn-goto-admin">➕ Crear la primera oposición</button>
              </div>`
            : '<div class="empty">Aún no hay oposiciones publicadas. Vuelve más tarde o pregúntale al admin.</div>')
        : html`
          <div class="op-grid">
            ${raw(list.map(o => {
              const yaLaTiene = misIds.has(o.id);
              const sol = solapadas.get(o.id);
              return html`
              <button class="op-tile ${yaLaTiene ? 'selected disabled' : ''}"
                      type="button" data-opid="${o.id}"
                      data-yatiene="${yaLaTiene ? '1' : ''}"
                      ${raw(yaLaTiene ? 'aria-current="true"' : '')}>
                <span class="ico">📚</span>
                <strong>${o.nombre}</strong>
                ${raw(o.descripcion ? html`<div class="desc">${o.descripcion}</div>` : '')}
                ${raw(yaLaTiene
                  ? '<div class="desc" style="margin-top:.4rem"><em>✓ Ya la tienes</em></div>'
                  : (sol
                      ? html`<div class="desc" style="margin-top:.4rem"><em>Tienes estudiado un ${sol.pct}% del temario. ¡Apúntate!</em></div>`
                      : ''))}
              </button>`;
            }).join(''))}
          </div>`)}
      ${raw(mias.length > 0
        ? '<div style="margin-top:1rem"><button class="btn" id="btn-volver">← Volver al inicio</button></div>'
        : '')}
    `;
    root.querySelectorAll('[data-opid]').forEach(b => {
      b.onclick = async () => {
        if (b.dataset.yatiene) {
          // Al reclicar una que ya tienes, la fijamos como activa y volvemos
          // al home sin llamar al RPC. Sin este atajo el flujo se veía como
          // "click → toast → home" y parecía que no había hecho nada nuevo.
          setCtx({ oposicion_id: b.dataset.opid });
          showToast('Esta oposición ya está en tu plan.');
          navigate('#/');
          return;
        }
        try {
          await S.rpc('elegir_oposicion', { p_oposicion_id: b.dataset.opid });
          setCtx({ oposicion_id: b.dataset.opid });
          showToast('¡Oposición añadida!');
          navigate('#/');
        } catch (e) {
          showToast('No se pudo añadir la oposición: ' + _msgError(e.message), 4000);
        }
      };
    });
    const bv = root.querySelector('#btn-volver');
    if (bv) bv.onclick = () => navigate('#/');
    const bg = root.querySelector('#btn-goto-admin');
    if (bg) bg.onclick = () => navigate('#/admin/contenido');
  }


  // Atajo booleano para saber si la sesión actual tiene rol admin. Combina
  // dos fuentes: el JWT (rápido) y una copia refrescada del rol vía
  // `mi_cuenta` (que puede diferir del JWT si el admin te añadió el rol
  // después de que iniciaras sesión). Si en la última carga de `mi_cuenta`
  // aparecía 'admin', lo tratamos como admin aunque el JWT aún no lo diga.
  let _lastFreshRoles = null;
  async function _refreshLocalRoles() {
    try {
      const me = await S.rpc('mi_cuenta');
      _lastFreshRoles = Array.isArray(me.roles) ? me.roles : null;
    } catch (_) { /* ignoramos */ }
  }
  function _esAdmin() {
    const u = S.getUser();
    const jwtAdmin = !!(u && Array.isArray(u.roles) && u.roles.includes('admin'));
    const freshAdmin = !!(Array.isArray(_lastFreshRoles) && _lastFreshRoles.includes('admin'));
    return jwtAdmin || freshAdmin;
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
          ${raw(idx < preguntas.length - 1
              ? '<button class="btn btn-pri" id="btn-next" style="margin-left:auto">Siguiente →</button>'
              : '<button class="btn btn-pri" id="btn-fin" style="margin-left:auto">Finalizar</button>')}
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
          ${raw(pasa
            ? '<button class="btn btn-pri" id="btn-repasar-otro">Repasar más</button>'
            : '<button class="btn btn-pri" id="btn-teoria">Repasar teoría</button>')}
        </div>
        ${raw(!pasa ? '<p class="muted small" style="margin-top:1rem">Sugerimos revisar la teoría de las preguntas que has fallado antes de repetir.</p>' : '')}
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
      const mias = await _misOposiciones().catch(() => []);
      const tema = getTheme();

      root.innerHTML = html`
        <div class="view-head"><h2>Mi cuenta</h2></div>

        <div class="panel-card">
          <h3 class="card-title"><span class="ico">👤</span> Datos de la cuenta</h3>
          <dl class="kv-list">
            <dt>Email</dt>
            <dd>${me.email}
              ${raw(me.email_verificado
                ? '<span class="kv-badge ok">verificado</span>'
                : '<span class="kv-badge warn">sin verificar</span>')}</dd>
            <dt>Nombre</dt><dd>${me.nombre_visible || '—'}</dd>
            <dt>Roles</dt><dd>${(me.roles || []).join(', ') || '—'}</dd>
            <dt>2FA</dt><dd>${raw(me.totp_activo
              ? '<span class="kv-badge ok">activo</span>'
              : 'no configurado')}</dd>
            <dt>Último acceso</dt><dd>${me.ultimo_login_en
              ? new Date(me.ultimo_login_en).toLocaleString()
              : '—'}</dd>
            <dt>Miembra desde</dt><dd>${me.creado_en
              ? new Date(me.creado_en).toLocaleDateString()
              : '—'}</dd>
          </dl>
        </div>

        <div class="panel-card">
          <h3 class="card-title"><span class="ico">🎨</span> Apariencia</h3>
          <p class="card-subtitle">Elige el aspecto de la aplicación.</p>
          <div class="seg-group" role="radiogroup" aria-label="Tema visual">
            <button type="button" data-theme="light"  class="${tema==='light'?'active':''}">☀️ Claro</button>
            <button type="button" data-theme="dark"   class="${tema==='dark' ?'active':''}">🌙 Oscuro</button>
            <button type="button" data-theme="system" class="${tema==='system'?'active':''}">🖥️ Sistema</button>
          </div>
        </div>

        <div class="panel-card">
          <h3 class="card-title"><span class="ico">📚</span> Mis oposiciones</h3>
          ${raw(mias.length
            ? html`
              <div class="form-grid">
                ${raw(mias.map(o => html`
                  <div class="sesion-row" data-op-mine="${o.id}">
                    <div class="grow">
                      <div><strong>${o.nombre}</strong></div>
                      ${raw(o.descripcion ? html`<div class="small">${o.descripcion}</div>` : '')}
                    </div>
                    <button class="btn btn-sm" data-act="ir">Ir</button>
                    <button class="btn btn-sm" data-act="quitar">Quitar</button>
                  </div>
                `).join(''))}
              </div>`
            : '<p class="card-subtitle">Aún no te has apuntado a ninguna oposición.</p>')}
          <div class="form-row" style="margin-top:.75rem">
            <button class="btn btn-pri btn-sm" id="btn-add-op">➕ Añadir oposición</button>
          </div>
        </div>

        <div class="panel-card">
          <h3 class="card-title"><span class="ico">🔒</span> Cambiar contraseña</h3>
          <form id="form-pass" class="form-grid" autocomplete="off">
            <div class="field">
              <label for="pw-actual">Contraseña actual</label>
              <input id="pw-actual" name="actual" type="password" autocomplete="current-password" required>
            </div>
            <div class="field">
              <label for="pw-nueva">Nueva contraseña</label>
              <input id="pw-nueva" name="nueva" type="password" minlength="10"
                     autocomplete="new-password" required>
              <small class="small" style="color:var(--txt-soft)">Mínimo 10 caracteres.</small>
            </div>
            <div class="form-err" id="err-pass" hidden></div>
            <div class="form-row">
              <button class="btn btn-pri" type="submit">Guardar contraseña</button>
            </div>
          </form>
        </div>

        <div class="panel-card">
          <h3 class="card-title"><span class="ico">💻</span> Sesiones activas
            <span class="kv-badge">${(ss || []).length}</span></h3>
          ${raw((ss || []).map(s => html`
            <div class="sesion-row">
              <div class="grow">
                <div>Emitida: ${new Date(s.emitida_en).toLocaleString()}</div>
                <div class="small">Expira: ${new Date(s.expira_en).toLocaleDateString()}</div>
              </div>
              ${raw(s.actual
                ? '<span class="badge-actual">Esta sesión</span>'
                : `<button class="btn btn-sm" data-jti="${esc(s.jti)}">Revocar</button>`)}
            </div>
          `).join(''))}
          <div class="form-row" style="margin-top:.75rem">
            <button class="btn btn-danger-outline btn-sm" id="btn-logout-global">
              Cerrar TODAS las sesiones
            </button>
          </div>
        </div>

        <h3 class="panel-section-title danger">Zona peligrosa</h3>
        <div class="panel-card zona-peligro">
          <h3 class="card-title"><span class="ico">⚠️</span> Borrar mi cuenta</h3>
          <p class="small">Esta acción es irreversible. Anonimizamos tu email y nombre;
             se cierran todas tus sesiones y se pierde tu progreso.</p>
          <div class="form-row">
            <button class="btn btn-danger btn-sm" id="btn-borrar">Borrar mi cuenta…</button>
          </div>
        </div>
      `;

      // Theme selector.
      root.querySelectorAll('[data-theme]').forEach(b => {
        b.onclick = () => {
          setTheme(b.dataset.theme);
          root.querySelectorAll('[data-theme]').forEach(x => x.classList.remove('active'));
          b.classList.add('active');
          showToast('Tema actualizado.');
        };
      });

      // Cambiar contraseña.
      root.querySelector('#form-pass').onsubmit = async (e) => {
        e.preventDefault();
        const f = new FormData(e.target);
        const err = root.querySelector('#err-pass');
        err.hidden = true;
        try {
          await S.rpc('cambiar_password',
            { p_actual: f.get('actual'), p_nueva: f.get('nueva') });
          showToast('Contraseña actualizada. Se cerraron las demás sesiones.');
          viewMiCuenta();
        } catch (er) {
          err.textContent = _msgError(er.message);
          err.hidden = false;
        }
      };

      // Sesiones.
      root.querySelectorAll('[data-jti]').forEach(b => {
        b.onclick = async () => {
          await S.rpc('revocar_sesion', { p_jti: b.dataset.jti });
          viewMiCuenta();
        };
      });
      root.querySelector('#btn-logout-global').onclick = async () => {
        _confirmar({
          titulo: 'Cerrar todas las sesiones',
          mensaje: 'Se cerrarán TODAS tus sesiones, incluida esta. ¿Continuar?',
          confirmar: 'Cerrar todas',
          peligroso: true,
          onOk: async () => {
            await S.rpc('logout_global');
            await S.logout();
            navigate('#/login');
          },
        });
      };

      // Oposiciones.
      root.querySelectorAll('[data-op-mine]').forEach(row => {
        const opId = row.dataset.opMine;
        row.querySelector('[data-act="ir"]').onclick = () => {
          setCtx({ oposicion_id: opId });
          navigate('#/');
        };
        row.querySelector('[data-act="quitar"]').onclick = () => {
          _confirmar({
            titulo: 'Quitar oposición',
            mensaje: '¿Quitar esta oposición de tu plan? Se conserva tu progreso.',
            confirmar: 'Quitar',
            peligroso: true,
            onOk: async () => {
              await S.rpc('desasignar_oposicion', { p_oposicion_id: opId });
              if (getCtx().oposicion_id === opId) setCtx({ oposicion_id: null });
              viewMiCuenta();
            },
          });
        };
      });
      root.querySelector('#btn-add-op').onclick = () => navigate('#/elegir-oposicion');

      // Borrado.
      root.querySelector('#btn-borrar').onclick = () => {
        _mostrarModal({
          titulo: 'Borrar mi cuenta',
          contenido: html`
            <p class="small" style="color:var(--txt-soft)">
              Escribe tu contraseña para confirmar. Esta acción es <strong>irreversible</strong>.
            </p>
            <form id="form-borrar" class="form-grid">
              <div class="field">
                <label>Contraseña</label>
                <input type="password" name="password" autocomplete="current-password" required>
              </div>
              <div class="form-err" id="err-borrar" hidden></div>
              <div class="form-row" style="justify-content:flex-end">
                <button class="btn btn-sm" type="button" id="cancelar-borrar">Cancelar</button>
                <button class="btn btn-danger btn-sm" type="submit">Sí, borrar</button>
              </div>
            </form>`,
          onMount(modal) {
            modal.querySelector('#cancelar-borrar').onclick = _cerrarModal;
            modal.querySelector('#form-borrar').onsubmit = async (e) => {
              e.preventDefault();
              const f = new FormData(e.target);
              const err = modal.querySelector('#err-borrar');
              try {
                await S.rpc('borrar_mi_cuenta', { p_password: f.get('password') });
                _cerrarModal();
                S.clear();
                showToast('Cuenta borrada.');
                navigate('#/login');
              } catch (er) {
                err.textContent = _msgError(er.message);
                err.hidden = false;
              }
            };
          },
        });
      };
    } catch (e) {
      empty(e.message);
    }
  }

  // Diálogo de confirmación reutilizable (reemplaza los `confirm()` nativos).
  function _confirmar({ titulo, mensaje, confirmar='Aceptar', peligroso=false, onOk }) {
    _mostrarModal({
      titulo,
      contenido: html`
        <p style="margin:0 0 1rem">${mensaje}</p>
        <div class="form-row" style="justify-content:flex-end">
          <button class="btn btn-sm" type="button" id="conf-cancel">Cancelar</button>
          <button class="btn btn-sm ${peligroso ? 'btn-danger' : 'btn-pri'}" type="button" id="conf-ok">${confirmar}</button>
        </div>`,
      onMount(modal) {
        modal.querySelector('#conf-cancel').onclick = _cerrarModal;
        modal.querySelector('#conf-ok').onclick = async () => {
          _cerrarModal();
          try { await onOk(); } catch (e) { showToast(_msgError(e.message)); }
        };
      },
    });
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
      <div class="admin-tabs">
        <a class="tab active" href="#/admin/usuarios">Usuarios</a>
        <a class="tab" href="#/admin/contenido">Contenido</a>
        <a class="tab" href="#/admin/duplicados">Duplicados</a>
      </div>
      <div class="view-head"><h2>Administración de usuarios</h2></div>
      <form id="form-search" class="form-grid" style="margin-bottom:1rem">
        <div class="form-row">
          <input name="q" value="${q}" placeholder="Buscar por email o nombre" style="flex:1">
          <button class="btn btn-pri btn-sm">Buscar</button>
        </div>
      </form>
      <div class="muted small">Total: ${rs.total} — página ${rs.page}/${rs.total_pages}</div>
      ${raw((rs.usuarios || []).map(u => html`
        <div class="tema-card" style="cursor:default" data-uid="${u.id}">
          <div style="display:flex; align-items:baseline; gap:.5rem; flex-wrap:wrap">
            <strong>${u.nombre_visible}</strong>
            <span class="muted small">${u.email}</span>
            ${raw(u.email_verificado ? '<span style="color:#4a8f2a">✓</span>' : '<span style="color:#b83a3a">sin verificar</span>')}
            ${raw(u.totp_activo ? '<span class="seccion-badge">2FA</span>' : '')}
            ${raw(!u.activo ? '<span class="seccion-badge" style="background:#b83a3a;color:white">DESACTIVADO</span>' : '')}
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
      <div class="admin-tabs">
        <a class="tab" href="#/admin/usuarios">Usuarios</a>
        <a class="tab" href="#/admin/contenido">Contenido</a>
        <a class="tab active" href="#/admin/duplicados">Duplicados</a>
      </div>
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
      ${raw((rs.items || []).length === 0 ? '<div class="empty">No hay duplicados pendientes.</div>' : '')}
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


  // ── Admin · Contenido pedagógico ─────────────────────────────────────
  // Panel jerárquico Oposición → Tema → Módulo → Sección → Preguntas.
  // Todas las vistas comparten:
  //   · `_requireContenidoAdmin()`  → cierra puerta si el usuario no tiene
  //     permiso funcional. En el MVP exigimos rol `admin` (los permisos
  //     granulares están definidos en el esquema por si se separan luego).
  //   · `_adminNav(...)`            → migas de pan con enlaces a los niveles.
  //   · `_editarEnModal(...)`       → helper para formularios de crear/editar
  //     que respetan la estética de la app (labels, foco verde, botones).

  function _requireContenidoAdmin() {
    const u = S.getUser();
    if (!u || !(u.roles || []).includes('admin')) {
      empty('Acceso restringido.');
      return false;
    }
    return true;
  }

  function _adminNav(crumbs) {
    // crumbs: [{label, href?}, ...]  — el último se pinta como <strong>.
    return html`
      <div class="admin-tabs">
        <a class="tab" href="#/admin/usuarios">Usuarios</a>
        <a class="tab active" href="#/admin/contenido">Contenido</a>
        <a class="tab" href="#/admin/duplicados">Duplicados</a>
      </div>
      <div class="breadcrumbs" style="margin-bottom:.75rem; color:var(--txt-soft)">
        ${raw(crumbs.map((c, i) => {
          const last = i === crumbs.length - 1;
          if (last) return `<strong>${esc(c.label)}</strong>`;
          return `<a href="${c.href || '#/'}">${esc(c.label)}</a> / `;
        }).join(''))}
      </div>`;
  }

  // Vista: listado de oposiciones (admin).
  async function viewAdminOposiciones() {
    if (!_requireContenidoAdmin()) return;
    loading();
    const oposiciones = await S.rpc('admin_listar_oposiciones').catch(() => []);
    root.innerHTML = html`
      ${raw(_adminNav([{ label: 'Oposiciones' }]))}
      <div class="admin-toolbar">
        <h2 style="margin:0; flex:1">Oposiciones</h2>
        <button class="btn btn-pri btn-sm" id="btn-crear-op">➕ Nueva oposición</button>
      </div>

      ${raw(oposiciones.length === 0
        ? '<div class="empty">Aún no hay oposiciones creadas.</div>'
        : oposiciones.map(o => html`
          <div class="list-item" data-opid="${o.id}">
            <div class="li-body">
              <div class="li-title">${o.nombre} ${raw(!o.activa ? '<span class="kv-badge warn">inactiva</span>' : '')}</div>
              <div class="li-meta">
                ${o.n_temas} tema(s) · ${o.n_alumnos} alumn@s
                ${raw(o.descripcion ? html` · ${o.descripcion}` : '')}
              </div>
            </div>
            <div class="li-actions">
              <button class="btn" data-act="ver">Abrir</button>
              <button class="btn" data-act="editar">Editar</button>
              <button class="btn btn-danger-outline" data-act="borrar">Borrar</button>
            </div>
          </div>
        `).join(''))}
    `;

    root.querySelector('#btn-crear-op').onclick = () => _editarOposicion(null);

    root.querySelectorAll('.list-item[data-opid]').forEach(item => {
      const id = item.dataset.opid;
      const op = oposiciones.find(x => x.id === id);
      item.querySelector('[data-act="ver"]').onclick = () =>
        navigate(`#/admin/contenido/oposicion/${id}`);
      item.querySelector('[data-act="editar"]').onclick = () => _editarOposicion(op);
      item.querySelector('[data-act="borrar"]').onclick = () => _confirmar({
        titulo: 'Borrar oposición',
        mensaje: `¿Borrar la oposición "${op.nombre}"? Se pierden las asignaciones a alumn@s.`,
        confirmar: 'Borrar', peligroso: true,
        onOk: async () => {
          await S.rpc('admin_borrar_oposicion', { p_id: id });
          viewAdminOposiciones();
        },
      });
    });
  }

  function _editarOposicion(op) {
    _mostrarModal({
      titulo: op ? 'Editar oposición' : 'Nueva oposición',
      contenido: html`
        <form id="form-op" class="form-grid">
          <div class="field">
            <label>Nombre</label>
            <input name="nombre" required value="${op ? op.nombre : ''}">
          </div>
          <div class="field">
            <label>Descripción (opcional)</label>
            <textarea name="descripcion">${op ? (op.descripcion || '') : ''}</textarea>
          </div>
          ${op ? html`
            <label class="field-inline">
              <input type="checkbox" name="activa" ${op.activa ? 'checked' : ''}>
              Activa (visible para los alumn@s)
            </label>` : ''}
          <div class="form-err" hidden></div>
          <div class="form-row" style="justify-content:flex-end">
            <button class="btn btn-sm" type="button" data-cancel>Cancelar</button>
            <button class="btn btn-pri btn-sm" type="submit">${op ? 'Guardar' : 'Crear'}</button>
          </div>
        </form>`,
      onMount(modal) {
        modal.querySelector('[data-cancel]').onclick = _cerrarModal;
        modal.querySelector('#form-op').onsubmit = async (e) => {
          e.preventDefault();
          const f = new FormData(e.target);
          try {
            if (op) {
              await S.rpc('admin_actualizar_oposicion', {
                p_id: op.id,
                p_nombre: f.get('nombre'),
                p_descripcion: f.get('descripcion') || null,
                p_activa: f.has('activa'),
              });
            } else {
              await S.rpc('admin_crear_oposicion', {
                p_nombre: f.get('nombre'),
                p_descripcion: f.get('descripcion') || null,
              });
            }
            _cerrarModal();
            viewAdminOposiciones();
          } catch (er) {
            const err = modal.querySelector('.form-err');
            err.textContent = _msgError(er.message);
            err.hidden = false;
          }
        };
      },
    });
  }

  // Vista: detalle de una oposición (lista sus temas y permite añadir/quitar).
  async function viewAdminOposicion([opId]) {
    if (!_requireContenidoAdmin()) return;
    loading();
    const [ops, temasOp, todosTemas] = await Promise.all([
      S.rpc('admin_listar_oposiciones'),
      S.rpc('admin_listar_temas', { p_oposicion_id: opId }),
      S.rpc('admin_listar_temas', { p_oposicion_id: null }),
    ]);
    const op = (ops || []).find(x => x.id === opId);
    if (!op) return empty('Oposición no encontrada.');

    root.innerHTML = html`
      ${raw(_adminNav([
        { label: 'Oposiciones', href: '#/admin/contenido' },
        { label: op.nombre },
      ]))}
      <div class="view-head"><h2>${op.nombre}</h2></div>
      ${op.descripcion ? html`<p class="muted">${op.descripcion}</p>` : ''}

      <div class="admin-toolbar">
        <h3 style="margin:0; flex:1">Temas</h3>
        <button class="btn btn-sm" id="btn-vincular">🔗 Vincular tema existente</button>
        <button class="btn btn-pri btn-sm" id="btn-nuevo-tema">➕ Nuevo tema</button>
      </div>

      ${raw(temasOp.length === 0
        ? '<div class="empty">Esta oposición aún no tiene temas.</div>'
        : temasOp.map(t => html`
          <div class="list-item" data-tid="${t.id}">
            <div class="li-body">
              <div class="li-title">${t.orden ?? '·'}. ${t.nombre}</div>
              <div class="li-meta">
                ${t.n_modulos} módulo(s) · ${t.n_secciones} sección(es) · ${t.n_preguntas} pregunta(s)
              </div>
            </div>
            <div class="li-actions">
              <button class="btn" data-act="abrir">Abrir</button>
              <button class="btn btn-danger-outline" data-act="quitar">Desvincular</button>
            </div>
          </div>
        `).join(''))}
    `;

    root.querySelector('#btn-nuevo-tema').onclick = () => _editarTema(null, opId);
    root.querySelector('#btn-vincular').onclick = () =>
      _vincularTemaAOposicion(opId, todosTemas, temasOp.map(t => t.id));

    root.querySelectorAll('.list-item[data-tid]').forEach(item => {
      const tid = item.dataset.tid;
      item.querySelector('[data-act="abrir"]').onclick = () =>
        navigate(`#/admin/contenido/tema/${tid}`);
      item.querySelector('[data-act="quitar"]').onclick = () => _confirmar({
        titulo: 'Desvincular tema',
        mensaje: 'Se quita el tema de esta oposición (no se borra el tema).',
        confirmar: 'Desvincular',
        onOk: async () => {
          await S.rpc('admin_quitar_tema_de_oposicion',
            { p_oposicion_id: opId, p_tema_id: tid });
          viewAdminOposicion([opId]);
        },
      });
    });
  }

  function _editarTema(tema, opIdContexto) {
    _mostrarModal({
      titulo: tema ? 'Editar tema' : 'Nuevo tema',
      contenido: html`
        <form id="form-tema" class="form-grid">
          <div class="field">
            <label>Nombre</label>
            <input name="nombre" required value="${tema ? tema.nombre : ''}">
          </div>
          <div class="field">
            <label>Descripción</label>
            <textarea name="descripcion">${tema ? (tema.descripcion || '') : ''}</textarea>
          </div>
          <div class="form-err" hidden></div>
          <div class="form-row" style="justify-content:flex-end">
            <button class="btn btn-sm" type="button" data-cancel>Cancelar</button>
            <button class="btn btn-pri btn-sm" type="submit">${tema ? 'Guardar' : 'Crear'}</button>
          </div>
        </form>`,
      onMount(modal) {
        modal.querySelector('[data-cancel]').onclick = _cerrarModal;
        modal.querySelector('#form-tema').onsubmit = async (e) => {
          e.preventDefault();
          const f = new FormData(e.target);
          try {
            if (tema) {
              await S.rpc('admin_actualizar_tema', {
                p_id: tema.id,
                p_nombre: f.get('nombre'),
                p_descripcion: f.get('descripcion') || null,
              });
            } else {
              await S.rpc('admin_crear_tema', {
                p_nombre: f.get('nombre'),
                p_descripcion: f.get('descripcion') || null,
                p_oposicion_id: opIdContexto || null,
              });
            }
            _cerrarModal();
            if (opIdContexto) viewAdminOposicion([opIdContexto]);
            else viewAdminOposiciones();
          } catch (er) {
            const err = modal.querySelector('.form-err');
            err.textContent = _msgError(er.message);
            err.hidden = false;
          }
        };
      },
    });
  }

  function _vincularTemaAOposicion(opId, todosTemas, yaVinculados) {
    const yaSet = new Set(yaVinculados);
    const disponibles = (todosTemas || []).filter(t => !yaSet.has(t.id));
    _mostrarModal({
      titulo: 'Vincular tema existente',
      contenido: disponibles.length === 0
        ? '<p>Todos los temas del catálogo están ya vinculados a esta oposición.</p>'
        : html`
          <div class="form-grid">
            ${raw(disponibles.map(t => html`
              <button class="list-item" type="button" data-tid="${t.id}" style="cursor:pointer">
                <div class="li-body">
                  <div class="li-title">${t.nombre}</div>
                  <div class="li-meta">${t.n_modulos} módulo(s) · ${t.n_secciones} sección(es)</div>
                </div>
                <div class="li-actions"><span class="btn btn-pri btn-sm">Vincular</span></div>
              </button>
            `).join(''))}
          </div>`,
      onMount(modal) {
        modal.querySelectorAll('[data-tid]').forEach(b => {
          b.onclick = async () => {
            try {
              await S.rpc('admin_asignar_tema_a_oposicion',
                { p_oposicion_id: opId, p_tema_id: b.dataset.tid });
              _cerrarModal();
              viewAdminOposicion([opId]);
            } catch (er) { showToast(_msgError(er.message)); }
          };
        });
      },
    });
  }

  // Vista: detalle de un tema (lista módulos).
  async function viewAdminTema([tid]) {
    if (!_requireContenidoAdmin()) return;
    loading();
    const temas = await S.rpc('admin_listar_temas', { p_oposicion_id: null });
    const tema = (temas || []).find(x => x.id === tid);
    if (!tema) return empty('Tema no encontrado.');
    const modulos = await S.rpc('admin_listar_modulos', { p_tema_id: tid });

    root.innerHTML = html`
      ${raw(_adminNav([
        { label: 'Oposiciones', href: '#/admin/contenido' },
        { label: tema.nombre },
      ]))}
      <div class="view-head"><h2>${tema.nombre}</h2></div>
      ${tema.descripcion ? html`<p class="muted">${tema.descripcion}</p>` : ''}

      <div class="admin-toolbar">
        <h3 style="margin:0; flex:1">Módulos</h3>
        <button class="btn btn-sm" id="btn-editar-tema">✏️ Editar tema</button>
        <button class="btn btn-pri btn-sm" id="btn-nuevo-mod">➕ Nuevo módulo</button>
      </div>

      ${raw(modulos.length === 0
        ? '<div class="empty">Este tema aún no tiene módulos.</div>'
        : modulos.map(m => html`
          <div class="list-item" data-mid="${m.id}">
            <div class="li-body">
              <div class="li-title">${m.orden}. ${m.nombre}
                ${raw(m.es_unico ? '<span class="chip-modulo">único</span>' : '')}</div>
              <div class="li-meta">${m.n_secciones} sección(es) · ${m.n_preguntas} pregunta(s)</div>
            </div>
            <div class="li-actions">
              <button class="btn" data-act="abrir">Abrir</button>
              <button class="btn" data-act="editar">Editar</button>
              <button class="btn btn-danger-outline" data-act="borrar">Borrar</button>
            </div>
          </div>
        `).join(''))}
    `;

    root.querySelector('#btn-editar-tema').onclick = () => _editarTema(tema, null);
    root.querySelector('#btn-nuevo-mod').onclick = () => _editarModulo(null, tid);
    root.querySelectorAll('.list-item[data-mid]').forEach(item => {
      const mid = item.dataset.mid;
      const m = modulos.find(x => x.id === mid);
      item.querySelector('[data-act="abrir"]').onclick = () =>
        navigate(`#/admin/contenido/modulo/${mid}`);
      item.querySelector('[data-act="editar"]').onclick = () => _editarModulo(m, tid);
      item.querySelector('[data-act="borrar"]').onclick = () => _confirmar({
        titulo: 'Borrar módulo',
        mensaje: `¿Borrar "${m.nombre}" y todas sus secciones/preguntas?`,
        confirmar: 'Borrar', peligroso: true,
        onOk: async () => {
          await S.rpc('admin_borrar_modulo', { p_id: mid });
          viewAdminTema([tid]);
        },
      });
    });
  }

  function _editarModulo(mod, temaId) {
    _mostrarModal({
      titulo: mod ? 'Editar módulo' : 'Nuevo módulo',
      contenido: html`
        <form id="form-mod" class="form-grid">
          <div class="field">
            <label>Nombre</label>
            <input name="nombre" required value="${mod ? mod.nombre : ''}">
          </div>
          <div class="field">
            <label>Orden</label>
            <input name="orden" type="number" min="1" value="${mod ? mod.orden : ''}">
          </div>
          <div class="form-err" hidden></div>
          <div class="form-row" style="justify-content:flex-end">
            <button class="btn btn-sm" type="button" data-cancel>Cancelar</button>
            <button class="btn btn-pri btn-sm" type="submit">${mod ? 'Guardar' : 'Crear'}</button>
          </div>
        </form>`,
      onMount(modal) {
        modal.querySelector('[data-cancel]').onclick = _cerrarModal;
        modal.querySelector('#form-mod').onsubmit = async (e) => {
          e.preventDefault();
          const f = new FormData(e.target);
          const orden = f.get('orden') ? +f.get('orden') : null;
          try {
            if (mod) {
              await S.rpc('admin_actualizar_modulo',
                { p_id: mod.id, p_nombre: f.get('nombre'), p_orden: orden });
            } else {
              await S.rpc('admin_crear_modulo',
                { p_tema_id: temaId, p_nombre: f.get('nombre'), p_orden: orden });
            }
            _cerrarModal();
            viewAdminTema([temaId]);
          } catch (er) {
            const err = modal.querySelector('.form-err');
            err.textContent = _msgError(er.message);
            err.hidden = false;
          }
        };
      },
    });
  }

  // Vista: detalle de un módulo (lista secciones).
  async function viewAdminModulo([mid]) {
    if (!_requireContenidoAdmin()) return;
    loading();
    // No hay una RPC "get_modulo"; buscamos entre los temas.
    const temas = await S.rpc('admin_listar_temas', { p_oposicion_id: null });
    let tema = null, modulo = null;
    for (const t of temas) {
      const mods = await S.rpc('admin_listar_modulos', { p_tema_id: t.id });
      const m = (mods || []).find(x => x.id === mid);
      if (m) { tema = t; modulo = m; break; }
    }
    if (!modulo) return empty('Módulo no encontrado.');
    const secciones = await S.rpc('admin_listar_secciones', { p_modulo_id: mid });

    root.innerHTML = html`
      ${raw(_adminNav([
        { label: 'Oposiciones', href: '#/admin/contenido' },
        { label: tema.nombre,   href: `#/admin/contenido/tema/${tema.id}` },
        { label: modulo.nombre },
      ]))}
      <div class="view-head"><h2>${modulo.nombre}</h2></div>
      <div class="admin-toolbar">
        <h3 style="margin:0; flex:1">Secciones</h3>
        <button class="btn btn-pri btn-sm" id="btn-nueva-sec">➕ Nueva sección</button>
      </div>
      ${raw(secciones.length === 0
        ? '<div class="empty">Este módulo aún no tiene secciones.</div>'
        : secciones.map(s => html`
          <div class="list-item" data-sid="${s.id}">
            <div class="li-body">
              <div class="li-title">${s.orden}. ${s.nombre}
                ${raw(s.tiene_teoria ? '<span class="kv-badge ok">teoría</span>' : '')}
              </div>
              <div class="li-meta">
                ${s.n_preguntas} pregunta(s) · aprobado ≥ ${s.min_aprobado}% · test ${s.n_preg_test} preg
              </div>
            </div>
            <div class="li-actions">
              <button class="btn" data-act="abrir">Abrir</button>
              <button class="btn" data-act="editar">Editar</button>
              <button class="btn btn-danger-outline" data-act="borrar">Borrar</button>
            </div>
          </div>
        `).join(''))}
    `;

    root.querySelector('#btn-nueva-sec').onclick = () => _editarSeccion(null, mid);
    root.querySelectorAll('.list-item[data-sid]').forEach(item => {
      const sid = item.dataset.sid;
      const sec = secciones.find(x => x.id === sid);
      item.querySelector('[data-act="abrir"]').onclick = () =>
        navigate(`#/admin/contenido/seccion/${sid}`);
      item.querySelector('[data-act="editar"]').onclick = () => _editarSeccion(sec, mid);
      item.querySelector('[data-act="borrar"]').onclick = () => _confirmar({
        titulo: 'Borrar sección',
        mensaje: `¿Borrar "${sec.nombre}" y todas sus preguntas?`,
        confirmar: 'Borrar', peligroso: true,
        onOk: async () => {
          await S.rpc('admin_borrar_seccion', { p_id: sid });
          viewAdminModulo([mid]);
        },
      });
    });
  }

  function _editarSeccion(sec, moduloId) {
    _mostrarModal({
      titulo: sec ? 'Editar sección' : 'Nueva sección',
      contenido: html`
        <form id="form-sec" class="form-grid">
          <div class="field">
            <label>Nombre</label>
            <input name="nombre" required value="${sec ? sec.nombre : ''}">
          </div>
          <div class="form-row">
            <div class="field" style="flex:1">
              <label>Orden</label>
              <input name="orden" type="number" min="1" value="${sec ? sec.orden : ''}">
            </div>
            <div class="field" style="flex:1">
              <label>Mínimo aprobado (%)</label>
              <input name="min_aprobado" type="number" min="0" max="100"
                     value="${sec ? sec.min_aprobado : 70}">
            </div>
            <div class="field" style="flex:1">
              <label>Nº preguntas / test</label>
              <input name="n_preg_test" type="number" min="1" max="100"
                     value="${sec ? sec.n_preg_test : 10}">
            </div>
          </div>
          <div class="form-err" hidden></div>
          <div class="form-row" style="justify-content:flex-end">
            <button class="btn btn-sm" type="button" data-cancel>Cancelar</button>
            <button class="btn btn-pri btn-sm" type="submit">${sec ? 'Guardar' : 'Crear'}</button>
          </div>
        </form>`,
      onMount(modal) {
        modal.querySelector('[data-cancel]').onclick = _cerrarModal;
        modal.querySelector('#form-sec').onsubmit = async (e) => {
          e.preventDefault();
          const f = new FormData(e.target);
          const args = {
            p_nombre: f.get('nombre'),
            p_orden: f.get('orden') ? +f.get('orden') : null,
            p_min_aprobado: f.get('min_aprobado') ? +f.get('min_aprobado') : null,
            p_n_preg_test: f.get('n_preg_test') ? +f.get('n_preg_test') : null,
          };
          try {
            if (sec) {
              await S.rpc('admin_actualizar_seccion', { p_id: sec.id, ...args });
            } else {
              await S.rpc('admin_crear_seccion',
                { p_modulo_id: moduloId, ...args });
            }
            _cerrarModal();
            viewAdminModulo([moduloId]);
          } catch (er) {
            const err = modal.querySelector('.form-err');
            err.textContent = _msgError(er.message);
            err.hidden = false;
          }
        };
      },
    });
  }

  // Vista: sección — preguntas + teoría.
  async function viewAdminSeccion([sid]) {
    if (!_requireContenidoAdmin()) return;
    loading();
    // No hay RPC directa "get_seccion"; buscamos navegando temas→módulos→secc.
    const temas = await S.rpc('admin_listar_temas', { p_oposicion_id: null });
    let tema = null, modulo = null, seccion = null;
    outer: for (const t of temas) {
      const mods = await S.rpc('admin_listar_modulos', { p_tema_id: t.id });
      for (const m of mods) {
        const secs = await S.rpc('admin_listar_secciones', { p_modulo_id: m.id });
        const s = (secs || []).find(x => x.id === sid);
        if (s) { tema = t; modulo = m; seccion = s; break outer; }
      }
    }
    if (!seccion) return empty('Sección no encontrada.');
    const preguntas = await S.rpc('admin_preguntas_de_seccion', { p_seccion_id: sid });
    const docTeoria = await S.rpc('documento_de_seccion', { p_seccion_id: sid })
      .catch(() => null);

    root.innerHTML = html`
      ${raw(_adminNav([
        { label: 'Oposiciones', href: '#/admin/contenido' },
        { label: tema.nombre,   href: `#/admin/contenido/tema/${tema.id}` },
        { label: modulo.nombre, href: `#/admin/contenido/modulo/${modulo.id}` },
        { label: seccion.nombre },
      ]))}
      <div class="view-head"><h2>${seccion.nombre}</h2></div>

      <div class="panel-card">
        <h3 class="card-title"><span class="ico">📖</span> Teoría (markdown)</h3>
        <p class="card-subtitle">
          Ruta del fichero markdown asociado a esta sección. Súbelo primero al
          microservicio de contenido y pega aquí la ruta relativa
          (empezando por <code>/</code>).
        </p>
        <form id="form-teoria" class="form-grid">
          <div class="field">
            <label>Subir un fichero markdown</label>
            <input type="file" name="fichero" accept=".md,.markdown,.txt">
            <small class="small" style="color:var(--txt-soft)">
              Se sube a <code>/${esc((tema.slug || 'tema')+'/'+ (seccion.orden || '') +'-'+ (seccion.nombre || ''))}/</code>
              y se registra su ruta como teoría de esta sección.
            </small>
          </div>
          <div class="field">
            <label>O bien, ruta ya existente</label>
            <input name="ruta" placeholder="/oposicion/tema/seccion/teoria.md"
                   value="${docTeoria?.ruta || ''}">
          </div>
          <div class="form-err" hidden></div>
          <div class="form-row" style="justify-content:flex-end">
            ${raw(docTeoria
              ? '<button class="btn btn-danger-outline btn-sm" type="button" id="btn-quitar-teoria">Quitar vínculo</button>'
              : '')}
            <button class="btn btn-pri btn-sm" type="submit">Guardar teoría</button>
          </div>
        </form>
      </div>

      <div class="admin-toolbar">
        <h3 style="margin:0; flex:1">Preguntas <span class="kv-badge">${preguntas.length}</span></h3>
        <button class="btn btn-pri btn-sm" id="btn-nueva-preg">➕ Nueva pregunta</button>
      </div>

      ${raw(preguntas.length === 0
        ? '<div class="empty">Aún no hay preguntas en esta sección.</div>'
        : preguntas.map(p => html`
          <div class="list-item" data-pid="${p.id}" style="cursor:default">
            <div class="li-body">
              <div class="li-title" style="white-space:pre-wrap">${p.enunciado}</div>
              <div class="li-meta">
                ${(p.opciones || []).length} opciones ·
                ${((p.opciones || []).filter(o => o.correcta).length)} correcta(s)
              </div>
            </div>
            <div class="li-actions">
              <button class="btn" data-act="editar">Editar</button>
              <button class="btn btn-danger-outline" data-act="borrar">Borrar</button>
            </div>
          </div>
        `).join(''))}
    `;

    // Teoría — form.
    root.querySelector('#form-teoria').onsubmit = async (e) => {
      e.preventDefault();
      const err = root.querySelector('#form-teoria .form-err');
      err.hidden = true;
      try {
        const f = new FormData(e.target);
        let ruta = (f.get('ruta') || '').trim();
        const file = f.get('fichero');
        if (file && file.name) {
          // Sube al microservicio contenido/. Carpeta por convención con el
          // slug del tema y la sección (crea la subcarpeta al vuelo).
          const carpeta = `/${(tema.slug || 'tema')}/${(seccion.orden || '') + '-' + (seccion.nombre || '').toLowerCase().replace(/[^a-z0-9]+/g, '-')}`;
          const tok = S.getAccess?.();
          // Crea carpeta destino de forma idempotente.
          await fetch('/teoria/api/carpeta', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json',
                       Authorization: `Bearer ${tok}` },
            body: JSON.stringify({ padre: carpeta.replace(/\/[^/]+$/, '/') || '/',
                                   nombre: carpeta.split('/').pop() }),
          }).catch(() => {});
          const fd = new FormData();
          fd.append('ruta', carpeta);
          fd.append('files', file);
          const r = await fetch('/teoria/api/subir', {
            method: 'POST', body: fd,
            headers: tok ? { Authorization: `Bearer ${tok}` } : {},
          });
          if (!r.ok) throw new Error('upload_failed');
          const d = await r.json();
          if (d.subidos && d.subidos.length) ruta = d.subidos[0].ruta;
        }
        if (!ruta) throw new Error('ruta_o_fichero_requerido');
        await S.rpc('admin_upsert_documento', {
          p_nivel: 'seccion',
          p_entidad_id: sid,
          p_tipo: 'teoria',
          p_ruta: ruta,
        });
        showToast('Teoría vinculada.');
        viewAdminSeccion([sid]);
      } catch (er) {
        err.textContent = _msgError(er.message || String(er));
        err.hidden = false;
      }
    };
    const btnQ = root.querySelector('#btn-quitar-teoria');
    if (btnQ) btnQ.onclick = () => _confirmar({
      titulo: 'Quitar teoría',
      mensaje: 'Se elimina el vínculo (el fichero markdown NO se borra del disco).',
      confirmar: 'Quitar',
      onOk: async () => {
        await S.rpc('admin_borrar_documento', { p_id: docTeoria.id });
        viewAdminSeccion([sid]);
      },
    });

    // Preguntas.
    root.querySelector('#btn-nueva-preg').onclick = () => _editarPregunta(null, sid);
    root.querySelectorAll('.list-item[data-pid]').forEach(item => {
      const pid = item.dataset.pid;
      const p = preguntas.find(x => x.id === pid);
      item.querySelector('[data-act="editar"]').onclick = () => _editarPregunta(p, sid);
      item.querySelector('[data-act="borrar"]').onclick = () => _confirmar({
        titulo: 'Borrar pregunta',
        mensaje: 'Se borrará la pregunta y todas las respuestas asociadas.',
        confirmar: 'Borrar', peligroso: true,
        onOk: async () => {
          await S.rpc('admin_borrar_pregunta', { p_id: pid });
          viewAdminSeccion([sid]);
        },
      });
    });
  }

  function _editarPregunta(preg, seccionId) {
    const opciones = preg
      ? preg.opciones.map(o => ({ texto: o.texto, correcta: !!o.correcta }))
      : [
          { texto: '', correcta: true },
          { texto: '', correcta: false },
          { texto: '', correcta: false },
          { texto: '', correcta: false },
        ];

    function _renderOpciones(container) {
      container.innerHTML = opciones.map((o, i) => `
        <div class="opcion-editor">
          <input type="radio" name="correcta" ${o.correcta ? 'checked' : ''} data-i="${i}"
                 title="Marcar como correcta">
          <input type="text" placeholder="Opción ${i+1}" value="${esc(o.texto)}" data-i="${i}">
          <button type="button" class="btn-del" data-del="${i}" title="Quitar">✕</button>
        </div>`).join('');
      container.querySelectorAll('input[type=radio]').forEach(r => {
        r.onchange = () => opciones.forEach((o, j) =>
          o.correcta = (r.dataset.i == j && r.checked));
      });
      container.querySelectorAll('input[type=text]').forEach(t => {
        t.oninput = () => { opciones[+t.dataset.i].texto = t.value; };
      });
      container.querySelectorAll('[data-del]').forEach(b => {
        b.onclick = () => {
          if (opciones.length <= 2) return showToast('Debe haber al menos 2 opciones.');
          opciones.splice(+b.dataset.del, 1);
          if (!opciones.some(o => o.correcta)) opciones[0].correcta = true;
          _renderOpciones(container);
        };
      });
    }

    _mostrarModal({
      titulo: preg ? 'Editar pregunta' : 'Nueva pregunta',
      contenido: html`
        <form id="form-preg" class="form-grid">
          <div class="field">
            <label>Enunciado</label>
            <textarea name="enunciado" required rows="3">${preg ? preg.enunciado : ''}</textarea>
          </div>
          <div class="field">
            <label>Opciones (marca la correcta con el radio)</label>
            <div id="opciones-editor"></div>
            <button class="btn btn-sm" type="button" id="btn-add-opcion">➕ Añadir opción</button>
          </div>
          <div class="field">
            <label>Explicación (se muestra al responder)</label>
            <textarea name="explicacion">${preg ? (preg.explicacion || '') : ''}</textarea>
          </div>
          <div class="form-err" hidden></div>
          <div class="form-row" style="justify-content:flex-end">
            <button class="btn btn-sm" type="button" data-cancel>Cancelar</button>
            <button class="btn btn-pri btn-sm" type="submit">${preg ? 'Guardar' : 'Crear'}</button>
          </div>
        </form>`,
      onMount(modal) {
        const cont = modal.querySelector('#opciones-editor');
        _renderOpciones(cont);
        modal.querySelector('#btn-add-opcion').onclick = () => {
          opciones.push({ texto: '', correcta: false });
          _renderOpciones(cont);
        };
        modal.querySelector('[data-cancel]').onclick = _cerrarModal;
        modal.querySelector('#form-preg').onsubmit = async (e) => {
          e.preventDefault();
          const f = new FormData(e.target);
          const err = modal.querySelector('.form-err');
          err.hidden = true;
          const clean = opciones
            .map(o => ({ texto: (o.texto || '').trim(), correcta: !!o.correcta }))
            .filter(o => o.texto);
          if (clean.length < 2) {
            err.textContent = 'Necesitas al menos 2 opciones con texto.';
            err.hidden = false; return;
          }
          if (!clean.some(o => o.correcta)) {
            err.textContent = 'Marca cuál es la opción correcta.';
            err.hidden = false; return;
          }
          try {
            if (preg) {
              await S.rpc('admin_actualizar_pregunta', {
                p_id: preg.id,
                p_enunciado: f.get('enunciado'),
                p_opciones: clean,
                p_explicacion: f.get('explicacion') || null,
              });
            } else {
              await S.rpc('admin_crear_pregunta', {
                p_seccion_id: seccionId,
                p_enunciado: f.get('enunciado'),
                p_opciones: clean,
                p_explicacion: f.get('explicacion') || null,
              });
            }
            _cerrarModal();
            viewAdminSeccion([seccionId]);
          } catch (er) {
            err.textContent = _msgError(er.message);
            err.hidden = false;
          }
        };
      },
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
    if (id === 'home')                navigate('#/');
    if (id === 'estadisticas')        navigate('#/estadisticas');
    if (id === 'cambiar-oposicion')   _abrirSelectorOposicion();
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
    if (v === 'admin-contenido')  navigate('#/admin/contenido');
    if (v === 'admin-duplicados') navigate('#/admin/duplicados');
  });

  (async function main() {
    // Antes de saber si hay sesión, ocultamos la cabecera para no mostrar
    // "?" en el avatar mientras rehidrata: se reactiva en _render() según
    // la ruta y el estado de sesión.
    setHeaderVisible(false);

    // Enlaces de email que llegan sin `#` (correos antiguos o clientes que
    // reescriben el fragmento): /verify?token=… → /#/verify?token=…, para no
    // perder el token en el bootstrap.
    if (!location.hash && ['/verify', '/reset'].includes(location.pathname)) {
      location.replace('/#' + location.pathname + location.search);
      return;
    }

    // Rehidratación silenciosa: si hay refresh, obtiene un access nuevo.
    await S.bootstrap();
    // Cargamos los roles frescos de mi_cuenta (pueden diferir del JWT si un
    // admin acaba de otorgar/retirar un rol). Esto alimenta `_esAdmin()`.
    if (S.getUser()) _refreshLocalRoles();
    if (!location.hash) {
      // Sin hash: si hay sesión, home; si no, login.
      location.hash = S.getUser() ? '#/' : '#/login';
    } else {
      _render();
    }
  })();
})();
