import os
import io
import json
import random
import sqlite3
import hashlib
import secrets
import zipfile
from math import ceil
from datetime import datetime
from flask import Flask, request, jsonify, send_from_directory, send_file

app = Flask(__name__, static_folder="static", static_url_path="/static")


def hash_password(password, salt=None):
    if salt is None:
        salt = secrets.token_hex(16)
    h = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), 200_000)
    return salt + ":" + h.hex()


def verify_password(password, stored):
    if ":" not in stored:
        return False
    salt = stored.split(":")[0]
    return hash_password(password, salt) == stored

DB_FILE = os.path.join("/app/bd", "bot.db")

FAILURES_TEST_SIZE = 40
TAMANO_PAGINA_TESTS = 20
TAMANO_TEST_FAVORITAS = 40
TAMANO_TEST_TEMPORAL = 40
PENALIZACION_FALLO = 1 / 3
PREGUNTAS_PARTE_1_SIMULACRO = 80
PUNTOS_ACIERTO_PARTE_2 = 4


def cargar_historico_desde_entorno(nombre_variable):
    valor = (os.getenv(nombre_variable) or "").strip()
    if not valor:
        return []
    try:
        datos = json.loads(valor)
    except json.JSONDecodeError:
        return []
    historico = []
    for item in datos:
        if not isinstance(item, (list, tuple)) or len(item) != 2:
            continue
        try:
            historico.append((float(item[0]), int(item[1])))
        except (TypeError, ValueError):
            continue
    return historico


HISTORICO_2024 = cargar_historico_desde_entorno("HISTORICO_2024")
HISTORICO_2022 = cargar_historico_desde_entorno("HISTORICO_2022")
PLAZAS_REFERENCIA_SIMULACRO = int(os.getenv("PLAZAS_REFERENCIA_SIMULACRO", "844"))
N_MAX_SIMULACRO = 160
E_MAX_SIMULACRO = 100
MIN_DIRECTA_SIMULACRO = N_MAX_SIMULACRO * 0.30


def cargar_lista_usuarios_desde_entorno(nombre_variable):
    valor = (os.getenv(nombre_variable) or "").strip()
    if not valor:
        return set()
    try:
        datos = json.loads(valor)
        if isinstance(datos, list):
            return {str(item).strip().lower() for item in datos if str(item).strip()}
    except json.JSONDecodeError:
        pass
    return {item.strip().lower() for item in valor.split(",") if item.strip()}


USUARIOS_GESTION_TESTS = cargar_lista_usuarios_desde_entorno("USUARIOS_GESTION_TESTS")


def _obtener_username_desde_user_id(cur, user_id):
    cur.execute("SELECT username FROM web_users WHERE user_id = ?", (user_id,))
    fila = cur.fetchone()
    return fila["username"] if fila else None


def usuario_tiene_permiso_gestion(user_id):
    if not user_id:
        return False
    with get_conn() as conn:
        cur = conn.cursor()
        username = _obtener_username_desde_user_id(cur, user_id)
    if username:
        username = username.strip().lower()
    return bool(username and username in USUARIOS_GESTION_TESTS)


def validar_permiso_gestion(user_id):
    if not user_id:
        return jsonify({"error": "user_id requerido"}), 400
    if not usuario_tiene_permiso_gestion(user_id):
        return jsonify({"error": "No tienes permisos para esta accion"}), 403
    return None


@app.route("/api/auth/permisos")
def permisos_usuario():
    user_id = request.args.get("user_id", type=int)
    if not user_id:
        return jsonify({"error": "user_id requerido"}), 400
    return jsonify({"puede_gestionar": usuario_tiene_permiso_gestion(user_id)})


# ─────────────── DB ───────────────
def get_conn():
    conn = sqlite3.connect(DB_FILE)
    conn.row_factory = sqlite3.Row
    return conn


def dict_row(row):
    if row is None:
        return None
    return dict(row)


def dict_rows(rows):
    return [dict(r) for r in rows]


# ─────────────── Simulacro helpers ───────────────
def estimar_posicion_en_historico(puntuacion, historico):
    if not historico:
        return None
    if puntuacion >= historico[0][0]:
        return 1
    for indice in range(len(historico) - 1):
        puntuacion_actual, posicion_actual = historico[indice]
        puntuacion_siguiente, posicion_siguiente = historico[indice + 1]
        if puntuacion >= puntuacion_siguiente:
            if puntuacion_actual == puntuacion_siguiente:
                return posicion_siguiente
            fraccion = (puntuacion_actual - puntuacion) / (puntuacion_actual - puntuacion_siguiente)
            return round(posicion_actual + fraccion * (posicion_siguiente - posicion_actual))
    return historico[-1][1] + 1


