-- ============================================================================
-- 15_backfill_repasos_caja_1.sql
--
-- Ajustes tras el primer despliegue del sistema de repaso espaciado (mig. 14):
--
-- 1) Cambia la caja inicial cuando el usuario acierta por primera vez una
--    pregunta que aún no está en 'repasos'. Antes: caja=2 (Leitner clásico,
--    "primer acierto ya te lo salta un escalón"). Ahora: caja=1, para que el
--    primer repaso caiga al intervalo más corto del ritmo (1 día en Normal)
--    en lugar de saltarse ese primer refuerzo.
--
-- 2) Backfill retroactivo: por cada (usuario, pregunta) con respuestas
--    históricas y sin fila en 'repasos', inserta caja=1 con
--    proximo_repaso=now() (vencida). Así, las preguntas que el usuario ya
--    respondió (antes de que el motor de cajas registrase nada) aparecen
--    inmediatamente disponibles para repasar.
--
-- 3) Reajuste de filas ya creadas: aquellas sin fallos (fallos = 0), se
--    resetean a caja=1 y proximo_repaso=now(). Esto alinea el comportamiento
--    anterior (arrancaban en caja=2) con la nueva regla, y responde a la
--    petición explícita de "quiero verlas ya en caja 1".
--
-- Migración idempotente: puede correrse varias veces sin efectos duplicados
-- gracias al ON CONFLICT DO NOTHING y a que el UPDATE es determinista.
-- ============================================================================

-- ─────────────── 1) Nueva regla en registrar_respuesta (caja inicial = 1) ──

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
        -- Sesión "Adelantar repaso": el acierto no cambia caja ni fecha.
        INSERT INTO repasos(usuario_id, pregunta_id, caja, aciertos, fallos,
                            ultima_en, proximo_repaso)
        VALUES (v_uid, p_pregunta_id, 1, 1, 0, now(),
                now() + intervalo_repaso(1, v_ritmo))
        ON CONFLICT (usuario_id, pregunta_id) DO UPDATE
            SET aciertos = repasos.aciertos + 1,
                ultima_en = now();

    ELSIF p_correcta THEN
        -- Acierto normal: sube caja (con techo en 7) y reprograma.
        -- IMPORTANTE: para preguntas nuevas (sin fila previa), la caja
        -- inicial pasa a ser 1 (antes era 2).
        SELECT LEAST(COALESCE(caja, 0) + 1, 7)
          INTO v_caja
          FROM repasos
         WHERE usuario_id = v_uid AND pregunta_id = p_pregunta_id;
        v_caja := COALESCE(v_caja, 1);  -- primer acierto → caja 1
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

-- ─────────────── 2) Backfill retroactivo desde respuestas ──────────────────
-- Solo inserta (no pisa) para cada (usuario, pregunta) que aún no tiene fila
-- en repasos. Cuenta aciertos y fallos históricos y deja la caja en 1 con
-- proximo_repaso=now() para que aparezcan como vencidas de inmediato.

INSERT INTO repasos (usuario_id, pregunta_id, caja, aciertos, fallos,
                     ultima_en, proximo_repaso)
SELECT
    i.usuario_id,
    r.pregunta_id,
    1                                                            AS caja,
    count(*) FILTER (WHERE r.correcta)::int                      AS aciertos,
    count(*) FILTER (WHERE NOT r.correcta)::int                  AS fallos,
    max(r.respondida_en)                                         AS ultima_en,
    now()                                                        AS proximo_repaso
FROM respuestas r
JOIN intentos   i ON i.id = r.intento_id
GROUP BY i.usuario_id, r.pregunta_id
ON CONFLICT (usuario_id, pregunta_id) DO NOTHING;

-- ─────────────── 3) Reajuste de filas ya creadas sin fallos ────────────────
-- Para las preguntas que ya estaban en repasos (creadas por la migración 14
-- durante el rodaje inicial) pero donde el usuario no ha fallado nunca, las
-- movemos a caja=1 y las ponemos como vencidas ahora, para que el usuario
-- las vea disponibles al pulsar "Repasar".

UPDATE repasos
   SET caja = 1,
       proximo_repaso = now()
 WHERE fallos = 0
   AND caja > 1;
