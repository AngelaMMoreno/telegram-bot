/**
 * Aprentix — landing.
 *
 * Login / registro contra PostgREST y, tras autenticarse, escritura de la
 * cookie 'aprentix_token' en dominio .aprentix.es para que test.* y
 * teoria.* la lean sin volver a pedir credenciales.
 *
 * Después del login la landing NO muestra un chooser: redirige
 * automáticamente al último modo elegido por el usuario (cookie
 * `aprentix_ultimo_modo`). Solo si es el primer inicio de sesión (sin
 * oposiciones asignadas todavía) se lanza el onboarding en el que el
 * usuario elige hasta 3 oposiciones; después se le lleva directamente a
 * la app de tests. El chooser explícito solo aparece si no se puede
 * decidir el modo (por ejemplo si el usuario aún no tiene ninguna
 * preferencia y accede desde una URL con `?next=/`).
 *
 * La configuración (tema, notificaciones, ritmo, reset) la gestiona
 * `shared/config.js` (window.AprentixConfig).
 */
'use strict';

// Sesión, cookies y RPC viven en shared/auth/session.js.
// Se carga como script clásico antes que este fichero, así que
// window.AprentixSession está garantizado aquí.
const {
  COOKIE_NAME,
  COOKIE_HORAS,
  getCookie, setCookie, deleteCookie,
  parseJwt,
} = window.AprentixSession;

const MODE_COOKIE  = 'aprentix_ultimo_modo';
const MODE_DAYS    = 365;
const API          = '/api';
const TESTS_URL    = '/tests/';
const TEORIA_URL   = '/teoria/';

// Wrapper local para no repetir { api: API } en cada call.  `token` es
// opcional: si se omite, la shared rpc() lee automáticamente la cookie.
const rpc = (fn, body, token) =>
  window.AprentixSession.rpc(fn, body, { api: API, token });

// setCookieDays: la shared usa horas; conservamos el helper por días para
// la cookie `aprentix_ultimo_modo` que dura 1 año.
const setCookieDays = (name, value, days) => setCookie(name, value, days * 24);

// ── UI helpers ─────────────────────────────────────────────────────────────

function mostrar(seccionId) {
  ['login', 'chooser', 'onboarding'].forEach(id => {
    const el = document.getElementById(id);
    if (el) el.hidden = id !== seccionId;
  });
}

function showError(id, msg) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = msg;
  el.hidden = false;
  setTimeout(() => { el.hidden = true; }, 4500);
}

function toast(msg, ms = 2600) {
  const t = document.getElementById('toast');
  if (!t) return;
  t.textContent = msg;
  t.classList.remove('hidden');
  clearTimeout(t._t);
  t._t = setTimeout(() => t.classList.add('hidden'), ms);
}

// ── Chooser (fallback) ─────────────────────────────────────────────────────

function pintarChooser(sesion, verTeoria) {
  mostrar('chooser');
  const uname = sesion.username || '(sin nombre)';
  document.getElementById('who').textContent = uname;
  document.getElementById('user-avatar').textContent = (uname.trim()[0] || '?').toUpperCase();

  const tarjeta = document.getElementById('tarjeta-teoria');
  const bloq    = document.getElementById('tarjeta-teoria-bloqueada');
  if (verTeoria) {
    tarjeta.hidden = false; bloq.hidden = true;
    tarjeta.style.display = ''; bloq.style.display = 'none';
  } else {
    tarjeta.hidden = true; bloq.hidden = false;
    tarjeta.style.display = 'none'; bloq.style.display = '';
  }
}

// ── Onboarding: primer login (elige hasta 3 oposiciones) ───────────────────

const ONBOARDING = { seleccion: new Set(), max: 3, esAdmin: false, todas: [] };

