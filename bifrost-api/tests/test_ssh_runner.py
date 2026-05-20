from __future__ import annotations

import asyncio
from pathlib import Path
from typing import Any

import pytest
from fastapi import HTTPException

from app.utils.ssh_runner import SshChannel, run_ssh_command


def _channel(key_path: Path) -> SshChannel:
    return SshChannel(
        label="test",
        user="bifrost-test",
        host="10.8.0.2",
        key_path=str(key_path),
        timeout_sec=5,
        missing_key_detail="missing key",
        timeout_detail="timeout",
        unavailable_detail="unavailable",
    )


@pytest.mark.asyncio
async def test_run_ssh_command_missing_key_returns_503(tmp_path):
    with pytest.raises(HTTPException) as exc_info:
        await run_ssh_command(_channel(tmp_path / "missing.key"), "status")

    assert exc_info.value.status_code == 503
    assert exc_info.value.detail == "missing key"


@pytest.mark.asyncio
async def test_run_ssh_command_decodes_output_and_passes_stdin(monkeypatch, tmp_path):
    key = tmp_path / "id_ed25519"
    key.write_text("test-key")
    captured: dict[str, Any] = {}

    class FakeProc:
        returncode = 9

        async def communicate(self, input=None):  # noqa: ANN001
            captured["stdin"] = input
            return b"stdout text\n", "stderr 文本\n".encode("utf-8")

    async def fake_create_subprocess_exec(*args, **kwargs):  # noqa: ANN002, ANN003
        captured["args"] = args
        captured["kwargs"] = kwargs
        return FakeProc()

    monkeypatch.setattr(asyncio, "create_subprocess_exec", fake_create_subprocess_exec)

    result = await run_ssh_command(_channel(key), "upload arg", stdin_bytes=b"payload")

    assert result.returncode == 9
    assert result.stdout == "stdout text\n"
    assert result.stderr == "stderr 文本\n"
    assert captured["stdin"] == b"payload"
    assert captured["args"][-2:] == ("bifrost-test@10.8.0.2", "upload arg")
    assert captured["kwargs"]["stdin"] == asyncio.subprocess.PIPE
