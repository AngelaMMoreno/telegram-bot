#!/usr/bin/env python3
"""Migra los tests JSON del sistema viejo al nuevo esquema por sección.

Uso:
    python3 mapear.py --tests-dir <carpeta> --mapeo <mapeo.yaml> \\
                      --db postgres://user@host:5432/aprentix_desa

Requiere:
    pip install -r requirements.txt

Formato de entrada esperado (tests del sistema viejo — ambos soportados):

    {
      "titulo": "…",
      "descripcion": "…",
      "etiquetas": ["…", "…"],           # opcional (fallback al top-level del test)
      "preguntas": [
        {
          "enunciado": "…" | "pregunta": "…",   # ambos aliases se aceptan
          "opciones":  [{"texto": "…", "correcta": true|false}, …] |
                       ["Texto opción 1", "Texto opción 2", …],   # legacy: primera correcta
          "explicacion": "…",                    # opcional
          "etiquetas":   ["…", "…"]              # opcional (fallback al test)
        },
        …
      ]
    }

Salida:
    * Inserta las preguntas vía RPC `importar_pregunta(seccion_id, …)`.
      El hash_contenido UNIQUE deduplica automáticamente.
    * Genera `informe_import_<fecha>.json` con el detalle.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import logging
import os
import re
import sys
from pathlib import Path
from typing import Any

import psycopg
import yaml


log = logging.getLogger("mapear")
logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"),
                    format="%(levelname)s %(message)s")


# ── Normalización de opciones ─────────────────────────────────────────────

def _normalizar_opciones(opts: Any) -> list[dict]:
    """Devuelve siempre [{texto, correcta}]. Acepta el formato legacy
    (lista de strings donde la primera es la correcta)."""
    if not isinstance(opts, list) or not opts:
        raise ValueError("opciones vacías o mal formadas")
    if isinstance(opts[0], dict):
        return [{"texto": (o.get("texto") or o.get("text") or "").strip(),
                 "correcta": bool(o.get("correcta"))} for o in opts]
    # legacy: lista de strings
    return [{"texto": str(t).strip(), "correcta": (i == 0)}
            for i, t in enumerate(opts)]


# ── Resolución de slugs → sección_id ──────────────────────────────────────

_SLUG_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")


def _resolver_seccion(conn: psycopg.Connection, ruta: str) -> str:
    """Convierte 'oposicion/tema/modulo/seccion' en el uuid de la sección.
    Cachea con `LRU` implícito por el módulo (dict)."""
    if ruta in _resolver_seccion._cache:
        return _resolver_seccion._cache[ruta]
    partes = ruta.split("/")
    if len(partes) != 4:
        raise ValueError(f"ruta inválida (esperaba 4 tramos): {ruta}")
    op_slug, tema_slug, mod_slug, sec_slug = partes
    row = conn.execute("""
        SELECT s.id
          FROM secciones s
          JOIN modulos   m ON m.id = s.modulo_id
          JOIN temas     t ON t.id = m.tema_id
          JOIN oposicion_temas ot ON ot.tema_id = t.id
          JOIN oposiciones o ON o.id = ot.oposicion_id
         WHERE lower(o.nombre) = lower(%s)
              -- si prefieres slug de oposición, sustituye por o.slug cuando
              -- lo añadas al esquema (hoy la oposición tiene 'nombre_lower').
           AND t.slug = %s
           AND (m.nombre ILIKE %s OR %s = 'sin_clasificar')
           AND (s.nombre ILIKE %s OR %s = 'sin_clasificar')
    """, (op_slug, tema_slug, mod_slug, mod_slug, sec_slug, sec_slug)).fetchone()
    if not row:
        raise LookupError(f"sección no encontrada: {ruta}")
    _resolver_seccion._cache[ruta] = row[0]
    return row[0]


_resolver_seccion._cache = {}


# ── Aplicación de las reglas del YAML ─────────────────────────────────────

def _matches(regla_etiqs: list[str], test_etiqs: list[str]) -> bool:
    tset = {e.lower() for e in test_etiqs}
    return all(e.lower() in tset for e in regla_etiqs)


def _seccion_para(reglas: list[dict], etiqs: list[str]) -> str | None:
    for regla in reglas:
        if _matches(regla.get("etiquetas", []), etiqs):
            return regla["seccion"]
    return None


# ── Import por fichero ────────────────────────────────────────────────────

def _importar_fichero(conn: psycopg.Connection, path: Path,
                      reglas: list[dict], informe: dict) -> None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as e:
        log.error("%s: JSON inválido (%s)", path, e)
        informe["errores"].append({"fichero": str(path), "error": str(e)})
        return
    if isinstance(data, list):
        # Los JSON viejos a veces son array de preguntas sin envoltorio.
        data = {"preguntas": data, "etiquetas": []}
    etiq_test = data.get("etiquetas") or []
    for i, pr in enumerate(data.get("preguntas", []), 1):
        etiq_p = pr.get("etiquetas") or etiq_test
        ruta = _seccion_para(reglas, etiq_p)
        if not ruta:
            informe["huerfanas"].append({
                "fichero": str(path), "posicion": i,
                "etiquetas": etiq_p,
                "enunciado": (pr.get("enunciado") or pr.get("pregunta") or "")[:120],
            })
            continue
        try:
            seccion_id = _resolver_seccion(conn, ruta)
        except LookupError as e:
            informe["errores"].append({"fichero": str(path), "posicion": i,
                                       "error": str(e)})
            continue
        enunciado = (pr.get("enunciado") or pr.get("pregunta") or "").strip()
        if not enunciado:
            informe["errores"].append({"fichero": str(path), "posicion": i,
                                       "error": "enunciado vacío"})
            continue
        try:
            opciones = _normalizar_opciones(pr.get("opciones"))
        except ValueError as e:
            informe["errores"].append({"fichero": str(path), "posicion": i,
                                       "error": str(e)})
            continue
        pid = conn.execute(
            "SELECT importar_pregunta(%s, %s, %s::jsonb, %s)",
            (seccion_id, enunciado, json.dumps(opciones),
             pr.get("explicacion")),
        ).fetchone()[0]
        informe["insertadas"].append({"fichero": str(path), "posicion": i,
                                      "pregunta_id": pid, "seccion": ruta})


# ── main ─────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--tests-dir", required=True, type=Path)
    ap.add_argument("--mapeo",     required=True, type=Path)
    ap.add_argument("--db",        required=True,
                    help="DSN de la BD nueva (aprentix_desa)")
    ap.add_argument("--informe",   type=Path,
                    default=Path(f"informe_import_{dt.date.today()}.json"))
    args = ap.parse_args()

    reglas = yaml.safe_load(args.mapeo.read_text(encoding="utf-8"))["reglas"]
    log.info("cargadas %d reglas de mapeo", len(reglas))

    ficheros = sorted(args.tests_dir.rglob("*.json"))
    if not ficheros:
        log.error("no hay .json en %s", args.tests_dir)
        return 2

    informe = {"insertadas": [], "huerfanas": [], "errores": []}
    with psycopg.connect(args.db) as conn:
        conn.autocommit = True
        for f in ficheros:
            log.info("importando %s", f)
            _importar_fichero(conn, f, reglas, informe)

    args.informe.write_text(json.dumps(informe, indent=2, ensure_ascii=False),
                            encoding="utf-8")
    log.info("insertadas=%d huerfanas=%d errores=%d — informe: %s",
             len(informe["insertadas"]),
             len(informe["huerfanas"]),
             len(informe["errores"]),
             args.informe)
    return 0 if not informe["errores"] else 1


if __name__ == "__main__":
    sys.exit(main())
