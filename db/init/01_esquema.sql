-- =============================================================================
-- 01_esquema.sql
-- Esquema y lógica completa de Aprentix sobre PostgreSQL 16 + pgvector.
--
-- Este fichero es la ÚNICA fuente de verdad del estado actual de la base de
-- datos: agrupa lo que antes vivía repartido en las migraciones 01..18. Se
-- ejecuta al arrancar el contenedor de Postgres (docker-entrypoint-initdb.d)
-- sobre una base vacía y deja el sistema listo para servir tráfico.
--
-- Para un despiece humano de tablas, columnas y funciones, ver
--   db/ESTADO_BBDD.md
-- =============================================================================


-- ─────────────────────────── Extensiones ────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS pgcrypto;    -- gen_random_uuid, crypt, hmac, bcrypt
CREATE EXTENSION IF NOT EXISTS pg_trgm;     -- búsqueda textual difusa (similarity, %>)
CREATE EXTENSION IF NOT EXISTS vector;      -- pgvector para embeddings


-- =============================================================================
--                                   TABLAS
-- =============================================================================


-- ─────────────────────────── Identidad ──────────────────────────────────────

CREATE TABLE usuarios (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    username        text UNIQUE NOT NULL,
    email           text UNIQUE,
    chat_id         text UNIQUE,                 -- Telegram, si está vinculado
    password_hash   text,                        -- bcrypt (pgcrypto)
    activo          boolean NOT NULL DEFAULT true,
    creado_en       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE roles (
    id          text PRIMARY KEY,                -- 'admin' | 'editor' | 'alumno'
    descripcion text
);

CREATE TABLE permisos (
    id          text PRIMARY KEY,                -- 'pregunta.crear', 'test.editar'…
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
    codigo      text PRIMARY KEY,                -- 6 dígitos generados por RPC
    usuario_id  uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    expira_en   timestamptz NOT NULL
);


-- ─────────────────────────── Contenido ──────────────────────────────────────

CREATE TABLE preguntas (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    enunciado       text NOT NULL,
    opciones        jsonb NOT NULL,              -- [{texto, correcta}, ...]
    explicacion     text,
    -- Etiquetas = tags = temas. El auto-tagger las añade por similitud pero
    -- nunca las sobreescribe: las que edites a mano sobreviven.
    etiquetas       text[] NOT NULL DEFAULT '{}',
    embedding       vector(1024),                -- BAAI/bge-m3
    autor_id        uuid REFERENCES usuarios(id) ON DELETE SET NULL,
    creado_en       timestamptz NOT NULL DEFAULT now(),
    actualizado_en  timestamptz NOT NULL DEFAULT now(),
    -- Hash sobre el enunciado normalizado para deduplicar preguntas iguales
    -- entre distintos tests importados.
    hash_contenido  text GENERATED ALWAYS AS
                    (md5(lower(btrim(enunciado)))) STORED UNIQUE
);

CREATE INDEX preguntas_emb_idx     ON preguntas USING hnsw (embedding vector_cosine_ops);
CREATE INDEX preguntas_enunciado_t ON preguntas USING gin  (enunciado gin_trgm_ops);
CREATE INDEX preguntas_etiquetas_i ON preguntas USING gin  (etiquetas);

-- Catálogo de etiquetas: cada una tiene descripción, palabras clave, un padre
-- opcional (jerarquía) y su propio embedding.
CREATE TABLE catalogo_etiquetas (
    nombre          text PRIMARY KEY,
    descripcion     text,
    palabras_clave  text[] NOT NULL DEFAULT '{}',
    padre           text REFERENCES catalogo_etiquetas(nombre)
                         ON UPDATE CASCADE ON DELETE SET NULL,
    embedding       vector(1024),
    creado_en       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX catalogo_etiquetas_emb_idx
    ON catalogo_etiquetas USING hnsw (embedding vector_cosine_ops);
CREATE INDEX catalogo_etiquetas_padre_idx
    ON catalogo_etiquetas (padre);


-- ─────────────────────────── Tests ──────────────────────────────────────────

CREATE TABLE tests (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    titulo          text NOT NULL,
    descripcion     text,
    tipo            text NOT NULL DEFAULT 'manual'
                    CHECK (tipo IN ('manual','simulacro','errores','mega',
                                    'favoritos','tematico')),
    etiquetas       text[] NOT NULL DEFAULT '{}',
    autor_id        uuid REFERENCES usuarios(id) ON DELETE SET NULL,
    publico         boolean NOT NULL DEFAULT false,
    nota_corte      numeric,                     -- solo tipo='simulacro'
    escala_maxima   numeric,                     -- solo tipo='simulacro'
    creado_en       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX tests_etiquetas_idx ON tests USING gin (etiquetas);

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
    -- Orden congelado de preguntas de este intento (para poder reanudar tras
    -- ediciones sin perder el orden ni las respuestas ya dadas).
    question_ids    uuid[],
    iniciado_en     timestamptz NOT NULL DEFAULT now(),
    finalizado_en   timestamptz
);
CREATE INDEX intentos_usuario_idx ON intentos (usuario_id);

CREATE TABLE respuestas (
    id              bigserial PRIMARY KEY,
    intento_id      uuid NOT NULL REFERENCES intentos(id) ON DELETE CASCADE,
    pregunta_id     uuid NOT NULL REFERENCES preguntas(id) ON DELETE CASCADE,
    -- Texto de la opción elegida (no un índice: sobrevive a reordenaciones
    -- de opciones dentro de la pregunta).
    opcion_elegida  text NOT NULL,
    correcta        boolean NOT NULL,
    respondida_en   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX respuestas_intento_idx  ON respuestas (intento_id);
CREATE INDEX respuestas_pregunta_idx ON respuestas (pregunta_id);

-- 'marcadores' unifica lo que antes eran tres tablas: fallos, favoritas y
-- tests favoritos. Sirve tanto para preguntas como para tests según 'tipo'.
CREATE TABLE marcadores (
    usuario_id      uuid REFERENCES usuarios(id) ON DELETE CASCADE,
    tipo            text NOT NULL CHECK (tipo IN ('fallo','favorita','test_favorito')),
    pregunta_id     uuid REFERENCES preguntas(id) ON DELETE CASCADE,
    test_id         uuid REFERENCES tests(id)     ON DELETE CASCADE,
    contador        int NOT NULL DEFAULT 1,      -- veces falladas (tipo='fallo')
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
-- El worker Python (servicio 'embeddings') escucha NOTIFY y procesa filas
-- pendientes.

CREATE TABLE cola_embeddings (
    id            bigserial PRIMARY KEY,
    entidad       text NOT NULL CHECK (entidad IN ('pregunta','etiqueta')),
    entidad_id    text NOT NULL,                 -- uuid en pregunta, nombre en etiqueta
    encolado_en   timestamptz NOT NULL DEFAULT now(),
    procesado_en  timestamptz
);
CREATE INDEX cola_emb_pendiente ON cola_embeddings (encolado_en)
    WHERE procesado_en IS NULL;


-- ─────────────────────────── Config y preferencias ──────────────────────────

CREATE TABLE config (
    clave  text PRIMARY KEY,
    valor  jsonb
);

CREATE TABLE preferencias_usuario (
    usuario_id     uuid PRIMARY KEY REFERENCES usuarios(id) ON DELETE CASCADE,
    ritmo_repaso   text NOT NULL DEFAULT 'normal'
                     CHECK (ritmo_repaso IN ('intensivo','normal','relajado')),
    actualizado_en timestamptz NOT NULL DEFAULT now()
);


-- ─────────────────────────── Motor de repasos (Leitner) ─────────────────────
-- Estado por (usuario, pregunta). La fecha del próximo repaso se DERIVA al
-- vuelo como ultima_en + intervalo(caja, ritmo_del_usuario); no se
-- materializa para no desincronizarse al cambiar el ritmo.

CREATE TABLE repasos (
    usuario_id   uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    pregunta_id  uuid NOT NULL REFERENCES preguntas(id) ON DELETE CASCADE,
    caja         int  NOT NULL DEFAULT 1 CHECK (caja BETWEEN 1 AND 7),
    aciertos     int  NOT NULL DEFAULT 0,
    fallos       int  NOT NULL DEFAULT 0,
    ultima_en    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (usuario_id, pregunta_id)
);
CREATE INDEX repasos_usuario_idx ON repasos (usuario_id, ultima_en);


-- ─────────────────────────── Ficheros vistos (teoría) ───────────────────────
-- Marca por (usuario, ruta_relativa) del material de teoría. La ruta es la
-- que la SPA de teoría muestra en la barra de navegación (p.ej.
-- '/tema-1/apuntes.pdf'), no la ruta en disco. El servicio de teoría
-- normaliza siempre a un path absoluto empezando por '/'.

CREATE TABLE ficheros_vistas (
    usuario_id  uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    ruta        text NOT NULL,
    vista_en    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (usuario_id, ruta)
);
CREATE INDEX ficheros_vistas_usuario_idx ON ficheros_vistas (usuario_id);


-- =============================================================================
--                              ROLES Y GRANTS
-- =============================================================================
-- Un único rol de conexión ('autenticador') usado por PostgREST; la identidad
-- llega por JWT (claim 'sub'). Los roles funcionales de la app (admin,
-- editor, alumno) viven en la tabla 'roles', NO como roles Postgres.

CREATE ROLE web_anon   NOLOGIN;
CREATE ROLE web_user   NOLOGIN;
CREATE ROLE autenticador LOGIN;
GRANT web_anon, web_user TO autenticador;

-- La contraseña real de 'autenticador' se fija más abajo desde app.auth_pass.

GRANT USAGE ON SCHEMA public TO web_anon, web_user;

-- Tablas RBAC: lectura pública (las políticas RLS las usan via tiene_permiso()).
GRANT SELECT ON rol_permisos, roles, permisos TO web_anon, web_user;

-- Usuarios: cada uno se ve a sí mismo (RLS).
GRANT SELECT ON usuarios TO web_user;

-- Contenido y actividad.
GRANT SELECT ON preguntas, tests, test_preguntas, catalogo_etiquetas TO web_user;
GRANT SELECT, INSERT, UPDATE, DELETE
    ON preguntas, tests, test_preguntas, catalogo_etiquetas,
       intentos, respuestas, marcadores,
       preferencias_usuario, repasos, ficheros_vistas
    TO web_user;

-- Cola de embeddings: los triggers de encolado son SECURITY DEFINER pero
-- damos INSERT/SELECT también como defensa en profundidad.
GRANT INSERT, SELECT ON cola_embeddings TO web_user;

-- Config: lectura para todos, escritura solo admin (RLS lo refuerza).
GRANT SELECT ON config TO web_user, web_anon;
GRANT INSERT, UPDATE, DELETE ON config TO web_user;

-- Secuencias generadas (bigserial…).
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO web_user;


-- =============================================================================
--                                    RLS
-- =============================================================================

ALTER TABLE usuarios              ENABLE ROW LEVEL SECURITY;
ALTER TABLE intentos              ENABLE ROW LEVEL SECURITY;
ALTER TABLE respuestas            ENABLE ROW LEVEL SECURITY;
ALTER TABLE marcadores            ENABLE ROW LEVEL SECURITY;
ALTER TABLE preguntas             ENABLE ROW LEVEL SECURITY;
ALTER TABLE tests                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE test_preguntas        ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalogo_etiquetas    ENABLE ROW LEVEL SECURITY;
ALTER TABLE config                ENABLE ROW LEVEL SECURITY;
ALTER TABLE preferencias_usuario  ENABLE ROW LEVEL SECURITY;
ALTER TABLE repasos               ENABLE ROW LEVEL SECURITY;
ALTER TABLE ficheros_vistas       ENABLE ROW LEVEL SECURITY;

-- Las políticas usan jwt_usuario_id(), tiene_permiso() y es_admin(), que se
-- definen a continuación.


-- =============================================================================
--                    HELPERS DE JWT, RBAC Y FIRMA DE TOKENS
-- =============================================================================
-- Firma JWT HS256 en SQL puro sobre pgcrypto (compatible con la verificación
-- de PostgREST); no necesitamos la extensión externa pgjwt.

CREATE OR REPLACE FUNCTION url_b64(data bytea) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT translate(encode(data, 'base64'), E'+/=\n', '-_');
$$;

CREATE OR REPLACE FUNCTION firmar_jwt(payload jsonb, secret text) RETURNS text
LANGUAGE sql AS $$
    WITH partes AS (
        SELECT url_b64(convert_to('{"alg":"HS256","typ":"JWT"}', 'utf8'))
               || '.' ||
               url_b64(convert_to(payload::text, 'utf8')) AS si
    )
    SELECT partes.si || '.' ||
           url_b64(hmac(partes.si::bytea, secret::bytea, 'sha256'))
    FROM partes;
$$;

-- SECURITY DEFINER para poder leer rol_permisos desde políticas RLS sin
-- necesitar GRANTs adicionales en el rol web_user.
CREATE OR REPLACE FUNCTION jwt_usuario_id() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT NULLIF(
        current_setting('request.jwt.claims', true)::jsonb->>'sub',
        ''
    )::uuid;
$$;

CREATE OR REPLACE FUNCTION jwt_roles() RETURNS text[]
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT COALESCE(
        ARRAY(SELECT jsonb_array_elements_text(
            current_setting('request.jwt.claims', true)::jsonb->'roles'
        )),
        ARRAY[]::text[]
    );
$$;

CREATE OR REPLACE FUNCTION tiene_permiso(p text) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT EXISTS (
        SELECT 1 FROM rol_permisos
        WHERE permiso_id = p AND rol_id = ANY (jwt_roles())
    );
$$;

CREATE OR REPLACE FUNCTION es_admin() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT 'admin' = ANY (jwt_roles());
$$;


-- =============================================================================
--                               POLÍTICAS RLS
-- =============================================================================

-- Usuarios: cada uno se ve a sí mismo; admin ve a todos.
CREATE POLICY usr_self       ON usuarios FOR SELECT USING (id = jwt_usuario_id() OR es_admin());
CREATE POLICY usr_admin_all  ON usuarios FOR ALL TO web_user USING (es_admin()) WITH CHECK (es_admin());

-- Preguntas y tests: lectura libre para autenticados; escritura por permiso.
CREATE POLICY preg_lectura ON preguntas FOR SELECT USING (jwt_usuario_id() IS NOT NULL);
CREATE POLICY preg_insert  ON preguntas FOR INSERT WITH CHECK (tiene_permiso('pregunta.crear'));
CREATE POLICY preg_update  ON preguntas FOR UPDATE USING  (tiene_permiso('pregunta.editar'));
CREATE POLICY preg_delete  ON preguntas FOR DELETE USING  (tiene_permiso('pregunta.borrar'));

CREATE POLICY test_lectura ON tests FOR SELECT
    USING (publico OR autor_id = jwt_usuario_id() OR es_admin());
CREATE POLICY test_insert  ON tests FOR INSERT WITH CHECK (tiene_permiso('test.crear'));
CREATE POLICY test_update  ON tests FOR UPDATE USING (tiene_permiso('test.editar') OR autor_id = jwt_usuario_id());
CREATE POLICY test_delete  ON tests FOR DELETE USING (tiene_permiso('test.borrar') OR autor_id = jwt_usuario_id());

CREATE POLICY tp_lectura   ON test_preguntas FOR SELECT USING (jwt_usuario_id() IS NOT NULL);
CREATE POLICY tp_escritura ON test_preguntas FOR ALL
    USING (tiene_permiso('test.editar')) WITH CHECK (tiene_permiso('test.editar'));

CREATE POLICY etiq_lectura   ON catalogo_etiquetas FOR SELECT USING (true);
CREATE POLICY etiq_escritura ON catalogo_etiquetas FOR ALL
    USING (tiene_permiso('etiqueta.gestionar'))
    WITH CHECK (tiene_permiso('etiqueta.gestionar'));

-- Cada usuario solo ve/edita lo suyo (admin ve todo).
CREATE POLICY mis_intentos ON intentos
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id() OR es_admin());

CREATE POLICY mis_respuestas ON respuestas
    USING (EXISTS (SELECT 1 FROM intentos i
                   WHERE i.id = respuestas.intento_id
                     AND (i.usuario_id = jwt_usuario_id() OR es_admin())))
    WITH CHECK (EXISTS (SELECT 1 FROM intentos i
                        WHERE i.id = respuestas.intento_id
                          AND i.usuario_id = jwt_usuario_id()));

CREATE POLICY mis_marcadores ON marcadores
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());

-- Config: lectura para cualquiera, escritura solo admin.
CREATE POLICY config_lectura ON config FOR SELECT USING (true);
CREATE POLICY config_admin   ON config FOR ALL TO web_user
    USING (es_admin()) WITH CHECK (es_admin());

CREATE POLICY pref_usuario_propio ON preferencias_usuario
    FOR ALL TO web_user
    USING (usuario_id = jwt_usuario_id())
    WITH CHECK (usuario_id = jwt_usuario_id());

CREATE POLICY repasos_propios ON repasos
    FOR ALL TO web_user
    USING (usuario_id = jwt_usuario_id())
    WITH CHECK (usuario_id = jwt_usuario_id());

CREATE POLICY vistas_propias ON ficheros_vistas
    FOR ALL TO web_user
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());


-- =============================================================================
--                        DEFAULTS DEPENDIENTES DE JWT
-- =============================================================================
-- Los INSERTs desde la SPA no necesitan enviar usuario_id/autor_id: la BBDD
-- los deriva del JWT.

ALTER TABLE intentos             ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE marcadores           ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE preguntas            ALTER COLUMN autor_id   SET DEFAULT jwt_usuario_id();
ALTER TABLE tests                ALTER COLUMN autor_id   SET DEFAULT jwt_usuario_id();
ALTER TABLE repasos              ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE ficheros_vistas      ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();


-- =============================================================================
--                       TRIGGERS DE ENCOLADO DE EMBEDDINGS
-- =============================================================================
-- SECURITY DEFINER para que puedan insertar en cola_embeddings aunque el
-- cliente solo tenga UPDATE en preguntas/catalogo_etiquetas.

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

-- Al editar enunciado o opciones se re-vectoriza (el worker calcula el
-- embedding sobre enunciado + opción correcta, así que las opciones importan).
CREATE TRIGGER preguntas_emb_au
    AFTER UPDATE OF enunciado, opciones ON preguntas
    FOR EACH ROW WHEN (
        NEW.enunciado IS DISTINCT FROM OLD.enunciado
        OR NEW.opciones IS DISTINCT FROM OLD.opciones
    )
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


-- =============================================================================
--                                    AUTH
-- =============================================================================

CREATE OR REPLACE FUNCTION registrarse(p_username text, p_password text, p_email text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_id uuid;
BEGIN
    IF length(p_username) < 3 OR length(p_password) < 6 THEN
        RAISE EXCEPTION 'datos_invalidos';
    END IF;
    INSERT INTO usuarios(username, email, password_hash)
    VALUES (p_username, p_email, crypt(p_password, gen_salt('bf', 12)))
    RETURNING id INTO v_id;
    INSERT INTO usuario_roles(usuario_id, rol_id) VALUES (v_id, 'alumno');
    RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION iniciar_sesion(p_username text, p_password text)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_usr      usuarios;
    v_roles    text[];
    v_payload  jsonb;
    v_secret   text := current_setting('app.jwt_secret');
BEGIN
    SELECT * INTO v_usr FROM usuarios WHERE username = p_username AND activo;
    IF v_usr.password_hash IS NULL
       OR v_usr.password_hash <> crypt(p_password, v_usr.password_hash) THEN
        RAISE EXCEPTION 'credenciales_invalidas';
    END IF;

    SELECT COALESCE(array_agg(rol_id), ARRAY[]::text[])
    INTO v_roles FROM usuario_roles WHERE usuario_id = v_usr.id;

    v_payload := jsonb_build_object(
        'sub',   v_usr.id,
        'role',  'web_user',
        'roles', v_roles,
        'exp',   extract(epoch FROM now() + interval '12 hours')::int
    );
    RETURN firmar_jwt(v_payload, v_secret);
END $$;

-- login_web devuelve al frontend el token JWT + los datos de sesión de
-- una vez, con la forma que el cliente espera.
CREATE OR REPLACE FUNCTION login_web(p_username text, p_password text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_token   text;
    v_usuario usuarios;
    v_roles   text[];
BEGIN
    v_token := iniciar_sesion(p_username, p_password);

    SELECT * INTO v_usuario FROM usuarios WHERE username = p_username;
    SELECT COALESCE(array_agg(rol_id), ARRAY[]::text[])
      INTO v_roles FROM usuario_roles WHERE usuario_id = v_usuario.id;

    RETURN jsonb_build_object(
        'token',           v_token,
        'user_id',         v_usuario.id,
        'username',        v_usuario.username,
        'roles',           v_roles,
        'puede_gestionar', ('test.crear' = ANY(
                                SELECT permiso_id FROM rol_permisos
                                WHERE rol_id = ANY(v_roles)
                            ))
                           OR ('admin' = ANY(v_roles))
    );
END $$;

CREATE OR REPLACE FUNCTION registrar_web(p_username text, p_password text,
                                          p_email text DEFAULT NULL,
                                          p_chat_id text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_id uuid;
BEGIN
    v_id := registrarse(p_username, p_password, p_email);
    IF p_chat_id IS NOT NULL AND p_chat_id <> '' THEN
        UPDATE usuarios SET chat_id = p_chat_id WHERE id = v_id;
    END IF;
    RETURN login_web(p_username, p_password);
END $$;

-- Vinculación de Telegram: código temporal de 6 dígitos.
CREATE OR REPLACE FUNCTION generar_codigo_telegram()
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_cod text;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    v_cod := lpad((floor(random()*1000000))::text, 6, '0');
    INSERT INTO codigos_vinculacion_telegram(codigo, usuario_id, expira_en)
    VALUES (v_cod, v_uid, now() + interval '10 minutes');
    RETURN v_cod;
END $$;

CREATE OR REPLACE FUNCTION canjear_codigo_telegram(p_codigo text, p_chat_id text)
RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_uid uuid;
BEGIN
    DELETE FROM codigos_vinculacion_telegram WHERE expira_en < now();
    SELECT usuario_id INTO v_uid FROM codigos_vinculacion_telegram
      WHERE codigo = p_codigo AND expira_en > now();
    IF v_uid IS NULL THEN RAISE EXCEPTION 'codigo_invalido'; END IF;
    UPDATE usuarios SET chat_id = p_chat_id WHERE id = v_uid;
    DELETE FROM codigos_vinculacion_telegram WHERE codigo = p_codigo;
    RETURN v_uid;
END $$;


-- =============================================================================
--                          SESIÓN, PROGRESO Y PERFIL
-- =============================================================================

CREATE OR REPLACE FUNCTION mi_sesion() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'user_id',          u.id,
        'username',         u.username,
        'roles',            jwt_roles(),
        'puede_gestionar',  tiene_permiso('test.crear')
                             OR tiene_permiso('pregunta.crear')
                             OR es_admin()
    )
    FROM usuarios u
    WHERE u.id = jwt_usuario_id();
$$;

CREATE OR REPLACE FUNCTION mi_progreso() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'respondidas_hoy', (
            SELECT count(*)
            FROM respuestas r
            JOIN intentos i ON i.id = r.intento_id
            WHERE i.usuario_id = jwt_usuario_id()
              AND r.respondida_en::date = current_date
        ),
        'nota_general', (
            SELECT COALESCE(
                avg(CASE WHEN r.correcta THEN 10 ELSE 0 END),
                0
            )::numeric(5,2)
            FROM respuestas r
            JOIN intentos i ON i.id = r.intento_id
            WHERE i.usuario_id = jwt_usuario_id()
        ),
        'preguntas_falladas', (
            SELECT count(*) FROM marcadores
            WHERE usuario_id = jwt_usuario_id() AND tipo = 'fallo'
        ),
        'preguntas_favoritas', (
            SELECT count(*) FROM marcadores
            WHERE usuario_id = jwt_usuario_id() AND tipo = 'favorita'
        ),
        'total_respondidas', (
            SELECT count(*) FROM respuestas r
            JOIN intentos i ON i.id = r.intento_id
            WHERE i.usuario_id = jwt_usuario_id()
        )
    );
$$;

CREATE OR REPLACE FUNCTION mi_progreso_detallado() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    WITH base AS (
        SELECT mi_progreso() AS p
    ),
    intentos_q AS (
        SELECT i.test_id, i.id AS attempt_id, i.iniciado_en,
               count(*) FILTER (WHERE r.correcta)     AS correct,
               count(*) FILTER (WHERE NOT r.correcta) AS wrong
        FROM intentos i
        LEFT JOIN respuestas r ON r.intento_id = i.id
        WHERE i.usuario_id = jwt_usuario_id()
          AND i.tipo = 'quiz'
          AND i.finalizado_en IS NOT NULL
        GROUP BY i.id
    ),
    por_test AS (
        SELECT iq.test_id AS quiz_id,
               t.titulo   AS titulo,
               jsonb_agg(jsonb_build_object(
                   'correct', iq.correct,
                   'wrong',   iq.wrong,
                   'nota',    CASE WHEN (iq.correct+iq.wrong) = 0 THEN 0
                                    ELSE GREATEST(
                                        ((iq.correct - (1.0/3)*iq.wrong) / (iq.correct+iq.wrong)) * 10,
                                        0
                                    )
                              END
               ) ORDER BY iq.iniciado_en) AS intentos
        FROM intentos_q iq
        JOIN tests t ON t.id = iq.test_id
        GROUP BY iq.test_id, t.titulo
    )
    SELECT (SELECT p FROM base) || jsonb_build_object(
        'por_test', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'quiz_id', quiz_id,
            'titulo',  titulo,
            'intentos', intentos
        )) FROM por_test), '[]'::jsonb)
    );
