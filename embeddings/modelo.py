"""Carga perezosa del modelo de embeddings multilingüe.

Usamos `intfloat/multilingual-e5-base` (768 dim, ~280 MB RAM). Es notablemente
mejor que el MiniLM anterior en español y entiende relaciones temáticas
("java" ↔ "hibernate"/"jdbc"/"junit") mucho mejor. La familia e5 exige que
cada texto vaya prefijado con "query: " o "passage: ", así que exponemos dos
funciones distintas para evitar mezclas.
"""
from functools import lru_cache
from sentence_transformers import SentenceTransformer

MODELO_NOMBRE = "intfloat/multilingual-e5-base"
DIMENSIONES = 768


@lru_cache(maxsize=1)
def cargar() -> SentenceTransformer:
    return SentenceTransformer(MODELO_NOMBRE)


def _vectorizar(textos: list[str], prefijo: str) -> list[list[float]]:
    if not textos:
        return []
    modelo = cargar()
    arr = modelo.encode(
        [f"{prefijo}{t}" for t in textos],
        normalize_embeddings=True,
        convert_to_numpy=True,
    )
    return arr.tolist()


def vectorizar_pasajes(textos: list[str]) -> list[list[float]]:
    """Para enunciados de preguntas y descripciones de etiquetas (lado documento)."""
    return _vectorizar(textos, "passage: ")


def vectorizar_consultas(textos: list[str]) -> list[list[float]]:
    """Para consultas de búsqueda (lado query)."""
    return _vectorizar(textos, "query: ")


# Compat: alias para no romper a quien siga llamando vectorizar().
def vectorizar(textos: list[str]) -> list[list[float]]:
    return vectorizar_pasajes(textos)
