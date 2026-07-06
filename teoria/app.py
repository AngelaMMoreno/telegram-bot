"""
Servicio de teoría de Aprentix.

Sirve /mnt/data/ficheros (montado en /ficheros) como navegador web para los
usuarios con rol 'teoria' o 'admin'. El admin además puede subir, mover y
borrar. El estado "visto/no visto" de cada usuario se persiste en Postgres
a través de PostgREST (tabla ficheros_vistas + RPCs marcar_fichero_*).

Autenticación: JWT firmado por Postgres (HS256, mismo JWT_SECRET). Se
acepta como cabecera Authorization: Bearer <token> (fetch de la SPA) o
como cookie aprentix_token en dominio .aprentix.es (para poder abrir un
PDF con un enlace <a>). La SPA se sirve como estáticos desde ./site.
"""

from __future__ import annotations

import mimetypes
import os
import shutil
from pathlib import Path

import httpx
import jwt
from fastapi import (
    FastAPI, File, Form, HTTPException, Request, UploadFile,
)
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles


# ── Configuración ───────────────────────────────────────────────────────────
BASE_DIR = Path(os.getenv("BASE_DIR", "/ficheros")).resolve()
JWT_SECRET = os.environ["JWT_SECRET"]
POSTGREST_URL = os.getenv("POSTGREST_URL", "http://postgrest:3000")
COOKIE_NAME = os.getenv("COOKIE_NAME", "aprentix_token")

BASE_DIR.mkdir(parents=True, exist_ok=True)

app = FastAPI(title="Aprentix — Teoría", docs_url=None, redoc_url=None)


# ── JWT + roles ─────────────────────────────────────────────────────────────

def extract_jwt(request: Request) -> str:
    auth = request.headers.get("authorization", "")
    if auth.lower().startswith("bearer "):
        return auth.split(" ", 1)[1].strip()
    tok = request.cookies.get(COOKIE_NAME)
    if tok:
        return tok
    raise HTTPException(status_code=401, detail="no_autenticado")


def decode_jwt(token: str) -> dict:
    try:
        return jwt.decode(
            token,
            JWT_SECRET,
            algorithms=["HS256"],
            # PostgREST no fuerza aud/iss; con verificar exp/firma nos basta.
            options={"require": ["exp", "sub"]},
        )
    except jwt.PyJWTError as e:
        raise HTTPException(status_code=401, detail=f"jwt_invalido: {e}")


def require_teoria(request: Request) -> dict:
    token = extract_jwt(request)
    claims = decode_jwt(token)
    roles = claims.get("roles") or []
    if "admin" not in roles and "teoria" not in roles:
        raise HTTPException(status_code=403, detail="permiso_denegado")
    claims["_token"] = token
    return claims


def require_admin(request: Request) -> dict:
    claims = require_teoria(request)
    if "admin" not in (claims.get("roles") or []):
        raise HTTPException(status_code=403, detail="solo_admin")
    return claims


# ── Paths ───────────────────────────────────────────────────────────────────

def normalize_url_path(url_path: str) -> str:
    """
    Devuelve una ruta 'estilo URL' absoluta, sin barras raras ni '..'.
    Es la que se guarda en ficheros_vistas y la que ve la SPA.
    """
    parts = [
        p for p in (url_path or "").replace("\\", "/").split("/")
        if p and p not in (".", "..")
    ]
    return "/" + "/".join(parts) if parts else "/"


def resolve_fs(url_path: str) -> Path:
    """Traduce ruta URL → ruta absoluta en disco, con jail sobre BASE_DIR."""
    url_path = normalize_url_path(url_path)
    parts = [p for p in url_path.split("/") if p]
    fs = (BASE_DIR / Path(*parts)).resolve() if parts else BASE_DIR
    try:
        fs.relative_to(BASE_DIR)
    except ValueError:
        raise HTTPException(status_code=403, detail="fuera_de_ficheros")
    return fs


def join_url(carpeta: str, nombre: str) -> str:
    carpeta = normalize_url_path(carpeta)
    return normalize_url_path(carpeta + "/" + nombre)


# ── PostgREST ───────────────────────────────────────────────────────────────

