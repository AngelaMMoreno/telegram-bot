# Migración de contenido al esquema nuevo

Este directorio contiene el script y la plantilla de mapeo para importar
los tests JSON del sistema antiguo (con etiquetas planas) a la nueva
estructura Oposición → Tema → Módulo → Sección.

## Estrategia (combinada)

1. **Convención por YAML** — un fichero `mapeo.yaml` mapea etiquetas
   antiguas (o combinaciones de etiquetas) a rutas
   `oposicion/tema/modulo/seccion`. El ~80 % del contenido queda ubicado
   sin intervención humana.
2. **Sección "sin_clasificar"** — las preguntas cuya etiqueta no case con
   ninguna regla caen en una sección catch-all por oposición. Se ven
   desde `#/admin/importar` en la SPA y se reasignan con drag-drop.
3. **Dedupe automático** — el `hash_contenido UNIQUE` de la tabla
   `preguntas` deduplica automáticamente entre tests distintos.

## Uso

```bash
cd db/migraciones_contenido
cp mapeo.ejemplo.yaml mapeo.yaml     # y edita a mano
python3 mapear.py \
    --tests-dir ../../old_tests/      # carpeta con los JSON del sistema viejo
    --mapeo mapeo.yaml \
    --db "postgres://aprentix@localhost:5432/aprentix_desa"
```

Requisitos: `pip install -r requirements.txt`.

## Formato del `mapeo.yaml`

```yaml
# Cada entrada es una regla. La primera que coincida gana.
reglas:
  # Coincide si la lista de etiquetas del test contiene TODAS estas etiquetas.
  - etiquetas: ["constitución española", "título preliminar"]
    seccion: oposicion-x/tema-1-constitucion/modulo-1/seccion-1-titulo-preliminar
  - etiquetas: ["constitución española", "derechos fundamentales"]
    seccion: oposicion-x/tema-1-constitucion/modulo-2/seccion-2-derechos
  # Fallback por oposición: si el test tiene esta etiqueta y no matchea
  # ninguna regla más específica, cae en la sección catch-all.
  - etiquetas: ["ley 40/2015"]
    seccion: oposicion-y/sin_clasificar
```

Las rutas usan **slugs** (`oposiciones.slug`/`temas.slug`/…) — no ids.
El script las resuelve consultando la BD. Si algún slug no existe, el
script aborta y te dice cuál falta.

## Qué NO hace el script

- No crea oposiciones, temas, módulos ni secciones nuevas: eso es
  contenido curricular que se define desde la SPA por el admin. El
  script sólo mueve preguntas ya redactadas al hueco correcto.
- No borra los JSON antiguos. Sí escribe un informe
  `informe_import_<fecha>.json` con lo que ha ubicado y lo huérfano.
