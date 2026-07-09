/**
 * Aprentix · configuración unificada.
 *
 * Renderiza el modal de configuración común a las tres apps (landing,
 * tests, teoría). Las secciones que no correspondan al usuario (por
 * permisos) aparecen visibles pero desactivadas — la configuración es
 * "de la persona", no de la app en la que está.
 *
 * Uso:
 *   AprentixConfig.init({ token: () => cookieAprentix, api: '/api' })
 *
 * Actualmente incluye:
 *   - Apariencia (tema): siempre.
 *   - Notificaciones (push): siempre (afecta a toda la app, no solo tests).
 *   - Tests: ritmo de repaso + reset. Sólo activo si el usuario tiene el
 *     permiso 'tests.acceder' (o roles equivalentes). Si no, se muestra
 *     desactivado con un mensaje.
 *   - Teoría: por ahora sin opciones específicas.
 *
 * El disparador es el botón #btn-config (fila "Configuración" del sheet
 * del avatar en tests/teoría, o el botón de la landing). Este módulo
 * inyecta el HTML del modal si no existe todavía.
 */
(function () {
  'use strict';

  const THEME_COOKIE = 'aprentix_theme';
  const RITMO_LABELS = {
    intensivo: { emoji: '🔥', nombre: 'Intensivo',
                 desc: 'Para semanas previas a examen. Verás preguntas nuevas varias veces el mismo día.' },
    normal:    { emoji: '🎯', nombre: 'Normal',
                 desc: 'Leitner clásico. Para aprendizaje continuo.' },
    relajado:  { emoji: '🌱', nombre: 'Relajado',
                 desc: 'Mantenimiento. Para no oxidarte cuando ya te sabes el temario.' },
  };

  // ── Utilidades ─────────────────────────────────────────────────────────
  function cookieDomain() {
    const parts = location.hostname.split('.');
    return parts.length >= 2 ? '.' + parts.slice(-2).join('.') : '';
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
  function esc(s) {
    return String(s ?? '').replace(/[&<>"']/g, c => (
      { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
    ));
  }
  function fmtHoras(h) {
    if (h < 24) return h + ' h';
    const d = Math.round(h / 24);
    if (d < 30) return d + ' d';
    const m = Math.round(d / 30);
    return m + ' mes' + (m > 1 ? 'es' : '');
  }

  function toast(msg, ms = 2600) {
    // Reutiliza el toast global del app si existe, si no crea uno propio.
    const existing = document.getElementById('toast');
    if (existing) {
      existing.textContent = msg;
      existing.classList.remove('hidden');
      clearTimeout(existing._t);
      existing._t = setTimeout(() => existing.classList.add('hidden'), ms);
      return;
    }
    const el = document.createElement('div');
    el.className = 'toast';
    el.textContent = msg;
    Object.assign(el.style, { position: 'fixed', bottom: '20px', left: '50%',
      transform: 'translateX(-50%)', zIndex: 9999 });
    document.body.appendChild(el);
    setTimeout(() => el.remove(), ms);
  }

  // ── Tema ───────────────────────────────────────────────────────────────
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
  function setThemePref(t) {
    setCookie(THEME_COOKIE, t, 365);
    applyTheme(t);
  }

  // ── Roles / permisos derivados del JWT ─────────────────────────────────
  function parseJwt(tok) {
    try {
      const b64 = tok.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
      const pad = b64.length % 4 ? b64 + '='.repeat(4 - (b64.length % 4)) : b64;
      return JSON.parse(atob(pad));
    } catch { return null; }
  }
  function permisos(token) {
    const claims = token ? parseJwt(token) : null;
    const roles = (claims && claims.roles) || [];
    const admin = roles.includes('admin');
    // Tests es "por defecto" para cualquier usuario logueado (no hay rol
    // "solo teoría" que excluya explícitamente). Teoría requiere rol.
    const tests  = !!token;
    const teoria = admin || roles.includes('teoria');
    return { admin, tests, teoria, token, roles };
  }

  // ── HTML del modal ─────────────────────────────────────────────────────
  // Cada grupo (Sistema, Tests) es un <details> plegable. Se abren al pulsar
  // el título — así en móvil el modal se ve compacto y el usuario decide qué
  // sección desplegar, en vez de ver todas las opciones a la vez.
  const CHEVRON = '<svg class="config-chevron" viewBox="0 0 24 24" fill="none" '
    + 'stroke="currentColor" stroke-width="2.5" stroke-linecap="round" '
    + 'stroke-linejoin="round" aria-hidden="true"><polyline points="6 9 12 15 18 9"/></svg>';
  const MODAL_HTML = `
<div id="aprentix-config-modal" class="modal hidden" role="dialog" aria-label="Configuración">
  <div class="modal-card">
    <header class="modal-header">
      <h3>Configuración</h3>
      <button class="btn btn-ghost btn-ghost-dark btn-sm" id="ap-cfg-close" aria-label="Cerrar">✕</button>
    </header>
    <div class="modal-body">

      <details class="config-group" id="ap-cfg-sistema-group">
        <summary class="config-group-title">
          <span class="config-group-label">Sistema</span>
          ${CHEVRON}
        </summary>
        <div class="config-group-body">
          <div class="config-section">
            <h5>Apariencia</h5>
            <div class="theme-toggle">
              <label class="theme-option"><input type="radio" name="ap-theme" value="light"><span>☀️ Claro</span></label>
              <label class="theme-option"><input type="radio" name="ap-theme" value="dark"><span>🌙 Oscuro</span></label>
              <label class="theme-option"><input type="radio" name="ap-theme" value="auto"><span>🖥️ Sistema</span></label>
            </div>
          </div>

          <div class="config-section" id="ap-cfg-push-wrap">
            <h5>Notificaciones</h5>
            <p class="muted small">
              Avisos de la aplicación en este dispositivo: repasos vencidos,
              días sin entrar, novedades, etc. Puedes desactivarlas cuando quieras.
            </p>
            <div class="push-actions">
              <button class="btn btn-pri" id="ap-cfg-push-on">🔔 Activar notificaciones</button>
              <button class="btn btn-ghost btn-ghost-dark hidden" id="ap-cfg-push-off">🔕 Desactivar</button>
            </div>
            <p class="muted small hidden" id="ap-cfg-push-status"></p>
          </div>
        </div>
      </details>

      <details class="config-group" id="ap-cfg-tests-group">
        <summary class="config-group-title">
          <span class="config-group-label">Tests</span>
          ${CHEVRON}
        </summary>
        <div class="config-group-body" id="ap-cfg-tests-body">
          <div class="config-section">
            <h5>Ritmo de repaso</h5>
            <p class="muted small">
              Elige la cadencia con la que quieres que se te repitan las preguntas.
              Solo afecta a los intervalos futuros; las fechas ya programadas no cambian.
            </p>
            <div id="ap-cfg-ritmo" class="ritmo-opciones"></div>
          </div>

          <div class="config-section danger-section">
            <h5>Resetear repaso</h5>
            <div class="reset-repasos">
              <div class="reset-repasos-copy">
                <strong>Empezar el repaso de cero</strong>
                <span class="muted small">
                  Borra las cajas Leitner de todas tus preguntas. No toca tus respuestas
                  ni tus intentos: solo se olvida en qué fase de repaso está cada pregunta.
                </span>
              </div>
              <button class="btn btn-danger-outline" id="ap-cfg-reset">Resetear mi repaso</button>
            </div>
          </div>
        </div>
        <p class="muted small hidden" id="ap-cfg-tests-locked">
          🔒 No tienes acceso a los tests. Pídele al administrador que te dé acceso
          para configurar el ritmo de repaso.
        </p>
      </details>

    </div>
  </div>
</div>

<div id="aprentix-reset-modal" class="modal hidden" role="dialog" aria-label="Confirmar reset">
  <div class="modal-card">
    <header class="modal-header"><h3>¿Resetear tu repaso?</h3></header>
    <div class="modal-body">
      <p>Se borrarán todas las cajas Leitner (aciertos, fallos y programación de repasos).
         Volverás a empezar como si nunca hubieras repasado nada.</p>
      <p class="muted small">
        Tus respuestas históricas, intentos y estadísticas se conservan intactos.
      </p>
      <div class="modal-actions">
        <button class="btn btn-ghost btn-ghost-dark" id="ap-cfg-reset-cancel">Cancelar</button>
        <button class="btn btn-danger" id="ap-cfg-reset-ok">Sí, resetear</button>
      </div>
    </div>
  </div>
</div>
`;

  // ── Push helpers ───────────────────────────────────────────────────────
  function pushSoportado() {
    return 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
  }
  function b64urlToBytes(s) {
    const pad = '='.repeat((4 - (s.length % 4)) % 4);
    const raw = atob((s + pad).replace(/-/g, '+').replace(/_/g, '/'));
    const out = new Uint8Array(raw.length);
    for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
    return out;
  }

  // ── Estado del módulo ──────────────────────────────────────────────────
  let CFG = {
    token: () => null,
    api: '/api',
  };

  async function rpc(name, body) {
    const tok = CFG.token();
    const r = await fetch(`${CFG.api}/rpc/${name}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(tok ? { 'Authorization': `Bearer ${tok}` } : {}),
      },
      body: JSON.stringify(body || {}),
    });
    if (r.status === 204) return null;
    const data = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(data.message || data.hint || `HTTP ${r.status}`);
    return data;
  }

  // ── Wiring ─────────────────────────────────────────────────────────────
  function ensureDom() {
    if (document.getElementById('aprentix-config-modal')) return;
    const host = document.createElement('div');
    host.id = 'aprentix-config-host';
    host.innerHTML = MODAL_HTML;
    document.body.appendChild(host);
    wire();
  }

  function wire() {
    const modal = document.getElementById('aprentix-config-modal');
    const resetModal = document.getElementById('aprentix-reset-modal');

    document.getElementById('ap-cfg-close').addEventListener('click', close);
    modal.addEventListener('click', (e) => { if (e.target === modal) close(); });

    document.querySelectorAll('input[name="ap-theme"]').forEach(r => {
      r.addEventListener('change', () => {
        setThemePref(r.value);
        toast(`Modo ${r.value === 'dark' ? 'oscuro' : r.value === 'light' ? 'claro' : 'automático'} activado`);
      });
    });

    document.getElementById('ap-cfg-ritmo').addEventListener('click', async (e) => {
      const card = e.target.closest('[data-ritmo]');
      if (!card) return;
      try {
        await rpc('set_ritmo_repaso', { p_ritmo: card.dataset.ritmo });
        toast(`Ritmo cambiado a ${RITMO_LABELS[card.dataset.ritmo].nombre}`);
        cargarRitmo();
      } catch (err) { toast(err.message); }
    });

    document.getElementById('ap-cfg-reset').addEventListener('click', () => {
      if (!CFG.token()) { toast('Inicia sesión primero'); return; }
      resetModal.classList.remove('hidden');
    });
    document.getElementById('ap-cfg-reset-cancel').addEventListener('click', () => {
      resetModal.classList.add('hidden');
    });
    document.getElementById('ap-cfg-reset-ok').addEventListener('click', async (e) => {
      const btn = e.currentTarget;
      btn.disabled = true;
      try {
        const r = await rpc('resetear_mis_repasos', { p_test_id: null });
        const n = r && typeof r.borradas === 'number' ? r.borradas : 0;
        toast(n === 0 ? 'No había repasos que borrar'
                      : `Repaso reseteado (${n} pregunta${n === 1 ? '' : 's'})`);
        resetModal.classList.add('hidden');
        close();
      } catch (err) { toast(err.message); }
      finally { btn.disabled = false; }
    });

    document.getElementById('ap-cfg-push-on').addEventListener('click', activarPush);
    document.getElementById('ap-cfg-push-off').addEventListener('click', desactivarPush);
  }

  // ── Ritmo ──────────────────────────────────────────────────────────────
  async function cargarRitmo() {
    const cont = document.getElementById('ap-cfg-ritmo');
    if (!cont) return;
    const tok = CFG.token();
    if (!tok) {
      cont.innerHTML = '<p class="muted small">Inicia sesión para configurar tu ritmo.</p>';
      return;
    }
    cont.innerHTML = '<p class="muted small">Cargando…</p>';
    try {
      const d = await rpc('mi_ritmo_repaso');
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
            <div class="curva">${esc(preview)}</div>
          </div>`;
      }).join('');
    } catch (e) {
      cont.innerHTML = `<p class="muted small">No se pudo cargar el ritmo: ${esc(e.message)}</p>`;
    }
  }

  // ── Push ───────────────────────────────────────────────────────────────
  async function refrescarPush() {
    const wrap   = document.getElementById('ap-cfg-push-wrap');
    const btnOn  = document.getElementById('ap-cfg-push-on');
    const btnOff = document.getElementById('ap-cfg-push-off');
    const status = document.getElementById('ap-cfg-push-status');
    if (!wrap) return;

    if (!pushSoportado()) {
      btnOn.disabled = true;
      btnOn.textContent = 'No disponible en este navegador';
      btnOff.classList.add('hidden');
      status.classList.remove('hidden');
      status.textContent = 'En iOS, instala primero la app (Compartir → Añadir a pantalla de inicio).';
      return;
    }
    const permiso = Notification.permission;
    let sub = null;
    // navigator.serviceWorker.ready puede quedarse pendiente para siempre
    // en scopes sin SW registrado (típicamente la landing). Ponemos una
    // carrera con timeout para no bloquear el modal.
    try {
      const timeout = new Promise(res => setTimeout(() => res(null), 1500));
      const reg = await Promise.race([navigator.serviceWorker.ready, timeout]);
      if (reg) sub = await reg.pushManager.getSubscription();
    } catch {}
    const activa = permiso === 'granted' && !!sub;
    btnOn.disabled = false;
    btnOn.classList.toggle('hidden', activa);
    btnOff.classList.toggle('hidden', !activa);
    status.classList.remove('hidden');
    if (permiso === 'denied') {
      status.textContent = 'Están bloqueadas en el navegador; cámbialo en el candado de la barra de direcciones.';
    } else if (activa) {
      status.textContent = 'Activas en este dispositivo.';
    } else {
      status.textContent = '';
      status.classList.add('hidden');
    }
  }
  async function activarPush() {
    if (!pushSoportado()) return toast('Este navegador no soporta notificaciones.');
    if (!CFG.token()) return toast('Inicia sesión primero.');
    try {
      const permiso = await Notification.requestPermission();
      if (permiso !== 'granted') return toast('Permiso denegado.');
      const timeout = new Promise((_, rej) => setTimeout(() => rej(new Error('sin_service_worker')), 3000));
      const reg = await Promise.race([navigator.serviceWorker.ready, timeout]);
      let sub = await reg.pushManager.getSubscription();
      if (!sub) {
        const cfg = await rpc('push_config_publica');
        if (!cfg?.vapid_public_key) throw new Error('Servidor sin clave VAPID.');
        sub = await reg.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: b64urlToBytes(cfg.vapid_public_key),
        });
      }
      const j = sub.toJSON();
      await rpc('guardar_push_suscripcion', {
        p_endpoint: j.endpoint,
        p_p256dh:   j.keys?.p256dh || '',
        p_auth:     j.keys?.auth   || '',
        p_ua:       navigator.userAgent,
        p_tz:       Intl.DateTimeFormat().resolvedOptions().timeZone || 'Europe/Madrid',
      });
      toast('🔔 Notificaciones activadas');
      refrescarPush();
    } catch (e) { toast('No se pudieron activar: ' + (e.message || e)); }
  }
  async function desactivarPush() {
    try {
      const reg = await navigator.serviceWorker.ready;
      const sub = await reg.pushManager.getSubscription();
      if (sub) {
        try { await rpc('borrar_push_suscripcion', { p_endpoint: sub.endpoint }); } catch {}
        await sub.unsubscribe();
      }
      toast('🔕 Notificaciones desactivadas');
      refrescarPush();
    } catch (e) { toast('No se pudieron desactivar: ' + (e.message || e)); }
  }

  // ── Apertura / cierre ──────────────────────────────────────────────────
  function open() {
    ensureDom();
    const t = currentTheme();
    document.querySelectorAll('input[name="ap-theme"]').forEach(r => {
      r.checked = (r.value === t);
    });
    // Bloquear sección de tests si no tiene acceso.
    const p = permisos(CFG.token());
    const tests = document.getElementById('ap-cfg-tests-body');
    const locked = document.getElementById('ap-cfg-tests-locked');
    if (p.tests) {
      tests.classList.remove('hidden');
      locked.classList.add('hidden');
      cargarRitmo();
    } else {
      tests.classList.add('hidden');
      locked.classList.remove('hidden');
    }
    refrescarPush();
    document.getElementById('aprentix-config-modal').classList.remove('hidden');
  }
  function close() {
    document.getElementById('aprentix-config-modal').classList.add('hidden');
  }

  // ── Init público ───────────────────────────────────────────────────────
  function init(opts) {
    CFG = Object.assign(CFG, opts || {});
    ensureDom();
    // Cablea todos los disparadores conocidos: fila del sheet (tests/teoría)
    // y botón de la landing. Idempotente.
    document.querySelectorAll(
      '#btn-config, [data-open-config]'
    ).forEach(b => {
      if (b._apConfigBound) return;
      b._apConfigBound = true;
      b.addEventListener('click', (e) => { e.preventDefault(); open(); });
    });
    applyTheme(currentTheme());
  }

  // Reacciona al cambio del sistema en modo "auto".
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
    if (currentTheme() === 'auto') applyTheme('auto');
  });

  window.AprentixConfig = { init, open, close, applyTheme, currentTheme };
})();
