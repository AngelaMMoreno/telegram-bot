# Directrices para crear etiquetas eficientes

El auto-tagger de Aprentix combina **tres señales** para asignar una
etiqueta a una pregunta o test:

1. **Vectorial (embedding)**: se genera con `BAAI/bge-m3` sobre el
   campo `descripcion`. Se compara por similitud coseno contra el
   embedding del enunciado + opción correcta. Umbral por defecto:
   `0.55`.
2. **Palabras clave**: se buscan literalmente con `ILIKE '%...%'` en
   el enunciado y en el título del test.
3. **Nombre de la etiqueta**: se busca literalmente en el enunciado y
   en el título del test.

Además hay un k-NN sobre las 5 preguntas más parecidas: si varias de
ellas ya tienen la etiqueta, se propaga. Las etiquetas manuales pesan
más que las automáticas, y las bloqueadas jamás se reintroducen.

Con este esquema, cada campo del catálogo tiene un rol distinto y hay
que rellenarlo pensando en QUÉ señal quieres reforzar.

---

## 1. `nombre`

> El nombre es identificador **y** cebo para el ILIKE. Es la única
> señal que se dispara directamente sobre el enunciado.

- **Minúsculas siempre**. El sistema lo normaliza con `lower(btrim(...))`
  antes de guardarlo.
- **Sin espacios raros** ni signos de puntuación.
- **Corto y canónico**: preferible `derecho constitucional` que
  `dº constitucional`; preferible `iva` (que `impuesto valor añadido`),
  porque el enunciado usará esa forma.
- **Singular**, salvo que en el corpus real el término aparezca casi
  siempre en plural (ej. `derechos humanos`).
- **Con acentos si el corpus los usa**. `ILIKE` es case-insensitive
  pero **sí distingue acentos**: `%constitución%` NO encuentra
  `Constitucion` sin tilde. Regla: escribe el nombre como aparece
  escrito habitualmente en tus preguntas.
  Si tu corpus mezcla ambos (con y sin tilde), usa la forma con
  acento en el `nombre` y añade la variante sin acento en
  `palabras_clave`.
- **Evita nombres muy cortos y ambiguos** (`ley`, `art`) porque el
  ILIKE hará match en cualquier pregunta que mencione esas palabras.
  Prefiere `ley orgánica` o `artículo 155`.
- **Un concepto, un nombre**. No metas dos temas en un mismo nombre
  con barras o comas (`derecho civil / mercantil`): créalos por
  separado.

**Ejemplos buenos:**

```
constitución española
derecho administrativo
ley 39/2015
iva
programación orientada a objetos
```

**Ejemplos malos:**

```
CONSTITUCION           ← mayúsculas + sin acento
Const.                 ← abreviatura poco natural
tema 1                 ← no describe el contenido
leyes/normativa        ← dos conceptos
```

---

## 2. `descripcion`

> Este texto es lo ÚNICO que el modelo vectorial ve. Un enunciado con
> embedding cercano al de la descripción entra en el auto-tagger. Si
> la descripción es pobre, el vector es pobre y el clasificador
> también.

- **Escribe en español natural**, en frases completas, como una
  entradilla de temario. `bge-m3` está entrenado sobre texto real:
  cuanto más se parezca a lo que aparece en las preguntas, mejor
  vectoriza.
- **Longitud: 2-6 frases**, unas 40-150 palabras. Menos de 20
  palabras da un vector pobre; más de 300 diluye la señal.
- **Menciona los subtemas** que la etiqueta debería cubrir, incluso
  los que van en etiquetas hijas. La coherencia jerárquica ayuda.
- **Incluye sinónimos y equivalencias**. Si `iva` también se llama
  "impuesto sobre el valor añadido" o "value added tax", méteselos.
  El vector aprende esas equivalencias.
- **Nombra los conceptos técnicos clave**: nombres propios de leyes,
  artículos icónicos, autores, tecnologías. Son los tokens con más
  peso semántico.
- **Escribe con acentos y puntuación correctos**. bge-m3 es
  multilingüe pero fue entrenado con texto bien escrito; el ruido
  ortográfico degrada el vector.
