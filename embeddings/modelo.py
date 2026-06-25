"""Carga perezosa del modelo de embeddings multilingüe (384 dims)."""
from functools import lru_cache
from sentence_transformers import SentenceTransformer

MODELO_NOMBRE = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"


@lru_cache(maxsize=1)
def cargar() -> SentenceTransformer:
    return SentenceTransformer(MODELO_NOMBRE)


def vectorizar(textos: list[str]) -> list[list[float]]:
    modelo = cargar()
    arr = modelo.encode(textos, normalize_embeddings=True, convert_to_numpy=True)
    return arr.tolist()
