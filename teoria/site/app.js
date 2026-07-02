/**
 * Aprentix — SPA de teoría.
 *
 * Lee el JWT de la cookie compartida `aprentix_token` (.aprentix.es).
 * Si no hay sesión, manda al usuario a la landing.
 */
'use strict';

const LANDING_URL = 'https://aprentix.es';
const COOKIE_NAME = 'aprentix_token';

// ── Utilidades ──────────────────────────────────────────────────────────────

function getCookie(name) {
  const parts = document.cookie.split(';');
  for (const raw of parts) {
    const [k, ...v] = raw.trim().split('=');
    if (k === name) return decodeURIComponent(v.join('='));
  }
  return null;
}

function deleteCookie(name) {
  // Borra en el subdominio (.aprentix.es) para que se propague al resto.
  const host = location.hostname;
  const parent = host.split('.').slice(-2).join('.');  // aprentix.es
  document.cookie = `${name}=; Max-Age=0; Path=/; Domain=.${parent}`;
  document.cookie = `${name}=; Max-Age=0; Path=/`;
}

function parseJwt(tok) {
  try {
    const payload = tok.split('.')[1];
    const b64 = payload.replace(/-/g, '+').replace(/_/g, '/');
    return JSON.parse(atob(b64));
  } catch { return null; }
}

function fmtSize(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024*1024) return `${(n/1024).toFixed(1)} KB`;
  if (n < 1024*1024*1024) return `${(n/1024/1024).toFixed(1)} MB`;
  return `${(n/1024/1024/1024).toFixed(1)} GB`;
}

function fmtDate(unix) {
  const d = new Date(unix * 1000);
  return d.toLocaleDateString('es-ES', { day: '2-digit', month: 'short', year: 'numeric' });
}

function emojiParaFichero(nombre, mime) {
  const ext = (nombre.split('.').pop() || '').toLowerCase();
  if (['pdf'].includes(ext)) return '📕';
  if (['doc','docx'].includes(ext)) return '📘';
  if (['xls','xlsx','csv'].includes(ext)) return '📗';
  if (['ppt','pptx'].includes(ext)) return '📙';
  if (['zip','rar','7z','tar','gz'].includes(ext)) return '🗜️';
  if (['png','jpg','jpeg','gif','webp','svg'].includes(ext)) return '🖼️';
  if (['mp4','mov','avi','webm','mkv'].includes(ext)) return '🎬';
  if (['mp3','wav','ogg','m4a','flac'].includes(ext)) return '🎧';
  if (['md','txt'].includes(ext)) return '📝';
  return '📄';
}

function toast(msg, ms = 2500) {
  const el = document.createElement('div');
  el.className = 'toast';
  el.textContent = msg;
  document.body.appendChild(el);
  setTimeout(() => el.remove(), ms);
}

// ── Auth ────────────────────────────────────────────────────────────────────

const TOKEN = getCookie(COOKIE_NAME);
if (!TOKEN) {
  location.href = LANDING_URL + '?next=' + encodeURIComponent(location.href);
}
const CLAIMS = TOKEN ? parseJwt(TOKEN) : null;
if (CLAIMS && (!CLAIMS.roles || (!CLAIMS.roles.includes('teoria') && !CLAIMS.roles.includes('admin')))) {
  location.href = LANDING_URL;
}

async function api(method, url, body, isForm = false) {
  const opts = {
    method,
    headers: { 'Authorization': `Bearer ${TOKEN}` },
  };
  if (body !== undefined) {
    if (isForm) {
      opts.body = body;  // FormData: el navegador pone el boundary
    } else {
      opts.headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(body);
    }
  }
  const r = await fetch(url, opts);
  if (r.status === 401) { deleteCookie(COOKIE_NAME); location.href = LANDING_URL; return; }
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.error || `HTTP ${r.status}`);
  return data;
}

// ── Estado ──────────────────────────────────────────────────────────────────

let ESTADO = {
  ruta: location.hash.slice(1) || '/',
  puede_gestionar: false,
};

// ── Render ──────────────────────────────────────────────────────────────────

