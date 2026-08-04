-- =============================================================================
--  2026-08-04 — Identidad por slug y publicación desde el repo de contenido
-- =============================================================================
-- Idempotente: se puede ejecutar varias veces.
--
-- QUÉ CAMBIA Y POR QUÉ
--
-- El progreso de cada usuario cuelga de `secciones.id` con ON DELETE CASCADE,
-- pero hasta ahora ningún nivel salvo `temas` tenía identificador estable: las
-- oposiciones se identificaban por nombre y los módulos y secciones por
-- `UNIQUE (padre, orden)`. Con la posición como identidad, insertar una
-- sección en medio de un módulo desplazaba a las de abajo y reasignaba el
-- progreso de cada usuario a otro contenido, en silencio.
--
-- A partir de aquí el `slug` es la identidad y el `nombre` es una etiqueta que
-- se puede cambiar cuando se quiera.
--
-- SI TU BBDD NO TIENE CONTENIDO QUE CONSERVAR, es más limpio recrearla desde
-- `db/init/01_esquema.sql` que aplicar este delta. Para eso hay que pedir el
-- reset explícitamente (el fichero se niega a pisar un esquema existente):
--     SET aprentix.recrear = 'si';   -- primera línea, antes de pegarlo
-- Se negará igualmente si encuentra intentos registrados.
--
-- ANTES DE EJECUTAR: backup.
--   docker compose -f deploy/core/docker-compose.yml exec db \
--       pg_dump -Fc -U aprentix -d aprentix > db/backups/aprentix_$(date +%F).dump
-- =============================================================================

BEGIN;

-- ── 1. Identidad estable ────────────────────────────────────────────────────

ALTER TABLE oposiciones ADD COLUMN IF NOT EXISTS slug text;
ALTER TABLE modulos     ADD COLUMN IF NOT EXISTS slug text;
ALTER TABLE secciones   ADD COLUMN IF NOT EXISTS slug text;

-- Backfill desde el nombre, resolviendo colisiones dentro de cada padre.
-- OJO: estos slugs pasan a ser la identidad del contenido. Revísalos antes de
-- publicar — tienen que coincidir con los del bloque `aprentix:meta` del repo.
UPDATE oposiciones o SET slug = x.s
  FROM (SELECT id, _slugify(nombre) ||
               CASE WHEN row_number() OVER (PARTITION BY _slugify(nombre)
                                            ORDER BY creado_en, id) > 1
                    THEN '-' || substr(id::text, 1, 4) ELSE '' END AS s
          FROM oposiciones) x
 WHERE o.id = x.id AND o.slug IS NULL;

UPDATE modulos m SET slug = x.s
  FROM (SELECT id, _slugify(nombre) ||
               CASE WHEN row_number() OVER (PARTITION BY tema_id, _slugify(nombre)
                                            ORDER BY orden, id) > 1
                    THEN '-' || substr(id::text, 1, 4) ELSE '' END AS s
          FROM modulos) x
 WHERE m.id = x.id AND m.slug IS NULL;

UPDATE secciones s SET slug = x.s
  FROM (SELECT id, _slugify(nombre) ||
               CASE WHEN row_number() OVER (PARTITION BY modulo_id, _slugify(nombre)
                                            ORDER BY orden, id) > 1
                    THEN '-' || substr(id::text, 1, 4) ELSE '' END AS s
          FROM secciones) x
 WHERE s.id = x.id AND s.slug IS NULL;

ALTER TABLE oposiciones ALTER COLUMN slug SET NOT NULL;
ALTER TABLE modulos     ALTER COLUMN slug SET NOT NULL;
ALTER TABLE secciones   ALTER COLUMN slug SET NOT NULL;

DO $mig$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'oposiciones_slug_key') THEN
        ALTER TABLE oposiciones ADD CONSTRAINT oposiciones_slug_key UNIQUE (slug);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'modulos_tema_id_slug_key') THEN
        ALTER TABLE modulos ADD CONSTRAINT modulos_tema_id_slug_key UNIQUE (tema_id, slug);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'secciones_modulo_id_slug_key') THEN
        ALTER TABLE secciones ADD CONSTRAINT secciones_modulo_id_slug_key UNIQUE (modulo_id, slug);
    END IF;
END $mig$;

-- El orden deja de ser identidad. Además, con estos UNIQUE puestos, reordenar
-- dos secciones obligaba a pasar por un valor temporal para esquivar el índice.
ALTER TABLE modulos   DROP CONSTRAINT IF EXISTS modulos_tema_id_orden_key;
ALTER TABLE secciones DROP CONSTRAINT IF EXISTS secciones_modulo_id_orden_key;


-- ── 2. Archivado en vez de borrado ──────────────────────────────────────────

ALTER TABLE temas     ADD COLUMN IF NOT EXISTS archivado boolean NOT NULL DEFAULT false;
ALTER TABLE modulos   ADD COLUMN IF NOT EXISTS archivado boolean NOT NULL DEFAULT false;
ALTER TABLE secciones ADD COLUMN IF NOT EXISTS archivada boolean NOT NULL DEFAULT false;
ALTER TABLE preguntas ADD COLUMN IF NOT EXISTS archivada boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS preguntas_vivas_idx ON preguntas (seccion_id) WHERE NOT archivada;


-- ── 3. El markdown pasa a vivir en la BD ────────────────────────────────────

ALTER TABLE documentos ADD COLUMN IF NOT EXISTS contenido  text;
ALTER TABLE documentos ADD COLUMN IF NOT EXISTS commit_sha text;
ALTER TABLE documentos ADD COLUMN IF NOT EXISTS origen     text NOT NULL DEFAULT 'publicacion';

DO $mig$
DECLARE v_huerfanos int;
BEGIN
    -- Las filas antiguas eran punteros a ficheros de /mnt/data/ficheros: no
    -- traen el texto. No las borramos —eso es decisión de una persona— sino
    -- que las dejamos con un aviso visible y `origen='publicacion'`, para que
    -- la primera publicación las sobrescriba sin pedir --forzar.
    SELECT count(*) INTO v_huerfanos FROM documentos WHERE contenido IS NULL;
    IF v_huerfanos > 0 THEN
        UPDATE documentos
           SET contenido = '## Pendiente de publicar' || chr(10) || chr(10) ||
                           'Este documento apuntaba al fichero `' || COALESCE(ruta, '?') ||
                           '`. Publícalo desde el repo de contenido con ' ||
                           '`db/publicacion/publicar.py`.',
               origen = 'publicacion'
         WHERE contenido IS NULL;
        RAISE NOTICE '% documentos apuntaban a ficheros y no traen texto: se han '
                     'marcado como pendientes. Publica el repo para rellenarlos.', v_huerfanos;
    END IF;
END $mig$;

ALTER TABLE documentos ALTER COLUMN contenido SET NOT NULL;
ALTER TABLE documentos ALTER COLUMN ruta DROP NOT NULL;

