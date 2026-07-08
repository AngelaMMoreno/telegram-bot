# Contenedor unificado de Aprentix: landing + tests + teoría en una sola
# imagen. Caddy actúa como gateway público y sirve los estáticos de
# landing y tests; FastAPI/uvicorn corre en 127.0.0.1:8000 y sirve la
# SPA de teoría junto con sus endpoints dinámicos (uploads, PDFs con
# JWT, marcar_visto, etc.).
#
# Los stacks originales de deploy/landing/, deploy/web/ y deploy/teoria/
# se conservan como opción de despliegue segmentado; deploy/app/ es la
# opción monolítica y más simple de operar.

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
# Landing va en la raíz de Caddy (/srv), tests bajo /srv/tests, y la
# SPA de teoría bajo ./site (la sirve el propio uvicorn con StaticFiles).
COPY landing/site /srv
COPY web/site     /srv/tests
COPY teoria/site  ./site

# /shared se duplica en cada raíz porque cada SPA lo carga con rutas
# relativas a su base href. Copiarlo tres veces cuesta unos KB y evita
# hacer alias globales que compliquen los service workers.
COPY shared /srv/shared
COPY shared /srv/tests/shared
COPY shared ./site/shared

# ── Config Caddy + script de arranque ────────────────────────────────
COPY deploy/app/Caddyfile /etc/caddy/Caddyfile
COPY deploy/app/start.sh  /start.sh
RUN chmod +x /start.sh

ENV BASE_DIR=/ficheros \
    POSTGREST_URL=http://postgrest:3000

EXPOSE 80
CMD ["/start.sh"]