function renderBreadcrumb(bc, ruta) {
  const el = document.getElementById('bc');
  el.innerHTML = '';
  bc.forEach((seg, i) => {
    if (i > 0) el.appendChild(Object.assign(document.createElement('span'), { className: 'bc-sep', textContent: '›' }));
    if (i === bc.length - 1) {
      el.appendChild(Object.assign(document.createElement('span'), { className: 'bc-current', textContent: i === 0 ? '🏠 Inicio' : seg.nombre }));
    } else {
      const a = document.createElement('a');
      a.href = '#' + seg.ruta;
      a.textContent = i === 0 ? '🏠 Inicio' : seg.nombre;
      el.appendChild(a);
    }
  });
}

function tarjetaCarpeta(c) {
  const card = document.createElement('div');
  card.className = 'card folder';
  card.dataset.ruta = c.ruta;
  card.dataset.tipo = 'carpeta';
  card.innerHTML = `
    <div class="card-emoji">📁</div>
    <div class="card-name" title="${c.nombre}">${c.nombre}</div>
    <div class="card-meta">${c.num_elementos} elemento${c.num_elementos === 1 ? '' : 's'}</div>
  `;
  if (ESTADO.puede_gestionar) {
    const actions = document.createElement('div');
    actions.className = 'card-actions';
    actions.innerHTML = `
      <button class="card-btn" data-accion="renombrar" title="Renombrar">✏️</button>
      <button class="card-btn del" data-accion="borrar" title="Borrar">🗑️</button>
    `;
    card.appendChild(actions);
  }
  card.addEventListener('click', (e) => {
    if (e.target.closest('.card-btn')) return;
    navegar(c.ruta);
  });
  return card;
}

function tarjetaFichero(f) {
  const card = document.createElement('div');
  card.className = 'card file' + (f.visto ? ' visto' : '');
  card.dataset.ruta = f.ruta;
  card.dataset.tipo = 'fichero';
  const emoji = emojiParaFichero(f.nombre, f.mime);
  const tickTitle = f.visto ? 'Marcar como no visto' : 'Marcar como visto';
  card.innerHTML = `
    <button class="visto-tick ${f.visto ? 'on' : 'off'}"
            data-accion="toggle-visto"
            title="${tickTitle}"
            aria-label="${tickTitle}"
            aria-pressed="${f.visto ? 'true' : 'false'}">
      <span class="visto-tick-check">${f.visto ? '✓' : ''}</span>
    </button>
    <div class="card-emoji">${emoji}</div>
    <div class="card-name" title="${f.nombre}">${f.nombre}</div>
    <div class="card-meta">${fmtSize(f.size)} · ${fmtDate(f.modificado)}</div>
  `;
  if (ESTADO.puede_gestionar) {
    const actions = document.createElement('div');
    actions.className = 'card-actions';
    actions.innerHTML = `
      <button class="card-btn" data-accion="renombrar" title="Renombrar">✏️</button>
      <button class="card-btn del" data-accion="borrar" title="Borrar">🗑️</button>
    `;
    card.appendChild(actions);
  }
  card.addEventListener('click', (e) => {
    if (e.target.closest('[data-accion]')) return;
    verFichero(f);
  });
  card.addEventListener('contextmenu', (e) => {
    e.preventDefault();
    menuContextualFichero(e, f);
  });
  return card;
}

