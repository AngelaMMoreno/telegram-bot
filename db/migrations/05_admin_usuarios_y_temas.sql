-- =============================================================================
-- Migración 05 — Fix listado de usuarios en admin + reutilización de temas
--
-- Cambios:
--   1) admin_listar_usuarios() dejaba de listar filas en algunas
--      configuraciones porque el LIMIT quedaba FUERA del jsonb_agg,
--      lo que interactúa mal con la agregación implícita. Reescrita
--      con un CTE que filtra/ordena/limita ANTES de agregar.
--
--   2) Nueva RPC admin_temas_disponibles(p_oposicion_id) que devuelve
--      los temas del catálogo NO vinculados a la oposición dada. Sirve
--      para que el editor visual ofrezca reutilizar temas existentes
--      (además de crear nuevos), evitando duplicados en el catálogo.
--
--   3) Nueva RPC admin_vincular_tema(p_oposicion_id, p_tema_id) —
--      atajo que evita tener que pasar por admin_upsert_tema cuando
--      sólo queremos vincular un tema ya existente a una oposición.
--
-- Idempotente: sólo hace CREATE OR REPLACE de funciones.
--
-- Ejecución:
--   docker exec -i db-desa psql -U aprentix -d aprentix_desa \
--       < db/migrations/05_admin_usuarios_y_temas.sql
-- =============================================================================

BEGIN;

-- ── 1) Fix admin_listar_usuarios ────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_listar_usuarios(p_query text DEFAULT NULL,
                                                 p_limit int  DEFAULT 50)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    -- CTE con el filtro + orden + limit ANTES de la agregación. Sin él
    -- el LIMIT p_limit se aplicaba sobre el resultado ya agregado (1
    -- fila) y en algunos planners esto devolvía [] en lugar del array
    -- completo.
    WITH filtrados AS (
        SELECT u.id, u.email, u.nombre, u.email_verificado, u.activo,
               u.creado_en,
               (SELECT array_agg(rol_id ORDER BY rol_id)
                  FROM usuario_roles WHERE usuario_id = u.id) AS roles,
               (SELECT array_agg(o.nombre)
                  FROM usuario_oposiciones uo
                  JOIN oposiciones o ON o.id = uo.oposicion_id
                 WHERE uo.usuario_id = u.id) AS oposiciones
          FROM usuarios u
         WHERE es_admin()
           AND (p_query IS NULL OR p_query = '' OR
                u.email  ILIKE '%' || p_query || '%' OR
                u.nombre ILIKE '%' || p_query || '%')
         ORDER BY u.creado_en DESC
         LIMIT COALESCE(p_limit, 50)
    )
    SELECT COALESCE(jsonb_agg(row_to_json(f)::jsonb), '[]'::jsonb)
      FROM filtrados f;
$$;

GRANT EXECUTE ON FUNCTION admin_listar_usuarios(text, int) TO web_user;


-- ── 2) admin_temas_disponibles ──────────────────────────────────────────
-- Devuelve todos los temas del catálogo que NO están vinculados a la
-- oposición p_oposicion_id.  Usado por el editor para "Elegir tema
-- existente" (reutilización sin duplicar el tema en el catálogo).
CREATE OR REPLACE FUNCTION admin_temas_disponibles(p_oposicion_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id',            t.id,
        'slug',          t.slug,
        'nombre',        t.nombre,
        'icono',         t.icono,
        'descripcion',   t.descripcion,
        'num_unidades',  (SELECT count(*) FROM unidades u WHERE u.tema_id = t.id),
        -- En cuántas oposiciones está ya vinculado — informativo.
        'usado_en',      (SELECT count(*) FROM oposicion_temas ot2 WHERE ot2.tema_id = t.id)
    ) ORDER BY t.nombre), '[]'::jsonb)
      FROM temas t
     WHERE es_admin()
       AND NOT EXISTS (
           SELECT 1 FROM oposicion_temas ot
            WHERE ot.oposicion_id = p_oposicion_id
              AND ot.tema_id      = t.id
       );
$$;

GRANT EXECUTE ON FUNCTION admin_temas_disponibles(uuid) TO web_user;


-- ── 3) admin_vincular_tema (atajo) ──────────────────────────────────────
-- Vincula un tema existente a una oposición SIN tocar sus datos.  El
-- orden por defecto es el siguiente hueco al final.  Idempotente
-- (INSERT ... ON CONFLICT DO NOTHING).
CREATE OR REPLACE FUNCTION admin_vincular_tema(p_oposicion_id uuid,
                                               p_tema_id      uuid,
                                               p_orden        int DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_orden int;
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    v_orden := COALESCE(p_orden,
        (SELECT COALESCE(max(orden), 0) + 1
           FROM oposicion_temas WHERE oposicion_id = p_oposicion_id));
    INSERT INTO oposicion_temas(oposicion_id, tema_id, orden)
    VALUES (p_oposicion_id, p_tema_id, v_orden)
    ON CONFLICT (oposicion_id, tema_id) DO NOTHING;
    RETURN jsonb_build_object('ok', true, 'orden', v_orden);
END $$;

GRANT EXECUTE ON FUNCTION admin_vincular_tema(uuid, uuid, int) TO web_user;

COMMIT;

-- Fuerza a PostgREST a releer el schema al instante.
NOTIFY pgrst, 'reload schema';