DO $mig$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'documentos_origen_check') THEN
        ALTER TABLE documentos ADD CONSTRAINT documentos_origen_check
            CHECK (origen IN ('publicacion','manual'));
    END IF;
END $mig$;

-- `hash_contenido` pasa a derivarse del texto: así no puede quedar
-- desincronizado de lo que describe.
DO $mig$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_name = 'documentos' AND column_name = 'hash_contenido'
                  AND is_generated = 'NEVER') THEN
        ALTER TABLE documentos DROP COLUMN hash_contenido;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_name = 'documentos' AND column_name = 'hash_contenido') THEN
        ALTER TABLE documentos
            ADD COLUMN hash_contenido text GENERATED ALWAYS AS (md5(contenido)) STORED;
    END IF;
END $mig$;


-- ── 4. Funciones ────────────────────────────────────────────────────────────
-- Extraídas de db/init/01_esquema.sql, que es la fuente de verdad.

CREATE OR REPLACE FUNCTION _sortear_preguntas(
    p_seccion_ids uuid[],
    p_n           int
) RETURNS uuid[]
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(array_agg(id ORDER BY random()), ARRAY[]::uuid[])
      FROM (
        SELECT id FROM preguntas
         WHERE seccion_id = ANY(p_seccion_ids)
           AND NOT archivada
         ORDER BY random()
         LIMIT p_n
      ) x;
$$;

CREATE OR REPLACE FUNCTION iniciar_intento_seccion(p_seccion_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_n   int;
    v_ids uuid[];
    v_int uuid;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    SELECT n_preg_test INTO v_n
      FROM secciones WHERE id = p_seccion_id AND NOT archivada;
    IF v_n IS NULL THEN RAISE EXCEPTION 'seccion_no_encontrada'; END IF;
    v_ids := _sortear_preguntas(ARRAY[p_seccion_id], v_n);
    IF array_length(v_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'sin_preguntas';
    END IF;
    INSERT INTO intentos (usuario_id, origen, seccion_id, question_ids)
    VALUES (v_uid, 'seccion', p_seccion_id, v_ids)
    RETURNING id INTO v_int;
    RETURN jsonb_build_object('intento_id', v_int, 'question_ids', to_jsonb(v_ids));
END $$;

CREATE OR REPLACE FUNCTION iniciar_intento_modulo(p_modulo_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_secc uuid[];
    v_n   int;
    v_ids uuid[];
    v_int uuid;
    v_tema uuid;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    SELECT array_agg(id), COUNT(*) INTO v_secc, v_n
      FROM secciones WHERE modulo_id = p_modulo_id AND NOT archivada;
    IF v_secc IS NULL THEN RAISE EXCEPTION 'modulo_sin_secciones'; END IF;
    SELECT tema_id INTO v_tema FROM modulos WHERE id = p_modulo_id;
    v_n := preguntas_por_nodo('modulo', v_n);
    v_ids := _sortear_preguntas(v_secc, v_n);
    IF array_length(v_ids, 1) IS NULL THEN RAISE EXCEPTION 'sin_preguntas'; END IF;
    INSERT INTO intentos (usuario_id, origen, modulo_id, tema_id, question_ids)
    VALUES (v_uid, 'modulo', p_modulo_id, v_tema, v_ids)
    RETURNING id INTO v_int;
    RETURN jsonb_build_object('intento_id', v_int, 'question_ids', to_jsonb(v_ids));
END $$;

CREATE OR REPLACE FUNCTION iniciar_intento_tema(p_tema_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_secc uuid[];
    v_n   int;
    v_ids uuid[];
    v_int uuid;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    SELECT array_agg(s.id), COUNT(*) INTO v_secc, v_n
      FROM secciones s
      JOIN modulos   m ON m.id = s.modulo_id
     WHERE m.tema_id = p_tema_id
       AND NOT s.archivada AND NOT m.archivado;
    IF v_secc IS NULL THEN RAISE EXCEPTION 'tema_sin_secciones'; END IF;
    v_n := preguntas_por_nodo('tema', v_n);
    v_ids := _sortear_preguntas(v_secc, v_n);
    IF array_length(v_ids, 1) IS NULL THEN RAISE EXCEPTION 'sin_preguntas'; END IF;
    INSERT INTO intentos (usuario_id, origen, tema_id, question_ids)
    VALUES (v_uid, 'tema', p_tema_id, v_ids)
    RETURNING id INTO v_int;
    RETURN jsonb_build_object('intento_id', v_int, 'question_ids', to_jsonb(v_ids));
END $$;

CREATE OR REPLACE FUNCTION mi_home_oposicion(p_oposicion_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_res jsonb;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;

    -- Todo este árbol ignora lo archivado: una sección retirada desaparece
    -- del home aunque el usuario tenga progreso en ella (el progreso sigue
    -- en la tabla, sólo deja de pintarse y de contar para los porcentajes).
    WITH secc_pct AS (
        -- Por sección: completada (0/1) — luego agregamos a módulo y tema.
        SELECT s.id AS seccion_id, s.modulo_id, m.tema_id,
               (ps.completada_en IS NOT NULL)::int AS completada,
               ps.nota_max,
               ps.teoria_vista_en
          FROM secciones s
          JOIN modulos m ON m.id = s.modulo_id
          LEFT JOIN progreso_seccion ps
                 ON ps.usuario_id = v_uid AND ps.seccion_id = s.id
         WHERE NOT s.archivada AND NOT m.archivado
    ),
    -- Nº de preguntas vivas por sección — se reutiliza a nivel de sección,
    -- módulo y tema, así que lo calculamos una sola vez.
    preg_por_secc AS (
        SELECT p.seccion_id, COUNT(*)::int AS n
          FROM preguntas p
         WHERE NOT p.archivada
         GROUP BY p.seccion_id
    )
    SELECT jsonb_build_object(
        'oposicion',
        (SELECT jsonb_build_object('id', o.id, 'nombre', o.nombre, 'descripcion', o.descripcion)
           FROM oposiciones o WHERE o.id = p_oposicion_id),
        'temas',
        COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id',           t.id,
                'nombre',       t.nombre,
                'slug',         t.slug,
                'orden',        ot.orden,
                -- % completado del tema = secciones completadas / totales.
                'pct',          CASE
                    WHEN (SELECT COUNT(*) FROM secc_pct WHERE tema_id = t.id) = 0
                        THEN 0
                    ELSE round(100.0 * (SELECT COALESCE(SUM(completada),0) FROM secc_pct WHERE tema_id = t.id)
                                     / (SELECT COUNT(*)                 FROM secc_pct WHERE tema_id = t.id), 0)
                END,
                -- Nº total de preguntas del tema (todas sus secciones).
                'preguntas_total',
                    COALESCE((
                        SELECT SUM(pps.n)::int
                          FROM secciones s
                          JOIN modulos m ON m.id = s.modulo_id
                          LEFT JOIN preg_por_secc pps ON pps.seccion_id = s.id
                         WHERE m.tema_id = t.id
                           AND NOT s.archivada AND NOT m.archivado
                    ), 0),
                'modulos',
                COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                        'id',              m.id,
                        'nombre',          m.nombre,
                        'orden',           m.orden,
                        'es_unico',        m.es_unico,
                        'secciones_ok',    (SELECT COALESCE(SUM(completada),0)
                                              FROM secc_pct WHERE modulo_id = m.id),
                        'secciones_total', (SELECT COUNT(*)
                                              FROM secc_pct WHERE modulo_id = m.id),
                        -- Nº de preguntas del módulo (todas sus secciones).
                        'preguntas_total',
                            COALESCE((
                                SELECT SUM(pps.n)::int
                                  FROM secciones s
                                  LEFT JOIN preg_por_secc pps ON pps.seccion_id = s.id
                                 WHERE s.modulo_id = m.id AND NOT s.archivada
                            ), 0),
                        'secciones',
                        COALESCE((
                            SELECT jsonb_agg(jsonb_build_object(
                                'id',              s.id,
                                'nombre',          s.nombre,
                                'orden',           s.orden,
                                'nota_max',        sp.nota_max,
                                'completada',      sp.completada = 1,
                                'teoria_vista_en', sp.teoria_vista_en,
                                'preguntas_total', COALESCE(
                                    (SELECT n FROM preg_por_secc WHERE seccion_id = s.id), 0)
                            ) ORDER BY s.orden)
                              FROM secciones s
                              LEFT JOIN secc_pct sp ON sp.seccion_id = s.id
                             WHERE s.modulo_id = m.id AND NOT s.archivada
                        ), '[]'::jsonb)
                    ) ORDER BY m.orden)
                      FROM modulos m
                     WHERE m.tema_id = t.id AND NOT m.archivado
                ), '[]'::jsonb)
            ) ORDER BY ot.orden)
              FROM temas t
              JOIN oposicion_temas ot ON ot.tema_id = t.id
             WHERE ot.oposicion_id = p_oposicion_id
               AND NOT t.archivado
        ), '[]'::jsonb)
    ) INTO v_res;

    RETURN v_res;
