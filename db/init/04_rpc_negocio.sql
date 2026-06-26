-- ============================================================================
-- 04_rpc_negocio.sql
-- RPCs que la SPA llama directamente vía PostgREST.  Devuelven jsonb con la
-- forma que el frontend espera (compat con la versión SQLite previa).
-- ============================================================================

-- ─────────────── DEFAULTs que evitan al cliente conocer su user_id ──────────
-- Los inserts en estas tablas no necesitan llevar usuario_id: lo coge del JWT.

ALTER TABLE intentos    ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE marcadores  ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE preguntas   ALTER COLUMN autor_id   SET DEFAULT jwt_usuario_id();
ALTER TABLE tests       ALTER COLUMN autor_id   SET DEFAULT jwt_usuario_id();


-- ─────────────── Sesión / perfil ────────────────────────────────────────────

-- Devuelve la info de sesión del usuario autenticado.  Forma compatible con
-- el frontend antiguo: {user_id, username, puede_gestionar}.
CREATE OR REPLACE FUNCTION mi_sesion() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'user_id',          u.id,
        'username',         u.username,
        'roles',            jwt_roles(),
        'puede_gestionar',  tiene_permiso('test.crear')
                             OR tiene_permiso('pregunta.crear')
                             OR es_admin()
    )
    FROM usuarios u
    WHERE u.id = jwt_usuario_id();
$$;


-- ─────────────── Registro + login en un único viaje ─────────────────────────
-- El frontend antiguo recibía {user_id, username, puede_gestionar} y un cookie
-- de sesión.  Ahora devolvemos {token, user_id, username, puede_gestionar}.

CREATE OR REPLACE FUNCTION login_web(p_username text, p_password text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_token   text;
    v_usuario usuarios;
    v_roles   text[];
BEGIN
    v_token := iniciar_sesion(p_username, p_password);

    SELECT * INTO v_usuario FROM usuarios WHERE username = p_username;
    SELECT COALESCE(array_agg(rol_id), ARRAY[]::text[])
      INTO v_roles FROM usuario_roles WHERE usuario_id = v_usuario.id;

    RETURN jsonb_build_object(
        'token',           v_token,
        'user_id',         v_usuario.id,
        'username',        v_usuario.username,
        'roles',           v_roles,
        'puede_gestionar', ('test.crear' = ANY(
                                SELECT permiso_id FROM rol_permisos
                                WHERE rol_id = ANY(v_roles)
                            ))
                           OR ('admin' = ANY(v_roles))
    );
END $$;

CREATE OR REPLACE FUNCTION registrar_web(p_username text, p_password text,
                                          p_email text DEFAULT NULL,
                                          p_chat_id text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_id uuid;
BEGIN
    v_id := registrarse(p_username, p_password, p_email);
    IF p_chat_id IS NOT NULL AND p_chat_id <> '' THEN
        UPDATE usuarios SET chat_id = p_chat_id WHERE id = v_id;
    END IF;
    RETURN login_web(p_username, p_password);
END $$;


-- ─────────────── Progreso del usuario ───────────────────────────────────────

CREATE OR REPLACE FUNCTION mi_progreso() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'respondidas_hoy', (
            SELECT count(*)
            FROM respuestas r
            JOIN intentos i ON i.id = r.intento_id
            WHERE i.usuario_id = jwt_usuario_id()
              AND r.respondida_en::date = current_date
        ),
        'nota_general', (
            SELECT COALESCE(
                avg(CASE WHEN r.correcta THEN 10 ELSE 0 END),
                0
            )::numeric(5,2)
            FROM respuestas r
            JOIN intentos i ON i.id = r.intento_id
            WHERE i.usuario_id = jwt_usuario_id()
        ),
        'preguntas_falladas', (
            SELECT count(*) FROM marcadores
            WHERE usuario_id = jwt_usuario_id() AND tipo = 'fallo'
        ),
        'preguntas_favoritas', (
            SELECT count(*) FROM marcadores
            WHERE usuario_id = jwt_usuario_id() AND tipo = 'favorita'
        ),
        'total_respondidas', (
            SELECT count(*) FROM respuestas r
            JOIN intentos i ON i.id = r.intento_id
            WHERE i.usuario_id = jwt_usuario_id()
        )
    );
$$;


-- ─────────────── Favoritas ──────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION mis_favoritas_ids() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'question_ids',
        COALESCE(jsonb_agg(pregunta_id), '[]'::jsonb)
    )
    FROM marcadores
    WHERE usuario_id = jwt_usuario_id() AND tipo = 'favorita';
