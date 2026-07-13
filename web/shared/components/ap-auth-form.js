/*
 * <ap-auth-form> · formulario unificado de login + registro.
 *
 * Reemplaza el HTML inline que estaba duplicado entre landing y tests.
 * Usa light DOM para que shared/auth.css controle el aspecto y los IDs
 * globales (`login-user`, `reg-pass`, ...) sigan siendo accesibles desde
 * el resto de la SPA si algún flujo antiguo los usa.
 *
 * Uso:
 *   <ap-auth-form mode="login"
 *                 error-login-id="login-error"
 *                 error-register-id="reg-error"></ap-auth-form>
 *
 * Eventos:
 *   - 'ap-auth-login'   detail: { username, password }
 *   - 'ap-auth-register' detail: { username, password, email }
 *
 * Métodos:
 *   - showError(msg, kind = 'login' | 'register')
 *   - setMode('login' | 'register')
 *   - reset()
 */
'use strict';

class ApAuthForm extends HTMLElement {
  connectedCallback() {
    if (this._mounted) return;
    this._mounted = true;

    const errLogin = this.getAttribute('error-login-id') || 'auth-login-error';
    const errReg   = this.getAttribute('error-register-id') || 'auth-register-error';

    this.innerHTML = `
      <div class="auth-card">
        <div class="auth-hero">
          <span class="brand-logo brand-logo-lg" aria-hidden="true"></span>
          <h1>Aprentix</h1>
          <p class="tagline">Tu oposición, a tu ritmo.</p>
        </div>

        <form class="auth-panel" data-panel="login" autocomplete="on">
          <h2 class="auth-panel-title">Iniciar sesión</h2>
          <label>Usuario
            <input id="login-user" name="username" autocomplete="username" required>
          </label>
          <label>Contraseña
            <input id="login-pass" name="password" type="password"
                   autocomplete="current-password" required>
          </label>
          <button class="btn btn-primary" type="submit">Entrar</button>
          <div id="${errLogin}" class="err" hidden></div>
          <p class="auth-switch muted small">
            ¿No tienes cuenta?
            <button type="button" class="auth-switch-btn" data-auth-goto="register">Regístrate</button>
          </p>
        </form>

        <form class="auth-panel" data-panel="register" autocomplete="off">
          <h2 class="auth-panel-title">Crear cuenta</h2>
          <label>Usuario
            <input id="reg-user" name="username" autocomplete="username" minlength="3" required>
          </label>
          <label>Email (opcional)
            <input id="reg-email" name="email" type="email" autocomplete="email">
          </label>
          <label>Contraseña
            <input id="reg-pass" name="password" type="password"
                   autocomplete="new-password" minlength="6" required>
          </label>
          <div class="pw-strength" data-pw-strength aria-live="polite">
            <div class="pw-strength-bar"><span data-pw-strength-fill></span></div>
            <span class="pw-strength-label" data-pw-strength-label>Introduce una contraseña</span>
          </div>
          <label>Repite la contraseña
            <input id="reg-pass2" name="password2" type="password"
                   autocomplete="new-password" minlength="6" required>
          </label>
          <p class="pw-match muted small" data-pw-match hidden></p>
          <button class="btn btn-primary" type="submit">Crear cuenta</button>
          <div id="${errReg}" class="err" hidden></div>
          <p class="auth-switch muted small">
            ¿Ya tienes cuenta?
            <button type="button" class="auth-switch-btn" data-auth-goto="login">Inicia sesión</button>
          </p>
        </form>
      </div>
    `;

    this._panels = this.querySelectorAll('.auth-panel');
    this._pwStrength = this.querySelector('[data-pw-strength]');
    this._pwFill     = this.querySelector('[data-pw-strength-fill]');
    this._pwLabel    = this.querySelector('[data-pw-strength-label]');
    this._pwMatch    = this.querySelector('[data-pw-match]');

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

    this.querySelector('[data-panel="login"]').addEventListener('submit', (e) => {
      e.preventDefault();
      const username = this.querySelector('#login-user').value.trim();
      const password = this.querySelector('#login-pass').value;
      this.dispatchEvent(new CustomEvent('ap-auth-login', {
        bubbles: true, detail: { username, password },
      }));
    });

    this.querySelector('[data-panel="register"]').addEventListener('submit', (e) => {
      e.preventDefault();
      const username = this.querySelector('#reg-user').value.trim();
      const email    = this.querySelector('#reg-email').value.trim() || null;
      const p1       = this.querySelector('#reg-pass').value;
      const p2       = this.querySelector('#reg-pass2').value;
      if (p1 !== p2) return this.showError('Las contraseñas no coinciden', 'register');
      const { nivel } = calcularFortaleza(p1);
      if (nivel < 2) return this.showError('Elige una contraseña más fuerte', 'register');
      this.dispatchEvent(new CustomEvent('ap-auth-register', {
        bubbles: true, detail: { username, password: p1, email },
      }));
    });
  }

  setMode(mode) {
    const target = mode === 'register' ? 'register' : 'login';
    this._panels.forEach(p => p.classList.toggle('active', p.dataset.panel === target));
    if (target === 'register') {
      this._updateStrength(this.querySelector('#reg-pass').value);
    }
    this.setAttribute('mode', target);
  }

  showError(msg, kind = 'login') {
    const errLogin = this.getAttribute('error-login-id') || 'auth-login-error';
    const errReg   = this.getAttribute('error-register-id') || 'auth-register-error';
    const id = kind === 'register' ? errReg : errLogin;
    const el = this.querySelector('#' + CSS.escape(id));
    if (!el) return;
    el.textContent = msg;
    el.hidden = false;
  }

  clearErrors() {
    this.querySelectorAll('.err').forEach(el => { el.textContent = ''; el.hidden = true; });
  }

  reset() {
    this.querySelectorAll('input').forEach(i => { i.value = ''; });
    this._updateStrength('');
    this._updateMatch();
    this.clearErrors();
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
      this._pwMatch.textContent = '✗ No coinciden';
      this._pwMatch.classList.remove('ok'); this._pwMatch.classList.add('err');
    }
  }
}

/* Cálculo de fortaleza: longitud + variedad de clases (a-z, A-Z, 0-9, símbolos).
 * No sustituye a zxcvbn; pretende dar al usuario una guía inmediata. */
function calcularFortaleza(pw) {
  if (!pw) return { nivel: 0, etiqueta: '' };
  let pts = 0;
  if (pw.length >= 6) pts++;
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