$$;


-- =============================================================================
--                        LISTADO Y OBTENCIÓN DE TESTS
-- =============================================================================

CREATE OR REPLACE FUNCTION listar_tests(
    p_solo_favoritos  boolean DEFAULT false,
    p_page            int     DEFAULT 1,
    p_size            int     DEFAULT 10,
    p_etiqueta        text    DEFAULT NULL,
    p_solo_pendientes boolean DEFAULT false,
    p_orden           text    DEFAULT 'reciente'
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_offset int := GREATEST(p_page - 1, 0) * p_size;
    v_total  int;
    v_tests  jsonb;
BEGIN
    WITH base AS (
        SELECT
            t.id, t.titulo, t.descripcion, t.tipo, t.publico,
            t.etiquetas, t.creado_en,
            (SELECT count(*) FROM test_preguntas tp WHERE tp.test_id = t.id) AS num_preguntas,
            (SELECT count(*) FROM intentos i
              WHERE i.test_id = t.id AND i.usuario_id = jwt_usuario_id()) AS num_intentos,
            EXISTS (
                SELECT 1 FROM intentos i
                 WHERE i.test_id = t.id
                   AND i.usuario_id = jwt_usuario_id()
                   AND i.finalizado_en IS NULL
            ) AS tiene_pendiente,
            EXISTS (
                SELECT 1 FROM marcadores m
                 WHERE m.usuario_id = jwt_usuario_id()
                   AND m.tipo = 'test_favorito'
                   AND m.test_id = t.id
            ) AS favorito
        FROM tests t
        WHERE (t.publico OR t.autor_id = jwt_usuario_id() OR es_admin())
          AND (p_etiqueta IS NULL OR p_etiqueta = ANY(t.etiquetas))
    ),
    filtrada AS (
        SELECT * FROM base
        WHERE (NOT p_solo_favoritos  OR favorito)
          AND (NOT p_solo_pendientes OR tiene_pendiente)
    )
    SELECT count(*) INTO v_total FROM filtrada;

    WITH base AS (
        SELECT
            t.id, t.titulo, t.descripcion, t.tipo, t.publico,
            t.etiquetas, t.creado_en,
            (SELECT count(*) FROM test_preguntas tp WHERE tp.test_id = t.id) AS num_preguntas,
            (SELECT count(*) FROM intentos i
              WHERE i.test_id = t.id AND i.usuario_id = jwt_usuario_id()) AS num_intentos,
            EXISTS (
                SELECT 1 FROM intentos i
                 WHERE i.test_id = t.id
                   AND i.usuario_id = jwt_usuario_id()
                   AND i.finalizado_en IS NULL
            ) AS tiene_pendiente,
            EXISTS (
                SELECT 1 FROM marcadores m
                 WHERE m.usuario_id = jwt_usuario_id()
                   AND m.tipo = 'test_favorito'
                   AND m.test_id = t.id
            ) AS favorito
        FROM tests t
        WHERE (t.publico OR t.autor_id = jwt_usuario_id() OR es_admin())
          AND (p_etiqueta IS NULL OR p_etiqueta = ANY(t.etiquetas))
    )
    SELECT COALESCE(jsonb_agg(row_to_json(x)), '[]'::jsonb) INTO v_tests
    FROM (
        SELECT
            b.id,
            b.titulo       AS title,
            b.descripcion  AS description,
            b.tipo,
            b.publico,
            b.etiquetas,
            b.creado_en    AS created_at,
            b.num_preguntas,
            b.num_intentos,
            b.tiene_pendiente,
            b.favorito
        FROM base b
        WHERE (NOT p_solo_favoritos  OR b.favorito)
          AND (NOT p_solo_pendientes OR b.tiene_pendiente)
        ORDER BY
            (CASE WHEN p_orden = 'intentos_desc' THEN b.num_intentos ELSE NULL END) DESC NULLS LAST,
            (CASE WHEN p_orden = 'intentos_asc'  THEN b.num_intentos ELSE NULL END) ASC  NULLS LAST,
            (CASE WHEN p_orden = 'antiguo'       THEN b.creado_en    ELSE NULL END) ASC  NULLS LAST,
            b.creado_en DESC
        LIMIT p_size OFFSET v_offset
    ) x;

    RETURN jsonb_build_object(
        'tests',       v_tests,
        'page',        p_page,
        'page_size',   p_size,
        'total',       v_total,
        'total_pages', GREATEST(1, (v_total + p_size - 1) / p_size)
    );
END $$;


-- Devuelve el test y sus preguntas en el formato que espera el frontend.
-- Convención: opciones[0].correcta = true si no viene explícito (heredado
-- de la migración desde SQLite).
CREATE OR REPLACE FUNCTION obtener_preguntas_test(p_test_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'quiz', jsonb_build_object('id', t.id, 'title', t.titulo),
        'questions', COALESCE(jsonb_agg(
            jsonb_build_object(
                'id',          p.id,
                'text',        p.enunciado,
                'options',     (
                    SELECT jsonb_agg(jsonb_build_object(
                        'text', o.opt->>'texto',
                        'isCorrect', COALESCE((o.opt->>'correcta')::boolean,
                                              o.idx = 1)
                    ) ORDER BY o.idx)
                    FROM jsonb_array_elements(p.opciones) WITH ORDINALITY o(opt, idx)
                ),
                'explicacion', p.explicacion,
                'etiquetas',   p.etiquetas
            ) ORDER BY tp.posicion
        ), '[]'::jsonb)
    )
    FROM tests t
    LEFT JOIN test_preguntas tp ON tp.test_id = t.id
    LEFT JOIN preguntas p ON p.id = tp.pregunta_id
    WHERE t.id = p_test_id
    GROUP BY t.id, t.titulo;
$$;


-- =============================================================================
--                     INTENTOS, RESPUESTAS Y MOTOR DE CAJAS
-- =============================================================================

CREATE OR REPLACE FUNCTION iniciar_intento(
    p_test_id      uuid    DEFAULT NULL,
    p_tipo         text    DEFAULT 'quiz',
    p_nombre       text    DEFAULT NULL,
    p_question_ids uuid[]  DEFAULT '{}'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
    INSERT INTO intentos(test_id, tipo, nombre, question_ids)
    VALUES (p_test_id, p_tipo, p_nombre, p_question_ids)
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('attempt_id', v_id);
END $$;

CREATE OR REPLACE FUNCTION finalizar_intento(p_intento_id uuid) RETURNS void
LANGUAGE sql AS $$
    UPDATE intentos SET finalizado_en = now() WHERE id = p_intento_id;
$$;

CREATE OR REPLACE FUNCTION descartar_intento(p_intento_id uuid) RETURNS void
LANGUAGE sql AS $$
    DELETE FROM intentos WHERE id = p_intento_id;
$$;


-- Helpers del motor de cajas (Leitner). La curva por ritmo se guarda en
-- config('ritmos_repaso'); intervalo_repaso(caja, ritmo) devuelve un interval.

CREATE OR REPLACE FUNCTION ritmo_repaso_usuario(p_usuario_id uuid) RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT ritmo_repaso FROM preferencias_usuario WHERE usuario_id = p_usuario_id),
        'normal'
    );
