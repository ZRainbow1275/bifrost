"""Unit tests for app.routers.marketplace_admin (PR-5a write endpoints).

Coverage strategy mirrors test_marketplace_router.py:
* Auth: 401 missing X-Admin-Key, 403 wrong key, 503 unconfigured admin_key.
* SSH plumbing: 503 when admin SSH key file is absent, 504 on timeout,
  502 when admin-router returns exit 2 (forbidden), 409 when exit 9
  (tag/version conflict), 502 for unmapped non-zero exit codes.
* Validation: 422 for oversized tarball (> 50MB), 422 for malformed manifest
  (missing required keys, empty stream, non-mapping YAML), 422 for plugin
  slug containing forbidden characters.
* Happy paths: 200 for each of upload / approve / curate / rerender with a
  mocked ``_run_admin_command`` returning ``(0, stdout, stderr)``; verifies
  audit_id round-trips through the response body for approve/curate/rerender,
  and tag_created is correctly assembled for upload.

Mocks operate at the module boundary (``marketplace_admin_module._run_admin_command``)
so the production handler logic -- including request parsing, manifest
validation, tarball-size checks and the response shape -- runs end-to-end.
"""

from __future__ import annotations

import io
import json
from pathlib import Path

import pytest
import yaml
from fastapi import HTTPException
from fastapi.testclient import TestClient

from app.main import app
from app.routers import marketplace_admin as marketplace_admin_module


client = TestClient(app)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _patch_run_admin_command(monkeypatch, *, return_value=None, raises=None):
    async def fake(settings, verb, args=None, stdin_bytes=None):
        if raises is not None:
            raise raises
        if return_value is not None:
            return return_value
        return (0, "", "")

    monkeypatch.setattr(marketplace_admin_module, "_run_admin_command", fake)


def _make_admin_key_available(monkeypatch, tmp_path: Path) -> Path:
    """Create a temp file and point Settings.admin_ssh_key at it."""
    from app import dependencies as deps

    key = tmp_path / "admin-fake.ed25519"
    key.write_text("test-only key contents; never used because subprocess is mocked")
    deps.settings.admin_ssh_key = str(key)
    return key


def _valid_manifest_bytes(name: str = "hello-world-skill", version: str = "0.2.0") -> bytes:
    """A minimally valid manifest.yaml payload that passes _validate_manifest."""
    payload = {
        "name": name,
        "version": version,
        "description": "test manifest",
        "license_id": "ALL-RIGHTS-RESERVED",
        "maintainers": [{"name": "Alice", "email": "alice@example.com"}],
        "requires": {
            "claude_code_min_version": "2.1.0",
            "os": ["linux", "darwin", "windows"],
        },
        "permissions": {
            "declared_hooks": [],
            "declared_mcp_servers": [],
            "declared_skills": ["hello"],
        },
    }
    return yaml.safe_dump(payload).encode("utf-8")


def _upload_files(
    tarball_bytes: bytes = b"fake tarball payload",
    manifest_bytes: bytes | None = None,
    tarball_filename: str = "hello-world-skill-v0.2.0.tar.gz",
):
    if manifest_bytes is None:
        manifest_bytes = _valid_manifest_bytes()
    return {
        "tarball": (tarball_filename, io.BytesIO(tarball_bytes), "application/gzip"),
        "manifest": ("manifest.yaml", io.BytesIO(manifest_bytes), "application/x-yaml"),
    }


# ---------------------------------------------------------------------------
# Auth tests (require_admin contract)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "endpoint",
    [
        "/marketplace/admin/upload",
        "/marketplace/admin/approve",
        "/marketplace/admin/curate",
        "/marketplace/admin/rerender",
    ],
)
def test_missing_admin_key_header_returns_401(endpoint):
    """All 4 admin endpoints must require X-Admin-Key (spec section 7.2)."""
    if endpoint == "/marketplace/admin/upload":
        response = client.post(endpoint, files=_upload_files())
    else:
        response = client.post(endpoint, json={"plugin": "x", "version": "1.0.0", "decision": "approve", "action": "feature"})
    assert response.status_code == 401, response.text
    assert "管理密钥" in response.json()["detail"]