def _pg(token: str, name: str, payload: dict) -> httpx.Response | None:
    try:
        return httpx.post(
            f"{POSTGREST_URL}/rpc/{name}",
            json=payload,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            timeout=5.0,
        )
    except httpx.HTTPError as e:
        print(f"[teoria] PostgREST {name} error: {e}", flush=True)
        return None


def vistos_prefijo(token: str, prefijo: str) -> set[str]:
    r = _pg(token, "mis_ficheros_vistos", {"p_prefijo": prefijo})
    if r is None or r.status_code != 200:
        return set()
    try:
        return {row["ruta"] for row in r.json()}
    except Exception:
        return set()


def _asignaciones_carpetas(token: str) -> dict[str, dict]:
    """Mapa ruta → {oposicion_ids: [uuid...], oposicion_nombres: [str...]}
    tomado de la BD. Una carpeta puede pertenecer a varias oposiciones.
    """
    r = _pg(token, "listar_carpeta_oposiciones", {})
    if r is None or r.status_code != 200:
        return {}
    try:
        rows = r.json() or []
        out: dict[str, dict] = {}
        for row in rows:
            ids = row.get("oposicion_ids") or []
            nombres = row.get("oposicion_nombres") or []
            # Compatibilidad con la respuesta antigua (1-a-1): si viene
            # `oposicion_id` en singular, lo envolvemos en lista.
            if not ids and row.get("oposicion_id"):
                ids = [row.get("oposicion_id")]
                nombres = [row.get("oposicion_nombre") or ""]
            out[row["ruta"]] = {
                "oposicion_ids": [str(x) for x in ids],
                "oposicion_nombres": [str(x) for x in nombres],
            }
        return out
    except Exception:
        return {}


def _mis_oposiciones_ids(token: str) -> set[str]:
    r = _pg(token, "mis_oposiciones_ids", {})
    if r is None or r.status_code != 200:
        return set()
    try:
        return {str(x) for x in (r.json() or [])}
    except Exception:
        return set()


# ── Endpoints API ───────────────────────────────────────────────────────────

@app.get("/api/sesion")
def api_sesion(request: Request):
    claims = require_teoria(request)
    roles = claims.get("roles") or []
    # El JWT sólo contiene el user_id (claim 'sub'); el username lo pedimos
    # a PostgREST para poder mostrarlo en la cabecera.
    username = None
    r = _pg(claims["_token"], "mi_sesion", {})
    if r is not None and r.status_code == 200:
        try:
            username = r.json().get("username")
        except Exception:
            pass
    return {
        "user_id": claims.get("sub"),
        "username": username,
        "roles": roles,
        "puede_gestionar": "admin" in roles,
    }


