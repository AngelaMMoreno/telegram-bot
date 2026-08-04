# Pipeline de creación de contenido

Procedimiento para convertir fuentes en bruto (tests de convocatorias
anteriores, normativa oficial, guías técnicas) en temas, módulos,
secciones, teoría y banco de preguntas listos para publicar.

Es el mismo pipeline tanto si lo ejecuta una persona como si lo ejecuta
un modelo asistido: cambia la velocidad, no los pasos ni los controles.

```
 F0 Fuentes  →  F1 Inventario de ítems  →  F2 Secciones  →  F3 Estructura
      →  F4 Teoría  →  F5 Preguntas  →  F6 QA  →  F7 Publicación
```

**Principio rector:** la estructura se decide a partir de **lo que se
evalúa**, no a partir del índice de la norma. Un índice legal es un
sumario, no una secuencia didáctica.

---

## F0 · Fuentes

### Jerarquía de autoridad

Cuando dos fuentes se contradicen, gana la de arriba. Siempre.

| # | Fuente | Uso | Riesgo |
|---|---|---|---|
| 1 | **Norma consolidada oficial** (BOE, boletín autonómico) | Verdad de referencia para todo dato | Ninguno; es el criterio |
| 2 | **Guía o manual oficial del organismo** | Interpretación, procedimientos internos, terminología | Puede estar desactualizada |
| 3 | **Jurisprudencia o doctrina consolidada** | Solo si el temario la exige | Cambia |
| 4 | **Tests de convocatorias anteriores** | **Señal de qué se pregunta y cómo**, nunca fuente de verdad | Erratas, respuestas mal marcadas, normativa derogada |
| 5 | Academias, apuntes, wikis | Solo para detectar enfoques | Sin garantía |

> Los tests reales son la fuente más valiosa para decidir **dónde poner
> el foco**, y la menos fiable para decidir **qué es cierto**. Todo dato
> que salga de un test se verifica contra la fuente 1 antes de escribirse.

### Registro de fuentes

Antes de empezar, deja constancia (irá al bloque `fuentes:` de cada
`teoria.md`):

```
- Norma: <título oficial completo> · <identificador BOE> · <fecha del texto consolidado>
- Guía:  <título> · <organismo> · <versión/fecha>
- Tests: <convocatoria, año, nº de preguntas aportadas>
```

Si la norma se modifica, este registro es lo que permite saber qué
secciones hay que revisar.

---

## F1 · Inventario de ítems evaluables

El paso más importante y el que más se salta. **No se escribe teoría
hasta tener esta tabla.**

Recorre las fuentes y extrae **todo hecho que se pueda preguntar**, uno
por fila:

| id | Ítem evaluable | Tipo | Fuente | Frec. en tests reales | Sección asignada |
|---|---|---|---|---:|---|
| 1 | Plazo general de resolución: 3 meses | plazo | L39/2015 art. 21.3 | 7 | plazos-y-computo |
| 2 | Silencio positivo como regla general a solicitud | regla | L39/2015 art. 24.1 | 12 | silencio-administrativo |
| 3 | Excepción: responsabilidad patrimonial | excepción | L39/2015 art. 24.1 | 5 | silencio-administrativo |

**Tipos de ítem:** `definicion`, `plazo`, `cuantia`, `mayoria`,
`competencia`, `procedimiento`, `regla`, `excepcion`, `jerarquia`,
`enumeracion`.

**Extracción desde tests de ejemplo:** cada pregunta existente apunta a
un ítem. Anota el ítem, no la pregunta. Si 12 preguntas de 5
convocatorias apuntan al mismo ítem, ese ítem es nuclear y merece
tratamiento destacado en la teoría y ≥ 5 preguntas propias.

**Salida de F1:** una tabla con 40–200 ítems por tema y su frecuencia.
Esa frecuencia es la que después alimenta la columna "Cómo cae en el
examen" de cada sección.

---

## F2 · Agrupar ítems en secciones

Agrupa los ítems por **una única idea nuclear**, no por proximidad en el
articulado.

1. Ordena los ítems por afinidad conceptual (qué se explica junto).
2. Forma grupos de **6–9 ítems**. Ese grupo es una sección candidata.
3. Escribe la **frase-objetivo** de la sección: ≤ 20 palabras, sin unir
   ideas distintas con "y". Si no sale, el grupo tiene dos secciones
   dentro.
4. Estima el tamaño con la aritmética de `ESTRUCTURA_CONTENIDO.md` § 1.
5. Ajusta: grupos de < 5 ítems se funden; grupos de > 12 se parten.

**Regla de partición:** cuando haya que partir, hazlo por **criterio
semántico** (regla vs. excepciones, sujeto vs. procedimiento, ámbito A
vs. ámbito B), nunca por cantidad ("parte 1 / parte 2").

