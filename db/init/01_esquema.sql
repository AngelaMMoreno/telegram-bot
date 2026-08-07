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
    id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug                      text UNIQUE NOT NULL,
    nombre                    text NOT NULL,
    descripcion               text,
    organismo                 text,
    -- Fecha del examen (la fija admin). Si es sólo orientativa (mes/año)
    -- se guarda el día 1 del mes y se marca fecha_examen_orientativa=true.
    -- El motor del planificador la usa para dimensionar el ritmo semanal.
    fecha_examen              date,
    fecha_examen_orientativa  boolean NOT NULL DEFAULT false,
    activa                    boolean NOT NULL DEFAULT true,
    creada_en                 timestamptz NOT NULL DEFAULT now(),
    autor_id                  uuid REFERENCES usuarios(id) ON DELETE SET NULL
);
-- Migración incremental para instalaciones previas.
ALTER TABLE oposiciones
    ADD COLUMN IF NOT EXISTS fecha_examen             date,
    ADD COLUMN IF NOT EXISTS fecha_examen_orientativa boolean NOT NULL DEFAULT false;

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

-- El progreso se DERIVA de sesiones_estudio + intentos: `teoria_completada`
-- pasa a true cuando el tiempo activo acumulado supera minutos_est*0.8, y
-- las notas se calculan a partir de `intentos.nota`.  Ver la RPC
-- `refrescar_progreso_unidad()` más abajo.
CREATE TABLE IF NOT EXISTS progreso_unidad (
    usuario_id           uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    unidad_id            uuid NOT NULL REFERENCES unidades(id) ON DELETE CASCADE,
    teoria_completada    boolean NOT NULL DEFAULT false,
    teoria_vista_en      timestamptz,
    minutos_estudiados   int  NOT NULL DEFAULT 0,   -- suma de sesiones_estudio activas
    intentos_test        int  NOT NULL DEFAULT 0,
    mejor_nota           numeric(5,2),
    ultima_nota          numeric(5,2),
    actualizado_en       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (usuario_id, unidad_id)
);
CREATE INDEX IF NOT EXISTS progreso_unidad_usuario_idx ON progreso_unidad (usuario_id);

