import os
import json
import sqlite3
from datetime import datetime
from flask import g, current_app

PENALIZACION_FALLO = 1 / 3
TAMANO_TEST_FAVORITAS = 40
TAMANO_TEST_TEMPORAL = 40
PREGUNTAS_PARTE_1_SIMULACRO = 80
PUNTOS_ACIERTO_PARTE_2 = 4
N_MAX_SIMULACRO = 160
E_MAX_SIMULACRO = 100
MIN_DIRECTA_SIMULACRO = N_MAX_SIMULACRO * 0.30
PLAZAS_REFERENCIA_SIMULACRO = int(os.environ.get("PLAZAS_REFERENCIA_SIMULACRO", "844"))


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


def get_db():
    if "db" not in g:
        g.db = sqlite3.connect(current_app.config["DB_FILE"])
        g.db.row_factory = sqlite3.Row
    return g.db


def close_db(e=None):
    db = g.pop("db", None)
    if db is not None:
        db.close()


def init_db(app):
    app.teardown_appcontext(close_db)
    db_file = app.config["DB_FILE"]
    if os.path.exists(db_file):
        conn = sqlite3.connect(db_file)
        conn.row_factory = sqlite3.Row
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
        conn.close()


# ── Auth helpers ──

def get_web_user_by_username(username):
    db = get_db()
    return db.execute(
        "SELECT * FROM web_users WHERE username = ?", (username,)
    ).fetchone()


def get_web_user_by_id(web_user_id):
    db = get_db()
    return db.execute(
        "SELECT * FROM web_users WHERE id = ?", (web_user_id,)
    ).fetchone()


def create_web_user(username, password_hash):
    db = get_db()
    now = datetime.utcnow().isoformat()
    # Create corresponding user in users table
    chat_id = f"web_{username}"
    row = db.execute("SELECT id FROM users WHERE chat_id = ?", (chat_id,)).fetchone()
    if row:
        user_id = row["id"]
    else:
        cur = db.execute(
            "INSERT INTO users (chat_id, created_at) VALUES (?, ?)",
            (chat_id, now),
        )
        db.commit()
        user_id = cur.lastrowid
    cur = db.execute(
        "INSERT INTO web_users (username, password_hash, user_id, created_at) VALUES (?, ?, ?, ?)",
        (username, password_hash, user_id, now),
    )
    db.commit()
    return cur.lastrowid


# ── Quiz listing ──

def listar_tests_paginado(offset, limit):
    db = get_db()
    return db.execute("""
        SELECT q.id, q.title, q.description, COUNT(que.id) AS total_preguntas
        FROM quizzes q
        LEFT JOIN questions que ON que.quiz_id = q.id
        GROUP BY q.id
        ORDER BY q.id DESC
        LIMIT ? OFFSET ?
    """, (limit, offset)).fetchall()


def contar_tests():
    db = get_db()
    row = db.execute("SELECT COUNT(*) AS total FROM quizzes").fetchone()
    return row["total"] if row else 0


def obtener_conteo_intentos_por_test(user_id, quiz_ids):
    if not quiz_ids:
        return {}
    db = get_db()
    placeholders = ",".join("?" for _ in quiz_ids)
    rows = db.execute(f"""
        SELECT quiz_id, COUNT(*) AS total_intentos
        FROM attempts
        WHERE user_id = ? AND quiz_id IN ({placeholders}) AND finished_at IS NOT NULL
        GROUP BY quiz_id
    """, [user_id, *quiz_ids]).fetchall()
    return {r["quiz_id"]: r["total_intentos"] for r in rows}


def obtener_tests_pendientes(user_id):
    db = get_db()
    rows = db.execute("""
        SELECT DISTINCT quiz_id FROM attempts
        WHERE user_id = ? AND attempt_type = 'quiz' AND finished_at IS NULL AND quiz_id IS NOT NULL
    """, (user_id,)).fetchall()
    return {r["quiz_id"] for r in rows}


