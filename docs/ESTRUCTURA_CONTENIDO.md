# Estructura del contenido — tema, módulo y sección

Reglas para dividir cualquier temario en la jerarquía de Aprentix
(`temas` → `modulos` → `secciones` → `preguntas`) de forma que el
resultado sea **homogéneo entre oposiciones, reutilizable y estudiable
en sesiones de 10–15 minutos**.

Deriva de `METODOLOGIA.md` (P1 Atomicidad, P5 Independencia de la
convocatoria).

---

## 1. La unidad de medida: la sección

Todo el sistema está calibrado sobre una constante:

> **Una sección = una sesión de estudio completa de 10 a 15 minutos:
> leer la teoría, autocomprobar y hacer el test de 10 preguntas.**

De ahí sale todo lo demás. Esta es la aritmética exacta:

| Componente | Regla de cálculo | Tiempo |
|---|---|---|
| Lectura de teoría | palabras ÷ **130 ppm** (velocidad de lectura de estudio en español sobre texto normativo denso) | 5–7 min |
| Autochequeo | 2–3 preguntas abiertas | 1–2 min |
| Test de sección | `n_preg_test` × **30 s** (responder + leer la explicación) | 5 min |
| **Total** | | **11–14 min** |

Corrección para contenido tabular: si más del 40 % del cuerpo son tablas
o listas de datos, multiplica el tiempo de lectura por **1,3** (se lee
más despacio y se releé).

### 1.1 Presupuesto de una sección

| Magnitud | Mínimo | **Objetivo** | Máximo duro |
|---|---:|---:|---:|
| Palabras de teoría | 350 | **700–900** | 1.100 |
| Ítems evaluables (datos memorizables) | 5 | **6–9** | 12 |
| Preguntas en el pool | 25 | **35** | — |
| `n_preg_test` | 8 | **10** | 15 |
| `min_aprobado` | 60 | **70** | 80 |

- **Por debajo de 350 palabras o 5 ítems** → funde la sección con la
  contigua. Excepción: secciones de datos puros (tablas de plazos,
  cuantías, composiciones de órganos) que sí funcionan con poco texto.
- **Por encima de 1.100 palabras o 12 ítems** → divide en dos secciones.
  No hay una tercera opción; recortar el contenido esencial no vale.
- **Pool < 25 preguntas**: el sorteo aleatorio (`_sortear_preguntas`)
  empieza a repetir y el usuario memoriza el orden, no el contenido.
  Objetivo: ≈3,5 × `n_preg_test`, es decir ~35, o 3–5 preguntas por ítem
  evaluable.

### 1.2 Qué es un "ítem evaluable"

Un hecho que se puede convertir en pregunta de test por sí solo:

- una definición ("qué es el silencio administrativo positivo"),
- un plazo, una cuantía, una mayoría, un número,
- una competencia o atribución ("a quién corresponde X"),
- una excepción a una regla,
- una relación jerárquica o de procedimiento ("qué va antes de qué").

Contar los ítems evaluables **antes** de escribir es la forma de saber
si la sección tiene el tamaño correcto. Es también la entrada del
pipeline (`PIPELINE_CREACION.md` § 2).

---

## 2. La diferencia entre módulo y sección

Es la pregunta clave y tiene una respuesta operativa, no estética.

> **La sección es la unidad de EVALUACIÓN. El módulo es la unidad de
> SENTIDO.**

| | Sección | Módulo |
|---|---|---|
| Responde a | "¿Qué tengo que saber?" | "¿Por qué esto va junto?" |
| Contenido propio | `teoria.md` (texto que se estudia) | `esquema.md` (mapa que se ojea) |
| Evaluación | Test directo de su propio pool | Test agregado de sus secciones |
| Se completa | Superando `min_aprobado` | Cuando todas sus secciones están completas |
| Tamaño | 1 idea nuclear, 10–15 min | 3–5 secciones, 40–60 min |
| Prueba de existencia | Se puede escribir una pregunta que se responda **solo** con ella | Sus secciones comparten una **misma fuente o lógica**, y separarlas perdería el hilo |

