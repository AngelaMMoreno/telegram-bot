# Despliegue

Cuatro stacks independientes bajo `deploy/`, cada uno con SU PROPIO
`.env`.  Los nombres de variable son los mismos en cualquier entorno
— sólo cambia el valor.

## Stacks

| Carpeta | Contenido | Publica | Redespliega cuando cambian… |
|---|---|---|---|
| `deploy/core/`        | db + postgrest (+ pgadmin opcional)    | `${DOMINIO_API}`, `${DOMINIO_PGADMIN}` | `db/init/01_esquema.sql`, versión de PostgREST, `pgadmin/servers.json` |
| `deploy/app/`         | Caddy + SPA                             | `${DOMINIO_LANDING}` (+ `_ALT`)         | `web/*`, `deploy/app/Caddyfile`, `deploy/app/Dockerfile` |
| `deploy/mailer/`      | worker SMTP                             | –                                       | `mailer/*` |
| `deploy/notificador/` | worker Web Push                         | –                                       | `notificador/*` |
| `deploy/backups/`     | restic + rclone → Google Drive          | –                                       | `deploy/backups/*` |

## Coexistencia desa + prod (DB_ALIAS)

`DB_ALIAS` se propaga a `container_name`, aliases de red, nombres de
routers Traefik y a los hostnames que los otros stacks usan.  Con la
forma `${DB_ALIAS:+-${DB_ALIAS}}` el sufijo se **omite** cuando la
variable está vacía y se añade cuando tiene valor:

| Entorno | `DB_ALIAS` | container / alias | router Traefik |
|---|---|---|---|
| **Prod** | *(vacío)*  | `db`, `postgrest`, `app`, `mailer`, `notificador`                | `aprentix-api`, `aprentix-web` |
| **Desa** | `desa`     | `db-desa`, `postgrest-desa`, `app-desa`, `mailer-desa`, `notif…` | `aprentix-api-desa`, `aprentix-web-desa` |

Prod se queda tal cual está hoy (no hay que renombrar containers ni
tocar el `servers.json` del pgAdmin).  Desa suma su sufijo y
convive con prod en `dokploy-network` sin colisiones.

**Regla**: el mismo valor de `DB_ALIAS` en los 4 `.env` de un
mismo entorno.

## Variables por stack

Los `.env.example` de cada carpeta traen los valores de desa como
default.  Para prod cambia lo mismo pero al valor de prod.

### `deploy/core/.env`

```
# Distintivo del entorno
DB_ALIAS=desa                             # prod: (vacío)

# PostgreSQL
POSTGRES_DB=aprentix_desa                 # prod: aprentix
POSTGRES_USER=aprentix
DB_PASS=…
AUTH_PASS=…
ADMIN_PASS=…

# JWT (MISMO valor en todos los .env del mismo entorno)
JWT_SECRET=…

# Traefik
DOMINIO_API=api.desa.aprentix.es          # prod: api.aprentix.es

# pgAdmin — SOLO en prod
COMPOSE_PROFILES=                         # prod: pgadmin
PGADMIN_EMAIL=cccoboss12@gmail.com
PGADMIN_PASS=…
DOMINIO_PGADMIN=pgadmin.aprentix.es
```

### `deploy/app/.env`

```
DB_ALIAS=desa                             # prod: (vacío)
POSTGRES_DB=aprentix_desa                 # prod: aprentix
JWT_SECRET=…                              # el mismo que core

DOMINIO_LANDING=desa.aprentix.es          # prod: aprentix.es
DOMINIO_LANDING_ALT=www.desa.aprentix.es  # prod: www.aprentix.es
```

### `deploy/mailer/.env`

```
DB_ALIAS=desa                             # prod: (vacío)
POSTGRES_DB=aprentix_desa                 # prod: aprentix
POSTGRES_USER=aprentix
DB_PASS=…

MAILER_DEV_LOG_ONLY=0                     # 1 → loguea correos, no envía
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=angcar.morcob@gmail.com
SMTP_PASS=…
SMTP_FROM=No Contestar <no-reply@aprentix.es>
SMTP_TLS=starttls

TICK_SECONDS=30
BATCH_LIMIT=25
LOG_LEVEL=INFO
```

### `deploy/notificador/.env`

