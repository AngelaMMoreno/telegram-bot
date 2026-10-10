-- ─────────────────────────────────────────────────────────────────────────
-- API para consultar y EDITAR oposiciones, tests y preguntas.
--
-- Motivación: la API de 2026-10-08 solo sabía crear tests
-- (`subir_test_a_oposicion`). Al corregir un temario hay que poder
-- actualizar un test ya subido sin duplicarlo ni perder el historial de
-- los usuarios, y la deduplicación por enunciado lo impedía: si una
-- pregunta nueva tenía el mismo enunciado que otra ya existente (por
-- ejemplo, la pregunta oficial de un examen y su versión adaptada en el
-- test de una unidad), se reutilizaba la vieja con sus opciones viejas y
-- el test subido no decía lo que decía el fichero.
--
-- 1. `preguntas.hash_contenido` pasa a cubrir enunciado + opciones.
--    Dos preguntas con el mismo enunciado y distintas opciones son
--    preguntas distintas; las idénticas se siguen deduplicando. Es una
--    clave más fina que la anterior: ninguna fila existente choca.
--
-- 2. RPCs nuevas (POST /rpc/<función>):
--
--   • obtener_test(test)                      test con sus oposiciones y sus
--                                             preguntas (id, posición, opciones…)
--   • obtener_test_por_titulo(oposicion, titulo)
--   • editar_test(test, titulo, descripcion)  renombrar / cambiar descripción
--   • reemplazar_preguntas_test(test, preguntas, borrar_huerfanas)
--       Deja el test con exactamente esas preguntas y en ese orden.
--       Conserva el historial: una pregunta idéntica se reutiliza, y una
--       pregunta del test con el mismo enunciado y otras opciones se
--       corrige en su sitio si ningún otro test la usa.
--   • sincronizar_test_en_oposicion(oposicion, titulo, descripcion, preguntas)
--       Crea el test si no existe en la oposición o lo reemplaza si
--       existe. Devuelve accion = CREADO | ACTUALIZADO | SIN_CAMBIOS.
--   • quitar_test_de_oposicion(test, oposicion, borrar_si_huerfano)
--   • editar_pregunta(pregunta, enunciado, opciones, explicacion, etiquetas)
--   • tests_repetidos_de_oposicion(oposicion, umbral)
--       Pares de tests de una oposición que comparten al menos `umbral`
--       (0-1) de sus enunciados: sirve para detectar exámenes repetidos.
--
-- Permisos: consultar, el staff (admin o `test.crear`) y los usuarios
-- con la oposición asignada; editar, admin o `test.editar`/`test.crear`
-- (editor); editar una pregunta, admin o `pregunta.editar`.
--
-- Ver db/API_TESTS_OPOSICION.md. Idempotente.
-- ─────────────────────────────────────────────────────────────────────────
BEGIN;

-- ── 1. Hash de contenido: enunciado + opciones ───────────────────────────
DO $mig$
DECLARE v_expr text;
BEGIN
    SELECT pg_get_expr(d.adbin, d.adrelid) INTO v_expr
      FROM pg_attribute a
      JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
     WHERE a.attrelid = 'preguntas'::regclass AND a.attname = 'hash_contenido';
    IF v_expr IS NULL OR position('opciones' IN v_expr) = 0 THEN
        ALTER TABLE preguntas DROP COLUMN IF EXISTS hash_contenido;
        ALTER TABLE preguntas ADD COLUMN hash_contenido text
            GENERATED ALWAYS AS (md5(lower(btrim(enunciado)) || '|' || lower(opciones::text))) STORED;
        ALTER TABLE preguntas ADD CONSTRAINT preguntas_hash_contenido_key UNIQUE (hash_contenido);
        RAISE NOTICE 'hash_contenido recalculado sobre enunciado + opciones';
    END IF;
END $mig$;

CREATE INDEX IF NOT EXISTS preguntas_enunciado_norm_idx ON preguntas (lower(btrim(enunciado)));


-- ── 2. Helpers ───────────────────────────────────────────────────────────

-- Hash que calcula la columna generada, para buscar antes de insertar.
CREATE OR REPLACE FUNCTION _hash_pregunta(p_enunciado text, p_opciones jsonb) RETURNS text
LANGUAGE sql IMMUTABLE AS $fn$
    SELECT md5(lower(btrim(p_enunciado)) || '|' || lower(p_opciones::text));
$fn$;

