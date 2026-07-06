/*
 * <aprentix-header active="tests|teoria" [nav-items='[...]'] [more-items='[...]']>
 *
 * Custom element que pinta el chasis común de las apps de tests y teoría.
 * En light DOM (sin Shadow) para que el CSS compartido y los
 * `document.getElementById(...)` de cada app sigan funcionando con IDs de
 * siempre:
 *   #topbar #btn-user-menu #user-avatar #user-name
 *   #btn-config #btn-logout #nav-teoria
 *
 * Además renderiza:
 *   - Una barra inferior de navegación (solo móvil) con hasta 5 slots
 *     descritos por el atributo JSON `nav-items`.
 *   - Un sheet del avatar con switch Tests⇄Teoría + Configuración +
 *     Cerrar sesión. Es la única vía para acceder a config/logout.
 *   - Un sheet "Más" con items secundarios (los admin/gestión salen
 *     resaltados) descritos por el atributo JSON `more-items`.
 *
 * Formato de cada item (nav-items y more-items):
 *   { "id": "…", "label": "…", "icon": "home|tests|search|star|target|
 *      trophy|more|book|folder|upload|tag|users|chart|book-mark|logout|
 *      gear|sun|moon|monitor",
 *     // acción — una de estas:
 *     "view":  "home",                 → dispara click con data-view=home
 *     "href":  "/tests/?atajo=retos",  → enlace
 *     "event": "buscar",               → dispara CustomEvent aprentix:nav
 *                                        con detail = { id: "buscar" }
 *     "more":  true,                   → abre el sheet "Más"
 *     // visibilidad opcional:
 *     "gestion": true  → solo si body.puede-gestionar
 *     "admin":   true  → solo si body.es-admin
 *   }
 *
 * Atributos:
 *   active         "tests" | "teoria" (pestaña marcada como activa).
 *   nav-items      JSON del bottom-nav móvil.
 *   more-items     JSON del sheet secundario.
 *   admin-items    JSON del sheet de administración. Solo visible para
 *                  usuarios con permiso de gestión o admin. Es común a
 *                  todas las apps: cada item declara su acción (view
 *                  local o href cross-app tipo /tests/?atajo=…).
 *   teoria-hidden  Oculta el link a Teoría hasta saber si el usuario
 *                  tiene el permiso (lo levanta el app.js).
 *   start-hidden   Empieza oculto (el app.js lo revela tras login).
 */
