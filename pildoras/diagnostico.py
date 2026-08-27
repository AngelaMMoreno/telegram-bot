"""
Diagnóstico de los PDFs — no llama a la API, no cuesta nada.

Lánzalo ANTES de la primera ingesta:

    docker compose -f deploy/pildoras/docker-compose.yml run --rm diagnostico

Responde a tres preguntas que deciden si esto va a funcionar:

  1. ¿Tus PDFs llevan texto, o son escaneos? pypdf no lee imágenes: de un
     PDF escaneado saca cero caracteres y la ingesta no generaría nada.
     Esos hay que pasarlos antes por OCR (ocrmypdf).
  2. ¿Cuántos fragmentos se enviarían con el MIN_CHARS actual?
  3. ¿Cuánto costaría aproximadamente la pasada completa?
"""
from __future__ import annotations

import os
from pathlib import Path

from pypdf import PdfReader

BASE_DIR  = Path(os.getenv("BASE_DIR", "/ficheros"))
MIN_CHARS = int(os.getenv("MIN_CHARS", "400"))
MAX_CHARS = int(os.getenv("MAX_CHARS", "6000"))

# Precios de claude-opus-5 por millón de tokens, ya con el 50% de
# descuento de la Batch API aplicado.
USD_ENTRADA_MTOK = 2.50
USD_SALIDA_MTOK = 12.50
# El español ronda los 3,5 caracteres por token. El system prompt suma
# unos 120 tokens por petición, y cada píldora ronda los 80 de salida;
# con thinking adaptativo a effort bajo, presupuestamos 300 para no
# quedarnos cortos.
CHARS_POR_TOKEN = 3.5
TOKENS_SISTEMA = 120
TOKENS_SALIDA = 300


def main() -> None:
    pdfs = sorted(BASE_DIR.rglob("*.pdf"))
    if not pdfs:
        print(f"No hay ningún PDF bajo {BASE_DIR}")
        return

    print(f"{len(pdfs)} PDFs bajo {BASE_DIR}  (MIN_CHARS={MIN_CHARS})\n")
    print(f"{'PDF':<50} {'págs':>5} {'útiles':>7} {'chars/pág':>10}  estado")
    print("-" * 92)

    total_utiles = total_chars = 0
    escaneados: list[str] = []
    ejemplo: str | None = None

    for pdf in pdfs:
        ruta = "/" + str(pdf.relative_to(BASE_DIR))
        try:
            paginas = PdfReader(pdf).pages
        except Exception as e:
            print(f"{ruta[:50]:<50} {'—':>5} {'—':>7} {'—':>10}  ILEGIBLE: {e}")
            continue

        textos = [(p.extract_text() or "").strip() for p in paginas]
        utiles = [t for t in textos if len(t) >= MIN_CHARS]
        chars = sum(len(t[:MAX_CHARS]) for t in utiles)
        media = (sum(len(t) for t in textos) // len(textos)) if textos else 0

        if not utiles:
            estado = "SIN TEXTO — ¿escaneado?" if media < 50 else "todo bajo MIN_CHARS"
            escaneados.append(ruta)
        else:
            estado = "ok"
            if ejemplo is None:
                ejemplo = utiles[0]

        total_utiles += len(utiles)
        total_chars += chars
        print(f"{ruta[:50]:<50} {len(paginas):>5} {len(utiles):>7} {media:>10}  {estado}")

    print("-" * 92)
    print(f"\nFragmentos que se enviarían: {total_utiles}")

    if escaneados:
        plural = "PDF no aporta" if len(escaneados) == 1 else "PDFs no aportan"
        print(f"\n⚠️  {len(escaneados)} {plural} nada:")
        for r in escaneados[:10]:
            print(f"      {r}")
        if len(escaneados) > 10:
            print(f"      … y {len(escaneados) - 10} más")
        print("\n    Si son escaneos, pásalos por OCR antes de ingerir:")
        print("      ocrmypdf --language spa entrada.pdf salida.pdf")

    if not total_utiles:
        print("\nNo hay nada que ingerir. No lances la ingesta todavía.")
        return

    entrada = total_utiles * (total_chars / total_utiles / CHARS_POR_TOKEN + TOKENS_SISTEMA)
    salida = total_utiles * TOKENS_SALIDA
    coste = entrada / 1e6 * USD_ENTRADA_MTOK + salida / 1e6 * USD_SALIDA_MTOK
    print(f"\nCoste estimado de la pasada completa: ~{coste:.2f} USD")
    print(f"  (~{entrada/1000:.0f}K tokens de entrada, ~{salida/1000:.0f}K de salida,")
    print("   con Batch API. Es una estimación a ojo, no una factura.)")

    if ejemplo:
        print("\nEjemplo de lo que recibiría el modelo (primer fragmento útil):")
        print("-" * 92)
        print(ejemplo[:600] + ("…" if len(ejemplo) > 600 else ""))
        print("-" * 92)
        print("Si esto se lee como texto corrido, buena señal. Si son cabeceras")
        print("sueltas o números de página, sube MIN_CHARS.")


if __name__ == "__main__":
    main()
