# Publicación del contenido

El repo de contenido (git) es donde se escribe y se revisa. La base de
datos es la copia publicada que sirve la app. `publicar.py` es el único
puente entre los dos, y va **en una sola dirección**: git → BD.

Nadie edita el contenido en la BD. Publicar es correr este script.

---

## Uso

```bash
pip install -r requirements.txt

# 1. Mira qué haría. NO escribe nada.
python3 publicar.py \
    --repo git@github.com:tu-cuenta/oposiciones.git \
    --db "postgres://aprentix@localhost:5432/aprentix_desa"

# 2. Si el plan cuadra, aplícalo.
python3 publicar.py --repo git@github.com:tu-cuenta/oposiciones.git \
    --db "…" --aplicar
```

Sin `--aplicar` es un **simulacro**: lee el repo, lo compara con lo
publicado y enseña el plan. Es el modo por defecto a propósito — el paso
que escribe hay que pedirlo.

### De dónde saca el contenido

| Flag | Para qué |
|---|---|
| `--repo URL` | Lo clona él mismo en un temporal y publica de ahí. |
| `--rama NOMBRE` | Rama a publicar. Por defecto, la del remoto. |
| `--commit SHA` | Publica un commit concreto. **Así se vuelve atrás.** |
| `--contenido RUTA` | Una copia local que ya tengas, en vez de clonar. |

Con `--repo` lo publicado sale siempre de un árbol limpio recién traído
del remoto, nunca de cambios sin commitear que alguien tuviera a medias
en su copia. Las credenciales son las del entorno (clave SSH o credential
helper): el script no maneja tokens ni los pide.

`--commit` es el botón de deshacer. Si una publicación mete la pata,
republicas el commit anterior y vuelves al estado bueno:

```bash
python3 publicar.py --repo … --commit a1b2c3d --aplicar
```

### Cuánto publica

| Flag | Alcance |
|---|---|
| *(nada)* | Todas las oposiciones de `oposiciones/*.yaml`. |
| `--oposicion SLUG` | Una oposición entera. |
| `--tema SLUG` | Un tema suelto, en las oposiciones que lo usen. |
| `--seccion TEMA/MODULO/SECCION` | Una sección suelta. |

Los tres son repetibles y se pueden mezclar. Publicar filtrado es seguro
para retocar algo concreto sin mover el resto:

```bash
# Sólo la sección que acabas de corregir.
python3 publicar.py --repo … --seccion ley-39-2015/terminacion/silencio --aplicar
```

Dos detalles que importan al publicar parcial:

- **El orden se respeta.** Un tema que va 5.º en su oposición sigue yendo
  5.º aunque lo publiques suelto: la posición sale del `temas:` del YAML
  completo, no del recorte.
- **No se puede archivar.** `--archivar-ausentes` se rechaza junto con
  `--tema`/`--seccion`, porque fuera del filtro no se ha leído nada y el
  script daría por desaparecido todo el resto del temario. Para retirar
  contenido hay que publicar la oposición entera.

### Resto de opciones

| Flag | Para qué |
|---|---|
| `--aplicar` | Escribe de verdad. Sin él, simulacro. |
| `--archivar-ausentes` | Retira lo que ya no está en el repo. **Nunca borra**: archiva. |
| `--forzar` | Sobrescribe también los documentos editados desde el panel. |
| `--estricto` | Los avisos de formato pasan a ser errores. Para el CI. |
| `--ignorar-rutas` | No exige que la ruta del fichero cuadre con su `meta`. |
| `--permitir-archivado-masivo` | Desactiva el freno. Léete antes por qué saltó. |

---

## Revisar sin publicar

```bash
python3 publicar.py --contenido ../ruta/al/repo --validar
```

Sale `0` si el contenido está limpio y `1` si hay avisos. **No necesita
base de datos ni `psycopg`**, sólo PyYAML: está pensado para que lo lance
el CI del repo de contenido y para que quien escribe —persona o modelo—
revise su propio trabajo antes de commitear.

Comprueba lo que se puede comprobar leyendo ficheros: los 8 apartados
obligatorios de la teoría, el presupuesto de 350–1.100 palabras, las 5–12
viñetas de «Retén esto», las ≥ 2 filas de «No lo confundas», el pool de
≥ 25 preguntas, las preguntas sin explicación, las que no tienen 4
opciones, los tamaños del árbol (secciones por módulo, módulos por tema),
los esquemas que falten, los nombres acoplados a la convocatoria (P5) y
que cada YAML de oposición apunte a temas que existan.

## Publicar sin lanzar nada a mano

Este script se puede dejar corriendo solo: `deploy/publicador/` es un
stack de Dokploy que lo ejecuta por cron con las banderas adecuadas para
funcionar sin supervisión (`--estricto`, `--archivar-ausentes`, y nunca
`--forzar` ni `--permitir-archivado-masivo`). Ver
`deploy/publicador/README.md`.

## Ficheros para copiar al repo de contenido

Dos plantillas que viven aquí sólo para estar junto al código que las
respalda. Su sitio de trabajo es el repo de contenido:

| Fichero | Cópialo como | Para qué |
|---|---|---|
| `CLAUDE.md.plantilla` | `CLAUDE.md` en la raíz | Toda la metodología, plantillas y reglas, autosuficiente. Es lo que hace que un modelo escriba contenido correcto sin tener que redescubrir las normas. |
| `workflow-contenido.yml` | `.github/workflows/validar.yml` | Pasa el validador en cada PR. Opcional: la validación también se puede lanzar a mano. |

