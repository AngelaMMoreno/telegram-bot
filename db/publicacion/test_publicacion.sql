-- Pruebas del flujo de publicación. Cada bloque revienta si la invariante
-- que comprueba deja de cumplirse.
\set ON_ERROR_STOP on

-- Nos identificamos como admin ante las RPCs. `request.jwt.claims` es lo
-- que lee `es_admin()`; conectando directamente viene vacío.
SELECT set_config('request.jwt.claims',
                  json_build_object('sub', u.id, 'roles', json_build_array('admin'))::text,
                  false)
  FROM usuarios u JOIN usuario_roles ur ON ur.usuario_id = u.id
 WHERE ur.rol_id = 'admin' ORDER BY u.creado_en LIMIT 1 \gset _claims_

-- ── 1. Publicación inicial ──────────────────────────────────────────────
SELECT admin_publicar_estructura($$
{
  "oposicion": {"slug": "auxilio-judicial", "nombre": "Auxilio Judicial"},
  "temas": [{
    "slug": "ley-39-2015", "nombre": "Procedimiento Administrativo", "orden": 1,
    "modulos": [{
      "slug": "terminacion", "nombre": "Terminación del procedimiento", "orden": 1,
      "secciones": [
        {"slug": "silencio",   "nombre": "Silencio administrativo", "orden": 1},
        {"slug": "caducidad",  "nombre": "Caducidad",               "orden": 2},
        {"slug": "renuncia",   "nombre": "Desistimiento y renuncia","orden": 3}
      ]
    }]
  }]
}
$$::jsonb) AS publicacion_inicial \gset

-- Guardamos los uuids de partida: son los que NO deben cambiar jamás.
CREATE TEMP TABLE ids_v1 AS
SELECT s.slug, s.id
  FROM secciones s JOIN modulos m ON m.id = s.modulo_id
  JOIN temas t ON t.id = m.tema_id WHERE t.slug = 'ley-39-2015';

-- ── 2. Un usuario hace progreso ─────────────────────────────────────────
INSERT INTO progreso_seccion (usuario_id, seccion_id, intentos_totales, nota_max, completada_en, teoria_vista_en)
SELECT (SELECT id FROM usuarios ORDER BY creado_en LIMIT 1), id, 3, 90, now(), now()
  FROM ids_v1 WHERE slug = 'silencio';

-- ── 3. Se renombra TODO y se reordena, manteniendo los slugs ────────────
SELECT admin_publicar_estructura($$
{
  "oposicion": {"slug": "auxilio-judicial", "nombre": "Cuerpo de Auxilio Judicial (2027)"},
  "temas": [{
    "slug": "ley-39-2015", "nombre": "Ley 39/2015 — Procedimiento Común", "orden": 1,
    "modulos": [{
      "slug": "terminacion", "nombre": "Formas de terminación", "orden": 1,
      "secciones": [
        {"slug": "renuncia",  "nombre": "Desistimiento y renuncia del interesado", "orden": 1},
        {"slug": "silencio",  "nombre": "El silencio administrativo",              "orden": 2},
        {"slug": "caducidad", "nombre": "La caducidad del procedimiento",          "orden": 3}
      ]
    }]
  }]
}
$$::jsonb);

DO $$
DECLARE v_cambiados int; v_progreso int; v_nombre text;
BEGIN
    -- Ningún uuid se ha movido.
    SELECT count(*) INTO v_cambiados
      FROM ids_v1 v
      JOIN secciones s ON s.slug = v.slug
      JOIN modulos m ON m.id = s.modulo_id JOIN temas t ON t.id = m.tema_id
     WHERE t.slug = 'ley-39-2015' AND s.id <> v.id;
    IF v_cambiados <> 0 THEN
        RAISE EXCEPTION 'FALLO: % secciones cambiaron de uuid al renombrar', v_cambiados;
    END IF;

    -- El progreso sigue ahí.
    SELECT count(*) INTO v_progreso
      FROM progreso_seccion ps JOIN ids_v1 v ON v.id = ps.seccion_id
     WHERE v.slug = 'silencio' AND ps.completada_en IS NOT NULL;
    IF v_progreso <> 1 THEN
        RAISE EXCEPTION 'FALLO: el progreso desapareció al renombrar';
    END IF;

    -- Y el nombre nuevo sí se ha aplicado.
    SELECT s.nombre INTO v_nombre FROM secciones s JOIN ids_v1 v ON v.id = s.id
     WHERE v.slug = 'silencio';
    IF v_nombre <> 'El silencio administrativo' THEN
        RAISE EXCEPTION 'FALLO: el nombre no se actualizó (%)', v_nombre;
    END IF;

    RAISE NOTICE 'OK 1 — renombrar y reordenar conserva uuids y progreso';
