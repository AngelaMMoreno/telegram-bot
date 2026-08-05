-- =============================================================================
-- Aprentix Oposiciones · esquema limpio desde cero
-- PostgreSQL 16 + pgcrypto. La teoría y los tests dejan de ser áreas separadas:
-- todo cuelga de una oposición, con temas reutilizables y unidades con teoría y tests.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ───────────────────────── Identidad y acceso ───────────────────────────────
CREATE TABLE usuarios (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre_usuario text UNIQUE NOT NULL CHECK (length(nombre_usuario) >= 3),
    correo_electronico text UNIQUE NOT NULL CHECK (correo_electronico ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    correo_confirmado boolean NOT NULL DEFAULT false,
    correo_confirmacion_token text UNIQUE,
    correo_confirmacion_enviado_en timestamptz,
    password_hash text NOT NULL,
    activo boolean NOT NULL DEFAULT true,
    creado_en timestamptz NOT NULL DEFAULT now(),
    actualizado_en timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE roles (
    id text PRIMARY KEY,
    descripcion text NOT NULL
);

CREATE TABLE usuario_roles (
    usuario_id uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    rol_id text NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    PRIMARY KEY (usuario_id, rol_id)
);

CREATE TABLE sesiones_usuario (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    token_hash text UNIQUE NOT NULL,
    expira_en timestamptz NOT NULL,
    creada_en timestamptz NOT NULL DEFAULT now(),
    revocada_en timestamptz
);

-- ───────────────────────── Contenido por oposición ──────────────────────────
CREATE TABLE oposiciones (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre text UNIQUE NOT NULL,
    slug text UNIQUE NOT NULL CHECK (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
    descripcion text,
    fecha_examen date,
    activa boolean NOT NULL DEFAULT true,
    creado_en timestamptz NOT NULL DEFAULT now(),
    actualizado_en timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE temas (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    titulo text NOT NULL,
    slug text UNIQUE NOT NULL CHECK (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
    descripcion text,
    icono text NOT NULL DEFAULT '📚',
    reutilizable boolean NOT NULL DEFAULT true,
    creado_en timestamptz NOT NULL DEFAULT now(),
    actualizado_en timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE oposicion_temas (
    oposicion_id uuid NOT NULL REFERENCES oposiciones(id) ON DELETE CASCADE,
    tema_id uuid NOT NULL REFERENCES temas(id) ON DELETE RESTRICT,
    posicion int NOT NULL DEFAULT 1,
    peso numeric(5,2) NOT NULL DEFAULT 1,
    PRIMARY KEY (oposicion_id, tema_id),
    UNIQUE (oposicion_id, posicion)
);

CREATE TABLE unidades (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tema_id uuid NOT NULL REFERENCES temas(id) ON DELETE CASCADE,
    titulo text NOT NULL,
    slug text NOT NULL CHECK (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
    resumen text,
    teoria_markdown text NOT NULL DEFAULT '',
    duracion_estimada_min int NOT NULL DEFAULT 25 CHECK (duracion_estimada_min > 0),
    posicion int NOT NULL DEFAULT 1,
    creada_en timestamptz NOT NULL DEFAULT now(),
    actualizada_en timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tema_id, slug),
    UNIQUE (tema_id, posicion)
);

CREATE TABLE preguntas (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    unidad_id uuid NOT NULL REFERENCES unidades(id) ON DELETE CASCADE,
    enunciado text NOT NULL,
    opciones jsonb NOT NULL CHECK (jsonb_typeof(opciones) = 'array'),
    explicacion text,
    dificultad int NOT NULL DEFAULT 2 CHECK (dificultad BETWEEN 1 AND 5),
    posicion int NOT NULL DEFAULT 1,
    creada_en timestamptz NOT NULL DEFAULT now(),
    actualizada_en timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE usuario_oposiciones (
    usuario_id uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    oposicion_id uuid NOT NULL REFERENCES oposiciones(id) ON DELETE CASCADE,
    oposicion_principal boolean NOT NULL DEFAULT false,
    creada_en timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (usuario_id, oposicion_id)
);

-- ───────────────────────── Estudio, progreso y planes ──────────────────────
CREATE TABLE progreso_unidades (
    usuario_id uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    unidad_id uuid NOT NULL REFERENCES unidades(id) ON DELETE CASCADE,
    porcentaje numeric(5,2) NOT NULL DEFAULT 0 CHECK (porcentaje BETWEEN 0 AND 100),
    teoria_vista boolean NOT NULL DEFAULT false,
    tests_completados int NOT NULL DEFAULT 0,
    ultima_actividad_en timestamptz,
    PRIMARY KEY (usuario_id, unidad_id)
);

CREATE TABLE intentos_test (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    unidad_id uuid REFERENCES unidades(id) ON DELETE SET NULL,
    iniciado_en timestamptz NOT NULL DEFAULT now(),
    finalizado_en timestamptz,
    aciertos int NOT NULL DEFAULT 0,
    fallos int NOT NULL DEFAULT 0
);

CREATE TABLE respuestas_test (
    id bigserial PRIMARY KEY,
    intento_id uuid NOT NULL REFERENCES intentos_test(id) ON DELETE CASCADE,
    pregunta_id uuid NOT NULL REFERENCES preguntas(id) ON DELETE CASCADE,
    opcion_elegida text NOT NULL,
    correcta boolean NOT NULL,
    respondida_en timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE planes_estudio (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    oposicion_id uuid NOT NULL REFERENCES oposiciones(id) ON DELETE CASCADE,
    estado text NOT NULL DEFAULT 'borrador' CHECK (estado IN ('borrador','activo','pausado','completado')),
    fecha_inicio date NOT NULL DEFAULT current_date,
    fecha_objetivo date,
    disponibilidad jsonb NOT NULL DEFAULT '{}'::jsonb,
    preferencias jsonb NOT NULL DEFAULT '{}'::jsonb,
    creado_en timestamptz NOT NULL DEFAULT now(),
    actualizado_en timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE bloques_plan_estudio (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_id uuid NOT NULL REFERENCES planes_estudio(id) ON DELETE CASCADE,
    unidad_id uuid REFERENCES unidades(id) ON DELETE SET NULL,
    tipo text NOT NULL CHECK (tipo IN ('teoria','test','repaso','simulacro','descanso')),
    inicio_en timestamptz NOT NULL,
    duracion_min int NOT NULL CHECK (duracion_min > 0),
    completado_en timestamptz,
    notas text
);

-- ───────────────────────── Retos y logros ──────────────────────────────────
CREATE TABLE retos (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    codigo text UNIQUE NOT NULL,
    titulo text NOT NULL,
    descripcion text NOT NULL,
    periodo text NOT NULL CHECK (periodo IN ('diario','semanal','mensual')),
    objetivo int NOT NULL CHECK (objetivo > 0),
    xp int NOT NULL DEFAULT 20,
    icono text NOT NULL DEFAULT '🎯',
    activo boolean NOT NULL DEFAULT true
);

CREATE TABLE retos_usuario (
    usuario_id uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    reto_id uuid NOT NULL REFERENCES retos(id) ON DELETE CASCADE,
    periodo_inicio date NOT NULL,
    progreso int NOT NULL DEFAULT 0,
    completado_en timestamptz,
    PRIMARY KEY (usuario_id, reto_id, periodo_inicio)
);

CREATE TABLE logros (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    codigo text UNIQUE NOT NULL,
    titulo text NOT NULL,
    descripcion text NOT NULL,
    objetivo int NOT NULL DEFAULT 1,
    xp int NOT NULL DEFAULT 100,
    icono text NOT NULL DEFAULT '🏆',
    activo boolean NOT NULL DEFAULT true
);

CREATE TABLE logros_usuario (
    usuario_id uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    logro_id uuid NOT NULL REFERENCES logros(id) ON DELETE CASCADE,
    progreso int NOT NULL DEFAULT 0,
    obtenido_en timestamptz,
    PRIMARY KEY (usuario_id, logro_id)
);

CREATE TABLE usuario_gamificacion (
    usuario_id uuid PRIMARY KEY REFERENCES usuarios(id) ON DELETE CASCADE,
    xp_total int NOT NULL DEFAULT 0,
    nivel int NOT NULL DEFAULT 1,
    racha_actual int NOT NULL DEFAULT 0,
    racha_maxima int NOT NULL DEFAULT 0,
    ultimo_dia_activo date
);

-- ───────────────────────── RPCs principales ────────────────────────────────
CREATE OR REPLACE FUNCTION unaccent_fallback(p_texto text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT translate(coalesce(p_texto, ''), 'áàäâéèëêíìïîóòöôúùüûñçÁÀÄÂÉÈËÊÍÌÏÎÓÒÖÔÚÙÜÛÑÇ', 'aaaaeeeeiiiioooouuuuncAAAAEEEEIIIIOOOOUUUUNC')
$$;

CREATE OR REPLACE FUNCTION normalizar_slug(p_texto text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT regexp_replace(trim(both '-' from lower(unaccent_fallback(p_texto))), '[^a-z0-9]+', '-', 'g')
$$;

CREATE OR REPLACE FUNCTION registrar_web(
    p_nombre_usuario text,
    p_password text,
    p_correo_electronico text,
    p_correo_electronico_repetido text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_usuario usuarios;
    v_token text := encode(gen_random_bytes(24), 'hex');
BEGIN
    IF lower(coalesce(p_correo_electronico, '')) <> lower(coalesce(p_correo_electronico_repetido, '')) THEN
        RAISE EXCEPTION 'Los correos electrónicos no coinciden';
    END IF;
    IF length(coalesce(p_password, '')) < 6 THEN
        RAISE EXCEPTION 'La contraseña debe tener al menos 6 caracteres';
    END IF;

    INSERT INTO usuarios(nombre_usuario, correo_electronico, password_hash, correo_confirmacion_token, correo_confirmacion_enviado_en)
    VALUES (trim(p_nombre_usuario), lower(trim(p_correo_electronico)), crypt(p_password, gen_salt('bf')), v_token, now())
    RETURNING * INTO v_usuario;

    INSERT INTO usuario_gamificacion(usuario_id) VALUES (v_usuario.id);
    RETURN jsonb_build_object('id', v_usuario.id, 'nombre_usuario', v_usuario.nombre_usuario, 'correo_confirmacion_pendiente', true);
END;
$$;

CREATE OR REPLACE FUNCTION importar_oposicion_desde_json(p_documento jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_oposicion_id uuid;
    v_tema jsonb;
    v_unidad jsonb;
    v_pregunta jsonb;
    v_tema_id uuid;
    v_unidad_id uuid;
    v_pos_tema int := 0;
    v_pos_unidad int;
    v_pos_pregunta int;
    v_slug text;
BEGIN
    INSERT INTO oposiciones(nombre, slug, descripcion, fecha_examen)
    VALUES (p_documento->>'nombre', coalesce(p_documento->>'slug', normalizar_slug(p_documento->>'nombre')), p_documento->>'descripcion', nullif(p_documento->>'fecha_examen','')::date)
    ON CONFLICT (slug) DO UPDATE SET nombre = EXCLUDED.nombre, descripcion = EXCLUDED.descripcion, fecha_examen = EXCLUDED.fecha_examen, actualizado_en = now()
    RETURNING id INTO v_oposicion_id;

    FOR v_tema IN SELECT * FROM jsonb_array_elements(coalesce(p_documento->'temas','[]'::jsonb)) LOOP
        v_pos_tema := v_pos_tema + 1;
        v_slug := coalesce(v_tema->>'slug', normalizar_slug(v_tema->>'titulo'));
        INSERT INTO temas(titulo, slug, descripcion, icono)
        VALUES (v_tema->>'titulo', v_slug, v_tema->>'descripcion', coalesce(v_tema->>'icono','📚'))
        ON CONFLICT (slug) DO UPDATE SET titulo = EXCLUDED.titulo, descripcion = EXCLUDED.descripcion, icono = EXCLUDED.icono, actualizado_en = now()
        RETURNING id INTO v_tema_id;

        INSERT INTO oposicion_temas(oposicion_id, tema_id, posicion)
        VALUES (v_oposicion_id, v_tema_id, coalesce((v_tema->>'posicion')::int, v_pos_tema))
        ON CONFLICT (oposicion_id, tema_id) DO UPDATE SET posicion = EXCLUDED.posicion;

        v_pos_unidad := 0;
        FOR v_unidad IN SELECT * FROM jsonb_array_elements(coalesce(v_tema->'unidades','[]'::jsonb)) LOOP
            v_pos_unidad := v_pos_unidad + 1;
            INSERT INTO unidades(tema_id, titulo, slug, resumen, teoria_markdown, duracion_estimada_min, posicion)
            VALUES (v_tema_id, v_unidad->>'titulo', coalesce(v_unidad->>'slug', normalizar_slug(v_unidad->>'titulo')), v_unidad->>'resumen', coalesce(v_unidad->>'teoria_markdown',''), coalesce((v_unidad->>'duracion_estimada_min')::int,25), v_pos_unidad)
            ON CONFLICT (tema_id, slug) DO UPDATE SET resumen = EXCLUDED.resumen, teoria_markdown = EXCLUDED.teoria_markdown, duracion_estimada_min = EXCLUDED.duracion_estimada_min, actualizada_en = now()
            RETURNING id INTO v_unidad_id;

            v_pos_pregunta := 0;
            FOR v_pregunta IN SELECT * FROM jsonb_array_elements(coalesce(v_unidad->'preguntas','[]'::jsonb)) LOOP
                v_pos_pregunta := v_pos_pregunta + 1;
                INSERT INTO preguntas(unidad_id, enunciado, opciones, explicacion, dificultad, posicion)
                VALUES (v_unidad_id, v_pregunta->>'enunciado', v_pregunta->'opciones', v_pregunta->>'explicacion', coalesce((v_pregunta->>'dificultad')::int,2), v_pos_pregunta);
            END LOOP;
        END LOOP;
    END LOOP;
    RETURN v_oposicion_id;
END;
$$;

INSERT INTO roles(id, descripcion) VALUES
('admin','Administración completa'), ('opositora','Estudia oposiciones asignadas')
ON CONFLICT DO NOTHING;

INSERT INTO retos(codigo,titulo,descripcion,periodo,objetivo,xp,icono) VALUES
('racha_lectura','Sigue el camino','Completa una unidad de teoría hoy','diario',1,20,'🌱'),
('test_rapido','Test rápido','Responde 15 preguntas','diario',15,25,'✅'),
('semana_constante','Semana constante','Estudia 5 días esta semana','semanal',5,80,'🔥')
ON CONFLICT DO NOTHING;

INSERT INTO logros(codigo,titulo,descripcion,objetivo,xp,icono) VALUES
('primera_unidad','Primer brote','Completa tu primera unidad',1,100,'🌿'),
('primer_simulacro','Simulacro iniciado','Completa tu primer simulacro',1,150,'🎯'),
('racha_7','Una semana constante','Alcanza 7 días de racha',7,250,'🔥')
ON CONFLICT DO NOTHING;

-- ───────────────────────── Roles técnicos PostgREST y autenticación ────────
DO $$ BEGIN
    CREATE ROLE web_anon NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    CREATE ROLE web_user NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
    CREATE ROLE autenticador LOGIN;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
GRANT web_anon, web_user TO autenticador;
GRANT USAGE ON SCHEMA public TO web_anon, web_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO web_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO web_user;

CREATE OR REPLACE FUNCTION url_b64(data bytea) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT translate(replace(encode(data, 'base64'), E'\n', ''), '+/=', '-_')
$$;

CREATE OR REPLACE FUNCTION firmar_jwt(payload jsonb, secret text) RETURNS text
LANGUAGE sql AS $$
    WITH partes AS (
        SELECT url_b64(convert_to('{"alg":"HS256","typ":"JWT"}', 'utf8')) || '.' || url_b64(convert_to(payload::text, 'utf8')) AS contenido
    )
    SELECT contenido || '.' || url_b64(hmac(contenido::bytea, coalesce(current_setting('app.jwt_secret', true), 'dev-secret')::bytea, 'sha256'))
    FROM partes
$$;

CREATE OR REPLACE FUNCTION login_web(p_username text, p_password text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_usuario usuarios;
    v_roles text[];
    v_exp bigint := extract(epoch from now() + interval '12 hours')::bigint;
    v_token text;
BEGIN
    SELECT * INTO v_usuario
    FROM usuarios
    WHERE (nombre_usuario = p_username OR correo_electronico = lower(p_username))
      AND activo;

    IF v_usuario.id IS NULL OR v_usuario.password_hash <> crypt(p_password, v_usuario.password_hash) THEN
        RAISE EXCEPTION 'Usuario o contraseña incorrectos';
    END IF;

    SELECT coalesce(array_agg(rol_id), ARRAY['opositora']::text[]) INTO v_roles
    FROM usuario_roles WHERE usuario_id = v_usuario.id;

    v_token := firmar_jwt(jsonb_build_object(
        'role', 'web_user',
        'sub', v_usuario.id,
        'username', v_usuario.nombre_usuario,
        'email', v_usuario.correo_electronico,
        'roles', v_roles,
        'exp', v_exp
    ), coalesce(current_setting('app.jwt_secret', true), 'dev-secret'));

    RETURN jsonb_build_object(
        'token', v_token,
        'user', jsonb_build_object(
            'id', v_usuario.id,
            'username', v_usuario.nombre_usuario,
            'email', v_usuario.correo_electronico,
            'correo_confirmado', v_usuario.correo_confirmado,
            'roles', v_roles
        )
    );
END;
$$;

GRANT EXECUTE ON FUNCTION registrar_web(text,text,text,text) TO web_anon;
GRANT EXECUTE ON FUNCTION login_web(text,text) TO web_anon;
GRANT EXECUTE ON FUNCTION importar_oposicion_desde_json(jsonb) TO web_user;
