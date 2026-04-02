import random
from flask import Blueprint, render_template, request, session, redirect, url_for, jsonify
from .auth import login_required
from . import db

quiz_bp = Blueprint("quiz", __name__)


@quiz_bp.route("/quiz/<int:quiz_id>")
@login_required
def quiz_page(quiz_id):
    title = db.obtener_titulo_test(quiz_id)
    if not title:
        return redirect(url_for("main.tests"))
    return render_template("quiz.html", quiz_id=quiz_id, title=title,
                           mode="quiz", simulacro_id=None)


@quiz_bp.route("/quiz/failures")
@login_required
def quiz_failures():
    return render_template("quiz.html", quiz_id=None, title="Test de Fallos",
                           mode="failures", simulacro_id=None)


@quiz_bp.route("/quiz/favorites")
@login_required
def quiz_favorites():
    return render_template("quiz.html", quiz_id=None, title="Test de Favoritas",
                           mode="favoritas", simulacro_id=None)


@quiz_bp.route("/quiz/simulacro/<int:simulacro_id>")
@login_required
def quiz_simulacro(simulacro_id):
    sim = db.obtener_simulacro(simulacro_id)
    if not sim:
        return redirect(url_for("main.simulacros"))
    return render_template("quiz.html", quiz_id=sim["quiz_id"],
                           title=sim["nombre"], mode="simulacro",
                           simulacro_id=simulacro_id)


# ── API endpoints ──

