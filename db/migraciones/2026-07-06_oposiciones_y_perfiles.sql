-- ============================================================================
-- Fase 5 del rediseño móvil: oposiciones + perfiles.
--
-- Este delta añade el sistema de "oposiciones" (bloques temáticos) y
-- "perfiles" (agrupación de oposiciones que se asigna a usuarios). Un
-- test puede pertenecer a 0, 1 o N oposiciones; los tests SIN oposición
-- asignada se consideran globales (visibles para todo el mundo con acceso).
--
-- Es idempotente: se puede correr varias veces sin efectos duplicados.
--
-- Cómo:
--   pgAdmin → conecta al servidor 'aprentix' → Query Tool → pega esto y
--   Execute (F5). Al terminar verás NOTICE con lo aplicado.
-- ============================================================================

BEGIN;

-- ── 1) Tablas nuevas ──────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS oposiciones (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre      text NOT NULL,
    descripcion text,
    activa      boolean NOT NULL DEFAULT true,
    creado_en   timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS oposiciones_nombre_key
    ON oposiciones (lower(nombre));

CREATE TABLE IF NOT EXISTS perfiles (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre      text NOT NULL,
    descripcion text,
    creado_en   timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS perfiles_nombre_key
    ON perfiles (lower(nombre));

CREATE TABLE IF NOT EXISTS perfil_oposiciones (
    perfil_id    uuid NOT NULL REFERENCES perfiles(id)    ON DELETE CASCADE,
    oposicion_id uuid NOT NULL REFERENCES oposiciones(id) ON DELETE CASCADE,
    PRIMARY KEY (perfil_id, oposicion_id)
);

CREATE TABLE IF NOT EXISTS usuario_perfiles (
    usuario_id  uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    perfil_id   uuid NOT NULL REFERENCES perfiles(id) ON DELETE CASCADE,
    asignado_en timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (usuario_id, perfil_id)
);

CREATE TABLE IF NOT EXISTS test_oposiciones (
    test_id      uuid NOT NULL REFERENCES tests(id)       ON DELETE CASCADE,
    oposicion_id uuid NOT NULL REFERENCES oposiciones(id) ON DELETE CASCADE,
    PRIMARY KEY (test_id, oposicion_id)
);
CREATE INDEX IF NOT EXISTS test_oposiciones_oposicion_idx
    ON test_oposiciones (oposicion_id);

-- Cada carpeta (URL-path del listado de teoría) puede pertenecer a UNA
-- oposición. Sin fila = global (visible para todos con acceso a teoría).
CREATE TABLE IF NOT EXISTS carpeta_oposiciones (
    ruta         text PRIMARY KEY,
    oposicion_id uuid NOT NULL REFERENCES oposiciones(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS carpeta_oposiciones_oposicion_idx
    ON carpeta_oposiciones (oposicion_id);

-- ── 2) RLS (lectura pública, escritura por RPC SECURITY DEFINER) ──────────
-- Habilitamos RLS y damos SELECT a web_user; los INSERT/UPDATE/DELETE se
-- hacen desde RPCs con SECURITY DEFINER, así que la política estricta no
-- rompe nada.

ALTER TABLE oposiciones          ENABLE ROW LEVEL SECURITY;
ALTER TABLE perfiles             ENABLE ROW LEVEL SECURITY;
ALTER TABLE perfil_oposiciones   ENABLE ROW LEVEL SECURITY;
ALTER TABLE usuario_perfiles     ENABLE ROW LEVEL SECURITY;
ALTER TABLE test_oposiciones     ENABLE ROW LEVEL SECURITY;
ALTER TABLE carpeta_oposiciones  ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS carpeta_op_lectura         ON carpeta_oposiciones;
CREATE POLICY carpeta_op_lectura         ON carpeta_oposiciones
    FOR SELECT TO web_user USING (true);

DROP POLICY IF EXISTS oposiciones_lectura        ON oposiciones;
CREATE POLICY oposiciones_lectura        ON oposiciones
    FOR SELECT TO web_user USING (true);

DROP POLICY IF EXISTS perfiles_lectura           ON perfiles;
CREATE POLICY perfiles_lectura           ON perfiles
    FOR SELECT TO web_user USING (true);

DROP POLICY IF EXISTS perfil_op_lectura          ON perfil_oposiciones;
CREATE POLICY perfil_op_lectura          ON perfil_oposiciones
    FOR SELECT TO web_user USING (true);

DROP POLICY IF EXISTS usuario_perfiles_lectura   ON usuario_perfiles;
CREATE POLICY usuario_perfiles_lectura   ON usuario_perfiles
    FOR SELECT TO web_user USING (
        usuario_id = jwt_usuario_id() OR es_admin()
    );

DROP POLICY IF EXISTS test_oposiciones_lectura   ON test_oposiciones;
CREATE POLICY test_oposiciones_lectura   ON test_oposiciones
    FOR SELECT TO web_user USING (true);

GRANT SELECT ON oposiciones, perfiles, perfil_oposiciones, usuario_perfiles, test_oposiciones,
                carpeta_oposiciones
    TO web_user;

-- ── 3) Helpers ────────────────────────────────────────────────────────────

-- Devuelve las oposiciones accesibles al usuario actual (unión de todos
-- sus perfiles). Admins/gestores ven TODAS las activas.
CREATE OR REPLACE FUNCTION mis_oposiciones() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE
    v_admin boolean := es_admin() OR tiene_permiso('test.crear');
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
        SELECT jsonb_agg(DISTINCT jsonb_build_object(
            'id', o.id, 'nombre', o.nombre, 'descripcion', o.descripcion
        ) ORDER BY jsonb_build_object(
            'id', o.id, 'nombre', o.nombre, 'descripcion', o.descripcion
        ))
        FROM usuario_perfiles up
        JOIN perfil_oposiciones po ON po.perfil_id = up.perfil_id
        JOIN oposiciones o         ON o.id = po.oposicion_id
        WHERE up.usuario_id = jwt_usuario_id()
          AND o.activa
    ), '[]'::jsonb);
