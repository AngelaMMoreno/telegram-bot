# Aprentix — Especificaciones del proyecto

**Aprentix** es una plataforma web para preparar oposiciones al servicio público
español. Combina un catálogo estructurado de contenido (oposiciones → temas →
unidades → preguntas), un planificador adaptativo por usuario y un motor de
estudio con cronómetro que orquesta bloques de teoría, repaso y descanso.

Este documento describe el sistema tal como está en la rama
`claude/redesign-oposiciones-9bdwaq`. Cubre arquitectura, modelo de datos, APIs,
SPA, sistema adaptativo, despliegue y estado de features.

---

## 1. Visión y principios

| Principio                             | Cómo se aplica                                                                 |
|---------------------------------------|--------------------------------------------------------------------------------|
| El contenido vive en la BBDD          | Nada de ficheros MD en disco: `unidades.teoria_md` guarda el temario.          |
| Reutilización de temas                | Los temas son un catálogo global (m:n con `oposicion_temas`), no duplicados.   |
| Auto-tracking del progreso            | El tiempo estudiado se acumula sin que el usuario tenga que "marcar hecho".    |
| Un solo botón "Estudiar"              | La app decide qué toca; el usuario no elige unidad/manera.                      |
| Nunca deprimir al usuario             | Los mensajes semanales celebran el progreso; nada de reproche.                 |
| Idempotencia SQL                      | Todo el `01_esquema.sql` puede re-lanzarse sin borrar datos.                    |
| Deploy separado por stack             | Cada carpeta bajo `deploy/` es una Compose Application redesplegable aislada.  |
| Coexistencia prod + desa              | `DB_ALIAS` permite dos entornos en el mismo Dokploy sin colisiones.            |

---

## 2. Arquitectura de alto nivel

```
              ┌──────────────────────────────────────────────────────┐
              │                     dokploy-network                  │
              │  ┌─────────┐  ┌────────────┐  ┌─────────┐            │
   Internet ──┼──│ Traefik │──│  app-desa  │  │ pgadmin │            │
              │  └─────────┘  │   (Caddy)  │  └────┬────┘            │
              │       │       └────────────┘       │                 │
              │       │              │             │                 │
              │       │              │  /api/*     │                 │
              │       │              ▼             │                 │
              │       │       ┌─────────────┐      │                 │
              │       └───────│ postgrest   │      │                 │
              │               │   -desa     │      │                 │
              │               └──────┬──────┘      │                 │
              └──────────────────────┼─────────────┼─────────────────┘
                                     │             │
              ┌──────────────────────┼─────────────┼─────────────────┐
              │                     db-net-desa   (privada)          │
              │                      │             │                 │
              │              ┌───────▼─────────────▼───────┐         │
              │              │      Postgres 16 (db-desa)  │         │
              │              │  BBDD: aprentix_desa        │         │
              │              └───┬──────────────┬──────────┘         │
              │                  │              │                    │
              │        ┌─────────▼──────┐  ┌────▼───────┐            │
              │        │ mailer-desa    │  │ notifica-  │            │
              │        │ (SMTP)         │  │ dor-desa   │            │
              │        └────────────────┘  └────────────┘            │
              │                  ┌────────▼────────┐                 │
              │                  │  backups-desa   │  → GDrive       │
              │                  └─────────────────┘                 │
              └──────────────────────────────────────────────────────┘
```

Cada entorno (`prod`, `desa`) reproduce la topología entera. La red pública
`dokploy-network` sólo lleva HTTP (Traefik + SPA + PostgREST + pgAdmin). La
BBDD y los workers viven en `db-net-<alias>`, una red privada por entorno.

---

## 3. Stack técnico

| Capa       | Componente                        | Notas                                                     |
|------------|-----------------------------------|-----------------------------------------------------------|
| BBDD       | PostgreSQL 16                     | Sólo pgcrypto y pg_trgm; sin pgjwt ni extensiones exóticas.|
| API        | PostgREST 12.2.3                  | JWT HS256 firmado por pgcrypto en `login_web`.            |
| Frontend   | SPA vanilla ES2020                | Router hash-based, sin bundler ni framework.              |
| Servidor web | Caddy 2 (imagen propia)         | Sirve `web/` y proxya `/api/*` a `postgrest-<alias>:3000`.|
| Workers    | Python 3.12 (psycopg 3)           | `mailer` (SMTP) y `notificador` (Web Push + cron interno).|
| Backups    | restic + rclone → Google Drive    | Snapshot diario del dump SQL.                             |
| Orquestación | Docker Compose 2.20+ / Dokploy  | `include:` fusiona los 4 stacks en `docker-compose.yml`.  |
| Reverse proxy | Traefik v3.5 + Let's Encrypt   | Routers con sufijo `${DB_ALIAS:+-${DB_ALIAS}}` únicos.    |
| Notificaciones | Web Push (VAPID)               | `cola_push` + worker con librería `pywebpush`.            |
| Email      | SMTP (Gmail app password u otro)  | STARTTLS 587 por defecto; `MAILER_DEV_LOG_ONLY=1` para dev.|

---

## 4. Modelo de datos

El esquema completo está en `db/init/01_esquema.sql` (~3500 líneas). Aquí una
vista agrupada por dominio.

### 4.1 Identidad y roles