---

## F3 · Agrupar secciones en módulos y módulos en tema

1. Agrupa secciones en módulos de **3–5** por fuente común, fase del
   procedimiento o bloque conceptual.
2. Para cada módulo, escribe sus **preguntas puente** (§ 3 de
   `PLANTILLA_TEORIA.md`). Si no salen 2, el módulo no existe:
   reagrupa.
3. Agrupa módulos en un tema de **3–5** módulos, ≤ 28 secciones.
4. **Nombra** todo aplicando el test de portabilidad
   (`ESTRUCTURA_CONTENIDO.md` § 4.2). Este es el punto de no retorno:
   renombrar después obliga a tocar slugs, rutas de fichero y
   documentos.
5. Fija el orden y declara prerrequisitos.

**Salida de F3:** el JSON de estructura importable (§ 7.1), listo para
`_importarOposicionJSON` / `_importarTemasJSON` del panel de admin.

---

## F4 · Escribir la teoría

Sigue `PLANTILLA_TEORIA.md` al pie de la letra. Orden de escritura
recomendado (no es el orden del documento):

1. **Retén esto** — parte de los ítems evaluables del inventario. Es el
   esqueleto real de la sección.
2. **Cómo cae en el examen** — con las frecuencias de F1 y las formas de
   enunciado observadas en los tests reales.
3. **No lo confundas** — de los distractores que más aparecen en los
   tests reales y de los errores que la propia norma induce.
4. **Desarrollo** — ahora sí, la prosa que sostiene lo anterior.
5. **La idea clave** — se escribe al final, resumiendo el desarrollo.
6. **Por qué importa** — el gancho, lo último. Debe conectar con el
   ítem de mayor frecuencia.
7. **Compruébalo tú mismo** — 2–3 preguntas abiertas sobre los ítems
   nucleares.
8. **Cabecera y `<!-- aprentix:meta -->`** — con el recuento real de
   palabras e ítems.

> Escribir en este orden garantiza el cierre teoría–test (P2): la teoría
> nace de lo evaluable, no al revés.

### Prompt reutilizable para generación asistida

Cuando se genere con ayuda de un modelo, este es el encargo. Se le
adjunta la fuente normativa y el inventario de ítems de la sección.

```
Eres redactor de contenido para Aprentix, una app de preparación de
oposiciones. Escribe la teoría de UNA sección siguiendo exactamente la
plantilla de docs/PLANTILLA_TEORIA.md § 2.

ENTRADA
- Nombre de la sección: <...>
- Módulo: <...>  · Tema: <...>
- Prerrequisito: <...>
- Fuente normativa (texto literal adjunto): <...>
- Ítems evaluables que DEBE cubrir (lista cerrada): <...>
- Confusiones observadas en tests reales: <...>
- Formas de enunciado observadas en tests reales: <...>

REGLAS DURAS
1. Los 8 apartados, con sus títulos literales, en el orden de la
   plantilla. Ninguno se omite.
2. Entre 700 y 900 palabras en total.
3. "Por qué importa" arranca con un caso o una pregunta concreta, nunca
   con una definición.
4. "Retén esto": una viñeta por ítem evaluable, autocontenida, sin
   pronombres que dependan del texto anterior.
5. "No lo confundas": mínimo 2 filas, tomadas de las confusiones reales
   aportadas.
6. Segunda persona, frases de máximo 25 palabras, números en cifra.
7. Negrita SOLO en términos evaluables (máximo 15 en toda la sección).
8. Cero menciones a ninguna oposición, convocatoria, cuerpo o escala.
9. No inventes ningún dato que no esté en la fuente adjunta. Si un ítem
   no puede sostenerse con la fuente, decláralo en una nota final en
   lugar de escribirlo.
10. Markdown compatible con `marked`: encabezados, listas, tablas GFM,
    citas y <details>. Nada de HTML con estilos ni de LaTeX.

SALIDA
El fichero teoria.md completo, empezando por el bloque
<!-- aprentix:meta --> con el recuento real de palabras e ítems.
```

Un segundo pase de revisión con la checklist de
`PLANTILLA_TEORIA.md` § 6 es obligatorio: la generación asistida falla
sobre todo en el recuento de palabras y en colar datos no presentes en
la fuente.

---

## F5 · Construir el banco de preguntas

### Cuántas

| Nivel | Regla |
|---|---|
| Por sección | **mínimo 25, objetivo 35** preguntas (≈ 3,5 × `n_preg_test`) |
| Por ítem evaluable | 3–5 preguntas |
| Por fila de "No lo confundas" | ≥ 1 pregunta cuyo distractor sea esa confusión |

### Mezcla de tipos

