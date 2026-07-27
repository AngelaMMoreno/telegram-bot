-- 2026-07-28_mas_retos_logros.sql
-- ─────────────────────────────────────────────────────────────────────
-- Amplía el catálogo de retos y logros y añade los hooks que hacen que
-- realmente progresen.  Idempotente: se puede reejecutar sin efectos.
--
-- Novedades:
--   1) Seed de 10 retos nuevos (4 diarios, 3 semanales, 3 mensuales).
--   2) Seed de 6 logros nuevos (racha 7 y 30 días, umbrales de XP,
--      teoría en 50 secciones, 100 tests).
--   3) `_gamif_on_progreso_seccion` bumpea los códigos nuevos de
--      "N secciones al día/mes" y suma la XP correspondiente.
--   4) Nuevo trigger `_gamif_on_teoria_vista` sobre progreso_seccion
--      cuando `teoria_vista_en` pasa de NULL a NOT NULL — bumpea los
--      retos de teoría y otorga el logro `teoria_50` al cruzar el
--      umbral.
--   5) Nuevo trigger `_gamif_on_intento_finalizado` sobre intentos
--      cuando `finalizado_en` pasa de NULL a NOT NULL — bumpea los
--      retos de "N tests" y precisión, y otorga `tests_100`.
--   6) Extiende `_gamif_dar_xp` para otorgar `xp_1000`, `xp_5000`,
--      `racha_7` y `racha_30` en cuanto el usuario cruza el umbral.
-- ─────────────────────────────────────────────────────────────────────
BEGIN;

-- ─── 1) Nuevos retos ──────────────────────────────────────────────────
INSERT INTO retos_catalogo (codigo, titulo, descripcion, periodo, objetivo, xp, icono) VALUES
    ('diario_test_1',            'Test diario',      'Completa 1 test hoy',                             'diario',   1,  20, '📝'),
    ('diario_completar_2_secc',  'Doble sección',    'Completa 2 secciones hoy',                        'diario',   2,  45, '🌱'),
    ('diario_teoria_1',          'Lectura diaria',   'Lee la teoría de 1 sección hoy',                  'diario',   1,  15, '📖'),
    ('diario_precision_90',      'Excelencia',       'Saca al menos un 90 % en un test',                'diario',   1,  40, '💎'),
    ('semanal_tests_10',         'Diez tests',       'Completa 10 tests esta semana',                   'semanal', 10,  90, '📚'),
    ('semanal_teoria_5',         'Teoría a fondo',   'Lee la teoría de 5 secciones esta semana',        'semanal',  5,  70, '📖'),
    ('semanal_precision_75_x5',  'Consistencia',     'Termina 5 tests con al menos un 75 %',            'semanal',  5, 100, '🎯'),
    ('mensual_tests_30',         '30 tests',         'Completa 30 tests este mes',                      'mensual', 30, 250, '🚀'),
    ('mensual_secciones_20',     '20 secciones',     'Completa 20 secciones este mes',                  'mensual', 20, 300, '🏔️'),
    ('mensual_repaso_4',         'Repaso mensual',   'Haz 4 repasos globales este mes',                 'mensual',  4, 200, '🔁')
ON CONFLICT (codigo) DO NOTHING;


-- ─── 2) Nuevos logros ─────────────────────────────────────────────────
INSERT INTO logros_catalogo (codigo, titulo, descripcion, objetivo, xp, icono) VALUES
    ('racha_7',   'Semana de fuego',  'Mantén una racha de 7 días',                    7,  200, '🔥'),
    ('racha_30',  'Mes en llamas',    'Mantén una racha de 30 días',                  30,  800, '🌋'),
    ('xp_1000',   'Aprendiz',         'Alcanza los 1 000 puntos de XP',             1000,  100, '💠'),
    ('xp_5000',   'Veterano',         'Alcanza los 5 000 puntos de XP',             5000,  400, '💎'),
    ('teoria_50', 'Bibliotecari@',    'Lee la teoría de 50 secciones distintas',      50,  400, '📚'),
    ('tests_100', 'Centenari@',       'Completa 100 tests',                          100,  500, '🏅')
ON CONFLICT (codigo) DO NOTHING;


-- ─── 3) Extiende _gamif_on_progreso_seccion ───────────────────────────
-- Añade bumps para retos "2 secciones diarias" y "20 secciones al mes".
-- Mantiene todo el comportamiento anterior (XP, cascada a módulo/tema
-- y logros originales).
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
    PERFORM _gamif_bump_reto(v_uid, 'diario_completar_2_secc');
    PERFORM _gamif_bump_reto(v_uid, 'semanal_5_secciones');
    PERFORM _gamif_bump_reto(v_uid, 'mensual_secciones_20');
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

        SELECT m.tema_id INTO v_tema FROM modulos m WHERE m.id = v_modulo;
        SELECT COUNT(*) INTO v_mod_tot FROM modulos WHERE tema_id = v_tema;
        SELECT COUNT(*) INTO v_mod_ok
          FROM modulos m
         WHERE m.tema_id = v_tema
           AND (SELECT COUNT(*) FROM secciones s WHERE s.modulo_id = m.id) > 0
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


