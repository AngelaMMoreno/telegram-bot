/* ═══════════════════════════════════════════════════════════════════════
   Aprentix — app.js  (SPA rediseño oposiciones)
   -----------------------------------------------------------------------
   Router hash-based, vanilla ES2020, sin bundler.  Reutiliza
   window.AprentixSession (session.js) para JWT + rpc.
   ═══════════════════════════════════════════════════════════════════════ */
'use strict';

const S = window.AprentixSession;
if (!S) throw new Error('AprentixSession no cargado');

const $  = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

const state = {
  session: null,
  oposiciones: [],
  principalId: null,
  planCargado: false,   // true una vez comprobado si tiene plan_estudio
  tienePlan: false,     // true si tiene plan_estudio activo con disponibilidad
  wizardData: {
    modo: 'diario',
    horas_semana: 10,
    horas_por_dia: { lun:2, mar:2, mie:2, jue:3, vie:2, sab:3, dom:0 },
    metodo: 'cortas',
    ritmo: 'normal',
  },
};

// ══════════════════════════════════════════════════════════════════════
// Router
// ══════════════════════════════════════════════════════════════════════

const routes = {
  auth:           renderAuth,
  verify:         renderVerify,
  onboarding:     renderOnboarding,
  wizard:         renderWizard,
  home:           renderHome,
  plan:           renderPlan,
  stats:          renderStats,
  perfil:         renderPerfil,
  oposicion:      renderOposicion,
  unidad:         renderUnidad,
  admin:          renderAdmin,
  administracion: renderAdministracion,
  editar:         renderEditar,
  estudio:        renderEstudio,
  reset:          renderReset,
};

