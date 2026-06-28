-- ============================================================================
-- 12_test_tematico_y_borrado.sql
-- 1) crear_test_tematico_multi(): genera un test a partir de una o varias
--    etiquetas, expandiendo cada una a su subárbol jerárquico y priorizando
--    las preguntas que el usuario ha visto menos veces (con random como
--    desempate). Así dos ejecuciones consecutivas no repiten todo.
-- 2) borrar_test_y_preguntas(): borra el test y, además, las preguntas que
--    sólo existían dentro de él (no afecta a preguntas compartidas con
--    otros tests).
-- ============================================================================


-- ─────────────── 1) Test temático multi-etiqueta ──────────────────────────
CREATE OR REPLACE FUNCTION crear_test_tematico_multi(
    p_etiquetas text[],
    p_n         int  DEFAULT 20,
    p_titulo    text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_test       uuid;
    v_titulo     text;
    v_expandidas text[];
    v_n_real     int;
BEGIN
    IF jwt_usuario_id() IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    IF p_etiquetas IS NULL OR cardinality(p_etiquetas) = 0 THEN
        RAISE EXCEPTION 'etiquetas_vacias';
    END IF;
    IF p_n IS NULL OR p_n < 1 THEN p_n := 20; END IF;

    -- Une la expansión jerárquica de cada etiqueta (incluye descendientes).
    SELECT COALESCE(array_agg(DISTINCT e), '{}'::text[]) INTO v_expandidas
      FROM unnest(p_etiquetas) AS t
           CROSS JOIN LATERAL unnest(etiqueta_y_descendientes(t)) AS e;

    v_titulo := COALESCE(
        NULLIF(btrim(p_titulo), ''),
        'Test temático: ' || array_to_string(p_etiquetas, ', ')
    );

    INSERT INTO tests(titulo, tipo, autor_id)
    VALUES (v_titulo, 'tematico', jwt_usuario_id())
    RETURNING id INTO v_test;

    -- Selecciona N preguntas dando prioridad a las menos vistas por el usuario.
    -- random() rompe los empates dentro de un mismo nivel de "visto".
    WITH candidatas AS (
        SELECT p.id,
               (SELECT count(*) FROM respuestas r
                  JOIN intentos i ON i.id = r.intento_id
                 WHERE r.pregunta_id = p.id
                   AND i.usuario_id = jwt_usuario_id()) AS veces_vista
          FROM preguntas p
         WHERE p.etiquetas && v_expandidas
    ),
    elegidas AS (
        SELECT id, row_number() OVER (ORDER BY veces_vista ASC, random()) AS pos
          FROM candidatas
         LIMIT p_n
    )
    INSERT INTO test_preguntas(test_id, pregunta_id, posicion)
    SELECT v_test, id, pos FROM elegidas;

    GET DIAGNOSTICS v_n_real = ROW_COUNT;
    IF v_n_real = 0 THEN
        -- Limpia el test vacío y avisa.
        DELETE FROM tests WHERE id = v_test;
        RAISE EXCEPTION 'sin_preguntas_para_etiquetas';
    END IF;

    RETURN v_test;
END $$;

GRANT EXECUTE ON FUNCTION crear_test_tematico_multi(text[], int, text)
    TO web_user;


-- ─────────────── Buscar preguntas con filtro multi-etiqueta ───────────────
-- Variante de buscar_preguntas que acepta un array (OR entre etiquetas) con
-- expansión jerárquica. Conserva la función original (text, int, text) para
-- no romper a quien la llame con una sola etiqueta.
CREATE OR REPLACE FUNCTION buscar_preguntas_multi(
    p_q         text,
    p_lim       int     DEFAULT 40,
    p_etiquetas text[]  DEFAULT NULL
) RETURNS TABLE (id uuid, enunciado text, score real, etiquetas text[])
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_expandidas text[];
BEGIN
    IF p_etiquetas IS NOT NULL AND cardinality(p_etiquetas) > 0 THEN
        SELECT COALESCE(array_agg(DISTINCT e), '{}'::text[]) INTO v_expandidas
          FROM unnest(p_etiquetas) AS t
               CROSS JOIN LATERAL unnest(etiqueta_y_descendientes(t)) AS e;
    END IF;

    RETURN QUERY
    SELECT p.id, p.enunciado,
           similarity(p.enunciado, p_q) AS score,
           p.etiquetas
      FROM preguntas p
     WHERE (p_q IS NULL OR p_q = '' OR p.enunciado %> p_q)
       AND (
            v_expandidas IS NULL
            OR p.etiquetas && v_expandidas
       )
     ORDER BY similarity(p.enunciado, p_q) DESC NULLS LAST
     LIMIT p_lim;
END $$;

GRANT EXECUTE ON FUNCTION buscar_preguntas_multi(text, int, text[])
    TO web_user;


-- ─────────────── 2) Borrar test (opcionalmente con sus preguntas) ─────────
-- Borra el test SIEMPRE. Si p_borrar_preguntas=true, además elimina las
-- preguntas que pertenecían solo a este test (las compartidas con otros
-- tests se conservan intactas). Devuelve un resumen con los contadores.
CREATE OR REPLACE FUNCTION borrar_test_y_preguntas(
    p_test_id           uuid,
    p_borrar_preguntas  boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_es_admin           boolean := es_admin();
    v_autor              uuid;
    v_preguntas_borradas int := 0;
    v_preguntas_compartidas int := 0;
BEGIN
    SELECT autor_id INTO v_autor FROM tests WHERE id = p_test_id;
    IF v_autor IS NULL THEN RAISE EXCEPTION 'test_no_encontrado'; END IF;

    IF NOT (v_es_admin OR v_autor = jwt_usuario_id() OR tiene_permiso('test.borrar')) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;

    IF p_borrar_preguntas THEN
        -- Cuenta cuántas son compartidas (solo para devolverlo en el resumen).
        SELECT count(*) INTO v_preguntas_compartidas
          FROM test_preguntas tp
         WHERE tp.test_id = p_test_id
           AND EXISTS (
               SELECT 1 FROM test_preguntas tp2
                WHERE tp2.pregunta_id = tp.pregunta_id
                  AND tp2.test_id <> p_test_id
           );

        -- Borra las exclusivas. ON DELETE CASCADE de test_preguntas se
        -- encarga de limpiar las entradas residuales.
        WITH exclusivas AS (
            SELECT tp.pregunta_id
              FROM test_preguntas tp
             WHERE tp.test_id = p_test_id
               AND NOT EXISTS (
                   SELECT 1 FROM test_preguntas tp2
                    WHERE tp2.pregunta_id = tp.pregunta_id
                      AND tp2.test_id <> p_test_id
               )
        )
        DELETE FROM preguntas p
         USING exclusivas e
         WHERE p.id = e.pregunta_id;
        GET DIAGNOSTICS v_preguntas_borradas = ROW_COUNT;
    END IF;

    DELETE FROM tests WHERE id = p_test_id;

    RETURN jsonb_build_object(
        'test_id',                  p_test_id,
        'preguntas_borradas',       v_preguntas_borradas,
        'preguntas_compartidas',    v_preguntas_compartidas
    );
END $$;

GRANT EXECUTE ON FUNCTION borrar_test_y_preguntas(uuid, boolean) TO web_user;