-- Valida un array de preguntas (o el objeto {preguntas: [...]}) y lo
-- devuelve normalizado: [{pregunta, opciones: [{texto, correcta}], explicacion, etiquetas}].
-- Mismos formatos y errores que `subir_test_a_oposicion`.
CREATE OR REPLACE FUNCTION _normalizar_preguntas(p_preguntas jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE
    v_preguntas jsonb := p_preguntas;
    v_preg      jsonb;
    v_opc       jsonb;
    v_idx       int   := 0;
    v_salida    jsonb := '[]'::jsonb;
BEGIN
    IF jsonb_typeof(v_preguntas) = 'object' THEN
        v_preguntas := v_preguntas->'preguntas';
    END IF;
    IF jsonb_typeof(v_preguntas) IS DISTINCT FROM 'array'
       OR jsonb_array_length(v_preguntas) = 0 THEN
        RAISE EXCEPTION 'preguntas_invalidas'
            USING HINT = 'Se espera un array JSON no vacío de preguntas.';
    END IF;

    FOR v_preg IN SELECT * FROM jsonb_array_elements(v_preguntas) LOOP
        v_idx := v_idx + 1;
        IF jsonb_typeof(v_preg) <> 'object'
           OR btrim(COALESCE(v_preg->>'pregunta', '')) = '' THEN
            RAISE EXCEPTION 'pregunta_invalida'
                USING DETAIL = 'Pregunta ' || v_idx || ': falta el campo "pregunta".';
        END IF;
        v_opc := _normalizar_opciones(v_preg->'opciones', v_idx);
        v_salida := v_salida || jsonb_build_array(jsonb_build_object(
            'pregunta',    btrim(v_preg->>'pregunta'),
            'opciones',    v_opc,
            'explicacion', NULLIF(btrim(COALESCE(v_preg->>'explicacion', '')), ''),
            'etiquetas',   CASE WHEN jsonb_typeof(v_preg->'etiquetas') = 'array'
                                THEN v_preg->'etiquetas' ELSE '[]'::jsonb END
        ));
    END LOOP;
    RETURN v_salida;
END $fn$;

-- Opciones en cualquiera de los dos formatos -> [{texto, correcta}].
CREATE OR REPLACE FUNCTION _normalizar_opciones(p_opciones jsonb, p_idx int DEFAULT 1) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE v_opc jsonb;
BEGIN
    IF jsonb_typeof(p_opciones) IS DISTINCT FROM 'array'
       OR jsonb_array_length(p_opciones) < 2 THEN
        RAISE EXCEPTION 'pregunta_invalida'
            USING DETAIL = 'Pregunta ' || p_idx || ': "opciones" debe ser un array de al menos 2 elementos.';
    END IF;
    IF jsonb_typeof(p_opciones->0) = 'string' THEN
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_opciones) e
                    WHERE jsonb_typeof(e) <> 'string' OR btrim(e #>> '{}') = '') THEN
            RAISE EXCEPTION 'pregunta_invalida'
                USING DETAIL = 'Pregunta ' || p_idx || ': todas las opciones deben ser textos no vacíos.';
        END IF;
        SELECT jsonb_agg(jsonb_build_object('texto', btrim(t), 'correcta', i = 1) ORDER BY i)
          INTO v_opc
          FROM jsonb_array_elements_text(p_opciones) WITH ORDINALITY AS x(t, i);
    ELSE
        IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_opciones) e
                    WHERE jsonb_typeof(e) <> 'object'
                       OR btrim(COALESCE(e->>'texto', '')) = ''
                       OR jsonb_typeof(e->'correcta') IS DISTINCT FROM 'boolean') THEN
            RAISE EXCEPTION 'pregunta_invalida'
                USING DETAIL = 'Pregunta ' || p_idx || ': cada opción debe ser {"texto": "...", "correcta": true|false}.';
        END IF;
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_opciones) e WHERE (e->>'correcta')::boolean) THEN
            RAISE EXCEPTION 'pregunta_invalida'
                USING DETAIL = 'Pregunta ' || p_idx || ': ninguna opción está marcada como correcta.';
        END IF;
        SELECT jsonb_agg(jsonb_build_object('texto', btrim(e->>'texto'), 'correcta', (e->>'correcta')::boolean) ORDER BY i)
          INTO v_opc
          FROM jsonb_array_elements(p_opciones) WITH ORDINALITY AS x(e, i);
    END IF;
    RETURN v_opc;
