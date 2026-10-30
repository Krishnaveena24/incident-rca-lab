FROM python:3.12-slim

# procps (ps, top, pkill) and curl are installed on purpose:
# they are your Linux diagnostic tools INSIDE the container.
RUN apt-get update && apt-get install -y --no-install-recommends procps curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV PYTHONUNBUFFERED=1
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

EXPOSE 5000
# 2 worker processes managed by a gunicorn master process
CMD ["gunicorn", "--workers", "2", "--bind", "0.0.0.0:5000", "--timeout", "90", \
     "--log-level", "info", "app:app"]
