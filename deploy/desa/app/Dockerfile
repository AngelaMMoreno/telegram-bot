# Contenedor de la SPA nueva (rediseño oposiciones) — sirve web/app/
# más los estilos y assets compartidos de web/shared/.  Aquí no hace
# falta uvicorn: la SPA habla directa con PostgREST vía /api (proxy en
# Caddy), y no hay backend específico de teoría porque el contenido
# vive dentro de la propia BBDD (tabla `unidades.teoria_md`).

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl gnupg debian-keyring debian-archive-keyring apt-transport-https ca-certificates \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list \
    && apt-get update && apt-get install -y --no-install-recommends caddy \
    && apt-get purge -y --auto-remove curl gnupg apt-transport-https \
    && rm -rf /var/lib/apt/lists/*

COPY web/app     /srv/app
COPY web/shared  /srv/shared
COPY deploy/desa/app/Caddyfile /etc/caddy/Caddyfile

EXPOSE 80
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
