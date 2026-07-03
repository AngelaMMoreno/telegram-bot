-- ============================================================================
-- Delta 2026-07-03: Notificaciones Web Push.
--
--   - Tabla push_suscripciones: 1 fila por dispositivo (endpoint es la PK).
--   - Tabla push_envios: última notificación enviada por (usuario, tipo).
--     Sirve para rate-limitar y para trazabilidad.
--   - RPCs que la SPA usa para suscribir/desuscribir.
--   - Helpers que el worker Python 'notificador' llama cada N minutos para
--     resolver a quién avisar de qué.
--   - Config: ventana horaria, intervalos y clave pública VAPID (para que
--     la SPA la lea sin secretos hardcodeados).
--
-- Idempotente. Aplica en pgAdmin → Query Tool → F5.
-- ============================================================================

BEGIN;

-- ─── 1) Tablas ─────────────────────────────────────────────────────────────

-- Una suscripción = un dispositivo. Endpoint es único global (Web Push spec).
CREATE TABLE IF NOT EXISTS push_suscripciones (
    endpoint     text PRIMARY KEY,
    usuario_id   uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    p256dh       text NOT NULL,
    auth         text NOT NULL,
    ua           text,                          -- User-Agent al suscribir
    tz           text NOT NULL DEFAULT 'Europe/Madrid',
    activa       boolean NOT NULL DEFAULT true,
    creada_en    timestamptz NOT NULL DEFAULT now(),
    ultima_ok_en timestamptz,                   -- último push aceptado por el gateway
    ultimo_error text                           -- razón por la que se desactivó
);
CREATE INDEX IF NOT EXISTS push_suscripciones_usuario_idx
    ON push_suscripciones (usuario_id) WHERE activa;

-- Un envío por (usuario, tipo) para poder rate-limitar sin buscar en el
-- histórico completo. El worker lo actualiza en cada envío.
CREATE TABLE IF NOT EXISTS push_envios (
    usuario_id  uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    tipo        text NOT NULL CHECK (tipo IN ('repaso','inactividad','reto')),
    enviado_en  timestamptz NOT NULL DEFAULT now(),
    payload     jsonb,
    PRIMARY KEY (usuario_id, tipo)
);


-- ─── 2) RLS + GRANTS ───────────────────────────────────────────────────────
-- La SPA solo puede tocar sus propias suscripciones. push_envios NO es
-- accesible desde web_user: solo el worker (que conecta como aprentix)
-- lo lee/escribe, así el rate-limit no lo puede falsear el cliente.

ALTER TABLE push_suscripciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE push_envios        ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS push_sus_propias ON push_suscripciones;
CREATE POLICY push_sus_propias ON push_suscripciones
    FOR ALL TO web_user
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());

DROP POLICY IF EXISTS push_env_admin ON push_envios;
CREATE POLICY push_env_admin ON push_envios FOR ALL TO web_user
    USING (es_admin()) WITH CHECK (es_admin());

GRANT SELECT, INSERT, UPDATE, DELETE ON push_suscripciones TO web_user;
-- push_envios NO se expone a web_user; el worker usa el rol aprentix.

ALTER TABLE push_suscripciones ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();