-- Registro fino del tiempo activo por (usuario, unidad).  El frontend
-- abre una sesión al entrar en la unidad y va enviando pings de
-- "sigo aquí"; al cerrar (blur / navegación / cierre de pestaña)
-- envía el cierre.  Si el ping no llega en X minutos, la sesión se
-- cierra sola vía RPC `sesiones_cerrar_zombies()`.
CREATE TABLE IF NOT EXISTS sesiones_estudio (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    usuario_id      uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    unidad_id       uuid NOT NULL REFERENCES unidades(id) ON DELETE CASCADE,
    abierta_en      timestamptz NOT NULL DEFAULT now(),
    ultima_actividad timestamptz NOT NULL DEFAULT now(),
    cerrada_en      timestamptz,
    -- Minutos ACTIVOS reales (sólo los ticks recibidos).  Al cerrar
    -- se calcula la diferencia final; en vivo el frontend puede
    -- estimar añadiendo `min(now(), ultima_actividad + 60s)`.
    minutos_activos int  NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS sesiones_estudio_usuario_idx
    ON sesiones_estudio (usuario_id, unidad_id);
CREATE INDEX IF NOT EXISTS sesiones_estudio_abiertas_idx
    ON sesiones_estudio (usuario_id) WHERE cerrada_en IS NULL;

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
    -- Modo de disponibilidad: 'semanal' (usa horas_semana) o 'diario'
    -- (usa horas_por_dia con detalle L..D).  El motor de generación
    -- interpreta cada modo por separado.
    modo_disponibilidad text NOT NULL DEFAULT 'diario'
                          CHECK (modo_disponibilidad IN ('semanal','diario')),
    horas_semana    numeric(5,2),                    -- solo modo='semanal'
    -- Horas por día lun..dom. NULL o 0 = día sin estudio. Ejemplo:
    -- '{"lun":1.5, "mar":2, "mie":1.5, "jue":3, "vie":1.5, "sab":3, "dom":0}'
    horas_por_dia   jsonb NOT NULL DEFAULT
        '{"lun":2,"mar":2,"mie":2,"jue":2,"vie":2,"sab":2,"dom":0}'::jsonb,
    -- Se conserva por compatibilidad con las RPCs previas.  El wizard
    -- rellena automáticamente estos dos a partir de horas_por_dia.
    horas_dia       numeric(4,2) NOT NULL DEFAULT 2 CHECK (horas_dia > 0),
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

-- Migración: añade columnas nuevas a plan_estudio si la tabla existía
-- desde una versión anterior del esquema.
ALTER TABLE plan_estudio
    ADD COLUMN IF NOT EXISTS modo_disponibilidad text NOT NULL DEFAULT 'diario'
        CHECK (modo_disponibilidad IN ('semanal','diario'));
ALTER TABLE plan_estudio
    ADD COLUMN IF NOT EXISTS horas_semana numeric(5,2);
ALTER TABLE plan_estudio
    ADD COLUMN IF NOT EXISTS horas_por_dia jsonb NOT NULL DEFAULT
        '{"lun":2,"mar":2,"mie":2,"jue":2,"vie":2,"sab":2,"dom":0}'::jsonb;

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
--                            GRANT EXECUTE en funciones
-- =============================================================================
-- PostgREST oculta las funciones sin EXECUTE al rol que hace la
-- llamada.  Registro y verificación son anónimos → web_anon.  Login
-- también es anónimo (el usuario aún no tiene JWT).  Todo lo demás
-- requiere JWT → web_user.
--
-- Se aplica al FINAL de las declaraciones de funciones (ver más
-- abajo).  Definimos aquí un DO block que barre TODAS las funciones
-- del esquema public y les da EXECUTE apropiado, para que baste con
-- añadir una función nueva sin acordarse del GRANT.
-- La ejecución REAL de este bloque va después de crear las funciones
-- (fin del fichero).


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
        NULLIF(current_setting('app.app_url', true), ''),
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
                AND p.teoria_completada) AS unidades_hechas,
            -- Lista completa de unidades del tema para renderizar el
            -- desplegable en la vista "Mi oposición".
            (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                    'id',           u.id,
                    'slug',         u.slug,
                    'nombre',       u.nombre,
                    'orden',        u.orden,
                    'minutos_est',  u.minutos_est,
                    'num_preguntas',
                        (SELECT count(*) FROM preguntas p WHERE p.unidad_id = u.id)
                ) ORDER BY u.orden), '[]'::jsonb)
              FROM unidades u WHERE u.tema_id = t.id
            ) AS unidades
          FROM oposicion_temas ot
          JOIN temas t ON t.id = ot.tema_id
         WHERE ot.oposicion_id = p_oposicion_id
    )
    SELECT jsonb_build_object(
        'id',                        o.id,
        'slug',                      o.slug,
        'nombre',                    o.nombre,
        'descripcion',               o.descripcion,
        'organismo',                 o.organismo,
        'fecha_examen',              o.fecha_examen,
        'fecha_examen_orientativa',  o.fecha_examen_orientativa,
        'temas',       COALESCE(
                           (SELECT jsonb_agg(
                                jsonb_build_object(
                                    'id',              ta.tema_id,
                                    'slug',            ta.slug,
                                    'nombre',          ta.nombre,
                                    'descripcion',     ta.descripcion,
                                    'icono',           ta.icono,
                                    'orden',           ta.orden,
                                    'num_unidades',    ta.num_unidades,
                                    'minutos_est',     ta.minutos_est,
                                    'unidades_hechas', ta.unidades_hechas,
                                    'unidades',        ta.unidades
                                ) ORDER BY ta.orden
                            ) FROM temas_agg ta),
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
--            SESIONES DE ESTUDIO — auto-tracking del progreso
-- =============================================================================
-- El frontend abre una sesión al entrar en la unidad, envía un tick
-- de "sigo aquí" cada 30-60 s y cierra al salir.  Un tick sólo
-- suma tiempo si la ventana está VISIBLE (Page Visibility API).
--
-- `refrescar_progreso_unidad()` deriva `teoria_completada` y
-- `minutos_estudiados` a partir de las sesiones cerradas + estimación
-- de la abierta.  Se ejecuta al abrir/cerrar/tick para mantener el
-- dashboard vivo sin agregados nocturnos.

CREATE OR REPLACE FUNCTION sesion_abrir(p_unidad_id uuid) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_id  uuid;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    -- Cierra sesiones huérfanas del propio usuario (inactividad > 15 min).
    UPDATE sesiones_estudio
       SET cerrada_en = COALESCE(cerrada_en, ultima_actividad)
     WHERE usuario_id = v_uid
       AND cerrada_en IS NULL
       AND ultima_actividad < now() - interval '15 minutes';

    INSERT INTO sesiones_estudio(usuario_id, unidad_id)
    VALUES (v_uid, p_unidad_id)
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('sesion_id', v_id);
END $$;

-- Cada tick suma como MUCHO `p_delta_seg` (por defecto 60 s).  El
-- frontend manda un tick cuando la pestaña está visible; si el usuario
-- cambia de pestaña, deja de mandar → deja de sumar.
CREATE OR REPLACE FUNCTION sesion_tick(p_sesion_id uuid, p_delta_seg int DEFAULT 60)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_ok  boolean;
BEGIN
    UPDATE sesiones_estudio
       SET ultima_actividad = now(),
           minutos_activos  = minutos_activos + GREATEST(0, p_delta_seg) / 60.0
     WHERE id = p_sesion_id AND usuario_id = v_uid AND cerrada_en IS NULL
     RETURNING true INTO v_ok;
    IF v_ok THEN
        PERFORM refrescar_progreso_unidad(
            v_uid,
            (SELECT unidad_id FROM sesiones_estudio WHERE id = p_sesion_id)
        );
    END IF;
END $$;

CREATE OR REPLACE FUNCTION sesion_cerrar(p_sesion_id uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_uid   uuid := jwt_usuario_id();
    v_unid  uuid;
BEGIN
    UPDATE sesiones_estudio
       SET cerrada_en = now(), ultima_actividad = now()
     WHERE id = p_sesion_id AND usuario_id = v_uid AND cerrada_en IS NULL
     RETURNING unidad_id INTO v_unid;
    IF v_unid IS NOT NULL THEN
        PERFORM refrescar_progreso_unidad(v_uid, v_unid);
    END IF;
END $$;

-- Recalcula `progreso_unidad` para (usuario, unidad) a partir de
-- las sesiones (cerradas o abiertas) + intentos. `teoria_completada`
-- se marca cuando el tiempo activo acumulado supera el 80 % del
-- estimado `unidades.minutos_est`.
CREATE OR REPLACE FUNCTION refrescar_progreso_unidad(p_usr uuid, p_unid uuid)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_minutos int;
    v_umbral  int;
    v_intentos int;
    v_ultima   numeric(5,2);
    v_mejor    numeric(5,2);
BEGIN
    SELECT COALESCE(ROUND(SUM(minutos_activos))::int, 0) INTO v_minutos
      FROM sesiones_estudio
     WHERE usuario_id = p_usr AND unidad_id = p_unid;

    SELECT GREATEST(5, (minutos_est * 0.8)::int) INTO v_umbral
      FROM unidades WHERE id = p_unid;

    SELECT count(*), max(nota),
           (SELECT nota FROM intentos
             WHERE usuario_id = p_usr AND unidad_id = p_unid
               AND finalizado_en IS NOT NULL
             ORDER BY finalizado_en DESC LIMIT 1)
      INTO v_intentos, v_mejor, v_ultima
      FROM intentos
     WHERE usuario_id = p_usr AND unidad_id = p_unid
       AND finalizado_en IS NOT NULL;

    INSERT INTO progreso_unidad(usuario_id, unidad_id,
                                 teoria_completada, teoria_vista_en,
                                 minutos_estudiados,
                                 intentos_test, mejor_nota, ultima_nota,
                                 actualizado_en)
    VALUES (p_usr, p_unid,
            v_minutos >= v_umbral,
            CASE WHEN v_minutos >= v_umbral THEN now() ELSE NULL END,
            v_minutos,
            COALESCE(v_intentos, 0), v_mejor, v_ultima,
            now())
    ON CONFLICT (usuario_id, unidad_id) DO UPDATE
       SET teoria_completada  = EXCLUDED.teoria_completada
                                OR progreso_unidad.teoria_completada,
           teoria_vista_en    = COALESCE(progreso_unidad.teoria_vista_en,
                                          EXCLUDED.teoria_vista_en),
           minutos_estudiados = EXCLUDED.minutos_estudiados,
           intentos_test      = EXCLUDED.intentos_test,
           mejor_nota         = EXCLUDED.mejor_nota,
           ultima_nota        = EXCLUDED.ultima_nota,
           actualizado_en     = now();
END $$;

-- Cierra sesiones huérfanas (llamable desde un cron externo, o desde
-- la propia SPA al abrir una nueva).
CREATE OR REPLACE FUNCTION sesiones_cerrar_zombies() RETURNS int
LANGUAGE plpgsql AS $$
DECLARE v_n int;
BEGIN
    UPDATE sesiones_estudio
       SET cerrada_en = ultima_actividad
     WHERE cerrada_en IS NULL
       AND ultima_actividad < now() - interval '30 minutes';
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END $$;


-- =============================================================================
--                    WIZARD DE DISPONIBILIDAD + MOTOR DE PLAN
-- =============================================================================

-- Guarda las respuestas del wizard.  Si el plan ya existe para la
-- oposición, se actualiza; si no, se crea.  Devuelve el plan_id.
CREATE OR REPLACE FUNCTION guardar_disponibilidad(
    p_oposicion_id  uuid,
    p_modo          text,                        -- 'semanal' | 'diario'
    p_horas_semana  numeric DEFAULT NULL,        -- solo modo='semanal'
    p_horas_por_dia jsonb   DEFAULT NULL,        -- solo modo='diario'
    p_fecha_examen  date    DEFAULT NULL,
    p_ritmo         text    DEFAULT 'normal',
    p_metodo        text    DEFAULT 'cortas'
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_uid    uuid := jwt_usuario_id();
    v_id     uuid;
    v_hd     numeric(4,2);
    v_dw     boolean[];
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    IF p_modo NOT IN ('semanal','diario') THEN RAISE EXCEPTION 'modo_invalido'; END IF;

    -- Derivar horas_dia y dias_semana (compat con RPCs previas).
    IF p_modo = 'semanal' THEN
        v_hd := ROUND((COALESCE(p_horas_semana, 10) / 6)::numeric, 2);
        v_dw := ARRAY[true,true,true,true,true,true,false];
    ELSE
        v_dw := ARRAY[
            COALESCE((p_horas_por_dia->>'lun')::numeric, 0) > 0,
            COALESCE((p_horas_por_dia->>'mar')::numeric, 0) > 0,
            COALESCE((p_horas_por_dia->>'mie')::numeric, 0) > 0,
            COALESCE((p_horas_por_dia->>'jue')::numeric, 0) > 0,
            COALESCE((p_horas_por_dia->>'vie')::numeric, 0) > 0,
            COALESCE((p_horas_por_dia->>'sab')::numeric, 0) > 0,
            COALESCE((p_horas_por_dia->>'dom')::numeric, 0) > 0
        ];
        v_hd := GREATEST(0.1, ROUND((
            COALESCE((p_horas_por_dia->>'lun')::numeric, 0) +
            COALESCE((p_horas_por_dia->>'mar')::numeric, 0) +
            COALESCE((p_horas_por_dia->>'mie')::numeric, 0) +
            COALESCE((p_horas_por_dia->>'jue')::numeric, 0) +
            COALESCE((p_horas_por_dia->>'vie')::numeric, 0) +
            COALESCE((p_horas_por_dia->>'sab')::numeric, 0) +
            COALESCE((p_horas_por_dia->>'dom')::numeric, 0)
        ) / 7, 2));
    END IF;

    INSERT INTO plan_estudio(usuario_id, oposicion_id, fecha_examen,
                              modo_disponibilidad, horas_semana, horas_por_dia,
                              horas_dia, dias_semana, ritmo, metodo,
                              activo, actualizado_en)
    VALUES (v_uid, p_oposicion_id, p_fecha_examen,
            p_modo, p_horas_semana,
            COALESCE(p_horas_por_dia, '{"lun":2,"mar":2,"mie":2,"jue":2,"vie":2,"sab":2,"dom":0}'::jsonb),
            v_hd, v_dw, p_ritmo, p_metodo,
            true, now())
    ON CONFLICT (usuario_id, oposicion_id) DO UPDATE
       SET fecha_examen        = EXCLUDED.fecha_examen,
           modo_disponibilidad = EXCLUDED.modo_disponibilidad,
           horas_semana        = EXCLUDED.horas_semana,
           horas_por_dia       = EXCLUDED.horas_por_dia,
           horas_dia           = EXCLUDED.horas_dia,
           dias_semana         = EXCLUDED.dias_semana,
           ritmo               = EXCLUDED.ritmo,
           metodo              = EXCLUDED.metodo,
           activo              = true,
           actualizado_en      = now()
    RETURNING id INTO v_id;

    -- Al guardar, regenera el plan de los próximos 14 días.
    PERFORM generar_plan(v_id, 14);
    RETURN jsonb_build_object('plan_id', v_id);
END $$;

-- Motor MUY simple de generación de plan:
--   - borra las sesiones NO completadas de los próximos p_dias
--   - para cada día con horas > 0, crea bloques de 25/45 min con las
--     unidades pendientes (no marcadas como teoria_completada) por
--     orden de oposicion_temas.orden + unidades.orden.
--   - añade un bloque final de "repaso" si sobran minutos.
CREATE OR REPLACE FUNCTION generar_plan(p_plan_id uuid, p_dias int DEFAULT 14)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_plan    plan_estudio;
    v_hoy     date := current_date;
    v_dia     date;
    v_dow_es  text;
    v_hd      numeric;
    v_min     int;
    v_bloque  int;
    v_creadas int := 0;
    v_uid     uuid;
    v_unid    uuid;
    v_unids   uuid[];
    v_idx     int;
BEGIN
    SELECT * INTO v_plan FROM plan_estudio WHERE id = p_plan_id;
    IF v_plan.id IS NULL THEN RAISE EXCEPTION 'plan_no_existe'; END IF;
    v_uid := v_plan.usuario_id;

    -- Cola de unidades pendientes de la oposición del plan.
    SELECT COALESCE(array_agg(u.id ORDER BY ot.orden, u.orden), ARRAY[]::uuid[])
      INTO v_unids
      FROM oposicion_temas ot
      JOIN unidades u ON u.tema_id = ot.tema_id
 LEFT JOIN progreso_unidad pu
        ON pu.unidad_id = u.id AND pu.usuario_id = v_uid
     WHERE ot.oposicion_id = v_plan.oposicion_id
       AND COALESCE(pu.teoria_completada, false) = false;

    IF cardinality(v_unids) = 0 THEN
        RETURN jsonb_build_object('creadas', 0, 'motivo', 'sin_unidades_pendientes');
    END IF;

    -- Limpia sesiones futuras NO completadas de este plan.
    DELETE FROM plan_sesiones
     WHERE plan_id = p_plan_id
       AND fecha >= v_hoy
       AND NOT completada;

    v_idx := 1;
    FOR i IN 0..(p_dias - 1) LOOP
        v_dia := v_hoy + i;
        v_dow_es := CASE EXTRACT(ISODOW FROM v_dia)::int
                        WHEN 1 THEN 'lun' WHEN 2 THEN 'mar' WHEN 3 THEN 'mie'
                        WHEN 4 THEN 'jue' WHEN 5 THEN 'vie' WHEN 6 THEN 'sab'
                        WHEN 7 THEN 'dom' END;
        v_hd  := COALESCE((v_plan.horas_por_dia->>v_dow_es)::numeric, 0);
        v_min := (v_hd * 60)::int;
        IF v_min <= 0 THEN CONTINUE; END IF;

        -- Método 'cortas' → bloques de 25 min; 'profundas' → 45 min.
        v_bloque := CASE WHEN v_plan.metodo = 'profundas' THEN 45 ELSE 25 END;

        WHILE v_min >= v_bloque AND v_idx <= cardinality(v_unids) LOOP
            v_unid := v_unids[v_idx];
            INSERT INTO plan_sesiones(plan_id, fecha, minutos, unidad_id, tipo)
            VALUES (p_plan_id, v_dia, v_bloque, v_unid, 'estudio');
            v_creadas := v_creadas + 1;
            v_min := v_min - v_bloque - 5;   -- 5 min de respiro
            v_idx := v_idx + 1;
        END LOOP;

        -- Añade un bloque de repaso al final del día si queda tiempo.
        IF v_min >= 15 THEN
            INSERT INTO plan_sesiones(plan_id, fecha, minutos, tipo)
            VALUES (p_plan_id, v_dia, LEAST(v_min, 30), 'repaso');
            v_creadas := v_creadas + 1;
        END IF;
    END LOOP;

    RETURN jsonb_build_object('creadas', v_creadas);
END $$;

-- Reprograma: si el usuario no ha cumplido las sesiones de hoy y
-- días anteriores, se marca las no-completadas como saltadas y se
-- vuelve a llamar a generar_plan para llenar los próximos 14 días.
CREATE OR REPLACE FUNCTION reprogramar_plan(p_plan_id uuid) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE plan_sesiones
       SET nota_libre = COALESCE(nota_libre, '') || ' [saltada]'
     WHERE plan_id = p_plan_id
       AND fecha < current_date
       AND NOT completada
       AND (nota_libre IS NULL OR nota_libre NOT LIKE '%[saltada]%');

    DELETE FROM plan_sesiones
     WHERE plan_id = p_plan_id
       AND fecha < current_date
       AND NOT completada;

    RETURN generar_plan(p_plan_id, 14);
END $$;

-- Devuelve el plan de HOY (o el día que pases).
CREATE OR REPLACE FUNCTION plan_del_dia(p_fecha date DEFAULT current_date) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id',           ps.id,
        'hora_inicio',  ps.hora_inicio,
        'minutos',      ps.minutos,
        'tipo',         ps.tipo,
        'completada',   ps.completada,
        'unidad_id',    ps.unidad_id,
        'unidad',       u.nombre,
        'tema',         t.nombre,
        'tema_icono',   t.icono
    ) ORDER BY ps.hora_inicio NULLS LAST, ps.id), '[]'::jsonb)
      FROM plan_estudio p
      JOIN plan_sesiones ps ON ps.plan_id = p.id
 LEFT JOIN unidades u ON u.id = ps.unidad_id
 LEFT JOIN temas t ON t.id = u.tema_id
     WHERE p.usuario_id = jwt_usuario_id()
       AND p.activo
       AND ps.fecha = p_fecha;
$$;


-- =============================================================================
--                    GESTIÓN DE USUARIOS (ADMIN)
-- =============================================================================

CREATE OR REPLACE FUNCTION admin_listar_usuarios(p_query text DEFAULT NULL,
                                                 p_limit int DEFAULT 50)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id',                u.id,
        'email',             u.email,
        'nombre',            u.nombre,
        'email_verificado',  u.email_verificado,
        'activo',            u.activo,
        'creado_en',         u.creado_en,
        'roles',             (SELECT array_agg(rol_id ORDER BY rol_id)
                                FROM usuario_roles WHERE usuario_id = u.id),
        'oposiciones',       (SELECT array_agg(o.nombre)
                                FROM usuario_oposiciones uo
                                JOIN oposiciones o ON o.id = uo.oposicion_id
                               WHERE uo.usuario_id = u.id)
    ) ORDER BY u.creado_en DESC), '[]'::jsonb)
      FROM usuarios u
     WHERE es_admin()
       AND (p_query IS NULL OR
            u.email ILIKE '%' || p_query || '%' OR
            u.nombre ILIKE '%' || p_query || '%')
     LIMIT p_limit;