$$;

CREATE OR REPLACE FUNCTION intervalo_repaso(p_caja int, p_ritmo text) RETURNS interval
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_horas numeric;
    v_arr   jsonb;
    v_idx   int;
BEGIN
    v_arr := (SELECT valor->p_ritmo FROM config WHERE clave = 'ritmos_repaso');
    IF v_arr IS NULL THEN
        v_arr := (SELECT valor->'normal' FROM config WHERE clave = 'ritmos_repaso');
    END IF;
    v_idx := LEAST(GREATEST(p_caja, 1), jsonb_array_length(v_arr));
    v_horas := (v_arr->>(v_idx - 1))::numeric;
    RETURN make_interval(hours => v_horas::int);
END $$;


-- registrar_respuesta hace tres cosas de una:
--   1) guarda la respuesta cruda en 'respuestas' (histórico intacto);
--   2) mantiene el marcador 'fallo' compatible con el "Test de fallos"
--      (borra el marcador si aciertas la pregunta previamente fallada);
--   3) mueve la caja de repaso Leitner correspondiente.
--
-- Semántica de p_adelantada = true: el acierto NO cambia caja ni ultima_en
-- (evita "farmear" cajas adelantándose). Los fallos siempre penalizan.
--
-- La fecha del próximo repaso NO se materializa: se deriva de
-- (caja, ultima_en, ritmo_actual). Por eso, en el caso de fallo, anclamos
-- ultima_en en el pasado exactamente el intervalo de la caja final para
-- que la fecha derivada caiga en now() (vencida al instante).
CREATE OR REPLACE FUNCTION registrar_respuesta(
    p_intento_id  uuid,
    p_pregunta_id uuid,
    p_texto       text,
    p_correcta    boolean,
    p_adelantada  boolean DEFAULT false
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_uid    uuid := jwt_usuario_id();
    v_ritmo  text;
    v_caja   int;
    v_intv   interval;
BEGIN
    INSERT INTO respuestas(intento_id, pregunta_id, opcion_elegida, correcta)
    VALUES (p_intento_id, p_pregunta_id, p_texto, p_correcta);

    IF NOT p_correcta THEN
        INSERT INTO marcadores(usuario_id, tipo, pregunta_id, contador, actualizado_en)
        VALUES (v_uid, 'fallo', p_pregunta_id, 1, now())
        ON CONFLICT (usuario_id, tipo, COALESCE(pregunta_id, test_id))
        DO UPDATE SET contador = marcadores.contador + 1,
                       actualizado_en = now();
    ELSE
        DELETE FROM marcadores
         WHERE usuario_id = v_uid
           AND tipo = 'fallo'
           AND pregunta_id = p_pregunta_id;
    END IF;

    v_ritmo := ritmo_repaso_usuario(v_uid);

    IF p_correcta AND p_adelantada THEN
        INSERT INTO repasos(usuario_id, pregunta_id, caja, aciertos, fallos, ultima_en)
        VALUES (v_uid, p_pregunta_id, 2, 1, 0, now())
        ON CONFLICT (usuario_id, pregunta_id) DO UPDATE
            SET aciertos = repasos.aciertos + 1;

    ELSIF p_correcta THEN
        SELECT LEAST(COALESCE(caja, 1) + 1, 7)
          INTO v_caja
          FROM repasos
         WHERE usuario_id = v_uid AND pregunta_id = p_pregunta_id;
        v_caja := COALESCE(v_caja, 2);

        INSERT INTO repasos(usuario_id, pregunta_id, caja, aciertos, fallos, ultima_en)
        VALUES (v_uid, p_pregunta_id, v_caja, 1, 0, now())
        ON CONFLICT (usuario_id, pregunta_id) DO UPDATE
            SET caja      = v_caja,
                aciertos  = repasos.aciertos + 1,
                ultima_en = now();

    ELSE
        SELECT GREATEST(COALESCE(caja, 1) - 2, 1)
          INTO v_caja
          FROM repasos
         WHERE usuario_id = v_uid AND pregunta_id = p_pregunta_id;
        v_caja := COALESCE(v_caja, 1);
        v_intv := intervalo_repaso(v_caja, v_ritmo);

        INSERT INTO repasos(usuario_id, pregunta_id, caja, aciertos, fallos, ultima_en)
        VALUES (v_uid, p_pregunta_id, v_caja, 0, 1, now() - v_intv)
        ON CONFLICT (usuario_id, pregunta_id) DO UPDATE
            SET caja      = v_caja,
                fallos    = repasos.fallos + 1,
                ultima_en = now() - v_intv;
    END IF;
END $$;


-- Reanudar un intento pendiente:
-- 1. Invalida respuestas a preguntas editadas (preguntas.actualizado_en >
--    respuestas.respondida_en). Si eran fallidas, limpia también el marcador
--    de fallo (la pregunta cambió, no cuenta como fallo histórico).
-- 2. Ignora preguntas del array que ya no existen.
-- 3. Devuelve pendientes en el orden original + acumulados válidos.
CREATE OR REPLACE FUNCTION reanudar_intento(p_intento_id uuid) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_int  intentos;
    v_pend jsonb;
    v_corr int;
    v_wrong int;
    v_tot_efectivo int;
BEGIN
    SELECT * INTO v_int FROM intentos WHERE id = p_intento_id;
    IF v_int.id IS NULL OR v_int.usuario_id <> jwt_usuario_id() THEN
        RAISE EXCEPTION 'intento_invalido';
    END IF;

    DELETE FROM marcadores m
    USING respuestas r, preguntas p
    WHERE r.intento_id = p_intento_id
      AND p.id = r.pregunta_id
      AND p.actualizado_en > r.respondida_en
      AND NOT r.correcta
      AND m.usuario_id = v_int.usuario_id
      AND m.tipo = 'fallo'
      AND m.pregunta_id = r.pregunta_id;

    DELETE FROM respuestas r
    USING preguntas p
    WHERE r.intento_id = p_intento_id
      AND p.id = r.pregunta_id
      AND p.actualizado_en > r.respondida_en;

    SELECT
        count(*) FILTER (WHERE r.correcta),
        count(*) FILTER (WHERE NOT r.correcta)
      INTO v_corr, v_wrong
      FROM respuestas r
     WHERE r.intento_id = p_intento_id;

    WITH pendientes AS (
        SELECT u.qid, u.ord
        FROM unnest(v_int.question_ids) WITH ORDINALITY AS u(qid, ord)
        JOIN preguntas p ON p.id = u.qid
        WHERE u.qid NOT IN (
            SELECT pregunta_id FROM respuestas WHERE intento_id = p_intento_id
        )
        ORDER BY u.ord
    )
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id', p.id,
            'text', p.enunciado,
            'options', (
                SELECT jsonb_agg(jsonb_build_object(
                    'text', o.opt->>'texto',
                    'isCorrect', COALESCE((o.opt->>'correcta')::boolean, o.idx = 1)
                ) ORDER BY o.idx)
                FROM jsonb_array_elements(p.opciones) WITH ORDINALITY o(opt, idx)
            ),
            'explicacion', p.explicacion,
            'etiquetas', p.etiquetas
        ) ORDER BY pe.ord
    ), '[]'::jsonb)
    INTO v_pend
    FROM pendientes pe
    JOIN preguntas p ON p.id = pe.qid;

    v_tot_efectivo := COALESCE(jsonb_array_length(v_pend), 0) + v_corr + v_wrong;

    RETURN jsonb_build_object(
        'attempt_id',     v_int.id,
        'attempt_type',   v_int.tipo,
        'quiz_id',        v_int.test_id,
        'nombre',         v_int.nombre,
        'questions',      v_pend,
        'correct',        v_corr,
        'wrong',          v_wrong,
        'respondidas',    v_corr + v_wrong,
        'total_efectivo', v_tot_efectivo
    );
END $$;


CREATE OR REPLACE FUNCTION intento_pendiente(
    p_tipo    text,
    p_test_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_int   intentos;
    v_resp  int;
    v_pend  int;
    v_inval int;
    v_tot_efectivo int;
BEGIN
    SELECT * INTO v_int FROM intentos i
     WHERE i.usuario_id = jwt_usuario_id()
       AND i.finalizado_en IS NULL
       AND i.tipo = p_tipo
       AND (p_test_id IS NULL OR i.test_id = p_test_id)
     ORDER BY i.iniciado_en DESC
     LIMIT 1;

    IF v_int.id IS NULL THEN
        RETURN jsonb_build_object('attempt', NULL);
    END IF;

    SELECT count(*) INTO v_resp
      FROM respuestas r JOIN preguntas p ON p.id = r.pregunta_id
     WHERE r.intento_id = v_int.id AND p.actualizado_en <= r.respondida_en;

    SELECT count(*) INTO v_inval
      FROM respuestas r JOIN preguntas p ON p.id = r.pregunta_id
     WHERE r.intento_id = v_int.id AND p.actualizado_en > r.respondida_en;

    SELECT count(*) INTO v_pend
      FROM unnest(v_int.question_ids) AS u(qid)
      JOIN preguntas p ON p.id = u.qid
     WHERE u.qid NOT IN (
        SELECT r.pregunta_id FROM respuestas r
        JOIN preguntas p2 ON p2.id = r.pregunta_id
        WHERE r.intento_id = v_int.id
          AND p2.actualizado_en <= r.respondida_en
     );

    v_tot_efectivo := v_resp + v_pend;

    RETURN jsonb_build_object(
        'attempt', jsonb_build_object(
            'id',              v_int.id,
            'nombre',          v_int.nombre,
            'quiz_id',         v_int.test_id,
            'attempt_type',    v_int.tipo,
            'iniciado_en',     v_int.iniciado_en,
            'respondidas',     v_resp,
            'pendientes',      v_pend,
            'invalidas',       v_inval,
            'total_efectivo',  v_tot_efectivo
        )
    );
END $$;


-- =============================================================================
--                              MARCADORES
-- =============================================================================

CREATE OR REPLACE FUNCTION toggle_favorita_pregunta(p_pregunta_id uuid) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_existe boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM marcadores
        WHERE usuario_id = jwt_usuario_id()
          AND tipo = 'favorita'
          AND pregunta_id = p_pregunta_id
    ) INTO v_existe;

    IF v_existe THEN
        DELETE FROM marcadores
        WHERE usuario_id = jwt_usuario_id()
          AND tipo = 'favorita'
          AND pregunta_id = p_pregunta_id;
        RETURN jsonb_build_object('favorito', false);
    ELSE
        INSERT INTO marcadores(usuario_id, tipo, pregunta_id)
        VALUES (jwt_usuario_id(), 'favorita', p_pregunta_id);
        RETURN jsonb_build_object('favorito', true);
    END IF;
END $$;

CREATE OR REPLACE FUNCTION toggle_favorita_test(p_test_id uuid) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_existe boolean;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM marcadores
        WHERE usuario_id = jwt_usuario_id()
          AND tipo = 'test_favorito'
          AND test_id = p_test_id
    ) INTO v_existe;

    IF v_existe THEN
        DELETE FROM marcadores
        WHERE usuario_id = jwt_usuario_id()
          AND tipo = 'test_favorito'
          AND test_id = p_test_id;
        RETURN jsonb_build_object('favorito', false);
    ELSE
        INSERT INTO marcadores(usuario_id, tipo, test_id)
        VALUES (jwt_usuario_id(), 'test_favorito', p_test_id);
        RETURN jsonb_build_object('favorito', true);
    END IF;
END $$;

CREATE OR REPLACE FUNCTION mis_favoritas_ids() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'question_ids',
        COALESCE(jsonb_agg(pregunta_id), '[]'::jsonb)
    )
    FROM marcadores
    WHERE usuario_id = jwt_usuario_id() AND tipo = 'favorita';
$$;