END $fn$;

CREATE OR REPLACE FUNCTION _puede_editar_tests() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER AS $fn$
    SELECT es_admin() OR tiene_permiso('test.editar') OR tiene_permiso('test.crear');
$fn$;

-- El staff ve cualquier test; un usuario, los de sus oposiciones.
CREATE OR REPLACE FUNCTION _puede_ver_test(p_test_id uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER AS $fn$
    SELECT es_admin() OR tiene_permiso('test.crear') OR EXISTS (
        SELECT 1 FROM test_oposiciones tox
          JOIN usuario_oposiciones uo ON uo.oposicion_id = tox.oposicion_id
         WHERE tox.test_id = p_test_id AND uo.usuario_id = jwt_usuario_id()
    );
$fn$;


-- ── 3. Consultar ─────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION obtener_test(p_test_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $fn$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM tests WHERE id = p_test_id) THEN
        RAISE EXCEPTION 'test_no_encontrado';
    END IF;
    IF NOT _puede_ver_test(p_test_id) THEN
        RAISE EXCEPTION 'no_autorizado';
    END IF;
    RETURN (
        SELECT jsonb_build_object(
            'id',            t.id,
            'titulo',        t.titulo,
            'descripcion',   t.descripcion,
            'tipo',          t.tipo,
            'publico',       t.publico,
            'creado_en',     t.creado_en,
            'oposiciones',   COALESCE((
                SELECT jsonb_agg(jsonb_build_object('id', o.id, 'nombre', o.nombre) ORDER BY o.nombre)
                  FROM test_oposiciones tox JOIN oposiciones o ON o.id = tox.oposicion_id
                 WHERE tox.test_id = t.id), '[]'::jsonb),
            'num_preguntas', (SELECT count(*) FROM test_preguntas WHERE test_id = t.id),
            'preguntas',     COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                    'id',          p.id,
                    'posicion',    tp.posicion,
                    'pregunta',    p.enunciado,
                    'opciones',    p.opciones,
                    'explicacion', p.explicacion,
                    'etiquetas',   p.etiquetas,
                    -- en cuántos tests más está: editarla los cambia todos
                    'otros_tests', (SELECT count(*) FROM test_preguntas tp2
                                     WHERE tp2.pregunta_id = p.id AND tp2.test_id <> t.id)
                ) ORDER BY tp.posicion)
                  FROM test_preguntas tp JOIN preguntas p ON p.id = tp.pregunta_id
                 WHERE tp.test_id = t.id), '[]'::jsonb)
        )
        FROM tests t WHERE t.id = p_test_id
    );
END $fn$;

CREATE OR REPLACE FUNCTION _test_de_oposicion_por_titulo(p_oposicion_id uuid, p_titulo text) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER AS $fn$
    SELECT t.id
      FROM tests t JOIN test_oposiciones tox ON tox.test_id = t.id
     WHERE tox.oposicion_id = p_oposicion_id
       AND lower(btrim(t.titulo)) = lower(btrim(p_titulo))
     ORDER BY t.creado_en
     LIMIT 1;
$fn$;

-- El test de una oposición con ese título (sin distinguir mayúsculas), o null.
CREATE OR REPLACE FUNCTION obtener_test_por_titulo(p_oposicion_id uuid, p_titulo text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $fn$
DECLARE v_test uuid;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM oposiciones WHERE id = p_oposicion_id) THEN
        RAISE EXCEPTION 'oposicion_no_encontrada';
    END IF;
    IF NOT puedo_ver_oposicion(p_oposicion_id) THEN
        RAISE EXCEPTION 'no_autorizado';
    END IF;
    v_test := _test_de_oposicion_por_titulo(p_oposicion_id, p_titulo);
    IF v_test IS NULL THEN RETURN NULL; END IF;
    RETURN obtener_test(v_test);
END $fn$;

