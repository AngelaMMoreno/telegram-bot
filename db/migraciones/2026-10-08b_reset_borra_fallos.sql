-- ─────────────────────────────────────────────────────────────────────────
-- "Resetear mi repaso" (Configuración) también borra los fallos.
--
-- Hasta ahora `resetear_mis_repasos` solo vaciaba `repasos` (cajas de
-- repaso). Los fallos viven aparte, como marcadores `tipo = 'fallo'`
-- (alimentan el "Test de fallos" y el contador de preguntas falladas),
-- así que tras resetear seguían apareciendo.
--
-- Ahora la misma RPC borra también los marcadores de fallo del usuario
-- (con el mismo alcance: todos, o solo los de las preguntas de un test).
-- No toca `respuestas`, `intentos`, favoritas ni estadísticas históricas.
-- Devuelve {borradas, fallos_borrados}; `borradas` mantiene su significado
-- para no romper al frontend anterior.
--
-- Idempotente.
-- ─────────────────────────────────────────────────────────────────────────
BEGIN;

CREATE OR REPLACE FUNCTION resetear_mis_repasos(p_test_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql AS $fn$
DECLARE
    v_uid    uuid := jwt_usuario_id();
    v_n      int;
    v_fallos int;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;

    IF p_test_id IS NULL THEN
        DELETE FROM repasos WHERE usuario_id = v_uid;
        GET DIAGNOSTICS v_n = ROW_COUNT;

        DELETE FROM marcadores
         WHERE usuario_id = v_uid AND tipo = 'fallo';
        GET DIAGNOSTICS v_fallos = ROW_COUNT;
    ELSE
        DELETE FROM repasos
         WHERE usuario_id = v_uid
           AND pregunta_id IN (
               SELECT pregunta_id FROM test_preguntas WHERE test_id = p_test_id
           );
        GET DIAGNOSTICS v_n = ROW_COUNT;

        DELETE FROM marcadores
         WHERE usuario_id = v_uid
           AND tipo = 'fallo'
           AND pregunta_id IN (
               SELECT pregunta_id FROM test_preguntas WHERE test_id = p_test_id
           );
        GET DIAGNOSTICS v_fallos = ROW_COUNT;
    END IF;

    RETURN jsonb_build_object('borradas', v_n, 'fallos_borrados', v_fallos);
END $fn$;

COMMIT;

NOTIFY pgrst, 'reload schema';