$$;

CREATE OR REPLACE FUNCTION admin_set_activo(p_usuario_id uuid, p_activo boolean)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    UPDATE usuarios SET activo = p_activo WHERE id = p_usuario_id;
END $$;

CREATE OR REPLACE FUNCTION admin_toggle_rol(p_usuario_id uuid, p_rol text, p_asignar boolean)
RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    IF p_asignar THEN
        INSERT INTO usuario_roles(usuario_id, rol_id) VALUES (p_usuario_id, p_rol)
        ON CONFLICT DO NOTHING;
    ELSE
        DELETE FROM usuario_roles WHERE usuario_id = p_usuario_id AND rol_id = p_rol;
    END IF;
END $$;

CREATE OR REPLACE FUNCTION admin_verificar_email(p_usuario_id uuid) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    UPDATE usuarios SET email_verificado = true WHERE id = p_usuario_id;
END $$;

CREATE OR REPLACE FUNCTION admin_stats() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN NOT es_admin() THEN 'null'::jsonb ELSE jsonb_build_object(
        'usuarios',          (SELECT count(*) FROM usuarios),
        'usuarios_activos',  (SELECT count(*) FROM usuarios WHERE activo),
        'usuarios_verif',    (SELECT count(*) FROM usuarios WHERE email_verificado),
        'oposiciones',       (SELECT count(*) FROM oposiciones),
        'temas',             (SELECT count(*) FROM temas),
        'unidades',          (SELECT count(*) FROM unidades),
        'preguntas',         (SELECT count(*) FROM preguntas),
        'emails_pendientes', (SELECT count(*) FROM cola_emails WHERE enviado_en IS NULL),
        'push_pendientes',   (SELECT count(*) FROM cola_push WHERE enviado_en IS NULL)
    ) END;
$$;

-- Política RLS para que un admin pueda ver todos los email_tokens y
-- cola_emails desde la SPA (útil para "reenviar verificación" y
-- diagnóstico de correo).
ALTER TABLE email_tokens ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS email_tokens_admin ON email_tokens;
CREATE POLICY email_tokens_admin ON email_tokens
    FOR SELECT TO web_user USING (es_admin());

ALTER TABLE cola_emails ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS cola_emails_admin ON cola_emails;
CREATE POLICY cola_emails_admin ON cola_emails
    FOR SELECT TO web_user USING (es_admin());
GRANT SELECT ON cola_emails, email_tokens TO web_user;

ALTER TABLE cola_push ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS cola_push_admin ON cola_push;
CREATE POLICY cola_push_admin ON cola_push
    FOR SELECT TO web_user USING (es_admin());
GRANT SELECT ON cola_push TO web_user;

ALTER TABLE sesiones_estudio ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS sesiones_propias ON sesiones_estudio;
CREATE POLICY sesiones_propias ON sesiones_estudio
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());
GRANT SELECT, INSERT, UPDATE ON sesiones_estudio TO web_user;
ALTER TABLE sesiones_estudio
    ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();


-- =============================================================================
--          SISTEMAS DE ESTUDIO, MODO ESTUDIO Y REPETICIÓN ESPACIADA
-- =============================================================================
-- Sistemas de estudio (Pomodoro, Ultradian, etc.) que dictan el
-- patrón de bloques que genera el modo estudio.  Cada uno define
-- min_estudio + min_descanso_corto + ciclos_hasta_descanso_largo +
-- min_descanso_largo.  El motor `iniciar_estudio` mezcla estos
-- bloques con bloques de test y de repaso vencido.

CREATE TABLE IF NOT EXISTS sistemas_estudio (
    id                          serial PRIMARY KEY,
    codigo                      text UNIQUE NOT NULL,
    nombre                      text NOT NULL,
    descripcion                 text,
    min_estudio                 int  NOT NULL CHECK (min_estudio  > 0),
    min_descanso_corto          int  NOT NULL CHECK (min_descanso_corto >= 0),
    ciclos_hasta_descanso_largo int  NOT NULL DEFAULT 4 CHECK (ciclos_hasta_descanso_largo > 0),
    min_descanso_largo          int  NOT NULL DEFAULT 15 CHECK (min_descanso_largo >= 0),
    activo                      boolean NOT NULL DEFAULT true
);

-- Sesión de estudio EN CURSO (una a la vez por usuario).  Contiene
-- la secuencia de bloques generada por `iniciar_estudio`.  Bloque
-- estructura: {tipo, minutos, unidad_id?, tema_nombre?, preguntas_ids?}.
CREATE TABLE IF NOT EXISTS sesion_activa (
    usuario_id       uuid PRIMARY KEY REFERENCES usuarios(id) ON DELETE CASCADE,
    iniciada_en      timestamptz NOT NULL DEFAULT now(),
    plan_bloques     jsonb NOT NULL,
    bloque_idx       int  NOT NULL DEFAULT 0,
    bloque_iniciado  timestamptz NOT NULL DEFAULT now(),
    minutos_totales  int  NOT NULL,
    sistema_id       int  REFERENCES sistemas_estudio(id) ON DELETE SET NULL
);

-- Repetición espaciada tipo SM-2 simplificado (Ebbinghaus + Anki).
-- Un intervalo por (usuario, pregunta):
--   ease_factor: 1.3 – 2.5 (baja con fallos, sube con aciertos)
--   intervalo_dias: días hasta el próximo repaso
--   Al acertar N veces seguidas → intervalo x ease_factor
--   Al fallar → intervalo=0 (repaso mismo día + siguiente día)
CREATE TABLE IF NOT EXISTS repasos_pregunta (
    usuario_id       uuid NOT NULL REFERENCES usuarios(id)  ON DELETE CASCADE,
    pregunta_id      uuid NOT NULL REFERENCES preguntas(id) ON DELETE CASCADE,
    ease_factor      numeric(3,2) NOT NULL DEFAULT 2.5 CHECK (ease_factor BETWEEN 1.3 AND 3.0),
    intervalo_dias   int NOT NULL DEFAULT 0,
    aciertos_ok      int NOT NULL DEFAULT 0,   -- aciertos consecutivos
    fallos_total     int NOT NULL DEFAULT 0,
    ultimo_repaso    timestamptz NOT NULL DEFAULT now(),
    siguiente_repaso timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (usuario_id, pregunta_id)
);
CREATE INDEX IF NOT EXISTS repasos_pregunta_vencidos_idx
    ON repasos_pregunta (usuario_id, siguiente_repaso);

-- Snapshot semanal de métricas (para poder graficar tendencia y
-- justificar ajustes de carga).  El domingo por la noche o al primer
-- login del lunes se calcula el snapshot de la semana anterior.
CREATE TABLE IF NOT EXISTS metricas_semanales (
    usuario_id           uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    semana_inicio        date NOT NULL,    -- lunes de la semana medida
    minutos_estudiados   int  NOT NULL DEFAULT 0,
    minutos_planificados int  NOT NULL DEFAULT 0,
    precision_media      int  NOT NULL DEFAULT 0,  -- %
    fatiga_delta         numeric(5,2),                -- diff aciertos 1ª mitad - 2ª mitad sesión (%)
    dias_activos         int  NOT NULL DEFAULT 0,
    objetivos_cumplidos  int  NOT NULL DEFAULT 0,  -- %
    tema_foco            uuid,                        -- tema con peor rendimiento
    creado_en            timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (usuario_id, semana_inicio)
);
CREATE INDEX IF NOT EXISTS metricas_semanales_uid_idx
    ON metricas_semanales (usuario_id, semana_inicio DESC);

-- Añade referencia opcional al sistema de estudio en plan_estudio.
ALTER TABLE plan_estudio
    ADD COLUMN IF NOT EXISTS sistema_estudio_id int
        REFERENCES sistemas_estudio(id) ON DELETE SET NULL;

-- Semilla de sistemas de estudio contrastados.
INSERT INTO sistemas_estudio(codigo, nombre, descripcion,
    min_estudio, min_descanso_corto, ciclos_hasta_descanso_largo, min_descanso_largo) VALUES
    ('pomodoro',        'Pomodoro clásico',
        '25 min de estudio y 5 min de descanso. Cada 4 ciclos, 15 min de descanso largo.',
        25, 5, 4, 15),
    ('pomodoro_largo',  'Pomodoro largo',
        '50 min de estudio y 10 min de descanso. Cada 3 ciclos, 20 min largo.',
        50, 10, 3, 20),
    ('ultradian',       'Ritmo ultradiano',
        '90 min de estudio profundo y 20 min de descanso. Óptimo para tareas de fondo.',
        90, 20, 2, 30),
    ('bloques_45',      'Bloques de 45',
        '45 min estudio + 15 min descanso. Buen equilibrio entre foco y respiro.',
        45, 15, 3, 25),
    ('sprints',         'Sprints cortos',
        '15 min estudio y 3 min descanso. Ideal para materia densa cuando cuesta arrancar.',
        15, 3, 6, 20)
ON CONFLICT (codigo) DO UPDATE
   SET nombre                      = EXCLUDED.nombre,
       descripcion                 = EXCLUDED.descripcion,
       min_estudio                 = EXCLUDED.min_estudio,
       min_descanso_corto          = EXCLUDED.min_descanso_corto,
       ciclos_hasta_descanso_largo = EXCLUDED.ciclos_hasta_descanso_largo,
       min_descanso_largo          = EXCLUDED.min_descanso_largo;

