# Contenedor unificado de Aprentix: SPA /estudio + backend de teoría en una
# sola imagen. Caddy actúa como gateway público y sirve los estáticos de
# /estudio; FastAPI/uvicorn corre en 127.0.0.1:8000 y expone los endpoints
# de /teoria/api/* (leer markdown, subir PDFs, etc.) usados por /estudio
# para pintar la teoría.
#
# Tras la retirada de la app legacy (/landing y /tests) todo el frontend
# vive bajo:
#   web/estudio/          → SPA única servida en aprentix.es/estudio/
#                             (la raíz `/` redirige aquí)
#   web/shared/           → assets compartidos en /srv/shared
#                             (Caddy reescribe /estudio/shared/*)
#   web/service-worker.js → SW en la raíz con scope "/"
#   web/manifest.webmanifest → manifest PWA en la raíz
#
# El backend de teoría sigue siendo teoria/app.py (FastAPI), pero ya no
# sirve ninguna SPA propia: sólo sus endpoints /api/*.

FROM python:3.11-slim

# ── Caddy 2 desde su repositorio oficial ─────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl gnupg debian-keyring debian-archive-keyring apt-transport-https ca-certificates \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list \
    && apt-get update && apt-get install -y --no-install-recommends caddy \
    && apt-get purge -y --auto-remove curl gnupg apt-transport-https \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ── Backend de teoría (FastAPI) ──────────────────────────────────────
COPY teoria/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY teoria/app.py .

# ── Estáticos ────────────────────────────────────────────────────────
# Sólo la SPA nueva. Assets del origin (SW, manifest, iconos) en /srv;
# la SPA en /srv/estudio (Caddy la sirve bajo aprentix.es/estudio/ y
# redirige `/` a ese path).
COPY web/estudio             /srv/estudio
COPY web/service-worker.js   /srv/service-worker.js
COPY web/manifest.webmanifest /srv/manifest.webmanifest

# Una sola copia física de web/shared. El Caddyfile intercepta
# /estudio/shared/* y lo sirve directamente de aquí, así que no hace
# falta duplicar dentro de la imagen.
COPY web/shared              /srv/shared

# ── Config Caddy + script de arranque ────────────────────────────────
COPY deploy/app/Caddyfile /etc/caddy/Caddyfile
COPY deploy/app/start.sh  /start.sh
RUN chmod +x /start.sh

ENV BASE_DIR=/ficheros \
    POSTGREST_URL=http://postgrest:3000

EXPOSE 80
CMD ["/start.sh"]
