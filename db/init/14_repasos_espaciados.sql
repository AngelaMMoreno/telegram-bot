-- ============================================================================
-- 14_repasos_espaciados.sql
-- Sistema de repaso espaciado (cajas Leitner con 3 ritmos).
--
-- Cada usuario tiene una fila por pregunta con la caja actual y la fecha del
-- próximo repaso. Acertar sube caja; fallar baja 2 cajas. Los intervalos por
-- caja dependen del "ritmo" elegido por el usuario (intensivo/normal/relajado),
-- que se lee de preferencias_usuario y se materializa desde config.
--
-- Además, registrar_respuesta pasa a aceptar un flag p_adelantada:
--   - false (por defecto): flujo normal; el acierto avanza caja/fecha.
--   - true: sesión adelantada; el acierto NO cambia caja/fecha (evita "farmear"
--           cajas). Los fallos sí penalizan siempre — un fallo es información
--           fiable adelantes o no.
--
-- La migración es idempotente: usa CREATE TABLE IF NOT EXISTS,
-- CREATE OR REPLACE, ON CONFLICT DO NOTHING/UPDATE y DROP FUNCTION previa
-- cuando cambia la firma.
-- ============================================================================

-- ─────────────── Preferencias de usuario (ritmo de repaso) ─────────────────

CREATE TABLE IF NOT EXISTS preferencias_usuario (
    usuario_id      uuid PRIMARY KEY REFERENCES usuarios(id) ON DELETE CASCADE,
    ritmo_repaso    text NOT NULL DEFAULT 'normal'
                     CHECK (ritmo_repaso IN ('intensivo','normal','relajado')),
    actualizado_en  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE preferencias_usuario ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pref_usuario_propio ON preferencias_usuario;
CREATE POLICY pref_usuario_propio ON preferencias_usuario
    FOR ALL TO web_user
    USING (usuario_id = jwt_usuario_id())
    WITH CHECK (usuario_id = jwt_usuario_id());

GRANT SELECT, INSERT, UPDATE, DELETE ON preferencias_usuario TO web_user;

-- ─────────────── Estado del motor de cajas por (usuario, pregunta) ──────────

CREATE TABLE IF NOT EXISTS repasos (
    usuario_id      uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    pregunta_id     uuid NOT NULL REFERENCES preguntas(id) ON DELETE CASCADE,
    caja            int  NOT NULL DEFAULT 1 CHECK (caja BETWEEN 1 AND 7),
    aciertos        int  NOT NULL DEFAULT 0,
    fallos          int  NOT NULL DEFAULT 0,
    ultima_en       timestamptz NOT NULL DEFAULT now(),
    proximo_repaso  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (usuario_id, pregunta_id)
);

CREATE INDEX IF NOT EXISTS repasos_vencidos_idx
    ON repasos (usuario_id, proximo_repaso);

ALTER TABLE repasos ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS repasos_propios ON repasos;
CREATE POLICY repasos_propios ON repasos
    FOR ALL TO web_user
    USING (usuario_id = jwt_usuario_id())
    WITH CHECK (usuario_id = jwt_usuario_id());

GRANT SELECT, INSERT, UPDATE, DELETE ON repasos TO web_user;

ALTER TABLE repasos ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();

-- ─────────────── Curvas por ritmo (horas por caja) ──────────────────────────
-- Intensivo: primera repetición 2h, luego crece rápido.
-- Normal:    Leitner clásico, en días.
-- Relajado:  mantenimiento; los intervalos crecen más lento a medio-largo.
-- Los valores están en horas para que quepan las fracciones de día del ritmo
-- intensivo sin tener que usar decimales.

INSERT INTO config(clave, valor) VALUES
    ('ritmos_repaso', jsonb_build_object(
        'intensivo', jsonb_build_array(2,   8,   24,  72,  168,  360,  720),
        'normal',    jsonb_build_array(24,  72,  168, 360, 720,  1440, 2880),
        'relajado',  jsonb_build_array(48, 168,  504, 1080, 2160, 4320, 8760)
    ))
ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor;

-- ─────────────── Helpers ────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION ritmo_repaso_usuario(p_usuario_id uuid)
RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT ritmo_repaso FROM preferencias_usuario WHERE usuario_id = p_usuario_id),
        'normal'
    );
$$;