-- Permisos y RLS
ALTER TABLE sistemas_estudio      ENABLE ROW LEVEL SECURITY;
ALTER TABLE sesion_activa         ENABLE ROW LEVEL SECURITY;
ALTER TABLE repasos_pregunta      ENABLE ROW LEVEL SECURITY;
ALTER TABLE metricas_semanales    ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS sistemas_lectura ON sistemas_estudio;
CREATE POLICY sistemas_lectura ON sistemas_estudio FOR SELECT USING (true);
GRANT SELECT ON sistemas_estudio TO web_anon, web_user;

DROP POLICY IF EXISTS sesion_activa_propia ON sesion_activa;
CREATE POLICY sesion_activa_propia ON sesion_activa
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());
GRANT SELECT, INSERT, UPDATE, DELETE ON sesion_activa TO web_user;
ALTER TABLE sesion_activa ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();

DROP POLICY IF EXISTS repasos_pregunta_propios ON repasos_pregunta;
CREATE POLICY repasos_pregunta_propios ON repasos_pregunta
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());
GRANT SELECT, INSERT, UPDATE, DELETE ON repasos_pregunta TO web_user;
ALTER TABLE repasos_pregunta ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();

DROP POLICY IF EXISTS metricas_semanales_propias ON metricas_semanales;
CREATE POLICY metricas_semanales_propias ON metricas_semanales
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());
GRANT SELECT, INSERT, UPDATE ON metricas_semanales TO web_user;
ALTER TABLE metricas_semanales ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();


-- =============================================================================
--          RPCs DE REPETICIÓN ESPACIADA (SM-2 simplificado)
-- =============================================================================
-- Al responder una pregunta desde el modo estudio o desde un test,
-- el frontend llama a `registrar_respuesta_espaciada` con el
-- resultado.  El algoritmo:
--
--   ACIERTO:
--     aciertos_ok += 1
--     ease_factor = min(3.0, ease_factor + 0.1)
--     nuevo intervalo:
--       aciertos_ok == 1 → 1 día
--       aciertos_ok == 2 → 3 días
--       aciertos_ok == 3 → 7 días
--       aciertos_ok >= 4 → intervalo_dias * ease_factor  (Anki-like)
--
--   FALLO:
--     aciertos_ok = 0
--     fallos_total += 1
--     ease_factor = max(1.3, ease_factor - 0.2)
--     intervalo = 0  → se repite HOY (al final del día en el modo
--     estudio siguiente); si vuelve a fallar mañana, otra vuelta.

