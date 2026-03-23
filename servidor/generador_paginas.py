"""
Generador de páginas HTML de teoría a partir de plantillas YAML/JSON.

Formato de plantilla (YAML/JSON):
──────────────────────────────────
titulo: "Título de la página"
descripcion: "Subtítulo o descripción breve"

banner:                          # Opcional — bloque destacado arriba
  etiqueta: "ETIQUETA SUPERIOR"
  titulo: "Título del banner"
  descripcion: "Texto descriptivo..."
  columnas:                      # Opcional — para comparativas
    - subtitulo: "Columna 1"
      titulo: "Nombre"
      texto: "Descripción..."

secciones:                       # Lista de secciones con categorías
  - titulo: "Título de sección"  # Opcional
    categorias:
      - nombre: "Nombre categoría"
        icono: "🔧"
        color: "#b5431c"         # Color temático
        etiquetas: ["PDU: Datos"]  # Opcional — badges en cabecera
        items:
          - nombre: "Apartado"
            descripcion: "Breve descripción"
            etiqueta: "Badge"    # Opcional
            contraible: true      # Opcional — si hay detalle/subitems
            detalle:              # Opcional — contenido ampliado
              texto: "Texto completo..."
              nota: "Nota adicional (admite <strong>HTML</strong>)"
            subitems:             # Opcional — subsecciones anidadas
              - nombre: "Subapartado"
                descripcion: "Más detalle"
                contraible: false
                detalle:
                  texto: "Visible siempre al no ser contraíble"
"""

import hashlib
import html

_COLORES_DEFAULT = [
    "#b5431c", "#8a5510", "#1254a0", "#0a6b52", "#4036b0",
    "#4a4845", "#4f7d10", "#12876a", "#7c3aed", "#0891b2",
    "#059669", "#c2410c", "#d97706", "#dc2626",
]


def _color_vars(color: str) -> str:
    """Genera CSS variables para una categoría dado su color hex."""
    r, g, b = int(color[1:3], 16), int(color[3:5], 16), int(color[5:7], 16)
    return (
        f"--cat-border:rgba({r},{g},{b},.22);"
        f"--cat-head-bg:rgba({r},{g},{b},.06);"
        f"--cat-color:{color};"
        f"--cat-soft:rgba({r},{g},{b},.05);"
        f"--cat-soft-strong:rgba({r},{g},{b},.10);"
    )


def _badge_style(color: str) -> str:
    r, g, b = int(color[1:3], 16), int(color[3:5], 16), int(color[5:7], 16)
    return f"background:rgba({r},{g},{b},.1);color:{color}"


def _crear_id_unico(texto: str) -> str:
    """Genera un ID seguro y corto para elementos interactivos."""
    return hashlib.md5(texto.encode("utf-8")).hexdigest()[:10]


def _texto_html(texto: str) -> str:
    texto = html.escape(texto or "")
    if not texto:
        return ""
    return texto.replace("\n", "<br>")


def generar_html(plantilla: dict) -> str:
    """Convierte una plantilla (dict) en HTML completo."""
    titulo = html.escape(plantilla.get("titulo", "Sin título"))
    descripcion = html.escape(plantilla.get("descripcion", ""))

    banner_html = ""
    banner = plantilla.get("banner")
    if banner:
        banner_html = _render_banner(banner)

    secciones_html = ""
    secciones = plantilla.get("secciones", [])
    if not secciones and "categorias" in plantilla:
        secciones = [{"categorias": plantilla["categorias"]}]

    color_idx = 0
    for indice_seccion, seccion in enumerate(secciones):
        sec_titulo = seccion.get("titulo", "")
        if sec_titulo:
            secciones_html += (
                f'<div class="section-title">{html.escape(sec_titulo)}</div>\n'
            )

        secciones_html += '<div class="grid">\n'
        for indice_categoria, cat in enumerate(seccion.get("categorias", [])):
            color = cat.get("color", _COLORES_DEFAULT[color_idx % len(_COLORES_DEFAULT)])
            color_idx += 1
            prefijo = f"sec-{indice_seccion}-cat-{indice_categoria}"
            secciones_html += _render_categoria(cat, color, prefijo)
        secciones_html += "</div>\n"

    return f"""<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{titulo}</title>
<style>
{_CSS}
</style>
</head>
<body>
<div class="wrap">
  <header class="page-header">
    <h1>{titulo}</h1>
    {"<p>" + descripcion + "</p>" if descripcion else ""}
  </header>
{banner_html}
{secciones_html}
</div>
<script>
{_JS}
</script>
</body>
</html>"""