-- ─── 3) RPCs para la SPA ───────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION guardar_push_suscripcion(
    p_endpoint text,
    p_p256dh   text,
    p_auth     text,
    p_ua       text DEFAULT NULL,
    p_tz       text DEFAULT 'Europe/Madrid'
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE v_uid uuid := jwt_usuario_id();
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    IF length(p_endpoint) = 0 OR length(p_p256dh) = 0 OR length(p_auth) = 0 THEN
        RAISE EXCEPTION 'suscripcion_invalida';
    END IF;
    INSERT INTO push_suscripciones(endpoint, usuario_id, p256dh, auth, ua, tz)
    VALUES (p_endpoint, v_uid, p_p256dh, p_auth, p_ua, COALESCE(p_tz,'Europe/Madrid'))
    ON CONFLICT (endpoint) DO UPDATE
        SET usuario_id   = EXCLUDED.usuario_id,
            p256dh       = EXCLUDED.p256dh,
            auth         = EXCLUDED.auth,
            ua           = EXCLUDED.ua,
            tz           = EXCLUDED.tz,
            activa       = true,
            ultimo_error = NULL;
END $$;

CREATE OR REPLACE FUNCTION borrar_push_suscripcion(p_endpoint text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF jwt_usuario_id() IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    DELETE FROM push_suscripciones
     WHERE endpoint = p_endpoint AND usuario_id = jwt_usuario_id();
END $$;

-- Devuelve la clave pública VAPID (segura de exponer) para que la SPA la
-- use en subscribe(). Se lee de config: no hay que hardcodearla en el JS.
CREATE OR REPLACE FUNCTION push_config_publica() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'vapid_public_key', COALESCE(
            (SELECT valor->>'valor' FROM config WHERE clave='push_vapid_public'),
            ''
        ),
        'ventana_ini', COALESCE(
            (SELECT (valor->>'valor')::int FROM config WHERE clave='push_ventana_ini'), 9),
        'ventana_fin', COALESCE(
            (SELECT (valor->>'valor')::int FROM config WHERE clave='push_ventana_fin'), 22),
        'intervalo_repaso_horas', COALESCE(
            (SELECT (valor->>'valor')::int FROM config WHERE clave='push_intervalo_repaso_horas'), 5)
    );
$$;

-- ¿Tiene el usuario actual al menos una suscripción activa? Útil para que la
-- UI decida entre mostrar "Activar notificaciones" u "Ya activas".
CREATE OR REPLACE FUNCTION mis_push_suscripciones() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'endpoint',  endpoint,
        'ua',        ua,
        'creada_en', creada_en,
        'activa',    activa
    ) ORDER BY creada_en DESC), '[]'::jsonb)
    FROM push_suscripciones
    WHERE usuario_id = jwt_usuario_id();
$$;


-- ─── 4) Helpers para el worker ────────────────────────────────────────────
-- Se ejecutan como el rol 'aprentix' (owner de la BBDD). Devuelven datos ya
-- listos para pywebpush: endpoint + p256dh + auth + payload sugerido.

-- Configuración con defaults. Cambia values en tabla config para ajustar sin
-- redeployar el worker.
CREATE OR REPLACE FUNCTION push_config_worker() RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'ventana_ini',            COALESCE((SELECT (valor->>'valor')::int FROM config WHERE clave='push_ventana_ini'), 9),
        'ventana_fin',            COALESCE((SELECT (valor->>'valor')::int FROM config WHERE clave='push_ventana_fin'), 22),
        'intervalo_repaso_horas', COALESCE((SELECT (valor->>'valor')::int FROM config WHERE clave='push_intervalo_repaso_horas'), 5),
        'inactividad_horas',      COALESCE((SELECT (valor->>'valor')::int FROM config WHERE clave='push_inactividad_horas'), 24),
        'inactividad_cooldown_h', COALESCE((SELECT (valor->>'valor')::int FROM config WHERE clave='push_inactividad_cooldown_horas'), 48),
        'tz',                     COALESCE((SELECT valor->>'valor' FROM config WHERE clave='push_tz'), 'Europe/Madrid'),
        'min_vencidas',           COALESCE((SELECT (valor->>'valor')::int FROM config WHERE clave='push_min_vencidas'), 5)
    );
$$;

-- Está la hora actual dentro de la ventana permitida?
CREATE OR REPLACE FUNCTION _push_en_ventana() RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cfg jsonb := push_config_worker();
    v_h   int := extract(hour FROM (now() AT TIME ZONE (v_cfg->>'tz')))::int;
BEGIN
    RETURN v_h >= (v_cfg->>'ventana_ini')::int
       AND v_h <  (v_cfg->>'ventana_fin')::int;
END $$;

