"""Aprentix · mailer
====================

Servicio residente que escucha `LISTEN email_enviar` en Postgres y envía
transaccionales (verificación de email y reset de contraseña).

Diseño:
  * La BD sigue siendo la fuente de verdad. Las RPCs `registrar`,
    `solicitar_reset_password` y `forzar_reset_password` insertan el token
    hasheado y hacen `pg_notify('email_enviar', json_payload)`.
  * Este proceso hace `LISTEN email_enviar`, recibe el payload con el
    token en claro (sólo viaja una vez, no se persiste) y envía por SMTP.
  * Si perdemos una notificación (reconexión, reinicio), no la
    recuperamos: el usuario tiene que volver a pedir el email. Sencillez
    frente a exactamente-una-vez; la fricción es baja porque el flujo
    tiene botón "reenviar".
  * SMTP genérico configurable por env — cualquier proveedor sirve
    (SES, Mailgun, Postmark, Postfix propio…).

Variables de entorno:
  DATABASE_URL       postgres://aprentix@db:5432/aprentix_desa
  PGPASSWORD         contraseña del rol aprentix
  SMTP_HOST          host del servidor SMTP
  SMTP_PORT          puerto (default 587)
  SMTP_USER          usuario SMTP
  SMTP_PASS          contraseña SMTP
  SMTP_FROM          "Aprentix <hola@aprentix.es>"
  SMTP_TLS           "starttls" (default), "ssl" o "off"
  DEV_LOG_ONLY       si "1", en lugar de enviar imprime el email en logs
                     (útil para arranque local sin SMTP configurado)
"""
from __future__ import annotations

import json
import logging
import os
import select
import signal
import smtplib
import ssl
import sys
import time
from email.message import EmailMessage
from typing import Any

import psycopg


log = logging.getLogger("mailer")
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)

DSN          = os.environ["DATABASE_URL"]
SMTP_HOST    = os.getenv("SMTP_HOST", "")
SMTP_PORT    = int(os.getenv("SMTP_PORT", "587"))
SMTP_USER    = os.getenv("SMTP_USER", "")
SMTP_PASS    = os.getenv("SMTP_PASS", "")
SMTP_FROM    = os.getenv("SMTP_FROM", "Aprentix <hola@aprentix.es>")
SMTP_TLS     = os.getenv("SMTP_TLS", "starttls").lower()
DEV_LOG_ONLY = os.getenv("DEV_LOG_ONLY", "0") == "1"


# ── Plantillas de email ─────────────────────────────────────────────────────
# Las URLs se construyen con `web_url_base` del payload — el destino final
# lo elige la RPC según el entorno (staging / producción / local).

_SUBJECTS = {
    "verificar_email": "Confirma tu cuenta en Aprentix",
    "reset_password":  "Restablece tu contraseña de Aprentix",
}


def _cuerpos(tipo: str, nombre: str, url: str) -> tuple[str, str]:
    """Devuelve (text, html) para el tipo de email dado."""
    if tipo == "verificar_email":
        text = (
            f"Hola {nombre},\n\n"
            f"Bienvenida a Aprentix. Confirma tu cuenta pulsando el enlace:\n\n"
            f"    {url}\n\n"
            f"El enlace caduca en 30 minutos. Si no eres tú, ignora este correo.\n\n"
            f"— Aprentix"
        )
        html = f"""\
<html><body style="font-family:sans-serif;line-height:1.5;color:#111">
<p>Hola {nombre},</p>
<p>Bienvenida a Aprentix. Confirma tu cuenta pulsando el botón:</p>
<p><a href="{url}" style="background:#6B8E23;color:#fff;padding:10px 18px;
       border-radius:6px;text-decoration:none">Verificar mi cuenta</a></p>
<p style="color:#666;font-size:0.9em">El enlace caduca en 30 minutos.
Si no eres tú, ignora este correo.</p>
<p style="color:#666;font-size:0.9em">— Aprentix</p>
</body></html>"""
        return text, html

    if tipo == "reset_password":
        text = (
            f"Hola {nombre},\n\n"
            f"Has solicitado restablecer tu contraseña. Pulsa el enlace:\n\n"
            f"    {url}\n\n"
            f"El enlace caduca en 30 minutos. Si no fuiste tú, ignora este correo\n"
            f"y considera revisar la seguridad de tu cuenta.\n\n"
            f"— Aprentix"
        )
        html = f"""\
<html><body style="font-family:sans-serif;line-height:1.5;color:#111">
<p>Hola {nombre},</p>
<p>Has solicitado restablecer tu contraseña. Pulsa el botón:</p>
<p><a href="{url}" style="background:#6B8E23;color:#fff;padding:10px 18px;
       border-radius:6px;text-decoration:none">Restablecer contraseña</a></p>
<p style="color:#666;font-size:0.9em">El enlace caduca en 30 minutos.
Si no fuiste tú, ignora este correo.</p>
<p style="color:#666;font-size:0.9em">— Aprentix</p>
</body></html>"""
        return text, html

    raise ValueError(f"tipo de email desconocido: {tipo}")


