/*
 * Aprentix · cabecera compartida (rediseño 2026-07).
 *
 * Reescrita para el nuevo modelo. Diferencias clave respecto al legado:
 *   - Sin brand (ni logo ni "Aprentix"). El home ya no es un botón.
 *   - Sin tabs Tests/Teoría: la app es única (`/estudio/`).
 *   - Izquierda: <xp-ring> (nivel + progreso XP como circunferencia).
 *   - Centro:   <streak-flame> (fueguito con días de racha).
 *   - Derecha:  <user-chip> (avatar). Abre el sheet de cuenta.
 *   - Bottom-nav: Inicio · Estadísticas · Tablón.
 *   - Sheet del avatar: Cambiar oposición · Mi cuenta · Panel admin · Salir.
 *
 * `<aprentix-header active="estudio" nav-items='[…]'>` es el único tag
 * que la SPA usa. Al conectar dispara `_bootstrap()` que:
 *   1) Pinta el chasis en light DOM.
 *   2) Registra listeners (avatar → sheet, sheet → callbacks, bottom-nav).
 *   3) Rellena XP/racha desde `AprentixSession.rpc('mi_gamificacion')`.
 *
 * La SPA escucha `aprentix:nav` (CustomEvent con detail.id) para navegar.
 */
'use strict';

