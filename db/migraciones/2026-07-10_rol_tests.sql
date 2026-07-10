-- ─────────────────────────────────────────────────────────────────────────
-- Sustituye el rol funcional 'alumno' por 'tests'.
--
-- Motivación: 'alumno' se usaba para "usuario que solo hace tests" pero
-- convivía mal con el rol 'teoria'. La combinación real que queremos
-- es una pareja simétrica: el usuario tiene 'tests' (accede a los tests
-- de la oposición que elija) y/o 'teoria' (accede al material de teoría
-- de la oposición que elija), y en ambos casos sin permisos de edición.
--
-- Esta migración:
--   1) Crea el rol 'tests' con el permiso 'test.realizar'.
--   2) Da 'tests' a todos los usuarios que hoy tienen 'alumno'.
--   3) Elimina el rol 'alumno' del catálogo y de rol_permisos.
--   4) Cambia el registro nuevo (registrarse) para asignar 'tests' por
--      defecto.
--
-- Idempotente: puede ejecutarse varias veces sin efectos duplicados.
-- ─────────────────────────────────────────────────────────────────────────
BEGIN;

-- 1) Nuevo rol funcional 'tests'.
INSERT INTO roles (id, descripcion) VALUES
    ('tests', 'Puede realizar tests de las oposiciones que tenga asignadas')
ON CONFLICT (id) DO UPDATE
    SET descripcion = EXCLUDED.descripcion;

-- 2) Permisos del rol 'tests': solo realizar. Sin crear/editar/borrar.
INSERT INTO rol_permisos (rol_id, permiso_id) VALUES
    ('tests', 'test.realizar')
ON CONFLICT DO NOTHING;

-- 3) Migra usuarios: todos los que tenían 'alumno' pasan a 'tests'.
INSERT INTO usuario_roles (usuario_id, rol_id)
SELECT usuario_id, 'tests'
FROM   usuario_roles
WHERE  rol_id = 'alumno'
ON CONFLICT DO NOTHING;

DELETE FROM usuario_roles WHERE rol_id = 'alumno';
DELETE FROM rol_permisos  WHERE rol_id = 'alumno';
DELETE FROM roles         WHERE id     = 'alumno';

-- 4) El alta por web ya no crea 'alumno': asigna 'tests'.
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
    INSERT INTO usuario_roles(usuario_id, rol_id) VALUES (v_id, 'tests');
    RETURN v_id;
END $$;

COMMIT;

NOTIFY pgrst, 'reload schema';
