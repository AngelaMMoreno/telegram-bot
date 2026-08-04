#!/usr/bin/env python3
"""Publica el repo de contenido en la base de datos de Aprentix.

El repo de contenido (git) es la fuente de la verdad: ahí se escribe, se
revisa y se discute. La BD es la copia publicada que sirve la app. Este
script es el único puente entre los dos, y va en una sola dirección.

Uso típico — mira antes de tocar:

    python3 publicar.py --contenido ../oposiciones --oposicion auxilio-judicial \\
                        --db "postgres://aprentix@localhost:5432/aprentix_desa"

Eso es un SIMULACRO: lee, compara y te enseña el plan sin escribir nada.
Cuando el plan te cuadre, repítelo con `--aplicar`.

Las tres garantías, que están en las RPCs y no en este script:

  1. Se casa por SLUG, nunca por nombre ni por posición. Renombrar una
     sección es un UPDATE: su uuid no se mueve y el progreso de los
     usuarios, que cuelga de ese uuid, no se entera.
  2. No se borra nada. Lo que desaparece del repo se archiva con
     `--archivar-ausentes`: sale de la app y conserva su historial.
  3. Cada oposición se publica en UNA transacción. Si algo falla a mitad,
     no queda un árbol a medias.

Estructura esperada del repo de contenido (la de PIPELINE_CREACION.md § 7.2,
más un YAML por oposición porque el orden de los temas no se puede deducir
de las rutas: un mismo tema se comparte entre oposiciones distintas):

    oposiciones/
      auxilio-judicial.yaml         # slug, nombre, descripcion, temas: [...]
    temas/
      <slug-tema>/
        esquema.md                  # aprentix:meta con nivel: tema
        <slug-modulo>/
          esquema.md                # nivel: modulo
          <slug-seccion>/
            teoria.md               # nivel: seccion
            preguntas.json          # pool de la sección (opcional)

Los slugs SALEN DEL BLOQUE `aprentix:meta`, no de la ruta. La ruta es sólo
dónde está el fichero. Si los dos discrepan el script para: significa que
alguien movió una carpeta sin actualizar el meta (o al revés), y adivinar
cuál de los dos manda es justo la clase de decisión que no debe tomar una
máquina. Con `--ignorar-rutas` se salta la comprobación.

Requiere: pip install -r requirements.txt
"""
from __future__ import annotations

import argparse
import json
import logging
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import psycopg
import yaml

log = logging.getLogger("publicar")

META_RE = re.compile(r"<!--\s*aprentix:meta\s*(.*?)-->", re.DOTALL)
H1_RE = re.compile(r"^#\s+(.+?)\s*$", re.MULTILINE)

# Apartados obligatorios de una teoría de sección (docs/PLANTILLA_TEORIA.md § 2).
APARTADOS_SECCION = [
    "Por qué importa",
    "La idea clave",
    "Desarrollo",
    "Cómo cae en el examen",
    "No lo confundas",
    "Retén esto",
    "Compruébalo tú mismo",
]
# Presupuesto de palabras de una sección (docs/ESTRUCTURA_CONTENIDO.md § 1.1).
PALABRAS_MIN, PALABRAS_MAX = 350, 1100


class ErrorContenido(Exception):
    """Problema en el repo de contenido: se reporta y se aborta."""


# ── Lectura del repo ────────────────────────────────────────────────────────

@dataclass
class Documento:
    nivel: str                 # 'tema' | 'modulo' | 'seccion'
    tema: str                  # slug
    modulo: str | None         # slug
    seccion: str | None        # slug
    nombre: str                # el H1 del markdown
    contenido: str
    ruta: str                  # relativa a la raíz del repo
    orden: int
    meta: dict[str, Any] = field(default_factory=dict)
    preguntas: list[dict] = field(default_factory=list)


def _parse_meta(texto: str, ruta: str) -> dict[str, Any]:
    """Extrae el bloque `<!-- aprentix:meta ... -->` como YAML."""
    m = META_RE.search(texto)
    if not m:
        raise ErrorContenido(
            f"{ruta}: falta el bloque «<!-- aprentix:meta ... -->». "
            f"Sin él no se sabe a qué sección pertenece el fichero "
            f"(ver docs/PLANTILLA_TEORIA.md § 2)."
        )
    try:
        meta = yaml.safe_load(m.group(1)) or {}
    except yaml.YAMLError as e:
        raise ErrorContenido(f"{ruta}: el bloque aprentix:meta no es YAML válido: {e}")
    if not isinstance(meta, dict):
        raise ErrorContenido(f"{ruta}: el bloque aprentix:meta debe ser un mapa clave: valor")
    return meta


