import io
import os
import json
import random
import sqlite3
import threading
import zipfile
from math import ceil
from datetime import datetime
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote, unquote, urlparse
from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import (
    ApplicationBuilder,
    CommandHandler,
    CallbackQueryHandler,
    MessageHandler,
    ContextTypes,
    filters,
)

RUTA_DATOS = os.getenv("RUTA_DATOS", os.getenv("DATA_DIR", "users"))
DB_FILE = os.path.join(RUTA_DATOS, "bot.db")
RUTA_ARCHIVOS_PUBLICOS = os.getenv(
    "RUTA_ARCHIVOS_PUBLICOS", "/mnt/data/ficheros"
)
PUERTO_ARCHIVOS_PUBLICOS = int(os.getenv("PUERTO_ARCHIVOS_PUBLICOS", "8000"))
URL_PUBLICA_ARCHIVOS = os.getenv(
    "URL_PUBLICA_ARCHIVOS", f"https://localhost:{PUERTO_ARCHIVOS_PUBLICOS}"
).rstrip("/")
if URL_PUBLICA_ARCHIVOS.startswith("http://"):
    URL_PUBLICA_ARCHIVOS = "https://" + URL_PUBLICA_ARCHIVOS[len("http://") :]
SERVIR_ARCHIVOS_PUBLICOS = os.getenv("SERVIR_ARCHIVOS_PUBLICOS", "").lower() in {
    "1",
    "true",
    "si",
    "sí",
    "yes",
}

FAILURES_TEST_SIZE = 40
TIEMPO_PREGUNTA_SEGUNDOS = 20
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
        puntuacion, posicion = item
        try:
            historico.append((float(puntuacion), int(posicion)))
        except (TypeError, ValueError):
            continue
    return historico


HISTORICO_2024 = cargar_historico_desde_entorno("HISTORICO_2024")
HISTORICO_2022 = cargar_historico_desde_entorno("HISTORICO_2022")
PLAZAS_REFERENCIA_SIMULACRO = int(os.getenv("PLAZAS_REFERENCIA_SIMULACRO", "844"))
N_MAX_SIMULACRO = 160       # Puntuación directa máxima (80 + 80)
E_MAX_SIMULACRO = 100       # Calificación máxima transformada
MIN_DIRECTA_SIMULACRO = N_MAX_SIMULACRO * 0.30  # 48 pts — mínimo 30%


# ─────────────── DB ───────────────
def get_conn():
    conn = sqlite3.connect(DB_FILE)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    os.makedirs(RUTA_DATOS, exist_ok=True)
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_id TEXT UNIQUE NOT NULL,
                created_at TEXT NOT NULL
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS quizzes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL,
                description TEXT,
                created_at TEXT NOT NULL
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS questions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                quiz_id INTEGER NOT NULL,
                text TEXT NOT NULL,
                explicacion TEXT,
                bloque INTEGER,
                tema INTEGER,
                FOREIGN KEY (quiz_id) REFERENCES quizzes(id)
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS options (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                question_id INTEGER NOT NULL,
                text TEXT NOT NULL,
                position INTEGER NOT NULL,
                FOREIGN KEY (question_id) REFERENCES questions(id)
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS attempts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER NOT NULL,
                quiz_id INTEGER,
                attempt_type TEXT NOT NULL,
                started_at TEXT NOT NULL,
                finished_at TEXT,
                correct INTEGER DEFAULT 0,
                wrong INTEGER DEFAULT 0,
                FOREIGN KEY (user_id) REFERENCES users(id),
                FOREIGN KEY (quiz_id) REFERENCES quizzes(id)
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS attempt_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                attempt_id INTEGER NOT NULL,
                question_id INTEGER NOT NULL,
                selected_option TEXT NOT NULL,
                is_correct INTEGER NOT NULL,
                FOREIGN KEY (attempt_id) REFERENCES attempts(id),
                FOREIGN KEY (question_id) REFERENCES questions(id)
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS failures (
                user_id INTEGER NOT NULL,
                question_id INTEGER NOT NULL,
                fail_count INTEGER NOT NULL DEFAULT 0,
                last_failed_at TEXT NOT NULL,
                PRIMARY KEY (user_id, question_id),
                FOREIGN KEY (user_id) REFERENCES users(id),
                FOREIGN KEY (question_id) REFERENCES questions(id)
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS favorites (
                user_id INTEGER NOT NULL,
                question_id INTEGER NOT NULL,
                created_at TEXT NOT NULL,
                PRIMARY KEY (user_id, question_id),
                FOREIGN KEY (user_id) REFERENCES users(id),
                FOREIGN KEY (question_id) REFERENCES questions(id)
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS tests_favoritos (
                user_id INTEGER NOT NULL,
                quiz_id INTEGER NOT NULL,
                created_at TEXT NOT NULL,
                PRIMARY KEY (user_id, quiz_id),
                FOREIGN KEY (user_id) REFERENCES users(id),
                FOREIGN KEY (quiz_id) REFERENCES quizzes(id)
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS tests_temporales (
                attempt_id INTEGER NOT NULL,
                question_id INTEGER NOT NULL,
                posicion INTEGER NOT NULL,
                PRIMARY KEY (attempt_id, posicion),
                FOREIGN KEY (attempt_id) REFERENCES attempts(id),
                FOREIGN KEY (question_id) REFERENCES questions(id)
            )
            """
        )
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS simulacros (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                nombre TEXT NOT NULL,
                quiz_id INTEGER NOT NULL,
                nota_corte_directa REAL NOT NULL,
                escala_maxima REAL NOT NULL,
                created_at TEXT NOT NULL,
                FOREIGN KEY (quiz_id) REFERENCES quizzes(id)
            )
            """
        )
        asegurar_columna_descripcion(conn)
        asegurar_columnas_preguntas(conn)
        conn.commit()


def get_or_create_user(chat_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id FROM users WHERE chat_id = ?", (str(chat_id),))
        row = cur.fetchone()
        if row:
            return row["id"]
        now = datetime.utcnow().isoformat()
        cur.execute(
            "INSERT INTO users (chat_id, created_at) VALUES (?, ?)",
            (str(chat_id), now),
        )
        conn.commit()
        return cur.lastrowid


def asegurar_columna_descripcion(conn):
    cur = conn.cursor()
    cur.execute("PRAGMA table_info(quizzes)")
    columnas = [row[1] for row in cur.fetchall()]
    if "description" not in columnas:
        cur.execute("ALTER TABLE quizzes ADD COLUMN description TEXT")


def asegurar_columnas_preguntas(conn):
    cur = conn.cursor()
    cur.execute("PRAGMA table_info(questions)")
    columnas = [row[1] for row in cur.fetchall()]
    if "explicacion" not in columnas:
        cur.execute("ALTER TABLE questions ADD COLUMN explicacion TEXT")
    if "bloque" not in columnas:
        cur.execute("ALTER TABLE questions ADD COLUMN bloque INTEGER")
    if "tema" not in columnas:
        cur.execute("ALTER TABLE questions ADD COLUMN tema INTEGER")


def create_quiz(quiz, titulo=None, descripcion=None):
    title = titulo or quiz.get("titulo") or "Quiz"
    descripcion = descripcion or quiz.get("descripcion")
    preguntas = quiz.get("preguntas") or []
    if not preguntas:
        return None
    now = datetime.utcnow().isoformat()
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO quizzes (title, description, created_at) VALUES (?, ?, ?)",
            (title, descripcion, now),
        )
        quiz_id = cur.lastrowid
        for p in preguntas:
            texto = (p.get("pregunta") or "").strip()
            explicacion = (p.get("explicacion") or "").strip() or None
            opciones = p.get("opciones") or []
            bloque = p.get("bloque")
            tema = p.get("tema")
            if not texto or len(opciones) < 2:
                continue
            cur.execute(
                """
                INSERT INTO questions (quiz_id, text, explicacion, bloque, tema)
                VALUES (?, ?, ?, ?, ?)
                """,
                (quiz_id, texto, explicacion, bloque, tema),
            )
            q_id = cur.lastrowid
            for idx, opt in enumerate(opciones):
                cur.execute(
                    "INSERT INTO options (question_id, text, position) VALUES (?, ?, ?)",
                    (q_id, str(opt).strip(), idx),
                )
        conn.commit()
        return quiz_id


def listar_tests_con_conteo():
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT q.id, q.title, q.description, COUNT(que.id) AS total_preguntas
            FROM quizzes q
            LEFT JOIN questions que ON que.quiz_id = q.id
            GROUP BY q.id
            ORDER BY q.id DESC
            """
        )
        return cur.fetchall()


def contar_tests():
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT COUNT(*) AS total FROM quizzes")
        row = cur.fetchone()
        return row["total"] if row else 0


def listar_tests_con_conteo_paginado(desplazamiento, limite):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT q.id, q.title, q.description, COUNT(que.id) AS total_preguntas
            FROM quizzes q
            LEFT JOIN questions que ON que.quiz_id = q.id
            GROUP BY q.id
            ORDER BY q.id DESC
            LIMIT ? OFFSET ?
            """,
            (limite, desplazamiento),
        )
        return cur.fetchall()

def obtener_conteo_intentos_por_test(user_id, quiz_ids):
    if not quiz_ids:
        return {}

    placeholders = ",".join("?" for _ in quiz_ids)
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            f"""
            SELECT quiz_id, COUNT(*) AS total_intentos
            FROM attempts
            WHERE user_id = ?
              AND quiz_id IN ({placeholders})
              AND finished_at IS NOT NULL
            GROUP BY quiz_id
            """,
            [user_id, *quiz_ids],
        )
        filas = cur.fetchall()

    return {fila["quiz_id"]: fila["total_intentos"] for fila in filas}


def contar_tests_favoritos(user_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT COUNT(*) AS total FROM tests_favoritos WHERE user_id = ?",
            (user_id,),
        )
        row = cur.fetchone()
        return row["total"] if row else 0


def listar_tests_favoritos_con_conteo_paginado(user_id, desplazamiento, limite):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT q.id, q.title, q.description, COUNT(que.id) AS total_preguntas
            FROM tests_favoritos tf
            JOIN quizzes q ON q.id = tf.quiz_id
            LEFT JOIN questions que ON que.quiz_id = q.id
            WHERE tf.user_id = ?
            GROUP BY q.id
            ORDER BY tf.created_at DESC
            LIMIT ? OFFSET ?
            """,
            (user_id, limite, desplazamiento),
        )
        return cur.fetchall()


def marcar_test_favorito(user_id, quiz_id):
    now = datetime.utcnow().isoformat()
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO tests_favoritos (user_id, quiz_id, created_at)
            VALUES (?, ?, ?)
            ON CONFLICT(user_id, quiz_id) DO NOTHING
            """,
            (user_id, quiz_id, now),
        )
        conn.commit()


def quitar_test_favorito(user_id, quiz_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "DELETE FROM tests_favoritos WHERE user_id = ? AND quiz_id = ?",
            (user_id, quiz_id),
        )
        conn.commit()


def es_test_favorito(user_id, quiz_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT 1 FROM tests_favoritos WHERE user_id = ? AND quiz_id = ?",
            (user_id, quiz_id),
        )
        return cur.fetchone() is not None


def obtener_tests_favoritos(user_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT quiz_id FROM tests_favoritos WHERE user_id = ?",
            (user_id,),
        )
        return {fila["quiz_id"] for fila in cur.fetchall()}



def obtener_tests_realizados(user_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT DISTINCT quiz_id
            FROM attempts
            WHERE user_id = ?
              AND attempt_type = 'quiz'
              AND finished_at IS NOT NULL
              AND quiz_id IS NOT NULL
            """,
            (user_id,),
        )
        return {fila["quiz_id"] for fila in cur.fetchall()}


def listar_simulacros():
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT s.id, s.nombre, s.quiz_id, s.nota_corte_directa, s.escala_maxima, q.title AS test_titulo
            FROM simulacros s
            JOIN quizzes q ON q.id = s.quiz_id
            ORDER BY s.id DESC
            """
        )
        return cur.fetchall()


def obtener_simulacro(simulacro_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT s.id, s.nombre, s.quiz_id, s.nota_corte_directa, s.escala_maxima, q.title AS test_titulo
            FROM simulacros s
            JOIN quizzes q ON q.id = s.quiz_id
            WHERE s.id = ?
            """,
            (simulacro_id,),
        )
        return cur.fetchone()


def crear_simulacro(nombre, quiz_id, nota_corte_directa, escala_maxima):
    now = datetime.utcnow().isoformat()
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO simulacros (nombre, quiz_id, nota_corte_directa, escala_maxima, created_at)
            VALUES (?, ?, ?, ?, ?)
            """,
            (nombre, quiz_id, nota_corte_directa, escala_maxima, now),
        )
        conn.commit()
        return cur.lastrowid


