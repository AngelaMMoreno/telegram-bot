-- ============================================================================
-- 06_admin.sql
-- Funciones de gestión de usuarios y roles, accesibles solo a admin.
-- ============================================================================

-- ─────────────── One-shot: tests migrados visibles para todos ──────────────
-- Los migrados desde SQLite no tienen autor_id (NULL) ni son públicos, así
-- que solo el admin los veía.  Los marcamos públicos para que cualquier
-- alumno autenticado pueda hacerlos.  Idempotente.

UPDATE tests SET publico = true
WHERE autor_id IS NULL AND publico = false;


-- ─────────────── Listar usuarios y roles ───────────────────────────────────

CREATE OR REPLACE FUNCTION listar_usuarios() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
BEGIN
    IF NOT es_admin() THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    RETURN (
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'id',         u.id,
            'username',   u.username,
            'email',      u.email,
            'chat_id',    u.chat_id,
            'activo',     u.activo,
            'creado_en',  u.creado_en,
            'tiene_pass', u.password_hash IS NOT NULL,
            'roles',      COALESCE(
                (SELECT array_agg(rol_id ORDER BY rol_id)
                 FROM usuario_roles WHERE usuario_id = u.id),
                ARRAY[]::text[]
            )
        ) ORDER BY u.username), '[]'::jsonb)
        FROM usuarios u
    );
END $$;


CREATE OR REPLACE FUNCTION listar_roles() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id',          id,
        'descripcion', descripcion
    ) ORDER BY id), '[]'::jsonb)
    FROM roles;
$$;


-- ─────────────── Asignar / quitar rol ──────────────────────────────────────

CREATE OR REPLACE FUNCTION asignar_rol(p_usuario_id uuid, p_rol_id text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'permiso_denegado'; END IF;
    INSERT INTO usuario_roles(usuario_id, rol_id)
    VALUES (p_usuario_id, p_rol_id)
    ON CONFLICT DO NOTHING;
END $$;

CREATE OR REPLACE FUNCTION quitar_rol(p_usuario_id uuid, p_rol_id text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'permiso_denegado'; END IF;
    -- Evitar quedarse sin ningún admin (último admin no se puede quitar).
    IF p_rol_id = 'admin' AND (
        SELECT count(*) FROM usuario_roles WHERE rol_id = 'admin'
    ) <= 1 THEN
        RAISE EXCEPTION 'no_se_puede_quitar_el_ultimo_admin';
    END IF;
    DELETE FROM usuario_roles
    WHERE usuario_id = p_usuario_id AND rol_id = p_rol_id;
END $$;


-- ─────────────── Resetear contraseña de un usuario ─────────────────────────

CREATE OR REPLACE FUNCTION resetear_contrasena(
    p_usuario_id uuid,
    p_nueva_pass text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'permiso_denegado'; END IF;
    IF length(p_nueva_pass) < 6 THEN
        RAISE EXCEPTION 'contrasena_muy_corta';
    END IF;
    UPDATE usuarios
       SET password_hash = crypt(p_nueva_pass, gen_salt('bf', 12))
     WHERE id = p_usuario_id;
END $$;


-- ─────────────── Activar / desactivar un usuario ───────────────────────────

CREATE OR REPLACE FUNCTION set_usuario_activo(
    p_usuario_id uuid,
    p_activo     boolean
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'permiso_denegado'; END IF;
    UPDATE usuarios SET activo = p_activo WHERE id = p_usuario_id;
END $$;


GRANT EXECUTE ON FUNCTION listar_usuarios()            TO web_user;
GRANT EXECUTE ON FUNCTION listar_roles()               TO web_user;
GRANT EXECUTE ON FUNCTION asignar_rol(uuid,text)       TO web_user;
GRANT EXECUTE ON FUNCTION quitar_rol(uuid,text)        TO web_user;
GRANT EXECUTE ON FUNCTION resetear_contrasena(uuid,text) TO web_user;
GRANT EXECUTE ON FUNCTION set_usuario_activo(uuid,boolean) TO web_user;