END $$;

-- Comprueba si el usuario actual puede ACCEDER a una oposición dada.
CREATE OR REPLACE FUNCTION puedo_ver_oposicion(p_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT es_admin() OR tiene_permiso('test.crear') OR EXISTS (
        SELECT 1
        FROM usuario_perfiles up
        JOIN perfil_oposiciones po ON po.perfil_id = up.perfil_id
        WHERE up.usuario_id = jwt_usuario_id()
          AND po.oposicion_id = p_id
    );
$$;

-- ── 4) RPCs de gestión (admin) ────────────────────────────────────────────

CREATE OR REPLACE FUNCTION crear_oposicion(p_nombre text, p_descripcion text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_id uuid;
BEGIN
    IF NOT (es_admin() OR tiene_permiso('test.crear')) THEN
        RAISE EXCEPTION 'no_autorizado';
    END IF;
    INSERT INTO oposiciones(nombre, descripcion)
    VALUES (trim(p_nombre), NULLIF(trim(p_descripcion), ''))
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('id', v_id);
END $$;

CREATE OR REPLACE FUNCTION editar_oposicion(
    p_id uuid, p_nombre text, p_descripcion text DEFAULT NULL, p_activa boolean DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NOT (es_admin() OR tiene_permiso('test.crear')) THEN
        RAISE EXCEPTION 'no_autorizado';
    END IF;
    UPDATE oposiciones
       SET nombre      = COALESCE(NULLIF(trim(p_nombre), ''), nombre),
           descripcion = COALESCE(NULLIF(trim(p_descripcion), ''), descripcion),
           activa      = COALESCE(p_activa, activa)
     WHERE id = p_id;
END $$;

CREATE OR REPLACE FUNCTION borrar_oposicion(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    DELETE FROM oposiciones WHERE id = p_id;
END $$;

CREATE OR REPLACE FUNCTION crear_perfil(p_nombre text, p_descripcion text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_id uuid;
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    INSERT INTO perfiles(nombre, descripcion)
    VALUES (trim(p_nombre), NULLIF(trim(p_descripcion), ''))
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('id', v_id);
END $$;

CREATE OR REPLACE FUNCTION editar_perfil(
    p_id uuid, p_nombre text, p_descripcion text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    UPDATE perfiles
       SET nombre      = COALESCE(NULLIF(trim(p_nombre), ''), nombre),
           descripcion = COALESCE(NULLIF(trim(p_descripcion), ''), descripcion)
     WHERE id = p_id;
END $$;

CREATE OR REPLACE FUNCTION borrar_perfil(p_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    DELETE FROM perfiles WHERE id = p_id;
END $$;

-- Reemplaza el conjunto de oposiciones asignadas a un perfil.
CREATE OR REPLACE FUNCTION set_perfil_oposiciones(
    p_perfil_id uuid, p_oposicion_ids uuid[]
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    DELETE FROM perfil_oposiciones WHERE perfil_id = p_perfil_id;
    INSERT INTO perfil_oposiciones(perfil_id, oposicion_id)
    SELECT p_perfil_id, oid
    FROM UNNEST(COALESCE(p_oposicion_ids, '{}'::uuid[])) oid
    ON CONFLICT DO NOTHING;
END $$;

-- Reemplaza el conjunto de perfiles asignados a un usuario.
CREATE OR REPLACE FUNCTION set_usuario_perfiles(
    p_usuario_id uuid, p_perfil_ids uuid[]
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    DELETE FROM usuario_perfiles WHERE usuario_id = p_usuario_id;
    INSERT INTO usuario_perfiles(usuario_id, perfil_id)
    SELECT p_usuario_id, pid
    FROM UNNEST(COALESCE(p_perfil_ids, '{}'::uuid[])) pid
    ON CONFLICT DO NOTHING;
END $$;

-- Reemplaza el conjunto de oposiciones asociadas a un test.
CREATE OR REPLACE FUNCTION set_test_oposiciones(
    p_test_id uuid, p_oposicion_ids uuid[]
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NOT (es_admin() OR tiene_permiso('test.crear')) THEN
        RAISE EXCEPTION 'no_autorizado';
    END IF;
    DELETE FROM test_oposiciones WHERE test_id = p_test_id;
    INSERT INTO test_oposiciones(test_id, oposicion_id)
    SELECT p_test_id, oid
    FROM UNNEST(COALESCE(p_oposicion_ids, '{}'::uuid[])) oid
    ON CONFLICT DO NOTHING;
END $$;

-- Lista todos los perfiles con sus oposiciones (admin).
CREATE OR REPLACE FUNCTION listar_perfiles_admin() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id',          p.id,
            'nombre',      p.nombre,
            'descripcion', p.descripcion,
            'oposiciones', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                    'id', o.id, 'nombre', o.nombre
                ) ORDER BY o.nombre)
                FROM perfil_oposiciones po
                JOIN oposiciones o ON o.id = po.oposicion_id
                WHERE po.perfil_id = p.id
            ), '[]'::jsonb)
        ) ORDER BY p.nombre)
        FROM perfiles p
    ), '[]'::jsonb);
END $$;

-- Lista todas las oposiciones (admin) con contadores útiles.
CREATE OR REPLACE FUNCTION listar_oposiciones_admin() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
BEGIN
    IF NOT (es_admin() OR tiene_permiso('test.crear')) THEN
        RAISE EXCEPTION 'no_autorizado';
    END IF;
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id',          o.id,
            'nombre',      o.nombre,
            'descripcion', o.descripcion,
            'activa',      o.activa,
            'num_tests',   (SELECT count(*) FROM test_oposiciones WHERE oposicion_id = o.id),
            'num_perfiles',(SELECT count(*) FROM perfil_oposiciones WHERE oposicion_id = o.id)
        ) ORDER BY o.nombre)
        FROM oposiciones o
    ), '[]'::jsonb);
