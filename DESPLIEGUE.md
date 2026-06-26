# Despliegue en Dokploy

Esta guía explica cómo levantar el nuevo stack PostgreSQL/PostgREST/embeddings
en paralelo al sistema actual (SQLite + bot/web/servidor), validar la
migración y, cuando estés conforme, hacer el corte definitivo.

## 0. Coexistencia con el sistema actual

El stack nuevo **no toca** nada del antiguo:

| Sistema actual                 | Stack nuevo                |
|--------------------------------|----------------------------|
| Volumen `/mnt/data/bot/*.sqlite` | Volumen `/mnt/data/pg/`    |
| Servicios `bot`, `web`, `servidor` | Servicios `db`, `postgrest`, `embeddings` |
| Red `dokploy-network`          | Red `dokploy-network`      |

Pueden correr a la vez sin conflicto. El stack antiguo sigue sirviendo
tráfico real mientras tú validas el nuevo.

## 1. Crear la aplicación en Dokploy

1. En Dokploy → **Create Compose Application**.
2. Source: este repositorio, rama `claude/happy-volta-fd3oz5` (o `main`
   tras el merge de la PR #90).
3. Compose path: `docker-compose.yml` (raíz).
4. En **Environment Variables** añade:

   | Clave                | Ejemplo / notas                                              |
   |----------------------|--------------------------------------------------------------|
   | `DB_PASS`            | contraseña fuerte para el rol `aprentix`                     |
   | `AUTH_PASS`          | contraseña fuerte para el rol `autenticador` (PostgREST)     |
   | `JWT_SECRET`         | mínimo 32 caracteres aleatorios (`openssl rand -hex 32`)     |
   | `ADMIN_PASS`         | contraseña inicial del usuario `admin` (mínimo 8)            |
   | `DOMINIO_API`        | `api.aprentix.es` (subdominio para PostgREST detrás de Traefik) |
   | `PG_PUERTO_EXTERNO`  | `55432` por defecto (puerto que el host expone hacia DBeaver) |

5. Asegúrate de tener el registro DNS de `DOMINIO_API` apuntando al
   servidor (lo necesita Let's Encrypt).
6. **Deploy**.

Dokploy ejecutará `docker compose up -d db postgrest embeddings`. El
servicio `migracion` queda fuera porque está bajo el perfil
`herramientas` y solo se lanza a demanda.

## 2. Verificar que Postgres arrancó

Desde el host del servidor:

```bash
docker compose -f /etc/dokploy/applications/<id>/code/docker-compose.yml ps
docker compose -f .../docker-compose.yml logs db --tail=80
```

Deberías ver `database system is ready to accept connections` y la
ejecución de `01_schema.sql`, `02_seed.sql`, `03_funciones.sql`.

## 3. Conectarte desde DBeaver / pgAdmin / psql

Postgres queda publicado en el puerto del host indicado por
`PG_PUERTO_EXTERNO` (por defecto **55432**).

- Host: la IP pública de tu servidor (o `localhost` si haces un túnel SSH)
- Puerto: `55432`
- Base de datos: `aprentix`
- Usuario: `aprentix`
- Contraseña: la que pusiste en `DB_PASS`

> Recomendación: en lugar de abrir 55432 al mundo en el firewall, usa
> un **túnel SSH**:
>
> ```bash
> ssh -L 55432:127.0.0.1:55432 usuario@servidor
> ```
>
> y conecta DBeaver a `localhost:55432`.

## 4. Lanzar la migración (modo prueba)

Desde el host del servidor, en el directorio del compose:

```bash
docker compose run --rm migracion --dry-run
```

Esto:

1. Construye un contenedor Python efímero con `psycopg`.
2. Monta el SQLite actual de `/mnt/data/bot` como **solo lectura**.
3. Recorre todas las tablas y las vuelca al Postgres nuevo.
4. Con `--dry-run` hace `ROLLBACK` al final: nada se persiste.

Mira la salida y verifica que el número de usuarios, preguntas únicas,
tests y respuestas tiene sentido.

## 5. Migración real

```bash
docker compose run --rm migracion
```

Idempotente para usuarios/preguntas (usa `ON CONFLICT`). Si algo sale
mal, puedes vaciar tablas en Postgres y repetir:

```sql
-- conectado como usuario aprentix
TRUNCATE marcadores, respuestas, intentos, test_preguntas, tests,
         pregunta_temas, preguntas, usuario_roles, usuarios
         RESTART IDENTITY CASCADE;
```

(no toques `roles`, `permisos`, `rol_permisos`: vienen del seed).

## 6. Comprobaciones SQL útiles tras la migración

```sql
-- Conteos básicos
SELECT 'usuarios', count(*) FROM usuarios
UNION ALL SELECT 'preguntas', count(*) FROM preguntas
UNION ALL SELECT 'tests',     count(*) FROM tests
UNION ALL SELECT 'intentos',  count(*) FROM intentos
UNION ALL SELECT 'respuestas',count(*) FROM respuestas;

-- Preguntas reutilizadas en >1 test (lo que querías conseguir)
SELECT p.id, p.enunciado, count(*) AS apariciones
FROM test_preguntas tp JOIN preguntas p ON p.id = tp.pregunta_id
GROUP BY p.id, p.enunciado HAVING count(*) > 1
ORDER BY apariciones DESC LIMIT 20;

-- Estado del embeddings worker
SELECT count(*) FILTER (WHERE procesado_en IS NULL) AS pendientes,
       count(*) FILTER (WHERE procesado_en IS NOT NULL) AS hechos
FROM cola_embeddings;
```

## 7. Backup / restauración

```bash
# Backup en el servidor
docker compose exec db pg_dump -Fc -U aprentix -d aprentix \
    > db/backups/aprentix_$(date +%F).dump

# Descarga al portátil
scp servidor:/.../db/backups/aprentix_*.dump ~/Backups/

# Restauración en otro servidor (con el stack levantado vacío)
cat aprentix_2026-06-25.dump | \
    docker compose exec -T db pg_restore -U aprentix -d aprentix -c
```

## 8. Cuándo cerrar el sistema viejo

Cuando hayas validado en Postgres que los datos están bien, hayas
reescrito `bot/` y `web/` contra PostgREST (siguientes fases) y
quieras hacer el corte:

1. Para `bot` y `web` viejos en Dokploy.
2. (Opcional) `chmod a-w` sobre `/mnt/data/bot/*.sqlite` para
   garantizar que nada escribe en SQLite.
3. Despliega las nuevas versiones de `bot` y `web` apuntando a
   `https://api.aprentix.es`.
4. Cuando lleves una semana sin incidentes, borra el volumen
   `/mnt/data/bot` (después de un último backup, claro).
