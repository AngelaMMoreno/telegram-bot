-- ============================================================================
-- Delta 2026-07-03: Gamificación.
--   - Retos diarios / semanales / mensuales con periodo en Europe/Madrid.
--   - Logros (hitos únicos, one-shot).
--   - XP, nivel y racha por usuario.
--   - Motor que se dispara desde registrar_respuesta, finalizar_intento y
--     marcar_fichero_visto (los 3 puntos donde el usuario "hace cosas").
--
-- Idempotente: se puede correr varias veces sin efectos duplicados.
-- Cómo aplicar: pgAdmin → Query Tool → F5.
-- ============================================================================

BEGIN;


-- ─── 1) Tablas ─────────────────────────────────────────────────────────────

-- Catálogo maestro de retos. El código es la clave estable que el motor usa
-- para saber qué regla aplicar; el resto son datos de presentación + umbral.
CREATE TABLE IF NOT EXISTS retos_catalogo (
    id           serial PRIMARY KEY,
    codigo       text UNIQUE NOT NULL,
    titulo       text NOT NULL,
    descripcion  text NOT NULL,
    periodo      text NOT NULL CHECK (periodo IN ('diario','semanal','mensual')),
    objetivo     int  NOT NULL CHECK (objetivo > 0),
    xp           int  NOT NULL DEFAULT 20 CHECK (xp >= 0),
    icono        text NOT NULL DEFAULT '🎯',
    activo       boolean NOT NULL DEFAULT true,
    creado_en    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS retos_catalogo_periodo_idx
    ON retos_catalogo (periodo) WHERE activo;

-- Progreso de cada usuario en cada reto para el periodo activo. La clave
-- lleva periodo_inicio para que la fila se "renueve" automáticamente al
-- cambiar de día/semana/mes sin necesidad de un cron: la UPSERT del motor
-- creará una fila nueva.
CREATE TABLE IF NOT EXISTS retos_usuario (
    usuario_id     uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    reto_id        int  NOT NULL REFERENCES retos_catalogo(id) ON DELETE CASCADE,
    periodo_inicio date NOT NULL,
    progreso       int  NOT NULL DEFAULT 0,
    completado_en  timestamptz,
    meta           jsonb NOT NULL DEFAULT '{}'::jsonb,
    actualizado_en timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (usuario_id, reto_id, periodo_inicio)
);
CREATE INDEX IF NOT EXISTS retos_usuario_uid_idx
    ON retos_usuario (usuario_id, periodo_inicio DESC);

-- Catálogo de logros (hitos únicos por vida del usuario).
CREATE TABLE IF NOT EXISTS logros_catalogo (
    id           serial PRIMARY KEY,
    codigo       text UNIQUE NOT NULL,
    titulo       text NOT NULL,
    descripcion  text NOT NULL,
    objetivo     int  NOT NULL DEFAULT 1 CHECK (objetivo > 0),
    xp           int  NOT NULL DEFAULT 100 CHECK (xp >= 0),
    icono        text NOT NULL DEFAULT '🏆',
    activo       boolean NOT NULL DEFAULT true,
    creado_en    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS logros_usuario (
    usuario_id  uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    logro_id    int  NOT NULL REFERENCES logros_catalogo(id) ON DELETE CASCADE,
    progreso    int  NOT NULL DEFAULT 0,
    obtenido_en timestamptz,
    PRIMARY KEY (usuario_id, logro_id)
);
CREATE INDEX IF NOT EXISTS logros_usuario_uid_idx ON logros_usuario (usuario_id);

-- Estado agregado del usuario: XP, nivel derivado, racha.
CREATE TABLE IF NOT EXISTS usuario_gamificacion (
    usuario_id       uuid PRIMARY KEY REFERENCES usuarios(id) ON DELETE CASCADE,
    xp_total         int  NOT NULL DEFAULT 0,
    racha_actual     int  NOT NULL DEFAULT 0,
    racha_maxima     int  NOT NULL DEFAULT 0,
    ultimo_dia_activo date,
    actualizado_en   timestamptz NOT NULL DEFAULT now()
);


-- ─── 2) RLS + GRANTS ───────────────────────────────────────────────────────

ALTER TABLE retos_catalogo        ENABLE ROW LEVEL SECURITY;
ALTER TABLE logros_catalogo       ENABLE ROW LEVEL SECURITY;
ALTER TABLE retos_usuario         ENABLE ROW LEVEL SECURITY;
ALTER TABLE logros_usuario        ENABLE ROW LEVEL SECURITY;
ALTER TABLE usuario_gamificacion  ENABLE ROW LEVEL SECURITY;

-- Catálogos: lectura pública para autenticados; escritura solo admin.
DROP POLICY IF EXISTS retos_cat_lectura ON retos_catalogo;
CREATE POLICY retos_cat_lectura ON retos_catalogo FOR SELECT
    USING (jwt_usuario_id() IS NOT NULL);
DROP POLICY IF EXISTS retos_cat_admin ON retos_catalogo;
CREATE POLICY retos_cat_admin ON retos_catalogo FOR ALL TO web_user
    USING (es_admin()) WITH CHECK (es_admin());

DROP POLICY IF EXISTS logros_cat_lectura ON logros_catalogo;
CREATE POLICY logros_cat_lectura ON logros_catalogo FOR SELECT
    USING (jwt_usuario_id() IS NOT NULL);
DROP POLICY IF EXISTS logros_cat_admin ON logros_catalogo;
CREATE POLICY logros_cat_admin ON logros_catalogo FOR ALL TO web_user
    USING (es_admin()) WITH CHECK (es_admin());

-- Progreso: cada uno el suyo; admin ve todo.
DROP POLICY IF EXISTS retos_usr_propios ON retos_usuario;
CREATE POLICY retos_usr_propios ON retos_usuario
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());

