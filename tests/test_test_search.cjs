const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync('web/tests/app.js', 'utf8');
const extract = name => source.match(new RegExp(`(?:async )?function ${name}\\([^]*?\\n\\}`))[0];
const handlers = {};
const calls = [];
const nodes = new Map();
const state = {
  user: { puede_gestionar: true }, currentOposicion: 'op-tic',
  filtroTests: '', testsPage: 4, filtroVisTests: 'todos',
  filtroEtiquetaTests: null, ordenTests: 'reciente', testsCache: [],
};
const context = {
  state, setTimeout: fn => { context.pending = fn; return 1; }, clearTimeout() {},
  $: selector => {
    if (!nodes.has(selector)) nodes.set(selector, {
      innerHTML: '', children: [], classList: { add() {}, remove() {} },
    });
    return nodes.get(selector);
  },
  on: (selector, event, handler) => { handlers[selector] = handler; },
  ensureEtiquetasCache: async () => {}, renderTagChips() {},
  esc: value => value,
  rpc: async (name, args) => {
    calls.push({ name, args });
    if (name === 'listar_etiquetas') return [];
    return { tests: [{ id: 'ipv4', title: 'IPv4_Direccionamiento_Subnetting', num_preguntas: 20 }],
      page: 1, total: 1, total_pages: 1 };
  },
};
vm.createContext(context);
vm.runInContext(['necesitaOposicion', 'loadTests', 'renderTests', 'renderPagination'].map(extract).join('\n') + '\n' +
  source.match(/on\("#tests-filter", "input",[^]*?\n\}\);/)[0], context);
(async () => {
  handlers['#tests-filter']({ target: { value: ' IPv4_Direccionamiento_Subnetting ' } });
  if (context.pending) await context.pending();
  const request = calls.find(c => c.name === 'listar_tests');
  assert.ok(request, 'Buscar debe consultar la API, no filtrar solo la página cargada');
  assert.equal(request.args.p_busqueda, 'IPv4_Direccionamiento_Subnetting');
  assert.equal(request.args.p_page, 1, 'Una nueva búsqueda debe volver a la primera página');
  assert.equal(request.args.p_oposicion_id, 'op-tic');
  assert.match(nodes.get('#tests-list').innerHTML, /IPv4_Direccionamiento_Subnetting/);
  assert.match(nodes.get('#tests-pagination').innerHTML, /data-page="1"/);
  calls.length = 0;
  handlers['#tests-filter']({ target: { value: '' } });
  if (context.pending) await context.pending();
  assert.equal(calls.find(c => c.name === 'listar_tests').args.p_busqueda, null);
  // Una respuesta lenta de una búsqueda anterior no debe reemplazar la nueva.
  const waiting = [];
  context.rpc = async (name, args) => {
    if (name === 'listar_etiquetas') return [];
    return new Promise(resolve => waiting.push({ args, resolve }));
  };
  state.filtroTests = 'viejo';
  const oldRequest = context.loadTests();
  while (waiting.length < 1) await Promise.resolve();
  state.filtroTests = 'IPv4';
  const newRequest = context.loadTests();
  while (waiting.length < 2) await Promise.resolve();
  waiting[1].resolve({ tests: [{ id: 'ipv4', title: 'IPv4_Direccionamiento_Subnetting' }], page: 1, total_pages: 1 });
  await newRequest;
  waiting[0].resolve({ tests: [{ id: 'old', title: 'viejo' }], page: 1, total_pages: 1 });
  await oldRequest;
  assert.match(nodes.get('#tests-list').innerHTML, /IPv4_Direccionamiento_Subnetting/);
  assert.doesNotMatch(nodes.get('#tests-list').innerHTML, /viejo/);
  console.log('Búsqueda por API, oposición, paginación, limpieza y respuestas desordenadas: OK');
})().catch(error => { console.error(error); process.exitCode = 1; });
