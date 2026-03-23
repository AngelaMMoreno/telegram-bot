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

try:
    import yaml
    _YAML_DISPONIBLE = True
except ImportError:
    _YAML_DISPONIBLE = False

from generador_paginas import generar_html

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


def _es_plantilla_pagina(filename: str, contenido: bytes) -> dict | None:
    """Detecta si un archivo es una plantilla de página y devuelve el dict parseado."""
    nombre_lower = filename.lower()
    if not (nombre_lower.endswith(".yaml") or nombre_lower.endswith(".yml")
            or nombre_lower.endswith(".json")):
        return None

    try:
        texto = contenido.decode("utf-8")
    except UnicodeDecodeError:
        return None

    try:
        if nombre_lower.endswith(".json"):
            data = json.loads(texto)
        else:
            if not _YAML_DISPONIBLE:
                return None
            data = yaml.safe_load(texto)
    except Exception:
        return None

    if isinstance(data, dict) and "titulo" in data and (
        "secciones" in data or "categorias" in data
    ):
        return data

    return None


def _leer_plantilla_pagina(fs_path: str) -> dict | None:
    """Lee una plantilla de página del disco si el archivo coincide con el formato esperado."""
    try:
        with open(fs_path, "rb") as fh:
            return _es_plantilla_pagina(os.path.basename(fs_path), fh.read())
    except OSError:
        return None


