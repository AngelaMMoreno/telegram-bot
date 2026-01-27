import os
import json
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

QUIZZES_FILE = "quizzes.json"
USERS_DIR = "users"

# ─────────────── Asegurarse que exista carpeta de usuarios ───────────────
if not os.path.exists(USERS_DIR):
    os.mkdir(USERS_DIR)

# ─────────────── Utilidades ───────────────
def cargar_quizzes():
    if not os.path.exists(QUIZZES_FILE):
        return []
    with open(QUIZZES_FILE, "r", encoding="utf-8") as f:
        return json.load(f)

def guardar_quizzes(quizzes):
    with open(QUIZZES_FILE, "w", encoding="utf-8") as f:
        json.dump(quizzes, f, ensure_ascii=False, indent=2)

def cargar_usuario(chat_id):
    user_file = os.path.join(USERS_DIR, f"{chat_id}.json")
    if os.path.exists(user_file):
        with open(user_file, "r", encoding="utf-8") as f:
            return json.load(f)
    else:
        return {"fallos": [], "historial_tests": []}

def guardar_usuario(chat_id, data):
    user_file = os.path.join(USERS_DIR, f"{chat_id}.json")
    with open(user_file, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

# ─────────────── Parseo de texto pegado ───────────────
def parse_text(text):
    preguntas = []
    current = None
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("===="):
            if current:
                preguntas.append(current)
            current = {"pregunta": "", "opciones": [], "correcta": None}
        elif line.startswith("+") and current:
            current["opciones"].append(line[1:].strip())
            current["correcta"] = len(current["opciones"]) - 1
        elif line.startswith("-") and current:
            current["opciones"].append(line[1:].strip())
        elif line and current:
            current["pregunta"] += line + " "
    if current:
        preguntas.append(current)
    return preguntas

# ─────────────── /start ───────────────
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await mostrar_menu(update.message.chat.id, context, "👋 Bienvenido al QuizBot")

# ─────────────── Menú principal ───────────────
async def mostrar_menu(chat_id, context, texto="Selecciona una opción:"):
    botones = [
        [InlineKeyboardButton("✍️ Pegar preguntas", callback_data="pegar_texto")],
        [InlineKeyboardButton("📋 Mis quizzes", callback_data="mis_quizzes")],
        [InlineKeyboardButton("📊 Estadísticas", callback_data="estadisticas")],
        [InlineKeyboardButton("📊 Estadísticas de test", callback_data="estadisticas_test")],
        [InlineKeyboardButton("⚠️ Test de fallos", callback_data="test_fallos")],
        [InlineKeyboardButton("📊 Estadísticas de usuarios", callback_data="estadisticas_usuarios")],
    ]
    await context.bot.send_message(
        chat_id, texto, reply_markup=InlineKeyboardMarkup(botones)
    )

# ─────────────── Botones ───────────────
async def handle_button(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    data = query.data
    chat_id = query.message.chat_id
    user_data = cargar_usuario(chat_id)

    if data == "pegar_texto":
        context.user_data["modo"] = "texto"
        await query.message.reply_text(
            "✍️ Pega las preguntas en el formato correcto.\nCuando termines escribe: /fin"
        )
    elif data == "mis_quizzes":
        await mostrar_quizzes(chat_id, context)
    elif data.startswith("empezar_"):
        quiz_id = int(data.split("_")[1])
        await iniciar_quiz(chat_id, context, quiz_id)
    elif data == "estadisticas":
        await mostrar_estadisticas_acumuladas(chat_id, context, user_data)
    elif data == "estadisticas_test":
        await mostrar_menu_estadisticas_tests(chat_id, context, user_data)
    elif data.startswith("ver_test_"):
        quiz_id = int(data.split("_")[2])
        await mostrar_tests_quiz(chat_id, context, quiz_id, user_data)
    elif data == "test_fallos":
        if not user_data["fallos"]:
            await query.message.reply_text("No hay fallos acumulados 🎉")
        else:
            await iniciar_quiz(chat_id, context, None, test_fallos=True)
    elif data == "estadisticas_usuarios":
        await mostrar_estadisticas_globales(chat_id, context)
    elif data == "menu":
        await mostrar_menu(chat_id, context)

# ─────────────── Texto pegado ───────────────
async def handle_text(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if context.user_data.get("modo") == "texto":
        context.user_data.setdefault("buffer", "")
        context.user_data["buffer"] += update.message.text + "\n"

async def fin(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if context.user_data.get("modo") != "texto":
        return
    text = context.user_data.pop("buffer", "")
    preguntas = parse_text(text)
    await guardar_quiz_desde_preguntas(update, context, preguntas)

# ─────────────── Guardar quiz ───────────────
async def guardar_quiz_desde_preguntas(update, context, preguntas):
    if not preguntas:
        await update.message.reply_text("❌ No se detectaron preguntas válidas.")
        return
    quizzes = cargar_quizzes()
    quiz_id = len(quizzes) + 1
    quizzes.append({
        "id": quiz_id,
        "titulo": f"Quiz {quiz_id}",
        "fecha": datetime.now().strftime("%d/%m/%Y %H:%M"),
        "preguntas": preguntas,
    })
    guardar_quizzes(quizzes)
    context.user_data.clear()
    await update.message.reply_text(f"✅ Quiz creado con {len(preguntas)} preguntas.")
    await mostrar_menu(update.message.chat.id, context)

# ─────────────── Mostrar quizzes ───────────────
async def mostrar_quizzes(chat_id, context):
    quizzes = cargar_quizzes()
    if not quizzes:
        await context.bot.send_message(chat_id, "No hay quizzes.")
        return
    botones = [
        [InlineKeyboardButton(q["titulo"], callback_data=f"empezar_{q['id']}")]
        for q in quizzes
    ]
    botones.append([InlineKeyboardButton("☰ Menú", callback_data="menu")])
    await context.bot.send_message(chat_id, "Selecciona un quiz:", reply_markup=InlineKeyboardMarkup(botones))

# ─────────────── Quiz interactivo ───────────────
async def iniciar_quiz(chat_id, context, quiz_id=None, test_fallos=False):
    user_data = cargar_usuario(chat_id)
    if test_fallos:
        preguntas = user_data["fallos"].copy()
    else:
        quiz = next(q for q in cargar_quizzes() if q["id"] == quiz_id)
        preguntas = quiz["preguntas"]

    context.user_data["quiz"] = {
        "preguntas": preguntas,
        "i": 0,
        "ok": 0,
        "fail": 0,
        "test_fallos": test_fallos,
        "quiz_id": quiz_id
    }
    await enviar_pregunta(chat_id, context)

async def enviar_pregunta(chat_id, context):
    user_data = cargar_usuario(chat_id)
    quiz = context.user_data["quiz"]
    i = quiz["i"]
    if i >= len(quiz["preguntas"]):
        nota = max((quiz["ok"] - 0.3 * quiz["fail"]) / len(quiz["preguntas"]) * 10, 0)

        if not quiz.get("test_fallos") and quiz["quiz_id"] is not None:
            quiz_data = next((q for q in cargar_quizzes() if q["id"] == quiz["quiz_id"]), {})
            quiz_hist = next((h for h in user_data["historial_tests"] if h["quiz_id"] == quiz["quiz_id"]), None)
            intento = {"hechas": quiz["ok"] + quiz["fail"], "fallos": quiz["fail"], "nota": nota}
            if quiz_hist:
                quiz_hist["intentos"].append(intento)
            else:
                user_data["historial_tests"].append({
                    "quiz_id": quiz["quiz_id"],
                    "titulo": quiz_data.get("titulo", f"Quiz {quiz['quiz_id']}"),
                    "intentos": [intento]
                })
            # Acumular fallos
            for j, p in enumerate(quiz["preguntas"]):
                if j >= quiz["ok"]:
                    user_data["fallos"].append(p)

            guardar_usuario(chat_id, user_data)

        await context.bot.send_message(
            chat_id,
            f"🏁 Fin del quiz\n✔️ {quiz['ok']} ❌ {quiz['fail']}\n🎯 Nota: {nota:.2f}/10"
        )
        context.user_data.pop("quiz")
        await mostrar_menu(chat_id, context)
        return

    p = quiz["preguntas"][i]
    botones = [[InlineKeyboardButton(o, callback_data=str(idx))] for idx, o in enumerate(p["opciones"])]
    botones.append([InlineKeyboardButton("☰ Menú", callback_data="menu")])
    await context.bot.send_message(chat_id, p["pregunta"], reply_markup=InlineKeyboardMarkup(botones))

# ─────────────── Responder interactivo ───────────────
async def responder(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    chat_id = query.message.chat_id
    user_data = cargar_usuario(chat_id)

    quiz = context.user_data.get("quiz")
    if not quiz:
        return
    p = quiz["preguntas"][quiz["i"]]
    selected = int(query.data)

    if selected == p["correcta"]:
        quiz["ok"] += 1
        await query.message.reply_text(f"✅ ¡Correcto!\nTu respuesta: {p['opciones'][selected]}")
        if quiz.get("test_fallos") and p in user_data["fallos"]:
            user_data["fallos"].remove(p)
            guardar_usuario(chat_id, user_data)
    else:
        quiz["fail"] += 1
        await query.message.reply_text(f"❌ Incorrecto!\nTu respuesta: {p['opciones'][selected]}")
        await query.message.reply_text(f"💡 Respuesta correcta: {p['opciones'][p['correcta']]}")
    quiz["i"] += 1
    await enviar_pregunta(chat_id, context)

# ─────────────── Estadísticas personales ───────────────
async def mostrar_estadisticas_acumuladas(chat_id, context, user_data):
    total_fallos = len(user_data["fallos"])
    total_preguntas = sum(sum(i["hechas"] for i in t["intentos"]) for t in user_data["historial_tests"])
    total_correctas = sum(sum(i["hechas"] - i["fallos"] for i in t["intentos"]) for t in user_data["historial_tests"])
    porcentaje_acierto = (total_correctas / total_preguntas * 100) if total_preguntas else 0
    mensaje = (
        f"📊 Estadísticas acumuladas\n"
        f"Preguntas en test de fallos: {total_fallos}\n"
        f"Preguntas hechas: {total_preguntas}\n"
        f"Porcentaje de acierto: {porcentaje_acierto:.2f}%"
    )
    await context.bot.send_message(chat_id, mensaje)

# ─────────────── Estadísticas globales de usuarios ───────────────
async def mostrar_estadisticas_globales(chat_id, context):
    users_files = [f for f in os.listdir(USERS_DIR) if f.endswith(".json")]
    total_hechas = 0
    total_correctas = 0
    for uf in users_files:
        with open(os.path.join(USERS_DIR, uf), "r", encoding="utf-8") as f:
            data = json.load(f)
            total_hechas += sum(sum(i["hechas"] for i in t["intentos"]) for t in data["historial_tests"])
            total_correctas += sum(sum(i["hechas"] - i["fallos"] for i in t["intentos"]) for t in data["historial_tests"])
    porcentaje_global = (total_correctas / total_hechas * 100) if total_hechas else 0
    await context.bot.send_message(chat_id, f"🌐 Porcentaje global de acierto de todos los usuarios: {porcentaje_global:.2f}%")

# ─────────────── Menú de tests por quiz ───────────────
async def mostrar_menu_estadisticas_tests(chat_id, context, user_data):
    quizzes_ids = list({t["quiz_id"]: t["titulo"] for t in user_data["historial_tests"]}.items())
    if not quizzes_ids:
        await context.bot.send_message(chat_id, "No hay tests realizados aún.")
        return
    botones = [[InlineKeyboardButton(titulo, callback_data=f"ver_test_{quiz_id}")] for quiz_id, titulo in quizzes_ids]
    botones.append([InlineKeyboardButton("☰ Menú", callback_data="menu")])
    await context.bot.send_message(chat_id, "Selecciona un quiz para ver sus tests:", reply_markup=InlineKeyboardMarkup(botones))

async def mostrar_tests_quiz(chat_id, context, quiz_id, user_data):
    tests = next((t for t in user_data["historial_tests"] if t["quiz_id"] == quiz_id), None)
    if not tests or not tests.get("intentos"):
        await context.bot.send_message(chat_id, "No hay tests de este quiz.")
        return
    mensaje = f"📊 Historial de tests para {tests['titulo']}:\n\n"
    total_notas = 0
    for i, t in enumerate(tests["intentos"], 1):
        mensaje += (
            f"Test {i}:\n"
            f"Preguntas hechas: {t['hechas']}\n"
            f"Fallos: {t['fallos']}\n"
            f"Nota: {t['nota']:.2f}/10\n\n"
        )
        total_notas += t["nota"]
    media = total_notas / len(tests["intentos"])
    mensaje += f"📈 Nota media: {media:.2f}/10"
    await context.bot.send_message(chat_id, mensaje)

# ─────────────── MAIN ───────────────
if __name__ == "__main__":
    TOKEN = os.environ.get("8561570570:AAGEzK8gV-CbEkeJIswxij25X2QUemIgqEE")
    app = ApplicationBuilder().token(TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("fin", fin))
    app.add_handler(CallbackQueryHandler(responder, pattern=r"^\d+$"))
    app.add_handler(CallbackQueryHandler(handle_button))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_text))
    print("🤖 Bot iniciado")
    app.run_polling()
