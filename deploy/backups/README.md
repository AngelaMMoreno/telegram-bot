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

### 1. Autorizar Google Drive con rclone (en tu máquina local)

Rclone necesita un token OAuth de Google. Se genera en local (donde
hay navegador) y se copia al VPS:

```bash
# En tu ordenador local (Linux/macOS):
brew install rclone         # o: sudo apt install rclone
rclone config
```

Elige:
- `n` → New remote
- Nombre: **`gdrive`** (usa el mismo que aparezca en `RESTIC_REPOSITORY`)
- Storage: `drive` (Google Drive)
- `client_id` y `client_secret`: déjalos vacíos (usa los de rclone) o
  crea los tuyos siguiendo <https://rclone.org/drive/#making-your-own-client-id>
  (recomendado si vas a mover mucho volumen — evita rate-limits).
- Scope: `drive` (acceso completo) o `drive.file` (solo ficheros que
  cree rclone — más seguro y suficiente para esto).
- `service_account_file`: vacío.
- `Edit advanced config`: `n`.
- `Use auto config`: `y` → se abre el navegador, autorizas, y rclone
  guarda el token.
- `Configure this as a Shared Drive`: `n` (a menos que uses un Drive
  compartido de Google Workspace).

Verifica que funciona:

```bash
rclone mkdir gdrive:aprentix-backups
rclone lsd gdrive:
```

### 2. Copiar `rclone.conf` al VPS

```bash
# En el VPS:
sudo mkdir -p /mnt/data/backup-config
# Desde tu ordenador local:
scp ~/.config/rclone/rclone.conf usuario@vps:/tmp/rclone.conf
# De vuelta en el VPS:
sudo mv /tmp/rclone.conf /mnt/data/backup-config/rclone.conf
sudo chmod 600 /mnt/data/backup-config/rclone.conf
```

### 3. Variables de entorno

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

### 4. Desplegar

```bash
docker compose -f deploy/backups/docker-compose.yml up -d --build
```

Fuerza una primera corrida para inicializar el repositorio y validar
que todo va:

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
