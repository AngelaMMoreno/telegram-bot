"""
Motor de plantillas para generar páginas interactivas de temario
a partir de un fichero JSON sencillo.

Formato JSON esperado:
{
  "titulo": "Título de la página",
  "descripcion": "Subtítulo o descripción corta",
  "banner": {                          // opcional
    "etiqueta": "TEXTO PEQUEÑO",
    "titulo": "Título del banner",
    "descripcion": "Texto descriptivo",
    "columnas": [                      // opcional
      {"etiqueta": "COL1", "titulo": "...", "texto": "..."},
      {"etiqueta": "COL2", "titulo": "...", "texto": "..."}
    ],
    "badges": ["Badge 1", "Badge 2"]   // opcional, clicables si hay items con ese id
  },
  "categorias": [
    {
      "icono": "🖥️",
      "nombre": "Nombre de la categoría",
      "pdu": "PDU: Datos",             // opcional
      "color": "#7c3aed",              // color de la categoría
      "items": [
        {
          "id": "http",
          "nombre": "HTTP / HTTPS",
          "descripcion": "Transferencia de hipertexto",
          "badges": [{"texto": "Web", "color": "#7c3aed"}],  // opcional
          "hijo": false,               // opcional, indenta el item
          "detalle": {
            "titulo": "HTTP — Protocolo de transferencia",
            "texto": "Explicación larga...",
            "relaciones": "<strong>Puerto:</strong> 80/443...",
            "categoria": "🖥️ Capa 7",
            "color": "#7c3aed"
          }
        }
      ]
    }
  ]
}
"""

import html as _html
import json
import re


def _esc(text: str) -> str:
    return _html.escape(text)


def _slug(text: str) -> str:
    """Genera un id seguro a partir de texto."""
    return re.sub(r'[^a-z0-9]+', '_', text.lower()).strip('_')