DROP POLICY IF EXISTS logros_usr_propios ON logros_usuario;
CREATE POLICY logros_usr_propios ON logros_usuario
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());

DROP POLICY IF EXISTS gamif_propia ON usuario_gamificacion;
CREATE POLICY gamif_propia ON usuario_gamificacion
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());

GRANT SELECT ON retos_catalogo, logros_catalogo TO web_user;
GRANT SELECT, INSERT, UPDATE, DELETE
    ON retos_usuario, logros_usuario, usuario_gamificacion TO web_user;
GRANT USAGE, SELECT ON SEQUENCE retos_catalogo_id_seq  TO web_user;
GRANT USAGE, SELECT ON SEQUENCE logros_catalogo_id_seq TO web_user;

ALTER TABLE retos_usuario        ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE logros_usuario       ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE usuario_gamificacion ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();


-- ─── 3) Helpers de fecha (Europe/Madrid) ───────────────────────────────────
-- Un solo sitio decide qué es "hoy" para retos y rachas. Cambia esta función
-- (y el config timezone_gamif si prefieres leerlo de ahí) para mover la zona
-- horaria de toda la gamificación.

CREATE OR REPLACE FUNCTION hoy_madrid() RETURNS date
LANGUAGE sql STABLE AS $$
    SELECT (now() AT TIME ZONE 'Europe/Madrid')::date;
$$;

CREATE OR REPLACE FUNCTION _gamif_periodo_inicio(p_periodo text) RETURNS date
LANGUAGE sql STABLE AS $$
    SELECT CASE p_periodo
        WHEN 'diario'  THEN hoy_madrid()
        WHEN 'semanal' THEN (date_trunc('week',  hoy_madrid()))::date
        WHEN 'mensual' THEN (date_trunc('month', hoy_madrid()))::date
    END;
$$;


-- ─── 4) Nivel derivado del XP ──────────────────────────────────────────────
-- Curva cuadrática suave: nivel N pide (N-1)^2 * 50 XP.
--   Nivel 1 → 0 XP     · Nivel 5 → 800 XP    · Nivel 10 → 4050 XP
--   Nivel 20 → 18050 XP · Nivel 30 → 42050 XP
CREATE OR REPLACE FUNCTION nivel_de_xp(p_xp int) RETURNS int
LANGUAGE sql IMMUTABLE AS $$
    SELECT GREATEST(1, floor(sqrt(GREATEST(p_xp, 0)::numeric / 50.0))::int + 1);
$$;

CREATE OR REPLACE FUNCTION xp_para_nivel(p_nivel int) RETURNS int
LANGUAGE sql IMMUTABLE AS $$
    SELECT (GREATEST(p_nivel, 1) - 1) * (GREATEST(p_nivel, 1) - 1) * 50;
$$;


-- ─── 5) Motor: helpers privados ────────────────────────────────────────────

-- Suma XP al total del usuario. Prefijo _ para señalar "interno".
CREATE OR REPLACE FUNCTION _gamif_sumar_xp(p_uid uuid, p_xp int) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF p_xp IS NULL OR p_xp = 0 THEN RETURN; END IF;
    INSERT INTO usuario_gamificacion(usuario_id, xp_total, actualizado_en)
    VALUES (p_uid, GREATEST(p_xp, 0), now())
    ON CONFLICT (usuario_id) DO UPDATE
        SET xp_total       = usuario_gamificacion.xp_total + EXCLUDED.xp_total,
            actualizado_en = now();
END $$;

