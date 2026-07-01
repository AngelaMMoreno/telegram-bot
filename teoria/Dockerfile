FROM python:3.11-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY site ./site

ENV BASE_DIR=/ficheros \
    POSTGREST_URL=http://postgrest:3000 \
    LANDING_URL=https://aprentix.es

EXPOSE 80
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "80", "--proxy-headers"]
