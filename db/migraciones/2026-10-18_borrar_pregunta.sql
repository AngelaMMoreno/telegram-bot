-- Borra una pregunta por completo: de todos los tests en que esté incluida
-- y de fallos, favoritas, respuestas y repasos de todos los usuarios (las
-- FK a preguntas son ON DELETE CASCADE). Exige admin o `pregunta.borrar`.
-- Idempotente.
BEGIN;

CREATE OR REPLACE FUNCTION borrar_pregunta(p_pregunta_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
    v_tests int;
BEGIN
    IF NOT (es_admin() OR tiene_permiso('pregunta.borrar')) THEN
        RAISE EXCEPTION 'no_autorizado';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM preguntas WHERE id = p_pregunta_id) THEN
        RAISE EXCEPTION 'pregunta_no_encontrada';
    END IF;

    SELECT count(*) INTO v_tests FROM test_preguntas WHERE pregunta_id = p_pregunta_id;

    -- ON DELETE CASCADE limpia test_preguntas, respuestas, marcadores
    -- (fallos y favoritas) y repasos de todos los usuarios.
    DELETE FROM preguntas WHERE id = p_pregunta_id;

    RETURN jsonb_build_object('id', p_pregunta_id, 'tests_afectados', v_tests);
END $fn$;

GRANT EXECUTE ON FUNCTION borrar_pregunta(uuid) TO web_user;

COMMIT;

NOTIFY pgrst, 'reload schema';
