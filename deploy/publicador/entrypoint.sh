#!/bin/sh
#
# Arranca dcron en foreground con el crontab que apunta a /publicar-job.sh.
# Mismo patrón (y mismas trampas) que deploy/backups/entrypoint.sh.
set -e

: "${PUBLICAR_CRON:=*/15 * * * *}"
: "${CONTENIDO_REPO:?CONTENIDO_REPO requerida (URL del repo de contenido)}"
: "${PUBLICAR_DSN:?PUBLICAR_DSN requerida (DSN de la BBDD)}"

# Tapa el token de la URL antes de escribirla en ningún log.
REPO_SEGURO=$(echo "$CONTENIDO_REPO" | sed -E 's#(https?://)[^/@]+@#\1***@#')

# El cron de BusyBox necesita el crontab en /etc/crontabs/<user>.
# OJO: dcron NO soporta líneas `VAR=value` en el crontab, así que el
# entorno se vuelca a un fichero y el job lo carga con `.` — igual que en
# el stack de backups.
mkdir -p /etc/crontabs
echo "$PUBLICAR_CRON . /etc/publicar.env && /publicar-job.sh 2>&1" > /etc/crontabs/root

env | grep -E '^(CONTENIDO_|PUBLICAR_|SMTP_|AVISO_|TZ)=' \
    | sed 's/^/export /' > /etc/publicar.env
chmod 600 /etc/publicar.env

echo "[entrypoint] cron programado: '$PUBLICAR_CRON' (TZ=${TZ:-UTC})"
echo "[entrypoint] repo de contenido: $REPO_SEGURO"
echo "[entrypoint] rama: ${CONTENIDO_RAMA:-<la del remoto>}"
if [ -n "${PUBLICAR_APLICAR:-}" ]; then
    echo "[entrypoint] modo: APLICAR (escribe en la BBDD)"
else
    echo "[entrypoint] modo: SIMULACRO — no escribe nada."
    echo "[entrypoint] Pon PUBLICAR_APLICAR=1 cuando hayas visto un par de"
    echo "[entrypoint] corridas en los logs y el plan te cuadre."
fi

# Una corrida al arrancar, para no esperar al primer tic del cron y ver
# enseguida en los logs si la configuración es correcta.
if [ "${PUBLICAR_AL_ARRANCAR:-1}" = "1" ]; then
    echo "[entrypoint] corrida inicial de comprobación"
    . /etc/publicar.env && /publicar-job.sh || \
        echo "[entrypoint] la corrida inicial falló; el cron reintentará"
fi

echo "[entrypoint] arrancando crond en foreground"
exec crond -f -L /dev/stdout
