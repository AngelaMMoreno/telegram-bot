# notifier

Servicio Python que envía notificaciones **Web Push** desde Aprentix a
los dispositivos suscritos (Android nativo y iOS 16.4+ tras "Añadir a
pantalla de inicio"). No usa ningún servicio de pago: solo el estándar
Web Push con claves VAPID auto-generadas.

## Qué hace

1. Escucha `LISTEN gamificacion` sobre Postgres. Cuando un trigger de
   la BBDD encola una fila en `notificaciones_pendientes` (por ejemplo,
   "un amigo completó un reto" o "te llegó una solicitud de amistad"),
   drena la cola inmediatamente y hace un `webpush()` a cada suscripción
   del destinatario.
2. Cada 5 min hace un **barrido de repasos vencidos** por usuario. Si
   alguien tiene más de `NOTIF_DIGEST_UMBRAL` preguntas vencidas y no le
   hemos avisado en las últimas `NOTIF_DIGEST_MIN_HORAS`, le manda **un
   solo push agregado** ("Tienes 47 preguntas por repasar"). Nunca 200
   pushes seguidos.
3. Sólo envía dentro de la franja `NOTIF_QUIET_START..NOTIF_QUIET_END`
   (por defecto 09:00-22:00) para no ser invasivo.

## Variables de entorno

| Nombre | Descripción |
| ------ | ----------- |
| `DATABASE_URL`             | DSN Postgres tipo `postgres://aprentix@db/aprentix` (usa `PGPASSWORD` para la contraseña). |
| `VAPID_PUBLIC_KEY_B64URL`  | Clave pública VAPID en base64url. El servicio la publica en `config` para que el frontend la lea vía RPC. |
| `VAPID_PRIVATE_KEY_PEM`    | Clave privada VAPID en formato PEM (multilínea). |
| `VAPID_SUBJECT`            | `mailto:soporte@aprentix.es` (recomendado). |
| `NOTIF_DIGEST_UMBRAL`      | Mínimo de vencidas para avisar (default 5). |
| `NOTIF_DIGEST_MIN_HORAS`   | Horas mínimas entre digests para el mismo usuario (default 12). |
| `NOTIF_QUIET_START` / `_END` | Franja horaria (hora local del servidor) en la que sí notificar. |

## Generar claves VAPID

Una vez por proyecto (no cambian salvo rotación explícita). En cualquier
máquina con Python + `py-vapid` instalado:

```bash
pip install py-vapid
python -c "
from py_vapid import Vapid01
v = Vapid01()
v.generate_keys()
print('---- VAPID_PRIVATE_KEY_PEM (multilínea) ----')
print(v.private_pem().decode())
print('---- VAPID_PUBLIC_KEY_B64URL ----')
print(v.public_key_b64u())
"
```

Pega el resultado en tus `.env` (los ficheros que Dokploy expone al
stack `notifier`). Puedes reutilizar la misma clave privada por siempre.
