import cgi
import html
import io
import json
import mimetypes
import os
import shutil
import signal
import threading
import urllib.parse
import warnings
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import markdown
import pymdownx.emoji
from pygments.formatters import HtmlFormatter

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
    # Requisito funcional: mostrar siempre carpetas con icono de carpeta
    # y ficheros con icono de fichero, sin depender del metadata.
    return "📁" if es_dir else "📄"


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


# ─── JSON source (sidecar) helpers ──────────────────────────────────────────

def ruta_json_fuente(html_path: str) -> str:
    """Devuelve la ruta del fichero JSON fuente asociado a un HTML generado."""
    base, _ = os.path.splitext(html_path)
    return base + ".source.json"




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
.hdr-search{flex:1;max-width:400px;min-width:150px}
.hdr-search input{width:100%;padding:8px 14px;border:none;border-radius:8px;
  font-size:14px;background:rgba(255,255,255,.2);color:#fff;
  outline:none;transition:background .15s}
.hdr-search input::placeholder{color:rgba(255,255,255,.6)}
.hdr-search input:focus{background:rgba(255,255,255,.3)}
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
.card-actions{display:flex;gap:4px;margin-top:4px;opacity:0;transition:opacity .15s}
.card:hover .card-actions{opacity:1}
.card-btn{background:none;border:1px solid var(--border);border-radius:6px;
  padding:3px 8px;font-size:13px;cursor:pointer;transition:background .12s,border-color .12s;line-height:1}