@pytest.mark.parametrize(
    "endpoint,payload",
    [
        ("/marketplace/admin/upload", None),
        ("/marketplace/admin/approve", {"plugin": "x", "version": "1.0.0", "decision": "approve"}),
        ("/marketplace/admin/curate", {"plugin": "x", "action": "feature"}),
        ("/marketplace/admin/rerender", None),
    ],
)
def test_wrong_admin_key_returns_403(endpoint, payload):
    """Wrong X-Admin-Key value must return 403."""
    headers = {"X-Admin-Key": "wrong-key"}
    if endpoint == "/marketplace/admin/upload":
        response = client.post(endpoint, files=_upload_files(), headers=headers)
    elif payload is None:
        response = client.post(endpoint, headers=headers)
    else:
        response = client.post(endpoint, json=payload, headers=headers)
    assert response.status_code == 403, response.text
    assert "无效" in response.json()["detail"]


def test_admin_key_unconfigured_returns_503():
    """When the service has no admin_key configured, require_admin returns 503."""
    from app import dependencies as deps

    deps.settings.admin_key = ""
    response = client.post(
        "/marketplace/admin/rerender",
        headers={"X-Admin-Key": "test-admin-key"},
    )
    assert response.status_code == 503
    assert "管理密钥" in response.json()["detail"]


# ---------------------------------------------------------------------------
# SSH plumbing tests
# ---------------------------------------------------------------------------


def test_admin_ssh_key_missing_returns_503_for_rerender(monkeypatch):
    """When the admin SSH key file is absent, return 503 (rerender)."""
    # autouse fixture set admin_ssh_key to a non-existent path
    response = client.post(
        "/marketplace/admin/rerender",
        headers={"X-Admin-Key": "test-admin-key"},
    )
    assert response.status_code == 503
    assert "管理 SSH" in response.json()["detail"]


def test_admin_ssh_key_missing_returns_503_for_approve(monkeypatch):
    response = client.post(
        "/marketplace/admin/approve",
        headers={"X-Admin-Key": "test-admin-key"},
        json={"plugin": "hello", "version": "0.1.0", "decision": "approve"},
    )
    assert response.status_code == 503


def test_admin_ssh_key_missing_returns_503_for_curate(monkeypatch):
    response = client.post(
        "/marketplace/admin/curate",
        headers={"X-Admin-Key": "test-admin-key"},
        json={"plugin": "hello", "action": "feature"},
    )
    assert response.status_code == 503


def test_admin_ssh_key_missing_returns_503_for_upload(monkeypatch):
    response = client.post(
        "/marketplace/admin/upload",
        headers={"X-Admin-Key": "test-admin-key"},
        files=_upload_files(),
    )
    assert response.status_code == 503


def test_admin_ssh_timeout_returns_504(monkeypatch, tmp_path):
    _make_admin_key_available(monkeypatch, tmp_path)
    timeout_exc = HTTPException(status_code=504, detail="Server B 管理 SSH 请求超时")
    _patch_run_admin_command(monkeypatch, raises=timeout_exc)

    response = client.post(
        "/marketplace/admin/rerender",
        headers={"X-Admin-Key": "test-admin-key"},
    )
    assert response.status_code == 504
    assert "超时" in response.json()["detail"]


def test_admin_router_forbidden_returns_502(monkeypatch, tmp_path):
    """admin-router exit 2 -> 502 with forbidden detail."""
    _make_admin_key_available(monkeypatch, tmp_path)
    _patch_run_admin_command(monkeypatch, return_value=(2, "", "forbidden\n"))

    response = client.post(
        "/marketplace/admin/rerender",
        headers={"X-Admin-Key": "test-admin-key"},
    )
    assert response.status_code == 502
    assert "拒绝" in response.json()["detail"]


def test_admin_router_tag_conflict_returns_409(monkeypatch, tmp_path):
    """admin-router exit 9 -> 409 with tag conflict detail (upload)."""
    _make_admin_key_available(monkeypatch, tmp_path)
    _patch_run_admin_command(monkeypatch, return_value=(9, "", "tag plugins/x/v0.2.0 already exists\n"))

    response = client.post(
        "/marketplace/admin/upload",
        headers={"X-Admin-Key": "test-admin-key"},
        files=_upload_files(),
    )
    assert response.status_code == 409
    assert "冲突" in response.json()["detail"]


