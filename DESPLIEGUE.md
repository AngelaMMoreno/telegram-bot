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
   | `DOMINIO_PGADMIN`    | `pgadmin.aprentix.es` (subdominio para pgAdmin)              |
   | `PGADMIN_EMAIL`      | tu correo (login de pgAdmin)                                 |
   | `PGADMIN_PASS`       | contraseña de pgAdmin                                        |

5. Crea los registros DNS **A** de `DOMINIO_API` y `DOMINIO_PGADMIN`
   apuntando a la IP del servidor (los necesita Let's Encrypt).
6. **Deploy**.

Dokploy ejecutará `docker compose up -d db pgadmin postgrest embeddings`.
El servicio `migracion` queda fuera porque está bajo el perfil
`herramientas` y solo se lanza a demanda.

**Postgres no publica ningún puerto al host**: solo escucha dentro de
`dokploy-network`. El acceso desde fuera se hace exclusivamente vía
pgAdmin por HTTPS (puerto 443, que ya tienes abierto).

## 2. Verificar que Postgres arrancó

Desde el host del servidor:

```bash
docker compose -f /etc/dokploy/applications/<id>/code/docker-compose.yml ps
docker compose -f .../docker-compose.yml logs db --tail=80
```

Deberías ver `database system is ready to accept connections` y la
ejecución de `01_schema.sql`, `02_seed.sql`, `03_funciones.sql`.

## 3. Conectarte vía pgAdmin

1. Entra en `https://pgadmin.aprentix.es`.
2. Login con `PGADMIN_EMAIL` / `PGADMIN_PASS`.
3. En el panel izquierdo ya verás un servidor llamado **aprentix**
   precargado (desde `pgadmin/servers.json`) apuntando a `db:5432`.
4. Click derecho → *Connect Server*. Te pide la contraseña: introduce
   `DB_PASS`. Puedes marcar *Save password* para no volver a pedirla.
5. Listo: navegas el esquema, ejecutas SQL desde *Query Tool*, etc.

> pgAdmin habla con Postgres por la red interna `dokploy-network`
> (`db:5432`). Postgres no está accesible desde fuera del VPS, así que
> **no necesitas abrir el puerto 5432** en el firewall de Oracle. Toda
> la administración entra por HTTPS (443).

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