def _titulo(texto: str, ruta: str) -> str:
    """El nombre visible sale del H1. Es lo que se renombra sin miedo."""
    m = H1_RE.search(texto)
    if not m:
        raise ErrorContenido(f"{ruta}: falta el encabezado «# Título» que da nombre al nodo")
    return m.group(1).strip()


def _leer_preguntas(path: Path) -> list[dict]:
    """Lee el pool de una sección. Acepta los dos formatos que ya usáis:
    lista suelta o `{"preguntas": [...]}`, con `enunciado` o `pregunta`, y
    opciones como objetos o como lista de textos (la primera correcta)."""
    datos = json.loads(path.read_text(encoding="utf-8"))
    crudas = datos.get("preguntas", []) if isinstance(datos, dict) else datos
    salida = []
    for i, pr in enumerate(crudas, 1):
        enunciado = (pr.get("enunciado") or pr.get("pregunta") or "").strip()
        if not enunciado:
            raise ErrorContenido(f"{path}: la pregunta #{i} no tiene enunciado")
        opts = pr.get("opciones") or []
        if opts and isinstance(opts[0], str):
            # Formato legacy: lista de textos, la primera es la correcta.
            opciones = [{"texto": o, "correcta": j == 0} for j, o in enumerate(opts)]
        else:
            opciones = [{"texto": o.get("texto", ""),
                         "correcta": bool(o.get("correcta"))} for o in opts]
        n_ok = sum(1 for o in opciones if o["correcta"])
        if len(opciones) < 2 or n_ok != 1:
            raise ErrorContenido(
                f"{path}: la pregunta #{i} («{enunciado[:50]}…») tiene "
                f"{len(opciones)} opciones y {n_ok} correctas; hacen falta "
                f"≥2 opciones y exactamente 1 correcta"
            )
        salida.append({"enunciado": enunciado, "opciones": opciones,
                       "explicacion": pr.get("explicacion")})
    return salida


def _avisos_formato(doc: Documento) -> list[str]:
    """Comprobaciones de la plantilla. Son AVISOS: no bloquean la
    publicación salvo con `--estricto`. Aquí es donde se nota tener el
    contenido en git — esto puede correr también en el CI del repo."""
    if doc.nivel != "seccion":
        return []
    avisos = []
    faltan = [a for a in APARTADOS_SECCION if f"## {a}" not in doc.contenido]
    if faltan:
        avisos.append(f"{doc.ruta}: faltan apartados obligatorios: {', '.join(faltan)}")
    # Palabras del cuerpo, quitando el bloque de metadatos.
    cuerpo = META_RE.sub("", doc.contenido)
    n = len(cuerpo.split())
    if n < PALABRAS_MIN:
        avisos.append(f"{doc.ruta}: {n} palabras, por debajo del mínimo de {PALABRAS_MIN} "
                      f"(¿fundir con la sección contigua?)")
    elif n > PALABRAS_MAX:
        avisos.append(f"{doc.ruta}: {n} palabras, por encima del máximo de {PALABRAS_MAX} "
                      f"(¿dividir en dos secciones?)")
    return avisos


