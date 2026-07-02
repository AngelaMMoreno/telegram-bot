/**
 * Aprentix — landing.
 *
 * Login / registro contra PostgREST y, tras autenticarse, escritura de la
 * cookie 'aprentix_token' en dominio .aprentix.es para que test.* y
 * teoria.* la lean sin volver a pedir credenciales. Tras el login se
 * muestra un chooser con dos tarjetas (tests y teoría), donde la de
 * teoría solo aparece si el usuario tiene el permiso 'teoria.acceder'.
 *
 * También ofrece un panel de configuración (apariencia, ritmo de repaso,
 * reset) accesible desde el avatar/nombre o el botón de configuración.
 */
'use strict';

const COOKIE_NAME = 'aprentix_token';
const COOKIE_DAYS = 12 / 24; // 12 horas — coincide con la expiración del JWT.
const THEME_COOKIE = 'aprentix_theme';
const API = '/api';

const RITMO_LABELS = {
  intensivo: { emoji: '🔥', nombre: 'Intensivo',
               desc: 'Para semanas previas a examen. Verás preguntas nuevas varias veces el mismo día.' },
  normal:    { emoji: '🎯', nombre: 'Normal',
               desc: 'Leitner clásico. Para aprendizaje continuo.' },
  relajado:  { emoji: '🌱', nombre: 'Relajado',
               desc: 'Mantenimiento. Para no oxidarte cuando ya te sabes el temario.' },
};

// ── Cookie helpers ─────────────────────────────────────────────────────────

function cookieDomain() {
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

// ── Theme (compartido en .aprentix.es via cookie de 365 días) ──────────────

function currentTheme() {
  const c = getCookie(THEME_COOKIE);
  if (c === 'dark' || c === 'light' || c === 'auto') return c;
  return 'auto';
}

function effectiveTheme(t) {
  if (t === 'auto') {
    return matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }
  return t;
}

function applyTheme(t) {
  const eff = effectiveTheme(t);
  document.documentElement.setAttribute('data-theme', eff);
}

function setTheme(t) {
  setCookie(THEME_COOKIE, t, 365);
  applyTheme(t);
}

// Reacciona al cambio del sistema cuando el modo es "auto".
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
  if (currentTheme() === 'auto') applyTheme('auto');
});

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
  const uname = sesion.username || '(sin nombre)';
  document.getElementById('who').textContent = uname;
  document.getElementById('user-avatar').textContent = (uname.trim()[0] || '?').toUpperCase();

  const tarjeta = document.getElementById('tarjeta-teoria');
  const bloq    = document.getElementById('tarjeta-teoria-bloqueada');
  // Usamos display para no depender del atributo `hidden`, que puede quedar
  // enmascarado por reglas CSS con display: flex/grid.
  if (verTeoria) {
    tarjeta.hidden = false; bloq.hidden = true;
    tarjeta.style.display = ''; bloq.style.display = 'none';
  } else {
    tarjeta.hidden = true; bloq.hidden = false;
    tarjeta.style.display = 'none'; bloq.style.display = '';
  }
}

function showError(id, msg) {
  const el = document.getElementById(id);
  el.textContent = msg;
  el.hidden = false;
  setTimeout(() => { el.hidden = true; }, 4500);
}

function toast(msg, ms = 2600) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.classList.remove('hidden');
  clearTimeout(t._t);
  t._t = setTimeout(() => t.classList.add('hidden'), ms);
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

// ── Config modal ───────────────────────────────────────────────────────────

const modalConfig = document.getElementById('modal-config');
const modalReset  = document.getElementById('modal-reset-repasos');

function abrirModalConfig() {
  // Marca el radio del tema actual.
  const t = currentTheme();
  document.querySelectorAll('input[name="theme"]').forEach(r => {
    r.checked = (r.value === t);
  });
  // Carga el ritmo actual si hay sesión.
  cargarRitmoOpciones();
  modalConfig.classList.remove('hidden');
}
function cerrarModalConfig() { modalConfig.classList.add('hidden'); }

