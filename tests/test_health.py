"""Tests for GET /health."""

from httpx import AsyncClient


async def test_health_returns_200(client: AsyncClient) -> None:
    response = await client.get("/health")
    assert response.status_code == 200


async def test_health_body_has_status(client: AsyncClient) -> None:
    data = (await client.get("/health")).json()
    assert data["status"] == "healthy"


async def test_health_body_has_version(client: AsyncClient) -> None:
    data = (await client.get("/health")).json()
    assert "version" in data


async def test_health_body_has_environment(client: AsyncClient) -> None:
    data = (await client.get("/health")).json()
    assert "environment" in data
