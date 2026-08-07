"""
Aprentix · notificador (Web Push).
==================================

Worker residente que consume la tabla `cola_push` de la BBDD y envía
cada fila como Web Push VAPID a todas las suscripciones activas del
destinatario. La BBDD es la única cola: la SPA (o la RPC
`push_enviar_prueba`) insertan filas y este servicio las procesa.

Ciclo por tick (TICK_SECONDS, por defecto 60 s):

  1. SELECT ... FROM cola_push WHERE enviado_en IS NULL
       AND intentos < max_intentos ORDER BY encolado_en LIMIT BATCH.
  2. Para cada fila, envía Web Push a cada suscripción activa del usuario.
     - 404/410 desactiva la suscripción (el navegador la tiró).
  3. Marca la fila como enviada o incrementa `intentos` con `ultimo_error`.

Además del envío, actúa como CRON INTERNO llamando a las RPCs
programadas de la BBDD:
  - Cada `ENCOLAR_MINUTOS` (default 15 min) → `encolar_notificaciones_diarias()`
    (avisos a inactivos + resumen dominical).
  - Los lunes a las 3:00 UTC → `cron_semanal()` (calcula métricas
    semanales de todos y aplica ajuste de carga).

Variables de entorno:
  DATABASE_URL         postgres://aprentix@db-<alias>:5432/<db_name>
  PGPASSWORD           contraseña del rol de conexión
  VAPID_PRIVATE_KEY    clave privada VAPID (PEM con saltos reales o "\\n")
  VAPID_PUBLIC_KEY     solo para log (opcional)
  VAPID_SUBJECT        mailto:soporte@aprentix.es
  TICK_SECONDS         intervalo del envío de push (default 300)
  BATCH_LIMIT          máximo de mensajes por tick (default 500)
  ENCOLAR_MINUTOS      cada cuánto encolar avisos (default 15)
  CRON_SEMANAL_HORA    hora UTC del cron semanal (default 3)
"""

from __future__ import annotations

import base64
import json
import logging
import os
import signal
import sys
import time

import psycopg
from pywebpush import WebPushException, webpush


# ── Utilidades ──────────────────────────────────────────────────────

def _normalizar_vapid_key(raw: str) -> str:
    """Acepta la clave privada VAPID en PEM (multilínea o con '\\n'
    literales) o base64 del PEM entero; devuelve siempre PEM con
    saltos reales, que es lo que espera cryptography."""
    s = raw.strip()
    if "-----BEGIN" in s and "\n" in s:
        return s
    if "-----BEGIN" in s and "\\n" in s:
        return s.replace("\\n", "\n")
    try:
        pad = "=" * ((4 - len(s) % 4) % 4)
        decoded = base64.b64decode(s + pad).decode("utf-8")
        if "-----BEGIN" in decoded:
            return decoded
    except Exception:  # noqa: BLE001
        pass
    raise SystemExit(
        "VAPID_PRIVATE_KEY no reconocida. Pega un PEM (con saltos "
        "reales o '\\n' literales) o el PEM entero en base64."
    )


DATABASE_URL      = os.environ["DATABASE_URL"]
VAPID_PRIVATE_KEY = _normalizar_vapid_key(os.environ["VAPID_PRIVATE_KEY"])
VAPID_SUBJECT     = os.environ.get("VAPID_SUBJECT", "mailto:soporte@aprentix.es")
TICK_SECONDS      = int(os.environ.get("TICK_SECONDS", "300"))
BATCH_LIMIT       = int(os.environ.get("BATCH_LIMIT", "500"))
ENCOLAR_MINUTOS   = int(os.environ.get("ENCOLAR_MINUTOS", "15"))
CRON_SEMANAL_HORA = int(os.environ.get("CRON_SEMANAL_HORA", "3"))


logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s :: %(message)s",
)
log = logging.getLogger("notificador")


def _enviar_a_suscripciones(cn: psycopg.Connection, usuario_id: str,
                            payload: dict) -> tuple[int, str | None]:
    """Envía payload a todas las suscripciones activas del usuario.
    Devuelve (num_ok, ultimo_error). Desactiva suscripciones caducas."""
    with cn.cursor() as cur:
        cur.execute(
            "SELECT endpoint, p256dh, auth FROM push_suscripciones "
            "WHERE usuario_id = %s AND activa",
            (usuario_id,),
        )
        subs = cur.fetchall()
    if not subs:
        return 0, "sin_suscripciones_activas"

    ok = 0
    err_final: str | None = None
    for endpoint, p256dh, auth in subs:
        info = {"endpoint": endpoint, "keys": {"p256dh": p256dh, "auth": auth}}
        try:
            webpush(
                subscription_info=info,
                data=json.dumps(payload),
                vapid_private_key=VAPID_PRIVATE_KEY,
                vapid_claims={"sub": VAPID_SUBJECT},
                ttl=3600,
            )
            ok += 1
            with cn.cursor() as cur:
                cur.execute(
                    "UPDATE push_suscripciones SET ultima_ok_en = now() "
                    "WHERE endpoint = %s",
                    (endpoint,),
                )
        except WebPushException as e:
            status = getattr(e.response, "status_code", None)
            err_final = f"HTTP {status}: {e}"[:900]
            if status in (404, 410):
                with cn.cursor() as cur:
                    cur.execute(
                        "UPDATE push_suscripciones SET activa = false, "
                        "ultimo_error = %s WHERE endpoint = %s",
                        (err_final, endpoint),
                    )
                log.info("suscripción caducada endpoint=%s", endpoint)
        except Exception as e:  # noqa: BLE001
            err_final = str(e)[:900]
    cn.commit()
    return ok, err_final


