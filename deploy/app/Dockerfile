# Contenedor de la SPA.  Caddy sirve web/ como estáticos y hace de
# proxy /api → PostgREST.  Toda la aplicación está bajo web/ (index,
# style, app, tokens, session, icons) — no hay carpetas compartidas.

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

COPY web/                     /srv/
COPY deploy/app/Caddyfile     /etc/caddy/Caddyfile

EXPOSE 80
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