def eliminar_simulacro(simulacro_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("DELETE FROM simulacros WHERE id = ?", (simulacro_id,))
        conn.commit()
        return cur.rowcount > 0


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


def obtener_titulo_test(quiz_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT title FROM quizzes WHERE id = ?", (quiz_id,))
        row = cur.fetchone()
        return row["title"] if row else None


def load_quiz_questions(quiz_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT id, text, explicacion FROM questions WHERE quiz_id = ?",
            (quiz_id,),
        )
        questions = []
        for row in cur.fetchall():
            cur.execute(
                "SELECT text, position FROM options WHERE question_id = ? ORDER BY position ASC",
                (row["id"],),
            )
            options = [o["text"] for o in cur.fetchall()]
            if not options:
                continue
            questions.append(
                {
                    "id": row["id"],
                    "text": row["text"],
                    "explicacion": row["explicacion"],
                    "options": options,
                    "correct_text": options[0],
                }
            )
        return questions


def get_progreso_por_tests(user_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT q.id AS quiz_id, q.title, a.correct, a.wrong, a.started_at
            FROM attempts a
            JOIN quizzes q ON q.id = a.quiz_id
            WHERE a.user_id = ?
              AND a.attempt_type = 'quiz'
              AND a.finished_at IS NOT NULL
            ORDER BY q.id, a.started_at
            """,
            (user_id,),
        )
        filas = cur.fetchall()
    resumen = {}
    for fila in filas:
        quiz_id = fila["quiz_id"]
        resumen.setdefault(
            quiz_id,
            {"titulo": fila["title"], "intentos": []},
        )
        correct = fila["correct"]
        wrong = fila["wrong"]
        total = correct + wrong
        nota = max((correct - PENALIZACION_FALLO * wrong) / total * 10, 0) if total else 0
        resumen[quiz_id]["intentos"].append(
            {
                "correct": correct,
                "wrong": wrong,
                "nota": nota,
            }
        )
    return list(resumen.values())


def obtener_test_como_json(quiz_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT title, description FROM quizzes WHERE id = ?",
            (quiz_id,),
        )
        quiz = cur.fetchone()
        if not quiz:
            return None
        cur.execute(
            """
            SELECT id, text, explicacion, bloque, tema
            FROM questions
            WHERE quiz_id = ?
            ORDER BY id ASC
            """,
            (quiz_id,),
        )
        preguntas = []
        for fila in cur.fetchall():
            cur.execute(
                """
                SELECT text
                FROM options
                WHERE question_id = ?
                ORDER BY position ASC
                """,
                (fila["id"],),
            )
            opciones = [item["text"] for item in cur.fetchall()]
            if len(opciones) < 2:
                continue
            preguntas.append(
                {
                    "pregunta": fila["text"],
                    "opciones": opciones,
                    "bloque": fila["bloque"],
                    "tema": fila["tema"],
                    "explicacion": fila["explicacion"],
                }
            )
    return {
        "titulo": quiz["title"],
        "descripcion": quiz["description"],
        "preguntas": preguntas,
    }


def normalizar_nombre_archivo_test(titulo):
    base = "".join(c if c.isalnum() else "_" for c in (titulo or "test"))
    base = base.strip("_") or "test"
    return base.lower()


def get_progreso_general(user_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT a.correct, a.wrong
            FROM attempts a
            JOIN (
                SELECT quiz_id, MAX(id) AS ultimo_id
                FROM attempts
                WHERE user_id = ?
                  AND attempt_type = 'quiz'
                  AND finished_at IS NOT NULL
                GROUP BY quiz_id
            ) ult ON ult.ultimo_id = a.id
            """,
            (user_id,),
        )
        filas = cur.fetchall()
    total_correct = sum(fila["correct"] for fila in filas)
    total_wrong = sum(fila["wrong"] for fila in filas)
    total = total_correct + total_wrong
    nota = max((total_correct - PENALIZACION_FALLO * total_wrong) / total * 10, 0) if total else 0
    return {
        "total_correct": total_correct,
        "total_wrong": total_wrong,
        "nota": nota,
    }


def contar_preguntas_respondidas_hoy(user_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT COUNT(ai.id) AS total
            FROM attempt_items ai
            JOIN attempts a ON a.id = ai.attempt_id
            WHERE a.user_id = ?
              AND date(a.started_at) = date('now')
            """,
            (user_id,),
        )
        fila = cur.fetchone()
        return fila["total"] if fila else 0


def create_attempt(user_id, quiz_id, attempt_type):
    now = datetime.utcnow().isoformat()
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO attempts (user_id, quiz_id, attempt_type, started_at)
            VALUES (?, ?, ?, ?)
            """,
            (user_id, quiz_id, attempt_type, now),
        )
        conn.commit()
        return cur.lastrowid


def finish_attempt(attempt_id, correct, wrong):
    now = datetime.utcnow().isoformat()
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            UPDATE attempts
            SET finished_at = ?, correct = ?, wrong = ?
            WHERE id = ?
            """,
            (now, correct, wrong, attempt_id),
        )
        cur.execute("DELETE FROM tests_temporales WHERE attempt_id = ?", (attempt_id,))
        conn.commit()


def add_attempt_item(attempt_id, question_id, selected_option, is_correct):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO attempt_items (attempt_id, question_id, selected_option, is_correct)
            VALUES (?, ?, ?, ?)
            """,
            (attempt_id, question_id, selected_option, int(is_correct)),
        )
        conn.commit()


def obtener_tests_pendientes(user_id):
    """Devuelve un set de quiz_ids con intentos sin terminar."""
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT DISTINCT quiz_id
            FROM attempts
            WHERE user_id = ?
              AND attempt_type = 'quiz'
              AND finished_at IS NULL
              AND quiz_id IS NOT NULL
            """,
            (user_id,),
        )
        return {fila["quiz_id"] for fila in cur.fetchall()}


def obtener_intento_pendiente(user_id, quiz_id):
    """Devuelve el intento sin terminar más reciente para un test, o None."""
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id, correct, wrong
            FROM attempts
            WHERE user_id = ?
              AND quiz_id = ?
              AND attempt_type = 'quiz'
              AND finished_at IS NULL
            ORDER BY started_at DESC
            LIMIT 1
            """,
            (user_id, quiz_id),
        )
        row = cur.fetchone()
        if row:
            return {"id": row["id"], "correct": row["correct"], "wrong": row["wrong"]}
        return None


def obtener_intento_pendiente_por_tipo(user_id, tipo_intento):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id, correct, wrong
            FROM attempts
            WHERE user_id = ?
              AND attempt_type = ?
              AND finished_at IS NULL
            ORDER BY started_at DESC
            LIMIT 1
            """,
            (user_id, tipo_intento),
        )
        fila = cur.fetchone()
        if not fila:
            return None
        return {"id": fila["id"], "correct": fila["correct"], "wrong": fila["wrong"]}


def obtener_preguntas_respondidas(attempt_id):
    """Devuelve un set de question_ids ya respondidos en este intento."""
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT question_id FROM attempt_items WHERE attempt_id = ?",
            (attempt_id,),
        )
        return {fila["question_id"] for fila in cur.fetchall()}


def descartar_intentos_pendientes(user_id, quiz_id=None):
    """Elimina intentos sin terminar de un usuario (opcionalmente para un quiz específico)."""
    with get_conn() as conn:
        cur = conn.cursor()
        if quiz_id is not None:
            cur.execute(
                """
                SELECT id
                FROM attempts
                WHERE user_id = ? AND quiz_id = ? AND finished_at IS NULL AND attempt_type = 'quiz'
                """,
                (user_id, quiz_id),
            )
        else:
            cur.execute(
                """
                SELECT id
                FROM attempts
                WHERE user_id = ? AND finished_at IS NULL AND attempt_type = 'quiz'
                """,
                (user_id,),
            )
        intentos_ids = [fila["id"] for fila in cur.fetchall()]
        for intento_id in intentos_ids:
            cur.execute("DELETE FROM attempt_items WHERE attempt_id = ?", (intento_id,))
            cur.execute("DELETE FROM tests_temporales WHERE attempt_id = ?", (intento_id,))
            cur.execute("DELETE FROM attempts WHERE id = ?", (intento_id,))
        conn.commit()


def descartar_intentos_pendientes_por_tipo(user_id, tipo_intento):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id
            FROM attempts
            WHERE user_id = ?
              AND attempt_type = ?
              AND finished_at IS NULL
            """,
            (user_id, tipo_intento),
        )
        intentos_ids = [fila["id"] for fila in cur.fetchall()]
        for intento_id in intentos_ids:
            cur.execute("DELETE FROM attempt_items WHERE attempt_id = ?", (intento_id,))
            cur.execute("DELETE FROM tests_temporales WHERE attempt_id = ?", (intento_id,))
            cur.execute("DELETE FROM attempts WHERE id = ?", (intento_id,))
        conn.commit()


def guardar_test_temporal(attempt_id, preguntas):
    with get_conn() as conn:
        cur = conn.cursor()
        for posicion, pregunta in enumerate(preguntas):
            cur.execute(
                """
                INSERT INTO tests_temporales (attempt_id, question_id, posicion)
                VALUES (?, ?, ?)
                """,
                (attempt_id, pregunta["id"], posicion),
            )
        conn.commit()


def obtener_test_temporal(attempt_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT question_id
            FROM tests_temporales
            WHERE attempt_id = ?
            ORDER BY posicion ASC
            """,
            (attempt_id,),
        )
        preguntas_ids = [fila["question_id"] for fila in cur.fetchall()]
        if not preguntas_ids:
            return []

        preguntas = []
        for pregunta_id in preguntas_ids:
            cur.execute(
                "SELECT id, text, explicacion FROM questions WHERE id = ?",
                (pregunta_id,),
            )
            fila = cur.fetchone()
            if not fila:
                continue
            cur.execute(
                "SELECT text, position FROM options WHERE question_id = ? ORDER BY position ASC",
                (pregunta_id,),
            )
            opciones = [opcion["text"] for opcion in cur.fetchall()]
            if not opciones:
                continue
            preguntas.append(
                {
                    "id": fila["id"],
                    "text": fila["text"],
                    "explicacion": fila["explicacion"],
                    "options": opciones,
                    "correct_text": opciones[0],
                }
            )
        return preguntas


def record_failure(user_id, question_id):
    now = datetime.utcnow().isoformat()
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO failures (user_id, question_id, fail_count, last_failed_at)
            VALUES (?, ?, 1, ?)
            ON CONFLICT(user_id, question_id)
            DO UPDATE SET fail_count = fail_count + 1, last_failed_at = excluded.last_failed_at
            """,
            (user_id, question_id, now),
        )
        conn.commit()


def clear_failure(user_id, question_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "DELETE FROM failures WHERE user_id = ? AND question_id = ?",
            (user_id, question_id),
        )
        conn.commit()


def revertir_fallo(user_id, question_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT fail_count FROM failures WHERE user_id = ? AND question_id = ?",
            (user_id, question_id),
        )
        fila = cur.fetchone()
        if not fila:
            return
        if fila["fail_count"] <= 1:
            cur.execute(
                "DELETE FROM failures WHERE user_id = ? AND question_id = ?",
                (user_id, question_id),
            )
        else:
            cur.execute(
                "UPDATE failures SET fail_count = fail_count - 1 WHERE user_id = ? AND question_id = ?",
                (user_id, question_id),
            )
        conn.commit()


def obtener_respuesta_pregunta_intento(attempt_id, question_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id, is_correct
            FROM attempt_items
            WHERE attempt_id = ? AND question_id = ?
            ORDER BY id DESC
            LIMIT 1
            """,
            (attempt_id, question_id),
        )
        fila = cur.fetchone()
        if not fila:
            return None
        return {"id": fila["id"], "is_correct": bool(fila["is_correct"])}


def borrar_respuesta_pregunta_intento(attempt_item_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("DELETE FROM attempt_items WHERE id = ?", (attempt_item_id,))
        conn.commit()


def agregar_favorita(user_id, question_id):
    now = datetime.utcnow().isoformat()
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            INSERT INTO favorites (user_id, question_id, created_at)
            VALUES (?, ?, ?)
            ON CONFLICT(user_id, question_id) DO NOTHING
            """,
            (user_id, question_id, now),
        )
        conn.commit()


def quitar_favorita(user_id, question_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "DELETE FROM favorites WHERE user_id = ? AND question_id = ?",
            (user_id, question_id),
        )
        conn.commit()


def es_pregunta_favorita(user_id, question_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT 1 FROM favorites WHERE user_id = ? AND question_id = ?",
            (user_id, question_id),
        )
        return cur.fetchone() is not None


def get_favorites_questions(user_id, limit_count):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT q.id, q.text, q.explicacion
            FROM favorites f
            JOIN questions q ON q.id = f.question_id
            WHERE f.user_id = ?
            ORDER BY f.created_at DESC
            LIMIT ?
            """,
            (user_id, limit_count),
        )
        rows = cur.fetchall()
        questions = []
        for row in rows:
            cur.execute(
                "SELECT text, position FROM options WHERE question_id = ? ORDER BY position ASC",
                (row["id"],),
            )
            options = [o["text"] for o in cur.fetchall()]
            if not options:
                continue
            questions.append(
                {
                    "id": row["id"],
                    "text": row["text"],
                    "explicacion": row["explicacion"],
                    "options": options,
                    "correct_text": options[0],
                }
            )
        return questions


def obtener_explicacion_pregunta(question_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT explicacion FROM questions WHERE id = ?",
            (question_id,),
        )
        row = cur.fetchone()
        return row["explicacion"] if row else None


def actualizar_explicacion_pregunta(question_id, explicacion):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "UPDATE questions SET explicacion = ? WHERE id = ?",
            (explicacion, question_id),
        )
        conn.commit()


def get_failures_questions(user_id, limit_count):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT q.id, q.text, q.explicacion
            FROM failures f
            JOIN questions q ON q.id = f.question_id
            WHERE f.user_id = ?
            ORDER BY f.last_failed_at DESC
            LIMIT ?
            """,
            (user_id, limit_count),
        )
        rows = cur.fetchall()
        questions = []
        for row in rows:
            cur.execute(
                "SELECT text, position FROM options WHERE question_id = ? ORDER BY position ASC",
                (row["id"],),
            )
            options = [o["text"] for o in cur.fetchall()]
            if not options:
                continue
            questions.append(
                {
                    "id": row["id"],
                    "text": row["text"],
                    "explicacion": row["explicacion"],
                    "options": options,
                    "correct_text": options[0],
                }
            )
        return questions


