-- ─────────────────────────────────────────────────────────────────────────
-- API para subir tests a una oposición ya creada y listar sus tests.
--
-- Motivación: hasta ahora, subir un test a una oposición exigía dos
-- llamadas (`importar_test_normalizado` + `set_test_oposiciones`), sin
-- validar el JSON y sin forma de listar los tests de una oposición con
-- su nombre/descripción (`tests_de_oposicion` solo devuelve ids). Estas
-- dos RPCs (expuestas por PostgREST en /rpc/...) cubren el caso de uso
-- "automatizar la subida de tests":
--
--   • subir_test_a_oposicion(oposicion, titulo, descripcion, preguntas)
--       Valida el JSON, crea el test, lo enlaza a la oposición y deja al
--       usuario como autor, todo en una única transacción (si algo falla
--       no queda nada a medias). Rechaza títulos repetidos dentro de la
--       misma oposición para que reintentar una subida no duplique.
--
--   • listar_tests_de_oposicion(oposicion)
--       Tests de una oposición con id, título, descripción, nº de
--       preguntas y fecha de creación.
--
-- Para listar las oposiciones se usa la RPC ya existente
-- `listar_oposiciones_admin()` (id, nombre, descripcion, activa, num_tests).
--
-- Permisos: subir exige admin o `test.crear`. Listar los tests de una
-- oposición la ven el staff y los usuarios que la tengan asignada.
--
-- Idempotente.
-- ─────────────────────────────────────────────────────────────────────────
BEGIN;

