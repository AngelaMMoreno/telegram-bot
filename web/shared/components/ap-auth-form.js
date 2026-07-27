/*
 * <ap-auth-form> · formulario unificado de login + registro para la SPA
 * remodelada (`/estudio/`).
 *
 * Diferencias respecto a la versión antigua (que usaba `username`):
 *   - Los identificadores son `email`, `email2`, `nombre_visible`,
 *     `password`, `password2` — el backend PostgREST espera email como
 *     credencial primaria.
 *   - Registro pide email + repetir email + nombre visible + contraseña
 *     + repetir contraseña, con indicador de fortaleza en vivo y aviso
 *     de coincidencia bajo cada par.
 *   - Sin campo 2FA/TOTP: el login sólo pide email + contraseña.
 *   - Además del panel de login y registro, expone un panel "forgot"
 *     para solicitar el enlace de reset por email.
 *
 * Uso:
 *   <ap-auth-form mode="login"></ap-auth-form>
 *
 * Eventos disparados (bubbling):
 *   - 'ap-auth-login'    detail: { email, password }
 *   - 'ap-auth-register' detail: { email, nombre_visible, password }
 *   - 'ap-auth-forgot'   detail: { email }
 *
 * API pública:
 *   - showError(msg, kind = 'login' | 'register' | 'forgot')
 *   - showInfo(msg, kind = 'login' | 'register' | 'forgot')
 *   - setMode('login' | 'register' | 'forgot')
 *   - reset()
 */
'use strict';