def _tick(cn: psycopg.Connection) -> int:
    """Procesa un lote de push pendientes. Devuelve cuántos entregó."""
    with cn.cursor() as cur:
        cur.execute(
            """
            SELECT id, usuario_id, titulo, cuerpo, url, icono
              FROM cola_push
             WHERE enviado_en IS NULL AND intentos < max_intentos
             ORDER BY encolado_en
             LIMIT %s
             FOR UPDATE SKIP LOCKED
            """,
            (BATCH_LIMIT,),
        )
        pendientes = cur.fetchall()

    entregados = 0
    for row_id, usuario_id, titulo, cuerpo, url, icono in pendientes:
        payload = {"title": titulo, "body": cuerpo, "url": url, "icon": icono}
        ok, err = _enviar_a_suscripciones(cn, str(usuario_id), payload)
        with cn.cursor() as cur:
            if ok > 0:
                cur.execute(
                    "UPDATE cola_push SET enviado_en = now(), "
                    "intentos = intentos + 1 WHERE id = %s",
                    (row_id,),
                )
                entregados += 1
                log.info("entregado id=%s destinos=%d", row_id, ok)
            else:
                cur.execute(
                    "UPDATE cola_push SET intentos = intentos + 1, "
                    "ultimo_error = %s WHERE id = %s",
                    (err or "sin_destinos", row_id),
                )
                log.warning("fallo id=%s error=%s", row_id, err)
        cn.commit()
    return entregados


def _encolar_avisos(cn: psycopg.Connection) -> int:
    """Llama a la RPC que genera las filas de cola_push para
    inactivos + resumen dominical. Devuelve nº encolado."""
    try:
        with cn.cursor() as cur:
            cur.execute("SELECT encolar_notificaciones_diarias()")
            n = cur.fetchone()[0]
        cn.commit()
        if n:
            log.info("encolar_notificaciones_diarias → %s avisos", n)
        return int(n or 0)
    except Exception as e:  # noqa: BLE001
        cn.rollback()
        log.warning("fallo encolar_notificaciones_diarias: %s", e)
        return 0


def _cron_semanal(cn: psycopg.Connection) -> None:
    """Ejecuta métricas + ajuste de carga los lunes a la hora
    configurada. Silencioso si ya se hizo hoy."""
    try:
        with cn.cursor() as cur:
            cur.execute("SELECT cron_semanal()")
            row = cur.fetchone()
        cn.commit()
        log.info("cron_semanal → %s", row[0] if row else "-")
    except Exception as e:  # noqa: BLE001
        cn.rollback()
        log.warning("fallo cron_semanal: %s", e)


def main() -> int:
    log.info(
        "arranca notificador subject=%s batch_limit=%s tick=%ss encolar_cada=%smin cron_semanal=lunes-%sh",
        VAPID_SUBJECT, BATCH_LIMIT, TICK_SECONDS, ENCOLAR_MINUTOS, CRON_SEMANAL_HORA,
    )

    stop = {"flag": False}
    def _handler(signum, _frame):  # noqa: ARG001
        log.info("recibida señal %s — cerrando", signum)
        stop["flag"] = True
    signal.signal(signal.SIGTERM, _handler)
    signal.signal(signal.SIGINT,  _handler)

    encolar_seg = ENCOLAR_MINUTOS * 60
    last_encolar = 0.0
    ultimo_dia_cron = None            # (year, isoweek) evita repetir

    while not stop["flag"]:
        try:
            with psycopg.connect(DATABASE_URL, autocommit=False) as cn:
                while not stop["flag"]:
                    ahora = time.time()

                    # 1) Envío de push pendientes.
                    _tick(cn)

                    # 2) Encolar avisos cada ENCOLAR_MINUTOS.
                    if ahora - last_encolar >= encolar_seg:
                        _encolar_avisos(cn)
                        last_encolar = ahora

                    # 3) Cron semanal (lunes a las CRON_SEMANAL_HORA UTC).
                    tm = time.gmtime(ahora)
                    if tm.tm_wday == 0 and tm.tm_hour == CRON_SEMANAL_HORA:
                        clave = (tm.tm_year, tm.tm_yday)
                        if clave != ultimo_dia_cron:
                            _cron_semanal(cn)
                            ultimo_dia_cron = clave

                    time.sleep(TICK_SECONDS)
        except psycopg.OperationalError as e:
            log.error("BBDD inalcanzable (%s); reintento en 10 s", e)
            time.sleep(10)
        except Exception as e:  # noqa: BLE001
            log.exception("error en el ciclo principal: %s", e)
            time.sleep(15)

    log.info("notificador detenido")
    return 0


if __name__ == "__main__":
    sys.exit(main())
