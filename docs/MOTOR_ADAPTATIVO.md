# Motor adaptativo — métricas, plan y feedback

Cómo la aplicación convierte el comportamiento real del usuario en
decisiones: qué mide, qué reglas aplica, con qué frecuencia ajusta y qué
le dice al usuario.

Deriva de `METODOLOGIA.md`, en particular de P3 (feedback accionable),
P6 (estabilidad del plan) y P7 (nunca castigar).

> **El diferencial del producto no es el temario ni los tests: es el
> feedback accionable automático.** Todo lo de aquí existe para eso.

---

## 1. Entrada: el cuestionario inicial

Seis preguntas. Ni una más: cada pregunta añadida reduce la conversión y
el sistema puede inferir casi todo lo demás observando.

| # | Pregunta | Opciones | Para qué se usa |
|---|---|---|---|
| 1 | ¿Cuándo es el examen? | Fecha concreta · "Aún sin convocar" (→ estimación en meses) | Horizonte `H` en semanas |
| 2 | ¿Cuánto puedes estudiar al día? | < 1 h · 1–2 h · 2–4 h · > 4 h | Minutos/día `M` |
| 3 | ¿Qué días puedes? | Selección de L–D | Días/semana `d` |
| 4 | ¿Qué prefieres? | Más teoría · Equilibrado · Más test | Reparto teoría/práctica |
| 5 | ¿Cómo llevas la rutina? | "Me cuesta mantenerla" · "Soy constante" | Carga inicial y tolerancia al fallo |
| 6 | ¿Partes de cero? | Sí · Ya he preparado antes | Fase de arranque |

Valores de trabajo:

| Respuesta | `M` (min/día) |
|---|---:|
| < 1 h | 45 |
| 1–2 h | 90 |
| 2–4 h | 165 |
| > 4 h | 240 |

**Nunca se planifica al 100 % de la capacidad declarada** (Skinner:
un objetivo inalcanzable produce extinción). Factor de realismo:

| Constancia | Factor |
|---|---:|
| "Me cuesta mantenerla" | **0,70** |
| "Soy constante" | **0,85** |

`Capacidad semanal = M × d × factor`

---

## 2. Generación del plan base

### 2.1 Cálculo de viabilidad

```
Coste del temario (minutos) =
      Σ secciones × 12                       (teoría + test de sección)
    + Σ módulos   × 13                       (test de módulo)
    + Σ temas     × 28                       (test de tema)
    + repaso: 15 % del total anterior
    + simulacros: n × 90
```

Se compara con `Capacidad semanal × H`:

| Cobertura | Mensaje y acción |
|---|---|
| ≥ 130 % | Holgura. Se añaden simulacros y repaso extra. |
| 100–130 % | Plan estándar. |
| 70–100 % | "Vas justo": se prioriza por peso en examen y se recorta la 2ª pasada de las secciones ya dominadas. |
| < 70 % | Se dice **con claridad** y se ofrecen tres salidas: subir días/semana, ampliar horizonte, o cubrir solo el núcleo priorizado. Nunca se genera en silencio un plan imposible. |

### 2.2 Fases (bloques estables de Ericsson)

El plan se divide en tres fases. **Las fases no cambian en los ajustes
semanales**; solo en el ajuste estructural (§ 5).

| Fase | % del horizonte | Objetivo | Composición del día |
|---|---:|---|---|
| **1 · Cobertura** | 55 % | Primera pasada completa | 70 % secciones nuevas · 20 % repaso · 10 % tests de módulo |
| **2 · Consolidación** | 30 % | Cerrar debilidades | 35 % secciones nuevas o repetidas · 40 % repaso · 25 % tests de módulo y tema |
| **3 · Simulación** | 15 % | Rendimiento en condiciones de examen | 20 % refuerzo puntual · 45 % repaso · 35 % simulacros |

**Últimas 2 semanas: cero contenido nuevo.** Solo repaso y simulacros.

Ajuste por preferencia (pregunta 4):

| Preferencia | Efecto |
|---|---|
| Más teoría | +1 sección nueva/día, −1 bloque de repaso |
| Equilibrado | Reparto por defecto |
| Más test | −1 sección nueva/día, +1 bloque de test agregado o repaso |

---

## 3. Lo que el sistema mide

