#!/usr/bin/env python3
"""Manda un aviso por email cuando la publicación falla o se recupera.

Usa las MISMAS variables de entorno que el servicio `mailer/`, así que si
ya tienes ese stack configurado no hay nada nuevo que preparar:

    SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, SMTP_FROM, SMTP_TLS

Y una propia con el destinatario:

    AVISO_EMAIL     a quién avisar. Sin ella, este script no hace nada.

Uso:  avisar.py <asunto> <fichero-con-el-log>

Es best-effort: si el correo no sale, se queja por stderr y devuelve 0.
Un fallo del aviso no debe convertirse en un fallo de la publicación.
"""
import os
import smtplib
import ssl
import sys
from email.message import EmailMessage

DESTINO = os.getenv("AVISO_EMAIL", "").strip()
HOST = os.getenv("SMTP_HOST", "").strip()
PORT = int(os.getenv("SMTP_PORT", "587"))
USER = os.getenv("SMTP_USER", "").strip()
PASS = os.getenv("SMTP_PASS", "")
DESDE = os.getenv("SMTP_FROM", "Aprentix <hola@aprentix.es>")
TLS = os.getenv("SMTP_TLS", "starttls").lower()

# Sólo se manda la cola del log: lo que importa para saber qué pasó está
# al final, y así no se envían correos de varios megas.
LINEAS_LOG = 60


def main() -> int:
    if len(sys.argv) < 3:
        print("uso: avisar.py <asunto> <fichero-log>", file=sys.stderr)
        return 0
    if not DESTINO or not HOST:
        # Sin configurar: no es un error, simplemente no se avisa.
        return 0

    asunto, ruta_log = sys.argv[1], sys.argv[2]
    try:
        with open(ruta_log, encoding="utf-8", errors="replace") as f:
            lineas = f.readlines()
    except OSError as e:
        lineas = [f"(no se pudo leer el log: {e})\n"]

    cuerpo = (
        f"{asunto}\n\n"
        f"Últimas {LINEAS_LOG} líneas de la corrida:\n\n"
        + "".join(lineas[-LINEAS_LOG:])
        + "\n--\nStack `publicador` de Aprentix. "
          "Para ver la corrida entera: docker logs <contenedor-publicador>\n"
    )

    msg = EmailMessage()
    msg["Subject"] = asunto
    msg["From"] = DESDE
    msg["To"] = DESTINO
    msg.set_content(cuerpo)

    try:
        if TLS == "ssl":
            with smtplib.SMTP_SSL(HOST, PORT, context=ssl.create_default_context()) as s:
                if USER:
                    s.login(USER, PASS)
                s.send_message(msg)
        else:
            with smtplib.SMTP(HOST, PORT) as s:
                if TLS == "starttls":
                    s.starttls(context=ssl.create_default_context())
                if USER:
                    s.login(USER, PASS)
                s.send_message(msg)
        print(f"[avisar] enviado a {DESTINO}")
    except Exception as e:  # noqa: BLE001 — avisar nunca debe tumbar el job
        print(f"[avisar] no se pudo enviar el aviso: {e}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
