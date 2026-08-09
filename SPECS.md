# Aprentix — Especificaciones (Spec-Driven Development)

Este documento es **la fuente de verdad** del producto Aprentix. Describe QUÉ
debe hacer el sistema — no cómo lo hace hoy. Cualquier cambio en el
comportamiento del producto empieza modificando este documento; la
implementación (schema SQL, RPCs, SPA, workers, deploy) se ajusta después.

Formato: los requisitos llevan IDs estables (`RF-*` funcionales, `RN-*` no
funcionales, `RB-*` reglas de negocio, `UX-*` interfaz). Los escenarios usan
`Given / When / Then`. Los criterios de aceptación son medibles.

**Cambios de spec** — abrir PR contra este fichero. Sólo mergeable si:
1. La sección modificada mantiene coherencia con el resto.
2. Se actualizan los criterios de aceptación afectados.
3. Se listan los IDs de requisitos añadidos/modificados/retirados.

---

## Índice

- **Parte I — Producto**
  - [1. Visión y problema](#1-visión-y-problema)
  - [2. Usuarios y roles](#2-usuarios-y-roles)
  - [3. Principios de producto](#3-principios-de-producto)
  - [4. Glosario del dominio](#4-glosario-del-dominio)
- **Parte II — Requisitos funcionales**
  - [5. Cuenta y sesión](#5-cuenta-y-sesión)
  - [6. Onboarding](#6-onboarding)
  - [7. Contenido (oposiciones, temas, unidades, preguntas)](#7-contenido)
  - [8. Planificador](#8-planificador)
  - [9. Modo estudio](#9-modo-estudio)
  - [10. Repetición espaciada](#10-repetición-espaciada)
  - [11. Progreso y auto-tracking](#11-progreso-y-auto-tracking)
  - [12. Métricas y adaptación semanal](#12-métricas-y-adaptación-semanal)
  - [13. Notificaciones](#13-notificaciones)
  - [14. Administración](#14-administración)
  - [15. Perfil y preferencias](#15-perfil-y-preferencias)
- **Parte III — Requisitos no funcionales**
  - [16. Seguridad y privacidad](#16-seguridad-y-privacidad)
  - [17. Rendimiento y disponibilidad](#17-rendimiento-y-disponibilidad)
  - [18. Accesibilidad](#18-accesibilidad)
  - [19. Compatibilidad y responsive](#19-compatibilidad-y-responsive)
  - [20. Observabilidad, backups y recuperación](#20-observabilidad-backups-y-recuperación)
- **Parte IV — Interfaz (specs de comportamiento)**
  - [21. Estructura general](#21-estructura-general)
  - [22. Vista Home](#22-vista-home)
  - [23. Vista Plan](#23-vista-plan)
  - [24. Vista Estadísticas](#24-vista-estadísticas)
  - [25. Vista Perfil](#25-vista-perfil)
  - [26. Vista Mi Oposición](#26-vista-mi-oposición)
  - [27. Vista Unidad](#27-vista-unidad)
  - [28. Vista Modo Estudio](#28-vista-modo-estudio)
  - [29. Wizard de disponibilidad](#29-wizard-de-disponibilidad)
  - [30. Vistas de admin](#30-vistas-de-admin)
- **Parte V — Contratos**
  - [31. Modelo conceptual del dominio](#31-modelo-conceptual-del-dominio)
  - [32. Contratos de API (comportamiento)](#32-contratos-de-api-comportamiento)
- **Parte VI — Estado y roadmap**
  - [33. Estado actual](#33-estado-actual)
  - [34. Roadmap priorizado](#34-roadmap-priorizado)
- **Apéndices**
  - [A. Implementación técnica actual](#a-implementación-técnica-actual)
  - [B. Convenciones de código](#b-convenciones-de-código)
  - [C. Referencias del repositorio](#c-referencias-del-repositorio)

---

# Parte I — Producto

## 1. Visión y problema

### 1.1 Visión

Aprentix es una plataforma web (PWA-ready) para preparar oposiciones al
servicio público español, que **decide por el opositor qué estudiar cada día**
y le acompaña con un motor de estudio activo, en lugar de servir contenido
pasivo y dejarle organizarse.

### 1.2 Problema que resuelve

Preparar una oposición larga (12–24 meses) exige:

- Un temario amplio que no se puede afrontar en un mes.
- Repasos espaciados para que no se olvide lo aprendido.
- Disciplina diaria sostenida con energía variable.
- Auto-evaluación honesta del progreso.

El opositor típico falla en **la gestión**, no en el temario. Aprentix
convierte esa gestión en una experiencia guiada: un botón "Estudiar" que
sabe qué toca hoy, un plan que se re-ajusta solo cuando la vida se
atraviesa, y métricas que motivan sin castigar.

### 1.3 No-objetivos (fuera de alcance)

- **NO** es un lector pasivo de PDFs ni un LMS clásico.
- **NO** es una red social ni un foro entre opositores.
- **NO** produce contenido propio: el contenido lo cargan admins.
- **NO** valida oficialmente ningún temario.

---

## 2. Usuarios y roles

### 2.1 Personas

- **Opositor** — usuario final. Prepara 1 o varias oposiciones simultáneas.
- **Administrador** — gestiona catálogo de oposiciones y usuarios.

### 2.2 Roles del sistema

| Rol         | Descripción                                                        |
|-------------|--------------------------------------------------------------------|
| `web_anon`  | Sin sesión. Sólo puede registrarse, verificar email, iniciar sesión, pedir reset. |
| `web_user`  | Sesión iniciada. Todas las funciones de opositor. Con RLS: ve sólo sus datos. |
| `admin`     | Rol de aplicación. `web_user` con permisos elevados. Ve/edita todo lo del catálogo y usuarios. |

### 2.3 Permisos por rol

**Opositor (`web_user`)**:
- Ver su propia sesión, plan, estadísticas, progreso.
- Ver todas las oposiciones activas del catálogo.
- Matricularse en oposiciones y cambiar la activa.
- Editar su disponibilidad, ritmo, sistema de estudio.
- Iniciar/terminar sesiones de estudio.
- Responder preguntas y ver explicaciones.
- Configurar tema (claro/oscuro), notificaciones.

**Admin**:
- Todo lo anterior +
- CRUD completo de oposiciones, temas, unidades, preguntas.
- Editar fecha del examen (real u orientativa) de cada oposición.
- Listar y gestionar usuarios (activar, desactivar, verificar email, cambiar rol).
- Ver contadores globales (usuarios, oposiciones, colas).
- Importar oposiciones desde JSON.

### 2.4 Regla de escalación

**RB-01** — El rol `admin` sólo se asigna manualmente por otro admin o desde
el bootstrap del schema. **Nunca** se auto-asigna al registrarse.

**RB-02** — El primer admin (`admin@aprentix.es`) se crea automáticamente en
el bootstrap de la BBDD, con contraseña provista por variable de entorno,
verificado y activo.

---

## 3. Principios de producto

Reglas transversales que todas las features deben respetar. Incumplirlas es
un bug de spec.

### 3.1 El opositor no organiza — el sistema le guía

**RP-01** — La acción principal desde Home es un único botón "Estudiar".
Pulsarlo debe ser suficiente para empezar a estudiar sin más decisiones.

**RP-02** — El sistema decide qué unidad tocar (basándose en unidades
pendientes + repasos vencidos + horas disponibles hoy), no el usuario.

**RP-03** — El opositor puede consultar su plan y ajustarlo, pero no está
obligado. Con solo "Estudiar" cada día el sistema le lleva.

### 3.2 Nunca deprimir, siempre acompañar

**RP-04** — Los mensajes del sistema (resúmenes semanales, notificaciones,
empty states) usan tono positivo o neutro. Prohibido:
- "No has estudiado…"
- "Vas retrasado", "vas mal".
- Cifras rojas grandes.

Permitido:
- "Cada bloque suma."
- "Hoy es un buen día para empezar de nuevo."
- Reformular "0% completado" como "Hoy empezamos limpio".

### 3.3 Progreso implícito

**RP-05** — El usuario **nunca** marca una teoría como "leída" con un botón.
El sistema lo deriva del tiempo real de estudio (auto-tracking con Page
Visibility API).

**RP-06** — Al terminar un modo de estudio, los bloques procesados se
marcan solos en el plan del día. El usuario no debe tocar checkboxes.

### 3.4 Adaptación

**RP-07** — Si el usuario cumple <50% de su plan semanal, la carga baja
20% la siguiente semana. Si cumple >90%, sube 15%. Automático.

**RP-08** — Si el usuario dice "hoy tengo otro tiempo", el plan del día
se recalcula y el resto de la semana redistribuye lo pendiente sin
superar los límites diarios configurados.

### 3.5 Reutilización de contenido

**RP-09** — Los temas son un catálogo global. Un tema ("Constitución
Española") puede vincularse a varias oposiciones sin duplicarse. Las
unidades y preguntas pertenecen al tema, no a la oposición, por lo que
también se comparten.

### 3.6 Nunca atrapado

**RP-10** — Toda pantalla que no sea la home tiene siempre un botón "Atrás"
o "Salir" claramente visible, para que el usuario nunca se sienta
atrapado (ni siquiera en el wizard u onboarding).

### 3.7 No scroll de página completa en flujos activos

**RP-11** — En el modo estudio, la cabecera y los botones de acción deben
estar siempre visibles. El contenido del bloque scrollea dentro de su
propio contenedor, nunca a nivel de página.

**RP-12** — En las vistas de menú (Home, Plan, Estadísticas, Perfil,
Oposición), la top-bar (logo + nivel + racha + avatar) es sticky y siempre
visible.

---

## 4. Glosario del dominio

| Término              | Significado                                                                 |
|----------------------|-----------------------------------------------------------------------------|
| **Oposición**        | Convocatoria pública concreta (ej. "Auxiliar Administrativo del Estado").   |
| **Tema**             | Bloque temático reutilizable (ej. "Constitución Española").                 |
| **Unidad**           | Subdivisión concreta de un tema con su propia teoría y preguntas.           |
| **Pregunta**         | Ítem de test con enunciado, 2–5 opciones (1 correcta), explicación y dificultad 1–5. |
| **Plan de estudio**  | Configuración por usuario y oposición: disponibilidad, ritmo, método, fecha del examen. |
| **Bloque**           | Unidad atómica del plan diario (`estudio`, `repaso`, `test`, `descanso`).   |
| **Sesión de estudio**| Ventana de tiempo real durante la cual el usuario está estudiando activamente. |
| **Sesión activa**    | Estado transitorio del modo estudio en curso (índice del bloque actual, etc). |
| **Auto-tracking**    | Contabilización automática de minutos activos usando la Page Visibility API. |
| **Repaso espaciado** | Presentación de preguntas ya vistas siguiendo intervalos SM-2.               |
| **Sistema de estudio** | Configuración de ciclos (Pomodoro, Ultradiano…): duración de estudio y descansos. |
| **Racha**            | Nº de días consecutivos con al menos una sesión de estudio.                  |
| **Fatiga cognitiva** | Δ de precisión entre la 1ª y 2ª mitad de una sesión de tests.                |
| **Ritmo**            | Enum `{relajado, normal, intensivo}` que modula la agresividad del plan.     |
| **Modo disponibilidad** | Enum `{semanal, diario}` — si el opositor da horas totales o por día.     |
| **Fecha orientativa**| Fecha de examen conocida sólo por mes/año (día = 1, `orientativa=true`).     |

---

# Parte II — Requisitos funcionales

## 5. Cuenta y sesión

### 5.1 Registro

**RF-05.1.1** — Un usuario nuevo se registra con: email, email repetido,
contraseña, contraseña repetida, nombre.

**RF-05.1.2** — Reglas de validación en cliente y servidor:
- Email con formato válido, único.
- Emails deben coincidir (comparación insensible a mayúsculas).
- Contraseñas deben coincidir.
- Contraseña mínima 8 caracteres. El servidor calcula fuerza en 4 niveles
  (débil, aceptable, fuerte, muy fuerte); mínimo aceptable = nivel 2.

**RF-05.1.3** — Tras registro exitoso, se encola un email de verificación
con enlace `#/verify?token=…`. El token caduca en **3 días**.

**RF-05.1.4** — Hasta verificar, `login_web` responde `email_no_verificado`.
El usuario ve un enlace "¿No has recibido el correo?" para reenviar
(rate-limit: 1 correo cada 5 min por email).

**Escenario — registro OK**
- Given un usuario sin cuenta con email `a@b.com`
- When se registra con contraseña fuerte y nombre "Ana"
- Then recibe un correo de "no-reply@aprentix.es" con enlace de activación
- And al pulsar el enlace se activa la cuenta y puede iniciar sesión

**Escenario — email duplicado**
- Given un usuario intenta registrarse con `a@b.com` que ya existe
- Then el servidor responde `email_registrado` y no encola correo
- And el mensaje mostrado es "Ese correo ya está registrado."

### 5.2 Login

**RF-05.2.1** — Login con email + contraseña. Devuelve un JWT firmado por
la BBDD con `sub = usuario_id`, `roles = ['web_user', 'admin'?]`, caducidad
**30 días**.

**RF-05.2.2** — El JWT se persiste en `localStorage.aprentix_token`. Cada
request al backend lleva `Authorization: Bearer <token>`.

**RF-05.2.3** — Mensajes de error concretos:
- Contraseña incorrecta → "Correo o contraseña incorrectos."
- Email no verificado → banner con botón "Reenviar correo".
- Usuario desactivado → "Cuenta desactivada. Contacta con el administrador."

**RF-05.2.4** — Si el JWT existe pero al llamar `mi_sesion()` la respuesta
es `null` (usuario borrado, BBDD reseteada, JWT huérfano), se **limpia el
token automáticamente** y se redirige a login sin mostrar error.

### 5.3 Reset de contraseña

**RF-05.3.1** — Desde login → "¿Olvidaste la contraseña?" → introducir email.
Si existe, se encola correo con enlace `#/reset?token=…`. Si no existe,
**se responde igual** para no filtrar emails registrados.

**RF-05.3.2** — El token de reset caduca en **24 horas**.

**RF-05.3.3** — Al aplicar reset con contraseña válida, se inicia sesión
automáticamente y se redirige a Home.

### 5.4 Cierre de sesión

**RF-05.4.1** — Botón "Cerrar sesión" siempre disponible en:
- Perfil.
- Onboarding (para poder cambiar de cuenta).
- Wizard de disponibilidad (idem).

**RF-05.4.2** — Cierre confirmado con diálogo excepto desde el Perfil.
Limpia `localStorage`, resetea estado, redirige a login.

---

## 6. Onboarding

### 6.1 Elección de oposición

**RF-06.1.1** — Al primer login (o siempre que no haya oposición
matriculada) se lleva al usuario a `#/onboarding` con el catálogo de
oposiciones activas.

**RF-06.1.2** — El usuario elige UNA oposición como principal. Puede
matricularse en más después desde Home → chip oposición → "Añadir otra".

**RF-06.1.3** — Si no hay oposiciones en el catálogo:
- Usuario normal: mensaje "Un administrador debe importar una oposición
  primero." + botón "Cerrar sesión".
- Admin: botón adicional "📚 Importar oposición" que va a `#/administracion`.

### 6.2 Wizard de disponibilidad

**RF-06.2.1** — Tras elegir oposición y confirmar, si no tiene plan
configurado, se lleva al usuario al wizard (`#/wizard`) de **3 pasos**:

1. **Modo de disponibilidad**: "Horas semanales" o "Detalle por día".
2. **Disponibilidad**:
   - Semanal → slider 1–50 h/semana.
   - Diario → 7 inputs numéricos (L…D) con total en vivo.
3. **Método + ritmo**:
   - Duración de sesiones: cortas (25 min) o profundas (45 min).
   - Ritmo: relajado / normal / intensivo.

**RF-06.2.2** — El wizard **NO** pregunta por fecha del examen. La fija el
admin al gestionar la oposición (**RB-03**).

**RF-06.2.3** — Cada paso tiene:
- Cabecera con logo, indicador de progreso (3 dots) y botón "Atrás" grande.
- Botón "Cerrar sesión" siempre visible (escape de emergencia — **RP-10**).
- Botón "Continuar" al final del contenido, sin flotar sobre él.

**RF-06.2.4** — Al finalizar, se llama a `guardar_disponibilidad()` que:
1. Crea o actualiza el `plan_estudio`.
2. Regenera el plan de los próximos 14 días.
3. Redirige a Home.

### 6.3 Detección de usuarios legacy

**RF-06.3.1** — Un usuario con oposición matriculada pero sin plan de
estudio configurado (creado antes del wizard) se redirige automáticamente a
`#/wizard` al abrir cualquier vista.

**RF-06.3.2** — Excepciones (rutas siempre accesibles): `#/perfil`,
`#/administracion`, `#/admin`, `#/editar/*`.

---

## 7. Contenido

### 7.1 Estructura del catálogo

```
Oposición (fecha_examen, orientativa)
    └─ Tema (reutilizable entre oposiciones)
         └─ Unidad (teoría markdown + minutos_est)
              └─ Pregunta (enunciado + opciones + explicación + dificultad)
```

**RB-04** — Un tema pertenece al catálogo global. La relación con oposiciones
es m:n a través de `oposicion_temas` con un `orden`. Un tema puede estar en 0
o más oposiciones.

**RB-05** — Las unidades pertenecen a UN tema (belongs-to). Si el tema está
en varias oposiciones, las unidades aparecen en todas.

**RB-06** — Las preguntas pertenecen a una unidad. Se comparten igual.

### 7.2 Importación desde JSON

**RF-07.2.1** — Sólo admin. Payload JSON con la oposición completa (temas +
unidades + preguntas). El servidor:
- Reutiliza temas por `slug` — no duplica.
- Devuelve `{temas_nuevos, temas_reutilizados}`.
- Es idempotente: se puede re-importar el mismo JSON sin duplicar unidades
  ni preguntas.

### 7.3 Editor visual (admin)

**RF-07.3.1** — Ruta `#/editar/<oposicion_id>` con navegación jerárquica
(migas de pan): Admin › Oposición › Tema › Unidad › Pregunta.

**RF-07.3.2** — Panel "Datos de la oposición" (siempre visible en el nivel
raíz):
- Nombre, organismo, descripción.
- Fecha del examen + checkbox "sólo orientativa (mes/año)".
- Botón "Guardar" (usa COALESCE, sólo actualiza lo modificado).

**RF-07.3.3** — Panel "Temas": lista de temas vinculados con contador
(unidades/preguntas). Botón "+ Tema" abre modal con **dos modos**:
- **Elegir existente** (por defecto): dropdown con los temas del catálogo
  aún NO vinculados a esta oposición. Muestra "N unidades · en N
  oposiciones" al seleccionar.
- **Crear nuevo**: slug + nombre + icono. Si el slug ya existe, reutiliza.

**RF-07.3.4** — CRUD de unidades: nombre, slug, orden, minutos estimados,
resumen (opcional), teoría en Markdown.

**RF-07.3.5** — CRUD de preguntas: enunciado, opciones (radio para marcar
la correcta, mínimo 2, sin límite superior razonable), explicación
opcional, dificultad 1–5.

**RF-07.3.6** — "Quitar tema" desvincula pero NO borra el tema del catálogo.
"Borrar unidad" borra la unidad y todas sus preguntas (con confirmación).

---

## 8. Planificador

### 8.1 Modelo de datos del plan

- `plan_estudio` por (usuario, oposición): modo (semanal/diario),
  horas_semana, horas_por_dia (jsonb `{lun,mar,mie,jue,vie,sab,dom}`),
  fecha_examen (copia del catálogo), ritmo, método, sistema de estudio.
- `plan_sesiones` por día: fecha, hora_inicio (opcional), minutos, tipo,
  unidad_id, completada, completada_en, orden_global.

### 8.2 Generación

**RF-08.2.1** — `guardar_disponibilidad()` regenera el plan de los próximos
**14 días** (bloques no completados de esos días se sobreescriben).

**RF-08.2.2** — `recalcular_plan_hasta_examen()` cubre desde HOY hasta la
fecha del examen del catálogo (usar cuando el admin la fija/cambia).

**RF-08.2.3** — Distribución (v1, básica):
- Iterar unidades pendientes en orden (`oposicion_temas.orden`,
  `unidades.orden`).
- Trocearlas en bloques de 25 o 45 min según método.
- Rellenar días respetando `horas_por_dia[dow]`.
- Insertar repasos SM-2 vencidos como bloques `tipo=repaso`.

**RF-08.2.4** — Días con 0 h configuradas quedan vacíos.

### 8.3 Bloques del día

**RB-07** — Un `plan_sesiones` puede ser:
- `estudio` (unidad concreta).
- `repaso` (preguntas vencidas, sin unidad concreta).
- `test` (test rápido de una unidad).
- `descanso` (dentro del modo estudio, no cuenta en el plan real).
- `simulacro` (aún sin generador).

**RB-08** — `completada` se marca desde:
1. El modo estudio al procesar el bloque (**RP-06**).
2. La vista Unidad al alcanzar el 80% del tiempo estimado (auto-tracking).
3. Manualmente por el admin (excepcional).

### 8.4 Cambio puntual "Hoy tengo otro tiempo"

**RF-08.4.1** — Botón en la vista Plan. Modal con opciones rápidas:
`0, 15, 30, 60, 120, 180+ min`.

**RF-08.4.2** — Al elegir, `cambiar_disponibilidad_hoy(minutos)`:
- Ajusta el día de HOY al nuevo tamaño.
- Recalcula el resto de la semana para reabsorber sobrante/faltante,
  sin superar los límites diarios ORIGINALES del plan.

### 8.5 Reprogramación silenciosa

**RF-08.5.1** — Al abrir Home, la SPA llama `reprogramar_dia_perdido()` sin
avisar al usuario:
- Coge bloques NO completados de días anteriores a HOY.
- Los mete en la cola de los próximos días respetando límites.
- Devuelve cuántos se reprogramaron (para métricas, no para UI).

### 8.6 Sugerencia del lunes

**RF-08.6.1** — El primer login de cada lunes, `resumen_inicio_semana()`
puede sugerir una disponibilidad basada en las últimas 4 semanas reales del
usuario. Se muestra en un modal con inputs de horas por día editables +
botón "Aceptar y planificar".

**RF-08.6.2** — Si el usuario no acepta, la sugerencia no se aplica.

---

## 9. Modo estudio

### 9.1 Arranque

**RF-09.1.1** — Botón "Estudiar" en Home. Comportamiento:
- **Si hay bloques pendientes hoy** → `iniciar_estudio(total_minutos_pendientes)`
  → arranca directamente sin preguntar.
- **Si no hay plan / no hay bloques hoy** → abrir modal "¿Cuánto tiempo
  tienes?" con quick chips (25/45/60/90/120 min) y selector de sistema de
  estudio. Al confirmar → `iniciar_estudio(minutos, sistema_id)`.

**RF-09.1.2** — `iniciar_estudio()` construye `plan_bloques` (JSONB) con la
secuencia completa (estudio + repaso + descansos) según el sistema, y
persiste `sesion_activa`.

**RB-09** — Mínimo 10 minutos para arrancar. Menos → error
`minutos_insuficientes`.

### 9.2 Vista fullscreen

**RF-09.2.1** — Layout inmersivo (`#/estudio`):
- **Cabecera** (siempre visible): botón salir, "Bloque N/M · <tipo>",
  cronómetro compacto (44px) con mm:ss.
- **Cuerpo** (scrollable dentro): teoría / preguntas de repaso / mensaje
  de descanso, según tipo del bloque.
- **CTA** (siempre visible al pie): "Siguiente" siempre, "⏭ Saltar
  descanso" solo si el bloque es descanso.

**RF-09.2.2** — **NO** hay scroll a nivel de pantalla completa (**RP-11**).
`height: 100dvh; overflow: hidden`.

### 9.3 Cronómetro

**RF-09.3.1** — Cuenta atrás del bloque actual. Al llegar a 00:00 avanza
automáticamente al siguiente bloque.

**RF-09.3.2** — El anillo del cronómetro refleja el % transcurrido con
`stroke-dasharray` animado.

**RF-09.3.3** — El usuario puede pulsar "Siguiente" antes de que llegue a 0
para avanzar manualmente.

### 9.4 Tipos de bloque

**Bloque `estudio`**:
- Muestra la teoría de la unidad (markdown renderizado a HTML básico).
- El auto-tracking suma los segundos que el usuario esté visible.

**Bloque `repaso`**:
- Muestra hasta 5 preguntas SM-2 vencidas.
- Al responder cada una, se corrige inmediatamente (verde/rojo), se muestra
  la explicación si existe y se llama a `registrar_respuesta_espaciada`.
- Botón "Siguiente" avanza a la siguiente pregunta.

**Bloque `descanso` / `descanso_largo`**:
- Muestra emoji + texto motivador ("Toca respirar", etc.).
- Botón "⏭ Saltar descanso" visible.

**Bloque `final`**:
- Centinela al final del array. `pintarBloque` llama a `terminar()`.

### 9.5 Cierre

**RF-09.5.1** — `cerrar_estudio()` es idempotente. Se ejecuta al llegar al
bloque `final`, al pulsar "Salir con confirmación", o si el navegador
notifica `pagehide/beforeunload`.

**RF-09.5.2** — Al cerrar:
1. Marca `progreso_unidad.teoria_completada = true` para cada unidad
   procesada (bloques `estudio` con `unidad_id` < `bloque_idx`).
2. Marca `plan_sesiones.completada = true` de HOY para esas unidades.
3. Para cada bloque `repaso`/`test` procesado, marca el primer
   `plan_sesiones` pendiente de ese tipo de HOY.
4. Suma XP al `usuario_gamificacion` proporcional a minutos activos.
5. Elimina `sesion_activa`.

**RF-09.5.3** — Pantalla final: "¡Sesión completada!" + minutos totales +
XP ganada + botón "Volver al Inicio".

**RF-09.5.4** — Si tras `cerrar_estudio` un evento residual dispara
`siguiente_bloque_estudio`, el error `sin_sesion_activa` se trata como fin
de sesión silenciosamente (no toast).

---

## 10. Repetición espaciada

### 10.1 Modelo SM-2 simplificado

**RB-10** — Por cada (usuario, pregunta) se mantiene:
- `intervalo` (días).
- `ease_factor` ∈ [1.3, 3.0].
- `aciertos_seguidos`.
- `proxima_revision`.

### 10.2 Evolución

**RB-11** — Al acertar (`registrar_respuesta_espaciada(id, true)`):
- Si es el 1er acierto: `intervalo = 1`.
- Si es el 2º: `intervalo = 3`.
- Si es el 3º: `intervalo = 7`.
- Si es el 4º+: `intervalo = intervalo × ease_factor`.
- `ease_factor` sube 0.1 (tope 3.0).
- `aciertos_seguidos += 1`.
- `proxima_revision = today + intervalo`.

**RB-12** — Al fallar:
- `intervalo = 0` (repaso mismo día).
- `ease_factor` baja 0.2 (mínimo 1.3).
- `aciertos_seguidos = 0`.

### 10.3 Selección de repasos

**RF-10.3.1** — `siguientes_repasos(N)` devuelve hasta N preguntas del
usuario con `proxima_revision <= today`, priorizando las más atrasadas.

**RF-10.3.2** — El generador de bloques del modo estudio consume estas
preguntas antes de meter bloques `estudio` nuevos.

---

## 11. Progreso y auto-tracking

### 11.1 Sesiones de estudio

**RF-11.1.1** — Al entrar a la vista Unidad, se abre una `sesion_estudio` con
`sesion_abrir(unidad_id)`.

**RF-11.1.2** — Un `setInterval(30s)` hace `sesion_tick(sesion_id,
delta_seg=30)` **solo si** `document.visibilityState === 'visible'`.

**RF-11.1.3** — Al salir de la ruta / `pagehide` / `beforeunload` se llama
`sesion_cerrar(sesion_id)`.

**RF-11.1.4** — Sesiones abiertas sin actividad >15 min se auto-cierran
(barrido `sesiones_cerrar_zombies` invocado dentro de `sesion_abrir`).

### 11.2 Derivación de `teoria_completada`

**RF-11.2.1** — `refrescar_progreso_unidad()` recalcula `progreso_unidad`
para una unidad desde las sesiones cerradas:
- Suma `sum(segundos_activos)` → `minutos_estudiados`.
- Si `minutos_estudiados >= 0.8 × unidades.minutos_est` →
  `teoria_completada = true`.

### 11.3 Ranking de racha y XP

**RB-13** — `racha_actual`: nº de días consecutivos con al menos una sesión
cerrada. Se actualiza al cerrar sesión de estudio.

**RB-14** — `xp_total`: suma de todos los minutos activos. Nivel = 1 +
`floor(xp_total / 500)`.

---

## 12. Métricas y adaptación semanal

### 12.1 Snapshot semanal

**RF-12.1.1** — `calcular_metricas_semanales()` para cada usuario activo
genera una fila en `metricas_semanales` por semana ISO:

| Métrica                    | Definición                                                              |
|----------------------------|-------------------------------------------------------------------------|
| `minutos_estudiados`       | Suma de segundos_activos / 60 de todas las sesiones cerradas.           |
| `objetivos_cumplidos_pct`  | `plan_sesiones.completada / total` de la semana.                        |
| `precision_media`          | `count(correctas) / count(respuestas)` en la semana.                    |
| `fatiga_delta`             | Media de (precisión_1ª_mitad − precisión_2ª_mitad) por sesión de tests. |
| `dias_activos`             | `count(distinct fecha)` con al menos una sesión.                        |
| `tema_foco`                | Tema con la peor precisión.                                             |

### 12.2 Ajuste de carga

**RB-15** — `ajustar_carga_semanal()`:
- `objetivos_cumplidos_pct < 50%` → nuevas `horas_por_dia = actuales × 0.8`.
- `objetivos_cumplidos_pct > 90%` → `horas_por_dia = actuales × 1.15`.
- Entre 50-90% → sin cambio.

Tras el ajuste, se regenera el plan.

### 12.3 Ejecución

**RF-12.3.1** — El worker `notificador` ejecuta `cron_semanal()` los lunes a
`CRON_SEMANAL_HORA` UTC (por defecto 03:00).

**RF-12.3.2** — `cron_semanal()` corre `calcular_metricas_semanales()` +
`ajustar_carga_semanal()` para todos los usuarios activos.

### 12.4 Resumen semanal

**RF-12.4.1** — Ya no se muestra en Home (retirado por decisión de producto).
Sí forma parte de la vista Estadísticas.

**RF-12.4.2** — Mensaje motivador **según objetivos_cumplidos_pct**
(**RP-04**):
- `>75%` → "¡Semana redonda!"
- `50-75%` → "Buen ritmo. Un pequeño empujón y…"
- `20-50%` → "Semana normal. Cada bloque suma."
- `<20%` → "Hoy es un buen día para empezar de nuevo."

---

## 13. Notificaciones

### 13.1 Email

**RF-13.1.1** — Tipos:
- Verificación de email (registro).
- Reset de contraseña.

**RF-13.1.2** — Worker `mailer`:
- Cada `TICK_SECONDS` (30s por defecto) vacía hasta `BATCH_LIMIT` (25)
  filas de `cola_emails` con `enviado_en IS NULL`.
- Envío vía SMTP (Gmail app password o similar) con STARTTLS.
- Modo dev: `MAILER_DEV_LOG_ONLY=1` → log a stdout, no envía.
- Ante error: registra `ultimo_error` y reintenta en el siguiente tick.

### 13.2 Web Push

**RF-13.2.1** — VAPID para push nativo.

**RF-13.2.2** — Worker `notificador` con cron interno (tres relojes):
- Cada `TICK_SECONDS` (300s) envía `cola_push` con `enviado_en IS NULL`.
- Cada `ENCOLAR_MINUTOS` (15) llama a `encolar_notificaciones_diarias()`.
- Lunes a `CRON_SEMANAL_HORA` UTC → `cron_semanal()`.

**RF-13.2.3** — `encolar_notificaciones_diarias()`:
- Encola recordatorio si el usuario lleva >24 h sin sesión.
- Los domingos encola resumen semanal.
- Anti-ruido: si ya hay push pendiente en las últimas 20 h, no encola otra.
- Mensajes genéricos (**RP-04**), no números.

### 13.3 Preferencias del usuario

**RF-13.3.1** — Botón "Activar notificaciones" en Perfil (fallback:
`push_enviar_prueba()` desde pgAdmin). **Pendiente** en la SPA.

---

## 14. Administración

### 14.1 Vista `#/admin`

**RF-14.1.1** — Cuatro contadores en cabecera: usuarios, oposiciones, cola
email, cola push.

**RF-14.1.2** — Listado de usuarios con:
- Email + nombre + tags (roles, activo/inactivo, verificado/no verificado).
- Acciones inline: activar/desactivar, verificar email, hacer/quitar admin.

**RF-14.1.3** — Buscador con debounce 220ms sobre email/nombre.

**RF-14.1.4** — Listado de oposiciones abajo, cada una:
- Nombre (enlace a `#/editar/<id>`).
- Input date para fecha del examen + checkbox "orientativa".
- Botón "Guardar".

### 14.2 Vista `#/administracion`

**RF-14.2.1** — Import de oposición desde JSON. Textarea grande +
validación mínima (`slug` y `nombre` requeridos) + botón "Importar
oposición".

### 14.3 Vista `#/editar/<id>`

Ver [RF-07.3](#73-editor-visual-admin).

### 14.4 Gestión de usuarios

**RB-16** — Un admin puede desactivar cualquier usuario excepto a sí mismo.

**RB-17** — Un admin puede quitar el rol admin a otro admin, pero **no al
usuario `admin@aprentix.es`** (para no dejar la instalación sin admin
accesible).

**RB-18** — Verificar manualmente el email de un usuario pone
`email_verificado = true` sin enviar correo.

---

## 15. Perfil y preferencias

### 15.1 Datos personales

**RF-15.1.1** — Perfil muestra: nombre, email (indica si no verificado),
nivel, XP, racha, oposición activa, logros, entradas de preferencias.

### 15.2 Preferencias

**RF-15.2.1** — Lista de entradas:
- **Mi oposición** → `#/oposicion` (temas + unidades + fecha del examen).
- **Disponibilidad** → `#/wizard` (edición).
- **Tema** → toggle claro/oscuro/automático (persistido en cookie).

### 15.3 Sección admin (visible solo si `es_admin`)

**RF-15.3.1** — Card "🛠️ Administración" con enlaces:
- **Usuarios** → `#/admin`.
- **Oposiciones** → `#/administracion`.

### 15.4 Cerrar sesión

**RF-15.4.1** — Botón "🚪 Cerrar sesión" al final del Perfil, sin
confirmación (**RF-05.4.2**).

---

# Parte III — Requisitos no funcionales

## 16. Seguridad y privacidad

**RN-16.1** — Contraseñas hasheadas con bcrypt cost 12 (`crypt(pw,
gen_salt('bf', 12))`).

**RN-16.2** — JWT firmado HS256 por la BBDD con secreto `JWT_SECRET` (nunca
en el frontend). Caducidad 30 días.

**RN-16.3** — RLS activo en TODAS las tablas con datos de usuario. Ninguna
consulta directa (ni desde PostgREST) puede leer datos ajenos sin ser admin.

**RN-16.4** — Rate limiting por email:
- Reenvío de verificación: 1 correo cada 5 min por email.
- Reset password: 1 correo cada 15 min por email.

**RN-16.5** — Los email tokens son UUIDv4 de 128 bits, single-use.

**RN-16.6** — HTTPS obligatorio en producción (Traefik + Let's Encrypt).

**RN-16.7** — `admin_*` RPCs comprueban `es_admin()` como primera línea del
cuerpo. Cualquiera fuera de eso responde `no_autorizado`.

**RN-16.8** — Errores de auth **no** revelan si un email existe o no
(mensajes uniformes).

**RN-16.9** — No se registran datos personales en logs (email, nombre) más
allá de lo estrictamente necesario para debug de mailer/notificador.

**RN-16.10** — Ningún secreto (JWT_SECRET, DB_PASS, SMTP_PASS, VAPID keys,
RESTIC_PASSWORD) puede ir al frontend, a commits, o al README.

---

## 17. Rendimiento y disponibilidad

**RN-17.1** — Time to interactive (TTI) mobile 4G: **<3s** para Home
tras login.

**RN-17.2** — Tamaño de bundle frontend: **<200 KB** (gzipped) al ser
vanilla sin frameworks.

**RN-17.3** — Cada request a PostgREST debe responder <300ms p95 en un VPS
modesto (2 vCPU, 4GB RAM) con hasta 500 usuarios activos.

**RN-17.4** — `dashboard_inicio()` es la RPC más llamada. Debe ejecutar
con LIMIT a subconsultas caras y estar bajo 100ms p95.

**RN-17.5** — La app debe funcionar aunque el worker `mailer` esté caído
(los correos se acumulan en `cola_emails` y se envían al recuperarse).

**RN-17.6** — Aislamiento de entornos: prod y desa **no** comparten BBDD.
La red `db-net-<alias>` privada evita colisiones de DNS entre entornos.

**RN-17.7** — Al reiniciar cualquier stack, los otros no deben caerse.

---

## 18. Accesibilidad

**RN-18.1** — Contraste WCAG AA en ambos temas. Verde salvia sobre fondo
claro y verde neón sobre fondo negro cumplen 4.5:1 mínimo.

**RN-18.2** — Todos los inputs tienen `<label>` asociada. Todos los
botones-solo-icono llevan `aria-label`.

**RN-18.3** — Tamaño mínimo de target táctil: **44×44 px** (Apple/Google HIG).

**RN-18.4** — `input:not([type=checkbox])` con `min-height: 44px`.

**RN-18.5** — Focus visible: outline 3px `var(--pri)` con offset 2px.

**RN-18.6** — Los mensajes de error usan color rojo + icono, **nunca color
solo** como diferenciador.

**RN-18.7** — Modo oscuro completo activable manualmente + respeto de
`prefers-color-scheme: dark`.

---

## 19. Compatibilidad y responsive

**RN-19.1** — Compatible con las 2 últimas versiones mayores de Safari,
Chrome, Firefox, Edge (mobile y desktop).

**RN-19.2** — Diseño mobile-first. Breakpoints:
- **Móvil** (<720px): columna única, `--content-max: 480px`.
- **Móvil grande** (≥720px): `--content-max: 560px`.
- **Desktop** (≥1024px): tokens comprimidos, `--content-max: 600px`.
- **Desktop grande** (≥1440px): `--content-max: 660px`.

**RN-19.3** — En desktop, la app **no debe verse gigante**. Los tokens de
tipografía y espaciados se reducen a valores fijos (no `clamp()`).

**RN-19.4** — Todas las vistas caben sin scroll horizontal en 320px de
ancho (iPhone SE).

**RN-19.5** — Instalable como PWA (manifest + iconos + theme-color). Service
worker offline **pendiente**.

**RN-19.6** — `viewport-fit=cover` para respetar safe-areas de iOS.

---

## 20. Observabilidad, backups y recuperación

**RN-20.1** — Logs estructurados en los workers Python (`LOG_LEVEL=INFO`
por defecto). El mailer y el notificador loguean qué envían, a quién, y con
qué resultado.

**RN-20.2** — Backups diarios de la BBDD (dump completo) a `restic` con
repositorio en Google Drive vía `rclone`. Retención: últimos N snapshots
(por defecto 2).

**RN-20.3** — El script `deploy/init-networks.sh` es idempotente y crea las
redes privadas por entorno.

**RN-20.4** — El esquema SQL es re-lanzable en cualquier estado de la BBDD
(idempotencia).

**RN-20.5** — Restauración probada: el `README.md` de backups debe permitir
recuperar la BBDD en <30 min desde un snapshot.

---

# Parte IV — Interfaz (specs de comportamiento)

## 21. Estructura general

### 21.1 Contenedor de app

**UX-21.1** — Todas las vistas se montan en un `<div id="app">` con
`max-width: var(--content-max)` centrado horizontalmente.

**UX-21.2** — La navegación entre vistas ocurre por hash (`location.hash =
'#/vista'`). No se recarga la página.

**UX-21.3** — La transición entre vistas usa fade-in de 0.18s.

### 21.2 Top-bar

**UX-21.4** — Presente en Home, Plan, Estadísticas, Perfil, Oposición,
Admin, Administración, Editor, Onboarding. Estructura:
`[brand-mini] [chip nivel] [chip racha] [avatar]`.

**UX-21.5** — `position: sticky; top: 0` para que quede siempre visible
al scrollear (**RP-12**).

**UX-21.6** — El logo del zorrito (44px) se ve entero, sin recortes, sin
fondo (`object-fit: contain`).

### 21.3 Bottom-nav

**UX-21.7** — Fija abajo (fixed), 4 tabs: Inicio, Plan, Estadísticas,
Perfil. Iconos con `stroke-width: 2` excepto Estadísticas que usa
rectángulos rellenos con esquinas redondeadas (más gruesos y legibles).

**UX-21.8** — Se **oculta** en las siguientes vistas (para foco máximo):
- Auth, verify, reset.
- Onboarding, wizard.
- Unidad, admin, administración, editar, oposición.
- Modo estudio.

### 21.4 Toast

**UX-21.9** — Notificaciones efímeras de 3.5s en la parte inferior, sobre
el bottom-nav. Sin acción; sólo informativos.

---

## 22. Vista Home

**UX-22.1** — Contenido (de arriba a abajo):
1. Top-bar.
2. Chip "Estudiando <Oposición>" clickable (abre modal de oposiciones).
3. Hero corto: "Hola, <nombre>" + subtítulo motivador.
4. Botón grande "Estudiar" con subtítulo dinámico.
5. Card "Plan de hoy" compacta: barra "X de N bloques hechos", primeros 4
   bloques con estado (⏱ o ✅), enlace "Ver los N restantes" si hay más.

**UX-22.2** — Subtítulo del botón "Estudiar":
- Sin plan → "Modo estudio guiado con cronómetro".
- Con plan pero todo hecho → "¡Plan de hoy completo! Sesión libre.".
- Con plan pendiente → "N bloques pendientes".

**UX-22.3** — Modal de oposiciones (al pulsar el chip):
- Lista de oposiciones matriculadas con la activa marcada.
- Click en otra oposición → llama `matricular_oposicion(id, principal=true)`,
  cierra modal, recarga Home.
- Botón "➕ Añadir otra oposición" → va a `#/onboarding`.

**UX-22.4** — Empty state del plan de hoy:
- Emoji + "Aún no tienes plan para hoy." + botón "Configurar disponibilidad"
  que va al wizard.

**UX-22.5** — NO mostrar el resumen semanal aquí (por decisión de producto).

---

## 23. Vista Plan

**UX-23.1** — Contenido:
1. Top-bar.
2. Hero con pill "Hoy" y "Tu plan".
3. Week-strip (L-D con día seleccionado destacado).
4. Card "Plan de hoy": lista de bloques con estado, barra "Completado hoy".
5. Card "Próximo hito" clickable → `#/oposicion`.
6. Botones: "✏️ Editar mi disponibilidad" + "⏱ Hoy tengo otro tiempo".

**UX-23.2** — Cada bloque del día muestra:
- Icono según tipo.
- Hora (si hay) + tema. Sin hora → sólo tema (**no** guión "—").
- Si `tema === unidad`, no duplicar el nombre.
- Minutos + status (⏱ pendiente / ✅ completado).

**UX-23.3** — Empty state cuando no hay bloques ese día:
`.empty-state` con emoji + "No hay bloques planificados para este día." +
botón "Ajustar disponibilidad".

---

## 24. Vista Estadísticas

**UX-24.1** — Contenido:
1. Top-bar.
2. Hero "Estadísticas".
3. Tiles con racha, tiempo semana, precisión.
4. Card "Actividad semanal" con chart de barras 7 días.
5. Card "Progreso total" con anillo SVG + texto "N de M unidades".
6. Card "Rendimiento por materia" (top 6 temas).

**UX-24.2** — Empty state del ranking: `.empty-state` con emoji + "Aún no
hay resultados. Completa algunos tests para ver este ranking."

---

## 25. Vista Perfil

**UX-25.1** — Contenido:
1. Perfil hero (logo grande + nombre + email + chip nivel).
2. Tiles con racha, XP, progreso.
3. Card "Tu objetivo" con la oposición activa y días hasta examen.
4. Card "Logros".
5. Card "Preferencias" (Mi oposición, Disponibilidad, Tema).
6. Card "Administración" (sólo si es admin).
7. Botón "🚪 Cerrar sesión".

**UX-25.2** — El toggle de tema (claro/oscuro) actualiza inmediatamente y
persiste en cookie `aprentix_theme`.

---

## 26. Vista Mi Oposición

**UX-26.1** — Contenido:
1. Top-bar.
2. Hero con pill "Mi oposición" y nombre.
3. Card "Fecha del examen":
   - Con fecha real → fecha formateada + "En N días".
   - Con fecha orientativa → fecha + "Fecha orientativa · en ~N días".
   - Sin fecha → "Sin confirmar" + estimación al ritmo actual del usuario
     (mes/año calculado dividiendo unidades pendientes por horas/semana).
4. Card "Temas y unidades": listado colapsable de temas con sus unidades.
   Click en una unidad → `#/unidad/<id>`.

**UX-26.2** — Empty state cuando la oposición no tiene temas: `.empty-state`
con emoji.

---

## 27. Vista Unidad

**UX-27.1** — Contenido:
1. Cabecera con "‹ Atrás", nombre del tema (pequeño), nombre de la
   unidad, chip minutos.
2. Barra de progreso de la unidad.
3. Card "Teoría" con markdown renderizado.
4. Card "¿Hacemos un test rápido?" con CTA "Comenzar" (si hay preguntas).
5. Card "Test" (aparece tras pulsar Comenzar): progreso, enunciado,
   opciones, explicación, botones.

**UX-27.2** — Auto-tracking activo (ver **RF-11**).

**UX-27.3** — Al completar el 80% del tiempo estimado, la unidad se marca
automáticamente como leída.

---

## 28. Vista Modo Estudio

**UX-28.1** — Layout `height: 100dvh; overflow: hidden` en 3 filas
(flex column):
- **Cabecera** compacta (~64px): salir + meta + cronómetro pequeño.
- **Cuerpo** (`flex: 1; overflow-y: auto`): contenido del bloque, scrollea
  dentro de sí mismo.
- **CTA** (fixed): "Siguiente" siempre, "Saltar descanso" en descansos.

**UX-28.2** — Nunca hay scroll de página completa (**RP-11**).

**UX-28.3** — Cronómetro compacto: chip con anillo SVG (44px) + mm:ss + "de
N min". Cambia de color según % transcurrido.

**UX-28.4** — Salir con confirmación: "¿Terminar la sesión ahora?".

**UX-28.5** — Pantalla final: "¡Sesión completada!" + estadísticas + botón
"Volver al Inicio" (que reemplaza al de "Siguiente", limpio de listeners
anteriores).

---

## 29. Wizard de disponibilidad

**UX-29.1** — Cabecera propia (`.wizard-head`) con:
- `brand-mini` a la izquierda.
- Indicador de progreso (3 puntos) en el centro.
- Botón "‹ Atrás" pill grande a la derecha.

**UX-29.2** — Fila `.wizard-escape` con "⏻ Cerrar sesión" (**RP-10**).

**UX-29.3** — El botón "Continuar" **NO** es sticky: fluye al final del
paso para adaptarse a cualquier alto de pantalla sin cortar el contenido.

**UX-29.4** — Al abrir el wizard y en cada `showStep`, `window.scrollTo(0,
0)` para que el logo y la cabecera siempre queden visibles.

**UX-29.5** — El paso 3 **NO** contiene ningún campo de fecha ni mención al
examen (**RB-03**).

---

## 30. Vistas de admin

### 30.1 `#/admin`

Ver [RF-14.1](#141-vista-admin).

### 30.2 `#/administracion`

Ver [RF-14.2](#142-vista-administracion).

### 30.3 `#/editar/<id>`

Ver [RF-14.3](#143-vista-editar-id) / [RF-07.3](#73-editor-visual-admin).

---

# Parte V — Contratos

## 31. Modelo conceptual del dominio

Diagrama de entidades desde el punto de vista de negocio (no de BBDD):

```
                                           ┌──────────────┐
                                           │    ADMIN     │
                                           └──────┬───────┘
                                                  │ gestiona
                                                  ▼
┌──────────┐  matricula   ┌────────────┐ tiene ┌────────┐ contiene ┌─────────┐
│ USUARIO  ├──────────────► OPOSICIÓN  ├───────► TEMA   ├──────────► UNIDAD  │
└─────┬────┘   como       └─────┬──────┘  m:n  └────┬───┘ 1:n      └────┬────┘
      │        principal        │                    │                   │
      │                         │ tiene              │                   │ contiene
      │ tiene                   │ fecha              │                   ▼
      ▼                         │ examen             │                ┌───────────┐
┌──────────┐  consta de  ┌──────▼──────┐             │                │ PREGUNTA  │
│  PLAN    ├─────────────►  BLOQUE     │             │                └───────────┘
└─────┬────┘   diario    │  (día/hora) │             │
      │                  └──────┬──────┘             │
      │                         │                    │
      │                         │ apunta a           │
      │                         └──────► UNIDAD ◄────┘
      │
      │ genera
      ▼
┌──────────────┐         ┌──────────────┐        ┌──────────────┐
│ SESIÓN       │         │ REPASOS      │        │ MÉTRICAS     │
│ DE ESTUDIO   │         │ PREGUNTA     │        │ SEMANALES    │
└──────────────┘         │ (SM-2 estado)│        └──────────────┘
                         └──────────────┘
```

**Invariantes**:
- Un USUARIO puede tener 0..N OPOSICIONES matriculadas, exactamente 1 marcada como principal.
- Un TEMA existe independientemente de las OPOSICIONES (catálogo global).
- Una UNIDAD pertenece a exactamente 1 TEMA.
- Una PREGUNTA pertenece a exactamente 1 UNIDAD.
- Un PLAN existe por (USUARIO, OPOSICIÓN).
- Un BLOQUE del plan puede apuntar a 0..1 UNIDAD.
- Los REPASOS PREGUNTA son 1 por (USUARIO, PREGUNTA).

## 32. Contratos de API (comportamiento)

Cada RPC del backend documentada con precondiciones, postcondiciones y
efectos secundarios. La signatura exacta y las firmas técnicas viven en
`db/init/01_esquema.sql`.

### 32.1 Auth

**`registrar_web(email, password, nombre)`**
- Pre: email no existe, password fuerza >=2.
- Post: crea `usuarios` con `email_verificado=false`.
- Efectos: encola email de verificación.
- Errores: `email_registrado`, `password_debil`, `email_invalido`.

**`login_web(email, password)`**
- Pre: cuenta existe, activa, verificada, password correcto.
- Post: devuelve `{token, ...}`.
- Errores: `credenciales_invalidas`, `email_no_verificado`, `usuario_inactivo`.

**`mi_sesion()`**
- Pre: JWT válido.
- Post: `{user_id, email, nombre, email_verificado, roles, es_admin, principal}`.
- Devuelve `null` si el `user_id` del JWT no existe (JWT huérfano) — el
  cliente debe interpretarlo como logout.

### 32.2 Contenido

**`obtener_oposicion(oposicion_id)`**
- Post: `{id, slug, nombre, organismo, descripcion, fecha_examen,
  fecha_examen_orientativa, temas: [{id, nombre, icono, orden,
  num_unidades, unidades: [{id, nombre, orden, minutos_est, num_preguntas}]}]}`.
- Usado por la vista Mi Oposición.

### 32.3 Planificador

**`guardar_disponibilidad(oposicion_id, modo, horas_semana?,
horas_por_dia?, fecha_examen?, ritmo, metodo)`**
- Pre: oposición matriculada por el usuario.
- Post: crea o actualiza `plan_estudio` y regenera 14 días de plan.
- Nota: `fecha_examen` es tolerada por compatibilidad pero **no debe usarse**
  desde el wizard (**RB-03**).

**`cambiar_disponibilidad_hoy(minutos)`**
- Post: recalcula bloques de hoy y redistribuye resto de la semana.

### 32.4 Modo estudio

**`iniciar_estudio(minutos_total, sistema_id?)`**
- Pre: `minutos_total >= 10`.
- Post: crea `sesion_activa` con `plan_bloques` generados.
- Efectos: borra cualquier `sesion_activa` previa del usuario.

**`siguiente_bloque_estudio()`**
- Pre: existe `sesion_activa` para el usuario.
- Post: incrementa `bloque_idx`, devuelve el bloque nuevo o `{tipo:
  'final'}` si no hay más.
- Error: `sin_sesion_activa` si no hay sesión.

**`cerrar_estudio()`**
- Idempotente (si no hay sesión activa, no-op).
- Post: marca `plan_sesiones.completada = true` y
  `progreso_unidad.teoria_completada = true` para todos los bloques
  procesados. Suma XP. Elimina `sesion_activa`.
- Devuelve: `{ok, minutos_totales, bloques_completados, plan_actualizados}`.

### 32.5 Admin

**`admin_listar_usuarios(query?, limit?)`**
- Pre: `es_admin()`.
- Post: array de usuarios paginado con roles y oposiciones.

**`admin_temas_disponibles(oposicion_id)`**
- Pre: `es_admin()`.
- Post: temas del catálogo NO vinculados a esta oposición (para reutilizar).

**`admin_vincular_tema(oposicion_id, tema_id, orden?)`**
- Pre: `es_admin()`.
- Post: vincula (idempotente). Devuelve `{ok, orden}`.

---

# Parte VI — Estado y roadmap

## 33. Estado actual

### Completo ✅

- Auth completa (registro, verificación, login, reset, JWT).
- Onboarding con reutilización de oposiciones.
- Wizard de disponibilidad multi-paso (sin fecha del examen).
- Contenido con temas reutilizables entre oposiciones.
- Importación JSON de oposiciones.
- Editor visual (datos generales + temas con reutilización + unidades + preguntas).
- Motor de plan (14 días).
- Modo estudio con cronómetro compacto, avance auto, cierre marca bloques.
- SM-2 simplificado con `siguientes_repasos`.
- Auto-tracking del tiempo real de estudio.
- Sistemas de estudio (Pomodoro, Ultradiano, Bloques 45, Sprints).
- Métricas semanales + ajuste de carga.
- Mailer SMTP (con modo dev).
- Notificador Web Push con cron interno.
- Admin (usuarios + fecha del examen por oposición).
- Vista "Mi oposición" con temas colapsables + fecha (real o estimada).
- Backups nocturnos con restic + rclone → GDrive.
- Coexistencia prod + desa con red privada por entorno.

### En beta 🌱

- Motor de plan: reparto por horas sin heurística de dificultad.
- Retos: catálogo semillado, sin motor que incremente `progreso`.
- Simulacros: tipo existe, sin generador N-al-azar con cronómetro.
- Web Push: infraestructura completa, sin botón "Activar" en SPA.

### Pendiente 🚧

- Simulacro mensual automático.
- Estadísticas por unidad/tema con desglose de tiempo.
- Recordatorios push programados por franjas horarias.
- Import/export CSV de preguntas.
- PWA offline real (service worker).
- Sesiones multi-dispositivo / revocación de tokens.
- Métricas de admin en tiempo real.

## 34. Roadmap priorizado

**P0 (bloqueantes UX)**:
- Botón "Activar notificaciones" en Perfil.
- Estadísticas por unidad/tema (desglose de tiempo y aciertos).

**P1 (mejora comportamiento)**:
- Simulacro mensual con generador N-al-azar.
- Motor de plan con heurística de dificultad (poner las difíciles al
  principio de la semana o cuando la energía sea alta).
- Retos con motor que incrementa progreso tras `finalizar_intento`.

**P2 (crecimiento)**:
- Import/export CSV de preguntas.
- Recordatorios push por franjas horarias.
- Compartir progreso con un tutor (rol nuevo).

**P3 (infraestructura)**:
- PWA offline real (1-2 días).
- Sesiones multi-dispositivo con revocación.
- Métricas de admin en tiempo real.

---

# Apéndices

## A. Implementación técnica actual

### A.1 Arquitectura

```
              ┌──────────────────────────────────────────────────────┐
              │                     dokploy-network                  │
              │  ┌─────────┐  ┌────────────┐  ┌─────────┐            │
   Internet ──┼──│ Traefik │──│    app     │  │ pgadmin │            │
              │  └─────────┘  │   (Caddy)  │  └────┬────┘            │
              │       │       └────────────┘       │                 │
              │       │              │  /api/*     │                 │
              │       │              ▼             │                 │
              │       │       ┌─────────────┐      │                 │
              │       └───────│  postgrest  │      │                 │
              │               └──────┬──────┘      │                 │
              └──────────────────────┼─────────────┼─────────────────┘
                                     │             │
              ┌──────────────────────┼─────────────┼─────────────────┐
              │                  db-net-<alias>   (privada)          │
              │              ┌───────▼─────────────▼───────┐         │
              │              │      Postgres 16 (db)       │         │
              │              └───┬──────────────┬──────────┘         │
              │        ┌─────────▼──────┐  ┌────▼───────┐            │
              │        │   mailer       │  │ notificador│            │
              │        └────────────────┘  └────────────┘            │
              │                  ┌────────▼────────┐                 │
              │                  │    backups      │  → GDrive       │
              │                  └─────────────────┘                 │
              └──────────────────────────────────────────────────────┘
```

### A.2 Stack

| Capa            | Componente                     | Notas                                      |
|-----------------|--------------------------------|--------------------------------------------|
| BBDD            | PostgreSQL 16                  | pgcrypto + pg_trgm. Sin pgjwt.             |
| API             | PostgREST 12.2.3               | JWT HS256 firmado en la BBDD.              |
| Frontend        | SPA vanilla ES2020             | Router hash-based, sin bundler.            |
| Web             | Caddy 2                        | Sirve `web/`, proxya `/api/*`.             |
| Workers         | Python 3.12 + psycopg 3        | `mailer` (SMTP), `notificador` (Web Push). |
| Backups         | restic + rclone                | Google Drive.                              |
| Orquestación    | Docker Compose 2.20 / Dokploy  | `include:` fusiona los 4 stacks.           |
| Reverse proxy   | Traefik v3.5 + Let's Encrypt   | Routers `${DB_ALIAS:+-${DB_ALIAS}}`.       |

### A.3 Redes

- `dokploy-network` (external): HTTP.
- `db-net-<alias>` (external, `deploy/init-networks.sh`): BBDD y workers,
  privada por entorno.

### A.4 Migraciones

- `db/init/01_esquema.sql` — schema completo, idempotente, sólo se ejecuta
  al inicializar un volumen vacío.
- `db/migrations/*.sql` — incrementales para BBDD existentes. Terminan con
  `NOTIFY pgrst, 'reload schema'`.

### A.5 Coexistencia prod + desa

`DB_ALIAS` distingue los stacks:

| Entorno | DB_ALIAS | Container / alias                                     |
|---------|----------|-------------------------------------------------------|
| Prod    | *(vacío)*| `db`, `postgrest`, `app`, `mailer`, `notificador`     |
| Desa    | `desa`   | `db-desa`, `postgrest-desa`, `app-desa`, ...          |

El service key del compose de core es `postgres` (no `db`) para que el
alias implícito de Compose no colisione entre entornos.

---

## B. Convenciones de código

### B.1 Git

- Rama de desarrollo: `claude/redesign-oposiciones-9bdwaq`.
- Commits en español, primera línea ≤72 caracteres.
- Footer obligatorio:
  ```
  Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
  Claude-Session: <url>
  ```

### B.2 SQL

- Idempotencia obligatoria: `CREATE OR REPLACE`, `IF NOT EXISTS`, `DROP
  POLICY IF EXISTS` + `CREATE POLICY`.
- Dollar-quotes etiquetados cuando anidan: `$html$…$html$`.
- `NOTIFY pgrst, 'reload schema'` al final de cada migración.
- `GRANT EXECUTE ON FUNCTION ...` centralizado en el `DO $grant_exec$` del
  init.

### B.3 JavaScript

- Vanilla ES2020. Sin bundler ni framework.
- `$(sel, root)` / `$$(sel, root)` como shortcuts de query.
- Router hash-based, hooks `hashchange` + `load`.
- Estado global en `state = { session, oposiciones, principalId,
  planCargado, tienePlan }`.
- RPC vía `S.rpc(nombre, params, { api: '/api' })`.
- Defensivo: `data = data || {}` para tolerar bodies `null`.

### B.4 CSS

- Mobile-first, `clamp(...)`.
- Media queries en 720px, 1024px, 1440px.
- `--content-max` para todas las vistas.
- Modo estudio: `height: 100dvh; overflow: hidden` con hijos flex.

---

## C. Referencias del repositorio

- **`README.md`** — introducción rápida.
- **`DESPLIEGUE.md`** — detalles operativos y troubleshooting.
- **`SPECS.md`** — este documento.
- **`db/init/01_esquema.sql`** — implementación del schema.
- **`db/migrations/*.sql`** — migraciones incrementales.
- **`db/ejemplo_oposicion.json`** — payload de referencia.
- **`web/`** — SPA (index + style + tokens + session + app).
- **`mailer/`** — worker SMTP.
- **`notificador/`** — worker Web Push con cron interno.
- **`deploy/`** — un stack por carpeta.
- **`deploy/init-networks.sh`** — crea `db-net-prod` y `db-net-desa`.
- **`pgadmin/servers.json`** — pre-registro para pgAdmin.

---

*Última revisión — reset de estructura como documento spec-first.*
*Cualquier cambio del comportamiento del producto empieza aquí.*
