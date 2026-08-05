# Despliegue del entorno DESA (rediseño oposiciones)

Este documento explica cómo levantar el entorno paralelo `desa` con la
nueva SPA orientada a oposiciones, sin afectar al entorno de
producción existente (`aprentix.es`).

Nombres, dominios y contenedores están sufijados con `-desa`; comparten
la red externa `dokploy-network`.

## Resumen

| Pieza | Producción | DESA |
|---|---|---|
| BBDD | `aprentix` (`db`) | `aprentix_desa` (`db-desa`) |
| PostgREST | `postgrest` | `postgrest-desa` |
| Frontend | `aprentix.es` (`app`) | `desa.aprentix.es` (`app-desa`) |
| API pública | `api.aprentix.es` | `api.desa.aprentix.es` |
| Mailer | — | `mailer-desa` |
| Notificador Push | `notificador` | `notificador-desa` |
| pgAdmin | *(compartido)* | mismo pgAdmin — nuevo servidor en `servers.json` |
| Backups | ✅ | ❌ (no en DESA) |

DESA usa Postgres estándar (no pgvector) porque el rediseño ya no
necesita embeddings.

## Cambios de esquema

Todo el modelo gira ahora en torno a la **oposición**:

- **oposiciones** 1—N **oposicion_temas** (puente N:M) 1—N **temas** *(reutilizables entre oposiciones)*
- **temas** 1—N **unidades**
- **unidades** 1—N **preguntas** *(cada unidad tiene teoría + tests)*

La sección teoría/tests desaparece: la unidad es la pieza atómica.

Fichero autoritativo: `db/desa/init/01_esquema.sql`.

## Preparación previa

1. **Crear el volumen** para la BBDD DESA (una sola vez):
   ```bash
   sudo mkdir -p /mnt/data/pg_desa
   sudo chown -R 999:999 /mnt/data/pg_desa
   ```
2. **Copiar `.env`** y ajustar valores:
   ```bash
   cp deploy/desa/.env.example deploy/desa/.env
   $EDITOR deploy/desa/.env
   ```
   Variables SMTP:
   ```
   SMTP_HOST=smtp.gmail.com
   SMTP_PORT=587
   SMTP_USER=...             # usuario Gmail
   SMTP_PASS=...             # "contraseña de aplicación" de Google
   SMTP_FROM=No Contestar <no-reply@aprentix.es>
   SMTP_TLS=starttls
   ```
3. **Actualizar el pgAdmin de producción**. Ya está incluido en
   `pgadmin/servers.json` un nuevo servidor `aprentix-desa` que
   apunta a `db-desa:5432`. Basta con **redeplegar el stack core de
   producción** para que pgAdmin recargue el fichero y muestre los
   dos servidores.

## Levantar todo el entorno DESA

Con `docker compose` en el host (Dokploy hace lo mismo internamente):

```bash
docker compose -f deploy/desa/docker-compose.yml --env-file deploy/desa/.env up -d
```

Esto levanta: `db-desa`, `postgrest-desa`, `app-desa`, `mailer-desa`,
`notificador-desa` en paralelo a los servicios de producción.

En Dokploy, crea **una Compose Application por carpeta**:

- `deploy/desa/core/docker-compose.yml`
- `deploy/desa/app/docker-compose.yml`
- `deploy/desa/mailer/docker-compose.yml`
- `deploy/desa/notificador/docker-compose.yml`

y pega el `.env` en cada una.

## Importar la primera oposición

Cuando arranca la BBDD DESA, sólo existe el usuario `admin@aprentix.es`
(contraseña = `ADMIN_PASS_DESA`).  Con su token puedes hacer:

```bash
curl -X POST https://api.desa.aprentix.es/rpc/importar_oposicion \
     -H "Authorization: Bearer <TU_JWT>" \
     -H "Content-Type: application/json" \
     -d @db/desa/ejemplo_oposicion.json
```

Ver `db/desa/ejemplo_oposicion.json` como plantilla del payload
aceptado por `importar_oposicion()`. Los temas se identifican por
`slug`: si el slug ya existe en la BBDD, el tema se **reutiliza**
(no se duplican unidades ni preguntas). Si es nuevo, se crea con
todas sus unidades y preguntas.

