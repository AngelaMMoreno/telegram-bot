#!/bin/sh
#
# Una corrida de publicación. Lo lanza cron (ver entrypoint.sh).
#
# Las banderas están elegidas para que esto pueda correr solo, de noche y
# sin nadie mirando. Las tres decisiones que importan:
#
#   --estricto   Un fichero que incumple la plantilla ABORTA la publicación
#                entera en vez de llegar a los usuarios. Publicar contenido
#                mal formado es peor que no publicar.
#
#   --archivar-ausentes  Lo que se quita del repo desaparece de la app. No
#                se borra nada: se archiva, conservando el progreso. El
#                freno anti-archivado-masivo sigue activo, así que un
#                cambio de slugs detiene la corrida en vez de vaciar el
#                temario.
#
#   SIN --forzar Un parche urgente hecho a mano desde el panel NO lo pisa
#                un robot de madrugada. Se reporta y se deja.
#
# Y nunca --permitir-archivado-masivo: ese flag existe para que lo ponga
# una persona que ha mirado la lista, no para automatizar.
set -u

ESTADO=/var/lib/publicador/estado
LOG=/var/lib/publicador/ultima-corrida.log
mkdir -p /var/lib/publicador

{
    echo "─────────────────────────────────────────────────────────"
    echo "[$(date '+%F %T')] arrancando publicación"

    RAMA_ARG=""
    [ -n "${CONTENIDO_RAMA:-}" ] && RAMA_ARG="--rama ${CONTENIDO_RAMA}"

    OPOSICIONES_ARG=""
    for slug in ${PUBLICAR_OPOSICIONES:-}; do
        OPOSICIONES_ARG="$OPOSICIONES_ARG --oposicion $slug"
    done

    # shellcheck disable=SC2086
    python3 /app/publicar.py \
        --repo "$CONTENIDO_REPO" \
        $RAMA_ARG \
        $OPOSICIONES_ARG \
        --db "$PUBLICAR_DSN" \
        --estricto \
        --archivar-ausentes \
        ${PUBLICAR_APLICAR:+--aplicar}
    echo "RC_PUBLICAR=$?"
} > "$LOG" 2>&1

RC=$(sed -n 's/^RC_PUBLICAR=//p' "$LOG" | tail -1)
: "${RC:=1}"

# Todo a los logs del contenedor, que es donde se mira primero.
cat "$LOG"

# ── Aviso por email, sólo en los CAMBIOS de estado ──────────────────────
# Sin esto, un merge malo para la publicación en silencio dentro de un
# contenedor que nadie mira. Y avisando en cada corrida, serían cuatro
# correos por hora hasta que alguien lo arregle: así que sólo se avisa
# cuando se pasa de bien a mal y cuando se vuelve a la normalidad.
ANTERIOR=$(cat "$ESTADO" 2>/dev/null || echo "")

if [ "$RC" -eq 0 ]; then
    echo "[$(date '+%F %T')] terminado correctamente"
    if [ "$ANTERIOR" = "fallo" ]; then
        python3 /app/avisar.py "[Aprentix] La publicación vuelve a funcionar" "$LOG" || true
    fi
    echo ok > "$ESTADO"
else
    # El contenedor sigue vivo (es un cron): el fallo se ve en los logs y
    # la siguiente corrida lo reintenta. Un error de contenido no debería
    # tirar el servicio.
    echo "[$(date '+%F %T')] FALLÓ con código $RC — revisa los avisos de arriba" >&2
    if [ "$ANTERIOR" != "fallo" ]; then
        python3 /app/avisar.py "[Aprentix] La publicación de contenido ha fallado" "$LOG" || true
    fi
    echo fallo > "$ESTADO"
fi

exit "$RC"