function parseHash() {
  const raw = location.hash.replace(/^#\/?/, '');
  const [pathPart, queryPart] = raw.split('?');
  const parts = pathPart.split('/').filter(Boolean);
  const name  = parts[0] || 'home';
  const params = {};
  if (parts[1]) params.id = decodeURIComponent(parts[1]);
  const query = Object.fromEntries(new URLSearchParams(queryPart || ''));
  return { name, params, query };
}

async function router() {
  const r = parseHash();

  if (r.name === 'verify') return renderVerify(r);
  if (r.name === 'reset')  return renderReset(r);

  if (!S.getToken() && r.name !== 'auth') {
    location.hash = '#/auth';
    return;
  }

  if (S.getToken() && !state.session) {
    try {
      const s = await S.rpc('mi_sesion', {}, { api: '/api' });
      const parsed = Array.isArray(s) ? s[0] : s;
      // mi_sesion devuelve NULL cuando el jwt_usuario_id() no
      // corresponde a ningún usuario en la BBDD (JWT huérfano: la
      // BBDD se recreó, el usuario se borró, etc). La request no
      // es un error, pero la sesión ya no vale — hay que forzar
      // logout para que no revienten renders posteriores.
      if (!parsed || !parsed.user_id) {
        S.clearToken();
        state.session = null;
        location.hash = '#/auth';
        return;
      }
      state.session = parsed;
    } catch (e) {
      S.clearToken();
      location.hash = '#/auth';
      return;
    }
  }

  if (state.session && !state.oposiciones.length) {
    try {
      const mis = await S.rpc('mis_oposiciones', {}, { api: '/api' });
      state.oposiciones = mis || [];
      state.principalId = (state.oposiciones.find(o => o.principal) || {}).id || null;
    } catch (_) { /* ignore */ }
  }

  if (state.session && !state.oposiciones.length
      && !['onboarding', 'auth', 'wizard',
           // Rutas de administración: si es admin, tiene sentido que
           // pueda importar y editar oposiciones AUNQUE aún no esté
           // matriculado en ninguna (que es lo normal la primera vez).
           'administracion', 'admin', 'editar', 'perfil']
          .includes(r.name)) {
    location.hash = '#/onboarding';
    return;
  }
  // Doble guardia: si NO es admin y no hay oposiciones, tampoco le
  // dejamos pasar a las rutas admin.
  if (state.session && !state.oposiciones.length
      && !state.session.es_admin
      && ['administracion', 'admin', 'editar'].includes(r.name)) {
    location.hash = '#/onboarding';
    return;
  }

  // Usuarios legacy (creados antes del wizard de disponibilidad):
  // tienen oposición matriculada pero no plan de estudio configurado.
  // Les llevamos al wizard para que rellenen disponibilidad/ritmo.
  if (state.session && state.oposiciones.length && !state.planCargado) {
    try {
      const pd = (await S.rpc('dashboard_perfil', {}, { api: '/api' })) || {};
      const p = pd.plan || null;
      const hpd = p?.horas_por_dia || {};
      const totalDia = ['lun','mar','mie','jue','vie','sab','dom']
        .reduce((s, d) => s + (parseFloat(hpd[d]) || 0), 0);
      state.tienePlan = !!(p && (p.horas_semana > 0 || totalDia > 0));
    } catch (_) { state.tienePlan = false; }
    state.planCargado = true;
  }
  if (state.session && state.oposiciones.length && !state.tienePlan
      && !['wizard', 'perfil', 'auth', 'verify', 'reset', 'onboarding',
           // También dejamos pasar rutas admin: si el admin aún no
           // tiene plan, no es motivo para bloquearle la gestión.
           'administracion', 'admin', 'editar']
          .includes(r.name)) {
    location.hash = '#/wizard';
    return;
  }

  const view = routes[r.name] || renderHome;
  await view(r);
  updateNav(r.name);
}

window.addEventListener('hashchange', router);
window.addEventListener('load', router);

// ══════════════════════════════════════════════════════════════════════
// Utils
// ══════════════════════════════════════════════════════════════════════

function mount(tplId) {
  const tpl = document.getElementById(tplId);
  const app = document.getElementById('app');
  app.innerHTML = '';
  app.appendChild(tpl.content.cloneNode(true));
  ensureNav();
}

function ensureNav() {
  if ($('.bottom-nav')) return;
  const app = document.getElementById('app');
  const tpl = document.getElementById('tpl-nav');
  app.appendChild(tpl.content.cloneNode(true));
  $$('.bottom-nav [data-nav]').forEach(btn => {
    btn.addEventListener('click', () => { location.hash = '#/' + btn.dataset.nav; });
  });
}

function updateNav(name) {
  const map = { home:'home', plan:'plan', stats:'stats', perfil:'perfil' };
  const target = map[name];
  const nav = $('.bottom-nav');
  // Vistas que NO llevan bottom-nav: flujos modales o inmersivos, y
  // subpantallas donde queremos que el foco sea la propia vista y no
  // la navegación general (unidad, editor, modo estudio…).
  if (!nav || ['auth','verify','reset','onboarding','wizard','unidad',
               'admin','administracion','editar','estudio','oposicion']
              .includes(name)) {
    if (nav) nav.remove();
    return;
  }
  $$('.bottom-nav [data-nav]').forEach(b => {
    b.classList.toggle('active', b.dataset.nav === target);
  });
}

function toast(msg, kind = 'info') {
  const el = document.getElementById('toast');
  el.textContent = msg;
  el.dataset.kind = kind;
  el.hidden = false;
  clearTimeout(toast._t);
  toast._t = setTimeout(() => { el.hidden = true; }, 3500);
}

function initials(nombre) {
  if (!nombre) return '?';
  return nombre.trim().split(/\s+/).slice(0, 2).map(x => x[0].toUpperCase()).join('');
}

function fmtMin(min) {
  if (!min) return '0m';
  if (min < 60) return min + 'm';
  const h = Math.floor(min / 60), m = min % 60;
  return h + 'h' + (m ? ' ' + m + 'm' : '');
}

function bindCommon(root) {
  $$('[data-open-perfil]', root).forEach(el => {
    el.addEventListener('click', () => location.hash = '#/perfil');
  });
  $$('[data-goto]', root).forEach(el => {
    el.addEventListener('click', () => location.hash = '#/' + el.dataset.goto);
  });
}

function setAvatarChips(root) {
  const nombre = state.session?.nombre || '';
  $$('[data-avatar]', root).forEach(el => { el.textContent = initials(nombre); });
}

function cerrarSesion() {
  clearInterval(_sesActiva?.tickTimer);
  _sesActiva = null;
  S.clearToken();
  state.session = null;
  state.oposiciones = [];
  state.principalId = null;
  state.planCargado = false;
  state.tienePlan = false;
  location.hash = '#/auth';
}

// ══════════════════════════════════════════════════════════════════════
// AUTH
// ══════════════════════════════════════════════════════════════════════

function calcPwLevel(pw) {
  if (!pw) return { nivel: 0, etiqueta: 'Introduce una contraseña' };
  let pts = 0;
  if (pw.length >= 8) pts++;
  if (pw.length >= 12) pts++;
  if (pw.length >= 16) pts++;
  const clases = [/[a-z]/, /[A-Z]/, /\d/, /[^A-Za-z0-9]/].filter(r => r.test(pw)).length;
  if (clases >= 2) pts++;
  if (clases >= 3) pts++;
  if (clases >= 4) pts++;
  const nivel = Math.min(4, Math.max(1, Math.round(pts * 4 / 6)));
  const etiqueta = ['', 'Débil', 'Aceptable', 'Fuerte', 'Muy fuerte'][nivel];
  return { nivel, etiqueta };
}

function renderAuth() {
  mount('tpl-auth');
  const root = $('.auth-view');

  $$('.auth-tab', root).forEach(tab => {
    tab.addEventListener('click', () => {
      $$('.auth-tab', root).forEach(t => t.classList.toggle('active', t === tab));
      $$('.auth-panel', root).forEach(p => p.classList.toggle('active', p.dataset.panel === tab.dataset.tab));
      $$('[data-err]', root).forEach(e => { e.hidden = true; e.textContent = ''; });
    });
  });

  $('[data-reenviar]', root).addEventListener('click', async () => {
    const email = $('input[name="email"]', $('[data-panel="login"]', root)).value.trim();
    if (!email) return toast('Introduce el correo primero');
    try {
      await S.rpc('reenviar_verificacion', { p_email: email }, { api: '/api' });
      toast('Si la cuenta existe y estaba sin verificar, te llegará un nuevo enlace.');
    } catch (e) { toast(e.message); }
  });

  const btnOlvidada = $('[data-olvidada]', root);
  if (btnOlvidada) btnOlvidada.addEventListener('click', async () => {
    const email = $('input[name="email"]', $('[data-panel="login"]', root)).value.trim();
    if (!email) return toast('Introduce tu correo primero');
    try {
      await S.rpc('solicitar_reset', { p_email: email }, { api: '/api', token: null });
      toast('Si el correo existe, te enviamos un enlace para restablecerla.');
    } catch (e) { toast(e.message); }
  });

  // LOGIN
  $('[data-panel="login"]', root).addEventListener('submit', async ev => {
    ev.preventDefault();
    const err = $('[data-err]', ev.currentTarget); err.hidden = true;
    const email = ev.currentTarget.email.value.trim();
    const pass  = ev.currentTarget.password.value;
    try {
      const r = await S.rpc('login_web', { p_email: email, p_password: pass },
                             { api: '/api', token: null });
      S.setToken(r.token);
      state.session = null; state.oposiciones = [];
      location.hash = '#/home';
    } catch (e) {
      err.hidden = false;
      const m = String(e.message);
      err.textContent = m.includes('email_no_verificado')
          ? 'Aún no has confirmado tu correo. Comprueba tu buzón o pulsa "¿No has recibido el correo?".'
        : m.includes('credenciales')
          ? 'Correo o contraseña incorrectos.'
        : e.message;
    }
  });

  // REGISTRO
  const regPanel = $('[data-panel="register"]', root);
  const regPw    = regPanel.querySelector('input[name="password"]');
  const regPw2   = regPanel.querySelector('input[name="password2"]');
  const regEmail = regPanel.querySelector('input[name="email"]');
  const regEmail2= regPanel.querySelector('input[name="email2"]');
  const pwHint   = regPanel.querySelector('[data-pw-strength]');
  const pwFill   = regPanel.querySelector('[data-pw-fill]');
  const pwLabel  = regPanel.querySelector('[data-pw-label]');
  const pwMatch  = regPanel.querySelector('[data-pw-match]');
  const emMatch  = regPanel.querySelector('[data-email-match]');

  function updatePw() {
    const { nivel, etiqueta } = calcPwLevel(regPw.value);
    pwHint.classList.remove('lvl-1','lvl-2','lvl-3','lvl-4');
    if (nivel) pwHint.classList.add('lvl-' + nivel);
    pwLabel.textContent = etiqueta;
    if (!regPw.value) pwFill.style.width = '0%';
  }
  function updateMatch() {
    if (!regPw2.value) { pwMatch.hidden = true; return; }
    pwMatch.hidden = false;
    const ok = regPw.value === regPw2.value;
    pwMatch.textContent = ok ? '✓ Las contraseñas coinciden' : '✗ No coinciden';
    pwMatch.classList.toggle('ok', ok);
    pwMatch.classList.toggle('err', !ok);
  }
  function updateEm() {
    if (!regEmail2.value) { emMatch.hidden = true; return; }
    emMatch.hidden = false;
    const ok = regEmail.value.trim().toLowerCase() === regEmail2.value.trim().toLowerCase();
    emMatch.textContent = ok ? '✓ Los correos coinciden' : '✗ No coinciden';
    emMatch.classList.toggle('ok', ok);
    emMatch.classList.toggle('err', !ok);
  }
  regPw.addEventListener('input', () => { updatePw(); updateMatch(); });
  regPw2.addEventListener('input', updateMatch);
  regEmail.addEventListener('input', updateEm);
  regEmail2.addEventListener('input', updateEm);

  regPanel.addEventListener('submit', async ev => {
    ev.preventDefault();
    const err = $('[data-err]', regPanel); err.hidden = true;
    const nombre = regPanel.nombre.value.trim();
    const email  = regEmail.value.trim().toLowerCase();
    const email2 = regEmail2.value.trim().toLowerCase();
    const pw     = regPw.value;
    const pw2    = regPw2.value;
    if (email !== email2) return showErr('Los correos no coinciden.');
    if (pw !== pw2)       return showErr('Las contraseñas no coinciden.');
    if (calcPwLevel(pw).nivel < 2) return showErr('Elige una contraseña más fuerte.');

    try {
      await S.rpc('registrar_web', { p_email: email, p_password: pw, p_nombre: nombre },
                   { api: '/api', token: null });
      showVerificationPending(email);
    } catch (e) {
      const m = String(e.message);
      showErr(
        m.includes('email_registrado') ? 'Ese correo ya está registrado.'
      : m.includes('password_debil')   ? 'La contraseña debe tener al menos 8 caracteres.'
      : m.includes('email_invalido')   ? 'El correo no tiene un formato válido.'
      : e.message
      );
    }
    function showErr(t){ err.textContent = t; err.hidden = false; }
  });
}

function showVerificationPending(email) {
  const app = document.getElementById('app');
  app.innerHTML = `
    <section class="auth-view">
      <img class="brand-hero" src="/logo.svg" alt="Aprentix">
      <div class="auth-card" style="text-align:center">
        <h2 style="color:var(--pri-d);margin-top:0">Revisa tu correo</h2>
        <p>Hemos enviado un enlace de confirmación a<br><strong>${email}</strong>.</p>
        <p class="muted">Pulsa el botón del correo para activar tu cuenta. El enlace caduca en 3 días.</p>
        <button class="btn btn-outline btn-block" onclick="location.hash='#/auth'">Volver a inicio</button>
      </div>
    </section>`;
  updateNav('auth');
}

async function renderVerify(r) {
  mount('tpl-verify');
  const panel = $('[data-panel]');
  const token = r.query?.token;
  if (!token) {
    panel.innerHTML = `<h2 style="color:var(--danger)">Enlace inválido</h2>
      <p>Falta el token en la URL.</p>
      <button class="btn btn-outline btn-block" onclick="location.hash='#/auth'">Ir al inicio</button>`;
    return;
  }
  try {
    await S.rpc('verificar_email', { p_token: token }, { api: '/api', token: null });
    panel.innerHTML = `
      <h2 style="color:var(--pri-d);margin-top:0">¡Cuenta activada!</h2>
      <p>Ya puedes iniciar sesión.</p>
      <button class="btn btn-primary btn-block" onclick="location.hash='#/auth'">Iniciar sesión</button>`;
  } catch (e) {
    panel.innerHTML = `
      <h2 style="color:var(--danger);margin-top:0">Enlace caducado o ya usado</h2>
      <p>Solicita uno nuevo desde "¿No has recibido el correo?" en el acceso.</p>
      <button class="btn btn-outline btn-block" onclick="location.hash='#/auth'">Volver</button>`;
  }
}

// ══════════════════════════════════════════════════════════════════════
// ONBOARDING oposición
// ══════════════════════════════════════════════════════════════════════

async function renderOnboarding() {
  mount('tpl-onboarding');
  const root = $('.view-onboarding');
  const ul = $('[data-onboarding]', root);
  const btn = $('[data-onboarding-guardar]', root);
  let seleccionada = null;

  let opos = [];
  try { opos = await S.rpc('listar_oposiciones', {}, { api: '/api' }); }
  catch (e) { toast('Error cargando oposiciones: ' + e.message); }

  // Cabecera: pintar chip con el email/nombre del usuario para dar
  // contexto — así se ve claramente en qué cuenta estás si abriste
  // una pestaña vieja o cambiaste de cuenta por error.
  const userLbl = $('[data-user-lbl]', root);
  if (userLbl) userLbl.textContent = state.session?.email || state.session?.nombre || '—';

  // Shortcuts globales del onboarding (visibles siempre)
  const shortAdm = $('[data-ir-administracion]', root);
  if (shortAdm) {
    shortAdm.hidden = !state.session?.es_admin;
    shortAdm.addEventListener('click', () => location.hash = '#/administracion');
  }
  const btnLogout = $('[data-logout]', root);
  if (btnLogout) btnLogout.addEventListener('click', () => {
    if (confirm('¿Cerrar sesión?')) cerrarSesion();
  });

  if (!opos.length) {
    ul.innerHTML = `<li class="onboarding-vacio">
      <p class="muted">No hay oposiciones disponibles. ${
        state.session?.es_admin
          ? 'Usa el botón «Importar oposición» para cargar una.'
          : 'Un administrador debe importar una primero (vía <code>importar_oposicion</code>).'
      }</p></li>`;
    return;
  }

  ul.innerHTML = opos.map(o => `
    <li data-id="${o.id}">
      <span class="ico-round">📘</span>
      <div>
        <strong>${escapeHtml(o.nombre)}</strong>
        <span class="muted">${escapeHtml(o.organismo || '')} · ${o.num_temas || 0} temas</span>
      </div>
      <span class="chevron">›</span>
    </li>
  `).join('');

  $$('li', ul).forEach(li => {
    li.addEventListener('click', () => {
      $$('li', ul).forEach(x => x.classList.remove('selected'));
      li.classList.add('selected');
      seleccionada = li.dataset.id;
      btn.disabled = false;
    });
  });

  btn.addEventListener('click', async () => {
    if (!seleccionada) return;
    try {
      await S.rpc('matricular_oposicion',
        { p_oposicion_id: seleccionada, p_principal: true },
        { api: '/api' });
      state.oposiciones = [];
      // Tras elegir oposición → wizard de disponibilidad
      location.hash = '#/wizard';
    } catch (e) { toast('Error: ' + e.message); }
  });
}

// ══════════════════════════════════════════════════════════════════════
// WIZARD disponibilidad
// ══════════════════════════════════════════════════════════════════════

async function renderWizard() {
  mount('tpl-wizard');
  const root = $('.view-wizard');
  let paso = 1;

  // Al abrir el wizard, arrancamos siempre desde arriba (evita que la
  // ventana cargue con el scroll heredado de la pantalla anterior).
  window.scrollTo(0, 0);

  function showStep(n) {
    paso = n;
    $$('.wizard-step', root).forEach(s => { s.hidden = s.dataset.wstep !== String(n); });
    $$('.wizard-steps .dot', root).forEach(d =>
      d.classList.toggle('active', +d.dataset.step === n));
    // Scroll inmediato al top (sin smooth) para que el hero y el botón
    // "Atrás" queden siempre visibles, sea cual sea el tamaño de móvil.
    window.scrollTo(0, 0);
  }

  // Paso 1 → siguiente
  $('[data-wizard-next="2"]', root).addEventListener('click', () => {
    const modoInput = $('input[name="modo"]:checked', root);
    state.wizardData.modo = modoInput?.value || 'diario';
    const hint = $('[data-wizard-hint]', root);
    $('[data-wizard-semanal]', root).hidden = state.wizardData.modo !== 'semanal';
    $('[data-wizard-diario]', root).hidden  = state.wizardData.modo !== 'diario';
    hint.textContent = state.wizardData.modo === 'semanal'
      ? 'Suma total de horas por semana. El plan repartirá entre lunes y sábado.'
      : 'Ajusta las horas para cada día. Deja 0 los días que no puedes.';
    showStep(2);
  });

  // Paso 2: sliders/inputs
  const hs = $('[data-hs]', root);
  const hsVal = $('[data-hs-val]', root);
  hs.addEventListener('input', () => { hsVal.textContent = hs.value; state.wizardData.horas_semana = +hs.value; });
  const totalEl = $('[data-hd-total]', root);
  function recalcTotal() {
    const t = ['lun','mar','mie','jue','vie','sab','dom']
      .reduce((s, d) => s + (parseFloat($(`[data-day="${d}"]`, root)?.value) || 0), 0);
    totalEl.textContent = t;
    ['lun','mar','mie','jue','vie','sab','dom'].forEach(d => {
      state.wizardData.horas_por_dia[d] = parseFloat($(`[data-day="${d}"]`, root)?.value) || 0;
    });
  }
  $$('[data-day]', root).forEach(inp => inp.addEventListener('input', recalcTotal));
  recalcTotal();

  $('[data-wizard-next="3"]', root).addEventListener('click', () => showStep(3));

  // Paso 3
  $$('[data-metodo] button', root).forEach(b => b.addEventListener('click', () => {
    $$('[data-metodo] button', root).forEach(x => x.classList.remove('active'));
    b.classList.add('active');
    state.wizardData.metodo = b.dataset.val;
  }));
  $$('[data-ritmo] button', root).forEach(b => b.addEventListener('click', () => {
    $$('[data-ritmo] button', root).forEach(x => x.classList.remove('active'));
    b.classList.add('active');
    state.wizardData.ritmo = b.dataset.val;
  }));

  $('[data-wizard-back]', root).addEventListener('click', () => {
    if (paso > 1) return showStep(paso - 1);
    // Al salir del paso 1: si el usuario aún no tiene plan (flujo
    // inicial u onboarding), vuelve al onboarding para elegir
    // oposición; si ya lo tenía y estaba editando su disponibilidad,
    // vuelve a Perfil.  Nunca a Home cuando no hay plan (evita bucle).
    location.hash = state.tienePlan
      ? '#/perfil'
      : (state.oposiciones.length ? '#/home' : '#/onboarding');
  });

  // Escape de emergencia: cerrar sesión desde el propio wizard.
  const btnLogout = $('[data-wizard-logout]', root);
  if (btnLogout) btnLogout.addEventListener('click', () => {
    if (confirm('¿Cerrar sesión?')) cerrarSesion();
  });

  $('[data-wizard-finish]', root).addEventListener('click', async () => {
    const opos = state.principalId || (state.oposiciones[0] || {}).id;
    if (!opos) { toast('Elige primero una oposición'); return location.hash = '#/onboarding'; }
    const w = state.wizardData;
    try {
      // Nota: la fecha de examen NO se envía desde el wizard; la fija
      // el admin al crear/editar la oposición.  Omitimos por completo
      // p_fecha_examen del payload (no lo mandamos ni como null) para
      // que PostgREST resuelva la función usando el DEFAULT del schema
      // y funcione incluso si la BD conserva una versión previa de la
      // firma sin ese parámetro.
      await S.rpc('guardar_disponibilidad', {
        p_oposicion_id:  opos,
        p_modo:          w.modo,
        p_horas_semana:  w.modo === 'semanal' ? w.horas_semana : null,
        p_horas_por_dia: w.modo === 'diario'  ? w.horas_por_dia : null,
        p_ritmo:         w.ritmo,
        p_metodo:        w.metodo,
      }, { api: '/api' });
      // El plan ya existe: quitamos el flag de "sin plan" para que el
      // router no vuelva a redirigirnos aquí.
      state.tienePlan = true;
      state.planCargado = true;
      toast('¡Plan creado! Vamos allá.');
      location.hash = '#/home';
    } catch (e) { toast('Error: ' + e.message); }
  });
}

// ══════════════════════════════════════════════════════════════════════
// HOME
// ══════════════════════════════════════════════════════════════════════

async function renderHome() {
  mount('tpl-home');
  const root = $('.view-home');
  bindCommon(root);
  setAvatarChips(root);

  // Botón Estudiar: flujo automático si hay plan de hoy pendiente,
  // fallback al modal "cuánto tiempo tienes" si no hay nada plan-eado.
  $('[data-abrir-estudiar]', root).addEventListener('click', async () => {
    try {
      const sig = await S.rpc('siguiente_bloque_pendiente', {}, { api: '/api' });
      if (sig && sig.id && sig.es_hoy !== false) {
        // Arranca directamente el modo estudio guiado del plan.
        await iniciarEstudioAuto();
        return;
      }
    } catch (_) {}
    // Sin plan de hoy → deja elegir minutos manualmente.
    abrirModalEstudio();
  });

  // Sugerencia de disponibilidad al primer login del lunes.
  if (new Date().getDay() === 1 && !sessionStorage.getItem('sem-check-' + new Date().toDateString())) {
    sessionStorage.setItem('sem-check-' + new Date().toDateString(), '1');
    S.rpc('resumen_inicio_semana', {}, { api: '/api' })
      .then(d => { if (d && d.sugerida) mostrarModalSemana(d); })
      .catch(() => {});
  }

  // Reprograma automáticamente los días perdidos (silencioso).
  S.rpc('reprogramar_dia_perdido', {}, { api: '/api' }).catch(() => {});

  // Resumen semanal
  try {
    const rs = await S.rpc('resumen_semanal', {}, { api: '/api' });
    if (rs && rs.minutos_estudiados !== undefined) {
      $('[data-resumen-semanal]', root).hidden = false;
      $('[data-rs-mensaje]', root).textContent = rs.mensaje || '';
      $('[data-rs-min]', root).textContent = fmtMin(rs.minutos_estudiados);
      $('[data-rs-obj]', root).textContent = (rs.objetivos_cumplidos || 0) + '%';
      $('[data-rs-prec]', root).textContent = (rs.precision_media || 0) + '%';
    }
  } catch (_) {}

  let data = null;
  try { data = await S.rpc('dashboard_inicio', {}, { api: '/api' }); }
  catch (e) { toast('Error cargando datos: ' + e.message); return; }
  // PostgREST puede responder `null` sin lanzar excepción (jwt huérfano,
  // dashboard sin usuario). Normalizamos para no reventar más abajo.
  data = data || {};

  $('[data-nivel]', root).textContent = 'Nivel ' + (data.nivel || 1);
  $('[data-racha]', root).textContent = data.racha_dias || 0;
  $('[data-racha2]', root).textContent = data.racha_dias || 0;
  $('[data-minutos]', root).textContent = fmtMin(data.minutos_semana || 0);
  $('[data-pct]', root).textContent = (data.porcentaje || 0) + '%';

  // La card-continua se ha eliminado: el gran botón "Estudiar" ya
  // cubre exactamente la misma acción (continuar donde lo dejaste) y
  // duplicar la CTA confundía. Guardamos `data.continua` en local
  // por si la lista de "Tu día de hoy" queda vacía y queremos
  // ofrecer un fallback hacia la unidad en curso.
  const c = data.continua;

  // Plan de hoy real
  let hoy = [];
  try { hoy = await S.rpc('plan_del_dia', {}, { api: '/api' }); } catch (_) {}
  const hoyUl = $('[data-hoy]', root);
  if (hoy.length) {
    hoyUl.innerHTML = hoy.map((b, i) => {
      const ico = b.tipo === 'repaso'   ? { c:'ico-repaso',   e:'📖' }
                : b.tipo === 'descanso' ? { c:'ico-descanso', e:'☕' }
                : b.tipo === 'test'     ? { c:'ico-repaso',   e:'📋' }
                : b.tipo === 'simulacro'? { c:'ico-repaso',   e:'🎯' }
                                        : { c:'ico-verde',    e:'📚' };
      const hora = b.hora_inicio ? b.hora_inicio.slice(0,5) + ' · ' : '';
      const nombre = b.unidad || (b.tema ? b.tema : 'Sesión');
      return `<li data-i="${i}">
        <span class="ico-round ${ico.c}">${ico.e}</span>
        <div>
          <strong>${hora}${escapeHtml(nombre)}</strong>
          <span class="muted">${b.tipo === 'estudio' ? 'Estudia' : b.tipo} · ${b.minutos} min</span>
        </div>
        <span class="chevron">›</span></li>`;
    }).join('');
    $$('[data-i]', hoyUl).forEach(li => {
      li.addEventListener('click', () => {
        const b = hoy[+li.dataset.i];
        if (b.unidad_id) location.hash = '#/unidad/' + b.unidad_id;
      });
    });
  } else if (c) {
    hoyUl.innerHTML = `<li>
      <span class="ico-round ico-verde">📚</span>
      <div><strong>Continúa donde lo dejaste</strong>
      <span class="muted">${escapeHtml(c.nombre)} · ${c.minutos_est || 20} min</span></div>
      <span class="chevron">›</span></li>`;
    $('li', hoyUl).addEventListener('click', () => location.hash = '#/unidad/' + c.id);
  } else {
    hoyUl.innerHTML = `<li style="border:0">
      <span class="ico-round">🌱</span>
      <div><strong>Aún no tienes plan</strong>
      <span class="muted">Configura tu disponibilidad desde el Perfil</span></div>
      <span class="chevron">›</span></li>`;
  }
}

// ══════════════════════════════════════════════════════════════════════
// PLAN
// ══════════════════════════════════════════════════════════════════════

async function renderPlan() {
  mount('tpl-plan');
  const root = $('.view-plan');
  bindCommon(root);
  setAvatarChips(root);

  let [dashData, perfilData] = await Promise.all([
    S.rpc('dashboard_inicio', {}, { api: '/api' }).catch(() => ({})),
    S.rpc('dashboard_perfil', {}, { api: '/api' }).catch(() => ({})),
  ]);
  dashData = dashData || {}; perfilData = perfilData || {};

  $('[data-nivel]', root).textContent = 'Nivel ' + (dashData.nivel || 1);
  $('[data-racha]', root).textContent = dashData.racha_dias || 0;

  // Semana
  const nombres = ['Lun','Mar','Mié','Jue','Vie','Sáb','Dom'];
  const hoy = new Date();
  const dow = (hoy.getDay() + 6) % 7;
  const inicio = new Date(hoy); inicio.setDate(hoy.getDate() - dow);
  const week = $('[data-week]', root);
  week.innerHTML = Array.from({length: 7}, (_, i) => {
    const d = new Date(inicio); d.setDate(inicio.getDate() + i);
    return `<button class="${i === dow ? 'active' : ''}" data-day="${i}" data-fecha="${d.toISOString().slice(0,10)}">
              ${nombres[i]}<strong>${d.getDate()}</strong></button>`;
  }).join('');

  async function cargarDia(fechaISO) {
    let sesiones = [];
    try { sesiones = await S.rpc('plan_del_dia', { p_fecha: fechaISO }, { api: '/api' }); } catch (_) {}
    $('[data-bloques]', root).textContent = sesiones.length + ' bloques';
    const timeline = $('[data-timeline]', root);
    if (!sesiones.length) {
      timeline.innerHTML = `<li class="empty">
        <div class="empty-state">
          <span class="emoji" aria-hidden="true">🌤️</span>
          <p>No hay bloques planificados para este día.</p>
          <button class="btn btn-outline btn-mini" data-plan-editar-empty>Ajustar disponibilidad</button>
        </div>
      </li>`;
      const bEdit = timeline.querySelector('[data-plan-editar-empty]');
      if (bEdit) bEdit.addEventListener('click', () => location.hash = '#/wizard');
    } else {
      timeline.innerHTML = sesiones.map(b => {
        const ico = b.tipo === 'repaso'   ? '📖'
                  : b.tipo === 'descanso' ? '☕'
                  : b.tipo === 'test'     ? '📋'
                  : b.tipo === 'simulacro'? '🎯'
                                          : (b.tema_icono || '📚');
        const hora = b.hora_inicio ? b.hora_inicio.slice(0,5) : '—';
        return `<li class="${b.completada ? 'completada' : ''}">
          <span class="t-ico">${ico}</span>
          <div>
            <span class="t-hora">${hora} · ${escapeHtml(b.tema || b.tipo)}</span>
            <span class="t-nombre">${escapeHtml(b.unidad || b.tipo)}</span>
            <span class="t-sub">${b.minutos} min</span>
          </div>
          <span class="t-status">${b.completada ? '✅' : '⏱'}</span></li>`;
      }).join('');
    }
    const total = sesiones.length;
    const done = sesiones.filter(s => s.completada).length;
    const pct = total ? Math.round(done / total * 100) : 0;
    $('[data-plan-fill]', root).style.width = pct + '%';
    $('[data-plan-pct]', root).textContent = pct;
  }
  cargarDia(hoy.toISOString().slice(0,10));
  $$('button[data-fecha]', week).forEach(btn => {
    btn.addEventListener('click', () => {
      $$('button[data-fecha]', week).forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      cargarDia(btn.dataset.fecha);
    });
  });

  // Hito
  const plan = perfilData.plan;
  if (plan && plan.fecha_examen) {
    const dias = Math.max(0, Math.round((new Date(plan.fecha_examen) - new Date()) / 86400000));
    $('[data-hito-nombre]', root).textContent = 'Examen';
    $('[data-hito-desc]', root).textContent = 'En ' + dias + ' días';
  }

  $('[data-plan-editar]', root).addEventListener('click', () => location.hash = '#/wizard');
  $('[data-plan-reprog]', root).addEventListener('click', () => abrirCambioDisponibilidadHoy());
}

// Modal "Nueva semana" con la sugerencia (aprendizaje) y opción de
// modificar antes de aceptar.  Al aceptar guarda y recalcula plan.
function mostrarModalSemana(data) {
  const dows = [['lun','Lun'],['mar','Mar'],['mie','Mié'],['jue','Jue'],
                ['vie','Vie'],['sab','Sáb'],['dom','Dom']];
  const suger = data.sugerida || {};
  const actual = data.actual || {};
  const tpl = document.getElementById('tpl-semana');
  document.body.appendChild(tpl.content.cloneNode(true));
  const back = $('.modal-backdrop:last-of-type') || $('[data-modal]');
  const ul = $('[data-semana-days]', back);
  ul.innerHTML = dows.map(([k, l]) => {
    // Prioriza sugerida si tiene datos, si no lo actual del plan.
    const val = (suger[k] ?? actual[k] ?? 0);
    return `<li>
      <span class="day-lbl">${l}</span>
      <input type="number" min="0" max="12" step="0.5" value="${val}" data-day="${k}" inputmode="decimal">
      <span class="day-unit">h</span></li>`;
  }).join('');
  const totalEl = $('[data-semana-total]', back);
  const recalc = () => {
    const t = dows.reduce((s, [k]) => s + (parseFloat($(`[data-day="${k}"]`, back)?.value) || 0), 0);
    totalEl.textContent = t;
  };
  $$('[data-day]', back).forEach(i => i.addEventListener('input', recalc));
  recalc();

  const cerrar = () => back.remove();
  $('[data-modal-close]', back).addEventListener('click', cerrar);
  back.addEventListener('click', ev => { if (ev.target === back) cerrar(); });

  $('[data-semana-aceptar]', back).addEventListener('click', async () => {
    const hpd = {};
    dows.forEach(([k]) => { hpd[k] = parseFloat($(`[data-day="${k}"]`, back)?.value) || 0; });
    const oposId = state.principalId ||
                   (state.oposiciones[0] || {}).id;
    try {
      await S.rpc('guardar_disponibilidad', {
        p_oposicion_id:  oposId,
        p_modo:          'diario',
        p_horas_por_dia: hpd,
      }, { api: '/api' });
      toast('Semana planificada 🌱');
      cerrar();
      renderHome();
    } catch (e) { toast(e.message); }
  });
}

// Cambio puntual de disponibilidad para HOY.
function abrirCambioDisponibilidadHoy() {
  const opciones = [
    { min: 0,   lbl: 'No puedo estudiar' },
    { min: 15,  lbl: '15 minutos' },
    { min: 30,  lbl: '30 minutos' },
    { min: 60,  lbl: '1 hora' },
    { min: 120, lbl: '2 horas' },
    { min: 180, lbl: '3 horas o más' },
  ];
  const back = document.createElement('div');
  back.className = 'modal-backdrop';
  back.innerHTML = `<div class="modal">
    <button class="modal-close" data-cerrar aria-label="Cerrar">×</button>
    <h2>Hoy tengo otro tiempo</h2>
    <p class="muted small">Elige lo que puedes dedicar hoy. Recalcularemos el resto de la semana.</p>
    <div class="tiempo-chips" style="margin-top:var(--sp-2)">
      ${opciones.map(o => `<button type="button" data-m="${o.min}">${o.lbl}</button>`).join('')}
    </div>
  </div>`;
  document.body.appendChild(back);
  const cerrar = () => back.remove();
  $('[data-cerrar]', back).addEventListener('click', cerrar);
  back.addEventListener('click', ev => { if (ev.target === back) cerrar(); });
  $$('button[data-m]', back).forEach(b => b.addEventListener('click', async () => {
    const min = +b.dataset.m;
    try {
      await S.rpc('cambiar_disponibilidad_hoy', { p_minutos: min }, { api: '/api' });
      toast('Plan de hoy recalculado');
      cerrar();
      renderPlan();
    } catch (e) { toast(e.message); }
  }));
}

// ══════════════════════════════════════════════════════════════════════
// STATS
// ══════════════════════════════════════════════════════════════════════

async function renderStats() {
  mount('tpl-stats');
  const root = $('.view-stats');
  bindCommon(root);
  setAvatarChips(root);

  let d = null;
  try { d = await S.rpc('dashboard_estadisticas', {}, { api: '/api' }); }
  catch (e) { toast('Error cargando estadísticas'); return; }
  d = d || {};

  $('[data-racha]', root).textContent = d.racha_dias || 0;
  $('[data-racha2]', root).textContent = (d.racha_dias || 0) + ' días';
  $('[data-minutos]', root).textContent = fmtMin(d.minutos_semana || 0);
  $('[data-precision]', root).textContent = (d.precision_media || 0) + '%';
  $('[data-hechas]', root).textContent = d.unidades_hechas || 0;
  $('[data-totales]', root).textContent = d.unidades_totales || 0;
  $('[data-ring]', root).style.strokeDasharray = (d.porcentaje || 0) + ' 100';
  $('[data-ring-txt]', root).textContent = (d.porcentaje || 0) + '%';
  $('[data-progreso-lema]', root).textContent = (d.porcentaje || 0) >= 60
    ? '¡Muy buen ritmo!' : (d.porcentaje || 0) >= 20 ? '¡Sigue así!' : 'A por ello.';

  const dows = ['L','M','X','J','V','S','D'];
  const hoy = new Date();
  const dias = Array.from({length: 7}, (_, i) => {
    const d0 = new Date(hoy); d0.setDate(hoy.getDate() - (6 - i));
    const key = d0.toISOString().slice(0,10);
    const f = (d.actividad_semanal || []).find(x => x.dia === key);
    return { dow: dows[(d0.getDay() + 6) % 7], minutos: f ? f.minutos : 0 };
  });
  const max = Math.max(60, ...dias.map(x => x.minutos));
  $('[data-chart]', root).innerHTML = dias.map(x =>
    `<div class="bar" data-dow="${x.dow}" style="height:${Math.max(6, Math.round(x.minutos / max * 100))}%"></div>`
  ).join('');

  const ul = $('[data-rendimiento]', root);
  ul.innerHTML = (d.rendimiento || []).slice(0, 6).map(r => `
    <li>
      <span class="ico-round">${r.icono || '📘'}</span>
      <div class="m-nombre">
        <strong>${escapeHtml(r.nombre)}</strong>
        <div class="progress"><div class="progress-bar"><span style="width:${r.porcentaje}%"></span></div></div>
      </div>
      <span class="m-pct">${r.porcentaje}%</span></li>`).join('') ||
    `<li class="empty">
       <div class="empty-state">
         <span class="emoji" aria-hidden="true">📊</span>
         <p>Aún no hay resultados. Completa algunos tests para ver este ranking.</p>
       </div>
     </li>`;
}

// ══════════════════════════════════════════════════════════════════════
// PERFIL
// ══════════════════════════════════════════════════════════════════════

async function renderPerfil() {
  mount('tpl-perfil');
  const root = $('.view-perfil');
  bindCommon(root);

  // Las RPCs pueden devolver `null` (no un error) si el JWT apunta a
  // un usuario que no existe en la BBDD (jwt huérfano). El catch nos
  // protege del error de red, pero un body `null` legítimo pasa como
  // resultado. Normalizamos a {} para no reventar al leer campos.
  let [pd, di] = await Promise.all([
    S.rpc('dashboard_perfil', {}, { api: '/api' }).catch(() => ({})),
    S.rpc('dashboard_inicio', {}, { api: '/api' }).catch(() => ({})),
  ]);
  pd = pd || {}; di = di || {};

  $('[data-nombre]', root).textContent = pd.nombre || '—';
  $('[data-email]', root).textContent = (pd.email || '—') + (pd.email && !pd.email_verificado ? ' (sin verificar)' : '');
  $('[data-nivel]', root).textContent = 'Nivel ' + (pd.nivel || 1);
  $('[data-racha]', root).textContent = (pd.racha || 0) + ' días';
  $('[data-xp]', root).textContent = pd.xp || 0;
  $('[data-pct]', root).textContent = (di.porcentaje || 0) + '%';

  if (pd.oposicion_activa) {
    $('[data-obj-titulo]', root).textContent = pd.oposicion_activa.nombre;
    if (pd.plan?.fecha_examen) {
      const dias = Math.max(0, Math.round((new Date(pd.plan.fecha_examen) - new Date()) / 86400000));
      $('[data-obj-desc]', root).textContent = 'Examen en ' + dias + ' días';
    } else {
      $('[data-obj-desc]', root).textContent = 'Configura tu plan desde "Disponibilidad".';
    }
    $('[data-obj-fill]', root).style.width = (di.porcentaje || 0) + '%';
    $('[data-obj-pct]', root).textContent = di.porcentaje || 0;
  }

  const logros = pd.logros || [];
  $('[data-logros]', root).innerHTML = logros.map(l => `
    <li class="${l.obtenido ? 'obtenido' : ''}" title="${escapeHtml(l.titulo)}">
      <span class="logro-ico">${l.icono}</span>
      <span>${escapeHtml(l.titulo)}</span></li>`).join('') ||
    '<li class="muted">Sin logros aún</li>';

  // Disponibilidad label
  if (pd.plan) {
    const hpd = pd.plan.horas_por_dia || {};
    const total = ['lun','mar','mie','jue','vie','sab','dom']
      .reduce((s,d) => s + (hpd[d] || 0), 0);
    $('[data-perf-disp]', root).textContent =
      pd.plan.modo_disponibilidad === 'semanal'
        ? (pd.plan.horas_semana || 0) + ' h/semana'
        : total + ' h/semana · detalle por día';
  } else {
    $('[data-perf-disp]', root).textContent = 'Sin configurar';
  }

  $('[data-goto-wizard]', root).addEventListener('click', () => location.hash = '#/wizard');

  // Admin card
  if (state.session?.es_admin) $('[data-admin-card]', root).hidden = false;

  // Theme toggle
  const themeBtn = $('[data-toggle-theme]', root);
  const themeLbl = $('[data-theme-label]', root);
  const applyLabel = () => {
    const t = document.documentElement.getAttribute('data-theme') || 'auto';
    themeLbl.textContent = t === 'dark' ? 'Oscuro' : t === 'light' ? 'Claro' : 'Automático';
  };
  applyLabel();
  themeBtn.addEventListener('click', () => {
    const cur = document.documentElement.getAttribute('data-theme');
    const nxt = cur === 'dark' ? 'light' : 'dark';
    document.documentElement.setAttribute('data-theme', nxt);
    document.cookie = `aprentix_theme=${nxt};path=/;max-age=${60*60*24*365}`;
    applyLabel();
  });

  $('[data-logout]', root).addEventListener('click', cerrarSesion);
}

// ══════════════════════════════════════════════════════════════════════
// OPOSICIÓN — vista de temas, unidades y fecha del examen
// ══════════════════════════════════════════════════════════════════════

async function renderOposicion() {
  mount('tpl-oposicion');
  const root = $('.view-oposicion');
  bindCommon(root);
  setAvatarChips(root);

  // La oposición principal del usuario (la que se está estudiando).
  // Si no hay principal pero sí hay matriculadas, usamos la primera.
  const oposId = state.principalId || (state.oposiciones[0] || {}).id;
  if (!oposId) {
    location.hash = '#/onboarding';
    return;
  }

  // Nivel/racha para la cabecera consistente.
  try {
    const di = (await S.rpc('dashboard_inicio', {}, { api: '/api' })) || {};
    $('[data-nivel]', root).textContent = 'Nivel ' + (di.nivel || 1);
    $('[data-racha]', root).textContent = di.racha_dias || 0;
  } catch (_) {}

  // Detalle de la oposición (nombre, organismo, fecha_examen, temas...)
  let opos = null;
  try { opos = await S.rpc('obtener_oposicion',
        { p_oposicion_id: oposId }, { api: '/api' }); }
  catch (e) { toast('Error cargando la oposición: ' + e.message); return; }
  opos = opos || {};

  $('[data-opos-nombre]', root).textContent    = opos.nombre || '—';
  $('[data-opos-organismo]', root).textContent = opos.organismo || 'Oposición';

  // Fecha del examen (o estimación por el propio plan del usuario).
  const fEl    = $('[data-opos-fecha]', root);
  const fDet   = $('[data-opos-fecha-detalle]', root);
  if (opos.fecha_examen) {
    const d    = new Date(opos.fecha_examen);
    const dias = Math.max(0, Math.round((d - new Date()) / 86400000));
    fEl.textContent = d.toLocaleDateString('es-ES', {
      day: 'numeric', month: 'long', year: 'numeric',
    });
    fDet.textContent = opos.fecha_examen_orientativa
      ? `Fecha orientativa · en ~${dias} días`
      : `En ${dias} días`;
  } else {
    // Sin fecha oficial: intentamos una estimación por el propio
    // plan del usuario (fecha en la que acabaría el temario al
    // ritmo actual).  Si no hay plan, dejamos el "Sin confirmar".
    fEl.textContent = 'Sin confirmar';
    try {
      const pd = (await S.rpc('dashboard_perfil', {}, { api: '/api' })) || {};
      const p  = pd.plan;
      if (p && (p.horas_semana > 0 || Object.values(p.horas_por_dia || {})
                                            .some(v => (+v) > 0))) {
        const totalUnidades = (opos.temas || [])
          .reduce((s, t) => s + (t.unidades?.length || 0), 0);
        const minPorUnidad  = 25;                   // estimación media
        const totalHoras    = (totalUnidades * minPorUnidad) / 60;
        const hSemana = p.modo_disponibilidad === 'semanal'
          ? (p.horas_semana || 0)
          : Object.values(p.horas_por_dia || {}).reduce((s, v) => s + (+v || 0), 0);
        if (hSemana > 0) {
          const semanas = Math.ceil(totalHoras / hSemana);
          const est = new Date();
          est.setDate(est.getDate() + semanas * 7);
          fDet.textContent = `Estimación al ritmo actual: ${est.toLocaleDateString(
            'es-ES', { month: 'long', year: 'numeric' })}`;
        } else {
          fDet.textContent = 'Configura tu disponibilidad para ver una estimación.';
        }
      } else {
        fDet.textContent = 'Configura tu disponibilidad para ver una estimación.';
      }
    } catch (_) {
      fDet.textContent = 'La fija el administrador al crear o editar la oposición.';
    }
  }

  // Temas y unidades (colapsables)
  const temas = opos.temas || [];
  $('[data-opos-count]', root).textContent = temas.length + ' tema' + (temas.length === 1 ? '' : 's');
  const ul = $('[data-opos-temas]', root);
  if (!temas.length) {
    ul.innerHTML = `<li class="empty">
      <div class="empty-state">
        <span class="emoji" aria-hidden="true">📖</span>
        <p>La oposición aún no tiene temas cargados.</p>
      </div>
    </li>`;
    return;
  }
  ul.innerHTML = temas.map(t => {
    const unids = (t.unidades || []).map(u => `
      <li data-uid="${u.id}">
        <span class="u-nombre">${escapeHtml(u.nombre)}</span>
        <span class="u-min">${u.minutos_est || 20} min</span>
      </li>`).join('');
    return `<li class="opos-tema" data-tid="${t.id}">
      <div class="opos-tema-head">
        <span class="t-ico">${t.icono || '📘'}</span>
        <div>
          <strong>${escapeHtml(t.nombre)}</strong>
          <span class="muted">${(t.unidades || []).length} unidades</span>
        </div>
        <span class="opos-tema-toggle">›</span>
      </div>
      <ul class="opos-unidades">${unids || '<li class="muted">Sin unidades aún</li>'}</ul>
    </li>`;
  }).join('');

  // Toggle de expansión por tema.
  $$('.opos-tema-head', ul).forEach(h => {
    h.addEventListener('click', () => h.parentElement.classList.toggle('open'));
  });
  // Click en unidad → abrir su vista.
  $$('.opos-unidades li[data-uid]', ul).forEach(li => {
    li.addEventListener('click', ev => {
      ev.stopPropagation();
      location.hash = '#/unidad/' + li.dataset.uid;
    });
  });
}


// ══════════════════════════════════════════════════════════════════════
// UNIDAD (unificada teoría+test) con AUTO-TRACKING
// ══════════════════════════════════════════════════════════════════════

let _sesActiva = null;   // { sesionId, unidadId, tickTimer, seconds, minutosEst }

async function renderUnidad(r) {
  const uid = r.params?.id;
  if (!uid) { location.hash = '#/home'; return; }
  await sesionCerrarPrevia();
  mount('tpl-unidad');
  const root = $('.view-unidad');
  $('[data-back]', root).addEventListener('click', () => history.back());

  let u = null;
  try { u = await S.rpc('obtener_unidad', { p_unidad_id: uid }, { api: '/api' }); }
  catch (e) { toast('Error cargando unidad'); return; }

  const tema = u.tema_id ? await S.rpc('obtener_tema',
      { p_tema_id: u.tema_id }, { api: '/api' }).catch(() => null) : null;

  $('[data-unidad-tema]', root).textContent = tema?.nombre || 'Tema';
  $('[data-unidad-nombre]', root).textContent = u.nombre;
  $('[data-unidad-min]', root).textContent = (u.minutos_est || 15) + ' min';
  $('[data-preguntas-n]', root).textContent = u.num_preguntas || 0;

  $('[data-teoria]', root).innerHTML = mdBasic(u.teoria_md || '_(Sin contenido de teoría todavía)_');
  const minAcum = (u.progreso && u.progreso.minutos_estudiados) || 0;
  $('[data-unidad-min-actuales]', root).textContent = minAcum;
  $('[data-unidad-min-total]', root).textContent = u.minutos_est || 15;
  $('[data-unidad-fill]', root).style.width =
    Math.min(100, Math.round((minAcum / Math.max(1, u.minutos_est || 15)) * 100)) + '%';

  // Si no hay preguntas, oculta el CTA del test
  if (!u.num_preguntas) $('[data-panel="test-cta"]', root).hidden = true;

  // Botón "Comenzar test"
  $('[data-test-start]', root).addEventListener('click', async () => {
    $('[data-panel="test-cta"]', root).hidden = true;
    await iniciarTest(uid, root);
  });

  // Abre sesión de estudio y arranca ticks
  await sesionAbrir(uid, u.minutos_est || 15);
}

async function sesionAbrir(unidadId, minutosEst) {
  try {
    const r = await S.rpc('sesion_abrir', { p_unidad_id: unidadId }, { api: '/api' });
    _sesActiva = {
      sesionId: r.sesion_id,
      unidadId,
      minutosEst,
      seconds: 0,
    };
    // Un tick cada 30 s SOLO si la pestaña está visible.
    _sesActiva.tickTimer = setInterval(() => {
      if (document.visibilityState !== 'visible') return;
      _sesActiva.seconds += 30;
      S.rpc('sesion_tick',
        { p_sesion_id: _sesActiva.sesionId, p_delta_seg: 30 },
        { api: '/api' }).catch(() => {});
      // Actualiza barra de progreso local
      const min = Math.round(_sesActiva.seconds / 60);
      const el1 = document.querySelector('[data-unidad-min-actuales]');
      const el2 = document.querySelector('[data-unidad-fill]');
      if (el1) el1.textContent = min;
      if (el2) el2.style.width = Math.min(100,
        Math.round((min / Math.max(1, _sesActiva.minutosEst)) * 100)) + '%';
    }, 30000);
    // Cierre limpio al salir
    window.addEventListener('pagehide', sesionCerrarPrevia, { once: true });
    window.addEventListener('beforeunload', sesionCerrarPrevia, { once: true });
  } catch (e) { /* silencioso */ }
}

async function sesionCerrarPrevia() {
  if (!_sesActiva) return;
  const s = _sesActiva; _sesActiva = null;
  clearInterval(s.tickTimer);
  try {
    await S.rpc('sesion_cerrar', { p_sesion_id: s.sesionId }, { api: '/api' });
  } catch (_) {}
}

async function iniciarTest(uid, root) {
  const pTest = $('[data-panel="test"]', root);
  pTest.hidden = false;
  let sesion = null;
  try { sesion = await S.rpc('iniciar_test_unidad', { p_unidad_id: uid, p_n: 10 }, { api: '/api' }); }
  catch (e) {
    pTest.innerHTML = `<p class="muted">${
      String(e.message).includes('sin_preguntas')
        ? 'Esta unidad todavía no tiene preguntas.' : e.message}</p>`;
    return;
  }

  const preguntas = sesion.preguntas || [];
  let idx = 0, correctas = 0;
  const total = preguntas.length;

  function paint() {
    if (idx >= total) {
      $('[data-test-q]', pTest).textContent = '';
      $('[data-test-options]', pTest).innerHTML = '';
      $('[data-test-explicacion]', pTest).hidden = true;
      $('[data-test-siguiente]', pTest).hidden = true;
      const nota = Math.round((correctas / total) * 10 * 100) / 100;
      $('[data-test-resultado]', pTest).innerHTML =
        `<div>Nota: <strong>${nota}</strong> / 10</div>
         <div class="muted">${correctas} correctas de ${total}</div>`;
      $('[data-test-resultado]', pTest).hidden = false;
      $('[data-test-progress]', pTest).textContent = '';
      S.rpc('finalizar_intento', { p_intento_id: sesion.intento_id }, { api: '/api' })
        .catch(() => {});
      return;
    }
    const p = preguntas[idx];
    $('[data-test-progress]', pTest).textContent = `Pregunta ${idx + 1} de ${total}`;
    $('[data-test-q]', pTest).textContent = p.enunciado;
    $('[data-test-explicacion]', pTest).hidden = true;
    $('[data-test-siguiente]', pTest).hidden = true;
    const opts = $('[data-test-options]', pTest);
    opts.innerHTML = '';
    const barajadas = [...p.opciones].sort(() => Math.random() - .5);
    barajadas.forEach(o => {
      const b = document.createElement('button');
      b.type = 'button';
      b.textContent = o.texto;
      b.addEventListener('click', async () => {
        $$('button', opts).forEach(x => x.disabled = true);
        let r = null;
        try {
          r = await S.rpc('responder_pregunta', {
            p_intento_id: sesion.intento_id,
            p_pregunta_id: p.id,
            p_opcion: o.texto,
          }, { api: '/api' });
        } catch (e) { toast(e.message); return; }
        if (r.correcta) { b.classList.add('correcta'); correctas++; }
        else {
          b.classList.add('incorrecta');
          const buenoBtn = $$('button', opts).find(x => x.textContent === r.correcta_esperada);
          if (buenoBtn) buenoBtn.classList.add('correcta');
        }
        if (r.explicacion) {
          $('[data-test-explicacion]', pTest).textContent = r.explicacion;
          $('[data-test-explicacion]', pTest).hidden = false;
        }
        $('[data-test-siguiente]', pTest).hidden = false;
      });
      opts.appendChild(b);
    });
  }
  $('[data-test-siguiente]', pTest).addEventListener('click', () => { idx++; paint(); });
  paint();
}

// ══════════════════════════════════════════════════════════════════════
// ADMIN
// ══════════════════════════════════════════════════════════════════════

async function renderAdmin() {
  if (!state.session?.es_admin) { toast('Sólo admin'); location.hash = '#/perfil'; return; }
  mount('tpl-admin');
  const root = $('.view-admin');
  $('[data-back]', root).addEventListener('click', () => history.back());

  try {
    const s = await S.rpc('admin_stats', {}, { api: '/api' });
    if (s) {
      $('[data-ad-usr]', root).textContent  = s.usuarios || 0;
      $('[data-ad-opos]', root).textContent = s.oposiciones || 0;
      $('[data-ad-mail]', root).textContent = s.emails_pendientes || 0;
      $('[data-ad-push]', root).textContent = s.push_pendientes || 0;
    }
  } catch (_) {}

  async function cargar(q = null) {
    let users = [];
    try { users = await S.rpc('admin_listar_usuarios',
        { p_query: q, p_limit: 100 }, { api: '/api' }); }
    catch (_) {}
    const ul = $('[data-ad-users]', root);
    ul.innerHTML = users.map(u => {
      const roles = (u.roles || []).map(r =>
        `<span class="u-tag ${r === 'admin' ? 'warn' : ''}">${r}</span>`).join('');
      return `<li>
        <div class="u-meta">
          <span class="u-mail">${escapeHtml(u.email)}</span>
          <span class="u-nombre">${escapeHtml(u.nombre)}</span>
          <div class="u-tags">
            ${roles}
            ${u.activo ? '<span class="u-tag ok">activo</span>' : '<span class="u-tag warn">inactivo</span>'}
            ${u.email_verificado ? '' : '<span class="u-tag warn">sin verificar</span>'}
          </div>
        </div>
        <div class="u-actions">
          <button class="btn btn-mini btn-outline" data-act="toggle" data-id="${u.id}" data-val="${!u.activo}">
            ${u.activo ? 'Desactivar' : 'Activar'}
          </button>
          ${u.email_verificado ? '' :
            `<button class="btn btn-mini btn-outline" data-act="verify" data-id="${u.id}">Verificar</button>`}
          <button class="btn btn-mini btn-outline" data-act="rol-admin" data-id="${u.id}"
                  data-val="${!(u.roles || []).includes('admin')}">
            ${(u.roles || []).includes('admin') ? 'Quitar admin' : 'Hacer admin'}
          </button>
        </div>
      </li>`;
    }).join('');

    $$('[data-act]', ul).forEach(b => b.addEventListener('click', async () => {
      const id = b.dataset.id, act = b.dataset.act;
      try {
        if (act === 'toggle') {
          await S.rpc('admin_set_activo',
            { p_usuario_id: id, p_activo: b.dataset.val === 'true' }, { api: '/api' });
        } else if (act === 'verify') {
          await S.rpc('admin_verificar_email', { p_usuario_id: id }, { api: '/api' });
        } else if (act === 'rol-admin') {
          await S.rpc('admin_toggle_rol',
            { p_usuario_id: id, p_rol: 'admin', p_asignar: b.dataset.val === 'true' },
            { api: '/api' });
        }
        toast('Hecho');
        cargar($('[data-ad-buscar]', root).value.trim() || null);
      } catch (e) { toast(e.message); }
    }));
  }
  cargar();

  const buscar = $('[data-ad-buscar]', root);
  let tId;
  buscar.addEventListener('input', () => {
    clearTimeout(tId);
    tId = setTimeout(() => cargar(buscar.value.trim() || null), 220);
  });

  // Listado editable de oposiciones (fecha del examen).
  async function cargarOpos() {
    let opos = [];
    try {
      const r = await fetch(
        '/api/oposiciones?select=id,nombre,organismo,fecha_examen,fecha_examen_orientativa,activa&order=nombre',
        { headers: authHeaders() });
      if (r.ok) opos = await r.json();
    } catch (_) {}
    const ul = $('[data-ad-opos-lista]', root);
    ul.innerHTML = opos.map(o => `
      <li data-id="${o.id}">
        <div>
          <a class="op-titulo" href="#/editar/${o.id}">${escapeHtml(o.nombre)}</a>
          <span class="op-org">${escapeHtml(o.organismo || '—')}</span>
        </div>
        <div class="op-form">
          <input type="date" value="${o.fecha_examen || ''}" data-fecha>
          <label>
            <input type="checkbox" ${o.fecha_examen_orientativa ? 'checked' : ''} data-orient>
            orientativa
          </label>
          <button class="btn btn-mini btn-outline" data-guardar>Guardar</button>
        </div>
      </li>`).join('') || '<li class="muted">No hay oposiciones aún</li>';

    $$('li[data-id]', ul).forEach(li => {
      $('[data-guardar]', li)?.addEventListener('click', async () => {
        try {
          await S.rpc('admin_editar_oposicion', {
            p_oposicion_id: li.dataset.id,
            p_fecha_examen: $('[data-fecha]', li).value || null,
            p_fecha_examen_orientativa: $('[data-orient]', li).checked,
          }, { api: '/api' });
          toast('Fecha actualizada');
        } catch (e) { toast(e.message); }
      });
    });
  }
  cargarOpos();
}

// ══════════════════════════════════════════════════════════════════════
// ADMINISTRACIÓN — importar oposiciones desde JSON
// ══════════════════════════════════════════════════════════════════════

async function renderAdministracion() {
  if (!state.session?.es_admin) {
    toast('Sólo admin');
    location.hash = state.oposiciones.length ? '#/perfil' : '#/onboarding';
    return;
  }
  mount('tpl-administracion');
  const root = $('.view-administracion');
  const form = $('[data-form-importar]', root);
  const txt  = $('[data-json-oposicion]', root);
  const err  = $('[data-error-importacion]', root);
  const btn  = $('button[type="submit"]', form);

  $('[data-volver-administracion]', root).addEventListener('click', () => {
    location.hash = state.oposiciones.length ? '#/perfil' : '#/onboarding';
  });

  form.addEventListener('submit', async ev => {
    ev.preventDefault();
    err.hidden = true;
    let payload;
    try { payload = JSON.parse(txt.value); }
    catch (_) {
      err.textContent = 'El contenido no es un JSON válido.';
      err.hidden = false; txt.focus(); return;
    }
    if (!payload || typeof payload !== 'object' || !payload.slug || !payload.nombre) {
      err.textContent = 'El JSON debe incluir al menos «slug» y «nombre».';
      err.hidden = false; return;
    }

    btn.disabled = true; btn.textContent = 'Importando…';
    try {
      const r = await S.rpc('importar_oposicion', { p_payload: payload }, { api: '/api' });
      state.oposiciones = [];
      toast('Oposición importada. Nuevos: ' + (r.temas_nuevos || 0) +
            ' · Reutilizados: ' + (r.temas_reutilizados || 0));
      txt.value = '';
    } catch (e) {
      err.textContent = 'No se pudo importar: ' + e.message;
      err.hidden = false;
    } finally {
      btn.disabled = false; btn.textContent = 'Importar oposición';
    }
  });
}

// ══════════════════════════════════════════════════════════════════════
// RESET PASSWORD
// ══════════════════════════════════════════════════════════════════════

async function renderReset(r) {
  mount('tpl-reset');
  const root = $('.auth-view');
  const token = r.query?.token;
  const panel = $('[data-panel]', root);
  if (!token) {
    panel.innerHTML = `<h2 style="color:var(--danger)">Enlace inválido</h2>
      <p>Falta el token en la URL.</p>
      <button class="btn btn-outline btn-block" onclick="location.hash='#/auth'">Ir al inicio</button>`;
    return;
  }
  const form = $('[data-form-reset]', panel);
  const pw   = form.password;
  const pw2  = form.password2;
  const err  = $('[data-err]', form);
  const hint = $('[data-pw-strength]', form);
  const fill = $('[data-pw-fill]', form);
  const lbl  = $('[data-pw-label]', form);
  const match= $('[data-pw-match]', form);

  function updatePw() {
    const { nivel, etiqueta } = calcPwLevel(pw.value);
    hint.classList.remove('lvl-1','lvl-2','lvl-3','lvl-4');
    if (nivel) hint.classList.add('lvl-' + nivel);
    lbl.textContent = etiqueta;
    if (!pw.value) fill.style.width = '0%';
  }
  function updateMatch() {
    if (!pw2.value) { match.hidden = true; return; }
    match.hidden = false;
    const ok = pw.value === pw2.value;
    match.textContent = ok ? '✓ Coinciden' : '✗ No coinciden';
    match.classList.toggle('ok', ok);
    match.classList.toggle('err', !ok);
  }
  pw.addEventListener('input', () => { updatePw(); updateMatch(); });
  pw2.addEventListener('input', updateMatch);

  form.addEventListener('submit', async ev => {
    ev.preventDefault();
    err.hidden = true;
    if (pw.value !== pw2.value) { err.textContent = 'No coinciden.'; err.hidden = false; return; }
    if (calcPwLevel(pw.value).nivel < 2) { err.textContent = 'Contraseña muy débil.'; err.hidden = false; return; }
    try {
      await S.rpc('aplicar_reset', { p_token: token, p_password: pw.value },
                   { api: '/api', token: null });
      toast('Contraseña actualizada. Ya puedes entrar.');
      location.hash = '#/auth';
    } catch (e) {
      err.textContent = String(e.message).includes('token_invalido')
        ? 'Enlace caducado o ya usado.' : e.message;
      err.hidden = false;
    }
  });
}

// ══════════════════════════════════════════════════════════════════════
// MODO ESTUDIO — modal + vista fullscreen + cronómetro
// ══════════════════════════════════════════════════════════════════════

let _estudioTimer = null;
let _sistemas = null;

// Arranca modo estudio directamente con los bloques pendientes del
// plan de HOY (flujo del botón "Estudiar" cuando ya hay plan).
async function iniciarEstudioAuto() {
  try {
    // Lee minutos pendientes de hoy para dimensionar la sesión.
    const hoy = await S.rpc('plan_del_dia', {}, { api: '/api' });
    const pend = (hoy || []).filter(b => !b.completada);
    const total = pend.reduce((s, b) => s + (b.minutos || 25), 0) || 30;
    await S.rpc('iniciar_estudio',
      { p_minutos_total: Math.max(15, total), p_sistema_id: null },
      { api: '/api' });
    location.hash = '#/estudio';
  } catch (e) { toast('No se pudo iniciar: ' + e.message); }
}

async function abrirModalEstudio() {
  // Carga sistemas de estudio (una vez)
  if (!_sistemas) {
    try { _sistemas = await S.rpc('sistemas_estudio', {}, { api: '/api' }); }
    catch (_) { _sistemas = []; }
    // Alternativa: leer via REST sin RPC (tabla pública)
    if (!Array.isArray(_sistemas) || !_sistemas.length) {
      const r = await fetch('/api/sistemas_estudio?select=id,nombre,codigo&activo=eq.true',
                             { headers: authHeaders() });
      _sistemas = r.ok ? await r.json() : [];
    }
  }

  const tpl = document.getElementById('tpl-estudiar-modal');
  document.body.appendChild(tpl.content.cloneNode(true));
  const back = $('[data-modal]');
  const sel  = $('[data-sistema]', back);
  sel.innerHTML = _sistemas.map(s =>
    `<option value="${s.id}">${escapeHtml(s.nombre)}</option>`).join('') ||
    '<option value="">Pomodoro clásico</option>';

  const h = $('[data-h]', back), m = $('[data-m]', back);
  $$('[data-quick]', back).forEach(b => b.addEventListener('click', () => {
    const total = +b.dataset.quick;
    h.value = Math.floor(total / 60);
    m.value = total % 60;
  }));

  function cerrar() { back.remove(); }
  $('[data-modal-close]', back).addEventListener('click', cerrar);
  back.addEventListener('click', ev => { if (ev.target === back) cerrar(); });

  $('[data-empezar-estudio]', back).addEventListener('click', async () => {
    const total = (parseInt(h.value, 10) || 0) * 60 + (parseInt(m.value, 10) || 0);
    if (total < 10) return toast('Al menos 10 minutos');
    const sistema = parseInt(sel.value, 10) || null;
    try {
      await S.rpc('iniciar_estudio',
        { p_minutos_total: total, p_sistema_id: sistema }, { api: '/api' });
      cerrar();
      location.hash = '#/estudio';
    } catch (e) {
      toast(e.message.includes('minutos_insuficientes')
        ? 'Al menos 10 minutos.' : 'No se pudo iniciar: ' + e.message);
    }
  });
}

function authHeaders() {
  const t = S.getToken();
  return t ? { Authorization: 'Bearer ' + t, Accept: 'application/json' }
           : { Accept: 'application/json' };
}

async function renderEstudio() {
  // Carga sesión activa
  let ses = null;
  try { ses = await S.rpc('obtener_sesion_activa', {}, { api: '/api' }); }
  catch (_) {}
  if (!ses || !ses.plan_bloques) {
    toast('No hay sesión activa. Pulsa "Estudiar" primero.');
    location.hash = '#/home';
    return;
  }

  mount('tpl-estudio');
  const root = $('.view-estudio');
  await sesionCerrarPrevia();  // por si hay auto-tracking de otra unidad

  const bloques = ses.plan_bloques;
  let idx = ses.bloque_idx || 0;
  const totalIniciado = new Date(ses.bloque_iniciado || ses.iniciada_en).getTime();

  $('[data-estudio-salir]', root).addEventListener('click', async () => {
    if (!confirm('¿Terminar la sesión ahora?')) return;
    clearInterval(_estudioTimer);
    try { await S.rpc('cerrar_estudio', {}, { api: '/api' }); } catch (_) {}
    location.hash = '#/home';
  });

  let bloqueActual;
  let bloqueIniciadoTs = totalIniciado;

  async function pintarBloque() {
    bloqueActual = bloques[idx];
    if (!bloqueActual || bloqueActual.tipo === 'final') return terminar();

    $('[data-estudio-idx]', root).textContent = `Bloque ${idx + 1} de ${bloques.length - 1}`;
    const tipoLbl = ({
      estudio:        'Estudia',
      repaso:         'Repasa',
      test:           'Test rápido',
      descanso:       'Descanso',
      descanso_largo: 'Descanso largo',
    })[bloqueActual.tipo] || 'Sesión';
    $('[data-estudio-tipo]', root).textContent = tipoLbl;
    $('[data-crono-total]', root).textContent = 'de ' + (bloqueActual.minutos || 0) + ' min';
    $('[data-estudio-saltar]', root).hidden =
      !['descanso', 'descanso_largo'].includes(bloqueActual.tipo);

    const cuerpo = $('[data-estudio-cuerpo]', root);
    if (bloqueActual.tipo === 'descanso' || bloqueActual.tipo === 'descanso_largo') {
      cuerpo.innerHTML = `
        <div class="estudio-descanso">
          <span class="emoji">☕</span>
          <h3>Toca respirar</h3>
          <p class="muted">Levántate, mira lejos, un vaso de agua.</p>
        </div>`;
    } else if (bloqueActual.tipo === 'estudio' && bloqueActual.unidad_id) {
      try {
        const u = await S.rpc('obtener_unidad',
          { p_unidad_id: bloqueActual.unidad_id }, { api: '/api' });
        cuerpo.innerHTML = `<div class="prose">${mdBasic(u.teoria_md || '_Sin contenido_')}</div>`;
      } catch (_) {
        cuerpo.innerHTML = `<p class="muted">No se ha podido cargar la unidad.</p>`;
      }
    } else if (bloqueActual.tipo === 'repaso' && bloqueActual.preguntas_ids?.length) {
      await renderPreguntasRepaso(cuerpo, bloqueActual.preguntas_ids);
    } else if (bloqueActual.tipo === 'repaso') {
      cuerpo.innerHTML = `<div class="prose"><h2>Repaso rápido</h2>
        <p>Hoy no tienes repasos vencidos. Aprovecha el bloque para releer un tema.</p></div>`;
    } else {
      cuerpo.innerHTML = `<p class="muted">Bloque listo.</p>`;
    }

    bloqueIniciadoTs = Date.now();
    clearInterval(_estudioTimer);
    _estudioTimer = setInterval(tickCronometro, 1000);
    tickCronometro();
  }

  function tickCronometro() {
    const minutos = bloqueActual?.minutos || 0;
    const seg = Math.max(0, Math.floor((Date.now() - bloqueIniciadoTs) / 1000));
    const total = minutos * 60;
    const restante = Math.max(0, total - seg);
    const mm = String(Math.floor(restante / 60)).padStart(2, '0');
    const ss = String(restante % 60).padStart(2, '0');
    $('[data-crono-mmss]', root).textContent = mm + ':' + ss;
    const pct = total ? Math.min(100, (seg / total) * 100) : 0;
    $('[data-crono-ring]', root).style.strokeDasharray = pct + ' 100';
    if (restante === 0) {
      clearInterval(_estudioTimer);
      // avance automático
      avanzar();
    }
  }

  async function avanzar() {
    try {
      const sig = await S.rpc('siguiente_bloque_estudio', {}, { api: '/api' });
      idx += 1;
      if (!sig || sig.tipo === 'final') return terminar();
      pintarBloque();
    } catch (e) { toast(e.message); }
  }

  $('[data-estudio-siguiente]', root).addEventListener('click', avanzar);
  $('[data-estudio-saltar]', root).addEventListener('click', async () => {
    try {
      await S.rpc('saltar_descanso', {}, { api: '/api' });
      idx += 1;
      pintarBloque();
    } catch (e) { toast(e.message); }
  });

  async function terminar() {
    clearInterval(_estudioTimer);
    let res = null;
    try { res = await S.rpc('cerrar_estudio', {}, { api: '/api' }); } catch (_) {}
    const cuerpo = $('[data-estudio-cuerpo]', root);
    cuerpo.innerHTML = `<div class="estudio-final">
      <span class="emoji">🎉</span>
      <h2>¡Sesión completada!</h2>
      <p>Has estudiado durante <strong>${res?.minutos_totales || 0}</strong> min.</p>
      <p class="muted">+${res?.minutos_totales || 0} XP</p>
    </div>`;
    $('[data-estudio-siguiente]', root).textContent = 'Volver al Inicio';
    $('[data-estudio-siguiente]', root).onclick = () => location.hash = '#/home';
    $('[data-estudio-saltar]', root).hidden = true;
  }

  pintarBloque();
}


// Renderiza N preguntas con sus opciones dentro del bloque de repaso.
// Al responder cada una, llama a registrar_respuesta_espaciada.
async function renderPreguntasRepaso(cuerpo, ids) {
  cuerpo.innerHTML = `<div class="prose"><h2>Repaso rápido</h2>
    <p class="muted">${ids.length} preguntas vencidas.</p></div>
    <div data-repaso-container></div>`;
  const cont = $('[data-repaso-container]', cuerpo);

  // PostgREST REST plano (más fiable que RPC para "in list").
  let preguntas = [];
  try {
    const r = await fetch(
      '/api/preguntas?select=id,enunciado,opciones,explicacion&id=in.(' +
      ids.map(encodeURIComponent).join(',') + ')',
      { headers: authHeaders() });
    if (r.ok) preguntas = await r.json();
  } catch (_) {}
  if (!preguntas.length) {
    cont.innerHTML = '<p class="muted">No se pudieron cargar las preguntas.</p>';
    return;
  }

  let idx = 0, ok = 0;
  function pintar() {
    if (idx >= preguntas.length) {
      cont.innerHTML = `<div class="test-resultado">
        Repaso hecho: <strong>${ok}</strong> de ${preguntas.length}
      </div>`;
      return;
    }
    const p = preguntas[idx];
    // Nota: `opciones` es jsonb con [{texto, correcta}]. Filtramos
    // `correcta` para no descubrirla en el DOM.
    const opciones = [...(p.opciones || [])].sort(() => Math.random() - 0.5);
    cont.innerHTML = `
      <div class="test-progress">Pregunta ${idx + 1} de ${preguntas.length}</div>
      <div class="test-q">${escapeHtml(p.enunciado)}</div>
      <div class="test-options" data-opts></div>
      <div class="test-explicacion" data-exp hidden></div>
      <button class="btn btn-primary btn-block" data-next hidden style="margin-top:8px">Siguiente</button>`;
    const opts = $('[data-opts]', cont);
    opciones.forEach(o => {
      const b = document.createElement('button');
      b.type = 'button';
      b.textContent = o.texto;
      b.addEventListener('click', async () => {
        $$('button', opts).forEach(x => x.disabled = true);
        const acierto = !!o.correcta;
        if (acierto) { b.classList.add('correcta'); ok++; }
        else {
          b.classList.add('incorrecta');
          const buenoBtn = $$('button', opts).find(x =>
            x.textContent === (opciones.find(oo => oo.correcta) || {}).texto);
          if (buenoBtn) buenoBtn.classList.add('correcta');
        }
        if (p.explicacion) {
          $('[data-exp]', cont).textContent = p.explicacion;
          $('[data-exp]', cont).hidden = false;
        }
        $('[data-next]', cont).hidden = false;
        try {
          await S.rpc('registrar_respuesta_espaciada',
            { p_pregunta_id: p.id, p_correcta: acierto }, { api: '/api' });
        } catch (_) {}
      });
      opts.appendChild(b);
    });
    $('[data-next]', cont).addEventListener('click', () => { idx++; pintar(); });
  }
  pintar();
}


// ══════════════════════════════════════════════════════════════════════
// EDITOR VISUAL DE OPOSICIONES
// ══════════════════════════════════════════════════════════════════════
// Ruta: #/editar/<oposicion_id>
// Navegación jerárquica (temas → unidades → preguntas) usando paneles
// que se muestran/ocultan. Cada mutación va vía RPCs admin_*.

const _ed = {
  oposicionId: null,
  oposicionNombre: '',
  temaId: null,
  temaNombre: '',
  unidadId: null,
};

async function renderEditar(r) {
  if (!state.session?.es_admin) {
    toast('Sólo admin'); location.hash = '#/perfil'; return;
  }
  const oposicionId = r.params?.id;
  if (!oposicionId) { location.hash = '#/administracion'; return; }
  _ed.oposicionId = oposicionId;
  _ed.temaId = _ed.unidadId = null;

  mount('tpl-editar');
  const root = $('.view-editar');
  $('[data-back]', root).addEventListener('click', () => {
    if (_ed.unidadId)     { _ed.unidadId = null; edMostrar('unidades'); return; }
    if (_ed.temaId)       { _ed.temaId = null;   edMostrar('temas'); return; }
    location.hash = '#/administracion';
  });

  // Cargar nombre de la oposición.
  try {
    const rop = await fetch('/api/oposiciones?id=eq.' + oposicionId + '&select=nombre',
                             { headers: authHeaders() });
    const arr = rop.ok ? await rop.json() : [];
    _ed.oposicionNombre = arr[0]?.nombre || 'Oposición';
    $('[data-op-nombre]', root).textContent = _ed.oposicionNombre;
  } catch (_) {}

  edMostrar('temas');
  cargarTemas();
}

function edCrumbs() {
  const c = $('[data-crumbs]');
  if (!c) return;
  const bits = [
    `<a href="#/administracion">Admin</a>`,
    `<span class="sep">›</span>`,
    `<a href="#/editar/${_ed.oposicionId}">${escapeHtml(_ed.oposicionNombre)}</a>`,
  ];
  if (_ed.temaId) {
    bits.push('<span class="sep">›</span>',
              `<span>${escapeHtml(_ed.temaNombre)}</span>`);
  }
  if (_ed.unidadId) {
    bits.push('<span class="sep">›</span>', '<span>Unidad</span>');
  }
  c.innerHTML = bits.join(' ');
}

function edMostrar(panel) {
  ['temas','unidades','unidad','pregunta'].forEach(p => {
    const el = $('[data-panel-' + p + ']');
    if (el) el.hidden = (p !== panel);
  });
  edCrumbs();
}

async function cargarTemas() {
  const ul = $('[data-lista-temas]');
  let temas = [];
  try {
    temas = await S.rpc('admin_temas_de_oposicion',
      { p_oposicion_id: _ed.oposicionId }, { api: '/api' });
  } catch (_) {}
  ul.innerHTML = (temas || []).map(t => `
    <li class="editable-item" data-tid="${t.tema_id}" data-tnom="${escapeHtml(t.nombre)}">
      <div>
        <strong>${t.icono || '📘'} ${escapeHtml(t.nombre)}
          <span class="muted small">· orden ${t.orden}</span></strong>
        <span class="muted">${t.num_unidades} unidades · ${t.num_preguntas} preguntas</span>
      </div>
      <div class="ed-actions">
        <button class="btn btn-mini btn-outline" data-quitar>Quitar</button>
      </div>
    </li>`).join('') ||
    '<li class="muted">Aún no hay temas. Añade uno con el botón "+ Tema".</li>';

  $$('li[data-tid]', ul).forEach(li => {
    li.addEventListener('click', ev => {
      if (ev.target.closest('[data-quitar]')) return;
      _ed.temaId = li.dataset.tid;
      _ed.temaNombre = li.dataset.tnom;
      edMostrar('unidades');
      $('[data-tema-titulo]').textContent = 'Unidades — ' + _ed.temaNombre;
      cargarUnidades();
    });
    $('[data-quitar]', li).addEventListener('click', async () => {
      if (!confirm('¿Quitar este tema de la oposición? (Los datos del tema no se borran.)')) return;
      try {
        await S.rpc('admin_desvincular_tema',
          { p_oposicion_id: _ed.oposicionId, p_tema_id: li.dataset.tid },
          { api: '/api' });
        cargarTemas();
      } catch (e) { toast(e.message); }
    });
  });

  $('[data-nuevo-tema]').onclick = () => modalNuevoTema();
}

function modalNuevoTema() {
  const tpl = document.getElementById('tpl-modal-tema');
  document.body.appendChild(tpl.content.cloneNode(true));
  const back = $('.modal-backdrop:last-of-type');
  const form = $('[data-form]', back);
  const cerrar = () => back.remove();
  $('[data-modal-close]', back).addEventListener('click', cerrar);
  back.addEventListener('click', ev => { if (ev.target === back) cerrar(); });

  form.addEventListener('submit', async ev => {
    ev.preventDefault();
    try {
      await S.rpc('admin_upsert_tema', {
        p_tema_id:      null,
        p_slug:         form.slug.value.trim(),
        p_nombre:       form.nombre.value.trim(),
        p_icono:        form.icono.value.trim() || '📘',
        p_oposicion_id: _ed.oposicionId,
      }, { api: '/api' });
      cerrar();
      cargarTemas();
    } catch (e) { toast('Error: ' + e.message); }
  });
}

async function cargarUnidades() {
  const ul = $('[data-lista-unidades]');
  let unids = [];
  try {
    unids = await S.rpc('admin_unidades_de_tema',
      { p_tema_id: _ed.temaId }, { api: '/api' });
  } catch (_) {}
  ul.innerHTML = (unids || []).map(u => `
    <li class="editable-item" data-uid="${u.id}">
      <div>
        <strong>#${u.orden} · ${escapeHtml(u.nombre)}</strong>
        <span class="muted">${u.num_preguntas} preguntas · ${u.minutos_est} min</span>
      </div>
      <div class="ed-actions">
        <button class="btn btn-mini btn-outline" data-borrar>Borrar</button>
      </div>
    </li>`).join('') ||
    '<li class="muted">Sin unidades todavía. Añade una con "+ Unidad".</li>';

  $$('li[data-uid]', ul).forEach(li => {
    li.addEventListener('click', ev => {
      if (ev.target.closest('[data-borrar]')) return;
      _ed.unidadId = li.dataset.uid;
      edMostrar('unidad');
      abrirEditorUnidad(li.dataset.uid);
    });
    $('[data-borrar]', li).addEventListener('click', async () => {
      if (!confirm('¿Borrar esta unidad y todas sus preguntas?')) return;
      try {
        await S.rpc('admin_borrar_unidad',
          { p_unidad_id: li.dataset.uid }, { api: '/api' });
        cargarUnidades();
      } catch (e) { toast(e.message); }
    });
  });

  $('[data-nueva-unidad]').onclick = async () => {
    _ed.unidadId = null;
    edMostrar('unidad');
    abrirEditorUnidad(null);
  };
}

async function abrirEditorUnidad(unidadId) {
  const form = $('[data-form-unidad]');
  const titulo = $('[data-unidad-titulo-edit]');
  // Estado por defecto: crear nueva.
  form.nombre.value = ''; form.slug.value = '';
  form.orden.value = 1; form.minutos_est.value = 20;
  form.resumen.value = ''; form.teoria_md.value = '';

  if (unidadId) {
    try {
      const arr = await S.rpc('admin_unidades_de_tema',
        { p_tema_id: _ed.temaId }, { api: '/api' });
      const u = (arr || []).find(x => x.id === unidadId);
      if (u) {
        form.nombre.value = u.nombre || '';
        form.slug.value = u.slug || '';
        form.orden.value = u.orden || 1;
        form.minutos_est.value = u.minutos_est || 20;
        form.resumen.value = u.resumen || '';
        form.teoria_md.value = u.teoria_md || '';
        titulo.textContent = 'Editar — ' + u.nombre;
      }
    } catch (_) {}
    cargarPreguntas(unidadId);
  } else {
    titulo.textContent = 'Nueva unidad';
    $('[data-lista-preguntas]').innerHTML =
      '<li class="muted">Guarda la unidad primero para añadir preguntas.</li>';
  }

  $('[data-guardar-unidad]').onclick = async () => {
    try {
      const r = await S.rpc('admin_upsert_unidad', {
        p_unidad_id:   unidadId,
        p_tema_id:     _ed.temaId,
        p_slug:        form.slug.value.trim(),
        p_nombre:      form.nombre.value.trim(),
        p_orden:       parseInt(form.orden.value, 10) || 1,
        p_teoria_md:   form.teoria_md.value,
        p_resumen:     form.resumen.value.trim() || null,
        p_minutos_est: parseInt(form.minutos_est.value, 10) || 20,
      }, { api: '/api' });
      toast('Unidad guardada');
      if (!unidadId && r?.unidad_id) {
        _ed.unidadId = r.unidad_id;
        abrirEditorUnidad(r.unidad_id);
      }
    } catch (e) { toast('Error: ' + e.message); }
  };

  $('[data-nueva-pregunta]').onclick = () => {
    if (!_ed.unidadId) return toast('Guarda la unidad primero');
    edMostrar('pregunta');
    abrirEditorPregunta(null);
  };
}

async function cargarPreguntas(unidadId) {
  const ul = $('[data-lista-preguntas]');
  let pregs = [];
  try {
    pregs = await S.rpc('admin_preguntas_de_unidad',
      { p_unidad_id: unidadId }, { api: '/api' });
  } catch (_) {}
  ul.innerHTML = (pregs || []).map(p => `
    <li class="editable-item" data-pid="${p.id}">
      <div>
        <strong>${escapeHtml((p.enunciado || '').slice(0, 100))}${(p.enunciado || '').length > 100 ? '…' : ''}</strong>
        <span class="muted">${(p.opciones || []).length} opciones · dif ${p.dificultad || 2}</span>
      </div>
      <div class="ed-actions">
        <button class="btn btn-mini btn-outline" data-borrar-preg>Borrar</button>
      </div>
    </li>`).join('') ||
    '<li class="muted">Sin preguntas todavía. Añade una con "+ Pregunta".</li>';

  $$('li[data-pid]', ul).forEach(li => {
    li.addEventListener('click', ev => {
      if (ev.target.closest('[data-borrar-preg]')) return;
      edMostrar('pregunta');
      abrirEditorPregunta(li.dataset.pid);
    });
    $('[data-borrar-preg]', li).addEventListener('click', async () => {
      if (!confirm('¿Borrar pregunta?')) return;
      try {
        await S.rpc('admin_borrar_pregunta',
          { p_pregunta_id: li.dataset.pid }, { api: '/api' });
        cargarPreguntas(unidadId);
      } catch (e) { toast(e.message); }
    });
  });
}

async function abrirEditorPregunta(preguntaId) {
  const form = $('[data-form-pregunta]');
  const titulo = $('[data-preg-titulo]');
  const opsUl  = $('[data-opciones]');
  form.enunciado.value = ''; form.explicacion.value = '';
  form.dificultad.value = 2;
  opsUl.innerHTML = '';

  const pintarOpciones = (arr) => {
    opsUl.innerHTML = arr.map((o, i) => `
      <li data-i="${i}">
        <input type="radio" name="correcta" ${o.correcta ? 'checked' : ''}>
        <input type="text" value="${escapeHtml(o.texto || '')}" placeholder="Texto de la opción">
        <button type="button" class="op-borrar" aria-label="Borrar">×</button>
      </li>`).join('');
    $$('li', opsUl).forEach((li, i) => {
      const inputText = li.querySelector('input[type=text]');
      const radio = li.querySelector('input[type=radio]');
      const upd = () => {
        radio.addEventListener('change', () => {
          $$('input[type=text]', opsUl).forEach(x => x.classList.remove('correcta'));
          inputText.classList.add('correcta');
        });
        if (radio.checked) inputText.classList.add('correcta');
      };
      upd();
      li.querySelector('.op-borrar').addEventListener('click', () => {
        arr.splice(i, 1);
        pintarOpciones(arr.length ? arr : [{ texto: '', correcta: true }]);
      });
    });
  };

  let opciones = [
    { texto: '', correcta: true },
    { texto: '', correcta: false },
    { texto: '', correcta: false },
    { texto: '', correcta: false },
  ];

  if (preguntaId) {
    try {
      const arr = await S.rpc('admin_preguntas_de_unidad',
        { p_unidad_id: _ed.unidadId }, { api: '/api' });
      const p = (arr || []).find(x => x.id === preguntaId);
      if (p) {
        form.enunciado.value = p.enunciado || '';
        form.explicacion.value = p.explicacion || '';
        form.dificultad.value = p.dificultad || 2;
        opciones = (p.opciones || []).map(o => ({
          texto: o.texto || '', correcta: !!o.correcta
        }));
        if (!opciones.length) opciones.push({ texto: '', correcta: true });
        titulo.textContent = 'Editar pregunta';
      }
    } catch (_) {}
  } else {
    titulo.textContent = 'Nueva pregunta';
  }
  pintarOpciones(opciones);

  $('[data-add-opcion]').onclick = () => {
    // Lee valores actuales del DOM y añade una nueva vacía.
    const arr = leerOpcionesDom();
    arr.push({ texto: '', correcta: false });
    pintarOpciones(arr);
  };

  function leerOpcionesDom() {
    return $$('li', opsUl).map(li => ({
      texto: li.querySelector('input[type=text]').value.trim(),
      correcta: li.querySelector('input[type=radio]').checked,
    })).filter(o => o.texto);
  }

  $('[data-guardar-pregunta]').onclick = async () => {
    const arr = leerOpcionesDom();
    if (arr.length < 2) return toast('Al menos 2 opciones con texto');
    if (!arr.some(o => o.correcta)) return toast('Marca la opción correcta');
    try {
      const r = await S.rpc('admin_upsert_pregunta', {
        p_pregunta_id: preguntaId,
        p_unidad_id:   _ed.unidadId,
        p_enunciado:   form.enunciado.value.trim(),
        p_opciones:    arr,
        p_explicacion: form.explicacion.value.trim() || null,
        p_dificultad:  parseInt(form.dificultad.value, 10) || 2,
      }, { api: '/api' });
      toast('Pregunta guardada');
      _ed.unidadId && cargarPreguntas(_ed.unidadId);
      edMostrar('unidad');
    } catch (e) { toast('Error: ' + e.message); }
  };
}


// ══════════════════════════════════════════════════════════════════════
// Utils varios
// ══════════════════════════════════════════════════════════════════════

function escapeHtml(str) {
  if (str == null) return '';
  return String(str)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
    .replace(/"/g,'&quot;').replace(/'/g,'&#39;');
}

/** Markdown mínimo. */
function mdBasic(txt) {
  return txt
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
    .replace(/^### (.+)$/gm, '<h3>$1</h3>')
    .replace(/^## (.+)$/gm,  '<h2>$1</h2>')
    .replace(/^# (.+)$/gm,   '<h1>$1</h1>')
    .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
    .replace(/_([^_\n]+)_/g, '<em>$1</em>')
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/^\- (.+)$/gm, '<li>$1</li>')
    .replace(/(<li>.+<\/li>\n?)+/g, m => '<ul>' + m + '</ul>')
    .replace(/\n{2,}/g, '</p><p>')
    .replace(/^(?!<[uho])(.+)$/gm, '$1')
    .replace(/^(.*)$/s, '<p>$1</p>');
}
