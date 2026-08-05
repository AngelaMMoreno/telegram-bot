#!/usr/bin/env bash
# Permite desplegar esta rama en una base o esquema independiente sin tocar
# producción. Docker ejecuta este script antes de 01_esquema.sql.
set -euo pipefail

ESQUEMA="${POSTGRES_SCHEMA:-public}"
if [ "$ESQUEMA" = "public" ]; then
  exit 0
fi

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<SQL
CREATE SCHEMA IF NOT EXISTS "$ESQUEMA" AUTHORIZATION "$POSTGRES_USER";
ALTER DATABASE "$POSTGRES_DB" SET search_path TO "$ESQUEMA", public;
SQL
