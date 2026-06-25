FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    TRANSFORMERS_NO_ADVISORY_WARNINGS=1 \
    HF_HOME=/cache/hf SENTENCE_TRANSFORMERS_HOME=/cache/st

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential libpq-dev curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY worker.py main.py modelo.py ./

# Precarga del modelo para evitar descargas en el primer arranque.
RUN python -c "from modelo import cargar; cargar()"

EXPOSE 8001

CMD ["python", "main.py"]
