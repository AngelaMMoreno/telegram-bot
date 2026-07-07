/**
 * Aprentix — SPA de teoría.
 *
 * Lee el JWT de la cookie compartida `aprentix_token` (.aprentix.es).
 * Si no hay sesión, manda al usuario a la landing.
 */
'use strict';

// La landing vive en el mismo origen (aprentix.es/) ahora que todo está
// unificado. Usar una ruta relativa evita romper el scope de la PWA.
const LANDING_URL = '/';
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

/* ── Notificaciones de logros (gamificación) ─────────────────────────
 * Idéntico contrato que en /tests/: `logros` es el array del backend
 * (marcar_visto RPC).  Pinta una tarjeta por logro con barra verde
 * animándose de 0 → 100%.  Se auto-descarta y se puede cerrar tocando.
 */
function notificarLogros(logros) {
  if (!Array.isArray(logros) || !logros.length) return;
  const stack = document.getElementById('logros-notif-stack');
  if (!stack) return;
  const escLite = s => String(s ?? '').replace(/[&<>"']/g, c => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));
  logros.forEach((l, i) => {
    const esReto = l.tipo === 'reto';
    const titular = esReto ? '¡Reto completado!' : '¡Logro desbloqueado!';
    const card = document.createElement('article');
    card.className = 'logro-notif' + (esReto ? ' es-reto' : '');
    card.setAttribute('role', 'status');
    card.innerHTML = `
      <div class="logro-notif-icono" aria-hidden="true">${escLite(l.icono || (esReto ? '🎯' : '🏆'))}</div>
      <div class="logro-notif-body">
        <div class="logro-notif-head">
          <strong>${titular}</strong>
          <span class="logro-notif-xp">+${Number(l.xp) || 0} XP</span>
        </div>
        <div class="logro-notif-desc"><strong>${escLite(l.titulo || '')}</strong>${
          l.descripcion ? ' · ' + escLite(l.descripcion) : ''
        }</div>
        <div class="logro-notif-bar" role="progressbar"
             aria-valuenow="${l.progreso || l.objetivo || 1}"
             aria-valuemin="0"
             aria-valuemax="${l.objetivo || 1}"><span></span></div>
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
    setTimeout(cerrar, 5000 + i * 400);
  });
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
// Marca desde el arranque si el usuario es admin, para que el sheet del
// avatar muestre "Panel de admin" sin esperar al primer listar(). El bit
// "puede-gestionar" seguirá refrescándose por ruta cuando llega listar().
if (CLAIMS && Array.isArray(CLAIMS.roles)) {
  const esAdmin = CLAIMS.roles.includes('admin');
  document.body.classList.toggle('es-admin', esAdmin);
  if (esAdmin) document.body.classList.add('puede-gestionar');
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

// `location.hash` devuelve el fragmento percent-encoded (p.ej. "/Mi%20Carpeta"),
// así que hay que decodificarlo antes de mandarlo a la API — si no, al llamar
// a `encodeURIComponent` en `cargar()` se codifica dos veces y el servidor
// busca literalmente una carpeta llamada "Mi%20Carpeta".
function rutaDeHash() {
  const raw = location.hash.slice(1);
  if (!raw) return '/';
  try { return decodeURIComponent(raw); } catch { return raw; }
}

let ESTADO = {
  ruta: rutaDeHash(),
  puede_gestionar: false,
  // Fase 5: oposición seleccionada actualmente (uuid | null = todas).
  // Se persiste en la misma clave que la app de tests para que la
  // decisión valga en ambas: aprentix.oposicion.<user_id>
  currentOposicion: null,
  currentOposicionNombre: null,
  misOposicionesCache: [],
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
  card.dataset.nombre = c.nombre;
  card.dataset.tipo = 'carpeta';
  // Compatibilidad: soporte multi-oposición nuevo y singular antiguo.
  const opIds = Array.isArray(c.oposicion_ids)
    ? c.oposicion_ids
    : (c.oposicion_id ? [c.oposicion_id] : []);
  const opNombres = Array.isArray(c.oposicion_nombres)
    ? c.oposicion_nombres
    : (c.oposicion_nombre ? [c.oposicion_nombre] : []);
  card.dataset.oposicionIds = opIds.join(',');
  card.dataset.oposicionNombres = opNombres.join('|');

  card.innerHTML = `
    <div class="card-check" hidden><input type="checkbox" data-accion="toggle-select" aria-label="Seleccionar carpeta"></div>
    <div class="card-emoji">📁</div>
    <div class="card-name" title="${esc(c.nombre)}">${esc(c.nombre)}</div>
    <div class="card-meta">${c.num_elementos} elemento${c.num_elementos === 1 ? '' : 's'}</div>
  `;
  card.addEventListener('click', (e) => {
    if (e.target.closest('[data-accion]')) return;
    if (SELECCION.activo) { toggleSeleccion(c.ruta, card); return; }
    navegar(c.ruta);
  });
  const itemCarpeta = { ruta: c.ruta, nombre: c.nombre, es_carpeta: true };
  card.addEventListener('contextmenu', (e) => {
    if (!ESTADO.puede_gestionar) return;
    e.preventDefault();
    menuContextualCarpeta(e, itemCarpeta, card);
  });
  attachLongPress(card, (ev) => {
    if (!ESTADO.puede_gestionar) return;
    menuContextualCarpeta(ev, itemCarpeta, card);
  });
  return card;
}

function tarjetaFichero(f) {
  const card = document.createElement('div');
  card.className = 'card file' + (f.visto ? ' visto' : '');
  card.dataset.ruta = f.ruta;
  card.dataset.nombre = f.nombre;
  card.dataset.tipo = 'fichero';
  const emoji = emojiParaFichero(f.nombre, f.mime);
  const tickTitle = f.visto ? 'Marcar como no visto' : 'Marcar como visto';
  card.innerHTML = `
    <div class="card-check" hidden><input type="checkbox" data-accion="toggle-select" aria-label="Seleccionar fichero"></div>
    <button class="visto-tick ${f.visto ? 'on' : 'off'}"
            data-accion="toggle-visto"
            title="${tickTitle}"
            aria-label="${tickTitle}"
            aria-pressed="${f.visto ? 'true' : 'false'}">
      <span class="visto-tick-check">${f.visto ? '✓' : ''}</span>
    </button>
    <div class="card-emoji">${emoji}</div>
    <div class="card-name" title="${esc(f.nombre)}">${esc(f.nombre)}</div>
    <div class="card-meta">${fmtSize(f.size)} · ${fmtDate(f.modificado)}</div>
  `;
  card.addEventListener('click', (e) => {
    if (e.target.closest('[data-accion]')) return;
    if (SELECCION.activo) { toggleSeleccion(f.ruta, card); return; }
    verFichero(f);
  });
  card.addEventListener('contextmenu', (e) => {
    e.preventDefault();
    menuContextualFichero(e, f, card);
  });
  attachLongPress(card, (ev) => {
    menuContextualFichero(ev, f, card);
  });
  return card;
}

/*
 * Long-press → menú contextual. En táctil no hay botón derecho; disparamos
 * el mismo menú cuando el usuario mantiene el dedo 500 ms sobre la tarjeta.
 * Se cancela si el dedo se mueve más de 10 px o se levanta antes.
 */
function attachLongPress(el, cb) {
  let timer = null;
  let startX = 0, startY = 0;
  let firedLong = false;
  const cancelar = () => {
    if (timer) { clearTimeout(timer); timer = null; }
  };
  el.addEventListener('touchstart', (e) => {
    if (e.touches.length !== 1) return;
    firedLong = false;
    const t = e.touches[0];
    startX = t.clientX; startY = t.clientY;
    cancelar();
    timer = setTimeout(() => {
      firedLong = true;
      cb({ clientX: startX, clientY: startY, preventDefault: () => {} });
    }, 500);
  }, { passive: true });
  el.addEventListener('touchmove', (e) => {
    if (!timer) return;
    const t = e.touches[0];
    if (Math.hypot(t.clientX - startX, t.clientY - startY) > 10) cancelar();
  }, { passive: true });
  el.addEventListener('touchend', cancelar, { passive: true });
  el.addEventListener('touchcancel', cancelar, { passive: true });
  // Si el long-press disparó, cancelamos el "click" fantasma posterior.
  el.addEventListener('click', (e) => {
    if (firedLong) { e.stopPropagation(); e.preventDefault(); firedLong = false; }
  }, true);
}

function menuContextualFichero(evt, f, card) {
  cerrarMenu();
  const m = document.createElement('div');
  m.className = 'ctx-menu';
  posicionarMenu(m, evt);
  const admin = ESTADO.puede_gestionar;
  const puedeEditar = admin && esMarkdown(f.nombre);
  m.innerHTML = `
    <div class="ctx-item" data-a="ver">📖 Abrir</div>
    <div class="ctx-item" data-a="descargar">⬇️ Descargar</div>
    <div class="ctx-sep"></div>
    <div class="ctx-item" data-a="${f.visto ? 'no-visto' : 'visto'}">
      ${f.visto ? '↩️ Marcar como no visto' : '✓ Marcar como visto'}
    </div>
    ${admin ? `
      <div class="ctx-sep"></div>
      <div class="ctx-item" data-a="seleccionar">☑️ Seleccionar</div>
      <div class="ctx-item" data-a="renombrar">✏️ Cambiar nombre</div>
      ${puedeEditar ? `<div class="ctx-item" data-a="editar">📝 Editar</div>` : ''}
      <div class="ctx-item" data-a="mover">📂 Mover</div>
      <div class="ctx-item danger" data-a="borrar">🗑️ Eliminar</div>
    ` : ''}
  `;
  document.body.appendChild(m);
  const item = { ruta: f.ruta, nombre: f.nombre, es_carpeta: false };
  m.addEventListener('click', async (e) => {
    const a = e.target.closest('.ctx-item')?.dataset.a;
    cerrarMenu();
    if (a === 'ver') verFichero(f);
    else if (a === 'editar') { await abrirMarkdown(f.ruta, f.nombre); mdEntrarEdicion(); }
    else if (a === 'descargar') window.open('api/ver?ruta=' + encodeURIComponent(f.ruta), '_blank');
    else if (a === 'visto') {
      const res = await api('POST', 'api/marcar_visto', { ruta: f.ruta });
      if (res && Array.isArray(res.logros_desbloqueados)) notificarLogros(res.logros_desbloqueados);
      recargar();
    }
    else if (a === 'no-visto') { await api('POST', 'api/marcar_no_visto', { ruta: f.ruta }); recargar(); }
    else if (a === 'seleccionar') { activarSeleccionDesdeMenu(f.ruta, card); }
    else if (a === 'renombrar') pedirRenombrar(item);
    else if (a === 'mover') abrirMoverDialogo([f.ruta]);
    else if (a === 'borrar') pedirBorrar(item);
  });
  setTimeout(() => document.addEventListener('click', cerrarMenu, { once: true }), 0);
}

function menuContextualCarpeta(evt, c, card) {
  cerrarMenu();
  if (!ESTADO.puede_gestionar) return;
  const m = document.createElement('div');
  m.className = 'ctx-menu';
  posicionarMenu(m, evt);
  m.innerHTML = `
    <div class="ctx-item" data-a="abrir">📁 Abrir</div>
    <div class="ctx-sep"></div>
    <div class="ctx-item" data-a="seleccionar">☑️ Seleccionar</div>
    <div class="ctx-item" data-a="renombrar">✏️ Cambiar nombre</div>
    <div class="ctx-item" data-a="mover">📂 Mover</div>
    <div class="ctx-item" data-a="oposicion">🎓 Asignar a oposición</div>
    <div class="ctx-item danger" data-a="borrar">🗑️ Eliminar</div>
  `;
  document.body.appendChild(m);
  m.addEventListener('click', async (e) => {
    const a = e.target.closest('.ctx-item')?.dataset.a;
    cerrarMenu();
    if (a === 'abrir') navegar(c.ruta);
    else if (a === 'seleccionar') activarSeleccionDesdeMenu(c.ruta, card);
    else if (a === 'renombrar') pedirRenombrar(c);
    else if (a === 'mover') abrirMoverDialogo([c.ruta]);
    else if (a === 'oposicion') abrirCarpetaOposicionPicker(c, card);
    else if (a === 'borrar') pedirBorrar(c);
  });
  setTimeout(() => document.addEventListener('click', cerrarMenu, { once: true }), 0);
}

/* Coloca el menú evitando salir del viewport. Se llama antes de append. */
function posicionarMenu(m, evt) {
  const x = evt.clientX ?? 0;
  const y = evt.clientY ?? 0;
  m.style.left = x + 'px';
  m.style.top = y + 'px';
  m.style.visibility = 'hidden';
  requestAnimationFrame(() => {
    const rect = m.getBoundingClientRect();
    const dx = Math.max(0, rect.right - window.innerWidth + 8);
    const dy = Math.max(0, rect.bottom - window.innerHeight + 8);
    if (dx) m.style.left = (x - dx) + 'px';
    if (dy) m.style.top = (y - dy) + 'px';
    m.style.visibility = '';
  });
}

/* Activa el modo selección y marca el elemento sobre el que se pulsó. */
function activarSeleccionDesdeMenu(ruta, card) {
  if (!SELECCION.activo) toggleModoSeleccion(true);
  toggleSeleccion(ruta, card, true);
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
  const accion = btn.dataset.accion;
  // Los checkboxes se dejan burbujear su change de forma controlada:
  // interceptamos y devolvemos sin stopPropagation para que el input
  // conserve su estado nativo. La lógica se dispara en toggleSeleccion.
  if (accion === 'toggle-select') {
    e.stopPropagation();
    const card = btn.closest('.card');
    toggleSeleccion(card.dataset.ruta, card, btn.checked);
    return;
  }
  if (accion === 'toggle-visto') {
    e.stopPropagation();
    e.preventDefault();
    const card = btn.closest('.card');
    const ruta = card.dataset.ruta;
    const item = { ruta, nombre: card.dataset.nombre || ruta.split('/').pop(), es_carpeta: false };
    toggleVistoInline(item, btn, card);
  }
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
    const res = await api('POST', `api/${rpc}`, { ruta: item.ruta });
    if (res && Array.isArray(res.logros_desbloqueados)) {
      notificarLogros(res.logros_desbloqueados);
    }
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
  const params = new URLSearchParams({ ruta });
  if (ESTADO.currentOposicion) params.set('oposicion_id', ESTADO.currentOposicion);
  const data = await api('GET', 'api/listar?' + params.toString());
  ESTADO.ruta = data.ruta;
  ESTADO.puede_gestionar = !!data.puede_gestionar;
  document.getElementById('admin-bar').hidden = !ESTADO.puede_gestionar;
  // Le decimos al chasis compartido si mostrar los slots "gestión" en el
  // sheet "Más". La regla en shared/header.css se apoya en estas clases.
  document.body.classList.toggle('puede-gestionar', ESTADO.puede_gestionar);
  document.title = `Aprentix — Teoría — ${data.ruta}`;
  renderBreadcrumb(data.breadcrumb, data.ruta);
  renderGrid(data);
  pintarHomeHeader();
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
  window.open('api/ver?ruta=' + encodeURIComponent(f.ruta), '_blank', 'noopener');
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
  // Editar vive dentro del menú kebab "Más" — solo si puedes editar y
  // no estás editando ya.
  document.getElementById('md-editar').hidden        = editing || !editable;
  document.getElementById('md-guardar').hidden       = !editing;
  document.getElementById('md-cancelar').hidden      = !editing;
  document.getElementById('md-preview-toggle').hidden = !editing;
  // El modo subrayar no tiene sentido mientras editas: si entras a
  // edición, lo apagamos.
  if (editing && SUBR.activo) toggleModoSubrayar();
  // El botón subrayar/marcador/buscar los ocultamos en edición: allí
  // no aportan y saturan el header.
  document.getElementById('md-subrayar').hidden = editing;
  document.getElementById('md-marcador').hidden = editing;
  document.getElementById('md-buscar').hidden   = editing;
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
  // Reengancha marcador y subrayados persistidos del usuario para este
  // documento. Búsqueda arranca cerrada.
  actualizarBotonMarcador();
  reaplicarSubrayados();
  cerrarBuscador();
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
  // Apaga modo subrayar y buscador al salir del documento.
  if (SUBR.activo) toggleModoSubrayar();
  cerrarBuscador();
  mdView().classList.add('hidden');
  mdView().setAttribute('aria-hidden', 'true');
  document.body.style.overflow = '';
  MD.ruta = null; MD.nombre = ''; MD.original = '';
  MD.creando = false; MD.padreCreacion = null;
}

async function abrirMarkdown(ruta, nombre) {
  try {
    const r = await api('GET', 'api/leer?ruta=' + encodeURIComponent(ruta));
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
      const r = await api('POST', 'api/crear_md', {
        padre: MD.padreCreacion,
        nombre: MD.nombre,
        contenido,
      });
      MD.ruta = r.ruta; MD.nombre = r.nombre;
      MD.creando = false; MD.padreCreacion = null;
      mdTitle().textContent = r.nombre;
      toast('Creado');
    } else {
      await api('POST', 'api/guardar', { ruta: MD.ruta, contenido });
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
  if (e.key === 'Escape') {
    // Esc primero cierra buscador si está abierto; luego cierra el visor.
    if (!document.getElementById('md-find').classList.contains('hidden')) {
      cerrarBuscador();
      return;
    }
    mdCerrar();
    return;
  }
  // Ctrl/Cmd+F abre buscador.
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'f' && !mdEnEdicion()) {
    e.preventDefault();
    abrirBuscadorDoc();
    return;
  }
  // Ctrl/Cmd+S guarda cuando estás editando.
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 's' && mdEnEdicion()) {
    e.preventDefault();
    mdGuardar();
  }
});

/* ── Buscar / marcadores / subrayado ──────────────────────────────────
 *
 * Persistencia local (Fase 5 lo llevará a BBDD): claves de localStorage
 *   aprentix.teoria.marcadores.<user_id>            → {ruta: {nombre, ts}}
 *   aprentix.teoria.subrayados.<user_id>.<ruta>     → [{start, end, texto}]
 *
 * <user_id> viene del claim `sub` del JWT. Así al cambiar de cuenta no
 * se cruzan marcadores/subrayados de usuarios distintos.
 */
const USER_ID = (CLAIMS && (CLAIMS.sub || CLAIMS.user_id)) || 'anon';
const K_MARC = `aprentix.teoria.marcadores.${USER_ID}`;
const K_SUBR = (ruta) => `aprentix.teoria.subrayados.${USER_ID}.${ruta}`;

function getMarcadores() {
  try { return JSON.parse(localStorage.getItem(K_MARC) || '{}') || {}; }
  catch { return {}; }
}
function setMarcadores(m) {
  try { localStorage.setItem(K_MARC, JSON.stringify(m)); } catch {}
}
function toggleMarcadorActual() {
  if (!MD.ruta) return;
  const m = getMarcadores();
  if (m[MD.ruta]) delete m[MD.ruta];
  else m[MD.ruta] = { nombre: MD.nombre || MD.ruta.split('/').pop(), ts: Date.now() };
  setMarcadores(m);
  actualizarBotonMarcador();
  toast(m[MD.ruta] ? 'Marcador añadido' : 'Marcador quitado');
}
function actualizarBotonMarcador() {
  const btn = document.getElementById('md-marcador');
  if (!btn) return;
  const m = getMarcadores();
  const activo = !!(MD.ruta && m[MD.ruta]);
  btn.classList.toggle('active', activo);
  btn.setAttribute('aria-pressed', activo ? 'true' : 'false');
  btn.title = activo ? 'Quitar marcador' : 'Marcar como favorito';
}

/* ── Búsqueda in-page ────────────────────────────────────────────────
 * Envuelve las coincidencias en <mark class="md-hit"> caminando los
 * text nodes de #md-render. No toca marcas del usuario (md-user-hl):
 * al re-envolver borramos SOLO nuestros marcadores de búsqueda. */
const BUSCA = { hits: [], idx: -1 };

function limpiarBusqueda() {
  const root = mdOut();
  root.querySelectorAll('mark.md-hit').forEach(m => {
    const parent = m.parentNode;
    while (m.firstChild) parent.insertBefore(m.firstChild, m);
    parent.removeChild(m);
    parent.normalize();
  });
  BUSCA.hits = []; BUSCA.idx = -1;
  document.getElementById('md-find-count').textContent = '0/0';
}

function aplicarBusqueda(q) {
  limpiarBusqueda();
  const query = (q || '').trim();
  const countEl = document.getElementById('md-find-count');
  if (!query) { countEl.textContent = '0/0'; return; }
  const root = mdOut();
  const qLow = query.toLowerCase();
  // Recolecta text nodes (excepto los que ya están dentro de una .md-hit,
  // aunque limpiarBusqueda las quita antes).
  const nodes = [];
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode: (n) => n.nodeValue && n.nodeValue.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT,
  });
  let n; while ((n = walker.nextNode())) nodes.push(n);
  for (const tn of nodes) {
    const txt = tn.nodeValue;
    const low = txt.toLowerCase();
    let i = 0, from = 0;
    const frag = document.createDocumentFragment();
    let hit = false;
    while ((i = low.indexOf(qLow, from)) !== -1) {
      hit = true;
      if (i > from) frag.appendChild(document.createTextNode(txt.slice(from, i)));
      const mark = document.createElement('mark');
      mark.className = 'md-hit';
      mark.textContent = txt.slice(i, i + query.length);
      frag.appendChild(mark);
      BUSCA.hits.push(mark);
      from = i + query.length;
    }
    if (hit) {
      if (from < txt.length) frag.appendChild(document.createTextNode(txt.slice(from)));
      tn.parentNode.replaceChild(frag, tn);
    }
  }
  if (BUSCA.hits.length) {
    BUSCA.idx = 0;
    subrayarActual();
  }
  countEl.textContent = `${BUSCA.hits.length ? BUSCA.idx + 1 : 0}/${BUSCA.hits.length}`;
}

function subrayarActual() {
  BUSCA.hits.forEach((h, i) => h.classList.toggle('current', i === BUSCA.idx));
  const el = BUSCA.hits[BUSCA.idx];
  if (el) el.scrollIntoView({ block: 'center', behavior: 'smooth' });
  document.getElementById('md-find-count').textContent =
    `${BUSCA.hits.length ? BUSCA.idx + 1 : 0}/${BUSCA.hits.length}`;
}

function saltoBusqueda(delta) {
  if (!BUSCA.hits.length) return;
  BUSCA.idx = (BUSCA.idx + delta + BUSCA.hits.length) % BUSCA.hits.length;
  subrayarActual();
}

function abrirBuscadorDoc() {
  const bar = document.getElementById('md-find');
  bar.classList.remove('hidden');
  const inp = document.getElementById('md-find-input');
  inp.focus();
  inp.select();
}
function cerrarBuscador() {
  document.getElementById('md-find').classList.add('hidden');
  limpiarBusqueda();
}

document.getElementById('md-buscar').addEventListener('click', abrirBuscadorDoc);
document.getElementById('md-find-cerrar').addEventListener('click', cerrarBuscador);
document.getElementById('md-find-input').addEventListener('input', (e) => {
  aplicarBusqueda(e.target.value);
});
document.getElementById('md-find-input').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') {
    e.preventDefault();
    saltoBusqueda(e.shiftKey ? -1 : 1);
  } else if (e.key === 'Escape') {
    e.preventDefault();
    cerrarBuscador();
  }
});
document.getElementById('md-find-prev').addEventListener('click', () => saltoBusqueda(-1));
document.getElementById('md-find-next').addEventListener('click', () => saltoBusqueda(1));

/* ── Subrayado del usuario ───────────────────────────────────────────
 * Guardamos offsets sobre el textContent completo del render. Al abrir
 * el documento re-aplicamos los subrayados envolviendo esos rangos.
 * Al pulsar sobre un subrayado existente, se elimina. */
const SUBR = { activo: false };

function getSubrayados(ruta) {
  try { return JSON.parse(localStorage.getItem(K_SUBR(ruta)) || '[]') || []; }
  catch { return []; }
}
function setSubrayados(ruta, arr) {
  try {
    if (arr.length) localStorage.setItem(K_SUBR(ruta), JSON.stringify(arr));
    else localStorage.removeItem(K_SUBR(ruta));
  } catch {}
}

function toggleModoSubrayar() {
  SUBR.activo = !SUBR.activo;
  const btn = document.getElementById('md-subrayar');
  btn.classList.toggle('active', SUBR.activo);
  btn.setAttribute('aria-pressed', SUBR.activo ? 'true' : 'false');
  mdBody().classList.toggle('hl-mode', SUBR.activo);
  toast(SUBR.activo
    ? 'Modo subrayado ON: selecciona texto para marcarlo'
    : 'Modo subrayado OFF');
}

// Mapa {textNode, offset} → offset absoluto dentro del textContent del render.
function offsetAbsoluto(root, node, offset) {
  let total = 0;
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  let n;
  while ((n = walker.nextNode())) {
    if (n === node) return total + offset;
    total += n.nodeValue.length;
  }
  return -1;
}

// Al revés: dado un offset absoluto, devuelve {node, offset} local.
function nodoEnOffset(root, target) {
  let acumulado = 0;
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  let n;
  while ((n = walker.nextNode())) {
    const len = n.nodeValue.length;
    if (acumulado + len >= target) {
      return { node: n, offset: target - acumulado };
    }
    acumulado += len;
  }
  return null;
}

function envolverRango(root, start, end) {
  const a = nodoEnOffset(root, start);
  const b = nodoEnOffset(root, end);
  if (!a || !b) return null;
  try {
    const range = document.createRange();
    range.setStart(a.node, a.offset);
    range.setEnd(b.node, b.offset);
    const mark = document.createElement('mark');
    mark.className = 'md-user-hl';
    mark.dataset.start = String(start);
    mark.dataset.end = String(end);
    // surroundContents falla si el rango cruza límites; en ese caso
    // extraemos contenido y lo insertamos dentro del mark.
    try {
      range.surroundContents(mark);
    } catch {
      const frag = range.extractContents();
      mark.appendChild(frag);
      range.insertNode(mark);
    }
    return mark;
  } catch { return null; }
}

function reaplicarSubrayados() {
  if (!MD.ruta) return;
  const root = mdOut();
  // Limpia los subrayados existentes en el DOM (los volvemos a envolver).
  root.querySelectorAll('mark.md-user-hl').forEach(m => {
    const parent = m.parentNode;
    while (m.firstChild) parent.insertBefore(m.firstChild, m);
    parent.removeChild(m);
    parent.normalize();
  });
  const items = getSubrayados(MD.ruta);
  // Aplica de mayor a menor offset para que los envoltorios anteriores
  // no muevan los offsets siguientes.
  [...items].sort((a, b) => b.start - a.start).forEach(it => {
    envolverRango(root, it.start, it.end);
  });
}

function guardarSeleccionActual() {
  const sel = window.getSelection();
  if (!sel || sel.isCollapsed) return;
  const root = mdOut();
  const range = sel.getRangeAt(0);
  if (!root.contains(range.commonAncestorContainer)) return;
  const start = offsetAbsoluto(root, range.startContainer, range.startOffset);
  const end   = offsetAbsoluto(root, range.endContainer, range.endOffset);
  if (start < 0 || end < 0 || start >= end) return;
  const texto = range.toString();
  if (!texto.trim()) return;
  sel.removeAllRanges();
  const arr = getSubrayados(MD.ruta);
  arr.push({ start, end, texto });
  setSubrayados(MD.ruta, arr);
  reaplicarSubrayados();
  toast('Subrayado guardado');
}

function borrarSubrayado(mark) {
  const start = Number(mark.dataset.start);
  const end   = Number(mark.dataset.end);
  const arr = getSubrayados(MD.ruta)
    .filter(it => !(it.start === start && it.end === end));
  setSubrayados(MD.ruta, arr);
  reaplicarSubrayados();
  toast('Subrayado quitado');
}

document.getElementById('md-subrayar').addEventListener('click', toggleModoSubrayar);
document.getElementById('md-marcador').addEventListener('click', toggleMarcadorActual);

// Captura selección de texto en el render solo si el modo está activo.
mdOut().addEventListener('mouseup', () => {
  if (SUBR.activo && !mdEnEdicion()) guardarSeleccionActual();
});
mdOut().addEventListener('touchend', () => {
  if (SUBR.activo && !mdEnEdicion()) setTimeout(guardarSeleccionActual, 10);
});

// Click sobre un subrayado existente → lo elimina.
mdOut().addEventListener('click', (e) => {
  const mark = e.target.closest('mark.md-user-hl');
  if (mark && !SUBR.activo) borrarSubrayado(mark);
});

/* ── Kebab "Más" del header del visor ────────────────────────────── */
document.getElementById('md-mas').addEventListener('click', (e) => {
  e.stopPropagation();
  const menu = document.getElementById('md-mas-menu');
  const btn = document.getElementById('md-mas');
  const open = menu.classList.toggle('hidden');
  btn.setAttribute('aria-expanded', open ? 'false' : 'true');
});
document.addEventListener('click', (e) => {
  const menu = document.getElementById('md-mas-menu');
  if (!menu || menu.classList.contains('hidden')) return;
  if (!e.target.closest('.md-mas-wrap')) {
    menu.classList.add('hidden');
    document.getElementById('md-mas').setAttribute('aria-expanded', 'false');
  }
});
document.getElementById('md-limpiar-subrayados').addEventListener('click', () => {
  if (!MD.ruta) return;
  if (!confirm('¿Quitar todos los subrayados de este documento?')) return;
  setSubrayados(MD.ruta, []);
  reaplicarSubrayados();
  document.getElementById('md-mas-menu').classList.add('hidden');
  toast('Subrayados limpios');
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
      await api('POST', 'api/mover', { origen: item.ruta, destino });
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
      await api('POST', 'api/borrar', { ruta: item.ruta });
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
      await api('POST', 'api/carpeta', { padre: ESTADO.ruta, nombre });
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
    const r = await api('POST', 'api/subir', fd, /* isForm */ true);
    toast(`${r.subidos.length} fichero${r.subidos.length === 1 ? '' : 's'} subido${r.subidos.length === 1 ? '' : 's'}`);
    recargar();
  } catch (e) { toast(`⚠️ ${e.message}`); }
}

// ── Configuración unificada (shared/config.js) ─────────────────────────────
// El modal (apariencia + notificaciones + ritmo + reset) es el mismo en
// landing, tests y teoría. Aquí solo delegamos al módulo compartido.
if (window.AprentixConfig) {
  window.AprentixConfig.init({ token: () => TOKEN, api: '/api' });
} else {
  window.addEventListener('load', () => {
    window.AprentixConfig?.init({ token: () => TOKEN, api: '/api' });
  });
}

// Guarda que el último modo elegido por el usuario es "teoria". La landing
// lo lee para redirigirle aquí directamente en la próxima visita.
(function guardarUltimoModo() {
  const host = location.hostname;
  const parent = host.split('.').slice(-2).join('.');
  const attrs = [
    'Max-Age=31536000', 'Path=/', 'SameSite=Lax',
    location.protocol === 'https:' ? 'Secure' : '',
    parent ? `Domain=.${parent}` : '',
  ].filter(Boolean);
  document.cookie = `aprentix_ultimo_modo=teoria; ${attrs.join('; ')}`;
})();

// ── Bootstrap ──────────────────────────────────────────────────────────────

// Si el usuario cambia de sesión (logout / login con otra cuenta) en otra
// pestaña, la cookie compartida `aprentix_token` cambia bajo nuestros pies.
// El TOKEN que capturamos al arrancar quedó obsoleto: recargamos para volver
// a leerla y no seguir haciendo llamadas con el JWT del usuario anterior.
document.addEventListener('visibilitychange', () => {
  if (document.hidden) return;
  if (getCookie(COOKIE_NAME) !== TOKEN) location.reload();
});

window.addEventListener('hashchange', () => cargar(rutaDeHash()));

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

/* ── Bottom-nav / sheet "Más" (aprentix:nav) ────────────────────────
 * <aprentix-header> emite CustomEvents con detail.id cuando el usuario
 * toca un item con "event":"…". Los mapeamos a acciones del app. */
document.addEventListener('aprentix:nav', (e) => {
  const id = e.detail && e.detail.id;
  switch (id) {
    case 'home':
      // Vuelve a la raíz de teoría.
      navegar('');
      break;
    case 'buscar':
      abrirBuscador();
      break;
    case 'marcadores':
      abrirMarcadores();
      break;
    case 'subir':
      document.getElementById('file-input')?.click();
      break;
    case 'nueva-carpeta':
      pedirNuevaCarpeta();
      break;
    case 'nuevo-md':
      pedirNuevoMarkdown();
      break;
  }
});

/* ── Buscador cliente-side sobre listar() de la ruta actual ─────────
 * En Fase 2 se sustituirá por un buscador global backed by API. Por
 * ahora, cargamos la ruta actual y filtramos por substring del nombre. */
async function abrirBuscador() {
  const modal = document.getElementById('teoria-buscar');
  const input = document.getElementById('teoria-buscar-input');
  const results = document.getElementById('teoria-buscar-results');
  if (!modal || !input || !results) return;
  modal.classList.remove('hidden');
  input.value = '';
  results.innerHTML = '<li class="muted small" style="padding:.5rem 0">Cargando…</li>';
  let entries = [];
  try {
    const p = new URLSearchParams({ ruta: ESTADO.ruta || '' });
    if (ESTADO.currentOposicion) p.set('oposicion_id', ESTADO.currentOposicion);
    const data = await api('GET', 'api/listar?' + p.toString());
    entries = (data.entries || data.items || []).map(e => ({
      nombre: e.nombre || e.name || '',
      es_carpeta: !!(e.es_carpeta || e.type === 'folder'),
      ruta: e.ruta || e.path || '',
    }));
  } catch (err) {
    results.innerHTML = `<li class="muted small">Error: ${err.message}</li>`;
    return;
  }
  const pintar = (q) => {
    const qq = (q || '').trim().toLowerCase();
    const filtered = qq
      ? entries.filter(e => e.nombre.toLowerCase().includes(qq))
      : entries;
    if (!filtered.length) {
      results.innerHTML = '<li class="muted small">Sin resultados</li>';
      return;
    }
    results.innerHTML = filtered.slice(0, 60).map(e => `
      <li>
        <button class="teoria-buscar-res" data-nombre="${e.nombre.replace(/"/g, '&quot;')}">
          <span aria-hidden="true">${e.es_carpeta ? '📁' : emojiParaFichero(e.nombre)}</span>
          <span class="teoria-buscar-nombre">${e.nombre}</span>
        </button>
      </li>
    `).join('');
  };
  pintar('');
  input.oninput = () => pintar(input.value);
  input.focus();
  results.onclick = (ev) => {
    const btn = ev.target.closest('.teoria-buscar-res');
    if (!btn) return;
    const nombre = btn.dataset.nombre;
    const entry = entries.find(e => e.nombre === nombre);
    if (!entry) return;
    modal.classList.add('hidden');
    // Navegar: si es carpeta, entra; si es fichero, abre.
    if (entry.es_carpeta) {
      const base = ESTADO.ruta ? ESTADO.ruta.replace(/\/$/, '') + '/' : '';
      navegar(base + entry.nombre);
    } else {
      // Los ficheros los abre el grid mediante onGridAction — dejamos que
      // el usuario los pulse allí tras navegar. Cerramos el buscador.
      const base = ESTADO.ruta ? ESTADO.ruta.replace(/\/$/, '') + '/' : '';
      navegar(base);
    }
  };
}
document.getElementById('teoria-buscar-cerrar')?.addEventListener('click', () => {
  document.getElementById('teoria-buscar')?.classList.add('hidden');
});
document.getElementById('teoria-buscar')?.addEventListener('click', (e) => {
  if (e.target.id === 'teoria-buscar') e.currentTarget.classList.add('hidden');
});
document.getElementById('teoria-marcadores-cerrar')?.addEventListener('click', () => {
  document.getElementById('teoria-marcadores')?.classList.add('hidden');
});
document.getElementById('teoria-marcadores')?.addEventListener('click', (e) => {
  if (e.target.id === 'teoria-marcadores') e.currentTarget.classList.add('hidden');
});

function abrirMarcadores() {
  const modal = document.getElementById('teoria-marcadores');
  const lista = document.getElementById('teoria-marcadores-lista');
  const vacio = document.getElementById('teoria-marcadores-vacio');
  if (!modal || !lista) return;
  const m = getMarcadores();
  const entries = Object.entries(m)
    .map(([ruta, meta]) => ({ ruta, nombre: meta.nombre || ruta.split('/').pop(), ts: meta.ts || 0 }))
    .sort((a, b) => b.ts - a.ts);
  if (!entries.length) {
    lista.innerHTML = '';
    if (vacio) vacio.hidden = false;
  } else {
    if (vacio) vacio.hidden = true;
    lista.innerHTML = entries.map(e => `
      <li>
        <button class="teoria-marc-item" data-ruta="${e.ruta.replace(/"/g, '&quot;')}">
          <span aria-hidden="true">${emojiParaFichero(e.nombre)}</span>
          <span class="teoria-marc-nombre">${e.nombre}</span>
          <span class="teoria-marc-ruta muted small">${e.ruta}</span>
        </button>
        <button class="md-icon teoria-marc-quitar" data-quitar="${e.ruta.replace(/"/g, '&quot;')}" aria-label="Quitar" title="Quitar marcador">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
        </button>
      </li>
    `).join('');
  }
  modal.classList.remove('hidden');
  lista.onclick = async (ev) => {
    const q = ev.target.closest('[data-quitar]');
    if (q) {
      ev.stopPropagation();
      const ruta = q.dataset.quitar;
      const cur = getMarcadores();
      delete cur[ruta];
      setMarcadores(cur);
      abrirMarcadores();  // repinta
      return;
    }
    const btn = ev.target.closest('[data-ruta]');
    if (!btn) return;
    const ruta = btn.dataset.ruta;
    modal.classList.add('hidden');
    // Abre el documento. Si falla (movido/borrado), avisamos.
    try {
      await abrirMarkdown(ruta, ruta.split('/').pop());
    } catch (e) {
      toast(`⚠️ ${e.message || 'No se pudo abrir'}`);
    }
  };
}

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
api('GET', 'api/sesion')
  .then(s => pintarUsuario(s && s.username))
  .catch(() => pintarUsuario(''));

cargar(ESTADO.ruta).catch(err => {
  document.getElementById('grid').innerHTML =
    `<div class="empty" style="grid-column:1/-1"><div class="empty-ico">⚠️</div><div>${err.message}</div></div>`;
});


/* ═════════════════════════════════════════════════════════════════════════
 *  Fase 5b: selector y asignación de oposiciones desde teoría
 *
 *  Comparte la clave de localStorage con tests (aprentix.oposicion.<user_id>)
 *  para que la elección valga en ambas apps sin duplicar UI ni almacenamiento.
 * ═════════════════════════════════════════════════════════════════════════ */

const OP_USER_ID = USER_ID;  // ya definido para marcadores/subrayados
const K_OP = OP_USER_ID ? `aprentix.oposicion.${OP_USER_ID}` : null;

function leerOposicionPersistida() {
  if (!K_OP) return null;
  try { const raw = localStorage.getItem(K_OP); return raw ? JSON.parse(raw) : null; }
  catch { return null; }
}
function guardarOposicionPersistida(op) {
  if (!K_OP) return;
  try {
    if (op) localStorage.setItem(K_OP, JSON.stringify({ id: op.id, nombre: op.nombre }));
    else    localStorage.removeItem(K_OP);
  } catch {}
}
function refrescarHintOposicion() {
  const el = document.getElementById('sheet-oposicion-actual');
  if (el) el.textContent = ESTADO.currentOposicionNombre || 'Todas';
  const chip = document.getElementById('ap-op-actual');
  if (chip) chip.textContent = ESTADO.currentOposicionNombre || 'Todas';
  const btnHome = document.getElementById('btn-cambiar-oposicion-home');
  const varias = (ESTADO.misOposicionesCache || []).length > 1;
  if (btnHome) btnHome.hidden = !varias;
}

/*
 * Cabecera de "Inicio" en teoría: saludo, oposición actual y tarjeta de
 * gamificación (mismo layout que en Tests). Solo se muestra cuando el
 * usuario está en la raíz de la biblioteca.
 */
async function pintarHomeHeader() {
  const box = document.getElementById('teoria-home-header');
  if (!box) return;
  const enRaiz = !ESTADO.ruta || ESTADO.ruta === '/' || ESTADO.ruta === '';
  if (!enRaiz) { box.hidden = true; return; }
  box.hidden = false;
  const helloEl = document.getElementById('teoria-hello-name');
  if (helloEl) {
    // El nombre real llega por api/sesion; pintarUsuario ya rellena
    // #user-name, así que lo espejamos.
    const uname = document.getElementById('user-name')?.textContent || '';
    helloEl.textContent = uname.trim() || '…';
  }
  refrescarHintOposicion();
  // Gamificación: llamada opcional, mostramos la tarjeta si el backend
  // responde. Si falla (usuario sin gamif o RPC no disponible), la
  // ocultamos con "hidden" para que no ocupe espacio.
  try {
    const g = await rpcPostgrest('mi_gamificacion', {});
    renderGamifCard('#teoria-home-gamif', g);
  } catch {
    const gCard = document.getElementById('teoria-home-gamif');
    if (gCard) gCard.innerHTML = '';
  }
}

function renderGamifCard(sel, g) {
  const box = document.querySelector(sel);
  if (!box) return;
  if (!g) { box.innerHTML = ''; return; }
  const rango = Math.max(1, (g.xp_siguiente || 0) - (g.xp_nivel_actual || 0));
  const pctNivel = Math.min(100, Math.round(100 * ((g.xp_total - g.xp_nivel_actual) / rango)));
  const rachaTxt = g.racha_actual > 0
    ? `🔥 <strong>${g.racha_actual}</strong> día${g.racha_actual === 1 ? '' : 's'} seguido${g.racha_actual === 1 ? '' : 's'}`
    : `😴 Sin racha — hoy es un buen día para empezar`;
  box.innerHTML = `
    <div class="gamif-head">
      <div class="gamif-level">
        <span class="gamif-nivel-num" title="Nivel">${g.nivel}</span>
        <div>
          <strong>Nivel ${g.nivel}</strong>
          <span class="muted small">${g.xp_total} / ${g.xp_siguiente} XP</span>
        </div>
      </div>
      <div class="gamif-racha">${rachaTxt}</div>
    </div>
    <div class="progress-bar level" role="progressbar"
         aria-valuenow="${pctNivel}" aria-valuemin="0" aria-valuemax="100">
      <span style="width:${pctNivel}%"></span>
    </div>
  `;
}

// PostgREST está expuesto en el mismo origen bajo /api/* (proxy del Caddy
// de la landing). Aquí replicamos el helper rpc() de tests para poder
// hablar con las RPCs de oposiciones desde teoría.
async function rpcPostgrest(nombre, payload) {
  const r = await fetch('/api/rpc/' + nombre, {
    method: 'POST',
    headers: {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${TOKEN}`,
    },
    body: JSON.stringify(payload || {}),
  });
  if (!r.ok) {
    let t = '';
    try { const j = await r.json(); t = j.message || j.hint || j.details || ''; }
    catch { try { t = await r.text(); } catch {} }
    throw new Error(t || `HTTP ${r.status}`);
  }
  if (r.status === 204) return null;
  const ct = r.headers.get('content-type') || '';
  return ct.includes('application/json') ? r.json() : r.text();
}

