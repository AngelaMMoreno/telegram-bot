# Aprentix

Plataforma para preparar oposiciones. Toda la app gira en torno a la
**oposición** — la oposición tiene **temas** (reutilizables entre
oposiciones), y cada tema tiene **unidades** que combinan teoría
(markdown) y test.

```
oposiciones  N:M  temas (reutilizables)  1:N  unidades  1:N  preguntas
```

## Estructura del repo

```
/
├── docker-compose.yml        ← maestro con `include:` para dev local
├── .env.example              ← superset de variables (dev local)
├── db/
│   ├── init/01_esquema.sql       ← esquema autoritativo (RLS + RPCs)
│   └── ejemplo_oposicion.json    ← payload para importar_oposicion()
├── pgadmin/
│   └── servers.json              ← entradas para prod (db-prod) + desa (db-desa)
├── web/                     ← SPA autocontenida
│   ├── index.html, style.css, app.js, tokens.css, session.js
├── mailer/                  ← worker SMTP (consume cola_emails)
├── notificador/             ← worker Web Push (consume cola_push)
└── deploy/                  ← un stack Dokploy por carpeta
    ├── core/          → db + postgrest + (opcional) pgadmin
    ├── app/           → Caddy + SPA
    ├── mailer/
    ├── notificador/
    └── backups/       → restic + rclone → Google Drive
```

En **Dokploy** cada carpeta bajo `deploy/` es una Compose Application
independiente con SU PROPIO `.env` — así puedes redesplegar sólo
`deploy/app` cuando cambia el frontend sin tocar la BBDD ni los
workers.

En **dev local** basta con:

```bash
cp .env.example .env  &&  $EDITOR .env  &&  docker compose up -d
```

El maestro (`include:`) fusiona los cuatro composes en un único
proyecto y todos leen del mismo `.env`.

## Coexistencia desa + prod en el mismo Dokploy

Una única variable — **`DB_ALIAS`** — distingue los dos despliegues.

- **Prod**: `DB_ALIAS=` **vacío** — mantiene los nombres actuales
  (`db`, `postgrest`, `app`, `mailer`).  Sin migración de containers.
- **Desa**: `DB_ALIAS=desa` — todo lleva sufijo (`db-desa`,
  `postgrest-desa`, `app-desa`, `mailer-desa`, `notificador-desa`).

El sufijo se calcula con `${DB_ALIAS:+-${DB_ALIAS}}` en cada YAML,
así el mismo compose sirve para ambos entornos sin duplicarlos.
Se propaga a `container_name`, aliases de red y nombres de routers
Traefik.

**Regla**: el mismo `DB_ALIAS` en los 4 `.env` de un mismo entorno.

## pgAdmin compartido

Se despliega **una sola instancia** de pgAdmin en el stack `core`
de prod, activada por `COMPOSE_PROFILES=pgadmin`.  Su `servers.json`
ya trae dos entradas:

- `aprentix`      → host `db`      / db `aprentix`
- `aprentix-desa` → host `db-desa` / db `aprentix_desa`

En desa deja `COMPOSE_PROFILES=` vacío y no se levanta un segundo
pgAdmin — todo se gestiona desde el de prod.

## Rutas de la SPA

Router hash-based:

- `#/auth` — login + registro (email + repetir email, contraseña +
  repetir con indicador de fuerza)
- `#/verify?token=…` — aterrizaje del enlace del correo
- `#/onboarding` — elegir oposición al primer login
- `#/home`, `#/plan`, `#/stats`, `#/perfil` — cuatro pantallas del mockup
- `#/unidad/<uuid>` — teoría + test en pestañas

Ver [`DESPLIEGUE.md`](DESPLIEGUE.md) para el paso a paso completo.
