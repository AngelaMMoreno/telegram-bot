-- ============================================================================
-- Refactor de oposiciones: fuera "perfiles", asignación directa
-- usuarios ↔ oposiciones. Añade bulk assignment de tests a una oposición.
--
-- Idempotente. Si ya se aplicó 2026-07-06_oposiciones_y_perfiles.sql,
-- este delta migra los datos existentes (unión de perfiles) y elimina
-- las tablas/RPCs de perfiles.
--
-- Cómo:
--   pgAdmin → Query Tool → pega esto y F5.
-- ============================================================================

BEGIN;

-- ── 1) Nueva tabla usuario_oposiciones ────────────────────────────────────
CREATE TABLE IF NOT EXISTS usuario_oposiciones (
    usuario_id   uuid NOT NULL REFERENCES usuarios(id)    ON DELETE CASCADE,
    oposicion_id uuid NOT NULL REFERENCES oposiciones(id) ON DELETE CASCADE,
    asignado_en  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (usuario_id, oposicion_id)
);
ALTER TABLE usuario_oposiciones ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS usuario_op_lectura ON usuario_oposiciones;
CREATE POLICY usuario_op_lectura ON usuario_oposiciones
    FOR SELECT TO web_user USING (usuario_id = jwt_usuario_id() OR es_admin());

GRANT SELECT ON usuario_oposiciones TO web_user;

-- ── 2) Migración de datos: usuario_perfiles + perfil_oposiciones → union ─
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables
               WHERE table_name = 'usuario_perfiles') THEN
        INSERT INTO usuario_oposiciones (usuario_id, oposicion_id)
        SELECT DISTINCT up.usuario_id, po.oposicion_id
        FROM usuario_perfiles up
        JOIN perfil_oposiciones po ON po.perfil_id = up.perfil_id
        ON CONFLICT DO NOTHING;
    END IF;
END $$;

-- ── 3) Reescribir RPCs que usaban perfiles ────────────────────────────────

CREATE OR REPLACE FUNCTION mis_oposiciones() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE v_admin boolean := es_admin() OR tiene_permiso('test.crear');
BEGIN
    IF v_admin THEN
        RETURN COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', id, 'nombre', nombre, 'descripcion', descripcion
            ) ORDER BY nombre)
            FROM oposiciones WHERE activa
        ), '[]'::jsonb);
    END IF;
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id', o.id, 'nombre', o.nombre, 'descripcion', o.descripcion
        ) ORDER BY o.nombre)
        FROM usuario_oposiciones uo
        JOIN oposiciones o ON o.id = uo.oposicion_id
        WHERE uo.usuario_id = jwt_usuario_id() AND o.activa
    ), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION mis_oposiciones_ids() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE v_admin boolean := es_admin() OR tiene_permiso('test.crear');
BEGIN
    IF v_admin THEN
        RETURN COALESCE((SELECT jsonb_agg(id) FROM oposiciones WHERE activa), '[]'::jsonb);
    END IF;
    RETURN COALESCE((
        SELECT jsonb_agg(o.id)
        FROM usuario_oposiciones uo
        JOIN oposiciones o ON o.id = uo.oposicion_id
        WHERE uo.usuario_id = jwt_usuario_id() AND o.activa
    ), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION puedo_ver_oposicion(p_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT es_admin() OR tiene_permiso('test.crear') OR EXISTS (
        SELECT 1 FROM usuario_oposiciones
         WHERE usuario_id = jwt_usuario_id() AND oposicion_id = p_id
    );
$$;

-- Ya no hay perfiles: contamos usuarios asignados directamente.
CREATE OR REPLACE FUNCTION listar_oposiciones_admin() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
BEGIN
    IF NOT (es_admin() OR tiene_permiso('test.crear')) THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id',           o.id,
            'nombre',       o.nombre,
            'descripcion',  o.descripcion,
            'activa',       o.activa,
            'num_tests',    (SELECT count(*) FROM test_oposiciones     WHERE oposicion_id = o.id),
            'num_usuarios', (SELECT count(*) FROM usuario_oposiciones  WHERE oposicion_id = o.id)
        ) ORDER BY o.nombre)
        FROM oposiciones o
    ), '[]'::jsonb);
END $$;

-- ── 4) Nuevos RPCs de asignación directa ─────────────────────────────────