- **`usuarios`** — email, nombre, password_hash (bcrypt cost 12), verificación, activo.
- **`roles_catalogo`** — `admin`, `usuario`.
- **`permisos_catalogo`** — `oposicion.gestionar`, `usuario.gestionar`...
- **`rol_permisos`** — m:n rol ↔ permiso.
- **`usuario_roles`** — asignación de roles a usuarios.
- **`email_tokens`** — verificación de email, reset de contraseña.

### 4.2 Catálogo de contenido

- **`oposiciones`** — id, slug, nombre, organismo, descripción,
  `fecha_examen date`, `fecha_examen_orientativa boolean`.
- **`temas`** — id, slug, nombre, icono, descripción. **Catálogo global**.
- **`oposicion_temas`** — m:n oposición ↔ tema, con `orden`. Un tema puede estar en
  varias oposiciones.
- **`unidades`** — pertenecen a UN tema (belongs-to). Cada unidad tiene
  `teoria_md text`, `minutos_est int`, `orden`, `resumen`, `slug`.
- **`preguntas`** — pertenecen a una unidad. `enunciado`, `opciones jsonb`
  (`[{texto, correcta}]`), `explicacion`, `dificultad 1-5`.

### 4.3 Actividad del usuario

- **`usuario_oposiciones`** — m:n user ↔ oposición, con `principal` (la activa).
- **`intentos`** — cabecera de un test/simulacro (`tipo`, `iniciado_en`, `finalizado_en`).
- **`respuestas`** — filas por pregunta respondida en un intento.
- **`progreso_unidad`** — por (usuario, unidad): `teoria_completada`, `teoria_vista_en`, `mejor_nota`.
- **`sesiones_estudio`** — auto-tracking (Page Visibility API). Una fila por sesión abierta con `unidad_id`, `iniciada_en`, `cerrada_en`, `ultima_actividad`, `segundos_activos`.

### 4.4 Planificación

- **`plan_estudio`** — un plan por (user, oposición). Modo (`semanal`/`diario`),
  `horas_semana`, `horas_por_dia jsonb`, `fecha_examen`, `ritmo`, `metodo`,
  `sistema_estudio_id`.
- **`plan_sesiones`** — un bloque planificado por día (`fecha`, `hora_inicio`,
  `minutos`, `unidad_id`, `tipo`, `completada`, `completada_en`, `orden_global`).

### 4.5 Sistema adaptativo

- **`sistemas_estudio`** — Pomodoro, Ultradiano, Bloques 45, Sprints…
  Cada uno define `min_estudio`, `min_descanso_corto`, `min_descanso_largo`,
  `ciclos_hasta_descanso_largo`.
- **`sesion_activa`** — el estado de la sesión en curso: `plan_bloques jsonb`,
  `bloque_idx`, `iniciada_en`, `bloque_iniciado`, `minutos_totales`, `sistema_id`.
- **`repasos_pregunta`** — SM-2 por (user, pregunta): `intervalo`, `ease_factor`,
  `aciertos_seguidos`, `proxima_revision`.
- **`metricas_semanales`** — snapshot semanal por usuario: minutos, precisión,
  fatiga (Δ precisión 1ª mitad vs 2ª), consistencia, foco.

### 4.6 Comunicación

- **`cola_emails`** — encolado por `registrar_web`, `solicitar_reset`. Worker `mailer` la vacía.
- **`push_suscripciones`** — endpoints + p256dh + auth por usuario.
- **`cola_push`** — encolada por `encolar_notificaciones_diarias`. Worker `notificador` la envía.

### 4.7 Gamificación

- **`retos_catalogo`** / **`retos_usuario`** — retos diarios/semanales/mensuales.
- **`logros_catalogo`** / **`logros_usuario`** — logros con `codigo`, `titulo`, `icono`.
- **`usuario_gamificacion`** — `xp_total`, `nivel_snapshot`, `racha_actual`, `ultimo_dia_activo`.

### 4.8 Configuración

- **`config`** — clave/valor JSONB (`app_url`, `push_vapid_public`).

### 4.9 Seguridad — RLS

Cada tabla con datos de usuario tiene RLS activo:

- Políticas del tipo `usuario_id = jwt_usuario_id() OR es_admin()`.
- El rol `web_anon` (sin JWT) sólo llega a lectura de catálogos activos y a
  las RPCs de auth (`login_web`, `registrar_web`, `verificar_email`,
  `reenviar_verificacion`, `push_config_publica`).
- El rol `web_user` (con JWT) llega a todo lo demás vía RLS.
- Un `DO $grant_exec$` al final del schema hace `GRANT EXECUTE` automático de
  todas las funciones `public.*` a `web_user`, así una función nueva no
  necesita recordar el GRANT.

---

## 5. API (RPCs)

Todas expuestas por PostgREST bajo `/api/rpc/<nombre>`. JWT en `Authorization:
Bearer` para las que requieran identidad. Devuelven JSON.

### 5.1 Autenticación

| RPC                    | Descripción                                                  |
|------------------------|--------------------------------------------------------------|
| `registrar_web`        | Alta con email + password + nombre. Encola verificación.     |
| `verificar_email`      | Consume el token y activa la cuenta.                         |
| `reenviar_verificacion`| Vuelve a encolar el correo (rate-limited por `email_tokens`).|
| `login_web`            | Devuelve `{token, ...}` si credenciales OK y email verificado.|
| `solicitar_reset`      | Encola un correo con enlace de reset.                        |
| `aplicar_reset`        | Consume el token y cambia la contraseña. Loguea al usuario.  |
| `mi_sesion`            | Devuelve `{user_id, email, nombre, es_admin, roles, principal}`. |