CREATE OR REPLACE FUNCTION registrar_respuesta_espaciada(
    p_pregunta_id uuid,
    p_correcta    boolean
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_uid  uuid := jwt_usuario_id();
    v_row  repasos_pregunta;
    v_int  int;
    v_ef   numeric(3,2);
    v_ok   int;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;

    SELECT * INTO v_row FROM repasos_pregunta
     WHERE usuario_id = v_uid AND pregunta_id = p_pregunta_id;

    IF v_row.pregunta_id IS NULL THEN
        v_ef := 2.5; v_int := 0; v_ok := 0;
    ELSE
        v_ef := v_row.ease_factor;
        v_int := v_row.intervalo_dias;
        v_ok := v_row.aciertos_ok;
    END IF;

    IF p_correcta THEN
        v_ok := v_ok + 1;
        v_ef := LEAST(3.0, v_ef + 0.1);
        v_int := CASE
            WHEN v_ok = 1 THEN 1
            WHEN v_ok = 2 THEN 3
            WHEN v_ok = 3 THEN 7
            ELSE GREATEST(1, ROUND(GREATEST(v_int, 1) * v_ef))::int
        END;
    ELSE
        v_ok := 0;
        v_ef := GREATEST(1.3, v_ef - 0.2);
        v_int := 0;                    -- repaso mismo día
    END IF;

    INSERT INTO repasos_pregunta(usuario_id, pregunta_id,
            ease_factor, intervalo_dias, aciertos_ok, fallos_total,
            ultimo_repaso, siguiente_repaso)
    VALUES (v_uid, p_pregunta_id, v_ef, v_int, v_ok,
            CASE WHEN p_correcta THEN 0 ELSE 1 END,
            now(), now() + (v_int || ' days')::interval)
    ON CONFLICT (usuario_id, pregunta_id) DO UPDATE
       SET ease_factor      = EXCLUDED.ease_factor,
           intervalo_dias   = EXCLUDED.intervalo_dias,
           aciertos_ok      = EXCLUDED.aciertos_ok,
           fallos_total     = repasos_pregunta.fallos_total
                               + CASE WHEN p_correcta THEN 0 ELSE 1 END,
           ultimo_repaso    = now(),
           siguiente_repaso = now() + (EXCLUDED.intervalo_dias || ' days')::interval;

    RETURN jsonb_build_object(
        'intervalo_dias', v_int,
        'ease_factor',    v_ef,
        'siguiente_repaso', now() + (v_int || ' days')::interval
    );
END $$;

-- Devuelve N ids de pregunta vencidas (siguiente_repaso <= now())
-- ordenadas por urgencia (más olvidadas primero).
CREATE OR REPLACE FUNCTION siguientes_repasos(p_max int DEFAULT 10) RETURNS uuid[]
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(array_agg(pregunta_id ORDER BY siguiente_repaso), ARRAY[]::uuid[])
      FROM (
        SELECT pregunta_id, siguiente_repaso
          FROM repasos_pregunta
         WHERE usuario_id = jwt_usuario_id()
           AND siguiente_repaso <= now()
         ORDER BY siguiente_repaso
         LIMIT p_max
      ) t;
$$;


-- =============================================================================
--                   MODO ESTUDIO — iniciar / siguiente / cerrar
-- =============================================================================
-- El usuario pulsa "Estudiar" y dice cuántos minutos tiene.  El
-- motor genera una secuencia adaptada a su sistema de estudio,
-- intercalando bloques de tipo:
--   estudio  → unidad pendiente (misma que el plan del día)
--   repaso   → preguntas vencidas de repasos_pregunta
--   test     → test rápido de una unidad casi acabada
--   descanso → según el sistema
--
-- El frontend consume `sesion_activa` y va llamando a
-- `siguiente_bloque_estudio()` que devuelve el bloque siguiente y
-- marca el anterior como cerrado.

CREATE OR REPLACE FUNCTION iniciar_estudio(
    p_minutos_total int,
    p_sistema_id    int DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_uid   uuid := jwt_usuario_id();
    v_plan  plan_estudio;
    v_sis   sistemas_estudio;
    v_bloques jsonb := '[]'::jsonb;
    v_minutos_restantes int := p_minutos_total;
    v_ciclo int := 0;
    v_unids uuid[];
    v_idx   int := 1;
    v_repasos uuid[];
    v_repaso_pos int := 1;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    IF p_minutos_total < 10 THEN RAISE EXCEPTION 'minutos_insuficientes'; END IF;

    -- Sistema: parámetro > plan > default 'pomodoro'.
    SELECT * INTO v_plan FROM plan_estudio
     WHERE usuario_id = v_uid AND activo LIMIT 1;

    SELECT * INTO v_sis FROM sistemas_estudio
     WHERE id = COALESCE(p_sistema_id, v_plan.sistema_estudio_id)
        OR codigo = 'pomodoro'
     ORDER BY (id = COALESCE(p_sistema_id, v_plan.sistema_estudio_id)) DESC
     LIMIT 1;

    -- Cola de unidades pendientes.
    SELECT COALESCE(array_agg(u.id ORDER BY ot.orden, u.orden), ARRAY[]::uuid[])
      INTO v_unids
      FROM oposicion_temas ot
      JOIN unidades u ON u.tema_id = ot.tema_id
 LEFT JOIN progreso_unidad pu
        ON pu.unidad_id = u.id AND pu.usuario_id = v_uid
     WHERE ot.oposicion_id = COALESCE(
             v_plan.oposicion_id,
             (SELECT oposicion_id FROM usuario_oposiciones
               WHERE usuario_id = v_uid AND principal LIMIT 1))
       AND COALESCE(pu.teoria_completada, false) = false;

    v_repasos := siguientes_repasos(50);

    -- Genera bloques hasta agotar los minutos.
    WHILE v_minutos_restantes >= v_sis.min_estudio LOOP
        -- Bloque de estudio: primero repaso si hay vencidos.
        IF v_repaso_pos <= cardinality(v_repasos) THEN
            v_bloques := v_bloques || jsonb_build_object(
                'tipo',    'repaso',
                'minutos', v_sis.min_estudio,
                'preguntas_ids', ARRAY(
                    SELECT v_repasos[i]
                      FROM generate_series(v_repaso_pos,
                           LEAST(v_repaso_pos + 4, cardinality(v_repasos))) i
                )
            );
            v_repaso_pos := v_repaso_pos + 5;
        ELSIF v_idx <= cardinality(v_unids) THEN
            v_bloques := v_bloques || jsonb_build_object(
                'tipo',      'estudio',
                'minutos',   v_sis.min_estudio,
                'unidad_id', v_unids[v_idx]
            );
            v_idx := v_idx + 1;
        ELSE
            -- Nada que estudiar → salir
            EXIT;
        END IF;

        v_minutos_restantes := v_minutos_restantes - v_sis.min_estudio;
        v_ciclo := v_ciclo + 1;

        -- Descanso.
        IF v_ciclo % v_sis.ciclos_hasta_descanso_largo = 0
           AND v_minutos_restantes >= v_sis.min_descanso_largo THEN
            v_bloques := v_bloques || jsonb_build_object(
                'tipo', 'descanso_largo', 'minutos', v_sis.min_descanso_largo);
            v_minutos_restantes := v_minutos_restantes - v_sis.min_descanso_largo;
        ELSIF v_minutos_restantes >= v_sis.min_descanso_corto THEN
            v_bloques := v_bloques || jsonb_build_object(
                'tipo', 'descanso', 'minutos', v_sis.min_descanso_corto);
            v_minutos_restantes := v_minutos_restantes - v_sis.min_descanso_corto;
        END IF;
    END LOOP;

    -- Cierre + celebración final.
    v_bloques := v_bloques || jsonb_build_object(
        'tipo', 'final', 'minutos', 0);

    -- Reemplaza sesión previa si la hubiera.
    DELETE FROM sesion_activa WHERE usuario_id = v_uid;
    INSERT INTO sesion_activa(usuario_id, plan_bloques, minutos_totales, sistema_id)
    VALUES (v_uid, v_bloques, p_minutos_total, v_sis.id);

    RETURN jsonb_build_object(
        'ok', true, 'bloques', v_bloques,
        'sistema', jsonb_build_object('id', v_sis.id, 'nombre', v_sis.nombre,
                                       'codigo', v_sis.codigo));
END $$;

-- Marca el bloque actual como cerrado y devuelve el siguiente.
CREATE OR REPLACE FUNCTION siguiente_bloque_estudio() RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_s   sesion_activa;
    v_siguiente jsonb;
BEGIN
    SELECT * INTO v_s FROM sesion_activa WHERE usuario_id = v_uid;
    IF v_s.usuario_id IS NULL THEN RAISE EXCEPTION 'sin_sesion_activa'; END IF;

    UPDATE sesion_activa
       SET bloque_idx = bloque_idx + 1,
           bloque_iniciado = now()
     WHERE usuario_id = v_uid;

    v_siguiente := (v_s.plan_bloques -> (v_s.bloque_idx + 1));
    RETURN COALESCE(v_siguiente, jsonb_build_object('tipo', 'final'));
END $$;

-- Saltar descanso (sólo si el bloque actual es descanso).  Reduce
-- los minutos totales de la sesión y avanza al siguiente.
CREATE OR REPLACE FUNCTION saltar_descanso() RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_uid  uuid := jwt_usuario_id();
    v_s    sesion_activa;
    v_bloq jsonb;
BEGIN
    SELECT * INTO v_s FROM sesion_activa WHERE usuario_id = v_uid;
    IF v_s.usuario_id IS NULL THEN RAISE EXCEPTION 'sin_sesion_activa'; END IF;
    v_bloq := v_s.plan_bloques -> v_s.bloque_idx;
    IF v_bloq->>'tipo' NOT IN ('descanso', 'descanso_largo') THEN
        RAISE EXCEPTION 'bloque_no_es_descanso';
    END IF;
    RETURN siguiente_bloque_estudio();
END $$;

-- Cierra la sesión, calcula minutos activos totales y devuelve
-- resumen (aciertos, fatiga aproximada).
CREATE OR REPLACE FUNCTION cerrar_estudio() RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_uid    uuid := jwt_usuario_id();
    v_s      sesion_activa;
    v_min    int;
BEGIN
    SELECT * INTO v_s FROM sesion_activa WHERE usuario_id = v_uid;
    IF v_s.usuario_id IS NULL THEN RETURN jsonb_build_object('ok', true); END IF;

    v_min := EXTRACT(EPOCH FROM (now() - v_s.iniciada_en))::int / 60;
    DELETE FROM sesion_activa WHERE usuario_id = v_uid;

    -- Suma XP proporcional a los minutos activos reales.
    UPDATE usuario_gamificacion
       SET xp_total = xp_total + v_min,
           ultimo_dia_activo = current_date,
           actualizado_en = now()
     WHERE usuario_id = v_uid;

    RETURN jsonb_build_object(
        'ok', true,
        'minutos_totales', v_min,
        'bloques_completados', v_s.bloque_idx
    );
END $$;

-- Devuelve la sesión activa (para restaurar al recargar la SPA).
CREATE OR REPLACE FUNCTION obtener_sesion_activa() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN usuario_id IS NULL THEN NULL::jsonb
                ELSE jsonb_build_object(
                    'iniciada_en',     iniciada_en,
                    'plan_bloques',    plan_bloques,
                    'bloque_idx',      bloque_idx,
                    'bloque_iniciado', bloque_iniciado,
                    'minutos_totales', minutos_totales,
                    'sistema_id',      sistema_id
                ) END
      FROM sesion_activa WHERE usuario_id = jwt_usuario_id();
$$;


-- =============================================================================
--        MÉTRICAS SEMANALES (rendimiento, fatiga, consistencia, foco)
-- =============================================================================
-- Calcula el snapshot de la semana pasada (o de una fecha dada) y
-- lo persiste.  Devuelve el objeto con TODAS las métricas + un
-- mensaje motivador según el cumplimiento.

CREATE OR REPLACE FUNCTION calcular_metricas_semanales(p_semana_inicio date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_uid    uuid := jwt_usuario_id();
    v_lunes  date := COALESCE(p_semana_inicio,
                        date_trunc('week', current_date - interval '7 days')::date);
    v_domingo date := v_lunes + 6;
    v_minutos int;
    v_planif  int;
    v_precision int;
    v_dias_act int;
    v_obj_pct int;
    v_fatiga  numeric(5,2);
    v_tema_foco uuid;
    v_msg  text;
    v_row  metricas_semanales;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;

    -- Minutos activos reales (sesiones_estudio).
    SELECT COALESCE(SUM(minutos_activos), 0)::int INTO v_minutos
      FROM sesiones_estudio
     WHERE usuario_id = v_uid
       AND abierta_en::date BETWEEN v_lunes AND v_domingo;

    -- Minutos planificados según plan del usuario.
    SELECT COALESCE(SUM(minutos), 0)::int INTO v_planif
      FROM plan_sesiones ps
      JOIN plan_estudio p ON p.id = ps.plan_id
     WHERE p.usuario_id = v_uid
       AND ps.fecha BETWEEN v_lunes AND v_domingo;

    -- Precisión media (%).
    SELECT COALESCE(ROUND(AVG(CASE WHEN r.correcta THEN 100 ELSE 0 END))::int, 0)
      INTO v_precision
      FROM respuestas r
      JOIN intentos i ON i.id = r.intento_id
     WHERE i.usuario_id = v_uid
       AND r.respondida_en::date BETWEEN v_lunes AND v_domingo;

    -- Días activos.
    SELECT COUNT(DISTINCT abierta_en::date) INTO v_dias_act
      FROM sesiones_estudio
     WHERE usuario_id = v_uid
       AND abierta_en::date BETWEEN v_lunes AND v_domingo;

    -- % objetivos cumplidos.
    v_obj_pct := CASE WHEN v_planif = 0 THEN 0
                      ELSE LEAST(100, ROUND(v_minutos::numeric * 100 / v_planif))::int
                 END;

    -- Fatiga: correlación negativa entre "posición temporal en la
    -- sesión" y "acierto".  Aproximación: diferencia de precisión
    -- entre la 1ª mitad y la 2ª mitad de cada intento.
    WITH intentos_semana AS (
        SELECT i.id
          FROM intentos i
         WHERE i.usuario_id = v_uid
           AND i.iniciado_en::date BETWEEN v_lunes AND v_domingo
           AND i.finalizado_en IS NOT NULL
    ),
    con_pos AS (
        SELECT r.intento_id, r.correcta,
               row_number() OVER (PARTITION BY r.intento_id ORDER BY r.id) AS pos,
               count(*)     OVER (PARTITION BY r.intento_id) AS total
          FROM respuestas r
         WHERE r.intento_id IN (SELECT id FROM intentos_semana)
    )
    SELECT ROUND(
             (avg(CASE WHEN pos <= total/2 AND correcta THEN 100
                       WHEN pos <= total/2 THEN 0 END) -
              avg(CASE WHEN pos >  total/2 AND correcta THEN 100
                       WHEN pos >  total/2 THEN 0 END))::numeric, 2)
      INTO v_fatiga FROM con_pos;

    -- Tema foco = peor porcentaje de aciertos en la semana.
    SELECT t.id INTO v_tema_foco
      FROM temas t
      JOIN unidades u ON u.tema_id = t.id
      JOIN preguntas p ON p.unidad_id = u.id
      JOIN respuestas r ON r.pregunta_id = p.id
      JOIN intentos i ON i.id = r.intento_id
     WHERE i.usuario_id = v_uid
       AND r.respondida_en::date BETWEEN v_lunes AND v_domingo
     GROUP BY t.id
     ORDER BY avg(CASE WHEN r.correcta THEN 1.0 ELSE 0 END)
     LIMIT 1;

    -- Persistir snapshot.
    INSERT INTO metricas_semanales(usuario_id, semana_inicio,
        minutos_estudiados, minutos_planificados, precision_media,
        fatiga_delta, dias_activos, objetivos_cumplidos, tema_foco)
    VALUES (v_uid, v_lunes, v_minutos, v_planif, v_precision,
            v_fatiga, v_dias_act, v_obj_pct, v_tema_foco)
    ON CONFLICT (usuario_id, semana_inicio) DO UPDATE
       SET minutos_estudiados   = EXCLUDED.minutos_estudiados,
           minutos_planificados = EXCLUDED.minutos_planificados,
           precision_media      = EXCLUDED.precision_media,
           fatiga_delta         = EXCLUDED.fatiga_delta,
           dias_activos         = EXCLUDED.dias_activos,
           objetivos_cumplidos  = EXCLUDED.objetivos_cumplidos,
           tema_foco            = EXCLUDED.tema_foco
    RETURNING * INTO v_row;

    -- Mensaje motivador (nunca deprimir):
    v_msg := CASE
        WHEN v_obj_pct >= 90 THEN '¡Semana brillante! Vas fuerte y con constancia.'
        WHEN v_obj_pct >= 60 THEN 'Buena semana. Con un empujoncito llegas al 100%.'
        WHEN v_obj_pct >= 30 THEN 'Has puesto minutos importantes. La próxima subimos.'
        ELSE 'Pequeños pasos también cuentan. Vamos a por una semana redonda.'
    END;

    RETURN jsonb_build_object(
        'semana_inicio', v_lunes,
        'minutos_estudiados', v_minutos,
        'minutos_planificados', v_planif,
        'precision_media', v_precision,
        'fatiga_delta', v_fatiga,
        'dias_activos', v_dias_act,
        'objetivos_cumplidos', v_obj_pct,
        'tema_foco', v_tema_foco,
        'mensaje', v_msg
    );
END $$;

-- Ajusta la carga del próximo plan según el cumplimiento semanal:
--  < 50% → -20%   |  50-90% → sin cambio  |  > 90% → +15%
CREATE OR REPLACE FUNCTION ajustar_carga_semanal() RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_uid   uuid := jwt_usuario_id();
    v_plan  plan_estudio;
    v_snap  metricas_semanales;
    v_mul   numeric := 1.0;
    v_hpd   jsonb;
    v_dow   text;
BEGIN
    SELECT * INTO v_plan FROM plan_estudio WHERE usuario_id = v_uid AND activo LIMIT 1;
    IF v_plan.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'motivo', 'sin_plan'); END IF;

    -- Snapshot de la semana anterior.
    SELECT * INTO v_snap FROM metricas_semanales
     WHERE usuario_id = v_uid
     ORDER BY semana_inicio DESC LIMIT 1;

    IF v_snap.usuario_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'motivo', 'sin_datos'); END IF;

    v_mul := CASE
        WHEN v_snap.objetivos_cumplidos < 50 THEN 0.8
        WHEN v_snap.objetivos_cumplidos > 90 THEN 1.15
        ELSE 1.0
    END;

    IF v_mul <> 1.0 THEN
        v_hpd := v_plan.horas_por_dia;
        FOR v_dow IN SELECT unnest(ARRAY['lun','mar','mie','jue','vie','sab','dom']) LOOP
            v_hpd := jsonb_set(v_hpd, ARRAY[v_dow],
                to_jsonb(GREATEST(0, ROUND((COALESCE((v_hpd->>v_dow)::numeric, 0) * v_mul)::numeric, 1))));
        END LOOP;
        UPDATE plan_estudio
           SET horas_por_dia = v_hpd, actualizado_en = now()
         WHERE id = v_plan.id;
        PERFORM generar_plan(v_plan.id, 14);
    END IF;

    RETURN jsonb_build_object('ok', true, 'multiplicador', v_mul);
END $$;

-- Resumen semanal para banner al inicio.
CREATE OR REPLACE FUNCTION resumen_semanal() RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_snap metricas_semanales;
BEGIN
    -- Si no hay snapshot esta semana, calcúlalo.
    SELECT * INTO v_snap FROM metricas_semanales
     WHERE usuario_id = jwt_usuario_id()
     ORDER BY semana_inicio DESC LIMIT 1;
    IF v_snap.usuario_id IS NULL OR v_snap.semana_inicio <
       (date_trunc('week', current_date - interval '7 days')::date) THEN
        PERFORM calcular_metricas_semanales();
        SELECT * INTO v_snap FROM metricas_semanales
         WHERE usuario_id = jwt_usuario_id()
         ORDER BY semana_inicio DESC LIMIT 1;
    END IF;
    RETURN COALESCE(row_to_json(v_snap)::jsonb, 'null'::jsonb);
END $$;


-- =============================================================================
--                 NOTIFICACIONES AUTOMÁTICAS (encola cola_push)
-- =============================================================================
-- Función utilitaria que un cron externo puede llamar cada día para
-- encolar avisos:
--   - Usuarios inactivos >24 h que no han estudiado hoy → recordatorio.
--   - Domingos → resumen de la semana + objetivos siguientes.
-- No manda notificación si ya hay una encolada sin enviar para
-- ese usuario en las últimas 20 h (evita ruido).

CREATE OR REPLACE FUNCTION encolar_notificaciones_diarias() RETURNS int
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_n int := 0;
    r   record;
BEGIN
    -- Recordatorio de estudio: activos, verificados, con plan, sin
    -- sesión en las últimas 24 h.  No se encola si ya hay una push
    -- pendiente de envío en las últimas 20 h (evita ruido).
    FOR r IN
        SELECT u.id, u.nombre
          FROM usuarios u
          JOIN plan_estudio p ON p.usuario_id = u.id AND p.activo
         WHERE u.activo AND u.email_verificado
           AND NOT EXISTS (
                SELECT 1 FROM sesiones_estudio s
                 WHERE s.usuario_id = u.id
                   AND s.abierta_en > now() - interval '24 hours')
           AND NOT EXISTS (
                SELECT 1 FROM cola_push cp
                 WHERE cp.usuario_id = u.id
                   AND cp.encolado_en > now() - interval '20 hours'
                   AND cp.enviado_en IS NULL)
    LOOP
        INSERT INTO cola_push(usuario_id, titulo, cuerpo, url)
        VALUES (r.id,
                'Te esperamos, ' || COALESCE(r.nombre, ''),
                'Un bloque corto de estudio hoy suma mucho. ¿Le damos?',
                app_url());
        v_n := v_n + 1;
    END LOOP;

    -- Domingos: resumen + objetivos siguiente semana.
    IF EXTRACT(ISODOW FROM current_date)::int = 7 THEN
        FOR r IN
            SELECT u.id, u.nombre
              FROM usuarios u
              JOIN plan_estudio p ON p.usuario_id = u.id AND p.activo
             WHERE u.activo AND u.email_verificado
               AND NOT EXISTS (
                    SELECT 1 FROM cola_push cp
                     WHERE cp.usuario_id = u.id
                       AND cp.encolado_en > now() - interval '20 hours'
                       AND cp.enviado_en IS NULL)
        LOOP
            INSERT INTO cola_push(usuario_id, titulo, cuerpo, url)
            VALUES (r.id,
                    'Nueva semana, ' || COALESCE(r.nombre, ''),
                    'Vamos a revisar cómo fue la semana y qué toca ahora.',
                    app_url());
            v_n := v_n + 1;
        END LOOP;
    END IF;

    RETURN v_n;
END $$;

-- Aplica el recálculo semanal para TODOS los usuarios activos.
-- Se llama desde el notificador los lunes de madrugada.
CREATE OR REPLACE FUNCTION cron_semanal() RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    r record;
    v_metrica int := 0;
    v_ajuste  int := 0;
BEGIN
    FOR r IN
        SELECT u.id FROM usuarios u
          JOIN plan_estudio p ON p.usuario_id = u.id AND p.activo
         WHERE u.activo
    LOOP
        -- Simula el contexto JWT del usuario para llamar a las RPCs
        -- basadas en jwt_usuario_id().  Al ser SECURITY DEFINER puede
        -- hacerlo con set_config.
        PERFORM set_config('request.jwt.claims',
                            jsonb_build_object('sub', r.id, 'roles', ARRAY[]::text[])::text,
                            true);
        BEGIN
            PERFORM calcular_metricas_semanales();
            v_metrica := v_metrica + 1;
            PERFORM ajustar_carga_semanal();
            v_ajuste  := v_ajuste + 1;
        EXCEPTION WHEN OTHERS THEN
            -- ignora fallos individuales para no abortar el batch
            NULL;
        END;
    END LOOP;
    -- Limpia claim para no afectar a llamadas posteriores.
    PERFORM set_config('request.jwt.claims', '', true);
    RETURN jsonb_build_object('metricas_calculadas', v_metrica,
                              'planes_ajustados',    v_ajuste);
END $$;


-- =============================================================================
--                    RECUPERACIÓN DE CONTRASEÑA
-- =============================================================================
-- Flujo: solicitar_reset(email) genera token de 3 días y encola el
-- correo; aplicar_reset(token, nueva) verifica y cambia la contraseña.
-- Respuesta silenciosa aunque el email no exista (no filtramos cuentas).

CREATE OR REPLACE FUNCTION solicitar_reset(p_email text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_email text := lower(btrim(p_email));
    v_usr   usuarios;
    v_token text;
BEGIN
    SELECT * INTO v_usr FROM usuarios WHERE email = v_email AND activo;
    IF v_usr.id IS NULL THEN
        RETURN jsonb_build_object('ok', true);   -- silencioso
    END IF;

    UPDATE email_tokens SET usado_en = now()
     WHERE usuario_id = v_usr.id AND tipo = 'reset_password' AND usado_en IS NULL;

    v_token := encode(gen_random_bytes(32), 'hex');
    INSERT INTO email_tokens(usuario_id, tipo, token, expira_en)
    VALUES (v_usr.id, 'reset_password', v_token, now() + interval '3 days');

    INSERT INTO cola_emails(destinatario, asunto, cuerpo_txt, cuerpo_html)
    VALUES (
        v_email,
        'Restablece tu contraseña en Aprentix',
        format(E'Hola %s,\n\nHas solicitado restablecer tu contraseña. Abre este enlace:\n%s/#/reset?token=%s\n\nSi no has sido tú, ignora este mensaje.\n\nEl enlace caduca en 3 días.\n\n— Aprentix',
               v_usr.nombre, app_url(), v_token),
        format($html$<p>Hola <strong>%s</strong>,</p>
<p>Has solicitado restablecer tu contraseña. Pulsa el botón para elegir una nueva:</p>
<p><a href="%s/#/reset?token=%s" style="background:#6B8E23;color:#fff;padding:12px 22px;border-radius:22px;text-decoration:none;display:inline-block">Elegir nueva contraseña</a></p>
<p style="color:#62705A">Si no has sido tú, ignora este mensaje.<br>El enlace caduca en 3 días.</p>$html$,
               v_usr.nombre, app_url(), v_token)
    );
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION aplicar_reset(p_token text, p_password text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE v_tok email_tokens;
BEGIN
    IF length(p_password) < 8 THEN RAISE EXCEPTION 'password_debil'; END IF;

    SELECT * INTO v_tok FROM email_tokens
     WHERE token = p_token AND tipo = 'reset_password';
    IF v_tok.id IS NULL OR v_tok.usado_en IS NOT NULL OR v_tok.expira_en < now() THEN
        RAISE EXCEPTION 'token_invalido';
    END IF;

    UPDATE usuarios
       SET password_hash    = crypt(p_password, gen_salt('bf', 12)),
           email_verificado = true
     WHERE id = v_tok.usuario_id;
    UPDATE email_tokens SET usado_en = now() WHERE id = v_tok.id;
    RETURN jsonb_build_object('ok', true);
END $$;


-- =============================================================================
--             EDICIÓN DE OPOSICIONES (admin) — nombre, fecha, activa
-- =============================================================================

CREATE OR REPLACE FUNCTION admin_editar_oposicion(
    p_oposicion_id           uuid,
    p_nombre                 text    DEFAULT NULL,
    p_descripcion            text    DEFAULT NULL,
    p_organismo              text    DEFAULT NULL,
    p_fecha_examen           date    DEFAULT NULL,
    p_fecha_examen_orientativa boolean DEFAULT NULL,
    p_activa                 boolean DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    UPDATE oposiciones
       SET nombre                   = COALESCE(p_nombre, nombre),
           descripcion              = COALESCE(p_descripcion, descripcion),
           organismo                = COALESCE(p_organismo, organismo),
           fecha_examen             = COALESCE(p_fecha_examen, fecha_examen),
           fecha_examen_orientativa = COALESCE(p_fecha_examen_orientativa,
                                                fecha_examen_orientativa),
           activa                   = COALESCE(p_activa, activa)
     WHERE id = p_oposicion_id;
    RETURN jsonb_build_object('ok', true);
END $$;


-- =============================================================================
--              EDITOR VISUAL DE OPOSICIONES — RPCs admin
-- =============================================================================
-- Estas RPCs son azúcar sintáctico sobre INSERT/UPDATE/DELETE que ya
-- están cubiertos por RLS.  La ventaja es que devuelven el objeto
-- completo tras cada mutación y validan `es_admin()` en un solo
-- lugar (evita depender de los policies para 40 llamadas del editor).

-- ── TEMAS ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_temas_de_oposicion(p_oposicion_id uuid)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'tema_id',       t.id,
        'slug',          t.slug,
        'nombre',        t.nombre,
        'icono',         t.icono,
        'descripcion',   t.descripcion,
        'orden',         ot.orden,
        'num_unidades',  (SELECT count(*) FROM unidades u WHERE u.tema_id = t.id),
        'num_preguntas', (SELECT count(*) FROM preguntas p
                            JOIN unidades u ON u.id = p.unidad_id
                           WHERE u.tema_id = t.id)
    ) ORDER BY ot.orden), '[]'::jsonb)
      FROM oposicion_temas ot
      JOIN temas t ON t.id = ot.tema_id
     WHERE ot.oposicion_id = p_oposicion_id;
$$;

-- Crea o actualiza un tema y opcionalmente lo vincula a la oposición
-- (si `p_oposicion_id` es NULL, sólo crea/actualiza).
CREATE OR REPLACE FUNCTION admin_upsert_tema(
    p_tema_id      uuid    DEFAULT NULL,   -- NULL = crear
    p_slug         text    DEFAULT NULL,
    p_nombre       text    DEFAULT NULL,
    p_descripcion  text    DEFAULT NULL,
    p_icono        text    DEFAULT '📘',
    p_oposicion_id uuid    DEFAULT NULL,
    p_orden        int     DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'no_autorizado'; END IF;

    IF p_tema_id IS NULL THEN
        IF p_slug IS NULL OR p_nombre IS NULL THEN
            RAISE EXCEPTION 'slug_y_nombre_requeridos';
        END IF;
        INSERT INTO temas(slug, nombre, descripcion, icono)
        VALUES (p_slug, p_nombre, p_descripcion, COALESCE(p_icono, '📘'))
        RETURNING id INTO v_id;
    ELSE
        v_id := p_tema_id;
        UPDATE temas
           SET slug        = COALESCE(p_slug, slug),
               nombre      = COALESCE(p_nombre, nombre),
               descripcion = COALESCE(p_descripcion, descripcion),
               icono       = COALESCE(p_icono, icono)
         WHERE id = v_id;
    END IF;

    IF p_oposicion_id IS NOT NULL THEN
        INSERT INTO oposicion_temas(oposicion_id, tema_id, orden)
        VALUES (p_oposicion_id, v_id,
                COALESCE(p_orden,
                    (SELECT COALESCE(max(orden), 0) + 1
                       FROM oposicion_temas WHERE oposicion_id = p_oposicion_id)))
        ON CONFLICT (oposicion_id, tema_id) DO UPDATE
           SET orden = COALESCE(p_orden, oposicion_temas.orden);
    END IF;

    RETURN jsonb_build_object('tema_id', v_id);
END $$;

CREATE OR REPLACE FUNCTION admin_desvincular_tema(p_oposicion_id uuid, p_tema_id uuid)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    DELETE FROM oposicion_temas
     WHERE oposicion_id = p_oposicion_id AND tema_id = p_tema_id;
END $$;

CREATE OR REPLACE FUNCTION admin_reordenar_temas(
    p_oposicion_id uuid, p_tema_ids uuid[]
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE i int;
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    FOR i IN 1..cardinality(p_tema_ids) LOOP
        UPDATE oposicion_temas
           SET orden = i
         WHERE oposicion_id = p_oposicion_id AND tema_id = p_tema_ids[i];
    END LOOP;
END $$;

-- ── UNIDADES ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_unidades_de_tema(p_tema_id uuid) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id',            u.id,
        'slug',          u.slug,
        'nombre',        u.nombre,
        'orden',         u.orden,
        'resumen',       u.resumen,
        'minutos_est',   u.minutos_est,
        'teoria_md',     u.teoria_md,
        'num_preguntas', (SELECT count(*) FROM preguntas p WHERE p.unidad_id = u.id)
    ) ORDER BY u.orden), '[]'::jsonb)
      FROM unidades u WHERE u.tema_id = p_tema_id;
