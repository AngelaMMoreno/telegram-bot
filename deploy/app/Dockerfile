# Contenedor unificado de Aprentix. Caddy sirve la SPA remodelada de estudio
# y FastAPI/uvicorn expone únicamente la API de contenidos.
#
# El frontend vive bajo web/estudio y los recursos comunes bajo web/shared.
#   web/service-worker.js → SW en la raíz con scope "/"
#
# La API sigue en teoria/app.py (backend FastAPI) y en postgrest.

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
# La SPA remodelada es el único frontend incluido en la imagen.
COPY web/estudio              /srv/estudio
COPY web/estudio/manifest.webmanifest /srv/manifest.webmanifest
COPY web/service-worker.js    /srv/service-worker.js

COPY web/shared               /srv/shared

# ── Config Caddy + script de arranque ────────────────────────────────
COPY deploy/app/Caddyfile /etc/caddy/Caddyfile
COPY deploy/app/start.sh  /start.sh
RUN chmod +x /start.sh

ENV BASE_DIR=/ficheros \
    POSTGREST_URL=http://postgrest_desa:3000

EXPOSE 80
CMD ["/start.sh"]