function menuContextualFichero(evt, f) {
  cerrarMenu();
  const m = document.createElement('div');
  m.className = 'ctx-menu';
  m.style.left = evt.clientX + 'px';
  m.style.top = evt.clientY + 'px';
  m.innerHTML = `
    <div class="ctx-item" data-a="ver">📖 Abrir</div>
    <div class="ctx-item" data-a="descargar">⬇️ Descargar</div>
    <div class="ctx-sep"></div>
    <div class="ctx-item" data-a="${f.visto ? 'no-visto' : 'visto'}">
      ${f.visto ? '↩️ Marcar como no visto' : '✓ Marcar como visto'}
    </div>
    ${ESTADO.puede_gestionar ? `
      <div class="ctx-sep"></div>
      <div class="ctx-item" data-a="renombrar">✏️ Renombrar</div>
      <div class="ctx-item danger" data-a="borrar">🗑️ Borrar</div>
    ` : ''}
  `;
  document.body.appendChild(m);
  m.addEventListener('click', async (e) => {
    const a = e.target.closest('.ctx-item')?.dataset.a;
    cerrarMenu();
    if (a === 'ver') verFichero(f);
    else if (a === 'descargar') window.open('/api/ver?ruta=' + encodeURIComponent(f.ruta), '_blank');
    else if (a === 'visto') { await api('POST', '/api/marcar_visto', { ruta: f.ruta }); recargar(); }
    else if (a === 'no-visto') { await api('POST', '/api/marcar_no_visto', { ruta: f.ruta }); recargar(); }
    else if (a === 'renombrar') pedirRenombrar(f);
    else if (a === 'borrar') pedirBorrar(f);
  });
  setTimeout(() => document.addEventListener('click', cerrarMenu, { once: true }), 0);
}

function cerrarMenu() {
  document.querySelectorAll('.ctx-menu').forEach(n => n.remove());
}

function renderGrid(data) {
  const grid = document.getElementById('grid');
  grid.innerHTML = '';

  if (data.padre !== null && data.padre !== undefined) {
    const back = document.createElement('div');
    back.className = 'card folder';
    back.innerHTML = `
      <div class="card-emoji">⬆️</div>
      <div class="card-name">Volver</div>
      <div class="card-meta">${data.padre}</div>
    `;
    back.addEventListener('click', () => navegar(data.padre));
    grid.appendChild(back);
  }

  data.carpetas.forEach(c => grid.appendChild(tarjetaCarpeta(c)));
  data.ficheros.forEach(f => grid.appendChild(tarjetaFichero(f)));

  if (data.carpetas.length === 0 && data.ficheros.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'empty';
    empty.style.gridColumn = '1 / -1';
    empty.innerHTML = `<div class="empty-ico">📭</div><div>Carpeta vacía</div>`;
    grid.appendChild(empty);
  }
}

function onGridAction(e) {
  const btn = e.target.closest('[data-accion]');
  if (!btn) return;
  e.stopPropagation();
  e.preventDefault();
  const card = btn.closest('.card');
  const ruta = card.dataset.ruta;
  const tipo = card.dataset.tipo;
  const item = { ruta, nombre: ruta.split('/').pop(), es_carpeta: tipo === 'carpeta' };
  const accion = btn.dataset.accion;
  if (accion === 'renombrar') pedirRenombrar(item);
  else if (accion === 'borrar') pedirBorrar(item);
  else if (accion === 'toggle-visto') toggleVistoInline(item, btn, card);
}

async function toggleVistoInline(item, btn, card) {
  const estabaVisto = btn.classList.contains('on');
  const rpc = estabaVisto ? 'marcar_no_visto' : 'marcar_visto';
  // Actualización optimista para que el clic se sienta instantáneo.
  btn.classList.toggle('on',  !estabaVisto);
  btn.classList.toggle('off', estabaVisto);
  btn.setAttribute('aria-pressed', String(!estabaVisto));
  btn.title = estabaVisto ? 'Marcar como visto' : 'Marcar como no visto';
  btn.querySelector('.visto-tick-check').textContent = estabaVisto ? '' : '✓';
  card.classList.toggle('visto', !estabaVisto);
  try {
    await api('POST', `/api/${rpc}`, { ruta: item.ruta });
  } catch (err) {
    // Revierte si falla.
    btn.classList.toggle('on',  estabaVisto);
    btn.classList.toggle('off', !estabaVisto);
    btn.setAttribute('aria-pressed', String(estabaVisto));
    btn.querySelector('.visto-tick-check').textContent = estabaVisto ? '✓' : '';
    card.classList.toggle('visto', estabaVisto);
    toast(`⚠️ ${err.message}`);
  }
}

// ── Navegación ─────────────────────────────────────────────────────────────