@app.get("/api/listar")
def api_listar(request: Request, ruta: str = "/", oposicion_id: str | None = None):
    """
    Lista una carpeta. Si se pasa `oposicion_id`, filtra la raíz para
    mostrar SOLO carpetas asignadas a esa oposición (filtro estricto:
    las carpetas globales no aparecen cuando el usuario ha elegido
    una oposición). Sin oposicion_id, el alumno ve global + las
    carpetas de cualquiera de sus oposiciones; el admin ve todas.

    Una vez dentro de una carpeta asignada, no se vuelve a filtrar:
    el árbol interno se hereda.
    """
    claims = require_teoria(request)
    url_path = normalize_url_path(ruta)
    fs = resolve_fs(url_path)
    if not fs.exists() or not fs.is_dir():
        raise HTTPException(status_code=404, detail="carpeta_no_encontrada")

    try:
        entries = list(fs.iterdir())
    except PermissionError:
        raise HTTPException(status_code=403, detail="sin_permiso_lectura")

    dirs = sorted(
        (e for e in entries if e.is_dir() and not e.name.startswith(".")),
        key=lambda e: e.name.lower(),
    )
    files = sorted(
        (e for e in entries if e.is_file() and not e.name.startswith(".")),
        key=lambda e: e.name.lower(),
    )

    vistos = vistos_prefijo(claims["_token"], url_path)
    roles = claims.get("roles") or []
    es_admin = "admin" in roles

    # Cargamos asignaciones solo si estamos en la raíz (donde tiene sentido
    # filtrar) o si somos admin (para poder etiquetar cada carpeta con su
    # oposición). Fuera de la raíz no filtramos ni etiquetamos: no aporta.
    asignaciones = _asignaciones_carpetas(claims["_token"]) if url_path == "/" or es_admin else {}
    mis_ids = _mis_oposiciones_ids(claims["_token"]) if url_path == "/" and not es_admin else set()

    carpetas = []
    for d in dirs:
        ruta_d = join_url(url_path, d.name)
        try:
            n = sum(1 for _ in d.iterdir() if not _.name.startswith("."))
        except Exception:
            n = 0
        entry = {
            "nombre": d.name,
            "ruta": ruta_d,
            "num_elementos": n,
        }
        # Adjuntamos las oposiciones asignadas a la carpeta (0..N). El
        # frontend las pinta como badges y las usa para el picker.
        asig = asignaciones.get(ruta_d)
        if asig:
            entry["oposicion_ids"]     = asig.get("oposicion_ids", [])
            entry["oposicion_nombres"] = asig.get("oposicion_nombres", [])
        else:
            entry["oposicion_ids"]     = []
            entry["oposicion_nombres"] = []

        # Filtrado en la raíz.
        if url_path == "/":
            op_ids = set(entry["oposicion_ids"])
            if oposicion_id:
                # Filtro ESTRICTO (para todos los roles): si hay una
                # oposición seleccionada, solo aparecen las carpetas
                # explícitamente asignadas a ella. Las globales / de
                # otra oposición se ocultan.
                if str(oposicion_id) not in op_ids:
                    continue
            elif not es_admin:
                # Vista "todas mis oposiciones" del alumno: globales
                # siempre visibles; asignadas solo si comparten alguna
                # con el usuario.
                if op_ids and not (op_ids & mis_ids):
                    continue

        carpetas.append(entry)

    ficheros = []
    for f in files:
        ruta_f = join_url(url_path, f.name)
        st = f.stat()
        mime, _ = mimetypes.guess_type(f.name)
        ficheros.append({
            "nombre": f.name,
            "ruta": ruta_f,
            "size": st.st_size,
            "mime": mime,
            "modificado": st.st_mtime,
            "visto": ruta_f in vistos,
        })

    parts = [p for p in url_path.split("/") if p]
    breadcrumb = [{"ruta": "/", "nombre": "Inicio"}]
    acc = ""
    for p in parts:
        acc += "/" + p
        breadcrumb.append({"ruta": acc, "nombre": p})

    padre = None
    if url_path != "/":
        padre = "/" + "/".join(parts[:-1]) if len(parts) > 1 else "/"

    return {
        "ruta": url_path,
        "padre": padre,
        "breadcrumb": breadcrumb,
        "carpetas": carpetas,
        "ficheros": ficheros,
        "puede_gestionar": es_admin,
        "oposicion_id": oposicion_id,
    }


@app.get("/api/ver")
def api_ver(request: Request, ruta: str):
    require_teoria(request)
    url_path = normalize_url_path(ruta)
    fs = resolve_fs(url_path)
    if not fs.exists() or not fs.is_file():
        raise HTTPException(status_code=404)

    # NO se marca como visto automáticamente: el usuario decide con el
    # tick de la tarjeta si ya lo ha estudiado o no. Abrir un fichero
    # para echarle un vistazo no cuenta como "visto".

    mime, _ = mimetypes.guess_type(fs.name)
    return FileResponse(
        str(fs),
        media_type=mime or "application/octet-stream",
        filename=fs.name,
        # inline en el navegador cuando el mime sea previsualizable.
        headers={"Content-Disposition": f'inline; filename="{fs.name}"'},
    )


# ── Lectura y edición de markdown ──────────────────────────────────────────

# Límite de tamaño para servir/aceptar contenido de texto en JSON. Los
# markdown de apuntes rara vez superan unos pocos KB; con 2 MB va sobrado
# y evita que un fichero enorme (renombrado a .md) tumbe el navegador.
MAX_TEXTO_BYTES = 2 * 1024 * 1024
TEXTO_EXTS = {".md", ".markdown", ".txt"}


def _es_texto(nombre: str) -> bool:
    ext = os.path.splitext(nombre)[1].lower()
    return ext in TEXTO_EXTS


