import cgi
import html
import io
import json
import mimetypes
import os
import signal
import threading
import urllib.parse
import warnings
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ─── Emojis predefinidos ────────────────────────────────────────────────────

EMOJIS = [
    "📁", "📂", "📄", "📝", "📊", "📈", "📉", "📋", "📌", "📍",
    "📎", "🗂️", "🗃️", "🗄️", "🖨️", "💼", "🗑️", "📬", "📯", "🔖",
    "🖼️", "🎵", "🎬", "📹", "📷", "📸", "🎤", "📻", "🎙️", "🎧",
    "🔑", "🔒", "🔓", "📦", "🎁", "💾", "💿", "📀", "🖥️", "💻",
    "📱", "⌨️", "🖱️", "🖲️", "🔌", "🔋", "📡", "☎️", "🔧", "🔩",
    "⭐", "❤️", "🔥", "✅", "❌", "⚠️", "ℹ️", "💡", "🔔", "🎯",
    "🏠", "🏢", "🚀", "🌍", "🌟", "🎨", "🎭", "🎪", "🎉", "🏆",
    "📚", "📖", "🔬", "🔭", "🧪", "🧬", "💊", "🏥", "🏫", "🏦",
    "🍕", "🍔", "☕", "🍺", "🎂", "🌈", "⚡", "❄️", "🌊", "🌺",
    "🐶", "🐱", "🦁", "🐘", "🦋", "🌳", "🌵", "🍀", "🌸", "🍁",
    "🎓", "🏅", "🎖️", "🥇", "🎗️", "🔐", "🛡️", "⚙️", "🔎", "📐",
    "🧲", "💎", "🪙", "💰", "📮", "🗺️", "🧭", "⛺", "🏕️", "🚁",
]

METADATA_FILE = ".metadata.json"

RUTA_ARCHIVOS_PUBLICOS = os.getenv(
    "RUTA_ARCHIVOS_PUBLICOS", "/mnt/data/ficheros"
)
PUERTO_ARCHIVOS_PUBLICOS = int(os.getenv("PUERTO_ARCHIVOS_PUBLICOS", "8000"))


# ─── Helpers ────────────────────────────────────────────────────────────────

def cargar_metadata(directorio: str) -> dict:
    path = os.path.join(directorio, METADATA_FILE)
    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {"files": {}}


def guardar_metadata(directorio: str, metadata: dict) -> None:
    path = os.path.join(directorio, METADATA_FILE)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(metadata, f, ensure_ascii=False, indent=2)


def obtener_icono(metadata: dict, nombre: str, es_dir: bool) -> str:
    return metadata.get("files", {}).get(nombre, "📁" if es_dir else "📄")


def format_size(size: int) -> str:
    if size < 1024:
        return f"{size} B"
    elif size < 1024 * 1024:
        return f"{size / 1024:.1f} KB"
    elif size < 1024 * 1024 * 1024:
        return f"{size / 1024 / 1024:.1f} MB"
    return f"{size / 1024 / 1024 / 1024:.1f} GB"


def asegurar_nombre_unico(directorio: str, nombre: str) -> str:
    base, ext = os.path.splitext(nombre)
    resultado = nombre
    contador = 1
    while os.path.exists(os.path.join(directorio, resultado)):
        resultado = f"{base}_{contador}{ext}"
        contador += 1
    return resultado


def obtener_todas_carpetas(base_dir: str, max_depth: int = 4) -> list[tuple[str, str]]:
    carpetas = [("/", "📁  /  (raíz)")]
    try:
        for root, dirs, _ in os.walk(base_dir):
            dirs[:] = sorted(
                [d for d in dirs if not d.startswith(".")],
                key=str.lower,
            )
            rel = os.path.relpath(root, base_dir)
            depth = rel.count(os.sep) if rel != "." else -1
            if depth >= max_depth:
                dirs.clear()
                continue
            if rel == ".":
                continue
            rel_path = "/" + rel.replace(os.sep, "/")
            indent = "  " * (depth + 1)
            carpetas.append((rel_path, f"📁{indent}{rel_path}"))
    except Exception:
        pass
    return carpetas


# ─── CSS compartido ─────────────────────────────────────────────────────────

_CSS_BASE = """
*{box-sizing:border-box;margin:0;padding:0}
:root{
  --pri:#6366F1;--pri-d:#4F46E5;--pri-light:#EEF2FF;
  --bg:#F1F5F9;--card:#fff;--text:#1E293B;--sub:#64748B;
  --border:#E2E8F0;--file-bg:#F0F9FF;--ok:#10B981;
}
body{font-family:system-ui,-apple-system,sans-serif;background:var(--bg);color:var(--text);min-height:100vh}
a{text-decoration:none;color:inherit}

/* ── header ── */
.hdr{background:linear-gradient(135deg,#6366F1,#8B5CF6);color:#fff;
  padding:14px 24px;display:flex;align-items:center;justify-content:space-between;
  box-shadow:0 2px 8px rgba(0,0,0,.2);gap:12px;flex-wrap:wrap}
.hdr-title{display:flex;align-items:center;gap:10px;font-size:20px;font-weight:700}
.hdr-actions{display:flex;gap:8px;flex-wrap:wrap}

/* ── breadcrumb ── */
.bc{background:#fff;padding:10px 24px;border-bottom:1px solid var(--border);
  font-size:13px;color:var(--sub);display:flex;align-items:center;gap:4px;flex-wrap:wrap}
.bc a{color:var(--pri);font-weight:500}.bc a:hover{text-decoration:underline}
.bc-sep{color:var(--border)}

/* ── stats bar ── */
.stats{padding:8px 24px;font-size:12px;color:var(--sub);
  display:flex;gap:12px;background:#fff;border-bottom:1px solid var(--border)}

/* ── grid ── */
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));
  gap:14px;padding:24px}

/* ── card ── */
.card{background:var(--card);border-radius:12px;padding:18px 12px 14px;
  text-align:center;border:1.5px solid var(--border);display:flex;
  flex-direction:column;align-items:center;gap:7px;
  transition:transform .15s,box-shadow .15s,border-color .15s;
  box-shadow:0 1px 3px rgba(0,0,0,.06)}
.card:hover{transform:translateY(-3px);box-shadow:0 6px 18px rgba(99,102,241,.18);
  border-color:var(--pri)}
.card.folder{background:var(--pri-light)}
.card.file{background:var(--file-bg)}
.card-emoji{font-size:38px;line-height:1}
.card-name{font-size:12px;font-weight:600;word-break:break-word;
  max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;width:100%}
.card-meta{font-size:11px;color:var(--sub)}

/* ── empty ── */
.empty{text-align:center;padding:80px 24px;color:var(--sub)}
.empty-ico{font-size:56px;margin-bottom:12px}

/* ── buttons ── */
.btn{display:inline-flex;align-items:center;gap:6px;padding:8px 16px;
  border-radius:8px;font-size:13px;font-weight:600;border:none;cursor:pointer;
  transition:opacity .15s,transform .1s}
.btn:hover{opacity:.88;transform:translateY(-1px)}
.btn-white{background:#fff;color:var(--pri)}
.btn-ghost{background:rgba(255,255,255,.18);color:#fff;border:1px solid rgba(255,255,255,.3)}
.btn-pri{background:linear-gradient(135deg,var(--pri),#8B5CF6);color:#fff}
.btn-sec{background:var(--pri-light);color:var(--pri-d)}

/* ── form page ── */
.form-wrap{max-width:700px;margin:32px auto;padding:0 20px 60px}
.form-card{background:#fff;border-radius:16px;padding:28px 32px;
  box-shadow:0 1px 4px rgba(0,0,0,.08);border:1px solid var(--border);margin-bottom:20px}
.form-card h2{font-size:17px;font-weight:700;margin-bottom:20px;
  display:flex;align-items:center;gap:8px;color:var(--text)}
.fg{margin-bottom:18px}
.fg label{display:block;font-size:13px;font-weight:600;margin-bottom:6px;color:var(--text)}
.fc{width:100%;padding:9px 13px;border:1.5px solid var(--border);border-radius:8px;
  font-size:14px;color:var(--text);background:#fff;transition:border-color .15s}
.fc:focus{outline:none;border-color:var(--pri);box-shadow:0 0 0 3px rgba(99,102,241,.12)}

/* ── drop zone ── */
.drop-zone{border:2px dashed var(--border);border-radius:12px;padding:36px;
  text-align:center;cursor:pointer;transition:border-color .15s,background .15s;
  color:var(--sub);position:relative}
.drop-zone:hover,.drop-zone.over{border-color:var(--pri);background:var(--pri-light)}
.drop-zone input[type=file]{position:absolute;inset:0;opacity:0;cursor:pointer;width:100%;height:100%}
.drop-ico{font-size:40px;margin-bottom:8px}
.drop-hint{font-size:13px}
.drop-name{font-size:14px;font-weight:600;color:var(--pri);margin-top:6px}

/* ── emoji picker ── */
.ep-wrap{border:1.5px solid var(--border);border-radius:12px;overflow:hidden}
.ep-preview{text-align:center;font-size:44px;padding:14px;
  background:var(--pri-light);border-bottom:1px solid var(--border)}
.ep-grid{display:grid;grid-template-columns:repeat(12,1fr);
  max-height:190px;overflow-y:auto;padding:8px;gap:3px}
@media(max-width:480px){.ep-grid{grid-template-columns:repeat(8,1fr)}}
.ep-btn{font-size:20px;background:none;border:2px solid transparent;border-radius:6px;
  padding:3px;cursor:pointer;transition:background .1s,border-color .1s;line-height:1}
.ep-btn:hover{background:var(--pri-light)}
.ep-btn.sel{border-color:var(--pri);background:var(--pri-light)}

/* ── submit ── */
.btn-submit{width:100%;padding:13px;background:linear-gradient(135deg,var(--pri),#8B5CF6);
  color:#fff;border:none;border-radius:10px;font-size:15px;font-weight:700;
  cursor:pointer;transition:opacity .15s}
.btn-submit:hover{opacity:.9}

/* ── divider ── */
.divider{text-align:center;position:relative;margin:24px 0;color:var(--sub);font-size:13px}
.divider::before{content:'';position:absolute;top:50%;left:0;right:0;height:1px;background:var(--border)}
.divider span{position:relative;background:#fff;padding:0 14px}

/* ── alert ── */
.alert{padding:10px 16px;border-radius:8px;font-size:13px;margin-bottom:16px}
.alert-ok{background:#D1FAE5;color:#065F46;border:1px solid #6EE7B7}
.alert-err{background:#FEE2E2;color:#991B1B;border:1px solid #FCA5A5}
"""