-- Candidatos a recibir aviso "tienes repasos vencidos".
--   - Al menos N preguntas vencidas (ver push_min_vencidas).
--   - Último push de tipo 'repaso' hace ≥ intervalo_repaso_horas.
--   - Al menos una suscripción activa.
-- Nota: las columnas del RETURNS TABLE se convierten en variables locales de
-- la función; para evitar colisiones con las columnas 'usuario_id' de las
-- tablas subyacentes las nombramos con prefijo 'o_'. Como CREATE OR REPLACE
-- no puede cambiar los nombres de OUT-columns si una versión previa ya
-- existía, dropeamos antes.
DROP FUNCTION IF EXISTS push_candidatos_repaso()      CASCADE;
DROP FUNCTION IF EXISTS push_candidatos_inactividad() CASCADE;
CREATE OR REPLACE FUNCTION push_candidatos_repaso() RETURNS TABLE (
    o_usuario_id uuid,
    o_vencidas   int
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cfg jsonb := push_config_worker();
    v_int int   := (v_cfg->>'intervalo_repaso_horas')::int;
    v_min int   := (v_cfg->>'min_vencidas')::int;
BEGIN
    RETURN QUERY
    WITH ritmos AS (
        SELECT r.usuario_id AS uid, r.pregunta_id, r.caja, r.ultima_en,
               ritmo_repaso_usuario(r.usuario_id) AS ritmo
          FROM repasos r
    ),
    vencidas AS (
        SELECT r.uid, count(*) AS n
          FROM ritmos r
         WHERE r.ultima_en + intervalo_repaso(r.caja, r.ritmo) <= now()
         GROUP BY r.uid
    )
    SELECT v.uid, v.n::int
      FROM vencidas v
     WHERE v.n >= v_min
       AND EXISTS (
           SELECT 1 FROM push_suscripciones s
            WHERE s.usuario_id = v.uid AND s.activa
       )
       AND NOT EXISTS (
           SELECT 1 FROM push_envios e
            WHERE e.usuario_id = v.uid
              AND e.tipo = 'repaso'
              AND e.enviado_en > now() - make_interval(hours => v_int)
       );
END $$;

-- Candidatos a "hace mucho que no entras".
--   - ultimo_dia_activo (gamificación) < hoy - inactividad_horas/24.
--   - Cooldown propio: solo uno cada 'inactividad_cooldown_h'.
CREATE OR REPLACE FUNCTION push_candidatos_inactividad() RETURNS TABLE (
    o_usuario_id uuid,
    o_dias       int
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cfg jsonb := push_config_worker();
    v_h   int   := (v_cfg->>'inactividad_horas')::int;
    v_cd  int   := (v_cfg->>'inactividad_cooldown_h')::int;
    v_tz  text  := v_cfg->>'tz';
    v_hoy date  := (now() AT TIME ZONE v_tz)::date;
BEGIN
    RETURN QUERY
    SELECT g.usuario_id,
           (v_hoy - g.ultimo_dia_activo)::int
      FROM usuario_gamificacion g
     WHERE g.ultimo_dia_activo IS NOT NULL
       AND (v_hoy - g.ultimo_dia_activo) * 24 >= v_h
       AND EXISTS (
           SELECT 1 FROM push_suscripciones s
            WHERE s.usuario_id = g.usuario_id AND s.activa
       )
       AND NOT EXISTS (
           SELECT 1 FROM push_envios e
            WHERE e.usuario_id = g.usuario_id
              AND e.tipo = 'inactividad'
              AND e.enviado_en > now() - make_interval(hours => v_cd)
       );
END $$;

-- Devuelve las suscripciones activas de un usuario. Los datos van completos
-- para que el worker no tenga que consultar la BBDD 2 veces por usuario.
CREATE OR REPLACE FUNCTION push_suscripciones_de(p_usuario_id uuid) RETURNS TABLE (
    endpoint text,
    p256dh   text,
    auth     text
)
LANGUAGE sql STABLE AS $$
    SELECT endpoint, p256dh, auth
      FROM push_suscripciones
     WHERE usuario_id = p_usuario_id AND activa;
$$;

-- Registra el resultado del envío. El worker llama:
--   push_marcar_envio(uid, 'repaso', payload)  → tras éxito
--   push_marcar_error(endpoint, motivo)        → tras 404/410 (desactiva)
CREATE OR REPLACE FUNCTION push_marcar_envio(
    p_usuario_id uuid,
    p_tipo       text,
    p_payload    jsonb
) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO push_envios(usuario_id, tipo, enviado_en, payload)
    VALUES (p_usuario_id, p_tipo, now(), p_payload)
    ON CONFLICT (usuario_id, tipo) DO UPDATE
        SET enviado_en = now(),
            payload    = EXCLUDED.payload;

    UPDATE push_suscripciones
       SET ultima_ok_en = now(),
           activa       = true,
           ultimo_error = NULL
     WHERE usuario_id = p_usuario_id AND activa;
END $$;

CREATE OR REPLACE FUNCTION push_marcar_error(
    p_endpoint text,
    p_motivo   text
) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    -- 404/410 significa que el navegador ha desregistrado esa suscripción:
    -- la marcamos inactiva para no volver a intentar.
    UPDATE push_suscripciones
       SET activa       = false,
           ultimo_error = p_motivo
     WHERE endpoint = p_endpoint;
END $$;


-- ─── 5) Grants + defaults ─────────────────────────────────────────────────
GRANT EXECUTE ON FUNCTION guardar_push_suscripcion(text,text,text,text,text) TO web_user;
GRANT EXECUTE ON FUNCTION borrar_push_suscripcion(text)                       TO web_user;
GRANT EXECUTE ON FUNCTION mis_push_suscripciones()                            TO web_user;
GRANT EXECUTE ON FUNCTION push_config_publica()                               TO web_user, web_anon;

-- Config con defaults sensatos (5h de intervalo entre pushes de repaso,
-- ventana 9-22, inactividad a 24h con cooldown de 48h).
INSERT INTO config(clave, valor) VALUES
    ('push_ventana_ini',                jsonb_build_object('valor', 9,  'descripcion', 'Hora inicial (Europe/Madrid) para enviar push')),
    ('push_ventana_fin',                jsonb_build_object('valor', 22, 'descripcion', 'Hora final (exclusiva) para enviar push')),
    ('push_intervalo_repaso_horas',     jsonb_build_object('valor', 5,  'descripcion', 'Horas mínimas entre pushes de repaso por usuario')),
    ('push_inactividad_horas',          jsonb_build_object('valor', 24, 'descripcion', 'Horas sin acceder para enviar aviso motivacional')),
    ('push_inactividad_cooldown_horas', jsonb_build_object('valor', 48, 'descripcion', 'Horas mínimas entre avisos de inactividad')),
    ('push_min_vencidas',               jsonb_build_object('valor', 5,  'descripcion', 'Mínimo de preguntas vencidas para lanzar aviso')),
    ('push_tz',                         jsonb_build_object('valor', 'Europe/Madrid', 'descripcion', 'Zona horaria de la ventana de envío')),
    ('push_vapid_public',               jsonb_build_object('valor', '',
        'descripcion', 'Clave pública VAPID (base64url). Se rellena tras generar el par con notificador/gen_vapid.py'))
ON CONFLICT (clave) DO NOTHING;


-- ─── 6) Comprobación final ────────────────────────────────────────────────
DO $$
DECLARE
    v_tablas int; v_funcs int; v_cfg int;
BEGIN
    SELECT count(*) INTO v_tablas FROM pg_tables
     WHERE schemaname='public' AND tablename IN ('push_suscripciones','push_envios');
    SELECT count(*) INTO v_funcs FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
     WHERE n.nspname='public' AND p.proname IN (
         'guardar_push_suscripcion','borrar_push_suscripcion','mis_push_suscripciones',
         'push_config_publica','push_config_worker','_push_en_ventana',
         'push_candidatos_repaso','push_candidatos_inactividad',
         'push_suscripciones_de','push_marcar_envio','push_marcar_error');
    SELECT count(*) INTO v_cfg FROM config
     WHERE clave LIKE 'push\_%' ESCAPE '\';
    RAISE NOTICE 'tablas push:      %/2', v_tablas;
    RAISE NOTICE 'funciones push:   %/11', v_funcs;
    RAISE NOTICE 'claves de config: %/8', v_cfg;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