-- Devuelve el intervalo hasta el próximo repaso para (caja, ritmo).
-- Si por algún motivo la caja se sale del array, coge el último valor.
CREATE OR REPLACE FUNCTION intervalo_repaso(p_caja int, p_ritmo text)
RETURNS interval
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_horas numeric;
    v_arr   jsonb;
    v_idx   int;
BEGIN
    v_arr := (SELECT valor->p_ritmo FROM config WHERE clave = 'ritmos_repaso');
    IF v_arr IS NULL THEN
        -- Fallback a 'normal' si el ritmo no existe.
        v_arr := (SELECT valor->'normal' FROM config WHERE clave = 'ritmos_repaso');
    END IF;
    v_idx := LEAST(GREATEST(p_caja, 1), jsonb_array_length(v_arr));
    v_horas := (v_arr->>(v_idx - 1))::numeric;
    RETURN make_interval(hours => v_horas::int);
END $$;

-- ─────────────── registrar_respuesta con flag "adelantada" ─────────────────
-- Mantenemos la firma antigua como wrapper para no romper llamadas viejas.
-- La nueva firma añade p_adelantada al final.

DROP FUNCTION IF EXISTS registrar_respuesta(uuid, uuid, text, boolean);

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
    -- 1) Registrar la respuesta cruda (histórico intacto).
    INSERT INTO respuestas(intento_id, pregunta_id, opcion_elegida, correcta)
    VALUES (p_intento_id, p_pregunta_id, p_texto, p_correcta);

    -- 2) Mantener 'marcadores' de fallo/acierto (compatibilidad hacia atrás
    --    con "Test de fallos" existente).
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

    -- 3) Motor de cajas.
    v_ritmo := ritmo_repaso_usuario(v_uid);

    IF p_correcta AND p_adelantada THEN
        -- Sesión "Adelantar repaso": el acierto no cambia caja ni fecha.
        -- Solo dejamos constancia (aciertos +1, ultima_en actualizado).
        INSERT INTO repasos(usuario_id, pregunta_id, caja, aciertos, fallos,
                            ultima_en, proximo_repaso)
        VALUES (v_uid, p_pregunta_id, 1, 1, 0, now(),
                now() + intervalo_repaso(1, v_ritmo))
        ON CONFLICT (usuario_id, pregunta_id) DO UPDATE
            SET aciertos = repasos.aciertos + 1,
                ultima_en = now();

    ELSIF p_correcta THEN
        -- Acierto normal: sube caja (con techo en 7) y reprograma.
        SELECT LEAST(COALESCE(caja, 1) + 1, 7)
          INTO v_caja
          FROM repasos
         WHERE usuario_id = v_uid AND pregunta_id = p_pregunta_id;
        v_caja := COALESCE(v_caja, 2);  -- si no existía fila, arranca en caja 2
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
GRANT EXECUTE ON FUNCTION ritmo_repaso_usuario(uuid) TO web_user;
GRANT EXECUTE ON FUNCTION intervalo_repaso(int, text) TO web_user;

-- ─────────────── RPCs de preferencia de ritmo ──────────────────────────────

CREATE OR REPLACE FUNCTION mi_ritmo_repaso() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'ritmo', ritmo_repaso_usuario(jwt_usuario_id()),
        'curvas', (SELECT valor FROM config WHERE clave = 'ritmos_repaso')
    );
$$;

CREATE OR REPLACE FUNCTION set_ritmo_repaso(p_ritmo text) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
    IF p_ritmo NOT IN ('intensivo','normal','relajado') THEN
        RAISE EXCEPTION 'ritmo_invalido';
    END IF;
    INSERT INTO preferencias_usuario(usuario_id, ritmo_repaso, actualizado_en)
    VALUES (jwt_usuario_id(), p_ritmo, now())
    ON CONFLICT (usuario_id) DO UPDATE
        SET ritmo_repaso = EXCLUDED.ritmo_repaso,
            actualizado_en = now();
    RETURN jsonb_build_object('ritmo', p_ritmo);
END $$;

GRANT EXECUTE ON FUNCTION mi_ritmo_repaso() TO web_user;
GRANT EXECUTE ON FUNCTION set_ritmo_repaso(text) TO web_user;

-- ─────────────── RPCs de resumen ────────────────────────────────────────────

