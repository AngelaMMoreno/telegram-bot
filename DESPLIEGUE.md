# Despliegue en Dokploy

> **Rama `desa` / entorno `desarrollo` de Dokploy.** Este README describe
> el despliegue de PRODUCCIÓN (rama `main`, entorno `produccion`). Para el
> despliegue paralelo de esta misma rama en el entorno `desarrollo`, ver
> la sección **[Entorno `desarrollo` en paralelo](#entorno-desarrollo-en-paralelo-rama-desa)**
> al final.

El proyecto está partido en **tres stacks independientes** para poder
redesplegarlos por separado desde Dokploy. Cada stack es una **Compose
Application** distinta que apunta a su propio fichero:

```
deploy/
├── core/docker-compose.yml         ← db + postgrest + embeddings + pgadmin
├── app/docker-compose.yml          ← SPA remodelada de estudio + API de contenidos, todo en un contenedor
├── notificador/docker-compose.yml  ← worker de Web Push (sin dominio propio)
└── backups/docker-compose.yml      ← snapshots automáticos a Google Drive (restic + rclone)
```

Los tres comparten la red externa `dokploy-network` y se ven entre sí
por nombre de servicio (`db:5432`, `postgrest:3000`).

El `docker-compose.yml` raíz **solo es para desarrollo local**: usa
`include:` para levantar los tres composes de una tacada
(`docker compose up`). Dokploy no lo utiliza.

## Estructura del frontend

La interfaz remodelada es la única SPA desplegada:

```
web/
├── estudio/            ← SPA unificada de estudio (tests + teoría)
│   └── manifest.webmanifest
├── shared/             ← sesión, cabecera, estilos e iconos comunes
│   └── auth/session.js ← access token, refresh token y cliente RPC
└── service-worker.js   ← service worker en la raíz con scope "/"
```

El backend de contenidos vive en `teoria/app.py` (FastAPI), sin servir una
segunda SPA, y se empaqueta junto al frontend en `deploy/app/`. Las rutas
antiguas `/tests/` y `/teoria/` redirigen a `/estudio/`; `/teoria/api/` se
reserva para la API de contenidos.

## 0. Preparar el servidor

1. Instalar Dokploy si aún no lo tienes.
2. La red `dokploy-network` la crea Dokploy automáticamente al
   desplegar el primer stack; no hace falta hacer nada.
3. Crear el volumen de datos en el host (una sola vez):

   ```bash
   sudo mkdir -p /mnt/data/pg /mnt/data/embeddings_cache /mnt/data/ficheros
   ```

4. Crear los registros DNS **A** apuntando a la IP del servidor para
   cada host que vayas a servir. En prod típicamente:
   `aprentix.es`, `www.aprentix.es`, `api.aprentix.es`,
   `pgadmin.aprentix.es`. Los dominios legacy `test.aprentix.es` y
   `teoria.aprentix.es` sólo son necesarios si los declaras en
   `DOMINIO_WEB` / `DOMINIO_TEORIA`; redirigen a `${DOMINIO_LANDING}`.
   Para desplegar además la rama de desarrollo en paralelo, añade un A
   record extra (p.ej. `desa.aprentix.es`) y en el stack de esa rama
   pon `DOMINIO_LANDING=desa.aprentix.es`.

## 1. Orden de despliegue

Crea las Compose Applications en Dokploy en este orden:

1. **core** — imprescindible; el resto depende de que la BBDD esté viva.
2. **app** — necesita compartir el `JWT_SECRET` con `core`.

En Dokploy, para cada una:

1. **Create Compose Application**.
2. Source: este repositorio, rama por defecto.
3. **Compose path**: el fichero correspondiente (ver tabla más abajo).
4. Variables de entorno: copiar del `.env.example` de la carpeta.
5. Deploy.

| Stack     | Compose path                          | .env de referencia            |
|-----------|---------------------------------------|-------------------------------|
| `core`    | `deploy/core/docker-compose.yml`      | `deploy/core/.env.example`    |
| `app`     | `deploy/app/docker-compose.yml`       | (usa `JWT_SECRET` de `core`)  |

## 2. Variables de entorno por stack

### `core` (db + postgrest + embeddings + pgadmin)

| Clave              | Uso                                                            |
|--------------------|----------------------------------------------------------------|
| `DB_PASS`          | Contraseña del rol `aprentix` (owner de la BBDD).              |
| `AUTH_PASS`        | Contraseña del rol `autenticador` (con el que conecta PostgREST). |
| `JWT_SECRET`       | HMAC HS256 con el que Postgres firma los JWT. **Debe coincidir con el de `app`.** |
| `ADMIN_PASS`       | Contraseña inicial del usuario `admin` de la app (solo se aplica en el primer init). |
| `PGADMIN_EMAIL`    | Login de pgAdmin.                                              |
| `PGADMIN_PASS`     | Contraseña de pgAdmin.                                         |
| `DOMINIO_API`      | Host de PostgREST (por defecto `api.aprentix.es`).             |
| `DOMINIO_PGADMIN`  | Host de pgAdmin (por defecto `pgadmin.aprentix.es`).           |

### `app` (SPA de estudio + API de contenidos)

| Clave                 | Uso                                                                             |
|-----------------------|---------------------------------------------------------------------------------|
| `JWT_SECRET`          | Igual que el de `core` (el backend de teoría verifica los JWT).                 |
| `DOMINIO_LANDING`     | **Obligatorio.** Host de la SPA para este despliegue. Prod → `aprentix.es`; rama de desarrollo → `desa.aprentix.es`. |
| `DOMINIO_LANDING_ALT` | Alias opcional (típicamente `www.<host principal>`). Si se deja vacío, cae al mismo valor que `DOMINIO_LANDING`. |
| `DOMINIO_WEB`         | Host legacy opcional redirigido a `${DOMINIO_LANDING}`. Sin valor → placeholder `.invalid` inerte (recomendado en dev/preview). |
| `DOMINIO_WEB_ALT`     | Alias opcional del legacy anterior.                                             |
| `DOMINIO_TEORIA`      | Host legacy opcional redirigido a `${DOMINIO_LANDING}`. Sin valor → placeholder `.invalid` inerte. |
| `DOMINIO_TEORIA_ALT`  | Alias opcional del legacy anterior.                                             |

> **Un stack por dominio.** Para tener a la vez la app de producción en
> `aprentix.es` y la de la rama de desarrollo en `desa.aprentix.es`, crea
> DOS Compose Applications en Dokploy (una por rama) con distintos valores
> de `DOMINIO_LANDING`. Ambas comparten el mismo Traefik y `core`; los
> hosts legacy (`test.*`, `teoria.*`) sólo se declaran en el stack de
> producción para que el de dev no intente registrarlos también.

> **Importante:** `JWT_SECRET` aparece en `core` y `app`; los dos deben
> tener EXACTAMENTE el mismo valor, si no, las cookies emitidas por
> PostgREST no valdrán para el backend de teoría.

## 3. Verificación

Desde el host del servidor:

```bash
docker network inspect dokploy-network | jq '.[].Containers | keys'
```

Deberías ver contenedores de los tres stacks conectados a la misma red.

Compose por compose:

```bash
docker compose -f deploy/core/docker-compose.yml logs db --tail=80
docker compose -f deploy/app/docker-compose.yml logs app --tail=40
docker compose -f deploy/notificador/docker-compose.yml logs notificador --tail=40
```

En el navegador:

- `https://aprentix.es` → redirección a la aplicación de estudio.
- `https://aprentix.es/estudio/` → SPA remodelada con login, tests y teoría.
- `https://aprentix.es/tests/`, `https://aprentix.es/teoria/`,
  `https://test.aprentix.es` y `https://teoria.aprentix.es` → redirección a
  `/estudio/` (rutas legacy conservadas sin desplegar sus aplicaciones).
- `https://api.aprentix.es` → OpenAPI de PostgREST.
- `https://pgadmin.aprentix.es` → panel de administración.

## 4. Redespliegues por parte

- **Cambio en el esquema SQL** (`db/init/01_esquema.sql`) → redeploy
  solo `core`. La BBDD reejecuta scripts de `docker-entrypoint-initdb.d`
  solo si el volumen está vacío; para BBDD viva, aplica el `ALTER` /
  `CREATE OR REPLACE` desde pgAdmin.
- **Cambio en la SPA de estudio o en la API de contenidos** → redeploy solo `app`.
- **Cambio en el notificador de push** → redeploy solo `notificador`.

Los stacks son independientes: reiniciar `app` no toca a `db`.

## 5. Login inicial

- Usuario `admin` con la contraseña `ADMIN_PASS` del stack `core`
  (creada por el bloque final de `db/init/01_esquema.sql`).
- Registros nuevos entran como `tests`. El admin añade además el rol
  `teoria` (o cualquier otro) desde el panel de usuarios de la SPA de
  tests (o llamando a `asignar_rol` desde pgAdmin). Ambos roles solo
  ven contenido de las oposiciones que el admin les haya asignado.

## 6. Backup / restauración

### 6.1 Snapshots automáticos a Google Drive (stack `backups`)

Un contenedor de fondo (`deploy/backups/`) lanza cada noche un
snapshot deduplicado y cifrado de la BBDD + `/mnt/data/ficheros` sobre
un repositorio [restic](https://restic.net/) alojado en Google Drive
vía rclone. La retención por defecto (`KEEP_LAST=2`) conserva los 2
snapshots más recientes de cada tag (`db` y `teoria`); todo lo
anterior se poda y libera espacio en Drive automáticamente.

Restic deduplica a nivel de bloque, así que la primera corrida sube
el estado entero y las noches siguientes solo suben los cambios
reales; para restaurar necesitas `restic` + `rclone` +
`RESTIC_PASSWORD` desde cualquier máquina.

**Setup completo (una sola vez)**: `deploy/backups/README.md`
describe paso a paso `rclone config` en local, la copia de
`rclone.conf` al VPS, las variables de Dokploy y el primer arranque.
Resumen:

| Clave               | Uso                                                                            |
|---------------------|--------------------------------------------------------------------------------|
| `DB_PASS`           | Igual que en `core` (pg_dump se conecta al servicio `db`).                     |
| `RESTIC_REPOSITORY` | `rclone:<remote>:<carpeta>` — el `<remote>` es el nombre que le des en rclone. |
| `RESTIC_PASSWORD`   | Contraseña de cifrado del repo restic. **Guárdala en un gestor.**              |
| `KEEP_LAST`         | Snapshots conservados por tag (default 2 → anoche + antes).                    |
| `BACKUP_CRON`       | Cron de 5 campos (default `30 3 * * *` = todas las noches a las 03:30).        |
| `TZ`                | Zona horaria del cron y de los logs (default `Europe/Madrid`).                 |

Además necesitas subir una vez `rclone.conf` con el token OAuth de
Drive a `/mnt/data/backup-config/rclone.conf` en el VPS — ver
`deploy/backups/README.md`.

**Restaurar** desde cualquier máquina:

```bash
export RESTIC_REPOSITORY=rclone:gdrive:aprentix-backups
export RESTIC_PASSWORD='...'
restic snapshots
restic restore latest --tag db     --host aprentix --target /tmp/r
restic restore latest --tag teoria --host aprentix --target /tmp/r
psql -h HOST -U aprentix -d aprentix < /tmp/r/stdin
sudo rsync -a --delete /tmp/r/data/ficheros/ /mnt/data/ficheros/
```

## 7. Desarrollo local

Con Docker Compose ≥ 2.20:

```bash
cp .env.example .env
# edita .env con tus valores
docker compose up --build
```

El `include:` del `docker-compose.yml` raíz agrupa los tres composes
como si fuera uno solo, así que sale toda la plataforma con un único
comando. Para levantar solo una parte:

```bash
docker compose -f deploy/core/docker-compose.yml up -d
docker compose -f deploy/app/docker-compose.yml up -d
```

## 8. Cambios de esquema en BBDD viva

El proyecto **no usa carpetas de migraciones**; el estado autoritativo
vive en `db/init/01_esquema.sql`. Al modificarlo:

1. Edita `01_esquema.sql` y `db/ESTADO_BBDD.md`.
2. Aplica el `ALTER` / `CREATE OR REPLACE` correspondiente contra la
   BBDD viva (pgAdmin → Query Tool). El script solo se ejecuta cuando
   Postgres se inicializa sobre volumen vacío.
3. Commit + push; Dokploy no redeploya nada solo por esto — el
   contenedor `db` no arranca de cero.

## 9. Histórico de plazas para el simulacro

```sql
UPDATE config SET valor = '[[55,1],[50,200],[45,500]]'::jsonb
 WHERE clave = 'historico_2024';
UPDATE config SET valor = '[[60,1],[55,150],[50,400]]'::jsonb
 WHERE clave = 'historico_2022';
UPDATE config SET valor = '844'::jsonb WHERE clave = 'plazas_referencia';
```

## 10. Notificaciones Web Push

El stack `notificador` es un servicio Python que consulta la BBDD cada
`TICK_SECONDS` (5 min por defecto) y envía Web Push firmados con VAPID.

**Primer despliegue:**

1. Genera el par de claves VAPID en **tu máquina local** (no hace falta
   contenedor):
   ```bash
   pip install py-vapid
   python notificador/gen_vapid.py
   ```
   El script imprime la privada en 3 formatos y la pública en 1.
2. Copia `VAPID_PUBLIC_KEY` y una de las tres variantes de
   `VAPID_PRIVATE_KEY` a las variables de entorno del stack `notificador`
   en Dokploy (y a `.env` en local). El worker acepta cualquiera de:

   | Formato | Uso |
   |---|---|
   | (A) PEM en una línea con `\n` literales | El más común, recomendado para .env |
   | (B) Base64 del PEM completo | Si tu UI se atraganta con las barras `/` |
   | (C) PEM multilínea con saltos reales | Solo si tu UI acepta valores multilínea |

   **Errores típicos**: si Dokploy te dice
   `unexpected character "/" in variable name`, tu UI ha guardado el PEM
   como si cada línea fuera una variable distinta. Usa la variante (A) o
   (B) del script.
3. Guarda la clave PÚBLICA también en la BBDD para que la SPA la lea
   (el script imprime este `UPDATE` listo para pegar en pgAdmin):
   ```sql
   UPDATE config
      SET valor = jsonb_build_object('valor', 'BFm...la_publica...',
                                     'descripcion', valor->>'descripcion')
    WHERE clave = 'push_vapid_public';
   ```
4. Levanta el stack. En logs verás:
   `notificador arrancado (tick=300s, batch=500)`.

**Ajustar comportamiento sin redeployar:** cambia los valores en la tabla
`config` (todas las claves empiezan por `push_`). El siguiente tick los
recoge.

| Clave                             | Default | Qué controla                                      |
|-----------------------------------|--------:|---------------------------------------------------|
| `push_ventana_ini`                |    `9`  | Hora inicial para enviar (Europe/Madrid)          |
| `push_ventana_fin`                |   `22`  | Hora final exclusiva                              |
| `push_intervalo_repaso_horas`     |    `5`  | Horas mínimas entre pushes de repaso por usuario  |
| `push_inactividad_horas`          |   `24`  | Horas sin acceder para lanzar aviso motivacional  |
| `push_inactividad_cooldown_horas` |   `48`  | Cooldown entre avisos de inactividad              |
| `push_min_vencidas`               |    `5`  | Mínimo de preguntas vencidas para lanzar aviso    |
| `push_tz`                         | `Europe/Madrid` | Zona horaria de la ventana                 |

## Entorno `desarrollo` en paralelo (rama `desa`)

Este bloque documenta cómo desplegar la rama `desa` en un **entorno
Dokploy independiente** que corre EN PARALELO al entorno `produccion`
(rama `main`), sin pisarse. El entorno `desarrollo` se apoya en la
infraestructura ya levantada por producción (Postgres, pgAdmin, red
Traefik) y sólo despliega sus propios `postgrest`/`mailer`/`app`.

### Arquitectura resumida

```
                 ┌───────── Entorno `produccion` (rama main) ─────────┐
                 │                                                    │
                 │  core-prod:  db  ·  pgadmin  ·  postgrest  · mailer│
                 │  app-prod:   app (aprentix.es)                     │
                 │  notificador-prod                                  │
                 │  backups-prod                                      │
                 └────────────┬───────────────────────────────────────┘
                              │  dokploy-network (compartida)
                              │  · alias `db`   → único postgres
                              │  · alias `pgadmin` → único pgAdmin
                              ▼
                 ┌───────── Entorno `desarrollo` (rama desa) ─────────┐
                 │                                                    │
                 │  core-desa:  postgrest_desa  ·  mailer_desa        │
                 │              (NO db, NO pgadmin)                   │
                 │  app-desa:   app (desa.aprentix.es)                │
                 │  (sin notificador, sin backups)                    │
                 └────────────────────────────────────────────────────┘
```

Un único Postgres en el host (`/mnt/data/pg`) con DOS bases de datos
dentro: `aprentix` (la usa prod) y `aprentix_desa` (la usa desa). Un
único pgAdmin en `pgadmin.aprentix.es` desde el que se ven ambas.

### Qué crea el entorno `desarrollo` en Dokploy

En Dokploy, dentro del entorno `desarrollo`, se crean SÓLO dos Compose
Applications, ambas apuntando a la rama `desa`:

| Stack       | Compose path                              | .env de referencia               |
|-------------|-------------------------------------------|----------------------------------|
| `core-desa` | `deploy/core/docker-compose.yml`          | `deploy/core/.env.example`       |
| `app-desa`  | `deploy/app/docker-compose.yml`           | `deploy/app/.env.example`        |
| `publicador-desa` | `deploy/publicador/docker-compose.yml` | `deploy/publicador/.env.example` |

**NO crear en desa** las Compose Applications de `notificador` ni
`backups` — corren sólo en producción y ya cubren el sistema entero.

**`publicador` sí va en los dos entornos**, a diferencia de los
anteriores: cada uno publica su rama del repo de contenido en su base de
datos (`desa` → `aprentix_desa`, `main` → `aprentix`). Así el contenido
recorre el mismo camino que el código y se comprueba en
`desa.aprentix.es` antes de llegar a producción. Ver
`deploy/publicador/README.md`.

### Diferencias respecto a los ficheros de producción

Los composes de esta rama están recortados/renombrados a propósito:

- `deploy/core/docker-compose.yml` **no define `db` ni `pgadmin`**.
  Dos motivos:
    - `db` de prod usa bind mount `/mnt/data/pg`. Levantar otro `db` en
      la misma máquina lo pisaría → corrupción segura.
    - El pgAdmin de prod ya alcanza `aprentix_desa` porque vive en el
      mismo cluster.
- `postgrest` y `mailer` se llaman **`postgrest_desa`** y
  **`mailer_desa`**. El alias DNS de un servicio en `dokploy-network`
  coincide con su nombre de servicio y no se puede suprimir: si en la
  red compartida hubiera dos alias `postgrest`, los clientes recibirían
  round-robin entre prod y desa → bug silencioso apuntando a la BD
  equivocada.
- Los router names y middlewares de Traefik (`api`, `app`,
  `web-legacy`, `teoria-legacy`, `api-rl`, …) llevan sufijo **`-desa`**
  por la misma razón: Traefik dedupe routers por nombre y sólo
  sobrevive uno.
- `deploy/app/Dockerfile` y `deploy/app/Caddyfile` apuntan a
  `postgrest_desa:3000` (no a `postgrest:3000`). Como cada rama
  construye su propia imagen, no hay conflicto entre las imágenes de
  prod y desa.

### Preparativos (una sola vez)

1. **Crear la BD `aprentix_desa` en el cluster Postgres de prod.** Si
   aún no existe, seguir `db/bootstrap_aprentix_desa.sql`
   (`CREATE DATABASE aprentix_desa OWNER aprentix;` + aplicar
   `db/init/01_esquema.sql` con los mismos `app.jwt_secret`,
   `app.auth_pass`, `app.admin_pass` que en prod).
2. **Añadir la entrada de `aprentix_desa` en pgAdmin.** Como el
   volumen `pgadmin_data` de prod ya está inicializado, editar
   `pgadmin/servers.json` NO añade retroactivamente el nuevo server.
   Opciones:
     - **Recomendado**: en el panel de pgAdmin de prod, click derecho
       sobre `Servers` → `Register` → `Server…`, con Host `db`, Port
       `5432`, Maintenance database `aprentix_desa`, Username
       `aprentix`. La entrada se persiste en `pgadmin_data`.
     - Alternativa: parar pgAdmin, borrar el volumen `pgadmin_data`, y
       redeployar prod → pgAdmin reseedará desde el `servers.json`
       actualizado (que ya trae ambas entradas en esta rama).
3. **A record DNS**: `desa.aprentix.es` y `api.desa.aprentix.es`
   apuntando a la IP del VPS. Let's Encrypt emitirá los certs al primer
   request TLS.

### Variables por stack en el entorno `desarrollo`

#### `core-desa`

| Clave                | Valor típico               | Notas                                        |
|----------------------|----------------------------|----------------------------------------------|
| `POSTGRES_DB`        | `aprentix_desa`            | La BD de desarrollo en el cluster compartido.|
| `POSTGRES_USER`      | `aprentix`                 | Rol global (mismo que prod).                 |
| `DB_PASS`            | *el mismo que en prod*     | Rol global, una sola password real.          |
| `AUTH_PASS`          | *el mismo que en prod*     | Rol global `autenticador`.                   |
| `JWT_SECRET`         | *el mismo que en prod*     | GUC cluster-wide; no se puede tener otro.    |
| `MAILER_DEV_LOG_ONLY`| `1`                        | Recomendado en desa (no envía SMTP real).    |
| `SMTP_*`             | los que quieras            | Sólo se usan si `MAILER_DEV_LOG_ONLY=0`.     |
| `DOMINIO_API`        | `api.desa.aprentix.es`     | Host propio de desa; no pisa `api.aprentix.es`. |

#### `app-desa`

| Clave                 | Valor típico               | Notas                                        |
|-----------------------|----------------------------|----------------------------------------------|
| `JWT_SECRET`          | *el mismo que en `core-desa` (y que en prod)* | Cluster-wide, no negociable. |
| `DOMINIO_LANDING`     | `desa.aprentix.es`         | Obligatorio; no pisa `aprentix.es`.          |
| `DOMINIO_LANDING_ALT` | vacío o `www.desa.aprentix.es` | Alias opcional.                          |
| `DOMINIO_WEB*`, `DOMINIO_TEORIA*` | **dejar vacías** | Los hosts legacy los declara sólo prod.  |

#### `publicador-desa`

| Clave                | Valor típico                                        | Notas                                        |
|----------------------|-----------------------------------------------------|----------------------------------------------|
| `CONTENIDO_REPO`     | `https://x-access-token:<TOKEN>@github.com/…/oposiciones.git` | Token de sólo lectura. No sale en los logs.  |
| `CONTENIDO_RAMA`     | `desa`                                              | En producción, `main`.                       |
| `PUBLICAR_DSN`       | `postgres://aprentix:<DB_PASS>@db:5432/aprentix_desa` | En producción, la BD `aprentix`.           |
| `PUBLICAR_CRON`      | `*/15 * * * *`                                      | En producción basta `0 * * * *`.             |
| `PUBLICAR_APLICAR`   | *(vacío al principio)*                              | Vacío = sólo simulacros; no escribe nada.    |
| `AVISO_EMAIL`        | tu correo                                           | Avisa si una publicación falla.              |
| `SMTP_*`             | *los mismos que `core`*                             | Sólo se usan si `AVISO_EMAIL` está puesta.   |

### Verificación

Desde el VPS, sólo deben existir UN `db` y UN `pgadmin`, y DOS grupos
paralelos de `postgrest`/`mailer`/`app`:

```bash
docker ps --format '{{.Names}}\t{{.Image}}' | sort
# esperado (nombres reales llevarán prefijos del proyecto Dokploy):
#   ...-core-prod-db-1              pgvector/pgvector:pg16
#   ...-core-prod-pgadmin-1         dpage/pgadmin4:9
#   ...-core-prod-postgrest-1       postgrest/postgrest:v12.2.3
#   ...-core-prod-mailer-1          ...
#   ...-core-desa-postgrest_desa-1  postgrest/postgrest:v12.2.3
#   ...-core-desa-mailer_desa-1     ...
#   ...-app-prod-app-1              ...
#   ...-app-desa-app-1              ...
```

En el navegador:
- `https://aprentix.es` → prod.
- `https://api.aprentix.es` → PostgREST prod (BD `aprentix`).
- `https://desa.aprentix.es` → desa.
- `https://api.desa.aprentix.es` → PostgREST desa (BD `aprentix_desa`).
- `https://pgadmin.aprentix.es` → único pgAdmin, ve las dos BDs.

### Limitaciones de compartir el cluster Postgres

Los GUCs `app.jwt_secret`, `app.auth_pass`, `app.admin_pass` los fija
Postgres cluster-wide desde el `command` del contenedor `db` de prod.
Consecuencia: prod y desa comparten OBLIGATORIAMENTE esos tres valores.
Un token emitido por PostgREST-prod se valida en PostgREST-desa y
viceversa (aceptable para dev; si algún día molesta, se pueden fijar
por-BD con `ALTER DATABASE aprentix_desa SET app.jwt_secret = ...`).

### MERGE NOTE para cuando esta rama vuelva a `main`

**No propagar tal cual estos cambios a producción.** Los ficheros de
`deploy/core/` y `deploy/app/` en esta rama están adaptados al entorno
`desarrollo` (sin `db`/`pgadmin`, con sufijos `-desa`). Producción
sigue necesitando el `core` completo (con `db` y `pgadmin`) y los
routers/servicios sin sufijo.

Al preparar el merge, elegir una de estas dos formas de mantener las
dos variantes coexistiendo en `main`:

1. **Dos ficheros por stack** (más simple):
   ```
   deploy/core/docker-compose.prod.yml   ← el actual de main
   deploy/core/docker-compose.desa.yml   ← el de esta rama
   deploy/app/docker-compose.prod.yml
   deploy/app/docker-compose.desa.yml
   ```
   Cada entorno de Dokploy apunta al que le toca en "Compose path".

2. **Un único fichero con `profiles`**: `db` y `pgadmin` con
   `profiles: ["prod"]`, `postgrest`/`postgrest_desa` con perfiles
   `prod`/`desa` respectivos, etc. El entorno de prod arranca con
   `COMPOSE_PROFILES=prod`, el de desa con `COMPOSE_PROFILES=desa`.
   Más compacto pero duplica definiciones dentro del mismo YAML.

En cualquier caso, revisar también:
- `deploy/app/Dockerfile`: el `ENV POSTGREST_URL` debe seguir siendo
  `http://postgrest:3000` en la imagen de prod. En este branch se ha
  cambiado a `postgrest_desa` para desa.
- `deploy/app/Caddyfile`: idem, `reverse_proxy postgrest:3000` en prod.
- `pgadmin/servers.json`: el añadido de `aprentix_desa` en esta rama
  es correcto para prod post-merge (pgAdmin de prod ve las dos BDs);
  se puede propagar tal cual.
- Si en el futuro se quiere desplegar `notificador` o `backups` también
  en desa, hay que renombrarlos (`notificador_desa`, `backups_desa`) y
  separar sus keys VAPID / repo restic para no pisar los de prod.

