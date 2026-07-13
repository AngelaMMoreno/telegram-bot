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
 *   el.setOptions(oposiciones, currentId, opts)
 *       oposiciones: array de { id, nombre }. Se añade automáticamente
 *       una fila "Todas" (id=null) al principio salvo que opts.allowAll
 *       sea false: entonces solo aparecen las oposiciones asignadas.
 *       currentId: id actual o null.
 *       opts: { allowAll?: boolean = true }
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
    // El selector siempre trae X de cerrar. El guard "requerido" (ver
    // setRequired) impide que se cierre sin elegir cuando es la primera
    // vez que el usuario configura su oposición.
    this._modal = document.createElement('ap-modal');
    this._modal.setAttribute('title', title);
    this._modal.setAttribute('closable', '');
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
      // Al elegir, ya no es "obligatorio" (ha seleccionado).
      this._required = false;
      this._modal._required = false;
      this.dispatchEvent(new CustomEvent('ap-op-select', {
        detail: { id, nombre },
        bubbles: true,
      }));
      this.close();
    });

    // Intercepta intentos de cerrar (X, Esc, backdrop) cuando el modo
    // "requerido" está activo. En vez de cerrar, mostramos un aviso.
    this._modal.addEventListener('click', (e) => {
      if (!this._required) return;
      const cerrando = e.target === this._modal ||
                       e.target.closest('[data-ap-close]');
      if (!cerrando) return;
      e.stopPropagation();
      // Aviso inline: pintamos un mensaje temporal encima de la lista.
      this._showRequiredHint();
      // Evita el close por click en overlay: <ap-modal>'s click handler
      // se dispara después; devolvemos el modal a estado abierto.
      queueMicrotask(() => this._modal && this._modal.open());
    }, true);
    document.addEventListener('keydown', (e) => {
      if (e.key !== 'Escape') return;
      if (!this._required) return;
      if (this._modal.classList.contains('hidden')) return;
      e.stopPropagation();
      this._showRequiredHint();
      queueMicrotask(() => this._modal && this._modal.open());
    }, true);
  }

  _showRequiredHint() {
    if (!this._modal) return;
    const body = this._modal.querySelector('.modal-body');
    if (!body) return;
    let hint = body.querySelector('.ap-op-required-hint');
    if (!hint) {
      hint = document.createElement('p');
      hint.className = 'ap-op-required-hint';
      hint.setAttribute('role', 'alert');
      hint.textContent = 'Debes seleccionar una oposición para continuar.';
      body.prepend(hint);
    }
    hint.classList.remove('shake');
    void hint.offsetWidth;
    hint.classList.add('shake');
  }

  setOptions(oposiciones, currentId, opts = {}) {
    // Si por algún motivo la ul se ha perdido, la re-buscamos.
    if (!this._list || !this._list.isConnected) {
      this._list = this._modal && this._modal.querySelector('.ap-op-list');
    }
    if (!this._list) return;
    const allowAll = opts.allowAll !== false;
    const items = allowAll
      ? [{ id: null, nombre: 'Todas mis oposiciones', _all: true }, ...(oposiciones || [])]
      : [...(oposiciones || [])];
    // Emojis rotativos para dar un toque visual a la ficha (queda cálida
    // en lugar de "texto sobre verde oscuro"). El "Todas" mantiene un
    // icono neutro.
    const ICONS = ['🎓', '📚', '🧪', '⚖️', '🏛️', '🩺', '📐', '🌐', '🧭', '📝'];
    this._list.innerHTML = items.map((op, i) => {
      const idAttr = op.id == null ? '' : op.id;
      const activa = String(op.id ?? '') === String(currentId ?? '');
      const desc = op.descripcion
        ? `<span class="check-item-desc">${escHtml(op.descripcion)}</span>` : '';
      const icono = op._all ? '✨' : ICONS[i % ICONS.length];
      return `
        <li>
          <button class="check-item op-card" type="button"
                  data-op-id="${escHtml(idAttr)}"
                  data-op-nombre="${escHtml(op.nombre || '')}"
                  aria-current="${activa ? 'true' : 'false'}">
            <span class="op-card-ico" aria-hidden="true">${icono}</span>
            <span class="op-card-body">
              <strong>${escHtml(op.nombre || '')}</strong>
              ${desc}
            </span>
            ${activa ? '<span class="op-card-check" aria-hidden="true">✓</span>' : ''}
          </button>
        </li>`;
    }).join('');
  }

  setRequired(required) {
    this._required = !!required;
    if (this._modal) this._modal._required = this._required;
    // Limpia el aviso si dejó de ser requerido.
    if (!this._required && this._modal) {
      this._modal.querySelector('.ap-op-required-hint')?.remove();
    }
  }
  open() { this._modal && this._modal.open(); }
  close() { this._modal && this._modal.close(); }
}

customElements.define('ap-op-selector', ApOpSelector);
