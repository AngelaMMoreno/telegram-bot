#!/usr/bin/env python3
"""Calibrado del validador de contenido.

Un validador que se queja de lo que está bien se acaba ignorando, así que
lo que se comprueba aquí es sobre todo que NO dé falsos positivos: los
ejemplos «válidos» salen literalmente de ESTRUCTURA_CONTENIDO.md § 4.3
y § 4.4.

No necesita base de datos.
"""
import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from publicar import (  # noqa: E402
    NOMBRES_PROHIBIDOS, _filas_tabla_bajo, _viñetas_bajo, leer_repo, validar,
)

fallos = []


def check(nombre, cond):
    print(f"  {'ok  ' if cond else 'FALLO'} {nombre}")
    if not cond:
        fallos.append(nombre)


def motivo(n):
    for patron, m in NOMBRES_PROHIBIDOS:
        if re.search(patron, n, re.IGNORECASE):
            return m
    return None


print("Nombres válidos (no deben disparar nada):")
VALIDOS = [
    "Procedimiento Administrativo Común (Ley 39/2015)",
    "Estatuto Básico del Empleado Público (RDL 5/2015)",
    "Ley 22/2006 de Capitalidad y de Régimen Especial de Madrid",
    "Estatuto de Autonomía de la Comunidad de Madrid",
    "La Corona",
    "El Tribunal Constitucional",
    "Título I: derechos y deberes fundamentales",
    "Iniciación del procedimiento",
    "Constitución Española: parte dogmática",
    "Derechos fundamentales y libertades públicas (arts. 14–29)",
    "Silencio administrativo positivo",
    "Ofimática: procesador de textos",
    "Igualdad efectiva de mujeres y hombres",
]
for n in VALIDOS:
    check(f"«{n}»", motivo(n) is None)

print("Nombres acoplados a la convocatoria (deben saltar, P5):")
INVALIDOS = [
    "Tema 4 Administrativo Ayto. Madrid",
    "Bloque II",
    "Módulo 2",
    "Parte general",
    "Continuación (II)",
    "Sección 3",
    "Parte autonómica (turno libre)",
    "Temario de la oposición",
    "Bloque específico grupo C1",
]
for n in INVALIDOS:
    check(f"«{n}»", motivo(n) is not None)


print("Lectura del repo:")

with tempfile.TemporaryDirectory() as tmp:
    raiz = Path(tmp)
    tema = raiz / "temas" / "constitucion"
    tema.mkdir(parents=True)
    (raiz / "temas" / "README.md").write_text(
        "# Estado del contenido en temas\n\nDocumento explicativo, no publicable.\n",
        encoding="utf-8",
    )
    (tema / "esquema.md").write_text(
        "<!-- aprentix:meta\n"
        "nivel: tema\n"
        "tema: constitucion\n"
        "nombre: Constitución Española\n"
        "-->\n"
        "# Constitución Española\n",
        encoding="utf-8",
    )
    docs = leer_repo(raiz)
    check("ignora temas/README.md como documentación auxiliar",
          len(docs) == 1 and docs[0].ruta == "temas/constitucion/esquema.md")

with tempfile.TemporaryDirectory() as tmp:
    raiz = Path(tmp)
    (raiz / "oposiciones").mkdir()
    (raiz / "oposiciones" / "auxilio.yaml").write_text(
        "slug: auxilio\nnombre: Auxilio\ntemas:\n  - tema-planificado\n",
        encoding="utf-8",
    )
    check("un tema planificado en el YAML sin ficheros no es aviso",
          validar([], raiz) == [])

print("Recuento de viñetas y filas:")

MD = """# X

## Retén esto

- **A:** uno.
- **B:** dos.
- **C:** tres.

## No lo confundas

| ❌ | ✅ | Diferencia |
|---|---|---|
| a | b | c |
| d | e | f |

## Fuente

- Norma.
"""
check("cuenta 3 viñetas de «Retén esto»", _viñetas_bajo(MD, "Retén esto") == 3)
check("no cuenta las de otro apartado", _viñetas_bajo(MD, "Fuente") == 1)
check("cuenta 2 filas con datos", _filas_tabla_bajo(MD, "No lo confundas") == 2)

# Las filas de plantilla sin rellenar no cuentan: si no, una tabla copiada
# tal cual de la plantilla pasaría el control sin contener nada.
VACIA = """# X

## No lo confundas

| ❌ | ✅ | Diferencia |
|---|---|---|
| | | |
"""
check("las filas vacías de la plantilla no cuentan",
      _filas_tabla_bajo(VACIA, "No lo confundas") == 0)
check("apartado inexistente devuelve 0",
      _filas_tabla_bajo(MD, "No existe") == 0)

print("TODO OK" if not fallos else f"HAY {len(fallos)} FALLOS")
sys.exit(1 if fallos else 0)