$$;


-- ─────────────── Listado de tests con paginación ────────────────────────────
-- Forma compatible con frontend: {tests:[{id,title,description,...}], page,
-- total_pages}.

CREATE OR REPLACE FUNCTION listar_tests(
    p_solo_favoritos boolean DEFAULT false,
    p_page           int     DEFAULT 1,
    p_size           int     DEFAULT 10
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_offset int := GREATEST(p_page - 1, 0) * p_size;
    v_total  int;
    v_tests  jsonb;
BEGIN
    IF p_solo_favoritos THEN
        SELECT count(*) INTO v_total
        FROM tests t
        WHERE EXISTS (
            SELECT 1 FROM marcadores m
            WHERE m.usuario_id = jwt_usuario_id()
              AND m.tipo = 'test_favorito'
              AND m.test_id = t.id
        );

        SELECT COALESCE(jsonb_agg(row_to_json(x)), '[]'::jsonb) INTO v_tests
        FROM (
            SELECT
                t.id,
                t.titulo       AS title,
                t.descripcion  AS description,
                t.tipo,
                t.publico,
                t.creado_en    AS created_at,
                (SELECT count(*) FROM test_preguntas tp WHERE tp.test_id = t.id) AS num_preguntas,
                true           AS favorito
            FROM tests t
            WHERE EXISTS (
                SELECT 1 FROM marcadores m
                WHERE m.usuario_id = jwt_usuario_id()
                  AND m.tipo = 'test_favorito'
                  AND m.test_id = t.id
            )
            ORDER BY t.creado_en DESC
            LIMIT p_size OFFSET v_offset
        ) x;
    ELSE
        SELECT count(*) INTO v_total
        FROM tests t
        WHERE t.publico OR t.autor_id = jwt_usuario_id() OR es_admin();

        SELECT COALESCE(jsonb_agg(row_to_json(x)), '[]'::jsonb) INTO v_tests
        FROM (
            SELECT
                t.id,
                t.titulo       AS title,
                t.descripcion  AS description,
                t.tipo,
                t.publico,
                t.creado_en    AS created_at,
                (SELECT count(*) FROM test_preguntas tp WHERE tp.test_id = t.id) AS num_preguntas,
                EXISTS (
                    SELECT 1 FROM marcadores m
                    WHERE m.usuario_id = jwt_usuario_id()
                      AND m.tipo = 'test_favorito'
                      AND m.test_id = t.id
                ) AS favorito
            FROM tests t
            WHERE t.publico OR t.autor_id = jwt_usuario_id() OR es_admin()
            ORDER BY t.creado_en DESC
            LIMIT p_size OFFSET v_offset
        ) x;
    END IF;

    RETURN jsonb_build_object(
        'tests',       v_tests,
        'page',        p_page,
        'page_size',   p_size,
        'total',       v_total,
        'total_pages', GREATEST(1, (v_total + p_size - 1) / p_size)
    );
END $$;


-- ─────────────── Ajustes de tablas para almacenar el orden y texto ─────────
-- Estos ALTER son IF NOT EXISTS / convertibles para que sean idempotentes
-- tanto en DB nueva como en una ya migrada.

ALTER TABLE intentos   ADD COLUMN IF NOT EXISTS question_ids uuid[];
ALTER TABLE respuestas ALTER COLUMN opcion_elegida TYPE text USING opcion_elegida::text;


-- ─────────────── Preguntas de un test (orden + opciones) ───────────────────
-- Devuelve la forma compatible con el frontend antiguo:
--   {quiz: {id, title}, questions: [{id, text, options: [{text, isCorrect}],
--                                    explicacion}]}
-- La convención: opciones[0] siempre es la correcta (heredado de la migración
-- del SQLite).  isCorrect lo deriva el RPC y lo expone por opción.

CREATE OR REPLACE FUNCTION obtener_preguntas_test(p_test_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'quiz', jsonb_build_object(
            'id',    t.id,
            'title', t.titulo
        ),
        'questions', COALESCE(jsonb_agg(
            jsonb_build_object(
                'id',          p.id,
                'text',        p.enunciado,
                'options',     (
                    SELECT jsonb_agg(jsonb_build_object(
                        'text', o.opt->>'texto',
                        'isCorrect', COALESCE((o.opt->>'correcta')::boolean,
                                              o.idx = 1)
                    ) ORDER BY o.idx)
                    FROM jsonb_array_elements(p.opciones) WITH ORDINALITY o(opt, idx)
                ),
                'explicacion', p.explicacion,
                'etiquetas',   p.etiquetas
            ) ORDER BY tp.posicion
        ), '[]'::jsonb)
    )
    FROM tests t
    LEFT JOIN test_preguntas tp ON tp.test_id = t.id
    LEFT JOIN preguntas p ON p.id = tp.pregunta_id
    WHERE t.id = p_test_id
    GROUP BY t.id, t.titulo;
$$;


-- ─────────────── Intentos ──────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION iniciar_intento(
    p_test_id      uuid    DEFAULT NULL,
    p_tipo         text    DEFAULT 'quiz',
    p_nombre       text    DEFAULT NULL,
    p_question_ids uuid[]  DEFAULT '{}'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
    INSERT INTO intentos(test_id, tipo, nombre, question_ids)
    VALUES (p_test_id, p_tipo, p_nombre, p_question_ids)
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('attempt_id', v_id);
END $$;

-- Registra la respuesta y, si es incorrecta, actualiza el marcador 'fallo'.
CREATE OR REPLACE FUNCTION registrar_respuesta(
    p_intento_id  uuid,
    p_pregunta_id uuid,
    p_texto       text,
    p_correcta    boolean
) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO respuestas(intento_id, pregunta_id, opcion_elegida, correcta)
    VALUES (p_intento_id, p_pregunta_id, p_texto, p_correcta);

    IF NOT p_correcta THEN
        INSERT INTO marcadores(usuario_id, tipo, pregunta_id, contador, actualizado_en)
        VALUES (jwt_usuario_id(), 'fallo', p_pregunta_id, 1, now())
        ON CONFLICT (usuario_id, tipo, COALESCE(pregunta_id, test_id))
        DO UPDATE SET contador = marcadores.contador + 1,
                       actualizado_en = now();
    END IF;
END $$;

CREATE OR REPLACE FUNCTION finalizar_intento(p_intento_id uuid)
RETURNS void
LANGUAGE sql AS $$
    UPDATE intentos SET finalizado_en = now() WHERE id = p_intento_id;
$$;

CREATE OR REPLACE FUNCTION descartar_intento(p_intento_id uuid)
RETURNS void
LANGUAGE sql AS $$
    DELETE FROM intentos WHERE id = p_intento_id;
$$;

-- Devuelve el intento pendiente más reciente (o null) para combo (tipo, test).
CREATE OR REPLACE FUNCTION intento_pendiente(
    p_tipo    text,
    p_test_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'attempt', (
            SELECT to_jsonb(x)
            FROM (
                SELECT i.id, i.nombre, i.test_id AS quiz_id, i.tipo AS attempt_type,
                       i.iniciado_en
                FROM intentos i
                WHERE i.usuario_id = jwt_usuario_id()
                  AND i.finalizado_en IS NULL
                  AND i.tipo = p_tipo
                  AND (p_test_id IS NULL OR i.test_id = p_test_id)
                ORDER BY i.iniciado_en DESC
                LIMIT 1
            ) x
        )
    );
$$;

-- Reanuda un intento: devuelve las preguntas pendientes (las que aún no se
-- han respondido) y el progreso parcial.
CREATE OR REPLACE FUNCTION reanudar_intento(p_intento_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_int  intentos;
    v_resp jsonb;
    v_pend jsonb;
    v_corr int;
    v_wrong int;
BEGIN
    SELECT * INTO v_int FROM intentos WHERE id = p_intento_id;
    IF v_int.id IS NULL OR v_int.usuario_id <> jwt_usuario_id() THEN
        RAISE EXCEPTION 'intento_invalido';
    END IF;

    SELECT count(*) FILTER (WHERE correcta),
           count(*) FILTER (WHERE NOT correcta)
      INTO v_corr, v_wrong
      FROM respuestas WHERE intento_id = p_intento_id;

    -- Preguntas pendientes: las del question_ids[] menos las ya respondidas,
    -- preservando el orden original.
    WITH respondidas AS (
        SELECT pregunta_id FROM respuestas WHERE intento_id = p_intento_id
    ),
    pendientes_ord AS (
        SELECT qid, ord
        FROM unnest(v_int.question_ids) WITH ORDINALITY AS u(qid, ord)
        WHERE qid NOT IN (SELECT pregunta_id FROM respondidas)
        ORDER BY ord
    )
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id',          p.id,
            'text',        p.enunciado,
            'options',     (
                SELECT jsonb_agg(jsonb_build_object(
                    'text', o.opt->>'texto',
                    'isCorrect', COALESCE((o.opt->>'correcta')::boolean, o.idx = 1)
                ) ORDER BY o.idx)
                FROM jsonb_array_elements(p.opciones) WITH ORDINALITY o(opt, idx)
            ),
            'explicacion', p.explicacion,
            'etiquetas',   p.etiquetas
        ) ORDER BY po.ord
    ), '[]'::jsonb)
    INTO v_pend
    FROM pendientes_ord po
    JOIN preguntas p ON p.id = po.qid;

    RETURN jsonb_build_object(
        'attempt_id',     v_int.id,
        'attempt_type',   v_int.tipo,
        'quiz_id',        v_int.test_id,
        'nombre',         v_int.nombre,
        'questions',      v_pend,
        'correct',        v_corr,
        'wrong',          v_wrong,
        'respondidas',    v_corr + v_wrong,
        'total_original', COALESCE(array_length(v_int.question_ids, 1), 0)
    );
