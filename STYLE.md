# Manifiesto de estilo — Aprentix

> Guía visual para maquetadores. Todo lo que se pinta en la app debe encajar
> aquí. Si algo no encaja, cambia el token o revisa el estilo antes de
> añadir estilos "sueltos" a la tarjeta o al botón.

Aprentix es una app de estudio para gente que se prepara oposiciones. Su
promesa emocional es **enfocarse sin agobio**. Todo el estilo se construye
sobre dos ideas:

- **Solarpunk** — naturaleza optimista, luz cálida, colores vegetales,
  formas orgánicas. Un invernadero soleado (día) o un bosque
  bioluminiscente (noche). Nada de neones estridentes ni corporativo frío.
- **Glassmorphism relajante** — superficies traslúcidas con desenfoque
  suave. La UI "flota" sobre el fondo ambiental sin taparlo. Bordes
  suaves, sombras cálidas, contraste alto pero sin negros puros ni
  blancos clínicos.

Nunca hay un cambio de color brusco al pulsar algo. Los estados
(hover, activo, error, éxito) se resuelven **subiendo o bajando la
intensidad del mismo tono** o pasando a un color hermano de la paleta,
no metiendo un color nuevo.

---

## 1 · Paleta

Toda la paleta vive en `web/shared/tokens.css`. Nunca escribas colores
literales en un CSS de vista — usa la variable. Si un color que necesitas
no está, añade el token, no lo hardcodees.

### Paleta día — "Un día soleado en el invernadero"

Marfil luminoso con toques de miel, coral melocotón, verde salvia,
cielo turquesa y lavanda glicinia. La sensación es de luz cálida entrando
por una cristalera con plantas.

| Rol                     | Token             | Valor      | Uso                                             |
|-------------------------|-------------------|------------|-------------------------------------------------|
| Primario / acción       | `--pri`           | `#6B8E23`  | Botones principales, foco, barra de progreso.   |
| Primario oscuro         | `--pri-d`         | `#4E6B1F`  | Texto sobre marfil, hover del primario.         |
| Primario pálido         | `--pri-light`     | `#E6F0CE`  | Fondo suave "acción secundaria".                |
| Acento — sol            | `--accent`        | `#F4B740`  | XP, hitos, highlight de "esto es importante".   |
| Acento oscuro           | `--accent-d`      | `#D6941F`  | Hover del acento.                               |
| Coral — amanecer        | `--coral`         | `#F27E62`  | Retos, cuenta atrás, "algo pide tu atención".   |
| Cielo turquesa          | `--sky`           | `#7FBEC6`  | Chips informativos, agrupadores neutros.        |
| Lavanda glicinia        | `--lavender`      | `#B79BD9`  | Descanso, categorías "soft", tag lore.          |
| Verde lima hoja         | `--leaf`          | `#9BC53D`  | Progreso completado, éxito puntual.             |
| Peligro — terracota     | `--danger`        | `#C0533E`  | Errores, borrar, desactivar. Nunca en flat rojo.|
| Éxito — musgo           | `--success`       | `#6B8E23`  | Igual que el primario (coherencia).             |

Superficies:

| Token          | Uso                                                       |
|----------------|-----------------------------------------------------------|
| `--bg`         | Fondo global (marfil luminoso).                           |
| `--bg-soft`    | Bandas alternas, filtros, seg-groups.                     |
| `--bg-panel`   | Tarjetas elevadas (casi blanco tirando a marfil).         |
| `--bg-alt`     | Hover neutro / secundario dentro de una tarjeta.          |
| `--border`     | Borde suave verde claro. Nunca `#ccc`, nunca `#e5e5e5`.   |

Fondo ambiental: `--bg-ambient` es una capa de radiales de ámbar,
turquesa, coral, lima y lavanda. Se aplica en `body` con
`background-image: var(--bg-ambient); background-attachment: fixed`.
Sin esta capa la app se ve gris — recuerda pintarla en cualquier
`<body>` nuevo.

### Paleta noche — "Bosque bioluminiscente"

Verde pino profundo con luces LED de bajo consumo: cian aguamarina,
amarillo luciérnaga, magenta de setas, verde neón musgo. Se activa
con `[data-theme="dark"]`.

| Rol                | Token          | Valor      |
|--------------------|----------------|------------|
| Primario cian      | `--pri`        | `#5CE5D5`  |
| Amarillo luciérnaga| `--accent`     | `#F4D03F`  |
| Coral bioluminis.  | `--coral`      | `#FF9B85`  |
| Turquesa neón agua | `--sky`        | `#6FD3E8`  |
| Púrpura setas      | `--lavender`   | `#B084F5`  |
| Verde neón musgo   | `--leaf`       | `#9CE87B`  |
| Fondo pino         | `--bg`         | `#101E1A`  |
| Panel hoja sombra  | `--bg-panel`   | `#1D3126`  |

Todo componente que pinte fondo blanco o color literal en modo día
tiene que pintar `var(--bg-panel)` en dark. Si ves fondo blanco en
modo noche, es un bug — el fallback correcto es siempre `var(--bg-panel)`.

### Glassmorphism