def leer_repo(raiz: Path, ignorar_rutas: bool = False) -> list[Documento]:
    """Recorre `temas/` y devuelve los documentos encontrados."""
    base = raiz / "temas"
    if not base.is_dir():
        raise ErrorContenido(f"no encuentro {base}. ¿Es {raiz} la raíz del repo de contenido?")

    docs: list[Documento] = []
    for path in sorted(base.rglob("*.md")):
        rel = path.relative_to(raiz).as_posix()
        texto = path.read_text(encoding="utf-8")
        meta = _parse_meta(texto, rel)
        nivel = meta.get("nivel")
        if nivel not in ("tema", "modulo", "seccion"):
            raise ErrorContenido(f"{rel}: `nivel` debe ser tema, modulo o seccion (vino «{nivel}»)")

        tema, modulo, seccion = meta.get("tema"), meta.get("modulo"), meta.get("seccion")
        if not tema:
            raise ErrorContenido(f"{rel}: el meta no declara `tema`")
        if nivel in ("modulo", "seccion") and not modulo:
            raise ErrorContenido(f"{rel}: el meta de un {nivel} debe declarar `modulo`")
        if nivel == "seccion" and not seccion:
            raise ErrorContenido(f"{rel}: el meta de una sección debe declarar `seccion`")
        if nivel != "seccion":
            seccion = None
        if nivel == "tema":
            modulo = None

        # El meta manda; la ruta debe estar de acuerdo. Si no lo está,
        # alguien renombró una carpeta a medias y hay que mirarlo a mano.
        if not ignorar_rutas:
            esperada = "/".join(["temas", tema] + [s for s in (modulo, seccion) if s])
            esperada += "/esquema.md" if nivel != "seccion" else "/teoria.md"
            if rel != esperada:
                raise ErrorContenido(
                    f"el fichero está en «{rel}» pero su meta dice que debería estar en "
                    f"«{esperada}».\n"
                    f"    El slug es la identidad del contenido: si has movido la carpeta, "
                    f"actualiza el meta; si has cambiado el meta, mueve la carpeta.\n"
                    f"    Cambiar el slug de una sección la convierte en otra distinta y "
                    f"deja huérfano el progreso de quien la estudió.\n"
                    f"    Si sabes lo que haces: --ignorar-rutas."
                )

        preguntas = []
        if nivel == "seccion":
            fp = path.parent / "preguntas.json"
            if fp.is_file():
                preguntas = _leer_preguntas(fp)

        docs.append(Documento(
            nivel=nivel, tema=tema, modulo=modulo, seccion=seccion,
            nombre=meta.get("nombre") or _titulo(texto, rel),
            contenido=texto, ruta=rel,
            orden=int(meta.get("orden", 0) or 0),
            meta=meta, preguntas=preguntas,
        ))
    if not docs:
        raise ErrorContenido(f"no hay ningún .md bajo {base}")
    return docs


def leer_oposicion(raiz: Path, slug: str) -> dict:
    """El YAML que declara la oposición y el orden de sus temas."""
    path = raiz / "oposiciones" / f"{slug}.yaml"
    if not path.is_file():
        raise ErrorContenido(
            f"no encuentro {path}.\n"
            f"    Cada oposición necesita su YAML porque el orden de los temas no se "
            f"puede deducir de las rutas: un mismo tema se comparte entre oposiciones "
            f"y va en distinta posición en cada una.\n"
            f"    Formato: slug, nombre, descripcion y `temas:` con los slugs en orden."
        )
    datos = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    if datos.get("slug") != slug:
        raise ErrorContenido(f"{path}: el campo `slug` dice «{datos.get('slug')}» "
                             f"pero el fichero se llama «{slug}.yaml»")
    if not datos.get("temas"):
        raise ErrorContenido(f"{path}: falta la lista `temas:` con los slugs en orden")
    return datos


# ── Construcción del árbol ──────────────────────────────────────────────────

def construir_arbol(op: dict, docs: list[Documento]) -> tuple[dict, list[Documento]]:
    """Arma el JSON que espera `admin_publicar_estructura`, limitado a los
    temas de esta oposición. Devuelve también los documentos implicados."""
    por_tema: dict[str, list[Documento]] = {}
    for d in docs:
        por_tema.setdefault(d.tema, []).append(d)

    temas_json, usados = [], []
    for orden_tema, slug_tema in enumerate(op["temas"], 1):
        del_tema = por_tema.get(slug_tema)
        if not del_tema:
            raise ErrorContenido(
                f"la oposición «{op['slug']}» declara el tema «{slug_tema}» "
                f"pero no hay ningún fichero en temas/{slug_tema}/"
            )
        usados.extend(del_tema)

        doc_tema = next((d for d in del_tema if d.nivel == "tema"), None)
        modulos: dict[str, dict] = {}
        for d in del_tema:
            if d.nivel == "tema":
                continue
            m = modulos.setdefault(d.modulo, {"slug": d.modulo, "secciones": {},
                                              "nombre": None, "orden": 0})
            if d.nivel == "modulo":
                m["nombre"] = d.nombre
                m["orden"] = d.orden
            else:
                m["secciones"][d.seccion] = {
                    "slug": d.seccion,
                    "nombre": d.nombre,
                    "orden": d.orden,
                    "min_aprobado": d.meta.get("min_aprobado"),
                    "n_preg_test": d.meta.get("n_preg_test"),
                }

        mods_json = []
        for i, (slug_mod, m) in enumerate(
                sorted(modulos.items(), key=lambda kv: (kv[1]["orden"], kv[0])), 1):
            secs = sorted(m["secciones"].values(), key=lambda s: (s["orden"], s["slug"]))
            for j, s in enumerate(secs, 1):
                s["orden"] = s["orden"] or j
                # Quitamos los None para que la RPC use COALESCE y respete
                # el valor que ya hubiera en la BD.
                for k in ("min_aprobado", "n_preg_test"):
                    if s[k] is None:
                        del s[k]
            mods_json.append({
                "slug": slug_mod,
                "nombre": m["nombre"] or slug_mod,
                "orden": m["orden"] or i,
                "es_unico": len(modulos) == 1,
                "secciones": secs,
            })

        temas_json.append({
            "slug": slug_tema,
            "nombre": doc_tema.nombre if doc_tema else slug_tema,
            "descripcion": (doc_tema.meta.get("descripcion") if doc_tema else None),
            "orden": orden_tema,
            "modulos": mods_json,
        })

    arbol = {
        "oposicion": {"slug": op["slug"], "nombre": op.get("nombre", op["slug"]),
                      "descripcion": op.get("descripcion")},
        "temas": temas_json,
    }
    return arbol, usados


