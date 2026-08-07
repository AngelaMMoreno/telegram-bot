-- =============================================================================
-- Amplía `obtener_oposicion(uuid)` para que devuelva también la fecha del
-- examen (con su flag de "orientativa") y las unidades completas dentro de
-- cada tema.  Necesario para la nueva vista "Mi oposición" del SPA
-- (#/oposicion), que muestra fecha del examen + listado colapsable de
-- temas con sus unidades.
--
-- La versión anterior devolvía sólo el número de unidades por tema.  No se
-- modifica ninguna tabla ni política — sólo se recrea la función.  Como es
-- `CREATE OR REPLACE`, no rompe ninguna instalación previa.
--
-- Cómo aplicar (sin reiniciar PostgREST ni el contenedor db):
--
--     docker exec -i db-desa psql -U aprentix -d aprentix_desa \
--         -f - < db/migrations/04_ampliar_obtener_oposicion.sql
--
-- El NOTIFY final fuerza al schema cache de PostgREST a releer las
-- funciones al instante.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION obtener_oposicion(p_oposicion_id uuid) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    WITH temas_agg AS (
        SELECT
            ot.orden,
            t.id AS tema_id,
            t.slug, t.nombre, t.descripcion, t.icono,
            (SELECT count(*) FROM unidades u WHERE u.tema_id = t.id) AS num_unidades,
            (SELECT COALESCE(sum(u.minutos_est), 0) FROM unidades u WHERE u.tema_id = t.id) AS minutos_est,
            (SELECT count(*)
               FROM unidades u
               JOIN progreso_unidad p ON p.unidad_id = u.id
              WHERE u.tema_id = t.id
                AND p.usuario_id = jwt_usuario_id()
                AND p.teoria_completada) AS unidades_hechas,
            -- Lista completa de unidades del tema para renderizar el
            -- desplegable en la vista "Mi oposición".
            (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                    'id',           u.id,
                    'slug',         u.slug,
                    'nombre',       u.nombre,
                    'orden',        u.orden,
                    'minutos_est',  u.minutos_est,
                    'num_preguntas',
                        (SELECT count(*) FROM preguntas p WHERE p.unidad_id = u.id)
                ) ORDER BY u.orden), '[]'::jsonb)
              FROM unidades u WHERE u.tema_id = t.id
            ) AS unidades
          FROM oposicion_temas ot
          JOIN temas t ON t.id = ot.tema_id
         WHERE ot.oposicion_id = p_oposicion_id
    )
    SELECT jsonb_build_object(
        'id',                        o.id,
        'slug',                      o.slug,
        'nombre',                    o.nombre,
        'descripcion',               o.descripcion,
        'organismo',                 o.organismo,
        'fecha_examen',              o.fecha_examen,
        'fecha_examen_orientativa',  o.fecha_examen_orientativa,
        'temas',       COALESCE(
                           (SELECT jsonb_agg(
                                jsonb_build_object(
                                    'id',              ta.tema_id,
                                    'slug',            ta.slug,
                                    'nombre',          ta.nombre,
                                    'descripcion',     ta.descripcion,
                                    'icono',           ta.icono,
                                    'orden',           ta.orden,
                                    'num_unidades',    ta.num_unidades,
                                    'minutos_est',     ta.minutos_est,
                                    'unidades_hechas', ta.unidades_hechas,
                                    'unidades',        ta.unidades
                                ) ORDER BY ta.orden
                            ) FROM temas_agg ta),
                           '[]'::jsonb
                       )
    )
    FROM oposiciones o WHERE o.id = p_oposicion_id;
$$;

-- La función ya está en el barrido `DO $grant_exec$` del 01_esquema.sql
-- (GRANT EXECUTE ON FUNCTION ... TO web_user).  El CREATE OR REPLACE
-- conserva los grants, pero por seguridad los volvemos a otorgar por si
-- este script se lanza en una BBDD que no tuviera el barrido aplicado.
GRANT EXECUTE ON FUNCTION obtener_oposicion(uuid) TO web_user;

COMMIT;

-- Fuerza a PostgREST a releer el schema cache al instante — sin esto
-- puede seguir sirviendo la firma antigua hasta el próximo reinicio.
NOTIFY pgrst, 'reload schema';
