FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

EXPOSE 8000

COPY . .

RUN pip install --no-cache-dir markdown

CMD ["python", "servidor_archivos.py"]
