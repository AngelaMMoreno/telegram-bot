# Editor de páginas dinámicas basado en JSON

## Qué resuelve

Este prototipo convierte una estructura JSON semántica en una página visual editable en tiempo real. El diseño replica el ADN observado en las páginas de referencia incluidas en `paginasEjemplo/`:

- Rejilla adaptable con enfoque mobile-first.
- Banner superior de alto contraste con etiquetas técnicas.
- Tarjetas por categoría con sombras suaves y jerarquía visual.
- Subtemas anidados como tarjetas hijas mediante la propiedad `nivel`.
- Control semántico del comportamiento con atributos como `type`, `style`, `desplegable` y `abierta`.

## Archivos principales

- `index.html`: estructura de la aplicación.
- `estilos.css`: estilos inspirados en el patrón visual de las páginas de referencia.
- `ejemplos.js`: plantillas base, completa y fragmentos inyectables.
- `aplicacion.js`: motor de renderizado, sincronización JSON ↔ interfaz e inyección modular.

## Funcionalidades incluidas

1. **Plantilla base** para comenzar desde un esqueleto mínimo.
2. **Plantilla completa** para replicar una guía técnica con banner, categorías, tarjetas y subtemas.
3. **Inyección incremental** de categorías completas o de nuevos items dentro de la categoría seleccionada.
4. **Vista previa en tiempo real** al editar el JSON.
5. **Edición inversa**: si editas desde el inspector visual, el JSON se sincroniza automáticamente.
6. **Temas y subtemas desplegables o fijos** con `desplegable` y `abierta`.

## Cómo usarlo localmente

Desde la raíz del repositorio:

```bash
python3 -m http.server 4173
```

Después abre en el navegador:

```text
http://localhost:4173/editor_json/
```

## Esquema JSON recomendado

```json
{
  "config": {
    "tituloPagina": "Mi guía",
    "subtituloPagina": "Generada desde JSON",
    "banner": {
      "mostrar": true,
      "titulo": "Centro de Conocimiento",
      "etiqueta": "SISTEMA V1.0",
      "descripcion": "Descripción visible en la cabecera."
    },
    "pie": {
      "texto": "Pie de página",
      "accion": "Texto secundario"
    }
  },
  "categorias": [
    {
      "id": "cat_1",
      "type": "categoria",
      "nombre": "CIBERSEGURIDAD",
      "icono": "🛡️",
      "colorClase": "c-app",
      "color": "#375dfb",
      "desplegable": true,
      "abierta": true,
      "descripcion": "Categoría modular",
      "items": [
        {
          "id": "item_1",
          "type": "card",
          "nombre": "Herramienta ADA",
          "resumen": "Resumen corto",
          "descripcionLarga": "Detalle largo para el panel lateral.",
          "notaRelacionada": "<strong>Tip:</strong> Nota HTML opcional.",
          "badges": ["Nivel 1", "Interno"],
          "nivel": 0,
          "style": "expanded"
        }
      ]
    }
  ]
}
```

## Inyección modular

Puedes inyectar cualquiera de estos formatos desde el cuadro de fragmento:

- Una **categoría completa**.
- Un **item** de tipo `card`, que se insertará en la categoría seleccionada.
- Un **arreglo de categorías** para añadir varios bloques de una sola vez.