CREATE OR REPLACE FUNCTION mis_fallos() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'questions', COALESCE(jsonb_agg(
            jsonb_build_object(
                'id', p.id,
                'text', p.enunciado,
                'options', (
                    SELECT jsonb_agg(jsonb_build_object(
                        'text', o.opt->>'texto',
                        'isCorrect', COALESCE((o.opt->>'correcta')::boolean, o.idx = 1)
                    ) ORDER BY o.idx)
                    FROM jsonb_array_elements(p.opciones) WITH ORDINALITY o(opt, idx)
                ),
                'explicacion', p.explicacion,
                'etiquetas',   p.etiquetas,
                'veces_fallada', m.contador
            ) ORDER BY m.actualizado_en DESC
        ), '[]'::jsonb)
    )
    FROM marcadores m
    JOIN preguntas p ON p.id = m.pregunta_id
    WHERE m.usuario_id = jwt_usuario_id() AND m.tipo = 'fallo';
$$;

CREATE OR REPLACE FUNCTION mis_favoritas() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'questions', COALESCE(jsonb_agg(
            jsonb_build_object(
                'id', p.id,
                'text', p.enunciado,
                'options', (
                    SELECT jsonb_agg(jsonb_build_object(
                        'text', o.opt->>'texto',
                        'isCorrect', COALESCE((o.opt->>'correcta')::boolean, o.idx = 1)
                    ) ORDER BY o.idx)
                    FROM jsonb_array_elements(p.opciones) WITH ORDINALITY o(opt, idx)
                ),
                'explicacion', p.explicacion,
                'etiquetas',   p.etiquetas
            ) ORDER BY m.actualizado_en DESC
        ), '[]'::jsonb)
    )
    FROM marcadores m
    JOIN preguntas p ON p.id = m.pregunta_id
    WHERE m.usuario_id = jwt_usuario_id() AND m.tipo = 'favorita';
$$;

CREATE OR REPLACE FUNCTION mis_favoritas_agrupadas() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'questions', COALESCE(jsonb_agg(
            jsonb_build_object(
                'id', p.id,
                'text', p.enunciado,
                'options', (
                    SELECT jsonb_agg(jsonb_build_object(
                        'text', o.opt->>'texto',
                        'isCorrect', COALESCE((o.opt->>'correcta')::boolean, o.idx = 1)
                    ) ORDER BY o.idx)
                    FROM jsonb_array_elements(p.opciones) WITH ORDINALITY o(opt, idx)
                ),
                'explicacion', p.explicacion,
                'quiz_title',  COALESCE((
                    SELECT t.titulo FROM test_preguntas tp
                    JOIN tests t ON t.id = tp.test_id
                    WHERE tp.pregunta_id = p.id
                    ORDER BY t.creado_en LIMIT 1
                ), '(sin test)')
            ) ORDER BY 1
        ), '[]'::jsonb)
    )
    FROM marcadores m
    JOIN preguntas p ON p.id = m.pregunta_id
    WHERE m.usuario_id = jwt_usuario_id() AND m.tipo = 'favorita';
$$;


-- =============================================================================
--                    IMPORTAR / EXPORTAR / MEGA / SIMULACRO
-- =============================================================================

-- Formato "nuevo": opciones ya vienen como [{texto, correcta}, ...].
CREATE OR REPLACE FUNCTION importar_test(p_titulo text, p_json jsonb) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_test uuid;
    v_preg jsonb;
    v_pid  uuid;
    v_pos  int := 0;
    v_etiq text[];
BEGIN
    IF NOT tiene_permiso('test.crear') THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;

    INSERT INTO tests(titulo, autor_id) VALUES (p_titulo, jwt_usuario_id())
    RETURNING id INTO v_test;

    FOR v_preg IN SELECT * FROM jsonb_array_elements(p_json) LOOP
        v_etiq := COALESCE(
            ARRAY(SELECT jsonb_array_elements_text(v_preg->'etiquetas')),
            ARRAY[]::text[]
        );

        INSERT INTO preguntas(enunciado, opciones, etiquetas, autor_id)
        VALUES (
            v_preg->>'pregunta',
            v_preg->'opciones',
            v_etiq,
            jwt_usuario_id()
        )
        ON CONFLICT (hash_contenido) DO UPDATE
            SET enunciado = EXCLUDED.enunciado
        RETURNING id INTO v_pid;

        v_pos := v_pos + 1;
        INSERT INTO test_preguntas(test_id, pregunta_id, posicion)
        VALUES (v_test, v_pid, v_pos);
    END LOOP;

    RETURN v_test;
END $$;

-- Formato "viejo" (el que exportaba el bot desde SQLite): opciones como array
-- de strings, donde la primera era la correcta.
CREATE OR REPLACE FUNCTION importar_test_normalizado(
    p_titulo      text,
    p_descripcion text,
    p_preguntas   jsonb
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_test uuid;
    v_preg jsonb;
    v_pid  uuid;
    v_pos  int := 0;
    v_opc  jsonb;
    v_etiq text[];
BEGIN
    IF NOT (tiene_permiso('test.crear') OR es_admin()) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;

    INSERT INTO tests(titulo, descripcion) VALUES (p_titulo, p_descripcion)
    RETURNING id INTO v_test;

    FOR v_preg IN SELECT * FROM jsonb_array_elements(p_preguntas) LOOP
        IF jsonb_typeof(v_preg->'opciones'->0) = 'string' THEN
            SELECT jsonb_agg(jsonb_build_object(
                       'texto', t,
                       'correcta', i = 1
                   ) ORDER BY i)
              INTO v_opc
              FROM jsonb_array_elements_text(v_preg->'opciones')
                   WITH ORDINALITY AS x(t, i);
        ELSE
            v_opc := v_preg->'opciones';
        END IF;

        v_etiq := COALESCE(
            ARRAY(SELECT jsonb_array_elements_text(v_preg->'etiquetas')),
            ARRAY[]::text[]
        );

        INSERT INTO preguntas(enunciado, opciones, explicacion, etiquetas)
        VALUES (
            v_preg->>'pregunta',
            v_opc,
            NULLIF(v_preg->>'explicacion',''),
            v_etiq
        )
        ON CONFLICT (hash_contenido) DO UPDATE
            SET enunciado = EXCLUDED.enunciado
        RETURNING id INTO v_pid;

        v_pos := v_pos + 1;
        INSERT INTO test_preguntas(test_id, pregunta_id, posicion)
        VALUES (v_test, v_pid, v_pos);
    END LOOP;

    RETURN v_test;
END $$;

CREATE OR REPLACE FUNCTION descargar_test(p_test_id uuid) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'titulo',      t.titulo,
        'descripcion', t.descripcion,
        'preguntas',   (
            SELECT jsonb_agg(jsonb_build_object(
                'pregunta',    p.enunciado,
                'opciones',    p.opciones,
                'explicacion', p.explicacion,
                'etiquetas',   p.etiquetas
            ) ORDER BY tp.posicion)
            FROM test_preguntas tp
            JOIN preguntas p ON p.id = tp.pregunta_id
            WHERE tp.test_id = t.id
        )
    )
    FROM tests t WHERE t.id = p_test_id;
$$;

CREATE OR REPLACE FUNCTION descargar_todos_los_tests() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(descargar_test(id) ORDER BY creado_en), '[]'::jsonb)
    FROM tests
    WHERE autor_id = jwt_usuario_id() OR publico OR es_admin();
$$;

-- Mega test: agrega TODAS las preguntas (deduplicadas) de un conjunto de tests.
CREATE OR REPLACE FUNCTION preguntas_de_tests(p_test_ids uuid[]) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'questions', COALESCE(jsonb_agg(jsonb_build_object(
            'id',          p.id,
            'text',        p.enunciado,
            'options',     (
                SELECT jsonb_agg(jsonb_build_object(
                    'text', o.opt->>'texto',
                    'isCorrect', COALESCE((o.opt->>'correcta')::boolean, o.idx = 1)
                ) ORDER BY o.idx)
                FROM jsonb_array_elements(p.opciones) WITH ORDINALITY o(opt, idx)
            ),
            'explicacion', p.explicacion,
            'etiquetas',   p.etiquetas,
            'quiz_title',  (
                SELECT t.titulo FROM test_preguntas tp2
                JOIN tests t ON t.id = tp2.test_id
                WHERE tp2.pregunta_id = p.id
                ORDER BY t.creado_en LIMIT 1
            )
        )), '[]'::jsonb)
    )
    FROM (
        SELECT DISTINCT tp.pregunta_id FROM test_preguntas tp
        WHERE tp.test_id = ANY(p_test_ids)
    ) ids
    JOIN preguntas p ON p.id = ids.pregunta_id;
$$;

CREATE OR REPLACE FUNCTION crear_mega_test(p_titulo text, p_test_ids uuid[])
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_test uuid;
    v_pos int := 0;
    v_qid uuid;
BEGIN
    IF NOT (tiene_permiso('test.crear') OR es_admin()) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;

    INSERT INTO tests(titulo, tipo) VALUES (p_titulo, 'mega')
    RETURNING id INTO v_test;

    FOR v_qid IN
        SELECT DISTINCT tp.pregunta_id FROM test_preguntas tp
        WHERE tp.test_id = ANY(p_test_ids)
        ORDER BY tp.pregunta_id
    LOOP
        v_pos := v_pos + 1;
        INSERT INTO test_preguntas(test_id, pregunta_id, posicion)
        VALUES (v_test, v_qid, v_pos);
    END LOOP;

    RETURN v_test;
END $$;

CREATE OR REPLACE FUNCTION listar_simulacros() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'simulacros', COALESCE(jsonb_agg(jsonb_build_object(
            'id',                 t.id,
            'nombre',             t.titulo,
            'quiz_id',            t.id,
            'nota_corte_directa', t.nota_corte,
            'escala_maxima',      t.escala_maxima,
            'preguntas_total',    (SELECT count(*) FROM test_preguntas WHERE test_id = t.id)
        ) ORDER BY t.creado_en DESC), '[]'::jsonb)
    )
    FROM tests t WHERE t.tipo = 'simulacro';
$$;

