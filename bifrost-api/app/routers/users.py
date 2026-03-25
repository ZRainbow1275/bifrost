"""Admin user management endpoints.

All endpoints require the ``X-Admin-Key`` header and are protected by
the ``require_admin`` dependency.
"""

from __future__ import annotations

import logging
import secrets
from datetime import date
from typing import Any

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..config import Settings
from ..dependencies import get_newapi_client, get_settings, require_admin
from ..newapi_client import NewAPIClient
from ..schemas import (
    ApiResponse,
    QuotaUpdateRequest,
    UserInfo,
    UserListResponse,
)

logger = logging.getLogger("bifrost.users")

router = APIRouter(
    prefix="/api/v1/users",
    tags=["users"],
    dependencies=[Depends(require_admin)],
)


# ---------------------------------------------------------------------------
# Request / response models local to this module
# ---------------------------------------------------------------------------


class StatusUpdateRequest(BaseModel):
    """Request body for enabling / disabling a user."""

    status: int = Field(..., ge=1, le=2, description="1=启用, 2=禁用")


class BatchCreateRequest(BaseModel):
    """Request body for batch user creation."""

    usernames: list[str] = Field(..., min_length=1)
    quota: int = Field(default=100, ge=0)


class BatchCreateResultItem(BaseModel):
    """Result for a single user in a batch operation."""

    username: str
    api_key: str = ""
    success: bool = True
    error: str = ""


class BatchCreateResponse(BaseModel):
    """Response for the batch-create endpoint."""

    success: bool
    results: list[BatchCreateResultItem] = []
    total: int = 0
    succeeded: int = 0
    failed: int = 0


# ---------------------------------------------------------------------------
# GET /api/v1/users  --  List users (paginated)
# ---------------------------------------------------------------------------
@router.get("", response_model=UserListResponse)
async def list_users(
    page: int = 1,
    page_size: int = 20,
    client: NewAPIClient = Depends(get_newapi_client),
) -> UserListResponse:
    """Return a paginated list of users from NewAPI."""
    try:
        result = await client.list_users(page=page, page_size=page_size)
    except Exception as exc:
        logger.exception("获取用户列表失败")
        raise HTTPException(status_code=502, detail=f"获取用户列表失败: {exc}") from exc

    users_raw: list[dict[str, Any]] = result.get("data", [])
    users = [UserInfo(**u) for u in users_raw]

    return UserListResponse(
        success=True,
        data=users,
        total=result.get("total", len(users)),
    )


# ---------------------------------------------------------------------------
# GET /api/v1/users/{user_id}  --  Get single user
# ---------------------------------------------------------------------------
@router.get("/{user_id}", response_model=UserInfo)
async def get_user(
    user_id: int,
    client: NewAPIClient = Depends(get_newapi_client),
) -> UserInfo:
    """Return details of a single user."""
    try:
        result = await client.get_user(user_id)
    except Exception as exc:
        logger.exception("获取用户信息失败: user_id=%d", user_id)
        raise HTTPException(status_code=502, detail=f"获取用户信息失败: {exc}") from exc

    if not result:
        raise HTTPException(status_code=404, detail="用户不存在")

    return UserInfo(**result)


# ---------------------------------------------------------------------------
# PUT /api/v1/users/{user_id}/quota  --  Update user quota
# ---------------------------------------------------------------------------
@router.put("/{user_id}/quota", response_model=ApiResponse)
async def update_user_quota(
    user_id: int,
    body: QuotaUpdateRequest,
    client: NewAPIClient = Depends(get_newapi_client),
) -> ApiResponse:
    """Update quota allocation for a user."""
    try:
        await client.update_user(user_id, quota=body.quota)
    except Exception as exc:
        logger.exception("更新用户配额失败: user_id=%d", user_id)
        raise HTTPException(status_code=502, detail=f"更新配额失败: {exc}") from exc

    logger.info("用户配额已更新: user_id=%d, quota=%d", user_id, body.quota)
    return ApiResponse(success=True, message="配额更新成功")