Todo lo de esta sección se deriva de tablas que **ya existen**, salvo lo
marcado con ⚠️.

### 3.1 Nivel usuario

| Métrica | Cómo se calcula | Fuente |
|---|---|---|
| % acierto por sección | `respuestas.correcta` agrupado por `preguntas.seccion_id` | `respuestas`, `preguntas` |
| % acierto por módulo / tema | Agregado por `modulos`/`temas` | idem |
| % acierto global | Todas las respuestas del usuario | `respuestas` |
| Evolución | Media móvil de 7 días de `intentos.nota` | `intentos` |
| **Fatiga cognitiva** | Acierto por **posición de la pregunta dentro del intento** (orden de `respondida_en`), por tramos de 10 | `respuestas` |
| Tiempo por pregunta | Diferencia entre `respondida_en` consecutivos del mismo intento | `respuestas` |
| Tasa de olvido | Fallos en preguntas con `repasos.caja ≥ 3` y días transcurridos desde `ultima_en` | `repasos` |
| Fallos persistentes | `marcadores.contador` (tipo `fallo`) | `marcadores` |
| Días activos/semana | Fechas distintas con `intentos` finalizados | `intentos` |
| Racha | `usuario_gamificacion.racha_actual` | `usuario_gamificacion` |
| % objetivos cumplidos | Bloques completados ÷ bloques planificados | ⚠️ `plan_bloques` |
| Secciones ignoradas | Secciones de la oposición sin fila en `progreso_seccion` | `progreso_seccion` |
| Tiempo real por sección | Suma de `minutos_reales` de sus bloques | ⚠️ `plan_bloques` |

**Detección de fatiga (concreta).** Para cada usuario, sobre intentos de
≥ 30 preguntas:

```
acierto(tramo 1–10), acierto(11–20), acierto(21–30), acierto(31–40), acierto(41+)
n_optimo = último tramo cuyo acierto no cae más de 10 puntos
           respecto al tramo 1–10
```

Con ≥ 5 intentos largos ya hay señal suficiente. `n_optimo` es lo que
fija el tamaño de los bloques de test en el plan diario.

### 3.2 Nivel global (todos los usuarios) — calibración del contenido

Este es el bucle que mejora el producto para todos y cierra contra
`PIPELINE_CREACION.md` § F8.

| Métrica | Definición | Para qué |
|---|---|---|
| **Dificultad de sección** | 1 − acierto medio global | Ordenar el temario por dificultad real, no percibida |
| **Tiempo real p50** | Mediana de minutos hasta completar la sección | Verificar la premisa de 10–15 min |
| **Tasa de abandono** | Intentos iniciados sin `finalizado_en` ÷ iniciados | Detectar secciones que agotan |
| **Índice de discriminación** | Correlación entre acertar esa pregunta y la nota total del intento | Detectar preguntas defectuosas |
| **Índice de dificultad de pregunta** | % de acierto global | Equilibrar el pool |
| **Curva de olvido por sección** | % de fallo en repaso según días transcurridos | Afinar los intervalos Leitner |
| **Orden real de aprendizaje** | Secciones que mejoran cuando otra ya está dominada | Validar los prerrequisitos declarados |
| **Cobertura del plan** | % de usuarios que llegan a cada fase | Detectar planes irreales |

**Reglas de calibración automática** (generan tareas de contenido, no
cambian nada solas):

| Condición (n ≥ 30 usuarios) | Diagnóstico | Acción propuesta |
|---|---|---|
| Acierto medio < 50 % | Teoría insuficiente o sección demasiado densa | Reescribir o dividir |
| Acierto medio > 92 % | Sección trivial | Fundir o elevar el nivel del pool |
| Tiempo p50 > 18 min | Viola P1 | **Dividir** |
| Tiempo p50 < 6 min | Infradimensionada | Fundir con la vecina |
| Abandono > 25 % | Carga cognitiva excesiva | Dividir y revisar el Desarrollo |
| Discriminación < 0 en una pregunta | Mal formulada o respuesta mal marcada | Corregir o retirar |
| Acierto de pregunta < 20 % o > 95 % | Fuera de rango útil | Revisar |

**Uso en planes nuevos:** la dificultad y el tiempo p50 reales sustituyen
a las estimaciones por defecto en cuanto hay muestra. Un usuario nuevo
recibe un plan calibrado con la experiencia de todos los anteriores.
Ese es el activo que se acumula.

