"""Shared SSH subprocess runner for Server B forced-command channels."""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from pathlib import Path

from fastapi import HTTPException

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class SshChannel:
    """Connection and error-message contract for one SSH channel."""

    label: str
    user: str
    host: str
    key_path: str
    timeout_sec: int
    missing_key_detail: str
    timeout_detail: str
    unavailable_detail: str


@dataclass(frozen=True)
class SshCommandResult:
    """Decoded SSH command result."""

    returncode: int
    stdout: str
    stderr: str


async def run_ssh_command(
    channel: SshChannel,
    remote_command: str,
    *,
    stdin_bytes: bytes | None = None,
) -> SshCommandResult:
    """Run a forced-command SSH action and return decoded output.

    This helper intentionally does not interpret non-zero return codes. Read
    and write routers keep their own business-specific HTTP mapping.
    """
    key_path = Path(channel.key_path)
    if not key_path.is_file():
        raise HTTPException(status_code=503, detail=channel.missing_key_detail)

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
        f"{channel.user}@{channel.host}",
        remote_command,
    ]

    try:
        proc = await asyncio.create_subprocess_exec(
            *ssh_args,
            stdin=asyncio.subprocess.PIPE if stdin_bytes is not None else None,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout_bytes, stderr_bytes = await asyncio.wait_for(
            proc.communicate(input=stdin_bytes),
            timeout=channel.timeout_sec,
        )
    except TimeoutError as exc:
        raise HTTPException(status_code=504, detail=channel.timeout_detail) from exc
    except OSError as exc:
        logger.warning("Unable to run %s SSH command: %s", channel.label, exc)
        raise HTTPException(status_code=503, detail=channel.unavailable_detail) from exc

    return SshCommandResult(
        returncode=proc.returncode if proc.returncode is not None else -1,
        stdout=stdout_bytes.decode("utf-8", errors="replace"),
        stderr=stderr_bytes.decode("utf-8", errors="replace"),
    )
