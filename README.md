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
├── web/                     ← SPA autocontenida (sin subcarpeta shared/)
│   ├── index.html
│   ├── style.css
│   ├── app.js
│   ├── tokens.css                ← paleta + modo oscuro
│   └── session.js                ← window.AprentixSession (JWT + rpc)
├── mailer/                  ← worker SMTP (consume cola_emails)
│   ├── Dockerfile, mailer.py, requirements.txt
├── notificador/             ← worker Web Push (consume cola_push)
│   ├── Dockerfile, notificador.py, gen_vapid.py, requirements.txt
└── deploy/                  ← un stack Dokploy por carpeta
    ├── core/          → db + postgrest
    │   ├── docker-compose.yml
    │   └── .env.example
    ├── app/           → Caddy + SPA
    │   ├── Dockerfile
    │   ├── Caddyfile
    │   ├── docker-compose.yml
    │   └── .env.example
    ├── mailer/
    │   ├── docker-compose.yml
    │   └── .env.example
    └── notificador/
        ├── docker-compose.yml
        └── .env.example
```

En **Dokploy** cada carpeta bajo `deploy/` es una Compose Application
independiente con SU PROPIO `.env` — así puedes redesplegar sólo
`deploy/app` cuando cambia el frontend sin tocar la BBDD ni los
workers, exactamente igual que en producción.

En **dev local** basta con:

```bash
cp .env.example .env
$EDITOR .env
docker compose up -d
```

El maestro (`include:`) fusiona los cuatro composes en un único
proyecto y todos ven las mismas variables.

## Mismas variables en todo entorno

Los nombres son **idénticos** en dev, desa y prod — sólo cambia el
valor.  Cambiar de entorno al que apunta un deploy es editar el
`.env` de ese stack, no el YAML.  Cuando merges esta rama a
`main` sólo hay que ajustar `DB_NAME`, `DOMINIO_WEB` y `DOMINIO_API`
al entorno de destino (más contraseñas y VAPID); el resto es igual.

## Rutas de la SPA

Router hash-based:

- `#/auth` — login + registro (email + repetir email, contraseña +
  repetir con indicador de fuerza)
- `#/verify?token=…` — aterrizaje del enlace del correo
- `#/onboarding` — elegir oposición al primer login
- `#/home`, `#/plan`, `#/stats`, `#/perfil` — cuatro pantallas del mockup
- `#/unidad/<uuid>` — teoría + test en pestañas

Ver [`DESPLIEGUE.md`](DESPLIEGUE.md) para el paso a paso completo.
