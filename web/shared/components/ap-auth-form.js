/*
 * <ap-auth-form> · formulario unificado de login + registro + reset.
 *
 * Adaptado al backend de la SPA remodelada (autenticación por email,
 * sin 2FA). Mantiene la estética solarpunk del componente original:
 * un único card con paneles conmutables, medidor de fortaleza de
 * contraseña y confirmación de email / contraseña al registrar.
 *
 * Uso:
 *   <ap-auth-form mode="login"></ap-auth-form>
 *
 * Eventos:
 *   - 'ap-auth-login'    detail: { email, password }
 *   - 'ap-auth-register' detail: { email, password, nombre_visible }
 *   - 'ap-auth-forgot'   detail: { email }
 *
 * Métodos:
 *   - setMode('login' | 'register' | 'forgot')
 *   - showError(msg, kind = 'login' | 'register' | 'forgot')
 *   - showInfo(msg, kind = 'login' | 'register' | 'forgot')
 *   - reset()
 */
'use strict';

class ApAuthForm extends HTMLElement {
  connectedCallback() {
    if (this._mounted) return;
    this._mounted = true;

    this.innerHTML = `
      <div class="auth-card">
        <div class="auth-hero">
          <span class="brand-logo brand-logo-lg" aria-hidden="true"></span>
          <h1>Aprentix</h1>
          <p class="tagline">Tu oposición, a tu ritmo.</p>
        </div>

        <form class="auth-panel" data-panel="login" autocomplete="on">
          <h2 class="auth-panel-title">Iniciar sesión</h2>
          <label>Email
            <input id="login-email" name="email" type="email"
                   autocomplete="username" required>
          </label>
          <label>Contraseña
            <input id="login-pass" name="password" type="password"
                   autocomplete="current-password" required>
          </label>
          <button class="btn btn-primary" type="submit">Entrar</button>
          <div class="err" data-err="login" hidden></div>
          <div class="info" data-info="login" hidden></div>
          <p class="auth-switch muted small">
            ¿No tienes cuenta?
            <button type="button" class="auth-switch-btn" data-auth-goto="register">Regístrate</button>
          </p>
          <p class="auth-switch muted small">
            <button type="button" class="auth-switch-btn" data-auth-goto="forgot">¿Olvidaste tu contraseña?</button>
          </p>
        </form>

        <form class="auth-panel" data-panel="register" autocomplete="off">
          <h2 class="auth-panel-title">Crear cuenta</h2>
          <label>Nombre a mostrar
            <input id="reg-nombre" name="nombre_visible" type="text"
                   autocomplete="nickname" minlength="2" required>
          </label>
          <label>Email
            <input id="reg-email" name="email" type="email"
                   autocomplete="email" required>
          </label>
          <label>Repite el email
            <input id="reg-email2" name="email2" type="email"
                   autocomplete="email" required>
          </label>
          <p class="pw-match muted small" data-email-match hidden></p>
          <label>Contraseña
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
          <p class="pw-match muted small" data-pw-match hidden></p>
          <button class="btn btn-primary" type="submit">Crear cuenta</button>
          <div class="err" data-err="register" hidden></div>
          <div class="info" data-info="register" hidden></div>
          <p class="auth-switch muted small">
            ¿Ya tienes cuenta?
            <button type="button" class="auth-switch-btn" data-auth-goto="login">Inicia sesión</button>
          </p>
        </form>

        <form class="auth-panel" data-panel="forgot" autocomplete="on">
          <h2 class="auth-panel-title">Recuperar contraseña</h2>
          <p class="muted small" style="text-align:center; margin:0 0 .6rem">
            Introduce tu email y te enviaremos un enlace para restablecerla.
          </p>
          <label>Email
            <input id="forgot-email" name="email" type="email"
                   autocomplete="username" required>
          </label>
          <button class="btn btn-primary" type="submit">Enviar enlace</button>
          <div class="err" data-err="forgot" hidden></div>
          <div class="info" data-info="forgot" hidden></div>
          <p class="auth-switch muted small">
            <button type="button" class="auth-switch-btn" data-auth-goto="login">← Volver al inicio de sesión</button>
          </p>
        </form>
      </div>
    `;

    this._panels     = this.querySelectorAll('.auth-panel');
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

    // Actualizaciones en vivo de la fortaleza y las coincidencias.
    this.querySelector('#reg-pass').addEventListener('input', (e) => {
      this._updateStrength(e.target.value);
      this._updateMatch();
    });
    this.querySelector('#reg-pass2').addEventListener('input', () => this._updateMatch());
    this.querySelector('#reg-email').addEventListener('input',  () => this._updateEmailMatch());
    this.querySelector('#reg-email2').addEventListener('input', () => this._updateEmailMatch());

    this.querySelector('[data-panel="login"]').addEventListener('submit', (e) => {
      e.preventDefault();
      this._clearMessages('login');
      const email    = this.querySelector('#login-email').value.trim();
      const password = this.querySelector('#login-pass').value;
      this.dispatchEvent(new CustomEvent('ap-auth-login', {
        bubbles: true, detail: { email, password },
      }));
    });

    this.querySelector('[data-panel="register"]').addEventListener('submit', (e) => {
      e.preventDefault();
      this._clearMessages('register');
      const nombre_visible = this.querySelector('#reg-nombre').value.trim();
      const email  = this.querySelector('#reg-email').value.trim();
      const email2 = this.querySelector('#reg-email2').value.trim();
      const p1     = this.querySelector('#reg-pass').value;
      const p2     = this.querySelector('#reg-pass2').value;
      if (nombre_visible.length < 2) {
        return this.showError('El nombre debe tener al menos 2 caracteres.', 'register');
      }
      if (email !== email2) {
        return this.showError('Los emails no coinciden.', 'register');
      }
      if (p1 !== p2) {
        return this.showError('Las contraseñas no coinciden.', 'register');
      }
      if (p1.length < 10) {
        return this.showError('La contraseña debe tener al menos 10 caracteres.', 'register');
      }
      const { nivel } = calcularFortaleza(p1);
      if (nivel < 2) {
        return this.showError('Elige una contraseña más fuerte (mezcla mayúsculas, minúsculas, números y símbolos).', 'register');
      }
      this.dispatchEvent(new CustomEvent('ap-auth-register', {
        bubbles: true, detail: { email, password: p1, nombre_visible },
      }));
    });

    this.querySelector('[data-panel="forgot"]').addEventListener('submit', (e) => {
      e.preventDefault();
      this._clearMessages('forgot');
      const email = this.querySelector('#forgot-email').value.trim();
      this.dispatchEvent(new CustomEvent('ap-auth-forgot', {
        bubbles: true, detail: { email },
      }));
    });
  }

