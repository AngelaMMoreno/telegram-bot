-- ============================================================================
-- Delta 2026-07-03: Notificaciones de logros en tiempo real.
--
-- Extiende el motor de gamificación para que las RPCs que el frontend ya
-- llama al terminar una acción del usuario devuelvan también la lista de
-- LOGROS que se han desbloqueado en esa misma llamada.  El frontend usa esa
-- lista para pintar una notificación tipo tarjeta en la parte superior de
-- la app con la barra de progreso completándose en verde.
--
-- Cambios:
--   - _gamif_bump_logro ahora devuelve jsonb (los datos del logro recién
--     desbloqueado, o NULL si no ha habido desbloqueo).
--   - _gamif_on_respuesta / _gamif_on_test_finalizado / _gamif_on_fichero_visto
--     devuelven jsonb (array de logros desbloqueados en la llamada).
--   - registrar_respuesta / finalizar_intento / marcar_fichero_visto pasan a
--     devolver jsonb = { "logros_desbloqueados": [...] } en lugar de void.
--     PostgREST sirve el jsonb como cuerpo JSON de la respuesta; el JS lo
--     lee sin cambios de contrato.
--
-- Idempotente.  pgAdmin → Query Tool → F5.
-- ============================================================================

BEGIN;


-- ─── 0) Drops previos ──────────────────────────────────────────────────────
-- CREATE OR REPLACE no permite cambiar el tipo de retorno de una función
-- (void → jsonb), así que las tiramos primero.  Las que devuelven jsonb tras
-- este delta se recrean más abajo; el resto no se toca.
DROP FUNCTION IF EXISTS _gamif_bump_logro(uuid, text, int);
DROP FUNCTION IF EXISTS _gamif_actualizar_racha(uuid);
DROP FUNCTION IF EXISTS _gamif_on_respuesta(uuid, uuid, boolean, boolean, boolean, int, int, boolean);
DROP FUNCTION IF EXISTS _gamif_on_test_finalizado(uuid, uuid, text);
DROP FUNCTION IF EXISTS _gamif_on_fichero_visto(uuid, text);
DROP FUNCTION IF EXISTS registrar_respuesta(uuid, uuid, text, boolean, boolean);
DROP FUNCTION IF EXISTS finalizar_intento(uuid);
DROP FUNCTION IF EXISTS marcar_fichero_visto(text);


-- ─── 1) _gamif_bump_logro devuelve el logro recién desbloqueado ────────────
CREATE OR REPLACE FUNCTION _gamif_bump_logro(
    p_uid              uuid,
    p_codigo           text,
    p_progreso_nuevo   int
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_logro    logros_catalogo;
    v_prev     int;
    v_final    int;
    v_obtenido timestamptz;
BEGIN
    IF p_progreso_nuevo IS NULL OR p_progreso_nuevo <= 0 THEN RETURN NULL; END IF;

    SELECT * INTO v_logro FROM logros_catalogo
     WHERE codigo = p_codigo AND activo;
    IF v_logro.id IS NULL THEN RETURN NULL; END IF;

    INSERT INTO logros_usuario(usuario_id, logro_id, progreso)
    VALUES (p_uid, v_logro.id, 0)
    ON CONFLICT (usuario_id, logro_id) DO NOTHING;

    SELECT progreso, obtenido_en INTO v_prev, v_obtenido
      FROM logros_usuario
     WHERE usuario_id = p_uid AND logro_id = v_logro.id
     FOR UPDATE;

    IF v_obtenido IS NOT NULL THEN RETURN NULL; END IF;

    v_final := LEAST(GREATEST(v_prev, p_progreso_nuevo), v_logro.objetivo);

    UPDATE logros_usuario
       SET progreso    = v_final,
           obtenido_en = CASE WHEN v_final >= v_logro.objetivo THEN now() END
     WHERE usuario_id = p_uid AND logro_id = v_logro.id;

    IF v_final >= v_logro.objetivo AND v_prev < v_logro.objetivo THEN
        PERFORM _gamif_sumar_xp(p_uid, v_logro.xp);
        RETURN jsonb_build_object(
            'codigo',      v_logro.codigo,
            'titulo',      v_logro.titulo,
            'descripcion', v_logro.descripcion,
            'icono',       v_logro.icono,
            'xp',          v_logro.xp,
            'objetivo',    v_logro.objetivo,
            'progreso',    v_final
        );
    END IF;

    RETURN NULL;
END $$;


-- Helper local: acumula el resultado (posiblemente NULL) de un bump en un
-- array jsonb.  Mantiene el patrón "PERFORM bump" muy limpio en las
-- funciones on_*, que se limitan a llamar a _push(array, bump(...)).
CREATE OR REPLACE FUNCTION _gamif_push_logro(
    p_acc  jsonb,
    p_row  jsonb
) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_row IS NULL THEN p_acc
                ELSE COALESCE(p_acc, '[]'::jsonb) || jsonb_build_array(p_row) END;
$$;


-- ─── 1b) Racha ahora devuelve los logros de racha desbloqueados ───────────
-- Antes era void; ahora los three on_* usan su valor de retorno para
-- notificar 'primera_semana' y 'veterano_30' cuando toca.
CREATE OR REPLACE FUNCTION _gamif_actualizar_racha(p_uid uuid) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_hoy   date := hoy_madrid();
    v_prev  date;
    v_racha int;
    v_logros jsonb := '[]'::jsonb;
