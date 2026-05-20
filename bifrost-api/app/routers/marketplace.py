"""Read-only observability endpoints for Server B Claude marketplace.

Implements spec.md section 7.2 read endpoints (PR-4). Mirrors the pattern of
bifrost-api/app/routers/mirrors.py so that auth (require_admin), SSH plumbing
(_run_readonly_command) and HTTP probing (_probe_http) behave identically.

The SSH commands shelled out here are PR-2 whitelisted forced-command arms
of scripts/bifrost-readonly-router.sh:

* marketplace:status         -> cat /var/lib/dist/plugins/state.json
* marketplace:list-json      -> git show HEAD:.claude-plugin/marketplace.json
* marketplace:disk-report    -> du -sh over the three marketplace paths
* logs:marketplace-render    -> journalctl -u marketplace-render.service
* logs:upstream-schema-check -> journalctl -u upstream-schema-check.service
* logs:admin-audit           -> tail -n 200 /var/log/marketplace/admin-audit.log
"""

from __future__ import annotations

import json
import logging
from typing import Any

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import PlainTextResponse

from ..config import Settings
from ..dependencies import get_settings, require_admin
from ..schemas import ApiResponse
from ..utils.ssh_runner import SshChannel, run_ssh_command

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/marketplace",
    tags=["内部 Marketplace"],
    dependencies=[Depends(require_admin)],
)

_HTTP_TIMEOUT_SECONDS = 3.0

_LOG_SERVICE_COMMANDS: dict[str, str] = {
    "render": "logs:marketplace-render",
    "schema-check": "logs:upstream-schema-check",
    "admin-audit": "logs:admin-audit",
}

_DISK_PATH_TO_KEY: dict[str, str] = {
    "/var/lib/git-mirrors/bifrost-internal-plugins.git": "var_lib_git_mirrors_bifrost_internal_plugins_mb",
    "/var/lib/dist/plugins": "var_lib_dist_plugins_mb",
    "/var/log/marketplace": "var_log_marketplace_mb",
}


async def _probe_http(url: str) -> dict[str, Any]:
    """Return a non-throwing HTTP probe result for a marketplace URL."""
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(_HTTP_TIMEOUT_SECONDS)) as client:
            response = await client.get(url)
        return {
            "up": response.status_code < 500,
            "status_code": response.status_code,
        }
    except httpx.HTTPError as exc:
        logger.info("Marketplace probe failed for %s: %s", url, exc)
        return {"up": False, "status_code": 0}


async def _run_readonly_command(settings: Settings, command: str) -> str:
    """Run a whitelisted forced-command SSH action against Server B."""
    result = await run_ssh_command(
        SshChannel(
            label="readonly",
            user=settings.readonly_user,
            host=settings.server_b_wg_ip,
            key_path=settings.readonly_ssh_key,
            timeout_sec=settings.readonly_ssh_timeout_sec,
            missing_key_detail="Server B 只读 SSH 通道未配置",
            timeout_detail="Server B 只读 SSH 请求超时",
            unavailable_detail="Server B 只读 SSH 通道不可用",
        ),
        command,
    )

    if result.returncode != 0:
        logger.warning(
            "Readonly SSH command failed: command=%s code=%s stderr=%s",
            command,
            result.returncode,
            result.stderr[:300],
        )
        raise HTTPException(status_code=502, detail="Server B 只读 SSH 命令失败")

    return result.stdout


def _tail_text(text: str, tail: int) -> str:
    lines = text.splitlines()
    if len(lines) <= tail:
        return text
    return "\n".join(lines[-tail:]) + "\n"


def _size_to_mb(raw_size: str) -> int:
    """Convert a du -sh size token (e.g. 42M) to integer megabytes.

    Mirrors routers.mirrors._size_to_mb so the two routers stay in sync.
    """
    value = raw_size.strip()
    if not value:
        return 0
    suffix = value[-1].upper()
    number_text = value[:-1] if suffix in {"K", "M", "G", "T"} else value
    try:
        number = float(number_text)
    except ValueError:
        return 0

    if suffix == "K":
        return max(1, int(number / 1024))
    if suffix == "M":
        return int(number)
    if suffix == "G":
        return int(number * 1024)
    if suffix == "T":
        return int(number * 1024 * 1024)
    return max(1, int(number / (1024 * 1024)))


