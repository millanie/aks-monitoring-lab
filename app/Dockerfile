FROM python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir flask prometheus_client gunicorn

COPY app.py .

EXPOSE 8080

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--timeout", "120", "app:app"]
