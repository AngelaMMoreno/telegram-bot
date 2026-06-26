"""Migración SQLite → PostgreSQL para Aprentix.

Uso:
    DATABASE_URL=postgres://... SQLITE_PATH=/mnt/data/bot/bd.sqlite \
        python migrar_sqlite_a_pg.py [--dry-run]

Principio rector: la pregunta es la entidad raíz. Se deduplica por
md5(lower(trim(enunciado))) y los tests se reconstruyen como
colecciones ordenadas (test_preguntas).

Mapas guardados:
    users.id        → usuarios.id (uuid)
    quizzes.id      → tests.id    (uuid)
    questions.id    → preguntas.id (uuid; misma pregunta repetida ⇒ mismo uuid)
    attempts.id     → intentos.id (uuid)
"""
from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import sqlite3
import sys
import uuid
from datetime import datetime

import psycopg

log = logging.getLogger("migracion")


def _hash(enunciado: str) -> str:
    return hashlib.md5(enunciado.strip().lower().encode()).hexdigest()


def _parsear_fecha(valor: str | None) -> datetime | None:
    if not valor:
        return None
    try:
        return datetime.fromisoformat(valor)
    except ValueError:
        return None


def migrar(sqlite_path: str, pg_dsn: str, dry_run: bool = False) -> None:
    log.info("origen sqlite: %s", sqlite_path)
    log.info("destino pg:    %s", pg_dsn.split("@")[-1])

    sl = sqlite3.connect(sqlite_path)
    sl.row_factory = sqlite3.Row

    with psycopg.connect(pg_dsn, autocommit=False) as pg:
        cur = pg.cursor()

        # ── Usuarios ────────────────────────────────────────────────────────
        log.info("→ usuarios")
        map_usuarios: dict[int, uuid.UUID] = {}
        sqlite_users = sl.execute("SELECT id, chat_id, created_at FROM users").fetchall()
        web_users = {}
        try:
            for r in sl.execute("SELECT user_id, username, password_hash FROM web_users").fetchall():
                web_users[r["user_id"]] = (r["username"], r["password_hash"])
        except sqlite3.OperationalError:
            log.warning("tabla web_users no existe en SQLite; sigo")

        for u in sqlite_users:
            nuevo = uuid.uuid4()
            map_usuarios[u["id"]] = nuevo
            username, pwd_hash = web_users.get(
                u["id"], (f"tg_{u['chat_id']}", None)
            )
            cur.execute(
                """
                INSERT INTO usuarios (id, username, chat_id, password_hash, creado_en)
                VALUES (%s, %s, %s, %s, %s)
                ON CONFLICT (username) DO NOTHING
                """,
                (nuevo, username, u["chat_id"], pwd_hash,
                 _parsear_fecha(u["created_at"]) or datetime.utcnow()),
            )
            cur.execute(
                "INSERT INTO usuario_roles(usuario_id, rol_id) VALUES (%s, 'alumno') ON CONFLICT DO NOTHING",
                (nuevo,),
            )
        log.info("   %d usuarios mapeados", len(map_usuarios))

        # ── Preguntas (deduplicadas) ────────────────────────────────────────
        log.info("→ preguntas (deduplicando por hash)")
        map_preguntas: dict[int, uuid.UUID] = {}
        hash_a_uuid: dict[str, uuid.UUID] = {}

        cur.execute("SELECT hash_contenido, id FROM preguntas")
        for h, pid in cur.fetchall():
            hash_a_uuid[h] = pid

        preguntas = sl.execute(
            "SELECT id, quiz_id, text, explicacion, bloque, tema FROM questions"
        ).fetchall()
        opciones_por_preg: dict[int, list[tuple[int, str]]] = {}
        for o in sl.execute(
            "SELECT question_id, position, text FROM options ORDER BY question_id, position"
        ).fetchall():
            opciones_por_preg.setdefault(o["question_id"], []).append(
                (o["position"], o["text"])
            )

        for p in preguntas:
            h = _hash(p["text"])
            if h in hash_a_uuid:
                map_preguntas[p["id"]] = hash_a_uuid[h]
                continue
            nuevo = uuid.uuid4()
            # En SQLite las opciones se insertaban con enumerate (position
            # empieza en 0) y la convención del bot era "primera = correcta".
            opciones = [
                {"texto": t, "correcta": pos == 0}
                for pos, t in opciones_por_preg.get(p["id"], [])
            ]
            cur.execute(
                """
                INSERT INTO preguntas (id, enunciado, opciones, explicacion)
                VALUES (%s, %s, %s, %s)
                ON CONFLICT (hash_contenido) DO NOTHING
                """,
                (nuevo, p["text"], json.dumps(opciones, ensure_ascii=False),
                 p["explicacion"]),
            )
            hash_a_uuid[h] = nuevo
            map_preguntas[p["id"]] = nuevo
        log.info("   %d preguntas mapeadas (%d únicas en destino)",
                 len(map_preguntas), len(hash_a_uuid))

        # ── Tests + test_preguntas ──────────────────────────────────────────
        log.info("→ tests")
        map_tests: dict[int, uuid.UUID] = {}
        for q in sl.execute("SELECT id, title, description, created_at FROM quizzes").fetchall():
            nuevo = uuid.uuid4()
            map_tests[q["id"]] = nuevo
            cur.execute(
                "INSERT INTO tests (id, titulo, descripcion, creado_en) VALUES (%s,%s,%s,%s)",
                (nuevo, q["title"], q["description"],
                 _parsear_fecha(q["created_at"]) or datetime.utcnow()),
            )

        for q_id, t_uuid in map_tests.items():
            preg_test = sl.execute(
                "SELECT id FROM questions WHERE quiz_id = ? ORDER BY id", (q_id,)
            ).fetchall()
            for pos, p in enumerate(preg_test, start=1):
                pid_nuevo = map_preguntas.get(p["id"])
                if pid_nuevo is None:
                    continue
                cur.execute(
                    """
                    INSERT INTO test_preguntas (test_id, pregunta_id, posicion)
                    VALUES (%s, %s, %s)
                    ON CONFLICT DO NOTHING
                    """,
                    (t_uuid, pid_nuevo, pos),
                )

        # ── Intentos + respuestas ───────────────────────────────────────────
        log.info("→ intentos y respuestas")
        map_intentos: dict[int, uuid.UUID] = {}
        for a in sl.execute(
            "SELECT id, user_id, quiz_id, attempt_type, started_at, finished_at, nombre FROM attempts"
        ).fetchall():
            uid = map_usuarios.get(a["user_id"])
            if uid is None:
                continue
            nuevo = uuid.uuid4()
            map_intentos[a["id"]] = nuevo
            cur.execute(
                """
                INSERT INTO intentos
                    (id, usuario_id, test_id, nombre, tipo, iniciado_en, finalizado_en)
                VALUES (%s,%s,%s,%s,%s,%s,%s)
                """,
                (nuevo, uid, map_tests.get(a["quiz_id"]),
                 a["nombre"], a["attempt_type"] or "normal",
                 _parsear_fecha(a["started_at"]) or datetime.utcnow(),
                 _parsear_fecha(a["finished_at"])),
            )

        for it in sl.execute(
            "SELECT attempt_id, question_id, selected_option, is_correct, answered_at FROM attempt_items"
        ).fetchall():
            iid = map_intentos.get(it["attempt_id"])
            pid = map_preguntas.get(it["question_id"])
            if not iid or not pid:
                continue
            try:
                opcion = int(it["selected_option"])
            except (TypeError, ValueError):
                opcion = -1
            cur.execute(
                """
                INSERT INTO respuestas
                    (intento_id, pregunta_id, opcion_elegida, correcta, respondida_en)
                VALUES (%s,%s,%s,%s,%s)
                """,
                (iid, pid, opcion, bool(it["is_correct"]),
                 _parsear_fecha(it["answered_at"]) or datetime.utcnow()),
            )

        # ── Marcadores (failures + favorites + tests_favoritos) ─────────────
        log.info("→ marcadores")
        for f in sl.execute(
            "SELECT user_id, question_id, fail_count, last_failed_at FROM failures"
        ).fetchall():
            uid, pid = map_usuarios.get(f["user_id"]), map_preguntas.get(f["question_id"])
            if uid and pid:
                cur.execute(
                    """
                    INSERT INTO marcadores (usuario_id, tipo, pregunta_id, contador, actualizado_en)
                    VALUES (%s,'fallo',%s,%s,%s)
                    ON CONFLICT DO NOTHING
                    """,
                    (uid, pid, f["fail_count"],
                     _parsear_fecha(f["last_failed_at"]) or datetime.utcnow()),
                )
        try:
            for f in sl.execute("SELECT user_id, question_id, created_at FROM favorites").fetchall():
                uid, pid = map_usuarios.get(f["user_id"]), map_preguntas.get(f["question_id"])
                if uid and pid:
                    cur.execute(
                        """
                        INSERT INTO marcadores (usuario_id, tipo, pregunta_id, actualizado_en)
                        VALUES (%s,'favorita',%s,%s)
                        ON CONFLICT DO NOTHING
                        """,
                        (uid, pid, _parsear_fecha(f["created_at"]) or datetime.utcnow()),
                    )
        except sqlite3.OperationalError:
            pass
        try:
            for f in sl.execute("SELECT user_id, quiz_id, created_at FROM tests_favoritos").fetchall():
                uid, tid = map_usuarios.get(f["user_id"]), map_tests.get(f["quiz_id"])
                if uid and tid:
                    cur.execute(
                        """
                        INSERT INTO marcadores (usuario_id, tipo, test_id, actualizado_en)
                        VALUES (%s,'test_favorito',%s,%s)
                        ON CONFLICT DO NOTHING
                        """,
                        (uid, tid, _parsear_fecha(f["created_at"]) or datetime.utcnow()),
                    )
        except sqlite3.OperationalError:
            pass

        if dry_run:
            log.warning("dry-run: rollback")
            pg.rollback()
        else:
            pg.commit()
            log.info("commit OK")


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    sqlite_path = os.environ.get("SQLITE_PATH", "/mnt/data/bot/bd.sqlite")
    pg_dsn = os.environ.get("DATABASE_URL")
    if not pg_dsn:
        log.error("falta DATABASE_URL")
        return 2
    migrar(sqlite_path, pg_dsn, args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
