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
  const puedeEditar = ESTADO.puede_gestionar && esMarkdown(f.nombre);
  m.innerHTML = `
    <div class="ctx-item" data-a="ver">📖 Abrir</div>
    ${puedeEditar ? `<div class="ctx-item" data-a="editar">✏️ Editar</div>` : ''}
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
    else if (a === 'editar') { await abrirMarkdown(f.ruta, f.nombre); mdEntrarEdicion(); }
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

const EXT_MARKDOWN = new Set(['md', 'markdown', 'txt']);

function esMarkdown(nombre) {
  return EXT_MARKDOWN.has((nombre.split('.').pop() || '').toLowerCase());
}

function verFichero(f) {
  // Los ficheros de texto (.md/.markdown/.txt) se abren dentro de la
  // plataforma con el visor/editor de markdown; el resto sigue yendo a
  // una pestaña nueva (PDFs, imágenes, etc.). El tick de "visto" lo
  // sigue poniendo el usuario a mano.
  if (esMarkdown(f.nombre)) {
    abrirMarkdown(f.ruta, f.nombre);
    return;
  }
  window.open('/api/ver?ruta=' + encodeURIComponent(f.ruta), '_blank', 'noopener');
}

// ── Visor / editor de markdown ─────────────────────────────────────────────
//
// El visor vive en #md-view. `MD.ruta` guarda la ruta del fichero abierto,
// `MD.original` el contenido guardado en disco (para saber si hay cambios),
// y `MD.creando` marca cuando estamos redactando un fichero nuevo (aún no
// existe en disco: al guardar hay que llamar a /api/crear_md, no /guardar).

const MD = { ruta: null, nombre: '', original: '', creando: false, padreCreacion: null };

if (window.marked && window.marked.setOptions) {
  marked.setOptions({ gfm: true, breaks: true });
}

function mdRender(texto) {
  const html = (window.marked && marked.parse) ? marked.parse(texto || '') : esc(texto || '');
  return (window.DOMPurify && DOMPurify.sanitize)
    ? DOMPurify.sanitize(html)
    : html;
}
function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));
}

const mdView   = () => document.getElementById('md-view');
const mdBody   = () => document.getElementById('md-body');
const mdEd     = () => document.getElementById('md-editor');
const mdOut    = () => document.getElementById('md-render');
const mdTitle  = () => document.getElementById('md-title');
const mdStatus = () => document.getElementById('md-status');

function mdEnEdicion() { return mdBody().classList.contains('editing'); }

function mdMostrarBotones() {
  const editable = ESTADO.puede_gestionar;
  const editing = mdEnEdicion();
  document.getElementById('md-editar').hidden        = editing || !editable;
  document.getElementById('md-guardar').hidden       = !editing;
  document.getElementById('md-cancelar').hidden      = !editing;
  document.getElementById('md-preview-toggle').hidden = !editing;
}

function mdMarcarEstado() {
  const dirty = mdEnEdicion() && mdEd().value !== MD.original;
  const el = mdStatus();
  el.classList.toggle('dirty', dirty);
  el.classList.toggle('saved', false);
  if (mdEnEdicion()) {
    el.hidden = false;
    el.textContent = dirty ? 'Sin guardar' : 'Guardado';
    if (!dirty) el.classList.add('saved');
  } else {
    el.hidden = true;
  }
}

function mdActualizarPreview() {
  mdOut().innerHTML = mdRender(mdEd().value);
  mdMarcarEstado();
}

function mdAbrirVista(nombre, contenido) {
  mdTitle().textContent = nombre;
  mdEd().value = contenido;
  mdOut().innerHTML = mdRender(contenido);
  mdBody().classList.remove('editing', 'show-preview', 'preview-only');
  mdView().classList.remove('hidden');
  mdView().setAttribute('aria-hidden', 'false');
  document.body.style.overflow = 'hidden';
  mdMostrarBotones();
  mdMarcarEstado();
}

function mdEntrarEdicion() {
  mdBody().classList.add('editing');
  mdBody().classList.remove('show-preview');
  mdMostrarBotones();
  mdActualizarPreview();
  mdEd().focus();
}

function mdCerrar() {
  if (mdEnEdicion() && mdEd().value !== MD.original) {
    if (!confirm('Tienes cambios sin guardar. ¿Descartarlos?')) return;
  }
  mdView().classList.add('hidden');
  mdView().setAttribute('aria-hidden', 'true');
  document.body.style.overflow = '';
  MD.ruta = null; MD.nombre = ''; MD.original = '';
  MD.creando = false; MD.padreCreacion = null;
}

async function abrirMarkdown(ruta, nombre) {
  try {
    const r = await api('GET', '/api/leer?ruta=' + encodeURIComponent(ruta));
    MD.ruta = r.ruta; MD.nombre = r.nombre;
    MD.original = r.contenido || '';
    MD.creando = false; MD.padreCreacion = null;
    mdAbrirVista(r.nombre, MD.original);
  } catch (e) {
    toast(`⚠️ ${e.message}`);
  }
}

function pedirNuevoMarkdown() {
  modal({
    titulo: 'Nuevo markdown',
    texto: `Dentro de ${ESTADO.ruta}`,
    campo: 'apuntes.md',
    aceptar: 'Crear',
    onOk: (nombre) => {
      if (!nombre) return;
      // No creamos el fichero todavía: lo escribes en el editor y se
      // guarda al pulsar "Guardar". Así puedes cancelar sin dejar un .md
      // vacío en disco.
      MD.creando = true;
      MD.padreCreacion = ESTADO.ruta;
      MD.ruta = null;
      MD.nombre = nombre.endsWith('.md') || nombre.endsWith('.markdown') || nombre.endsWith('.txt')
        ? nombre
        : nombre + '.md';
      const inicial = `# ${MD.nombre.replace(/\.(md|markdown|txt)$/i, '')}\n\n`;
      MD.original = '';
      mdAbrirVista(MD.nombre, inicial);
      mdEntrarEdicion();
    },
  });
}