END $$;


-- ─────────────── Marcadores (favoritas + tests favoritos) ──────────────────

CREATE OR REPLACE FUNCTION toggle_favorita_pregunta(p_pregunta_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_existe boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM marcadores
        WHERE usuario_id = jwt_usuario_id()
          AND tipo = 'favorita'
          AND pregunta_id = p_pregunta_id
    ) INTO v_existe;

    IF v_existe THEN
        DELETE FROM marcadores
        WHERE usuario_id = jwt_usuario_id()
          AND tipo = 'favorita'
          AND pregunta_id = p_pregunta_id;
        RETURN jsonb_build_object('favorito', false);
    ELSE
        INSERT INTO marcadores(usuario_id, tipo, pregunta_id)
        VALUES (jwt_usuario_id(), 'favorita', p_pregunta_id);
        RETURN jsonb_build_object('favorito', true);
    END IF;
END $$;

CREATE OR REPLACE FUNCTION toggle_favorita_test(p_test_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_existe boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM marcadores
        WHERE usuario_id = jwt_usuario_id()
          AND tipo = 'test_favorito'
          AND test_id = p_test_id
    ) INTO v_existe;

    IF v_existe THEN
        DELETE FROM marcadores
        WHERE usuario_id = jwt_usuario_id()
          AND tipo = 'test_favorito'
          AND test_id = p_test_id;
        RETURN jsonb_build_object('favorito', false);
    ELSE
        INSERT INTO marcadores(usuario_id, tipo, test_id)
        VALUES (jwt_usuario_id(), 'test_favorito', p_test_id);
        RETURN jsonb_build_object('favorito', true);
    END IF;
