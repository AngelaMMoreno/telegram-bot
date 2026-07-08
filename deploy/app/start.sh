#!/bin/sh
# Arranca los dos procesos del contenedor unificado y termina el
# contenedor si cualquiera de los dos se cae (Docker lo reiniciará
# gracias a restart: unless-stopped).
#
# - uvicorn en 127.0.0.1:8000  → SPA + API de teoría (no expuesto fuera)
# - caddy en 0.0.0.0:80        → gateway público, sirve landing/tests
#                                 y hace reverse_proxy al uvicorn de teoría
set -eu

# El uvicorn NO debe escuchar en 0.0.0.0 para no exponerse por fuera;
# el único que habla con él es el Caddy local.
uvicorn app:app --host 127.0.0.1 --port 8000 --proxy-headers &
BACKEND_PID=$!

caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!

# Termina en cuanto muera cualquiera de los dos: eso hace que Docker
# reinicie el contenedor entero, lo que es más seguro que dejarlo con
# un solo proceso vivo y comportamiento degradado.
wait -n "$BACKEND_PID" "$CADDY_PID"
EXIT=$?
# Baja el otro proceso también para no dejarlo huérfano.
kill "$BACKEND_PID" "$CADDY_PID" 2>/dev/null || true
exit "$EXIT"
