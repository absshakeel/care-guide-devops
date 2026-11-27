"""Tests for the SIGTERM handler installed during application lifespan."""

import signal

from app.main import app, lifespan


async def test_lifespan_delegates_sigterm_to_previous_handler() -> None:
    """The lifespan handler must chain to uvicorn's handler, not replace it.

    Replacing it silently disables uvicorn's graceful shutdown, which forces
    Docker to SIGKILL the container after the stop timeout instead of letting
    in-flight requests finish.
    """
    original = signal.getsignal(signal.SIGTERM)
    calls: list[int] = []

    def uvicorn_handler(signum: int, frame: object) -> None:
        calls.append(signum)

    signal.signal(signal.SIGTERM, uvicorn_handler)

    try:
        async with lifespan(app):
            installed = signal.getsignal(signal.SIGTERM)
            # A wrapper was installed rather than uvicorn's handler being kept.
            assert installed is not uvicorn_handler

            installed(signal.SIGTERM, None)

            # ...and invoking the wrapper still reaches uvicorn's handler.
            assert calls == [signal.SIGTERM]
    finally:
        signal.signal(signal.SIGTERM, original)


async def test_lifespan_tolerates_non_callable_previous_handler() -> None:
    """SIG_DFL is a valid previous handler and must not raise when invoked."""
    original = signal.getsignal(signal.SIGTERM)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)

    try:
        async with lifespan(app):
            signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
    finally:
        signal.signal(signal.SIGTERM, original)
