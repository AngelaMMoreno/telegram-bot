# Formato de la teoría — plantillas markdown

Formato **obligatorio y literal** de los tres documentos que la app
sirve desde la tabla `documentos`:

| Nivel | Tipo | Fichero | Función |
|---|---|---|---|
| `seccion` | `teoria` | `teoria.md` | El contenido que se estudia. |
| `modulo` | `esquema` | `esquema.md` | Mapa del bloque: encuadre y cierre. |
| `tema` | `esquema` | `esquema.md` | Mapa del tema completo. |

La rigidez del esqueleto es deliberada (P4, control de estímulos de
Skinner): el usuario siempre sabe dónde está cada cosa, y eso reduce el
coste de arrancar una sesión.

---

## 1. Restricciones técnicas del renderizador

La SPA renderiza con **`marked` + `DOMPurify`** (`renderMarkdown()` en
`web/estudio/app.js`). En la práctica:

| Sí se puede | No usar |
|---|---|
| Encabezados `#`–`####` | Front-matter YAML `---` (se renderiza como línea + texto suelto) |
| **Negrita**, *cursiva*, `código` | LaTeX / MathJax (no hay renderizador) |
| Listas ordenadas y no ordenadas, anidadas | Scripts, iframes, estilos inline (DOMPurify los elimina) |
| Tablas GFM | Imágenes remotas (sin política de assets aún) |
| Citas `>` | HTML complejo o clases CSS propias |
| `<details>` / `<summary>` | Enlaces a ficheros fuera de `/mnt/data/ficheros` (PDFs y adjuntos; el markdown ya no vive ahí) |
| Enlaces relativos entre documentos | |

**Metadatos:** van en un comentario HTML al principio del fichero. Es
invisible en el render y legible por herramientas.

---

## 2. Plantilla de sección (`teoria.md`)

Copiar tal cual. Los ocho apartados son **obligatorios y en este
orden**. Ninguno se omite.

> **Los tres slugs del meta son la identidad del contenido.** El
> publicador casa cada sección por `tema`/`modulo`/`seccion`, así que:
>
> - El `# Título` y el `nombre` de cualquier nodo se pueden **cambiar
>   cuando quieras**: es un `UPDATE` y no afecta a nadie.
> - El `orden` también: reordenar no toca ninguna identidad.
> - **El slug no se cambia.** Cambiarlo convierte la sección en otra
>   distinta: la vieja se archiva con el progreso de quien la estudió
>   dentro, y la nueva nace vacía. Si de verdad hace falta, se hace con un
>   `UPDATE` sobre la columna `slug` y se publica después.
>
> La ruta del fichero tiene que reflejar esos mismos slugs
> (`temas/<tema>/<modulo>/<seccion>/teoria.md`). Si no coinciden, el
> publicador para: ver `db/publicacion/README.md`.

````markdown
<!-- aprentix:meta
version: 1
nivel: seccion
tema: <slug-del-tema>
modulo: <slug-del-modulo>
seccion: <slug-de-la-seccion>
orden: <n>
min_aprobado: 70
n_preg_test: 10
fuentes:
  - "<Norma o documento, artículos, identificador oficial>"
actualizado: AAAA-MM-DD
palabras: <n>
items_evaluables: <n>
preguntas_pool: <n>
-->

# <Nombre de la sección>

> **Objetivo** · <Qué sabrás hacer al terminar. Una frase, ≤ 25 palabras.>
> **Antes de esto** · <Sección prerrequisito | Nada>
> **Tiempo** · <X> min de teoría + <Y> min de test

## Por qué importa

<40–70 palabras. Un caso, una situación o una pregunta real. NUNCA
empieza con una definición. Es el gancho experiencial de Dewey: primero
el problema, después el concepto.>

## La idea clave

<50–80 palabras. El núcleo de la sección, comprensible por sí solo. Si
el usuario solo leyera esto, ya sabría de qué va. Los términos que van a
examen, en **negrita**.>

## Desarrollo

