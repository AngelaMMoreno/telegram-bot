# Contenedor unificado de Aprentix: landing + tests + teoría en una sola
# imagen. Caddy actúa como gateway público y sirve los estáticos de
# landing y tests; FastAPI/uvicorn corre en 127.0.0.1:8000 y sirve la
# SPA de teoría junto con sus endpoints dinámicos (uploads, PDFs con
# JWT, marcar_visto, etc.).
#
# Tras la reorganización todo el frontend vive bajo web/:
#   web/landing/  → landing SPA
#   web/tests/    → SPA de tests
#   web/teoria/   → SPA de teoría (uvicorn la sirve como StaticFiles)
#   web/shared/   → assets compartidos, UNA sola copia física en /srv/shared
#                    (Caddy reescribe /tests/shared/* y /teoria/shared/*)
#   web/service-worker.js → SW en la raíz con scope "/"
#
# La API sigue en teoria/app.py (backend FastAPI) y en postgrest.

FROM python:3.11-slim

# ── Caddy 2 desde su repositorio oficial ─────────────────────────────
# `postgresql-client` da el `pg_dump`/`pg_restore` que usa el endpoint
# /api/backup (dump de la BBDD) y /api/restore. `p7zip-full` da el
# binario `7z` con soporte de cifrado AES-256 y cabecera cifrada
# (-mhe=on) para el .apbak.
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl gnupg debian-keyring debian-archive-keyring apt-transport-https ca-certificates \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list \
    && apt-get update && apt-get install -y --no-install-recommends \
        caddy postgresql-client p7zip-full \
    && apt-get purge -y --auto-remove curl gnupg apt-transport-https \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ── Backend de teoría (FastAPI) ──────────────────────────────────────
COPY teoria/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY teoria/app.py .

# ── Estáticos ────────────────────────────────────────────────────────
# Landing en /srv, tests bajo /srv/tests, y la SPA de teoría bajo ./site
# (uvicorn la sirve como StaticFiles).
#
# El SW se copia también en /srv para que se sirva en
# aprentix.es/service-worker.js con scope "/" y cubra toda la app.
COPY web/landing              /srv
COPY web/tests                /srv/tests
COPY web/teoria               ./site
COPY web/service-worker.js    /srv/service-worker.js

# Una sola copia física de web/shared. El Caddyfile intercepta
# /tests/shared/* y /teoria/shared/* y los sirve directamente de aquí,
# así que no hace falta duplicar dentro de la imagen.
COPY web/shared               /srv/shared

# ── Config Caddy + script de arranque ────────────────────────────────
COPY deploy/app/Caddyfile /etc/caddy/Caddyfile
COPY deploy/app/start.sh  /start.sh
RUN chmod +x /start.sh

ENV BASE_DIR=/ficheros \
    POSTGREST_URL=http://postgrest:3000

EXPOSE 80
CMD ["/start.sh"]
