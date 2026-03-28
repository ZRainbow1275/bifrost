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
    if not settings.newapi_admin_token.strip():
        raise HTTPException(status_code=503, detail="服务端未配置 NewAPI 管理令牌")
    if _client is None:
        _client = NewAPIClient(
            settings.newapi_base_url,
            settings.newapi_admin_token,
        )
    return _client


async def require_admin(
    x_admin_key: str | None = Header(None, alias="X-Admin-Key"),
) -> str:
    """Dependency that enforces admin authentication.

    Returns 401 when the header is missing, 403 when it is present but invalid,
    and 503 when the service is misconfigured without an admin key.
    """
    if not settings.admin_key:
        raise HTTPException(status_code=503, detail="服务端未配置管理密钥")
    if x_admin_key is None:
        raise HTTPException(status_code=401, detail="缺少管理密钥")
    if x_admin_key != settings.admin_key:
        raise HTTPException(status_code=403, detail="无效的管理密钥")
    return x_admin_key
