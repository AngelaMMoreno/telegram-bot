window.EJEMPLOS_PLANTILLAS = {
  base: {
    config: {
      tituloPagina: 'Nueva página modular',
      subtituloPagina: 'Plantilla mínima para empezar a construir desde JSON',
      banner: {
        mostrar: false,
        titulo: '',
        etiqueta: 'BASE',
        descripcion: ''
      },
      pie: {
        texto: 'Pie de página editable desde JSON',
        accion: 'Añadir categorías, tarjetas y subtemas.'
      }
    },
    categorias: []
  },
  completa: {
    config: {
      tituloPagina: 'Mi Nueva Guía Técnica',
      subtituloPagina: 'Generada dinámicamente mediante módulos JSON',
      banner: {
        mostrar: true,
        titulo: 'Centro de Conocimiento',
        etiqueta: 'SISTEMA V1.0',
        descripcion: 'Descripción general del banner que aparece al principio.'
      },
      pie: {
        texto: 'Sistema de documentación low-code listo para ampliar.',
        accion: 'Selecciona una tarjeta o modifica el JSON para editar.'
      }
    },
    categorias: [
      {
        id: 'cat_1',
        type: 'categoria',
        nombre: 'CIBERSEGURIDAD',
        icono: '🛡️',
        colorClase: 'c-app',
        color: '#375dfb',
        desplegable: true,
        abierta: true,
        descripcion: 'Categoría inspirada en tarjetas técnicas del ejemplo CCN-CERT.',
        items: [
          {
            id: 'item_1',
            type: 'card',
            nombre: 'Herramienta ADA',
            resumen: 'Análisis Automatizado de Auditorías.',
            descripcionLarga: 'Explicación profunda de ADA que aparecerá en el panel de detalles.',
            notaRelacionada: '<strong>Tip:</strong> ADA funciona mejor en entornos aislados.',
            badges: ['Nivel 1', 'Interno'],
            nivel: 0,
            style: 'expanded'
          },
          {
            id: 'item_2',
            type: 'card',
            nombre: 'Subtema ADA - Análisis',
            resumen: 'Módulo específico de análisis de trazas.',
            descripcionLarga: 'Detalles técnicos del subtema con el mismo lenguaje visual de tarjetas anidadas.',
            badges: ['Subtema'],
            nivel: 1,
            style: 'collapsed'
          }
        ]
      },
      {
        id: 'cat_2',
        type: 'categoria',
        nombre: 'REDES Y PROTOCOLOS',
        icono: '🌐',
        colorClase: 'c-redes',
        color: '#16a34a',
        desplegable: false,
        abierta: true,
        descripcion: 'Bloque inspirado en la estructura comparativa de la página OSI/TCP-IP.',
        items: [
          {
            id: 'item_3',
            type: 'card',
            nombre: 'Modelo OSI',
            resumen: 'Separación clara por capas y responsabilidades.',
            descripcionLarga: 'Panel de contenido para mostrar capas, PDU, dispositivos y protocolos.',
            badges: ['Comparativa', '7 capas'],
            nivel: 0,
            style: 'expanded'
          },
          {
            id: 'item_4',
            type: 'card',
            nombre: 'TCP/IP',
            resumen: 'Agrupación funcional en menos capas.',
            descripcionLarga: 'La jerarquía de tarjetas permite profundizar desde una vista compacta.',
            badges: ['Comparativa', '4 capas'],
            nivel: 0,
            style: 'expanded'
          }
        ]
      }
    ]
  },
  fragmento: {
    categoria: {
      id: 'cat_ada',
      type: 'categoria',
      nombre: 'ADA Y SUBTEMAS',
      icono: '🧠',
      colorClase: 'c-ada',
      color: '#7c3aed',
      desplegable: true,
      abierta: true,
      descripcion: 'Módulo inyectable que añade una categoría completa.',
      items: [
        {
          id: 'item_ada_1',
          type: 'card',
          nombre: 'ADA - Recopilación',
          resumen: 'Inicio del flujo de información.',
          descripcionLarga: 'Puedes inyectar este bloque en una página existente sin afectar al resto.',
          badges: ['Módulo'],
          nivel: 0,
          style: 'expanded'
        }
      ]
    },
    item: {
      id: 'item_extra',
      type: 'card',
      nombre: 'Nuevo subtema inyectado',
      resumen: 'Se añadirá a la categoría seleccionada.',
      descripcionLarga: 'Ejemplo de inserción incremental de un subtema reutilizable.',
      badges: ['Nuevo'],
      nivel: 1,
      style: 'collapsed'
    }
  }
};
