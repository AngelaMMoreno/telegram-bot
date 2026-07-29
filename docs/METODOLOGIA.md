# Metodología Aprentix — marco pedagógico

Este documento es la **raíz** de la metodología. Define en qué creemos y
por qué, y de ahí se derivan todas las reglas concretas que viven en los
otros documentos:

| Documento | Responde a |
|---|---|
| `METODOLOGIA.md` (este) | Por qué la app funciona así. Los 4 autores traducidos a reglas. |
| `ESTRUCTURA_CONTENIDO.md` | Cómo se divide un temario: tema / módulo / sección, tamaños y nombres. |
| `PLANTILLA_TEORIA.md` | Formato markdown exacto de la teoría y los esquemas. |
| `PIPELINE_CREACION.md` | Cómo se fabrica contenido a partir de tests, BOE y guías técnicas. |
| `MOTOR_ADAPTATIVO.md` | Métricas, reglas de decisión, plan semanal y plan diario. |

Regla general: **si una decisión de producto no se puede justificar con
uno de los cuatro principios de abajo, no entra.**

---

## 1. Los cuatro autores, traducidos

No usamos a los autores como decoración teórica. Cada uno resuelve un
problema concreto de la aplicación y se materializa en una decisión de
diseño verificable.

### 1.1 Anders Ericsson — práctica deliberada

**Qué dice.** La mejora no viene de la exposición ni de las horas, sino
de practicar tareas *bien definidas*, ligeramente por encima del nivel
actual, con *feedback inmediato*, repitiendo con corrección y atacando
las debilidades en lugar de repasar lo que ya se domina. La práctica
debe organizarse en **bloques estables**: cambiar de estructura
constantemente destruye el efecto.

**Qué implica en Aprentix.**

| Principio | Decisión de diseño |
|---|---|
| Tarea bien definida | La **sección** es la unidad atómica: un objetivo, 10–15 min, un test que lo verifica. Es la razón de ser de toda la jerarquía. |
| Dificultad ajustada | Zona objetivo de rendimiento **70–85 %**. Por debajo → volver a teoría. Por encima de forma sostenida → subir carga o nivel (módulo, tema, simulacro). |
| Feedback inmediato | `explicacion` obligatoria en toda pregunta, mostrada al responder. Una pregunta sin explicación es contenido defectuoso. |
| Foco en debilidades | El motor prioriza secciones con nota baja y secciones nunca intentadas, no las que ya están en caja alta. |
| Bloques estables | El plan base **no se toca a diario**. Micro-feedback diario, ajuste ligero semanal, ajuste estructural cada 3–4 semanas. |

**Consecuencia dura:** una sección que no se puede evaluar con preguntas
no es una sección. Si escribes teoría que no genera preguntas, has
escrito material de lectura, no práctica deliberada.

### 1.2 John Dewey — aprender haciendo y reconstruir la experiencia

**Qué dice.** Se aprende actuando sobre un problema y reflexionando
después sobre lo ocurrido. El conocimiento no se transmite, se
reconstruye. Dos criterios: **continuidad** (cada experiencia se apoya
en la anterior y prepara la siguiente) e **interacción** (el contenido
dialoga con la situación real del que aprende).

**Qué implica en Aprentix.**

| Principio | Decisión de diseño |
|---|---|
| Problema antes que definición | Toda sección abre con `## Por qué importa`: un caso, una pregunta o un conflicto real. Nunca con "Se entiende por…". |
| Aprender haciendo | El ciclo canónico es **teoría → test → corrección**, siempre en la misma sesión. La teoría sin test no cierra el ciclo y no cuenta como sección completada. |
| Reflexión | `## Compruébalo tú mismo` obliga al usuario a producir la respuesta antes de verla. |
| Continuidad | Cada sección declara su prerrequisito (`Antes de esto`). El orden de secciones y módulos es una secuencia, no una lista. |
| Interacción | `## Cómo cae en el examen` conecta el contenido con la situación real del opositor. |

**Consecuencia dura:** el `esquema.md` de módulo y de tema existe por
Dewey — el todo antes de la parte y el todo otra vez al final. Sin ese
marco, las secciones son fragmentos sin sentido.

### 1.3 John Flavell — metacognición

**Qué dice.** Aprender bien exige saber qué sabes, qué no, y regular la
propia estrategia. Tres componentes: **conocimiento metacognitivo**
(sobre la tarea y sobre uno mismo), **experiencias metacognitivas** (la
sensación de "esto no lo entiendo") y **regulación** (planificar,
monitorizar, evaluar). El fallo típico del opositor es la **mala
calibración**: cree que domina algo que no domina, porque lo ha leído
muchas veces.

