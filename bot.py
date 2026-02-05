import os
import json
import random
import sqlite3
import threading
from math import ceil
from datetime import datetime
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import quote
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
    "RUTA_ARCHIVOS_PUBLICOS", os.path.join(RUTA_DATOS, "publicos")
)
PUERTO_ARCHIVOS_PUBLICOS = int(os.getenv("PUERTO_ARCHIVOS_PUBLICOS", "8000"))
URL_PUBLICA_ARCHIVOS = os.getenv(
    "URL_PUBLICA_ARCHIVOS", f"http://localhost:{PUERTO_ARCHIVOS_PUBLICOS}"
).rstrip("/")
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
        nota = max((correct - 0.3 * wrong) / total * 10, 0) if total else 0
        resumen[quiz_id]["intentos"].append(
            {
                "correct": correct,
                "wrong": wrong,
                "nota": nota,
            }
        )
    return list(resumen.values())


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
    nota = max((total_correct - 0.3 * total_wrong) / total * 10, 0) if total else 0
    return {
        "total_correct": total_correct,
        "total_wrong": total_wrong,
        "nota": nota,
    }


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
        cur.execute("SELECT id FROM questions WHERE quiz_id = ?", (quiz_id,))
        preguntas_ids = [row["id"] for row in cur.fetchall()]
        if preguntas_ids:
            placeholders = ",".join("?" for _ in preguntas_ids)
            cur.execute(
                f"DELETE FROM failures WHERE question_id IN ({placeholders})",
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
                f"DELETE FROM attempts WHERE id IN ({placeholders})",
                intentos_ids,
            )
        cur.execute("DELETE FROM quizzes WHERE id = ?", (quiz_id,))
        conn.commit()


# ─────────────── Formato de texto ───────────────
def wrap_text(text, width=None):
    return text


def split_message(text, limit=None):
    return [text]


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
        return
    for pregunta in quiz.get("questions", []):
        if pregunta["id"] == question_id:
            pregunta.update(pregunta_actualizada)
            break

    actual = quiz.get("current")
    if actual and actual.get("question_id") == question_id:
        opciones_mezcladas = list(pregunta_actualizada["options"])
        random.shuffle(opciones_mezcladas)
        actual["options"] = opciones_mezcladas
        actual["correct_index"] = opciones_mezcladas.index(
            pregunta_actualizada["correct_text"]
        )


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


def cancelar_temporizador_pregunta(context):
    trabajo = context.user_data.pop("temporizador_pregunta", None)
    if trabajo:
        trabajo.schedule_removal()


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

    quiz["fail"] += 1
    correcta = wrap_text(actual["options"][actual["correct_index"]])
    await context.bot.send_message(chat_id, "⏰ Tiempo agotado.")
    await context.bot.send_message(chat_id, f"💡 Respuesta correcta:\n{correcta}")

    add_attempt_item(quiz["attempt_id"], pregunta_id, "Sin respuesta", False)
    record_failure(quiz["user_id"], pregunta_id)

    quiz["i"] += 1
    await enviar_pregunta(chat_id, context)


# ─────────────── /start ───────────────
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await mostrar_menu(update.message.chat.id, context, "👋 Bienvenido al TestBot")


