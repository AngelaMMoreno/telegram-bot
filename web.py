import os
import json
import random
import sqlite3
import secrets
from datetime import datetime
from functools import wraps
from flask import (
    Flask,
    render_template,
    request,
    redirect,
    url_for,
    session,
    flash,
    jsonify,
    abort,
)

app = Flask(__name__)
app.secret_key = os.getenv("WEB_SECRET_KEY", secrets.token_hex(32))

RUTA_DATOS = os.getenv("RUTA_DATOS", os.getenv("DATA_DIR", "users"))
DB_FILE = os.path.join(RUTA_DATOS, "bot.db")
WEB_PORT = int(os.getenv("WEB_PORT", "5000"))

FAILURES_TEST_SIZE = 40
TAMANO_TEST_FAVORITAS = 40

# ─────────── Auth config ───────────
def _parse_env_list(val):
    val = (val or "").strip()
    if not val:
        return []
    if val.startswith("["):
        try:
            return json.loads(val)
        except json.JSONDecodeError:
            pass
    return [x.strip() for x in val.split(",") if x.strip()]


def get_credentials():
    users = _parse_env_list(os.getenv("USERS", ""))
    passwords = _parse_env_list(os.getenv("PASSWORDS", ""))
    return dict(zip(users, passwords))


# ─────────── DB helpers ───────────
def get_conn():
    conn = sqlite3.connect(DB_FILE)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    os.makedirs(RUTA_DATOS, exist_ok=True)
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("""
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_id TEXT UNIQUE NOT NULL,
                created_at TEXT NOT NULL
            )
        """)
        cur.execute("""
            CREATE TABLE IF NOT EXISTS quizzes (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL,
                description TEXT,
                created_at TEXT NOT NULL
            )
        """)
        cur.execute("""
            CREATE TABLE IF NOT EXISTS questions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                quiz_id INTEGER NOT NULL,
                text TEXT NOT NULL,
                explicacion TEXT,
                bloque INTEGER,
                tema INTEGER,
                FOREIGN KEY (quiz_id) REFERENCES quizzes(id)
            )
        """)
        cur.execute("""
            CREATE TABLE IF NOT EXISTS options (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                question_id INTEGER NOT NULL,
                text TEXT NOT NULL,
                position INTEGER NOT NULL,
                FOREIGN KEY (question_id) REFERENCES questions(id)
            )
        """)
        cur.execute("""
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
        """)
        cur.execute("""
            CREATE TABLE IF NOT EXISTS attempt_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                attempt_id INTEGER NOT NULL,
                question_id INTEGER NOT NULL,
                selected_option TEXT NOT NULL,
                is_correct INTEGER NOT NULL,
                FOREIGN KEY (attempt_id) REFERENCES attempts(id),
                FOREIGN KEY (question_id) REFERENCES questions(id)
            )
        """)
        cur.execute("""
            CREATE TABLE IF NOT EXISTS failures (
                user_id INTEGER NOT NULL,
                question_id INTEGER NOT NULL,
                fail_count INTEGER NOT NULL DEFAULT 0,
                last_failed_at TEXT NOT NULL,
                PRIMARY KEY (user_id, question_id),
                FOREIGN KEY (user_id) REFERENCES users(id),
                FOREIGN KEY (question_id) REFERENCES questions(id)
            )
        """)
        cur.execute("""
            CREATE TABLE IF NOT EXISTS favorites (
                user_id INTEGER NOT NULL,
                question_id INTEGER NOT NULL,
                created_at TEXT NOT NULL,
                PRIMARY KEY (user_id, question_id),
                FOREIGN KEY (user_id) REFERENCES users(id),
                FOREIGN KEY (question_id) REFERENCES questions(id)
            )
        """)
        cur.execute("""
            CREATE TABLE IF NOT EXISTS tests_favoritos (
                user_id INTEGER NOT NULL,
                quiz_id INTEGER NOT NULL,
                created_at TEXT NOT NULL,
                PRIMARY KEY (user_id, quiz_id),
                FOREIGN KEY (user_id) REFERENCES users(id),
                FOREIGN KEY (quiz_id) REFERENCES quizzes(id)
            )
        """)
        conn.commit()


