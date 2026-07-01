-- ============================================================================
-- 16_repasos_caja_por_historial.sql
--
-- Refinamiento del backfill de repasos:
--   · Preguntas con al menos un fallo histórico → caja 1, vencidas ahora
--     (necesitan repaso urgente).
--   · Preguntas sin ningún fallo → caja 2, con próximo repaso al intervalo
--     de caja 2 del ritmo de cada usuario (aciertos limpios ya demuestran
--     dominio inicial y no requieren revisión inmediata).
--
-- También revierte la caja inicial de registrar_respuesta a 2 (Leitner
-- clásico): un primer acierto en una pregunta nunca vista se considera
-- señal suficiente para saltar el escalón más agresivo.
-- ============================================================================

-- ─────────────── 1) registrar_respuesta con caja inicial 2 ─────────────────

CREATE OR REPLACE FUNCTION registrar_respuesta(
    p_intento_id  uuid,
    p_pregunta_id uuid,
    p_texto       text,
    p_correcta    boolean,
    p_adelantada  boolean DEFAULT false
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_uid    uuid := jwt_usuario_id();
    v_ritmo  text;
    v_caja   int;
    v_intv   interval;
BEGIN
    INSERT INTO respuestas(intento_id, pregunta_id, opcion_elegida, correcta)
    VALUES (p_intento_id, p_pregunta_id, p_texto, p_correcta);

    IF NOT p_correcta THEN
        INSERT INTO marcadores(usuario_id, tipo, pregunta_id, contador, actualizado_en)
        VALUES (v_uid, 'fallo', p_pregunta_id, 1, now())
        ON CONFLICT (usuario_id, tipo, COALESCE(pregunta_id, test_id))
        DO UPDATE SET contador = marcadores.contador + 1,
                       actualizado_en = now();
    ELSE
        DELETE FROM marcadores
         WHERE usuario_id = v_uid
           AND tipo = 'fallo'
           AND pregunta_id = p_pregunta_id;
    END IF;

    v_ritmo := ritmo_repaso_usuario(v_uid);

    IF p_correcta AND p_adelantada THEN
        INSERT INTO repasos(usuario_id, pregunta_id, caja, aciertos, fallos,
                            ultima_en, proximo_repaso)
        VALUES (v_uid, p_pregunta_id, 2, 1, 0, now(),
                now() + intervalo_repaso(2, v_ritmo))
        ON CONFLICT (usuario_id, pregunta_id) DO UPDATE
            SET aciertos = repasos.aciertos + 1,
                ultima_en = now();

    ELSIF p_correcta THEN
        -- Acierto normal: sube caja (con techo en 7) y reprograma.
        -- Para preguntas nuevas (sin fila previa), la caja inicial es 2:
        -- un primer acierto ya demuestra dominio inicial en Leitner clásico.
        SELECT LEAST(COALESCE(caja, 1) + 1, 7)
          INTO v_caja
          FROM repasos
         WHERE usuario_id = v_uid AND pregunta_id = p_pregunta_id;
        v_caja := COALESCE(v_caja, 2);  -- primer acierto → caja 2
        v_intv := intervalo_repaso(v_caja, v_ritmo);

        INSERT INTO repasos(usuario_id, pregunta_id, caja, aciertos, fallos,
                            ultima_en, proximo_repaso)
        VALUES (v_uid, p_pregunta_id, v_caja, 1, 0, now(), now() + v_intv)
        ON CONFLICT (usuario_id, pregunta_id) DO UPDATE
            SET caja = v_caja,
                aciertos = repasos.aciertos + 1,
                ultima_en = now(),
                proximo_repaso = now() + v_intv;

    ELSE
        -- Fallo: baja 2 cajas (con suelo en 1) y aparece hoy otra vez.
        SELECT GREATEST(COALESCE(caja, 1) - 2, 1)
          INTO v_caja
          FROM repasos
         WHERE usuario_id = v_uid AND pregunta_id = p_pregunta_id;
        v_caja := COALESCE(v_caja, 1);
        v_intv := intervalo_repaso(1, v_ritmo);

        INSERT INTO repasos(usuario_id, pregunta_id, caja, aciertos, fallos,
                            ultima_en, proximo_repaso)
        VALUES (v_uid, p_pregunta_id, v_caja, 0, 1, now(), now() + v_intv)
        ON CONFLICT (usuario_id, pregunta_id) DO UPDATE
            SET caja = v_caja,
                fallos = repasos.fallos + 1,
                ultima_en = now(),
                proximo_repaso = now() + v_intv;
    END IF;
END $$;

GRANT EXECUTE ON FUNCTION registrar_respuesta(uuid, uuid, text, boolean, boolean)
    TO web_user;

-- ─────────────── 2) Mover preguntas sin fallos históricos a caja 2 ─────────
-- Las que ya estaban en caja 1 sin fallos (tras la migración 15) se mueven a
-- caja 2 con próximo repaso al intervalo del ritmo del usuario. Las que
-- tienen fallos se quedan en caja 1 (siguen apareciendo como vencidas).

UPDATE repasos r
   SET caja = 2,
       proximo_repaso = now() + intervalo_repaso(2, ritmo_repaso_usuario(r.usuario_id))
 WHERE r.fallos = 0
   AND r.caja = 1;
