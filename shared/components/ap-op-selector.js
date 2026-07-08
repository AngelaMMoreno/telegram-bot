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
    const closable = this.hasAttribute('closable') || false;

    this._modal = document.createElement('ap-modal');
    this._modal.setAttribute('title', title);
    if (closable) this._modal.setAttribute('closable', '');
    this._modal.setAttribute('hidden', '');
    this._modal.classList.add('hidden');

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
      this.dispatchEvent(new CustomEvent('ap-op-select', {
        detail: { id, nombre },
        bubbles: true,
      }));
      this.close();
    });
  }

  setOptions(oposiciones, currentId) {
    // Si por algún motivo la ul se ha perdido, la re-buscamos.
    if (!this._list || !this._list.isConnected) {
      this._list = this._modal && this._modal.querySelector('.ap-op-list');
    }
    if (!this._list) return;
    const items = [{ id: null, nombre: 'Todas mis oposiciones' }, ...(oposiciones || [])];
    this._list.innerHTML = items.map(op => {
      const idAttr = op.id == null ? '' : op.id;
      const activa = String(op.id ?? '') === String(currentId ?? '');
      const desc = op.descripcion
        ? `<span class="muted small">${escHtml(op.descripcion)}</span>` : '';
      return `
        <li>
          <button class="check-item" type="button"
                  data-op-id="${escHtml(idAttr)}"
                  data-op-nombre="${escHtml(op.nombre || '')}"
                  aria-current="${activa ? 'true' : 'false'}">
            <span>
              <strong>${escHtml(op.nombre || '')}</strong>
              ${desc}
            </span>
          </button>
        </li>`;
    }).join('');
  }

  open() { this._modal && this._modal.open(); }
  close() { this._modal && this._modal.close(); }
}

customElements.define('ap-op-selector', ApOpSelector);