def obtener_tests_realizados(user_id):
    db = get_db()
    rows = db.execute("""
        SELECT DISTINCT quiz_id FROM attempts
        WHERE user_id = ? AND attempt_type = 'quiz' AND finished_at IS NOT NULL AND quiz_id IS NOT NULL
    """, (user_id,)).fetchall()
    return {r["quiz_id"] for r in rows}


def obtener_tests_favoritos(user_id):
    db = get_db()
    rows = db.execute(
        "SELECT quiz_id FROM tests_favoritos WHERE user_id = ?", (user_id,)
    ).fetchall()
    return {r["quiz_id"] for r in rows}


def contar_tests_favoritos(user_id):
    db = get_db()
    row = db.execute(
        "SELECT COUNT(*) AS total FROM tests_favoritos WHERE user_id = ?", (user_id,)
    ).fetchone()
    return row["total"] if row else 0


def listar_tests_favoritos_paginado(user_id, offset, limit):
    db = get_db()
    return db.execute("""
        SELECT q.id, q.title, q.description, COUNT(que.id) AS total_preguntas
        FROM tests_favoritos tf
        JOIN quizzes q ON q.id = tf.quiz_id
        LEFT JOIN questions que ON que.quiz_id = q.id
        WHERE tf.user_id = ?
        GROUP BY q.id
        ORDER BY tf.created_at DESC
        LIMIT ? OFFSET ?
    """, (user_id, limit, offset)).fetchall()


def marcar_test_favorito(user_id, quiz_id):
    db = get_db()
    now = datetime.utcnow().isoformat()
    db.execute("""
        INSERT INTO tests_favoritos (user_id, quiz_id, created_at)
        VALUES (?, ?, ?) ON CONFLICT(user_id, quiz_id) DO NOTHING
    """, (user_id, quiz_id, now))
    db.commit()


def quitar_test_favorito(user_id, quiz_id):
    db = get_db()
    db.execute("DELETE FROM tests_favoritos WHERE user_id = ? AND quiz_id = ?", (user_id, quiz_id))
    db.commit()


def es_test_favorito(user_id, quiz_id):
    db = get_db()
    return db.execute(
        "SELECT 1 FROM tests_favoritos WHERE user_id = ? AND quiz_id = ?", (user_id, quiz_id)
    ).fetchone() is not None


# ── Quiz questions ──

def load_quiz_questions(quiz_id):
    db = get_db()
    rows = db.execute(
        "SELECT id, text, explicacion FROM questions WHERE quiz_id = ?", (quiz_id,)
    ).fetchall()
    questions = []
    for row in rows:
        opts = db.execute(
            "SELECT text, position FROM options WHERE question_id = ? ORDER BY position ASC",
            (row["id"],)
        ).fetchall()
        options = [o["text"] for o in opts]
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


def obtener_titulo_test(quiz_id):
    db = get_db()
    row = db.execute("SELECT title FROM quizzes WHERE id = ?", (quiz_id,)).fetchone()
    return row["title"] if row else None


# ── Attempts ──

def create_attempt(user_id, quiz_id, attempt_type):
    db = get_db()
    now = datetime.utcnow().isoformat()
    cur = db.execute("""
        INSERT INTO attempts (user_id, quiz_id, attempt_type, started_at)
        VALUES (?, ?, ?, ?)
    """, (user_id, quiz_id, attempt_type, now))
    db.commit()
    return cur.lastrowid


def finish_attempt(attempt_id, correct, wrong):
    db = get_db()
    now = datetime.utcnow().isoformat()
    db.execute("""
        UPDATE attempts SET finished_at = ?, correct = ?, wrong = ? WHERE id = ?
    """, (now, correct, wrong, attempt_id))
    db.execute("DELETE FROM tests_temporales WHERE attempt_id = ?", (attempt_id,))
    db.commit()


def add_attempt_item(attempt_id, question_id, selected_option, is_correct):
    db = get_db()
    db.execute("""
        INSERT INTO attempt_items (attempt_id, question_id, selected_option, is_correct)
        VALUES (?, ?, ?, ?)
    """, (attempt_id, question_id, selected_option, int(is_correct)))
    db.commit()


