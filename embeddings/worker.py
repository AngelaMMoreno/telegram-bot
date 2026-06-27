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
                "SELECT id, enunciado FROM preguntas WHERE id::text = ANY(%s)",
                (preguntas_ids,),
            )
            datos = cur.fetchall()
            if datos:
                vecs = vectorizar([d[1] for d in datos])
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
