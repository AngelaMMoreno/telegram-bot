FROM python:3.11-slim

# Build context es la raíz del repo (para poder incluir /shared).
WORKDIR /app
COPY teoria/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY teoria/app.py .
COPY teoria/site   ./site
COPY shared        ./site/shared

ENV BASE_DIR=/ficheros \
    POSTGREST_URL=http://postgrest:3000 \
    LANDING_URL=https://aprentix.es

EXPOSE 80
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "80", "--proxy-headers"]
