# Stack `backups` — snapshots automáticos a Google Drive

Contenedor de fondo que cada noche vuelca la BBDD y los ficheros de
teoría a un repositorio [restic](https://restic.net/) alojado en
Google Drive vía [rclone](https://rclone.org/).

## Cómo funciona

Un `dcron` dentro del contenedor lanza `/backup.sh` en el horario que
marque `BACKUP_CRON` (por defecto todas las noches a las 03:30). El
script:

1. `pg_dump -Fp` de la BBDD (formato plano — mucho mejor dedup en restic
   que el custom binario) y lo mete como snapshot con tag `db`.
2. `restic backup /data/ficheros` con tag `teoria`.
3. `restic forget --keep-last N --prune` para dejar solo los N más
   recientes (por defecto 2) y liberar los chunks huérfanos.

Restic deduplica a nivel de bloque: la primera corrida sube todo
entero, las siguientes solo suben los cambios. El fichero que ves en
Drive no es una carpeta por snapshot — es UN repositorio donde restic
mete chunks y la metadata. Sin `restic` no es útil, pero sí es
cifrado end-to-end con `RESTIC_PASSWORD`.

## Configuración inicial (una sola vez)

El plan: autorizamos Google Drive con OAuth desde el navegador de tu
ordenador local (headless) y pegamos el token generado dentro del
contenedor. El `rclone.conf` resultante queda persistido en el host
en `/mnt/data/backup-config/` gracias al bind-mount, así sobrevive a
reinicios y redespliegues.

### 1. Preparar la carpeta en el VPS

```bash
# En el VPS por SSH:
sudo mkdir -p /mnt/data/backup-config
sudo chmod 700 /mnt/data/backup-config
```

### 2. Obtener el token OAuth en tu máquina local

Rclone tiene un modo específico para máquinas sin navegador:

```bash
# En tu ordenador local (Linux/macOS/Windows):
brew install rclone           # o: sudo apt install rclone / scoop install rclone
rclone authorize "drive"
```

Se abre el navegador, autorizas con tu cuenta de Google y rclone te
imprime en el terminal (y copia al portapapeles) un JSON parecido a:

```
{"token":{"access_token":"ya29...","refresh_token":"1//...","expiry":"..."}}
```

Cópialo entero — lo vas a pegar en el paso siguiente.

### 3. Configurar el remote DENTRO del contenedor

Levanta el stack por primera vez con `docker compose up -d --build` (o
desde Dokploy). El contenedor arrancará pero el backup no se ejecutará
todavía porque falta el `rclone.conf`. Entra al terminal del
contenedor:

```bash
# Desde el VPS por SSH:
docker compose -f deploy/backups/docker-compose.yml exec backups sh
# O desde Dokploy: stack backups → contenedor → Terminal.

# Ya dentro del contenedor:
rclone config
```

Responde así:
- `n` → New remote
- Nombre: **`gdrive`** (tiene que coincidir con `RESTIC_REPOSITORY`).
- Storage: `drive`
- `client_id` / `client_secret`: déjalos vacíos (o crea los tuyos
  siguiendo <https://rclone.org/drive/#making-your-own-client-id>
  si vas a mover mucho volumen — evita rate-limits).
- Scope: `1` (`drive`, acceso completo) o `2` (`drive.file`, solo lo
  que suba rclone — más seguro y sobra para esto).
- `service_account_file`: vacío.
- `Edit advanced config`: `n`.
- **`Use auto config`: `n`** ← esto activa el modo headless.
- `config_token>` → **pega aquí el JSON del paso 2** y Enter.
- `Configure this as a Shared Drive`: `n` (a menos que sea un Drive
  compartido de Workspace).
- Confirma con `y` y sal con `q`.

Verifica que va:

```bash
# Sigue dentro del contenedor:
rclone lsd gdrive:
rclone mkdir gdrive:aprentix-backups
```

El fichero queda en `/mnt/data/backup-config/rclone.conf` del host
gracias al bind-mount; puedes salir con `exit`.

### 4. Variables de entorno

Copia `deploy/backups/.env.example` en Dokploy → Compose Application
`backups` y rellena:

- `DB_PASS` — la misma del stack core.
- `RESTIC_REPOSITORY` — `rclone:gdrive:aprentix-backups` (o el nombre
  que hayas usado en `rclone config`).
- `RESTIC_PASSWORD` — genera una larga y aleatoria (`openssl rand
  -base64 32`). Guárdala en tu gestor. **Sin ella no se puede
  restaurar nada.**
- `KEEP_LAST` — cuántos snapshots conservar por tag (default 2).
- `BACKUP_CRON` — horario cron de 5 campos (default `30 3 * * *`).

### 5. Forzar el primer backup

Con el remote ya configurado, dispara una corrida manual para
inicializar el repositorio restic en Drive y validar que todo va:

```bash
docker compose -f deploy/backups/docker-compose.yml exec backups /backup.sh
```

Deberías ver algo como:

```
[backup] ... Inicializando repositorio restic en rclone:gdrive:aprentix-backups
[backup] ... Volcando la BBDD y subiendo snapshot 'db'
[backup] ... Subiendo snapshot 'teoria'
[backup] ... Rotando snapshots (keep-last=2)
[backup] ... OK. Snapshots vivos:
ID        Time                 Host       Tags     Paths
...
```

## Restaurar

Puedes restaurar desde cualquier máquina con `restic` y `rclone` y el
mismo `RESTIC_REPOSITORY` + `RESTIC_PASSWORD` + `rclone.conf`.

```bash
export RESTIC_REPOSITORY=rclone:gdrive:aprentix-backups
export RESTIC_PASSWORD='...'

# Listar lo que hay
restic snapshots

# Restaurar el último dump de BBDD a /tmp/restore/
restic restore latest --tag db --host aprentix --target /tmp/restore
psql -h HOST -U aprentix -d aprentix < /tmp/restore/stdin

# Restaurar los ficheros de teoría
restic restore latest --tag teoria --host aprentix --target /tmp/restore
sudo rsync -a --delete /tmp/restore/data/ficheros/ /mnt/data/ficheros/
```

Para restaurar un snapshot ANTERIOR al último, sustituye `latest` por
el ID que sale en `restic snapshots`.

## Operaciones útiles

```bash
# Ver todo el histórico
docker compose -f deploy/backups/docker-compose.yml exec backups \
    restic snapshots

# Comprobar integridad del repo (pesa: descarga metadata + muestra)
docker compose -f deploy/backups/docker-compose.yml exec backups \
    restic check

# Estadísticas de tamaño
docker compose -f deploy/backups/docker-compose.yml exec backups \
    restic stats --mode raw-data

# Forzar backup ad-hoc (además del cron nocturno)
docker compose -f deploy/backups/docker-compose.yml exec backups /backup.sh
```
