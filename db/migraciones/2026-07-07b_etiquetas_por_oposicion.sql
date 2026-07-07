-- Filtra el catálogo de etiquetas por la oposición activa.
--
-- Contexto: en la vista Tests pintamos un chip por etiqueta para filtrar
-- el listado. Con listar_etiquetas() sin filtrar veíamos etiquetas que
-- no aparecen en NINGÚN test de la oposición del usuario (p.ej. "java"
-- para un opositor a Sanidad), así que al pulsarlas el listado quedaba
-- vacío. Con esta migración el frontend pide la lista pasando la
-- oposición actual y sólo recibe etiquetas que llevan tests dentro de
-- esa oposición.
--
-- El parámetro es opcional. Con NULL el comportamiento es el de siempre
-- (todas las etiquetas), para no romper llamadas antiguas.
--
-- CREATE OR REPLACE no puede cambiar la lista de parámetros (aunque el
-- nuevo tenga default), así que dropeamos la firma antigua primero.

SET search_path = public;

DROP FUNCTION IF EXISTS listar_etiquetas();

CREATE OR REPLACE FUNCTION listar_etiquetas(p_oposicion_id uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'nombre',         c.nombre,
        'descripcion',    c.descripcion,
        'palabras_clave', c.palabras_clave,
        'padre',          c.padre,
        'num_hijas',      (SELECT count(*) FROM catalogo_etiquetas h WHERE h.padre = c.nombre),
        'creada_en',      c.creado_en,
        'vectorizada',    c.embedding IS NOT NULL,
        'num_preguntas',  (SELECT count(*) FROM preguntas WHERE c.nombre = ANY(etiquetas)),
        'num_tests',      (SELECT count(*) FROM tests     WHERE c.nombre = ANY(etiquetas))
    ) ORDER BY c.nombre), '[]'::jsonb)
    FROM catalogo_etiquetas c
    WHERE p_oposicion_id IS NULL
       OR EXISTS (
              SELECT 1
                FROM tests t
                JOIN test_oposiciones tox ON tox.test_id = t.id
               WHERE tox.oposicion_id = p_oposicion_id
                 AND c.nombre = ANY(t.etiquetas)
          );
$$;

GRANT EXECUTE ON FUNCTION listar_etiquetas(uuid) TO web_user;
