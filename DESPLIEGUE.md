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
DOMINIO_LANDING=desa.aprentix.es          # prod: aprentix.es; enlaces de correo

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
   - La URL de los enlaces de confirmación se toma de
     `DOMINIO_LANDING` en el stack core. Para una instalación anterior con
     volumen persistente, ejecuta primero
     `db/migrations/03_configurar_url_publica.sql` y redespliega core.
   - `config.app_url = "http://localhost"` queda como respaldo. Si necesitas
     modificarlo manualmente:
     ```sql
     UPDATE config SET valor = '"https://desa.aprentix.es"'::jsonb
      WHERE clave = 'app_url';
     ```
     (los enlaces del correo se construyen con `app_url()`, que prioriza el
     dominio configurado en PostgreSQL sobre este valor de respaldo).

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

El usuario administrador inicial es `admin@aprentix.es` y su contraseña es el
valor configurado en `ADMIN_PASS` al crear la base de datos. Tras iniciar sesión,
pulsa **Añadir la primera oposición** y pega el contenido JSON en la pantalla de
administración.

También se puede importar desde la consola del navegador:

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

## Estado de las funcionalidades

### Editor visual + cron automático (nuevo) ✅

- **Editor visual de oposiciones** en `#/editar/<uuid>`:
  - Navegación jerárquica **Oposición → Temas → Unidades → Preguntas**
    con migas de pan.
  - Añadir/quitar/reordenar temas de la oposición (los datos del tema
    no se borran, sólo la vinculación).
  - CRUD de unidades con editor de teoría en Markdown, orden,
    minutos estimados, resumen, slug.
  - CRUD de preguntas con opciones (radio para marcar la correcta,
    borrar por opción, +2 mínimo), explicación y dificultad 1-5.
  - Acceso desde `#/admin` → listado de oposiciones (el nombre es
    enlace al editor).
  - RPCs nuevas: `admin_temas_de_oposicion`, `admin_upsert_tema`,
    `admin_desvincular_tema`, `admin_reordenar_temas`,
    `admin_unidades_de_tema`, `admin_upsert_unidad`,
    `admin_borrar_unidad`, `admin_preguntas_de_unidad`,
    `admin_upsert_pregunta`, `admin_borrar_pregunta`.

- **Cron interno en el notificador**: extiende `notificador.py` para
  no depender de un cron externo:
  - Cada `ENCOLAR_MINUTOS` (default 15) llama a
    `encolar_notificaciones_diarias()`.
  - Los lunes a `CRON_SEMANAL_HORA` UTC (default 3) llama a
    `cron_semanal()` (calcula métricas + ajusta carga para TODOS los
    usuarios activos).
  - `encolar_notificaciones_diarias` mantiene mensajes genéricos
    (recordatorio si lleva >24 h sin sesión + resumen dominical),
    con el filtro anti-ruido de no encolar si ya hay push pendiente
    en las últimas 20 h.

### Planificador v2 (nuevo) ✅

- **Fecha del examen** por oposición (día exacto o mes/año
  orientativo). Editable desde admin (`admin_editar_oposicion`).
  El motor la usa para dimensionar el horizonte del plan.
- **Motor autónomo** `recalcular_plan_hasta_examen`: distribuye
  todas las unidades pendientes + repasos vencidos desde HOY hasta
  la fecha del examen respetando `horas_por_dia`. Cada bloque
  recibe `orden_global` para saber cuál toca a continuación.
- **Flujo diario**: botón "Estudiar" en Home
  - Si hay plan de hoy → entra directamente en el siguiente bloque
    pendiente (sin preguntarle nada al usuario).
  - Si no hay plan → abre el modal "¿Cuánto tiempo tienes?" clásico.
- **Auto-avance**: al terminar un bloque, `registrar_bloque_completado`
  devuelve el siguiente y el modo estudio encadena.
- **"Hoy tengo otro tiempo"** en la vista Plan → modal con opciones
  rápidas (0, 15, 30, 60, 120, 180+ min) → `cambiar_disponibilidad_hoy`
  ajusta hoy y **recalcula toda la semana** sin superar los
  límites configurados.
- **Reprogramación silenciosa de días perdidos** al abrir la app:
  `reprogramar_dia_perdido` mete lo no completado en la cola de los
  próximos días sin superar la disponibilidad máxima.