def obtener_preguntas_respondidas(attempt_id):
    db = get_db()
    rows = db.execute(
        "SELECT question_id FROM attempt_items WHERE attempt_id = ?", (attempt_id,)
    ).fetchall()
    return {r["question_id"] for r in rows}


def obtener_intento_pendiente(user_id, quiz_id):
    db = get_db()
    row = db.execute("""
        SELECT id, correct, wrong FROM attempts
        WHERE user_id = ? AND quiz_id = ? AND attempt_type = 'quiz' AND finished_at IS NULL
        ORDER BY started_at DESC LIMIT 1
    """, (user_id, quiz_id)).fetchone()
    if row:
        return {"id": row["id"], "correct": row["correct"], "wrong": row["wrong"]}
    return None


def obtener_intento_pendiente_por_tipo(user_id, tipo):
    db = get_db()
    row = db.execute("""
        SELECT id, correct, wrong FROM attempts
        WHERE user_id = ? AND attempt_type = ? AND finished_at IS NULL
        ORDER BY started_at DESC LIMIT 1
    """, (user_id, tipo)).fetchone()
    if row:
        return {"id": row["id"], "correct": row["correct"], "wrong": row["wrong"]}
    return None


def descartar_intentos_pendientes(user_id, quiz_id=None):
    db = get_db()
    if quiz_id is not None:
        rows = db.execute("""
            SELECT id FROM attempts
            WHERE user_id = ? AND quiz_id = ? AND finished_at IS NULL AND attempt_type = 'quiz'
        """, (user_id, quiz_id)).fetchall()
    else:
        rows = db.execute("""
            SELECT id FROM attempts
            WHERE user_id = ? AND finished_at IS NULL AND attempt_type = 'quiz'
        """, (user_id,)).fetchall()
    for r in rows:
        db.execute("DELETE FROM attempt_items WHERE attempt_id = ?", (r["id"],))
        db.execute("DELETE FROM tests_temporales WHERE attempt_id = ?", (r["id"],))
        db.execute("DELETE FROM attempts WHERE id = ?", (r["id"],))
    db.commit()


def descartar_intentos_pendientes_por_tipo(user_id, tipo):
    db = get_db()
    rows = db.execute("""
        SELECT id FROM attempts
        WHERE user_id = ? AND attempt_type = ? AND finished_at IS NULL
    """, (user_id, tipo)).fetchall()
    for r in rows:
        db.execute("DELETE FROM attempt_items WHERE attempt_id = ?", (r["id"],))
        db.execute("DELETE FROM tests_temporales WHERE attempt_id = ?", (r["id"],))
        db.execute("DELETE FROM attempts WHERE id = ?", (r["id"],))
    db.commit()


def guardar_test_temporal(attempt_id, preguntas):
    db = get_db()
    for pos, p in enumerate(preguntas):
        db.execute("""
            INSERT INTO tests_temporales (attempt_id, question_id, posicion)
            VALUES (?, ?, ?)
        """, (attempt_id, p["id"], pos))
    db.commit()


def obtener_test_temporal(attempt_id):
    db = get_db()
    rows = db.execute("""
        SELECT question_id FROM tests_temporales
        WHERE attempt_id = ? ORDER BY posicion ASC
    """, (attempt_id,)).fetchall()
    if not rows:
        return []
    questions = []
    for r in rows:
        q = db.execute(
            "SELECT id, text, explicacion FROM questions WHERE id = ?", (r["question_id"],)
        ).fetchone()
        if not q:
            continue
        opts = db.execute(
            "SELECT text, position FROM options WHERE question_id = ? ORDER BY position ASC",
            (r["question_id"],)
        ).fetchall()
        options = [o["text"] for o in opts]
        if not options:
            continue
        questions.append({
            "id": q["id"],
            "text": q["text"],
            "explicacion": q["explicacion"],
            "options": options,
            "correct_text": options[0],
        })
    return questions


