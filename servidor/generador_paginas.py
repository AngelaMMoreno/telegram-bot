"""
Generador de páginas HTML de teoría a partir de plantillas YAML/JSON.

Formato de plantilla (YAML):
─────────────────────────────
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
    - subtitulo: "Columna 2"
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
          - nombre: "Elemento"
            descripcion: "Breve descripción"
            etiqueta: "Badge"    # Opcional
            nivel: 0             # 0=normal, 1=hijo, 2=subhijo
            detalle:             # Opcional — panel expandible
              texto: "Texto completo..."
              nota: "Nota adicional (admite <strong>HTML</strong>)"
"""

import html
import json
import hashlib

# ── Colores por defecto para categorías ──────────────────────────────────────

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
    )


def _badge_style(color: str) -> str:
    r, g, b = int(color[1:3], 16), int(color[3:5], 16), int(color[5:7], 16)
    return f"background:rgba({r},{g},{b},.1);color:{color}"


def _detail_id(nombre: str) -> str:
    """Genera un ID seguro para el panel de detalle."""
    return hashlib.md5(nombre.encode()).hexdigest()[:8]


def generar_html(plantilla: dict) -> str:
    """Convierte una plantilla (dict) en HTML completo."""
    titulo = html.escape(plantilla.get("titulo", "Sin título"))
    descripcion = html.escape(plantilla.get("descripcion", ""))

    # Recopilar todos los detalles para el JS
    detalles = {}

    # ── Banner ───────────────────────────────────────────────────────────────
    banner_html = ""
    banner = plantilla.get("banner")
    if banner:
        banner_html = _render_banner(banner)

    # ── Secciones ────────────────────────────────────────────────────────────
    secciones_html = ""
    secciones = plantilla.get("secciones", [])

    # Si no hay secciones pero hay categorías directas (formato simplificado)
    if not secciones and "categorias" in plantilla:
        secciones = [{"categorias": plantilla["categorias"]}]

    color_idx = 0
    for seccion in secciones:
        sec_titulo = seccion.get("titulo", "")
        if sec_titulo:
            secciones_html += (
                f'<div class="section-title">{html.escape(sec_titulo)}</div>\n'
            )

        secciones_html += '<div class="grid">\n'
        for cat in seccion.get("categorias", []):
            color = cat.get("color", _COLORES_DEFAULT[color_idx % len(_COLORES_DEFAULT)])
            color_idx += 1
            secciones_html += _render_categoria(cat, color, detalles)
        secciones_html += '</div>\n'

    # ── Detalle panel + JS ───────────────────────────────────────────────────
    detail_panel = ""
    detail_js = ""
    if detalles:
        detail_panel = _render_detail_panel()
        detail_js = _render_detail_js(detalles)

    # ── CSS categorías dinámicas ─────────────────────────────────────────────
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
{detail_panel}
</div>
<script>
{detail_js}
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
            t = html.escape(col.get("titulo", ""))
            txt = html.escape(col.get("texto", ""))
            cols += f"""<div class="banner-col">
        <div class="banner-col-title">{sub}</div>
        <h3>{t}</h3>
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


def _render_categoria(cat: dict, color: str, detalles: dict) -> str:
    nombre = html.escape(cat.get("nombre", ""))
    icono = cat.get("icono", "📂")
    style = _color_vars(color)

    # Etiquetas de cabecera (como PDU)
    etiquetas_html = ""
    for et in cat.get("etiquetas", []):
        etiquetas_html += f'<span class="cat-pdu">{html.escape(et)}</span>'

    # Items
    items_html = ""
    for item in cat.get("items", []):
        items_html += _render_item(item, color, detalles)

    return f"""    <div class="cat" style="{style}">
      <div class="cat-head">
        <span class="cat-icon">{icono}</span>
        <span class="cat-name">{nombre}</span>
        {etiquetas_html}
      </div>
      <div class="tools">
{items_html}
      </div>
    </div>