### 5.2 Contenido

| RPC                       | Descripción                                                     |
|---------------------------|-----------------------------------------------------------------|
| `importar_oposicion`      | Payload JSON completo (oposición + temas + unidades + preguntas). Reutiliza por slug. |
| `listar_oposiciones`      | Catálogo público de oposiciones activas.                        |
| `obtener_oposicion`       | Detalle con `fecha_examen`, `fecha_examen_orientativa`, temas y **unidades**. |
| `obtener_tema`            | Detalle del tema con sus unidades.                              |
| `obtener_unidad`          | Detalle con `teoria_md` y `progreso` del usuario.               |
| `matricular_oposicion`    | Alta en `usuario_oposiciones`. Con `p_principal=true` cambia la activa. |
| `mis_oposiciones`         | Devuelve las matriculadas del usuario.                          |

### 5.3 Motor de tests

| RPC                    | Descripción                                                  |
|------------------------|--------------------------------------------------------------|
| `iniciar_test_unidad`  | Devuelve `{intento_id, preguntas: [{id, enunciado, opciones}]}`. |
| `responder_pregunta`   | Registra respuesta; devuelve corrección + explicación.       |
| `finalizar_intento`    | Cierra el intento y calcula nota media.                      |
| `marcar_teoria`        | Marca teoría vista de una unidad (fallback manual).          |

### 5.4 Auto-tracking del estudio

| RPC                          | Descripción                                          |
|------------------------------|------------------------------------------------------|
| `sesion_abrir`               | Abre una sesión de estudio para una unidad.          |
| `sesion_tick`                | Suma segundos visibles (Page Visibility API).        |
| `sesion_cerrar`              | Cierra la sesión y refresca progreso.                |
| `sesiones_cerrar_zombies`    | Barrido de sesiones abiertas >15 min sin actividad.  |
| `refrescar_progreso_unidad`  | Deriva `teoria_completada` a partir de las sesiones. |

### 5.5 Dashboards

| RPC                       | Descripción                                                 |
|---------------------------|-------------------------------------------------------------|
| `dashboard_inicio`        | Racha, minutos_semana, porcentaje global, continua...       |
| `dashboard_estadisticas`  | Actividad semanal, precisión, unidades hechas, rendimiento por materia. |
| `dashboard_perfil`        | Nombre, email, nivel, xp, racha, oposicion_activa, plan, logros. |
| `mis_retos`               | Retos vigentes con progreso.                                |

### 5.6 Planificador v2

| RPC                              | Descripción                                                  |
|----------------------------------|--------------------------------------------------------------|
| `guardar_disponibilidad`         | Guarda respuestas del wizard y regenera plan próximos 14 d.  |
| `generar_plan`                   | Reparte unidades pendientes por los días disponibles.        |
| `recalcular_plan_hasta_examen`   | Cubre todo el horizonte hasta la fecha del examen.           |
| `siguiente_bloque_pendiente`     | Devuelve el próximo bloque para el botón "Estudiar".         |
| `registrar_bloque_completado`    | Marca un bloque como hecho.                                  |
| `cambiar_disponibilidad_hoy`     | Ajusta las horas de hoy y recalcula la semana.               |
| `reprogramar_dia_perdido`        | Traslada lo no cumplido a los próximos días.                 |
| `sugerir_plan_semanal`           | Sugerencia lunes primer login (basada en últimas 4 semanas). |
| `resumen_inicio_semana`          | Datos para el modal de "Nueva semana" del lunes.             |
| `plan_del_dia`                   | Bloques planificados para una fecha (por defecto hoy).       |
| `reprogramar_plan`               | Fuerza regeneración completa.                                |

### 5.7 Modo estudio

| RPC                       | Descripción                                                    |
|---------------------------|----------------------------------------------------------------|
| `iniciar_estudio`         | Construye `plan_bloques` (estudio + repaso + descansos) para N minutos y sistema. |
| `siguiente_bloque_estudio`| Avanza al siguiente bloque.                                    |
| `saltar_descanso`         | Salta el descanso actual (sólo si es descanso).                |
| `cerrar_estudio`          | Cierra, marca bloques del plan como completados y suma XP.     |
| `obtener_sesion_activa`   | Recupera el estado (para restaurar al recargar la SPA).        |

### 5.8 Repetición espaciada (SM-2 simplificado)

| RPC                            | Descripción                                                |
|--------------------------------|------------------------------------------------------------|
| `registrar_respuesta_espaciada`| Ajusta intervalo/ease según acierto/fallo.                 |
| `siguientes_repasos`           | Devuelve N ids de preguntas con `proxima_revision <= now()`.|

**Algoritmo**: al acertar los intervalos crecen 1 → 3 → 7 → `intervalo × ease_factor`.
El `ease_factor` se mueve entre 1.3 y 3.0 (+0.1 con acierto, −0.2 con fallo).
Al fallar el intervalo vuelve a 0 (repaso mismo día).

### 5.9 Métricas semanales

| RPC                          | Descripción                                                |
|------------------------------|------------------------------------------------------------|
| `calcular_metricas_semanales`| Snapshot de la semana pasada por usuario.                  |
| `ajustar_carga_semanal`      | Regenera plan con carga −20% (<50% cumplido) o +15% (>90%).|
| `resumen_semanal`            | Datos para el banner motivador del Home.                   |
| `cron_semanal`               | Ejecuta ambos para TODOS los usuarios activos (lunes 3am UTC).|

