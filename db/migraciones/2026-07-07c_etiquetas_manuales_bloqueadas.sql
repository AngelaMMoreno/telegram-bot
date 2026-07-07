-- Prioridad del humano sobre el auto-tagger.
--
-- Contexto: hasta ahora `reclasificar_pregunta` y `clasificar_test` sólo
-- SUMABAN etiquetas. Si un usuario quitaba a mano una etiqueta mal puesta,
-- la siguiente pasada del clasificador (o la revectorización tras un
-- cambio en el catálogo) volvía a ponerla. Esto invertía la relación:
-- el modelo pisaba la corrección humana.
--
-- Con este delta:
--
--   • Cada pregunta y cada test guardan `etiquetas_manuales` (lo que el
--     usuario ha puesto a mano) y `etiquetas_bloqueadas` (lo que el
--     usuario ha quitado a mano).
--   • El auto-tagger NUNCA vuelve a añadir una etiqueta bloqueada.
--   • Las etiquetas manuales de las preguntas vecinas cuentan como
--     doble voto en el kNN: la corrección humana ES el bucle de mejora.
--   • Nueva RPC `set_etiquetas_pregunta(id, nuevas[])` y
--     `set_etiquetas_test(id, nuevas[])`: cualquier admin/editor
--     (o autor del test) puede reasignar la lista completa desde la SPA
--     y los conjuntos manuales/bloqueadas se recalculan solos por diff.
--
-- Es idempotente: se puede volver a ejecutar sin efectos duplicados.

SET search_path = public;

-- ────────── 1. Nuevas columnas ──────────

ALTER TABLE preguntas
    ADD COLUMN IF NOT EXISTS etiquetas_manuales   text[] NOT NULL DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS etiquetas_bloqueadas text[] NOT NULL DEFAULT '{}';

ALTER TABLE tests
    ADD COLUMN IF NOT EXISTS etiquetas_manuales   text[] NOT NULL DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS etiquetas_bloqueadas text[] NOT NULL DEFAULT '{}';


-- ────────── 2. Auto-tagger que respeta lo humano ──────────

CREATE OR REPLACE FUNCTION reclasificar_pregunta(
    p_id          uuid,
    k             int  DEFAULT 5,
    umbral        real DEFAULT 0.55,
    p_knn_k       int  DEFAULT 5,
    p_knn_umbral  real DEFAULT 0.70,
    p_knn_min     int  DEFAULT 1
) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
    v_emun       text;
    v_emb        vector(1024);
    v_test_tit   text;
    v_bloqueadas text[];
    v_n          int;