def _parse_marketplace_disk(report: str) -> dict[str, int]:
    """Parse marketplace:disk-report (du -sh over 3 marketplace paths)."""
    parsed: dict[str, int] = {key: 0 for key in _DISK_PATH_TO_KEY.values()}
    for line in report.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        size, path = parts[0], parts[-1]
        key = _DISK_PATH_TO_KEY.get(path)
        if key:
            parsed[key] = _size_to_mb(size)
    return parsed


@router.get("/status", response_model=ApiResponse)
async def marketplace_status(
    settings: Settings = Depends(get_settings),
) -> ApiResponse:
    """Return read-only marketplace health + render state for Server B."""
    base = f"http://{settings.server_b_wg_ip}"
    probe = await _probe_http(f"{base}:8081/plugins/state.json")

    state_data: dict[str, Any] = {}
    state_error: str | None = None
    try:
        raw = await _run_readonly_command(settings, "marketplace:status")
    except HTTPException as exc:
        state_error = exc.detail if isinstance(exc.detail, str) else str(exc.detail)
    else:
        if raw.strip():
            try:
                parsed = json.loads(raw)
                if isinstance(parsed, dict):
                    state_data = parsed
                else:
                    state_error = "state.json 顶层不是对象"
            except json.JSONDecodeError as exc:
                logger.warning("Failed to decode state.json: %s", exc)
                state_error = "state.json 解析失败"

    return ApiResponse(
        success=True,
        data={
            "up": probe["up"],
            "status_code": probe["status_code"],
            "last_render_ts": state_data.get("last_render_ts"),
            "latest_git_head": state_data.get("latest_git_head"),
            "plugin_count": state_data.get("plugin_count", 0),
            "upstream_alert": state_data.get("upstream_alert", False),
            "upstream_last_check_ts": state_data.get("upstream_last_check_ts"),
            "render_script_version": state_data.get("render_script_version"),
            "state_error": state_error,
        },
    )


@router.get("/list", response_model=ApiResponse)
async def marketplace_list(
    settings: Settings = Depends(get_settings),
) -> ApiResponse:
    """Return the rendered .claude-plugin/marketplace.json plugin list."""
    raw = await _run_readonly_command(settings, "marketplace:list-json")
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        logger.warning("marketplace.json decode failed: %s", exc)
        raise HTTPException(status_code=502, detail="marketplace.json 解析失败") from exc

    if not isinstance(parsed, dict):
        raise HTTPException(status_code=502, detail="marketplace.json 顶层不是对象")

    plugins = parsed.get("plugins", [])
    if not isinstance(plugins, list):
        raise HTTPException(status_code=502, detail="marketplace.json 的 plugins 字段不是数组")

    return ApiResponse(
        success=True,
        data={
            "plugins": plugins,
            "name": parsed.get("name"),
            "version": parsed.get("version"),
            "metadata": parsed.get("metadata"),
        },
    )


@router.get("/disk", response_model=ApiResponse)
async def marketplace_disk(
    settings: Settings = Depends(get_settings),
) -> ApiResponse:
    """Return disk usage for the three marketplace data directories."""
    output = await _run_readonly_command(settings, "marketplace:disk-report")
    return ApiResponse(success=True, data=_parse_marketplace_disk(output))


@router.get("/logs", response_class=PlainTextResponse)
async def marketplace_logs(
    service: str = Query(..., pattern="^(render|schema-check|admin-audit)$"),
    tail: int = Query(200, ge=1, le=1000),
    settings: Settings = Depends(get_settings),
) -> PlainTextResponse:
    """Return tailed marketplace logs through the readonly-router SSH channel.
    """
    command = _LOG_SERVICE_COMMANDS.get(service)
    if command is None:
        raise HTTPException(
            status_code=422,
            detail="日志服务暂未支持（PR-5a 上线后启用）",
        )
    output = await _run_readonly_command(settings, command)
    return PlainTextResponse(_tail_text(output, tail))