### 5.10 Notificaciones

| RPC                             | Descripción                                                    |
|---------------------------------|----------------------------------------------------------------|
| `push_config_publica`           | Devuelve la VAPID public key para `pushManager.subscribe`.     |
| `push_enviar_prueba`            | Encola un push de prueba al usuario logueado.                   |
| `encolar_notificaciones_diarias`| Encola recordatorios genéricos (>24h sin sesión + domingo).    |

### 5.11 Administración

| RPC                        | Descripción                                                     |
|----------------------------|-----------------------------------------------------------------|
| `admin_stats`              | Contadores generales (usuarios, oposiciones, cola…).            |
| `admin_listar_usuarios`    | Listado paginado con roles y oposiciones matriculadas.          |
| `admin_set_activo`         | Activar/desactivar usuario.                                     |
| `admin_toggle_rol`         | Asignar o quitar rol.                                           |
| `admin_verificar_email`    | Forzar `email_verificado = true`.                               |
| `admin_editar_oposicion`   | Nombre, organismo, descripción, fecha examen (real/orientativa).|
| `admin_temas_de_oposicion` | Temas vinculados a la oposición.                                |
| `admin_temas_disponibles`  | Catálogo de temas NO vinculados (para reutilizar).              |
| `admin_upsert_tema`        | Crear/actualizar tema y opcionalmente vincularlo.               |
| `admin_vincular_tema`      | Atajo: sólo vincular un tema existente.                         |
| `admin_desvincular_tema`   | Quitar tema de la oposición (no borra el tema).                 |
| `admin_reordenar_temas`    | Reordenar todos los temas de una oposición.                     |
| `admin_unidades_de_tema`   | Unidades de un tema.                                            |
| `admin_upsert_unidad`      | Crear/actualizar unidad (con teoría markdown y minutos).        |
| `admin_borrar_unidad`      | Borrar unidad + sus preguntas.                                  |
| `admin_preguntas_de_unidad`| Preguntas de una unidad.                                        |
| `admin_upsert_pregunta`    | Crear/actualizar con opciones y explicación.                    |
| `admin_borrar_pregunta`    | Borrar pregunta.                                                |

---

## 6. SPA (frontend)

### 6.1 Estructura

```
web/
├── index.html         ← templates de todas las vistas (<template id="tpl-*">)
├── style.css          ← estilos móviles + queries desktop
├── tokens.css         ← paleta (salvia + dark bioluminiscente) + shadows/radios
├── session.js         ← wrapper JWT + rpc() + localStorage
├── app.js             ← router, renders, motor de estudio
├── logo.svg           ← el zorrito
├── icons/*            ← manifest / apple-touch / mask-icon
└── manifest.webmanifest
```

Sin bundler. `session.js` y `app.js` son cargados como `<script>` clásicos.

### 6.2 Router

Basado en `location.hash`. Formato: `#/<vista>[/<id>][?query]`.

- Rutas principales: `home`, `plan`, `stats`, `perfil`, `oposicion`, `unidad/<id>`, `estudio`.
- Auth: `auth`, `verify?token=…`, `reset?token=…`.
- Onboarding: `onboarding`, `wizard`.
- Admin: `admin` (usuarios), `administracion` (importar oposiciones),
  `editar/<oposicion_id>` (editor visual).

Reglas del router:
- Sin JWT → `#/auth`.
- Con JWT pero `mi_sesion` devuelve null → limpia token → `#/auth` (JWT huérfano).
- Sin oposiciones matriculadas → `#/onboarding` (excepto rutas admin/perfil).
- Con oposiciones pero sin plan_estudio → `#/wizard` (excepto rutas admin/perfil).

### 6.3 Vistas

| Ruta         | Descripción                                                                                             |
|--------------|---------------------------------------------------------------------------------------------------------|
| `home`       | Chip "Estudiando <oposición>" (clickable → modal), saludo, botón "Estudiar" grande, Plan de hoy compacto.|
| `plan`       | Semana strip (L-D), lista de bloques del día seleccionado, tarjeta "Próximo hito" clickable, botones "Editar disponibilidad" / "Hoy tengo otro tiempo". |
| `stats`      | Racha / tiempo semanal / precisión, chart de barras 7 días, anillo de progreso total, ranking por materia. |
| `perfil`     | Datos, nivel, XP, logros, entradas a "Mi oposición" / "Disponibilidad" / "Tema", card admin.            |
| `oposicion`  | Nombre + organismo, card con fecha de examen (o estimación), temas colapsables con sus unidades.        |
| `unidad/<id>`| Cabecera con `‹ atrás`, teoría markdown, CTA "Comenzar test" con 10 preguntas.                          |
| `wizard`     | 3 pasos: modo (semanal/diario), horas por día/semana, método+ritmo.                                     |
| `estudio`    | Modo fullscreen con cabecera + cronómetro compacto, cuerpo del bloque scrollable, botones fijos abajo.  |
| `admin`      | Contadores + listado de usuarios + gestión (activar, verificar, rol admin) + listado de oposiciones.    |
| `administracion` | Import de oposición desde JSON.                                                                     |
| `editar/<id>`| Editor visual: datos generales (nombre + fecha examen), temas colapsables (reutilizar o crear), unidades, preguntas. |

