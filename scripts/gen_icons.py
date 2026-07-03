#!/usr/bin/env python3
"""Genera iconos PNG para la PWA a partir de shared/logo.svg.

Salida: web/site/icons/
    icon-192.png            (any)
    icon-512.png            (any)
    icon-maskable-192.png   (maskable, con padding seguro del 20%)
    icon-maskable-512.png
    icon-monochrome-512.png (para notificaciones)
    apple-touch-icon.png    (180x180, para iOS Add to Home Screen)
    favicon-32.png
    favicon-16.png

El logo actual es negro sobre transparente. Lo pintamos del verde salvia
de la marca (--pri #6B8E23) sobre un marfil (--bg #FBF9F0). La versión
maskable añade padding para que ninguna esquina se recorte cuando el SO
aplica una máscara circular o de squircle.
"""
import io
import re
from pathlib import Path

import cairosvg
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC  = ROOT / "shared" / "logo.svg"
DST  = ROOT / "web" / "site" / "icons"
DST.mkdir(parents=True, exist_ok=True)

# Colores de la marca (deben coincidir con shared/tokens.css)
BRAND     = "#6B8E23"          # verde musgo
BG        = "#FBF9F0"          # marfil luminoso
MONO_FG   = "#FFFFFF"          # blanco puro para status bar de Android
MONO_BG   = "#00000000"        # transparente

# El logo original está en negro (#000000). Lo repintamos.
raw_svg = SRC.read_text(encoding="utf-8")

def recolor(svg: str, fill: str) -> str:
    # Reemplazos "quirúrgicos": el fichero tiene fill="#000000" en <svg>
    # y en <g>, y stroke="none". Convertimos todos los negros a `fill`.
    out = re.sub(r'fill="#000000"', f'fill="{fill}"', svg)
    return out

def render(svg: str, size: int, bg: str | None = None,
           padding: float = 0.0) -> Image.Image:
    """Renderiza el SVG a un PNG cuadrado de `size` px, con fondo opcional
    y un margen interior (`padding` en [0, 0.5])."""
    if padding > 0:
        # Renderizamos más pequeño y componemos sobre un canvas del tamaño
        # objetivo con un fondo del color deseado.
        inner = int(round(size * (1 - 2 * padding)))
        inner_png = cairosvg.svg2png(bytestring=svg.encode("utf-8"),
                                     output_width=inner, output_height=inner)
        inner_img = Image.open(io.BytesIO(inner_png)).convert("RGBA")
        if bg:
            canvas = Image.new("RGBA", (size, size), bg)
        else:
            canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        off = (size - inner) // 2
        canvas.alpha_composite(inner_img, (off, off))
        return canvas

    png = cairosvg.svg2png(bytestring=svg.encode("utf-8"),
                           output_width=size, output_height=size)
    fg = Image.open(io.BytesIO(png)).convert("RGBA")
    if bg:
        canvas = Image.new("RGBA", (size, size), bg)
        canvas.alpha_composite(fg)
        return canvas
    return fg

green_svg = recolor(raw_svg, BRAND)
mono_svg  = recolor(raw_svg, MONO_FG)

# — Iconos "any" (con fondo) —
render(green_svg, 192, bg=BG).save(DST / "icon-192.png", optimize=True)
render(green_svg, 512, bg=BG).save(DST / "icon-512.png", optimize=True)

# — Maskable: mismo aspecto pero con 20 % de padding para safe area —
render(green_svg, 192, bg=BG, padding=0.18).save(DST / "icon-maskable-192.png", optimize=True)
render(green_svg, 512, bg=BG, padding=0.18).save(DST / "icon-maskable-512.png", optimize=True)

# — Monocromo (para status bar Android; transparente) —
render(mono_svg, 512, bg=None).save(DST / "icon-monochrome-512.png", optimize=True)

# — Apple Touch Icon (iOS ignora "maskable", usa este PNG cuadrado con
#   fondo opaco; Safari le añade los bordes redondeados). —
render(green_svg, 180, bg=BG, padding=0.10).save(DST / "apple-touch-icon.png", optimize=True)

# — Favicons (opcional pero completo) —
render(green_svg, 32, bg=BG).save(DST / "favicon-32.png", optimize=True)
render(green_svg, 16, bg=BG).save(DST / "favicon-16.png", optimize=True)

print("Iconos generados en", DST)
for p in sorted(DST.iterdir()):
    print(" ·", p.name, p.stat().st_size, "B")
