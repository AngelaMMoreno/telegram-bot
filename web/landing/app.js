'use strict';

const API = '/api';
const sesion = window.AprentixSession;
const rpc = (fn, body, token) => sesion.rpc(fn, body, { api: API, token });

function mostrarError(id, mensaje) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = mensaje;
  el.hidden = false;
}

document.addEventListener('ap-auth-login', async (evento) => {
  const { username, password } = evento.detail;
  try {
    const respuesta = await rpc('login_web', { p_username: username, p_password: password });
    if (respuesta?.token) sesion.setCookie(sesion.COOKIE_NAME, respuesta.token, sesion.COOKIE_HORAS);
    location.href = '/';
  } catch (error) {
    mostrarError('login-error', error.message || 'No se pudo iniciar sesión');
  }
});

document.addEventListener('ap-auth-register', async (evento) => {
  const { username, password, email, email2 } = evento.detail;
  try {
    await rpc('registrar_web', {
      p_nombre_usuario: username,
      p_password: password,
      p_correo_electronico: email,
      p_correo_electronico_repetido: email2,
    });
    document.querySelector('ap-auth-form')?.setMode('login');
    mostrarError('login-error', 'Cuenta creada. Te enviaremos un correo de confirmación cuando activemos el servicio de email.');
  } catch (error) {
    mostrarError('reg-error', error.message || 'No se pudo crear la cuenta');
  }
});
