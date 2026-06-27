-- ============================================================================
-- 10_embeddings_con_respuesta_correcta.sql
-- A partir de aquí el worker vectoriza enunciado + opción correcta en vez de
-- solo el enunciado. Mejora el auto-tagger en preguntas con enunciados
-- genéricos tipo "¿cuál de las siguientes…?" donde el tema solo aparece en
-- las respuestas.
--
-- Migración idempotente:
--   1) Reemplaza el trigger para que también dispare al editar opciones.
--   2) Re-encola toda pregunta que no esté ya pendiente para que el worker
--      genere de nuevo el embedding con el texto combinado.
-- ============================================================================

DROP TRIGGER IF EXISTS preguntas_emb_au ON preguntas;

CREATE TRIGGER preguntas_emb_au
    AFTER UPDATE OF enunciado, opciones ON preguntas
    FOR EACH ROW WHEN (
        NEW.enunciado IS DISTINCT FROM OLD.enunciado
        OR NEW.opciones IS DISTINCT FROM OLD.opciones
    )
    EXECUTE FUNCTION encolar_embedding_pregunta();


-- Re-encola solo las preguntas que NO tienen ya una entrada pendiente,
-- así no duplicamos trabajo si todavía no había terminado el bulk anterior.
DO $$
DECLARE v_n int;
BEGIN
    INSERT INTO cola_embeddings(entidad, entidad_id)
    SELECT 'pregunta', p.id::text
      FROM preguntas p
     WHERE NOT EXISTS (
        SELECT 1 FROM cola_embeddings c
         WHERE c.entidad = 'pregunta'
           AND c.entidad_id = p.id::text
           AND c.procesado_en IS NULL
     );
    GET DIAGNOSTICS v_n = ROW_COUNT;
    PERFORM pg_notify('embeddings', 'bulk');
    RAISE NOTICE 'Re-encoladas % preguntas para re-vectorizar con enunciado + correcta.', v_n;
END $$;