  setMode(mode) {
    const valid = ['login', 'register', 'forgot'];
    const target = valid.includes(mode) ? mode : 'login';
    this._panels.forEach(p => p.classList.toggle('active', p.dataset.panel === target));
    if (target === 'register') {
      this._updateStrength(this.querySelector('#reg-pass').value);
    }
    this.setAttribute('mode', target);
  }

  showError(msg, kind = 'login') {
    const el = this.querySelector(`[data-err="${kind}"]`);
    if (!el) return;
    el.textContent = msg;
    el.hidden = false;
    // Oculta info si estaba visible.
    const info = this.querySelector(`[data-info="${kind}"]`);
    if (info) { info.hidden = true; info.textContent = ''; }
  }

  showInfo(msg, kind = 'login') {
    const el = this.querySelector(`[data-info="${kind}"]`);
    if (!el) return;
    el.textContent = msg;
    el.hidden = false;
    const err = this.querySelector(`[data-err="${kind}"]`);
    if (err) { err.hidden = true; err.textContent = ''; }
  }

  _clearMessages(kind) {
    ['err', 'info'].forEach(k => {
      const el = this.querySelector(`[data-${k}="${kind}"]`);
      if (el) { el.textContent = ''; el.hidden = true; }
    });
  }

  reset() {
    this.querySelectorAll('input').forEach(i => { i.value = ''; });
    this._updateStrength('');
    this._updateMatch();
    this._updateEmailMatch();
    ['login', 'register', 'forgot'].forEach(k => this._clearMessages(k));
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

  _updateEmailMatch() {
    if (!this._emailMatch) return;
    const e1 = this.querySelector('#reg-email').value.trim();
    const e2 = this.querySelector('#reg-email2').value.trim();
    if (!e2) { this._emailMatch.hidden = true; return; }
    this._emailMatch.hidden = false;
    if (e1 === e2) {
      this._emailMatch.textContent = '✓ Los emails coinciden';
      this._emailMatch.classList.remove('err'); this._emailMatch.classList.add('ok');
    } else {
      this._emailMatch.textContent = '✗ No coinciden';
      this._emailMatch.classList.remove('ok'); this._emailMatch.classList.add('err');
    }
  }
}

/* Cálculo de fortaleza: longitud + variedad de clases (a-z, A-Z, 0-9, símbolos).
 * No sustituye a zxcvbn; pretende dar al usuario una guía inmediata. */
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