CREATE OR REPLACE FUNCTION subir_test_a_oposicion(
    p_oposicion_id uuid,
    p_titulo       text,
    p_descripcion  text,
    p_preguntas    jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_titulo    text  := btrim(COALESCE(p_titulo, ''));
    v_preguntas jsonb := p_preguntas;
    v_preg      jsonb;
    v_opc       jsonb;
    v_idx       int   := 0;
    v_test      uuid;
BEGIN
    IF NOT (es_admin() OR tiene_permiso('test.crear')) THEN
        RAISE EXCEPTION 'no_autorizado';
    END IF;

    IF v_titulo = '' THEN
        RAISE EXCEPTION 'titulo_obligatorio'
            USING HINT = 'Indica el nombre del test.';
    END IF;

    IF p_oposicion_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM oposiciones WHERE id = p_oposicion_id) THEN
        RAISE EXCEPTION 'oposicion_no_encontrada'
            USING HINT = 'Lista las oposiciones con /rpc/listar_oposiciones_admin.';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM   tests t
        JOIN   test_oposiciones tox ON tox.test_id = t.id
        WHERE  tox.oposicion_id = p_oposicion_id
          AND  lower(btrim(t.titulo)) = lower(v_titulo)
    ) THEN
        RAISE EXCEPTION 'test_duplicado'
            USING HINT = 'Ya existe un test con ese nombre en la oposición.';
    END IF;

    -- Se acepta tanto el array de preguntas como el objeto exportado por
    -- `descargar_test` ({titulo, descripcion, preguntas: [...]}).
    IF jsonb_typeof(v_preguntas) = 'object' THEN
        v_preguntas := v_preguntas->'preguntas';
    END IF;
    IF jsonb_typeof(v_preguntas) IS DISTINCT FROM 'array'
       OR jsonb_array_length(v_preguntas) = 0 THEN
        RAISE EXCEPTION 'preguntas_invalidas'
            USING HINT = 'Se espera un array JSON no vacío de preguntas.';
    END IF;

    -- Validación pregunta a pregunta. Dos formatos de opciones:
    --   ["correcta", "otra", ...]                      (la primera es la correcta)
    --   [{"texto": "...", "correcta": true|false}, ...] (al menos una correcta)
    FOR v_preg IN SELECT * FROM jsonb_array_elements(v_preguntas) LOOP
        v_idx := v_idx + 1;

        IF jsonb_typeof(v_preg) <> 'object'
           OR btrim(COALESCE(v_preg->>'pregunta', '')) = '' THEN
            RAISE EXCEPTION 'pregunta_invalida'
                USING DETAIL = format('Pregunta %s: falta el campo "pregunta".', v_idx);
        END IF;

        v_opc := v_preg->'opciones';
        IF jsonb_typeof(v_opc) IS DISTINCT FROM 'array'
           OR jsonb_array_length(v_opc) < 2 THEN
            RAISE EXCEPTION 'pregunta_invalida'
                USING DETAIL = format('Pregunta %s: "opciones" debe ser un array de al menos 2 elementos.', v_idx);
        END IF;

        IF jsonb_typeof(v_opc->0) = 'string' THEN
            IF EXISTS (
                SELECT 1 FROM jsonb_array_elements(v_opc) e
                WHERE jsonb_typeof(e) <> 'string' OR btrim(e #>> '{}') = ''
            ) THEN
                RAISE EXCEPTION 'pregunta_invalida'
                    USING DETAIL = format('Pregunta %s: todas las opciones deben ser textos no vacíos.', v_idx);
            END IF;
        ELSE
            IF EXISTS (
                SELECT 1 FROM jsonb_array_elements(v_opc) e
                WHERE jsonb_typeof(e) <> 'object'
                   OR btrim(COALESCE(e->>'texto', '')) = ''
                   OR jsonb_typeof(e->'correcta') IS DISTINCT FROM 'boolean'
            ) THEN
                RAISE EXCEPTION 'pregunta_invalida'
                    USING DETAIL = format('Pregunta %s: cada opción debe ser {"texto": "...", "correcta": true|false}.', v_idx);
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM jsonb_array_elements(v_opc) e
                WHERE (e->>'correcta')::boolean
            ) THEN
                RAISE EXCEPTION 'pregunta_invalida'
                    USING DETAIL = format('Pregunta %s: ninguna opción está marcada como correcta.', v_idx);
            END IF;
        END IF;
    END LOOP;

    v_test := importar_test_normalizado(
        v_titulo, NULLIF(btrim(COALESCE(p_descripcion, '')), ''), v_preguntas
    );

    UPDATE tests SET autor_id = jwt_usuario_id() WHERE id = v_test;

    INSERT INTO test_oposiciones(test_id, oposicion_id)
    VALUES (v_test, p_oposicion_id)
    ON CONFLICT DO NOTHING;

    RETURN jsonb_build_object(
        'id',            v_test,
        'titulo',        v_titulo,
        'descripcion',   NULLIF(btrim(COALESCE(p_descripcion, '')), ''),
        'oposicion_id',  p_oposicion_id,
        'num_preguntas', jsonb_array_length(v_preguntas)
    );
END $$;


CREATE OR REPLACE FUNCTION listar_tests_de_oposicion(p_oposicion_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM oposiciones WHERE id = p_oposicion_id) THEN
        RAISE EXCEPTION 'oposicion_no_encontrada'
            USING HINT = 'Lista las oposiciones con /rpc/listar_oposiciones_admin.';
    END IF;
    IF NOT puedo_ver_oposicion(p_oposicion_id) THEN
        RAISE EXCEPTION 'no_autorizado';
    END IF;

    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id',            t.id,
            'titulo',        t.titulo,
            'descripcion',   t.descripcion,
            'num_preguntas', (SELECT count(*) FROM test_preguntas tp WHERE tp.test_id = t.id),
            'creado_en',     t.creado_en
        ) ORDER BY t.creado_en DESC, t.titulo)
        FROM   test_oposiciones tox
        JOIN   tests t ON t.id = tox.test_id
        WHERE  tox.oposicion_id = p_oposicion_id
    ), '[]'::jsonb);
END $$;


GRANT EXECUTE ON FUNCTION subir_test_a_oposicion(uuid, text, text, jsonb) TO web_user;
GRANT EXECUTE ON FUNCTION listar_tests_de_oposicion(uuid)                 TO web_user;

COMMIT;

NOTIFY pgrst, 'reload schema';