### 2.1 Test de decisión: ¿esto es una sección o un módulo?

Aplica en orden. La primera respuesta afirmativa decide.

1. **¿Supera los 15 minutos (teoría + test)?**
   → Es un módulo (o una sección que hay que partir).
2. **¿Contiene más de una idea nuclear, es decir, no lo puedes resumir
   en una frase de ≤ 20 palabras sin usar "y" para unir cosas distintas?**
   → Es un módulo.
3. **¿Necesita dos niveles de encabezado con contenido sustantivo
   (`##` con varios `###` que podrían estudiarse por separado)?**
   → Es un módulo, y esos `###` son sus secciones.
4. **¿Genera de forma natural más de 15 preguntas realmente distintas
   entre sí (no variaciones de la misma)?**
   → Es un módulo.
5. **¿Un usuario podría completarlo sin volver atrás a consultar otra
   parte del mismo bloque?**
   → Sí: es una sección. No: falta el encuadre → agrúpalo en un módulo.

### 2.2 Casos límite

| Situación | Resolución |
|---|---|
| El tema no tiene subdivisiones naturales (≤ 6 secciones) | Un solo módulo con `es_unico = true`. La UI lo pinta colapsado. |
| Un módulo se queda con una sola sección | No es un módulo. O la fusionas con el módulo vecino, o la sección era en realidad un módulo mal dimensionado. |
| Una sección "gigante" que no se puede partir sin romper el sentido (p. ej. un procedimiento con 12 fases encadenadas) | Se convierte en módulo y sus fases en secciones agrupadas por bloques de 3–4 fases. El hilo se preserva en el `esquema.md` del módulo. |
| Contenido puramente enumerativo muy largo (listado de 40 órganos) | Divide por criterio semántico (ámbito, jerarquía, función), no por cantidad. Nunca "Parte 1 / Parte 2". |

---

## 3. Cuántos módulos y cuántas secciones

Los rangos no son arbitrarios: salen de mantener los tests agregados en
duraciones razonables, dado `preguntas_por_nodo()`.

```
seccion → n_preg_test              (10 por defecto)
modulo  → round(10 + 8·√N_secciones)
tema    → round(15 + 10·√N_secciones)
```

### 3.1 Módulo

| Magnitud | Mínimo | **Objetivo** | Máximo |
|---|---:|---:|---:|
| Secciones | 2 | **3–5** | 7 |
| Tiempo total de estudio | 25 min | **40–60 min** | 90 min |
| Test de módulo (calculado) | 21 preg. | **24–28 preg.** | 31 preg. |
| Duración del test de módulo | 10 min | **12–14 min** | 16 min |

> Con 4 secciones: `round(10 + 8·√4)` = **26 preguntas** ≈ 13 min. Es
> exactamente el tamaño de un bloque del plan diario. Por eso 3–5 es el
> objetivo.

**Más de 7 secciones** en un módulo: el test agregado pasa de 31
preguntas y entra en zona de fatiga; además el `esquema.md` deja de
caber en una pantalla. Divide en dos módulos.

### 3.2 Tema

| Magnitud | Mínimo | **Objetivo** | Máximo |
|---|---:|---:|---:|
| Módulos | 1 (`es_unico`) | **3–5** | 7 |
| Secciones totales | 4 | **12–20** | 28 |
| Tiempo total de estudio | 1 h | **2,5–4 h** | 6 h |
| Test de tema (calculado) | 35 preg. | **50–60 preg.** | 68 preg. |
| Duración del test de tema | 18 min | **25–30 min** | 34 min |

> Con 4 módulos × 4 secciones = 16 secciones:
> `round(15 + 10·√16)` = **55 preguntas** ≈ 27 min. Es una sesión de
> consolidación de fin de bloque, no una sesión diaria.

**Más de 28 secciones**: el test de tema supera los 34 min y deja de ser
utilizable; el tema es en realidad dos temas. Divide por fuente
normativa o por bloque conceptual.

### 3.3 Tabla de referencia rápida

