const estadoAplicacion = {
  pagina: null,
  rutaSeleccionada: null,
  itemDetalleActivo: null
};

const mapaColoresCategoria = {
  'c-app': '#375dfb',
  'c-redes': '#16a34a',
  'c-ada': '#7c3aed',
  'c-datos': '#ea580c'
};

const editorJson = document.getElementById('editor-json');
const editorFragmento = document.getElementById('editor-fragmento');
const lienzo = document.getElementById('lienzo');
const formularioInspector = document.getElementById('formulario-inspector');
const estadoJson = document.getElementById('estado-json');
const rutaSeleccion = document.getElementById('ruta-seleccion');

function clonarProfundo(valor) {
  return JSON.parse(JSON.stringify(valor));
}

function normalizarPagina(pagina) {
  const paginaNormalizada = {
    config: {
      tituloPagina: pagina?.config?.tituloPagina || 'Página sin título',
      subtituloPagina: pagina?.config?.subtituloPagina || '',
      banner: {
        mostrar: Boolean(pagina?.config?.banner?.mostrar),
        titulo: pagina?.config?.banner?.titulo || '',
        etiqueta: pagina?.config?.banner?.etiqueta || 'SISTEMA',
        descripcion: pagina?.config?.banner?.descripcion || ''
      },
      pie: {
        texto: pagina?.config?.pie?.texto || 'Pie de página sin configurar.',
        accion: pagina?.config?.pie?.accion || 'Añade contenido desde el inspector o el editor JSON.'
      }
    },
    categorias: Array.isArray(pagina?.categorias)
      ? pagina.categorias.map(normalizarCategoria)
      : []
  };

  return paginaNormalizada;
}

function normalizarCategoria(categoria, indice = 0) {
  const color = categoria?.color || mapaColoresCategoria[categoria?.colorClase] || '#375dfb';
  return {
    id: categoria?.id || `cat_${Date.now()}_${indice}`,
    type: categoria?.type || 'categoria',
    nombre: categoria?.nombre || 'Nueva categoría',
    icono: categoria?.icono || '🗂️',
    colorClase: categoria?.colorClase || 'c-app',
    color,
    desplegable: categoria?.desplegable !== false,
    abierta: categoria?.abierta !== false,
    descripcion: categoria?.descripcion || '',
    items: Array.isArray(categoria?.items)
      ? categoria.items.map((item, indiceItem) => normalizarItem(item, indiceItem))
      : []
  };
}

function normalizarItem(item, indice = 0) {
  return {
    id: item?.id || `item_${Date.now()}_${indice}`,
    type: item?.type || 'card',
    nombre: item?.nombre || 'Nuevo elemento',
    resumen: item?.resumen || '',
    descripcionLarga: item?.descripcionLarga || '',
    notaRelacionada: item?.notaRelacionada || '',
    badges: Array.isArray(item?.badges) ? item.badges : [],
    nivel: Number.isFinite(item?.nivel) ? item.nivel : Number(item?.nivel || 0),
    style: item?.style || 'expanded'
  };
}

function obtenerValorPorRuta(objeto, ruta) {
  return ruta.reduce((actual, segmento) => (actual == null ? undefined : actual[segmento]), objeto);
}

function establecerValorPorRuta(objeto, ruta, valor) {
  const rutaPadre = ruta.slice(0, -1);
  const claveFinal = ruta[ruta.length - 1];
  const padre = obtenerValorPorRuta(objeto, rutaPadre);
  if (padre != null) {
    padre[claveFinal] = valor;
  }
}

function actualizarEditorDesdeEstado() {
  editorJson.value = JSON.stringify(estadoAplicacion.pagina, null, 2);
}

function establecerEstadoMensaje(texto, tipo = 'neutro') {
  estadoJson.textContent = texto;
  estadoJson.className = `estado estado-${tipo}`;
}

function seleccionarRuta(ruta) {
  estadoAplicacion.rutaSeleccionada = ruta;
  rutaSeleccion.textContent = ruta ? ruta.join(' › ') : 'Sin selección';
  renderizarInspector();
  renderizarVistaPrevia();
}

