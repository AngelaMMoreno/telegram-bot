"""notifier · Envía Web Push (VAPID) desde Aprentix.

Dos fuentes de trabajo:

  1) Cola `notificaciones_pendientes` — el trigger de retos y las RPCs de
     amistad la rellenan; hacemos LISTEN de `gamificacion` para vaciarla
     cuanto antes, con un barrido periódico como red de seguridad.

  2) Repasos vencidos (digest agregado) — un barrido cada N minutos cuenta
     los repasos vencidos por usuario y, si supera el umbral y ha pasado el
     mínimo de horas desde la última vez que le avisamos (throttle en
     `notificaciones_estado`), envía UN push agregado con la cifra ("Tienes
     47 preguntas por repasar"). Nunca 200 pushes; nunca antes de que
     amanezca en su zona horaria (por defecto: entre 09:00 y 22:00 hora
     local del servidor, configurable con NOTIF_QUIET_START / _END).

Todas las claves VAPID salen de variables de entorno:
  VAPID_PUBLIC_KEY_B64URL   clave pública (b64url) — la exponemos por RPC
                            para que el navegador la use en subscribe().
  VAPID_PRIVATE_KEY_PEM     clave privada en PEM (multilínea).
  VAPID_SUBJECT             normalmente "mailto:soporte@aprentix.es".

Si detectamos un 404/410 al enviar, borramos la suscripción muerta.
"""
from __future__ import annotations

import json
import logging
import os
import select
import time
from datetime import datetime, timedelta

import psycopg
from psycopg.rows import dict_row
from pywebpush import WebPushException, webpush

log = logging.getLogger("notifier")
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(name)s %(levelname)s %(message)s",
)

DSN = os.environ["DATABASE_URL"]

VAPID_PUBLIC  = os.environ["VAPID_PUBLIC_KEY_B64URL"].strip()
VAPID_PRIVATE = os.environ["VAPID_PRIVATE_KEY_PEM"].strip()
VAPID_SUB     = os.getenv("VAPID_SUBJECT", "mailto:soporte@aprentix.es")

# Repaso digest: no más de un push cada N horas, y solo si hay >= umbral.
DIGEST_MIN_HORAS = int(os.getenv("NOTIF_DIGEST_MIN_HORAS", "12"))
DIGEST_UMBRAL    = int(os.getenv("NOTIF_DIGEST_UMBRAL", "5"))

# Horario "aceptable" (hora local del servidor) en el que enviamos digests.
# Fuera de esta franja los aplazamos.
QUIET_START = int(os.getenv("NOTIF_QUIET_START", "9"))
QUIET_END   = int(os.getenv("NOTIF_QUIET_END",  "22"))

# Cada cuántos segundos hacemos el barrido de seguridad.
SWEEP_SECS = int(os.getenv("NOTIF_SWEEP_SECS", "300"))


# ─────────────────────────── VAPID helpers ─────────────────────────────────

VAPID_CLAIMS_TEMPLATE = {"sub": VAPID_SUB}


