-- ============================================================================
-- Delta a aplicar UNA VEZ sobre una BBDD viva anterior a la gamificación.
-- Idempotente: se puede correr varias veces sin efectos duplicados.
--
-- Añade:
--   · amistades (bidireccionales, con estado pending/accepted)
--   · push_subscripciones (Web Push VAPID por dispositivo)
--   · notificaciones_pendientes (cola procesada por el servicio notifier)
--   · notificaciones_estado (throttle por usuario + tipo, para no spamear)
--   · retos_plantillas (catálogo de tipos de reto)
--   · retos_diarios (retos generados por usuario y fecha)
--   · rachas_diarias (para el streak de días consecutivos)
--   · gamificacion_stats vista (nivel + puntos derivados)
--
--   RPCs: buscar_usuarios, enviar/responder/cancelar amistad,
--         mis_amigos, mis_solicitudes,
--         mis_retos_hoy (auto-genera), progreso_retos,
--         registrar_suscripcion_push, borrar_suscripcion_push,
--         mi_racha, mis_notificaciones_recientes.
--
--   Trigger: sobre respuestas y ficheros_vistas para avanzar retos y
--            emitir NOTIFY 'gamificacion' al completar uno.
-- ============================================================================

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1) AMISTADES
-- ─────────────────────────────────────────────────────────────────────────────
-- Guardamos una sola fila por par de usuarios, siempre con el UUID menor en
-- 'usuario_a' (invariante mantenido por CHECK + los helpers). Así no hay
-- dobles filas y las políticas RLS son triviales.

CREATE TABLE IF NOT EXISTS amistades (
    usuario_a    uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    usuario_b    uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    -- Quién envió la solicitud original (para saber a quién le toca aceptar).
    solicitante  uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    estado       text NOT NULL DEFAULT 'pendiente'
                     CHECK (estado IN ('pendiente','aceptada','bloqueada')),
    creado_en    timestamptz NOT NULL DEFAULT now(),
    actualizado_en timestamptz NOT NULL DEFAULT now(),
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


-- ─────────────────────────────────────────────────────────────────────────────
-- 2) WEB PUSH: suscripciones por dispositivo
-- ─────────────────────────────────────────────────────────────────────────────

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
CREATE INDEX IF NOT EXISTS push_subs_usuario_idx
    ON push_subscripciones (usuario_id);

ALTER TABLE push_subscripciones ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS push_subs_propias ON push_subscripciones;
CREATE POLICY push_subs_propias ON push_subscripciones
    FOR ALL TO web_user
    USING (usuario_id = jwt_usuario_id() OR es_admin())
    WITH CHECK (usuario_id = jwt_usuario_id());

GRANT SELECT, INSERT, UPDATE, DELETE ON push_subscripciones TO web_user;
GRANT USAGE, SELECT ON SEQUENCE push_subscripciones_id_seq TO web_user;
ALTER TABLE push_subscripciones ALTER COLUMN usuario_id SET DEFAULT jwt_usuario_id();


-- ─────────────────────────────────────────────────────────────────────────────
-- 3) COLA DE NOTIFICACIONES + THROTTLE
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS notificaciones_pendientes (
    id           bigserial PRIMARY KEY,
    usuario_id   uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    tipo         text NOT NULL,        -- 'amigo_reto' | 'repaso_digest' | 'amistad_solicitud'
    titulo       text NOT NULL,
    cuerpo       text NOT NULL,
    url          text,                 -- deep link opcional
    datos        jsonb NOT NULL DEFAULT '{}'::jsonb,
    creado_en    timestamptz NOT NULL DEFAULT now(),
    enviado_en   timestamptz
);
CREATE INDEX IF NOT EXISTS notif_pend_idx
    ON notificaciones_pendientes (enviado_en, creado_en) WHERE enviado_en IS NULL;

-- No es una tabla RLS accesible al cliente: solo el notifier (rol
-- 'aprentix' de la DB) la lee/escribe. La dejamos sin GRANTs para web_user.

