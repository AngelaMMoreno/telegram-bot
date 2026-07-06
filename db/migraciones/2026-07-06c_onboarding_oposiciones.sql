-- ============================================================================
-- Onboarding de oposiciones: RPCs para el primer inicio de sesión.
--
--   - oposiciones_publicas():          lista pública (nombre + descripcion)
--                                      de oposiciones activas. La usa la
--                                      landing en el picker de bienvenida.
--   - elegir_mis_oposiciones(uuid[]):  el propio usuario elige sus
--                                      oposiciones (máx 3, admins sin
--                                      límite). Sólo válida si el usuario
--                                      NO tiene ninguna asignada — evita
--                                      que amplíe o cambie sus permisos
--                                      por su cuenta más adelante.
--
-- Cómo:
--   pgAdmin → Query Tool → pega esto y F5. Idempotente.
-- ============================================================================

BEGIN;

-- ── oposiciones_publicas ──────────────────────────────────────────────────
-- Devuelve todas las oposiciones activas visibles para cualquier usuario
-- autenticado. NO expone flags de gestión ni número de tests/usuarios; es
-- el mínimo indispensable para pintar el picker del onboarding.
CREATE OR REPLACE FUNCTION oposiciones_publicas() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
BEGIN
    IF jwt_usuario_id() IS NULL THEN
        RAISE EXCEPTION 'no_autorizado';
    END IF;
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id',          o.id,
            'nombre',      o.nombre,
            'descripcion', o.descripcion
        ) ORDER BY o.nombre)
        FROM oposiciones o
        WHERE o.activa
    ), '[]'::jsonb);
END $$;

GRANT EXECUTE ON FUNCTION oposiciones_publicas() TO web_user;


-- ── elegir_mis_oposiciones ────────────────────────────────────────────────
-- El usuario elige sus oposiciones tras el primer login. Reglas:
--   * Sólo si aún NO tiene ninguna asignada (o si es admin).
--   * Los no-admin quedan capados a máximo 3.
--   * Todas las oposiciones referenciadas deben existir y estar activas.
-- Si el usuario ya tenía oposiciones asignadas, se lanza excepción para
-- que use el flujo administrativo normal.
CREATE OR REPLACE FUNCTION elegir_mis_oposiciones(p_oposicion_ids uuid[])
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_user   uuid := jwt_usuario_id();
    v_admin  boolean := es_admin();
    v_limite int := 3;
    v_ids    uuid[] := COALESCE(p_oposicion_ids, '{}'::uuid[]);
    v_n      int    := coalesce(array_length(v_ids, 1), 0);
BEGIN
    IF v_user IS NULL THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    IF v_n = 0 THEN RAISE EXCEPTION 'sin_seleccion'; END IF;

    -- Solo el primer onboarding: si ya tiene asignaciones, denegar.
    IF NOT v_admin AND EXISTS (
        SELECT 1 FROM usuario_oposiciones WHERE usuario_id = v_user
    ) THEN
        RAISE EXCEPTION 'ya_tiene_oposiciones';
    END IF;

    IF NOT v_admin AND v_n > v_limite THEN
        RAISE EXCEPTION 'demasiadas_oposiciones' USING HINT = format('Máximo %s', v_limite);
    END IF;

    -- Todas deben existir y estar activas.
    IF EXISTS (
        SELECT 1
        FROM UNNEST(v_ids) x(id)
        WHERE NOT EXISTS (SELECT 1 FROM oposiciones o
                          WHERE o.id = x.id AND o.activa)
    ) THEN
        RAISE EXCEPTION 'oposicion_no_valida';
    END IF;

    INSERT INTO usuario_oposiciones(usuario_id, oposicion_id)
    SELECT v_user, oid
    FROM UNNEST(v_ids) oid
    ON CONFLICT DO NOTHING;
END $$;

GRANT EXECUTE ON FUNCTION elegir_mis_oposiciones(uuid[]) TO web_user;

COMMIT;
