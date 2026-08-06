-- =============================================================================
-- 01_esquema.sql
--
-- Esquema autoritativo de Aprentix (rediseño orientado a oposiciones).
--
-- El modelo entero gira en torno a la oposición.  Desaparece la
-- separación teoría/tests: la unidad es la pieza atómica que combina
-- ambos.
--
--   oposiciones  ─N:M→  temas (reutilizables)  1:N→  unidades  1:N→  preguntas
--
-- El fichero puede ejecutarse sobre una BBDD vacía o relanzarse sobre una
-- instalación previa. Los objetos simples usan IF NOT EXISTS; triggers y
-- políticas se recrean para aplicar su definición actual. Esto evita errores
-- por objetos existentes, pero no sustituye a migraciones ALTER cuando cambia
-- la estructura de una tabla ya creada.
-- =============================================================================


CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid, crypt/bcrypt, hmac
CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- búsqueda difusa opcional


-- =============================================================================
--                                  IDENTIDAD
-- =============================================================================

CREATE TABLE IF NOT EXISTS usuarios (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- El email es el login. Un trigger lo normaliza a minúsculas antes
    -- de insertar, así el UNIQUE por email es case-insensitive de
    -- facto sin depender de la extensión citext.
    email                  text NOT NULL,
    nombre                 text NOT NULL,
    password_hash          text,                     -- bcrypt (pgcrypto)
    email_verificado       boolean NOT NULL DEFAULT false,
    activo                 boolean NOT NULL DEFAULT true,
    avatar                 text,                     -- URL o iniciales calculadas en la SPA
    creado_en              timestamptz NOT NULL DEFAULT now(),
    UNIQUE (email)
);

CREATE OR REPLACE FUNCTION normalizar_email() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.email IS NOT NULL THEN
        NEW.email := lower(btrim(NEW.email));
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS usuarios_email_normalize ON usuarios;
CREATE TRIGGER usuarios_email_normalize
    BEFORE INSERT OR UPDATE OF email ON usuarios
    FOR EACH ROW EXECUTE FUNCTION normalizar_email();

CREATE TABLE IF NOT EXISTS roles (
    id          text PRIMARY KEY,             -- admin | editor | alumno
    descripcion text
);

CREATE TABLE IF NOT EXISTS permisos (
    id          text PRIMARY KEY,             -- oposicion.gestionar, ...
    descripcion text
);

CREATE TABLE IF NOT EXISTS rol_permisos (
    rol_id      text REFERENCES roles(id)    ON DELETE CASCADE,
    permiso_id  text REFERENCES permisos(id) ON DELETE CASCADE,
    PRIMARY KEY (rol_id, permiso_id)
);

CREATE TABLE IF NOT EXISTS usuario_roles (
    usuario_id  uuid REFERENCES usuarios(id) ON DELETE CASCADE,
    rol_id      text REFERENCES roles(id)    ON DELETE CASCADE,
    PRIMARY KEY (usuario_id, rol_id)
);