function seleccionarItemDetalle(ruta) {
  estadoAplicacion.itemDetalleActivo = ruta;
  seleccionarRuta(ruta);
}

function aplicarJsonCompleto(texto) {
  try {
    const json = JSON.parse(texto);
    estadoAplicacion.pagina = normalizarPagina(json);
    if (!estadoAplicacion.rutaSeleccionada) {
      seleccionarRuta(['config']);
    }
    actualizarEditorDesdeEstado();
    renderizarVistaPrevia();
    renderizarInspector();
    establecerEstadoMensaje('JSON renderizado correctamente.', 'exito');
  } catch (error) {
    establecerEstadoMensaje(`JSON inválido: ${error.message}`, 'error');
  }
}

function inyectarFragmento() {
  try {
    const fragmento = JSON.parse(editorFragmento.value);
    const pagina = estadoAplicacion.pagina;

    if (Array.isArray(fragmento)) {
      fragmento.forEach((categoria, indice) => pagina.categorias.push(normalizarCategoria(categoria, indice)));
      establecerEstadoMensaje('Se han inyectado varias categorías.', 'exito');
    } else if (fragmento.type === 'categoria' || fragmento.items || (fragmento.nombre && fragmento.icono)) {
      pagina.categorias.push(normalizarCategoria(fragmento));
      establecerEstadoMensaje('Se ha inyectado una nueva categoría.', 'exito');
    } else if (fragmento.type === 'card' || fragmento.nombre) {
      const indiceCategoria = encontrarIndiceCategoriaSeleccionada();
      if (indiceCategoria < 0) {
        throw new Error('Selecciona una categoría antes de inyectar un item.');
      }
      pagina.categorias[indiceCategoria].items.push(normalizarItem(fragmento));
      establecerEstadoMensaje('Se ha inyectado un nuevo item en la categoría seleccionada.', 'exito');
    } else {
      throw new Error('El fragmento no tiene un formato compatible.');
    }

    actualizarEditorDesdeEstado();
    renderizarVistaPrevia();
    renderizarInspector();
  } catch (error) {
    establecerEstadoMensaje(`No se pudo inyectar el fragmento: ${error.message}`, 'error');
  }
}

function encontrarIndiceCategoriaSeleccionada() {
  const ruta = estadoAplicacion.rutaSeleccionada;
  if (!ruta) {
    return estadoAplicacion.pagina.categorias.length ? 0 : -1;
  }

  const indiceCategorias = ruta.indexOf('categorias');
  if (indiceCategorias >= 0) {
    return Number(ruta[indiceCategorias + 1]);
  }

  return estadoAplicacion.pagina.categorias.length ? 0 : -1;
}

function renderizarVistaPrevia() {
  const pagina = estadoAplicacion.pagina;
  lienzo.innerHTML = '';

  const seccionPagina = document.createElement('section');
  seccionPagina.className = 'pagina';

  const cabecera = document.createElement('header');
  cabecera.className = 'cabecera-pagina';
  cabecera.innerHTML = `
    <h2>${escaparHtml(pagina.config.tituloPagina)}</h2>
    <p class="texto-secundario">${escaparHtml(pagina.config.subtituloPagina)}</p>
  `;
  cabecera.addEventListener('click', () => seleccionarRuta(['config']));
  seccionPagina.appendChild(cabecera);

  if (pagina.config.banner.mostrar) {
    const banner = document.createElement('section');
    banner.className = 'banner-principal';
    banner.innerHTML = `
      <p class="etiqueta-superior">${escaparHtml(pagina.config.banner.etiqueta)}</p>
      <h3>${escaparHtml(pagina.config.banner.titulo)}</h3>
      <p>${escaparHtml(pagina.config.banner.descripcion)}</p>
    `;
    banner.addEventListener('click', () => seleccionarRuta(['config', 'banner']));
    seccionPagina.appendChild(banner);
  }

  if (!pagina.categorias.length) {
    const vacio = document.createElement('div');
    vacio.className = 'modulo-vacio';
    vacio.textContent = 'La página está vacía. Usa la plantilla completa, el inspector o la inyección incremental para empezar.';
    seccionPagina.appendChild(vacio);
  } else {
    const rejilla = document.createElement('div');
    rejilla.className = 'rejilla-categorias';

    pagina.categorias.forEach((categoria, indiceCategoria) => {
      rejilla.appendChild(crearTarjetaCategoria(categoria, indiceCategoria));
    });

    seccionPagina.appendChild(rejilla);
  }

  seccionPagina.appendChild(crearPanelDetalle());

  const pie = document.createElement('footer');
  pie.className = 'pie-pagina';
  pie.innerHTML = `
    <div>
      <strong>${escaparHtml(pagina.config.pie.texto)}</strong>
      <p>${escaparHtml(pagina.config.pie.accion)}</p>
    </div>
    <button class="boton boton-secundario" type="button">Añadir módulo</button>
  `;
  pie.addEventListener('click', () => seleccionarRuta(['config', 'pie']));
  seccionPagina.appendChild(pie);

  lienzo.appendChild(seccionPagina);
}