| Tipo | Peso | Qué evalúa | Ejemplo de enunciado |
|---|---:|---|---|
| **Literal / dato** | 40 % | Recuerdo exacto del ítem | "El plazo general de resolución es de…" |
| **Comprensión / aplicación** | 35 % | Uso del concepto en un caso | "Solicitas X y transcurren 4 meses sin respuesta. ¿Qué procede?" |
| **Discriminación** | 25 % | Distinguir figuras confundibles | "¿Cuál de las siguientes NO es una excepción al silencio positivo?" |

Las de **discriminación** son las que producen aprendizaje real
(Skinner: control por discriminación de estímulos) y las que peor se
generan automáticamente. Escríbelas a mano si hace falta.

### Reglas de redacción de preguntas

1. **4 opciones, 1 correcta.** El esquema admite ≥ 2 opciones, pero el
   estándar del sistema es 4 para que el azar valga 25 %.
2. **`explicacion` obligatoria.** Máximo 3 líneas. Debe decir por qué la
   correcta lo es **y** por qué falla la trampa principal. Sin
   explicación no hay feedback inmediato y la pregunta no cumple P3.
3. **Distractores plausibles y con origen**: salen de "No lo confundas",
   de errores reales observados en tests o de datos vecinos (otro plazo
   de la misma norma). Un distractor absurdo no enseña nada.
4. **Paridad de longitud** entre opciones. La opción notablemente más
   larga suele ser la correcta y el usuario lo aprende.
5. **Sin "todas las anteriores" / "ninguna de las anteriores"** por
   encima del 5 % del pool.
6. **Sin negaciones dobles.** Si el enunciado es negativo, el "NO" va en
   mayúsculas.
7. **Autosuficiencia**: la pregunta se responde con la teoría de **su
   sección**. Si necesita otra sección, o cambia de sección o es una
   pregunta puente del test de módulo.
8. **Un ítem por pregunta.** Nada de preguntas que evalúan tres datos a
   la vez.
9. **Sin referencias a la convocatoria** ni al número de tema.

### Formato

```json
{
  "enunciado": "Transcurrido el plazo máximo sin notificación expresa en un procedimiento iniciado a solicitud del interesado, el silencio administrativo será, como regla general:",
  "opciones": [
    { "texto": "Estimatorio",  "correcta": true  },
    { "texto": "Desestimatorio", "correcta": false },
    { "texto": "Estimatorio solo si lo prevé una norma con rango de ley", "correcta": false },
    { "texto": "Produce la caducidad del procedimiento", "correcta": false }
  ],
  "explicacion": "El art. 24.1 de la Ley 39/2015 fija el silencio positivo como regla general a solicitud del interesado. La caducidad opera en procedimientos iniciados de oficio con efectos desfavorables, no aquí."
}
```

Se cargan con `admin_crear_pregunta(p_seccion_id, p_enunciado,
p_opciones, p_explicacion)` o `importar_pregunta(...)`. Ambas
deduplican por `hash_contenido` (md5 del enunciado normalizado): un
enunciado idéntico **no** crea fila nueva.

---

## F6 · Control de calidad

### Automático

| Control | Herramienta | Umbral |
|---|---|---|
| Duplicados semánticos | `embeddings/detectar_duplicados.py` → `propuestas_fusion` | coseno ≥ 0,90 dentro de la misma sección |
| Tamaño de pool | Consulta sobre `preguntas` agrupada por `seccion_id` | ≥ 25 |
| Preguntas sin explicación | `explicacion IS NULL` | 0 |
| Opciones mal formadas | Validación de `admin_crear_pregunta` | ninguna opción correcta → error |
| Recuento de palabras | Contra el bloque `aprentix:meta` | 350–1.100 |

### Manual

Aplica las tres checklists antes de publicar:

- Estructura → `ESTRUCTURA_CONTENIDO.md` § 6
- Teoría → `PLANTILLA_TEORIA.md` § 6
- Cierre teoría–test → `PLANTILLA_TEORIA.md` § 2.3

### Revisión cruzada obligatoria del cierre teoría–test

Toma la lista de "Retén esto" y el pool de preguntas de la sección y
construye esta matriz. Ninguna celda puede quedar vacía:

| Ítem (viñeta de "Retén esto") | Preguntas que lo evalúan |
|---|---|
| Regla general: silencio positivo | 5 |
| Excepción: responsabilidad patrimonial | 3 |
| … | … |

Y a la inversa: toda pregunta debe apuntar a un ítem. Las preguntas
huérfanas señalan teoría incompleta; los ítems sin preguntas señalan
contenido que sobra o pool incompleto.

---

## F7 · Publicación

Publicar es **mergear en el repo de contenido y correr el publicador**. No
se sube nada a mano: el repo (git) es la fuente de la verdad y la BD es la
copia que sirve la app.