-- Tokens para acciones asíncronas por email (confirmación de cuenta y
-- reset de contraseña).  Solo un token vivo por (usuario, tipo).
CREATE TABLE IF NOT EXISTS email_tokens (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id  uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    tipo        text NOT NULL CHECK (tipo IN ('verificar_email','reset_password')),
    token       text NOT NULL UNIQUE,
    expira_en   timestamptz NOT NULL,
    usado_en    timestamptz,
    creado_en   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS email_tokens_activos_idx ON email_tokens (usuario_id, tipo)
    WHERE usado_en IS NULL;


-- =============================================================================
--                             COLAS: EMAILS Y PUSH
-- =============================================================================
-- Dos colas de trabajo (una fila = una notificación a enviar). La BBDD
-- sólo encola; los workers Python (mailer, notificador) consumen.

CREATE TABLE IF NOT EXISTS cola_emails (
    id            bigserial PRIMARY KEY,
    destinatario  text NOT NULL,
    asunto        text NOT NULL,
    cuerpo_txt    text NOT NULL,
    cuerpo_html   text,
    intentos      int  NOT NULL DEFAULT 0,
    max_intentos  int  NOT NULL DEFAULT 5,
    encolado_en   timestamptz NOT NULL DEFAULT now(),
    enviado_en    timestamptz,
    ultimo_error  text
);
CREATE INDEX IF NOT EXISTS cola_emails_pendiente_idx ON cola_emails (encolado_en)
    WHERE enviado_en IS NULL;

CREATE TABLE IF NOT EXISTS cola_push (
    id            bigserial PRIMARY KEY,
    usuario_id    uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    titulo        text NOT NULL,
    cuerpo        text NOT NULL,
    url           text,                       -- destino al pulsar la notificación
    icono         text,                       -- URL de icono opcional
    intentos      int  NOT NULL DEFAULT 0,
    max_intentos  int  NOT NULL DEFAULT 3,
    encolado_en   timestamptz NOT NULL DEFAULT now(),
    enviado_en    timestamptz,
    ultimo_error  text
);
CREATE INDEX IF NOT EXISTS cola_push_pendiente_idx ON cola_push (encolado_en)
    WHERE enviado_en IS NULL;
CREATE INDEX IF NOT EXISTS cola_push_usuario_idx  ON cola_push (usuario_id);


-- =============================================================================
--             OPOSICIONES, TEMAS (REUTILIZABLES) Y UNIDADES
-- =============================================================================

CREATE TABLE IF NOT EXISTS oposiciones (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug         text UNIQUE NOT NULL,
    nombre       text NOT NULL,
    descripcion  text,
    organismo    text,
    activa       boolean NOT NULL DEFAULT true,
    creada_en    timestamptz NOT NULL DEFAULT now(),
    autor_id     uuid REFERENCES usuarios(id) ON DELETE SET NULL
);

-- Un tema es reutilizable: la misma "Constitución Española" puede
-- formar parte de varias oposiciones.  Vive en su propia tabla y se
-- enlaza a las oposiciones vía `oposicion_temas` (N:M) con orden.
CREATE TABLE IF NOT EXISTS temas (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug         text UNIQUE NOT NULL,
    nombre       text NOT NULL,
    descripcion  text,
    icono        text NOT NULL DEFAULT '📘',
    creado_en    timestamptz NOT NULL DEFAULT now(),
    autor_id     uuid REFERENCES usuarios(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS oposicion_temas (
    oposicion_id uuid NOT NULL REFERENCES oposiciones(id) ON DELETE CASCADE,
    tema_id      uuid NOT NULL REFERENCES temas(id)       ON DELETE CASCADE,
    orden        int  NOT NULL,
    PRIMARY KEY (oposicion_id, tema_id),
    UNIQUE (oposicion_id, orden)
);
CREATE INDEX IF NOT EXISTS oposicion_temas_tema_idx ON oposicion_temas (tema_id);

-- Cada tema tiene unidades.  Una unidad contiene teoría (markdown) y
-- puede tener preguntas asociadas para el test de esa unidad.
CREATE TABLE IF NOT EXISTS unidades (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tema_id       uuid NOT NULL REFERENCES temas(id) ON DELETE CASCADE,
    slug          text NOT NULL,
    nombre        text NOT NULL,
    orden         int  NOT NULL,
    teoria_md     text NOT NULL DEFAULT '',   -- markdown renderizado en la SPA
    resumen       text,
    minutos_est   int  NOT NULL DEFAULT 15 CHECK (minutos_est > 0),
    creada_en     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tema_id, slug),
    UNIQUE (tema_id, orden)
);
CREATE INDEX IF NOT EXISTS unidades_tema_idx ON unidades (tema_id);

-- Preguntas SIEMPRE cuelgan de una unidad. Al reutilizar un tema, sus
-- preguntas se reutilizan también.
CREATE TABLE IF NOT EXISTS preguntas (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    unidad_id      uuid NOT NULL REFERENCES unidades(id) ON DELETE CASCADE,
    enunciado      text NOT NULL,
    -- [{"texto": "…", "correcta": true|false}, …]
    opciones       jsonb NOT NULL,
    explicacion    text,
    dificultad     int  NOT NULL DEFAULT 2 CHECK (dificultad BETWEEN 1 AND 5),
    creada_en      timestamptz NOT NULL DEFAULT now(),
    autor_id       uuid REFERENCES usuarios(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS preguntas_unidad_idx ON preguntas (unidad_id);


-- =============================================================================
--                     MATRÍCULA DEL ALUMNO EN OPOSICIONES
-- =============================================================================

CREATE TABLE IF NOT EXISTS usuario_oposiciones (
    usuario_id    uuid NOT NULL REFERENCES usuarios(id)   ON DELETE CASCADE,
    oposicion_id  uuid NOT NULL REFERENCES oposiciones(id) ON DELETE CASCADE,
    matriculado_en timestamptz NOT NULL DEFAULT now(),
    principal     boolean NOT NULL DEFAULT false,
    PRIMARY KEY (usuario_id, oposicion_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS usuario_oposiciones_principal_idx
    ON usuario_oposiciones (usuario_id) WHERE principal;


-- =============================================================================
--                                   ACTIVIDAD
-- =============================================================================

CREATE TABLE IF NOT EXISTS intentos (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id     uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    unidad_id      uuid NOT NULL REFERENCES unidades(id) ON DELETE CASCADE,
    -- Orden congelado de preguntas para poder reanudar sin depender de
    -- cambios posteriores en la unidad.
    question_ids   uuid[] NOT NULL,
    tipo           text NOT NULL DEFAULT 'test'
                     CHECK (tipo IN ('test','repaso','simulacro')),
    iniciado_en    timestamptz NOT NULL DEFAULT now(),
    finalizado_en  timestamptz,
    nota           numeric(5,2)
);
CREATE INDEX IF NOT EXISTS intentos_usuario_idx ON intentos (usuario_id, iniciado_en DESC);
CREATE INDEX IF NOT EXISTS intentos_unidad_idx  ON intentos (unidad_id);

CREATE TABLE IF NOT EXISTS respuestas (
    id             bigserial PRIMARY KEY,
    intento_id     uuid NOT NULL REFERENCES intentos(id)  ON DELETE CASCADE,
    pregunta_id    uuid NOT NULL REFERENCES preguntas(id) ON DELETE CASCADE,
    -- Texto de la opción elegida (no un índice: sobrevive a
    -- reordenaciones dentro de la pregunta).
    opcion_elegida text NOT NULL,
    correcta       boolean NOT NULL,
    respondida_en  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS respuestas_intento_idx ON respuestas (intento_id);

CREATE TABLE IF NOT EXISTS progreso_unidad (
    usuario_id           uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    unidad_id            uuid NOT NULL REFERENCES unidades(id) ON DELETE CASCADE,
    teoria_completada    boolean NOT NULL DEFAULT false,
    teoria_vista_en      timestamptz,
    intentos_test        int  NOT NULL DEFAULT 0,
    mejor_nota           numeric(5,2),
    ultima_nota          numeric(5,2),
    actualizado_en       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (usuario_id, unidad_id)
);
CREATE INDEX IF NOT EXISTS progreso_unidad_usuario_idx ON progreso_unidad (usuario_id);

CREATE TABLE IF NOT EXISTS marcadores (
    usuario_id     uuid NOT NULL REFERENCES usuarios(id)  ON DELETE CASCADE,
    tipo           text NOT NULL CHECK (tipo IN ('fallo','favorita')),
    pregunta_id    uuid NOT NULL REFERENCES preguntas(id) ON DELETE CASCADE,
    contador       int  NOT NULL DEFAULT 1,
    actualizado_en timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (usuario_id, tipo, pregunta_id)
);


-- =============================================================================
--                              PLAN DE ESTUDIO
-- =============================================================================
-- La generación real del plan llegará en una siguiente iteración. Aquí
-- ya hay dónde guardar las respuestas del wizard (disponibilidad,
-- fecha del examen, ritmo…) y las sesiones diarias.

CREATE TABLE IF NOT EXISTS plan_estudio (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id      uuid NOT NULL REFERENCES usuarios(id)   ON DELETE CASCADE,
    oposicion_id    uuid NOT NULL REFERENCES oposiciones(id) ON DELETE CASCADE,
    fecha_examen    date,
    horas_dia       numeric(4,2) NOT NULL DEFAULT 2 CHECK (horas_dia > 0),
    -- 7 booleans (lun..dom) con qué días del semana estudia.
    dias_semana     boolean[] NOT NULL DEFAULT ARRAY[true,true,true,true,true,true,false],
    ritmo           text NOT NULL DEFAULT 'normal'
                       CHECK (ritmo IN ('relajado','normal','intensivo')),
    metodo          text NOT NULL DEFAULT 'cortas'
                       CHECK (metodo IN ('cortas','profundas')),
    activo          boolean NOT NULL DEFAULT true,
    creado_en       timestamptz NOT NULL DEFAULT now(),
    actualizado_en  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (usuario_id, oposicion_id)
);
CREATE INDEX IF NOT EXISTS plan_estudio_usuario_idx ON plan_estudio (usuario_id) WHERE activo;

CREATE TABLE IF NOT EXISTS plan_sesiones (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_id       uuid NOT NULL REFERENCES plan_estudio(id) ON DELETE CASCADE,
    fecha         date NOT NULL,
    hora_inicio   time,
    minutos       int  NOT NULL DEFAULT 25 CHECK (minutos > 0),
    unidad_id     uuid REFERENCES unidades(id) ON DELETE SET NULL,
    tipo          text NOT NULL DEFAULT 'estudio'
                    CHECK (tipo IN ('estudio','repaso','test','descanso','simulacro')),
    completada    boolean NOT NULL DEFAULT false,
    completada_en timestamptz,
    nota_libre    text
);
CREATE INDEX IF NOT EXISTS plan_sesiones_plan_fecha_idx ON plan_sesiones (plan_id, fecha);


-- =============================================================================
--                     GAMIFICACIÓN — retos, logros, XP, racha
-- =============================================================================
-- Retos con periodo (diario/semanal/mensual): no hace falta un cron
-- para "resetearlos" porque la PK incluye `periodo_inicio` (día actual,
-- lunes de la semana, primer día del mes).  Cambiar de periodo crea
-- una fila nueva sin tocar la anterior.

CREATE TABLE IF NOT EXISTS retos_catalogo (
    id           serial PRIMARY KEY,
    codigo       text UNIQUE NOT NULL,
    titulo       text NOT NULL,
    descripcion  text NOT NULL,
    periodo      text NOT NULL CHECK (periodo IN ('diario','semanal','mensual')),
    objetivo     int  NOT NULL CHECK (objetivo > 0),
    xp           int  NOT NULL DEFAULT 20,
    icono        text NOT NULL DEFAULT '🎯',
    activo       boolean NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS retos_usuario (
    usuario_id     uuid NOT NULL REFERENCES usuarios(id)      ON DELETE CASCADE,
    reto_id        int  NOT NULL REFERENCES retos_catalogo(id) ON DELETE CASCADE,
    periodo_inicio date NOT NULL,
    progreso       int  NOT NULL DEFAULT 0,
    completado_en  timestamptz,
    PRIMARY KEY (usuario_id, reto_id, periodo_inicio)
);
CREATE INDEX IF NOT EXISTS retos_usuario_uid_idx ON retos_usuario (usuario_id, periodo_inicio DESC);

CREATE TABLE IF NOT EXISTS logros_catalogo (
    id           serial PRIMARY KEY,
    codigo       text UNIQUE NOT NULL,
    titulo       text NOT NULL,
    descripcion  text NOT NULL,
    objetivo     int  NOT NULL DEFAULT 1,
    xp           int  NOT NULL DEFAULT 100,
    icono        text NOT NULL DEFAULT '🏆',
    activo       boolean NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS logros_usuario (
    usuario_id  uuid NOT NULL REFERENCES usuarios(id)       ON DELETE CASCADE,
    logro_id    int  NOT NULL REFERENCES logros_catalogo(id) ON DELETE CASCADE,
    progreso    int  NOT NULL DEFAULT 0,
    obtenido_en timestamptz,
    PRIMARY KEY (usuario_id, logro_id)
);

CREATE TABLE IF NOT EXISTS usuario_gamificacion (
    usuario_id        uuid PRIMARY KEY REFERENCES usuarios(id) ON DELETE CASCADE,
    xp_total          int  NOT NULL DEFAULT 0,
    racha_actual      int  NOT NULL DEFAULT 0,
    racha_maxima      int  NOT NULL DEFAULT 0,
    ultimo_dia_activo date,
    actualizado_en    timestamptz NOT NULL DEFAULT now()
);


-- =============================================================================
--                          CONFIG Y NOTIFICACIONES PUSH
-- =============================================================================

CREATE TABLE IF NOT EXISTS config (
    clave  text PRIMARY KEY,
    valor  jsonb
);

CREATE TABLE IF NOT EXISTS push_suscripciones (
    endpoint     text PRIMARY KEY,
    usuario_id   uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    p256dh       text NOT NULL,
    auth         text NOT NULL,
    ua           text,
    tz           text NOT NULL DEFAULT 'Europe/Madrid',
    activa       boolean NOT NULL DEFAULT true,
    creada_en    timestamptz NOT NULL DEFAULT now(),
    ultima_ok_en timestamptz,
    ultimo_error text
);
CREATE INDEX IF NOT EXISTS push_suscripciones_usuario_idx
    ON push_suscripciones (usuario_id) WHERE activa;


-- =============================================================================
--                             ROLES POSTGRES Y GRANTS
-- =============================================================================

DO $crear_roles$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'web_anon') THEN
        CREATE ROLE web_anon NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'web_user') THEN
        CREATE ROLE web_user NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'autenticador') THEN
        CREATE ROLE autenticador LOGIN;
    END IF;
END
$crear_roles$;

-- Asegura los atributos esperados también cuando los roles ya existían.
ALTER ROLE web_anon NOLOGIN;
ALTER ROLE web_user NOLOGIN;
ALTER ROLE autenticador LOGIN;

GRANT web_anon, web_user TO autenticador;

GRANT USAGE ON SCHEMA public TO web_anon, web_user;

-- Lectura del catálogo básico incluso sin sesión.
GRANT SELECT ON roles, permisos, rol_permisos TO web_anon, web_user;

GRANT SELECT ON usuarios TO web_user;
GRANT SELECT ON oposiciones, temas, oposicion_temas, unidades, preguntas TO web_user;
GRANT SELECT, INSERT, UPDATE, DELETE
    ON oposiciones, temas, oposicion_temas, unidades, preguntas,
       usuario_oposiciones,
       intentos, respuestas, marcadores,
       progreso_unidad,
       plan_estudio, plan_sesiones,
       retos_usuario, logros_usuario, usuario_gamificacion,
       push_suscripciones
    TO web_user;
GRANT SELECT ON retos_catalogo, logros_catalogo TO web_user;

-- Config: lectura pública, escritura solo admin (vía RLS).
GRANT SELECT ON config TO web_anon, web_user;
GRANT INSERT, UPDATE, DELETE ON config TO web_user;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO web_user;


-- =============================================================================
--                                     RLS
-- =============================================================================

ALTER TABLE usuarios              ENABLE ROW LEVEL SECURITY;
ALTER TABLE oposiciones           ENABLE ROW LEVEL SECURITY;
ALTER TABLE temas                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE oposicion_temas       ENABLE ROW LEVEL SECURITY;
ALTER TABLE unidades              ENABLE ROW LEVEL SECURITY;
ALTER TABLE preguntas             ENABLE ROW LEVEL SECURITY;
ALTER TABLE usuario_oposiciones   ENABLE ROW LEVEL SECURITY;
ALTER TABLE intentos              ENABLE ROW LEVEL SECURITY;
ALTER TABLE respuestas            ENABLE ROW LEVEL SECURITY;
ALTER TABLE marcadores            ENABLE ROW LEVEL SECURITY;
ALTER TABLE progreso_unidad       ENABLE ROW LEVEL SECURITY;
ALTER TABLE plan_estudio          ENABLE ROW LEVEL SECURITY;
ALTER TABLE plan_sesiones         ENABLE ROW LEVEL SECURITY;
ALTER TABLE retos_catalogo        ENABLE ROW LEVEL SECURITY;
ALTER TABLE logros_catalogo       ENABLE ROW LEVEL SECURITY;
ALTER TABLE retos_usuario         ENABLE ROW LEVEL SECURITY;
ALTER TABLE logros_usuario        ENABLE ROW LEVEL SECURITY;
ALTER TABLE usuario_gamificacion  ENABLE ROW LEVEL SECURITY;
ALTER TABLE config                ENABLE ROW LEVEL SECURITY;
ALTER TABLE push_suscripciones    ENABLE ROW LEVEL SECURITY;


-- =============================================================================
--                     HELPERS DE JWT, RBAC Y FIRMA DE TOKENS
-- =============================================================================
-- Firma JWT HS256 en SQL puro sobre pgcrypto (evita depender de pgjwt).

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
--                                POLÍTICAS RLS
-- =============================================================================

DROP POLICY IF EXISTS usr_self ON usuarios;
CREATE POLICY usr_self       ON usuarios FOR SELECT USING (id = jwt_usuario_id() OR es_admin());
DROP POLICY IF EXISTS usr_admin_all ON usuarios;
CREATE POLICY usr_admin_all  ON usuarios FOR ALL TO web_user USING (es_admin()) WITH CHECK (es_admin());

DROP POLICY IF EXISTS opos_lectura ON oposiciones;
CREATE POLICY opos_lectura ON oposiciones FOR SELECT USING (activa OR jwt_usuario_id() IS NOT NULL);
DROP POLICY IF EXISTS opos_insert ON oposiciones;
CREATE POLICY opos_insert  ON oposiciones FOR INSERT WITH CHECK (tiene_permiso('oposicion.gestionar'));
DROP POLICY IF EXISTS opos_update ON oposiciones;
CREATE POLICY opos_update  ON oposiciones FOR UPDATE USING (tiene_permiso('oposicion.gestionar'));
DROP POLICY IF EXISTS opos_delete ON oposiciones;
CREATE POLICY opos_delete  ON oposiciones FOR DELETE USING (tiene_permiso('oposicion.gestionar'));

DROP POLICY IF EXISTS tema_lectura ON temas;
CREATE POLICY tema_lectura ON temas FOR SELECT USING (jwt_usuario_id() IS NOT NULL);
DROP POLICY IF EXISTS tema_admin ON temas;
CREATE POLICY tema_admin   ON temas FOR ALL TO web_user
    USING (tiene_permiso('oposicion.gestionar'))
    WITH CHECK (tiene_permiso('oposicion.gestionar'));

DROP POLICY IF EXISTS ot_lectura ON oposicion_temas;
CREATE POLICY ot_lectura  ON oposicion_temas FOR SELECT USING (jwt_usuario_id() IS NOT NULL);
DROP POLICY IF EXISTS ot_admin ON oposicion_temas;
CREATE POLICY ot_admin    ON oposicion_temas FOR ALL TO web_user
    USING (tiene_permiso('oposicion.gestionar'))
    WITH CHECK (tiene_permiso('oposicion.gestionar'));

DROP POLICY IF EXISTS unid_lectura ON unidades;
CREATE POLICY unid_lectura ON unidades FOR SELECT USING (jwt_usuario_id() IS NOT NULL);
DROP POLICY IF EXISTS unid_admin ON unidades;
CREATE POLICY unid_admin   ON unidades FOR ALL TO web_user
    USING (tiene_permiso('oposicion.gestionar'))
    WITH CHECK (tiene_permiso('oposicion.gestionar'));

DROP POLICY IF EXISTS preg_lectura ON preguntas;
CREATE POLICY preg_lectura ON preguntas FOR SELECT USING (jwt_usuario_id() IS NOT NULL);
DROP POLICY IF EXISTS preg_admin ON preguntas;
CREATE POLICY preg_admin   ON preguntas FOR ALL TO web_user
    USING (tiene_permiso('oposicion.gestionar'))
    WITH CHECK (tiene_permiso('oposicion.gestionar'));

DROP POLICY IF EXISTS uo_propias ON usuario_oposiciones;
CREATE POLICY uo_propias ON usuario_oposiciones
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());

DROP POLICY IF EXISTS intentos_propios ON intentos;
CREATE POLICY intentos_propios ON intentos
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id() OR es_admin());

DROP POLICY IF EXISTS respuestas_propias ON respuestas;
CREATE POLICY respuestas_propias ON respuestas
    USING (EXISTS (SELECT 1 FROM intentos i
                    WHERE i.id = respuestas.intento_id
                      AND (i.usuario_id = jwt_usuario_id() OR es_admin())))
    WITH CHECK (EXISTS (SELECT 1 FROM intentos i
                         WHERE i.id = respuestas.intento_id
                           AND i.usuario_id = jwt_usuario_id()));

DROP POLICY IF EXISTS marcadores_propios ON marcadores;
CREATE POLICY marcadores_propios ON marcadores
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());

DROP POLICY IF EXISTS progreso_propio ON progreso_unidad;
CREATE POLICY progreso_propio ON progreso_unidad
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());

DROP POLICY IF EXISTS plan_propio ON plan_estudio;
CREATE POLICY plan_propio ON plan_estudio
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());

DROP POLICY IF EXISTS plan_ses_propio ON plan_sesiones;
CREATE POLICY plan_ses_propio ON plan_sesiones
    USING (EXISTS (SELECT 1 FROM plan_estudio p
                    WHERE p.id = plan_sesiones.plan_id
                      AND (p.usuario_id = jwt_usuario_id() OR es_admin())))
    WITH CHECK (EXISTS (SELECT 1 FROM plan_estudio p
                         WHERE p.id = plan_sesiones.plan_id
                           AND p.usuario_id = jwt_usuario_id()));

DROP POLICY IF EXISTS retos_cat_lectura ON retos_catalogo;
CREATE POLICY retos_cat_lectura ON retos_catalogo FOR SELECT
    USING (jwt_usuario_id() IS NOT NULL);
DROP POLICY IF EXISTS retos_cat_admin ON retos_catalogo;
CREATE POLICY retos_cat_admin ON retos_catalogo FOR ALL TO web_user
    USING (es_admin()) WITH CHECK (es_admin());
DROP POLICY IF EXISTS logros_cat_lectura ON logros_catalogo;
CREATE POLICY logros_cat_lectura ON logros_catalogo FOR SELECT
    USING (jwt_usuario_id() IS NOT NULL);
DROP POLICY IF EXISTS logros_cat_admin ON logros_catalogo;
CREATE POLICY logros_cat_admin ON logros_catalogo FOR ALL TO web_user
    USING (es_admin()) WITH CHECK (es_admin());

DROP POLICY IF EXISTS retos_usr_propios ON retos_usuario;
CREATE POLICY retos_usr_propios ON retos_usuario
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());
DROP POLICY IF EXISTS logros_usr_propios ON logros_usuario;
CREATE POLICY logros_usr_propios ON logros_usuario
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());
DROP POLICY IF EXISTS gamif_propia ON usuario_gamificacion;
CREATE POLICY gamif_propia ON usuario_gamificacion
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());