CREATE TABLE IF NOT EXISTS notificaciones_estado (
    usuario_id  uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    tipo        text NOT NULL,
    -- Última vez que enviamos una notificación de este tipo a este usuario
    -- (para throttlear digests: mínimo 12 h entre pushes de "repasos").
    ultima_en   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (usuario_id, tipo)
);


-- ─────────────────────────────────────────────────────────────────────────────
-- 4) RETOS DIARIOS
-- ─────────────────────────────────────────────────────────────────────────────
--
-- 'retos_plantillas' es el catálogo. Los tipos son:
--   · responder_n      → responder N preguntas hoy
--   · acertar_n        → acertar N preguntas hoy
--   · teoria_n         → marcar N documentos de teoría como leídos
--   · repasos_n        → completar N repasos vencidos hoy
--   · test_completo    → finalizar 1 test hoy
--   · test_precision   → sacar >= 80 % en un test hoy
--   · redimir_n        → volver a acertar N preguntas antes falladas
--   · racha_dias       → mantener la racha de días consecutivos
--   · subir_cajas_n    → subir N preguntas de caja Leitner
--   · etiqueta_nueva   → responder preguntas de una etiqueta nueva

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
    id           bigserial PRIMARY KEY,
    usuario_id   uuid NOT NULL REFERENCES usuarios(id) ON DELETE CASCADE,
    fecha        date NOT NULL DEFAULT current_date,
    plantilla_id text NOT NULL REFERENCES retos_plantillas(id) ON DELETE CASCADE,
    objetivo     int  NOT NULL,
    progreso     int  NOT NULL DEFAULT 0,
    puntos       int  NOT NULL DEFAULT 10,
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


-- Seed del catálogo (idempotente).
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
    SET titulo = EXCLUDED.titulo,
        descripcion = EXCLUDED.descripcion,
        tipo = EXCLUDED.tipo,
        objetivo = EXCLUDED.objetivo,
        puntos = EXCLUDED.puntos;


-- ─────────────────────────────────────────────────────────────────────────────
-- 5) RACHA DE DÍAS CONSECUTIVOS
-- ─────────────────────────────────────────────────────────────────────────────

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


-- ─────────────────────────────────────────────────────────────────────────────
-- 6) HELPERS DE AMISTAD
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION amigos_de(p_usuario uuid)
RETURNS TABLE(amigo_id uuid)
LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN usuario_a = p_usuario THEN usuario_b ELSE usuario_a END
      FROM amistades
     WHERE estado = 'aceptada'
       AND p_usuario IN (usuario_a, usuario_b);
$$;

CREATE OR REPLACE FUNCTION buscar_usuarios(p_q text, p_lim int DEFAULT 15)
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    WITH candidatos AS (
        SELECT u.id, u.username
          FROM usuarios u
         WHERE u.activo
           AND u.id <> jwt_usuario_id()
           AND (
                u.username ILIKE p_q || '%'
                OR u.username %> p_q
           )
         ORDER BY (u.username ILIKE p_q || '%') DESC,
                  similarity(u.username, p_q) DESC,
                  u.username
         LIMIT GREATEST(p_lim, 1)
    )
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id',       c.id,
        'username', c.username,
        'estado',   (SELECT a.estado FROM amistades a
                       WHERE (a.usuario_a = LEAST(c.id, jwt_usuario_id())
                          AND a.usuario_b = GREATEST(c.id, jwt_usuario_id()))),
        'yo_solicite', (SELECT a.solicitante = jwt_usuario_id() FROM amistades a
                       WHERE (a.usuario_a = LEAST(c.id, jwt_usuario_id())
                          AND a.usuario_b = GREATEST(c.id, jwt_usuario_id())))
    ) ORDER BY c.username), '[]'::jsonb)
    FROM candidatos c;
$$;

