#!/usr/bin/env bash
# =============================================================================
# Crea las redes Docker PRIVADAS que aíslan la BBDD de cada entorno.
#
# Ejecutarlo UNA vez en el host (VPS) antes de desplegar los stacks:
#   bash deploy/init-networks.sh
#
# Idempotente: si ya existen, no hace nada y sale con éxito.
#
# ¿Por qué?  Cada stack (core, mailer, notificador, backups) declara
# la red `db-net-<alias>` como `external: true` para que Dokploy no
# la recree con un nombre prefijado por el proyecto.  Como es external,
# Docker exige que exista antes de arrancar los contenedores.
# =============================================================================
set -euo pipefail

for net in db-net-prod db-net-desa; do
  if docker network inspect "$net" >/dev/null 2>&1; then
    echo "✓ Red '$net' ya existe"
  else
    docker network create "$net" >/dev/null
    echo "✓ Red '$net' creada"
  fi
done