```bash
cd db/publicacion

# 1. Simulacro. Lee, compara con lo publicado y enseña el plan. No escribe.
python3 publicar.py --contenido ../../../oposiciones \
                    --db "postgres://aprentix@localhost:5432/aprentix_desa"

# 2. Si el plan cuadra:
python3 publicar.py --contenido ../../../oposiciones --db "…" --aplicar
```

Publica de una pasada la estructura, la teoría y las preguntas. Es
idempotente: lo que no ha cambiado no se toca. El detalle completo —
estructura del repo, flags y salvaguardas — está en
`db/publicacion/README.md`.

### 7.1 De dónde sale cada cosa

| En la app | Sale de |
|---|---|
| Identidad (slug) | El bloque `aprentix:meta` |
| Nombre visible | El `# H1` del markdown |
| Orden | `orden:` del meta |
| `min_aprobado`, `n_preg_test` | El meta; si faltan, se respeta lo que ya hay |
| Teoría / esquema | El cuerpo del `.md`, tal cual, en `documentos.contenido` |
| Preguntas | El `preguntas.json` de cada sección |
| Oposición y orden de sus temas | `oposiciones/<slug>.yaml` |

El YAML de oposición hace falta porque el orden de los temas no se deduce
de las rutas: un mismo tema se comparte entre oposiciones y ocupa distinta
posición en cada una (P5, independencia de la convocatoria).

### 7.2 Qué protege el progreso

El progreso de cada usuario cuelga de `secciones.id`. Todo lo demás se
deriva de proteger ese uuid:

- **El slug es la identidad; el nombre es una etiqueta.** Renombrar una
  oposición, un tema, un módulo o una sección es un `UPDATE`. Reordenar,
  también. Nadie pierde nada.
- **El slug no se cambia.** Cambiarlo convierte la sección en otra: la
  vieja se archiva con el progreso dentro y la nueva nace a cero.
- **Aquí no se borra.** Lo que desaparece del repo se archiva con
  `--archivar-ausentes`: sale del home y de los tests, y conserva el
  historial. Volver a añadirlo lo desarchiva.
- **Hay un freno.** Si la publicación fuese a retirar una parte grande del
  temario —y sobre todo si crea casi tantas secciones como archiva, que es
  la huella de un cambio de slugs— el script para antes de escribir.

### 7.3 Orden de publicación

Una sola pasada del publicador ya respeta el orden correcto
(estructura → documentos → preguntas). Lo que sigue siendo manual:

1. Publicar (`--aplicar`).
2. Esperar al worker de embeddings y revisar `propuestas_fusion`.
3. Asignar el tema a la oposición: basta con añadir su slug a la lista
   `temas:` del YAML y volver a publicar.

> No metas un tema en el YAML de una oposición hasta que sus secciones
> tengan teoría **y** pool ≥ 25. Una sección sin preguntas hace que
> `iniciar_intento_seccion` falle con `sin_preguntas` y rompe el plan
> diario del usuario.

### 7.4 Parches urgentes

El panel de admin sigue permitiendo sobrescribir la teoría de una sección
a mano, para un arreglo que no puede esperar a un PR. Queda marcada como
`origen = 'manual'` y **la siguiente publicación no la pisa**: la reporta y
sigue. Cuando el arreglo esté en git, publica con `--forzar`.

---

## F8 · Mantenimiento

### Cuando cambia una norma

1. Busca en los bloques `fuentes:` de todos los `teoria.md` el
   identificador de la norma afectada.
2. Revisa esas secciones: ítems, "Retén esto" y "Cómo cae en el examen".
3. Corrige la teoría y **actualiza `actualizado` en el meta**.
4. Revisa las preguntas del pool afectadas. Editar el enunciado cambia
   `hash_contenido`; editar solo opciones o explicación, no.
5. Si un dato desaparece de la norma, quita sus preguntas del
   `preguntas.json` y publica con `--archivar-ausentes`: una pregunta sobre
   normativa derogada es peor que no tener pregunta. Se archivan, no se
   borran, así que las respuestas que ya dio la gente siguen contando en su
   historial.

### Cuando las métricas señalan una sección

`MOTOR_ADAPTATIVO.md` § 4 define los umbrales que devuelven una sección
a este pipeline. Resumen:

| Señal global | Diagnóstico probable | Acción |
|---|---|---|
| Acierto medio < 50 % de forma estable | Teoría insuficiente o sección demasiado densa | Reescribir o dividir |
| Acierto medio > 92 % | Sección trivial | Fundir con la vecina o subir el nivel de las preguntas |
| Tiempo real p50 > 18 min | Sección sobredimensionada | Dividir (viola P1) |
| Abandono > 25 % | Carga cognitiva excesiva | Dividir y revisar el "Desarrollo" |
| Pregunta con discriminación negativa | Pregunta mal formulada o respuesta mal marcada | Corregir o retirar |
