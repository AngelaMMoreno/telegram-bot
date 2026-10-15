"""Importación reanudable mediante APIs públicas; no registra credenciales."""
import argparse
import json
import os
from pathlib import Path
import time
from urllib.parse import urlencode
import requests

NAME = 'Ayuntamiento Tecnico Medio TIC'
DEFAULT_SOURCE = '/home/ccobos/Documentos/Opo/Ayuntamiento Madrid/Tecnico Medio TIC 2026/temas'


def add_reference(explanation, url):
    text = explanation or ''
    return text if url in text else (text.rstrip() + '\n\nConsultar teoría: ' + url).strip()


def inventory(root):
    items = []
    titles = set()
    for path in sorted(root.rglob('*.json')):
        questions = json.loads(path.read_text(encoding='utf-8'))
        theory = path.parent.parent / (path.stem + '.md')
        if not theory.is_file() or not isinstance(questions, list) or not questions:
            raise ValueError(f'Test sin teoría o vacío: {path}')
        title = path.stem
        if title.casefold() in titles:
            raise ValueError(f'Título repetido: {title}')
        titles.add(title.casefold())
        for n, q in enumerate(questions, 1):
            if not isinstance(q, dict) or not isinstance(q.get('pregunta'), str) or not q['pregunta'].strip():
                raise ValueError(f'Enunciado inválido: {path}:{n}')
            opts = q.get('opciones')
            if not isinstance(opts, list) or len(opts) < 2:
                raise ValueError(f'Opciones inválidas: {path}:{n}')
            strings = all(isinstance(o, str) and o.strip() for o in opts)
            objects = all(isinstance(o, dict) and isinstance(o.get('texto'), str) and o['texto'].strip() and isinstance(o.get('correcta'), bool) for o in opts)
            if not strings and not (objects and any(o['correcta'] for o in opts)):
                raise ValueError(f'Formato de opciones inválido: {path}:{n}')
            if q.get('explicacion') is not None and not isinstance(q['explicacion'], str):
                raise ValueError(f'Explicación inválida: {path}:{n}')
        items.append(dict(title=title, theory=theory, questions=questions))
    if not items:
        raise ValueError('No hay tests')
    return items


def read_env(path):
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        key, value = line.split('=', 1)
        os.environ.setdefault(key.strip(), value.strip().strip('\"\''))


class Client:
    def __init__(self):
        self.base = os.environ['APRENTIX_API_URL'].rstrip('/')
        self.theory = os.environ['APRENTIX_TEORIA_URL'].rstrip('/')
        if not self.base.startswith('https://') or not self.theory.startswith('https://'):
            raise ValueError('Las URLs deben usar HTTPS')
        self.session = requests.Session()
        self.login()

    def login(self):
        r = self.session.post(self.base + '/rpc/login_web', json={
            'p_username': os.environ['APRENTIX_USER'], 'p_password': os.environ['APRENTIX_PASSWORD']}, timeout=60)
        if not r.ok:
            raise RuntimeError(f'Login: HTTP {r.status_code}')
        data = r.json()
        if 'admin' not in data.get('roles', []):
            raise RuntimeError('La subida de teoría requiere rol admin')
        self.session.headers['Authorization'] = 'Bearer ' + data['token']

    def call(self, url, body=None, method='POST'):
        for attempt in range(4):
            try:
                r = self.session.request(method, url, json=body, timeout=90)
            except requests.RequestException:
                if method != 'GET' or attempt == 3:
                    raise RuntimeError('Error de red; ejecutar de nuevo para reanudar sin repetir escrituras ambiguas') from None
                time.sleep(2 ** attempt)
                continue
            if r.status_code == 401 and attempt == 0:
                self.login()
                continue
            # Solo lecturas se reintentan en 5xx: una escritura podría haber terminado.
            if r.status_code >= 500 and method == 'GET' and attempt < 3:
                time.sleep(2 ** attempt)
                continue
            if not r.ok:
                raise RuntimeError(f'API HTTP {r.status_code} en {url.split("?")[0]}')
            return r.json() if r.content else None

    def rpc(self, name, body=None):
        return self.call(self.base + '/rpc/' + name, body or {})

    def listing(self, path):
        return self.call(self.theory + '/api/listar?' + urlencode({'ruta': path}), method='GET')

    def folder(self, parent, name):
        path = parent.rstrip('/') + '/' + name
        entries = self.listing(parent)
        if any(c['nombre'] == name for c in entries['carpetas']):
            return path
        self.call(self.theory + '/api/carpeta', {'padre': parent, 'nombre': name})
        return path

    def upload(self, local, remote):
        parent, name = remote.rsplit('/', 1)
        entries = self.listing(parent)
        if any(f['nombre'] == name for f in entries['ficheros']):
            # Comprobar contenido antes de saltar, sin crear sufijos duplicados.
            if local.suffix.lower() not in {'.md', '.markdown', '.txt'}:
                r = self.session.get(self.theory + '/api/ver', params={'ruta': remote}, timeout=90)
                if not r.ok or r.content != local.read_bytes():
                    raise RuntimeError('Documento binario existente diferente; revisar manualmente')
                return
            existing = self.call(self.theory + '/api/leer?' + urlencode({'ruta': remote}), method='GET')
            if existing['contenido'] != local.read_text(encoding='utf-8'):
                self.call(self.theory + '/api/guardar', {'ruta': remote, 'contenido': local.read_text(encoding='utf-8')})
            return
        with local.open('rb') as stream:
            r = self.session.post(self.theory + '/api/subir', data={'ruta': parent}, files={'files': (name, stream, 'text/markdown' if local.suffix == '.md' else 'text/html')}, timeout=90)
        if not r.ok: raise RuntimeError(f'Subida: HTTP {r.status_code}')
        if [f['ruta'] for f in r.json()['subidos']] != [remote]:
            raise RuntimeError('La subida renombró el documento; revisar antes de reanudar')


