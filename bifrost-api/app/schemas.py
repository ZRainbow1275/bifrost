"""Pydantic models for Bifrost API request/response schemas.

All data contracts are defined here to maintain a single source of truth
for API serialization and validation.
"""

from __future__ import annotations

from pydantic import BaseModel, Field


# === Common ===


class ApiResponse(BaseModel):
    """Generic API response wrapper."""

    success: bool
    message: str = ""
    data: dict | list | None = None


# === Registration ===


class RegisterRequest(BaseModel):
    """User self-registration request."""

    username: str = Field(
        ...,
        min_length=2,
        max_length=31,
        pattern=r"^[a-z][a-z0-9_-]+$",
    )
    email: str = ""


class RegisterResponse(BaseModel):
    """User self-registration response with generated API key."""

    success: bool
    username: str
    api_key: str = ""
    base_url: str = ""
    message: str = ""


# === Users ===


class UserInfo(BaseModel):
    """Represents a user record from NewAPI."""

    id: int = 0
    username: str
    display_name: str = ""
    email: str = ""
    status: int = 1  # 1=active, 2=disabled
    quota: int = 0
    used_quota: int = 0
    request_count: int = 0
    created_time: int = 0


class UserListResponse(BaseModel):
    """Paginated list of users."""

    success: bool
    data: list[UserInfo] = []
    total: int = 0


class QuotaUpdateRequest(BaseModel):
    """Request to update a user's quota."""

    quota: int = Field(..., ge=0)


# === Models ===


class ModelStatus(BaseModel):
    """Status of a single model across all channels."""

    id: str  # model name like "gpt-4o"
    name: str = ""
    available: bool = True
    channels: int = 0  # number of channels providing this model
    avg_latency_ms: float = 0  # average response latency


class ModelStatusResponse(BaseModel):
    """Response containing all model statuses."""

    success: bool
    models: list[ModelStatus] = []
    tested_at: str = ""


# === Channels ===


class ChannelInfo(BaseModel):
    """Represents a channel (upstream provider) in NewAPI."""

    id: int = 0
    name: str = ""
    type: int = 1  # 1=OpenAI, etc.
    status: int = 1  # 1=enabled, 2=disabled, 3=testing
    key: str = ""
    base_url: str = ""
    models: str = ""  # comma-separated model names
    test_model: str = ""
    response_time: int = 0  # ms
    balance: float = 0
    priority: int = 0


class ChannelCreateRequest(BaseModel):
    """Request to create a new channel."""

    name: str
    type: int = 1
    key: str
    base_url: str = ""
    models: str = ""
    test_model: str = ""


class ChannelTestResult(BaseModel):
    """Result of testing a single channel."""

    id: int
    name: str
    success: bool
    latency_ms: int = 0
    error: str = ""


# === Stats ===


class UsageStats(BaseModel):
    """Global usage statistics."""

    total_requests: int = 0
    total_tokens: int = 0
    total_quota_used: float = 0
    active_users: int = 0
    active_channels: int = 0
    models_available: int = 0


class UserUsage(BaseModel):
    """Per-user usage breakdown."""

    username: str
    request_count: int = 0
    quota: int = 0
    used_quota: int = 0
    usage_percent: float = 0
