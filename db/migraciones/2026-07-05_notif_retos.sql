-- ============================================================================
-- Delta 2026-07-05: Notificar también los retos (no solo los logros).
--
-- El delta anterior (2026-07-03_logros_notificaciones.sql) hizo que
-- registrar_respuesta / finalizar_intento / marcar_fichero_visto devuelvan
-- `{ logros_desbloqueados: [...] }` — pero SOLO se incluían LOGROS (hitos
-- únicos vitalicios como "Centurión = 100 respuestas de por vida"). Los
-- RETOS (diarios/semanales/mensuales, típicamente los que un usuario ve
-- "completándose durante una sesión": 30 preguntas hoy, un test más, etc.)
-- se completaban en silencio.
--
-- Este delta:
--   - Hace que `_gamif_bump_reto` y `_gamif_bump_reto_distintos` devuelvan
--     un jsonb con los datos del reto SOLO cuando pasa de "no completado"
--     a "completado" en esta llamada (idempotente: un reto ya completado
--     no vuelve a notificar).
--   - Recrea los tres `_gamif_on_*` para acumular esas notificaciones en
--     el mismo array `logros_desbloqueados` que ya devuelven, marcándolas
--     con `tipo: 'reto'` para que el frontend las diferencie visualmente.
--
-- Idempotente. Se puede reaplicar. pgAdmin → Query Tool → F5.
-- ============================================================================

BEGIN;

-- ─── Drops previos ─────────────────────────────────────────────────────────
-- Cambia el tipo de retorno de void → jsonb: CREATE OR REPLACE no lo admite.
DROP FUNCTION IF EXISTS _gamif_bump_reto(uuid, text, int);
DROP FUNCTION IF EXISTS _gamif_bump_reto_distintos(uuid, text, text);
DROP FUNCTION IF EXISTS _gamif_on_respuesta(uuid, uuid, boolean, boolean, boolean, int, int, boolean);
DROP FUNCTION IF EXISTS _gamif_on_test_finalizado(uuid, uuid, text);
DROP FUNCTION IF EXISTS _gamif_on_fichero_visto(uuid, text);


