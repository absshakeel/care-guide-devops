# syntax=docker/dockerfile:1.10

# ---------------------------------------------------------------------------
# Stage 1 — build: install dependencies into a clean venv
# ---------------------------------------------------------------------------
FROM python:3.12.7-alpine3.20 AS builder

WORKDIR /build

# System build dependencies (only needed during build)
RUN apk add --no-cache gcc musl-dev libffi-dev

# Create isolated virtual environment
RUN python -m venv /venv
ENV PATH="/venv/bin:$PATH"

# Copy dependency manifest first to maximise layer cache reuse
COPY pyproject.toml .

# Install only production dependencies (no dev extras)
RUN pip install --no-cache-dir --upgrade pip \
 && pip install --no-cache-dir \
        "fastapi==0.115.5" \
        "uvicorn[standard]==0.32.1" \
        "prometheus-client==0.21.1" \
        "python-json-logger==3.2.1"

# ---------------------------------------------------------------------------
# Stage 2 — runtime: minimal Alpine image, non-root user
# ---------------------------------------------------------------------------
FROM python:3.12.7-alpine3.20 AS runtime

# OCI image labels
LABEL org.opencontainers.image.title="careguide-devops-app" \
      org.opencontainers.image.description="FastAPI service for Care Guide DevOps assessment" \
      org.opencontainers.image.version="0.1.0" \
      org.opencontainers.image.source="https://github.com/careguide/devops-task" \
      org.opencontainers.image.licenses="MIT"

WORKDIR /app

# Copy pre-built venv from builder — no compiler or build tools in runtime
COPY --from=builder /venv /venv
ENV PATH="/venv/bin:$PATH"

# Copy application source only (not tests, docs, etc. — see .dockerignore)
COPY app/ ./app/

# Create non-root user; no shell needed in production
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

USER appuser

# Runtime configuration with safe defaults
ENV PORT=8080 \
    LOG_LEVEL=info \
    ENVIRONMENT=production \
    APP_VERSION=0.1.0

EXPOSE 8080

# Health check: probe /health every 30 s, allow 5 s start-up grace
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:${PORT}/health || exit 1

CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT} --log-level ${LOG_LEVEL}"]