$$;

CREATE OR REPLACE FUNCTION admin_upsert_unidad(
    p_unidad_id   uuid   DEFAULT NULL,
    p_tema_id     uuid   DEFAULT NULL,
    p_slug        text   DEFAULT NULL,
    p_nombre      text   DEFAULT NULL,
    p_orden       int    DEFAULT NULL,
    p_teoria_md   text   DEFAULT NULL,
    p_resumen     text   DEFAULT NULL,
    p_minutos_est int    DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    IF p_unidad_id IS NULL THEN
        IF p_tema_id IS NULL OR p_slug IS NULL OR p_nombre IS NULL THEN
            RAISE EXCEPTION 'tema_slug_nombre_requeridos';
        END IF;
        INSERT INTO unidades(tema_id, slug, nombre, orden,
                             teoria_md, resumen, minutos_est)
        VALUES (p_tema_id, p_slug, p_nombre,
                COALESCE(p_orden,
                    (SELECT COALESCE(max(orden), 0) + 1
                       FROM unidades WHERE tema_id = p_tema_id)),
                COALESCE(p_teoria_md, ''),
                p_resumen,
                COALESCE(p_minutos_est, 20))
        RETURNING id INTO v_id;
    ELSE
        v_id := p_unidad_id;
        UPDATE unidades
           SET slug        = COALESCE(p_slug, slug),
               nombre      = COALESCE(p_nombre, nombre),
               orden       = COALESCE(p_orden, orden),
               teoria_md   = COALESCE(p_teoria_md, teoria_md),
               resumen     = COALESCE(p_resumen, resumen),
               minutos_est = COALESCE(p_minutos_est, minutos_est)
         WHERE id = v_id;
    END IF;
    RETURN jsonb_build_object('unidad_id', v_id);
END $$;

CREATE OR REPLACE FUNCTION admin_borrar_unidad(p_unidad_id uuid) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    DELETE FROM unidades WHERE id = p_unidad_id;
END $$;

-- ── PREGUNTAS ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION admin_preguntas_de_unidad(p_unidad_id uuid) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id',          p.id,
        'enunciado',   p.enunciado,
        'opciones',    p.opciones,
        'explicacion', p.explicacion,
        'dificultad',  p.dificultad
    ) ORDER BY p.creada_en), '[]'::jsonb)
      FROM preguntas p WHERE p.unidad_id = p_unidad_id;
