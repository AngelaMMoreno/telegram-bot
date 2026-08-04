#!/usr/bin/env python3
"""Casos límite del freno de archivado."""
import sys
sys.path.insert(0, "/home/user/telegram-bot/db/publicacion")
from publicar import revisar_salvaguardas, ErrorContenido

def caso(nombre, n_crear, n_arch, n_vivas, debe_parar, umbral=3, permitir=False):
    plan = {"crear": [f"c{i}" for i in range(n_crear)],
            "archivar": [f"a{i}" for i in range(n_arch)]}
    estado = {f"s{i}": {} for i in range(n_vivas)}
    try:
        revisar_salvaguardas(plan, estado, umbral, permitir)
        paro = False
    except ErrorContenido:
        paro = True
    ok = paro == debe_parar
    print(f"  {'ok  ' if ok else 'FALLO'} {nombre}: crear={n_crear} archivar={n_arch} "
          f"vivas={n_vivas} -> {'para' if paro else 'sigue'} "
          f"(esperado {'para' if debe_parar else 'sigue'})")
    return ok

print("Freno de archivado:")
res = [
    # El escenario catastrófico: cambio de convención de slugs.
    caso("renombrado masivo 3/3",        3,  3,  3,  True),
    caso("renombrado masivo 40/40",     40, 40, 40,  True),
    # Trabajo editorial normal: no debe estorbar.
    caso("retiro 1 y añado 1 de 40",     1,  1, 40, False),
    caso("retiro 1 de 40",               0,  1, 40, False),
    caso("retiro 3 de 200",              0,  3,200, False),
    caso("sólo añado",                   5,  0, 40, False),
    # Retiradas grandes de verdad: sí debe parar.
    caso("retiro 15 de 40",              0, 15, 40,  True),
    caso("retiro 1 de 3 (repo pequeño)", 0,  1,  3,  True),
    # El flag manda siempre.
    caso("con --permitir",              40, 40, 40, False, permitir=True),
]
print("TODO OK" if all(res) else "HAY FALLOS")
sys.exit(0 if all(res) else 1)
