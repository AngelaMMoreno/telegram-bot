-- ============================================================================
-- 02_seed.sql
-- Datos iniciales: contraseñas de roles Postgres, RBAC y usuario admin.
-- Los secretos vienen como GUCs inyectados por docker-compose:
--   app.auth_pass   -> rol autenticador (usado por PostgREST)
--   app.admin_pass  -> usuario 'admin' de la aplicación
--   app.jwt_secret  -> firma JWT (lo usa 03_funciones.sql)
-- ============================================================================

-- ── Contraseña del rol autenticador ─────────────────────────────────────────
DO $$
DECLARE v text := current_setting('app.auth_pass', true);
BEGIN
    IF v IS NULL OR length(v) < 4 THEN
        RAISE EXCEPTION 'app.auth_pass no definida o demasiado corta';
    END IF;
    EXECUTE format('ALTER ROLE autenticador WITH PASSWORD %L', v);
END $$;

-- ── Roles base ──────────────────────────────────────────────────────────────
INSERT INTO roles (id, descripcion) VALUES
    ('admin',  'Acceso total al sistema'),
    ('editor', 'Puede crear y editar preguntas, tests y temas'),
    ('alumno', 'Puede realizar tests y consultar su propio progreso')
ON CONFLICT (id) DO NOTHING;

-- ── Permisos ────────────────────────────────────────────────────────────────
INSERT INTO permisos (id, descripcion) VALUES
    ('pregunta.crear',    'Crear preguntas'),
    ('pregunta.editar',   'Editar preguntas existentes'),
    ('pregunta.borrar',   'Eliminar preguntas'),
    ('test.crear',        'Crear tests'),
    ('test.editar',       'Editar tests'),
    ('test.borrar',       'Eliminar tests'),
    ('test.publicar',     'Marcar un test como público'),
    ('tema.gestionar',    'Crear, editar y borrar temas'),
    ('usuario.gestionar', 'Dar de alta usuarios y asignarles roles'),
    ('backup.descargar',  'Descargar copias de seguridad de la base de datos'),
    ('test.realizar',     'Realizar tests y registrar respuestas')
ON CONFLICT (id) DO NOTHING;

-- ── Mapeo rol → permisos ────────────────────────────────────────────────────
INSERT INTO rol_permisos (rol_id, permiso_id)
SELECT 'admin', id FROM permisos
ON CONFLICT DO NOTHING;

INSERT INTO rol_permisos (rol_id, permiso_id) VALUES
    ('editor', 'pregunta.crear'),
    ('editor', 'pregunta.editar'),
    ('editor', 'pregunta.borrar'),
    ('editor', 'test.crear'),
    ('editor', 'test.editar'),
    ('editor', 'test.borrar'),
    ('editor', 'test.publicar'),
    ('editor', 'tema.gestionar'),
    ('editor', 'test.realizar'),
    ('alumno', 'test.realizar')
ON CONFLICT DO NOTHING;

-- ── Usuario administrador maestro ───────────────────────────────────────────
-- La contraseña inicial se toma de la variable de sesión app.admin_pass
-- que el entrypoint configura con: SET app.admin_pass = '$ADMIN_PASS';
DO $$
DECLARE
    v_id    uuid;
    v_pass  text := current_setting('app.admin_pass', true);
BEGIN
    IF v_pass IS NULL OR length(v_pass) < 8 THEN
        RAISE NOTICE 'ADMIN_PASS no definida o demasiado corta; omito creación de admin';
        RETURN;
    END IF;

    INSERT INTO usuarios (username, email, password_hash)
    VALUES ('admin', NULL, crypt(v_pass, gen_salt('bf', 12)))
    ON CONFLICT (username) DO UPDATE
        SET password_hash = EXCLUDED.password_hash
    RETURNING id INTO v_id;

    INSERT INTO usuario_roles (usuario_id, rol_id)
    VALUES (v_id, 'admin')
    ON CONFLICT DO NOTHING;
END $$;