def nota_corte_para_plazas(plazas, historico):
    if not historico:
        return None
    for puntuacion, posicion in historico:
        if posicion >= plazas:
            return puntuacion
    return historico[-1][0]


def calcular_nota_transformada_simulacro(puntuacion_directa, nota_corte_directa, total_directa_maxima, escala_maxima):
    if total_directa_maxima <= 0 or nota_corte_directa <= 0 or escala_maxima <= 0:
        return 0.0
    puntuacion_directa = max(0.0, puntuacion_directa)
    if puntuacion_directa < nota_corte_directa:
        return (escala_maxima / 2) * (puntuacion_directa / nota_corte_directa)
    if total_directa_maxima <= nota_corte_directa:
        return escala_maxima / 2
    return (escala_maxima / 2) * (
        1 + (puntuacion_directa - nota_corte_directa) / (total_directa_maxima - nota_corte_directa)
    )


def calcular_resultado_simulacro_tai(aciertos_p1, errores_p1, aciertos_p2, errores_p2,
                                     total_p1=80, total_p2=20):
    directa_p1 = max(0.0, aciertos_p1 - PENALIZACION_FALLO * errores_p1)
    directa_p2 = max(0.0, PUNTOS_ACIERTO_PARTE_2 * aciertos_p2 - PUNTOS_ACIERTO_PARTE_2 * PENALIZACION_FALLO * errores_p2)
    directa_total = directa_p1 + directa_p2

    corte_2024 = nota_corte_para_plazas(PLAZAS_REFERENCIA_SIMULACRO, HISTORICO_2024)
    corte_2022 = nota_corte_para_plazas(PLAZAS_REFERENCIA_SIMULACRO, HISTORICO_2022)

    cortes = [c for c in [corte_2024, corte_2022] if c is not None]
    if cortes:
        corte_optimista = max(MIN_DIRECTA_SIMULACRO, min(cortes))
        corte_pesimista = max(MIN_DIRECTA_SIMULACRO, max(cortes))
    else:
        corte_optimista = MIN_DIRECTA_SIMULACRO
        corte_pesimista = MIN_DIRECTA_SIMULACRO
    corte_media = (corte_optimista + corte_pesimista) / 2

    tps_optimista = calcular_nota_transformada_simulacro(directa_total, corte_optimista, N_MAX_SIMULACRO, E_MAX_SIMULACRO)
    tps_medio = calcular_nota_transformada_simulacro(directa_total, corte_media, N_MAX_SIMULACRO, E_MAX_SIMULACRO)
    tps_pesimista = calcular_nota_transformada_simulacro(directa_total, corte_pesimista, N_MAX_SIMULACRO, E_MAX_SIMULACRO)

    return {
        "directa_p1": round(directa_p1, 2),
        "directa_p2": round(directa_p2, 2),
        "directa_total": round(directa_total, 2),
        "blancos_p1": total_p1 - aciertos_p1 - errores_p1,
        "blancos_p2": total_p2 - aciertos_p2 - errores_p2,
        "corte_2024": corte_2024,
        "corte_2022": corte_2022,
        "corte_optimista": round(corte_optimista, 2),
        "corte_pesimista": round(corte_pesimista, 2),
        "corte_media": round(corte_media, 2),
        "tps_optimista": round(tps_optimista, 2),
        "tps_medio": round(tps_medio, 2),
        "tps_pesimista": round(tps_pesimista, 2),
        "aprobado_optimista": directa_total >= corte_optimista,
        "aprobado_pesimista": directa_total >= corte_pesimista,
        "supera_minimo_30": directa_total >= MIN_DIRECTA_SIMULACRO,
        "pos_2024": estimar_posicion_en_historico(directa_total, HISTORICO_2024),
        "pos_2022": estimar_posicion_en_historico(directa_total, HISTORICO_2022),
    }


# ─────────────── Serve SPA ───────────────
@app.route("/")
def index():
    return send_from_directory("static", "index.html")


