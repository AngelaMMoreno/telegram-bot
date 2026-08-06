-- =============================================================================
-- Expone las funciones de autenticación y actualiza la caché de PostgREST.
--
-- Ejecutar en la MISMA base de datos a la que apunta PGRST_DB_URI cuando la
-- instalación ya tiene un volumen persistente. Los scripts de db/init sólo se
-- ejecutan automáticamente al crear un volumen de PostgreSQL vacío.
-- =============================================================================

BEGIN;

GRANT USAGE ON SCHEMA public TO web_anon, web_user;
GRANT EXECUTE ON FUNCTION public.registrar_web(text, text, text) TO web_anon, web_user;
GRANT EXECUTE ON FUNCTION public.reenviar_verificacion(text) TO web_anon, web_user;
GRANT EXECUTE ON FUNCTION public.verificar_email(text) TO web_anon, web_user;
GRANT EXECUTE ON FUNCTION public.login_web(text, text) TO web_anon, web_user;

COMMIT;

NOTIFY pgrst, 'reload schema';
