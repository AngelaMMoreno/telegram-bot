-- ============================================================================
-- 05_etiquetado_avanzado.sql
-- Etiquetado híbrido (embedding + palabras clave) y clasificación de tests.
-- Todos los ALTER usan IF NOT EXISTS para ser idempotentes.
-- ============================================================================

ALTER TABLE catalogo_etiquetas
    ADD COLUMN IF NOT EXISTS palabras_clave text[] NOT NULL DEFAULT '{}';

ALTER TABLE tests
    ADD COLUMN IF NOT EXISTS etiquetas text[] NOT NULL DEFAULT '{}';

CREATE INDEX IF NOT EXISTS tests_etiquetas_idx ON tests USING gin (etiquetas);


-- ─────────────── Auto-tagger híbrido ──────────────────────────────────────
-- Combina:
--   a) similitud coseno embedding (precisión)
--   b) match ILIKE del enunciado contra cada palabra_clave  (recall)
--   c) match ILIKE del enunciado contra el nombre de la etiqueta
--   d) match ILIKE del TÍTULO DEL TEST contra el nombre o palabras_clave
--      (etiqueta transitiva: si el test se llama "Java avanzado", todas
--      sus preguntas reciben 'java' aunque no lo digan literalmente).
-- Conservador: solo añade, nunca quita.

CREATE OR REPLACE FUNCTION reclasificar_pregunta(
    p_id     uuid,
    k        int   DEFAULT 5,
    umbral   real  DEFAULT 0.55
) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
    v_emun     text;
    v_emb      vector(768);
    v_test_tit text;
    v_n        int;
BEGIN
    SELECT p.enunciado, p.embedding,
           (SELECT t.titulo FROM test_preguntas tp
              JOIN tests t ON t.id = tp.test_id
             WHERE tp.pregunta_id = p.id
             ORDER BY t.creado_en LIMIT 1)
      INTO v_emun, v_emb, v_test_tit
      FROM preguntas p WHERE p.id = p_id;

    IF v_emun IS NULL THEN RETURN 0; END IF;

    WITH candidatas AS (
        SELECT c.nombre FROM catalogo_etiquetas c
        WHERE
            -- (a) vector
            (v_emb IS NOT NULL AND c.embedding IS NOT NULL
             AND 1 - (c.embedding <=> v_emb) > umbral)
            -- (b) palabra clave en el enunciado
            OR EXISTS (
                SELECT 1 FROM unnest(c.palabras_clave) kw
                WHERE v_emun ILIKE '%' || kw || '%'
            )
            -- (c) nombre de la etiqueta en el enunciado
            OR v_emun ILIKE '%' || c.nombre || '%'
            -- (d) nombre o palabra clave en el título del test
            OR (
                v_test_tit IS NOT NULL AND (
                    v_test_tit ILIKE '%' || c.nombre || '%'
                    OR EXISTS (
                        SELECT 1 FROM unnest(c.palabras_clave) kw
                        WHERE v_test_tit ILIKE '%' || kw || '%'
                    )
                )
            )
    )
    UPDATE preguntas
       SET etiquetas = ARRAY(
               SELECT DISTINCT e
                 FROM unnest(etiquetas || ARRAY(SELECT nombre FROM candidatas)) AS e
           ),
           actualizado_en = now()
     WHERE id = p_id;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END $$;


-- ─────────────── Clasificar UN test ───────────────────────────────────────
-- Mira el título del test contra las etiquetas (por nombre o palabra clave),
-- añade las que casen a tests.etiquetas[] y PROPAGA a todas las preguntas
-- del test.

CREATE OR REPLACE FUNCTION clasificar_test(p_test_id uuid) RETURNS text[]
LANGUAGE plpgsql AS $$
DECLARE
    v_titulo    text;
    v_descr     text;
    v_etiq_nuevas text[];
BEGIN
    SELECT titulo, descripcion INTO v_titulo, v_descr
      FROM tests WHERE id = p_test_id;
    IF v_titulo IS NULL THEN RETURN '{}'::text[]; END IF;

    SELECT array_agg(DISTINCT c.nombre) INTO v_etiq_nuevas
      FROM catalogo_etiquetas c
     WHERE v_titulo ILIKE '%' || c.nombre || '%'
        OR (v_descr IS NOT NULL AND v_descr ILIKE '%' || c.nombre || '%')
        OR EXISTS (
            SELECT 1 FROM unnest(c.palabras_clave) kw
            WHERE v_titulo ILIKE '%' || kw || '%'
               OR (v_descr IS NOT NULL AND v_descr ILIKE '%' || kw || '%')
        );

    IF v_etiq_nuevas IS NULL OR cardinality(v_etiq_nuevas) = 0 THEN
        RETURN '{}'::text[];
    END IF;

    UPDATE tests SET etiquetas = ARRAY(
        SELECT DISTINCT e FROM unnest(etiquetas || v_etiq_nuevas) AS e
    ) WHERE id = p_test_id;

    UPDATE preguntas
       SET etiquetas = ARRAY(
               SELECT DISTINCT e FROM unnest(preguntas.etiquetas || v_etiq_nuevas) AS e
           ),
           actualizado_en = now()
     WHERE id IN (SELECT pregunta_id FROM test_preguntas WHERE test_id = p_test_id);

    RETURN v_etiq_nuevas;
