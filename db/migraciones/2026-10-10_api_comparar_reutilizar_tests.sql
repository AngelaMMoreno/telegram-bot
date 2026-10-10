-- ─────────────────────────────────────────────────────────────────────────
-- API para comparar / actualizar tests y reutilizarlos entre oposiciones.
--
-- Contexto: un mismo test (p. ej. el de una unidad) se comparte entre
-- varias oposiciones y puede cambiar ligeramente entre versiones del
-- fichero. Estas RPCs permiten:
--
--   • asegurar_oposicion(nombre, descripcion)
--       Crea la oposición si no existe (sin distinguir mayúsculas) y
--       devuelve su id. Idempotente.
--   • exportar_test(test_id)
--       Contenido completo de un test (para staff, sin depender de RLS).
--   • comparar_test(test_id, preguntas)
--       Diferencias entre un test existente y un JSON candidato: qué
--       preguntas son iguales, modificadas (opciones/explicación),
--       renombradas (enunciado retocado), nuevas o eliminadas.
--   • actualizar_test(test_id, preguntas, ...)
--       Aplica solo lo que cambió, conservando el id de cada pregunta
--       (y con él el progreso, fallos y repasos de los usuarios).
--   • buscar_tests_existentes(titulo, preguntas)
--       Busca en TODOS los tests (de cualquier oposición) por título y/o
--       por contenido, para no volver a subir lo que ya existe.
--   • reutilizar_test_en_oposicion(test_id, oposicion_id)
--       Enlaza un test existente a otra oposición (sin copiarlo).
--   • sincronizar_test_en_oposicion(...)
--       Flujo todo-en-uno: decide si hay que no hacer nada, actualizar,
--       reutilizar un test existente, crear uno nuevo o revisar a mano.
--       Por defecto solo planifica (p_aplicar = false).
--
-- La identidad de una pregunta es el hash de su enunciado
-- (`preguntas.hash_contenido`, ya único), de modo que una misma pregunta
-- se reutiliza en todos los tests donde aparece.
--
-- También sustituye `subir_test_a_oposicion` (de 2026-10-08) por una
-- versión que comparte la validación del JSON con estas RPCs.
--
-- Requiere pg_trgm (ya instalada) y 2026-10-08_api_tests_oposicion.sql.
-- Idempotente.
-- ─────────────────────────────────────────────────────────────────────────
BEGIN;

-- ── Helpers internos (no expuestos a la API) ─────────────────────────────

CREATE OR REPLACE FUNCTION _norm_texto(p text) RETURNS text
LANGUAGE sql IMMUTABLE AS $fn$
    SELECT lower(btrim(regexp_replace(COALESCE(p, ''), '\s+', ' ', 'g')));
$fn$;