BEGIN
    SELECT ultimo_dia_activo, racha_actual
      INTO v_prev, v_racha
      FROM usuario_gamificacion WHERE usuario_id = p_uid;

    IF v_prev = v_hoy THEN
        RETURN v_logros; -- ya contó hoy
    END IF;

    IF v_prev = v_hoy - 1 THEN
        v_racha := COALESCE(v_racha, 0) + 1;
    ELSE
        v_racha := 1;
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

    v_logros := _gamif_push_logro(v_logros, _gamif_bump_logro(p_uid, 'primera_semana', v_racha));
    v_logros := _gamif_push_logro(v_logros, _gamif_bump_logro(p_uid, 'veterano_30',    v_racha));

    RETURN v_logros;
END $$;


-- ─── 2) Los tres on_* devuelven jsonb (array de logros desbloqueados) ──────

CREATE OR REPLACE FUNCTION _gamif_on_respuesta(
    p_uid         uuid,
    p_pregunta_id uuid,
    p_correcta    boolean,
    p_adelantada  boolean,
    p_es_repaso   boolean,
    p_caja_prev   int,
    p_caja_new    int,
    p_era_fallo   boolean
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_hoy          date := hoy_madrid();
    v_respondidas  int;
    v_correctas    int;
    v_totales      int;
    v_rescatados   int;
    v_domadas_hoy  int;
    v_logros       jsonb := '[]'::jsonb;
BEGIN
    -- Racha diaria (única fuente).  Devuelve los logros de racha desbloqueados.
    v_logros := COALESCE(_gamif_actualizar_racha(p_uid), '[]'::jsonb);

    -- ═══ Retos DIARIOS ═══════════════════════════════════════════════════
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

    IF p_correcta THEN
        PERFORM _gamif_bump_reto(p_uid, 'diario_racha_10_aciertos', 1);
    ELSE
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

    IF v_respondidas = 150 THEN
        PERFORM _gamif_bump_reto(p_uid, 'mensual_maraton_150', 1);
    END IF;

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

    -- ═══ LOGROS acumulativos (los que sí notificamos) ════════════════════
    SELECT count(*) INTO v_totales
      FROM respuestas r
      JOIN intentos i ON i.id = r.intento_id
     WHERE i.usuario_id = p_uid;
    v_logros := _gamif_push_logro(v_logros, _gamif_bump_logro(p_uid, 'centurion', v_totales));
    v_logros := _gamif_push_logro(v_logros, _gamif_bump_logro(p_uid, 'millar',    v_totales));
    v_logros := _gamif_push_logro(v_logros, _gamif_bump_logro(p_uid, 'decamil',   v_totales));

    IF p_correcta AND p_caja_new = 7 AND p_caja_prev IS NOT NULL AND p_caja_prev < 7 THEN
        v_logros := _gamif_push_logro(v_logros, _gamif_bump_logro(p_uid, 'primer_dominio', 1));
        SELECT count(*) INTO v_domadas_hoy
          FROM repasos WHERE usuario_id = p_uid AND caja = 7;
        v_logros := _gamif_push_logro(v_logros, _gamif_bump_logro(p_uid, 'dominador_100', v_domadas_hoy));
    END IF;

    IF p_correcta AND p_era_fallo THEN
        v_logros := _gamif_push_logro(v_logros, _gamif_bump_logro(p_uid, 'resiliente_10',
            COALESCE((SELECT progreso FROM logros_usuario lu
                        JOIN logros_catalogo lc ON lc.id = lu.logro_id
                       WHERE lu.usuario_id = p_uid AND lc.codigo = 'resiliente_10'), 0) + 1));
    END IF;

    RETURN v_logros;
END $$;


CREATE OR REPLACE FUNCTION _gamif_on_test_finalizado(
    p_uid      uuid,
    p_test_id  uuid,
    p_tipo     text
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_logros jsonb;
BEGIN
    v_logros := COALESCE(_gamif_actualizar_racha(p_uid), '[]'::jsonb);

    PERFORM _gamif_bump_reto(p_uid, 'diario_test_1', 1);
    PERFORM _gamif_bump_reto_distintos(p_uid, 'semanal_5_tests_distintos',
                                       p_test_id::text);

    IF p_tipo = 'simulacro' THEN
        PERFORM _gamif_bump_reto(p_uid, 'semanal_simulacro_1', 1);
    END IF;

    -- Solo logros de racha aquí (no hay logros vinculados a finalizar test),
    -- pero mantenemos el contrato jsonb para el frontend.
    RETURN v_logros;
END $$;


CREATE OR REPLACE FUNCTION _gamif_on_fichero_visto(
    p_uid  uuid,
    p_ruta text
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_distintos int;
    v_logros    jsonb;
BEGIN
    v_logros := COALESCE(_gamif_actualizar_racha(p_uid), '[]'::jsonb);

    PERFORM _gamif_bump_reto(p_uid, 'diario_teoria_1', 1);
    PERFORM _gamif_bump_reto_distintos(p_uid, 'semanal_teoria_3', p_ruta);

    SELECT count(*) INTO v_distintos
      FROM ficheros_vistas WHERE usuario_id = p_uid;
    v_logros := _gamif_push_logro(v_logros,
        _gamif_bump_logro(p_uid, 'explorador_teoria_10', v_distintos));

    RETURN v_logros;
END $$;


-- ─── 3) RPCs públicas: devuelven { logros_desbloqueados: [...] } ───────────

CREATE OR REPLACE FUNCTION registrar_respuesta(
    p_intento_id  uuid,
    p_pregunta_id uuid,
    p_texto       text,
    p_correcta    boolean,
    p_adelantada  boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_uid       uuid := jwt_usuario_id();
    v_ritmo     text;
    v_caja_new  int;
    v_caja_prev int;
    v_intv      interval;
    v_era_fallo boolean;
    v_es_repaso boolean;
    v_logros    jsonb;
BEGIN
    INSERT INTO respuestas(intento_id, pregunta_id, opcion_elegida, correcta)
    VALUES (p_intento_id, p_pregunta_id, p_texto, p_correcta);

    SELECT true INTO v_era_fallo
      FROM marcadores
     WHERE usuario_id = v_uid AND tipo = 'fallo' AND pregunta_id = p_pregunta_id;
    v_era_fallo := COALESCE(v_era_fallo, false);

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
        v_caja_new := COALESCE(v_caja_prev, 1);
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

    v_logros := _gamif_on_respuesta(
        v_uid, p_pregunta_id, p_correcta, p_adelantada,
        v_es_repaso, v_caja_prev, v_caja_new, v_era_fallo
    );

    RETURN jsonb_build_object('logros_desbloqueados', COALESCE(v_logros, '[]'::jsonb));
END $$;


CREATE OR REPLACE FUNCTION finalizar_intento(p_intento_id uuid) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_test_id uuid;
    v_uid     uuid;
    v_tipo    text;
    v_logros  jsonb;
BEGIN
    UPDATE intentos SET finalizado_en = now()
     WHERE id = p_intento_id AND finalizado_en IS NULL
     RETURNING test_id, usuario_id INTO v_test_id, v_uid;

    IF v_uid IS NULL OR v_test_id IS NULL THEN
        RETURN jsonb_build_object('logros_desbloqueados', '[]'::jsonb);
    END IF;

    SELECT tipo INTO v_tipo FROM tests WHERE id = v_test_id;
    v_logros := _gamif_on_test_finalizado(v_uid, v_test_id, COALESCE(v_tipo, 'manual'));

    RETURN jsonb_build_object('logros_desbloqueados', COALESCE(v_logros, '[]'::jsonb));
END $$;


CREATE OR REPLACE FUNCTION marcar_fichero_visto(p_ruta text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_uid       uuid := jwt_usuario_id();
    v_ya_estaba boolean;
    v_logros    jsonb := '[]'::jsonb;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;

    SELECT true INTO v_ya_estaba
      FROM ficheros_vistas WHERE usuario_id = v_uid AND ruta = p_ruta;

    INSERT INTO ficheros_vistas(usuario_id, ruta, vista_en)
    VALUES (v_uid, p_ruta, now())
    ON CONFLICT (usuario_id, ruta) DO UPDATE
        SET vista_en = EXCLUDED.vista_en;

    IF NOT COALESCE(v_ya_estaba, false) THEN
        v_logros := _gamif_on_fichero_visto(v_uid, p_ruta);
    END IF;

    RETURN jsonb_build_object('logros_desbloqueados', COALESCE(v_logros, '[]'::jsonb));
END $$;


-- Los GRANT EXECUTE se pierden al hacer DROP FUNCTION, así que hay que
-- concederlos de nuevo con la firma actual.
GRANT EXECUTE ON FUNCTION registrar_respuesta(uuid,uuid,text,boolean,boolean) TO web_user;
GRANT EXECUTE ON FUNCTION finalizar_intento(uuid)                             TO web_user;
GRANT EXECUTE ON FUNCTION marcar_fichero_visto(text)                          TO web_user;


-- ─── 4) Comprobación ──────────────────────────────────────────────────────
DO $$
DECLARE v_ok int;
BEGIN
    SELECT count(*) INTO v_ok FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'
       AND p.proname IN (
           '_gamif_bump_logro','_gamif_push_logro',
           '_gamif_on_respuesta','_gamif_on_test_finalizado','_gamif_on_fichero_visto',
           'registrar_respuesta','finalizar_intento','marcar_fichero_visto'
       )
       AND pg_get_function_result(p.oid) = 'jsonb';
    RAISE NOTICE 'funciones que devuelven jsonb: %/8', v_ok;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