END $$;


-- ─────────────── Recorrer TODOS los tests + TODAS las preguntas ────────────

CREATE OR REPLACE FUNCTION reclasificar_todo() RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_tests_n      int := 0;
    v_preguntas_n  int := 0;
    v_id           uuid;
BEGIN
    IF NOT (tiene_permiso('etiqueta.gestionar') OR es_admin()) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;

    -- 1) Clasifica tests (también propaga a sus preguntas)
    FOR v_id IN SELECT id FROM tests LOOP
        PERFORM clasificar_test(v_id);
        v_tests_n := v_tests_n + 1;
    END LOOP;

    -- 2) Re-clasifica preguntas (vector + palabras clave + transitivo)
    FOR v_id IN SELECT id FROM preguntas LOOP
        PERFORM reclasificar_pregunta(v_id);
        v_preguntas_n := v_preguntas_n + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'tests_procesados',     v_tests_n,
        'preguntas_procesadas', v_preguntas_n
    );
END $$;


-- ─────────────── listar_etiquetas devuelve también palabras_clave ──────────

CREATE OR REPLACE FUNCTION listar_etiquetas() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'nombre',         c.nombre,
        'descripcion',    c.descripcion,
        'palabras_clave', c.palabras_clave,
        'creada_en',      c.creado_en,
        'vectorizada',    c.embedding IS NOT NULL,
        'num_preguntas',  (SELECT count(*) FROM preguntas
                            WHERE c.nombre = ANY(etiquetas)),
        'num_tests',      (SELECT count(*) FROM tests
                            WHERE c.nombre = ANY(etiquetas))
    ) ORDER BY c.nombre), '[]'::jsonb)
    FROM catalogo_etiquetas c;
$$;


-- ─────────────── crear_etiqueta acepta palabras_clave ──────────────────────