async function cargar(ruta) {
  const data = await api('GET', '/api/listar?ruta=' + encodeURIComponent(ruta));
  ESTADO.ruta = data.ruta;
  ESTADO.puede_gestionar = !!data.puede_gestionar;
  document.getElementById('admin-bar').hidden = !ESTADO.puede_gestionar;
  document.title = `Aprentix — Teoría — ${data.ruta}`;
  renderBreadcrumb(data.breadcrumb, data.ruta);
  renderGrid(data);
}

function navegar(ruta) {
  location.hash = ruta;  // hashchange dispara la recarga
}

function recargar() { cargar(ESTADO.ruta); }

function verFichero(f) {
  // Solo abre; el tick de "visto" lo pone el usuario a mano.
  window.open('/api/ver?ruta=' + encodeURIComponent(f.ruta), '_blank', 'noopener');
}

// ── Acciones ───────────────────────────────────────────────────────────────

function modal({ titulo, texto, campo, aceptar = 'Aceptar', cancelar = 'Cancelar', peligro = false, onOk }) {
  // Clonar el host descarta los listeners de modales anteriores para no
  // dispararlos al cerrar/abrir en sucesión.
  const old = document.getElementById('modal-host');
  const host = old.cloneNode(false);
  host.id = 'modal-host';
  old.parentNode.replaceChild(host, old);
  host.innerHTML = `
    <div class="overlay">
      <div class="modal">
        <h3>${titulo}</h3>
        ${texto ? `<p>${texto}</p>` : ''}
        ${campo !== undefined ? `<input id="modal-input" type="text" value="${campo || ''}">` : ''}
        <div class="modal-actions">
          <button class="btn btn-cancel" data-a="cancel">${cancelar}</button>
          <button class="btn ${peligro ? 'btn-danger' : 'btn-pri'}" data-a="ok">${aceptar}</button>
        </div>
      </div>
    </div>`;
  const input = host.querySelector('#modal-input');
  if (input) { input.focus(); input.select(); }
  host.addEventListener('click', async (e) => {
    if (e.target.dataset.a === 'cancel' || e.target.classList.contains('overlay')) { host.innerHTML = ''; return; }
    if (e.target.dataset.a === 'ok') {
      try { await onOk(input ? input.value.trim() : null); host.innerHTML = ''; }
      catch (err) { toast(`⚠️ ${err.message}`); }
    }
  }, { once: false });
  if (input) input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter') host.querySelector('[data-a="ok"]').click();
    if (e.key === 'Escape') host.querySelector('[data-a="cancel"]').click();
  });
}

function pedirRenombrar(item) {
  modal({
    titulo: 'Renombrar',
    texto: item.ruta,
    campo: item.nombre || item.ruta.split('/').pop(),
    aceptar: 'Renombrar',
    onOk: async (nuevo) => {
      if (!nuevo || nuevo === item.nombre) return;
      const padre = item.ruta.split('/').slice(0, -1).join('/') || '/';
      const destino = (padre === '/' ? '' : padre) + '/' + nuevo;
      await api('POST', '/api/mover', { origen: item.ruta, destino });
      toast('Renombrado');
      recargar();
    },
  });
}

function pedirBorrar(item) {
  modal({
    titulo: `Borrar ${item.es_carpeta ? 'carpeta' : 'fichero'}`,
    texto: `¿Seguro que quieres borrar «${item.nombre || item.ruta}»? Esta acción no se puede deshacer.`,
    aceptar: 'Borrar',
    peligro: true,
    onOk: async () => {
      await api('POST', '/api/borrar', { ruta: item.ruta });
      toast('Borrado');
      recargar();
    },
  });
}

function pedirNuevaCarpeta() {
  modal({
    titulo: 'Nueva carpeta',
    texto: `Dentro de ${ESTADO.ruta}`,
    campo: '',
    aceptar: 'Crear',
    onOk: async (nombre) => {
      if (!nombre) return;
      await api('POST', '/api/carpeta', { padre: ESTADO.ruta, nombre });
      toast('Carpeta creada');
      recargar();
    },
  });
}

