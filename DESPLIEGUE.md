# Despliegue en Dokploy

El proyecto está partido en **tres stacks independientes** para poder
redesplegarlos por separado desde Dokploy. Cada stack es una **Compose
Application** distinta que apunta a su propio fichero:

```
deploy/
├── core/docker-compose.yml         ← db + postgrest + embeddings + pgadmin
├── app/docker-compose.yml          ← landing + tests + teoría (frontend) + backend teoría, todo en un contenedor
└── notificador/docker-compose.yml  ← worker de Web Push (sin dominio propio)
```

Los tres comparten la red externa `dokploy-network` y se ven entre sí
por nombre de servicio (`db:5432`, `postgrest:3000`).

El `docker-compose.yml` raíz **solo es para desarrollo local**: usa
`include:` para levantar los tres composes de una tacada
(`docker compose up`). Dokploy no lo utiliza.

## Estructura del frontend

Todo el código de front vive bajo `web/`:

```
web/
├── landing/            ← SPA de landing (aprentix.es/)
├── tests/              ← SPA de tests (aprentix.es/tests/)
├── teoria/             ← SPA de teoría (aprentix.es/teoria/)
├── shared/             ← componentes y CSS compartidos (una copia)
│   ├── auth/session.js       ← cookies + JWT + rpc
│   ├── auth.css              ← estilos de <ap-auth-form>
│   ├── components/
│   │   ├── ap-auth-form.js   ← formulario login+registro compartido
│   │   ├── ap-modal.js
│   │   └── ap-op-selector.js
│   └── header.js, config.js, tokens.css, ...
└── service-worker.js   ← SW en la raíz con scope "/"
```

El backend de teoría vive en `teoria/app.py` (FastAPI), y se empaqueta
junto al frontend en `deploy/app/`.

## 0. Preparar el servidor

1. Instalar Dokploy si aún no lo tienes.
2. La red `dokploy-network` la crea Dokploy automáticamente al
   desplegar el primer stack; no hace falta hacer nada.
3. Crear el volumen de datos en el host (una sola vez):

   ```bash
   sudo mkdir -p /mnt/data/pg /mnt/data/embeddings_cache /mnt/data/ficheros
   ```

4. Crear los registros DNS **A** apuntando a la IP del servidor para
   los dominios (Let's Encrypt los necesita):
   `aprentix.es`, `www.aprentix.es`, `api.aprentix.es`,
   `pgadmin.aprentix.es`.
   Los dominios legacy `test.aprentix.es` y `teoria.aprentix.es`
   redirigen a `aprentix.es/tests/` y `aprentix.es/teoria/`; sus DNS
   siguen siendo necesarios mientras existan.

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

### `app` (aprentix.es — landing + tests + teoría en un contenedor)

| Clave                 | Uso                                                                             |
|-----------------------|---------------------------------------------------------------------------------|
| `JWT_SECRET`          | Igual que el de `core` (el backend de teoría verifica los JWT).                 |
| `DB_PASS`             | Igual que el de `core`. Solo se usa cuando el admin lanza el backup total desde el panel (pg_dump + pg_restore contra `db`). |
| `DOMINIO_LANDING`     | Host principal (por defecto `aprentix.es`).                                     |
| `DOMINIO_LANDING_ALT` | Host alternativo (por defecto `www.aprentix.es`).                               |
| `DOMINIO_WEB`         | Host legacy redirigido a `aprentix.es/tests/` (por defecto `test.aprentix.es`). |
| `DOMINIO_WEB_ALT`     | Host legacy alternativo (por defecto `www.test.aprentix.es`).                   |
| `DOMINIO_TEORIA`      | Host legacy redirigido a `aprentix.es/teoria/` (por defecto `teoria.aprentix.es`). |
| `DOMINIO_TEORIA_ALT`  | Host legacy alternativo (por defecto `www.teoria.aprentix.es`).                 |

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

- `https://aprentix.es` → landing con login/registro.
- `https://aprentix.es/tests/` → SPA de tests.
- `https://aprentix.es/teoria/` → navegador de ficheros.
- `https://test.aprentix.es` y `https://teoria.aprentix.es` → 301 a las
  rutas anteriores (dominios legacy conservados).
- `https://api.aprentix.es` → OpenAPI de PostgREST.
- `https://pgadmin.aprentix.es` → panel de administración.

## 4. Redespliegues por parte

- **Cambio en el esquema SQL** (`db/init/01_esquema.sql`) → redeploy
  solo `core`. La BBDD reejecuta scripts de `docker-entrypoint-initdb.d`
  solo si el volumen está vacío; para BBDD viva, aplica el `ALTER` /
  `CREATE OR REPLACE` desde pgAdmin.
- **Cambio en cualquier SPA (landing, tests, teoría) o en el backend de
  teoría** → redeploy solo `app`.
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

### 6.1 Backup total desde el panel de admin (recomendado)

El panel de administración (menú avatar → **Panel de administración**)
tiene dos opciones exclusivas de `admin`:

- **Backup total** — genera un `.apbak` con:
  - `db/aprentix.dump` (pg_dump -Fc de la BBDD).
  - `teoria/…` (copia íntegra de `/mnt/data/ficheros`).
  - `README.md` con las instrucciones de restauración específicas.

  El archivo se cifra con **AES-256** (7z, `-mhe=on`: también los
  nombres de fichero) con una contraseña que eliges en el momento. Al
  darle a *Generar y descargar*, el navegador descarga el fichero.
  Guarda la contraseña junto al backup — sin ella no se puede abrir.

- **Restaurar backup** — sube un `.apbak`, escribe la contraseña, y el
  servidor:
  1. Ejecuta `pg_restore --clean --if-exists --no-owner` sobre la BBDD.
  2. Vacía `/mnt/data/ficheros` y copia dentro el árbol del backup.
  3. La app queda funcional sin más pasos manuales.

Esto vale para migrar el proyecto de un VPS a otro: despliega los
stacks `core` + `app` en el nuevo servidor con el `DESPLIEGUE.md`, entra
como `admin` (con la `ADMIN_PASS` del stack `core`) y sube el `.apbak`.

### 6.2 Backup / restauración manual (equivalente)

Si el panel no está accesible (por ejemplo, la BBDD aún no tiene
usuario `admin`), se puede hacer todo desde el host del VPS:

```bash
# Backup de la BBDD (dentro del contenedor db del stack core)
docker compose -f deploy/core/docker-compose.yml exec db \
    pg_dump -Fc -U aprentix -d aprentix > db/backups/aprentix_$(date +%F).dump

# Restauración sobre BBDD ya inicializada por 01_esquema.sql
cat aprentix_YYYY-MM-DD.dump | \
    docker compose -f deploy/core/docker-compose.yml exec -T db \
    pg_restore --clean --if-exists -U aprentix -d aprentix

# Ficheros de teoría
rsync -a /mnt/data/ficheros/ destino/
```

Un `.apbak` se puede descomprimir a mano con `7z x backup.apbak` (te
pedirá la contraseña) y luego seguir estos pasos con los ficheros
resultantes.

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