-- Resumen para un test concreto. Devuelve conteos y la próxima fecha si no
-- hay vencidas ahora mismo (para el modal "Sin vencidas ahora mismo").
CREATE OR REPLACE FUNCTION resumen_repaso_test(p_test_id uuid) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    WITH q AS (
        SELECT r.*
        FROM repasos r
        JOIN test_preguntas tp ON tp.pregunta_id = r.pregunta_id
        WHERE tp.test_id = p_test_id
          AND r.usuario_id = jwt_usuario_id()
    )
    SELECT jsonb_build_object(
        'total_repasos',   (SELECT count(*) FROM q),
        'vencidas',        (SELECT count(*) FROM q WHERE proximo_repaso <= now()),
        'dominadas',       (SELECT count(*) FROM q WHERE caja = 7),
        'siguiente',       (SELECT min(proximo_repaso) FROM q
                             WHERE proximo_repaso > now()),
        'test_realizado',  EXISTS (
            SELECT 1 FROM intentos
            WHERE usuario_id = jwt_usuario_id() AND test_id = p_test_id
        )
    );
$$;

-- Resumen global (todos los tests que el usuario ha hecho al menos una vez).
CREATE OR REPLACE FUNCTION resumen_repaso_global() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    WITH q AS (
        SELECT r.*
        FROM repasos r
        WHERE r.usuario_id = jwt_usuario_id()
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
    );
$$;

GRANT EXECUTE ON FUNCTION resumen_repaso_test(uuid)  TO web_user;
GRANT EXECUTE ON FUNCTION resumen_repaso_global()    TO web_user;

-- ─────────────── RPCs de obtención de preguntas para repaso ────────────────

-- Devuelve preguntas de un test para repaso (formato compatible con el que
-- consume el frontend: {quiz:{id,title}, questions:[...]}).
--
--   p_test_id:   test a repasar
--   p_n:         número de preguntas deseadas
--   p_adelantar: si true, devuelve las más próximas a vencer aunque no lo
--                estén; si false, solo vencidas (hasta p_n).
CREATE OR REPLACE FUNCTION preguntas_repaso_test(
    p_test_id   uuid,
    p_n         int     DEFAULT 20,
    p_adelantar boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_titulo text;
    v_qs     jsonb;
BEGIN
    SELECT titulo INTO v_titulo FROM tests WHERE id = p_test_id;

    WITH pool AS (
        SELECT r.pregunta_id, r.proximo_repaso, r.caja
        FROM repasos r
        JOIN test_preguntas tp ON tp.pregunta_id = r.pregunta_id
        WHERE tp.test_id = p_test_id
          AND r.usuario_id = jwt_usuario_id()
          AND (p_adelantar OR r.proximo_repaso <= now())
        ORDER BY r.proximo_repaso ASC
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
            'caja',        pool.caja
        ) ORDER BY pool.proximo_repaso ASC
    ), '[]'::jsonb)
    INTO v_qs
    FROM pool
    JOIN preguntas p ON p.id = pool.pregunta_id;

    RETURN jsonb_build_object(
        'quiz',      jsonb_build_object('id', p_test_id, 'title', v_titulo),
        'questions', v_qs,
        'adelantada', p_adelantar
    );
END $$;

-- Repaso global: preguntas de cualquier test que el usuario haya hecho al
-- menos una vez. Filtrado por vencidas o próximas a vencer según p_adelantar.
CREATE OR REPLACE FUNCTION preguntas_repaso_global(
    p_n         int     DEFAULT 20,
    p_adelantar boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_qs jsonb;
BEGIN
    WITH pool AS (
        SELECT r.pregunta_id, r.proximo_repaso, r.caja
        FROM repasos r
        WHERE r.usuario_id = jwt_usuario_id()
          AND (p_adelantar OR r.proximo_repaso <= now())
          AND EXISTS (
            SELECT 1 FROM test_preguntas tp
            JOIN intentos i ON i.test_id = tp.test_id
            WHERE tp.pregunta_id = r.pregunta_id
              AND i.usuario_id = r.usuario_id
          )
        ORDER BY r.proximo_repaso ASC
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
            'caja',        pool.caja
        ) ORDER BY pool.proximo_repaso ASC
    ), '[]'::jsonb)
    INTO v_qs
    FROM pool
    JOIN preguntas p ON p.id = pool.pregunta_id;

    RETURN jsonb_build_object(
        'questions',  v_qs,
        'adelantada', p_adelantar
    );
END $$;

GRANT EXECUTE ON FUNCTION preguntas_repaso_test(uuid, int, boolean) TO web_user;
GRANT EXECUTE ON FUNCTION preguntas_repaso_global(int, boolean)     TO web_user;