---

## 4. Motor de decisión

Reglas explícitas, auditables y explicables al usuario en una frase. No
hay caja negra.

### A · Priorización de secciones

Umbrales base:

| Nota máxima de la sección | Prioridad |
|---|---|
| < 60 % | **ALTA** |
| 60–80 % | MEDIA |
| > 80 % | BAJA |
| Sin intentar, y toca en la fase actual | **ALTA** |

Score de ordenación dentro de cada nivel de prioridad:

```
score = 0,45 · (1 − nota_normalizada)
      + 0,25 · peso_en_examen            (frecuencia observada, F1 del pipeline)
      + 0,20 · urgencia_de_repaso        (días vencidos ÷ intervalo de su caja)
      + 0,10 · (1 − veces_practicada_normalizada)
```

El mensaje al usuario cita **el factor dominante**, nunca el score:
"Prioriza *Silencio administrativo*: es lo que más falla y lo que más
cae".

En la UI, las tarjetas de los temas prioritarios se marcan visualmente.

### B · Repetición espaciada

**No se construye un motor paralelo.** El sistema Leitner ya existe
(`repasos`, 7 cajas, `intervalo_repaso(caja, ritmo)`): acierto sube 1
caja, fallo baja 2, la próxima fecha se deriva al vuelo. El "peso por
error" que hace falta ya está en `marcadores.contador`.

Score de selección para el repaso global:

```
score_repaso = 2,0 · fallos_activos (marcadores.contador)
             + 1,5 · (8 − caja)
             + 1,0 · días_vencida
             + 0,5 · prioridad_de_su_seccion
```

Al usuario **nunca se le habla de preguntas pendientes**, se le habla de
contenido: "Hoy toca repasar *Silencio administrativo* y *Plazos*".

### C · Ajuste por fatiga

| Condición | Acción automática | Aviso |
|---|---|---|
| `n_optimo` < 30 en ≥ 5 intentos largos | Bloques de test de `n_optimo` preguntas | "He acortado los bloques a 25 preguntas: tu acierto cae a partir de ahí." |
| `n_optimo` ≥ 40 y acierto global > 80 % | Se **propone** subir, no se impone | "Vas muy bien, ¿probamos bloques de 50 preguntas?" |
| Caída > 15 puntos entre el primer tramo y el último | Insertar descanso a mitad del bloque | Automático, se informa |

Subir carga siempre se pregunta; bajarla se hace y se explica (P7).

### D · Ajuste por consistencia

Medido sobre la semana cerrada:

| % de objetivos cumplidos | Acción |
|---|---|
| < 50 % | Carga −20 %. Mensaje de recuperación, nunca de reproche. |
| 50–80 % | Sin cambios. |
| 80–95 % | Sin cambios; refuerzo positivo. |
| > 95 % dos semanas seguidas | Carga +10–15 %, previa confirmación. |

**Suelo de dignidad:** la carga nunca baja de **1 sección al día**. Un
plan de cero días es un plan abandonado.

### E · Práctica deliberada

| Condición | Acción |
|---|---|
| Sección con nota < 60 % y **1–2** intentos | Más exposición: sus preguntas ganan peso en el repaso |
| Sección con nota < 60 % y **≥ 3** intentos | **Volver a la teoría**, no repetir el test |
| Sección > 85 % con 2 intentos | Se retira de la rotación activa; queda solo en Leitner |
| Módulo con todas las secciones > 80 % | Se desbloquea el test de módulo como objetivo |

> La regla de los 3 intentos es la traducción literal de Ericsson:
> repetir una práctica que falla, sin corregir el modelo mental, no es
> práctica deliberada — es desgaste. A partir del tercer fallo el
> problema es de comprensión, no de repetición.

### F · Emergencia (evaluación diaria)

Se salta la cadencia semanal solo en estos tres casos:

| Disparador | Acción inmediata |
|---|---|
| 0 actividad en 5 días | Plan en pausa; al volver, día de reentrada al 50 % de carga y sin penalización de racha |
| Caída > 25 puntos en la media móvil de 7 días | Semana de consolidación: cero contenido nuevo, solo repaso |
| < 20 % de objetivos cumplidos 2 semanas seguidas | Re-cuestionario: probablemente la disponibilidad declarada ya no es real |