# ─────────────── Menú principal ───────────────
async def mostrar_menu(chat_id, context, texto="Selecciona una opción:"):
    botones = [
        [InlineKeyboardButton("🧩 Crear test", callback_data="crear_test")],
        [InlineKeyboardButton("📋 Mis tests", callback_data="mis_tests")],
        [InlineKeyboardButton("🗑️ Borrar test", callback_data="borrar_tests")],
        [InlineKeyboardButton("📈 Progreso", callback_data="progreso")],
        [InlineKeyboardButton("⚠️ Test de fallos", callback_data="test_fallos")],
        [InlineKeyboardButton("📁 Archivos", callback_data="archivos")],
        [InlineKeyboardButton("⬇️ Descargar BD", callback_data="descargar_bd")],
    ]
    await context.bot.send_message(
        chat_id, texto, reply_markup=InlineKeyboardMarkup(botones)
    )


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
        texto_expandido = construir_texto_pregunta(
            f"📍 Pregunta {i + 1}/{len(quiz['questions'])}",
            texto_pregunta,
            opciones,
        )
        botones = [
            [InlineKeyboardButton(ensanchar_etiqueta_opcion(o), callback_data=str(idx))]
            for idx, o in enumerate(opciones)
        ]
        botones.append([InlineKeyboardButton("🧾 Editar pregunta (JSON)", callback_data=f"editar_pregunta_json_{q['id']}")])
        botones.append([InlineKeyboardButton("☰ Menú", callback_data="menu")])
        await query.message.edit_text(
            texto_expandido,
            reply_markup=None,
        )
    elif data == "crear_test":
        context.user_data["modo"] = "crear_test_nombre"
        context.user_data["nuevo_test"] = {}
        await query.message.reply_text("🧩 Escribe el nombre del test:")
    elif data == "mis_tests":
        await mostrar_tests(chat_id, context, pagina=1)
    elif data == "borrar_tests":
        await mostrar_tests_para_borrar(chat_id, context, pagina=1)
    elif data.startswith("mis_tests_pagina_"):
        pagina = int(data.split("_")[3])
        await mostrar_tests(chat_id, context, pagina=pagina)
    elif data.startswith("borrar_tests_pagina_"):
        pagina = int(data.split("_")[3])
        await mostrar_tests_para_borrar(chat_id, context, pagina=pagina)
    elif data.startswith("empezar_"):
        quiz_id = int(data.split("_")[1])
        await iniciar_quiz(
            chat_id,
            context,
            quiz_id=quiz_id,
            attempt_type="quiz",
            telegram_user_id=query.from_user.id,
        )
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
    elif data.startswith("confirmar_borrar_"):
        quiz_id = int(data.split("_")[2])
        borrar_test(quiz_id)
        await query.message.reply_text("🗑️ Test borrado.")
        pagina = context.user_data.get("pagina_borrado_tests", 1)
        await mostrar_tests_para_borrar(chat_id, context, pagina=pagina)
    elif data == "cancelar_borrar":
        await query.message.reply_text("Operación cancelada.")
        pagina = context.user_data.get("pagina_borrado_tests", 1)
        await mostrar_tests_para_borrar(chat_id, context, pagina=pagina)
    elif data == "progreso":
        await mostrar_progreso(chat_id, context)
    elif data == "test_fallos":
        await iniciar_test_fallos(
            chat_id, context, telegram_user_id=query.from_user.id
        )
    elif data == "archivos":
        await mostrar_menu_archivos(chat_id, context)
    elif data == "subir_archivo":
        context.user_data["modo"] = "subir_archivo"
        await query.message.reply_text(
            "📤 Envía el archivo que quieras publicar en la carpeta pública."
        )
    elif data == "ver_archivos":
        await mostrar_archivos_publicos(chat_id, context)
    elif data == "volver_menu_archivos":
        await mostrar_menu_archivos(chat_id, context)
    elif data == "descargar_bd":
        await enviar_bd(chat_id, context)
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
        json_actual = json.dumps(payload_actual, ensure_ascii=False, indent=2)
        botones = InlineKeyboardMarkup(
            [[InlineKeyboardButton("↩️ Cancelar", callback_data="cancelar_edicion_pregunta_json")]]
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
        await query.message.reply_text("Operación cancelada.")
    elif data.startswith("explicacion_"):
        pregunta_id = int(data.split("_")[1])
        contexto_explicacion = obtener_explicacion_pregunta(pregunta_id)
        context.user_data["modo"] = "editar_explicacion"
        context.user_data["pregunta_explicacion_id"] = pregunta_id
        botones = InlineKeyboardMarkup(
            [[InlineKeyboardButton("↩️ Cancelar", callback_data="cancelar_explicacion")]]
        )
        if contexto_explicacion:
            await query.message.reply_text(
                "📝 Explicación actual:\n"
                f"{contexto_explicacion}\n\n"
                "Escribe la nueva explicación para la pregunta o adjunta un archivo "
                "para guardarlo como enlace:",
                reply_markup=botones,
            )
        else:
            await query.message.reply_text(
                "📝 Esta pregunta no tiene explicación.\n"
                "Escribe una explicación o adjunta un archivo para guardar el enlace:",
                reply_markup=botones,
            )
    elif data == "cancelar_explicacion":
        context.user_data.pop("modo", None)
        context.user_data.pop("pregunta_explicacion_id", None)
        await query.message.reply_text("Operación cancelada.")
    elif data.startswith("ver_explicacion_"):
        pregunta_id = int(data.split("_")[2])
        explicacion = obtener_explicacion_pregunta(pregunta_id)
        if explicacion:
            await query.message.reply_text(f"📖 Explicación:\n{explicacion}")
        else:
            await query.message.reply_text(
                "ℹ️ Esta pregunta no tiene explicación guardada."
            )


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
        actualizar_explicacion_pregunta(pregunta_id, explicacion)
        await update.message.reply_text("✅ Explicación guardada.")
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

        sincronizar_pregunta_en_quiz(context, pregunta_id, pregunta_actualizada)
        context.user_data.pop("modo", None)
        context.user_data.pop("pregunta_json_id", None)
        await update.message.reply_text("✅ Pregunta actualizada correctamente desde JSON.")
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
    if context.user_data.get("modo") != "crear_test_json":
        return
    text = context.user_data.pop("buffer", "")
    await procesar_texto_json(text, update, context)


async def handle_document(update: Update, context: ContextTypes.DEFAULT_TYPE):
    modo = context.user_data.get("modo")
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
            f"🌐 {url}"
        )
        return
    if modo == "subir_archivo":
        await guardar_archivo_publico(update, context)
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

    botones = [
        [
            InlineKeyboardButton(
                f"{'✅ ' if q['id'] in tests_realizados else ''}"
                f"{q['title']} ({q['total_preguntas']} preguntas)",
                callback_data=f"empezar_{q['id']}",
            ),
        ]
        for q in quizzes
    ]

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