$$;

CREATE OR REPLACE FUNCTION admin_upsert_pregunta(
    p_pregunta_id uuid  DEFAULT NULL,
    p_unidad_id   uuid  DEFAULT NULL,
    p_enunciado   text  DEFAULT NULL,
    p_opciones    jsonb DEFAULT NULL,
    p_explicacion text  DEFAULT NULL,
    p_dificultad  int   DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    IF p_pregunta_id IS NULL THEN
        IF p_unidad_id IS NULL OR p_enunciado IS NULL OR p_opciones IS NULL THEN
            RAISE EXCEPTION 'unidad_enunciado_opciones_requeridos';
        END IF;
        INSERT INTO preguntas(unidad_id, enunciado, opciones,
                              explicacion, dificultad)
        VALUES (p_unidad_id, p_enunciado, p_opciones,
                p_explicacion, COALESCE(p_dificultad, 2))
        RETURNING id INTO v_id;
    ELSE
        v_id := p_pregunta_id;
        UPDATE preguntas
           SET enunciado   = COALESCE(p_enunciado, enunciado),
               opciones    = COALESCE(p_opciones, opciones),
               explicacion = COALESCE(p_explicacion, explicacion),
               dificultad  = COALESCE(p_dificultad, dificultad)
         WHERE id = v_id;
    END IF;
    RETURN jsonb_build_object('pregunta_id', v_id);
END $$;

CREATE OR REPLACE FUNCTION admin_borrar_pregunta(p_pregunta_id uuid) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT es_admin() THEN RAISE EXCEPTION 'no_autorizado'; END IF;
    DELETE FROM preguntas WHERE id = p_pregunta_id;
END $$;


-- =============================================================================
--                    PLANIFICADOR V2 — motor autónomo
-- =============================================================================
-- Objetivo: el usuario configura UNA VEZ por semana su disponibilidad y
-- después sólo pulsa "Estudiar".  La app decide qué, cuánto y cuándo.
--
-- Piezas:
--   * recalcular_plan_hasta_examen(plan_id)  — recalcula desde HOY hasta
--     `fecha_examen` (o 90 días si no la hay), distribuyendo:
--       - unidades pendientes de teoría (por orden de tema.orden, unidad.orden)
--       - repasos vencidos (SM-2)
--       - repasos programados (cuando toque)
--     respetando `horas_por_dia`.  Nunca crea bloques después del examen.
--
--   * siguiente_bloque_pendiente()          — devuelve el primer bloque
--     no completado (prioridad: bloque en curso → hoy → adelantar día siguiente).
--
--   * registrar_bloque_completado(id)        — marca completado y sugiere
--     el siguiente.
--
--   * cambiar_disponibilidad_hoy(minutos)    — sustituye la carga de hoy y
--     recalcula el resto de la semana sin superar la horas_por_dia máx.
--
--   * reprogramar_dia_perdido()              — llama al abrir la app: si
--     ayer quedaron bloques no completados los desplaza a los próximos
--     días sin superar la disponibilidad configurada.
--
--   * sugerir_plan_semanal()                 — analiza las últimas 4
--     semanas de comportamiento y devuelve horas_por_dia sugeridas.

-- Añade `orden_global` a plan_sesiones para saber cuál es el "siguiente".
ALTER TABLE plan_sesiones
    ADD COLUMN IF NOT EXISTS orden_global int NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS plan_sesiones_orden_idx
    ON plan_sesiones (plan_id, fecha, orden_global);

CREATE OR REPLACE FUNCTION recalcular_plan_hasta_examen(p_plan_id uuid)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_plan   plan_estudio;
    v_uid    uuid;
    v_hoy    date := current_date;
    v_fin    date;
    v_dia    date;
    v_dow    text;
    v_hd     numeric;
    v_min    int;
    v_bloque int;
    v_creadas int := 0;
    v_orden   int := 0;
    v_unids   uuid[];
    v_idx     int := 1;
    v_repasos uuid[];
    v_rep_idx int := 1;
    v_metodo  text;
    v_op      uuid;
BEGIN
    SELECT * INTO v_plan FROM plan_estudio WHERE id = p_plan_id;
    IF v_plan.id IS NULL THEN RAISE EXCEPTION 'plan_no_existe'; END IF;
    v_uid := v_plan.usuario_id;
    v_metodo := COALESCE(v_plan.metodo, 'cortas');

    -- Fecha límite: fecha_examen de la oposición > fecha_examen del plan
    -- > +90 días desde hoy.  Se ignora la parte "orientativa" del mes/año
    -- porque como fecha se guardó día 1 (buena estimación por lo bajo).
    SELECT o.fecha_examen INTO v_fin
      FROM oposiciones o WHERE o.id = v_plan.oposicion_id;
    v_fin := COALESCE(v_fin, v_plan.fecha_examen, v_hoy + 90);

    -- Sólo consideramos los bloques FUTUROS no completados como
    -- reemplazables.  Los pasados (hechos o no) los preservamos como
    -- registro histórico.
    DELETE FROM plan_sesiones
     WHERE plan_id = p_plan_id
       AND fecha >= v_hoy
       AND NOT completada;

    -- Unidades pendientes (teoría no completada).
    SELECT COALESCE(array_agg(u.id ORDER BY ot.orden, u.orden), ARRAY[]::uuid[])
      INTO v_unids
      FROM oposicion_temas ot
      JOIN unidades u ON u.tema_id = ot.tema_id
 LEFT JOIN progreso_unidad pu
        ON pu.unidad_id = u.id AND pu.usuario_id = v_uid
     WHERE ot.oposicion_id = v_plan.oposicion_id
       AND COALESCE(pu.teoria_completada, false) = false;

    v_repasos := siguientes_repasos(200);

    v_bloque := CASE WHEN v_metodo = 'profundas' THEN 45 ELSE 25 END;

    -- Distribuye día a día hasta la fecha del examen o hasta agotar
    -- unidades y repasos.
    WHILE v_dia IS NULL OR v_dia < v_fin LOOP
        v_dia := COALESCE(v_dia + 1, v_hoy);
        IF v_dia > v_fin THEN EXIT; END IF;

        v_dow := CASE EXTRACT(ISODOW FROM v_dia)::int
                     WHEN 1 THEN 'lun' WHEN 2 THEN 'mar' WHEN 3 THEN 'mie'
                     WHEN 4 THEN 'jue' WHEN 5 THEN 'vie' WHEN 6 THEN 'sab'
                     WHEN 7 THEN 'dom' END;
        v_hd  := COALESCE((v_plan.horas_por_dia->>v_dow)::numeric, 0);
        v_min := (v_hd * 60)::int;
        IF v_min <= 0 THEN CONTINUE; END IF;

        -- Prioridad: primero repasos vencidos (memoria fresca), luego
        -- teoría, luego repasos futuros (más lejanos), luego test corto
        -- de refuerzo si queda tiempo.
        WHILE v_min >= v_bloque AND (v_idx <= cardinality(v_unids)
                                     OR v_rep_idx <= cardinality(v_repasos)) LOOP
            IF v_rep_idx <= cardinality(v_repasos)
               AND (v_idx > cardinality(v_unids) OR (v_rep_idx % 3) = 1) THEN
                -- Bloque de repaso cada 3 bloques o si no hay más teoría.
                v_orden := v_orden + 1;
                INSERT INTO plan_sesiones(plan_id, fecha, minutos, tipo, orden_global)
                VALUES (p_plan_id, v_dia, v_bloque, 'repaso', v_orden);
                v_rep_idx := v_rep_idx + 3;
            ELSE
                v_orden := v_orden + 1;
                INSERT INTO plan_sesiones(plan_id, fecha, minutos, unidad_id,
                                           tipo, orden_global)
                VALUES (p_plan_id, v_dia, v_bloque, v_unids[v_idx],
                        'estudio', v_orden);
                v_idx := v_idx + 1;
            END IF;
            v_creadas := v_creadas + 1;
            v_min := v_min - v_bloque - 5;
        END LOOP;

        -- Si sobran minutos y ya no hay unidades → bloque de test
        -- corto (repaso general) si queda margen.
        IF v_min >= 15
           AND v_idx > cardinality(v_unids)
           AND v_rep_idx > cardinality(v_repasos) THEN
            v_orden := v_orden + 1;
            INSERT INTO plan_sesiones(plan_id, fecha, minutos, tipo, orden_global)
            VALUES (p_plan_id, v_dia, LEAST(v_min, 20), 'repaso', v_orden);
            v_creadas := v_creadas + 1;
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'creadas', v_creadas,
        'hasta', v_fin,
        'unidades_pendientes_al_final',
            GREATEST(0, cardinality(v_unids) - (v_idx - 1))
    );