DROP POLICY IF EXISTS config_lectura ON config;
CREATE POLICY config_lectura ON config FOR SELECT USING (true);
DROP POLICY IF EXISTS config_admin ON config;
CREATE POLICY config_admin   ON config FOR ALL TO web_user
    USING (es_admin()) WITH CHECK (es_admin());

DROP POLICY IF EXISTS push_sus_propias ON push_suscripciones;
CREATE POLICY push_sus_propias ON push_suscripciones
    FOR ALL TO web_user
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());


-- =============================================================================
--                        DEFAULTS DEPENDIENTES DEL JWT
-- =============================================================================

ALTER TABLE intentos             ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE marcadores           ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE progreso_unidad      ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE plan_estudio         ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE retos_usuario        ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE logros_usuario       ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE usuario_gamificacion ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE push_suscripciones   ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();
ALTER TABLE preguntas            ALTER COLUMN autor_id   SET DEFAULT jwt_usuario_id();
ALTER TABLE oposiciones          ALTER COLUMN autor_id   SET DEFAULT jwt_usuario_id();
ALTER TABLE temas                ALTER COLUMN autor_id   SET DEFAULT jwt_usuario_id();


-- =============================================================================
--                                 AUTENTICACIÓN
-- =============================================================================
-- El login es el email. Hasta confirmarlo, no se puede iniciar sesión.
-- app_url() se lee de config('app_url') para no hard-codear el dominio
-- en el SQL — en dev / desa / prod cambia solo el valor.

