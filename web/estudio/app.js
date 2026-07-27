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
 *   #/plan                          Planificador personal de estudio.
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
    { re: /^\/esquema\/tema\/([0-9a-f-]+)$/, view: viewEsquemaTema },
    { re: /^\/repaso\/([0-9a-f-]+)$/,        view: viewRepaso },
    { re: /^\/tablon\/([0-9a-f-]+)$/,        view: viewTablon },
    { re: /^\/estadisticas$/,                view: viewEstadisticas },
    { re: /^\/plan$/,                        view: viewPlan },
    { re: /^\/logros$/,                      view: viewLogrosRetos },
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
  // Paleta cíclica para pintar cada tema con carácter propio. Un mismo tema
  // conserva siempre su color porque el índice se calcula por posición dentro
  // de la oposición. Los tokens (--pri, --accent, ...) están en tokens.css.
  const TEMA_PALETA = [
    { key: 'moss',     border: 'var(--pri)',      soft: 'var(--pri-soft)',      strong: 'var(--pri-d)'      },
    { key: 'amber',    border: 'var(--accent)',   soft: 'var(--accent-soft)',   strong: 'var(--accent-d)'   },
    { key: 'lavender', border: 'var(--lavender)', soft: 'var(--lavender-soft)', strong: 'var(--lavender-d)' },
    { key: 'sky',      border: 'var(--sky)',      soft: 'var(--sky-soft)',      strong: 'var(--sky-d)'      },
    { key: 'coral',    border: 'var(--coral)',    soft: 'var(--coral-soft)',    strong: 'var(--coral-d)'    },
    { key: 'leaf',     border: 'var(--leaf)',     soft: 'var(--leaf-soft)',     strong: 'var(--pri-d)'      },
  ];
  function _paletaTema(idx) { return TEMA_PALETA[idx % TEMA_PALETA.length]; }

  // Emoji-icono por defecto para cuando el tema no lo trae. Heurística barata
  // sobre el nombre (constitución → 🏛️, derechos → ⚖️, etc.). Si no matchea,
  // recae en un pequeño ciclo de iconos "de institución" para no dar siempre
  // el mismo dibujo.
  const ICON_FALLBACK = ['🏛️','⚖️','👑','🏛️','📜','🗳️','🌍','⚙️'];
  function _iconoTema(nombre, idx) {
    const n = String(nombre || '').toLowerCase();
    if (/constituci/.test(n))        return '🏛️';
    if (/derecho|libertad/.test(n))  return '⚖️';
    if (/corona|jefatur/.test(n))    return '👑';
    if (/cortes|parlament|senado|congreso|legislat/.test(n)) return '🏛️';
    if (/gobierno|adminis/.test(n))  return '⚙️';
    if (/judicial|juez|tribunal/.test(n)) return '⚖️';
    if (/unión|europ|internacional/.test(n)) return '🌍';
    if (/econom|hacienda|presupue/.test(n)) return '💰';
    return ICON_FALLBACK[idx % ICON_FALLBACK.length];
  }

  // Estimación de duración de un tema. No tenemos el dato exacto en la RPC,
  // así que asumimos ~15 min por sección estudiada. Devuelve una cadena
  // legible ("~45 min", "~2h", "~3h 30 min").
  function _duracionEstimada(minutos) {
    const m = Math.max(0, Math.round(minutos || 0));
    if (m < 60) return `~${m || 15} min`;
    const h = Math.floor(m / 60), r = m - h * 60;
    if (r === 0) return `~${h}h`;
    return `~${h}h ${r} min`;
  }

  // Anillo de progreso SVG reutilizable (usado en tarjetas de tema, módulo,
  // y en el resumen del home). `size` es el diámetro, `stroke` el grosor.
  function _svgProgreso(pct, {
    size = 44, stroke = 4, color = 'var(--pri)', track = 'var(--border)',
  } = {}) {
    const p = Math.max(0, Math.min(100, Number(pct) || 0));
    const r = (size / 2) - stroke;
    const c = 2 * Math.PI * r;
    const off = c * (1 - p / 100);
    return `
      <svg class="ring" viewBox="0 0 ${size} ${size}" width="${size}" height="${size}"
           role="img" aria-label="Progreso ${p}%">
        <circle cx="${size/2}" cy="${size/2}" r="${r}" fill="none"
                stroke="${track}" stroke-width="${stroke}"/>
        <circle cx="${size/2}" cy="${size/2}" r="${r}" fill="none"
                stroke="${color}" stroke-width="${stroke}"
                stroke-linecap="round"
                stroke-dasharray="${c.toFixed(2)}" stroke-dashoffset="${off.toFixed(2)}"
                transform="rotate(-90 ${size/2} ${size/2})"/>
        <text x="${size/2}" y="${size/2 + 4}" text-anchor="middle"
              font-size="11" font-weight="800" fill="currentColor">${p}%</text>
      </svg>`;
  }

  // Colección de consejos rotatorios para el pie del home. Se elige uno por
  // día del año para que sea estable dentro de la misma jornada.
  const CONSEJOS = [
    'Estudia un poco cada día. ¡La constancia es la clave!',
    '5 minutos de repaso valen más que 1 hora de agobio.',
    'Explícate la teoría en voz alta: si sabes explicarla, la sabes.',
    'Marca la sección más floja de hoy y empieza por ella.',
    'Descansa 5 min entre tests: el cerebro consolida mejor.',
    'Los fallos de hoy son los aciertos de mañana.',
    'Repite un test antiguo antes de dormir. Es magia.',
    'Cada racha suma. No la rompas hoy.',
  ];
  function _consejoDelDia() {
    const d = new Date();
    const doy = Math.floor((d - new Date(d.getFullYear(), 0, 0)) / 86400000);
    return CONSEJOS[doy % CONSEJOS.length];
  }


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

    // Métricas agregadas para la franja de estadísticas del home. Todo se
    // deriva del payload de `mi_home_oposicion` (secciones_ok/total por
    // módulo) sin pedir más RPCs. El tiempo total es una estimación amable
    // (~15 min por sección) para dar sensación de progreso longitudinal.
    let seccOk = 0, seccTot = 0, modTot = 0;
    for (const t of temas) {
      for (const m of (t.modulos || [])) {
        seccOk += Number(m.secciones_ok) || 0;
        seccTot += Number(m.secciones_total) || 0;
        modTot += 1;
      }
    }
    const progresoGlobal = seccTot === 0 ? 0 : Math.round(100 * seccOk / seccTot);
    const tiempoEstim = _duracionEstimada(seccTot * 15);

    // Racha: la trae `mi_gamificacion`. Es la misma info que la cabecera; la
    // duplicamos en el home para que la stat-strip esté completa aunque el
    // usuario ya la vea arriba (refuerza el hábito).
    const gm = await S.rpc('mi_gamificacion').catch(() => ({}));
    const racha = Number(gm?.racha_actual) || 0;

    // Tema "por donde lo dejaste": el primero con progreso parcial (> 0 y
    // < 100). Si no hay ninguno con progreso, el primer tema pendiente. Si
    // todo está al 100%, mostramos el primero (para poder repasar). Sin
    // temas, esta card se oculta.
    const temaContinuar = temas.find(t => t.pct > 0 && t.pct < 100)
                        || temas.find(t => t.pct < 100)
                        || temas[0]
                        || null;

    const admin = _esAdmin();
    const varsCont = temaContinuar
      ? _paletaTema(temas.indexOf(temaContinuar))
      : _paletaTema(0);

    root.innerHTML = html`
      <div class="home-top-actions">
        <button class="oposicion-chip" id="btn-cambiar-op"
                title="Cambiar de oposición">
          <span class="oposicion-chip-ico">📚</span>
          <span class="oposicion-chip-nombre">${op.nombre || 'Elige una oposición'}</span>
          <span class="oposicion-chip-caret" aria-hidden="true">▾</span>
        </button>
        ${raw(temas.length > 0 ? html`
          <button class="repaso-chip" id="btn-repasar-op"
                  title="Repasar toda la oposición (40 preguntas)">
            <span class="repaso-chip-ico" aria-hidden="true">🔁</span>
            <span class="repaso-chip-label">Repasar</span>
          </button>
        ` : '')}
      </div>

      <header class="home-head">
        <span class="home-head-emoji" aria-hidden="true">📚</span>
        <div>
          <h1 class="home-title">Temas</h1>
          <p class="home-subtitle">Explora todos los temas y sigue tu progreso</p>
        </div>
      </header>

      ${raw(temaContinuar ? html`
        <button class="continuar-card" id="btn-continuar"
                data-tema="${temaContinuar.id}"
                style="--tema-border:${raw(varsCont.border)}; --tema-soft:${raw(varsCont.soft)}; --tema-strong:${raw(varsCont.strong)};">
          <span class="continuar-icono" aria-hidden="true">${_iconoTema(temaContinuar.nombre, temas.indexOf(temaContinuar))}</span>
          <span class="continuar-copy">
            <small>Continúa por donde lo dejaste</small>
            <strong>${temaContinuar.nombre}</strong>
            <span class="continuar-meta">
              ${temaContinuar.pct}% completado · ${(temaContinuar.modulos || []).length} módulo${(temaContinuar.modulos || []).length === 1 ? '' : 's'}
            </span>
          </span>
          <span class="continuar-cta">Continuar</span>
        </button>
      ` : '')}

      ${raw(temas.length > 0 ? html`
        <section class="stat-strip" aria-label="Resumen de tu progreso">
          <div class="stat-cell">
            <span class="stat-ico stat-ico-temas" aria-hidden="true">📗</span>
            <strong>${temas.length}</strong>
            <small>Temas</small>
          </div>
          <div class="stat-cell">
            <span class="stat-ico stat-ico-prog" aria-hidden="true">✓</span>
            <strong>${progresoGlobal}%</strong>
            <small>Progreso global</small>
          </div>
          <div class="stat-cell">
            <span class="stat-ico stat-ico-time" aria-hidden="true">⏱</span>
            <strong>${tiempoEstim}</strong>
            <small>Tiempo total</small>
          </div>
          <div class="stat-cell">
            <span class="stat-ico stat-ico-fire ${racha > 0 ? 'on' : ''}" aria-hidden="true">🔥</span>
            <strong>${racha}</strong>
            <small>Racha actual</small>
          </div>
        </section>
      ` : '')}

      ${raw(temas.length > 0 ? html`
        <div class="section-head">
          <h2>Todos los temas</h2>
        </div>

        <div class="tema-lista">
          ${raw(temas.map((t, idx) => {
            const pal = _paletaTema(idx);
            const totalModulos = (t.modulos || []).length;
            const totalPreg = Number(t.preguntas_total) || 0;
            const iconoTema = _iconoTema(t.nombre, idx);
            // Chip principal: preguntas si el backend nuevo ya las devuelve;
            // si no, número de secciones como fallback compatible con la RPC
            // antigua para que no salga "0 preguntas" en instancias que
            // todavía no hayan aplicado la migración 2026-07-29.
            const totalSecc = (t.modulos || []).reduce(
              (n, m) => n + (Number(m.secciones_total) || 0), 0);
            const chipMuted = totalPreg > 0
              ? `${totalPreg} pregunta${totalPreg === 1 ? '' : 's'}`
              : `${totalSecc} sección${totalSecc === 1 ? '' : 'es'}`;
            return html`
              <button class="tema-tile" data-tema="${t.id}"
                      style="--tema-border:${raw(pal.border)}; --tema-soft:${raw(pal.soft)}; --tema-strong:${raw(pal.strong)};">
                <span class="tema-tile-icono" aria-hidden="true">
                  <span class="tema-tile-icono-emoji">${iconoTema}</span>
                </span>
                <span class="tema-tile-body">
                  <strong class="tema-tile-titulo">${idx + 1}. ${t.nombre}</strong>
                  <span class="tema-tile-chips">
                    <span class="tema-tile-chip">${totalModulos} módulo${totalModulos === 1 ? '' : 's'}</span>
                    <span class="tema-tile-chip muted">${chipMuted}</span>
                  </span>
                </span>
                <span class="tema-tile-progreso" aria-hidden="true">
                  ${raw(_svgProgreso(t.pct, { size: 44, stroke: 4, color: pal.border }))}
                </span>
                <span class="tema-tile-caret" aria-hidden="true">›</span>
              </button>`;
          }).join(''))}
        </div>

        <aside class="consejo-card">
          <span class="consejo-ico" aria-hidden="true">💡</span>
          <div>
            <strong>Consejo del día</strong>
            <p>${_consejoDelDia()}</p>
          </div>
          <span class="consejo-caret" aria-hidden="true">›</span>
        </aside>
      ` : '')}

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

    root.querySelectorAll('.tema-tile').forEach(c => {
      c.onclick = () => navigate(`#/tema/${c.dataset.tema}`);
    });
    const bc = root.querySelector('#btn-continuar');
    if (bc) bc.onclick = () => navigate(`#/tema/${bc.dataset.tema}`);
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
    // El árbol de la oposición y el documento del tema se piden en paralelo
    // — ambos son datos que necesita esta vista antes del primer render.
    const [home, docTema] = await Promise.all([
      opId ? S.rpc('mi_home_oposicion', { p_oposicion_id: opId })
           : Promise.resolve({ temas: [] }),
      S.rpc('documento_de_tema', { p_tema_id: temaId }).catch(() => null),
    ]);
    const tema = (home.temas || []).find(t => t.id === temaId);
    if (!tema) return empty('Tema no encontrado en tu oposición actual.');

    // Índice del tema dentro de la oposición → determina su color y su
    // icono. Así el color se mantiene coherente con el que se ve en el home.
    const idxTema = (home.temas || []).findIndex(t => t.id === temaId);
    const pal = _paletaTema(idxTema < 0 ? 0 : idxTema);
    const iconoTema = _iconoTema(tema.nombre, idxTema);
    const hayEsquema = !!(docTema && docTema.ruta);
    const puedeSubirEsquema = _esAdmin();

    // Siempre listamos los módulos como tiles clickeables — aunque el tema
    // tenga un único módulo. Antes desplegábamos sus secciones aquí para
    // ahorrar un click, pero eso rompía las migas ("Inicio / Tema" saltaba
    // directo a estudiar sin pasar por el módulo) y desbalanceaba la
    // jerarquía visual entre temas.
    const modulos = tema.modulos || [];

    root.innerHTML = html`
      <div class="view-head">
        <div class="breadcrumbs">
          <a href="#/">${home.oposicion?.nombre || 'Inicio'}</a> / <strong>${tema.nombre}</strong>
        </div>
      </div>

      <header class="tema-hero"
              style="--tema-border:${raw(pal.border)}; --tema-soft:${raw(pal.soft)}; --tema-strong:${raw(pal.strong)};">
        <span class="tema-hero-icono" aria-hidden="true">${iconoTema}</span>
        <div class="tema-hero-body">
          <h1 class="tema-hero-titulo">${tema.nombre}</h1>
          <div class="tema-hero-meta">
            <span>${modulos.length} módulo${modulos.length === 1 ? '' : 's'}</span>
            <span aria-hidden="true">·</span>
            <span>${tema.pct}% completado</span>
            ${raw(Number(tema.preguntas_total) > 0 ? html`
              <span aria-hidden="true">·</span>
              <span>${tema.preguntas_total} pregunta${tema.preguntas_total === 1 ? '' : 's'}</span>
            ` : '')}
          </div>
          <div class="tema-hero-barra" role="progressbar"
               aria-valuenow="${tema.pct}" aria-valuemin="0" aria-valuemax="100">
            <span style="width:${tema.pct}%"></span>
          </div>
        </div>
      </header>

      <div class="tema-actions">
        ${raw(hayEsquema
          ? html`<a class="tema-action" href="#/esquema/tema/${tema.id}">
                  <span aria-hidden="true">📄</span>
                  <span>Ver esquema</span>
                </a>`
          : html`<button class="tema-action is-disabled" type="button"
                        id="btn-ver-esquema-vacio"
                        aria-disabled="true"
                        title="Este tema aún no tiene esquema">
                  <span aria-hidden="true">📄</span>
                  <span>Ver esquema</span>
                </button>`)}
        ${raw(puedeSubirEsquema ? html`
          <button class="tema-action" type="button" id="btn-subir-esquema">
            <span aria-hidden="true">⬆️</span>
            <span>${hayEsquema ? 'Cambiar esquema' : 'Subir esquema'}</span>
          </button>
        ` : '')}
      </div>

      <div class="modulo-lista">
        ${raw(modulos.map((m, i) => {
          const pctModulo = m.secciones_total === 0
            ? 0
            : Math.round(100 * m.secciones_ok / m.secciones_total);
          const preguntasM = Number(m.preguntas_total) || 0;
          return html`
            <button class="modulo-tile" data-modulo="${m.id}"
                    style="--tema-border:${raw(pal.border)}; --tema-soft:${raw(pal.soft)}; --tema-strong:${raw(pal.strong)};">
              <span class="modulo-tile-num" aria-hidden="true">M${i + 1}</span>
              <span class="modulo-tile-body">
                <strong class="modulo-tile-titulo">${m.nombre}</strong>
                <span class="modulo-tile-chips">
                  <span class="modulo-tile-chip">${m.secciones_total} sección${m.secciones_total === 1 ? '' : 'es'}</span>
                  ${raw(preguntasM > 0 ? html`
                    <span class="modulo-tile-chip muted">${preguntasM} pregunta${preguntasM === 1 ? '' : 's'}</span>
                  ` : '')}
                </span>
              </span>
              <span class="modulo-tile-progreso" aria-hidden="true">
                ${raw(_svgProgreso(pctModulo, { size: 40, stroke: 4, color: pal.border }))}
              </span>
              <span class="modulo-tile-caret" aria-hidden="true">›</span>
            </button>`;
        }).join(''))}
      </div>

      ${tema.pct >= 100 ? html`
        <button class="repasar-mini" id="btn-repaso-tema" type="button">
          <span class="repasar-mini-ico" aria-hidden="true">🔁</span>
          <span>Repasar tema completo</span>
          <span aria-hidden="true">›</span>
        </button>
      ` : ''}
    `;

    // Cada tile de módulo navega a su vista (donde ya viven las secciones).
    root.querySelectorAll('.modulo-tile').forEach(el => {
      el.onclick = () => navigate(`#/modulo/${el.dataset.modulo}`);
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
    const btnSubir = root.querySelector('#btn-subir-esquema');
    if (btnSubir) btnSubir.onclick = () => _subirEsquemaTema(tema, docTema, () => viewTema([temaId]));
    const btnVerVacio = root.querySelector('#btn-ver-esquema-vacio');
    if (btnVerVacio) btnVerVacio.onclick = () => showToast('Este tema aún no tiene esquema.');
  }


  // Sube un esquema de tema al microservicio de contenido y lo registra en
  // la tabla `documentos` con nivel='tema', tipo='esquema'.  Sigue el mismo
  // patrón que la subida de teoría desde `viewAdminSeccion`: primero
  // asegura la carpeta destino, luego POST /teoria/api/subir con el
  // fichero, y finalmente `admin_upsert_documento`. Sólo admin — el botón
  // que abre este modal ya está protegido en `viewTema`.
  function _subirEsquemaTema(tema, docPrevio, onDone) {
    // Carpeta convención: /<slug-tema>/esquema/. El microservicio crea las
    // subcarpetas al vuelo con /api/carpeta (idempotente).
    const slug = (tema.slug || 'tema')
      .toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'tema';
    const carpeta = `/${slug}/esquema`;

    _mostrarModal({
      titulo: docPrevio ? 'Cambiar esquema del tema' : 'Subir esquema del tema',
      contenido: html`
        <p class="muted" style="margin-top:0">
          Sube un fichero markdown (<code>.md</code>) con el esquema del tema.
          Se guarda en <code>${carpeta}/</code> y se enlaza como esquema de
          <strong>${tema.nombre}</strong>. ${raw(docPrevio ? html`
            <br>Reemplazará la ruta actual (<code>${docPrevio.ruta}</code>).
          ` : '')}
        </p>
        <form id="form-subir-esquema" class="form-grid">
          <div class="field">
            <label>Fichero</label>
            <input type="file" name="fichero" accept=".md,.markdown,.txt" required>
          </div>
          <div class="form-err" hidden></div>
          <div class="form-row" style="justify-content:flex-end;gap:.5rem">
            <button class="btn" type="button" id="btn-cancelar-esquema">Cancelar</button>
            <button class="btn btn-pri" type="submit" id="btn-guardar-esquema">
              ${docPrevio ? 'Cambiar' : 'Subir'}
            </button>
          </div>
        </form>`,
      onMount(modal) {
        modal.querySelector('#btn-cancelar-esquema').onclick = () => _cerrarModal();
        modal.querySelector('#form-subir-esquema').onsubmit = async (ev) => {
          ev.preventDefault();
          const err = modal.querySelector('.form-err');
          const btn = modal.querySelector('#btn-guardar-esquema');
          err.hidden = true;
          const file = new FormData(ev.target).get('fichero');
          if (!file || !file.name) {
            err.textContent = 'Elige un fichero antes de subir.';
            err.hidden = false;
            return;
          }
          btn.disabled = true;
          btn.textContent = 'Subiendo…';
          try {
            const tok = S.getAccess?.();
            const headers = tok ? { Authorization: `Bearer ${tok}` } : {};
            // 1) Crea la carpeta destino de forma idempotente.
            await fetch('/teoria/api/carpeta', {
              method: 'POST',
              headers: { ...headers, 'Content-Type': 'application/json' },
              body: JSON.stringify({
                padre: carpeta.replace(/\/[^/]+$/, '/') || '/',
                nombre: carpeta.split('/').pop(),
              }),
            }).catch(() => {});
            // 2) Sube el fichero al microservicio de contenido.
            const fd = new FormData();
            fd.append('ruta', carpeta);
            fd.append('files', file);
            const r = await fetch('/teoria/api/subir', {
              method: 'POST', body: fd, headers,
            });
            if (!r.ok) throw new Error('upload_failed');
            const d = await r.json();
            const ruta = d.subidos && d.subidos[0] && d.subidos[0].ruta;
            if (!ruta) throw new Error('no_se_pudo_registrar');
            // 3) Registra la ruta como esquema del tema en `documentos`.
            await S.rpc('admin_upsert_documento', {
              p_nivel: 'tema',
              p_entidad_id: tema.id,
              p_tipo: 'esquema',
              p_ruta: ruta,
            });
            _cerrarModal();
            showToast(docPrevio ? 'Esquema actualizado.' : 'Esquema subido.');
            if (typeof onDone === 'function') onDone();
          } catch (e) {
            err.textContent = _msgError(e.message || String(e));
            err.hidden = false;
            btn.disabled = false;
            btn.textContent = docPrevio ? 'Cambiar' : 'Subir';
          }
        };
      },
    });
  }


  // ── Vista: esquema de un tema (markdown) ───────────────────────────
  async function viewEsquemaTema([temaId]) {
    loading();
    try {
      const opId = getCtx().oposicion_id;
      const [home, doc] = await Promise.all([
        opId ? S.rpc('mi_home_oposicion', { p_oposicion_id: opId })
             : Promise.resolve({ temas: [] }),
        S.rpc('documento_de_tema', { p_tema_id: temaId }).catch(() => null),
      ]);
      const tema = (home.temas || []).find(t => t.id === temaId);
      if (!tema) return empty('Tema no encontrado.');
      const idxTema = (home.temas || []).findIndex(t => t.id === temaId);
      const pal = _paletaTema(idxTema < 0 ? 0 : idxTema);
      const nombreOp = home.oposicion?.nombre || 'Inicio';

      let md = '';
      if (doc && doc.ruta) md = await fetchMarkdown(doc.ruta);
      else md = '## Sin esquema todavía\n\nEste tema aún no tiene esquema subido.';

      root.innerHTML = html`
        <div class="view-head">
          <div class="breadcrumbs">
            <a href="#/">${nombreOp}</a> /
            <a href="#/tema/${tema.id}">${tema.nombre}</a> /
            <strong>Esquema</strong>
          </div>
        </div>

        <header class="tema-hero teoria-hero"
                style="--tema-border:${raw(pal.border)}; --tema-soft:${raw(pal.soft)}; --tema-strong:${raw(pal.strong)};">
          <span class="tema-hero-icono teoria-hero-icono" aria-hidden="true">📄</span>
          <div class="tema-hero-body">
            <span class="teoria-hero-crumb">${tema.nombre}</span>
            <h1 class="tema-hero-titulo">Esquema del tema</h1>
          </div>
        </header>

        <div class="teoria-body">${raw(renderMarkdown(md))}</div>
      `;
    } catch (e) {
      empty('No se pudo cargar el esquema: ' + e.message);
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

    const idxTema = (home.temas || []).findIndex(t => t.id === tema.id);
    const pal = _paletaTema(idxTema < 0 ? 0 : idxTema);
    const pctModulo = totalT === 0 ? 0 : Math.round(100 * totalOk / totalT);

    root.innerHTML = html`
      <div class="view-head">
        <div class="breadcrumbs">
          <a href="#/">${home.oposicion?.nombre || 'Inicio'}</a> /
          <a href="#/tema/${tema.id}">${tema.nombre}</a> /
          <strong>${modulo.nombre}</strong>
        </div>
      </div>

      <header class="tema-hero modulo-hero"
              style="--tema-border:${raw(pal.border)}; --tema-soft:${raw(pal.soft)}; --tema-strong:${raw(pal.strong)};">
        <span class="tema-hero-icono modulo-hero-icono" aria-hidden="true">📘</span>
        <div class="tema-hero-body">
          <h1 class="tema-hero-titulo">${modulo.nombre}</h1>
          <div class="tema-hero-meta">
            <span>${totalOk}/${totalT} sección${totalT === 1 ? '' : 'es'} completada${totalOk === 1 ? '' : 's'}</span>
            <span aria-hidden="true">·</span>
            <span>${pctModulo}%</span>
            ${raw(Number(modulo.preguntas_total) > 0 ? html`
              <span aria-hidden="true">·</span>
              <span>${modulo.preguntas_total} pregunta${modulo.preguntas_total === 1 ? '' : 's'}</span>
            ` : '')}
          </div>
          <div class="tema-hero-barra" role="progressbar"
               aria-valuenow="${pctModulo}" aria-valuemin="0" aria-valuemax="100">
            <span style="width:${pctModulo}%"></span>
          </div>
        </div>
      </header>

      <ol class="seccion-lista modulo-seccion-lista"
          style="--tema-border:${raw(pal.border)}; --tema-soft:${raw(pal.soft)}; --tema-strong:${raw(pal.strong)};">
        ${raw((modulo.secciones || []).map((s, j) => html`
          <li class="seccion-mini ${s.completada ? 'is-done' : ''}"
              data-seccion="${s.id}">
            <span class="seccion-mini-check" aria-hidden="true">
              ${s.completada ? '✓' : (j + 1)}
            </span>
            <span class="seccion-mini-body">
              <span class="seccion-mini-titulo">${s.nombre}</span>
              ${s.nota_max != null
                ? html`<span class="seccion-mini-sub">Última nota: ${Math.round(s.nota_max)}</span>`
                : html`<span class="seccion-mini-sub">Pendiente de estudiar</span>`}
            </span>
            <span class="seccion-mini-cta" data-mini-test="${s.id}"
                  role="button" aria-label="Hacer el test de esta sección"
                  title="Solo test">📝</span>
            <span class="seccion-mini-caret" aria-hidden="true">›</span>
          </li>
        `).join(''))}
      </ol>

      ${completado ? html`
        <button class="repasar-mini" id="btn-repaso-mod" type="button">
          <span class="repasar-mini-ico" aria-hidden="true">🔁</span>
          <span>Repasar todo el módulo</span>
          <span aria-hidden="true">›</span>
        </button>
      ` : ''}
    `;

    // Al pulsar una sección arranca la teoría (con test al final). El icono
    // pequeño 📝 permite ir directo al test, como acceso secundario para
    // quien ya se lo sabe. Está dentro del <li> pero paramos la propagación
    // para que la fila entera no interprete el click como "abrir teoría".
    root.querySelectorAll('.seccion-mini').forEach(el => {
      el.onclick = () => navigate(`#/seccion/${el.dataset.seccion}/teoria`);
    });
    root.querySelectorAll('[data-mini-test]').forEach(el => {
      el.onclick = (ev) => {
        ev.stopPropagation();
        navigate(`#/seccion/${el.dataset.miniTest}/test`);
      };
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
  // Busca una sección en el payload de `mi_home_oposicion` y devuelve el
  // triple (tema, modulo, seccion, idxTema) o null si no aparece — para
  // pintar migas y color heredado sin más RPCs.
  function _localizarSeccion(home, seccId) {
    const temas = home?.temas || [];
    for (let i = 0; i < temas.length; i++) {
      const t = temas[i];
      for (const m of (t.modulos || [])) {
        const s = (m.secciones || []).find(x => x.id === seccId);
        if (s) return { tema: t, modulo: m, seccion: s, idxTema: i };
      }
    }
    return null;
  }

  async function viewTeoria([seccId]) {
    loading();
    try {
      // Necesitamos el árbol completo de la oposición para pintar migas
      // (Tema / Módulo / Sección) coherentes con la vista de tema/módulo.
      // Es una llamada más, pero es el mismo endpoint cacheable que ya usan
      // esas vistas: el navegador reaprovecha la respuesta y la cabecera
      // queda "en armonía" con el resto del flujo.
      const opId = getCtx().oposicion_id;
      const [doc, home] = await Promise.all([
        S.rpc('documento_de_seccion', { p_seccion_id: seccId }).catch(() => null),
        opId ? S.rpc('mi_home_oposicion', { p_oposicion_id: opId })
             : Promise.resolve({ temas: [] }),
      ]);
      const ctx = _localizarSeccion(home, seccId);

      let md = '';
      if (doc && doc.ruta) md = await fetchMarkdown(doc.ruta);
      else md = '## Sin teoría todavía\n\nEsta sección no tiene documento de teoría subido.';

      // Marca la teoría como vista (idempotente).
      S.rpc('marcar_teoria_vista', { p_seccion_id: seccId }).catch(() => {});

      const pal = ctx ? _paletaTema(ctx.idxTema) : _paletaTema(0);
      const nombreOp = home.oposicion?.nombre || 'Inicio';

      root.innerHTML = html`
        <div class="view-head">
          <div class="breadcrumbs">
            <a href="#/">${nombreOp}</a>
            ${raw(ctx ? html`
              / <a href="#/tema/${ctx.tema.id}">${ctx.tema.nombre}</a>
              / <a href="#/modulo/${ctx.modulo.id}">${ctx.modulo.nombre}</a>
              / <strong>${ctx.seccion.nombre}</strong>
            ` : ' / <strong>Teoría</strong>')}
          </div>
        </div>

        ${raw(ctx ? html`
          <header class="tema-hero teoria-hero"
                  style="--tema-border:${raw(pal.border)}; --tema-soft:${raw(pal.soft)}; --tema-strong:${raw(pal.strong)};">
            <span class="tema-hero-icono teoria-hero-icono" aria-hidden="true">📖</span>
            <div class="tema-hero-body">
              <span class="teoria-hero-crumb">${ctx.tema.nombre} · ${ctx.modulo.nombre}</span>
              <h1 class="tema-hero-titulo">${ctx.seccion.nombre}</h1>
            </div>
          </header>
        ` : '')}

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
    // Fija el snapshot ANTES del test para que al finalizar el diff detecte
    // los retos/logros que se hayan desbloqueado durante este intento.
    gamif.snapshot();

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
        // El backend actualiza retos/logros vía triggers; el frontend hace
        // diff local para pintar la tarjeta de "¡Reto completado!" / etc.
        gamif.checkNuevos();
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
                <button class="btn btn-cancel btn-sm" type="button" id="cancelar-borrar">Cancelar</button>
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
          <button class="btn btn-cancel btn-sm" type="button" id="conf-cancel">Cancelar</button>
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
    if (!_esAdmin()) return empty('Acceso restringido.');
    loading();
    const q = params.get('q') || '';
    const page = +(params.get('page') || 1);
    const [rs, roles] = await Promise.all([
      S.rpc('listar_usuarios', { p_q: q || null, p_page: page, p_size: 20 }),
      S.rpc('listar_roles'),
    ]);

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
        <div class="user-card" data-uid="${u.id}">
          <div class="user-head">
            <strong>${u.nombre_visible}</strong>
            <span class="muted small">${u.email}</span>
            ${raw(u.email_verificado
              ? '<span class="kv-badge ok">verificado</span>'
              : '<span class="kv-badge warn">sin verificar</span>')}
            ${raw(u.totp_activo ? '<span class="kv-badge">2FA</span>' : '')}
            ${raw(!u.activo ? '<span class="kv-badge danger">DESACTIVADO</span>' : '')}
          </div>
          <div class="user-roles">
            ${raw((u.roles || []).length
              ? (u.roles.map(r => `<span class="role-chip">${esc(r)}</span>`).join(''))
              : '<span class="muted small">sin roles</span>')}
          </div>
          <div class="muted small user-meta">
            Último login: ${u.ultimo_login_en ? new Date(u.ultimo_login_en).toLocaleString() : '—'}
            · Sesiones activas: ${u.sesiones_activas}
          </div>
          <div class="user-actions">
            <button class="btn btn-sm btn-pri" data-act="roles">Editar roles</button>
            <button class="btn btn-sm" data-act="reset">Enviar reset pass</button>
            <button class="btn btn-sm" data-act="logout">Cerrar sesiones</button>
            <button class="btn btn-sm" data-act="toggle-activo">${u.activo ? 'Desactivar' : 'Activar'}</button>
            <button class="btn btn-sm btn-danger-outline" data-act="borrar">Borrar</button>
          </div>
        </div>
      `).join(''))}
      ${raw((rs.usuarios || []).length === 0
        ? '<div class="empty">No hay usuarios que encajen con la búsqueda.</div>'
        : '')}
      ${raw(rs.total_pages > 1
        ? html`<div class="form-row" style="justify-content:center; margin-top:1rem">
            ${raw(page > 1
              ? `<a class="btn btn-sm" href="#/admin/usuarios?q=${encodeURIComponent(q)}&page=${page-1}">← Anterior</a>`
              : '')}
            <span class="muted small" style="align-self:center">Página ${page} de ${rs.total_pages}</span>
            ${raw(page < rs.total_pages
              ? `<a class="btn btn-sm" href="#/admin/usuarios?q=${encodeURIComponent(q)}&page=${page+1}">Siguiente →</a>`
              : '')}
          </div>`
        : '')}
    `;

    root.querySelector('#form-search').onsubmit = (e) => {
      e.preventDefault();
      const nq = new FormData(e.target).get('q');
      navigate(`#/admin/usuarios?q=${encodeURIComponent(nq)}`);
    };

    root.querySelectorAll('.user-card[data-uid]').forEach(card => {
      const uid = card.dataset.uid;
      const user = (rs.usuarios || []).find(x => x.id === uid);
      card.querySelectorAll('[data-act]').forEach(btn => {
        btn.onclick = async () => {
          const act = btn.dataset.act;
          try {
            if (act === 'reset') {
              _confirmar({
                titulo: 'Enviar enlace de reset',
                mensaje: `Se enviará a ${user.email} un enlace para restablecer su contraseña (válido 30 min).`,
                confirmar: 'Enviar',
                onOk: async () => {
                  await S.rpc('forzar_reset_password', { p_usuario_id: uid });
                  showToast('Reset enviado por email.');
                },
              });
            } else if (act === 'logout') {
              _confirmar({
                titulo: 'Cerrar todas las sesiones',
                mensaje: `Se cerrarán todas las sesiones activas de ${user.email}. Tendrá que volver a iniciar sesión.`,
                confirmar: 'Cerrar sesiones', peligroso: true,
                onOk: async () => {
                  await S.rpc('forzar_logout_global', { p_usuario_id: uid });
                  showToast('Sesiones revocadas.');
                  viewAdminUsuarios(_, params);
                },
              });
            } else if (act === 'toggle-activo') {
              await S.rpc('set_usuario_activo',
                { p_usuario_id: uid, p_activo: !user.activo });
              viewAdminUsuarios(_, params);
            } else if (act === 'roles') {
              _editarRolesUsuario(user, roles || []);
            } else if (act === 'borrar') {
              _confirmar({
                titulo: 'Borrar cuenta',
                mensaje: `¿Borrar a ${user.email}? Se anonimiza el email y el nombre; sus intentos y respuestas se conservan sin dueño. Acción irreversible.`,
                confirmar: 'Borrar cuenta', peligroso: true,
                onOk: async () => {
                  await S.rpc('borrar_usuario_admin', { p_usuario_id: uid });
                  showToast('Cuenta borrada.');
                  viewAdminUsuarios(_, params);
                },
              });
            }
          } catch (e) { showToast(_msgError(e.message)); }
        };
      });
    });
  }


  // Modal editor de roles. `catalogoRoles` viene de listar_roles(). Sale un
  // checkbox por rol con la descripción a la derecha. Al guardar, calcula el
  // diff y llama asignar_rol / quitar_rol solo para los que cambian.
  function _editarRolesUsuario(user, catalogoRoles) {
    const asignados = new Set(user.roles || []);
    _mostrarModal({
      titulo: `Roles de ${user.nombre_visible || user.email}`,
      contenido: html`
        <p class="muted small" style="margin:0 0 .75rem">
          Marca los roles que quieres que tenga este usuario.
        </p>
        <form id="form-roles" class="roles-editor">
          ${raw((catalogoRoles || []).map(r => `
            <label class="role-row">
              <input type="checkbox" name="rol" value="${esc(r.id)}"
                     ${asignados.has(r.id) ? 'checked' : ''}>
              <span class="role-info">
                <strong>${esc(r.id)}</strong>
                ${r.descripcion ? `<small class="muted">${esc(r.descripcion)}</small>` : ''}
              </span>
            </label>
          `).join(''))}
          <div class="form-err" hidden></div>
          <div class="form-row" style="justify-content:flex-end; margin-top:.75rem">
            <button class="btn btn-cancel btn-sm" type="button" data-cancel>Cancelar</button>
            <button class="btn btn-pri btn-sm" type="submit">Guardar</button>
          </div>
        </form>`,
      onMount(modal) {
        modal.querySelector('[data-cancel]').onclick = _cerrarModal;
        modal.querySelector('#form-roles').onsubmit = async (e) => {
          e.preventDefault();
          const seleccionados = new Set(
            [...modal.querySelectorAll('input[name="rol"]:checked')]
              .map(i => i.value));
          const err = modal.querySelector('.form-err');
          err.hidden = true;
          try {
            // Añadidos primero (menos riesgo de quedarse sin admin a mitad).
            for (const r of seleccionados) {
              if (!asignados.has(r)) {
                await S.rpc('asignar_rol', { p_usuario_id: user.id, p_rol_id: r });
              }
            }
            for (const r of asignados) {
              if (!seleccionados.has(r)) {
                await S.rpc('quitar_rol', { p_usuario_id: user.id, p_rol_id: r });
              }
            }
            _cerrarModal();
            showToast('Roles actualizados.');
            viewAdminUsuarios(null, new URLSearchParams(location.hash.split('?')[1] || ''));
          } catch (ex) {
            err.textContent = _msgError(ex.message);
            err.hidden = false;
          }
        };
      },
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
    // crumbs: [{label, href?}, ...]  — el último se pinta como chip activo,
    // el resto como pastilla salvia con separador solarpunk (›). Nada de
    // <a> azules subrayados: el estilo lo aporta .admin-crumbs.
    return html`
      <div class="admin-tabs">
        <a class="tab" href="#/admin/usuarios">Usuarios</a>
        <a class="tab active" href="#/admin/contenido">Contenido</a>
        <a class="tab" href="#/admin/duplicados">Duplicados</a>
      </div>
      <nav class="admin-crumbs" aria-label="Ruta de navegación">
        ${raw(crumbs.map((c, i) => {
          const last = i === crumbs.length - 1;
          const sep = last ? '' : '<span class="admin-crumbs__sep" aria-hidden="true">›</span>';
          if (last) return `<span class="admin-crumbs__crumb is-current" aria-current="page">${esc(c.label)}</span>`;
          return `<a class="admin-crumbs__crumb" href="${c.href || '#/'}">${esc(c.label)}</a>${sep}`;
        }).join(''))}
      </nav>`;
  }

  function _oposicionDelTema(tema, oposiciones) {
    const ids = Array.isArray(tema?.oposicion_ids) ? tema.oposicion_ids : [];
    const idPreferido = getCtx().admin_oposicion_id;
    const id = ids.includes(idPreferido) ? idPreferido : ids[0];
    return (oposiciones || []).find(oposicion => oposicion.id === id) || null;
  }

  function _migasContenido(tema, oposicion, niveles = []) {
    return [
      { label: 'Oposiciones', href: '#/admin/contenido' },
      ...(oposicion ? [{
        label: oposicion.nombre,
        href: `#/admin/contenido/oposicion/${oposicion.id}`,
      }] : []),
      {
        label: tema.nombre,
        ...(niveles.length ? { href: `#/admin/contenido/tema/${tema.id}` } : {}),
      },
      ...niveles,
    ];
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
        <button class="btn btn-sm" id="btn-importar-op">📥 Importar desde JSON</button>
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
    root.querySelector('#btn-importar-op').onclick = () =>
      _importarOposicionJSON(() => viewAdminOposiciones());

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
            <button class="btn btn-cancel btn-sm" type="button" data-cancel>Cancelar</button>
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
    setCtx({ admin_oposicion_id: opId });

    root.innerHTML = html`
      ${raw(_adminNav([
        { label: 'Oposiciones', href: '#/admin/contenido' },
        { label: op.nombre },
      ]))}
      <div class="view-head"><h2>${op.nombre}</h2></div>
      ${op.descripcion ? html`<p class="muted">${op.descripcion}</p>` : ''}

      <div class="admin-toolbar">
        <h3 style="margin:0; flex:1">Temas</h3>
        <button class="btn btn-sm" id="btn-importar-temas">📥 Importar temas</button>
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
    root.querySelector('#btn-importar-temas').onclick = () =>
      _importarTemasJSON(opId, () => viewAdminOposicion([opId]));
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
            <button class="btn btn-cancel btn-sm" type="button" data-cancel>Cancelar</button>
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
    const [temas, oposiciones] = await Promise.all([
      S.rpc('admin_listar_temas', { p_oposicion_id: null }),
      S.rpc('admin_listar_oposiciones'),
    ]);
    const tema = (temas || []).find(x => x.id === tid);
    if (!tema) return empty('Tema no encontrado.');
    const oposicion = _oposicionDelTema(tema, oposiciones);
    if (oposicion) setCtx({ admin_oposicion_id: oposicion.id });
    const modulos = await S.rpc('admin_listar_modulos', { p_tema_id: tid });

    root.innerHTML = html`
      ${raw(_adminNav(_migasContenido(tema, oposicion)))}
      <div class="view-head"><h2>${tema.nombre}</h2></div>
      ${tema.descripcion ? html`<p class="muted">${tema.descripcion}</p>` : ''}

      <div class="admin-toolbar">
        <h3 style="margin:0; flex:1">Módulos</h3>
        <button class="btn btn-sm" id="btn-editar-tema">✏️ Editar tema</button>
        <button class="btn btn-sm" id="btn-importar-modulos">📥 Importar módulos</button>
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
    root.querySelector('#btn-importar-modulos').onclick = () =>
      _importarModulosJSON(tid, () => viewAdminTema([tid]));
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
            <button class="btn btn-cancel btn-sm" type="button" data-cancel>Cancelar</button>
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
    const [temas, oposiciones] = await Promise.all([
      S.rpc('admin_listar_temas', { p_oposicion_id: null }),
      S.rpc('admin_listar_oposiciones'),
    ]);
    let tema = null, modulo = null;
    for (const t of temas) {
      const mods = await S.rpc('admin_listar_modulos', { p_tema_id: t.id });
      const m = (mods || []).find(x => x.id === mid);
      if (m) { tema = t; modulo = m; break; }
    }
    if (!modulo) return empty('Módulo no encontrado.');
    const oposicion = _oposicionDelTema(tema, oposiciones);
    const secciones = await S.rpc('admin_listar_secciones', { p_modulo_id: mid });

    root.innerHTML = html`
      ${raw(_adminNav(_migasContenido(tema, oposicion, [
        { label: modulo.nombre },
      ])))}
      <div class="view-head"><h2>${modulo.nombre}</h2></div>
      <div class="admin-toolbar">
        <h3 style="margin:0; flex:1">Secciones</h3>
        <button class="btn btn-sm" id="btn-importar-secciones">📥 Importar secciones</button>
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
    root.querySelector('#btn-importar-secciones').onclick = () =>
      _importarSeccionesJSON(mid, () => viewAdminModulo([mid]));
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
            <button class="btn btn-cancel btn-sm" type="button" data-cancel>Cancelar</button>
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
    const [temas, oposiciones] = await Promise.all([
      S.rpc('admin_listar_temas', { p_oposicion_id: null }),
      S.rpc('admin_listar_oposiciones'),
    ]);
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
    const oposicion = _oposicionDelTema(tema, oposiciones);
    const preguntas = await S.rpc('admin_preguntas_de_seccion', { p_seccion_id: sid });
    const docTeoria = await S.rpc('documento_de_seccion', { p_seccion_id: sid })
      .catch(() => null);

    root.innerHTML = html`
      ${raw(_adminNav(_migasContenido(tema, oposicion, [
        { label: modulo.nombre, href: `#/admin/contenido/modulo/${modulo.id}` },
        { label: seccion.nombre },
      ])))}
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
        <button class="btn btn-pri btn-sm" id="btn-subir-preg">📥 Subir JSON de preguntas</button>
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

    // Preguntas — sólo subida por JSON: descartamos "nueva a mano" para
    // que el flujo de creación pase siempre por un fichero validable.
    root.querySelector('#btn-subir-preg').onclick = () => _subirPreguntasJSON(sid);
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
            <button class="btn btn-cancel btn-sm" type="button" data-cancel>Cancelar</button>
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


  // ── Utilidad: lee un fichero <input type=file> y devuelve su texto ─
  function _leerFicheroTexto(file) {
    return new Promise((resolve, reject) => {
      const rd = new FileReader();
      rd.onerror = () => reject(new Error('no_se_pudo_leer'));
      rd.onload = () => resolve(String(rd.result || ''));
      rd.readAsText(file, 'utf-8');
    });
  }

  // Subir preguntas de una sección desde un fichero JSON.
  // Formato aceptado (array):
  //   [{
  //     "pregunta": "enunciado",
  //     "opciones": ["Correcta", "Opción 2", "Opción 3", "Opción 4"],
  //     "explicacion": "…"
  //   }, ...]
  // La PRIMERA opción es la correcta (convención acordada); el resto se
  // marcan como incorrectas. `admin_crear_pregunta` es UPSERT por hash
  // de contenido, así que reintentar la misma subida no duplica.
  function _subirPreguntasJSON(seccionId) {
    let parsed = null;   // array normalizado listo para enviar
    let raw = '';        // texto original para la vista de previsualización

    function _validar(text) {
      let data;
      try { data = JSON.parse(text); }
      catch (e) { throw new Error('json_invalido'); }
      if (!Array.isArray(data)) throw new Error('debe_ser_array');
      if (data.length === 0)    throw new Error('array_vacio');
      return data.map((p, i) => {
        const enunciado = String(p?.pregunta ?? '').trim();
        const ops = Array.isArray(p?.opciones) ? p.opciones : [];
        const explicacion = (p?.explicacion == null)
          ? null
          : String(p.explicacion).trim() || null;
        if (!enunciado) throw new Error(`pregunta_${i+1}_sin_enunciado`);
        if (ops.length < 2) throw new Error(`pregunta_${i+1}_pocas_opciones`);
        const opciones = ops.map((t, j) => ({
          texto: String(t ?? '').trim(),
          correcta: j === 0,
        }));
        if (opciones.some(o => !o.texto)) throw new Error(`pregunta_${i+1}_opcion_vacia`);
        return { enunciado, opciones, explicacion };
      });
    }

    _mostrarModal({
      titulo: 'Subir preguntas desde JSON',
      contenido: html`
        <p class="muted small" style="margin:0 0 .75rem">
          Formato esperado (array). La <strong>primera opción</strong> de cada
          pregunta es la correcta.
        </p>
        <label class="json-drop" for="fp-json">
          <span id="fp-json-label">📁 Elegir fichero <code>.json</code> o pegar debajo</span>
          <input id="fp-json" type="file" accept=".json,application/json">
        </label>
        <div class="campo-json">
          <label for="ta-json">O pega el JSON aquí</label>
          <textarea id="ta-json" rows="8" spellcheck="false"
            placeholder='[
  {"pregunta": "…", "opciones": ["Correcta", "Op2", "Op3", "Op4"], "explicacion": "…"}
]'></textarea>
        </div>
        <div class="json-preview__summary" id="sum-json" hidden></div>
        <div class="form-err" hidden></div>
        <div class="form-row" style="justify-content:flex-end; margin-top:.75rem">
          <button class="btn btn-cancel btn-sm" type="button" data-cancel>Cancelar</button>
          <button class="btn btn-pri btn-sm" type="button" id="btn-subir-ok" disabled>Subir preguntas</button>
        </div>`,
      onMount(modal) {
        const ta    = modal.querySelector('#ta-json');
        const err   = modal.querySelector('.form-err');
        const sum   = modal.querySelector('#sum-json');
        const btnOk = modal.querySelector('#btn-subir-ok');
        const label = modal.querySelector('#fp-json-label');

        function _refresh() {
          err.hidden = true;
          sum.hidden = true;
          btnOk.disabled = true;
          parsed = null;
          const text = ta.value.trim();
          if (!text) return;
          try {
            parsed = _validar(text);
            sum.innerHTML =
              `<span class="kv-badge ok">${parsed.length} pregunta(s) válidas</span>`;
            sum.hidden = false;
            btnOk.disabled = false;
          } catch (e) {
            err.textContent = _msgError(e.message);
            err.hidden = false;
          }
        }
        ta.oninput = _refresh;

        modal.querySelector('#fp-json').onchange = async (ev) => {
          const f = ev.target.files && ev.target.files[0];
          if (!f) return;
          try {
            raw = await _leerFicheroTexto(f);
            ta.value = raw;
            label.textContent = '📄 ' + f.name;
            _refresh();
          } catch (e) {
            err.textContent = _msgError(e.message);
            err.hidden = false;
          }
        };

        modal.querySelector('[data-cancel]').onclick = _cerrarModal;
        btnOk.onclick = async () => {
          if (!parsed) return;
          btnOk.disabled = true;
          err.hidden = true;
          const total = parsed.length;
          let creadas = 0, falladas = 0;
          for (const p of parsed) {
            try {
              await S.rpc('admin_crear_pregunta', {
                p_seccion_id: seccionId,
                p_enunciado: p.enunciado,
                p_opciones: p.opciones,
                p_explicacion: p.explicacion,
              });
              creadas++;
              btnOk.textContent = `Subiendo ${creadas}/${total}…`;
            } catch (e) {
              falladas++;
            }
          }
          _cerrarModal();
          if (falladas === 0) {
            showToast(`${creadas} pregunta(s) subidas.`);
          } else {
            showToast(`${creadas} subidas · ${falladas} fallaron`);
          }
          viewAdminSeccion([seccionId]);
        };
      },
    });
  }

  function _normalizarSecciones(datos, ruta = 'seccion') {
    if (!Array.isArray(datos)) throw new Error('secciones_debe_ser_array');
    return datos.map((seccion, indice) => {
      const nombre = String(seccion?.nombre || '').trim();
      if (!nombre) throw new Error(`${ruta}_${indice + 1}_sin_nombre`);
      return {
        nombre,
        orden: (seccion.orden != null ? +seccion.orden : indice + 1) || null,
        min_aprobado: seccion.min_aprobado != null ? +seccion.min_aprobado : 70,
        n_preg_test: seccion.n_preg_test != null ? +seccion.n_preg_test : 10,
      };
    });
  }

  function _normalizarModulos(datos, ruta = 'modulo') {
    if (!Array.isArray(datos)) throw new Error('modulos_debe_ser_array');
    return datos.map((modulo, indice) => {
      const nombre = String(modulo?.nombre || '').trim();
      if (!nombre) throw new Error(`${ruta}_${indice + 1}_sin_nombre`);
      return {
        nombre,
        orden: (modulo.orden != null ? +modulo.orden : indice + 1) || null,
        secciones: _normalizarSecciones(
          Array.isArray(modulo.secciones) ? modulo.secciones : [],
          `${ruta}_${indice + 1}_seccion`),
      };
    });
  }

  function _normalizarTemas(datos) {
    if (!Array.isArray(datos)) throw new Error('temas_debe_ser_array');
    return datos.map((tema, indice) => {
      const nombre = String(tema?.nombre || '').trim();
      if (!nombre) throw new Error(`tema_${indice + 1}_sin_nombre`);
      return {
        nombre,
        descripcion: tema.descripcion ? String(tema.descripcion).trim() : null,
        modulos: _normalizarModulos(
          Array.isArray(tema.modulos) ? tema.modulos : [],
          `tema_${indice + 1}_modulo`),
      };
    });
  }

  async function _crearSeccionesAusentes(moduloId, secciones) {
    const existentes = await S.rpc('admin_listar_secciones', { p_modulo_id: moduloId }) || [];
    const nombres = new Set(existentes.map(s => String(s.nombre).trim().toLowerCase()));
    let creadas = 0;
    for (const seccion of secciones) {
      if (nombres.has(seccion.nombre.toLowerCase())) continue;
      await S.rpc('admin_crear_seccion', {
        p_modulo_id: moduloId,
        p_nombre: seccion.nombre,
        p_orden: seccion.orden,
        p_min_aprobado: seccion.min_aprobado,
        p_n_preg_test: seccion.n_preg_test,
      });
      nombres.add(seccion.nombre.toLowerCase());
      creadas++;
    }
    return creadas;
  }

  function _mostrarImportadorEstructura({ titulo, ayuda, ejemplo, validar, confirmar, procesar }) {
    let datos = null;
    _mostrarModal({
      titulo,
      contenido: html`
        <p class="muted small ayuda-importacion">${ayuda}</p>
        <label class="json-drop" for="fichero-estructura-json">
          <span id="etiqueta-fichero-estructura">📁 Elegir fichero <code>.json</code> o pegar debajo</span>
          <input id="fichero-estructura-json" type="file" accept=".json,application/json">
        </label>
        <div class="campo-json">
          <label for="texto-estructura-json">O pega el JSON aquí</label>
          <textarea id="texto-estructura-json" rows="10" spellcheck="false"
            placeholder="${ejemplo}"></textarea>
          <span class="campo-json__ayuda">Se valida automáticamente y no se importan nombres duplicados.</span>
        </div>
        <div class="json-preview__summary" id="resumen-estructura-json" hidden></div>
        <div class="form-err" hidden></div>
        <div class="form-row acciones-importacion">
          <button class="btn btn-cancel btn-sm" type="button" data-cancel>Cancelar</button>
          <button class="btn btn-pri btn-sm" type="button" id="confirmar-estructura-json" disabled>${confirmar}</button>
        </div>`,
      onMount(modal) {
        const texto = modal.querySelector('#texto-estructura-json');
        const error = modal.querySelector('.form-err');
        const resumen = modal.querySelector('#resumen-estructura-json');
        const boton = modal.querySelector('#confirmar-estructura-json');
        const etiqueta = modal.querySelector('#etiqueta-fichero-estructura');
        const actualizar = () => {
          datos = null;
          error.hidden = true;
          resumen.hidden = true;
          boton.disabled = true;
          if (!texto.value.trim()) return;
          try {
            datos = validar(texto.value);
            resumen.textContent = datos.resumen;
            resumen.hidden = false;
            boton.disabled = false;
          } catch (e) {
            error.textContent = _msgError(e.message);
            error.hidden = false;
          }
        };
        texto.oninput = actualizar;
        modal.querySelector('#fichero-estructura-json').onchange = async (evento) => {
          const fichero = evento.target.files?.[0];
          if (!fichero) return;
          try {
            texto.value = await _leerFicheroTexto(fichero);
            etiqueta.textContent = `📄 ${fichero.name}`;
            actualizar();
          } catch (e) {
            error.textContent = _msgError(e.message);
            error.hidden = false;
          }
        };
        modal.querySelector('[data-cancel]').onclick = _cerrarModal;
        boton.onclick = async () => {
          if (!datos) return;
          boton.disabled = true;
          error.hidden = true;
          try {
            boton.textContent = 'Importando…';
            const mensaje = await procesar(datos.valor);
            _cerrarModal();
            showToast(mensaje);
          } catch (e) {
            boton.disabled = false;
            boton.textContent = confirmar;
            error.textContent = _msgError(e.message || String(e));
            error.hidden = false;
          }
        };
      },
    });
  }

  function _importarTemasJSON(oposicionId, refrescar) {
    _mostrarImportadorEstructura({
      titulo: 'Importar temas desde JSON',
      ayuda: 'Añade temas a esta oposición junto con sus módulos y secciones. Los elementos existentes con el mismo nombre se reutilizan.',
      ejemplo: '[\n  {\n    "nombre": "Constitución",\n    "modulos": [\n      {"nombre": "Título preliminar", "secciones": [{"nombre": "Artículos 1-9"}]}\n    ]\n  }\n]',
      confirmar: 'Importar temas',
      validar(texto) {
        let json;
        try { json = JSON.parse(texto); } catch { throw new Error('json_invalido'); }
        const temas = _normalizarTemas(Array.isArray(json) ? json : json?.temas);
        const modulos = temas.reduce((total, tema) => total + tema.modulos.length, 0);
        const secciones = temas.reduce((total, tema) =>
          total + tema.modulos.reduce((subtotal, modulo) => subtotal + modulo.secciones.length, 0), 0);
        return { valor: temas, resumen: `${temas.length} tema(s) · ${modulos} módulo(s) · ${secciones} sección(es)` };
      },
      async procesar(temas) {
        const catalogo = await S.rpc('admin_listar_temas', { p_oposicion_id: null }) || [];
        const porNombre = new Map(catalogo.map(t => [String(t.nombre).trim().toLowerCase(), t]));
        let temasNuevos = 0, modulosNuevos = 0, seccionesNuevas = 0;
        for (const tema of temas) {
          const existente = porNombre.get(tema.nombre.toLowerCase());
          let temaId;
          if (existente) {
            temaId = existente.id;
            await S.rpc('admin_asignar_tema_a_oposicion', {
              p_oposicion_id: oposicionId, p_tema_id: temaId,
            }).catch(() => {});
          } else {
            const creado = await S.rpc('admin_crear_tema', {
              p_nombre: tema.nombre, p_descripcion: tema.descripcion, p_oposicion_id: oposicionId,
            });
            temaId = creado?.id || creado?.tema_id || creado;
            temasNuevos++;
          }
          const modulos = await S.rpc('admin_listar_modulos', { p_tema_id: temaId }) || [];
          const modulosPorNombre = new Map(modulos.map(m => [String(m.nombre).trim().toLowerCase(), m]));
          for (const modulo of tema.modulos) {
            const moduloExistente = modulosPorNombre.get(modulo.nombre.toLowerCase());
            let moduloId = moduloExistente?.id;
            if (!moduloId) {
              const creado = await S.rpc('admin_crear_modulo', {
                p_tema_id: temaId, p_nombre: modulo.nombre, p_orden: modulo.orden,
              });
              moduloId = creado?.id || creado?.modulo_id || creado;
              modulosNuevos++;
            }
            seccionesNuevas += await _crearSeccionesAusentes(moduloId, modulo.secciones);
          }
        }
        if (typeof refrescar === 'function') refrescar();
        return `${temasNuevos} tema(s), ${modulosNuevos} módulo(s) y ${seccionesNuevas} sección(es) creados.`;
      },
    });
  }

  function _importarModulosJSON(temaId, refrescar) {
    _mostrarImportadorEstructura({
      titulo: 'Importar módulos desde JSON',
      ayuda: 'Añade módulos a este tema junto con sus secciones. Los módulos y secciones existentes con el mismo nombre se reutilizan.',
      ejemplo: '[\n  {\n    "nombre": "Título I",\n    "orden": 1,\n    "secciones": [\n      {"nombre": "Sección 1", "orden": 1}\n    ]\n  }\n]',
      confirmar: 'Importar módulos',
      validar(texto) {
        let json;
        try { json = JSON.parse(texto); } catch { throw new Error('json_invalido'); }
        const modulos = _normalizarModulos(Array.isArray(json) ? json : json?.modulos);
        const secciones = modulos.reduce((total, modulo) => total + modulo.secciones.length, 0);
        return {
          valor: modulos,
          resumen: `${modulos.length} módulo(s) · ${secciones} sección(es)`,
        };
      },
      async procesar(modulos) {
        const existentes = await S.rpc('admin_listar_modulos', { p_tema_id: temaId }) || [];
        const porNombre = new Map(existentes.map(modulo =>
          [String(modulo.nombre).trim().toLowerCase(), modulo]));
        let modulosNuevos = 0;
        let seccionesNuevas = 0;
        for (const modulo of modulos) {
          const existente = porNombre.get(modulo.nombre.toLowerCase());
          let moduloId = existente?.id;
          if (!moduloId) {
            const creado = await S.rpc('admin_crear_modulo', {
              p_tema_id: temaId,
              p_nombre: modulo.nombre,
              p_orden: modulo.orden,
            });
            moduloId = creado?.id || creado?.modulo_id || creado;
            modulosNuevos++;
          }
          seccionesNuevas += await _crearSeccionesAusentes(moduloId, modulo.secciones);
        }
        if (typeof refrescar === 'function') refrescar();
        return `${modulosNuevos} módulo(s) y ${seccionesNuevas} sección(es) creados; los duplicados se han omitido.`;
      },
    });
  }

  function _importarSeccionesJSON(moduloId, refrescar) {
    _mostrarImportadorEstructura({
      titulo: 'Importar secciones desde JSON',
      ayuda: 'Añade varias secciones a este módulo. Puedes incluir orden, mínimo de aprobado y número de preguntas por test.',
      ejemplo: '[\n  {"nombre": "Artículos 1-9", "orden": 1, "min_aprobado": 70, "n_preg_test": 10}\n]',
      confirmar: 'Importar secciones',
      validar(texto) {
        let json;
        try { json = JSON.parse(texto); } catch { throw new Error('json_invalido'); }
        const secciones = _normalizarSecciones(Array.isArray(json) ? json : json?.secciones);
        return { valor: secciones, resumen: `${secciones.length} sección(es) válidas` };
      },
      async procesar(secciones) {
        const creadas = await _crearSeccionesAusentes(moduloId, secciones);
        if (typeof refrescar === 'function') refrescar();
        return `${creadas} sección(es) creadas; las duplicadas se han omitido.`;
      },
    });
  }

  // Importa una oposición completa (o sólo la estructura) desde un JSON.
  // Formato aceptado:
  //   {
  //     "nombre": "Nombre de la oposición",
  //     "descripcion": "…" (opcional),
  //     "temas": [
  //       {
  //         "nombre": "Tema 1",
  //         "descripcion": "…" (opcional),
  //         "modulos": [
  //           {
  //             "nombre": "Módulo A",
  //             "secciones": [
  //               {"nombre": "Sección Z", "min_aprobado": 70, "n_preg_test": 10}
  //             ]
  //           }
  //         ]
  //       }
  //     ]
  //   }
  //
  // Reglas de reutilización:
  //   · Si ya existe un tema con el mismo `nombre` en el catálogo global,
  //     se REUTILIZA (se vincula a la oposición nueva con sus módulos y
  //     secciones existentes) — nunca se crea otro tema con nombre igual.
  //   · Módulos y secciones dentro de un tema existente se comparan por
  //     `nombre`: si ya existe, se conserva; si es nuevo, se crea.
  function _importarOposicionJSON(refresh) {
    let parsed = null;

    function _validar(text) {
      let data;
      try { data = JSON.parse(text); }
      catch (e) { throw new Error('json_invalido'); }
      if (!data || typeof data !== 'object') throw new Error('json_debe_ser_objeto');
      const nombre = String(data.nombre || '').trim();
      if (!nombre) throw new Error('oposicion_sin_nombre');
      const descripcion = data.descripcion ? String(data.descripcion).trim() : null;
      const temas = Array.isArray(data.temas) ? data.temas : [];
      const temasN = temas.map((t, i) => {
        const tnom = String(t?.nombre || '').trim();
        if (!tnom) throw new Error(`tema_${i+1}_sin_nombre`);
        const modulos = Array.isArray(t?.modulos) ? t.modulos : [];
        const modulosN = modulos.map((m, j) => {
          const mnom = String(m?.nombre || '').trim();
          if (!mnom) throw new Error(`tema_${i+1}_modulo_${j+1}_sin_nombre`);
          const secs = Array.isArray(m?.secciones) ? m.secciones : [];
          const secsN = secs.map((s, k) => {
            const snom = String(s?.nombre || '').trim();
            if (!snom) throw new Error(`tema_${i+1}_modulo_${j+1}_seccion_${k+1}_sin_nombre`);
            return {
              nombre: snom,
              orden: (s.orden != null ? +s.orden : (k + 1)) || null,
              min_aprobado: (s.min_aprobado != null ? +s.min_aprobado : 70),
              n_preg_test:  (s.n_preg_test  != null ? +s.n_preg_test  : 10),
            };
          });
          return {
            nombre: mnom,
            orden: (m.orden != null ? +m.orden : (j + 1)) || null,
            secciones: secsN,
          };
        });
        return {
          nombre: tnom,
          descripcion: t.descripcion ? String(t.descripcion).trim() : null,
          modulos: modulosN,
        };
      });
      return { nombre, descripcion, temas: temasN };
    }

    _mostrarModal({
      titulo: 'Importar oposición desde JSON',
      contenido: html`
        <p class="muted small" style="margin:0 0 .75rem">
          Crea una oposición con sus temas, módulos y secciones. Si ya
          existe un <strong>tema con el mismo nombre</strong>, se reutiliza
          con sus módulos y secciones. La teoría y las preguntas se
          añaden después, sección por sección.
        </p>
        <label class="json-drop" for="fp-op-json">
          <span id="fp-op-json-label">📁 Elegir fichero <code>.json</code> o pegar debajo</span>
          <input id="fp-op-json" type="file" accept=".json,application/json">
        </label>
        <div class="campo-json">
          <label for="ta-op-json">O pega el JSON aquí</label>
          <textarea id="ta-op-json" rows="10" spellcheck="false"
            placeholder='{
  "nombre": "Auxilio Judicial",
  "descripcion": "…",
  "temas": [
    {
      "nombre": "Constitución",
      "modulos": [
        {"nombre": "Título Preliminar", "secciones": [{"nombre": "Artículos 1-9"}]}
      ]
    }
  ]
}'></textarea>
        </div>
        <div class="json-preview__summary" id="sum-op-json" hidden></div>
        <div class="form-err" hidden></div>
        <div class="form-row" style="justify-content:flex-end; margin-top:.75rem">
          <button class="btn btn-cancel btn-sm" type="button" data-cancel>Cancelar</button>
          <button class="btn btn-pri btn-sm" type="button" id="btn-op-ok" disabled>Crear oposición</button>
        </div>`,
      onMount(modal) {
        const ta    = modal.querySelector('#ta-op-json');
        const err   = modal.querySelector('.form-err');
        const sum   = modal.querySelector('#sum-op-json');
        const btnOk = modal.querySelector('#btn-op-ok');
        const label = modal.querySelector('#fp-op-json-label');

        function _refresh() {
          err.hidden = true;
          sum.hidden = true;
          btnOk.disabled = true;
          parsed = null;
          const text = ta.value.trim();
          if (!text) return;
          try {
            parsed = _validar(text);
            const nT = parsed.temas.length;
            const nM = parsed.temas.reduce((s, t) => s + (t.modulos || []).length, 0);
            const nS = parsed.temas.reduce((s, t) =>
              s + (t.modulos || []).reduce((ss, m) => ss + (m.secciones || []).length, 0), 0);
            sum.innerHTML =
              `<span class="kv-badge ok">${esc(parsed.nombre)}</span>` +
              `<span class="kv-badge">${nT} tema(s)</span>` +
              `<span class="kv-badge">${nM} módulo(s)</span>` +
              `<span class="kv-badge">${nS} sección(es)</span>`;
            sum.hidden = false;
            btnOk.disabled = false;
          } catch (e) {
            err.textContent = _msgError(e.message);
            err.hidden = false;
          }
        }
        ta.oninput = _refresh;

        modal.querySelector('#fp-op-json').onchange = async (ev) => {
          const f = ev.target.files && ev.target.files[0];
          if (!f) return;
          try {
            const text = await _leerFicheroTexto(f);
            ta.value = text;
            label.textContent = '📄 ' + f.name;
            _refresh();
          } catch (e) {
            err.textContent = _msgError(e.message);
            err.hidden = false;
          }
        };

        modal.querySelector('[data-cancel]').onclick = _cerrarModal;
        btnOk.onclick = async () => {
          if (!parsed) return;
          btnOk.disabled = true;
          err.hidden = true;
          try {
            btnOk.textContent = 'Creando oposición…';
            const rOp = await S.rpc('admin_crear_oposicion', {
              p_nombre: parsed.nombre,
              p_descripcion: parsed.descripcion,
            });
            const opId = rOp?.id || rOp?.oposicion_id || rOp;
            // Catálogo global de temas → para detectar reutilizables.
            const catTemas = await S.rpc('admin_listar_temas', { p_oposicion_id: null }) || [];
            const catByName = new Map(catTemas.map(t => [String(t.nombre).trim().toLowerCase(), t]));

            let tOK = 0, tSKIP = 0, mNew = 0, sNew = 0;
            for (let i = 0; i < parsed.temas.length; i++) {
              const t = parsed.temas[i];
              btnOk.textContent = `Tema ${i+1}/${parsed.temas.length}…`;
              const key = t.nombre.trim().toLowerCase();
              let temaId;
              const existente = catByName.get(key);
              if (existente) {
                // Reutiliza el tema del catálogo (con sus módulos y secciones).
                temaId = existente.id;
                await S.rpc('admin_asignar_tema_a_oposicion', {
                  p_oposicion_id: opId,
                  p_tema_id: temaId,
                }).catch(() => {}); // si ya está vinculado, ignora
                tSKIP++;
              } else {
                const rT = await S.rpc('admin_crear_tema', {
                  p_nombre: t.nombre,
                  p_descripcion: t.descripcion,
                  p_oposicion_id: opId,
                });
                temaId = rT?.id || rT?.tema_id || rT;
                tOK++;
              }

              // Módulos y secciones: comparar por nombre dentro del tema.
              const modsExist = await S.rpc('admin_listar_modulos', { p_tema_id: temaId }) || [];
              const modByName = new Map(modsExist.map(m => [String(m.nombre).trim().toLowerCase(), m]));
              for (const m of t.modulos) {
                let modId;
                const mExist = modByName.get(m.nombre.trim().toLowerCase());
                if (mExist) {
                  modId = mExist.id;
                } else {
                  const rM = await S.rpc('admin_crear_modulo', {
                    p_tema_id: temaId,
                    p_nombre: m.nombre,
                    p_orden: m.orden,
                  });
                  modId = rM?.id || rM?.modulo_id || rM;
                  mNew++;
                }
                const secsExist = await S.rpc('admin_listar_secciones', { p_modulo_id: modId }) || [];
                const secByName = new Set(secsExist.map(s => String(s.nombre).trim().toLowerCase()));
                for (const s of m.secciones) {
                  if (secByName.has(s.nombre.trim().toLowerCase())) continue;
                  await S.rpc('admin_crear_seccion', {
                    p_modulo_id: modId,
                    p_nombre: s.nombre,
                    p_orden: s.orden,
                    p_min_aprobado: s.min_aprobado,
                    p_n_preg_test: s.n_preg_test,
                  });
                  sNew++;
                }
              }
            }

            _cerrarModal();
            showToast(
              `Oposición creada · ${tOK} tema(s) nuevos, ${tSKIP} reutilizados, ` +
              `${mNew} módulo(s), ${sNew} sección(es).`);
            if (typeof refresh === 'function') refresh();
          } catch (e) {
            btnOk.disabled = false;
            btnOk.textContent = 'Crear oposición';
            err.textContent = _msgError(e.message || String(e));
            err.hidden = false;
          }
        };
      },
    });
  }


  // ── Notificaciones de logros y retos ───────────────────────────────
  // El motor de gamificación (retos + logros) vive en el backend, pero el
  // frontend no recibe hoy en día un `logros_desbloqueados` en la respuesta
  // de `finalizar_intento` (esa parte del pipeline se documentó pero se
  // eliminó del schema unificado). Lo suplimos con un "diff local":
  //   · antes de una acción que puede otorgar retos/logros → snapshot.
  //   · después de completarse            → diff con lo nuevo.
  // Así cada vez que un intento cambia el estado del catálogo, se pintan
  // las tarjetitas emergentes como en la app antigua.
  const gamif = (() => {
    let snap = null;

    async function _fetchEstado() {
      const [retos, logros] = await Promise.all([
        S.rpc('mis_retos_activos').catch(() => []),
        S.rpc('mis_logros').catch(() => []),
      ]);
      return { retos: retos || [], logros: logros || [] };
    }

    // Guarda el estado actual (retos completos + logros obtenidos) como
    // referencia; devuelve una promesa que resuelve cuando termina.
    async function snapshot() {
      try {
        const e = await _fetchEstado();
        snap = {
          retos:  new Set(e.retos.filter(r => r.completado).map(r => r.codigo)),
          logros: new Set(e.logros.filter(l => l.obtenido).map(l => l.codigo)),
        };
      } catch (_) {
        snap = { retos: new Set(), logros: new Set() };
      }
    }

    // Compara con el snapshot y notifica cualquier reto/logro nuevo.
    async function checkNuevos() {
      if (!snap) { await snapshot(); return; }
      try {
        const e = await _fetchEstado();
        const nuevos = [];
        e.retos.forEach(r => {
          if (r.completado && !snap.retos.has(r.codigo)) {
            nuevos.push({
              tipo: 'reto',
              titulo: r.titulo,
              descripcion: r.descripcion,
              icono: r.icono,
              xp: r.xp,
            });
          }
        });
        e.logros.forEach(l => {
          if (l.obtenido && !snap.logros.has(l.codigo)) {
            nuevos.push({
              tipo: 'logro',
              titulo: l.titulo,
              descripcion: l.descripcion,
              icono: l.icono,
              xp: l.xp,
            });
          }
        });
        if (nuevos.length) _notificar(nuevos);
        // Actualiza snapshot al estado post-acción.
        snap = {
          retos:  new Set(e.retos.filter(r => r.completado).map(r => r.codigo)),
          logros: new Set(e.logros.filter(l => l.obtenido).map(l => l.codigo)),
        };
        // Refresca XP y racha del header.
        window.dispatchEvent(new Event('aprentix:session'));
      } catch (_) { /* silencioso */ }
    }

    return { snapshot, checkNuevos };
  })();

  // Pinta una tarjeta por logro/reto en la pila `#logros-notif-stack`.
  function _notificar(items) {
    const stack = document.getElementById('logros-notif-stack');
    if (!stack || !Array.isArray(items) || !items.length) return;
    items.forEach((l, i) => {
      const esReto = l.tipo === 'reto';
      const titular = esReto ? '¡Reto completado!' : '¡Logro desbloqueado!';
      const card = document.createElement('article');
      card.className = 'logro-notif' + (esReto ? ' es-reto' : '');
      card.setAttribute('role', 'status');
      card.innerHTML = `
        <div class="logro-notif-icono" aria-hidden="true">${esc(l.icono || (esReto ? '🎯' : '🏆'))}</div>
        <div class="logro-notif-body">
          <div class="logro-notif-head">
            <strong>${esc(titular)}</strong>
            <span class="logro-notif-xp">+${Number(l.xp) || 0} XP</span>
          </div>
          <div class="logro-notif-desc"><strong>${esc(l.titulo || '')}</strong>${
            l.descripcion ? ' · ' + esc(l.descripcion) : ''
          }</div>
          <div class="logro-notif-bar" role="progressbar" aria-valuenow="1" aria-valuemin="0" aria-valuemax="1"><span></span></div>
        </div>`;
      stack.appendChild(card);
      setTimeout(() => card.classList.add('done'), 60 + i * 120);
      const cerrar = () => {
        if (card._closed) return;
        card._closed = true;
        card.classList.add('out');
        setTimeout(() => card.remove(), 350);
      };
      card.addEventListener('click', cerrar);
      setTimeout(cerrar, 5200 + i * 400);
    });
  }


  // ── Vista: Logros y retos ──────────────────────────────────────────
  // Panel con dos secciones — retos activos (agrupados por periodo) y
  // logros del catálogo (obtenidos vs pendientes). Estilo tarjeta,
  // aprovecha `.panel-card` y utilidades del manifiesto.
  async function viewLogrosRetos() {
    loading();
    const [retos, logros, gm] = await Promise.all([
      S.rpc('mis_retos_activos').catch(() => []),
      S.rpc('mis_logros').catch(() => []),
      S.rpc('mi_gamificacion').catch(() => ({})),
    ]);
    // Snapshot inicial cada vez que se entra: así los nuevos retos que
    // caigan durante la sesión se detectan como "nuevos".
    gamif.snapshot();

    const retosPorPeriodo = { diario: [], semanal: [], mensual: [] };
    (retos || []).forEach(r => {
      const p = r.periodo || 'diario';
      (retosPorPeriodo[p] = retosPorPeriodo[p] || []).push(r);
    });
    const etiquetaPeriodo = {
      diario:  { titulo: 'Retos diarios',   icono: '🌞', desc: 'Se reinician cada día.' },
      semanal: { titulo: 'Retos semanales', icono: '📅', desc: 'Se reinician cada lunes.' },
      mensual: { titulo: 'Retos mensuales', icono: '📈', desc: 'Se reinician el día 1.' },
    };

    function retoCard(r) {
      const pct = Math.min(100, Math.round(((r.progreso || 0) / (r.objetivo || 1)) * 100));
      const done = r.completado;
      return `
        <article class="reto-card ${done ? 'is-done' : ''}">
          <div class="reto-icono" aria-hidden="true">${esc(r.icono || '🎯')}</div>
          <div class="reto-body">
            <div class="reto-head">
              <strong>${esc(r.titulo || '')}</strong>
              <span class="reto-xp">+${Number(r.xp) || 0} XP</span>
            </div>
            <div class="reto-desc">${esc(r.descripcion || '')}</div>
            <div class="reto-bar" role="progressbar"
                 aria-valuenow="${r.progreso || 0}"
                 aria-valuemin="0" aria-valuemax="${r.objetivo || 1}">
              <span style="width:${pct}%"></span>
            </div>
            <div class="reto-meta">
              ${done
                ? '<span class="kv-badge ok">Completado ✓</span>'
                : `<span>${r.progreso || 0} / ${r.objetivo || 1}</span>`}
            </div>
          </div>
        </article>`;
    }

    function logroCard(l) {
      return `
        <article class="logro-card ${l.obtenido ? 'is-obtenido' : 'is-locked'}">
          <div class="logro-icono" aria-hidden="true">${esc(l.icono || '🏆')}</div>
          <div class="logro-body">
            <div class="logro-head">
              <strong>${esc(l.titulo || '')}</strong>
              <span class="logro-xp">+${Number(l.xp) || 0} XP</span>
            </div>
            <div class="logro-desc">${esc(l.descripcion || '')}</div>
            ${l.obtenido
              ? `<div class="logro-fecha kv-badge ok">Conseguido${
                    l.obtenido_en
                      ? ' · ' + new Date(l.obtenido_en).toLocaleDateString()
                      : ''
                  }</div>`
              : '<div class="kv-badge">Por conseguir</div>'}
          </div>
        </article>`;
    }

    const obtenidos = (logros || []).filter(l => l.obtenido).length;
    const totalLogros = (logros || []).length;

    // Nivel + progreso al siguiente nivel — sirve como cabecera "grande"
    // de la vista (no un tile más), para dar aire y hacer de la vista de
    // logros un espacio que "se sienta como progreso".
    const nivel = Number(gm?.nivel) || 1;
    const xpTot = Number(gm?.xp_total) || 0;
    const xpIni = Number(gm?.xp_nivel_ini) || 0;
    const xpSig = Number(gm?.xp_nivel_sig) || Math.max(50, xpIni + 50);
    const xpDen = Math.max(1, xpSig - xpIni);
    const pctNivel = Math.min(100, Math.max(0, Math.round(100 * (xpTot - xpIni) / xpDen)));
    const restanteXP = Math.max(0, xpSig - xpTot);

    // Render de una sección de retos por periodo. Se pinta como bloque
    // abierto (diario) o desplegable (semanal/mensual) según `openByDefault`.
    // No hay pestañas: todo cae en un scroll vertical natural.
    function bloqueRetos(periodo, meta, items, openByDefault) {
      const cuerpo = items.length === 0
        ? '<div class="empty small">Aún no hay retos de este periodo.</div>'
        : `<div class="retos-grid">${items.map(retoCard).join('')}</div>`;
      return `
        <details class="logros-seccion" ${openByDefault ? 'open' : ''}>
          <summary class="logros-seccion-head">
            <span class="logros-seccion-ico" aria-hidden="true">${esc(meta.icono)}</span>
            <span class="logros-seccion-titulo">${esc(meta.titulo)}</span>
            <span class="logros-seccion-count">${items.length}</span>
            <span class="logros-seccion-caret" aria-hidden="true">▾</span>
          </summary>
          <div class="logros-seccion-body">
            <p class="logros-seccion-desc">${esc(meta.desc)}</p>
            ${cuerpo}
          </div>
        </details>`;
    }

    root.innerHTML = html`
      <div class="view-head"><h2>Logros y retos</h2></div>

      <section class="logros-nivel-hero"
               role="group" aria-label="Nivel y experiencia">
        <div class="logros-nivel-ico">
          <div class="logros-nivel-badge">
            <span class="logros-nivel-num">${nivel}</span>
          </div>
        </div>
        <div class="logros-nivel-body">
          <small>Nivel actual</small>
          <strong>Nivel ${nivel}</strong>
          <div class="logros-nivel-barra" role="progressbar"
               aria-valuenow="${xpTot - xpIni}" aria-valuemin="0"
               aria-valuemax="${xpDen}">
            <span style="width:${pctNivel}%"></span>
          </div>
          <span class="logros-nivel-hint">${xpTot} / ${xpSig} XP · ${restanteXP} para subir</span>
        </div>
        <div class="logros-nivel-racha ${(gm?.racha_actual || 0) > 0 ? 'on' : ''}">
          <span class="logros-nivel-racha-ico" aria-hidden="true">🔥</span>
          <strong>${gm?.racha_actual ?? 0}</strong>
          <small>Racha</small>
        </div>
      </section>

      <section class="logros-stats" aria-label="Resumen">
        <div class="logros-stat">
          <span aria-hidden="true">💎</span>
          <strong>${xpTot}</strong>
          <small>XP total</small>
        </div>
        <div class="logros-stat">
          <span aria-hidden="true">🏆</span>
          <strong>${obtenidos}/${totalLogros}</strong>
          <small>Logros</small>
        </div>
        <div class="logros-stat">
          <span aria-hidden="true">🎯</span>
          <strong>${(retos || []).filter(r => r.completado).length}</strong>
          <small>Retos hoy</small>
        </div>
      </section>

      ${raw(bloqueRetos('diario',  etiquetaPeriodo.diario,  retosPorPeriodo.diario,  true))}
      ${raw(bloqueRetos('semanal', etiquetaPeriodo.semanal, retosPorPeriodo.semanal, true))}
      ${raw(bloqueRetos('mensual', etiquetaPeriodo.mensual, retosPorPeriodo.mensual, false))}

      <details class="logros-seccion" open>
        <summary class="logros-seccion-head">
          <span class="logros-seccion-ico" aria-hidden="true">🏅</span>
          <span class="logros-seccion-titulo">Medallas</span>
          <span class="logros-seccion-count">${obtenidos}/${totalLogros}</span>
          <span class="logros-seccion-caret" aria-hidden="true">▾</span>
        </summary>
        <div class="logros-seccion-body">
          <p class="logros-seccion-desc">Hitos únicos que se desbloquean al progresar.</p>
          ${raw((logros || []).length === 0
            ? '<div class="empty small">Todavía no hay logros en el catálogo.</div>'
            : `<div class="medallas-grid">${logros.map(logroCard).join('')}</div>`)}
        </div>
      </details>
    `;
  }


  // ── Vista: plan de estudio ─────────────────────────────────────────
  // Primera base visual del planificador. La generación se conectará al
  // backend cuando exista; mientras tanto explicamos qué datos solicitará
  // sin guardar respuestas ni prometer un calendario que aún no se genera.
  async function viewPlan() {
    root.innerHTML = html`
      <header class="plan-cabecera">
        <span class="plan-cabecera-icono" aria-hidden="true">📅</span>
        <div>
          <span class="kv-badge">Próximamente</span>
          <h1>Tu plan de estudio</h1>
          <p>Un calendario personal para avanzar en tu oposición con constancia y sin agobios.</p>
        </div>
      </header>

      <section class="panel-card plan-presentacion">
        <h2 class="card-title">Un plan adaptado a tu día a día</h2>
        <p>Te haremos unas preguntas breves y distribuiremos el temario en sesiones realistas.</p>
        <div class="plan-pasos" aria-label="Cómo se creará tu plan">
          <div><span aria-hidden="true">⏱️</span><strong>Tu tiempo</strong><small>Horas disponibles cada día</small></div>
          <div><span aria-hidden="true">🎯</span><strong>Tu objetivo</strong><small>Fecha y ritmo de preparación</small></div>
          <div><span aria-hidden="true">🌱</span><strong>Tu progreso</strong><small>Temas estudiados y descansos</small></div>
        </div>
      </section>

      <section class="panel-card plan-vista-previa">
        <div>
          <h2 class="card-title">Aquí verás tu calendario</h2>
          <p class="card-subtitle">Cada día mostrará la lección o el repaso que te toca. También podrás generar un plan nuevo cuando cambie tu disponibilidad.</p>
        </div>
        <div class="plan-semana" aria-hidden="true">
          <span>L<em></em></span><span>M<em></em></span><span>X<em></em></span>
          <span>J<em></em></span><span>V<em></em></span><span>S<em></em></span><span>D<em></em></span>
        </div>
      </section>

      <button class="btn btn-primary plan-accion" type="button" disabled>
        Crear mi plan · Disponible próximamente
      </button>`;
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
    if (id === 'plan')                navigate('#/plan');
    if (id === 'estadisticas')        navigate('#/estadisticas');
    if (id === 'logros')              navigate('#/logros');
    if (id === 'cambiar-oposicion')   _abrirSelectorOposicion();
    if (id === 'tablon') {
      const op = getCtx().oposicion_id;
      if (op) navigate(`#/tablon/${op}`);
      else showToast('Elige primero una oposición.');
    }
  });

  // El sheet del avatar también expone acceso directo a la vista.
  document.addEventListener('click', (e) => {
    const el = e.target.closest('[data-view="logros"]');
    if (el) navigate('#/logros');
  });

  // El sheet del avatar dispara clicks por data-view; los cazamos aquí.
  document.addEventListener('click', (e) => {
    const el = e.target.closest('[data-view]');
    if (!el) return;
    const v = el.dataset.view;
    if (v === 'home')             navigate('#/');
    if (v === 'plan')             navigate('#/plan');
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
    if (S.getUser()) {
      _refreshLocalRoles();
      // Snapshot inicial de retos/logros para el diff de notificaciones.
      gamif.snapshot();
    }
    if (!location.hash) {
      // Sin hash: si hay sesión, home; si no, login.
      location.hash = S.getUser() ? '#/' : '#/login';
    } else {
      _render();
    }
  })();
})();