END $$;

-- ── 4. Idempotencia: republicar lo mismo no crea nada ───────────────────
DO $$
DECLARE v_res jsonb; v_antes int; v_despues int;
BEGIN
    SELECT count(*) INTO v_antes FROM secciones;
    v_res := admin_publicar_estructura($json$
    {
      "oposicion": {"slug": "auxilio-judicial", "nombre": "Cuerpo de Auxilio Judicial (2027)"},
      "temas": [{
        "slug": "ley-39-2015", "nombre": "Ley 39/2015 — Procedimiento Común", "orden": 1,
        "modulos": [{"slug": "terminacion", "nombre": "Formas de terminación", "orden": 1,
          "secciones": [
            {"slug": "renuncia",  "nombre": "Desistimiento y renuncia del interesado", "orden": 1},
            {"slug": "silencio",  "nombre": "El silencio administrativo",              "orden": 2},
            {"slug": "caducidad", "nombre": "La caducidad del procedimiento",          "orden": 3}
          ]}]
      }]
    }
    $json$::jsonb);
    SELECT count(*) INTO v_despues FROM secciones;
    IF v_antes <> v_despues OR (v_res->>'creados')::int <> 0 THEN
        RAISE EXCEPTION 'FALLO: republicar creó filas (creados=%)', v_res->>'creados';
    END IF;
    RAISE NOTICE 'OK 2 — republicar es idempotente';
END $$;

-- ── 5. Quitar una sección del repo la ARCHIVA, no la borra ──────────────
DO $$
DECLARE v_res jsonb; v_archivada boolean; v_progreso int; v_home jsonb;
BEGIN
    v_res := admin_publicar_estructura($json$
    {
      "oposicion": {"slug": "auxilio-judicial"},
      "temas": [{"slug": "ley-39-2015", "orden": 1,
        "modulos": [{"slug": "terminacion", "orden": 1,
          "secciones": [
            {"slug": "renuncia",  "orden": 1},
            {"slug": "caducidad", "orden": 2}
          ]}]}]
    }
    $json$::jsonb, true);   -- archivar_ausentes = true

    SELECT s.archivada INTO v_archivada
      FROM secciones s JOIN ids_v1 v ON v.id = s.id WHERE v.slug = 'silencio';
    IF NOT v_archivada THEN
        RAISE EXCEPTION 'FALLO: la sección ausente no se archivó';
    END IF;

    -- Lo importante: la fila y el progreso SIGUEN existiendo.
    SELECT count(*) INTO v_progreso
      FROM progreso_seccion ps JOIN ids_v1 v ON v.id = ps.seccion_id
     WHERE v.slug = 'silencio';
    IF v_progreso <> 1 THEN
        RAISE EXCEPTION 'FALLO: archivar destruyó el progreso';
    END IF;

    -- Y ha desaparecido del home.
    v_home := mi_home_oposicion((SELECT id FROM oposiciones WHERE slug='auxilio-judicial'));
    IF v_home::text LIKE '%silencio administrativo%' THEN
        RAISE EXCEPTION 'FALLO: la sección archivada sigue saliendo en el home';
    END IF;
    RAISE NOTICE 'OK 3 — lo ausente se archiva, conserva progreso y sale del home';
END $$;