| Nivel | Cantidad de hijos | Contenido propio | Test | Duración de la sesión |
|---|---|---|---|---|
| **Tema** | 3–5 módulos | `esquema.md` (400–700 pal.) | 50–60 preg. | 25–30 min (consolidación) |
| **Módulo** | 3–5 secciones | `esquema.md` (200–400 pal.) | 24–28 preg. | 12–14 min (repaso de bloque) |
| **Sección** | 6–9 ítems | `teoria.md` (700–900 pal.) | 10 preg. (pool ≥ 25) | **10–15 min (unidad diaria)** |

---

## 4. Nomenclatura: independiente de la convocatoria

`oposicion_temas` es M:N por diseño: **un tema se comparte entre
oposiciones**. Completar una sección en una oposición se refleja en
cualquier otra que la incluya, y `sugerir_solapamiento()` explota
justamente eso. Si los nombres se acoplan a una convocatoria, esa
capacidad se pierde.

### 4.1 Regla de oro

> **El nombre describe el OBJETO DE CONOCIMIENTO, no la convocatoria que
> lo exige.**

Un tema no es "el tema 7 de Auxilio Judicial": es "Organización del
Poder Judicial". Que en una convocatoria sea el 7 y en otra el 12 es
información de `oposicion_temas.orden`, no del nombre.

### 4.2 Test de portabilidad (3 preguntas, obligatorio antes de crear)

1. **¿Seguiría siendo correcto este nombre si mañana otra oposición
   distinta incluyera el mismo contenido?**
2. **¿Contiene número de tema, bloque, parte, cuerpo, escala, grupo,
   subgrupo o año de convocatoria?** → Renombrar.
3. **¿Un opositor de otra administración entendería qué hay dentro sin
   leer las bases?**

Si alguna respuesta falla, el nombre no vale.

### 4.3 Formatos válidos

**Tema** — elige el patrón según la naturaleza de la fuente:

| Naturaleza | Patrón | Ejemplo |
|---|---|---|
| Norma | `<Denominación corta> (<referencia legal>)` | `Procedimiento Administrativo Común (Ley 39/2015)` |
| Institución u órgano | `<Institución>` | `La Corona` · `El Tribunal Constitucional` |
| Materia técnica | `<Materia>: <ámbito>` | `Ofimática: procesador de textos` |
| Bloque conceptual | `<Concepto>` | `Igualdad efectiva de mujeres y hombres` |

**Módulo** — debe expresar el **criterio de agrupación**:

```
✅ Título I: derechos y deberes fundamentales
✅ Iniciación del procedimiento
✅ Órganos de gobierno del Estado
❌ Módulo 2            ← no dice nada
❌ Parte general       ← no dice nada
❌ Continuación (II)   ← partición por cantidad, no por sentido
```

**Sección** — `<Concepto> (<anclaje>)`, el ancla entre paréntesis:

```
✅ Derechos fundamentales y libertades públicas (arts. 14–29)
✅ Silencio administrativo positivo
✅ Plazos de resolución y cómputo
❌ Artículos 14 al 29  ← describe el envase, no el contenido
❌ Sección 3           ← el orden ya vive en `secciones.orden`
```

**Longitudes máximas:** tema 60 caracteres, módulo 50, sección 60. Si no
cabe, es que el nombre está describiendo demasiadas cosas.

### 4.4 La excepción legítima de especificidad

Hay contenidos cuyo objeto de conocimiento **es intrínsecamente
específico** de una administración. Ahí el nombre específico es correcto
y no supone acoplamiento.

**Criterio de decisión, verificable:**

> Si el nombre específico aparece como **título de la norma o
> denominación oficial del órgano** en un boletín oficial (BOE, boletín
> autonómico, BOCM…), es válido.
> Si solo aparece en las **bases de una convocatoria**, no lo es.

| ✅ Válido (la fuente es específica) | ❌ Inválido (la convocatoria es específica) |
|---|---|
| `Ley 22/2006 de Capitalidad y de Régimen Especial de Madrid` | `Tema 4 Administrativo Ayto. Madrid` |
| `Reglamento Orgánico del Gobierno y de la Administración del Ayuntamiento de Madrid` | `Bloque específico Madrid` |
| `Estatuto de Autonomía de la Comunidad de Madrid` | `Parte autonómica (turno libre 2026)` |
| `Estatuto Básico del Empleado Público (RDL 5/2015)` | `Función pública C2` |