# ─────────────── Tests ───────────────
async def iniciar_quiz(
    chat_id, context, quiz_id=None, attempt_type="quiz", telegram_user_id=None
):
    user_id = get_or_create_user(chat_id)
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
        "i": 0,
        "ok": 0,
        "fail": 0,
        "attempt_id": attempt_id,
        "attempt_type": attempt_type,
        "user_id": user_id,
        "telegram_user_id": telegram_user_id,
    }
    await enviar_pregunta(chat_id, context)


async def iniciar_test_fallos(chat_id, context, telegram_user_id=None):
    user_id = get_or_create_user(chat_id)
    preguntas = get_failures_questions(user_id, FAILURES_TEST_SIZE)
    if not preguntas:
        await context.bot.send_message(chat_id, "No tienes fallos acumulados.")
        return
    attempt_id = create_attempt(user_id, None, "failures")
    context.user_data["quiz"] = {
        "questions": preguntas,
        "i": 0,
        "ok": 0,
        "fail": 0,
        "attempt_id": attempt_id,
        "attempt_type": "failures",
        "user_id": user_id,
        "telegram_user_id": telegram_user_id,
    }
    await enviar_pregunta(chat_id, context)


async def enviar_pregunta(chat_id, context):
    cancelar_temporizador_pregunta(context)
    quiz = context.user_data["quiz"]
    i = quiz["i"]
    if i >= len(quiz["questions"]):
        nota = max((quiz["ok"] - 0.3 * quiz["fail"]) / len(quiz["questions"]) * 10, 0)
        finish_attempt(quiz["attempt_id"], quiz["ok"], quiz["fail"])
        await context.bot.send_message(
            chat_id,
            f"🏁 Fin del test\n✔️ {quiz['ok']} ❌ {quiz['fail']}\n🎯 Nota: {nota:.2f}/10",
        )
        context.user_data.pop("quiz")
        await mostrar_menu(chat_id, context)
        return

    q = quiz["questions"][i]
    total_preguntas = len(quiz["questions"])
    encabezado = f"📍 Pregunta {i + 1}/{total_preguntas}"
    texto_pregunta = wrap_text(q["text"].strip())

    options = list(q["options"])
    random.shuffle(options)
    correct_index = options.index(q["correct_text"])
    quiz["current"] = {
        "question_id": q["id"],
        "options": options,
        "correct_index": correct_index,
    }

    mensaje_inicial = construir_texto_pregunta(encabezado, texto_pregunta)
    partes = split_message(mensaje_inicial)
    botones_enunciado = [[InlineKeyboardButton("👀 Ver más", callback_data="ver_mas")]]
    botones_opciones = [
        [InlineKeyboardButton(ensanchar_etiqueta_opcion(o), callback_data=str(idx))]
        for idx, o in enumerate(options)
    ]
    botones_opciones.append(
        [
            InlineKeyboardButton(
                "🧾 Editar pregunta (JSON)",
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

    explicacion_actual = obtener_explicacion_pregunta(question_id)
    filas_explicacion = []
    if explicacion_actual:
        filas_explicacion.append(
            [
                InlineKeyboardButton(
                    "👀 Ver explicación",
                    callback_data=f"ver_explicacion_{question_id}",
                )
            ]
        )
    filas_explicacion.append(
        [
            InlineKeyboardButton(
                "✍️ Añadir/editar explicación",
                callback_data=f"explicacion_{question_id}",
            )
        ]
    )
    filas_explicacion.append(
        [
            InlineKeyboardButton(
                "🧾 Editar pregunta (JSON)",
                callback_data=f"editar_pregunta_json_{question_id}",
            )
        ]
    )
    await query.message.reply_text(
        "📝 Opciones de explicación:",
        reply_markup=InlineKeyboardMarkup(filas_explicacion),
    )

    quiz["i"] += 1
    await enviar_pregunta(chat_id, context)


# ─────────────── Progreso ───────────────
async def mostrar_progreso(chat_id, context):
    user_id = get_or_create_user(chat_id)
    progreso_general = get_progreso_general(user_id)
    progreso_tests = get_progreso_por_tests(user_id)

    mensaje = (
        "📈 Progreso general\n"
        f"Aciertos totales: {progreso_general['total_correct']}\n"
        f"Fallos totales: {progreso_general['total_wrong']}\n"
        f"Nota general: {progreso_general['nota']:.2f}/10"
    )

    if not progreso_tests:
        mensaje += "\n\nNo hay intentos registrados todavía."
        await context.bot.send_message(chat_id, mensaje)
        return

    detalles = ["\n\n📚 Progreso por test"]
    for test in progreso_tests:
        detalles.append(f"\n🧪 {test['titulo']}")
        for idx, intento in enumerate(test["intentos"], start=1):
            detalles.append(
                f"  Intento {idx}: ✔️ {intento['correct']} ❌ {intento['wrong']} "
                f"🎯 {intento['nota']:.2f}/10"
            )

    await context.bot.send_message(chat_id, mensaje + "\n".join(detalles))


# ─────────────── Descargar BD ───────────────
async def enviar_bd(chat_id, context):
    if not os.path.exists(DB_FILE):
        await context.bot.send_message(chat_id, "No hay base de datos todavía.")
        return
    with open(DB_FILE, "rb") as f:
        await context.bot.send_document(chat_id, document=f, filename="bot.db")


async def mostrar_menu_archivos(chat_id, context):
    botones = [
        [InlineKeyboardButton("⬆️ Subir archivo", callback_data="subir_archivo")],
        [InlineKeyboardButton("📂 Ver archivos", callback_data="ver_archivos")],
        [InlineKeyboardButton("☰ Menú principal", callback_data="menu")],
    ]
    await context.bot.send_message(
        chat_id,
        "📁 Gestión de archivos",
        reply_markup=InlineKeyboardMarkup(botones),
    )


def asegurar_nombre_archivo_unico(ruta_directorio, nombre_archivo):
    base, extension = os.path.splitext(nombre_archivo)
    contador = 1
    nombre_final = nombre_archivo
    while os.path.exists(os.path.join(ruta_directorio, nombre_final)):
        nombre_final = f"{base}_{contador}{extension}"
        contador += 1
    return nombre_final


def obtener_archivos_publicos():
    if not os.path.isdir(RUTA_ARCHIVOS_PUBLICOS):
        return []
    entradas = []
    for nombre in os.listdir(RUTA_ARCHIVOS_PUBLICOS):
        ruta = os.path.join(RUTA_ARCHIVOS_PUBLICOS, nombre)
        if os.path.isfile(ruta):
            entradas.append(
                {
                    "nombre": nombre,
                    "tamano": os.path.getsize(ruta),
                }
            )
    return sorted(entradas, key=lambda item: item["nombre"].lower())


def construir_url_archivo(nombre_archivo):
    return f"{URL_PUBLICA_ARCHIVOS}/{quote(nombre_archivo)}"


async def mostrar_archivos_publicos(chat_id, context):
    archivos = obtener_archivos_publicos()
    if not archivos:
        await context.bot.send_message(
            chat_id, "📭 No hay archivos públicos todavía."
        )
        return
    lineas = ["📂 Archivos públicos:"]
    for archivo in archivos:
        url = construir_url_archivo(archivo["nombre"])
        lineas.append(f"- {archivo['nombre']} ({archivo['tamano']} bytes)\n  {url}")
    await context.bot.send_message(chat_id, "\n".join(lineas))


async def guardar_archivo_publico(update: Update, context: ContextTypes.DEFAULT_TYPE):
    documento = update.message.document
    if not documento:
        await update.message.reply_text("❌ No se recibió ningún archivo.")
        return
    nombre_archivo, url = await guardar_documento_publico(documento)
    if not nombre_archivo or not url:
        await update.message.reply_text("❌ No se pudo guardar el archivo.")
        return
    context.user_data.pop("modo", None)
    await update.message.reply_text(
        "✅ Archivo guardado.\n"
        f"📎 {nombre_archivo}\n"
        f"🌐 {url}"
    )


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