def _render_banner(banner: dict) -> str:
    etiqueta = html.escape(banner.get("etiqueta", ""))
    titulo = html.escape(banner.get("titulo", ""))
    desc = html.escape(banner.get("descripcion", ""))

    columnas_html = ""
    columnas = banner.get("columnas", [])
    if columnas:
        cols = ""
        for col in columnas:
            sub = html.escape(col.get("subtitulo", ""))
            tit = html.escape(col.get("titulo", ""))
            txt = html.escape(col.get("texto", ""))
            cols += f"""<div class="banner-col">
        <div class="banner-col-title">{sub}</div>
        <h3>{tit}</h3>
        <p>{txt}</p>
      </div>\n"""
        columnas_html = f'<div class="banner-cols">{cols}</div>'

    return f"""  <div class="compare-banner">
    {"<div class='banner-label'>" + etiqueta + "</div>" if etiqueta else ""}
    <div class="banner-title">{titulo}</div>
    <div class="banner-sub">{desc}</div>
    {columnas_html}
  </div>
"""


def _render_categoria(categoria: dict, color: str, prefijo: str) -> str:
    nombre = html.escape(categoria.get("nombre", ""))
    icono = categoria.get("icono", "📂")
    style = _color_vars(color)

    etiquetas_html = ""
    for etiqueta in categoria.get("etiquetas", []):
        etiquetas_html += f'<span class="cat-pdu">{html.escape(etiqueta)}</span>'

    items_html = ""
    for indice_item, item in enumerate(categoria.get("items", [])):
        items_html += _render_item(
            item=item,
            color=color,
            nivel=0,
            prefijo=f"{prefijo}-item-{indice_item}",
        )

    return f"""    <section class="cat" style="{style}">
      <div class="cat-head">
        <span class="cat-icon">{icono}</span>
        <span class="cat-name">{nombre}</span>
        {etiquetas_html}
      </div>
      <div class="tools">
{items_html}
      </div>
    </section>
"""


def _render_item(item: dict, color: str, nivel: int, prefijo: str) -> str:
    nombre = html.escape(item.get("nombre", ""))
    descripcion = html.escape(item.get("descripcion", ""))
    etiqueta = item.get("etiqueta", "")
    detalle = item.get("detalle") or {}
    subitems = item.get("subitems", []) or []

    badge_html = ""
    if etiqueta:
        badge_html = (
            f' <span class="badge" style="{_badge_style(color)}">{html.escape(etiqueta)}</span>'
        )

    nivel_class = ""
    if nivel == 1:
        nivel_class = " child"
    elif nivel >= 2:
        nivel_class = " child2"

    contenido_extra = []
    texto_detalle = _texto_html(detalle.get("texto", ""))
    if texto_detalle:
        contenido_extra.append(f'<div class="tool-detail-text">{texto_detalle}</div>')

    nota = detalle.get("nota", "")
    if nota:
        contenido_extra.append(f'<div class="tool-note">{nota}</div>')

    if subitems:
        subitems_html = ""
        for indice_subitem, subitem in enumerate(subitems):
            subitems_html += _render_item(
                item=subitem,
                color=color,
                nivel=nivel + 1,
                prefijo=f"{prefijo}-sub-{indice_subitem}",
            )
        contenido_extra.append(f'<div class="tool-subitems">{subitems_html}</div>')

    tiene_contenido_extra = bool(contenido_extra)
    es_contraible = bool(item.get("contraible", False) and tiene_contenido_extra)
    mostrar_abierto = bool(item.get("mostrar_abierto", False))
    cuerpo_html = "".join(contenido_extra)

    encabezado = (
        f'<div class="tool-name">{nombre}{badge_html}</div>'
        + (f'<div class="tool-desc">{descripcion}</div>' if descripcion else "")
    )

    if es_contraible:
        cuerpo_id = _crear_id_unico(prefijo + nombre)
        clase_abierto = " open" if mostrar_abierto else ""
        atributo_oculto = "" if mostrar_abierto else " hidden"
        return f"""        <article class="tool{nivel_class} contraible{clase_abierto}">
          <button type="button" class="tool-toggle" aria-expanded="{'true' if mostrar_abierto else 'false'}" aria-controls="{cuerpo_id}">
            <span class="tool-toggle-main">{encabezado}</span>
            <span class="tool-arrow">⌄</span>
          </button>
          <div class="tool-body" id="{cuerpo_id}"{atributo_oculto}>
            {cuerpo_html}
          </div>
        </article>
"""

    if tiene_contenido_extra:
        return f"""        <article class="tool{nivel_class} fijo-abierto">
          {encabezado}
          <div class="tool-body visible">
            {cuerpo_html}
          </div>
        </article>
"""

    return f"""        <article class="tool{nivel_class}">
          {encabezado}
        </article>
"""


