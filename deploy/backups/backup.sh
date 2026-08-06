#!/bin/bash
#
# Snapshot restic diario.  Se lanza desde cron (BACKUP_CRON) o a
# mano:
#
#   docker compose -f deploy/backups/docker-compose.yml exec backups /backup.sh
#
# Un único snapshot con tag 'db' por corrida: el dump plano de la
# BBDD.  En este rediseño la teoría (markdown) vive dentro de la
# propia BBDD, así que el dump lo captura entero — no hay snapshot
# aparte de ficheros.
#
# Al terminar, `restic forget --keep-last N --prune` deja únicamente
# los N snapshots más recientes por tag+host y libera el espacio de
# los chunks huérfanos.

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
# Formato PLAIN (-Fp) para que restic deduplique bien a nivel de
# bloque: dos dumps consecutivos comparten miles de líneas idénticas
# y solo se suben las diferencias.  Con -Fc la salida es binaria
# comprimida y no dedupea nada (cada dump ocuparía casi lo mismo).
log "Volcando la BBDD ($PGDATABASE @ $PGHOST) y subiendo snapshot 'db'"
pg_dump -Fp -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" \
    | restic backup --stdin --stdin-filename "${PGDATABASE}.sql" \
                    --tag db --host "$RESTIC_HOST"

# 3) Rotación: nos quedamos con los N últimos snapshots del tag 'db'.
# `--prune` compacta el repositorio borrando chunks huérfanos.
log "Rotando snapshots (keep-last=$KEEP_LAST)"
restic forget --host "$RESTIC_HOST" --tag db --keep-last "$KEEP_LAST" --prune

log "OK. Snapshots vivos:"
restic snapshots --compact --host "$RESTIC_HOST"
