-- ============================================================================
-- 09_embeddings_1024.sql
-- Migración a embeddings de 1024 dimensiones (BAAI/bge-m3).
-- Idempotente: solo hace algo si las columnas siguen siendo vector(768)
-- (o vector(384), por si se aplica sobre una BBDD que no llegó a pasar por 07).
-- En BBDD nuevas que ya nacen con vector(1024) no hace nada.
-- ============================================================================

DO $$
DECLARE
    v_tipo_actual text;
BEGIN
    SELECT format_type(a.atttypid, a.atttypmod)
      INTO v_tipo_actual
      FROM pg_attribute a
      JOIN pg_class c ON c.oid = a.attrelid
     WHERE c.relname = 'preguntas' AND a.attname = 'embedding';

    IF v_tipo_actual IN ('vector(768)', 'vector(384)') THEN
        RAISE NOTICE 'Migrando embeddings % → 1024…', v_tipo_actual;

        DROP INDEX IF EXISTS preguntas_emb_idx;
        DROP INDEX IF EXISTS catalogo_etiquetas_emb_idx;

        UPDATE preguntas          SET embedding = NULL WHERE embedding IS NOT NULL;
        UPDATE catalogo_etiquetas SET embedding = NULL WHERE embedding IS NOT NULL;

        ALTER TABLE preguntas          ALTER COLUMN embedding TYPE vector(1024);
        ALTER TABLE catalogo_etiquetas ALTER COLUMN embedding TYPE vector(1024);

        CREATE INDEX preguntas_emb_idx
            ON preguntas USING hnsw (embedding vector_cosine_ops);
        CREATE INDEX catalogo_etiquetas_emb_idx
            ON catalogo_etiquetas USING hnsw (embedding vector_cosine_ops);

        INSERT INTO cola_embeddings(entidad, entidad_id)
            SELECT 'pregunta', id::text FROM preguntas;
        INSERT INTO cola_embeddings(entidad, entidad_id)
            SELECT 'etiqueta', nombre FROM catalogo_etiquetas;
        PERFORM pg_notify('embeddings', 'bulk');

        RAISE NOTICE 'Migración 1024 dim completada. El worker re-vectorizará en segundo plano.';
    END IF;
END $$;


-- reclasificar_pregunta debe declarar v_emb a la dimensión nueva. Se vuelve
-- a definir aquí por si en la BBDD existente seguía viva la versión 768/384.
CREATE OR REPLACE FUNCTION reclasificar_pregunta(
    p_id     uuid,
    k        int   DEFAULT 5,
    umbral   real  DEFAULT 0.55
) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
    v_emun     text;
    v_emb      vector(1024);
    v_test_tit text;
    v_n        int;
BEGIN
    SELECT p.enunciado, p.embedding,
           (SELECT t.titulo FROM test_preguntas tp
              JOIN tests t ON t.id = tp.test_id
             WHERE tp.pregunta_id = p.id
             ORDER BY t.creado_en LIMIT 1)
      INTO v_emun, v_emb, v_test_tit
      FROM preguntas p WHERE p.id = p_id;

    IF v_emun IS NULL THEN RETURN 0; END IF;

    WITH candidatas AS (
        SELECT c.nombre FROM catalogo_etiquetas c
        WHERE
            (v_emb IS NOT NULL AND c.embedding IS NOT NULL
             AND 1 - (c.embedding <=> v_emb) > umbral)
            OR EXISTS (
                SELECT 1 FROM unnest(c.palabras_clave) kw
                WHERE v_emun ILIKE '%' || kw || '%'
            )
            OR v_emun ILIKE '%' || c.nombre || '%'
            OR (
                v_test_tit IS NOT NULL AND (
                    v_test_tit ILIKE '%' || c.nombre || '%'
                    OR EXISTS (
                        SELECT 1 FROM unnest(c.palabras_clave) kw
                        WHERE v_test_tit ILIKE '%' || kw || '%'
                    )
                )
            )
    )
    UPDATE preguntas
       SET etiquetas = ARRAY(
               SELECT DISTINCT e
                 FROM unnest(etiquetas || ARRAY(SELECT nombre FROM candidatas)) AS e
           ),
           actualizado_en = now()
     WHERE id = p_id;

    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END $$;