# ── Diálogo con la BD ───────────────────────────────────────────────────────

def abrir(conn_str: str) -> psycopg.Connection:
    """Conecta y se identifica como admin ante las RPCs.

    Las RPCs comprueban permisos con `es_admin()`, que lee el claim `roles`
    de `request.jwt.claims`. Conectando directamente ese GUC viene vacío, así
    que hay que ponerlo a mano con un usuario que tenga el rol admin.
    """
    conn = psycopg.connect(conn_str)
    fila = conn.execute("""
        SELECT u.id FROM usuarios u
          JOIN usuario_roles ur ON ur.usuario_id = u.id
         WHERE ur.rol_id = 'admin' AND u.activo
         ORDER BY u.creado_en LIMIT 1
    """).fetchone()
    if not fila:
        raise ErrorContenido("no hay ningún usuario con rol admin en esta BD")
    conn.execute("SELECT set_config('request.jwt.claims', %s, false)",
                 (json.dumps({"sub": str(fila[0]), "roles": ["admin"]}),))
    return conn


def commit_actual(raiz: Path) -> str | None:
    """El commit publicado, para poder responder «¿qué versión hay viva?»."""
    try:
        out = subprocess.run(["git", "-C", str(raiz), "rev-parse", "HEAD"],
                             capture_output=True, text=True, timeout=10)
        return out.stdout.strip()[:12] if out.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def estado_actual(conn: psycopg.Connection, slug: str) -> dict[str, dict]:
    """Foto de lo publicado, indexada por ruta de slugs."""
    fila = conn.execute("SELECT admin_estado_publicacion(%s)", (slug,)).fetchone()[0]
    if not fila.get("existe"):
        return {}
    return {s["ruta"]: s for s in fila["secciones"]}


# ── Plan y ejecución ────────────────────────────────────────────────────────

def calcular_plan(docs: list[Documento], estado: dict[str, dict]) -> dict[str, list]:
    """Compara repo y BD. Esto es lo que se enseña en el simulacro."""
    import hashlib

    plan: dict[str, list] = {"crear": [], "actualizar": [], "sin_cambios": [],
                             "archivar": [], "manual": []}
    vistas = set()
    for d in docs:
        if d.nivel != "seccion":
            continue
        ruta = f"{d.tema}/{d.modulo}/{d.seccion}"
        vistas.add(ruta)
        pub = estado.get(ruta)
        if pub is None:
            plan["crear"].append(ruta)
            continue
        h = hashlib.md5(d.contenido.encode("utf-8")).hexdigest()
        if pub.get("doc_origen") == "manual":
            plan["manual"].append(ruta)
        elif pub.get("doc_hash") == h:
            plan["sin_cambios"].append(ruta)
        else:
            plan["actualizar"].append(ruta)
    for ruta, pub in estado.items():
        if ruta not in vistas and not pub.get("archivada"):
            plan["archivar"].append(ruta)
    return plan


def imprimir_plan(plan: dict[str, list], op_slug: str, aplicar: bool) -> None:
    cab = "PLAN DE PUBLICACIÓN" if aplicar else "SIMULACRO — no se escribe nada"
    print(f"\n── {cab} · {op_slug} " + "─" * max(0, 50 - len(op_slug)))
    print(f"  crear         {len(plan['crear']):4d}")
    print(f"  actualizar    {len(plan['actualizar']):4d}")
    print(f"  sin cambios   {len(plan['sin_cambios']):4d}")
    print(f"  archivar      {len(plan['archivar']):4d}")
    if plan["manual"]:
        print(f"  editadas a mano {len(plan['manual']):2d}  (no se pisan sin --forzar)")
    for clave, etiqueta in (("crear", "+"), ("actualizar", "~"),
                            ("archivar", "-"), ("manual", "!")):
        for ruta in plan[clave][:20]:
            print(f"    {etiqueta} {ruta}")
        if len(plan[clave]) > 20:
            print(f"    … y {len(plan[clave]) - 20} más")