async function subirFicheros(files) {
  if (!files || files.length === 0) return;
  const fd = new FormData();
  fd.append('ruta', ESTADO.ruta);
  for (const f of files) fd.append('files', f, f.name);
  try {
    const r = await api('POST', '/api/subir', fd, /* isForm */ true);
    toast(`${r.subidos.length} fichero${r.subidos.length === 1 ? '' : 's'} subido${r.subidos.length === 1 ? '' : 's'}`);
    recargar();
  } catch (e) { toast(`⚠️ ${e.message}`); }
}

// ── Theme (compartido en .aprentix.es) ─────────────────────────────────────

const THEME_COOKIE = 'aprentix_theme';

function currentTheme() {
  const c = getCookie(THEME_COOKIE);
  if (c === 'dark' || c === 'light' || c === 'auto') return c;
  return 'auto';
}
function effectiveTheme(t) {
  if (t === 'auto') return matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  return t;
}
function applyTheme(t) {
  const eff = effectiveTheme(t);
  if (eff === 'dark') document.documentElement.setAttribute('data-theme', 'dark');
  else document.documentElement.removeAttribute('data-theme');
}
function setTheme(t) {
  // Cookie compartida con el resto de subdominios de aprentix.es
  const host = location.hostname;
  const parent = host.split('.').slice(-2).join('.');
  const attrs = [
    'Max-Age=31536000', 'Path=/', 'SameSite=Lax',
    location.protocol === 'https:' ? 'Secure' : '',
    parent ? `Domain=.${parent}` : '',
  ].filter(Boolean);
  document.cookie = `${THEME_COOKIE}=${t}; ${attrs.join('; ')}`;
  applyTheme(t);
}
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
  if (currentTheme() === 'auto') applyTheme('auto');
});
applyTheme(currentTheme());

// ── Config modal ───────────────────────────────────────────────────────────

const modalConfig = document.getElementById('modal-config');
function abrirModalConfig() {
  const t = currentTheme();
  document.querySelectorAll('input[name="theme"]').forEach(r => { r.checked = (r.value === t); });
  modalConfig.classList.remove('hidden');
}
function cerrarModalConfig() { modalConfig.classList.add('hidden'); }
document.getElementById('btn-config')?.addEventListener('click', abrirModalConfig);
document.getElementById('btn-user-menu')?.addEventListener('click', abrirModalConfig);
document.getElementById('btn-config-cerrar')?.addEventListener('click', cerrarModalConfig);
modalConfig?.addEventListener('click', (e) => {
  if (e.target === modalConfig) cerrarModalConfig();
});
document.querySelectorAll('input[name="theme"]').forEach(r => {
  r.addEventListener('change', () => {
    setTheme(r.value);
    toast(`Modo ${r.value === 'dark' ? 'oscuro' : r.value === 'light' ? 'claro' : 'automático'} activado`);
  });
});

// ── Bootstrap ──────────────────────────────────────────────────────────────

window.addEventListener('hashchange', () => cargar(location.hash.slice(1) || '/'));

document.getElementById('btn-logout').addEventListener('click', () => {
  deleteCookie(COOKIE_NAME);
  location.href = LANDING_URL;
});
document.getElementById('btn-nueva-carpeta').addEventListener('click', pedirNuevaCarpeta);
document.getElementById('file-input').addEventListener('change', (e) => {
  subirFicheros(e.target.files);
  e.target.value = '';
});
document.getElementById('grid').addEventListener('click', onGridAction);

// Rellena el chip de usuario (avatar + nombre).
if (CLAIMS) {
  const uname = CLAIMS.sub || CLAIMS.username || (CLAIMS.roles || []).join(', ') || 'sesión';
  const nameEl = document.getElementById('user-name-lbl');
  const avEl = document.getElementById('user-avatar');
  if (nameEl) nameEl.textContent = uname;
  if (avEl) avEl.textContent = (uname.trim()[0] || '?').toUpperCase();
}

cargar(ESTADO.ruta).catch(err => {
  document.getElementById('grid').innerHTML =
    `<div class="empty" style="grid-column:1/-1"><div class="empty-ico">⚠️</div><div>${err.message}</div></div>`;
});