CREATE OR REPLACE FUNCTION enviar_solicitud_amistad(p_otro uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_yo uuid := jwt_usuario_id();
    v_a  uuid;
    v_b  uuid;
BEGIN
    IF v_yo IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    IF p_otro = v_yo THEN RAISE EXCEPTION 'no_puedes_ser_tu_propio_amigo'; END IF;
    IF NOT EXISTS (SELECT 1 FROM usuarios WHERE id = p_otro AND activo) THEN
        RAISE EXCEPTION 'usuario_no_existe';
    END IF;

    v_a := LEAST(v_yo, p_otro);
    v_b := GREATEST(v_yo, p_otro);

    INSERT INTO amistades(usuario_a, usuario_b, solicitante, estado)
    VALUES (v_a, v_b, v_yo, 'pendiente')
    ON CONFLICT (usuario_a, usuario_b) DO UPDATE
        SET estado = CASE
            -- Si el otro ya me la había mandado, aceptamos.
            WHEN amistades.estado = 'pendiente'
                 AND amistades.solicitante = p_otro THEN 'aceptada'
            ELSE amistades.estado
        END,
        actualizado_en = now();

    -- Encolar notificación push al destinatario si es una solicitud nueva.
    INSERT INTO notificaciones_pendientes(usuario_id, tipo, titulo, cuerpo, url, datos)
    SELECT p_otro,
           'amistad_solicitud',
           'Nueva solicitud de amistad',
           u.username || ' quiere ser tu amigo en Aprentix',
           '/#amigos',
           jsonb_build_object('de', v_yo, 'username', u.username)
      FROM usuarios u
     WHERE u.id = v_yo
       AND EXISTS (
           SELECT 1 FROM amistades WHERE usuario_a = v_a AND usuario_b = v_b
             AND estado = 'pendiente' AND solicitante = v_yo
       );

    PERFORM pg_notify('gamificacion', 'nueva:' || p_otro::text);

    RETURN (SELECT to_jsonb(a) FROM amistades a
             WHERE usuario_a = v_a AND usuario_b = v_b);
END $$;

CREATE OR REPLACE FUNCTION responder_solicitud_amistad(p_otro uuid, p_aceptar boolean)
RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_yo uuid := jwt_usuario_id();
    v_a  uuid;
    v_b  uuid;
    v_ok boolean;
BEGIN
    IF v_yo IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    v_a := LEAST(v_yo, p_otro);
    v_b := GREATEST(v_yo, p_otro);

    IF p_aceptar THEN
        UPDATE amistades
           SET estado = 'aceptada', actualizado_en = now()
         WHERE usuario_a = v_a AND usuario_b = v_b
           AND estado = 'pendiente'
           AND solicitante = p_otro
        RETURNING true INTO v_ok;
        IF NOT COALESCE(v_ok, false) THEN
            RAISE EXCEPTION 'solicitud_no_encontrada';
        END IF;
    ELSE
        DELETE FROM amistades
         WHERE usuario_a = v_a AND usuario_b = v_b;
    END IF;

    RETURN jsonb_build_object('ok', true, 'aceptada', p_aceptar);
END $$;

CREATE OR REPLACE FUNCTION cancelar_amistad(p_otro uuid) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_yo uuid := jwt_usuario_id();
    v_a  uuid := LEAST(v_yo, p_otro);
    v_b  uuid := GREATEST(v_yo, p_otro);
BEGIN
    IF v_yo IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    DELETE FROM amistades WHERE usuario_a = v_a AND usuario_b = v_b;
    RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION mis_amigos() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'id',           u.id,
        'username',     u.username,
        'racha_actual', COALESCE(r.racha_actual, 0),
        'racha_maxima', COALESCE(r.racha_maxima, 0),
        'puntos',       COALESCE(r.puntos_totales, 0),
        'retos_hoy_completados', (
            SELECT count(*) FROM retos_diarios rd
             WHERE rd.usuario_id = u.id AND rd.fecha = current_date
               AND rd.completado_en IS NOT NULL
        )
    ) ORDER BY u.username), '[]'::jsonb)
    FROM amistades a
    JOIN usuarios u ON u.id = CASE WHEN a.usuario_a = jwt_usuario_id()
                                    THEN a.usuario_b ELSE a.usuario_a END
    LEFT JOIN rachas_diarias r ON r.usuario_id = u.id
    WHERE a.estado = 'aceptada'
      AND jwt_usuario_id() IN (a.usuario_a, a.usuario_b);