<350–550 palabras, el cuerpo. Se organiza en 2–4 subapartados `###`.
Regla: lo comparable va en tabla, lo enumerable va en lista, lo
explicativo va en prosa corta. Párrafos de 3–5 líneas como máximo.>

### <Subapartado 1>

### <Subapartado 2>

## Cómo cae en el examen

<Tabla obligatoria, 3–6 filas. Conecta el contenido con la práctica real
(interacción, Dewey) y aísla lo que discrimina (Ericsson).>

| Dato que se pregunta | Forma habitual del enunciado | Cómo acertar |
|---|---|---|
| | | |

## No lo confundas

<Tabla obligatoria, mínimo 2 filas. Son las confusiones reales, no
matices teóricos. Estas filas son la FUENTE DE LOS DISTRACTORES de las
preguntas: lo que aquí se declara confundible es lo que aparece como
opción incorrecta. Cierra el bucle Skinner (discriminación de estímulos)
con el banco de preguntas.>

| ❌ Se confunde con | ✅ Lo correcto | Diferencia en una frase |
|---|---|---|
| | | |

## Retén esto

<5–9 viñetas atómicas, literales y memorizables (12 como tope absoluto):
UNA POR ÍTEM EVALUABLE, autocontenida, sin pronombres que dependan del
texto anterior. Son las tarjetas del repaso espaciado.>

- **<Concepto>:** <dato exacto>
- **<Concepto>:** <dato exacto>

## Compruébalo tú mismo

<2–3 preguntas abiertas con la respuesta plegada. El usuario debe
PRODUCIR la respuesta antes de verla: es la intervención metacognitiva
de Flavell y no se sustituye por el test de opción múltiple.>

**1. <Pregunta abierta>**

<details>
<summary>Ver respuesta</summary>

<Respuesta en 1–2 líneas.>

</details>

**2. <Pregunta abierta>**

<details>
<summary>Ver respuesta</summary>

<Respuesta en 1–2 líneas.>

</details>

## Fuente

- <Norma consolidada, artículos concretos, identificador oficial>
- <Guía o documento oficial, con fecha de la versión>
````

### 2.1 Función de cada apartado

| Apartado | Autor | Función | Palabras |
|---|---|---|---:|
| Cabecera `>` | Flavell | Planificación: qué, desde dónde, cuánto | 25 |
| Por qué importa | Dewey | Experiencia y problema antes que concepto | 40–70 |
| La idea clave | Ericsson | Aísla la sub-habilidad que se va a practicar | 50–80 |
| Desarrollo | — | El contenido | 350–550 |
| Cómo cae en el examen | Dewey + Ericsson | Interacción con la situación real; foco en lo discriminante | 60–100 |
| No lo confundas | Skinner + Flavell | Discriminación de estímulos; corrige la mala calibración | 50–90 |
| Retén esto | Ericsson + Ebbinghaus | Chunking para el repaso espaciado | 60–110 |
| Compruébalo tú mismo | Flavell + Dewey | Monitorización activa y reflexión | 60–100 |
| Fuente | — | Trazabilidad y actualización cuando cambie la norma | 15–30 |
| **Total** | | | **700–900 (tope duro 1.100)** |

Si la suma de los máximos te lleva por encima de 1.100 palabras, el
recorte sale del **Desarrollo**, nunca de "Retén esto" ni de "No lo
confundas": esos dos apartados son los que sostienen el banco de
preguntas.

### 2.2 Reglas de redacción

1. **Segunda persona.** "Cuando presentes un recurso…", no "El
   interesado, cuando presente…". Se dirige al usuario, no describe el
   mundo.
2. **Frases cortas.** Máximo 25 palabras. La teoría no es la norma: la
   norma ya está en el BOE.
3. **Nunca copies literalmente artículos largos.** Cita el artículo,
   explica qué dice. Si hay que reproducir literalmente un texto (una
   definición legal, una fórmula), va en `> cita` y no supera 3 líneas.
4. **Negrita solo para términos evaluables.** Si todo está en negrita,
   nada lo está. Máximo ~15 negritas por sección.
5. **Los números siempre en cifra**: "3 meses", no "tres meses". Los
   plazos y cuantías son lo que más se pregunta y deben saltar a la
   vista.
