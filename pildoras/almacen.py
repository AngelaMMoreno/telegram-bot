"""
Almacén de píldoras: SQLite en un fichero propio.

El bot es autónomo — no depende del Postgres de Aprentix ni de ningún
otro stack. La base vive en un volumen del host para sobrevivir a los
redespliegues, igual que /mnt/data/ficheros.

Estados:
    pendiente  → recién generada por la ingesta; nunca se publica
    aprobada   → revisada desde Discord con /revisar; cola de publicación
    descartada → ruido del PDF (índices, tablas); se archiva, no se borra
"""
from __future__ import annotations

import os
import sqlite3
from contextlib import closing
from pathlib import Path

RUTA_DB = Path(os.getenv("RUTA_DB", "/datos/pildoras.db"))

ESQUEMA = """
CREATE TABLE IF NOT EXISTS pildoras (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    texto        TEXT    NOT NULL,
    fuente       TEXT    NOT NULL,
    pagina       INTEGER,
    estado       TEXT    NOT NULL DEFAULT 'pendiente'
                 CHECK (estado IN ('pendiente', 'aprobada', 'descartada')),
    publicada_en TEXT,
    creada_en    TEXT    NOT NULL DEFAULT (datetime('now'))
);

-- Reingestar un PDF no debe duplicar píldoras ya generadas.
CREATE UNIQUE INDEX IF NOT EXISTS pildoras_texto_uniq ON pildoras (texto);

-- Cola de publicación y pantalla de revisión.
CREATE INDEX IF NOT EXISTS pildoras_cola_idx ON pildoras (estado, publicada_en);
"""


def conectar() -> sqlite3.Connection:
    RUTA_DB.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(RUTA_DB, timeout=10, isolation_level=None)
    conn.row_factory = sqlite3.Row
    # WAL: el bot puede leer mientras la ingesta escribe sin bloquearse.
    conn.execute("PRAGMA journal_mode=WAL")
    conn.executescript(ESQUEMA)
    return conn


# ── Operaciones ─────────────────────────────────────────────────────────────

def siguiente_pildora() -> str | None:
    """Saca la siguiente píldora aprobada y la marca como publicada.

    Coge la que lleve más tiempo sin publicarse (las que nunca se han
    publicado van primero) y la marca en la misma transacción, para que
    dos publicaciones simultáneas no repitan. BEGIN IMMEDIATE toma el
    lock de escritura desde el principio.
    """
    with closing(conectar()) as conn:
        conn.execute("BEGIN IMMEDIATE")
        try:
            fila = conn.execute(
                "SELECT id, texto FROM pildoras WHERE estado = 'aprobada'"
                " ORDER BY publicada_en IS NOT NULL, publicada_en, RANDOM() LIMIT 1"
            ).fetchone()
            if fila is None:
                return None
            conn.execute(
                "UPDATE pildoras SET publicada_en = datetime('now') WHERE id = ?",
                (fila["id"],),
            )
        finally:
            conn.execute("COMMIT")
        return fila["texto"]


def siguiente_pendiente(excluir: set[int] | None = None) -> sqlite3.Row | None:
    """La próxima píldora por revisar (para /revisar).

    `excluir` son las que se han saltado en esta sesión de revisión: siguen
    pendientes en la base, pero no vuelven a salir hasta la siguiente.
    """
    excluir = excluir or set()
    huecos = ",".join("?" * len(excluir))
    filtro = f" AND id NOT IN ({huecos})" if excluir else ""
    with closing(conectar()) as conn:
        return conn.execute(
            "SELECT id, texto, fuente, pagina FROM pildoras"
            f" WHERE estado = 'pendiente'{filtro}"
            " ORDER BY fuente, pagina, id LIMIT 1",
            tuple(excluir),
        ).fetchone()


def marcar(id_pildora: int, estado: str) -> None:
    if estado not in ("pendiente", "aprobada", "descartada"):
        raise ValueError(f"estado inválido: {estado}")
    with closing(conectar()) as conn:
        conn.execute(
            "UPDATE pildoras SET estado = ? WHERE id = ?", (estado, id_pildora)
        )


def guardar(texto: str, fuente: str, pagina: int | None) -> bool:
    """Inserta una píldora nueva. Devuelve False si ya existía."""
    with closing(conectar()) as conn:
        cur = conn.execute(
            "INSERT OR IGNORE INTO pildoras (texto, fuente, pagina)"
            " VALUES (?, ?, ?)",
            (texto, fuente, pagina),
        )
        return cur.rowcount > 0


def recuento() -> dict[str, int]:
    with closing(conectar()) as conn:
        filas = conn.execute(
            "SELECT estado, count(*) AS n FROM pildoras GROUP BY estado"
        ).fetchall()
    return {f["estado"]: f["n"] for f in filas}