$$;

CREATE OR REPLACE FUNCTION mis_solicitudes_amistad() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER AS $$
    SELECT jsonb_build_object(
        'recibidas', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', u.id, 'username', u.username, 'desde', a.creado_en
            ) ORDER BY a.creado_en DESC)
            FROM amistades a
            JOIN usuarios u ON u.id = a.solicitante
            WHERE a.estado = 'pendiente'
              AND a.solicitante <> jwt_usuario_id()
              AND jwt_usuario_id() IN (a.usuario_a, a.usuario_b)
        ), '[]'::jsonb),
        'enviadas', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                'id', u.id, 'username', u.username, 'desde', a.creado_en
            ) ORDER BY a.creado_en DESC)
            FROM amistades a
            JOIN usuarios u ON u.id = CASE WHEN a.usuario_a = jwt_usuario_id()
                                            THEN a.usuario_b ELSE a.usuario_a END
            WHERE a.estado = 'pendiente'
              AND a.solicitante = jwt_usuario_id()
              AND jwt_usuario_id() IN (a.usuario_a, a.usuario_b)
        ), '[]'::jsonb)
    );
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 7) RETOS DIARIOS: generación, consulta, avance
-- ─────────────────────────────────────────────────────────────────────────────

-- Genera retos para el día si no existen todavía. Elegimos 3 plantillas al
-- azar (activas), tratando de mezclar dificultad. Devuelve el listado.
CREATE OR REPLACE FUNCTION mis_retos_hoy() RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
    v_uid uuid := jwt_usuario_id();
    v_hoy date := current_date;
    v_n   int;
    v_res jsonb;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;

    SELECT count(*) INTO v_n
      FROM retos_diarios
     WHERE usuario_id = v_uid AND fecha = v_hoy;

    IF v_n = 0 THEN
        -- Semilla determinista por (uid, fecha) para que si dos llamadas
        -- llegan a la vez den los mismos retos.
        INSERT INTO retos_diarios(usuario_id, fecha, plantilla_id, objetivo, puntos)
        SELECT v_uid, v_hoy, p.id, p.objetivo, p.puntos
          FROM (
              SELECT id, objetivo, puntos
                FROM retos_plantillas
               WHERE activo
               ORDER BY md5(v_uid::text || v_hoy::text || id)
               LIMIT 3
          ) p
        ON CONFLICT DO NOTHING;
    END IF;

    SELECT jsonb_build_object(
        'fecha', v_hoy,
        'retos', COALESCE(jsonb_agg(jsonb_build_object(
            'id',            rd.id,
            'plantilla_id',  rd.plantilla_id,
            'titulo',        rp.titulo,
            'descripcion',   rp.descripcion,
            'tipo',          rp.tipo,
            'objetivo',      rd.objetivo,
            'progreso',      rd.progreso,
            'puntos',        rd.puntos,
            'completado',    rd.completado_en IS NOT NULL,
            'completado_en', rd.completado_en
        ) ORDER BY rd.id), '[]'::jsonb),
        'racha', (SELECT jsonb_build_object(
            'actual', COALESCE(racha_actual, 0),
            'maxima', COALESCE(racha_maxima, 0),
            'puntos', COALESCE(puntos_totales, 0)
        ) FROM rachas_diarias WHERE usuario_id = v_uid)
    ) INTO v_res
    FROM retos_diarios rd
    JOIN retos_plantillas rp ON rp.id = rd.plantilla_id
    WHERE rd.usuario_id = v_uid AND rd.fecha = v_hoy;

    RETURN v_res;
END $$;