-- Pares de tests de la oposición que comparten al menos `p_umbral` (sobre
-- el más pequeño de los dos) de sus enunciados normalizados.
CREATE OR REPLACE FUNCTION tests_repetidos_de_oposicion(p_oposicion_id uuid, p_umbral numeric DEFAULT 0.5)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $fn$
BEGIN
    IF NOT (es_admin() OR tiene_permiso('test.crear')) THEN
        RAISE EXCEPTION 'no_autorizado';
    END IF;
    RETURN COALESCE((
        WITH enun AS (
            SELECT DISTINCT tox.test_id, lower(btrim(p.enunciado)) AS e
              FROM test_oposiciones tox
              JOIN test_preguntas tp ON tp.test_id = tox.test_id
              JOIN preguntas p ON p.id = tp.pregunta_id
             WHERE tox.oposicion_id = p_oposicion_id
        ), tam AS (
            SELECT test_id, count(*) AS n FROM enun GROUP BY test_id
        ), pares AS (
            SELECT a.test_id AS a, b.test_id AS b, count(*) AS comunes
              FROM enun a JOIN enun b ON a.e = b.e AND a.test_id < b.test_id
             GROUP BY a.test_id, b.test_id
        )
        SELECT jsonb_agg(jsonb_build_object(
                   'test_a',     ta.titulo,  'id_a', pa.a, 'preguntas_a', na.n,
                   'test_b',     tb.titulo,  'id_b', pa.b, 'preguntas_b', nb.n,
                   'comunes',    pa.comunes,
                   'proporcion', round(pa.comunes::numeric / LEAST(na.n, nb.n), 3)
               ) ORDER BY pa.comunes::numeric / LEAST(na.n, nb.n) DESC)
          FROM pares pa
          JOIN tam na ON na.test_id = pa.a
          JOIN tam nb ON nb.test_id = pa.b
          JOIN tests ta ON ta.id = pa.a
          JOIN tests tb ON tb.id = pa.b
         WHERE pa.comunes::numeric / LEAST(na.n, nb.n) >= COALESCE(p_umbral, 0.5)
    ), '[]'::jsonb);
END $fn$;


-- ── 4. Editar ────────────────────────────────────────────────────────────