def test_admin_router_unmapped_exit_returns_502(monkeypatch, tmp_path):
    """An admin-router non-zero exit not in (2, 9) maps to 502."""
    _make_admin_key_available(monkeypatch, tmp_path)
    _patch_run_admin_command(monkeypatch, return_value=(127, "", "command not found\n"))

    response = client.post(
        "/marketplace/admin/curate",
        headers={"X-Admin-Key": "test-admin-key"},
        json={"plugin": "hello", "action": "feature"},
    )
    assert response.status_code == 502
    assert "exit=127" in response.json()["detail"]


# ---------------------------------------------------------------------------
# Validation tests (422)
# ---------------------------------------------------------------------------


def test_upload_oversized_tarball_returns_422(monkeypatch, tmp_path):
    """Tarball exceeding 50MB hard cap should surface as 422."""
    _make_admin_key_available(monkeypatch, tmp_path)
    _patch_run_admin_command(monkeypatch, return_value=(0, "{}", ""))
    # 50MB + 1 byte; chunked reader trips the cap during the first or second 64KB chunk
    oversized = b"X" * (50 * 1024 * 1024 + 1)
    response = client.post(
        "/marketplace/admin/upload",
        headers={"X-Admin-Key": "test-admin-key"},
        files=_upload_files(tarball_bytes=oversized),
    )
    assert response.status_code == 422
    assert "50MB" in response.json()["detail"]


def test_upload_manifest_missing_required_field_returns_422(monkeypatch, tmp_path):
    """manifest.yaml without all 5 required top-level keys must be rejected."""
    _make_admin_key_available(monkeypatch, tmp_path)
    bad_manifest = yaml.safe_dump(
        {
            # missing description / license_id / maintainers / requires
            "version": "0.2.0",
        }
    ).encode("utf-8")
    response = client.post(
        "/marketplace/admin/upload",
        headers={"X-Admin-Key": "test-admin-key"},
        files=_upload_files(manifest_bytes=bad_manifest),
    )
    assert response.status_code == 422
    detail = response.json()["detail"]
    assert "缺少必填字段" in detail
    # All four omitted keys should be enumerated
    assert "description" in detail
    assert "license_id" in detail
    assert "maintainers" in detail
    assert "requires" in detail


def test_upload_manifest_empty_returns_422(monkeypatch, tmp_path):
    _make_admin_key_available(monkeypatch, tmp_path)
    response = client.post(
        "/marketplace/admin/upload",
        headers={"X-Admin-Key": "test-admin-key"},
        files=_upload_files(manifest_bytes=b""),
    )
    assert response.status_code == 422
    assert "为空" in response.json()["detail"]


def test_upload_manifest_non_mapping_returns_422(monkeypatch, tmp_path):
    _make_admin_key_available(monkeypatch, tmp_path)
    response = client.post(
        "/marketplace/admin/upload",
        headers={"X-Admin-Key": "test-admin-key"},
        files=_upload_files(manifest_bytes=b"- one\n- two\n"),
    )
    assert response.status_code == 422
    assert "mapping" in response.json()["detail"]


def test_upload_manifest_version_not_string_returns_422(monkeypatch, tmp_path):
    _make_admin_key_available(monkeypatch, tmp_path)
    bad = yaml.safe_dump(
        {
            "version": 123,  # int instead of string
            "description": "x",
            "license_id": "MIT",
            "maintainers": [{"name": "Alice"}],
            "requires": {"claude_code_min_version": "2.1.0"},
        }
    ).encode("utf-8")
    response = client.post(
        "/marketplace/admin/upload",
        headers={"X-Admin-Key": "test-admin-key"},
        files=_upload_files(manifest_bytes=bad),
    )
    assert response.status_code == 422
    assert "version" in response.json()["detail"]