# ─── JavaScript compartido ───────────────────────────────────────────────────

_JS = """
function selectEmoji(btn, previewId, inputId) {
  var grid = btn.closest('.ep-grid');
  grid.querySelectorAll('.ep-btn').forEach(function(b){ b.classList.remove('sel'); });
  btn.classList.add('sel');
  document.getElementById(previewId).textContent = btn.dataset.e;
  document.getElementById(inputId).value = btn.dataset.e;
}

function initDrop(zoneId, inputId, nameId) {
  var zone = document.getElementById(zoneId);
  var inp  = document.getElementById(inputId);
  var nameEl = document.getElementById(nameId);
  zone.addEventListener('dragover', function(e){ e.preventDefault(); zone.classList.add('over'); });
  zone.addEventListener('dragleave', function(){ zone.classList.remove('over'); });
  zone.addEventListener('drop', function(e){
    e.preventDefault(); zone.classList.remove('over');
    if (e.dataTransfer.files.length) {
      inp.files = e.dataTransfer.files;
      nameEl.textContent = e.dataTransfer.files[0].name;
    }
  });
  inp.addEventListener('change', function(){
    if (inp.files.length) nameEl.textContent = inp.files[0].name;
  });
}
"""


# ─── CSS de las páginas generadas ──────────────────────────────────────────

