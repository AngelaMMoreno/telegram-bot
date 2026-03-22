import cgi
import html
import io
import json
import mimetypes
import os
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
        else:
            self.serve_path(path)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        if path == "/subirFichero":
            self.handle_upload()
        elif path == "/crearCarpeta":
            self.handle_create_folder()
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
    hilo = threading.Thread(target=servidor.serve_forever, daemon=True)
    hilo.start()
    print(
        f"📂 Servidor de ficheros iniciado en http://0.0.0.0:{puerto} "
        f"(directorio: {base_dir})"
    )
    return servidor


def ejecutar_servidor_desde_entorno() -> None:
    ruta_archivos_publicos = os.getenv("RUTA_ARCHIVOS_PUBLICOS", "/mnt/data/ficheros")
    puerto_archivos_publicos = int(os.getenv("PUERTO_ARCHIVOS_PUBLICOS", "8000"))
    os.makedirs(ruta_archivos_publicos, exist_ok=True)
    handler = crear_handler(ruta_archivos_publicos)
    servidor = ThreadingHTTPServer(("", puerto_archivos_publicos), handler)
    print(
        f"📂 Servidor de ficheros iniciado en http://0.0.0.0:{puerto_archivos_publicos} "
        f"(directorio: {ruta_archivos_publicos})"
    )
    try:
        servidor.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        servidor.server_close()


if __name__ == "__main__":
    ejecutar_servidor_desde_entorno()