-- Avanza el progreso de un reto (nunca lo pasa del objetivo) y, si lo
-- completa, marca completado_en, suma puntos totales y encola notificaciones
-- push a todos los amigos que hayan activado las suscripciones.
CREATE OR REPLACE FUNCTION avanzar_reto(
    p_uid       uuid,
    p_tipo      text,
    p_incremento int DEFAULT 1
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_ids bigint[];
    v_id  bigint;
    v_rp  retos_plantillas;
    v_rd  retos_diarios;
    v_username text;
BEGIN
    SELECT array_agg(rd.id)
      INTO v_ids
      FROM retos_diarios rd
      JOIN retos_plantillas rp ON rp.id = rd.plantilla_id
     WHERE rd.usuario_id = p_uid
       AND rd.fecha = current_date
       AND rp.tipo = p_tipo
       AND rd.completado_en IS NULL;

    IF v_ids IS NULL THEN RETURN; END IF;

    FOREACH v_id IN ARRAY v_ids LOOP
        SELECT * INTO v_rd FROM retos_diarios WHERE id = v_id FOR UPDATE;
        SELECT * INTO v_rp FROM retos_plantillas WHERE id = v_rd.plantilla_id;

        UPDATE retos_diarios
           SET progreso = LEAST(progreso + GREATEST(p_incremento, 0), objetivo),
               completado_en = CASE
                 WHEN completado_en IS NULL
                      AND progreso + GREATEST(p_incremento, 0) >= objetivo
                 THEN now()
                 ELSE completado_en
               END
         WHERE id = v_id
        RETURNING * INTO v_rd;

        IF v_rd.completado_en IS NOT NULL THEN
            -- Suma puntos totales al usuario.
            INSERT INTO rachas_diarias(usuario_id, puntos_totales)
            VALUES (p_uid, v_rd.puntos)
            ON CONFLICT (usuario_id) DO UPDATE
                SET puntos_totales = rachas_diarias.puntos_totales + v_rd.puntos;

            SELECT username INTO v_username FROM usuarios WHERE id = p_uid;

            -- Notifica a los amigos.
            INSERT INTO notificaciones_pendientes(usuario_id, tipo, titulo, cuerpo, url, datos)
            SELECT amigo_id,
                   'amigo_reto',
                   '🎯 ' || v_username || ' completó un reto',
                   v_rp.titulo,
                   '/#amigos',
                   jsonb_build_object(
                       'amigo', p_uid,
                       'username', v_username,
                       'reto', v_rp.id,
                       'titulo', v_rp.titulo,
                       'puntos', v_rd.puntos
                   )
              FROM amigos_de(p_uid);

            PERFORM pg_notify('gamificacion', 'reto:' || p_uid::text);
        END IF;
    END LOOP;
END $$;


-- Marca al usuario como "activo hoy" y actualiza racha (idempotente por día).
CREATE OR REPLACE FUNCTION tocar_racha(p_uid uuid) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_hoy date := current_date;
    v_row rachas_diarias;
BEGIN
    SELECT * INTO v_row FROM rachas_diarias WHERE usuario_id = p_uid FOR UPDATE;
    IF v_row.usuario_id IS NULL THEN
        INSERT INTO rachas_diarias(usuario_id, racha_actual, racha_maxima, ultima_fecha)
        VALUES (p_uid, 1, 1, v_hoy);
        PERFORM avanzar_reto(p_uid, 'racha_dias', 1);
        RETURN;
    END IF;

    IF v_row.ultima_fecha = v_hoy THEN
        RETURN;                                          -- ya contabilizado hoy
    ELSIF v_row.ultima_fecha = v_hoy - 1 THEN
        UPDATE rachas_diarias
           SET racha_actual = racha_actual + 1,
               racha_maxima = GREATEST(racha_maxima, racha_actual + 1),
               ultima_fecha = v_hoy
         WHERE usuario_id = p_uid;
    ELSE
        UPDATE rachas_diarias
           SET racha_actual = 1,
               racha_maxima = GREATEST(racha_maxima, 1),
               ultima_fecha = v_hoy
         WHERE usuario_id = p_uid;
    END IF;

    PERFORM avanzar_reto(p_uid, 'racha_dias', 1);
END $$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 8) TRIGGERS DE PROGRESO DE RETOS
-- ─────────────────────────────────────────────────────────────────────────────
-- Al insertar una respuesta:
--   · +1 responder_n
--   · si correcta:      +1 acertar_n
--   · si redime fallo:  +1 redimir_n  (la lógica de redimir se detecta viendo
--                        si había marcador 'fallo' antes; para simplificar
--                        usamos el 'fallos' contador en repasos > 0)
-- Además tocamos la racha.