# ─────────────── DB init (web_users table) ───────────────
def init_web_db():
    with get_conn() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS web_users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                username TEXT UNIQUE NOT NULL,
                password_hash TEXT NOT NULL,
                user_id INTEGER NOT NULL,
                created_at TEXT NOT NULL,
                FOREIGN KEY (user_id) REFERENCES users(id)
            )
        """)
        conn.commit()

init_web_db()


# ─────────────── Auth / User ───────────────
@app.route("/api/auth/register", methods=["POST"])
def register():
    data = request.get_json(force=True)
    username = (data.get("username") or "").strip()
    password = (data.get("password") or "")
    chat_id = (data.get("chat_id") or "").strip()

    if not username or not password:
        return jsonify({"error": "Usuario y contrasenya requeridos"}), 400
    if len(username) < 3:
        return jsonify({"error": "El usuario debe tener al menos 3 caracteres"}), 400
    if len(password) < 4:
        return jsonify({"error": "La contrasenya debe tener al menos 4 caracteres"}), 400

    with get_conn() as conn:
        cur = conn.cursor()

        # Check if username already taken
        cur.execute("SELECT 1 FROM web_users WHERE username = ?", (username,))
        if cur.fetchone():
            return jsonify({"error": "Ese nombre de usuario ya existe"}), 409

        now = datetime.utcnow().isoformat()

        if chat_id:
            # Link to existing Telegram user
            cur.execute("SELECT id FROM users WHERE chat_id = ?", (chat_id,))
            row = cur.fetchone()
            if not row:
                return jsonify({"error": "No se encontro un usuario con ese chat_id de Telegram"}), 404
            user_id = row["id"]
            # Check if this chat_id is already linked
            cur.execute("SELECT 1 FROM web_users WHERE user_id = ?", (user_id,))
            if cur.fetchone():
                return jsonify({"error": "Ese chat_id ya esta vinculado a otra cuenta"}), 409
        else:
            # Create new user entry with a generated chat_id
            generated_chat_id = "web_" + secrets.token_hex(8)
            cur.execute("INSERT INTO users (chat_id, created_at) VALUES (?, ?)", (generated_chat_id, now))
            user_id = cur.lastrowid

        password_hash = hash_password(password)
        cur.execute(
            "INSERT INTO web_users (username, password_hash, user_id, created_at) VALUES (?, ?, ?, ?)",
            (username, password_hash, user_id, now),
        )
        conn.commit()

    return jsonify({
        "user_id": user_id,
        "username": username,
        "puede_gestionar": usuario_tiene_permiso_gestion(user_id),
    })


@app.route("/api/auth/login", methods=["POST"])
def login():
    data = request.get_json(force=True)
    username = (data.get("username") or "").strip()
    password = (data.get("password") or "")

    if not username or not password:
        return jsonify({"error": "Usuario y contrasenya requeridos"}), 400

    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id, password_hash, user_id FROM web_users WHERE username = ?", (username,))
        row = cur.fetchone()
        if not row or not verify_password(password, row["password_hash"]):
            return jsonify({"error": "Usuario o contrasenya incorrectos"}), 401

    return jsonify({
        "user_id": row["user_id"],
        "username": username,
        "puede_gestionar": usuario_tiene_permiso_gestion(row["user_id"]),
    })


# ─────────────── Tests (quizzes) ───────────────
@app.route("/api/tests")
def listar_tests():
    page = max(1, request.args.get("page", 1, type=int))
    user_id = request.args.get("user_id", type=int)
    offset = (page - 1) * TAMANO_PAGINA_TESTS
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT COUNT(*) AS total FROM quizzes")
        total = cur.fetchone()["total"]
        cur.execute("""
            SELECT q.id, q.title, q.description, COUNT(que.id) AS total_preguntas
            FROM quizzes q
            LEFT JOIN questions que ON que.quiz_id = q.id
            GROUP BY q.id ORDER BY q.id DESC
            LIMIT ? OFFSET ?
        """, (TAMANO_PAGINA_TESTS, offset))
        tests = dict_rows(cur.fetchall())

        favoritos = set()
        realizados = set()
        conteo_intentos = {}
        if user_id:
            cur.execute("SELECT quiz_id FROM tests_favoritos WHERE user_id = ?", (user_id,))
            favoritos = {r["quiz_id"] for r in cur.fetchall()}
            cur.execute("""
                SELECT DISTINCT quiz_id FROM attempts
                WHERE user_id = ? AND attempt_type = 'quiz' AND finished_at IS NOT NULL AND quiz_id IS NOT NULL
            """, (user_id,))
            realizados = {r["quiz_id"] for r in cur.fetchall()}
            if tests:
                quiz_ids = [t["id"] for t in tests]
                placeholders = ",".join("?" for _ in quiz_ids)
                cur.execute(f"""
                    SELECT quiz_id, COUNT(*) AS total_intentos FROM attempts
                    WHERE user_id = ? AND quiz_id IN ({placeholders}) AND finished_at IS NOT NULL
                    GROUP BY quiz_id
                """, [user_id, *quiz_ids])
                conteo_intentos = {r["quiz_id"]: r["total_intentos"] for r in cur.fetchall()}

    for t in tests:
        t["es_favorito"] = t["id"] in favoritos
        t["realizado"] = t["id"] in realizados
        t["intentos"] = conteo_intentos.get(t["id"], 0)

    return jsonify({
        "tests": tests,
        "total": total,
        "page": page,
        "pages": ceil(total / TAMANO_PAGINA_TESTS) if total else 1,
    })


@app.route("/api/tests/favoritos")
def listar_tests_favoritos():
    user_id = request.args.get("user_id", type=int)
    if not user_id:
        return jsonify({"error": "user_id requerido"}), 400
    page = max(1, request.args.get("page", 1, type=int))
    offset = (page - 1) * TAMANO_PAGINA_TESTS
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT COUNT(*) AS total FROM tests_favoritos WHERE user_id = ?", (user_id,))
        total = cur.fetchone()["total"]
        cur.execute("""
            SELECT q.id, q.title, q.description, COUNT(que.id) AS total_preguntas
            FROM tests_favoritos tf
            JOIN quizzes q ON q.id = tf.quiz_id
            LEFT JOIN questions que ON que.quiz_id = q.id
            WHERE tf.user_id = ?
            GROUP BY q.id ORDER BY tf.created_at DESC
            LIMIT ? OFFSET ?
        """, (user_id, TAMANO_PAGINA_TESTS, offset))
        tests = dict_rows(cur.fetchall())
    for t in tests:
        t["es_favorito"] = True
    return jsonify({
        "tests": tests,
        "total": total,
        "page": page,
        "pages": ceil(total / TAMANO_PAGINA_TESTS) if total else 1,
    })


@app.route("/api/tests/<int:quiz_id>/favorito", methods=["POST"])
def toggle_favorito_test(quiz_id):
    data = request.get_json(force=True)
    user_id = data.get("user_id")
    quiz_id_param = quiz_id
    if not user_id:
        return jsonify({"error": "user_id requerido"}), 400
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT 1 FROM tests_favoritos WHERE user_id = ? AND quiz_id = ?", (user_id, quiz_id_param))
        if cur.fetchone():
            cur.execute("DELETE FROM tests_favoritos WHERE user_id = ? AND quiz_id = ?", (user_id, quiz_id_param))
            conn.commit()
            return jsonify({"es_favorito": False})
        now = datetime.utcnow().isoformat()
        cur.execute("INSERT INTO tests_favoritos (user_id, quiz_id, created_at) VALUES (?, ?, ?) ON CONFLICT DO NOTHING",
                     (user_id, quiz_id_param, now))
        conn.commit()
        return jsonify({"es_favorito": True})


@app.route("/api/tests/<int:quiz_id>/questions")
def get_test_questions(quiz_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT title, description FROM quizzes WHERE id = ?", (quiz_id,))
        quiz = dict_row(cur.fetchone())
        if not quiz:
            return jsonify({"error": "Test no encontrado"}), 404
        cur.execute("SELECT id, text, explicacion FROM questions WHERE quiz_id = ?", (quiz_id,))
        questions = []
        for row in cur.fetchall():
            cur.execute("SELECT text, position FROM options WHERE question_id = ? ORDER BY position ASC", (row["id"],))
            options = [o["text"] for o in cur.fetchall()]
            if not options:
                continue
            questions.append({
                "id": row["id"],
                "text": row["text"],
                "explicacion": row["explicacion"],
                "options": options,
                "correct_index": 0,
            })
    return jsonify({"quiz": quiz, "questions": questions})


# ─────────────── Upload tests ───────────────
@app.route("/api/tests/upload", methods=["POST"])
def upload_tests():
    user_id = request.form.get("user_id", type=int)
    error_permiso = validar_permiso_gestion(user_id)
    if error_permiso:
        return error_permiso

    file = request.files.get("file")
    if not file:
        return jsonify({"error": "No se ha enviado archivo"}), 400

    filename = file.filename or ""
    created = []

    if filename.lower().endswith(".zip"):
        try:
            zip_data = io.BytesIO(file.read())
            with zipfile.ZipFile(zip_data) as zf:
                for name in zf.namelist():
                    if not name.lower().endswith(".json"):
                        continue
                    with zf.open(name) as f:
                        try:
                            payload = json.loads(f.read().decode("utf-8"))
                        except (json.JSONDecodeError, UnicodeDecodeError):
                            continue
                        quiz_id = _create_quiz_from_payload(payload, name)
                        if quiz_id:
                            created.append(quiz_id)
        except zipfile.BadZipFile:
            return jsonify({"error": "Archivo ZIP no valido"}), 400
    elif filename.lower().endswith(".json"):
        try:
            payload = json.loads(file.read().decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return jsonify({"error": "JSON no valido"}), 400
        quiz_id = _create_quiz_from_payload(payload, filename)
        if quiz_id:
            created.append(quiz_id)
    else:
        return jsonify({"error": "Formato no soportado. Usa .json o .zip"}), 400

    return jsonify({"created": created, "count": len(created)})


def _create_quiz_from_payload(payload, filename=""):
    if isinstance(payload, list):
        preguntas = payload
        titulo = os.path.splitext(os.path.basename(filename))[0] or "Test"
        descripcion = None
    elif isinstance(payload, dict):
        preguntas = payload.get("preguntas", [])
        titulo = payload.get("titulo") or os.path.splitext(os.path.basename(filename))[0] or "Test"
        descripcion = payload.get("descripcion")
    else:
        return None

    if not preguntas:
        return None

    now = datetime.utcnow().isoformat()
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("INSERT INTO quizzes (title, description, created_at) VALUES (?, ?, ?)",
                     (titulo, descripcion, now))
        quiz_id = cur.lastrowid
        for p in preguntas:
            texto = (p.get("pregunta") or "").strip()
            explicacion = (p.get("explicacion") or "").strip() or None
            opciones = p.get("opciones") or []
            bloque = p.get("bloque")
            tema = p.get("tema")
            if not texto or len(opciones) < 2:
                continue
            cur.execute("INSERT INTO questions (quiz_id, text, explicacion, bloque, tema) VALUES (?, ?, ?, ?, ?)",
                         (quiz_id, texto, explicacion, bloque, tema))
            q_id = cur.lastrowid
            for idx, opt in enumerate(opciones):
                cur.execute("INSERT INTO options (question_id, text, position) VALUES (?, ?, ?)",
                             (q_id, str(opt).strip(), idx))
        conn.commit()
        return quiz_id


# ─────────────── Delete test ───────────────
@app.route("/api/tests/<int:quiz_id>", methods=["DELETE"])
def delete_test(quiz_id):
    user_id = request.args.get("user_id", type=int)
    error_permiso = validar_permiso_gestion(user_id)
    if error_permiso:
        return error_permiso

    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT 1 FROM quizzes WHERE id = ?", (quiz_id,))
        if not cur.fetchone():
            return jsonify({"error": "Test no encontrado"}), 404

        cur.execute("DELETE FROM tests_favoritos WHERE quiz_id = ?", (quiz_id,))
        cur.execute("DELETE FROM simulacros WHERE quiz_id = ?", (quiz_id,))
        cur.execute("SELECT id FROM questions WHERE quiz_id = ?", (quiz_id,))
        q_ids = [r["id"] for r in cur.fetchall()]
        if q_ids:
            ph = ",".join("?" for _ in q_ids)
            cur.execute(f"DELETE FROM failures WHERE question_id IN ({ph})", q_ids)
            cur.execute(f"DELETE FROM favorites WHERE question_id IN ({ph})", q_ids)
            cur.execute(f"DELETE FROM options WHERE question_id IN ({ph})", q_ids)
            cur.execute(f"DELETE FROM attempt_items WHERE question_id IN ({ph})", q_ids)
            cur.execute(f"DELETE FROM questions WHERE id IN ({ph})", q_ids)
        cur.execute("SELECT id FROM attempts WHERE quiz_id = ?", (quiz_id,))
        a_ids = [r["id"] for r in cur.fetchall()]
        if a_ids:
            ph = ",".join("?" for _ in a_ids)
            cur.execute(f"DELETE FROM attempt_items WHERE attempt_id IN ({ph})", a_ids)
            cur.execute(f"DELETE FROM tests_temporales WHERE attempt_id IN ({ph})", a_ids)
            cur.execute(f"DELETE FROM attempts WHERE id IN ({ph})", a_ids)
        cur.execute("DELETE FROM quizzes WHERE id = ?", (quiz_id,))
        conn.commit()
    return jsonify({"ok": True})


# ─────────────── Download test ───────────────
@app.route("/api/tests/<int:quiz_id>/download")
def download_test(quiz_id):
    user_id = request.args.get("user_id", type=int)
    error_permiso = validar_permiso_gestion(user_id)
    if error_permiso:
        return error_permiso

    data = _get_test_as_json(quiz_id)
    if not data:
        return jsonify({"error": "Test no encontrado"}), 404
    filename = _normalize_filename(data.get("titulo", "test")) + ".json"
    buf = io.BytesIO(json.dumps(data, ensure_ascii=False, indent=2).encode("utf-8"))
    buf.seek(0)
    return send_file(buf, mimetype="application/json", as_attachment=True, download_name=filename)


@app.route("/api/tests/download-all")
def download_all_tests():
    user_id = request.args.get("user_id", type=int)
    error_permiso = validar_permiso_gestion(user_id)
    if error_permiso:
        return error_permiso

    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id FROM quizzes ORDER BY id")
        quiz_ids = [r["id"] for r in cur.fetchall()]
    if not quiz_ids:
        return jsonify({"error": "No hay tests"}), 404

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for qid in quiz_ids:
            data = _get_test_as_json(qid)
            if not data:
                continue
            fname = _normalize_filename(data.get("titulo", "test")) + f"_{qid}.json"
            zf.writestr(fname, json.dumps(data, ensure_ascii=False, indent=2))
    buf.seek(0)
    return send_file(buf, mimetype="application/zip", as_attachment=True, download_name="tests.zip")


def _get_test_as_json(quiz_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT title, description FROM quizzes WHERE id = ?", (quiz_id,))
        quiz = cur.fetchone()
        if not quiz:
            return None
        cur.execute("SELECT id, text, explicacion, bloque, tema FROM questions WHERE quiz_id = ? ORDER BY id", (quiz_id,))
        preguntas = []
        for f in cur.fetchall():
            cur.execute("SELECT text FROM options WHERE question_id = ? ORDER BY position ASC", (f["id"],))
            opciones = [i["text"] for i in cur.fetchall()]
            if len(opciones) < 2:
                continue
            preguntas.append({
                "pregunta": f["text"], "opciones": opciones,
                "bloque": f["bloque"], "tema": f["tema"], "explicacion": f["explicacion"],
            })
    return {"titulo": quiz["title"], "descripcion": quiz["description"], "preguntas": preguntas}


def _normalize_filename(titulo):
    base = "".join(c if c.isalnum() else "_" for c in (titulo or "test"))
    return (base.strip("_") or "test").lower()


# ─────────────── Attempts (test taking) ───────────────
@app.route("/api/attempts/start", methods=["POST"])
def start_attempt():
    data = request.get_json(force=True)
    user_id = data.get("user_id")
    quiz_id = data.get("quiz_id")
    attempt_type = data.get("attempt_type", "quiz")
    if not user_id:
        return jsonify({"error": "user_id requerido"}), 400

    now = datetime.utcnow().isoformat()
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("INSERT INTO attempts (user_id, quiz_id, attempt_type, started_at) VALUES (?, ?, ?, ?)",
                     (user_id, quiz_id, attempt_type, now))
        conn.commit()
        attempt_id = cur.lastrowid
    return jsonify({"attempt_id": attempt_id})


@app.route("/api/attempts/<int:attempt_id>/answer", methods=["POST"])
def answer_question(attempt_id):
    data = request.get_json(force=True)
    question_id = data.get("question_id")
    selected_option = data.get("selected_option", "")
    is_correct = data.get("is_correct", False)
    user_id = data.get("user_id")

    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("INSERT INTO attempt_items (attempt_id, question_id, selected_option, is_correct) VALUES (?, ?, ?, ?)",
                     (attempt_id, question_id, selected_option, int(is_correct)))
        conn.commit()

    if user_id and question_id:
        _record_failure_or_clear(user_id, question_id, is_correct)

    return jsonify({"ok": True})


def _record_failure_or_clear(user_id, question_id, is_correct):
    with get_conn() as conn:
        cur = conn.cursor()
        if is_correct:
            cur.execute("DELETE FROM failures WHERE user_id = ? AND question_id = ?", (user_id, question_id))
        else:
            now = datetime.utcnow().isoformat()
            cur.execute("""
                INSERT INTO failures (user_id, question_id, fail_count, last_failed_at)
                VALUES (?, ?, 1, ?)
                ON CONFLICT(user_id, question_id)
                DO UPDATE SET fail_count = fail_count + 1, last_failed_at = excluded.last_failed_at
            """, (user_id, question_id, now))
        conn.commit()


@app.route("/api/attempts/<int:attempt_id>/finish", methods=["POST"])
def finish_attempt(attempt_id):
    data = request.get_json(force=True)
    correct = data.get("correct", 0)
    wrong = data.get("wrong", 0)
    now = datetime.utcnow().isoformat()
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("UPDATE attempts SET finished_at = ?, correct = ?, wrong = ? WHERE id = ?",
                     (now, correct, wrong, attempt_id))
        cur.execute("DELETE FROM tests_temporales WHERE attempt_id = ?", (attempt_id,))
        conn.commit()
    return jsonify({"ok": True})


# ─────────────── Favorites (questions) ───────────────
@app.route("/api/favorites/toggle", methods=["POST"])
def toggle_favorite_question():
    data = request.get_json(force=True)
    user_id = data.get("user_id")
    question_id = data.get("question_id")
    if not user_id or not question_id:
        return jsonify({"error": "user_id y question_id requeridos"}), 400
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT 1 FROM favorites WHERE user_id = ? AND question_id = ?", (user_id, question_id))
        if cur.fetchone():
            cur.execute("DELETE FROM favorites WHERE user_id = ? AND question_id = ?", (user_id, question_id))
            conn.commit()
            return jsonify({"es_favorita": False})
        now = datetime.utcnow().isoformat()
        cur.execute("INSERT INTO favorites (user_id, question_id, created_at) VALUES (?, ?, ?) ON CONFLICT DO NOTHING",
                     (user_id, question_id, now))
        conn.commit()
        return jsonify({"es_favorita": True})


@app.route("/api/favorites/questions")
def get_favorite_questions():
    user_id = request.args.get("user_id", type=int)
    if not user_id:
        return jsonify({"error": "user_id requerido"}), 400
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT q.id, q.text, q.explicacion FROM favorites f
            JOIN questions q ON q.id = f.question_id
            WHERE f.user_id = ? ORDER BY f.created_at DESC LIMIT ?
        """, (user_id, TAMANO_TEST_FAVORITAS))
        questions = []
        for row in cur.fetchall():
            cur.execute("SELECT text, position FROM options WHERE question_id = ? ORDER BY position ASC", (row["id"],))
            options = [o["text"] for o in cur.fetchall()]
            if not options:
                continue
            questions.append({
                "id": row["id"], "text": row["text"], "explicacion": row["explicacion"],
                "options": options, "correct_index": 0,
            })
    return jsonify({"questions": questions})


