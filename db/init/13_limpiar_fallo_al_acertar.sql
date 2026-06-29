-- ============================================================================
-- 13_limpiar_fallo_al_acertar.sql
-- Al responder correctamente una pregunta, eliminar su marcador 'fallo' para
-- ese usuario. Antes, registrar_respuesta solo incrementaba el contador al
-- fallar y nunca lo borraba al acertar, por lo que las preguntas acertadas
-- seguían apareciendo en mis_fallos() y no desaparecían del "Test de fallos".
--
-- Migración idempotente: redefine registrar_respuesta con CREATE OR REPLACE.
-- ============================================================================

CREATE OR REPLACE FUNCTION registrar_respuesta(
    p_intento_id  uuid,
    p_pregunta_id uuid,
    p_texto       text,
    p_correcta    boolean
) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO respuestas(intento_id, pregunta_id, opcion_elegida, correcta)
    VALUES (p_intento_id, p_pregunta_id, p_texto, p_correcta);

    IF NOT p_correcta THEN
        INSERT INTO marcadores(usuario_id, tipo, pregunta_id, contador, actualizado_en)
        VALUES (jwt_usuario_id(), 'fallo', p_pregunta_id, 1, now())
        ON CONFLICT (usuario_id, tipo, COALESCE(pregunta_id, test_id))
        DO UPDATE SET contador = marcadores.contador + 1,
                       actualizado_en = now();
    ELSE
        DELETE FROM marcadores
         WHERE usuario_id = jwt_usuario_id()
           AND tipo = 'fallo'
           AND pregunta_id = p_pregunta_id;
    END IF;
END $$;

GRANT EXECUTE ON FUNCTION registrar_respuesta(uuid,uuid,text,boolean) TO web_user;
