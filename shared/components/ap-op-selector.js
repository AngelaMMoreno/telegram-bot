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

    if (subtitle) {
      const p = document.createElement('p');
      p.className = 'muted small';
      p.textContent = subtitle;
      this._modal.appendChild(p);
    }

    this._list = document.createElement('ul');
    this._list.className = 'check-list';
    this._modal.appendChild(this._list);

    this.appendChild(this._modal);

    this._list.addEventListener('click', (e) => {
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
    if (!this._list) return;
    const items = [{ id: null, nombre: 'Todas' }, ...(oposiciones || [])];
    this._list.innerHTML = items.map(op => {
      const idAttr = op.id == null ? '' : op.id;
      const activa = String(op.id ?? '') === String(currentId ?? '');
      return `
        <li>
          <button class="check-item" type="button"
                  data-op-id="${idAttr}"
                  data-op-nombre="${(op.nombre || '').replace(/"/g, '&quot;')}"
                  aria-current="${activa ? 'true' : 'false'}">
            <strong>${op.nombre || ''}</strong>
          </button>
        </li>`;
    }).join('');
  }

  open() { this._modal && this._modal.open(); }
  close() { this._modal && this._modal.close(); }
}

customElements.define('ap-op-selector', ApOpSelector);