-- Opciones en formato objeto [{texto, correcta}], venga como venga.
CREATE OR REPLACE FUNCTION _opciones_normalizadas(p_opc jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $fn$
    SELECT COALESCE(jsonb_agg(
        CASE
            WHEN jsonb_typeof(e) = 'string'
                THEN jsonb_build_object('texto', e #>> '{}', 'correcta', i = 1)
            WHEN jsonb_typeof(e) = 'object' AND NOT (e ? 'correcta')
                THEN e || jsonb_build_object('correcta', i = 1)
            ELSE e
        END ORDER BY i
    ), '[]'::jsonb)
    FROM jsonb_array_elements(
             CASE WHEN jsonb_typeof(p_opc) = 'array' THEN p_opc ELSE '[]'::jsonb END
         ) WITH ORDINALITY AS a(e, i);
$fn$;

-- Forma canónica para comparar opciones: independiente del orden, de
-- mayúsculas y de espacios.
CREATE OR REPLACE FUNCTION _opciones_canon(p_opc jsonb) RETURNS jsonb
LANGUAGE sql IMMUTABLE AS $fn$
    SELECT COALESCE(jsonb_agg(x ORDER BY x->>'t', x->>'c'), '[]'::jsonb)
    FROM (
        SELECT jsonb_build_object(
                   't', _norm_texto(e->>'texto'),
                   'c', COALESCE((e->>'correcta')::boolean, false)
               ) AS x
        FROM jsonb_array_elements(_opciones_normalizadas(p_opc)) e
    ) s;
$fn$;

-- Valida el JSON de preguntas y devuelve el array (desenvuelve
-- {"preguntas": [...]}). Dos formatos de opciones:
--   ["correcta", "otra", ...]                      (la primera es la correcta)
--   [{"texto": "...", "correcta": true|false}, ...] (al menos una correcta)
CREATE OR REPLACE FUNCTION _validar_preguntas(p_preguntas jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE
    v_preguntas jsonb := p_preguntas;
    v_preg      jsonb;
    v_opc       jsonb;
    v_idx       int := 0;
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

        v_opc := v_preg->'opciones';
        IF jsonb_typeof(v_opc) IS DISTINCT FROM 'array'
           OR jsonb_array_length(v_opc) < 2 THEN
            RAISE EXCEPTION 'pregunta_invalida'
                USING DETAIL = 'Pregunta ' || v_idx || ': "opciones" debe ser un array de al menos 2 elementos.';
        END IF;

        IF jsonb_typeof(v_opc->0) = 'string' THEN
            IF EXISTS (
                SELECT 1 FROM jsonb_array_elements(v_opc) e
                WHERE jsonb_typeof(e) <> 'string' OR btrim(e #>> '{}') = ''
            ) THEN
                RAISE EXCEPTION 'pregunta_invalida'
                    USING DETAIL = 'Pregunta ' || v_idx || ': todas las opciones deben ser textos no vacíos.';
            END IF;
        ELSE
            IF EXISTS (
                SELECT 1 FROM jsonb_array_elements(v_opc) e
                WHERE jsonb_typeof(e) <> 'object'
                   OR btrim(COALESCE(e->>'texto', '')) = ''
                   OR jsonb_typeof(e->'correcta') IS DISTINCT FROM 'boolean'
            ) THEN
                RAISE EXCEPTION 'pregunta_invalida'
                    USING DETAIL = 'Pregunta ' || v_idx || ': cada opción debe ser {"texto": "...", "correcta": true|false}.';
            END IF;
            IF NOT EXISTS (
                SELECT 1 FROM jsonb_array_elements(v_opc) e
                WHERE (e->>'correcta')::boolean
            ) THEN
                RAISE EXCEPTION 'pregunta_invalida'
                    USING DETAIL = 'Pregunta ' || v_idx || ': ninguna opción está marcada como correcta.';
            END IF;
        END IF;
    END LOOP;

    RETURN v_preguntas;
END $fn$;

-- Motor de comparación. Empareja por hash de enunciado; los que no
-- empareja los cruza por similitud de enunciado (pg_trgm) para detectar
-- preguntas retocadas. Devuelve el detalle completo.
CREATE OR REPLACE FUNCTION _diff_test(
    p_test_id   uuid,
    p_preguntas jsonb,
    p_umbral    real DEFAULT 0.6
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_cand      jsonb;
    v_act       jsonb;
    v_pares     jsonb := '[]'::jsonb;
    v_usadas_c  int[]  := '{}';
    v_usadas_a  uuid[] := '{}';
    v_par       record;
    v_out       jsonb;
BEGIN
    -- Candidato (deduplicado por enunciado, conserva la primera posición).
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'pos',        s.pos,
               'enun',       s.enun,
               'h',          s.h,
               'oc',         _opciones_canon(s.opc),
               'opc',        _opciones_normalizadas(s.opc),
               'expl',       s.expl,
               'existe_id',  pr.id,
               'existe_oc',  CASE WHEN pr.id IS NULL THEN NULL ELSE _opciones_canon(pr.opciones) END
           ) ORDER BY s.pos), '[]'::jsonb)
      INTO v_cand
      FROM (
          SELECT DISTINCT ON (md5(lower(btrim(t.e->>'pregunta'))))
                 t.n::int                                AS pos,
                 btrim(t.e->>'pregunta')                 AS enun,
                 md5(lower(btrim(t.e->>'pregunta')))     AS h,
                 t.e->'opciones'                         AS opc,
                 NULLIF(btrim(t.e->>'explicacion'), '')  AS expl
          FROM jsonb_array_elements(p_preguntas) WITH ORDINALITY AS t(e, n)
          ORDER BY md5(lower(btrim(t.e->>'pregunta'))), t.n
      ) s
      LEFT JOIN preguntas pr ON pr.hash_contenido = s.h;

    -- Estado actual del test.
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'id',   s.id,
               'pos',  s.pos,
               'enun', s.enun,
               'h',    s.h,
               'oc',   _opciones_canon(s.opc),
               'opc',  s.opc,
               'expl', s.expl
           ) ORDER BY s.pos), '[]'::jsonb)
      INTO v_act
      FROM (
          SELECT DISTINCT ON (p.hash_contenido)
                 p.id, tp.posicion AS pos, p.enunciado AS enun,
                 p.hash_contenido AS h, p.opciones AS opc,
                 NULLIF(btrim(p.explicacion), '') AS expl
          FROM test_preguntas tp
          JOIN preguntas p ON p.id = tp.pregunta_id
          WHERE tp.test_id = p_test_id
          ORDER BY p.hash_contenido, tp.posicion
      ) s;

    -- Emparejado por similitud entre "nuevas" y "eliminadas": se asignan
    -- primero los pares más parecidos y cada pregunta se usa una vez. No
    -- se empareja con enunciados que ya existen como pregunta (en ese caso
    -- no es un retoque, es otra pregunta ya conocida).
    FOR v_par IN
        WITH
        c AS (SELECT * FROM jsonb_to_recordset(v_cand)
                AS x(pos int, enun text, h text, existe_id uuid)),
        a AS (SELECT * FROM jsonb_to_recordset(v_act)
                AS x(id uuid, pos int, enun text, h text))
        SELECT c.pos AS cpos, a.id AS aid,
               similarity(_norm_texto(c.enun), _norm_texto(a.enun)) AS sim
          FROM c CROSS JOIN a
         WHERE c.existe_id IS NULL
           AND NOT EXISTS (SELECT 1 FROM a a2 WHERE a2.h = c.h)
           AND NOT EXISTS (SELECT 1 FROM c c2 WHERE c2.h = a.h)
           AND similarity(_norm_texto(c.enun), _norm_texto(a.enun)) >= p_umbral
         ORDER BY sim DESC, c.pos, a.pos
    LOOP
        IF v_par.cpos = ANY (v_usadas_c) OR v_par.aid = ANY (v_usadas_a) THEN
            CONTINUE;
        END IF;
        v_usadas_c := v_usadas_c || v_par.cpos;
        v_usadas_a := v_usadas_a || v_par.aid;
        v_pares := v_pares || jsonb_build_object(
            'cpos', v_par.cpos, 'aid', v_par.aid, 'sim', round(v_par.sim::numeric, 3));
    END LOOP;

    WITH
    c  AS (SELECT * FROM jsonb_to_recordset(v_cand)
             AS x(pos int, enun text, h text, oc jsonb, opc jsonb, expl text,
                  existe_id uuid, existe_oc jsonb)),
    a  AS (SELECT * FROM jsonb_to_recordset(v_act)
             AS x(id uuid, pos int, enun text, h text, oc jsonb, opc jsonb, expl text)),
    pr AS (SELECT * FROM jsonb_to_recordset(v_pares) AS x(cpos int, aid uuid, sim numeric)),
    -- Pares (candidato, actual) por mismo enunciado.
    ig AS (SELECT c.pos AS cpos, a.pos AS apos, a.id,
                  (a.oc <> c.oc) AS d_opc,
                  (c.expl IS NOT NULL AND c.expl IS DISTINCT FROM a.expl) AS d_expl
             FROM c JOIN a ON a.h = c.h),
    -- Pares por similitud (enunciado retocado).
    rn AS (SELECT c.pos AS cpos, a.pos AS apos, a.id, pr.sim,
                  c.enun AS enun_nuevo, a.enun AS enun_actual,
                  (a.oc <> c.oc) AS d_opc,
                  (c.expl IS NOT NULL AND c.expl IS DISTINCT FROM a.expl) AS d_expl,
                  c.opc AS opc_nuevas, a.opc AS opc_actuales,
                  c.expl AS expl_nueva, a.expl AS expl_actual
             FROM pr JOIN c ON c.pos = pr.cpos JOIN a ON a.id = pr.aid),
    nu AS (SELECT c.* FROM c
            WHERE NOT EXISTS (SELECT 1 FROM a WHERE a.h = c.h)
              AND c.pos NOT IN (SELECT cpos FROM pr)),
    el AS (SELECT a.* FROM a
            WHERE NOT EXISTS (SELECT 1 FROM c WHERE c.h = a.h)
              AND a.id NOT IN (SELECT aid FROM pr)),
    mt AS (SELECT cpos, apos FROM ig UNION ALL SELECT cpos, apos FROM rn),
    mo AS (SELECT ig.*, c.enun, c.opc, c.expl, a.opc AS opc_act, a.expl AS expl_act
             FROM ig JOIN c ON c.pos = ig.cpos JOIN a ON a.id = ig.id
            WHERE ig.d_opc OR ig.d_expl)
    SELECT jsonb_build_object(
        'test_id', p_test_id,
        'identico', (NOT EXISTS (SELECT 1 FROM mo) AND NOT EXISTS (SELECT 1 FROM rn)
                     AND NOT EXISTS (SELECT 1 FROM nu) AND NOT EXISTS (SELECT 1 FROM el)),
        'resumen', jsonb_build_object(
            'candidato',    (SELECT count(*) FROM c),
            'actual',       (SELECT count(*) FROM a),
            'iguales',      (SELECT count(*) FROM ig WHERE NOT d_opc AND NOT d_expl),
            'modificadas',  (SELECT count(*) FROM mo),
            'renombradas',  (SELECT count(*) FROM rn),
            'nuevas',       (SELECT count(*) FROM nu),
            'eliminadas',   (SELECT count(*) FROM el),
            'orden_cambiado', EXISTS (
                SELECT 1 FROM (
                    SELECT apos, lag(apos) OVER (ORDER BY cpos) AS prev FROM mt
                ) o WHERE o.prev > o.apos)
        ),
        'modificadas', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'pregunta_id',        mo.id,
                'pregunta',           mo.enun,
                'posicion_actual',    mo.apos,
                'posicion_nueva',     mo.cpos,
                'cambios',            to_jsonb(array_remove(ARRAY[
                                          CASE WHEN mo.d_opc  THEN 'opciones'    END,
                                          CASE WHEN mo.d_expl THEN 'explicacion' END], NULL)),
                'opciones_actuales',  mo.opc_act,
                'opciones_nuevas',    mo.opc,
                'explicacion_actual', mo.expl_act,
                'explicacion_nueva',  mo.expl
            ) ORDER BY mo.cpos), '[]'::jsonb) FROM mo),
        'renombradas', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'pregunta_id',        rn.id,
                'similitud',          rn.sim,
                'pregunta_actual',    rn.enun_actual,
                'pregunta_nueva',     rn.enun_nuevo,
                'posicion_actual',    rn.apos,
                'posicion_nueva',     rn.cpos,
                'cambios',            to_jsonb(array_remove(ARRAY['enunciado',
                                          CASE WHEN rn.d_opc  THEN 'opciones'    END,
                                          CASE WHEN rn.d_expl THEN 'explicacion' END], NULL)),
                'opciones_actuales',  rn.opc_actuales,
                'opciones_nuevas',    rn.opc_nuevas,
                'explicacion_actual', rn.expl_actual,
                'explicacion_nueva',  rn.expl_nueva
            ) ORDER BY rn.cpos), '[]'::jsonb) FROM rn),
        'nuevas', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'posicion_nueva',      nu.pos,
                'pregunta',            nu.enun,
                'pregunta_existente_id', nu.existe_id,
                'opciones_difieren_de_la_existente',
                    (nu.existe_id IS NOT NULL AND nu.existe_oc <> nu.oc)
            ) ORDER BY nu.pos), '[]'::jsonb) FROM nu),
        'eliminadas', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'pregunta_id',     el.id,
                'pregunta',        el.enun,
                'posicion_actual', el.pos
            ) ORDER BY el.pos), '[]'::jsonb) FROM el)
    ) INTO v_out;

    RETURN v_out;