Solo para superficies flotantes (modales, barra ambiental, chips
elevados sobre el fondo ambiental). Reglas:

- Fondo `var(--glass-bg)` (semi-transparente marfil / bosque).
- Borde `1px solid var(--glass-border)`.
- Desenfoque `backdrop-filter: blur(var(--glass-blur)) saturate(140%)`.
- Radio orgánico: `var(--radius)` o mayor.
- No usar sobre superficies planas ya elevadas — se convierte en ruido.

Utilidad ya definida: la clase `.glass` de `shared/base.css`.

---

## 2 · Formas y sombras

Nada tiene esquinas de 4 px. La app usa radios orgánicos:

- `--radius-sm: 10px` — chips, badges, inputs pequeños.
- `--radius: 16px`    — botones, inputs, tarjetas normales.
- `--radius-lg: 22px` — modales, tarjetas destacadas.
- `--radius-xl: 28px` — hero de bienvenida.

Sombras cálidas con matiz miel de día, halo bioluminiscente sutil de
noche. Usa siempre los tokens `--shadow-sm / --shadow / --shadow-md /
--shadow-lg`, nunca `box-shadow: 0 2px 4px rgba(0,0,0,.1)` literal.

---

## 3 · Tipografía

- `system-ui, -apple-system, "Segoe UI", Roboto, sans-serif`.
- Base 17 px, line-height 1.6 (accesibilidad).
- Texto principal `var(--txt)`, secundario `var(--txt-soft)`.
- Nunca `#000` ni `#333`. El "negro" de Aprentix es `--txt` (verde
  tierra oscuro en día, marfil verdoso en noche).

Jerarquía tipográfica de una vista:

1. Título de vista dentro de `.view-head h2` — 1.5 rem, peso 700.
2. Título de sección dentro de una tarjeta — `.card-title`, 1.05 rem, 700.
3. Subtítulo / ayuda — `.card-subtitle`, 0.9 rem, `--txt-soft`.
4. Cuerpo — 1 rem, `--txt`.
5. Meta / micro — 0.82 rem, `--txt-soft`.

---

## 4 · Botones — cómo elegir sin salir del estilo

Todos los botones parten de `.btn` (46 px de alto mínimo, radio 16 px,
peso 600). La **variante** elige el color, no la forma. Nunca inventes
una variante nueva.

### Cuándo usar cada variante

| Variante              | Cuándo                                                      | Ejemplo                        |
|-----------------------|-------------------------------------------------------------|--------------------------------|
| `.btn-primary` / `.btn-pri` | Acción principal de la vista, una sola por pantalla.   | "Guardar", "Crear", "Repasar". |
| `.btn-sec`            | Acción secundaria positiva, coherente con la primaria.      | "Vincular tema existente".     |
| Bare `.btn`           | Acción neutra recurrente en listas (editar, abrir, etc.).   | "Abrir", "Editar" en `.list-item`. |
| `.btn-accent`         | Llamada aspiracional / hito, no técnica.                    | "Reclamar XP", "Ver logro".    |
| `.btn-ghost`          | Acción reversible sobre fondo cargado (dentro de un modal). | "Volver", cerrar overlay.      |
| `.btn-cancel`         | Descartar sin destruir (cerrar formularios).                | "Cancelar" en modales.         |
| `.btn-danger`         | Destruir de verdad y sin diálogo posterior.                 | Poco usado; casi siempre `-outline`. |
| `.btn-danger-outline` | Destruir con confirmación posterior.                        | "Borrar", "Desactivar".        |
| `.btn-sm`             | Modificador de tamaño para acciones en listas / toolbars.   | Combina con cualquier variante. |

Reglas:

- **Una sola primaria por vista.** Si hay dos, una de las dos no es
  realmente la principal — hazla `.btn` o `.btn-sec`.
- **Nunca fondo gris "de sistema".** Un `<button>` sin variante hereda
  el gris del navegador y rompe el estilo. Siempre pon una variante.
- **Cancelar no es gris.** Usa `.btn-cancel` (o `.btn-ghost` dentro de
  un modal). Ambos son lavanda / marfil traslúcido — nunca gris plano.
- **Editar / Abrir / Ver** en filas de lista van con `.btn` bare
  (ahora tinte salvia suave), no con `.btn-primary` — reservada para la
  acción principal de la vista.
- **Borrar** siempre `.btn-danger-outline` + confirmación. `.btn-danger`
  sólido sólo en modales de confirmación.

### Estados

- Hover: sube ligeramente la intensidad del mismo tono. Nunca cambia el
  hue. Puedes añadir `box-shadow` más profunda del token.
- Active: `translateY(1px)` (viene por defecto de `.btn`).
- Disabled: `opacity: 0.5`, sin sombra.
- Focus: **siempre** anillo `outline: 3px solid var(--pri); outline-offset: 2px`
  (viene por `:focus-visible` global). No lo desactives.

---

## 5 · Resaltar zonas sin impacto visual negativo

El principio: nunca metas un bloque de color plano. Para destacar,
apila estas técnicas en este orden:

