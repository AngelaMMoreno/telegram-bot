FROM caddy:2-alpine

# Build context es la raíz del repo (para poder incluir /shared).
COPY web/Caddyfile /etc/caddy/Caddyfile
COPY web/site      /srv
COPY shared        /srv/shared

EXPOSE 80
