import functools
from flask import Blueprint, render_template, request, redirect, url_for, session, flash
from werkzeug.security import generate_password_hash, check_password_hash
from .db import get_web_user_by_username, get_web_user_by_id, create_web_user

auth_bp = Blueprint("auth", __name__)


def login_required(view):
    @functools.wraps(view)
    def wrapped(**kwargs):
        if "web_user_id" not in session:
            return redirect(url_for("auth.login"))
        return view(**kwargs)
    return wrapped


def get_current_user():
    wid = session.get("web_user_id")
    if not wid:
        return None
    return get_web_user_by_id(wid)


@auth_bp.route("/login", methods=["GET", "POST"])
def login():
    if "web_user_id" in session:
        return redirect(url_for("main.home"))
    if request.method == "POST":
        username = (request.form.get("username") or "").strip().lower()
        password = request.form.get("password") or ""
        if not username or not password:
            flash("Introduce usuario y contrasena.", "error")
            return render_template("login.html")
        user = get_web_user_by_username(username)
        if not user or not check_password_hash(user["password_hash"], password):
            flash("Usuario o contrasena incorrectos.", "error")
            return render_template("login.html")
        session.permanent = True
        session["web_user_id"] = user["id"]
        session["user_id"] = user["user_id"]
        session["username"] = user["username"]
        return redirect(url_for("main.home"))
    return render_template("login.html")


@auth_bp.route("/register", methods=["GET", "POST"])
def register():
    if "web_user_id" in session:
        return redirect(url_for("main.home"))
    if request.method == "POST":
        username = (request.form.get("username") or "").strip().lower()
        password = request.form.get("password") or ""
        password2 = request.form.get("password2") or ""
        if not username or not password:
            flash("Todos los campos son obligatorios.", "error")
            return render_template("register.html")
        if len(username) < 3:
            flash("El usuario debe tener al menos 3 caracteres.", "error")
            return render_template("register.html")
        if len(password) < 4:
            flash("La contrasena debe tener al menos 4 caracteres.", "error")
            return render_template("register.html")
        if password != password2:
            flash("Las contrasenas no coinciden.", "error")
            return render_template("register.html")
        existing = get_web_user_by_username(username)
        if existing:
            flash("Ese nombre de usuario ya existe.", "error")
            return render_template("register.html")
        pw_hash = generate_password_hash(password)
        create_web_user(username, pw_hash)
        flash("Cuenta creada. Inicia sesion.", "success")
        return redirect(url_for("auth.login"))
    return render_template("register.html")


@auth_bp.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("auth.login"))