1. **Elevación** — sube la superficie a `--bg-panel`, añade `--shadow-sm`.
2. **Borde tintado** — usa `border: 1px solid var(--pri-soft)` o
   `--accent-soft`. Nunca borde negro.
3. **Franja lateral** — 3–4 px de `border-left` en el color del tema
   (éxito, aviso, reto). Ver `.logro-notif`, `.explicacion`.
4. **Fondo suave** — sólo las variantes `-soft` de la paleta
   (`--pri-soft`, `--accent-soft`, `--coral-soft`, `--lavender-soft`,
   `--sky-soft`). Todas están calibradas a ~16 % de opacidad.
5. **Chip informativo** — `.kv-badge` o `.role-chip` para etiquetas
   inline; nunca uses un `<div>` con `background-color: red`.

Zonas con semántica ya asignada:

| Semántica        | Color de acento    | Ejemplo                              |
|------------------|--------------------|--------------------------------------|
| Estudio / progreso | `--pri` / `--leaf` | Barra de progreso, secciones completadas. |
| XP / hito        | `--accent` (ámbar) | Notificación de logro clásico.       |
| Reto / urgencia  | `--coral`          | Notificación de reto, cuenta atrás.  |
| Info / navegación| `--sky`            | Chips de módulo, enlaces informativos.|
| Descanso / meta  | `--lavender`       | Cancel, categorías "soft".           |
| Peligro          | `--danger`         | Borrar, desactivar, zona peligro.    |
| Éxito puntual    | `--success`        | Verificado, aprobado, badges "ok".   |

Si necesitas diferenciar dos elementos que compiten por atención,
cambia de familia (uno primario, otro acento) antes que subir el brillo
de ambos. Dos primarios juntos anulan la jerarquía.

---

## 6 · Enlaces y migas de pan (breadcrumbs)

Prohibido el `<a>` azul subrayado del navegador. Cualquier enlace en la
UI se pinta con el color del texto o de la marca.

- **Enlace en texto largo** — color `var(--pri-d)`, sin subrayado por
  defecto, subrayado sólo en `:hover`.
- **Migas de pan** — chips con hoja suave, separador con carácter
  ornamental (`›`), el crumb activo va en verde tierra `var(--txt)` con
  peso 700 y sin fondo. Ver `.admin-crumbs` en `estudio/style.css`.
- **Tabs de admin** — pill activo verde salvia, resto marfil con
  borde suave. Nunca subrayado.

---

## 7 · Inputs y formularios

Todo formulario dentro de una tarjeta usa `.form-grid`:

- Label pequeño (0.82 rem, `--txt-soft`, peso 700).
- Input alto (46 px), radio 16 px, borde `--border`, fondo `--bg-panel`.
- Focus: borde `--pri` + halo `--pri-glow`.
- Textarea vertical-resizable, mínimo 5.5 rem.

**Number inputs**: los "spinners" nativos son grises y feos. Se
sustituyen por flechas custom que respetan la paleta (ver
`estudio/style.css > input[type=number]`). Nunca los ocultes: son la
manera accesible de cambiar el valor con teclado o táctil.

Radios / checkboxes / switches: usa `accent-color: var(--pri)`. Nunca
metas un CSS que dibuje un cuadrado azul del sistema.

---

## 8 · Feedback (toast, badges, notificaciones)

- **Toast** — 1 sola línea, pill con fondo `--accent` en día y borde
  bioluminiscente en noche. Aparece 2.5 s abajo-centro, no interrumpe.
- **Badges** — `.kv-badge`, `.kv-badge.ok`, `.kv-badge.warn`,
  `.kv-badge.danger`. Píldora, 0.78 rem.
- **Notificaciones de logro** — arriba, con icono grande y barra de XP
  que se rellena. Reto = variante coral (`.es-reto`). Ver `.logro-notif`.

---

## 9 · Modo oscuro

- El interruptor pinta `data-theme="dark"` en `<html>`.
- Cualquier CSS con fondo blanco o color literal se rompe en dark.
  Norma: sustituye `#fff` por `var(--bg-panel)` y `#f6f6f6` por
  `var(--bg-alt)`. Todo componente tiene que probarse en ambos temas
  antes de darse por hecho.
- Los botones primarios en dark pintan texto **oscuro** (`#14241D`),
  porque el fondo `--pri` es cian brillante.

---

## 10 · Checklist antes de mergear una vista

- [ ] Ningún `color:` ni `background:` con literal — todo por token.
- [ ] Todos los botones tienen variante explícita (nada gris).
- [ ] Botón "Cancelar" no es gris — `.btn-cancel` o `.btn-ghost`.
- [ ] Enlaces no salen azules subrayados — o van estilados o son chips.
- [ ] Tarjetas elevadas usan `--bg-panel` (nunca `#fff` como fallback).
- [ ] Números tienen las flechas custom (no las nativas grises).
- [ ] Se ve bien en modo día **y** en modo noche.
- [ ] Foco visible con `:focus-visible`.
- [ ] `prefers-reduced-motion` respetado si añades animaciones.

Si algo se sale del estilo, el arreglo casi siempre es un token o una
variante existente, no un CSS nuevo. Cuando en duda, pregunta.