END $$;

-- Perfiles asignados a un usuario dado (admin, para el modal usuario).
CREATE OR REPLACE FUNCTION perfiles_de_usuario(p_usuario_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object('id', p.id, 'nombre', p.nombre)
                         ORDER BY p.nombre)
        FROM usuario_perfiles up
        JOIN perfiles p ON p.id = up.perfil_id
        WHERE up.usuario_id = p_usuario_id
    ), '[]'::jsonb);
END $$;

-- Asigna una oposición a una carpeta de teoría (ruta URL). NULL = global
-- (borra la asignación). Solo admin/gestor de tests.
CREATE OR REPLACE FUNCTION set_carpeta_oposicion(p_ruta text, p_oposicion_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NOT (es_admin() OR tiene_permiso('test.crear')) THEN
        RAISE EXCEPTION 'no_autorizado';
    END IF;
    IF p_ruta IS NULL OR btrim(p_ruta) = '' OR p_ruta = '/' THEN
        RAISE EXCEPTION 'ruta_invalida';
    END IF;
    IF p_oposicion_id IS NULL THEN
        DELETE FROM carpeta_oposiciones WHERE ruta = p_ruta;
    ELSE
        INSERT INTO carpeta_oposiciones(ruta, oposicion_id)
        VALUES (p_ruta, p_oposicion_id)
        ON CONFLICT (ruta) DO UPDATE SET oposicion_id = EXCLUDED.oposicion_id;
    END IF;
END $$;

-- Devuelve el mapa de carpetas asignadas (ruta → {id, nombre}) para que
-- el backend de teoría pueda filtrar el listado.
CREATE OR REPLACE FUNCTION listar_carpeta_oposiciones() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'ruta',            co.ruta,
        'oposicion_id',    co.oposicion_id,
        'oposicion_nombre',o.nombre
    ) ORDER BY co.ruta), '[]'::jsonb)
    FROM carpeta_oposiciones co
    JOIN oposiciones o ON o.id = co.oposicion_id;