CREATE OR REPLACE FUNCTION crear_simulacro(
    p_titulo         text,
    p_test_id        uuid,
    p_nota_corte     numeric,
    p_escala_maxima  numeric
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
    IF NOT (tiene_permiso('test.crear') OR es_admin()) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    UPDATE tests
       SET tipo = 'simulacro',
           titulo = COALESCE(NULLIF(p_titulo,''), titulo),
           nota_corte = p_nota_corte,
           escala_maxima = p_escala_maxima
     WHERE id = p_test_id
     RETURNING id INTO v_id;
    IF v_id IS NULL THEN
        RAISE EXCEPTION 'test_no_encontrado';
    END IF;
    RETURN v_id;
END $$;


-- =============================================================================
--                     BORRADO DE TESTS Y SUS PREGUNTAS
-- =============================================================================
-- Borra el test SIEMPRE. Si p_borrar_preguntas=true, también las preguntas
-- exclusivas de este test (las compartidas con otros se conservan).
CREATE OR REPLACE FUNCTION borrar_test_y_preguntas(
    p_test_id           uuid,
    p_borrar_preguntas  boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_es_admin              boolean := es_admin();
    v_autor                 uuid;
    v_preguntas_borradas    int := 0;
    v_preguntas_compartidas int := 0;
BEGIN
    SELECT autor_id INTO v_autor FROM tests WHERE id = p_test_id;
    IF v_autor IS NULL THEN RAISE EXCEPTION 'test_no_encontrado'; END IF;

    IF NOT (v_es_admin OR v_autor = jwt_usuario_id() OR tiene_permiso('test.borrar')) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;

    IF p_borrar_preguntas THEN
        SELECT count(*) INTO v_preguntas_compartidas
          FROM test_preguntas tp
         WHERE tp.test_id = p_test_id
           AND EXISTS (
               SELECT 1 FROM test_preguntas tp2
                WHERE tp2.pregunta_id = tp.pregunta_id
                  AND tp2.test_id <> p_test_id
           );

        WITH exclusivas AS (
            SELECT tp.pregunta_id
              FROM test_preguntas tp
             WHERE tp.test_id = p_test_id
               AND NOT EXISTS (
                   SELECT 1 FROM test_preguntas tp2
                    WHERE tp2.pregunta_id = tp.pregunta_id
                      AND tp2.test_id <> p_test_id
               )
        )
        DELETE FROM preguntas p
         USING exclusivas e
         WHERE p.id = e.pregunta_id;
        GET DIAGNOSTICS v_preguntas_borradas = ROW_COUNT;
    END IF;

    DELETE FROM tests WHERE id = p_test_id;

    RETURN jsonb_build_object(
        'test_id',                p_test_id,
        'preguntas_borradas',     v_preguntas_borradas,
        'preguntas_compartidas',  v_preguntas_compartidas
    );
END $$;


-- =============================================================================
--                           ETIQUETAS (CATÁLOGO)
-- =============================================================================

-- Devuelve la etiqueta consultada + toda su descendencia (recursivo).
CREATE OR REPLACE FUNCTION etiqueta_y_descendientes(p_nombre text) RETURNS text[]
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

CREATE OR REPLACE FUNCTION listar_etiquetas() RETURNS jsonb
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
    FROM catalogo_etiquetas c;
$$;

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

CREATE OR REPLACE FUNCTION borrar_etiqueta(p_nombre text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT (tiene_permiso('etiqueta.gestionar') OR es_admin()) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    DELETE FROM catalogo_etiquetas WHERE nombre = p_nombre;
    UPDATE preguntas
       SET etiquetas = array_remove(etiquetas, p_nombre),
           actualizado_en = now()
     WHERE p_nombre = ANY(etiquetas);
END $$;


-- =============================================================================
--                     AUTO-TAGGER (HÍBRIDO + k-NN)
-- =============================================================================
-- Sobre cada pregunta suma candidatas de:
--   (a) similitud coseno de embedding contra el catálogo (precisión)
--   (b) palabras_clave del catálogo dentro del enunciado (recall)
--   (c) nombre de la etiqueta dentro del enunciado
--   (d) nombre/palabras_clave del TÍTULO del test asociado (transitivo)
--   (e) etiquetas de las k preguntas vecinas más parecidas por embedding
--       (bucle de mejora: lo que etiquetas a mano educa al clasificador).
-- Nunca elimina etiquetas: las manuales sobreviven.

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

-- Clasificar un test: propaga etiquetas del título+descripción a todas sus
-- preguntas.
CREATE OR REPLACE FUNCTION clasificar_test(p_test_id uuid) RETURNS text[]
LANGUAGE plpgsql AS $$
DECLARE
    v_titulo      text;
    v_descr       text;
    v_etiq_nuevas text[];
BEGIN
    SELECT titulo, descripcion INTO v_titulo, v_descr
      FROM tests WHERE id = p_test_id;
    IF v_titulo IS NULL THEN RETURN '{}'::text[]; END IF;

    SELECT array_agg(DISTINCT c.nombre) INTO v_etiq_nuevas
      FROM catalogo_etiquetas c
     WHERE v_titulo ILIKE '%' || c.nombre || '%'
        OR (v_descr IS NOT NULL AND v_descr ILIKE '%' || c.nombre || '%')
        OR EXISTS (
            SELECT 1 FROM unnest(c.palabras_clave) kw
            WHERE v_titulo ILIKE '%' || kw || '%'
               OR (v_descr IS NOT NULL AND v_descr ILIKE '%' || kw || '%')
        );

    IF v_etiq_nuevas IS NULL OR cardinality(v_etiq_nuevas) = 0 THEN
        RETURN '{}'::text[];
    END IF;

    UPDATE tests SET etiquetas = ARRAY(
        SELECT DISTINCT e FROM unnest(etiquetas || v_etiq_nuevas) AS e
    ) WHERE id = p_test_id;

    UPDATE preguntas
       SET etiquetas = ARRAY(
               SELECT DISTINCT e FROM unnest(preguntas.etiquetas || v_etiq_nuevas) AS e
           ),
           actualizado_en = now()
     WHERE id IN (SELECT pregunta_id FROM test_preguntas WHERE test_id = p_test_id);

    RETURN v_etiq_nuevas;
END $$;

CREATE OR REPLACE FUNCTION reclasificar_todas() RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_n int := 0; v_id uuid;
BEGIN
    IF NOT (tiene_permiso('etiqueta.gestionar') OR es_admin()) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    FOR v_id IN SELECT id FROM preguntas WHERE embedding IS NOT NULL LOOP
        PERFORM reclasificar_pregunta(v_id);
        v_n := v_n + 1;
    END LOOP;
    RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION reclasificar_todo() RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_tests_n     int := 0;
    v_preguntas_n int := 0;
    v_id          uuid;
BEGIN
    IF NOT (tiene_permiso('etiqueta.gestionar') OR es_admin()) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;

    FOR v_id IN SELECT id FROM tests LOOP
        PERFORM clasificar_test(v_id);
        v_tests_n := v_tests_n + 1;
    END LOOP;

    FOR v_id IN SELECT id FROM preguntas LOOP
        PERFORM reclasificar_pregunta(v_id);
        v_preguntas_n := v_preguntas_n + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'tests_procesados',     v_tests_n,
        'preguntas_procesadas', v_preguntas_n
    );
END $$;


-- =============================================================================
--                    BÚSQUEDA Y TESTS TEMÁTICOS
-- =============================================================================

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
       AND (v_etiq_expandidas IS NULL OR p.etiquetas && v_etiq_expandidas)
     ORDER BY similarity(p.enunciado, p_q) DESC NULLS LAST
     LIMIT p_lim;
END $$;

CREATE OR REPLACE FUNCTION buscar_preguntas_multi(
    p_q         text,
    p_lim       int    DEFAULT 40,
    p_etiquetas text[] DEFAULT NULL
) RETURNS TABLE (id uuid, enunciado text, score real, etiquetas text[])
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_expandidas text[];
BEGIN
    IF p_etiquetas IS NOT NULL AND cardinality(p_etiquetas) > 0 THEN
        SELECT COALESCE(array_agg(DISTINCT e), '{}'::text[]) INTO v_expandidas
          FROM unnest(p_etiquetas) AS t
               CROSS JOIN LATERAL unnest(etiqueta_y_descendientes(t)) AS e;
    END IF;

    RETURN QUERY
    SELECT p.id, p.enunciado,
           similarity(p.enunciado, p_q) AS score,
           p.etiquetas
      FROM preguntas p
     WHERE (p_q IS NULL OR p_q = '' OR p.enunciado %> p_q)
       AND (v_expandidas IS NULL OR p.etiquetas && v_expandidas)
     ORDER BY similarity(p.enunciado, p_q) DESC NULLS LAST
     LIMIT p_lim;
END $$;

CREATE OR REPLACE FUNCTION generar_test_tematico(p_etiqueta text, p_n int DEFAULT 20)
RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_test uuid;
BEGIN
    IF jwt_usuario_id() IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;

    INSERT INTO tests(titulo, tipo, autor_id)
    VALUES ('Etiqueta: ' || p_etiqueta, 'tematico', jwt_usuario_id())
    RETURNING id INTO v_test;

    INSERT INTO test_preguntas(test_id, pregunta_id, posicion)
    SELECT v_test, id, row_number() OVER (ORDER BY random())
    FROM preguntas
    WHERE p_etiqueta = ANY(etiquetas)
    LIMIT p_n;

    RETURN v_test;
END $$;

-- Test temático multi-etiqueta con expansión jerárquica y priorización de
-- preguntas menos vistas por el usuario.
CREATE OR REPLACE FUNCTION crear_test_tematico_multi(
    p_etiquetas text[],
    p_n         int  DEFAULT 20,
    p_titulo    text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_test       uuid;
    v_titulo     text;
    v_expandidas text[];
    v_n_real     int;
BEGIN
    IF jwt_usuario_id() IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    IF p_etiquetas IS NULL OR cardinality(p_etiquetas) = 0 THEN
        RAISE EXCEPTION 'etiquetas_vacias';
    END IF;
    IF p_n IS NULL OR p_n < 1 THEN p_n := 20; END IF;

    SELECT COALESCE(array_agg(DISTINCT e), '{}'::text[]) INTO v_expandidas
      FROM unnest(p_etiquetas) AS t
           CROSS JOIN LATERAL unnest(etiqueta_y_descendientes(t)) AS e;

    v_titulo := COALESCE(
        NULLIF(btrim(p_titulo), ''),
        'Test temático: ' || array_to_string(p_etiquetas, ', ')
    );

    INSERT INTO tests(titulo, tipo, autor_id)
    VALUES (v_titulo, 'tematico', jwt_usuario_id())
    RETURNING id INTO v_test;

    WITH candidatas AS (
        SELECT p.id,
               (SELECT count(*) FROM respuestas r
                  JOIN intentos i ON i.id = r.intento_id
                 WHERE r.pregunta_id = p.id
                   AND i.usuario_id = jwt_usuario_id()) AS veces_vista
          FROM preguntas p
         WHERE p.etiquetas && v_expandidas
    ),
    elegidas AS (
        SELECT id, row_number() OVER (ORDER BY veces_vista ASC, random()) AS pos
          FROM candidatas
         LIMIT p_n
    )
    INSERT INTO test_preguntas(test_id, pregunta_id, posicion)
    SELECT v_test, id, pos FROM elegidas;

    GET DIAGNOSTICS v_n_real = ROW_COUNT;
    IF v_n_real = 0 THEN
        DELETE FROM tests WHERE id = v_test;
        RAISE EXCEPTION 'sin_preguntas_para_etiquetas';
    END IF;

    RETURN v_test;
END $$;


-- =============================================================================
--                       ESTADO Y COLA DE EMBEDDINGS
-- =============================================================================

CREATE OR REPLACE FUNCTION estado_embeddings() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'preguntas_total',        (SELECT count(*) FROM preguntas),
        'preguntas_vectorizadas', (SELECT count(*) FROM preguntas WHERE embedding IS NOT NULL),
        'etiquetas_total',        (SELECT count(*) FROM catalogo_etiquetas),
        'etiquetas_vectorizadas', (SELECT count(*) FROM catalogo_etiquetas WHERE embedding IS NOT NULL),
        'cola_pendiente',         (SELECT count(*) FROM cola_embeddings WHERE procesado_en IS NULL)
    );
$$;

CREATE OR REPLACE FUNCTION encolar_revectorizado_total() RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
    IF NOT (tiene_permiso('etiqueta.gestionar') OR es_admin()) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    INSERT INTO cola_embeddings(entidad, entidad_id)
    SELECT 'pregunta', id::text FROM preguntas;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    PERFORM pg_notify('embeddings', 'bulk');
    RETURN v_n;
END $$;


-- =============================================================================
--                            REPASOS (RPCs)
-- =============================================================================

CREATE OR REPLACE FUNCTION mi_ritmo_repaso() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'ritmo',  ritmo_repaso_usuario(jwt_usuario_id()),
        'curvas', (SELECT valor FROM config WHERE clave = 'ritmos_repaso')
    );
$$;

CREATE OR REPLACE FUNCTION set_ritmo_repaso(p_ritmo text) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
    IF p_ritmo NOT IN ('intensivo','normal','relajado') THEN
        RAISE EXCEPTION 'ritmo_invalido';
    END IF;
    INSERT INTO preferencias_usuario(usuario_id, ritmo_repaso, actualizado_en)
    VALUES (jwt_usuario_id(), p_ritmo, now())
    ON CONFLICT (usuario_id) DO UPDATE
        SET ritmo_repaso   = EXCLUDED.ritmo_repaso,
            actualizado_en = now();
    RETURN jsonb_build_object('ritmo', p_ritmo);
END $$;

-- Vacía por completo el estado del motor de cajas del usuario actual.
-- No toca respuestas ni intentos (histórico intacto); solo borra
-- 'repasos'. En la siguiente respuesta correcta, la pregunta volverá a
-- entrar en caja 2 (comportamiento por defecto de registrar_respuesta).
-- Opcionalmente restringe el reset a un test concreto.
CREATE OR REPLACE FUNCTION resetear_mis_repasos(p_test_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_n   int;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;

    IF p_test_id IS NULL THEN
        DELETE FROM repasos WHERE usuario_id = v_uid;
    ELSE
        DELETE FROM repasos
         WHERE usuario_id = v_uid
           AND pregunta_id IN (
               SELECT pregunta_id FROM test_preguntas WHERE test_id = p_test_id
           );
    END IF;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN jsonb_build_object('borradas', v_n);
END $$;

CREATE OR REPLACE FUNCTION resumen_repaso_test(p_test_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_uid   uuid := jwt_usuario_id();
    v_ritmo text := ritmo_repaso_usuario(v_uid);
BEGIN
    RETURN (
        WITH q AS (
            SELECT r.caja,
                   r.ultima_en + intervalo_repaso(r.caja, v_ritmo) AS proximo_repaso
            FROM repasos r
            JOIN test_preguntas tp ON tp.pregunta_id = r.pregunta_id
            WHERE tp.test_id = p_test_id AND r.usuario_id = v_uid
        )
        SELECT jsonb_build_object(
            'total_repasos',  (SELECT count(*) FROM q),
            'vencidas',       (SELECT count(*) FROM q WHERE proximo_repaso <= now()),
            'dominadas',      (SELECT count(*) FROM q WHERE caja = 7),
            'siguiente',      (SELECT min(proximo_repaso) FROM q WHERE proximo_repaso > now()),
            'test_realizado', EXISTS (
                SELECT 1 FROM intentos WHERE usuario_id = v_uid AND test_id = p_test_id
            )
        )
    );
END $$;

CREATE OR REPLACE FUNCTION resumen_repaso_global() RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_uid   uuid := jwt_usuario_id();
    v_ritmo text := ritmo_repaso_usuario(v_uid);
BEGIN
    RETURN (
        WITH q AS (
            SELECT r.caja,
                   r.ultima_en + intervalo_repaso(r.caja, v_ritmo) AS proximo_repaso
            FROM repasos r
            WHERE r.usuario_id = v_uid
              AND EXISTS (
                SELECT 1 FROM test_preguntas tp
                JOIN intentos i ON i.test_id = tp.test_id
                WHERE tp.pregunta_id = r.pregunta_id AND i.usuario_id = r.usuario_id
              )
        )
        SELECT jsonb_build_object(
            'total_repasos', (SELECT count(*) FROM q),
            'vencidas',      (SELECT count(*) FROM q WHERE proximo_repaso <= now()),
            'dominadas',     (SELECT count(*) FROM q WHERE caja = 7),
            'siguiente',     (SELECT min(proximo_repaso) FROM q WHERE proximo_repaso > now())
        )
    );
END $$;

CREATE OR REPLACE FUNCTION preguntas_repaso_test(
    p_test_id   uuid,
    p_n         int     DEFAULT 20,
    p_adelantar boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_uid    uuid := jwt_usuario_id();
    v_ritmo  text := ritmo_repaso_usuario(v_uid);
    v_titulo text;
    v_qs     jsonb;
BEGIN
    SELECT titulo INTO v_titulo FROM tests WHERE id = p_test_id;

    WITH pool AS (
        SELECT r.pregunta_id, r.caja,
               r.ultima_en + intervalo_repaso(r.caja, v_ritmo) AS proximo_repaso
        FROM repasos r
        JOIN test_preguntas tp ON tp.pregunta_id = r.pregunta_id
        WHERE tp.test_id = p_test_id AND r.usuario_id = v_uid
    ), filtro AS (
        SELECT * FROM pool
        WHERE p_adelantar OR proximo_repaso <= now()
        ORDER BY proximo_repaso ASC
        LIMIT GREATEST(p_n, 0)
    )
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id',   p.id,
            'text', p.enunciado,
            'options', (
                SELECT jsonb_agg(jsonb_build_object(
                    'text',      o.opt->>'texto',
                    'isCorrect', COALESCE((o.opt->>'correcta')::boolean, o.idx = 1)
                ) ORDER BY o.idx)
                FROM jsonb_array_elements(p.opciones) WITH ORDINALITY o(opt, idx)
            ),
            'explicacion', p.explicacion,
            'etiquetas',   p.etiquetas,
            'caja',        filtro.caja
        ) ORDER BY filtro.proximo_repaso ASC
    ), '[]'::jsonb)
    INTO v_qs
    FROM filtro JOIN preguntas p ON p.id = filtro.pregunta_id;

    RETURN jsonb_build_object(
        'quiz',       jsonb_build_object('id', p_test_id, 'title', v_titulo),
        'questions',  v_qs,
        'adelantada', p_adelantar
    );
END $$;

CREATE OR REPLACE FUNCTION preguntas_repaso_global(
    p_n         int     DEFAULT 20,
    p_adelantar boolean DEFAULT false
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_uid   uuid := jwt_usuario_id();
    v_ritmo text := ritmo_repaso_usuario(v_uid);
    v_qs    jsonb;
BEGIN
    WITH pool AS (
        SELECT r.pregunta_id, r.caja,
               r.ultima_en + intervalo_repaso(r.caja, v_ritmo) AS proximo_repaso
        FROM repasos r
        WHERE r.usuario_id = v_uid
          AND EXISTS (
            SELECT 1 FROM test_preguntas tp
            JOIN intentos i ON i.test_id = tp.test_id
            WHERE tp.pregunta_id = r.pregunta_id AND i.usuario_id = r.usuario_id
          )
    ), filtro AS (
        SELECT * FROM pool
        WHERE p_adelantar OR proximo_repaso <= now()
        ORDER BY proximo_repaso ASC
        LIMIT GREATEST(p_n, 0)
    )
    SELECT COALESCE(jsonb_agg(
        jsonb_build_object(
            'id',   p.id,
            'text', p.enunciado,
            'options', (
                SELECT jsonb_agg(jsonb_build_object(
                    'text',      o.opt->>'texto',
                    'isCorrect', COALESCE((o.opt->>'correcta')::boolean, o.idx = 1)
                ) ORDER BY o.idx)
                FROM jsonb_array_elements(p.opciones) WITH ORDINALITY o(opt, idx)
            ),
            'explicacion', p.explicacion,
            'etiquetas',   p.etiquetas,
            'caja',        filtro.caja
        ) ORDER BY filtro.proximo_repaso ASC
    ), '[]'::jsonb)
    INTO v_qs
    FROM filtro JOIN preguntas p ON p.id = filtro.pregunta_id;

    RETURN jsonb_build_object('questions', v_qs, 'adelantada', p_adelantar);
END $$;


-- =============================================================================
--                    TEORÍA — VISTAS DE FICHEROS
-- =============================================================================
-- El servicio de teoría (backend Python) hace el trabajo pesado: listar
-- ficheros del disco, subir, mover, borrar, servir el binario. Estas RPCs
-- son solo el estado de "leído/no leído" por usuario, y el helper que la
-- landing usa para decidir si mostrar la tarjeta de teoría.

-- El JWT lleva los roles funcionales; teoria.acceder abre la vista.
-- Los admin también entran (aunque no tengan el rol 'teoria' asignado).
CREATE OR REPLACE FUNCTION puede_ver_teoria() RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT tiene_permiso('teoria.acceder') OR es_admin();
$$;

-- Marca (o remarca) un fichero como visto por el usuario actual.
CREATE OR REPLACE FUNCTION marcar_fichero_visto(p_ruta text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF jwt_usuario_id() IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    INSERT INTO ficheros_vistas(usuario_id, ruta, vista_en)
    VALUES (jwt_usuario_id(), p_ruta, now())
    ON CONFLICT (usuario_id, ruta) DO UPDATE
        SET vista_en = EXCLUDED.vista_en;
END $$;

CREATE OR REPLACE FUNCTION marcar_fichero_no_visto(p_ruta text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF jwt_usuario_id() IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    DELETE FROM ficheros_vistas
     WHERE usuario_id = jwt_usuario_id() AND ruta = p_ruta;
END $$;

-- Devuelve las rutas vistas cuyo prefijo coincide con p_prefijo (útil para
-- pintar el estado 'visto' en la vista de una carpeta sin traer todo el
-- historial). Si p_prefijo es NULL/'' devuelve todas.
CREATE OR REPLACE FUNCTION mis_ficheros_vistos(p_prefijo text DEFAULT NULL) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'ruta',     ruta,
        'vista_en', vista_en
    ) ORDER BY vista_en DESC), '[]'::jsonb)
    FROM ficheros_vistas
    WHERE usuario_id = jwt_usuario_id()
      AND (p_prefijo IS NULL OR p_prefijo = '' OR ruta LIKE p_prefijo || '%');
$$;

-- Al mover o renombrar un fichero desde el panel de admin, ajustamos las
-- marcas 'visto' para que sigan apuntando al nuevo path. Se llama desde el
-- backend de teoría después de mover en disco.
CREATE OR REPLACE FUNCTION renombrar_ruta_vistas(p_origen text, p_destino text) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
    IF NOT (tiene_permiso('teoria.gestionar') OR es_admin()) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    -- Fichero suelto: match exacto.
    UPDATE ficheros_vistas
       SET ruta = p_destino
     WHERE ruta = p_origen;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    IF v_n = 0 THEN
        -- Carpeta: reescribe el prefijo.
        UPDATE ficheros_vistas
           SET ruta = p_destino || substring(ruta from length(p_origen) + 1)
         WHERE ruta LIKE p_origen || '/%';
        GET DIAGNOSTICS v_n = ROW_COUNT;
    END IF;
    RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION borrar_ruta_vistas(p_ruta text) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
    IF NOT (tiene_permiso('teoria.gestionar') OR es_admin()) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    DELETE FROM ficheros_vistas
     WHERE ruta = p_ruta OR ruta LIKE p_ruta || '/%';
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END $$;


-- =============================================================================
--                                 ADMIN
-- =============================================================================

CREATE OR REPLACE FUNCTION listar_usuarios() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'permiso_denegado'; END IF;
    RETURN (
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
            'id',         u.id,
            'username',   u.username,
            'email',      u.email,
            'chat_id',    u.chat_id,
            'activo',     u.activo,
            'creado_en',  u.creado_en,
            'tiene_pass', u.password_hash IS NOT NULL,
            'roles',      COALESCE(
                (SELECT array_agg(rol_id ORDER BY rol_id)
                 FROM usuario_roles WHERE usuario_id = u.id),
                ARRAY[]::text[]
            )
        ) ORDER BY u.username), '[]'::jsonb)
        FROM usuarios u
    );
