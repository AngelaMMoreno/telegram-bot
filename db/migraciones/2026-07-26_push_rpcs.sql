-- ─────────────────────────────────────────────────────────────────────────
-- Recrea las RPCs de push que consume notificador/notificador.py.
--
-- El rediseño de esquema del commit 7cb0e26 mantuvo las tablas
-- (push_suscripciones, push_envios) y la ventana horaria en `config`,
-- pero eliminó las 6 funciones que el worker llama, dejándolo en bucle
-- de error ("function _push_en_ventana() does not exist", etc.).
--
-- Esta migración:
--   1. Añade las claves de config con umbrales y cooldowns por defecto
--      (cambiables en caliente sin redeploy).
--   2. Crea las funciones:
--        _push_en_ventana()             → bool
--        push_candidatos_repaso()       → (usuario_id, n_vencidas)
--        push_candidatos_inactividad()  → (usuario_id, dias)
--        push_suscripciones_de(uuid)    → (endpoint, p256dh, auth)
--        push_marcar_envio(uuid,text,jsonb)
--        push_marcar_error(text,text)
--
-- Todas se llaman desde el rol dueño (aprentix) por PSQL directo del
-- worker, así que no llevan SECURITY DEFINER ni GRANTs a web_user.
--
-- Idempotente: se puede aplicar varias veces sin efectos duplicados.
-- ─────────────────────────────────────────────────────────────────────────
BEGIN;

-- ── 1. Semilla de config ─────────────────────────────────────────────────
INSERT INTO config (clave, valor) VALUES
    -- Nº mínimo de preguntas de repaso vencidas para que valga la pena avisar.
    ('push_min_vencidas',              to_jsonb(5)),
    -- Máx. 1 push de tipo 'repaso' cada N minutos por usuario (24 h).
    ('push_cooldown_repaso_min',       to_jsonb(24 * 60)),
    -- Máx. 1 push de tipo 'inactividad' cada N minutos por usuario (72 h).
    ('push_cooldown_inactividad_min',  to_jsonb(72 * 60)),
    -- Horas de inactividad (sin login ni intento) para considerar candidato.
    ('push_inactividad_min_horas',     to_jsonb(48))
ON CONFLICT (clave) DO NOTHING;


-- ── 2. Ventana horaria ───────────────────────────────────────────────────
-- Cierto si "ahora" (Europe/Madrid) cae en [push_ventana_ini, push_ventana_fin).
-- Con la semilla actual (9, 22) → 9:00 ≤ h < 22:00.
CREATE OR REPLACE FUNCTION _push_en_ventana() RETURNS boolean
LANGUAGE sql STABLE AS $$
    SELECT EXTRACT(hour FROM (now() AT TIME ZONE 'Europe/Madrid'))::int
           BETWEEN
             (SELECT (valor)::text::int FROM config WHERE clave='push_ventana_ini')
             AND
             (SELECT (valor)::text::int FROM config WHERE clave='push_ventana_fin') - 1;
$$;


-- ── 3. Candidatos a push de repaso ───────────────────────────────────────
-- Usuarios con ≥ push_min_vencidas preguntas cuyo intervalo_repaso(caja,
-- ritmo) ya ha caducado, con suscripción activa y sin push de repaso
-- reciente (cooldown).
CREATE OR REPLACE FUNCTION push_candidatos_repaso()
RETURNS TABLE (usuario_id uuid, n_vencidas int)
LANGUAGE sql STABLE AS $$
    WITH vencidos AS (
        SELECT r.usuario_id, count(*)::int AS n
        FROM repasos r
        WHERE r.ultima_en
              + intervalo_repaso(r.caja, ritmo_repaso_usuario(r.usuario_id))
              <= now()
        GROUP BY r.usuario_id
    ),
    umbral AS (
        SELECT (valor)::text::int AS v FROM config WHERE clave='push_min_vencidas'
    ),
    cd AS (
        SELECT (valor)::text::int AS m FROM config WHERE clave='push_cooldown_repaso_min'
    )
    SELECT v.usuario_id, v.n
    FROM vencidos v, umbral, cd
    WHERE v.n >= umbral.v
      AND EXISTS (
          SELECT 1 FROM push_suscripciones s
          WHERE s.usuario_id = v.usuario_id AND s.activa
      )
      AND NOT EXISTS (
          SELECT 1 FROM push_envios e
          WHERE e.usuario_id = v.usuario_id
            AND e.tipo = 'repaso'
            AND e.enviado_en > now() - make_interval(mins => cd.m)
      );