"""


def _render_item(item: dict, color: str, detalles: dict) -> str:
    nombre = html.escape(item.get("nombre", ""))
    desc = html.escape(item.get("descripcion", ""))
    nivel = item.get("nivel", 0)
    etiqueta = item.get("etiqueta", "")

    nivel_class = ""
    if nivel == 1:
        nivel_class = " child"
    elif nivel >= 2:
        nivel_class = " child2"

    badge_html = ""
    if etiqueta:
        badge_html = f' <span class="badge" style="{_badge_style(color)}">{html.escape(etiqueta)}</span>'

    # Si tiene detalle, hacerlo clickable
    detalle = item.get("detalle")
    onclick = ""
    if detalle:
        did = _detail_id(item.get("nombre", ""))
        r, g, b = int(color[1:3], 16), int(color[3:5], 16), int(color[5:7], 16)
        detalles[did] = {
            "title": item.get("nombre", ""),
            "text": detalle.get("texto", ""),
            "rel": detalle.get("nota", ""),
            "cat": nombre,
            "color": color,
            "bg": f"rgba({r},{g},{b},.04)",
            "notebg": f"rgba({r},{g},{b},.04)",
            "noteborder": f"rgba({r},{g},{b},.15)",
        }
        onclick = f' tabindex="0" role="button" onclick="showDetail(\'{did}\')"'

    arrow = '<span class="tool-arrow">›</span>' if detalle else ""

    return f"""        <div class="tool{nivel_class}"{onclick}>
          <div class="tool-name">{nombre}{badge_html}</div>
          <div class="tool-desc">{desc}</div>
          {arrow}
        </div>
"""


def _render_detail_panel() -> str:
    return """  <div class="detail-panel" id="detail-panel">
    <div class="detail-stripe"></div>
    <div class="detail-inner">
      <div class="detail-cat-label" id="detail-cat-label"></div>
      <div class="detail-header">
        <div class="detail-title" id="detail-title"></div>
        <button class="close-btn" onclick="closeDetail()">✕ cerrar</button>
      </div>
      <div class="detail-text" id="detail-text"></div>
      <div class="rel-note" id="detail-rel"></div>
    </div>
  </div>
"""


def _render_detail_js(detalles: dict) -> str:
    data_json = json.dumps(detalles, ensure_ascii=False)
    return f"""const data={data_json};

function showDetail(id){{
  const d=data[id];
  if(!d) return;
  const p=document.getElementById('detail-panel');
  document.getElementById('detail-cat-label').textContent=d.cat||'';
  document.getElementById('detail-title').textContent=d.title;
  document.getElementById('detail-text').textContent=d.text;
  document.getElementById('detail-rel').innerHTML=d.rel;
  p.style.setProperty('--detail-color', d.color);
  p.style.setProperty('--detail-bg', d.bg);
  p.style.setProperty('--detail-note-bg', d.notebg);
  p.style.setProperty('--detail-note-border', d.noteborder);
  p.classList.remove('show');
  void p.offsetWidth;
  p.classList.add('show');
  setTimeout(()=>p.scrollIntoView({{behavior:'smooth',block:'nearest'}}),50);
}}

function closeDetail(){{
  document.getElementById('detail-panel').classList.remove('show');
}}

document.addEventListener('keydown', function(e){{
  if(e.key === 'Escape') closeDetail();
}});
document.querySelectorAll('.tool[tabindex]').forEach(el=>{{
  el.addEventListener('keydown', function(e){{
    if(e.key === 'Enter' || e.key === ' '){{
      e.preventDefault();
      this.click();
    }}
  }});
}});
"""


# ── CSS completo (extraído y generalizado de las páginas de ejemplo) ─────────

_CSS = """
/* RESET & BASE */
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
  --shadow-lg:0 8px 32px rgba(0,0,0,.08), 0 4px 12px rgba(0,0,0,.04);
  --shadow-tool:0 1px 4px rgba(0,0,0,.03);
  --shadow-tool-hover:0 4px 20px rgba(0,0,0,.08), 0 2px 8px rgba(0,0,0,.04);
  --radius-sm:.5rem;
  --radius-md:.75rem;
  --radius-lg:1rem;
  --radius-xl:1.25rem;
}

html{font-size:16px;-webkit-font-smoothing:antialiased}
body{font-family:var(--font-body);background:var(--bg-page);color:var(--text-primary);line-height:1.6;min-height:100vh}

/* LAYOUT */
.wrap{width:100%;max-width:1280px;margin:0 auto;padding:1rem 1rem 3rem}

/* PAGE HEADER */
.page-header{margin-bottom:1.5rem;padding:0 .25rem}
.page-header h1{font-size:1.5rem;font-weight:700;letter-spacing:-.02em;color:var(--text-primary);line-height:1.2}
.page-header p{font-size:.9rem;color:var(--text-secondary);margin-top:.35rem;line-height:1.5}