```
DB_ALIAS=desa                             # prod: (vacío)
POSTGRES_DB=aprentix_desa                 # prod: aprentix
POSTGRES_USER=aprentix
DB_PASS=…

# MISMAS claves que en prod si quieres reutilizar suscripciones
VAPID_PRIVATE_KEY=…
VAPID_PUBLIC_KEY=…
VAPID_SUBJECT=mailto:cccoboss12@gmail.com

TICK_SECONDS=300
BATCH_LIMIT=500
LOG_LEVEL=INFO
```

### `deploy/backups/.env`

```
DB_ALIAS=desa                                                 # prod: (vacío)
POSTGRES_DB=aprentix_desa                                     # prod: aprentix
POSTGRES_USER=aprentix
DB_PASS=…                                                      # la misma que core

# Carpeta DIFERENTE en Drive para no mezclar prod y desa
RESTIC_REPOSITORY=rclone:gdrive:aprentix_desa-backups          # prod: rclone:gdrive:aprentix-backups
RESTIC_PASSWORD=…                                              # sin ella no se puede restaurar
RESTIC_HOST=aprentix

KEEP_LAST=2
BACKUP_CRON=30 3 * * *
TZ=Europe/Madrid
```

El detalle de `rclone config` y la restauración están en
[`deploy/backups/README.md`](deploy/backups/README.md).

## Prerequisitos

- Dokploy (o Docker Compose 2.20+) sobre un host con Traefik +
  Let's Encrypt configurados.
- La red externa `dokploy-network` ya existe (la crea Dokploy).

## Orden de despliegue (primera vez)

1. **`deploy/core`** primero.  Al arrancar sobre BBDD vacía,
   `db/init/01_esquema.sql` se ejecuta y deja:
   - Usuario admin (`admin@aprentix.es` / `${ADMIN_PASS}`) verificado.
   - Catálogos de roles, permisos, retos y logros.
   - `config.app_url = "http://localhost"` — actualízalo:
     ```sql
     UPDATE config SET valor = '"https://desa.aprentix.es"'::jsonb
      WHERE clave = 'app_url';
     ```
     (los links del correo de verificación se construyen con
     `app_url()`).

   En prod: `COMPOSE_PROFILES=pgadmin` levanta también pgAdmin.

2. **`deploy/app`** — frontend en `${DOMINIO_LANDING}`, proxya
   `/api/*` a `postgrest-${DB_ALIAS}:3000` (Caddy lee
   `POSTGREST_UPSTREAM`).

3. **`deploy/mailer`** — worker SMTP.

4. **`deploy/notificador`** — worker Web Push.

## Dev local

```bash
cp .env.example .env
$EDITOR .env
docker compose up -d
```

El maestro (`include:`) fusiona los cuatro composes en un único
proyecto.  Todos leen del mismo `.env`.  Deja
`DB_ALIAS=desa` (o el que uses) y `COMPOSE_PROFILES=` vacío para no
levantar pgAdmin en local.

## Compartir el pgAdmin de producción para ver desa

Ya está.  `pgadmin/servers.json` trae dos entradas:

- `aprentix`      → `Host: db`,      `MaintenanceDB: aprentix`
- `aprentix-desa` → `Host: db-desa`, `MaintenanceDB: aprentix_desa`

Como pgAdmin y ambos `db` están en `dokploy-network`, la resolución
funciona directa.  Cuando desa aún no esté desplegado, la entrada
de desa aparecerá pero fallará al conectar hasta que el `db-desa`
exista — no bloquea nada.

## Importar la primera oposición

Login con `admin@aprentix.es`. Desde la consola del navegador:

```js
const payload = /* JSON con el shape de db/ejemplo_oposicion.json */;
AprentixSession.rpc('importar_oposicion', { p_payload: payload });
```

O por `curl`:

```bash
JWT=<pega_tu_token>
curl -X POST "https://${DOMINIO_API}/rpc/importar_oposicion" \
     -H "Authorization: Bearer $JWT" \
     -H "Content-Type: application/json" \
     -d @db/ejemplo_oposicion.json
```

Los temas se identifican por `slug`. Si el slug ya existe, el tema
se **reutiliza** — no se duplican unidades ni preguntas.

## Correo (SMTP)

El registro encola una fila en `cola_emails`. `deploy/mailer` la
vacía con las credenciales `SMTP_*`. Con Gmail hace falta una
**contraseña de aplicación**, no la de la cuenta.

Modo dev: `MAILER_DEV_LOG_ONLY=1` — el mailer no abre conexión SMTP
y sólo loguea el correo por stdout.  Útil para arrancar desa sin
tocar SMTP.

Comprobar la cola:

