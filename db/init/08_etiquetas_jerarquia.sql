-- ============================================================================
-- 08_etiquetas_jerarquia.sql
-- Jerarquía padre/hijo en catalogo_etiquetas.
--
-- Motivación: los embeddings resuelven bien la similitud léxica/semántica
-- (java ↔ hibernate), pero no las relaciones de tipo "es un":
--   programación ⊃ {java, php, python}
--   java         ⊃ {hibernate, jdbc, junit, springboot}
--
-- Con esta tabla autorreferenciada y la función etiqueta_y_descendientes(),
-- buscar_preguntas() expande la etiqueta consultada a todo su subárbol antes
-- de filtrar. El usuario escribe "programación" y aparecen preguntas
-- etiquetadas como "java", "php", etc.
-- ============================================================================

-- Columna padre autorreferenciada. ON DELETE SET NULL para que borrar una
-- etiqueta padre no se lleve a las hijas; quedan huérfanas (sin padre).
ALTER TABLE catalogo_etiquetas
    ADD COLUMN IF NOT EXISTS padre text
        REFERENCES catalogo_etiquetas(nombre)
        ON UPDATE CASCADE ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS catalogo_etiquetas_padre_idx
    ON catalogo_etiquetas (padre);


-- ─────────────── Descendientes (recursivo) ─────────────────────────────────
-- Devuelve la etiqueta consultada + toda su descendencia (cualquier nivel).
-- Si la etiqueta no existe en el catálogo devuelve {p_nombre} para no romper
-- a quien filtra por una etiqueta libre.
CREATE OR REPLACE FUNCTION etiqueta_y_descendientes(p_nombre text)
RETURNS text[]
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE arbol AS (
        SELECT nombre FROM catalogo_etiquetas WHERE nombre = p_nombre
        UNION ALL
        SELECT c.nombre
          FROM catalogo_etiquetas c
          JOIN arbol a ON c.padre = a.nombre
    )
    SELECT COALESCE(array_agg(nombre), ARRAY[p_nombre])
      FROM arbol;
$$;


-- ─────────────── buscar_preguntas: expande etiqueta a su subárbol ───────────
-- Mantiene la firma (text, int, text) para no romper al frontend. Añade
-- expansión jerárquica del filtro p_etiqueta y respeta el comportamiento
-- previo cuando p_etiqueta es NULL.
CREATE OR REPLACE FUNCTION buscar_preguntas(
    p_q        text,
    p_lim      int  DEFAULT 20,
    p_etiqueta text DEFAULT NULL
) RETURNS TABLE (id uuid, enunciado text, score real, etiquetas text[])
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_etiq_expandidas text[];
BEGIN
    IF p_etiqueta IS NOT NULL AND p_etiqueta <> '' THEN
        v_etiq_expandidas := etiqueta_y_descendientes(p_etiqueta);
    END IF;

    RETURN QUERY
    SELECT p.id, p.enunciado,
           similarity(p.enunciado, p_q) AS score,
           p.etiquetas
      FROM preguntas p
     WHERE (p_q IS NULL OR p_q = '' OR p.enunciado %> p_q)
       AND (
            v_etiq_expandidas IS NULL
            OR p.etiquetas && v_etiq_expandidas
       )
     ORDER BY similarity(p.enunciado, p_q) DESC NULLS LAST
     LIMIT p_lim;
END $$;

GRANT EXECUTE ON FUNCTION etiqueta_y_descendientes(text)       TO web_user, web_anon;
GRANT EXECUTE ON FUNCTION buscar_preguntas(text,int,text)      TO web_user;


-- ─────────────── listar_etiquetas: incluye `padre` y `num_hijas` ────────────
CREATE OR REPLACE FUNCTION listar_etiquetas() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'nombre',         c.nombre,
        'descripcion',    c.descripcion,
        'palabras_clave', c.palabras_clave,
        'padre',          c.padre,
        'num_hijas',      (SELECT count(*) FROM catalogo_etiquetas h
                            WHERE h.padre = c.nombre),
        'creada_en',      c.creado_en,
        'vectorizada',    c.embedding IS NOT NULL,
        'num_preguntas',  (SELECT count(*) FROM preguntas
                            WHERE c.nombre = ANY(etiquetas)),
        'num_tests',      (SELECT count(*) FROM tests
                            WHERE c.nombre = ANY(etiquetas))
    ) ORDER BY c.nombre), '[]'::jsonb)
    FROM catalogo_etiquetas c;
$$;


-- ─────────────── crear_etiqueta: acepta p_padre ────────────────────────────
-- Conserva la firma anterior creando una nueva sobrecarga; la vieja se
-- reemplaza por una versión que llama a la nueva con padre = NULL para que
-- los clientes existentes sigan funcionando.

DROP FUNCTION IF EXISTS crear_etiqueta(text, text, text[]);

CREATE OR REPLACE FUNCTION crear_etiqueta(
    p_nombre         text,
    p_descripcion    text,
    p_palabras_clave text[] DEFAULT '{}',
    p_padre          text   DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v jsonb;
    v_padre text;
BEGIN
    IF NOT (tiene_permiso('etiqueta.gestionar') OR es_admin()) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;

    p_nombre := lower(btrim(p_nombre));
    IF length(p_nombre) = 0 THEN RAISE EXCEPTION 'nombre_vacio'; END IF;

    v_padre := NULLIF(lower(btrim(COALESCE(p_padre, ''))), '');

    IF v_padre IS NOT NULL THEN
        IF v_padre = p_nombre THEN
            RAISE EXCEPTION 'padre_no_puede_ser_misma_etiqueta';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM catalogo_etiquetas WHERE nombre = v_padre) THEN
            RAISE EXCEPTION 'padre_no_existe: %', v_padre;
        END IF;
        -- Evita ciclos: el padre propuesto no puede ser descendiente nuestro.
        IF v_padre = ANY(etiqueta_y_descendientes(p_nombre)) THEN
            RAISE EXCEPTION 'ciclo_jerarquia';
        END IF;
    END IF;

    INSERT INTO catalogo_etiquetas(nombre, descripcion, palabras_clave, padre)
    VALUES (
        p_nombre,
        NULLIF(btrim(p_descripcion), ''),
        COALESCE(p_palabras_clave, '{}'),
        v_padre
    )
    ON CONFLICT (nombre) DO UPDATE
        SET descripcion    = EXCLUDED.descripcion,
            palabras_clave = EXCLUDED.palabras_clave,
            padre          = EXCLUDED.padre;

    SELECT to_jsonb(c) INTO v FROM catalogo_etiquetas c WHERE nombre = p_nombre;
    RETURN v;
END $$;

GRANT EXECUTE ON FUNCTION crear_etiqueta(text,text,text[],text) TO web_user;
