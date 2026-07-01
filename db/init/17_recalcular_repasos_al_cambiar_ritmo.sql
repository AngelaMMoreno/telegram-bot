-- ============================================================================
-- 17_recalcular_repasos_al_cambiar_ritmo.sql
--
-- Cuando el usuario cambia su ritmo de repaso (intensivo/normal/relajado),
-- las fechas ya programadas en 'repasos' se recalculan al vuelo:
--
--   proximo_repaso = ultima_en + intervalo(caja, nuevo_ritmo)
--
-- De esta forma, si pasas de Normal a Intensivo, una pregunta en caja 3 que
-- tenías programada dentro de 7 días (Normal) queda reprogramada a 24 h
-- desde tu última respuesta (Intensivo). Si el nuevo cálculo cae en el
-- pasado, la fila aparece como vencida inmediatamente — justo lo que quieres
-- si acabas de apretar el ritmo antes de un examen.
-- ============================================================================

CREATE OR REPLACE FUNCTION set_ritmo_repaso(p_ritmo text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
BEGIN
    IF p_ritmo NOT IN ('intensivo','normal','relajado') THEN
        RAISE EXCEPTION 'ritmo_invalido';
    END IF;

    INSERT INTO preferencias_usuario(usuario_id, ritmo_repaso, actualizado_en)
    VALUES (v_uid, p_ritmo, now())
    ON CONFLICT (usuario_id) DO UPDATE
        SET ritmo_repaso   = EXCLUDED.ritmo_repaso,
            actualizado_en = now();

    UPDATE repasos
       SET proximo_repaso = ultima_en + intervalo_repaso(caja, p_ritmo)
     WHERE usuario_id = v_uid;

    RETURN jsonb_build_object('ritmo', p_ritmo);
END $$;

GRANT EXECUTE ON FUNCTION set_ritmo_repaso(text) TO web_user;
