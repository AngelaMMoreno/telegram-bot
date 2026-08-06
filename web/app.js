/* ═══════════════════════════════════════════════════════════════════════
   Aprentix (DESA)  ──  app.js
   -----------------------------------------------------------------------
   SPA nueva orientada a oposiciones.  Vistas:
     - auth         (login + registro con email + confirmar email)
     - onboarding   (elegir oposición)
     - home         (mockup 1)
     - plan         (mockup 2)
     - stats        (mockup 3)
     - perfil       (mockup 4)
     - administracion (importar oposiciones, solo administradores)
     - unidad       (teoría + test)
     - verify       (aterrizaje del enlace de confirmación de email)

   Toda la comunicación con la BBDD va vía RPCs de PostgREST — reutiliza
   window.AprentixSession (shared/auth/session.js) para el JWT y la
   llamada `rpc(fn, args, {api:'/api'})`.

   Este fichero es autosuficiente: no depende de shared/spa-router ni de
   los componentes web personalizados del sitio anterior (los usaban
   tests/teoría).  Estilo: vanilla ES2020 sin bundler.
   ═══════════════════════════════════════════════════════════════════════ */
'use strict';

const S = window.AprentixSession;
if (!S) throw new Error('AprentixSession no cargado');

const $  = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

// ═══════════════════════════════════════════════════════════════════════
// ROUTER (hash-based; nada de History API porque este bundle vive bajo
// /app/ sin backend propio — con hashes evitamos que Caddy tenga que
// reescribir rutas).
// ═══════════════════════════════════════════════════════════════════════

const state = {
  session: null,          // { user_id, email, nombre, roles, es_admin, ... }
  oposiciones: [],
  principalId: null,
};

const routes = {
  auth:       renderAuth,
  verify:     renderVerify,
  onboarding: renderOnboarding,
  home:       renderHome,
  plan:       renderPlan,
  stats:      renderStats,
  perfil:     renderPerfil,
  administracion: renderizarAdministracion,
  unidad:     renderUnidad,
};

function parseHash() {
  // #/home        → { name: 'home', params: {} }
  // #/unidad/UUID → { name: 'unidad', params: { id: 'UUID' } }
  // #/verify?token=xxx→ { name: 'verify', query: { token: '...' } }
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
  // El aterrizaje de "verificar cuenta" no requiere sesión.
  if (r.name === 'verify') return renderVerify(r);

  // Si no hay token, forzamos auth (salvo que ya estemos en auth).
  if (!S.getToken() && r.name !== 'auth') {
    location.hash = '#/auth';
    return;
  }

  if (S.getToken() && !state.session) {
    try {
      state.session = await S.rpc('mi_sesion', {}, { api: '/api' });
      state.session = state.session[0] || state.session;    // PostgREST devuelve array
    } catch (e) {
      // Token caducado o inválido → limpia y a login.
      S.clearToken();
      location.hash = '#/auth';
      return;
    }
  }

  // Onboarding se muestra la primera vez (sin oposiciones matriculadas)
  if (state.session && !state.oposiciones.length) {
    try {
      const mis = await S.rpc('mis_oposiciones', {}, { api: '/api' });
      state.oposiciones = mis || [];
      state.principalId = (state.oposiciones.find(o => o.principal) || {}).id || null;
    } catch (e) { /* silencioso */ }
  }
  const rutaPermitidaSinOposicion = r.name === 'onboarding' || r.name === 'auth'
    || (r.name === 'administracion' && state.session.es_admin);
  if (state.session && !state.oposiciones.length && !rutaPermitidaSinOposicion) {
    location.hash = '#/onboarding';
    return;
  }

  const view = routes[r.name] || renderHome;
  await view(r);
  updateNav(r.name);
}

window.addEventListener('hashchange', router);
window.addEventListener('load', router);

// ═══════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════

