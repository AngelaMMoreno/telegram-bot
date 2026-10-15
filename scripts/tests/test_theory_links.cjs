const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync('web/tests/app.js', 'utf8');
const match = source.match(/function renderExplanation\(element, text\) \{[\s\S]*?\n\}/);
assert.ok(match, 'Debe existir renderExplanation');
function element(tag = 'div') { return {tag, children: [], replaceChildren(...nodes) {this.children=nodes;}, append(...nodes) {this.children.push(...nodes);} }; }
const context = {document: {createTextNode: text => ({text}), createElement: element}, URL, location: {origin:'https://aprentix.es'}};
vm.createContext(context); vm.runInContext(match[0], context);
const el = element();
context.renderExplanation(el, 'Respuesta <script>\nConsultar teoría: https://aprentix.es/teoria/?archivo=%2Fa.md');
assert.equal(el.children.filter(x=>x.tag==='a').length, 1);
assert.equal(el.children.find(x=>x.tag==='a').textContent, 'Consultar teoría');
assert.ok(el.children.some(x=>x.text?.includes('<script>')));
context.renderExplanation(el, 'https://evil.example/teoria/?archivo=x javascript:alert(1)');
assert.equal(el.children.filter(x=>x.tag==='a').length, 0);
console.log('Enlaces seguros y explicación conservada: OK');
assert.doesNotThrow(() => context.renderExplanation(el, 'Ejemplo: https://<servidor>'));
assert.ok(el.children.some(x => x.text?.includes('https://<servidor>')));