def generar_pagina(data: dict) -> str:
    """Genera HTML completo a partir del dict de plantilla."""

    titulo = data.get("titulo", "Sin título")
    descripcion = data.get("descripcion", "")
    banner = data.get("banner")
    categorias = data.get("categorias", [])

    # Recoger todos los detalles en un dict JS
    detalles = {}
    for cat in categorias:
        cat_color = cat.get("color", "#6366F1")
        for item in cat.get("items", []):
            det = item.get("detalle")
            if det:
                item_id = item.get("id") or _slug(item.get("nombre", ""))
                detalles[item_id] = {
                    "title": det.get("titulo", item.get("nombre", "")),
                    "text": det.get("texto", ""),
                    "rel": det.get("relaciones", ""),
                    "cat": det.get("categoria", cat.get("nombre", "")),
                    "color": det.get("color", cat_color),
                }

    # También badges del banner que apunten a detalles
    if banner and banner.get("badges"):
        for badge_text in banner["badges"]:
            badge_id = _slug(badge_text)
            if badge_id not in detalles:
                # Buscar si hay un detalle especial para badges
                badge_detalles = data.get("detalles_extra", {})
                if badge_id in badge_detalles:
                    detalles[badge_id] = badge_detalles[badge_id]

    # Incluir detalles extra directamente
    for k, v in data.get("detalles_extra", {}).items():
        if k not in detalles:
            detalles[k] = v

    # ── CSS de categorías (colores dinámicos)
    cat_css = []
    for i, cat in enumerate(categorias):
        color = cat.get("color", "#6366F1")
        # Generar variantes de opacidad
        r, g, b = int(color[1:3], 16), int(color[3:5], 16), int(color[5:7], 16)
        cat_css.append(f""".c-{i}{{--cat-color:{color};--cat-border:rgba({r},{g},{b},.2);--cat-bg:rgba({r},{g},{b},.03)}}
.c-{i} .cat-head{{background:rgba({r},{g},{b},.06);border-bottom:1.5px solid rgba({r},{g},{b},.12)}}
.c-{i} .tool-arrow{{color:{color}}}""")

    # ── Banner HTML
    banner_html = ""
    if banner:
        cols_html = ""
        if banner.get("columnas"):
            cols_inner = ""
            for col in banner["columnas"]:
                cols_inner += f"""<div class="banner-col">
        <div class="banner-col-title">{_esc(col.get('etiqueta', ''))}</div>
        <h3>{_esc(col.get('titulo', ''))}</h3>
        <p>{_esc(col.get('texto', ''))}</p>
      </div>\n"""
            cols_html = f'<div class="banner-cols">{cols_inner}</div>'

        badges_html = ""
        if banner.get("badges"):
            badges_inner = ""
            for badge in banner["badges"]:
                bid = _slug(badge)
                badges_inner += f'<span class="banner-badge" tabindex="0" role="button" onclick="showDetail(\'{bid}\')">{_esc(badge)}</span>\n'
            badges_html = f'<div class="banner-badges">{badges_inner}</div>'

        banner_html = f"""<div class="banner">
    <div class="banner-label">{_esc(banner.get('etiqueta', ''))}</div>
    <div class="banner-title">{_esc(banner.get('titulo', ''))}</div>
    <div class="banner-sub">{_esc(banner.get('descripcion', ''))}</div>
    {cols_html}
    {badges_html}
  </div>"""

    # ── Categorías HTML
    cats_html = ""
    for i, cat in enumerate(categorias):
        pdu_html = ""
        if cat.get("pdu"):
            pdu_html = f'<span class="cat-pdu">{_esc(cat["pdu"])}</span>'

        items_html = ""
        for item in cat.get("items", []):
            item_id = item.get("id") or _slug(item.get("nombre", ""))
            badges = ""
            for b in item.get("badges", []):
                bcolor = b.get("color", cat.get("color", "#6366F1"))
                r, g, b_ = int(bcolor[1:3], 16), int(bcolor[3:5], 16), int(bcolor[5:7], 16)
                badges += f' <span class="badge" style="background:rgba({r},{g},{b_},.1);color:{bcolor}">{_esc(b["texto"])}</span>'

            child_class = " child" if item.get("hijo") else ""
            items_html += f"""<div class="tool{child_class}" tabindex="0" role="button" onclick="showDetail('{_esc(item_id)}')">
          <div class="tool-name">{_esc(item.get('nombre', ''))}{badges}</div>
          <div class="tool-desc">{_esc(item.get('descripcion', ''))}</div>
          <span class="tool-arrow">›</span>
        </div>\n"""

        cats_html += f"""<div class="cat c-{i}">
      <div class="cat-head">
        <span class="cat-icon">{cat.get('icono', '📁')}</span>
        <span class="cat-name">{_esc(cat.get('nombre', ''))}</span>
        {pdu_html}
      </div>
      <div class="tools">{items_html}</div>
    </div>\n"""

    # ── Data JS
    data_js = json.dumps(detalles, ensure_ascii=False)

    return f"""<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>{_esc(titulo)}</title>
<link rel="preconnect" href="https://fonts.googleapis.com/">
<link rel="preconnect" href="https://fonts.gstatic.com/" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;600;700&family=JetBrains+Mono:wght@400;600&display=swap" rel="stylesheet">
<style>
{_CSS_PLANTILLA}
{chr(10).join(cat_css)}
</style>
</head>
<body>

<div class="wrap">

  <header class="page-header">
    <h1>{_esc(titulo)}</h1>
    <p>{_esc(descripcion)}</p>
  </header>

  {banner_html}

  <div class="grid">
    {cats_html}
  </div>

  <!-- Detail Panel -->
  <div class="detail-panel" id="detail-panel">
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

</div>

<script>
const data={data_js};

function showDetail(id){{
  const d=data[id];
  if(!d) return;
  const p=document.getElementById('detail-panel');
  document.getElementById('detail-cat-label').textContent=d.cat||'';
  document.getElementById('detail-title').textContent=d.title;
  document.getElementById('detail-text').textContent=d.text;
  document.getElementById('detail-rel').innerHTML=d.rel;
  const c=d.color||'#6366F1';
  const r=parseInt(c.slice(1,3),16),g=parseInt(c.slice(3,5),16),b=parseInt(c.slice(5,7),16);
  p.style.setProperty('--detail-color', c);
  p.style.setProperty('--detail-bg', 'rgba('+r+','+g+','+b+',.04)');
  p.style.setProperty('--detail-note-bg', 'rgba('+r+','+g+','+b+',.04)');
  p.style.setProperty('--detail-note-border', 'rgba('+r+','+g+','+b+',.15)');
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
document.querySelectorAll('.tool[tabindex], .banner-badge[tabindex]').forEach(el=>{{
  el.addEventListener('keydown', function(e){{
    if(e.key === 'Enter' || e.key === ' '){{
      e.preventDefault();
      this.click();
    }}
  }});
}});
</script>

</body>
</html>"""


