# Servicio de backups automatizados.
#
# Contenedor mínimo con:
#   - restic        → snapshots deduplicados y cifrados end-to-end.
#   - rclone        → transporta el repositorio de restic a Google Drive
#                     (OAuth), Backblaze, S3, etc.
#   - postgresql16-client → pg_dump para volcar la BBDD del stack core.
#   - dcron         → cron de BusyBox, corre el script en el horario elegido.
#
# El contenedor NO publica puertos ni tiene endpoints web: es un
# servicio de fondo que despierta según BACKUP_CRON, lanza backup.sh y
# vuelve a dormir. Los logs de cada corrida salen por `docker logs`.
FROM alpine:3.19

RUN apk add --no-cache \
        restic \
        rclone \
        postgresql16-client \
        dcron \
        bash \
        tzdata \
        ca-certificates

COPY backup.sh     /backup.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /backup.sh /entrypoint.sh \
 && mkdir -p /root/.config/rclone /root/.cache/restic /var/log

ENTRYPOINT ["/entrypoint.sh"]
