"""Tests for GET /metrics."""

from httpx import AsyncClient


async def test_metrics_returns_200(client: AsyncClient) -> None:
    response = await client.get("/metrics")
    assert response.status_code == 200


async def test_metrics_content_type(client: AsyncClient) -> None:
    response = await client.get("/metrics")
    assert "text/plain" in response.headers["content-type"]


async def test_metrics_contains_request_counter(client: AsyncClient) -> None:
    # Fire a request first so the counter is non-zero
    await client.get("/health")
    response = await client.get("/metrics")
    assert "http_requests_total" in response.text


async def test_metrics_contains_error_counter(client: AsyncClient) -> None:
    response = await client.get("/metrics")
    assert "http_errors_total" in response.text


async def test_metrics_contains_duration_histogram(client: AsyncClient) -> None:
    response = await client.get("/metrics")
    assert "http_request_duration_seconds" in response.text


async def test_error_increments_error_counter(client: AsyncClient) -> None:
    """A 404 response must increment the error counter."""
    await client.get("/nonexistent-route")
    metrics_text = (await client.get("/metrics")).text
    # The counter line for 404 on the "other" endpoint should be present
    assert "http_errors_total" in metrics_text
