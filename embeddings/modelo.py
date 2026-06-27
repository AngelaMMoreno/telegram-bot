"""Carga perezosa del modelo de embeddings multilingüe.

Usamos `BAAI/bge-m3` (1024 dim, ~2.3 GB RAM en FP32). Es el modelo
multilingüe abierto SOTA: capta relaciones temáticas en español mucho
mejor que e5 ("java" ↔ "spring boot"/"maven"/"gradle" sin necesidad de
palabras clave manuales) y soporta hasta 8192 tokens por entrada.

A diferencia de la familia e5, bge-m3 NO requiere prefijos
"query:"/"passage:": el mismo embedding sirve para indexar y para
buscar.
"""
from functools import lru_cache
from sentence_transformers import SentenceTransformer

MODELO_NOMBRE = "BAAI/bge-m3"
DIMENSIONES = 1024


@lru_cache(maxsize=1)
def cargar() -> SentenceTransformer:
    return SentenceTransformer(MODELO_NOMBRE)


def _vectorizar(textos: list[str]) -> list[list[float]]:
    if not textos:
        return []
    modelo = cargar()
    arr = modelo.encode(
        textos,
        normalize_embeddings=True,
        convert_to_numpy=True,
    )
    return arr.tolist()


def vectorizar_pasajes(textos: list[str]) -> list[list[float]]:
    """Para enunciados de preguntas y descripciones de etiquetas."""
    return _vectorizar(textos)


def vectorizar_consultas(textos: list[str]) -> list[list[float]]:
    """Para consultas de búsqueda del usuario."""
    return _vectorizar(textos)


# Compat: alias para no romper a quien siga llamando vectorizar().
def vectorizar(textos: list[str]) -> list[list[float]]:
    return _vectorizar(textos)
