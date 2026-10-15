# Importar Ayuntamiento Tecnico Medio TIC

El importador usa Python 3 y `requests`. Lee las credenciales de `.env.local`
(excluido de Git) y necesita una cuenta con rol `admin` para subir teoría.

```dotenv
APRENTIX_API_URL=https://api.aprentix.es
APRENTIX_TEORIA_URL=https://aprentix.es/teoria
APRENTIX_USER=...
APRENTIX_PASSWORD=...
```

Validación local sin conectarse ni escribir en la plataforma:

```bash
python scripts/importar_oposicion.py --dry-run
```

Importar o reanudar una carga:

```bash
python scripts/importar_oposicion.py
```

`--source`, `--env` y `--report` permiten cambiar las rutas. Por defecto se
importa el corpus local Técnico Medio TIC 2026 y se guarda un informe sin
credenciales en `/tmp/aprentix-importacion-tic.json`.

El proceso crea o reutiliza la oposición exacta, conserva la estructura de
bloques, sube todos los documentos Markdown/HTML/TXT y sincroniza un test por
fichero JSON. Comprueba el contenido de los Markdown existentes antes de
actualizarlos; no crea nombres con sufijos al reanudar. Las escrituras con una
respuesta de red ambigua no se repiten automáticamente. Si se interrumpe, se
puede volver a ejecutar.

Cada pregunta conserva su explicación y añade una referencia a su Markdown.
Para preguntas compartidas, conserva las explicaciones y referencias existentes
y añade la nueva referencia. Se verifica la referencia leyendo cada test después
de actualizarlo. La sincronización actualiza tests del mismo título: no usarla
con una oposición que contenga cambios manuales que se quieran conservar.

Los cambios de `web/tests/app.js` y `web/teoria/app.js` deben desplegarse en el
stack **app** para convertir las referencias guardadas en enlaces pulsables y
abrir el documento en el visor de teoría. No se necesitan migraciones SQL.

Comprobaciones:

```bash
python -m unittest discover -s scripts/tests
node scripts/tests/test_theory_links.cjs
node --check web/tests/app.js
node --check web/teoria/app.js
```