CREATE OR REPLACE FUNCTION app_url() RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT valor #>> '{}' FROM config WHERE clave = 'app_url'),
        'http://localhost'
    );
$$;

CREATE OR REPLACE FUNCTION registrar_web(
    p_email    text,
    p_password text,
    p_nombre   text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $registrar_web$
DECLARE
    v_email  text := lower(btrim(p_email));
    v_nombre text := COALESCE(NULLIF(btrim(p_nombre), ''), split_part(v_email, '@', 1));
    v_id     uuid;
    v_token  text;
BEGIN
    IF v_email IS NULL OR position('@' IN v_email) = 0 THEN
        RAISE EXCEPTION 'email_invalido';
    END IF;
    IF length(p_password) < 8 THEN
        RAISE EXCEPTION 'password_debil';
    END IF;
    IF EXISTS (SELECT 1 FROM usuarios WHERE email = v_email) THEN
        RAISE EXCEPTION 'email_registrado';
    END IF;

    INSERT INTO usuarios(email, nombre, password_hash, email_verificado)
    VALUES (v_email, v_nombre, crypt(p_password, gen_salt('bf', 12)), false)
    RETURNING id INTO v_id;

    INSERT INTO usuario_roles(usuario_id, rol_id) VALUES (v_id, 'alumno');
    INSERT INTO usuario_gamificacion(usuario_id) VALUES (v_id);

    v_token := encode(gen_random_bytes(32), 'hex');
    INSERT INTO email_tokens(usuario_id, tipo, token, expira_en)
    VALUES (v_id, 'verificar_email', v_token, now() + interval '3 days');

    INSERT INTO cola_emails(destinatario, asunto, cuerpo_txt, cuerpo_html)
    VALUES (
        v_email,
        'Confirma tu cuenta en Aprentix',
        format(E'Hola %s,\n\nConfirma tu cuenta abriendo este enlace:\n%s/#/verify?token=%s\n\nEl enlace caduca en 3 días.\n\n— Aprentix',
               v_nombre, app_url(), v_token),
        -- Etiqueta $html$ para separar claramente el bloque HTML del
        -- delimitador exterior usado por esta función.
        format($html$<p>Hola <strong>%s</strong>,</p>
<p>Confirma tu cuenta pulsando el botón:</p>
<p><a href="%s/#/verify?token=%s" style="background:#6B8E23;color:#fff;padding:12px 22px;border-radius:22px;text-decoration:none;display:inline-block">Confirmar mi cuenta</a></p>
<p>O copia este enlace en tu navegador:<br><code>%s/#/verify?token=%s</code></p>
<p style="color:#62705A">El enlace caduca en 3 días.</p>
<p style="color:#62705A">— Equipo Aprentix</p>$html$,
               v_nombre, app_url(), v_token, app_url(), v_token)
    );

    RETURN jsonb_build_object('ok', true, 'user_id', v_id, 'requiere_verificacion', true);
END $registrar_web$;

CREATE OR REPLACE FUNCTION reenviar_verificacion(p_email text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_email text := lower(btrim(p_email));
    v_usr   usuarios;
    v_token text;
BEGIN
    SELECT * INTO v_usr FROM usuarios WHERE email = v_email;
    -- Silencioso aunque la cuenta no exista, para no filtrar emails.
    IF v_usr.id IS NULL OR v_usr.email_verificado THEN
        RETURN jsonb_build_object('ok', true);
    END IF;

    UPDATE email_tokens SET usado_en = now()
     WHERE usuario_id = v_usr.id AND tipo = 'verificar_email' AND usado_en IS NULL;

    v_token := encode(gen_random_bytes(32), 'hex');
    INSERT INTO email_tokens(usuario_id, tipo, token, expira_en)
    VALUES (v_usr.id, 'verificar_email', v_token, now() + interval '3 days');

    INSERT INTO cola_emails(destinatario, asunto, cuerpo_txt, cuerpo_html)
    VALUES (
        v_email,
        'Nuevo enlace para confirmar tu cuenta',
        format(E'Aquí tienes un enlace nuevo para confirmar tu cuenta:\n%s/#/verify?token=%s\n',
               app_url(), v_token),
        format('<p>Aquí tienes un enlace nuevo para confirmar tu cuenta:</p><p><a href="%s/#/verify?token=%s">Confirmar mi cuenta</a></p>',
               app_url(), v_token)
    );
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION verificar_email(p_token text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_tok email_tokens;
BEGIN
    SELECT * INTO v_tok FROM email_tokens
     WHERE token = p_token AND tipo = 'verificar_email';
    IF v_tok.id IS NULL OR v_tok.usado_en IS NOT NULL OR v_tok.expira_en < now() THEN
        RAISE EXCEPTION 'token_invalido';
    END IF;
    UPDATE usuarios SET email_verificado = true WHERE id = v_tok.usuario_id;
    UPDATE email_tokens SET usado_en = now() WHERE id = v_tok.id;
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION login_web(p_email text, p_password text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_email   text := lower(btrim(p_email));
    v_usr     usuarios;
    v_roles   text[];
    v_payload jsonb;
    v_secret  text := current_setting('app.jwt_secret');
    v_token   text;
BEGIN
    SELECT * INTO v_usr FROM usuarios WHERE email = v_email AND activo;
    IF v_usr.password_hash IS NULL
       OR v_usr.password_hash <> crypt(p_password, v_usr.password_hash) THEN
        RAISE EXCEPTION 'credenciales_invalidas';
    END IF;
    IF NOT v_usr.email_verificado THEN
        RAISE EXCEPTION 'email_no_verificado';
    END IF;

    SELECT COALESCE(array_agg(rol_id), ARRAY[]::text[])
      INTO v_roles FROM usuario_roles WHERE usuario_id = v_usr.id;

    v_payload := jsonb_build_object(
        'sub',   v_usr.id,
        'role',  'web_user',
        'roles', v_roles,
        'exp',   extract(epoch FROM now() + interval '12 hours')::int
    );
    v_token := firmar_jwt(v_payload, v_secret);
    RETURN jsonb_build_object(
        'token',    v_token,
        'user_id',  v_usr.id,
        'email',    v_usr.email,
        'nombre',   v_usr.nombre,
        'roles',    v_roles,
        'es_admin', 'admin' = ANY(v_roles)
    );
END $$;


-- =============================================================================
--                    IMPORTACIÓN DE OPOSICIONES DESDE JSON
-- =============================================================================
-- Recibe un JSON como el de db/ejemplo_oposicion.json.  Los temas se
-- identifican por `slug`: si ya existen, se reutilizan (no se pisan
-- unidades ni preguntas).  Si son nuevos, se crean con todas sus
-- unidades y preguntas.

CREATE OR REPLACE FUNCTION importar_oposicion(p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_opos_id   uuid;
    v_tema      jsonb;
    v_tema_id   uuid;
    v_tema_new  boolean;
    v_unidad    jsonb;
    v_unid_id   uuid;
    v_preg      jsonb;
    v_creadas   int := 0;
    v_reutil    int := 0;
    v_orden     int;
BEGIN
    IF NOT (tiene_permiso('oposicion.gestionar') OR es_admin()) THEN
        RAISE EXCEPTION 'no_autorizado';
    END IF;

    IF p_payload->>'slug' IS NULL OR p_payload->>'nombre' IS NULL THEN
        RAISE EXCEPTION 'payload_invalido: falta slug o nombre';
    END IF;

    INSERT INTO oposiciones(slug, nombre, descripcion, organismo)
    VALUES (
        p_payload->>'slug',
        p_payload->>'nombre',
        p_payload->>'descripcion',
        p_payload->>'organismo'
    )
    ON CONFLICT (slug) DO UPDATE
       SET nombre      = EXCLUDED.nombre,
           descripcion = EXCLUDED.descripcion,
           organismo   = EXCLUDED.organismo
    RETURNING id INTO v_opos_id;

    -- Se desenganchan los temas anteriores de esta oposición (no se
    -- borran de la tabla temas: otras oposiciones pueden usarlos).
    DELETE FROM oposicion_temas WHERE oposicion_id = v_opos_id;

    FOR v_tema IN SELECT * FROM jsonb_array_elements(COALESCE(p_payload->'temas', '[]'::jsonb))
    LOOP
        v_orden := COALESCE((v_tema->>'orden')::int,
                            (SELECT COALESCE(max(orden), 0) + 1
                               FROM oposicion_temas WHERE oposicion_id = v_opos_id));

        SELECT id INTO v_tema_id FROM temas WHERE slug = v_tema->>'slug';
        v_tema_new := v_tema_id IS NULL;

        IF v_tema_new THEN
            INSERT INTO temas(slug, nombre, descripcion, icono)
            VALUES (
                v_tema->>'slug',
                v_tema->>'nombre',
                v_tema->>'descripcion',
                COALESCE(v_tema->>'icono', '📘')
            )
            RETURNING id INTO v_tema_id;
            v_creadas := v_creadas + 1;
        ELSE
            v_reutil := v_reutil + 1;
        END IF;

        INSERT INTO oposicion_temas(oposicion_id, tema_id, orden)
        VALUES (v_opos_id, v_tema_id, v_orden)
        ON CONFLICT (oposicion_id, tema_id) DO UPDATE SET orden = EXCLUDED.orden;

        -- Solo se importan unidades si el tema es NUEVO (no pisamos
        -- material existente al reutilizar un tema).
        IF v_tema_new THEN
            FOR v_unidad IN SELECT * FROM jsonb_array_elements(COALESCE(v_tema->'unidades', '[]'::jsonb))
            LOOP
                INSERT INTO unidades(tema_id, slug, nombre, orden, teoria_md, resumen, minutos_est)
                VALUES (
                    v_tema_id,
                    v_unidad->>'slug',
                    v_unidad->>'nombre',
                    COALESCE((v_unidad->>'orden')::int,
                             (SELECT COALESCE(max(orden), 0) + 1
                                FROM unidades WHERE tema_id = v_tema_id)),
                    COALESCE(v_unidad->>'teoria_md', ''),
                    v_unidad->>'resumen',
                    COALESCE((v_unidad->>'minutos_est')::int, 20)
                )
                RETURNING id INTO v_unid_id;

                FOR v_preg IN SELECT * FROM jsonb_array_elements(COALESCE(v_unidad->'preguntas', '[]'::jsonb))
                LOOP
                    INSERT INTO preguntas(unidad_id, enunciado, opciones, explicacion, dificultad)
                    VALUES (
                        v_unid_id,
                        v_preg->>'enunciado',
                        v_preg->'opciones',
                        v_preg->>'explicacion',
                        COALESCE((v_preg->>'dificultad')::int, 2)
                    );
                END LOOP;
            END LOOP;
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'oposicion_id',       v_opos_id,
        'temas_nuevos',       v_creadas,
        'temas_reutilizados', v_reutil
    );
END $$;


-- =============================================================================
--               CATÁLOGO DE OPOSICIONES, TEMAS Y UNIDADES (LECTURA)
-- =============================================================================

CREATE OR REPLACE FUNCTION listar_oposiciones() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(row_to_json(x) ORDER BY x.nombre), '[]'::jsonb)
      FROM (
        SELECT o.id, o.slug, o.nombre, o.descripcion, o.organismo,
               (SELECT count(*) FROM oposicion_temas ot WHERE ot.oposicion_id = o.id) AS num_temas,
               EXISTS (
                 SELECT 1 FROM usuario_oposiciones uo
                  WHERE uo.usuario_id = jwt_usuario_id() AND uo.oposicion_id = o.id
               ) AS matriculado,
               EXISTS (
                 SELECT 1 FROM usuario_oposiciones uo
                  WHERE uo.usuario_id = jwt_usuario_id() AND uo.oposicion_id = o.id AND uo.principal
               ) AS principal
          FROM oposiciones o
         WHERE o.activa
      ) x;
$$;

CREATE OR REPLACE FUNCTION obtener_oposicion(p_oposicion_id uuid) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    WITH temas_agg AS (
        SELECT
            ot.orden,
            t.id AS tema_id,
            t.slug, t.nombre, t.descripcion, t.icono,
            (SELECT count(*) FROM unidades u WHERE u.tema_id = t.id) AS num_unidades,
            (SELECT COALESCE(sum(u.minutos_est), 0) FROM unidades u WHERE u.tema_id = t.id) AS minutos_est,
            (SELECT count(*)
               FROM unidades u
               JOIN progreso_unidad p ON p.unidad_id = u.id
              WHERE u.tema_id = t.id
                AND p.usuario_id = jwt_usuario_id()
                AND p.teoria_completada) AS unidades_hechas
          FROM oposicion_temas ot
          JOIN temas t ON t.id = ot.tema_id
         WHERE ot.oposicion_id = p_oposicion_id
    )
    SELECT jsonb_build_object(
        'id',          o.id,
        'slug',        o.slug,
        'nombre',      o.nombre,
        'descripcion', o.descripcion,
        'organismo',   o.organismo,
        'temas',       COALESCE(
                           (SELECT jsonb_agg(row_to_json(ta) ORDER BY ta.orden) FROM temas_agg ta),
                           '[]'::jsonb
                       )
    )
    FROM oposiciones o WHERE o.id = p_oposicion_id;
$$;

CREATE OR REPLACE FUNCTION obtener_tema(p_tema_id uuid) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'id',           t.id,
        'slug',         t.slug,
        'nombre',       t.nombre,
        'descripcion',  t.descripcion,
        'icono',        t.icono,
        'unidades',     COALESCE(
            (SELECT jsonb_agg(jsonb_build_object(
                       'id',                u.id,
                       'slug',              u.slug,
                       'nombre',            u.nombre,
                       'orden',             u.orden,
                       'resumen',           u.resumen,
                       'minutos_est',       u.minutos_est,
                       'num_preguntas',     (SELECT count(*) FROM preguntas p WHERE p.unidad_id = u.id),
                       'teoria_completada', COALESCE(pu.teoria_completada, false),
                       'ultima_nota',       pu.ultima_nota,
                       'mejor_nota',        pu.mejor_nota
                   ) ORDER BY u.orden)
               FROM unidades u
          LEFT JOIN progreso_unidad pu
                 ON pu.unidad_id = u.id AND pu.usuario_id = jwt_usuario_id()
              WHERE u.tema_id = t.id),
            '[]'::jsonb
        )
    ) FROM temas t WHERE t.id = p_tema_id;
$$;

CREATE OR REPLACE FUNCTION obtener_unidad(p_unidad_id uuid) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'id',            u.id,
        'tema_id',       u.tema_id,
        'nombre',        u.nombre,
        'orden',         u.orden,
        'teoria_md',     u.teoria_md,
        'minutos_est',   u.minutos_est,
        'num_preguntas', (SELECT count(*) FROM preguntas p WHERE p.unidad_id = u.id),
        'progreso',      COALESCE(row_to_json(pu)::jsonb, '{}'::jsonb)
    )
    FROM unidades u
    LEFT JOIN progreso_unidad pu
           ON pu.unidad_id = u.id AND pu.usuario_id = jwt_usuario_id()
    WHERE u.id = p_unidad_id;
$$;


-- =============================================================================
--                          MATRÍCULA (elegir oposiciones)
-- =============================================================================

CREATE OR REPLACE FUNCTION matricular_oposicion(p_oposicion_id uuid,
                                                p_principal boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_uid uuid := jwt_usuario_id();
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    IF p_principal THEN
        UPDATE usuario_oposiciones SET principal = false
         WHERE usuario_id = v_uid AND principal;
    END IF;
    INSERT INTO usuario_oposiciones(usuario_id, oposicion_id, principal)
    VALUES (v_uid, p_oposicion_id, p_principal)
    ON CONFLICT (usuario_id, oposicion_id)
      DO UPDATE SET principal = EXCLUDED.principal OR usuario_oposiciones.principal;
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION mis_oposiciones() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(row_to_json(x) ORDER BY x.principal DESC, x.nombre), '[]'::jsonb)
      FROM (
        SELECT o.id, o.slug, o.nombre, o.descripcion, o.organismo,
               uo.principal, uo.matriculado_en
          FROM usuario_oposiciones uo
          JOIN oposiciones o ON o.id = uo.oposicion_id
         WHERE uo.usuario_id = jwt_usuario_id() AND o.activa
      ) x;
$$;


-- =============================================================================
--                MOTOR DE TESTS (iniciar / responder / finalizar)
-- =============================================================================

CREATE OR REPLACE FUNCTION iniciar_test_unidad(p_unidad_id uuid,
                                                p_n int DEFAULT 15,
                                                p_tipo text DEFAULT 'test')
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_uid    uuid := jwt_usuario_id();
    v_ids    uuid[];
    v_int_id uuid;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;

    SELECT ARRAY(SELECT id FROM preguntas
                  WHERE unidad_id = p_unidad_id
                  ORDER BY random() LIMIT p_n)
      INTO v_ids;
    IF cardinality(v_ids) = 0 THEN RAISE EXCEPTION 'unidad_sin_preguntas'; END IF;

    INSERT INTO intentos(unidad_id, question_ids, tipo)
    VALUES (p_unidad_id, v_ids, p_tipo)
    RETURNING id INTO v_int_id;

    RETURN jsonb_build_object(
        'intento_id', v_int_id,
        'preguntas',  (
            SELECT jsonb_agg(jsonb_build_object(
                'id',        p.id,
                'enunciado', p.enunciado,
                'opciones',  (SELECT jsonb_agg(jsonb_build_object('texto', o->>'texto'))
                                FROM jsonb_array_elements(p.opciones) o)
            ) ORDER BY array_position(v_ids, p.id))
            FROM preguntas p
            WHERE p.id = ANY(v_ids)
        )
    );
END $$;

CREATE OR REPLACE FUNCTION responder_pregunta(p_intento_id uuid,
                                              p_pregunta_id uuid,
                                              p_opcion text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_correcta_esperada text;
    v_correcta boolean;
BEGIN
    SELECT (o->>'texto') INTO v_correcta_esperada
      FROM preguntas p, jsonb_array_elements(p.opciones) o
     WHERE p.id = p_pregunta_id AND (o->>'correcta')::boolean;
    v_correcta := (p_opcion = v_correcta_esperada);

    INSERT INTO respuestas(intento_id, pregunta_id, opcion_elegida, correcta)
    VALUES (p_intento_id, p_pregunta_id, p_opcion, v_correcta);

    IF NOT v_correcta THEN
        INSERT INTO marcadores(usuario_id, tipo, pregunta_id, contador)
        VALUES (v_uid, 'fallo', p_pregunta_id, 1)
        ON CONFLICT (usuario_id, tipo, pregunta_id)
          DO UPDATE SET contador = marcadores.contador + 1, actualizado_en = now();
    END IF;

    RETURN jsonb_build_object(
        'correcta',           v_correcta,
        'correcta_esperada',  v_correcta_esperada,
        'explicacion',        (SELECT explicacion FROM preguntas WHERE id = p_pregunta_id)
    );
END $$;

CREATE OR REPLACE FUNCTION finalizar_intento(p_intento_id uuid) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_correctas int;
    v_totales   int;
    v_nota      numeric(5,2);
    v_unid      uuid;
    v_uid       uuid := jwt_usuario_id();
    v_prev_dia  date;
    v_new_racha int;
BEGIN
    SELECT unidad_id INTO v_unid FROM intentos WHERE id = p_intento_id;

    SELECT count(*) FILTER (WHERE correcta), count(*)
      INTO v_correctas, v_totales
      FROM respuestas WHERE intento_id = p_intento_id;

    v_nota := CASE WHEN v_totales = 0 THEN 0
                   ELSE round((v_correctas::numeric / v_totales) * 10, 2)
              END;

    UPDATE intentos
       SET finalizado_en = now(), nota = v_nota
     WHERE id = p_intento_id;

    -- Progreso agregado.
    INSERT INTO progreso_unidad(usuario_id, unidad_id, intentos_test, ultima_nota, mejor_nota, actualizado_en)
    VALUES (v_uid, v_unid, 1, v_nota, v_nota, now())
    ON CONFLICT (usuario_id, unidad_id) DO UPDATE
      SET intentos_test = progreso_unidad.intentos_test + 1,
          ultima_nota   = EXCLUDED.ultima_nota,
          mejor_nota    = GREATEST(progreso_unidad.mejor_nota, EXCLUDED.mejor_nota),
          actualizado_en = now();

    -- Gamificación: XP + racha.
    SELECT ultimo_dia_activo INTO v_prev_dia
      FROM usuario_gamificacion WHERE usuario_id = v_uid;

    v_new_racha := CASE
        WHEN v_prev_dia = current_date       THEN (SELECT racha_actual FROM usuario_gamificacion WHERE usuario_id = v_uid)
        WHEN v_prev_dia = current_date - 1   THEN (SELECT racha_actual + 1 FROM usuario_gamificacion WHERE usuario_id = v_uid)
        ELSE 1
    END;

    UPDATE usuario_gamificacion
       SET xp_total          = xp_total + (v_correctas * 10),
           racha_actual      = v_new_racha,
           racha_maxima      = GREATEST(racha_maxima, v_new_racha),
           ultimo_dia_activo = current_date,
           actualizado_en    = now()
     WHERE usuario_id = v_uid;

    RETURN jsonb_build_object(
        'correctas', v_correctas,
        'totales',   v_totales,
        'nota',      v_nota
    );
END $$;


-- =============================================================================
--                             TEORÍA — marcar leída
-- =============================================================================

CREATE OR REPLACE FUNCTION marcar_teoria(p_unidad_id uuid,
                                          p_completada boolean DEFAULT true) RETURNS void
LANGUAGE sql AS $$
    INSERT INTO progreso_unidad(usuario_id, unidad_id, teoria_completada, teoria_vista_en, actualizado_en)
    VALUES (jwt_usuario_id(), p_unidad_id, p_completada,
            CASE WHEN p_completada THEN now() ELSE NULL END, now())
    ON CONFLICT (usuario_id, unidad_id) DO UPDATE
      SET teoria_completada = EXCLUDED.teoria_completada,
          teoria_vista_en   = COALESCE(EXCLUDED.teoria_vista_en, progreso_unidad.teoria_vista_en),
          actualizado_en    = now();
$$;


-- =============================================================================
--             DASHBOARD (Inicio / Estadísticas / Perfil)
-- =============================================================================

CREATE OR REPLACE FUNCTION mi_sesion() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'user_id',          u.id,
        'email',            u.email,
        'nombre',           u.nombre,
        'email_verificado', u.email_verificado,
        'roles',            jwt_roles(),
        'es_admin',         'admin' = ANY(jwt_roles()),
        'principal',        (SELECT o.id
                                FROM usuario_oposiciones uo
                                JOIN oposiciones o ON o.id = uo.oposicion_id
                               WHERE uo.usuario_id = u.id AND uo.principal LIMIT 1)
    )
    FROM usuarios u WHERE u.id = jwt_usuario_id();
$$;

CREATE OR REPLACE FUNCTION dashboard_inicio() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    WITH continua AS (
        SELECT u.id, u.nombre, u.minutos_est, u.tema_id, t.nombre AS tema_nombre,
               t.icono AS tema_icono,
               COALESCE(pu.mejor_nota, 0) AS mejor_nota,
               CASE
                 WHEN pu.teoria_completada AND pu.mejor_nota IS NOT NULL THEN 100
                 WHEN pu.teoria_completada THEN 60
                 WHEN pu.teoria_vista_en IS NOT NULL THEN 30
                 ELSE 0
               END AS progreso_pct
          FROM unidades u
          JOIN temas t ON t.id = u.tema_id
          JOIN oposicion_temas ot ON ot.tema_id = t.id
          JOIN usuario_oposiciones uo
            ON uo.oposicion_id = ot.oposicion_id AND uo.usuario_id = jwt_usuario_id()
     LEFT JOIN progreso_unidad pu
            ON pu.unidad_id = u.id AND pu.usuario_id = jwt_usuario_id()
         WHERE COALESCE(pu.teoria_completada, false) = false
                OR pu.mejor_nota IS NULL
         ORDER BY uo.principal DESC, ot.orden, u.orden
         LIMIT 1
    ),
    gamif AS (
        SELECT COALESCE(g.xp_total, 0) AS xp,
               COALESCE(g.racha_actual, 0) AS racha,
               1 + COALESCE(g.xp_total, 0) / 500 AS nivel
          FROM usuario_gamificacion g
         WHERE g.usuario_id = jwt_usuario_id()
    ),
    resumen AS (
        SELECT
          (SELECT count(*) FROM progreso_unidad
            WHERE usuario_id = jwt_usuario_id() AND teoria_completada) AS unidades_hechas,
          (SELECT count(*) FROM unidades u
             JOIN oposicion_temas ot ON ot.tema_id = u.tema_id
             JOIN usuario_oposiciones uo
               ON uo.oposicion_id = ot.oposicion_id
              AND uo.usuario_id = jwt_usuario_id()) AS unidades_totales,
          (SELECT COALESCE(sum(EXTRACT(EPOCH FROM (finalizado_en - iniciado_en))/60), 0)::int
             FROM intentos
            WHERE usuario_id = jwt_usuario_id()
              AND finalizado_en > (now() - interval '7 days')) AS minutos_semana
    )
    SELECT jsonb_build_object(
        'continua',          COALESCE((SELECT row_to_json(c) FROM continua c)::jsonb, 'null'::jsonb),
        'nivel',             COALESCE((SELECT nivel FROM gamif), 1),
        'xp',                COALESCE((SELECT xp FROM gamif), 0),
        'racha_dias',        COALESCE((SELECT racha FROM gamif), 0),
        'unidades_hechas',   (SELECT unidades_hechas FROM resumen),
        'unidades_totales',  (SELECT unidades_totales FROM resumen),
        'porcentaje',        CASE WHEN (SELECT unidades_totales FROM resumen) = 0 THEN 0
                                  ELSE round(100.0 * (SELECT unidades_hechas FROM resumen)
                                                   / (SELECT unidades_totales FROM resumen))
                             END,
        'minutos_semana',    (SELECT minutos_semana FROM resumen)
    );
$$;

CREATE OR REPLACE FUNCTION dashboard_estadisticas() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    WITH por_dia AS (
        SELECT to_char(iniciado_en, 'YYYY-MM-DD') AS dia,
               EXTRACT(ISODOW FROM iniciado_en)::int AS dow,
               COALESCE(sum(EXTRACT(EPOCH FROM (finalizado_en - iniciado_en))/60), 0)::int AS minutos
          FROM intentos
         WHERE usuario_id = jwt_usuario_id()
           AND iniciado_en > (now() - interval '7 days')
           AND finalizado_en IS NOT NULL
         GROUP BY 1, 2
    ),
    por_tema AS (
        SELECT t.id, t.nombre, t.icono,
               round(avg(pu.mejor_nota)::numeric * 10, 0) AS porcentaje
          FROM temas t
          JOIN unidades u ON u.tema_id = t.id
          JOIN progreso_unidad pu ON pu.unidad_id = u.id
         WHERE pu.usuario_id = jwt_usuario_id() AND pu.mejor_nota IS NOT NULL
         GROUP BY t.id, t.nombre, t.icono
    ),
    resumen AS (
        SELECT
          COALESCE((SELECT racha_actual FROM usuario_gamificacion
                     WHERE usuario_id = jwt_usuario_id()), 0) AS racha,
          (SELECT COALESCE(sum(EXTRACT(EPOCH FROM (finalizado_en - iniciado_en))/60), 0)::int
             FROM intentos
            WHERE usuario_id = jwt_usuario_id()
              AND finalizado_en > (now() - interval '7 days')) AS minutos_semana,
          COALESCE((SELECT round(avg(CASE WHEN r.correcta THEN 100 ELSE 0 END))
                      FROM respuestas r JOIN intentos i ON i.id = r.intento_id
                     WHERE i.usuario_id = jwt_usuario_id()), 0) AS precision_media,
          (SELECT count(*) FROM progreso_unidad
            WHERE usuario_id = jwt_usuario_id() AND teoria_completada) AS unidades_hechas,
          (SELECT count(*) FROM unidades u
             JOIN oposicion_temas ot ON ot.tema_id = u.tema_id
             JOIN usuario_oposiciones uo
               ON uo.oposicion_id = ot.oposicion_id AND uo.usuario_id = jwt_usuario_id()
          ) AS unidades_totales
    )
    SELECT jsonb_build_object(
        'racha_dias',        (SELECT racha FROM resumen),
        'minutos_semana',    (SELECT minutos_semana FROM resumen),
        'precision_media',   (SELECT precision_media FROM resumen),
        'unidades_hechas',   (SELECT unidades_hechas FROM resumen),
        'unidades_totales',  (SELECT unidades_totales FROM resumen),
        'porcentaje',        CASE WHEN (SELECT unidades_totales FROM resumen) = 0 THEN 0
                                  ELSE round(100.0 * (SELECT unidades_hechas FROM resumen)
                                                   / (SELECT unidades_totales FROM resumen))
                             END,
        'actividad_semanal', COALESCE((SELECT jsonb_agg(row_to_json(x) ORDER BY x.dia) FROM por_dia x), '[]'::jsonb),
        'rendimiento',       COALESCE((SELECT jsonb_agg(row_to_json(x) ORDER BY x.porcentaje DESC) FROM por_tema x), '[]'::jsonb)
    );
$$;

CREATE OR REPLACE FUNCTION dashboard_perfil() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'nombre',           u.nombre,
        'email',            u.email,
        'email_verificado', u.email_verificado,
        'creado_en',        u.creado_en,
        'nivel',            1 + COALESCE(g.xp_total, 0) / 500,
        'xp',               COALESCE(g.xp_total, 0),
        'racha',            COALESCE(g.racha_actual, 0),
        'oposicion_activa', (
            SELECT jsonb_build_object('id', o.id, 'nombre', o.nombre)
              FROM usuario_oposiciones uo
              JOIN oposiciones o ON o.id = uo.oposicion_id
             WHERE uo.usuario_id = u.id AND uo.principal LIMIT 1
        ),
        'plan', (SELECT row_to_json(p)::jsonb FROM plan_estudio p
                  WHERE p.usuario_id = u.id AND p.activo LIMIT 1),
        'logros', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'codigo',   lc.codigo,
                'titulo',   lc.titulo,
                'icono',    lc.icono,
                'obtenido', lu.obtenido_en IS NOT NULL
            )) FROM logros_catalogo lc
          LEFT JOIN logros_usuario lu
                 ON lu.logro_id = lc.id AND lu.usuario_id = u.id
             WHERE lc.activo
        ), '[]'::jsonb)
    )
    FROM usuarios u
    LEFT JOIN usuario_gamificacion g ON g.usuario_id = u.id
    WHERE u.id = jwt_usuario_id();
