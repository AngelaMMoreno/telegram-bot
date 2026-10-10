# API: tests de una oposición (subir, listar, consultar y editar)

La API es la propia de PostgREST: cada función de Postgres se llama con
`POST /rpc/<función>` y un cuerpo JSON. Base URL en producción:
`https://api.aprentix.es` (también `https://aprentix.es/api` y
`https://aprentix.es/tests/api`, que pasan por Caddy).

Requiere haber aplicado
`db/migraciones/2026-10-08_api_tests_oposicion.sql` y, para consultar y
editar (apartados 5-8), `db/migraciones/2026-10-10_api_editar_tests.sql`
(las BBDD nuevas ya lo traen en `db/init/01_esquema.sql`).

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
- Las preguntas con el mismo enunciado **y las mismas opciones** que otra
  ya existente se reutilizan (deduplicación por `hash_contenido`). Hasta
  la migración de 2026-10-10 bastaba el enunciado, y una pregunta
  corregida con el mismo enunciado se quedaba con las opciones viejas.

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


## 5. Consultar un test con sus preguntas

`POST /rpc/obtener_test` con `{"p_test_id": "…"}`, o
`POST /rpc/obtener_test_por_titulo` con
`{"p_oposicion_id": "…", "p_titulo": "redes_area_local"}` (sin distinguir
mayúsculas; devuelve `null` si la oposición no tiene ese test).

```json
{ "id": "…", "titulo": "redes_area_local", "descripcion": null, "tipo": "manual",
  "publico": false, "creado_en": "…", "num_preguntas": 264,
  "oposiciones": [{ "id": "…", "nombre": "Ayuntamiento Madrid A2" }],
  "preguntas": [
    { "id": "…", "posicion": 1, "pregunta": "…",
      "opciones": [{ "texto": "…", "correcta": true }, …],
      "explicacion": "…", "etiquetas": [], "otros_tests": 0 } ] }
```

`otros_tests` dice en cuántos tests más está la pregunta: editarla con
`editar_pregunta` la cambia en todos.

## 6. Actualizar un test ya subido

### Sincronizar (crear o actualizar)

`POST /rpc/sincronizar_test_en_oposicion`, mismos parámetros que
`subir_test_a_oposicion` (`p_oposicion_id`, `p_titulo`, `p_descripcion`,
`p_preguntas`). Si la oposición no tiene un test con ese título lo crea;
si lo tiene, lo deja con exactamente esas preguntas y en ese orden.
`p_descripcion` `null` no toca la descripción de un test existente.
Es la llamada para volver a subir un `test.json` corregido: es idempotente
y no duplica.

```json
{ "id": "…", "titulo": "redes_area_local", "accion": "ACTUALIZADO",
  "num_preguntas": 264, "sin_cambios": false, "reutilizadas": 258,
  "corregidas": 3, "nuevas": 3, "explicaciones_actualizadas": 2,
  "explicaciones_compartidas": 0, "repetidas_en_el_fichero": 0,
  "retiradas": 4, "borradas": 2 }
```

`accion`: `CREADO`, `ACTUALIZADO` o `SIN_CAMBIOS`.

### Reemplazar las preguntas de un test por id

`POST /rpc/reemplazar_preguntas_test` con `{"p_test_id", "p_preguntas",
"p_borrar_huerfanas": true}`. Es lo que hace la sincronización con un test
existente. Criterios, pensados para no perder el historial de los usuarios:

| Caso | Qué hace |
|---|---|
| Pregunta idéntica (enunciado + opciones) a una existente | La reutiliza (`reutilizadas`). Si cambia la explicación y ningún otro test la usa, la actualiza (`explicaciones_actualizadas`); si la comparte, la deja (`explicaciones_compartidas`). |
| Mismo enunciado que una pregunta del test, otras opciones, y ningún otro test la usa | La corrige en su sitio: conserva repasos, fallos y favoritas (`corregidas`). |
| Mismo enunciado que una pregunta compartida con otro test (p. ej. la oficial de un examen) | Crea una pregunta nueva y la del otro test no cambia (`nuevas`). |
| Pregunta que sale del test | Se desenlaza (`retiradas`); si no queda en ningún test y `p_borrar_huerfanas`, se borra con su historial (`borradas`). |

### Renombrar o cambiar la descripción

`POST /rpc/editar_test` con `{"p_test_id", "p_titulo", "p_descripcion"}`.
`null` deja el campo como está; `p_descripcion: ""` la borra. Error
`test_duplicado` si otro test de una de sus oposiciones ya tiene ese título.

### Quitar un test de una oposición

`POST /rpc/quitar_test_de_oposicion` con `{"p_test_id", "p_oposicion_id",
"p_borrar_si_huerfano": false}`. Con `true`, si el test ya no está en
ninguna oposición se borra junto con sus preguntas exclusivas (requiere
`test.borrar`).

## 7. Editar una pregunta

`POST /rpc/editar_pregunta` con `{"p_pregunta_id", "p_enunciado",
"p_opciones", "p_explicacion", "p_etiquetas"}`. `null` deja cada campo como
está; `p_explicacion: ""` la borra; `p_opciones` acepta los dos formatos
de la subida. Cambia la pregunta en todos los tests que la usan (los
devuelve en `tests`). Error `pregunta_duplicada` si ya hay otra con el
mismo enunciado y opciones. Requiere `pregunta.editar`.

## 8. Oposiciones y tests repetidos

| Llamada | Cuerpo | Qué hace |
|---|---|---|
| `listar_oposiciones_admin` | `{}` | Lista (apartado 2). |
| `crear_oposicion` | `{"p_nombre", "p_descripcion"}` | Alta. Devuelve `{id}`. |
| `editar_oposicion` | `{"p_id", "p_nombre", "p_descripcion", "p_activa"}` | `null` deja cada campo. |
| `borrar_oposicion` | `{"p_id"}` | Solo admin. Los tests no se borran: solo se desenlazan. |
| `tests_repetidos_de_oposicion` | `{"p_oposicion_id", "p_umbral": 0.5}` | Pares de tests de la oposición que comparten al menos esa proporción de enunciados (sobre el menor de los dos). Sirve para encontrar exámenes subidos dos veces con nombres distintos. |

## 9. Errores nuevos

| `message` | Causa |
|---|---|
| `test_no_encontrado` | El id de test no existe. |
| `test_no_esta_en_la_oposicion` | `quitar_test_de_oposicion` sobre un par que no existe. |
| `pregunta_no_encontrada` | El id de pregunta no existe. |
| `pregunta_duplicada` | `editar_pregunta` la dejaría igual que otra existente. |
