-- ============================================================================
-- 18_repaso_derivar_proximo_al_vuelo.sql
--
-- Refactor: en lugar de materializar 'proximo_repaso' por fila, guardamos
-- únicamente la caja y la última respuesta y derivamos la fecha al vuelo
-- como:
--
--     proximo_repaso = ultima_en + intervalo(caja, ritmo_del_usuario)
--
-- Ventajas:
--   · Cambiar el ritmo (set_ritmo_repaso) deja de hacer UPDATE masivo: se
--     limita a escribir una fila en preferencias_usuario. La nueva cadencia
--     se ve reflejada en la siguiente consulta.
--   · No hay riesgo de que 'proximo_repaso' quede desincronizado del par
--     (caja, ritmo); la fuente de la verdad es única.
--
-- Cambio sutil de semántica en el fallo: hasta ahora, un fallo dejaba
-- 'proximo_repaso = now() + intervalo(1, ritmo)' (aparecía "hoy" pase lo
-- que pase con la caja). Ahora, para que un fallo siga viniendo con el
-- intervalo corto respetando la derivación, anclamos 'ultima_en' en
-- '(now() - intervalo(caja_final, ritmo))' de manera que la fecha derivada
-- sea 'now()' — vencida al instante. Esto preserva el comportamiento
-- observado desde fuera.
-- ============================================================================

-- ─────────────── Quitar columna materializada y su índice ──────────────────
DROP INDEX IF EXISTS repasos_vencidos_idx;
ALTER TABLE repasos DROP COLUMN IF EXISTS proximo_repaso;
CREATE INDEX IF NOT EXISTS repasos_usuario_idx ON repasos (usuario_id, ultima_en);

-- ─────────────── registrar_respuesta sin materializar la fecha ────────────

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
        -- Acierto adelantado: no cambia caja ni ultima_en (para no mover la
        -- fecha derivada); solo aumenta el contador de aciertos. Si no había
        -- fila previa (raro en un adelantamiento, pero por robustez), la
        -- creamos como un acierto normal.
        INSERT INTO repasos(usuario_id, pregunta_id, caja, aciertos, fallos, ultima_en)
        VALUES (v_uid, p_pregunta_id, 2, 1, 0, now())
        ON CONFLICT (usuario_id, pregunta_id) DO UPDATE
            SET aciertos = repasos.aciertos + 1;

    ELSIF p_correcta THEN
        -- Acierto normal: sube caja (techo 7) y ancla ultima_en = now().
        -- La fecha derivada será now() + intervalo(nueva_caja, ritmo_actual).
        SELECT LEAST(COALESCE(caja, 1) + 1, 7)
          INTO v_caja
          FROM repasos
         WHERE usuario_id = v_uid AND pregunta_id = p_pregunta_id;
        v_caja := COALESCE(v_caja, 2);

        INSERT INTO repasos(usuario_id, pregunta_id, caja, aciertos, fallos, ultima_en)
        VALUES (v_uid, p_pregunta_id, v_caja, 1, 0, now())
        ON CONFLICT (usuario_id, pregunta_id) DO UPDATE
            SET caja      = v_caja,
                aciertos  = repasos.aciertos + 1,
                ultima_en = now();

    ELSE
        -- Fallo: baja 2 cajas (suelo 1). Anclamos ultima_en en el pasado
        -- por exactamente el intervalo de la caja final, de modo que la
        -- fecha derivada (ultima_en + intervalo(caja_final, ritmo)) sea
        -- now(): la pregunta aparece vencida al instante, como antes.
        SELECT GREATEST(COALESCE(caja, 1) - 2, 1)
          INTO v_caja
          FROM repasos
         WHERE usuario_id = v_uid AND pregunta_id = p_pregunta_id;
        v_caja := COALESCE(v_caja, 1);
        v_intv := intervalo_repaso(v_caja, v_ritmo);

        INSERT INTO repasos(usuario_id, pregunta_id, caja, aciertos, fallos, ultima_en)
        VALUES (v_uid, p_pregunta_id, v_caja, 0, 1, now() - v_intv)
        ON CONFLICT (usuario_id, pregunta_id) DO UPDATE
            SET caja      = v_caja,
                fallos    = repasos.fallos + 1,
                ultima_en = now() - v_intv;
    END IF;