---

## 5. Cadencias de ajuste

El equilibrio entre adaptación y estabilidad. **Es la regla que más se
incumple y la que más daño hace incumplir.**

| Cadencia | Qué puede cambiar | Qué NO puede cambiar |
|---|---|---|
| **Diario** — micro-feedback | Nada del plan. Solo el orden de los bloques del día y los mensajes de guía. | Carga, fases, objetivos |
| **Semanal** — ajuste ligero | Carga ±10–20 %, prioridad de secciones, tamaño de bloques de test, misión semanal | Fases, reparto teoría/test, estructura |
| **Cada 3–4 semanas** — ajuste estructural | Reparto teoría/test, reorganización de módulos pendientes, introducción de simulacros, ritmo general | Fecha de examen, temario |
| **Inmediato** — solo emergencias (§ 4.F) | Lo necesario para no perder al usuario | — |

> Los expertos coinciden: el aprendizaje mejora con **estabilidad más
> correcciones puntuales**, no con cambios continuos. Un plan que cambia
> cada día no es adaptativo, es ruido.

---

## 6. Salidas

### 6.1 Misión semanal

Estructura idéntica para todos, **intensidad distinta** (Skinner:
control de estímulos con refuerzo diferencial). Se expresa en secciones
y temas, nunca en número de preguntas.

| Perfil | Secciones nuevas | Repaso | Tests de módulo | Simulacros |
|---|---:|---:|---:|---:|
| Ligero | 4 | 3 sesiones | 1 | 0 |
| Estándar | 8 | 4 sesiones | 2 | 1 (desde fase 2) |
| Intensivo | 14 | 5 sesiones | 3 | 2 |

El perfil sale de `Capacidad semanal`, y se recalcula cada semana con la
regla D.

### 6.2 Resumen semanal (4 bloques, siempre los mismos)

```
🎯 Prioridad
   Esta semana: Silencio administrativo y Plazos de resolución.
   Son las dos secciones donde más se te escapa.

📊 Mejora
   Has subido 12 puntos en Procedimiento Administrativo. Vas por buen camino.

⚠️ Ajuste
   He acortado los bloques de test a 25 preguntas: tu acierto cae a partir de ahí.

🔁 Repaso
   Hoy toca repasar: La Corona · Plazos de resolución.
```

Reglas de redacción (P3 + P7):

1. **Decisiones, no datos.** Ningún porcentaje sin la acción que implica.
2. **Nombres de contenido, nunca cantidades de preguntas.** "Repasa
   *Plazos*", no "tienes 120 preguntas pendientes".
3. **Máximo 4 bloques.** Si no hay nada que decir en uno, se omite.
4. **Bajar carga se comunica en positivo**: "vamos a ajustar el ritmo",
   nunca "no has cumplido".
5. **Subir carga se pregunta**, no se impone.
6. Una frase por bloque. Dos como máximo.

### 6.3 Plan diario

Se muestra **al primer acceso del día**, antes que ninguna otra cosa.

```
📅 Tu plan de hoy · 47 min

  1. 📖 Teoría · Procedimiento Administrativo › Terminación › Silencio administrativo    6 min
  2. ✍️ Test   · Silencio administrativo                                                 5 min
  3. 🔁 Repaso · La Corona · Plazos de resolución                                        8 min
  4. ☕ Descanso                                                                          5 min
  5. 📖 Teoría · Terminación › Desistimiento y renuncia                                   6 min
  6. ✍️ Test   · Desistimiento y renuncia                                                 5 min
  7. 🧩 Test de módulo · Terminación del procedimiento                                   12 min

                          [ Estudiar ]
```

**Reglas de construcción del día:**

| Regla | Valor |
|---|---|
| Unidad de composición | El par teoría + test de la misma sección, **nunca separados** |
| Descanso | Tras cada 2 secciones o cada 25 min de test continuado |
| Repaso | Siempre presente si hay contenido vencido; va **al principio**, en frío |
| Test de módulo | Cuando todas sus secciones están completadas |
| Simulacro | Solo en fase 3, y en un día con `M` suficiente |
| Contenido nuevo | Nunca después de un simulacro |
| Día mínimo | 1 sección (≈ 12 min), aunque el usuario tenga menos tiempo |
| Tope del día | `M × factor`, sin excederlo jamás |

