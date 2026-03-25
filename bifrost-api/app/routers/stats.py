"""Usage statistics and system overview endpoints.

All endpoints require admin authentication.  Data is aggregated from the
upstream NewAPI instance's user, channel, and log APIs.
"""

from __future__ import annotations

import logging
import time
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Query

from ..dependencies import get_newapi_client, require_admin
from ..newapi_client import NewAPIClient, NewAPIError
from ..schemas import ApiResponse, UserUsage, UsageStats

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/api/v1/stats",
    tags=["统计"],
    dependencies=[Depends(require_admin)],
)


# ------------------------------------------------------------------
# Internal helpers
# ------------------------------------------------------------------


async def _fetch_all_pages(
    fetch_fn: Any,
    *,
    page_size: int = 100,
) -> list[dict[str, Any]]:
    """Generic paginator that collects all records from a NewAPI list endpoint.

    ``fetch_fn`` must accept ``page`` and ``page_size`` kwargs and return a
    dict with a ``"data"`` key containing a list.
    """
    all_items: list[dict[str, Any]] = []
    page = 0
    while True:
        result = await fetch_fn(page=page, page_size=page_size)
        data = result.get("data", [])
        if not data:
            break
        all_items.extend(data)
        if len(data) < page_size:
            break
        page += 1
    return all_items


# ------------------------------------------------------------------
# Endpoints
# ------------------------------------------------------------------


@router.get(
    "/overview",
    response_model=ApiResponse,
    summary="系统总览统计",
    description="返回系统级的聚合统计，包括用户总数、活跃用户、渠道总数、活跃渠道、可用模型数量等。",
)
async def stats_overview(
    client: NewAPIClient = Depends(get_newapi_client),
) -> ApiResponse:
    """Aggregate high-level system statistics."""
    try:
        all_users = await _fetch_all_pages(client.list_users)
        all_channels = await _fetch_all_pages(client.list_channels)
    except NewAPIError as exc:
        logger.error("获取系统统计失败: %s", exc)
        if exc.status_code in (401, 403):
            raise HTTPException(status_code=500, detail="NewAPI 管理员令牌无效或已过期，请检查配置") from exc
        raise HTTPException(
            status_code=502, detail="无法连接上游服务获取统计数据"
        ) from exc

    active_users = [u for u in all_users if u.get("status", 1) == 1]
    active_channels = [ch for ch in all_channels if ch.get("status", 1) == 1]

    # Collect unique model names across all channels
    model_set: set[str] = set()
    for ch in all_channels:
        raw_models = ch.get("models", "")
        if raw_models and isinstance(raw_models, str):
            for m in raw_models.split(","):
                stripped = m.strip()
                if stripped:
                    model_set.add(stripped)

    total_requests = sum(u.get("request_count", 0) for u in all_users)
    total_quota_used = sum(u.get("used_quota", 0) for u in all_users)

    stats = UsageStats(
        total_requests=total_requests,
        total_tokens=0,  # NewAPI does not expose token counts at user level
        total_quota_used=total_quota_used,
        active_users=len(active_users),
        active_channels=len(active_channels),
        models_available=len(model_set),
    )

    overview: dict[str, Any] = stats.model_dump()
    overview["total_users"] = len(all_users)
    overview["total_channels"] = len(all_channels)

    return ApiResponse(success=True, data=overview)


@router.get(
    "/usage",
    response_model=ApiResponse,
    summary="使用量统计",
    description="获取指定时间范围内的使用量数据。可按用户筛选。",
)
async def stats_usage(
    days: int = Query(7, ge=1, le=365, description="统计天数"),
    user_id: int | None = Query(None, ge=1, description="按用户 ID 筛选"),
    client: NewAPIClient = Depends(get_newapi_client),
) -> ApiResponse:
    """Return usage data for the given time window."""
    now_ts = int(time.time())
    start_ts = now_ts - days * 86400

    try:
        logs_result = await client.get_logs(
            page=0,
            page_size=100,
            start_timestamp=start_ts,
            end_timestamp=now_ts,
            user_id=user_id,
        )
    except NewAPIError as exc:
        logger.error("获取使用统计失败: %s", exc)
        if exc.status_code in (401, 403):
            raise HTTPException(status_code=500, detail="NewAPI 管理员令牌无效或已过期，请检查配置") from exc
        raise HTTPException(
            status_code=502, detail="无法连接上游服务获取日志数据"
        ) from exc

    log_entries = logs_result.get("data", [])

    # Aggregate per-model usage from logs
    model_usage: dict[str, dict[str, int]] = {}
    total_requests = 0
    total_tokens = 0
    total_quota = 0

    for entry in log_entries:
        model_name = entry.get("model_name", "unknown")
        tokens = entry.get("token_used", 0) or entry.get("quota", 0)
        quota = entry.get("quota", 0)

        if model_name not in model_usage:
            model_usage[model_name] = {
                "requests": 0,
                "tokens": 0,
                "quota": 0,
            }
        model_usage[model_name]["requests"] += 1
        model_usage[model_name]["tokens"] += tokens
        model_usage[model_name]["quota"] += quota

        total_requests += 1
        total_tokens += tokens
        total_quota += quota

    return ApiResponse(
        success=True,
        data={
            "days": days,
            "user_id": user_id,
            "total_requests": total_requests,
            "total_tokens": total_tokens,
            "total_quota": total_quota,
            "by_model": model_usage,
        },
    )