async function refrescarMisOposiciones() {
  try {
    const ops = await rpcPostgrest('mis_oposiciones', {});
    ESTADO.misOposicionesCache = Array.isArray(ops) ? ops : [];
    document.body.classList.toggle('has-oposiciones', ESTADO.misOposicionesCache.length > 1);

    const guardada = leerOposicionPersistida();
    if (guardada && ESTADO.misOposicionesCache.some(o => o.id === guardada.id)) {
      ESTADO.currentOposicion = guardada.id;
      ESTADO.currentOposicionNombre = guardada.nombre;
    } else if (ESTADO.misOposicionesCache.length === 1) {
      const o = ESTADO.misOposicionesCache[0];
      ESTADO.currentOposicion = o.id;
      ESTADO.currentOposicionNombre = o.nombre;
      guardarOposicionPersistida(o);
    } else if (ESTADO.misOposicionesCache.length > 1 && !ESTADO.currentOposicion) {
      abrirSelectorOposicion();
    }
    refrescarHintOposicion();
    // Al arranque la primera carga puede haber ocurrido antes de saber la
    // oposición: recargamos si la ruta actual es la raíz para aplicar el
    // filtro correcto. Fuera de la raíz no filtramos, así que no hace falta.
    if (ESTADO.ruta === '/' || !ESTADO.ruta) cargar('/').catch(() => {});
  } catch (e) {
    // Si el usuario aún no está en el sistema de oposiciones (BD vieja),
    // no rompemos nada.
    console.warn('[teoria] mis_oposiciones falló:', e.message);
  }
}

