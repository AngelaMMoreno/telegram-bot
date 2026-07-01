# Despliegue en Dokploy

Guía para levantar el stack (PostgreSQL + PostgREST + embeddings + web +
pgAdmin) en Dokploy y servirlo en los dominios de producción.

Solo hay un stack: el basado en PostgreSQL. La aplicación anterior
(SQLite + Flask + bot Python + servidor de archivos) ya no existe.

## 1. Servicios que componen el stack

| Servicio    | Imagen / build      | Dominio                                                    |
|-------------|---------------------|------------------------------------------------------------|
| `db`        | `pgvector/pgvector:pg16` | — (solo red interna `dokploy-network`)                 |
| `postgrest` | `postgrest/postgrest:v12.2.3` | `api.aprentix.es` (`DOMINIO_API`)                 |
| `web`       | build `./web` (Caddy) | `test.aprentix.es` **y** `www.aprentix.es`               |
| `embeddings`| build `./embeddings` | — (worker interno)                                        |
| `pgadmin`   | `dpage/pgadmin4:9`   | `pgadmin.aprentix.es` (`DOMINIO_PGADMIN`)                 |

Postgres NO publica puerto al host: solo escucha en `dokploy-network`.
El acceso administrativo entra por HTTPS vía pgAdmin.

## 2. Crear la aplicación en Dokploy

1. Dokploy → **Create Compose Application**.
2. Source: este repositorio, rama por defecto.
3. Compose path: `docker-compose.yml`.
4. **Environment Variables** (copiar de `.env.example` y rellenar):

   | Clave              | Ejemplo / notas                                              |
   |--------------------|--------------------------------------------------------------|
   | `DB_PASS`          | Contraseña fuerte del rol `aprentix`.                        |
   | `AUTH_PASS`        | Contraseña del rol `autenticador` (PostgREST).               |
   | `JWT_SECRET`       | ≥ 32 caracteres (`openssl rand -hex 32`).                    |
   | `ADMIN_PASS`       | Contraseña inicial del usuario `admin` (mínimo 8).           |
   | `DOMINIO_WEB`      | `test.aprentix.es` (SPA).                                    |
   | `DOMINIO_WEB_ALT`  | `www.aprentix.es` (segundo Host).                            |
   | `DOMINIO_API`      | `api.aprentix.es` (PostgREST).                               |
   | `DOMINIO_PGADMIN`  | `pgadmin.aprentix.es`.                                       |
   | `PGADMIN_EMAIL`    | Correo del login de pgAdmin.                                 |
   | `PGADMIN_PASS`     | Contraseña de pgAdmin.                                       |

5. Crea los registros DNS **A** apuntando a la IP del servidor para
   cada uno de los cuatro dominios (Let's Encrypt los necesita
   accesibles antes de emitir el certificado).
6. **Deploy**.

Dokploy ejecuta `docker compose up -d`. Al arrancar, `db` corre
`db/init/01_esquema.sql` (crea tablas, funciones, RLS, seed y usuario
`admin`).

## 3. Verificación rápida

Desde el host del servidor:

```bash
docker compose -f /etc/dokploy/applications/<id>/code/docker-compose.yml ps
docker compose ... logs db --tail=80
docker compose ... logs web postgrest embeddings --tail=40
```

En los logs de `db` debes ver `database system is ready to accept
connections` y la ejecución de `01_esquema.sql`.

En el navegador:

- `https://test.aprentix.es` → SPA de Aprentix.
- `https://www.aprentix.es` → misma SPA (segundo Host en la misma ruta Traefik).
- `https://api.aprentix.es` → OpenAPI de PostgREST.
- `https://pgadmin.aprentix.es` → panel de administración.

## 4. Login inicial

- Usuario `admin` con la contraseña `ADMIN_PASS` que configuraste en
  el `.env` (creada por el bloque final del `01_esquema.sql`).
- Cualquier registro nuevo desde la pantalla de la SPA entra como
  rol `alumno`; el admin puede promoverlo a `editor`/`admin` desde
  el panel de usuarios.

## 5. Conexión con pgAdmin

1. `https://pgadmin.aprentix.es` → login con `PGADMIN_EMAIL` /
   `PGADMIN_PASS`.
2. En el panel izquierdo aparece precargado el servidor
   **aprentix** (`pgadmin/servers.json`) apuntando a `db:5432`.
3. Click derecho → *Connect Server* → introducir `DB_PASS`. Marcar
   *Save password* si se quiere persistir.

## 6. Backup / restauración

```bash
# Backup en el servidor
docker compose exec db pg_dump -Fc -U aprentix -d aprentix \
    > db/backups/aprentix_$(date +%F).dump

# Descarga
scp servidor:/.../db/backups/aprentix_*.dump ~/Backups/

# Restauración en otro servidor (con el stack levantado sobre BBDD vacía)
cat aprentix_YYYY-MM-DD.dump | \
    docker compose exec -T db pg_restore -U aprentix -d aprentix -c
```

## 7. Cambios de esquema

El proyecto **no usa carpetas de migraciones**: el estado actual vive
en un único fichero:

- `db/init/01_esquema.sql` — SQL autoritativo.
- `db/ESTADO_BBDD.md` — documentación de referencia (tablas,
  columnas, RPCs).

Al cambiar el esquema:

1. Edita `01_esquema.sql` y `ESTADO_BBDD.md`.
2. Aplica el `ALTER`/`CREATE OR REPLACE` correspondiente contra la
   BBDD viva (pgAdmin → *Query Tool*) — el fichero solo se ejecuta al
   inicializar una BBDD vacía.
3. Verifica en `pgadmin`.

## 8. Histórico de plazas para el simulacro

El cálculo del simulacro lee de la tabla `config`. Para rellenar los
baremos históricos (pgAdmin → Query Tool):

```sql
UPDATE config SET valor = '[[55,1],[50,200],[45,500]]'::jsonb
 WHERE clave = 'historico_2024';
UPDATE config SET valor = '[[60,1],[55,150],[50,400]]'::jsonb
 WHERE clave = 'historico_2022';
UPDATE config SET valor = '844'::jsonb WHERE clave = 'plazas_referencia';
```
