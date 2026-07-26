/*
 * Aprentix · sesión compartida (rediseño).
 *
 * Cambios respecto al legado:
 *   - Access token JWT (TTL 15 min) vive SÓLO en memoria. Nunca en cookie
 *     ni en localStorage.
 *   - Refresh token (opaco, TTL 14 días) vive en localStorage. En v2 se
 *     moverá a cookie HttpOnly con un bridge — para v1 evitamos el bridge
 *     y aceptamos el trade-off documentado en el plan.
 *   - `rpc(fn, args)` hace refresh automático transparente:
 *       · Si queda poco al access, lo renueva ANTES de la llamada.
 *       · Si la llamada falla con 401, refresca y reintenta 1 vez.
 *   - Sin cookies compartidas de dominio: cada SPA gestiona su sesión.
 *
 * API pública:
 *   AprentixSession.getUser()       → {sub, email_verificado, roles, exp} | null
 *   AprentixSession.setTokens({...})→ almacena tras login/refresh/registro
 *   AprentixSession.clear()         → borra ambos tokens (usar en logout)
 *   AprentixSession.rpc(fn, args)   → POST /rpc/<fn> con Authorization Bearer
 *                                     + refresh transparente
 *   AprentixSession.login(email, password, totp)
 *   AprentixSession.logout()        → RPC logout + clear
 */
'use strict';

(function () {
  if (window.AprentixSession) return;

  const API_BASE = '/api';                             // Caddy reenvía a PostgREST
  const LS_REFRESH = 'aprentix_refresh';               // cookie HttpOnly en v2
  const REFRESH_MARGIN_S = 60;                         // refresca 60s antes de expirar

  // ── Estado en memoria (sobrevive a navegación in-SPA, no a recarga) ──
  let _access = null;
  let _accessExp = 0;
  let _refreshing = null;   // promesa in-flight para deduplicar refresh

  function _parseJwt(tok) {
    try {
      const b64 = tok.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
      const pad = b64.length % 4 ? b64 + '='.repeat(4 - (b64.length % 4)) : b64;
      return JSON.parse(atob(pad));
    } catch (_) { return null; }
  }

  function getUser() {
    if (!_access) return null;
    const c = _parseJwt(_access);
    return c ? { sub: c.sub, email_verificado: c.email_verificado,
                 roles: c.roles || [], exp: c.exp } : null;
  }

  // Devuelve el access token vivo si lo hay (para pasar como Authorization
  // a servicios propios distintos de PostgREST, p.ej. el contenido markdown).
  function getAccess() { return _access; }

  function setTokens({ access_token, access_exp, refresh_token, refresh_exp }) {
    _access = access_token || null;
    _accessExp = access_exp || (_parseJwt(_access)?.exp) || 0;
    if (refresh_token) {
      localStorage.setItem(LS_REFRESH, refresh_token);
    }
    // Notifica a la SPA para refrescar UI (avatar, roles, etc.).
    window.dispatchEvent(new CustomEvent('aprentix:session', { detail: getUser() }));
  }

  function _getRefresh() { return localStorage.getItem(LS_REFRESH); }

  function clear() {
    _access = null; _accessExp = 0;
    localStorage.removeItem(LS_REFRESH);
    window.dispatchEvent(new CustomEvent('aprentix:session', { detail: null }));
  }

  async function _rawRpc(fn, args = {}, token = null) {
    const r = await fetch(`${API_BASE}/rpc/${fn}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify(args),
    });
    const data = await r.json().catch(() => ({}));
    if (!r.ok) {
      const err = new Error(data.message || data.hint || data.details ||
                             data.error || `HTTP ${r.status}`);
      err.status = r.status;
      err.data = data;
      throw err;
    }
    return data;
  }

  // Refresca el access token usando el refresh guardado. Deduplica llamadas
  // concurrentes (si dos rpc() piden refresh a la vez, sólo hacemos uno).
  async function _refresh() {
    if (_refreshing) return _refreshing;
    const rt = _getRefresh();
    if (!rt) throw new Error('sin_sesion');
    _refreshing = (async () => {
      try {
        const data = await _rawRpc('refresh', { p_refresh: rt });
        setTokens(data);
        return data;
      } catch (e) {
        // Si el refresh fue rechazado, cerramos la sesión completa.
        if (e.status === 401 || e.status === 403 || e.status === 400) clear();
        throw e;
      } finally {
        _refreshing = null;
      }
    })();
    return _refreshing;
  }

  function _accessAboutToExpire() {
    const now = Math.floor(Date.now() / 1000);
    return !_access || (_accessExp - now) < REFRESH_MARGIN_S;
  }

  // Wrapper "seguro": refresca proactivamente si toca, y reintenta 1 vez
  // si el servidor responde 401 (por ejemplo, tras un cambio de rol admin).
  async function rpc(fn, args = {}) {
    if (_getRefresh() && _accessAboutToExpire()) {
      try { await _refresh(); } catch (_) { /* seguimos y dejamos que falle si aplica */ }
    }
    try {
      return await _rawRpc(fn, args, _access);
    } catch (e) {
      if (e.status !== 401) throw e;
      if (!_getRefresh()) throw e;
      await _refresh();
      return _rawRpc(fn, args, _access);
    }
  }

  async function login(email, password, totp = null) {
    const data = await _rawRpc('login', {
      p_email: email, p_password: password, p_totp: totp || null,
    });
    setTokens(data);
    return data;
  }

  async function registrar(email, password, nombre_visible) {
    return _rawRpc('registrar', {
      p_email: email, p_password: password, p_nombre_visible: nombre_visible,
    });
  }

  async function verificarEmail(token) {
    return _rawRpc('verificar_email', { p_token: token });
  }

  async function solicitarReset(email) {
    return _rawRpc('solicitar_reset_password', { p_email: email });
  }

  async function resetearPassword(token, nueva) {
    return _rawRpc('resetear_password', { p_token: token, p_nueva: nueva });
  }

  async function logout() {
    const rt = _getRefresh();
    if (rt) {
      try { await _rawRpc('logout', { p_refresh: rt }); } catch (_) { /* idempotente */ }
    }
    clear();
  }

  // Arranque: si hay refresh en localStorage, intenta refresh silencioso.
  async function bootstrap() {
    if (!_getRefresh()) return null;
    try { await _refresh(); return getUser(); }
    catch (_) { return null; }
  }

  window.AprentixSession = {
    API_BASE,
    getUser, getAccess, setTokens, clear,
    rpc,
    login, registrar, verificarEmail, solicitarReset, resetearPassword, logout,
    bootstrap,
  };
})();