function crearTarjetaCategoria(categoria, indiceCategoria) {
  const tarjeta = document.createElement('article');
  tarjeta.className = 'tarjeta-categoria';
  tarjeta.style.setProperty('--fondo-categoria', `${categoria.color}15`);
  tarjeta.style.setProperty('--color-acento', categoria.color);

  const cabecera = document.createElement('div');
  cabecera.className = 'cabecera-categoria';
  cabecera.innerHTML = `
    <div>
      <p class="etiqueta-categoria">${escaparHtml(categoria.icono)} ${escaparHtml(categoria.colorClase)}</p>
      <h3>${escaparHtml(categoria.nombre)}</h3>
      <p class="texto-secundario">${escaparHtml(categoria.descripcion || 'Categoría modular editable.')}</p>
    </div>
  `;

  const botonAlternar = document.createElement('button');
  botonAlternar.type = 'button';
  botonAlternar.textContent = categoria.desplegable
    ? categoria.abierta ? 'Contraer' : 'Expandir'
    : 'Fija';
  botonAlternar.disabled = !categoria.desplegable;
  botonAlternar.addEventListener('click', (evento) => {
    evento.stopPropagation();
    if (categoria.desplegable) {
      categoria.abierta = !categoria.abierta;
      actualizarEditorDesdeEstado();
      renderizarVistaPrevia();
      renderizarInspector();
    }
  });
  cabecera.appendChild(botonAlternar);
  cabecera.addEventListener('click', () => seleccionarRuta(['categorias', indiceCategoria]));

  tarjeta.appendChild(cabecera);

  const cuerpo = document.createElement('div');
  cuerpo.className = 'cuerpo-categoria';
  cuerpo.hidden = categoria.desplegable && !categoria.abierta;

  categoria.items.forEach((item, indiceItem) => {
    cuerpo.appendChild(crearTarjetaItem(item, indiceCategoria, indiceItem, categoria.color));
  });

  if (!categoria.items.length) {
    const vacio = document.createElement('div');
    vacio.className = 'modulo-vacio';
    vacio.textContent = 'Categoría sin tarjetas. Inyecta un item o crea uno desde el inspector.';
    cuerpo.appendChild(vacio);
  }

  tarjeta.appendChild(cuerpo);
  return tarjeta;
}

function crearTarjetaItem(item, indiceCategoria, indiceItem, colorCategoria) {
  const ruta = ['categorias', indiceCategoria, 'items', indiceItem];
  const tarjeta = document.createElement('button');
  tarjeta.type = 'button';
  tarjeta.className = `tarjeta-item nivel-${item.nivel || 0}`;
  tarjeta.style.setProperty('--color-acento', colorCategoria);

  const activa = JSON.stringify(estadoAplicacion.itemDetalleActivo) === JSON.stringify(ruta);
  if (activa) {
    tarjeta.classList.add('item-activo');
  }

  const badges = Array.isArray(item.badges) && item.badges.length
    ? `<div class="badges">${item.badges.map((badge) => `<span class="etiqueta-badge">${escaparHtml(badge)}</span>`).join('')}</div>`
    : '';

  tarjeta.innerHTML = `
    <div class="fila-titulo-item">
      <div>
        <p class="etiqueta-modulo">${escaparHtml(item.type)} · ${escaparHtml(item.style)}</p>
        <h4>${escaparHtml(item.nombre)}</h4>
      </div>
      <span>${item.nivel > 0 ? '↳' : '→'}</span>
    </div>
    <p class="texto-secundario">${escaparHtml(item.resumen)}</p>
    ${badges}
  `;

  tarjeta.addEventListener('click', () => seleccionarItemDetalle(ruta));
  return tarjeta;
}

