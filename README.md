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
├── docker-compose.yml     ← el único stack
├── .env.example           ← variables (mismos nombres en todo entorno)
├── db/
│   ├── init/01_esquema.sql       ← esquema autoritativo (RLS + RPCs)
│   └── ejemplo_oposicion.json    ← payload para importar_oposicion()
├── web/                   ← SPA autocontenida (sin subcarpeta shared)
│   ├── index.html
│   ├── style.css
│   ├── app.js
│   ├── tokens.css                ← paleta + modo oscuro
│   └── session.js                ← window.AprentixSession (JWT + rpc)
├── mailer/                ← worker SMTP (consume cola_emails)
│   ├── Dockerfile
│   ├── mailer.py
│   └── requirements.txt
├── notificador/           ← worker Web Push (consume cola_push)
│   ├── Dockerfile
│   ├── notificador.py
│   ├── gen_vapid.py
│   └── requirements.txt
└── deploy/
    └── app/
        ├── Dockerfile     ← imagen Caddy + estáticos de web/
        └── Caddyfile      ← / → SPA;  /api → PostgREST
```

## Puesta en marcha rápida

Ver [`DESPLIEGUE.md`](DESPLIEGUE.md) para el paso a paso completo
(incluye cómo añadir el servidor a un pgAdmin ya existente y cómo
probar el circuito de correo y push).

Resumen:

```bash
cp .env.example .env
$EDITOR .env
docker compose up -d
```

- Frontend: `https://${DOMINIO_WEB}` (SPA)
- API:      `https://${DOMINIO_API}` (PostgREST)
- Login inicial: `admin@aprentix.es` / `${ADMIN_PASS}` (ya verificado
  para poder entrar sin pasar por SMTP).

## Rutas de la SPA

Router hash-based:

- `#/auth` — login + registro (email + repetir email, contraseña +
  repetir con indicador de fuerza)
- `#/verify?token=…` — aterrizaje del enlace del correo
- `#/onboarding` — elegir oposición al primer login
- `#/home` — Inicio
- `#/plan` — Plan (esqueleto para el motor de planificación futuro)
- `#/stats` — Estadísticas
- `#/perfil` — Perfil
- `#/unidad/<uuid>` — Unidad (pestañas Teoría / Test)