$$;


-- =============================================================================
--                          RETOS Y LOGROS — RPCs auxiliares
-- =============================================================================

CREATE OR REPLACE FUNCTION mis_retos() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'codigo',      rc.codigo,
        'titulo',      rc.titulo,
        'descripcion', rc.descripcion,
        'icono',       rc.icono,
        'periodo',     rc.periodo,
        'objetivo',    rc.objetivo,
        'xp',          rc.xp,
        'progreso',    COALESCE(ru.progreso, 0),
        'completado',  ru.completado_en IS NOT NULL
    )), '[]'::jsonb)
      FROM retos_catalogo rc
 LEFT JOIN retos_usuario ru
        ON ru.reto_id = rc.id
       AND ru.usuario_id = jwt_usuario_id()
       AND ru.periodo_inicio = CASE rc.periodo
             WHEN 'diario'   THEN current_date
             WHEN 'semanal'  THEN date_trunc('week', current_date)::date
             WHEN 'mensual'  THEN date_trunc('month', current_date)::date
           END
     WHERE rc.activo;
$$;


-- =============================================================================
--                        PUSH — configuración y prueba
-- =============================================================================

-- La SPA necesita la clave pública VAPID para llamar a
-- pushManager.subscribe.  Se guarda en config('push_vapid_public') tras
-- generar el par con notificador/gen_vapid.py.  Endpoint anónimo.
CREATE OR REPLACE FUNCTION push_config_publica() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'vapid_public', COALESCE((SELECT valor #>> '{}' FROM config
                                    WHERE clave = 'push_vapid_public'), NULL)
    );
