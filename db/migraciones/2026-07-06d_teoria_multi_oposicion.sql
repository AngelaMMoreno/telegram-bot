-- ============================================================================
-- Fase 5c: teoría multi-oposición + filtro estricto de tests/teoría.
--
-- Cambios:
--   1) `carpeta_oposiciones` deja de ser 1-a-1 (ruta) y pasa a N-a-N
--      (PK compuesta ruta, oposicion_id).  Una misma carpeta de teoría
--      puede pertenecer a varias oposiciones a la vez.
--   2) `set_carpeta_oposiciones(text, uuid[])` sustituye a la vieja
--      `set_carpeta_oposicion(text, uuid)`: reemplaza la lista completa
--      de oposiciones asignadas a la carpeta (array vacío = global).
--   3) `listar_carpeta_oposiciones()` agrega ahora por ruta, devolviendo
--      un array de {id, nombre} por cada carpeta asignada.
--   4) Nuevo `oposiciones_de_carpeta(text)` que devuelve la lista de
--      oposiciones asignadas a una ruta (array vacío = global).
--   5) `listar_tests()` pasa a filtro ESTRICTO: si se pasa p_oposicion_id
--      solo se muestran los tests asignados explícitamente a ella (los
--      globales — sin oposición — dejan de aparecer al elegir una).
--   6) Se corrige `mis_oposiciones_ids()` en el esquema base, que aún
--      referenciaba las tablas `usuario_perfiles` / `perfil_oposiciones`
--      eliminadas por la migración 2026-07-06b.
--
-- Idempotente: se puede correr varias veces.
--
-- Cómo aplicar:
--   pgAdmin → Query Tool → pega esto y F5.
-- ============================================================================

BEGIN;

-- ── 1) carpeta_oposiciones: PK compuesta (ruta, oposicion_id) ──────────────
--
-- Si la tabla existe con la vieja PK sobre (ruta), la migramos a la nueva
-- clave compuesta sin perder los datos.  Postgres no admite ALTER PRIMARY
-- KEY directo si la restricción se llama distinto, así que buscamos y
-- soltamos la PK actual antes de crear la nueva.

DO $$
DECLARE
    v_pk_name text;
BEGIN
    SELECT tc.constraint_name INTO v_pk_name
      FROM information_schema.table_constraints tc
     WHERE tc.table_name = 'carpeta_oposiciones'
       AND tc.constraint_type = 'PRIMARY KEY'
     LIMIT 1;
    IF v_pk_name IS NOT NULL THEN
        -- Si la PK es solo (ruta), la reemplazamos.  Si ya es compuesta
        -- (por si esta migración se aplicó antes), no la tocamos.
        IF NOT EXISTS (
            SELECT 1
              FROM information_schema.key_column_usage
             WHERE constraint_name = v_pk_name
               AND column_name = 'oposicion_id'
        ) THEN
            EXECUTE format('ALTER TABLE carpeta_oposiciones DROP CONSTRAINT %I',
                           v_pk_name);
            ALTER TABLE carpeta_oposiciones
                ADD PRIMARY KEY (ruta, oposicion_id);
        END IF;
    END IF;
END $$;

-- Índice por ruta para el "dame las oposiciones de esta carpeta".
CREATE INDEX IF NOT EXISTS carpeta_oposiciones_ruta_idx
    ON carpeta_oposiciones (ruta);