END $$;

GRANT EXECUTE ON FUNCTION registrar_respuesta(uuid, uuid, text, boolean, boolean)
    TO web_user;

-- ─────────────── set_ritmo_repaso: solo la preferencia, sin UPDATE masivo ──

CREATE OR REPLACE FUNCTION set_ritmo_repaso(p_ritmo text) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
    IF p_ritmo NOT IN ('intensivo','normal','relajado') THEN
        RAISE EXCEPTION 'ritmo_invalido';
    END IF;
    INSERT INTO preferencias_usuario(usuario_id, ritmo_repaso, actualizado_en)
    VALUES (jwt_usuario_id(), p_ritmo, now())
    ON CONFLICT (usuario_id) DO UPDATE
        SET ritmo_repaso   = EXCLUDED.ritmo_repaso,
            actualizado_en = now();
    RETURN jsonb_build_object('ritmo', p_ritmo);
END $$;

GRANT EXECUTE ON FUNCTION set_ritmo_repaso(text) TO web_user;

-- ─────────────── RPCs de resumen y de obtención con derivación al vuelo ────

CREATE OR REPLACE FUNCTION resumen_repaso_test(p_test_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_uid   uuid := jwt_usuario_id();
    v_ritmo text := ritmo_repaso_usuario(v_uid);
BEGIN
    RETURN (
        WITH q AS (
            SELECT r.caja,
                   r.ultima_en + intervalo_repaso(r.caja, v_ritmo) AS proximo_repaso
            FROM repasos r
            JOIN test_preguntas tp ON tp.pregunta_id = r.pregunta_id
            WHERE tp.test_id = p_test_id
              AND r.usuario_id = v_uid
        )
        SELECT jsonb_build_object(
            'total_repasos',  (SELECT count(*) FROM q),
            'vencidas',       (SELECT count(*) FROM q WHERE proximo_repaso <= now()),
            'dominadas',      (SELECT count(*) FROM q WHERE caja = 7),
            'siguiente',      (SELECT min(proximo_repaso) FROM q
                                WHERE proximo_repaso > now()),
            'test_realizado', EXISTS (
                SELECT 1 FROM intentos
                WHERE usuario_id = v_uid AND test_id = p_test_id
            )
        )
    );
END $$;

CREATE OR REPLACE FUNCTION resumen_repaso_global() RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_uid   uuid := jwt_usuario_id();
    v_ritmo text := ritmo_repaso_usuario(v_uid);
BEGIN
    RETURN (
        WITH q AS (
            SELECT r.caja,
                   r.ultima_en + intervalo_repaso(r.caja, v_ritmo) AS proximo_repaso
            FROM repasos r
            WHERE r.usuario_id = v_uid
              AND EXISTS (
                SELECT 1 FROM test_preguntas tp
                JOIN intentos i ON i.test_id = tp.test_id
                WHERE tp.pregunta_id = r.pregunta_id
                  AND i.usuario_id = r.usuario_id
              )
        )
        SELECT jsonb_build_object(
            'total_repasos', (SELECT count(*) FROM q),
            'vencidas',      (SELECT count(*) FROM q WHERE proximo_repaso <= now()),
            'dominadas',     (SELECT count(*) FROM q WHERE caja = 7),
            'siguiente',     (SELECT min(proximo_repaso) FROM q
                               WHERE proximo_repaso > now())
        )
    );
END $$;

CREATE OR REPLACE FUNCTION preguntas_repaso_test(
    p_test_id   uuid,
    p_n         int     DEFAULT 20,
    p_adelantar boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_uid    uuid := jwt_usuario_id();
    v_ritmo  text := ritmo_repaso_usuario(v_uid);
    v_titulo text;
    v_qs     jsonb;
BEGIN
    SELECT titulo INTO v_titulo FROM tests WHERE id = p_test_id;

    WITH pool AS (
        SELECT r.pregunta_id,
               r.caja,
               r.ultima_en + intervalo_repaso(r.caja, v_ritmo) AS proximo_repaso
        FROM repasos r
        JOIN test_preguntas tp ON tp.pregunta_id = r.pregunta_id
        WHERE tp.test_id = p_test_id
          AND r.usuario_id = v_uid
    ), filtro AS (
        SELECT * FROM pool
        WHERE p_adelantar OR proximo_repaso <= now()
        ORDER BY proximo_repaso ASC
        LIMIT GREATEST(p_n, 0)
    )
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id',   p.id,
            'text', p.enunciado,
            'options', (
                SELECT jsonb_agg(jsonb_build_object(
                    'text',      o.opt->>'texto',
                    'isCorrect', COALESCE((o.opt->>'correcta')::boolean, o.idx = 1)
                ) ORDER BY o.idx)
                FROM jsonb_array_elements(p.opciones) WITH ORDINALITY o(opt, idx)
            ),
            'explicacion', p.explicacion,
            'etiquetas',   p.etiquetas,
            'caja',        filtro.caja
        ) ORDER BY filtro.proximo_repaso ASC
    ), '[]'::jsonb)
    INTO v_qs
    FROM filtro
    JOIN preguntas p ON p.id = filtro.pregunta_id;

    RETURN jsonb_build_object(
        'quiz',       jsonb_build_object('id', p_test_id, 'title', v_titulo),
        'questions',  v_qs,
        'adelantada', p_adelantar
    );