- **Aprendizaje automático**: los lunes al primer login del día,
  la SPA muestra la sugerencia semanal en horas por día
  (`sugerir_plan_semanal`) basada en las últimas 4 semanas de
  `sesiones_estudio`. El usuario acepta o ajusta y se guarda.
- **Recuperación de contraseña**: enlace "¿Olvidaste?" en el
  login → `solicitar_reset` envía correo → `/#/reset?token=…` la
  cambia con `aplicar_reset`.
- **Preguntas en el bloque de repaso** del modo estudio
  (renderizado inline + `registrar_respuesta_espaciada`).

### Sistema adaptativo (nuevo) ✅

- **Modo Estudio**: botón "Estudiar" en Home → modal "¿Cuánto tiempo tienes?"
  (horas + minutos, chips 25/45/60/90/120, selector de sistema) →
  vista fullscreen con **cronómetro grande**, bloque actual (teoría,
  repaso, descanso), botón "Saltar descanso" en descansos, avance
  automático al llegar a 00:00.
- **Sistemas de estudio** contrastados semillados:
  Pomodoro clásico (25/5), Pomodoro largo (50/10), Ultradiano (90/20),
  Bloques de 45, Sprints cortos (15/3).  Cada uno define
  ciclos hasta descanso largo.
- **Repetición espaciada SM-2 simplificado**:
  - Al acertar: intervalos 1, 3, 7 días, luego `intervalo × ease_factor`
    (ease entre 1.3 y 3.0; sube 0.1 con acierto, baja 0.2 con fallo).
  - Al fallar: intervalo=0 → repaso mismo día (y otra vez al día
    siguiente si vuelve a fallar).
  - RPCs: `registrar_respuesta_espaciada(pregunta, correcta)`,
    `siguientes_repasos(N)`.
- **Métricas semanales** (`calcular_metricas_semanales`):
  minutos estudiados vs planificados, precisión media, **fatiga
  cognitiva** (Δ precisión entre 1ª y 2ª mitad de la sesión), días
  activos, % objetivos cumplidos, tema foco (peor rendimiento).
- **Ajuste de carga automático** (`ajustar_carga_semanal`):
  <50% cumplido → carga −20%; >90% → +15%; regenera plan.
- **Resumen semanal** (`resumen_semanal`) — se ejecuta la primera vez
  que abre la Home cada semana y muestra banner con mensaje motivador
  (nunca deprimente).
- **Notificaciones automáticas** (`encolar_notificaciones_diarias`):
  inactivos >24 h → recordatorio; domingos → resumen + objetivos.
  Se llama desde un cron externo o manualmente desde pgAdmin.

### Listas ✅
- Registro con verificación por email (SMTP configurable).
- Login por email, JWT de PostgREST.
- Onboarding + wizard de disponibilidad (semanal / detalle por día).
- Motor básico de generación de plan (14 días).
- Reprogramar plan (marca las sesiones no cumplidas y regenera).
- Vista de unidad **unificada** (teoría + CTA test): sin pestañas.
- **Auto-tracking** del tiempo de estudio (Page Visibility API).
  `teoria_completada` se marca sola al llegar al 80% del tiempo
  estimado.
- Test rápido dentro de la unidad (10 preguntas).
- Estadísticas: racha, tiempo semanal, precisión, anillo de
  progreso, chart de barras, rendimiento por tema.
- Perfil con XP / nivel / logros y toggle de tema.
- Admin: listado de usuarios, activar/desactivar, verificar email
  manual, hacer/quitar admin, contadores de cola email/push.
- pgAdmin único (prod) compartido para ambas BBDD.
- Backups nocturnos con restic + rclone → Google Drive.

### En beta / muy básico 🌱
- **Motor de plan**: reparte unidades en bloques de 25/45 min por
  las horas disponibles, sin heurística de dificultad ni de
  repasos espaciados.  Suficiente para dar una lista de tareas
  realista, pero no óptimo.
- **Retos**: catálogo semillado pero el motor que incrementa
  `retos_usuario.progreso` tras `finalizar_intento()` aún no está
  hecho.  Los retos se ven "estáticos" en la SPA.
- **Simulacros**: la tabla y el tipo existen (`tipo='simulacro'`
  en intentos), pero no hay generador de "N preguntas al azar de
  toda la oposición" ni cronómetro dedicado.
