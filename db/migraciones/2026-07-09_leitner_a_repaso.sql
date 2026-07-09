-- ─────────────────────────────────────────────────────────────────────────
-- Renombra los literales que aún hablaban de "caja Leitner" por lenguaje
-- de repaso, más claro para el usuario. Solo cambia textos visibles en la
-- UI (retos, logros); la mecánica interna sigue exactamente igual.
--
-- Idempotente: puede ejecutarse varias veces sin efectos duplicados.
-- ─────────────────────────────────────────────────────────────────────────
BEGIN;

UPDATE retos_catalogo
   SET descripcion = 'Sube de nivel de repaso a 5 preguntas'
 WHERE codigo = 'diario_domar_5';

UPDATE retos_catalogo
   SET descripcion = 'Domina 20 preguntas este mes'
 WHERE codigo = 'mensual_dominar_20';

UPDATE logros_catalogo
   SET descripcion = 'Domina tu primera pregunta'
 WHERE codigo = 'primer_dominio';

UPDATE logros_catalogo
   SET descripcion = 'Domina 100 preguntas'
 WHERE codigo = 'dominador_100';

COMMIT;

NOTIFY pgrst, 'reload schema';