```sql
SELECT id, destinatario, asunto, enviado_en, ultimo_error
  FROM cola_emails ORDER BY encolado_en DESC LIMIT 20;
```

## Error de caché al registrar o iniciar sesión

Si la API responde `Could not find the function public.login_web(...) in the
schema cache` o el mismo error para `registrar_web`, no es un problema con el
orden de los argumentos. PostgREST resuelve los argumentos por nombre; el
mensaje enumera los nombres que recibió y puede mostrarlos en un orden distinto
al de la declaración SQL.

Cuando producción y desa comparten `dokploy-network`, no debe usarse el hostname
genérico `db`: los dos proyectos publican ese alias y Docker puede resolverlo al
contenedor del otro entorno. El Compose de core construye `PGRST_DB_URI` con el
alias inequívoco: `db` cuando `DB_ALIAS` está vacío, `db-desa` con
`DB_ALIAS=desa` y `db-prod` con `DB_ALIAS=prod`. Después de actualizar esta
configuración hay que redesplegar el stack **core** de ambos entornos, empezando
por desa.

En una instalación con datos existentes, `db/init/01_esquema.sql` **no vuelve a
ejecutarse** al redesplegar: la imagen oficial de PostgreSQL sólo procesa
`/docker-entrypoint-initdb.d` cuando inicializa un directorio de datos vacío.
Desde pgAdmin, selecciona primero la base indicada en `POSTGRES_DB` del mismo
entorno que atiende la web (producción o desa), abre
`db/migrations/02_recargar_funciones_autenticacion.sql` y ejecuta todo su
contenido en el *Query Tool*.

Después se puede verificar desde el exterior, usando el dominio API del mismo
entorno:

```bash
curl -i -X POST "https://${DOMINIO_API}/rpc/login_web" \
  -H 'Content-Type: application/json' \
  -d '{"p_email":"no-existe@example.com","p_password":"prueba123"}'
```

Una respuesta de la función como `credenciales_invalidas` confirma que
PostgREST ya la encontró. Si todavía aparece `PGRST202`, reinicia únicamente el
servicio `postgrest` y comprueba dentro del contenedor que `PGRST_DB_URI` sea
`postgres://autenticador@db-desa:5432/aprentix_desa` en desa y
`postgres://autenticador@db-prod:5432/aprentix` en producción si se ha definido
`DB_ALIAS=prod` (o que use `@db:` si el alias está vacío). La base debe coincidir
con la que se abrió en pgAdmin.

## Notificaciones Web Push

1. Genera el par VAPID (o reutiliza el de prod si prefieres compartir
   suscripciones):
   ```bash
   docker run --rm -v $PWD/notificador:/w -w /w python:3.12-slim \
     sh -c 'pip install py-vapid && python gen_vapid.py'
   ```
2. Pon la privada y la pública en `.env` del stack notificador.
3. Guarda también la pública en la BBDD:
   ```sql
   UPDATE config SET valor = '"<clave_publica>"'::jsonb
    WHERE clave = 'push_vapid_public';
   ```
4. Probar el circuito completo, ya logueado:
   ```sql
   SELECT push_enviar_prueba();
   ```

## Migrar esta rama a producción

Cuando esta rama esté validada y merges a `main`:

1. En Dokploy, cambia la rama de cada Compose Application a `main`.
2. Ajusta el `.env` de cada stack:
   - `DB_ALIAS=` (vacío) — mantiene los nombres actuales `db`,
     `postgrest`, `app` sin renombrar containers ni tocar el
     `pgadmin/servers.json`.
   - `POSTGRES_DB=aprentix`
   - `DOMINIO_LANDING=aprentix.es`, `DOMINIO_LANDING_ALT=www.aprentix.es`
   - `DOMINIO_API=api.aprentix.es`
   - En core: `COMPOSE_PROFILES=pgadmin`
   - Contraseñas, JWT_SECRET y VAPID de producción.
3. Redespliega los cuatro stacks.

No hay que cambiar YAMLs, ni Dockerfiles, ni SQL — sólo el `.env`.

## Qué queda para siguientes iteraciones

- **Motor real del plan de estudio**: la vista Plan hoy pinta
  bloques de muestra a partir de la unidad pendiente.
- **Editor visual** de oposiciones desde admin.  Ahora la carga es
  por RPC `importar_oposicion(payload)`.
- **Motor de retos**: incrementar `retos_usuario.progreso` dentro de
  `finalizar_intento()` según cada `codigo` del catálogo.