6. **Sin "como ya sabemos", "obviamente", "es evidente".** Presuponen
   dominio y desactivan la monitorización (Flavell).
7. **Cero referencias a la convocatoria** dentro de la teoría (P5). Nada
   de "este tema cae en el examen de Auxilio Judicial".
8. **Cada viñeta de "Retén esto" debe entenderse fuera de contexto**,
   porque se mostrará suelta en repasos.

### 2.3 El cierre teoría–test (P2)

Verificación obligatoria antes de publicar:

- Cada viñeta de **Retén esto** tiene ≥ 2 preguntas en el pool.
- Cada fila de **No lo confundas** genera ≥ 1 pregunta cuyo distractor
  es precisamente esa confusión.
- Ninguna pregunta del pool exige un dato que no esté en la teoría de
  esta sección (ni en otra: la sección debe ser autosuficiente).
- Ningún párrafo del **Desarrollo** queda sin ninguna pregunta asociada.
  Si sobra contenido, o se convierte en pregunta o se elimina.

---

## 3. Plantilla de módulo (`esquema.md`)

Es el **encuadre** (Dewey: el todo antes de la parte) y el cierre del
bloque. Se ojea, no se estudia: 200–400 palabras.

````markdown
<!-- aprentix:meta
version: 1
nivel: modulo
tema: <slug-del-tema>
modulo: <slug-del-modulo>
actualizado: AAAA-MM-DD
-->

# <Nombre del módulo>

> **Qué agrupa** · <Criterio de agrupación en una frase: la fuente
> común, el bloque conceptual o la fase del procedimiento.>
> **Secciones** · <N> · **Tiempo total** · <N × 12> min aprox.

## El hilo conductor

<60–100 palabras. Por qué estas secciones van juntas y en este orden.
Si no puedes explicarlo, el módulo está mal formado.>

## Mapa del módulo

1. **<Sección 1>** — <qué resuelve, 1 línea>
2. **<Sección 2>** — <qué resuelve, 1 línea>
3. **<Sección 3>** — <qué resuelve, 1 línea>

## Cuando termines sabrás

- <Capacidad concreta y verificable, en verbo de acción>
- <Capacidad concreta y verificable>
- <Capacidad concreta y verificable>

## Preguntas puente

<2–3 preguntas que NINGUNA sección responde por sí sola: exigen combinar
dos o más. Son las que justifican que el módulo exista y las que el test
de módulo debe incluir.>

- <Pregunta que cruza las secciones 1 y 3>
- <Pregunta que cruza las secciones 2 y 4>
````

> Si no consigues escribir al menos 2 **preguntas puente**, el módulo no
> aporta sentido: sus secciones son independientes y deberían colgar de
> otro módulo o reagruparse.

---

## 4. Plantilla de tema (`esquema.md`)

400–700 palabras. Es lo primero que ve el usuario al abrir el tema y lo
que consulta al final para consolidar.

````markdown
<!-- aprentix:meta
version: 1
nivel: tema
tema: <slug-del-tema>
actualizado: AAAA-MM-DD
-->

# <Nombre del tema>

> **De qué va** · <Una frase. Qué objeto de conocimiento cubre.>
> **Módulos** · <N> · **Secciones** · <N> · **Tiempo total** · <N> h aprox.

## Qué vas a estudiar y por qué

<80–120 palabras. El sentido del tema completo. Para qué sirve saber
esto, no solo qué contiene.>

## Estructura

| # | Módulo | Secciones | Qué cubre |
|---|---|---:|---|
| 1 | <Módulo> | <n> | <1 línea> |
| 2 | <Módulo> | <n> | <1 línea> |

<Si algún módulo solo lo exigen determinadas convocatorias, indícalo
aquí como **ampliación**, sin nombrar la oposición: "Ampliación: solo
necesario si tu temario incluye X".>

## Orden recomendado

<Explica la secuencia si no es el orden natural de la norma, y qué
módulo depende de cuál. 40–80 palabras.>

## Antes de empezar