def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if "user" not in session:
            return redirect(url_for("login"))
        return f(*args, **kwargs)
    return decorated


# ─────────── Auth routes ───────────
@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")
        creds = get_credentials()
        if creds.get(username) == password and username:
            session["user"] = username
            return redirect(url_for("dashboard"))
        flash("Usuario o contrasena incorrectos", "error")
    return render_template("login.html")


@app.route("/logout")
def logout():
    session.pop("user", None)
    return redirect(url_for("login"))


# ─────────── Dashboard ───────────
@app.route("/")
@login_required
def dashboard():
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
        tests = [dict(row) for row in cur.fetchall()]
    return render_template("dashboard.html", tests=tests)


# ─────────── Quiz list (API for pagination) ───────────
@app.route("/api/tests")
@login_required
def api_tests():
    page = int(request.args.get("page", 1))
    per_page = 20
    offset = (page - 1) * per_page
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT COUNT(*) AS total FROM quizzes")
        total = cur.fetchone()["total"]
        cur.execute(
            """
            SELECT q.id, q.title, q.description, COUNT(que.id) AS total_preguntas
            FROM quizzes q
            LEFT JOIN questions que ON que.quiz_id = q.id
            GROUP BY q.id
            ORDER BY q.id DESC
            LIMIT ? OFFSET ?
            """,
            (per_page, offset),
        )
        tests = [dict(row) for row in cur.fetchall()]
    return jsonify({"tests": tests, "total": total, "page": page, "per_page": per_page})


# ─────────── Start quiz ───────────
@app.route("/quiz/<int:quiz_id>/start", methods=["POST"])
@login_required
def start_quiz(quiz_id):
    questions = _load_quiz_questions(quiz_id)
    if not questions:
        flash("No se encontraron preguntas en este test.", "error")
        return redirect(url_for("dashboard"))
    random.shuffle(questions)
    user_id = _get_web_user_id()
    attempt_id = _create_attempt(user_id, quiz_id, "quiz")
    session["quiz"] = {
        "quiz_id": quiz_id,
        "attempt_id": attempt_id,
        "questions": questions,
        "index": 0,
        "ok": 0,
        "fail": 0,
    }
    return redirect(url_for("quiz_question"))


@app.route("/quiz/failures/start", methods=["POST"])
@login_required
def start_failures_quiz():
    user_id = _get_web_user_id()
    questions = _get_failures_questions(user_id, FAILURES_TEST_SIZE)
    if not questions:
        flash("No tienes preguntas falladas.", "error")
        return redirect(url_for("dashboard"))
    random.shuffle(questions)
    attempt_id = _create_attempt(user_id, None, "failures")
    session["quiz"] = {
        "quiz_id": None,
        "attempt_id": attempt_id,
        "attempt_type": "failures",
        "questions": questions,
        "index": 0,
        "ok": 0,
        "fail": 0,
    }
    return redirect(url_for("quiz_question"))


@app.route("/quiz/favorites/start", methods=["POST"])
@login_required
def start_favorites_quiz():
    user_id = _get_web_user_id()
    questions = _get_favorites_questions(user_id, TAMANO_TEST_FAVORITAS)
    if not questions:
        flash("No tienes preguntas favoritas.", "error")
        return redirect(url_for("dashboard"))
    random.shuffle(questions)
    attempt_id = _create_attempt(user_id, None, "favorites")
    session["quiz"] = {
        "quiz_id": None,
        "attempt_id": attempt_id,
        "attempt_type": "favorites",
        "questions": questions,
        "index": 0,
        "ok": 0,
        "fail": 0,
    }
    return redirect(url_for("quiz_question"))


