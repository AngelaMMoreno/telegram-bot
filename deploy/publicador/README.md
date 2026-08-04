# Stack `publicador` — publicar sin ejecutar nada a mano

Un contenedor de fondo que cada X minutos clona el repo de contenido,
compara con lo publicado y sube lo que haya cambiado. Sustituye a lanzar
`db/publicacion/publicar.py` a mano.

Mismo patrón que el stack `backups`: dcron en foreground, la hora por
variable de entorno y todo a `docker logs`.

---

## Puesta en marcha

En Dokploy, **Create Application → Compose**, apuntando a este repo con
`deploy/publicador/docker-compose.yml`. Igual que los demás stacks.

Variables mínimas:

| Variable | Ejemplo | Qué es |
|---|---|---|
| `CONTENIDO_REPO` | `https://x-access-token:<TOKEN>@github.com/tu-cuenta/oposiciones.git` | URL del repo de contenido |
| `PUBLICAR_DSN` | `postgres://aprentix:<PASS>@db:5432/aprentix` | La BBDD. `db` es el hostname del stack core |
| `CONTENIDO_RAMA` | `main` | Publica sólo lo mergeado |
| `PUBLICAR_CRON` | `*/15 * * * *` | Cada cuánto mira |
| `PUBLICAR_APLICAR` | *(vacío)* | **Déjala vacía al principio** |
| `AVISO_EMAIL` | `tu@correo.es` | A quién avisar si falla. Ver abajo |

### Avisos por email (importante si no usas CI)

Si tú haces los PR y los merges a mano, **sin ningún CI de por medio**,
este contenedor es lo único que revisa el contenido. Y cuando `--estricto`
aborta una publicación, lo hace dentro de un contenedor que nadie mira: se
deja de publicar en silencio hasta que alguien abra los logs.

Pon `AVISO_EMAIL` y las credenciales SMTP (**las mismas del stack
`mailer`**, así que si ya lo tienes configurado no hay nada nuevo que
preparar) y recibirás un correo con el motivo exacto:

```
[Aprentix] La publicación de contenido ha fallado

WARNING …/silencio/teoria.md: 9 preguntas en el pool, mínimo 25
ERROR 1 avisos de formato y --estricto activo
```

**Sólo se avisa en los cambios de estado.** Si el fallo persiste no
recibes un correo cada 15 minutos: uno cuando empieza a fallar y otro
cuando vuelve a funcionar. Nada entre medias.

Sin `AVISO_EMAIL` el contenedor funciona igual, pero los fallos sólo se
ven en `docker logs`.

### Arranca en simulacro, a propósito

Sin `PUBLICAR_APLICAR`, el contenedor **no escribe nada**: sólo enseña en
los logs qué publicaría. Déjalo así uno o dos días, mira `docker logs` y
comprueba que el plan es el que esperas. Cuando te cuadre, pon
`PUBLICAR_APLICAR=1` y redespliega.

Además hace una corrida nada más arrancar (`PUBLICAR_AL_ARRANCAR=1`), para
que no tengas que esperar al primer tic del cron para ver si la
configuración es correcta.

### Repo privado

Mete el token en la propia URL:

```
https://x-access-token:ghp_xxxxxxxxxxxx@github.com/tu-cuenta/oposiciones.git
```

Un token de sólo lectura sobre ese repo basta. **No aparece en los logs**:
tanto el entrypoint como `publicar.py` tapan las credenciales de cualquier
URL antes de imprimir nada.

---

## Las banderas están elegidas para correr sin nadie mirando

| Bandera | Por qué |
|---|---|
| `--estricto` | Un fichero que incumple la plantilla **aborta la publicación entera** en vez de llegar a los usuarios. Publicar contenido mal formado es peor que no publicar. |
| `--archivar-ausentes` | Lo que se quita del repo desaparece de la app. No se borra: se archiva conservando el progreso. |
| **sin** `--forzar` | Un parche urgente hecho a mano desde el panel no lo pisa un robot de madrugada. Se reporta y se deja. |
| **sin** `--permitir-archivado-masivo` | Ese flag existe para que lo ponga una persona que ha mirado la lista. |

Las dos salvaguardas están probadas contra este contenedor:

- **Contenido roto mergeado a `main`** (pool de 12 preguntas, tres sin
  explicación, nombre con número de tema): `--estricto` aborta y la BBDD
  conserva la versión buena.
- **Cambio de slugs mergeado a `main`**: el freno detecta que crearía
  tantas secciones como archivaría, aborta, y no se toca ni una fila.

En ambos casos el contenedor **sigue vivo**: el fallo se ve en los logs,
sale el aviso por email y la siguiente corrida lo reintenta. Un error de
contenido no tira el servicio.

---

## Qué NO es

**No es un sistema de CI.** Publica lo que ya está en la rama que le
digas, es decir, lo que alguien revisó y mergeó. La revisión previa sigue
siendo cosa del PR — para eso está `publicar.py --validar`, que corre sin
base de datos (ver `db/publicacion/README.md`).

El reparto queda así:

```
escribes → PR → validar (revisión)  → merge a main → publicador (automático)
                 ↑ humano o CI                        ↑ este contenedor
```

---

## Operación

```bash
# Ver qué ha hecho
docker logs -f <contenedor-publicador>

# Forzar una corrida sin esperar al cron
docker exec <contenedor-publicador> sh -c '. /etc/publicar.env && /publicar-job.sh'
```

Cada corrida imprime el plan (crear / actualizar / sin cambios /
archivar) y una línea de resumen con el commit publicado. Ese commit es
la respuesta a «¿qué versión hay viva ahora mismo?».

### Publicar sólo algunas oposiciones

`PUBLICAR_OPOSICIONES="auxilio-judicial gestion-procesal"`. Vacío = todas.

### Volver atrás

El contenedor publica siempre la punta de la rama. Para volver a una
versión anterior, lo natural es un `git revert` en el repo de contenido:
la siguiente corrida lo recoge solo.

Si hace falta ir a un commit concreto ya mismo, se hace a mano desde
cualquier sitio con acceso a la BBDD:

```bash
python3 publicar.py --repo <url> --commit a1b2c3d --db "…" --aplicar
```