_CSS_PAGINA_GENERADA = """
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{
  --font-body:'DM Sans',system-ui,-apple-system,sans-serif;
  --font-mono:'JetBrains Mono',monospace;
  --bg-page:#f5f6f8;--bg-card:#ffffff;--bg-card-hover:#fafbfc;--bg-detail:#ffffff;
  --text-primary:#1a1d23;--text-secondary:#5a5f6d;--text-tertiary:#8b90a0;
  --border-light:#e8eaef;--border-medium:#d4d7de;
  --shadow-sm:0 1px 3px rgba(0,0,0,.04),0 1px 2px rgba(0,0,0,.06);
  --shadow-md:0 4px 16px rgba(0,0,0,.06),0 2px 6px rgba(0,0,0,.04);
  --shadow-lg:0 8px 32px rgba(0,0,0,.08),0 4px 12px rgba(0,0,0,.04);
  --shadow-tool:0 1px 4px rgba(0,0,0,.03);
  --shadow-tool-hover:0 4px 20px rgba(0,0,0,.08),0 2px 8px rgba(0,0,0,.04);
  --radius-sm:.5rem;--radius-md:.75rem;--radius-lg:1rem;--radius-xl:1.25rem;
}
html{font-size:16px;-webkit-font-smoothing:antialiased}
body{font-family:var(--font-body);background:var(--bg-page);color:var(--text-primary);line-height:1.6;min-height:100vh}
.wrap{width:100%;max-width:1280px;margin:0 auto;padding:1rem 1rem 3rem}
.page-header{margin-bottom:1.5rem;padding:0 .25rem}
.page-header h1{font-size:1.5rem;font-weight:700;letter-spacing:-.02em;color:var(--text-primary);line-height:1.2}
.page-header p{font-size:.9rem;color:var(--text-secondary);margin-top:.35rem;line-height:1.5}
.iris-banner{background:linear-gradient(135deg,#0c1a35 0%,#162d58 50%,#1a3a6e 100%);border-radius:var(--radius-lg);padding:1.5rem;margin-bottom:1.75rem;color:#fff;position:relative;overflow:hidden;box-shadow:0 4px 24px rgba(12,26,53,.35)}
.iris-banner::before{content:'';position:absolute;inset:0;background:radial-gradient(ellipse at 85% 20%,rgba(59,130,246,.2) 0%,transparent 50%),radial-gradient(ellipse at 10% 80%,rgba(99,102,241,.1) 0%,transparent 50%);pointer-events:none}
.iris-banner>*{position:relative;z-index:1}
.iris-label{font-family:var(--font-mono);font-size:.65rem;font-weight:600;letter-spacing:.12em;text-transform:uppercase;opacity:.5;margin-bottom:.5rem}
.iris-title{font-size:1.25rem;font-weight:700;margin-bottom:.6rem;letter-spacing:-.01em;line-height:1.3}
.iris-sub{font-size:.875rem;opacity:.7;line-height:1.6}
.grid{display:grid;grid-template-columns:1fr;gap:1.25rem}
.cat{border-radius:var(--radius-lg);overflow:hidden;border:1.5px solid var(--cat-border,#e8eaef);background:var(--bg-card);box-shadow:var(--shadow-sm);transition:box-shadow .2s ease}
.cat:hover{box-shadow:var(--shadow-md)}
.cat-head{padding:.85rem 1.1rem;display:flex;align-items:center;gap:.6rem;background:var(--cat-head-bg,rgba(0,0,0,.04));border-bottom:1.5px solid var(--cat-border,#e8eaef);cursor:pointer;user-select:none}
.cat-icon{font-size:1.05rem;line-height:1;flex-shrink:0}
.cat-name{font-family:var(--font-mono);font-size:.7rem;font-weight:700;color:var(--cat-color,#4036b0);letter-spacing:.06em;text-transform:uppercase}
.cat-toggle{margin-left:auto;font-size:.9rem;color:var(--cat-color,#4036b0);transition:transform .2s ease;opacity:.7}
.cat-head.collapsed .cat-toggle{transform:rotate(-90deg)}
.tools{padding:.65rem;display:flex;flex-direction:column;gap:.45rem;overflow:hidden;transition:max-height .3s ease,padding .3s ease}
.tools.collapsed{max-height:0!important;padding-top:0;padding-bottom:0}
.tool{background:var(--bg-card);border:1.5px solid var(--border-light);border-radius:var(--radius-md);padding:.85rem 1rem;padding-right:2.2rem;cursor:pointer;transition:all .2s ease;position:relative;box-shadow:var(--shadow-tool)}
.tool:hover{border-color:var(--cat-color);box-shadow:var(--shadow-tool-hover);transform:translateY(-1px);background:var(--bg-card-hover)}
.tool:active{transform:translateY(0);box-shadow:var(--shadow-sm)}
.tool.child{margin-left:.85rem;border-left:3px solid var(--cat-color);padding-left:.85rem}
.tool.child2{margin-left:1.7rem;border-left:3px solid var(--cat-color);padding-left:.85rem;opacity:.92}
.tool-name{font-size:.95rem;font-weight:700;color:var(--text-primary);margin-bottom:.3rem;display:flex;align-items:center;gap:.5rem;flex-wrap:wrap;line-height:1.4}
.tool-desc{font-size:.85rem;color:var(--text-secondary);line-height:1.55}
.badge{font-family:var(--font-mono);font-size:.6rem;font-weight:600;padding:.2em .6em;border-radius:.5rem;letter-spacing:.04em;white-space:nowrap;background:rgba(0,0,0,.06);color:var(--cat-color)}
.tool-arrow{position:absolute;right:.85rem;top:50%;transform:translateY(-50%);font-size:1rem;color:var(--text-tertiary);opacity:.3;transition:all .2s ease;font-weight:300}
.tool:hover .tool-arrow{opacity:.7;right:.65rem;color:var(--cat-color)}
.detail-panel{border-radius:var(--radius-xl);padding:0;margin-top:1.75rem;display:none;overflow:hidden;border:2px solid var(--detail-color,var(--border-medium));box-shadow:var(--shadow-lg);background:var(--bg-detail);animation:slideUp .3s ease}
@keyframes slideUp{from{opacity:0;transform:translateY(12px)}to{opacity:1;transform:translateY(0)}}
.detail-panel.show{display:block}
.detail-stripe{height:4px;background:var(--detail-color,var(--border-medium))}
.detail-inner{padding:1.5rem}
.detail-cat-label{font-family:var(--font-mono);font-size:.6rem;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:var(--detail-color);margin-bottom:.4rem;opacity:.8}
.detail-header{display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:1rem;gap:1rem}
.detail-title{font-size:1.15rem;font-weight:700;color:var(--text-primary);line-height:1.3;letter-spacing:-.01em}
.close-btn{flex-shrink:0;font-size:.75rem;font-weight:500;color:var(--text-secondary);cursor:pointer;border:1.5px solid var(--border-light);padding:.35em .85em;border-radius:2rem;transition:all .2s ease;white-space:nowrap;background:transparent;font-family:var(--font-body)}
.close-btn:hover{color:var(--detail-color);border-color:var(--detail-color);background:var(--detail-bg)}
.detail-text{font-size:.95rem;color:var(--text-secondary);line-height:1.7;margin-bottom:1rem}
.rel-note{font-size:.875rem;color:var(--text-secondary);padding:1rem 1.15rem;background:var(--detail-note-bg);border-radius:var(--radius-md);border:1.5px solid var(--detail-note-border);line-height:1.65}
.rel-note strong{color:var(--text-primary)}
.c-malware{--cat-border:rgba(192,74,32,.2);--cat-head-bg:rgba(192,74,32,.06);--cat-color:#b5431c}
.c-apt{--cat-border:rgba(154,96,16,.2);--cat-head-bg:rgba(154,96,16,.06);--cat-color:#8a5510}
.c-siem{--cat-border:rgba(18,84,160,.2);--cat-head-bg:rgba(18,84,160,.06);--cat-color:#1254a0}
.c-ens{--cat-border:rgba(10,107,82,.2);--cat-head-bg:rgba(10,107,82,.06);--cat-color:#0a6b52}
.c-incidentes{--cat-border:rgba(64,54,176,.2);--cat-head-bg:rgba(64,54,176,.06);--cat-color:#4036b0}
.c-borrado{--cat-border:rgba(74,72,69,.2);--cat-head-bg:rgba(74,72,69,.06);--cat-color:#4a4845}
.c-formacion{--cat-border:rgba(79,125,16,.2);--cat-head-bg:rgba(79,125,16,.06);--cat-color:#4f7d10}
.c-colab{--cat-border:rgba(18,135,106,.2);--cat-head-bg:rgba(18,135,106,.06);--cat-color:#12876a}
.c-app{--cat-border:rgba(124,58,237,.2);--cat-head-bg:rgba(124,58,237,.06);--cat-color:#7c3aed}
.c-pres{--cat-border:rgba(91,95,199,.2);--cat-head-bg:rgba(91,95,199,.06);--cat-color:#5b5fc7}
.c-ses{--cat-border:rgba(37,99,235,.2);--cat-head-bg:rgba(37,99,235,.06);--cat-color:#2563eb}
.c-trans{--cat-border:rgba(8,145,178,.2);--cat-head-bg:rgba(8,145,178,.06);--cat-color:#0891b2}
.c-red{--cat-border:rgba(5,150,105,.2);--cat-head-bg:rgba(5,150,105,.06);--cat-color:#059669}
.c-enlace{--cat-border:rgba(180,83,9,.2);--cat-head-bg:rgba(180,83,9,.06);--cat-color:#b45309}
.c-fisica{--cat-border:rgba(220,38,38,.2);--cat-head-bg:rgba(220,38,38,.06);--cat-color:#dc2626}
::-webkit-scrollbar{width:8px}
::-webkit-scrollbar-track{background:transparent}
::-webkit-scrollbar-thumb{background:#c8cad0;border-radius:4px}
@media(min-width:640px){.wrap{padding:1.5rem 1.5rem 3rem}.page-header h1{font-size:1.7rem}.grid{grid-template-columns:repeat(2,1fr)}}
@media(min-width:1024px){.wrap{padding:2rem 2.5rem 4rem}.page-header h1{font-size:1.85rem}.grid{grid-template-columns:repeat(3,1fr)}}
"""

# ─── JS del page builder (compartido servidor y cliente) ────────────────────

# Este JS se incrusta en la página de subida para la vista previa en vivo,
# y también se usa como referencia para generar el HTML servidor-side.

