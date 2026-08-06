# Despliegue

El repo se organiza en **cuatro stacks** independientes bajo
`deploy/`, para que cada uno sea una Compose Application separada en
Dokploy con su propio `.env` — así puedes redesplegar sólo el
frontend, o sólo el mailer, sin tocar la BBDD.

Todos los nombres de variable son los mismos en cualquier entorno;
sólo cambia el valor.  Cuando esta rama se merge a `main` para
producción, redesplegar es literalmente cambiar el `.env` de cada
stack.

## Stacks

| Carpeta | Contenido | Publica | Redespliega cuando cambian… |
|---|---|---|---|
| `deploy/core/`        | db + postgrest             | `${DOMINIO_API}` | `db/init/01_esquema.sql`, versión de PostgREST |
| `deploy/app/`         | Caddy + SPA (build)        | `${DOMINIO_WEB}` | `web/*`, `deploy/app/Caddyfile`, `deploy/app/Dockerfile` |
| `deploy/mailer/`      | worker SMTP                | –                | `mailer/*` |
| `deploy/notificador/` | worker Web Push            | –                | `notificador/*` |

Los cuatro comparten la red externa `dokploy-network` — Traefik ve
`postgrest` y `app`, y los workers hablan con `db` por nombre.

## Prerequisitos

- Dokploy (o Docker Compose 2.20+) sobre un host con Traefik +
  Let's Encrypt configurados.
- La red externa `dokploy-network` ya existe (la crea Dokploy).

## Orden de despliegue (primera vez)

1. **`deploy/core`** primero (`db` y `postgrest`).  Al arrancar sobre
   una BBDD vacía, `db/init/01_esquema.sql` se ejecuta entero y deja:
   - Usuario admin (`admin@aprentix.es` / `${ADMIN_PASS}`) ya verificado.
   - Catálogos de roles, permisos, retos y logros.
   - Fila `config.app_url = "http://localhost"` — actualízala al
     dominio real:
     ```sql
     UPDATE config SET valor = '"https://desa.aprentix.es"'::jsonb
      WHERE clave = 'app_url';
     ```
     El correo de verificación usa `app_url()` para construir el
     enlace: sin esto, los links irán a localhost.

2. **`deploy/app`** — el frontend.  Sirve en `${DOMINIO_WEB}` y
   proxya `/api/*` a `postgrest:3000`.

3. **`deploy/mailer`** — worker SMTP.  Sin él, los registros se
   encolan pero nadie envía el correo de verificación.

4. **`deploy/notificador`** — worker Web Push (opcional al arrancar).

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
mismo `.env` (superset).

## Actualizar solo un stack

En Dokploy, redespliega la Compose Application correspondiente:

- Cambio de frontend → redespliega `deploy/app`.
- Cambio de esquema BBDD → redespliega `deploy/core` (o aplica el
  `ALTER` a mano desde pgAdmin).
- Nueva plantilla de email → redespliega `deploy/mailer`.

## Importar la primera oposición

Login con `admin@aprentix.es`.  Desde la consola del navegador:

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
se **reutiliza** — no se duplican sus unidades ni preguntas.

## Correo (SMTP)

El registro encola una fila en `cola_emails`.  `deploy/mailer` la
vacía enviando por SMTP con las variables `SMTP_*`.  Para Gmail
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

## Reutilizar un pgAdmin existente

Este stack no incluye pgAdmin.  Si tienes uno en otro proyecto,
añade una entrada a su `servers.json` con `Host: db` y
`MaintenanceDB: <DB_NAME>`, y redespliegua el pgAdmin.

Como el pgAdmin y la BBDD están ambos en `dokploy-network`, la
resolución de hostname funciona directamente — igual que en el
stack de producción.

Nota: si ya tienes otro `db` en la red compartida (por ejemplo, un
prod corriendo en paralelo), habrá colisión de alias en
`dokploy-network`.  Cuando esta rama sustituya a la de prod la
colisión desaparece; para coexistir temporalmente, la solución es
añadir `container_name: aprentix-desa-db` (y usar ese nombre desde
`postgrest`, `mailer`, `notificador` y pgAdmin).

## Migración de la rama a producción

Cuando esta rama esté validada en desa y merges a `main`:

1. En Dokploy, cambia la rama de cada Compose Application a `main`.
2. Ajusta los valores del `.env` de cada stack:
   - `DB_NAME=aprentix` (no `aprentix_desa`)
   - `DOMINIO_WEB=aprentix.es`, `DOMINIO_API=api.aprentix.es`
   - Contraseñas y VAPID de producción.
3. Redespliega los cuatro stacks.

No hay que cambiar YAMLs, ni Dockerfiles, ni SQL.  Todo lo que
diferencia dev / desa / prod está en el `.env`.

## Qué queda para siguientes iteraciones

- **Motor real del plan de estudio**: hoy la vista Plan pinta bloques
  de muestra a partir de la unidad pendiente.  La tabla
  `plan_sesiones` ya existe para persistir el calendario diario que
  genere el motor.
- **Editor visual** de oposiciones desde admin.  Ahora la carga es
  por RPC `importar_oposicion(payload)`.
- **Motor de retos**: incrementar `retos_usuario.progreso` dentro de
  `finalizar_intento()` según cada `codigo` del catálogo.