(function () {
  if (customElements.get('aprentix-header')) return;

  const S = window.AprentixSession;

  const ICONS = {
    home:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12l9-9 9 9"/><path d="M5 10v10a1 1 0 0 0 1 1h4v-6h4v6h4a1 1 0 0 0 1-1V10"/></svg>',
    calendar:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="5" width="18" height="16" rx="2"/><line x1="16" y1="3" x2="16" y2="7"/><line x1="8" y1="3" x2="8" y2="7"/><line x1="3" y1="10" x2="21" y2="10"/><path d="M8 14h.01M12 14h.01M16 14h.01M8 18h.01M12 18h.01"/></svg>',
    chart:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="4" y1="20" x2="20" y2="20"/><rect x="6" y="10" width="3" height="10"/><rect x="11" y="6" width="3" height="14"/><rect x="16" y="13" width="3" height="7"/></svg>',
    bookmark:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3h12a1 1 0 0 1 1 1v18l-7-4-7 4V4a1 1 0 0 1 1-1z"/></svg>',
    gear:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33h.01a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82v.01a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>',
    logout: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" y1="12" x2="9" y2="12"/></svg>',
    folder: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>',
    user:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>',
    shield: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2L4 5v7c0 5 3.5 8.5 8 10 4.5-1.5 8-5 8-10V5l-8-3z"/></svg>',
    trophy: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M8 21h8"/><path d="M12 17v4"/><path d="M7 4h10v5a5 5 0 0 1-10 0V4z"/><path d="M17 5h3a2 2 0 0 1 0 4h-3"/><path d="M7 5H4a2 2 0 0 0 0 4h3"/></svg>',
  };
  const icon = (n) => ICONS[n] || ICONS.user;
  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, c =>
    ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

  const parseJson = (raw) => {
    if (!raw) return [];
    try { return JSON.parse(raw) || []; } catch { return []; }
  };


  // ── <xp-ring level xp xp-nivel-ini xp-nivel-sig> ────────────────────
  // Círculo SVG cuyo borde se rellena con la fracción de XP dentro del
  // nivel actual. Muestra el nivel como número en el centro.
  class XpRing extends HTMLElement {
    static get observedAttributes() { return ['level','xp','xp-nivel-ini','xp-nivel-sig']; }
    connectedCallback() { this.render(); }
    attributeChangedCallback() { this.render(); }
    render() {
      const nivel = +(this.getAttribute('level') || 1);
      const xp    = +(this.getAttribute('xp')    || 0);
      const ini   = +(this.getAttribute('xp-nivel-ini') || 0);
      const sig   = +(this.getAttribute('xp-nivel-sig') || Math.max(50, ini + 50));
      const denom = Math.max(1, sig - ini);
      const frac  = Math.min(1, Math.max(0, (xp - ini) / denom));
      const R = 18, C = 2 * Math.PI * R;
      const off = C * (1 - frac);
      this.innerHTML = `
        <svg viewBox="0 0 44 44" width="40" height="40" aria-label="Nivel ${nivel}">
          <circle cx="22" cy="22" r="${R}" fill="none"
                  stroke="var(--xp-track, rgba(0,0,0,.12))" stroke-width="4"/>
          <circle cx="22" cy="22" r="${R}" fill="none"
                  stroke="var(--xp-fill, #6B8E23)" stroke-width="4"
                  stroke-linecap="round"
                  stroke-dasharray="${C}" stroke-dashoffset="${off}"
                  transform="rotate(-90 22 22)"
                  style="transition: stroke-dashoffset .4s ease"/>
          <text x="22" y="26" text-anchor="middle"
                font-size="13" font-weight="700"
                fill="var(--txt, currentColor)">${nivel}</text>
        </svg>`;
    }
  }
  if (!customElements.get('xp-ring')) customElements.define('xp-ring', XpRing);


  // ── <streak-flame days> ────────────────────────────────────────────
  // Fuego + contador. Se apaga (gris) si days=0.
  class StreakFlame extends HTMLElement {
    static get observedAttributes() { return ['days']; }
    connectedCallback() { this.render(); }
    attributeChangedCallback() { this.render(); }
    render() {
      const d = +(this.getAttribute('days') || 0);
      const on = d > 0;
      this.innerHTML = `
        <span class="flame ${on ? 'on' : 'off'}" title="${on ? d+' días de racha' : 'Sin racha activa'}">
          <span class="flame-emoji" aria-hidden="true">🔥</span>
          <strong class="flame-days" aria-label="${on ? d+' días de racha' : 'Sin racha'}">${d}</strong>
        </span>`;
    }
  }
  if (!customElements.get('streak-flame')) customElements.define('streak-flame', StreakFlame);


  // ── <aprentix-header> ──────────────────────────────────────────────
  class AprentixHeader extends HTMLElement {
    connectedCallback() {
      const navItems = parseJson(this.getAttribute('nav-items'));
      const activeKey = this.getAttribute('active-key') || 'home';

      this.innerHTML = `
        <header class="topbar" id="topbar">
          <div class="hdr-stats">
            <button type="button" class="hdr-chip level-chip"
                    id="btn-level-chip"
                    aria-label="Nivel y experiencia — ver logros y retos"
                    title="Ver logros y retos">
              <xp-ring level="1" xp="0"></xp-ring>
              <span class="level-meta">
                <span class="level-copy">
                  <small>Nivel <strong id="lvl-num">1</strong></small>
                  <b><span id="lvl-xp">0</span><span class="of"> / <span id="lvl-xp-next">50</span> XP</span></b>
                </span>
                <span class="level-progress" aria-hidden="true"><span id="lvl-progress-fill"></span></span>
                <span class="level-hint" id="lvl-xp-restante">50 XP para subir</span>
              </span>
            </button>
            <button type="button" class="hdr-chip streak-chip"
                    id="btn-streak-chip"
                    aria-label="Racha diaria — ver logros y retos"
                    title="Ver logros y retos">
              <streak-flame days="0"></streak-flame>
              <span class="flame-copy">
                <strong id="streak-days-lbl">0</strong>
                <small>Racha</small>
              </span>
            </button>
          </div>
          <div class="hdr-spacer"></div>
          <div class="hdr-right">
            <button class="user-btn" id="btn-user-menu" aria-haspopup="dialog" aria-expanded="false" title="Cuenta">
              <span class="avatar" id="user-avatar">?</span>
            </button>
          </div>
        </header>

        <nav class="bottom-nav" id="bottom-nav" aria-label="Navegación principal">
          ${navItems.map(it => `
            <button type="button" class="bnav-item ${it.id === activeKey ? 'active' : ''}"
                    data-view="${esc(it.view || '')}" data-nav-id="${esc(it.id)}">
              <span class="bnav-ico" aria-hidden="true">${icon(it.icon)}</span>
              <span class="bnav-label">${esc(it.label)}</span>
            </button>
          `).join('')}
        </nav>

        <div class="aprentix-sheet hidden" id="user-sheet" role="dialog" aria-label="Cuenta">
          <div class="aprentix-sheet-backdrop" data-sheet-close="1"></div>
          <div class="aprentix-sheet-card" role="document">
            <header class="sheet-head">
              <span class="avatar sheet-avatar" id="sheet-avatar">?</span>
              <div class="sheet-head-txt">
                <strong id="sheet-username">—</strong>
                <span class="sheet-mode-label" id="sheet-email"></span>
                <span class="sheet-roles" id="sheet-roles" aria-label="Roles asignados"></span>
              </div>
              <button class="sheet-close" data-sheet-close="1" aria-label="Cerrar">✕</button>
            </header>

            <div class="sheet-section">
              <button class="sheet-row" id="btn-cambiar-oposicion" type="button">
                <span class="sheet-row-ico">${icon('folder')}</span>
                <span class="sheet-row-label">Cambiar oposición</span>
              </button>
              <button class="sheet-row" id="btn-mi-cuenta" type="button" data-view="mi-cuenta">
                <span class="sheet-row-ico">${icon('user')}</span>
                <span class="sheet-row-label">Mi cuenta</span>
              </button>
              <button class="sheet-row admin-row" id="btn-admin-panel" type="button" data-view="admin-usuarios">
                <span class="sheet-row-ico">${icon('shield')}</span>
                <span class="sheet-row-label">Usuarios (admin)</span>
                <span class="sheet-row-badge">ADMIN</span>
              </button>
              <button class="sheet-row admin-row" id="btn-admin-contenido" type="button" data-view="admin-contenido">
                <span class="sheet-row-ico">${icon('folder')}</span>
                <span class="sheet-row-label">Gestión de contenido</span>
                <span class="sheet-row-badge">ADMIN</span>
              </button>
              <button class="sheet-row danger" id="btn-logout" type="button">
                <span class="sheet-row-ico">${icon('logout')}</span>
                <span class="sheet-row-label">Cerrar sesión</span>
              </button>
            </div>
          </div>
        </div>
      `;
      this._wire();
      this._refreshGamif();     // XP/racha
      this._refreshUser();      // avatar/nombre
      // Cada cambio de sesión repinta la cabecera.
      window.addEventListener('aprentix:session', () => {
        this._refreshUser();
        this._refreshGamif();
      });
    }

    _wire() {
      const $ = (s) => this.querySelector(s);
      const openSheet = (id) => {
        const s = this.querySelector('#' + id);
        if (!s) return;
        s.classList.remove('hidden');
        s.classList.add('open');
        document.body.classList.add('sheet-open');
      };
      const closeAll = () => {
        this.querySelectorAll('.aprentix-sheet.open').forEach(s => {
          s.classList.remove('open'); s.classList.add('hidden');
        });
        document.body.classList.remove('sheet-open');
      };

      $('#btn-user-menu').onclick = () => openSheet('user-sheet');

      // Chips de nivel y racha llevan al panel de logros y retos, así el
      // usuario tiene un atajo desde la cabecera hacia su progreso.
      const navLogros = () => this.dispatchEvent(new CustomEvent('aprentix:nav', {
        detail: { id: 'logros' }, bubbles: true,
      }));
      const bl = $('#btn-level-chip');
      const bs = $('#btn-streak-chip');
      if (bl) bl.onclick = navLogros;
      if (bs) bs.onclick = navLogros;
      this.querySelectorAll('[data-sheet-close]').forEach(el =>
        el.addEventListener('click', closeAll));
      document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') closeAll();
      });

      // Cierra la sheet al pulsar cualquier fila (excepto las que abren otra).
      this.querySelectorAll('.sheet-row').forEach(b =>
        b.addEventListener('click', () => setTimeout(closeAll, 0)));

      // Cambiar oposición: dispara evento para que la SPA lo maneje.
      $('#btn-cambiar-oposicion').onclick = () => {
        this.dispatchEvent(new CustomEvent('aprentix:nav', {
          detail: { id: 'cambiar-oposicion' }, bubbles: true,
        }));
      };

      // Cerrar sesión. La SPA vive en la raíz (con /estudio/ como alias),
      // así que redirigimos al login sin forzar el prefijo antiguo.
      $('#btn-logout').onclick = async () => {
        if (S) await S.logout();
        location.href = '/#/login';
      };

      // Oculta las filas de admin si el usuario no es admin. Los roles llegan
      // por dos vías: (a) claim `roles` del JWT (rápido, se sella al login) y
      // (b) `mi_cuenta` — que es fresco pero requiere red. Usamos la unión:
      // si alguno de los dos dice "admin", mostramos. Así al añadir el rol en
      // BBDD tras el login, no hay que cerrar sesión — con la primera llamada
      // a mi_cuenta la cabecera se actualiza (this._freshAdmin se recuerda).
      this._freshAdmin = null;
      const applyAdmin = () => {
        const u = S?.getUser?.();
        const jwtAdmin   = !!(u && Array.isArray(u.roles) && u.roles.includes('admin'));
        const freshAdmin = this._freshAdmin === true;
        const esAdmin = jwtAdmin || freshAdmin;
        const bp = $('#btn-admin-panel');
        const cont = $('#btn-admin-contenido');
        if (bp)   bp.hidden = !esAdmin;
        if (cont) cont.hidden = !esAdmin;
        console.debug('[aprentix-header] applyAdmin', {
          jwtAdmin, freshAdmin, esAdmin,
          rolesJwt: u?.roles || [],
        });
      };
      this._applyAdmin = applyAdmin;
      applyAdmin();
      window.addEventListener('aprentix:session', applyAdmin);

      // Delega los clicks del bottom-nav como CustomEvent.
      this.querySelectorAll('[data-view]').forEach(el => {
        el.addEventListener('click', (e) => {
          const id = el.dataset.view;
          if (!id) return;
          this.dispatchEvent(new CustomEvent('aprentix:nav', {
            detail: { id }, bubbles: true,
          }));
        });
      });
    }

    async _refreshGamif() {
      if (!S || !S.getUser()) return;
      try {
        const g = await S.rpc('mi_gamificacion');
        const ring = this.querySelector('xp-ring');
        if (ring) {
          ring.setAttribute('level', g.nivel);
          ring.setAttribute('xp', g.xp_total);
          ring.setAttribute('xp-nivel-ini', g.xp_nivel_ini);
          ring.setAttribute('xp-nivel-sig', g.xp_nivel_sig);
        }
        const fl = this.querySelector('streak-flame');
        const dias = g.racha_actual || 0;
        if (fl) fl.setAttribute('days', dias);
        // Etiquetas numéricas visibles de la chip: aprovechan el espacio
        // que antes quedaba vacío en la topbar y refuerzan el contexto.
        const numLvl  = this.querySelector('#lvl-num');
        const numXP   = this.querySelector('#lvl-xp');
        const numNext = this.querySelector('#lvl-xp-next');
        const numRch  = this.querySelector('#streak-days-lbl');
        const progreso = this.querySelector('#lvl-progress-fill');
        const restante = this.querySelector('#lvl-xp-restante');
        if (numLvl)  numLvl.textContent  = g.nivel;
        if (numXP)   numXP.textContent   = g.xp_total;
        if (numNext) numNext.textContent = g.xp_nivel_sig;
        if (numRch)  numRch.textContent  = dias;
        const inicioNivel = Number(g.xp_nivel_ini) || 0;
        const siguienteNivel = Number(g.xp_nivel_sig) || Math.max(50, inicioNivel + 50);
        const xpTotal = Number(g.xp_total) || 0;
        const porcentaje = Math.min(100, Math.max(0,
          ((xpTotal - inicioNivel) / Math.max(1, siguienteNivel - inicioNivel)) * 100));
        if (progreso) progreso.style.width = `${porcentaje}%`;
        if (restante) restante.textContent = `${Math.max(0, siguienteNivel - xpTotal)} XP para subir`;
      } catch (_) { /* silencioso */ }
    }

    async _refreshUser() {
      if (!S || !S.getUser()) {
        this.querySelector('#user-avatar').textContent = '?';
        this.querySelector('#sheet-username').textContent = '—';
        this.querySelector('#sheet-email').textContent = '';
        this.querySelector('#sheet-roles').textContent = '';
        return;
      }
      try {
        const me = await S.rpc('mi_cuenta');
        const inicial = (me.nombre_visible || me.email || '?').trim()[0].toUpperCase();
        this.querySelector('#user-avatar').textContent  = inicial;
        this.querySelector('#sheet-avatar').textContent = inicial;
        this.querySelector('#sheet-username').textContent = me.nombre_visible || '';
        this.querySelector('#sheet-email').textContent    = me.email || '';
        const roles = Array.isArray(me.roles) ? me.roles : [];
        const contenedorRoles = this.querySelector('#sheet-roles');
        contenedorRoles.replaceChildren(...(roles.length ? roles : ['sin rol']).map(rol => {
          const etiqueta = document.createElement('span');
          etiqueta.className = 'sheet-role';
          etiqueta.textContent = rol;
          return etiqueta;
        }));
        // Detecta cambios de rol tras el login (por ejemplo, un admin te dio
        // el rol admin). Si los roles frescos difieren del JWT, actualizamos
        // la visibilidad del panel admin sin esperar a que caduque el token.
        this._freshAdmin = roles.includes('admin');
        console.debug('[aprentix-header] roles frescos de mi_cuenta:', roles);
        if (typeof this._applyAdmin === 'function') this._applyAdmin();
      } catch (e) {
        console.warn('[aprentix-header] mi_cuenta falló:', e.message);
      }
    }
  }

  customElements.define('aprentix-header', AprentixHeader);
})();