# ── Failures ──

def record_failure(user_id, question_id):
    db = get_db()
    now = datetime.utcnow().isoformat()
    db.execute("""
        INSERT INTO failures (user_id, question_id, fail_count, last_failed_at)
        VALUES (?, ?, 1, ?)
        ON CONFLICT(user_id, question_id)
        DO UPDATE SET fail_count = fail_count + 1, last_failed_at = excluded.last_failed_at
    """, (user_id, question_id, now))
    db.commit()


def clear_failure(user_id, question_id):
    db = get_db()
    db.execute("DELETE FROM failures WHERE user_id = ? AND question_id = ?", (user_id, question_id))
    db.commit()


def get_failures_questions(user_id, limit_count):
    db = get_db()
    rows = db.execute("""
        SELECT q.id, q.text, q.explicacion
        FROM failures f JOIN questions q ON q.id = f.question_id
        WHERE f.user_id = ? ORDER BY f.last_failed_at DESC LIMIT ?
    """, (user_id, limit_count)).fetchall()
    questions = []
    for row in rows:
        opts = db.execute(
            "SELECT text, position FROM options WHERE question_id = ? ORDER BY position ASC",
            (row["id"],)
        ).fetchall()
        options = [o["text"] for o in opts]
        if not options:
            continue
        questions.append({
            "id": row["id"], "text": row["text"], "explicacion": row["explicacion"],
            "options": options, "correct_text": options[0],
        })
    return questions


def contar_fallos(user_id):
    db = get_db()
    row = db.execute("SELECT COUNT(*) AS total FROM failures WHERE user_id = ?", (user_id,)).fetchone()
    return row["total"] if row else 0


# ── Favorites ──

def agregar_favorita(user_id, question_id):
    db = get_db()
    now = datetime.utcnow().isoformat()
    db.execute("""
        INSERT INTO favorites (user_id, question_id, created_at)
        VALUES (?, ?, ?) ON CONFLICT(user_id, question_id) DO NOTHING
    """, (user_id, question_id, now))
    db.commit()


def quitar_favorita(user_id, question_id):
    db = get_db()
    db.execute("DELETE FROM favorites WHERE user_id = ? AND question_id = ?", (user_id, question_id))
    db.commit()


def es_pregunta_favorita(user_id, question_id):
    db = get_db()
    return db.execute(
        "SELECT 1 FROM favorites WHERE user_id = ? AND question_id = ?", (user_id, question_id)
    ).fetchone() is not None


def get_favorites_questions(user_id, limit_count):
    db = get_db()
    rows = db.execute("""
        SELECT q.id, q.text, q.explicacion
        FROM favorites f JOIN questions q ON q.id = f.question_id
        WHERE f.user_id = ? ORDER BY f.created_at DESC LIMIT ?
    """, (user_id, limit_count)).fetchall()
    questions = []
    for row in rows:
        opts = db.execute(
            "SELECT text, position FROM options WHERE question_id = ? ORDER BY position ASC",
            (row["id"],)
        ).fetchall()
        options = [o["text"] for o in opts]
        if not options:
            continue
        questions.append({
            "id": row["id"], "text": row["text"], "explicacion": row["explicacion"],
            "options": options, "correct_text": options[0],
        })
    return questions


def contar_favoritas(user_id):
    db = get_db()
    row = db.execute("SELECT COUNT(*) AS total FROM favorites WHERE user_id = ?", (user_id,)).fetchone()
    return row["total"] if row else 0


# ── Progress ──

def get_progress_summary(user_id):
    db = get_db()
    stats = db.execute("""
        SELECT COALESCE(SUM(correct), 0) AS total_correct,
               COALESCE(SUM(wrong), 0) AS total_wrong,
               COUNT(*) AS total_attempts
        FROM attempts WHERE user_id = ?
    """, (user_id,)).fetchone()
    failed = db.execute(
        "SELECT COUNT(*) AS failed_q FROM failures WHERE user_id = ?", (user_id,)
    ).fetchone()
    return {
        "total_correct": stats["total_correct"],
        "total_wrong": stats["total_wrong"],
        "total_attempts": stats["total_attempts"],
        "failed_q": failed["failed_q"],
    }