def test_upload_plugin_slug_invalid_chars_returns_422(monkeypatch, tmp_path):
    """Manifest name with slashes / spaces is rejected as 422."""
    _make_admin_key_available(monkeypatch, tmp_path)
    bad = yaml.safe_dump(
        {
            "name": "evil/slug name",
            "version": "0.1.0",
            "description": "x",
            "license_id": "MIT",
            "maintainers": [{"name": "Alice"}],
            "requires": {"claude_code_min_version": "2.1.0"},
        }
    ).encode("utf-8")
    response = client.post(
        "/marketplace/admin/upload",
        headers={"X-Admin-Key": "test-admin-key"},
        files=_upload_files(manifest_bytes=bad),
    )
    assert response.status_code == 422
    assert "plugin slug" in response.json()["detail"]


def test_approve_invalid_decision_returns_422(monkeypatch, tmp_path):
    """Pydantic pattern enforces decision in {approve, reject}."""
    _make_admin_key_available(monkeypatch, tmp_path)
    response = client.post(
        "/marketplace/admin/approve",
        headers={"X-Admin-Key": "test-admin-key"},
        json={"plugin": "hello", "version": "0.1.0", "decision": "maybe"},
    )
    assert response.status_code == 422


def test_curate_invalid_action_returns_422(monkeypatch, tmp_path):
    """Pydantic pattern enforces action in {feature, deprecate, remove}."""
    _make_admin_key_available(monkeypatch, tmp_path)
    response = client.post(
        "/marketplace/admin/curate",
        headers={"X-Admin-Key": "test-admin-key"},
        json={"plugin": "hello", "action": "yeet"},
    )
    assert response.status_code == 422


def test_upload_missing_tarball_field_returns_422(monkeypatch, tmp_path):
    """multipart body missing the tarball part should fail validation."""
    _make_admin_key_available(monkeypatch, tmp_path)
    response = client.post(
        "/marketplace/admin/upload",
        headers={"X-Admin-Key": "test-admin-key"},
        files={"manifest": ("manifest.yaml", io.BytesIO(_valid_manifest_bytes()), "application/x-yaml")},
    )
    assert response.status_code == 422


# ---------------------------------------------------------------------------
# Happy-path tests (200) -- mocked admin-router success
# ---------------------------------------------------------------------------


