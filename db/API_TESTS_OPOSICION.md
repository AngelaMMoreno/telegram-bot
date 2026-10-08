# API: subir tests a una oposición y listarlos

La API es la propia de PostgREST: cada función de Postgres se llama con
`POST /rpc/<función>` y un cuerpo JSON. Base URL en producción:
`https://api.aprentix.es` (también `https://aprentix.es/api` y
`https://aprentix.es/tests/api`, que pasan por Caddy).

Requiere haber aplicado
`db/migraciones/2026-10-08_api_tests_oposicion.sql` (las BBDD nuevas ya
la traen en `db/init/01_esquema.sql`).

## 1. Autenticación

```bash
API=https://api.aprentix.es

TOKEN=$(curl -s "$API/rpc/login_web" \
  -H 'Content-Type: application/json' \
  -d '{"p_username":"admin","p_password":"TU_PASSWORD"}' | jq -r .token)
```

El token (JWT) dura 12 horas. Se envía como `Authorization: Bearer $TOKEN`.
Para **subir** hace falta un usuario con rol `admin` o `editor`
(permiso `test.crear`).

## 2. Listar oposiciones

`POST /rpc/listar_oposiciones_admin` (sin parámetros; ya existía).

```bash
curl -s -X POST "$API/rpc/listar_oposiciones_admin" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}'
```

```json
[
  { "id": "6f1c…", "nombre": "Auxiliar Administrativo", "descripcion": null,
    "activa": true, "num_tests": 12, "num_usuarios": 40 }
]
```

El `id` es el que se usa en las otras dos llamadas.

## 3. Listar los tests de una oposición

`POST /rpc/listar_tests_de_oposicion`

| Parámetro        | Tipo | Descripción         |
|------------------|------|---------------------|
| `p_oposicion_id` | uuid | Id de la oposición. |

```bash
curl -s -X POST "$API/rpc/listar_tests_de_oposicion" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"p_oposicion_id":"6f1c…"}'
```

```json
[
  { "id": "a3d9…", "titulo": "Tema 1", "descripcion": "Constitución",
    "num_preguntas": 25, "creado_en": "2026-10-08T17:02:28+00:00" }
]
```

Ordenados del más reciente al más antiguo. Lo puede llamar el staff y
cualquier usuario que tenga esa oposición asignada.

## 4. Subir un test a una oposición

`POST /rpc/subir_test_a_oposicion`

| Parámetro        | Tipo  | Descripción |
|------------------|-------|-------------|
| `p_oposicion_id` | uuid  | Oposición **ya creada** a la que se añade el test. |
| `p_titulo`       | text  | Nombre del test (obligatorio). |
| `p_descripcion`  | text  | Descripción (puede ser `null`). |
| `p_preguntas`    | jsonb | Array de preguntas (ver formato). También se acepta el objeto `{"preguntas": [...]}` que genera `descargar_test`. |

```bash
curl -s -X POST "$API/rpc/subir_test_a_oposicion" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg op 6f1c… --arg t 'Tema 1' --arg d 'Constitución' \
        --slurpfile p preguntas.json \
        '{p_oposicion_id:$op, p_titulo:$t, p_descripcion:$d, p_preguntas:$p[0]}')"
```

Respuesta (`200`):

```json
{ "id": "a3d9…", "titulo": "Tema 1", "descripcion": "Constitución",
  "oposicion_id": "6f1c…", "num_preguntas": 25 }
```

### Formato de `preguntas.json`

Dos formatos de opciones, intercambiables entre preguntas del mismo fichero
siempre que dentro de una pregunta no se mezclen:

```json
[
  {
    "pregunta": "¿En qué año se aprobó la Constitución española?",
    "opciones": ["1978", "1975", "1982", "1931"],
    "explicacion": "Opcional. En este formato la PRIMERA opción es la correcta.",
    "etiquetas": ["constitucion"]
  },
  {
    "pregunta": "¿Cuántos artículos tiene el Título Preliminar?",
    "opciones": [
      { "texto": "9",  "correcta": true  },
      { "texto": "10", "correcta": false }
    ]
  }
]
```

- `pregunta` y `opciones` son obligatorios; mínimo 2 opciones.
- Con opciones-objeto cada una lleva `texto` y `correcta` (booleano), con
  al menos una correcta.
- `explicacion` y `etiquetas` son opcionales.
- Las preguntas con el mismo enunciado que otra ya existente se reutilizan
  (deduplicación por `hash_contenido`).

### Comportamiento

- Todo ocurre en **una transacción**: si el JSON es inválido no se crea
  nada.
- El test queda enlazado a la oposición (visible para sus usuarios),
  con `publico = false` y el usuario que llama como autor.
- No se permite repetir el título (sin distinguir mayúsculas) dentro de la
  misma oposición → `test_duplicado`; así se puede reintentar una subida
  sin duplicar.

### Errores

PostgREST responde `400` con `{"message", "details", "hint"}`:

| `message`                 | Causa |
|---------------------------|-------|
| `no_autorizado`           | El usuario no es `admin`/`editor`. |
| `titulo_obligatorio`      | `p_titulo` vacío. |
| `oposicion_no_encontrada` | El id no existe. |
| `test_duplicado`          | Ya hay un test con ese título en la oposición. |
| `preguntas_invalidas`     | No es un array, o está vacío. |
| `pregunta_invalida`       | `details` indica la pregunta (nº) y el problema. |

Un token ausente o caducado devuelve `401`.