## Estructura del repo de contenido

```
oposiciones/
  auxilio-judicial.yaml          # slug, nombre, descripcion, temas: [...]
temas/
  <slug-tema>/
    esquema.md                   # aprentix:meta con nivel: tema
    <slug-modulo>/
      esquema.md                 # nivel: modulo
      <slug-seccion>/
        teoria.md                # nivel: seccion
        preguntas.json           # pool de la sección (opcional)
```

Es la convención que ya documenta `docs/PIPELINE_CREACION.md` § 7.2, más
un YAML por oposición. Ese YAML hace falta porque **el orden de los temas
no se puede deducir de las rutas**: un mismo tema se comparte entre
oposiciones y ocupa distinta posición en cada una.

```yaml
slug: auxilio-judicial
nombre: Cuerpo de Auxilio Judicial
descripcion: Administración de Justicia.
temas:
  - ley-39-2015
  - constitucion-espanola
```

De dónde sale cada cosa:

| En la app | Sale de |
|---|---|
| Identidad (slug) | El bloque `aprentix:meta` |
| Nombre visible | El `# H1` del markdown |
| Orden | `orden:` del meta; si falta, alfabético |
| `min_aprobado`, `n_preg_test` | El meta; si faltan, se respeta lo que ya hay en la BD |
| Teoría | El cuerpo del `.md`, tal cual |
| Preguntas | `preguntas.json` |

`preguntas.json` acepta los dos formatos que ya usáis: `{"preguntas": [...]}`
o una lista suelta, con `enunciado` o `pregunta`, y opciones como objetos
`{texto, correcta}` o como lista de textos (la primera es la correcta).

---

## Las reglas que protegen el progreso

El progreso de cada usuario cuelga de `secciones.id`. Todo lo demás se
deriva de proteger ese uuid.

**1. El slug es la identidad; el nombre es una etiqueta.**
Renombrar una oposición, un tema, un módulo o una sección es un `UPDATE`.
El uuid no se mueve y nadie pierde nada. Cambia los `# H1` con total
libertad.

**2. El slug no se cambia.** Cambiar el slug de una sección la convierte
en otra distinta: la vieja se archiva con el progreso dentro y la nueva
nace vacía. Si de verdad hace falta, hazlo con un `UPDATE` manual sobre
la columna `slug` y publica después — no lo hagas cambiando el fichero.

**3. El orden no es identidad.** Reordenar es cambiar `orden:`. Insertar
una sección en medio no afecta a las demás.

**4. Aquí no se borra.** Lo que desaparece del repo se archiva con
`--archivar-ausentes`: sale del home y de los tests, y conserva íntegro
el historial de quien ya lo estudió. Volver a añadirlo lo desarchiva.
Borrar de verdad es una acción manual del panel, y `admin_borrar_*` la
rechaza si hay progreso enganchado.

**5. Si el meta y la ruta discrepan, el script para.** Significa que
alguien movió una carpeta sin actualizar el meta, o al revés. Cuál de los
dos manda no lo puede adivinar una máquina.

### El freno de archivado

Salta cuando la publicación retiraría una parte grande del temario, y muy
en particular cuando **crea aproximadamente tantas secciones como
archiva**. Esa es la huella de un cambio de convención de slugs: el script
ve secciones nuevas donde antes había otras. Nadie pierde datos —archivar
no borra— pero el progreso se queda varado en la fila retirada mientras la
nueva nace a cero, que para el usuario es lo mismo.

Si salta, **mira las dos listas antes de tocar el flag**. Casi siempre la
respuesta correcta es recuperar el slug antiguo, no publicar.

### Ediciones manuales

Un documento parcheado desde el panel queda marcado con
`origen = 'manual'`. La siguiente publicación **no lo pisa**: lo reporta y
sigue. Así un arreglo urgente en caliente no desaparece en silencio.
Cuando el arreglo esté en git, publica con `--forzar`.

---

## Pruebas

```bash
# Freno, filtrado y calibrado del validador (no necesitan BD).
python3 test_salvaguardas.py
python3 test_filtrado.py
python3 test_validador.py

# Invariantes sobre una BD de usar y tirar.
createdb aprentix_test && psql -d aprentix_test -f ../init/01_esquema.sql
psql -d aprentix_test -v ON_ERROR_STOP=1 -f test_publicacion.sql
```

`test_publicacion.sql` comprueba lo que hay que comprobar: que renombrar
oposición, tema, módulo y secciones a la vez —y reordenarlas— no mueve
ningún uuid ni pierde progreso; que republicar es idempotente; que lo
ausente se archiva y se desarchiva al reaparecer; y que borrar con
progreso se rechaza.

---

## Permisos

Las RPCs comprueban `es_admin()`, que lee el claim `roles` de
`request.jwt.claims`. Conectando directo a Postgres ese GUC viene vacío,
así que el script busca el primer usuario con rol `admin` y lo pone él
mismo. Necesitas, por tanto, acceso directo a la BD (no PostgREST).

> Nota: `db/migraciones_contenido/mapear.py` no hace esto, así que sus
> llamadas a `importar_pregunta` fallarían con `permiso_denegado`. Ese
> script quedó para la migración del sistema viejo; para publicar
> contenido nuevo usa éste.