END $fn$;

-- Búsqueda de tests parecidos (título y/o contenido), en todas las
-- oposiciones. Solo considera tests de tipo 'manual'.
CREATE OR REPLACE FUNCTION _buscar_tests(
    p_titulo    text,
    p_preguntas jsonb,
    p_umbral    real DEFAULT 0.5
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_tn      text := _norm_texto(p_titulo);
    v_hashes  text[];
    v_ncand   int := 0;
    v_r       record;
    v_diff    jsonb;
    v_res     jsonb := '[]'::jsonb;
BEGIN
    IF p_preguntas IS NOT NULL THEN
        SELECT array_agg(DISTINCT md5(lower(btrim(e->>'pregunta'))))
          INTO v_hashes
          FROM jsonb_array_elements(p_preguntas) e;
        v_ncand := COALESCE(cardinality(v_hashes), 0);
    END IF;

    FOR v_r IN
        WITH comunes AS (
            SELECT tp.test_id, count(DISTINCT p.hash_contenido)::int AS n
              FROM test_preguntas tp
              JOIN preguntas p ON p.id = tp.pregunta_id
             WHERE v_hashes IS NOT NULL AND p.hash_contenido = ANY (v_hashes)
             GROUP BY tp.test_id
        ),
        base AS (
            SELECT t.id, t.titulo, t.descripcion,
                   (SELECT count(*) FROM test_preguntas x WHERE x.test_id = t.id)::int AS np,
                   COALESCE(c.n, 0) AS comunes,
                   (v_tn <> '' AND _norm_texto(t.titulo) = v_tn) AS mismo_titulo,
                   CASE WHEN v_tn <> '' THEN similarity(_norm_texto(t.titulo), v_tn)
                        ELSE 0 END AS sim
              FROM tests t
              LEFT JOIN comunes c ON c.test_id = t.id
             WHERE t.tipo = 'manual'
        )
        SELECT * FROM base
         WHERE mismo_titulo
            OR (v_ncand > 0 AND comunes::real / v_ncand >= p_umbral)
            OR (v_ncand = 0 AND sim >= p_umbral)
         ORDER BY (comunes::real / GREATEST(v_ncand, 1)) DESC, mismo_titulo DESC, sim DESC
         LIMIT 20
    LOOP
        v_diff := CASE WHEN p_preguntas IS NULL THEN NULL
                       ELSE _diff_test(v_r.id, p_preguntas) END;
        v_res := v_res || jsonb_build_object(
            'test_id',            v_r.id,
            'titulo',             v_r.titulo,
            'descripcion',        v_r.descripcion,
            'num_preguntas',      v_r.np,
            'mismo_titulo',       v_r.mismo_titulo,
            'similitud_titulo',   round(v_r.sim::numeric, 3),
            'preguntas_en_comun', v_r.comunes,
            'pct_del_candidato',  CASE WHEN v_ncand > 0
                                       THEN round(v_r.comunes::numeric / v_ncand, 3) END,
            'pct_del_test',       CASE WHEN v_ncand > 0 AND v_r.np > 0
                                       THEN round(v_r.comunes::numeric / v_r.np, 3) END,
            'identico',           v_diff->'identico',
            'orden_cambiado',     v_diff->'resumen'->'orden_cambiado',
            'resumen_diff',       v_diff->'resumen',
            'oposiciones',        COALESCE((
                SELECT jsonb_agg(jsonb_build_object('id', o.id, 'nombre', o.nombre)
                                 ORDER BY o.nombre)
                  FROM test_oposiciones tox
                  JOIN oposiciones o ON o.id = tox.oposicion_id
                 WHERE tox.test_id = v_r.id), '[]'::jsonb)
        );
    END LOOP;

    RETURN COALESCE((
        SELECT jsonb_agg(x ORDER BY (x->>'identico')::boolean DESC NULLS LAST,
                                    (x->>'pct_del_candidato')::numeric DESC NULLS LAST,
                                    (x->>'mismo_titulo')::boolean DESC,
                                    (x->>'similitud_titulo')::numeric DESC)
          FROM jsonb_array_elements(v_res) x
    ), '[]'::jsonb);
END $fn$;

-- Que estos helpers no cuelguen de /rpc/.
REVOKE ALL ON FUNCTION _norm_texto(text)                     FROM PUBLIC;
REVOKE ALL ON FUNCTION _opciones_normalizadas(jsonb)         FROM PUBLIC;
REVOKE ALL ON FUNCTION _opciones_canon(jsonb)                FROM PUBLIC;
REVOKE ALL ON FUNCTION _validar_preguntas(jsonb)             FROM PUBLIC;
REVOKE ALL ON FUNCTION _diff_test(uuid, jsonb, real)         FROM PUBLIC;
REVOKE ALL ON FUNCTION _buscar_tests(text, jsonb, real)      FROM PUBLIC;


-- ── subir_test_a_oposicion (misma API que 2026-10-08, validación común) ──

CREATE OR REPLACE FUNCTION subir_test_a_oposicion(
    p_oposicion_id uuid,
    p_titulo       text,
    p_descripcion  text,
    p_preguntas    jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
    v_titulo    text := btrim(COALESCE(p_titulo, ''));
    v_preguntas jsonb;
    v_test      uuid;
BEGIN
    IF NOT (es_admin() OR tiene_permiso('test.crear')) THEN
        RAISE EXCEPTION 'no_autorizado';
    END IF;
    IF v_titulo = '' THEN
        RAISE EXCEPTION 'titulo_obligatorio'
            USING HINT = 'Indica el nombre del test.';
    END IF;
    IF p_oposicion_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM oposiciones WHERE id = p_oposicion_id) THEN
        RAISE EXCEPTION 'oposicion_no_encontrada'
            USING HINT = 'Lista las oposiciones con /rpc/listar_oposiciones_admin.';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM   tests t
        JOIN   test_oposiciones tox ON tox.test_id = t.id
        WHERE  tox.oposicion_id = p_oposicion_id
          AND  lower(btrim(t.titulo)) = lower(v_titulo)
    ) THEN
        RAISE EXCEPTION 'test_duplicado'
            USING HINT = 'Ya existe un test con ese nombre en la oposición.';
    END IF;

    v_preguntas := _validar_preguntas(p_preguntas);

    v_test := importar_test_normalizado(
        v_titulo, NULLIF(btrim(COALESCE(p_descripcion, '')), ''), v_preguntas
    );
    UPDATE tests SET autor_id = jwt_usuario_id() WHERE id = v_test;
    INSERT INTO test_oposiciones(test_id, oposicion_id)
    VALUES (v_test, p_oposicion_id)
    ON CONFLICT DO NOTHING;

    RETURN jsonb_build_object(
        'id',            v_test,
        'titulo',        v_titulo,
        'descripcion',   NULLIF(btrim(COALESCE(p_descripcion, '')), ''),
        'oposicion_id',  p_oposicion_id,
        'num_preguntas', jsonb_array_length(v_preguntas)
    );
