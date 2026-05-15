"""Self-service registration endpoints.

Provides public registration API and a web-based registration page.
Rate-limited by daily count to prevent abuse.
"""

from __future__ import annotations

import asyncio
import inspect
import json
import logging
import secrets
from datetime import date, datetime
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
_state_lock = asyncio.Lock()

# Jinja2 template renderer -- resolve relative to this file's package
_TEMPLATE_DIR = Path(__file__).resolve().parent.parent / "templates"
templates = Jinja2Templates(directory=str(_TEMPLATE_DIR))
_TEMPLATE_RESPONSE_ACCEPTS_REQUEST_KW = (
    "request" in inspect.signature(templates.TemplateResponse).parameters
)


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


def _normalize_path_prefix(path_prefix: str | None) -> str:
    """Normalize an externally visible path prefix such as ``/manage``."""
    if not path_prefix:
        return ""

    normalized = path_prefix.strip()
    if not normalized or normalized == "/":
        return ""
    if not normalized.startswith("/"):
        normalized = f"/{normalized}"
    return normalized.rstrip("/")


def _get_request_path_prefix(request: Request) -> str:
    """Extract the reverse proxy prefix forwarded to the app."""
    forwarded_prefix = request.headers.get("x-forwarded-prefix")
    if forwarded_prefix:
        return _normalize_path_prefix(forwarded_prefix)

    root_path = request.scope.get("root_path")
    return _normalize_path_prefix(root_path if isinstance(root_path, str) else None)


def _template_response(
    request: Request,
    name: str,
    context: dict[str, object],
) -> HTMLResponse:
    """Render templates across Starlette TemplateResponse signature variants."""
    template_context = {"request": request, **context}
    if _TEMPLATE_RESPONSE_ACCEPTS_REQUEST_KW:
        return templates.TemplateResponse(
            request=request,
            name=name,
            context=template_context,
        )
    return templates.TemplateResponse(name, template_context)


def _get_public_gateway_base_url(settings: Settings) -> str:
    """Return the externally reachable AI gateway URL for end users."""
    public_base_url = settings.public_base_url.strip().rstrip("/")
    if not public_base_url:
        raise HTTPException(
            status_code=503,
            detail="管理员尚未配置 BIFROST_PUBLIC_BASE_URL，暂时无法发放可用接入地址",
        )
    return public_base_url


def _load_registration_state(state_file: str) -> dict[str, dict[str, int]]:
    """Load registration state from disk, tolerating missing/corrupt files."""
    path = Path(state_file)
    if not path.exists():
        return {"daily_counts": {}, "minute_counts": {}}

    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        logger.warning("注册状态文件损坏，将重置: %s", path)
        return {"daily_counts": {}, "minute_counts": {}}

    daily_counts = data.get("daily_counts", {})
    minute_counts = data.get("minute_counts", {})
    if not isinstance(daily_counts, dict) or not isinstance(minute_counts, dict):
        return {"daily_counts": {}, "minute_counts": {}}

    return {
        "daily_counts": {
            str(key): int(value)
            for key, value in daily_counts.items()
            if isinstance(value, int)
        },
        "minute_counts": {
            str(key): int(value)
            for key, value in minute_counts.items()
            if isinstance(value, int)
        },
    }


def _save_registration_state(
    state_file: str, state: dict[str, dict[str, int]]
) -> None:
    """Persist registration state atomically to disk."""
    path = Path(state_file)
    path.parent.mkdir(parents=True, exist_ok=True)

    tmp_path = path.with_suffix(f"{path.suffix}.tmp")
    tmp_path.write_text(
        json.dumps(state, ensure_ascii=False, sort_keys=True),
        encoding="utf-8",
    )
    tmp_path.replace(path)


def _current_minute_key() -> str:
    """Return the current minute bucket for rate limiting."""
    return datetime.utcnow().strftime("%Y-%m-%dT%H:%M")


def _prune_registration_state(
    state: dict[str, dict[str, int]], today_key: str, minute_key: str
) -> None:
    """Drop stale counters so the state file stays bounded."""
    state["daily_counts"] = {
        key: value
        for key, value in state.get("daily_counts", {}).items()
        if key == today_key
    }
    state["minute_counts"] = {
        key: value
        for key, value in state.get("minute_counts", {}).items()
        if key == minute_key
    }


async def _reserve_registration_attempt(settings: Settings) -> int:
    """Reserve one registration attempt and return today's current count."""
    today_key = _today()
    minute_key = _current_minute_key()

    async with _state_lock:
        state = _load_registration_state(settings.registration_state_file)
        _prune_registration_state(state, today_key, minute_key)

        daily_count = state["daily_counts"].get(today_key, 0)
        if daily_count >= settings.max_register_per_day:
            raise HTTPException(
                status_code=429,
                detail="今日注册名额已满，请明天再试",
            )

        minute_count = state["minute_counts"].get(minute_key, 0)
        if minute_count >= settings.rate_limit_per_minute:
            raise HTTPException(
                status_code=429,
                detail="注册请求过于频繁，请稍后重试",
            )

        state["minute_counts"][minute_key] = minute_count + 1
        _save_registration_state(settings.registration_state_file, state)
        return daily_count


async def _mark_registration_success(settings: Settings) -> None:
    """Persist a successful registration into the daily counter."""
    today_key = _today()
    minute_key = _current_minute_key()

    async with _state_lock:
        state = _load_registration_state(settings.registration_state_file)
        _prune_registration_state(state, today_key, minute_key)
        state["daily_counts"][today_key] = state["daily_counts"].get(today_key, 0) + 1
        _save_registration_state(settings.registration_state_file, state)


async def _get_persisted_today_count(settings: Settings) -> int:
    """Read the persisted daily registration count."""
    async with _state_lock:
        state = _load_registration_state(settings.registration_state_file)
        _prune_registration_state(state, _today(), _current_minute_key())
        _save_registration_state(settings.registration_state_file, state)
        return state["daily_counts"].get(_today(), 0)


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

    public_gateway_base_url = _get_public_gateway_base_url(settings)
    _daily_counts[_today()] = await _reserve_registration_attempt(settings)

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

        user_id: int = user_result.get("data", {}).get("id", 0)
        if not user_id:
            raise ValueError("NewAPI 未返回有效的用户 ID")

        # Step 2: create token for this user
        try:
            token_result = await client.create_token(
                name=token_name,
                remain_quota=settings.default_quota,
                expired_time=-1,  # never expire
                unlimited_quota=False,
                user_id=user_id,
            )

            api_key: str = token_result.get("data", {}).get("key", "")
            if not api_key:
                raise ValueError("NewAPI 未返回有效的 API Key")
        except Exception as token_exc:
            # Rollback: delete the orphaned user
            try:
                await client.delete_user(user_id)
            except Exception:
                pass  # Best-effort cleanup
            raise HTTPException(
                status_code=502,
                detail=f"Token 创建失败（用户已回滚）: {token_exc}",
            ) from token_exc

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
    await _mark_registration_success(settings)
    logger.info(
        "新用户注册成功: username=%s, user_id=%d",
        body.username,
        user_id,
    )

    return RegisterResponse(
        success=True,
        username=body.username,
        api_key=api_key,
        base_url=f"{public_gateway_base_url}/v1",
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
    today_count = await _get_persisted_today_count(settings)
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
    return _template_response(
        request,
        "register.html",
        {
            "api_prefix": _get_request_path_prefix(request),
        },
    )