function abrirSelectorOposicion() {
  const modal = document.getElementById('teoria-elegir-oposicion');
  const lista = document.getElementById('teoria-op-list');
  if (!modal || !lista) return;
  const items = ESTADO.misOposicionesCache;
  lista.innerHTML = [
    `<li><button class="check-item" data-op-id=""><strong>Todas mis oposiciones</strong><span class="muted small">Ver todo lo global y de cualquier oposición asignada</span></button></li>`,
    ...items.map(o => `
      <li><button class="check-item" data-op-id="${o.id}">
        <strong>${esc(o.nombre)}</strong>
        ${o.descripcion ? `<span class="muted small">${esc(o.descripcion)}</span>` : ''}
      </button></li>`),
  ].join('');
  modal.classList.remove('hidden');
}
document.getElementById('teoria-op-cerrar')?.addEventListener('click', () => {
  document.getElementById('teoria-elegir-oposicion').classList.add('hidden');
});
document.getElementById('teoria-op-list')?.addEventListener('click', (e) => {
  const btn = e.target.closest('[data-op-id]');
  if (!btn) return;
  const id = btn.dataset.opId || null;
  const op = id ? ESTADO.misOposicionesCache.find(o => o.id === id) : null;
  ESTADO.currentOposicion = id;
  ESTADO.currentOposicionNombre = op ? op.nombre : null;
  guardarOposicionPersistida(op);
  refrescarHintOposicion();
  document.getElementById('teoria-elegir-oposicion').classList.add('hidden');
  // Recarga la carpeta actual con el nuevo filtro.
  cargar(ESTADO.ruta).catch(err => toast(err.message));
});