END $$;

CREATE OR REPLACE FUNCTION sugerir_solapamiento(p_oposicion_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_total int; v_hechas int;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    SELECT COUNT(*) INTO v_total
      FROM secciones s
      JOIN modulos m ON m.id = s.modulo_id
      JOIN temas   t ON t.id = m.tema_id
      JOIN oposicion_temas ot ON ot.tema_id = m.tema_id
     WHERE ot.oposicion_id = p_oposicion_id
       AND NOT s.archivada AND NOT m.archivado AND NOT t.archivado;
    SELECT COUNT(*) INTO v_hechas
      FROM secciones s
      JOIN modulos m ON m.id = s.modulo_id
      JOIN temas   t ON t.id = m.tema_id
      JOIN oposicion_temas ot ON ot.tema_id = m.tema_id
      JOIN progreso_seccion ps ON ps.seccion_id = s.id AND ps.usuario_id = v_uid
     WHERE ot.oposicion_id = p_oposicion_id
       AND ps.completada_en IS NOT NULL
       AND NOT s.archivada AND NOT m.archivado AND NOT t.archivado;
    RETURN jsonb_build_object(
        'oposicion_id', p_oposicion_id,
        'total',        v_total,
        'hechas',       v_hechas,
        'pct',          CASE WHEN v_total = 0 THEN 0
                             ELSE round(100.0 * v_hechas / v_total, 0)
                        END
    );
END $$;

CREATE OR REPLACE FUNCTION preguntas_repaso_oposicion(
    p_oposicion_id uuid,
    p_n            int DEFAULT 40
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_res jsonb;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;

    WITH pool AS (
        SELECT p.id AS pregunta_id
          FROM preguntas p
          JOIN secciones s   ON s.id = p.seccion_id
          JOIN modulos   m   ON m.id = s.modulo_id
          JOIN temas     t   ON t.id = m.tema_id
          JOIN oposicion_temas ot ON ot.tema_id = m.tema_id
          JOIN progreso_seccion ps
                ON ps.usuario_id = v_uid AND ps.seccion_id = s.id
         WHERE ot.oposicion_id = p_oposicion_id
           AND ps.completada_en IS NOT NULL
           AND NOT p.archivada
           AND NOT s.archivada AND NOT m.archivado AND NOT t.archivado
    ),
    scored AS (
        SELECT p.pregunta_id,
               COALESCE(mf.contador, 0)                                            AS fallos,
               COALESCE(r.caja, 1)                                                 AS caja,
               COALESCE(EXTRACT(day FROM (now() - r.ultima_en))::int, 999)         AS dias_desde
          FROM pool p
          LEFT JOIN marcadores mf
                 ON mf.usuario_id = v_uid AND mf.tipo = 'fallo' AND mf.pregunta_id = p.pregunta_id
          LEFT JOIN repasos r
                 ON r.usuario_id = v_uid AND r.pregunta_id = p.pregunta_id
    )
    SELECT COALESCE(jsonb_agg(pregunta_id ORDER BY score DESC, random()) , '[]'::jsonb) INTO v_res
      FROM (
        SELECT pregunta_id,
               100 * fallos
             + 20  * (8 - caja)
             +  5  * dias_desde
             - 10  * (CASE WHEN caja = 7 THEN 1 ELSE 0 END) AS score
          FROM scored
         ORDER BY score DESC, random()
         LIMIT p_n
      ) x;

    RETURN v_res;
END $$;

CREATE OR REPLACE FUNCTION documento_de_seccion(p_seccion_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT jsonb_build_object(
        'id',        d.id,
        'tipo',      d.tipo,
        'contenido', d.contenido,
        'ruta',      d.ruta,
        'commit_sha', d.commit_sha,
        'actualizado_en', d.actualizado_en
    )
      FROM documentos d
     WHERE d.seccion_id = p_seccion_id AND d.tipo = 'teoria'
     LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION documento_de_modulo(p_modulo_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT jsonb_build_object(
        'id',        d.id,
        'tipo',      d.tipo,
        'contenido', d.contenido,
        'ruta',      d.ruta,
        'commit_sha', d.commit_sha,
        'actualizado_en', d.actualizado_en
    )
      FROM documentos d
     WHERE d.modulo_id = p_modulo_id AND d.tipo = 'esquema'
     LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION documento_de_tema(p_tema_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT jsonb_build_object(
        'id',        d.id,
        'tipo',      d.tipo,
        'contenido', d.contenido,
        'ruta',      d.ruta,
        'commit_sha', d.commit_sha,
        'actualizado_en', d.actualizado_en
    )
      FROM documentos d
     WHERE d.tema_id = p_tema_id AND d.tipo = 'esquema'
     LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION admin_listar_oposiciones() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('oposicion.gestionar');
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id',          o.id,
            'nombre',      o.nombre,
            'slug',        o.slug,
            'descripcion', o.descripcion,
            'activa',      o.activa,
            'creado_en',   o.creado_en,
            'n_temas',     (SELECT count(*) FROM oposicion_temas ot WHERE ot.oposicion_id = o.id),
            'n_alumnos',   (SELECT count(*) FROM usuario_oposiciones uo WHERE uo.oposicion_id = o.id)
        ) ORDER BY o.nombre)
        FROM oposiciones o
    ), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION admin_crear_oposicion(
    p_nombre       text,
    p_descripcion  text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid; v_slug text;
BEGIN
    PERFORM _admin_o_permiso('oposicion.gestionar');
    IF p_nombre IS NULL OR btrim(p_nombre) = '' THEN
        RAISE EXCEPTION 'nombre_invalido';
    END IF;
    -- El slug se propone desde el nombre sólo AQUÍ, al crear. A partir de
    -- este momento es la identidad de la oposición y no se recalcula nunca
    -- (`admin_actualizar_oposicion` no lo toca).
    v_slug := _slugify(p_nombre);
    WHILE EXISTS (SELECT 1 FROM oposiciones WHERE slug = v_slug) LOOP
        v_slug := v_slug || '-' || substr(gen_random_uuid()::text, 1, 4);
    END LOOP;
    INSERT INTO oposiciones (nombre, slug, descripcion)
    VALUES (btrim(p_nombre), v_slug, NULLIF(btrim(COALESCE(p_descripcion,'')), ''))
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('ok', true, 'id', v_id, 'slug', v_slug);
END $$;

CREATE OR REPLACE FUNCTION admin_listar_temas(p_oposicion_id uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('contenido.editar');
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id',            t.id,
            'nombre',        t.nombre,
            'slug',          t.slug,
            'descripcion',   t.descripcion,
            'archivado',     t.archivado,
            'n_modulos',     (SELECT count(*) FROM modulos m WHERE m.tema_id = t.id),
            'n_secciones',   (SELECT count(*) FROM secciones s
                               JOIN modulos m ON m.id = s.modulo_id
                              WHERE m.tema_id = t.id),
            'n_preguntas',   (SELECT count(*) FROM preguntas p
                               JOIN secciones s ON s.id = p.seccion_id
                               JOIN modulos m ON m.id = s.modulo_id
                              WHERE m.tema_id = t.id),
            'orden',         ot.orden,
            'oposicion_ids', COALESCE(
                (SELECT jsonb_agg(oposicion_id) FROM oposicion_temas WHERE tema_id = t.id),
                '[]'::jsonb
            )
        ) ORDER BY COALESCE(ot.orden, 999), t.nombre)
        FROM temas t
        LEFT JOIN oposicion_temas ot
               ON ot.tema_id = t.id AND ot.oposicion_id = p_oposicion_id
        WHERE p_oposicion_id IS NULL OR ot.oposicion_id IS NOT NULL
    ), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION admin_crear_tema(
    p_nombre        text,
    p_descripcion   text DEFAULT NULL,
    p_oposicion_id  uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_id   uuid;
    v_slug text;
    v_ord  int;
BEGIN
    PERFORM _admin_o_permiso('contenido.crear');
    IF p_nombre IS NULL OR btrim(p_nombre) = '' THEN
        RAISE EXCEPTION 'nombre_invalido';
    END IF;
    v_slug := _slugify(p_nombre);
    WHILE EXISTS (SELECT 1 FROM temas WHERE slug = v_slug) LOOP
        v_slug := v_slug || '-' || substr(gen_random_uuid()::text, 1, 4);
    END LOOP;
    INSERT INTO temas (nombre, slug, descripcion)
    VALUES (btrim(p_nombre), v_slug, NULLIF(btrim(COALESCE(p_descripcion,'')), ''))
    RETURNING id INTO v_id;

    IF p_oposicion_id IS NOT NULL THEN
        SELECT COALESCE(max(orden), 0) + 1 INTO v_ord
          FROM oposicion_temas WHERE oposicion_id = p_oposicion_id;
        INSERT INTO oposicion_temas (oposicion_id, tema_id, orden)
        VALUES (p_oposicion_id, v_id, v_ord)
        ON CONFLICT DO NOTHING;
    END IF;

    INSERT INTO modulos (tema_id, nombre, slug, orden, es_unico)
    VALUES (v_id, btrim(p_nombre), 'general', 1, true);

    RETURN jsonb_build_object('ok', true, 'id', v_id, 'slug', v_slug);
END $$;

CREATE OR REPLACE FUNCTION _progreso_en_secciones(p_seccion_ids uuid[]) RETURNS int
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
    SELECT COUNT(*)::int FROM progreso_seccion
     WHERE seccion_id = ANY(p_seccion_ids);
$$;

CREATE OR REPLACE FUNCTION admin_borrar_tema(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_progreso int;
BEGIN
    PERFORM _admin_o_permiso('contenido.borrar');
    SELECT _progreso_en_secciones(array_agg(s.id)) INTO v_progreso
      FROM secciones s JOIN modulos m ON m.id = s.modulo_id
     WHERE m.tema_id = p_id;
    IF COALESCE(v_progreso, 0) > 0 THEN
        RAISE EXCEPTION 'tiene_progreso'
            USING DETAIL = format('%s filas de progreso se perderían; archiva el tema en vez de borrarlo', v_progreso);
    END IF;
    DELETE FROM temas WHERE id = p_id;
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION admin_archivar_tema(p_id uuid, p_archivado boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('contenido.editar');
    UPDATE temas SET archivado = p_archivado WHERE id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'tema_no_encontrado'; END IF;
    RETURN jsonb_build_object('ok', true, 'archivado', p_archivado);
END $$;

CREATE OR REPLACE FUNCTION admin_listar_modulos(p_tema_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('contenido.editar');
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id',           m.id,
            'nombre',       m.nombre,
            'slug',         m.slug,
            'orden',        m.orden,
            'es_unico',     m.es_unico,
            'archivado',    m.archivado,
            'n_secciones',  (SELECT count(*) FROM secciones s WHERE s.modulo_id = m.id),
            'n_preguntas',  (SELECT count(*) FROM preguntas p
                              JOIN secciones s ON s.id = p.seccion_id
                             WHERE s.modulo_id = m.id)
        ) ORDER BY m.orden)
        FROM modulos m
        WHERE m.tema_id = p_tema_id
    ), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION admin_crear_modulo(
    p_tema_id uuid,
    p_nombre  text,
    p_orden   int DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid; v_ord int; v_slug text;
BEGIN
    PERFORM _admin_o_permiso('contenido.crear');
    IF p_nombre IS NULL OR btrim(p_nombre) = '' THEN
        RAISE EXCEPTION 'nombre_invalido';
    END IF;
    SELECT COALESCE(p_orden,
                    (SELECT COALESCE(max(orden), 0) + 1 FROM modulos WHERE tema_id = p_tema_id))
      INTO v_ord;
    -- Slug propuesto desde el nombre, único dentro del tema. Identidad a
    -- partir de aquí: `admin_actualizar_modulo` no lo recalcula.
    v_slug := _slugify(p_nombre);
    WHILE EXISTS (SELECT 1 FROM modulos WHERE tema_id = p_tema_id AND slug = v_slug) LOOP
        v_slug := v_slug || '-' || substr(gen_random_uuid()::text, 1, 4);
    END LOOP;
    INSERT INTO modulos (tema_id, nombre, slug, orden, es_unico)
    VALUES (p_tema_id, btrim(p_nombre), v_slug, v_ord, false)
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('ok', true, 'id', v_id, 'slug', v_slug, 'orden', v_ord);
END $$;

CREATE OR REPLACE FUNCTION admin_borrar_modulo(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_progreso int;
BEGIN
    PERFORM _admin_o_permiso('contenido.borrar');
    SELECT _progreso_en_secciones(array_agg(s.id)) INTO v_progreso
      FROM secciones s WHERE s.modulo_id = p_id;
    IF COALESCE(v_progreso, 0) > 0 THEN
        RAISE EXCEPTION 'tiene_progreso'
            USING DETAIL = format('%s filas de progreso se perderían; archiva el módulo en vez de borrarlo', v_progreso);
    END IF;
    DELETE FROM modulos WHERE id = p_id;
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION admin_archivar_modulo(p_id uuid, p_archivado boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('contenido.editar');
    UPDATE modulos SET archivado = p_archivado WHERE id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'modulo_no_encontrado'; END IF;
    RETURN jsonb_build_object('ok', true, 'archivado', p_archivado);
END $$;

CREATE OR REPLACE FUNCTION admin_listar_secciones(p_modulo_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('contenido.editar');
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id',            s.id,
            'nombre',        s.nombre,
            'slug',          s.slug,
            'orden',         s.orden,
            'min_aprobado',  s.min_aprobado,
            'n_preg_test',   s.n_preg_test,
            'archivada',     s.archivada,
            'n_preguntas',   (SELECT count(*) FROM preguntas p
                               WHERE p.seccion_id = s.id AND NOT p.archivada),
            'tiene_teoria',  EXISTS (SELECT 1 FROM documentos d
                                      WHERE d.seccion_id = s.id AND d.tipo = 'teoria')
        ) ORDER BY s.orden)
        FROM secciones s
        WHERE s.modulo_id = p_modulo_id
    ), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION admin_crear_seccion(
    p_modulo_id    uuid,
    p_nombre       text,
    p_orden        int     DEFAULT NULL,
    p_min_aprobado numeric DEFAULT 70,
    p_n_preg_test  int     DEFAULT 10
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid; v_ord int; v_slug text;
BEGIN
    PERFORM _admin_o_permiso('contenido.crear');
    IF p_nombre IS NULL OR btrim(p_nombre) = '' THEN
        RAISE EXCEPTION 'nombre_invalido';
    END IF;
    SELECT COALESCE(p_orden,
                    (SELECT COALESCE(max(orden), 0) + 1 FROM secciones WHERE modulo_id = p_modulo_id))
      INTO v_ord;
    -- Slug propuesto desde el nombre, único dentro del módulo. Es la
    -- identidad de la que colgará el progreso de todos los usuarios: a
    -- partir de aquí no se recalcula nunca.
    v_slug := _slugify(p_nombre);
    WHILE EXISTS (SELECT 1 FROM secciones WHERE modulo_id = p_modulo_id AND slug = v_slug) LOOP
        v_slug := v_slug || '-' || substr(gen_random_uuid()::text, 1, 4);
    END LOOP;
    INSERT INTO secciones (modulo_id, nombre, slug, orden, min_aprobado, n_preg_test)
    VALUES (p_modulo_id, btrim(p_nombre), v_slug, v_ord,
            COALESCE(p_min_aprobado, 70),
            COALESCE(p_n_preg_test, 10))
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('ok', true, 'id', v_id, 'slug', v_slug, 'orden', v_ord);
END $$;

CREATE OR REPLACE FUNCTION admin_borrar_seccion(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_progreso int;
BEGIN
    PERFORM _admin_o_permiso('contenido.borrar');
    v_progreso := _progreso_en_secciones(ARRAY[p_id]);
    IF v_progreso > 0 THEN
        RAISE EXCEPTION 'tiene_progreso'
            USING DETAIL = format('%s usuarios tienen progreso aquí; archiva la sección en vez de borrarla', v_progreso);
    END IF;
    DELETE FROM secciones WHERE id = p_id;
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION admin_archivar_seccion(p_id uuid, p_archivada boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('contenido.editar');
    UPDATE secciones SET archivada = p_archivada WHERE id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'seccion_no_encontrada'; END IF;
    RETURN jsonb_build_object('ok', true, 'archivada', p_archivada);
END $$;

CREATE OR REPLACE FUNCTION admin_upsert_documento(
    p_nivel      text,
    p_entidad_id uuid,
    p_tipo       text,
    p_contenido  text,
    p_ruta       text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
    PERFORM _admin_o_permiso('teoria.gestionar');
    IF p_contenido IS NULL OR btrim(p_contenido) = '' THEN
        RAISE EXCEPTION 'contenido_vacio';
    END IF;
    IF p_nivel = 'seccion' THEN
        INSERT INTO documentos (nivel, seccion_id, tipo, contenido, ruta, origen)
        VALUES ('seccion', p_entidad_id, p_tipo, p_contenido, p_ruta, 'manual')
        ON CONFLICT (seccion_id, tipo) WHERE seccion_id IS NOT NULL DO UPDATE
            SET contenido = EXCLUDED.contenido, ruta = EXCLUDED.ruta,
                origen = 'manual', commit_sha = NULL, actualizado_en = now()
        RETURNING id INTO v_id;
    ELSIF p_nivel = 'modulo' THEN
        INSERT INTO documentos (nivel, modulo_id, tipo, contenido, ruta, origen)
        VALUES ('modulo', p_entidad_id, p_tipo, p_contenido, p_ruta, 'manual')
        ON CONFLICT (modulo_id, tipo) WHERE modulo_id IS NOT NULL DO UPDATE
            SET contenido = EXCLUDED.contenido, ruta = EXCLUDED.ruta,
                origen = 'manual', commit_sha = NULL, actualizado_en = now()
        RETURNING id INTO v_id;
    ELSIF p_nivel = 'tema' THEN
        INSERT INTO documentos (nivel, tema_id, tipo, contenido, ruta, origen)
        VALUES ('tema', p_entidad_id, p_tipo, p_contenido, p_ruta, 'manual')
        ON CONFLICT (tema_id, tipo) WHERE tema_id IS NOT NULL DO UPDATE
            SET contenido = EXCLUDED.contenido, ruta = EXCLUDED.ruta,
                origen = 'manual', commit_sha = NULL, actualizado_en = now()
        RETURNING id INTO v_id;
    ELSE
        RAISE EXCEPTION 'nivel_invalido';
    END IF;
    RETURN jsonb_build_object('ok', true, 'id', v_id);
END $$;

CREATE OR REPLACE FUNCTION _seccion_por_slug(
    p_tema_slug    text,
    p_modulo_slug  text,
    p_seccion_slug text
) RETURNS uuid
LANGUAGE sql STABLE SET search_path = public, pg_temp AS $$
    SELECT s.id
      FROM secciones s
      JOIN modulos m ON m.id = s.modulo_id
      JOIN temas   t ON t.id = m.tema_id
     WHERE t.slug = p_tema_slug
       AND m.slug = p_modulo_slug
       AND s.slug = p_seccion_slug;
$$;

CREATE OR REPLACE FUNCTION admin_publicar_estructura(
    p_arbol              jsonb,
    p_archivar_ausentes  boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_op_slug   text := p_arbol #>> '{oposicion,slug}';
    v_op_id     uuid;
    v_tema      jsonb;
    v_modulo    jsonb;
    v_seccion   jsonb;
    v_tema_id   uuid;
    v_mod_id    uuid;
    v_sec_id    uuid;
    v_temas_vivos   uuid[] := '{}';
    v_mods_vivos    uuid[] := '{}';
    v_secs_vivas    uuid[] := '{}';
    v_creados   int := 0;
    v_actualiz  int := 0;
    v_archivados int := 0;
    v_nuevo     boolean;
BEGIN
    PERFORM _admin_o_permiso('contenido.editar');

    IF v_op_slug IS NULL OR btrim(v_op_slug) = '' THEN
        RAISE EXCEPTION 'oposicion_sin_slug'
            USING DETAIL = 'el arbol debe traer oposicion.slug';
    END IF;

    -- ── Oposición ───────────────────────────────────────────────────────
    SELECT id INTO v_op_id FROM oposiciones WHERE slug = v_op_slug;
    IF v_op_id IS NULL THEN
        INSERT INTO oposiciones (slug, nombre, descripcion)
        VALUES (v_op_slug,
                COALESCE(p_arbol #>> '{oposicion,nombre}', v_op_slug),
                p_arbol #>> '{oposicion,descripcion}')
        RETURNING id INTO v_op_id;
        v_creados := v_creados + 1;
    ELSE
        UPDATE oposiciones
           SET nombre      = COALESCE(p_arbol #>> '{oposicion,nombre}', nombre),
               descripcion = COALESCE(p_arbol #>> '{oposicion,descripcion}', descripcion)
         WHERE id = v_op_id;
        v_actualiz := v_actualiz + 1;
    END IF;

    -- ── Temas ───────────────────────────────────────────────────────────
    FOR v_tema IN SELECT * FROM jsonb_array_elements(COALESCE(p_arbol->'temas', '[]'::jsonb)) LOOP
        SELECT id INTO v_tema_id FROM temas WHERE slug = v_tema->>'slug';
        v_nuevo := v_tema_id IS NULL;
        IF v_nuevo THEN
            INSERT INTO temas (slug, nombre, descripcion)
            VALUES (v_tema->>'slug',
                    COALESCE(v_tema->>'nombre', v_tema->>'slug'),
                    v_tema->>'descripcion')
            RETURNING id INTO v_tema_id;
            v_creados := v_creados + 1;
        ELSE
            -- Renombrar es sólo esto: un UPDATE sobre la fila de siempre.
            UPDATE temas
               SET nombre      = COALESCE(v_tema->>'nombre', nombre),
                   descripcion = COALESCE(v_tema->>'descripcion', descripcion),
                   archivado   = false   -- reaparecer en el repo lo desarchiva
             WHERE id = v_tema_id;
            v_actualiz := v_actualiz + 1;
        END IF;
        v_temas_vivos := v_temas_vivos || v_tema_id;

        INSERT INTO oposicion_temas (oposicion_id, tema_id, orden)
        VALUES (v_op_id, v_tema_id, COALESCE((v_tema->>'orden')::int, 0))
        ON CONFLICT (oposicion_id, tema_id) DO UPDATE
            SET orden = EXCLUDED.orden;

        -- ── Módulos ─────────────────────────────────────────────────────
        FOR v_modulo IN SELECT * FROM jsonb_array_elements(COALESCE(v_tema->'modulos', '[]'::jsonb)) LOOP
            SELECT id INTO v_mod_id
              FROM modulos WHERE tema_id = v_tema_id AND slug = v_modulo->>'slug';
            IF v_mod_id IS NULL THEN
                INSERT INTO modulos (tema_id, slug, nombre, orden, es_unico)
                VALUES (v_tema_id, v_modulo->>'slug',
                        COALESCE(v_modulo->>'nombre', v_modulo->>'slug'),
                        COALESCE((v_modulo->>'orden')::int, 0),
                        COALESCE((v_modulo->>'es_unico')::boolean, false))
                RETURNING id INTO v_mod_id;
                v_creados := v_creados + 1;
            ELSE
                UPDATE modulos
                   SET nombre    = COALESCE(v_modulo->>'nombre', nombre),
                       orden     = COALESCE((v_modulo->>'orden')::int, orden),
                       es_unico  = COALESCE((v_modulo->>'es_unico')::boolean, es_unico),
                       archivado = false
                 WHERE id = v_mod_id;
                v_actualiz := v_actualiz + 1;
            END IF;
            v_mods_vivos := v_mods_vivos || v_mod_id;

            -- ── Secciones ───────────────────────────────────────────────
            FOR v_seccion IN SELECT * FROM jsonb_array_elements(COALESCE(v_modulo->'secciones', '[]'::jsonb)) LOOP
                SELECT id INTO v_sec_id
                  FROM secciones WHERE modulo_id = v_mod_id AND slug = v_seccion->>'slug';
                IF v_sec_id IS NULL THEN
                    INSERT INTO secciones (modulo_id, slug, nombre, orden, min_aprobado, n_preg_test)
                    VALUES (v_mod_id, v_seccion->>'slug',
                            COALESCE(v_seccion->>'nombre', v_seccion->>'slug'),
                            COALESCE((v_seccion->>'orden')::int, 0),
                            COALESCE((v_seccion->>'min_aprobado')::numeric, 70),
                            COALESCE((v_seccion->>'n_preg_test')::int, 10))
                    RETURNING id INTO v_sec_id;
                    v_creados := v_creados + 1;
                ELSE
                    -- Aquí es donde se protege el progreso: el uuid de la
                    -- sección no cambia por mucho que cambie el nombre.
                    UPDATE secciones
                       SET nombre       = COALESCE(v_seccion->>'nombre', nombre),
                           orden        = COALESCE((v_seccion->>'orden')::int, orden),
                           min_aprobado = COALESCE((v_seccion->>'min_aprobado')::numeric, min_aprobado),
                           n_preg_test  = COALESCE((v_seccion->>'n_preg_test')::int, n_preg_test),
                           archivada    = false
                     WHERE id = v_sec_id;
                    v_actualiz := v_actualiz + 1;
                END IF;
                v_secs_vivas := v_secs_vivas || v_sec_id;
            END LOOP;
        END LOOP;
    END LOOP;

    -- ── Archivado de lo ausente (nunca borrado) ─────────────────────────
    IF p_archivar_ausentes THEN
        WITH del_arbol AS (
            SELECT s.id AS seccion_id, m.id AS modulo_id, t.id AS tema_id
              FROM temas t
              JOIN oposicion_temas ot ON ot.tema_id = t.id AND ot.oposicion_id = v_op_id
              JOIN modulos m   ON m.tema_id = t.id
              JOIN secciones s ON s.modulo_id = m.id
        ), arch_s AS (
            UPDATE secciones s SET archivada = true
             WHERE s.id IN (SELECT seccion_id FROM del_arbol)
               AND NOT s.id = ANY(v_secs_vivas)
               AND NOT s.archivada
            RETURNING 1
        ), arch_m AS (
            UPDATE modulos m SET archivado = true
             WHERE m.id IN (SELECT modulo_id FROM del_arbol)
               AND NOT m.id = ANY(v_mods_vivos)
               AND NOT m.archivado
            RETURNING 1
        ), arch_t AS (
            UPDATE temas t SET archivado = true
             WHERE t.id IN (SELECT tema_id FROM del_arbol)
               AND NOT t.id = ANY(v_temas_vivos)
               AND NOT t.archivado
            RETURNING 1
        )
        SELECT (SELECT count(*) FROM arch_s)
             + (SELECT count(*) FROM arch_m)
             + (SELECT count(*) FROM arch_t) INTO v_archivados;
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'oposicion_id', v_op_id,
        'creados',      v_creados,
        'actualizados', v_actualiz,
        'archivados',   COALESCE(v_archivados, 0),
        'secciones_vivas', array_length(v_secs_vivas, 1)
    );
END $$;

CREATE OR REPLACE FUNCTION admin_publicar_documento(
    p_tema_slug    text,
    p_modulo_slug  text,
    p_seccion_slug text,
    p_contenido    text,
    p_ruta         text    DEFAULT NULL,
    p_commit_sha   text    DEFAULT NULL,
    p_forzar       boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_tema_id uuid; v_mod_id uuid; v_sec_id uuid;
    v_id uuid; v_origen text; v_hash_actual text; v_hash_nuevo text;
BEGIN
    PERFORM _admin_o_permiso('teoria.gestionar');
    IF p_contenido IS NULL OR btrim(p_contenido) = '' THEN
        RAISE EXCEPTION 'contenido_vacio';
    END IF;
    v_hash_nuevo := md5(p_contenido);

    SELECT id INTO v_tema_id FROM temas WHERE slug = p_tema_slug;
    IF v_tema_id IS NULL THEN
        RAISE EXCEPTION 'tema_no_encontrado' USING DETAIL = p_tema_slug;
    END IF;

    IF p_seccion_slug IS NOT NULL THEN
        v_sec_id := _seccion_por_slug(p_tema_slug, p_modulo_slug, p_seccion_slug);
        IF v_sec_id IS NULL THEN
            RAISE EXCEPTION 'seccion_no_encontrada'
                USING DETAIL = format('%s/%s/%s', p_tema_slug, p_modulo_slug, p_seccion_slug);
        END IF;
        SELECT id, origen, hash_contenido INTO v_id, v_origen, v_hash_actual
          FROM documentos WHERE seccion_id = v_sec_id AND tipo = 'teoria';
    ELSIF p_modulo_slug IS NOT NULL THEN
        SELECT id INTO v_mod_id FROM modulos WHERE tema_id = v_tema_id AND slug = p_modulo_slug;
        IF v_mod_id IS NULL THEN
            RAISE EXCEPTION 'modulo_no_encontrado'
                USING DETAIL = format('%s/%s', p_tema_slug, p_modulo_slug);
        END IF;
        SELECT id, origen, hash_contenido INTO v_id, v_origen, v_hash_actual
          FROM documentos WHERE modulo_id = v_mod_id AND tipo = 'esquema';
    ELSE
        SELECT id, origen, hash_contenido INTO v_id, v_origen, v_hash_actual
          FROM documentos WHERE tema_id = v_tema_id AND tipo = 'esquema';
    END IF;

    -- Sin cambios: no tocamos `actualizado_en` para que siga significando
    -- "cuándo cambió de verdad este texto".
    IF v_id IS NOT NULL AND v_hash_actual = v_hash_nuevo THEN
        RETURN jsonb_build_object('ok', true, 'id', v_id, 'accion', 'sin_cambios');
    END IF;

    IF v_id IS NOT NULL AND v_origen = 'manual' AND NOT p_forzar THEN
        RETURN jsonb_build_object('ok', false, 'id', v_id, 'accion', 'editado_a_mano',
                                  'detalle', 'editado desde el panel; publica con --forzar para sobrescribir');
    END IF;

    IF v_id IS NOT NULL THEN
        UPDATE documentos
           SET contenido = p_contenido, ruta = p_ruta, commit_sha = p_commit_sha,
               origen = 'publicacion', actualizado_en = now()
         WHERE id = v_id;
        RETURN jsonb_build_object('ok', true, 'id', v_id, 'accion', 'actualizado');
    END IF;

    IF v_sec_id IS NOT NULL THEN
        INSERT INTO documentos (nivel, seccion_id, tipo, contenido, ruta, commit_sha, origen)
        VALUES ('seccion', v_sec_id, 'teoria', p_contenido, p_ruta, p_commit_sha, 'publicacion')
        RETURNING id INTO v_id;
    ELSIF v_mod_id IS NOT NULL THEN
        INSERT INTO documentos (nivel, modulo_id, tipo, contenido, ruta, commit_sha, origen)
        VALUES ('modulo', v_mod_id, 'esquema', p_contenido, p_ruta, p_commit_sha, 'publicacion')
        RETURNING id INTO v_id;
    ELSE
        INSERT INTO documentos (nivel, tema_id, tipo, contenido, ruta, commit_sha, origen)
        VALUES ('tema', v_tema_id, 'esquema', p_contenido, p_ruta, p_commit_sha, 'publicacion')
        RETURNING id INTO v_id;
    END IF;
    RETURN jsonb_build_object('ok', true, 'id', v_id, 'accion', 'creado');
END $$;

CREATE OR REPLACE FUNCTION admin_publicar_preguntas(
    p_tema_slug         text,
    p_modulo_slug       text,
    p_seccion_slug      text,
    p_preguntas         jsonb,
    p_archivar_ausentes boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_sec_id   uuid;
    v_row      jsonb;
    v_id       uuid;
    v_sec_prev uuid;
    v_ids      uuid[] := '{}';
    v_nuevas   int := 0;
    v_actualiz int := 0;
    v_movidas  int := 0;
    v_archiv   int := 0;
    v_n_correctas int;
BEGIN
    IF NOT (es_admin() OR tiene_permiso('pregunta.crear')) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;

    v_sec_id := _seccion_por_slug(p_tema_slug, p_modulo_slug, p_seccion_slug);
    IF v_sec_id IS NULL THEN
        RAISE EXCEPTION 'seccion_no_encontrada'
            USING DETAIL = format('%s/%s/%s', p_tema_slug, p_modulo_slug, p_seccion_slug);
    END IF;

    FOR v_row IN SELECT * FROM jsonb_array_elements(COALESCE(p_preguntas, '[]'::jsonb)) LOOP
        -- Validación mínima: sin esto, un fallo de formato en el repo entra
        -- en producción y sólo se descubre cuando un usuario hace el test.
        IF COALESCE(btrim(v_row->>'enunciado'), '') = '' THEN
            RAISE EXCEPTION 'enunciado_vacio'
                USING DETAIL = format('en %s/%s/%s', p_tema_slug, p_modulo_slug, p_seccion_slug);
        END IF;
        IF jsonb_typeof(v_row->'opciones') <> 'array'
           OR jsonb_array_length(v_row->'opciones') < 2 THEN
            RAISE EXCEPTION 'opciones_invalidas'
                USING DETAIL = format('«%s» necesita al menos 2 opciones',
                                      left(v_row->>'enunciado', 60));
        END IF;
        SELECT count(*) INTO v_n_correctas
          FROM jsonb_array_elements(v_row->'opciones') o
         WHERE (o->>'correcta')::boolean;
        IF v_n_correctas <> 1 THEN
            RAISE EXCEPTION 'correctas_invalidas'
                USING DETAIL = format('«%s» tiene %s opciones correctas, debe tener exactamente 1',
                                      left(v_row->>'enunciado', 60), v_n_correctas);
        END IF;

        SELECT id, seccion_id INTO v_id, v_sec_prev
          FROM preguntas WHERE hash_contenido = md5(lower(btrim(v_row->>'enunciado')));

        IF v_id IS NULL THEN
            INSERT INTO preguntas (seccion_id, enunciado, opciones, explicacion)
            VALUES (v_sec_id, btrim(v_row->>'enunciado'), v_row->'opciones', v_row->>'explicacion')
            RETURNING id INTO v_id;
            v_nuevas := v_nuevas + 1;
        ELSE
            UPDATE preguntas
               SET seccion_id     = v_sec_id,
                   opciones       = v_row->'opciones',
                   explicacion    = v_row->>'explicacion',
                   archivada      = false,
                   actualizado_en = now()
             WHERE id = v_id;
            IF v_sec_prev IS DISTINCT FROM v_sec_id THEN
                v_movidas := v_movidas + 1;
            ELSE
                v_actualiz := v_actualiz + 1;
            END IF;
        END IF;
        v_ids := v_ids || v_id;
    END LOOP;

    IF p_archivar_ausentes THEN
        WITH arch AS (
            UPDATE preguntas SET archivada = true
             WHERE seccion_id = v_sec_id
               AND NOT id = ANY(v_ids)
               AND NOT archivada
            RETURNING 1
        ) SELECT count(*) INTO v_archiv FROM arch;
    END IF;

    RETURN jsonb_build_object(
        'ok', true,
        'seccion_id',   v_sec_id,
        'nuevas',       v_nuevas,
        'actualizadas', v_actualiz,
        'movidas',      v_movidas,
        'archivadas',   COALESCE(v_archiv, 0),
        'total_vivas',  array_length(v_ids, 1)
    );
END $$;

CREATE OR REPLACE FUNCTION admin_estado_publicacion(p_oposicion_slug text)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_op_id uuid; v_res jsonb;
BEGIN
    PERFORM _admin_o_permiso('contenido.editar');
    SELECT id INTO v_op_id FROM oposiciones WHERE slug = p_oposicion_slug;
    IF v_op_id IS NULL THEN
        RETURN jsonb_build_object('existe', false, 'secciones', '[]'::jsonb);
    END IF;

    SELECT jsonb_build_object(
        'existe', true,
        'oposicion_id', v_op_id,
        'secciones', COALESCE(jsonb_agg(jsonb_build_object(
            'ruta',        t.slug || '/' || m.slug || '/' || s.slug,
            'seccion_id',  s.id,
            'nombre',      s.nombre,
            'archivada',   s.archivada OR m.archivado OR t.archivado,
            'doc_hash',    d.hash_contenido,
            'doc_origen',  d.origen,
            'n_preguntas', (SELECT count(*) FROM preguntas p
                             WHERE p.seccion_id = s.id AND NOT p.archivada)
        ) ORDER BY t.slug, m.slug, s.slug), '[]'::jsonb)
    ) INTO v_res
      FROM secciones s
      JOIN modulos m ON m.id = s.modulo_id
      JOIN temas   t ON t.id = m.tema_id
      JOIN oposicion_temas ot ON ot.tema_id = t.id
      LEFT JOIN documentos d ON d.seccion_id = s.id AND d.tipo = 'teoria'
     WHERE ot.oposicion_id = v_op_id;

    RETURN v_res;
END $$;


-- ── 5. Grants ───────────────────────────────────────────────────────────────

GRANT EXECUTE ON FUNCTION _seccion_por_slug(text, text, text)                   TO web_user;
GRANT EXECUTE ON FUNCTION admin_publicar_estructura(jsonb, boolean)             TO web_user;
GRANT EXECUTE ON FUNCTION admin_publicar_documento(text,text,text,text,text,text,boolean) TO web_user;
GRANT EXECUTE ON FUNCTION admin_publicar_preguntas(text,text,text,jsonb,boolean) TO web_user;
GRANT EXECUTE ON FUNCTION admin_estado_publicacion(text)                        TO web_user;
GRANT EXECUTE ON FUNCTION admin_archivar_tema(uuid, boolean)                    TO web_user;
GRANT EXECUTE ON FUNCTION admin_archivar_modulo(uuid, boolean)                  TO web_user;
GRANT EXECUTE ON FUNCTION admin_archivar_seccion(uuid, boolean)                 TO web_user;
GRANT EXECUTE ON FUNCTION admin_upsert_documento(text, uuid, text, text, text)  TO web_user;
GRANT EXECUTE ON FUNCTION admin_crear_oposicion(text, text)                     TO web_user;

-- La firma de `admin_upsert_documento` ha cambiado (antes recibía la ruta,
-- ahora el contenido). Se retira la vieja para que no queden las dos.
DROP FUNCTION IF EXISTS admin_upsert_documento(text, uuid, text, text);

-- Resumen.
DO $mig$
DECLARE v_op int; v_mod int; v_sec int;
BEGIN
    SELECT count(*) INTO v_op  FROM oposiciones;
    SELECT count(*) INTO v_mod FROM modulos;
    SELECT count(*) INTO v_sec FROM secciones;
    RAISE NOTICE 'Slugs asignados: % oposiciones, % modulos, % secciones.', v_op, v_mod, v_sec;
    RAISE NOTICE 'Revisa que coincidan con los del repo de contenido ANTES de publicar:';
    RAISE NOTICE '  SELECT t.slug, m.slug, s.slug FROM secciones s '
                 'JOIN modulos m ON m.id=s.modulo_id JOIN temas t ON t.id=m.tema_id;';
END $mig$;

COMMIT;

NOTIFY pgrst, 'reload schema';