.card-btn:hover{background:var(--pri-light);border-color:var(--pri)}
.card-btn.del:hover{background:#FEE2E2;border-color:#FCA5A5}
.selector-item{position:absolute;top:8px;left:8px;z-index:2}
.selector-item input{width:18px;height:18px;cursor:pointer}
.card{position:relative}
.card.seleccionada{outline:2px solid var(--pri);border-color:var(--pri)}
.barra-seleccion{padding:10px 24px;background:#fff;border-bottom:1px solid var(--border);
  display:none;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap}
.barra-seleccion.visible{display:flex}
.seleccion-texto{font-size:13px;color:var(--text);font-weight:600}
.seleccion-acciones{display:flex;gap:8px;flex-wrap:wrap}

/* ── confirm modal ── */
.modal-overlay{position:fixed;inset:0;background:rgba(0,0,0,.45);display:flex;
  align-items:center;justify-content:center;z-index:9999}
.modal-box{background:#fff;border-radius:16px;padding:28px 32px;max-width:420px;
  width:90%;box-shadow:0 12px 40px rgba(0,0,0,.2);text-align:center}
.modal-box h3{font-size:17px;margin-bottom:8px}
.modal-box p{font-size:14px;color:var(--sub);margin-bottom:20px;word-break:break-word}
.modal-btns{display:flex;gap:10px;justify-content:center}
.modal-btns .btn{padding:9px 22px;font-size:14px}
.btn-danger{background:#EF4444;color:#fff}
.btn-danger:hover{background:#DC2626;opacity:1}
.btn-cancel{background:var(--bg);color:var(--text);border:1px solid var(--border)}

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


# ─── CSS para renderizar Markdown ──────────────────────────────────────────

_CSS_MARKDOWN = """
*{box-sizing:border-box;margin:0;padding:0}
:root{
  --pri:#6366F1;--pri-d:#4F46E5;--pri-light:#EEF2FF;
  --bg:#F1F5F9;--card:#fff;--text:#1E293B;--sub:#64748B;
  --border:#E2E8F0;
}
body{font-family:system-ui,-apple-system,sans-serif;background:var(--bg);color:var(--text);min-height:100vh}
a{color:var(--pri);text-decoration:none}a:hover{text-decoration:underline}
.md-header{background:linear-gradient(135deg,#6366F1,#8B5CF6);color:#fff;
  padding:14px 24px;display:flex;align-items:center;justify-content:space-between;
  box-shadow:0 2px 8px rgba(0,0,0,.2);gap:12px;flex-wrap:wrap}
.md-header-title{display:flex;align-items:center;gap:10px;font-size:20px;font-weight:700}
.md-header a{color:#fff;font-size:14px;opacity:.85}
.md-header a:hover{opacity:1}
.md-wrap{max-width:900px;margin:32px auto;background:var(--card);
  border-radius:12px;box-shadow:0 1px 4px rgba(0,0,0,.08);padding:40px 48px;
  border:1px solid var(--border)}
@media(max-width:640px){.md-wrap{margin:16px;padding:24px 20px;border-radius:8px}}

/* ── tipografía markdown ── */
.md-body{line-height:1.7;font-size:16px;color:var(--text)}
.md-body h1{font-size:2em;font-weight:700;margin:1.2em 0 .6em;padding-bottom:.3em;border-bottom:2px solid var(--border)}
.md-body h2{font-size:1.5em;font-weight:700;margin:1.1em 0 .5em;padding-bottom:.25em;border-bottom:1px solid var(--border)}
.md-body h3{font-size:1.25em;font-weight:600;margin:1em 0 .4em}
.md-body h4{font-size:1.1em;font-weight:600;margin:.9em 0 .3em}
.md-body h5,.md-body h6{font-size:1em;font-weight:600;margin:.8em 0 .3em;color:var(--sub)}
.md-body p{margin:.8em 0}
.md-body ul,.md-body ol{margin:.8em 0;padding-left:2em}
.md-body li{margin:.3em 0}
.md-body li>ul,.md-body li>ol{margin:.2em 0}
.md-body blockquote{margin:.8em 0;padding:.6em 1em;border-left:4px solid var(--pri);
  background:var(--pri-light);border-radius:0 8px 8px 0;color:var(--sub)}
.md-body blockquote p{margin:.3em 0}
.md-body code{font-family:'JetBrains Mono',ui-monospace,monospace;font-size:.9em;
  background:#F1F5F9;padding:2px 6px;border-radius:4px;color:#E11D48}
.md-body pre{margin:.8em 0;padding:16px 20px;background:#272822;color:#F8F8F2;
  border-radius:8px;overflow-x:auto;font-size:.875em;line-height:1.6}
.md-body pre code{background:none;padding:0;color:inherit;font-size:inherit}
.md-body table{width:100%;border-collapse:collapse;margin:.8em 0;font-size:.95em}
.md-body th{background:var(--pri-light);font-weight:600;text-align:left;
  padding:10px 14px;border:1px solid var(--border)}
.md-body td{padding:10px 14px;border:1px solid var(--border)}
.md-body tr:nth-child(even){background:#FAFBFC}
.md-body img{max-width:100%;border-radius:8px;margin:.8em 0}
.md-body hr{border:none;border-top:2px solid var(--border);margin:1.5em 0}
.md-body del{color:var(--sub);text-decoration:line-through}
.md-body mark{background:#FEF08A;padding:2px 4px;border-radius:3px}

/* ── task lists (pymdownx.tasklist) ── */
.md-body .task-list-item{list-style:none;margin-left:-1.5em}
.md-body .task-list-control{margin-right:.4em}
.md-body .task-list-control input[type=checkbox]{width:1.1em;height:1.1em;accent-color:var(--pri);vertical-align:middle}

/* ── syntax highlighting – Pygments monokai ── */
.md-body .highlight{margin:.8em 0;padding:16px 20px;background:#272822;color:#F8F8F2;
  border-radius:8px;overflow-x:auto;font-size:.875em;line-height:1.6;
  font-family:'JetBrains Mono',ui-monospace,monospace}
.md-body .highlight pre{margin:0;padding:0;background:none}
.md-body .highlight code{background:none;padding:0;color:inherit}
.highlight .hll{background-color:#49483e}
.highlight .c,.highlight .ch,.highlight .cm,.highlight .cp,.highlight .cpf,.highlight .c1,.highlight .cs{color:#959077}
.highlight .gd{color:#FF4689}.highlight .gi{color:#A6E22E}
.highlight .ge{font-style:italic}.highlight .gs{font-weight:bold}
.highlight .go{color:#66D9EF}.highlight .gp{color:#FF4689;font-weight:bold}
.highlight .gu{color:#959077}
.highlight .k,.highlight .kc,.highlight .kd,.highlight .kp,.highlight .kr,.highlight .kt{color:#66D9EF}
.highlight .kn{color:#FF4689}
.highlight .l,.highlight .m,.highlight .mb,.highlight .mf,.highlight .mh,.highlight .mi,.highlight .mo,.highlight .il{color:#AE81FF}
.highlight .s,.highlight .sa,.highlight .sb,.highlight .sc,.highlight .dl,.highlight .sd,.highlight .s2,.highlight .sh,.highlight .si,.highlight .sx,.highlight .sr,.highlight .s1,.highlight .ss,.highlight .ld{color:#E6DB74}
.highlight .se{color:#AE81FF}
.highlight .na,.highlight .nc,.highlight .nd,.highlight .ne,.highlight .nf,.highlight .nx,.highlight .fm{color:#A6E22E}
.highlight .o,.highlight .ow{color:#FF4689}
.highlight .nt{color:#FF4689}
.highlight .err{color:#ED007E;background-color:#1E0010}
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
        elif path == "/editarMarkdown":
            self.serve_markdown_editor(query)
        elif path == "/api/markdown/cargar":
            self.api_cargar_markdown(query)
        elif path == "/descargarCarpeta":
            self.descargar_carpeta_como_zip(query)
        else:
            self.serve_path(path)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        if path == "/subirFichero":
            self.handle_upload()
        elif path == "/crearCarpeta":
            self.handle_create_folder()
        elif path == "/editarMarkdown":
            self.handle_markdown_save()
        elif path == "/eliminar":
            self.handle_delete()
        elif path == "/mover":
            self.handle_move()
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
            [e for e in entries if e.is_file() and not e.name.startswith(".")
             and not e.name.endswith(".source.json")],
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
            del_path = html.escape(href, quote=True)
            cards.append(
                f'<a href="{html.escape(href)}" class="card folder item-arrastrable destino-carpeta" draggable="true" data-ruta="{del_path}" data-es-carpeta="1">'
                f'<div class="selector-item"><input type="checkbox" class="selector-multiple" data-ruta="{del_path}" data-es-carpeta="1" title="Seleccionar {html.escape(d.name, quote=True)}"></div>'
                f'<div class="card-emoji">{icon}</div>'
                f'<div class="card-name" title="{html.escape(d.name)}">{html.escape(d.name)}</div>'
                f'<div class="card-meta">{subtxt}</div>'
                f'<div class="card-actions">'
                f'<button class="card-btn" onclick="event.preventDefault();event.stopPropagation();descargarCarpeta(\'{del_path}\')" title="Descargar carpeta en ZIP">⬇️</button>'
                f'<button class="card-btn" onclick="event.preventDefault();event.stopPropagation();renombrarElemento(\'{del_path}\', true)" title="Renombrar carpeta">✏️</button>'
                f'<button class="card-btn del" onclick="event.preventDefault();event.stopPropagation();confirmDelete(\'{del_path}\',\'{html.escape(d.name, quote=True)}\',true)" title="Eliminar carpeta">🗑️</button>'
                f'</div>'
                f'</a>'
            )
        for f in files:
            icon = obtener_icono(meta, f.name, False)
            href = (url_path.rstrip("/") + "/" + urllib.parse.quote(f.name))
            if not href.startswith("/"):
                href = "/" + href
            size_str = format_size(f.stat().st_size)
            edit_btn = ""
            if f.name.lower().endswith(".md"):
                edit_href = f'/editarMarkdown?editar={urllib.parse.quote(href)}'
                edit_btn = (
                    f'<button class="card-btn" onclick="event.preventDefault();event.stopPropagation();'
                    f'window.location.href=\'{html.escape(edit_href, quote=True)}\'" title="Editar markdown">📝</button>'
                )
            del_path = html.escape(href, quote=True)
            cards.append(
                f'<a href="{html.escape(href)}" class="card file item-arrastrable" target="_blank" draggable="true" data-ruta="{del_path}" data-es-carpeta="0">'
                f'<div class="selector-item"><input type="checkbox" class="selector-multiple" data-ruta="{del_path}" data-es-carpeta="0" title="Seleccionar {html.escape(f.name, quote=True)}"></div>'
                f'<div class="card-emoji">{icon}</div>'
                f'<div class="card-name" title="{html.escape(f.name)}">{html.escape(f.name)}</div>'
                f'<div class="card-meta">{size_str}</div>'
                f'<div class="card-actions">'
                f'{edit_btn}'
                f'<button class="card-btn" onclick="event.preventDefault();event.stopPropagation();renombrarElemento(\'{del_path}\', false)" title="Renombrar archivo">✏️</button>'
                f'<button class="card-btn del" onclick="event.preventDefault();event.stopPropagation();confirmDelete(\'{del_path}\',\'{html.escape(f.name, quote=True)}\',false)" title="Eliminar archivo">🗑️</button>'
                f'</div>'
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
  <div class="hdr-search">
    <input type="text" id="buscador" placeholder="🔍 Buscar ficheros..." oninput="filtrarFicheros(this.value)">
  </div>
  <div class="hdr-actions">
    <a href="/editarMarkdown" class="btn btn-ghost">📝 Crear Markdown</a>
    <a href="{upload_link}" class="btn btn-white">📤 Subir / Nueva carpeta</a>
  </div>
</div>
<div class="bc">{bc}</div>
<div class="stats">
  <span>📁 {len(dirs)} carpeta{'s' if len(dirs) != 1 else ''}</span>
  <span>·</span>
  <span>📄 {len(files)} archivo{'s' if len(files) != 1 else ''}</span>
</div>
<div class="barra-seleccion" id="barra-seleccion">
  <div class="seleccion-texto" id="seleccion-texto">0 elementos seleccionados</div>
  <div class="seleccion-acciones">
    <button class="btn btn-sec" type="button" onclick="moverSeleccionados()">📦 Mover seleccionados</button>
    <button class="btn btn-danger" type="button" onclick="eliminarSeleccionados()">🗑️ Eliminar seleccionados</button>
  </div>
</div>
<div class="grid">{grid_content}</div>
<script>
var rutaActual = {json.dumps(url_path or "/")};

function filtrarFicheros(texto) {{
  var termino = texto.toLowerCase().trim();
  var cards = document.querySelectorAll('.grid .card');
  var visibles = 0;
  cards.forEach(function(card) {{
    var nombre = card.querySelector('.card-name');
    if (!nombre) return;
    var coincide = !termino || nombre.textContent.toLowerCase().indexOf(termino) !== -1;
    card.style.display = coincide ? '' : 'none';
    if (coincide) visibles++;
  }});
  var empty = document.querySelector('.grid .empty');
  if (empty) empty.style.display = termino ? 'none' : '';
}}

function descargarCarpeta(ruta) {{
  window.location.href = '/descargarCarpeta?ruta=' + encodeURIComponent(ruta);
}}

function postMover(origen, destino, nuevoNombre) {{
  var form = document.createElement('form');
  form.method = 'POST';
  form.action = '/mover';

  var inpOrigen = document.createElement('input');
  inpOrigen.type = 'hidden';
  inpOrigen.name = 'origen';
  inpOrigen.value = origen;
  form.appendChild(inpOrigen);

  var inpDestino = document.createElement('input');
  inpDestino.type = 'hidden';
  inpDestino.name = 'destino';
  inpDestino.value = destino;
  form.appendChild(inpDestino);

  if (nuevoNombre) {{
    var inpNombre = document.createElement('input');
    inpNombre.type = 'hidden';
    inpNombre.name = 'nuevo_nombre';
    inpNombre.value = nuevoNombre;
    form.appendChild(inpNombre);
  }}
  document.body.appendChild(form);
  form.submit();
}}

function renombrarElemento(ruta, esDir) {{
  var nombreActual = decodeURIComponent((ruta || '').split('/').pop() || '');
  var tipo = esDir ? 'carpeta' : 'archivo';
  var nuevoNombre = prompt('Nuevo nombre de ' + tipo + ':', nombreActual);
  if (nuevoNombre === null) return;
  nuevoNombre = (nuevoNombre || '').trim();
  if (!nuevoNombre || nuevoNombre === nombreActual) return;
  postMover(ruta, rutaActual, nuevoNombre);
}}

function obtenerRutasSeleccionadas() {{
  var checks = document.querySelectorAll('.selector-multiple:checked');
  return Array.from(checks).map(function(chk) {{ return chk.dataset.ruta || ''; }}).filter(Boolean);
}}

function actualizarBarraSeleccion() {{
  var checks = document.querySelectorAll('.selector-multiple');
  var total = 0;
  checks.forEach(function(chk) {{
    var card = chk.closest('.card');
    if (chk.checked) {{
      total += 1;
      if (card) card.classList.add('seleccionada');
    }} else if (card) {{
      card.classList.remove('seleccionada');
    }}
  }});
  var barra = document.getElementById('barra-seleccion');
  var texto = document.getElementById('seleccion-texto');
  if (!barra || !texto) return;
  texto.textContent = total + ' elemento' + (total === 1 ? '' : 's') + ' seleccionado' + (total === 1 ? '' : 's');
  barra.classList.toggle('visible', total > 0);
}}

function moverSeleccionados() {{
  var rutas = obtenerRutasSeleccionadas();
  if (!rutas.length) return;
  var destino = prompt('Ruta destino (ejemplo: /documentos/subcarpeta):', rutaActual);
  if (destino === null) return;
  destino = (destino || '').trim();
  if (!destino) return;

  var form = document.createElement('form');
  form.method = 'POST';
  form.action = '/mover';

  rutas.forEach(function(ruta) {{
    var inp = document.createElement('input');
    inp.type = 'hidden';
    inp.name = 'origen';
    inp.value = ruta;
    form.appendChild(inp);
  }});

  var inpDestino = document.createElement('input');
  inpDestino.type = 'hidden';
  inpDestino.name = 'destino';
  inpDestino.value = destino;
  form.appendChild(inpDestino);

  document.body.appendChild(form);
  form.submit();
}}

function eliminarSeleccionados() {{
  var rutas = obtenerRutasSeleccionadas();
  if (!rutas.length) return;
  var confirmar = confirm('¿Eliminar ' + rutas.length + ' elemento' + (rutas.length === 1 ? '' : 's') + ' seleccionado' + (rutas.length === 1 ? '' : 's') + '?');
  if (!confirmar) return;

  var form = document.createElement('form');
  form.method = 'POST';
  form.action = '/eliminar';
  rutas.forEach(function(ruta) {{
    var inp = document.createElement('input');
    inp.type = 'hidden';
    inp.name = 'ruta';
    inp.value = ruta;
    form.appendChild(inp);
  }});
  document.body.appendChild(form);
  form.submit();
}}

function initSeleccionMultiple() {{
  var checks = document.querySelectorAll('.selector-multiple');
  checks.forEach(function(chk) {{
    chk.addEventListener('click', function(e) {{
      e.stopPropagation();
    }});
    chk.addEventListener('change', function() {{
      actualizarBarraSeleccion();
    }});
  }});
}}

function initArrastreMover() {{
  var elementos = document.querySelectorAll('.item-arrastrable');
  var destinos = document.querySelectorAll('.destino-carpeta');
  var rutaArrastrada = '';

  elementos.forEach(function(el) {{
    el.addEventListener('dragstart', function(e) {{
      rutaArrastrada = el.dataset.ruta || '';
      e.dataTransfer.effectAllowed = 'move';
      e.dataTransfer.setData('text/plain', rutaArrastrada);
    }});
  }});

  destinos.forEach(function(destino) {{
    destino.addEventListener('dragover', function(e) {{
      e.preventDefault();
      destino.style.borderColor = 'var(--pri)';
      e.dataTransfer.dropEffect = 'move';
    }});
    destino.addEventListener('dragleave', function() {{
      destino.style.borderColor = '';
    }});
    destino.addEventListener('drop', function(e) {{
      e.preventDefault();
      destino.style.borderColor = '';
      var origen = e.dataTransfer.getData('text/plain') || rutaArrastrada;
      var destinoCarpeta = destino.dataset.ruta || '';
      if (!origen || !destinoCarpeta || origen === destinoCarpeta) return;
      postMover(origen, destinoCarpeta, '');
    }});
  }});
}}

function confirmDelete(ruta, nombre, esDir) {{
  var tipo = esDir ? 'la carpeta' : 'el archivo';
  var extra = esDir ? '\\n\\nSe eliminará todo su contenido.' : '';
  var overlay = document.createElement('div');
  overlay.className = 'modal-overlay';
  overlay.innerHTML =
    '<div class="modal-box">' +
    '<h3>Eliminar ' + tipo + '</h3>' +
    '<p>¿Seguro que quieres eliminar <strong>' + nombre + '</strong>?' + extra + '</p>' +
    '<div class="modal-btns">' +
    '<button class="btn btn-cancel" onclick="this.closest(\\'.modal-overlay\\').remove()">Cancelar</button>' +
    '<button class="btn btn-danger" id="confirm-del-btn">Eliminar</button>' +
    '</div></div>';
  document.body.appendChild(overlay);
  overlay.addEventListener('click', function(e) {{ if (e.target === overlay) overlay.remove(); }});
  document.getElementById('confirm-del-btn').onclick = function() {{
    var form = document.createElement('form');
    form.method = 'POST';
    form.action = '/eliminar';
    var inp = document.createElement('input');
    inp.type = 'hidden'; inp.name = 'ruta'; inp.value = ruta;
    form.appendChild(inp);
    document.body.appendChild(form);
    form.submit();
  }};
}}
initSeleccionMultiple();
actualizarBarraSeleccion();
initArrastreMover();
</script>
</body>
</html>"""

    def descargar_carpeta_como_zip(self, query: dict):
        ruta = query.get("ruta", [""])[0]
        if not ruta:
            self.send_error(400, "Ruta de carpeta requerida.")
            return

        ruta_carpeta = self.safe_path(ruta)
        if ruta_carpeta is None or not os.path.isdir(ruta_carpeta):
            self.send_error(404, "Carpeta no encontrada.")
            return

        nombre_carpeta = os.path.basename(ruta_carpeta.rstrip(os.sep)) or "carpeta"
        nombre_zip = f"{nombre_carpeta}.zip"
        buffer_zip = io.BytesIO()

        with zipfile.ZipFile(buffer_zip, "w", zipfile.ZIP_DEFLATED) as zf:
            for raiz, _, archivos in os.walk(ruta_carpeta):
                for archivo in archivos:
                    ruta_archivo = os.path.join(raiz, archivo)
                    ruta_relativa = os.path.relpath(ruta_archivo, ruta_carpeta)
                    zf.write(ruta_archivo, arcname=ruta_relativa)

        contenido = buffer_zip.getvalue()
        self.send_response(200)
        self.send_header("Content-Type", "application/zip")
        self.send_header("Content-Length", str(len(contenido)))
        self.send_header(
            "Content-Disposition",
            f'attachment; filename="{nombre_zip}"',
        )
        self.end_headers()
        self.wfile.write(contenido)

    # ── file serving ─────────────────────────────────────────────────────────

    def serve_file(self, fs_path: str):
        if fs_path.lower().endswith(".md"):
            return self.serve_markdown(fs_path)
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

    def serve_markdown(self, fs_path: str):
        try:
            with open(fs_path, "r", encoding="utf-8") as f:
                md_text = f.read()
        except Exception as e:
            self.send_error(500, str(e))
            return

        md_html = markdown.markdown(
            md_text,
            extensions=[
                "fenced_code",
                "codehilite",
                "tables",
                "toc",
                "nl2br",
                "sane_lists",
                "pymdownx.tasklist",
                "pymdownx.tilde",
                "pymdownx.mark",
                "pymdownx.emoji",
                "pymdownx.superfences",
                "pymdownx.betterem",
            ],
            extension_configs={
                "codehilite": {"css_class": "highlight", "guess_lang": True},
                "pymdownx.emoji": {
                    "emoji_index": pymdownx.emoji.gemoji,
                    "emoji_generator": pymdownx.emoji.to_alt,
                },
                "pymdownx.tasklist": {"custom_checkbox": True},
            },
        )
        name = os.path.basename(fs_path)
        title = html.escape(os.path.splitext(name)[0])

        rel = os.path.relpath(os.path.dirname(fs_path), self.base_dir)
        parent_url = "/" if rel == "." else "/" + rel.replace(os.sep, "/") + "/"

        page = f"""<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title}</title>
<style>{_CSS_MARKDOWN}</style>
</head>
<body>
<div class="md-header">
  <div class="md-header-title">📝 {title}</div>
  <a href="{html.escape(parent_url)}">← Volver</a>
</div>
<div class="md-wrap">
  <div class="md-body">{md_html}</div>
</div>
</body>
</html>"""
        self._send_html(page)

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
            meta.setdefault("files", {})[filename] = "📄"
            guardar_metadata(dir_path, meta)

            redirect = carpeta if carpeta.startswith("/") else "/" + carpeta
            self._redirect(redirect)
        except Exception as exc:
            self.send_error(500, f"Error al subir el archivo: {exc}")

    def handle_create_folder(self):
        form = self._parse_form()
        nombre = form.getvalue("nombre", "").strip()
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
        meta.setdefault("files", {})[nombre] = "📁"
        guardar_metadata(parent_path, meta)

        redirect = carpeta_padre if carpeta_padre.startswith("/") else "/" + carpeta_padre
        self._redirect(redirect)

    # ── delete handler ────────────────────────────────────────────────────────

    def handle_delete(self):
        try:
            form = self._parse_form()
            rutas = [r for r in form.getlist("ruta") if r]
            if not rutas:
                ruta_unica = form.getvalue("ruta", "")
                if ruta_unica:
                    rutas = [ruta_unica]
            if not rutas:
                self.send_error(400, "No se especificó ruta.")
                return

            parent_dir_retorno = None
            for ruta in rutas:
                fs = self.safe_path(ruta)
                if fs is None or not os.path.exists(fs):
                    self.send_error(404, "Elemento no encontrado.")
                    return

                # No permitir eliminar el directorio raíz
                if os.path.realpath(fs) == os.path.realpath(self.base_dir):
                    self.send_error(403, "No se puede eliminar el directorio raíz.")
                    return

                nombre = os.path.basename(fs)
                parent_dir = os.path.dirname(fs)
                if parent_dir_retorno is None:
                    parent_dir_retorno = parent_dir

                # Si es una página generada con JSON, eliminar también el .source.json
                if os.path.isfile(fs):
                    source_json = ruta_json_fuente(fs)
                    if os.path.exists(source_json):
                        os.remove(source_json)
                    os.remove(fs)
                elif os.path.isdir(fs):
                    shutil.rmtree(fs)

                # Eliminar la entrada del metadata.json
                meta = cargar_metadata(parent_dir)
                if nombre in meta.get("files", {}):
                    del meta["files"][nombre]
                    guardar_metadata(parent_dir, meta)

            if parent_dir_retorno is None:
                parent_dir_retorno = self.base_dir

            # Redirigir a la carpeta padre
            parent_url = os.path.relpath(parent_dir_retorno, self.base_dir)
            if parent_url == ".":
                parent_url = "/"
            else:
                parent_url = "/" + parent_url.replace(os.sep, "/")
            self._redirect(parent_url)
        except Exception as exc:
            self.send_error(500, f"Error al eliminar: {exc}")

    def handle_move(self):
        try:
            form = self._parse_form()
            origenes = [o for o in form.getlist("origen") if o]
            if not origenes:
                origen_unico = form.getvalue("origen", "")
                if origen_unico:
                    origenes = [origen_unico]
            destino = form.getvalue("destino", "")
            nuevo_nombre = (form.getvalue("nuevo_nombre", "") or "").strip()

            if not origenes or not destino:
                self.send_error(400, "Faltan datos para mover.")
                return

            ruta_destino_dir = self.safe_path(destino)
            if ruta_destino_dir is None or not os.path.isdir(ruta_destino_dir):
                self.send_error(404, "Carpeta destino no encontrada.")
                return

            if len(origenes) > 1 and nuevo_nombre:
                self.send_error(400, "No se puede renombrar en movimiento múltiple.")
                return

            for origen in origenes:
                ruta_origen = self.safe_path(origen)
                if ruta_origen is None or not os.path.exists(ruta_origen):
                    self.send_error(404, "Elemento origen no encontrado.")
                    return
                if os.path.realpath(ruta_origen) == os.path.realpath(self.base_dir):
                    self.send_error(403, "No se puede mover la carpeta raíz.")
                    return

                nombre_origen = os.path.basename(ruta_origen)
                nombre_final = (nuevo_nombre or nombre_origen).strip()
                if (not nombre_final or ".." in nombre_final or "/" in nombre_final or
                        "\\" in nombre_final):
                    self.send_error(400, "Nombre inválido.")
                    return

                ruta_final = os.path.join(ruta_destino_dir, nombre_final)
                ruta_origen_real = os.path.realpath(ruta_origen)
                ruta_final_real = os.path.realpath(ruta_final)

                if ruta_origen_real == ruta_final_real:
                    continue

                if os.path.exists(ruta_final):
                    self.send_error(409, f'Ya existe "{nombre_final}" en destino.')
                    return

                if os.path.isdir(ruta_origen):
                    if ruta_final_real.startswith(ruta_origen_real + os.sep):
                        self.send_error(409, "No se puede mover una carpeta dentro de sí misma.")
                        return

                ruta_json_origen = ""
                ruta_json_destino = ""
                if os.path.isfile(ruta_origen) and ruta_origen.lower().endswith(".html"):
                    ruta_json_origen = ruta_json_fuente(ruta_origen)
                    ruta_json_destino = ruta_json_fuente(ruta_final)

                shutil.move(ruta_origen, ruta_final)

                if ruta_json_origen and os.path.exists(ruta_json_origen):
                    shutil.move(ruta_json_origen, ruta_json_destino)

                padre_origen = os.path.dirname(ruta_origen)
                meta_origen = cargar_metadata(padre_origen)
                if nombre_origen in meta_origen.get("files", {}):
                    del meta_origen["files"][nombre_origen]
                    guardar_metadata(padre_origen, meta_origen)

                meta_destino = cargar_metadata(ruta_destino_dir)
                meta_destino.setdefault("files", {})[nombre_final] = "📁" if os.path.isdir(ruta_final) else "📄"
                guardar_metadata(ruta_destino_dir, meta_destino)

            self._redirect(self._ruta_url_desde_fs(ruta_destino_dir))
        except Exception as exc:
            self.send_error(500, f"Error al mover: {exc}")

    # ── API endpoints ────────────────────────────────────────────────────────

    def _send_json(self, data):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def api_cargar_markdown(self, query: dict):
        ruta = query.get("ruta", [""])[0]
        if not ruta:
            self._send_json({"error": "No se especificó ruta."})
            return
        fs = self.safe_path(ruta)
        if fs is None or not os.path.isfile(fs):
            self._send_json({"error": "Archivo no encontrado."})
            return
        try:
            with open(fs, "r", encoding="utf-8") as f:
                contenido = f.read()
            self._send_json({"contenido": contenido})
        except Exception as e:
            self._send_json({"error": str(e)})

    # ── markdown editor page ─────────────────────────────────────────────────

    def serve_markdown_editor(self, query: dict, *, msg: str = "", msg_type: str = "ok"):
        msg = msg or query.get("msg", [""])[0]
        msg_type = msg_type or query.get("tipo", ["ok"])[0]
        carpeta = query.get("carpeta", ["/"])[0]
        editar = query.get("editar", [""])[0]
        self._send_html(self._render_markdown_editor(carpeta, msg=msg, msg_type=msg_type, editar=editar))

    def _render_markdown_editor(self, carpeta_sel: str = "/", *, msg: str = "", msg_type: str = "ok", editar: str = "") -> str:
        alert_html = ""
        if msg:
            alert_html = f'<div class="alert alert-{html.escape(msg_type)}" style="margin:8px 16px">{html.escape(msg)}</div>'

        editar_autoload_js = ""
        if editar:
            editar_parts = editar.rsplit("/", 1)
            editar_carpeta = editar_parts[0] if len(editar_parts) > 1 else "/"
            editar_nombre = editar_parts[-1]
            if editar_nombre.lower().endswith(".md"):
                editar_nombre = editar_nombre[:-3]
            carpeta_sel = editar_carpeta or "/"
            editar_autoload_js = f"""
(function() {{
  var ruta = {json.dumps(editar)};
  fetch('/api/markdown/cargar?ruta=' + encodeURIComponent(ruta))
    .then(function(r) {{ return r.json(); }})
    .then(function(data) {{
      if (data.error) {{ alert(data.error); return; }}
      document.getElementById('md-input').value = data.contenido;
      document.getElementById('editar-ruta').value = ruta;
      document.querySelector('input[name="nombre_archivo"]').value = {json.dumps(editar_nombre)};
      updatePreview();
    }});
}})();
"""

        carpetas = obtener_todas_carpetas(self.base_dir)
        opts = _carpeta_options_html(carpetas, carpeta_sel)

        return f"""<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>📝 Editor Markdown</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=DM+Sans:wght@400;500;600;700&family=JetBrains+Mono:wght@400;600;700&display=swap" rel="stylesheet">
<style>
{_CSS_BASE}
/* ── Markdown editor layout ── */
.md-editor-grid{{display:grid;grid-template-columns:1fr 1fr;gap:0;height:calc(100vh - 130px);overflow:hidden}}
.md-editor-left{{display:flex;flex-direction:column;border-right:1px solid var(--border);overflow:hidden}}
.md-editor-right{{display:flex;flex-direction:column;overflow:hidden}}
.md-editor-wrap{{flex:1;display:flex;flex-direction:column;overflow:hidden;padding:12px;gap:6px}}
.md-editor-wrap textarea{{flex:1;font-family:'JetBrains Mono',monospace;font-size:13px;
  line-height:1.6;resize:none;border:1.5px solid var(--border);border-radius:8px;padding:12px;
  background:#1e1e2e;color:#cdd6f4;tab-size:2}}
.md-editor-wrap textarea:focus{{outline:none;border-color:var(--pri);
  box-shadow:0 0 0 3px rgba(99,102,241,.12)}}
.md-save-section{{padding:12px;border-top:1px solid var(--border);background:#fff;flex-shrink:0}}
.md-save-row{{display:flex;gap:10px;align-items:end}}
.md-save-row .fg{{flex:1;margin-bottom:0}}
.md-save-row label{{font-size:12px;font-weight:600;margin-bottom:4px;display:block;color:var(--text)}}
.md-preview-section{{flex:1;display:flex;flex-direction:column;overflow:hidden}}
.md-preview-header{{flex-shrink:0;background:linear-gradient(135deg,#6366F1,#8B5CF6);
  color:#fff;padding:10px 18px;font-size:13px;font-weight:700;
  display:flex;align-items:center;justify-content:space-between}}
.md-preview-body{{flex:1;overflow-y:auto;padding:24px 32px}}
.md-preview-empty{{text-align:center;padding:60px 20px;color:var(--sub);font-size:14px}}
@media(max-width:900px){{
  .md-editor-grid{{grid-template-columns:1fr;height:auto}}
  .md-editor-left{{min-height:50vh}}
  .md-editor-right{{min-height:50vh}}
}}
{_CSS_MARKDOWN.replace("body{", "body.x-unused{")}
</style>
</head>
<body>

<div class="hdr">
  <div class="hdr-title">📝 Editor Markdown</div>
  <div class="hdr-actions">
    <a href="/" class="btn btn-ghost">\u2190 Volver</a>
  </div>
</div>

{alert_html}

<div class="md-editor-grid">
  <div class="md-editor-left">
    <div class="md-editor-wrap">
      <textarea id="md-input" oninput="schedulePreview()"
        placeholder="# Mi documento&#10;&#10;Escribe o pega tu contenido Markdown aquí..."></textarea>
    </div>
    <div class="md-save-section">
      <form method="POST" action="/editarMarkdown" enctype="multipart/form-data" id="md-form">
        <input type="hidden" name="editar_ruta" id="editar-ruta">
        <div class="md-save-row">
          <div class="fg">
            <label>📁 Carpeta</label>
            <select name="carpeta" class="fc" style="padding:7px 10px">{opts}</select>
          </div>
          <div class="fg">
            <label>🏷️ Nombre (.md)</label>
            <input type="text" name="nombre_archivo" class="fc" placeholder="mi-documento"
                   pattern="[\\w\\-.]+" style="padding:7px 10px"
                   title="Solo letras, números, guiones y puntos">
          </div>
          <div style="flex-shrink:0">
            <button type="submit" class="btn btn-pri" style="white-space:nowrap;padding:9px 20px">
              💾 Guardar .md
            </button>
          </div>
        </div>
      </form>
    </div>
  </div>

  <div class="md-editor-right">
    <div class="md-preview-section">
      <div class="md-preview-header">
        <span>👁️ Vista previa</span>
      </div>
      <div class="md-preview-body md-body" id="md-preview">
        <div class="md-preview-empty">
          <div style="font-size:48px;margin-bottom:12px">📝</div>
          <div>Escribe o pega Markdown en el panel izquierdo</div>
        </div>
      </div>
    </div>
  </div>
</div>

<script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
<script>
var previewTimer = null;
function schedulePreview() {{
  clearTimeout(previewTimer);
  previewTimer = setTimeout(updatePreview, 300);
}}
function updatePreview() {{
  var txt = document.getElementById('md-input').value;
  var preview = document.getElementById('md-preview');
  if (!txt.trim()) {{
    preview.innerHTML = '<div class="md-preview-empty"><div style="font-size:48px;margin-bottom:12px">📝</div><div>Escribe o pega Markdown en el panel izquierdo</div></div>';
    return;
  }}
  try {{
    preview.innerHTML = marked.parse(txt);
  }} catch(e) {{
    preview.innerHTML = '<p style="color:#dc2626">Error al renderizar: ' + e.message + '</p>';
  }}
}}
// Handle form submit: include textarea content
document.getElementById('md-form').addEventListener('submit', function(e) {{
  var txt = document.getElementById('md-input').value;
  if (!txt.trim()) {{
    e.preventDefault();
    alert('El contenido Markdown está vacío.');
    return;
  }}
  var nombre = document.querySelector('input[name="nombre_archivo"]').value.trim();
  if (!nombre) {{
    e.preventDefault();
    alert('Introduce un nombre para el archivo.');
    return;
  }}
  // Add markdown content as hidden field
  var hidden = document.createElement('input');
  hidden.type = 'hidden';
  hidden.name = 'contenido_md';
  hidden.value = txt;
  this.appendChild(hidden);
}});
// Tab key support in textarea
document.getElementById('md-input').addEventListener('keydown', function(e) {{
  if (e.key === 'Tab') {{
    e.preventDefault();
    var start = this.selectionStart;
    var end = this.selectionEnd;
    this.value = this.value.substring(0, start) + '  ' + this.value.substring(end);
    this.selectionStart = this.selectionEnd = start + 2;
    schedulePreview();
  }}
}});
{editar_autoload_js}
</script>
</body>
</html>"""

    def handle_markdown_save(self):
        try:
            form = self._parse_form()
            carpeta = form.getvalue("carpeta", "/")
            nombre_archivo = (form.getvalue("nombre_archivo", "") or "").strip()
            editar_ruta = (form.getvalue("editar_ruta", "") or "").strip()
            contenido = form.getvalue("contenido_md", "") or ""

            if not contenido.strip():
                self._redirect_with_msg("/editarMarkdown", "El contenido Markdown está vacío.", "err", carpeta)
                return

            if not nombre_archivo:
                self._redirect_with_msg("/editarMarkdown", "Introduce un nombre para el archivo.", "err", carpeta)
                return

            # Ensure .md extension
            if not nombre_archivo.lower().endswith(".md"):
                nombre_archivo += ".md"

            dir_path = self.safe_path(carpeta)
            if dir_path is None or not os.path.isdir(dir_path):
                dir_path = self.base_dir

            if editar_ruta:
                filename = nombre_archivo
            else:
                filename = asegurar_nombre_unico(dir_path, nombre_archivo)
            filepath = os.path.join(dir_path, filename)

            ruta_anterior = ""
            if editar_ruta:
                ruta_anterior = self.safe_path(editar_ruta)
                if ruta_anterior is None or not os.path.isfile(ruta_anterior):
                    self._redirect_with_msg("/editarMarkdown", "No se encontró el archivo original para editar.", "err", carpeta)
                    return
                if os.path.exists(filepath) and os.path.realpath(filepath) != os.path.realpath(ruta_anterior):
                    self._redirect_with_msg("/editarMarkdown", f'Ya existe un archivo llamado "{filename}".', "err", carpeta)
                    return

            with open(filepath, "w", encoding="utf-8") as fh:
                fh.write(contenido)

            # If renamed, delete the old file
            if ruta_anterior and os.path.realpath(ruta_anterior) != os.path.realpath(filepath):
                if os.path.exists(ruta_anterior):
                    os.remove(ruta_anterior)
                nombre_anterior = os.path.basename(ruta_anterior)
                dir_anterior = os.path.dirname(ruta_anterior)
                meta_anterior = cargar_metadata(dir_anterior)
                if nombre_anterior in meta_anterior.get("files", {}):
                    del meta_anterior["files"][nombre_anterior]
                    guardar_metadata(dir_anterior, meta_anterior)

            meta = cargar_metadata(dir_path)
            meta.setdefault("files", {})[filename] = "📝"
            guardar_metadata(dir_path, meta)

            redirect = carpeta if carpeta.startswith("/") else "/" + carpeta
            self._redirect(redirect)
        except Exception as exc:
            self.send_error(500, f"Error al guardar el Markdown: {exc}")

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

    def _ruta_url_desde_fs(self, ruta_fs: str) -> str:
        rel = os.path.relpath(ruta_fs, self.base_dir)
        if rel == ".":
            return "/"
        return "/" + rel.replace(os.sep, "/")

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
