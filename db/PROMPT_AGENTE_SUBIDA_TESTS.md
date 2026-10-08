# Prompt para el agente que sube los tests

Copia todo lo que hay debajo de la línea en la sesión del otro proyecto.
Antes, sigue los pasos previos que te he indicado en el chat (migración
aplicada, usuario `editor` creado y `.env` rellenado).

---

## Objetivo

Sube a la plataforma Aprentix todos los tests de unidad que hay en este
proyecto a UNA oposición ya existente. Cada fichero `test.json` es un test;
el **nombre del test es el nombre de la carpeta que lo contiene** (la
carpeta de la unidad). No subas los que ya estén subidos.

## Configuración (fichero `.env` en la raíz del proyecto)

```
APRENTIX_API_URL=https://api.aprentix.es
APRENTIX_USER=...
APRENTIX_PASSWORD=...
APRENTIX_OPOSICION=Nombre exacto de la oposición
TESTS_DIR=.            # carpeta raíz donde buscar los test.json
```

Lee el `.env` desde un script. NUNCA imprimas la contraseña ni el token,
NUNCA los metas en commits ni en logs, y comprueba que `.env` está en
`.gitignore`.

## API (PostgREST). Todas las llamadas son `POST {APRENTIX_API_URL}/rpc/<función>` con cuerpo JSON

1. **Login** — `login_web` con `{"p_username": USER, "p_password": PASSWORD}`.
   Devuelve `{"token": "...", ...}`. Usa el token como
   `Authorization: Bearer <token>` en las demás llamadas. Caduca a las 12 h:
   si recibes 401, vuelve a hacer login y reintenta.
2. **Listar oposiciones** — `listar_oposiciones_admin` con `{}`. Devuelve
   `[{id, nombre, descripcion, activa, num_tests, num_usuarios}]`. Localiza
   la oposición cuyo `nombre` coincida (sin distinguir mayúsculas) con
   `APRENTIX_OPOSICION`. Si no hay coincidencia exacta, muestra las
   disponibles y PARA; no adivines.
3. **Listar tests ya subidos** — `listar_tests_de_oposicion` con
   `{"p_oposicion_id": "<id>"}`. Devuelve
   `[{id, titulo, descripcion, num_preguntas, creado_en}]`.
4. **Subir un test** — `subir_test_a_oposicion` con
   ```json
   {
     "p_oposicion_id": "<id>",
     "p_titulo": "<nombre de la carpeta>",
     "p_descripcion": null,
     "p_preguntas": [ ... ]
   }
   ```
   Responde `{id, titulo, descripcion, oposicion_id, num_preguntas}`.
   Los errores llegan como HTTP 400 con `{message, details, hint}`:
   `test_duplicado` (ya existe ese título en la oposición),
   `pregunta_invalida` (en `details` va el nº de pregunta y el problema),
   `preguntas_invalidas`, `titulo_obligatorio`, `oposicion_no_encontrada`,
   `no_autorizado`.

## Formato esperado de `p_preguntas`

Array JSON no vacío. Cada pregunta:

```json
{
  "pregunta": "Enunciado (obligatorio)",
  "opciones": ["Correcta", "Incorrecta", "Incorrecta"],
  "explicacion": "opcional",
  "etiquetas": ["opcional"]
}
```

- Formato A: `opciones` es un array de textos y **la PRIMERA es la correcta**.
- Formato B: `opciones` es `[{"texto": "...", "correcta": true|false}, ...]`
  con al menos una correcta.
- Mínimo 2 opciones. No mezcles A y B dentro de la misma pregunta.
- Si el `test.json` ya es un array de preguntas, o un objeto
  `{"titulo", "descripcion", "preguntas": [...]}`, se acepta tal cual. Si
  trae otro esquema (otros nombres de campo, la correcta indicada por
  índice o por letra…), conviértelo al formato A o B SIN cambiar el
  contenido, y dime qué transformación hiciste.

## Procedimiento

1. Busca todos los `test.json` bajo `TESTS_DIR`. El título del test es el
   nombre de la carpeta que contiene el fichero (usa el nombre tal cual,
   sin renombrar ni traducir).
2. Haz login, localiza la oposición y lista los tests que ya tiene.
3. **Antes de subir nada**, haz una pasada en seco: valida localmente cada
   `test.json` (JSON válido, formato de preguntas) y muestra una tabla con
   `carpeta | nº preguntas | estado` donde estado es `nuevo`,
   `ya existe` (el título coincide, sin distinguir mayúsculas ni espacios
   en los extremos) o `inválido (motivo)`. Si hay dos carpetas con el mismo
   nombre, avísame y no subas ninguna de las dos.
4. Si la tabla es razonable, sube solo los `nuevo`, UNO POR UNO (una
   petición por test), de forma secuencial. Si `p_descripcion` no viene en
   el propio `test.json`, déjala en `null`.
5. Si una subida falla, no abortes todo: registra el error y sigue con las
   demás. No reintentes automáticamente un 400 (es un problema de datos);
   sí reintenta hasta 3 veces con espera creciente ante errores de red o
   5xx, y tras un 401 vuelve a autenticarte una vez.
6. Es idempotente: si me lo ejecutas de nuevo, los ya subidos salen como
   `ya existe` y no se duplican. Tampoco intentes borrar ni modificar tests
   existentes: esta API solo crea.
7. Al terminar, vuelve a listar los tests de la oposición y muéstrame el
   resumen: subidos, saltados (ya existían), fallidos con su motivo, y el
   total de tests y de preguntas que tiene ahora la oposición.

## Reglas

- Guarda el script en el proyecto (p. ej. `subir_tests.py`) con un flag
  `--dry-run` que solo hace los pasos 1–3, para poder reutilizarlo.
- Usa solo la librería estándar o `requests`; sin dependencias raras.
- No toques nada fuera de estas 4 llamadas a la API. Si el entorno no
  alcanza `APRENTIX_API_URL` (red bloqueada), dímelo en lugar de buscar
  rodeos.