CREATE OR REPLACE FUNCTION crear_etiqueta(
    p_nombre        text,
    p_descripcion   text,
    p_palabras_clave text[] DEFAULT '{}'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v jsonb;
BEGIN
    IF NOT (tiene_permiso('etiqueta.gestionar') OR es_admin()) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    p_nombre := lower(btrim(p_nombre));
    IF length(p_nombre) = 0 THEN RAISE EXCEPTION 'nombre_vacio'; END IF;

    INSERT INTO catalogo_etiquetas(nombre, descripcion, palabras_clave)
    VALUES (
        p_nombre,
        NULLIF(btrim(p_descripcion), ''),
        COALESCE(p_palabras_clave, '{}')
    )
    ON CONFLICT (nombre) DO UPDATE
        SET descripcion    = EXCLUDED.descripcion,
            palabras_clave = EXCLUDED.palabras_clave;

    SELECT to_jsonb(c) INTO v FROM catalogo_etiquetas c WHERE nombre = p_nombre;
    RETURN v;
END $$;


-- ─────────────── listar_tests con filtros y ordenación ────────────────────
-- Filtros: por etiqueta, solo_favoritos, solo_pendientes (con intento abierto).
-- Orden:   reciente (default) | antiguo | intentos_desc | intentos_asc.

DROP FUNCTION IF EXISTS listar_tests(boolean,int,int);
DROP FUNCTION IF EXISTS listar_tests(boolean,int,int,text);

CREATE OR REPLACE FUNCTION listar_tests(
    p_solo_favoritos  boolean DEFAULT false,
    p_page            int     DEFAULT 1,
    p_size            int     DEFAULT 10,
    p_etiqueta        text    DEFAULT NULL,
    p_solo_pendientes boolean DEFAULT false,
    p_orden           text    DEFAULT 'reciente'
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_offset int := GREATEST(p_page - 1, 0) * p_size;
    v_total  int;
    v_tests  jsonb;
BEGIN
    WITH base AS (
        SELECT
            t.id, t.titulo, t.descripcion, t.tipo, t.publico,
            t.etiquetas, t.creado_en,
            (SELECT count(*) FROM test_preguntas tp WHERE tp.test_id = t.id) AS num_preguntas,
            (SELECT count(*) FROM intentos i
              WHERE i.test_id = t.id AND i.usuario_id = jwt_usuario_id()) AS num_intentos,
            EXISTS (
                SELECT 1 FROM intentos i
                 WHERE i.test_id = t.id
                   AND i.usuario_id = jwt_usuario_id()
                   AND i.finalizado_en IS NULL
            ) AS tiene_pendiente,
            EXISTS (
                SELECT 1 FROM marcadores m
                 WHERE m.usuario_id = jwt_usuario_id()
                   AND m.tipo = 'test_favorito'
                   AND m.test_id = t.id
            ) AS favorito
        FROM tests t
        WHERE (t.publico OR t.autor_id = jwt_usuario_id() OR es_admin())
          AND (p_etiqueta IS NULL OR p_etiqueta = ANY(t.etiquetas))
    ),
    filtrada AS (
        SELECT * FROM base
        WHERE (NOT p_solo_favoritos  OR favorito)
          AND (NOT p_solo_pendientes OR tiene_pendiente)
    )
    SELECT count(*) INTO v_total FROM filtrada;

    WITH base AS (
        SELECT
            t.id, t.titulo, t.descripcion, t.tipo, t.publico,
            t.etiquetas, t.creado_en,
            (SELECT count(*) FROM test_preguntas tp WHERE tp.test_id = t.id) AS num_preguntas,
            (SELECT count(*) FROM intentos i
              WHERE i.test_id = t.id AND i.usuario_id = jwt_usuario_id()) AS num_intentos,
            EXISTS (
                SELECT 1 FROM intentos i
                 WHERE i.test_id = t.id
                   AND i.usuario_id = jwt_usuario_id()
                   AND i.finalizado_en IS NULL
            ) AS tiene_pendiente,
            EXISTS (
                SELECT 1 FROM marcadores m
                 WHERE m.usuario_id = jwt_usuario_id()
                   AND m.tipo = 'test_favorito'
                   AND m.test_id = t.id
            ) AS favorito
        FROM tests t
        WHERE (t.publico OR t.autor_id = jwt_usuario_id() OR es_admin())
          AND (p_etiqueta IS NULL OR p_etiqueta = ANY(t.etiquetas))
    )
    SELECT COALESCE(jsonb_agg(row_to_json(x)), '[]'::jsonb) INTO v_tests
    FROM (
        SELECT
            b.id,
            b.titulo       AS title,
            b.descripcion  AS description,
            b.tipo,
            b.publico,
            b.etiquetas,
            b.creado_en    AS created_at,
            b.num_preguntas,
            b.num_intentos,
            b.tiene_pendiente,
            b.favorito
        FROM base b
        WHERE (NOT p_solo_favoritos  OR b.favorito)
          AND (NOT p_solo_pendientes OR b.tiene_pendiente)
        ORDER BY
            (CASE WHEN p_orden = 'intentos_desc' THEN b.num_intentos ELSE NULL END) DESC NULLS LAST,
            (CASE WHEN p_orden = 'intentos_asc'  THEN b.num_intentos ELSE NULL END) ASC  NULLS LAST,
            (CASE WHEN p_orden = 'antiguo'       THEN b.creado_en    ELSE NULL END) ASC  NULLS LAST,
            b.creado_en DESC
        LIMIT p_size OFFSET v_offset
    ) x;

    RETURN jsonb_build_object(
        'tests',       v_tests,
        'page',        p_page,
        'page_size',   p_size,
        'total',       v_total,
        'total_pages', GREATEST(1, (v_total + p_size - 1) / p_size)
    );
END $$;

GRANT EXECUTE ON FUNCTION listar_tests(boolean,int,int,text,boolean,text) TO web_user;


-- ─────────────── Buscar preguntas con filtro por etiqueta opcional ─────────

CREATE OR REPLACE FUNCTION buscar_preguntas(
    p_q        text,
    p_lim      int  DEFAULT 20,
    p_etiqueta text DEFAULT NULL
) RETURNS TABLE (id uuid, enunciado text, score real, etiquetas text[])
LANGUAGE sql STABLE AS $$
    SELECT p.id, p.enunciado,
           similarity(p.enunciado, p_q) AS score,
           p.etiquetas
    FROM preguntas p
    WHERE (p_q IS NULL OR p_q = '' OR p.enunciado %> p_q)
      AND (p_etiqueta IS NULL OR p_etiqueta = ANY(p.etiquetas))
    ORDER BY similarity(p.enunciado, p_q) DESC NULLS LAST
    LIMIT p_lim;
$$;


GRANT EXECUTE ON FUNCTION clasificar_test(uuid)                     TO web_user;
GRANT EXECUTE ON FUNCTION reclasificar_todo()                       TO web_user;
GRANT EXECUTE ON FUNCTION crear_etiqueta(text,text,text[])          TO web_user;
-- listar_tests: GRANT junto a la función (acepta 6 parámetros).
GRANT EXECUTE ON FUNCTION buscar_preguntas(text,int,text)           TO web_user;