@router.get(
    "/top-users",
    response_model=ApiResponse,
    summary="使用量 Top 用户",
    description="按已用配额降序排列，返回使用量最高的用户列表。",
)
async def stats_top_users(
    limit: int = Query(10, ge=1, le=100, description="返回数量"),
    client: NewAPIClient = Depends(get_newapi_client),
) -> ApiResponse:
    """Return top users sorted by quota usage."""
    try:
        all_users = await _fetch_all_pages(client.list_users)
    except NewAPIError as exc:
        logger.error("获取用户列表失败: %s", exc)
        if exc.status_code in (401, 403):
            raise HTTPException(status_code=500, detail="NewAPI 管理员令牌无效或已过期，请检查配置") from exc
        raise HTTPException(
            status_code=502, detail="无法连接上游服务获取用户数据"
        ) from exc

    # Sort by used_quota descending
    sorted_users = sorted(
        all_users,
        key=lambda u: u.get("used_quota", 0),
        reverse=True,
    )[:limit]

    top: list[dict[str, Any]] = []
    for u in sorted_users:
        quota = u.get("quota", 0)
        used = u.get("used_quota", 0)
        usage_pct = (used / quota * 100) if quota > 0 else 0

        top.append(
            UserUsage(
                username=u.get("username", ""),
                request_count=u.get("request_count", 0),
                quota=quota,
                used_quota=used,
                usage_percent=round(usage_pct, 2),
            ).model_dump()
        )

    return ApiResponse(success=True, data=top)


@router.get(
    "/top-models",
    response_model=ApiResponse,
    summary="最常用模型排行",
    description="根据日志聚合统计，返回使用频率最高的模型列表。",
)
async def stats_top_models(
    limit: int = Query(10, ge=1, le=100, description="返回数量"),
    client: NewAPIClient = Depends(get_newapi_client),
) -> ApiResponse:
    """Return most-used models by request count from log stats."""
    try:
        stat_result = await client.get_log_stat()
    except NewAPIError as exc:
        logger.error("获取日志统计失败: %s", exc)
        if exc.status_code in (401, 403):
            raise HTTPException(status_code=500, detail="NewAPI 管理员令牌无效或已过期，请检查配置") from exc
        raise HTTPException(
            status_code=502, detail="无法连接上游服务获取日志统计"
        ) from exc

    # NewAPI log/stat may return different shapes; handle gracefully
    raw_data = stat_result.get("data", stat_result)
    model_stats: list[dict[str, Any]] = []

    if isinstance(raw_data, list):
        # Each item may represent a model's stats
        for item in raw_data:
            if isinstance(item, dict) and item.get("model_name"):
                model_stats.append({
                    "model": item["model_name"],
                    "requests": item.get("request_count", 0),
                    "tokens": item.get("token_used", 0),
                    "quota": item.get("quota", 0),
                })
    elif isinstance(raw_data, dict):
        # May be keyed by model name or contain a nested list
        models_data = raw_data.get("models", raw_data)
        if isinstance(models_data, dict):
            for model_name, info in models_data.items():
                if isinstance(info, dict):
                    model_stats.append({
                        "model": model_name,
                        "requests": info.get("request_count", 0),
                        "tokens": info.get("token_used", 0),
                        "quota": info.get("quota", 0),
                    })
                elif isinstance(info, (int, float)):
                    model_stats.append({
                        "model": model_name,
                        "requests": int(info),
                        "tokens": 0,
                        "quota": 0,
                    })
        elif isinstance(models_data, list):
            for item in models_data:
                if isinstance(item, dict) and item.get("model_name"):
                    model_stats.append({
                        "model": item["model_name"],
                        "requests": item.get("request_count", 0),
                        "tokens": item.get("token_used", 0),
                        "quota": item.get("quota", 0),
                    })

    # Sort by request count descending and limit
    model_stats.sort(key=lambda m: m.get("requests", 0), reverse=True)
    model_stats = model_stats[:limit]

    return ApiResponse(success=True, data=model_stats)