_JS_BUILDPAGE = r"""
function hexToRgb(hex){
  var r=parseInt(hex.slice(1,3),16),g=parseInt(hex.slice(3,5),16),b=parseInt(hex.slice(5,7),16);
  return r+','+g+','+b;
}

var CAT_COLORS={
  'c-malware':'#b5431c','c-apt':'#8a5510','c-siem':'#1254a0','c-ens':'#0a6b52',
  'c-incidentes':'#4036b0','c-borrado':'#4a4845','c-formacion':'#4f7d10','c-colab':'#12876a',
  'c-app':'#7c3aed','c-pres':'#5b5fc7','c-ses':'#2563eb','c-trans':'#0891b2',
  'c-red':'#059669','c-enlace':'#b45309','c-fisica':'#dc2626'
};

function buildPage(data){
  var config = data.config||{};
  var titulo = config.tituloPagina||'Página generada';
  var subtitulo = config.subtituloPagina||'';
  var banner = config.banner||{};
  var categorias = data.categorias||[];

  // Build data object for detail panel
  var jsData = {};
  categorias.forEach(function(cat){
    var color = CAT_COLORS[cat.colorClase]||'#4036b0';
    var rgb = hexToRgb(color);
    (cat.items||[]).forEach(function(item){
      if(item.descripcionLarga||item.notaRelacionada){
        jsData[item.id] = {
          title: item.nombre||'',
          text: item.descripcionLarga||'',
          rel: item.notaRelacionada||'',
          cat: (cat.icono||'')+' '+cat.nombre,
          color: color,
          bg: 'rgba('+rgb+',.04)',
          notebg: 'rgba('+rgb+',.04)',
          noteborder: 'rgba('+rgb+',.15)'
        };
      }
    });
  });

  // Banner HTML
  var bannerHtml = '';
  if(banner.mostrar!==false && (banner.titulo||banner.descripcion)){
    bannerHtml = '<div class="iris-banner">'
      +(banner.etiqueta?'<div class="iris-label">'+esc(banner.etiqueta)+'</div>':'')
      +(banner.titulo?'<div class="iris-title">'+esc(banner.titulo)+'</div>':'')
      +(banner.descripcion?'<div class="iris-sub">'+esc(banner.descripcion)+'</div>':'')
      +'</div>';
  }

  // Categories HTML
  var catsHtml = '';
  categorias.forEach(function(cat){
    var colorClase = cat.colorClase||'c-incidentes';
    var color = CAT_COLORS[colorClase]||'#4036b0';
    var rgb = hexToRgb(color);
    var togAttr = (cat.desplegable!==false)?' onclick="toggleCat(this)"':'';
    var headClass = (cat.desplegable!==false && cat.abierta===false)?' collapsed':'';
    var toolsClass = (cat.desplegable!==false && cat.abierta===false)?' collapsed':'';
    var toggleIcon = (cat.desplegable!==false)?'<span class="cat-toggle">›</span>':'';

    var itemsHtml = '';
    (cat.items||[]).forEach(function(item){
      var nivelClass = item.nivel===2?' child2':item.nivel===1?' child':'';
      var hasDetail = !!(item.descripcionLarga||item.notaRelacionada);
      var clickAttr = hasDetail?' onclick="showDetail(\''+item.id+'\')" tabindex="0" role="button"':'';
      var arrowHtml = hasDetail?'<span class="tool-arrow">›</span>':'';
      var badgesHtml = '';
      (item.badges||[]).forEach(function(b){
        badgesHtml += '<span class="badge" style="background:rgba('+rgb+',.1);color:'+color+'">'+esc(b)+'</span>';
      });
      itemsHtml += '<div class="tool'+nivelClass+'"'+clickAttr+'>'
        +'<div class="tool-name">'+esc(item.nombre||'')+(badgesHtml?' '+badgesHtml:'')+'</div>'
        +(item.resumen?'<div class="tool-desc">'+esc(item.resumen)+'</div>':'')
        +arrowHtml
        +'</div>';
    });

    catsHtml += '<div class="cat '+colorClase+'">'
      +'<div class="cat-head'+headClass+'"'+togAttr+'>'
      +'<span class="cat-icon">'+esc(cat.icono||'📋')+'</span>'
      +'<span class="cat-name">'+esc(cat.nombre||'')+'</span>'
      +toggleIcon
      +'</div>'
      +'<div class="tools'+toolsClass+'">'+itemsHtml+'</div>'
      +'</div>';
  });

  var jsDataStr = JSON.stringify(jsData);

  return '<!DOCTYPE html>\n<html lang="es">\n<head>\n'
    +'<meta charset="UTF-8">\n'
    +'<meta name="viewport" content="width=device-width,initial-scale=1">\n'
    +'<title>'+esc(titulo)+'</title>\n'
    +'<link rel="preconnect" href="https://fonts.googleapis.com">\n'
    +'<link href="https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;600;700&family=JetBrains+Mono:wght@400;600;700&display=swap" rel="stylesheet">\n'
    +'<style>'+CSS_PAGINA+'</style>\n'
    +'</head>\n<body>\n<div class="wrap">\n'
    +'<header class="page-header"><h1>'+esc(titulo)+'</h1>'
    +(subtitulo?'<p>'+esc(subtitulo)+'</p>':'')
    +'</header>\n'
    +bannerHtml
    +'<div class="grid">'+catsHtml+'</div>\n'
    +'<div class="detail-panel" id="detail-panel">'
    +'<div class="detail-stripe"></div>'
    +'<div class="detail-inner">'
    +'<div class="detail-cat-label" id="detail-cat-label"></div>'
    +'<div class="detail-header">'
    +'<div class="detail-title" id="detail-title"></div>'
    +'<button class="close-btn" onclick="closeDetail()">✕ cerrar</button>'
    +'</div>'
    +'<div class="detail-text" id="detail-text"></div>'
    +'<div class="rel-note" id="detail-rel"></div>'
    +'</div></div>\n'
    +'</div>\n'
    +'<script>\n'
    +'var data='+jsDataStr+';\n'
    +JS_PAGINA
    +'<\/script>\n'
    +'</body>\n</html>';
}

function esc(s){
  return String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

var JS_PAGINA = [
  'function showDetail(id){',
  '  var d=data[id];if(!d)return;',
  '  var p=document.getElementById("detail-panel");',
  '  document.getElementById("detail-cat-label").textContent=d.cat||"";',
  '  document.getElementById("detail-title").textContent=d.title;',
  '  document.getElementById("detail-text").textContent=d.text;',
  '  document.getElementById("detail-rel").innerHTML=d.rel;',
  '  p.style.setProperty("--detail-color",d.color);',
  '  p.style.setProperty("--detail-bg",d.bg);',
  '  p.style.setProperty("--detail-note-bg",d.notebg);',
  '  p.style.setProperty("--detail-note-border",d.noteborder);',
  '  p.classList.remove("show");void p.offsetWidth;p.classList.add("show");',
  '  setTimeout(function(){p.scrollIntoView({behavior:"smooth",block:"nearest"})},50);',
  '}',
  'function closeDetail(){document.getElementById("detail-panel").classList.remove("show");}',
  'function toggleCat(head){',
  '  head.classList.toggle("collapsed");',
  '  var tools=head.nextElementSibling;',
  '  if(tools){tools.classList.toggle("collapsed");}',
  '}',
  'document.addEventListener("keydown",function(e){if(e.key==="Escape")closeDetail();});',
  'document.querySelectorAll(".tool[tabindex]").forEach(function(el){',
  '  el.addEventListener("keydown",function(e){if(e.key==="Enter"||e.key===" "){e.preventDefault();this.click();}});',
  '});'
].join('\n');
"""