- **Necesitas haber visto:** <Tema prerrequisito | Nada>
- **Se apoya en:** <Conceptos previos que conviene tener frescos>

## Vocabulario mínimo

| Término | Significado en una línea |
|---|---|
| | |

<5–10 términos. Es el glosario que el usuario consulta mientras estudia
las secciones.>

## Fuentes del tema

- <Norma consolidada principal, con identificador oficial y fecha>
- <Normas secundarias>
- <Guías técnicas o documentación oficial del organismo>
````

---

## 5. Ejemplo completo de sección

Ejemplo real y publicable, para calibrar el tono y la densidad.

````markdown
<!-- aprentix:meta
version: 1
nivel: seccion
tema: procedimiento-administrativo-comun-ley-39-2015
modulo: terminacion-del-procedimiento
seccion: silencio-administrativo
fuentes:
  - "Ley 39/2015, arts. 21, 24 y 25 (BOE-A-2015-10565)"
actualizado: 2026-07-29
palabras: 810
items_evaluables: 7
preguntas_pool: 34
-->

# Silencio administrativo

> **Objetivo** · Determinar si la falta de respuesta de la Administración
> te da la razón o te la quita, y desde cuándo.
> **Antes de esto** · Plazos de resolución y cómputo
> **Tiempo** · 6 min de teoría + 5 min de test

## Por qué importa

Pides una licencia en enero. Pasan seis meses y nadie te contesta. ¿Puedes
abrir el negocio o no? ¿Y si en el mes siete te llega una denegación,
sirve de algo? La respuesta no depende de la buena voluntad de nadie: está
tasada en la ley, y cambia por completo según quién iniciara el
procedimiento.

## La idea clave

La Administración **está obligada a resolver siempre**. Si no lo hace en
plazo, la ley asigna un efecto por defecto: el **silencio administrativo**.
En procedimientos iniciados **a solicitud del interesado** el silencio es
por regla general **positivo** (estimatorio); en los iniciados **de
oficio** que puedan dar lugar a efectos desfavorables, es **negativo**
(desestimatorio) y se produce la caducidad.

## Desarrollo

### Procedimientos iniciados a solicitud del interesado

La regla general es el **silencio positivo**: vencido el plazo sin
notificación expresa, entiendes estimada tu solicitud. Las excepciones,
que producen silencio negativo, son tasadas:

- cuando una **norma con rango de ley** o una norma de **Derecho de la
  Unión Europea** lo establezca;
- procedimientos de **derecho de petición** (art. 29 CE);
- procedimientos cuya estimación transfiera al solicitante **facultades
  sobre el dominio público** o el servicio público;
- procedimientos de **impugnación de actos** y de **revisión de oficio**;
- procedimientos de **responsabilidad patrimonial**.

Hay una contraexcepción que se pregunta mucho: en el **recurso de alzada**
contra una desestimación por silencio, si vuelve a transcurrir el plazo
sin resolver, el silencio del recurso es **positivo**.

### Procedimientos iniciados de oficio

- Si podían generar **efectos favorables**: silencio **negativo**.
- Si eran **sancionadores o de intervención** (efectos desfavorables o de
  gravamen): se produce **caducidad**, no silencio.

### Qué valor tiene cada silencio

El silencio **positivo** es un **acto administrativo finalizador** a todos
los efectos: solo puede revisarse por los procedimientos de revisión de
oficio. El silencio **negativo** es una **ficción legal** que solo abre la
vía de recurso; no es un acto. Por eso la Administración **conserva la
obligación de resolver expresamente** y, en el caso del silencio negativo,
puede hacerlo después **en cualquier sentido**; en el positivo, solo puede
resolver de forma **confirmatoria**.

## Cómo cae en el examen

