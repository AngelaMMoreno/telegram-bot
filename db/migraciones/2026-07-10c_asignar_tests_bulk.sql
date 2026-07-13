-- ─────────────────────────────────────────────────────────────────────────
-- Bulk many-to-many: asigna N tests a M oposiciones en una sola llamada.
--
-- Motivación: hasta ahora el panel de administración permitía enlazar
-- tests con oposiciones por dos caminos: desde una oposición marcando
-- sus tests (`set_oposicion_tests`, semántica REEMPLAZO), o desde el
-- detalle de un test marcando sus oposiciones (`set_test_oposiciones`,
-- también REEMPLAZO). Ninguno permite tocar varios tests y varias
-- oposiciones a la vez y ambos borran lo previo, con lo que "asignar a
-- todas las oposiciones" desde el detalle de un test recién subido era
-- tediosamente manual.
--
-- Esta RPC INSERTA los pares `(test_id, oposicion_id)` faltantes sin
-- borrar los ya existentes, así que sirve tanto para "asignar este test
-- nuevo a todas las oposiciones" como para "adjuntar estos tests a
-- estas otras oposiciones sin afectar al resto". Devuelve cuántos
-- pares eran nuevos (útil para el toast).
--
-- Idempotente.
-- ─────────────────────────────────────────────────────────────────────────
BEGIN;

CREATE OR REPLACE FUNCTION asignar_tests_a_oposiciones(
    p_test_ids uuid[], p_oposicion_ids uuid[]
) RETURNS int
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_nuevos int;
BEGIN
    IF NOT (es_admin() OR tiene_permiso('test.crear')) THEN
        RAISE EXCEPTION 'no_autorizado';
    END IF;
    WITH ins AS (
        INSERT INTO test_oposiciones(test_id, oposicion_id)
        SELECT tid, oid
        FROM   UNNEST(COALESCE(p_test_ids,      '{}'::uuid[])) tid
        CROSS JOIN UNNEST(COALESCE(p_oposicion_ids, '{}'::uuid[])) oid
        ON CONFLICT DO NOTHING
        RETURNING 1
    )
    SELECT count(*)::int INTO v_nuevos FROM ins;
    RETURN v_nuevos;
END $$;

GRANT EXECUTE ON FUNCTION asignar_tests_a_oposiciones(uuid[], uuid[]) TO web_user;

COMMIT;

NOTIFY pgrst, 'reload schema';