def get_progress_summary(user_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT
                COALESCE(SUM(correct), 0) AS total_correct,
                COALESCE(SUM(wrong), 0) AS total_wrong,
                COUNT(*) AS total_attempts
            FROM attempts
            WHERE user_id = ?
            """,
            (user_id,),
        )
        stats = cur.fetchone()
        cur.execute(
            "SELECT COUNT(*) AS failed_q FROM failures WHERE user_id = ?",
            (user_id,),
        )
        failed = cur.fetchone()
        return {
            "total_correct": stats["total_correct"],
            "total_wrong": stats["total_wrong"],
            "total_attempts": stats["total_attempts"],
            "failed_q": failed["failed_q"],
        }


def borrar_test(quiz_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("DELETE FROM tests_favoritos WHERE quiz_id = ?", (quiz_id,))
        cur.execute("SELECT id FROM questions WHERE quiz_id = ?", (quiz_id,))
        preguntas_ids = [row["id"] for row in cur.fetchall()]
        if preguntas_ids:
            placeholders = ",".join("?" for _ in preguntas_ids)
            cur.execute(
                f"DELETE FROM failures WHERE question_id IN ({placeholders})",
                preguntas_ids,
            )
            cur.execute(
                f"DELETE FROM favorites WHERE question_id IN ({placeholders})",
                preguntas_ids,
            )
            cur.execute(
                f"DELETE FROM options WHERE question_id IN ({placeholders})",
                preguntas_ids,
            )
            cur.execute(
                f"DELETE FROM attempt_items WHERE question_id IN ({placeholders})",
                preguntas_ids,
            )
            cur.execute(
                f"DELETE FROM questions WHERE id IN ({placeholders})",
                preguntas_ids,
            )
        cur.execute("SELECT id FROM attempts WHERE quiz_id = ?", (quiz_id,))
        intentos_ids = [row["id"] for row in cur.fetchall()]
        if intentos_ids:
            placeholders = ",".join("?" for _ in intentos_ids)
            cur.execute(
                f"DELETE FROM attempt_items WHERE attempt_id IN ({placeholders})",
                intentos_ids,
            )
            cur.execute(
                f"DELETE FROM tests_temporales WHERE attempt_id IN ({placeholders})",
                intentos_ids,
            )
            cur.execute(
                f"DELETE FROM attempts WHERE id IN ({placeholders})",
                intentos_ids,
            )
        cur.execute("DELETE FROM quizzes WHERE id = ?", (quiz_id,))
        conn.commit()


def borrar_pregunta(question_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT quiz_id FROM questions WHERE id = ?", (question_id,))
        fila = cur.fetchone()
        if not fila:
            return False
        cur.execute("DELETE FROM failures WHERE question_id = ?", (question_id,))
        cur.execute("DELETE FROM favorites WHERE question_id = ?", (question_id,))
        cur.execute("DELETE FROM options WHERE question_id = ?", (question_id,))
        cur.execute("DELETE FROM attempt_items WHERE question_id = ?", (question_id,))
        cur.execute("DELETE FROM questions WHERE id = ?", (question_id,))
        conn.commit()
        return True


def sincronizar_borrado_pregunta_en_quiz(context, question_id):
    quiz = context.user_data.get("quiz")
    if not quiz:
        return

    preguntas = quiz.get("questions", [])
    indice_actual = quiz.get("i", 0)
    indice_eliminado = next(
        (indice for indice, pregunta in enumerate(preguntas) if pregunta["id"] == question_id),
        None,
    )

    if indice_eliminado is None:
        return

    del preguntas[indice_eliminado]
    quiz["total_original"] = max(0, quiz.get("total_original", len(preguntas) + 1) - 1)

    if indice_eliminado < indice_actual:
        quiz["i"] = max(0, indice_actual - 1)
    elif indice_eliminado == indice_actual:
        quiz["i"] = max(-1, indice_actual - 1)

    actual = quiz.get("current")
    if actual and actual.get("question_id") == question_id:
        quiz["current"] = None

    if quiz.get("ultimo_pregunta_id") == question_id:
        quiz["ultimo_pregunta_id"] = None


# ─────────────── Formato de texto ───────────────
def wrap_text(text, width=None):
    return text


def split_message(text, limit=None):
    texto = text or ""
    limite = limit or 4096
    if len(texto) <= limite:
        return [texto]

    partes = []
    inicio = 0
    while inicio < len(texto):
        fin = min(inicio + limite, len(texto))
        if fin < len(texto):
            corte = texto.rfind("\n", inicio, fin)
            if corte > inicio:
                fin = corte
        fragmento = texto[inicio:fin].strip()
        if fragmento:
            partes.append(fragmento)
        inicio = fin
        while inicio < len(texto) and texto[inicio] == "\n":
            inicio += 1

    return partes or [texto[:limite]]


def format_option(text):
    return (text or "").strip()


def ensanchar_etiqueta_opcion(texto, ancho_minimo=38):
    texto_limpio = format_option(texto)
    if len(texto_limpio) >= ancho_minimo:
        return texto_limpio
    relleno_total = ancho_minimo - len(texto_limpio)
    relleno_izquierda = relleno_total // 2
    relleno_derecha = relleno_total - relleno_izquierda
    return f"{'·' * relleno_izquierda} {texto_limpio} {'·' * relleno_derecha}"


def construir_lineas_respuesta(indice, texto):
    texto = (texto or "").strip()
    if not texto:
        return f"{indice}."
    return f"{indice}. {texto}"


def construir_texto_pregunta(encabezado, texto_pregunta, opciones=None):
    base = f"{encabezado}\n{texto_pregunta}"
    if not opciones:
        return base
    respuestas = "\n".join(
        construir_lineas_respuesta(idx + 1, opcion)
        for idx, opcion in enumerate(opciones)
    )
    return f"{base}\n\nRespuestas:\n{respuestas}"


def parse_preguntas_json(texto):
    payload = json.loads(texto)
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        preguntas = payload.get("preguntas")
        if isinstance(preguntas, list):
            return preguntas
    return []


def obtener_pregunta_como_json(question_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT id, text, explicacion, bloque, tema
            FROM questions
            WHERE id = ?
            """,
            (question_id,),
        )
        fila = cur.fetchone()
        if not fila:
            return None
        cur.execute(
            """
            SELECT text
            FROM options
            WHERE question_id = ?
            ORDER BY position ASC
            """,
            (question_id,),
        )
        opciones = [item["text"] for item in cur.fetchall()]

    pregunta = {
        "pregunta": fila["text"],
        "opciones": opciones,
        "bloque": fila["bloque"],
        "tema": fila["tema"],
        "explicacion": fila["explicacion"],
    }
    return pregunta


