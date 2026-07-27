-- 2026-07-29_preguntas_total_home.sql
-- ─────────────────────────────────────────────────────────────────────
-- Reemplaza `mi_home_oposicion` para incluir el número de preguntas
-- disponibles en cada módulo y en cada tema.  Con este dato la SPA
-- puede pintar las tarjetas del home al estilo "40 preguntas" sin
-- tener que hacer una RPC extra por tema.
--
-- No hay cambios de esquema (solo se reescribe la función), por lo
-- que la migración es completamente idempotente.
-- ─────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION mi_home_oposicion(p_oposicion_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_res jsonb;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;

    WITH secc_pct AS (
        -- Por sección: completada (0/1) — luego agregamos a módulo y tema.
        SELECT s.id AS seccion_id, s.modulo_id, m.tema_id,
               (ps.completada_en IS NOT NULL)::int AS completada,
               ps.nota_max,
               ps.teoria_vista_en
          FROM secciones s
          JOIN modulos m ON m.id = s.modulo_id
          LEFT JOIN progreso_seccion ps
                 ON ps.usuario_id = v_uid AND ps.seccion_id = s.id
    ),
    -- Nº de preguntas por sección — se reutiliza tres veces (por
    -- sección, por módulo y por tema) así que lo calculamos una sola
    -- vez en un CTE.
    preg_por_secc AS (
        SELECT p.seccion_id, COUNT(*)::int AS n
          FROM preguntas p
         GROUP BY p.seccion_id
    )
    SELECT jsonb_build_object(
        'oposicion',
        (SELECT jsonb_build_object('id', o.id, 'nombre', o.nombre, 'descripcion', o.descripcion)
           FROM oposiciones o WHERE o.id = p_oposicion_id),
        'temas',
        COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id',           t.id,
                'nombre',       t.nombre,
                'slug',         t.slug,
                'orden',        ot.orden,
                'pct',          CASE
                    WHEN (SELECT COUNT(*) FROM secc_pct WHERE tema_id = t.id) = 0
                        THEN 0
                    ELSE round(100.0 * (SELECT COALESCE(SUM(completada),0) FROM secc_pct WHERE tema_id = t.id)
                                     / (SELECT COUNT(*)                 FROM secc_pct WHERE tema_id = t.id), 0)
                END,
                -- Nº total de preguntas del tema (todas las secciones,
                -- todos los módulos que cuelguen del tema).
                'preguntas_total',
                    COALESCE((
                        SELECT SUM(pps.n)::int
                          FROM secciones s
                          JOIN modulos m ON m.id = s.modulo_id
                          LEFT JOIN preg_por_secc pps ON pps.seccion_id = s.id
                         WHERE m.tema_id = t.id
                    ), 0),
                'modulos',
                COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                        'id',              m.id,
                        'nombre',          m.nombre,
                        'orden',           m.orden,
                        'es_unico',        m.es_unico,
                        'secciones_ok',    (SELECT COALESCE(SUM(completada),0)
                                              FROM secc_pct WHERE modulo_id = m.id),
                        'secciones_total', (SELECT COUNT(*)
                                              FROM secc_pct WHERE modulo_id = m.id),
                        -- Nº de preguntas del módulo.
                        'preguntas_total',
                            COALESCE((
                                SELECT SUM(pps.n)::int
                                  FROM secciones s
                                  LEFT JOIN preg_por_secc pps ON pps.seccion_id = s.id
                                 WHERE s.modulo_id = m.id
                            ), 0),
                        'secciones',
                        COALESCE((
                            SELECT jsonb_agg(jsonb_build_object(
                                'id',              s.id,
                                'nombre',          s.nombre,
                                'orden',           s.orden,
                                'nota_max',        sp.nota_max,
                                'completada',      sp.completada = 1,
                                'teoria_vista_en', sp.teoria_vista_en,
                                'preguntas_total', COALESCE(
                                    (SELECT n FROM preg_por_secc WHERE seccion_id = s.id), 0)
                            ) ORDER BY s.orden)
                              FROM secciones s
                              LEFT JOIN secc_pct sp ON sp.seccion_id = s.id
                             WHERE s.modulo_id = m.id
                        ), '[]'::jsonb)
                    ) ORDER BY m.orden)
                      FROM modulos m WHERE m.tema_id = t.id
                ), '[]'::jsonb)
            ) ORDER BY ot.orden)
              FROM temas t
              JOIN oposicion_temas ot ON ot.tema_id = t.id
             WHERE ot.oposicion_id = p_oposicion_id
        ), '[]'::jsonb)
    ) INTO v_res;

    RETURN v_res;
END $$;

GRANT EXECUTE ON FUNCTION mi_home_oposicion(uuid) TO web_user;