function mount(templateId) {
  const tpl = document.getElementById(templateId);
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
  const map = { home: 'home', plan: 'plan', stats: 'stats', perfil: 'perfil', unidad: null, administracion: null };
  const target = map[name];
  const nav = $('.bottom-nav');
  if (!nav || name === 'auth' || name === 'verify' || name === 'onboarding') {
    nav && nav.remove();
    return;
  }
  $$('.bottom-nav [data-nav]').forEach(btn => {
    btn.classList.toggle('active', btn.dataset.nav === target);
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

// ═══════════════════════════════════════════════════════════════════════
// AUTH — login + registro
// ═══════════════════════════════════════════════════════════════════════

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
  updateNav('auth');

  // Cambio de tab (login / registro)
  $$('.auth-tab', root).forEach(tab => {
    tab.addEventListener('click', () => {
      $$('.auth-tab', root).forEach(t => t.classList.toggle('active', t === tab));
      $$('.auth-panel', root).forEach(p => p.classList.toggle('active', p.dataset.panel === tab.dataset.tab));
      // Limpia error visible
      $$('[data-err]', root).forEach(e => { e.hidden = true; e.textContent = ''; });
    });
  });

  // Reenvío de verificación
  $('[data-reenviar]', root).addEventListener('click', async () => {
    const email = $('input[name="email"]', $('[data-panel="login"]', root)).value.trim();
    if (!email) return toast('Introduce el correo primero');
    try {
      await S.rpc('reenviar_verificacion', { p_email: email }, { api: '/api' });
      toast('Si la cuenta existe y estaba sin verificar, te llegará un nuevo enlace.');
    } catch (e) { toast(e.message); }
  });

  // LOGIN
  $('[data-panel="login"]', root).addEventListener('submit', async ev => {
    ev.preventDefault();
    const err = $('[data-err]', ev.currentTarget);
    err.hidden = true;
    const email = ev.currentTarget.email.value.trim();
    const pass  = ev.currentTarget.password.value;
    try {
      const r = await S.rpc('login_web', { p_email: email, p_password: pass }, { api: '/api', token: null });
      S.setToken(r.token);
      state.session = null; state.oposiciones = [];
      location.hash = '#/home';
    } catch (e) {
      if (String(e.message).includes('email_no_verificado')) {
        err.textContent = 'Aún no has confirmado tu correo. Comprueba tu buzón (o pulsa "Reenviar confirmación").';
      } else if (String(e.message).includes('credenciales')) {
        err.textContent = 'Correo o contraseña incorrectos.';
      } else {
        err.textContent = e.message;
      }
      err.hidden = false;
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
    pwHint.classList.remove('lvl-1', 'lvl-2', 'lvl-3', 'lvl-4');
    if (nivel) pwHint.classList.add('lvl-' + nivel);
    pwLabel.textContent = etiqueta;
    // ancho controlado por CSS via .lvl-N; forzamos "reset" cuando está vacío
    if (!regPw.value) pwFill.style.width = '0%';
  }
  function updateMatch() {
    if (!regPw2.value) { pwMatch.hidden = true; return; }
    pwMatch.hidden = false;
    if (regPw.value === regPw2.value) {
      pwMatch.textContent = '✓ Las contraseñas coinciden';
      pwMatch.classList.remove('err'); pwMatch.classList.add('ok');
    } else {
      pwMatch.textContent = '✗ No coinciden';
      pwMatch.classList.remove('ok'); pwMatch.classList.add('err');
    }
  }
  function updateEmailMatch() {
    if (!regEmail2.value) { emMatch.hidden = true; return; }
    emMatch.hidden = false;
    if (regEmail.value.trim().toLowerCase() === regEmail2.value.trim().toLowerCase()) {
      emMatch.textContent = '✓ Los correos coinciden';
      emMatch.classList.remove('err'); emMatch.classList.add('ok');
    } else {
      emMatch.textContent = '✗ No coinciden';
      emMatch.classList.remove('ok'); emMatch.classList.add('err');
    }
  }

  regPw.addEventListener('input', () => { updatePw(); updateMatch(); });
  regPw2.addEventListener('input', updateMatch);
  regEmail.addEventListener('input', updateEmailMatch);
  regEmail2.addEventListener('input', updateEmailMatch);

  regPanel.addEventListener('submit', async ev => {
    ev.preventDefault();
    const err = $('[data-err]', regPanel);
    err.hidden = true;
    const nombre = regPanel.nombre.value.trim();
    const email  = regEmail.value.trim().toLowerCase();
    const email2 = regEmail2.value.trim().toLowerCase();
    const pw     = regPw.value;
    const pw2    = regPw2.value;
    if (email !== email2) { err.textContent = 'Los correos no coinciden.'; err.hidden = false; return; }
    if (pw !== pw2)       { err.textContent = 'Las contraseñas no coinciden.'; err.hidden = false; return; }
    if (calcPwLevel(pw).nivel < 2) {
      err.textContent = 'Elige una contraseña más fuerte.'; err.hidden = false; return;
    }
    try {
      await S.rpc('registrar_web', {
        p_email:    email,
        p_password: pw,
        p_nombre:   nombre,
      }, { api: '/api', token: null });
      // Muestra pantalla de "revisa tu correo"
      showVerificationPending(email);
    } catch (e) {
      if (String(e.message).includes('email_registrado')) {
        err.textContent = 'Ese correo ya está registrado.';
      } else if (String(e.message).includes('password_debil')) {
        err.textContent = 'La contraseña debe tener al menos 8 caracteres.';
      } else if (String(e.message).includes('email_invalido')) {
        err.textContent = 'El correo no tiene un formato válido.';
      } else {
        err.textContent = e.message;
      }
      err.hidden = false;
    }
  });
}

function showVerificationPending(email) {
  const app = document.getElementById('app');
  app.innerHTML = `
    <section class="auth-view">
      <div class="fox-badge fox-badge-hero"></div>
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
  const token = r.query?.token;
  const app = document.getElementById('app');
  app.innerHTML = `
    <section class="auth-view">
      <div class="fox-badge fox-badge-hero"></div>
      <div class="auth-card" style="text-align:center" data-panel>
        <h2 style="color:var(--pri-d);margin-top:0">Confirmando tu cuenta…</h2>
        <p class="muted">Espera un momento.</p>
      </div>
    </section>`;
  const panel = $('[data-panel]');
  updateNav('verify');
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
      <p>Solicita un nuevo enlace desde "Reenviar confirmación" en la pantalla de acceso.</p>
      <button class="btn btn-outline btn-block" onclick="location.hash='#/auth'">Volver</button>`;
  }
}

// ═══════════════════════════════════════════════════════════════════════
// ONBOARDING
// ═══════════════════════════════════════════════════════════════════════

async function renderOnboarding() {
  mount('tpl-onboarding');
  const root = $('.view-onboarding');
  const ul = $('[data-onboarding]', root);
  const btn = $('[data-onboarding-guardar]', root);
  let seleccionada = null;

  let opos = [];
  try {
    opos = await S.rpc('listar_oposiciones', {}, { api: '/api' });
  } catch (e) {
    toast('Error cargando oposiciones: ' + e.message);
  }

  ul.innerHTML = opos.map(o => `
    <li data-id="${o.id}">
      <span class="ico-round">📘</span>
      <div>
        <strong>${o.nombre}</strong>
        <span class="muted">${o.organismo || ''} · ${o.num_temas || 0} temas</span>
      </div>
      <span class="chevron">›</span>
    </li>
  `).join('') || '<p class="muted">No hay oposiciones disponibles. Contacta con el administrador para importar una.</p>';

  const accesoAdministracion = $('[data-ir-administracion]', root);
  accesoAdministracion.hidden = !state.session?.es_admin;
  accesoAdministracion.addEventListener('click', () => { location.hash = '#/administracion'; });

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
      await S.rpc('matricular_oposicion', {
        p_oposicion_id: seleccionada, p_principal: true,
      }, { api: '/api' });
      state.oposiciones = []; // fuerza recarga
      location.hash = '#/home';
    } catch (e) { toast('Error: ' + e.message); }
  });
}