- **Web Push**: infraestructura completa (cola_push, worker,
  VAPID), pero la SPA aún NO tiene botón "Activar notificaciones"
  que llame a `pushManager.subscribe`.  Vale usar
  `SELECT push_enviar_prueba()` desde pgAdmin para probar el
  circuito una vez suscrito.

### Cron sugerido (opcional)

Para que las notificaciones de recordatorio funcionen automáticamente,
programa esto cada día a las 9:00 y 20:00 (o desde un `cron` externo):

```sql
SELECT encolar_notificaciones_diarias();
```

Y esto los lunes al calcular la semana anterior + ajustar carga:

```sql
SELECT calcular_metricas_semanales();
SELECT ajustar_carga_semanal();
```

Puedes lanzarlas con `pg_cron`, o desde el propio worker
`notificador` extendiéndolo, o desde un job de Dokploy.

### PWA offline — alcance previsto (sin implementar)

Con el modo planificador nuevo, el service worker que **podría**
añadirse aportaría un valor real limitado y bien definido. Lo que
tendría sentido offline:

| Función | Offline razonable | Por qué |
|---|---|---|
| Abrir la app instalada | ✅ | Cache básica del shell (HTML/CSS/JS/logo). |
| Ver **teoría** ya visitada | ✅ | Cachear las respuestas JSON de `obtener_unidad`. Poco peso, mucha utilidad si el usuario estudia en el metro. |
| Continuar un **bloque de teoría** iniciado online | ✅ | La lectura es local; el auto-tracking se encola y se envía al recuperar red (Background Sync). |
| Terminar un bloque y avanzar al siguiente | ⚠️ Parcial | `registrar_bloque_completado` requiere red para reordenar. Se encolaría con Background Sync y al reconectar se aplica. |
| Test rápido de una unidad cacheada | ⚠️ Parcial | Preguntas cacheables; `responder_pregunta` se encola. |
| Repaso SM-2 | ❌ | Necesita ver `siguiente_repaso`, que puede haber cambiado. Correcto sólo online. |
| Login / registro / verificación | ❌ | Requieren red obligatoriamente. |
| Importar oposición JSON | ❌ | Admin online. |
| Recalcular plan / cambio de disponibilidad | ❌ | Motor SQL — online. |
| Estadísticas / dashboard | ❌ | Cálculos en BBDD — online. |

Estrategia recomendada cuando se aborde:

- **Precache** del shell: `index.html`, `tokens.css`, `style.css`,
  `app.js`, `session.js`, `logo.svg`, iconos PWA.
- **Runtime cache** stale-while-revalidate para `/api/rpc/obtener_unidad`,
  `/api/rpc/obtener_tema`, `/api/oposiciones`, `/api/preguntas`.
- **Background Sync** para POSTs pendientes (`sesion_tick`,
  `sesion_cerrar`, `registrar_bloque_completado`,
  `responder_pregunta`, `registrar_respuesta_espaciada`).
- Fallback offline con la última página cacheada + toast
  "trabajando sin conexión, sincronizaremos cuando vuelvas".

Coste técnico estimado: 1-2 días bien hechos.

### Sin implementar aún 🚧
- **Simulacro mensual automático**: RPCs de intento con
  `tipo='simulacro'` ya existen; falta un generador que coja N
  preguntas al azar de toda la oposición con cronómetro y baremo.
- **Recuperación de contraseña** (`reset_password` como tipo de
  `email_tokens` ya existe, pero la RPC y la UI no).
- **Sesiones multi-dispositivo / revocación de tokens.**
- **Estadísticas por unidad/tema** con desglose de tiempo y
  respuestas correctas.
- **Recordatorios push programados** por franjas horarias del
  usuario.
- **Import/export CSV** de preguntas.
- **PWA offline real** (service worker).  Está el manifest pero
  sin worker registrado.
- **Métricas de admin en tiempo real** (websocket o polling
  automático).

### Historial de la BBDD
- El esquema es **idempotente**: usa `IF NOT EXISTS`, `CREATE OR
  REPLACE`, `DROP POLICY IF EXISTS` + `CREATE POLICY`, y
  `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` para migrar tablas
  existentes.  Se puede relanzar sobre una BBDD parcialmente
  inicializada sin borrar el volumen.
- `NOTIFY pgrst, 'reload schema';` al final del init — no hace
  falta reiniciar PostgREST tras redesplegar.