-- Actualiza racha diaria. Se llama cuando el usuario "hace algo" ese día.
-- Solo cuenta una vez por día natural (Madrid); llamarla N veces no infla la
-- racha.
CREATE OR REPLACE FUNCTION _gamif_actualizar_racha(p_uid uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_hoy   date := hoy_madrid();
    v_prev  date;
    v_racha int;
BEGIN
    SELECT ultimo_dia_activo, racha_actual
      INTO v_prev, v_racha
      FROM usuario_gamificacion WHERE usuario_id = p_uid;

    IF v_prev = v_hoy THEN
        RETURN; -- ya contó hoy
    END IF;

    IF v_prev = v_hoy - 1 THEN
        v_racha := COALESCE(v_racha, 0) + 1;
    ELSE
        v_racha := 1; -- primera vez o rota
    END IF;

    INSERT INTO usuario_gamificacion(
        usuario_id, racha_actual, racha_maxima, ultimo_dia_activo, actualizado_en
    ) VALUES (
        p_uid, v_racha, v_racha, v_hoy, now()
    )
    ON CONFLICT (usuario_id) DO UPDATE
        SET racha_actual      = v_racha,
            racha_maxima      = GREATEST(usuario_gamificacion.racha_maxima, v_racha),
            ultimo_dia_activo = v_hoy,
            actualizado_en    = now();

    -- Logros de racha: comprueba con el nuevo valor.
    PERFORM _gamif_bump_logro(p_uid, 'primera_semana', v_racha);
    PERFORM _gamif_bump_logro(p_uid, 'veterano_30',    v_racha);
END $$;


-- Incrementa el progreso de un reto por código. Si el reto no existe o está
-- inactivo, no hace nada (silencioso, para poder tener seeds opcionales).
--
-- Comportamiento:
--   - Upsert de la fila para el periodo actual.
--   - progreso = LEAST(progreso + p_delta, objetivo).
--   - Si acaba de alcanzar el objetivo, marca completado_en=now() y suma XP.
--   - Un progreso negativo (p_delta<0) baja el contador pero nunca revierte
--     un reto ya completado (una vez ganado, ganado).
CREATE OR REPLACE FUNCTION _gamif_bump_reto(
    p_uid    uuid,
    p_codigo text,
    p_delta  int
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_reto      retos_catalogo;
    v_periodo   date;
    v_prev      int;
    v_new       int;
    v_completo  timestamptz;
BEGIN
    IF p_delta IS NULL OR p_delta = 0 THEN RETURN; END IF;

    SELECT * INTO v_reto FROM retos_catalogo
     WHERE codigo = p_codigo AND activo;
    IF v_reto.id IS NULL THEN RETURN; END IF;

    v_periodo := _gamif_periodo_inicio(v_reto.periodo);

    INSERT INTO retos_usuario(usuario_id, reto_id, periodo_inicio, progreso)
    VALUES (p_uid, v_reto.id, v_periodo, 0)
    ON CONFLICT (usuario_id, reto_id, periodo_inicio) DO NOTHING;

    SELECT progreso, completado_en INTO v_prev, v_completo
      FROM retos_usuario
     WHERE usuario_id = p_uid AND reto_id = v_reto.id
       AND periodo_inicio = v_periodo
     FOR UPDATE;

    IF v_completo IS NOT NULL THEN RETURN; END IF;

    v_new := LEAST(GREATEST(v_prev + p_delta, 0), v_reto.objetivo);

    UPDATE retos_usuario
       SET progreso        = v_new,
           completado_en   = CASE WHEN v_new >= v_reto.objetivo THEN now() END,
           actualizado_en  = now()
     WHERE usuario_id = p_uid AND reto_id = v_reto.id
       AND periodo_inicio = v_periodo;

    -- Si acaba de completarse, suma el XP.
    IF v_new >= v_reto.objetivo AND v_prev < v_reto.objetivo THEN
        PERFORM _gamif_sumar_xp(p_uid, v_reto.xp);
    END IF;
END $$;


-- Cuenta un elemento distinto (test_id / etiqueta / ruta) hacia un reto que
-- pide "N cosas distintas". Guarda el conjunto en meta.set (jsonb array).
CREATE OR REPLACE FUNCTION _gamif_bump_reto_distintos(
    p_uid    uuid,
    p_codigo text,
    p_elem   text
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_reto      retos_catalogo;
    v_periodo   date;
    v_set       jsonb;
    v_prev      int;
    v_completo  timestamptz;
BEGIN
    IF p_elem IS NULL OR length(p_elem) = 0 THEN RETURN; END IF;

    SELECT * INTO v_reto FROM retos_catalogo
     WHERE codigo = p_codigo AND activo;
    IF v_reto.id IS NULL THEN RETURN; END IF;

    v_periodo := _gamif_periodo_inicio(v_reto.periodo);

    INSERT INTO retos_usuario(usuario_id, reto_id, periodo_inicio, progreso, meta)
    VALUES (p_uid, v_reto.id, v_periodo, 0, jsonb_build_object('set', '[]'::jsonb))
    ON CONFLICT (usuario_id, reto_id, periodo_inicio) DO NOTHING;

    SELECT COALESCE(meta->'set', '[]'::jsonb), progreso, completado_en
      INTO v_set, v_prev, v_completo
      FROM retos_usuario
     WHERE usuario_id = p_uid AND reto_id = v_reto.id
       AND periodo_inicio = v_periodo
     FOR UPDATE;

    IF v_completo IS NOT NULL THEN RETURN; END IF;

    -- ¿ya está en el set?
    IF v_set ? p_elem THEN RETURN; END IF;

    v_set := v_set || to_jsonb(p_elem);
    v_prev := LEAST(v_prev + 1, v_reto.objetivo);

    UPDATE retos_usuario
       SET progreso       = v_prev,
           meta           = jsonb_set(meta, '{set}', v_set),
           completado_en  = CASE WHEN v_prev >= v_reto.objetivo THEN now() END,
           actualizado_en = now()
     WHERE usuario_id = p_uid AND reto_id = v_reto.id
       AND periodo_inicio = v_periodo;

    IF v_prev >= v_reto.objetivo THEN
        PERFORM _gamif_sumar_xp(p_uid, v_reto.xp);
    END IF;
END $$;


-- Igual que _gamif_bump_reto pero para logros (hitos únicos).
--   - Si es acumulativo (objetivo>1), sube al máximo entre lo que había y
--     p_progreso_nuevo (idempotente: pasar el valor absoluto de la métrica).
--   - Si es one-shot (objetivo=1), pasar p_progreso_nuevo=1 para desbloquear.
CREATE OR REPLACE FUNCTION _gamif_bump_logro(
    p_uid              uuid,
    p_codigo           text,
    p_progreso_nuevo   int
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_logro    logros_catalogo;
    v_prev     int;
    v_final    int;
    v_obtenido timestamptz;
BEGIN
    IF p_progreso_nuevo IS NULL OR p_progreso_nuevo <= 0 THEN RETURN; END IF;

    SELECT * INTO v_logro FROM logros_catalogo
     WHERE codigo = p_codigo AND activo;
    IF v_logro.id IS NULL THEN RETURN; END IF;

    INSERT INTO logros_usuario(usuario_id, logro_id, progreso)
    VALUES (p_uid, v_logro.id, 0)
    ON CONFLICT (usuario_id, logro_id) DO NOTHING;

    SELECT progreso, obtenido_en INTO v_prev, v_obtenido
      FROM logros_usuario
     WHERE usuario_id = p_uid AND logro_id = v_logro.id
     FOR UPDATE;

    IF v_obtenido IS NOT NULL THEN RETURN; END IF;

    v_final := LEAST(GREATEST(v_prev, p_progreso_nuevo), v_logro.objetivo);

    UPDATE logros_usuario
       SET progreso    = v_final,
           obtenido_en = CASE WHEN v_final >= v_logro.objetivo THEN now() END
     WHERE usuario_id = p_uid AND logro_id = v_logro.id;

    IF v_final >= v_logro.objetivo AND v_prev < v_logro.objetivo THEN
        PERFORM _gamif_sumar_xp(p_uid, v_logro.xp);
    END IF;
END $$;


-- ─── 6) Reglas de reto por evento ──────────────────────────────────────────

-- Se dispara al final de registrar_respuesta con toda la información del
-- evento (correcta, si venía de repaso, si era una pregunta ya fallada,
-- movimiento de caja). No consulta la BBDD para las cosas simples, así
-- añadir una respuesta cuesta O(nº retos activos) UPSERTs.
CREATE OR REPLACE FUNCTION _gamif_on_respuesta(
    p_uid         uuid,
    p_pregunta_id uuid,
    p_correcta    boolean,
    p_adelantada  boolean,
    p_es_repaso   boolean,
    p_caja_prev   int,
    p_caja_new    int,
    p_era_fallo   boolean
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_hoy          date := hoy_madrid();
    v_respondidas  int;
    v_correctas    int;
    v_totales      int;
    v_rescatados   int;
    v_domadas_hoy  int;
BEGIN
    -- Racha diaria (única fuente).
    PERFORM _gamif_actualizar_racha(p_uid);

    -- ═══ Retos DIARIOS ═══════════════════════════════════════════════════
    -- Contar respuestas del día para cascadas 30/60/100.
    PERFORM _gamif_bump_reto(p_uid, 'diario_responder_30',  1);
    PERFORM _gamif_bump_reto(p_uid, 'diario_responder_60',  1);
    PERFORM _gamif_bump_reto(p_uid, 'diario_responder_100', 1);

    IF p_es_repaso THEN
        PERFORM _gamif_bump_reto(p_uid, 'diario_repasar_15', 1);
    END IF;

    IF p_correcta AND p_era_fallo THEN
        PERFORM _gamif_bump_reto(p_uid, 'diario_rescatar_5', 1);
    END IF;

    IF p_correcta AND p_caja_new IS NOT NULL AND p_caja_prev IS NOT NULL
       AND p_caja_new > p_caja_prev THEN
        PERFORM _gamif_bump_reto(p_uid, 'diario_domar_5', 1);
    END IF;

    -- Racha de aciertos consecutivos del día.
    IF p_correcta THEN
        PERFORM _gamif_bump_reto(p_uid, 'diario_racha_10_aciertos', 1);
    ELSE
        -- Fallo: resetea a 0 (solo si aún no completado).
        UPDATE retos_usuario ru
           SET progreso = 0,
               actualizado_en = now()
          FROM retos_catalogo rc
         WHERE ru.reto_id = rc.id
           AND rc.codigo = 'diario_racha_10_aciertos'
           AND ru.usuario_id = p_uid
           AND ru.periodo_inicio = v_hoy
           AND ru.completado_en IS NULL;
    END IF;

    -- Acierto ≥80% del día (a partir de 20 respuestas). Se evalúa cada vez
    -- porque el ratio cambia con la próxima respuesta.
    SELECT count(*), count(*) FILTER (WHERE r.correcta)
      INTO v_respondidas, v_correctas
      FROM respuestas r
      JOIN intentos i ON i.id = r.intento_id
     WHERE i.usuario_id = p_uid
       AND (r.respondida_en AT TIME ZONE 'Europe/Madrid')::date = v_hoy;
    IF v_respondidas >= 20 AND v_correctas * 100 >= v_respondidas * 80 THEN
        PERFORM _gamif_bump_reto(p_uid, 'diario_acierto_80', 1);
    END IF;

    -- ═══ Retos SEMANALES/MENSUALES ═══════════════════════════════════════
    PERFORM _gamif_bump_reto(p_uid, 'semanal_responder_250',  1);
    PERFORM _gamif_bump_reto(p_uid, 'mensual_responder_1000', 1);

    IF p_correcta AND p_caja_new IS NOT NULL AND p_caja_new = 7
       AND p_caja_prev IS NOT NULL AND p_caja_prev < 7 THEN
        PERFORM _gamif_bump_reto(p_uid, 'mensual_dominar_20', 1);
    END IF;

    -- Maratón mensual: 1 día con ≥150 respuestas. Se completa cuando el
    -- contador diario alcanza 150 (comprobamos con v_respondidas ya arriba).
    IF v_respondidas = 150 THEN
        PERFORM _gamif_bump_reto(p_uid, 'mensual_maraton_150', 1);
    END IF;

    -- Media mensual ≥7/10 con ≥500 respuestas. Solo tiene sentido cuando el
    -- umbral de volumen se supera; no golpeamos BBDD hasta entonces.
    SELECT count(*), count(*) FILTER (WHERE r.correcta)
      INTO v_totales, v_correctas
      FROM respuestas r
      JOIN intentos i ON i.id = r.intento_id
     WHERE i.usuario_id = p_uid
       AND (r.respondida_en AT TIME ZONE 'Europe/Madrid')
           >= date_trunc('month', hoy_madrid())::timestamp;
    IF v_totales >= 500 AND v_correctas * 10 >= v_totales * 7 THEN
        PERFORM _gamif_bump_reto(p_uid, 'mensual_media_7', 1);
    END IF;

    -- ═══ LOGROS acumulativos ═════════════════════════════════════════════
    -- Respuestas totales de por vida: golpeamos BBDD una vez por respuesta,
    -- barato porque hay índice por intento_id + intentos_usuario_idx.
    SELECT count(*) INTO v_totales
      FROM respuestas r
      JOIN intentos i ON i.id = r.intento_id
     WHERE i.usuario_id = p_uid;
    PERFORM _gamif_bump_logro(p_uid, 'centurion',  v_totales);
    PERFORM _gamif_bump_logro(p_uid, 'millar',     v_totales);
    PERFORM _gamif_bump_logro(p_uid, 'decamil',    v_totales);

    IF p_correcta AND p_caja_new = 7 AND p_caja_prev IS NOT NULL AND p_caja_prev < 7 THEN
        PERFORM _gamif_bump_logro(p_uid, 'primer_dominio', 1);
        SELECT count(*) INTO v_domadas_hoy
          FROM repasos WHERE usuario_id = p_uid AND caja = 7;
        PERFORM _gamif_bump_logro(p_uid, 'dominador_100', v_domadas_hoy);
    END IF;

    IF p_correcta AND p_era_fallo THEN
        SELECT COALESCE(sum(contador), 0) INTO v_rescatados
          FROM marcadores WHERE usuario_id = p_uid AND tipo = 'fallo';
        -- Aproximación: el número de rescates de por vida no se guarda; en su
        -- lugar contamos el logro incrementalmente cada vez que ocurre.
        PERFORM _gamif_bump_logro(p_uid, 'resiliente_10',
            COALESCE((SELECT progreso FROM logros_usuario lu
                        JOIN logros_catalogo lc ON lc.id = lu.logro_id
                       WHERE lu.usuario_id = p_uid AND lc.codigo = 'resiliente_10'), 0) + 1);
    END IF;
END $$;


CREATE OR REPLACE FUNCTION _gamif_on_test_finalizado(
    p_uid      uuid,
    p_test_id  uuid,
    p_tipo     text
) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM _gamif_actualizar_racha(p_uid);

    PERFORM _gamif_bump_reto(p_uid, 'diario_test_1', 1);
    PERFORM _gamif_bump_reto_distintos(p_uid, 'semanal_5_tests_distintos',
                                       p_test_id::text);

    IF p_tipo = 'simulacro' THEN
        PERFORM _gamif_bump_reto(p_uid, 'semanal_simulacro_1', 1);
    END IF;
END $$;


CREATE OR REPLACE FUNCTION _gamif_on_fichero_visto(
    p_uid  uuid,
    p_ruta text
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_distintos int;
BEGIN
    PERFORM _gamif_actualizar_racha(p_uid);

    PERFORM _gamif_bump_reto(p_uid, 'diario_teoria_1', 1);
    PERFORM _gamif_bump_reto_distintos(p_uid, 'semanal_teoria_3', p_ruta);

    -- Logro: N documentos únicos vistos en toda la vida del usuario.
    SELECT count(*) INTO v_distintos
      FROM ficheros_vistas WHERE usuario_id = p_uid;
    PERFORM _gamif_bump_logro(p_uid, 'explorador_teoria_10', v_distintos);
END $$;


-- ─── 7) Enganche en las RPCs existentes ────────────────────────────────────

-- registrar_respuesta: mismos parámetros y comportamiento que antes, pero
-- ahora captura caja previa/nueva y si la pregunta estaba en la lista de
-- fallos, y dispara el motor de gamificación al final.
CREATE OR REPLACE FUNCTION registrar_respuesta(
    p_intento_id  uuid,
    p_pregunta_id uuid,
    p_texto       text,
    p_correcta    boolean,
    p_adelantada  boolean DEFAULT false
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_uid       uuid := jwt_usuario_id();
    v_ritmo     text;
    v_caja_new  int;
    v_caja_prev int;
    v_intv      interval;
    v_era_fallo boolean;
    v_es_repaso boolean;
BEGIN
    INSERT INTO respuestas(intento_id, pregunta_id, opcion_elegida, correcta)
    VALUES (p_intento_id, p_pregunta_id, p_texto, p_correcta);

    -- ¿La pregunta estaba en la lista de fallos ANTES de esta respuesta?
    SELECT true INTO v_era_fallo
      FROM marcadores
     WHERE usuario_id = v_uid AND tipo = 'fallo' AND pregunta_id = p_pregunta_id;
    v_era_fallo := COALESCE(v_era_fallo, false);

    -- ¿Existía ya un repaso para esta pregunta? (se considera "de repaso")
    SELECT caja INTO v_caja_prev
      FROM repasos WHERE usuario_id = v_uid AND pregunta_id = p_pregunta_id;
    v_es_repaso := v_caja_prev IS NOT NULL;

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
        v_caja_new := COALESCE(v_caja_prev, 1); -- sesión adelantada: no sube caja
        INSERT INTO repasos(usuario_id, pregunta_id, caja, aciertos, fallos, ultima_en)
        VALUES (v_uid, p_pregunta_id, 2, 1, 0, now())
        ON CONFLICT (usuario_id, pregunta_id) DO UPDATE
            SET aciertos = repasos.aciertos + 1;

    ELSIF p_correcta THEN
        v_caja_new := LEAST(COALESCE(v_caja_prev, 1) + 1, 7);
        IF v_caja_prev IS NULL THEN v_caja_new := 2; END IF;

        INSERT INTO repasos(usuario_id, pregunta_id, caja, aciertos, fallos, ultima_en)
        VALUES (v_uid, p_pregunta_id, v_caja_new, 1, 0, now())
        ON CONFLICT (usuario_id, pregunta_id) DO UPDATE
            SET caja      = v_caja_new,
                aciertos  = repasos.aciertos + 1,
                ultima_en = now();

    ELSE
        v_caja_new := GREATEST(COALESCE(v_caja_prev, 1) - 2, 1);
        v_intv := intervalo_repaso(v_caja_new, v_ritmo);

        INSERT INTO repasos(usuario_id, pregunta_id, caja, aciertos, fallos, ultima_en)
        VALUES (v_uid, p_pregunta_id, v_caja_new, 0, 1, now() - v_intv)
        ON CONFLICT (usuario_id, pregunta_id) DO UPDATE
            SET caja      = v_caja_new,
                fallos    = repasos.fallos + 1,
                ultima_en = now() - v_intv;
    END IF;

    -- Motor de retos + logros (no bloqueante en la práctica: solo UPSERTs).
    PERFORM _gamif_on_respuesta(
        v_uid, p_pregunta_id, p_correcta, p_adelantada,
        v_es_repaso, v_caja_prev, v_caja_new, v_era_fallo
    );
END $$;


-- finalizar_intento: al finalizar dispara los retos "un test terminado".
CREATE OR REPLACE FUNCTION finalizar_intento(p_intento_id uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_test_id uuid;
    v_uid     uuid;
    v_tipo    text;
BEGIN
    UPDATE intentos SET finalizado_en = now()
     WHERE id = p_intento_id AND finalizado_en IS NULL
     RETURNING test_id, usuario_id INTO v_test_id, v_uid;

    IF v_uid IS NULL OR v_test_id IS NULL THEN RETURN; END IF;

    SELECT tipo INTO v_tipo FROM tests WHERE id = v_test_id;
    PERFORM _gamif_on_test_finalizado(v_uid, v_test_id, COALESCE(v_tipo, 'manual'));
END $$;


-- marcar_fichero_visto: además de la marca, dispara los retos de teoría.
CREATE OR REPLACE FUNCTION marcar_fichero_visto(p_ruta text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_uid       uuid := jwt_usuario_id();
    v_ya_estaba boolean;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;

    SELECT true INTO v_ya_estaba
      FROM ficheros_vistas WHERE usuario_id = v_uid AND ruta = p_ruta;

    INSERT INTO ficheros_vistas(usuario_id, ruta, vista_en)
    VALUES (v_uid, p_ruta, now())
    ON CONFLICT (usuario_id, ruta) DO UPDATE
        SET vista_en = EXCLUDED.vista_en;

    -- Solo dispara el motor la primera vez que se marca este documento (una
    -- relectura del mismo PDF no debe contar como "otro documento" para el
    -- reto semanal ni para el logro de explorador).
    IF NOT COALESCE(v_ya_estaba, false) THEN
        PERFORM _gamif_on_fichero_visto(v_uid, p_ruta);
    END IF;
END $$;


-- ─── 8) RPCs públicas ──────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION mi_gamificacion() RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_uid  uuid := jwt_usuario_id();
    v_row  usuario_gamificacion;
    v_niv  int;
    v_next int;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;

    SELECT * INTO v_row FROM usuario_gamificacion WHERE usuario_id = v_uid;
    v_niv := nivel_de_xp(COALESCE(v_row.xp_total, 0));
    v_next := xp_para_nivel(v_niv + 1);

    RETURN jsonb_build_object(
        'xp_total',         COALESCE(v_row.xp_total, 0),
        'nivel',            v_niv,
        'xp_nivel_actual',  xp_para_nivel(v_niv),
        'xp_siguiente',     v_next,
        'racha_actual',     COALESCE(v_row.racha_actual, 0),
        'racha_maxima',     COALESCE(v_row.racha_maxima, 0),
        'ultimo_dia',       v_row.ultimo_dia_activo,
        'hoy_madrid',       hoy_madrid()
    );
END $$;

-- Retos ACTIVOS del usuario para el periodo actual (o desbloqueados en él).
-- Devuelve también el % de progreso y una marca de completado.
CREATE OR REPLACE FUNCTION mis_retos_activos() RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_uid uuid := jwt_usuario_id();
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;

    RETURN (
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'id',            rc.id,
            'codigo',        rc.codigo,
            'titulo',        rc.titulo,
            'descripcion',   rc.descripcion,
            'periodo',       rc.periodo,
            'objetivo',      rc.objetivo,
            'xp',            rc.xp,
            'icono',         rc.icono,
            'progreso',      COALESCE(ru.progreso, 0),
            'completado',    ru.completado_en IS NOT NULL,
            'completado_en', ru.completado_en,
            'periodo_inicio', _gamif_periodo_inicio(rc.periodo)
        ) ORDER BY CASE rc.periodo
                     WHEN 'diario'  THEN 0
                     WHEN 'semanal' THEN 1
                     WHEN 'mensual' THEN 2
                   END,
                   rc.xp), '[]'::jsonb)
        FROM retos_catalogo rc
        LEFT JOIN retos_usuario ru
               ON ru.reto_id = rc.id
              AND ru.usuario_id = v_uid
              AND ru.periodo_inicio = _gamif_periodo_inicio(rc.periodo)
        WHERE rc.activo
    );
END $$;

CREATE OR REPLACE FUNCTION mis_logros() RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE v_uid uuid := jwt_usuario_id();
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;

    RETURN (
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'id',           lc.id,
            'codigo',       lc.codigo,
            'titulo',       lc.titulo,
            'descripcion',  lc.descripcion,
            'objetivo',     lc.objetivo,
            'xp',           lc.xp,
            'icono',        lc.icono,
            'progreso',     COALESCE(lu.progreso, 0),
            'obtenido',     lu.obtenido_en IS NOT NULL,
            'obtenido_en',  lu.obtenido_en
        ) ORDER BY (lu.obtenido_en IS NOT NULL) DESC, lc.xp DESC), '[]'::jsonb)
        FROM logros_catalogo lc
        LEFT JOIN logros_usuario lu
               ON lu.logro_id = lc.id AND lu.usuario_id = v_uid
        WHERE lc.activo
    );