END $$;

CREATE OR REPLACE FUNCTION listar_roles() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', id, 'descripcion', descripcion
    ) ORDER BY id), '[]'::jsonb)
    FROM roles;
$$;

CREATE OR REPLACE FUNCTION asignar_rol(p_usuario_id uuid, p_rol_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'permiso_denegado'; END IF;
    INSERT INTO usuario_roles(usuario_id, rol_id)
    VALUES (p_usuario_id, p_rol_id)
    ON CONFLICT DO NOTHING;
END $$;

CREATE OR REPLACE FUNCTION quitar_rol(p_usuario_id uuid, p_rol_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'permiso_denegado'; END IF;
    IF p_rol_id = 'admin' AND (
        SELECT count(*) FROM usuario_roles WHERE rol_id = 'admin'
    ) <= 1 THEN
        RAISE EXCEPTION 'no_se_puede_quitar_el_ultimo_admin';
    END IF;
    DELETE FROM usuario_roles
     WHERE usuario_id = p_usuario_id AND rol_id = p_rol_id;
END $$;

CREATE OR REPLACE FUNCTION resetear_contrasena(p_usuario_id uuid, p_nueva_pass text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'permiso_denegado'; END IF;
    IF length(p_nueva_pass) < 6 THEN
        RAISE EXCEPTION 'contrasena_muy_corta';
    END IF;
    UPDATE usuarios
       SET password_hash = crypt(p_nueva_pass, gen_salt('bf', 12))
     WHERE id = p_usuario_id;
END $$;

CREATE OR REPLACE FUNCTION set_usuario_activo(p_usuario_id uuid, p_activo boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'permiso_denegado'; END IF;
    UPDATE usuarios SET activo = p_activo WHERE id = p_usuario_id;
END $$;


-- =============================================================================
--                               CONFIG (RPC)
-- =============================================================================

CREATE OR REPLACE FUNCTION leer_config() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_object_agg(clave, valor), '{}'::jsonb) FROM config;
$$;


-- =============================================================================
--                              GRANTS DE EXECUTE
-- =============================================================================

GRANT EXECUTE ON FUNCTION registrarse(text,text,text)                 TO web_anon;
GRANT EXECUTE ON FUNCTION iniciar_sesion(text,text)                   TO web_anon;
GRANT EXECUTE ON FUNCTION login_web(text,text)                        TO web_anon;
GRANT EXECUTE ON FUNCTION registrar_web(text,text,text,text)          TO web_anon;
GRANT EXECUTE ON FUNCTION canjear_codigo_telegram(text,text)          TO web_anon, web_user;
GRANT EXECUTE ON FUNCTION generar_codigo_telegram()                   TO web_user;

GRANT EXECUTE ON FUNCTION mi_sesion()                                 TO web_user;
GRANT EXECUTE ON FUNCTION mi_progreso()                               TO web_user;
GRANT EXECUTE ON FUNCTION mi_progreso_detallado()                     TO web_user;

GRANT EXECUTE ON FUNCTION listar_tests(boolean,int,int,text,boolean,text) TO web_user;
GRANT EXECUTE ON FUNCTION obtener_preguntas_test(uuid)                TO web_user;
GRANT EXECUTE ON FUNCTION iniciar_intento(uuid,text,text,uuid[])      TO web_user;
GRANT EXECUTE ON FUNCTION registrar_respuesta(uuid,uuid,text,boolean,boolean) TO web_user;
GRANT EXECUTE ON FUNCTION finalizar_intento(uuid)                     TO web_user;
GRANT EXECUTE ON FUNCTION descartar_intento(uuid)                     TO web_user;
GRANT EXECUTE ON FUNCTION intento_pendiente(text,uuid)                TO web_user;
GRANT EXECUTE ON FUNCTION reanudar_intento(uuid)                      TO web_user;
GRANT EXECUTE ON FUNCTION borrar_test_y_preguntas(uuid, boolean)      TO web_user;

GRANT EXECUTE ON FUNCTION toggle_favorita_pregunta(uuid)              TO web_user;
GRANT EXECUTE ON FUNCTION toggle_favorita_test(uuid)                  TO web_user;
GRANT EXECUTE ON FUNCTION mis_favoritas_ids()                         TO web_user;
GRANT EXECUTE ON FUNCTION mis_fallos()                                TO web_user;
GRANT EXECUTE ON FUNCTION mis_favoritas()                             TO web_user;
GRANT EXECUTE ON FUNCTION mis_favoritas_agrupadas()                   TO web_user;

GRANT EXECUTE ON FUNCTION importar_test(text,jsonb)                   TO web_user;
GRANT EXECUTE ON FUNCTION importar_test_normalizado(text,text,jsonb)  TO web_user;
GRANT EXECUTE ON FUNCTION descargar_test(uuid)                        TO web_user;
GRANT EXECUTE ON FUNCTION descargar_todos_los_tests()                 TO web_user;
GRANT EXECUTE ON FUNCTION preguntas_de_tests(uuid[])                  TO web_user;
GRANT EXECUTE ON FUNCTION crear_mega_test(text,uuid[])                TO web_user;
GRANT EXECUTE ON FUNCTION listar_simulacros()                         TO web_user;
GRANT EXECUTE ON FUNCTION crear_simulacro(text,uuid,numeric,numeric)  TO web_user;

GRANT EXECUTE ON FUNCTION etiqueta_y_descendientes(text)              TO web_user, web_anon;
GRANT EXECUTE ON FUNCTION listar_etiquetas()                          TO web_user;
GRANT EXECUTE ON FUNCTION crear_etiqueta(text,text,text[],text)       TO web_user;
GRANT EXECUTE ON FUNCTION borrar_etiqueta(text)                       TO web_user;
GRANT EXECUTE ON FUNCTION clasificar_test(uuid)                       TO web_user;
GRANT EXECUTE ON FUNCTION reclasificar_pregunta(uuid,int,real,int,real,int) TO web_user;
GRANT EXECUTE ON FUNCTION reclasificar_todas()                        TO web_user;
GRANT EXECUTE ON FUNCTION reclasificar_todo()                         TO web_user;
GRANT EXECUTE ON FUNCTION buscar_preguntas(text,int,text)             TO web_user;
GRANT EXECUTE ON FUNCTION buscar_preguntas_multi(text,int,text[])     TO web_user;
GRANT EXECUTE ON FUNCTION generar_test_tematico(text,int)             TO web_user;
GRANT EXECUTE ON FUNCTION crear_test_tematico_multi(text[],int,text)  TO web_user;

GRANT EXECUTE ON FUNCTION estado_embeddings()                         TO web_user;
GRANT EXECUTE ON FUNCTION encolar_revectorizado_total()               TO web_user;

GRANT EXECUTE ON FUNCTION mi_ritmo_repaso()                           TO web_user;
GRANT EXECUTE ON FUNCTION set_ritmo_repaso(text)                      TO web_user;
GRANT EXECUTE ON FUNCTION resetear_mis_repasos(uuid)                  TO web_user;
GRANT EXECUTE ON FUNCTION ritmo_repaso_usuario(uuid)                  TO web_user;
GRANT EXECUTE ON FUNCTION intervalo_repaso(int, text)                 TO web_user;
GRANT EXECUTE ON FUNCTION resumen_repaso_test(uuid)                   TO web_user;
GRANT EXECUTE ON FUNCTION resumen_repaso_global()                     TO web_user;
GRANT EXECUTE ON FUNCTION preguntas_repaso_test(uuid, int, boolean)   TO web_user;
GRANT EXECUTE ON FUNCTION preguntas_repaso_global(int, boolean)       TO web_user;

GRANT EXECUTE ON FUNCTION puede_ver_teoria()                          TO web_user;
GRANT EXECUTE ON FUNCTION marcar_fichero_visto(text)                  TO web_user;
GRANT EXECUTE ON FUNCTION marcar_fichero_no_visto(text)               TO web_user;
GRANT EXECUTE ON FUNCTION mis_ficheros_vistos(text)                   TO web_user;
GRANT EXECUTE ON FUNCTION renombrar_ruta_vistas(text, text)           TO web_user;
GRANT EXECUTE ON FUNCTION borrar_ruta_vistas(text)                    TO web_user;

GRANT EXECUTE ON FUNCTION listar_usuarios()                           TO web_user;
GRANT EXECUTE ON FUNCTION listar_roles()                              TO web_user;
GRANT EXECUTE ON FUNCTION asignar_rol(uuid,text)                      TO web_user;
GRANT EXECUTE ON FUNCTION quitar_rol(uuid,text)                       TO web_user;
GRANT EXECUTE ON FUNCTION resetear_contrasena(uuid,text)              TO web_user;
GRANT EXECUTE ON FUNCTION set_usuario_activo(uuid,boolean)            TO web_user;

GRANT EXECUTE ON FUNCTION leer_config()                               TO web_user, web_anon;


-- =============================================================================
--                            SEED DE DATOS BASE
-- =============================================================================

-- ── Contraseña del rol autenticador (lee GUC app.auth_pass) ─────────────────
DO $$
DECLARE v text := current_setting('app.auth_pass', true);
BEGIN
    IF v IS NULL OR length(v) < 4 THEN
        RAISE EXCEPTION 'app.auth_pass no definida o demasiado corta';
    END IF;
    EXECUTE format('ALTER ROLE autenticador WITH PASSWORD %L', v);
END $$;

-- ── Roles funcionales de la aplicación ──────────────────────────────────────
INSERT INTO roles (id, descripcion) VALUES
    ('admin',  'Acceso total al sistema'),
    ('editor', 'Puede crear y editar preguntas, tests y temas'),
    ('alumno', 'Puede realizar tests y consultar su propio progreso'),
    ('teoria', 'Puede acceder al material de teoría')
ON CONFLICT (id) DO NOTHING;

-- ── Permisos y su mapeo a roles ─────────────────────────────────────────────
INSERT INTO permisos (id, descripcion) VALUES
    ('pregunta.crear',    'Crear preguntas'),
    ('pregunta.editar',   'Editar preguntas existentes'),
    ('pregunta.borrar',   'Eliminar preguntas'),
    ('test.crear',        'Crear tests'),
    ('test.editar',       'Editar tests'),
    ('test.borrar',       'Eliminar tests'),
    ('test.publicar',     'Marcar un test como público'),
    ('etiqueta.gestionar','Crear, editar y borrar etiquetas del catálogo'),
    ('usuario.gestionar', 'Dar de alta usuarios y asignarles roles'),
    ('backup.descargar',  'Descargar copias de seguridad de la base de datos'),
    ('test.realizar',     'Realizar tests y registrar respuestas'),
    ('teoria.acceder',    'Ver y descargar ficheros de teoría'),
    ('teoria.gestionar',  'Subir, mover, editar y borrar ficheros de teoría')
ON CONFLICT (id) DO NOTHING;

-- 'admin' hereda todos los permisos automáticamente vía este bulk insert.
INSERT INTO rol_permisos (rol_id, permiso_id)
SELECT 'admin', id FROM permisos
ON CONFLICT DO NOTHING;

INSERT INTO rol_permisos (rol_id, permiso_id) VALUES
    ('editor', 'pregunta.crear'),
    ('editor', 'pregunta.editar'),
    ('editor', 'pregunta.borrar'),
    ('editor', 'test.crear'),
    ('editor', 'test.editar'),
    ('editor', 'test.borrar'),
    ('editor', 'test.publicar'),
    ('editor', 'etiqueta.gestionar'),
    ('editor', 'test.realizar'),
    ('alumno', 'test.realizar'),
    -- El rol 'teoria' solo abre la puerta a leer la teoría, no a
    -- realizar tests ni a gestionarla. Se combina con 'alumno' cuando
    -- corresponda.
    ('teoria', 'teoria.acceder')
ON CONFLICT DO NOTHING;

-- ── Usuario administrador inicial (lee GUC app.admin_pass) ──────────────────
DO $$
DECLARE
    v_id    uuid;
    v_pass  text := current_setting('app.admin_pass', true);
BEGIN
    IF v_pass IS NULL OR length(v_pass) < 8 THEN
        RAISE NOTICE 'ADMIN_PASS no definida o demasiado corta; omito creación de admin';
        RETURN;
    END IF;

    INSERT INTO usuarios (username, email, password_hash)
    VALUES ('admin', NULL, crypt(v_pass, gen_salt('bf', 12)))
    ON CONFLICT (username) DO UPDATE
        SET password_hash = EXCLUDED.password_hash
    RETURNING id INTO v_id;

    INSERT INTO usuario_roles (usuario_id, rol_id)
    VALUES (v_id, 'admin')
    ON CONFLICT DO NOTHING;
END $$;

-- ── Config: valores por defecto de simulacro y curvas de repaso ─────────────
INSERT INTO config(clave, valor) VALUES
    ('historico_2024',         '[]'::jsonb),
    ('historico_2022',         '[]'::jsonb),
    ('plazas_referencia',      '844'::jsonb),
    ('penalizacion_fallo',     '0.333333'::jsonb),
    ('puntos_acierto_parte_2', '0.5'::jsonb),
    ('min_directa_simulacro',  '30'::jsonb),
    ('n_max_simulacro',        '90'::jsonb),
    ('e_max_simulacro',        '50'::jsonb),
    -- Horas por caja para cada ritmo de repaso (Leitner de 7 cajas).
    ('ritmos_repaso', jsonb_build_object(
        'intensivo', jsonb_build_array(2,   8,   24,  72,   168,  360,  720),
        'normal',    jsonb_build_array(24,  72,  168, 360,  720,  1440, 2880),
        'relajado',  jsonb_build_array(48,  168, 504, 1080, 2160, 4320, 8760)
    ))
ON CONFLICT (clave) DO NOTHING;


-- =============================================================================
--                              GAMIFICACIÓN
-- =============================================================================
-- Todo lo que sigue es la misma lógica que la migración manual
-- `db/migraciones/2026-07-02_gamificacion.sql`, pero embebida en el init
-- para que despliegues sobre BBDD vacía la traigan de fábrica. Es idempotente
-- (usa IF NOT EXISTS / ON CONFLICT) por si se re-corre.

-- ─────────────────────────── Amistades ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS amistades (
    usuario_a       uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    usuario_b       uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    solicitante     uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    estado          text NOT NULL DEFAULT 'pendiente'
                        CHECK (estado IN ('pendiente','aceptada','bloqueada')),
    creado_en       timestamptz NOT NULL DEFAULT now(),
    actualizado_en  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (usuario_a, usuario_b),
    CHECK (usuario_a < usuario_b),
    CHECK (solicitante IN (usuario_a, usuario_b))
);
CREATE INDEX IF NOT EXISTS amistades_a_idx ON amistades (usuario_a);
CREATE INDEX IF NOT EXISTS amistades_b_idx ON amistades (usuario_b);
ALTER TABLE amistades ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS amistades_visibles ON amistades;
CREATE POLICY amistades_visibles ON amistades
    FOR SELECT TO web_user
    USING (usuario_a = jwt_usuario_id() OR usuario_b = jwt_usuario_id() OR es_admin());
DROP POLICY IF EXISTS amistades_escritura ON amistades;
CREATE POLICY amistades_escritura ON amistades
    FOR ALL TO web_user
    USING (usuario_a = jwt_usuario_id() OR usuario_b = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_a = jwt_usuario_id() OR usuario_b = jwt_usuario_id() OR es_admin());
GRANT SELECT, INSERT, UPDATE, DELETE ON amistades TO web_user;

-- ─────────────────────────── Web Push ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS push_subscripciones (
    id          bigserial PRIMARY KEY,
    usuario_id  uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    endpoint    text NOT NULL,
    p256dh      text NOT NULL,
    auth        text NOT NULL,
    user_agent  text,
    creada_en   timestamptz NOT NULL DEFAULT now(),
    vista_en    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (endpoint)
);
CREATE INDEX IF NOT EXISTS push_subs_usuario_idx ON push_subscripciones (usuario_id);
ALTER TABLE push_subscripciones ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS push_subs_propias ON push_subscripciones;
CREATE POLICY push_subs_propias ON push_subscripciones
    FOR ALL TO web_user
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());
GRANT SELECT, INSERT, UPDATE, DELETE ON push_subscripciones TO web_user;
GRANT USAGE, SELECT ON SEQUENCE push_subscripciones_id_seq TO web_user;
ALTER TABLE push_subscripciones ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();

-- ─────────────────── Cola y estado de notificaciones ────────────────────────
CREATE TABLE IF NOT EXISTS notificaciones_pendientes (
    id         bigserial PRIMARY KEY,
    usuario_id uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    tipo       text NOT NULL,
    titulo     text NOT NULL,
    cuerpo     text NOT NULL,
    url        text,
    datos      jsonb NOT NULL DEFAULT '{}'::jsonb,
    creado_en  timestamptz NOT NULL DEFAULT now(),
    enviado_en timestamptz
);
CREATE INDEX IF NOT EXISTS notif_pend_idx
    ON notificaciones_pendientes (enviado_en, creado_en) WHERE enviado_en IS NULL;

CREATE TABLE IF NOT EXISTS notificaciones_estado (
    usuario_id uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    tipo       text NOT NULL,
    ultima_en  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (usuario_id, tipo)
);

-- ─────────────────────────── Retos diarios ──────────────────────────────────
CREATE TABLE IF NOT EXISTS retos_plantillas (
    id           text PRIMARY KEY,
    titulo       text NOT NULL,
    descripcion  text NOT NULL,
    tipo         text NOT NULL,
    objetivo     int  NOT NULL DEFAULT 1,
    puntos       int  NOT NULL DEFAULT 10,
    activo       boolean NOT NULL DEFAULT true,
    creada_en    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS retos_diarios (
    id            bigserial PRIMARY KEY,
    usuario_id    uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    fecha         date NOT NULL DEFAULT current_date,
    plantilla_id  text NOT NULL REFERENCES retos_plantillas(id) ON DELETE CASCADE,
    objetivo      int NOT NULL,
    progreso      int NOT NULL DEFAULT 0,
    puntos        int NOT NULL DEFAULT 10,
    completado_en timestamptz,
    UNIQUE (usuario_id, fecha, plantilla_id)
);
CREATE INDEX IF NOT EXISTS retos_diarios_usuario_fecha
    ON retos_diarios (usuario_id, fecha);
ALTER TABLE retos_diarios ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS retos_diarios_propios ON retos_diarios;
CREATE POLICY retos_diarios_propios ON retos_diarios
    FOR ALL TO web_user
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());
GRANT SELECT ON retos_plantillas TO web_user;
GRANT SELECT, INSERT, UPDATE ON retos_diarios TO web_user;
GRANT USAGE, SELECT ON SEQUENCE retos_diarios_id_seq TO web_user;

INSERT INTO retos_plantillas (id, titulo, descripcion, tipo, objetivo, puntos) VALUES
    ('responder_20',  'Responde 20 preguntas',  'Responde 20 preguntas hoy, sean del test que sean.', 'responder_n',    20, 10),
    ('responder_50',  'Maratón: 50 preguntas',  'Aguanta el ritmo y responde 50 preguntas hoy.',        'responder_n',    50, 25),
    ('acertar_15',    'Acierta 15 preguntas',   'Acierta 15 preguntas hoy.',                            'acertar_n',      15, 15),
    ('acertar_30',    'Precisión: 30 aciertos', 'Consigue 30 aciertos hoy.',                            'acertar_n',      30, 30),
    ('teoria_1',      'Estudia 1 documento',    'Marca al menos 1 documento de teoría como leído hoy.', 'teoria_n',        1, 10),
    ('teoria_3',      'Estudia 3 documentos',   'Marca 3 documentos de teoría como leídos hoy.',        'teoria_n',        3, 20),
    ('repasos_10',    'Repasa 10 vencidas',     'Completa 10 preguntas del repaso espaciado.',          'repasos_n',      10, 15),
    ('repasos_25',    'Repasa 25 vencidas',     'Completa 25 preguntas del repaso espaciado.',          'repasos_n',      25, 30),
    ('test_completo', 'Termina un test',        'Empieza y termina un test entero hoy.',                'test_completo',   1, 15),
    ('test_80',       'Sobresaliente: 80 %',    'Termina un test con al menos 80 % de aciertos.',       'test_precision', 80, 25),
    ('redimir_5',     'Redime 5 fallos',        'Vuelve a acertar 5 preguntas que llevabas fallando.',  'redimir_n',       5, 20),
    ('subir_cajas_10','Sube 10 cajas Leitner',  'Consigue que 10 preguntas suban de caja hoy.',         'subir_cajas_n',  10, 20),
    ('etiqueta_nueva','Explora un tema nuevo',  'Responde preguntas de una etiqueta que aún no habías tocado.', 'etiqueta_nueva', 1, 25),
    ('racha_dias',    'Racha viva',             'Estudia hoy para mantener tu racha de días seguidos.', 'racha_dias',      1,  5)
ON CONFLICT (id) DO UPDATE
    SET titulo = EXCLUDED.titulo, descripcion = EXCLUDED.descripcion,
        tipo = EXCLUDED.tipo, objetivo = EXCLUDED.objetivo, puntos = EXCLUDED.puntos;

-- ─────────────────────────── Racha diaria ───────────────────────────────────
CREATE TABLE IF NOT EXISTS rachas_diarias (
    usuario_id      uuid PRIMARY KEY REFERENCES usuarios(id) ON DELETE CASCADE,
    racha_actual    int  NOT NULL DEFAULT 0,
    racha_maxima    int  NOT NULL DEFAULT 0,
    ultima_fecha    date,
    puntos_totales  int  NOT NULL DEFAULT 0
);
ALTER TABLE rachas_diarias ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS racha_propia ON rachas_diarias;
CREATE POLICY racha_propia ON rachas_diarias
    FOR SELECT TO web_user
    USING (usuario_id = jwt_usuario_id() OR es_admin()
           OR EXISTS (
                SELECT 1 FROM amistades a
                WHERE a.estado = 'aceptada'
                  AND jwt_usuario_id() IN (a.usuario_a, a.usuario_b)
                  AND rachas_diarias.usuario_id IN (a.usuario_a, a.usuario_b)
           ));
GRANT SELECT ON rachas_diarias TO web_user;

-- ── Funciones (definiciones idénticas a la migración; ver ese fichero) ─────
CREATE OR REPLACE FUNCTION amigos_de(p_usuario uuid) RETURNS TABLE(amigo_id uuid)
LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN usuario_a = p_usuario THEN usuario_b ELSE usuario_a END
      FROM amistades
     WHERE estado = 'aceptada'
       AND p_usuario IN (usuario_a, usuario_b);
$$;

CREATE OR REPLACE FUNCTION buscar_usuarios(p_q text, p_lim int DEFAULT 15) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    WITH candidatos AS (
        SELECT u.id, u.username FROM usuarios u
         WHERE u.activo AND u.id <> jwt_usuario_id()
           AND (u.username ILIKE p_q || '%' OR u.username %> p_q)
         ORDER BY (u.username ILIKE p_q || '%') DESC,
                  similarity(u.username, p_q) DESC, u.username
         LIMIT GREATEST(p_lim, 1)
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', c.id, 'username', c.username,
        'estado', (SELECT a.estado FROM amistades a
                     WHERE a.usuario_a = LEAST(c.id, jwt_usuario_id())
                       AND a.usuario_b = GREATEST(c.id, jwt_usuario_id())),
        'yo_solicite', (SELECT a.solicitante = jwt_usuario_id() FROM amistades a
                     WHERE a.usuario_a = LEAST(c.id, jwt_usuario_id())
                       AND a.usuario_b = GREATEST(c.id, jwt_usuario_id()))
    ) ORDER BY c.username), '[]'::jsonb) FROM candidatos c;
