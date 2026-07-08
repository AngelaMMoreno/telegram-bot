/*
 * <ap-modal> · custom element para reducir el boilerplate de modales.
 *
 * En vez de escribir:
 *
 *   <div id="foo" class="modal hidden">
 *     <div class="modal-card">
 *       <header class="modal-header">
 *         <h3>Título</h3>
 *         <button class="modal-close" aria-label="Cerrar">✕</button>
 *       </header>
 *       <div class="modal-body">…contenido…</div>
 *     </div>
 *   </div>
 *
 * escribes:
 *
 *   <ap-modal id="foo" title="Título" hidden closable>
 *     …contenido…
 *   </ap-modal>
 *
 * Al conectarse, el componente envuelve su contenido con la estructura
 * .modal + .modal-card + .modal-header + .modal-body. Como no usa
 * shadow DOM, los estilos globales (shared/modal.css) y los selectores
 * por id/class de la app siguen funcionando exactamente igual.
 *
 * API:
 *   - title="…"      opcional; si está, pinta la cabecera con <h3>
 *   - title-id="…"   opcional; da un id al <h3> para poder cambiarlo desde JS
 *   - closable       si está, añade la X y permite cerrar con Esc o click backdrop
 *   - hidden         convención estándar de HTML para que arranque oculto
 *   - .open() / .close() / .toggle(bool)
 *   - Eventos: 'ap-open', 'ap-close'
 */

class ApModal extends HTMLElement {
  connectedCallback() {
    if (this._wrapped) return;
    this._wrapped = true;

    // Si el HTML del hijo ya trae .modal-card (uso avanzado), no lo tocamos.
    // Solo aplicamos la clase .modal al host y añadimos los listeners.
    const hasCard = !!this.querySelector(':scope > .modal-card');
    if (!hasCard) {
      const title = this.getAttribute('title') || '';
      const titleId = this.getAttribute('title-id') || '';
      const closable = this.hasAttribute('closable');
      const inner = this.innerHTML;
      const idAttr = titleId ? ` id="${titleId}"` : '';
      const header = (title || titleId || closable)
        ? `<header class="modal-header">
             <h3${idAttr}>${title}</h3>
             ${closable ? '<button class="modal-close" data-ap-close aria-label="Cerrar">✕</button>' : ''}
           </header>`
        : '';
      this.innerHTML = `
        <div class="modal-card">
          ${header}
          <div class="modal-body">${inner}</div>
        </div>`;
    }

    this.classList.add('modal');

    // Normaliza el estado inicial: el atributo HTML `hidden` fuerza
    // display:none por defecto del navegador, y muchos sitios del código
    // legacy abren el modal con classList.remove("hidden") (solo la clase).
    // Convertimos aquí el atributo en la clase para que ambas APIs sean
    // equivalentes y `.classList.remove("hidden")` baste para abrir.
    if (this.hasAttribute('hidden')) {
      this.removeAttribute('hidden');
      this.classList.add('hidden');
    }

    this.addEventListener('click', (e) => {
      if (!this.hasAttribute('closable')) return;
      if (e.target === this) { this.close(); return; }
      if (e.target.closest('[data-ap-close]')) { this.close(); }
    });

    this._onKey = (e) => {
      if (e.key !== 'Escape') return;
      if (!this.hasAttribute('closable')) return;
      if (this.classList.contains('hidden')) return;
      this.close();
    };
    document.addEventListener('keydown', this._onKey);
  }

  disconnectedCallback() {
    if (this._onKey) document.removeEventListener('keydown', this._onKey);
  }

  open() {
    this.removeAttribute('hidden');
    this.classList.remove('hidden');
    this.dispatchEvent(new CustomEvent('ap-open', { bubbles: true }));
  }
  close() {
    this.classList.add('hidden');
    this.dispatchEvent(new CustomEvent('ap-close', { bubbles: true }));
  }
  toggle(force) {
    const shouldOpen = force !== undefined ? force : this.classList.contains('hidden');
    if (shouldOpen) this.open(); else this.close();
  }
}

customElements.define('ap-modal', ApModal);