@app.get("/api/leer")
def api_leer(request: Request, ruta: str):
    """Devuelve el contenido de texto de un .md/.markdown/.txt para que la
    SPA pueda renderizarlo o editarlo. Se limita por extensión y tamaño."""
    require_teoria(request)
    url_path = normalize_url_path(ruta)
    fs = resolve_fs(url_path)
    if not fs.exists() or not fs.is_file():
        raise HTTPException(status_code=404, detail="fichero_no_encontrado")
    if not _es_texto(fs.name):
        raise HTTPException(status_code=415, detail="no_es_texto")
    if fs.stat().st_size > MAX_TEXTO_BYTES:
        raise HTTPException(status_code=413, detail="fichero_demasiado_grande")
    try:
        contenido = fs.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        raise HTTPException(status_code=415, detail="codificacion_no_utf8")
    return {"ruta": url_path, "nombre": fs.name, "contenido": contenido}


@app.post("/api/guardar")
def api_guardar(request: Request, body: dict):
    """Sobrescribe un fichero de texto ya existente. Solo admin."""
    require_admin(request)
    url_path = normalize_url_path(body.get("ruta", ""))
    contenido = body.get("contenido", "")
    if not isinstance(contenido, str):
        raise HTTPException(status_code=400, detail="contenido_invalido")
    if len(contenido.encode("utf-8")) > MAX_TEXTO_BYTES:
        raise HTTPException(status_code=413, detail="contenido_demasiado_grande")

    fs = resolve_fs(url_path)
    if not fs.exists() or not fs.is_file():
        raise HTTPException(status_code=404, detail="fichero_no_encontrado")
    if not _es_texto(fs.name):
        raise HTTPException(status_code=415, detail="no_es_texto")

    fs.write_text(contenido, encoding="utf-8")
    st = fs.stat()
    return {"ruta": url_path, "size": st.st_size, "modificado": st.st_mtime}


@app.post("/api/crear_md")
def api_crear_md(request: Request, body: dict):
    """Crea un fichero markdown vacío (o con contenido inicial) dentro de
    una carpeta. Solo admin. Añade la extensión .md si el nombre no la
    trae. Devuelve la ruta final y el nombre normalizado."""
    require_admin(request)
    padre = normalize_url_path(body.get("padre", "/"))
    nombre_raw = (body.get("nombre") or "").strip()
    nombre = Path(nombre_raw).name
    if not nombre or nombre.startswith("."):
        raise HTTPException(status_code=400, detail="nombre_invalido")

    ext = os.path.splitext(nombre)[1].lower()
    if ext not in TEXTO_EXTS:
        nombre = nombre + ".md"

    contenido = body.get("contenido") or f"# {os.path.splitext(nombre)[0]}\n\n"
    if not isinstance(contenido, str):
        raise HTTPException(status_code=400, detail="contenido_invalido")
    if len(contenido.encode("utf-8")) > MAX_TEXTO_BYTES:
        raise HTTPException(status_code=413, detail="contenido_demasiado_grande")

    padre_fs = resolve_fs(padre)
    if not padre_fs.exists() or not padre_fs.is_dir():
        raise HTTPException(status_code=404, detail="padre_no_existe")

    nombre = _nombre_unico(padre_fs, nombre)
    destino = padre_fs / nombre
    destino.write_text(contenido, encoding="utf-8")
    return {"ruta": join_url(padre, nombre), "nombre": nombre}


@app.post("/api/marcar_visto")
def api_marcar_visto(request: Request, body: dict):
    claims = require_teoria(request)
    # marcar_fichero_visto ahora devuelve { logros_desbloqueados: [...] }
    # cuando el marcado dispara la primera vista del documento.  Reenviamos
    # ese payload al frontend para pintar la notificación de logro.
    r = _pg(
        claims["_token"], "marcar_fichero_visto",
        {"p_ruta": normalize_url_path(body.get("ruta", ""))},
    )
    logros = []
    if r is not None and r.status_code == 200:
        try:
            data = r.json() or {}
            logros = data.get("logros_desbloqueados") or []
        except Exception:
            logros = []
    return {"ok": True, "logros_desbloqueados": logros}


