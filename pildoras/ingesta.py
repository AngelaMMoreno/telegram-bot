"""
Ingesta: PDFs de teoría → píldoras cortas en la BBDD.

Recorre /ficheros (el mismo volumen que sirve la SPA de teoría, montado
aquí en solo lectura), trocea cada PDF por páginas y le pide a Claude una
píldora por página. Las píldoras entran en estado 'pendiente': se aprueban
desde el propio Discord con /revisar (botones aprobar / descartar / saltar)
antes de que el bot las publique.

Se ejecuta a mano cuando cambian los PDFs, no como servicio residente:

    docker compose -f deploy/pildoras/docker-compose.yml run --rm ingesta

Usa la Batch API: cuesta la mitad que las llamadas normales y aquí la
latencia da igual. Un batch admite hasta 100.000 peticiones; si hay más
fragmentos se parte en varios y se procesan en serie.

Consejo: la primera vez, lanza con LIMITE=20 para ver qué calidad sale
antes de pagar por el corpus entero.
"""
from __future__ import annotations

import logging
import os
import time
from pathlib import Path

import anthropic
from anthropic.types.message_create_params import MessageCreateParamsNonStreaming
from anthropic.types.messages.batch_create_params import Request
from pypdf import PdfReader

import almacen

BASE_DIR  = Path(os.getenv("BASE_DIR", "/ficheros"))
MIN_CHARS = int(os.getenv("MIN_CHARS", "400"))   # descarta portadas y separadores
MAX_CHARS = int(os.getenv("MAX_CHARS", "6000"))  # recorta páginas gigantes
LIMITE    = int(os.getenv("LIMITE", "0"))        # 0 = sin límite
POR_LOTE  = 50_000                               # tope de la Batch API: 100.000

MODELO = "claude-opus-5"

SISTEMA = (
    "Eres un editor de contenidos para opositores. A partir del fragmento de "
    "temario que te doy, escribe UNA píldora de 40 a 60 palabras: un consejo "
    "práctico, un dato clave o un truco memorístico, en español, autocontenido "
    "y en tono cercano. Sin preámbulos, sin markdown, sin encabezados y sin "
    "citar el fragmento ni referirte a él. Si el fragmento no da para una "
    "píldora útil (índices, tablas de datos, textos legales en bruto, páginas "
    "casi vacías), responde exactamente: DESCARTAR"
)

log = logging.getLogger("pildoras.ingesta")


# ── PDFs → fragmentos ───────────────────────────────────────────────────────

def extraer_fragmentos() -> list[tuple[str, int, str]]:
    """Devuelve [(ruta_url, pagina, texto)] de todos los PDFs bajo BASE_DIR."""
    fragmentos: list[tuple[str, int, str]] = []
    for pdf in sorted(BASE_DIR.rglob("*.pdf")):
        ruta = "/" + str(pdf.relative_to(BASE_DIR))
        try:
            paginas = PdfReader(pdf).pages
        except Exception as e:  # PDF corrupto o cifrado: no aborta la pasada
            log.warning("no se pudo leer %s: %s", ruta, e)
            continue
        for n, pagina in enumerate(paginas, start=1):
            texto = (pagina.extract_text() or "").strip()
            if len(texto) >= MIN_CHARS:
                fragmentos.append((ruta, n, texto[:MAX_CHARS]))
    return fragmentos


# ── Fragmentos → píldoras ───────────────────────────────────────────────────

def procesar_lote(
    client: anthropic.Anthropic,
    fragmentos: list[tuple[str, int, str]],
) -> int:
    lote = client.messages.batches.create(requests=[
        Request(
            custom_id=f"f{i}",
            params=MessageCreateParamsNonStreaming(
                model=MODELO,
                max_tokens=4000,
                # La tarea es simple y se repite miles de veces: con effort
                # bajo sale igual de bien y cuesta bastante menos.
                output_config={"effort": "low"},
                system=SISTEMA,
                messages=[{"role": "user", "content": texto}],
            ),
        )
        for i, (_, _, texto) in enumerate(fragmentos)
    ])
    log.info("batch %s creado con %d peticiones", lote.id, len(fragmentos))

    while True:
        estado = client.messages.batches.retrieve(lote.id)
        if estado.processing_status == "ended":
            break
        log.info("procesando… (%s pendientes)", estado.request_counts.processing)
        time.sleep(60)

    insertadas = 0
    # Los resultados llegan en cualquier orden: se indexan por custom_id.
    for res in client.messages.batches.results(lote.id):
        if res.result.type != "succeeded":
            log.warning("%s: %s", res.custom_id, res.result.type)
            continue
        mensaje = res.result.message
        if mensaje.stop_reason == "refusal":
            continue
        texto = "".join(
            b.text for b in mensaje.content if b.type == "text"
        ).strip()
        if not texto or texto == "DESCARTAR":
            continue
        ruta, pagina, _ = fragmentos[int(res.custom_id[1:])]
        if almacen.guardar(texto, ruta, pagina):
            insertadas += 1
    return insertadas


def main() -> None:
    fragmentos = extraer_fragmentos()
    if LIMITE:
        fragmentos = fragmentos[:LIMITE]
    if not fragmentos:
        log.warning("no se encontró ningún PDF con texto en %s", BASE_DIR)
        return

    pdfs = len({f[0] for f in fragmentos})
    log.info("%d fragmentos de %d PDFs", len(fragmentos), pdfs)

    client = anthropic.Anthropic()
    total = 0
    for i in range(0, len(fragmentos), POR_LOTE):
        total += procesar_lote(client, fragmentos[i:i + POR_LOTE])

    log.info("%d píldoras nuevas en estado 'pendiente'", total)
    log.info("apruébalas desde Discord con /revisar antes de que se publiquen")
    log.info("recuento actual: %s", almacen.recuento())


if __name__ == "__main__":
    logging.basicConfig(
        level=os.getenv("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    main()
