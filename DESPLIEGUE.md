# Despliegue

El repo se despliega como **una sola** Compose Application
(`docker-compose.yml` al raíz).  Todas las variables viven en `.env`
y usan nombres neutros — nada de sufijos por entorno.  Cambiar de
dev a desa a prod es cambiar los valores.

## Servicios

Todos con `container_name` prefijado por `aprentix-` para no chocar
en `dokploy-network`:

| Servicio | Container | Puerto | Publicado en |
|---|---|---|---|
| `db`          | `aprentix-db`          | 5432 | red interna |
| `postgrest`   | `aprentix-postgrest`   | 3000 | `${DOMINIO_API}` |
| `app`         | `aprentix-app`         |   80 | `${DOMINIO_WEB}` |
| `mailer`      | `aprentix-mailer`      |    – | red interna |
| `notificador` | `aprentix-notificador` |    – | red interna |

Los cuatro workers/servicios cuelgan de la red externa
`dokploy-network`, que Traefik también usa. No hay pgAdmin en este
stack.

## Prerequisitos

1. Un Dokploy (o Docker Compose 2.20+) apuntando al repo.
2. La red externa `dokploy-network` ya existe (la crea Dokploy).
3. Traefik está delante con Let's Encrypt.

## Primera vez

```bash
cp .env.example .env
$EDITOR .env       # rellena DB_PASS, JWT_SECRET, SMTP_*, dominios, ...
docker compose up -d
```

Al primer arranque, el esquema `db/init/01_esquema.sql` se ejecuta
sobre una BBDD vacía y deja:

- El usuario admin (`admin@aprentix.es` / `${ADMIN_PASS}`), ya
  verificado.
- Los catálogos de roles, permisos, retos y logros.
- Una fila en `config` con `app_url = "http://localhost"` — cámbiala
  al dominio real:
  ```sql
  UPDATE config SET valor = '"https://desa.aprentix.es"'::jsonb
   WHERE clave = 'app_url';
  ```
  El correo de verificación usa `app_url()` para construir el enlace,
  así que si no lo actualizas los links irán a localhost.

## Importar la primera oposición

Login con `admin@aprentix.es`, luego desde la consola del navegador:

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

El registro encola en `cola_emails`. El worker `mailer` la vacía
enviando por SMTP (`SMTP_HOST`/`SMTP_PORT`/`SMTP_USER`/`SMTP_PASS`/
`SMTP_FROM`/`SMTP_TLS`). Para Gmail necesitas una **contraseña de
aplicación**, no la de la cuenta.

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
2. Pon la privada en `VAPID_PRIVATE_KEY` y la pública en
   `VAPID_PUBLIC_KEY` del `.env`.
3. Guarda también la pública en la BBDD (la SPA la lee al suscribirse):
   ```sql
   UPDATE config SET valor = '"<clave_publica>"'::jsonb
    WHERE clave = 'push_vapid_public';
   ```
4. Probar el circuito completo, ya logueado:
   ```sql
   SELECT push_enviar_prueba();  -- encola una notificación al usuario actual
   ```
   El worker `notificador` la despacha en el siguiente tick.

## Reutilizar un pgAdmin existente

Este stack **no** incluye pgAdmin. Si tienes un pgAdmin en otro
proyecto (por ejemplo, tu instalación de producción) y quieres
conectarte a esta BBDD:

1. Añade una entrada al `servers.json` de ese pgAdmin:
   ```json
   {
     "Name": "aprentix-desa",
     "Group": "Servers",
     "Host": "aprentix-db",
     "Port": 5432,
     "MaintenanceDB": "aprentix_desa",
     "Username": "aprentix",
     "SSLMode": "prefer"
   }
   ```
2. Redeploya el stack donde vive el pgAdmin para que recargue el JSON.

Como `aprentix-db` y el pgAdmin están ambos en `dokploy-network`, la
resolución de hostname funciona directamente.

## Qué queda para siguientes iteraciones

- **Motor real del plan de estudio**: hoy la vista Plan pinta bloques
  de muestra a partir de la unidad pendiente. La tabla
  `plan_sesiones` ya existe para persistir el calendario diario que
  genere el motor.
- **Editor visual** de oposiciones desde admin.  Ahora la carga es
  por RPC `importar_oposicion(payload)`.
- **Motor de retos**: incrementar `retos_usuario.progreso` dentro de
  `finalizar_intento()` según cada `codigo` del catálogo.
