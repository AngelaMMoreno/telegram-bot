/*
 * Aprentix · sesión y llamadas RPC.
 *
 * Único módulo que sabe de cookies, JWT y PostgREST — todo lo demás
 * usa window.AprentixSession.rpc(fn, args).  Se carga como script
 * clásico antes que app.js.
 */
'use strict';

(function () {
  if (window.AprentixSession) return;

  const COOKIE_NAME  = 'aprentix_token';
  const COOKIE_HORAS = 12;                 // coincide con la expiración del JWT

  function cookieDomain() {
    const parts = location.hostname.split('.');
    return parts.length >= 2 ? '.' + parts.slice(-2).join('.') : '';
  }

  function getCookie(name) {
    for (const raw of document.cookie.split(';')) {
      const [k, ...v] = raw.trim().split('=');
      if (k === name) return decodeURIComponent(v.join('='));
    }
    return null;
  }

  function setCookie(name, value, horas) {
    const dom = cookieDomain();
    const attrs = [
      `Max-Age=${Math.round(horas * 3600)}`,
      'Path=/',
      'SameSite=Lax',
      location.protocol === 'https:' ? 'Secure' : '',
      dom ? `Domain=${dom}` : '',
    ].filter(Boolean);
    document.cookie = `${name}=${encodeURIComponent(value)}; ${attrs.join('; ')}`;
  }

  function deleteCookie(name) {
    const dom = cookieDomain();
    document.cookie = `${name}=; Max-Age=0; Path=/; ${dom ? 'Domain=' + dom : ''}`;
    document.cookie = `${name}=; Max-Age=0; Path=/`;
  }

  function parseJwt(tok) {
    try {
      const b64 = tok.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
      const pad = b64.length % 4 ? b64 + '='.repeat(4 - (b64.length % 4)) : b64;
      return JSON.parse(atob(pad));
    } catch (_) { return null; }
  }

  const getToken   = () => getCookie(COOKIE_NAME);
  const setToken   = (t, horas = COOKIE_HORAS) => setCookie(COOKIE_NAME, t, horas);
  const clearToken = () => deleteCookie(COOKIE_NAME);

  /*
   * rpc(fn, args, opts) → JSON de PostgREST.
   *   opts.api    → base ('/api' por defecto).
   *   opts.token  → sobreescribe el token; pasa null para llamadas
   *                 anónimas (login, registro).
   * Lanza Error(message||hint||details||HTTP nnn) si !ok.
   */
  async function rpc(fn, args = {}, opts = {}) {
    const api = opts.api || '/api';
    const token = opts.token !== undefined ? opts.token : getToken();
    const r = await fetch(`${api}/rpc/${fn}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify(args),
      signal: opts.signal,
    });
    const data = await r.json().catch(() => ({}));
    if (!r.ok) {
      const msg = data.message || data.hint || data.details || data.error || `HTTP ${r.status}`;
      const err = new Error(msg);
      err.status = r.status;
      err.data = data;
      throw err;
    }
    return data;
  }

  window.AprentixSession = {
    COOKIE_NAME, COOKIE_HORAS,
    cookieDomain,
    getCookie, setCookie, deleteCookie,
    parseJwt,
    getToken, setToken, clearToken,
    rpc,
  };
})();
