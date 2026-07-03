FROM python:3.12-slim

# Zoneinfo (para Europe/Madrid en el worker si necesitáramos parsear fechas).
RUN apt-get update && apt-get install -y --no-install-recommends tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY notificador.py gen_vapid.py ./

# Sin ENTRYPOINT: el compose ejecuta 'python notificador.py'.
CMD ["python", "-u", "notificador.py"]