### 6.4 Auto-tracking

En `unidad/<id>`:
1. `sesion_abrir(unidad_id)` al montar.
2. `setInterval(30s)` que si `document.visibilityState === 'visible'` hace `sesion_tick(delta_seg=30)`.
3. `sesion_cerrar` en `pagehide` / `beforeunload` / al salir de la ruta.
4. La SPA actualiza la barra de progreso local con los segundos acumulados.

### 6.5 Modo estudio

1. Usuario pulsa "Estudiar" en Home:
   - Si hay bloques pendientes de hoy → `iniciar_estudio(total_minutos_pendientes)` → arranca directamente.
   - Si no hay plan → modal "¿Cuánto tiempo tienes?" con quick chips.
2. Se navega a `#/estudio`.
3. La vista carga `obtener_sesion_activa`. Pinta bloque actual (teoría / preguntas de repaso / descanso).
4. Cronómetro compacto en la cabecera cuenta atrás. Cuerpo scrollable dentro de sí mismo (nunca la página completa).
5. Al llegar a 0 o al pulsar "Siguiente" → `siguiente_bloque_estudio` → carga el siguiente.
6. Al llegar al bloque `final` → `cerrar_estudio()`:
   - Marca `progreso_unidad.teoria_completada = true` para las unidades procesadas.
   - Marca `plan_sesiones.completada = true` de HOY para esas unidades y para los repasos.
   - Suma XP proporcional a minutos activos.
   - Muestra pantalla "¡Sesión completada!" con botón "Volver al Inicio".

---

## 7. Sistema adaptativo

### 7.1 Métricas semanales

Se calculan cada lunes al primer login (o desde el cron interno del `notificador`).
Guardadas en `metricas_semanales`:

| Métrica                  | Cálculo                                                            |
|--------------------------|--------------------------------------------------------------------|
| `minutos_estudiados`     | `sum(sesiones_estudio.segundos_activos) / 60` de la semana.        |
| `objetivos_cumplidos_pct`| `plan_sesiones.completada / total` de la semana.                   |
| `precision_media`        | `sum(respuestas.correcta) / count(*)` de la semana.                |
| `fatiga_delta`           | `precisión 1ª mitad − precisión 2ª mitad` de cada sesión (avg).    |
| `dias_activos`           | Días distintos con alguna sesión.                                  |
| `tema_foco`              | Tema con peor rendimiento (para insistir).                         |

### 7.2 Ajuste de carga automático

`ajustar_carga_semanal()`:
- `<50%` objetivos cumplidos → carga −20%, regenera plan.
- `>90%` cumplido → carga +15%, regenera plan.
- Entre 50-90% → sin cambio.

### 7.3 Repetición espaciada (SM-2 simplificado)

En `repasos_pregunta`:
- Al acertar: `intervalo` sube por escalones 1 → 3 → 7 → `intervalo × ease_factor`.
- `ease_factor` ∈ [1.3, 3.0], sube 0.1 con acierto, baja 0.2 con fallo.
- Al fallar: `intervalo = 0`, `aciertos_seguidos = 0` (repaso hoy).
- `siguientes_repasos(N)` devuelve las N preguntas con `proxima_revision <= now()`.

### 7.4 Mensajes

`resumen_semanal.mensaje` es siempre positivo:
- `>75%` → "¡Semana redonda!"
- `50-75%` → "Buen ritmo. Un pequeño empujón y…"
- `20-50%` → "Semana normal. Cada bloque suma."
- `<20%` → "Hoy es un buen día para empezar de nuevo."

Nunca aparece "no has hecho…" ni cifras negativas.

---

## 8. Planificador

### 8.1 Wizard de disponibilidad

3 pasos guiados:

1. **Modo**: "Horas semanales" o "Detalle por día". Reutilizables entre oposiciones.
2. **Disponibilidad**:
   - Semanal → slider 1–50 h.
   - Diario → 7 inputs numéricos (L…D) con total en vivo.
3. **Método + Ritmo**:
   - Duración de sesiones: cortas (25 min) / profundas (45 min).
   - Ritmo: relajado / normal / intensivo.

La fecha del examen NO se pregunta al usuario; la fija el admin al crear la oposición.

### 8.2 Motor de generación

`guardar_disponibilidad()` invoca `generar_plan(plan_id, 14)`:
- Borra `plan_sesiones` NO completadas de los próximos 14 días.
- Recorre unidades pendientes de la oposición.
- Distribuye en bloques de 25 o 45 min según método.
- Cada día no puede superar `horas_por_dia[dow]` del plan.
- Añade repasos SM-2 vencidos como bloques `tipo=repaso`.

`recalcular_plan_hasta_examen()`: extiende el horizonte hasta `plan_estudio.fecha_examen`
si está fijada, o mantiene 14 días.

### 8.3 Cambio puntual "Hoy tengo otro tiempo"

Modal en la vista Plan con opciones rápidas (0, 15, 30, 60, 120, 180+ min) →
`cambiar_disponibilidad_hoy(minutos)`:
- Ajusta lo de HOY.
- Recalcula el resto de la semana para reabsorber lo que sobre / falte.

### 8.4 Reprogramación silenciosa

Al abrir Home la SPA llama `reprogramar_dia_perdido()`:
- Coge bloques NO completados de días anteriores.
- Los mete en la cola de los próximos días sin superar los límites diarios.