document.getElementById('btn-cambiar-oposicion')?.addEventListener('click', abrirSelectorOposicion);
document.getElementById('btn-cambiar-oposicion-home')?.addEventListener('click', abrirSelectorOposicion);

/* ── Picker MULTI-oposición para una carpeta (admin) ────────────────
 * Ahora una carpeta puede pertenecer a varias oposiciones a la vez.
 * El picker es multi-selección con checkboxes; al pulsar "Guardar" se
 * llama a set_carpeta_oposiciones(uuid[]).
 */
async function abrirCarpetaOposicionPicker(item, card) {
  const modal = document.getElementById('teoria-carpeta-oposicion');
  const lista = document.getElementById('teoria-carpeta-op-list');
  const tit   = document.getElementById('teoria-carpeta-op-titulo');
  const guardar = document.getElementById('teoria-carpeta-op-guardar');
  const cancelar = document.getElementById('teoria-carpeta-op-cancelar');
  if (!modal || !lista) return;
  const actualesRaw = (card?.dataset.oposicionIds || '').split(',').filter(Boolean);
  const actuales = new Set(actualesRaw);
  tit.textContent = `Oposiciones de ${item.nombre}`;
  try {
    const ops = await rpcPostgrest('mis_oposiciones', {});
    const items = Array.isArray(ops) ? ops : [];
    if (!items.length) {
      lista.innerHTML = `<li class="muted small" style="padding:.5rem 0">No hay oposiciones creadas todavía.</li>`;
    } else {
      lista.innerHTML = items.map(o => `
        <li><label class="check-item check-item-multi">
          <input type="checkbox" data-op-id="${o.id}" ${actuales.has(o.id) ? 'checked' : ''}>
          <span class="check-item-body">
            <strong>${esc(o.nombre)}</strong>
            ${o.descripcion ? `<span class="muted small">${esc(o.descripcion)}</span>` : ''}
          </span>
        </label></li>`).join('');
    }
    modal.classList.remove('hidden');

    const cerrar = () => modal.classList.add('hidden');
    cancelar.onclick = cerrar;
    guardar.onclick = async () => {
      const ids = Array.from(lista.querySelectorAll('input[type="checkbox"]:checked'))
        .map(el => el.dataset.opId);
      try {
        await rpcPostgrest('set_carpeta_oposiciones', {
          p_ruta: item.ruta,
          p_oposicion_ids: ids,
        });
        cerrar();
        toast(ids.length
          ? `Asignada${ids.length === 1 ? '' : 's'} a ${ids.length} oposicion${ids.length === 1 ? '' : 'es'}`
          : 'Carpeta puesta como global');
        recargar();
      } catch (e) { toast(e.message); }
    };
  } catch (e) { toast(e.message); }
}
document.getElementById('teoria-carpeta-op-cerrar')?.addEventListener('click', () => {
  document.getElementById('teoria-carpeta-oposicion').classList.add('hidden');
});