async function iniciarOnboarding(sesion, token) {
  mostrar('onboarding');
  const uname = sesion.username || '(sin nombre)';
  document.getElementById('onboarding-who').textContent = uname;
  document.getElementById('onboarding-avatar').textContent = (uname.trim()[0] || '?').toUpperCase();

  const lista = document.getElementById('onboarding-lista');
  lista.innerHTML = '<li class="muted">Cargando oposiciones…</li>';

  let ops = [];
  try { ops = await rpc('oposiciones_publicas', {}, token); }
  catch (e) {
    lista.innerHTML = `<li class="muted">No se pudieron cargar las oposiciones: ${e.message}</li>`;
    return;
  }
  ONBOARDING.todas = Array.isArray(ops) ? ops : [];
  ONBOARDING.seleccion = new Set();
  ONBOARDING.esAdmin = false;
  ONBOARDING.max = 3;

  if (!ONBOARDING.todas.length) {
    lista.innerHTML = `
      <li class="muted">
        Aún no hay oposiciones disponibles. Contacta con el administrador.
      </li>`;
    return;
  }
  lista.innerHTML = ONBOARDING.todas.map(o => `
    <li>
      <label class="check-item">
        <input type="checkbox" data-op-id="${o.id}">
        <span>
          <strong>${escapeHtml(o.nombre)}</strong>
          ${o.descripcion ? `<span class="muted small">${escapeHtml(o.descripcion)}</span>` : ''}
        </span>
      </label>
    </li>
  `).join('');
  actualizarContadorOnboarding();
}

function escapeHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));
}

function actualizarContadorOnboarding() {
  const cont = document.getElementById('onboarding-contador');
  const btn  = document.getElementById('onboarding-guardar');
  const n = ONBOARDING.seleccion.size;
  const max = ONBOARDING.esAdmin ? '∞' : String(ONBOARDING.max);
  cont.textContent = `${n} / ${max} seleccionada${n === 1 ? '' : 's'}`;
  btn.disabled = n === 0;
}

document.getElementById('onboarding-lista')?.addEventListener('change', (e) => {
  const cb = e.target.closest('input[type=checkbox][data-op-id]');
  if (!cb) return;
  const id = cb.dataset.opId;
  if (cb.checked) {
    if (!ONBOARDING.esAdmin && ONBOARDING.seleccion.size >= ONBOARDING.max) {
      cb.checked = false;
      toast(`Máximo ${ONBOARDING.max} oposiciones`);
      return;
    }
    ONBOARDING.seleccion.add(id);
  } else {
    ONBOARDING.seleccion.delete(id);
  }
  actualizarContadorOnboarding();
});

document.getElementById('onboarding-guardar')?.addEventListener('click', async () => {
  const btn = document.getElementById('onboarding-guardar');
  const tok = getCookie(COOKIE_NAME);
  if (!tok) return;
  btn.disabled = true;
  try {
    await rpc('elegir_mis_oposiciones', {
      p_oposicion_ids: [...ONBOARDING.seleccion],
    }, tok);
    toast('¡Listo! Empezamos con tus tests.');
    setCookieDays(MODE_COOKIE, 'tests', MODE_DAYS);
    location.href = TESTS_URL;
  } catch (e) {
    toast(e.message);
    btn.disabled = false;
  }
});

document.getElementById('onboarding-salir')?.addEventListener('click', () => {
  deleteCookie(COOKIE_NAME);
  mostrar('login');
});

// ── Session lookup on load ─────────────────────────────────────────────────