-- Reemplaza el conjunto de oposiciones asignadas a un usuario dado.
CREATE OR REPLACE FUNCTION set_usuario_oposiciones(
    p_usuario_id uuid, p_oposicion_ids uuid[]
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    DELETE FROM usuario_oposiciones WHERE usuario_id = p_usuario_id;
    INSERT INTO usuario_oposiciones(usuario_id, oposicion_id)
    SELECT p_usuario_id, oid
    FROM UNNEST(COALESCE(p_oposicion_ids, '{}'::uuid[])) oid
    ON CONFLICT DO NOTHING;
END $$;

-- Oposiciones asignadas a un usuario dado (para pintar el picker).
CREATE OR REPLACE FUNCTION oposiciones_de_usuario(p_usuario_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object('id', o.id, 'nombre', o.nombre) ORDER BY o.nombre)
        FROM usuario_oposiciones uo
        JOIN oposiciones o ON o.id = uo.oposicion_id
        WHERE uo.usuario_id = p_usuario_id
    ), '[]'::jsonb);
END $$;

-- Reemplaza el conjunto de tests que pertenecen a una oposición dada
-- (bulk). Los tests que se quiten quedan en las otras oposiciones que
-- tuvieran asignadas (no borra vínculos cruzados).
CREATE OR REPLACE FUNCTION set_oposicion_tests(
    p_oposicion_id uuid, p_test_ids uuid[]
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NOT (es_admin() OR tiene_permiso('test.crear')) THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    DELETE FROM test_oposiciones WHERE oposicion_id = p_oposicion_id;
    INSERT INTO test_oposiciones(test_id, oposicion_id)
    SELECT tid, p_oposicion_id
    FROM UNNEST(COALESCE(p_test_ids, '{}'::uuid[])) tid
    ON CONFLICT DO NOTHING;
END $$;

-- IDs de los tests actualmente en una oposición (para pre-marcar el picker).
CREATE OR REPLACE FUNCTION tests_de_oposicion(p_oposicion_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT COALESCE(jsonb_agg(test_id), '[]'::jsonb)
    FROM test_oposiciones WHERE oposicion_id = p_oposicion_id;
$$;

-- Listado ligero de tests para el picker bulk: solo id, título y etiquetas.
-- No pagina: el picker filtra en cliente por nombre y etiqueta.
CREATE OR REPLACE FUNCTION listar_tests_min() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
BEGIN
    IF NOT (es_admin() OR tiene_permiso('test.crear')) THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id',            t.id,
            'titulo',        t.titulo,
            'etiquetas',     t.etiquetas,
            'num_preguntas', (SELECT count(*) FROM test_preguntas tp WHERE tp.test_id = t.id)
        ) ORDER BY t.titulo)
        FROM tests t
    ), '[]'::jsonb);
END $$;

-- ── 5) Baja de RPCs de perfiles y de las tablas ──────────────────────────

DROP FUNCTION IF EXISTS listar_perfiles_admin();
DROP FUNCTION IF EXISTS crear_perfil(text, text);
DROP FUNCTION IF EXISTS editar_perfil(uuid, text, text);
DROP FUNCTION IF EXISTS borrar_perfil(uuid);
DROP FUNCTION IF EXISTS set_perfil_oposiciones(uuid, uuid[]);
DROP FUNCTION IF EXISTS set_usuario_perfiles(uuid, uuid[]);
DROP FUNCTION IF EXISTS perfiles_de_usuario(uuid);

DROP TABLE IF EXISTS usuario_perfiles;
DROP TABLE IF EXISTS perfil_oposiciones;
DROP TABLE IF EXISTS perfiles;

-- ── 6) GRANTs ────────────────────────────────────────────────────────────

GRANT EXECUTE ON FUNCTION set_usuario_oposiciones(uuid, uuid[])          TO web_user;
GRANT EXECUTE ON FUNCTION oposiciones_de_usuario(uuid)                   TO web_user;
GRANT EXECUTE ON FUNCTION set_oposicion_tests(uuid, uuid[])              TO web_user;
GRANT EXECUTE ON FUNCTION tests_de_oposicion(uuid)                       TO web_user;
GRANT EXECUTE ON FUNCTION listar_tests_min()                             TO web_user;

DO $$ BEGIN RAISE NOTICE 'Oposiciones directas listas (perfiles eliminados).'; END $$;

COMMIT;
