# Metodología de Aprentix

Cómo se diseña, se fabrica y se adapta el contenido y el estudio en
Aprentix. Todo lo que hay aquí es normativo: si una decisión de producto
o un contenido contradice estos documentos, se corrige el contenido o se
cambia el documento — pero no se ignora.

## Los documentos

| Documento | Responde a | Lo lee |
|---|---|---|
| [`METODOLOGIA.md`](METODOLOGIA.md) | Por qué la app funciona así. Ericsson, Dewey, Flavell y Skinner traducidos a reglas de producto. | Todo el equipo |
| [`ESTRUCTURA_CONTENIDO.md`](ESTRUCTURA_CONTENIDO.md) | Cómo se divide un temario: tema / módulo / sección, tamaños, nomenclatura independiente de la convocatoria. | Quien crea temarios |
| [`PLANTILLA_TEORIA.md`](PLANTILLA_TEORIA.md) | Formato markdown exacto de `teoria.md` y `esquema.md`, con ejemplo completo. | Quien escribe teoría |
| [`PIPELINE_CREACION.md`](PIPELINE_CREACION.md) | Cómo se convierten tests reales, BOE y guías técnicas en contenido publicado. | Quien produce contenido |
| [`MOTOR_ADAPTATIVO.md`](MOTOR_ADAPTATIVO.md) | Métricas, reglas de decisión, plan semanal y plan diario. | Producto y desarrollo |
| [`mapeos/`](mapeos/) | Correspondencia entre las bases de cada convocatoria y los temas canónicos. | Quien da de alta oposiciones |

## Las tres ideas que lo sostienen todo

1. **La sección es la unidad de todo.** Una idea nuclear, 10–15 minutos,
   teoría más test que la verifica. Planificación, evaluación, repaso y
   métricas se agregan a partir de ella.

2. **Cierre teoría–test.** Toda pregunta se responde con la teoría de su
   sección, y todo dato de la teoría se evalúa en alguna pregunta. Ni
   teoría huérfana ni preguntas huérfanas.

3. **El diferencial es el feedback accionable automático**, no el
   temario ni los tests. Nunca se muestra un dato sin la decisión que
   implica.

## Por dónde empezar

- **Voy a crear un temario nuevo** → `ESTRUCTURA_CONTENIDO.md`, después
  `PIPELINE_CREACION.md`.
- **Voy a escribir la teoría de una sección** → `PLANTILLA_TEORIA.md`
  § 2 y el ejemplo completo de § 5.
- **Voy a implementar el plan de estudio** → `MOTOR_ADAPTATIVO.md`, y en
  particular el orden de implementación de § 8.
- **Quiero entender por qué está todo así** → `METODOLOGIA.md`.

## Documentos relacionados fuera de esta carpeta

- `db/ESTADO_BBDD.md` — esquema real de la base de datos.
- `db/DIRECTRICES_ETIQUETAS.md` — catálogo de etiquetas (sistema previo).
- `STYLE.md` — guía visual de la aplicación.
- `DESPLIEGUE.md` — infraestructura y despliegue.
