# Despliegue en Dokploy

El proyecto está partido en **cuatro stacks independientes** para poder
redesplegarlos por separado desde Dokploy. Cada stack es una **Compose
Application** distinta que apunta a su propio fichero:

```
deploy/
├── core/docker-compose.yml         ← db + postgrest + embeddings + pgadmin
├── landing/docker-compose.yml      ← aprentix.es / www.aprentix.es
├── web/docker-compose.yml          ← test.aprentix.es / www.test.aprentix.es
├── teoria/docker-compose.yml       ← teoria.aprentix.es / www.teoria.aprentix.es
└── notificador/docker-compose.yml  ← worker de Web Push (sin dominio propio)
```

Los cuatro comparten la red externa `dokploy-network` y se ven entre sí
por nombre de servicio (`db:5432`, `postgrest:3000`).

El `docker-compose.yml` raíz **solo es para desarrollo local**: usa
`include:` para levantar los cuatro composes de una tacada
(`docker compose up`). Dokploy no lo utiliza.

## 0. Preparar el servidor

1. Instalar Dokploy si aún no lo tienes.
2. La red `dokploy-network` la crea Dokploy automáticamente al
   desplegar el primer stack; no hace falta hacer nada.
3. Crear el volumen de datos en el host (una sola vez):

   ```bash
   sudo mkdir -p /mnt/data/pg /mnt/data/embeddings_cache /mnt/data/ficheros
   ```

