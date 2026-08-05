"""
Aprentix · mailer
=================

Worker residente que consume la tabla `cola_emails` de la BBDD y envía
cada fila vía SMTP.  La BBDD es la única cola: la SPA/PostgREST solo
insertan filas; este servicio las procesa.

Ciclo por tick (TICK_SECONDS, por defecto 30 s):

  1. SELECT ... FROM cola_emails WHERE enviado_en IS NULL
       AND intentos < max_intentos ORDER BY encolado_en LIMIT BATCH.
  2. Para cada fila:
       - Envía por SMTP (STARTTLS o SSL, según SMTP_TLS).
       - Éxito → UPDATE enviado_en = now().
       - Error → UPDATE intentos += 1, ultimo_error = <msg>.
  3. Duerme TICK_SECONDS y repite.

Variables de entorno:
  DATABASE_URL     postgres://aprentix@db:5432/aprentix_desa
  PGPASSWORD       contraseña del rol de conexión
  SMTP_HOST        smtp.gmail.com
  SMTP_PORT        587
  SMTP_USER        usuario SMTP
  SMTP_PASS        contraseña SMTP
  SMTP_FROM        "No Contestar <no-reply@aprentix.es>"
  SMTP_TLS         starttls | ssl | none  (default: starttls)
  TICK_SECONDS     intervalo entre ciclos (default: 30)
  BATCH            máximo de emails por tick (default: 25)
"""

from __future__ import annotations

import logging
import os
import signal
import smtplib
import ssl
import sys
import time
from email.message import EmailMessage
from email.utils import formataddr, parseaddr

import psycopg


DATABASE_URL = os.environ["DATABASE_URL"]
SMTP_HOST    = os.environ["SMTP_HOST"]
SMTP_PORT    = int(os.environ.get("SMTP_PORT", "587"))
SMTP_USER    = os.environ.get("SMTP_USER") or None
SMTP_PASS    = os.environ.get("SMTP_PASS") or None
SMTP_FROM    = os.environ.get("SMTP_FROM", "No Contestar <no-reply@aprentix.es>")
SMTP_TLS     = os.environ.get("SMTP_TLS", "starttls").lower()  # starttls|ssl|none
TICK_SECONDS = int(os.environ.get("TICK_SECONDS", "30"))
BATCH        = int(os.environ.get("BATCH", "25"))


logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s :: %(message)s",
)
log = logging.getLogger("mailer")


def _abrir_smtp() -> smtplib.SMTP:
    """Abre una sesión SMTP negociando TLS según la configuración.

    STARTTLS y puerto 587 es lo común (Gmail, Zoho, la mayoría de
    proveedores).  SSL implícito va en 465.  `none` es SOLO para
    entornos de test con un relay local sin cifrado.
    """
    if SMTP_TLS == "ssl":
        s = smtplib.SMTP_SSL(SMTP_HOST, SMTP_PORT, context=ssl.create_default_context(), timeout=30)
    else:
        s = smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=30)
        s.ehlo()
        if SMTP_TLS == "starttls":
            s.starttls(context=ssl.create_default_context())
            s.ehlo()
    if SMTP_USER and SMTP_PASS:
        s.login(SMTP_USER, SMTP_PASS)
    return s


def _construir_msg(destinatario: str, asunto: str, txt: str, html: str | None) -> EmailMessage:
    msg = EmailMessage()
    nombre_from, addr_from = parseaddr(SMTP_FROM)
    msg["From"] = formataddr((nombre_from or "Aprentix", addr_from or SMTP_FROM))
    msg["To"] = destinatario
    msg["Subject"] = asunto
    msg.set_content(txt or "")
    if html:
        msg.add_alternative(html, subtype="html")
    return msg


def _tick(cn: psycopg.Connection) -> int:
    """Procesa un lote de emails pendientes. Devuelve cuántos envió."""
    with cn.cursor() as cur:
        cur.execute(
            """
            SELECT id, destinatario, asunto, cuerpo_txt, cuerpo_html
              FROM cola_emails
             WHERE enviado_en IS NULL AND intentos < max_intentos
             ORDER BY encolado_en
             LIMIT %s
             FOR UPDATE SKIP LOCKED
            """,
            (BATCH,),
        )
        pendientes = cur.fetchall()
    if not pendientes:
        return 0

    enviados = 0
    smtp = None
    try:
        smtp = _abrir_smtp()
        for row_id, destinatario, asunto, txt, html in pendientes:
            msg = _construir_msg(destinatario, asunto, txt, html)
            try:
                smtp.send_message(msg)
                with cn.cursor() as cur:
                    cur.execute(
                        "UPDATE cola_emails SET enviado_en = now(), intentos = intentos + 1 "
                        "WHERE id = %s",
                        (row_id,),
                    )
                cn.commit()
                enviados += 1
                log.info("enviado id=%s destinatario=%s asunto=%r", row_id, destinatario, asunto)
            except Exception as e:  # noqa: BLE001
                cn.rollback()
                with cn.cursor() as cur:
                    cur.execute(
                        "UPDATE cola_emails SET intentos = intentos + 1, ultimo_error = %s "
                        "WHERE id = %s",
                        (str(e)[:1000], row_id),
                    )
                cn.commit()
                log.warning("fallo id=%s destinatario=%s error=%s", row_id, destinatario, e)
    finally:
        if smtp is not None:
            try:
                smtp.quit()
            except Exception:  # noqa: BLE001
                pass
    return enviados


def main() -> int:
    log.info(
        "arranca mailer host=%s puerto=%s tls=%s from=%s batch=%s tick=%ss",
        SMTP_HOST, SMTP_PORT, SMTP_TLS, SMTP_FROM, BATCH, TICK_SECONDS,
    )
    # SIGTERM/SIGINT para parada limpia (Docker lo envía al detener).
    stop = {"flag": False}

    def _handler(signum, _frame):  # noqa: ARG001
        log.info("recibida señal %s — cerrando", signum)
        stop["flag"] = True

    signal.signal(signal.SIGTERM, _handler)
    signal.signal(signal.SIGINT, _handler)

    while not stop["flag"]:
        try:
            with psycopg.connect(DATABASE_URL, autocommit=False) as cn:
                while not stop["flag"]:
                    enviados = _tick(cn)
                    if enviados == 0:
                        # nada que hacer → duerme; con carga alta el sleep
                        # se reduce implícitamente porque BATCH se llena.
                        time.sleep(TICK_SECONDS)
        except psycopg.OperationalError as e:
            log.error("BBDD inalcanzable (%s); reintento en 10 s", e)
            time.sleep(10)
        except Exception as e:  # noqa: BLE001
            log.exception("error en el ciclo principal: %s", e)
            time.sleep(15)

    log.info("mailer detenido")
    return 0


if __name__ == "__main__":
    sys.exit(main())
