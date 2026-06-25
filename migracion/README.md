# Migración SQLite → PostgreSQL

## Requisitos

- Postgres en marcha con el esquema aplicado (`db/init/*.sql`).
- Variables de entorno: `DATABASE_URL` (DSN postgres) y `SQLITE_PATH`
  (por defecto `/mnt/data/bot/bd.sqlite`).

## Probar en seco

```bash
DATABASE_URL='postgres://aprentix:...@db:5432/aprentix' \
SQLITE_PATH=/mnt/data/bot/bd.sqlite \
python migrar_sqlite_a_pg.py --dry-run
```

## Migración real

```bash
DATABASE_URL='postgres://aprentix:...@db:5432/aprentix' \
SQLITE_PATH=/mnt/data/bot/bd.sqlite \
python migrar_sqlite_a_pg.py
```

## Backup / restauración del Postgres ya migrado

```bash
docker compose exec db pg_dump -Fc -d aprentix -U aprentix > db/backups/$(date +%F).dump
# Restaurar en otro servidor:
cat 2026-06-25.dump | docker compose exec -T db pg_restore -d aprentix -U aprentix -c
```