function crearPanelDetalle() {
  const panel = document.createElement('section');
  panel.className = 'panel-detalle';

  const ruta = estadoAplicacion.itemDetalleActivo;
  const item = ruta ? obtenerValorPorRuta(estadoAplicacion.pagina, ruta) : null;

  if (!item) {
    panel.innerHTML = `
      <h3>Panel de detalle</h3>
      <p class="texto-secundario">Selecciona una tarjeta para ver y editar su contenido detallado.</p>
    `;
    return panel;
  }

  panel.innerHTML = `
    <p class="etiqueta-superior">DETALLE ACTIVO</p>
    <h3>${escaparHtml(item.nombre)}</h3>
    <p>${escaparHtml(item.descripcionLarga || item.resumen || 'Sin descripción.')}</p>
    ${item.notaRelacionada ? `<div class="nota">${item.notaRelacionada}</div>` : ''}
  `;

  return panel;
}

function renderizarInspector() {
  const ruta = estadoAplicacion.rutaSeleccionada;
  formularioInspector.innerHTML = '';

  if (!ruta) {
    formularioInspector.innerHTML = '<p class="texto-secundario">Selecciona una parte de la página para editarla.</p>';
    return;
  }

  const valor = obtenerValorPorRuta(estadoAplicacion.pagina, ruta);
  if (!valor || typeof valor !== 'object') {
    formularioInspector.innerHTML = '<p class="texto-secundario">La selección actual no es editable desde el inspector.</p>';
    return;
  }

  const campos = describirCampos(ruta, valor);
  campos.forEach((campo) => {
    formularioInspector.appendChild(crearCampoInspector(campo, valor));
  });

  formularioInspector.appendChild(crearAccionesInspector(ruta));
}

function describirCampos(ruta, valor) {
  const claveFinal = ruta[ruta.length - 1];

  if (claveFinal === 'config') {
    return [
      { clave: 'tituloPagina', etiqueta: 'Título de página', tipo: 'texto' },
      { clave: 'subtituloPagina', etiqueta: 'Subtítulo', tipo: 'texto' }
    ];
  }

  if (claveFinal === 'banner') {
    return [
      { clave: 'mostrar', etiqueta: 'Mostrar banner', tipo: 'booleano' },
      { clave: 'etiqueta', etiqueta: 'Etiqueta', tipo: 'texto' },
      { clave: 'titulo', etiqueta: 'Título del banner', tipo: 'texto' },
      { clave: 'descripcion', etiqueta: 'Descripción', tipo: 'texto-largo' }
    ];
  }

  if (claveFinal === 'pie') {
    return [
      { clave: 'texto', etiqueta: 'Texto principal', tipo: 'texto' },
      { clave: 'accion', etiqueta: 'Texto de acción', tipo: 'texto' }
    ];
  }

  if (valor.type === 'categoria') {
    return [
      { clave: 'nombre', etiqueta: 'Nombre', tipo: 'texto' },
      { clave: 'icono', etiqueta: 'Icono', tipo: 'texto' },
      { clave: 'colorClase', etiqueta: 'Clase semántica', tipo: 'texto' },
      { clave: 'color', etiqueta: 'Color', tipo: 'color' },
      { clave: 'descripcion', etiqueta: 'Descripción', tipo: 'texto-largo' },
      { clave: 'desplegable', etiqueta: 'Es desplegable', tipo: 'booleano' },
      { clave: 'abierta', etiqueta: 'Está abierta', tipo: 'booleano' }
    ];
  }

  if (valor.type === 'card') {
    return [
      { clave: 'nombre', etiqueta: 'Nombre', tipo: 'texto' },
      { clave: 'resumen', etiqueta: 'Resumen', tipo: 'texto-largo' },
      { clave: 'descripcionLarga', etiqueta: 'Descripción larga', tipo: 'texto-largo' },
      { clave: 'notaRelacionada', etiqueta: 'Nota HTML', tipo: 'texto-largo' },
      { clave: 'nivel', etiqueta: 'Nivel jerárquico', tipo: 'numero' },
      { clave: 'style', etiqueta: 'Estilo', tipo: 'seleccion', opciones: ['expanded', 'collapsed'] },
      { clave: 'badges', etiqueta: 'Badges (coma separada)', tipo: 'lista' }
    ];
  }

  return Object.keys(valor).map((clave) => ({ clave, etiqueta: clave, tipo: 'texto' }));
}