**Qué implica en Aprentix.**

| Principio | Decisión de diseño |
|---|---|
| Planificar | Cabecera de sección con objetivo y tiempo estimado. Plan diario visible al entrar. |
| Monitorizar | `## Compruébalo tú mismo` + resultado del test como espejo objetivo frente a la sensación de dominio. |
| Evaluar | Feedback semanal en forma de **decisiones**, no de datos: "enfócate en X", no "tu media es 63,4 %". |
| Calibración | Recomendado: antes de ver la nota, preguntar *"¿cuántas crees que has acertado?"* y mostrar predicho vs. real. Es la intervención metacognitiva más barata y más potente del sistema. |
| Estrategia explícita | `## No lo confundas` enseña *cómo* se equivoca la gente, no solo qué es correcto. |

**Consecuencia dura:** el sistema nunca oculta al usuario por qué le
propone algo. Cada recomendación lleva su motivo en una frase.

### 1.4 B. F. Skinner — condicionamiento operante

**Qué dice.** La conducta se moldea por sus consecuencias. Refuerzo
inmediato, aproximaciones sucesivas (moldeamiento), programas de
refuerzo variables para mantener la conducta, y **control de estímulos**:
un entorno predecible dispara la conducta con menos fricción. El castigo
y la extinción (esfuerzo sin recompensa) apagan la conducta.

**Qué implica en Aprentix.**

| Principio | Decisión de diseño |
|---|---|
| Refuerzo inmediato | Corrección al instante tras cada respuesta + XP al completar sección. |
| Moldeamiento | Escalera sección → módulo → tema → simulacro. Nunca se salta un peldaño. |
| Refuerzo intermitente | Retos y logros (`retos_catalogo`, `logros_catalogo`) que no siempre se anticipan. |
| Evitar extinción | `min_aprobado` por defecto **70 %** y test de 10 preguntas: alcanzable en el primer intento. Un muro al principio expulsa usuarios. |
| Control de estímulos | **La estructura de la teoría y del plan diario es siempre idéntica.** La rigidez del formato no es burocracia: es lo que hace que estudiar cueste menos decidir. |
| Refuerzo diferencial | Más XP por completar una sección marcada como prioritaria que una fácil. |
| Racha | `usuario_gamificacion.racha_actual` refuerza la constancia, que es la variable con más peso en el resultado real. |

**Consecuencia dura:** ninguna pantalla castiga. Un rendimiento bajo se
traduce en *"vamos a bajar el ritmo"*, nunca en *"has fallado"*.

### 1.5 Soporte complementario (ya implementado)

- **Ebbinghaus** → motor Leitner de 7 cajas (`repasos`,
  `intervalo_repaso`), con ritmos intensivo/normal/relajado.
- **Sweller (carga cognitiva)** → límite de 10–15 min por sección,
  descansos en el plan diario y detección de caída de rendimiento por
  longitud de sesión.

No son el marco, son las curvas que lo hacen operativo.

---

## 2. El ciclo canónico de aprendizaje

Todo en la app es una instancia de este ciclo. Si algo no encaja aquí,
sobra.

```
   ┌─────────────────────────────────────────────────────────┐
   │                                                         │
   │   1. ENCUADRE      esquema.md de tema/módulo            │  Dewey
   │        ↓           "qué voy a aprender y para qué"       │  Flavell
   │                                                         │
   │   2. EXPOSICIÓN    teoria.md de sección (5–7 min)        │  Dewey
   │        ↓           problema → idea clave → desarrollo    │
   │                                                         │
   │   3. AUTOCHEQUEO   "Compruébalo tú mismo"               │  Flavell
   │        ↓           producir antes de verificar           │
   │                                                         │
   │   4. PRÁCTICA      test de sección (10 preg., 5 min)     │  Ericsson
   │        ↓           tarea definida + dificultad ajustada  │
   │                                                         │
   │   5. FEEDBACK      corrección + explicación inmediata    │  Skinner
   │        ↓                                                 │
   │   6. REFUERZO      XP, racha, sección completada         │  Skinner
   │        ↓                                                 │
   │   7. CONSOLIDACIÓN repaso Leitner en D+1, D+3, D+7…      │  Ebbinghaus
   │        ↓                                                 │
   │   8. INTEGRACIÓN   test de módulo → test de tema         │  Ericsson
   │        ↓                          → simulacro            │  (moldeamiento)
   │                                                         │
   └───────────────► métricas ──► ajuste del plan ───────────┘
                                                   Flavell + Ericsson
```