BEGIN
    SELECT p.enunciado, p.embedding, p.etiquetas_bloqueadas,
           (SELECT t.titulo FROM test_preguntas tp
              JOIN tests t ON t.id = tp.test_id
             WHERE tp.pregunta_id = p.id
             ORDER BY t.creado_en LIMIT 1)
      INTO v_emun, v_emb, v_bloqueadas, v_test_tit
      FROM preguntas p WHERE p.id = p_id;

    IF v_emun IS NULL THEN RETURN 0; END IF;

    SELECT array_agg(DISTINCT b) INTO v_bloqueadas FROM (
        SELECT unnest(COALESCE(v_bloqueadas, '{}'::text[])) AS b
        UNION
        SELECT unnest(COALESCE(t.etiquetas_bloqueadas, '{}'::text[])) AS b
          FROM test_preguntas tp JOIN tests t ON t.id = tp.test_id
         WHERE tp.pregunta_id = p_id
    ) x WHERE b IS NOT NULL;
    v_bloqueadas := COALESCE(v_bloqueadas, '{}'::text[]);

    WITH
    cat AS (
        SELECT c.nombre FROM catalogo_etiquetas c
        WHERE
            (v_emb IS NOT NULL AND c.embedding IS NOT NULL
             AND 1 - (c.embedding <=> v_emb) > umbral)
            OR EXISTS (
                SELECT 1 FROM unnest(c.palabras_clave) kw
                WHERE v_emun ILIKE '%' || kw || '%'
            )
            OR v_emun ILIKE '%' || c.nombre || '%'
            OR (
                v_test_tit IS NOT NULL AND (
                    v_test_tit ILIKE '%' || c.nombre || '%'
                    OR EXISTS (
                        SELECT 1 FROM unnest(c.palabras_clave) kw
                        WHERE v_test_tit ILIKE '%' || kw || '%'
                    )
                )
            )
    ),
    vecinas AS (
        SELECT id, etiquetas, etiquetas_manuales, etiquetas_bloqueadas,
               1 - (embedding <=> v_emb) AS sim
          FROM preguntas
         WHERE v_emb IS NOT NULL
           AND embedding IS NOT NULL
           AND id <> p_id
           AND cardinality(etiquetas) > 0
         ORDER BY embedding <=> v_emb
         LIMIT GREATEST(p_knn_k, 1)
    ),
    votos_knn AS (
        SELECT v.e AS nombre,
               SUM(v.peso) AS peso
          FROM (
            SELECT unnest(etiquetas)          AS e,  1 AS peso FROM vecinas WHERE sim >= p_knn_umbral
            UNION ALL
            SELECT unnest(etiquetas_manuales) AS e,  2 AS peso FROM vecinas WHERE sim >= p_knn_umbral
            UNION ALL
            SELECT unnest(etiquetas_bloqueadas) AS e, -3 AS peso FROM vecinas WHERE sim >= p_knn_umbral
          ) v
         GROUP BY v.e
    ),
    knn AS (
        SELECT nombre FROM votos_knn
         WHERE peso >= GREATEST(p_knn_min, 1)
    ),
    candidatas AS (
        SELECT nombre FROM cat
        UNION
        SELECT nombre FROM knn
    )
    UPDATE preguntas
       SET etiquetas = ARRAY(
               SELECT DISTINCT e
                 FROM unnest(etiquetas || ARRAY(SELECT nombre FROM candidatas)) AS e
                WHERE e <> ALL(v_bloqueadas)
           ),
           actualizado_en = now()
     WHERE id = p_id;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END $$;


CREATE OR REPLACE FUNCTION clasificar_test(p_test_id uuid) RETURNS text[]
LANGUAGE plpgsql AS $$
DECLARE
    v_titulo      text;
    v_descr       text;
    v_bloq_test   text[];
    v_etiq_nuevas text[];
BEGIN
    SELECT titulo, descripcion, etiquetas_bloqueadas
      INTO v_titulo, v_descr, v_bloq_test
      FROM tests WHERE id = p_test_id;
    IF v_titulo IS NULL THEN RETURN '{}'::text[]; END IF;

    SELECT array_agg(DISTINCT c.nombre) INTO v_etiq_nuevas
      FROM catalogo_etiquetas c
     WHERE (v_titulo ILIKE '%' || c.nombre || '%'
        OR (v_descr IS NOT NULL AND v_descr ILIKE '%' || c.nombre || '%')
        OR EXISTS (
            SELECT 1 FROM unnest(c.palabras_clave) kw
            WHERE v_titulo ILIKE '%' || kw || '%'
               OR (v_descr IS NOT NULL AND v_descr ILIKE '%' || kw || '%')
        ))
       AND c.nombre <> ALL(COALESCE(v_bloq_test, '{}'::text[]));

    IF v_etiq_nuevas IS NULL OR cardinality(v_etiq_nuevas) = 0 THEN
        RETURN '{}'::text[];
    END IF;

    UPDATE tests SET etiquetas = ARRAY(
        SELECT DISTINCT e FROM unnest(etiquetas || v_etiq_nuevas) AS e
        WHERE e <> ALL(COALESCE(v_bloq_test, '{}'::text[]))
    ) WHERE id = p_test_id;

    UPDATE preguntas
       SET etiquetas = ARRAY(
               SELECT DISTINCT e
                 FROM unnest(preguntas.etiquetas || v_etiq_nuevas) AS e
                WHERE e <> ALL(COALESCE(preguntas.etiquetas_bloqueadas, '{}'::text[]))
                  AND e <> ALL(COALESCE(v_bloq_test, '{}'::text[]))
           ),
           actualizado_en = now()
     WHERE id IN (SELECT pregunta_id FROM test_preguntas WHERE test_id = p_test_id);

    RETURN v_etiq_nuevas;
