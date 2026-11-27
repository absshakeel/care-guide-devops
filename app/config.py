"""Application configuration loaded from environment variables."""

import os

# Application identity
APP_VERSION: str = os.getenv("APP_VERSION", "0.1.0")
ENVIRONMENT: str = os.getenv("ENVIRONMENT", "development")

# Server
PORT: int = int(os.getenv("PORT", "8080"))

# Logging
LOG_LEVEL: str = os.getenv("LOG_LEVEL", "info").lower()
