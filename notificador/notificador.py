"""
Aprentix · notificador
======================

Servicio residente que, cada N minutos:
  1. Comprueba si estamos dentro de la ventana horaria (Europe/Madrid por
     defecto) mediante _push_en_ventana() en la BBDD.
  2. Consulta candidatos a recibir push:
       - push_candidatos_repaso()      → tienen preguntas de repaso vencidas.
       - push_candidatos_inactividad() → llevan demasiadas horas sin entrar.
  3. Para cada candidato, envía un Web Push firmado con VAPID a todas sus
     suscripciones activas (pywebpush).
  4. Registra el envío en push_envios (para el rate-limit) y desactiva las
     suscripciones que devuelvan 404/410 (el navegador las tiró).

La BBDD es la fuente de verdad para *cuándo* y *a quién* avisar: la ventana,
el mínimo de vencidas y los cooldowns viven en la tabla `config`. Cambiar
un valor allí surte efecto en el siguiente tick sin redeploy.

Variables de entorno:
  DATABASE_URL          postgresql://aprentix@db:5432/aprentix
  PGPASSWORD            (contraseña del rol aprentix)
  VAPID_PRIVATE_KEY     clave privada VAPID en formato PEM (una línea con \\n)
  VAPID_PUBLIC_KEY      clave pública VAPID (opcional, solo para log)
  VAPID_SUBJECT         mailto:soporte@aprentix.es
  TICK_SECONDS          intervalo entre ciclos (default 300 = 5 min)
"""

from __future__ import annotations

import json
import logging
import os
import signal
import sys
import time
from dataclasses import dataclass
from typing import Iterable

import base64

import psycopg
from pywebpush import WebPushException, webpush


# ── Configuración desde entorno ────────────────────────────────────────────

def _normalizar_vapid_key(raw: str) -> str:
    """
    Acepta la clave privada VAPID en cualquiera de estos formatos:

      1) PEM con saltos REALES:
             -----BEGIN PRIVATE KEY-----
             MIGHA...
             -----END PRIVATE KEY-----
         (funciona si tu backend de secretos permite valores multilínea)

      2) PEM con '\\n' LITERALES:
             -----BEGIN PRIVATE KEY-----\\nMIGHA...\\n-----END PRIVATE KEY-----\\n
         (necesario en .env de Dokploy y en la mayoría de UIs de secretos,
          porque los .env no soportan valores multilínea sin escape).

      3) Base64 del PEM entero:
             LS0tLS1CRUdJTiBQUklWQVRFI...
         (útil si tu UI escapa mal las barras: base64 no tiene ni '/' ni
          saltos que confundan al parser)

    Devuelve siempre PEM con saltos reales, que es lo que espera
    pywebpush → cryptography.
    """
    s = raw.strip()

    # 1) Ya viene con saltos reales.
    if "-----BEGIN" in s and "\n" in s:
        return s

    # 2) Saltos codificados como '\n' literales (dos caracteres).
    if "-----BEGIN" in s and "\\n" in s:
        return s.replace("\\n", "\n")

    # 3) Base64 del PEM entero.
    try:
        # Padding tolerante (algunos generadores omiten '=').
        pad = "=" * ((4 - len(s) % 4) % 4)
        decoded = base64.b64decode(s + pad).decode("utf-8")
        if "-----BEGIN" in decoded:
            return decoded
    except Exception:  # noqa: BLE001
        pass

    raise SystemExit(
        "VAPID_PRIVATE_KEY no reconocida. Debe ser un PEM (con saltos reales "
        "o con '\\n' literales) o el PEM entero codificado en base64."
    )


DATABASE_URL      = os.environ["DATABASE_URL"]
VAPID_PRIVATE_KEY = _normalizar_vapid_key(os.environ["VAPID_PRIVATE_KEY"])
VAPID_SUBJECT     = os.environ.get("VAPID_SUBJECT", "mailto:soporte@aprentix.es")
TICK_SECONDS      = int(os.environ.get("TICK_SECONDS", "300"))
BATCH_LIMIT       = int(os.environ.get("BATCH_LIMIT",  "500"))

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("notificador")


# ── Textos motivacionales ──────────────────────────────────────────────────
# Deliberadamente cortos: en Android e iOS solo se ven ~2 líneas.

def payload_repaso(n_vencidas: int) -> dict:
    return {
        "title": "🌱 Toca repaso",
        "body":  (f"Tienes {n_vencidas} preguntas listas para repasar. "
                  "¡Vamos a por ellas!"),
        "tag":   "repaso",
        "url":   "/?atajo=repasar",
    }


def payload_inactividad(dias: int) -> dict:
    if dias <= 1:
        cuerpo = "Ha pasado un día. Unos minutos y no pierdes la racha."
    elif dias <= 3:
        cuerpo = f"Llevas {dias} días fuera. Vuelve poco a poco: 5 preguntas cuentan."
    else:
        cuerpo = f"Hace {dias} días que no entras. Tu oposición te espera."
    return {
        "title": "🔥 Tu racha te espera",
        "body":  cuerpo,
        "tag":   "inactividad",
        "url":   "/?atajo=home",
    }


