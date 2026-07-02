/**
 * Aprentix — landing.
 *
 * Login / registro contra PostgREST y, tras autenticarse, escritura de la
 * cookie 'aprentix_token' en dominio .aprentix.es para que test.* y
 * teoria.* la lean sin volver a pedir credenciales. Tras el login se
 * muestra un chooser con dos tarjetas (tests y teoría), donde la de
 * teoría solo aparece si el usuario tiene el permiso 'teoria.acceder'.
 */
'use strict';

const COOKIE_NAME = 'aprentix_token';
const COOKIE_DAYS = 12 / 24; // 12 horas — coincide con la expiración del JWT.
const API = '/api';

// ── Cookie helpers ─────────────────────────────────────────────────────────

function cookieDomain() {
  // Devuelve '.aprentix.es' cuando estamos en aprentix.es o cualquier
  // subdominio; deja vacío para localhost/otros hosts (por si testeas en
  // local sin dominio).
  const h = location.hostname;
  const parts = h.split('.');
  if (parts.length >= 2) return '.' + parts.slice(-2).join('.');
  return '';
}

function setCookie(name, value, days) {
  const dom = cookieDomain();
  const attrs = [
    `Max-Age=${Math.round(days * 86400)}`,
    'Path=/',
    'SameSite=Lax',
    location.protocol === 'https:' ? 'Secure' : '',
    dom ? `Domain=${dom}` : '',
  ].filter(Boolean);
  document.cookie = `${name}=${encodeURIComponent(value)}; ${attrs.join('; ')}`;
}

function getCookie(name) {
  for (const raw of document.cookie.split(';')) {
    const [k, ...v] = raw.trim().split('=');
    if (k === name) return decodeURIComponent(v.join('='));
  }
  return null;
}

function deleteCookie(name) {
  const dom = cookieDomain();
  document.cookie = `${name}=; Max-Age=0; Path=/; ${dom ? 'Domain=' + dom : ''}`;
  document.cookie = `${name}=; Max-Age=0; Path=/`;
}

function parseJwt(tok) {
  try {
    const b64 = tok.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    return JSON.parse(atob(b64));
  } catch { return null; }
}

// ── PostgREST calls ────────────────────────────────────────────────────────

async function rpc(fn, body, token) {
  const r = await fetch(`${API}/rpc/${fn}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { 'Authorization': `Bearer ${token}` } : {}),
    },
    body: JSON.stringify(body || {}),
  });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) {
    // PostgREST devuelve {message, details, hint, code}
    const msg = data.message || data.hint || data.error || `HTTP ${r.status}`;
    throw new Error(msg);
  }
  return data;
}

// ── UI ─────────────────────────────────────────────────────────────────────

function showLogin() {
  document.getElementById('login').hidden = false;
  document.getElementById('chooser').hidden = true;
}

function showChooser(sesion, verTeoria) {
  document.getElementById('login').hidden = true;
  const chooser = document.getElementById('chooser');
  chooser.hidden = false;
  document.getElementById('who').textContent = sesion.username || '(sin nombre)';
  const tarjeta = document.getElementById('tarjeta-teoria');
  const bloq    = document.getElementById('tarjeta-teoria-bloqueada');
  if (verTeoria) { tarjeta.hidden = false; bloq.hidden = true; }
  else           { tarjeta.hidden = true;  bloq.hidden = false; }
}

function showError(id, msg) {
  const el = document.getElementById(id);
  el.textContent = msg;
  el.hidden = false;
  setTimeout(() => { el.hidden = true; }, 4500);
}

// ── Session lookup on load ─────────────────────────────────────────────────

async function comprobarSesion() {
  const tok = getCookie(COOKIE_NAME);
  if (!tok) return false;
  const claims = parseJwt(tok);
  if (!claims || (claims.exp && claims.exp * 1000 < Date.now())) {
    deleteCookie(COOKIE_NAME);
    return false;
  }
  try {
    const sesion = await rpc('mi_sesion', {}, tok);
    let verTeoria = false;
    try {
      verTeoria = await rpc('puede_ver_teoria', {}, tok);
    } catch { /* ignora, defaults false */ }
    showChooser({ username: sesion?.username || claims.sub }, !!verTeoria);
    return true;
  } catch {
    deleteCookie(COOKIE_NAME);
    return false;
  }
}

// ── Handlers ───────────────────────────────────────────────────────────────

document.getElementById('form-login').addEventListener('submit', async (e) => {
  e.preventDefault();
  const fd = new FormData(e.target);
  try {
    const r = await rpc('login_web', {
      p_username: fd.get('username'),
      p_password: fd.get('password'),
    });
    if (!r || !r.token) throw new Error('Respuesta sin token');
    setCookie(COOKIE_NAME, r.token, COOKIE_DAYS);
    // Si venimos redirigidos desde un subdominio, vuelve allí.
    const params = new URLSearchParams(location.search);
    const next = params.get('next');
    if (next) { location.href = next; return; }
    await comprobarSesion();
  } catch (err) {
    const raw = String(err.message || err);
    const humano = raw.includes('credenciales_invalidas')
      ? 'Usuario o contraseña incorrectos.'
      : raw;
    showError('login-error', humano);
  }
});

document.getElementById('form-registro').addEventListener('submit', async (e) => {
  e.preventDefault();
  const fd = new FormData(e.target);
  try {
    const r = await rpc('registrar_web', {
      p_username: fd.get('username'),
      p_password: fd.get('password'),
      p_email: fd.get('email') || null,
    });
    if (!r || !r.token) throw new Error('Respuesta sin token');
    setCookie(COOKIE_NAME, r.token, COOKIE_DAYS);
    await comprobarSesion();
  } catch (err) {
    showError('reg-error', String(err.message || err));
  }
});

document.getElementById('btn-logout').addEventListener('click', () => {
  deleteCookie(COOKIE_NAME);
  showLogin();
});

// ── Bootstrap ──────────────────────────────────────────────────────────────

comprobarSesion().then(ok => { if (!ok) showLogin(); });
