-- ============================================================================
-- Delta 2026-07-04: RPC de diagnóstico de notificaciones Web Push.
--
-- El motor de envío vive en el worker `notificador` (Python) y decide a
-- quién avisar mirando cuatro cosas:
--   1) que haya al menos una suscripción activa,
--   2) que estemos dentro de la ventana horaria,
--   3) que el usuario supere el umbral (min_vencidas / inactividad_horas),
--   4) que el último envío del mismo tipo haya sido hace >= cooldown horas.
--
-- Cuando un push "no llega" hay que averiguar cuál de esas cuatro condiciones
-- está fallando. Esta RPC devuelve, para el usuario logueado, el valor de
-- cada condición y los umbrales de config, para poder autoservicio desde la
-- SPA sin tener que meterse en logs del contenedor.
--
-- Idempotente.  pgAdmin → Query Tool → F5.
-- ============================================================================

BEGIN;

-- push_envios sólo la puede leer el worker (rol aprentix); web_user está
-- vetado por RLS + falta de GRANT. La RPC accede como SECURITY DEFINER para
-- poder leer el último envío del propio usuario sin abrir la tabla al
-- resto de rutas de la API.  search_path fijado para evitar sorpresas.
CREATE OR REPLACE FUNCTION mi_diagnostico_push() RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid          uuid := jwt_usuario_id();
    v_cfg          jsonb := push_config_worker();
    v_tz           text  := v_cfg->>'tz';
    v_now_madrid   timestamp := (now() AT TIME ZONE v_tz)::timestamp;
    v_hoy          date := v_now_madrid::date;
    v_hora         int := extract(hour FROM v_now_madrid)::int;
    v_vent_ini     int := (v_cfg->>'ventana_ini')::int;
    v_vent_fin     int := (v_cfg->>'ventana_fin')::int;
    v_min_venc     int := (v_cfg->>'min_vencidas')::int;
    v_int_repaso   int := (v_cfg->>'intervalo_repaso_horas')::int;
    v_inact_h      int := (v_cfg->>'inactividad_horas')::int;
    v_inact_cd     int := (v_cfg->>'inactividad_cooldown_h')::int;
    v_suscripciones int;
    v_vencidas     int;
    v_ultimo_dia   date;
    v_dias_inact   int;
    v_ult_env_rep  timestamptz;
    v_ult_env_ina  timestamptz;
    v_vapid_ok     boolean;
BEGIN
    IF v_uid IS NULL THEN RAISE EXCEPTION 'no_autenticado'; END IF;

    SELECT count(*) INTO v_suscripciones
      FROM push_suscripciones WHERE usuario_id = v_uid AND activa;

    SELECT count(*) INTO v_vencidas
      FROM repasos r
     WHERE r.usuario_id = v_uid
       AND r.ultima_en + intervalo_repaso(r.caja, ritmo_repaso_usuario(v_uid)) <= now();

    SELECT ultimo_dia_activo INTO v_ultimo_dia
      FROM usuario_gamificacion WHERE usuario_id = v_uid;
    IF v_ultimo_dia IS NOT NULL THEN
        v_dias_inact := (v_hoy - v_ultimo_dia)::int;
    END IF;

    SELECT enviado_en INTO v_ult_env_rep FROM push_envios
     WHERE usuario_id = v_uid AND tipo = 'repaso';
    SELECT enviado_en INTO v_ult_env_ina FROM push_envios
     WHERE usuario_id = v_uid AND tipo = 'inactividad';

    v_vapid_ok := COALESCE(length((push_config_publica()->>'vapid_public_key')) > 0, false);

    RETURN jsonb_build_object(
        'ahora',              v_now_madrid,
        'zona',               v_tz,
        'ventana_ini',        v_vent_ini,
        'ventana_fin',        v_vent_fin,
        'hora_actual',        v_hora,
        'en_ventana',         v_hora >= v_vent_ini AND v_hora < v_vent_fin,
        'suscripciones',      v_suscripciones,
        'vapid_configurada',  v_vapid_ok,
        'vencidas',           v_vencidas,
        'min_vencidas',       v_min_venc,
        'ultimo_dia_activo',  v_ultimo_dia,
        'dias_inactivo',      v_dias_inact,
        'inactividad_horas',  v_inact_h,
        'ultimo_push_repaso', v_ult_env_rep,
        'cooldown_repaso_h',  v_int_repaso,
        'ultimo_push_inact',  v_ult_env_ina,
        'cooldown_inact_h',   v_inact_cd
    );
END $$;

-- Buenas prácticas de SECURITY DEFINER: quitar el EXECUTE a PUBLIC y
-- concederlo solo al rol de la API. jwt_usuario_id() garantiza que un
-- anónimo no obtiene nada, pero cerrar la puerta a nivel de GRANT es más
-- barato de auditar.
REVOKE ALL ON FUNCTION mi_diagnostico_push() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION mi_diagnostico_push() TO web_user;

NOTIFY pgrst, 'reload schema';

COMMIT;