function crearCampoInspector(campo, valor) {
  if (campo.tipo === 'booleano') {
    const contenedor = document.createElement('label');
    contenedor.className = 'control-checkbox';

    const entrada = document.createElement('input');
    entrada.type = 'checkbox';
    entrada.checked = Boolean(valor[campo.clave]);
    entrada.addEventListener('change', () => {
      valor[campo.clave] = entrada.checked;
      sincronizarCambiosDesdeInspector();
    });

    const texto = document.createElement('span');
    texto.textContent = campo.etiqueta;
    contenedor.append(entrada, texto);
    return contenedor;
  }

  const grupo = document.createElement('div');
  grupo.className = 'campo-inspector';

  const etiqueta = document.createElement('label');
  etiqueta.textContent = campo.etiqueta;
  grupo.appendChild(etiqueta);

  let entrada;

  if (campo.tipo === 'texto-largo') {
    entrada = document.createElement('textarea');
    entrada.className = 'textarea-inspector';
    entrada.value = valor[campo.clave] || '';
  } else if (campo.tipo === 'seleccion') {
    entrada = document.createElement('select');
    entrada.className = 'selector-inspector';
    campo.opciones.forEach((opcion) => {
      const nodoOpcion = document.createElement('option');
      nodoOpcion.value = opcion;
      nodoOpcion.textContent = opcion;
      nodoOpcion.selected = valor[campo.clave] === opcion;
      entrada.appendChild(nodoOpcion);
    });
  } else {
    entrada = document.createElement('input');
    entrada.className = 'entrada-inspector';
    entrada.type = campo.tipo === 'numero' ? 'number' : campo.tipo === 'color' ? 'color' : 'text';
    if (campo.tipo === 'color') {
      entrada.value = valor[campo.clave] || '#375dfb';
    } else {
      entrada.value = campo.tipo === 'lista'
        ? (valor[campo.clave] || []).join(', ')
        : valor[campo.clave] ?? '';
    }
  }

  entrada.addEventListener('input', () => {
    if (campo.tipo === 'numero') {
      valor[campo.clave] = Number(entrada.value || 0);
    } else if (campo.tipo === 'lista') {
      valor[campo.clave] = entrada.value
        .split(',')
        .map((elemento) => elemento.trim())
        .filter(Boolean);
    } else {
      valor[campo.clave] = entrada.value;
    }

    if (campo.clave === 'colorClase' && !valor.color) {
      valor.color = mapaColoresCategoria[entrada.value] || '#375dfb';
    }

    sincronizarCambiosDesdeInspector();
  });

  grupo.appendChild(entrada);
  return grupo;
}