@app.route("/api/favorites/check")
def check_favorites():
    user_id = request.args.get("user_id", type=int)
    if not user_id:
        return jsonify({"error": "user_id requerido"}), 400
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT question_id FROM favorites WHERE user_id = ?", (user_id,))
        ids = [r["question_id"] for r in cur.fetchall()]
    return jsonify({"question_ids": ids})


# ─────────────── Failures test ───────────────
@app.route("/api/failures/questions")
def get_failure_questions():
    user_id = request.args.get("user_id", type=int)
    if not user_id:
        return jsonify({"error": "user_id requerido"}), 400
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT q.id, q.text, q.explicacion FROM failures f
            JOIN questions q ON q.id = f.question_id
            WHERE f.user_id = ? ORDER BY f.last_failed_at DESC LIMIT ?
        """, (user_id, FAILURES_TEST_SIZE))
        questions = []
        for row in cur.fetchall():
            cur.execute("SELECT text, position FROM options WHERE question_id = ? ORDER BY position ASC", (row["id"],))
            options = [o["text"] for o in cur.fetchall()]
            if not options:
                continue
            questions.append({
                "id": row["id"], "text": row["text"], "explicacion": row["explicacion"],
                "options": options, "correct_index": 0,
            })
    return jsonify({"questions": questions})


# ─────────────── Progress ───────────────
@app.route("/api/progress")
def get_progress():
    user_id = request.args.get("user_id", type=int)
    if not user_id:
        return jsonify({"error": "user_id requerido"}), 400

    with get_conn() as conn:
        cur = conn.cursor()

        # General stats
        cur.execute("""
            SELECT COALESCE(SUM(correct),0) AS total_correct,
                   COALESCE(SUM(wrong),0) AS total_wrong,
                   COUNT(*) AS total_attempts
            FROM attempts WHERE user_id = ?
        """, (user_id,))
        stats = dict_row(cur.fetchone())

        cur.execute("SELECT COUNT(*) AS n FROM failures WHERE user_id = ?", (user_id,))
        stats["preguntas_falladas"] = cur.fetchone()["n"]

        cur.execute("SELECT COUNT(*) AS n FROM favorites WHERE user_id = ?", (user_id,))
        stats["preguntas_favoritas"] = cur.fetchone()["n"]

        # Today
        cur.execute("""
            SELECT COUNT(ai.id) AS total FROM attempt_items ai
            JOIN attempts a ON a.id = ai.attempt_id
            WHERE a.user_id = ? AND date(a.started_at) = date('now')
        """, (user_id,))
        stats["respondidas_hoy"] = cur.fetchone()["total"]

        # Per-test progress (last attempt per quiz)
        cur.execute("""
            SELECT a.correct, a.wrong FROM attempts a
            JOIN (
                SELECT quiz_id, MAX(id) AS ultimo_id FROM attempts
                WHERE user_id = ? AND attempt_type = 'quiz' AND finished_at IS NOT NULL
                GROUP BY quiz_id
            ) ult ON ult.ultimo_id = a.id
        """, (user_id,))
        filas = cur.fetchall()
        tc = sum(f["correct"] for f in filas)
        tw = sum(f["wrong"] for f in filas)
        total = tc + tw
        nota_general = max((tc - PENALIZACION_FALLO * tw) / total * 10, 0) if total else 0
        stats["nota_general"] = round(nota_general, 2)

        # Per-test breakdown
        cur.execute("""
            SELECT q.id AS quiz_id, q.title, a.correct, a.wrong, a.started_at
            FROM attempts a JOIN quizzes q ON q.id = a.quiz_id
            WHERE a.user_id = ? AND a.attempt_type = 'quiz' AND a.finished_at IS NOT NULL
            ORDER BY q.id, a.started_at
        """, (user_id,))
        por_test = {}
        for f in cur.fetchall():
            qid = f["quiz_id"]
            por_test.setdefault(qid, {"quiz_id": qid, "titulo": f["title"], "intentos": []})
            c, w = f["correct"], f["wrong"]
            t = c + w
            nota = max((c - PENALIZACION_FALLO * w) / t * 10, 0) if t else 0
            por_test[qid]["intentos"].append({"correct": c, "wrong": w, "nota": round(nota, 2)})
        stats["por_test"] = list(por_test.values())

    return jsonify(stats)


# ─────────────── Simulacros ───────────────
@app.route("/api/simulacros")
def listar_simulacros():
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT s.id, s.nombre, s.quiz_id, s.nota_corte_directa, s.escala_maxima, q.title AS test_titulo
            FROM simulacros s JOIN quizzes q ON q.id = s.quiz_id ORDER BY s.id DESC
        """)
        return jsonify({"simulacros": dict_rows(cur.fetchall())})


