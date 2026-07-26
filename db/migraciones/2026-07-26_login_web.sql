-- =============================================================================
-- 2026-07-26 · login_web y compañía
-- =============================================================================
-- La SPA (landing y tests) llama a funciones RPC que nunca se llegaron a
-- migrar al esquema real (`login_web`, `iniciar_sesion`, `registrar_web`,
-- `mi_sesion`, `puede_ver_teoria`, `oposiciones_publicas`,
-- `elegir_mis_oposiciones`). Sin ellas PostgREST responde
-- "Could not find the function public.login_web in the schema cache" y el
-- inicio de sesión desde web falla en seco.
--
-- Este delta añade las funciones respetando el contrato del frontend:
--   login_web  →  jsonb { token, user_id, username, roles, puede_gestionar }
--   mi_sesion  →  jsonb { user_id, username, roles, puede_gestionar }
--
-- Modelo de identidad: se conserva `email` como identificador de acceso
-- (login por email + contraseña) y se añade una columna `username` a la
-- tabla `usuarios` que se pide en el registro. El username sirve como
-- etiqueta pública (avatar, saludo, listados) y también se puede usar en
-- el futuro para login alternativo.
--
-- Idempotente: se puede reejecutar sin efectos secundarios.
-- =============================================================================

BEGIN;

-- ── 1. Columna username en usuarios ────────────────────────────────────────
ALTER TABLE usuarios ADD COLUMN IF NOT EXISTS username citext;

-- Backfill: para usuarios ya existentes toma la parte local del email
-- (antes de la @) y va añadiendo sufijo numérico si hay colisiones.
DO $$
DECLARE
    r        RECORD;
    v_base   text;
    v_try    text;
    v_i      int;
BEGIN
    FOR r IN SELECT id, email FROM usuarios WHERE username IS NULL LOOP
        v_base := regexp_replace(split_part(r.email::text, '@', 1),
                                 '[^a-zA-Z0-9._-]', '', 'g');
        IF v_base IS NULL OR length(v_base) = 0 THEN v_base := 'user'; END IF;
        v_try := v_base;
        v_i   := 0;
        WHILE EXISTS (SELECT 1 FROM usuarios WHERE username = v_try::citext) LOOP
            v_i := v_i + 1;
            v_try := v_base || v_i::text;
        END LOOP;
        UPDATE usuarios SET username = v_try::citext WHERE id = r.id;
    END LOOP;
END $$;

ALTER TABLE usuarios ALTER COLUMN username SET NOT NULL;

DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'usuarios_username_key'
    ) THEN
        ALTER TABLE usuarios ADD CONSTRAINT usuarios_username_key UNIQUE (username);
    END IF;
END $$;