END $fn$;


-- ── Oposiciones ──────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION asegurar_oposicion(p_nombre text, p_descripcion text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
    v_nombre text := btrim(COALESCE(p_nombre, ''));
    v_id     uuid;
BEGIN
    IF NOT (es_admin() OR tiene_permiso('test.crear')) THEN
        RAISE EXCEPTION 'no_autorizado';
    END IF;
    IF v_nombre = '' THEN
        RAISE EXCEPTION 'nombre_obligatorio';
    END IF;

    SELECT id INTO v_id FROM oposiciones WHERE lower(nombre) = lower(v_nombre);
    IF FOUND THEN
        RETURN jsonb_build_object('id', v_id, 'nombre', v_nombre, 'creada', false);
    END IF;

    INSERT INTO oposiciones(nombre, descripcion)
    VALUES (v_nombre, NULLIF(btrim(COALESCE(p_descripcion, '')), ''))
    ON CONFLICT (lower(nombre)) DO NOTHING
    RETURNING id INTO v_id;

    IF v_id IS NULL THEN   -- otra transacción la creó entre medias
        SELECT id INTO v_id FROM oposiciones WHERE lower(nombre) = lower(v_nombre);
        RETURN jsonb_build_object('id', v_id, 'nombre', v_nombre, 'creada', false);
    END IF;
    RETURN jsonb_build_object('id', v_id, 'nombre', v_nombre, 'creada', true);
END $fn$;


-- ── Lectura / comparación ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION exportar_test(p_test_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $fn$
DECLARE v_out jsonb;
BEGIN
    IF NOT (es_admin() OR tiene_permiso('test.crear')) THEN
        RAISE EXCEPTION 'no_autorizado';
    END IF;
    SELECT jsonb_build_object(
        'id',          t.id,
        'titulo',      t.titulo,
        'descripcion', t.descripcion,
        'tipo',        t.tipo,
        'oposiciones', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('id', o.id, 'nombre', o.nombre)
                             ORDER BY o.nombre)
              FROM test_oposiciones tox JOIN oposiciones o ON o.id = tox.oposicion_id
             WHERE tox.test_id = t.id), '[]'::jsonb),
        'preguntas',   COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id',          p.id,
                       'pregunta',    p.enunciado,
                       'opciones',    _opciones_normalizadas(p.opciones),
                       'explicacion', p.explicacion,
                       'etiquetas',   p.etiquetas
                   ) ORDER BY tp.posicion)
              FROM test_preguntas tp JOIN preguntas p ON p.id = tp.pregunta_id
             WHERE tp.test_id = t.id), '[]'::jsonb)
    ) INTO v_out FROM tests t WHERE t.id = p_test_id;

    IF v_out IS NULL THEN RAISE EXCEPTION 'test_no_encontrado'; END IF;
    RETURN v_out;