-- ── 6. Volver a añadirla la desarchiva ──────────────────────────────────
DO $$
DECLARE v_archivada boolean;
BEGIN
    PERFORM admin_publicar_estructura($json$
    {
      "oposicion": {"slug": "auxilio-judicial"},
      "temas": [{"slug": "ley-39-2015", "orden": 1,
        "modulos": [{"slug": "terminacion", "orden": 1,
          "secciones": [
            {"slug": "renuncia",  "orden": 1},
            {"slug": "silencio",  "orden": 2},
            {"slug": "caducidad", "orden": 3}
          ]}]}]
    }
    $json$::jsonb, true);
    SELECT s.archivada INTO v_archivada
      FROM secciones s JOIN ids_v1 v ON v.id = s.id WHERE v.slug = 'silencio';
    IF v_archivada THEN RAISE EXCEPTION 'FALLO: no se desarchivó al reaparecer'; END IF;
    RAISE NOTICE 'OK 4 — reaparecer en el repo desarchiva';
END $$;

-- ── 7. Borrar una sección con progreso está prohibido ───────────────────
DO $$
DECLARE v_sec uuid; v_err text;
BEGIN
    SELECT id INTO v_sec FROM ids_v1 WHERE slug = 'silencio';
    BEGIN
        PERFORM admin_borrar_seccion(v_sec);
        RAISE EXCEPTION 'FALLO: dejó borrar una sección con progreso';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
        IF v_err <> 'tiene_progreso' THEN RAISE; END IF;
    END;
    RAISE NOTICE 'OK 5 — borrar con progreso enganchado se rechaza';
END $$;

-- ── 8. Documentos: publicar, saltar sin cambios, respetar edición manual ─
DO $$
DECLARE v_res jsonb; v_doc jsonb; v_ts timestamptz; v_ts2 timestamptz;
BEGIN
    v_res := admin_publicar_documento('ley-39-2015','terminacion','silencio',
                '# Silencio administrativo\n\nRegla general…', 'temas/ley-39-2015/terminacion/silencio/teoria.md', 'abc1234');
    IF v_res->>'accion' <> 'creado' THEN RAISE EXCEPTION 'FALLO: no creó el documento (%)', v_res; END IF;

    -- La SPA lo recibe ya renderizable, sin segundo salto.
    v_doc := documento_de_seccion((SELECT id FROM ids_v1 WHERE slug='silencio'));
    IF v_doc->>'contenido' NOT LIKE '# Silencio%' THEN
        RAISE EXCEPTION 'FALLO: documento_de_seccion no devuelve el markdown';
    END IF;

    SELECT actualizado_en INTO v_ts FROM documentos WHERE id = (v_res->>'id')::uuid;
    PERFORM pg_sleep(0.05);
    v_res := admin_publicar_documento('ley-39-2015','terminacion','silencio',
                '# Silencio administrativo\n\nRegla general…', 'x', 'def5678');
    IF v_res->>'accion' <> 'sin_cambios' THEN
        RAISE EXCEPTION 'FALLO: republicar el mismo texto no se saltó (%)', v_res->>'accion';
    END IF;
    SELECT actualizado_en INTO v_ts2 FROM documentos WHERE id = (v_res->>'id')::uuid;
    IF v_ts2 <> v_ts THEN RAISE EXCEPTION 'FALLO: tocó actualizado_en sin cambios reales'; END IF;

    -- Alguien parchea a mano desde el panel…
    PERFORM admin_upsert_documento('seccion', (SELECT id FROM ids_v1 WHERE slug='silencio'),
                                   'teoria', '# Parche urgente');
    -- …y la siguiente publicación no lo pisa sin avisar.
    v_res := admin_publicar_documento('ley-39-2015','terminacion','silencio', '# Version de git', 'x', 'ghi');
    IF (v_res->>'ok')::boolean OR v_res->>'accion' <> 'editado_a_mano' THEN
        RAISE EXCEPTION 'FALLO: pisó una edición manual sin avisar (%)', v_res;
    END IF;
    -- Con --forzar sí.
    v_res := admin_publicar_documento('ley-39-2015','terminacion','silencio', '# Version de git', 'x', 'ghi', true);
    IF v_res->>'accion' <> 'actualizado' THEN
        RAISE EXCEPTION 'FALLO: --forzar no sobrescribió (%)', v_res;
    END IF;
    RAISE NOTICE 'OK 6 — documentos: hash-skip y protección de ediciones manuales';