END $$;

-- Alias amigable del nombre viejo `generar_plan(plan_id, dias)` — ahora
-- invoca el motor nuevo ignorando `p_dias`.
CREATE OR REPLACE FUNCTION generar_plan(p_plan_id uuid, p_dias int DEFAULT 14)
RETURNS jsonb
LANGUAGE sql AS $$
    SELECT recalcular_plan_hasta_examen(p_plan_id);
$$;

-- Prioridad al elegir el siguiente bloque para "Estudiar":
--   1. Bloque de HOY no completado (por orden_global).
--   2. Primer bloque futuro no completado (adelantar).
CREATE OR REPLACE FUNCTION siguiente_bloque_pendiente() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'id',          ps.id,
        'plan_id',     ps.plan_id,
        'fecha',       ps.fecha,
        'minutos',     ps.minutos,
        'tipo',        ps.tipo,
        'unidad_id',   ps.unidad_id,
        'unidad',      u.nombre,
        'tema',        t.nombre,
        'tema_icono',  t.icono,
        'orden',       ps.orden_global,
        'es_hoy',      ps.fecha = current_date
    )
      FROM plan_estudio p
      JOIN plan_sesiones ps ON ps.plan_id = p.id
 LEFT JOIN unidades u ON u.id = ps.unidad_id
 LEFT JOIN temas t ON t.id = u.tema_id
     WHERE p.usuario_id = jwt_usuario_id() AND p.activo
       AND NOT ps.completada
       AND ps.fecha >= current_date
     ORDER BY (ps.fecha = current_date) DESC, ps.fecha, ps.orden_global
     LIMIT 1;
$$;

-- Marca un bloque completado + registra minutos reales.  Devuelve el
-- SIGUIENTE bloque pendiente (para que el frontend encadene sin ida
-- y vuelta al servidor).
CREATE OR REPLACE FUNCTION registrar_bloque_completado(
    p_bloque_id     uuid,
    p_minutos_real  int DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_ok  boolean;
BEGIN
    UPDATE plan_sesiones ps
       SET completada    = true,
           completada_en = now(),
           minutos       = COALESCE(p_minutos_real, ps.minutos)
     WHERE id = p_bloque_id
       AND EXISTS (SELECT 1 FROM plan_estudio p
                    WHERE p.id = ps.plan_id AND p.usuario_id = v_uid)
     RETURNING true INTO v_ok;

    IF NOT v_ok THEN RAISE EXCEPTION 'bloque_no_encontrado'; END IF;
    RETURN siguiente_bloque_pendiente();
END $$;

-- Cambio puntual de disponibilidad para HOY: sustituye el plan del día
-- por bloques que quepan en `p_minutos` y recalcula desde mañana hasta
-- el examen.  Los bloques ya completados de hoy se preservan.
CREATE OR REPLACE FUNCTION cambiar_disponibilidad_hoy(p_minutos int)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_uid  uuid := jwt_usuario_id();
    v_plan plan_estudio;
    v_min  int := GREATEST(0, p_minutos);
    v_hd   jsonb;
    v_dow  text;
BEGIN
    SELECT * INTO v_plan FROM plan_estudio
     WHERE usuario_id = v_uid AND activo LIMIT 1;
    IF v_plan.id IS NULL THEN RAISE EXCEPTION 'sin_plan'; END IF;

    -- Ajusta horas_por_dia para HOY como excepción temporal.
    v_dow := CASE EXTRACT(ISODOW FROM current_date)::int
                 WHEN 1 THEN 'lun' WHEN 2 THEN 'mar' WHEN 3 THEN 'mie'
                 WHEN 4 THEN 'jue' WHEN 5 THEN 'vie' WHEN 6 THEN 'sab'
                 WHEN 7 THEN 'dom' END;
    v_hd := jsonb_set(v_plan.horas_por_dia,
                       ARRAY[v_dow],
                       to_jsonb(round(v_min::numeric / 60, 2)));
    UPDATE plan_estudio SET horas_por_dia = v_hd,
                              actualizado_en = now()
     WHERE id = v_plan.id;

    -- Borra bloques de HOY no completados y regenera todo desde hoy.
    DELETE FROM plan_sesiones
     WHERE plan_id = v_plan.id AND fecha = current_date AND NOT completada;

    RETURN recalcular_plan_hasta_examen(v_plan.id);
END $$;

-- Reprograma bloques perdidos: coge los NO completados de fechas
-- anteriores a hoy y los mete de nuevo en la cola.  Se limita a mover
-- los últimos 7 días de bloques perdidos para no invadir el plan.
CREATE OR REPLACE FUNCTION reprogramar_dia_perdido() RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_plan plan_estudio;
    v_perdidos int;
BEGIN
    SELECT * INTO v_plan FROM plan_estudio
     WHERE usuario_id = jwt_usuario_id() AND activo LIMIT 1;
    IF v_plan.id IS NULL THEN RETURN jsonb_build_object('ok', false); END IF;

    -- Cuenta cuántos bloques quedaron por hacer en el pasado reciente.
    SELECT count(*) INTO v_perdidos FROM plan_sesiones
     WHERE plan_id = v_plan.id
       AND fecha BETWEEN current_date - 7 AND current_date - 1
       AND NOT completada;

    -- Al recalcular, esos bloques se regeneran junto a la teoría
    -- pendiente actual (sólo miramos progreso_unidad, no la fecha),
    -- así que simplemente reprogramamos todo el horizonte.
    PERFORM recalcular_plan_hasta_examen(v_plan.id);

    RETURN jsonb_build_object('ok', true, 'perdidos', v_perdidos);
END $$;

-- Analiza las últimas 4 semanas de sesiones_estudio y sugiere una
-- distribución `horas_por_dia` basada en cuándo estudia el usuario
-- REALMENTE (no lo que dijo cuando se dio de alta).
CREATE OR REPLACE FUNCTION sugerir_plan_semanal() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    WITH tot AS (
        SELECT
            CASE EXTRACT(ISODOW FROM abierta_en)::int
                 WHEN 1 THEN 'lun' WHEN 2 THEN 'mar' WHEN 3 THEN 'mie'
                 WHEN 4 THEN 'jue' WHEN 5 THEN 'vie' WHEN 6 THEN 'sab'
                 WHEN 7 THEN 'dom' END AS dow,
            sum(minutos_activos) AS min
          FROM sesiones_estudio
         WHERE usuario_id = jwt_usuario_id()
           AND abierta_en > now() - interval '28 days'
         GROUP BY 1
    ),
    -- Media semanal por día (min / 4 semanas → horas por día).
    prom AS (
        SELECT dow, ROUND((COALESCE(min, 0) / 4.0 / 60)::numeric, 1) AS horas
          FROM (SELECT unnest(ARRAY['lun','mar','mie','jue','vie','sab','dom']) AS dow) d
     LEFT JOIN tot USING (dow)
    )
    SELECT jsonb_object_agg(dow, horas) FROM prom;
$$;

-- Un pack para el flujo "Inicio de semana":
--   { sugerida: {lun:.., ...}, actual: {...}, semana_inicio, ... }
CREATE OR REPLACE FUNCTION resumen_inicio_semana() RETURNS jsonb
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_plan     plan_estudio;
    v_lunes    date := date_trunc('week', current_date)::date;
    v_sugerida jsonb;
BEGIN
    SELECT * INTO v_plan FROM plan_estudio
     WHERE usuario_id = jwt_usuario_id() AND activo LIMIT 1;
    v_sugerida := sugerir_plan_semanal();
    RETURN jsonb_build_object(
        'semana_inicio', v_lunes,
        'actual',        v_plan.horas_por_dia,
        'sugerida',      v_sugerida,
        'plan_id',       v_plan.id
    );
END $$;


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

-- =============================================================================
--                 GRANT EXECUTE en TODAS las funciones (barrido)
-- =============================================================================
-- Barre todas las funciones del schema public y les da EXECUTE al
-- rol apropiado.  Las de auth (login/registro/verify/reenvío) tienen
-- que ser ejecutables por `web_anon` (sin JWT).  El resto se ofrece
-- a `web_user`.  Todas las nuevas se benefician automáticamente sin
-- tener que acordarse del GRANT.

DO $grant_exec$
DECLARE
    r          record;
    v_anon_ok  text[] := ARRAY[
        'login_web', 'registrar_web', 'verificar_email',
        'reenviar_verificacion', 'push_config_publica'
    ];
BEGIN
    FOR r IN
        SELECT p.oid, p.proname, pg_get_function_identity_arguments(p.oid) AS args
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
    LOOP
        EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I(%s) TO web_user',
                       r.proname, r.args);
        IF r.proname = ANY(v_anon_ok) THEN
            EXECUTE format('GRANT EXECUTE ON FUNCTION public.%I(%s) TO web_anon',
                           r.proname, r.args);
        END IF;
    END LOOP;
END
$grant_exec$;

-- Fuerza recarga del schema cache de PostgREST tras el init.  Con
-- esto no hay que hacer NOTIFY a mano después de un `psql < schema`.
NOTIFY pgrst, 'reload schema';


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

-- Las funciones de autenticación se crean después del bloque general de
-- permisos. Declaramos sus permisos de forma explícita para que PostgREST
-- pueda exponerlas tanto antes como después de iniciar sesión.
GRANT EXECUTE ON FUNCTION public.registrar_web(text, text, text) TO web_anon, web_user;
GRANT EXECUTE ON FUNCTION public.reenviar_verificacion(text) TO web_anon, web_user;
GRANT EXECUTE ON FUNCTION public.verificar_email(text) TO web_anon, web_user;
GRANT EXECUTE ON FUNCTION public.login_web(text, text) TO web_anon, web_user;

-- PostgREST mantiene su propio catálogo de funciones. Si este script se
-- aplica sobre una base ya existente, la notificación evita que continúe
-- respondiendo PGRST202 con una caché anterior.
NOTIFY pgrst, 'reload schema';