def run(args):
    source = Path(args.source)
    items = inventory(source)
    print(f'Validación: {len(items)} tests, {sum(len(i["questions"]) for i in items)} preguntas', flush=True)
    if args.dry_run: return
    read_env(Path(args.env))
    client = Client()
    opos = client.rpc('listar_oposiciones_admin')
    matches = [o for o in opos if o['nombre'].strip().casefold() == NAME.casefold()]
    if len(matches) > 1: raise RuntimeError('Oposiciones duplicadas; resolver antes de importar')
    op = matches[0] if matches else client.rpc('crear_oposicion', {'p_nombre': NAME, 'p_descripcion': 'Técnico Medio TIC · Ayuntamiento de Madrid · 2026'})
    destination = client.folder('/', NAME)
    client.rpc('set_carpeta_oposiciones', {'p_ruta': destination, 'p_oposicion_ids': [op['id']]})
    for block in sorted({i['theory'].parent.name for i in items}):
        client.folder(destination, block)
    # Índice, notas de revisión y ficha HTML original, además de las 306 fichas.
    matched = {i['theory'] for i in items}
    supplements = sorted(p for p in source.rglob('*') if p.is_file() and p.suffix.lower() in {'.md', '.html', '.txt'} and p not in matched)
    for local in supplements:
        remote = destination + '/' + local.relative_to(source).as_posix()
        client.upload(local, remote)
    report = {'oposicion_id': op['id'], 'documentos': len(items) + len(supplements), 'tests': [], 'errores': []}
    for index, item in enumerate(items, 1):
        try:
            remote = destination + '/' + item['theory'].relative_to(source).as_posix()
            client.upload(item['theory'], remote)
            url = client.theory + '/?' + urlencode({'archivo': remote})
            questions = [dict(q, explicacion=add_reference(q.get('explicacion'), url)) for q in item['questions']]
            result = client.rpc('sincronizar_test_en_oposicion', {'p_oposicion_id': op['id'], 'p_titulo': item['title'], 'p_descripcion': 'Consultar teoría: ' + url, 'p_preguntas': questions})
            # La deduplicación puede reutilizar preguntas compartidas y conservar su explicación.
            test = client.rpc('obtener_test', {'p_test_id': result['id']})
            for q in test['preguntas']:
                if url not in (q.get('explicacion') or ''):
                    client.rpc('editar_pregunta', {'p_pregunta_id': q['id'], 'p_explicacion': add_reference(q.get('explicacion'), url)})
            verified = client.rpc('obtener_test', {'p_test_id': result['id']})
            if not all(url in (q.get('explicacion') or '') for q in verified['preguntas']):
                raise RuntimeError('Faltan referencias a teoría')
            report['tests'].append({'titulo': item['title'], 'id': result['id'], 'preguntas': len(verified['preguntas']), 'teoria': remote})
            print(f'{index}/{len(items)} OK {item["title"]} ({len(verified["preguntas"])} preguntas)', flush=True)
        except Exception as e:
            report['errores'].append({'titulo': item['title'], 'motivo': str(e)})
            print(f'{index}/{len(items)} ERROR {item["title"]}: {e}', flush=True)
        Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    actual = client.rpc('listar_tests_de_oposicion', {'p_oposicion_id': op['id']})
    print(f'Resultado: {len(actual)} tests remotos; {len(report["errores"])} errores', flush=True)
    if report['errores']: raise SystemExit(1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', default=DEFAULT_SOURCE)
    parser.add_argument('--env', default='.env.local')
    parser.add_argument('--report', default='/tmp/aprentix-importacion-tic.json')
    parser.add_argument('--dry-run', action='store_true')
    try:
        run(parser.parse_args())
    except (RuntimeError, ValueError, KeyError) as e:
        parser.exit(1, f'{e}\n')