$$;


-- ── 4. Candidatos a push de inactividad ──────────────────────────────────
-- Última actividad = max(ultimo_login_en, último intento iniciado,
-- creado_en). Si superó push_inactividad_min_horas y sigue con
-- suscripción activa y sin push de inactividad reciente, se avisa.
-- `dias` es lo que se pinta en el cuerpo del push.
CREATE OR REPLACE FUNCTION push_candidatos_inactividad()
RETURNS TABLE (usuario_id uuid, dias int)
LANGUAGE sql STABLE AS $$
    WITH ult AS (
        SELECT u.id AS usuario_id,
               GREATEST(
                   COALESCE(u.ultimo_login_en, u.creado_en),
                   COALESCE(
                       (SELECT max(i.iniciado_en) FROM intentos i
                         WHERE i.usuario_id = u.id),
                       u.creado_en
                   )
               ) AS ts
        FROM usuarios u
        WHERE u.activo
          AND u.borrado_en IS NULL
          AND u.email_verificado_en IS NOT NULL
    ),
    umbral AS (
        SELECT (valor)::text::int AS h
          FROM config WHERE clave='push_inactividad_min_horas'
    ),
    cd AS (
        SELECT (valor)::text::int AS m
          FROM config WHERE clave='push_cooldown_inactividad_min'
    )
    SELECT ult.usuario_id,
           GREATEST(1, EXTRACT(day FROM (now() - ult.ts))::int) AS dias
    FROM ult, umbral, cd
    WHERE now() - ult.ts >= make_interval(hours => umbral.h)
      AND EXISTS (
          SELECT 1 FROM push_suscripciones s
          WHERE s.usuario_id = ult.usuario_id AND s.activa
      )
      AND NOT EXISTS (
          SELECT 1 FROM push_envios e
          WHERE e.usuario_id = ult.usuario_id
            AND e.tipo = 'inactividad'
            AND e.enviado_en > now() - make_interval(mins => cd.m)
      );
$$;


-- ── 5. Suscripciones activas de un usuario ───────────────────────────────
CREATE OR REPLACE FUNCTION push_suscripciones_de(p_usuario_id uuid)
RETURNS TABLE (endpoint text, p256dh text, auth text)
LANGUAGE sql STABLE AS $$
    SELECT s.endpoint, s.p256dh, s.auth
    FROM push_suscripciones s
    WHERE s.usuario_id = p_usuario_id AND s.activa;
$$;


-- ── 6. Registrar envío OK (para el rate-limit del próximo tick) ──────────
CREATE OR REPLACE FUNCTION push_marcar_envio(
    p_usuario_id uuid,
    p_tipo       text,
    p_payload    jsonb
) RETURNS void
LANGUAGE sql AS $$
    INSERT INTO push_envios (usuario_id, tipo, enviado_en, payload)
    VALUES (p_usuario_id, p_tipo, now(), p_payload)
    ON CONFLICT (usuario_id, tipo) DO UPDATE
        SET enviado_en = EXCLUDED.enviado_en,
            payload    = EXCLUDED.payload;
$$;


-- ── 7. Marcar suscripción muerta (404/410 del push service) ──────────────
CREATE OR REPLACE FUNCTION push_marcar_error(
    p_endpoint text,
    p_motivo   text
) RETURNS void
LANGUAGE sql AS $$
    UPDATE push_suscripciones
       SET activa       = false,
           ultimo_error = p_motivo
     WHERE endpoint = p_endpoint;
$$;


-- Recarga el schema cache de PostgREST (por si algún admin llama a estas
-- RPCs desde la SPA en el futuro).
NOTIFY pgrst, 'reload schema';

COMMIT;
