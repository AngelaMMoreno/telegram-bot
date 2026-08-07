-- =============================================================================
-- Migración 06 — cerrar_estudio() marca los bloques del plan como hechos
--
-- Bug: al terminar un modo estudio, aunque el usuario completara todos
-- los bloques (unidades + repasos) la tabla plan_sesiones NO se
-- actualizaba, así que en la vista Plan / Home los bloques del día
-- seguían apareciendo como pendientes.  Sólo se actualizaba XP.
--
-- Fix: al cerrar_estudio, iteramos los bloques REALMENTE procesados
-- (indices < sesion_activa.bloque_idx) y por cada uno:
--   - `estudio` con unidad_id → marcamos progreso_unidad.teoria_completada
--     = true y todas las plan_sesiones de HOY del usuario con esa unidad
--     como completadas.
--   - `repaso` → marcamos el primer plan_sesiones de HOY tipo 'repaso'
--     no completado como completado (LIFO por hora).
--   - `descanso` / `descanso_largo` / `final` → no marcan nada.
--
-- Idempotente: si vuelves a cerrar una sesión ya cerrada, no hay nada
-- que hacer (el DELETE FROM sesion_activa la borra) y las plan_sesiones
-- ya completadas se ignoran por el filtro.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION cerrar_estudio() RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_uid    uuid := jwt_usuario_id();
    v_s      sesion_activa;
    v_min    int;
    v_b      jsonb;
    v_i      int;
    v_uid_u  uuid;
    v_tipo   text;
    v_actual int := 0;
    v_ps_id  uuid;
BEGIN
    SELECT * INTO v_s FROM sesion_activa WHERE usuario_id = v_uid;
    IF v_s.usuario_id IS NULL THEN RETURN jsonb_build_object('ok', true); END IF;

    v_min := EXTRACT(EPOCH FROM (now() - v_s.iniciada_en))::int / 60;

    -- Marca como completados los bloques que sí llegaron a procesarse.
    -- v_s.bloque_idx apunta al bloque ACTUAL (0-based).  Consideramos
    -- procesados también el actual (el usuario acaba de terminarlo con
    -- "Siguiente" o dejando que el crono llegue a 0) — el bloque
    -- 'final' del array es un centinela que no marca nada.
    FOR v_i IN 0..LEAST(v_s.bloque_idx,
                         jsonb_array_length(v_s.plan_bloques) - 1) LOOP
        v_b    := v_s.plan_bloques -> v_i;
        v_tipo := v_b->>'tipo';
        IF v_tipo = 'final' THEN CONTINUE; END IF;

        IF v_tipo = 'estudio' AND v_b ? 'unidad_id' THEN
            v_uid_u := (v_b->>'unidad_id')::uuid;

            -- Marca la teoría como completada.
            INSERT INTO progreso_unidad(usuario_id, unidad_id,
                                        teoria_completada, teoria_vista_en)
            VALUES (v_uid, v_uid_u, true, now())
            ON CONFLICT (usuario_id, unidad_id) DO UPDATE
               SET teoria_completada = true,
                   teoria_vista_en   = COALESCE(progreso_unidad.teoria_vista_en, now());

            -- Marca cualquier plan_sesiones de HOY para esta unidad.
            UPDATE plan_sesiones ps
               SET completada    = true,
                   completada_en = now()
              FROM plan_estudio p
             WHERE ps.plan_id = p.id
               AND p.usuario_id = v_uid
               AND ps.fecha     = current_date
               AND ps.unidad_id = v_uid_u
               AND NOT ps.completada;

            v_actual := v_actual + 1;

        ELSIF v_tipo IN ('repaso', 'test') THEN
            -- Marca el primer plan_sesiones de HOY de ese tipo no
            -- completado — como los repasos no llevan unidad_id
            -- concreta, cerramos "el siguiente pendiente".
            SELECT ps.id INTO v_ps_id
              FROM plan_sesiones ps
              JOIN plan_estudio p ON p.id = ps.plan_id
             WHERE p.usuario_id = v_uid
               AND ps.fecha     = current_date
               AND ps.tipo      = v_tipo
               AND NOT ps.completada
             ORDER BY ps.hora_inicio NULLS LAST
             LIMIT 1;

            IF v_ps_id IS NOT NULL THEN
                UPDATE plan_sesiones
                   SET completada    = true,
                       completada_en = now()
                 WHERE id = v_ps_id;
                v_actual := v_actual + 1;
            END IF;
        END IF;
    END LOOP;

    DELETE FROM sesion_activa WHERE usuario_id = v_uid;

    -- Suma XP proporcional a los minutos activos reales.
    UPDATE usuario_gamificacion
       SET xp_total = xp_total + v_min,
           ultimo_dia_activo = current_date,
           actualizado_en = now()
     WHERE usuario_id = v_uid;

    RETURN jsonb_build_object(
        'ok', true,
        'minutos_totales',     v_min,
        'bloques_completados', v_s.bloque_idx,
        'plan_actualizados',   v_actual
    );
END $$;

GRANT EXECUTE ON FUNCTION cerrar_estudio() TO web_user;

COMMIT;

NOTIFY pgrst, 'reload schema';