END $$;


-- ─────────────── Listas de preguntas falladas / favoritas ───────────────────

CREATE OR REPLACE FUNCTION mis_fallos() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'questions', COALESCE(jsonb_agg(
            jsonb_build_object(
                'id', p.id,
                'text', p.enunciado,
                'options', (
                    SELECT jsonb_agg(jsonb_build_object(
                        'text', o.opt->>'texto',
                        'isCorrect', COALESCE((o.opt->>'correcta')::boolean, o.idx = 1)
                    ) ORDER BY o.idx)
                    FROM jsonb_array_elements(p.opciones) WITH ORDINALITY o(opt, idx)
                ),
                'explicacion', p.explicacion,
                'etiquetas',   p.etiquetas,
                'veces_fallada', m.contador
            ) ORDER BY m.actualizado_en DESC
        ), '[]'::jsonb)
    )
    FROM marcadores m
    JOIN preguntas p ON p.id = m.pregunta_id
    WHERE m.usuario_id = jwt_usuario_id() AND m.tipo = 'fallo';
$$;

CREATE OR REPLACE FUNCTION mis_favoritas() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'questions', COALESCE(jsonb_agg(
            jsonb_build_object(
                'id', p.id,
                'text', p.enunciado,
                'options', (
                    SELECT jsonb_agg(jsonb_build_object(
                        'text', o.opt->>'texto',
                        'isCorrect', COALESCE((o.opt->>'correcta')::boolean, o.idx = 1)
                    ) ORDER BY o.idx)
                    FROM jsonb_array_elements(p.opciones) WITH ORDINALITY o(opt, idx)
                ),
                'explicacion', p.explicacion,
                'etiquetas',   p.etiquetas
            ) ORDER BY m.actualizado_en DESC
        ), '[]'::jsonb)
    )
    FROM marcadores m
    JOIN preguntas p ON p.id = m.pregunta_id
    WHERE m.usuario_id = jwt_usuario_id() AND m.tipo = 'favorita';