// ═══════════════════════════════════════════════════════════════════════
// ADMINISTRACIÓN — importar oposiciones desde JSON
// ═══════════════════════════════════════════════════════════════════════

async function renderizarAdministracion() {
  if (!state.session?.es_admin) {
    toast('Esta sección es exclusiva para administradores.', 'error');
    location.hash = state.oposiciones.length ? '#/home' : '#/onboarding';
    return;
  }

  mount('tpl-administracion');
  const root = $('.view-administracion');
  const formulario = $('[data-form-importar]', root);
  const campoJson = $('[data-json-oposicion]', root);
  const error = $('[data-error-importacion]', root);
  const boton = $('button[type="submit"]', formulario);

  $('[data-volver-administracion]', root).addEventListener('click', () => {
    location.hash = state.oposiciones.length ? '#/perfil' : '#/onboarding';
  });

  formulario.addEventListener('submit', async evento => {
    evento.preventDefault();
    error.hidden = true;
    let contenido;
    try {
      contenido = JSON.parse(campoJson.value);
    } catch (_) {
      error.textContent = 'El contenido no es un JSON válido.';
      error.hidden = false;
      campoJson.focus();
      return;
    }

    if (!contenido || typeof contenido !== 'object' || !contenido.slug || !contenido.nombre) {
      error.textContent = 'El JSON debe incluir, como mínimo, los campos «slug» y «nombre».';
      error.hidden = false;
      return;
    }

    boton.disabled = true;
    boton.textContent = 'Importando…';
    try {
      await S.rpc('importar_oposicion', { p_payload: contenido }, { api: '/api' });
      state.oposiciones = [];
      toast('Oposición importada correctamente. Ya está disponible para elegirla.');
      location.hash = '#/onboarding';
    } catch (e) {
      error.textContent = 'No se pudo importar: ' + e.message;
      error.hidden = false;
    } finally {
      boton.disabled = false;
      boton.textContent = 'Importar oposición';
    }
  });
}