document.getElementById('btn-config')?.addEventListener('click', abrirModalConfig);
document.getElementById('btn-user-menu')?.addEventListener('click', abrirModalConfig);
document.getElementById('modal-config-close')?.addEventListener('click', cerrarModalConfig);
modalConfig?.addEventListener('click', (e) => {
  if (e.target === modalConfig) cerrarModalConfig();
});

// Tema
document.querySelectorAll('input[name="theme"]').forEach(r => {
  r.addEventListener('change', () => {
    setTheme(r.value);
    toast(`Modo ${r.value === 'dark' ? 'oscuro' : r.value === 'light' ? 'claro' : 'automático'} activado`);
  });
});

// Ritmo
async function cargarRitmoOpciones() {
  const cont = document.getElementById('ritmo-opciones');
  const tok = getCookie(COOKIE_NAME);
  if (!tok) {
    cont.innerHTML = '<p class="muted small">Inicia sesión para configurar tu ritmo.</p>';
    return;
  }
  cont.innerHTML = '<p class="muted small">Cargando…</p>';
  try {
    const d = await rpc('mi_ritmo_repaso', {}, tok);
    const actual = d.ritmo || 'normal';
    const curvas = d.curvas || {};
    cont.innerHTML = ['intensivo', 'normal', 'relajado'].map(k => {
      const meta = RITMO_LABELS[k];
      const horas = curvas[k] || [];
      const preview = horas.map(fmtHoras).join(' → ');
      return `
        <div class="ritmo-card ${k===actual?'active':''}" data-ritmo="${k}">
          <div class="titulo">${meta.emoji} ${meta.nombre} ${k===actual?"<span class='muted small'>(actual)</span>":''}</div>
          <div class="muted small">${meta.desc}</div>
          <div class="curva">${preview}</div>
        </div>`;
    }).join('');
  } catch (e) {
    cont.innerHTML = `<p class="muted small">No se pudo cargar el ritmo: ${e.message}</p>`;
  }
}

function fmtHoras(h) {
  if (h < 24) return h + ' h';
  const d = Math.round(h / 24);
  if (d < 30) return d + ' d';
  const m = Math.round(d / 30);
  return m + ' mes' + (m > 1 ? 'es' : '');
}

document.getElementById('ritmo-opciones')?.addEventListener('click', async (e) => {
  const card = e.target.closest('[data-ritmo]');
  if (!card) return;
  const tok = getCookie(COOKIE_NAME);
  if (!tok) return;
  try {
    await rpc('set_ritmo_repaso', { p_ritmo: card.dataset.ritmo }, tok);
    toast(`Ritmo cambiado a ${RITMO_LABELS[card.dataset.ritmo].nombre}`);
    cargarRitmoOpciones();
  } catch (err) { toast(err.message); }
});

// Reset repasos
document.getElementById('btn-resetear-repasos')?.addEventListener('click', () => {
  const tok = getCookie(COOKIE_NAME);
  if (!tok) { toast('Inicia sesión primero'); return; }
  modalReset.classList.remove('hidden');
});
document.getElementById('btn-reset-cancelar')?.addEventListener('click', () => {
  modalReset.classList.add('hidden');
});
document.getElementById('btn-reset-confirmar')?.addEventListener('click', async (e) => {
  const btn = e.currentTarget;
  const tok = getCookie(COOKIE_NAME);
  if (!tok) return;
  btn.disabled = true;
  try {
    const r = await rpc('resetear_mis_repasos', { p_test_id: null }, tok);
    const n = r && typeof r.borradas === 'number' ? r.borradas : 0;
    toast(n === 0
      ? 'No había repasos que borrar'
      : `Repaso reseteado (${n} pregunta${n === 1 ? '' : 's'})`);
    modalReset.classList.add('hidden');
  } catch (err) {
    toast(err.message);
  } finally {
    btn.disabled = false;
  }
});

// ── Bootstrap ──────────────────────────────────────────────────────────────

applyTheme(currentTheme());
comprobarSesion().then(ok => { if (!ok) showLogin(); });
