import os
from flask import Flask
from .db import init_db


def create_app():
    app = Flask(__name__)
    app.secret_key = os.environ.get("SECRET_KEY", "dev-secret-key-change-me")
    app.config["DB_FILE"] = os.path.join("/app/bd", "bot.db")
    app.config["PERMANENT_SESSION_LIFETIME"] = 60 * 60 * 24 * 30  # 30 days

    init_db(app)

    from .auth import auth_bp
    from .main import main_bp
    from .quiz import quiz_bp

    app.register_blueprint(auth_bp)
    app.register_blueprint(main_bp)
    app.register_blueprint(quiz_bp)

    return app