_JS = """
document.querySelectorAll('.tool-toggle').forEach((boton) => {
  boton.addEventListener('click', () => {
    const contenedor = boton.closest('.tool.contraible');
    const cuerpo = document.getElementById(boton.getAttribute('aria-controls'));
    const expandido = boton.getAttribute('aria-expanded') === 'true';
    boton.setAttribute('aria-expanded', String(!expandido));
    contenedor.classList.toggle('open', !expandido);
    if (expandido) {
      cuerpo.hidden = true;
      return;
    }
    cuerpo.hidden = false;
  });
});
"""


_CSS = """
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}

:root{
  --font-body:system-ui, -apple-system, 'Segoe UI', sans-serif;
  --font-mono:'Courier New', monospace;
  --bg-page:#f5f6f8;
  --bg-card:#ffffff;
  --bg-card-hover:#fafbfc;
  --text-primary:#1a1d23;
  --text-secondary:#5a5f6d;
  --text-tertiary:#8b90a0;
  --border-light:#e8eaef;
  --border-medium:#d4d7de;
  --shadow-sm:0 1px 3px rgba(0,0,0,.04), 0 1px 2px rgba(0,0,0,.06);
  --shadow-md:0 4px 16px rgba(0,0,0,.06), 0 2px 6px rgba(0,0,0,.04);
  --shadow-tool:0 1px 4px rgba(0,0,0,.03);
  --shadow-tool-hover:0 4px 20px rgba(0,0,0,.08), 0 2px 8px rgba(0,0,0,.04);
  --radius-sm:.5rem;
  --radius-md:.75rem;
  --radius-lg:1rem;
  --radius-xl:1.25rem;
}

html{font-size:16px;-webkit-font-smoothing:antialiased}
body{font-family:var(--font-body);background:var(--bg-page);color:var(--text-primary);line-height:1.6;min-height:100vh}
.wrap{width:100%;max-width:1280px;margin:0 auto;padding:1rem 1rem 3rem}
.page-header{margin-bottom:1.5rem;padding:0 .25rem}
.page-header h1{font-size:1.5rem;font-weight:700;letter-spacing:-.02em;color:var(--text-primary);line-height:1.2}
.page-header p{font-size:.9rem;color:var(--text-secondary);margin-top:.35rem;line-height:1.5}

.compare-banner{
  background:linear-gradient(135deg,#0c1a35 0%,#162d58 50%,#1a3a6e 100%);
  border-radius:var(--radius-lg);padding:1.5rem;margin-bottom:1.75rem;
  color:#fff;position:relative;overflow:hidden;
  box-shadow:0 4px 24px rgba(12,26,53,.35);
}
.compare-banner::before{content:'';position:absolute;inset:0;
  background:radial-gradient(ellipse at 85% 20%, rgba(59,130,246,.2) 0%, transparent 50%),
  radial-gradient(ellipse at 10% 80%, rgba(99,102,241,.1) 0%, transparent 50%);pointer-events:none}
.compare-banner>*{position:relative;z-index:1}
.banner-label{font-family:var(--font-mono);font-size:.65rem;font-weight:600;letter-spacing:.12em;text-transform:uppercase;opacity:.5;margin-bottom:.5rem}
.banner-title{font-size:1.25rem;font-weight:700;margin-bottom:.6rem;letter-spacing:-.01em;line-height:1.3}
.banner-sub{font-size:.875rem;opacity:.7;margin-bottom:1.25rem;max-width:70ch;line-height:1.6}
.banner-cols{display:grid;grid-template-columns:1fr;gap:.75rem;margin-top:1rem}
.banner-col{background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.12);border-radius:var(--radius-md);padding:1rem}
.banner-col-title{font-family:var(--font-mono);font-size:.7rem;font-weight:700;letter-spacing:.08em;text-transform:uppercase;opacity:.6;margin-bottom:.4rem}
.banner-col h3{font-size:1rem;font-weight:700;margin-bottom:.35rem}
.banner-col p{font-size:.8rem;opacity:.65;line-height:1.55}

.section-title{font-family:var(--font-mono);font-size:.7rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:var(--text-tertiary);padding:0 .25rem;margin:2rem 0 1rem}
.grid{display:grid;grid-template-columns:1fr;gap:1.25rem;margin-bottom:1rem}

.cat{border-radius:var(--radius-lg);overflow:hidden;border:1.5px solid var(--cat-border);background:var(--bg-card);box-shadow:var(--shadow-sm);transition:box-shadow .2s ease}
.cat:hover{box-shadow:var(--shadow-md)}
.cat-head{padding:.85rem 1.1rem;display:flex;align-items:center;gap:.6rem;flex-wrap:wrap;background:var(--cat-head-bg);border-bottom:1.5px solid var(--cat-border)}
.cat-icon{font-size:1.05rem;line-height:1;flex-shrink:0}
.cat-name{font-family:var(--font-mono);font-size:.7rem;font-weight:700;color:var(--cat-color);letter-spacing:.06em;text-transform:uppercase}
.cat-pdu{font-family:var(--font-mono);font-size:.6rem;font-weight:600;padding:.2em .6em;border-radius:2rem;background:rgba(0,0,0,.04);color:var(--text-secondary);letter-spacing:.03em;white-space:nowrap}
.tools{padding:.65rem;display:flex;flex-direction:column;gap:.45rem}

.tool{background:var(--bg-card);border:1.5px solid var(--border-light);border-radius:var(--radius-md);padding:.95rem 1rem;box-shadow:var(--shadow-tool)}
.tool.child{margin-left:.85rem;border-left:3px solid var(--cat-color);background:var(--cat-soft)}
.tool.child2{margin-left:1.7rem;border-left:3px solid var(--cat-color);background:var(--cat-soft);opacity:.97}
.tool-name{font-size:.95rem;font-weight:700;color:var(--text-primary);margin-bottom:.25rem;display:flex;align-items:center;gap:.5rem;flex-wrap:wrap;line-height:1.4}
.tool-desc{font-size:.85rem;color:var(--text-secondary);line-height:1.55}
.badge{font-family:var(--font-mono);font-size:.6rem;font-weight:600;padding:.2em .6em;border-radius:.5rem;letter-spacing:.04em;white-space:nowrap}

.tool.contraible,.tool.fijo-abierto{padding:0;overflow:hidden}
.tool-toggle{width:100%;border:0;background:none;padding:.95rem 1rem;display:flex;align-items:center;justify-content:space-between;gap:1rem;text-align:left;cursor:pointer;color:inherit}
.tool-toggle:hover{background:var(--bg-card-hover)}
.tool-toggle-main{display:block;flex:1}
.tool-arrow{font-size:1rem;color:var(--text-tertiary);transition:transform .2s ease,color .2s ease;flex-shrink:0}
.tool.contraible.open .tool-arrow{transform:rotate(180deg);color:var(--cat-color)}
.tool-body{padding:0 1rem 1rem;border-top:1px solid var(--border-light);background:linear-gradient(180deg,var(--cat-soft),rgba(255,255,255,.9))}
.tool-body.visible{display:block}
.tool-detail-text{font-size:.9rem;color:var(--text-secondary);line-height:1.7;padding-top:.9rem}
.tool-note{margin-top:.85rem;padding:.9rem 1rem;border-radius:var(--radius-md);background:var(--cat-soft-strong);border:1px solid var(--cat-border);font-size:.85rem;color:var(--text-secondary)}
.tool-note strong{color:var(--text-primary)}
.tool-subitems{display:flex;flex-direction:column;gap:.45rem;margin-top:.9rem}

::-webkit-scrollbar{width:8px}
::-webkit-scrollbar-track{background:transparent}
::-webkit-scrollbar-thumb{background:#c8cad0;border-radius:4px}
::-webkit-scrollbar-thumb:hover{background:#a8aab2}
.tool-toggle:focus-visible{outline:2px solid var(--cat-color);outline-offset:-2px}

@media (min-width: 640px){
  .wrap{padding:1.5rem 1.5rem 3rem}
  .page-header h1{font-size:1.7rem}
  .compare-banner{padding:1.75rem}
  .banner-title{font-size:1.35rem}
  .banner-cols{grid-template-columns:1fr 1fr}
  .grid{grid-template-columns:repeat(2,1fr);gap:1.25rem}
}
@media (min-width: 1024px){
  .wrap{padding:2rem 2.5rem 4rem}
  .page-header{margin-bottom:2rem}
  .page-header h1{font-size:1.85rem}
  .page-header p{font-size:.95rem}
  .compare-banner{padding:2rem 2.25rem;margin-bottom:2rem;border-radius:var(--radius-xl)}
  .banner-title{font-size:1.5rem}
  .banner-sub{font-size:.925rem}
  .grid{grid-template-columns:repeat(3,1fr);gap:1.5rem}
  .cat-head{padding:.9rem 1.25rem}
}
@media (min-width: 1400px){
  .page-header h1{font-size:2rem}
  .banner-title{font-size:1.6rem}
}
"""