(function () {
  if (customElements.get('ap-auth-form')) return;

  class ApAuthForm extends HTMLElement {
    connectedCallback() {
      if (this._mounted) return;
      this._mounted = true;

      this.innerHTML = `
        <div class="auth-card">
          <div class="auth-hero">
            <span class="brand-logo" aria-hidden="true"></span>
            <h1>Aprentix</h1>
            <p class="tagline">Tu oposición, a tu ritmo.</p>
          </div>

          <form class="auth-panel" data-panel="login" autocomplete="on" novalidate>
            <h2 class="auth-panel-title">Iniciar sesión</h2>
            <label>Email
              <input id="login-email" name="email" type="email"
                     autocomplete="email" inputmode="email"
                     autocapitalize="none" spellcheck="false" required>
            </label>
            <label>Contraseña
              <input id="login-pass" name="password" type="password"
                     autocomplete="current-password" required>
            </label>
            <button class="btn btn-primary" type="submit">Entrar</button>
            <p class="err" data-err hidden></p>
            <p class="info" data-info hidden></p>
            <p class="auth-switch">
              ¿No tienes cuenta?
              <button type="button" class="auth-switch-btn" data-auth-goto="register">Regístrate</button>
              <br>
              ¿Olvidaste la contraseña?
              <button type="button" class="auth-switch-btn" data-auth-goto="forgot">Recupérala</button>
            </p>
          </form>

          <form class="auth-panel" data-panel="register" autocomplete="off" novalidate>
            <h2 class="auth-panel-title">Crear cuenta</h2>
            <label>Email
              <input id="reg-email" name="email" type="email"
                     autocomplete="email" inputmode="email"
                     autocapitalize="none" spellcheck="false" required>
            </label>
            <label>Repite el email
              <input id="reg-email2" name="email2" type="email"
                     autocomplete="off" inputmode="email"
                     autocapitalize="none" spellcheck="false" required>
            </label>
            <p class="email-match" data-email-match hidden></p>
            <label>Nombre a mostrar
              <input id="reg-name" name="nombre_visible" type="text"
                     autocomplete="nickname" minlength="2" required>
            </label>
            <label>Contraseña (≥10 caracteres)
              <input id="reg-pass" name="password" type="password"
                     autocomplete="new-password" minlength="10" required>
            </label>
            <div class="pw-strength" data-pw-strength aria-live="polite">
              <div class="pw-strength-bar"><span data-pw-strength-fill></span></div>
              <span class="pw-strength-label" data-pw-strength-label>Introduce una contraseña</span>
            </div>
            <label>Repite la contraseña
              <input id="reg-pass2" name="password2" type="password"
                     autocomplete="new-password" minlength="10" required>
            </label>
            <p class="pw-match" data-pw-match hidden></p>
            <button class="btn btn-primary" type="submit">Crear cuenta</button>
            <p class="err" data-err hidden></p>
            <p class="info" data-info hidden></p>
            <p class="auth-switch">
              ¿Ya tienes cuenta?
              <button type="button" class="auth-switch-btn" data-auth-goto="login">Inicia sesión</button>
            </p>
          </form>

          <form class="auth-panel" data-panel="forgot" autocomplete="off" novalidate>
            <h2 class="auth-panel-title">Recuperar contraseña</h2>
            <label>Email
              <input id="forgot-email" name="email" type="email"
                     autocomplete="email" inputmode="email"
                     autocapitalize="none" spellcheck="false" required>
            </label>
            <button class="btn btn-primary" type="submit">Enviar enlace</button>
            <p class="err" data-err hidden></p>
            <p class="info" data-info hidden></p>
            <p class="auth-switch">
              <button type="button" class="auth-switch-btn" data-auth-goto="login">← Volver al inicio de sesión</button>
            </p>
          </form>
        </div>
      `;

      this._panels = this.querySelectorAll('.auth-panel');
      this._pwStrength = this.querySelector('[data-pw-strength]');
      this._pwFill     = this.querySelector('[data-pw-strength-fill]');
      this._pwLabel    = this.querySelector('[data-pw-strength-label]');
      this._pwMatch    = this.querySelector('[data-pw-match]');
      this._emailMatch = this.querySelector('[data-email-match]');

      this.setMode(this.getAttribute('mode') || 'login');

      this.addEventListener('click', (e) => {
        const btn = e.target.closest('[data-auth-goto]');
        if (!btn) return;
        e.preventDefault();
        this.setMode(btn.dataset.authGoto);
      });

      this.querySelector('#reg-pass').addEventListener('input', (e) => {
        this._updateStrength(e.target.value);
        this._updateMatch();
      });
      this.querySelector('#reg-pass2').addEventListener('input', () => this._updateMatch());
      this.querySelector('#reg-email').addEventListener('input', () => this._updateEmailMatch());
      this.querySelector('#reg-email2').addEventListener('input', () => this._updateEmailMatch());

      this.querySelector('[data-panel="login"]').addEventListener('submit', (e) => {
        e.preventDefault();
        this.clearMessages('login');
        const email    = this.querySelector('#login-email').value.trim();
        const password = this.querySelector('#login-pass').value;
        if (!email || !password) {
          return this.showError('Rellena email y contraseña.', 'login');
        }
        this.dispatchEvent(new CustomEvent('ap-auth-login', {
          bubbles: true, detail: { email, password },
        }));
      });

      this.querySelector('[data-panel="register"]').addEventListener('submit', (e) => {
        e.preventDefault();
        this.clearMessages('register');
        const email          = this.querySelector('#reg-email').value.trim();
        const email2         = this.querySelector('#reg-email2').value.trim();
        const nombre_visible = this.querySelector('#reg-name').value.trim();
        const p1             = this.querySelector('#reg-pass').value;
        const p2             = this.querySelector('#reg-pass2').value;
        if (email !== email2) return this.showError('Los emails no coinciden.', 'register');
        if (p1 !== p2)        return this.showError('Las contraseñas no coinciden.', 'register');
        if (p1.length < 10)   return this.showError('La contraseña debe tener al menos 10 caracteres.', 'register');
        const { nivel } = calcularFortaleza(p1);
        if (nivel < 2) return this.showError('Elige una contraseña más fuerte (mezcla mayúsculas, minúsculas, números y símbolos).', 'register');
        this.dispatchEvent(new CustomEvent('ap-auth-register', {
          bubbles: true, detail: { email, nombre_visible, password: p1 },
        }));
      });

      this.querySelector('[data-panel="forgot"]').addEventListener('submit', (e) => {
        e.preventDefault();
        this.clearMessages('forgot');
        const email = this.querySelector('#forgot-email').value.trim();
        if (!email) return this.showError('Introduce el email de tu cuenta.', 'forgot');
        this.dispatchEvent(new CustomEvent('ap-auth-forgot', {
          bubbles: true, detail: { email },
        }));
      });
    }

    setMode(mode) {
      const target = ['login', 'register', 'forgot'].includes(mode) ? mode : 'login';
      this._panels.forEach(p => p.classList.toggle('active', p.dataset.panel === target));
      if (target === 'register') {
        this._updateStrength(this.querySelector('#reg-pass').value);
        this._updateMatch();
        this._updateEmailMatch();
      }
      this.setAttribute('mode', target);
      this.clearMessages(target);
      // Da foco al primer input visible para acelerar la entrada de datos.
      const active = this.querySelector('.auth-panel.active input');
      if (active) queueMicrotask(() => active.focus({ preventScroll: true }));
    }

    _panelBy(kind) {
      const key = ['login', 'register', 'forgot'].includes(kind) ? kind : 'login';
      return this.querySelector(`.auth-panel[data-panel="${key}"]`);
    }

    showError(msg, kind = 'login') {
      const panel = this._panelBy(kind);
      const err = panel.querySelector('[data-err]');
      const info = panel.querySelector('[data-info]');
      if (info) { info.hidden = true; info.textContent = ''; }
      if (!err) return;
      err.textContent = msg;
      err.hidden = false;
    }

    showInfo(msg, kind = 'login') {
      const panel = this._panelBy(kind);
      const err = panel.querySelector('[data-err]');
      const info = panel.querySelector('[data-info]');
      if (err) { err.hidden = true; err.textContent = ''; }
      if (!info) return;
      info.textContent = msg;
      info.hidden = false;
    }

    clearMessages(kind) {
      const panels = kind ? [this._panelBy(kind)] : Array.from(this._panels);
      panels.forEach(p => {
        p.querySelectorAll('[data-err], [data-info]').forEach(el => {
          el.textContent = ''; el.hidden = true;
        });
      });
    }

    reset() {
      this.querySelectorAll('input').forEach(i => { i.value = ''; });
      this._updateStrength('');
      this._updateMatch();
      this._updateEmailMatch();
      this.clearMessages();
    }

    _updateStrength(pw) {
      if (!this._pwStrength) return;
      this._pwStrength.classList.remove('lvl-1', 'lvl-2', 'lvl-3', 'lvl-4');
      if (!pw) {
        this._pwFill.style.width = '0%';
        this._pwLabel.textContent = 'Introduce una contraseña';
        return;
      }
      const { nivel, etiqueta } = calcularFortaleza(pw);
      this._pwStrength.classList.add('lvl-' + nivel);
      this._pwFill.style.width = (nivel * 25) + '%';
      this._pwLabel.textContent = etiqueta;
    }

    _updateMatch() {
      if (!this._pwMatch) return;
      const p1 = this.querySelector('#reg-pass').value;
      const p2 = this.querySelector('#reg-pass2').value;
      if (!p2) { this._pwMatch.hidden = true; return; }
      this._pwMatch.hidden = false;
      if (p1 === p2) {
        this._pwMatch.textContent = '✓ Las contraseñas coinciden';
        this._pwMatch.classList.remove('err'); this._pwMatch.classList.add('ok');
      } else {
        this._pwMatch.textContent = '✗ Las contraseñas no coinciden';
        this._pwMatch.classList.remove('ok'); this._pwMatch.classList.add('err');
      }
    }

    _updateEmailMatch() {
      if (!this._emailMatch) return;
      const e1 = this.querySelector('#reg-email').value.trim();
      const e2 = this.querySelector('#reg-email2').value.trim();
      if (!e2) { this._emailMatch.hidden = true; return; }
      this._emailMatch.hidden = false;
      if (e1.toLowerCase() === e2.toLowerCase()) {
        this._emailMatch.textContent = '✓ Los emails coinciden';
        this._emailMatch.classList.remove('err'); this._emailMatch.classList.add('ok');
      } else {
        this._emailMatch.textContent = '✗ Los emails no coinciden';
        this._emailMatch.classList.remove('ok'); this._emailMatch.classList.add('err');
      }
    }
  }

  /* Cálculo de fortaleza: longitud + variedad de clases (a-z, A-Z, 0-9, símbolos).
   * No sustituye a zxcvbn; pretende dar al usuario una guía inmediata que se
   * complementa con la política real del backend (≥10 chars y 3/4 categorías). */
  function calcularFortaleza(pw) {
    if (!pw) return { nivel: 0, etiqueta: '' };
    let pts = 0;
    if (pw.length >= 8)  pts++;
    if (pw.length >= 10) pts++;
    if (pw.length >= 14) pts++;
    const clases = [/[a-z]/, /[A-Z]/, /\d/, /[^A-Za-z0-9]/].filter(r => r.test(pw)).length;
    if (clases >= 2) pts++;
    if (clases >= 3) pts++;
    if (clases >= 4) pts++;
    const nivel = Math.min(4, Math.max(1, Math.round(pts * 4 / 6)));
    const etiqueta = ['', 'Débil', 'Aceptable', 'Fuerte', 'Muy fuerte'][nivel];
    return { nivel, etiqueta };
  }

  customElements.define('ap-auth-form', ApAuthForm);
})();