END $$;

GRANT EXECUTE ON FUNCTION hoy_madrid()                                     TO web_user, web_anon;
GRANT EXECUTE ON FUNCTION nivel_de_xp(int)                                 TO web_user, web_anon;
GRANT EXECUTE ON FUNCTION xp_para_nivel(int)                               TO web_user, web_anon;
GRANT EXECUTE ON FUNCTION mi_gamificacion()                                TO web_user;
GRANT EXECUTE ON FUNCTION mis_retos_activos()                              TO web_user;
GRANT EXECUTE ON FUNCTION mis_logros()                                     TO web_user;


-- ─── 9) SEED: retos y logros ───────────────────────────────────────────────

INSERT INTO retos_catalogo(codigo, titulo, descripcion, periodo, objetivo, xp, icono) VALUES
  -- DIARIOS (rápidos, XP moderada)
  ('diario_responder_30',       '30 preguntas',            'Responde 30 preguntas hoy',                           'diario', 30,  30, '💪'),
  ('diario_responder_60',       'A tope: 60 preguntas',    'Responde 60 preguntas hoy',                           'diario', 60,  50, '🔥'),
  ('diario_responder_100',      'Modo bestia',             '100 preguntas en un solo día',                        'diario', 100, 80, '🚀'),
  ('diario_test_1',             'Un test más',             'Termina al menos 1 test hoy',                         'diario', 1,   25, '📋'),
  ('diario_repasar_15',         'Repasa lo pendiente',     'Contesta 15 preguntas que ya tocaba repasar',         'diario', 15,  35, '🔁'),
  ('diario_rescatar_5',         'Rescata fallos',          'Acierta 5 preguntas que tenías falladas',             'diario', 5,   35, '🩹'),
  ('diario_domar_5',            'Doma preguntas',          'Sube de caja Leitner a 5 preguntas',                  'diario', 5,   30, '📈'),
  ('diario_teoria_1',           'Un rato de teoría',       'Marca al menos 1 documento de teoría como leído',     'diario', 1,   20, '📚'),
  ('diario_acierto_80',         'Puntería fina',           'Termina el día con ≥80% de acierto (mín. 20 resp.)',  'diario', 1,   40, '🎯'),
  ('diario_racha_10_aciertos',  '10 seguidas',             'Encadena 10 aciertos consecutivos',                   'diario', 10,  30, '⚡'),

  -- SEMANALES
  ('semanal_responder_250',     'Semana en marcha',        'Responde 250 preguntas esta semana',                  'semanal', 250, 120, '🏋️'),
  ('semanal_5_tests_distintos', '5 tests distintos',       'Termina 5 tests diferentes esta semana',              'semanal', 5,   150, '🗂️'),
  ('semanal_simulacro_1',       'Simulacro semanal',       'Haz al menos 1 simulacro completo',                   'semanal', 1,   150, '🧪'),
  ('semanal_teoria_3',          'Explorador de teoría',    'Lee 3 documentos distintos de teoría',                'semanal', 3,   100, '🗺️'),

  -- MENSUALES (recompensa gruesa)
  ('mensual_responder_1000',    'Kilómetro cero',          '1000 preguntas respondidas este mes',                 'mensual', 1000, 500, '🛤️'),
  ('mensual_dominar_20',        'Domador',                 'Lleva 20 preguntas a la caja 7 este mes',             'mensual', 20,   500, '👑'),
  ('mensual_maraton_150',       'Maratoniano',             'Un día del mes con ≥150 preguntas',                   'mensual', 1,    400, '🏃'),
  ('mensual_media_7',           'Consistencia 7/10',       'Media mensual ≥7 (mín. 500 respuestas)',              'mensual', 1,    600, '🎓')
