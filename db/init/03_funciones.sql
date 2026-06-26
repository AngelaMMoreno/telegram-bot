-- ============================================================================
-- 03_funciones.sql
-- Funciones de negocio expuestas a PostgREST como /rpc/<nombre>
-- y políticas RLS que dependen de ellas.
-- ============================================================================

-- ─────────────────────────── Firma JWT (HS256) ──────────────────────────────
-- Implementación pura en SQL sobre pgcrypto, compatible con la verificación
-- por defecto de PostgREST.  No requiere la extensión pgjwt.

CREATE OR REPLACE FUNCTION url_b64(data bytea) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    -- base64 URL-safe sin padding: '+' → '-', '/' → '_', '=' y '\n' fuera.
    SELECT translate(encode(data, 'base64'), E'+/=\n', '-_');
$$;

CREATE OR REPLACE FUNCTION firmar_jwt(payload jsonb, secret text) RETURNS text
LANGUAGE sql AS $$
    WITH partes AS (
        SELECT url_b64(convert_to('{"alg":"HS256","typ":"JWT"}', 'utf8'))
               || '.' ||
               url_b64(convert_to(payload::text, 'utf8')) AS si
    )
    SELECT partes.si || '.' ||
           url_b64(hmac(partes.si::bytea, secret::bytea, 'sha256'))
    FROM partes;
$$;

-- ─────────────────────────── Helpers JWT / RBAC ─────────────────────────────

CREATE OR REPLACE FUNCTION jwt_usuario_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
    SELECT NULLIF(
        current_setting('request.jwt.claims', true)::jsonb->>'sub',
        ''
    )::uuid;
$$;

CREATE OR REPLACE FUNCTION jwt_roles() RETURNS text[]
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        ARRAY(SELECT jsonb_array_elements_text(
            current_setting('request.jwt.claims', true)::jsonb->'roles'
        )),
        ARRAY[]::text[]
    );
$$;

CREATE OR REPLACE FUNCTION tiene_permiso(p text) RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM rol_permisos
        WHERE permiso_id = p AND rol_id = ANY (jwt_roles())
    );
$$;

CREATE OR REPLACE FUNCTION es_admin() RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT 'admin' = ANY (jwt_roles());
$$;

-- ─────────────────────────── Auth ───────────────────────────────────────────

