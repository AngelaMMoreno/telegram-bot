# Publicador de contenido. Corre `db/publicacion/publicar.py` en bucle de
# cron: clona el repo de contenido, compara con lo publicado y sube lo que
# haya cambiado. Es el sustituto de lanzar el script a mano.
#
# El contexto de build es la RAÍZ del repo (ver docker-compose.yml), igual
# que en deploy/app, porque el script vive en db/publicacion/.
FROM python:3.12-alpine

# git para clonar el repo de contenido; tini (init) para que crond no sea
# PID 1 — mismo motivo que en deploy/backups.
RUN apk add --no-cache git ca-certificates tzdata

WORKDIR /app

COPY db/publicacion/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY db/publicacion/publicar.py .
COPY deploy/publicador/avisar.py       /app/avisar.py
COPY deploy/publicador/publicar-job.sh /publicar-job.sh
COPY deploy/publicador/entrypoint.sh   /entrypoint.sh
RUN chmod +x /publicar-job.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