| Dato que se pregunta | Forma habitual del enunciado | Cómo acertar |
|---|---|---|
| Sentido del silencio según quién inicia | "Iniciado a solicitud del interesado, el silencio será…" | Solicitud → positivo; oficio favorable → negativo |
| Las 5 excepciones tasadas | "¿En cuál de los siguientes el silencio NO es estimatorio?" | Memorízalas como lista cerrada de "Retén esto" |
| Silencio en el recurso de alzada | "Interpuesto recurso de alzada contra una desestimación presunta…" | Positivo: es la contraexcepción |
| Naturaleza de cada silencio | "El silencio negativo tiene la consideración de…" | Positivo = acto; negativo = ficción legal |
| Resolución posterior | "Vencido el plazo, la Administración…" | Sigue obligada. Positivo → solo confirmatoria |

## No lo confundas

| ❌ Se confunde con | ✅ Lo correcto | Diferencia en una frase |
|---|---|---|
| Silencio negativo = acto denegatorio | Es una **ficción legal** | Solo existe para que puedas recurrir; no es un acto administrativo |
| Caducidad = silencio | Son figuras distintas | La caducidad archiva el procedimiento; el silencio le da un sentido |
| Todo procedimiento de oficio caduca | Solo los de efectos desfavorables o de gravamen | Los de efectos favorables producen silencio negativo |
| Con silencio positivo ya no hay que resolver | Sigue existiendo la obligación de resolver | Pero solo puede resolverse en sentido confirmatorio |

## Retén esto

- **Regla general a solicitud del interesado:** silencio **positivo**.
- **Excepciones (silencio negativo):** norma con rango de ley o Derecho
  UE, derecho de petición, facultades sobre dominio o servicio público,
  impugnación de actos y revisión de oficio, responsabilidad patrimonial.
- **Recurso de alzada contra desestimación presunta:** silencio
  **positivo**.
- **De oficio con efectos favorables:** silencio **negativo**.
- **De oficio sancionador o de gravamen:** **caducidad**, no silencio.
- **Silencio positivo:** acto finalizador; resolución posterior solo
  confirmatoria.
- **Silencio negativo:** ficción legal; resolución posterior en cualquier
  sentido.

## Compruébalo tú mismo

**1. Solicitas una licencia de obra y pasa el plazo sin respuesta. ¿Qué
tienes y qué puede hacer después la Administración?**

<details>
<summary>Ver respuesta</summary>

Tienes un acto estimatorio por silencio positivo. La Administración sigue
obligada a resolver, pero solo puede hacerlo en sentido confirmatorio; si
quiere dejarlo sin efecto, debe acudir a la revisión de oficio.

</details>

**2. ¿Por qué un procedimiento sancionador que se pasa de plazo no produce
silencio?**

<details>
<summary>Ver respuesta</summary>

Porque es un procedimiento iniciado de oficio con efectos desfavorables:
la ley prevé la caducidad y el archivo, no un sentido presunto.

</details>

## Fuente

- Ley 39/2015, de 1 de octubre, del Procedimiento Administrativo Común de
  las Administraciones Públicas, arts. 21, 24 y 25 (BOE-A-2015-10565,
  texto consolidado).
````

---

## 6. Checklist de publicación de una sección

- [ ] Están los 8 apartados, en orden, con sus nombres literales.
- [ ] El bloque `<!-- aprentix:meta -->` está completo y actualizado.
- [ ] 350 ≤ palabras ≤ 1.100 (objetivo 700–900).
- [ ] La cabecera declara objetivo, prerrequisito y tiempo.
- [ ] "Por qué importa" no empieza con una definición.
- [ ] "No lo confundas" tiene ≥ 2 filas y cada una tiene su distractor
      en el banco de preguntas.
- [ ] "Retén esto" tiene 5–9 viñetas autocontenidas, una por ítem
      evaluable.
- [ ] "Compruébalo tú mismo" tiene 2–3 preguntas con `<details>`.
- [ ] "Fuente" cita norma consolidada e identificador oficial.
- [ ] Se cumple el cierre teoría–test (§ 2.3).
- [ ] Sin referencias a ninguna oposición concreta.
- [ ] El fichero está en `temas/<tema>/<modulo>/<seccion>/teoria.md` y los
      tres slugs del meta coinciden con esa ruta.
- [ ] `publicar.py` sin `--aplicar` lo lista como "crear" o "actualizar",
      no da avisos de formato y no dispara el freno de archivado.