### 8.5 Sugerencia semanal (lunes)

Al primer login del lunes, `resumen_inicio_semana()` devuelve una sugerencia
basada en las últimas 4 semanas de `sesiones_estudio`. El usuario acepta o
ajusta y se guarda como nueva `horas_por_dia`.

---

## 9. Notificaciones

### 9.1 Email (mailer)

Worker Python que:
1. Cada `TICK_SECONDS` (30s default) lee `cola_emails WHERE enviado_en IS NULL LIMIT BATCH_LIMIT`.
2. Los envía vía SMTP (`SMTP_HOST:SMTP_PORT` con STARTTLS).
3. Marca `enviado_en = now()` o registra `ultimo_error`.

Modo dev: `MAILER_DEV_LOG_ONLY=1` → sólo loguea, no abre conexión SMTP.

### 9.2 Web Push (notificador)

Worker Python con **cron interno** (sin cron externo):
- **Cada `TICK_SECONDS`** (300s default): envía `cola_push` pendientes.
- **Cada `ENCOLAR_MINUTOS`** (15 default): llama a `encolar_notificaciones_diarias()`.
  - Encola recordatorio para inactivos >24 h.
  - Los domingos encola resumen semanal.
  - Anti-ruido: si ya hay push pendiente en las últimas 20 h, no encola otra.
- **Lunes a `CRON_SEMANAL_HORA` UTC** (3 default): llama a `cron_semanal()`.
  - Calcula métricas semanales para todos los usuarios activos.
  - Ajusta carga semanal.

---

## 10. Editor visual (admin)

Ruta `#/editar/<oposicion_id>` con navegación jerárquica:

- **Datos generales** — nombre, organismo, descripción, fecha del examen + "sólo orientativa".
- **Temas** — botón "+ Tema" abre modal con **dos modos**:
  - "Elegir existente": dropdown con temas del catálogo no vinculados aún
    (muestra "N unidades · en N oposiciones").
  - "Crear nuevo": slug + nombre + icono. Si el slug ya existe, se reutiliza.
- **Unidades** — CRUD con teoría markdown, orden, minutos estimados.
- **Preguntas** — CRUD con opciones (radio para marcar la correcta, +2 mínimo),
  explicación, dificultad 1-5.

Cada nivel tiene migas de pan y botón "Atrás" grande. Cada mutación va vía
RPCs `admin_*` (que validan `es_admin()` centralizadamente).

---

## 11. Despliegue

### 11.1 Stacks

Cuatro directorios bajo `deploy/`, cada uno con su propio compose y `.env.example`:

| Carpeta               | Contenido                              | Publica                          |
|-----------------------|----------------------------------------|----------------------------------|
| `deploy/core/`        | db + postgrest + pgadmin (opcional)    | `${DOMINIO_API}`, `${DOMINIO_PGADMIN}` |
| `deploy/app/`         | Caddy + SPA                            | `${DOMINIO_LANDING}` (+ ALT)     |
| `deploy/mailer/`      | Worker SMTP                            | —                                |
| `deploy/notificador/` | Worker Web Push + cron interno         | —                                |
| `deploy/backups/`     | restic + rclone → Google Drive         | —                                |

### 11.2 Redes

- **`dokploy-network`** (external) — la de Traefik. Sólo la usan servicios con HTTP: `postgrest`, `app`, `pgadmin`.
- **`db-net-${DB_ALIAS:-prod}`** (external, creada con `deploy/init-networks.sh`) — red **privada** por entorno. Sólo la usan `db`, `postgrest`, `mailer`, `notificador`, `backups` de ese entorno.

Aislar la BBDD en una red privada por entorno evita la colisión de alias `db`
cuando prod y desa coexisten en el mismo host (el hostname `db` en
`dokploy-network` resolvería a round-robin entre las dos BBDD).

En el compose de core, el servicio `postgres` tiene:
- `container_name: db${DB_ALIAS:+-${DB_ALIAS}}` → visible como `db-desa` en `docker ps`.
- Alias explícito `db-desa` en la red privada.
- Service key `postgres` a propósito: el alias implícito por service name (que Compose siempre añade y no se puede desactivar) es `postgres`, no `db`, así que no colisiona con nada.

### 11.3 Coexistencia prod + desa (DB_ALIAS)

`DB_ALIAS` se propaga a `container_name`, aliases de red, nombres de routers
Traefik y hostnames que los otros stacks usan. La forma
`${DB_ALIAS:+-${DB_ALIAS}}` **omite** el sufijo cuando la variable está vacía
(compatibilidad con la prod histórica):

| Entorno | `DB_ALIAS` | container/alias                                       | router Traefik                     |
|---------|------------|-------------------------------------------------------|------------------------------------|
| Prod    | *(vacío)*  | `db`, `postgrest`, `app`, `mailer`, `notificador`     | `aprentix-api`, `aprentix-web`     |
| Desa    | `desa`     | `db-desa`, `postgrest-desa`, `app-desa`, `mailer-desa`| `aprentix-api-desa`, `aprentix-web-desa` |

### 11.4 Variables por stack (desa como ejemplo)

Ver `DESPLIEGUE.md` para el listado completo. Puntos clave:

