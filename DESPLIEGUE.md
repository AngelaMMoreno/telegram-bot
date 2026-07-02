# Despliegue en Dokploy

Guía para levantar el stack completo (PostgreSQL + PostgREST + landing +
tests + teoría + embeddings + pgAdmin) y servirlo en los dominios de
producción.

Todo el frontend comparte la misma cuenta: el JWT se guarda como cookie
en dominio `.aprentix.es`, así que iniciar sesión en la landing te deja
autenticado también en `test.aprentix.es` y `teoria.aprentix.es`.

## 1. Servicios que componen el stack

| Servicio    | Imagen / build      | Dominio                                                                     |
|-------------|---------------------|-----------------------------------------------------------------------------|
| `db`        | `pgvector/pgvector:pg16` | — (solo red interna `dokploy-network`)                                  |
| `postgrest` | `postgrest/postgrest:v12.2.3` | `api.aprentix.es` (`DOMINIO_API`)                                 |
| `landing`   | build `./landing` (Caddy) | `aprentix.es` **+** `www.aprentix.es` (login + chooser)               |
| `web`       | build `./web` (Caddy) | `test.aprentix.es` **+** `www.test.aprentix.es` (SPA de tests)          |
| `teoria`    | build `./teoria` (FastAPI) | `teoria.aprentix.es` **+** `www.teoria.aprentix.es` (ficheros)     |
| `embeddings`| build `./embeddings` | — (worker interno)                                                         |
| `pgadmin`   | `dpage/pgadmin4:9`   | `pgadmin.aprentix.es` (`DOMINIO_PGADMIN`)                                  |

Postgres no publica puerto al host: solo escucha en `dokploy-network`. El
acceso administrativo entra por HTTPS vía pgAdmin.

El servicio de teoría monta `/mnt/data/ficheros` (misma ruta que tenía el
servidor de ficheros antiguo). No hace falta mover nada al desplegar por
primera vez sobre un servidor con ese volumen ya poblado.

## 2. Roles y flujo de usuario

Roles funcionales de la aplicación (columna `roles` del JWT):

| Rol      | Puede |
|----------|-------|
| `alumno` | Realizar tests, ver su progreso y sus repasos. |
| `editor` | Todo lo de `alumno` + crear/editar preguntas, tests y etiquetas. |
| `admin`  | Todo lo anterior + gestión de usuarios y CRUD sobre teoría. |
| `teoria` | Ver y descargar el material de teoría. Ortogonal a los demás. |

Un usuario puede tener varios roles a la vez (por ejemplo `alumno + teoria`
si ha contratado ambas cosas). Los admin siempre pueden entrar a teoría
aunque no tengan asignado el rol `teoria`.

Flujo típico:

1. Registro en `aprentix.es` → el usuario nuevo entra como `alumno`.
2. Un admin le añade `teoria` cuando corresponda desde el panel de
   usuarios (los admin tienen acceso vía `asignar_rol`).
3. Al hacer login, la landing enseña una tarjeta para Tests y otra para
   Teoría (la de Teoría solo si el usuario tiene el permiso).

## 3. Crear la aplicación en Dokploy

1. Dokploy → **Create Compose Application**.
2. Source: este repositorio, rama por defecto.
3. Compose path: `docker-compose.yml`.
4. **Environment Variables** (copiar de `.env.example` y rellenar):

   | Clave                | Ejemplo / notas                                             |
   |----------------------|-------------------------------------------------------------|
   | `DB_PASS`            | Contraseña fuerte del rol `aprentix`.                       |
   | `AUTH_PASS`          | Contraseña del rol `autenticador` (PostgREST).              |
   | `JWT_SECRET`         | ≥ 32 caracteres (`openssl rand -hex 32`).                   |
   | `ADMIN_PASS`         | Contraseña inicial del usuario `admin` (mínimo 8).          |
   | `DOMINIO_LANDING`    | `aprentix.es`.                                              |
   | `DOMINIO_LANDING_ALT`| `www.aprentix.es`.                                          |
   | `DOMINIO_WEB`        | `test.aprentix.es`.                                         |
   | `DOMINIO_WEB_ALT`    | `www.test.aprentix.es`.                                     |
   | `DOMINIO_TEORIA`     | `teoria.aprentix.es`.                                       |
   | `DOMINIO_TEORIA_ALT` | `www.teoria.aprentix.es`.                                   |
   | `DOMINIO_API`        | `api.aprentix.es` (PostgREST).                              |
   | `DOMINIO_PGADMIN`    | `pgadmin.aprentix.es`.                                      |
   | `PGADMIN_EMAIL`      | Correo del login de pgAdmin.                                |
   | `PGADMIN_PASS`       | Contraseña de pgAdmin.                                      |

