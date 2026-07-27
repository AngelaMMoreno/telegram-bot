-- =============================================================================
-- 2026-07-27 · RPCs del panel de administración de contenido + selector inicial
-- de oposición para el alta de usuario.
--
-- Añade las funciones que la SPA `/estudio/` necesita para:
--
--   1. Que un usuario recién registrado pueda elegir en qué oposición se
--      presenta (sin depender de que un admin le asigne una manualmente):
--        - `listar_oposiciones_disponibles()`
--        - `elegir_oposicion(uuid)`
--
--   2. Un panel de administración que cubre la jerarquía completa
--      Oposición → Tema → Módulo → Sección → Preguntas + Documentos:
--        - CRUD oposiciones (`admin_*_oposicion`)
--        - CRUD temas         (`admin_*_tema` + asociación a oposiciones)
--        - CRUD módulos       (`admin_*_modulo`)
--        - CRUD secciones     (`admin_*_seccion`)
--        - CRUD preguntas     (`admin_*_pregunta` + `admin_preguntas_de_seccion`)
--        - CRUD documentos de teoría (metadatos; el fichero markdown vive en
--          el microservicio `teoria/` y lo sube la SPA con /api/subir).
--
-- Todas las RPCs de administración son SECURITY DEFINER y comprueban
-- `es_admin()` o el permiso funcional correspondiente. Idempotente:
-- CREATE OR REPLACE.
-- =============================================================================

BEGIN;

-- =============================================================================
-- Selector inicial de oposición (autoservicio del usuario)
-- =============================================================================

-- Todas las oposiciones activas del catálogo, para que la SPA pueda mostrar
-- un selector en el primer login. No requiere ser admin — se llama después
-- de verificar el email.
CREATE OR REPLACE FUNCTION listar_oposiciones_disponibles() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := jwt_usuario_id();
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id',          o.id,
            'nombre',      o.nombre,
            'descripcion', o.descripcion,
            'ya_elegida',  EXISTS (
                SELECT 1 FROM usuario_oposiciones uo
                 WHERE uo.usuario_id = v_uid AND uo.oposicion_id = o.id
            )
        ) ORDER BY o.nombre)
        FROM oposiciones o
        WHERE o.activa
    ), '[]'::jsonb);
END $$;