ON CONFLICT (codigo) DO UPDATE
    SET titulo      = EXCLUDED.titulo,
        descripcion = EXCLUDED.descripcion,
        objetivo    = EXCLUDED.objetivo,
        xp          = EXCLUDED.xp,
        icono       = EXCLUDED.icono;

INSERT INTO logros_catalogo(codigo, titulo, descripcion, objetivo, xp, icono) VALUES
  ('primera_semana',       'Primera semana',      '7 días seguidos conectándote',        7,     200, '🌱'),
  ('veterano_30',          'Veterano',            '30 días seguidos: rutina de hierro',  30,    1000, '🌳'),
  ('centurion',            'Centurión',           '100 respuestas de por vida',          100,   100, '💯'),
  ('millar',               'Millar',              '1000 respuestas de por vida',         1000,  500, '🏵️'),
  ('decamil',              'Diez mil',            '10 000 respuestas de por vida',       10000, 2000, '🌟'),
  ('primer_dominio',       'Primera dominada',    'Llevas tu primera pregunta a caja 7', 1,     150, '🥇'),
  ('dominador_100',        'Dominador',           '100 preguntas en caja 7',             100,   750, '👑'),
  ('resiliente_10',        'Resiliente',          '10 fallos rescatados en total',       10,    150, '🩹'),
  ('explorador_teoria_10', 'Explorador de teoría','Lee 10 documentos distintos',         10,    200, '📖')