@app.post("/api/marcar_no_visto")
def api_marcar_no_visto(request: Request, body: dict):
    claims = require_teoria(request)
    _pg(
        claims["_token"], "marcar_fichero_no_visto",
        {"p_ruta": normalize_url_path(body.get("ruta", ""))},
    )
    return {"ok": True}


# ── Endpoints de admin ─────────────────────────────────────────────────────

def _nombre_unico(carpeta: Path, nombre: str) -> str:
    base, ext = os.path.splitext(nombre)
    n = 1
    resultado = nombre
    while (carpeta / resultado).exists():
        resultado = f"{base}_{n}{ext}"
        n += 1
    return resultado


@app.post("/api/subir")
async def api_subir(
    request: Request,
    ruta: str = Form("/"),
    files: list[UploadFile] = File(...),
):
    require_admin(request)
    url_path = normalize_url_path(ruta)
    dest_dir = resolve_fs(url_path)
    if not dest_dir.exists() or not dest_dir.is_dir():
        raise HTTPException(status_code=404, detail="carpeta_destino_no_existe")

    subidos = []
    for f in files:
        nombre = Path(f.filename or "sin_nombre").name  # blinda contra '/'
        if not nombre or nombre.startswith("."):
            continue
        nombre = _nombre_unico(dest_dir, nombre)
        target = dest_dir / nombre
        with open(target, "wb") as out:
            shutil.copyfileobj(f.file, out)
        subidos.append({"nombre": nombre, "ruta": join_url(url_path, nombre)})
    return {"carpeta": url_path, "subidos": subidos}


@app.post("/api/carpeta")
def api_crear_carpeta(request: Request, body: dict):
    require_admin(request)
    padre = normalize_url_path(body.get("padre", "/"))
    nombre = Path((body.get("nombre") or "").strip()).name
    if not nombre or nombre.startswith("."):
        raise HTTPException(status_code=400, detail="nombre_invalido")

    padre_fs = resolve_fs(padre)
    if not padre_fs.exists() or not padre_fs.is_dir():
        raise HTTPException(status_code=404, detail="padre_no_existe")

    nueva = padre_fs / nombre
    if nueva.exists():
        raise HTTPException(status_code=409, detail="ya_existe")

    nueva.mkdir(parents=False, exist_ok=False)
    return {"ruta": join_url(padre, nombre)}


@app.post("/api/borrar")
def api_borrar(request: Request, body: dict):
    claims = require_admin(request)
    ruta = normalize_url_path(body.get("ruta", "/"))
    if ruta == "/":
        raise HTTPException(status_code=400, detail="no_puedes_borrar_la_raiz")

    fs = resolve_fs(ruta)
    if not fs.exists():
        raise HTTPException(status_code=404)

    if fs.is_dir():
        shutil.rmtree(fs)
    else:
        fs.unlink()

    _pg(claims["_token"], "borrar_ruta_vistas", {"p_ruta": ruta})
    return {"borrado": ruta}


@app.post("/api/mover")
def api_mover(request: Request, body: dict):
    claims = require_admin(request)
    origen = normalize_url_path(body.get("origen", ""))
    destino = normalize_url_path(body.get("destino", ""))
    if origen == "/" or destino == "/" or origen == destino:
        raise HTTPException(status_code=400, detail="ruta_invalida")

    src = resolve_fs(origen)
    dst = resolve_fs(destino)
    if not src.exists():
        raise HTTPException(status_code=404, detail="origen_no_existe")
    if dst.exists():
        raise HTTPException(status_code=409, detail="destino_ya_existe")

    dst.parent.mkdir(parents=True, exist_ok=True)
    src.rename(dst)
    _pg(
        claims["_token"], "renombrar_ruta_vistas",
        {"p_origen": origen, "p_destino": destino},
    )
    return {"origen": origen, "destino": destino}