Desde la propia SPA, puedes hacer login con `admin@aprentix.es` y
hacer la misma llamada RPC desde la consola del navegador
(`AprentixSession.rpc('importar_oposicion', {p_payload: JSON.parse(txt)})`).

## Probar el flujo de emails

1. Regístrate desde `https://desa.aprentix.es/` con un correo real
   (dos veces el mismo, contraseña + repetir).
2. El registro encola una fila en `cola_emails`.
3. `mailer-desa` la envía al primer tick (30 s por defecto).
4. Pulsa el botón "Confirmar mi cuenta" del correo → aterrizas en
   `https://desa.aprentix.es/#/verify?token=…`.
5. El login pasa a estar habilitado (`iniciar_sesion` comprueba
   `email_verificado`).

Para revisar la cola desde pgAdmin:

```sql
SELECT id, destinatario, asunto, enviado_en, ultimo_error
  FROM cola_emails ORDER BY encolado_en DESC LIMIT 20;
```

## Notificaciones push

1. Genera un par VAPID nuevo (no reutilices el de producción):
   ```bash
   python notificador/gen_vapid.py
   ```
2. Pon la privada en `VAPID_PRIVATE_KEY_DESA` y la pública en
   `VAPID_PUBLIC_KEY_DESA` del `.env`.
3. Guarda también la pública en la BBDD:
   ```sql
   UPDATE config SET valor = '"<clave_publica>"'::jsonb
    WHERE clave = 'push_vapid_public';
   INSERT INTO config(clave, valor) VALUES
     ('push_vapid_public', '"<clave_publica>"'::jsonb)
     ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor;
   ```
4. El notificador-desa hace tick cada 5 min por defecto.  Puedes
   forzar un envío de prueba insertando manualmente en `push_envios`
   o modificando la lógica de `push_candidatos_*` cuando la
   implementes (ahora mismo el notificador reutiliza el binario de
   producción; conviene revisar que sus RPCs coincidan con el nuevo
   esquema — de momento devolverán 0 candidatos porque las tablas
   `intentos` / `respuestas` tienen otro shape).

## Rutas de la SPA nueva

Router hash-based:

- `#/auth` — login + registro (con confirmar email y contraseña + fuerza)
- `#/verify?token=…` — aterrizaje del enlace del correo
- `#/onboarding` — elegir oposición al primer login
- `#/home` — Inicio
- `#/plan` — Plan
- `#/stats` — Estadísticas
- `#/perfil` — Perfil
- `#/unidad/<uuid>` — Unidad (tabs Teoría / Test)

## Comprobación rápida

Después del primer arranque, comprueba:

- `psql -h db-desa -U aprentix -d aprentix_desa -c "\dt"` — tablas creadas.
- `curl https://api.desa.aprentix.es/` — PostgREST responde con el
  catálogo OpenAPI.
- `curl https://desa.aprentix.es/` — la SPA sirve `index.html`.
- `SELECT * FROM cola_emails ORDER BY encolado_en DESC LIMIT 1;` —
  la fila del correo de verificación existe.

## Borrado limpio (solo DESA)

```bash
docker compose -f deploy/desa/docker-compose.yml --env-file deploy/desa/.env down
sudo rm -rf /mnt/data/pg_desa
```

Esto NO toca `aprentix` de producción (usa `/mnt/data/pg`).

## Lo que queda para siguientes iteraciones

- Motor de generación real del **plan de estudio**: hoy el wizard es
  un placeholder y la SPA muestra bloques inventados en la vista
  Plan.  La tabla `plan_sesiones` ya existe para persistir el
  calendario diario.
- **Retos y logros**: el catálogo y el progreso viven en la BBDD
  (`retos_catalogo`, `logros_catalogo`), pero el motor que
  incrementa `retos_usuario` tras cada test aún no está
  implementado.  Se dispara desde `finalizar_intento()` — extenderlo
  ahí.
- **Editor visual** de oposiciones desde el propio panel de admin.
  Hoy la carga se hace vía RPC `importar_oposicion` con un JSON.