**Botón "Estudiar":** encadena los bloques automáticamente. Al terminar
uno, lleva al siguiente sin volver al menú. Es lo que elimina la
fricción de decidir (Skinner: control de estímulos).

**Medición:** cada bloque registra `minutos_estimados` y
`minutos_reales`. La diferencia acumulada es lo que recalibra las
estimaciones — primero del usuario, y agregada, del contenido para todos
(§ 3.2).

### 6.4 Micro-feedback diario

Máximo **un** mensaje al día, al cerrar la sesión. No cambia el plan.

| Situación | Mensaje |
|---|---|
| Día completado | "Día completo. Racha: 6 días." |
| Día parcial | "Has hecho 2 de 4 bloques. Mañana seguimos por *Caducidad*." |
| Sección fallada 3ª vez | "*Silencio administrativo* se te resiste. Mañana volvemos a la teoría antes del test." |
| Sección dominada | "*Plazos* dominado. Pasa a repaso espaciado." |
| Vuelta tras ausencia | "Bienvenido de nuevo. Hoy retomamos suave: 1 sección y un repaso corto." |

---

## 7. Evolución del esquema necesaria

Lo descrito arriba usa tablas existentes salvo lo siguiente, que **hoy
no existe** en `db/init/01_esquema.sql`. Nomenclatura alineada con la
del proyecto.

### 7.1 Tablas nuevas

```sql
-- Plan personal. Uno activo por (usuario, oposición).
CREATE TABLE planes (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id     uuid NOT NULL REFERENCES usuarios(id)   ON DELETE CASCADE,
    oposicion_id   uuid NOT NULL REFERENCES oposiciones(id) ON DELETE CASCADE,
    fecha_examen   date,                       -- NULL = sin convocar
    horizonte_sem  int  NOT NULL,              -- semanas estimadas si no hay fecha
    minutos_dia    int  NOT NULL,
    dias_semana    int[] NOT NULL,             -- 1=lunes … 7=domingo
    preferencia    text NOT NULL CHECK (preferencia IN ('teoria','equilibrado','test')),
    constancia     text NOT NULL CHECK (constancia IN ('baja','alta')),
    fase           text NOT NULL DEFAULT 'cobertura'
                     CHECK (fase IN ('cobertura','consolidacion','simulacion')),
    activo         boolean NOT NULL DEFAULT true,
    creado_en      timestamptz NOT NULL DEFAULT now(),
    recalculado_en timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX planes_activo_uk ON planes (usuario_id, oposicion_id) WHERE activo;

-- Objetivo semanal y su cumplimiento (base del ajuste de la regla D).
CREATE TABLE plan_semanas (
    plan_id            uuid NOT NULL REFERENCES planes(id) ON DELETE CASCADE,
    semana_inicio      date NOT NULL,                    -- lunes
    fase               text NOT NULL,
    secciones_objetivo int  NOT NULL,
    repasos_objetivo   int  NOT NULL,
    tests_objetivo     int  NOT NULL DEFAULT 0,
    simulacros_objetivo int NOT NULL DEFAULT 0,
    secciones_hechas   int  NOT NULL DEFAULT 0,
    repasos_hechos     int  NOT NULL DEFAULT 0,
    tests_hechos       int  NOT NULL DEFAULT 0,
    simulacros_hechos  int  NOT NULL DEFAULT 0,
    PRIMARY KEY (plan_id, semana_inicio)
);

-- El día concreto y sus bloques. La medición vive aquí.
CREATE TABLE plan_dias (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_id            uuid NOT NULL REFERENCES planes(id) ON DELETE CASCADE,
    fecha              date NOT NULL,
    minutos_estimados  int  NOT NULL,
    minutos_reales     int,
    estado             text NOT NULL DEFAULT 'pendiente'
                         CHECK (estado IN ('pendiente','en_curso','completado','parcial','saltado')),
    UNIQUE (plan_id, fecha)
);

CREATE TABLE plan_bloques (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_dia_id       uuid NOT NULL REFERENCES plan_dias(id) ON DELETE CASCADE,
    orden             int  NOT NULL,
    tipo              text NOT NULL CHECK (tipo IN
                        ('teoria','test_seccion','test_modulo','test_tema',
                         'repaso','simulacro','descanso')),
    seccion_id        uuid REFERENCES secciones(id) ON DELETE SET NULL,
    modulo_id         uuid REFERENCES modulos(id)   ON DELETE SET NULL,
    tema_id           uuid REFERENCES temas(id)     ON DELETE SET NULL,
    minutos_estimados int  NOT NULL,
    minutos_reales    int,
    intento_id        uuid REFERENCES intentos(id)  ON DELETE SET NULL,
    completado_en     timestamptz,
    UNIQUE (plan_dia_id, orden)
);

-- Cachés de métricas globales, refrescadas por job nocturno.
CREATE TABLE metricas_seccion_global (
    seccion_id     uuid PRIMARY KEY REFERENCES secciones(id) ON DELETE CASCADE,
    n_usuarios     int     NOT NULL DEFAULT 0,
    n_intentos     int     NOT NULL DEFAULT 0,
    acierto_medio  numeric,
    tiempo_p50_min numeric,
    abandono_pct   numeric,
    actualizado_en timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE metricas_pregunta_global (
    pregunta_id    uuid PRIMARY KEY REFERENCES preguntas(id) ON DELETE CASCADE,
    n_respuestas   int     NOT NULL DEFAULT 0,
    acierto_pct    numeric,
    discriminacion numeric,                    -- correlación con la nota del intento
    actualizado_en timestamptz NOT NULL DEFAULT now()
);
```