**Invariante:** una sección solo cuenta como completada cuando ha pasado
por los pasos 2→5 y ha superado `min_aprobado`. Leer teoría marca
`teoria_vista_en`, pero **no completa** (`completada_en`). Está así en el
esquema y es una decisión metodológica, no técnica.

---

## 3. Premisas no negociables

Estas siete premisas son el contrato que todo contenido y toda función
del producto deben cumplir. Sirven como criterio de rechazo en revisión.

1. **P1 · Atomicidad.** La sección es la unidad mínima de estudio,
   evaluación, repaso y planificación. Todo lo demás se agrega a partir
   de ella. Duración objetivo: **10–15 minutos** de principio a fin.

2. **P2 · Cierre teoría–test.** Toda pregunta debe poder responderse con
   la teoría de su sección, y todo dato relevante de la teoría debe
   aparecer en al menos una pregunta. Ni teoría huérfana ni preguntas
   huérfanas. *(Es el principio verificable más importante del sistema.)*

3. **P3 · Feedback inmediato y accionable.** Nunca se muestra un dato sin
   la decisión que implica. "Has fallado 7" no es feedback; "repasa
   Procedimiento Administrativo · Plazos" sí.

4. **P4 · Estructura invariable.** El esqueleto de la teoría, del plan
   diario y del test es siempre el mismo, en el mismo orden. La
   predictibilidad es una funcionalidad.

5. **P5 · Independencia de la convocatoria.** Temas y módulos se nombran
   por el objeto de conocimiento, no por la oposición que los exige. Un
   tema es reutilizable por definición (`oposicion_temas` es M:N).
   Excepción: cuando la fuente misma es específica de una administración.

6. **P6 · Estabilidad del plan.** El plan base se genera una vez y se
   mantiene. Diario: guía. Semanal: ajuste ±10–20 %. Cada 3–4 semanas:
   reestructuración. Inmediato: solo en abandono o desplome.

7. **P7 · Nunca castigar.** Bajo rendimiento reduce carga y aumenta
   soporte. Nunca bloquea, nunca reprocha, nunca resetea progreso.

---

## 4. Dónde vive cada principio en el código actual

Para que la metodología no se quede en papel, este es el mapa contra el
esquema real (`db/init/01_esquema.sql`).

| Principio | Artefacto existente |
|---|---|
| Atomicidad (P1) | `secciones` (+ `n_preg_test` = 10, `min_aprobado` = 70) |
| Escalera de moldeamiento | `iniciar_intento_seccion` / `_modulo` / `_tema`, `preguntas_por_nodo()` |
| Feedback inmediato | `preguntas.explicacion`, `registrar_respuesta()` |
| Refuerzo | `usuario_gamificacion`, `retos_catalogo`, `logros_catalogo`, `_gamif_*` |
| Repaso espaciado | `repasos` (7 cajas), `intervalo_repaso()`, `preguntas_repaso_oposicion()` |
| Encuadre (Dewey) | `documentos` nivel `tema`/`modulo`, tipo `esquema` |
| Exposición | `documentos` nivel `seccion`, tipo `teoria` |
| Monitorización | `progreso_seccion` (`nota_max`, `intentos_totales`, `teoria_vista_en`) |
| Reutilización entre oposiciones (P5) | `oposicion_temas`, `sugerir_solapamiento()` |
| Calidad del banco | `propuestas_fusion` (similitud ≥ 0,90 vía `bge-m3`) |

Lo que **todavía no existe** y la metodología necesita (plan personal,
métricas agregadas, tiempos reales) está especificado en
`MOTOR_ADAPTATIVO.md` § 7 como evolución de esquema propuesta.

---

## 5. Criterio de rechazo (usar en revisión)

Una sección, un módulo o un tema se rechaza si:

- [ ] La sección no se completa en 15 min (teoría + test) → dividir.
- [ ] Hay preguntas que la teoría de la sección no permite responder → P2.
- [ ] Hay contenido en la teoría que ninguna pregunta evalúa → P2.
- [ ] Falta alguna sección obligatoria del esqueleto markdown → P4.
- [ ] Alguna pregunta no tiene `explicacion` → P3.
- [ ] El nombre del tema o del módulo contiene número de tema, bloque,
      cuerpo, escala o año de convocatoria → P5.
- [ ] El módulo tiene una sola sección real (y no está marcado
      `es_unico`) → no es un módulo.
- [ ] El test de sección no tiene un pool de al menos 25 preguntas →
      la repetición degenera en memorizar el orden.
