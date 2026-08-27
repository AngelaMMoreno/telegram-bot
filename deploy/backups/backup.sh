#!/bin/bash
#
# Snapshot restic diario. Se lanza desde cron (BACKUP_CRON) o a mano:
#   docker compose -f deploy/backups/docker-compose.yml exec backups /backup.sh
#
# Genera TRES snapshots por corrida — el dump de la BBDD, los ficheros
# de teoría y el SQLite del bot de Discord — para poder restaurar cada
# parte por separado. Restic deduplica a nivel de bloque, así que la segunda
# noche solo sube los cambios reales (no ocupa "otro backup entero").
#
# Al terminar, `restic forget --keep-last N --prune` deja únicamente
# los N snapshots más recientes por tag+host y libera el espacio de
# los chunks que ya no referencia nadie.
set -euo pipefail

log() { echo "[backup] $(date -u +%FT%TZ) $*"; }

: "${PGHOST:?PGHOST requerido}"
: "${PGUSER:?PGUSER requerido}"
: "${PGDATABASE:?PGDATABASE requerido}"
: "${PGPASSWORD:?PGPASSWORD requerido}"
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY requerido (ej: rclone:gdrive:aprentix-backups)}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD requerido (contraseña del repo restic)}"
KEEP_LAST="${KEEP_LAST:-2}"
RESTIC_HOST="${RESTIC_HOST:-aprentix}"

export RESTIC_REPOSITORY RESTIC_PASSWORD

# 1) Inicializa el repositorio si es la primera corrida. `restic cat
# config` es un ping barato — si sale 0, el repo ya existía; si no,
# lo creamos con `restic init`.
if ! restic cat config >/dev/null 2>&1; then
  log "Inicializando repositorio restic en $RESTIC_REPOSITORY"
  restic init
fi

# 2) Snapshot de la BBDD.
#
# Usamos el formato PLAIN (-Fp) en vez del custom (-Fc) porque restic
# deduplica a nivel de bloque: dos dumps consecutivos comparten miles
# de líneas idénticas y solo se suben las diferencias. Con -Fc la
# salida es binaria comprimida y no dedupea nada — cada dump ocuparía
# casi lo mismo entero.
log "Volcando la BBDD y subiendo snapshot 'db'"
pg_dump -Fp -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" \
  | restic backup --stdin --stdin-filename aprentix.sql \
                  --tag db --host "$RESTIC_HOST"

# 3) Snapshot de los ficheros de teoría (bind-mount de solo lectura).
log "Subiendo snapshot 'teoria'"
restic backup /data/ficheros --tag teoria --host "$RESTIC_HOST"

# 4) Snapshot del SQLite del bot de Discord (stack pildoras).
#
# Opcional: si ese stack no está desplegado, no hay fichero y se salta
# sin hacer ruido.
#
# NO se copia el .db a pelo, ni se deja que restic se lleve el
# directorio entero. SQLite en modo WAL reparte el estado entre el
# fichero principal y el -wal:
#
#   - Copiar solo el .db da una base perfectamente legible pero VIEJA:
#     le falta todo lo que siga en el -wal. Medido sobre una base con
#     escrituras en curso: 1979 filas copiadas frente a 2889 reales.
#     Restauras, la base abre sin quejarse, y has perdido las últimas
#     aprobaciones sin que nada te avise.
#   - Copiar el directorio entero es peor: restic lee .db y -wal en
#     instantes distintos, así que pueden no corresponderse.
#
# `.backup` usa la API de backup en línea de SQLite, que sí produce una
# instantánea coherente aunque haya escrituras a la vez. Por eso el
# volumen va montado en lectura-escritura: para reproducir el WAL,
# sqlite necesita abrir la base en modo escritura.
PILDORAS_DB=/data/pildoras/pildoras.db
if [ -f "$PILDORAS_DB" ]; then
  log "Copiando el SQLite del bot y subiendo snapshot 'pildoras'"
  TMP_DB=$(mktemp -d)/pildoras.db
  sqlite3 "$PILDORAS_DB" ".backup '$TMP_DB'"
  restic backup "$TMP_DB" --tag pildoras --host "$RESTIC_HOST"
  rm -rf "$(dirname "$TMP_DB")"
else
  log "Sin SQLite del bot en $PILDORAS_DB — se salta el snapshot 'pildoras'"
fi

# 5) Rotación: nos quedamos con los N últimos snapshots de cada tag.
# `--prune` compacta el repositorio borrando chunks huérfanos.
log "Rotando snapshots (keep-last=$KEEP_LAST)"
restic forget --host "$RESTIC_HOST" --tag db     --keep-last "$KEEP_LAST" --prune
restic forget --host "$RESTIC_HOST" --tag teoria --keep-last "$KEEP_LAST" --prune
restic forget --host "$RESTIC_HOST" --tag pildoras --keep-last "$KEEP_LAST" --prune

log "OK. Snapshots vivos:"
restic snapshots --compact --host "$RESTIC_HOST"