$$;

-- Devuelve la oposición asignada a una carpeta dada, o null si es global.
CREATE OR REPLACE FUNCTION oposicion_de_carpeta(p_ruta text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT COALESCE(jsonb_build_object('id', o.id, 'nombre', o.nombre), 'null'::jsonb)
    FROM carpeta_oposiciones co
    LEFT JOIN oposiciones o ON o.id = co.oposicion_id
    WHERE co.ruta = p_ruta
    LIMIT 1;
$$;

-- IDs de oposiciones accesibles por el usuario actual. Admins/gestores
-- reciben TODAS las ids activas. Los alumnos solo las que traen sus
-- perfiles. Se usa desde el backend de teoría para filtrar.
CREATE OR REPLACE FUNCTION mis_oposiciones_ids() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
DECLARE v_admin boolean := es_admin() OR tiene_permiso('test.crear');
BEGIN
    IF v_admin THEN
        RETURN COALESCE((SELECT jsonb_agg(id) FROM oposiciones WHERE activa),
                        '[]'::jsonb);
    END IF;
    RETURN COALESCE((
        SELECT jsonb_agg(DISTINCT o.id)
        FROM usuario_perfiles up
        JOIN perfil_oposiciones po ON po.perfil_id = up.perfil_id
        JOIN oposiciones o         ON o.id = po.oposicion_id
        WHERE up.usuario_id = jwt_usuario_id() AND o.activa
    ), '[]'::jsonb);
END $$;

-- Oposiciones asignadas a un test dado.
CREATE OR REPLACE FUNCTION oposiciones_de_test(p_test_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', o.id, 'nombre', o.nombre)
                              ORDER BY o.nombre), '[]'::jsonb)
    FROM test_oposiciones tox
    JOIN oposiciones o ON o.id = tox.oposicion_id
    WHERE tox.test_id = p_test_id;