@quiz_bp.route("/api/quiz/start", methods=["POST"])
@login_required
def api_start_quiz():
    user_id = session["user_id"]
    data = request.get_json()
    mode = data.get("mode", "quiz")
    quiz_id = data.get("quiz_id")
    simulacro_id = data.get("simulacro_id")

    if mode == "quiz":
        if not quiz_id:
            return jsonify({"error": "missing quiz_id"}), 400
        # Check for pending attempt
        pending = db.obtener_intento_pendiente(user_id, quiz_id)
        if pending:
            questions = db.load_quiz_questions(quiz_id)
            answered = db.obtener_preguntas_respondidas(pending["id"])
            remaining = [q for q in questions if q["id"] not in answered]
            for q in remaining:
                shuffled = q["options"][:]
                random.shuffle(shuffled)
                q["shuffled_options"] = shuffled
            return jsonify({
                "attempt_id": pending["id"],
                "questions": _sanitize_questions(remaining),
                "correct": pending["correct"],
                "wrong": pending["wrong"],
                "total_original": len(questions),
                "resumed": True,
            })
        questions = db.load_quiz_questions(quiz_id)
        if not questions:
            return jsonify({"error": "No hay preguntas"}), 400
        random.shuffle(questions)
        for q in questions:
            shuffled = q["options"][:]
            random.shuffle(shuffled)
            q["shuffled_options"] = shuffled
        attempt_id = db.create_attempt(user_id, quiz_id, "quiz")
        return jsonify({
            "attempt_id": attempt_id,
            "questions": _sanitize_questions(questions),
            "correct": 0, "wrong": 0,
            "total_original": len(questions),
            "resumed": False,
        })

    elif mode == "failures":
        pending = db.obtener_intento_pendiente_por_tipo(user_id, "failures")
        if pending:
            questions = db.obtener_test_temporal(pending["id"])
            answered = db.obtener_preguntas_respondidas(pending["id"])
            remaining = [q for q in questions if q["id"] not in answered]
            for q in remaining:
                shuffled = q["options"][:]
                random.shuffle(shuffled)
                q["shuffled_options"] = shuffled
            return jsonify({
                "attempt_id": pending["id"],
                "questions": _sanitize_questions(remaining),
                "correct": pending["correct"],
                "wrong": pending["wrong"],
                "total_original": len(questions),
                "resumed": True,
            })
        questions = db.get_failures_questions(user_id, db.TAMANO_TEST_TEMPORAL)
        if not questions:
            return jsonify({"error": "No tienes preguntas falladas"}), 400
        random.shuffle(questions)
        for q in questions:
            shuffled = q["options"][:]
            random.shuffle(shuffled)
            q["shuffled_options"] = shuffled
        attempt_id = db.create_attempt(user_id, None, "failures")
        db.guardar_test_temporal(attempt_id, questions)
        return jsonify({
            "attempt_id": attempt_id,
            "questions": _sanitize_questions(questions),
            "correct": 0, "wrong": 0,
            "total_original": len(questions),
            "resumed": False,
        })

    elif mode == "favoritas":
        pending = db.obtener_intento_pendiente_por_tipo(user_id, "favoritas")
        if pending:
            questions = db.obtener_test_temporal(pending["id"])
            answered = db.obtener_preguntas_respondidas(pending["id"])
            remaining = [q for q in questions if q["id"] not in answered]
            for q in remaining:
                shuffled = q["options"][:]
                random.shuffle(shuffled)
                q["shuffled_options"] = shuffled
            return jsonify({
                "attempt_id": pending["id"],
                "questions": _sanitize_questions(remaining),
                "correct": pending["correct"],
                "wrong": pending["wrong"],
                "total_original": len(questions),
                "resumed": True,
            })
        questions = db.get_favorites_questions(user_id, db.TAMANO_TEST_FAVORITAS)
        if not questions:
            return jsonify({"error": "No tienes preguntas favoritas"}), 400
        random.shuffle(questions)
        for q in questions:
            shuffled = q["options"][:]
            random.shuffle(shuffled)
            q["shuffled_options"] = shuffled
        attempt_id = db.create_attempt(user_id, None, "favoritas")
        db.guardar_test_temporal(attempt_id, questions)
        return jsonify({
            "attempt_id": attempt_id,
            "questions": _sanitize_questions(questions),
            "correct": 0, "wrong": 0,
            "total_original": len(questions),
            "resumed": False,
        })

    elif mode == "simulacro":
        if not quiz_id:
            return jsonify({"error": "missing quiz_id"}), 400
        pending = db.obtener_intento_pendiente_por_tipo(user_id, "simulacro")
        if pending:
            questions = db.obtener_test_temporal(pending["id"])
            answered = db.obtener_preguntas_respondidas(pending["id"])
            remaining = [q for q in questions if q["id"] not in answered]
            for q in remaining:
                shuffled = q["options"][:]
                random.shuffle(shuffled)
                q["shuffled_options"] = shuffled
            return jsonify({
                "attempt_id": pending["id"],
                "questions": _sanitize_questions(remaining),
                "correct": pending["correct"],
                "wrong": pending["wrong"],
                "total_original": len(questions),
                "resumed": True,
            })
        questions = db.load_quiz_questions(quiz_id)
        if not questions:
            return jsonify({"error": "No hay preguntas"}), 400
        for q in questions:
            shuffled = q["options"][:]
            random.shuffle(shuffled)
            q["shuffled_options"] = shuffled
        attempt_id = db.create_attempt(user_id, quiz_id, "simulacro")
        db.guardar_test_temporal(attempt_id, questions)
        return jsonify({
            "attempt_id": attempt_id,
            "questions": _sanitize_questions(questions),
            "correct": 0, "wrong": 0,
            "total_original": len(questions),
            "resumed": False,
        })

    return jsonify({"error": "Modo no valido"}), 400


@quiz_bp.route("/api/quiz/answer", methods=["POST"])
@login_required
def api_answer():
    user_id = session["user_id"]
    data = request.get_json()
    attempt_id = data.get("attempt_id")
    question_id = data.get("question_id")
    selected = data.get("selected_option")
    correct_text = data.get("correct_text")
    mode = data.get("mode", "quiz")

    if not all([attempt_id, question_id, selected is not None, correct_text]):
        return jsonify({"error": "missing fields"}), 400

    is_correct = selected == correct_text
    db.add_attempt_item(attempt_id, question_id, selected, is_correct)

    if is_correct:
        if mode in ("failures",):
            db.clear_failure(user_id, question_id)
    else:
        db.record_failure(user_id, question_id)

    return jsonify({"is_correct": is_correct})


@quiz_bp.route("/api/quiz/skip", methods=["POST"])
@login_required
def api_skip():
    """For simulacro: record a blank answer."""
    data = request.get_json()
    attempt_id = data.get("attempt_id")
    question_id = data.get("question_id")
    if not attempt_id or not question_id:
        return jsonify({"error": "missing fields"}), 400
    db.add_attempt_item(attempt_id, question_id, "__blank__", False)
    return jsonify({"ok": True})


