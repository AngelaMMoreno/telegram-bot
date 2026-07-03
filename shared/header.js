/*
 * <aprentix-header active="tests|teoria" [hamburger] [teoria-hidden]>
 *
 * Custom element que pinta la cabecera común de las apps de tests y
 * teoría. Se renderiza en light DOM (sin Shadow) para que el CSS
 * compartido y los `document.getElementById(...)` de cada app sigan
 * funcionando con los IDs de siempre:
 *   #topbar #btn-menu #btn-user-menu #user-avatar #user-name
 *   #btn-config #btn-logout #nav-teoria
 *
 * Atributos:
 *   active         "tests" | "teoria" (pestaña marcada como activa).
 *   hamburger      Si está presente, muestra el botón de menú lateral
 *                  (solo lo usa la app de tests).
 *   teoria-hidden  Si está presente, oculta el enlace a Teoría (la app
 *                  de tests lo pone hidden hasta saber si el usuario
 *                  tiene el permiso).
 */
(function () {
  'use strict';

  // Todo comparte origen bajo aprentix.es. Enlaces con rutas absolutas
  // dentro del mismo origen para que el navegador los trate como una
  // navegación normal (mismo scope, sin abrir in-app browser).
  const LANDING_URL = '/';
  const TESTS_URL   = '/tests/';
  const TEORIA_URL  = '/teoria/';

  const ICO_MENU = `
    <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="18" x2="21" y2="18"/>
    </svg>`;
  const ICO_GEAR = `
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <circle cx="12" cy="12" r="3"/>
      <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33h.01a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82v.01a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/>
    </svg>`;
  const ICO_LOGOUT = `
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/>
      <polyline points="16 17 21 12 16 7"/>
      <line x1="21" y1="12" x2="9" y2="12"/>
    </svg>`;

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

  class AprentixHeader extends HTMLElement {
    connectedCallback() {
      const active = this.getAttribute('active') || 'tests';
      const withHamburger = this.hasAttribute('hamburger');
      const teoriaHidden = this.hasAttribute('teoria-hidden');
      const startsHidden = this.hasAttribute('start-hidden');

      this.innerHTML = `
        <header class="topbar${startsHidden ? ' hidden' : ''}" id="topbar">
          ${withHamburger ? `<button class="hamburger" id="btn-menu" aria-label="Menú">${ICO_MENU}</button>` : ''}
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
            <button class="user-btn" id="btn-user-menu" title="Configuración">
              <span class="avatar" id="user-avatar"></span>
              <span class="user-name" id="user-name"></span>
            </button>
            <button class="btn-icon" id="btn-config" title="Configuración" aria-label="Configuración">${ICO_GEAR}</button>
            <button class="btn-icon danger-icon" id="btn-logout" title="Cerrar sesión" aria-label="Cerrar sesión">${ICO_LOGOUT}</button>
          </div>
        </header>
      `;
    }
  }

  if (!customElements.get('aprentix-header')) {
    customElements.define('aprentix-header', AprentixHeader);
  }
})();
