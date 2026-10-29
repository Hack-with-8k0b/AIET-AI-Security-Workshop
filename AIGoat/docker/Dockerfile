# Multi-stage workshop image → Google distroless runtime (no shell/apt).
# Chat + embeddings via NVIDIA API. No local Torch/CUDA.
FROM python:3.11-slim-bookworm AS builder

WORKDIR /build

COPY docker/requirements-workshop.txt ./requirements.txt
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

COPY app/ ./app/
COPY scripts/ ./scripts/
COPY config/ ./config/
COPY prompts/ ./prompts/
COPY guardrails/ ./guardrails/
COPY media/ ./media/
COPY alembic.ini ./alembic.ini
COPY alembic/ ./alembic/
COPY docker/entrypoint.py ./entrypoint.py

# Distroless already ENTRYPOINTs python3.11 — only pass the script as CMD.
FROM gcr.io/distroless/python3-debian12

WORKDIR /app

COPY --from=builder /install /install
COPY --from=builder /build/app /app/app
COPY --from=builder /build/scripts /app/scripts
COPY --from=builder /build/config /app/config
COPY --from=builder /build/prompts /app/prompts
COPY --from=builder /build/guardrails /app/guardrails
COPY --from=builder /build/media /app/media
COPY --from=builder /build/alembic.ini /app/alembic.ini
COPY --from=builder /build/alembic /app/alembic
COPY --from=builder /build/entrypoint.py /app/entrypoint.py

ENV PATH="/install/bin:/usr/bin:/bin"
ENV PYTHONPATH="/app:/install/lib/python3.11/site-packages"
ENV PYTHONUNBUFFERED=1
ENV CONFIG_PATH=/app/config/config.yml

EXPOSE 8000

# Base image ENTRYPOINT is already /usr/bin/python3.11
CMD ["/app/entrypoint.py"]
