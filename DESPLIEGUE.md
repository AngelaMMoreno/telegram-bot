# Despliegue

Cuatro stacks independientes bajo `deploy/`, cada uno con SU PROPIO
`.env`.  Los nombres de variable son los mismos en cualquier entorno
— sólo cambia el valor.

Dos despliegues del mismo repo pueden coexistir en el mismo host
Dokploy (por ejemplo `prod` + `desa`) sin colisionar en
`dokploy-network`, usando la variable **`STACK_SUFFIX`**.

## Stacks

| Carpeta | Contenido | Publica | Redespliega cuando cambian… |
|---|---|---|---|
| `deploy/core/`        | db + postgrest     | `${DOMINIO_API}` | `db/init/01_esquema.sql`, versión de PostgREST |
| `deploy/app/`         | Caddy + SPA        | `${DOMINIO_WEB}` | `web/*`, `deploy/app/Caddyfile`, `deploy/app/Dockerfile` |
| `deploy/mailer/`      | worker SMTP        | –                | `mailer/*` |
| `deploy/notificador/` | worker Web Push    | –                | `notificador/*` |

## Coexistencia desa + prod (STACK_SUFFIX)

`STACK_SUFFIX` se propaga a cuatro sitios:

1. `container_name` (nombre real del contenedor en el daemon).
2. Alias explícito en `dokploy-network` (para que otros stacks y
   pgAdmin resuelvan el hostname correcto).
3. Nombres de routers/services de Traefik (deben ser únicos
   globalmente).
4. Hostnames que los otros stacks usan para conectar
   (`postgrest${STACK_SUFFIX}`, `db${STACK_SUFFIX}`).

Regla: **el mismo valor en los 4 `.env` de un mismo entorno**.

| | `STACK_SUFFIX` | container | alias en `dokploy-network` |
|---|---|---|---|
| Producción | *(vacío)* | `db`, `postgrest`, `app`, `mailer`, `notificador` | `db`, `postgrest`, ... |
| Desarrollo | `-desa`   | `db-desa`, `postgrest-desa`, `app-desa`, `mailer-desa`, `notificador-desa` | `db-desa`, `postgrest-desa`, ... |

En cada Compose Application de Dokploy, `.env` de `deploy/<stack>/`
lleva `STACK_SUFFIX=-desa` para el despliegue de desa, y vacío para
prod.  Los YAMLs no cambian.

## Valores por entorno (resumen)

**Producción** (rama `main` cuando esta llegue allí):

```
STACK_SUFFIX=
DB_NAME=aprentix
DOMINIO_WEB=aprentix.es
DOMINIO_API=api.aprentix.es
```

**Desa** (rama `claude/redesign-oposiciones-9bdwaq`):

```
STACK_SUFFIX=-desa
DB_NAME=aprentix_desa
DOMINIO_WEB=desa.aprentix.es
DOMINIO_API=api.desa.aprentix.es
```

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

2. **`deploy/app`** — frontend.  Sirve en `${DOMINIO_WEB}` y proxya
   `/api/*` a `postgrest${STACK_SUFFIX}:3000` (Caddy lo lee de
   `POSTGREST_UPSTREAM`).

3. **`deploy/mailer`** — worker SMTP.

4. **`deploy/notificador`** — worker Web Push.

Cada stack lee su propio `.env`.  Copia el `.env.example` de cada
carpeta y ajusta valores.

## Dev local

```bash
cp .env.example .env
$EDITOR .env
docker compose up -d
```

El `docker-compose.yml` del raíz usa `include:` para fusionar los
cuatro stacks en un único proyecto Docker Compose.  Todos leen del
mismo `.env` (superset).  Deja `STACK_SUFFIX=` vacío en local.

## Reutilizar el pgAdmin de producción para ver desa

Añade una entrada al `servers.json` del pgAdmin existente y
redespliega ese stack.  Como el pgAdmin y `db-desa` están ambos en
`dokploy-network`, la resolución del hostname `db-desa` funciona
directamente:

```json
{
  "Servers": {
    "1": {
      "Name": "aprentix",
      "Group": "Servers",
      "Host": "db",
      "Port": 5432,
      "MaintenanceDB": "aprentix",
      "Username": "aprentix",
      "SSLMode": "prefer",
      "Comment": "Producción"
    },
    "2": {
      "Name": "aprentix-desa",
      "Group": "Servers",
      "Host": "db-desa",
      "Port": 5432,
      "MaintenanceDB": "aprentix_desa",
      "Username": "aprentix",
      "SSLMode": "prefer",
      "Comment": "Entorno de desarrollo (misma pgAdmin, otra BBDD)"
    }
  }
}
```

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

Los temas se identifican por `slug`. Si el slug ya existe, el tema se
**reutiliza** — no se duplican sus unidades ni preguntas.

## Correo (SMTP)

El registro encola una fila en `cola_emails`.  `deploy/mailer` la
vacía enviando por SMTP con las variables `SMTP_*`.  Con Gmail
necesitas una **contraseña de aplicación**, no la de la cuenta.

Comprobar la cola:

```sql
SELECT id, destinatario, asunto, enviado_en, ultimo_error
  FROM cola_emails ORDER BY encolado_en DESC LIMIT 20;
```

## Notificaciones Web Push

1. Genera el par VAPID una única vez:
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
   El worker despacha en el siguiente tick.

## Migrar esta rama a producción

Cuando esta rama esté validada en desa y merges a `main`:

1. En Dokploy, cambia la rama de cada Compose Application a `main`.
2. Ajusta el `.env` de cada stack:
   - `STACK_SUFFIX=` (vacío — vuelve al naming de prod)
   - `DB_NAME=aprentix`
   - `DOMINIO_WEB=aprentix.es`, `DOMINIO_API=api.aprentix.es`
   - Contraseñas y VAPID de producción.
3. Redespliega los cuatro stacks.

No hay que cambiar YAMLs, ni Dockerfiles, ni SQL — sólo el `.env`.

## Qué queda para siguientes iteraciones

- **Motor real del plan de estudio**: la vista Plan hoy pinta
  bloques de muestra a partir de la unidad pendiente.  La tabla
  `plan_sesiones` ya existe para persistir el calendario diario que
  genere el motor.
- **Editor visual** de oposiciones desde admin.  Ahora la carga es
  por RPC `importar_oposicion(payload)`.
- **Motor de retos**: incrementar `retos_usuario.progreso` dentro de
  `finalizar_intento()` según cada `codigo` del catálogo.
