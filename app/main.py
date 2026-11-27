"""FastAPI application — Care Guide DevOps assessment."""

import logging
import signal
import time
import types
from collections.abc import AsyncGenerator, Callable, Coroutine
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Histogram,
    generate_latest,
)

from app.config import APP_VERSION, ENVIRONMENT
from app.logging_config import configure_logging

configure_logging()
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Prometheus metrics
# ---------------------------------------------------------------------------
REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status_code"],
)

ERROR_COUNT = Counter(
    "http_errors_total",
    "Total HTTP errors (4xx and 5xx)",
    ["method", "endpoint", "status_code"],
)

REQUEST_DURATION = Histogram(
    "http_request_duration_seconds",
    "HTTP request duration in seconds",
    ["method", "endpoint"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)


# ---------------------------------------------------------------------------
# Lifespan — startup / shutdown
# ---------------------------------------------------------------------------
@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    """Handle application startup and graceful shutdown."""
    logger.info("Application starting", extra={"version": APP_VERSION, "environment": ENVIRONMENT})

    # Log SIGTERM without replacing the handler uvicorn installs for its own
    # graceful shutdown. signal.signal() would override it, so hook in and
    # delegate to whatever was registered before us.
    previous_sigterm = signal.getsignal(signal.SIGTERM)

    def _handle_sigterm(signum: int, frame: types.FrameType | None) -> None:
        logger.info("SIGTERM received — initiating graceful shutdown")
        if callable(previous_sigterm):
            previous_sigterm(signum, frame)

    signal.signal(signal.SIGTERM, _handle_sigterm)

    yield

    logger.info("Application shutdown complete")


# ---------------------------------------------------------------------------
# FastAPI application
# ---------------------------------------------------------------------------
app = FastAPI(
    title="Care Guide DevOps App",
    version=APP_VERSION,
    docs_url="/docs",
    redoc_url=None,
    lifespan=lifespan,
)


# ---------------------------------------------------------------------------
# Middleware — request logging and metrics
# ---------------------------------------------------------------------------
@app.middleware("http")
async def observe_requests(
    request: Request,
    call_next: Callable[[Request], Coroutine[None, None, Response]],
) -> Response:
    """Emit access logs and update Prometheus metrics for every request."""
    start = time.perf_counter()
    # Normalise dynamic path segments to avoid high-cardinality labels.
    # Only the fixed routes we expose are tracked individually; everything
    # else falls under "other".
    _known = {"/", "/health", "/metrics"}
    endpoint = request.url.path if request.url.path in _known else "other"

    response: Response = await call_next(request)
    duration = time.perf_counter() - start

    status = str(response.status_code)
    method = request.method

    REQUEST_COUNT.labels(method=method, endpoint=endpoint, status_code=status).inc()
    REQUEST_DURATION.labels(method=method, endpoint=endpoint).observe(duration)

    if response.status_code >= 400:
        ERROR_COUNT.labels(method=method, endpoint=endpoint, status_code=status).inc()
        logger.warning(
            "HTTP error",
            extra={
                "method": method,
                "path": request.url.path,
                "status_code": response.status_code,
                "duration_ms": round(duration * 1000, 2),
            },
        )
    else:
        logger.info(
            "HTTP request",
            extra={
                "method": method,
                "path": request.url.path,
                "status_code": response.status_code,
                "duration_ms": round(duration * 1000, 2),
            },
        )

    return response


# ---------------------------------------------------------------------------
# Exception handler — never expose internal details to clients
# ---------------------------------------------------------------------------
@app.exception_handler(Exception)
async def generic_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    logger.error(
        "Unhandled exception",
        extra={"path": request.url.path, "error": type(exc).__name__},
        exc_info=True,
    )
    return JSONResponse(
        status_code=500,
        content={"error": "Internal server error"},
    )


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
@app.get("/")
async def root() -> dict[str, str]:
    """Return service identity information."""
    return {
        "message": "Hello from DevOps Task!",
        "status": "running",
        "version": APP_VERSION,
    }


@app.get("/health")
async def health() -> dict[str, str]:
    """Liveness and readiness probe endpoint."""
    return {
        "status": "healthy",
        "version": APP_VERSION,
        "environment": ENVIRONMENT,
    }


@app.get("/metrics")
async def metrics() -> Response:
    """Expose Prometheus metrics in text exposition format."""
    return Response(
        content=generate_latest(),
        media_type=CONTENT_TYPE_LATEST,
    )