$$;

-- Utilidad para probar el circuito Web Push: encola una notificación
-- de prueba para el propio usuario. El notificador la despacha en el
-- siguiente tick.
CREATE OR REPLACE FUNCTION push_enviar_prueba(p_titulo text DEFAULT 'Aprentix',
                                              p_cuerpo text DEFAULT 'Notificación de prueba ✅')
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_uid uuid := jwt_usuario_id();
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    INSERT INTO cola_push(usuario_id, titulo, cuerpo, url)
    VALUES (v_uid, p_titulo, p_cuerpo, app_url());
    RETURN jsonb_build_object('ok', true);
END $$;


-- =============================================================================
--                                    SEMILLA
-- =============================================================================

INSERT INTO roles(id, descripcion) VALUES
    ('admin',   'Superusuario del sistema'),
    ('editor',  'Puede crear/editar oposiciones, temas y unidades'),
    ('alumno',  'Usuario estándar que estudia')
ON CONFLICT (id) DO UPDATE
SET descripcion = EXCLUDED.descripcion;

INSERT INTO permisos(id, descripcion) VALUES
    ('oposicion.gestionar', 'Crear/editar oposiciones, temas, unidades y preguntas'),
    ('usuarios.gestionar',  'Ver y administrar cuentas de usuario'),
    ('config.gestionar',    'Editar la tabla config')
