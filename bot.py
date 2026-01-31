import os
import json
import random
import sqlite3
import textwrap
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

DATA_DIR = "data"
DB_FILE = os.path.join(DATA_DIR, "bot.db")

MAX_MESSAGE_LEN = 4000
QUESTION_WRAP = 70
OPTION_WRAP = 28
OPTION_MAX_LEN = 64
FAILURES_TEST_SIZE = 40


# ─────────────── DB ───────────────
def get_conn():
    conn = sqlite3.connect(DB_FILE)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    os.makedirs(DATA_DIR, exist_ok=True)
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


def create_quiz(quiz):
    title = quiz.get("titulo") or "Quiz"
    preguntas = quiz.get("preguntas") or []
    if not preguntas:
        return None
    now = datetime.utcnow().isoformat()
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("INSERT INTO quizzes (title, created_at) VALUES (?, ?)", (title, now))
        quiz_id = cur.lastrowid
        for p in preguntas:
            texto = (p.get("pregunta") or "").strip()
            opciones = p.get("opciones") or []
            if not texto or len(opciones) < 2:
                continue
            cur.execute(
                "INSERT INTO questions (quiz_id, text) VALUES (?, ?)",
                (quiz_id, texto),
            )
            q_id = cur.lastrowid
            for idx, opt in enumerate(opciones):
                cur.execute(
                    "INSERT INTO options (question_id, text, position) VALUES (?, ?, ?)",
                    (q_id, str(opt).strip(), idx),
                )
        conn.commit()
        return quiz_id


def list_quizzes():
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id, title FROM quizzes ORDER BY id DESC")
        return cur.fetchall()


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


# ─────────────── Formato de texto ───────────────
def wrap_text(text, width):
    return textwrap.fill(text, width=width, replace_whitespace=False)


def split_message(text, limit=MAX_MESSAGE_LEN):
    if len(text) <= limit:
        return [text]
    parts = []
    current = ""
    for line in text.splitlines(keepends=True):
        if len(current) + len(line) > limit:
            parts.append(current.rstrip())
            current = ""
        current += line
    if current:
        parts.append(current.rstrip())
    return parts


def format_option(text):
    wrapped = wrap_text(text, OPTION_WRAP)
    if len(wrapped) > OPTION_MAX_LEN:
        wrapped = wrapped[: OPTION_MAX_LEN - 1].rstrip() + "…"
    return wrapped


def parse_quiz_json(text):
    payload = json.loads(text)
    if isinstance(payload, dict):
        return [payload]
    if isinstance(payload, list):
        return payload
    return []


# ─────────────── /start ───────────────
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await mostrar_menu(update.message.chat.id, context, "👋 Bienvenido al TestBot")