/* BANNER */
.compare-banner{
  background:linear-gradient(135deg,#0c1a35 0%,#162d58 50%,#1a3a6e 100%);
  border-radius:var(--radius-lg);padding:1.5rem;margin-bottom:1.75rem;
  color:#fff;position:relative;overflow:hidden;
  box-shadow:0 4px 24px rgba(12,26,53,.35);
}
.compare-banner::before{content:'';position:absolute;inset:0;
  background:radial-gradient(ellipse at 85% 20%, rgba(59,130,246,.2) 0%, transparent 50%),
  radial-gradient(ellipse at 10% 80%, rgba(99,102,241,.1) 0%, transparent 50%);pointer-events:none}
.compare-banner::after{content:'';position:absolute;top:-50%;right:-30%;width:60%;height:200%;
  background:linear-gradient(135deg, transparent 40%, rgba(255,255,255,.03) 50%, transparent 60%);pointer-events:none}
.compare-banner>*{position:relative;z-index:1}

.banner-label{font-family:var(--font-mono);font-size:.65rem;font-weight:600;
  letter-spacing:.12em;text-transform:uppercase;opacity:.5;margin-bottom:.5rem}
.banner-title{font-size:1.25rem;font-weight:700;margin-bottom:.6rem;letter-spacing:-.01em;line-height:1.3}
.banner-sub{font-size:.875rem;opacity:.7;margin-bottom:1.25rem;max-width:70ch;line-height:1.6}

.banner-cols{display:grid;grid-template-columns:1fr;gap:.75rem;margin-top:1rem}
.banner-col{background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.12);
  border-radius:var(--radius-md);padding:1rem}
.banner-col-title{font-family:var(--font-mono);font-size:.7rem;font-weight:700;
  letter-spacing:.08em;text-transform:uppercase;opacity:.6;margin-bottom:.4rem}
.banner-col h3{font-size:1rem;font-weight:700;margin-bottom:.35rem}
.banner-col p{font-size:.8rem;opacity:.65;line-height:1.55}

/* SECTION TITLE */
.section-title{font-family:var(--font-mono);font-size:.7rem;font-weight:700;
  letter-spacing:.1em;text-transform:uppercase;color:var(--text-tertiary);
  padding:0 .25rem;margin:2rem 0 1rem}

/* GRID */
.grid{display:grid;grid-template-columns:1fr;gap:1.25rem;margin-bottom:1rem}

/* CATEGORY CARD */
.cat{border-radius:var(--radius-lg);overflow:hidden;
  border:1.5px solid var(--cat-border);background:var(--bg-card);
  box-shadow:var(--shadow-sm);transition:box-shadow .2s ease}
.cat:hover{box-shadow:var(--shadow-md)}

.cat-head{padding:.85rem 1.1rem;display:flex;align-items:center;gap:.6rem;
  background:var(--cat-head-bg);border-bottom:1.5px solid var(--cat-border)}
.cat-icon{font-size:1.05rem;line-height:1;flex-shrink:0}
.cat-name{font-family:var(--font-mono);font-size:.7rem;font-weight:700;
  color:var(--cat-color);letter-spacing:.06em;text-transform:uppercase}
.cat-pdu{font-family:var(--font-mono);font-size:.6rem;font-weight:600;
  padding:.2em .6em;border-radius:2rem;background:rgba(0,0,0,.04);
  color:var(--text-secondary);letter-spacing:.03em;white-space:nowrap;margin-left:auto}

.tools{padding:.65rem;display:flex;flex-direction:column;gap:.45rem}

/* TOOL CARD */
.tool{background:var(--bg-card);border:1.5px solid var(--border-light);
  border-radius:var(--radius-md);padding:.85rem 1rem;padding-right:2.2rem;
  cursor:default;transition:all .2s ease;position:relative;box-shadow:var(--shadow-tool)}
.tool[tabindex]{cursor:pointer}
.tool[tabindex]:hover{border-color:var(--cat-color);box-shadow:var(--shadow-tool-hover);
  transform:translateY(-1px);background:var(--bg-card-hover)}
.tool[tabindex]:active{transform:translateY(0);box-shadow:var(--shadow-sm)}

.tool.child{margin-left:.85rem;border-left:3px solid var(--cat-color);padding-left:.85rem}
.tool.child2{margin-left:1.7rem;border-left:3px solid var(--cat-color);padding-left:.85rem;opacity:.92}

.tool-name{font-size:.95rem;font-weight:700;color:var(--text-primary);margin-bottom:.3rem;
  display:flex;align-items:center;gap:.5rem;flex-wrap:wrap;line-height:1.4}