$$;

-- Visor agrupado por test (para la pantalla "Ver favoritas").  Devuelve
-- {questions:[{...,quiz_title}]} con quiz_title = primer test en el que
-- aparece la pregunta (si está en varios).
CREATE OR REPLACE FUNCTION mis_favoritas_agrupadas() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'questions', COALESCE(jsonb_agg(
            jsonb_build_object(
                'id', p.id,
                'text', p.enunciado,
                'options', (
                    SELECT jsonb_agg(jsonb_build_object(
                        'text', o.opt->>'texto',
                        'isCorrect', COALESCE((o.opt->>'correcta')::boolean, o.idx = 1)
                    ) ORDER BY o.idx)
                    FROM jsonb_array_elements(p.opciones) WITH ORDINALITY o(opt, idx)
                ),
                'explicacion', p.explicacion,
                'quiz_title',  COALESCE((
                    SELECT t.titulo FROM test_preguntas tp
                    JOIN tests t ON t.id = tp.test_id
                    WHERE tp.pregunta_id = p.id
                    ORDER BY t.creado_en LIMIT 1
                ), '(sin test)')
            ) ORDER BY 1
        ), '[]'::jsonb)
    )
    FROM marcadores m
    JOIN preguntas p ON p.id = m.pregunta_id
    WHERE m.usuario_id = jwt_usuario_id() AND m.tipo = 'favorita';
$$;


-- ─────────────── Concesiones de ejecución ───────────────────────────────────