// ═══════════════════════════════════════════════════════════════════════
// HOME
// ═══════════════════════════════════════════════════════════════════════

async function renderHome() {
  mount('tpl-home');
  const root = $('.view-home');
  bindCommon(root);
  setAvatarChips(root);

  let data = null;
  try {
    data = await S.rpc('dashboard_inicio', {}, { api: '/api' });
  } catch (e) { toast('Error cargando datos: ' + e.message); return; }

  $('[data-nivel]', root).textContent = 'Nivel ' + (data.nivel || 1);
  $('[data-racha]', root).textContent = data.racha_dias || 0;
  $('[data-racha2]', root).textContent = data.racha_dias || 0;
  $('[data-minutos]', root).textContent = (data.minutos_semana || 0) + 'm';
  $('[data-pct]', root).textContent = (data.porcentaje || 0) + '%';

  // Continúa estudiando
  const c = data.continua;
  const cardC = $('.card-continua', root);
  if (c) {
    $('[data-continua-tema]', cardC).textContent = c.tema_nombre;
    $('[data-continua-unidad]', cardC).textContent = c.nombre;
    $('[data-continua-ico]', cardC).textContent = c.tema_icono || '📘';
    $('[data-continua-min]', cardC).textContent = (c.minutos_est || 20) + ' min';
    $('[data-continua-fill]', cardC).style.width = (c.progreso_pct || 0) + '%';
    $('[data-continua-pct]', cardC).textContent = c.progreso_pct || 0;
    $('[data-continua-btn]', cardC).addEventListener('click', () => {
      location.hash = '#/unidad/' + c.id;
    });
  } else {
    cardC.innerHTML = `<div class="card-body">
      <div class="book-avatar">✅</div>
      <div class="card-body-txt"><h3>¡Todo al día!</h3>
      <p class="muted">Elige una unidad desde el Plan para seguir avanzando.</p></div>
    </div>`;
  }

  // Bloques de "Tu día de hoy" — mientras el motor de plan no exista,
  // proponemos un plan tipo con la unidad "continua" + repaso + descanso.
  const hoyUl = $('[data-hoy]', root);
  const bloques = [];
  if (c) bloques.push({
    ico: '📋', clase: 'ico-verde',
    titulo: 'Sesión 1', desc: `Test de la unidad ${c.nombre}`, action: () => location.hash = '#/unidad/' + c.id,
  });
  bloques.push({
    ico: '📖', clase: 'ico-repaso',
    titulo: 'Repaso', desc: 'Preguntas falladas', action: () => toast('Próximamente'),
  });
  bloques.push({
    ico: '☕', clase: 'ico-descanso',
    titulo: 'Descanso', desc: 'Pausa recomendada en 40 min', action: () => toast('Buen momento para una pausa'),
  });
  hoyUl.innerHTML = bloques.map((b, i) => `
    <li data-i="${i}">
      <span class="ico-round ${b.clase}">${b.ico}</span>
      <div><strong>${b.titulo}</strong><span class="muted">${b.desc}</span></div>
      <span class="chevron">›</span>
    </li>`).join('');
  $$('[data-i]', hoyUl).forEach(li => {
    li.addEventListener('click', () => bloques[+li.dataset.i].action());
  });
}

// ═══════════════════════════════════════════════════════════════════════
// PLAN
// ═══════════════════════════════════════════════════════════════════════