- Todos los stacks del mismo entorno usan **el mismo `DB_ALIAS`, `POSTGRES_DB`, `POSTGRES_USER`, `DB_PASS`, `JWT_SECRET`**.
- Sólo el stack `core` (prod) activa `COMPOSE_PROFILES=pgadmin`.
- `pgadmin/servers.json` trae dos entradas: `Host: db` (prod) y `Host: db-desa`. pgAdmin se une a las tres redes (`dokploy-network`, `db-net-prod`, `db-net-desa`).
- Backups: `RESTIC_REPOSITORY=rclone:gdrive:aprentix_desa-backups` diferente por entorno.

### 11.5 Migraciones

- **`db/init/01_esquema.sql`** — esquema completo, idempotente
  (`CREATE OR REPLACE`, `ADD COLUMN IF NOT EXISTS`, `DROP POLICY IF EXISTS`).
  Se ejecuta automáticamente en el **primer arranque** del contenedor db
  (cuando el volumen está vacío) por el hook `/docker-entrypoint-initdb.d/`.
- **`db/migrations/`** — cambios incrementales para BBDD ya existentes
  (donde el init no vuelve a ejecutarse). Numeradas por orden. Cada una
  termina con `NOTIFY pgrst, 'reload schema';` para recargar el cache de
  PostgREST sin reiniciar.
  - `02_recargar_funciones_autenticacion.sql`
  - `03_configurar_url_publica.sql`
  - `04_ampliar_obtener_oposicion.sql`
  - `05_admin_usuarios_y_temas.sql`
  - `06_cerrar_estudio_marca_bloques.sql`

Aplicación típica:
```bash
docker exec -i db-desa psql -U aprentix -d aprentix_desa \
    < db/migrations/06_cerrar_estudio_marca_bloques.sql
```

---

## 12. Design system

### 12.1 Paleta (light)

- `--pri` salvia principal (verde apagado).
- `--pri-d` verde oscuro para texto/CTA.
- `--pri-soft` verde muy suave para chips.
- `--accent` naranja/coral suave para racha (🔥).
- `--txt` / `--txt-soft` grises cálidos.
- `--bg` / `--bg-panel` / `--bg-alt` fondos con contraste bajo.

### 12.2 Paleta (dark)

Modo bioluminiscente: fondos verde-negro muy oscuros, acentos en verde neón
suave. Definido en `tokens.css` bajo `:root:not([data-theme="light"])` con
`prefers-color-scheme: dark` y bajo `:root[data-theme="dark"]` para forzarlo.

### 12.3 Tipografía

`clamp(...)` fluido en móvil. En desktop (≥1024px) los tokens se comprimen
a valores fijos para que la app no se vea gigante en pantallas grandes.

### 12.4 Componentes clave

- `.top-bar` — sticky top, siempre visible.
- `.chip` (variantes: soft / ghost / outline / level / racha).
- `.btn` (variantes: primary / outline / ghost / mini).
- `.btn-back` — pill con "‹ Atrás", visible.
- `.btn-estudiar` — CTA grande con icono ▶ e info dinámica.
- `.card` / `.card-head` — contenedor genérico.
- `.opos-activa` — chip clickable en el Home con la oposición activa.
- `.progress` / `.progress-bar` / `.progress-lg`.
- `.empty-state` — panel dashed con emoji + mensaje + CTA opcional.
- `.crono-mini` — cronómetro compacto (44px + mm:ss) para el modo estudio.
- `.bottom-nav` — fixed abajo, 4 tabs, siempre visible.

### 12.5 Layout responsivo

- Móvil: columna única, top-bar sticky, bottom-nav fixed.
- Desktop (≥1024px): mismo diseño pero con tokens comprimidos y `--content-max: 600px`.
- Desktop grande (≥1440px): `--content-max: 660px`.
- Modo estudio: `height: 100dvh` sin scroll de página. Cabecera + cuerpo
  scrollable + CTA fija abajo.

---

## 13. Estado de las funcionalidades

### Listas ✅

- Registro con verificación por email (SMTP configurable).
- Login por email, JWT PostgREST.
- Reset de contraseña (RPC + UI).
- Onboarding con reutilización de oposiciones matriculadas.
- Wizard de disponibilidad multi-paso.
- Motor básico de generación de plan (14 días).
- Vista unidad unificada (teoría + CTA test).
- Test rápido dentro de la unidad (10 preguntas).
- Auto-tracking del tiempo de estudio (Page Visibility API).
- Modo Estudio a pantalla completa con cronómetro y avance automático.
- SM-2 simplificado con `registrar_respuesta_espaciada`.
- Sistemas de estudio (Pomodoro, Ultradiano, Bloques 45…).
- Métricas semanales + ajuste de carga automático.
- Editor visual completo (oposición → temas → unidades → preguntas).
- Reutilización de temas por catálogo (dropdown "Elegir existente").
- Fecha del examen por oposición (real u orientativa), editada por admin.
- Admin: listado de usuarios (activar, verificar, rol admin), stats globales.
- Vista "Mi oposición" con temas colapsables + fecha del examen (o estimación).
- Notificador con cron interno (envío push + encolar diario + cron semanal).
- Mailer SMTP con `MAILER_DEV_LOG_ONLY` para desarrollo.
- Backups nocturnos con restic + rclone → Google Drive.
- Coexistencia prod + desa aislada por red privada.

### En beta / básico 🌱

