-- =============================================================================
-- 01_esquema.sql — Aprentix (rediseño 2026-07)
--
-- Fuente única de verdad del esquema, funciones, políticas RLS y seed base.
-- Se ejecuta al arrancar el contenedor de Postgres sobre una BD vacía y deja
-- el sistema listo para servir tráfico.
--
-- Alcance por bloques:
--   BLOQUE A — Identidad y RBAC (usuarios, roles, permisos, sesiones, tokens
--              de verificación, helpers JWT/RLS).
--   BLOQUE B — Gamificación, config, push y cola de embeddings (soporte
--              transversal que usan el resto de bloques).
--   BLOQUE C — Contenido: oposiciones, temas, módulos, secciones, preguntas,
--              intentos, respuestas, repasos, marcadores, documentos y
--              detección de duplicados. (Se añade en fase posterior.)
--
-- Convenciones:
--   • Español, snake_case, `timestamptz` en UTC.
--   • Nada de datos personales opcionales (sin IP, sin user-agent, sin
--     geolocalización). Guardamos email, contraseña (hash bcrypt) y estado
--     funcional de la cuenta.
--   • Toda tabla accesible desde la SPA lleva RLS activo. `web_user` sólo
--     entra a lo suyo; `admin` (rol funcional) ve todo. Los helpers
--     `jwt_usuario_id()`, `jwt_roles()`, `tiene_permiso()` y `es_admin()`
--     hacen el trabajo desde `SECURITY DEFINER`.
-- =============================================================================


-- ─────────────────────────── Extensiones ────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS pgcrypto;    -- gen_random_uuid, crypt/bcrypt, hmac, pgp_sym_*
CREATE EXTENSION IF NOT EXISTS pg_trgm;     -- búsqueda difusa (similarity, %>)
CREATE EXTENSION IF NOT EXISTS citext;      -- email case-insensitive
CREATE EXTENSION IF NOT EXISTS vector;      -- pgvector (usado en bloque de contenido)


-- =============================================================================
--                       BLOQUE A — IDENTIDAD Y RBAC
-- =============================================================================


-- ─────────────────────────── Identidad ──────────────────────────────────────
-- Login por email (case-insensitive). `nombre_visible` es sólo etiqueta UI.
-- No guardamos IP, user-agent, geolocalización ni ningún metadato de conexión.
-- Sólo lo funcional para operar la cuenta con seguridad razonable.
CREATE TABLE usuarios (
    id                      uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    email                   citext      UNIQUE NOT NULL,
    email_verificado_en     timestamptz,
    nombre_visible          text        NOT NULL,
    -- bcrypt (pgcrypto). Se abstrae en _hash_password / _verify_password
    -- para poder migrar a Argon2id el día que se instale pg_argon2.
    password_hash           text        NOT NULL,
    password_actualizado_en timestamptz NOT NULL DEFAULT now(),
    -- Estado funcional.
    activo                  boolean     NOT NULL DEFAULT true,
    -- Lockout tras N intentos fallidos. Se resetea al login OK.
    intentos_login_fallidos int         NOT NULL DEFAULT 0,
    bloqueado_hasta         timestamptz,
    -- TOTP opcional. `totp_secret` va cifrado con pgp_sym_encrypt usando
    -- el GUC `app.jwt_secret` como clave (rotación conjunta).
    totp_secret             bytea,
    totp_activo             boolean     NOT NULL DEFAULT false,
    -- Sólo timestamp del último login OK. Sin IP, sin UA.
    ultimo_login_en         timestamptz,
    creado_en               timestamptz NOT NULL DEFAULT now(),
    actualizado_en          timestamptz NOT NULL DEFAULT now(),
    -- Soft-delete para autoservicio: al borrar la cuenta anonimizamos
    -- email/nombre_visible y ponemos `borrado_en`. Un cron mensual purga.
    borrado_en              timestamptz
);
CREATE INDEX usuarios_activos_idx ON usuarios (id) WHERE activo AND borrado_en IS NULL;


-- RBAC funcional. Los roles Postgres (autenticador/web_anon/web_user) son
-- otra cosa: sólo el rol técnico de conexión. Los roles de la aplicación
-- ('admin', 'editor', 'tests', 'teoria') viven aquí.
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


-- ─────────────────────────── Sesiones (refresh tokens revocables) ───────────
-- Access token = JWT HS256 corto (15 min) con claim `jti`. La fila viva en
-- `sesiones` es lo que valida el refresh: si desaparece o `revocada_en` está
-- puesta, no se puede refrescar. Sin IP, sin UA.
CREATE TABLE sesiones (
    jti          uuid        PRIMARY KEY,
    usuario_id   uuid        NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    -- sha256 del refresh token (nunca guardar el token plano).
    refresh_hash text        NOT NULL,
    emitida_en   timestamptz NOT NULL DEFAULT now(),
    expira_en    timestamptz NOT NULL,
    revocada_en  timestamptz
);
CREATE INDEX sesiones_usuario_activas_idx
    ON sesiones (usuario_id, expira_en DESC)
    WHERE revocada_en IS NULL;


-- ─────────────────────────── Tokens de verificación ─────────────────────────
-- Sirve para verificar email al registrarse y para reset de contraseña. TTL
-- corto (30 min). Guardamos sólo el sha256 del token; el token plano viaja
-- únicamente por el email al usuario. `usado_en` cierra el token para siempre.
CREATE TABLE tokens_verificacion (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id  uuid        NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    tipo        text        NOT NULL CHECK (tipo IN ('verificar_email','reset_password')),
    token_hash  text        NOT NULL,
    expira_en   timestamptz NOT NULL,
    usado_en    timestamptz,
    creado_en   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX tokens_verificacion_hash_idx ON tokens_verificacion (token_hash);
CREATE INDEX tokens_verificacion_usuario_idx
    ON tokens_verificacion (usuario_id, tipo, creado_en DESC);


-- =============================================================================
--                 BLOQUE B — CONFIG, GAMIFICACIÓN Y PUSH
-- =============================================================================


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


-- ─────────────────────────── Cola de embeddings ────────────────────────────
-- La usa el worker Python (embeddings/worker.py) para procesar en lotes.
-- Sólo tiene `entidad='pregunta'` porque el catálogo de etiquetas viejo se
-- retira; si el día de mañana vuelve algo más que vectorizar, esta tabla
-- ya lo aguanta con un CHECK ampliable.
CREATE TABLE cola_embeddings (
    id            bigserial PRIMARY KEY,
    entidad       text NOT NULL CHECK (entidad IN ('pregunta')),
    entidad_id    text NOT NULL,
    encolado_en   timestamptz NOT NULL DEFAULT now(),
    procesado_en  timestamptz
);
CREATE INDEX cola_emb_pendiente ON cola_embeddings (encolado_en)
    WHERE procesado_en IS NULL;


-- ─────────────────────────── Gamificación ───────────────────────────────────
-- Retos (diarios/semanales/mensuales), logros (hitos únicos), XP y racha.
-- Todo el "día" se calcula en Europe/Madrid (ver hoy_madrid() más abajo).
CREATE TABLE retos_catalogo (
    id           serial PRIMARY KEY,
    codigo       text UNIQUE NOT NULL,
    titulo       text NOT NULL,
    descripcion  text NOT NULL,
    periodo      text NOT NULL CHECK (periodo IN ('diario','semanal','mensual')),
    objetivo     int  NOT NULL CHECK (objetivo > 0),
    xp           int  NOT NULL DEFAULT 20 CHECK (xp >= 0),
    icono        text NOT NULL DEFAULT '🎯',
    activo       boolean NOT NULL DEFAULT true,
    creado_en    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX retos_catalogo_periodo_idx
    ON retos_catalogo (periodo) WHERE activo;

CREATE TABLE retos_usuario (
    usuario_id     uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    reto_id        int  NOT NULL REFERENCES retos_catalogo(id) ON DELETE CASCADE,
    periodo_inicio date NOT NULL,
    progreso       int  NOT NULL DEFAULT 0,
    completado_en  timestamptz,
    meta           jsonb NOT NULL DEFAULT '{}'::jsonb,
    actualizado_en timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (usuario_id, reto_id, periodo_inicio)
);
CREATE INDEX retos_usuario_uid_idx ON retos_usuario (usuario_id, periodo_inicio DESC);

CREATE TABLE logros_catalogo (
    id           serial PRIMARY KEY,
    codigo       text UNIQUE NOT NULL,
    titulo       text NOT NULL,
    descripcion  text NOT NULL,
    objetivo     int  NOT NULL DEFAULT 1 CHECK (objetivo > 0),
    xp           int  NOT NULL DEFAULT 100 CHECK (xp >= 0),
    icono        text NOT NULL DEFAULT '🏆',
    activo       boolean NOT NULL DEFAULT true,
    creado_en    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE logros_usuario (
    usuario_id  uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    logro_id    int  NOT NULL REFERENCES logros_catalogo(id) ON DELETE CASCADE,
    progreso    int  NOT NULL DEFAULT 0,
    obtenido_en timestamptz,
    PRIMARY KEY (usuario_id, logro_id)
);
CREATE INDEX logros_usuario_uid_idx ON logros_usuario (usuario_id);

CREATE TABLE usuario_gamificacion (
    usuario_id        uuid PRIMARY KEY REFERENCES usuarios(id) ON DELETE CASCADE,
    xp_total          int  NOT NULL DEFAULT 0,
    racha_actual      int  NOT NULL DEFAULT 0,
    racha_maxima      int  NOT NULL DEFAULT 0,
    ultimo_dia_activo date,
    actualizado_en    timestamptz NOT NULL DEFAULT now()
);


-- ─────────────────────────── Notificaciones Web Push ───────────────────────
-- Endpoint único global (spec Web Push). `push_envios` guarda sólo el ÚLTIMO
-- envío por (usuario, tipo) para rate-limitar sin escanear un histórico.
CREATE TABLE push_suscripciones (
    endpoint     text PRIMARY KEY,
    usuario_id   uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    p256dh       text NOT NULL,
    auth         text NOT NULL,
    ua           text,                                   -- sólo diagnóstico, no PII
    tz           text NOT NULL DEFAULT 'Europe/Madrid',
    activa       boolean NOT NULL DEFAULT true,
    creada_en    timestamptz NOT NULL DEFAULT now(),
    ultima_ok_en timestamptz,
    ultimo_error text
);
CREATE INDEX push_suscripciones_usuario_idx
    ON push_suscripciones (usuario_id) WHERE activa;

CREATE TABLE push_envios (
    usuario_id  uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    tipo        text NOT NULL CHECK (tipo IN ('repaso','inactividad','reto')),
    enviado_en  timestamptz NOT NULL DEFAULT now(),
    payload     jsonb,
    PRIMARY KEY (usuario_id, tipo)
);


-- ─────────────────────────── Oposiciones (base) ─────────────────────────────
-- El bloque de contenido (temas/módulos/secciones) lo cuelga de aquí; se
-- añade en fase posterior. Definimos ya la tabla y su M:N con usuarios
-- para poder seed y para que las tablas de contenido de la fase 3 tengan
-- a qué referenciar sin tocar este bloque.
CREATE TABLE oposiciones (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre       text        NOT NULL,
    -- lower(nombre) UNIQUE para evitar duplicados con distinta capitalización.
    nombre_lower text        GENERATED ALWAYS AS (lower(nombre)) STORED UNIQUE,
    descripcion  text,
    activa       boolean     NOT NULL DEFAULT true,
    creado_en    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE usuario_oposiciones (
    usuario_id   uuid REFERENCES usuarios(id)   ON DELETE CASCADE,
    oposicion_id uuid REFERENCES oposiciones(id) ON DELETE CASCADE,
    asignada_en  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (usuario_id, oposicion_id)
);


-- =============================================================================
--                             ROLES POSTGRES Y GRANTS
-- =============================================================================
-- Un único rol de conexión ('autenticador') usado por PostgREST; la identidad
-- llega por JWT (claim 'sub'). Los roles funcionales de la app (admin,
-- editor, tests, teoria) viven en la tabla 'roles', NO como roles Postgres.
--
-- Los roles son a nivel de CLÚSTER (no de BD), así que ya pueden existir
-- si otra BD del mismo Postgres los creó antes (p.ej. main → aprentix
-- crea web_anon/web_user/autenticador; al bootstrapear aprentix_desa esos
-- roles ya están). Usamos bloques DO idempotentes para no reventar.

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'web_anon') THEN
        CREATE ROLE web_anon NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'web_user') THEN
        CREATE ROLE web_user NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'autenticador') THEN
        CREATE ROLE autenticador LOGIN;
    END IF;
END $$;

GRANT web_anon, web_user TO autenticador;   -- GRANT es idempotente en Postgres.

-- La contraseña real de 'autenticador' se fija más abajo desde app.auth_pass.

GRANT USAGE ON SCHEMA public TO web_anon, web_user;

-- Tablas RBAC: lectura pública (las políticas RLS las usan vía tiene_permiso()).
GRANT SELECT ON rol_permisos, roles, permisos TO web_anon, web_user;

-- Usuarios: cada uno se ve a sí mismo; UPDATE lo damos para que las RPCs
-- SECURITY DEFINER dejen al usuario cambiar su nombre_visible / password.
GRANT SELECT, UPDATE ON usuarios TO web_user;

-- Sesiones: la SPA las lee para mostrar "sesiones activas" y las revoca
-- desde RPC (`logout`, `logout_global`, `revocar_sesion`). El INSERT lo
-- hace la RPC `login`, con SECURITY DEFINER, así que no hace falta grant.
GRANT SELECT, DELETE, UPDATE ON sesiones TO web_user;

-- Tokens de verificación: nunca se acceden desde la SPA directamente. Todas
-- las operaciones pasan por RPCs SECURITY DEFINER. No damos grant.

-- Preferencias, gamificación y push: propiedad del usuario, RLS los ciñe.
GRANT SELECT, INSERT, UPDATE, DELETE
    ON preferencias_usuario, retos_usuario, logros_usuario, usuario_gamificacion
    TO web_user;
GRANT SELECT ON retos_catalogo, logros_catalogo TO web_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON push_suscripciones TO web_user;

-- Cola de embeddings: los triggers de encolado son SECURITY DEFINER pero
-- damos INSERT/SELECT también como defensa en profundidad.
GRANT INSERT, SELECT ON cola_embeddings TO web_user;

-- Config: lectura para todos, escritura sólo admin (RLS lo refuerza).
GRANT SELECT ON config TO web_user, web_anon;
GRANT INSERT, UPDATE, DELETE ON config TO web_user;

-- Oposiciones y M:N: lectura para autenticados; escritura de la M:N desde
-- RPCs admin.
GRANT SELECT ON oposiciones TO web_user;
GRANT SELECT, INSERT, DELETE ON usuario_oposiciones TO web_user;

-- Secuencias generadas (bigserial, serial…).
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO web_user;


-- =============================================================================
--                                    RLS
-- =============================================================================

ALTER TABLE usuarios              ENABLE ROW LEVEL SECURITY;
ALTER TABLE sesiones              ENABLE ROW LEVEL SECURITY;
ALTER TABLE tokens_verificacion   ENABLE ROW LEVEL SECURITY;
ALTER TABLE config                ENABLE ROW LEVEL SECURITY;
ALTER TABLE preferencias_usuario  ENABLE ROW LEVEL SECURITY;
ALTER TABLE retos_catalogo        ENABLE ROW LEVEL SECURITY;
ALTER TABLE logros_catalogo       ENABLE ROW LEVEL SECURITY;
ALTER TABLE retos_usuario         ENABLE ROW LEVEL SECURITY;
ALTER TABLE logros_usuario        ENABLE ROW LEVEL SECURITY;
ALTER TABLE usuario_gamificacion  ENABLE ROW LEVEL SECURITY;
ALTER TABLE push_suscripciones    ENABLE ROW LEVEL SECURITY;
ALTER TABLE push_envios           ENABLE ROW LEVEL SECURITY;
ALTER TABLE oposiciones           ENABLE ROW LEVEL SECURITY;
ALTER TABLE usuario_oposiciones   ENABLE ROW LEVEL SECURITY;

-- Las políticas usan jwt_usuario_id(), tiene_permiso() y es_admin(), que se
-- definen a continuación.


-- =============================================================================
--                    HELPERS DE JWT, RBAC Y FIRMA DE TOKENS
-- =============================================================================
-- Firma JWT HS256 en SQL puro sobre pgcrypto (compatible con la verificación
-- de PostgREST); no necesitamos la extensión externa pgjwt.

CREATE OR REPLACE FUNCTION url_b64(data bytea) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    -- Base64url: `+/` → `-_`, se quita padding `=` y saltos de línea.
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

-- Usuarios: cada uno se ve a sí mismo; admin ve a todos. UPDATE sólo por
-- sí mismo o admin — las RPCs cambiantes son SECURITY DEFINER pero como
-- refuerzo mantenemos la política.
CREATE POLICY usr_self       ON usuarios FOR SELECT
    USING (id = jwt_usuario_id() OR es_admin());
CREATE POLICY usr_self_upd   ON usuarios FOR UPDATE
    USING (id = jwt_usuario_id() OR es_admin())
    WITH CHECK (id = jwt_usuario_id() OR es_admin());
CREATE POLICY usr_admin_all  ON usuarios FOR ALL TO web_user
    USING (es_admin()) WITH CHECK (es_admin());

-- Sesiones: cada usuario ve/revoca las suyas; admin ve/revoca todas.
CREATE POLICY sesiones_propias ON sesiones
    FOR ALL TO web_user
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id() OR es_admin());

