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


-- ─────────────── Concesiones de ejecución ───────────────────────────────────

GRANT EXECUTE ON FUNCTION mi_sesion()                                 TO web_user;
GRANT EXECUTE ON FUNCTION login_web(text,text)                        TO web_anon;
GRANT EXECUTE ON FUNCTION registrar_web(text,text,text,text)          TO web_anon;
GRANT EXECUTE ON FUNCTION mi_progreso()                               TO web_user;
GRANT EXECUTE ON FUNCTION mis_favoritas_ids()                         TO web_user;
GRANT EXECUTE ON FUNCTION listar_tests(boolean,int,int)               TO web_user;
