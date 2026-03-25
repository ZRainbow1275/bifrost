"""Self-service registration endpoints.

Provides public registration API and a web-based registration page.
Rate-limited by daily count to prevent abuse.
"""

from __future__ import annotations

import logging
import secrets
from datetime import date
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from ..config import Settings
from ..dependencies import get_newapi_client, get_settings
from ..newapi_client import NewAPIClient
from ..schemas import ApiResponse, RegisterRequest, RegisterResponse

logger = logging.getLogger("bifrost.register")

# API routes (prefixed with /api/v1)
router = APIRouter(prefix="/api/v1", tags=["registration"])

# Page routes (no prefix, serves HTML at /register)
page_router = APIRouter(tags=["pages"], include_in_schema=False)

# ---------------------------------------------------------------------------
# Module-level daily registration counter
# ---------------------------------------------------------------------------
_daily_counts: dict[str, int] = {}

# Jinja2 template renderer -- resolve relative to this file's package
_TEMPLATE_DIR = Path(__file__).resolve().parent.parent / "templates"
templates = Jinja2Templates(directory=str(_TEMPLATE_DIR))


def _today() -> str:
    """Return today's date as an ISO string for counter keying."""
    return date.today().isoformat()


def _get_today_count() -> int:
    """Return how many registrations happened today."""
    return _daily_counts.get(_today(), 0)


def _increment_today_count() -> None:
    """Increment the registration counter for today."""
    key = _today()
    _daily_counts[key] = _daily_counts.get(key, 0) + 1


# ---------------------------------------------------------------------------
# POST /api/v1/register  --  Self-service registration
# ---------------------------------------------------------------------------
@router.post("/register", response_model=RegisterResponse)
async def register_user(
    body: RegisterRequest,
    settings: Settings = Depends(get_settings),
    client: NewAPIClient = Depends(get_newapi_client),
) -> RegisterResponse:
    """Create a new user account and return an API key.

    - Checks self-registration toggle
    - Enforces daily registration cap
    - Creates user + token in NewAPI
    """
    # --- Gate: self-registration disabled ---
    if not settings.allow_self_register:
        raise HTTPException(
            status_code=403,
            detail="自助注册已关闭，请联系管理员",
        )

    # --- Gate: daily limit ---
    if _get_today_count() >= settings.max_register_per_day:
        raise HTTPException(
            status_code=429,
            detail="今日注册名额已满，请明天再试",
        )

    # --- Generate credentials ---
    password = secrets.token_urlsafe(16)
    today_str = _today()
    token_name = f"bifrost-{body.username}-{today_str}"

    try:
        # Step 1: create user in NewAPI
        user_result = await client.create_user(
            username=body.username,
            display_name=body.username,
            password=password,
            email=body.email,
            quota=settings.default_quota,
        )

        user_id: int = user_result.get("id", 0)
        if not user_id:
            raise ValueError("NewAPI 未返回有效的用户 ID")

        # Step 2: create token for this user
        token_result = await client.create_token(
            name=token_name,
            remain_quota=settings.default_quota,
            expired_time=-1,  # never expire
            unlimited_quota=False,
            user_id=user_id,
        )

        api_key: str = token_result.get("key", "")
        if not api_key:
            raise ValueError("NewAPI 未返回有效的 API Key")

    except HTTPException:
        raise
    except Exception as exc:
        logger.exception("注册过程中发生错误: username=%s", body.username)
        raise HTTPException(
            status_code=502,
            detail=f"注册失败: {exc}",
        ) from exc

    # --- Success ---
    _increment_today_count()
    logger.info(
        "新用户注册成功: username=%s, user_id=%d",
        body.username,
        user_id,
    )

    return RegisterResponse(
        success=True,
        username=body.username,
        api_key=api_key,
        base_url=f"{settings.newapi_base_url}/v1",
        message="注册成功",
    )


# ---------------------------------------------------------------------------
# GET /api/v1/register/status  --  Registration availability
# ---------------------------------------------------------------------------
@router.get("/register/status", response_model=ApiResponse)
async def register_status(
    settings: Settings = Depends(get_settings),
) -> ApiResponse:
    """Return current registration availability information."""
    today_count = _get_today_count()
    remaining = max(0, settings.max_register_per_day - today_count)

    return ApiResponse(
        success=True,
        message="注册状态查询成功",
        data={
            "enabled": settings.allow_self_register,
            "remaining_today": remaining,
            "max_per_day": settings.max_register_per_day,
        },
    )


# ---------------------------------------------------------------------------
# GET /register  --  Web registration page (HTML)
# ---------------------------------------------------------------------------
@page_router.get("/register", response_class=HTMLResponse)
async def register_page(request: Request) -> HTMLResponse:
    """Serve the web-based registration form."""
    return templates.TemplateResponse("register.html", {"request": request})
