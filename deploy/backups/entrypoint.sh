#!/bin/sh
#
# Arranca dcron en foreground con el crontab que apunta a /backup.sh.
# BACKUP_CRON permite ajustar la hora sin rebuildar la imagen — por
# defecto todas las noches a las 03:30 (zona TZ de la variable).
set -e

: "${BACKUP_CRON:=30 3 * * *}"

# El cron de BusyBox necesita el crontab en /etc/crontabs/<user>.
# OJO: dcron (a diferencia de Vixie/cronie) NO soporta líneas
# `VAR=value` en el crontab — las trata como entries mal formadas y
# escupe "failed parsing crontab for user root: ...". Por eso el env
# no se define aquí; el propio job hace `. /etc/backup.env` (ver más
# abajo) para cargar PG*/RESTIC_* al shell hijo. TZ ya viene del
# entorno del contenedor y crond la hereda para saber cuándo disparar.
mkdir -p /etc/crontabs
echo "$BACKUP_CRON . /etc/backup.env && /backup.sh 2>&1" > /etc/crontabs/root

# Vuelca las variables sensibles a /etc/backup.env para que el job las
# lea. Se filtran a las que interesan para no meter ruido innecesario.
env | grep -E '^(PG|RESTIC_|KEEP_LAST|RESTIC_HOST|TZ)=' \
    | sed 's/^/export /' > /etc/backup.env
chmod 600 /etc/backup.env

echo "[entrypoint] cron programado: '$BACKUP_CRON' (TZ=${TZ:-UTC})"
echo "[entrypoint] repo restic: ${RESTIC_REPOSITORY:-<no definido>}"
echo "[entrypoint] arrancando crond en foreground"

# -f: foreground. -L /dev/stdout: manda los logs de cron al stdout del
# contenedor (así `docker logs backups` muestra cada ejecución).
exec crond -f -L /dev/stdout
