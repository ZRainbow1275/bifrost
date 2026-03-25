"""Shared FastAPI dependencies for dependency injection.

Provides singleton access to settings and the NewAPI client,
plus admin authentication guard.
"""

from __future__ import annotations

from fastapi import Header, HTTPException

from .config import Settings
from .newapi_client import NewAPIClient

settings = Settings()

_client: NewAPIClient | None = None


def get_settings() -> Settings:
    """Return the global ``Settings`` singleton."""
    return settings


async def get_newapi_client() -> NewAPIClient:
    """Return the global ``NewAPIClient`` singleton.

    Lazily instantiated on first call using the current settings.
    """
    global _client
    if _client is None:
        _client = NewAPIClient(
            settings.newapi_base_url,
            settings.newapi_admin_token,
        )
    return _client


async def require_admin(
    x_admin_key: str = Header(..., alias="X-Admin-Key"),
) -> str:
    """Dependency that enforces admin authentication.

    Raises 403 if the provided ``X-Admin-Key`` header does not match
    the configured ``admin_key``.
    """
    if not settings.admin_key or x_admin_key != settings.admin_key:
        raise HTTPException(status_code=403, detail="无效的管理密钥")
    return x_admin_key
