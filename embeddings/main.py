"""API HTTP del servicio de embeddings + arranque del worker en segundo plano."""
import logging
import threading

import uvicorn
from fastapi import FastAPI
from pydantic import BaseModel

from modelo import vectorizar_pasajes, vectorizar_consultas
from worker import loop as worker_loop

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")

app = FastAPI(title="aprentix-embeddings", version="0.2.0")


class Peticion(BaseModel):
    textos: list[str]


@app.get("/salud")
def salud() -> dict[str, str]:
    return {"estado": "ok"}


@app.post("/vectorizar")
def endpoint_vectorizar(p: Peticion) -> dict[str, list[list[float]]]:
    """Lado documento (passage). Para indexar enunciados y etiquetas."""
    return {"vectores": vectorizar_pasajes(p.textos)}


@app.post("/vectorizar_consulta")
def endpoint_vectorizar_consulta(p: Peticion) -> dict[str, list[list[float]]]:
    """Lado búsqueda (query). Para vectorizar la cadena que escribe el usuario."""
    return {"vectores": vectorizar_consultas(p.textos)}


if __name__ == "__main__":
    threading.Thread(target=worker_loop, daemon=True, name="emb-worker").start()
    uvicorn.run(app, host="0.0.0.0", port=8001)
