-- Fase 7: XP explícita al terminar un test (con desglose).
--
-- Antes solo se ganaba XP mediante retos y logros. Los usuarios no percibían
-- una recompensa proporcional al esfuerzo del propio test: no es lo mismo
-- terminar un test de 10 preguntas que uno de 90. Esta migración añade una
-- recompensa base al finalizar el intento, con bonos por volumen, calidad y
-- racha de aciertos.
--
-- Fórmula (todos los valores son enteros; el subtotal se suma a xp_total):
--
--   base          = 10 XP siempre que termines el intento
--   volumen       = 2 XP por pregunta respondida (30 preg → 60 XP, 90 → 180)
--   nota          = si nota_sobre_10 >= 8  →  +30 XP
--                   si nota_sobre_10 >= 9  →  +50 XP  (sustituye al anterior)
--                   si nota_sobre_10 == 10 → +80 XP  (idem)
--   racha_max     = por cada 5 aciertos consecutivos en el intento, +10 XP.
--                   Se calcula sobre respuestas ordenadas por respondida_en,
--                   así se recompensa "hacerlo bien seguidas veces".
--
-- Se pega al final del RPC finalizar_intento(): sigue disparando retos.
-- El desglose viaja de vuelta al cliente para poder pintarlo como toast.
--
-- Nota sobre idempotencia: llamamos a finalizar_intento con un intento ya
-- finalizado no debería duplicar XP. Nos apoyamos en que el UPDATE de
-- finalizado_en solo golpea filas con finalizado_en IS NULL — si no cambió
-- ninguna fila, no premiamos.

SET search_path = public;

-- ─── 1) Cálculo del desglose ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION _gamif_desglose_test(p_intento_id uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_total     int := 0;
    v_correctas int := 0;
    v_nota      numeric(4,2);
    v_racha_max int := 0;
    v_racha     int := 0;
    v_correcta  boolean;
    v_base      int := 10;
    v_volumen   int := 0;
    v_bono_nota int := 0;
    v_bono_racha int := 0;
BEGIN
    SELECT count(*), count(*) FILTER (WHERE correcta)
      INTO v_total, v_correctas
      FROM respuestas
     WHERE intento_id = p_intento_id;

    IF v_total = 0 THEN
        RETURN jsonb_build_object(
            'xp',       0,
            'base',     0,
            'volumen',  0,
            'nota',     0,
            'racha',    0,
            'total_preg', 0,
            'correctas', 0,
            'nota_sobre_10', 0
        );
    END IF;

    v_nota := round((v_correctas::numeric * 10) / v_total, 2);

    -- Racha máxima dentro del intento.
    FOR v_correcta IN
        SELECT correcta FROM respuestas
         WHERE intento_id = p_intento_id
         ORDER BY respondida_en, id
    LOOP
        IF v_correcta THEN
            v_racha := v_racha + 1;
            IF v_racha > v_racha_max THEN v_racha_max := v_racha; END IF;
        ELSE
            v_racha := 0;
        END IF;
    END LOOP;

    v_volumen := v_total * 2;

    -- Bono por nota: escalonado, se queda con el mejor tramo alcanzado.
    IF v_nota >= 10 THEN
        v_bono_nota := 80;
    ELSIF v_nota >= 9 THEN
        v_bono_nota := 50;
    ELSIF v_nota >= 8 THEN
        v_bono_nota := 30;
    END IF;

    v_bono_racha := (v_racha_max / 5) * 10;

    RETURN jsonb_build_object(
        'xp',            v_base + v_volumen + v_bono_nota + v_bono_racha,
        'base',          v_base,
        'volumen',       v_volumen,
        'nota',          v_bono_nota,
        'racha',         v_bono_racha,
        'racha_maxima',  v_racha_max,
        'total_preg',    v_total,
        'correctas',     v_correctas,
        'nota_sobre_10', v_nota
    );
END $$;


-- ─── 2) finalizar_intento: ahora devuelve el desglose de XP ───────────────
-- Cambia la firma de void → jsonb. PostgREST lo expone como el nuevo tipo de
-- retorno; el frontend leerá {xp, base, volumen, nota, racha, ...}.
DROP FUNCTION IF EXISTS finalizar_intento(uuid);

CREATE OR REPLACE FUNCTION finalizar_intento(p_intento_id uuid) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_test_id   uuid;
    v_uid       uuid;
    v_tipo      text;
    v_desglose  jsonb;
    v_xp        int;
BEGIN
    UPDATE intentos SET finalizado_en = now()
     WHERE id = p_intento_id AND finalizado_en IS NULL
     RETURNING test_id, usuario_id INTO v_test_id, v_uid;

    IF v_uid IS NULL OR v_test_id IS NULL THEN
        -- Intento ya finalizado o inexistente: no premiamos otra vez.
        RETURN jsonb_build_object('xp', 0, 'ya_finalizado', true);
    END IF;

    SELECT tipo INTO v_tipo FROM tests WHERE id = v_test_id;
    PERFORM _gamif_on_test_finalizado(v_uid, v_test_id, COALESCE(v_tipo, 'manual'));

    v_desglose := _gamif_desglose_test(p_intento_id);
    v_xp := COALESCE((v_desglose->>'xp')::int, 0);
    IF v_xp > 0 THEN
        PERFORM _gamif_sumar_xp(v_uid, v_xp);
    END IF;

    RETURN v_desglose;
END $$;

GRANT EXECUTE ON FUNCTION _gamif_desglose_test(uuid) TO web_user;
GRANT EXECUTE ON FUNCTION finalizar_intento(uuid)    TO web_user;