# ─────────── Quiz question flow ───────────
@app.route("/quiz/question")
@login_required
def quiz_question():
    quiz = session.get("quiz")
    if not quiz:
        return redirect(url_for("dashboard"))
    idx = quiz["index"]
    questions = quiz["questions"]
    if idx >= len(questions):
        return redirect(url_for("quiz_result"))
    q = questions[idx]
    options = list(q["options"])
    correct_text = q["correct_text"]
    random.shuffle(options)
    quiz["_shuffled_options"] = options
    quiz["_correct_index"] = options.index(correct_text)
    session["quiz"] = quiz
    total = len(questions)
    quiz_id = quiz.get("quiz_id")
    quiz_title = None
    if quiz_id:
        quiz_title = _get_quiz_title(quiz_id)
    return render_template(
        "question.html",
        question=q,
        options=options,
        current=idx + 1,
        total=total,
        quiz_title=quiz_title,
    )


@app.route("/quiz/answer", methods=["POST"])
@login_required
def quiz_answer():
    quiz = session.get("quiz")
    if not quiz:
        return redirect(url_for("dashboard"))
    selected = int(request.form.get("option", -1))
    options = quiz.get("_shuffled_options", [])
    correct_index = quiz.get("_correct_index", -1)
    idx = quiz["index"]
    q = quiz["questions"][idx]
    is_correct = selected == correct_index
    user_id = _get_web_user_id()

    if is_correct:
        quiz["ok"] += 1
        _clear_failure(user_id, q["id"])
    else:
        quiz["fail"] += 1
        _record_failure(user_id, q["id"])

    _add_attempt_item(
        quiz["attempt_id"], q["id"], options[selected] if 0 <= selected < len(options) else "?", is_correct
    )

    result_data = {
        "is_correct": is_correct,
        "selected": selected,
        "correct_index": correct_index,
        "options": options,
        "question": q,
        "current": idx + 1,
        "total": len(quiz["questions"]),
        "ok": quiz["ok"],
        "fail": quiz["fail"],
        "quiz_title": _get_quiz_title(quiz["quiz_id"]) if quiz.get("quiz_id") else None,
        "is_favorite": _is_favorite(user_id, q["id"]),
    }

    quiz["index"] += 1
    session["quiz"] = quiz

    return render_template("answer_result.html", **result_data)


@app.route("/quiz/favorite/<int:question_id>", methods=["POST"])
@login_required
def toggle_favorite(question_id):
    user_id = _get_web_user_id()
    if _is_favorite(user_id, question_id):
        _remove_favorite(user_id, question_id)
        return jsonify({"is_favorite": False})
    else:
        _add_favorite(user_id, question_id)
        return jsonify({"is_favorite": True})


# ─────────── Quiz result ───────────
@app.route("/quiz/result")
@login_required
def quiz_result():
    quiz = session.pop("quiz", None)
    if not quiz:
        return redirect(url_for("dashboard"))
    ok = quiz["ok"]
    fail = quiz["fail"]
    total = ok + fail
    nota = max((ok - 0.3 * fail) / total * 10, 0) if total else 0
    _finish_attempt(quiz["attempt_id"], ok, fail)
    quiz_title = _get_quiz_title(quiz["quiz_id"]) if quiz.get("quiz_id") else None
    attempt_type = quiz.get("attempt_type", "quiz")
    return render_template(
        "result.html",
        ok=ok,
        fail=fail,
        total=total,
        nota=round(nota, 2),
        quiz_title=quiz_title,
        attempt_type=attempt_type,
    )


@app.route("/quiz/abandon", methods=["POST"])
@login_required
def quiz_abandon():
    quiz = session.pop("quiz", None)
    if quiz and quiz.get("attempt_id"):
        _finish_attempt(quiz["attempt_id"], quiz.get("ok", 0), quiz.get("fail", 0))
    return redirect(url_for("dashboard"))


