FROM caddy:2-alpine

# Build context es la raíz del repo (para poder incluir /shared).
COPY landing/Caddyfile /etc/caddy/Caddyfile
COPY landing/site      /srv
COPY shared            /srv/shared

EXPOSE 80