- **Motor de plan**: reparte por horas disponibles sin heurística de dificultad.
- **Retos**: catálogo semillado pero sin motor que incremente `retos_usuario.progreso`.
- **Simulacros**: tipo existe pero no hay generador de "N preguntas al azar de
  toda la oposición" con cronómetro y baremo.
- **Web Push**: infraestructura completa (cola_push, worker, VAPID), pero la
  SPA no tiene aún botón "Activar notificaciones" que llame a
  `pushManager.subscribe`. Vale usar `SELECT push_enviar_prueba()` desde
  pgAdmin para probar el circuito una vez suscrito.

### Sin implementar 🚧

- **Simulacro mensual automático**: falta el generador N-al-azar.
- **Estadísticas por unidad/tema** con desglose de tiempo y respuestas.
- **Recordatorios push programados** por franjas horarias del usuario.
- **Import/export CSV** de preguntas.
- **PWA offline real** (service worker). Sólo hay manifest.
- **Sesiones multi-dispositivo / revocación de tokens**.
- **Métricas de admin en tiempo real** (websocket o polling).

### PWA offline — alcance previsto (documentado, no implementado)

| Función                                | Offline razonable | Por qué                                                  |
|----------------------------------------|-------------------|----------------------------------------------------------|
| Abrir la app instalada                 | ✅                | Cache básica del shell.                                  |
| Ver teoría ya visitada                 | ✅                | Cachear `obtener_unidad`.                                |
| Continuar bloque de teoría offline     | ✅                | Auto-tracking se encola (Background Sync).               |
| Terminar bloque y avanzar              | ⚠️ Parcial        | `registrar_bloque_completado` necesita red.              |
| Test de una unidad cacheada            | ⚠️ Parcial        | Preguntas cacheables; `responder_pregunta` se encola.    |
| Repaso SM-2                            | ❌                | Necesita ver `siguientes_repasos`, que cambia.           |
| Login / registro / verificación        | ❌                | Requieren red.                                           |
| Import de oposición JSON               | ❌                | Admin online.                                            |
| Recalcular plan / cambio disponibilidad| ❌                | Motor SQL — online.                                      |
| Estadísticas                           | ❌                | Cálculos en BBDD — online.                               |

Coste técnico estimado si se aborda: 1-2 días.

---

## 14. Convenciones

### 14.1 Git

- Rama de desarrollo: `claude/redesign-oposiciones-9bdwaq`.
- Commits en español, primera línea sujeta ≤72 caracteres, cuerpo explicativo.
- Todos los commits llevan el footer:
  ```
  Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
  Claude-Session: <url>
  ```

### 14.2 SQL

- Idempotencia obligatoria: `CREATE OR REPLACE`, `IF NOT EXISTS`,
  `DROP POLICY IF EXISTS` + `CREATE POLICY`.
- Dollar-quotes etiquetados cuando anidan: `$html$…$html$`, `$grant_exec$…$grant_exec$`.
- `NOTIFY pgrst, 'reload schema'` al final de cada script.
- Comentarios sin `$` sueltos (evitar cerrar dollar-quotes por accidente).

### 14.3 JavaScript

- Vanilla ES2020, sin bundler ni framework.
- `$(sel, root)` / `$$(sel, root)` como shortcuts de query.
- Router hash-based, hooks `hashchange` + `load`.
- Estado global en `state = { session, oposiciones, principalId, planCargado, tienePlan }`.
- Todas las llamadas RPC vía `S.rpc(nombre, params, { api: '/api' })`.
- Manejo defensivo: `data = data || {}` para tolerar bodies `null`.

### 14.4 CSS

- Mobile-first, `clamp(...)` para tipografía y spacings.
- Media queries en 720px, 1024px, 1440px.
- Todas las vistas usan `--content-max`.
- Sin scroll de página en modo estudio (`height: 100dvh; overflow: hidden`).

---

## 15. Puesta en marcha rápida (desa)

```bash
# 1) Redes privadas (una vez por host)
bash deploy/init-networks.sh

# 2) .env en cada stack (ver deploy/<stack>/.env.example)
#    Todos con DB_ALIAS=desa, mismo JWT_SECRET, POSTGRES_DB=aprentix_desa

# 3) Desde Dokploy: desplegar en orden core → app → mailer → notificador → backups

# 4) Migraciones sobre BBDD existente
for f in db/migrations/*.sql; do
  docker exec -i db-desa psql -U aprentix -d aprentix_desa < "$f"
done

# 5) Primer login: admin@aprentix.es / ${ADMIN_PASS}
#    Desde el perfil de admin → Administración → Importar oposición JSON.
```

Para prod, mismo flujo con `DB_ALIAS=` (vacío), `POSTGRES_DB=aprentix`,
`COMPOSE_PROFILES=pgadmin` en el core.

---

## 16. Referencias en el repositorio

- **`README.md`** — introducción rápida.
- **`DESPLIEGUE.md`** — detalles operativos y troubleshooting.
- **`SPECS.md`** — este documento.
- **`db/init/01_esquema.sql`** — esquema completo (~3500 líneas).
- **`db/migrations/`** — migraciones incrementales.
- **`db/ejemplo_oposicion.json`** — payload de referencia para `importar_oposicion`.
- **`web/`** — SPA (index + style + tokens + session + app).
- **`mailer/`** — worker SMTP.
- **`notificador/`** — worker Web Push con cron interno.
- **`deploy/`** — un stack por carpeta.
- **`pgadmin/servers.json`** — pre-registro de servidores para pgAdmin.