GRANT EXECUTE ON FUNCTION mi_sesion()                                 TO web_user;
GRANT EXECUTE ON FUNCTION login_web(text,text)                        TO web_anon;
GRANT EXECUTE ON FUNCTION registrar_web(text,text,text,text)          TO web_anon;
GRANT EXECUTE ON FUNCTION mi_progreso()                               TO web_user;
GRANT EXECUTE ON FUNCTION mis_favoritas_ids()                         TO web_user;
GRANT EXECUTE ON FUNCTION listar_tests(boolean,int,int)               TO web_user;
GRANT EXECUTE ON FUNCTION obtener_preguntas_test(uuid)                TO web_user;
GRANT EXECUTE ON FUNCTION iniciar_intento(uuid,text,text,uuid[])      TO web_user;
GRANT EXECUTE ON FUNCTION registrar_respuesta(uuid,uuid,text,boolean) TO web_user;
GRANT EXECUTE ON FUNCTION finalizar_intento(uuid)                     TO web_user;
GRANT EXECUTE ON FUNCTION descartar_intento(uuid)                     TO web_user;
GRANT EXECUTE ON FUNCTION intento_pendiente(text,uuid)                TO web_user;
GRANT EXECUTE ON FUNCTION reanudar_intento(uuid)                      TO web_user;
GRANT EXECUTE ON FUNCTION toggle_favorita_pregunta(uuid)              TO web_user;
GRANT EXECUTE ON FUNCTION toggle_favorita_test(uuid)                  TO web_user;
GRANT EXECUTE ON FUNCTION mis_fallos()                                TO web_user;
GRANT EXECUTE ON FUNCTION mis_favoritas()                             TO web_user;
GRANT EXECUTE ON FUNCTION mis_favoritas_agrupadas()                   TO web_user;


-- ─────────────── Importar JSON ──────────────────────────────────────────────
-- Normaliza el formato viejo de los JSON exportados desde el bot, donde
-- opciones era un array de strings (la primera era la correcta) y los
-- bloque/tema iban como números sueltos.

CREATE OR REPLACE FUNCTION importar_test_normalizado(
    p_titulo      text,
    p_descripcion text,
    p_preguntas   jsonb
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_test uuid;
    v_preg jsonb;
    v_pid  uuid;
    v_pos  int := 0;
    v_opc  jsonb;
    v_etiq text[];
BEGIN
    IF NOT (tiene_permiso('test.crear') OR es_admin()) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;

    INSERT INTO tests(titulo, descripcion) VALUES (p_titulo, p_descripcion)
    RETURNING id INTO v_test;

    FOR v_preg IN SELECT * FROM jsonb_array_elements(p_preguntas) LOOP
        -- Opciones: si es array de strings, las convierto a {texto,correcta}
        -- con la convención antigua "primera = correcta".
        IF jsonb_typeof(v_preg->'opciones'->0) = 'string' THEN
            SELECT jsonb_agg(jsonb_build_object(
                       'texto', t,
                       'correcta', i = 1
                   ) ORDER BY i)
              INTO v_opc
              FROM jsonb_array_elements_text(v_preg->'opciones')
                   WITH ORDINALITY AS x(t, i);
        ELSE
            v_opc := v_preg->'opciones';
        END IF;

        v_etiq := COALESCE(
            ARRAY(SELECT jsonb_array_elements_text(v_preg->'etiquetas')),
            ARRAY[]::text[]
        );

        INSERT INTO preguntas(enunciado, opciones, explicacion, etiquetas)
        VALUES (
            v_preg->>'pregunta',
            v_opc,
            NULLIF(v_preg->>'explicacion',''),
            v_etiq
        )
        ON CONFLICT (hash_contenido) DO UPDATE
            SET enunciado = EXCLUDED.enunciado
        RETURNING id INTO v_pid;

        v_pos := v_pos + 1;
        INSERT INTO test_preguntas(test_id, pregunta_id, posicion)
        VALUES (v_test, v_pid, v_pos);
    END LOOP;

    RETURN v_test;
END $$;


-- ─────────────── Descargar tests como JSON ──────────────────────────────────

CREATE OR REPLACE FUNCTION descargar_test(p_test_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'titulo',      t.titulo,
        'descripcion', t.descripcion,
        'preguntas',   (
            SELECT jsonb_agg(jsonb_build_object(
                'pregunta',    p.enunciado,
                'opciones',    p.opciones,
                'explicacion', p.explicacion,
                'etiquetas',   p.etiquetas
            ) ORDER BY tp.posicion)
            FROM test_preguntas tp
            JOIN preguntas p ON p.id = tp.pregunta_id
            WHERE tp.test_id = t.id
        )
    )
    FROM tests t WHERE t.id = p_test_id;
$$;

CREATE OR REPLACE FUNCTION descargar_todos_los_tests()
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(descargar_test(id) ORDER BY creado_en), '[]'::jsonb)
    FROM tests
    WHERE autor_id = jwt_usuario_id() OR publico OR es_admin();