(function () {
  'use strict';

  const LANDING_URL = '/';
  const TESTS_URL   = '/tests/';
  const TEORIA_URL  = '/teoria/';

  // Diccionario de iconos SVG. Se usan en bottom-nav y en el user sheet.
  const ICONS = {
    home:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12l9-9 9 9"/><path d="M5 10v10a1 1 0 0 0 1 1h4v-6h4v6h4a1 1 0 0 0 1-1V10"/></svg>',
    tests:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="3" width="16" height="18" rx="2"/><path d="M8 8h6M8 12h8M8 16h5"/><circle cx="16.5" cy="7.5" r="1.2" fill="currentColor" stroke="none"/></svg>',
    search: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="7"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg>',
    star:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="12 2 15 8.5 22 9.3 17 14 18.5 21 12 17.5 5.5 21 7 14 2 9.3 9 8.5"/></svg>',
    target: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><line x1="9" y1="9" x2="15" y2="15"/><line x1="15" y1="9" x2="9" y2="15"/></svg>',
    trophy: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="8" r="6"/><path d="M15.5 12.5L17 22l-5-3-5 3 1.5-9.5"/></svg>',
    more:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="5" cy="12" r="1.6" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.6" fill="currentColor" stroke="none"/><circle cx="19" cy="12" r="1.6" fill="currentColor" stroke="none"/></svg>',
    book:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 4v16a2 2 0 0 0 2 2h14V4a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2z"/><line x1="8" y1="6" x2="16" y2="6"/><line x1="8" y1="10" x2="16" y2="10"/></svg>',
    folder: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>',
    upload: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/></svg>',
    tag:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20.6 13.4L13.4 20.6a2 2 0 0 1-2.8 0L2 12V2h10l8.6 8.6a2 2 0 0 1 0 2.8z"/><circle cx="7" cy="7" r="1.5" fill="currentColor" stroke="none"/></svg>',
    users:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg>',
    chart:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="4" y1="20" x2="20" y2="20"/><rect x="6" y="10" width="3" height="10"/><rect x="11" y="6" width="3" height="14"/><rect x="16" y="13" width="3" height="7"/></svg>',
    bookmark: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3h12a1 1 0 0 1 1 1v18l-7-4-7 4V4a1 1 0 0 1 1-1z"/></svg>',
    logout: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" y1="12" x2="9" y2="12"/></svg>',
    gear:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33h.01a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82v.01a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>',
    swap:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="17 3 21 7 17 11"/><path d="M3 7h18"/><polyline points="7 21 3 17 7 13"/><path d="M21 17H3"/></svg>',
    shield: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2L4 5v7c0 5 3.5 8.5 8 10 4.5-1.5 8-5 8-10V5l-8-3z"/><polyline points="9 12 11 14 15 10"/></svg>',
  };

  function icon(name) { return ICONS[name] || ICONS.more; }

  function esc(s) {
    return String(s ?? '').replace(/[&<>"']/g, c => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[c]));
  }

  function parseItems(attr) {
    if (!attr) return [];
    try { return JSON.parse(attr) || []; }
    catch { return []; }
  }

  function tab(kind, active, hidden) {
    const isActive = active === kind;
    const label = kind === 'tests' ? 'Tests' : 'Teoría';
    const url = kind === 'tests' ? TESTS_URL : TEORIA_URL;
    const idAttr = kind === 'teoria' ? ' id="nav-teoria"' : '';
    if (isActive) {
      return `<span class="nav-tab active" data-nav="${kind}" aria-current="page"${idAttr}>${label}</span>`;
    }
    return `<a href="${url}" class="nav-tab" data-nav="${kind}"${idAttr}${hidden ? ' hidden' : ''}>${label}</a>`;
  }

  function itemVisibilityClass(it) {
    const cls = [];
    if (it.gestion) cls.push('gestion');
    if (it.admin)   cls.push('solo-admin');
    if (it.special) cls.push('special');
    return cls.join(' ');
  }

  function itemAttrs(it) {
    // Devuelve los atributos del <a>/<button> según la acción.
    if (it.view)  return { tag: 'button', attrs: `type="button" data-view="${esc(it.view)}"` };
    if (it.href)  return { tag: 'a',      attrs: `href="${esc(it.href)}"` };
    if (it.event) return { tag: 'button', attrs: `type="button" data-nav-event="${esc(it.event)}"` };
    if (it.more)  return { tag: 'button', attrs: `type="button" data-more="1"` };
    return { tag: 'button', attrs: 'type="button"' };
  }

  function renderNavItem(it, activeKey) {
    const { tag, attrs } = itemAttrs(it);
    const isActive = activeKey && it.id === activeKey;
    const cls = ['bnav-item', itemVisibilityClass(it), isActive ? 'active' : ''].filter(Boolean).join(' ');
    return `<${tag} class="${cls}" ${attrs} data-nav-id="${esc(it.id)}">
      <span class="bnav-ico" aria-hidden="true">${icon(it.icon)}</span>
      <span class="bnav-label">${esc(it.label)}</span>
    </${tag}>`;
  }

  function renderMoreItem(it) {
    const { tag, attrs } = itemAttrs(it);
    const cls = ['more-item', itemVisibilityClass(it)].filter(Boolean).join(' ');
    return `<${tag} class="${cls}" ${attrs} data-nav-id="${esc(it.id)}">
      <span class="more-ico" aria-hidden="true">${icon(it.icon)}</span>
      <span class="more-label">${esc(it.label)}</span>
    </${tag}>`;
  }

  class AprentixHeader extends HTMLElement {
    connectedCallback() {
      const active = this.getAttribute('active') || 'tests';
      const teoriaHidden = this.hasAttribute('teoria-hidden');
      const startsHidden = this.hasAttribute('start-hidden');

      const navItems = parseItems(this.getAttribute('nav-items'));
      const moreItems = parseItems(this.getAttribute('more-items'));
      const adminItems = parseItems(this.getAttribute('admin-items'));
      const activeKey = this.getAttribute('active-key') || (active === 'tests' ? 'home' : null);

      this.innerHTML = `
        <header class="topbar${startsHidden ? ' hidden' : ''}" id="topbar">
          <a href="${LANDING_URL}" class="brand" title="Volver al inicio">
            <span class="brand-logo" aria-hidden="true"></span>
            <span class="brand-name">Aprentix</span>
          </a>
          <nav class="hdr-nav" aria-label="Secciones">
            ${tab('tests', active, false)}
            ${tab('teoria', active, teoriaHidden)}
          </nav>
          <div class="hdr-spacer"></div>
          <div class="user-chip">
            <button class="user-btn" id="btn-user-menu" title="Cuenta" aria-haspopup="dialog" aria-expanded="false">
              <span class="avatar" id="user-avatar"></span>
              <span class="user-name" id="user-name"></span>
            </button>
          </div>
        </header>

        <!-- Bottom-nav móvil (oculta en desktop) -->
        <nav class="bottom-nav${startsHidden ? ' hidden' : ''}" id="bottom-nav" aria-label="Navegación principal">
          ${navItems.map(it => renderNavItem(it, activeKey)).join('')}
        </nav>

        <!-- Sheet del avatar: switch app + config + logout -->
        <div class="aprentix-sheet hidden" id="user-sheet" role="dialog" aria-label="Cuenta">
          <div class="aprentix-sheet-backdrop" data-sheet-close="1"></div>
          <div class="aprentix-sheet-card" role="document">
            <header class="sheet-head">
              <span class="avatar sheet-avatar" id="sheet-avatar"></span>
              <div class="sheet-head-txt">
                <strong id="sheet-username">—</strong>
                <span class="sheet-mode-label" id="sheet-mode-label">${active === 'tests' ? 'Modo Tests' : 'Modo Teoría'}</span>
              </div>
              <button class="sheet-close" data-sheet-close="1" aria-label="Cerrar">✕</button>
            </header>

            <div class="sheet-section">
              <div class="sheet-section-title">Modo</div>
              <div class="mode-switch" role="tablist" aria-label="Cambiar de sección">
                <a class="mode-opt ${active === 'tests' ? 'active' : ''}" ${active === 'tests' ? 'aria-current="page"' : `href="${TESTS_URL}"`}>
                  <span class="mode-ico">${icon('tests')}</span>
                  <span>Tests</span>
                </a>
                <a class="mode-opt ${active === 'teoria' ? 'active' : ''}" id="sheet-mode-teoria" ${active === 'teoria' ? 'aria-current="page"' : `href="${TEORIA_URL}"`}>
                  <span class="mode-ico">${icon('book')}</span>
                  <span>Teoría</span>
                </a>
              </div>
            </div>

            <div class="sheet-section">
              <!-- Retos: común a tests y teoría, así que vive en el sheet.
                   En tests navega a la vista local; en teoría abre el
                   apartado de retos de la app de tests. -->
              ${active === 'tests'
                ? `<button class="sheet-row" id="btn-retos" type="button" data-view="retos">
                     <span class="sheet-row-ico">${icon('trophy')}</span>
                     <span class="sheet-row-label">Retos y logros</span>
                   </button>`
                : `<a class="sheet-row" id="btn-retos" href="${TESTS_URL}?atajo=retos">
                     <span class="sheet-row-ico">${icon('trophy')}</span>
                     <span class="sheet-row-label">Retos y logros</span>
                   </a>`}
              <button class="sheet-row" id="btn-config" type="button">
                <span class="sheet-row-ico">${icon('gear')}</span>
                <span class="sheet-row-label">Configuración</span>
              </button>
              <!-- Fila destacada de admin: sólo si el usuario tiene permiso
                   (body.puede-gestionar o body.es-admin). Ver CSS. -->
              <button class="sheet-row admin-row" id="btn-admin-panel" type="button" data-more-sheet="admin-sheet">
                <span class="sheet-row-ico">${icon('shield')}</span>
                <span class="sheet-row-label">Panel de administración</span>
                <span class="sheet-row-badge">ADMIN</span>
              </button>
              <button class="sheet-row danger" id="btn-logout" type="button">
                <span class="sheet-row-ico">${icon('logout')}</span>
                <span class="sheet-row-label">Cerrar sesión</span>
              </button>
            </div>
          </div>
        </div>

        <!-- Sheet Admin: solo con permiso. Común a tests y teoría. -->
        <div class="aprentix-sheet hidden" id="admin-sheet" role="dialog" aria-label="Panel de administración">
          <div class="aprentix-sheet-backdrop" data-sheet-close="1"></div>
          <div class="aprentix-sheet-card admin-card" role="document">
            <header class="sheet-head">
              <div class="sheet-head-txt">
                <strong>Panel de administración</strong>
                <span class="sheet-mode-label">Herramientas restringidas por rol</span>
              </div>
              <button class="sheet-close" data-sheet-close="1" aria-label="Cerrar">✕</button>
            </header>
            <div class="sheet-section more-list admin-list">
              ${adminItems.length
                ? adminItems.map(renderMoreItem).join('')
                : '<p class="muted small" style="grid-column:1/-1; margin:0">Sin herramientas disponibles.</p>'}
            </div>
          </div>
        </div>

        <!-- Sheet "Más": opciones secundarias -->
        <div class="aprentix-sheet hidden" id="more-sheet" role="dialog" aria-label="Más opciones">
          <div class="aprentix-sheet-backdrop" data-sheet-close="1"></div>
          <div class="aprentix-sheet-card" role="document">
            <header class="sheet-head">
              <div class="sheet-head-txt">
                <strong>Más opciones</strong>
                <span class="sheet-mode-label">Herramientas y gestión</span>
              </div>
              <button class="sheet-close" data-sheet-close="1" aria-label="Cerrar">✕</button>
            </header>
            <div class="sheet-section more-list">
              ${moreItems.map(renderMoreItem).join('')}
            </div>
          </div>
        </div>
      `;

      this._wire();
    }

    _wire() {
      const openSheet = (id) => {
        const s = this.querySelector('#' + id);
        if (!s) return;
        s.classList.remove('hidden');
        s.classList.add('open');
        document.body.classList.add('sheet-open');
        const btn = id === 'user-sheet' ? this.querySelector('#btn-user-menu') : null;
        if (btn) btn.setAttribute('aria-expanded', 'true');
      };
      const closeSheet = (s) => {
        s.classList.remove('open');
        s.classList.add('hidden');
        // Cierra "todos" quiere decir solo si no queda ninguno abierto.
        if (!this.querySelector('.aprentix-sheet.open')) {
          document.body.classList.remove('sheet-open');
        }
        const btn = this.querySelector('#btn-user-menu');
        if (btn) btn.setAttribute('aria-expanded', 'false');
      };

      // Toggle del avatar → sheet del usuario.
      const userBtn = this.querySelector('#btn-user-menu');
      userBtn?.addEventListener('click', (e) => {
        e.preventDefault();
        const s = this.querySelector('#user-sheet');
        if (s.classList.contains('open')) closeSheet(s); else openSheet('user-sheet');
      });

      // Cerrar sheets: click en backdrop, botón ✕ o Esc.
      this.querySelectorAll('.aprentix-sheet').forEach(s => {
        s.addEventListener('click', (e) => {
          if (e.target.closest('[data-sheet-close]')) {
            e.preventDefault();
            closeSheet(s);
          }
        });
      });
      document.addEventListener('keydown', (e) => {
        if (e.key !== 'Escape') return;
        this.querySelectorAll('.aprentix-sheet.open').forEach(closeSheet);
      });

      // Botón "Más" del bottom-nav → sheet secundaria.
      this.querySelectorAll('[data-more]').forEach(b => {
        b.addEventListener('click', (e) => {
          e.preventDefault();
          openSheet('more-sheet');
        });
      });

      // Fila "Panel de admin" en el sheet del usuario → sheet admin.
      // Cerramos primero el sheet del usuario para transición limpia.
      this.querySelector('#btn-admin-panel')?.addEventListener('click', (e) => {
        e.preventDefault();
        const userSheet = this.querySelector('#user-sheet');
        if (userSheet) closeSheet(userSheet);
        openSheet('admin-sheet');
      });

      // Items con data-nav-event → CustomEvent para el app.
      this.addEventListener('click', (e) => {
        const el = e.target.closest('[data-nav-event]');
        if (!el) return;
        e.preventDefault();
        const detail = { id: el.dataset.navEvent, from: el };
        this.dispatchEvent(new CustomEvent('aprentix:nav', { detail, bubbles: true }));
        // Cierra sheets abiertas para que la nueva vista quede visible.
        this.querySelectorAll('.aprentix-sheet.open').forEach(closeSheet);
      });

      // Al pulsar cualquier item del bottom-nav, del sheet "Más" o una
      // fila del sheet del avatar (excepto la de admin que abre otro
      // sheet), cerramos las sheets abiertas — el routing lo hace el app.
      this.querySelectorAll('.bnav-item, .more-item, .sheet-row').forEach(b => {
        if (b.id === 'btn-admin-panel') return;  // abre otro sheet
        b.addEventListener('click', () => {
          setTimeout(() => {
            this.querySelectorAll('.aprentix-sheet.open').forEach(closeSheet);
          }, 0);
        });
      });

      // Espejo: sincroniza avatar/username del sheet con los del topbar.
      const syncAvatar = () => {
        const av = this.querySelector('#user-avatar');
        const nm = this.querySelector('#user-name');
        const shAv = this.querySelector('#sheet-avatar');
        const shNm = this.querySelector('#sheet-username');
        if (shAv) shAv.textContent = av?.textContent || '?';
        if (shNm) shNm.textContent = nm?.textContent || '—';
      };
      // Observa cambios de contenido en el chip del topbar.
      const av = this.querySelector('#user-avatar');
      if (av && 'MutationObserver' in window) {
        const mo = new MutationObserver(syncAvatar);
        mo.observe(av, { childList: true, characterData: true, subtree: true });
        const nm = this.querySelector('#user-name');
        if (nm) mo.observe(nm, { childList: true, characterData: true, subtree: true });
        this._avatarObserver = mo;
      }
      syncAvatar();

      // Si el atributo teoria-hidden se levanta más tarde por app.js
      // (al saber si tiene permiso), refleja el cambio en el switch del
      // sheet: si no puede acceder a teoría, se oculta la opción.
      const navT = this.querySelector('#nav-teoria');
      const modeT = this.querySelector('#sheet-mode-teoria');
      if (navT && modeT && 'MutationObserver' in window) {
        const applyModeT = () => {
          modeT.hidden = !!navT.hidden;
        };
        applyModeT();
        const mo = new MutationObserver(applyModeT);
        mo.observe(navT, { attributes: true, attributeFilter: ['hidden'] });
        this._navTObserver = mo;
      }
    }
  }

  if (!customElements.get('aprentix-header')) {
    customElements.define('aprentix-header', AprentixHeader);
  }
})();
