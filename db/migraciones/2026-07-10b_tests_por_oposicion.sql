-- ─────────────────────────────────────────────────────────────────────────
-- Los usuarios con rol 'tests' (antes 'alumno') no ven los tests de su
-- oposición si el test no está marcado como `publico=true`. El admin sí
-- porque las policies incluyen `es_admin()`. Este delta amplía la
-- visibilidad de un test a los usuarios que tienen asignada, en su
-- perfil, alguna de las oposiciones a las que el test pertenece — el
-- criterio con el que el admin ya reparte tests desde el panel.
--
-- Se toca:
--   • RLS `test_lectura` (SELECT sobre `tests`).
--   • `listar_tests` (WHERE de conteo y de página).
--
-- No cambia nada para admin/editor/autor: siguen viendo todo lo que
-- veían. Solo abre puerta a los tests explícitamente asignados a las
-- oposiciones del usuario.
--
-- Idempotente.
-- ─────────────────────────────────────────────────────────────────────────
BEGIN;

DROP POLICY IF EXISTS test_lectura ON tests;
CREATE POLICY test_lectura ON tests FOR SELECT
    USING (
        publico
        OR autor_id = jwt_usuario_id()
        OR es_admin()
        OR EXISTS (
            SELECT 1
            FROM   test_oposiciones    tox
            JOIN   usuario_oposiciones uo ON uo.oposicion_id = tox.oposicion_id
            WHERE  tox.test_id     = tests.id
              AND  uo.usuario_id   = jwt_usuario_id()
        )
    );

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
        WHERE (
              t.publico
              OR t.autor_id = jwt_usuario_id()
              OR es_admin()
              OR EXISTS (SELECT 1
                           FROM test_oposiciones    tox
                           JOIN usuario_oposiciones uo ON uo.oposicion_id = tox.oposicion_id
                          WHERE tox.test_id   = t.id
                            AND uo.usuario_id = jwt_usuario_id())
          )
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
        WHERE (
              t.publico
              OR t.autor_id = jwt_usuario_id()
              OR es_admin()
              OR EXISTS (SELECT 1
                           FROM test_oposiciones    tox
                           JOIN usuario_oposiciones uo ON uo.oposicion_id = tox.oposicion_id
                          WHERE tox.test_id   = t.id
                            AND uo.usuario_id = jwt_usuario_id())
          )
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

COMMIT;

NOTIFY pgrst, 'reload schema';
