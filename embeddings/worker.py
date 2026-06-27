"""Worker que escucha NOTIFY 'embeddings' y procesa la cola pendiente.

Se ejecuta en un hilo aparte arrancado desde main.py. Si pg_notify pierde un
mensaje (reconexión, reinicio), la pasada de barrido posterior recoge todas
las filas pendientes.
"""
from __future__ import annotations

import logging
import os
import select
import time

import psycopg

from modelo import vectorizar_pasajes as vectorizar

log = logging.getLogger("embeddings.worker")
DSN = os.environ["DATABASE_URL"]
LOTE = int(os.getenv("EMB_LOTE", "32"))


def _texto_opcion_correcta(opciones) -> str | None:
    """Devuelve el texto de la opción correcta de una pregunta.

    Convención del esquema (ver importar_test_normalizado / obtener_preguntas_test):
      - opciones es un array JSON
      - cada item puede ser {texto, correcta:bool} (formato nuevo) o un string
        suelto (formato heredado de la migración desde SQLite, donde la primera
        era la correcta por convención)
      - si ningún item lleva correcta=true, asumimos posición 0 como correcta.
    """
    if not isinstance(opciones, list) or not opciones:
        return None
    for o in opciones:
        if isinstance(o, dict) and o.get("correcta") is True:
            return (o.get("texto") or o.get("text") or "").strip() or None
    primera = opciones[0]
    if isinstance(primera, dict):
        return (primera.get("texto") or primera.get("text") or "").strip() or None
    if isinstance(primera, str):
        return primera.strip() or None
    return None


def _texto_para_embedding(enunciado: str, opciones) -> str:
    """Combina enunciado + opción correcta para reforzar la señal semántica.

    Útil cuando el enunciado es genérico ("¿cuál de las siguientes…?") y el
    tema solo aparece en las respuestas. La respuesta correcta es por
    definición on-topic, así que añadirla sube el recall del auto-tagger sin
    introducir ruido de distractores.
    """
    correcta = _texto_opcion_correcta(opciones)
    if correcta:
        return f"{enunciado}\n{correcta}"
    return enunciado


def _procesar_lote(conn: psycopg.Connection) -> int:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT id, entidad, entidad_id
            FROM cola_embeddings
            WHERE procesado_en IS NULL
            ORDER BY encolado_en
            LIMIT %s
            FOR UPDATE SKIP LOCKED
            """,
            (LOTE,),
        )
        filas = cur.fetchall()
        if not filas:
            return 0

        preguntas_ids = [r[2] for r in filas if r[1] == "pregunta"]
        etiquetas_nombres = [r[2] for r in filas if r[1] == "etiqueta"]

        if preguntas_ids:
            cur.execute(
                "SELECT id, enunciado, opciones FROM preguntas WHERE id::text = ANY(%s)",
                (preguntas_ids,),
            )
            datos = cur.fetchall()
            if datos:
                textos = [_texto_para_embedding(d[1], d[2]) for d in datos]
                vecs = vectorizar(textos)
                cur.executemany(
                    "UPDATE preguntas SET embedding = %s, actualizado_en = now() WHERE id = %s",
                    [(v, d[0]) for d, v in zip(datos, vecs)],
                )
                cur.executemany(
                    "SELECT reclasificar_pregunta(%s)",
                    [(d[0],) for d in datos],
                )

        if etiquetas_nombres:
            cur.execute(
                "SELECT nombre, COALESCE(descripcion, nombre) FROM catalogo_etiquetas WHERE nombre = ANY(%s)",
                (etiquetas_nombres,),
            )
            datos = cur.fetchall()
            if datos:
                vecs = vectorizar([d[1] for d in datos])
                cur.executemany(
                    "UPDATE catalogo_etiquetas SET embedding = %s WHERE nombre = %s",
                    [(v, d[0]) for d, v in zip(datos, vecs)],
                )

        cur.execute(
            "UPDATE cola_embeddings SET procesado_en = now() WHERE id = ANY(%s)",
            ([r[0] for r in filas],),
        )
    conn.commit()
    return len(filas)


def loop() -> None:
    log.info("worker arrancado; DSN=%s", DSN.split("@")[-1])
    while True:
        try:
            with psycopg.connect(DSN, autocommit=False) as conn:
                # Barrido inicial por si quedó cola pendiente.
                while _procesar_lote(conn):
                    pass

                conn.autocommit = True
                with conn.cursor() as cur:
                    cur.execute("LISTEN embeddings;")

                while True:
                    if select.select([conn], [], [], 30) == ([], [], []):
                        # Timeout: barrido defensivo.
                        conn.autocommit = False
                        while _procesar_lote(conn):
                            pass
                        conn.autocommit = True
                        continue
                    conn.execute("SELECT 1")  # consume notificaciones
                    list(conn.notifies())
                    conn.autocommit = False
                    while _procesar_lote(conn):
                        pass
                    conn.autocommit = True
        except Exception as e:  # noqa: BLE001
            log.exception("error en worker, reintento en 5s: %s", e)
            time.sleep(5)
