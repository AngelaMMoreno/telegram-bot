"""Detección de preguntas duplicadas dentro de una misma sección.

Se ejecuta como cron semanal (Dokploy scheduled task) y compara pares de
preguntas por similitud coseno del embedding pgvector. Las que superen
un umbral se apuntan en `propuestas_fusion` para que un admin las revise
(fusionar o descartar) desde el panel `#/admin/duplicados` de la SPA.

Reglas:
  * Sólo dentro de la misma sección (`p1.seccion_id = p2.seccion_id`).
  * Sólo pares con similitud > SIMILITUD_MIN (default 0.90 → distancia < 0.10).
  * `ON CONFLICT (a_id, b_id) DO NOTHING` — no re-propone las ya
    resueltas/descartadas.
  * Requiere que ambas preguntas tengan embedding no NULL.

Variables de entorno:
  DATABASE_URL       postgres://aprentix@db:5432/aprentix_desa
  PGPASSWORD         contraseña del rol aprentix
  SIMILITUD_MIN      opcional (default 0.90)
"""
from __future__ import annotations

import logging
import os
import sys

import psycopg


log = logging.getLogger("detectar_duplicados")
logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"),
                    format="%(asctime)s %(levelname)s %(name)s %(message)s")

DSN = os.environ["DATABASE_URL"]
SIMILITUD_MIN = float(os.getenv("SIMILITUD_MIN", "0.90"))
DIST_MAX = 1.0 - SIMILITUD_MIN  # cosine distance


SQL = """
INSERT INTO propuestas_fusion (a_id, b_id, seccion_id, similitud, propuesto_en, estado)
SELECT p1.id, p2.id, p1.seccion_id,
       1 - (p1.embedding <=> p2.embedding), now(), 'pendiente'
  FROM preguntas p1
  JOIN preguntas p2
    ON p1.seccion_id = p2.seccion_id
   AND p1.id < p2.id
 WHERE p1.embedding IS NOT NULL
   AND p2.embedding IS NOT NULL
   AND (p1.embedding <=> p2.embedding) < %s
ON CONFLICT (a_id, b_id) DO NOTHING;
"""


def main() -> int:
    log.info("umbral similitud=%.2f (distancia < %.2f)", SIMILITUD_MIN, DIST_MAX)
    with psycopg.connect(DSN, autocommit=True) as conn:
        cur = conn.execute(SQL, (DIST_MAX,))
        # psycopg no expone `rowcount` fiable en algunos DDL/INSERT; usamos
        # el statement message si podemos.
        log.info("propuestas insertadas: %s", cur.rowcount if cur.rowcount is not None else "?")
        # Reporta el total pendiente para el log de cron.
        row = conn.execute(
            "SELECT count(*) FROM propuestas_fusion WHERE estado = 'pendiente'"
        ).fetchone()
        log.info("total propuestas pendientes: %s", row[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
