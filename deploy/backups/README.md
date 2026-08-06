# Stack `backups` — snapshots automáticos a Google Drive

Contenedor de fondo que cada noche vuelca la BBDD a un repositorio
[restic](https://restic.net/) alojado en Google Drive vía
[rclone](https://rclone.org/).

En este rediseño la teoría (markdown) vive **dentro de la propia
BBDD** (columna `unidades.teoria_md`), así que un solo snapshot del
dump SQL cubre todo — no hay snapshot aparte de ficheros de disco.

## Cómo funciona

Un `dcron` dentro del contenedor lanza `/backup.sh` en el horario
que marque `BACKUP_CRON` (por defecto todas las noches a las 03:30).
El script:

1. `pg_dump -Fp` de la BBDD (formato plano — mucho mejor dedup en
   restic que el custom binario) y lo mete como snapshot con tag
   `db`.
2. `restic forget --keep-last N --prune` para dejar solo los N más
   recientes (por defecto 2) y liberar los chunks huérfanos.

Restic deduplica a nivel de bloque: la primera corrida sube todo
entero, las siguientes solo suben los cambios.  El fichero que ves
en Drive no es una carpeta por snapshot — es UN repositorio donde
restic mete chunks y metadata.  Cifrado end-to-end con
`RESTIC_PASSWORD`.

## Coexistencia prod + desa

Prod y desa apuntan a **carpetas distintas** en Drive para no
mezclar snapshots:

- prod: `RESTIC_REPOSITORY=rclone:gdrive:aprentix-backups`
- desa: `RESTIC_REPOSITORY=rclone:gdrive:aprentix_desa-backups`

El hostname de la BBDD se resuelve por `DB_ALIAS`:

- prod: `DB_ALIAS=` vacío → hostname `db`.
- desa: `DB_ALIAS=desa`   → hostname `db-desa`.

## Configuración inicial (una sola vez)

El plan: autorizamos Google Drive con OAuth desde el navegador de
tu ordenador local (headless) y pegamos el token generado dentro
del contenedor.  El `rclone.conf` resultante queda persistido en el
host en `/mnt/data/backup-config/` gracias al bind-mount, así
sobrevive a reinicios y redespliegues.

### 1. Preparar la carpeta en el VPS

```bash
# En el VPS por SSH:
sudo mkdir -p /mnt/data/backup-config
sudo chmod 700 /mnt/data/backup-config
```

### 2. Obtener el token OAuth en tu máquina local

```bash
# En tu ordenador local (Linux/macOS/Windows):
brew install rclone           # o: sudo apt install rclone / scoop install rclone
rclone authorize "drive"
```

Se abre el navegador, autorizas con tu cuenta de Google y rclone te
imprime en el terminal un JSON parecido a:

```
{"token":{"access_token":"ya29...","refresh_token":"1//...","expiry":"..."}}
```

Cópialo entero — lo vas a pegar en el paso siguiente.

### 3. Configurar el remote DENTRO del contenedor

Levanta el stack por primera vez (`docker compose up -d --build` o
desde Dokploy).  El contenedor arrancará pero el backup no se
ejecutará todavía porque falta el `rclone.conf`.  Entra al
terminal:

```bash
# Desde el VPS por SSH:
docker compose -f deploy/backups/docker-compose.yml exec backups sh
# Ya dentro del contenedor:
rclone config
```

Responde así:
- `n` → New remote
- Nombre: **`gdrive`** (tiene que coincidir con `RESTIC_REPOSITORY`).
- Storage: `drive`
- `client_id` / `client_secret`: déjalos vacíos (o crea los tuyos
  siguiendo <https://rclone.org/drive/#making-your-own-client-id>
  si vas a mover mucho volumen).
- Scope: `1` (drive completo) o `2` (drive.file — solo lo que suba
  rclone; más seguro y sobra para esto).
- `service_account_file`: vacío.
- `Edit advanced config`: `n`.
- **`Use auto config`: `n`** ← activa el modo headless.
- `config_token>` → **pega el JSON del paso 2** y Enter.
- `Configure this as a Shared Drive`: `n` (a menos que sea un Shared
  Drive de Workspace).
- Confirma con `y` y sal con `q`.

Verifica:

```bash
rclone lsd gdrive:
rclone mkdir gdrive:aprentix_desa-backups   # o el nombre que uses
```

El fichero queda en `/mnt/data/backup-config/rclone.conf` gracias
al bind-mount.

### 4. Variables de entorno

Copia `deploy/backups/.env.example` a la Compose Application
`backups` de Dokploy y rellena.  Para desa:

- `DB_ALIAS=desa`
- `POSTGRES_DB=aprentix_desa`
- `POSTGRES_USER=aprentix`
- `DB_PASS` — la misma que en el stack core desa.
- `RESTIC_REPOSITORY=rclone:gdrive:aprentix_desa-backups`
- `RESTIC_PASSWORD` — generada con `openssl rand -base64 32`.
  **Sin ella no se puede restaurar nada.**
- `KEEP_LAST=2`, `BACKUP_CRON=30 3 * * *`

### 5. Forzar el primer backup

```bash
docker compose -f deploy/backups/docker-compose.yml exec backups /backup.sh
```

Deberías ver:

```
[backup] ... Inicializando repositorio restic en rclone:gdrive:aprentix_desa-backups
[backup] ... Volcando la BBDD (aprentix_desa @ db-desa) y subiendo snapshot 'db'
[backup] ... Rotando snapshots (keep-last=2)
[backup] ... OK. Snapshots vivos:
ID        Time                 Host       Tags     Paths
...
```

## Restaurar

Puedes restaurar desde cualquier máquina con `restic` + `rclone`
usando el mismo `RESTIC_REPOSITORY` + `RESTIC_PASSWORD` +
`rclone.conf`.

```bash
export RESTIC_REPOSITORY=rclone:gdrive:aprentix_desa-backups
export RESTIC_PASSWORD='…'

# Listar lo que hay
restic snapshots

# Restaurar el último dump a /tmp/restore/
restic restore latest --tag db --host aprentix --target /tmp/restore
psql -h HOST -U aprentix -d aprentix_desa < /tmp/restore/aprentix_desa.sql
```

Para restaurar un snapshot anterior al último, sustituye `latest`
por el ID que aparezca en `restic snapshots`.

## Operaciones útiles

```bash
# Todo el histórico
docker compose -f deploy/backups/docker-compose.yml exec backups \
    restic snapshots

# Integridad del repo (descarga metadata + muestra de bloques)
docker compose -f deploy/backups/docker-compose.yml exec backups \
    restic check

# Estadísticas de tamaño
docker compose -f deploy/backups/docker-compose.yml exec backups \
    restic stats --mode raw-data

# Forzar backup ad-hoc
docker compose -f deploy/backups/docker-compose.yml exec backups /backup.sh
```
