#!/bin/sh
#
# Arranca dcron en foreground con el crontab que apunta a /backup.sh.
# BACKUP_CRON permite ajustar la hora sin rebuildar la imagen — por
# defecto todas las noches a las 03:30 (zona TZ de la variable).
set -e

: "${BACKUP_CRON:=30 3 * * *}"

# El cron de BusyBox necesita el crontab en /etc/crontabs/<user>.
mkdir -p /etc/crontabs
# Exportamos las variables al proceso hijo escribiéndolas antes del
# comando en el propio crontab — cron no hereda el entorno del padre
# más allá de HOME/PATH.
{
  echo "SHELL=/bin/bash"
  echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  echo "TZ=${TZ:-UTC}"
  # Cada línea `Foo=Bar` se copia a un `export` en el shell del job.
  env | grep -E '^(PG|RESTIC_|KEEP_LAST|RESTIC_HOST)' | sed 's/^/export /' \
    | awk '{ print "# " $0 }'
  # El propio job carga el entorno desde /etc/backup.env — se genera
  # a continuación con las variables completas.
  echo "$BACKUP_CRON . /etc/backup.env && /backup.sh 2>&1"
} > /etc/crontabs/root

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
