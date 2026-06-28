-- ============================================================================
-- 11_reclasificar_knn.sql
-- Mejora del auto-tagger: además de comparar el embedding de la pregunta
-- contra el catálogo de etiquetas, ahora también busca las K preguntas más
-- parecidas que YA tengan etiquetas y suma sus etiquetas como candidatas.
--
-- Bucle de mejora: cada pregunta que etiquetas a mano (desde el quiz o el
-- editor) sirve de ejemplo para clasificar futuras preguntas similares.
--
-- Parámetros nuevos:
--   p_knn_k       : cuántas preguntas vecinas mirar (default 5).
--   p_knn_umbral  : similitud coseno mínima para que una vecina cuente
--                   (default 0.70, más estricto que el umbral del catálogo
--                    porque el riesgo de contagiar ruido es mayor).
--   p_knn_min     : una etiqueta vecina solo se añade si la sugieren al
--                   menos p_knn_min vecinos (default 1).
-- ============================================================================

-- Elimina la firma anterior (uuid,int,real) para que la nueva con defaults
-- atienda todos los call patterns. Sin esto coexistirían y el worker
-- llamaría a la vieja sin k-NN.
DROP FUNCTION IF EXISTS reclasificar_pregunta(uuid, int, real);

CREATE OR REPLACE FUNCTION reclasificar_pregunta(
    p_id          uuid,
    k             int  DEFAULT 5,
    umbral        real DEFAULT 0.55,
    p_knn_k       int  DEFAULT 5,
    p_knn_umbral  real DEFAULT 0.70,
    p_knn_min     int  DEFAULT 1
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

    WITH
    -- (a-d) candidatas tradicionales: catálogo + palabras clave + nombre +
    -- título del test transitivo. Igual que antes.
    cat AS (
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
    ),
    -- (e) k-NN sobre preguntas ya etiquetadas. La cláusula <=> usa el índice
    -- HNSW de preguntas.embedding. Solo cuentan vecinas con similitud
    -- por encima del umbral fuerte. La etiqueta se acepta si sale en al
    -- menos p_knn_min vecinas.
    vecinas AS (
        SELECT id, etiquetas, 1 - (embedding <=> v_emb) AS sim
          FROM preguntas
         WHERE v_emb IS NOT NULL
           AND embedding IS NOT NULL
           AND id <> p_id
           AND cardinality(etiquetas) > 0
         ORDER BY embedding <=> v_emb
         LIMIT GREATEST(p_knn_k, 1)
    ),
    knn AS (
        SELECT e AS nombre
          FROM vecinas v, unnest(v.etiquetas) AS e
         WHERE v.sim >= p_knn_umbral
         GROUP BY e
        HAVING count(*) >= GREATEST(p_knn_min, 1)
    ),
    candidatas AS (
        SELECT nombre FROM cat
        UNION
        SELECT nombre FROM knn
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


-- Se ha cambiado la firma; otorga ejecución a web_user.
GRANT EXECUTE ON FUNCTION reclasificar_pregunta(uuid,int,real,int,real,int)
    TO web_user;