async function comprobarSesion() {
  const tok = getCookie(COOKIE_NAME);
  if (!tok) return false;
  const claims = parseJwt(tok);
  if (!claims || (claims.exp && claims.exp * 1000 < Date.now())) {
    deleteCookie(COOKIE_NAME);
    return false;
  }

  // Espera al parámetro ?next=<url> — si viene, respetamos el destino.
  const params = new URLSearchParams(location.search);
  const next = params.get('next');

  let sesion, verTeoria = false, misOps = [];
  try {
    sesion = await rpc('mi_sesion', {}, tok);
    try { verTeoria = await rpc('puede_ver_teoria', {}, tok); } catch {}
    try { misOps = await rpc('mis_oposiciones', {}, tok); } catch {}
  } catch {
    deleteCookie(COOKIE_NAME);
    return false;
  }

  const roles = (sesion?.roles || claims.roles || []);
  const esAdmin = roles.includes('admin');

  // Onboarding: primer login sin oposiciones (excepto admin).
  if (!esAdmin && Array.isArray(misOps) && misOps.length === 0) {
    await iniciarOnboarding({ username: sesion?.username || claims.sub }, tok);
    return true;
  }

  // Si viene un ?next= explícito, respétalo.
  if (next && (next.startsWith('/tests') || next.startsWith('/teoria'))) {
    setCookieDays(MODE_COOKIE, next.startsWith('/teoria') ? 'teoria' : 'tests', MODE_DAYS);
    location.href = next;
    return true;
  }

  // Redirige al último modo elegido si existe y es accesible.
  const ultimo = getCookie(MODE_COOKIE);
  if (ultimo === 'teoria' && verTeoria) {
    location.href = TEORIA_URL;
    return true;
  }
  if (ultimo === 'tests') {
    location.href = TESTS_URL;
    return true;
  }
  // Sin modo previo → tests por defecto (la app principal).
  if (!ultimo) {
    setCookieDays(MODE_COOKIE, 'tests', MODE_DAYS);
    location.href = TESTS_URL;
    return true;
  }

  // Fallback: chooser explícito.
  pintarChooser({ username: sesion?.username || claims.sub }, !!verTeoria);
  return true;
}

// ── Handlers de login/registro ─────────────────────────────────────────────
// Los eventos los emite <ap-auth-form> (shared/components/ap-auth-form.js).
// El componente ya se encarga de la UI (fortaleza, coincidencia, alternar
// paneles); aquí solo llamamos a la RPC correspondiente.

document.addEventListener('ap-auth-login', async (e) => {
  const { username, password } = e.detail;
  try {
    const r = await rpc('login_web', { p_username: username, p_password: password });
    if (!r || !r.token) throw new Error('Respuesta sin token');
    setCookie(COOKIE_NAME, r.token, COOKIE_HORAS);
    await comprobarSesion();
  } catch (err) {
    const raw = String(err.message || err);
    const humano = raw.includes('credenciales_invalidas')
      ? 'Usuario o contraseña incorrectos.'
      : raw;
    showError('login-error', humano);
  }
});

document.addEventListener('ap-auth-register', async (e) => {
  const { username, password, email } = e.detail;
  try {
    const r = await rpc('registrar_web', {
      p_username: username,
      p_password: password,
      p_email: email || null,
    });
    if (!r || !r.token) throw new Error('Respuesta sin token');
    setCookie(COOKIE_NAME, r.token, COOKIE_HORAS);
    // Registro nuevo → borra la cookie de "último modo" para forzar el
    // onboarding aunque venga de otro navegador con la cookie puesta.
    deleteCookie(MODE_COOKIE);
    await comprobarSesion();
  } catch (err) {
    showError('reg-error', String(err.message || err));
  }
});

document.getElementById('btn-logout').addEventListener('click', () => {
  deleteCookie(COOKIE_NAME);
  deleteCookie(MODE_COOKIE);
  mostrar('login');
});

// ── Bootstrap ──────────────────────────────────────────────────────────────

// Inicializa el módulo de configuración compartido (usable desde el
// chooser mientras siga visible).
if (window.AprentixConfig) {
  window.AprentixConfig.init({ token: () => getCookie(COOKIE_NAME), api: API });
} else {
  window.addEventListener('load', () => {
    window.AprentixConfig?.init({ token: () => getCookie(COOKIE_NAME), api: API });
  });
}

comprobarSesion().then(ok => { if (!ok) mostrar('login'); });