// Arranque: intenta cargar oposiciones tras el primer render.
refrescarMisOposiciones();


/* ═════════════════════════════════════════════════════════════════════════
 *  Modo selección múltiple + acciones por lote (Mover / Borrar)
 *
 *  Se activa desde el menú contextual "Seleccionar" sobre una tarjeta.
 *  Al entrar, aparecen checkboxes en cada tarjeta y la fila #seleccion-bar
 *  bajo la de subir/nueva carpeta/nuevo markdown. Los
 *  clics en tarjetas alternan la selección en vez de navegar/abrir.
 *  Solo disponible para gestores (admin).
 * ═════════════════════════════════════════════════════════════════════════ */

const SELECCION = { activo: false, rutas: new Set() };

function toggleModoSeleccion(forzar) {
  const nuevo = typeof forzar === 'boolean' ? forzar : !SELECCION.activo;
  SELECCION.activo = nuevo;
  document.body.classList.toggle('en-seleccion', nuevo);
  if (!nuevo) {
    // Limpiamos selección al salir.
    SELECCION.rutas.clear();
    document.querySelectorAll('.card.seleccionada').forEach(c => c.classList.remove('seleccionada'));
    document.querySelectorAll('.card-check input[type="checkbox"]').forEach(cb => { cb.checked = false; });
  }
  actualizarBarraSeleccion();
}