END $$;


-- ────────── 3. Borrado de etiqueta: también limpia listas humanas ──────────

CREATE OR REPLACE FUNCTION borrar_etiqueta(p_nombre text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT (tiene_permiso('etiqueta.gestionar') OR es_admin()) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    DELETE FROM catalogo_etiquetas WHERE nombre = p_nombre;
    UPDATE preguntas
       SET etiquetas            = array_remove(etiquetas, p_nombre),
           etiquetas_manuales   = array_remove(etiquetas_manuales, p_nombre),
           etiquetas_bloqueadas = array_remove(etiquetas_bloqueadas, p_nombre),
           actualizado_en       = now()
     WHERE p_nombre = ANY(etiquetas)
        OR p_nombre = ANY(etiquetas_manuales)
        OR p_nombre = ANY(etiquetas_bloqueadas);
    UPDATE tests
       SET etiquetas            = array_remove(etiquetas, p_nombre),
           etiquetas_manuales   = array_remove(etiquetas_manuales, p_nombre),
           etiquetas_bloqueadas = array_remove(etiquetas_bloqueadas, p_nombre)
     WHERE p_nombre = ANY(etiquetas)
        OR p_nombre = ANY(etiquetas_manuales)
        OR p_nombre = ANY(etiquetas_bloqueadas);
END $$;


-- ────────── 4. RPCs para editar desde la SPA ──────────

CREATE OR REPLACE FUNCTION set_etiquetas_pregunta(
    p_id        uuid,
    p_etiquetas text[]
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_prev      text[];
    v_manuales  text[];
    v_bloq      text[];
    v_nuevas    text[];
    v_anadidas  text[];
    v_quitadas  text[];
BEGIN
    IF NOT (tiene_permiso('pregunta.editar') OR es_admin()) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;

    SELECT etiquetas, etiquetas_manuales, etiquetas_bloqueadas
      INTO v_prev, v_manuales, v_bloq
      FROM preguntas WHERE id = p_id;
    IF v_prev IS NULL THEN RAISE EXCEPTION 'pregunta_no_existe'; END IF;

    v_nuevas := ARRAY(
        SELECT DISTINCT lower(btrim(e))
          FROM unnest(COALESCE(p_etiquetas, '{}'::text[])) e
         WHERE btrim(e) <> ''
    );

    v_anadidas := ARRAY(
        SELECT e FROM unnest(v_nuevas) e
         WHERE e <> ALL(COALESCE(v_prev, '{}'::text[]))
    );
    v_quitadas := ARRAY(
        SELECT e FROM unnest(COALESCE(v_prev, '{}'::text[])) e
         WHERE e <> ALL(v_nuevas)
    );

    UPDATE preguntas
       SET etiquetas            = v_nuevas,
           etiquetas_manuales   = ARRAY(
               SELECT DISTINCT e
                 FROM unnest(COALESCE(v_manuales, '{}'::text[]) || v_anadidas) e
                WHERE e = ANY(v_nuevas)
           ),
           etiquetas_bloqueadas = ARRAY(
               SELECT DISTINCT e
                 FROM unnest(COALESCE(v_bloq, '{}'::text[]) || v_quitadas) e
                WHERE e <> ALL(v_nuevas)
           ),
           actualizado_en       = now()
     WHERE id = p_id;

    RETURN jsonb_build_object(
        'id',                 p_id,
        'etiquetas',          v_nuevas,
        'etiquetas_anadidas', v_anadidas,
        'etiquetas_quitadas', v_quitadas
    );
END $$;


CREATE OR REPLACE FUNCTION set_etiquetas_test(
    p_test_id   uuid,
    p_etiquetas text[]
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_prev      text[];
    v_manuales  text[];
    v_bloq      text[];
    v_autor     uuid;
    v_nuevas    text[];
    v_anadidas  text[];
    v_quitadas  text[];
BEGIN
    SELECT etiquetas, etiquetas_manuales, etiquetas_bloqueadas, autor_id
      INTO v_prev, v_manuales, v_bloq, v_autor
      FROM tests WHERE id = p_test_id;
    IF v_prev IS NULL THEN RAISE EXCEPTION 'test_no_existe'; END IF;

    IF NOT (tiene_permiso('test.editar')
            OR es_admin()
            OR v_autor = jwt_usuario_id()) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;

    v_nuevas := ARRAY(
        SELECT DISTINCT lower(btrim(e))
          FROM unnest(COALESCE(p_etiquetas, '{}'::text[])) e
         WHERE btrim(e) <> ''
    );

    v_anadidas := ARRAY(
        SELECT e FROM unnest(v_nuevas) e
         WHERE e <> ALL(COALESCE(v_prev, '{}'::text[]))
    );
    v_quitadas := ARRAY(
        SELECT e FROM unnest(COALESCE(v_prev, '{}'::text[])) e
         WHERE e <> ALL(v_nuevas)
    );

    UPDATE tests
       SET etiquetas            = v_nuevas,
           etiquetas_manuales   = ARRAY(
               SELECT DISTINCT e
                 FROM unnest(COALESCE(v_manuales, '{}'::text[]) || v_anadidas) e
                WHERE e = ANY(v_nuevas)
           ),
           etiquetas_bloqueadas = ARRAY(
               SELECT DISTINCT e
                 FROM unnest(COALESCE(v_bloq, '{}'::text[]) || v_quitadas) e
                WHERE e <> ALL(v_nuevas)
           )
     WHERE id = p_test_id;

    IF cardinality(v_anadidas) > 0 THEN
        UPDATE preguntas
           SET etiquetas = ARRAY(
                   SELECT DISTINCT e
                     FROM unnest(etiquetas || v_anadidas) e
                    WHERE e <> ALL(COALESCE(etiquetas_bloqueadas, '{}'::text[]))
               ),
               actualizado_en = now()
         WHERE id IN (SELECT pregunta_id FROM test_preguntas WHERE test_id = p_test_id);
    END IF;

    IF cardinality(v_quitadas) > 0 THEN
        UPDATE preguntas
           SET etiquetas = ARRAY(
                   SELECT e FROM unnest(etiquetas) e
                    WHERE e <> ALL(v_quitadas)
                       OR e = ANY(COALESCE(etiquetas_manuales, '{}'::text[]))
               ),
               etiquetas_bloqueadas = ARRAY(
                   SELECT DISTINCT e
                     FROM unnest(
                         COALESCE(etiquetas_bloqueadas, '{}'::text[]) || v_quitadas
                     ) e
                    WHERE e <> ALL(COALESCE(etiquetas_manuales, '{}'::text[]))
               ),
               actualizado_en = now()
         WHERE id IN (SELECT pregunta_id FROM test_preguntas WHERE test_id = p_test_id);
    END IF;

    RETURN jsonb_build_object(
        'test_id',            p_test_id,
        'etiquetas',          v_nuevas,
        'etiquetas_anadidas', v_anadidas,
        'etiquetas_quitadas', v_quitadas
    );
END $$;


-- ────────── 5. GRANTS ──────────

GRANT EXECUTE ON FUNCTION set_etiquetas_pregunta(uuid, text[]) TO web_user;
GRANT EXECUTE ON FUNCTION set_etiquetas_test(uuid, text[])     TO web_user;


NOTIFY pgrst, 'reload schema';

DO $$ BEGIN
    RAISE NOTICE 'etiquetas_manuales/bloqueadas: columnas y RPCs listos.';
END $$;