$$;


-- ─────────────── Mega test ─────────────────────────────────────────────────
-- Devuelve hasta N preguntas extraídas al azar de los tests indicados.

CREATE OR REPLACE FUNCTION preguntas_de_tests(p_test_ids uuid[])
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'questions', COALESCE(jsonb_agg(jsonb_build_object(
            'id',          p.id,
            'text',        p.enunciado,
            'options',     (
                SELECT jsonb_agg(jsonb_build_object(
                    'text', o.opt->>'texto',
                    'isCorrect', COALESCE((o.opt->>'correcta')::boolean, o.idx = 1)
                ) ORDER BY o.idx)
                FROM jsonb_array_elements(p.opciones) WITH ORDINALITY o(opt, idx)
            ),
            'explicacion', p.explicacion,
            'etiquetas',   p.etiquetas,
            'quiz_title',  (
                SELECT t.titulo FROM test_preguntas tp2
                JOIN tests t ON t.id = tp2.test_id
                WHERE tp2.pregunta_id = p.id
                ORDER BY t.creado_en LIMIT 1
            )
        )), '[]'::jsonb)
    )
    FROM (
        SELECT DISTINCT tp.pregunta_id FROM test_preguntas tp
        WHERE tp.test_id = ANY(p_test_ids)
    ) ids
    JOIN preguntas p ON p.id = ids.pregunta_id;
$$;

CREATE OR REPLACE FUNCTION crear_mega_test(
    p_titulo    text,
    p_test_ids  uuid[]
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_test uuid;
    v_pos int := 0;
    v_qid uuid;
BEGIN
    IF NOT (tiene_permiso('test.crear') OR es_admin()) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;

    INSERT INTO tests(titulo, tipo) VALUES (p_titulo, 'mega')
    RETURNING id INTO v_test;

    FOR v_qid IN
        SELECT DISTINCT tp.pregunta_id FROM test_preguntas tp
        WHERE tp.test_id = ANY(p_test_ids)
        ORDER BY tp.pregunta_id
    LOOP
        v_pos := v_pos + 1;
        INSERT INTO test_preguntas(test_id, pregunta_id, posicion)
        VALUES (v_test, v_qid, v_pos);
    END LOOP;

    RETURN v_test;
END $$;


-- ─────────────── Progreso detallado (con desglose por test) ────────────────

CREATE OR REPLACE FUNCTION mi_progreso_detallado() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    WITH base AS (
        SELECT mi_progreso() AS p
    ),
    intentos_q AS (
        SELECT i.test_id, i.id AS attempt_id, i.iniciado_en,
               count(*) FILTER (WHERE r.correcta)     AS correct,
               count(*) FILTER (WHERE NOT r.correcta) AS wrong
        FROM intentos i
        LEFT JOIN respuestas r ON r.intento_id = i.id
        WHERE i.usuario_id = jwt_usuario_id()
          AND i.tipo = 'quiz'
          AND i.finalizado_en IS NOT NULL
        GROUP BY i.id
    ),
    por_test AS (
        SELECT iq.test_id AS quiz_id,
               t.titulo AS titulo,
               jsonb_agg(jsonb_build_object(
                   'correct', iq.correct,
                   'wrong',   iq.wrong,
                   'nota',    CASE WHEN (iq.correct+iq.wrong) = 0 THEN 0
                                    ELSE GREATEST(
                                        ((iq.correct - (1.0/3)*iq.wrong) / (iq.correct+iq.wrong)) * 10,
                                        0
                                    )
                              END
               ) ORDER BY iq.iniciado_en) AS intentos
        FROM intentos_q iq
        JOIN tests t ON t.id = iq.test_id
        GROUP BY iq.test_id, t.titulo
    )
    SELECT (
        SELECT p FROM base
    ) || jsonb_build_object(
        'por_test', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'quiz_id', quiz_id,
            'titulo',  titulo,
            'intentos', intentos
        )) FROM por_test), '[]'::jsonb)
    );