$$;

CREATE OR REPLACE FUNCTION enviar_solicitud_amistad(p_otro uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_yo uuid := jwt_usuario_id(); v_a uuid; v_b uuid;
BEGIN
    IF v_yo IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    IF p_otro = v_yo THEN RAISE EXCEPTION 'no_puedes_ser_tu_propio_amigo'; END IF;
    IF NOT EXISTS (SELECT 1 FROM usuarios WHERE id = p_otro AND activo) THEN
        RAISE EXCEPTION 'usuario_no_existe';
    END IF;
    v_a := LEAST(v_yo, p_otro); v_b := GREATEST(v_yo, p_otro);
    INSERT INTO amistades(usuario_a, usuario_b, solicitante, estado)
    VALUES (v_a, v_b, v_yo, 'pendiente')
    ON CONFLICT (usuario_a, usuario_b) DO UPDATE
        SET estado = CASE WHEN amistades.estado = 'pendiente'
                          AND amistades.solicitante = p_otro THEN 'aceptada'
                          ELSE amistades.estado END,
            actualizado_en = now();
    INSERT INTO notificaciones_pendientes(usuario_id, tipo, titulo, cuerpo, url, datos)
    SELECT p_otro, 'amistad_solicitud', 'Nueva solicitud de amistad',
           u.username || ' quiere ser tu amigo en Aprentix', '/#amigos',
           jsonb_build_object('de', v_yo, 'username', u.username)
      FROM usuarios u
     WHERE u.id = v_yo
       AND EXISTS (SELECT 1 FROM amistades WHERE usuario_a = v_a AND usuario_b = v_b
                     AND estado = 'pendiente' AND solicitante = v_yo);
    PERFORM pg_notify('gamificacion', 'nueva:' || p_otro::text);
    RETURN (SELECT to_jsonb(a) FROM amistades a WHERE usuario_a = v_a AND usuario_b = v_b);
END $$;

CREATE OR REPLACE FUNCTION responder_solicitud_amistad(p_otro uuid, p_aceptar boolean) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_yo uuid := jwt_usuario_id(); v_a uuid; v_b uuid; v_ok boolean;
BEGIN
    IF v_yo IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    v_a := LEAST(v_yo, p_otro); v_b := GREATEST(v_yo, p_otro);
    IF p_aceptar THEN
        UPDATE amistades SET estado = 'aceptada', actualizado_en = now()
         WHERE usuario_a = v_a AND usuario_b = v_b
           AND estado = 'pendiente' AND solicitante = p_otro
        RETURNING true INTO v_ok;
        IF NOT COALESCE(v_ok, false) THEN RAISE EXCEPTION 'solicitud_no_encontrada'; END IF;
    ELSE
        DELETE FROM amistades WHERE usuario_a = v_a AND usuario_b = v_b;
    END IF;
    RETURN jsonb_build_object('ok', true, 'aceptada', p_aceptar);
END $$;

CREATE OR REPLACE FUNCTION cancelar_amistad(p_otro uuid) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_yo uuid := jwt_usuario_id();
        v_a uuid := LEAST(v_yo, p_otro);
        v_b uuid := GREATEST(v_yo, p_otro);
BEGIN
    IF v_yo IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    DELETE FROM amistades WHERE usuario_a = v_a AND usuario_b = v_b;
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION mis_amigos() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', u.id, 'username', u.username,
        'racha_actual', COALESCE(r.racha_actual, 0),
        'racha_maxima', COALESCE(r.racha_maxima, 0),
        'puntos',       COALESCE(r.puntos_totales, 0),
        'retos_hoy_completados', (
            SELECT count(*) FROM retos_diarios rd
             WHERE rd.usuario_id = u.id AND rd.fecha = current_date
               AND rd.completado_en IS NOT NULL)
    ) ORDER BY u.username), '[]'::jsonb)
    FROM amistades a
    JOIN usuarios u ON u.id = CASE WHEN a.usuario_a = jwt_usuario_id()
                                    THEN a.usuario_b ELSE a.usuario_a END
    LEFT JOIN rachas_diarias r ON r.usuario_id = u.id
    WHERE a.estado = 'aceptada' AND jwt_usuario_id() IN (a.usuario_a, a.usuario_b);