5. Crea los registros DNS **A** apuntando a la IP del servidor para
   cada uno de los ocho dominios (Let's Encrypt los necesita accesibles
   antes de emitir el certificado).
6. **Deploy**.

Dokploy ejecuta `docker compose up -d`. Al arrancar por primera vez, `db`
corre `db/init/01_esquema.sql` (crea tablas, funciones, RLS, seed y
usuario `admin`).

## 4. Verificación rápida

Desde el host del servidor:

```bash
docker compose -f /etc/dokploy/applications/<id>/code/docker-compose.yml ps
docker compose ... logs db --tail=80
docker compose ... logs landing web teoria postgrest embeddings --tail=40
```

En los logs de `db` debes ver `database system is ready to accept
connections` y la ejecución de `01_esquema.sql`.

En el navegador:

- `https://aprentix.es` → landing con login + chooser.
- `https://test.aprentix.es` → SPA de tests.
- `https://teoria.aprentix.es` → navegador de ficheros (bloquea si no tienes rol).
- `https://api.aprentix.es` → OpenAPI de PostgREST.
- `https://pgadmin.aprentix.es` → panel de administración.

## 5. Login inicial

- Usuario `admin` con la contraseña `ADMIN_PASS` que configuraste en
  el `.env` (creada por el bloque final de `01_esquema.sql`).
- Cualquier registro nuevo desde la landing entra como rol `alumno`; el
  admin puede promoverlo a `editor` / `admin` / `teoria` desde el panel
  de usuarios (o llamando a `asignar_rol` desde pgAdmin).

## 6. Conexión con pgAdmin

1. `https://pgadmin.aprentix.es` → login con `PGADMIN_EMAIL` /
   `PGADMIN_PASS`.
2. En el panel izquierdo aparece precargado el servidor **aprentix**
   (`pgadmin/servers.json`) apuntando a `db:5432`.
3. Click derecho → *Connect Server* → introducir `DB_PASS`.

## 7. Backup / restauración

```bash
# Backup en el servidor
docker compose exec db pg_dump -Fc -U aprentix -d aprentix \
    > db/backups/aprentix_$(date +%F).dump

# Restauración en otro servidor (con el stack levantado sobre BBDD vacía)
cat aprentix_YYYY-MM-DD.dump | \
    docker compose exec -T db pg_restore -U aprentix -d aprentix -c
```

Los ficheros de teoría se respaldan aparte (`rsync` de `/mnt/data/ficheros`).

## 8. Cambios de esquema

El proyecto **no usa carpetas de migraciones**: el estado actual vive
en un único fichero:

- `db/init/01_esquema.sql` — SQL autoritativo.
- `db/ESTADO_BBDD.md` — documentación de referencia.

Al cambiar el esquema:

1. Edita `01_esquema.sql` y `ESTADO_BBDD.md`.
2. Aplica el `ALTER`/`CREATE OR REPLACE` correspondiente contra la
   BBDD viva (pgAdmin → Query Tool) — el fichero solo se ejecuta al
   inicializar una BBDD vacía.

## 9. Histórico de plazas para el simulacro

El cálculo del simulacro lee de la tabla `config`. Para rellenar los
baremos históricos (pgAdmin → Query Tool):

```sql
UPDATE config SET valor = '[[55,1],[50,200],[45,500]]'::jsonb
 WHERE clave = 'historico_2024';
UPDATE config SET valor = '[[60,1],[55,150],[50,400]]'::jsonb
 WHERE clave = 'historico_2022';
UPDATE config SET valor = '844'::jsonb WHERE clave = 'plazas_referencia';
```