$$;

-- ── 5) Nuevo listar_tests con filtro por oposición ───────────────────────
-- La signatura antigua se sustituye por una que acepta p_oposicion_id
-- (uuid opcional). Un test es visible en el listado si:
--   - Está sin asignar a ninguna oposición (globales), o
--   - Está asignado a la oposición seleccionada.
-- Si p_oposicion_id es NULL, se aplica la lógica antigua (todos).

DROP FUNCTION IF EXISTS listar_tests(boolean, int, int, text, boolean, text);

CREATE OR REPLACE FUNCTION listar_tests(
    p_solo_favoritos  boolean DEFAULT false,
    p_page            int     DEFAULT 1,
    p_size            int     DEFAULT 10,
    p_etiqueta        text    DEFAULT NULL,
    p_solo_pendientes boolean DEFAULT false,
    p_orden           text    DEFAULT 'reciente',
    p_oposicion_id    uuid    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_offset int := GREATEST(p_page - 1, 0) * p_size;
    v_total  int;
    v_tests  jsonb;
BEGIN
    WITH base AS (
        SELECT
            t.id, t.titulo, t.descripcion, t.tipo, t.publico,
            t.etiquetas, t.creado_en,
            (SELECT count(*) FROM test_preguntas tp WHERE tp.test_id = t.id) AS num_preguntas,
            (SELECT count(*) FROM intentos i
              WHERE i.test_id = t.id AND i.usuario_id = jwt_usuario_id()) AS num_intentos,
            EXISTS (
                SELECT 1 FROM intentos i
                 WHERE i.test_id = t.id
                   AND i.usuario_id = jwt_usuario_id()
                   AND i.finalizado_en IS NULL
            ) AS tiene_pendiente,
            EXISTS (
                SELECT 1 FROM marcadores m
                 WHERE m.usuario_id = jwt_usuario_id()
                   AND m.tipo = 'test_favorito'
                   AND m.test_id = t.id
            ) AS favorito
        FROM tests t
        WHERE (t.publico OR t.autor_id = jwt_usuario_id() OR es_admin())
          AND (p_etiqueta IS NULL OR p_etiqueta = ANY(t.etiquetas))
          AND (
              p_oposicion_id IS NULL
              OR NOT EXISTS (SELECT 1 FROM test_oposiciones WHERE test_id = t.id)
              OR EXISTS (
                  SELECT 1 FROM test_oposiciones WHERE test_id = t.id
                    AND oposicion_id = p_oposicion_id
              )
          )
    ),
    filtrada AS (
        SELECT * FROM base
        WHERE (NOT p_solo_favoritos  OR favorito)
          AND (NOT p_solo_pendientes OR tiene_pendiente)
    )
    SELECT count(*) INTO v_total FROM filtrada;

    WITH base AS (
        SELECT
            t.id, t.titulo, t.descripcion, t.tipo, t.publico,
            t.etiquetas, t.creado_en,
            (SELECT count(*) FROM test_preguntas tp WHERE tp.test_id = t.id) AS num_preguntas,
            (SELECT count(*) FROM intentos i
              WHERE i.test_id = t.id AND i.usuario_id = jwt_usuario_id()) AS num_intentos,
            EXISTS (
                SELECT 1 FROM intentos i
                 WHERE i.test_id = t.id
                   AND i.usuario_id = jwt_usuario_id()
                   AND i.finalizado_en IS NULL
            ) AS tiene_pendiente,
            EXISTS (
                SELECT 1 FROM marcadores m
                 WHERE m.usuario_id = jwt_usuario_id()
                   AND m.tipo = 'test_favorito'
                   AND m.test_id = t.id
            ) AS favorito
        FROM tests t
        WHERE (t.publico OR t.autor_id = jwt_usuario_id() OR es_admin())
          AND (p_etiqueta IS NULL OR p_etiqueta = ANY(t.etiquetas))
          AND (
              p_oposicion_id IS NULL
              OR NOT EXISTS (SELECT 1 FROM test_oposiciones WHERE test_id = t.id)
              OR EXISTS (
                  SELECT 1 FROM test_oposiciones WHERE test_id = t.id
                    AND oposicion_id = p_oposicion_id
              )
          )
    )
    SELECT COALESCE(jsonb_agg(row_to_json(x)), '[]'::jsonb) INTO v_tests
    FROM (
        SELECT
            b.id,
            b.titulo       AS title,
            b.descripcion  AS description,
            b.tipo,
            b.publico,
            b.etiquetas,
            b.creado_en    AS created_at,
            b.num_preguntas,
            b.num_intentos,
            b.tiene_pendiente,
            b.favorito
        FROM base b
        WHERE (NOT p_solo_favoritos  OR b.favorito)
          AND (NOT p_solo_pendientes OR b.tiene_pendiente)
        ORDER BY
            (CASE WHEN p_orden = 'intentos_desc' THEN b.num_intentos ELSE NULL END) DESC NULLS LAST,
            (CASE WHEN p_orden = 'intentos_asc'  THEN b.num_intentos ELSE NULL END) ASC  NULLS LAST,
            (CASE WHEN p_orden = 'antiguo'       THEN b.creado_en    ELSE NULL END) ASC  NULLS LAST,
            b.creado_en DESC
        LIMIT p_size OFFSET v_offset
    ) x;

    RETURN jsonb_build_object(
        'tests',       v_tests,
        'page',        p_page,
        'page_size',   p_size,
        'total',       v_total,
        'total_pages', GREATEST(1, (v_total + p_size - 1) / p_size)
    );
END $$;

-- ── 6) GRANTs ────────────────────────────────────────────────────────────