- **No repitas literalmente las palabras clave**. La descripción
  educa el vector; las palabras clave son ILIKE. Duplicar no ayuda.

**Ejemplo bueno** (para la etiqueta `constitución española`):

> La Constitución Española de 1978 es la norma suprema del
> ordenamiento jurídico español. Regula la organización territorial
> del Estado, los derechos fundamentales, las Cortes Generales, el
> Gobierno, el Poder Judicial y la Corona. Incluye el título
> preliminar, los diez títulos principales y las disposiciones
> adicionales, transitorias, derogatorias y finales. Su reforma se
> regula en el título X.

**Ejemplo malo:**

> Constitución.

---

## 3. `palabras_clave`

> Estas se buscan con **ILIKE literal** en enunciado y título del
> test. Son la red de seguridad para preguntas donde el nombre no
> aparece.

- **Todo en minúsculas**. Se normalizan al guardar.
- **`ILIKE` distingue acentos**: si el corpus mezcla `articulo` y
  `artículo`, mete **ambas formas**.
- **Fragmentos frecuentes del enunciado**: sinónimos, siglas,
  nombres de leyes o instituciones, verbos característicos.
- **Palabras únicas o poco ambiguas**. Evita palabras funcionales
  como `este`, `sobre`, `derecho` sueltas: harán match en todo.
  Prefiere combos: `derecho civil`, `código penal`.
- **10-25 palabras clave por etiqueta**. Menos de 5 deja huecos;
  más de 40 mete ruido.
- **Coordina con las hijas**: si una hija tiene la palabra clave
  `spring boot`, no la repitas en el padre `programación` — deja
  que la hija haga su trabajo.
- **No metas el propio `nombre`** de la etiqueta: ya se busca por
  separado.

**Ejemplo bueno** (para `iva`):

```json
["impuesto valor añadido", "impuesto sobre el valor añadido",
 "iva", "sujeto pasivo", "hecho imponible", "base imponible",
 "tipo impositivo", "tipo reducido", "tipo superreducido",
 "operaciones intracomunitarias", "autoliquidación",
 "modelo 303", "modelo 390"]
```

**Ejemplo malo:**

```json
["iva", "impuesto", "administración", "económico"]
```
(`impuesto` y `administración` son demasiado genéricas → falsos
positivos garantizados)

---

## 4. `padre` — jerarquías

> El padre no interviene en la clasificación por sí solo. Su papel
> es agrupar en la SPA (`etiqueta_y_descendientes` expande hacia
> abajo para búsquedas y tests temáticos) y en el `k-NN` (una
> pregunta parecida con etiqueta hija tira también del padre).

**Directrices para etiquetas padre:**

- **El padre debe ser un paraguas real**: cualquier pregunta de
  cualquier hija debería poder llevar también la etiqueta padre
  sin sonar rara.
  - ✅ `programación → java → spring`
  - ✅ `derecho administrativo → procedimiento administrativo → notificaciones`
  - ❌ `ley 39/2015 → art. 21` (`ley 39/2015` es más específico que
    `procedimiento administrativo` — el padre no encaja como
    paraguas conceptual, no jurídico)

- **Descripción del padre = suma abstracta de las hijas.** Debe
  cubrir semánticamente lo mismo que ellas juntas. Así, una
  pregunta que hable de `spring boot` sin nombrar `java`
  igualmente activa `programación` por similitud vectorial.

- **Palabras clave del padre = las que NO están en las hijas.**
  Reserva términos generales para el padre y específicos para las
  hijas. No dupliques.

- **Máximo 3-4 niveles**. Más profundidad no aporta y complica el
  mantenimiento. La jerarquía es organización, no ontología
  exhaustiva.

- **Un solo padre por hija.** El modelo de datos ya lo impone
  (`padre text` no array), pero recuérdalo al diseñar: si una
  etiqueta encaja bajo dos padres, probablemente son dos etiquetas
  distintas (`derecho civil`, `derecho mercantil`) o el padre está
  mal elegido.

- **Nombra al padre por el concepto, no por el nivel.** ❌ `tema 1`,
  `bloque 3`, `unidad 2` son malos padres: no aportan señal
  semántica al vector. ✅ `organización territorial del estado`,
  `contabilidad financiera`.