@app.post("/api/borrar_lote")
def api_borrar_lote(request: Request, body: dict):
    """Borra varias rutas de una vez. Devuelve por ruta el resultado
    para que el frontend pueda avisar de los fallos parcial."""
    claims = require_admin(request)
    rutas = body.get("rutas") or []
    if not isinstance(rutas, list) or not rutas:
        raise HTTPException(status_code=400, detail="rutas_invalidas")

    borrados: list[str] = []
    errores: list[dict] = []
    for raw in rutas:
        try:
            ruta = normalize_url_path(str(raw))
            if ruta == "/":
                errores.append({"ruta": ruta, "error": "no_puedes_borrar_la_raiz"})
                continue
            fs = resolve_fs(ruta)
            if not fs.exists():
                errores.append({"ruta": ruta, "error": "no_existe"})
                continue
            if fs.is_dir():
                shutil.rmtree(fs)
            else:
                fs.unlink()
            _pg(claims["_token"], "borrar_ruta_vistas", {"p_ruta": ruta})
            borrados.append(ruta)
        except HTTPException as e:
            errores.append({"ruta": str(raw), "error": e.detail})
        except Exception as e:
            errores.append({"ruta": str(raw), "error": str(e)})
    return {"borrados": borrados, "errores": errores}


@app.post("/api/mover_lote")
def api_mover_lote(request: Request, body: dict):
    """Mueve varias rutas a la carpeta destino. Conserva el nombre de
    cada origen. Si ya existe algo con ese nombre, marca el error y
    continúa con el resto (no se sobrescribe)."""
    claims = require_admin(request)
    rutas = body.get("rutas") or []
    destino_padre = normalize_url_path(body.get("destino", "/"))
    if not isinstance(rutas, list) or not rutas:
        raise HTTPException(status_code=400, detail="rutas_invalidas")

    dst_dir = resolve_fs(destino_padre)
    if not dst_dir.exists() or not dst_dir.is_dir():
        raise HTTPException(status_code=404, detail="destino_no_existe")

    movidos: list[dict] = []
    errores: list[dict] = []
    for raw in rutas:
        try:
            origen = normalize_url_path(str(raw))
            if origen == "/":
                errores.append({"ruta": origen, "error": "ruta_invalida"})
                continue
            src = resolve_fs(origen)
            if not src.exists():
                errores.append({"ruta": origen, "error": "no_existe"})
                continue
            nombre = src.name
            destino = join_url(destino_padre, nombre)
            if origen == destino:
                # Ya está en el destino, nada que hacer.
                continue
            dst = dst_dir / nombre
            if dst.exists():
                errores.append({"ruta": origen, "error": "destino_ya_existe"})
                continue
            # Evita mover una carpeta dentro de sí misma o de un descendiente.
            try:
                dst.resolve().relative_to(src.resolve())
                errores.append({"ruta": origen, "error": "destino_dentro_de_origen"})
                continue
            except ValueError:
                pass
            src.rename(dst)
            _pg(
                claims["_token"], "renombrar_ruta_vistas",
                {"p_origen": origen, "p_destino": destino},
            )
            movidos.append({"origen": origen, "destino": destino})
        except HTTPException as e:
            errores.append({"ruta": str(raw), "error": e.detail})
        except Exception as e:
            errores.append({"ruta": str(raw), "error": str(e)})
    return {"movidos": movidos, "errores": errores, "destino": destino_padre}


@app.get("/api/arbol_carpetas")
def api_arbol_carpetas(request: Request):
    """Devuelve la lista plana de carpetas del árbol para el selector
    "Mover a…". Solo directorios (sin ficheros) y sin ocultos."""
    require_admin(request)
    rutas: list[str] = ["/"]
    for dirpath, dirnames, _files in os.walk(BASE_DIR):
        # Filtra ocultos in-place para no descender en ellos.
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for d in dirnames:
            full = Path(dirpath) / d
            try:
                rel = full.relative_to(BASE_DIR)
            except ValueError:
                continue
            rutas.append("/" + str(rel).replace("\\", "/"))
    return {"carpetas": rutas}


# ── Errores JSON ────────────────────────────────────────────────────────────

@app.exception_handler(HTTPException)
async def http_exc_handler(request: Request, exc: HTTPException):
    return JSONResponse({"error": exc.detail}, status_code=exc.status_code)


# ── SPA estática ────────────────────────────────────────────────────────────
# Va al final para no ensombrecer /api/*.
app.mount("/", StaticFiles(directory="site", html=True), name="spa")