.tool-desc{font-size:.85rem;color:var(--text-secondary);line-height:1.55}

.badge{font-family:var(--font-mono);font-size:.6rem;font-weight:600;
  padding:.2em .6em;border-radius:.5rem;letter-spacing:.04em;white-space:nowrap}

.tool-arrow{position:absolute;right:.85rem;top:50%;transform:translateY(-50%);
  font-size:1.2rem;color:var(--text-tertiary);font-weight:300;
  transition:transform .2s ease,color .2s ease}
.tool[tabindex]:hover .tool-arrow{color:var(--cat-color);transform:translateY(-50%) translateX(3px)}

/* DETAIL PANEL */
.detail-panel{position:relative;margin-top:2rem;border-radius:var(--radius-xl);
  background:var(--detail-bg,#fff);border:1.5px solid var(--border-light);
  box-shadow:var(--shadow-lg);overflow:hidden;
  max-height:0;opacity:0;transform:translateY(12px);
  transition:max-height .4s ease,opacity .3s ease,transform .3s ease;
  pointer-events:none}
.detail-panel.show{max-height:600px;opacity:1;transform:translateY(0);pointer-events:auto}

.detail-stripe{height:4px;background:var(--detail-color,#6366f1)}
.detail-inner{padding:1.5rem}

.detail-cat-label{font-family:var(--font-mono);font-size:.65rem;font-weight:600;
  letter-spacing:.1em;text-transform:uppercase;color:var(--detail-color,#6366f1);
  margin-bottom:.75rem}
.detail-header{display:flex;align-items:flex-start;justify-content:space-between;
  gap:1rem;margin-bottom:1rem;flex-wrap:wrap}
.detail-title{font-size:1.15rem;font-weight:700;color:var(--text-primary);line-height:1.3}

.close-btn{background:none;border:1.5px solid var(--border-light);border-radius:var(--radius-sm);
  padding:.35em .9em;font-size:.75rem;color:var(--text-secondary);cursor:pointer;
  transition:all .15s ease;white-space:nowrap;flex-shrink:0}
.close-btn:hover{background:var(--bg-card-hover);border-color:var(--border-medium);color:var(--text-primary)}

.detail-text{font-size:.925rem;color:var(--text-secondary);line-height:1.7;margin-bottom:1.25rem}

.rel-note{font-size:.85rem;line-height:1.65;padding:1rem 1.15rem;
  border-radius:var(--radius-md);
  background:var(--detail-note-bg,rgba(99,102,241,.04));
  border:1px solid var(--detail-note-border,rgba(99,102,241,.15));
  color:var(--text-secondary)}
.rel-note:empty{display:none}
.rel-note strong{color:var(--text-primary);font-weight:600}

/* RESPONSIVE */
@media (min-width: 640px){
  .wrap{padding:1.5rem 1.5rem 3rem}
  .page-header h1{font-size:1.7rem}
  .compare-banner{padding:1.75rem}
  .banner-title{font-size:1.35rem}
  .banner-cols{grid-template-columns:1fr 1fr}
  .grid{grid-template-columns:repeat(2,1fr);gap:1.25rem}
  .detail-inner{padding:1.75rem}
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
  .tool{padding:.95rem 1.1rem;padding-right:2.4rem}
  .tool-name{font-size:1rem}
  .tool-desc{font-size:.875rem}
  .detail-inner{padding:2rem 2.25rem}
  .detail-title{font-size:1.3rem}
  .detail-text{font-size:1rem}
  .rel-note{font-size:.925rem}
}
@media (min-width: 1400px){
  .page-header h1{font-size:2rem}
  .banner-title{font-size:1.6rem}
  .tool-name{font-size:1.05rem}
  .tool-desc{font-size:.9rem}
  .detail-title{font-size:1.4rem}
  .detail-text{font-size:1.05rem}
}

/* SCROLLBAR */
::-webkit-scrollbar{width:8px}
::-webkit-scrollbar-track{background:transparent}
::-webkit-scrollbar-thumb{background:#c8cad0;border-radius:4px}
::-webkit-scrollbar-thumb:hover{background:#a8aab2}

/* A11Y */
.tool:focus-visible,.close-btn:focus-visible{
  outline:2px solid var(--cat-color, #4036b0);outline-offset:2px}
@media (hover: none){
  .tool{padding:1rem 1.1rem;padding-right:2.4rem}
}
"""
