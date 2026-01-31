import os
import json
import random
import sqlite3
from datetime import datetime
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

FAILURES_TEST_SIZE = 40
TIEMPO_PREGUNTA_SEGUNDOS = 20


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
            opciones = p.get("opciones") or []
            bloque = p.get("bloque")
            tema = p.get("tema")
            if not texto or len(opciones) < 2:
                continue
            cur.execute(
                "INSERT INTO questions (quiz_id, text, bloque, tema) VALUES (?, ?, ?, ?)",
                (quiz_id, texto, bloque, tema),
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


def obtener_titulo_test(quiz_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT title FROM quizzes WHERE id = ?", (quiz_id,))
        row = cur.fetchone()
        return row["title"] if row else None


def load_quiz_questions(quiz_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id, text FROM questions WHERE quiz_id = ?", (quiz_id,))
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


def get_failures_questions(user_id, limit_count):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            """
            SELECT q.id, q.text
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
        [InlineKeyboardButton("📈 Progreso", callback_data="progreso")],
        [InlineKeyboardButton("⚠️ Test de fallos", callback_data="test_fallos")],
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
            [InlineKeyboardButton(format_option(o), callback_data=str(idx))]
            for idx, o in enumerate(opciones)
        ]
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
        await mostrar_tests(chat_id, context)
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
        await mostrar_tests(chat_id, context)
    elif data == "cancelar_borrar":
        await query.message.reply_text("Operación cancelada.")
        await mostrar_tests(chat_id, context)
    elif data == "progreso":
        await mostrar_progreso(chat_id, context)
    elif data == "test_fallos":
        await iniciar_test_fallos(
            chat_id, context, telegram_user_id=query.from_user.id
        )
    elif data == "descargar_bd":
        await enviar_bd(chat_id, context)
    elif data == "menu":
        await mostrar_menu(chat_id, context)


# ─────────────── Texto pegado ───────────────
async def handle_text(update: Update, context: ContextTypes.DEFAULT_TYPE):
    modo = context.user_data.get("modo")
    if modo == "crear_test_nombre":
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
            "Cada pregunta incluye bloque y tema.\n"
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
    if context.user_data.get("modo") != "crear_test_json":
        return
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


# ─────────────── Mostrar tests ───────────────
async def mostrar_tests(chat_id, context):
    quizzes = listar_tests_con_conteo()
    if not quizzes:
        await context.bot.send_message(chat_id, "No hay tests creados.")
        return
    botones = [
        [
            InlineKeyboardButton(
                f"{q['title']} ({q['total_preguntas']} preguntas)",
                callback_data=f"empezar_{q['id']}",
            ),
            InlineKeyboardButton("🗑️ Borrar", callback_data=f"borrar_{q['id']}"),
        ]
        for q in quizzes
    ]
    botones.append([InlineKeyboardButton("☰ Menú", callback_data="menu")])
    await context.bot.send_message(
        chat_id, "Selecciona un test:", reply_markup=InlineKeyboardMarkup(botones)
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
        [InlineKeyboardButton(format_option(o), callback_data=str(idx))]
        for idx, o in enumerate(options)
    ]
    botones_opciones.append([InlineKeyboardButton("☰ Menú", callback_data="menu")])

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


# ─────────────── MAIN ───────────────
if __name__ == "__main__":
    init_db()

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