END $$;

-- ── 9. Preguntas: validación, movimiento entre secciones y archivado ────
DO $$
DECLARE v_res jsonb; v_err text; v_sec_silencio uuid; v_sec_caducidad uuid;
BEGIN
    SELECT id INTO v_sec_silencio  FROM ids_v1 WHERE slug='silencio';
    SELECT id INTO v_sec_caducidad FROM ids_v1 WHERE slug='caducidad';

    v_res := admin_publicar_preguntas('ley-39-2015','terminacion','silencio', $j$[
      {"enunciado":"¿Plazo general del silencio?","opciones":[{"texto":"3 meses","correcta":true},{"texto":"6 meses","correcta":false}]},
      {"enunciado":"¿El silencio positivo requiere acto expreso?","opciones":[{"texto":"No","correcta":true},{"texto":"Sí","correcta":false}]}
    ]$j$::jsonb);
    IF (v_res->>'nuevas')::int <> 2 THEN RAISE EXCEPTION 'FALLO: no insertó 2 preguntas (%)', v_res; END IF;

    -- Formato inválido: debe reventar ANTES de llegar a producción.
    BEGIN
        PERFORM admin_publicar_preguntas('ley-39-2015','terminacion','caducidad', $j$[
          {"enunciado":"Sin correcta","opciones":[{"texto":"a","correcta":false},{"texto":"b","correcta":false}]}
        ]$j$::jsonb);
        RAISE EXCEPTION 'FALLO: aceptó una pregunta sin opción correcta';
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_err = MESSAGE_TEXT;
        IF v_err <> 'correctas_invalidas' THEN RAISE; END IF;
    END;

    -- Mover un enunciado a otra sección: se mueve y se reporta.
    v_res := admin_publicar_preguntas('ley-39-2015','terminacion','caducidad', $j$[
      {"enunciado":"¿Plazo general del silencio?","opciones":[{"texto":"3 meses","correcta":true},{"texto":"6 meses","correcta":false}]}
    ]$j$::jsonb);
    IF (v_res->>'movidas')::int <> 1 THEN RAISE EXCEPTION 'FALLO: no reportó el movimiento (%)', v_res; END IF;

    -- Archivar ausentes deja la pregunta fuera del sorteo pero en la tabla.
    v_res := admin_publicar_preguntas('ley-39-2015','terminacion','silencio', '[]'::jsonb, true);
    IF (v_res->>'archivadas')::int <> 1 THEN RAISE EXCEPTION 'FALLO: no archivó la ausente (%)', v_res; END IF;
    IF (SELECT count(*) FROM preguntas WHERE seccion_id = v_sec_silencio) <> 1 THEN
        RAISE EXCEPTION 'FALLO: archivar borró la fila';
    END IF;
    IF array_length(_sortear_preguntas(ARRAY[v_sec_silencio], 10), 1) IS NOT NULL THEN
        RAISE EXCEPTION 'FALLO: una pregunta archivada entró en el sorteo';
    END IF;
    RAISE NOTICE 'OK 7 — preguntas: validación, movimiento y archivado';
END $$;

-- ── 10. Estado de publicación (lo que usa el --dry-run) ─────────────────
DO $$
DECLARE v_est jsonb;
BEGIN
    v_est := admin_estado_publicacion('auxilio-judicial');
    IF NOT (v_est->>'existe')::boolean THEN RAISE EXCEPTION 'FALLO: no ve la oposición'; END IF;
    IF jsonb_array_length(v_est->'secciones') <> 3 THEN
        RAISE EXCEPTION 'FALLO: esperaba 3 secciones, vino %', jsonb_array_length(v_est->'secciones');
    END IF;
    IF NOT (v_est->'secciones')::text LIKE '%ley-39-2015/terminacion/silencio%' THEN
        RAISE EXCEPTION 'FALLO: la ruta de slugs no aparece en el estado';
    END IF;
    RAISE NOTICE 'OK 8 — admin_estado_publicacion da la foto para el diff';
END $$;

\echo '=== TODAS LAS PRUEBAS PASARON ==='