CREATE OR REPLACE FUNCTION trg_respuestas_gamif() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_uid uuid;
    v_pre boolean;
    v_tenia_fallo boolean;
    v_etiq text[];
    v_etiqueta_nueva boolean := false;
    v_caja_prev int;
    v_caja_post int;
BEGIN
    SELECT i.usuario_id INTO v_uid FROM intentos i WHERE i.id = NEW.intento_id;
    IF v_uid IS NULL THEN RETURN NEW; END IF;

    PERFORM tocar_racha(v_uid);
    PERFORM avanzar_reto(v_uid, 'responder_n', 1);

    IF NEW.correcta THEN
        PERFORM avanzar_reto(v_uid, 'acertar_n', 1);

        -- ¿Estaba marcada como fallo antes de esta respuesta correcta?
        -- registrar_respuesta borra el marcador tras insertar la respuesta,
        -- así que aquí ya no lo veríamos. Miramos el contador de 'fallos'
        -- del motor de repasos: si es > 0 significa que la habíamos fallado.
        SELECT fallos INTO v_caja_prev FROM repasos
          WHERE usuario_id = v_uid AND pregunta_id = NEW.pregunta_id;
        IF COALESCE(v_caja_prev, 0) > 0 THEN
            PERFORM avanzar_reto(v_uid, 'redimir_n', 1);
        END IF;

        -- ¿Es una etiqueta nueva para este usuario?
        SELECT etiquetas INTO v_etiq FROM preguntas WHERE id = NEW.pregunta_id;
        IF v_etiq IS NOT NULL AND cardinality(v_etiq) > 0 THEN
            SELECT NOT EXISTS (
                SELECT 1
                  FROM respuestas r2
                  JOIN intentos i2 ON i2.id = r2.intento_id
                  JOIN preguntas p2 ON p2.id = r2.pregunta_id
                 WHERE i2.usuario_id = v_uid
                   AND r2.id <> NEW.id
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
CREATE TRIGGER respuestas_gamif
    AFTER INSERT ON respuestas
    FOR EACH ROW EXECUTE FUNCTION trg_respuestas_gamif();


-- Al subir de caja Leitner (correcta con caja post > caja pre): +1 subir_cajas_n.
CREATE OR REPLACE FUNCTION trg_repasos_gamif() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.caja > 1 THEN
            PERFORM avanzar_reto(NEW.usuario_id, 'subir_cajas_n', 1);
        END IF;
    ELSIF TG_OP = 'UPDATE' AND NEW.caja > OLD.caja THEN
        PERFORM avanzar_reto(NEW.usuario_id, 'subir_cajas_n', 1);
    END IF;
    -- 'repasos_n' se cuenta también aquí: cada UPDATE es una respuesta a
    -- pregunta que ya tenía repaso.
    IF TG_OP = 'UPDATE' THEN
        PERFORM avanzar_reto(NEW.usuario_id, 'repasos_n', 1);
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS repasos_gamif ON repasos;
CREATE TRIGGER repasos_gamif
    AFTER INSERT OR UPDATE ON repasos
    FOR EACH ROW EXECUTE FUNCTION trg_repasos_gamif();


-- Al marcar un fichero de teoría como visto: +1 teoria_n.
CREATE OR REPLACE FUNCTION trg_teoria_gamif() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    PERFORM tocar_racha(NEW.usuario_id);
    PERFORM avanzar_reto(NEW.usuario_id, 'teoria_n', 1);
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS teoria_gamif ON ficheros_vistas;
CREATE TRIGGER teoria_gamif
    AFTER INSERT ON ficheros_vistas
    FOR EACH ROW EXECUTE FUNCTION trg_teoria_gamif();


-- Al finalizar un intento con tipo 'quiz' y test_id no nulo: contamos
-- test_completo. Si la precisión >= 80%: test_precision.
CREATE OR REPLACE FUNCTION trg_intento_finalizado_gamif() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_corr int;
    v_tot  int;
    v_prec int;
BEGIN
    IF NEW.finalizado_en IS NULL OR OLD.finalizado_en IS NOT NULL THEN
        RETURN NEW;
    END IF;

    SELECT count(*) FILTER (WHERE correcta), count(*)
      INTO v_corr, v_tot
      FROM respuestas WHERE intento_id = NEW.id;

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
CREATE TRIGGER intentos_gamif
    AFTER UPDATE OF finalizado_en ON intentos
    FOR EACH ROW EXECUTE FUNCTION trg_intento_finalizado_gamif();


-- ─────────────────────────────────────────────────────────────────────────────
-- 9) RPCs para Web Push
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION registrar_suscripcion_push(
    p_endpoint text, p_p256dh text, p_auth text, p_user_agent text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql AS $$
BEGIN
    IF jwt_usuario_id() IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;
    INSERT INTO push_subscripciones(usuario_id, endpoint, p256dh, auth, user_agent)
    VALUES (jwt_usuario_id(), p_endpoint, p_p256dh, p_auth, p_user_agent)
    ON CONFLICT (endpoint) DO UPDATE
        SET usuario_id = EXCLUDED.usuario_id,
            p256dh     = EXCLUDED.p256dh,
            auth       = EXCLUDED.auth,
            user_agent = EXCLUDED.user_agent,
            vista_en   = now();
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

-- Endpoint público leído por el frontend para saber la VAPID public key.
-- Se sirve de config → 'vapid_public_key'.
CREATE OR REPLACE FUNCTION vapid_public_key() RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(valor #>> '{}', '') FROM config WHERE clave = 'vapid_public_key';
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 10) GRANTS DE EXECUTE
-- ─────────────────────────────────────────────────────────────────────────────

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


-- ─────────────────────────────────────────────────────────────────────────────
-- 11) Comprobación final
-- ─────────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
    v_tablas   int;
    v_funcs    int;
    v_plantillas int;