async function mdGuardar() {
  const contenido = mdEd().value;
  try {
    if (MD.creando) {
      const r = await api('POST', '/api/crear_md', {
        padre: MD.padreCreacion,
        nombre: MD.nombre,
        contenido,
      });
      MD.ruta = r.ruta; MD.nombre = r.nombre;
      MD.creando = false; MD.padreCreacion = null;
      mdTitle().textContent = r.nombre;
      toast('Creado');
    } else {
      await api('POST', '/api/guardar', { ruta: MD.ruta, contenido });
      toast('Guardado');
    }
    MD.original = contenido;
    mdMarcarEstado();
    recargar();
  } catch (e) {
    toast(`⚠️ ${e.message}`);
  }
}

document.getElementById('md-back').addEventListener('click', mdCerrar);
document.getElementById('md-editar').addEventListener('click', mdEntrarEdicion);
document.getElementById('md-cancelar').addEventListener('click', () => {
  if (MD.creando) { mdCerrar(); return; }
  if (mdEd().value !== MD.original &&
      !confirm('Descartar los cambios sin guardar?')) return;
  mdEd().value = MD.original;
  mdBody().classList.remove('editing', 'show-preview');
  mdOut().innerHTML = mdRender(MD.original);
  mdMostrarBotones();
  mdMarcarEstado();
});
document.getElementById('md-guardar').addEventListener('click', mdGuardar);
document.getElementById('md-preview-toggle').addEventListener('click', () => {
  mdBody().classList.toggle('show-preview');
});
document.getElementById('md-editor').addEventListener('input', mdActualizarPreview);
document.addEventListener('keydown', (e) => {
  if (mdView().classList.contains('hidden')) return;
  if (e.key === 'Escape') { mdCerrar(); return; }
  // Ctrl/Cmd+S guarda cuando estás editando.
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's' && mdEnEdicion()) {
    e.preventDefault();
    mdGuardar();
  }
});

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
document.getElementById('btn-config-cerrar-x')?.addEventListener('click', cerrarModalConfig);
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

// Si el usuario cambia de sesión (logout / login con otra cuenta) en otra
// pestaña, la cookie compartida `aprentix_token` cambia bajo nuestros pies.
// El TOKEN que capturamos al arrancar quedó obsoleto: recargamos para volver
// a leerla y no seguir haciendo llamadas con el JWT del usuario anterior.
document.addEventListener('visibilitychange', () => {
  if (document.hidden) return;
  if (getCookie(COOKIE_NAME) !== TOKEN) location.reload();
});

window.addEventListener('hashchange', () => cargar(location.hash.slice(1) || '/'));

document.getElementById('btn-logout').addEventListener('click', () => {
  deleteCookie(COOKIE_NAME);
  location.href = LANDING_URL;
});
document.getElementById('btn-nueva-carpeta').addEventListener('click', pedirNuevaCarpeta);
document.getElementById('btn-nuevo-md').addEventListener('click', pedirNuevoMarkdown);
document.getElementById('file-input').addEventListener('change', (e) => {
  subirFicheros(e.target.files);
  e.target.value = '';
});
document.getElementById('grid').addEventListener('click', onGridAction);

// Rellena el chip de usuario (avatar + nombre). El JWT sólo trae el
// user_id en 'sub'; el username lo pide el backend a mi_sesion() y lo
// devuelve por /api/sesion, así mostramos el nombre real en la cabecera.
function pintarUsuario(nombre) {
  const uname = (nombre || '').trim() || 'sesión';
  const nameEl = document.getElementById('user-name');
  const avEl = document.getElementById('user-avatar');
  if (nameEl) nameEl.textContent = uname;
  if (avEl) avEl.textContent = (uname[0] || '?').toUpperCase();
}
pintarUsuario('…');
api('GET', '/api/sesion')
  .then(s => pintarUsuario(s && s.username))
  .catch(() => pintarUsuario(''));

cargar(ESTADO.ruta).catch(err => {
  document.getElementById('grid').innerHTML =
    `<div class="empty" style="grid-column:1/-1"><div class="empty-ico">⚠️</div><div>${err.message}</div></div>`;
});