@quiz_bp.route("/api/quiz/finish", methods=["POST"])
@login_required
def api_finish():
    user_id = session["user_id"]
    data = request.get_json()
    attempt_id = data.get("attempt_id")
    correct = data.get("correct", 0)
    wrong = data.get("wrong", 0)
    mode = data.get("mode", "quiz")
    simulacro_id = data.get("simulacro_id")

    db.finish_attempt(attempt_id, correct, wrong)

    total = correct + wrong
    penalizacion = db.PENALIZACION_FALLO
    nota = max((correct - penalizacion * wrong) / total * 10, 0) if total else 0

    result = {
        "correct": correct,
        "wrong": wrong,
        "total": total,
        "nota": round(nota, 2),
    }

    if mode == "simulacro" and simulacro_id:
        sim = db.obtener_simulacro(simulacro_id)
        if sim:
            # Calculate simulacro results from attempt_items
            sim_result = _calcular_simulacro_desde_intento(attempt_id, sim)
            result["simulacro"] = sim_result

    return jsonify(result)


@quiz_bp.route("/api/quiz/discard", methods=["POST"])
@login_required
def api_discard():
    user_id = session["user_id"]
    data = request.get_json()
    mode = data.get("mode", "quiz")
    quiz_id = data.get("quiz_id")

    if mode == "quiz" and quiz_id:
        db.descartar_intentos_pendientes(user_id, quiz_id)
    elif mode in ("failures", "favoritas", "simulacro"):
        db.descartar_intentos_pendientes_por_tipo(user_id, mode)
    return jsonify({"ok": True})


@quiz_bp.route("/api/quiz/toggle-favorite", methods=["POST"])
@login_required
def api_toggle_favorite():
    user_id = session["user_id"]
    data = request.get_json()
    question_id = data.get("question_id")
    if not question_id:
        return jsonify({"error": "missing question_id"}), 400
    if db.es_pregunta_favorita(user_id, question_id):
        db.quitar_favorita(user_id, question_id)
        return jsonify({"favorita": False})
    else:
        db.agregar_favorita(user_id, question_id)
        return jsonify({"favorita": True})


@quiz_bp.route("/api/quiz/is-favorite", methods=["POST"])
@login_required
def api_is_favorite():
    user_id = session["user_id"]
    data = request.get_json()
    question_id = data.get("question_id")
    if not question_id:
        return jsonify({"error": "missing question_id"}), 400
    return jsonify({"favorita": db.es_pregunta_favorita(user_id, question_id)})


@quiz_bp.route("/results")
@login_required
def results_page():
    return render_template("results.html")


@quiz_bp.route("/simulacro-results")
@login_required
def simulacro_results_page():
    return render_template("simulacro_results.html")


def _sanitize_questions(questions):
    """Return questions safe to send to client (no correct answer exposed directly)."""
    result = []
    for q in questions:
        result.append({
            "id": q["id"],
            "text": q["text"],
            "explicacion": q.get("explicacion"),
            "options": q.get("shuffled_options", q["options"]),
            "correct_text": q["correct_text"],
        })
    return result


def _calcular_simulacro_desde_intento(attempt_id, sim):
    """Calculate simulacro scoring from attempt items."""
    d = db.get_db()
    items = d.execute("""
        SELECT ai.question_id, ai.selected_option, ai.is_correct
        FROM attempt_items ai
        WHERE ai.attempt_id = ?
        ORDER BY ai.id ASC
    """, (attempt_id,)).fetchall()

    total_p1 = db.PREGUNTAS_PARTE_1_SIMULACRO
    aciertos_p1 = errores_p1 = 0
    aciertos_p2 = errores_p2 = 0

    for idx, item in enumerate(items):
        is_blank = item["selected_option"] == "__blank__"
        if idx < total_p1:
            if is_blank:
                continue
            if item["is_correct"]:
                aciertos_p1 += 1
            else:
                errores_p1 += 1
        else:
            if is_blank:
                continue
            if item["is_correct"]:
                aciertos_p2 += 1
            else:
                errores_p2 += 1

    total_p2 = max(0, len(items) - total_p1)
    return db.calcular_resultado_simulacro(
        aciertos_p1, errores_p1, aciertos_p2, errores_p2,
        total_p1=min(total_p1, len(items)), total_p2=total_p2,
    )
