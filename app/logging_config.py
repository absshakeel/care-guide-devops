"""Structured JSON logging configuration."""

import logging
import sys

from pythonjsonlogger.json import JsonFormatter

from app.config import ENVIRONMENT, LOG_LEVEL


def configure_logging() -> None:
    """Configure root logger to emit structured JSON to stdout."""
    log_level = getattr(logging, LOG_LEVEL.upper(), logging.INFO)

    handler = logging.StreamHandler(sys.stdout)
    handler.setLevel(log_level)

    formatter = JsonFormatter(
        fmt="%(asctime)s %(levelname)s %(name)s %(message)s",
        rename_fields={"asctime": "timestamp", "levelname": "level", "name": "logger"},
        datefmt="%Y-%m-%dT%H:%M:%S",
    )
    handler.setFormatter(formatter)

    root = logging.getLogger()
    root.setLevel(log_level)
    root.handlers.clear()
    root.addHandler(handler)

    # Suppress uvicorn's own access log — the middleware above emits a
    # structured JSON line per request, so the plain-text duplicate is noise.
    logging.getLogger("uvicorn.access").propagate = False
    logging.getLogger("uvicorn.access").handlers.clear()
    logging.getLogger("uvicorn.access").disabled = True
    logging.getLogger("uvicorn.error").propagate = True

    logging.getLogger(__name__).info(
        "Logging configured",
        extra={"environment": ENVIRONMENT, "log_level": LOG_LEVEL},
    )