function toggleSeleccion(ruta, card, forzar) {
  if (!SELECCION.activo) return;
  const cb = card.querySelector('.card-check input[type="checkbox"]');
  let seleccionada;
  if (typeof forzar === 'boolean') seleccionada = forzar;
  else seleccionada = !SELECCION.rutas.has(ruta);
  if (seleccionada) SELECCION.rutas.add(ruta);
  else SELECCION.rutas.delete(ruta);
  card.classList.toggle('seleccionada', seleccionada);
  if (cb) cb.checked = seleccionada;
  actualizarBarraSeleccion();
}

function actualizarBarraSeleccion() {
  const bar = document.getElementById('seleccion-bar');
  const cnt = document.getElementById('seleccion-count');
  if (!bar) return;
  const n = SELECCION.rutas.size;
  // La fila de selección aparece en cuanto se entra al modo, aunque haya
  // 0 elementos. Así el usuario ve inmediatamente las acciones disponibles.
  bar.hidden = !SELECCION.activo;
  if (cnt) cnt.textContent = `${n} seleccionado${n === 1 ? '' : 's'}`;
}

document.getElementById('seleccion-cancelar')?.addEventListener('click', () => toggleModoSeleccion(false));
document.getElementById('seleccion-borrar')?.addEventListener('click', () => pedirBorrarLote());
document.getElementById('seleccion-mover')?.addEventListener('click', () => {
  if (!SELECCION.rutas.size) return;
  abrirMoverDialogo(Array.from(SELECCION.rutas));
});