-- ─── 4) Trigger nuevo sobre teoría vista ──────────────────────────────
CREATE OR REPLACE FUNCTION _gamif_on_teoria_vista() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := NEW.usuario_id;
    v_total int;
BEGIN
    IF NEW.teoria_vista_en IS NULL THEN RETURN NEW; END IF;
    IF TG_OP = 'UPDATE' AND OLD.teoria_vista_en IS NOT NULL THEN
        RETURN NEW;
    END IF;
    -- Retos de teoría: se comparten con el seed original diario_teoria_2_secciones
    -- (objetivo 2), el nuevo diario_teoria_1 (objetivo 1) y semanal_teoria_5.
    PERFORM _gamif_bump_reto(v_uid, 'diario_teoria_2_secciones');
    PERFORM _gamif_bump_reto(v_uid, 'diario_teoria_1');
    PERFORM _gamif_bump_reto(v_uid, 'semanal_teoria_5');

    -- Logro "Bibliotecari@": 50 secciones distintas con teoría vista.
    SELECT COUNT(DISTINCT seccion_id) INTO v_total
      FROM progreso_seccion
     WHERE usuario_id = v_uid AND teoria_vista_en IS NOT NULL;
    IF v_total >= 50 THEN
        PERFORM _gamif_dar_logro(v_uid, 'teoria_50');
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS progreso_seccion_teoria_gamif ON progreso_seccion;
CREATE TRIGGER progreso_seccion_teoria_gamif
    AFTER INSERT OR UPDATE OF teoria_vista_en ON progreso_seccion
    FOR EACH ROW EXECUTE FUNCTION _gamif_on_teoria_vista();


-- ─── 5) Trigger nuevo sobre intentos finalizados ──────────────────────
CREATE OR REPLACE FUNCTION _gamif_on_intento_finalizado() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_uid uuid := NEW.usuario_id;
    v_total int;
BEGIN
    IF NEW.finalizado_en IS NULL THEN RETURN NEW; END IF;
    IF TG_OP = 'UPDATE' AND OLD.finalizado_en IS NOT NULL THEN
        RETURN NEW;
    END IF;
    -- Recuentos generales.
    PERFORM _gamif_bump_reto(v_uid, 'diario_test_1');
    PERFORM _gamif_bump_reto(v_uid, 'semanal_tests_10');
    PERFORM _gamif_bump_reto(v_uid, 'mensual_tests_30');
    -- Sólo los repasos globales suman aquí.
    IF NEW.origen = 'repaso' THEN
        PERFORM _gamif_bump_reto(v_uid, 'semanal_repaso_global_1');
        PERFORM _gamif_bump_reto(v_uid, 'mensual_repaso_4');
    END IF;
    -- Retos por nota (precisión).
    IF NEW.nota IS NOT NULL AND NEW.nota >= 80 THEN
        PERFORM _gamif_bump_reto(v_uid, 'diario_acierto_80');
    END IF;
    IF NEW.nota IS NOT NULL AND NEW.nota >= 90 THEN
        PERFORM _gamif_bump_reto(v_uid, 'diario_precision_90');
    END IF;
    IF NEW.nota IS NOT NULL AND NEW.nota >= 75 THEN
        PERFORM _gamif_bump_reto(v_uid, 'semanal_precision_75_x5');
    END IF;

    -- Logro tests_100: se cuenta con la totalidad histórica.
    SELECT COUNT(*) INTO v_total
      FROM intentos
     WHERE usuario_id = v_uid AND finalizado_en IS NOT NULL;
    IF v_total >= 100 THEN
        PERFORM _gamif_dar_logro(v_uid, 'tests_100');
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS intento_finalizado_gamif ON intentos;
CREATE TRIGGER intento_finalizado_gamif
    AFTER INSERT OR UPDATE OF finalizado_en ON intentos
    FOR EACH ROW EXECUTE FUNCTION _gamif_on_intento_finalizado();


-- ─── 6) _gamif_dar_xp — logros de XP y racha ──────────────────────────
-- Mantiene toda la lógica de suma / racha y sólo añade checks al final
-- para otorgar logros por umbral (idempotentes por _gamif_dar_logro).
CREATE OR REPLACE FUNCTION _gamif_dar_xp(p_usuario_id uuid, p_delta int)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
    v_hoy  date := hoy_madrid();
    v_gm   usuario_gamificacion%ROWTYPE;
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

    -- Logros por umbral. Los _gamif_dar_logro son idempotentes, así que
    -- llamarlos en cada bump es seguro.
    SELECT * INTO v_gm FROM usuario_gamificacion WHERE usuario_id = p_usuario_id;
    IF v_gm.xp_total >= 1000 THEN PERFORM _gamif_dar_logro(p_usuario_id, 'xp_1000'); END IF;
    IF v_gm.xp_total >= 5000 THEN PERFORM _gamif_dar_logro(p_usuario_id, 'xp_5000'); END IF;
    IF v_gm.racha_actual >= 7  THEN PERFORM _gamif_dar_logro(p_usuario_id, 'racha_7');  END IF;
    IF v_gm.racha_actual >= 30 THEN PERFORM _gamif_dar_logro(p_usuario_id, 'racha_30'); END IF;
END $$;


-- Refresca el esquema para PostgREST.
NOTIFY pgrst, 'reload schema';

COMMIT;