END $$;

CREATE OR REPLACE FUNCTION preguntas_repaso_global(
    p_n         int     DEFAULT 20,
    p_adelantar boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_uid   uuid := jwt_usuario_id();
    v_ritmo text := ritmo_repaso_usuario(v_uid);
    v_qs    jsonb;
BEGIN
    WITH pool AS (
        SELECT r.pregunta_id,
               r.caja,
               r.ultima_en + intervalo_repaso(r.caja, v_ritmo) AS proximo_repaso
        FROM repasos r
        WHERE r.usuario_id = v_uid
          AND EXISTS (
            SELECT 1 FROM test_preguntas tp
            JOIN intentos i ON i.test_id = tp.test_id
            WHERE tp.pregunta_id = r.pregunta_id
              AND i.usuario_id = r.usuario_id
          )
    ), filtro AS (
        SELECT * FROM pool
        WHERE p_adelantar OR proximo_repaso <= now()
        ORDER BY proximo_repaso ASC
        LIMIT GREATEST(p_n, 0)
    )
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id',   p.id,
            'text', p.enunciado,
            'options', (
                SELECT jsonb_agg(jsonb_build_object(
                    'text',      o.opt->>'texto',
                    'isCorrect', COALESCE((o.opt->>'correcta')::boolean, o.idx = 1)
                ) ORDER BY o.idx)
                FROM jsonb_array_elements(p.opciones) WITH ORDINALITY o(opt, idx)
            ),
            'explicacion', p.explicacion,
            'etiquetas',   p.etiquetas,
            'caja',        filtro.caja
        ) ORDER BY filtro.proximo_repaso ASC
    ), '[]'::jsonb)
    INTO v_qs
    FROM filtro
    JOIN preguntas p ON p.id = filtro.pregunta_id;

    RETURN jsonb_build_object(
        'questions',  v_qs,
        'adelantada', p_adelantar
    );
END $$;

GRANT EXECUTE ON FUNCTION resumen_repaso_test(uuid)                  TO web_user;
GRANT EXECUTE ON FUNCTION resumen_repaso_global()                    TO web_user;
GRANT EXECUTE ON FUNCTION preguntas_repaso_test(uuid, int, boolean)  TO web_user;
GRANT EXECUTE ON FUNCTION preguntas_repaso_global(int, boolean)      TO web_user;