### 7.2 Columnas a añadir

```sql
-- Fecha prevista de examen a nivel de oposición (informativa; la que
-- manda para el plan es planes.fecha_examen).
ALTER TABLE oposiciones ADD COLUMN fecha_examen_prevista date;

-- Denominación de las bases por oposición, sin contaminar el nombre
-- canónico del tema (ver ESTRUCTURA_CONTENIDO.md § 4.5).
ALTER TABLE oposicion_temas ADD COLUMN alias_bases text;
ALTER TABLE oposicion_temas ADD COLUMN epigrafe    text;

-- Tiempo real de lectura de teoría (hoy solo se guarda el instante).
ALTER TABLE progreso_seccion ADD COLUMN segundos_teoria int NOT NULL DEFAULT 0;

-- Simulacro como origen de intento.
-- (implica recrear el CHECK de intentos.origen añadiendo 'simulacro')
```

El tiempo por pregunta **no necesita columna nueva**: se deriva de las
diferencias entre `respuestas.respondida_en` consecutivos del mismo
intento.

### 7.3 RPCs a crear

| RPC | Devuelve |
|---|---|
| `crear_plan(oposicion_id, fecha_examen, minutos_dia, dias_semana, preferencia, constancia)` | Plan generado + viabilidad |
| `mi_plan_hoy()` | Bloques del día con tiempos estimados y estado |
| `iniciar_bloque(bloque_id)` / `completar_bloque(bloque_id, minutos_reales)` | Avance y siguiente bloque |
| `mi_resumen_semanal()` | Los 4 bloques de § 6.2, ya redactados |
| `recalcular_plan(plan_id)` | Aplica reglas D y E; se ejecuta semanalmente |
| `mis_prioridades(oposicion_id)` | Secciones ordenadas por el score de § 4.A |
| `admin_metricas_contenido()` | Secciones y preguntas que disparan las reglas de § 3.2 |

---

## 8. Orden de implementación recomendado

Cada paso aporta valor por sí solo y no bloquea al siguiente.

| # | Entrega | Depende de |
|---|---|---|
| 1 | Métricas de usuario sobre tablas existentes (acierto por sección, fatiga, consistencia) | Nada |
| 2 | Priorización (§ 4.A) y marcado visual de temas prioritarios | 1 |
| 3 | Resumen semanal (§ 6.2) sin plan: ya es feedback accionable | 1, 2 |
| 4 | Cuestionario + `planes` + plan base por fases | 3 |
| 5 | Plan diario, botón "Estudiar" y medición de tiempos | 4 |
| 6 | Ajuste automático semanal (reglas C, D, E) y emergencias (F) | 5 |
| 7 | Métricas globales y calibración del contenido (§ 3.2) | 5 |

> El paso 3 ya entrega el diferencial del producto sin necesidad de
> calendario. Es el primero que debería salir.
