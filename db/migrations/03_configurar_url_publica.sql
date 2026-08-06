-- =============================================================================
-- Hace que los enlaces de los correos usen la URL pública configurada en el
-- proceso de PostgreSQL, sin depender del valor inicial guardado en config.
--
-- Ejecutar en instalaciones con un volumen persistente. Después, reiniciar el
-- servicio db con DOMINIO_LANDING definido en el stack core.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION app_url() RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        NULLIF(current_setting('app.app_url', true), ''),
        (SELECT valor #>> '{}' FROM config WHERE clave = 'app_url'),
        'http://localhost'
    );
$$;

COMMIT;
