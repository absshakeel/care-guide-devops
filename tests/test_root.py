"""Tests for GET /."""

from httpx import AsyncClient


async def test_root_returns_200(client: AsyncClient) -> None:
    response = await client.get("/")
    assert response.status_code == 200


async def test_root_message(client: AsyncClient) -> None:
    data = (await client.get("/")).json()
    assert data["message"] == "Hello from DevOps Task!"


async def test_root_status(client: AsyncClient) -> None:
    data = (await client.get("/")).json()
    assert data["status"] == "running"


async def test_root_version(client: AsyncClient) -> None:
    data = (await client.get("/")).json()
    assert "version" in data
    assert data["version"]  # non-empty