def actualizar_pregunta_desde_json(question_id, payload_pregunta):
    texto = str(payload_pregunta.get("pregunta") or "").strip()
    opciones = payload_pregunta.get("opciones")
    if not texto:
        raise ValueError("La clave 'pregunta' es obligatoria.")
    if not isinstance(opciones, list) or len(opciones) < 2:
        raise ValueError("La clave 'opciones' debe tener al menos dos elementos.")

    opciones_limpias = [str(opcion).strip() for opcion in opciones if str(opcion).strip()]
    if len(opciones_limpias) < 2:
        raise ValueError("Debes mantener al menos dos opciones no vacías.")

    explicacion = payload_pregunta.get("explicacion")
    explicacion = str(explicacion).strip() if explicacion is not None else None
    if explicacion == "":
        explicacion = None

    bloque = payload_pregunta.get("bloque")
    tema = payload_pregunta.get("tema")

    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            UPDATE questions
            SET text = ?, explicacion = ?, bloque = ?, tema = ?
            WHERE id = ?
            """,
            (texto, explicacion, bloque, tema, question_id),
        )
        cur.execute("DELETE FROM options WHERE question_id = ?", (question_id,))
        for indice, opcion in enumerate(opciones_limpias):
            cur.execute(
                """
                INSERT INTO options (question_id, text, position)
                VALUES (?, ?, ?)
                """,
                (question_id, opcion, indice),
            )
        conn.commit()

    return {
        "id": question_id,
        "text": texto,
        "explicacion": explicacion,
        "options": opciones_limpias,
        "correct_text": opciones_limpias[0],
    }


def sincronizar_pregunta_en_quiz(context, question_id, pregunta_actualizada):
    quiz = context.user_data.get("quiz")
    if not quiz:
        return False

    for pregunta in quiz.get("questions", []):
        if pregunta["id"] == question_id:
            pregunta.update(pregunta_actualizada)
            break

    respuesta_previa = obtener_respuesta_pregunta_intento(
        quiz.get("attempt_id"), question_id
    )
    if respuesta_previa:
        borrar_respuesta_pregunta_intento(respuesta_previa["id"])
        if respuesta_previa["is_correct"]:
            quiz["ok"] = max(0, quiz.get("ok", 0) - 1)
        else:
            quiz["fail"] = max(0, quiz.get("fail", 0) - 1)
            user_id = quiz.get("user_id")
            if user_id:
                revertir_fallo(user_id, question_id)

        opciones_mezcladas = list(pregunta_actualizada["options"])
        random.shuffle(opciones_mezcladas)
        quiz["current"] = {
            "question_id": question_id,
            "options": opciones_mezcladas,
            "correct_index": opciones_mezcladas.index(pregunta_actualizada["correct_text"]),
        }
        quiz["esperando_siguiente"] = False
        quiz["ultimo_pregunta_id"] = None
        return True

    actual = quiz.get("current")
    if actual and actual.get("question_id") == question_id:
        opciones_mezcladas = list(pregunta_actualizada["options"])
        random.shuffle(opciones_mezcladas)
        actual["options"] = opciones_mezcladas
        actual["correct_index"] = opciones_mezcladas.index(
            pregunta_actualizada["correct_text"]
        )

    return False


async def procesar_texto_json(texto, update: Update, context, mostrar_error=True):
    try:
        preguntas = parse_preguntas_json(texto)
    except json.JSONDecodeError:
        if mostrar_error:
            await update.message.reply_text("❌ JSON inválido.")
        return False
    if not preguntas:
        if mostrar_error:
            await update.message.reply_text("❌ No se encontraron preguntas válidas.")
        return False

    context.user_data.pop("modo", None)
    context.user_data.pop("buffer", None)
    nuevo_test = context.user_data.pop("nuevo_test", {})

    quiz_id = create_quiz(
        {"preguntas": preguntas},
        titulo=nuevo_test.get("titulo"),
        descripcion=nuevo_test.get("descripcion"),
    )
    if not quiz_id:
        await update.message.reply_text("❌ No se pudo crear ningún test.")
    else:
        await update.message.reply_text("✅ Test creado correctamente.")
    await mostrar_menu(update.message.chat.id, context)
    return True


def extraer_preguntas_desde_payload(payload):
    if isinstance(payload, list):
        return payload, None
    if isinstance(payload, dict):
        preguntas = payload.get("preguntas")
        if isinstance(preguntas, list):
            return preguntas, payload.get("titulo")
    return [], None


def crear_test_y_simulacro_desde_preguntas(preguntas, nombre_simulacro):
    if not preguntas:
        return None, "sin_preguntas"

    quiz_id = create_quiz(
        {"preguntas": preguntas},
        titulo=nombre_simulacro,
        descripcion=f"Test base del simulacro {nombre_simulacro}",
    )
    if not quiz_id:
        return None, "error_crear_test"

    total_preguntas = len(load_quiz_questions(quiz_id))
    if total_preguntas <= 0:
        borrar_test(quiz_id)
        return None, "sin_preguntas_validas"

    simulacro_id = crear_simulacro(
        nombre_simulacro,
        quiz_id,
        MIN_DIRECTA_SIMULACRO,
        E_MAX_SIMULACRO,
    )
    return simulacro_id, None


async def procesar_texto_json_simulacro(texto, update: Update, context, mostrar_error=True):
    try:
        payload = json.loads(texto)
    except json.JSONDecodeError:
        if mostrar_error:
            await update.message.reply_text("❌ JSON inválido.")
        return False

    preguntas, titulo_payload = extraer_preguntas_desde_payload(payload)
    if not preguntas:
        if mostrar_error:
            await update.message.reply_text("❌ No se encontraron preguntas válidas para el simulacro.")
        return False

    configuracion = context.user_data.get("simulacro_en_creacion") or {}
    nombre_simulacro = configuracion.get("nombre") or titulo_payload or "Simulacro"

    simulacro_id, error = crear_test_y_simulacro_desde_preguntas(preguntas, nombre_simulacro)

    if error:
        if error == "sin_preguntas_validas":
            await update.message.reply_text("❌ No se pudo crear el simulacro porque no hay preguntas válidas.")
        else:
            await update.message.reply_text("❌ No se pudo crear el simulacro.")
        return False

    context.user_data.pop("modo", None)
    context.user_data.pop("buffer", None)
    context.user_data.pop("simulacro_en_creacion", None)
    await update.message.reply_text(f"✅ Simulacro creado correctamente (ID {simulacro_id}).")
    await mostrar_menu_simulacros(update.message.chat.id, context)
    return True


def cancelar_temporizador_pregunta(context):
    trabajo = context.user_data.pop("temporizador_pregunta", None)
    if trabajo:
        trabajo.schedule_removal()


def guardar_contexto_cancelable(context, contexto):
    context.user_data["contexto_cancelable"] = contexto


def obtener_quiz_reanudable(quiz, quiz_id):
    if not quiz:
        return False
    if quiz.get("attempt_type") != "quiz":
        return False
    if quiz.get("quiz_id") != quiz_id:
        return False
    return quiz.get("i", 0) < len(quiz.get("questions", []))


def obtener_test_temporal_reanudable(quiz, tipo_intento):
    if not quiz:
        return False
    if quiz.get("attempt_type") != tipo_intento:
        return False
    return quiz.get("i", 0) < len(quiz.get("questions", []))


def reconstruir_quiz_desde_db(user_id, quiz_id, telegram_user_id):
    """Reconstruye el estado del quiz desde la BD para poder reanudarlo."""
    intento = obtener_intento_pendiente(user_id, quiz_id)
    if not intento:
        return None
    questions = load_quiz_questions(quiz_id)
    if not questions:
        return None
    respondidas = obtener_preguntas_respondidas(intento["id"])
    # Contar aciertos y fallos desde attempt_items
    ok = 0
    fail = 0
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT is_correct FROM attempt_items WHERE attempt_id = ?",
            (intento["id"],),
        )
        for fila in cur.fetchall():
            if fila["is_correct"]:
                ok += 1
            else:
                fail += 1
    # Filtrar preguntas ya respondidas manteniendo el orden
    preguntas_pendientes = [q for q in questions if q["id"] not in respondidas]
    if not preguntas_pendientes:
        return None
    # Reconstruir con todas las preguntas pero el índice apuntando a las pendientes
    # Usamos solo las preguntas pendientes como lista restante
    return {
        "questions": preguntas_pendientes,
        "quiz_id": quiz_id,
        "i": 0,
        "ok": ok,
        "fail": fail,
        "attempt_id": intento["id"],
        "attempt_type": "quiz",
        "user_id": user_id,
        "telegram_user_id": telegram_user_id,
        "total_original": len(questions),
        "respondidas_count": len(respondidas),
    }


def reconstruir_test_temporal_desde_db(user_id, tipo_intento, telegram_user_id):
    intento = obtener_intento_pendiente_por_tipo(user_id, tipo_intento)
    if not intento:
        return None

    preguntas = obtener_test_temporal(intento["id"])
    if not preguntas:
        return None

    respondidas = obtener_preguntas_respondidas(intento["id"])
    ok = 0
    fail = 0
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT is_correct FROM attempt_items WHERE attempt_id = ?",
            (intento["id"],),
        )
        for fila in cur.fetchall():
            if fila["is_correct"]:
                ok += 1
            else:
                fail += 1

    preguntas_pendientes = [q for q in preguntas if q["id"] not in respondidas]
    if not preguntas_pendientes:
        return None

    return {
        "questions": preguntas_pendientes,
        "i": 0,
        "ok": ok,
        "fail": fail,
        "attempt_id": intento["id"],
        "attempt_type": tipo_intento,
        "user_id": user_id,
        "telegram_user_id": telegram_user_id,
        "total_original": len(preguntas),
        "respondidas_count": len(respondidas),
    }


async def volver_a_contexto_anterior(chat_id, context):
    contexto = context.user_data.pop("contexto_cancelable", None)
    if not contexto:
        if context.user_data.get("quiz"):
            await mostrar_pregunta_actual(chat_id, context)
        else:
            await mostrar_menu(chat_id, context)
        return

    tipo = contexto.get("tipo")
    if tipo == "pregunta_actual":
        await mostrar_pregunta_actual(chat_id, context)
    elif tipo == "lista_tests":
        await mostrar_tests(chat_id, context, pagina=contexto.get("pagina", 1))
    elif tipo == "lista_borrado_tests":
        await mostrar_tests_para_borrar(chat_id, context, pagina=contexto.get("pagina", 1))
    else:
        await mostrar_menu(chat_id, context)


def cerrar_intento_en_curso(context):
    quiz = context.user_data.get("quiz")
    if not quiz:
        return

    attempt_id = quiz.get("attempt_id")
    if attempt_id and quiz.get("attempt_type") != "quiz":
        finish_attempt(attempt_id, quiz.get("ok", 0), quiz.get("fail", 0))

    cancelar_temporizador_pregunta(context)
    context.user_data.pop("quiz", None)


def programar_temporizador_pregunta(context, chat_id, indice_pregunta, pregunta_id):
    telegram_user_id = context.user_data.get("quiz", {}).get("telegram_user_id")
    if not telegram_user_id:
        return
    trabajo = context.job_queue.run_once(
        tiempo_agotado,
        TIEMPO_PREGUNTA_SEGUNDOS,
        data={
            "chat_id": chat_id,
            "indice_pregunta": indice_pregunta,
            "pregunta_id": pregunta_id,
            "telegram_user_id": telegram_user_id,
        },
    )
    context.user_data["temporizador_pregunta"] = trabajo


async def tiempo_agotado(context: ContextTypes.DEFAULT_TYPE):
    datos = context.job.data
    telegram_user_id = datos["telegram_user_id"]
    chat_id = datos["chat_id"]
    indice_pregunta = datos["indice_pregunta"]
    pregunta_id = datos["pregunta_id"]

    datos_usuario = context.application.user_data.get(telegram_user_id)
    if not datos_usuario:
        return

    quiz = datos_usuario.get("quiz")
    if not quiz or quiz.get("i") != indice_pregunta:
        return

    actual = quiz.get("current")
    if not actual or actual.get("question_id") != pregunta_id:
        return

    correcta = wrap_text(actual["options"][actual["correct_index"]])
    await context.bot.send_message(chat_id, "⏰ Tiempo agotado.")

    if quiz.get("attempt_type") == "simulacro":
        quiz["sin_responder"] = quiz.get("sin_responder", 0) + 1
        await context.bot.send_message(chat_id, "Pregunta dejada sin contestar.")
        add_attempt_item(quiz["attempt_id"], pregunta_id, "Sin respuesta", False)
    else:
        quiz["fail"] += 1
        await context.bot.send_message(chat_id, f"💡 Respuesta correcta:\n{correcta}")
        add_attempt_item(quiz["attempt_id"], pregunta_id, "Sin respuesta", False)
        record_failure(quiz["user_id"], pregunta_id)


    quiz["esperando_siguiente"] = True
    quiz["ultimo_pregunta_id"] = pregunta_id
    await mostrar_opciones_post_respuesta(chat_id, context, pregunta_id)


# ─────────────── /start ───────────────
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await mostrar_menu(update.message.chat.id, context, "👋 Bienvenido al TestBot")


# ─────────────── Menú principal ───────────────
async def mostrar_menu(chat_id, context, texto="Selecciona una opción:"):
    botones = [
        [InlineKeyboardButton("🧩 Crear test", callback_data="crear_test")],
        [InlineKeyboardButton("📦 Subir tests (ZIP)", callback_data="subir_zip")],
        [InlineKeyboardButton("📋 Mis tests", callback_data="mis_tests")],
        [InlineKeyboardButton("🗑️ Borrar test", callback_data="borrar_tests")],
        [InlineKeyboardButton("⬇️ Descargar test", callback_data="descargar_tests")],
        [
            InlineKeyboardButton(
                "⬇️ Descargar todos los tests", callback_data="descargar_todos_tests"
            )
        ],
        [InlineKeyboardButton("📈 Progreso", callback_data="progreso")],
        [InlineKeyboardButton("⚠️ Test de fallos", callback_data="test_fallos")],
        [InlineKeyboardButton("⭐ Hacer tests favoritos", callback_data="tests_favoritos")],
        [InlineKeyboardButton("⭐ Test de favoritas", callback_data="test_favoritas")],
        [InlineKeyboardButton("🧪 Simulacros", callback_data="menu_simulacros")],
        [InlineKeyboardButton("⬇️ Descargar BD", callback_data="descargar_bd")],
    ]
    await context.bot.send_message(
        chat_id, texto, reply_markup=InlineKeyboardMarkup(botones)
    )


async def mostrar_menu_simulacros(chat_id, context, texto="🧪 Menú de simulacros"):
    botones = [
        [InlineKeyboardButton("➕ Añadir simulacro", callback_data="anadir_simulacro")],
        [InlineKeyboardButton("🗑️ Eliminar simulacro", callback_data="eliminar_simulacro")],
        [InlineKeyboardButton("▶️ Hacer simulacro", callback_data="hacer_simulacro")],
        [InlineKeyboardButton("☰ Menú", callback_data="menu")],
    ]
    await context.bot.send_message(
        chat_id,
        texto,
        reply_markup=InlineKeyboardMarkup(botones),
    )


async def mostrar_lista_simulacros(chat_id, context, modo_lista):
    simulacros = listar_simulacros()
    if not simulacros:
        await context.bot.send_message(chat_id, "No hay simulacros creados todavía.")
        return

    if modo_lista == "eliminar":
        prefijo = "eliminar_simulacro_"
        titulo = "🗑️ Elige un simulacro para eliminar:"
    else:
        prefijo = "iniciar_simulacro_"
        titulo = "▶️ Elige un simulacro para empezar:"

    botones = []
    for simulacro in simulacros:
        etiqueta = (
            f"{simulacro['nombre']} · {simulacro['test_titulo']} "
            f"(corte={simulacro['nota_corte_directa']}, E={simulacro['escala_maxima']})"
        )
        botones.append(
            [
                InlineKeyboardButton(
                    etiqueta,
                    callback_data=f"{prefijo}{simulacro['id']}",
                )
            ]
        )

    botones.append([InlineKeyboardButton("↩️ Volver", callback_data="menu_simulacros")])
    await context.bot.send_message(
        chat_id,
        titulo,
        reply_markup=InlineKeyboardMarkup(botones),
    )




async def mostrar_pregunta_actual(chat_id, context):
    quiz = context.user_data.get("quiz")
    if not quiz:
        await mostrar_menu(chat_id, context)
        return

    if quiz.get("esperando_siguiente"):
        pregunta_id = quiz.get("ultimo_pregunta_id")
        if pregunta_id:
            await mostrar_opciones_post_respuesta(chat_id, context, pregunta_id)
            return

    if quiz.get("i", 0) >= len(quiz.get("questions", [])):
        await enviar_pregunta(chat_id, context)
        return

    actual = quiz.get("current")
    if not actual:
        await enviar_pregunta(chat_id, context)
        return

    q = quiz["questions"][quiz["i"]]
    total_original = quiz.get("total_original", len(quiz["questions"]))
    respondidas_previas = quiz.get("respondidas_count", 0)
    numero_pregunta = respondidas_previas + quiz["i"] + 1
    encabezado = f"📍 Pregunta {numero_pregunta}/{total_original}"
    texto_pregunta = wrap_text(q["text"].strip())
    texto = construir_texto_pregunta(encabezado, texto_pregunta, actual.get("options", []))

    botones = [
        [InlineKeyboardButton(ensanchar_etiqueta_opcion(o), callback_data=str(idx))]
        for idx, o in enumerate(actual.get("options", []))
    ]
    botones.append(
        [
            InlineKeyboardButton(
                "🧾 Editar pregunta",
                callback_data=f"editar_pregunta_json_{q['id']}",
            ),
            InlineKeyboardButton("☰ Menú", callback_data="menu"),
        ]
    )

    await context.bot.send_message(
        chat_id,
        texto,
        reply_markup=InlineKeyboardMarkup(botones),
    )
    programar_temporizador_pregunta(context, chat_id, quiz["i"], q["id"])


# ─────────────── Botones ───────────────
async def handle_button(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    data = query.data
    chat_id = query.message.chat.id

    if data == "ver_mas":
        quiz = context.user_data.get("quiz")
        if not quiz:
            return
        i = quiz.get("i", 0)
        if i >= len(quiz.get("questions", [])):
            return
        q = quiz["questions"][i]
        current = quiz.get("current", {})
        opciones = current.get("options", [])
        texto_pregunta = wrap_text(q["text"].strip())
        total_original = quiz.get("total_original", len(quiz["questions"]))
        respondidas_previas = quiz.get("respondidas_count", 0)
        numero_pregunta = respondidas_previas + i + 1
        texto_expandido = construir_texto_pregunta(
            f"📍 Pregunta {numero_pregunta}/{total_original}",
            texto_pregunta,
            opciones,
        )
        botones = [
            [InlineKeyboardButton(ensanchar_etiqueta_opcion(o), callback_data=str(idx))]
            for idx, o in enumerate(opciones)
        ]
        botones.append([InlineKeyboardButton("🧾 Editar pregunta", callback_data=f"editar_pregunta_json_{q['id']}")])
        botones.append([InlineKeyboardButton("☰ Menú", callback_data="menu")])
        await query.message.edit_text(
            texto_expandido,
            reply_markup=None,
        )
    elif data == "crear_test":
        context.user_data["modo"] = "crear_test_nombre"
        context.user_data["nuevo_test"] = {}
        await query.message.reply_text("🧩 Escribe el nombre del test:")
    elif data == "subir_zip":
        context.user_data["modo"] = "subir_zip"
        await query.message.reply_text(
            "📦 Envía un archivo .zip con los tests.\n\n"
            "Cada archivo .json dentro del ZIP se creará como un test independiente.\n"
            "• El nombre del test será el nombre del archivo (sin extensión).\n"
            "• Si el JSON incluye una clave \"descripcion\", se usará como descripción.\n"
            "• El formato del JSON es el mismo que para crear un test normal.\n\n"
            "Los archivos que no sean .json se ignorarán."
        )
    elif data == "mis_tests":
        await mostrar_tests(chat_id, context, pagina=1)
    elif data == "borrar_tests":
        await mostrar_tests_para_borrar(chat_id, context, pagina=1)
    elif data == "descargar_tests":
        await mostrar_tests_para_descargar(chat_id, context, pagina=1)
    elif data == "descargar_todos_tests":
        await enviar_tests_como_zip(chat_id, context)
    elif data == "tests_favoritos":
        await mostrar_tests_favoritos(chat_id, context, pagina=1)
    elif data.startswith("mis_tests_pagina_"):
        pagina = int(data.split("_")[3])
        await mostrar_tests(chat_id, context, pagina=pagina)
    elif data.startswith("tests_favoritos_pagina_"):
        pagina = int(data.split("_")[3])
        await mostrar_tests_favoritos(chat_id, context, pagina=pagina)
    elif data.startswith("borrar_tests_pagina_"):
        pagina = int(data.split("_")[3])
        await mostrar_tests_para_borrar(chat_id, context, pagina=pagina)
    elif data.startswith("descargar_test_pagina_"):
        pagina = int(data.split("_")[3])
        await mostrar_tests_para_descargar(chat_id, context, pagina=pagina)
    elif data.startswith("favorito_test_"):
        quiz_id = int(data.split("_")[-1])
        user_id = get_or_create_user(chat_id)
        if es_test_favorito(user_id, quiz_id):
            quitar_test_favorito(user_id, quiz_id)
            await query.message.reply_text("✅ Test quitado de favoritos.")
        else:
            marcar_test_favorito(user_id, quiz_id)
            await query.message.reply_text("✅ Test guardado en favoritos.")
        pagina = context.user_data.get("pagina_tests", 1)
        await mostrar_tests(chat_id, context, pagina=pagina)
    elif data.startswith("empezar_"):
        quiz_id = int(data.split("_")[1])
        user_id = get_or_create_user(chat_id)
        quiz_en_curso = context.user_data.get("quiz")
        # Primero comprobar estado en memoria
        reanudable_memoria = obtener_quiz_reanudable(quiz_en_curso, quiz_id)
        # Si no hay en memoria, comprobar en BD
        reanudable_bd = False
        if not reanudable_memoria:
            intento_db = obtener_intento_pendiente(user_id, quiz_id)
            if intento_db:
                reanudable_bd = True
        if reanudable_memoria or reanudable_bd:
            context.user_data["quiz_pendiente"] = {
                "quiz_id": quiz_id,
                "telegram_user_id": query.from_user.id,
                "desde_bd": reanudable_bd and not reanudable_memoria,
            }
            guardar_contexto_cancelable(
                context,
                {
                    "tipo": "lista_tests",
                    "pagina": context.user_data.get("pagina_tests", 1),
                },
            )
            botones = InlineKeyboardMarkup(
                [
                    [
                        InlineKeyboardButton(
                            "▶️ Continuar donde lo dejé",
                            callback_data="continuar_test_pendiente",
                        )
                    ],
                    [
                        InlineKeyboardButton(
                            "🔄 Empezar de nuevo",
                            callback_data="reiniciar_test_pendiente",
                        )
                    ],
                    [
                        InlineKeyboardButton(
                            "↩️ Cancelar",
                            callback_data="cancelar_reanudar_test",
                        )
                    ],
                ]
            )
            await query.message.reply_text(
                "Tienes este test a medias. ¿Qué quieres hacer?",
                reply_markup=botones,
            )
        else:
            await iniciar_quiz(
                chat_id,
                context,
                quiz_id=quiz_id,
                attempt_type="quiz",
                telegram_user_id=query.from_user.id,
            )
    elif data == "continuar_test_pendiente":
        pendiente = context.user_data.pop("quiz_pendiente", None)
        if not pendiente:
            await query.message.reply_text("No hay ningún test pendiente para continuar.")
            return
        tipo_pendiente = pendiente.get("tipo", "quiz")
        if pendiente.get("desde_bd") and tipo_pendiente == "quiz":
            # Reconstruir estado desde la BD
            user_id = get_or_create_user(chat_id)
            quiz_reconstruido = reconstruir_quiz_desde_db(
                user_id, pendiente["quiz_id"], pendiente["telegram_user_id"]
            )
            if not quiz_reconstruido:
                await query.message.reply_text("No se pudo recuperar el test pendiente.")
                await mostrar_menu(chat_id, context)
                return
            cerrar_intento_en_curso(context)
            context.user_data["quiz"] = quiz_reconstruido
            total = quiz_reconstruido["total_original"]
            respondidas = quiz_reconstruido["respondidas_count"]
            await query.message.reply_text(
                f"▶️ Reanudando test: {respondidas}/{total} preguntas respondidas "
                f"(✔️ {quiz_reconstruido['ok']} ❌ {quiz_reconstruido['fail']})"
            )
            await enviar_pregunta(chat_id, context)
        elif pendiente.get("desde_bd") and tipo_pendiente in {"failures", "favoritas"}:
            user_id = get_or_create_user(chat_id)
            quiz_reconstruido = reconstruir_test_temporal_desde_db(
                user_id, tipo_pendiente, pendiente["telegram_user_id"]
            )
            if not quiz_reconstruido:
                await query.message.reply_text("No se pudo recuperar el test pendiente.")
                await mostrar_menu(chat_id, context)
                return
            cerrar_intento_en_curso(context)
            context.user_data["quiz"] = quiz_reconstruido
            total = quiz_reconstruido["total_original"]
            respondidas = quiz_reconstruido["respondidas_count"]
            await query.message.reply_text(
                f"▶️ Reanudando test: {respondidas}/{total} preguntas respondidas "
                f"(✔️ {quiz_reconstruido['ok']} ❌ {quiz_reconstruido['fail']})"
            )
            await enviar_pregunta(chat_id, context)
        else:
            await mostrar_pregunta_actual(chat_id, context)
    elif data == "reiniciar_test_pendiente":
        pendiente = context.user_data.pop("quiz_pendiente", None)
        if not pendiente:
            await query.message.reply_text("No hay ningún test pendiente para reiniciar.")
            return
        user_id = get_or_create_user(chat_id)
        tipo_pendiente = pendiente.get("tipo", "quiz")
        cerrar_intento_en_curso(context)
        # También cerrar intentos pendientes en BD
        if tipo_pendiente == "quiz":
            descartar_intentos_pendientes(user_id, pendiente["quiz_id"])
            await iniciar_quiz(
                chat_id,
                context,
                quiz_id=pendiente["quiz_id"],
                attempt_type="quiz",
                telegram_user_id=pendiente.get("telegram_user_id"),
            )
        else:
            descartar_intentos_pendientes_por_tipo(user_id, tipo_pendiente)
            await iniciar_test_temporal(
                chat_id,
                context,
                tipo_intento=tipo_pendiente,
                telegram_user_id=pendiente.get("telegram_user_id"),
                forzar_nuevo=True,
            )
    elif data == "cancelar_reanudar_test":
        context.user_data.pop("quiz_pendiente", None)
        await query.message.reply_text("Operación cancelada.")
        await volver_a_contexto_anterior(chat_id, context)
    elif data.startswith("borrar_"):
        quiz_id = int(data.split("_")[1])
        titulo = obtener_titulo_test(quiz_id) or "este test"
        botones = [
            [
                InlineKeyboardButton(
                    "✅ Confirmar borrado", callback_data=f"confirmar_borrar_{quiz_id}"
                ),
                InlineKeyboardButton("↩️ Cancelar", callback_data="cancelar_borrar"),
            ]
        ]
        await query.message.reply_text(
            f"⚠️ ¿Seguro que quieres borrar {titulo}?",
            reply_markup=InlineKeyboardMarkup(botones),
        )
        guardar_contexto_cancelable(
            context,
            {
                "tipo": "lista_borrado_tests",
                "pagina": context.user_data.get("pagina_borrado_tests", 1),
            },
        )
    elif data.startswith("confirmar_borrar_"):
        quiz_id = int(data.split("_")[2])
        borrar_test(quiz_id)
        await query.message.reply_text("🗑️ Test borrado.")
        pagina = context.user_data.get("pagina_borrado_tests", 1)
        await mostrar_tests_para_borrar(chat_id, context, pagina=pagina)
    elif data.startswith("descargar_test_"):
        quiz_id = int(data.split("_")[-1])
        await enviar_test_como_json(chat_id, context, quiz_id)
        pagina = context.user_data.get("pagina_descarga_tests", 1)
        await mostrar_tests_para_descargar(chat_id, context, pagina=pagina)
    elif data == "cancelar_borrar":
        await query.message.reply_text("Operación cancelada.")
        await volver_a_contexto_anterior(chat_id, context)
    elif data == "progreso":
        await mostrar_progreso(chat_id, context)
    elif data == "test_fallos":
        user_id = get_or_create_user(chat_id)
        quiz_en_curso = context.user_data.get("quiz")
        reanudable_memoria = obtener_test_temporal_reanudable(quiz_en_curso, "failures")
        reanudable_bd = False
        if not reanudable_memoria:
            reanudable_bd = (
                obtener_intento_pendiente_por_tipo(user_id, "failures") is not None
            )
        if reanudable_memoria or reanudable_bd:
            context.user_data["quiz_pendiente"] = {
                "tipo": "failures",
                "telegram_user_id": query.from_user.id,
                "desde_bd": reanudable_bd and not reanudable_memoria,
            }
            botones = InlineKeyboardMarkup(
                [
                    [
                        InlineKeyboardButton(
                            "▶️ Continuar donde lo dejé",
                            callback_data="continuar_test_pendiente",
                        )
                    ],
                    [
                        InlineKeyboardButton(
                            "🔄 Empezar de nuevo",
                            callback_data="reiniciar_test_pendiente",
                        )
                    ],
                    [
                        InlineKeyboardButton(
                            "↩️ Cancelar",
                            callback_data="cancelar_reanudar_test",
                        )
                    ],
                ]
            )
            await query.message.reply_text(
                "Tienes este test de errores a medias. ¿Qué quieres hacer?",
                reply_markup=botones,
            )
        else:
            await iniciar_test_fallos(
                chat_id, context, telegram_user_id=query.from_user.id
            )
    elif data == "test_favoritas":
        user_id = get_or_create_user(chat_id)
        quiz_en_curso = context.user_data.get("quiz")
        reanudable_memoria = obtener_test_temporal_reanudable(quiz_en_curso, "favoritas")
        reanudable_bd = False
        if not reanudable_memoria:
            reanudable_bd = (
                obtener_intento_pendiente_por_tipo(user_id, "favoritas") is not None
            )
        if reanudable_memoria or reanudable_bd:
            context.user_data["quiz_pendiente"] = {
                "tipo": "favoritas",
                "telegram_user_id": query.from_user.id,
                "desde_bd": reanudable_bd and not reanudable_memoria,
            }
            botones = InlineKeyboardMarkup(
                [
                    [
                        InlineKeyboardButton(
                            "▶️ Continuar donde lo dejé",
                            callback_data="continuar_test_pendiente",
                        )
                    ],
                    [
                        InlineKeyboardButton(
                            "🔄 Empezar de nuevo",
                            callback_data="reiniciar_test_pendiente",
                        )
                    ],
                    [
                        InlineKeyboardButton(
                            "↩️ Cancelar",
                            callback_data="cancelar_reanudar_test",
                        )
                    ],
                ]
            )
            await query.message.reply_text(
                "Tienes este test de favoritas a medias. ¿Qué quieres hacer?",
                reply_markup=botones,
            )
        else:
            await iniciar_test_favoritas(
                chat_id, context, telegram_user_id=query.from_user.id
            )
    elif data == "simulacro_sin_contestar":
        quiz = context.user_data.get("quiz")
        if not quiz or quiz.get("attempt_type") != "simulacro":
            return
        current = quiz.get("current")
        if not current or quiz.get("esperando_siguiente"):
            return
        cancelar_temporizador_pregunta(context)
        pregunta_id = current["question_id"]
        quiz["sin_responder"] = quiz.get("sin_responder", 0) + 1
        add_attempt_item(quiz["attempt_id"], pregunta_id, "Sin respuesta", False)
        await query.message.reply_text("⏭️ Pregunta dejada sin contestar.")
        quiz["esperando_siguiente"] = True
        quiz["ultimo_pregunta_id"] = pregunta_id
        await mostrar_opciones_post_respuesta(chat_id, context, pregunta_id)
    elif data == "siguiente_pregunta":
        quiz = context.user_data.get("quiz")
        if not quiz or not quiz.get("esperando_siguiente"):
            return
        quiz["esperando_siguiente"] = False
        quiz["ultimo_pregunta_id"] = None
        quiz["i"] += 1
        await enviar_pregunta(chat_id, context)
    elif data == "volver_pregunta":
        context.user_data.pop("modo", None)
        context.user_data.pop("pregunta_json_id", None)
        context.user_data.pop("pregunta_explicacion_id", None)
        quiz = context.user_data.get("quiz")
        if not quiz:
            return
        pregunta_id = quiz.get("ultimo_pregunta_id")
        if pregunta_id:
            await mostrar_opciones_post_respuesta(chat_id, context, pregunta_id)
        else:
            await mostrar_pregunta_actual(chat_id, context)
    elif data == "descargar_bd":
        await enviar_bd(chat_id, context)
    elif data == "menu_simulacros":
        await mostrar_menu_simulacros(chat_id, context)
    elif data == "anadir_simulacro":
        context.user_data["simulacro_en_creacion"] = {}
        context.user_data["modo"] = "crear_simulacro_nombre"
        await query.message.reply_text(
            "🧪 Creación de simulacro." + "\n" + "Escribe el nombre del simulacro:"
        )
    elif data == "eliminar_simulacro":
        await mostrar_lista_simulacros(chat_id, context, modo_lista="eliminar")
    elif data == "hacer_simulacro":
        await mostrar_lista_simulacros(chat_id, context, modo_lista="hacer")
    elif data.startswith("eliminar_simulacro_"):
        simulacro_id = int(data.split("_")[-1])
        if eliminar_simulacro(simulacro_id):
            await query.message.reply_text("✅ Simulacro eliminado correctamente.")
        else:
            await query.message.reply_text("❌ No se encontró el simulacro.")
        await mostrar_menu_simulacros(chat_id, context)
    elif data.startswith("iniciar_simulacro_"):
        simulacro_id = int(data.split("_")[-1])
        simulacro = obtener_simulacro(simulacro_id)
        if not simulacro:
            await query.message.reply_text("❌ Simulacro no encontrado.")
            return
        await iniciar_quiz(
            chat_id,
            context,
            quiz_id=simulacro["quiz_id"],
            attempt_type="simulacro",
            telegram_user_id=query.from_user.id,
            configuracion_simulacro={
                "id": simulacro["id"],
                "nombre": simulacro["nombre"],
                "nota_corte_directa": simulacro["nota_corte_directa"],
                "escala_maxima": simulacro["escala_maxima"],
                "test_titulo": simulacro["test_titulo"],
            },
        )
    elif data == "menu":
        await mostrar_menu(chat_id, context)
    elif data.startswith("editar_pregunta_json_"):
        pregunta_id = int(data.split("_")[-1])
        payload_actual = obtener_pregunta_como_json(pregunta_id)
        if not payload_actual:
            await query.message.reply_text("❌ No se encontró la pregunta para editar.")
            return
        context.user_data["modo"] = "editar_pregunta_json"
        context.user_data["pregunta_json_id"] = pregunta_id
        guardar_contexto_cancelable(context, {"tipo": "pregunta_actual"})
        json_actual = json.dumps(payload_actual, ensure_ascii=False, indent=2)
        botones = InlineKeyboardMarkup(
            [
                [
                    InlineKeyboardButton(
                        "↩️ Volver a la pregunta", callback_data="volver_pregunta"
                    )
                ],
                [
                    InlineKeyboardButton(
                        "↩️ Cancelar", callback_data="cancelar_edicion_pregunta_json"
                    )
                ],
            ]
        )
        await query.message.reply_text(
            "🧾 Edición de pregunta en JSON.\n"
            "Te envío la pregunta actual para que la edites y la reenvíes:\n\n"
            f"```json\n{json_actual}\n```",
            reply_markup=botones,
        )
    elif data == "cancelar_edicion_pregunta_json":
        context.user_data.pop("modo", None)
        context.user_data.pop("pregunta_json_id", None)
        await query.message.reply_text(
            "Operación cancelada.",
            reply_markup=obtener_markup_volver_pregunta(),
        )
    elif data.startswith("explicacion_"):
        pregunta_id = int(data.split("_")[1])
        contexto_explicacion = obtener_explicacion_pregunta(pregunta_id)
        context.user_data["modo"] = "editar_explicacion"
        context.user_data["pregunta_explicacion_id"] = pregunta_id
        guardar_contexto_cancelable(context, {"tipo": "pregunta_actual"})
        botones = InlineKeyboardMarkup(
            [
                [
                    InlineKeyboardButton(
                        "↩️ Volver a la pregunta", callback_data="volver_pregunta"
                    )
                ],
                [InlineKeyboardButton("↩️ Cancelar", callback_data="cancelar_explicacion")],
            ]
        )
        if contexto_explicacion:
            await query.message.reply_text(
                "📝 Explicación actual:\n"
                f"{contexto_explicacion}\n\n"
                "Escribe la nueva explicación, pega una URL/nombre de fichero "
                "o adjunta un archivo para guardarlo como enlace HTTPS:",
                reply_markup=botones,
            )
        else:
            await query.message.reply_text(
                "📝 Esta pregunta no tiene explicación.\n"
                "Escribe una explicación, pega una URL/nombre de fichero "
                "o adjunta un archivo para guardar el enlace HTTPS:",
                reply_markup=botones,
            )
    elif data == "cancelar_explicacion":
        context.user_data.pop("modo", None)
        context.user_data.pop("pregunta_explicacion_id", None)
        await query.message.reply_text(
            "Operación cancelada.",
            reply_markup=obtener_markup_volver_pregunta(),
        )
    elif data.startswith("ver_explicacion_"):
        pregunta_id = int(data.split("_")[2])
        explicacion = obtener_explicacion_pregunta(pregunta_id)
        if explicacion:
            await query.message.reply_text(
                f"📖 Explicación:\n{explicacion}",
                reply_markup=obtener_markup_volver_pregunta(),
            )
        else:
            await query.message.reply_text(
                "ℹ️ Esta pregunta no tiene explicación guardada.",
                reply_markup=obtener_markup_volver_pregunta(),
            )
    elif data.startswith("eliminar_pregunta_"):
        pregunta_id = int(data.split("_")[2])
        botones = InlineKeyboardMarkup(
            [
                [
                    InlineKeyboardButton(
                        "✅ Confirmar eliminación",
                        callback_data=f"confirmar_eliminar_pregunta_{pregunta_id}",
                    ),
                    InlineKeyboardButton(
                        "↩️ Cancelar", callback_data=f"cancelar_eliminar_pregunta_{pregunta_id}"
                    ),
                ]
            ]
        )
        await query.message.reply_text(
            "⚠️ ¿Seguro que quieres eliminar esta pregunta?",
            reply_markup=botones,
        )
    elif data.startswith("confirmar_eliminar_pregunta_"):
        pregunta_id = int(data.split("_")[3])
        se_borro = borrar_pregunta(pregunta_id)
        if not se_borro:
            await query.message.reply_text("❌ No se encontró la pregunta para eliminar.")
            return
        sincronizar_borrado_pregunta_en_quiz(context, pregunta_id)
        await query.message.reply_text("🗑️ Pregunta eliminada correctamente.")
        quiz = context.user_data.get("quiz")
        if quiz:
            quiz["esperando_siguiente"] = False
            await enviar_pregunta(chat_id, context)
        else:
            await mostrar_menu(chat_id, context)
    elif data.startswith("cancelar_eliminar_pregunta_"):
        pregunta_id = int(data.split("_")[3])
        await query.message.reply_text("Operación cancelada.")
        quiz = context.user_data.get("quiz")
        if quiz and quiz.get("esperando_siguiente"):
            await mostrar_opciones_post_respuesta(chat_id, context, pregunta_id)
    elif data.startswith("favorita_"):
        quiz = context.user_data.get("quiz", {})
        user_id = quiz.get("user_id") or get_or_create_user(chat_id)
        pregunta_id = int(data.split("_")[1])
        if es_pregunta_favorita(user_id, pregunta_id):
            quitar_favorita(user_id, pregunta_id)
            await query.message.reply_text("✅ Pregunta quitada de favoritas.")
        else:
            agregar_favorita(user_id, pregunta_id)
            await query.message.reply_text("✅ Pregunta guardada en favoritas.")
        if quiz.get("esperando_siguiente"):
            await mostrar_opciones_post_respuesta(chat_id, context, pregunta_id)


# ─────────────── Texto pegado ───────────────
async def handle_text(update: Update, context: ContextTypes.DEFAULT_TYPE):
    modo = context.user_data.get("modo")
    if modo == "editar_explicacion":
        explicacion = update.message.text.strip()
        if not explicacion:
            await update.message.reply_text("❌ La explicación no puede estar vacía.")
            return
        pregunta_id = context.user_data.pop("pregunta_explicacion_id", None)
        context.user_data.pop("modo", None)
        if not pregunta_id:
            await update.message.reply_text("❌ No se pudo identificar la pregunta.")
            return
        url_archivo = construir_url_archivo_desde_texto(explicacion)
        if url_archivo:
            actualizar_explicacion_pregunta(pregunta_id, url_archivo)
            await update.message.reply_text(
                "✅ Explicación guardada como enlace HTTPS.",
                reply_markup=obtener_markup_volver_pregunta(),
            )
            return
        actualizar_explicacion_pregunta(pregunta_id, explicacion)
        await update.message.reply_text(
            "✅ Explicación guardada.",
            reply_markup=obtener_markup_volver_pregunta(),
        )
    elif modo == "editar_pregunta_json":
        pregunta_id = context.user_data.get("pregunta_json_id")
        if not pregunta_id:
            context.user_data.pop("modo", None)
            await update.message.reply_text("❌ No se pudo identificar la pregunta.")
            return
        texto = (update.message.text or "").strip()
        if not texto:
            await update.message.reply_text("❌ Debes enviar un JSON válido.")
            return
        try:
            payload = json.loads(texto)
        except json.JSONDecodeError:
            await update.message.reply_text("❌ JSON inválido. Revisa el formato e inténtalo de nuevo.")
            return
        if isinstance(payload, dict) and isinstance(payload.get("preguntas"), list):
            preguntas = payload.get("preguntas")
            if len(preguntas) != 1:
                await update.message.reply_text(
                    "❌ Para editar una pregunta debes enviar un único objeto pregunta."
                )
                return
            payload = preguntas[0]
        if isinstance(payload, list):
            if len(payload) != 1:
                await update.message.reply_text(
                    "❌ Para editar una pregunta debes enviar una lista con un solo elemento."
                )
                return
            payload = payload[0]
        if not isinstance(payload, dict):
            await update.message.reply_text(
                "❌ El contenido debe ser un objeto JSON con la pregunta."
            )
            return

        try:
            pregunta_actualizada = actualizar_pregunta_desde_json(pregunta_id, payload)
        except ValueError as error:
            await update.message.reply_text(f"❌ {error}")
            return

        pregunta_reiniciada = sincronizar_pregunta_en_quiz(
            context, pregunta_id, pregunta_actualizada
        )
        context.user_data.pop("modo", None)
        context.user_data.pop("pregunta_json_id", None)
        if pregunta_reiniciada:
            mensaje = (
                "✅ Pregunta actualizada correctamente desde JSON.\n"
                "🔄 Como ya estaba respondida, se reinició su resultado para que cuente "
                "la respuesta de la pregunta modificada."
            )
        else:
            mensaje = "✅ Pregunta actualizada correctamente desde JSON."
        await update.message.reply_text(
            mensaje,
            reply_markup=obtener_markup_volver_pregunta(),
        )
    elif modo == "crear_simulacro_nombre":
        nombre = (update.message.text or "").strip()
        if not nombre:
            await update.message.reply_text("❌ El nombre del simulacro no puede estar vacío.")
            return
        simulacro = context.user_data.get("simulacro_en_creacion") or {}
        simulacro["nombre"] = nombre
        context.user_data["simulacro_en_creacion"] = simulacro
        context.user_data["modo"] = "crear_simulacro_json"
        context.user_data.setdefault("buffer", "")
        await update.message.reply_text(
            "📦 Ahora envía las preguntas del simulacro en JSON." + "\n"
            + "Puedes pegar el JSON directamente, adjuntar un archivo .json/.txt," + "\n"
            + "o adjuntar un .zip con varios .json para crear varios simulacros de una vez." + "\n"
            + "Cuando termines de pegar texto escribe: /fin"
        )
    elif modo == "crear_simulacro_json":
        context.user_data.setdefault("buffer", "")
        texto = update.message.text
        if texto and texto.strip().startswith(("{", "[")):
            creado = await procesar_texto_json_simulacro(
                texto, update, context, mostrar_error=False
            )
            if creado:
                return
        if texto:
            context.user_data["buffer"] += texto + "\n"
    elif modo == "crear_test_nombre":
        nombre = update.message.text.strip()
        if not nombre:
            await update.message.reply_text("❌ El nombre no puede estar vacío.")
            return
        context.user_data["nuevo_test"]["titulo"] = nombre
        context.user_data["modo"] = "crear_test_descripcion"
        await update.message.reply_text("📝 Escribe la descripción del test:")
    elif modo == "crear_test_descripcion":
        descripcion = update.message.text.strip()
        if not descripcion:
            await update.message.reply_text("❌ La descripción no puede estar vacía.")
            return
        context.user_data["nuevo_test"]["descripcion"] = descripcion
        context.user_data["modo"] = "crear_test_json"
        context.user_data.setdefault("buffer", "")
        await update.message.reply_text(
            "📦 Pega el JSON de preguntas con el formato indicado.\n"
            "Puedes enviar una lista de preguntas o un objeto con la clave preguntas.\n"
            "La respuesta correcta será siempre la primera opción.\n"
            "Cada pregunta incluye bloque, tema y opcionalmente explicacion.\n"
            "También puedes adjuntar un archivo .json o .txt con el JSON completo.\n"
            "Cuando termines escribe: /fin"
        )
    elif modo == "crear_test_json":
        context.user_data.setdefault("buffer", "")
        texto = update.message.text
        if texto and texto.strip().startswith(("{", "[")):
            creado = await procesar_texto_json(
                texto, update, context, mostrar_error=False
            )
            if creado:
                return
        context.user_data["buffer"] += texto + "\n"


async def fin(update: Update, context: ContextTypes.DEFAULT_TYPE):
    modo = context.user_data.get("modo")
    if modo == "crear_test_json":
        text = context.user_data.pop("buffer", "")
        await procesar_texto_json(text, update, context)
        return
    if modo == "crear_simulacro_json":
        text = context.user_data.pop("buffer", "")
        await procesar_texto_json_simulacro(text, update, context)


async def handle_document(update: Update, context: ContextTypes.DEFAULT_TYPE):
    modo = context.user_data.get("modo")
    if modo == "subir_zip":
        documento = update.message.document
        if not documento:
            return
        nombre_archivo = (documento.file_name or "").lower()
        if not nombre_archivo.endswith(".zip"):
            await update.message.reply_text(
                "❌ Formato no válido. Adjunta un archivo .zip."
            )
            return
        archivo = await documento.get_file()
        contenido = await archivo.download_as_bytearray()
        try:
            zip_buffer = io.BytesIO(contenido)
            with zipfile.ZipFile(zip_buffer) as zf:
                archivos_json = [
                    n for n in zf.namelist()
                    if n.lower().endswith(".json") and not n.startswith("__MACOSX")
                ]
                if not archivos_json:
                    await update.message.reply_text(
                        "❌ El ZIP no contiene archivos .json."
                    )
                    return
                creados = 0
                errores = []
                for nombre in archivos_json:
                    nombre_base = os.path.basename(nombre)
                    titulo = os.path.splitext(nombre_base)[0]
                    if not titulo:
                        continue
                    try:
                        texto = zf.read(nombre).decode("utf-8", errors="replace")
                        payload = json.loads(texto)
                        if isinstance(payload, list):
                            preguntas = payload
                            descripcion = ""
                        elif isinstance(payload, dict):
                            preguntas = payload.get("preguntas")
                            if isinstance(preguntas, list):
                                descripcion = payload.get("descripcion") or ""
                            else:
                                preguntas = []
                                descripcion = ""
                        else:
                            preguntas = []
                            descripcion = ""
                        if not preguntas:
                            errores.append(f"⚠️ {nombre_base}: sin preguntas válidas")
                            continue
                        quiz_id = create_quiz(
                            {"preguntas": preguntas},
                            titulo=titulo,
                            descripcion=descripcion or None,
                        )
                        if quiz_id:
                            creados += 1
                        else:
                            errores.append(f"⚠️ {nombre_base}: no se pudo crear")
                    except json.JSONDecodeError:
                        errores.append(f"❌ {nombre_base}: JSON inválido")
                    except Exception as e:
                        errores.append(f"❌ {nombre_base}: {e}")
                resumen = "📦 Resultado de la importación" + "\n" + f"✅ {creados} test(s) creado(s)"
                if errores:
                    resumen += "\n" + f"⚠️ {len(errores)} error(es):" + "\n" + "\n".join(errores)
                await update.message.reply_text(resumen)
        except zipfile.BadZipFile:
            await update.message.reply_text("❌ El archivo no es un ZIP válido.")
        except Exception as e:
            await update.message.reply_text(f"❌ Error procesando el ZIP: {e}")
        context.user_data.pop("modo", None)
        await mostrar_menu(update.message.chat.id, context)
        return

    if modo == "crear_test_json":
        documento = update.message.document
        if not documento:
            return
        nombre_archivo = (documento.file_name or "").lower()
        if not (nombre_archivo.endswith(".json") or nombre_archivo.endswith(".txt")):
            await update.message.reply_text(
                "❌ Formato no válido. Adjunta un archivo .json o .txt."
            )
            return
        archivo = await documento.get_file()
        contenido = await archivo.download_as_bytearray()
        texto = contenido.decode("utf-8", errors="replace")
        await procesar_texto_json(texto, update, context)
        return

    if modo == "crear_simulacro_json":
        documento = update.message.document
        if not documento:
            return
        nombre_archivo = (documento.file_name or "").lower()
        archivo = await documento.get_file()
        contenido = await archivo.download_as_bytearray()

        if nombre_archivo.endswith(".zip"):
            try:
                zip_buffer = io.BytesIO(contenido)
                with zipfile.ZipFile(zip_buffer) as zf:
                    archivos_json = [
                        n for n in zf.namelist()
                        if n.lower().endswith(".json") and not n.startswith("__MACOSX")
                    ]
                    if not archivos_json:
                        await update.message.reply_text("❌ El ZIP no contiene archivos .json.")
                        return
                    creados = 0
                    errores = []
                    for nombre in archivos_json:
                        nombre_base = os.path.basename(nombre)
                        nombre_simulacro = os.path.splitext(nombre_base)[0] or "Simulacro"
                        try:
                            texto = zf.read(nombre).decode("utf-8", errors="replace")
                            payload = json.loads(texto)
                            preguntas, titulo_payload = extraer_preguntas_desde_payload(payload)
                            if not preguntas:
                                errores.append(f"⚠️ {nombre_base}: sin preguntas válidas")
                                continue
                            simulacro_id, error = crear_test_y_simulacro_desde_preguntas(
                                preguntas,
                                titulo_payload or nombre_simulacro,
                            )
                            if error:
                                errores.append(f"⚠️ {nombre_base}: no se pudo crear")
                                continue
                            if simulacro_id:
                                creados += 1
                        except json.JSONDecodeError:
                            errores.append(f"❌ {nombre_base}: JSON inválido")
                        except Exception as e:
                            errores.append(f"❌ {nombre_base}: {e}")
                    resumen = "📦 Resultado de la importación de simulacros" + "\n" + f"✅ {creados} simulacro(s) creado(s)"
                    if errores:
                        resumen += "\n" + f"⚠️ {len(errores)} error(es):" + "\n" + "\n".join(errores)
                    await update.message.reply_text(resumen)
            except zipfile.BadZipFile:
                await update.message.reply_text("❌ El archivo no es un ZIP válido.")
            except Exception as e:
                await update.message.reply_text(f"❌ Error procesando el ZIP: {e}")
            context.user_data.pop("modo", None)
            context.user_data.pop("buffer", None)
            context.user_data.pop("simulacro_en_creacion", None)
            await mostrar_menu_simulacros(update.message.chat.id, context)
            return

        if not (nombre_archivo.endswith(".json") or nombre_archivo.endswith(".txt")):
            await update.message.reply_text(
                "❌ Formato no válido. Adjunta un archivo .json, .txt o .zip."
            )
            return

        texto = contenido.decode("utf-8", errors="replace")
        await procesar_texto_json_simulacro(texto, update, context)
        return

    if modo == "editar_pregunta_json":
        await update.message.reply_text(
            "❌ En este modo debes enviar texto JSON, no un archivo."
        )
        return
    if modo == "editar_explicacion":
        documento = update.message.document
        if not documento:
            return
        pregunta_id = context.user_data.pop("pregunta_explicacion_id", None)
        context.user_data.pop("modo", None)
        if not pregunta_id:
            await update.message.reply_text("❌ No se pudo identificar la pregunta.")
            return
        nombre_archivo, url = await guardar_documento_publico(documento)
        if not nombre_archivo or not url:
            await update.message.reply_text("❌ No se pudo guardar el archivo.")
            return
        descripcion = (update.message.caption or "").strip()
        if descripcion:
            explicacion = f"{descripcion}\n\n{url}"
        else:
            explicacion = url
        actualizar_explicacion_pregunta(pregunta_id, explicacion)
        await update.message.reply_text(
            "✅ Explicación actualizada con archivo.\n"
            f"📎 {nombre_archivo}\n"
            f"🌐 {url}",
            reply_markup=obtener_markup_volver_pregunta(),
        )
        return

# ─────────────── Mostrar tests ───────────────
async def mostrar_tests(chat_id, context, pagina=1):
    user_id = get_or_create_user(chat_id)
    total_tests = contar_tests()
    if total_tests == 0:
        await context.bot.send_message(chat_id, "No hay tests creados.")
        return

    total_paginas = max(1, ceil(total_tests / TAMANO_PAGINA_TESTS))
    pagina = max(1, min(pagina, total_paginas))
    desplazamiento = (pagina - 1) * TAMANO_PAGINA_TESTS
    quizzes = listar_tests_con_conteo_paginado(
        desplazamiento, TAMANO_PAGINA_TESTS
    )
    context.user_data["pagina_tests"] = pagina
    tests_realizados = obtener_tests_realizados(user_id)
    tests_pendientes = obtener_tests_pendientes(user_id)
    tests_favoritos = obtener_tests_favoritos(user_id)
    quizzes_ids = [q["id"] for q in quizzes]
    conteos_intentos = obtener_conteo_intentos_por_test(user_id, quizzes_ids)

    def icono_test(quiz_id):
        if quiz_id in tests_pendientes:
            return "⏳ "
        if quiz_id in tests_realizados:
            return "✅ "
        return ""

    botones = []
    for q in quizzes:
        icono_favorito = "⭐" if q["id"] in tests_favoritos else "☆"
        botones.append(
            [
                InlineKeyboardButton(
                    f"{conteos_intentos.get(q['id'], 0)} · {icono_test(q['id'])}"
                    f"{q['title']} ({q['total_preguntas']} preguntas)",
                    callback_data=f"empezar_{q['id']}",
                ),
                InlineKeyboardButton(
                    icono_favorito,
                    callback_data=f"favorito_test_{q['id']}",
                ),
            ]
        )

    if total_paginas > 1:
        fila_paginas = []
        if pagina > 1:
            fila_paginas.append(
                InlineKeyboardButton(
                    "⬅️ Anterior", callback_data=f"mis_tests_pagina_{pagina - 1}"
                )
            )
        if pagina < total_paginas:
            fila_paginas.append(
                InlineKeyboardButton(
                    "Siguiente ➡️", callback_data=f"mis_tests_pagina_{pagina + 1}"
                )
            )
        if fila_paginas:
            botones.append(fila_paginas)

    botones.append([InlineKeyboardButton("☰ Menú", callback_data="menu")])
    await context.bot.send_message(
        chat_id,
        f"Selecciona un test (página {pagina}/{total_paginas}):",
        reply_markup=InlineKeyboardMarkup(botones),
    )


async def mostrar_tests_favoritos(chat_id, context, pagina=1):
    user_id = get_or_create_user(chat_id)
    total_tests_favoritos = contar_tests_favoritos(user_id)
    if total_tests_favoritos == 0:
        await context.bot.send_message(chat_id, "No tienes tests favoritos guardados.")
        return

    total_paginas = max(1, ceil(total_tests_favoritos / TAMANO_PAGINA_TESTS))
    pagina = max(1, min(pagina, total_paginas))
    desplazamiento = (pagina - 1) * TAMANO_PAGINA_TESTS
    quizzes = listar_tests_favoritos_con_conteo_paginado(
        user_id,
        desplazamiento,
        TAMANO_PAGINA_TESTS,
    )
    context.user_data["pagina_tests_favoritos"] = pagina
    quizzes_ids = [q["id"] for q in quizzes]
    conteos_intentos = obtener_conteo_intentos_por_test(user_id, quizzes_ids)

    botones = [
        [
            InlineKeyboardButton(
                f"{conteos_intentos.get(q['id'], 0)} · ⭐ {q['title']} ({q['total_preguntas']} preguntas)",
                callback_data=f"empezar_{q['id']}",
            )
        ]
        for q in quizzes
    ]

    if total_paginas > 1:
        fila_paginas = []
        if pagina > 1:
            fila_paginas.append(
                InlineKeyboardButton(
                    "⬅️ Anterior",
                    callback_data=f"tests_favoritos_pagina_{pagina - 1}",
                )
            )
        if pagina < total_paginas:
            fila_paginas.append(
                InlineKeyboardButton(
                    "Siguiente ➡️",
                    callback_data=f"tests_favoritos_pagina_{pagina + 1}",
                )
            )
        if fila_paginas:
            botones.append(fila_paginas)

    botones.append([InlineKeyboardButton("☰ Menú", callback_data="menu")])
    await context.bot.send_message(
        chat_id,
        f"Selecciona un test favorito (página {pagina}/{total_paginas}):",
        reply_markup=InlineKeyboardMarkup(botones),
    )


async def mostrar_tests_para_borrar(chat_id, context, pagina=1):
    total_tests = contar_tests()
    if total_tests == 0:
        await context.bot.send_message(chat_id, "No hay tests para borrar.")
        return

    total_paginas = max(1, ceil(total_tests / TAMANO_PAGINA_TESTS))
    pagina = max(1, min(pagina, total_paginas))
    desplazamiento = (pagina - 1) * TAMANO_PAGINA_TESTS
    quizzes = listar_tests_con_conteo_paginado(
        desplazamiento, TAMANO_PAGINA_TESTS
    )
    context.user_data["pagina_borrado_tests"] = pagina

    botones = [
        [
            InlineKeyboardButton(
                f"{q['title']} ({q['total_preguntas']} preguntas)",
                callback_data=f"borrar_{q['id']}",
            )
        ]
        for q in quizzes
    ]

    if total_paginas > 1:
        fila_paginas = []
        if pagina > 1:
            fila_paginas.append(
                InlineKeyboardButton(
                    "⬅️ Anterior",
                    callback_data=f"borrar_tests_pagina_{pagina - 1}",
                )
            )
        if pagina < total_paginas:
            fila_paginas.append(
                InlineKeyboardButton(
                    "Siguiente ➡️",
                    callback_data=f"borrar_tests_pagina_{pagina + 1}",
                )
            )
        if fila_paginas:
            botones.append(fila_paginas)

    botones.append([InlineKeyboardButton("☰ Menú", callback_data="menu")])
    await context.bot.send_message(
        chat_id,
        f"Selecciona un test para borrar (página {pagina}/{total_paginas}):",
        reply_markup=InlineKeyboardMarkup(botones),
    )


async def mostrar_tests_para_descargar(chat_id, context, pagina=1):
    total_tests = contar_tests()
    if total_tests == 0:
        await context.bot.send_message(chat_id, "No hay tests para descargar.")
        return

    total_paginas = max(1, ceil(total_tests / TAMANO_PAGINA_TESTS))
    pagina = max(1, min(pagina, total_paginas))
    desplazamiento = (pagina - 1) * TAMANO_PAGINA_TESTS
    quizzes = listar_tests_con_conteo_paginado(
        desplazamiento, TAMANO_PAGINA_TESTS
    )
    context.user_data["pagina_descarga_tests"] = pagina

    botones = [
        [
            InlineKeyboardButton(
                f"{q['title']} ({q['total_preguntas']} preguntas)",
                callback_data=f"descargar_test_{q['id']}",
            )
        ]
        for q in quizzes
    ]

    if total_paginas > 1:
        fila_paginas = []
        if pagina > 1:
            fila_paginas.append(
                InlineKeyboardButton(
                    "⬅️ Anterior",
                    callback_data=f"descargar_test_pagina_{pagina - 1}",
                )
            )
        if pagina < total_paginas:
            fila_paginas.append(
                InlineKeyboardButton(
                    "Siguiente ➡️",
                    callback_data=f"descargar_test_pagina_{pagina + 1}",
                )
            )
        if fila_paginas:
            botones.append(fila_paginas)

    botones.append([InlineKeyboardButton("☰ Menú", callback_data="menu")])
    await context.bot.send_message(
        chat_id,
        f"Selecciona un test para descargar (página {pagina}/{total_paginas}):",
        reply_markup=InlineKeyboardMarkup(botones),
    )


# ─────────────── Tests ───────────────
async def iniciar_quiz(
    chat_id,
    context,
    quiz_id=None,
    attempt_type="quiz",
    telegram_user_id=None,
    configuracion_simulacro=None,
):
    user_id = get_or_create_user(chat_id)
    # Cerrar cualquier quiz en memoria antes de empezar uno nuevo
    cerrar_intento_en_curso(context)
    questions = load_quiz_questions(quiz_id)
    if not questions:
        await context.bot.send_message(chat_id, "❌ Test no encontrado o vacío.")
        await mostrar_menu(chat_id, context)
        return
    await context.bot.send_message(
        chat_id, f"🧪 Este test tiene {len(questions)} preguntas."
    )
    attempt_id = create_attempt(user_id, quiz_id, attempt_type)
    context.user_data["quiz"] = {
        "questions": questions,
        "quiz_id": quiz_id,
        "i": 0,
        "ok": 0,
        "fail": 0,
        "sin_responder": 0,
        "attempt_id": attempt_id,
        "attempt_type": attempt_type,
        "user_id": user_id,
        "telegram_user_id": telegram_user_id,
        "simulacro": configuracion_simulacro,
    }
    await enviar_pregunta(chat_id, context)


async def iniciar_test_fallos(chat_id, context, telegram_user_id=None):
    await iniciar_test_temporal(
        chat_id,
        context,
        tipo_intento="failures",
        telegram_user_id=telegram_user_id,
    )


async def iniciar_test_favoritas(chat_id, context, telegram_user_id=None):
    await iniciar_test_temporal(
        chat_id,
        context,
        tipo_intento="favoritas",
        telegram_user_id=telegram_user_id,
    )


async def iniciar_test_temporal(
    chat_id, context, tipo_intento, telegram_user_id=None, forzar_nuevo=False
):
    user_id = get_or_create_user(chat_id)
    if forzar_nuevo:
        descartar_intentos_pendientes_por_tipo(user_id, tipo_intento)

    if tipo_intento == "failures":
        preguntas = get_failures_questions(user_id, TAMANO_TEST_TEMPORAL)
        mensaje_vacio = "No tienes fallos acumulados."
    else:
        preguntas = get_favorites_questions(user_id, TAMANO_TEST_TEMPORAL)
        mensaje_vacio = "No tienes preguntas favoritas guardadas."

    if not preguntas:
        await context.bot.send_message(chat_id, mensaje_vacio)
        return

    cerrar_intento_en_curso(context)
    attempt_id = create_attempt(user_id, None, tipo_intento)
    guardar_test_temporal(attempt_id, preguntas)
    context.user_data["quiz"] = {
        "questions": preguntas,
        "i": 0,
        "ok": 0,
        "fail": 0,
        "sin_responder": 0,
        "attempt_id": attempt_id,
        "attempt_type": tipo_intento,
        "user_id": user_id,
        "telegram_user_id": telegram_user_id,
        "total_original": len(preguntas),
        "respondidas_count": 0,
    }
    await enviar_pregunta(chat_id, context)


async def enviar_pregunta(chat_id, context):
    cancelar_temporizador_pregunta(context)
    quiz = context.user_data["quiz"]
    i = quiz["i"]
    total_original = quiz.get("total_original", len(quiz["questions"]))
    respondidas_previas = quiz.get("respondidas_count", 0)
    if i >= len(quiz["questions"]):
        penalizacion = PENALIZACION_FALLO * quiz["fail"]
        puntuacion_directa = max(quiz["ok"] - penalizacion, 0)
        finish_attempt(quiz["attempt_id"], quiz["ok"], quiz["fail"])
        if quiz.get("attempt_type") == "simulacro" and quiz.get("simulacro"):
            datos_simulacro = quiz["simulacro"]
            total_p2 = max(len(quiz["questions"]) - PREGUNTAS_PARTE_1_SIMULACRO, 0)
            aciertos_p1 = min(quiz["ok"], PREGUNTAS_PARTE_1_SIMULACRO)
            aciertos_p2 = max(quiz["ok"] - PREGUNTAS_PARTE_1_SIMULACRO, 0)
            errores_p1 = min(quiz["fail"], PREGUNTAS_PARTE_1_SIMULACRO - aciertos_p1)
            errores_p2 = max(quiz["fail"] - errores_p1, 0)

            resultado_tai = calcular_resultado_simulacro_tai(
                aciertos_p1, errores_p1, aciertos_p2, errores_p2,
                total_p1=PREGUNTAS_PARTE_1_SIMULACRO, total_p2=total_p2,
            )

            # Veredicto según escenarios
            if not resultado_tai["supera_minimo_30"]:
                veredicto = "❌ BAJO MÍNIMO (30%)"
            elif resultado_tai["aprobado_pesimista"]:
                veredicto = "✅ APTO (optimista y pesimista)"
            elif resultado_tai["aprobado_optimista"]:
                veredicto = "⚠️ FRONTERA (sólo escenario optimista)"
            else:
                veredicto = "❌ NO APTO"

            margen = resultado_tai["directa_total"] - resultado_tai["corte_media"]
            signo = "+" if margen >= 0 else ""

            lineas = [
                f"🏁 Fin del simulacro: {datos_simulacro['nombre']}",
                f"✔️ {quiz['ok']} · ❌ {quiz['fail']} · ⏭️ {quiz.get('sin_responder', 0)}",
                f"  Blancos P1: {resultado_tai['blancos_p1']} · Blancos P2: {resultado_tai['blancos_p2']}",
                "─" * 30,
                f"Directa P1  (A - E/3):     {resultado_tai['directa_p1']:>7.2f} / {PREGUNTAS_PARTE_1_SIMULACRO}",
                f"Directa P2  (4A - 4E/3):   {resultado_tai['directa_p2']:>7.2f} / {total_p2 * PUNTOS_ACIERTO_PARTE_2}",
                f"TOTAL DIRECTA:             {resultado_tai['directa_total']:>7.2f} / {N_MAX_SIMULACRO}",
                "─" * 30,
            ]
            if resultado_tai["corte_2024"] is not None:
                lineas.append(f"Corte 2024 ({PLAZAS_REFERENCIA_SIMULACRO} plazas): {resultado_tai['corte_2024']}")
            if resultado_tai["corte_2022"] is not None:
                lineas.append(f"Corte 2022 ({PLAZAS_REFERENCIA_SIMULACRO} plazas): {resultado_tai['corte_2022']}")
            lineas += [
                f"Rango corte: {resultado_tai['corte_optimista']} – {resultado_tai['corte_pesimista']}",
                f"Corte medio: {resultado_tai['corte_media']}",
                "─" * 30,
                f"TPS optimista:  {resultado_tai['tps_optimista']:>6.2f} / 100  {'✅' if resultado_tai['tps_optimista'] >= 50 else '❌'}",
                f"TPS medio:      {resultado_tai['tps_medio']:>6.2f} / 100  {'✅' if resultado_tai['tps_medio'] >= 50 else '❌'}",
                f"TPS pesimista:  {resultado_tai['tps_pesimista']:>6.2f} / 100  {'✅' if resultado_tai['tps_pesimista'] >= 50 else '❌'}",
                "─" * 30,
            ]
            if resultado_tai["pos_2024"] is not None:
                lineas.append(f"Posición est. 2024: #{resultado_tai['pos_2024']}")
            if resultado_tai["pos_2022"] is not None:
                lineas.append(f"Posición est. 2022: #{resultado_tai['pos_2022']}")
            lineas += [
                f"Margen vs corte medio: {signo}{margen:.2f} pts",
                f"Veredicto: {veredicto}",
            ]
            await context.bot.send_message(chat_id, "\n".join(lineas))
        else:
            nota = max((quiz["ok"] - PENALIZACION_FALLO * quiz["fail"]) / total_original * 10, 0)
            await context.bot.send_message(
                chat_id,
                f"🏁 Fin del test\n✔️ {quiz['ok']} ❌ {quiz['fail']}\n🎯 Nota: {nota:.2f}/10",
            )
        context.user_data.pop("quiz")
        await mostrar_menu(chat_id, context)
        return


    q = quiz["questions"][i]
    numero_pregunta = respondidas_previas + i + 1
    encabezado = f"📍 Pregunta {numero_pregunta}/{total_original}"
    texto_pregunta = wrap_text(q["text"].strip())

    options = list(q["options"])
    random.shuffle(options)
    correct_index = options.index(q["correct_text"])
    quiz["current"] = {
        "question_id": q["id"],
        "options": options,
        "correct_index": correct_index,
    }
    quiz["esperando_siguiente"] = False
    quiz["ultimo_pregunta_id"] = None

    mensaje_inicial = construir_texto_pregunta(encabezado, texto_pregunta)
    partes = split_message(mensaje_inicial)
    botones_enunciado = [[InlineKeyboardButton("👀 Ver más", callback_data="ver_mas")]]
    botones_opciones = [
        [InlineKeyboardButton(ensanchar_etiqueta_opcion(o), callback_data=str(idx))]
        for idx, o in enumerate(options)
    ]
    if quiz.get("attempt_type") == "simulacro":
        botones_opciones.append(
            [InlineKeyboardButton("⏭️ Dejar sin contestar", callback_data="simulacro_sin_contestar")]
        )
    botones_opciones.append(
        [
            InlineKeyboardButton(
                "🧾 Editar pregunta",
                callback_data=f"editar_pregunta_json_{q['id']}",
            ),
            InlineKeyboardButton("☰ Menú", callback_data="menu"),
        ]
    )

    for parte in partes[:-1]:
        await context.bot.send_message(chat_id, parte)
    await context.bot.send_message(
        chat_id,
        partes[-1],
        reply_markup=InlineKeyboardMarkup(botones_enunciado),
    )
    await context.bot.send_message(
        chat_id,
        "Opciones:",
        reply_markup=InlineKeyboardMarkup(botones_opciones),
    )
    programar_temporizador_pregunta(context, chat_id, i, q["id"])


def obtener_texto_boton_favorita(user_id, question_id):
    if es_pregunta_favorita(user_id, question_id):
        return "⭐ Quitar favorita"
    return "⭐ Guardar favorita"


def construir_botones_post_respuesta(user_id, question_id):
    explicacion_actual = obtener_explicacion_pregunta(question_id)
    filas = []
    if explicacion_actual:
        filas.append(
            [
                InlineKeyboardButton(
                    "👀 Ver explicación",
                    callback_data=f"ver_explicacion_{question_id}",
                )
            ]
        )
    filas.append(
        [
            InlineKeyboardButton(
                "✍️ Añadir/editar explicación",
                callback_data=f"explicacion_{question_id}",
            )
        ]
    )
    filas.append(
        [
            InlineKeyboardButton(
                "🧾 Editar pregunta",
                callback_data=f"editar_pregunta_json_{question_id}",
            )
        ]
    )
    filas.append(
        [
            InlineKeyboardButton(
                "🗑️ Eliminar pregunta",
                callback_data=f"eliminar_pregunta_{question_id}",
            )
        ]
    )
    filas.append(
        [
            InlineKeyboardButton(
                obtener_texto_boton_favorita(user_id, question_id),
                callback_data=f"favorita_{question_id}",
            )
        ]
    )
    filas.append(
        [
            InlineKeyboardButton(
                "➡️ Siguiente pregunta",
                callback_data="siguiente_pregunta",
            )
        ]
    )
    filas.append([InlineKeyboardButton("☰ Menú", callback_data="menu")])
    return InlineKeyboardMarkup(filas)


async def mostrar_opciones_post_respuesta(chat_id, context, question_id):
    quiz = context.user_data.get("quiz", {})
    user_id = quiz.get("user_id") or get_or_create_user(chat_id)
    markup = construir_botones_post_respuesta(user_id, question_id)
    await context.bot.send_message(
        chat_id,
        "📝 Opciones de la pregunta:",
        reply_markup=markup,
    )


def obtener_markup_volver_pregunta():
    return InlineKeyboardMarkup(
        [[InlineKeyboardButton("↩️ Volver a la pregunta", callback_data="volver_pregunta")]]
    )


# ─────────────── Responder ───────────────
async def responder(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    chat_id = query.message.chat.id

    quiz = context.user_data.get("quiz")
    if not quiz:
        return

    current = quiz.get("current")
    if not current:
        return

    if quiz.get("esperando_siguiente"):
        return

    cancelar_temporizador_pregunta(context)
    selected = int(query.data)
    correct_index = current["correct_index"]
    options = current["options"]
    question_id = current["question_id"]
    user_id = quiz["user_id"]

    if selected == correct_index:
        quiz["ok"] += 1
        respuesta = wrap_text(options[selected])
        await query.message.reply_text(f"✅ ¡Correcto!\nTu respuesta:\n{respuesta}")
        clear_failure(user_id, question_id)
        is_correct = True
    else:
        quiz["fail"] += 1
        resp = wrap_text(options[selected])
        correcta = wrap_text(options[correct_index])
        await query.message.reply_text(f"❌ Incorrecto!\nTu respuesta:\n{resp}")
        await query.message.reply_text(f"💡 Respuesta correcta:\n{correcta}")
        record_failure(user_id, question_id)
        is_correct = False

    add_attempt_item(quiz["attempt_id"], question_id, options[selected], is_correct)

    quiz["esperando_siguiente"] = True
    quiz["ultimo_pregunta_id"] = question_id
    await mostrar_opciones_post_respuesta(chat_id, context, question_id)


# ─────────────── Progreso ───────────────
async def mostrar_progreso(chat_id, context):
    user_id = get_or_create_user(chat_id)
    progreso_general = get_progreso_general(user_id)
    progreso_tests = get_progreso_por_tests(user_id)
    preguntas_respondidas_hoy = contar_preguntas_respondidas_hoy(user_id)

    mensaje = (
        "📈 Progreso general\n"
        f"Preguntas respondidas hoy: {preguntas_respondidas_hoy}\n"
        f"Aciertos totales: {progreso_general['total_correct']}\n"
        f"Fallos totales: {progreso_general['total_wrong']}\n"
        f"Nota general: {progreso_general['nota']:.2f}/10"
    )

    if not progreso_tests:
        mensaje += "\n\nNo hay intentos registrados todavía."
        botones = InlineKeyboardMarkup(
            [[InlineKeyboardButton("☰ Volver al menú", callback_data="menu")]]
        )
        await context.bot.send_message(chat_id, mensaje, reply_markup=botones)
        return

    detalles = ["\n\n📚 Progreso por test"]
    for test in progreso_tests:
        detalles.append(f"\n🧪 {test['titulo']}")
        for idx, intento in enumerate(test["intentos"], start=1):
            detalles.append(
                f"  Intento {idx}: ✔️ {intento['correct']} ❌ {intento['wrong']} "
                f"🎯 {intento['nota']:.2f}/10"
            )

    botones = InlineKeyboardMarkup(
        [[InlineKeyboardButton("☰ Volver al menú", callback_data="menu")]]
    )
    mensaje_completo = mensaje + "\n".join(detalles)
    partes_mensaje = split_message(mensaje_completo)

    for parte in partes_mensaje[:-1]:
        await context.bot.send_message(chat_id, parte)

    await context.bot.send_message(
        chat_id,
        partes_mensaje[-1],
        reply_markup=botones,
    )


# ─────────────── Descargar BD ───────────────
async def enviar_bd(chat_id, context):
    if not os.path.exists(DB_FILE):
        await context.bot.send_message(chat_id, "No hay base de datos todavía.")
        return
    with open(DB_FILE, "rb") as f:
        await context.bot.send_document(chat_id, document=f, filename="bot.db")


async def enviar_test_como_json(chat_id, context, quiz_id):
    payload = obtener_test_como_json(quiz_id)
    if not payload:
        await context.bot.send_message(chat_id, "❌ No se encontró el test.")
        return
    if not payload.get("preguntas"):
        await context.bot.send_message(chat_id, "❌ El test no tiene preguntas válidas.")
        return
    titulo = payload.get("titulo") or "test"
    nombre_base = normalizar_nombre_archivo_test(titulo)
    nombre_archivo = f"{nombre_base}.json"
    contenido = json.dumps(payload, ensure_ascii=False, indent=2)
    archivo = io.BytesIO(contenido.encode("utf-8"))
    archivo.name = nombre_archivo
    await context.bot.send_document(chat_id, document=archivo, filename=nombre_archivo)


async def enviar_tests_como_zip(chat_id, context):
    tests = listar_tests_con_conteo()
    if not tests:
        await context.bot.send_message(chat_id, "No hay tests para descargar.")
        return
    archivo_memoria = io.BytesIO()
    nombres_usados = {}
    total_archivos = 0
    with zipfile.ZipFile(archivo_memoria, "w", zipfile.ZIP_DEFLATED) as zipf:
        for test in tests:
            payload = obtener_test_como_json(test["id"])
            if not payload or not payload.get("preguntas"):
                continue
            titulo = payload.get("titulo") or test["title"] or "test"
            nombre_base = normalizar_nombre_archivo_test(titulo)
            contador = nombres_usados.get(nombre_base, 0) + 1
            nombres_usados[nombre_base] = contador
            if contador > 1:
                nombre_archivo = f"{nombre_base}_{contador}.json"
            else:
                nombre_archivo = f"{nombre_base}.json"
            contenido = json.dumps(payload, ensure_ascii=False, indent=2)
            zipf.writestr(nombre_archivo, contenido)
            total_archivos += 1
    if total_archivos == 0:
        await context.bot.send_message(
            chat_id, "No hay tests válidos para descargar."
        )
        return
    archivo_memoria.seek(0)
    archivo_memoria.name = "tests_completos.zip"
    await context.bot.send_document(
        chat_id, document=archivo_memoria, filename="tests_completos.zip"
    )


def asegurar_nombre_archivo_unico(ruta_directorio, nombre_archivo):
    base, extension = os.path.splitext(nombre_archivo)
    contador = 1
    nombre_final = nombre_archivo
    while os.path.exists(os.path.join(ruta_directorio, nombre_final)):
        nombre_final = f"{base}_{contador}{extension}"
        contador += 1
    return nombre_final


def construir_url_archivo(nombre_archivo):
    return f"{URL_PUBLICA_ARCHIVOS}/{quote(nombre_archivo)}"


def extraer_nombre_archivo_desde_texto(texto):
    texto = (texto or "").strip()
    if not texto:
        return None
    if "://" in texto:
        texto = urlparse(texto).path or ""
    texto = unquote(texto).strip().lstrip("/")
    nombre_archivo = os.path.basename(texto)
    if nombre_archivo in {"", ".", ".."}:
        return None
    return nombre_archivo


def construir_url_archivo_desde_texto(texto):
    nombre_archivo = extraer_nombre_archivo_desde_texto(texto)
    if not nombre_archivo:
        return None
    ruta_archivo = os.path.join(RUTA_ARCHIVOS_PUBLICOS, nombre_archivo)
    if not os.path.isfile(ruta_archivo):
        return None
    return construir_url_archivo(nombre_archivo)


async def guardar_documento_publico(documento):
    if not documento:
        return None, None
    os.makedirs(RUTA_ARCHIVOS_PUBLICOS, exist_ok=True)
    nombre_archivo = os.path.basename(documento.file_name or "archivo")
    nombre_archivo = asegurar_nombre_archivo_unico(
        RUTA_ARCHIVOS_PUBLICOS, nombre_archivo
    )
    archivo = await documento.get_file()
    ruta_destino = os.path.join(RUTA_ARCHIVOS_PUBLICOS, nombre_archivo)
    await archivo.download_to_drive(ruta_destino)
    url = construir_url_archivo(nombre_archivo)
    return nombre_archivo, url


def iniciar_servidor_archivos():
    if not SERVIR_ARCHIVOS_PUBLICOS:
        return None
    os.makedirs(RUTA_ARCHIVOS_PUBLICOS, exist_ok=True)
    controlador = partial(SimpleHTTPRequestHandler, directory=RUTA_ARCHIVOS_PUBLICOS)
    servidor = ThreadingHTTPServer(("", PUERTO_ARCHIVOS_PUBLICOS), controlador)
    hilo = threading.Thread(target=servidor.serve_forever, daemon=True)
    hilo.start()
    print(
        "📂 Servidor de archivos iniciado en "
        f"http://0.0.0.0:{PUERTO_ARCHIVOS_PUBLICOS} "
        f"(ruta: {RUTA_ARCHIVOS_PUBLICOS})"
    )
    return servidor


# ─────────────── MAIN ───────────────
if __name__ == "__main__":
    init_db()
    iniciar_servidor_archivos()

    TOKEN = os.environ.get("TOKEN")
    if not TOKEN:
        raise ValueError("❌ ERROR: La variable de entorno TOKEN no está definida")
    else:
        print("✅ TOKEN cargado correctamente")

    app = ApplicationBuilder().token(TOKEN).build()

    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("fin", fin))
    app.add_handler(CallbackQueryHandler(responder, pattern=r"^\d+$"))
    app.add_handler(CallbackQueryHandler(handle_button))
    app.add_handler(MessageHandler(filters.Document.ALL, handle_document))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_text))

    print("🤖 Bot iniciado")
    app.run_polling()
