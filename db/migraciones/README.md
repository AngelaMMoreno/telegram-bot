# Migraciones manuales

El proyecto **no** ejecuta esta carpeta automáticamente. La fuente de
verdad del esquema para BBDD **nuevas** es `db/init/01_esquema.sql`; se
corre solo cuando Postgres arranca sobre un `PGDATA` vacío.

Cuando cambia el esquema y ya hay una BBDD viva en producción, el
delta correspondiente vive aquí como fichero SQL con fecha en el
nombre. Aplícalo a mano (una sola vez) desde pgAdmin → Query Tool.

Todos los ficheros son idempotentes: pueden ejecutarse varias veces
sin efectos duplicados.

## Ficheros

| Fecha       | Fichero                                    | Qué añade |
|-------------|--------------------------------------------|-----------|
| 2026-07-02  | `2026-07-02_teoria_y_reset_repasos.sql`    | Rol `teoria`, permisos, tabla `ficheros_vistas`, RPCs de vistas y `resetear_mis_repasos`. |
| 2026-07-03  | `2026-07-03_gamificacion.sql`              | Tablas de retos/logros/XP, motor de gamificación con hooks en `registrar_respuesta`, `finalizar_intento` y `marcar_fichero_visto`. Seed de 18 retos y 9 logros. |
| 2026-07-03  | `2026-07-03_push_notificaciones.sql`       | Tablas `push_suscripciones` y `push_envios`, RPCs de suscripción y helpers para el worker `notificador`. Semilla de config con la ventana horaria y los cooldowns. |
| 2026-07-03  | `2026-07-03_logros_notificaciones.sql`     | `registrar_respuesta`, `finalizar_intento` y `marcar_fichero_visto` pasan a devolver `jsonb` con `logros_desbloqueados`. El motor de gamificación (`_gamif_bump_logro`, `_gamif_actualizar_racha`, los `on_*`) acumula los logros recién obtenidos para que el frontend pinte una tarjeta de notificación por logro. |

## Al aplicar cada delta

1. Backup previo (por si algo sale mal):
   ```bash
   docker compose -f deploy/core/docker-compose.yml exec db \
       pg_dump -Fc -U aprentix -d aprentix \
       > db/backups/aprentix_$(date +%F).dump
   ```
2. pgAdmin → conecta al servidor `aprentix` → Query Tool → abre el
   fichero y pulsa Execute (F5).
3. Revisa los `NOTICE` al final: el script imprime un pequeño resumen
   con los objetos creados.
4. El script hace `NOTIFY pgrst, 'reload schema'` al final; PostgREST
   recarga su esquema sin necesidad de reiniciar el contenedor.