$$;


-- ─────────────── Simulacros ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION listar_simulacros() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'simulacros', COALESCE(jsonb_agg(jsonb_build_object(
            'id',                 t.id,
            'nombre',             t.titulo,
            'quiz_id',            t.id,
            'nota_corte_directa', t.nota_corte,
            'escala_maxima',      t.escala_maxima,
            'preguntas_total',    (SELECT count(*) FROM test_preguntas WHERE test_id = t.id)
        ) ORDER BY t.creado_en DESC), '[]'::jsonb)
    )
    FROM tests t WHERE t.tipo = 'simulacro';
$$;

GRANT EXECUTE ON FUNCTION importar_test_normalizado(text,text,jsonb)  TO web_user;
GRANT EXECUTE ON FUNCTION descargar_test(uuid)                        TO web_user;
GRANT EXECUTE ON FUNCTION descargar_todos_los_tests()                 TO web_user;
GRANT EXECUTE ON FUNCTION preguntas_de_tests(uuid[])                  TO web_user;
GRANT EXECUTE ON FUNCTION crear_mega_test(text,uuid[])                TO web_user;
GRANT EXECUTE ON FUNCTION mi_progreso_detallado()                     TO web_user;
GRANT EXECUTE ON FUNCTION listar_simulacros()                         TO web_user;


CREATE OR REPLACE FUNCTION crear_simulacro(
    p_titulo            text,
    p_test_id           uuid,
    p_nota_corte        numeric,
    p_escala_maxima     numeric
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
    IF NOT (tiene_permiso('test.crear') OR es_admin()) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    -- Marca el test indicado como simulacro y guarda nota_corte/escala_maxima.
    UPDATE tests
       SET tipo = 'simulacro',
           titulo = COALESCE(NULLIF(p_titulo,''), titulo),
           nota_corte = p_nota_corte,
           escala_maxima = p_escala_maxima
     WHERE id = p_test_id
     RETURNING id INTO v_id;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'test_no_encontrado';
    END IF;
    RETURN v_id;
END $$;

GRANT EXECUTE ON FUNCTION crear_simulacro(text,uuid,numeric,numeric)   TO web_user;


-- ─────────────── Configuración (histórico simulacro, plazas…) ──────────────
-- Pares (puntuación directa, posición) ordenados desc por puntuación.
-- Se rellenan a mano desde pgAdmin o mediante una migración inicial.

CREATE TABLE IF NOT EXISTS config (
    clave text PRIMARY KEY,
    valor jsonb
);
ALTER TABLE config ENABLE ROW LEVEL SECURITY;
CREATE POLICY config_lectura  ON config FOR SELECT USING (true);
CREATE POLICY config_admin    ON config FOR ALL TO web_user
    USING (es_admin()) WITH CHECK (es_admin());
GRANT SELECT ON config TO web_user, web_anon;
GRANT INSERT, UPDATE, DELETE ON config TO web_user;

INSERT INTO config(clave, valor) VALUES
    ('historico_2024',         '[]'::jsonb),
    ('historico_2022',         '[]'::jsonb),
    ('plazas_referencia',      '844'::jsonb),
    ('penalizacion_fallo',     '0.333333'::jsonb),
    ('puntos_acierto_parte_2', '0.5'::jsonb),
    ('min_directa_simulacro',  '30'::jsonb),
    ('n_max_simulacro',        '90'::jsonb),
    ('e_max_simulacro',        '50'::jsonb)
ON CONFLICT (clave) DO NOTHING;

CREATE OR REPLACE FUNCTION leer_config() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_object_agg(clave, valor), '{}'::jsonb) FROM config;
$$;

GRANT EXECUTE ON FUNCTION leer_config() TO web_user, web_anon;