-- El usuario se apunta a la oposición elegida. Idempotente. Devuelve el
-- estado tras la inserción, para que la SPA pueda pintar "ya tienes N
-- oposiciones asignadas".
CREATE OR REPLACE FUNCTION elegir_oposicion(p_oposicion_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_ok  boolean;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    -- Sólo se permite apuntarse a oposiciones activas.
    SELECT true INTO v_ok FROM oposiciones WHERE id = p_oposicion_id AND activa;
    IF v_ok IS NULL THEN RAISE EXCEPTION 'oposicion_no_disponible'; END IF;
    INSERT INTO usuario_oposiciones (usuario_id, oposicion_id)
    VALUES (v_uid, p_oposicion_id)
    ON CONFLICT DO NOTHING;
    RETURN jsonb_build_object('ok', true, 'oposicion_id', p_oposicion_id);
END $$;

CREATE OR REPLACE FUNCTION desasignar_oposicion(p_oposicion_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := jwt_usuario_id();
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    DELETE FROM usuario_oposiciones
     WHERE usuario_id = v_uid AND oposicion_id = p_oposicion_id;
    RETURN jsonb_build_object('ok', true);
END $$;

GRANT EXECUTE ON FUNCTION listar_oposiciones_disponibles()  TO web_user;
GRANT EXECUTE ON FUNCTION elegir_oposicion(uuid)            TO web_user;
GRANT EXECUTE ON FUNCTION desasignar_oposicion(uuid)        TO web_user;


-- =============================================================================
-- Panel admin — helper de comprobación
-- =============================================================================
CREATE OR REPLACE FUNCTION _admin_o_permiso(p_permiso text) RETURNS void
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT (es_admin() OR tiene_permiso(p_permiso)) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
END $$;


-- =============================================================================
-- Panel admin — Oposiciones
-- =============================================================================

-- Listado completo con contadores para pintar la tabla de admin.
CREATE OR REPLACE FUNCTION admin_listar_oposiciones() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('oposicion.gestionar');
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id',          o.id,
            'nombre',      o.nombre,
            'descripcion', o.descripcion,
            'activa',      o.activa,
            'creado_en',   o.creado_en,
            'n_temas',     (SELECT count(*) FROM oposicion_temas ot WHERE ot.oposicion_id = o.id),
            'n_alumnos',   (SELECT count(*) FROM usuario_oposiciones uo WHERE uo.oposicion_id = o.id)
        ) ORDER BY o.nombre)
        FROM oposiciones o
    ), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION admin_crear_oposicion(
    p_nombre       text,
    p_descripcion  text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
    PERFORM _admin_o_permiso('oposicion.gestionar');
    IF p_nombre IS NULL OR btrim(p_nombre) = '' THEN
        RAISE EXCEPTION 'nombre_invalido';
    END IF;
    INSERT INTO oposiciones (nombre, descripcion)
    VALUES (btrim(p_nombre), NULLIF(btrim(COALESCE(p_descripcion,'')), ''))
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('ok', true, 'id', v_id);
END $$;

CREATE OR REPLACE FUNCTION admin_actualizar_oposicion(
    p_id           uuid,
    p_nombre       text  DEFAULT NULL,
    p_descripcion  text  DEFAULT NULL,
    p_activa       boolean DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('oposicion.gestionar');
    UPDATE oposiciones
       SET nombre      = COALESCE(NULLIF(btrim(p_nombre), ''), nombre),
           descripcion = COALESCE(p_descripcion, descripcion),
           activa      = COALESCE(p_activa, activa)
     WHERE id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'oposicion_no_encontrada'; END IF;
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION admin_borrar_oposicion(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('oposicion.gestionar');
    DELETE FROM oposiciones WHERE id = p_id;
    RETURN jsonb_build_object('ok', true);
END $$;

GRANT EXECUTE ON FUNCTION admin_listar_oposiciones()                            TO web_user;
GRANT EXECUTE ON FUNCTION admin_crear_oposicion(text, text)                     TO web_user;
GRANT EXECUTE ON FUNCTION admin_actualizar_oposicion(uuid, text, text, boolean) TO web_user;
GRANT EXECUTE ON FUNCTION admin_borrar_oposicion(uuid)                          TO web_user;


-- =============================================================================
-- Panel admin — Temas
-- =============================================================================

CREATE OR REPLACE FUNCTION admin_listar_temas(p_oposicion_id uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('contenido.editar');
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id',           t.id,
            'nombre',       t.nombre,
            'slug',         t.slug,
            'descripcion',  t.descripcion,
            'n_modulos',    (SELECT count(*) FROM modulos m WHERE m.tema_id = t.id),
            'n_secciones',  (SELECT count(*) FROM secciones s
                              JOIN modulos m ON m.id = s.modulo_id
                             WHERE m.tema_id = t.id),
            'n_preguntas',  (SELECT count(*) FROM preguntas p
                              JOIN secciones s ON s.id = p.seccion_id
                              JOIN modulos m ON m.id = s.modulo_id
                             WHERE m.tema_id = t.id),
            'orden',        ot.orden,
            'oposicion_ids', COALESCE(
                (SELECT jsonb_agg(oposicion_id) FROM oposicion_temas WHERE tema_id = t.id),
                '[]'::jsonb
            )
        ) ORDER BY COALESCE(ot.orden, 999), t.nombre)
        FROM temas t
        LEFT JOIN oposicion_temas ot
               ON ot.tema_id = t.id AND ot.oposicion_id = p_oposicion_id
        WHERE p_oposicion_id IS NULL OR ot.oposicion_id IS NOT NULL
    ), '[]'::jsonb);
END $$;