function crearAccionesInspector(ruta) {
  const contenedor = document.createElement('div');
  contenedor.className = 'acciones-inspector';

  const botonAgregarCategoria = document.createElement('button');
  botonAgregarCategoria.type = 'button';
  botonAgregarCategoria.className = 'boton boton-secundario';
  botonAgregarCategoria.textContent = 'Añadir categoría';
  botonAgregarCategoria.addEventListener('click', () => {
    estadoAplicacion.pagina.categorias.push(normalizarCategoria({ nombre: 'Nueva categoría' }));
    seleccionarRuta(['categorias', estadoAplicacion.pagina.categorias.length - 1]);
    sincronizarCambiosDesdeInspector();
  });

  const botonAgregarItem = document.createElement('button');
  botonAgregarItem.type = 'button';
  botonAgregarItem.className = 'boton boton-primario';
  botonAgregarItem.textContent = 'Añadir item';
  botonAgregarItem.addEventListener('click', () => {
    const indiceCategoria = encontrarIndiceCategoriaSeleccionada();
    if (indiceCategoria < 0) {
      establecerEstadoMensaje('Debes seleccionar o crear una categoría antes de añadir items.', 'error');
      return;
    }
    const items = estadoAplicacion.pagina.categorias[indiceCategoria].items;
    items.push(normalizarItem({ nombre: 'Nuevo item', nivel: 0 }));
    seleccionarItemDetalle(['categorias', indiceCategoria, 'items', items.length - 1]);
    sincronizarCambiosDesdeInspector();
  });

  const botonEliminar = document.createElement('button');
  botonEliminar.type = 'button';
  botonEliminar.className = 'boton boton-fantasma';
  botonEliminar.textContent = 'Eliminar selección';
  botonEliminar.addEventListener('click', () => eliminarSeleccionActual(ruta));

  contenedor.append(botonAgregarCategoria, botonAgregarItem, botonEliminar);
  return contenedor;
}

function eliminarSeleccionActual(ruta) {
  if (!ruta || ruta.length < 2) {
    establecerEstadoMensaje('La selección actual no se puede eliminar.', 'error');
    return;
  }

  const clavePadre = ruta[ruta.length - 2];
  const indice = Number(ruta[ruta.length - 1]);
  const rutaPadre = ruta.slice(0, -2);
  const contenedor = obtenerValorPorRuta(estadoAplicacion.pagina, rutaPadre);

  if (Array.isArray(contenedor?.[clavePadre]) && Number.isInteger(indice)) {
    contenedor[clavePadre].splice(indice, 1);
    estadoAplicacion.itemDetalleActivo = null;
    seleccionarRuta(['config']);
    sincronizarCambiosDesdeInspector();
    return;
  }

  establecerEstadoMensaje('No se pudo eliminar la selección actual.', 'error');
}

function sincronizarCambiosDesdeInspector() {
  actualizarEditorDesdeEstado();
  renderizarVistaPrevia();
  renderizarInspector();
  establecerEstadoMensaje('Cambios sincronizados con el JSON.', 'exito');
}

function escaparHtml(valor) {
  return String(valor ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function inicializarEventos() {
  document.getElementById('boton-plantilla-base').addEventListener('click', () => {
    estadoAplicacion.pagina = normalizarPagina(clonarProfundo(window.EJEMPLOS_PLANTILLAS.base));
    seleccionarRuta(['config']);
    actualizarEditorDesdeEstado();
    renderizarVistaPrevia();
    renderizarInspector();
    establecerEstadoMensaje('Plantilla base cargada.', 'exito');
  });

  document.getElementById('boton-plantilla-completa').addEventListener('click', () => {
    estadoAplicacion.pagina = normalizarPagina(clonarProfundo(window.EJEMPLOS_PLANTILLAS.completa));
    seleccionarRuta(['categorias', 0, 'items', 0]);
    actualizarEditorDesdeEstado();
    renderizarVistaPrevia();
    renderizarInspector();
    establecerEstadoMensaje('Plantilla completa cargada.', 'exito');
  });

  document.getElementById('boton-formatear').addEventListener('click', () => {
    aplicarJsonCompleto(editorJson.value);
  });

  document.getElementById('boton-inyectar').addEventListener('click', inyectarFragmento);

  let temporizador;
  editorJson.addEventListener('input', () => {
    clearTimeout(temporizador);
    temporizador = setTimeout(() => aplicarJsonCompleto(editorJson.value), 220);
  });
}

function inicializarAplicacion() {
  estadoAplicacion.pagina = normalizarPagina(clonarProfundo(window.EJEMPLOS_PLANTILLAS.completa));
  editorFragmento.value = JSON.stringify(window.EJEMPLOS_PLANTILLAS.fragmento.item, null, 2);
  seleccionarRuta(['categorias', 0, 'items', 0]);
  actualizarEditorDesdeEstado();
  renderizarVistaPrevia();
  renderizarInspector();
  inicializarEventos();
}

inicializarAplicacion();