def generar_pagina_html(data: dict) -> str:
    """Genera el HTML completo de una página a partir del JSON de plantilla."""
    config = data.get("config", {})
    titulo = config.get("tituloPagina", "Página generada")
    subtitulo = config.get("subtituloPagina", "")
    banner = config.get("banner", {})
    categorias = data.get("categorias", [])

    CAT_COLORS = {
        "c-malware": "#b5431c", "c-apt": "#8a5510", "c-siem": "#1254a0",
        "c-ens": "#0a6b52", "c-incidentes": "#4036b0", "c-borrado": "#4a4845",
        "c-formacion": "#4f7d10", "c-colab": "#12876a", "c-app": "#7c3aed",
        "c-pres": "#5b5fc7", "c-ses": "#2563eb", "c-trans": "#0891b2",
        "c-red": "#059669", "c-enlace": "#b45309", "c-fisica": "#dc2626",
    }

    def hex_to_rgb(h):
        h = h.lstrip("#")
        return f"{int(h[0:2],16)},{int(h[2:4],16)},{int(h[4:6],16)}"

    # Build JS data object
    js_data = {}
    for cat in categorias:
        color = CAT_COLORS.get(cat.get("colorClase", ""), "#4036b0")
        rgb = hex_to_rgb(color)
        for item in cat.get("items", []):
            if item.get("descripcionLarga") or item.get("notaRelacionada"):
                js_data[item["id"]] = {
                    "title": item.get("nombre", ""),
                    "text": item.get("descripcionLarga", ""),
                    "rel": item.get("notaRelacionada", ""),
                    "cat": f"{cat.get('icono','')} {cat.get('nombre','')}",
                    "color": color,
                    "bg": f"rgba({rgb},.04)",
                    "notebg": f"rgba({rgb},.04)",
                    "noteborder": f"rgba({rgb},.15)",
                }

    # Banner
    banner_html = ""
    if banner.get("mostrar", True) and (banner.get("titulo") or banner.get("descripcion")):
        banner_html = '<div class="iris-banner">'
        if banner.get("etiqueta"):
            banner_html += f'<div class="iris-label">{html.escape(banner["etiqueta"])}</div>'
        if banner.get("titulo"):
            banner_html += f'<div class="iris-title">{html.escape(banner["titulo"])}</div>'
        if banner.get("descripcion"):
            banner_html += f'<div class="iris-sub">{html.escape(banner["descripcion"])}</div>'
        banner_html += "</div>\n"

    # Categories
    cats_html_parts = []
    for cat in categorias:
        color_clase = cat.get("colorClase", "c-incidentes")
        color = CAT_COLORS.get(color_clase, "#4036b0")
        rgb = hex_to_rgb(color)
        desplegable = cat.get("desplegable", True)
        abierta = cat.get("abierta", True)
        tog_attr = ' onclick="toggleCat(this)"' if desplegable else ""
        head_class = " collapsed" if desplegable and not abierta else ""
        tools_class = " collapsed" if desplegable and not abierta else ""
        toggle_icon = '<span class="cat-toggle">›</span>' if desplegable else ""

        items_html_parts = []
        for item in cat.get("items", []):
            nivel = item.get("nivel", 0)
            nivel_class = " child2" if nivel == 2 else " child" if nivel == 1 else ""
            has_detail = bool(item.get("descripcionLarga") or item.get("notaRelacionada"))
            click_attr = f' onclick="showDetail(\'{html.escape(item["id"])}\')" tabindex="0" role="button"' if has_detail else ""
            arrow_html = '<span class="tool-arrow">›</span>' if has_detail else ""
            badges_html = "".join(
                f'<span class="badge" style="background:rgba({rgb},.1);color:{color}">{html.escape(b)}</span>'
                for b in item.get("badges", [])
            )
            desc_html = (f'<div class="tool-desc">{html.escape(item.get("resumen",""))}</div>' if item.get("resumen") else "")
            items_html_parts.append(
                f'<div class="tool{nivel_class}"{click_attr}>'
                f'<div class="tool-name">{html.escape(item.get("nombre",""))}'
                f'{(" " + badges_html) if badges_html else ""}</div>'
                f'{desc_html}'
                f'{arrow_html}</div>'
            )

        cats_html_parts.append(
            f'<div class="cat {color_clase}">'
            f'<div class="cat-head{head_class}"{tog_attr}>'
            f'<span class="cat-icon">{html.escape(cat.get("icono","📋"))}</span>'
            f'<span class="cat-name">{html.escape(cat.get("nombre",""))}</span>'
            f'{toggle_icon}</div>'
            f'<div class="tools{tools_class}">{"".join(items_html_parts)}</div>'
            f'</div>'
        )

    js_data_str = json.dumps(js_data, ensure_ascii=False)

    js_pagina = """
function showDetail(id){
  var d=data[id];if(!d)return;
  var p=document.getElementById('detail-panel');
  document.getElementById('detail-cat-label').textContent=d.cat||'';
  document.getElementById('detail-title').textContent=d.title;
  document.getElementById('detail-text').textContent=d.text;
  document.getElementById('detail-rel').innerHTML=d.rel;
  p.style.setProperty('--detail-color',d.color);
  p.style.setProperty('--detail-bg',d.bg);
  p.style.setProperty('--detail-note-bg',d.notebg);
  p.style.setProperty('--detail-note-border',d.noteborder);
  p.classList.remove('show');void p.offsetWidth;p.classList.add('show');
  setTimeout(function(){p.scrollIntoView({behavior:'smooth',block:'nearest'})},50);
}
function closeDetail(){document.getElementById('detail-panel').classList.remove('show');}
function toggleCat(head){
  head.classList.toggle('collapsed');
  var tools=head.nextElementSibling;
  if(tools){tools.classList.toggle('collapsed');}
}
document.addEventListener('keydown',function(e){if(e.key==='Escape')closeDetail();});
document.querySelectorAll('.tool[tabindex]').forEach(function(el){
  el.addEventListener('keydown',function(e){if(e.key==='Enter'||e.key===' '){e.preventDefault();this.click();}});
});
"""

    return f"""<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(titulo)}</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;600;700&family=JetBrains+Mono:wght@400;600;700&display=swap" rel="stylesheet">
<style>
{_CSS_PAGINA_GENERADA}
</style>
</head>
<body>
<div class="wrap">
  <header class="page-header">
    <h1>{html.escape(titulo)}</h1>
    {f'<p>{html.escape(subtitulo)}</p>' if subtitulo else ''}
  </header>
  {banner_html}
  <div class="grid">
    {"".join(cats_html_parts)}
  </div>

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
var data={js_data_str};
{js_pagina}
</script>
</body>
</html>"""


def _emoji_picker_html(picker_id: str, default: str) -> str:
    preview_id = f"ep-prev-{picker_id}"
    input_id = f"ep-inp-{picker_id}"
    btns = "\n".join(
        f'<button type="button" class="ep-btn{" sel" if e == default else ""}" '
        f'data-e="{e}" onclick="selectEmoji(this,\'{preview_id}\',\'{input_id}\')">{e}</button>'
        for e in EMOJIS
    )
    return f"""
<div class="ep-wrap">
  <div class="ep-preview" id="{preview_id}">{default}</div>
  <div class="ep-grid">{btns}</div>
</div>
<input type="hidden" name="icono" id="{input_id}" value="{default}">
"""


def _carpeta_options_html(carpetas: list, selected: str = "/") -> str:
    opts = []
    for val, label in carpetas:
        sel = ' selected' if val == selected else ''
        opts.append(f'<option value="{html.escape(val)}"{sel}>{html.escape(label)}</option>')
    return "\n".join(opts)


# ─── Handler ────────────────────────────────────────────────────────────────