4. Crear los registros DNS **A** apuntando a la IP del servidor para
   los ocho dominios (Let's Encrypt los necesita):
   `aprentix.es`, `www.aprentix.es`, `test.aprentix.es`,
   `www.test.aprentix.es`, `teoria.aprentix.es`, `www.teoria.aprentix.es`,
   `api.aprentix.es`, `pgadmin.aprentix.es`.

## 1. Orden de despliegue

Crea las Compose Applications en Dokploy en este orden:

1. **core** — imprescindible; el resto depende de que la BBDD esté viva.
2. **teoria** — necesita compartir el `JWT_SECRET` con `core`.
3. **landing** y **web** — independientes entre sí, se pueden desplegar
   en cualquier orden después de `core`.

En Dokploy, para cada una:

1. **Create Compose Application**.
2. Source: este repositorio, rama por defecto.
3. **Compose path**: el fichero correspondiente (ver tabla más abajo).
4. Variables de entorno: copiar del `.env.example` de la carpeta.
5. Deploy.

| Stack     | Compose path                          | .env de referencia            |
|-----------|---------------------------------------|-------------------------------|
| `core`    | `deploy/core/docker-compose.yml`      | `deploy/core/.env.example`    |
| `landing` | `deploy/landing/docker-compose.yml`   | `deploy/landing/.env.example` |
| `web`     | `deploy/web/docker-compose.yml`       | `deploy/web/.env.example`     |
| `teoria`  | `deploy/teoria/docker-compose.yml`    | `deploy/teoria/.env.example`  |

## 2. Variables de entorno por stack

### `core` (db + postgrest + embeddings + pgadmin)

| Clave              | Uso                                                            |
|--------------------|----------------------------------------------------------------|
| `DB_PASS`          | Contraseña del rol `aprentix` (owner de la BBDD).              |
| `AUTH_PASS`        | Contraseña del rol `autenticador` (con el que conecta PostgREST). |
| `JWT_SECRET`       | HMAC HS256 con el que Postgres firma los JWT. **Debe coincidir con el de `teoria`.** |
| `ADMIN_PASS`       | Contraseña inicial del usuario `admin` de la app (solo se aplica en el primer init). |
| `PGADMIN_EMAIL`    | Login de pgAdmin.                                              |
| `PGADMIN_PASS`     | Contraseña de pgAdmin.                                         |
| `DOMINIO_API`      | Host de PostgREST (por defecto `api.aprentix.es`).             |
| `DOMINIO_PGADMIN`  | Host de pgAdmin (por defecto `pgadmin.aprentix.es`).           |

### `landing` (aprentix.es)

| Clave                 | Uso                                                    |
|-----------------------|--------------------------------------------------------|
| `DOMINIO_LANDING`     | Host principal (por defecto `aprentix.es`).            |
| `DOMINIO_LANDING_ALT` | Host alternativo (por defecto `www.aprentix.es`).      |

### `web` (SPA de tests)

| Clave              | Uso                                                            |
|--------------------|----------------------------------------------------------------|
| `DOMINIO_WEB`      | Host principal (por defecto `test.aprentix.es`).               |
| `DOMINIO_WEB_ALT`  | Host alternativo (por defecto `www.test.aprentix.es`).         |

### `teoria` (navegador de ficheros)

| Clave                | Uso                                                                    |
|----------------------|------------------------------------------------------------------------|
| `JWT_SECRET`         | Igual que el de `core` (el backend verifica los JWT).                  |
| `DOMINIO_TEORIA`     | Host principal (por defecto `teoria.aprentix.es`).                     |
| `DOMINIO_TEORIA_ALT` | Host alternativo (por defecto `www.teoria.aprentix.es`).               |

> **Importante:** `JWT_SECRET` aparece en `core` y `teoria`; los dos
> deben tener EXACTAMENTE el mismo valor, si no, las cookies emitidas
> por PostgREST no valdrán para el backend de teoría.

## 3. Verificación

Desde el host del servidor:

```bash
docker network inspect dokploy-network | jq '.[].Containers | keys'
```

Deberías ver contenedores de los cuatro stacks conectados a la misma red.

Compose por compose:

```bash
docker compose -f deploy/core/docker-compose.yml logs db --tail=80
docker compose -f deploy/teoria/docker-compose.yml logs teoria --tail=40
docker compose -f deploy/web/docker-compose.yml logs web --tail=40
docker compose -f deploy/landing/docker-compose.yml logs landing --tail=40
```

En el navegador:

- `https://aprentix.es` → landing con login + chooser.
- `https://test.aprentix.es` → SPA de tests.
- `https://teoria.aprentix.es` → navegador de ficheros.
- `https://api.aprentix.es` → OpenAPI de PostgREST.
- `https://pgadmin.aprentix.es` → panel de administración.

## 4. Redespliegues por parte

- **Cambio en el esquema SQL** (`db/init/01_esquema.sql`) → redeploy
  solo `core`. La BBDD reejecuta scripts de `docker-entrypoint-initdb.d`
  solo si el volumen está vacío; para BBDD viva, aplica el `ALTER` /
  `CREATE OR REPLACE` desde pgAdmin.
- **Cambio en la SPA de tests** → redeploy solo `web`.
- **Cambio en teoría (backend o SPA)** → redeploy solo `teoria`.
- **Cambio en la landing** → redeploy solo `landing`.

Los stacks son independientes: reiniciar `web` no toca a `db`.

## 5. Login inicial

- Usuario `admin` con la contraseña `ADMIN_PASS` del stack `core`
  (creada por el bloque final de `db/init/01_esquema.sql`).
- Registros nuevos entran como `alumno`. El admin promueve al rol
  `teoria` desde el panel de usuarios de la SPA de tests (o llamando a
  `asignar_rol` desde pgAdmin).

## 6. Backup / restauración

```bash
# Backup de la BBDD (dentro del contenedor db del stack core)
docker compose -f deploy/core/docker-compose.yml exec db \
    pg_dump -Fc -U aprentix -d aprentix > db/backups/aprentix_$(date +%F).dump

# Restauración sobre BBDD vacía
cat aprentix_YYYY-MM-DD.dump | \
    docker compose -f deploy/core/docker-compose.yml exec -T db \
    pg_restore -U aprentix -d aprentix -c
```

Los ficheros de teoría se respaldan aparte: `rsync -a
/mnt/data/ficheros/ destino/`.

## 7. Desarrollo local

Con Docker Compose ≥ 2.20:

```bash
cp .env.example .env
# edita .env con tus valores
docker compose up --build
```

El `include:` del `docker-compose.yml` raíz agrupa los cuatro composes
como si fuera uno solo, así que sale toda la plataforma con un único
comando. Para levantar solo una parte:

```bash
docker compose -f deploy/core/docker-compose.yml up -d
docker compose -f deploy/web/docker-compose.yml up -d
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

1. Genera el par de claves VAPID (en tu máquina o en un shell del
   contenedor):
   ```bash
   pip install py-vapid
   python notificador/gen_vapid.py
   ```
2. Copia `VAPID_PRIVATE_KEY` y `VAPID_PUBLIC_KEY` a las variables de
   entorno del stack `notificador` en Dokploy (y a `.env` en local).
3. Guarda la clave PÚBLICA también en la BBDD para que la SPA la lea:
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
