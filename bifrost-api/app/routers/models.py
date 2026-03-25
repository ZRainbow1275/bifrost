"""Model status and availability monitoring endpoints.

Public endpoints (no admin key required) for querying which models are
available across all upstream channels, plus an admin-only test endpoint
that actively probes channel connectivity.
"""

from __future__ import annotations

import asyncio
import logging
import time
from datetime import datetime, timezone
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Path

from ..dependencies import get_newapi_client, require_admin
from ..newapi_client import NewAPIClient, NewAPIError
from ..schemas import (
    ApiResponse,
    ChannelInfo,
    ModelStatus,
    ModelStatusResponse,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1/models", tags=["模型"])


# ------------------------------------------------------------------
# Internal helpers
# ------------------------------------------------------------------


def _parse_models_from_channel(channel: dict[str, Any]) -> list[str]:
    """Extract individual model names from a channel's ``models`` field.

    The ``models`` field is a comma-separated string, e.g.
    ``"gpt-4o,gpt-3.5-turbo,claude-3-opus"``.
    """
    raw = channel.get("models", "")
    if not raw or not isinstance(raw, str):
        return []
    return [m.strip() for m in raw.split(",") if m.strip()]


async def _fetch_all_channels(client: NewAPIClient) -> list[dict[str, Any]]:
    """Fetch every channel by paginating through ``list_channels``."""
    all_channels: list[dict[str, Any]] = []
    page = 0
    page_size = 100
    while True:
        result = await client.list_channels(page=page, page_size=page_size)
        data = result.get("data", [])
        if not data:
            break
        all_channels.extend(data)
        # If fewer items than page_size, we've reached the last page
        if len(data) < page_size:
            break
        page += 1
    return all_channels


def _aggregate_models(
    channels: list[dict[str, Any]],
) -> list[ModelStatus]:
    """Aggregate model info from raw channel dicts.

    Groups by model name, counts how many *enabled* channels provide each,
    and marks availability.
    """
    model_map: dict[str, dict[str, Any]] = {}

    for ch in channels:
        enabled = ch.get("status", 1) == 1
        response_time = ch.get("response_time", 0) or 0
        for model_name in _parse_models_from_channel(ch):
            if model_name not in model_map:
                model_map[model_name] = {
                    "total_channels": 0,
                    "enabled_channels": 0,
                    "latency_sum": 0,
                    "latency_count": 0,
                }
            entry = model_map[model_name]
            entry["total_channels"] += 1
            if enabled:
                entry["enabled_channels"] += 1
            if response_time > 0:
                entry["latency_sum"] += response_time
                entry["latency_count"] += 1

    result: list[ModelStatus] = []
    for name, info in sorted(model_map.items()):
        avg_latency = (
            info["latency_sum"] / info["latency_count"]
            if info["latency_count"] > 0
            else 0
        )
        result.append(
            ModelStatus(
                id=name,
                name=name,
                available=info["enabled_channels"] > 0,
                channels=info["enabled_channels"],
                avg_latency_ms=round(avg_latency, 1),
            )
        )
    return result


# ------------------------------------------------------------------
# Endpoints
# ------------------------------------------------------------------


@router.get(
    "",
    response_model=ModelStatusResponse,
    summary="获取所有可用模型列表",
    description="返回所有渠道中可用模型的聚合状态，包括提供该模型的渠道数量和可用性。",
)
async def list_models(
    client: NewAPIClient = Depends(get_newapi_client),
) -> ModelStatusResponse:
    """Aggregate model availability across all channels."""
    try:
        channels = await _fetch_all_channels(client)
    except NewAPIError as exc:
        logger.error("获取渠道列表失败: %s", exc)
        raise HTTPException(
            status_code=502, detail="无法连接上游服务获取渠道列表"
        ) from exc

    models = _aggregate_models(channels)
    return ModelStatusResponse(
        success=True,
        models=models,
        tested_at=datetime.now(timezone.utc).isoformat(),
    )


@router.get(
    "/test",
    response_model=ModelStatusResponse,
    summary="测试所有渠道的模型可用性",
    description="（管理员）并行测试所有已启用渠道，汇报每个模型的实际可用性和延迟。",
    dependencies=[Depends(require_admin)],
)
async def test_all_models(
    client: NewAPIClient = Depends(get_newapi_client),
) -> ModelStatusResponse:
    """Actively test every enabled channel and aggregate per-model results."""
    try:
        channels = await _fetch_all_channels(client)
    except NewAPIError as exc:
        logger.error("获取渠道列表失败: %s", exc)
        raise HTTPException(
            status_code=502, detail="无法连接上游服务获取渠道列表"
        ) from exc

    enabled_channels = [ch for ch in channels if ch.get("status", 1) == 1]

    # Parallel test all enabled channels
    async def _test_one(ch: dict[str, Any]) -> dict[str, Any]:
        ch_id = ch.get("id", 0)
        start = time.monotonic()
        try:
            result = await client.test_channel(ch_id)
            elapsed_ms = int((time.monotonic() - start) * 1000)
            return {
                "channel": ch,
                "success": result.get("success", False),
                "latency_ms": result.get("time", elapsed_ms),
            }
        except (NewAPIError, Exception) as exc:
            elapsed_ms = int((time.monotonic() - start) * 1000)
            logger.warning("测试渠道 %d 失败: %s", ch_id, exc)
            return {
                "channel": ch,
                "success": False,
                "latency_ms": elapsed_ms,
            }

    test_results = await asyncio.gather(
        *[_test_one(ch) for ch in enabled_channels],
        return_exceptions=True,
    )

    # Aggregate per-model
    model_map: dict[str, dict[str, Any]] = {}
    for result in test_results:
        if isinstance(result, BaseException):
            continue
        ch = result["channel"]
        success = result["success"]
        latency = result["latency_ms"]
        for model_name in _parse_models_from_channel(ch):
            if model_name not in model_map:
                model_map[model_name] = {
                    "available_channels": 0,
                    "total_channels": 0,
                    "latency_sum": 0,
                    "latency_count": 0,
                }
            entry = model_map[model_name]
            entry["total_channels"] += 1
            if success:
                entry["available_channels"] += 1
                entry["latency_sum"] += latency
                entry["latency_count"] += 1

    models: list[ModelStatus] = []
    for name, info in sorted(model_map.items()):
        avg_latency = (
            info["latency_sum"] / info["latency_count"]
            if info["latency_count"] > 0
            else 0
        )
        models.append(
            ModelStatus(
                id=name,
                name=name,
                available=info["available_channels"] > 0,
                channels=info["available_channels"],
                avg_latency_ms=round(avg_latency, 1),
            )
        )

    return ModelStatusResponse(
        success=True,
        models=models,
        tested_at=datetime.now(timezone.utc).isoformat(),
    )


@router.get(
    "/{model_name}/channels",
    response_model=ApiResponse,
    summary="获取提供指定模型的渠道列表",
    description="返回所有包含该模型的渠道信息。",
)
async def get_model_channels(
    model_name: str = Path(..., description="模型名称，例如 gpt-4o"),
    client: NewAPIClient = Depends(get_newapi_client),
) -> ApiResponse:
    """Return channels that serve a specific model."""
    try:
        channels = await _fetch_all_channels(client)
    except NewAPIError as exc:
        logger.error("获取渠道列表失败: %s", exc)
        raise HTTPException(
            status_code=502, detail="无法连接上游服务获取渠道列表"
        ) from exc

    matching: list[dict[str, Any]] = []
    for ch in channels:
        model_names = _parse_models_from_channel(ch)
        if model_name in model_names:
            matching.append(
                ChannelInfo(
                    id=ch.get("id", 0),
                    name=ch.get("name", ""),
                    type=ch.get("type", 1),
                    status=ch.get("status", 1),
                    base_url=ch.get("base_url", ""),
                    models=ch.get("models", ""),
                    test_model=ch.get("test_model", ""),
                    response_time=ch.get("response_time", 0),
                    priority=ch.get("priority", 0),
                ).model_dump()
            )

    if not matching:
        raise HTTPException(
            status_code=404,
            detail=f"未找到提供模型 '{model_name}' 的渠道",
        )

    return ApiResponse(success=True, data=matching)