ON CONFLICT (codigo) DO UPDATE
    SET titulo      = EXCLUDED.titulo,
        descripcion = EXCLUDED.descripcion,
        objetivo    = EXCLUDED.objetivo,
        xp          = EXCLUDED.xp,
        icono       = EXCLUDED.icono;


-- ─── 10) Comprobación ──────────────────────────────────────────────────────
DO $$
DECLARE v_retos int; v_logros int; v_funcs int;
BEGIN
    SELECT count(*) INTO v_retos  FROM retos_catalogo  WHERE activo;
    SELECT count(*) INTO v_logros FROM logros_catalogo WHERE activo;
    SELECT count(*) INTO v_funcs FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN (
           '_gamif_actualizar_racha','_gamif_bump_reto','_gamif_bump_reto_distintos',
           '_gamif_bump_logro','_gamif_sumar_xp','_gamif_periodo_inicio',
           '_gamif_on_respuesta','_gamif_on_test_finalizado','_gamif_on_fichero_visto',
           'mi_gamificacion','mis_retos_activos','mis_logros',
           'hoy_madrid','nivel_de_xp','xp_para_nivel'
       );
    RAISE NOTICE 'retos activos:  %', v_retos;
    RAISE NOTICE 'logros activos: %', v_logros;
    RAISE NOTICE 'funciones gamif presentes: %/15', v_funcs;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