async function renderPlan() {
  mount('tpl-plan');
  const root = $('.view-plan');
  bindCommon(root);
  setAvatarChips(root);

  $('[data-nivel]', root).textContent = 'Nivel ' + ((await sessionData()).nivel || 1);
  $('[data-racha]', root).textContent = (await sessionData()).racha || 0;

  // Semana Lun–Dom con el día actual resaltado
  const nombres = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
  const hoy = new Date();
  const dow = (hoy.getDay() + 6) % 7; // 0..6, Lun=0
  const inicio = new Date(hoy);
  inicio.setDate(hoy.getDate() - dow);
  const week = $('[data-week]', root);
  week.innerHTML = Array.from({length: 7}, (_, i) => {
    const d = new Date(inicio); d.setDate(inicio.getDate() + i);
    const isToday = i === dow;
    return `<button class="${isToday ? 'active' : ''}" data-day="${i}">
              ${nombres[i]}<strong>${d.getDate()}</strong>
            </button>`;
  }).join('');

  // Plan de hoy — de momento se genera a partir de la primera unidad
  // pendiente + un repaso + un descanso.  Cuando el motor de planning
  // real esté implementado, se leerá de plan_sesiones.
  const cInicio = await S.rpc('dashboard_inicio', {}, { api: '/api' });
  const c = cInicio.continua;
  const bloques = [];
  if (c) bloques.push({ hora: '08:00', ico: '⚖️', titulo: c.tema_nombre, sub: c.nombre + ' · ' + (c.minutos_est || 25) + ' min' });
  bloques.push({ hora: '18:30', ico: '📋', titulo: 'Repaso', sub: 'Repaso + test · 40 min' });
  bloques.push({ hora: '20:00', ico: '🧘', titulo: 'Descanso activo', sub: 'Pausa guiada · 10 min' });

  $('[data-bloques]', root).textContent = bloques.length + ' bloques';
  $('[data-timeline]', root).innerHTML = bloques.map(b => `
    <li>
      <span class="t-ico">${b.ico}</span>
      <div>
        <span class="t-hora">${b.hora} · ${b.titulo}</span>
        <p>${b.sub}</p>
      </div>
    </li>`).join('');

  const pct = cInicio.porcentaje || 0;
  $('[data-plan-fill]', root).style.width = pct + '%';
  $('[data-plan-pct]', root).textContent = pct;

  // Próximo hito: usa fecha_examen del plan si existe
  const perfil = await S.rpc('dashboard_perfil', {}, { api: '/api' });
  const plan = perfil.plan;
  if (plan && plan.fecha_examen) {
    const dias = Math.max(0, Math.round((new Date(plan.fecha_examen) - new Date()) / 86400000));
    $('[data-hito-desc]', root).textContent = 'En ' + dias + ' días';
  } else {
    $('[data-hito-desc]', root).textContent = 'Configura tu plan para verlo';
  }

  $('[data-plan-editar]', root).addEventListener('click', () => toast('El wizard de plan llegará en la próxima iteración.'));
  $('[data-plan-reprog]', root).addEventListener('click', () => toast('El wizard de plan llegará en la próxima iteración.'));
}

// ═══════════════════════════════════════════════════════════════════════
// ESTADÍSTICAS
// ═══════════════════════════════════════════════════════════════════════

async function renderStats() {
  mount('tpl-stats');
  const root = $('.view-stats');
  bindCommon(root);
  setAvatarChips(root);

  let d = null;
  try {
    d = await S.rpc('dashboard_estadisticas', {}, { api: '/api' });
  } catch (e) { toast('Error cargando estadísticas'); return; }

  $('[data-racha]', root).textContent = d.racha_dias || 0;
  $('[data-racha2]', root).textContent = (d.racha_dias || 0) + ' días';
  $('[data-minutos]', root).textContent = fmtMin(d.minutos_semana || 0);
  $('[data-precision]', root).textContent = (d.precision_media || 0) + '%';
  $('[data-hechas]', root).textContent = d.unidades_hechas || 0;
  $('[data-totales]', root).textContent = d.unidades_totales || 0;
  $('[data-ring]', root).style.strokeDasharray = (d.porcentaje || 0) + ' 100';
  $('[data-ring-txt]', root).textContent = (d.porcentaje || 0) + '%';

  // Chart de barras (7 días).  Rellena con 0 los días que faltan.
  const dows = ['L', 'M', 'X', 'J', 'V', 'S', 'D'];
  const hoy = new Date();
  const dias = Array.from({length: 7}, (_, i) => {
    const d0 = new Date(hoy); d0.setDate(hoy.getDate() - (6 - i));
    const key = d0.toISOString().slice(0, 10);
    const found = (d.actividad_semanal || []).find(x => x.dia === key);
    return { key, dow: dows[(d0.getDay() + 6) % 7], minutos: found ? found.minutos : 0 };
  });
  const max = Math.max(60, ...dias.map(x => x.minutos));
  $('[data-chart]', root).innerHTML = dias.map(x => `
    <div class="bar" data-dow="${x.dow}" style="height:${Math.max(6, Math.round(x.minutos / max * 100))}%"></div>
  `).join('');

  // Rendimiento por materia (barra por tema)
  const ul = $('[data-rendimiento]', root);
  ul.innerHTML = (d.rendimiento || []).slice(0, 6).map(r => `
    <li>
      <span class="ico-round">${r.icono || '📘'}</span>
      <div class="m-nombre">
        <strong>${r.nombre}</strong>
        <div class="progress"><div class="progress-bar"><span style="width:${r.porcentaje}%"></span></div></div>
      </div>
      <span class="m-pct">${r.porcentaje}%</span>
    </li>`).join('') || '<li class="muted">Aún no hay resultados. Completa algunos tests para ver este ranking.</li>';
}