def get_progreso_general(user_id):
    db = get_db()
    rows = db.execute("""
        SELECT a.correct, a.wrong
        FROM attempts a
        JOIN (
            SELECT quiz_id, MAX(id) AS ultimo_id
            FROM attempts
            WHERE user_id = ? AND attempt_type = 'quiz' AND finished_at IS NOT NULL
            GROUP BY quiz_id
        ) ult ON ult.ultimo_id = a.id
    """, (user_id,)).fetchall()
    total_correct = sum(r["correct"] for r in rows)
    total_wrong = sum(r["wrong"] for r in rows)
    total = total_correct + total_wrong
    nota = max((total_correct - PENALIZACION_FALLO * total_wrong) / total * 10, 0) if total else 0
    return {"total_correct": total_correct, "total_wrong": total_wrong, "nota": nota}


def get_progreso_por_tests(user_id):
    db = get_db()
    rows = db.execute("""
        SELECT q.id AS quiz_id, q.title, a.correct, a.wrong, a.started_at
        FROM attempts a JOIN quizzes q ON q.id = a.quiz_id
        WHERE a.user_id = ? AND a.attempt_type = 'quiz' AND a.finished_at IS NOT NULL
        ORDER BY q.id, a.started_at
    """, (user_id,)).fetchall()
    resumen = {}
    for r in rows:
        qid = r["quiz_id"]
        resumen.setdefault(qid, {"titulo": r["title"], "intentos": []})
        correct, wrong = r["correct"], r["wrong"]
        total = correct + wrong
        nota = max((correct - PENALIZACION_FALLO * wrong) / total * 10, 0) if total else 0
        resumen[qid]["intentos"].append({"correct": correct, "wrong": wrong, "nota": nota})
    return list(resumen.values())


def contar_preguntas_respondidas_hoy(user_id):
    db = get_db()
    row = db.execute("""
        SELECT COUNT(ai.id) AS total
        FROM attempt_items ai JOIN attempts a ON a.id = ai.attempt_id
        WHERE a.user_id = ? AND date(a.started_at) = date('now')
    """, (user_id,)).fetchone()
    return row["total"] if row else 0


# ── Simulacros ──

def listar_simulacros():
    db = get_db()
    return db.execute("""
        SELECT s.id, s.nombre, s.quiz_id, s.nota_corte_directa, s.escala_maxima,
               q.title AS test_titulo
        FROM simulacros s JOIN quizzes q ON q.id = s.quiz_id
        ORDER BY s.id DESC
    """).fetchall()


def obtener_simulacro(simulacro_id):
    db = get_db()
    return db.execute("""
        SELECT s.id, s.nombre, s.quiz_id, s.nota_corte_directa, s.escala_maxima,
               q.title AS test_titulo
        FROM simulacros s JOIN quizzes q ON q.id = s.quiz_id
        WHERE s.id = ?
    """, (simulacro_id,)).fetchone()


def nota_corte_para_plazas(plazas, historico):
    if not historico:
        return None
    for puntuacion, posicion in historico:
        if posicion >= plazas:
            return puntuacion
    return historico[-1][0]


def estimar_posicion_en_historico(puntuacion, historico):
    if not historico:
        return None
    if puntuacion >= historico[0][0]:
        return 1
    for i in range(len(historico) - 1):
        pa, posa = historico[i]
        pb, posb = historico[i + 1]
        if puntuacion >= pb:
            if pa == pb:
                return posb
            fraccion = (pa - puntuacion) / (pa - pb)
            return round(posa + fraccion * (posb - posa))
    return historico[-1][1] + 1


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


def calcular_resultado_simulacro(aciertos_p1, errores_p1, aciertos_p2, errores_p2,
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
