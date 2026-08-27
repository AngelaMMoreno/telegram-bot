FROM python:3.12-slim

# Zoneinfo: el bot publica la píldora diaria en horario Europe/Madrid.
RUN apt-get update && apt-get install -y --no-install-recommends tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY bot.py ingesta.py ./

# El servicio 'ingesta' del compose sobreescribe esto con 'python ingesta.py'.
CMD ["python", "-u", "bot.py"]