-- Sin extensión unaccent instalada; hacemos un mapeo manual para las vocales
-- españolas más frecuentes. Es suficiente para slugs cortos y humanos.
CREATE OR REPLACE FUNCTION unaccent_es(p_txt text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT translate(
        COALESCE(p_txt, ''),
        'áéíóúÁÉÍÓÚñÑüÜçÇàèìòùÀÈÌÒÙ',
        'aeiouAEIOUnNuUcCaeiouAEIOU'
    );
$$;

-- Helper: slugifica (sin dependencias externas).
CREATE OR REPLACE FUNCTION _slugify(p_txt text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT trim(both '-' from
                regexp_replace(
                    regexp_replace(lower(unaccent_es(p_txt)), '[^a-z0-9]+', '-', 'g'),
                    '-+', '-', 'g'));
$$;

CREATE OR REPLACE FUNCTION admin_crear_tema(
    p_nombre        text,
    p_descripcion   text DEFAULT NULL,
    p_oposicion_id  uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_id   uuid;
    v_slug text;
    v_ord  int;
BEGIN
    PERFORM _admin_o_permiso('contenido.crear');
    IF p_nombre IS NULL OR btrim(p_nombre) = '' THEN
        RAISE EXCEPTION 'nombre_invalido';
    END IF;
    v_slug := _slugify(p_nombre);
    -- Si ya existe un tema con este slug, añadimos sufijo hasta que sea único.
    WHILE EXISTS (SELECT 1 FROM temas WHERE slug = v_slug) LOOP
        v_slug := v_slug || '-' || substr(gen_random_uuid()::text, 1, 4);
    END LOOP;
    INSERT INTO temas (nombre, slug, descripcion)
    VALUES (btrim(p_nombre), v_slug, NULLIF(btrim(COALESCE(p_descripcion,'')), ''))
    RETURNING id INTO v_id;

    -- Si nos dan una oposición, asociamos y creamos también un módulo único
    -- por defecto para no forzar al admin a un segundo paso.
    IF p_oposicion_id IS NOT NULL THEN
        SELECT COALESCE(max(orden), 0) + 1 INTO v_ord
          FROM oposicion_temas WHERE oposicion_id = p_oposicion_id;
        INSERT INTO oposicion_temas (oposicion_id, tema_id, orden)
        VALUES (p_oposicion_id, v_id, v_ord)
        ON CONFLICT DO NOTHING;
    END IF;

    -- Un módulo "único" por defecto para que el admin pueda meter secciones
    -- sin pasos intermedios; si quiere partir el tema en varios módulos
    -- después, edita este o crea nuevos.
    INSERT INTO modulos (tema_id, nombre, orden, es_unico)
    VALUES (v_id, btrim(p_nombre), 1, true);

    RETURN jsonb_build_object('ok', true, 'id', v_id, 'slug', v_slug);
END $$;

CREATE OR REPLACE FUNCTION admin_actualizar_tema(
    p_id           uuid,
    p_nombre       text DEFAULT NULL,
    p_descripcion  text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('contenido.editar');
    UPDATE temas
       SET nombre      = COALESCE(NULLIF(btrim(p_nombre), ''), nombre),
           descripcion = COALESCE(p_descripcion, descripcion)
     WHERE id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'tema_no_encontrado'; END IF;
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION admin_borrar_tema(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('contenido.borrar');
    DELETE FROM temas WHERE id = p_id;
    RETURN jsonb_build_object('ok', true);
END $$;

-- Asocia un tema a una oposición (con orden).
CREATE OR REPLACE FUNCTION admin_asignar_tema_a_oposicion(
    p_oposicion_id uuid,
    p_tema_id      uuid,
    p_orden        int  DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_ord int;
BEGIN
    PERFORM _admin_o_permiso('oposicion.gestionar');
    SELECT COALESCE(p_orden,
                    (SELECT COALESCE(max(orden), 0) + 1 FROM oposicion_temas WHERE oposicion_id = p_oposicion_id))
      INTO v_ord;
    INSERT INTO oposicion_temas (oposicion_id, tema_id, orden)
    VALUES (p_oposicion_id, p_tema_id, v_ord)
    ON CONFLICT (oposicion_id, tema_id) DO UPDATE
        SET orden = EXCLUDED.orden;
    RETURN jsonb_build_object('ok', true, 'orden', v_ord);
END $$;

CREATE OR REPLACE FUNCTION admin_quitar_tema_de_oposicion(
    p_oposicion_id uuid,
    p_tema_id      uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('oposicion.gestionar');
    DELETE FROM oposicion_temas
     WHERE oposicion_id = p_oposicion_id AND tema_id = p_tema_id;
    RETURN jsonb_build_object('ok', true);
END $$;

GRANT EXECUTE ON FUNCTION admin_listar_temas(uuid)                             TO web_user;
GRANT EXECUTE ON FUNCTION admin_crear_tema(text, text, uuid)                   TO web_user;
GRANT EXECUTE ON FUNCTION admin_actualizar_tema(uuid, text, text)              TO web_user;
GRANT EXECUTE ON FUNCTION admin_borrar_tema(uuid)                              TO web_user;
GRANT EXECUTE ON FUNCTION admin_asignar_tema_a_oposicion(uuid, uuid, int)      TO web_user;
GRANT EXECUTE ON FUNCTION admin_quitar_tema_de_oposicion(uuid, uuid)           TO web_user;


-- =============================================================================
-- Panel admin — Módulos
-- =============================================================================

CREATE OR REPLACE FUNCTION admin_listar_modulos(p_tema_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('contenido.editar');
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id',           m.id,
            'nombre',       m.nombre,
            'orden',        m.orden,
            'es_unico',     m.es_unico,
            'n_secciones',  (SELECT count(*) FROM secciones s WHERE s.modulo_id = m.id),
            'n_preguntas',  (SELECT count(*) FROM preguntas p
                              JOIN secciones s ON s.id = p.seccion_id
                             WHERE s.modulo_id = m.id)
        ) ORDER BY m.orden)
        FROM modulos m
        WHERE m.tema_id = p_tema_id
    ), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION admin_crear_modulo(
    p_tema_id uuid,
    p_nombre  text,
    p_orden   int DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid; v_ord int;
BEGIN
    PERFORM _admin_o_permiso('contenido.crear');
    IF p_nombre IS NULL OR btrim(p_nombre) = '' THEN
        RAISE EXCEPTION 'nombre_invalido';
    END IF;
    SELECT COALESCE(p_orden,
                    (SELECT COALESCE(max(orden), 0) + 1 FROM modulos WHERE tema_id = p_tema_id))
      INTO v_ord;
    INSERT INTO modulos (tema_id, nombre, orden, es_unico)
    VALUES (p_tema_id, btrim(p_nombre), v_ord, false)
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('ok', true, 'id', v_id, 'orden', v_ord);
END $$;

CREATE OR REPLACE FUNCTION admin_actualizar_modulo(
    p_id     uuid,
    p_nombre text DEFAULT NULL,
    p_orden  int  DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('contenido.editar');
    UPDATE modulos
       SET nombre = COALESCE(NULLIF(btrim(p_nombre), ''), nombre),
           orden  = COALESCE(p_orden, orden)
     WHERE id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'modulo_no_encontrado'; END IF;
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION admin_borrar_modulo(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('contenido.borrar');
    DELETE FROM modulos WHERE id = p_id;
    RETURN jsonb_build_object('ok', true);
END $$;

GRANT EXECUTE ON FUNCTION admin_listar_modulos(uuid)                TO web_user;
GRANT EXECUTE ON FUNCTION admin_crear_modulo(uuid, text, int)       TO web_user;
GRANT EXECUTE ON FUNCTION admin_actualizar_modulo(uuid, text, int)  TO web_user;
GRANT EXECUTE ON FUNCTION admin_borrar_modulo(uuid)                 TO web_user;


-- =============================================================================
-- Panel admin — Secciones
-- =============================================================================

CREATE OR REPLACE FUNCTION admin_listar_secciones(p_modulo_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('contenido.editar');
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id',            s.id,
            'nombre',        s.nombre,
            'orden',         s.orden,
            'min_aprobado',  s.min_aprobado,
            'n_preg_test',   s.n_preg_test,
            'n_preguntas',   (SELECT count(*) FROM preguntas p WHERE p.seccion_id = s.id),
            'tiene_teoria',  EXISTS (SELECT 1 FROM documentos d
                                      WHERE d.seccion_id = s.id AND d.tipo = 'teoria')
        ) ORDER BY s.orden)
        FROM secciones s
        WHERE s.modulo_id = p_modulo_id
    ), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION admin_crear_seccion(
    p_modulo_id    uuid,
    p_nombre       text,
    p_orden        int     DEFAULT NULL,
    p_min_aprobado numeric DEFAULT 70,
    p_n_preg_test  int     DEFAULT 10
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid; v_ord int;
BEGIN
    PERFORM _admin_o_permiso('contenido.crear');
    IF p_nombre IS NULL OR btrim(p_nombre) = '' THEN
        RAISE EXCEPTION 'nombre_invalido';
    END IF;
    SELECT COALESCE(p_orden,
                    (SELECT COALESCE(max(orden), 0) + 1 FROM secciones WHERE modulo_id = p_modulo_id))
      INTO v_ord;
    INSERT INTO secciones (modulo_id, nombre, orden, min_aprobado, n_preg_test)
    VALUES (p_modulo_id, btrim(p_nombre), v_ord,
            COALESCE(p_min_aprobado, 70),
            COALESCE(p_n_preg_test, 10))
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('ok', true, 'id', v_id, 'orden', v_ord);
END $$;

CREATE OR REPLACE FUNCTION admin_actualizar_seccion(
    p_id           uuid,
    p_nombre       text    DEFAULT NULL,
    p_orden        int     DEFAULT NULL,
    p_min_aprobado numeric DEFAULT NULL,
    p_n_preg_test  int     DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('contenido.editar');
    UPDATE secciones
       SET nombre       = COALESCE(NULLIF(btrim(p_nombre), ''), nombre),
           orden        = COALESCE(p_orden, orden),
           min_aprobado = COALESCE(p_min_aprobado, min_aprobado),
           n_preg_test  = COALESCE(p_n_preg_test, n_preg_test)
     WHERE id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'seccion_no_encontrada'; END IF;
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION admin_borrar_seccion(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('contenido.borrar');
    DELETE FROM secciones WHERE id = p_id;
    RETURN jsonb_build_object('ok', true);
END $$;

GRANT EXECUTE ON FUNCTION admin_listar_secciones(uuid)                                   TO web_user;
GRANT EXECUTE ON FUNCTION admin_crear_seccion(uuid, text, int, numeric, int)             TO web_user;
GRANT EXECUTE ON FUNCTION admin_actualizar_seccion(uuid, text, int, numeric, int)        TO web_user;
GRANT EXECUTE ON FUNCTION admin_borrar_seccion(uuid)                                     TO web_user;


-- =============================================================================
-- Panel admin — Preguntas
-- =============================================================================

CREATE OR REPLACE FUNCTION admin_preguntas_de_seccion(p_seccion_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('pregunta.editar');
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id',           p.id,
            'enunciado',    p.enunciado,
            'opciones',     p.opciones,
            'explicacion',  p.explicacion,
            'actualizado_en', p.actualizado_en
        ) ORDER BY p.creado_en)
        FROM preguntas p
        WHERE p.seccion_id = p_seccion_id
    ), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION admin_crear_pregunta(
    p_seccion_id  uuid,
    p_enunciado   text,
    p_opciones    jsonb,
    p_explicacion text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
    PERFORM _admin_o_permiso('pregunta.crear');
    IF p_enunciado IS NULL OR btrim(p_enunciado) = '' THEN
        RAISE EXCEPTION 'enunciado_invalido';
    END IF;
    IF jsonb_typeof(p_opciones) <> 'array' OR jsonb_array_length(p_opciones) < 2 THEN
        RAISE EXCEPTION 'opciones_invalidas';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(p_opciones) e
         WHERE (e->>'correcta')::boolean IS TRUE
    ) THEN
        RAISE EXCEPTION 'ninguna_opcion_correcta';
    END IF;
    INSERT INTO preguntas (seccion_id, enunciado, opciones, explicacion, autor_id)
    VALUES (p_seccion_id, btrim(p_enunciado), p_opciones,
            NULLIF(btrim(COALESCE(p_explicacion,'')), ''),
            jwt_usuario_id())
    ON CONFLICT (hash_contenido) DO UPDATE
        -- Si ya existía otra pregunta con el MISMO enunciado, actualizamos su
        -- sección/opciones/explicación (los admins normalmente quieren
        -- "reasignar" la pregunta a la sección nueva) y devolvemos su id.
        SET seccion_id  = EXCLUDED.seccion_id,
            opciones    = EXCLUDED.opciones,
            explicacion = EXCLUDED.explicacion,
            actualizado_en = now()
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('ok', true, 'id', v_id);
END $$;

CREATE OR REPLACE FUNCTION admin_actualizar_pregunta(
    p_id          uuid,
    p_enunciado   text  DEFAULT NULL,
    p_opciones    jsonb DEFAULT NULL,
    p_explicacion text  DEFAULT NULL,
    p_seccion_id  uuid  DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('pregunta.editar');
    IF p_opciones IS NOT NULL THEN
        IF jsonb_typeof(p_opciones) <> 'array' OR jsonb_array_length(p_opciones) < 2 THEN
            RAISE EXCEPTION 'opciones_invalidas';
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM jsonb_array_elements(p_opciones) e
             WHERE (e->>'correcta')::boolean IS TRUE
        ) THEN
            RAISE EXCEPTION 'ninguna_opcion_correcta';
        END IF;
    END IF;
    UPDATE preguntas
       SET enunciado   = COALESCE(NULLIF(btrim(p_enunciado), ''), enunciado),
           opciones    = COALESCE(p_opciones, opciones),
           explicacion = COALESCE(p_explicacion, explicacion),
           seccion_id  = COALESCE(p_seccion_id, seccion_id),
           actualizado_en = now()
     WHERE id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'pregunta_no_encontrada'; END IF;
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION admin_borrar_pregunta(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('pregunta.borrar');
    DELETE FROM preguntas WHERE id = p_id;
    RETURN jsonb_build_object('ok', true);
END $$;

GRANT EXECUTE ON FUNCTION admin_preguntas_de_seccion(uuid)                                        TO web_user;
GRANT EXECUTE ON FUNCTION admin_crear_pregunta(uuid, text, jsonb, text)                           TO web_user;
GRANT EXECUTE ON FUNCTION admin_actualizar_pregunta(uuid, text, jsonb, text, uuid)                TO web_user;
GRANT EXECUTE ON FUNCTION admin_borrar_pregunta(uuid)                                             TO web_user;


-- =============================================================================
-- Panel admin — Documentos (teoría markdown)
-- =============================================================================
-- El fichero markdown vive en el microservicio `teoria/` (endpoint /api/subir
-- o /api/crear_md). Aquí sólo se guarda la RUTA relativa asociada al nodo
-- (sección/módulo/tema) para que la SPA sepa qué pedirle al microservicio.

CREATE OR REPLACE FUNCTION admin_upsert_documento(
    p_nivel      text,          -- 'tema' | 'modulo' | 'seccion'
    p_entidad_id uuid,
    p_tipo       text,          -- 'esquema' | 'teoria'
    p_ruta       text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
    PERFORM _admin_o_permiso('teoria.gestionar');
    IF p_nivel = 'seccion' THEN
        INSERT INTO documentos (nivel, seccion_id, tipo, ruta)
        VALUES ('seccion', p_entidad_id, p_tipo, p_ruta)
        ON CONFLICT (seccion_id, tipo) WHERE seccion_id IS NOT NULL DO UPDATE
            SET ruta = EXCLUDED.ruta, actualizado_en = now()
        RETURNING id INTO v_id;
    ELSIF p_nivel = 'modulo' THEN
        INSERT INTO documentos (nivel, modulo_id, tipo, ruta)
        VALUES ('modulo', p_entidad_id, p_tipo, p_ruta)
        ON CONFLICT (modulo_id, tipo) WHERE modulo_id IS NOT NULL DO UPDATE
            SET ruta = EXCLUDED.ruta, actualizado_en = now()
        RETURNING id INTO v_id;
    ELSIF p_nivel = 'tema' THEN
        INSERT INTO documentos (nivel, tema_id, tipo, ruta)
        VALUES ('tema', p_entidad_id, p_tipo, p_ruta)
        ON CONFLICT (tema_id, tipo) WHERE tema_id IS NOT NULL DO UPDATE
            SET ruta = EXCLUDED.ruta, actualizado_en = now()
        RETURNING id INTO v_id;
    ELSE
        RAISE EXCEPTION 'nivel_invalido';
    END IF;
    RETURN jsonb_build_object('ok', true, 'id', v_id);
END $$;

CREATE OR REPLACE FUNCTION admin_borrar_documento(p_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('teoria.gestionar');
    DELETE FROM documentos WHERE id = p_id;
    RETURN jsonb_build_object('ok', true);
END $$;

GRANT EXECUTE ON FUNCTION admin_upsert_documento(text, uuid, text, text)   TO web_user;
GRANT EXECUTE ON FUNCTION admin_borrar_documento(uuid)                     TO web_user;


NOTIFY pgrst, 'reload schema';

COMMIT;