END $fn$;

CREATE OR REPLACE FUNCTION comparar_test(
    p_test_id           uuid,
    p_preguntas         jsonb,
    p_umbral_renombre   real DEFAULT 0.6
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $fn$
BEGIN
    IF NOT (es_admin() OR tiene_permiso('test.crear')) THEN
        RAISE EXCEPTION 'no_autorizado';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM tests WHERE id = p_test_id) THEN
        RAISE EXCEPTION 'test_no_encontrado';
    END IF;
    RETURN _diff_test(p_test_id, _validar_preguntas(p_preguntas), p_umbral_renombre);
END $fn$;

CREATE OR REPLACE FUNCTION buscar_tests_existentes(
    p_titulo    text  DEFAULT NULL,
    p_preguntas jsonb DEFAULT NULL,
    p_umbral    real  DEFAULT 0.5
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $fn$
BEGIN
    IF NOT (es_admin() OR tiene_permiso('test.crear')) THEN
        RAISE EXCEPTION 'no_autorizado';
    END IF;
    IF btrim(COALESCE(p_titulo, '')) = '' AND p_preguntas IS NULL THEN
        RAISE EXCEPTION 'criterio_obligatorio'
            USING HINT = 'Indica p_titulo y/o p_preguntas.';
    END IF;
    RETURN _buscar_tests(
        p_titulo,
        CASE WHEN p_preguntas IS NULL THEN NULL ELSE _validar_preguntas(p_preguntas) END,
        p_umbral);
END $fn$;


-- ── Reutilizar un test en otra oposición ─────────────────────────────────

CREATE OR REPLACE FUNCTION reutilizar_test_en_oposicion(
    p_test_id uuid, p_oposicion_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE v_titulo text;
BEGIN
    IF NOT (es_admin() OR tiene_permiso('test.crear')) THEN
        RAISE EXCEPTION 'no_autorizado';
    END IF;
    SELECT titulo INTO v_titulo FROM tests WHERE id = p_test_id AND tipo = 'manual';
    IF NOT FOUND THEN RAISE EXCEPTION 'test_no_encontrado'; END IF;
    IF NOT EXISTS (SELECT 1 FROM oposiciones WHERE id = p_oposicion_id) THEN
        RAISE EXCEPTION 'oposicion_no_encontrada'
            USING HINT = 'Lista las oposiciones con /rpc/listar_oposiciones_admin.';
    END IF;

    IF EXISTS (SELECT 1 FROM test_oposiciones
                WHERE test_id = p_test_id AND oposicion_id = p_oposicion_id) THEN
        RETURN jsonb_build_object('test_id', p_test_id, 'titulo', v_titulo,
                                  'oposicion_id', p_oposicion_id,
                                  'asignado', false, 'ya_estaba', true);
    END IF;

    IF EXISTS (
        SELECT 1 FROM tests t JOIN test_oposiciones tox ON tox.test_id = t.id
         WHERE tox.oposicion_id = p_oposicion_id AND t.id <> p_test_id
           AND lower(btrim(t.titulo)) = lower(btrim(v_titulo))
    ) THEN
        RAISE EXCEPTION 'test_duplicado'
            USING HINT = 'La oposición ya tiene otro test con ese título.';
    END IF;

    INSERT INTO test_oposiciones(test_id, oposicion_id)
    VALUES (p_test_id, p_oposicion_id) ON CONFLICT DO NOTHING;

    RETURN jsonb_build_object('test_id', p_test_id, 'titulo', v_titulo,
                              'oposicion_id', p_oposicion_id,
                              'asignado', true, 'ya_estaba', false);
END $fn$;


-- ── Actualizar solo lo que cambió ────────────────────────────────────────
-- p_opciones (todas opcionales):
--   anadir_nuevas          (true)  añade las preguntas que no estaban
--   actualizar_modificadas (true)  actualiza opciones/explicación
--   aceptar_renombres      (false) trata enunciados retocados como la
--                                  misma pregunta (la edita) en vez de
--                                  quitar la vieja y añadir una nueva
--   eliminar_ausentes      (false) quita del test las que ya no vienen
--                                  (solo del test; la pregunta no se borra)
--   reordenar              (true)  usa el orden del JSON
--   umbral_renombre        (0.6)   similitud mínima de enunciado
-- Las preguntas se editan EN SITIO: conservan su id, así que los fallos y
-- repasos de los usuarios se mantienen. Como una pregunta puede estar en
-- varios tests, el cambio se ve en todos ellos.
CREATE OR REPLACE FUNCTION actualizar_test(
    p_test_id     uuid,
    p_preguntas   jsonb,
    p_titulo      text  DEFAULT NULL,
    p_descripcion text  DEFAULT NULL,
    p_opciones    jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
    v_opt_anadir  boolean := COALESCE((p_opciones->>'anadir_nuevas')::boolean, true);
    v_opt_actual  boolean := COALESCE((p_opciones->>'actualizar_modificadas')::boolean, true);
    v_opt_renomb  boolean := COALESCE((p_opciones->>'aceptar_renombres')::boolean, false);
    v_opt_elim    boolean := COALESCE((p_opciones->>'eliminar_ausentes')::boolean, false);
    v_opt_reorden boolean := COALESCE((p_opciones->>'reordenar')::boolean, true);
    v_umbral      real    := COALESCE((p_opciones->>'umbral_renombre')::real, 0.6);

    v_test        tests;
    v_preguntas   jsonb;
    v_diff        jsonb;
    v_c           jsonb;
    v_pos         int;
    v_h           text;
    v_seen        text[] := '{}';
    v_pid         uuid;
    v_mod         jsonb;
    v_ren         jsonb;
    v_final       jsonb := '[]'::jsonb;
    v_orden       uuid[];
    v_resto       uuid[];
    v_actual      uuid[];
    v_nuevo_titulo text := btrim(COALESCE(p_titulo, ''));

    n_mod int := 0;  n_ren int := 0;  n_cre int := 0;  n_reu int := 0;  n_quit int := 0;
    v_reordenado boolean := false;
    v_avisos     jsonb := '[]'::jsonb;
    v_ops        jsonb;
BEGIN
    IF NOT (es_admin() OR tiene_permiso('test.crear')) THEN
        RAISE EXCEPTION 'no_autorizado';
    END IF;
    SELECT * INTO v_test FROM tests WHERE id = p_test_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'test_no_encontrado'; END IF;
    IF v_test.tipo <> 'manual' THEN
        RAISE EXCEPTION 'test_no_editable'
            USING HINT = 'Solo se pueden actualizar tests de tipo manual.';
    END IF;

    v_preguntas := _validar_preguntas(p_preguntas);
    v_diff      := _diff_test(p_test_id, v_preguntas, v_umbral);

    -- Título nuevo: no puede chocar con otro test de ninguna de sus oposiciones.
    IF v_nuevo_titulo <> '' AND lower(v_nuevo_titulo) <> lower(btrim(v_test.titulo)) THEN
        IF EXISTS (
            SELECT 1
            FROM test_oposiciones mine
            JOIN test_oposiciones otro ON otro.oposicion_id = mine.oposicion_id
                                      AND otro.test_id <> mine.test_id
            JOIN tests t ON t.id = otro.test_id
            WHERE mine.test_id = p_test_id
              AND lower(btrim(t.titulo)) = lower(v_nuevo_titulo)
        ) THEN
            RAISE EXCEPTION 'test_duplicado'
                USING HINT = 'Otro test de una de sus oposiciones ya se llama así.';
        END IF;
    END IF;

    SELECT COALESCE(array_agg(pregunta_id ORDER BY posicion), '{}')
      INTO v_actual FROM test_preguntas WHERE test_id = p_test_id;

    FOR v_c, v_pos IN
        SELECT e, n::int FROM jsonb_array_elements(v_preguntas) WITH ORDINALITY AS t(e, n)
    LOOP
        v_h := md5(lower(btrim(v_c->>'pregunta')));
        IF v_h = ANY (v_seen) THEN CONTINUE; END IF;
        v_seen := v_seen || v_h;

        SELECT p.id INTO v_pid
          FROM test_preguntas tp JOIN preguntas p ON p.id = tp.pregunta_id
         WHERE tp.test_id = p_test_id AND p.hash_contenido = v_h
         LIMIT 1;

        IF FOUND THEN
            -- Mismo enunciado ya en el test: igual o modificada.
            SELECT m INTO v_mod FROM jsonb_array_elements(v_diff->'modificadas') m
             WHERE (m->>'pregunta_id')::uuid = v_pid;
            IF v_mod IS NOT NULL AND v_opt_actual THEN
                UPDATE preguntas
                   SET opciones    = CASE WHEN v_mod->'cambios' ? 'opciones'
                                          THEN _opciones_normalizadas(v_c->'opciones')
                                          ELSE opciones END,
                       explicacion = CASE WHEN v_mod->'cambios' ? 'explicacion'
                                          THEN NULLIF(btrim(v_c->>'explicacion'), '')
                                          ELSE explicacion END,
                       -- Solo un cambio de opciones invalida respuestas en curso.
                       actualizado_en = CASE WHEN v_mod->'cambios' ? 'opciones'
                                             THEN now() ELSE actualizado_en END
                 WHERE id = v_pid;
                n_mod := n_mod + 1;
            END IF;
            v_final := v_final || jsonb_build_object('id', v_pid, 'cpos', v_pos);
        ELSE
            SELECT r INTO v_ren FROM jsonb_array_elements(v_diff->'renombradas') r
             WHERE (r->>'posicion_nueva')::int = v_pos;

            IF v_ren IS NOT NULL AND v_opt_renomb THEN
                v_pid := (v_ren->>'pregunta_id')::uuid;
                UPDATE preguntas
                   SET enunciado   = btrim(v_c->>'pregunta'),
                       opciones    = _opciones_normalizadas(v_c->'opciones'),
                       explicacion = COALESCE(NULLIF(btrim(v_c->>'explicacion'), ''), explicacion),
                       actualizado_en = now()
                 WHERE id = v_pid;
                n_ren := n_ren + 1;
                v_final := v_final || jsonb_build_object('id', v_pid, 'cpos', v_pos);
            ELSIF v_opt_anadir THEN
                SELECT id INTO v_pid FROM preguntas WHERE hash_contenido = v_h;
                IF FOUND THEN
                    -- Ya existe en otro test: se reutiliza tal cual.
                    n_reu := n_reu + 1;
                    IF _opciones_canon(v_c->'opciones')
                         <> (SELECT _opciones_canon(opciones) FROM preguntas WHERE id = v_pid) THEN
                        v_avisos := v_avisos || jsonb_build_object(
                            'posicion_nueva', v_pos, 'pregunta_id', v_pid,
                            'aviso', 'La pregunta ya existía con otras opciones y no se ha modificado (puede estar en otros tests).');
                    END IF;
                ELSE
                    INSERT INTO preguntas(enunciado, opciones, explicacion, etiquetas, autor_id)
                    VALUES (btrim(v_c->>'pregunta'),
                            _opciones_normalizadas(v_c->'opciones'),
                            NULLIF(btrim(v_c->>'explicacion'), ''),
                            COALESCE(ARRAY(SELECT jsonb_array_elements_text(v_c->'etiquetas')),
                                     ARRAY[]::text[]),
                            jwt_usuario_id())
                    RETURNING id INTO v_pid;
                    n_cre := n_cre + 1;
                END IF;
                v_final := v_final || jsonb_build_object('id', v_pid, 'cpos', v_pos);
            END IF;
        END IF;
        v_mod := NULL;  v_ren := NULL;
    END LOOP;

    -- Orden final: el del JSON, o (sin reordenar) las existentes donde
    -- estaban y las nuevas al final.
    SELECT COALESCE(array_agg(f.id ORDER BY
               CASE WHEN v_opt_reorden THEN 0 WHEN tp.posicion IS NULL THEN 1 ELSE 0 END,
               CASE WHEN v_opt_reorden THEN f.cpos ELSE COALESCE(tp.posicion, 0) END,
               f.cpos), '{}')
      INTO v_orden
      FROM jsonb_to_recordset(v_final) AS f(id uuid, cpos int)
      LEFT JOIN test_preguntas tp ON tp.test_id = p_test_id AND tp.pregunta_id = f.id;

    -- Las que no vienen en el JSON: se quedan al final, salvo eliminar_ausentes.
    SELECT COALESCE(array_agg(pregunta_id ORDER BY posicion), '{}')
      INTO v_resto FROM test_preguntas
     WHERE test_id = p_test_id AND NOT (pregunta_id = ANY (v_orden));
    IF v_opt_elim THEN
        n_quit := cardinality(v_resto);
        v_resto := '{}';
    END IF;
    v_orden := v_orden || v_resto;

    IF v_orden IS DISTINCT FROM v_actual THEN
        DELETE FROM test_preguntas WHERE test_id = p_test_id;
        INSERT INTO test_preguntas(test_id, pregunta_id, posicion)
        SELECT p_test_id, x.id, x.ord::int
          FROM unnest(v_orden) WITH ORDINALITY AS x(id, ord);
        v_reordenado := v_opt_reorden
                        AND COALESCE((v_diff->'resumen'->>'orden_cambiado')::boolean, false);
    END IF;

    IF v_nuevo_titulo <> '' THEN
        UPDATE tests SET titulo = v_nuevo_titulo WHERE id = p_test_id;
    END IF;
    IF p_descripcion IS NOT NULL THEN
        UPDATE tests SET descripcion = NULLIF(btrim(p_descripcion), '') WHERE id = p_test_id;
    END IF;

    SELECT COALESCE(jsonb_agg(jsonb_build_object('id', o.id, 'nombre', o.nombre)
                              ORDER BY o.nombre), '[]'::jsonb)
      INTO v_ops
      FROM test_oposiciones tox JOIN oposiciones o ON o.id = tox.oposicion_id
     WHERE tox.test_id = p_test_id;

    RETURN jsonb_build_object(
        'test_id',        p_test_id,
        'num_preguntas',  cardinality(v_orden),
        'aplicado', jsonb_build_object(
            'modificadas',          n_mod,
            'renombradas',          n_ren,
            'nuevas_creadas',       n_cre,
            'nuevas_reutilizadas',  n_reu,
            'quitadas_del_test',    n_quit,
            'orden_cambiado',       v_reordenado
        ),
        'avisos',               v_avisos,
        'oposiciones_afectadas', v_ops,
        'diff_previo',          v_diff->'resumen'
    );
END $fn$;


-- ── Todo en uno: planificar / aplicar la subida de un test ───────────────
-- Por defecto (p_aplicar = false) solo devuelve el plan. Acciones:
--   sin_cambios  ya existe en la oposición idéntico
--   actualizar   existe en la oposición con diferencias → actualizar_test
--   reutilizar   existe idéntico en otra oposición → se enlaza, no se copia
--   crear        no existe nada parecido → se sube nuevo
--   revisar      hay candidatos dudosos: decide tú y repite con p_accion
--                ('crear' | 'reutilizar' | 'actualizar') y p_test_id
CREATE OR REPLACE FUNCTION sincronizar_test_en_oposicion(
    p_oposicion_id uuid,
    p_titulo       text,
    p_descripcion  text,
    p_preguntas    jsonb,
    p_aplicar      boolean DEFAULT false,
    p_accion       text    DEFAULT NULL,
    p_test_id      uuid    DEFAULT NULL,
    p_opciones     jsonb   DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $fn$
DECLARE
    v_titulo     text := btrim(COALESCE(p_titulo, ''));
    v_preguntas  jsonb;
    v_accion     text;
    v_base       uuid;
    v_motivo     text;
    v_diff       jsonb;
    v_cands      jsonb := '[]'::jsonb;
    v_ident      jsonb;
    v_en_opo     uuid;
    v_ncand      int;
    v_comunes    int;
    v_resultado  jsonb;
    v_aplicado   boolean := false;
    v_umbral     real := COALESCE((p_opciones->>'umbral_renombre')::real, 0.6);
BEGIN
    IF NOT (es_admin() OR tiene_permiso('test.crear')) THEN
        RAISE EXCEPTION 'no_autorizado';
    END IF;
    IF v_titulo = '' THEN RAISE EXCEPTION 'titulo_obligatorio'; END IF;
    IF NOT EXISTS (SELECT 1 FROM oposiciones WHERE id = p_oposicion_id) THEN
        RAISE EXCEPTION 'oposicion_no_encontrada'
            USING HINT = 'Lista las oposiciones con /rpc/listar_oposiciones_admin.';
    END IF;
    IF p_accion IS NOT NULL AND p_accion NOT IN ('crear', 'reutilizar', 'actualizar') THEN
        RAISE EXCEPTION 'accion_invalida'
            USING HINT = 'p_accion: crear | reutilizar | actualizar (o null para automático).';
    END IF;
    IF p_accion IN ('reutilizar', 'actualizar') AND p_test_id IS NULL THEN
        RAISE EXCEPTION 'test_id_obligatorio'
            USING HINT = 'Con p_accion = reutilizar/actualizar indica p_test_id.';
    END IF;

    v_preguntas := _validar_preguntas(p_preguntas);
    v_ncand := (SELECT count(DISTINCT md5(lower(btrim(e->>'pregunta'))))
                  FROM jsonb_array_elements(v_preguntas) e);

    IF p_accion IS NOT NULL THEN
        -- Decisión explícita del llamante.
        v_accion := p_accion;
        v_base   := p_test_id;
        v_motivo := 'Acción indicada por el llamante.';
        IF p_accion <> 'crear' THEN
            IF NOT EXISTS (SELECT 1 FROM tests WHERE id = v_base AND tipo = 'manual') THEN
                RAISE EXCEPTION 'test_no_encontrado';
            END IF;
            v_diff := _diff_test(v_base, v_preguntas, v_umbral);
        END IF;
    ELSE
        -- 1) ¿Ya hay un test con ese título en esta oposición?
        SELECT t.id INTO v_en_opo
          FROM tests t JOIN test_oposiciones tox ON tox.test_id = t.id
         WHERE tox.oposicion_id = p_oposicion_id
           AND lower(btrim(t.titulo)) = lower(v_titulo)
         LIMIT 1;

        IF v_en_opo IS NOT NULL THEN
            v_base := v_en_opo;
            v_diff := _diff_test(v_base, v_preguntas, v_umbral);
            v_comunes := (v_diff->'resumen'->>'iguales')::int
                       + (v_diff->'resumen'->>'modificadas')::int
                       + (v_diff->'resumen'->>'renombradas')::int;
            IF (v_diff->>'identico')::boolean
               AND NOT (v_diff->'resumen'->>'orden_cambiado')::boolean THEN
                v_accion := 'sin_cambios';
                v_motivo := 'Ya existe en la oposición con el mismo título y contenido.';
            ELSIF v_comunes::real / GREATEST(v_ncand, 1) < 0.5 THEN
                v_accion := 'revisar';
                v_motivo := 'Existe en la oposición un test con el mismo título pero el contenido '
                         || 'es muy distinto (menos del 50% de preguntas en común). Si es una '
                         || 'versión nueva del mismo test, repite con p_accion = actualizar y '
                         || 'p_test_id; si es otro test, cambia el título.';
                v_cands := jsonb_build_array(jsonb_build_object(
                    'test_id', v_base, 'mismo_titulo', true, 'en_esta_oposicion', true,
                    'resumen_diff', v_diff->'resumen'));
            ELSE
                v_accion := 'actualizar';
                v_motivo := 'Existe en la oposición con el mismo título pero con diferencias.';
            END IF;
        ELSE
            -- 2) ¿Existe ya (idéntico o parecido) en cualquier otra oposición?
            v_cands := _buscar_tests(v_titulo, v_preguntas, 0.5);
            SELECT c INTO v_ident FROM jsonb_array_elements(v_cands) c
             WHERE (c->>'identico')::boolean AND NOT (c->>'orden_cambiado')::boolean
             LIMIT 1;

            IF v_ident IS NOT NULL THEN
                v_base := (v_ident->>'test_id')::uuid;
                IF EXISTS (SELECT 1 FROM test_oposiciones
                            WHERE test_id = v_base AND oposicion_id = p_oposicion_id) THEN
                    v_accion := 'sin_cambios';
                    v_motivo := 'El contenido ya está en esta oposición bajo el título «'
                             || (v_ident->>'titulo') || '».';
                ELSE
                    v_accion := 'reutilizar';
                    v_motivo := 'Existe un test idéntico («' || (v_ident->>'titulo')
                             || '») en otra oposición: se enlaza en lugar de copiarlo.';
                END IF;
            ELSIF jsonb_array_length(v_cands) > 0 THEN
                v_accion := 'revisar';
                v_motivo := 'Hay tests parecidos (mismo título o contenido solapado) en otras '
                         || 'oposiciones. Decide y repite con p_accion = reutilizar | actualizar '
                         || '(con p_test_id) o crear.';
            ELSE
                v_accion := 'crear';
                v_motivo := 'No existe nada parecido.';
            END IF;
        END IF;
    END IF;

    -- Aplicación.
    IF p_aplicar AND v_accion IN ('crear', 'reutilizar', 'actualizar') THEN
        IF v_accion = 'crear' THEN
            v_resultado := subir_test_a_oposicion(p_oposicion_id, v_titulo, p_descripcion, v_preguntas);
            v_base := (v_resultado->>'id')::uuid;
        ELSIF v_accion = 'reutilizar' THEN
            v_resultado := reutilizar_test_en_oposicion(v_base, p_oposicion_id);
        ELSE
            v_resultado := actualizar_test(
                v_base, v_preguntas, NULL,
                NULLIF(btrim(COALESCE(p_descripcion, '')), ''), p_opciones);
            PERFORM reutilizar_test_en_oposicion(v_base, p_oposicion_id);
        END IF;
        v_aplicado := true;
    END IF;

    RETURN jsonb_build_object(
        'accion',       v_accion,
        'aplicado',     v_aplicado,
        'motivo',       v_motivo,
        'oposicion_id', p_oposicion_id,
        'test_id',      v_base,
        'diff',         v_diff,
        'candidatos',   v_cands,
        'resultado',    v_resultado
    );
END $fn$;


GRANT EXECUTE ON FUNCTION subir_test_a_oposicion(uuid, text, text, jsonb)        TO web_user;
GRANT EXECUTE ON FUNCTION asegurar_oposicion(text, text)                         TO web_user;
GRANT EXECUTE ON FUNCTION exportar_test(uuid)                                    TO web_user;
GRANT EXECUTE ON FUNCTION comparar_test(uuid, jsonb, real)                       TO web_user;
GRANT EXECUTE ON FUNCTION buscar_tests_existentes(text, jsonb, real)             TO web_user;
GRANT EXECUTE ON FUNCTION reutilizar_test_en_oposicion(uuid, uuid)               TO web_user;
GRANT EXECUTE ON FUNCTION actualizar_test(uuid, jsonb, text, text, jsonb)        TO web_user;
GRANT EXECUTE ON FUNCTION sincronizar_test_en_oposicion(uuid, text, text, jsonb, boolean, text, uuid, jsonb) TO web_user;

COMMIT;

NOTIFY pgrst, 'reload schema';
