"""Shared pytest fixtures for bifrost-api tests.

Adds ``bifrost-api/`` to ``sys.path`` so the ``app`` package is importable
under both ``pytest`` invoked from the repo root and from ``bifrost-api/``.

NOTE: No secrets are read or written by this module. The fixture overrides
the module-level Settings singleton with safe sentinel values (test admin
key, non-existent SSH key path) and restores the original values after each
test. We deliberately do not touch ``.env`` files or persisted credentials.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

_PKG_ROOT = Path(__file__).resolve().parent.parent
if str(_PKG_ROOT) not in sys.path:
    sys.path.insert(0, str(_PKG_ROOT))


@pytest.fixture(autouse=True)
def _patch_settings_for_tests():
    """Mutate the module-level Settings singleton with sentinel test values.

    ``require_admin`` (dependencies.py) reads ``dependencies.settings.admin_key``
    directly rather than via dependency injection, so we mutate that attribute
    in-place per test and restore the original on teardown. This keeps each
    test deterministic regardless of any host ``.env`` or environment overrides.
    """
    from app import dependencies as deps

    original = {
        "admin_key": deps.settings.admin_key,
        "readonly_ssh_key": deps.settings.readonly_ssh_key,
        "server_b_wg_ip": deps.settings.server_b_wg_ip,
        "readonly_ssh_timeout_sec": deps.settings.readonly_ssh_timeout_sec,
        "admin_user": deps.settings.admin_user,
        "admin_ssh_key": deps.settings.admin_ssh_key,
        "admin_ssh_timeout_sec": deps.settings.admin_ssh_timeout_sec,
    }
    deps.settings.admin_key = "test-admin-key"
    deps.settings.readonly_ssh_key = "/nonexistent/test/path/will-fail-is_file"
    deps.settings.server_b_wg_ip = "127.0.0.1"
    deps.settings.readonly_ssh_timeout_sec = 0.5
    deps.settings.admin_user = "bifrost-admin"
    deps.settings.admin_ssh_key = "/nonexistent/test/path/will-fail-is_file"
    deps.settings.admin_ssh_timeout_sec = 0.5
    try:
        yield deps.settings
    finally:
        for k, v in original.items():
            setattr(deps.settings, k, v)