BEGIN
    SELECT count(*) INTO v_tablas FROM pg_class
     WHERE relnamespace = 'public'::regnamespace
       AND relname IN (
           'amistades', 'push_subscripciones', 'notificaciones_pendientes',
           'notificaciones_estado', 'retos_plantillas', 'retos_diarios',
           'rachas_diarias'
       );
    SELECT count(*) INTO v_funcs FROM pg_proc
      JOIN pg_namespace n ON n.oid = pronamespace
     WHERE n.nspname = 'public'
       AND proname IN (
           'buscar_usuarios','enviar_solicitud_amistad',
           'responder_solicitud_amistad','cancelar_amistad',
           'mis_amigos','mis_solicitudes_amistad','mis_retos_hoy',
           'avanzar_reto','tocar_racha','amigos_de',
           'registrar_suscripcion_push','borrar_suscripcion_push',
           'vapid_public_key'
       );
    SELECT count(*) INTO v_plantillas FROM retos_plantillas;

    RAISE NOTICE 'tablas gamificación:  %/7', v_tablas;
    RAISE NOTICE 'RPCs gamificación:    %/13', v_funcs;
    RAISE NOTICE 'plantillas de reto:   %',     v_plantillas;
END $$;

NOTIFY pgrst, 'reload schema';

COMMIT;
