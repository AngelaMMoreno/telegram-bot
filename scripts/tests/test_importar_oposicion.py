import unittest
import tempfile
import json
from unittest.mock import Mock
import requests
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from importar_oposicion import add_reference, inventory, Client

class ImportTests(unittest.TestCase):
    def test_reference_preserves_text_and_is_idempotent(self):
        url = 'https://aprentix.es/teoria/?archivo=%2FA%20B.md'
        result = add_reference('Explicación original.', url)
        self.assertIn('Explicación original.', result)
        self.assertIn(url, result)
        self.assertEqual(result, add_reference(result, url))

    def test_rejects_invalid_options_before_upload(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / 'tests').mkdir()
            (root / 'Tema.md').write_text('# Tema')
            (root / 'tests/Tema.json').write_text(json.dumps([
                {'pregunta': 'Pregunta', 'opciones': ['Sí', {'texto': 'No', 'correcta': False}]}
            ]))
            with self.assertRaises(ValueError):
                inventory(root)

    def test_ambiguous_write_is_not_retried(self):
        client = object.__new__(Client)
        client.session = Mock()
        client.session.request.side_effect = requests.ReadTimeout()
        with self.assertRaises(RuntimeError):
            client.call('https://example.test/rpc/crear_oposicion', {})
        self.assertEqual(client.session.request.call_count, 1)

    def test_all_local_tests_have_theory(self):
        root = Path('/home/ccobos/Documentos/Opo/Ayuntamiento Madrid/Tecnico Medio TIC 2026/temas')
        if not root.exists():
            self.skipTest('Corpus local no disponible')
        items = inventory(root)
        self.assertEqual(len(items), 306)
        self.assertEqual(sum(len(i['questions']) for i in items), 14950)
        self.assertTrue(all(i['theory'].is_file() for i in items))

if __name__ == '__main__': unittest.main()