# ─────────── Progress ───────────
@app.route("/progress")
@login_required
def progress():
    user_id = _get_web_user_id()
    general = _get_progreso_general(user_id)
    por_tests = _get_progreso_por_tests(user_id)
    hoy = _contar_preguntas_hoy(user_id)
    return render_template(
        "progress.html",
        general=general,
        por_tests=por_tests,
        hoy=hoy,
    )


# ─────────── DB helper functions ───────────
def _get_web_user_id():
    username = session.get("user", "web_user")
    chat_id = f"web_{username}"
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT id FROM users WHERE chat_id = ?", (chat_id,))
        row = cur.fetchone()
        if row:
            return row["id"]
        now = datetime.utcnow().isoformat()
        cur.execute(
            "INSERT INTO users (chat_id, created_at) VALUES (?, ?)",
            (chat_id, now),
        )
        conn.commit()
        return cur.lastrowid


def _load_quiz_questions(quiz_id):
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
            questions.append({
                "id": row["id"],
                "text": row["text"],
                "explicacion": row["explicacion"],
                "options": options,
                "correct_text": options[0],
            })
        return questions


def _get_quiz_title(quiz_id):
    if not quiz_id:
        return None
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("SELECT title FROM quizzes WHERE id = ?", (quiz_id,))
        row = cur.fetchone()
        return row["title"] if row else None


def _create_attempt(user_id, quiz_id, attempt_type):
    now = datetime.utcnow().isoformat()
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO attempts (user_id, quiz_id, attempt_type, started_at) VALUES (?, ?, ?, ?)",
            (user_id, quiz_id, attempt_type, now),
        )
        conn.commit()
        return cur.lastrowid


def _finish_attempt(attempt_id, correct, wrong):
    now = datetime.utcnow().isoformat()
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "UPDATE attempts SET finished_at = ?, correct = ?, wrong = ? WHERE id = ?",
            (now, correct, wrong, attempt_id),
        )
        conn.commit()


def _add_attempt_item(attempt_id, question_id, selected_option, is_correct):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "INSERT INTO attempt_items (attempt_id, question_id, selected_option, is_correct) VALUES (?, ?, ?, ?)",
            (attempt_id, question_id, selected_option, int(is_correct)),
        )
        conn.commit()


def _record_failure(user_id, question_id):
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


def _clear_failure(user_id, question_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "DELETE FROM failures WHERE user_id = ? AND question_id = ?",
            (user_id, question_id),
        )
        conn.commit()


def _get_failures_questions(user_id, limit_count):
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
            questions.append({
                "id": row["id"],
                "text": row["text"],
                "explicacion": row["explicacion"],
                "options": options,
                "correct_text": options[0],
            })
        return questions


def _get_favorites_questions(user_id, limit_count):
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
            questions.append({
                "id": row["id"],
                "text": row["text"],
                "explicacion": row["explicacion"],
                "options": options,
                "correct_text": options[0],
            })
        return questions


def _is_favorite(user_id, question_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "SELECT 1 FROM favorites WHERE user_id = ? AND question_id = ?",
            (user_id, question_id),
        )
        return cur.fetchone() is not None


def _add_favorite(user_id, question_id):
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


def _remove_favorite(user_id, question_id):
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(
            "DELETE FROM favorites WHERE user_id = ? AND question_id = ?",
            (user_id, question_id),
        )
        conn.commit()


def _get_progreso_general(user_id):
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
        "nota": round(nota, 2),
    }


def _get_progreso_por_tests(user_id):
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
        resumen.setdefault(quiz_id, {"titulo": fila["title"], "intentos": []})
        correct = fila["correct"]
        wrong = fila["wrong"]
        total = correct + wrong
        nota = max((correct - 0.3 * wrong) / total * 10, 0) if total else 0
        resumen[quiz_id]["intentos"].append({
            "correct": correct,
            "wrong": wrong,
            "nota": round(nota, 2),
        })
    return list(resumen.values())


def _contar_preguntas_hoy(user_id):
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


if __name__ == "__main__":
    init_db()
    app.run(host="0.0.0.0", port=WEB_PORT, debug=False)