ON CONFLICT (id) DO UPDATE
SET descripcion = EXCLUDED.descripcion;

INSERT INTO rol_permisos(rol_id, permiso_id) VALUES
    ('admin',  'oposicion.gestionar'),
    ('admin',  'usuarios.gestionar'),
    ('admin',  'config.gestionar'),
    ('editor', 'oposicion.gestionar')
ON CONFLICT (rol_id, permiso_id) DO NOTHING;

-- Config inicial. El dominio se ajusta desde fuera (variable de entorno
-- APP_URL en el arranque del contenedor de db → ver docker-entrypoint
-- de deploy/core, o UPDATE manual desde pgAdmin).
INSERT INTO config(clave, valor) VALUES
    ('app_url',          '"http://localhost"'::jsonb),
    ('app_nombre',       '"Aprentix"'::jsonb),
    ('push_vapid_public', 'null'::jsonb)
ON CONFLICT (clave) DO NOTHING;

INSERT INTO retos_catalogo(codigo, titulo, descripcion, periodo, objetivo, xp, icono) VALUES
    ('reto_diario_test',  '3 tests al día',      'Completa 3 tests en un solo día.',        'diario',  3,  20, '🎯'),
    ('reto_semanal_hora', '5 horas esta semana', 'Suma 5 horas de estudio en la semana.',   'semanal', 300, 80, '⏱️'),
    ('reto_semanal_racha','Mantén la racha',     'Estudia 7 días seguidos.',                'semanal', 7,  50, '🔥'),
    ('reto_mensual_temas','8 temas al mes',       'Completa la teoría de 8 temas nuevos.',  'mensual', 8,  200,'📚')
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO logros_catalogo(codigo, titulo, descripcion, objetivo, xp, icono) VALUES
    ('logro_primer_test',  'Primera pisada',     'Completa tu primer test.',            1,   50, '🥾'),
    ('logro_racha_10',     'Racha de 10 días',   'Estudia 10 días seguidos.',           10, 150, '🔥'),
    ('logro_10_temas',     'Coleccionista',      'Completa la teoría de 10 temas.',     10, 200, '📖'),
    ('logro_1000_xp',      'Nivel avanzado',     'Alcanza los 1.000 XP.',               1000, 300, '⭐'),
    ('logro_100_correctas','Ojo de halcón',      'Acumula 100 respuestas correctas.',   100, 250, '🦅')