-- ── 2. Helpers ────────────────────────────────────────────────────────────
-- `puede_gestionar` = tiene rol admin o editor. Coincide con el uso del
-- frontend (body.puede-gestionar habilita paneles de admin/edición).
CREATE OR REPLACE FUNCTION _puede_gestionar(p_uid uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT EXISTS (
        SELECT 1 FROM usuario_roles
         WHERE usuario_id = p_uid AND rol_id IN ('admin','editor')
    );
$$;


-- ── 3. iniciar_sesion(email, password) → JWT (12h) ────────────────────────
-- Versión ligera del login para la SPA: sin refresh token, sin TOTP y sin
-- exigir verificación de email (el registro por username marca la cuenta
-- como verificada automáticamente). Devuelve solo el JWT firmado.
CREATE OR REPLACE FUNCTION iniciar_sesion(
    p_email    text,
    p_password text
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user     usuarios%ROWTYPE;
    v_max      int := (SELECT (valor)::text::int FROM config WHERE clave='login_max_fallos');
    v_lock_min int := (SELECT (valor)::text::int FROM config WHERE clave='login_lockout_min');
    v_secret   text := current_setting('app.jwt_secret');
    v_iss      text := trim(both '"' from (SELECT valor::text FROM config WHERE clave='jwt_iss'));
    v_aud      text := trim(both '"' from (SELECT valor::text FROM config WHERE clave='jwt_aud'));
    v_roles    text[];
    v_now      timestamptz := now();
    v_exp      timestamptz := v_now + interval '12 hours';
    v_jti      uuid := gen_random_uuid();
    v_payload  jsonb;
BEGIN
    IF p_email IS NULL OR position('@' in p_email) < 2 THEN
        RAISE EXCEPTION 'credenciales_invalidas';
    END IF;

    SELECT * INTO v_user
      FROM usuarios
     WHERE email = p_email::citext AND borrado_en IS NULL;
    IF NOT FOUND OR NOT v_user.activo THEN
        RAISE EXCEPTION 'credenciales_invalidas';
    END IF;
    IF v_user.bloqueado_hasta IS NOT NULL AND v_user.bloqueado_hasta > now() THEN
        RAISE EXCEPTION 'cuenta_bloqueada';
    END IF;
    IF NOT _verify_password(p_password, v_user.password_hash) THEN
        UPDATE usuarios
           SET intentos_login_fallidos = intentos_login_fallidos + 1,
               bloqueado_hasta = CASE
                   WHEN intentos_login_fallidos + 1 >= COALESCE(v_max, 5)
                        THEN now() + make_interval(mins => COALESCE(v_lock_min, 15))
                   ELSE bloqueado_hasta
               END,
               actualizado_en = now()
         WHERE id = v_user.id;
        RAISE EXCEPTION 'credenciales_invalidas';
    END IF;

    UPDATE usuarios
       SET intentos_login_fallidos = 0,
           bloqueado_hasta         = NULL,
           ultimo_login_en         = now(),
           actualizado_en          = now()
     WHERE id = v_user.id;

    SELECT COALESCE(array_agg(rol_id ORDER BY rol_id), ARRAY[]::text[])
      INTO v_roles FROM usuario_roles WHERE usuario_id = v_user.id;

    v_payload := jsonb_build_object(
        'sub',   v_user.id::text,
        'role',  'web_user',
        'roles', to_jsonb(v_roles),
        'iat',   extract(epoch FROM v_now)::int,
        'exp',   extract(epoch FROM v_exp)::int,
        'jti',   v_jti::text,
        'iss',   v_iss,
        'aud',   v_aud
    );
    RETURN firmar_jwt(v_payload, v_secret);
END $$;


-- ── 4. login_web(email, password) → jsonb ────────────────────────────────
-- Envoltorio para la SPA. Devuelve token + datos mínimos de sesión.
CREATE OR REPLACE FUNCTION login_web(
    p_email    text,
    p_password text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_token text;
    v_user  usuarios%ROWTYPE;
    v_roles text[];
BEGIN
    v_token := iniciar_sesion(p_email, p_password);

    SELECT * INTO v_user FROM usuarios WHERE email = p_email::citext;
    SELECT COALESCE(array_agg(rol_id ORDER BY rol_id), ARRAY[]::text[])
      INTO v_roles FROM usuario_roles WHERE usuario_id = v_user.id;

    RETURN jsonb_build_object(
        'token',           v_token,
        'user_id',         v_user.id,
        'username',        v_user.username,
        'roles',           to_jsonb(v_roles),
        'puede_gestionar', _puede_gestionar(v_user.id)
    );
END $$;


-- ── 5. registrar_web(email, username, password) → jsonb ───────────────────
-- Alta de usuario desde la SPA: registra + inicia sesión en un solo viaje.
-- No exige verificación de email para poder entrar (marca la cuenta como
-- verificada al momento). El `nombre_visible` interno se rellena con el
-- username.
CREATE OR REPLACE FUNCTION registrar_web(
    p_email    text,
    p_username text,
    p_password text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_id     uuid;
    v_uname  text := btrim(COALESCE(p_username, ''));
BEGIN
    IF p_email IS NULL OR position('@' in p_email) < 2 THEN
        RAISE EXCEPTION 'email_invalido';
    END IF;
    IF length(v_uname) < 3 THEN
        RAISE EXCEPTION 'username_invalido';
    END IF;
    IF v_uname !~ '^[A-Za-z0-9._-]+$' THEN
        RAISE EXCEPTION 'username_caracteres_invalidos';
    END IF;
    PERFORM _validar_password(p_password);

    IF EXISTS (SELECT 1 FROM usuarios WHERE username = v_uname::citext) THEN
        RAISE EXCEPTION 'username_en_uso';
    END IF;
    IF EXISTS (SELECT 1 FROM usuarios WHERE email = p_email::citext) THEN
        RAISE EXCEPTION 'email_en_uso';
    END IF;

    INSERT INTO usuarios (email, username, nombre_visible, password_hash,
                          email_verificado_en)
    VALUES (p_email::citext, v_uname::citext, v_uname,
            _hash_password(p_password), now())
    RETURNING id INTO v_id;

    -- Roles por defecto: tests + teoria.
    INSERT INTO usuario_roles (usuario_id, rol_id) VALUES
        (v_id, 'tests'), (v_id, 'teoria')
    ON CONFLICT DO NOTHING;

    RETURN login_web(p_email, p_password);
END $$;


-- ── 6. mi_sesion() → jsonb ────────────────────────────────────────────────
-- Datos del usuario del JWT actual. Lo llama la landing tras leer la
-- cookie y también tests/app.js cuando entra sin `user` en localStorage.
CREATE OR REPLACE FUNCTION mi_sesion() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid   uuid := jwt_usuario_id();
    v_user  usuarios%ROWTYPE;
    v_roles text[];
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    SELECT * INTO v_user FROM usuarios WHERE id = v_uid AND borrado_en IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    SELECT COALESCE(array_agg(rol_id ORDER BY rol_id), ARRAY[]::text[])
      INTO v_roles FROM usuario_roles WHERE usuario_id = v_uid;
    RETURN jsonb_build_object(
        'user_id',         v_user.id,
        'username',        v_user.username,
        'email',           v_user.email,
        'roles',           to_jsonb(v_roles),
        'puede_gestionar', _puede_gestionar(v_uid)
    );
END $$;


-- ── 7. puede_ver_teoria() → boolean ───────────────────────────────────────
CREATE OR REPLACE FUNCTION puede_ver_teoria() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT es_admin() OR tiene_permiso('teoria.acceder');
$$;


-- ── 8. oposiciones_publicas() → jsonb ─────────────────────────────────────
-- Catálogo público de oposiciones activas para el onboarding.
CREATE OR REPLACE FUNCTION oposiciones_publicas() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id',          o.id,
        'nombre',      o.nombre,
        'descripcion', o.descripcion
    ) ORDER BY o.nombre), '[]'::jsonb)
      FROM oposiciones o
     WHERE o.activa;
$$;


-- ── 9. elegir_mis_oposiciones(uuid[]) → void ──────────────────────────────
-- Vincula al usuario del JWT con las oposiciones indicadas (sustituye el
-- conjunto anterior). Máx 3 salvo que sea admin.
CREATE OR REPLACE FUNCTION elegir_mis_oposiciones(p_oposicion_ids uuid[])
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    IF p_oposicion_ids IS NULL THEN p_oposicion_ids := ARRAY[]::uuid[]; END IF;
    IF NOT es_admin() AND array_length(p_oposicion_ids, 1) > 3 THEN
        RAISE EXCEPTION 'demasiadas_oposiciones';
    END IF;
    -- Verifica que todas existan y estén activas.
    IF EXISTS (
        SELECT 1 FROM unnest(p_oposicion_ids) AS x(id)
        WHERE NOT EXISTS (SELECT 1 FROM oposiciones o WHERE o.id = x.id AND o.activa)
    ) THEN
        RAISE EXCEPTION 'oposicion_no_valida';
    END IF;

    DELETE FROM usuario_oposiciones WHERE usuario_id = v_uid;
    INSERT INTO usuario_oposiciones (usuario_id, oposicion_id)
    SELECT v_uid, x FROM unnest(p_oposicion_ids) AS x
    ON CONFLICT DO NOTHING;
END $$;


-- ── 10. GRANTs ────────────────────────────────────────────────────────────
GRANT EXECUTE ON FUNCTION iniciar_sesion(text,text)              TO web_anon;
GRANT EXECUTE ON FUNCTION login_web(text,text)                   TO web_anon;
GRANT EXECUTE ON FUNCTION registrar_web(text,text,text)          TO web_anon;
GRANT EXECUTE ON FUNCTION mi_sesion()                            TO web_user;
GRANT EXECUTE ON FUNCTION puede_ver_teoria()                     TO web_user;
GRANT EXECUTE ON FUNCTION oposiciones_publicas()                 TO web_user, web_anon;
GRANT EXECUTE ON FUNCTION elegir_mis_oposiciones(uuid[])         TO web_user;

COMMIT;

-- Recarga el esquema de PostgREST sin reiniciar el contenedor.
NOTIFY pgrst, 'reload schema';