# ---------------------------------------------------------------------------
# PUT /api/v1/users/{user_id}/status  --  Enable / disable user
# ---------------------------------------------------------------------------
@router.put("/{user_id}/status", response_model=ApiResponse)
async def update_user_status(
    user_id: int,
    body: StatusUpdateRequest,
    client: NewAPIClient = Depends(get_newapi_client),
) -> ApiResponse:
    """Enable (status=1) or disable (status=2) a user."""
    try:
        await client.update_user(user_id, status=body.status)
    except Exception as exc:
        logger.exception("更新用户状态失败: user_id=%d", user_id)
        raise HTTPException(status_code=502, detail=f"更新状态失败: {exc}") from exc

    label = "启用" if body.status == 1 else "禁用"
    logger.info("用户已%s: user_id=%d", label, user_id)
    return ApiResponse(success=True, message=f"用户已{label}")


# ---------------------------------------------------------------------------
# DELETE /api/v1/users/{user_id}  --  Delete user
# ---------------------------------------------------------------------------
@router.delete("/{user_id}", response_model=ApiResponse)
async def delete_user(
    user_id: int,
    client: NewAPIClient = Depends(get_newapi_client),
) -> ApiResponse:
    """Permanently delete a user from NewAPI."""
    try:
        deleted = await client.delete_user(user_id)
    except Exception as exc:
        logger.exception("删除用户失败: user_id=%d", user_id)
        raise HTTPException(status_code=502, detail=f"删除用户失败: {exc}") from exc

    if not deleted:
        raise HTTPException(status_code=404, detail="用户不存在或已被删除")

    logger.info("用户已删除: user_id=%d", user_id)
    return ApiResponse(success=True, message="用户已删除")


# ---------------------------------------------------------------------------
# POST /api/v1/users/batch  --  Batch create users (注册机)
# ---------------------------------------------------------------------------
@router.post("/batch", response_model=BatchCreateResponse)
async def batch_create_users(
    body: BatchCreateRequest,
    settings: Settings = Depends(get_settings),
    client: NewAPIClient = Depends(get_newapi_client),
) -> BatchCreateResponse:
    """Batch-create multiple users and return their API keys.

    This is the "注册机" (registration machine) mode: given a list of
    usernames, create each user with a token and return credentials.
    """
    today_str = date.today().isoformat()
    results: list[BatchCreateResultItem] = []
    succeeded = 0
    failed = 0

    for username in body.usernames:
        password = secrets.token_urlsafe(16)
        token_name = f"bifrost-{username}-{today_str}"

        try:
            # Create user
            user_result = await client.create_user(
                username=username,
                display_name=username,
                password=password,
                email="",
                quota=body.quota,
            )

            user_id: int = user_result.get("id", 0)
            if not user_id:
                raise ValueError("NewAPI 未返回有效的用户 ID")

            # Create token
            token_result = await client.create_token(
                name=token_name,
                remain_quota=body.quota,
                expired_time=-1,
                unlimited_quota=False,
                user_id=user_id,
            )

            api_key: str = token_result.get("key", "")
            if not api_key:
                raise ValueError("NewAPI 未返回有效的 API Key")

            results.append(
                BatchCreateResultItem(
                    username=username,
                    api_key=api_key,
                    success=True,
                )
            )
            succeeded += 1
            logger.info("批量注册成功: username=%s", username)

        except Exception as exc:
            logger.warning("批量注册失败: username=%s, error=%s", username, exc)
            results.append(
                BatchCreateResultItem(
                    username=username,
                    success=False,
                    error=str(exc),
                )
            )
            failed += 1

    return BatchCreateResponse(
        success=failed == 0,
        results=results,
        total=len(body.usernames),
        succeeded=succeeded,
        failed=failed,
    )