CREATE OR REPLACE FUNCTION registrarse(p_username text, p_password text, p_email text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_id uuid;
BEGIN
    IF length(p_username) < 3 OR length(p_password) < 6 THEN
        RAISE EXCEPTION 'datos_invalidos';
    END IF;
    INSERT INTO usuarios(username, email, password_hash)
    VALUES (p_username, p_email, crypt(p_password, gen_salt('bf', 12)))
    RETURNING id INTO v_id;
    INSERT INTO usuario_roles(usuario_id, rol_id) VALUES (v_id, 'alumno');
    RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION iniciar_sesion(p_username text, p_password text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_usr      usuarios;
    v_roles    text[];
    v_payload  jsonb;
    v_secret   text := current_setting('app.jwt_secret');
BEGIN
    SELECT * INTO v_usr FROM usuarios
      WHERE username = p_username AND activo;
    IF v_usr.password_hash IS NULL
       OR v_usr.password_hash <> crypt(p_password, v_usr.password_hash) THEN
        RAISE EXCEPTION 'credenciales_invalidas';
    END IF;

    SELECT COALESCE(array_agg(rol_id), ARRAY[]::text[])
    INTO v_roles FROM usuario_roles WHERE usuario_id = v_usr.id;

    v_payload := jsonb_build_object(
        'sub',   v_usr.id,
        'role',  'web_user',
        'roles', v_roles,
        'exp',   extract(epoch FROM now() + interval '12 hours')::int
    );
    RETURN firmar_jwt(v_payload, v_secret);
END $$;

-- Genera un código de 6 dígitos para vincular Telegram con una cuenta web.
CREATE OR REPLACE FUNCTION generar_codigo_telegram()
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_cod text;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    v_cod := lpad((floor(random()*1000000))::text, 6, '0');
    INSERT INTO codigos_vinculacion_telegram(codigo, usuario_id, expira_en)
    VALUES (v_cod, v_uid, now() + interval '10 minutes');
    RETURN v_cod;
END $$;

CREATE OR REPLACE FUNCTION canjear_codigo_telegram(p_codigo text, p_chat_id text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_uid uuid;
BEGIN
    DELETE FROM codigos_vinculacion_telegram WHERE expira_en < now();
    SELECT usuario_id INTO v_uid FROM codigos_vinculacion_telegram
      WHERE codigo = p_codigo AND expira_en > now();
    IF v_uid IS NULL THEN RAISE EXCEPTION 'codigo_invalido'; END IF;
    UPDATE usuarios SET chat_id = p_chat_id WHERE id = v_uid;
    DELETE FROM codigos_vinculacion_telegram WHERE codigo = p_codigo;
    RETURN v_uid;
END $$;

-- ─────────────────────────── Importación de tests ───────────────────────────
-- Espera JSON: [{pregunta, opciones:[...], bloque, tema, correcta?}, ...]
-- Las opciones se guardan tal cual en jsonb. Si la pregunta ya existe
-- (mismo hash de enunciado) se reutiliza, no se duplica.

CREATE OR REPLACE FUNCTION importar_test(p_titulo text, p_json jsonb)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_test uuid;
    v_preg jsonb;
    v_pid  uuid;
    v_pos  int := 0;
BEGIN
    IF NOT tiene_permiso('test.crear') THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;

    INSERT INTO tests(titulo, autor_id) VALUES (p_titulo, jwt_usuario_id())
    RETURNING id INTO v_test;

    FOR v_preg IN SELECT * FROM jsonb_array_elements(p_json) LOOP
        INSERT INTO preguntas(enunciado, opciones, bloque, tema_legacy, autor_id)
        VALUES (
            v_preg->>'pregunta',
            v_preg->'opciones',
            NULLIF(v_preg->>'bloque','')::int,
            NULLIF(v_preg->>'tema','')::int,
            jwt_usuario_id()
        )
        ON CONFLICT (hash_contenido) DO UPDATE
            SET enunciado = EXCLUDED.enunciado   -- fuerza RETURNING
        RETURNING id INTO v_pid;

        v_pos := v_pos + 1;
        INSERT INTO test_preguntas(test_id, pregunta_id, posicion)
        VALUES (v_test, v_pid, v_pos);
    END LOOP;

    RETURN v_test;
END $$;

-- ─────────────────────────── Clasificación temática ─────────────────────────

CREATE OR REPLACE FUNCTION reclasificar_pregunta(
    p_id     uuid,
    k        int   DEFAULT 3,
    umbral   real  DEFAULT 0.55
) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_emb vector(384); v_n int;
BEGIN
    SELECT embedding INTO v_emb FROM preguntas WHERE id = p_id;
    IF v_emb IS NULL THEN RETURN 0; END IF;

    DELETE FROM pregunta_temas WHERE pregunta_id = p_id AND automatico;

    WITH candidatos AS (
        SELECT t.id, 1 - (t.embedding <=> v_emb) AS score
        FROM temas t
        WHERE t.embedding IS NOT NULL
        ORDER BY t.embedding <=> v_emb
        LIMIT k
    )
    INSERT INTO pregunta_temas(pregunta_id, tema_id, score, automatico)
    SELECT p_id, id, score, true FROM candidatos WHERE score > umbral;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION generar_test_tematico(p_tema uuid, p_n int DEFAULT 20)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_test uuid;
BEGIN
    IF jwt_usuario_id() IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;

    INSERT INTO tests(titulo, tipo, autor_id)
    VALUES (
        'Tema: ' || (SELECT nombre FROM temas WHERE id = p_tema),
        'tematico',
        jwt_usuario_id()
    )
    RETURNING id INTO v_test;

    INSERT INTO test_preguntas(test_id, pregunta_id, posicion)
    SELECT v_test, pregunta_id,
           row_number() OVER (ORDER BY random())
    FROM pregunta_temas
    WHERE tema_id = p_tema
    ORDER BY score DESC
    LIMIT p_n;

    RETURN v_test;
END $$;

CREATE OR REPLACE FUNCTION buscar_preguntas(
    p_q   text,
    p_lim int DEFAULT 20
) RETURNS TABLE (id uuid, enunciado text, score real)
LANGUAGE sql STABLE AS $$
    SELECT id, enunciado, similarity(enunciado, p_q) AS score
    FROM preguntas
    WHERE enunciado %> p_q
    ORDER BY similarity(enunciado, p_q) DESC
    LIMIT p_lim;
$$;

-- ─────────────────────────── Políticas RLS ──────────────────────────────────

-- Usuarios: cada uno se ve a sí mismo; el admin a todos.
CREATE POLICY usr_self ON usuarios
    FOR SELECT USING (id = jwt_usuario_id() OR es_admin());
CREATE POLICY usr_admin_all ON usuarios
    FOR ALL TO web_user USING (es_admin()) WITH CHECK (es_admin());

-- Preguntas y tests: lectura libre para autenticados; escritura por permiso.
CREATE POLICY preg_lectura ON preguntas FOR SELECT USING (jwt_usuario_id() IS NOT NULL);
CREATE POLICY preg_insert  ON preguntas FOR INSERT WITH CHECK (tiene_permiso('pregunta.crear'));
CREATE POLICY preg_update  ON preguntas FOR UPDATE USING  (tiene_permiso('pregunta.editar'));
CREATE POLICY preg_delete  ON preguntas FOR DELETE USING  (tiene_permiso('pregunta.borrar'));

CREATE POLICY test_lectura ON tests FOR SELECT
    USING (publico OR autor_id = jwt_usuario_id() OR es_admin());
CREATE POLICY test_insert  ON tests FOR INSERT WITH CHECK (tiene_permiso('test.crear'));
CREATE POLICY test_update  ON tests FOR UPDATE USING  (tiene_permiso('test.editar') OR autor_id = jwt_usuario_id());
CREATE POLICY test_delete  ON tests FOR DELETE USING  (tiene_permiso('test.borrar') OR autor_id = jwt_usuario_id());

CREATE POLICY tp_lectura ON test_preguntas FOR SELECT USING (jwt_usuario_id() IS NOT NULL);
CREATE POLICY tp_escritura ON test_preguntas FOR ALL
    USING (tiene_permiso('test.editar')) WITH CHECK (tiene_permiso('test.editar'));

CREATE POLICY temas_lectura ON temas FOR SELECT USING (true);
CREATE POLICY temas_escritura ON temas FOR ALL
    USING (tiene_permiso('tema.gestionar')) WITH CHECK (tiene_permiso('tema.gestionar'));

CREATE POLICY pt_lectura ON pregunta_temas FOR SELECT USING (true);
CREATE POLICY pt_escritura ON pregunta_temas FOR ALL
    USING (tiene_permiso('tema.gestionar')) WITH CHECK (tiene_permiso('tema.gestionar'));

-- Intentos, respuestas, marcadores: cada usuario solo lo suyo (admin todo).
CREATE POLICY mis_intentos ON intentos
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id() OR es_admin());

CREATE POLICY mis_respuestas ON respuestas
    USING (EXISTS (SELECT 1 FROM intentos i
                   WHERE i.id = respuestas.intento_id
                     AND (i.usuario_id = jwt_usuario_id() OR es_admin())))
    WITH CHECK (EXISTS (SELECT 1 FROM intentos i
                        WHERE i.id = respuestas.intento_id
                          AND i.usuario_id = jwt_usuario_id()));

CREATE POLICY mis_marcadores ON marcadores
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());

-- Exponer las RPCs a usuarios autenticados y anónimos donde corresponde.
GRANT EXECUTE ON FUNCTION registrarse(text,text,text)     TO web_anon;
GRANT EXECUTE ON FUNCTION iniciar_sesion(text,text)       TO web_anon;
GRANT EXECUTE ON FUNCTION canjear_codigo_telegram(text,text) TO web_anon, web_user;
GRANT EXECUTE ON FUNCTION generar_codigo_telegram()       TO web_user;
GRANT EXECUTE ON FUNCTION importar_test(text,jsonb)       TO web_user;
GRANT EXECUTE ON FUNCTION reclasificar_pregunta(uuid,int,real) TO web_user;
GRANT EXECUTE ON FUNCTION generar_test_tematico(uuid,int) TO web_user;
GRANT EXECUTE ON FUNCTION buscar_preguntas(text,int)      TO web_user;