function pedirBorrarLote() {
  const rutas = Array.from(SELECCION.rutas);
  if (!rutas.length) return;
  modal({
    titulo: `Borrar ${rutas.length} elemento${rutas.length === 1 ? '' : 's'}`,
    texto: `Se borrarán:\n${rutas.map(r => '• ' + r).join('\n')}\n\nEsta acción no se puede deshacer.`,
    aceptar: 'Borrar',
    peligro: true,
    onOk: async () => {
      try {
        const r = await api('POST', 'api/borrar_lote', { rutas });
        const n = (r.borrados || []).length;
        const errs = (r.errores || []).length;
        toast(errs
          ? `${n} borrado${n === 1 ? '' : 's'} · ${errs} con error`
          : `${n} borrado${n === 1 ? '' : 's'}`);
        toggleModoSeleccion(false);
        recargar();
      } catch (e) { toast(`⚠️ ${e.message}`); }
    },
  });
}

/* ── Diálogo "Mover a…" ─────────────────────────────────────────────── */

async function abrirMoverDialogo(rutas) {
  if (!rutas || !rutas.length) return;
  const modalEl = document.getElementById('teoria-mover-modal');
  const lista   = document.getElementById('teoria-mover-list');
  const tit     = document.getElementById('teoria-mover-titulo');
  const filtro  = document.getElementById('teoria-mover-filtro');
  const cancelar = document.getElementById('teoria-mover-cancelar');
  if (!modalEl || !lista) return;
  tit.textContent = rutas.length === 1
    ? `Mover «${rutas[0].split('/').pop()}» a…`
    : `Mover ${rutas.length} elementos a…`;
  lista.innerHTML = `<li class="muted small" style="padding:.5rem 0">Cargando…</li>`;
  modalEl.classList.remove('hidden');
  filtro.value = '';
  filtro.focus();

  let carpetas = [];
  try {
    const r = await api('GET', 'api/arbol_carpetas');
    carpetas = r.carpetas || [];
  } catch (e) {
    lista.innerHTML = `<li class="muted small">Error: ${esc(e.message)}</li>`;
    return;
  }

  // Excluye rutas que serían destinos inválidos:
  //   - la propia carpeta actual (padre) de cada origen
  //   - la carpeta origen y todo su subárbol (para no mover dentro de sí misma)
  const padresOrigen = new Set(rutas.map(r => {
    const parts = r.split('/').filter(Boolean);
    parts.pop();
    return '/' + parts.join('/');
  }).map(p => p === '/' ? '/' : p));
  const bloqueadas = (dst) => {
    for (const r of rutas) {
      if (dst === r) return true;
      if (r !== '/' && dst.startsWith(r + '/')) return true;
    }
    return false;
  };

  const pintar = (q) => {
    const qq = (q || '').trim().toLowerCase();
    const filtered = carpetas
      .filter(c => !bloqueadas(c))
      .filter(c => !qq || c.toLowerCase().includes(qq));
    if (!filtered.length) {
      lista.innerHTML = `<li class="muted small">No hay carpetas destino disponibles</li>`;
      return;
    }
    lista.innerHTML = filtered.map(c => {
      const label = c === '/' ? '🏠 Inicio (raíz)' : c;
      const marcado = padresOrigen.has(c) ? '<span class="muted small">(carpeta actual)</span>' : '';
      const disabled = padresOrigen.has(c) ? 'disabled' : '';
      return `<li><button class="check-item" data-destino="${esc(c)}" ${disabled}>
        <strong>${esc(label)}</strong>${marcado}
      </button></li>`;
    }).join('');
  };
  pintar('');
  filtro.oninput = () => pintar(filtro.value);

  const cerrar = () => modalEl.classList.add('hidden');
  cancelar.onclick = cerrar;
  document.getElementById('teoria-mover-cerrar').onclick = cerrar;

  lista.onclick = async (ev) => {
    const btn = ev.target.closest('[data-destino]');
    if (!btn || btn.disabled) return;
    const destino = btn.dataset.destino;
    try {
      const r = await api('POST', 'api/mover_lote', { rutas, destino });
      const n = (r.movidos || []).length;
      const errs = (r.errores || []).length;
      toast(errs
        ? `${n} movido${n === 1 ? '' : 's'} · ${errs} con error`
        : `${n} movido${n === 1 ? '' : 's'}`);
      cerrar();
      toggleModoSeleccion(false);
      recargar();
    } catch (e) { toast(`⚠️ ${e.message}`); }
  };
}