-- Tokens de verificación: la SPA NO los toca directamente (todas las
-- operaciones pasan por RPCs SECURITY DEFINER). Política restrictiva.
CREATE POLICY tokens_ver_admin ON tokens_verificacion
    FOR ALL TO web_user
    USING (es_admin()) WITH CHECK (es_admin());

-- Config: lectura para cualquiera, escritura sólo admin.
CREATE POLICY config_lectura ON config FOR SELECT USING (true);
CREATE POLICY config_admin   ON config FOR ALL TO web_user
    USING (es_admin()) WITH CHECK (es_admin());

CREATE POLICY pref_usuario_propio ON preferencias_usuario
    FOR ALL TO web_user
    USING (usuario_id = jwt_usuario_id())
    WITH CHECK (usuario_id = jwt_usuario_id());

-- Gamificación: catálogos de lectura pública para autenticados; progreso
-- del propio usuario R/W.
CREATE POLICY retos_cat_lectura ON retos_catalogo FOR SELECT
    USING (jwt_usuario_id() IS NOT NULL);
CREATE POLICY retos_cat_admin ON retos_catalogo FOR ALL TO web_user
    USING (es_admin()) WITH CHECK (es_admin());

CREATE POLICY logros_cat_lectura ON logros_catalogo FOR SELECT
    USING (jwt_usuario_id() IS NOT NULL);
CREATE POLICY logros_cat_admin ON logros_catalogo FOR ALL TO web_user
    USING (es_admin()) WITH CHECK (es_admin());

CREATE POLICY retos_usr_propios ON retos_usuario
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());

CREATE POLICY logros_usr_propios ON logros_usuario
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());

CREATE POLICY gamif_propia ON usuario_gamificacion
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());

-- Push: el usuario ve/modifica sólo sus dispositivos.
CREATE POLICY push_sus_propias ON push_suscripciones
    FOR ALL TO web_user
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());

-- push_envios queda cerrado a la SPA: sólo admin puede leerlo desde el
-- cliente (útil para debug); el worker usa el rol aprentix con bypass RLS.
CREATE POLICY push_env_admin ON push_envios FOR ALL TO web_user
    USING (es_admin()) WITH CHECK (es_admin());

-- Oposiciones: lectura para autenticados; escritura sólo admin.
CREATE POLICY oposiciones_lectura ON oposiciones FOR SELECT
    USING (jwt_usuario_id() IS NOT NULL);
CREATE POLICY oposiciones_admin ON oposiciones FOR ALL TO web_user
    USING (es_admin()) WITH CHECK (es_admin());

CREATE POLICY uop_propias ON usuario_oposiciones
    FOR ALL TO web_user
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id() OR es_admin());


-- =============================================================================
--                        DEFAULTS DEPENDIENTES DE JWT
-- =============================================================================
-- Los INSERTs desde la SPA no necesitan enviar usuario_id: la BBDD lo
-- deriva del claim `sub` del JWT.

ALTER TABLE preferencias_usuario ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE retos_usuario        ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE logros_usuario       ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE usuario_gamificacion ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE push_suscripciones   ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE usuario_oposiciones  ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();


-- =============================================================================
--            HELPERS DE HASH DE CONTRASEÑA (abstraen bcrypt)
-- =============================================================================
-- Envolvemos el hasher para poder migrar a Argon2id (extensión pg_argon2)
-- sin tocar cada RPC. bcrypt cost 12 hoy; futura migración se limita a
-- reemplazar este par de funciones.

CREATE OR REPLACE FUNCTION _hash_password(p_password text) RETURNS text
LANGUAGE sql VOLATILE AS $$
    -- VOLATILE porque gen_salt() usa aleatoriedad; el hash de una misma
    -- contraseña es distinto en cada invocación (que es lo que queremos).
    SELECT crypt(p_password, gen_salt('bf', 12));
$$;

CREATE OR REPLACE FUNCTION _verify_password(p_password text, p_hash text) RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT crypt(p_password, p_hash) = p_hash;
$$;


-- =============================================================================
--                             SEED DE DATOS BASE
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
-- Los mismos cuatro roles del sistema anterior: 'admin' sigue mandando,
-- 'editor' crea/edita contenido, 'tests' hace tests, 'teoria' lee teoría.
-- 'tests' y 'teoria' son ortogonales: un usuario puede tener uno, otro o
-- ambos.
INSERT INTO roles (id, descripcion) VALUES
    ('admin',  'Acceso total al sistema'),
    ('editor', 'Puede crear y editar contenido (temas, módulos, secciones, preguntas y teoría)'),
    ('tests',  'Puede realizar tests de las oposiciones asignadas'),
    ('teoria', 'Puede acceder al material de teoría')
ON CONFLICT (id) DO NOTHING;


-- ── Permisos y su mapeo a roles ─────────────────────────────────────────────
-- Permisos granulares para el nuevo modelo. Los de contenido pedagógico
-- (`seccion.*`, `tema.*`) se rellenan cuando la fase 3 añada sus tablas;
-- este seed los deja ya listos para que 'editor' los tenga desde el arranque.
INSERT INTO permisos (id, descripcion) VALUES
    -- Contenido pedagógico (aplica a temas, módulos y secciones)
    ('contenido.crear',        'Crear temas, módulos, secciones y documentos de teoría'),
    ('contenido.editar',       'Editar temas, módulos, secciones y documentos'),
    ('contenido.borrar',       'Eliminar temas, módulos, secciones y documentos'),
    -- Preguntas
    ('pregunta.crear',         'Crear preguntas'),
    ('pregunta.editar',        'Editar preguntas existentes'),
    ('pregunta.borrar',        'Eliminar preguntas'),
    ('pregunta.fusionar',      'Fusionar duplicados detectados por el worker'),
    -- Realización de tests y acceso a teoría (asignados a los roles homónimos)
    ('test.realizar',          'Realizar tests y registrar respuestas'),
    ('teoria.acceder',         'Ver ficheros de teoría'),
    ('teoria.gestionar',       'Subir, mover, editar y borrar ficheros de teoría'),
    -- Oposiciones
    ('oposicion.gestionar',    'Crear, editar y borrar oposiciones y su asignación de temas'),
    -- Gestión de usuarios (granulares — el viejo `usuario.gestionar` se retira)
    ('usuarios.leer',          'Ver el listado de usuarios y su ficha'),
    ('usuarios.gestionar_roles', 'Asignar y quitar roles a otros usuarios'),
    ('usuarios.forzar_reset',  'Enviar reset de contraseña a otro usuario'),
    ('usuarios.borrar',        'Borrar cuentas de otros usuarios'),
    -- Backups
    ('backup.descargar',       'Descargar copias de seguridad de la base de datos')
ON CONFLICT (id) DO NOTHING;

-- 'admin' hereda TODOS los permisos automáticamente.
INSERT INTO rol_permisos (rol_id, permiso_id)
SELECT 'admin', id FROM permisos
ON CONFLICT DO NOTHING;

-- 'editor' cubre contenido y preguntas; también puede realizar tests.
INSERT INTO rol_permisos (rol_id, permiso_id) VALUES
    ('editor', 'contenido.crear'),
    ('editor', 'contenido.editar'),
    ('editor', 'contenido.borrar'),
    ('editor', 'pregunta.crear'),
    ('editor', 'pregunta.editar'),
    ('editor', 'pregunta.borrar'),
    ('editor', 'pregunta.fusionar'),
    ('editor', 'test.realizar'),
    ('editor', 'teoria.acceder'),
    ('editor', 'teoria.gestionar'),
    ('tests',  'test.realizar'),
    ('teoria', 'teoria.acceder')
ON CONFLICT DO NOTHING;


-- ── Usuario administrador inicial (lee GUC app.admin_pass) ──────────────────
-- Se crea con email admin@aprentix.local ya marcado como verificado para que
-- el arranque no dependa del mailer. Cámbialo en cuanto tengas SMTP listo
-- desde la vista "Mi cuenta".
DO $$
DECLARE
    v_id    uuid;
    v_pass  text := current_setting('app.admin_pass', true);
BEGIN
    IF v_pass IS NULL OR length(v_pass) < 10 THEN
        RAISE EXCEPTION 'app.admin_pass no definida o < 10 caracteres';
    END IF;
    INSERT INTO usuarios (email, nombre_visible, password_hash,
                          email_verificado_en, creado_en)
    VALUES ('admin@aprentix.local', 'admin', _hash_password(v_pass),
            now(), now())
    ON CONFLICT (email) DO NOTHING
    RETURNING id INTO v_id;
    IF v_id IS NULL THEN
        SELECT id INTO v_id FROM usuarios WHERE email = 'admin@aprentix.local';
    END IF;
    INSERT INTO usuario_roles (usuario_id, rol_id)
    VALUES (v_id, 'admin'), (v_id, 'editor'), (v_id, 'tests'), (v_id, 'teoria')
    ON CONFLICT DO NOTHING;
END $$;


-- ── Config semilla ──────────────────────────────────────────────────────────
-- Valores por defecto que la SPA y el mailer pueden leer sin más.
INSERT INTO config (clave, valor) VALUES
    -- Duración del access token (segundos). Cambiar aquí; login/refresh lo leen.
    ('access_token_ttl_s',        to_jsonb(900)),        -- 15 min
    ('refresh_token_ttl_s',       to_jsonb(1209600)),    -- 14 días
    -- Umbral y ventana del lockout tras intentos fallidos.
    ('login_max_fallos',          to_jsonb(5)),
    ('login_lockout_min',         to_jsonb(15)),
    -- Política de contraseñas mínima aplicada server-side.
    ('password_min_len',          to_jsonb(10)),
    ('password_min_categorias',   to_jsonb(3)),
    ('password_relax_len',        to_jsonb(14)),         -- si ≥ esto no exigimos categorías
    -- Datos identificativos del emisor JWT (van en `iss`/`aud` del token).
    ('jwt_iss',                   '"aprentix"'::jsonb),
    ('jwt_aud',                   '"aprentix.web"'::jsonb),
    -- Rutas donde el mailer construye enlaces (verificación / reset).
    ('web_url_base',              '"https://aprentix.es"'::jsonb),
    -- Ventana horaria válida para envíos push (Europe/Madrid).
    ('push_ventana_ini',          to_jsonb(9)),
    ('push_ventana_fin',          to_jsonb(22))
ON CONFLICT (clave) DO NOTHING;

-- =============================================================================
--                          BLOQUE A2 — RPCs DE AUTH
-- =============================================================================
-- Toda la lógica de auth vive en RPCs SECURITY DEFINER con
-- `SET search_path = public, pg_temp` para blindar contra hijacking. La SPA
-- las invoca por PostgREST; el rol web_anon puede llamar sólo a las que
-- necesitan estar abiertas sin sesión (`registrar`, `verificar_email`,
-- `login`, `refresh`, `solicitar_reset_password`, `resetear_password`).
-- Los detalles funcionales del bloque auth están en el plan del rediseño.


-- ── Utilidades internas ─────────────────────────────────────────────────────

-- Genera un token opaco de 32 bytes en base64url. Se usa como refresh token
-- y como token de verificación/reset (el hash sha256 es lo que se guarda).
CREATE OR REPLACE FUNCTION _random_token() RETURNS text
LANGUAGE sql VOLATILE AS $$
    SELECT translate(encode(gen_random_bytes(32), 'base64'), E'+/=\n', '-_');
$$;