def _publicar_public_key(conn: psycopg.Connection) -> None:
    """Guardamos la clave pública en config(vapid_public_key) para que la
    RPC `vapid_public_key()` la sirva al frontend. Se rehace en cada
    arranque; si el operador rota la clave, la config se actualiza al
    siguiente boot."""
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO config(clave, valor) VALUES ('vapid_public_key', to_jsonb(%s::text))
            ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor
            """,
            (VAPID_PUBLIC,),
        )
    conn.commit()
    log.info("VAPID public key publicada en config (%d chars)", len(VAPID_PUBLIC))


def _enviar_a_subs(conn: psycopg.Connection, subs: list[dict], payload: dict) -> int:
    """Envía a una lista de suscripciones y limpia las muertas.
    Devuelve el número de envíos exitosos."""
    enviados = 0
    muertas: list[int] = []
    body = json.dumps(payload)
    for s in subs:
        try:
            webpush(
                subscription_info={
                    "endpoint": s["endpoint"],
                    "keys": {"p256dh": s["p256dh"], "auth": s["auth"]},
                },
                data=body,
                vapid_private_key=VAPID_PRIVATE,
                vapid_claims=dict(VAPID_CLAIMS_TEMPLATE),
                ttl=60 * 60 * 24,
            )
            enviados += 1
        except WebPushException as e:
            status = getattr(e.response, "status_code", None) if e.response else None
            if status in (404, 410):
                muertas.append(s["id"])
                log.info("suscripción muerta (%s), borrada", status)
            else:
                log.warning("error enviando push a %s: %s", s["endpoint"][:60], e)
        except Exception as e:  # noqa: BLE001
            log.warning("error inesperado enviando push: %s", e)

    if muertas:
        with conn.cursor() as cur:
            cur.execute("DELETE FROM push_subscripciones WHERE id = ANY(%s)", (muertas,))
        conn.commit()

    return enviados


def _subs_de(conn: psycopg.Connection, usuario_id: str) -> list[dict]:
    with conn.cursor(row_factory=dict_row) as cur:
        cur.execute(
            """
            SELECT id, endpoint, p256dh, auth
              FROM push_subscripciones
             WHERE usuario_id = %s
             ORDER BY vista_en DESC
            """,
            (usuario_id,),
        )
        return list(cur.fetchall())


# ─────────────────────────── Cola pendientes ───────────────────────────────

def _drenar_cola(conn: psycopg.Connection) -> int:
    """Procesa hasta 200 filas pendientes por pasada. Devuelve enviados."""
    procesadas = 0
    with conn.cursor(row_factory=dict_row) as cur:
        cur.execute(
            """
            SELECT id, usuario_id, tipo, titulo, cuerpo, url, datos
              FROM notificaciones_pendientes
             WHERE enviado_en IS NULL
             ORDER BY creado_en
             LIMIT 200
             FOR UPDATE SKIP LOCKED
            """
        )
        filas = list(cur.fetchall())
    if not filas:
        return 0

    for f in filas:
        subs = _subs_de(conn, str(f["usuario_id"]))
        payload = {
            "title": f["titulo"],
            "body":  f["cuerpo"],
            "url":   f["url"] or "/",
            "tipo":  f["tipo"],
            "datos": f["datos"],
        }
        if subs:
            _enviar_a_subs(conn, subs, payload)

        with conn.cursor() as cur:
            cur.execute(
                "UPDATE notificaciones_pendientes SET enviado_en = now() WHERE id = %s",
                (f["id"],),
            )
        conn.commit()
        procesadas += 1
    return procesadas


# ─────────────────────────── Digest de repasos vencidos ────────────────────

def _en_horario_ok() -> bool:
    ahora = datetime.now().hour
    if QUIET_START <= QUIET_END:
        return QUIET_START <= ahora < QUIET_END
    # Ventanas que cruzan medianoche (raro pero soportado).
    return ahora >= QUIET_START or ahora < QUIET_END


DIGEST_SQL = """
WITH candidatos AS (
    SELECT r.usuario_id,
           count(*) AS vencidas
      FROM repasos r
      JOIN preferencias_usuario pu ON pu.usuario_id = r.usuario_id
     WHERE r.ultima_en + intervalo_repaso(r.caja, pu.ritmo_repaso) <= now()
       AND EXISTS (
             SELECT 1 FROM test_preguntas tp
             JOIN intentos i ON i.test_id = tp.test_id
             WHERE tp.pregunta_id = r.pregunta_id
               AND i.usuario_id = r.usuario_id
           )
     GROUP BY r.usuario_id
)
SELECT c.usuario_id::text, c.vencidas, u.username
  FROM candidatos c
  JOIN usuarios u ON u.id = c.usuario_id
 WHERE c.vencidas >= %s
   AND EXISTS (SELECT 1 FROM push_subscripciones WHERE usuario_id = c.usuario_id)
   AND NOT EXISTS (
        SELECT 1 FROM notificaciones_estado ne
         WHERE ne.usuario_id = c.usuario_id
           AND ne.tipo = 'repaso_digest'
           AND ne.ultima_en > now() - (%s || ' hours')::interval
   )
"""


def _digest_repasos(conn: psycopg.Connection) -> int:
    if not _en_horario_ok():
        return 0
    enviados = 0
    with conn.cursor(row_factory=dict_row) as cur:
        cur.execute(DIGEST_SQL, (DIGEST_UMBRAL, DIGEST_MIN_HORAS))
        candidatos = list(cur.fetchall())
    if not candidatos:
        return 0

    for c in candidatos:
        vencidas = int(c["vencidas"])
        payload = {
            "title": "🔁 Repaso pendiente",
            "body":  f"Tienes {vencidas} preguntas por repasar. ¡5 minutos y las despachas!",
            "url":   "/#repaso",
            "tipo":  "repaso_digest",
            "datos": {"vencidas": vencidas},
        }
        subs = _subs_de(conn, c["usuario_id"])
        if subs and _enviar_a_subs(conn, subs, payload) > 0:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO notificaciones_estado(usuario_id, tipo, ultima_en)
                    VALUES (%s, 'repaso_digest', now())
                    ON CONFLICT (usuario_id, tipo) DO UPDATE
                        SET ultima_en = EXCLUDED.ultima_en
                    """,
                    (c["usuario_id"],),
                )
            conn.commit()
            enviados += 1
    if enviados:
        log.info("digest de repasos enviado a %d usuarios", enviados)
    return enviados


# ─────────────────────────────── Loop ──────────────────────────────────────

def loop() -> None:
    log.info("notifier arrancado; DSN=%s", DSN.split("@")[-1])
    last_digest = datetime.min
    while True:
        try:
            with psycopg.connect(DSN, autocommit=False) as conn:
                _publicar_public_key(conn)

                # Barrido inicial.
                while _drenar_cola(conn):
                    pass
                _digest_repasos(conn)

                conn.autocommit = True
                with conn.cursor() as cur:
                    cur.execute("LISTEN gamificacion;")

                while True:
                    r, _, _ = select.select([conn], [], [], SWEEP_SECS)
                    conn.execute("SELECT 1")
                    list(conn.notifies())

                    conn.autocommit = False
                    while _drenar_cola(conn):
                        pass
                    conn.autocommit = True

                    # Digest cada media hora como mucho, y solo por barrido.
                    if datetime.utcnow() - last_digest > timedelta(minutes=30):
                        conn.autocommit = False
                        _digest_repasos(conn)
                        conn.autocommit = True
                        last_digest = datetime.utcnow()
        except Exception as e:  # noqa: BLE001
            log.exception("error en notifier, reintento en 5s: %s", e)
            time.sleep(5)


if __name__ == "__main__":
    loop()