# ── Modelo simple ──────────────────────────────────────────────────────────

@dataclass
class Suscripcion:
    endpoint: str
    p256dh:   str
    auth:     str

    def as_subscription_info(self) -> dict:
        return {
            "endpoint": self.endpoint,
            "keys":     {"p256dh": self.p256dh, "auth": self.auth},
        }


# ── Envío con manejo de errores ────────────────────────────────────────────

def enviar_push(sus: Suscripcion, payload: dict) -> tuple[bool, str | None]:
    """
    Devuelve (ok, motivo_si_falla). Un motivo con "gone" o "not_found" es
    señal de que la suscripción está muerta y hay que desactivarla.
    """
    try:
        webpush(
            subscription_info=sus.as_subscription_info(),
            data=json.dumps(payload),
            vapid_private_key=VAPID_PRIVATE_KEY,
            vapid_claims={"sub": VAPID_SUBJECT},
            ttl=3600,
        )
        return True, None
    except WebPushException as e:
        status = getattr(e.response, "status_code", None)
        if status in (404, 410):
            return False, "gone"
        return False, f"http_{status}" if status else "network"
    except Exception as e:  # noqa: BLE001 — no queremos que un fallo pare el bucle
        return False, f"error:{type(e).__name__}"


# ── Ciclo principal ────────────────────────────────────────────────────────

def procesar_candidatos(
    cur: psycopg.Cursor,
    tipo: str,
    filas: Iterable[tuple],
    build_payload,
) -> int:
    enviados = 0
    for usuario_id, medida in filas:
        payload = build_payload(medida)

        # Todas las suscripciones activas del usuario en un solo round-trip.
        cur.execute(
            "SELECT endpoint, p256dh, auth FROM push_suscripciones_de(%s);",
            (usuario_id,),
        )
        subs = [Suscripcion(*row) for row in cur.fetchall()]
        if not subs:
            continue

        exito_alguno = False
        for s in subs:
            ok, motivo = enviar_push(s, payload)
            if ok:
                exito_alguno = True
            elif motivo == "gone":
                cur.execute("SELECT push_marcar_error(%s, %s);", (s.endpoint, motivo))
                log.info("suscripción desactivada (%s): %s", motivo, s.endpoint[:60])
            else:
                # error transitorio → no desactivamos, se reintentará el próximo tick
                log.warning("push falló (%s) para %s: %s",
                            motivo, s.endpoint[:60], tipo)

        if exito_alguno:
            cur.execute(
                "SELECT push_marcar_envio(%s, %s, %s::jsonb);",
                (usuario_id, tipo, json.dumps(payload)),
            )
            enviados += 1

    return enviados


def tick(conn: psycopg.Connection) -> None:
    with conn.cursor() as cur:
        cur.execute("SELECT _push_en_ventana();")
        (en_ventana,) = cur.fetchone()
        if not en_ventana:
            log.debug("fuera de ventana horaria; skip")
            return

        # ── Repaso ──
        cur.execute("SELECT * FROM push_candidatos_repaso() LIMIT %s;",
                    (BATCH_LIMIT,))
        candidatos_repaso = cur.fetchall()
        n_repaso = procesar_candidatos(
            cur, "repaso", candidatos_repaso, payload_repaso
        )

        # ── Inactividad ──
        cur.execute("SELECT * FROM push_candidatos_inactividad() LIMIT %s;",
                    (BATCH_LIMIT,))
        candidatos_inactividad = cur.fetchall()
        n_inact = procesar_candidatos(
            cur, "inactividad", candidatos_inactividad, payload_inactividad
        )

    conn.commit()
    if n_repaso or n_inact:
        log.info("tick: repaso=%d inactividad=%d", n_repaso, n_inact)


def main() -> int:
    parar = False

    def _handle(signum, _frame):
        nonlocal parar
        log.info("señal %s recibida, salgo tras el tick actual", signum)
        parar = True
    signal.signal(signal.SIGTERM, _handle)
    signal.signal(signal.SIGINT,  _handle)

    log.info("notificador arrancado (tick=%ss, batch=%d)",
             TICK_SECONDS, BATCH_LIMIT)

    while not parar:
        try:
            with psycopg.connect(DATABASE_URL, autocommit=False) as conn:
                tick(conn)
        except Exception:  # noqa: BLE001
            log.exception("fallo en el tick; reintento en 30s")
            time.sleep(30)
            continue
        # Sleep con exit temprano si nos avisan.
        for _ in range(TICK_SECONDS):
            if parar:
                break
            time.sleep(1)

    log.info("notificador parado")
    return 0


if __name__ == "__main__":
    sys.exit(main())