$$;

CREATE OR REPLACE FUNCTION mis_solicitudes_amistad() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT jsonb_build_object(
        'recibidas', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('id', u.id, 'username', u.username, 'desde', a.creado_en)
                             ORDER BY a.creado_en DESC)
            FROM amistades a JOIN usuarios u ON u.id = a.solicitante
            WHERE a.estado = 'pendiente' AND a.solicitante <> jwt_usuario_id()
              AND jwt_usuario_id() IN (a.usuario_a, a.usuario_b)
        ), '[]'::jsonb),
        'enviadas', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('id', u.id, 'username', u.username, 'desde', a.creado_en)
                             ORDER BY a.creado_en DESC)
            FROM amistades a
            JOIN usuarios u ON u.id = CASE WHEN a.usuario_a = jwt_usuario_id()
                                            THEN a.usuario_b ELSE a.usuario_a END
            WHERE a.estado = 'pendiente' AND a.solicitante = jwt_usuario_id()
              AND jwt_usuario_id() IN (a.usuario_a, a.usuario_b)
        ), '[]'::jsonb)
    );
$$;

CREATE OR REPLACE FUNCTION mis_retos_hoy() RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_uid uuid := jwt_usuario_id();
        v_hoy date := current_date;
        v_n int; v_res jsonb;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    SELECT count(*) INTO v_n FROM retos_diarios WHERE usuario_id = v_uid AND fecha = v_hoy;
    IF v_n = 0 THEN
        INSERT INTO retos_diarios(usuario_id, fecha, plantilla_id, objetivo, puntos)
        SELECT v_uid, v_hoy, p.id, p.objetivo, p.puntos
          FROM (SELECT id, objetivo, puntos FROM retos_plantillas WHERE activo
                 ORDER BY md5(v_uid::text || v_hoy::text || id) LIMIT 3) p
        ON CONFLICT DO NOTHING;
    END IF;
    SELECT jsonb_build_object(
        'fecha', v_hoy,
        'retos', COALESCE(jsonb_agg(jsonb_build_object(
            'id', rd.id, 'plantilla_id', rd.plantilla_id, 'titulo', rp.titulo,
            'descripcion', rp.descripcion, 'tipo', rp.tipo,
            'objetivo', rd.objetivo, 'progreso', rd.progreso, 'puntos', rd.puntos,
            'completado', rd.completado_en IS NOT NULL,
            'completado_en', rd.completado_en
        ) ORDER BY rd.id), '[]'::jsonb),
        'racha', (SELECT jsonb_build_object(
            'actual', COALESCE(racha_actual, 0),
            'maxima', COALESCE(racha_maxima, 0),
            'puntos', COALESCE(puntos_totales, 0)
        ) FROM rachas_diarias WHERE usuario_id = v_uid)
    ) INTO v_res
    FROM retos_diarios rd JOIN retos_plantillas rp ON rp.id = rd.plantilla_id
    WHERE rd.usuario_id = v_uid AND rd.fecha = v_hoy;
    RETURN v_res;
END $$;

CREATE OR REPLACE FUNCTION avanzar_reto(p_uid uuid, p_tipo text, p_incremento int DEFAULT 1)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_ids bigint[]; v_id bigint; v_rp retos_plantillas; v_rd retos_diarios;
    v_username text;
BEGIN
    SELECT array_agg(rd.id) INTO v_ids
      FROM retos_diarios rd JOIN retos_plantillas rp ON rp.id = rd.plantilla_id
     WHERE rd.usuario_id = p_uid AND rd.fecha = current_date
       AND rp.tipo = p_tipo AND rd.completado_en IS NULL;
    IF v_ids IS NULL THEN RETURN; END IF;
    FOREACH v_id IN ARRAY v_ids LOOP
        SELECT * INTO v_rd FROM retos_diarios WHERE id = v_id FOR UPDATE;
        SELECT * INTO v_rp FROM retos_plantillas WHERE id = v_rd.plantilla_id;
        UPDATE retos_diarios
           SET progreso = LEAST(progreso + GREATEST(p_incremento, 0), objetivo),
               completado_en = CASE WHEN completado_en IS NULL
                                     AND progreso + GREATEST(p_incremento, 0) >= objetivo
                                THEN now() ELSE completado_en END
         WHERE id = v_id RETURNING * INTO v_rd;
        IF v_rd.completado_en IS NOT NULL THEN
            INSERT INTO rachas_diarias(usuario_id, puntos_totales) VALUES (p_uid, v_rd.puntos)
            ON CONFLICT (usuario_id) DO UPDATE
                SET puntos_totales = rachas_diarias.puntos_totales + v_rd.puntos;
            SELECT username INTO v_username FROM usuarios WHERE id = p_uid;
            INSERT INTO notificaciones_pendientes(usuario_id, tipo, titulo, cuerpo, url, datos)
            SELECT amigo_id, 'amigo_reto',
                   '🎯 ' || v_username || ' completó un reto',
                   v_rp.titulo, '/#amigos',
                   jsonb_build_object('amigo', p_uid, 'username', v_username,
                       'reto', v_rp.id, 'titulo', v_rp.titulo, 'puntos', v_rd.puntos)
              FROM amigos_de(p_uid);
            PERFORM pg_notify('gamificacion', 'reto:' || p_uid::text);
        END IF;
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION tocar_racha(p_uid uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_hoy date := current_date; v_row rachas_diarias;
BEGIN
    SELECT * INTO v_row FROM rachas_diarias WHERE usuario_id = p_uid FOR UPDATE;
    IF v_row.usuario_id IS NULL THEN
        INSERT INTO rachas_diarias(usuario_id, racha_actual, racha_maxima, ultima_fecha)
        VALUES (p_uid, 1, 1, v_hoy);
        PERFORM avanzar_reto(p_uid, 'racha_dias', 1);
        RETURN;
    END IF;
    IF v_row.ultima_fecha = v_hoy THEN RETURN;
    ELSIF v_row.ultima_fecha = v_hoy - 1 THEN
        UPDATE rachas_diarias
           SET racha_actual = racha_actual + 1,
               racha_maxima = GREATEST(racha_maxima, racha_actual + 1),
               ultima_fecha = v_hoy WHERE usuario_id = p_uid;
    ELSE
        UPDATE rachas_diarias
           SET racha_actual = 1, racha_maxima = GREATEST(racha_maxima, 1),
               ultima_fecha = v_hoy WHERE usuario_id = p_uid;
    END IF;
    PERFORM avanzar_reto(p_uid, 'racha_dias', 1);
END $$;

CREATE OR REPLACE FUNCTION trg_respuestas_gamif() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_uid uuid; v_caja_prev int; v_etiq text[]; v_etiqueta_nueva boolean := false;
BEGIN
    SELECT i.usuario_id INTO v_uid FROM intentos i WHERE i.id = NEW.intento_id;
    IF v_uid IS NULL THEN RETURN NEW; END IF;
    PERFORM tocar_racha(v_uid);
    PERFORM avanzar_reto(v_uid, 'responder_n', 1);
    IF NEW.correcta THEN
        PERFORM avanzar_reto(v_uid, 'acertar_n', 1);
        SELECT fallos INTO v_caja_prev FROM repasos
          WHERE usuario_id = v_uid AND pregunta_id = NEW.pregunta_id;
        IF COALESCE(v_caja_prev, 0) > 0 THEN
            PERFORM avanzar_reto(v_uid, 'redimir_n', 1);
        END IF;
        SELECT etiquetas INTO v_etiq FROM preguntas WHERE id = NEW.pregunta_id;
        IF v_etiq IS NOT NULL AND cardinality(v_etiq) > 0 THEN
            SELECT NOT EXISTS (
                SELECT 1 FROM respuestas r2
                  JOIN intentos i2 ON i2.id = r2.intento_id
                  JOIN preguntas p2 ON p2.id = r2.pregunta_id
                 WHERE i2.usuario_id = v_uid AND r2.id <> NEW.id
                   AND p2.etiquetas && v_etiq
            ) INTO v_etiqueta_nueva;
            IF v_etiqueta_nueva THEN
                PERFORM avanzar_reto(v_uid, 'etiqueta_nueva', 1);
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS respuestas_gamif ON respuestas;
CREATE TRIGGER respuestas_gamif AFTER INSERT ON respuestas
    FOR EACH ROW EXECUTE FUNCTION trg_respuestas_gamif();

CREATE OR REPLACE FUNCTION trg_repasos_gamif() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.caja > 1 THEN PERFORM avanzar_reto(NEW.usuario_id, 'subir_cajas_n', 1); END IF;
    ELSIF TG_OP = 'UPDATE' AND NEW.caja > OLD.caja THEN
        PERFORM avanzar_reto(NEW.usuario_id, 'subir_cajas_n', 1);
    END IF;
    IF TG_OP = 'UPDATE' THEN
        PERFORM avanzar_reto(NEW.usuario_id, 'repasos_n', 1);
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS repasos_gamif ON repasos;
CREATE TRIGGER repasos_gamif AFTER INSERT OR UPDATE ON repasos
    FOR EACH ROW EXECUTE FUNCTION trg_repasos_gamif();

CREATE OR REPLACE FUNCTION trg_teoria_gamif() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    PERFORM tocar_racha(NEW.usuario_id);
    PERFORM avanzar_reto(NEW.usuario_id, 'teoria_n', 1);
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS teoria_gamif ON ficheros_vistas;
CREATE TRIGGER teoria_gamif AFTER INSERT ON ficheros_vistas
    FOR EACH ROW EXECUTE FUNCTION trg_teoria_gamif();

CREATE OR REPLACE FUNCTION trg_intento_finalizado_gamif() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_corr int; v_tot int; v_prec int;
BEGIN
    IF NEW.finalizado_en IS NULL OR OLD.finalizado_en IS NOT NULL THEN RETURN NEW; END IF;
    SELECT count(*) FILTER (WHERE correcta), count(*)
      INTO v_corr, v_tot FROM respuestas WHERE intento_id = NEW.id;
    IF v_tot > 0 THEN
        PERFORM avanzar_reto(NEW.usuario_id, 'test_completo', 1);
        v_prec := (v_corr * 100) / v_tot;
        IF v_prec >= 80 THEN
            PERFORM avanzar_reto(NEW.usuario_id, 'test_precision', v_prec);
        END IF;
    END IF;
    RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS intentos_gamif ON intentos;
CREATE TRIGGER intentos_gamif AFTER UPDATE OF finalizado_en ON intentos
    FOR EACH ROW EXECUTE FUNCTION trg_intento_finalizado_gamif();

-- ── Web Push RPCs ───────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION registrar_suscripcion_push(
    p_endpoint text, p_p256dh text, p_auth text, p_user_agent text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $$
BEGIN
    IF jwt_usuario_id() IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    INSERT INTO push_subscripciones(usuario_id, endpoint, p256dh, auth, user_agent)
    VALUES (jwt_usuario_id(), p_endpoint, p_p256dh, p_auth, p_user_agent)
    ON CONFLICT (endpoint) DO UPDATE
        SET usuario_id = EXCLUDED.usuario_id, p256dh = EXCLUDED.p256dh,
            auth = EXCLUDED.auth, user_agent = EXCLUDED.user_agent, vista_en = now();
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION borrar_suscripcion_push(p_endpoint text) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
    IF jwt_usuario_id() IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    DELETE FROM push_subscripciones
     WHERE usuario_id = jwt_usuario_id() AND endpoint = p_endpoint;
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION vapid_public_key() RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(valor #>> '{}', '') FROM config WHERE clave = 'vapid_public_key';
$$;

GRANT EXECUTE ON FUNCTION buscar_usuarios(text, int)                     TO web_user;
GRANT EXECUTE ON FUNCTION enviar_solicitud_amistad(uuid)                 TO web_user;
GRANT EXECUTE ON FUNCTION responder_solicitud_amistad(uuid, boolean)     TO web_user;
GRANT EXECUTE ON FUNCTION cancelar_amistad(uuid)                         TO web_user;
GRANT EXECUTE ON FUNCTION mis_amigos()                                   TO web_user;
GRANT EXECUTE ON FUNCTION mis_solicitudes_amistad()                      TO web_user;
GRANT EXECUTE ON FUNCTION mis_retos_hoy()                                TO web_user;
GRANT EXECUTE ON FUNCTION registrar_suscripcion_push(text,text,text,text) TO web_user;
GRANT EXECUTE ON FUNCTION borrar_suscripcion_push(text)                  TO web_user;
GRANT EXECUTE ON FUNCTION vapid_public_key()                             TO web_user, web_anon;