# ─────────────── Menú principal ───────────────
async def mostrar_menu(chat_id, context, texto="Selecciona una opción:"):
    botones = [
        [InlineKeyboardButton("🧩 Crear test", callback_data="crear_test")],
        [InlineKeyboardButton("📋 Mis tests", callback_data="mis_tests")],
        [InlineKeyboardButton("📈 Progreso", callback_data="progreso")],
        [InlineKeyboardButton("⚠️ Test de fallos (40)", callback_data="test_fallos")],
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

    if data == "crear_test":
        context.user_data["modo"] = "json"
        await query.message.reply_text(
            "🧩 Pega el JSON del test. Usa el formato del ejemplo pero sin 'correcta'.\n"
            "La respuesta correcta será siempre la primera opción.\n"
            "Cuando termines escribe: /fin"
        )
    elif data == "mis_tests":
        await mostrar_tests(chat_id, context)
    elif data.startswith("empezar_"):
        quiz_id = int(data.split("_")[1])
        await iniciar_quiz(chat_id, context, quiz_id=quiz_id, attempt_type="quiz")
    elif data == "progreso":
        await mostrar_progreso(chat_id, context)
    elif data == "test_fallos":
        await iniciar_test_fallos(chat_id, context)
    elif data == "descargar_bd":
        await enviar_bd(chat_id, context)
    elif data == "menu":
        await mostrar_menu(chat_id, context)


# ─────────────── Texto pegado ───────────────
async def handle_text(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if context.user_data.get("modo") == "json":
        context.user_data.setdefault("buffer", "")
        context.user_data["buffer"] += update.message.text + "\n"


async def fin(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if context.user_data.get("modo") != "json":
        return
    text = context.user_data.pop("buffer", "")
    context.user_data.pop("modo", None)
    try:
        quizzes = parse_quiz_json(text)
    except json.JSONDecodeError:
        await update.message.reply_text("❌ JSON inválido.")
        return

    created = 0
    for quiz in quizzes:
        quiz_id = create_quiz(quiz)
        if quiz_id:
            created += 1
    if created == 0:
        await update.message.reply_text("❌ No se pudo crear ningún test.")
    else:
        await update.message.reply_text(f"✅ Tests creados: {created}")
    await mostrar_menu(update.message.chat.id, context)


# ─────────────── Mostrar tests ───────────────
async def mostrar_tests(chat_id, context):
    quizzes = list_quizzes()
    if not quizzes:
        await context.bot.send_message(chat_id, "No hay tests creados.")
        return
    botones = [
        [InlineKeyboardButton(q["title"], callback_data=f"empezar_{q['id']}")]
        for q in quizzes
    ]
    botones.append([InlineKeyboardButton("☰ Menú", callback_data="menu")])
    await context.bot.send_message(
        chat_id, "Selecciona un test:", reply_markup=InlineKeyboardMarkup(botones)
    )


# ─────────────── Tests ───────────────
async def iniciar_quiz(chat_id, context, quiz_id=None, attempt_type="quiz"):
    user_id = get_or_create_user(chat_id)
    questions = load_quiz_questions(quiz_id)
    if not questions:
        await context.bot.send_message(chat_id, "❌ Test no encontrado o vacío.")
        await mostrar_menu(chat_id, context)
        return
    attempt_id = create_attempt(user_id, quiz_id, attempt_type)
    context.user_data["quiz"] = {
        "questions": questions,
        "i": 0,
        "ok": 0,
        "fail": 0,
        "attempt_id": attempt_id,
        "attempt_type": attempt_type,
        "user_id": user_id,
    }
    await enviar_pregunta(chat_id, context)


async def iniciar_test_fallos(chat_id, context):
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
    }
    await enviar_pregunta(chat_id, context)


async def enviar_pregunta(chat_id, context):
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
    pregunta = wrap_text(q["text"].strip(), QUESTION_WRAP)
    partes = split_message(pregunta)

    options = list(q["options"])
    random.shuffle(options)
    correct_index = options.index(q["correct_text"])
    quiz["current"] = {
        "question_id": q["id"],
        "options": options,
        "correct_index": correct_index,
    }

    botones = [
        [InlineKeyboardButton(format_option(o), callback_data=str(idx))]
        for idx, o in enumerate(options)
    ]
    botones.append([InlineKeyboardButton("☰ Menú", callback_data="menu")])

    for parte in partes[:-1]:
        await context.bot.send_message(chat_id, parte)
    await context.bot.send_message(
        chat_id, partes[-1], reply_markup=InlineKeyboardMarkup(botones)
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

    selected = int(query.data)
    correct_index = current["correct_index"]
    options = current["options"]
    question_id = current["question_id"]
    user_id = quiz["user_id"]

    if selected == correct_index:
        quiz["ok"] += 1
        respuesta = wrap_text(options[selected], QUESTION_WRAP)
        await query.message.reply_text(f"✅ ¡Correcto!\nTu respuesta:\n{respuesta}")
        clear_failure(user_id, question_id)
        is_correct = True
    else:
        quiz["fail"] += 1
        resp = wrap_text(options[selected], QUESTION_WRAP)
        correcta = wrap_text(options[correct_index], QUESTION_WRAP)
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
    stats = get_progress_summary(user_id)
    total = stats["total_correct"] + stats["total_wrong"]
    porcentaje = (stats["total_correct"] / total * 100) if total else 0
    mensaje = (
        "📈 Progreso\n"
        f"Tests realizados: {stats['total_attempts']}\n"
        f"Preguntas hechas: {total}\n"
        f"Aciertos: {stats['total_correct']}\n"
        f"Errores: {stats['total_wrong']}\n"
        f"Porcentaje de acierto: {porcentaje:.2f}%\n"
        f"Preguntas falladas pendientes: {stats['failed_q']}"
    )
    await context.bot.send_message(chat_id, mensaje)


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
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_text))

    print("🤖 Bot iniciado")
    app.run_polling()
