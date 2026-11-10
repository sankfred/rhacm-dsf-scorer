FROM python:3-slim

LABEL org.opencontainers.image.description="quota-scorer"
LABEL org.opencontainers.image.title="quota-scorer"

COPY requirements.txt .

# Install dependencies
RUN apt-get update && apt-get install -y curl jq
RUN pip install --no-cache-dir -r requirements.txt

WORKDIR /scripts
COPY scripts ./

WORKDIR /app
COPY app ./

# Dynamic Scorer
EXPOSE 8000

# Scorer Prometheus Metric Exporter
EXPOSE 9000

CMD ["python", "main.py"]
