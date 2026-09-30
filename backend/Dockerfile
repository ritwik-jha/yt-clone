FROM public.ecr.aws/docker/library/python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY alembic.ini .
COPY migrations ./migrations
COPY app ./app

# Both processes run from this one image; the poller service overrides the
# command. Config comes from the process environment (docker compose
# env_file), not from a baked-in .env — never COPY .env into the image.
RUN useradd --create-home --uid 10001 appuser
USER appuser

EXPOSE 8000

# The API applies pending migrations before it serves (migrations/env.py
# serialises concurrent tasks). Keep in step with the command in
# terraform/ecs.tf, which overrides this on ECS.
CMD ["sh", "-c", "alembic upgrade head && exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers 2 --proxy-headers --forwarded-allow-ips '*'"]
