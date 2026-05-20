"""Unit tests for app.routers.marketplace (PR-4 read endpoints).

Coverage strategy:
* Auth: 401 missing X-Admin-Key, 403 wrong key, 503 unconfigured admin_key.
* SSH plumbing: 503 when readonly SSH key file is absent, 504 on timeout,
  502 when readonly-router rejects the verb.
* Validation: 422 for an out-of-pattern service value (FastAPI built-in).
* Happy paths: 200 status / list / disk / logs each with a mocked
  ``_run_readonly_command`` return value that mirrors the real PR-2
  readonly-router output shapes.

Mocks operate exclusively at the module boundary
(``app.routers.marketplace._run_readonly_command`` /
``app.routers.marketplace._probe_http``) so the production handler logic
runs end-to-end, including ApiResponse serialization.
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from app.main import app
from app.routers import marketplace as marketplace_module


client = TestClient(app)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _patch_run_readonly_command(monkeypatch, *, return_value=None, raises=None):
    async def fake(settings, command):  # noqa: D401, ARG001
        if raises is not None:
            raise raises
        return return_value if return_value is not None else ""

    monkeypatch.setattr(marketplace_module, "_run_readonly_command", fake)


def _patch_probe_http(monkeypatch, *, up=True, status_code=200):
    async def fake(url):  # noqa: D401, ARG001
        return {"up": up, "status_code": status_code}

    monkeypatch.setattr(marketplace_module, "_probe_http", fake)


def _make_ssh_key_available(monkeypatch, tmp_path: Path) -> Path:
    """Create a temp file and point Settings.readonly_ssh_key at it.

    Allows ``_ssh_key_path(settings).is_file()`` to return True so we can
    exercise paths that come *after* the SSH-key-missing 503 branch.
    """
    from app import dependencies as deps

    key = tmp_path / "fake.ed25519"
    key.write_text("test-only key contents; never used because subprocess is mocked")
    deps.settings.readonly_ssh_key = str(key)
    return key


# ---------------------------------------------------------------------------
# Auth tests (require_admin contract -- spec section 7.2 error mapping)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "endpoint",
    ["/marketplace/status", "/marketplace/list", "/marketplace/disk", "/marketplace/logs?service=render"],
)
def test_missing_admin_key_header_returns_401(endpoint):
    """All 4 endpoints must require X-Admin-Key (spec section 7.2)."""
    response = client.get(endpoint)
    assert response.status_code == 401
    assert "管理密钥" in response.json()["detail"]


@pytest.mark.parametrize(
    "endpoint",
    ["/marketplace/status", "/marketplace/list", "/marketplace/disk", "/marketplace/logs?service=render"],
)
def test_wrong_admin_key_returns_403(endpoint):
    """Wrong X-Admin-Key value must return 403."""
    response = client.get(endpoint, headers={"X-Admin-Key": "wrong-key"})
    assert response.status_code == 403
    assert "无效" in response.json()["detail"]


def test_admin_key_unconfigured_returns_503():
    """When server admin_key is empty, require_admin returns 503."""
    from app import dependencies as deps

    deps.settings.admin_key = ""
    response = client.get(
        "/marketplace/status", headers={"X-Admin-Key": "test-admin-key"}
    )
    assert response.status_code == 503
    assert "管理密钥" in response.json()["detail"]


# ---------------------------------------------------------------------------
# SSH plumbing tests (mirrors.py-parity error code mapping)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "endpoint",
    ["/marketplace/status", "/marketplace/list", "/marketplace/disk", "/marketplace/logs?service=render"],
)
def test_ssh_key_missing_returns_503(endpoint, monkeypatch):
    """When the readonly SSH key file is absent, return 503.

    /status returns 200 with state_error filled because the probe + state.json
    read are independent; the other endpoints surface 503 directly.
    """
    # The autouse fixture already set readonly_ssh_key to a non-existent path.
    _patch_probe_http(monkeypatch, up=False, status_code=0)
    response = client.get(endpoint, headers={"X-Admin-Key": "test-admin-key"})
    if endpoint == "/marketplace/status":
        assert response.status_code == 200
        body = response.json()["data"]
        assert body["state_error"] is not None
        assert "未配置" in body["state_error"] or "未配置" in str(body)
    else:
        assert response.status_code == 503
        assert "未配置" in response.json()["detail"]


@pytest.mark.parametrize(
    "endpoint",
    ["/marketplace/status", "/marketplace/list", "/marketplace/disk", "/marketplace/logs?service=render"],
)
def test_ssh_timeout_returns_504(endpoint, monkeypatch, tmp_path):
    """Mocking _run_readonly_command to raise HTTPException(504) returns 504.

    /status absorbs 504 into state_error (it's the auxiliary read), other
    endpoints surface 504 directly.
    """
    _make_ssh_key_available(monkeypatch, tmp_path)
    _patch_probe_http(monkeypatch, up=True, status_code=200)
    timeout_exc = HTTPException(status_code=504, detail="Server B 只读 SSH 请求超时")
    _patch_run_readonly_command(monkeypatch, raises=timeout_exc)

    response = client.get(endpoint, headers={"X-Admin-Key": "test-admin-key"})
    if endpoint == "/marketplace/status":
        assert response.status_code == 200
        assert "超时" in response.json()["data"]["state_error"]
    else:
        assert response.status_code == 504
        assert "超时" in response.json()["detail"]


@pytest.mark.parametrize(
    "endpoint",
    ["/marketplace/status", "/marketplace/list", "/marketplace/disk", "/marketplace/logs?service=render"],
)
def test_readonly_router_rejected_returns_502(endpoint, monkeypatch, tmp_path):
    """When readonly-router returns non-zero, _run_readonly_command raises 502."""
    _make_ssh_key_available(monkeypatch, tmp_path)
    _patch_probe_http(monkeypatch, up=True, status_code=200)
    reject_exc = HTTPException(status_code=502, detail="Server B 只读 SSH 命令失败")
    _patch_run_readonly_command(monkeypatch, raises=reject_exc)

    response = client.get(endpoint, headers={"X-Admin-Key": "test-admin-key"})
    if endpoint == "/marketplace/status":
        assert response.status_code == 200
        assert "失败" in response.json()["data"]["state_error"]
    else:
        assert response.status_code == 502
        assert "失败" in response.json()["detail"]


# ---------------------------------------------------------------------------
# Validation tests (422 mapping for log service param)
# ---------------------------------------------------------------------------


def test_logs_out_of_pattern_service_returns_422(monkeypatch, tmp_path):
    """FastAPI Query pattern validator should reject unknown service values."""
    _make_ssh_key_available(monkeypatch, tmp_path)
    response = client.get(
        "/marketplace/logs?service=unknown-foo",
        headers={"X-Admin-Key": "test-admin-key"},
    )
    assert response.status_code == 422


def test_logs_missing_service_returns_422(monkeypatch, tmp_path):
    """``service`` is a required query param."""
    _make_ssh_key_available(monkeypatch, tmp_path)
    response = client.get(
        "/marketplace/logs",
        headers={"X-Admin-Key": "test-admin-key"},
    )
    assert response.status_code == 422


# ---------------------------------------------------------------------------
# Happy paths (200) -- mocked SSH returns realistic readonly-router output
# ---------------------------------------------------------------------------


def test_status_happy_path_returns_state_fields(monkeypatch, tmp_path):
    """marketplace:status SSH output is the JSON body of state.json."""
    _make_ssh_key_available(monkeypatch, tmp_path)
    _patch_probe_http(monkeypatch, up=True, status_code=200)
    state_json = json.dumps(
        {
            "last_render_ts": "2026-05-19T11:30:00+00:00",
            "latest_git_head": "abc123def456",
            "plugin_count": 1,
            "upstream_alert": False,
            "render_script_version": "v1.0.0",
            "upstream_last_check_ts": "2026-05-19T12:00:00+00:00",
        }
    )
    _patch_run_readonly_command(monkeypatch, return_value=state_json)

    response = client.get(
        "/marketplace/status", headers={"X-Admin-Key": "test-admin-key"}
    )
    assert response.status_code == 200
    body = response.json()
    assert body["success"] is True
    data = body["data"]
    assert data["up"] is True
    assert data["status_code"] == 200
    assert data["last_render_ts"] == "2026-05-19T11:30:00+00:00"
    assert data["latest_git_head"] == "abc123def456"
    assert data["plugin_count"] == 1
    assert data["upstream_alert"] is False
    assert data["render_script_version"] == "v1.0.0"
    assert data["upstream_last_check_ts"] == "2026-05-19T12:00:00+00:00"
    assert data["state_error"] is None


def test_status_handles_bad_state_json(monkeypatch, tmp_path):
    """If state.json body is not valid JSON, /status still returns 200."""
    _make_ssh_key_available(monkeypatch, tmp_path)
    _patch_probe_http(monkeypatch, up=False, status_code=0)
    _patch_run_readonly_command(monkeypatch, return_value="not-json-at-all")

    response = client.get(
        "/marketplace/status", headers={"X-Admin-Key": "test-admin-key"}
    )
    assert response.status_code == 200
    data = response.json()["data"]
    assert data["plugin_count"] == 0
    assert data["upstream_alert"] is False
    assert "解析失败" in data["state_error"]


def test_list_happy_path_returns_plugin_array(monkeypatch, tmp_path):
    """marketplace:list-json returns the full .claude-plugin/marketplace.json body."""
    _make_ssh_key_available(monkeypatch, tmp_path)
    marketplace_payload = {
        "name": "bifrost-internal",
        "owner": {"name": "Bifrost Team", "email": "bifrost-admin@uuhfn.cloud"},
        "version": "1.0.0",
        "metadata": {
            "pluginRoot": "./plugins",
            "license_id": "ALL-RIGHTS-RESERVED",
            "git_head_sha": "abc123",
        },
        "plugins": [
            {
                "name": "hello-world-skill",
                "version": "0.1.0",
                "source": "./plugins/hello-world-skill",
                "license": "ALL-RIGHTS-RESERVED",
            }
        ],
    }
    _patch_run_readonly_command(monkeypatch, return_value=json.dumps(marketplace_payload))

    response = client.get(
        "/marketplace/list", headers={"X-Admin-Key": "test-admin-key"}
    )
    assert response.status_code == 200
    body = response.json()
    assert body["success"] is True
    data = body["data"]
    assert isinstance(data["plugins"], list)
    assert len(data["plugins"]) >= 1
    assert data["plugins"][0]["name"] == "hello-world-skill"
    assert data["name"] == "bifrost-internal"
    assert data["version"] == "1.0.0"
    assert data["metadata"]["license_id"] == "ALL-RIGHTS-RESERVED"


def test_list_invalid_json_returns_502(monkeypatch, tmp_path):
    """If marketplace:list-json output is not valid JSON, surface 502."""
    _make_ssh_key_available(monkeypatch, tmp_path)
    _patch_run_readonly_command(monkeypatch, return_value="not valid json {[}")

    response = client.get(
        "/marketplace/list", headers={"X-Admin-Key": "test-admin-key"}
    )
    assert response.status_code == 502
    assert "解析失败" in response.json()["detail"]


def test_list_non_dict_top_level_returns_502(monkeypatch, tmp_path):
    """marketplace.json top level must be an object."""
    _make_ssh_key_available(monkeypatch, tmp_path)
    _patch_run_readonly_command(monkeypatch, return_value="[]")

    response = client.get(
        "/marketplace/list", headers={"X-Admin-Key": "test-admin-key"}
    )
    assert response.status_code == 502
    assert "顶层" in response.json()["detail"]


def test_disk_happy_path_parses_du_output(monkeypatch, tmp_path):
    """marketplace:disk-report is ``du -sh`` over the three marketplace paths."""
    _make_ssh_key_available(monkeypatch, tmp_path)
    du_output = (
        "12M\t/var/lib/git-mirrors/bifrost-internal-plugins.git\n"
        "4.0K\t/var/lib/dist/plugins\n"
        "2.5G\t/var/log/marketplace\n"
    )
    _patch_run_readonly_command(monkeypatch, return_value=du_output)

    response = client.get(
        "/marketplace/disk", headers={"X-Admin-Key": "test-admin-key"}
    )
    assert response.status_code == 200
    data = response.json()["data"]
    assert data["var_lib_git_mirrors_bifrost_internal_plugins_mb"] == 12
    # 4.0K -> max(1, int(4.0/1024)) = max(1, 0) = 1
    assert data["var_lib_dist_plugins_mb"] == 1
    # 2.5G -> int(2.5 * 1024) = 2560
    assert data["var_log_marketplace_mb"] == 2560


def test_disk_unknown_path_lines_ignored(monkeypatch, tmp_path):
    """du -sh lines for paths outside the whitelist must not appear in result."""
    _make_ssh_key_available(monkeypatch, tmp_path)
    du_output = (
        "12M\t/var/lib/git-mirrors/bifrost-internal-plugins.git\n"
        "999G\t/some/other/path\n"
    )
    _patch_run_readonly_command(monkeypatch, return_value=du_output)

    response = client.get(
        "/marketplace/disk", headers={"X-Admin-Key": "test-admin-key"}
    )
    assert response.status_code == 200
    data = response.json()["data"]
    assert data["var_lib_git_mirrors_bifrost_internal_plugins_mb"] == 12
    assert data["var_lib_dist_plugins_mb"] == 0
    assert data["var_log_marketplace_mb"] == 0


def test_logs_render_happy_path(monkeypatch, tmp_path):
    """logs:marketplace-render returns plain-text journalctl tail."""
    _make_ssh_key_available(monkeypatch, tmp_path)
    log_body = "\n".join(
        f"2026-05-19 11:30:{i:02d} marketplace-render line {i}" for i in range(10)
    )
    _patch_run_readonly_command(monkeypatch, return_value=log_body)

    response = client.get(
        "/marketplace/logs?service=render",
        headers={"X-Admin-Key": "test-admin-key"},
    )
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/plain")
    assert "marketplace-render line 0" in response.text
    assert "marketplace-render line 9" in response.text


def test_logs_schema_check_happy_path(monkeypatch, tmp_path):
    """logs:upstream-schema-check returns plain-text journalctl tail."""
    _make_ssh_key_available(monkeypatch, tmp_path)
    log_body = "LICENSE-OK abcdef0123456789\nUPSTREAM-CHANGED deadbeef\n"
    _patch_run_readonly_command(monkeypatch, return_value=log_body)

    response = client.get(
        "/marketplace/logs?service=schema-check&tail=50",
        headers={"X-Admin-Key": "test-admin-key"},
    )
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/plain")
    assert "LICENSE-OK" in response.text
    assert "UPSTREAM-CHANGED" in response.text


def test_logs_admin_audit_happy_path(monkeypatch, tmp_path):
    """logs:admin-audit returns plain-text audit tail."""
    _make_ssh_key_available(monkeypatch, tmp_path)
    log_body = '{"action":"upload","success":true}\n{"action":"curate","success":true}\n'
    _patch_run_readonly_command(monkeypatch, return_value=log_body)

    response = client.get(
        "/marketplace/logs?service=admin-audit&tail=50",
        headers={"X-Admin-Key": "test-admin-key"},
    )
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/plain")
    assert '"action":"upload"' in response.text
    assert '"action":"curate"' in response.text


def test_logs_tail_truncates_when_lines_exceed_request(monkeypatch, tmp_path):
    """When the upstream output has more lines than ``tail``, output is sliced."""
    _make_ssh_key_available(monkeypatch, tmp_path)
    log_body = "\n".join(f"line-{i}" for i in range(50))
    _patch_run_readonly_command(monkeypatch, return_value=log_body)

    response = client.get(
        "/marketplace/logs?service=render&tail=5",
        headers={"X-Admin-Key": "test-admin-key"},
    )
    assert response.status_code == 200
    # _tail_text emits the last N lines joined by newline + trailing newline
    returned_lines = [ln for ln in response.text.splitlines() if ln]
    assert returned_lines == [f"line-{i}" for i in range(45, 50)]