class FileBrowserHandler(BaseHTTPRequestHandler):
    base_dir: str = "/tmp"

    # ── routing ──────────────────────────────────────────────────────────────

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)

        if path == "/subirFichero":
            self.serve_upload_page(query)
        elif path == "/subirPlantilla":
            self.serve_plantilla_page(query)
        else:
            self.serve_path(path)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        if path == "/subirFichero":
            self.handle_upload()
        elif path == "/crearCarpeta":
            self.handle_create_folder()
        elif path == "/subirPlantilla":
            self.handle_plantilla()
        else:
            self.send_error(404)

    # ── path helpers ─────────────────────────────────────────────────────────

    def safe_path(self, url_path: str) -> str | None:
        url_path = urllib.parse.unquote(url_path).lstrip("/")
        parts = [p for p in url_path.replace("\\", "/").split("/")
                 if p and p != ".." and p != "."]
        fs = os.path.realpath(os.path.join(self.base_dir, *parts) if parts else self.base_dir)
        base = os.path.realpath(self.base_dir)
        return fs if fs.startswith(base) else None

    def serve_path(self, url_path: str):
        fs = self.safe_path(url_path)
        if fs is None:
            self.send_error(403)
            return
        if os.path.isdir(fs):
            self.serve_directory(fs, url_path.rstrip("/") or "/")
        elif os.path.isfile(fs):
            self.serve_file(fs)
        else:
            self.send_error(404)

    # ── directory listing ────────────────────────────────────────────────────

    def serve_directory(self, fs_path: str, url_path: str):
        try:
            entries = list(os.scandir(fs_path))
        except PermissionError:
            self.send_error(403)
            return

        meta = cargar_metadata(fs_path)
        dirs = sorted(
            [e for e in entries if e.is_dir() and not e.name.startswith(".")],
            key=lambda e: e.name.lower(),
        )
        files = sorted(
            [e for e in entries if e.is_file() and not e.name.startswith(".")],
            key=lambda e: e.name.lower(),
        )
        self._send_html(self._render_directory(fs_path, url_path, dirs, files, meta))

    def _render_directory(self, fs_path, url_path, dirs, files, meta) -> str:
        # Breadcrumb
        parts = [p for p in url_path.split("/") if p]
        bc = '<a href="/">🏠 Inicio</a>'
        for i, part in enumerate(parts):
            link = "/" + "/".join(parts[: i + 1])
            escaped = html.escape(part)
            if i == len(parts) - 1:
                bc += f' <span class="bc-sep">›</span> <strong>{escaped}</strong>'
            else:
                bc += f' <span class="bc-sep">›</span> <a href="{link}">{escaped}</a>'

        # Cards
        cards = []
        for d in dirs:
            icon = obtener_icono(meta, d.name, True)
            href = (url_path.rstrip("/") + "/" + urllib.parse.quote(d.name))
            if not href.startswith("/"):
                href = "/" + href
            try:
                n = len([e for e in os.scandir(d.path) if not e.name.startswith(".")])
                subtxt = f"{n} elemento{'s' if n != 1 else ''}"
            except Exception:
                subtxt = "carpeta"
            cards.append(
                f'<a href="{html.escape(href)}" class="card folder">'
                f'<div class="card-emoji">{icon}</div>'
                f'<div class="card-name" title="{html.escape(d.name)}">{html.escape(d.name)}</div>'
                f'<div class="card-meta">{subtxt}</div>'
                f'</a>'
            )
        for f in files:
            icon = obtener_icono(meta, f.name, False)
            href = (url_path.rstrip("/") + "/" + urllib.parse.quote(f.name))
            if not href.startswith("/"):
                href = "/" + href
            size_str = format_size(f.stat().st_size)
            cards.append(
                f'<a href="{html.escape(href)}" class="card file" target="_blank">'
                f'<div class="card-emoji">{icon}</div>'
                f'<div class="card-name" title="{html.escape(f.name)}">{html.escape(f.name)}</div>'
                f'<div class="card-meta">{size_str}</div>'
                f'</a>'
            )

        grid_content = (
            "\n".join(cards)
            if cards
            else '<div class="empty"><div class="empty-ico">📭</div><p>Esta carpeta está vacía</p></div>'
        )
        upload_link = f'/subirFichero?carpeta={urllib.parse.quote(url_path or "/")}'

        return f"""<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>📂 Ficheros</title>
<style>{_CSS_BASE}</style>
</head>
<body>
<div class="hdr">
  <div class="hdr-title">🗂️ Ficheros</div>
  <div class="hdr-actions">
    <a href="/subirPlantilla" class="btn btn-ghost">🧩 Nueva página desde JSON</a>
    <a href="{upload_link}" class="btn btn-white">📤 Subir / Nueva carpeta</a>
  </div>
</div>
<div class="bc">{bc}</div>
<div class="stats">
  <span>📁 {len(dirs)} carpeta{'s' if len(dirs) != 1 else ''}</span>
  <span>·</span>
  <span>📄 {len(files)} archivo{'s' if len(files) != 1 else ''}</span>
</div>
<div class="grid">{grid_content}</div>
</body>
</html>"""

    # ── file serving ─────────────────────────────────────────────────────────

    def serve_file(self, fs_path: str):
        mime, _ = mimetypes.guess_type(fs_path)
        mime = mime or "application/octet-stream"
        try:
            size = os.path.getsize(fs_path)
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(size))
            name = os.path.basename(fs_path)
            self.send_header("Content-Disposition", f'inline; filename="{name}"')
            self.end_headers()
            with open(fs_path, "rb") as fh:
                while chunk := fh.read(65536):
                    self.wfile.write(chunk)
        except Exception as e:
            self.send_error(500, str(e))

    # ── upload page ──────────────────────────────────────────────────────────

    def serve_upload_page(self, query: dict, *, msg: str = "", msg_type: str = "ok"):
        carpeta = query.get("carpeta", ["/"])[0]
        msg = msg or query.get("msg", [""])[0]
        msg_type = msg_type or query.get("tipo", ["ok"])[0]
        self._send_html(self._render_upload(carpeta, msg=msg, msg_type=msg_type))

    def _render_upload(self, carpeta_sel: str = "/", *, msg: str = "", msg_type: str = "ok") -> str:
        carpetas = obtener_todas_carpetas(self.base_dir)
        opts_file = _carpeta_options_html(carpetas, carpeta_sel)
        opts_folder = _carpeta_options_html(carpetas, carpeta_sel)
        ep_file = _emoji_picker_html("file", "📄")
        ep_folder = _emoji_picker_html("folder", "📁")

        alert_html = ""
        if msg:
            alert_html = f'<div class="alert alert-{msg_type}">{html.escape(msg)}</div>'

        back_url = html.escape(carpeta_sel) if carpeta_sel.startswith("/") else "/"

        return f"""<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>📤 Subir fichero</title>
<style>{_CSS_BASE}</style>
</head>
<body>
<div class="hdr">
  <div class="hdr-title">📤 Subir fichero</div>
  <div class="hdr-actions">
    <a href="{back_url}" class="btn btn-ghost">← Volver</a>
  </div>
</div>

<div class="form-wrap">
{alert_html}

<!-- ══ Subir archivo ══════════════════════════════════════════════════════ -->
<div class="form-card">
  <h2>📄 Subir un archivo</h2>
  <form method="POST" action="/subirFichero" enctype="multipart/form-data">

    <div class="fg">
      <label>📁 Carpeta destino</label>
      <select name="carpeta" class="fc">{opts_file}</select>
    </div>

    <div class="fg">
      <label>📎 Archivo</label>
      <div class="drop-zone" id="dz">
        <input type="file" name="archivo" id="file-inp" required>
        <div class="drop-ico">☁️</div>
        <div class="drop-hint">Arrastra aquí o haz clic para seleccionar</div>
        <div class="drop-name" id="file-name"></div>
      </div>
    </div>

    <div class="fg">
      <label>🎨 Icono del archivo</label>
      {ep_file}
    </div>

    <button type="submit" class="btn-submit">📤 Subir archivo</button>
  </form>
</div>

<!-- ══ Crear carpeta ══════════════════════════════════════════════════════ -->
<div class="form-card">
  <h2>📁 Crear una carpeta nueva</h2>
  <form method="POST" action="/crearCarpeta">

    <div class="fg">
      <label>🏷️ Nombre de la carpeta</label>
      <input type="text" name="nombre" class="fc" placeholder="mi-carpeta" required
             pattern="[^/\\\\<>:&quot;|?*]+" title="Sin barras ni caracteres especiales">
    </div>

    <div class="fg">
      <label>📁 Carpeta padre</label>
      <select name="carpeta_padre" class="fc">{opts_folder}</select>
    </div>

    <div class="fg">
      <label>🎨 Icono de la carpeta</label>
      {ep_folder}
    </div>

    <button type="submit" class="btn-submit">📁 Crear carpeta</button>
  </form>
</div>

</div><!-- /form-wrap -->

<script>
{_JS}
initDrop('dz','file-inp','file-name');
</script>
</body>
</html>"""

    # ── POST handlers ─────────────────────────────────────────────────────────

    def _parse_form(self) -> cgi.FieldStorage:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)
            return cgi.FieldStorage(
                fp=self.rfile,
                headers=self.headers,
                environ={
                    "REQUEST_METHOD": "POST",
                    "CONTENT_TYPE": self.headers.get("Content-Type"),
                    "CONTENT_LENGTH": self.headers.get("Content-Length", "0"),
                },
            )

    def handle_upload(self):
        try:
            form = self._parse_form()
            carpeta = form.getvalue("carpeta", "/")
            icono = form.getvalue("icono", "📄")

            file_item = form["archivo"] if "archivo" in form else None
            if file_item is None or not getattr(file_item, "filename", None):
                self._redirect_with_msg("/subirFichero", "No se recibió ningún archivo.", "err", carpeta)
                return

            dir_path = self.safe_path(carpeta)
            if dir_path is None or not os.path.isdir(dir_path):
                dir_path = self.base_dir

            filename = os.path.basename(file_item.filename or "archivo")
            filename = asegurar_nombre_unico(dir_path, filename)
            with open(os.path.join(dir_path, filename), "wb") as fh:
                fh.write(file_item.file.read())

            meta = cargar_metadata(dir_path)
            meta.setdefault("files", {})[filename] = icono
            guardar_metadata(dir_path, meta)

            redirect = carpeta if carpeta.startswith("/") else "/" + carpeta
            self._redirect(redirect)
        except Exception as exc:
            self.send_error(500, f"Error al subir el archivo: {exc}")

    def handle_create_folder(self):
        form = self._parse_form()
        nombre = form.getvalue("nombre", "").strip()
        icono = form.getvalue("icono", "📁")
        carpeta_padre = form.getvalue("carpeta_padre", "/")

        if not nombre or ".." in nombre or "/" in nombre or "\\" in nombre:
            self._redirect_with_msg("/subirFichero", "Nombre de carpeta inválido.", "err", carpeta_padre)
            return

        parent_path = self.safe_path(carpeta_padre)
        if parent_path is None or not os.path.isdir(parent_path):
            parent_path = self.base_dir

        new_folder = os.path.join(parent_path, nombre)
        if os.path.exists(new_folder):
            self._redirect_with_msg("/subirFichero", f'Ya existe una carpeta llamada "{nombre}".', "err", carpeta_padre)
            return

        os.makedirs(new_folder, exist_ok=True)
        meta = cargar_metadata(parent_path)
        meta.setdefault("files", {})[nombre] = icono
        guardar_metadata(parent_path, meta)

        redirect = carpeta_padre if carpeta_padre.startswith("/") else "/" + carpeta_padre
        self._redirect(redirect)

    # ── plantilla page ────────────────────────────────────────────────────────

    def serve_plantilla_page(self, query: dict, *, msg: str = "", msg_type: str = "ok"):
        msg = msg or query.get("msg", [""])[0]
        msg_type = msg_type or query.get("tipo", ["ok"])[0]
        carpeta = query.get("carpeta", ["/"])[0]
        self._send_html(self._render_plantilla_form(carpeta, msg=msg, msg_type=msg_type))

    def _render_plantilla_form(self, carpeta_sel: str = "/", *, msg: str = "", msg_type: str = "ok") -> str:
        carpetas = obtener_todas_carpetas(self.base_dir)
        opts = _carpeta_options_html(carpetas, carpeta_sel)
        alert_html = ""
        if msg:
            alert_html = f'<div class="alert alert-{msg_type}">{html.escape(msg)}</div>'
        css_pagina_js = json.dumps(_CSS_PAGINA_GENERADA)

        return f"""<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>🧩 Plantilla JSON → Página Web</title>
<style>
{_CSS_BASE}
{_CSS_PAGINA_GENERADA}
.preview-wrap{{margin-top:28px;border:2px solid var(--border);border-radius:14px;overflow:hidden;background:#f5f6f8}}
.preview-header{{background:linear-gradient(135deg,#6366F1,#8B5CF6);color:#fff;padding:10px 18px;font-size:13px;font-weight:700;display:flex;align-items:center;justify-content:space-between}}
.preview-body{{padding:0;min-height:300px;max-height:720px;overflow:auto}}
.preview-body iframe{{width:100%;border:none;min-height:600px;display:block}}
.preview-empty{{text-align:center;padding:60px 20px;color:var(--sub);font-size:14px}}
.json-error{{color:#dc2626;font-size:12px;margin-top:6px;min-height:18px}}
.tabs{{display:flex;gap:0;border-bottom:2px solid var(--border);margin-bottom:0}}
.tab{{padding:9px 20px;font-size:13px;font-weight:600;cursor:pointer;border-bottom:2px solid transparent;margin-bottom:-2px;color:var(--sub);transition:all .15s}}
.tab.active{{color:var(--pri);border-bottom-color:var(--pri)}}
.tab-panel{{display:none}}.tab-panel.active{{display:block}}
</style>
</head>
<body>
<div class="hdr">
  <div class="hdr-title">🧩 Plantilla JSON → Página Web</div>
  <div class="hdr-actions">
    <a href="/" class="btn btn-ghost">← Volver</a>
  </div>
</div>

<div style="display:grid;grid-template-columns:1fr 1fr;gap:24px;padding:24px;max-width:1600px;margin:0 auto">

<!-- ══ Panel izquierdo: formulario ══════════════════════════════════════════ -->
<div>
{alert_html}
<div class="form-card">
  <h2>📋 Configurar plantilla</h2>

  <div class="tabs">
    <div class="tab active" onclick="switchTab('texto')">✏️ Pegar JSON</div>
    <div class="tab" onclick="switchTab('archivo')">📂 Subir archivo</div>
  </div>

  <form method="POST" action="/subirPlantilla" enctype="multipart/form-data" id="plantilla-form">

    <div class="tab-panel active" id="tab-texto" style="padding-top:16px">
      <div class="fg">
        <label>📝 JSON de la plantilla</label>
        <textarea name="json_texto" id="json-input" class="fc" rows="18"
          style="font-family:monospace;font-size:12px;resize:vertical"
          placeholder='{{"config":{{"tituloPagina":"Mi Guía",...}},"categorias":[...]}}'
          oninput="onJsonChange(this.value)"></textarea>
        <div class="json-error" id="json-error"></div>
      </div>
    </div>

    <div class="tab-panel" id="tab-archivo" style="padding-top:16px">
      <div class="fg">
        <label>📎 Archivo JSON</label>
        <div class="drop-zone" id="dz-json">
          <input type="file" name="json_archivo" id="json-file-inp" accept=".json,application/json">
          <div class="drop-ico">📄</div>
          <div class="drop-hint">Arrastra tu .json o haz clic para seleccionar</div>
          <div class="drop-name" id="json-file-name"></div>
        </div>
      </div>
    </div>

    <div class="fg" style="margin-top:16px">
      <label>📁 Guardar en carpeta</label>
      <select name="carpeta" class="fc">{opts}</select>
    </div>

    <div class="fg">
      <label>🏷️ Nombre del archivo (sin .html)</label>
      <input type="text" name="nombre_archivo" id="nombre-archivo" class="fc"
             placeholder="mi-guia-tecnica" pattern="[\\w\\-]+" title="Solo letras, números, guiones y guiones bajos">
    </div>

    <button type="submit" class="btn-submit">🚀 Generar página HTML</button>
  </form>
</div>
</div>

<!-- ══ Panel derecho: vista previa ══════════════════════════════════════════ -->
<div>
  <div class="preview-wrap">
    <div class="preview-header">
      <span>👁️ Vista previa</span>
      <span id="preview-status" style="font-weight:400;opacity:.75;font-size:12px">Introduce JSON para previsualizar</span>
    </div>
    <div class="preview-body">
      <div class="preview-empty" id="preview-empty">
        <div style="font-size:48px;margin-bottom:12px">🧩</div>
        <div>La vista previa aparecerá aquí<br>mientras escribes el JSON</div>
      </div>
      <iframe id="preview-iframe" style="display:none"></iframe>
    </div>
  </div>
</div>

</div><!-- /grid -->

<script>
{_JS}
var CSS_PAGINA = {css_pagina_js};
initDrop('dz-json','json-file-inp','json-file-name');

// ── tab switch ──────────────────────────────────────────────────────────────
function switchTab(name){{
  document.querySelectorAll('.tab').forEach((t,i)=>t.classList.toggle('active', (i===0&&name==='texto')||(i===1&&name==='archivo')));
  document.getElementById('tab-texto').classList.toggle('active', name==='texto');
  document.getElementById('tab-archivo').classList.toggle('active', name==='archivo');
}}

// ── file reader for preview ──────────────────────────────────────────────────
document.getElementById('json-file-inp').addEventListener('change', function(){{
  const f = this.files[0];
  if(!f) return;
  const r = new FileReader();
  r.onload = e => onJsonChange(e.target.result);
  r.readAsText(f);
}});

// ── live preview ─────────────────────────────────────────────────────────────
let _debounce;
function onJsonChange(txt){{
  clearTimeout(_debounce);
  _debounce = setTimeout(()=>renderPreview(txt), 400);
}}

function renderPreview(txt){{
  const errEl = document.getElementById('json-error');
  const statusEl = document.getElementById('preview-status');
  if(!txt.trim()){{
    errEl.textContent='';
    showEmpty();
    statusEl.textContent='Introduce JSON para previsualizar';
    return;
  }}
  let data;
  try{{ data = JSON.parse(txt); }}
  catch(e){{ errEl.textContent='⚠ JSON inválido: '+e.message; showEmpty(); statusEl.textContent='JSON inválido'; return; }}
  errEl.textContent='';
  try{{
    const generatedHtml = buildPage(data);
    const iframe = document.getElementById('preview-iframe');
    const empty = document.getElementById('preview-empty');
    iframe.style.display='block';
    empty.style.display='none';
    iframe.srcdoc = generatedHtml;
    statusEl.textContent='✅ Vista previa actualizada';
  }} catch(e){{
    errEl.textContent='⚠ Error al generar vista previa: '+e.message;
    statusEl.textContent='Error en datos';
  }}
}}

function showEmpty(){{
  document.getElementById('preview-iframe').style.display='none';
  document.getElementById('preview-empty').style.display='';
}}

// ── page builder (client-side mirror of server generator) ────────────────────
{_JS_BUILDPAGE}
</script>
</body>
</html>"""

    def handle_plantilla(self):
        try:
            form = self._parse_form()
            carpeta = form.getvalue("carpeta", "/")
            nombre_archivo = (form.getvalue("nombre_archivo", "") or "").strip()

            # Get JSON from textarea or file upload
            json_txt = form.getvalue("json_texto", "") or ""
            if not json_txt and "json_archivo" in form:
                file_item = form["json_archivo"]
                if getattr(file_item, "filename", None):
                    json_txt = file_item.file.read().decode("utf-8", errors="replace")

            if not json_txt.strip():
                self._redirect_with_msg("/subirPlantilla", "No se recibió ningún JSON.", "err", carpeta)
                return

            try:
                data = json.loads(json_txt)
            except json.JSONDecodeError as e:
                self._redirect_with_msg("/subirPlantilla", f"JSON inválido: {e}", "err", carpeta)
                return

            html_content = generar_pagina_html(data)

            dir_path = self.safe_path(carpeta)
            if dir_path is None or not os.path.isdir(dir_path):
                dir_path = self.base_dir

            if not nombre_archivo:
                config = data.get("config", {})
                titulo = config.get("tituloPagina", "pagina")
                nombre_archivo = "".join(c if c.isalnum() or c in "-_ " else "" for c in titulo).strip().replace(" ", "-").lower()[:60] or "pagina"

            filename = asegurar_nombre_unico(dir_path, nombre_archivo + ".html")
            filepath = os.path.join(dir_path, filename)
            with open(filepath, "w", encoding="utf-8") as fh:
                fh.write(html_content)

            meta = cargar_metadata(dir_path)
            meta.setdefault("files", {})[filename] = "🌐"
            guardar_metadata(dir_path, meta)

            redirect = carpeta if carpeta.startswith("/") else "/" + carpeta
            self._redirect(redirect)
        except Exception as exc:
            self.send_error(500, f"Error al generar la página: {exc}")

    # ── response helpers ──────────────────────────────────────────────────────

    def _send_html(self, content: str):
        data = content.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _redirect(self, location: str):
        self.send_response(303)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _redirect_with_msg(self, base: str, msg: str, tipo: str, carpeta: str = "/"):
        loc = f"{base}?carpeta={urllib.parse.quote(carpeta)}&msg={urllib.parse.quote(msg)}&tipo={tipo}"
        self._redirect(loc)

    def log_message(self, *_):
        pass  # silenciar logs HTTP por defecto


# ─── Factory & startup ───────────────────────────────────────────────────────

def crear_handler(base_dir: str):
    """Devuelve una clase handler con base_dir fijado."""

    class _Handler(FileBrowserHandler):
        pass

    _Handler.base_dir = os.path.realpath(base_dir)
    return _Handler


def iniciar_servidor(base_dir: str, puerto: int) -> ThreadingHTTPServer:
    os.makedirs(base_dir, exist_ok=True)
    handler = crear_handler(base_dir)
    servidor = ThreadingHTTPServer(("", puerto), handler)
    print(
        f"📂 Servidor de ficheros iniciado en http://0.0.0.0:{puerto} "
        f"(directorio: {base_dir})"
    )
    return servidor


if __name__ == "__main__":
    servidor = iniciar_servidor(RUTA_ARCHIVOS_PUBLICOS, PUERTO_ARCHIVOS_PUBLICOS)

    # Apagado limpio con Ctrl+C o SIGTERM (docker stop)
    def _shutdown(sig, frame):
        print("\n🛑 Apagando servidor...")
        servidor.shutdown()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    # serve_forever() bloquea el hilo principal → el proceso NO muere
    servidor.serve_forever()