def revisar_salvaguardas(plan: dict[str, list], estado: dict[str, dict],
                         umbral: int, permitir: bool) -> None:
    """Freno de emergencia.

    Archivar en masa casi nunca es un cambio de contenido: es la firma de un
    slug que ha dejado de casar. El script ve secciones «nuevas» donde antes
    había otras y da las viejas por desaparecidas. Nadie pierde datos —
    archivar no borra— pero el progreso se queda varado en la fila retirada
    mientras la nueva nace a cero, que para el usuario es lo mismo que
    haberlo perdido.

    Cualquiera de las tres señales basta para parar; el flag las desactiva.
    """
    n_arch = len(plan["archivar"])
    n_crear = len(plan["crear"])
    n_vivas = max(len(estado), 1)
    if permitir or n_arch == 0:
        return

    pct = 100 * n_arch / n_vivas

    # La señal más específica y la más grave: se crea casi tanto como se
    # archiva. Eso es un renombrado de slugs disfrazado de contenido nuevo.
    #
    # Sólo se aplica a partir de `umbral` secciones: retirar una y añadir otra
    # es trabajo editorial de todos los días y no debe disparar nada. La huella
    # del renombrado masivo es, por definición, masiva.
    if n_arch >= umbral and n_crear and abs(n_crear - n_arch) <= max(1, n_arch // 4):
        raise ErrorContenido(
            f"la publicación crearía {n_crear} secciones y archivaría {n_arch}: "
            f"eso no es contenido nuevo, son slugs que han dejado de casar.\n"
            f"    Compara las dos listas de arriba. Si son las mismas secciones "
            f"con otro slug, lo que quieres es conservar el slug antiguo (es la "
            f"identidad de la que cuelga el progreso), no publicar esto.\n"
            f"    Si de verdad son secciones distintas: --permitir-archivado-masivo."
        )

    # Umbral proporcional. Un freno que salta por tres secciones de doscientas
    # se acaba desactivando por costumbre, y entonces ya no frena nada: lo que
    # importa no es cuántas se retiran sino qué parte del temario se lleva.
    if pct > 25 or (n_arch >= umbral and pct > 10):
        raise ErrorContenido(
            f"la publicación archivaría {n_arch} de {n_vivas} secciones vivas "
            f"({pct:.0f} %).\n"
            f"    Revisa la lista de arriba: si esas secciones siguen en el repo, "
            f"lo que ha cambiado es su slug y no deberías publicar esto.\n"
            f"    Si de verdad quieres retirarlas: --permitir-archivado-masivo."
        )


def publicar(conn: psycopg.Connection, arbol: dict, docs: list[Documento],
             commit: str | None, args) -> dict[str, int]:
    """Escribe. Todo dentro de una transacción: o entra entero o no entra."""
    res = {"documentos": 0, "preguntas_nuevas": 0, "preguntas_movidas": 0,
           "preguntas_archivadas": 0, "saltados_manual": 0}

    r = conn.execute("SELECT admin_publicar_estructura(%s::jsonb, %s)",
                     (json.dumps(arbol), args.archivar_ausentes)).fetchone()[0]
    log.info("estructura: creados=%s actualizados=%s archivados=%s",
             r["creados"], r["actualizados"], r["archivados"])

    for d in docs:
        rd = conn.execute(
            "SELECT admin_publicar_documento(%s,%s,%s,%s,%s,%s,%s)",
            (d.tema, d.modulo, d.seccion, d.contenido, d.ruta, commit, args.forzar),
        ).fetchone()[0]
        if rd.get("accion") == "editado_a_mano":
            log.warning("%s se editó desde el panel; no se pisa (usa --forzar)", d.ruta)
            res["saltados_manual"] += 1
        elif rd.get("accion") in ("creado", "actualizado"):
            res["documentos"] += 1

        if d.nivel == "seccion" and d.preguntas:
            rp = conn.execute(
                "SELECT admin_publicar_preguntas(%s,%s,%s,%s::jsonb,%s)",
                (d.tema, d.modulo, d.seccion, json.dumps(d.preguntas),
                 args.archivar_ausentes),
            ).fetchone()[0]
            res["preguntas_nuevas"] += rp["nuevas"]
            res["preguntas_movidas"] += rp["movidas"]
            res["preguntas_archivadas"] += rp["archivadas"]
            if rp["movidas"]:
                log.info("%s: %s preguntas movidas desde otra sección",
                         d.ruta, rp["movidas"])
    return res


# ── main ────────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(
        description="Publica el repo de contenido en la BD de Aprentix.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Sin --aplicar sólo enseña el plan; no escribe nada.")
    ap.add_argument("--contenido", required=True, type=Path,
                    help="raíz del repo de contenido")
    ap.add_argument("--db", required=True, help="DSN de la BD (postgres://…)")
    ap.add_argument("--oposicion", action="append", dest="oposiciones",
                    help="slug de la oposición a publicar; repetible. "
                         "Por defecto, todas las de oposiciones/*.yaml")
    ap.add_argument("--aplicar", action="store_true",
                    help="escribe de verdad (por defecto es un simulacro)")
    ap.add_argument("--archivar-ausentes", action="store_true",
                    help="archiva lo que ya no está en el repo (nunca lo borra)")
    ap.add_argument("--forzar", action="store_true",
                    help="sobrescribe también los documentos editados a mano")
    ap.add_argument("--estricto", action="store_true",
                    help="convierte en error los avisos de formato")
    ap.add_argument("--ignorar-rutas", action="store_true",
                    help="no exige que la ruta del fichero cuadre con su meta")
    ap.add_argument("--permitir-archivado-masivo", action="store_true",
                    help="desactiva el freno ante un archivado masivo")
    ap.add_argument("--umbral-archivado", type=int, default=3,
                    help="a partir de cuántas secciones salta el freno (def. 3)")
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    try:
        docs = leer_repo(args.contenido, args.ignorar_rutas)
        log.info("leídos %d documentos de %s", len(docs), args.contenido)

        avisos = [a for d in docs for a in _avisos_formato(d)]
        for a in avisos:
            log.warning(a)
        if avisos and args.estricto:
            raise ErrorContenido(f"{len(avisos)} avisos de formato y --estricto activo")

        slugs = args.oposiciones or sorted(
            p.stem for p in (args.contenido / "oposiciones").glob("*.yaml"))
        if not slugs:
            raise ErrorContenido("no hay ninguna oposición en oposiciones/*.yaml")

        commit = commit_actual(args.contenido)
        total = {"documentos": 0, "preguntas_nuevas": 0, "preguntas_movidas": 0,
                 "preguntas_archivadas": 0, "saltados_manual": 0}

        with abrir(args.db) as conn:
            for slug in slugs:
                op = leer_oposicion(args.contenido, slug)
                arbol, usados = construir_arbol(op, docs)
                estado = estado_actual(conn, slug)
                plan = calcular_plan(usados, estado)
                imprimir_plan(plan, slug, args.aplicar)

                # Se revisa también en simulacro: la idea es enterarse antes
                # de escribir, no después.
                if args.archivar_ausentes:
                    revisar_salvaguardas(plan, estado, args.umbral_archivado,
                                         args.permitir_archivado_masivo)
                elif plan["archivar"]:
                    log.info("%d secciones ya no están en el repo; se quedan "
                             "publicadas (usa --archivar-ausentes para retirarlas)",
                             len(plan["archivar"]))

                if not args.aplicar:
                    continue

                # Una transacción por oposición: si algo revienta a mitad,
                # esta oposición se queda como estaba.
                with conn.transaction():
                    res = publicar(conn, arbol, usados, commit, args)
                for k, v in res.items():
                    total[k] += v

        if not args.aplicar:
            print("\nSimulacro terminado. Repítelo con --aplicar cuando el plan te cuadre.")
            return 0

        print(f"\nPublicado{f' — commit {commit}' if commit else ''}: "
              f"{total['documentos']} documentos, "
              f"{total['preguntas_nuevas']} preguntas nuevas, "
              f"{total['preguntas_movidas']} movidas, "
              f"{total['preguntas_archivadas']} archivadas.")
        if total["saltados_manual"]:
            print(f"AVISO: {total['saltados_manual']} documentos editados desde el "
                  f"panel no se han tocado. Revísalos o publica con --forzar.")
        return 0

    except ErrorContenido as e:
        log.error("%s", e)
        return 2
    except psycopg.Error as e:
        log.error("error de base de datos: %s", e)
        return 3


if __name__ == "__main__":
    sys.exit(main())