CREATE OR REPLACE FUNCTION _sha256_hex(p text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT encode(digest(p, 'sha256'), 'hex');
$$;

-- Política de contraseñas server-side. Tira excepción con código estable
-- (`password_debil`) para que la SPA lo pueda internacionalizar.
CREATE OR REPLACE FUNCTION _validar_password(p_password text) RETURNS void
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_min_len       int := (SELECT (valor)::text::int FROM config WHERE clave='password_min_len');
    v_min_cats      int := (SELECT (valor)::text::int FROM config WHERE clave='password_min_categorias');
    v_relax_len     int := (SELECT (valor)::text::int FROM config WHERE clave='password_relax_len');
    v_len           int;
    v_cats          int := 0;
BEGIN
    IF p_password IS NULL THEN
        RAISE EXCEPTION 'password_debil' USING DETAIL = 'contraseña vacía';
    END IF;
    v_len := char_length(p_password);
    IF v_len < COALESCE(v_min_len, 10) THEN
        RAISE EXCEPTION 'password_debil' USING DETAIL = 'longitud mínima no cumplida';
    END IF;
    -- Si la contraseña es "larga" (>= v_relax_len) NO exigimos categorías.
    IF v_len < COALESCE(v_relax_len, 14) THEN
        IF p_password ~ '[a-z]' THEN v_cats := v_cats + 1; END IF;
        IF p_password ~ '[A-Z]' THEN v_cats := v_cats + 1; END IF;
        IF p_password ~ '[0-9]' THEN v_cats := v_cats + 1; END IF;
        IF p_password ~ '[^A-Za-z0-9]' THEN v_cats := v_cats + 1; END IF;
        IF v_cats < COALESCE(v_min_cats, 3) THEN
            RAISE EXCEPTION 'password_debil'
                USING DETAIL = format('categorías: %s de %s requeridas',
                                      v_cats, COALESCE(v_min_cats, 3));
        END IF;
    END IF;
END $$;

-- Notifica al servicio mailer/ para enviar un email. El mailer escucha
-- `LISTEN email_enviar` y recibe el JSON del payload como notificación.
-- El TOKEN PLANO viaja aquí (una sola vez); la BD sólo guarda su sha256.
CREATE OR REPLACE FUNCTION _emitir_email(
    p_usuario_id uuid,
    p_tipo       text,
    p_token      text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_email text;
    v_nom   text;
    v_base  text;
BEGIN
    SELECT email, nombre_visible INTO v_email, v_nom
      FROM usuarios WHERE id = p_usuario_id;
    IF v_email IS NULL THEN RETURN; END IF;
    SELECT valor::text INTO v_base FROM config WHERE clave='web_url_base';
    PERFORM pg_notify('email_enviar', jsonb_build_object(
        'usuario_id',     p_usuario_id,
        'tipo',           p_tipo,
        'email',          v_email::text,
        'nombre_visible', v_nom,
        'token',          p_token,
        'web_url_base',   trim(both '"' from COALESCE(v_base, '""'))
    )::text);
END $$;

-- Construye y firma un access token JWT. Devuelve (jti, access, exp_ts).
CREATE OR REPLACE FUNCTION _emit_access(p_usuario_id uuid)
RETURNS TABLE (jti uuid, access text, expira_en timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_secret text := current_setting('app.jwt_secret');
    v_ttl_s  int  := (SELECT (valor)::text::int FROM config WHERE clave='access_token_ttl_s');
    v_iss    text := trim(both '"' from (SELECT valor::text FROM config WHERE clave='jwt_iss'));
    v_aud    text := trim(both '"' from (SELECT valor::text FROM config WHERE clave='jwt_aud'));
    v_roles  text[];
    v_email_ok bool;
    v_now    timestamptz := now();
    v_exp    timestamptz;
    v_jti    uuid := gen_random_uuid();
    v_payload jsonb;
BEGIN
    v_exp := v_now + make_interval(secs => COALESCE(v_ttl_s, 900));
    SELECT COALESCE(array_agg(rol_id ORDER BY rol_id), ARRAY[]::text[])
      INTO v_roles FROM usuario_roles WHERE usuario_id = p_usuario_id;
    SELECT (email_verificado_en IS NOT NULL) INTO v_email_ok
      FROM usuarios WHERE id = p_usuario_id;
    v_payload := jsonb_build_object(
        'sub',              p_usuario_id::text,
        'role',             'web_user',           -- rol Postgres (fijo)
        'roles',            to_jsonb(v_roles),    -- roles funcionales
        'email_verificado', COALESCE(v_email_ok, false),
        'iat',              extract(epoch FROM v_now)::int,
        'exp',              extract(epoch FROM v_exp)::int,
        'jti',              v_jti::text,
        'iss',              v_iss,
        'aud',              v_aud
    );
    RETURN QUERY SELECT v_jti, firmar_jwt(v_payload, v_secret), v_exp;
END $$;


-- ── Registro y verificación de email ────────────────────────────────────────

CREATE OR REPLACE FUNCTION registrar(
    p_email          text,
    p_password       text,
    p_nombre_visible text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_id    uuid;
    v_tok   text := _random_token();
BEGIN
    IF p_email IS NULL OR position('@' in p_email) < 2 THEN
        RAISE EXCEPTION 'email_invalido';
    END IF;
    IF p_nombre_visible IS NULL OR length(btrim(p_nombre_visible)) < 2 THEN
        RAISE EXCEPTION 'nombre_visible_invalido';
    END IF;
    PERFORM _validar_password(p_password);

    INSERT INTO usuarios (email, nombre_visible, password_hash)
    VALUES (p_email, btrim(p_nombre_visible), _hash_password(p_password))
    RETURNING id INTO v_id;

    -- Roles por defecto: `tests` + `teoria` (acceso básico). Ajusta al gusto.
    INSERT INTO usuario_roles (usuario_id, rol_id) VALUES
        (v_id, 'tests'), (v_id, 'teoria')
    ON CONFLICT DO NOTHING;

    INSERT INTO tokens_verificacion (usuario_id, tipo, token_hash, expira_en)
    VALUES (v_id, 'verificar_email', _sha256_hex(v_tok), now() + interval '30 minutes');

    PERFORM _emitir_email(v_id, 'verificar_email', v_tok);
    RETURN jsonb_build_object('ok', true, 'mensaje', 'Revisa tu correo para verificar la cuenta.');
EXCEPTION WHEN unique_violation THEN
    -- No filtramos si el email ya existe: mismo mensaje que en OK.
    RETURN jsonb_build_object('ok', true, 'mensaje', 'Revisa tu correo para verificar la cuenta.');
END $$;

CREATE OR REPLACE FUNCTION verificar_email(p_token text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_row tokens_verificacion%ROWTYPE;
BEGIN
    SELECT * INTO v_row FROM tokens_verificacion
      WHERE token_hash = _sha256_hex(p_token)
        AND tipo = 'verificar_email'
        AND usado_en IS NULL
        AND expira_en > now();
    IF NOT FOUND THEN
        RAISE EXCEPTION 'token_invalido';
    END IF;
    UPDATE tokens_verificacion SET usado_en = now() WHERE id = v_row.id;
    UPDATE usuarios
       SET email_verificado_en = COALESCE(email_verificado_en, now()),
           actualizado_en      = now()
     WHERE id = v_row.usuario_id;
    RETURN jsonb_build_object('ok', true);
END $$;


-- ── Login, refresh y logout ────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION login(
    p_email    text,
    p_password text,
    p_totp     text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_user     usuarios%ROWTYPE;
    v_max      int := (SELECT (valor)::text::int FROM config WHERE clave='login_max_fallos');
    v_lock_min int := (SELECT (valor)::text::int FROM config WHERE clave='login_lockout_min');
    v_ref_ttl  int := (SELECT (valor)::text::int FROM config WHERE clave='refresh_token_ttl_s');
    v_refresh  text := _random_token();
    v_jti      uuid;
    v_access   text;
    v_exp      timestamptz;
    v_ref_exp  timestamptz;
BEGIN
    SELECT * INTO v_user FROM usuarios WHERE email = p_email AND borrado_en IS NULL;
    IF NOT FOUND OR NOT v_user.activo THEN
        RAISE EXCEPTION 'credenciales_invalidas';
    END IF;
    IF v_user.bloqueado_hasta IS NOT NULL AND v_user.bloqueado_hasta > now() THEN
        RAISE EXCEPTION 'cuenta_bloqueada';
    END IF;
    IF NOT _verify_password(p_password, v_user.password_hash) THEN
        UPDATE usuarios
           SET intentos_login_fallidos = intentos_login_fallidos + 1,
               bloqueado_hasta = CASE
                   WHEN intentos_login_fallidos + 1 >= COALESCE(v_max, 5)
                        THEN now() + make_interval(mins => COALESCE(v_lock_min, 15))
                   ELSE bloqueado_hasta
               END,
               actualizado_en = now()
         WHERE id = v_user.id;
        RAISE EXCEPTION 'credenciales_invalidas';
    END IF;
    IF v_user.totp_activo THEN
        IF p_totp IS NULL OR length(p_totp) = 0 THEN
            RAISE EXCEPTION 'totp_requerido';
        END IF;
        -- Verificación TOTP: se delega a la RPC pública `verificar_totp`
        -- para poder testear el algoritmo aislado. Ver TODO abajo.
        IF NOT _verificar_totp(v_user.totp_secret, p_totp) THEN
            RAISE EXCEPTION 'totp_invalido';
        END IF;
    END IF;
    IF v_user.email_verificado_en IS NULL THEN
        RAISE EXCEPTION 'email_no_verificado';
    END IF;

    -- Éxito: emite access + refresh, y persiste la sesión.
    SELECT * INTO v_jti, v_access, v_exp FROM _emit_access(v_user.id);
    v_ref_exp := now() + make_interval(secs => COALESCE(v_ref_ttl, 1209600));
    INSERT INTO sesiones (jti, usuario_id, refresh_hash, expira_en)
    VALUES (v_jti, v_user.id, _sha256_hex(v_refresh), v_ref_exp);

    UPDATE usuarios
       SET intentos_login_fallidos = 0,
           bloqueado_hasta         = NULL,
           ultimo_login_en         = now(),
           actualizado_en          = now()
     WHERE id = v_user.id;

    RETURN jsonb_build_object(
        'ok',            true,
        'access_token',  v_access,
        'access_exp',    extract(epoch FROM v_exp)::int,
        'refresh_token', v_refresh,
        'refresh_exp',   extract(epoch FROM v_ref_exp)::int
    );
END $$;

CREATE OR REPLACE FUNCTION refresh(p_refresh text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_sesion   sesiones%ROWTYPE;
    v_ref_ttl  int := (SELECT (valor)::text::int FROM config WHERE clave='refresh_token_ttl_s');
    v_new_ref  text := _random_token();
    v_jti      uuid;
    v_access   text;
    v_exp      timestamptz;
    v_ref_exp  timestamptz;
BEGIN
    SELECT * INTO v_sesion FROM sesiones
      WHERE refresh_hash = _sha256_hex(p_refresh);
    IF NOT FOUND THEN
        RAISE EXCEPTION 'refresh_invalido';
    END IF;
    IF v_sesion.revocada_en IS NOT NULL OR v_sesion.expira_en <= now() THEN
        -- Indicio de robo: revoca TODAS las sesiones del usuario.
        UPDATE sesiones SET revocada_en = COALESCE(revocada_en, now())
         WHERE usuario_id = v_sesion.usuario_id AND revocada_en IS NULL;
        RAISE EXCEPTION 'refresh_invalido';
    END IF;

    -- Rota el refresh: revoca el viejo, emite uno nuevo con jti nuevo.
    UPDATE sesiones SET revocada_en = now() WHERE jti = v_sesion.jti;
    SELECT * INTO v_jti, v_access, v_exp FROM _emit_access(v_sesion.usuario_id);
    v_ref_exp := now() + make_interval(secs => COALESCE(v_ref_ttl, 1209600));
    INSERT INTO sesiones (jti, usuario_id, refresh_hash, expira_en)
    VALUES (v_jti, v_sesion.usuario_id, _sha256_hex(v_new_ref), v_ref_exp);

    RETURN jsonb_build_object(
        'ok',            true,
        'access_token',  v_access,
        'access_exp',    extract(epoch FROM v_exp)::int,
        'refresh_token', v_new_ref,
        'refresh_exp',   extract(epoch FROM v_ref_exp)::int
    );
END $$;

CREATE OR REPLACE FUNCTION logout(p_refresh text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    UPDATE sesiones SET revocada_en = COALESCE(revocada_en, now())
     WHERE refresh_hash = _sha256_hex(p_refresh);
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION logout_global() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF jwt_usuario_id() IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    UPDATE sesiones SET revocada_en = COALESCE(revocada_en, now())
     WHERE usuario_id = jwt_usuario_id() AND revocada_en IS NULL;
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION revocar_sesion(p_jti uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF jwt_usuario_id() IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    UPDATE sesiones SET revocada_en = COALESCE(revocada_en, now())
     WHERE jti = p_jti
       AND (usuario_id = jwt_usuario_id() OR es_admin());
    RETURN jsonb_build_object('ok', true);
END $$;

-- Cambio de contraseña por el propio usuario. Revoca todas las sesiones
-- EXCEPTO la actual (identificada por el jti del access token).
CREATE OR REPLACE FUNCTION cambiar_password(p_actual text, p_nueva text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid  uuid := jwt_usuario_id();
    v_jti  uuid := NULLIF(current_setting('request.jwt.claims', true)::jsonb->>'jti', '')::uuid;
    v_hash text;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    SELECT password_hash INTO v_hash FROM usuarios WHERE id = v_uid;
    IF NOT _verify_password(p_actual, v_hash) THEN
        RAISE EXCEPTION 'credenciales_invalidas';
    END IF;
    PERFORM _validar_password(p_nueva);
    UPDATE usuarios
       SET password_hash = _hash_password(p_nueva),
           password_actualizado_en = now(),
           actualizado_en = now()
     WHERE id = v_uid;
    UPDATE sesiones SET revocada_en = COALESCE(revocada_en, now())
     WHERE usuario_id = v_uid AND revocada_en IS NULL AND jti <> COALESCE(v_jti, '00000000-0000-0000-0000-000000000000'::uuid);
    RETURN jsonb_build_object('ok', true);
END $$;


-- ── Reset de contraseña (olvidé mi contraseña) ─────────────────────────────

CREATE OR REPLACE FUNCTION solicitar_reset_password(p_email text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_id  uuid;
    v_tok text := _random_token();
BEGIN
    SELECT id INTO v_id FROM usuarios
      WHERE email = p_email AND activo AND borrado_en IS NULL;
    IF v_id IS NOT NULL THEN
        INSERT INTO tokens_verificacion (usuario_id, tipo, token_hash, expira_en)
        VALUES (v_id, 'reset_password', _sha256_hex(v_tok), now() + interval '30 minutes');
        PERFORM _emitir_email(v_id, 'reset_password', v_tok);
    END IF;
    -- Respuesta uniforme (no filtra si el email existe).
    RETURN jsonb_build_object('ok', true, 'mensaje', 'Si el email existe, recibirás un correo con instrucciones.');
END $$;

CREATE OR REPLACE FUNCTION resetear_password(p_token text, p_nueva text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_row tokens_verificacion%ROWTYPE;
BEGIN
    SELECT * INTO v_row FROM tokens_verificacion
      WHERE token_hash = _sha256_hex(p_token)
        AND tipo = 'reset_password'
        AND usado_en IS NULL
        AND expira_en > now();
    IF NOT FOUND THEN RAISE EXCEPTION 'token_invalido'; END IF;
    PERFORM _validar_password(p_nueva);
    UPDATE tokens_verificacion SET usado_en = now() WHERE id = v_row.id;
    UPDATE usuarios
       SET password_hash = _hash_password(p_nueva),
           password_actualizado_en = now(),
           intentos_login_fallidos = 0,
           bloqueado_hasta = NULL,
           actualizado_en = now()
     WHERE id = v_row.usuario_id;
    UPDATE sesiones SET revocada_en = COALESCE(revocada_en, now())
     WHERE usuario_id = v_row.usuario_id AND revocada_en IS NULL;
    RETURN jsonb_build_object('ok', true);
END $$;


-- ── 2FA TOTP (stub — algoritmo pendiente) ───────────────────────────────────
-- Las columnas `totp_secret` / `totp_activo` en usuarios están listas. El
-- algoritmo TOTP (RFC 6238) se implementará en la fase 2.1 cuando encajemos
-- el flujo de la SPA. Por ahora `_verificar_totp` devuelve false y las RPCs
-- de activación tiran `no_implementado` para no dejar la puerta a medias.
CREATE OR REPLACE FUNCTION _verificar_totp(p_secret bytea, p_code text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$ SELECT false $$;

CREATE OR REPLACE FUNCTION activar_2fa()      RETURNS jsonb
LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'no_implementado'; END $$;
CREATE OR REPLACE FUNCTION confirmar_2fa(text) RETURNS jsonb
LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'no_implementado'; END $$;
CREATE OR REPLACE FUNCTION desactivar_2fa(text, text) RETURNS jsonb
LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'no_implementado'; END $$;


-- ── Autoservicio de cuenta ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION mi_cuenta() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_row usuarios%ROWTYPE;
    v_roles text[];
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    SELECT * INTO v_row FROM usuarios WHERE id = v_uid;
    SELECT COALESCE(array_agg(rol_id ORDER BY rol_id), ARRAY[]::text[])
      INTO v_roles FROM usuario_roles WHERE usuario_id = v_uid;
    RETURN jsonb_build_object(
        'id',                v_row.id,
        'email',             v_row.email::text,
        'nombre_visible',    v_row.nombre_visible,
        'email_verificado',  v_row.email_verificado_en IS NOT NULL,
        'totp_activo',       v_row.totp_activo,
        'roles',             to_jsonb(v_roles),
        'ultimo_login_en',   v_row.ultimo_login_en,
        'creado_en',         v_row.creado_en
    );
END $$;

CREATE OR REPLACE FUNCTION mis_sesiones() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_jti uuid := NULLIF(current_setting('request.jwt.claims', true)::jsonb->>'jti', '')::uuid;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'jti',         s.jti,
            'emitida_en',  s.emitida_en,
            'expira_en',   s.expira_en,
            'actual',      (s.jti = v_jti)
        ) ORDER BY s.emitida_en DESC)
        FROM sesiones s
        WHERE s.usuario_id = v_uid AND s.revocada_en IS NULL
    ), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION borrar_mi_cuenta(p_password text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid  uuid := jwt_usuario_id();
    v_hash text;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    SELECT password_hash INTO v_hash FROM usuarios WHERE id = v_uid;
    IF NOT _verify_password(p_password, v_hash) THEN
        RAISE EXCEPTION 'credenciales_invalidas';
    END IF;
    -- Soft-delete: anonimiza email/nombre y marca borrado_en. Un cron
    -- mensual purga las filas con `borrado_en < now() - 30 días`.
    UPDATE usuarios
       SET email               = ('borrado+' || v_uid || '@aprentix.local')::citext,
           nombre_visible      = 'Cuenta borrada',
           password_hash       = _hash_password(_random_token()),  -- imposible de usar
           activo              = false,
           totp_secret         = NULL,
           totp_activo         = false,
           borrado_en          = now(),
           actualizado_en      = now()
     WHERE id = v_uid;
    UPDATE sesiones SET revocada_en = COALESCE(revocada_en, now())
     WHERE usuario_id = v_uid AND revocada_en IS NULL;
    RETURN jsonb_build_object('ok', true);
END $$;


-- ── Administración de usuarios ─────────────────────────────────────────────

CREATE OR REPLACE FUNCTION listar_usuarios(
    p_q     text DEFAULT NULL,
    p_page  int  DEFAULT 1,
    p_size  int  DEFAULT 20
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_off int := GREATEST(p_page - 1, 0) * p_size;
    v_total int;
    v_rows jsonb;
BEGIN
    IF NOT (es_admin() OR tiene_permiso('usuarios.leer')) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;

    WITH base AS (
        SELECT u.*
          FROM usuarios u
         WHERE u.borrado_en IS NULL
           AND (p_q IS NULL OR u.email::text ILIKE '%'||p_q||'%'
                             OR u.nombre_visible ILIKE '%'||p_q||'%')
    )
    SELECT count(*) INTO v_total FROM base;

    WITH base AS (
        SELECT u.*
          FROM usuarios u
         WHERE u.borrado_en IS NULL
           AND (p_q IS NULL OR u.email::text ILIKE '%'||p_q||'%'
                             OR u.nombre_visible ILIKE '%'||p_q||'%')
         ORDER BY u.creado_en DESC
         LIMIT p_size OFFSET v_off
    )
    SELECT jsonb_agg(jsonb_build_object(
        'id',                u.id,
        'email',             u.email::text,
        'nombre_visible',    u.nombre_visible,
        'email_verificado',  u.email_verificado_en IS NOT NULL,
        'activo',            u.activo,
        'totp_activo',       u.totp_activo,
        'ultimo_login_en',   u.ultimo_login_en,
        'sesiones_activas',  (SELECT count(*) FROM sesiones s
                               WHERE s.usuario_id = u.id AND s.revocada_en IS NULL),
        'roles',             COALESCE(
            (SELECT array_agg(rol_id ORDER BY rol_id)
             FROM usuario_roles WHERE usuario_id = u.id),
            ARRAY[]::text[]
        )
    )) INTO v_rows FROM base u;

    RETURN jsonb_build_object(
        'usuarios',    COALESCE(v_rows, '[]'::jsonb),
        'page',        p_page,
        'page_size',   p_size,
        'total',       v_total,
        'total_pages', GREATEST(1, (v_total + p_size - 1) / p_size)
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
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT (es_admin() OR tiene_permiso('usuarios.gestionar_roles')) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    INSERT INTO usuario_roles(usuario_id, rol_id)
    VALUES (p_usuario_id, p_rol_id)
    ON CONFLICT DO NOTHING;
END $$;

CREATE OR REPLACE FUNCTION quitar_rol(p_usuario_id uuid, p_rol_id text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT (es_admin() OR tiene_permiso('usuarios.gestionar_roles')) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    IF p_rol_id = 'admin' AND (
        SELECT count(*) FROM usuario_roles WHERE rol_id = 'admin'
    ) <= 1 THEN
        RAISE EXCEPTION 'no_se_puede_quitar_el_ultimo_admin';
    END IF;
    DELETE FROM usuario_roles
     WHERE usuario_id = p_usuario_id AND rol_id = p_rol_id;
END $$;

-- El admin YA NO resetea contraseñas directamente. Envía un email de reset
-- al usuario, que decide él mismo la nueva contraseña. Menos superficie
-- para leaks y auditable por el propio usuario.
CREATE OR REPLACE FUNCTION forzar_reset_password(p_usuario_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_tok text := _random_token();
BEGIN
    IF NOT (es_admin() OR tiene_permiso('usuarios.forzar_reset')) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    INSERT INTO tokens_verificacion (usuario_id, tipo, token_hash, expira_en)
    VALUES (p_usuario_id, 'reset_password', _sha256_hex(v_tok), now() + interval '30 minutes');
    PERFORM _emitir_email(p_usuario_id, 'reset_password', v_tok);
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION forzar_logout_global(p_usuario_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT (es_admin() OR tiene_permiso('usuarios.gestionar_roles')) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    UPDATE sesiones SET revocada_en = COALESCE(revocada_en, now())
     WHERE usuario_id = p_usuario_id AND revocada_en IS NULL;
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION set_usuario_activo(p_usuario_id uuid, p_activo boolean) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT (es_admin() OR tiene_permiso('usuarios.gestionar_roles')) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    UPDATE usuarios SET activo = p_activo, actualizado_en = now()
     WHERE id = p_usuario_id;
    IF NOT p_activo THEN
        UPDATE sesiones SET revocada_en = COALESCE(revocada_en, now())
         WHERE usuario_id = p_usuario_id AND revocada_en IS NULL;
    END IF;
END $$;

CREATE OR REPLACE FUNCTION borrar_usuario_admin(p_usuario_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT (es_admin() OR tiene_permiso('usuarios.borrar')) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    IF (SELECT count(*) FROM usuario_roles
        WHERE rol_id = 'admin' AND usuario_id <> p_usuario_id) < 1 THEN
        RAISE EXCEPTION 'no_se_puede_borrar_el_ultimo_admin';
    END IF;
    UPDATE usuarios
       SET email          = ('borrado+' || p_usuario_id || '@aprentix.local')::citext,
           nombre_visible = 'Cuenta borrada',
           password_hash  = _hash_password(_random_token()),
           activo         = false,
           totp_secret    = NULL,
           totp_activo    = false,
           borrado_en     = COALESCE(borrado_en, now()),
           actualizado_en = now()
     WHERE id = p_usuario_id;
    UPDATE sesiones SET revocada_en = COALESCE(revocada_en, now())
     WHERE usuario_id = p_usuario_id AND revocada_en IS NULL;
    RETURN jsonb_build_object('ok', true);
END $$;


-- ── Config y varios ────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION leer_config() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    -- Sólo devuelve claves no sensibles. `jwt_iss/aud`, `web_url_base`,
    -- políticas de password y ventanas horarias son públicas; el JWT
    -- secret no vive aquí (está en GUC).
    SELECT COALESCE(jsonb_object_agg(clave, valor), '{}'::jsonb)
      FROM config;
$$;


-- =============================================================================
--                             GRANTS DE EXECUTE
-- =============================================================================
-- web_anon → sólo lo estrictamente necesario sin sesión.
GRANT EXECUTE ON FUNCTION registrar(text,text,text)            TO web_anon;
GRANT EXECUTE ON FUNCTION verificar_email(text)                 TO web_anon;
GRANT EXECUTE ON FUNCTION login(text,text,text)                 TO web_anon;
GRANT EXECUTE ON FUNCTION refresh(text)                         TO web_anon, web_user;
GRANT EXECUTE ON FUNCTION logout(text)                          TO web_anon, web_user;
GRANT EXECUTE ON FUNCTION solicitar_reset_password(text)        TO web_anon;
GRANT EXECUTE ON FUNCTION resetear_password(text,text)          TO web_anon;
GRANT EXECUTE ON FUNCTION leer_config()                         TO web_anon, web_user;

-- web_user → todo lo que requiere sesión.
GRANT EXECUTE ON FUNCTION logout_global()                       TO web_user;
GRANT EXECUTE ON FUNCTION revocar_sesion(uuid)                  TO web_user;
GRANT EXECUTE ON FUNCTION cambiar_password(text,text)           TO web_user;
GRANT EXECUTE ON FUNCTION mi_cuenta()                           TO web_user;
GRANT EXECUTE ON FUNCTION mis_sesiones()                        TO web_user;
GRANT EXECUTE ON FUNCTION borrar_mi_cuenta(text)                TO web_user;
GRANT EXECUTE ON FUNCTION activar_2fa()                         TO web_user;
GRANT EXECUTE ON FUNCTION confirmar_2fa(text)                   TO web_user;
GRANT EXECUTE ON FUNCTION desactivar_2fa(text,text)             TO web_user;

-- Admin (chequeado dentro de la RPC).
GRANT EXECUTE ON FUNCTION listar_usuarios(text,int,int)         TO web_user;
GRANT EXECUTE ON FUNCTION listar_roles()                        TO web_user;
GRANT EXECUTE ON FUNCTION asignar_rol(uuid,text)                TO web_user;
GRANT EXECUTE ON FUNCTION quitar_rol(uuid,text)                 TO web_user;
GRANT EXECUTE ON FUNCTION forzar_reset_password(uuid)           TO web_user;
GRANT EXECUTE ON FUNCTION forzar_logout_global(uuid)            TO web_user;
GRANT EXECUTE ON FUNCTION set_usuario_activo(uuid,boolean)      TO web_user;
GRANT EXECUTE ON FUNCTION borrar_usuario_admin(uuid)            TO web_user;


-- =============================================================================
--                    BLOQUE C — CONTENIDO PEDAGÓGICO
-- =============================================================================
-- Jerarquía Oposición → Tema → Módulo → Sección → Preguntas + Teoría.
-- Los temas se comparten entre oposiciones vía la M:N `oposicion_temas`. El
-- progreso vive por (usuario, sección): completar una sección en una
-- oposición se refleja automáticamente en cualquier otra que la incluya.


-- ─────────────────────────── Estructura curricular ─────────────────────────

CREATE TABLE temas (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    nombre       text NOT NULL,
    slug         text UNIQUE NOT NULL,        -- p.ej. 'constitucion-espanola'
    descripcion  text,
    creado_en    timestamptz NOT NULL DEFAULT now()
);

-- Un tema tiene 1..N módulos. Cuando un tema no tiene submódulos "reales"
-- se crea uno con `es_unico=true` que contiene todas las secciones — así
-- la UI puede pintarlos igual (colapsados) sin ramificar la lógica.
CREATE TABLE modulos (
    id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tema_id   uuid NOT NULL REFERENCES temas(id) ON DELETE CASCADE,
    nombre    text NOT NULL,
    orden     int  NOT NULL DEFAULT 0,
    es_unico  boolean NOT NULL DEFAULT false,
    UNIQUE (tema_id, orden)
);
CREATE INDEX modulos_tema_idx ON modulos (tema_id, orden);

CREATE TABLE secciones (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    modulo_id     uuid NOT NULL REFERENCES modulos(id) ON DELETE CASCADE,
    nombre        text NOT NULL,
    orden         int  NOT NULL DEFAULT 0,
    -- Umbral (%) para considerar la sección aprobada tras un test.
    min_aprobado  numeric NOT NULL DEFAULT 70 CHECK (min_aprobado BETWEEN 0 AND 100),
    -- Nº de preguntas del test de sección (fijo por defecto = 10).
    n_preg_test   int NOT NULL DEFAULT 10 CHECK (n_preg_test BETWEEN 1 AND 100),
    UNIQUE (modulo_id, orden)
);
CREATE INDEX secciones_modulo_idx ON secciones (modulo_id, orden);

-- M:N Oposición ↔ Tema. Es la asignación administrativa: define qué temas
-- componen cada oposición y en qué orden aparecen en el home.
CREATE TABLE oposicion_temas (
    oposicion_id uuid REFERENCES oposiciones(id) ON DELETE CASCADE,
    tema_id      uuid REFERENCES temas(id)       ON DELETE CASCADE,
    orden        int NOT NULL DEFAULT 0,
    PRIMARY KEY (oposicion_id, tema_id)
);
CREATE INDEX oposicion_temas_op_idx ON oposicion_temas (oposicion_id, orden);


-- ─────────────────────────── Preguntas ──────────────────────────────────────
-- Cada pregunta cuelga de UNA sección. El pool de preguntas de un test se
-- sortea de ahí. `hash_contenido UNIQUE` deduplica preguntas iguales entre
-- imports distintos (misma redacción → misma fila).
CREATE TABLE preguntas (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    seccion_id      uuid NOT NULL REFERENCES secciones(id) ON DELETE RESTRICT,
    enunciado       text NOT NULL,
    -- [{texto: '...', correcta: true|false}, ...]. El texto correcto se
    -- guarda en la propia opción; el índice se deriva.
    opciones        jsonb NOT NULL,
    explicacion     text,
    embedding       vector(1024),                -- BAAI/bge-m3
    autor_id        uuid REFERENCES usuarios(id) ON DELETE SET NULL,
    creado_en       timestamptz NOT NULL DEFAULT now(),
    actualizado_en  timestamptz NOT NULL DEFAULT now(),
    hash_contenido  text GENERATED ALWAYS AS
                    (md5(lower(btrim(enunciado)))) STORED UNIQUE
);
CREATE INDEX preguntas_seccion_idx  ON preguntas (seccion_id);
CREATE INDEX preguntas_emb_idx      ON preguntas USING hnsw (embedding vector_cosine_ops);
CREATE INDEX preguntas_enunciado_t  ON preguntas USING gin  (enunciado gin_trgm_ops);


-- ─────────────────────────── Documentos (teoría markdown) ──────────────────
-- Cada documento apunta a un fichero en `/mnt/data/ficheros/<oposicion>/…`
-- servido por el microservicio `contenido/`. La BD guarda sólo metadatos y
-- la ruta relativa; el contenido real es el fichero. Reglas:
--   • Sección → sólo 'teoria'  (un fichero teoria.md por sección).
--   • Módulo  → sólo 'esquema' (un fichero esquema.md por módulo).
--   • Tema    → sólo 'esquema' (un fichero esquema.md por tema).
-- La UI del esquema puede linkar a la teoría de secciones concretas por
-- referencias relativas dentro del propio markdown (`[link](../seccion-1/teoria.md)`).
CREATE TABLE documentos (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    nivel          text NOT NULL CHECK (nivel IN ('tema','modulo','seccion')),
    tema_id        uuid REFERENCES temas(id)     ON DELETE CASCADE,
    modulo_id      uuid REFERENCES modulos(id)   ON DELETE CASCADE,
    seccion_id     uuid REFERENCES secciones(id) ON DELETE CASCADE,
    tipo           text NOT NULL CHECK (tipo IN ('esquema','teoria')),
    ruta           text NOT NULL,                       -- relativa a /mnt/data/ficheros
    hash_contenido text,                                -- sha256 del fichero (integridad)
    actualizado_en timestamptz NOT NULL DEFAULT now(),
    CHECK (
        (nivel = 'seccion' AND seccion_id IS NOT NULL AND modulo_id IS NULL AND tema_id IS NULL AND tipo = 'teoria')
     OR (nivel = 'modulo'  AND modulo_id  IS NOT NULL AND seccion_id IS NULL AND tema_id IS NULL AND tipo = 'esquema')
     OR (nivel = 'tema'    AND tema_id    IS NOT NULL AND modulo_id  IS NULL AND seccion_id IS NULL AND tipo = 'esquema')
    )
);
-- Un único documento por (nivel, entidad, tipo).
CREATE UNIQUE INDEX documentos_seccion_uk ON documentos (seccion_id, tipo) WHERE seccion_id IS NOT NULL;
CREATE UNIQUE INDEX documentos_modulo_uk  ON documentos (modulo_id, tipo)  WHERE modulo_id  IS NOT NULL;
CREATE UNIQUE INDEX documentos_tema_uk    ON documentos (tema_id, tipo)    WHERE tema_id    IS NOT NULL;


-- ─────────────────────────── Actividad ──────────────────────────────────────

-- Un intento agrupa las respuestas a una tanda de preguntas.
-- `origen` marca de dónde salió: test de sección/módulo/tema, repaso global
-- o libre (por ejemplo, adelanto de repaso). `seccion_id` sólo se rellena
-- cuando el origen es 'seccion'.
CREATE TABLE intentos (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id      uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    origen          text NOT NULL CHECK (origen IN ('seccion','modulo','tema','repaso_global','libre')),
    seccion_id      uuid REFERENCES secciones(id)   ON DELETE SET NULL,
    modulo_id       uuid REFERENCES modulos(id)     ON DELETE SET NULL,
    tema_id         uuid REFERENCES temas(id)       ON DELETE SET NULL,
    oposicion_id    uuid REFERENCES oposiciones(id) ON DELETE SET NULL,
    -- IDs de las preguntas sorteadas (congela el orden y el pool del intento).
    question_ids    uuid[] NOT NULL,
    iniciado_en     timestamptz NOT NULL DEFAULT now(),
    finalizado_en   timestamptz,
    -- Nota final (0..100). Se calcula al finalizar; se cachea aquí.
    nota            numeric
);
CREATE INDEX intentos_usuario_idx    ON intentos (usuario_id, iniciado_en DESC);
CREATE INDEX intentos_seccion_idx    ON intentos (seccion_id, finalizado_en) WHERE finalizado_en IS NOT NULL;
CREATE INDEX intentos_pendiente_idx  ON intentos (usuario_id, origen) WHERE finalizado_en IS NULL;

CREATE TABLE respuestas (
    id             bigserial PRIMARY KEY,
    intento_id     uuid NOT NULL REFERENCES intentos(id)   ON DELETE CASCADE,
    pregunta_id    uuid NOT NULL REFERENCES preguntas(id)  ON DELETE CASCADE,
    -- Guardamos el texto de la opción elegida (más robusto ante reorden
    -- de opciones que un índice numérico).
    opcion_elegida text NOT NULL,
    correcta       boolean NOT NULL,
    respondida_en  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX respuestas_intento_idx  ON respuestas (intento_id);
CREATE INDEX respuestas_pregunta_idx ON respuestas (pregunta_id);

-- Marcadores unifica fallos activos y favoritas. `contador` cuenta fallos
-- consecutivos para el score del repaso global. Los favoritos son un flag
-- (contador = 1) que el usuario alterna con `toggle_favorita_*`.
CREATE TABLE marcadores (
    usuario_id   uuid NOT NULL REFERENCES usuarios(id)  ON DELETE CASCADE,
    tipo         text NOT NULL CHECK (tipo IN ('fallo','favorita_pregunta','favorita_seccion')),
    pregunta_id  uuid REFERENCES preguntas(id) ON DELETE CASCADE,
    seccion_id   uuid REFERENCES secciones(id) ON DELETE CASCADE,
    contador     int  NOT NULL DEFAULT 1,
    marcado_en   timestamptz NOT NULL DEFAULT now(),
    CHECK (
        (tipo = 'fallo'              AND pregunta_id IS NOT NULL AND seccion_id IS NULL)
     OR (tipo = 'favorita_pregunta'  AND pregunta_id IS NOT NULL AND seccion_id IS NULL)
     OR (tipo = 'favorita_seccion'   AND seccion_id  IS NOT NULL AND pregunta_id IS NULL)
    )
);
CREATE UNIQUE INDEX marcadores_preg_uk ON marcadores (usuario_id, tipo, pregunta_id) WHERE pregunta_id IS NOT NULL;
CREATE UNIQUE INDEX marcadores_secc_uk ON marcadores (usuario_id, tipo, seccion_id)  WHERE seccion_id  IS NOT NULL;
CREATE INDEX marcadores_usuario_idx    ON marcadores (usuario_id, tipo);


-- ─────────────────────────── Repasos (Leitner) ──────────────────────────────
-- Igual que en el sistema anterior: 7 cajas, próxima fecha se deriva al
-- vuelo con intervalo_repaso(caja, ritmo). El score del repaso global lo
-- calcula preguntas_repaso_oposicion() combinando repasos + marcadores.
CREATE TABLE repasos (
    usuario_id   uuid NOT NULL REFERENCES usuarios(id)  ON DELETE CASCADE,
    pregunta_id  uuid NOT NULL REFERENCES preguntas(id) ON DELETE CASCADE,
    caja         int  NOT NULL DEFAULT 1 CHECK (caja BETWEEN 1 AND 7),
    aciertos     int  NOT NULL DEFAULT 0,
    fallos       int  NOT NULL DEFAULT 0,
    ultima_en    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (usuario_id, pregunta_id)
);
CREATE INDEX repasos_usuario_idx ON repasos (usuario_id, ultima_en);


-- ─────────────────────────── Progreso (cache derivable) ────────────────────
-- Fila por (usuario, sección) con el resumen que la SPA necesita en el home.
-- Se recalcula por trigger cuando se finaliza un intento de esa sección.
-- La completada_en se pone la primera vez que un intento supera el umbral;
-- si el usuario vuelve a intentar y baja, NO se retira (una vez aprobada,
-- aprobada — la nota_max se sigue actualizando).
CREATE TABLE progreso_seccion (
    usuario_id       uuid NOT NULL REFERENCES usuarios(id)  ON DELETE CASCADE,
    seccion_id       uuid NOT NULL REFERENCES secciones(id) ON DELETE CASCADE,
    intentos_totales int NOT NULL DEFAULT 0,
    nota_max         numeric,
    ultimo_intento_id uuid REFERENCES intentos(id) ON DELETE SET NULL,
    teoria_vista_en  timestamptz,
    completada_en    timestamptz,
    PRIMARY KEY (usuario_id, seccion_id)
);
CREATE INDEX progreso_seccion_uid_idx ON progreso_seccion (usuario_id) WHERE completada_en IS NOT NULL;


-- ─────────────────────────── Propuestas de fusión ──────────────────────────
-- El worker `embeddings/detectar_duplicados.py` mete aquí pares con
-- similitud coseno > 0.90 dentro de la misma sección. Un admin las revisa
-- y decide fusionar (mueve marcadores/respuestas a la elegida y borra la
-- otra) o descartar (queda registro para no re-proponerla).
CREATE TABLE propuestas_fusion (
    a_id         uuid NOT NULL REFERENCES preguntas(id) ON DELETE CASCADE,
    b_id         uuid NOT NULL REFERENCES preguntas(id) ON DELETE CASCADE,
    seccion_id   uuid NOT NULL REFERENCES secciones(id) ON DELETE CASCADE,
    similitud    float NOT NULL,
    propuesto_en timestamptz NOT NULL DEFAULT now(),
    estado       text NOT NULL DEFAULT 'pendiente'
                     CHECK (estado IN ('pendiente','fusionada','descartada')),
    resuelto_por uuid REFERENCES usuarios(id) ON DELETE SET NULL,
    resuelto_en  timestamptz,
    PRIMARY KEY (a_id, b_id),
    CHECK (a_id < b_id)                             -- par ordenado, no duplica
);
CREATE INDEX propuestas_fusion_pend_idx
    ON propuestas_fusion (seccion_id, propuesto_en DESC) WHERE estado = 'pendiente';


-- ─────────────────────────── Enlaces del tablón (v1) ───────────────────────
CREATE TABLE enlaces_oposicion (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    oposicion_id  uuid NOT NULL REFERENCES oposiciones(id) ON DELETE CASCADE,
    orden         int NOT NULL DEFAULT 0,
    titulo        text NOT NULL,
    url           text NOT NULL,
    icono         text,
    tipo          text NOT NULL DEFAULT 'otro'
                     CHECK (tipo IN ('bases','inscripcion','calendario','sede','otro')),
    creado_en     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX enlaces_oposicion_op_idx ON enlaces_oposicion (oposicion_id, orden);


-- =============================================================================
--                    GRANTS Y RLS DEL BLOQUE DE CONTENIDO
-- =============================================================================

GRANT SELECT ON temas, modulos, secciones, oposicion_temas, documentos, enlaces_oposicion
    TO web_user;
GRANT INSERT, UPDATE, DELETE ON temas, modulos, secciones, oposicion_temas, documentos, enlaces_oposicion
    TO web_user;  -- protegido por RLS + permisos funcionales

GRANT SELECT ON preguntas TO web_user;
GRANT INSERT, UPDATE, DELETE ON preguntas TO web_user;

GRANT SELECT, INSERT, UPDATE, DELETE
    ON intentos, respuestas, marcadores, repasos, progreso_seccion
    TO web_user;

GRANT SELECT, INSERT, UPDATE ON propuestas_fusion TO web_user;

ALTER TABLE temas             ENABLE ROW LEVEL SECURITY;
ALTER TABLE modulos           ENABLE ROW LEVEL SECURITY;
ALTER TABLE secciones         ENABLE ROW LEVEL SECURITY;
ALTER TABLE oposicion_temas   ENABLE ROW LEVEL SECURITY;
ALTER TABLE documentos        ENABLE ROW LEVEL SECURITY;
ALTER TABLE preguntas         ENABLE ROW LEVEL SECURITY;
ALTER TABLE intentos          ENABLE ROW LEVEL SECURITY;
ALTER TABLE respuestas        ENABLE ROW LEVEL SECURITY;
ALTER TABLE marcadores        ENABLE ROW LEVEL SECURITY;
ALTER TABLE repasos           ENABLE ROW LEVEL SECURITY;
ALTER TABLE progreso_seccion  ENABLE ROW LEVEL SECURITY;
ALTER TABLE propuestas_fusion ENABLE ROW LEVEL SECURITY;
ALTER TABLE enlaces_oposicion ENABLE ROW LEVEL SECURITY;

-- Contenido curricular: lectura libre para autenticados. Escritura sólo
-- con permiso funcional (editor/admin).
CREATE POLICY temas_lectura ON temas FOR SELECT
    USING (jwt_usuario_id() IS NOT NULL);
CREATE POLICY temas_escritura ON temas FOR ALL TO web_user
    USING (tiene_permiso('contenido.crear') OR tiene_permiso('contenido.editar') OR es_admin())
    WITH CHECK (tiene_permiso('contenido.crear') OR tiene_permiso('contenido.editar') OR es_admin());

CREATE POLICY modulos_lectura ON modulos FOR SELECT
    USING (jwt_usuario_id() IS NOT NULL);
CREATE POLICY modulos_escritura ON modulos FOR ALL TO web_user
    USING (tiene_permiso('contenido.crear') OR tiene_permiso('contenido.editar') OR es_admin())
    WITH CHECK (tiene_permiso('contenido.crear') OR tiene_permiso('contenido.editar') OR es_admin());

CREATE POLICY secciones_lectura ON secciones FOR SELECT
    USING (jwt_usuario_id() IS NOT NULL);
CREATE POLICY secciones_escritura ON secciones FOR ALL TO web_user
    USING (tiene_permiso('contenido.crear') OR tiene_permiso('contenido.editar') OR es_admin())
    WITH CHECK (tiene_permiso('contenido.crear') OR tiene_permiso('contenido.editar') OR es_admin());

CREATE POLICY optemas_lectura ON oposicion_temas FOR SELECT
    USING (jwt_usuario_id() IS NOT NULL);
CREATE POLICY optemas_escritura ON oposicion_temas FOR ALL TO web_user
    USING (tiene_permiso('oposicion.gestionar') OR es_admin())
    WITH CHECK (tiene_permiso('oposicion.gestionar') OR es_admin());

CREATE POLICY documentos_lectura ON documentos FOR SELECT
    USING (jwt_usuario_id() IS NOT NULL);
CREATE POLICY documentos_escritura ON documentos FOR ALL TO web_user
    USING (tiene_permiso('teoria.gestionar') OR tiene_permiso('contenido.editar') OR es_admin())
    WITH CHECK (tiene_permiso('teoria.gestionar') OR tiene_permiso('contenido.editar') OR es_admin());

CREATE POLICY enlaces_lectura ON enlaces_oposicion FOR SELECT
    USING (jwt_usuario_id() IS NOT NULL);
CREATE POLICY enlaces_escritura ON enlaces_oposicion FOR ALL TO web_user
    USING (tiene_permiso('oposicion.gestionar') OR es_admin())
    WITH CHECK (tiene_permiso('oposicion.gestionar') OR es_admin());

-- Preguntas: lectura para autenticados, escritura por permiso.
CREATE POLICY preg_lectura ON preguntas FOR SELECT
    USING (jwt_usuario_id() IS NOT NULL);
CREATE POLICY preg_insert  ON preguntas FOR INSERT WITH CHECK (tiene_permiso('pregunta.crear'));
CREATE POLICY preg_update  ON preguntas FOR UPDATE USING  (tiene_permiso('pregunta.editar'));
CREATE POLICY preg_delete  ON preguntas FOR DELETE USING  (tiene_permiso('pregunta.borrar'));

-- Actividad: cada uno ve/edita lo suyo; admin ve todo.
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

CREATE POLICY mis_repasos ON repasos
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());

CREATE POLICY mi_progreso_seccion ON progreso_seccion
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());

-- Propuestas de fusión: sólo quien puede fusionar preguntas las ve/edita.
CREATE POLICY prof_admin ON propuestas_fusion FOR ALL TO web_user
    USING (tiene_permiso('pregunta.fusionar') OR es_admin())
    WITH CHECK (tiene_permiso('pregunta.fusionar') OR es_admin());


-- ── Defaults dependientes de JWT del bloque de contenido ────────────────────
ALTER TABLE intentos  ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE marcadores ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE repasos    ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE progreso_seccion ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE preguntas  ALTER COLUMN autor_id   SET DEFAULT jwt_usuario_id();


-- =============================================================================
--                    TRIGGERS DE ENCOLADO DE EMBEDDINGS
-- =============================================================================
-- Cuando se inserta/modifica una pregunta, se encola para que el worker
-- de embeddings la vectorice. SECURITY DEFINER para poder insertar en
-- cola_embeddings aunque el cliente sólo tenga UPDATE en preguntas.

CREATE OR REPLACE FUNCTION encolar_embedding_pregunta() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF TG_OP = 'INSERT'
       OR NEW.enunciado IS DISTINCT FROM OLD.enunciado
       OR NEW.opciones  IS DISTINCT FROM OLD.opciones THEN
        INSERT INTO cola_embeddings (entidad, entidad_id)
        VALUES ('pregunta', NEW.id::text);
        PERFORM pg_notify('embeddings', 'pregunta');
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER preguntas_encolar_emb
    AFTER INSERT OR UPDATE OF enunciado, opciones ON preguntas
    FOR EACH ROW EXECUTE FUNCTION encolar_embedding_pregunta();


-- =============================================================================
--                        UTILIDADES DE CONTENIDO
-- =============================================================================

-- Nº de preguntas de un test según nivel y nº de secciones que engloba.
-- Fórmula sublineal:
--   sección  → n_preg_test fijo (10 por defecto, configurable por sección).
--   módulo   → round(10 + 8·√N)
--   tema     → round(15 + 10·√N)
-- Cambiar aquí ajusta el sistema entero.
CREATE OR REPLACE FUNCTION preguntas_por_nodo(p_nivel text, p_n_secciones int) RETURNS int
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_nivel
        WHEN 'modulo' THEN GREATEST(1, round(10 + 8  * sqrt(GREATEST(p_n_secciones, 1))))::int
        WHEN 'tema'   THEN GREATEST(1, round(15 + 10 * sqrt(GREATEST(p_n_secciones, 1))))::int
        ELSE 10
    END;
$$;

-- Día actual en Europe/Madrid (para retos diarios y racha).
CREATE OR REPLACE FUNCTION hoy_madrid() RETURNS date
LANGUAGE sql STABLE AS $$
    SELECT (now() AT TIME ZONE 'Europe/Madrid')::date;
$$;

-- Curva de nivel: nivel = floor(sqrt(xp/50)) + 1  →  50xp lvl1→2, 200xp lvl2→3,
-- 450xp lvl3→4, 800xp lvl4→5, …
CREATE OR REPLACE FUNCTION nivel_de_xp(p_xp int) RETURNS int
LANGUAGE sql IMMUTABLE AS $$
    SELECT floor(sqrt(GREATEST(p_xp, 0)::float / 50.0))::int + 1;
$$;

CREATE OR REPLACE FUNCTION xp_para_nivel(p_nivel int) RETURNS int
LANGUAGE sql IMMUTABLE AS $$
    SELECT (50 * (GREATEST(p_nivel, 1) - 1) * (GREATEST(p_nivel, 1) - 1))::int;
$$;

-- Ritmo de repaso preferido del usuario (con fallback a 'normal').
CREATE OR REPLACE FUNCTION ritmo_repaso_usuario(p_usuario_id uuid) RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT ritmo_repaso FROM preferencias_usuario WHERE usuario_id = p_usuario_id),
        'normal'
    );
$$;

-- Días entre repasos según caja y ritmo. Curva "1-3-7-15-30-60-120" (normal)
-- suavizada/exigida en los otros ritmos.
CREATE OR REPLACE FUNCTION intervalo_repaso(p_caja int, p_ritmo text) RETURNS interval
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_ritmo
        WHEN 'intensivo' THEN (ARRAY['1 day','1 day','3 days','7 days','14 days','30 days','60 days'])[GREATEST(LEAST(p_caja,7),1)]::interval
        WHEN 'relajado'  THEN (ARRAY['2 days','5 days','10 days','21 days','45 days','90 days','180 days'])[GREATEST(LEAST(p_caja,7),1)]::interval
        ELSE                    (ARRAY['1 day','3 days','7 days','15 days','30 days','60 days','120 days'])[GREATEST(LEAST(p_caja,7),1)]::interval
    END;
$$;


-- =============================================================================
--                RECÁLCULO DE PROGRESO (cascada sección→módulo→tema)
-- =============================================================================
-- Cada vez que un intento se finaliza sobre una sección, actualizamos
-- progreso_seccion. El "completado" de módulo y tema NO se materializa
-- en tabla propia: se deriva de progreso_seccion al leer (una vista o RPC).
-- Esto evita tener que mantener 3 tablas sincronizadas.

CREATE OR REPLACE FUNCTION _actualizar_progreso_seccion(
    p_usuario_id uuid,
    p_seccion_id uuid,
    p_intento_id uuid,
    p_nota       numeric
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_min numeric;
BEGIN
    SELECT min_aprobado INTO v_min FROM secciones WHERE id = p_seccion_id;
    INSERT INTO progreso_seccion (usuario_id, seccion_id, intentos_totales,
                                  nota_max, ultimo_intento_id, completada_en)
    VALUES (p_usuario_id, p_seccion_id, 1, p_nota, p_intento_id,
            CASE WHEN p_nota >= COALESCE(v_min, 70) THEN now() ELSE NULL END)
    ON CONFLICT (usuario_id, seccion_id) DO UPDATE
        SET intentos_totales   = progreso_seccion.intentos_totales + 1,
            nota_max           = GREATEST(progreso_seccion.nota_max, EXCLUDED.nota_max),
            ultimo_intento_id  = EXCLUDED.ultimo_intento_id,
            -- Aprobada una vez, aprobada para siempre.
            completada_en      = COALESCE(progreso_seccion.completada_en,
                                          CASE WHEN p_nota >= COALESCE(v_min, 70)
                                               THEN now() ELSE NULL END);
END $$;


-- =============================================================================
--                            RPCs DE CONTENIDO
-- =============================================================================

-- Marca la teoría de una sección como vista (sin cambiar el resto del progreso).
CREATE OR REPLACE FUNCTION marcar_teoria_vista(p_seccion_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := jwt_usuario_id();
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    INSERT INTO progreso_seccion (usuario_id, seccion_id, teoria_vista_en)
    VALUES (v_uid, p_seccion_id, now())
    ON CONFLICT (usuario_id, seccion_id) DO UPDATE
        SET teoria_vista_en = COALESCE(progreso_seccion.teoria_vista_en, now());
    RETURN jsonb_build_object('ok', true);
END $$;


-- Sortea un pool de preguntas para un intento nuevo.
CREATE OR REPLACE FUNCTION _sortear_preguntas(
    p_seccion_ids uuid[],
    p_n           int
) RETURNS uuid[]
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(array_agg(id ORDER BY random()), ARRAY[]::uuid[])
      FROM (
        SELECT id FROM preguntas
         WHERE seccion_id = ANY(p_seccion_ids)
         ORDER BY random()
         LIMIT p_n
      ) x;
$$;


-- Crea un intento de sección: sortea `n_preg_test` preguntas del pool.
CREATE OR REPLACE FUNCTION iniciar_intento_seccion(p_seccion_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_n   int;
    v_ids uuid[];
    v_int uuid;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    SELECT n_preg_test INTO v_n FROM secciones WHERE id = p_seccion_id;
    IF v_n IS NULL THEN RAISE EXCEPTION 'seccion_no_encontrada'; END IF;
    v_ids := _sortear_preguntas(ARRAY[p_seccion_id], v_n);
    IF array_length(v_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'sin_preguntas';
    END IF;
    INSERT INTO intentos (usuario_id, origen, seccion_id, question_ids)
    VALUES (v_uid, 'seccion', p_seccion_id, v_ids)
    RETURNING id INTO v_int;
    RETURN jsonb_build_object('intento_id', v_int, 'question_ids', to_jsonb(v_ids));
END $$;


-- Crea un intento de módulo: sortea preguntas del pool combinado de sus
-- secciones. `preguntas_por_nodo('modulo', N)` decide el tamaño.
CREATE OR REPLACE FUNCTION iniciar_intento_modulo(p_modulo_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_secc uuid[];
    v_n   int;
    v_ids uuid[];
    v_int uuid;
    v_tema uuid;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    SELECT array_agg(id), COUNT(*) INTO v_secc, v_n
      FROM secciones WHERE modulo_id = p_modulo_id;
    IF v_secc IS NULL THEN RAISE EXCEPTION 'modulo_sin_secciones'; END IF;
    SELECT tema_id INTO v_tema FROM modulos WHERE id = p_modulo_id;
    v_n := preguntas_por_nodo('modulo', v_n);
    v_ids := _sortear_preguntas(v_secc, v_n);
    IF array_length(v_ids, 1) IS NULL THEN RAISE EXCEPTION 'sin_preguntas'; END IF;
    INSERT INTO intentos (usuario_id, origen, modulo_id, tema_id, question_ids)
    VALUES (v_uid, 'modulo', p_modulo_id, v_tema, v_ids)
    RETURNING id INTO v_int;
    RETURN jsonb_build_object('intento_id', v_int, 'question_ids', to_jsonb(v_ids));
END $$;


-- Crea un intento de tema: sortea preguntas del pool combinado de todas sus
-- secciones (recorriendo módulos).
CREATE OR REPLACE FUNCTION iniciar_intento_tema(p_tema_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_secc uuid[];
    v_n   int;
    v_ids uuid[];
    v_int uuid;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    SELECT array_agg(s.id), COUNT(*) INTO v_secc, v_n
      FROM secciones s
      JOIN modulos   m ON m.id = s.modulo_id
     WHERE m.tema_id = p_tema_id;
    IF v_secc IS NULL THEN RAISE EXCEPTION 'tema_sin_secciones'; END IF;
    v_n := preguntas_por_nodo('tema', v_n);
    v_ids := _sortear_preguntas(v_secc, v_n);
    IF array_length(v_ids, 1) IS NULL THEN RAISE EXCEPTION 'sin_preguntas'; END IF;
    INSERT INTO intentos (usuario_id, origen, tema_id, question_ids)
    VALUES (v_uid, 'tema', p_tema_id, v_ids)
    RETURNING id INTO v_int;
    RETURN jsonb_build_object('intento_id', v_int, 'question_ids', to_jsonb(v_ids));
END $$;


-- Registra una respuesta puntual: actualiza `respuestas`, marca fallo/limpia,
-- y avanza Leitner. NO finaliza el intento (eso se hace explícito con
-- `finalizar_intento`, típicamente al enviar el test).
CREATE OR REPLACE FUNCTION registrar_respuesta(
    p_intento_id  uuid,
    p_pregunta_id uuid,
    p_opcion      text,
    p_correcta    boolean
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_owner uuid;
    v_ritmo text;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    SELECT usuario_id INTO v_owner FROM intentos WHERE id = p_intento_id;
    IF v_owner IS NULL THEN RAISE EXCEPTION 'intento_no_encontrado'; END IF;
    IF v_owner <> v_uid AND NOT es_admin() THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    INSERT INTO respuestas (intento_id, pregunta_id, opcion_elegida, correcta)
    VALUES (p_intento_id, p_pregunta_id, p_opcion, p_correcta);
    v_ritmo := ritmo_repaso_usuario(v_owner);

    -- Leitner: acierto sube 1 caja, fallo baja 2 y ancla `ultima_en` en el
    -- pasado para que quede vencida. Nueva pregunta arranca en caja 2.
    INSERT INTO repasos (usuario_id, pregunta_id, caja, aciertos, fallos, ultima_en)
    VALUES (v_owner, p_pregunta_id,
            CASE WHEN p_correcta THEN 2 ELSE 1 END,
            CASE WHEN p_correcta THEN 1 ELSE 0 END,
            CASE WHEN p_correcta THEN 0 ELSE 1 END,
            now())
    ON CONFLICT (usuario_id, pregunta_id) DO UPDATE
        SET caja      = CASE WHEN p_correcta
                             THEN LEAST(repasos.caja + 1, 7)
                             ELSE GREATEST(repasos.caja - 2, 1)
                        END,
            aciertos  = repasos.aciertos + (CASE WHEN p_correcta THEN 1 ELSE 0 END),
            fallos    = repasos.fallos   + (CASE WHEN p_correcta THEN 0 ELSE 1 END),
            ultima_en = CASE WHEN p_correcta
                             THEN now()
                             ELSE now() - intervalo_repaso(GREATEST(repasos.caja - 2, 1), v_ritmo)
                        END;

    -- Marcador de fallo: activo mientras no se acierte. Al acertar limpia.
    IF p_correcta THEN
        DELETE FROM marcadores
         WHERE usuario_id = v_owner AND tipo = 'fallo' AND pregunta_id = p_pregunta_id;
    ELSE
        INSERT INTO marcadores (usuario_id, tipo, pregunta_id, contador)
        VALUES (v_owner, 'fallo', p_pregunta_id, 1)
        ON CONFLICT (usuario_id, tipo, pregunta_id) DO UPDATE
            SET contador = marcadores.contador + 1,
                marcado_en = now();
    END IF;
END $$;


-- Cierra el intento: calcula nota (aciertos/total*100) y actualiza el cache
-- de progreso_seccion si el intento era de sección.
CREATE OR REPLACE FUNCTION finalizar_intento(p_intento_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_int intentos%ROWTYPE;
    v_ok  int;
    v_tot int;
    v_nota numeric;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    SELECT * INTO v_int FROM intentos WHERE id = p_intento_id;
    IF v_int.usuario_id IS NULL THEN RAISE EXCEPTION 'intento_no_encontrado'; END IF;
    IF v_int.usuario_id <> v_uid AND NOT es_admin() THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    IF v_int.finalizado_en IS NOT NULL THEN
        -- Idempotente: devolver la misma info.
        RETURN jsonb_build_object('ok', true, 'nota', v_int.nota, 'ya_finalizado', true);
    END IF;
    v_tot := COALESCE(array_length(v_int.question_ids, 1), 0);
    SELECT count(*) FILTER (WHERE correcta) INTO v_ok
      FROM respuestas WHERE intento_id = p_intento_id;
    v_nota := CASE WHEN v_tot > 0 THEN round((v_ok::numeric * 100) / v_tot, 2) ELSE 0 END;
    UPDATE intentos SET finalizado_en = now(), nota = v_nota
     WHERE id = p_intento_id;
    IF v_int.origen = 'seccion' AND v_int.seccion_id IS NOT NULL THEN
        PERFORM _actualizar_progreso_seccion(v_int.usuario_id, v_int.seccion_id, p_intento_id, v_nota);
    END IF;
    RETURN jsonb_build_object('ok', true, 'nota', v_nota,
                              'aciertos', v_ok, 'total', v_tot);
END $$;


-- Descarta un intento sin finalizarlo (borra las respuestas ya dadas).
CREATE OR REPLACE FUNCTION descartar_intento(p_intento_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := jwt_usuario_id();
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    DELETE FROM intentos
     WHERE id = p_intento_id
       AND (usuario_id = v_uid OR es_admin());
END $$;


-- Home de una oposición: devuelve todo lo que la SPA necesita en una llamada.
CREATE OR REPLACE FUNCTION mi_home_oposicion(p_oposicion_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_res jsonb;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;

    WITH secc_pct AS (
        -- Por sección: completada (0/1) — luego agregamos a módulo y tema.
        SELECT s.id AS seccion_id, s.modulo_id, m.tema_id,
               (ps.completada_en IS NOT NULL)::int AS completada,
               ps.nota_max,
               ps.teoria_vista_en
          FROM secciones s
          JOIN modulos m ON m.id = s.modulo_id
          LEFT JOIN progreso_seccion ps
                 ON ps.usuario_id = v_uid AND ps.seccion_id = s.id
    )
    SELECT jsonb_build_object(
        'oposicion',
        (SELECT jsonb_build_object('id', o.id, 'nombre', o.nombre, 'descripcion', o.descripcion)
           FROM oposiciones o WHERE o.id = p_oposicion_id),
        'temas',
        COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id',           t.id,
                'nombre',       t.nombre,
                'slug',         t.slug,
                'orden',        ot.orden,
                -- % completado del tema = secciones completadas / totales.
                'pct',          CASE
                    WHEN (SELECT COUNT(*) FROM secc_pct WHERE tema_id = t.id) = 0
                        THEN 0
                    ELSE round(100.0 * (SELECT COALESCE(SUM(completada),0) FROM secc_pct WHERE tema_id = t.id)
                                     / (SELECT COUNT(*)                 FROM secc_pct WHERE tema_id = t.id), 0)
                END,
                'modulos',
                COALESCE((
                    SELECT jsonb_agg(jsonb_build_object(
                        'id',              m.id,
                        'nombre',          m.nombre,
                        'orden',           m.orden,
                        'es_unico',        m.es_unico,
                        'secciones_ok',    (SELECT COALESCE(SUM(completada),0)
                                              FROM secc_pct WHERE modulo_id = m.id),
                        'secciones_total', (SELECT COUNT(*)
                                              FROM secc_pct WHERE modulo_id = m.id),
                        'secciones',
                        COALESCE((
                            SELECT jsonb_agg(jsonb_build_object(
                                'id',              s.id,
                                'nombre',          s.nombre,
                                'orden',           s.orden,
                                'nota_max',        sp.nota_max,
                                'completada',      sp.completada = 1,
                                'teoria_vista_en', sp.teoria_vista_en
                            ) ORDER BY s.orden)
                              FROM secciones s
                              LEFT JOIN secc_pct sp ON sp.seccion_id = s.id
                             WHERE s.modulo_id = m.id
                        ), '[]'::jsonb)
                    ) ORDER BY m.orden)
                      FROM modulos m WHERE m.tema_id = t.id
                ), '[]'::jsonb)
            ) ORDER BY ot.orden)
              FROM temas t
              JOIN oposicion_temas ot ON ot.tema_id = t.id
             WHERE ot.oposicion_id = p_oposicion_id
        ), '[]'::jsonb)
    ) INTO v_res;

    RETURN v_res;
END $$;


-- % de solapamiento entre una oposición y lo que el usuario ya tiene
-- estudiado (secciones completadas). Útil al proponer una oposición nueva.
CREATE OR REPLACE FUNCTION sugerir_solapamiento(p_oposicion_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_total int; v_hechas int;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    SELECT COUNT(*) INTO v_total
      FROM secciones s
      JOIN modulos m ON m.id = s.modulo_id
      JOIN oposicion_temas ot ON ot.tema_id = m.tema_id
     WHERE ot.oposicion_id = p_oposicion_id;
    SELECT COUNT(*) INTO v_hechas
      FROM secciones s
      JOIN modulos m ON m.id = s.modulo_id
      JOIN oposicion_temas ot ON ot.tema_id = m.tema_id
      JOIN progreso_seccion ps ON ps.seccion_id = s.id AND ps.usuario_id = v_uid
     WHERE ot.oposicion_id = p_oposicion_id
       AND ps.completada_en IS NOT NULL;
    RETURN jsonb_build_object(
        'oposicion_id', p_oposicion_id,
        'total',        v_total,
        'hechas',       v_hechas,
        'pct',          CASE WHEN v_total = 0 THEN 0
                             ELSE round(100.0 * v_hechas / v_total, 0)
                        END
    );
END $$;


-- Repaso global de una oposición: 40 preguntas de secciones completadas,
-- priorizadas por fallos activos y cajas bajas. Ver score en el plan.
CREATE OR REPLACE FUNCTION preguntas_repaso_oposicion(
    p_oposicion_id uuid,
    p_n            int DEFAULT 40
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_res jsonb;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;

    WITH pool AS (
        SELECT p.id AS pregunta_id
          FROM preguntas p
          JOIN secciones s   ON s.id = p.seccion_id
          JOIN modulos   m   ON m.id = s.modulo_id
          JOIN oposicion_temas ot ON ot.tema_id = m.tema_id
          JOIN progreso_seccion ps
                ON ps.usuario_id = v_uid AND ps.seccion_id = s.id
         WHERE ot.oposicion_id = p_oposicion_id
           AND ps.completada_en IS NOT NULL
    ),
    scored AS (
        SELECT p.pregunta_id,
               COALESCE(mf.contador, 0)                                            AS fallos,
               COALESCE(r.caja, 1)                                                 AS caja,
               COALESCE(EXTRACT(day FROM (now() - r.ultima_en))::int, 999)         AS dias_desde
          FROM pool p
          LEFT JOIN marcadores mf
                 ON mf.usuario_id = v_uid AND mf.tipo = 'fallo' AND mf.pregunta_id = p.pregunta_id
          LEFT JOIN repasos r
                 ON r.usuario_id = v_uid AND r.pregunta_id = p.pregunta_id
    )
    SELECT COALESCE(jsonb_agg(pregunta_id ORDER BY score DESC, random()) , '[]'::jsonb) INTO v_res
      FROM (
        SELECT pregunta_id,
               100 * fallos
             + 20  * (8 - caja)
             +  5  * dias_desde
             - 10  * (CASE WHEN caja = 7 THEN 1 ELSE 0 END) AS score
          FROM scored
         ORDER BY score DESC, random()
         LIMIT p_n
      ) x;

    RETURN v_res;
END $$;


-- Iniciar intento de repaso: crea el intento con esas 40 preguntas.
CREATE OR REPLACE FUNCTION iniciar_intento_repaso(
    p_oposicion_id uuid,
    p_n            int DEFAULT 40
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_ids uuid[];
    v_int uuid;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    SELECT ARRAY(SELECT jsonb_array_elements_text(preguntas_repaso_oposicion(p_oposicion_id, p_n)))::uuid[]
      INTO v_ids;
    IF v_ids IS NULL OR array_length(v_ids, 1) IS NULL THEN
        RAISE EXCEPTION 'sin_preguntas_repaso';
    END IF;
    INSERT INTO intentos (usuario_id, origen, oposicion_id, question_ids)
    VALUES (v_uid, 'repaso_global', p_oposicion_id, v_ids)
    RETURNING id INTO v_int;
    RETURN jsonb_build_object('intento_id', v_int, 'question_ids', to_jsonb(v_ids));
END $$;


-- Utilidad: cuerpo de preguntas de un intento (para pintar el test).
CREATE OR REPLACE FUNCTION preguntas_de_intento(p_intento_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_owner uuid;
    v_qids  uuid[];
    v_res   jsonb;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    SELECT usuario_id, question_ids INTO v_owner, v_qids
      FROM intentos WHERE id = p_intento_id;
    IF v_owner IS NULL THEN RAISE EXCEPTION 'intento_no_encontrado'; END IF;
    IF v_owner <> v_uid AND NOT es_admin() THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    -- Preserva el orden del array question_ids.
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id',          p.id,
        'enunciado',   p.enunciado,
        'opciones',    p.opciones,
        'explicacion', p.explicacion
    ) ORDER BY array_position(v_qids, p.id)), '[]'::jsonb) INTO v_res
      FROM preguntas p WHERE p.id = ANY(v_qids);
    RETURN v_res;
END $$;


-- Favoritas / fallos
CREATE OR REPLACE FUNCTION toggle_favorita_pregunta(p_pregunta_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_ok  boolean;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    DELETE FROM marcadores
     WHERE usuario_id = v_uid AND tipo = 'favorita_pregunta' AND pregunta_id = p_pregunta_id
     RETURNING true INTO v_ok;
    IF v_ok IS NULL THEN
        INSERT INTO marcadores (usuario_id, tipo, pregunta_id)
        VALUES (v_uid, 'favorita_pregunta', p_pregunta_id);
        RETURN jsonb_build_object('favorita', true);
    END IF;
    RETURN jsonb_build_object('favorita', false);
END $$;

CREATE OR REPLACE FUNCTION mis_fallos_ids() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT COALESCE(jsonb_agg(pregunta_id ORDER BY marcado_en DESC), '[]'::jsonb)
      FROM marcadores
     WHERE usuario_id = jwt_usuario_id() AND tipo = 'fallo';
$$;


-- Gamificación mínima (lectura) — el catálogo se maneja en fase 8.
CREATE OR REPLACE FUNCTION mi_gamificacion() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_gm  usuario_gamificacion%ROWTYPE;
    v_nvl int;
    v_xp0 int;
    v_xp1 int;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    SELECT * INTO v_gm FROM usuario_gamificacion WHERE usuario_id = v_uid;
    IF v_gm.usuario_id IS NULL THEN
        v_gm.xp_total := 0; v_gm.racha_actual := 0; v_gm.racha_maxima := 0;
    END IF;
    v_nvl := nivel_de_xp(v_gm.xp_total);
    v_xp0 := xp_para_nivel(v_nvl);
    v_xp1 := xp_para_nivel(v_nvl + 1);
    RETURN jsonb_build_object(
        'xp_total',       v_gm.xp_total,
        'nivel',          v_nvl,
        'xp_nivel_ini',   v_xp0,
        'xp_nivel_sig',   v_xp1,
        'racha_actual',   v_gm.racha_actual,
        'racha_maxima',   v_gm.racha_maxima,
        'ultimo_activo',  v_gm.ultimo_dia_activo
    );
END $$;


-- Ritmo de repaso propio.
CREATE OR REPLACE FUNCTION mi_ritmo_repaso() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT ritmo_repaso_usuario(jwt_usuario_id());
$$;

CREATE OR REPLACE FUNCTION set_ritmo_repaso(p_ritmo text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF jwt_usuario_id() IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    IF p_ritmo NOT IN ('intensivo','normal','relajado') THEN
        RAISE EXCEPTION 'ritmo_invalido';
    END IF;
    INSERT INTO preferencias_usuario (usuario_id, ritmo_repaso)
    VALUES (jwt_usuario_id(), p_ritmo)
    ON CONFLICT (usuario_id) DO UPDATE
        SET ritmo_repaso = EXCLUDED.ritmo_repaso, actualizado_en = now();
END $$;


-- Tablón v1: enlaces útiles por oposición.
CREATE OR REPLACE FUNCTION enlaces_de_oposicion(p_oposicion_id uuid) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', id, 'titulo', titulo, 'url', url, 'icono', icono, 'tipo', tipo
    ) ORDER BY orden, titulo), '[]'::jsonb)
      FROM enlaces_oposicion
     WHERE oposicion_id = p_oposicion_id;
$$;

CREATE OR REPLACE FUNCTION set_enlaces_oposicion(
    p_oposicion_id uuid,
    p_enlaces      jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_row jsonb;
    v_ord int := 0;
BEGIN
    IF NOT (es_admin() OR tiene_permiso('oposicion.gestionar')) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    DELETE FROM enlaces_oposicion WHERE oposicion_id = p_oposicion_id;
    FOR v_row IN SELECT * FROM jsonb_array_elements(p_enlaces) LOOP
        v_ord := v_ord + 1;
        INSERT INTO enlaces_oposicion (oposicion_id, orden, titulo, url, icono, tipo)
        VALUES (p_oposicion_id, v_ord,
                v_row->>'titulo', v_row->>'url',
                v_row->>'icono', COALESCE(v_row->>'tipo', 'otro'));
    END LOOP;
    RETURN jsonb_build_object('ok', true, 'total', v_ord);
END $$;


-- =============================================================================
--                         GRANTS DE EXECUTE (BLOQUE C)
-- =============================================================================
GRANT EXECUTE ON FUNCTION preguntas_por_nodo(text,int)          TO web_user, web_anon;
GRANT EXECUTE ON FUNCTION hoy_madrid()                          TO web_user, web_anon;
GRANT EXECUTE ON FUNCTION nivel_de_xp(int)                      TO web_user, web_anon;
GRANT EXECUTE ON FUNCTION xp_para_nivel(int)                    TO web_user, web_anon;
GRANT EXECUTE ON FUNCTION ritmo_repaso_usuario(uuid)            TO web_user;
GRANT EXECUTE ON FUNCTION intervalo_repaso(int,text)            TO web_user;

GRANT EXECUTE ON FUNCTION marcar_teoria_vista(uuid)             TO web_user;
GRANT EXECUTE ON FUNCTION iniciar_intento_seccion(uuid)         TO web_user;
GRANT EXECUTE ON FUNCTION iniciar_intento_modulo(uuid)          TO web_user;
GRANT EXECUTE ON FUNCTION iniciar_intento_tema(uuid)            TO web_user;
GRANT EXECUTE ON FUNCTION iniciar_intento_repaso(uuid,int)      TO web_user;
GRANT EXECUTE ON FUNCTION registrar_respuesta(uuid,uuid,text,boolean) TO web_user;
GRANT EXECUTE ON FUNCTION finalizar_intento(uuid)               TO web_user;
GRANT EXECUTE ON FUNCTION descartar_intento(uuid)               TO web_user;
GRANT EXECUTE ON FUNCTION preguntas_de_intento(uuid)            TO web_user;

GRANT EXECUTE ON FUNCTION mi_home_oposicion(uuid)               TO web_user;
GRANT EXECUTE ON FUNCTION sugerir_solapamiento(uuid)            TO web_user;
GRANT EXECUTE ON FUNCTION preguntas_repaso_oposicion(uuid,int)  TO web_user;

GRANT EXECUTE ON FUNCTION toggle_favorita_pregunta(uuid)        TO web_user;
GRANT EXECUTE ON FUNCTION mis_fallos_ids()                      TO web_user;

GRANT EXECUTE ON FUNCTION mi_gamificacion()                     TO web_user;
GRANT EXECUTE ON FUNCTION mi_ritmo_repaso()                     TO web_user;
GRANT EXECUTE ON FUNCTION set_ritmo_repaso(text)                TO web_user;

GRANT EXECUTE ON FUNCTION enlaces_de_oposicion(uuid)            TO web_user;
GRANT EXECUTE ON FUNCTION set_enlaces_oposicion(uuid, jsonb)    TO web_user;


-- Oposiciones asignadas al usuario actual (para el selector de la SPA).
CREATE OR REPLACE FUNCTION mis_oposiciones() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id', o.id, 'nombre', o.nombre, 'descripcion', o.descripcion
    ) ORDER BY o.nombre), '[]'::jsonb)
      FROM oposiciones o
      JOIN usuario_oposiciones uo ON uo.oposicion_id = o.id
     WHERE uo.usuario_id = jwt_usuario_id() AND o.activa;
$$;

-- Metadatos del documento (teoría o esquema) asociado a una sección.
-- La SPA lo usa para saber la ruta relativa y pedir el fichero al
-- microservicio de contenido.
CREATE OR REPLACE FUNCTION documento_de_seccion(p_seccion_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT jsonb_build_object(
        'id',   d.id,
        'ruta', d.ruta,
        'tipo', d.tipo,
        'actualizado_en', d.actualizado_en
    )
      FROM documentos d
     WHERE d.seccion_id = p_seccion_id AND d.tipo = 'teoria'
     LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION documento_de_modulo(p_modulo_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT jsonb_build_object(
        'id',   d.id,
        'ruta', d.ruta,
        'tipo', d.tipo,
        'actualizado_en', d.actualizado_en
    )
      FROM documentos d
     WHERE d.modulo_id = p_modulo_id AND d.tipo = 'esquema'
     LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION documento_de_tema(p_tema_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
    SELECT jsonb_build_object(
        'id',   d.id,
        'ruta', d.ruta,
        'tipo', d.tipo,
        'actualizado_en', d.actualizado_en
    )
      FROM documentos d
     WHERE d.tema_id = p_tema_id AND d.tipo = 'esquema'
     LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION mis_oposiciones()                 TO web_user;
GRANT EXECUTE ON FUNCTION documento_de_seccion(uuid)        TO web_user;
GRANT EXECUTE ON FUNCTION documento_de_modulo(uuid)         TO web_user;
GRANT EXECUTE ON FUNCTION documento_de_tema(uuid)           TO web_user;


-- ─────────────────────── Propuestas de fusión (admin) ──────────────────
-- Detectadas por `embeddings/detectar_duplicados.py` (cron semanal). Un
-- admin las revisa una a una y decide fusionar (mueve marcadores y
-- respuestas de `b` a `a`, borra `b`) o descartar (no se re-propone).

CREATE OR REPLACE FUNCTION listar_propuestas_fusion(
    p_page int DEFAULT 1,
    p_size int DEFAULT 20
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_off int := GREATEST(p_page - 1, 0) * p_size;
    v_total int;
    v_rows  jsonb;
BEGIN
    IF NOT (es_admin() OR tiene_permiso('pregunta.fusionar')) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    SELECT count(*) INTO v_total FROM propuestas_fusion WHERE estado = 'pendiente';
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'a', jsonb_build_object('id', a.id, 'enunciado', a.enunciado),
        'b', jsonb_build_object('id', b.id, 'enunciado', b.enunciado),
        'seccion_id', pf.seccion_id,
        'similitud',  pf.similitud,
        'propuesto_en', pf.propuesto_en
    ) ORDER BY pf.similitud DESC), '[]'::jsonb) INTO v_rows
      FROM propuestas_fusion pf
      JOIN preguntas a ON a.id = pf.a_id
      JOIN preguntas b ON b.id = pf.b_id
     WHERE pf.estado = 'pendiente'
     LIMIT p_size OFFSET v_off;
    RETURN jsonb_build_object('total', v_total, 'items', v_rows);
END $$;

-- Fusiona la propuesta: mueve marcadores/respuestas/repasos de `b_id` a
-- `a_id`, borra la pregunta `b_id`, y marca la propuesta como fusionada.
-- La sesión de admin debe pasar `p_keep` = 'a' o 'b' según cuál conserva.
CREATE OR REPLACE FUNCTION fusionar_propuesta(
    p_a_id uuid,
    p_b_id uuid,
    p_keep text DEFAULT 'a'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_keep uuid;
    v_drop uuid;
BEGIN
    IF NOT (es_admin() OR tiene_permiso('pregunta.fusionar')) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    IF p_keep NOT IN ('a','b') THEN
        RAISE EXCEPTION 'keep_invalido';
    END IF;
    v_keep := CASE WHEN p_keep = 'a' THEN p_a_id ELSE p_b_id END;
    v_drop := CASE WHEN p_keep = 'a' THEN p_b_id ELSE p_a_id END;

    -- Mueve marcadores y repasos que apunten a la pregunta que se elimina.
    -- `ON CONFLICT` sólo aplica a INSERT: para evitar chocar con la PK
    -- (usuario_id, tipo, pregunta_id) mueve sólo las filas del usuario que
    -- NO tenga ya un marcador del mismo tipo apuntando a v_keep, y borra
    -- las duplicadas al final. Mismo patrón para `repasos` (PK usuario_id,
    -- pregunta_id). `respuestas` no tiene unique compuesta, así que su
    -- UPDATE no puede fallar y va directo.
    UPDATE marcadores m SET pregunta_id = v_keep
     WHERE m.pregunta_id = v_drop
       AND NOT EXISTS (
           SELECT 1 FROM marcadores m2
            WHERE m2.usuario_id = m.usuario_id
              AND m2.tipo       = m.tipo
              AND m2.pregunta_id = v_keep
       );
    DELETE FROM marcadores WHERE pregunta_id = v_drop;

    UPDATE repasos r SET pregunta_id = v_keep
     WHERE r.pregunta_id = v_drop
       AND NOT EXISTS (
           SELECT 1 FROM repasos r2
            WHERE r2.usuario_id  = r.usuario_id
              AND r2.pregunta_id = v_keep
       );
    DELETE FROM repasos WHERE pregunta_id = v_drop;

    UPDATE respuestas SET pregunta_id = v_keep WHERE pregunta_id = v_drop;

    -- Borra la pregunta descartada (los intentos siguen apuntando a la
    -- fila conservada vía respuestas, y question_ids del intento queda
    -- con el uuid huérfano — aceptable, la SPA lo ignora si no existe).
    DELETE FROM preguntas WHERE id = v_drop;

    UPDATE propuestas_fusion
       SET estado = 'fusionada',
           resuelto_por = jwt_usuario_id(),
           resuelto_en  = now()
     WHERE (a_id = p_a_id AND b_id = p_b_id)
        OR (a_id = p_b_id AND b_id = p_a_id);
    RETURN jsonb_build_object('ok', true, 'conservada', v_keep, 'borrada', v_drop);
END $$;

CREATE OR REPLACE FUNCTION descartar_propuesta(p_a_id uuid, p_b_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    IF NOT (es_admin() OR tiene_permiso('pregunta.fusionar')) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    UPDATE propuestas_fusion
       SET estado = 'descartada',
           resuelto_por = jwt_usuario_id(),
           resuelto_en  = now()
     WHERE (a_id = p_a_id AND b_id = p_b_id)
        OR (a_id = p_b_id AND b_id = p_a_id);
    RETURN jsonb_build_object('ok', true);
END $$;

GRANT EXECUTE ON FUNCTION listar_propuestas_fusion(int, int)    TO web_user;
GRANT EXECUTE ON FUNCTION fusionar_propuesta(uuid, uuid, text)  TO web_user;
GRANT EXECUTE ON FUNCTION descartar_propuesta(uuid, uuid)       TO web_user;


-- =============================================================================
--                    BLOQUE D — GAMIFICACIÓN (retos, logros, XP)
-- =============================================================================
-- Se dispara desde el trigger de progreso_seccion. Cada sección completada:
--   1) suma XP y avanza racha,
--   2) bumpea retos "por sección" del periodo actual,
--   3) si es la última sección del módulo, dispara "módulo completado",
--   4) si es el último módulo del tema, dispara "tema completado".
-- El "periodo" (diario/semanal/mensual) se calcula en Europe/Madrid.

CREATE OR REPLACE FUNCTION _periodo_inicio(p_tipo text) RETURNS date
LANGUAGE sql STABLE AS $$
    SELECT CASE p_tipo
        WHEN 'diario'   THEN hoy_madrid()
        WHEN 'semanal'  THEN (date_trunc('week', hoy_madrid()))::date
        WHEN 'mensual'  THEN (date_trunc('month', hoy_madrid()))::date
    END;
$$;

-- Actualiza el progreso del usuario en un reto (identificado por código).
-- Si el reto se completa, marca completado_en y da XP.
CREATE OR REPLACE FUNCTION _gamif_bump_reto(
    p_usuario_id uuid,
    p_codigo     text,
    p_delta      int DEFAULT 1
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_reto  retos_catalogo%ROWTYPE;
    v_ini   date;
    v_nuevo int;
    v_completo bool;
BEGIN
    SELECT * INTO v_reto FROM retos_catalogo WHERE codigo = p_codigo AND activo;
    IF v_reto.id IS NULL THEN RETURN; END IF;
    v_ini := _periodo_inicio(v_reto.periodo);

    INSERT INTO retos_usuario (usuario_id, reto_id, periodo_inicio, progreso)
    VALUES (p_usuario_id, v_reto.id, v_ini, p_delta)
    ON CONFLICT (usuario_id, reto_id, periodo_inicio) DO UPDATE
        SET progreso = retos_usuario.progreso + p_delta,
            actualizado_en = now()
    RETURNING progreso INTO v_nuevo;

    v_completo := v_nuevo >= v_reto.objetivo;
    IF v_completo THEN
        UPDATE retos_usuario
           SET completado_en = COALESCE(completado_en, now())
         WHERE usuario_id = p_usuario_id AND reto_id = v_reto.id
           AND periodo_inicio = v_ini;
        -- Otorgamos XP sólo la primera vez que se completa.
        PERFORM _gamif_dar_xp(p_usuario_id, v_reto.xp);
    END IF;
END $$;

-- Otorga un logro (idempotente). Si ya está obtenido, no repite XP.
CREATE OR REPLACE FUNCTION _gamif_dar_logro(
    p_usuario_id uuid,
    p_codigo     text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_logro logros_catalogo%ROWTYPE;
    v_actual logros_usuario%ROWTYPE;
BEGIN
    SELECT * INTO v_logro FROM logros_catalogo WHERE codigo = p_codigo AND activo;
    IF v_logro.id IS NULL THEN RETURN; END IF;
    SELECT * INTO v_actual FROM logros_usuario
      WHERE usuario_id = p_usuario_id AND logro_id = v_logro.id;
    IF v_actual.obtenido_en IS NOT NULL THEN RETURN; END IF;
    INSERT INTO logros_usuario (usuario_id, logro_id, progreso, obtenido_en)
    VALUES (p_usuario_id, v_logro.id, v_logro.objetivo, now())
    ON CONFLICT (usuario_id, logro_id) DO UPDATE
        SET progreso = v_logro.objetivo, obtenido_en = now();
    PERFORM _gamif_dar_xp(p_usuario_id, v_logro.xp);
END $$;

-- Suma XP al usuario y actualiza racha diaria.
CREATE OR REPLACE FUNCTION _gamif_dar_xp(p_usuario_id uuid, p_delta int)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_hoy  date := hoy_madrid();
    v_prev date;
BEGIN
    IF p_delta <= 0 THEN RETURN; END IF;
    INSERT INTO usuario_gamificacion (usuario_id, xp_total, racha_actual, racha_maxima, ultimo_dia_activo)
    VALUES (p_usuario_id, p_delta, 1, 1, v_hoy)
    ON CONFLICT (usuario_id) DO UPDATE
        SET xp_total = usuario_gamificacion.xp_total + p_delta,
            racha_actual =
                CASE
                    WHEN usuario_gamificacion.ultimo_dia_activo = v_hoy
                        THEN usuario_gamificacion.racha_actual
                    WHEN usuario_gamificacion.ultimo_dia_activo = v_hoy - 1
                        THEN usuario_gamificacion.racha_actual + 1
                    ELSE 1
                END,
            racha_maxima = GREATEST(usuario_gamificacion.racha_maxima,
                CASE
                    WHEN usuario_gamificacion.ultimo_dia_activo = v_hoy
                        THEN usuario_gamificacion.racha_actual
                    WHEN usuario_gamificacion.ultimo_dia_activo = v_hoy - 1
                        THEN usuario_gamificacion.racha_actual + 1
                    ELSE 1
                END),
            ultimo_dia_activo = v_hoy,
            actualizado_en = now();
END $$;


-- Trigger sobre progreso_seccion:
--   * Al pasar completada_en de NULL a NOT NULL (INSERT o UPDATE) → sección completada.
--   * Comprueba cascada de módulo y tema.
CREATE OR REPLACE FUNCTION _gamif_on_progreso_seccion() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := NEW.usuario_id;
    v_modulo uuid; v_tema uuid;
    v_secc_tot int; v_secc_ok int;
    v_mod_tot int; v_mod_ok int;
BEGIN
    IF NEW.completada_en IS NULL THEN RETURN NEW; END IF;
    IF TG_OP = 'UPDATE' AND OLD.completada_en IS NOT NULL THEN
        RETURN NEW;   -- ya se dio la XP la primera vez
    END IF;

    -- Sección completada: XP + retos.
    PERFORM _gamif_dar_xp(v_uid, 25);
    PERFORM _gamif_bump_reto(v_uid, 'diario_completar_1_seccion');
    PERFORM _gamif_bump_reto(v_uid, 'semanal_5_secciones');
    PERFORM _gamif_dar_logro(v_uid, 'primera_seccion');

    -- ¿Se ha completado el módulo?
    SELECT s.modulo_id INTO v_modulo FROM secciones s WHERE s.id = NEW.seccion_id;
    SELECT COUNT(*) INTO v_secc_tot FROM secciones WHERE modulo_id = v_modulo;
    SELECT COUNT(*) INTO v_secc_ok
      FROM secciones s
      JOIN progreso_seccion p ON p.seccion_id = s.id AND p.usuario_id = v_uid
     WHERE s.modulo_id = v_modulo AND p.completada_en IS NOT NULL;

    IF v_secc_tot > 0 AND v_secc_ok >= v_secc_tot THEN
        PERFORM _gamif_dar_xp(v_uid, 80);
        PERFORM _gamif_bump_reto(v_uid, 'semanal_completar_1_modulo');
        PERFORM _gamif_dar_logro(v_uid, 'primer_modulo');

        -- ¿Se ha completado el tema?
        SELECT m.tema_id INTO v_tema FROM modulos m WHERE m.id = v_modulo;
        SELECT COUNT(*) INTO v_mod_tot FROM modulos WHERE tema_id = v_tema;
        SELECT COUNT(*) INTO v_mod_ok
          FROM modulos m
         WHERE m.tema_id = v_tema
           AND (
             SELECT COUNT(*) FROM secciones s WHERE s.modulo_id = m.id
           ) > 0
           AND NOT EXISTS (
             SELECT 1 FROM secciones s
              WHERE s.modulo_id = m.id
                AND NOT EXISTS (
                    SELECT 1 FROM progreso_seccion p
                     WHERE p.seccion_id = s.id AND p.usuario_id = v_uid
                       AND p.completada_en IS NOT NULL
                )
           );
        IF v_mod_tot > 0 AND v_mod_ok >= v_mod_tot THEN
            PERFORM _gamif_dar_xp(v_uid, 300);
            PERFORM _gamif_bump_reto(v_uid, 'mensual_completar_1_tema');
            PERFORM _gamif_dar_logro(v_uid, 'primer_tema');
        END IF;
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER progreso_seccion_gamif
    AFTER INSERT OR UPDATE OF completada_en ON progreso_seccion
    FOR EACH ROW EXECUTE FUNCTION _gamif_on_progreso_seccion();


-- Retos y logros al lector: para el panel de "Retos y logros".
CREATE OR REPLACE FUNCTION mis_retos_activos() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'codigo',      c.codigo,
            'titulo',      c.titulo,
            'descripcion', c.descripcion,
            'periodo',     c.periodo,
            'objetivo',    c.objetivo,
            'xp',          c.xp,
            'icono',       c.icono,
            'progreso',    COALESCE(ru.progreso, 0),
            'completado',  ru.completado_en IS NOT NULL
        ) ORDER BY c.periodo, c.codigo)
        FROM retos_catalogo c
        LEFT JOIN retos_usuario ru
               ON ru.reto_id = c.id
              AND ru.usuario_id = v_uid
              AND ru.periodo_inicio = _periodo_inicio(c.periodo)
        WHERE c.activo
    ), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION mis_logros() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_uid uuid := jwt_usuario_id();
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'codigo',      c.codigo,
            'titulo',      c.titulo,
            'descripcion', c.descripcion,
            'xp',          c.xp,
            'icono',       c.icono,
            'obtenido',    lu.obtenido_en IS NOT NULL,
            'obtenido_en', lu.obtenido_en
        ) ORDER BY c.codigo)
        FROM logros_catalogo c
        LEFT JOIN logros_usuario lu
               ON lu.logro_id = c.id AND lu.usuario_id = v_uid
        WHERE c.activo
    ), '[]'::jsonb);
END $$;

GRANT EXECUTE ON FUNCTION mis_retos_activos()   TO web_user;
GRANT EXECUTE ON FUNCTION mis_logros()          TO web_user;


-- Seed del catálogo de retos y logros nuevos (adaptados a la jerarquía
-- Oposición → Tema → Módulo → Sección).
INSERT INTO retos_catalogo (codigo, titulo, descripcion, periodo, objetivo, xp, icono) VALUES
    ('diario_completar_1_seccion', 'Sección diaria', 'Completa 1 sección hoy',              'diario',   1,  30, '🎯'),
    ('diario_teoria_2_secciones',  'Doble teoría',   'Lee la teoría de 2 secciones',        'diario',   2,  20, '📖'),
    ('diario_acierto_80',          'Precisión 80 %', 'Acierta el 80 % o más en algún test', 'diario',   1,  25, '🎯'),
    ('semanal_5_secciones',        '5 secciones',    'Completa 5 secciones esta semana',    'semanal',  5,  80, '📚'),
    ('semanal_completar_1_modulo', 'Módulo semanal', 'Completa un módulo entero',           'semanal',  1, 150, '🏔️'),
    ('semanal_repaso_global_1',    'Repaso global',  'Haz al menos 1 repaso de 40 pregs',   'semanal',  1,  60, '🔁'),
    ('mensual_completar_1_tema',   'Tema del mes',   'Completa un tema entero este mes',    'mensual',  1, 400, '👑'),
    ('mensual_oposicion_25_pct',   'Avance mensual', 'Avanza +25 % en cualquier oposición', 'mensual',  1, 300, '📈')
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO logros_catalogo (codigo, titulo, descripcion, objetivo, xp, icono) VALUES
    ('primera_seccion',            'Primera sección',           'Completaste tu primera sección',              1, 100, '🥇'),
    ('primer_modulo',              'Primer módulo',             'Completaste tu primer módulo',                1, 200, '🥈'),
    ('primer_tema',                'Primer tema',               'Completaste tu primer tema completo',         1, 500, '🥉'),
    ('primera_oposicion_completa', 'Oposición completa',        'Completaste una oposición entera',            1,1500, '🏆'),
    ('polivalente_3_oposiciones',  'Polivalente',               'Tienes 3 oposiciones activas',                1, 300, '🎓'),
    ('explorador_10_temas',        'Explorador',                'Has abierto teoría de 10 temas distintos',   10, 200, '🧭')
ON CONFLICT (codigo) DO NOTHING;


-- =============================================================================
--                    IMPORT DE CONTENIDO (usado por Fase 4)
-- =============================================================================
-- El script db/migraciones_contenido/mapear.py inserta preguntas nuevas
-- llamando a esta RPC. Devuelve el uuid de la pregunta (existente o nueva).
-- Al ser el hash_contenido UNIQUE, la re-importación del mismo enunciado
-- devuelve la fila ya presente sin duplicar.
CREATE OR REPLACE FUNCTION importar_pregunta(
    p_seccion_id uuid,
    p_enunciado  text,
    p_opciones   jsonb,
    p_explicacion text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
    IF NOT (es_admin() OR tiene_permiso('pregunta.crear')) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
    INSERT INTO preguntas (seccion_id, enunciado, opciones, explicacion, autor_id)
    VALUES (p_seccion_id, p_enunciado, p_opciones, p_explicacion, jwt_usuario_id())
    ON CONFLICT (hash_contenido) DO UPDATE
        -- Si ya existe, dejamos la fila como está pero devolvemos su id.
        SET actualizado_en = preguntas.actualizado_en
    RETURNING id INTO v_id;
    RETURN v_id;
END $$;

GRANT EXECUTE ON FUNCTION importar_pregunta(uuid,text,jsonb,text) TO web_user;


-- =============================================================================
--         BLOQUE D — SELECTOR DE OPOSICIÓN Y PANEL DE ADMINISTRACIÓN
-- =============================================================================
-- Antes vivían en la migración `db/migraciones/2026-07-27_admin_panel_rpcs.sql`.
-- Se han integrado aquí para que cualquier BBDD fresca las traiga desde el
-- primer arranque (evita que la SPA reciba 404 al llamar a
-- `listar_oposiciones_disponibles` / `admin_crear_oposicion` en un entorno
-- recién creado — bug reportado 2026-07-27: "cuando añado una oposición me
-- vuelve al inicio").

-- ── Selector inicial de oposición (autoservicio del usuario) ────────────────

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

CREATE OR REPLACE FUNCTION elegir_oposicion(p_oposicion_id uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_ok  boolean;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
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


-- ── Helper de comprobación para las RPCs de admin ───────────────────────────
CREATE OR REPLACE FUNCTION _admin_o_permiso(p_permiso text) RETURNS void
LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF NOT (es_admin() OR tiene_permiso(p_permiso)) THEN
        RAISE EXCEPTION 'permiso_denegado';
    END IF;
END $$;


-- ── Panel admin — Oposiciones ───────────────────────────────────────────────

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


-- ── Panel admin — Temas ─────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION admin_listar_temas(p_oposicion_id uuid DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
    PERFORM _admin_o_permiso('contenido.editar');
    RETURN COALESCE((
        SELECT jsonb_agg(jsonb_build_object(
            'id',            t.id,
            'nombre',        t.nombre,
            'slug',          t.slug,
            'descripcion',   t.descripcion,
            'n_modulos',     (SELECT count(*) FROM modulos m WHERE m.tema_id = t.id),
            'n_secciones',   (SELECT count(*) FROM secciones s
                               JOIN modulos m ON m.id = s.modulo_id
                              WHERE m.tema_id = t.id),
            'n_preguntas',   (SELECT count(*) FROM preguntas p
                               JOIN secciones s ON s.id = p.seccion_id
                               JOIN modulos m ON m.id = s.modulo_id
                              WHERE m.tema_id = t.id),
            'orden',         ot.orden,
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

CREATE OR REPLACE FUNCTION unaccent_es(p_txt text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
    SELECT translate(
        COALESCE(p_txt, ''),
        'áéíóúÁÉÍÓÚñÑüÜçÇàèìòùÀÈÌÒÙ',
        'aeiouAEIOUnNuUcCaeiouAEIOU'
    );
$$;

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
    WHILE EXISTS (SELECT 1 FROM temas WHERE slug = v_slug) LOOP
        v_slug := v_slug || '-' || substr(gen_random_uuid()::text, 1, 4);
    END LOOP;
    INSERT INTO temas (nombre, slug, descripcion)
    VALUES (btrim(p_nombre), v_slug, NULLIF(btrim(COALESCE(p_descripcion,'')), ''))
    RETURNING id INTO v_id;

    IF p_oposicion_id IS NOT NULL THEN
        SELECT COALESCE(max(orden), 0) + 1 INTO v_ord
          FROM oposicion_temas WHERE oposicion_id = p_oposicion_id;
        INSERT INTO oposicion_temas (oposicion_id, tema_id, orden)
        VALUES (p_oposicion_id, v_id, v_ord)
        ON CONFLICT DO NOTHING;
    END IF;

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


-- ── Panel admin — Módulos ───────────────────────────────────────────────────

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


-- ── Panel admin — Secciones ─────────────────────────────────────────────────

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


-- ── Panel admin — Preguntas ─────────────────────────────────────────────────

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


-- ── Panel admin — Documentos (metadatos de teoría markdown) ─────────────────
CREATE OR REPLACE FUNCTION admin_upsert_documento(
    p_nivel      text,
    p_entidad_id uuid,
    p_tipo       text,
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


-- =============================================================================
-- NOTAS FINALES:
-- * 2FA TOTP: columnas listas; algoritmo pendiente (`_verificar_totp` stub).
-- * Cron de purga: filas de `tokens_verificacion` y `sesiones` caducadas
--   se pueden barrer con un cron simple (WHERE expira_en < now() - N days).
--   No urge en v1 (poco volumen); añadir cuando se prepare el cron general.
-- * Retos y logros nuevos: catálogo en fase 8 (03_seed_retos_logros.sql).
-- =============================================================================
