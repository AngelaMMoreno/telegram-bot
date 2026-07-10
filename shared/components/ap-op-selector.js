/*
 * <ap-op-selector> · picker de oposición del usuario.
 *
 * Encapsula el modal "¿Con qué oposición trabajas hoy?" que hoy está
 * duplicado en tests y teoría con markup y IDs distintos. La app le
 * pasa la lista de oposiciones, decide cuándo abrirlo y escucha el
 * evento 'ap-op-select' para reaccionar a la elección.
 *
 * Uso declarativo:
 *   <ap-op-selector id="op-selector"
 *                   title="¿Con qué oposición trabajas hoy?"
 *                   subtitle="Se aplica a tests y a teoría."></ap-op-selector>
 *
 * API:
 *   el.setOptions(oposiciones, currentId)
 *       oposiciones: array de { id, nombre }. Se añade automáticamente
 *       una fila "Todas" (id=null) al principio.
 *       currentId: id actual o null.
 *   el.open() / el.close()
 *
 * Eventos:
 *   'ap-op-select' con detail = { id, nombre }
 *
 * Depende de shared/components/ap-modal.js (debe cargarse antes).
 */

function escHtml(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));
}

class ApOpSelector extends HTMLElement {
  connectedCallback() {
    if (this._modal) return;

    const title = this.getAttribute('title') || '¿Con qué oposición trabajas hoy?';
    const subtitle = this.getAttribute('subtitle') || '';

    // Siempre mostramos la X: aunque sea la primera vez interceptamos el
    // cierre y avisamos al usuario que debe seleccionar una oposición.
    this._modal = document.createElement('ap-modal');
    this._modal.setAttribute('title', title);
    this._modal.setAttribute('closable', '');
    this._modal.setAttribute('hidden', '');
    this._modal.classList.add('hidden');
    // Guarda de "primera selección obligatoria": la levanta setOptions()
    // cuando currentId es null; el listener 'ap-close' lo cancela.
    this._requireSelection = false;

    // OJO: no podemos crear <ul> y appendChild-ear al modal antes de
    // insertarlo, porque <ap-modal>.connectedCallback() reescribe su
    // innerHTML al conectarse y destruye cualquier hijo previo, dejando
    // referencias fantasma. En su lugar pasamos el contenido como
    // innerHTML (string) y buscamos la <ul> DESPUÉS de conectar.
    this._modal.innerHTML = `
      ${subtitle ? `<p class="muted small">${escHtml(subtitle)}</p>` : ''}
      <ul class="check-list ap-op-list"></ul>`;

    this.appendChild(this._modal);

    // Ahora que el modal se ha "wrappeado" en .modal-card > .modal-body,
    // localizamos la <ul> re-creada. Es la fuente de la verdad.
    this._list = this._modal.querySelector('.ap-op-list');

    this._modal.addEventListener('click', (e) => {
      const btn = e.target.closest('[data-op-id]');
      if (!btn) return;
      const raw = btn.dataset.opId;
      const id = raw === '' ? null : raw;
      const nombre = btn.dataset.opNombre || 'Todas';
      // Al elegir baja el flag para que el próximo cierre sea normal.
      this._requireSelection = false;
      this.dispatchEvent(new CustomEvent('ap-op-select', {
        detail: { id, nombre },
        bubbles: true,
      }));
      this.close();
    });

    // Si la selección es obligatoria (primera vez sin oposición elegida) y
    // el usuario intenta cerrar (X, Esc, backdrop), interceptamos el
    // método .close() del <ap-modal> hijo para bloquearlo y avisar.
    const origClose = this._modal.close.bind(this._modal);
    this._modal.close = () => {
      if (this._requireSelection) {
        this.dispatchEvent(new CustomEvent('ap-op-selection-required', {
          bubbles: true,
        }));
        return;
      }
      origClose();
    };
  }

  setOptions(oposiciones, currentId) {
    // Si por algún motivo la ul se ha perdido, la re-buscamos.
    if (!this._list || !this._list.isConnected) {
      this._list = this._modal && this._modal.querySelector('.ap-op-list');
    }
    if (!this._list) return;
    // Sin oposición actual (primera selección): activa el guard para que
    // el cierre sin elegir dispare 'ap-op-selection-required' en la app.
    this._requireSelection = currentId == null || currentId === '';
    const items = [{ id: null, nombre: 'Todas mis oposiciones', _todas: true }, ...(oposiciones || [])];
    this._list.innerHTML = items.map(op => {
      const idAttr = op.id == null ? '' : op.id;
      const activa = String(op.id ?? '') === String(currentId ?? '');
      const desc = op.descripcion
        ? `<span class="ap-op-desc muted small">${escHtml(op.descripcion)}</span>` : '';
      // "Todas" lleva un icono global; el resto, birrete de graduado.
      const emoji = op._todas ? '🌱' : '🎓';
      const tick = activa
        ? '<span class="ap-op-tick" aria-hidden="true">✓</span>' : '';
      return `
        <li>
          <button class="check-item ap-op-item${op._todas ? ' ap-op-item-todas' : ''}"
                  type="button"
                  data-op-id="${escHtml(idAttr)}"
                  data-op-nombre="${escHtml(op.nombre || '')}"
                  aria-current="${activa ? 'true' : 'false'}">
            <span class="ap-op-ico-wrap" aria-hidden="true">${emoji}</span>
            <span class="ap-op-body">
              <strong>${escHtml(op.nombre || '')}</strong>
              ${desc}
            </span>
            ${tick}
          </button>
        </li>`;
    }).join('');
  }

  open() { this._modal && this._modal.open(); }
  close() { this._modal && this._modal.close(); }
}

customElements.define('ap-op-selector', ApOpSelector);
