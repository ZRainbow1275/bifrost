"""Read-only observability endpoints for Server B private mirrors."""

from __future__ import annotations

import asyncio
import logging
from pathlib import Path
from typing import Any

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import PlainTextResponse

from ..config import Settings
from ..dependencies import get_settings, require_admin
from ..schemas import ApiResponse

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/mirrors",
    tags=["镜像源"],
    dependencies=[Depends(require_admin)],
)

_HTTP_TIMEOUT_SECONDS = 3.0
_LOG_SERVICE_COMMANDS: dict[str, str] = {
    "verdaccio": "logs:verdaccio",
    "new-api": "logs:new-api",
    "newapi": "logs:new-api",
    "git-sync": "logs:git-mirror",
    "git-mirror": "logs:git-mirror",
}


async def _probe_http(url: str) -> dict[str, Any]:
    """Return a non-throwing HTTP probe result for a private mirror URL."""
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(_HTTP_TIMEOUT_SECONDS)) as client:
            response = await client.get(url)
        return {
            "up": response.status_code < 500,
            "status_code": response.status_code,
        }
    except httpx.HTTPError as exc:
        logger.info("Mirror probe failed for %s: %s", url, exc)
        return {"up": False, "status_code": 0}


def _ssh_key_path(settings: Settings) -> Path:
    return Path(settings.readonly_ssh_key)


async def _run_readonly_command(settings: Settings, command: str) -> str:
    """Run a whitelisted forced-command SSH action against Server B."""
    key_path = _ssh_key_path(settings)
    if not key_path.is_file():
        raise HTTPException(
            status_code=503,
            detail="Server B 只读 SSH 通道未配置",
        )

    ssh_target = f"{settings.readonly_user}@{settings.server_b_wg_ip}"
    ssh_args = [
        "ssh",
        "-i",
        str(key_path),
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        "ConnectTimeout=5",
        ssh_target,
        command,
    ]

    try:
        proc = await asyncio.create_subprocess_exec(
            *ssh_args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(
            proc.communicate(),
            timeout=settings.readonly_ssh_timeout_sec,
        )
    except TimeoutError as exc:
        raise HTTPException(status_code=504, detail="Server B 只读 SSH 请求超时") from exc
    except OSError as exc:
        logger.warning("Unable to run readonly SSH command: %s", exc)
        raise HTTPException(status_code=503, detail="Server B 只读 SSH 通道不可用") from exc

    if proc.returncode != 0:
        logger.warning(
            "Readonly SSH command failed: command=%s code=%s stderr=%s",
            command,
            proc.returncode,
            stderr.decode("utf-8", errors="replace")[:300],
        )
        raise HTTPException(status_code=502, detail="Server B 只读 SSH 命令失败")

    return stdout.decode("utf-8", errors="replace")


def _tail_text(text: str, tail: int) -> str:
    lines = text.splitlines()
    if len(lines) <= tail:
        return text
    return "\n".join(lines[-tail:]) + "\n"


def _size_to_mb(raw_size: str) -> int:
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


def _parse_disk_report(report: str) -> dict[str, int]:
    path_to_key = {
        "/var/lib/verdaccio": "verdaccio_storage_mb",
        "/var/lib/new-api-pg": "newapi_pg_mb",
        "/var/lib/new-api-redis": "newapi_redis_mb",
        "/var/lib/git-mirrors": "git_mirrors_mb",
        "/var/lib/dist": "dist_mb",
    }
    parsed: dict[str, int] = {key: 0 for key in path_to_key.values()}

    for line in report.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        size, path = parts[0], parts[-1]
        key = path_to_key.get(path)
        if key:
            parsed[key] = _size_to_mb(size)
    return parsed


@router.get("/status", response_model=ApiResponse)
async def mirrors_status(
    settings: Settings = Depends(get_settings),
) -> ApiResponse:
    """Return read-only health for private distribution services on Server B."""
    base = f"http://{settings.server_b_wg_ip}"
    verdaccio, newapi, files, git = await asyncio.gather(
        _probe_http(f"{base}:4873/-/ping"),
        _probe_http(f"{base}:3000/api/status"),
        _probe_http(f"{base}:8081/"),
        _probe_http(f"{base}:8082/git/claude-for-legal-zh.git/info/refs?service=git-upload-pack"),
    )

    ssh_configured = _ssh_key_path(settings).is_file()
    wg_link: dict[str, Any] = {"ssh_configured": ssh_configured}
    if ssh_configured:
        try:
            wg_link["latest_handshakes"] = await _run_readonly_command(settings, "wg:age")
        except HTTPException as exc:
            wg_link["error"] = exc.detail

    return ApiResponse(
        success=True,
        data={
            "verdaccio": {
                "up": verdaccio["up"],
                "url": "https://npm.uuhfn.cloud/",
                "status_code": verdaccio["status_code"],
            },
            "newapi": {
                "up": newapi["up"],
                "url": "https://api.uuhfn.cloud/",
                "status_code": newapi["status_code"],
            },
            "files": {
                "up": files["up"],
                "url": "https://files.uuhfn.cloud/",
                "status_code": files["status_code"],
            },
            "git_mirror_claude_for_legal_zh": {
                "up": git["up"],
                "url": "https://files.uuhfn.cloud/git/claude-for-legal-zh.git",
                "status_code": git["status_code"],
            },
            "wg_link": wg_link,
        },
    )


@router.get("/logs", response_class=PlainTextResponse)
async def mirrors_logs(
    service: str = Query(..., pattern="^(verdaccio|new-api|newapi|git-sync|git-mirror)$"),
    tail: int = Query(200, ge=1, le=1000),
    settings: Settings = Depends(get_settings),
) -> PlainTextResponse:
    """Return tailed logs through the Server B forced-command SSH router."""
    command = _LOG_SERVICE_COMMANDS.get(service)
    if command is None:
        raise HTTPException(status_code=422, detail="Unsupported mirror log service")
    output = await _run_readonly_command(settings, command)
    return PlainTextResponse(_tail_text(output, tail))


@router.get("/disk", response_model=ApiResponse)
async def mirrors_disk(
    settings: Settings = Depends(get_settings),
) -> ApiResponse:
    """Return disk usage for Server B distribution data directories."""
    output = await _run_readonly_command(settings, "disk:report")
    return ApiResponse(success=True, data=_parse_disk_report(output))