-- ─── _gamif_bump_reto: devuelve el reto recién completado ─────────────────
CREATE OR REPLACE FUNCTION _gamif_bump_reto(
    p_uid       uuid,
    p_codigo    text,
    p_delta     int
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_reto    retos_catalogo;
    v_periodo date;
    v_prev    int;
    v_final   int;
BEGIN
    IF p_delta IS NULL OR p_delta = 0 THEN RETURN NULL; END IF;

    SELECT * INTO v_reto FROM retos_catalogo WHERE codigo = p_codigo AND activo;
    IF v_reto.id IS NULL THEN RETURN NULL; END IF;

    v_periodo := _gamif_periodo_inicio(v_reto.periodo);

    INSERT INTO retos_usuario(usuario_id, reto_id, periodo_inicio, progreso)
    VALUES (p_uid, v_reto.id, v_periodo, 0)
    ON CONFLICT (usuario_id, reto_id, periodo_inicio) DO NOTHING;

    SELECT progreso INTO v_prev
      FROM retos_usuario
     WHERE usuario_id = p_uid AND reto_id = v_reto.id AND periodo_inicio = v_periodo
     FOR UPDATE;

    v_final := LEAST(v_prev + p_delta, v_reto.objetivo);

    UPDATE retos_usuario
       SET progreso       = v_final,
           actualizado_en = now(),
           completado_en  = CASE WHEN v_final >= v_reto.objetivo
                                  AND completado_en IS NULL THEN now()
                                 ELSE completado_en END
     WHERE usuario_id = p_uid AND reto_id = v_reto.id AND periodo_inicio = v_periodo;

    -- Solo notifica y suma XP en el *primer* cruce del umbral, para no
    -- disparar N tarjetas si el motor vuelve a llamar tras el completado.
    IF v_final >= v_reto.objetivo AND v_prev < v_reto.objetivo THEN
        PERFORM _gamif_sumar_xp(p_uid, v_reto.xp);
        RETURN jsonb_build_object(
            'tipo',        'reto',
            'codigo',      v_reto.codigo,
            'titulo',      v_reto.titulo,
            'descripcion', v_reto.descripcion,
            'icono',       v_reto.icono,
            'xp',          v_reto.xp,
            'objetivo',    v_reto.objetivo,
            'progreso',    v_final,
            'periodo',     v_reto.periodo
        );
    END IF;

    RETURN NULL;
END $$;


-- ─── _gamif_bump_reto_distintos: idem, contando elementos únicos ──────────
-- Guarda en meta.items[] los identificadores ya vistos para evitar contarlos
-- dos veces (p.ej. el mismo test terminado dos veces en la misma semana no
-- suma dos al reto "5 tests distintos").
CREATE OR REPLACE FUNCTION _gamif_bump_reto_distintos(
    p_uid    uuid,
    p_codigo text,
    p_item   text
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_reto    retos_catalogo;
    v_periodo date;
    v_meta    jsonb;
    v_items   jsonb;
    v_prev    int;
    v_final   int;
BEGIN
    IF p_item IS NULL OR length(p_item) = 0 THEN RETURN NULL; END IF;

    SELECT * INTO v_reto FROM retos_catalogo WHERE codigo = p_codigo AND activo;
    IF v_reto.id IS NULL THEN RETURN NULL; END IF;

    v_periodo := _gamif_periodo_inicio(v_reto.periodo);

    INSERT INTO retos_usuario(usuario_id, reto_id, periodo_inicio, progreso, meta)
    VALUES (p_uid, v_reto.id, v_periodo, 0, jsonb_build_object('items', '[]'::jsonb))
    ON CONFLICT (usuario_id, reto_id, periodo_inicio) DO NOTHING;

    SELECT progreso, meta INTO v_prev, v_meta
      FROM retos_usuario
     WHERE usuario_id = p_uid AND reto_id = v_reto.id AND periodo_inicio = v_periodo
     FOR UPDATE;

    v_items := COALESCE(v_meta->'items', '[]'::jsonb);
    IF v_items @> to_jsonb(p_item) THEN
        RETURN NULL;  -- ya contado en este periodo
    END IF;

    v_items := v_items || to_jsonb(p_item);
    v_final := LEAST(v_prev + 1, v_reto.objetivo);

    UPDATE retos_usuario
       SET progreso       = v_final,
           meta           = jsonb_set(COALESCE(v_meta, '{}'::jsonb), '{items}', v_items),
           actualizado_en = now(),
           completado_en  = CASE WHEN v_final >= v_reto.objetivo
                                  AND completado_en IS NULL THEN now()
                                 ELSE completado_en END
     WHERE usuario_id = p_uid AND reto_id = v_reto.id AND periodo_inicio = v_periodo;

    IF v_final >= v_reto.objetivo AND v_prev < v_reto.objetivo THEN
        PERFORM _gamif_sumar_xp(p_uid, v_reto.xp);
        RETURN jsonb_build_object(
            'tipo',        'reto',
            'codigo',      v_reto.codigo,
            'titulo',      v_reto.titulo,
            'descripcion', v_reto.descripcion,
            'icono',       v_reto.icono,
            'xp',          v_reto.xp,
            'objetivo',    v_reto.objetivo,
            'progreso',    v_final,
            'periodo',     v_reto.periodo
        );
    END IF;

    RETURN NULL;
END $$;


-- ─── on_respuesta: acumula retos + logros en el mismo array ───────────────
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
    v_domadas_hoy  int;
    v_notif        jsonb := '[]'::jsonb;
BEGIN
    v_notif := COALESCE(_gamif_actualizar_racha(p_uid), '[]'::jsonb);

    v_notif := _gamif_push_logro(v_notif, _gamif_bump_reto(p_uid, 'diario_responder_30',  1));
    v_notif := _gamif_push_logro(v_notif, _gamif_bump_reto(p_uid, 'diario_responder_60',  1));
    v_notif := _gamif_push_logro(v_notif, _gamif_bump_reto(p_uid, 'diario_responder_100', 1));

    IF p_es_repaso THEN
        v_notif := _gamif_push_logro(v_notif, _gamif_bump_reto(p_uid, 'diario_repasar_15', 1));
    END IF;

    IF p_correcta AND p_era_fallo THEN
        v_notif := _gamif_push_logro(v_notif, _gamif_bump_reto(p_uid, 'diario_rescatar_5', 1));
    END IF;

    IF p_correcta AND p_caja_new IS NOT NULL AND p_caja_prev IS NOT NULL
       AND p_caja_new > p_caja_prev THEN
        v_notif := _gamif_push_logro(v_notif, _gamif_bump_reto(p_uid, 'diario_domar_5', 1));
    END IF;

    IF p_correcta THEN
        v_notif := _gamif_push_logro(v_notif, _gamif_bump_reto(p_uid, 'diario_racha_10_aciertos', 1));
    ELSE
        UPDATE retos_usuario ru
           SET progreso = 0, actualizado_en = now()
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
        v_notif := _gamif_push_logro(v_notif, _gamif_bump_reto(p_uid, 'diario_acierto_80', 1));
    END IF;

    v_notif := _gamif_push_logro(v_notif, _gamif_bump_reto(p_uid, 'semanal_responder_250',  1));
    v_notif := _gamif_push_logro(v_notif, _gamif_bump_reto(p_uid, 'mensual_responder_1000', 1));

    IF p_correcta AND p_caja_new IS NOT NULL AND p_caja_new = 7
       AND p_caja_prev IS NOT NULL AND p_caja_prev < 7 THEN
        v_notif := _gamif_push_logro(v_notif, _gamif_bump_reto(p_uid, 'mensual_dominar_20', 1));
    END IF;

    IF v_respondidas = 150 THEN
        v_notif := _gamif_push_logro(v_notif, _gamif_bump_reto(p_uid, 'mensual_maraton_150', 1));
    END IF;

    SELECT count(*), count(*) FILTER (WHERE r.correcta)
      INTO v_totales, v_correctas
      FROM respuestas r
      JOIN intentos i ON i.id = r.intento_id
     WHERE i.usuario_id = p_uid
       AND (r.respondida_en AT TIME ZONE 'Europe/Madrid')
           >= date_trunc('month', hoy_madrid())::timestamp;
    IF v_totales >= 500 AND v_correctas * 10 >= v_totales * 7 THEN
        v_notif := _gamif_push_logro(v_notif, _gamif_bump_reto(p_uid, 'mensual_media_7', 1));
    END IF;

    -- ═══ LOGROS acumulativos ════════════════════════════════════════════
    SELECT count(*) INTO v_totales
      FROM respuestas r
      JOIN intentos i ON i.id = r.intento_id
     WHERE i.usuario_id = p_uid;
    v_notif := _gamif_push_logro(v_notif, _gamif_bump_logro(p_uid, 'centurion', v_totales));
    v_notif := _gamif_push_logro(v_notif, _gamif_bump_logro(p_uid, 'millar',    v_totales));
    v_notif := _gamif_push_logro(v_notif, _gamif_bump_logro(p_uid, 'decamil',   v_totales));

    IF p_correcta AND p_caja_new = 7 AND p_caja_prev IS NOT NULL AND p_caja_prev < 7 THEN
        v_notif := _gamif_push_logro(v_notif, _gamif_bump_logro(p_uid, 'primer_dominio', 1));
        SELECT count(*) INTO v_domadas_hoy
          FROM repasos WHERE usuario_id = p_uid AND caja = 7;
        v_notif := _gamif_push_logro(v_notif, _gamif_bump_logro(p_uid, 'dominador_100', v_domadas_hoy));
    END IF;

    IF p_correcta AND p_era_fallo THEN
        v_notif := _gamif_push_logro(v_notif, _gamif_bump_logro(p_uid, 'resiliente_10',
            COALESCE((SELECT progreso FROM logros_usuario lu
                        JOIN logros_catalogo lc ON lc.id = lu.logro_id
                       WHERE lu.usuario_id = p_uid AND lc.codigo = 'resiliente_10'), 0) + 1));
    END IF;

    RETURN v_notif;
END $$;


CREATE OR REPLACE FUNCTION _gamif_on_test_finalizado(
    p_uid      uuid,
    p_test_id  uuid,
    p_tipo     text
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_notif jsonb;
BEGIN
    v_notif := COALESCE(_gamif_actualizar_racha(p_uid), '[]'::jsonb);

    v_notif := _gamif_push_logro(v_notif, _gamif_bump_reto(p_uid, 'diario_test_1', 1));
    v_notif := _gamif_push_logro(v_notif, _gamif_bump_reto_distintos(
        p_uid, 'semanal_5_tests_distintos', p_test_id::text));

    IF p_tipo = 'simulacro' THEN
        v_notif := _gamif_push_logro(v_notif, _gamif_bump_reto(p_uid, 'semanal_simulacro_1', 1));
    END IF;

    RETURN v_notif;
END $$;


CREATE OR REPLACE FUNCTION _gamif_on_fichero_visto(
    p_uid  uuid,
    p_ruta text
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_distintos int;
    v_notif     jsonb;
BEGIN
    v_notif := COALESCE(_gamif_actualizar_racha(p_uid), '[]'::jsonb);

    v_notif := _gamif_push_logro(v_notif, _gamif_bump_reto(p_uid, 'diario_teoria_1', 1));
    v_notif := _gamif_push_logro(v_notif, _gamif_bump_reto_distintos(p_uid, 'semanal_teoria_3', p_ruta));

    SELECT count(*) INTO v_distintos
      FROM ficheros_vistas WHERE usuario_id = p_uid;
    v_notif := _gamif_push_logro(v_notif,
        _gamif_bump_logro(p_uid, 'explorador_teoria_10', v_distintos));

    RETURN v_notif;
END $$;


-- ─── Comprobación ─────────────────────────────────────────────────────────
DO $$
DECLARE v_ok int;
BEGIN
    SELECT count(*) INTO v_ok FROM pg_proc p
      JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public'
       AND p.proname IN ('_gamif_bump_reto','_gamif_bump_reto_distintos',
                         '_gamif_on_respuesta','_gamif_on_test_finalizado',
                         '_gamif_on_fichero_visto')
       AND pg_get_function_result(p.oid) = 'jsonb';
    RAISE NOTICE 'funciones de reto/on_* que devuelven jsonb: %/5', v_ok;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