GRANT EXECUTE ON FUNCTION mis_oposiciones()                              TO web_user;
GRANT EXECUTE ON FUNCTION puedo_ver_oposicion(uuid)                      TO web_user;
GRANT EXECUTE ON FUNCTION crear_oposicion(text, text)                    TO web_user;
GRANT EXECUTE ON FUNCTION editar_oposicion(uuid, text, text, boolean)    TO web_user;
GRANT EXECUTE ON FUNCTION borrar_oposicion(uuid)                         TO web_user;
GRANT EXECUTE ON FUNCTION crear_perfil(text, text)                       TO web_user;
GRANT EXECUTE ON FUNCTION editar_perfil(uuid, text, text)                TO web_user;
GRANT EXECUTE ON FUNCTION borrar_perfil(uuid)                            TO web_user;
GRANT EXECUTE ON FUNCTION set_perfil_oposiciones(uuid, uuid[])           TO web_user;
GRANT EXECUTE ON FUNCTION set_usuario_perfiles(uuid, uuid[])             TO web_user;
GRANT EXECUTE ON FUNCTION set_test_oposiciones(uuid, uuid[])             TO web_user;
GRANT EXECUTE ON FUNCTION listar_perfiles_admin()                        TO web_user;
GRANT EXECUTE ON FUNCTION listar_oposiciones_admin()                     TO web_user;
GRANT EXECUTE ON FUNCTION perfiles_de_usuario(uuid)                      TO web_user;
GRANT EXECUTE ON FUNCTION oposiciones_de_test(uuid)                      TO web_user;
GRANT EXECUTE ON FUNCTION set_carpeta_oposicion(text, uuid)              TO web_user;
GRANT EXECUTE ON FUNCTION listar_carpeta_oposiciones()                   TO web_user;
GRANT EXECUTE ON FUNCTION oposicion_de_carpeta(text)                     TO web_user;
GRANT EXECUTE ON FUNCTION mis_oposiciones_ids()                          TO web_user;
GRANT EXECUTE ON FUNCTION listar_tests(boolean, int, int, text, boolean, text, uuid) TO web_user;

DO $$ BEGIN RAISE NOTICE 'Oposiciones y perfiles instalados correctamente.'; END $$;

COMMIT;