- **No crees padres vacíos**. Si sólo hay una hija de un padre y
  no vas a añadir más pronto, colapsa: usa sólo la hija.

**Ejemplo de jerarquía correcta** para una oposición de Auxiliar
Administrativo del Estado:

```
constitución española
├── derechos fundamentales
├── organización territorial
├── corona y sucesión
├── cortes generales
├── gobierno y administración
└── poder judicial

derecho administrativo
├── procedimiento administrativo común  (ley 39/2015)
│   ├── inicio del procedimiento
│   ├── instrucción
│   ├── terminación
│   └── recursos administrativos
└── régimen jurídico del sector público  (ley 40/2015)
    ├── órganos administrativos
    └── responsabilidad patrimonial
```

---

## 5. Reglas prácticas resumidas

| Campo | Longitud | Estilo | Para qué se usa |
|---|---|---|---|
| `nombre` | 1-4 palabras | minúsculas, con acentos si el corpus los usa | ILIKE en enunciado + título |
| `descripcion` | 2-6 frases (~40-150 palabras) | prosa natural, con sinónimos y términos técnicos | vector para similitud coseno |
| `palabras_clave` | 10-25 términos | minúsculas, fragmentos multi-palabra específicos, con/sin acento si mezcla | ILIKE en enunciado + título |
| `padre` | uno o ninguno | debe ser un paraguas conceptual real | agrupación en búsquedas / SPA |

---

## 6. Flujo recomendado para poblar el catálogo

1. **Lista los temas del temario** de la oposición (no las preguntas).
2. Para cada tema, decide si es un **padre** o una **hoja**.
3. Escribe la `descripcion` de cada uno como si fuera la entradilla
   del tema del libro de texto.
4. Añade `palabras_clave` mirando 10-20 preguntas reales del corpus
   y anotando los términos que se repiten.
5. Sube todo en un solo JSON con `importar_etiquetas`.
6. Lanza `reclasificar_todo` para etiquetar el corpus existente.
7. **Corrige a mano** las preguntas mal clasificadas: el sistema
   aprende de tus correcciones (kNN + `etiquetas_manuales` /
   `etiquetas_bloqueadas`).

---

## 7. Plantilla JSON

```json
[
  {
    "nombre": "programación",
    "descripcion": "Concepto general de desarrollo de software: paradigmas (imperativa, orientada a objetos, funcional), lenguajes (java, python, javascript), estructuras de datos, algoritmos, testing, control de versiones y ciclo de vida del software. Incluye tanto la teoría (complejidad, patrones de diseño) como la práctica del día a día en un equipo de desarrollo.",
    "palabras_clave": ["algoritmo", "estructura de datos",
      "patrón de diseño", "control de versiones", "git",
      "testing unitario", "refactorización", "compilador",
      "intérprete", "paradigma"]
  },
  {
    "nombre": "java",
    "descripcion": "Lenguaje de programación orientado a objetos con tipado estático, sintaxis C-like y ejecución sobre la JVM. Se usa masivamente en backend empresarial, Android y sistemas de alta escala. Ecosistema: Spring, Hibernate, Maven, Gradle, JUnit. Versiones LTS: Java 8, 11, 17, 21. Conceptos clave: clases, interfaces, herencia, polimorfismo, colecciones, streams, generics, anotaciones.",
    "palabras_clave": ["jvm", "jdk", "jre", "clase abstracta",
      "interfaz", "herencia", "polimorfismo", "collections",
      "stream api", "genéricos", "anotación", "maven", "gradle",
      "junit"],
    "padre": "programación"
  },
  {
    "nombre": "spring",
    "descripcion": "Framework de Java para aplicaciones empresariales. Núcleo basado en inversión de control y contenedor de dependencias. Módulos clave: Spring Boot (arranque autoconfigurado), Spring MVC (controladores REST), Spring Data (JPA/JDBC), Spring Security (autenticación y autorización), Spring Cloud (microservicios).",
    "palabras_clave": ["spring boot", "spring mvc", "spring data",
      "spring security", "inyección de dependencias",
      "@component", "@service", "@repository", "@autowired",
      "actuator", "starter"],
    "padre": "java"
  }
]
```