// ═══════════════════════════════════════════════════════════════════════
// PERFIL
// ═══════════════════════════════════════════════════════════════════════

async function renderPerfil() {
  mount('tpl-perfil');
  const root = $('.view-perfil');
  bindCommon(root);
  const accesoAdministracion = $('[data-ir-administracion]', root);
  accesoAdministracion.hidden = !state.session?.es_admin;
  accesoAdministracion.addEventListener('click', () => { location.hash = '#/administracion'; });

  let d = null;
  try { d = await S.rpc('dashboard_perfil', {}, { api: '/api' }); }
  catch (e) { toast('Error cargando perfil'); return; }

  $('[data-nombre]', root).textContent = d.nombre;
  $('[data-email]', root).textContent = d.email + (d.email_verificado ? '' : ' (sin verificar)');
  $('[data-nivel]', root).textContent = 'Nivel ' + (d.nivel || 1);
  $('[data-racha]', root).textContent = (d.racha || 0) + ' días';
  $('[data-xp]', root).textContent = d.xp || 0;
  const opStats = await S.rpc('dashboard_inicio', {}, { api: '/api' });
  $('[data-pct]', root).textContent = (opStats.porcentaje || 0) + '%';

  // Objetivo
  if (d.oposicion_activa) {
    $('[data-obj-titulo]', root).textContent = d.oposicion_activa.nombre;
    if (d.plan && d.plan.fecha_examen) {
      const dias = Math.max(0, Math.round((new Date(d.plan.fecha_examen) - new Date()) / 86400000));
      $('[data-obj-desc]', root).textContent = 'Examen en ' + dias + ' días';
    } else {
      $('[data-obj-desc]', root).textContent = 'Sin fecha de examen — edítalo desde el Plan.';
    }
    $('[data-obj-fill]', root).style.width = (opStats.porcentaje || 0) + '%';
    $('[data-obj-pct]', root).textContent = opStats.porcentaje || 0;
  }

  // Logros
  const logros = d.logros || [];
  $('[data-logros]', root).innerHTML = logros.map(l => `
    <li class="${l.obtenido ? 'obtenido' : ''}" title="${l.titulo}">
      <span class="logro-ico">${l.icono}</span>
      <span>${l.titulo}</span>
    </li>`).join('') || '<li class="muted">Sin logros aún</li>';

  // Toggle tema
  const themeBtn = $('[data-toggle-theme]', root);
  const themeLbl = $('[data-theme-label]', root);
  const applyThemeLabel = () => {
    const t = document.documentElement.getAttribute('data-theme') || 'auto';
    themeLbl.textContent = t === 'dark' ? 'Oscuro' : t === 'light' ? 'Claro' : 'Automático';
  };
  applyThemeLabel();
  themeBtn.addEventListener('click', () => {
    const cur = document.documentElement.getAttribute('data-theme');
    const nxt = cur === 'dark' ? 'light' : 'dark';
    document.documentElement.setAttribute('data-theme', nxt);
    document.cookie = `aprentix_theme=${nxt};path=/;max-age=${60*60*24*365}`;
    applyThemeLabel();
  });

  // Logout
  $('[data-logout]', root).addEventListener('click', () => {
    S.clearToken();
    state.session = null; state.oposiciones = [];
    location.hash = '#/auth';
  });
}