-- ── 2) RPC nueva: set_carpeta_oposiciones(text, uuid[]) ────────────────────
--
-- Reemplaza todas las asignaciones de una carpeta por el conjunto pasado.
-- Un array vacío o NULL elimina todas las asignaciones (carpeta global).
CREATE OR REPLACE FUNCTION set_carpeta_oposiciones(
    p_ruta text, p_oposicion_ids uuid[]
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NOT (es_admin() OR tiene_permiso('test.crear')) THEN
        RAISE EXCEPTION 'no_autorizado';
    END IF;
    IF p_ruta IS NULL OR btrim(p_ruta) = '' OR p_ruta = '/' THEN
        RAISE EXCEPTION 'ruta_invalida';
    END IF;
    DELETE FROM carpeta_oposiciones WHERE ruta = p_ruta;
    IF p_oposicion_ids IS NOT NULL AND array_length(p_oposicion_ids, 1) > 0 THEN
        INSERT INTO carpeta_oposiciones(ruta, oposicion_id)
        SELECT p_ruta, oid
        FROM UNNEST(p_oposicion_ids) oid
        ON CONFLICT DO NOTHING;
    END IF;
END $$;

GRANT EXECUTE ON FUNCTION set_carpeta_oposiciones(text, uuid[]) TO web_user;

-- Mantenemos la vieja RPC (1-a-1) como shim delegando en la nueva por si
-- algún cliente antiguo la sigue llamando.  Si te aseguras de que ya no
-- hay clientes viejos, puedes DROP FUNCTION set_carpeta_oposicion(text, uuid).
CREATE OR REPLACE FUNCTION set_carpeta_oposicion(p_ruta text, p_oposicion_id uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF p_oposicion_id IS NULL THEN
        PERFORM set_carpeta_oposiciones(p_ruta, '{}'::uuid[]);
    ELSE
        PERFORM set_carpeta_oposiciones(p_ruta, ARRAY[p_oposicion_id]);
    END IF;
END $$;

-- ── 3) Listado agregado por ruta ───────────────────────────────────────────
--
-- Devuelve, por cada ruta con asignación, la lista de {id, nombre} de sus
-- oposiciones y una cadena de conveniencia con los nombres concatenados
-- (para pintar un tooltip / badge combinado).
CREATE OR REPLACE FUNCTION listar_carpeta_oposiciones() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'ruta'), '[]'::jsonb) FROM (
        SELECT jsonb_build_object(
            'ruta',              co.ruta,
            'oposicion_ids',     jsonb_agg(co.oposicion_id ORDER BY o.nombre),
            'oposicion_nombres', jsonb_agg(o.nombre        ORDER BY o.nombre)
        ) AS x
        FROM carpeta_oposiciones co
        JOIN oposiciones o ON o.id = co.oposicion_id
        GROUP BY co.ruta
    ) t;
$$;

-- ── 4) oposiciones_de_carpeta(text) ────────────────────────────────────────
CREATE OR REPLACE FUNCTION oposiciones_de_carpeta(p_ruta text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', o.id, 'nombre', o.nombre)
                              ORDER BY o.nombre), '[]'::jsonb)
    FROM carpeta_oposiciones co
    JOIN oposiciones o ON o.id = co.oposicion_id
    WHERE co.ruta = p_ruta;
$$;

GRANT EXECUTE ON FUNCTION oposiciones_de_carpeta(text) TO web_user;

-- ── 5) Filtro ESTRICTO en listar_tests ─────────────────────────────────────
--
-- Si p_oposicion_id no es NULL, se muestran solo tests asignados
-- explícitamente a esa oposición.  Los tests sin oposición asignada
-- (globales) ya no aparecen cuando el usuario ha elegido una oposición.
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
              OR EXISTS (SELECT 1 FROM test_oposiciones
                          WHERE test_id = t.id AND oposicion_id = p_oposicion_id)
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
              OR EXISTS (SELECT 1 FROM test_oposiciones
                          WHERE test_id = t.id AND oposicion_id = p_oposicion_id)
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

-- ── 6) mis_oposiciones_ids: fuente correcta (usuario_oposiciones) ─────────
--
-- El 01_esquema.sql base aún llamaba a las tablas `usuario_perfiles` y
-- `perfil_oposiciones`, eliminadas en 2026-07-06b_oposiciones_directas.
-- La migración b ya reescribió esta RPC en su día, pero la dejamos aquí
-- de forma explícita por si esta migración se corre sobre una BBDD que
-- viene de un `01_esquema.sql` reciente sin haber pasado por la 'b'.
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

-- ── 7) Recarga del esquema en PostgREST ────────────────────────────────────
NOTIFY pgrst, 'reload schema';

DO $$ BEGIN
    RAISE NOTICE 'Teoría multi-oposición + filtro estricto listos.';
END $$;

COMMIT;