-- Renombra o cambia la descripción. NULL deja el campo como está; una
-- descripción '' la borra. El título no puede repetirse en ninguna de las
-- oposiciones del test.
CREATE OR REPLACE FUNCTION editar_test(
    p_test_id uuid, p_titulo text DEFAULT NULL, p_descripcion text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_titulo text := NULLIF(btrim(COALESCE(p_titulo, '')), '');
BEGIN
    IF NOT _puede_editar_tests() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    IF NOT EXISTS (SELECT 1 FROM tests WHERE id = p_test_id) THEN
        RAISE EXCEPTION 'test_no_encontrado';
    END IF;
    IF v_titulo IS NOT NULL AND EXISTS (
        SELECT 1
          FROM test_oposiciones mia
          JOIN test_oposiciones otra ON otra.oposicion_id = mia.oposicion_id AND otra.test_id <> p_test_id
          JOIN tests t ON t.id = otra.test_id
         WHERE mia.test_id = p_test_id AND lower(btrim(t.titulo)) = lower(v_titulo)
    ) THEN
        RAISE EXCEPTION 'test_duplicado'
            USING HINT = 'Ya existe un test con ese nombre en una de sus oposiciones.';
    END IF;
    UPDATE tests
       SET titulo      = COALESCE(v_titulo, titulo),
           descripcion = CASE WHEN p_descripcion IS NULL THEN descripcion
                              ELSE NULLIF(btrim(p_descripcion), '') END
     WHERE id = p_test_id;
    RETURN (SELECT jsonb_build_object('id', id, 'titulo', titulo, 'descripcion', descripcion)
              FROM tests WHERE id = p_test_id);
END $fn$;

-- Deja el test con exactamente `p_preguntas`, en ese orden.
--   • Una pregunta idéntica (enunciado + opciones) a otra existente se
--     reutiliza; si su explicación cambia y ningún otro test la usa, se
--     actualiza (si la comparte, se deja y se cuenta en
--     `explicaciones_compartidas`).
--   • Una pregunta del test con el mismo enunciado y otras opciones se
--     corrige en su sitio si ningún otro test la usa: conserva repasos,
--     fallos y favoritas. Si la comparte, se crea una nueva.
--   • Las preguntas que salen del test y no quedan en ningún otro se
--     borran si `p_borrar_huerfanas` (por defecto), con su historial.
CREATE OR REPLACE FUNCTION reemplazar_preguntas_test(
    p_test_id uuid, p_preguntas jsonb, p_borrar_huerfanas boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
    v_nuevas_preg jsonb;
    v_preg        jsonb;
    v_hash        text;
    v_pid         uuid;
    v_antes       uuid[];
    v_despues     uuid[] := '{}';
    v_compartida  boolean;
    v_etiq        text[];
    n_reutilizadas int := 0; n_corregidas int := 0; n_nuevas int := 0;
    n_explicaciones int := 0; n_expl_compartidas int := 0; n_repetidas int := 0;
    n_retiradas int := 0; n_borradas int := 0;
    v_mismo_orden boolean;
BEGIN
    IF NOT _puede_editar_tests() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    IF NOT EXISTS (SELECT 1 FROM tests WHERE id = p_test_id) THEN
        RAISE EXCEPTION 'test_no_encontrado';
    END IF;
    v_nuevas_preg := _normalizar_preguntas(p_preguntas);

    SELECT COALESCE(array_agg(pregunta_id ORDER BY posicion), '{}') INTO v_antes
      FROM test_preguntas WHERE test_id = p_test_id;

    FOR v_preg IN SELECT * FROM jsonb_array_elements(v_nuevas_preg) LOOP
        v_hash := _hash_pregunta(v_preg->>'pregunta', v_preg->'opciones');
        v_etiq := ARRAY(SELECT jsonb_array_elements_text(v_preg->'etiquetas'));
        v_pid  := NULL;

        SELECT id INTO v_pid FROM preguntas WHERE hash_contenido = v_hash;
        IF v_pid IS NOT NULL THEN
            n_reutilizadas := n_reutilizadas + 1;
            IF (SELECT explicacion FROM preguntas WHERE id = v_pid)
               IS DISTINCT FROM (v_preg->>'explicacion') THEN
                v_compartida := EXISTS (SELECT 1 FROM test_preguntas
                                         WHERE pregunta_id = v_pid AND test_id <> p_test_id);
                IF v_compartida THEN
                    n_expl_compartidas := n_expl_compartidas + 1;
                ELSE
                    UPDATE preguntas SET explicacion = v_preg->>'explicacion', actualizado_en = now()
                     WHERE id = v_pid;
                    n_explicaciones := n_explicaciones + 1;
                END IF;
            END IF;
        ELSE
            -- ¿Una pregunta del test con el mismo enunciado, solo de este test?
            SELECT p.id INTO v_pid
              FROM preguntas p
             WHERE p.id = ANY(v_antes)
               AND NOT (p.id = ANY(v_despues))
               AND lower(btrim(p.enunciado)) = lower(btrim(v_preg->>'pregunta'))
               AND NOT EXISTS (SELECT 1 FROM test_preguntas tp
                                WHERE tp.pregunta_id = p.id AND tp.test_id <> p_test_id)
             LIMIT 1;
            IF v_pid IS NOT NULL THEN
                UPDATE preguntas
                   SET enunciado = v_preg->>'pregunta',
                       opciones = v_preg->'opciones',
                       explicacion = v_preg->>'explicacion',
                       etiquetas = (SELECT ARRAY(SELECT DISTINCT unnest(etiquetas || v_etiq))),
                       actualizado_en = now()
                 WHERE id = v_pid;
                n_corregidas := n_corregidas + 1;
            ELSE
                INSERT INTO preguntas(enunciado, opciones, explicacion, etiquetas, autor_id)
                VALUES (v_preg->>'pregunta', v_preg->'opciones', v_preg->>'explicacion',
                        v_etiq, jwt_usuario_id())
                RETURNING id INTO v_pid;
                n_nuevas := n_nuevas + 1;
            END IF;
        END IF;

        IF v_pid = ANY(v_despues) THEN
            n_repetidas := n_repetidas + 1;   -- la misma pregunta dos veces en el fichero
        ELSE
            v_despues := v_despues || v_pid;
        END IF;
    END LOOP;

    v_mismo_orden := v_antes = v_despues;
    IF NOT v_mismo_orden THEN
        DELETE FROM test_preguntas WHERE test_id = p_test_id;
        INSERT INTO test_preguntas(test_id, pregunta_id, posicion)
        SELECT p_test_id, pid, pos FROM unnest(v_despues) WITH ORDINALITY AS x(pid, pos);
    END IF;

    SELECT count(*) INTO n_retiradas FROM unnest(v_antes) a WHERE NOT (a = ANY(v_despues));
    IF p_borrar_huerfanas AND n_retiradas > 0 THEN
        WITH borradas AS (
            DELETE FROM preguntas p
             WHERE p.id = ANY(v_antes) AND NOT (p.id = ANY(v_despues))
               AND NOT EXISTS (SELECT 1 FROM test_preguntas tp WHERE tp.pregunta_id = p.id)
            RETURNING 1
        ) SELECT count(*) INTO n_borradas FROM borradas;
    END IF;

    RETURN jsonb_build_object(
        'id',                         p_test_id,
        'num_preguntas',              cardinality(v_despues),
        'sin_cambios',                v_mismo_orden AND n_corregidas = 0 AND n_explicaciones = 0,
        'reutilizadas',               n_reutilizadas,
        'corregidas',                 n_corregidas,
        'nuevas',                     n_nuevas,
        'explicaciones_actualizadas', n_explicaciones,
        'explicaciones_compartidas',  n_expl_compartidas,
        'repetidas_en_el_fichero',    n_repetidas,
        'retiradas',                  n_retiradas,
        'borradas',                   n_borradas
    );
END $fn$;

-- Crea el test en la oposición o, si ya hay uno con ese título, lo deja
-- con estas preguntas. `p_descripcion` NULL no toca la descripción.
CREATE OR REPLACE FUNCTION sincronizar_test_en_oposicion(
    p_oposicion_id uuid, p_titulo text, p_descripcion text, p_preguntas jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
    v_test uuid;
    v_res  jsonb;
    v_desc_antes text;
BEGIN
    IF NOT _puede_editar_tests() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    IF btrim(COALESCE(p_titulo, '')) = '' THEN RAISE EXCEPTION 'titulo_obligatorio'; END IF;
    IF NOT EXISTS (SELECT 1 FROM oposiciones WHERE id = p_oposicion_id) THEN
        RAISE EXCEPTION 'oposicion_no_encontrada'
            USING HINT = 'Lista las oposiciones con /rpc/listar_oposiciones_admin.';
    END IF;

    v_test := _test_de_oposicion_por_titulo(p_oposicion_id, p_titulo);
    IF v_test IS NULL THEN
        -- Las preguntas se crean con el mismo criterio que al reemplazar:
        -- un test vacío y después sus preguntas.
        PERFORM _normalizar_preguntas(p_preguntas);
        INSERT INTO tests(titulo, descripcion, autor_id)
        VALUES (btrim(p_titulo), NULLIF(btrim(COALESCE(p_descripcion, '')), ''), jwt_usuario_id())
        RETURNING id INTO v_test;
        INSERT INTO test_oposiciones(test_id, oposicion_id) VALUES (v_test, p_oposicion_id);
        v_res := reemplazar_preguntas_test(v_test, p_preguntas, true);
        RETURN v_res || jsonb_build_object('accion', 'CREADO', 'titulo', btrim(p_titulo));
    END IF;

    SELECT descripcion INTO v_desc_antes FROM tests WHERE id = v_test;
    v_res := reemplazar_preguntas_test(v_test, p_preguntas, true);
    IF p_descripcion IS NOT NULL
       AND NULLIF(btrim(p_descripcion), '') IS DISTINCT FROM v_desc_antes THEN
        PERFORM editar_test(v_test, NULL, p_descripcion);
        v_res := v_res || jsonb_build_object('sin_cambios', false);
    END IF;
    RETURN v_res || jsonb_build_object(
        'accion', CASE WHEN (v_res->>'sin_cambios')::boolean THEN 'SIN_CAMBIOS' ELSE 'ACTUALIZADO' END,
        'titulo', (SELECT titulo FROM tests WHERE id = v_test));
END $fn$;

-- Desenlaza un test de una oposición. Si ya no queda en ninguna y
-- `p_borrar_si_huerfano`, se borra con sus preguntas exclusivas.
CREATE OR REPLACE FUNCTION quitar_test_de_oposicion(
    p_test_id uuid, p_oposicion_id uuid, p_borrar_si_huerfano boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_borrado jsonb;
BEGIN
    IF NOT _puede_editar_tests() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    DELETE FROM test_oposiciones WHERE test_id = p_test_id AND oposicion_id = p_oposicion_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'test_no_esta_en_la_oposicion';
    END IF;
    IF p_borrar_si_huerfano AND NOT EXISTS (SELECT 1 FROM test_oposiciones WHERE test_id = p_test_id) THEN
        IF NOT (es_admin() OR tiene_permiso('test.borrar')) THEN RAISE EXCEPTION 'no_autorizado'; END IF;
        v_borrado := borrar_test_y_preguntas(p_test_id, true);
    END IF;
    RETURN jsonb_build_object('test_id', p_test_id, 'oposicion_id', p_oposicion_id,
                              'borrado', v_borrado IS NOT NULL, 'detalle', v_borrado);
END $fn$;

-- Edita una pregunta en todos los tests que la usan. NULL deja el campo
-- como está; una explicación '' la borra. Las opciones aceptan los dos
-- formatos de la subida.
CREATE OR REPLACE FUNCTION editar_pregunta(
    p_pregunta_id uuid,
    p_enunciado   text  DEFAULT NULL,
    p_opciones    jsonb DEFAULT NULL,
    p_explicacion text  DEFAULT NULL,
    p_etiquetas   text[] DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
    v_enun text;
    v_opc  jsonb;
BEGIN
    IF NOT (es_admin() OR tiene_permiso('pregunta.editar')) THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    SELECT enunciado, opciones INTO v_enun, v_opc FROM preguntas WHERE id = p_pregunta_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'pregunta_no_encontrada'; END IF;
    IF p_enunciado IS NOT NULL THEN
        IF btrim(p_enunciado) = '' THEN
            RAISE EXCEPTION 'pregunta_invalida' USING DETAIL = 'El enunciado no puede quedar vacío.';
        END IF;
        v_enun := btrim(p_enunciado);
    END IF;
    IF p_opciones IS NOT NULL THEN
        v_opc := _normalizar_opciones(p_opciones, 1);
    END IF;
    IF EXISTS (SELECT 1 FROM preguntas WHERE hash_contenido = _hash_pregunta(v_enun, v_opc)
                                         AND id <> p_pregunta_id) THEN
        RAISE EXCEPTION 'pregunta_duplicada'
            USING HINT = 'Ya existe otra pregunta con el mismo enunciado y las mismas opciones.';
    END IF;
    UPDATE preguntas
       SET enunciado   = v_enun,
           opciones    = v_opc,
           explicacion = CASE WHEN p_explicacion IS NULL THEN explicacion
                              ELSE NULLIF(btrim(p_explicacion), '') END,
           etiquetas   = COALESCE(p_etiquetas, etiquetas),
           actualizado_en = now()
     WHERE id = p_pregunta_id;
    RETURN (
        SELECT jsonb_build_object(
            'id', p.id, 'pregunta', p.enunciado, 'opciones', p.opciones,
            'explicacion', p.explicacion, 'etiquetas', p.etiquetas,
            'tests', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', t.id, 'titulo', t.titulo))
                                 FROM test_preguntas tp JOIN tests t ON t.id = tp.test_id
                                WHERE tp.pregunta_id = p.id), '[]'::jsonb))
          FROM preguntas p WHERE p.id = p_pregunta_id);
END $fn$;


GRANT EXECUTE ON FUNCTION _hash_pregunta(text, jsonb)                              TO web_user;
GRANT EXECUTE ON FUNCTION _normalizar_preguntas(jsonb)                             TO web_user;
GRANT EXECUTE ON FUNCTION _normalizar_opciones(jsonb, int)                         TO web_user;
GRANT EXECUTE ON FUNCTION _puede_editar_tests()                                    TO web_user;
GRANT EXECUTE ON FUNCTION _puede_ver_test(uuid)                                    TO web_user;
GRANT EXECUTE ON FUNCTION obtener_test(uuid)                                       TO web_user;
GRANT EXECUTE ON FUNCTION _test_de_oposicion_por_titulo(uuid, text)                TO web_user;
GRANT EXECUTE ON FUNCTION obtener_test_por_titulo(uuid, text)                      TO web_user;
GRANT EXECUTE ON FUNCTION tests_repetidos_de_oposicion(uuid, numeric)              TO web_user;
GRANT EXECUTE ON FUNCTION editar_test(uuid, text, text)                            TO web_user;
GRANT EXECUTE ON FUNCTION reemplazar_preguntas_test(uuid, jsonb, boolean)          TO web_user;
GRANT EXECUTE ON FUNCTION sincronizar_test_en_oposicion(uuid, text, text, jsonb)   TO web_user;
GRANT EXECUTE ON FUNCTION quitar_test_de_oposicion(uuid, uuid, boolean)            TO web_user;
GRANT EXECUTE ON FUNCTION editar_pregunta(uuid, text, jsonb, text, text[])         TO web_user;

COMMIT;

NOTIFY pgrst, 'reload schema';