// ═══════════════════════════════════════════════════════════════════════
// UNIDAD (teoría + test)
// ═══════════════════════════════════════════════════════════════════════

async function renderUnidad(r) {
  const uid = r.params?.id;
  if (!uid) { location.hash = '#/home'; return; }
  mount('tpl-unidad');
  const root = $('.view-unidad');
  $('[data-back]', root).addEventListener('click', () => history.back());

  let u = null;
  try { u = await S.rpc('obtener_unidad', { p_unidad_id: uid }, { api: '/api' }); }
  catch (e) { toast('Error cargando unidad'); return; }

  $('[data-unidad-nombre]', root).textContent = u.nombre;
  $('[data-unidad-min]', root).textContent = (u.minutos_est || 15) + ' min';

  // Render markdown MUY básico (sin dependencia externa).  Convertimos
  // ##, ###, listas y saltos.  Es suficiente para material corto; para
  // markdown complejo el import JSON puede traer HTML directamente en
  // teoria_md.
  $('[data-teoria]', root).innerHTML = mdBasic(u.teoria_md || '_(Sin contenido)_');

  $('[data-marcar-teoria]', root).addEventListener('click', async () => {
    try {
      await S.rpc('marcar_teoria', { p_unidad_id: uid, p_completada: true }, { api: '/api' });
      toast('¡Teoría marcada como estudiada!');
    } catch (e) { toast(e.message); }
  });

  // Tabs teoría / test
  const tabTeoria = $('.tab[data-tab="teoria"]', root);
  const tabTest   = $('.tab[data-tab="test"]', root);
  const pTeoria = $('[data-panel="teoria"]', root);
  const pTest   = $('[data-panel="test"]', root);
  function setTab(name) {
    tabTeoria.classList.toggle('active', name === 'teoria');
    tabTest.classList.toggle('active', name === 'test');
    pTeoria.hidden = name !== 'teoria';
    pTest.hidden   = name !== 'test';
  }
  tabTeoria.addEventListener('click', () => setTab('teoria'));
  tabTest.addEventListener('click', async () => {
    setTab('test');
    if (!pTest.dataset.loaded) await iniciarTest(uid, root);
  });
}

async function iniciarTest(uid, root) {
  const pTest = $('[data-panel="test"]', root);
  pTest.dataset.loaded = '1';
  let sesion = null;
  try { sesion = await S.rpc('iniciar_test_unidad', { p_unidad_id: uid, p_n: 10 }, { api: '/api' }); }
  catch (e) {
    pTest.innerHTML = `<p class="muted">${e.message.includes('sin_preguntas') ? 'Esta unidad todavía no tiene preguntas.' : e.message}</p>`;
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
      $('[data-test-resultado]', pTest).innerHTML = `<div>Nota: <strong>${nota}</strong> / 10</div>
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
    // Barajamos el orden de las opciones aunque el JSON traiga la
    // correcta siempre primera (evita que se sospeche del orden).
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
        else            { b.classList.add('incorrecta');
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

// Cache de dashboard_inicio para no lanzar 2 RPCs cuando plan pide "nivel"
let _sess = null;
async function sessionData() {
  if (_sess) return _sess;
  try {
    const d = await S.rpc('dashboard_inicio', {}, { api: '/api' });
    _sess = { nivel: d.nivel, racha: d.racha_dias };
  } catch (_) { _sess = { nivel: 1, racha: 0 }; }
  return _sess;
}

function fmtMin(min) {
  if (min < 60) return min + 'm';
  const h = Math.floor(min / 60), m = min % 60;
  return h + 'h ' + (m ? m + 'm' : '');
}

/** Markdown reducido: h1..h3, listas, negritas, párrafos.  */
function mdBasic(txt) {
  return txt
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/^### (.+)$/gm, '<h3>$1</h3>')
    .replace(/^## (.+)$/gm,  '<h2>$1</h2>')
    .replace(/^# (.+)$/gm,   '<h1>$1</h1>')
    .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/^\- (.+)$/gm, '<li>$1</li>')
    .replace(/(<li>.+<\/li>\n?)+/g, m => '<ul>' + m + '</ul>')
    .replace(/\n{2,}/g, '</p><p>')
    .replace(/^(?!<)(.+)$/gm, '$1')
    .replace(/^(.*)$/s, '<p>$1</p>');
}
