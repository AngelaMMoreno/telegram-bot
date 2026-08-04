#!/usr/bin/env python3
"""Publicación parcial: qué entra en el filtro y qué orden conserva.

No necesita base de datos.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from publicar import (  # noqa: E402
    Documento, ErrorContenido, calcular_plan, construir_arbol, filtrar,
)


def doc(nivel, tema, modulo=None, seccion=None, orden=0):
    return Documento(nivel=nivel, tema=tema, modulo=modulo, seccion=seccion,
                     nombre=f"N-{seccion or modulo or tema}", contenido="x",
                     ruta=f"temas/{tema}/…", orden=orden)


DOCS = [
    doc("tema", "constitucion"),
    doc("modulo", "constitucion", "preliminar", orden=1),
    doc("seccion", "constitucion", "preliminar", "art-1", orden=1),
    doc("seccion", "constitucion", "preliminar", "art-2", orden=2),
    doc("tema", "ley-39-2015"),
    doc("modulo", "ley-39-2015", "terminacion", orden=1),
    doc("seccion", "ley-39-2015", "terminacion", "silencio", orden=1),
    doc("seccion", "ley-39-2015", "terminacion", "caducidad", orden=2),
]

fallos = []


def check(nombre, cond):
    print(f"  {'ok  ' if cond else 'FALLO'} {nombre}")
    if not cond:
        fallos.append(nombre)


print("Filtrado:")

# Sin filtro no se toca nada.
check("sin filtro devuelve todo", len(filtrar(DOCS, None, None)) == len(DOCS))

# Por tema: entra el tema entero y nada del otro.
r = filtrar(DOCS, ["ley-39-2015"], None)
check("--tema trae sólo ese tema", {d.tema for d in r} == {"ley-39-2015"})
check("--tema trae sus 4 documentos", len(r) == 4)

# Por sección: la sección y sus ancestros, para que los padres tengan nombre.
r = filtrar(DOCS, None, ["ley-39-2015/terminacion/silencio"])
niveles = sorted((d.nivel, d.seccion or d.modulo or d.tema) for d in r)
check("--seccion arrastra tema y módulo padres",
      niveles == [("modulo", "terminacion"), ("seccion", "silencio"), ("tema", "ley-39-2015")])
check("--seccion no cuela la sección hermana",
      all(d.seccion != "caducidad" for d in r))

# Errores claros.
try:
    filtrar(DOCS, None, ["ley-39-2015/silencio"])
    check("--seccion mal formada da error", False)
except ErrorContenido as e:
    check("--seccion mal formada da error", "tema/modulo/seccion" in str(e))

try:
    filtrar(DOCS, ["no-existe"], None)
    check("filtro sin resultados da error", False)
except ErrorContenido:
    check("filtro sin resultados da error", True)

print("Orden de temas:")

# El tema compartido va 2º en esta oposición. Publicándolo suelto tiene que
# seguir siendo el 2º y no pasar a ser el 1º.
OP = {"slug": "auxilio-judicial", "nombre": "Auxilio",
      "temas": ["constitucion", "ley-39-2015"]}

arbol, _ = construir_arbol(OP, DOCS, completo=True)
check("publicación completa: órdenes 1 y 2",
      [t["orden"] for t in arbol["temas"]] == [1, 2])

parcial = filtrar(DOCS, ["ley-39-2015"], None)
arbol, usados = construir_arbol(OP, parcial, completo=False)
check("publicación parcial: el 2º sigue siendo el 2º",
      len(arbol["temas"]) == 1 and arbol["temas"][0]["orden"] == 2)
check("publicación parcial: sólo el tema pedido", len(usados) == 4)

# Una oposición puede declarar temas planificados aunque aún no tengan
# documentos: se saltan sin bloquear lo que ya está listo.
arbol, usados = construir_arbol({"slug": "x", "temas": ["constitucion", "fantasma"]},
                                DOCS, completo=True)
check("publicación completa: el tema planificado sin ficheros se salta",
      [t["slug"] for t in arbol["temas"]] == ["constitucion"] and len(usados) == 4)

# Filtrando se mantiene el mismo criterio.
arbol, _ = construir_arbol({"slug": "x", "temas": ["constitucion", "fantasma"]},
                           DOCS, completo=False)
check("filtrando, el tema ausente se salta", len(arbol["temas"]) == 1)

plan = calcular_plan(
    usados,
    {
        "constitucion/preliminar/art-1": {"doc_hash": "x", "doc_origen": "git"},
        "constitucion/preliminar/retirada": {"doc_hash": "x", "doc_origen": "git"},
        "fantasma/modulo/seccion": {"doc_hash": "x", "doc_origen": "git"},
    },
    completo=True,
    temas_publicables={d.tema for d in usados},
)
check("archivar se limita a temas con documentos publicables",
      plan["archivar"] == ["constitucion/preliminar/retirada"])

print("TODO OK" if not fallos else f"HAY {len(fallos)} FALLOS")
sys.exit(1 if fallos else 0)