@app.route("/api/simulacros", methods=["POST"])
def crear_simulacro():
    data = request.get_json(force=True)
    nombre = (data.get("nombre") or "").strip()
    quiz_id = data.get("quiz_id")
    nota_corte = data.get("nota_corte_directa")
    escala = data.get("escala_maxima")
    if not nombre or not quiz_id or nota_corte is None or escala is None:
        return jsonify({"error": "Faltan campos requeridos"}), 400
    now = datetime.utcnow().isoformat()
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("INSERT INTO simulacros (nombre, quiz_id, nota_corte_directa, escala_maxima, created_at) VALUES (?,?,?,?,?)",
                     (nombre, quiz_id, float(nota_corte), float(escala), now))
        conn.commit()
        return jsonify({"id": cur.lastrowid})


@app.route("/api/simulacros/<int:sim_id>", methods=["DELETE"])
def eliminar_simulacro(sim_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("DELETE FROM simulacros WHERE id = ?", (sim_id,))
        conn.commit()
        return jsonify({"ok": cur.rowcount > 0})


@app.route("/api/simulacros/<int:sim_id>/start", methods=["POST"])
def start_simulacro(sim_id):
    data = request.get_json(force=True)
    user_id = data.get("user_id")
    if not user_id:
        return jsonify({"error": "user_id requerido"}), 400

    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT s.id, s.nombre, s.quiz_id, s.nota_corte_directa, s.escala_maxima
            FROM simulacros s WHERE s.id = ?
        """, (sim_id,))
        sim = dict_row(cur.fetchone())
        if not sim:
            return jsonify({"error": "Simulacro no encontrado"}), 404

        cur.execute("SELECT id, text, explicacion FROM questions WHERE quiz_id = ?", (sim["quiz_id"],))
        questions = []
        for row in cur.fetchall():
            cur.execute("SELECT text, position FROM options WHERE question_id = ? ORDER BY position ASC", (row["id"],))
            options = [o["text"] for o in cur.fetchall()]
            if not options:
                continue
            questions.append({
                "id": row["id"], "text": row["text"], "explicacion": row["explicacion"],
                "options": options, "correct_index": 0,
            })

    return jsonify({"simulacro": sim, "questions": questions})


@app.route("/api/simulacros/calculate", methods=["POST"])
def calculate_simulacro():
    data = request.get_json(force=True)
    result = calcular_resultado_simulacro_tai(
        aciertos_p1=data.get("aciertos_p1", 0),
        errores_p1=data.get("errores_p1", 0),
        aciertos_p2=data.get("aciertos_p2", 0),
        errores_p2=data.get("errores_p2", 0),
        total_p1=data.get("total_p1", 80),
        total_p2=data.get("total_p2", 20),
    )
    return jsonify(result)


# ─────────────── DB download ───────────────
@app.route("/api/db/download")
def download_db():
    user_id = request.args.get("user_id", type=int)
    error_permiso = validar_permiso_gestion(user_id)
    if error_permiso:
        return error_permiso

    db_dir = os.path.dirname(DB_FILE)
    db_name = os.path.basename(DB_FILE)
    return send_from_directory(db_dir, db_name, as_attachment=True, download_name="bot.db")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
