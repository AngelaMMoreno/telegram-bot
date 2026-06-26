-- ============================================================================
-- 01_schema.sql
-- Esquema base de Aprentix sobre PostgreSQL 16 + pgvector.
-- La pregunta es la entidad raíz; los tests son colecciones ordenadas.
-- Auth y RBAC en tablas propias (no se usan roles Postgres como identidad).
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;       -- gen_random_uuid, crypt, bcrypt, hmac
CREATE EXTENSION IF NOT EXISTS pg_trgm;        -- búsqueda textual difusa
CREATE EXTENSION IF NOT EXISTS vector;         -- pgvector (embeddings)

-- La firma de JWT se implementa en SQL puro sobre pgcrypto (HS256)
-- en 03_funciones.sql: no necesitamos la extensión externa pgjwt.
-- Los secretos llegan al servidor como GUCs personalizados (-c app.xxx=...)
-- y se leen con current_setting('app.jwt_secret') etc.

-- ─────────────────────────── Identidad ──────────────────────────────────────

CREATE TABLE usuarios (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    username        text UNIQUE NOT NULL,
    email           text UNIQUE,
    chat_id         text UNIQUE,
    password_hash   text,
    activo          boolean NOT NULL DEFAULT true,
    creado_en       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE roles (
    id          text PRIMARY KEY,
    descripcion text
);

CREATE TABLE permisos (
    id          text PRIMARY KEY,
    descripcion text
);

CREATE TABLE rol_permisos (
    rol_id      text REFERENCES roles(id)    ON DELETE CASCADE,
    permiso_id  text REFERENCES permisos(id) ON DELETE CASCADE,
    PRIMARY KEY (rol_id, permiso_id)
);

CREATE TABLE usuario_roles (
    usuario_id  uuid REFERENCES usuarios(id) ON DELETE CASCADE,
    rol_id      text REFERENCES roles(id)    ON DELETE CASCADE,
    PRIMARY KEY (usuario_id, rol_id)
);

CREATE TABLE codigos_vinculacion_telegram (
    codigo      text PRIMARY KEY,
    usuario_id  uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    expira_en   timestamptz NOT NULL
);

-- ─────────────────────────── Contenido ──────────────────────────────────────

CREATE TABLE preguntas (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    enunciado       text NOT NULL,
    opciones        jsonb NOT NULL,
    explicacion     text,
    -- Etiquetas (= tags = temas).  El auto-tagger las rellena tomando los
    -- nombres del catalogo_etiquetas por similitud; tú puedes editar a
    -- mano libremente, no se sobreescriben.
    etiquetas       text[] NOT NULL DEFAULT '{}',
    embedding       vector(384),
    autor_id        uuid REFERENCES usuarios(id) ON DELETE SET NULL,
    creado_en       timestamptz NOT NULL DEFAULT now(),
    actualizado_en  timestamptz NOT NULL DEFAULT now(),
    hash_contenido  text GENERATED ALWAYS AS
                    (md5(lower(btrim(enunciado)))) STORED UNIQUE
);

CREATE INDEX preguntas_emb_idx     ON preguntas USING hnsw (embedding vector_cosine_ops);
CREATE INDEX preguntas_enunciado_t ON preguntas USING gin  (enunciado gin_trgm_ops);
CREATE INDEX preguntas_etiquetas_i ON preguntas USING gin  (etiquetas);

-- Catálogo de etiquetas conocidas con embedding de su descripción.
-- El auto-tagger compara cada pregunta contra estas y añade las que
-- superen un umbral de similitud a preguntas.etiquetas[].
CREATE TABLE catalogo_etiquetas (
    nombre      text PRIMARY KEY,
    descripcion text,
    embedding   vector(384),
    creado_en   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX catalogo_etiquetas_emb_idx
    ON catalogo_etiquetas USING hnsw (embedding vector_cosine_ops);

-- ─────────────────────────── Tests ──────────────────────────────────────────

CREATE TABLE tests (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    titulo          text NOT NULL,
    descripcion     text,
    tipo            text NOT NULL DEFAULT 'manual'
                    CHECK (tipo IN ('manual','simulacro','errores','mega','favoritos','tematico')),
    autor_id        uuid REFERENCES usuarios(id) ON DELETE SET NULL,
    publico         boolean NOT NULL DEFAULT false,
    nota_corte      numeric,
    escala_maxima   numeric,
    creado_en       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE test_preguntas (
    test_id     uuid REFERENCES tests(id)     ON DELETE CASCADE,
    pregunta_id uuid REFERENCES preguntas(id) ON DELETE CASCADE,
    posicion    int NOT NULL,
    PRIMARY KEY (test_id, posicion)
);
CREATE INDEX test_preguntas_preg_idx ON test_preguntas (pregunta_id);

-- ─────────────────────────── Actividad ──────────────────────────────────────

CREATE TABLE intentos (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id      uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    test_id         uuid REFERENCES tests(id) ON DELETE SET NULL,
    nombre          text,
    tipo            text NOT NULL DEFAULT 'normal',
    iniciado_en     timestamptz NOT NULL DEFAULT now(),
    finalizado_en   timestamptz
);
CREATE INDEX intentos_usuario_idx ON intentos (usuario_id);

CREATE TABLE respuestas (
    id              bigserial PRIMARY KEY,
    intento_id      uuid NOT NULL REFERENCES intentos(id) ON DELETE CASCADE,
    pregunta_id     uuid NOT NULL REFERENCES preguntas(id) ON DELETE CASCADE,
    opcion_elegida  int NOT NULL,
    correcta        boolean NOT NULL,
    respondida_en   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX respuestas_intento_idx  ON respuestas (intento_id);
CREATE INDEX respuestas_pregunta_idx ON respuestas (pregunta_id);

-- Marcadores unifica failures, favorites y tests_favoritos
CREATE TABLE marcadores (
    usuario_id      uuid REFERENCES usuarios(id) ON DELETE CASCADE,
    tipo            text NOT NULL CHECK (tipo IN ('fallo','favorita','test_favorito')),
    pregunta_id     uuid REFERENCES preguntas(id) ON DELETE CASCADE,
    test_id         uuid REFERENCES tests(id)     ON DELETE CASCADE,
    contador        int NOT NULL DEFAULT 1,
    actualizado_en  timestamptz NOT NULL DEFAULT now(),
    CHECK (
        (tipo IN ('fallo','favorita') AND pregunta_id IS NOT NULL AND test_id IS NULL)
        OR
        (tipo = 'test_favorito' AND test_id IS NOT NULL AND pregunta_id IS NULL)
    )
);
CREATE UNIQUE INDEX marcadores_unico ON marcadores
    (usuario_id, tipo, COALESCE(pregunta_id, test_id));

-- ─────────────────────────── Cola de embeddings ─────────────────────────────
-- El worker Python escucha NOTIFY y procesa filas pendientes.

CREATE TABLE cola_embeddings (
    id          bigserial PRIMARY KEY,
    entidad     text NOT NULL CHECK (entidad IN ('pregunta','etiqueta')),
    entidad_id  text NOT NULL,    -- uuid en pregunta, nombre en etiqueta
    encolado_en timestamptz NOT NULL DEFAULT now(),
    procesado_en timestamptz
);
CREATE INDEX cola_emb_pendiente ON cola_embeddings (encolado_en)
    WHERE procesado_en IS NULL;

-- ─────────────────────────── Triggers de embedding ──────────────────────────

-- SECURITY DEFINER para que los triggers puedan insertar en cola_embeddings
-- aunque el cliente (web_user) solo tenga UPDATE en preguntas.
CREATE OR REPLACE FUNCTION encolar_embedding_pregunta() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    INSERT INTO cola_embeddings(entidad, entidad_id)
    VALUES ('pregunta', NEW.id::text);
    PERFORM pg_notify('embeddings', 'pregunta:' || NEW.id::text);
    RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION encolar_embedding_etiqueta() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    INSERT INTO cola_embeddings(entidad, entidad_id)
    VALUES ('etiqueta', NEW.nombre);
    PERFORM pg_notify('embeddings', 'etiqueta:' || NEW.nombre);
    RETURN NEW;
END $$;

CREATE TRIGGER preguntas_emb_ai
    AFTER INSERT ON preguntas
    FOR EACH ROW EXECUTE FUNCTION encolar_embedding_pregunta();

CREATE TRIGGER preguntas_emb_au
    AFTER UPDATE OF enunciado ON preguntas
    FOR EACH ROW WHEN (NEW.enunciado IS DISTINCT FROM OLD.enunciado)
    EXECUTE FUNCTION encolar_embedding_pregunta();

CREATE TRIGGER catalogo_etiquetas_emb_ai
    AFTER INSERT ON catalogo_etiquetas
    FOR EACH ROW EXECUTE FUNCTION encolar_embedding_etiqueta();

CREATE TRIGGER catalogo_etiquetas_emb_au
    AFTER UPDATE OF descripcion, nombre ON catalogo_etiquetas
    FOR EACH ROW WHEN (
        NEW.descripcion IS DISTINCT FROM OLD.descripcion
        OR NEW.nombre   IS DISTINCT FROM OLD.nombre
    )
    EXECUTE FUNCTION encolar_embedding_etiqueta();

-- ─────────────────────────── Roles Postgres para PostgREST ──────────────────
-- Un único rol de conexión; la identidad llega por JWT (claim sub).

CREATE ROLE web_anon   NOLOGIN;
CREATE ROLE web_user   NOLOGIN;
-- La contraseña del rol autenticador se fija en 02_seed.sql desde
-- la GUC app.auth_pass (inyectada por compose con -c).
CREATE ROLE autenticador LOGIN;
GRANT web_anon, web_user TO autenticador;

GRANT USAGE ON SCHEMA public TO web_anon, web_user;
-- Tablas RBAC (lectura pública, las usan políticas RLS via tiene_permiso())
GRANT SELECT ON rol_permisos, roles, permisos TO web_anon, web_user;
-- Tabla de usuarios: lectura controlada por RLS (cada uno ve su fila)
GRANT SELECT ON usuarios TO web_user;
-- Contenido
GRANT SELECT ON preguntas, tests, test_preguntas, catalogo_etiquetas TO web_user;
GRANT SELECT, INSERT, UPDATE, DELETE
    ON preguntas, tests, test_preguntas, catalogo_etiquetas,
       intentos, respuestas, marcadores
    TO web_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO web_user;

-- ─────────────────────────── RLS ────────────────────────────────────────────

ALTER TABLE usuarios            ENABLE ROW LEVEL SECURITY;
ALTER TABLE intentos            ENABLE ROW LEVEL SECURITY;
ALTER TABLE respuestas          ENABLE ROW LEVEL SECURITY;
ALTER TABLE marcadores          ENABLE ROW LEVEL SECURITY;
ALTER TABLE preguntas           ENABLE ROW LEVEL SECURITY;
ALTER TABLE tests               ENABLE ROW LEVEL SECURITY;
ALTER TABLE test_preguntas      ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalogo_etiquetas  ENABLE ROW LEVEL SECURITY;

-- Las políticas concretas se definen en 03_funciones.sql tras crear
-- las funciones auxiliares jwt_usuario_id() y tiene_permiso().
