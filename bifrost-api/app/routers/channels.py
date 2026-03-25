"""Channel (upstream AI provider) management endpoints.

All endpoints require admin authentication via the ``X-Admin-Key`` header.
Channels represent upstream AI service providers (OpenAI, Anthropic, etc.)
configured in the NewAPI instance.
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Path, Query

from ..dependencies import get_newapi_client, require_admin
from ..newapi_client import NewAPIClient, NewAPIError
from ..schemas import (
    ApiResponse,
    ChannelCreateRequest,
    ChannelInfo,
    ChannelTestResult,
)

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/api/v1/channels",
    tags=["渠道管理"],
    dependencies=[Depends(require_admin)],
)

# Mapping of NewAPI channel type IDs to human-readable provider names
CHANNEL_TYPES: dict[int, str] = {
    1: "OpenAI",
    3: "Azure",
    8: "Custom (OpenAI-compatible)",
    14: "Anthropic",
    15: "Google Gemini",
    24: "DeepSeek",
    28: "Mistral",
    31: "Groq",
    33: "xAI (Grok)",
    40: "Moonshot",
    41: "Baichuan",
    42: "Minimax",
    43: "零一万物 (01.AI)",
    44: "阶跃星辰 (StepFun)",
}


# ------------------------------------------------------------------
# Internal helpers
# ------------------------------------------------------------------


def _mask_key(key: str) -> str:
    """Mask API key, showing only first 4 and last 4 characters."""
    if len(key) <= 12:
        return "***"
    return f"{key[:4]}{'*' * 6}{key[-4:]}"


def _map_channel(raw: dict[str, Any]) -> ChannelInfo:
    """Convert a raw NewAPI channel dict to our ``ChannelInfo`` schema."""
    return ChannelInfo(
        id=raw.get("id", 0),
        name=raw.get("name", ""),
        type=raw.get("type", 1),
        status=raw.get("status", 1),
        key=_mask_key(raw.get("key", "")),
        base_url=raw.get("base_url", ""),
        models=raw.get("models", ""),
        test_model=raw.get("test_model", ""),
        response_time=raw.get("response_time", 0),
        balance=raw.get("balance", 0),
        priority=raw.get("priority", 0),
    )


async def _fetch_all_channels(client: NewAPIClient) -> list[dict[str, Any]]:
    """Paginate through all channels."""
    all_channels: list[dict[str, Any]] = []
    page = 0
    page_size = 100
    while True:
        result = await client.list_channels(page=page, page_size=page_size)
        data = result.get("data", [])
        if not data:
            break
        all_channels.extend(data)
        if len(data) < page_size:
            break
        page += 1
    return all_channels


# ------------------------------------------------------------------
# Endpoints
# ------------------------------------------------------------------


@router.get(
    "/types",
    response_model=ApiResponse,
    summary="获取支持的渠道类型",
    description="返回所有已知的渠道类型映射（类型编号 -> 提供商名称）。",
)
async def get_channel_types() -> ApiResponse:
    """Return the known channel type mapping."""
    return ApiResponse(
        success=True,
        data={"types": {str(k): v for k, v in CHANNEL_TYPES.items()}},
    )


@router.post(
    "/test-all",
    response_model=ApiResponse,
    summary="批量测试所有已启用渠道",
    description="并行测试所有状态为已启用的渠道连通性，返回每个渠道的测试结果。",
)
async def test_all_channels(
    client: NewAPIClient = Depends(get_newapi_client),
) -> ApiResponse:
    """Test all enabled channels in parallel."""
    try:
        channels = await _fetch_all_channels(client)
    except NewAPIError as exc:
        logger.error("获取渠道列表失败: %s", exc)
        if exc.status_code in (401, 403):
            raise HTTPException(status_code=500, detail="NewAPI 管理员令牌无效或已过期，请检查配置") from exc
        raise HTTPException(
            status_code=502, detail="无法连接上游服务获取渠道列表"
        ) from exc

    enabled = [ch for ch in channels if ch.get("status", 1) == 1]
    if not enabled:
        return ApiResponse(success=True, data=[], message="没有已启用的渠道")

    async def _test_one(ch: dict[str, Any]) -> ChannelTestResult:
        ch_id = ch.get("id", 0)
        ch_name = ch.get("name", "")
        start = time.monotonic()
        try:
            result = await client.test_channel(ch_id)
            elapsed_ms = int((time.monotonic() - start) * 1000)
            return ChannelTestResult(
                id=ch_id,
                name=ch_name,
                success=result.get("success", False),
                latency_ms=result.get("time", elapsed_ms),
            )
        except (NewAPIError, Exception) as exc:
            elapsed_ms = int((time.monotonic() - start) * 1000)
            return ChannelTestResult(
                id=ch_id,
                name=ch_name,
                success=False,
                latency_ms=elapsed_ms,
                error=str(exc),
            )

    raw_results = await asyncio.gather(
        *[_test_one(ch) for ch in enabled],
        return_exceptions=True,
    )

    results: list[dict[str, Any]] = []
    for r in raw_results:
        if isinstance(r, BaseException):
            logger.error("渠道测试出现未预期异常: %s", r)
            continue
        results.append(r.model_dump())

    return ApiResponse(success=True, data=results)


@router.get(
    "",
    response_model=ApiResponse,
    summary="获取渠道列表",
    description="分页获取所有渠道信息。",
)
async def list_channels(
    page: int = Query(0, ge=0, description="页码（从 0 开始）"),
    page_size: int = Query(20, ge=1, le=100, description="每页数量"),
    client: NewAPIClient = Depends(get_newapi_client),
) -> ApiResponse:
    """Return a paginated list of channels."""
    try:
        result = await client.list_channels(page=page, page_size=page_size)
    except NewAPIError as exc:
        logger.error("获取渠道列表失败: %s", exc)
        if exc.status_code in (401, 403):
            raise HTTPException(status_code=500, detail="NewAPI 管理员令牌无效或已过期，请检查配置") from exc
        raise HTTPException(
            status_code=502, detail="无法连接上游服务获取渠道列表"
        ) from exc

    raw_channels = result.get("data", [])
    mapped = [_map_channel(ch).model_dump() for ch in raw_channels]
    return ApiResponse(success=True, data=mapped)


@router.post(
    "",
    response_model=ApiResponse,
    summary="创建新渠道",
    description="在上游 NewAPI 中创建一个新的 AI 服务渠道。",
)
async def create_channel(
    body: ChannelCreateRequest,
    client: NewAPIClient = Depends(get_newapi_client),
) -> ApiResponse:
    """Create a new channel in NewAPI."""
    try:
        result = await client.create_channel(
            name=body.name,
            type=body.type,
            key=body.key,
            base_url=body.base_url,
            models=body.models,
            test_model=body.test_model,
        )
    except NewAPIError as exc:
        logger.error("创建渠道失败: %s", exc)
        if exc.status_code in (401, 403):
            raise HTTPException(status_code=500, detail="NewAPI 管理员令牌无效或已过期，请检查配置") from exc
        raise HTTPException(
            status_code=502,
            detail=f"创建渠道失败: {exc.detail or exc}",
        ) from exc

    channel_data = result.get("data", result)
    if isinstance(channel_data, dict):
        channel_data = _map_channel(channel_data).model_dump()

    return ApiResponse(
        success=True,
        data=channel_data,
        message="渠道创建成功",
    )


@router.get(
    "/{channel_id}",
    response_model=ApiResponse,
    summary="获取单个渠道详情",
    description="根据渠道 ID 获取完整的渠道配置信息。",
)
async def get_channel(
    channel_id: int = Path(..., ge=1, description="渠道 ID"),
    client: NewAPIClient = Depends(get_newapi_client),
) -> ApiResponse:
    """Get details for a single channel."""
    try:
        all_channels = await _fetch_all_channels(client)
    except NewAPIError as exc:
        logger.error("获取渠道详情失败: %s", exc)
        if exc.status_code in (401, 403):
            raise HTTPException(status_code=500, detail="NewAPI 管理员令牌无效或已过期，请检查配置") from exc
        raise HTTPException(
            status_code=502, detail="无法连接上游服务"
        ) from exc

    for ch in all_channels:
        if ch.get("id") == channel_id:
            return ApiResponse(
                success=True, data=_map_channel(ch).model_dump()
            )

    raise HTTPException(status_code=404, detail="渠道不存在")


@router.put(
    "/{channel_id}",
    response_model=ApiResponse,
    summary="更新渠道配置",
    description="更新指定渠道的配置字段（名称、密钥、基础 URL、模型列表、状态、优先级等）。",
)
async def update_channel(
    channel_id: int = Path(..., ge=1, description="渠道 ID"),
    name: str | None = None,
    key: str | None = None,
    base_url: str | None = None,
    models: str | None = None,
    status: int | None = None,
    priority: int | None = None,
    test_model: str | None = None,
    client: NewAPIClient = Depends(get_newapi_client),
) -> ApiResponse:
    """Update an existing channel's fields."""
    kwargs: dict[str, Any] = {}
    if name is not None:
        kwargs["name"] = name
    if key is not None:
        kwargs["key"] = key
    if base_url is not None:
        kwargs["base_url"] = base_url
    if models is not None:
        kwargs["models"] = models
    if status is not None:
        kwargs["status"] = status
    if priority is not None:
        kwargs["priority"] = priority
    if test_model is not None:
        kwargs["test_model"] = test_model

    if not kwargs:
        raise HTTPException(status_code=400, detail="未提供任何要更新的字段")

    try:
        result = await client.update_channel(channel_id, **kwargs)
    except NewAPIError as exc:
        logger.error("更新渠道 %d 失败: %s", channel_id, exc)
        if exc.status_code in (401, 403):
            raise HTTPException(status_code=500, detail="NewAPI 管理员令牌无效或已过期，请检查配置") from exc
        raise HTTPException(
            status_code=502,
            detail=f"更新渠道失败: {exc.detail or exc}",
        ) from exc

    return ApiResponse(
        success=True,
        data=result.get("data", result),
        message="渠道更新成功",
    )