### 4.5 Correspondencia con las bases de cada oposición

Las bases de cada convocatoria llaman a lo mismo de forma distinta. Eso
es un problema de **presentación**, no de modelo de datos.

**Cómo se resuelve hoy** (sin tocar el esquema):

- El nombre canónico manda siempre.
- El orden por oposición vive en `oposicion_temas.orden`.
- La correspondencia "epígrafe de las bases → tema canónico" se
  documenta en `docs/mapeos/<oposicion>.md` con esta tabla:

  ```markdown
  | # bases | Epígrafe literal de las bases | Tema canónico | Módulos incluidos |
  |---|---|---|---|
  | 7 | "La Constitución Española de 1978: estructura y contenido" | Constitución Española de 1978 | Todos |
  | 8 | "Organización territorial del Estado" | Constitución Española de 1978 | Título VIII |
  ```

  Sirve para auditar cobertura frente a las bases y para responder al
  usuario "¿esto cubre mi temario?".

**Evolución recomendada del esquema** (ver `MOTOR_ADAPTATIVO.md` § 7):
añadir a `oposicion_temas` las columnas `alias_bases text` y
`epigrafe text`, de forma que la UI pueda mostrar el nombre de las bases
sin contaminar el catálogo canónico.

### 4.6 Cuando dos oposiciones piden la misma fuente con distinta
profundidad

Asignar un tema arrastra todos sus módulos. Regla de decisión:

| Solapamiento de contenido | Decisión |
|---|---|
| **≥ 60 %** | **Un solo tema compartido.** Los módulos que solo exige la oposición más amplia van al final, en orden, y su `esquema.md` los marca como ampliación. El coste (algún módulo de más) es menor que duplicar el banco de preguntas. |
| **< 60 %** | **Dos temas distintos**, nombrados por su alcance real: `Constitución Española: parte dogmática` y `Constitución Española: organización territorial`. |

Nunca duplicar un tema con el mismo contenido y distinto nombre: rompe
el progreso compartido y la deduplicación por `hash_contenido`.

---

## 5. Orden interno

- **Módulos dentro del tema** (`modulos.orden`): secuencia didáctica, no
  necesariamente el orden de la norma. Primero lo que da marco, después
  lo que depende de ello. Si la norma ya está bien ordenada, respétala.
- **Secciones dentro del módulo** (`secciones.orden`): estrictamente
  progresivo. La sección *n* puede exigir la *n−1* como prerrequisito,
  nunca al revés (continuidad de Dewey).
- **Prerrequisitos entre módulos o temas**: se declaran en el campo
  `Antes de esto` de la cabecera de la sección. Si un prerrequisito
  cruza de tema, revisa la división: probablemente los dos temas son uno.

---

## 6. Checklist de validación estructural

Antes de dar por buena la estructura de un tema:

- [ ] Cada sección se completa en 10–15 min con la aritmética de § 1.
- [ ] Ninguna sección baja de 350 palabras ni supera 1.100.
- [ ] Cada sección tiene 5–12 ítems evaluables y ≥ 25 preguntas en pool.
- [ ] Cada módulo tiene entre 2 y 7 secciones (objetivo 3–5).
- [ ] Ningún módulo tiene una sola sección salvo `es_unico = true`.
- [ ] El tema tiene entre 1 y 7 módulos y ≤ 28 secciones.
- [ ] El test de tema calculado no supera las 68 preguntas.
- [ ] Los nombres de tema y módulo pasan el test de portabilidad (§ 4.2).
- [ ] Los nombres específicos, si los hay, cumplen el criterio del
      boletín oficial (§ 4.4).
- [ ] Existe `esquema.md` de tema y de cada módulo, y `teoria.md` de
      cada sección.
- [ ] El orden de secciones respeta los prerrequisitos declarados.