def _es_archivo_auxiliar_pagina(fs_path: str) -> bool:
    """Indica si el archivo es una plantilla de página que no debe listarse por defecto."""
    return _leer_plantilla_pagina(fs_path) is not None


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
        elif path == "/crearPagina":
            self.serve_crear_pagina(query)
        else:
            self.serve_path(path)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        if path == "/subirFichero":
            self.handle_upload()
        elif path == "/crearCarpeta":
            self.handle_create_folder()
        elif path == "/crearPagina":
            self.handle_crear_pagina()
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
            [
                e for e in entries
                if e.is_file() and not e.name.startswith(".") and not _es_archivo_auxiliar_pagina(e.path)
            ],
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
    <a href="/crearPagina?carpeta={urllib.parse.quote(url_path or '/')}" class="btn btn-ghost">📖 Crear página</a>
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
        plantilla = _leer_plantilla_pagina(fs_path)
        if plantilla is not None:
            self._send_html(generar_html(plantilla))
            return

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

    # ── crear página ────────────────────────────────────────────────────────

    def serve_crear_pagina(self, query: dict, *, msg: str = "", msg_type: str = "ok"):
        carpeta = query.get("carpeta", ["/"])[0]
        msg = msg or query.get("msg", [""])[0]
        msg_type = msg_type or query.get("tipo", ["ok"])[0]
        self._send_html(self._render_crear_pagina(carpeta, msg=msg, msg_type=msg_type))

    def _render_crear_pagina(self, carpeta_sel: str = "/", *, msg: str = "", msg_type: str = "ok") -> str:
        carpetas = obtener_todas_carpetas(self.base_dir)
        opts = _carpeta_options_html(carpetas, carpeta_sel)

        alert_html = ""
        if msg:
            alert_html = f'<div class="alert alert-{msg_type}">{html.escape(msg)}</div>'

        back_url = html.escape(carpeta_sel) if carpeta_sel.startswith("/") else "/"

        documento = """<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>📖 Crear página de teoría</title>
<style>
__CSS_BASE__
.yaml-editor{width:100%;min-height:420px;font-family:'Courier New',monospace;font-size:13px;
  line-height:1.5;padding:14px;border:1.5px solid var(--border);border-radius:10px;
  background:#1e1e2e;color:#cdd6f4;resize:vertical;tab-size:2}
.yaml-editor::placeholder{color:#585b70}
.yaml-editor:focus{outline:none;border-color:var(--pri);box-shadow:0 0 0 3px rgba(99,102,241,.15)}
.hint{font-size:12px;color:var(--sub);margin-top:6px;line-height:1.5}
.hint code{background:var(--pri-light);padding:1px 5px;border-radius:4px;font-size:11px;color:var(--pri-d)}
.preview-frame{width:100%;height:540px;border:1.5px solid var(--border);border-radius:10px;
  background:#fff;margin-top:12px;display:block}
.tabs{display:flex;gap:4px;margin-bottom:12px;flex-wrap:wrap}
.tab{padding:7px 16px;border-radius:8px;font-size:13px;font-weight:600;cursor:pointer;
  border:1.5px solid var(--border);background:#fff;color:var(--sub);transition:all .15s}
.tab.active{background:var(--pri);color:#fff;border-color:var(--pri)}
.panel{display:none}
.panel.active{display:block}
.disenador{display:grid;gap:14px}
.bloque-diseno{border:1.5px solid var(--border);border-radius:12px;background:#fff;padding:16px}
.bloque-diseno h3,.bloque-diseno h4,.bloque-diseno h5{margin:0 0 10px 0;color:var(--text)}
.grid-dos{display:grid;gap:12px;grid-template-columns:repeat(auto-fit,minmax(220px,1fr))}
.acciones-inline{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}
.btn-mini{border:1px solid var(--border);background:#fff;border-radius:8px;padding:6px 10px;cursor:pointer;font-size:12px;font-weight:600;color:var(--sub)}
.btn-mini:hover{border-color:var(--pri);color:var(--pri)}
.btn-mini.peligro{border-color:#fecaca;color:#b91c1c;background:#fff5f5}
.nodo-diseno{border:1px solid var(--border);border-radius:12px;background:#fafafa;padding:14px;margin-top:10px}
.nodo-diseno.nivel-1{margin-left:18px;background:#fcfcff}
.nodo-diseno.nivel-2{margin-left:36px;background:#f8faff}
.cabecera-nodo{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:10px}
.cabecera-nodo strong{color:var(--text)}
.selector-check{display:flex;align-items:center;gap:8px;font-size:13px;color:var(--sub);margin-top:6px}
.ayuda-diseno{padding:10px 12px;border-radius:10px;background:var(--pri-light);color:var(--pri-d);font-size:12px;line-height:1.5}
</style>
</head>
<body>
<div class="hdr">
  <div class="hdr-title">📖 Crear página de teoría</div>
  <div class="hdr-actions">
    <a href="__BACK_URL__" class="btn btn-ghost">← Volver</a>
  </div>
</div>

<div class="form-wrap">
__ALERT_HTML__

<div class="form-card">
  <h2>🧩 Crear página desde YAML o con asistente visual</h2>

  <form method="POST" action="/crearPagina" id="pageForm">
    <input type="hidden" name="formato_contenido" id="formatoContenido" value="yaml">

    <div class="fg">
      <label>📁 Carpeta destino</label>
      <select name="carpeta" class="fc">__OPTS__</select>
    </div>

    <div class="fg">
      <label>🏷️ Nombre del archivo (sin extensión)</label>
      <input type="text" name="nombre" class="fc" placeholder="mi-tema-de-estudio" required
             pattern="[^/\\<>:&quot;|?*.]+" title="Sin barras, puntos ni caracteres especiales">
    </div>

    <div class="fg">
      <div class="tabs">
        <button type="button" class="tab active" data-tab="editor">✏️ Editor YAML</button>
        <button type="button" class="tab" data-tab="disenador">🧭 Asistente visual</button>
        <button type="button" class="tab" data-tab="preview">👁️ Vista previa</button>
      </div>

      <div class="panel active" id="panel-editor">
        <textarea name="yaml_content" class="yaml-editor" id="yamlEditor" required
                  placeholder='# Pega aquí tu plantilla YAML
titulo: "Mi tema de estudio"
descripcion: "Descripción breve"

secciones:
  - titulo: "Bloque principal"
    categorias:
      - nombre: "Tarjeta"
        icono: "📚"
        color: "#1254a0"
        items:
          - nombre: "Apartado"
            descripcion: "Resumen"
            contraible: true
            detalle:
              texto: "Desarrollo del apartado"
            subitems:
              - nombre: "Subapartado"
                descripcion: "Detalle extra"
                contraible: false
                detalle:
                  texto: "Siempre visible"'></textarea>
        <div class="hint">
          Puedes pegar YAML a mano o usar el asistente visual. Si usas el asistente, se guardará una plantilla estructurada y no se mostrará como archivo en el listado servido.
        </div>
      </div>

      <div class="panel" id="panel-disenador">
        <div class="disenador">
          <div class="ayuda-diseno">
            Crea el tema paso a paso sin escribir YAML. Cada apartado o subapartado puede quedar <strong>contraíble</strong> o <strong>siempre visible</strong>.
          </div>
          <div class="bloque-diseno">
            <h3>📄 Datos generales</h3>
            <div class="grid-dos">
              <div class="fg"><label>Título</label><input type="text" class="fc" id="tituloDiseno"></div>
              <div class="fg"><label>Descripción</label><input type="text" class="fc" id="descripcionDiseno"></div>
            </div>
            <div class="selector-check"><input type="checkbox" id="activarBanner"> <label for="activarBanner">Añadir banner destacado</label></div>
            <div id="camposBanner" style="display:none;margin-top:12px">
              <div class="grid-dos">
                <div class="fg"><label>Etiqueta del banner</label><input type="text" class="fc" id="bannerEtiqueta"></div>
                <div class="fg"><label>Título del banner</label><input type="text" class="fc" id="bannerTitulo"></div>
              </div>
              <div class="fg"><label>Descripción del banner</label><textarea class="fc" id="bannerDescripcion" rows="3"></textarea></div>
            </div>
          </div>
          <div class="bloque-diseno">
            <div class="cabecera-nodo">
              <h3>🗂️ Secciones y tarjetas</h3>
              <button type="button" class="btn-mini" id="agregarSeccionBtn">+ Añadir sección</button>
            </div>
            <div id="contenedorSecciones"></div>
          </div>
        </div>
      </div>

      <div class="panel" id="panel-preview">
        <iframe id="previewFrame" class="preview-frame"></iframe>
        <div class="hint">La vista previa se genera con el contenido actual del editor o del asistente visual.</div>
      </div>
    </div>

    <button type="submit" class="btn-submit">📖 Generar página</button>
  </form>
</div>
</div>

<script>
const estadoDiseno = {
  titulo: '',
  descripcion: '',
  secciones: [crearSeccion()],
};
let modoContenido = 'editor';

function crearSeccion() {
  return { titulo: '', categorias: [crearCategoria()] };
}

function crearCategoria() {
  return { nombre: '', icono: '📚', color: '#1254a0', etiquetasTexto: '', items: [crearItem()] };
}

function crearItem() {
  return {
    nombre: '',
    descripcion: '',
    etiqueta: '',
    contraible: true,
    mostrar_abierto: false,
    detalle: { texto: '', nota: '' },
    subitems: [],
  };
}

function limpiarDato(valor) {
  if (Array.isArray(valor)) {
    const elementos = valor.map(limpiarDato).filter((item) => item !== undefined);
    return elementos.length ? elementos : undefined;
  }
  if (valor && typeof valor === 'object') {
    const limpio = {};
    Object.entries(valor).forEach(([clave, contenido]) => {
      const resultado = limpiarDato(contenido);
      if (resultado !== undefined && !(typeof resultado === 'string' && resultado.trim() === '')) {
        limpio[clave] = resultado;
      }
    });
    return Object.keys(limpio).length ? limpio : undefined;
  }
  if (typeof valor === 'string') {
    return valor.trim() ? valor : undefined;
  }
  if (typeof valor === 'boolean') {
    return valor;
  }
  return valor;
}

function normalizarParaGuardar() {
  const plantilla = {
    titulo: estadoDiseno.titulo || 'Nueva página',
    descripcion: estadoDiseno.descripcion || '',
    secciones: estadoDiseno.secciones,
  };
  if (estadoDiseno.bannerActivo) {
    plantilla.banner = {
      etiqueta: estadoDiseno.bannerEtiqueta || '',
      titulo: estadoDiseno.bannerTitulo || '',
      descripcion: estadoDiseno.bannerDescripcion || '',
    };
  }
  const limpio = limpiarDato(plantilla) || {};
  (limpio.secciones || []).forEach((seccion) => {
    (seccion.categorias || []).forEach((categoria) => {
      if (categoria.etiquetasTexto) {
        categoria.etiquetas = categoria.etiquetasTexto.split(',').map((txt) => txt.trim()).filter(Boolean);
      }
      delete categoria.etiquetasTexto;
    });
  });
  return limpio;
}

function sincronizarEditorSegunModo() {
  if (modoContenido !== 'disenador') {
    document.getElementById('formatoContenido').value = 'yaml';
    return;
  }
  const contenido = JSON.stringify(normalizarParaGuardar(), null, 2);
  document.getElementById('yamlEditor').value = contenido;
  document.getElementById('formatoContenido').value = 'json';
}

function cambiarTab(tab) {
  document.querySelectorAll('.tab').forEach((boton) => {
    boton.classList.toggle('active', boton.dataset.tab === tab);
  });
  document.querySelectorAll('.panel').forEach((panel) => panel.classList.remove('active'));
  document.getElementById(`panel-${tab}`).classList.add('active');

  if (tab === 'preview') {
    sincronizarEditorSegunModo();
    generarVistaPrevia();
  }
}

function generarVistaPrevia() {
  const form = new FormData();
  form.append('yaml_content', document.getElementById('yamlEditor').value);
  form.append('preview', '1');
  fetch('/crearPagina', { method: 'POST', body: form })
    .then((respuesta) => respuesta.text())
    .then((html) => { document.getElementById('previewFrame').srcdoc = html; })
    .catch(() => {
      document.getElementById('previewFrame').srcdoc = '<p style="padding:2rem;color:#991B1B;">Error al generar la vista previa.</p>';
    });
}

function renderizarSecciones() {
  const contenedor = document.getElementById('contenedorSecciones');
  contenedor.innerHTML = '';
  estadoDiseno.secciones.forEach((seccion, indiceSeccion) => {
    const caja = document.createElement('div');
    caja.className = 'nodo-diseno';
    caja.innerHTML = `
      <div class="cabecera-nodo">
        <strong>Sección ${indiceSeccion + 1}</strong>
        <button type="button" class="btn-mini peligro">Eliminar sección</button>
      </div>
      <div class="fg"><label>Título de la sección</label><input type="text" class="fc" value="${escapeHtml(seccion.titulo || '')}"></div>
      <div class="acciones-inline"><button type="button" class="btn-mini">+ Añadir tarjeta</button></div>
      <div class="categorias"></div>
    `;
    caja.querySelector('.btn-mini.peligro').onclick = () => {
      estadoDiseno.secciones.splice(indiceSeccion, 1);
      if (!estadoDiseno.secciones.length) estadoDiseno.secciones.push(crearSeccion());
      renderizarSecciones();
    };
    caja.querySelector('input').oninput = (evento) => {
      seccion.titulo = evento.target.value;
      sincronizarEditorSegunModo();
    };
    caja.querySelector('.acciones-inline .btn-mini').onclick = () => {
      seccion.categorias.push(crearCategoria());
      renderizarSecciones();
    };
    const categorias = caja.querySelector('.categorias');
    seccion.categorias.forEach((categoria, indiceCategoria) => {
      categorias.appendChild(renderizarCategoria(categoria, indiceSeccion, indiceCategoria));
    });
    contenedor.appendChild(caja);
  });
  sincronizarEditorSegunModo();
}

function renderizarCategoria(categoria, indiceSeccion, indiceCategoria) {
  const caja = document.createElement('div');
  caja.className = 'nodo-diseno nivel-1';
  caja.innerHTML = `
    <div class="cabecera-nodo">
      <strong>Tarjeta ${indiceCategoria + 1}</strong>
      <button type="button" class="btn-mini peligro">Eliminar tarjeta</button>
    </div>
    <div class="grid-dos">
      <div class="fg"><label>Nombre</label><input type="text" class="fc nombre" value="${escapeHtml(categoria.nombre || '')}"></div>
      <div class="fg"><label>Icono</label><input type="text" class="fc icono" value="${escapeHtml(categoria.icono || '📚')}"></div>
      <div class="fg"><label>Color</label><input type="color" class="fc color" value="${escapeHtml(categoria.color || '#1254a0')}"></div>
      <div class="fg"><label>Etiquetas (coma separada)</label><input type="text" class="fc etiquetas" value="${escapeHtml(categoria.etiquetasTexto || '')}"></div>
    </div>
    <div class="acciones-inline"><button type="button" class="btn-mini agregar-apartado">+ Añadir apartado</button></div>
    <div class="items"></div>
  `;
  caja.querySelector('.peligro').onclick = () => {
    estadoDiseno.secciones[indiceSeccion].categorias.splice(indiceCategoria, 1);
    if (!estadoDiseno.secciones[indiceSeccion].categorias.length) {
      estadoDiseno.secciones[indiceSeccion].categorias.push(crearCategoria());
    }
    renderizarSecciones();
  };
  caja.querySelector('.nombre').oninput = (e) => { categoria.nombre = e.target.value; sincronizarEditorSegunModo(); };
  caja.querySelector('.icono').oninput = (e) => { categoria.icono = e.target.value; sincronizarEditorSegunModo(); };
  caja.querySelector('.color').oninput = (e) => { categoria.color = e.target.value; sincronizarEditorSegunModo(); };
  caja.querySelector('.etiquetas').oninput = (e) => { categoria.etiquetasTexto = e.target.value; sincronizarEditorSegunModo(); };
  caja.querySelector('.agregar-apartado').onclick = () => {
    categoria.items.push(crearItem());
    renderizarSecciones();
  };
  const contenedorItems = caja.querySelector('.items');
  categoria.items.forEach((item, indiceItem) => {
    contenedorItems.appendChild(renderizarItem(item, categoria.items, indiceItem, 0));
  });
  return caja;
}

function renderizarItem(item, coleccion, indiceItem, nivel) {
  const caja = document.createElement('div');
  caja.className = `nodo-diseno nivel-${Math.min(nivel + 1, 2)}`;
  caja.innerHTML = `
    <div class="cabecera-nodo">
      <strong>${nivel === 0 ? 'Apartado' : 'Subapartado'} ${indiceItem + 1}</strong>
      <button type="button" class="btn-mini peligro">Eliminar</button>
    </div>
    <div class="grid-dos">
      <div class="fg"><label>Nombre</label><input type="text" class="fc nombre" value="${escapeHtml(item.nombre || '')}"></div>
      <div class="fg"><label>Etiqueta</label><input type="text" class="fc etiqueta" value="${escapeHtml(item.etiqueta || '')}"></div>
    </div>
    <div class="fg"><label>Descripción breve</label><textarea class="fc descripcion" rows="2">${escapeHtml(item.descripcion || '')}</textarea></div>
    <div class="selector-check"><input type="checkbox" class="contraible" ${item.contraible ? 'checked' : ''}> <label>Mostrar como bloque contraíble</label></div>
    <div class="selector-check"><input type="checkbox" class="mostrar-abierto" ${item.mostrar_abierto ? 'checked' : ''}> <label>Empezar desplegado</label></div>
    <div class="fg"><label>Texto ampliado</label><textarea class="fc detalle-texto" rows="3">${escapeHtml((item.detalle || {}).texto || '')}</textarea></div>
    <div class="fg"><label>Nota ampliada (admite HTML sencillo)</label><textarea class="fc detalle-nota" rows="3">${escapeHtml((item.detalle || {}).nota || '')}</textarea></div>
    <div class="acciones-inline">
      <button type="button" class="btn-mini agregar-subitem">+ Añadir subapartado</button>
    </div>
    <div class="subitems"></div>
  `;
  caja.querySelector('.peligro').onclick = () => {
    coleccion.splice(indiceItem, 1);
    if (!coleccion.length) coleccion.push(crearItem());
    renderizarSecciones();
  };
  caja.querySelector('.nombre').oninput = (e) => { item.nombre = e.target.value; sincronizarEditorSegunModo(); };
  caja.querySelector('.etiqueta').oninput = (e) => { item.etiqueta = e.target.value; sincronizarEditorSegunModo(); };
  caja.querySelector('.descripcion').oninput = (e) => { item.descripcion = e.target.value; sincronizarEditorSegunModo(); };
  caja.querySelector('.contraible').onchange = (e) => { item.contraible = e.target.checked; sincronizarEditorSegunModo(); };
  caja.querySelector('.mostrar-abierto').onchange = (e) => { item.mostrar_abierto = e.target.checked; sincronizarEditorSegunModo(); };
  caja.querySelector('.detalle-texto').oninput = (e) => {
    item.detalle = item.detalle || {};
    item.detalle.texto = e.target.value;
    sincronizarEditorSegunModo();
  };
  caja.querySelector('.detalle-nota').oninput = (e) => {
    item.detalle = item.detalle || {};
    item.detalle.nota = e.target.value;
    sincronizarEditorSegunModo();
  };
  caja.querySelector('.agregar-subitem').onclick = () => {
    item.subitems = item.subitems || [];
    item.subitems.push(crearItem());
    renderizarSecciones();
  };
  const subitems = caja.querySelector('.subitems');
  (item.subitems || []).forEach((subitem, indiceSubitem) => {
    subitems.appendChild(renderizarItem(subitem, item.subitems, indiceSubitem, nivel + 1));
  });
  return caja;
}

function escapeHtml(texto) {
  return String(texto)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
}

document.querySelectorAll('.tab').forEach((boton) => {
  boton.addEventListener('click', () => {
    if (boton.dataset.tab === 'disenador') {
      modoContenido = 'disenador';
      document.getElementById('formatoContenido').value = 'json';
    }
    if (boton.dataset.tab === 'editor') {
      modoContenido = 'editor';
      document.getElementById('formatoContenido').value = 'yaml';
    }
    cambiarTab(boton.dataset.tab);
  });
});

document.getElementById('yamlEditor').addEventListener('keydown', function(e) {
  if (e.key === 'Tab') {
    e.preventDefault();
    const inicio = this.selectionStart;
    const fin = this.selectionEnd;
    this.value = this.value.substring(0, inicio) + '  ' + this.value.substring(fin);
    this.selectionStart = this.selectionEnd = inicio + 2;
  }
});

document.getElementById('activarBanner').addEventListener('change', function() {
  estadoDiseno.bannerActivo = this.checked;
  document.getElementById('camposBanner').style.display = this.checked ? 'block' : 'none';
  sincronizarEditorSegunModo();
});
document.getElementById('tituloDiseno').addEventListener('input', (e) => { estadoDiseno.titulo = e.target.value; sincronizarEditorSegunModo(); });
document.getElementById('descripcionDiseno').addEventListener('input', (e) => { estadoDiseno.descripcion = e.target.value; sincronizarEditorSegunModo(); });
document.getElementById('bannerEtiqueta').addEventListener('input', (e) => { estadoDiseno.bannerEtiqueta = e.target.value; sincronizarEditorSegunModo(); });
document.getElementById('bannerTitulo').addEventListener('input', (e) => { estadoDiseno.bannerTitulo = e.target.value; sincronizarEditorSegunModo(); });
document.getElementById('bannerDescripcion').addEventListener('input', (e) => { estadoDiseno.bannerDescripcion = e.target.value; sincronizarEditorSegunModo(); });
document.getElementById('agregarSeccionBtn').addEventListener('click', () => { estadoDiseno.secciones.push(crearSeccion()); renderizarSecciones(); });
document.getElementById('pageForm').addEventListener('submit', () => { sincronizarEditorSegunModo(); });
renderizarSecciones();
</script>
</body>
</html>"""
        return (
            documento
            .replace("__CSS_BASE__", _CSS_BASE)
            .replace("__BACK_URL__", back_url)
            .replace("__ALERT_HTML__", alert_html)
            .replace("__OPTS__", opts)
        )

    def handle_crear_pagina(self):
        try:
            form = self._parse_form()
            yaml_content = form.getvalue("yaml_content", "")
            is_preview = form.getvalue("preview", "")

            if not yaml_content.strip():
                if is_preview:
                    self._send_html("<p style='padding:2rem;color:#991B1B;'>El contenido YAML está vacío.</p>")
                else:
                    self._redirect_with_msg("/crearPagina", "El contenido YAML está vacío.", "err")
                return

            # Parsear YAML
            try:
                if _YAML_DISPONIBLE:
                    data = yaml.safe_load(yaml_content)
                else:
                    data = json.loads(yaml_content)
            except Exception as exc:
                err_msg = f"Error de sintaxis en el YAML: {exc}"
                if is_preview:
                    self._send_html(f"<p style='padding:2rem;color:#991B1B;'>{html.escape(err_msg)}</p>")
                else:
                    self._redirect_with_msg("/crearPagina", err_msg, "err")
                return

            if not isinstance(data, dict) or "titulo" not in data:
                err_msg = "La plantilla debe tener al menos un campo 'titulo'."
                if is_preview:
                    self._send_html(f"<p style='padding:2rem;color:#991B1B;'>{html.escape(err_msg)}</p>")
                else:
                    self._redirect_with_msg("/crearPagina", err_msg, "err")
                return

            # Generar HTML
            html_content = generar_html(data)

            # Si es preview, devolver el HTML directamente
            if is_preview:
                self._send_html(html_content)
                return

            # Guardar archivos
            carpeta = form.getvalue("carpeta", "/")
            nombre = form.getvalue("nombre", "").strip()
            if not nombre:
                nombre = data.get("titulo", "pagina").replace(" ", "_")

            # Sanitizar nombre
            nombre = "".join(c for c in nombre if c not in '/\\<>:"|?*.')

            dir_path = self.safe_path(carpeta)
            if dir_path is None or not os.path.isdir(dir_path):
                dir_path = self.base_dir

            # Guardar HTML
            html_filename = asegurar_nombre_unico(dir_path, nombre + ".html")
            with open(os.path.join(dir_path, html_filename), "w", encoding="utf-8") as fh:
                fh.write(html_content)

            formato_contenido = form.getvalue("formato_contenido", "yaml")
            extension_plantilla = ".json" if formato_contenido == "json" else ".yaml"
            plantilla_filename = asegurar_nombre_unico(dir_path, nombre + extension_plantilla)
            with open(os.path.join(dir_path, plantilla_filename), "w", encoding="utf-8") as fh:
                fh.write(yaml_content)

            meta = cargar_metadata(dir_path)
            meta.setdefault("files", {})[html_filename] = "📖"
            meta.setdefault("files", {})[plantilla_filename] = "📝"
            guardar_metadata(dir_path, meta)

            redirect = carpeta if carpeta.startswith("/") else "/" + carpeta
            self._redirect(redirect)

        except Exception as exc:
            self.send_error(500, f"Error al crear la página: {exc}")

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
            contenido = file_item.file.read()

            # Detectar si es una plantilla de página de teoría
            plantilla = _es_plantilla_pagina(filename, contenido)
            if plantilla is not None:
                # Generar HTML a partir de la plantilla
                try:
                    html_content = generar_html(plantilla)
                    # Guardar el HTML con el mismo nombre pero extensión .html
                    nombre_base = os.path.splitext(filename)[0]
                    html_filename = asegurar_nombre_unico(dir_path, nombre_base + ".html")
                    with open(os.path.join(dir_path, html_filename), "w", encoding="utf-8") as fh:
                        fh.write(html_content)

                    # También guardar el YAML/JSON original
                    filename = asegurar_nombre_unico(dir_path, filename)
                    with open(os.path.join(dir_path, filename), "wb") as fh:
                        fh.write(contenido)

                    meta = cargar_metadata(dir_path)
                    meta.setdefault("files", {})[html_filename] = "📖"
                    meta.setdefault("files", {})[filename] = icono
                    guardar_metadata(dir_path, meta)

                    redirect = carpeta if carpeta.startswith("/") else "/" + carpeta
                    self._redirect(redirect)
                    return
                except Exception as exc:
                    self._redirect_with_msg(
                        "/subirFichero",
                        f"Error generando página desde plantilla: {exc}",
                        "err",
                        carpeta,
                    )
                    return

            filename = asegurar_nombre_unico(dir_path, filename)
            with open(os.path.join(dir_path, filename), "wb") as fh:
                fh.write(contenido)

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