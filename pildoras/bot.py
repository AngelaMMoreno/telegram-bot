"""
Bot de Discord de Aprentix — píldoras de temario.

Publica una píldora corta (consejo, dato clave, truco memorístico) en un
canal a una hora fija, y responde a /consejo bajo demanda.

Comandos:
    /consejo   Cualquiera. Devuelve una píldora aprobada.
    /revisar   Solo gestores del servidor. Aprueba o descarta las
               píldoras pendientes con botones, una a una.
    /pildoras  Solo gestores. Recuento por estado.

Las píldoras las genera `ingesta.py` a partir de los PDFs de teoría y
viven en un SQLite propio (ver almacen.py). El bot no lee los PDFs: su
contenedor no monta el volumen de ficheros.
"""
from __future__ import annotations

import asyncio
import logging
import os
from datetime import time as hora
from zoneinfo import ZoneInfo

import discord
from discord.ext import tasks

import almacen

TOKEN    = os.environ["DISCORD_TOKEN"]
CANAL_ID = int(os.environ["DISCORD_CANAL_ID"])
# Opcional: si se define, los slash commands se registran solo en ese
# servidor y aparecen al instante. Sin él, el registro es global y Discord
# puede tardar hasta una hora en propagarlo.
GUILD_ID = os.getenv("DISCORD_GUILD_ID")

MADRID = ZoneInfo("Europe/Madrid")
HORA_DIARIA = hora(
    hour=int(os.getenv("HORA_PILDORA", "9")),
    minute=int(os.getenv("MINUTO_PILDORA", "0")),
    tzinfo=MADRID,
)

log = logging.getLogger("pildoras.bot")


# almacen es síncrono: lo sacamos del hilo del event loop.
async def _db(fn, *args):
    return await asyncio.to_thread(fn, *args)


# ── Bot ─────────────────────────────────────────────────────────────────────

class BotPildoras(discord.Client):
    def __init__(self) -> None:
        # Intents por defecto: no necesitamos 'message_content' porque solo
        # usamos slash commands. Pedirlo obligaría a justificar el intent
        # privilegiado en la verificación del bot.
        super().__init__(intents=discord.Intents.default())
        self.tree = discord.app_commands.CommandTree(self)

    async def setup_hook(self) -> None:
        # setup_hook corre una sola vez, antes de conectar. Sincronizar en
        # on_ready repetiría el sync en cada reconexión (y come rate limit).
        if GUILD_ID:
            guild = discord.Object(id=int(GUILD_ID))
            self.tree.copy_global_to(guild=guild)
            await self.tree.sync(guild=guild)
        else:
            await self.tree.sync()
        diaria.start()


bot = BotPildoras()


# ── /consejo ────────────────────────────────────────────────────────────────

@bot.tree.command(name="consejo", description="Una píldora del temario")
async def consejo(inter: discord.Interaction) -> None:
    await inter.response.defer(thinking=True)
    texto = await _db(almacen.siguiente_pildora)
    await inter.followup.send(texto or "Todavía no hay píldoras aprobadas.")


# ── /revisar ────────────────────────────────────────────────────────────────

def _embed_revision(fila, pendientes: int) -> discord.Embed:
    embed = discord.Embed(title="Píldora pendiente", description=fila["texto"])
    origen = fila["fuente"]
    if fila["pagina"]:
        origen += f" · página {fila['pagina']}"
    embed.add_field(name="Origen", value=origen, inline=False)
    embed.set_footer(text=f"{pendientes} pendientes · #{fila['id']}")
    return embed


class Revision(discord.ui.View):
    """Botones de aprobar/descartar/saltar sobre una píldora concreta."""

    def __init__(self, id_pildora: int, autor_id: int) -> None:
        super().__init__(timeout=300)
        self.id_pildora = id_pildora
        self.autor_id = autor_id
        self.saltadas: set[int] = set()

    async def interaction_check(self, inter: discord.Interaction) -> bool:
        # Que otro no pulse los botones de tu sesión de revisión.
        if inter.user.id != self.autor_id:
            await inter.response.send_message(
                "Esta revisión la abrió otra persona. Usa /revisar.",
                ephemeral=True,
            )
            return False
        return True

    async def _avanzar(self, inter: discord.Interaction) -> None:
        fila = await _db(almacen.siguiente_pendiente, self.saltadas)
        if fila is None:
            await inter.response.edit_message(
                content="No quedan píldoras por revisar.", embed=None, view=None
            )
            self.stop()
            return
        self.id_pildora = fila["id"]
        recuento = await _db(almacen.recuento)
        await inter.response.edit_message(
            embed=_embed_revision(fila, recuento.get("pendiente", 0)), view=self
        )

    @discord.ui.button(label="Aprobar", style=discord.ButtonStyle.success, emoji="✅")
    async def aprobar(self, inter: discord.Interaction, _: discord.ui.Button) -> None:
        await _db(almacen.marcar, self.id_pildora, "aprobada")
        await self._avanzar(inter)

    @discord.ui.button(label="Descartar", style=discord.ButtonStyle.danger, emoji="❌")
    async def descartar(self, inter: discord.Interaction, _: discord.ui.Button) -> None:
        await _db(almacen.marcar, self.id_pildora, "descartada")
        await self._avanzar(inter)

    @discord.ui.button(label="Saltar", style=discord.ButtonStyle.secondary, emoji="⏭️")
    async def saltar(self, inter: discord.Interaction, _: discord.ui.Button) -> None:
        self.saltadas.add(self.id_pildora)
        await self._avanzar(inter)


@bot.tree.command(name="revisar", description="Aprobar o descartar píldoras pendientes")
@discord.app_commands.default_permissions(manage_guild=True)
async def revisar(inter: discord.Interaction) -> None:
    fila = await _db(almacen.siguiente_pendiente)
    if fila is None:
        await inter.response.send_message(
            "No hay píldoras pendientes. Lanza la ingesta para generar más.",
            ephemeral=True,
        )
        return
    recuento = await _db(almacen.recuento)
    await inter.response.send_message(
        embed=_embed_revision(fila, recuento.get("pendiente", 0)),
        view=Revision(fila["id"], inter.user.id),
        ephemeral=True,
    )


# ── /pildoras ───────────────────────────────────────────────────────────────

@bot.tree.command(name="pildoras", description="Cuántas píldoras hay y en qué estado")
@discord.app_commands.default_permissions(manage_guild=True)
async def pildoras(inter: discord.Interaction) -> None:
    r = await _db(almacen.recuento)
    await inter.response.send_message(
        f"✅ Aprobadas: **{r.get('aprobada', 0)}**\n"
        f"🕓 Pendientes: **{r.get('pendiente', 0)}**\n"
        f"❌ Descartadas: **{r.get('descartada', 0)}**",
        ephemeral=True,
    )


# ── Píldora diaria ──────────────────────────────────────────────────────────

@tasks.loop(time=HORA_DIARIA)
async def diaria() -> None:
    texto = await _db(almacen.siguiente_pildora)
    if not texto:
        log.warning("no hay píldoras aprobadas; no se publica nada")
        return
    canal = bot.get_channel(CANAL_ID) or await bot.fetch_channel(CANAL_ID)
    await canal.send(f"💡 **Píldora del día**\n\n{texto}")


@diaria.before_loop
async def _esperar_conexion() -> None:
    await bot.wait_until_ready()


@bot.event
async def on_ready() -> None:
    log.info("conectado como %s", bot.user)


if __name__ == "__main__":
    logging.basicConfig(
        level=os.getenv("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    bot.run(TOKEN, log_handler=None)