# ── CSS base de las plantillas (extraído y unificado de los ejemplos) ──

_CSS_PLANTILLA = """
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}

:root{
  --font-body:'DM Sans', system-ui, -apple-system, sans-serif;
  --font-mono:'JetBrains Mono', monospace;
  --bg-page:#f5f6f8;
  --bg-card:#ffffff;
  --bg-card-hover:#fafbfc;
  --bg-detail:#ffffff;
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

html{font-size:16px;-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale}
body{font-family:var(--font-body);background:var(--bg-page);color:var(--text-primary);line-height:1.6;min-height:100vh}

/* Layout */
.wrap{width:100%;max-width:1280px;margin:0 auto;padding:1rem 1rem 3rem}

/* Page header */
.page-header{margin-bottom:1.5rem;padding:0 .25rem}
.page-header h1{font-size:1.5rem;font-weight:700;letter-spacing:-.02em;color:var(--text-primary);line-height:1.2}
.page-header p{font-size:.9rem;color:var(--text-secondary);margin-top:.35rem;line-height:1.5}

/* Banner */
.banner{
  background:linear-gradient(135deg,#0c1a35 0%,#162d58 50%,#1a3a6e 100%);
  border-radius:var(--radius-lg);padding:1.5rem;margin-bottom:1.75rem;
  color:#fff;position:relative;overflow:hidden;
  box-shadow:0 4px 24px rgba(12,26,53,.35);
}
.banner::before{content:'';position:absolute;inset:0;
  background:radial-gradient(ellipse at 85% 20%, rgba(59,130,246,.2) 0%, transparent 50%),
  radial-gradient(ellipse at 10% 80%, rgba(99,102,241,.1) 0%, transparent 50%);pointer-events:none}
.banner::after{content:'';position:absolute;top:-50%;right:-30%;width:60%;height:200%;
  background:linear-gradient(135deg, transparent 40%, rgba(255,255,255,.03) 50%, transparent 60%);pointer-events:none}
.banner>*{position:relative;z-index:1}
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
.banner-badges{display:flex;flex-wrap:wrap;gap:.4rem;margin-top:1rem}
.banner-badge{font-family:var(--font-mono);font-size:.65rem;font-weight:600;
  padding:.3em .85em;border-radius:2rem;background:rgba(255,255,255,.08);
  border:1px solid rgba(255,255,255,.15);color:rgba(255,255,255,.85);
  cursor:pointer;transition:all .2s ease;letter-spacing:.04em;user-select:none}
.banner-badge:hover{background:rgba(255,255,255,.18);border-color:rgba(255,255,255,.35);transform:translateY(-1px)}

@media(min-width:640px){.banner-cols{grid-template-columns:repeat(2,1fr)}}

/* Grid */
.grid{display:grid;grid-template-columns:1fr;gap:1.25rem}

/* Category card */
.cat{border-radius:var(--radius-lg);overflow:hidden;border:1.5px solid var(--cat-border);
  background:var(--bg-card);box-shadow:var(--shadow-sm)}
.cat-head{display:flex;align-items:center;gap:.6rem;padding:.85rem 1.1rem;font-size:.85rem;font-weight:600}
.cat-icon{font-size:1.15rem}
.cat-name{flex:1}
.cat-pdu{font-family:var(--font-mono);font-size:.65rem;font-weight:600;
  padding:.25em .7em;border-radius:2rem;background:rgba(0,0,0,.04);color:var(--text-secondary);
  letter-spacing:.03em}

/* Tool items */
.tools{display:flex;flex-direction:column}
.tool{display:flex;align-items:flex-start;gap:.6rem;padding:.75rem 1.1rem;padding-right:2rem;
  border-top:1px solid var(--border-light);cursor:pointer;position:relative;
  transition:background .15s;background:var(--bg-card)}
.tool:hover{background:var(--bg-card-hover)}
.tool.child{padding-left:2rem}
.tool-name{font-size:.82rem;font-weight:600;color:var(--text-primary);line-height:1.4}
.tool-desc{font-size:.78rem;color:var(--text-secondary);line-height:1.5;margin-top:.15rem}
.tool-arrow{position:absolute;right:.9rem;top:50%;transform:translateY(-50%);
  font-size:1.1rem;font-weight:300;transition:transform .15s}
.tool:hover .tool-arrow{transform:translateY(-50%) translateX(2px)}

/* Badges */
.badge{font-family:var(--font-mono);font-size:.6rem;font-weight:600;
  padding:.2em .6em;border-radius:2rem;vertical-align:middle;margin-left:.35rem;letter-spacing:.03em}

/* Detail panel */
.detail-panel{
  --detail-color:#4036b0;
  --detail-bg:rgba(64,54,176,.04);
  --detail-note-bg:rgba(64,54,176,.04);
  --detail-note-border:rgba(64,54,176,.15);
  margin-top:1.5rem;border-radius:var(--radius-lg);overflow:hidden;
  border:1.5px solid color-mix(in srgb, var(--detail-color) 20%, transparent);
  background:var(--detail-bg);box-shadow:var(--shadow-md);
  max-height:0;opacity:0;transition:max-height .4s ease,opacity .3s ease,margin .3s ease;
  margin-bottom:0}
.detail-panel.show{max-height:600px;opacity:1;margin-bottom:1.5rem}
.detail-stripe{height:4px;background:var(--detail-color)}
.detail-inner{padding:1.25rem 1.5rem 1.5rem}
.detail-cat-label{font-family:var(--font-mono);font-size:.65rem;font-weight:600;
  letter-spacing:.08em;text-transform:uppercase;color:var(--detail-color);margin-bottom:.6rem}
.detail-header{display:flex;justify-content:space-between;align-items:flex-start;gap:1rem;margin-bottom:.8rem}
.detail-title{font-size:1.05rem;font-weight:700;color:var(--text-primary);line-height:1.35}
.close-btn{font-family:var(--font-mono);font-size:.7rem;padding:.35em .9em;border-radius:2rem;
  background:rgba(0,0,0,.04);border:1px solid var(--border-light);color:var(--text-secondary);
  cursor:pointer;transition:all .15s;white-space:nowrap;flex-shrink:0}
.close-btn:hover{background:rgba(0,0,0,.08);color:var(--text-primary)}
.detail-text{font-size:.88rem;color:var(--text-secondary);line-height:1.7;margin-bottom:1rem}
.rel-note{font-size:.82rem;line-height:1.65;padding:1rem 1.15rem;
  border-radius:var(--radius-md);background:var(--detail-note-bg);
  border:1px solid var(--detail-note-border);color:var(--text-primary)}
.rel-note:empty{display:none}
.rel-note strong{font-weight:600}

/* Responsive */
@media(min-width:640px){
  .grid{grid-template-columns:repeat(2,1fr)}
  .page-header h1{font-size:1.75rem}
}
@media(min-width:1024px){
  .grid{grid-template-columns:repeat(2,1fr)}
  .wrap{padding:1.5rem 2rem 3rem}
}

/* Focus & accessibility */
.tool:focus-visible,.banner-badge:focus-visible,.close-btn:focus-visible{
  outline:2px solid var(--cat-color, #4036b0);outline-offset:2px}
@media(hover:none){
  .tool{padding:.85rem 1.1rem;padding-right:2.4rem}
  .banner-badge{padding:.4em 1em;font-size:.75rem}
}

/* Section title */
.section-title{font-size:.8rem;font-weight:700;text-transform:uppercase;letter-spacing:.08em;
  color:var(--text-tertiary);padding:.5rem .25rem;margin-top:1.5rem;margin-bottom:.5rem}
"""
