"""
Bot de Discord de Aprentix — píldoras de temario.

Publica una píldora corta (consejo, dato clave, truco memorístico) en un
canal a una hora fija, y responde al comando /consejo bajo demanda.

Las píldoras las genera `ingesta.py` a partir de los PDFs de teoría y
viven en el esquema `discord` de Postgres. Este proceso NO lee los PDFs:
solo consulta la tabla, así que su contenedor no monta /ficheros.

Solo se publican las píldoras en estado 'aprobada'. Ver ingesta.py para
el flujo de revisión.
"""
from __future__ import annotations

import asyncio
import logging
import os
from datetime import time as hora
from zoneinfo import ZoneInfo

import discord
import psycopg
from discord.ext import tasks

DSN      = os.environ["DATABASE_URL"]
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


# ── Selección de píldora ────────────────────────────────────────────────────

# Coge la aprobada que lleve más tiempo sin publicarse (las que nunca se
# han publicado van primero, por NULLS FIRST) y la marca como publicada en
# la misma sentencia, para que dos publicaciones concurrentes no repitan.
# SKIP LOCKED evita que se bloqueen entre ellas.
SIGUIENTE = """
    UPDATE discord.pildoras
       SET publicada_en = now()
     WHERE id = (
           SELECT id FROM discord.pildoras
            WHERE estado = 'aprobada'
            ORDER BY publicada_en NULLS FIRST, random()
            LIMIT 1
              FOR UPDATE SKIP LOCKED
     )
 RETURNING texto
"""


def _siguiente_sync() -> str | None:
    with psycopg.connect(DSN) as conn:
        fila = conn.execute(SIGUIENTE).fetchone()
    return fila[0] if fila else None


async def siguiente_pildora() -> str | None:
    """psycopg es síncrono: lo sacamos del hilo del event loop."""
    return await asyncio.to_thread(_siguiente_sync)


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


@bot.tree.command(name="consejo", description="Una píldora del temario")
async def consejo(inter: discord.Interaction) -> None:
    await inter.response.defer(thinking=True)
    texto = await siguiente_pildora()
    await inter.followup.send(texto or "Todavía no hay píldoras aprobadas.")


@tasks.loop(time=HORA_DIARIA)
async def diaria() -> None:
    texto = await siguiente_pildora()
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
