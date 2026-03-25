"""HTTP client wrapping NewAPI's REST API.

This is the core integration layer. All service modules depend on this client
to communicate with the upstream NewAPI instance. It handles authentication,
retry logic, and response parsing.
"""

from __future__ import annotations

import logging
from typing import Any

import httpx

logger = logging.getLogger(__name__)

# Transient HTTP status codes that warrant automatic retry
_RETRYABLE_STATUS_CODES: frozenset[int] = frozenset({502, 503, 504, 408, 429})

# Default retry configuration
_DEFAULT_MAX_RETRIES: int = 3
_DEFAULT_TIMEOUT_SECONDS: float = 30.0


class NewAPIError(Exception):
    """Raised when NewAPI returns an error response."""

    def __init__(self, message: str, status_code: int = 0, detail: str = "") -> None:
        self.status_code = status_code
        self.detail = detail
        super().__init__(message)


class NewAPIClient:
    """Async HTTP client for NewAPI's management REST API.

    All methods return parsed JSON dicts or raise ``NewAPIError``
    on non-success responses. Bearer-token authentication is
    injected via default headers.
    """

    def __init__(
        self,
        base_url: str,
        admin_token: str,
        *,
        max_retries: int = _DEFAULT_MAX_RETRIES,
        timeout: float = _DEFAULT_TIMEOUT_SECONDS,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._admin_token = admin_token
        self._max_retries = max_retries
        self._timeout = timeout
        self._client: httpx.AsyncClient | None = None

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    async def _ensure_client(self) -> httpx.AsyncClient:
        """Lazily initialize the underlying ``httpx.AsyncClient``."""
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(
                base_url=self._base_url,
                headers={
                    "Authorization": f"Bearer {self._admin_token}",
                    "Content-Type": "application/json",
                },
                timeout=httpx.Timeout(self._timeout),
            )
        return self._client

    async def close(self) -> None:
        """Gracefully close the HTTP client connection pool."""
        if self._client is not None and not self._client.is_closed:
            await self._client.aclose()
            self._client = None

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    async def _request(
        self,
        method: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
        json_body: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Execute an HTTP request with retry logic.

        Retries on transient failures (502/503/504/408/429) up to
        ``self._max_retries`` times. All other errors are raised immediately.
        """
        client = await self._ensure_client()
        last_exc: Exception | None = None

        for attempt in range(1, self._max_retries + 1):
            try:
                response = await client.request(
                    method,
                    path,
                    params=params,
                    json=json_body,
                )

                if response.status_code in _RETRYABLE_STATUS_CODES and attempt < self._max_retries:
                    logger.warning(
                        "Retryable status %d on %s %s (attempt %d/%d)",
                        response.status_code,
                        method,
                        path,
                        attempt,
                        self._max_retries,
                    )
                    continue

                if response.status_code >= 400:
                    body = response.text
                    raise NewAPIError(
                        f"NewAPI request failed: {method} {path} -> {response.status_code}",
                        status_code=response.status_code,
                        detail=body,
                    )

                return response.json()  # type: ignore[no-any-return]

            except httpx.TransportError as exc:
                last_exc = exc
                if attempt < self._max_retries:
                    logger.warning(
                        "Transport error on %s %s (attempt %d/%d): %s",
                        method,
                        path,
                        attempt,
                        self._max_retries,
                        exc,
                    )
                    continue
                raise NewAPIError(
                    f"NewAPI unreachable after {self._max_retries} attempts: {exc}",
                    status_code=0,
                    detail=str(exc),
                ) from exc

        # Should not be reached, but guard against logic errors
        raise NewAPIError(
            f"NewAPI request exhausted retries: {method} {path}",
            detail=str(last_exc) if last_exc else "",
        )

    # ------------------------------------------------------------------
    # Health
    # ------------------------------------------------------------------

    async def health_check(self) -> bool:
        """Check if NewAPI is reachable and healthy."""
        try:
            await self._request("GET", "/api/status")
            return True
        except NewAPIError:
            return False

    # ------------------------------------------------------------------
    # Users
    # ------------------------------------------------------------------

    async def create_user(
        self,
        username: str,
        display_name: str = "",
        password: str = "",
        email: str = "",
        quota: int = 0,
    ) -> dict[str, Any]:
        """Create a new user in NewAPI.

        Returns the created user record as a dict.
        """
        payload: dict[str, Any] = {
            "username": username,
            "display_name": display_name or username,
            "password": password,
        }
        if email:
            payload["email"] = email
        if quota:
            payload["quota"] = quota
        return await self._request("POST", "/api/user/", json_body=payload)

    async def list_users(self, page: int = 0, page_size: int = 20) -> dict[str, Any]:
        """List users with pagination.

        NewAPI uses 0-based page indexing. Returns ``{"data": [...], ...}``.
        """
        return await self._request(
            "GET",
            "/api/user/",
            params={"p": page, "size": page_size},
        )

    async def get_user(self, user_id: int) -> dict[str, Any]:
        """Get a single user by ID."""
        return await self._request("GET", f"/api/user/{user_id}")

    async def update_user(self, user_id: int, **kwargs: Any) -> dict[str, Any]:
        """Update user fields.

        Accepts arbitrary keyword arguments that map to NewAPI user fields
        (e.g. ``status``, ``quota``, ``display_name``).
        """
        payload = {"id": user_id, **kwargs}
        return await self._request("PUT", "/api/user/", json_body=payload)

    async def delete_user(self, user_id: int) -> bool:
        """Delete a user by ID. Returns ``True`` on success."""
        await self._request("DELETE", f"/api/user/{user_id}")
        return True

    # ------------------------------------------------------------------
    # Tokens
    # ------------------------------------------------------------------

    async def create_token(
        self,
        name: str,
        remain_quota: int = 0,
        expired_time: int = -1,
        unlimited_quota: bool = False,
        user_id: int = 0,
    ) -> dict[str, Any]:
        """Create an API token (key) in NewAPI.

        Args:
            name: Display name for the token.
            remain_quota: Quota remaining for this token.
            expired_time: Unix timestamp for expiry, -1 = never.
            unlimited_quota: If True, token has no quota limit.
            user_id: Owner user ID (0 = current admin user).

        Returns the created token record including the ``key`` field.
        """
        payload: dict[str, Any] = {
            "name": name,
            "remain_quota": remain_quota,
            "expired_time": expired_time,
            "unlimited_quota": unlimited_quota,
        }
        if user_id:
            payload["user_id"] = user_id
        return await self._request("POST", "/api/token/", json_body=payload)

    async def list_tokens(self, page: int = 0, page_size: int = 20) -> dict[str, Any]:
        """List API tokens with pagination."""
        return await self._request(
            "GET",
            "/api/token/",
            params={"p": page, "size": page_size},
        )

    async def update_token(self, token_id: int, **kwargs: Any) -> dict[str, Any]:
        """Update token fields."""
        payload = {"id": token_id, **kwargs}
        return await self._request("PUT", "/api/token/", json_body=payload)

    async def delete_token(self, token_id: int) -> bool:
        """Delete a token by ID. Returns ``True`` on success."""
        await self._request("DELETE", f"/api/token/{token_id}")
        return True

    # ------------------------------------------------------------------
    # Channels
    # ------------------------------------------------------------------

    async def list_channels(self, page: int = 0, page_size: int = 20) -> dict[str, Any]:
        """List channels (upstream providers) with pagination."""
        return await self._request(
            "GET",
            "/api/channel/",
            params={"p": page, "size": page_size},
        )

    async def create_channel(
        self,
        name: str,
        type: int = 1,
        key: str = "",
        base_url: str = "",
        models: str = "",
        test_model: str = "",
    ) -> dict[str, Any]:
        """Create a new channel.

        Args:
            name: Channel display name.
            type: Channel type (1=OpenAI, 3=Azure, etc.).
            key: API key for the upstream provider.
            base_url: Override base URL for the provider.
            models: Comma-separated list of supported model names.
            test_model: Model name to use for channel testing.
        """
        payload: dict[str, Any] = {
            "name": name,
            "type": type,
            "key": key,
        }
        if base_url:
            payload["base_url"] = base_url
        if models:
            payload["models"] = models
        if test_model:
            payload["test_model"] = test_model
        return await self._request("POST", "/api/channel/", json_body=payload)

    async def update_channel(self, channel_id: int, **kwargs: Any) -> dict[str, Any]:
        """Update channel fields."""
        payload = {"id": channel_id, **kwargs}
        return await self._request("PUT", "/api/channel/", json_body=payload)

    async def delete_channel(self, channel_id: int) -> bool:
        """Delete a channel by ID. Returns ``True`` on success."""
        await self._request("DELETE", f"/api/channel/{channel_id}")
        return True

    async def test_channel(self, channel_id: int) -> dict[str, Any]:
        """Test a channel's connectivity and latency.

        Returns test result including success status and response time.
        """
        return await self._request("GET", f"/api/channel/test/{channel_id}")

    async def list_models(self) -> list[str]:
        """List all available model names across all enabled channels.

        Returns a deduplicated list of model identifier strings.
        """
        result = await self._request("GET", "/api/channel/models")
        # NewAPI returns models in various formats; normalize to a flat list
        if isinstance(result, list):
            return [str(m) for m in result]
        data = result.get("data", [])
        if isinstance(data, list):
            return [str(m.get("id", m)) if isinstance(m, dict) else str(m) for m in data]
        return []

    # ------------------------------------------------------------------
    # Statistics / Logs
    # ------------------------------------------------------------------

    async def get_usage_stats(self) -> dict[str, Any]:
        """Get global usage statistics (admin only)."""
        return await self._request("GET", "/api/log/stat")

    async def get_log_stat(self) -> dict[str, Any]:
        """Get aggregated log statistics (admin only).

        Alias kept for backward compatibility with stats router.
        """
        return await self._request("GET", "/api/log/stat")

    async def get_logs(
        self,
        page: int = 0,
        page_size: int = 20,
        *,
        start_timestamp: int | None = None,
        end_timestamp: int | None = None,
        user_id: int | None = None,
    ) -> dict[str, Any]:
        """Query usage logs with optional time range and user filter.

        Args:
            page: 0-based page index.
            page_size: Number of records per page.
            start_timestamp: Unix timestamp for range start (inclusive).
            end_timestamp: Unix timestamp for range end (inclusive).
            user_id: Filter by specific user ID.
        """
        params: dict[str, Any] = {"p": page, "size": page_size}
        if start_timestamp is not None:
            params["start_timestamp"] = start_timestamp
        if end_timestamp is not None:
            params["end_timestamp"] = end_timestamp
        if user_id is not None:
            params["user_id"] = user_id
        return await self._request("GET", "/api/log/self/stat", params=params)