def _construir_url(web_url_base: str, tipo: str, token: str) -> str:
    # La SPA usa hash-routing: /#/verify?token=…  Sin el `#` el navegador
    # entra a /verify?token=…, el bootstrap no ve `location.hash` y redirige
    # a #/login descartando el token, por lo que la RPC verificar_email nunca
    # llega a ejecutarse y el usuario ve "email no verificado" al entrar.
    base = (web_url_base or "").rstrip("/")
    path = {
        "verificar_email": "#/verify",
        "reset_password":  "#/reset",
    }[tipo]
    return f"{base}/{path}?token={token}"


# ── Envío SMTP ─────────────────────────────────────────────────────────────

def _enviar_smtp(to: str, subject: str, text: str, html: str) -> None:
    msg = EmailMessage()
    msg["From"]    = SMTP_FROM
    msg["To"]      = to
    msg["Subject"] = subject
    msg.set_content(text)
    msg.add_alternative(html, subtype="html")

    if DEV_LOG_ONLY or not SMTP_HOST:
        log.info("DEV_LOG_ONLY — email no enviado. destino=%s asunto=%s\n%s",
                 to, subject, text)
        return

    if SMTP_TLS == "ssl":
        ctx = ssl.create_default_context()
        with smtplib.SMTP_SSL(SMTP_HOST, SMTP_PORT, context=ctx, timeout=15) as s:
            if SMTP_USER:
                s.login(SMTP_USER, SMTP_PASS)
            s.send_message(msg)
    else:
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=15) as s:
            s.ehlo()
            if SMTP_TLS == "starttls":
                s.starttls(context=ssl.create_default_context())
                s.ehlo()
            if SMTP_USER:
                s.login(SMTP_USER, SMTP_PASS)
            s.send_message(msg)


def _procesar(payload: dict[str, Any]) -> None:
    tipo   = payload["tipo"]
    email  = payload["email"]
    nombre = payload.get("nombre_visible") or "estudiante"
    token  = payload["token"]
    base   = payload.get("web_url_base") or "https://aprentix.es"

    url = _construir_url(base, tipo, token)
    text, html = _cuerpos(tipo, nombre, url)
    _enviar_smtp(email, _SUBJECTS[tipo], text, html)
    log.info("email enviado tipo=%s destino=%s", tipo, email)


# ── Loop LISTEN ────────────────────────────────────────────────────────────

_should_stop = False


def _stop(signum, _frame):
    global _should_stop
    log.info("señal %s recibida, saliendo…", signum)
    _should_stop = True


def _loop() -> None:
    """Bucle LISTEN con reconexión exponencial ante fallos."""
    backoff = 1
    while not _should_stop:
        try:
            with psycopg.connect(DSN, autocommit=True) as conn:
                log.info("conectado a la BD, LISTEN email_enviar")
                conn.execute("LISTEN email_enviar;")
                backoff = 1
                while not _should_stop:
                    if select.select([conn.fileno()], [], [], 5) == ([], [], []):
                        continue
                    for note in conn.notifies():
                        try:
                            payload = json.loads(note.payload)
                            _procesar(payload)
                        except Exception:
                            log.exception("fallo procesando notificación")
        except Exception:
            log.exception("fallo de conexión al listener, retry en %ss", backoff)
            for _ in range(backoff):
                if _should_stop:
                    return
                time.sleep(1)
            backoff = min(backoff * 2, 60)


def main() -> int:
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT,  _stop)
    log.info("mailer arrancado (dev_log_only=%s, smtp=%s:%s)",
             DEV_LOG_ONLY, SMTP_HOST or "(sin configurar)", SMTP_PORT)
    _loop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