@router.delete(
    "/{channel_id}",
    response_model=ApiResponse,
    summary="删除渠道",
    description="从上游 NewAPI 中删除指定渠道。此操作不可逆。",
)
async def delete_channel(
    channel_id: int = Path(..., ge=1, description="渠道 ID"),
    client: NewAPIClient = Depends(get_newapi_client),
) -> ApiResponse:
    """Delete a channel."""
    try:
        await client.delete_channel(channel_id)
    except NewAPIError as exc:
        logger.error("删除渠道 %d 失败: %s", channel_id, exc)
        if exc.status_code in (401, 403):
            raise HTTPException(status_code=500, detail="NewAPI 管理员令牌无效或已过期，请检查配置") from exc
        raise HTTPException(
            status_code=502,
            detail=f"删除渠道失败: {exc.detail or exc}",
        ) from exc

    return ApiResponse(success=True, message=f"渠道 {channel_id} 已删除")


@router.post(
    "/{channel_id}/test",
    response_model=ApiResponse,
    summary="测试单个渠道连通性",
    description="测试指定渠道是否可以正常连接，返回延迟信息。",
)
async def test_channel(
    channel_id: int = Path(..., ge=1, description="渠道 ID"),
    client: NewAPIClient = Depends(get_newapi_client),
) -> ApiResponse:
    """Test connectivity for a single channel."""
    # First, verify the channel exists and get its name
    try:
        channels_result = await client.list_channels(page=0, page_size=100)
    except NewAPIError as exc:
        if exc.status_code in (401, 403):
            raise HTTPException(status_code=500, detail="NewAPI 管理员令牌无效或已过期，请检查配置") from exc
        raise HTTPException(
            status_code=502, detail="无法连接上游服务"
        ) from exc

    channel_name = ""
    for ch in channels_result.get("data", []):
        if ch.get("id") == channel_id:
            channel_name = ch.get("name", "")
            break

    if not channel_name:
        raise HTTPException(
            status_code=404, detail=f"渠道 {channel_id} 不存在"
        )

    start = time.monotonic()
    try:
        result = await client.test_channel(channel_id)
        elapsed_ms = int((time.monotonic() - start) * 1000)
        test_result = ChannelTestResult(
            id=channel_id,
            name=channel_name,
            success=result.get("success", False),
            latency_ms=result.get("time", elapsed_ms),
        )
    except NewAPIError as exc:
        elapsed_ms = int((time.monotonic() - start) * 1000)
        test_result = ChannelTestResult(
            id=channel_id,
            name=channel_name,
            success=False,
            latency_ms=elapsed_ms,
            error=str(exc),
        )

    return ApiResponse(success=True, data=test_result.model_dump())
