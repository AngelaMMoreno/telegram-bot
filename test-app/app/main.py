from flask import Blueprint, render_template, request, session, redirect, url_for, jsonify
from .auth import login_required
from . import db

main_bp = Blueprint("main", __name__)

PAGE_SIZE = 20


@main_bp.route("/")
@login_required
def home():
    user_id = session["user_id"]
    summary = db.get_progress_summary(user_id)
    general = db.get_progreso_general(user_id)
    hoy = db.contar_preguntas_respondidas_hoy(user_id)
    n_fallos = db.contar_fallos(user_id)
    n_favoritas = db.contar_favoritas(user_id)
    n_tests = db.contar_tests()
    return render_template("home.html",
                           summary=summary, general=general,
                           hoy=hoy, n_fallos=n_fallos,
                           n_favoritas=n_favoritas, n_tests=n_tests,
                           username=session.get("username", ""))


@main_bp.route("/tests")
@login_required
def tests():
    user_id = session["user_id"]
    page = max(1, request.args.get("page", 1, type=int))
    tab = request.args.get("tab", "all")
    offset = (page - 1) * PAGE_SIZE

    if tab == "favorites":
        total = db.contar_tests_favoritos(user_id)
        tests_list = db.listar_tests_favoritos_paginado(user_id, offset, PAGE_SIZE)
    else:
        total = db.contar_tests()
        tests_list = db.listar_tests_paginado(offset, PAGE_SIZE)

    quiz_ids = [t["id"] for t in tests_list]
    intentos = db.obtener_conteo_intentos_por_test(user_id, quiz_ids)
    pendientes = db.obtener_tests_pendientes(user_id)
    realizados = db.obtener_tests_realizados(user_id)
    favoritos = db.obtener_tests_favoritos(user_id)

    total_pages = max(1, (total + PAGE_SIZE - 1) // PAGE_SIZE)
    return render_template("tests.html",
                           tests=tests_list, intentos=intentos,
                           pendientes=pendientes, realizados=realizados,
                           favoritos=favoritos,
                           page=page, total_pages=total_pages, tab=tab)


@main_bp.route("/api/toggle-test-fav", methods=["POST"])
@login_required
def toggle_test_fav():
    user_id = session["user_id"]
    data = request.get_json()
    quiz_id = data.get("quiz_id")
    if not quiz_id:
        return jsonify({"error": "missing quiz_id"}), 400
    if db.es_test_favorito(user_id, quiz_id):
        db.quitar_test_favorito(user_id, quiz_id)
        return jsonify({"favorito": False})
    else:
        db.marcar_test_favorito(user_id, quiz_id)
        return jsonify({"favorito": True})


@main_bp.route("/progress")
@login_required
def progress():
    user_id = session["user_id"]
    general = db.get_progreso_general(user_id)
    por_tests = db.get_progreso_por_tests(user_id)
    summary = db.get_progress_summary(user_id)
    return render_template("progress.html",
                           general=general, por_tests=por_tests, summary=summary)


@main_bp.route("/simulacros")
@login_required
def simulacros():
    sims = db.listar_simulacros()
    return render_template("simulacros.html", simulacros=sims)
