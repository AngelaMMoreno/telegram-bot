-- ============================================================================
-- Delta a aplicar UNA VEZ sobre una BBDD viva anterior a los cambios de
-- 'teoría' y 'resetear repaso'. Idempotente: se puede correr varias veces
-- sin efectos duplicados.
--
-- Cuándo:
--   Solo si tu Postgres ya estaba corriendo desde antes de estos cambios.
--   En despliegues sobre BBDD vacía NO hace falta: 01_esquema.sql ya crea
--   todo esto.
--
-- Cómo:
--   pgAdmin → conecta al servidor 'aprentix' → Query Tool → pega esto y
--   Execute (F5). Al terminar verás NOTICE con lo que se ha aplicado.
-- ============================================================================

BEGIN;

-- ── 1) Nuevo rol funcional 'teoria' ────────────────────────────────────────
INSERT INTO roles (id, descripcion) VALUES
    ('teoria', 'Puede acceder al material de teoría')
ON CONFLICT (id) DO NOTHING;

-- ── 2) Nuevos permisos ─────────────────────────────────────────────────────
INSERT INTO permisos (id, descripcion) VALUES
    ('teoria.acceder',   'Ver y descargar ficheros de teoría'),
    ('teoria.gestionar', 'Subir, mover, editar y borrar ficheros de teoría')
ON CONFLICT (id) DO NOTHING;

-- Admin sigue teniendo TODOS los permisos: el mapeo 'admin → *' se
-- reafirma; SELECT sobre permisos lo repuebla con los nuevos.
INSERT INTO rol_permisos (rol_id, permiso_id)
SELECT 'admin', id FROM permisos
ON CONFLICT DO NOTHING;

INSERT INTO rol_permisos (rol_id, permiso_id) VALUES
    ('teoria', 'teoria.acceder')
ON CONFLICT DO NOTHING;


-- ── 3) Tabla ficheros_vistas ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS ficheros_vistas (
    usuario_id  uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    ruta        text NOT NULL,
    vista_en    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (usuario_id, ruta)
);

CREATE INDEX IF NOT EXISTS ficheros_vistas_usuario_idx
    ON ficheros_vistas (usuario_id);

ALTER TABLE ficheros_vistas ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS vistas_propias ON ficheros_vistas;
CREATE POLICY vistas_propias ON ficheros_vistas
    FOR ALL TO web_user
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());

GRANT SELECT, INSERT, UPDATE, DELETE ON ficheros_vistas TO web_user;
ALTER TABLE ficheros_vistas ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();


-- ── 4) RPCs de teoría ──────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION puede_ver_teoria() RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT tiene_permiso('teoria.acceder') OR es_admin();
$$;

CREATE OR REPLACE FUNCTION marcar_fichero_visto(p_ruta text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF jwt_usuario_id() IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    INSERT INTO ficheros_vistas(usuario_id, ruta, vista_en)
    VALUES (jwt_usuario_id(), p_ruta, now())
    ON CONFLICT (usuario_id, ruta) DO UPDATE
        SET vista_en = EXCLUDED.vista_en;
END $$;

CREATE OR REPLACE FUNCTION marcar_fichero_no_visto(p_ruta text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF jwt_usuario_id() IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    DELETE FROM ficheros_vistas
     WHERE usuario_id = jwt_usuario_id() AND ruta = p_ruta;
END $$;

CREATE OR REPLACE FUNCTION mis_ficheros_vistos(p_prefijo text DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'ruta',     ruta,
        'vista_en', vista_en
    ) ORDER BY vista_en DESC), '[]'::jsonb)
    FROM ficheros_vistas
    WHERE usuario_id = jwt_usuario_id()
      AND (p_prefijo IS NULL OR p_prefijo = '' OR ruta LIKE p_prefijo || '%');
$$;

CREATE OR REPLACE FUNCTION renombrar_ruta_vistas(p_origen text, p_destino text)
RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
    IF NOT (tiene_permiso('teoria.gestionar') OR es_admin()) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    UPDATE ficheros_vistas SET ruta = p_destino WHERE ruta = p_origen;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        UPDATE ficheros_vistas
           SET ruta = p_destino || substring(ruta from length(p_origen) + 1)
         WHERE ruta LIKE p_origen || '/%';
        GET DIAGNOSTICS v_n = ROW_COUNT;
    END IF;
    RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION borrar_ruta_vistas(p_ruta text) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
    IF NOT (tiene_permiso('teoria.gestionar') OR es_admin()) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    DELETE FROM ficheros_vistas
     WHERE ruta = p_ruta OR ruta LIKE p_ruta || '/%';
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END $$;

GRANT EXECUTE ON FUNCTION puede_ver_teoria()                    TO web_user;
GRANT EXECUTE ON FUNCTION marcar_fichero_visto(text)            TO web_user;
GRANT EXECUTE ON FUNCTION marcar_fichero_no_visto(text)         TO web_user;
GRANT EXECUTE ON FUNCTION mis_ficheros_vistos(text)             TO web_user;
GRANT EXECUTE ON FUNCTION renombrar_ruta_vistas(text, text)     TO web_user;
GRANT EXECUTE ON FUNCTION borrar_ruta_vistas(text)              TO web_user;


-- ── 5) Reset del motor de cajas ────────────────────────────────────────────
CREATE OR REPLACE FUNCTION resetear_mis_repasos(p_test_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_n   int;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;

    IF p_test_id IS NULL THEN
        DELETE FROM repasos WHERE usuario_id = v_uid;
    ELSE
        DELETE FROM repasos
         WHERE usuario_id = v_uid
           AND pregunta_id IN (
               SELECT pregunta_id FROM test_preguntas WHERE test_id = p_test_id
           );
    END IF;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN jsonb_build_object('borradas', v_n);
END $$;

GRANT EXECUTE ON FUNCTION resetear_mis_repasos(uuid) TO web_user;


-- ── 6) Comprobación final ──────────────────────────────────────────────────
DO $$
DECLARE
    v_rol       boolean;
    v_permisos  int;
    v_tabla     boolean;
    v_funcs     int;
BEGIN
    SELECT true INTO v_rol FROM roles WHERE id = 'teoria';
    SELECT count(*) INTO v_permisos FROM permisos
     WHERE id IN ('teoria.acceder', 'teoria.gestionar');
    SELECT to_regclass('public.ficheros_vistas') IS NOT NULL INTO v_tabla;
    SELECT count(*) INTO v_funcs FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN (
           'puede_ver_teoria', 'marcar_fichero_visto', 'marcar_fichero_no_visto',
           'mis_ficheros_vistos', 'renombrar_ruta_vistas', 'borrar_ruta_vistas',
           'resetear_mis_repasos'
       );

    RAISE NOTICE 'rol teoria presente:      %', COALESCE(v_rol, false);
    RAISE NOTICE 'permisos nuevos:          %/2', v_permisos;
    RAISE NOTICE 'tabla ficheros_vistas:    %', v_tabla;
    RAISE NOTICE 'RPCs esperadas presentes: %/7', v_funcs;
END $$;

-- Refresca el esquema de PostgREST (evita tener que reiniciar el pod).
NOTIFY pgrst, 'reload schema';

COMMIT;