def test_upload_happy_path_returns_tag_created(monkeypatch, tmp_path):
    """Successful upload returns tag_created derived from manifest version + name."""
    _make_admin_key_available(monkeypatch, tmp_path)
    captured: dict = {}

    async def fake(settings, verb, args=None, stdin_bytes=None):
        captured["verb"] = verb
        captured["args"] = list(args or [])
        captured["stdin_envelope"] = json.loads(stdin_bytes.decode("utf-8"))
        return (0, "ok\n", "")

    monkeypatch.setattr(marketplace_admin_module, "_run_admin_command", fake)

    response = client.post(
        "/marketplace/admin/upload",
        headers={"X-Admin-Key": "test-admin-key"},
        files=_upload_files(),
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["success"] is True
    data = body["data"]
    assert data["tag_created"] == "plugins/hello-world-skill/v0.2.0"
    assert data["render_triggered"] is True
    assert data["audit_id"]  # non-empty UUID
    # The admin-router was called with the right verb and arg list
    assert captured["verb"] == "upload"
    assert captured["args"] == ["hello-world-skill", "0.2.0"]
    envelope = captured["stdin_envelope"]
    assert envelope["plugin"] == "hello-world-skill"
    assert envelope["version"] == "0.2.0"
    assert envelope["audit_id"] == data["audit_id"]
    assert envelope["manifest"]["license_id"] == "ALL-RIGHTS-RESERVED"
    # tarball_b64 round-trips the actual bytes we sent
    import base64

    assert base64.b64decode(envelope["tarball_b64"]) == b"fake tarball payload"
    # actor token never carries the full admin key past 12 chars
    assert len(envelope["actor"]) <= 12


def test_approve_happy_path_returns_audit_id(monkeypatch, tmp_path):
    _make_admin_key_available(monkeypatch, tmp_path)
    captured: dict = {}

    async def fake(settings, verb, args=None, stdin_bytes=None):
        captured["verb"] = verb
        captured["args"] = list(args or [])
        captured["envelope"] = json.loads(stdin_bytes.decode("utf-8"))
        return (0, "", "")

    monkeypatch.setattr(marketplace_admin_module, "_run_admin_command", fake)

    response = client.post(
        "/marketplace/admin/approve",
        headers={"X-Admin-Key": "test-admin-key"},
        json={"plugin": "hello-world-skill", "version": "0.2.0", "decision": "approve"},
    )
    assert response.status_code == 200, response.text
    data = response.json()["data"]
    assert data["ok"] is True
    assert data["audit_id"]
    assert captured["verb"] == "approve"
    assert captured["args"] == ["hello-world-skill", "0.2.0", "approve"]
    # audit_id round-trip: client sees the same one that admin-router was given
    assert captured["envelope"]["audit_id"] == data["audit_id"]
    assert captured["envelope"]["decision"] == "approve"


def test_curate_happy_path_returns_audit_id(monkeypatch, tmp_path):
    _make_admin_key_available(monkeypatch, tmp_path)
    captured: dict = {}

    async def fake(settings, verb, args=None, stdin_bytes=None):
        captured["verb"] = verb
        captured["args"] = list(args or [])
        captured["envelope"] = json.loads(stdin_bytes.decode("utf-8"))
        return (0, "", "")

    monkeypatch.setattr(marketplace_admin_module, "_run_admin_command", fake)

    response = client.post(
        "/marketplace/admin/curate",
        headers={"X-Admin-Key": "test-admin-key"},
        json={"plugin": "hello-world-skill", "action": "deprecate"},
    )
    assert response.status_code == 200, response.text
    data = response.json()["data"]
    assert data["ok"] is True
    assert data["audit_id"]
    assert captured["verb"] == "curate"
    assert captured["args"] == ["hello-world-skill", "deprecate"]
    assert captured["envelope"]["action"] == "deprecate"


def test_rerender_happy_path_returns_triggered(monkeypatch, tmp_path):
    _make_admin_key_available(monkeypatch, tmp_path)
    captured: dict = {}

    async def fake(settings, verb, args=None, stdin_bytes=None):
        captured["verb"] = verb
        captured["args"] = list(args or [])
        captured["envelope"] = json.loads(stdin_bytes.decode("utf-8"))
        return (0, "", "")

    monkeypatch.setattr(marketplace_admin_module, "_run_admin_command", fake)

    response = client.post(
        "/marketplace/admin/rerender",
        headers={"X-Admin-Key": "test-admin-key"},
    )
    assert response.status_code == 200, response.text
    data = response.json()["data"]
    assert data["triggered"] is True
    assert data["audit_id"]
    assert captured["verb"] == "rerender"
    assert captured["args"] == []
    assert captured["envelope"]["audit_id"] == data["audit_id"]


def test_run_admin_command_rejects_non_whitelisted_verb(monkeypatch, tmp_path):
    """Direct call into _run_admin_command with an off-whitelist verb -> 502.

    This is a belt-and-braces test for the in-memory verb whitelist; the public
    POST routes never reach a non-whitelisted verb, but the helper is the
    last line of defence if a future endpoint mis-spells a verb.
    """
    from app import dependencies as deps
    import asyncio as _asyncio

    _make_admin_key_available(monkeypatch, tmp_path)
    with pytest.raises(HTTPException) as exc_info:
        _asyncio.run(
            marketplace_admin_module._run_admin_command(
                deps.settings,
                "shell-exec",
                args=["rm", "-rf", "/"],
            )
        )
    assert exc_info.value.status_code == 502
    assert "shell-exec" in exc_info.value.detail


def test_validate_manifest_rejects_non_yaml_bytes(monkeypatch, tmp_path):
    """Malformed YAML bytes (binary noise) raise 422 not 5xx."""
    _make_admin_key_available(monkeypatch, tmp_path)
    response = client.post(
        "/marketplace/admin/upload",
        headers={"X-Admin-Key": "test-admin-key"},
        files=_upload_files(manifest_bytes=b"\xff\xfe\x00\x01:not::yaml::"),
    )
    assert response.status_code == 422