ON CONFLICT (codigo) DO NOTHING;

-- Usuario admin de bootstrap (marcado como verificado para poder
-- entrar sin pasar por el flujo SMTP).
DO $bootstrap_admin$
DECLARE
    v_admin      uuid;
    v_admin_pass text := current_setting('app.admin_pass', true);
BEGIN
    SELECT id INTO v_admin
      FROM usuarios
     WHERE email = 'admin@aprentix.es';

    IF v_admin IS NULL THEN
        IF v_admin_pass IS NULL OR v_admin_pass = '' THEN
            RAISE EXCEPTION 'Falta configurar app.admin_pass para crear el usuario administrador inicial';
        END IF;

        INSERT INTO usuarios(email, nombre, password_hash, email_verificado)
        VALUES ('admin@aprentix.es', 'Admin',
                crypt(v_admin_pass, gen_salt('bf', 12)),
                true)
        RETURNING id INTO v_admin;
    ELSE
        UPDATE usuarios
           SET email_verificado = true,
               activo = true
         WHERE id = v_admin;
    END IF;

    INSERT INTO usuario_roles(usuario_id, rol_id)
    VALUES (v_admin, 'admin')
    ON CONFLICT (usuario_id, rol_id) DO NOTHING;

    INSERT INTO usuario_gamificacion(usuario_id)
    VALUES (v_admin)
    ON CONFLICT (usuario_id) DO NOTHING;
END
$bootstrap_admin$;

DO $password_autenticador$
DECLARE
    v_auth_pass text := current_setting('app.auth_pass', true);
BEGIN
    IF v_auth_pass IS NOT NULL AND v_auth_pass <> '' THEN
        EXECUTE format('ALTER ROLE autenticador WITH PASSWORD %L', v_auth_pass);
    ELSE
        RAISE NOTICE 'app.auth_pass no está configurado; se conserva la contraseña actual de autenticador';
    END IF;
END
$password_autenticador$;
