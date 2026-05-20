#!/bin/bash
# =============================================================================
# Bifrost - Docker 模拟测试
# 在 Ubuntu 容器中测试脚本的安装逻辑（不含实际网络穿越）
#
# 用法:
#   bash tests/test-in-docker.sh [test_name]
#
# 测试项:
#   syntax    - bash -n 全部脚本
#   common    - common.sh 工具函数
#   detect    - 系统检测 + 云厂商识别
#   security  - 安全加固（防火墙/sysctl）
#   menu      - install.sh 菜单逻辑
#   mihomo    - Mihomo 配置编辑输入边界契约
#   xray      - Xray geodata 与启动前依赖契约
#   deploy    - server-a/server-b 主部署状态一致性契约
#   dd        - dd-reinstall 前置检查 fail-fast 契约
#   keepalive - Keepalive 控制面 fail-fast 契约
#   multi     - Multi-server 与 Mihomo 路由同步契约
#   user      - User-management 交付原子性契约
#   whitelist - Whitelist 与 Xray 路由原子性契约
#   diagnostics - diagnostics 报告导出真实性契约
#   update    - 更新脚本安全与 helper 对齐契约
#   backup    - backup 自动备份与归档内容契约
#   uninstall - uninstall cron 清理边界契约
#   supply    - 供应链 / trust bootstrap 契约
#   bifrost   - bifrost-api 管理面合同测试
#   distribution - Server B 私有分发栈静态/模拟合同测试
#   all       - 运行全部测试
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER_IMAGE="ubuntu:24.04"
CONTAINER_NAME="aigw-test-$$"
TEST_NAME="${1:-all}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; }
skip() { echo -e "${YELLOW}[SKIP]${NC} $*"; }
info() { echo -e "${YELLOW}[TEST]${NC} $*"; }

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

record_pass() { PASS_COUNT=$((PASS_COUNT + 1)); pass "$*"; }
record_fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); fail "$*"; }
record_skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); skip "$*"; }

# --- Check Docker ---
check_docker() {
    if ! command -v docker &>/dev/null; then
        echo "Docker 未安装，跳过容器测试。仅运行本地测试。"
        return 1
    fi
    docker info &>/dev/null || { echo "Docker 未运行"; return 1; }
    return 0
}

cleanup_test_containers() {
    local containers
    containers="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep '^aigw-test-' || true)"
    if [[ -n "${containers}" ]]; then
        echo "${containers}" | xargs -r docker rm -f >/dev/null 2>&1 || true
    fi
}

find_python_cmd() {
    if command -v python >/dev/null 2>&1; then
        echo "python"
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        echo "python3"
        return 0
    fi
    return 1
}

python_has_bifrost_test_deps() {
    local py_cmd="$1"
    "$py_cmd" - <<'PY' >/dev/null 2>&1
import importlib.util
import sys

required = ("fastapi", "httpx", "jinja2", "pydantic_settings")
missing = [name for name in required if importlib.util.find_spec(name) is None]
sys.exit(0 if not missing else 1)
PY
}

is_external_network_failure() {
    local logfile="$1"
    grep -qiE \
        'timed out|temporary failure|could not resolve|name or service not known|network is unreachable|tls handshake timeout|ssl:|certificate|lookup .* timeout|failed to fetch|connection broken|proxy error|read udp .* timeout|EOF occurred in violation of protocol' \
        "${logfile}"
}

run_bifrost_contract_checks() {
    local py_cmd="$1"
    local extra_site_packages="${2:-}"

    BIFROST_TEST_REPO_DIR="${SCRIPT_DIR}" \
    BIFROST_TEST_SITE_PACKAGES="${extra_site_packages}" \
    "$py_cmd" - <<'PY'
import os
import sys

site_packages = os.environ.get("BIFROST_TEST_SITE_PACKAGES", "").strip()
if site_packages:
    sys.path.insert(0, site_packages)

repo_dir = os.environ["BIFROST_TEST_REPO_DIR"]
sys.path.insert(0, os.path.join(repo_dir, "bifrost-api"))

os.environ["BIFROST_ADMIN_KEY"] = "test-admin"
os.environ["BIFROST_PUBLIC_BASE_URL"] = "https://api.example.com"
os.environ["BIFROST_NEWAPI_ADMIN_TOKEN"] = "test-token"
os.environ["BIFROST_NEWAPI_BASE_URL"] = "http://127.0.0.1:9"
os.environ["BIFROST_SERVER_B_WG_IP"] = "127.0.0.1"
os.environ["BIFROST_READONLY_SSH_KEY"] = "/tmp/bifrost-readonly-test-missing.ed25519"
os.environ["BIFROST_READONLY_USER"] = "bifrost-readonly"
os.environ.pop("BIFROST_CORS_ALLOW_ORIGINS", None)
os.environ["BIFROST_CORS_ALLOW_CREDENTIALS"] = "false"

from fastapi.testclient import TestClient

from app.main import app


def ensure(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


with TestClient(app) as client:
    docs = client.get("/docs")
    ensure(docs.status_code == 200, f"/docs should return 200, got {docs.status_code}")
    ensure("/openapi.json" in docs.text, "/docs should reference /openapi.json for direct access")

    prefixed_docs = client.get("/docs", headers={"X-Forwarded-Prefix": "/manage"})
    ensure(
        prefixed_docs.status_code == 200,
        f"/manage/docs should return 200, got {prefixed_docs.status_code}",
    )
    ensure(
        "/manage/openapi.json" in prefixed_docs.text,
        "/manage/docs should reference /manage/openapi.json behind reverse proxy",
    )

    openapi = client.get("/openapi.json", headers={"X-Forwarded-Prefix": "/manage"})
    ensure(openapi.status_code == 200, f"/manage/openapi.json should return 200, got {openapi.status_code}")
    servers = openapi.json().get("servers", [])
    ensure(
        any(server.get("url") == "/manage" for server in servers),
        f"OpenAPI servers should include /manage, got {servers}",
    )

    register_page = client.get("/register")
    ensure(register_page.status_code == 200, f"/register should return 200, got {register_page.status_code}")
    ensure(
        'data-api-prefix=""' in register_page.text,
        "/register should inject an empty API prefix for direct access",
    )

    prefixed_register_page = client.get("/register", headers={"X-Forwarded-Prefix": "/manage"})
    ensure(
        prefixed_register_page.status_code == 200,
        f"/manage/register should return 200, got {prefixed_register_page.status_code}",
    )
    ensure(
        'data-api-prefix="/manage"' in prefixed_register_page.text,
        "/manage/register should inject /manage as the API prefix",
    )

    missing_admin_key = client.get("/api/v1/models/test")
    ensure(
        missing_admin_key.status_code == 401,
        f"Missing X-Admin-Key should return 401, got {missing_admin_key.status_code}",
    )

    wrong_admin_key = client.get(
        "/api/v1/models/test",
        headers={"X-Admin-Key": "wrong-admin-key"},
    )
    ensure(
        wrong_admin_key.status_code == 403,
        f"Wrong X-Admin-Key should return 403, got {wrong_admin_key.status_code}",
    )

    mirrors_missing_admin = client.get("/mirrors/status")
    ensure(
        mirrors_missing_admin.status_code == 401,
        f"Missing X-Admin-Key on /mirrors/status should return 401, got {mirrors_missing_admin.status_code}",
    )

    mirrors_wrong_admin = client.get(
        "/mirrors/status",
        headers={"X-Admin-Key": "wrong-admin-key"},
    )
    ensure(
        mirrors_wrong_admin.status_code == 403,
        f"Wrong X-Admin-Key on /mirrors/status should return 403, got {mirrors_wrong_admin.status_code}",
    )

    mirrors_status = client.get(
        "/mirrors/status",
        headers={"X-Admin-Key": "test-admin"},
    )
    ensure(
        mirrors_status.status_code == 200,
        f"/mirrors/status should degrade to 200 with per-service status, got {mirrors_status.status_code}",
    )
    mirrors_status_data = mirrors_status.json().get("data", {})
    ensure(
        mirrors_status_data.get("verdaccio", {}).get("up") is False,
        "Unreachable Verdaccio probe should be reported as up=false",
    )
    ensure(
        mirrors_status_data.get("wg_link", {}).get("ssh_configured") is False,
        "Missing readonly SSH key should be reported as ssh_configured=false",
    )

    mirrors_logs = client.get(
        "/mirrors/logs?service=verdaccio&tail=200",
        headers={"X-Admin-Key": "test-admin"},
    )
    ensure(
        mirrors_logs.status_code == 503,
        f"/mirrors/logs should fail closed when readonly SSH key is missing, got {mirrors_logs.status_code}",
    )
    ensure(
        "ed25519" not in mirrors_logs.text,
        "/mirrors/logs error should not leak the configured private key path",
    )

    mirrors_disk = client.get(
        "/mirrors/disk",
        headers={"X-Admin-Key": "test-admin"},
    )
    ensure(
        mirrors_disk.status_code == 503,
        f"/mirrors/disk should fail closed when readonly SSH key is missing, got {mirrors_disk.status_code}",
    )

    cors_preflight = client.options(
        "/api/v1/register/status",
        headers={
            "Origin": "https://evil.example",
            "Access-Control-Request-Method": "GET",
        },
    )
    ensure(
        cors_preflight.headers.get("access-control-allow-origin") is None,
        "Default same-origin policy should not echo arbitrary Origin values",
    )
    ensure(
        cors_preflight.status_code in (400, 405),
        f"Unexpected preflight status without CORS middleware: {cors_preflight.status_code}",
    )
PY
}

# --- Test: Syntax ---
test_syntax() {
    info "=== 语法测试 (bash -n) ==="

    local scripts=()
    while IFS= read -r -d '' f; do
        scripts+=("$f")
    done < <(find "${SCRIPT_DIR}" -name "*.sh" -type f -not -path "*/tests/*" -not -path "*/.claude/*" -print0)

    for script in "${scripts[@]}"; do
        local name="${script#"${SCRIPT_DIR}/"}"
        if bash -n "$script" 2>/dev/null; then
            record_pass "bash -n: ${name}"
        else
            record_fail "bash -n: ${name}"
        fi
    done
}

# --- Test: Function existence ---
test_functions() {
    info "=== 函数存在性测试 ==="

    # Key entry functions that install.sh calls
    local expected_functions=(
        "scripts/common.sh:detect_system"
        "scripts/common.sh:show_menu"
        "scripts/common.sh:log_info"
        "scripts/common.sh:install_packages"
        "scripts/common.sh:check_docker"
        "scripts/common.sh:require_docker_server_version"
        "scripts/common.sh:generate_uuid"
        "scripts/common.sh:generate_x25519_keypair"
        "scripts/common.sh:template_render"
        "scripts/common.sh:bifrost_exposure_profile"
        "scripts/common.sh:bifrost_admin_allowed_ranges"
        "scripts/common.sh:bifrost_exposure_profile_description"
        "scripts/security.sh:full_security_hardening"
        "scripts/security.sh:harden_ssh"
        "scripts/security.sh:setup_firewall"
        "scripts/security.sh:setup_fail2ban"
        "scripts/server-a.sh:deploy_server_a"
        "scripts/server-a.sh:install_xray_client"
        "scripts/server-a.sh:install_new_api"
        "scripts/server-b.sh:deploy_server_b"
        "scripts/server-b.sh:install_xray_server"
        "scripts/monitoring.sh:deploy_monitoring"
        "scripts/dd-reinstall.sh:pre_deploy_check"
        "scripts/dd-reinstall.sh:detect_cloud_provider"
        "scripts/vpn.sh:deploy_vpn"
        "scripts/vpn.sh:create_vpn_user"
        "scripts/anti-dpi.sh:deploy_anti_dpi"
        "scripts/anti-dpi.sh:rotate_dest"
        "scripts/mihomo.sh:deploy_mihomo"
        "scripts/mihomo.sh:add_mihomo_node"
        "scripts/keepalive.sh:deploy_keepalive"
        "scripts/split-tunnel.sh:deploy_split_tunnel"
        "scripts/backup.sh:manage_backups"
        "scripts/update.sh:manage_updates"
        "scripts/multi-server.sh:manage_servers"
        "scripts/user-management.sh:manage_users"
        "scripts/diagnostics.sh:manage_diagnostics"
        "scripts/whitelist.sh:manage_whitelist"
        "scripts/uninstall.sh:uninstall_all"
    )

    for entry in "${expected_functions[@]}"; do
        local file="${entry%%:*}"
        local func="${entry##*:}"
        local filepath="${SCRIPT_DIR}/${file}"

        if grep -q "^${func}()" "$filepath" 2>/dev/null || grep -q "^function ${func}" "$filepath" 2>/dev/null; then
            record_pass "函数存在: ${file}:${func}()"
        else
            record_fail "函数缺失: ${file}:${func}()"
        fi
    done
}

# --- Test: Config templates ---
test_configs() {
    info "=== 配置模板测试 ==="

    # JSON templates (replace placeholders then validate)
    for tpl in configs/xray/client.json.tpl configs/xray/server.json.tpl; do
        local filepath="${SCRIPT_DIR}/${tpl}"
        if [[ -f "$filepath" ]]; then
            # Replace all {{PLACEHOLDER}} with type-appropriate dummy values:
            # - Numeric-context placeholders (port numbers) use 443 (valid JSON number)
            # - All other placeholders use "test-value" (valid JSON string)
            # Two-pass sed: first replace bare numeric placeholders, then string ones.
            local tmp="/tmp/aigw-test-$$.json"
            sed \
                -e 's/"port": {{[A-Z0-9_]*}}/"port": 443/g' \
                -e 's/{{[A-Z0-9_]*}}/test-value/g' \
                "$filepath" > "$tmp"
            if python3 -m json.tool "$tmp" >/dev/null 2>&1; then
                record_pass "JSON 有效: ${tpl}"
            else
                record_fail "JSON 无效: ${tpl}"
            fi
            rm -f "$tmp"
        else
            record_fail "文件缺失: ${tpl}"
        fi
    done

    # YAML templates
    for tpl in configs/mihomo/config.yaml.tpl configs/mihomo/ruleset/ai-domains.yaml configs/mihomo/ruleset/streaming-block.yaml; do
        local filepath="${SCRIPT_DIR}/${tpl}"
        if [[ -f "$filepath" ]]; then
            # Basic YAML validation (check for tab indentation errors)
            if ! grep -P '^\t' "$filepath" >/dev/null 2>&1; then
                record_pass "YAML 无 tab: ${tpl}"
            else
                record_fail "YAML 含 tab: ${tpl} (YAML 不允许 tab 缩进)"
            fi
        else
            record_fail "文件缺失: ${tpl}"
        fi
    done

    # Whitelist has content
    local wl="${SCRIPT_DIR}/configs/whitelist/ai-domains.txt"
    if [[ -f "$wl" ]]; then
        local domain_count
        domain_count=$(grep -v '^#' "$wl" | grep -v '^$' | wc -l)
        if [[ "$domain_count" -ge 30 ]]; then
            record_pass "白名单域名数: ${domain_count} (≥30)"
        else
            record_fail "白名单域名数不足: ${domain_count} (<30)"
        fi
    fi
}

test_monitoring_contracts() {
    info "=== Monitoring 健康检查部署契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local fakebin="${temp_root}/bin"
    local cronfile="${temp_root}/crontab.txt"
    mkdir -p "${fakebin}" "${temp_root}/install" "${temp_root}/logs"

    cat > "${fakebin}/crontab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cronfile="${BIFROST_TEST_CRONTAB_FILE:?}"

case "${1:-}" in
    -l)
        [[ -f "${cronfile}" ]] && cat "${cronfile}"
        ;;
    -|"")
        cat > "${cronfile}"
        ;;
    *)
        echo "unsupported crontab args: $*" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "${fakebin}/crontab"

    cat > "${fakebin}/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${fakebin}/pgrep"

    if BIFROST_TEST_CRONTAB_FILE="${cronfile}" \
        PATH="${fakebin}:${PATH}" \
        INSTALL_DIR="${temp_root}/install" \
        LOG_DIR="${temp_root}/logs" \
        MONITORING_SH="${SCRIPT_DIR}/scripts/monitoring.sh" \
        bash -c '
            set -euo pipefail
            source "$MONITORING_SH"
            setup_health_check
            test -x "${INSTALL_DIR}/health-check.sh"
            grep -q "check_bifrost_api" "${INSTALL_DIR}/health-check.sh"
            grep -q "check_public_manage_surface" "${INSTALL_DIR}/health-check.sh"
            ! grep -q "Minimal health check" "${INSTALL_DIR}/health-check.sh"
            grep -q "# bifrost-health-check" "${BIFROST_TEST_CRONTAB_FILE}"
        '; then
        record_pass "Monitoring 部署完整 health-check + cron"
    else
        record_fail "Monitoring 部署完整 health-check + cron"
    fi

    local update_root="${temp_root}/update"
    local update_cronfile="${temp_root}/crontab-update.txt"
    mkdir -p "${update_root}/install" "${update_root}/logs"
    cat > "${update_cronfile}" <<'EOF'
15 1 * * * /usr/bin/true
*/10 * * * * /tmp/legacy-health-check.sh >> /tmp/legacy-health.log 2>&1 # bifrost-health-check
EOF

    if BIFROST_TEST_CRONTAB_FILE="${update_cronfile}" \
        PATH="${fakebin}:${PATH}" \
        INSTALL_DIR="${update_root}/install" \
        LOG_DIR="${update_root}/logs" \
        MONITORING_SH="${SCRIPT_DIR}/scripts/monitoring.sh" \
        bash -c '
            set -euo pipefail
            source "$MONITORING_SH"
            setup_health_check
            [[ "$(grep -c "# bifrost-health-check" "${BIFROST_TEST_CRONTAB_FILE}")" -eq 1 ]]
            grep -q "${INSTALL_DIR}/health-check.sh" "${BIFROST_TEST_CRONTAB_FILE}"
            grep -q "/usr/bin/true" "${BIFROST_TEST_CRONTAB_FILE}"
            ! grep -q "/tmp/legacy-health-check.sh" "${BIFROST_TEST_CRONTAB_FILE}"
        '; then
        record_pass "Monitoring 更新已存在的 health-check cron"
    else
        record_fail "Monitoring 更新已存在的 health-check cron"
    fi

    local missing_root="${temp_root}/missing"
    mkdir -p "${missing_root}"
    cp "${SCRIPT_DIR}/scripts/monitoring.sh" "${missing_root}/monitoring.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${missing_root}/common.sh"

    if BIFROST_TEST_CRONTAB_FILE="${cronfile}" \
        PATH="${fakebin}:${PATH}" \
        INSTALL_DIR="${temp_root}/missing-install" \
        LOG_DIR="${temp_root}/missing-logs" \
        MONITORING_SH="${missing_root}/monitoring.sh" \
        bash -c '
            set -euo pipefail
            source "$MONITORING_SH"
            if setup_health_check; then
                exit 1
            fi
            exit 0
        '; then
        record_pass "Monitoring 缺失 health-check 时 fail-fast"
    else
        record_fail "Monitoring 缺失 health-check 时 fail-fast"
    fi

    cat > "${fakebin}/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${fakebin}/pgrep"

    cat > "${fakebin}/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${fakebin}/systemctl"

    local stopped_cronfile="${temp_root}/crontab-stopped.txt"
    if BIFROST_TEST_CRONTAB_FILE="${stopped_cronfile}" \
        PATH="${fakebin}:${PATH}" \
        INSTALL_DIR="${temp_root}/stopped-install" \
        LOG_DIR="${temp_root}/stopped-logs" \
        MONITORING_SH="${SCRIPT_DIR}/scripts/monitoring.sh" \
        bash -c '
            set -euo pipefail
            source "$MONITORING_SH"
            if setup_health_check; then
                exit 1
            fi
            ! grep -q "# bifrost-health-check" "${BIFROST_TEST_CRONTAB_FILE}" 2>/dev/null
        '; then
        record_pass "Monitoring 在 crontab 存在但调度器未运行时会 fail-fast"
    else
        record_fail "Monitoring 在 crontab 存在但调度器未运行时会 fail-fast"
    fi

    rm -rf "${temp_root}"
}

test_backup_contracts() {
    info "=== Backup 自动备份与归档内容契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local fakebin="${temp_root}/bin"
    local cronfile="${temp_root}/backup-crontab.txt"
    mkdir -p "${fakebin}" "${temp_root}/install"

    cat > "${fakebin}/crontab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cronfile="${BIFROST_TEST_CRONTAB_FILE:?}"

case "${1:-}" in
    -l)
        [[ -f "${cronfile}" ]] && cat "${cronfile}"
        ;;
    -|"")
        cat > "${cronfile}"
        ;;
    *)
        echo "unsupported crontab args: $*" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "${fakebin}/crontab"

    cat > "${fakebin}/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${fakebin}/pgrep"

    cat > "${fakebin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    info)
        exit 1
        ;;
    *)
        exit 1
        ;;
esac
EOF
    chmod +x "${fakebin}/docker"

    if BIFROST_TEST_CRONTAB_FILE="${cronfile}" \
        PATH="${fakebin}:${PATH}" \
        TMP_ROOT="${temp_root}" \
        BACKUP_SH="${SCRIPT_DIR}/scripts/backup.sh" \
        bash -c '
            set -euo pipefail
            source "$BACKUP_SH"
            BACKUP_BASE_DIR="${TMP_ROOT}/backups"
            BACKUP_ENCRYPTION_KEY_FILE="${TMP_ROOT}/backup.key"
            LOG_DIR="${TMP_ROOT}/logs"
            setup_auto_backup
            test -f "${BACKUP_ENCRYPTION_KEY_FILE}"
            grep -q "# bifrost-daily-backup" "${BIFROST_TEST_CRONTAB_FILE}"
            grep -q "backup.sh backup" "${BIFROST_TEST_CRONTAB_FILE}"
        '; then
        record_pass "Backup 首次注册 daily cron"
    else
        record_fail "Backup 首次注册 daily cron"
    fi

    local update_cronfile="${temp_root}/backup-crontab-update.txt"
    cat > "${update_cronfile}" <<'EOF'
30 2 * * * /usr/bin/true
0 4 * * * /tmp/legacy-backup.sh backup >> /tmp/legacy-backup.log 2>&1 # bifrost-daily-backup
EOF

    if BIFROST_TEST_CRONTAB_FILE="${update_cronfile}" \
        PATH="${fakebin}:${PATH}" \
        TMP_ROOT="${temp_root}" \
        BACKUP_SH="${SCRIPT_DIR}/scripts/backup.sh" \
        bash -c '
            set -euo pipefail
            source "$BACKUP_SH"
            BACKUP_BASE_DIR="${TMP_ROOT}/backups-update"
            BACKUP_ENCRYPTION_KEY_FILE="${TMP_ROOT}/backup-update.key"
            LOG_DIR="${TMP_ROOT}/logs-update"
            setup_auto_backup
            [[ "$(grep -c "# bifrost-daily-backup" "${BIFROST_TEST_CRONTAB_FILE}")" -eq 1 ]]
            grep -q "backup.sh backup" "${BIFROST_TEST_CRONTAB_FILE}"
            grep -q "/usr/bin/true" "${BIFROST_TEST_CRONTAB_FILE}"
            ! grep -q "/tmp/legacy-backup.sh" "${BIFROST_TEST_CRONTAB_FILE}"
        '; then
        record_pass "Backup 更新已存在的 daily cron"
    else
        record_fail "Backup 更新已存在的 daily cron"
    fi

    if TMP_ROOT="${temp_root}" \
        PATH="/usr/bin:/bin" \
        BACKUP_SH="${SCRIPT_DIR}/scripts/backup.sh" \
        bash -c '
            set -euo pipefail
            source "$BACKUP_SH"
            BACKUP_BASE_DIR="${TMP_ROOT}/backups-missing"
            BACKUP_ENCRYPTION_KEY_FILE="${TMP_ROOT}/backup-missing.key"
            LOG_DIR="${TMP_ROOT}/logs-missing"
            PKG_MGR=unknown
            command_exists() {
                if [[ "$1" == "crontab" ]]; then
                    return 1
                fi
                command -v "$1" >/dev/null 2>&1
            }
            if setup_auto_backup; then
                exit 1
            fi
            exit 0
        '; then
        record_pass "Backup 缺失 crontab 时 fail-fast"
    else
        record_fail "Backup 缺失 crontab 时 fail-fast"
    fi

    cat > "${fakebin}/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${fakebin}/pgrep"

    cat > "${fakebin}/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${fakebin}/systemctl"

    cat > "${fakebin}/service" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${fakebin}/service"

    local stopped_cronfile="${temp_root}/backup-crontab-stopped.txt"
    if BIFROST_TEST_CRONTAB_FILE="${stopped_cronfile}" \
        PATH="${fakebin}:${PATH}" \
        TMP_ROOT="${temp_root}" \
        BACKUP_SH="${SCRIPT_DIR}/scripts/backup.sh" \
        bash -c '
            set -euo pipefail
            source "$BACKUP_SH"
            BACKUP_BASE_DIR="${TMP_ROOT}/backups-stopped"
            BACKUP_ENCRYPTION_KEY_FILE="${TMP_ROOT}/backup-stopped.key"
            LOG_DIR="${TMP_ROOT}/logs-stopped"
            if setup_auto_backup; then
                exit 1
            fi
            ! grep -q "# bifrost-daily-backup" "${BIFROST_TEST_CRONTAB_FILE}" 2>/dev/null
        '; then
        record_pass "Backup 在 crontab 存在但调度器未运行时会 fail-fast"
    else
        record_fail "Backup 在 crontab 存在但调度器未运行时会 fail-fast"
    fi

    if BIFROST_TEST_CRONTAB_FILE="${cronfile}" \
        PATH="${fakebin}:${PATH}" \
        TMP_ROOT="${temp_root}" \
        BACKUP_SH="${SCRIPT_DIR}/scripts/backup.sh" \
        bash -c '
            set -euo pipefail
            source "$BACKUP_SH"
            BACKUP_BASE_DIR="${TMP_ROOT}/content-backups"
            BACKUP_ENCRYPTION_KEY_FILE="${TMP_ROOT}/backup-content.key"
            XRAY_CONFIG_DIR="${TMP_ROOT}/content-src/usr/local/etc/xray"
            CADDY_CONFIG_DIR="${TMP_ROOT}/content-src/etc/caddy"
            MIHOMO_CONFIG_DIR="${TMP_ROOT}/content-src/etc/mihomo"
            NEW_API_DIR="${TMP_ROOT}/content-src/opt/new-api"
            INSTALL_DIR="${TMP_ROOT}/content-src/opt/bifrost"
            SECURITY_STATE_DIR="${TMP_ROOT}/content-src/etc/bifrost"
            FAIL2BAN_CONFIG="${TMP_ROOT}/content-src/etc/fail2ban"
            SYSCTL_HARDENING="${TMP_ROOT}/content-src/etc/sysctl.d/99-ai-gateway-hardening.conf"
            SERVER_B_CONF="${TMP_ROOT}/content-src/root/server-b-connection.conf"
            CONNECTION_INFO="${TMP_ROOT}/content-src/root/ai-gateway-connection.txt"

            mkdir -p "${XRAY_CONFIG_DIR}" \
                "${CADDY_CONFIG_DIR}" \
                "${SECURITY_STATE_DIR}" \
                "$(dirname "${SYSCTL_HARDENING}")" \
                "$(dirname "${SERVER_B_CONF}")" \
                "$(dirname "${CONNECTION_INFO}")"
            printf "{\"test\":true}\n" > "${XRAY_CONFIG_DIR}/config.json"
            printf ":443 { respond \"ok\" }\n" > "${CADDY_CONFIG_DIR}/Caddyfile"
            printf "SECURITY_STATE=1\n" > "${SECURITY_STATE_DIR}/state.env"
            printf "net.ipv4.ip_forward=1\n" > "${SYSCTL_HARDENING}"
            printf "SERVER_B_IP=203.0.113.10\n" > "${SERVER_B_CONF}"
            printf "Connection info\n" > "${CONNECTION_INFO}"
            printf "*/5 * * * * /usr/bin/echo health\n" > "${BIFROST_TEST_CRONTAB_FILE}"

            backup_config

            archive="$(find "${BACKUP_BASE_DIR}" -maxdepth 1 -name "backup-*.tar.gz.enc" | head -1)"
            test -n "${archive}"
            openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
                -in "${archive}" \
                -out "${TMP_ROOT}/content-backup.tar.gz" \
                -pass "pass:$(cat "${BACKUP_ENCRYPTION_KEY_FILE}")" 2>/dev/null
            tar tzf "${TMP_ROOT}/content-backup.tar.gz" > "${TMP_ROOT}/content-backup.list"

            grep -q "/usr/local/etc/xray/config.json$" "${TMP_ROOT}/content-backup.list"
            grep -q "/etc/caddy/Caddyfile$" "${TMP_ROOT}/content-backup.list"
            grep -q "/backup-content.key$" "${TMP_ROOT}/content-backup.list"
            grep -q "^metadata/crontab.txt$" "${TMP_ROOT}/content-backup.list"
            grep -q "^metadata/docker-info.txt$" "${TMP_ROOT}/content-backup.list"
        '; then
        record_pass "Backup 归档同时包含 configs payload + metadata"
    else
        record_fail "Backup 归档同时包含 configs payload + metadata"
    fi

    if TMP_ROOT="${temp_root}" \
        BACKUP_SH="${SCRIPT_DIR}/scripts/backup.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$BACKUP_SH"
            XRAY_CONFIG_DIR="${TMP_ROOT}/rotate-empty/usr/local/etc/xray"
            MIHOMO_CONFIG_DIR="${TMP_ROOT}/rotate-empty/etc/mihomo"
            SERVER_B_CONF="${TMP_ROOT}/rotate-empty/root/server-b-connection.conf"
            CONNECTION_INFO="${TMP_ROOT}/rotate-empty/root/ai-gateway-connection.txt"
            confirm_action() { return 0; }
            backup_config() { return 0; }
            install_if_missing() { return 1; }
            command_exists() { return 1; }
            sleep() { :; }
            if emergency_ip_rotation "198.51.100.20" >"${output_file}" 2>&1; then
                exit 1
            fi
            grep -q "No configuration files were updated. IP rotation aborted." "${output_file}"
            ! grep -q "IP rotation complete" "${output_file}"
        '; then
        record_pass "Backup rotate-ip 在零变更时 fail-fast 且不打印完成摘要"
    else
        record_fail "Backup rotate-ip 在零变更时 fail-fast 且不打印完成摘要"
    fi

    if TMP_ROOT="${temp_root}" \
        BACKUP_SH="${SCRIPT_DIR}/scripts/backup.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$BACKUP_SH"
            XRAY_CONFIG_DIR="${TMP_ROOT}/rotate-connectivity/usr/local/etc/xray"
            MIHOMO_CONFIG_DIR="${TMP_ROOT}/rotate-connectivity/etc/mihomo"
            SERVER_B_CONF="${TMP_ROOT}/rotate-connectivity/root/server-b-connection.conf"
            CONNECTION_INFO="${TMP_ROOT}/rotate-connectivity/root/ai-gateway-connection.txt"
            mkdir -p "${XRAY_CONFIG_DIR}" "${MIHOMO_CONFIG_DIR}" "$(dirname "${SERVER_B_CONF}")" "$(dirname "${CONNECTION_INFO}")"
            printf "{\"outbounds\":[{\"tag\":\"proxy\",\"settings\":{\"vnext\":[{\"address\":\"203.0.113.10\"}]}}]}\n" > "${XRAY_CONFIG_DIR}/config.json"
            printf "proxies:\n  - name: test\n    server: 203.0.113.10\n" > "${MIHOMO_CONFIG_DIR}/config.yaml"
            printf "SERVER_B_IP=203.0.113.10\n" > "${SERVER_B_CONF}"
            printf "Server B: 203.0.113.10\n" > "${CONNECTION_INFO}"
            confirm_action() { return 0; }
            backup_config() { return 0; }
            install_if_missing() { return 1; }
            command_exists() {
                [[ "$1" == "systemctl" ]]
            }
            systemctl() {
                case "$1" in
                    is-active|restart) return 0 ;;
                    *) return 1 ;;
                esac
            }
            curl() { return 1; }
            sleep() { :; }
            if emergency_ip_rotation "198.51.100.20" >"${output_file}" 2>&1; then
                exit 1
            fi
            grep -q "Connectivity test failed (HTTP 000). Configuration was updated but tunnel verification failed." "${output_file}"
            ! grep -q "IP rotation complete" "${output_file}"
            grep -q "198.51.100.20" "${XRAY_CONFIG_DIR}/config.json"
            grep -q "198.51.100.20" "${MIHOMO_CONFIG_DIR}/config.yaml"
            grep -q "SERVER_B_IP=198.51.100.20" "${SERVER_B_CONF}"
        '; then
        record_pass "Backup rotate-ip 在 tunnel 验证失败时返回失败且不打印完成摘要"
    else
        record_fail "Backup rotate-ip 在 tunnel 验证失败时返回失败且不打印完成摘要"
    fi

    if TMP_ROOT="${temp_root}" \
        BACKUP_SH="${SCRIPT_DIR}/scripts/backup.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$BACKUP_SH"
            trap - EXIT ERR
            XRAY_CONFIG_DIR="${TMP_ROOT}/rotate-backup-fail/usr/local/etc/xray"
            MIHOMO_CONFIG_DIR="${TMP_ROOT}/rotate-backup-fail/etc/mihomo"
            SERVER_B_CONF="${TMP_ROOT}/rotate-backup-fail/root/server-b-connection.conf"
            CONNECTION_INFO="${TMP_ROOT}/rotate-backup-fail/root/ai-gateway-connection.txt"
            mkdir -p "${XRAY_CONFIG_DIR}" "${MIHOMO_CONFIG_DIR}" "$(dirname "${SERVER_B_CONF}")" "$(dirname "${CONNECTION_INFO}")"
            printf "{\"outbounds\":[{\"tag\":\"proxy\",\"settings\":{\"vnext\":[{\"address\":\"203.0.113.10\"}]}}]}\n" > "${XRAY_CONFIG_DIR}/config.json"
            printf "proxies:\n  - name: test\n    server: 203.0.113.10\n" > "${MIHOMO_CONFIG_DIR}/config.yaml"
            printf "SERVER_B_IP=203.0.113.10\n" > "${SERVER_B_CONF}"
            printf "Server B: 203.0.113.10\n" > "${CONNECTION_INFO}"
            confirm_action() { return 0; }
            backup_config() { return 1; }
            install_if_missing() { return 1; }
            command_exists() { return 1; }
            failed=0
            set +e
            emergency_ip_rotation "198.51.100.20" >"${output_file}" 2>&1
            status=$?
            [[ "${status}" -ne 0 ]] || failed=1
            grep -q "Pre-rotation backup failed. Refusing to continue with IP rotation." "${output_file}" || failed=1
            ! grep -q "IP rotation complete" "${output_file}" || failed=1
            grep -q "203.0.113.10" "${XRAY_CONFIG_DIR}/config.json" || failed=1
            grep -q "203.0.113.10" "${MIHOMO_CONFIG_DIR}/config.yaml" || failed=1
            grep -q "SERVER_B_IP=203.0.113.10" "${SERVER_B_CONF}" || failed=1
            if [[ "${failed}" -ne 0 ]]; then
                cat "${output_file}" >&2
                exit 1
            fi
        '; then
        record_pass "Backup rotate-ip 在预备份失败时会拒绝修改配置"
    else
        record_fail "Backup rotate-ip 在预备份失败时会拒绝修改配置"
    fi

    rm -rf "${temp_root}"
}

test_bridge_backup_contracts() {
    info "=== AI Gateway Bridge Backup 自动备份与归档内容契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local fakebin="${temp_root}/bin"
    local cronfile="${temp_root}/bridge-backup-crontab.txt"
    mkdir -p "${fakebin}" "${temp_root}/install"

    cat > "${fakebin}/crontab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cronfile="${BIFROST_TEST_CRONTAB_FILE:?}"

case "${1:-}" in
    -l)
        [[ -f "${cronfile}" ]] && cat "${cronfile}"
        ;;
    -|"")
        cat > "${cronfile}"
        ;;
    *)
        echo "unsupported crontab args: $*" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "${fakebin}/crontab"

    cat > "${fakebin}/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${fakebin}/pgrep"

    cat > "${fakebin}/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
    info)
        exit 1
        ;;
    *)
        exit 1
        ;;
esac
EOF
    chmod +x "${fakebin}/docker"

    if BIFROST_TEST_CRONTAB_FILE="${cronfile}" \
        PATH="${fakebin}:${PATH}" \
        TMP_ROOT="${temp_root}" \
        BACKUP_SH="${SCRIPT_DIR}/ai-gateway-bridge/scripts/backup.sh" \
        bash -c '
            set -euo pipefail
            source "$BACKUP_SH"
            BACKUP_BASE_DIR="${TMP_ROOT}/backups"
            BACKUP_ENCRYPTION_KEY_FILE="${TMP_ROOT}/backup.key"
            LOG_DIR="${TMP_ROOT}/logs"
            setup_auto_backup
            test -f "${BACKUP_ENCRYPTION_KEY_FILE}"
            grep -q "# ai-gateway-bridge-daily-backup" "${BIFROST_TEST_CRONTAB_FILE}"
            grep -q "backup.sh backup" "${BIFROST_TEST_CRONTAB_FILE}"
        '; then
        record_pass "AI Gateway Bridge backup 首次注册 daily cron"
    else
        record_fail "AI Gateway Bridge backup 首次注册 daily cron"
    fi

    local update_cronfile="${temp_root}/bridge-backup-crontab-update.txt"
    cat > "${update_cronfile}" <<'EOF'
30 2 * * * /usr/bin/true
0 4 * * * /tmp/legacy-backup.sh backup >> /tmp/legacy-backup.log 2>&1 # ai-gateway-bridge-daily-backup
EOF

    if BIFROST_TEST_CRONTAB_FILE="${update_cronfile}" \
        PATH="${fakebin}:${PATH}" \
        TMP_ROOT="${temp_root}" \
        BACKUP_SH="${SCRIPT_DIR}/ai-gateway-bridge/scripts/backup.sh" \
        bash -c '
            set -euo pipefail
            source "$BACKUP_SH"
            BACKUP_BASE_DIR="${TMP_ROOT}/backups-update"
            BACKUP_ENCRYPTION_KEY_FILE="${TMP_ROOT}/backup-update.key"
            LOG_DIR="${TMP_ROOT}/logs-update"
            setup_auto_backup
            [[ "$(grep -c "# ai-gateway-bridge-daily-backup" "${BIFROST_TEST_CRONTAB_FILE}")" -eq 1 ]]
            grep -q "backup.sh backup" "${BIFROST_TEST_CRONTAB_FILE}"
            grep -q "/usr/bin/true" "${BIFROST_TEST_CRONTAB_FILE}"
            ! grep -q "/tmp/legacy-backup.sh" "${BIFROST_TEST_CRONTAB_FILE}"
        '; then
        record_pass "AI Gateway Bridge backup 更新已存在的 daily cron"
    else
        record_fail "AI Gateway Bridge backup 更新已存在的 daily cron"
    fi

    if TMP_ROOT="${temp_root}" \
        PATH="/usr/bin:/bin" \
        BACKUP_SH="${SCRIPT_DIR}/ai-gateway-bridge/scripts/backup.sh" \
        bash -c '
            set -euo pipefail
            source "$BACKUP_SH"
            BACKUP_BASE_DIR="${TMP_ROOT}/backups-missing"
            BACKUP_ENCRYPTION_KEY_FILE="${TMP_ROOT}/backup-missing.key"
            LOG_DIR="${TMP_ROOT}/logs-missing"
            PKG_MGR=unknown
            command_exists() {
                if [[ "$1" == "crontab" ]]; then
                    return 1
                fi
                command -v "$1" >/dev/null 2>&1
            }
            if setup_auto_backup; then
                exit 1
            fi
            exit 0
        '; then
        record_pass "AI Gateway Bridge backup 缺失 crontab 时 fail-fast"
    else
        record_fail "AI Gateway Bridge backup 缺失 crontab 时 fail-fast"
    fi

    cat > "${fakebin}/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${fakebin}/pgrep"

    cat > "${fakebin}/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${fakebin}/systemctl"

    cat > "${fakebin}/service" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${fakebin}/service"

    local bridge_stopped_cronfile="${temp_root}/bridge-backup-crontab-stopped.txt"
    if BIFROST_TEST_CRONTAB_FILE="${bridge_stopped_cronfile}" \
        PATH="${fakebin}:${PATH}" \
        TMP_ROOT="${temp_root}" \
        BACKUP_SH="${SCRIPT_DIR}/ai-gateway-bridge/scripts/backup.sh" \
        bash -c '
            set -euo pipefail
            source "$BACKUP_SH"
            BACKUP_BASE_DIR="${TMP_ROOT}/backups-stopped"
            BACKUP_ENCRYPTION_KEY_FILE="${TMP_ROOT}/backup-stopped.key"
            LOG_DIR="${TMP_ROOT}/logs-stopped"
            if setup_auto_backup; then
                exit 1
            fi
            ! grep -q "# ai-gateway-bridge-daily-backup" "${BIFROST_TEST_CRONTAB_FILE}" 2>/dev/null
        '; then
        record_pass "AI Gateway Bridge backup 在 crontab 存在但调度器未运行时会 fail-fast"
    else
        record_fail "AI Gateway Bridge backup 在 crontab 存在但调度器未运行时会 fail-fast"
    fi

    if BIFROST_TEST_CRONTAB_FILE="${cronfile}" \
        PATH="${fakebin}:${PATH}" \
        TMP_ROOT="${temp_root}" \
        BACKUP_SH="${SCRIPT_DIR}/ai-gateway-bridge/scripts/backup.sh" \
        bash -c '
            set -euo pipefail
            source "$BACKUP_SH"
            BACKUP_BASE_DIR="${TMP_ROOT}/content-backups"
            BACKUP_ENCRYPTION_KEY_FILE="${TMP_ROOT}/backup-content.key"
            XRAY_CONFIG_DIR="${TMP_ROOT}/content-src/usr/local/etc/xray"
            CADDY_CONFIG_DIR="${TMP_ROOT}/content-src/etc/caddy"
            MIHOMO_CONFIG_DIR="${TMP_ROOT}/content-src/etc/mihomo"
            NEW_API_DIR="${TMP_ROOT}/content-src/opt/new-api"
            INSTALL_DIR="${TMP_ROOT}/content-src/opt/ai-gateway-bridge"
            SECURITY_STATE_DIR="${TMP_ROOT}/content-src/etc/ai-gateway-bridge"
            FAIL2BAN_CONFIG="${TMP_ROOT}/content-src/etc/fail2ban"
            SYSCTL_HARDENING="${TMP_ROOT}/content-src/etc/sysctl.d/99-ai-gateway-hardening.conf"
            SERVER_B_CONF="${TMP_ROOT}/content-src/root/server-b-connection.conf"
            CONNECTION_INFO="${TMP_ROOT}/content-src/root/ai-gateway-connection.txt"

            mkdir -p "${XRAY_CONFIG_DIR}" \
                "${CADDY_CONFIG_DIR}" \
                "${SECURITY_STATE_DIR}" \
                "$(dirname "${SYSCTL_HARDENING}")" \
                "$(dirname "${SERVER_B_CONF}")" \
                "$(dirname "${CONNECTION_INFO}")"
            printf "{\"test\":true}\n" > "${XRAY_CONFIG_DIR}/config.json"
            printf ":443 { respond \"ok\" }\n" > "${CADDY_CONFIG_DIR}/Caddyfile"
            printf "SECURITY_STATE=1\n" > "${SECURITY_STATE_DIR}/state.env"
            printf "net.ipv4.ip_forward=1\n" > "${SYSCTL_HARDENING}"
            printf "SERVER_B_IP=203.0.113.10\n" > "${SERVER_B_CONF}"
            printf "Connection info\n" > "${CONNECTION_INFO}"
            printf "*/5 * * * * /usr/bin/echo health\n" > "${BIFROST_TEST_CRONTAB_FILE}"

            backup_config

            archive="$(find "${BACKUP_BASE_DIR}" -maxdepth 1 -name "backup-*.tar.gz.enc" | head -1)"
            test -n "${archive}"
            openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
                -in "${archive}" \
                -out "${TMP_ROOT}/content-backup.tar.gz" \
                -pass "pass:$(cat "${BACKUP_ENCRYPTION_KEY_FILE}")" 2>/dev/null
            tar tzf "${TMP_ROOT}/content-backup.tar.gz" > "${TMP_ROOT}/content-backup.list"

            grep -q "/usr/local/etc/xray/config.json$" "${TMP_ROOT}/content-backup.list"
            grep -q "/etc/caddy/Caddyfile$" "${TMP_ROOT}/content-backup.list"
            grep -q "/backup-content.key$" "${TMP_ROOT}/content-backup.list"
            grep -q "^metadata/crontab.txt$" "${TMP_ROOT}/content-backup.list"
            grep -q "^metadata/docker-info.txt$" "${TMP_ROOT}/content-backup.list"
        '; then
        record_pass "AI Gateway Bridge backup 归档同时包含 configs payload + metadata"
    else
        record_fail "AI Gateway Bridge backup 归档同时包含 configs payload + metadata"
    fi

    if TMP_ROOT="${temp_root}" \
        BACKUP_SH="${SCRIPT_DIR}/ai-gateway-bridge/scripts/backup.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$BACKUP_SH"
            XRAY_CONFIG_DIR="${TMP_ROOT}/bridge-rotate-empty/usr/local/etc/xray"
            MIHOMO_CONFIG_DIR="${TMP_ROOT}/bridge-rotate-empty/etc/mihomo"
            SERVER_B_CONF="${TMP_ROOT}/bridge-rotate-empty/root/server-b-connection.conf"
            CONNECTION_INFO="${TMP_ROOT}/bridge-rotate-empty/root/ai-gateway-connection.txt"
            confirm_action() { return 0; }
            backup_config() { return 0; }
            install_if_missing() { return 1; }
            command_exists() { return 1; }
            sleep() { :; }
            if emergency_ip_rotation "198.51.100.20" >"${output_file}" 2>&1; then
                exit 1
            fi
            grep -q "No configuration files were updated. IP rotation aborted." "${output_file}"
            ! grep -q "IP rotation complete" "${output_file}"
        '; then
        record_pass "AI Gateway Bridge backup rotate-ip 在零变更时 fail-fast 且不打印完成摘要"
    else
        record_fail "AI Gateway Bridge backup rotate-ip 在零变更时 fail-fast 且不打印完成摘要"
    fi

    if TMP_ROOT="${temp_root}" \
        BACKUP_SH="${SCRIPT_DIR}/ai-gateway-bridge/scripts/backup.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$BACKUP_SH"
            XRAY_CONFIG_DIR="${TMP_ROOT}/bridge-rotate-connectivity/usr/local/etc/xray"
            MIHOMO_CONFIG_DIR="${TMP_ROOT}/bridge-rotate-connectivity/etc/mihomo"
            SERVER_B_CONF="${TMP_ROOT}/bridge-rotate-connectivity/root/server-b-connection.conf"
            CONNECTION_INFO="${TMP_ROOT}/bridge-rotate-connectivity/root/ai-gateway-connection.txt"
            mkdir -p "${XRAY_CONFIG_DIR}" "${MIHOMO_CONFIG_DIR}" "$(dirname "${SERVER_B_CONF}")" "$(dirname "${CONNECTION_INFO}")"
            printf "{\"outbounds\":[{\"tag\":\"proxy\",\"settings\":{\"vnext\":[{\"address\":\"203.0.113.10\"}]}}]}\n" > "${XRAY_CONFIG_DIR}/config.json"
            printf "proxies:\n  - name: test\n    server: 203.0.113.10\n" > "${MIHOMO_CONFIG_DIR}/config.yaml"
            printf "SERVER_B_IP=203.0.113.10\n" > "${SERVER_B_CONF}"
            printf "Server B: 203.0.113.10\n" > "${CONNECTION_INFO}"
            confirm_action() { return 0; }
            backup_config() { return 0; }
            install_if_missing() { return 1; }
            command_exists() {
                [[ "$1" == "systemctl" ]]
            }
            systemctl() {
                case "$1" in
                    is-active|restart) return 0 ;;
                    *) return 1 ;;
                esac
            }
            curl() { return 1; }
            sleep() { :; }
            if emergency_ip_rotation "198.51.100.20" >"${output_file}" 2>&1; then
                exit 1
            fi
            grep -q "Connectivity test failed (HTTP 000). Configuration was updated but tunnel verification failed." "${output_file}"
            ! grep -q "IP rotation complete" "${output_file}"
            grep -q "198.51.100.20" "${XRAY_CONFIG_DIR}/config.json"
            grep -q "198.51.100.20" "${MIHOMO_CONFIG_DIR}/config.yaml"
            grep -q "SERVER_B_IP=198.51.100.20" "${SERVER_B_CONF}"
        '; then
        record_pass "AI Gateway Bridge backup rotate-ip 在 tunnel 验证失败时返回失败且不打印完成摘要"
    else
        record_fail "AI Gateway Bridge backup rotate-ip 在 tunnel 验证失败时返回失败且不打印完成摘要"
    fi

    if TMP_ROOT="${temp_root}" \
        BACKUP_SH="${SCRIPT_DIR}/ai-gateway-bridge/scripts/backup.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$BACKUP_SH"
            trap - EXIT ERR
            XRAY_CONFIG_DIR="${TMP_ROOT}/bridge-rotate-backup-fail/usr/local/etc/xray"
            MIHOMO_CONFIG_DIR="${TMP_ROOT}/bridge-rotate-backup-fail/etc/mihomo"
            SERVER_B_CONF="${TMP_ROOT}/bridge-rotate-backup-fail/root/server-b-connection.conf"
            CONNECTION_INFO="${TMP_ROOT}/bridge-rotate-backup-fail/root/ai-gateway-connection.txt"
            mkdir -p "${XRAY_CONFIG_DIR}" "${MIHOMO_CONFIG_DIR}" "$(dirname "${SERVER_B_CONF}")" "$(dirname "${CONNECTION_INFO}")"
            printf "{\"outbounds\":[{\"tag\":\"proxy\",\"settings\":{\"vnext\":[{\"address\":\"203.0.113.10\"}]}}]}\n" > "${XRAY_CONFIG_DIR}/config.json"
            printf "proxies:\n  - name: test\n    server: 203.0.113.10\n" > "${MIHOMO_CONFIG_DIR}/config.yaml"
            printf "SERVER_B_IP=203.0.113.10\n" > "${SERVER_B_CONF}"
            printf "Server B: 203.0.113.10\n" > "${CONNECTION_INFO}"
            confirm_action() { return 0; }
            backup_config() { return 1; }
            install_if_missing() { return 1; }
            command_exists() { return 1; }
            failed=0
            set +e
            emergency_ip_rotation "198.51.100.20" >"${output_file}" 2>&1
            status=$?
            [[ "${status}" -ne 0 ]] || failed=1
            grep -q "Pre-rotation backup failed. Refusing to continue with IP rotation." "${output_file}" || failed=1
            ! grep -q "IP rotation complete" "${output_file}" || failed=1
            grep -q "203.0.113.10" "${XRAY_CONFIG_DIR}/config.json" || failed=1
            grep -q "203.0.113.10" "${MIHOMO_CONFIG_DIR}/config.yaml" || failed=1
            grep -q "SERVER_B_IP=203.0.113.10" "${SERVER_B_CONF}" || failed=1
            if [[ "${failed}" -ne 0 ]]; then
                cat "${output_file}" >&2
                exit 1
            fi
        '; then
        record_pass "AI Gateway Bridge backup rotate-ip 在预备份失败时会拒绝修改配置"
    else
        record_fail "AI Gateway Bridge backup rotate-ip 在预备份失败时会拒绝修改配置"
    fi

    rm -rf "${temp_root}"
}

test_diagnostics_contracts() {
    info "=== Diagnostics 报告导出真实性契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local py_cmd
    if ! py_cmd="$(find_python_cmd)"; then
        record_fail "缺少 Python 运行时，无法验证 diagnostics JSON 报告"
        rm -rf "${temp_root}"
        return
    fi

    if TMP_ROOT="${temp_root}" \
        PY_CMD="${py_cmd}" \
        DIAG_SH="${SCRIPT_DIR}/scripts/diagnostics.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$DIAG_SH"
            TMPDIR="${TMP_ROOT}/tmp"
            mkdir -p "${TMPDIR}"
            REPORT_DIR="/proc/bifrost-diag-denied"
            run_full_diagnostic() {
                DIAG_TIMESTAMP="2026-03-27T00:00:00Z"
                DIAG_OVERALL="degraded"
                DIAG_SYSTEM=([os]="Ubuntu \"24.04\"" [path]="C:\\diag\\root")
                DIAG_SERVICES=([quoted]="service \"needs\\escape\"")
                DIAG_NETWORK=([newline]=$'"'"'line1\nline2'"'"')
                DIAG_DNS=([resolver]="1.1.1.1")
                DIAG_SPEED=([latency]="123ms")
                DIAG_GFW=([summary]="possible")
            }
            generate_diagnostic_report >"${output_file}" 2>&1
            latest="${TMPDIR}/bifrost/diagnostic-report.json"
            test -f "${latest}"
            grep -q "Diagnostic report saved." "${output_file}"
            grep -q "Default report directory /proc/bifrost-diag-denied was not writable; used fallback ${TMPDIR}/bifrost" "${output_file}"
            "$PY_CMD" - "${latest}" <<'"'"'PY'"'"'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)

assert payload["timestamp"] == "2026-03-27T00:00:00Z"
assert payload["overall_status"] == "degraded"
assert payload["system"]["os"] == "Ubuntu \"24.04\""
assert payload["system"]["path"] == "C:\\diag\\root"
assert payload["services"]["quoted"] == "service \"needs\\escape\""
assert payload["network"]["newline"] == "line1\nline2"
PY
        '; then
        record_pass "Root diagnostics report 会输出可解析 JSON 并在默认目录不可写时回退"
    else
        record_fail "Root diagnostics report 会输出可解析 JSON 并在默认目录不可写时回退"
    fi

    rm -rf "${temp_root}"
}

test_bridge_diagnostics_contracts() {
    info "=== AI Gateway Bridge Diagnostics 报告导出真实性契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local py_cmd
    if ! py_cmd="$(find_python_cmd)"; then
        record_fail "缺少 Python 运行时，无法验证 AI Gateway Bridge diagnostics JSON 报告"
        rm -rf "${temp_root}"
        return
    fi

    if TMP_ROOT="${temp_root}" \
        PY_CMD="${py_cmd}" \
        DIAG_SH="${SCRIPT_DIR}/ai-gateway-bridge/scripts/diagnostics.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$DIAG_SH"
            TMPDIR="${TMP_ROOT}/tmp"
            mkdir -p "${TMPDIR}"
            REPORT_DIR="/proc/bridge-diag-denied"
            run_full_diagnostic() {
                DIAG_TIMESTAMP="2026-03-27T00:00:00Z"
                DIAG_OVERALL="degraded"
                DIAG_SYSTEM=([os]="Ubuntu \"24.04\"" [path]="C:\\diag\\bridge")
                DIAG_SERVICES=([quoted]="bridge \"needs\\escape\"")
                DIAG_NETWORK=([newline]=$'"'"'bridge\nline'"'"')
                DIAG_DNS=([resolver]="8.8.8.8")
                DIAG_SPEED=([latency]="456ms")
                DIAG_GFW=([summary]="possible")
            }
            generate_diagnostic_report >"${output_file}" 2>&1
            latest="${TMPDIR}/ai-gateway-bridge/diagnostic-report.json"
            test -f "${latest}"
            grep -q "Diagnostic report saved." "${output_file}"
            grep -q "Default report directory /proc/bridge-diag-denied was not writable; used fallback ${TMPDIR}/ai-gateway-bridge" "${output_file}"
            "$PY_CMD" - "${latest}" <<'"'"'PY'"'"'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)

assert payload["timestamp"] == "2026-03-27T00:00:00Z"
assert payload["overall_status"] == "degraded"
assert payload["system"]["os"] == "Ubuntu \"24.04\""
assert payload["system"]["path"] == "C:\\diag\\bridge"
assert payload["services"]["quoted"] == "bridge \"needs\\escape\""
assert payload["network"]["newline"] == "bridge\nline"
PY
        '; then
        record_pass "AI Gateway Bridge diagnostics report 会输出可解析 JSON 并在默认目录不可写时回退"
    else
        record_fail "AI Gateway Bridge diagnostics report 会输出可解析 JSON 并在默认目录不可写时回退"
    fi

    rm -rf "${temp_root}"
}

test_uninstall_contracts() {
    info "=== Uninstall cron 清理边界契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local fakebin="${temp_root}/bin"
    local cronfile="${temp_root}/uninstall-crontab.txt"
    mkdir -p "${fakebin}" "${temp_root}/cron.weekly" "${temp_root}/cron.monthly"

    cat > "${fakebin}/crontab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cronfile="${BIFROST_TEST_CRONTAB_FILE:?}"

case "${1:-}" in
    -l)
        [[ -f "${cronfile}" ]] && cat "${cronfile}"
        ;;
    -|"")
        cat > "${cronfile}"
        ;;
    *)
        echo "unsupported crontab args: $*" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "${fakebin}/crontab"

    cat > "${cronfile}" <<'EOF'
*/5 * * * * /opt/custom-health-check.sh
0 0 * * * /usr/bin/rkhunter --check
0 3 * * * /opt/bifrost/scripts/backup.sh backup >> /var/log/bifrost/backup-cron.log 2>&1 # bifrost-daily-backup
*/5 * * * * /opt/bifrost/scripts/health-check.sh >> /var/log/bifrost/health-cron.log 2>&1 # bifrost-health-check
# bifrost: dest rotation
17 3 * * 0 /opt/bifrost/rotate-dest.sh >> /var/log/bifrost/rotate-dest.log 2>&1
EOF
    printf '#!/usr/bin/env bash\n' > "${temp_root}/cron.weekly/rkhunter-scan"
    printf '#!/usr/bin/env bash\n' > "${temp_root}/cron.monthly/lynis-audit"

    if BIFROST_TEST_CRONTAB_FILE="${cronfile}" \
        PATH="${fakebin}:${PATH}" \
        TMP_ROOT="${temp_root}" \
        UNINSTALL_SH="${SCRIPT_DIR}/scripts/uninstall.sh" \
        bash -lc '
            set -euo pipefail
            source "$UNINSTALL_SH"
            ANTI_DPI_ROTATE_CRON_SCRIPT="/opt/bifrost/rotate-dest.sh"
            RKHUNTER_CRON_FILE="${TMP_ROOT}/cron.weekly/rkhunter-scan"
            LYNIS_CRON_FILE="${TMP_ROOT}/cron.monthly/lynis-audit"
            remove_cron_jobs

            grep -q "/opt/custom-health-check.sh" "${BIFROST_TEST_CRONTAB_FILE}"
            grep -q "/usr/bin/rkhunter --check" "${BIFROST_TEST_CRONTAB_FILE}"
            ! grep -q "bifrost-daily-backup" "${BIFROST_TEST_CRONTAB_FILE}"
            ! grep -q "bifrost-health-check" "${BIFROST_TEST_CRONTAB_FILE}"
            ! grep -q "/opt/bifrost/rotate-dest.sh" "${BIFROST_TEST_CRONTAB_FILE}"
            ! grep -q "# bifrost: dest rotation" "${BIFROST_TEST_CRONTAB_FILE}"
            [[ ! -f "${RKHUNTER_CRON_FILE}" ]]
            [[ ! -f "${LYNIS_CRON_FILE}" ]]
        '; then
        record_pass "Uninstall 仅删除 Bifrost 自有 cron，不误删用户任务"
    else
        record_fail "Uninstall 仅删除 Bifrost 自有 cron，不误删用户任务"
    fi

    rm -rf "${temp_root}"
}

test_bridge_uninstall_contracts() {
    info "=== AI Gateway Bridge uninstall cron 清理边界契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local fakebin="${temp_root}/bin"
    local cronfile="${temp_root}/bridge-uninstall-crontab.txt"
    mkdir -p "${fakebin}" "${temp_root}/cron.weekly" "${temp_root}/cron.monthly"

    cat > "${fakebin}/crontab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cronfile="${BIFROST_TEST_CRONTAB_FILE:?}"

case "${1:-}" in
    -l)
        [[ -f "${cronfile}" ]] && cat "${cronfile}"
        ;;
    -|"")
        cat > "${cronfile}"
        ;;
    *)
        echo "unsupported crontab args: $*" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "${fakebin}/crontab"

    cat > "${cronfile}" <<'EOF'
*/5 * * * * /opt/custom-health-check.sh
0 0 * * * /usr/bin/rkhunter --check
0 3 * * * /opt/ai-gateway-bridge/scripts/backup.sh backup >> /var/log/ai-gateway-bridge/backup-cron.log 2>&1 # ai-gateway-bridge-daily-backup
*/5 * * * * /opt/ai-gateway-bridge/scripts/health-check.sh >> /var/log/ai-gateway-bridge/health-cron.log 2>&1 # ai-gateway-bridge-health-check
# ai-gateway-bridge: dest rotation
17 3 * * 0 /opt/ai-gateway-bridge/rotate-dest.sh >> /var/log/ai-gateway-bridge/rotate-dest.log 2>&1
EOF
    printf '#!/usr/bin/env bash\n' > "${temp_root}/cron.weekly/rkhunter-scan"
    printf '#!/usr/bin/env bash\n' > "${temp_root}/cron.monthly/lynis-audit"

    if BIFROST_TEST_CRONTAB_FILE="${cronfile}" \
        PATH="${fakebin}:${PATH}" \
        TMP_ROOT="${temp_root}" \
        UNINSTALL_SH="${SCRIPT_DIR}/ai-gateway-bridge/scripts/uninstall.sh" \
        bash -lc '
            set -euo pipefail
            source "$UNINSTALL_SH"
            ANTI_DPI_ROTATE_CRON_SCRIPT="/opt/ai-gateway-bridge/rotate-dest.sh"
            RKHUNTER_CRON_FILE="${TMP_ROOT}/cron.weekly/rkhunter-scan"
            LYNIS_CRON_FILE="${TMP_ROOT}/cron.monthly/lynis-audit"
            remove_cron_jobs

            grep -q "/opt/custom-health-check.sh" "${BIFROST_TEST_CRONTAB_FILE}"
            grep -q "/usr/bin/rkhunter --check" "${BIFROST_TEST_CRONTAB_FILE}"
            ! grep -q "ai-gateway-bridge-daily-backup" "${BIFROST_TEST_CRONTAB_FILE}"
            ! grep -q "ai-gateway-bridge-health-check" "${BIFROST_TEST_CRONTAB_FILE}"
            ! grep -q "/opt/ai-gateway-bridge/rotate-dest.sh" "${BIFROST_TEST_CRONTAB_FILE}"
            ! grep -q "# ai-gateway-bridge: dest rotation" "${BIFROST_TEST_CRONTAB_FILE}"
            [[ ! -f "${RKHUNTER_CRON_FILE}" ]]
            [[ ! -f "${LYNIS_CRON_FILE}" ]]
        '; then
        record_pass "AI Gateway Bridge uninstall 仅删除自有 cron，不误删用户任务"
    else
        record_fail "AI Gateway Bridge uninstall 仅删除自有 cron，不误删用户任务"
    fi

    rm -rf "${temp_root}"
}

test_supply_chain_contracts() {
    info "=== 供应链 / Trust Bootstrap 契约 ==="

    if grep -Eq "gitee.com/neilpang/acme.sh/raw/master/acme.sh|curl -fsSL.*\|\s*sh -s -- --install-online" scripts/server-b.sh; then
        record_fail "Server B 不应再通过第三方 mirror 直接 pipe 执行 acme.sh"
    else
        record_pass "Server B 不再通过第三方 mirror 直接 pipe 执行 acme.sh"
    fi

    if grep -q "acmesh-official/get.acme.sh/master/index.html" scripts/server-b.sh; then
        record_pass "Server B acme.sh fallback 已收敛到官方 GitHub 源"
    else
        record_fail "Server B acme.sh fallback 已收敛到官方 GitHub 源"
    fi

    if grep -Eq "gpg --dearmor.*\|\| true" scripts/server-b.sh scripts/security.sh; then
        record_fail "关键仓库 key 导入不应吞掉失败"
    else
        record_pass "关键仓库 key 导入失败时会 fail-fast"
    fi

    if grep -q "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg" scripts/server-a.sh; then
        record_fail "Server A 的 Caddy key 导入不应缺少 fail-fast 包裹"
    else
        record_pass "Server A 的 Caddy key 导入已具备 fail-fast 包裹"
    fi

    if grep -Eq 'echo "\\$\\{_xray_script\\}" \\| bash -s -- install|echo "y" \\| bash -c "\\$\\{_3xui_script\\}"' scripts/server-b.sh; then
        record_fail "Server B 不应再通过 echo/bach -c 形式执行下载脚本正文"
    else
        record_pass "Server B 下载脚本正文已改为 stdin 执行，避免额外 shell 字符串解释"
    fi

    if grep -q 'BIFROST_NEW_API_IMAGE' scripts/server-a.sh && \
       grep -q 'Refusing mutable New API image' scripts/server-a.sh && \
       grep -q 'BIFROST_ALLOW_UNPINNED' scripts/server-a.sh; then
        record_pass "Server A 生产 profile 会拒绝未显式允许的 New API latest 镜像"
    else
        record_fail "Server A 生产 profile 会拒绝未显式允许的 New API latest 镜像"
    fi

    if grep -q 'prepare_new_api_env' scripts/server-a.sh && \
       grep -q 'NEW_API_ENV_FILE="${NEW_API_DIR}/.env"' scripts/server-a.sh && \
       grep -q 'docker compose config --quiet' scripts/server-a.sh && \
       grep -q 'sslmode=disable' scripts/server-a.sh && \
       grep -q 'verify_new_api_port_binding' scripts/server-a.sh && \
       grep -q 'diagnose_new_api_startup_failure' scripts/server-a.sh; then
        record_pass "Server A New API 一键部署会持久化 env、预检 compose、限制 3000 暴露并诊断 Postgres 漂移"
    else
        record_fail "Server A New API 一键部署缺少 env/compose/端口/Postgres 漂移门禁"
    fi

    if grep -q 'cloudflare-origin' scripts/server-a.sh && \
       grep -q 'collect_cloudflare_origin_tls_files' scripts/server-a.sh && \
       grep -q 'BIFROST_CLOUDFLARE_ORIGIN_CERT' scripts/server-a.sh && \
       grep -q 'Cloudflare DNS for' scripts/server-a.sh; then
        record_pass "Server A Caddy 支持 Cloudflare Origin CA 显式证书文件模式"
    else
        record_fail "Server A Caddy 缺少 Cloudflare Origin CA 显式证书文件模式"
    fi

    if grep -Eq 'Default Admin: root|Default Pass : 123456|New API Admin Pass : 123456|root/123456' scripts/server-a.sh; then
        record_fail "Server A 不应继续输出 New API 弱默认管理员口令"
    else
        record_pass "Server A 不再输出 New API 弱默认管理员口令"
    fi
}

test_bridge_supply_chain_contracts() {
    info "=== AI Gateway Bridge 供应链 / Trust Bootstrap 契约 ==="

    if grep -Eq "gitee.com/neilpang/acme.sh/raw/master/acme.sh|curl -fsSL.*\|\s*sh -s -- --install-online" ai-gateway-bridge/scripts/server-b.sh; then
        record_fail "AI Gateway Bridge Server B 不应再通过第三方 mirror 直接 pipe 执行 acme.sh"
    else
        record_pass "AI Gateway Bridge Server B 不再通过第三方 mirror 直接 pipe 执行 acme.sh"
    fi

    if grep -q "acmesh-official/get.acme.sh/master/index.html" ai-gateway-bridge/scripts/server-b.sh; then
        record_pass "AI Gateway Bridge Server B acme.sh fallback 已收敛到官方 GitHub 源"
    else
        record_fail "AI Gateway Bridge Server B acme.sh fallback 已收敛到官方 GitHub 源"
    fi

    if grep -Eq "gpg --dearmor.*\|\| true" ai-gateway-bridge/scripts/server-b.sh ai-gateway-bridge/scripts/security.sh; then
        record_fail "AI Gateway Bridge 关键仓库 key 导入不应吞掉失败"
    else
        record_pass "AI Gateway Bridge 关键仓库 key 导入失败时会 fail-fast"
    fi

    if grep -q "curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg" ai-gateway-bridge/scripts/server-a.sh; then
        record_fail "AI Gateway Bridge Server A 的 Caddy key 导入不应缺少 fail-fast 包裹"
    else
        record_pass "AI Gateway Bridge Server A 的 Caddy key 导入已具备 fail-fast 包裹"
    fi

    if BRIDGE_COMMON_SH="${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" \
        bash -c '
            set -euo pipefail
            source "$BRIDGE_COMMON_SH" >/dev/null 2>&1
            github_download() {
                local url="$1"
                local dest="$2"
                local max_time="${3:-60}"
                printf "noise-from-download-helper\\n"
                printf "#!/usr/bin/env bash\\necho bridge-ok\\n" > "${dest}"
                return 0
            }
            output="$(github_download_script "https://example.com/script.sh" 2>/dev/null)"
            [[ "${output}" == $'"'"'#!/usr/bin/env bash\necho bridge-ok'"'"' ]]
        '; then
        record_pass "AI Gateway Bridge github_download_script 不会把下载日志污染到脚本 stdout"
    else
        record_fail "AI Gateway Bridge github_download_script 不会把下载日志污染到脚本 stdout"
    fi

    if BRIDGE_COMMON_SH="${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" \
        BIFROST_TRACE_COMMON_LOAD=0 \
        bash -c '
            set -euo pipefail
            tmp_out="$(mktemp)"
            { source "$BRIDGE_COMMON_SH"; } >"${tmp_out}" 2>&1
            [[ ! -s "${tmp_out}" ]]
            declare -f github_fetch_text >/dev/null
            declare -f github_clone_repo >/dev/null
            rm -f "${tmp_out}"
        '; then
        record_pass "AI Gateway Bridge common.sh 默认静默加载，且补齐 GitHub helper 契约"
    else
        record_fail "AI Gateway Bridge common.sh 默认静默加载，且补齐 GitHub helper 契约"
    fi

    if grep -Eq 'echo "\\$\\{_xray_script\\}" \\| bash -s -- install|echo "y" \\| bash -c "\\$\\{_3xui_script\\}"' ai-gateway-bridge/scripts/server-b.sh; then
        record_fail "AI Gateway Bridge Server B 不应再通过 echo/bash -c 形式执行下载脚本正文"
    else
        record_pass "AI Gateway Bridge Server B 下载脚本正文已改为 stdin 执行，避免额外 shell 字符串解释"
    fi

    if grep -q 'github_fetch_text "${api_url}" 20 10' ai-gateway-bridge/scripts/server-b.sh && \
       ! grep -q 'ghproxy.net/${api_url}' ai-gateway-bridge/scripts/server-b.sh; then
        record_pass "AI Gateway Bridge Server B 的 Xray 版本解析已收敛到共享 GitHub helper"
    else
        record_fail "AI Gateway Bridge Server B 的 Xray 版本解析已收敛到共享 GitHub helper"
    fi

    if grep -q 'BIFROST_NEW_API_IMAGE' ai-gateway-bridge/scripts/server-a.sh && \
       grep -q 'Refusing mutable New API image' ai-gateway-bridge/scripts/server-a.sh && \
       grep -q 'BIFROST_ALLOW_UNPINNED' ai-gateway-bridge/scripts/server-a.sh; then
        record_pass "AI Gateway Bridge Server A 生产 profile 会拒绝未显式允许的 New API latest 镜像"
    else
        record_fail "AI Gateway Bridge Server A 生产 profile 会拒绝未显式允许的 New API latest 镜像"
    fi

    if grep -q 'prepare_new_api_env' ai-gateway-bridge/scripts/server-a.sh && \
       grep -q 'NEW_API_ENV_FILE="${NEW_API_DIR}/.env"' ai-gateway-bridge/scripts/server-a.sh && \
       grep -q 'docker compose config --quiet' ai-gateway-bridge/scripts/server-a.sh && \
       grep -q 'sslmode=disable' ai-gateway-bridge/scripts/server-a.sh && \
       grep -q 'verify_new_api_port_binding' ai-gateway-bridge/scripts/server-a.sh && \
       grep -q 'diagnose_new_api_startup_failure' ai-gateway-bridge/scripts/server-a.sh; then
        record_pass "AI Gateway Bridge Server A New API 一键部署会持久化 env、预检 compose、限制 3000 暴露并诊断 Postgres 漂移"
    else
        record_fail "AI Gateway Bridge Server A New API 一键部署缺少 env/compose/端口/Postgres 漂移门禁"
    fi

    if grep -q 'cloudflare-origin' ai-gateway-bridge/scripts/server-a.sh && \
       grep -q 'collect_cloudflare_origin_tls_files' ai-gateway-bridge/scripts/server-a.sh && \
       grep -q 'BIFROST_CLOUDFLARE_ORIGIN_CERT' ai-gateway-bridge/scripts/server-a.sh && \
       grep -q 'Cloudflare DNS for' ai-gateway-bridge/scripts/server-a.sh; then
        record_pass "AI Gateway Bridge Server A Caddy 支持 Cloudflare Origin CA 显式证书文件模式"
    else
        record_fail "AI Gateway Bridge Server A Caddy 缺少 Cloudflare Origin CA 显式证书文件模式"
    fi

    if grep -q '^require_docker_server_version()' ai-gateway-bridge/scripts/common.sh && \
       grep -q 'require_docker_server_version "20.10.0" "New API Docker host-gateway mapping"' ai-gateway-bridge/scripts/server-a.sh; then
        record_pass "AI Gateway Bridge Server A 部署 New API 前会验证 host-gateway 所需 Docker 版本"
    else
        record_fail "AI Gateway Bridge Server A 部署 New API 前缺少 host-gateway Docker 版本门禁"
    fi

    if grep -Eq 'Default Admin: root|Default Pass : 123456|New API Admin Pass : 123456|root/123456' ai-gateway-bridge/scripts/server-a.sh; then
        record_fail "AI Gateway Bridge Server A 不应继续输出 New API 弱默认管理员口令"
    else
        record_pass "AI Gateway Bridge Server A 不再输出 New API 弱默认管理员口令"
    fi
}

test_update_contracts() {
    info "=== Update 更新链路安全契约 ==="

    if grep -Eq 'eval "\$\{run_cmd\}"|log_info "Running: \$\{run_cmd\}"' "${SCRIPT_DIR}/scripts/update.sh"; then
        record_fail "Root update.sh 不应使用 eval 重建容器或输出完整 docker run 命令"
    else
        record_pass "Root update.sh 已移除 eval 容器重建与敏感命令回显"
    fi

    local temp_root
    temp_root="$(mktemp -d)"
    local workdir="${temp_root}/root-update"
    mkdir -p "${workdir}"
    cp "${SCRIPT_DIR}/scripts/update.sh" "${workdir}/update.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${workdir}/common.sh"

    if UPDATE_SH="${workdir}/update.sh" \
        bash -c '
            set -euo pipefail
            source "$UPDATE_SH"
            install_if_missing() { return 0; }
            _get_installed_xray_version() { echo "1.8.0"; }
            _get_installed_mihomo_version() { echo "1.18.0"; }
            _get_github_latest_version() { return 0; }
            confirm_action() { CONFIRM_CALLED=1; return 0; }
            github_download() { DOWNLOAD_CALLED=1; return 0; }

            if update_xray; then
                exit 1
            fi
            [[ "${CONFIRM_CALLED:-0}" == 0 ]]
            [[ "${DOWNLOAD_CALLED:-0}" == 0 ]]

            unset CONFIRM_CALLED DOWNLOAD_CALLED
            if update_mihomo; then
                exit 1
            fi
            [[ "${CONFIRM_CALLED:-0}" == 0 ]]
            [[ "${DOWNLOAD_CALLED:-0}" == 0 ]]
        '; then
        record_pass "Root update.sh 在 release 元数据缺失时会拒绝盲重装"
    else
        record_fail "Root update.sh 在 release 元数据缺失时会拒绝盲重装"
    fi

    rm -rf "${temp_root}"
}

test_bridge_update_contracts() {
    info "=== AI Gateway Bridge Update 更新链路安全契约 ==="

    if grep -Eq 'eval "\$\{run_cmd\}"|log_info "Running: \$\{run_cmd\}"' "${SCRIPT_DIR}/ai-gateway-bridge/scripts/update.sh"; then
        record_fail "AI Gateway Bridge update.sh 不应使用 eval 重建容器或输出完整 docker run 命令"
    else
        record_pass "AI Gateway Bridge update.sh 已移除 eval 容器重建与敏感命令回显"
    fi

    if grep -q 'github_fetch_text "${api_url}" 20 10' "${SCRIPT_DIR}/ai-gateway-bridge/scripts/update.sh" && \
       grep -q 'github_fetch_text "https://api.github.com" 10 5' "${SCRIPT_DIR}/ai-gateway-bridge/scripts/update.sh" && \
       grep -q 'github_fetch_text "${MIHOMO_RELEASES_API}" 20 10' "${SCRIPT_DIR}/ai-gateway-bridge/scripts/update.sh" && \
       ! grep -q 'ghproxy.net/${api_url}' "${SCRIPT_DIR}/ai-gateway-bridge/scripts/update.sh" && \
       ! grep -q 'ghproxy.net/${MIHOMO_RELEASES_API}' "${SCRIPT_DIR}/ai-gateway-bridge/scripts/update.sh"; then
        record_pass "AI Gateway Bridge update.sh 已收敛到共享 GitHub helper，不再硬编码 ghproxy 分支"
    else
        record_fail "AI Gateway Bridge update.sh 已收敛到共享 GitHub helper，不再硬编码 ghproxy 分支"
    fi

    if grep -q 'github_fetch_text "${api_url}" 20 10' "${SCRIPT_DIR}/ai-gateway-bridge/scripts/mihomo.sh" && \
       ! grep -q 'ghproxy.net/${api_url}' "${SCRIPT_DIR}/ai-gateway-bridge/scripts/mihomo.sh"; then
        record_pass "AI Gateway Bridge mihomo.sh 已收敛到共享 GitHub helper"
    else
        record_fail "AI Gateway Bridge mihomo.sh 已收敛到共享 GitHub helper"
    fi

    local temp_root
    temp_root="$(mktemp -d)"
    local workdir="${temp_root}/bridge-update"
    mkdir -p "${workdir}"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/update.sh" "${workdir}/update.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${workdir}/common.sh"

    if UPDATE_SH="${workdir}/update.sh" \
        bash -c '
            set -euo pipefail
            source "$UPDATE_SH"
            install_if_missing() { return 0; }
            _get_installed_xray_version() { echo "1.8.0"; }
            _get_installed_mihomo_version() { echo "1.18.0"; }
            _get_github_latest_version() { return 0; }
            confirm_action() { CONFIRM_CALLED=1; return 0; }
            github_download() { DOWNLOAD_CALLED=1; return 0; }

            if update_xray; then
                exit 1
            fi
            [[ "${CONFIRM_CALLED:-0}" == 0 ]]
            [[ "${DOWNLOAD_CALLED:-0}" == 0 ]]

            unset CONFIRM_CALLED DOWNLOAD_CALLED
            if update_mihomo; then
                exit 1
            fi
            [[ "${CONFIRM_CALLED:-0}" == 0 ]]
            [[ "${DOWNLOAD_CALLED:-0}" == 0 ]]
        '; then
        record_pass "AI Gateway Bridge update.sh 在 release 元数据缺失时会拒绝盲重装"
    else
        record_fail "AI Gateway Bridge update.sh 在 release 元数据缺失时会拒绝盲重装"
    fi

    rm -rf "${temp_root}"
}

test_bridge_monitoring_contracts() {
    info "=== AI Gateway Bridge Monitoring 健康检查部署契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local fakebin="${temp_root}/bin"
    local cronfile="${temp_root}/bridge-monitoring-crontab.txt"
    mkdir -p "${fakebin}" "${temp_root}/install" "${temp_root}/logs"

    cat > "${fakebin}/crontab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cronfile="${BIFROST_TEST_CRONTAB_FILE:?}"

case "${1:-}" in
    -l)
        [[ -f "${cronfile}" ]] && cat "${cronfile}"
        ;;
    -|"")
        cat > "${cronfile}"
        ;;
    *)
        echo "unsupported crontab args: $*" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "${fakebin}/crontab"

    cat > "${fakebin}/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${fakebin}/pgrep"

    if BIFROST_TEST_CRONTAB_FILE="${cronfile}" \
        PATH="${fakebin}:${PATH}" \
        INSTALL_DIR="${temp_root}/install" \
        LOG_DIR="${temp_root}/logs" \
        MONITORING_SH="${SCRIPT_DIR}/ai-gateway-bridge/scripts/monitoring.sh" \
        bash -c '
            set -euo pipefail
            source "$MONITORING_SH"
            setup_health_check
            test -x "${INSTALL_DIR}/health-check.sh"
            grep -q "check_xray" "${INSTALL_DIR}/health-check.sh"
            grep -q "check_tunnel" "${INSTALL_DIR}/health-check.sh"
            ! grep -q "minimal check" "${INSTALL_DIR}/health-check.sh"
            grep -q "# ai-gateway-bridge-health-check" "${BIFROST_TEST_CRONTAB_FILE}"
        '; then
        record_pass "AI Gateway Bridge monitoring 部署完整 health-check + cron"
    else
        record_fail "AI Gateway Bridge monitoring 部署完整 health-check + cron"
    fi

    local missing_root="${temp_root}/bridge-missing"
    mkdir -p "${missing_root}"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/monitoring.sh" "${missing_root}/monitoring.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${missing_root}/common.sh"

    if BIFROST_TEST_CRONTAB_FILE="${cronfile}" \
        PATH="${fakebin}:${PATH}" \
        INSTALL_DIR="${temp_root}/install-missing" \
        LOG_DIR="${temp_root}/logs-missing" \
        MONITORING_SH="${missing_root}/monitoring.sh" \
        bash -c '
            set -euo pipefail
            source "$MONITORING_SH"
            if setup_health_check; then
                exit 1
            fi
            exit 0
        '; then
        record_pass "AI Gateway Bridge monitoring 缺失 health-check 时 fail-fast"
    else
        record_fail "AI Gateway Bridge monitoring 缺失 health-check 时 fail-fast"
    fi

    cat > "${fakebin}/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${fakebin}/pgrep"

    cat > "${fakebin}/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${fakebin}/systemctl"

    local bridge_stopped_cronfile="${temp_root}/bridge-crontab-stopped.txt"
    if BIFROST_TEST_CRONTAB_FILE="${bridge_stopped_cronfile}" \
        PATH="${fakebin}:${PATH}" \
        INSTALL_DIR="${temp_root}/bridge-install-stopped" \
        LOG_DIR="${temp_root}/bridge-logs-stopped" \
        MONITORING_SH="${SCRIPT_DIR}/ai-gateway-bridge/scripts/monitoring.sh" \
        bash -c '
            set -euo pipefail
            source "$MONITORING_SH"
            if setup_health_check; then
                exit 1
            fi
            ! grep -q "# ai-gateway-bridge-health-check" "${BIFROST_TEST_CRONTAB_FILE}" 2>/dev/null
        '; then
        record_pass "AI Gateway Bridge monitoring 在 crontab 存在但调度器未运行时会 fail-fast"
    else
        record_fail "AI Gateway Bridge monitoring 在 crontab 存在但调度器未运行时会 fail-fast"
    fi

    rm -rf "${temp_root}"
}

test_mihomo_contracts() {
    info "=== Mihomo 配置编辑输入边界契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local workdir="${temp_root}/root-mihomo"
    mkdir -p "${workdir}"
    cp "${SCRIPT_DIR}/scripts/mihomo.sh" "${workdir}/mihomo.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${workdir}/common.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        MIHOMO_SH="${workdir}/mihomo.sh" \
        bash -c '
            set -euo pipefail
            source "$MIHOMO_SH"
            if add_mihomo_node "bad\"name" "127.0.0.1" "10810"; then
                exit 1
            fi
            if add_mihomo_node "safe-name" "bad address" "10810"; then
                exit 1
            fi
            exit 0
        '; then
        record_pass "Root mihomo add_mihomo_node 会拒绝危险名称/地址"
    else
        record_fail "Root mihomo add_mihomo_node 会拒绝危险名称/地址"
    fi

    local no_yq_root="${temp_root}/root-mihomo-no-yq"
    local no_yq_config_dir="${temp_root}/root-mihomo-config"
    mkdir -p "${no_yq_root}"
    cp "${SCRIPT_DIR}/scripts/mihomo.sh" "${no_yq_root}/mihomo.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${no_yq_root}/common.sh"
    mkdir -p "${no_yq_config_dir}"
    sed -i "s|^readonly MIHOMO_CONFIG_DIR=.*$|readonly MIHOMO_CONFIG_DIR=\"${no_yq_config_dir}\"|" "${no_yq_root}/mihomo.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        MIHOMO_SH="${no_yq_root}/mihomo.sh" \
        bash -c '
            set -euo pipefail
            source "$MIHOMO_SH"
            printf "proxies: []\nproxy-groups: []\n" > "${MIHOMO_CONFIG}"
            install_if_missing() { return 1; }
            check_command() {
                if [[ "$1" == "yq" ]]; then
                    return 1
                fi
                command -v "$1" >/dev/null 2>&1
            }
            backup_file() { BACKUP_CALLED=1; return 0; }
            if add_mihomo_node "safe-name" "127.0.0.1" "10810"; then
                exit 1
            fi
            [[ "${BACKUP_CALLED:-0}" == 0 ]]
            ! grep -q "safe-name" "${MIHOMO_CONFIG}"
        '; then
        record_pass "Root mihomo add_mihomo_node 在缺失 yq 时会 fail-fast"
    else
        record_fail "Root mihomo add_mihomo_node 在缺失 yq 时会 fail-fast"
    fi

    local geodata_root="${temp_root}/root-mihomo-geodata"
    local geodata_dir="${temp_root}/root-mihomo-geodata-dir"
    mkdir -p "${geodata_root}" "${geodata_dir}"
    cp "${SCRIPT_DIR}/scripts/mihomo.sh" "${geodata_root}/mihomo.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${geodata_root}/common.sh"
    sed -i "s|^readonly MIHOMO_GEODATA_DIR=.*$|readonly MIHOMO_GEODATA_DIR=\"${geodata_dir}\"|" "${geodata_root}/mihomo.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        MIHOMO_SH="${geodata_root}/mihomo.sh" \
        bash -c '
            set -euo pipefail
            source "$MIHOMO_SH"
            github_download() { return 1; }
            if _mihomo_download_geodata; then
                exit 1
            fi
            [[ ! -e "${MIHOMO_GEODATA_DIR}/geoip.dat" ]]
            [[ ! -e "${MIHOMO_GEODATA_DIR}/geosite.dat" ]]
            exit 0
        '; then
        record_pass "Root mihomo 在 geodata 首装下载失败时会 fail-fast"
    else
        record_fail "Root mihomo 在 geodata 首装下载失败时会 fail-fast"
    fi

    rm -rf "${temp_root}"
}

test_bridge_mihomo_contracts() {
    info "=== AI Gateway Bridge Mihomo 配置编辑输入边界契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local workdir="${temp_root}/bridge-mihomo"
    mkdir -p "${workdir}"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/mihomo.sh" "${workdir}/mihomo.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${workdir}/common.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        MIHOMO_SH="${workdir}/mihomo.sh" \
        bash -c '
            set -euo pipefail
            source "$MIHOMO_SH"
            if add_mihomo_node "bad\"name" "127.0.0.1" "10810"; then
                exit 1
            fi
            if add_mihomo_node "safe-name" "bad address" "10810"; then
                exit 1
            fi
            exit 0
        '; then
        record_pass "AI Gateway Bridge mihomo add_mihomo_node 会拒绝危险名称/地址"
    else
        record_fail "AI Gateway Bridge mihomo add_mihomo_node 会拒绝危险名称/地址"
    fi

    local no_yq_root="${temp_root}/bridge-mihomo-no-yq"
    local no_yq_config_dir="${temp_root}/bridge-mihomo-config"
    mkdir -p "${no_yq_root}"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/mihomo.sh" "${no_yq_root}/mihomo.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${no_yq_root}/common.sh"
    mkdir -p "${no_yq_config_dir}"
    sed -i "s|^readonly MIHOMO_CONFIG_DIR=.*$|readonly MIHOMO_CONFIG_DIR=\"${no_yq_config_dir}\"|" "${no_yq_root}/mihomo.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        MIHOMO_SH="${no_yq_root}/mihomo.sh" \
        bash -c '
            set -euo pipefail
            source "$MIHOMO_SH"
            printf "proxies: []\nproxy-groups: []\n" > "${MIHOMO_CONFIG}"
            install_if_missing() { return 1; }
            check_command() {
                if [[ "$1" == "yq" ]]; then
                    return 1
                fi
                command -v "$1" >/dev/null 2>&1
            }
            backup_file() { BACKUP_CALLED=1; return 0; }
            if add_mihomo_node "safe-name" "127.0.0.1" "10810"; then
                exit 1
            fi
            [[ "${BACKUP_CALLED:-0}" == 0 ]]
            ! grep -q "safe-name" "${MIHOMO_CONFIG}"
        '; then
        record_pass "AI Gateway Bridge mihomo add_mihomo_node 在缺失 yq 时会 fail-fast"
    else
        record_fail "AI Gateway Bridge mihomo add_mihomo_node 在缺失 yq 时会 fail-fast"
    fi

    local geodata_root="${temp_root}/bridge-mihomo-geodata"
    local geodata_dir="${temp_root}/bridge-mihomo-geodata-dir"
    mkdir -p "${geodata_root}" "${geodata_dir}"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/mihomo.sh" "${geodata_root}/mihomo.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${geodata_root}/common.sh"
    sed -i "s|^readonly MIHOMO_GEODATA_DIR=.*$|readonly MIHOMO_GEODATA_DIR=\"${geodata_dir}\"|" "${geodata_root}/mihomo.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        MIHOMO_SH="${geodata_root}/mihomo.sh" \
        bash -c '
            set -euo pipefail
            source "$MIHOMO_SH"
            github_download() { return 1; }
            if _mihomo_download_geodata; then
                exit 1
            fi
            [[ ! -e "${MIHOMO_GEODATA_DIR}/geoip.dat" ]]
            [[ ! -e "${MIHOMO_GEODATA_DIR}/geosite.dat" ]]
            exit 0
        '; then
        record_pass "AI Gateway Bridge mihomo 在 geodata 首装下载失败时会 fail-fast"
    else
        record_fail "AI Gateway Bridge mihomo 在 geodata 首装下载失败时会 fail-fast"
    fi

    rm -rf "${temp_root}"
}

test_xray_contracts() {
    info "=== Xray geodata 启动前依赖契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local workdir="${temp_root}/root-xray"
    mkdir -p "${workdir}" "${temp_root}/geodata"
    cp "${SCRIPT_DIR}/scripts/server-a.sh" "${workdir}/server-a.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${workdir}/common.sh"
    sed -i "s|^readonly XRAY_GEODATA_DIR=.*$|readonly XRAY_GEODATA_DIR=\"${temp_root}/geodata\"|" "${workdir}/server-a.sh"

    if SERVER_A_SH="${workdir}/server-a.sh" \
        bash -c '
            set -euo pipefail
            source "$SERVER_A_SH"
            github_download() { return 1; }
            if _ensure_xray_geodata; then
                exit 1
            fi
            [[ ! -e "${XRAY_GEODATA_DIR}/geoip.dat" ]]
            [[ ! -e "${XRAY_GEODATA_DIR}/geosite.dat" ]]
            exit 0
        '; then
        record_pass "Root server-a 在缺失 geodata 且下载失败时会 fail-fast"
    else
        record_fail "Root server-a 在缺失 geodata 且下载失败时会 fail-fast"
    fi

    rm -rf "${temp_root}"
}

test_bridge_xray_contracts() {
    info "=== AI Gateway Bridge Xray geodata 启动前依赖契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local workdir="${temp_root}/bridge-xray"
    mkdir -p "${workdir}" "${temp_root}/geodata"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/server-a.sh" "${workdir}/server-a.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${workdir}/common.sh"
    sed -i "s|^readonly XRAY_GEODATA_DIR=.*$|readonly XRAY_GEODATA_DIR=\"${temp_root}/geodata\"|" "${workdir}/server-a.sh"

    if SERVER_A_SH="${workdir}/server-a.sh" \
        bash -c '
            set -euo pipefail
            source "$SERVER_A_SH"
            github_download() { return 1; }
            if _ensure_xray_geodata; then
                exit 1
            fi
            [[ ! -e "${XRAY_GEODATA_DIR}/geoip.dat" ]]
            [[ ! -e "${XRAY_GEODATA_DIR}/geosite.dat" ]]
            exit 0
        '; then
        record_pass "AI Gateway Bridge server-a 在缺失 geodata 且下载失败时会 fail-fast"
    else
        record_fail "AI Gateway Bridge server-a 在缺失 geodata 且下载失败时会 fail-fast"
    fi

    rm -rf "${temp_root}"
}

test_server_b_panel_contracts() {
    info "=== Server B 3x-ui 配置失败可观测性契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local fakebin="${temp_root}/bin"
    local workdir="${temp_root}/root-server-b"
    mkdir -p "${fakebin}" "${workdir}"
    cp "${SCRIPT_DIR}/scripts/server-b.sh" "${workdir}/server-b.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${workdir}/common.sh"
    sed -i "s|local xui_db=\"/etc/x-ui/x-ui.db\"|local xui_db=\"${temp_root}/x-ui.db\"|" "${workdir}/server-b.sh"
    : > "${temp_root}/x-ui.db"

    cat > "${fakebin}/x-ui" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${fakebin}/x-ui"

    cat > "${fakebin}/sqlite3" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${fakebin}/sqlite3"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        PATH="${fakebin}:${PATH}" \
        SERVER_B_SH="${workdir}/server-b.sh" \
        TMP_ROOT="${temp_root}" \
        bash -c '
            set -euo pipefail
            source "$SERVER_B_SH"
            if _configure_3xui_panel "23456" "admin" "secret"; then
                exit 1
            fi
            exit 0
        '; then
        record_pass "Root server-b 在 3x-ui CLI/sqlite fallback 同时失败时会显式报错"
    else
        record_fail "Root server-b 在 3x-ui CLI/sqlite fallback 同时失败时会显式报错"
    fi

    if grep -q 'THREE_X_UI_DIRECT_PORT_OPEN' "${SCRIPT_DIR}/scripts/server-b.sh" && \
       grep -q '3x-ui direct panel port is not opened in ${exposure_profile} profile' "${SCRIPT_DIR}/scripts/server-b.sh" && \
       grep -q '3x-ui panel (lab profile only)' "${SCRIPT_DIR}/scripts/server-b.sh" && \
       grep -q '3x-ui requires VPN/private access in vpn-first profile' "${SCRIPT_DIR}/scripts/server-b.sh"; then
        record_pass "Root server-b 3x-ui 默认不再直接开放公网面板端口，lab 例外有显式标记"
    else
        record_fail "Root server-b 3x-ui 默认不再直接开放公网面板端口，lab 例外有显式标记"
    fi

    cat > "${fakebin}/ufw" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${fakebin}/ufw"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        PATH="${fakebin}:${PATH}" \
        SERVER_B_SH="${workdir}/server-b.sh" \
        bash -c '
            set -euo pipefail
            source "$SERVER_B_SH"
            if _open_firewall_port "23456" "tcp" "test panel"; then
                exit 1
            fi
            exit 0
        '; then
        record_pass "Root server-b 防火墙命令失败时不会吞错并继续宣称端口已开放"
    else
        record_fail "Root server-b 防火墙命令失败时不会吞错并继续宣称端口已开放"
    fi

    rm -rf "${temp_root}"
}

test_bridge_server_b_panel_contracts() {
    info "=== AI Gateway Bridge Server B 3x-ui 配置失败可观测性契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local fakebin="${temp_root}/bin"
    local workdir="${temp_root}/bridge-server-b"
    mkdir -p "${fakebin}" "${workdir}"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/server-b.sh" "${workdir}/server-b.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${workdir}/common.sh"
    sed -i "s|local xui_db=\"/etc/x-ui/x-ui.db\"|local xui_db=\"${temp_root}/x-ui.db\"|" "${workdir}/server-b.sh"
    : > "${temp_root}/x-ui.db"

    cat > "${fakebin}/x-ui" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${fakebin}/x-ui"

    cat > "${fakebin}/sqlite3" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${fakebin}/sqlite3"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        PATH="${fakebin}:${PATH}" \
        SERVER_B_SH="${workdir}/server-b.sh" \
        TMP_ROOT="${temp_root}" \
        bash -c '
            set -euo pipefail
            source "$SERVER_B_SH"
            if _configure_3xui_panel "23456" "admin" "secret"; then
                exit 1
            fi
            exit 0
        '; then
        record_pass "AI Gateway Bridge server-b 在 3x-ui CLI/sqlite fallback 同时失败时会显式报错"
    else
        record_fail "AI Gateway Bridge server-b 在 3x-ui CLI/sqlite fallback 同时失败时会显式报错"
    fi

    if grep -q 'THREE_X_UI_DIRECT_PORT_OPEN' "${SCRIPT_DIR}/ai-gateway-bridge/scripts/server-b.sh" && \
       grep -q '3x-ui direct panel port is not opened in ${exposure_profile} profile' "${SCRIPT_DIR}/ai-gateway-bridge/scripts/server-b.sh" && \
       grep -q '3x-ui panel (lab profile only)' "${SCRIPT_DIR}/ai-gateway-bridge/scripts/server-b.sh" && \
       grep -q '3x-ui requires VPN/private access in vpn-first profile' "${SCRIPT_DIR}/ai-gateway-bridge/scripts/server-b.sh"; then
        record_pass "AI Gateway Bridge server-b 3x-ui 默认不再直接开放公网面板端口，lab 例外有显式标记"
    else
        record_fail "AI Gateway Bridge server-b 3x-ui 默认不再直接开放公网面板端口，lab 例外有显式标记"
    fi

    cat > "${fakebin}/ufw" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${fakebin}/ufw"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        PATH="${fakebin}:${PATH}" \
        SERVER_B_SH="${workdir}/server-b.sh" \
        bash -c '
            set -euo pipefail
            source "$SERVER_B_SH"
            if _open_firewall_port "23456" "tcp" "test panel"; then
                exit 1
            fi
            exit 0
        '; then
        record_pass "AI Gateway Bridge server-b 防火墙命令失败时不会吞错并继续宣称端口已开放"
    else
        record_fail "AI Gateway Bridge server-b 防火墙命令失败时不会吞错并继续宣称端口已开放"
    fi

    rm -rf "${temp_root}"
}

_check_server_a_caddy_generation() {
    local label="$1"
    local source_dir="$2"
    local temp_root fakebin workdir
    temp_root="$(mktemp -d)"
    fakebin="${temp_root}/bin"
    workdir="${temp_root}/server-a"
    mkdir -p "${fakebin}" "${workdir}" "${temp_root}/caddy" "${temp_root}/www" "${temp_root}/logs/caddy" \
        "${temp_root}/acme" "${temp_root}/letsencrypt/live" "${temp_root}/renewal-hooks" "${temp_root}/systemd"
    cp "${SCRIPT_DIR}/${source_dir}/server-a.sh" "${workdir}/server-a.sh"
    cp "${SCRIPT_DIR}/${source_dir}/common.sh" "${workdir}/common.sh"
    sed -i "s|^readonly CADDY_CONFIG=.*$|readonly CADDY_CONFIG=\"${temp_root}/caddy/Caddyfile\"|" "${workdir}/server-a.sh"
    sed -i "s|^readonly DECOY_WEBROOT=.*$|readonly DECOY_WEBROOT=\"${temp_root}/www\"|" "${workdir}/server-a.sh"
    sed -i "s|^readonly CADDY_LOG_DIR=.*$|readonly CADDY_LOG_DIR=\"${temp_root}/logs/caddy\"|" "${workdir}/server-a.sh"
    sed -i "s|/root/server-a-domain.conf|${temp_root}/server-a-domain.conf|g" "${workdir}/server-a.sh"

    cat > "${fakebin}/caddy" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    validate) exit 0 ;;
    version) echo "2.8.0"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "${fakebin}/caddy"

    cat > "${fakebin}/certbot" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
    echo "certbot 5.4.0"
    exit 0
fi
printf '%s\n' "$*" >> "${BIFROST_FAKE_CERTBOT_LOG}"
if [[ "${1:-}" == "certonly" ]]; then
    ip=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ip-address|--cert-name)
                ip="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    mkdir -p "${BIFROST_LETSENCRYPT_LIVE_DIR}/${ip}"
    printf 'fake cert\n' > "${BIFROST_LETSENCRYPT_LIVE_DIR}/${ip}/fullchain.pem"
    printf 'fake key\n' > "${BIFROST_LETSENCRYPT_LIVE_DIR}/${ip}/privkey.pem"
    exit 0
fi
if [[ "${1:-}" == "renew" ]]; then
    exit 0
fi
exit 0
EOF
    chmod +x "${fakebin}/certbot"

    cat > "${fakebin}/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${fakebin}/systemctl"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        PATH="${fakebin}:${PATH}" \
        TEMP_ROOT="${temp_root}" \
        BIFROST_ACME_WEBROOT="${temp_root}/acme" \
        BIFROST_LETSENCRYPT_LIVE_DIR="${temp_root}/letsencrypt/live" \
        BIFROST_LETSENCRYPT_RENEWAL_HOOK_DIR="${temp_root}/renewal-hooks" \
        BIFROST_SYSTEMD_SYSTEM_DIR="${temp_root}/systemd" \
        BIFROST_FAKE_CERTBOT_LOG="${temp_root}/certbot.log" \
        SERVER_A_SH="${workdir}/server-a.sh" \
        bash -c '
            set -euo pipefail
            source "$SERVER_A_SH"
            _install_caddy() { return 0; }
            journalctl() { return 0; }

            BIFROST_EXPOSURE_PROFILE=vpn-first \
            BIFROST_ADMIN_ALLOWED_RANGES="127.0.0.1" \
            setup_caddy_a <<< "audit.example.com" >/dev/null

            grep -q "# Exposure profile: vpn-first" "$CADDY_CONFIG"
            grep -q "@newapi_private" "$CADDY_CONFIG"
            grep -q "@manage_private_root" "$CADDY_CONFIG"
            grep -q "remote_ip 127.0.0.1" "$CADDY_CONFIG"
            grep -Fq "path /api/* /static/* /logo.png /dashboard" "$CADDY_CONFIG"
            grep -q "handle /api/status" "$CADDY_CONFIG"
            grep -Fq "handle /static/*" "$CADDY_CONFIG"
            grep -Fq "handle /logo.png" "$CADDY_CONFIG"
            grep -q "Bifrost management requires VPN/private access in vpn-first profile" "$CADDY_CONFIG"
            grep -q "New API static assets require VPN/private access in vpn-first profile" "$CADDY_CONFIG"
            grep -q "New API dashboard requires VPN/private access in vpn-first profile" "$CADDY_CONFIG"

            BIFROST_EXPOSURE_PROFILE=public-managed \
            BIFROST_ADMIN_ALLOWED_RANGES="127.0.0.1" \
            setup_caddy_a <<< "audit.example.net" >/dev/null

            grep -q "# Exposure profile: public-managed" "$CADDY_CONFIG"
            grep -q "handle /manage {" "$CADDY_CONFIG"
            grep -q "redir /manage/ 308" "$CADDY_CONFIG"
            grep -Fq "handle /static/*" "$CADDY_CONFIG"
            grep -Fq "handle /logo.png" "$CADDY_CONFIG"
            grep -q "handle /dashboard" "$CADDY_CONFIG"
            ! grep -q "Bifrost management requires VPN/private access in vpn-first profile" "$CADDY_CONFIG"

            BIFROST_SERVER_A_TLS_MODE=ip \
            BIFROST_SERVER_A_PUBLIC_IP="203.0.113.10" \
            BIFROST_ACME_EMAIL="ops@example.com" \
            BIFROST_ACME_WEBROOT="${TEMP_ROOT}/acme" \
            BIFROST_LETSENCRYPT_LIVE_DIR="${TEMP_ROOT}/letsencrypt/live" \
            BIFROST_LETSENCRYPT_RENEWAL_HOOK_DIR="${TEMP_ROOT}/renewal-hooks" \
            BIFROST_SYSTEMD_SYSTEM_DIR="${TEMP_ROOT}/systemd" \
            BIFROST_FAKE_CERTBOT_LOG="${TEMP_ROOT}/certbot.log" \
            setup_caddy_a >/dev/null

            grep -q "# TLS mode: ip" "$CADDY_CONFIG"
            grep -q "https://203.0.113.10 {" "$CADDY_CONFIG"
            grep -Fq "tls ${TEMP_ROOT}/letsencrypt/live/203.0.113.10/fullchain.pem ${TEMP_ROOT}/letsencrypt/live/203.0.113.10/privkey.pem" "$CADDY_CONFIG"
            grep -q "http://203.0.113.10 {" "$CADDY_CONFIG"
            grep -Fq "root * ${TEMP_ROOT}/acme" "$CADDY_CONFIG"
            grep -q "ENDPOINT_MODE=ip" "${TEMP_ROOT}/server-a-domain.conf"
            grep -q "SERVER_A_BASE_URL=https://203.0.113.10" "${TEMP_ROOT}/server-a-domain.conf"
            grep -q -- "--preferred-profile shortlived" "${TEMP_ROOT}/certbot.log"
            grep -q -- "--ip-address 203.0.113.10" "${TEMP_ROOT}/certbot.log"
            grep -q "cert-name 203.0.113.10" "${TEMP_ROOT}/systemd/bifrost-certbot-renew.service"

            printf "fake origin cert\n" > "${TEMP_ROOT}/cloudflare-origin.pem"
            printf "fake origin key\n" > "${TEMP_ROOT}/cloudflare-origin.key"
            BIFROST_SERVER_A_TLS_MODE=cloudflare-origin \
            BIFROST_SERVER_A_DOMAIN="cf.example.com" \
            BIFROST_CLOUDFLARE_ORIGIN_CERT="${TEMP_ROOT}/cloudflare-origin.pem" \
            BIFROST_CLOUDFLARE_ORIGIN_KEY="${TEMP_ROOT}/cloudflare-origin.key" \
            setup_caddy_a >/dev/null

            grep -q "# TLS mode: cloudflare-origin" "$CADDY_CONFIG"
            grep -q "cf.example.com {" "$CADDY_CONFIG"
            grep -Fq "tls ${TEMP_ROOT}/cloudflare-origin.pem ${TEMP_ROOT}/cloudflare-origin.key" "$CADDY_CONFIG"
            grep -q "ENDPOINT_MODE=cloudflare-origin" "${TEMP_ROOT}/server-a-domain.conf"
            grep -q "SERVER_A_BASE_URL=https://cf.example.com" "${TEMP_ROOT}/server-a-domain.conf"
            exit 0
        '; then
        record_pass "${label} Server A Caddyfile 生成按 vpn-first/public-managed/IP HTTPS/Cloudflare Origin 区分管理面暴露"
    else
        record_fail "${label} Server A Caddyfile 生成按 vpn-first/public-managed/IP HTTPS/Cloudflare Origin 区分管理面暴露"
    fi

    rm -rf "${temp_root}"
}

_check_server_b_caddy_generation() {
    local label="$1"
    local source_dir="$2"
    local temp_root fakebin workdir
    temp_root="$(mktemp -d)"
    fakebin="${temp_root}/bin"
    workdir="${temp_root}/server-b"
    mkdir -p "${fakebin}" "${workdir}" "${temp_root}/state" "${temp_root}/systemd" "${temp_root}/logs/caddy"
    cp "${SCRIPT_DIR}/${source_dir}/server-b.sh" "${workdir}/server-b.sh"
    cp "${SCRIPT_DIR}/${source_dir}/common.sh" "${workdir}/common.sh"
    sed -i "s|^readonly CADDY_CONFIG_DIR=.*$|readonly CADDY_CONFIG_DIR=\"${temp_root}/caddy\"|" "${workdir}/server-b.sh"
    sed -i "s|^readonly CADDY_DATA_DIR=.*$|readonly CADDY_DATA_DIR=\"${temp_root}/caddy-data\"|" "${workdir}/server-b.sh"
    sed -i "s|^readonly CADDY_WEB_ROOT=.*$|readonly CADDY_WEB_ROOT=\"${temp_root}/www\"|" "${workdir}/server-b.sh"
    sed -i "s|^readonly DEPLOY_STATE_DIR=.*$|readonly DEPLOY_STATE_DIR=\"${temp_root}/state\"|" "${workdir}/server-b.sh"
    sed -i "s|/etc/systemd/system/caddy.service|${temp_root}/systemd/caddy.service|g" "${workdir}/server-b.sh"
    sed -i "s|/var/log/caddy|${temp_root}/logs/caddy|g" "${workdir}/server-b.sh"
    printf 'THREE_X_UI_PORT=23456\n' > "${temp_root}/state/state.env"

    cat > "${fakebin}/caddy" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    validate) exit 0 ;;
    version) echo "2.8.0"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "${fakebin}/caddy"

    cat > "${fakebin}/systemctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${fakebin}/systemctl"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        PATH="${fakebin}:${PATH}" \
        SERVER_B_SH="${workdir}/server-b.sh" \
        TMP_ROOT="${temp_root}" \
        bash -c '
            set -euo pipefail
            source "$SERVER_B_SH"
            _install_caddy() { return 0; }
            _deploy_decoy_website() { mkdir -p "$CADDY_WEB_ROOT"; : > "${CADDY_WEB_ROOT}/index.html"; }
            _wait_for_service() { return 0; }
            _open_firewall_port() { return 0; }
            _get_public_ip() { echo "203.0.113.20"; }
            journalctl() { return 0; }

            BIFROST_EXPOSURE_PROFILE=vpn-first \
            BIFROST_ADMIN_ALLOWED_RANGES="127.0.0.1" \
            setup_caddy_b <<< "panel.example.com" >/dev/null

            cfg="${CADDY_CONFIG_DIR}/Caddyfile"
            grep -q "# Exposure profile: vpn-first" "$cfg"
            grep -q "@xui_private_root" "$cfg"
            grep -q "@xui_private" "$cfg"
            grep -q "remote_ip 127.0.0.1" "$cfg"
            grep -q "3x-ui requires VPN/private access in vpn-first profile" "$cfg"
            ! grep -q "handle_path /xui-panel/\\*" "$cfg"

            BIFROST_EXPOSURE_PROFILE=public-managed \
            BIFROST_ADMIN_ALLOWED_RANGES="127.0.0.1" \
            setup_caddy_b <<< "panel.example.net" >/dev/null

            grep -q "# Exposure profile: public-managed" "$cfg"
            grep -q "handle /xui-panel {" "$cfg"
            grep -q "redir /xui-panel/ 308" "$cfg"
            grep -q "handle_path /xui-panel/\\*" "$cfg"
            ! grep -q "3x-ui requires VPN/private access in vpn-first profile" "$cfg"

            _wait_for_service() { return 1; }
            fail_output="${TMP_ROOT}/server-b-caddy-start-failure.log"
            if BIFROST_EXPOSURE_PROFILE=vpn-first setup_caddy_b <<< "broken.example.org" >"${fail_output}" 2>&1; then
                exit 1
            fi
            grep -q "Caddy service failed to start. Check logs:" "${fail_output}"
            ! grep -q "CADDY (SERVER B) DEPLOYMENT COMPLETE" "${fail_output}"
            ! grep -q "broken.example.org" "${DEPLOY_STATE_DIR}/state.env"
            exit 0
        '; then
        record_pass "${label} Server B Caddyfile 生成按 vpn-first/public-managed 区分 3x-ui 暴露"
    else
        record_fail "${label} Server B Caddyfile 生成按 vpn-first/public-managed 区分 3x-ui 暴露"
    fi

    rm -rf "${temp_root}"
}

test_caddy_exposure_generation_contracts() {
    info "=== Caddy 暴露面 profile 生成契约 ==="
    _check_server_a_caddy_generation "Root" "scripts"
    _check_server_a_caddy_generation "AI Gateway Bridge" "ai-gateway-bridge/scripts"
    _check_server_b_caddy_generation "Root" "scripts"
    _check_server_b_caddy_generation "AI Gateway Bridge" "ai-gateway-bridge/scripts"
}

test_server_a_deploy_contracts() {
    info "=== Server A 主部署状态一致性契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local precheck_workdir="${temp_root}/root-server-a-precheck"
    mkdir -p "${precheck_workdir}"
    cp "${SCRIPT_DIR}/scripts/server-a.sh" "${precheck_workdir}/server-a.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${precheck_workdir}/common.sh"

    cat > "${precheck_workdir}/dd-reinstall.sh" <<'EOF'
pre_deploy_check() {
    return 1
}
EOF

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SERVER_A_SH="${precheck_workdir}/server-a.sh" \
        TMP_ROOT="${temp_root}" \
        bash -c '
            set -euo pipefail
            source "$SERVER_A_SH"

            output="${TMP_ROOT}/server-a-precheck-output.log"
            if DEPLOY_DOMAIN="audit.example.com" deploy_server_a >"${output}" 2>&1; then
                exit 1
            fi

            grep -q "Pre-deploy check failed. Cannot continue with Server A deployment." "${output}"
            ! grep -q "\[Step 1/14\] Detecting system environment" "${output}"
            ! grep -q "Server A Deployment Complete!" "${output}"
            exit 0
        '; then
        record_pass "Root server-a 在预部署云环境审查失败时会立即终止且不进入后续部署"
    else
        record_fail "Root server-a 在预部署云环境审查失败时会立即终止且不进入后续部署"
    fi

    local workdir="${temp_root}/root-server-a"
    mkdir -p "${workdir}"
    cp "${SCRIPT_DIR}/scripts/server-a.sh" "${workdir}/server-a.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${workdir}/common.sh"

    cat > "${workdir}/mihomo.sh" <<'EOF'
deploy_mihomo() { return 0; }
EOF

    cat > "${workdir}/keepalive.sh" <<'EOF'
deploy_keepalive() { return 0; }
EOF

    cat > "${workdir}/split-tunnel.sh" <<'EOF'
deploy_split_tunnel() { return 0; }
EOF

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SERVER_A_SH="${workdir}/server-a.sh" \
        TMP_ROOT="${temp_root}" \
        bash -c '
            set -euo pipefail
            source "$SERVER_A_SH"
            detect_system() { return 0; }
            _install_base_dependencies() { return 0; }
            setup_firewall() { return 0; }
            harden_ssh() { return 0; }
            setup_fail2ban() { return 0; }
            harden_kernel() { return 0; }
            collect_server_b_info() { SERVER_B_IP="203.0.113.10"; SERVER_B_PORT="8443"; return 0; }
            install_xray_client() { return 0; }
            install_new_api() { return 0; }
            setup_decoy_website() { return 0; }
            setup_caddy_a() { return 0; }
            confirm_action() { return 1; }
            setup_logrotate() { return 0; }
            deploy_monitoring() { return 0; }
            test_connectivity() { return 1; }
            systemctl() {
                if [[ "${1:-}" == "is-active" ]]; then
                    echo "inactive"
                    return 0
                fi
                return 0
            }

            output="${TMP_ROOT}/server-a-output.log"
            if DEPLOY_DOMAIN="audit.example.com" deploy_server_a >"${output}" 2>&1; then
                exit 1
            fi

            grep -q "Connectivity Tests" "${output}"
            grep -q "Server A Deployment Incomplete" "${output}"
            grep -q "Exposure Profile  : vpn-first" "${output}"
            grep -q "Skipping local New API install; Server A is running distribution gateway mode" "${output}"
            grep -q "Admin Credential  : Created by you during first-run setup" "${output}"
            ! grep -q "New API Admin Pass : 123456" "${output}"
            ! grep -q "Server A Deployment Complete!" "${output}"
            exit 0
        '; then
        record_pass "Root server-a 在连通性失败时返回失败且不打印完成摘要"
    else
        record_fail "Root server-a 在连通性失败时返回失败且不打印完成摘要"
    fi

    local vpn_workdir="${temp_root}/root-server-a-vpn"
    mkdir -p "${vpn_workdir}"
    cp "${SCRIPT_DIR}/scripts/server-a.sh" "${vpn_workdir}/server-a.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${vpn_workdir}/common.sh"

    cat > "${vpn_workdir}/mihomo.sh" <<'EOF'
deploy_mihomo() { return 0; }
EOF

    cat > "${vpn_workdir}/keepalive.sh" <<'EOF'
deploy_keepalive() { return 0; }
EOF

    cat > "${vpn_workdir}/split-tunnel.sh" <<'EOF'
deploy_split_tunnel() { return 0; }
EOF

    cat > "${vpn_workdir}/vpn.sh" <<'EOF'
deploy_vpn() { return 1; }
EOF

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SERVER_A_SH="${vpn_workdir}/server-a.sh" \
        TMP_ROOT="${temp_root}" \
        bash -c '
            set -euo pipefail
            source "$SERVER_A_SH"
            detect_system() { return 0; }
            _install_base_dependencies() { return 0; }
            setup_firewall() { return 0; }
            harden_ssh() { return 0; }
            setup_fail2ban() { return 0; }
            harden_kernel() { return 0; }
            collect_server_b_info() { SERVER_B_IP="203.0.113.10"; SERVER_B_PORT="8443"; return 0; }
            install_xray_client() { return 0; }
            install_new_api() { return 0; }
            setup_decoy_website() { return 0; }
            setup_caddy_a() { return 0; }
            confirm_action() {
                if [[ "$1" == "Deploy enterprise VPN (WireGuard/Firezone)?"* ]]; then
                    return 0
                fi
                return 1
            }
            setup_logrotate() { return 0; }
            deploy_monitoring() { return 0; }
            test_connectivity() { return 0; }
            systemctl() {
                if [[ "${1:-}" == "is-active" ]]; then
                    echo "inactive"
                    return 0
                fi
                return 0
            }

            output="${TMP_ROOT}/server-a-vpn-output.log"
            if DEPLOY_DOMAIN="audit.example.com" deploy_server_a >"${output}" 2>&1; then
                exit 1
            fi

            grep -q "VPN" "${output}"
            grep -q "Server A Deployment Incomplete" "${output}"
            grep -q "Exposure Profile  : vpn-first" "${output}"
            ! grep -q "root/123456" "${output}"
            ! grep -q "Server A Deployment Complete!" "${output}"
            exit 0
        '; then
        record_pass "Root server-a 在用户选择 VPN 且部署失败时返回失败且不打印完成摘要"
    else
        record_fail "Root server-a 在用户选择 VPN 且部署失败时返回失败且不打印完成摘要"
    fi

    rm -rf "${temp_root}"
}

test_bridge_server_a_deploy_contracts() {
    info "=== AI Gateway Bridge Server A 主部署状态一致性契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local precheck_workdir="${temp_root}/bridge-server-a-precheck"
    mkdir -p "${precheck_workdir}"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/server-a.sh" "${precheck_workdir}/server-a.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${precheck_workdir}/common.sh"

    cat > "${precheck_workdir}/dd-reinstall.sh" <<'EOF'
pre_deploy_check() {
    return 1
}
EOF

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SERVER_A_SH="${precheck_workdir}/server-a.sh" \
        TMP_ROOT="${temp_root}" \
        bash -c '
            set -euo pipefail
            source "$SERVER_A_SH"

            output="${TMP_ROOT}/bridge-server-a-precheck-output.log"
            if DEPLOY_DOMAIN="audit.example.com" deploy_server_a >"${output}" 2>&1; then
                exit 1
            fi

            grep -q "Pre-deploy check failed. Cannot continue with Server A deployment." "${output}"
            ! grep -q "\[Step 1/14\] Detecting system environment" "${output}"
            ! grep -q "Server A Deployment Complete!" "${output}"
            exit 0
        '; then
        record_pass "AI Gateway Bridge server-a 在预部署云环境审查失败时会立即终止且不进入后续部署"
    else
        record_fail "AI Gateway Bridge server-a 在预部署云环境审查失败时会立即终止且不进入后续部署"
    fi

    local workdir="${temp_root}/bridge-server-a"
    mkdir -p "${workdir}"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/server-a.sh" "${workdir}/server-a.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${workdir}/common.sh"

    cat > "${workdir}/mihomo.sh" <<'EOF'
deploy_mihomo() { return 0; }
EOF

    cat > "${workdir}/keepalive.sh" <<'EOF'
deploy_keepalive() { return 0; }
EOF

    cat > "${workdir}/split-tunnel.sh" <<'EOF'
deploy_split_tunnel() { return 0; }
EOF

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SERVER_A_SH="${workdir}/server-a.sh" \
        TMP_ROOT="${temp_root}" \
        bash -c '
            set -euo pipefail
            source "$SERVER_A_SH"
            detect_system() { return 0; }
            _install_base_dependencies() { return 0; }
            setup_firewall() { return 0; }
            harden_ssh() { return 0; }
            setup_fail2ban() { return 0; }
            harden_kernel() { return 0; }
            collect_server_b_info() { SERVER_B_IP="203.0.113.10"; SERVER_B_PORT="8443"; return 0; }
            install_xray_client() { return 0; }
            install_new_api() { return 0; }
            setup_decoy_website() { return 0; }
            setup_caddy_a() { return 0; }
            confirm_action() { return 1; }
            setup_logrotate() { return 0; }
            deploy_monitoring() { return 0; }
            test_connectivity() { return 1; }
            systemctl() {
                if [[ "${1:-}" == "is-active" ]]; then
                    echo "inactive"
                    return 0
                fi
                return 0
            }

            output="${TMP_ROOT}/bridge-server-a-output.log"
            if DEPLOY_DOMAIN="audit.example.com" deploy_server_a >"${output}" 2>&1; then
                exit 1
            fi

            grep -q "Connectivity Tests" "${output}"
            grep -q "Server A Deployment Incomplete" "${output}"
            grep -q "Exposure Profile  : vpn-first" "${output}"
            grep -q "New API Initialization" "${output}"
            grep -q "Admin Credential  : Created by you during first-run setup" "${output}"
            ! grep -q "New API Admin Pass : 123456" "${output}"
            ! grep -q "Server A Deployment Complete!" "${output}"
            exit 0
        '; then
        record_pass "AI Gateway Bridge server-a 在连通性失败时返回失败且不打印完成摘要"
    else
        record_fail "AI Gateway Bridge server-a 在连通性失败时返回失败且不打印完成摘要"
    fi

    local vpn_workdir="${temp_root}/bridge-server-a-vpn"
    mkdir -p "${vpn_workdir}"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/server-a.sh" "${vpn_workdir}/server-a.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${vpn_workdir}/common.sh"

    cat > "${vpn_workdir}/mihomo.sh" <<'EOF'
deploy_mihomo() { return 0; }
EOF

    cat > "${vpn_workdir}/keepalive.sh" <<'EOF'
deploy_keepalive() { return 0; }
EOF

    cat > "${vpn_workdir}/split-tunnel.sh" <<'EOF'
deploy_split_tunnel() { return 0; }
EOF

    cat > "${vpn_workdir}/vpn.sh" <<'EOF'
deploy_vpn() { return 1; }
EOF

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SERVER_A_SH="${vpn_workdir}/server-a.sh" \
        TMP_ROOT="${temp_root}" \
        bash -c '
            set -euo pipefail
            source "$SERVER_A_SH"
            detect_system() { return 0; }
            _install_base_dependencies() { return 0; }
            setup_firewall() { return 0; }
            harden_ssh() { return 0; }
            setup_fail2ban() { return 0; }
            harden_kernel() { return 0; }
            collect_server_b_info() { SERVER_B_IP="203.0.113.10"; SERVER_B_PORT="8443"; return 0; }
            install_xray_client() { return 0; }
            install_new_api() { return 0; }
            setup_decoy_website() { return 0; }
            setup_caddy_a() { return 0; }
            confirm_action() {
                if [[ "$1" == "Deploy enterprise VPN (WireGuard/Firezone)?"* ]]; then
                    return 0
                fi
                return 1
            }
            setup_logrotate() { return 0; }
            deploy_monitoring() { return 0; }
            test_connectivity() { return 0; }
            systemctl() {
                if [[ "${1:-}" == "is-active" ]]; then
                    echo "inactive"
                    return 0
                fi
                return 0
            }

            output="${TMP_ROOT}/bridge-server-a-vpn-output.log"
            if DEPLOY_DOMAIN="audit.example.com" deploy_server_a >"${output}" 2>&1; then
                exit 1
            fi

            grep -q "VPN" "${output}"
            grep -q "Server A Deployment Incomplete" "${output}"
            grep -q "Exposure Profile  : vpn-first" "${output}"
            ! grep -q "root/123456" "${output}"
            ! grep -q "Server A Deployment Complete!" "${output}"
            exit 0
        '; then
        record_pass "AI Gateway Bridge server-a 在用户选择 VPN 且部署失败时返回失败且不打印完成摘要"
    else
        record_fail "AI Gateway Bridge server-a 在用户选择 VPN 且部署失败时返回失败且不打印完成摘要"
    fi

    rm -rf "${temp_root}"
}

test_server_b_deploy_contracts() {
    info "=== Server B 主部署状态一致性契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local workdir="${temp_root}/root-server-b-deploy"
    mkdir -p "${workdir}"
    cp "${SCRIPT_DIR}/scripts/server-b.sh" "${workdir}/server-b.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${workdir}/common.sh"
    sed -i "s|^readonly XRAY_LOG_DIR=.*$|readonly XRAY_LOG_DIR=\"${temp_root}/logs/xray\"|" "${workdir}/server-b.sh"
    sed -i "s|^readonly XRAY_CONFIG_DIR=.*$|readonly XRAY_CONFIG_DIR=\"${temp_root}/xray\"|" "${workdir}/server-b.sh"
    sed -i "s|^readonly HYSTERIA_CONFIG_DIR=.*$|readonly HYSTERIA_CONFIG_DIR=\"${temp_root}/hysteria\"|" "${workdir}/server-b.sh"
    sed -i "s|^readonly CADDY_CONFIG_DIR=.*$|readonly CADDY_CONFIG_DIR=\"${temp_root}/caddy\"|" "${workdir}/server-b.sh"
    sed -i "s|^readonly CONNECTION_INFO_FILE=.*$|readonly CONNECTION_INFO_FILE=\"${temp_root}/connection.txt\"|" "${workdir}/server-b.sh"
    sed -i "s|^readonly DEPLOY_STATE_DIR=.*$|readonly DEPLOY_STATE_DIR=\"${temp_root}/state\"|" "${workdir}/server-b.sh"

    cat > "${workdir}/anti-dpi.sh" <<'EOF'
deploy_anti_dpi() { return 0; }
EOF

    cat > "${workdir}/keepalive.sh" <<'EOF'
deploy_keepalive() { return 0; }
EOF

    cat > "${workdir}/dd-reinstall.sh" <<'EOF'
pre_deploy_check() { return 1; }
EOF

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SERVER_B_SH="${workdir}/server-b.sh" \
        TMP_ROOT="${temp_root}" \
        bash -c '
            set -euo pipefail
            source "$SERVER_B_SH"
            confirm_action() {
                if [[ "$1" == "Proceed with Server B deployment?"* ]]; then
                    return 0
                fi
                return 1
            }

            output="${TMP_ROOT}/server-b-predeploy-output.log"
            if deploy_server_b >"${output}" 2>&1; then
                exit 1
            fi

            grep -q "Pre-deploy check failed. Cannot continue with Server B deployment." "${output}"
            ! grep -q "\\[Step 1/14\\]" "${output}"
            ! grep -q "DEPLOYMENT COMPLETE" "${output}"
            ! grep -q "DEPLOYMENT INCOMPLETE" "${output}"
            exit 0
        '; then
        record_pass "Root server-b 在预部署云环境审查失败时会立即终止且不进入后续部署"
    else
        record_fail "Root server-b 在预部署云环境审查失败时会立即终止且不进入后续部署"
    fi

    cat > "${workdir}/dd-reinstall.sh" <<'EOF'
pre_deploy_check() { return 0; }
EOF

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SERVER_B_SH="${workdir}/server-b.sh" \
        TMP_ROOT="${temp_root}" \
        bash -c '
            set -euo pipefail
            source "$SERVER_B_SH"
            detect_system() { return 0; }
            _install_base_dependencies() { return 0; }
            full_security_hardening() { return 0; }
            harden_ssh() { return 0; }
            setup_firewall() { return 1; }
            harden_kernel() { return 0; }
            setup_fail2ban() { return 0; }
            setup_auto_updates() { return 0; }
            install_xray_server() { mkdir -p "$(dirname "$XRAY_CONFIG_FILE")"; : > "$XRAY_CONFIG_FILE"; return 0; }
            setup_whitelist_routing() { return 0; }
            install_3xui() { return 0; }
            install_hysteria2_server() { return 0; }
            setup_caddy_b() { mkdir -p "$CADDY_CONFIG_DIR"; : > "${CADDY_CONFIG_DIR}/Caddyfile"; return 0; }
            enable_bbr() { return 0; }
            deploy_monitoring() { return 0; }
            test_connectivity_b() { return 0; }
            _get_public_ip() { echo "203.0.113.20"; }
            confirm_action() {
                if [[ "$1" == "Proceed with Server B deployment?"* ]]; then
                    return 0
                fi
                return 1
            }
            systemctl() {
                if [[ "${1:-}" == "is-active" ]]; then
                    return 1
                fi
                return 0
            }

            output="${TMP_ROOT}/server-b-output.log"
            if deploy_server_b >"${output}" 2>&1; then
                exit 1
            fi

            grep -q "Firewall Setup" "${output}"
            grep -q "DEPLOYMENT INCOMPLETE" "${output}"
            ! grep -q "DEPLOYMENT COMPLETE" "${output}"
            exit 0
        '; then
        record_pass "Root server-b 在安全加固失败时返回失败且不打印完成摘要"
    else
        record_fail "Root server-b 在安全加固失败时返回失败且不打印完成摘要"
    fi

    rm -rf "${temp_root}"
}

test_bridge_server_b_deploy_contracts() {
    info "=== AI Gateway Bridge Server B 主部署状态一致性契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local workdir="${temp_root}/bridge-server-b-deploy"
    mkdir -p "${workdir}"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/server-b.sh" "${workdir}/server-b.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${workdir}/common.sh"
    sed -i "s|^readonly XRAY_LOG_DIR=.*$|readonly XRAY_LOG_DIR=\"${temp_root}/logs/xray\"|" "${workdir}/server-b.sh"
    sed -i "s|^readonly XRAY_CONFIG_DIR=.*$|readonly XRAY_CONFIG_DIR=\"${temp_root}/xray\"|" "${workdir}/server-b.sh"
    sed -i "s|^readonly HYSTERIA_CONFIG_DIR=.*$|readonly HYSTERIA_CONFIG_DIR=\"${temp_root}/hysteria\"|" "${workdir}/server-b.sh"
    sed -i "s|^readonly CADDY_CONFIG_DIR=.*$|readonly CADDY_CONFIG_DIR=\"${temp_root}/caddy\"|" "${workdir}/server-b.sh"
    sed -i "s|^readonly CONNECTION_INFO_FILE=.*$|readonly CONNECTION_INFO_FILE=\"${temp_root}/connection.txt\"|" "${workdir}/server-b.sh"
    sed -i "s|^readonly DEPLOY_STATE_DIR=.*$|readonly DEPLOY_STATE_DIR=\"${temp_root}/state\"|" "${workdir}/server-b.sh"

    cat > "${workdir}/anti-dpi.sh" <<'EOF'
deploy_anti_dpi() { return 0; }
EOF

    cat > "${workdir}/keepalive.sh" <<'EOF'
deploy_keepalive() { return 0; }
EOF

    cat > "${workdir}/dd-reinstall.sh" <<'EOF'
pre_deploy_check() { return 1; }
EOF

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SERVER_B_SH="${workdir}/server-b.sh" \
        TMP_ROOT="${temp_root}" \
        bash -c '
            set -euo pipefail
            source "$SERVER_B_SH"
            confirm_action() {
                if [[ "$1" == "Proceed with Server B deployment?"* ]]; then
                    return 0
                fi
                return 1
            }

            output="${TMP_ROOT}/bridge-server-b-predeploy-output.log"
            if deploy_server_b >"${output}" 2>&1; then
                exit 1
            fi

            grep -q "Pre-deploy check failed. Cannot continue with Server B deployment." "${output}"
            ! grep -q "\\[Step 1/14\\]" "${output}"
            ! grep -q "DEPLOYMENT COMPLETE" "${output}"
            ! grep -q "DEPLOYMENT INCOMPLETE" "${output}"
            exit 0
        '; then
        record_pass "AI Gateway Bridge server-b 在预部署云环境审查失败时会立即终止且不进入后续部署"
    else
        record_fail "AI Gateway Bridge server-b 在预部署云环境审查失败时会立即终止且不进入后续部署"
    fi

    cat > "${workdir}/dd-reinstall.sh" <<'EOF'
pre_deploy_check() { return 0; }
EOF

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SERVER_B_SH="${workdir}/server-b.sh" \
        TMP_ROOT="${temp_root}" \
        bash -c '
            set -euo pipefail
            source "$SERVER_B_SH"
            detect_system() { return 0; }
            _install_base_dependencies() { return 0; }
            full_security_hardening() { return 0; }
            harden_ssh() { return 0; }
            setup_firewall() { return 1; }
            harden_kernel() { return 0; }
            setup_fail2ban() { return 0; }
            setup_auto_updates() { return 0; }
            install_xray_server() { mkdir -p "$(dirname "$XRAY_CONFIG_FILE")"; : > "$XRAY_CONFIG_FILE"; return 0; }
            setup_whitelist_routing() { return 0; }
            install_3xui() { return 0; }
            install_hysteria2_server() { return 0; }
            setup_caddy_b() { mkdir -p "$CADDY_CONFIG_DIR"; : > "${CADDY_CONFIG_DIR}/Caddyfile"; return 0; }
            enable_bbr() { return 0; }
            deploy_monitoring() { return 0; }
            test_connectivity_b() { return 0; }
            _get_public_ip() { echo "203.0.113.20"; }
            confirm_action() {
                if [[ "$1" == "Proceed with Server B deployment?"* ]]; then
                    return 0
                fi
                return 1
            }
            systemctl() {
                if [[ "${1:-}" == "is-active" ]]; then
                    return 1
                fi
                return 0
            }

            output="${TMP_ROOT}/bridge-server-b-output.log"
            if deploy_server_b >"${output}" 2>&1; then
                exit 1
            fi

            grep -q "Firewall Setup" "${output}"
            grep -q "DEPLOYMENT INCOMPLETE" "${output}"
            ! grep -q "DEPLOYMENT COMPLETE" "${output}"
            exit 0
        '; then
        record_pass "AI Gateway Bridge server-b 在安全加固失败时返回失败且不打印完成摘要"
    else
        record_fail "AI Gateway Bridge server-b 在安全加固失败时返回失败且不打印完成摘要"
    fi

    rm -rf "${temp_root}"
}

test_install_deploy_entrypoint_contracts() {
    info "=== install.sh 部署入口状态透传契约 ==="

    if grep -q 'if ! deploy_server_a; then' "${SCRIPT_DIR}/install.sh" && \
       grep -q 'if ! deploy_server_b; then' "${SCRIPT_DIR}/install.sh" && \
       grep -q 'deploy_server_a || exit 1' "${SCRIPT_DIR}/install.sh" && \
       grep -q 'deploy_server_b || exit 1' "${SCRIPT_DIR}/install.sh"; then
        record_pass "Root install.sh 会透传 server-a/server-b 部署失败"
    else
        record_fail "Root install.sh 未透传 server-a/server-b 部署失败"
    fi

    if grep -q 'if ! deploy_server_a; then' "${SCRIPT_DIR}/ai-gateway-bridge/install.sh" && \
       grep -q 'if ! deploy_server_b; then' "${SCRIPT_DIR}/ai-gateway-bridge/install.sh" && \
       grep -q 'deploy_server_a || exit 1' "${SCRIPT_DIR}/ai-gateway-bridge/install.sh" && \
       grep -q 'deploy_server_b || exit 1' "${SCRIPT_DIR}/ai-gateway-bridge/install.sh"; then
        record_pass "AI Gateway Bridge install.sh 会透传 server-a/server-b 部署失败"
    else
        record_fail "AI Gateway Bridge install.sh 未透传 server-a/server-b 部署失败"
    fi

    if grep -q 'if ! deploy_bifrost_api; then' "${SCRIPT_DIR}/install.sh"; then
        record_pass "Root install.sh 会透传 bifrost-api 部署失败"
    else
        record_fail "Root install.sh 未透传 bifrost-api 部署失败"
    fi

    if grep -q '^run_flow_command()' "${SCRIPT_DIR}/install.sh" && \
       grep -q '^run_cli_command()' "${SCRIPT_DIR}/install.sh" && \
       grep -q '^run_flow_command()' "${SCRIPT_DIR}/ai-gateway-bridge/install.sh" && \
       grep -q '^run_cli_command()' "${SCRIPT_DIR}/ai-gateway-bridge/install.sh"; then
        record_pass "Root / AI Gateway Bridge install.sh 已提供统一的 flow/CLI 失败传播 helper"
    else
        record_fail "Root / AI Gateway Bridge install.sh 缺少统一的 flow/CLI 失败传播 helper"
    fi

    local root_cli_patterns=(
        'run_cli_command "安全加固失败，请先处理上方错误。" full_security_hardening'
        'run_cli_command "健康检查失败，请先处理上方错误。" bash "${SCRIPT_DIR}/scripts/health-check.sh" --verbose'
        'run_cli_command "卸载未完成，请先处理上方错误。" uninstall_all'
        'run_cli_command "VPN 部署未完成，请先处理上方错误。" deploy_vpn'
        'run_cli_command "DPI 防护部署未完成，请先处理上方错误。" deploy_anti_dpi'
        'run_cli_command "Mihomo 部署未完成，请先处理上方错误。" deploy_mihomo'
        'run_cli_command "Keepalive 部署未完成，请先处理上方错误。" deploy_keepalive'
        'run_cli_command "网络分流部署未完成，请先处理上方错误。" deploy_split_tunnel'
        'run_cli_command "备份与恢复管理执行失败，请先处理上方错误。" manage_backups'
        'run_cli_command "组件更新管理执行失败，请先处理上方错误。" manage_updates'
        'run_cli_command "多节点 Server B 管理执行失败，请先处理上方错误。" manage_servers'
        'run_cli_command "用户管理执行失败，请先处理上方错误。" manage_users'
        'run_cli_command "Bifrost 管理平台部署未完成，请先处理上方错误。" deploy_bifrost_api'
        'run_cli_command "深度诊断执行失败，请先处理上方错误。" manage_diagnostics'
        'run_cli_command "预部署云环境审查未完成，请先处理上方错误。" pre_deploy_check'
    )

    local missing_root_cli=0
    local pattern
    for pattern in "${root_cli_patterns[@]}"; do
        if ! grep -Fq "${pattern}" "${SCRIPT_DIR}/install.sh"; then
            missing_root_cli=1
            break
        fi
    done
    if [[ "${missing_root_cli}" -eq 0 ]]; then
        record_pass "Root install.sh CLI 子命令会统一透传底层失败"
    else
        record_fail "Root install.sh CLI 子命令仍存在吞失败风险"
    fi

    local bridge_cli_patterns=(
        'run_cli_command "安全加固失败，请先处理上方错误。" full_security_hardening'
        'run_cli_command "健康检查失败，请先处理上方错误。" bash "${SCRIPT_DIR}/scripts/health-check.sh" --verbose'
        'run_cli_command "卸载未完成，请先处理上方错误。" uninstall_all'
        'run_cli_command "VPN 部署未完成，请先处理上方错误。" deploy_vpn'
        'run_cli_command "DPI 防护部署未完成，请先处理上方错误。" deploy_anti_dpi'
        'run_cli_command "Mihomo 部署未完成，请先处理上方错误。" deploy_mihomo'
        'run_cli_command "Keepalive 部署未完成，请先处理上方错误。" deploy_keepalive'
        'run_cli_command "网络分流部署未完成，请先处理上方错误。" deploy_split_tunnel'
        'run_cli_command "备份与恢复管理执行失败，请先处理上方错误。" manage_backups'
        'run_cli_command "组件更新管理执行失败，请先处理上方错误。" manage_updates'
        'run_cli_command "多节点 Server B 管理执行失败，请先处理上方错误。" manage_servers'
        'run_cli_command "用户管理执行失败，请先处理上方错误。" manage_users'
        'run_cli_command "深度诊断执行失败，请先处理上方错误。" manage_diagnostics'
        'run_cli_command "预部署云环境审查未完成，请先处理上方错误。" pre_deploy_check'
    )

    local missing_bridge_cli=0
    for pattern in "${bridge_cli_patterns[@]}"; do
        if ! grep -Fq "${pattern}" "${SCRIPT_DIR}/ai-gateway-bridge/install.sh"; then
            missing_bridge_cli=1
            break
        fi
    done
    if [[ "${missing_bridge_cli}" -eq 0 ]]; then
        record_pass "AI Gateway Bridge install.sh CLI 子命令会统一透传底层失败"
    else
        record_fail "AI Gateway Bridge install.sh CLI 子命令仍存在吞失败风险"
    fi

    if grep -q 'if ! manage_whitelist; then' "${SCRIPT_DIR}/install.sh" && \
       grep -q 'if ! deploy_monitoring; then' "${SCRIPT_DIR}/install.sh" && \
       grep -q 'if ! pre_deploy_check; then' "${SCRIPT_DIR}/install.sh" && \
       grep -q 'if ! deploy_vpn; then' "${SCRIPT_DIR}/install.sh" && \
       grep -q 'if ! manage_whitelist; then' "${SCRIPT_DIR}/ai-gateway-bridge/install.sh" && \
       grep -q 'if ! deploy_monitoring; then' "${SCRIPT_DIR}/ai-gateway-bridge/install.sh" && \
       grep -q 'if ! pre_deploy_check; then' "${SCRIPT_DIR}/ai-gateway-bridge/install.sh" && \
       grep -q 'if ! deploy_vpn; then' "${SCRIPT_DIR}/ai-gateway-bridge/install.sh"; then
        record_pass "Root / AI Gateway Bridge 菜单 flow 不再在关键子命令失败后继续宣告完成"
    else
        record_fail "Root / AI Gateway Bridge 菜单 flow 仍可能在关键子命令失败后继续宣告完成"
    fi
}

test_dd_reinstall_contracts() {
    info "=== dd-reinstall 前置检查 fail-fast 契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local workdir="${temp_root}/root-dd"
    mkdir -p "${workdir}"
    cp "${SCRIPT_DIR}/scripts/dd-reinstall.sh" "${workdir}/dd-reinstall.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${workdir}/common.sh"

    local dangerous_pattern
    local root_dd_static_ok=1
    local dangerous_patterns=(
        "Cloud Agent Cleanup"
        "monitoring agents / security daemons / telemetry"
        "Remove detected agents only"
        "systemctl mask \"\${svc}\""
        "pkill -9"
        "apt-get purge -y \"\${pkg}\""
        "dnf remove -y \"\${pkg}\""
        "yum remove -y \"\${pkg}\""
        "rm -rf \"\${agent_path}\""
        "systemctl mask cloud-init cloud-config cloud-final"
    )
    for dangerous_pattern in "${dangerous_patterns[@]}"; do
        if grep -Fq -- "${dangerous_pattern}" "${workdir}/dd-reinstall.sh"; then
            root_dd_static_ok=0
            break
        fi
    done
    if [[ "${root_dd_static_ok}" -eq 1 ]] && \
       grep -Fq "Cloud Readiness Review Options" "${workdir}/dd-reinstall.sh" && \
       grep -Fq "Cloud integration review was not acknowledged. Deployment must stop." "${workdir}/dd-reinstall.sh"; then
        record_pass "Root dd-reinstall uses non-destructive cloud readiness review contract"
    else
        record_fail "Root dd-reinstall still contains destructive provider-component modification contract"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        DD_REINSTALL_SH="${workdir}/dd-reinstall.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$DD_REINSTALL_SH"
            OS_ID="ubuntu"
            require_root() { return 0; }
            detect_cloud_provider() { DETECTED_PROVIDER="unknown"; return 1; }
            detect_preinstalled_agents() { return 1; }
            offer_dd_reinstall() { return 0; }
            verify_clean_system() { return 0; }
            if ! pre_deploy_check >"${output_file}" 2>&1; then
                exit 1
            fi
            grep -q "Pre-deployment check complete. Proceeding with deployment" "${output_file}"
        '; then
        record_pass "Root dd-reinstall 在未知云厂商且系统干净时允许继续部署"
    else
        record_fail "Root dd-reinstall 在未知云厂商且系统干净时允许继续部署"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        DD_REINSTALL_SH="${workdir}/dd-reinstall.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$DD_REINSTALL_SH"
            OS_ID="ubuntu"
            require_root() { return 0; }
            detect_cloud_provider() { DETECTED_PROVIDER="tencent"; return 0; }
            detect_preinstalled_agents() { return 0; }
            offer_dd_reinstall() { return 1; }
            verify_clean_system() { return 0; }
            if pre_deploy_check >"${output_file}" 2>&1; then
                exit 1
            fi
            grep -q "Cloud integration review was not acknowledged. Deployment must stop." "${output_file}"
            ! grep -q "Pre-deployment check complete. Proceeding with deployment" "${output_file}"
        '; then
        record_pass "Root dd-reinstall 在检测到云集成但未确认审查时会阻断部署"
    else
        record_fail "Root dd-reinstall 在检测到云集成但未确认审查时会阻断部署"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        DD_REINSTALL_SH="${workdir}/dd-reinstall.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$DD_REINSTALL_SH"
            OS_ID="ubuntu"
            require_root() { return 0; }
            detect_cloud_provider() { DETECTED_PROVIDER="unknown"; return 1; }
            detect_preinstalled_agents() { return 1; }
            offer_dd_reinstall() { return 0; }
            verify_clean_system() { return 1; }
            if pre_deploy_check >"${output_file}" 2>&1; then
                exit 1
            fi
            grep -q "Cloud readiness verification detected unresolved issues. Deployment must stop." "${output_file}"
            ! grep -q "Pre-deployment check complete. Proceeding with deployment" "${output_file}"
        '; then
        record_pass "Root dd-reinstall 在云就绪校验失败时会阻断部署"
    else
        record_fail "Root dd-reinstall 在云就绪校验失败时会阻断部署"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        DD_REINSTALL_SH="${workdir}/dd-reinstall.sh" \
        bash -c '
            set -euo pipefail
            source "$DD_REINSTALL_SH"
            show_menu() { MENU_RESULT=1; }
            _do_light_clean() { return 1; }
            if offer_dd_reinstall; then
                exit 1
            fi
        '; then
        record_pass "Root offer_dd_reinstall 在云集成审查取消/失败时会透传非零"
    else
        record_fail "Root offer_dd_reinstall 在云集成审查取消/失败时会透传非零"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        DD_REINSTALL_SH="${workdir}/dd-reinstall.sh" \
        bash -c '
            set -euo pipefail
            source "$DD_REINSTALL_SH"
            show_menu() { MENU_RESULT=2; }
            _do_dd_reinstall() { return 1; }
            if offer_dd_reinstall; then
                exit 1
            fi
        '; then
        record_pass "Root offer_dd_reinstall 在 Full DD Reinstall 取消/失败时会透传非零"
    else
        record_fail "Root offer_dd_reinstall 在 Full DD Reinstall 取消/失败时会透传非零"
    fi

    rm -rf "${temp_root}"
}

test_bridge_dd_reinstall_contracts() {
    info "=== AI Gateway Bridge dd-reinstall 前置检查 fail-fast 契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local workdir="${temp_root}/bridge-dd"
    mkdir -p "${workdir}"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/dd-reinstall.sh" "${workdir}/dd-reinstall.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${workdir}/common.sh"

    local dangerous_pattern
    local bridge_dd_static_ok=1
    local dangerous_patterns=(
        "Cloud Agent Cleanup"
        "monitoring agents / security daemons / telemetry"
        "Remove detected agents only"
        "systemctl mask \"\${svc}\""
        "pkill -9"
        "apt-get purge -y \"\${pkg}\""
        "dnf remove -y \"\${pkg}\""
        "yum remove -y \"\${pkg}\""
        "rm -rf \"\${agent_path}\""
        "systemctl mask cloud-init cloud-config cloud-final"
    )
    for dangerous_pattern in "${dangerous_patterns[@]}"; do
        if grep -Fq -- "${dangerous_pattern}" "${workdir}/dd-reinstall.sh"; then
            bridge_dd_static_ok=0
            break
        fi
    done
    if [[ "${bridge_dd_static_ok}" -eq 1 ]] && \
       grep -Fq "Cloud Readiness Review Options" "${workdir}/dd-reinstall.sh" && \
       grep -Fq "Cloud integration review was not acknowledged. Deployment must stop." "${workdir}/dd-reinstall.sh"; then
        record_pass "AI Gateway Bridge dd-reinstall uses non-destructive cloud readiness review contract"
    else
        record_fail "AI Gateway Bridge dd-reinstall still contains destructive provider-component modification contract"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        DD_REINSTALL_SH="${workdir}/dd-reinstall.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$DD_REINSTALL_SH"
            OS_ID="ubuntu"
            require_root() { return 0; }
            detect_cloud_provider() { DETECTED_PROVIDER="unknown"; return 1; }
            detect_preinstalled_agents() { return 1; }
            offer_dd_reinstall() { return 0; }
            verify_clean_system() { return 0; }
            if ! pre_deploy_check >"${output_file}" 2>&1; then
                exit 1
            fi
            grep -q "Pre-deployment check complete. Proceeding with deployment" "${output_file}"
        '; then
        record_pass "AI Gateway Bridge dd-reinstall 在未知云厂商且系统干净时允许继续部署"
    else
        record_fail "AI Gateway Bridge dd-reinstall 在未知云厂商且系统干净时允许继续部署"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        DD_REINSTALL_SH="${workdir}/dd-reinstall.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$DD_REINSTALL_SH"
            OS_ID="ubuntu"
            require_root() { return 0; }
            detect_cloud_provider() { DETECTED_PROVIDER="tencent"; return 0; }
            detect_preinstalled_agents() { return 0; }
            offer_dd_reinstall() { return 1; }
            verify_clean_system() { return 0; }
            if pre_deploy_check >"${output_file}" 2>&1; then
                exit 1
            fi
            grep -q "Cloud integration review was not acknowledged. Deployment must stop." "${output_file}"
            ! grep -q "Pre-deployment check complete. Proceeding with deployment" "${output_file}"
        '; then
        record_pass "AI Gateway Bridge dd-reinstall 在检测到云集成但未确认审查时会阻断部署"
    else
        record_fail "AI Gateway Bridge dd-reinstall 在检测到云集成但未确认审查时会阻断部署"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        DD_REINSTALL_SH="${workdir}/dd-reinstall.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$DD_REINSTALL_SH"
            OS_ID="ubuntu"
            require_root() { return 0; }
            detect_cloud_provider() { DETECTED_PROVIDER="unknown"; return 1; }
            detect_preinstalled_agents() { return 1; }
            offer_dd_reinstall() { return 0; }
            verify_clean_system() { return 1; }
            if pre_deploy_check >"${output_file}" 2>&1; then
                exit 1
            fi
            grep -q "Cloud readiness verification detected unresolved issues. Deployment must stop." "${output_file}"
            ! grep -q "Pre-deployment check complete. Proceeding with deployment" "${output_file}"
        '; then
        record_pass "AI Gateway Bridge dd-reinstall 在云就绪校验失败时会阻断部署"
    else
        record_fail "AI Gateway Bridge dd-reinstall 在云就绪校验失败时会阻断部署"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        DD_REINSTALL_SH="${workdir}/dd-reinstall.sh" \
        bash -c '
            set -euo pipefail
            source "$DD_REINSTALL_SH"
            show_menu() { MENU_RESULT=1; }
            _do_light_clean() { return 1; }
            if offer_dd_reinstall; then
                exit 1
            fi
        '; then
        record_pass "AI Gateway Bridge offer_dd_reinstall 在云集成审查取消/失败时会透传非零"
    else
        record_fail "AI Gateway Bridge offer_dd_reinstall 在云集成审查取消/失败时会透传非零"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        DD_REINSTALL_SH="${workdir}/dd-reinstall.sh" \
        bash -c '
            set -euo pipefail
            source "$DD_REINSTALL_SH"
            show_menu() { MENU_RESULT=2; }
            _do_dd_reinstall() { return 1; }
            if offer_dd_reinstall; then
                exit 1
            fi
        '; then
        record_pass "AI Gateway Bridge offer_dd_reinstall 在 Full DD Reinstall 取消/失败时会透传非零"
    else
        record_fail "AI Gateway Bridge offer_dd_reinstall 在 Full DD Reinstall 取消/失败时会透传非零"
    fi

    rm -rf "${temp_root}"
}

test_keepalive_contracts() {
    info "=== Keepalive 控制面 fail-fast 契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local workdir="${temp_root}/root-keepalive"
    mkdir -p "${workdir}"
    cp "${SCRIPT_DIR}/scripts/keepalive.sh" "${workdir}/keepalive.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${workdir}/common.sh"
    mkdir -p "${temp_root}/configs/keepalive"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${temp_root}/configs/keepalive/heartbeat.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${temp_root}/configs/keepalive/watchdog.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        KEEPALIVE_SH="${workdir}/keepalive.sh" \
        INSTALL_DIR="${temp_root}/install" \
        LOG_DIR="${temp_root}/log" \
        KEEPALIVE_STATE_DIR="${temp_root}/state" \
        SYSTEMD_UNIT_DIR="${temp_root}/systemd" \
        bash -c '
            set -euo pipefail
            local_output="$(mktemp)"
            trap "rm -f \"${local_output}\"" EXIT
            source "$KEEPALIVE_SH"
            setup_tcp_keepalive() { return 0; }
            setup_xray_keepalive() { return 0; }
            sleep() { :; }
            systemctl() {
                if [[ "${1:-}" == "start" && "${2:-}" == "ai-gateway-heartbeat.timer" ]]; then
                    return 1
                fi
                if [[ "${1:-}" == "is-active" && "${3:-}" == "ai-gateway-heartbeat.timer" ]]; then
                    return 0
                fi
                return 0
            }
            if deploy_keepalive >"${local_output}" 2>&1; then
                exit 1
            fi
            grep -q "Failed to start heartbeat timer." "${local_output}"
            ! grep -q "Heartbeat service deployed." "${local_output}"
            ! grep -q "Keepalive Deployment Complete" "${local_output}"
        '; then
        record_pass "Root keepalive 在 heartbeat timer 启动失败时会终止且不打印完成摘要"
    else
        record_fail "Root keepalive 在 heartbeat timer 启动失败时会终止且不打印完成摘要"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        KEEPALIVE_SH="${workdir}/keepalive.sh" \
        INSTALL_DIR="${temp_root}/install" \
        LOG_DIR="${temp_root}/log" \
        KEEPALIVE_STATE_DIR="${temp_root}/state" \
        SYSTEMD_UNIT_DIR="${temp_root}/systemd" \
        bash -c '
            set -euo pipefail
            local_output="$(mktemp)"
            trap "rm -f \"${local_output}\"" EXIT
            source "$KEEPALIVE_SH"
            setup_tcp_keepalive() { return 0; }
            setup_xray_keepalive() { return 0; }
            sleep() { :; }
            systemctl() {
                if [[ "${1:-}" == "is-active" && "${3:-}" == "ai-gateway-heartbeat.timer" ]]; then
                    return 0
                fi
                if [[ "${1:-}" == "is-active" && "${3:-}" == "ai-gateway-watchdog.service" ]]; then
                    return 1
                fi
                return 0
            }
            if deploy_keepalive >"${local_output}" 2>&1; then
                exit 1
            fi
            grep -q "Watchdog service failed to reach active state." "${local_output}"
            ! grep -q "Watchdog service is running." "${local_output}"
            ! grep -q "Keepalive Deployment Complete" "${local_output}"
        '; then
        record_pass "Root keepalive 在 watchdog 未进入 active 时会终止且不打印完成摘要"
    else
        record_fail "Root keepalive 在 watchdog 未进入 active 时会终止且不打印完成摘要"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        KEEPALIVE_SH="${workdir}/keepalive.sh" \
        XRAY_CONFIG="${temp_root}/missing-xray-config.json" \
        bash -c '
            set -euo pipefail
            local_output="$(mktemp)"
            trap "rm -f \"${local_output}\"" EXIT
            source "$KEEPALIVE_SH"
            setup_tcp_keepalive() { return 0; }
            setup_heartbeat_service() { return 0; }
            setup_watchdog() { return 0; }
            install_if_missing() { return 0; }
            if deploy_keepalive >"${local_output}" 2>&1; then
                exit 1
            fi
            ! grep -q "Xray sockopt: keepalive injected into config" "${local_output}"
            ! grep -q "Keepalive Deployment Complete" "${local_output}"
        '; then
        record_pass "Root keepalive 在缺失 Xray config 时会终止且不打印完成摘要"
    else
        record_fail "Root keepalive 在缺失 Xray config 时会终止且不打印完成摘要"
    fi

    local invalid_config="${temp_root}/invalid-xray-config.json"
    printf '{ invalid json }\n' > "${invalid_config}"
    if BIFROST_TRACE_COMMON_LOAD=0 \
        KEEPALIVE_SH="${workdir}/keepalive.sh" \
        XRAY_CONFIG="${invalid_config}" \
        bash -c '
            set -euo pipefail
            local_output="$(mktemp)"
            trap "rm -f \"${local_output}\"" EXIT
            source "$KEEPALIVE_SH"
            setup_tcp_keepalive() { return 0; }
            setup_heartbeat_service() { return 0; }
            setup_watchdog() { return 0; }
            install_if_missing() { return 0; }
            if deploy_keepalive >"${local_output}" 2>&1; then
                exit 1
            fi
            ! grep -q "Xray sockopt: keepalive injected into config" "${local_output}"
            ! grep -q "Keepalive Deployment Complete" "${local_output}"
        '; then
        record_pass "Root keepalive 在 Xray config 非法 JSON 时会终止且不打印完成摘要"
    else
        record_fail "Root keepalive 在 Xray config 非法 JSON 时会终止且不打印完成摘要"
    fi

    rm -rf "${temp_root}"
}

test_bridge_keepalive_contracts() {
    info "=== AI Gateway Bridge Keepalive 控制面 fail-fast 契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local workdir="${temp_root}/bridge-keepalive"
    mkdir -p "${workdir}"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/keepalive.sh" "${workdir}/keepalive.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${workdir}/common.sh"
    mkdir -p "${temp_root}/configs/keepalive"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${temp_root}/configs/keepalive/heartbeat.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "${temp_root}/configs/keepalive/watchdog.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        KEEPALIVE_SH="${workdir}/keepalive.sh" \
        INSTALL_DIR="${temp_root}/install" \
        LOG_DIR="${temp_root}/log" \
        KEEPALIVE_STATE_DIR="${temp_root}/state" \
        SYSTEMD_UNIT_DIR="${temp_root}/systemd" \
        bash -c '
            set -euo pipefail
            local_output="$(mktemp)"
            trap "rm -f \"${local_output}\"" EXIT
            source "$KEEPALIVE_SH"
            setup_tcp_keepalive() { return 0; }
            setup_xray_keepalive() { return 0; }
            sleep() { :; }
            systemctl() {
                if [[ "${1:-}" == "start" && "${2:-}" == "ai-gateway-heartbeat.timer" ]]; then
                    return 1
                fi
                if [[ "${1:-}" == "is-active" && "${3:-}" == "ai-gateway-heartbeat.timer" ]]; then
                    return 0
                fi
                return 0
            }
            if deploy_keepalive >"${local_output}" 2>&1; then
                exit 1
            fi
            grep -q "Failed to start heartbeat timer." "${local_output}"
            ! grep -q "Heartbeat service deployed." "${local_output}"
            ! grep -q "Keepalive Deployment Complete" "${local_output}"
        '; then
        record_pass "AI Gateway Bridge keepalive 在 heartbeat timer 启动失败时会终止且不打印完成摘要"
    else
        record_fail "AI Gateway Bridge keepalive 在 heartbeat timer 启动失败时会终止且不打印完成摘要"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        KEEPALIVE_SH="${workdir}/keepalive.sh" \
        INSTALL_DIR="${temp_root}/install" \
        LOG_DIR="${temp_root}/log" \
        KEEPALIVE_STATE_DIR="${temp_root}/state" \
        SYSTEMD_UNIT_DIR="${temp_root}/systemd" \
        bash -c '
            set -euo pipefail
            local_output="$(mktemp)"
            trap "rm -f \"${local_output}\"" EXIT
            source "$KEEPALIVE_SH"
            setup_tcp_keepalive() { return 0; }
            setup_xray_keepalive() { return 0; }
            sleep() { :; }
            systemctl() {
                if [[ "${1:-}" == "is-active" && "${3:-}" == "ai-gateway-heartbeat.timer" ]]; then
                    return 0
                fi
                if [[ "${1:-}" == "is-active" && "${3:-}" == "ai-gateway-watchdog.service" ]]; then
                    return 1
                fi
                return 0
            }
            if deploy_keepalive >"${local_output}" 2>&1; then
                exit 1
            fi
            grep -q "Watchdog service failed to reach active state." "${local_output}"
            ! grep -q "Watchdog service is running." "${local_output}"
            ! grep -q "Keepalive Deployment Complete" "${local_output}"
        '; then
        record_pass "AI Gateway Bridge keepalive 在 watchdog 未进入 active 时会终止且不打印完成摘要"
    else
        record_fail "AI Gateway Bridge keepalive 在 watchdog 未进入 active 时会终止且不打印完成摘要"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        KEEPALIVE_SH="${workdir}/keepalive.sh" \
        XRAY_CONFIG="${temp_root}/missing-xray-config.json" \
        bash -c '
            set -euo pipefail
            local_output="$(mktemp)"
            trap "rm -f \"${local_output}\"" EXIT
            source "$KEEPALIVE_SH"
            setup_tcp_keepalive() { return 0; }
            setup_heartbeat_service() { return 0; }
            setup_watchdog() { return 0; }
            install_if_missing() { return 0; }
            if deploy_keepalive >"${local_output}" 2>&1; then
                exit 1
            fi
            ! grep -q "Xray sockopt: keepalive injected into config" "${local_output}"
            ! grep -q "Keepalive Deployment Complete" "${local_output}"
        '; then
        record_pass "AI Gateway Bridge keepalive 在缺失 Xray config 时会终止且不打印完成摘要"
    else
        record_fail "AI Gateway Bridge keepalive 在缺失 Xray config 时会终止且不打印完成摘要"
    fi

    local invalid_config="${temp_root}/invalid-xray-config.json"
    printf '{ invalid json }\n' > "${invalid_config}"
    if BIFROST_TRACE_COMMON_LOAD=0 \
        KEEPALIVE_SH="${workdir}/keepalive.sh" \
        XRAY_CONFIG="${invalid_config}" \
        bash -c '
            set -euo pipefail
            local_output="$(mktemp)"
            trap "rm -f \"${local_output}\"" EXIT
            source "$KEEPALIVE_SH"
            setup_tcp_keepalive() { return 0; }
            setup_heartbeat_service() { return 0; }
            setup_watchdog() { return 0; }
            install_if_missing() { return 0; }
            if deploy_keepalive >"${local_output}" 2>&1; then
                exit 1
            fi
            ! grep -q "Xray sockopt: keepalive injected into config" "${local_output}"
            ! grep -q "Keepalive Deployment Complete" "${local_output}"
        '; then
        record_pass "AI Gateway Bridge keepalive 在 Xray config 非法 JSON 时会终止且不打印完成摘要"
    else
        record_fail "AI Gateway Bridge keepalive 在 Xray config 非法 JSON 时会终止且不打印完成摘要"
    fi

    rm -rf "${temp_root}"
}

test_security_contracts() {
    info "=== Security Audit fail-fast 契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local workdir="${temp_root}/root-security"
    mkdir -p "${workdir}"
    cp "${SCRIPT_DIR}/scripts/security.sh" "${workdir}/security.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${workdir}/common.sh"

    mkdir -p "${temp_root}/etc/ssh" "${temp_root}/root/.ssh"
    cat > "${temp_root}/etc/ssh/sshd_config" <<'EOF'
Port 22
PasswordAuthentication yes
PermitRootLogin yes
PubkeyAuthentication yes
EOF
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey root@test\n' > "${temp_root}/root/.ssh/authorized_keys"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        SECURITY_STATE_DIR="${temp_root}/state" \
        SECURITY_STATE_FILE="${temp_root}/state/security.env" \
        SSHD_CONFIG_PATH="${temp_root}/etc/ssh/sshd_config" \
        SSHD_BACKUP_DIR="${temp_root}/etc/ssh" \
        SSH_ADMIN_DIR="${temp_root}/root/.ssh" \
        SSH_AUTHORIZED_KEYS_FILE="${temp_root}/root/.ssh/authorized_keys" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            restart_marker="$(mktemp)"
            trap "rm -f \"${output}\" \"${restart_marker}\"" EXIT
            source "$SECURITY_SH"
            _generate_random_port() { echo 2222; }
            _get_ssh_port() { echo 22; }
            _save_state() { :; }
            sshd() { return 0; }
            sleep() { :; }
            nohup() { :; }
            systemctl() {
                if [[ "${1:-}" == "restart" ]]; then
                    echo restart >> "${restart_marker}"
                fi
                if [[ "${1:-}" == "is-active" ]]; then
                    return 0
                fi
                return 0
            }
            _detect_firewall() { echo ufw; }
            ufw() {
                if [[ "${1:-}" == "allow" && "${2:-}" == "2222/tcp" ]]; then
                    return 1
                fi
                return 0
            }
            if printf "2222\nn\n" | harden_ssh >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "Failed to open new SSH port 2222/tcp in ufw." "${output}"
            grep -q "Firewall update failed before SSH restart. Restoring backup to avoid lockout." "${output}"
            ! grep -q "SSH hardening complete." "${output}"
            [[ ! -s "${restart_marker}" ]]
        '; then
        record_pass "Root harden_ssh 在防火墙放行新端口失败时会终止且不会重启 sshd"
    else
        record_fail "Root harden_ssh 在防火墙放行新端口失败时会终止且不会重启 sshd"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        SECURITY_STATE_DIR="${temp_root}/state" \
        SECURITY_STATE_FILE="${temp_root}/state/security.env" \
        SSHD_CONFIG_PATH="${temp_root}/etc/ssh/sshd_config" \
        SSHD_BACKUP_DIR="${temp_root}/etc/ssh" \
        SSH_ADMIN_DIR="${temp_root}/root/.ssh" \
        SSH_AUTHORIZED_KEYS_FILE="${temp_root}/root/.ssh/authorized_keys" \
        bash -c '
            set -euo pipefail
            mkdir -p "$(dirname "${SSHD_CONFIG_PATH}")" "${SSH_ADMIN_DIR}" "${SSHD_BACKUP_DIR}" "${SECURITY_STATE_DIR}"
            cat > "${SSHD_CONFIG_PATH}" <<EOF
Port 22
PasswordAuthentication yes
PermitRootLogin yes
PubkeyAuthentication yes
EOF
            printf "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey root@test\n" > "${SSH_AUTHORIZED_KEYS_FILE}"
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$SECURITY_SH"
            sshd() { return 0; }
            _detect_firewall() { echo none; }
            systemctl() {
                if [[ "${1:-}" == "is-active" ]]; then
                    return 0
                fi
                if [[ "${1:-}" == "restart" ]]; then
                    return 1
                fi
                return 0
            }
            if printf "22\nn\n" | harden_ssh >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "Failed to restart sshd service." "${output}"
            grep -q "Failed to restart SSH daemon after applying hardened config. Restoring backup." "${output}"
            ! grep -q "SSH hardening complete." "${output}"
            grep -q "^PasswordAuthentication yes$" "${SSHD_CONFIG_PATH}"
            grep -q "^PermitRootLogin yes$" "${SSHD_CONFIG_PATH}"
            test -f "${SECURITY_STATE_FILE}"
        '; then
        record_pass "Root harden_ssh 在重启失败但服务仍 active 时会返回失败并恢复备份"
    else
        record_fail "Root harden_ssh 在重启失败但服务仍 active 时会返回失败并恢复备份"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        SECURITY_STATE_DIR="${temp_root}/state" \
        SECURITY_STATE_FILE="${temp_root}/state/security.env" \
        SSHD_CONFIG_PATH="${temp_root}/etc/ssh/sshd_config" \
        SSHD_BACKUP_DIR="${temp_root}/etc/ssh" \
        SSH_ADMIN_DIR="${temp_root}/root/.ssh" \
        SSH_AUTHORIZED_KEYS_FILE="${temp_root}/root/.ssh/authorized_keys" \
        bash -c '
            set -euo pipefail
            revert_script="/tmp/ssh-revert-safety.sh"
            trap "rm -f \"${revert_script}\"" EXIT
            rm -f "${revert_script}"
            source "$SECURITY_SH"
            _generate_random_port() { echo 2222; }
            _get_ssh_port() { echo 22; }
            _save_state() { :; }
            sshd() { return 0; }
            sleep() { :; }
            nohup() { :; }
            _detect_firewall() { echo none; }
            systemctl() { return 0; }
            printf "2222\nn\n" | harden_ssh >/dev/null 2>&1
            test -f "${revert_script}"
            grep -Fq "Failed to restore SSH config backup." "${revert_script}"
            grep -Fq "Failed to restart SSH daemon after revert. Manual recovery required." "${revert_script}"
            ! grep -Fq "systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true" "${revert_script}"
        '; then
        record_pass "Root harden_ssh 生成的 safety revert 脚本不再吞掉 SSH 恢复失败"
    else
        record_fail "Root harden_ssh 生成的 safety revert 脚本不再吞掉 SSH 恢复失败"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$SECURITY_SH"
            _get_ssh_port() { echo 2222; }
            _detect_firewall() { echo ufw; }
            _save_state() { :; }
            ufw() {
                if [[ "${1:-}" == "--force" && "${2:-}" == "reset" ]]; then
                    return 1
                fi
                return 0
            }
            if setup_firewall >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "Failed to reset ufw to defaults." "${output}"
            ! grep -q "Firewall setup complete." "${output}"
        '; then
        record_pass "Root setup_firewall 在 ufw reset 失败时会返回失败且不宣称已完成"
    else
        record_fail "Root setup_firewall 在 ufw reset 失败时会返回失败且不宣称已完成"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$SECURITY_SH"
            _get_ssh_port() { echo 2222; }
            _detect_firewall() { echo firewalld; }
            _save_state() { :; }
            systemctl() { return 0; }
            firewall-cmd() {
                if [[ "${1:-}" == "--set-default-zone=public" ]]; then
                    return 1
                fi
                return 0
            }
            if setup_firewall >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "Failed to set firewalld default zone to public." "${output}"
            ! grep -q "Firewall setup complete." "${output}"
        '; then
        record_pass "Root setup_firewall 在 firewalld 关键步骤失败时会返回失败且不宣称已完成"
    else
        record_fail "Root setup_firewall 在 firewalld 关键步骤失败时会返回失败且不宣称已完成"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        FAIL2BAN_FILTER_DIR="${temp_root}/fail2ban/filter.d" \
        FAIL2BAN_JAIL_FILE="${temp_root}/fail2ban/jail.local" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$SECURITY_SH"
            _get_ssh_port() { echo 22; }
            fail2ban-client() { return 0; }
            systemctl() {
                if [[ "${1:-}" == "restart" ]]; then
                    return 1
                fi
                return 0
            }
            sleep() { :; }
            if setup_fail2ban >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "Failed to restart fail2ban service." "${output}"
            ! grep -q "fail2ban setup complete." "${output}"
        '; then
        record_pass "Root setup_fail2ban 在服务重启失败时会返回失败且不宣称已完成"
    else
        record_fail "Root setup_fail2ban 在服务重启失败时会返回失败且不宣称已完成"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        AUTO_UPGRADES_CONFIG_FILE="${temp_root}/apt/50unattended-upgrades" \
        AUTO_UPGRADES_PERIODIC_FILE="${temp_root}/apt/20auto-upgrades" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$SECURITY_SH"
            apt-get() { return 0; }
            lsb_release() {
                if [[ "${1:-}" == "-is" ]]; then
                    echo Ubuntu
                else
                    echo noble
                fi
            }
            unattended-upgrades() {
                echo "dry run failed" >&2
                return 1
            }
            if setup_auto_updates >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "unattended-upgrades dry run failed." "${output}"
            ! grep -q "Automatic security updates configured." "${output}"
        '; then
        record_pass "Root setup_auto_updates 在 unattended-upgrades 验证失败时会返回失败且不宣称已完成"
    else
        record_fail "Root setup_auto_updates 在 unattended-upgrades 验证失败时会返回失败且不宣称已完成"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$SECURITY_SH"
            _install_rkhunter() {
                echo "RK_FAIL"
                return 1
            }
            _install_lynis() {
                echo "LY_SHOULD_NOT_RUN"
                return 0
            }
            if install_security_tools >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "RK_FAIL" "${output}"
            ! grep -q "LY_SHOULD_NOT_RUN" "${output}"
            ! grep -q "Security tools installation complete." "${output}"
        '; then
        record_pass "Root install_security_tools 在子安装器失败时会返回失败且不宣称已完成"
    else
        record_fail "Root install_security_tools 在子安装器失败时会返回失败且不宣称已完成"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        RKHUNTER_CRON_FILE="${temp_root}/cron/rkhunter-scan" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$SECURITY_SH"
            rkhunter() {
                case "${1:-}" in
                    --update|--propupd)
                        return 0
                        ;;
                    --check)
                        echo "scan failed" >&2
                        return 1
                        ;;
                esac
                return 0
            }
            if _install_rkhunter >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "Initial rkhunter scan failed." "${output}"
            ! grep -q "rkhunter installation and configuration complete." "${output}"
            ! test -f "${RKHUNTER_CRON_FILE}"
        '; then
        record_pass "Root _install_rkhunter 在初始扫描失败时会返回失败且不宣称已完成"
    else
        record_fail "Root _install_rkhunter 在初始扫描失败时会返回失败且不宣称已完成"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        RKHUNTER_CRON_FILE="${temp_root}/cron/rkhunter-scan" \
        bash -c '
            set -euo pipefail
            source "$SECURITY_SH"
            rkhunter() {
                case "${1:-}" in
                    --update|--propupd|--check)
                        return 0
                        ;;
                esac
                return 0
            }
            _install_rkhunter >/dev/null 2>&1
            test -f "${RKHUNTER_CRON_FILE}"
            grep -Fq "RKHUNTER_BIN=\"\${RKHUNTER_BIN:-/usr/bin/rkhunter}\"" "${RKHUNTER_CRON_FILE}"
            grep -Fq "RKHUNTER_LOG_DIR=\"\${RKHUNTER_LOG_DIR:-/var/log}\"" "${RKHUNTER_CRON_FILE}"
            grep -Fq "if ! \"\${RKHUNTER_BIN}\" --check --skip-keypress --nocolors --report-warnings-only >> \"\${LOG_FILE}\" 2>&1; then" "${RKHUNTER_CRON_FILE}"
            grep -Fq "[rkhunter-cron] scan failed." "${RKHUNTER_CRON_FILE}"
            ! grep -Fq "/usr/bin/rkhunter --update --nocolors 2>/dev/null || true" "${RKHUNTER_CRON_FILE}"
            ! grep -Fq "/usr/bin/rkhunter --check --skip-keypress --nocolors --report-warnings-only > \"\${LOG_FILE}\" 2>&1 || true" "${RKHUNTER_CRON_FILE}"
        '; then
        record_pass "Root _install_rkhunter 生成的 weekly cron 不再吞掉扫描失败"
    else
        record_fail "Root _install_rkhunter 生成的 weekly cron 不再吞掉扫描失败"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        LYNIS_LOG_DIR="${temp_root}/lynis" \
        LYNIS_REPORT_FILE="${temp_root}/lynis/lynis-report.txt" \
        LYNIS_DATA_FILE="${temp_root}/lynis/lynis-report.dat" \
        LYNIS_CRON_FILE="/proc/1/bifrost-test/lynis-audit" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$SECURITY_SH"
            lynis() {
                echo "Hardening index : 80"
                printf "hardening_index=80\n" > "${LYNIS_DATA_FILE}"
                return 0
            }
            _display_lynis_summary() { :; }
            if _install_lynis >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "Failed to create monthly Lynis cron directory for ${LYNIS_CRON_FILE}." "${output}"
            ! grep -q "Lynis installation and configuration complete." "${output}"
        '; then
        record_pass "Root _install_lynis 在月度 cron 物化失败时会返回失败且不宣称已完成"
    else
        record_fail "Root _install_lynis 在月度 cron 物化失败时会返回失败且不宣称已完成"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$SECURITY_SH"
            _get_ssh_port() { echo 22; }
            _detect_firewall() { echo ufw; }
            ss() {
                cat <<'\''EOF'\''
State Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))
LISTEN 0 128 0.0.0.0:5555 0.0.0.0:* users:(("mystery",pid=2,fd=4))
EOF
            }
            netstat() { return 1; }
            ufw() {
                if [[ "${1:-}" == "deny" && "${2:-}" == "5555/tcp" ]]; then
                    return 1
                fi
                return 0
            }
            if printf "y\n" | audit_ports >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "Failed to block port 5555/tcp via ufw." "${output}"
            grep -q "Failed to block 1 non-whitelisted port action(s)." "${output}"
            ! grep -q "Non-whitelisted ports have been blocked." "${output}"
        '; then
        record_pass "Root audit_ports 在 ufw deny 失败时会返回失败且不宣称端口已封禁"
    else
        record_fail "Root audit_ports 在 ufw deny 失败时会返回失败且不宣称端口已封禁"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$SECURITY_SH"
            _get_ssh_port() { echo 22; }
            _detect_firewall() { echo firewalld; }
            ss() {
                cat <<'\''EOF'\''
State Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))
LISTEN 0 128 0.0.0.0:5555 0.0.0.0:* users:(("mystery",pid=2,fd=4))
EOF
            }
            netstat() { return 1; }
            firewall-cmd() {
                if [[ "${1:-}" == "--reload" ]]; then
                    return 1
                fi
                return 0
            }
            if printf "y\n" | audit_ports >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "Failed to reload firewalld after blocking audited ports." "${output}"
            grep -q "Failed to block 1 non-whitelisted port action(s)." "${output}"
            ! grep -q "Non-whitelisted ports have been blocked." "${output}"
        '; then
        record_pass "Root audit_ports 在 firewalld reload 失败时会返回失败且不宣称端口已封禁"
    else
        record_fail "Root audit_ports 在 firewalld reload 失败时会返回失败且不宣称端口已封禁"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        LYNIS_LOG_DIR="${temp_root}/logs" \
        LYNIS_REPORT_FILE="${temp_root}/logs/lynis-report.txt" \
        LYNIS_DATA_FILE="${temp_root}/logs/lynis-report.dat" \
        SECURITY_STATE_DIR="${temp_root}/state" \
        SECURITY_STATE_FILE="${temp_root}/state/security.env" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            mkdir -p "${LYNIS_LOG_DIR}"
            source "$SECURITY_SH"
            harden_kernel() { return 0; }
            setup_firewall() { return 0; }
            harden_ssh() { return 0; }
            setup_fail2ban() { return 0; }
            setup_auto_updates() { return 0; }
            install_security_tools() { return 0; }
            audit_ports() { return 0; }
            _display_lynis_summary() { return 0; }
            _get_ssh_port() { echo 22; }
            _detect_firewall() { echo ufw; }
            lynis() { return 1; }
            if full_security_hardening >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "Lynis security audit failed with exit code 1." "${output}"
            grep -q "\\[FAIL\\] Security Audit" "${output}"
            ! grep -q "Security audit complete. Full report" "${output}"
        '; then
        record_pass "Root security 在 Lynis 审计失败时会返回失败并把 Security Audit 标记为失败"
    else
        record_fail "Root security 在 Lynis 审计失败时会返回失败并把 Security Audit 标记为失败"
    fi

    rm -rf "${temp_root}"
}

test_bridge_security_contracts() {
    info "=== AI Gateway Bridge Security Audit fail-fast 契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"
    local workdir="${temp_root}/bridge-security"
    mkdir -p "${workdir}"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/security.sh" "${workdir}/security.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${workdir}/common.sh"

    mkdir -p "${temp_root}/etc/ssh" "${temp_root}/root/.ssh"
    cat > "${temp_root}/etc/ssh/sshd_config" <<'EOF'
Port 22
PasswordAuthentication yes
PermitRootLogin yes
PubkeyAuthentication yes
EOF
    printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey root@test\n' > "${temp_root}/root/.ssh/authorized_keys"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        SECURITY_STATE_DIR="${temp_root}/state" \
        SECURITY_STATE_FILE="${temp_root}/state/security.env" \
        SSHD_CONFIG_PATH="${temp_root}/etc/ssh/sshd_config" \
        SSHD_BACKUP_DIR="${temp_root}/etc/ssh" \
        SSH_ADMIN_DIR="${temp_root}/root/.ssh" \
        SSH_AUTHORIZED_KEYS_FILE="${temp_root}/root/.ssh/authorized_keys" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            restart_marker="$(mktemp)"
            trap "rm -f \"${output}\" \"${restart_marker}\"" EXIT
            source "$SECURITY_SH"
            _generate_random_port() { echo 2222; }
            _get_ssh_port() { echo 22; }
            _save_state() { :; }
            sshd() { return 0; }
            sleep() { :; }
            nohup() { :; }
            systemctl() {
                if [[ "${1:-}" == "restart" ]]; then
                    echo restart >> "${restart_marker}"
                fi
                if [[ "${1:-}" == "is-active" ]]; then
                    return 0
                fi
                return 0
            }
            _detect_firewall() { echo ufw; }
            ufw() {
                if [[ "${1:-}" == "allow" && "${2:-}" == "2222/tcp" ]]; then
                    return 1
                fi
                return 0
            }
            if printf "2222\nn\n" | harden_ssh >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "Failed to open new SSH port 2222/tcp in ufw." "${output}"
            grep -q "Firewall update failed before SSH restart. Restoring backup to avoid lockout." "${output}"
            ! grep -q "SSH hardening complete." "${output}"
            [[ ! -s "${restart_marker}" ]]
        '; then
        record_pass "AI Gateway Bridge harden_ssh 在防火墙放行新端口失败时会终止且不会重启 sshd"
    else
        record_fail "AI Gateway Bridge harden_ssh 在防火墙放行新端口失败时会终止且不会重启 sshd"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        SECURITY_STATE_DIR="${temp_root}/state" \
        SECURITY_STATE_FILE="${temp_root}/state/security.env" \
        SSHD_CONFIG_PATH="${temp_root}/etc/ssh/sshd_config" \
        SSHD_BACKUP_DIR="${temp_root}/etc/ssh" \
        SSH_ADMIN_DIR="${temp_root}/root/.ssh" \
        SSH_AUTHORIZED_KEYS_FILE="${temp_root}/root/.ssh/authorized_keys" \
        bash -c '
            set -euo pipefail
            mkdir -p "$(dirname "${SSHD_CONFIG_PATH}")" "${SSH_ADMIN_DIR}" "${SSHD_BACKUP_DIR}" "${SECURITY_STATE_DIR}"
            cat > "${SSHD_CONFIG_PATH}" <<EOF
Port 22
PasswordAuthentication yes
PermitRootLogin yes
PubkeyAuthentication yes
EOF
            printf "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestKey root@test\n" > "${SSH_AUTHORIZED_KEYS_FILE}"
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$SECURITY_SH"
            sshd() { return 0; }
            _detect_firewall() { echo none; }
            systemctl() {
                if [[ "${1:-}" == "is-active" ]]; then
                    return 0
                fi
                if [[ "${1:-}" == "restart" ]]; then
                    return 1
                fi
                return 0
            }
            if printf "22\nn\n" | harden_ssh >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "Failed to restart sshd service." "${output}"
            grep -q "Failed to restart SSH daemon after applying hardened config. Restoring backup." "${output}"
            ! grep -q "SSH hardening complete." "${output}"
            grep -q "^PasswordAuthentication yes$" "${SSHD_CONFIG_PATH}"
            grep -q "^PermitRootLogin yes$" "${SSHD_CONFIG_PATH}"
            test -f "${SECURITY_STATE_FILE}"
        '; then
        record_pass "AI Gateway Bridge harden_ssh 在重启失败但服务仍 active 时会返回失败并恢复备份"
    else
        record_fail "AI Gateway Bridge harden_ssh 在重启失败但服务仍 active 时会返回失败并恢复备份"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        SECURITY_STATE_DIR="${temp_root}/state" \
        SECURITY_STATE_FILE="${temp_root}/state/security.env" \
        SSHD_CONFIG_PATH="${temp_root}/etc/ssh/sshd_config" \
        SSHD_BACKUP_DIR="${temp_root}/etc/ssh" \
        SSH_ADMIN_DIR="${temp_root}/root/.ssh" \
        SSH_AUTHORIZED_KEYS_FILE="${temp_root}/root/.ssh/authorized_keys" \
        bash -c '
            set -euo pipefail
            revert_script="/tmp/ssh-revert-safety.sh"
            trap "rm -f \"${revert_script}\"" EXIT
            rm -f "${revert_script}"
            source "$SECURITY_SH"
            _generate_random_port() { echo 2222; }
            _get_ssh_port() { echo 22; }
            _save_state() { :; }
            sshd() { return 0; }
            sleep() { :; }
            nohup() { :; }
            _detect_firewall() { echo none; }
            systemctl() { return 0; }
            printf "2222\nn\n" | harden_ssh >/dev/null 2>&1
            test -f "${revert_script}"
            grep -Fq "Failed to restore SSH config backup." "${revert_script}"
            grep -Fq "Failed to restart SSH daemon after revert. Manual recovery required." "${revert_script}"
            ! grep -Fq "systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true" "${revert_script}"
        '; then
        record_pass "AI Gateway Bridge harden_ssh 生成的 safety revert 脚本不再吞掉 SSH 恢复失败"
    else
        record_fail "AI Gateway Bridge harden_ssh 生成的 safety revert 脚本不再吞掉 SSH 恢复失败"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$SECURITY_SH"
            _get_ssh_port() { echo 2222; }
            _detect_firewall() { echo ufw; }
            _save_state() { :; }
            ufw() {
                if [[ "${1:-}" == "--force" && "${2:-}" == "reset" ]]; then
                    return 1
                fi
                return 0
            }
            if setup_firewall >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "Failed to reset ufw to defaults." "${output}"
            ! grep -q "Firewall setup complete." "${output}"
        '; then
        record_pass "AI Gateway Bridge setup_firewall 在 ufw reset 失败时会返回失败且不宣称已完成"
    else
        record_fail "AI Gateway Bridge setup_firewall 在 ufw reset 失败时会返回失败且不宣称已完成"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$SECURITY_SH"
            _get_ssh_port() { echo 2222; }
            _detect_firewall() { echo firewalld; }
            _save_state() { :; }
            systemctl() { return 0; }
            firewall-cmd() {
                if [[ "${1:-}" == "--set-default-zone=public" ]]; then
                    return 1
                fi
                return 0
            }
            if setup_firewall >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "Failed to set firewalld default zone to public." "${output}"
            ! grep -q "Firewall setup complete." "${output}"
        '; then
        record_pass "AI Gateway Bridge setup_firewall 在 firewalld 关键步骤失败时会返回失败且不宣称已完成"
    else
        record_fail "AI Gateway Bridge setup_firewall 在 firewalld 关键步骤失败时会返回失败且不宣称已完成"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        FAIL2BAN_FILTER_DIR="${temp_root}/fail2ban/filter.d" \
        FAIL2BAN_JAIL_FILE="${temp_root}/fail2ban/jail.local" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$SECURITY_SH"
            _get_ssh_port() { echo 22; }
            fail2ban-client() { return 0; }
            systemctl() {
                if [[ "${1:-}" == "restart" ]]; then
                    return 1
                fi
                return 0
            }
            sleep() { :; }
            if setup_fail2ban >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "Failed to restart fail2ban service." "${output}"
            ! grep -q "fail2ban setup complete." "${output}"
        '; then
        record_pass "AI Gateway Bridge setup_fail2ban 在服务重启失败时会返回失败且不宣称已完成"
    else
        record_fail "AI Gateway Bridge setup_fail2ban 在服务重启失败时会返回失败且不宣称已完成"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        AUTO_UPGRADES_CONFIG_FILE="${temp_root}/apt/50unattended-upgrades" \
        AUTO_UPGRADES_PERIODIC_FILE="${temp_root}/apt/20auto-upgrades" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$SECURITY_SH"
            apt-get() { return 0; }
            lsb_release() {
                if [[ "${1:-}" == "-is" ]]; then
                    echo Ubuntu
                else
                    echo noble
                fi
            }
            unattended-upgrades() {
                echo "dry run failed" >&2
                return 1
            }
            if setup_auto_updates >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "unattended-upgrades dry run failed." "${output}"
            ! grep -q "Automatic security updates configured." "${output}"
        '; then
        record_pass "AI Gateway Bridge setup_auto_updates 在 unattended-upgrades 验证失败时会返回失败且不宣称已完成"
    else
        record_fail "AI Gateway Bridge setup_auto_updates 在 unattended-upgrades 验证失败时会返回失败且不宣称已完成"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$SECURITY_SH"
            _install_rkhunter() {
                echo "RK_FAIL"
                return 1
            }
            _install_lynis() {
                echo "LY_SHOULD_NOT_RUN"
                return 0
            }
            if install_security_tools >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "RK_FAIL" "${output}"
            ! grep -q "LY_SHOULD_NOT_RUN" "${output}"
            ! grep -q "Security tools installation complete." "${output}"
        '; then
        record_pass "AI Gateway Bridge install_security_tools 在子安装器失败时会返回失败且不宣称已完成"
    else
        record_fail "AI Gateway Bridge install_security_tools 在子安装器失败时会返回失败且不宣称已完成"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        RKHUNTER_CRON_FILE="${temp_root}/cron/rkhunter-scan" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$SECURITY_SH"
            rkhunter() {
                case "${1:-}" in
                    --update|--propupd)
                        return 0
                        ;;
                    --check)
                        echo "scan failed" >&2
                        return 1
                        ;;
                esac
                return 0
            }
            if _install_rkhunter >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "Initial rkhunter scan failed." "${output}"
            ! grep -q "rkhunter installation and configuration complete." "${output}"
            ! test -f "${RKHUNTER_CRON_FILE}"
        '; then
        record_pass "AI Gateway Bridge _install_rkhunter 在初始扫描失败时会返回失败且不宣称已完成"
    else
        record_fail "AI Gateway Bridge _install_rkhunter 在初始扫描失败时会返回失败且不宣称已完成"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        RKHUNTER_CRON_FILE="${temp_root}/cron/rkhunter-scan" \
        bash -c '
            set -euo pipefail
            source "$SECURITY_SH"
            rkhunter() {
                case "${1:-}" in
                    --update|--propupd|--check)
                        return 0
                        ;;
                esac
                return 0
            }
            _install_rkhunter >/dev/null 2>&1
            test -f "${RKHUNTER_CRON_FILE}"
            grep -Fq "RKHUNTER_BIN=\"\${RKHUNTER_BIN:-/usr/bin/rkhunter}\"" "${RKHUNTER_CRON_FILE}"
            grep -Fq "RKHUNTER_LOG_DIR=\"\${RKHUNTER_LOG_DIR:-/var/log}\"" "${RKHUNTER_CRON_FILE}"
            grep -Fq "if ! \"\${RKHUNTER_BIN}\" --check --skip-keypress --nocolors --report-warnings-only >> \"\${LOG_FILE}\" 2>&1; then" "${RKHUNTER_CRON_FILE}"
            grep -Fq "[rkhunter-cron] scan failed." "${RKHUNTER_CRON_FILE}"
            ! grep -Fq "/usr/bin/rkhunter --update --nocolors 2>/dev/null || true" "${RKHUNTER_CRON_FILE}"
            ! grep -Fq "/usr/bin/rkhunter --check --skip-keypress --nocolors --report-warnings-only > \"\${LOG_FILE}\" 2>&1 || true" "${RKHUNTER_CRON_FILE}"
        '; then
        record_pass "AI Gateway Bridge _install_rkhunter 生成的 weekly cron 不再吞掉扫描失败"
    else
        record_fail "AI Gateway Bridge _install_rkhunter 生成的 weekly cron 不再吞掉扫描失败"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        LYNIS_LOG_DIR="${temp_root}/lynis" \
        LYNIS_REPORT_FILE="${temp_root}/lynis/lynis-report.txt" \
        LYNIS_DATA_FILE="${temp_root}/lynis/lynis-report.dat" \
        LYNIS_CRON_FILE="/proc/1/bifrost-test/lynis-audit" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$SECURITY_SH"
            lynis() {
                echo "Hardening index : 80"
                printf "hardening_index=80\n" > "${LYNIS_DATA_FILE}"
                return 0
            }
            _display_lynis_summary() { :; }
            if _install_lynis >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "Failed to create monthly Lynis cron directory for ${LYNIS_CRON_FILE}." "${output}"
            ! grep -q "Lynis installation and configuration complete." "${output}"
        '; then
        record_pass "AI Gateway Bridge _install_lynis 在月度 cron 物化失败时会返回失败且不宣称已完成"
    else
        record_fail "AI Gateway Bridge _install_lynis 在月度 cron 物化失败时会返回失败且不宣称已完成"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$SECURITY_SH"
            _get_ssh_port() { echo 22; }
            _detect_firewall() { echo ufw; }
            ss() {
                cat <<'\''EOF'\''
State Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))
LISTEN 0 128 0.0.0.0:5555 0.0.0.0:* users:(("mystery",pid=2,fd=4))
EOF
            }
            netstat() { return 1; }
            ufw() {
                if [[ "${1:-}" == "deny" && "${2:-}" == "5555/tcp" ]]; then
                    return 1
                fi
                return 0
            }
            if printf "y\n" | audit_ports >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "Failed to block port 5555/tcp via ufw." "${output}"
            grep -q "Failed to block 1 non-whitelisted port action(s)." "${output}"
            ! grep -q "Non-whitelisted ports have been blocked." "${output}"
        '; then
        record_pass "AI Gateway Bridge audit_ports 在 ufw deny 失败时会返回失败且不宣称端口已封禁"
    else
        record_fail "AI Gateway Bridge audit_ports 在 ufw deny 失败时会返回失败且不宣称端口已封禁"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$SECURITY_SH"
            _get_ssh_port() { echo 22; }
            _detect_firewall() { echo firewalld; }
            ss() {
                cat <<'\''EOF'\''
State Recv-Q Send-Q Local Address:Port Peer Address:Port Process
LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))
LISTEN 0 128 0.0.0.0:5555 0.0.0.0:* users:(("mystery",pid=2,fd=4))
EOF
            }
            netstat() { return 1; }
            firewall-cmd() {
                if [[ "${1:-}" == "--reload" ]]; then
                    return 1
                fi
                return 0
            }
            if printf "y\n" | audit_ports >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "Failed to reload firewalld after blocking audited ports." "${output}"
            grep -q "Failed to block 1 non-whitelisted port action(s)." "${output}"
            ! grep -q "Non-whitelisted ports have been blocked." "${output}"
        '; then
        record_pass "AI Gateway Bridge audit_ports 在 firewalld reload 失败时会返回失败且不宣称端口已封禁"
    else
        record_fail "AI Gateway Bridge audit_ports 在 firewalld reload 失败时会返回失败且不宣称端口已封禁"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        SECURITY_SH="${workdir}/security.sh" \
        LYNIS_LOG_DIR="${temp_root}/logs" \
        LYNIS_REPORT_FILE="${temp_root}/logs/lynis-report.txt" \
        LYNIS_DATA_FILE="${temp_root}/logs/lynis-report.dat" \
        SECURITY_STATE_DIR="${temp_root}/state" \
        SECURITY_STATE_FILE="${temp_root}/state/security.env" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            mkdir -p "${LYNIS_LOG_DIR}"
            source "$SECURITY_SH"
            harden_kernel() { return 0; }
            setup_firewall() { return 0; }
            harden_ssh() { return 0; }
            setup_fail2ban() { return 0; }
            setup_auto_updates() { return 0; }
            install_security_tools() { return 0; }
            audit_ports() { return 0; }
            _display_lynis_summary() { return 0; }
            _get_ssh_port() { echo 22; }
            _detect_firewall() { echo ufw; }
            lynis() { return 1; }
            if full_security_hardening >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "Lynis security audit failed with exit code 1." "${output}"
            grep -q "\\[FAIL\\] Security Audit" "${output}"
            ! grep -q "Security audit complete. Full report" "${output}"
        '; then
        record_pass "AI Gateway Bridge security 在 Lynis 审计失败时会返回失败并把 Security Audit 标记为失败"
    else
        record_fail "AI Gateway Bridge security 在 Lynis 审计失败时会返回失败并把 Security Audit 标记为失败"
    fi

    rm -rf "${temp_root}"
}

test_multi_server_contracts() {
    info "=== Multi-server 与 Mihomo 路由同步契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"

    local missing_workdir="${temp_root}/root-multi-missing"
    mkdir -p "${missing_workdir}"
    cp "${SCRIPT_DIR}/scripts/multi-server.sh" "${missing_workdir}/multi-server.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${missing_workdir}/common.sh"
    sed -i "s|^SERVER_REGISTRY_DIR=.*$|SERVER_REGISTRY_DIR=\"${temp_root}/root-registry\"|" "${missing_workdir}/multi-server.sh"
    sed -i 's|^SERVER_REGISTRY_FILE=.*$|SERVER_REGISTRY_FILE="${SERVER_REGISTRY_DIR}/servers.conf"|' "${missing_workdir}/multi-server.sh"
    sed -i "s|^MIHOMO_CONFIG=.*$|MIHOMO_CONFIG=\"${temp_root}/missing-mihomo.yaml\"|" "${missing_workdir}/multi-server.sh"
    sed -i "s|^MIHOMO_FALLBACK_CONFIG=.*$|MIHOMO_FALLBACK_CONFIG=\"${temp_root}/missing-clash.yaml\"|" "${missing_workdir}/multi-server.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        MULTI_SERVER_SH="${missing_workdir}/multi-server.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$MULTI_SERVER_SH"
            confirm_action() { return 0; }
            _test_server_connectivity() { echo "12"; return 0; }
            if printf "%s\n" \
                "tokyo-01" \
                "1.2.3.4" \
                "443" \
                "123e4567-e89b-12d3-a456-426614174000" \
                "abcdefghijklmnopqrstuvwxyz123456" \
                "www.microsoft.com" \
                "abcdef12" \
                | add_server_b >"${output_file}" 2>&1; then
                exit 1
            fi
            ! grep -q "^tokyo-01|" "${SERVER_REGISTRY_FILE}"
            ! grep -q "added to the proxy pool" "${output_file}"
        '; then
        record_pass "Root multi-server 在缺失 Mihomo 配置时会回滚注册表且不宣称已入池"
    else
        record_fail "Root multi-server 在缺失 Mihomo 配置时会回滚注册表且不宣称已入池"
    fi

    local cleanup_workdir="${temp_root}/root-multi-cleanup"
    local cleanup_registry_dir="${temp_root}/root-cleanup-registry"
    local cleanup_config="${temp_root}/root-multi-config.yaml"
    mkdir -p "${cleanup_workdir}" "${cleanup_registry_dir}"
    cp "${SCRIPT_DIR}/scripts/multi-server.sh" "${cleanup_workdir}/multi-server.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${cleanup_workdir}/common.sh"
    sed -i "s|^SERVER_REGISTRY_DIR=.*$|SERVER_REGISTRY_DIR=\"${cleanup_registry_dir}\"|" "${cleanup_workdir}/multi-server.sh"
    sed -i 's|^SERVER_REGISTRY_FILE=.*$|SERVER_REGISTRY_FILE="${SERVER_REGISTRY_DIR}/servers.conf"|' "${cleanup_workdir}/multi-server.sh"
    sed -i "s|^MIHOMO_CONFIG=.*$|MIHOMO_CONFIG=\"${cleanup_config}\"|" "${cleanup_workdir}/multi-server.sh"
    sed -i "s|^MIHOMO_FALLBACK_CONFIG=.*$|MIHOMO_FALLBACK_CONFIG=\"${temp_root}/unused-clash.yaml\"|" "${cleanup_workdir}/multi-server.sh"
    cat > "${cleanup_config}" <<'EOF'
mixed-port: 7890
# >>> AI-GATEWAY-BRIDGE MANAGED PROXIES - DO NOT EDIT >>>
proxies:
  - name: "tokyo-01"
proxy-groups:
  - name: "ServerB-Pool"
    type: url-test
    proxies: ["tokyo-01"]
# <<< AI-GATEWAY-BRIDGE MANAGED PROXIES <<<
EOF

    if BIFROST_TRACE_COMMON_LOAD=0 \
        MULTI_SERVER_SH="${cleanup_workdir}/multi-server.sh" \
        bash -c '
            set -euo pipefail
            source "$MULTI_SERVER_SH"
            _ensure_registry
            if ! _update_mihomo_config "remove" "tokyo-01"; then
                exit 1
            fi
            ! grep -q "AI-GATEWAY-BRIDGE MANAGED PROXIES" "${MIHOMO_CONFIG}"
            ! grep -q "ServerB-Pool" "${MIHOMO_CONFIG}"
        '; then
        record_pass "Root multi-server 在注册表清空后会移除 Mihomo managed proxy pool"
    else
        record_fail "Root multi-server 在注册表清空后会移除 Mihomo managed proxy pool"
    fi

    rm -rf "${temp_root}"
}

test_bridge_multi_server_contracts() {
    info "=== AI Gateway Bridge Multi-server 与 Mihomo 路由同步契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"

    local missing_workdir="${temp_root}/bridge-multi-missing"
    mkdir -p "${missing_workdir}"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/multi-server.sh" "${missing_workdir}/multi-server.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${missing_workdir}/common.sh"
    sed -i "s|^SERVER_REGISTRY_DIR=.*$|SERVER_REGISTRY_DIR=\"${temp_root}/bridge-registry\"|" "${missing_workdir}/multi-server.sh"
    sed -i 's|^SERVER_REGISTRY_FILE=.*$|SERVER_REGISTRY_FILE="${SERVER_REGISTRY_DIR}/servers.conf"|' "${missing_workdir}/multi-server.sh"
    sed -i "s|^MIHOMO_CONFIG=.*$|MIHOMO_CONFIG=\"${temp_root}/bridge-missing-mihomo.yaml\"|" "${missing_workdir}/multi-server.sh"
    sed -i "s|^MIHOMO_FALLBACK_CONFIG=.*$|MIHOMO_FALLBACK_CONFIG=\"${temp_root}/bridge-missing-clash.yaml\"|" "${missing_workdir}/multi-server.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        MULTI_SERVER_SH="${missing_workdir}/multi-server.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$MULTI_SERVER_SH"
            confirm_action() { return 0; }
            _test_server_connectivity() { echo "12"; return 0; }
            if printf "%s\n" \
                "tokyo-01" \
                "1.2.3.4" \
                "443" \
                "123e4567-e89b-12d3-a456-426614174000" \
                "abcdefghijklmnopqrstuvwxyz123456" \
                "www.microsoft.com" \
                "abcdef12" \
                | add_server_b >"${output_file}" 2>&1; then
                exit 1
            fi
            ! grep -q "^tokyo-01|" "${SERVER_REGISTRY_FILE}"
            ! grep -q "added to the proxy pool" "${output_file}"
        '; then
        record_pass "AI Gateway Bridge multi-server 在缺失 Mihomo 配置时会回滚注册表且不宣称已入池"
    else
        record_fail "AI Gateway Bridge multi-server 在缺失 Mihomo 配置时会回滚注册表且不宣称已入池"
    fi

    local cleanup_workdir="${temp_root}/bridge-multi-cleanup"
    local cleanup_registry_dir="${temp_root}/bridge-cleanup-registry"
    local cleanup_config="${temp_root}/bridge-multi-config.yaml"
    mkdir -p "${cleanup_workdir}" "${cleanup_registry_dir}"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/multi-server.sh" "${cleanup_workdir}/multi-server.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${cleanup_workdir}/common.sh"
    sed -i "s|^SERVER_REGISTRY_DIR=.*$|SERVER_REGISTRY_DIR=\"${cleanup_registry_dir}\"|" "${cleanup_workdir}/multi-server.sh"
    sed -i 's|^SERVER_REGISTRY_FILE=.*$|SERVER_REGISTRY_FILE="${SERVER_REGISTRY_DIR}/servers.conf"|' "${cleanup_workdir}/multi-server.sh"
    sed -i "s|^MIHOMO_CONFIG=.*$|MIHOMO_CONFIG=\"${cleanup_config}\"|" "${cleanup_workdir}/multi-server.sh"
    sed -i "s|^MIHOMO_FALLBACK_CONFIG=.*$|MIHOMO_FALLBACK_CONFIG=\"${temp_root}/bridge-unused-clash.yaml\"|" "${cleanup_workdir}/multi-server.sh"
    cat > "${cleanup_config}" <<'EOF'
mixed-port: 7890
# >>> AI-GATEWAY-BRIDGE MANAGED PROXIES - DO NOT EDIT >>>
proxies:
  - name: "tokyo-01"
proxy-groups:
  - name: "ServerB-Pool"
    type: url-test
    proxies: ["tokyo-01"]
# <<< AI-GATEWAY-BRIDGE MANAGED PROXIES <<<
EOF

    if BIFROST_TRACE_COMMON_LOAD=0 \
        MULTI_SERVER_SH="${cleanup_workdir}/multi-server.sh" \
        bash -c '
            set -euo pipefail
            source "$MULTI_SERVER_SH"
            _ensure_registry
            if ! _update_mihomo_config "remove" "tokyo-01"; then
                exit 1
            fi
            ! grep -q "AI-GATEWAY-BRIDGE MANAGED PROXIES" "${MIHOMO_CONFIG}"
            ! grep -q "ServerB-Pool" "${MIHOMO_CONFIG}"
        '; then
        record_pass "AI Gateway Bridge multi-server 在注册表清空后会移除 Mihomo managed proxy pool"
    else
        record_fail "AI Gateway Bridge multi-server 在注册表清空后会移除 Mihomo managed proxy pool"
    fi

    rm -rf "${temp_root}"
}

test_user_management_contracts() {
    info "=== User-management 交付原子性契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"

    local xray_fail_workdir="${temp_root}/root-user-xray-fail"
    mkdir -p "${xray_fail_workdir}"
    cp "${SCRIPT_DIR}/scripts/user-management.sh" "${xray_fail_workdir}/user-management.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${xray_fail_workdir}/common.sh"
    sed -i "s|^USER_REGISTRY_DIR=.*$|USER_REGISTRY_DIR=\"${temp_root}/root-users\"|" "${xray_fail_workdir}/user-management.sh"
    sed -i 's|^USER_REGISTRY_FILE=.*$|USER_REGISTRY_FILE="${USER_REGISTRY_DIR}/registry.conf"|' "${xray_fail_workdir}/user-management.sh"
    sed -i 's|^USER_GUIDES_DIR=.*$|USER_GUIDES_DIR="${USER_REGISTRY_DIR}/guides"|' "${xray_fail_workdir}/user-management.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        USER_MGMT_SH="${xray_fail_workdir}/user-management.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$USER_MGMT_SH"
            _add_xray_user() { return 1; }
            _create_api_token() { echo "token-should-not-be-created|1"; return 0; }
            if printf "\n" | create_user "alice" >"${output_file}" 2>&1; then
                exit 1
            fi
            ! grep -q "^alice|" "${USER_REGISTRY_FILE}"
            ! grep -q "Created Successfully" "${output_file}"
            ! grep -q "Registering user" "${output_file}"
        '; then
        record_pass "Root user-management 在 Xray 失败时不会登记本地用户或打印成功"
    else
        record_fail "Root user-management 在 Xray 失败时不会登记本地用户或打印成功"
    fi

    local api_fail_workdir="${temp_root}/root-user-api-fail"
    mkdir -p "${api_fail_workdir}"
    cp "${SCRIPT_DIR}/scripts/user-management.sh" "${api_fail_workdir}/user-management.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${api_fail_workdir}/common.sh"
    sed -i "s|^USER_REGISTRY_DIR=.*$|USER_REGISTRY_DIR=\"${temp_root}/root-users-api\"|" "${api_fail_workdir}/user-management.sh"
    sed -i 's|^USER_REGISTRY_FILE=.*$|USER_REGISTRY_FILE="${USER_REGISTRY_DIR}/registry.conf"|' "${api_fail_workdir}/user-management.sh"
    sed -i 's|^USER_GUIDES_DIR=.*$|USER_GUIDES_DIR="${USER_REGISTRY_DIR}/guides"|' "${api_fail_workdir}/user-management.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        USER_MGMT_SH="${api_fail_workdir}/user-management.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            rollback_flag="$(mktemp)"
            trap "rm -f \"${output_file}\" \"${rollback_flag}\"" EXIT
            source "$USER_MGMT_SH"
            _add_xray_user() { return 0; }
            _create_api_token() { return 1; }
            _remove_xray_user() { printf "rolled-back\n" > "${rollback_flag}"; return 0; }
            if printf "\n" | create_user "alice" >"${output_file}" 2>&1; then
                exit 1
            fi
            grep -q "rolled-back" "${rollback_flag}"
            ! grep -q "^alice|" "${USER_REGISTRY_FILE}"
            ! grep -q "Created Successfully" "${output_file}"
            ! grep -q "Registering user" "${output_file}"
        '; then
        record_pass "Root user-management 在 API token 失败时会回滚 Xray 并拒绝落本地状态"
    else
        record_fail "Root user-management 在 API token 失败时会回滚 Xray 并拒绝落本地状态"
    fi

    local disable_xray_workdir="${temp_root}/root-user-disable-xray"
    mkdir -p "${disable_xray_workdir}"
    cp "${SCRIPT_DIR}/scripts/user-management.sh" "${disable_xray_workdir}/user-management.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${disable_xray_workdir}/common.sh"
    sed -i "s|^USER_REGISTRY_DIR=.*$|USER_REGISTRY_DIR=\"${temp_root}/root-disable-users\"|" "${disable_xray_workdir}/user-management.sh"
    sed -i 's|^USER_REGISTRY_FILE=.*$|USER_REGISTRY_FILE="${USER_REGISTRY_DIR}/registry.conf"|' "${disable_xray_workdir}/user-management.sh"
    sed -i 's|^USER_GUIDES_DIR=.*$|USER_GUIDES_DIR="${USER_REGISTRY_DIR}/guides"|' "${disable_xray_workdir}/user-management.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        USER_MGMT_SH="${disable_xray_workdir}/user-management.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$USER_MGMT_SH"
            _ensure_user_dirs
            printf "alice|uuid-1|alice@example.com|active|123|2026-03-27T00:00:00Z|\n" >> "${USER_REGISTRY_FILE}"
            confirm_action() { return 0; }
            _remove_xray_user() { return 1; }
            _disable_api_token() { return 0; }
            if disable_user "alice" >"${output_file}" 2>&1; then
                exit 1
            fi
            grep -q "^alice|uuid-1|alice@example.com|active|123|" "${USER_REGISTRY_FILE}"
            ! grep -q "has been disabled" "${output_file}"
        '; then
        record_pass "Root user-management 在撤销 Xray 失败时不会把本地状态写成 disabled"
    else
        record_fail "Root user-management 在撤销 Xray 失败时不会把本地状态写成 disabled"
    fi

    local disable_wg_workdir="${temp_root}/root-user-disable-wg"
    mkdir -p "${disable_wg_workdir}"
    cp "${SCRIPT_DIR}/scripts/user-management.sh" "${disable_wg_workdir}/user-management.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${disable_wg_workdir}/common.sh"
    cat > "${disable_wg_workdir}/vpn.sh" <<'EOF'
#!/usr/bin/env bash
revoke_vpn_user() {
    printf "wg-called\n" > "${WG_FLAG}"
    return 1
}
EOF
    sed -i "s|^USER_REGISTRY_DIR=.*$|USER_REGISTRY_DIR=\"${temp_root}/root-disable-wg-users\"|" "${disable_wg_workdir}/user-management.sh"
    sed -i 's|^USER_REGISTRY_FILE=.*$|USER_REGISTRY_FILE="${USER_REGISTRY_DIR}/registry.conf"|' "${disable_wg_workdir}/user-management.sh"
    sed -i 's|^USER_GUIDES_DIR=.*$|USER_GUIDES_DIR="${USER_REGISTRY_DIR}/guides"|' "${disable_wg_workdir}/user-management.sh"
    sed -i "s|local vpn_users_dir=\"/etc/bifrost/vpn/users\"|local vpn_users_dir=\"${temp_root}/root-vpn-users\"|" "${disable_wg_workdir}/user-management.sh"
    mkdir -p "${temp_root}/root-vpn-users/alice"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        USER_MGMT_SH="${disable_wg_workdir}/user-management.sh" \
        WG_FLAG="${temp_root}/root-wg-flag" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$USER_MGMT_SH"
            _ensure_user_dirs
            printf "alice|uuid-1|alice@example.com|active|none|2026-03-27T00:00:00Z|\n" >> "${USER_REGISTRY_FILE}"
            confirm_action() { return 0; }
            _remove_xray_user() { return 0; }
            if disable_user "alice" >"${output_file}" 2>&1; then
                exit 1
            fi
            grep -q "wg-called" "${WG_FLAG}"
            grep -q "^alice|uuid-1|alice@example.com|active|none|" "${USER_REGISTRY_FILE}"
            ! grep -q "has been disabled" "${output_file}"
        '; then
        record_pass "Root user-management 在 WireGuard 撤销失败时不会写 disabled 且会实际触发撤销路径"
    else
        record_fail "Root user-management 在 WireGuard 撤销失败时不会写 disabled 且会实际触发撤销路径"
    fi

    rm -rf "${temp_root}"
}

test_bridge_user_management_contracts() {
    info "=== AI Gateway Bridge User-management 交付原子性契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"

    local xray_fail_workdir="${temp_root}/bridge-user-xray-fail"
    mkdir -p "${xray_fail_workdir}"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/user-management.sh" "${xray_fail_workdir}/user-management.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${xray_fail_workdir}/common.sh"
    sed -i "s|^USER_REGISTRY_DIR=.*$|USER_REGISTRY_DIR=\"${temp_root}/bridge-users\"|" "${xray_fail_workdir}/user-management.sh"
    sed -i 's|^USER_REGISTRY_FILE=.*$|USER_REGISTRY_FILE="${USER_REGISTRY_DIR}/registry.conf"|' "${xray_fail_workdir}/user-management.sh"
    sed -i 's|^USER_GUIDES_DIR=.*$|USER_GUIDES_DIR="${USER_REGISTRY_DIR}/guides"|' "${xray_fail_workdir}/user-management.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        USER_MGMT_SH="${xray_fail_workdir}/user-management.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$USER_MGMT_SH"
            _add_xray_user() { return 1; }
            _create_api_token() { echo "token-should-not-be-created|1"; return 0; }
            if printf "\n" | create_user "alice" >"${output_file}" 2>&1; then
                exit 1
            fi
            ! grep -q "^alice|" "${USER_REGISTRY_FILE}"
            ! grep -q "Created Successfully" "${output_file}"
            ! grep -q "Registering user" "${output_file}"
        '; then
        record_pass "AI Gateway Bridge user-management 在 Xray 失败时不会登记本地用户或打印成功"
    else
        record_fail "AI Gateway Bridge user-management 在 Xray 失败时不会登记本地用户或打印成功"
    fi

    local api_fail_workdir="${temp_root}/bridge-user-api-fail"
    mkdir -p "${api_fail_workdir}"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/user-management.sh" "${api_fail_workdir}/user-management.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${api_fail_workdir}/common.sh"
    sed -i "s|^USER_REGISTRY_DIR=.*$|USER_REGISTRY_DIR=\"${temp_root}/bridge-users-api\"|" "${api_fail_workdir}/user-management.sh"
    sed -i 's|^USER_REGISTRY_FILE=.*$|USER_REGISTRY_FILE="${USER_REGISTRY_DIR}/registry.conf"|' "${api_fail_workdir}/user-management.sh"
    sed -i 's|^USER_GUIDES_DIR=.*$|USER_GUIDES_DIR="${USER_REGISTRY_DIR}/guides"|' "${api_fail_workdir}/user-management.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        USER_MGMT_SH="${api_fail_workdir}/user-management.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            rollback_flag="$(mktemp)"
            trap "rm -f \"${output_file}\" \"${rollback_flag}\"" EXIT
            source "$USER_MGMT_SH"
            _add_xray_user() { return 0; }
            _create_api_token() { return 1; }
            _remove_xray_user() { printf "rolled-back\n" > "${rollback_flag}"; return 0; }
            if printf "\n" | create_user "alice" >"${output_file}" 2>&1; then
                exit 1
            fi
            grep -q "rolled-back" "${rollback_flag}"
            ! grep -q "^alice|" "${USER_REGISTRY_FILE}"
            ! grep -q "Created Successfully" "${output_file}"
            ! grep -q "Registering user" "${output_file}"
        '; then
        record_pass "AI Gateway Bridge user-management 在 API token 失败时会回滚 Xray 并拒绝落本地状态"
    else
        record_fail "AI Gateway Bridge user-management 在 API token 失败时会回滚 Xray 并拒绝落本地状态"
    fi

    local disable_xray_workdir="${temp_root}/bridge-user-disable-xray"
    mkdir -p "${disable_xray_workdir}"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/user-management.sh" "${disable_xray_workdir}/user-management.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${disable_xray_workdir}/common.sh"
    sed -i "s|^USER_REGISTRY_DIR=.*$|USER_REGISTRY_DIR=\"${temp_root}/bridge-disable-users\"|" "${disable_xray_workdir}/user-management.sh"
    sed -i 's|^USER_REGISTRY_FILE=.*$|USER_REGISTRY_FILE="${USER_REGISTRY_DIR}/registry.conf"|' "${disable_xray_workdir}/user-management.sh"
    sed -i 's|^USER_GUIDES_DIR=.*$|USER_GUIDES_DIR="${USER_REGISTRY_DIR}/guides"|' "${disable_xray_workdir}/user-management.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        USER_MGMT_SH="${disable_xray_workdir}/user-management.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$USER_MGMT_SH"
            _ensure_user_dirs
            printf "alice|uuid-1|alice@example.com|active|123|2026-03-27T00:00:00Z|\n" >> "${USER_REGISTRY_FILE}"
            confirm_action() { return 0; }
            _remove_xray_user() { return 1; }
            _disable_api_token() { return 0; }
            if disable_user "alice" >"${output_file}" 2>&1; then
                exit 1
            fi
            grep -q "^alice|uuid-1|alice@example.com|active|123|" "${USER_REGISTRY_FILE}"
            ! grep -q "has been disabled" "${output_file}"
        '; then
        record_pass "AI Gateway Bridge user-management 在撤销 Xray 失败时不会把本地状态写成 disabled"
    else
        record_fail "AI Gateway Bridge user-management 在撤销 Xray 失败时不会把本地状态写成 disabled"
    fi

    local disable_wg_workdir="${temp_root}/bridge-user-disable-wg"
    mkdir -p "${disable_wg_workdir}"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/user-management.sh" "${disable_wg_workdir}/user-management.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${disable_wg_workdir}/common.sh"
    cat > "${disable_wg_workdir}/vpn.sh" <<'EOF'
#!/usr/bin/env bash
revoke_vpn_user() {
    printf "wg-called\n" > "${WG_FLAG}"
    return 1
}
EOF
    sed -i "s|^USER_REGISTRY_DIR=.*$|USER_REGISTRY_DIR=\"${temp_root}/bridge-disable-wg-users\"|" "${disable_wg_workdir}/user-management.sh"
    sed -i 's|^USER_REGISTRY_FILE=.*$|USER_REGISTRY_FILE="${USER_REGISTRY_DIR}/registry.conf"|' "${disable_wg_workdir}/user-management.sh"
    sed -i 's|^USER_GUIDES_DIR=.*$|USER_GUIDES_DIR="${USER_REGISTRY_DIR}/guides"|' "${disable_wg_workdir}/user-management.sh"
    sed -i "s|local vpn_users_dir=\"/etc/ai-gateway-bridge/vpn/users\"|local vpn_users_dir=\"${temp_root}/bridge-vpn-users\"|" "${disable_wg_workdir}/user-management.sh"
    mkdir -p "${temp_root}/bridge-vpn-users/alice"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        USER_MGMT_SH="${disable_wg_workdir}/user-management.sh" \
        WG_FLAG="${temp_root}/bridge-wg-flag" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$USER_MGMT_SH"
            _ensure_user_dirs
            printf "alice|uuid-1|alice@example.com|active|none|2026-03-27T00:00:00Z|\n" >> "${USER_REGISTRY_FILE}"
            confirm_action() { return 0; }
            _remove_xray_user() { return 0; }
            if disable_user "alice" >"${output_file}" 2>&1; then
                exit 1
            fi
            grep -q "wg-called" "${WG_FLAG}"
            grep -q "^alice|uuid-1|alice@example.com|active|none|" "${USER_REGISTRY_FILE}"
            ! grep -q "has been disabled" "${output_file}"
        '; then
        record_pass "AI Gateway Bridge user-management 在 WireGuard 撤销失败时不会写 disabled 且会实际触发撤销路径"
    else
        record_fail "AI Gateway Bridge user-management 在 WireGuard 撤销失败时不会写 disabled 且会实际触发撤销路径"
    fi

    rm -rf "${temp_root}"
}

test_whitelist_contracts() {
    info "=== Whitelist 与 Xray 路由原子性契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"

    local add_workdir="${temp_root}/root-whitelist-add"
    mkdir -p "${add_workdir}"
    cp "${SCRIPT_DIR}/scripts/whitelist.sh" "${add_workdir}/whitelist.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${add_workdir}/common.sh"
    mkdir -p "${temp_root}/root-whitelist-configs"
    cat > "${temp_root}/root-whitelist-configs/ai-domains.txt" <<'EOF'
# Root whitelist
openai.com
EOF
    sed -i "s|^WHITELIST_FILE=.*$|WHITELIST_FILE=\"${temp_root}/root-whitelist-configs/ai-domains.txt\"|" "${add_workdir}/whitelist.sh"
    sed -i "s|^INSTALLED_WHITELIST=.*$|INSTALLED_WHITELIST=\"${temp_root}/root-installed-ai-domains.txt\"|" "${add_workdir}/whitelist.sh"
    sed -i "s|^XRAY_CLIENT_CONFIG=.*$|XRAY_CLIENT_CONFIG=\"${temp_root}/missing-root-xray.json\"|" "${add_workdir}/whitelist.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        WHITELIST_SH="${add_workdir}/whitelist.sh" \
        ROOT_WL_FILE="${temp_root}/root-whitelist-configs/ai-domains.txt" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$WHITELIST_SH"
            jq() { cat "$@"; }
            if add_domain "api.anthropic.com" >"${output_file}" 2>&1; then
                exit 1
            fi
            ! grep -q "^api.anthropic.com$" "${ROOT_WL_FILE}"
            ! grep -q "added to whitelist" "${output_file}"
        '; then
        record_pass "Root whitelist 在 Xray 配置缺失时会回滚新增域名且不打印成功"
    else
        record_fail "Root whitelist 在 Xray 配置缺失时会回滚新增域名且不打印成功"
    fi

    local remove_workdir="${temp_root}/root-whitelist-remove"
    mkdir -p "${remove_workdir}"
    cp "${SCRIPT_DIR}/scripts/whitelist.sh" "${remove_workdir}/whitelist.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${remove_workdir}/common.sh"
    mkdir -p "${temp_root}/root-whitelist-remove-configs"
    cat > "${temp_root}/root-whitelist-remove-configs/ai-domains.txt" <<'EOF'
# Root whitelist
# Added manually on 2026-03-27 00:00:00
api.openai.com
EOF
    sed -i "s|^WHITELIST_FILE=.*$|WHITELIST_FILE=\"${temp_root}/root-whitelist-remove-configs/ai-domains.txt\"|" "${remove_workdir}/whitelist.sh"
    sed -i "s|^INSTALLED_WHITELIST=.*$|INSTALLED_WHITELIST=\"${temp_root}/root-remove-installed-ai-domains.txt\"|" "${remove_workdir}/whitelist.sh"
    sed -i "s|^XRAY_CLIENT_CONFIG=.*$|XRAY_CLIENT_CONFIG=\"${temp_root}/missing-root-remove-xray.json\"|" "${remove_workdir}/whitelist.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        WHITELIST_SH="${remove_workdir}/whitelist.sh" \
        ROOT_WL_FILE="${temp_root}/root-whitelist-remove-configs/ai-domains.txt" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$WHITELIST_SH"
            jq() { cat "$@"; }
            confirm_action() { return 0; }
            if remove_domain "api.openai.com" >"${output_file}" 2>&1; then
                exit 1
            fi
            grep -q "^api.openai.com$" "${ROOT_WL_FILE}"
            ! grep -q "removed from whitelist" "${output_file}"
        '; then
        record_pass "Root whitelist 在 Xray 配置缺失时不会删除本地域名或打印移除成功"
    else
        record_fail "Root whitelist 在 Xray 配置缺失时不会删除本地域名或打印移除成功"
    fi

    local normalize_workdir="${temp_root}/root-whitelist-normalize"
    mkdir -p "${normalize_workdir}"
    cp "${SCRIPT_DIR}/scripts/whitelist.sh" "${normalize_workdir}/whitelist.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${normalize_workdir}/common.sh"
    cat > "${temp_root}/root-xray-config.json" <<'EOF'
{
  "routing": {
    "rules": [
      {
        "type": "field",
        "outboundTag": "proxy",
        "domain": ["domain:openai.com"]
      }
    ]
  }
}
EOF
    sed -i "s|^XRAY_CLIENT_CONFIG=.*$|XRAY_CLIENT_CONFIG=\"${temp_root}/root-xray-config.json\"|" "${normalize_workdir}/whitelist.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        WHITELIST_SH="${normalize_workdir}/whitelist.sh" \
        ROOT_XRAY_CONFIG="${temp_root}/root-xray-config.json" \
        bash -c '
            set -euo pipefail
            source "$WHITELIST_SH"
            jq() {
                local rule=""
                local file=""
                while (($#)); do
                    case "$1" in
                        --arg)
                            if [[ "${2:-}" == "rule" ]]; then
                                rule="${3:-}"
                            fi
                            shift 3
                            ;;
                        *)
                            file="$1"
                            shift
                            ;;
                    esac
                done
                grep -v "\"${rule}\"" "${file}"
            }
            if ! _update_xray_routing "api.openai.com" "remove"; then
                exit 1
            fi
            ! grep -q "domain:openai.com" "${ROOT_XRAY_CONFIG}"
        '; then
        record_pass "Root whitelist 删除子域名时会同步移除归一化后的 Xray 路由规则"
    else
        record_fail "Root whitelist 删除子域名时会同步移除归一化后的 Xray 路由规则"
    fi

    rm -rf "${temp_root}"
}

test_bridge_whitelist_contracts() {
    info "=== AI Gateway Bridge Whitelist 与 Xray 路由原子性契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"

    local add_workdir="${temp_root}/bridge-whitelist-add"
    mkdir -p "${add_workdir}"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/whitelist.sh" "${add_workdir}/whitelist.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${add_workdir}/common.sh"
    mkdir -p "${temp_root}/bridge-whitelist-configs"
    cat > "${temp_root}/bridge-whitelist-configs/ai-domains.txt" <<'EOF'
# Bridge whitelist
openai.com
EOF
    sed -i "s|^WHITELIST_FILE=.*$|WHITELIST_FILE=\"${temp_root}/bridge-whitelist-configs/ai-domains.txt\"|" "${add_workdir}/whitelist.sh"
    sed -i "s|^INSTALLED_WHITELIST=.*$|INSTALLED_WHITELIST=\"${temp_root}/bridge-installed-ai-domains.txt\"|" "${add_workdir}/whitelist.sh"
    sed -i "s|^XRAY_CLIENT_CONFIG=.*$|XRAY_CLIENT_CONFIG=\"${temp_root}/missing-bridge-xray.json\"|" "${add_workdir}/whitelist.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        WHITELIST_SH="${add_workdir}/whitelist.sh" \
        BRIDGE_WL_FILE="${temp_root}/bridge-whitelist-configs/ai-domains.txt" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$WHITELIST_SH"
            jq() { cat "$@"; }
            if add_domain "api.anthropic.com" >"${output_file}" 2>&1; then
                exit 1
            fi
            ! grep -q "^api.anthropic.com$" "${BRIDGE_WL_FILE}"
            ! grep -q "added to whitelist" "${output_file}"
        '; then
        record_pass "AI Gateway Bridge whitelist 在 Xray 配置缺失时会回滚新增域名且不打印成功"
    else
        record_fail "AI Gateway Bridge whitelist 在 Xray 配置缺失时会回滚新增域名且不打印成功"
    fi

    local remove_workdir="${temp_root}/bridge-whitelist-remove"
    mkdir -p "${remove_workdir}"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/whitelist.sh" "${remove_workdir}/whitelist.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${remove_workdir}/common.sh"
    mkdir -p "${temp_root}/bridge-whitelist-remove-configs"
    cat > "${temp_root}/bridge-whitelist-remove-configs/ai-domains.txt" <<'EOF'
# Bridge whitelist
# Added manually on 2026-03-27 00:00:00
api.openai.com
EOF
    sed -i "s|^WHITELIST_FILE=.*$|WHITELIST_FILE=\"${temp_root}/bridge-whitelist-remove-configs/ai-domains.txt\"|" "${remove_workdir}/whitelist.sh"
    sed -i "s|^INSTALLED_WHITELIST=.*$|INSTALLED_WHITELIST=\"${temp_root}/bridge-remove-installed-ai-domains.txt\"|" "${remove_workdir}/whitelist.sh"
    sed -i "s|^XRAY_CLIENT_CONFIG=.*$|XRAY_CLIENT_CONFIG=\"${temp_root}/missing-bridge-remove-xray.json\"|" "${remove_workdir}/whitelist.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        WHITELIST_SH="${remove_workdir}/whitelist.sh" \
        BRIDGE_WL_FILE="${temp_root}/bridge-whitelist-remove-configs/ai-domains.txt" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$WHITELIST_SH"
            jq() { cat "$@"; }
            confirm_action() { return 0; }
            if remove_domain "api.openai.com" >"${output_file}" 2>&1; then
                exit 1
            fi
            grep -q "^api.openai.com$" "${BRIDGE_WL_FILE}"
            ! grep -q "removed from whitelist" "${output_file}"
        '; then
        record_pass "AI Gateway Bridge whitelist 在 Xray 配置缺失时不会删除本地域名或打印移除成功"
    else
        record_fail "AI Gateway Bridge whitelist 在 Xray 配置缺失时不会删除本地域名或打印移除成功"
    fi

    local normalize_workdir="${temp_root}/bridge-whitelist-normalize"
    mkdir -p "${normalize_workdir}"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/whitelist.sh" "${normalize_workdir}/whitelist.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${normalize_workdir}/common.sh"
    cat > "${temp_root}/bridge-xray-config.json" <<'EOF'
{
  "routing": {
    "rules": [
      {
        "type": "field",
        "outboundTag": "proxy",
        "domain": ["domain:openai.com"]
      }
    ]
  }
}
EOF
    sed -i "s|^XRAY_CLIENT_CONFIG=.*$|XRAY_CLIENT_CONFIG=\"${temp_root}/bridge-xray-config.json\"|" "${normalize_workdir}/whitelist.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        WHITELIST_SH="${normalize_workdir}/whitelist.sh" \
        BRIDGE_XRAY_CONFIG="${temp_root}/bridge-xray-config.json" \
        bash -c '
            set -euo pipefail
            source "$WHITELIST_SH"
            jq() {
                local rule=""
                local file=""
                while (($#)); do
                    case "$1" in
                        --arg)
                            if [[ "${2:-}" == "rule" ]]; then
                                rule="${3:-}"
                            fi
                            shift 3
                            ;;
                        *)
                            file="$1"
                            shift
                            ;;
                    esac
                done
                grep -v "\"${rule}\"" "${file}"
            }
            if ! _update_xray_routing "api.openai.com" "remove"; then
                exit 1
            fi
            ! grep -q "domain:openai.com" "${BRIDGE_XRAY_CONFIG}"
        '; then
        record_pass "AI Gateway Bridge whitelist 删除子域名时会同步移除归一化后的 Xray 路由规则"
    else
        record_fail "AI Gateway Bridge whitelist 删除子域名时会同步移除归一化后的 Xray 路由规则"
    fi

    rm -rf "${temp_root}"
}

# --- Test: Port consistency ---
test_ports() {
    info "=== 端口一致性测试 ==="

    # Docker proxy must use 7890 (Mihomo) not 10809 (old Xray)
    if grep -q 'host.docker.internal:7890\|host\.docker\.internal:\${proxy_port}' "${SCRIPT_DIR}/scripts/server-a.sh"; then
        record_pass "Docker HTTP_PROXY 使用 Mihomo 7890"
    else
        record_fail "Docker HTTP_PROXY 未使用 Mihomo 7890"
    fi

    # Xray HTTP proxy on 0.0.0.0 (for Docker access)
    if grep -q '"listen": "0.0.0.0"' "${SCRIPT_DIR}/configs/xray/client.json.tpl"; then
        record_pass "Xray HTTP proxy 监听 0.0.0.0 (Docker 可达)"
    else
        record_fail "Xray HTTP proxy 未监听 0.0.0.0"
    fi

    # Mihomo mixed-port 7890 (template uses {{MIHOMO_MIXED_PORT}}, value set in mihomo.sh)
    if grep -q 'mixed-port: {{MIHOMO_MIXED_PORT}}' "${SCRIPT_DIR}/configs/mihomo/config.yaml.tpl" && \
       grep -q 'MIHOMO_MIXED_PORT="7890"' "${SCRIPT_DIR}/scripts/mihomo.sh"; then
        record_pass "Mihomo mixed-port 7890 (template + mihomo.sh 一致)"
    else
        record_fail "Mihomo mixed-port 不一致 (模板或 mihomo.sh 未设置 7890)"
    fi

    # Server A management path and exposure-profile parity
    if grep -q 'header_up X-Forwarded-Prefix /manage' "${SCRIPT_DIR}/configs/caddy/Caddyfile-a.tpl" && \
       grep -q 'header_up X-Forwarded-Prefix /manage' "${SCRIPT_DIR}/scripts/server-a.sh" && \
       grep -Fq 'path /api/* /static/* /logo.png /dashboard' "${SCRIPT_DIR}/configs/caddy/Caddyfile-a.tpl" && \
       grep -Fq 'path /api/* /static/* /logo.png /dashboard' "${SCRIPT_DIR}/scripts/server-a.sh" && \
       grep -q '@manage_private' "${SCRIPT_DIR}/configs/caddy/Caddyfile-a.tpl" && \
       grep -q '@manage_private' "${SCRIPT_DIR}/scripts/server-a.sh" && \
       grep -q 'New API static assets require VPN/private access in vpn-first profile' "${SCRIPT_DIR}/configs/caddy/Caddyfile-a.tpl" && \
       grep -q 'New API static assets require VPN/private access in vpn-first profile' "${SCRIPT_DIR}/scripts/server-a.sh" && \
       grep -q 'Bifrost management requires VPN/private access in vpn-first profile' "${SCRIPT_DIR}/configs/caddy/Caddyfile-a.tpl" && \
       grep -q 'Bifrost management requires VPN/private access in vpn-first profile' "${SCRIPT_DIR}/scripts/server-a.sh" && \
       grep -q 'tls {{TLS_CERT_FILE}} {{TLS_KEY_FILE}}' "${SCRIPT_DIR}/configs/caddy/Caddyfile-a.tpl" && \
       grep -q 'CLOUDFLARE_ORIGIN_CERT_FILE' "${SCRIPT_DIR}/configs/caddy/Caddyfile-a.tpl" && \
       grep -q 'cloudflare-origin' "${SCRIPT_DIR}/scripts/server-a.sh" && \
       grep -q 'server_a_caddy_tls_block' "${SCRIPT_DIR}/scripts/server-a.sh" && \
       grep -q -- '--preferred-profile shortlived' "${SCRIPT_DIR}/scripts/server-a.sh" && \
       grep -q -- '--ip-address "$public_ip"' "${SCRIPT_DIR}/scripts/server-a.sh"; then
        record_pass "Server A /manage 前缀、vpn-first 暴露面与 IP HTTPS 证书合同在模板与运行脚本中一致"
    else
        record_fail "Server A /manage 前缀、vpn-first 暴露面与 IP HTTPS 证书合同在模板与运行脚本中不一致"
    fi

    # Server B panel path and exposure-profile parity
    if grep -q '@xui_private' "${SCRIPT_DIR}/configs/caddy/Caddyfile-b.tpl" && \
       grep -q '@xui_private' "${SCRIPT_DIR}/scripts/server-b.sh" && \
       grep -q 'remote_ip' "${SCRIPT_DIR}/configs/caddy/Caddyfile-b.tpl" && \
       grep -q 'remote_ip' "${SCRIPT_DIR}/scripts/server-b.sh" && \
       grep -q '3x-ui requires VPN/private access in vpn-first profile' "${SCRIPT_DIR}/configs/caddy/Caddyfile-b.tpl" && \
       grep -q '3x-ui requires VPN/private access in vpn-first profile' "${SCRIPT_DIR}/scripts/server-b.sh"; then
        record_pass "Server B 3x-ui 路径与 vpn-first 暴露面在模板与运行脚本中一致"
    else
        record_fail "Server B 3x-ui 路径与 vpn-first 暴露面在模板与运行脚本中不一致"
    fi

    # Health checks must follow the same exposure profile. vpn-first should not
    # mark a 403 management surface as unhealthy.
    if grep -q 'resolve_exposure_profile' "${SCRIPT_DIR}/scripts/health-check.sh" && \
       grep -q 'PUBLIC_MANAGE_EXPOSURE_PROFILE' "${SCRIPT_DIR}/scripts/health-check.sh" && \
       grep -q 'allowlisted_from_current_origin' "${SCRIPT_DIR}/scripts/health-check.sh" && \
       grep -q 'PUBLIC_MANAGE_POLICY' "${SCRIPT_DIR}/scripts/health-check.sh"; then
        record_pass "Health-check /manage 探测已按暴露面 profile 区分 403 保护与公网管理模式"
    else
        record_fail "Health-check /manage 探测未按暴露面 profile 区分 403 保护与公网管理模式"
    fi

    # VPN subnet 10.8.0.0/24
    if grep -q '10.8.0.0/24' "${SCRIPT_DIR}/scripts/vpn.sh" && \
       grep -q '10.8.0.0/24' "${SCRIPT_DIR}/configs/vpn/wg-client.conf.tpl"; then
        record_pass "VPN 子网 10.8.0.0/24 一致"
    else
        record_fail "VPN 子网不一致"
    fi
}

# --- Test: Menu integration ---
test_menu() {
    info "=== 菜单集成测试 ==="

    local install_sh="${SCRIPT_DIR}/install.sh"
    local help_output=""

    # Check all 19 menu flow functions exist
    local flows=(
        "deploy_server_b_flow"
        "deploy_server_a_flow"
        "security_only_flow"
        "monitoring_only_flow"
        "whitelist_flow"
        "health_check_flow"
        "show_connection_info"
        "dd_reinstall_flow"
        "vpn_flow"
        "anti_dpi_flow"
        "mihomo_flow"
        "keepalive_flow"
        "split_tunnel_flow"
        "backup_flow"
        "update_flow"
        "multi_server_flow"
        "user_management_flow"
        "diagnostics_flow"
        "uninstall_flow"
    )

    for flow in "${flows[@]}"; do
        if grep -q "${flow}()" "$install_sh" || grep -q "function ${flow}" "$install_sh"; then
            record_pass "菜单 flow: ${flow}()"
        else
            record_fail "菜单 flow 缺失: ${flow}()"
        fi
    done

    # Check CLI arguments
    local cli_args=(
        "--server-a" "--server-b" "--security" "--health-check"
        "--vpn" "--anti-dpi" "--mihomo" "--keepalive" "--split-tunnel"
        "--backup" "--update" "--multi-server" "--user-mgmt" "--diagnostics"
        "--dd-reinstall" "--uninstall" "--version" "--help"
    )

    help_output="$(bash "$install_sh" --help 2>/dev/null || true)"
    local help_first_line
    help_first_line="$(printf '%s\n' "$help_output" | sed -n '1p')"

    for arg in "${cli_args[@]}"; do
        if printf '%s\n' "$help_output" | grep -q -- "${arg}"; then
            record_pass "CLI 参数: ${arg}"
        else
            record_fail "CLI 参数缺失: ${arg}"
        fi
    done

    if [[ "${help_first_line}" == "Bifrost v2.0 - 一键部署脚本" ]]; then
        record_pass "CLI 帮助输出首行干净"
    else
        record_fail "CLI 帮助输出被启动噪音污染"
    fi

    local version_output
    version_output="$(bash "$install_sh" --version 2>/dev/null || true)"
    if [[ "${version_output}" == "Bifrost v2.0.0" ]]; then
        record_pass "CLI 版本输出干净"
    else
        record_fail "CLI 版本输出被启动噪音污染"
    fi
}

# --- Test: Documentation ---
test_docs() {
    info "=== 文档完整性测试 ==="

    local required_docs=(
        "README.md"
        "docs/USAGE.md"
        "docs/TROUBLESHOOTING.md"
        "docs/CLIENT-SETUP.md"
        "docs/SECURITY.md"
        "docs/VPN-SETUP.md"
    )

    for doc in "${required_docs[@]}"; do
        local filepath="${SCRIPT_DIR}/${doc}"
        if [[ -f "$filepath" ]]; then
            local lines
            lines=$(wc -l < "$filepath")
            if [[ "$lines" -ge 50 ]]; then
                record_pass "文档存在: ${doc} (${lines} 行)"
            else
                record_fail "文档太短: ${doc} (${lines} 行, 预期 ≥50)"
            fi
        else
            record_fail "文档缺失: ${doc}"
        fi
    done

    # Check README mentions key features
    local readme="${SCRIPT_DIR}/README.md"
    for keyword in "VPN" "Mihomo" "DPI" "DD" "Keepalive" "Firezone" "Headscale"; do
        if grep -qi "$keyword" "$readme"; then
            record_pass "README 提及: ${keyword}"
        else
            record_fail "README 未提及: ${keyword}"
        fi
    done
}

# --- Test: Server B marketplace skeleton (PR-1, static checks only) ---
test_marketplace_skeleton_contracts() {
    info "=== Server B 内部 Claude marketplace skeleton 静态合同测试 ==="

    local required_files=(
        "scripts/render-marketplace-json.sh"
        "scripts/validate-marketplace-schema.sh"
        "tests/test-render-marketplace.sh"
        "prompts/0519-1/marketplace-bootstrap/bifrost-internal-plugins/.claude-plugin/marketplace.json"
        "prompts/0519-1/marketplace-bootstrap/bifrost-internal-plugins/LICENSE"
        "prompts/0519-1/marketplace-bootstrap/bifrost-internal-plugins/NOTICE"
        "prompts/0519-1/marketplace-bootstrap/bifrost-internal-plugins/README.md"
        "prompts/0519-1/marketplace-bootstrap/bifrost-internal-plugins/.gitignore"
        "prompts/0519-1/marketplace-bootstrap/bifrost-internal-plugins/plugins/hello-world-skill/.claude-plugin/plugin.json"
        "prompts/0519-1/marketplace-bootstrap/bifrost-internal-plugins/plugins/hello-world-skill/manifest.yaml"
        "prompts/0519-1/marketplace-bootstrap/bifrost-internal-plugins/plugins/hello-world-skill/skills/hello/SKILL.md"
        "prompts/0519-1/marketplace-bootstrap/bifrost-internal-plugins/plugins/hello-world-skill/LICENSE"
        "prompts/0519-1/marketplace-bootstrap/bifrost-internal-plugins/plugins/hello-world-skill/README.md"
    )
    local file
    for file in "${required_files[@]}"; do
        if [[ -f "${SCRIPT_DIR}/${file}" ]]; then
            record_pass "marketplace skeleton file exists: ${file}"
        else
            record_fail "marketplace skeleton file missing: ${file}"
        fi
    done

    local sh
    for sh in scripts/render-marketplace-json.sh \
              scripts/validate-marketplace-schema.sh \
              tests/test-render-marketplace.sh; do
        if [[ -f "${SCRIPT_DIR}/${sh}" ]] && bash -n "${SCRIPT_DIR}/${sh}" 2>/dev/null; then
            record_pass "bash -n: ${sh}"
        else
            record_fail "bash -n: ${sh}"
        fi
    done

    local seed_json="${SCRIPT_DIR}/prompts/0519-1/marketplace-bootstrap/bifrost-internal-plugins/.claude-plugin/marketplace.json"
    if command -v jq >/dev/null 2>&1; then
        if bash "${SCRIPT_DIR}/scripts/validate-marketplace-schema.sh" "${seed_json}" >/dev/null 2>&1; then
            record_pass "validate-marketplace-schema.sh accepts seed marketplace.json"
        else
            record_fail "validate-marketplace-schema.sh rejected seed marketplace.json"
        fi

        local seed_name seed_owner_type seed_src
        seed_name="$(jq -r .name "${seed_json}" 2>/dev/null)"
        seed_owner_type="$(jq -r ".owner | type" "${seed_json}" 2>/dev/null)"
        seed_src="$(jq -r ".plugins[0].source" "${seed_json}" 2>/dev/null)"
        if [[ "${seed_name}" == "bifrost-internal" ]]; then
            record_pass "seed marketplace.json .name == bifrost-internal"
        else
            record_fail "seed marketplace.json .name == '${seed_name}' (expected bifrost-internal)"
        fi
        if [[ "${seed_owner_type}" == "object" ]]; then
            record_pass "seed marketplace.json .owner is object (spec.md C2)"
        else
            record_fail "seed marketplace.json .owner is '${seed_owner_type}' (expected object)"
        fi
        if [[ "${seed_src}" == "./plugins/hello-world-skill" ]]; then
            record_pass "seed marketplace.json .plugins[0].source uses relative-path string (spec.md 4.1)"
        else
            record_fail "seed marketplace.json .plugins[0].source == '${seed_src}' (expected ./plugins/hello-world-skill)"
        fi
        if grep -q "git+" "${seed_json}"; then
            record_fail "seed marketplace.json contains forbidden git+ URL prefix (spec.md C3)"
        else
            record_pass "seed marketplace.json has no git+ URL prefix (spec.md C3)"
        fi
    else
        record_fail "jq missing; cannot run schema validator (install jq to run this test)"
    fi
}

# --- Test: Server B private distribution contracts ---
test_distribution_contracts() {
    info "=== Server B 私有分发栈合同测试 ==="

    local required_files=(
        "configs/verdaccio/config.yaml.tpl"
        "configs/new-api/docker-compose.yml.tpl"
        "configs/new-api/pg-init.sh"
        "configs/caddy/Caddyfile-b-distribution.tpl"
        "configs/nftables/bifrost-distribution.nft.tpl"
        "configs/systemd/verdaccio.service"
        "configs/systemd/git-mirror@.service"
        "configs/systemd/git-mirror@.timer"
        "configs/systemd/caddy-wg-after.conf"
        "configs/restic/restic-to-a.service"
        "configs/restic/restic-to-a.timer"
        "scripts/git-mirror-sync.sh"
        "scripts/bifrost-readonly-router.sh"
        "scripts/bifrost-restic-backup.sh"
        "scripts/e2e-distribution-rehearsal.sh"
        "scripts/legacy-vps-final-snapshot.ps1"
        "configs/systemd/marketplace-render.path"
        "configs/systemd/marketplace-render.service"
        "configs/systemd/upstream-schema-check.timer"
        "configs/systemd/upstream-schema-check.service"
        "scripts/check-upstream-schema.sh"
    )
    local file
    for file in "${required_files[@]}"; do
        if [[ -f "${SCRIPT_DIR}/${file}" ]]; then
            record_pass "distribution 文件存在: ${file}"
        else
            record_fail "distribution 文件缺失: ${file}"
        fi
    done

    if grep -Fq 'sslmode=disable' "${SCRIPT_DIR}/configs/new-api/docker-compose.yml.tpl" && \
       grep -Fq 'condition: service_healthy' "${SCRIPT_DIR}/configs/new-api/docker-compose.yml.tpl" && \
       grep -Fq 'redis-server' "${SCRIPT_DIR}/configs/new-api/docker-compose.yml.tpl" && \
       grep -Fq -- '--appendonly' "${SCRIPT_DIR}/configs/new-api/docker-compose.yml.tpl"; then
        record_pass "NewAPI compose 固化 PG sslmode/healthcheck/Redis AOF"
    else
        record_fail "NewAPI compose 缺少 PG sslmode/healthcheck/Redis AOF 合同"
    fi

    if grep -Fq 'VERDACCIO_PUBLIC_URL=https://npm.uuhfn.cloud' "${SCRIPT_DIR}/configs/systemd/verdaccio.service" && \
       grep -Fq 'Requires=docker.service wg-quick@wg0.service' "${SCRIPT_DIR}/configs/systemd/verdaccio.service" && \
       ! grep -Fq 'VERDACCIO_BOOTSTRAP_PASSWORD' "${SCRIPT_DIR}/configs/systemd/verdaccio.service"; then
        record_pass "Verdaccio unit 绑定 wg0 且不暴露 bootstrap 密码"
    else
        record_fail "Verdaccio unit 未满足 wg0/public URL/secret 合同"
    fi

    if grep -Fq 'git push disabled on mirror' "${SCRIPT_DIR}/configs/caddy/Caddyfile-b-distribution.tpl" && \
       grep -Fq 'env QUERY_STRING' "${SCRIPT_DIR}/configs/caddy/Caddyfile-b-distribution.tpl" && \
       grep -Fq 'env CONTENT_LENGTH' "${SCRIPT_DIR}/configs/caddy/Caddyfile-b-distribution.tpl"; then
        record_pass "Server B Caddy git mirror 禁 push 且 FastCGI env 完整"
    else
        record_fail "Server B Caddy git mirror 缺少只读或 FastCGI env 合同"
    fi

    if grep -Fq 'table inet filter' "${SCRIPT_DIR}/configs/nftables/bifrost-distribution.nft.tpl" && \
       grep -Fq 'policy drop' "${SCRIPT_DIR}/configs/nftables/bifrost-distribution.nft.tpl" && \
       grep -Fq 'iifname != "wg0" tcp dport { 3000, 4873, 8081, 8082 } drop' "${SCRIPT_DIR}/configs/nftables/bifrost-distribution.nft.tpl" && \
       grep -Fq 'DOCKER-USER' "${SCRIPT_DIR}/scripts/server-b.sh"; then
        record_pass "nftables 单表 drop + DOCKER-USER 防公网泄漏"
    else
        record_fail "nftables/DOCKER-USER 防泄漏合同缺失"
    fi

    if grep -Fq -- '--enable-distribution' "${SCRIPT_DIR}/scripts/server-b.sh" && \
       grep -Fq -- '--disable-distribution' "${SCRIPT_DIR}/scripts/server-b.sh" && \
       grep -Fq -- '--rotate-bootstrap-pwd' "${SCRIPT_DIR}/scripts/server-b.sh" && \
       grep -Fq '_distribution_step_done' "${SCRIPT_DIR}/scripts/server-b.sh" && \
       ! grep -E 'VERDACCIO_BOOTSTRAP_PASSWORD.*_distribution_state_set|_distribution_state_set.*VERDACCIO_BOOTSTRAP_PASSWORD' "${SCRIPT_DIR}/scripts/server-b.sh" >/dev/null; then
        record_pass "server-b.sh distribution 入口/step-state/secret 边界存在"
    else
        record_fail "server-b.sh distribution 入口/step-state/secret 边界缺失"
    fi

    if grep -Fq 'command="/usr/local/bin/bifrost-readonly-router.sh \${SSH_ORIGINAL_COMMAND}"' "${SCRIPT_DIR}/scripts/server-b.sh" && \
       grep -Fq 'logs:verdaccio)' "${SCRIPT_DIR}/scripts/bifrost-readonly-router.sh" && \
       grep -Fq 'logs:new-api' "${SCRIPT_DIR}/scripts/bifrost-readonly-router.sh" && \
       grep -Fq 'journalctl -u "git-mirror@${repo}" --no-pager -n 200' "${SCRIPT_DIR}/scripts/bifrost-readonly-router.sh" && \
       grep -Fq 'forbidden' "${SCRIPT_DIR}/scripts/bifrost-readonly-router.sh"; then
        record_pass "bifrost-readonly forced-command 白名单合同存在"
    else
        record_fail "bifrost-readonly forced-command 白名单合同缺失"
    fi

    if grep -Fq 'check_distribution()' "${SCRIPT_DIR}/scripts/diagnostics.sh" && \
       grep -Fq -- '--check distribution' "${SCRIPT_DIR}/scripts/diagnostics.sh" && \
       grep -Fq 'VERDACCIO_PUBLIC_URL=https://npm.uuhfn.cloud' "${SCRIPT_DIR}/scripts/diagnostics.sh" && \
       grep -Fq 'sslmode=disable' "${SCRIPT_DIR}/scripts/diagnostics.sh"; then
        record_pass "diagnostics.sh 支持 --check distribution 且覆盖关键合同"
    else
        record_fail "diagnostics.sh distribution 检查缺失"
    fi

    if grep -Fq '(server_b_proxy)' "${SCRIPT_DIR}/configs/caddy/Caddyfile-a.tpl" && \
       grep -Fq 'api.{{DOMAIN}}' "${SCRIPT_DIR}/configs/caddy/Caddyfile-a.tpl" && \
       grep -Fq 'npm.{{DOMAIN}}' "${SCRIPT_DIR}/configs/caddy/Caddyfile-a.tpl" && \
       grep -Fq 'files.{{DOMAIN}}' "${SCRIPT_DIR}/configs/caddy/Caddyfile-a.tpl" && \
       grep -Fq 'http://10.8.0.2:3000' "${SCRIPT_DIR}/configs/caddy/Caddyfile-a.tpl" && \
       grep -Fq 'http://10.8.0.2:4873' "${SCRIPT_DIR}/configs/caddy/Caddyfile-a.tpl"; then
        record_pass "Server A Caddy 模板包含 api/npm/files 到 Server B 的反代"
    else
        record_fail "Server A Caddy 模板缺少 api/npm/files 到 Server B 的反代"
    fi

    if grep -Fq 'server_a_new_api_mode()' "${SCRIPT_DIR}/scripts/server-a.sh" && \
       grep -Fq 'BIFROST_SERVER_A_NEWAPI_MODE' "${SCRIPT_DIR}/scripts/server-a.sh" && \
       grep -Fq 'BIFROST_DISTRIBUTION_DOMAIN' "${SCRIPT_DIR}/scripts/server-a.sh" && \
       grep -Fq 'api.*|npm.*|files.*|legacy.*)' "${SCRIPT_DIR}/scripts/server-a.sh" && \
       grep -Fq 'distribution_domain="${domain#*.}"' "${SCRIPT_DIR}/scripts/server-a.sh" && \
       ! grep -Fq 'health_uri /-/ping' "${SCRIPT_DIR}/scripts/server-a.sh" && \
       ! grep -Fq 'health_uri /-/ping' "${SCRIPT_DIR}/configs/caddy/Caddyfile-a.tpl" && \
       grep -Fq 'Skipping local New API install; Server A is running distribution gateway mode' "${SCRIPT_DIR}/scripts/server-a.sh"; then
        record_pass "Server A NewAPI 默认路径已转 distribution/legacy 显式模式且分发域名/健康检查合同正确"
    else
        record_fail "Server A NewAPI distribution/legacy 模式或分发反代合同缺失"
    fi

    # === spec.md PR-2 contract assertions (marketplace + step 07 + admin-router) ===
    if grep -Fq '@plugins_status path /plugins/state.json /plugins/LICENSE.md /plugins/NOTICE.md' "${SCRIPT_DIR}/configs/caddy/Caddyfile-b-distribution.tpl"; then
        record_pass "Caddyfile-b-distribution.tpl contains @plugins_status matcher (spec 3.3)"
    else
        record_fail "Caddyfile-b-distribution.tpl missing @plugins_status matcher (spec 3.3)"
    fi

    if grep -Fq '_distribution_prepare_marketplace_dirs' "${SCRIPT_DIR}/scripts/server-b.sh" \
       && grep -Fq '_distribution_init_marketplace_bare' "${SCRIPT_DIR}/scripts/server-b.sh" \
       && grep -Fq '_distribution_init_upstream_schema_baseline' "${SCRIPT_DIR}/scripts/server-b.sh" \
       && grep -Fq '_distribution_render_marketplace_license_notice' "${SCRIPT_DIR}/scripts/server-b.sh" \
       && grep -Fq '_distribution_render_marketplace_scripts' "${SCRIPT_DIR}/scripts/server-b.sh"; then
        record_pass "server-b.sh contains all 5 PR-2 marketplace helper definitions (spec 9.2)"
    else
        record_fail "server-b.sh missing one or more PR-2 marketplace helper definitions (spec 9.2)"
    fi

    if grep -Fq 'step_id="07_render_marketplace"' "${SCRIPT_DIR}/scripts/server-b.sh"; then
        record_pass "server-b.sh enable_distribution injects step 07_render_marketplace (spec 9.1)"
    else
        record_fail "server-b.sh missing step 07_render_marketplace (spec 9.1)"
    fi

    if grep -Fq 'systemctl disable --now marketplace-render.path' "${SCRIPT_DIR}/scripts/server-b.sh" \
       && grep -Fq 'systemctl disable --now upstream-schema-check.timer' "${SCRIPT_DIR}/scripts/server-b.sh"; then
        record_pass "disable_distribution stops marketplace + upstream-schema-check (spec 9.4 M12)"
    else
        record_fail "disable_distribution missing marketplace + upstream-schema-check shutdown (spec 9.4 M12)"
    fi

    # spec.md C6 anti-regression: bifrost-internal-plugins must NOT appear in git-mirror-sync.sh.
    if ! grep -Fq 'bifrost-internal-plugins' "${SCRIPT_DIR}/scripts/git-mirror-sync.sh"; then
        record_pass "git-mirror-sync.sh has no bifrost-internal-plugins arm (spec C6 anti-regression)"
    else
        record_fail "git-mirror-sync.sh contains bifrost-internal-plugins arm -- violates spec C6"
    fi

    if grep -Fq 'marketplace:status)' "${SCRIPT_DIR}/scripts/bifrost-readonly-router.sh" \
       && grep -Fq 'marketplace:list-json)' "${SCRIPT_DIR}/scripts/bifrost-readonly-router.sh" \
       && grep -Fq 'marketplace:disk-report)' "${SCRIPT_DIR}/scripts/bifrost-readonly-router.sh" \
       && grep -Fq 'logs:marketplace-render)' "${SCRIPT_DIR}/scripts/bifrost-readonly-router.sh" \
       && grep -Fq 'logs:upstream-schema-check)' "${SCRIPT_DIR}/scripts/bifrost-readonly-router.sh"; then
        record_pass "bifrost-readonly-router.sh contains 5 marketplace case arms (spec PR-2 section 10)"
    else
        record_fail "bifrost-readonly-router.sh missing marketplace case arms (spec PR-2 section 10)"
    fi

    # spec.md M16: logs:git-mirror inner allowlist must include bifrost-internal-plugins.
    if grep -Fq 'claude-for-legal-zh|bifrost-internal-plugins)' "${SCRIPT_DIR}/scripts/bifrost-readonly-router.sh"; then
        record_pass "bifrost-readonly-router.sh logs:git-mirror inner allowlist contains bifrost-internal-plugins (spec M16)"
    else
        record_fail "bifrost-readonly-router.sh logs:git-mirror inner allowlist missing bifrost-internal-plugins (spec M16)"
    fi

    if grep -Fq 'PathModified=/var/lib/git-mirrors/bifrost-internal-plugins.git/packed-refs' "${SCRIPT_DIR}/configs/systemd/marketplace-render.path"; then
        record_pass "marketplace-render.path watches packed-refs (spec 4.3 M5)"
    else
        record_fail "marketplace-render.path missing packed-refs PathModified"
    fi

    if grep -Fq 'Requires=network-online.target' "${SCRIPT_DIR}/configs/systemd/marketplace-render.service" \
       && grep -Fq 'ExecStart=/usr/local/bin/render-marketplace-json.sh bifrost-internal-plugins' "${SCRIPT_DIR}/configs/systemd/marketplace-render.service"; then
        record_pass "marketplace-render.service contains network-online + ExecStart (spec 4.3 M7)"
    else
        record_fail "marketplace-render.service missing network-online / ExecStart"
    fi

    if grep -Fq 'Requires=network-online.target' "${SCRIPT_DIR}/configs/systemd/upstream-schema-check.service" \
       && grep -Fq 'ExecStart=/usr/local/bin/check-upstream-schema.sh' "${SCRIPT_DIR}/configs/systemd/upstream-schema-check.service"; then
        record_pass "upstream-schema-check.service contains network-online + ExecStart (spec 4.3 M7)"
    else
        record_fail "upstream-schema-check.service missing network-online / ExecStart"
    fi

    if grep -Fq 'OnCalendar=daily' "${SCRIPT_DIR}/configs/systemd/upstream-schema-check.timer"; then
        record_pass "upstream-schema-check.timer contains OnCalendar=daily (spec 4.3)"
    else
        record_fail "upstream-schema-check.timer missing OnCalendar=daily"
    fi

    if grep -Eq 'LICENSE-OK|LICENSE-BASELINE-INIT|UPSTREAM-CHANGED' "${SCRIPT_DIR}/scripts/check-upstream-schema.sh"; then
        record_pass "check-upstream-schema.sh emits AC-12 status code literals (spec 5.4)"
    else
        record_fail "check-upstream-schema.sh missing AC-12 status code literals (spec 5.4)"
    fi

    local sh_check
    for sh_check in scripts/check-upstream-schema.sh scripts/bifrost-readonly-router.sh scripts/bifrost-admin-router.sh; do
        if [[ -f "${SCRIPT_DIR}/${sh_check}" ]] && bash -n "${SCRIPT_DIR}/${sh_check}" 2>/dev/null; then
            record_pass "bash -n: ${sh_check}"
        else
            record_fail "bash -n: ${sh_check}"
        fi
    done

    # spec.md PR-5a contract assertions: admin-router whitelist + server-b helpers.
    if [[ -f "${SCRIPT_DIR}/scripts/bifrost-admin-router.sh" ]] \
       && grep -Fq "upload)" "${SCRIPT_DIR}/scripts/bifrost-admin-router.sh" \
       && grep -Fq "tag-create)" "${SCRIPT_DIR}/scripts/bifrost-admin-router.sh" \
       && grep -Fq "approve)" "${SCRIPT_DIR}/scripts/bifrost-admin-router.sh" \
       && grep -Fq "curate)" "${SCRIPT_DIR}/scripts/bifrost-admin-router.sh" \
       && grep -Fq "rerender)" "${SCRIPT_DIR}/scripts/bifrost-admin-router.sh"; then
        record_pass "bifrost-admin-router.sh contains 5 PR-5a write verbs (spec section 6.3 + 7.2)"
    else
        record_fail "bifrost-admin-router.sh missing one or more PR-5a write verbs"
    fi

    if grep -Fq 'forbidden' "${SCRIPT_DIR}/scripts/bifrost-admin-router.sh" \
       && grep -Fq 'exit 2' "${SCRIPT_DIR}/scripts/bifrost-admin-router.sh"; then
        record_pass "bifrost-admin-router.sh fails closed on unknown verb (forbidden + exit 2)"
    else
        record_fail "bifrost-admin-router.sh missing forbidden / exit 2 fail-closed default"
    fi

    if grep -Fq 'audit_log' "${SCRIPT_DIR}/scripts/bifrost-admin-router.sh" \
       && grep -Fq '/var/log/marketplace/admin-audit.log' "${SCRIPT_DIR}/scripts/bifrost-admin-router.sh" \
       && grep -Fq 'sync' "${SCRIPT_DIR}/scripts/bifrost-admin-router.sh"; then
        record_pass "bifrost-admin-router.sh writes audit log + sync (spec section 6.3)"
    else
        record_fail "bifrost-admin-router.sh missing audit log + sync chain"
    fi

    if ! grep -E '(^[[:space:]]*eval |^[[:space:]]*exec sh |^[[:space:]]*bash -c )' "${SCRIPT_DIR}/scripts/bifrost-admin-router.sh" >/dev/null 2>&1; then
        record_pass "bifrost-admin-router.sh free of eval / exec sh / bash -c (spec M11)"
    else
        record_fail "bifrost-admin-router.sh uses eval / exec sh / bash -c -- escape hatch forbidden by spec M11"
    fi

    if grep -Fq '_distribution_configure_admin_ssh()' "${SCRIPT_DIR}/scripts/server-b.sh" \
       && grep -Fq 'BIFROST_ADMIN_SSH_PUBLIC_KEY' "${SCRIPT_DIR}/scripts/server-b.sh" \
       && grep -Fq 'bifrost-admin-router.sh' "${SCRIPT_DIR}/scripts/server-b.sh"; then
        record_pass "server-b.sh defines _distribution_configure_admin_ssh + admin-router install (spec PR-5a section 9.2)"
    else
        record_fail "server-b.sh missing _distribution_configure_admin_ssh / admin-router install"
    fi

    local temp_root
    temp_root="$(mktemp -d)"
    if BIFROST_TRACE_COMMON_LOAD=0 \
        SERVER_B_SH="${SCRIPT_DIR}/scripts/server-b.sh" \
        TMP_ROOT="${temp_root}" \
        bash -c '
            set -euo pipefail
            source "$SERVER_B_SH"
            state_file="${TMP_ROOT}/distribution-state.env"
            step_file="${TMP_ROOT}/distribution-steps.txt"
            touch "${step_file}"

            detect_system() { PKG_MGR=apt; }
            _install_base_dependencies() { return 0; }
            _distribution_require_wg0() { return 0; }
            _distribution_ensure_docker() { return 0; }
            _install_caddy() { return 0; }
            _distribution_ensure_caddy_service() { return 0; }
            _distribution_ensure_user() { return 0; }
            install_packages() { return 0; }
            command() {
                if [[ "${1:-}" == "-v" ]]; then
                    return 0
                fi
                builtin command "$@"
            }
            get_public_ip() { echo "203.0.113.44"; }
            _distribution_state_set() { printf "%s=%s\n" "$1" "$2" >> "${state_file}"; }
            _distribution_state_get() { grep -E "^$1=" "${state_file}" 2>/dev/null | tail -n1 | cut -d= -f2-; }
            _distribution_step_done() {
                case "$1" in
                    08_*|09_*|10_*|11_*|12_*|13_*) return 0 ;;
                esac
                grep -Fxq "$1" "${step_file}"
            }
            _distribution_mark_step_done() { printf "%s\n" "$1" >> "${step_file}"; }
            _distribution_write_verdaccio_config() { echo render_verdaccio >> "${TMP_ROOT}/calls"; }
            _distribution_write_new_api_env() { echo render_new_api_env >> "${TMP_ROOT}/calls"; }
            _distribution_render_new_api_compose() { echo render_new_api_compose >> "${TMP_ROOT}/calls"; }
            _distribution_render_caddy() { echo render_caddy >> "${TMP_ROOT}/calls"; }
            _distribution_render_nftables() { echo render_nftables >> "${TMP_ROOT}/calls"; }
            _distribution_render_systemd_units() { echo render_systemd >> "${TMP_ROOT}/calls"; }
            _distribution_render_git_mirror_script() { echo render_git_script >> "${TMP_ROOT}/calls"; }
            _distribution_render_readonly_router() { echo render_readonly_router >> "${TMP_ROOT}/calls"; }
            _distribution_render_restic_script() { echo render_restic_script >> "${TMP_ROOT}/calls"; }
            _distribution_render_marketplace_scripts() { echo render_marketplace_scripts >> "${TMP_ROOT}/calls"; }
            _distribution_prepare_marketplace_dirs() { echo prepare_marketplace_dirs >> "${TMP_ROOT}/calls"; }
            _distribution_init_marketplace_bare() { echo init_marketplace_bare >> "${TMP_ROOT}/calls"; }
            _distribution_init_upstream_schema_baseline() { echo init_upstream_schema_baseline >> "${TMP_ROOT}/calls"; }
            _distribution_configure_admin_ssh() { echo configure_admin_ssh >> "${TMP_ROOT}/calls"; }
            _distribution_configure_readonly_ssh() { _distribution_state_set BIFROST_READONLY_SSH_CONFIGURED 0; }
            _distribution_write_restic_env() { echo render_restic_env >> "${TMP_ROOT}/calls"; }
            _distribution_init_verdaccio_bootstrap() { _distribution_state_set VERDACCIO_BOOTSTRAP_INITIALIZED 1; }
            _distribution_verify() { return 0; }
            _distribution_prepare_dirs() { return 0; }
            _distribution_apply_docker_user_rules() { return 0; }
            nft() { return 0; }
            systemctl() { return 0; }
            docker() { return 0; }

            enable_distribution >/tmp/enable1.out
            enable_distribution >/tmp/enable2.out
            grep -Fq "DISTRIBUTION_ENABLED=1" "${state_file}"
            grep -Fq "BIFROST_READONLY_SSH_CONFIGURED=0" "${state_file}"
            ! grep -Fq "VERDACCIO_BOOTSTRAP_PASSWORD" "${state_file}"
            [[ "$(grep -c "^render_verdaccio$" "${TMP_ROOT}/calls")" -eq 1 ]]
            # spec.md PR-2 M19: step 07 must mark complete AND each step-07 helper
            # must execute exactly once across two enable_distribution invocations.
            grep -Fxq "07_render_marketplace" "${step_file}"
            [[ "$(grep -c "^prepare_marketplace_dirs$" "${TMP_ROOT}/calls")" -eq 1 ]]
            [[ "$(grep -c "^init_marketplace_bare$" "${TMP_ROOT}/calls")" -eq 1 ]]
            [[ "$(grep -c "^init_upstream_schema_baseline$" "${TMP_ROOT}/calls")" -eq 1 ]]
            [[ "$(grep -c "^render_marketplace_scripts$" "${TMP_ROOT}/calls")" -eq 1 ]]
            # spec.md PR-5a: bifrost-admin SSH config must fire exactly once in step 07.
            [[ "$(grep -c "^configure_admin_ssh$" "${TMP_ROOT}/calls")" -eq 1 ]]
        '; then
        record_pass "enable_distribution mock 验证 step-state 幂等与 secret 不落 state"
    else
        record_fail "enable_distribution mock 验证失败"
    fi
    rm -rf "${temp_root}"
}

# --- Test: Bifrost API contracts ---
test_bifrost_api_contracts() {
    info "=== Bifrost API 合同测试 ==="

    local py_cmd
    if ! py_cmd="$(find_python_cmd)"; then
        record_fail "缺少 Python 运行时，无法执行 bifrost-api 合同测试"
        return
    fi

    if python_has_bifrost_test_deps "$py_cmd"; then
        if run_bifrost_contract_checks "$py_cmd"; then
            record_pass "Bifrost API 合同测试（本地依赖）"
        else
            record_fail "Bifrost API 合同测试（本地依赖）"
        fi
        return
    fi

    local temp_site_packages
    local pip_log
    temp_site_packages="$(mktemp -d)"
    pip_log="$(mktemp)"

    if ! "$py_cmd" -m pip install --quiet --disable-pip-version-check \
        -r "${SCRIPT_DIR}/bifrost-api/requirements.txt" \
        --target "${temp_site_packages}" >"${pip_log}" 2>&1; then
        if is_external_network_failure "${pip_log}"; then
            record_skip "Bifrost API 合同测试（临时依赖自举受环境网络限制）"
        else
            cat "${pip_log}" >&2
            record_fail "Bifrost API 合同测试（临时依赖自举）"
        fi
        rm -rf "${temp_site_packages}"
        rm -f "${pip_log}"
        return
    fi

    rm -f "${pip_log}"

    if run_bifrost_contract_checks "$py_cmd" "${temp_site_packages}"; then
        record_pass "Bifrost API 合同测试（临时依赖自举）"
    else
        record_fail "Bifrost API 合同测试（临时依赖自举）"
    fi

    rm -rf "${temp_site_packages}"
}

test_bifrost_shell_contracts() {
    info "=== Bifrost API 管理脚本契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"

    local deploy_workdir="${temp_root}/bifrost-shell-deploy"
    mkdir -p "${deploy_workdir}" "${temp_root}/bifrost-api"
    cp "${SCRIPT_DIR}/scripts/bifrost-api.sh" "${deploy_workdir}/bifrost-api.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${deploy_workdir}/common.sh"
    cat > "${temp_root}/bifrost-api/.env" <<'EOF'
BIFROST_PUBLIC_BASE_URL=https://api.example.com
EOF

    if BIFROST_TRACE_COMMON_LOAD=0 \
        BIFROST_API_SH="${deploy_workdir}/bifrost-api.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$BIFROST_API_SH"
            check_command() {
                case "$1" in
                    docker|curl) return 0 ;;
                    *) return 1 ;;
                esac
            }
            require_docker_server_version() { return 0; }
            _ba_check_newapi() { return 0; }
            _ba_get_admin_token() { echo "test-admin-token"; }
            _ba_wait_for_health() { return 1; }
            docker() {
                if [[ "$1" == "info" ]]; then
                    return 0
                fi
                if [[ "$1" == "compose" && "${2:-}" == "version" ]]; then
                    return 0
                fi
                if [[ "$1" == "compose" && "${2:-}" == "build" ]]; then
                    return 0
                fi
                if [[ "$1" == "compose" && "${2:-}" == "up" ]]; then
                    return 0
                fi
                if [[ "$1" == "compose" && "${2:-}" == "logs" ]]; then
                    return 0
                fi
                if [[ "$1" == "ps" ]]; then
                    return 1
                fi
                return 0
            }
            if printf "\n" | deploy_bifrost_api >"${output_file}" 2>&1; then
                exit 1
            fi
            grep -q "health check timed out" "${output_file}"
            ! grep -q "Deployment Complete" "${output_file}"
            ! grep -q "Admin Key:" "${output_file}"
        '; then
        record_pass "bifrost-api deploy 在健康检查超时时不会打印完成摘要"
    else
        record_fail "bifrost-api deploy 在健康检查超时时不会打印完成摘要"
    fi

    local restart_workdir="${temp_root}/bifrost-shell-restart"
    mkdir -p "${restart_workdir}"
    cp "${SCRIPT_DIR}/scripts/bifrost-api.sh" "${restart_workdir}/bifrost-api.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${restart_workdir}/common.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        BIFROST_API_SH="${restart_workdir}/bifrost-api.sh" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$BIFROST_API_SH"
            _ba_wait_for_health() { return 1; }
            docker() {
                if [[ "$1" == "ps" && "${2:-}" == "-a" ]]; then
                    echo "bifrost-api"
                    return 0
                fi
                if [[ "$1" == "compose" && "${2:-}" == "restart" ]]; then
                    return 0
                fi
                return 0
            }
            if _ba_restart >"${output_file}" 2>&1; then
                exit 1
            fi
            grep -q "restart health check timed out" "${output_file}"
            ! grep -q "restarted successfully" "${output_file}"
        '; then
        record_pass "bifrost-api restart 在健康检查超时时会返回失败"
    else
        record_fail "bifrost-api restart 在健康检查超时时会返回失败"
    fi

    local uninstall_workdir="${temp_root}/bifrost-shell-uninstall"
    mkdir -p "${uninstall_workdir}" "${temp_root}/bifrost-api"
    cp "${SCRIPT_DIR}/scripts/bifrost-api.sh" "${uninstall_workdir}/bifrost-api.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${uninstall_workdir}/common.sh"
    cat > "${temp_root}/bifrost-api/.env" <<'EOF'
BIFROST_PUBLIC_BASE_URL=https://api.example.com
EOF

    if BIFROST_TRACE_COMMON_LOAD=0 \
        BIFROST_API_SH="${uninstall_workdir}/bifrost-api.sh" \
        ENV_FILE_PATH="${temp_root}/bifrost-api/.env" \
        bash -c '
            set -euo pipefail
            output_file="$(mktemp)"
            trap "rm -f \"${output_file}\"" EXIT
            source "$BIFROST_API_SH"
            confirm_action() { return 0; }
            docker() {
                if [[ "$1" == "ps" && "${2:-}" == "-a" ]]; then
                    echo "bifrost-api"
                    return 0
                fi
                if [[ "$1" == "compose" && "${2:-}" == "down" ]]; then
                    return 1
                fi
                if [[ "$1" == "rm" && "${2:-}" == "-f" ]]; then
                    return 1
                fi
                return 0
            }
            if _ba_uninstall >"${output_file}" 2>&1; then
                exit 1
            fi
            test -f "${ENV_FILE_PATH}"
            grep -q "Failed to remove Bifrost API container" "${output_file}"
            ! grep -q "Container removed." "${output_file}"
            ! grep -q "Bifrost API uninstalled." "${output_file}"
        '; then
        record_pass "bifrost-api uninstall 在容器删除失败时不会打印已卸载"
    else
        record_fail "bifrost-api uninstall 在容器删除失败时不会打印已卸载"
    fi

    rm -rf "${temp_root}"
}

test_vpn_contracts() {
    info "=== VPN Headscale 凭据完整性契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"

    local deploy_workdir="${temp_root}/root-vpn-deploy"
    mkdir -p "${deploy_workdir}/scripts" "${deploy_workdir}/configs/vpn"
    cp "${SCRIPT_DIR}/scripts/vpn.sh" "${deploy_workdir}/scripts/vpn.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${deploy_workdir}/scripts/common.sh"
    cp "${SCRIPT_DIR}/configs/vpn/headscale-config.yaml" "${deploy_workdir}/configs/vpn/headscale-config.yaml"
    sed -i "s|^readonly VPN_STATE_DIR=.*$|readonly VPN_STATE_DIR=\"${temp_root}/root-vpn-state\"|" "${deploy_workdir}/scripts/vpn.sh"
    sed -i "s|^readonly HEADSCALE_DIR=.*$|readonly HEADSCALE_DIR=\"${temp_root}/root-headscale\"|" "${deploy_workdir}/scripts/vpn.sh"
    sed -i "s|cat > /etc/systemd/system/headscale.service <<SERVICE|cat > \"${temp_root}/root-headscale.service\" <<SERVICE|" "${deploy_workdir}/scripts/vpn.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        VPN_SH="${deploy_workdir}/scripts/vpn.sh" \
        TMP_ROOT="${temp_root}" \
        bash -c '
            set -euo pipefail
            source "$VPN_SH"
            ARCH="x86_64"
            PKG_MGR="apt"
            check_port_open() { return 1; }
            register_cleanup() { return 0; }
            github_download() { : > "$2"; return 0; }
            dpkg() { return 0; }
            apt-get() { return 0; }
            check_command() {
                [[ "${1:-}" == "headscale" ]] && return 0
                return 1
            }
            read_input() { INPUT_RESULT="https://vpn.example.com"; return 0; }
            template_render() { printf "server_url: https://vpn.example.com\n" > "$2"; return 0; }
            useradd() { return 0; }
            chown() { return 0; }
            systemctl() { return 0; }
            enable_service() { return 0; }
            restart_service() { return 0; }
            sleep() { return 0; }
            headscale() {
                if [[ "${1:-}" == "version" ]]; then
                    echo "headscale 0.24.0"
                    return 0
                fi
                if [[ "${1:-}" == "users" && "${2:-}" == "create" ]]; then
                    return 0
                fi
                if [[ "${1:-}" == "apikeys" && "${2:-}" == "create" ]]; then
                    return 1
                fi
                return 0
            }

            output="${TMP_ROOT}/root-vpn-headscale-output.log"
            if _vpn_deploy_headscale >"${output}" 2>&1; then
                exit 1
            fi

            grep -q "Failed to generate Headscale API key." "${output}"
            ! grep -q "Headscale Deployment Complete" "${output}"
            ! grep -q "Headscale deployment complete." "${output}"
        '; then
        record_pass "Root vpn Headscale 在 API key 生成失败时会 fail-fast"
    else
        record_fail "Root vpn Headscale 在 API key 生成失败时会 fail-fast"
    fi

    local user_workdir="${temp_root}/root-vpn-user"
    mkdir -p "${user_workdir}/scripts"
    cp "${SCRIPT_DIR}/scripts/vpn.sh" "${user_workdir}/scripts/vpn.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${user_workdir}/scripts/common.sh"
    sed -i "s|^readonly VPN_STATE_DIR=.*$|readonly VPN_STATE_DIR=\"${temp_root}/root-vpn-user-state\"|" "${user_workdir}/scripts/vpn.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        VPN_SH="${user_workdir}/scripts/vpn.sh" \
        TMP_ROOT="${temp_root}" \
        bash -c '
            set -euo pipefail
            source "$VPN_SH"
            mkdir -p "${VPN_STATE_DIR}"
            cat > "${VPN_STATE_FILE}" <<EOF
VPN_TYPE=headscale
HEADSCALE_SERVER_URL=https://vpn.example.com
EOF
            check_command() {
                [[ "${1:-}" == "headscale" ]] && return 0
                return 1
            }
            check_port_open() { return 1; }
            headscale() {
                if [[ "${1:-}" == "preauthkeys" && "${2:-}" == "create" ]]; then
                    return 1
                fi
                return 0
            }

            output="${TMP_ROOT}/root-vpn-user-output.log"
            if create_vpn_user "alice" >"${output}" 2>&1; then
                exit 1
            fi

            grep -q "Could not generate Headscale pre-auth key for '\''alice'\''." "${output}"
            ! grep -q "VPN user '\''alice'\'' created successfully." "${output}"
            ! test -f "${VPN_USERS_DIR}/alice/preauth-key.txt"
            ! grep -q "^USER_alice_CREATED=" "${VPN_STATE_FILE}"
        '; then
        record_pass "Root vpn create_vpn_user 在 Headscale pre-auth key 生成失败时会拒绝宣告成功"
    else
        record_fail "Root vpn create_vpn_user 在 Headscale pre-auth key 生成失败时会拒绝宣告成功"
    fi

    rm -rf "${temp_root}"
}

test_bridge_vpn_contracts() {
    info "=== AI Gateway Bridge VPN Headscale 凭据完整性契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"

    local deploy_workdir="${temp_root}/bridge-vpn-deploy"
    mkdir -p "${deploy_workdir}/scripts" "${deploy_workdir}/configs/vpn"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/vpn.sh" "${deploy_workdir}/scripts/vpn.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${deploy_workdir}/scripts/common.sh"
    cp "${SCRIPT_DIR}/configs/vpn/headscale-config.yaml" "${deploy_workdir}/configs/vpn/headscale-config.yaml"
    sed -i "s|^readonly VPN_STATE_DIR=.*$|readonly VPN_STATE_DIR=\"${temp_root}/bridge-vpn-state\"|" "${deploy_workdir}/scripts/vpn.sh"
    sed -i "s|^readonly HEADSCALE_DIR=.*$|readonly HEADSCALE_DIR=\"${temp_root}/bridge-headscale\"|" "${deploy_workdir}/scripts/vpn.sh"
    sed -i "s|cat > /etc/systemd/system/headscale.service <<SERVICE|cat > \"${temp_root}/bridge-headscale.service\" <<SERVICE|" "${deploy_workdir}/scripts/vpn.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        VPN_SH="${deploy_workdir}/scripts/vpn.sh" \
        TMP_ROOT="${temp_root}" \
        bash -c '
            set -euo pipefail
            source "$VPN_SH"
            ARCH="x86_64"
            PKG_MGR="apt"
            check_port_open() { return 1; }
            register_cleanup() { return 0; }
            github_download() { : > "$2"; return 0; }
            github_fetch_text() { printf "{\"tag_name\":\"v0.24.1\"}"; return 0; }
            github_mirror_help() { echo "mirror help"; }
            dpkg() { return 0; }
            apt-get() { return 0; }
            check_command() {
                [[ "${1:-}" == "headscale" ]] && return 0
                return 1
            }
            read_input() { INPUT_RESULT="https://vpn.example.com"; return 0; }
            template_render() { printf "server_url: https://vpn.example.com\n" > "$2"; return 0; }
            useradd() { return 0; }
            chown() { return 0; }
            systemctl() { return 0; }
            enable_service() { return 0; }
            restart_service() { return 0; }
            sleep() { return 0; }
            headscale() {
                if [[ "${1:-}" == "version" ]]; then
                    echo "headscale 0.24.1"
                    return 0
                fi
                if [[ "${1:-}" == "users" && "${2:-}" == "create" ]]; then
                    return 0
                fi
                if [[ "${1:-}" == "apikeys" && "${2:-}" == "create" ]]; then
                    return 1
                fi
                return 0
            }

            output="${TMP_ROOT}/bridge-vpn-headscale-output.log"
            if _vpn_deploy_headscale >"${output}" 2>&1; then
                exit 1
            fi

            grep -q "Failed to generate Headscale API key." "${output}"
            ! grep -q "Headscale Deployment Complete" "${output}"
            ! grep -q "Headscale deployment complete." "${output}"
        '; then
        record_pass "AI Gateway Bridge vpn Headscale 在 API key 生成失败时会 fail-fast"
    else
        record_fail "AI Gateway Bridge vpn Headscale 在 API key 生成失败时会 fail-fast"
    fi

    local user_workdir="${temp_root}/bridge-vpn-user"
    mkdir -p "${user_workdir}/scripts"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/vpn.sh" "${user_workdir}/scripts/vpn.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${user_workdir}/scripts/common.sh"
    sed -i "s|^readonly VPN_STATE_DIR=.*$|readonly VPN_STATE_DIR=\"${temp_root}/bridge-vpn-user-state\"|" "${user_workdir}/scripts/vpn.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        VPN_SH="${user_workdir}/scripts/vpn.sh" \
        TMP_ROOT="${temp_root}" \
        bash -c '
            set -euo pipefail
            source "$VPN_SH"
            mkdir -p "${VPN_STATE_DIR}"
            cat > "${VPN_STATE_FILE}" <<EOF
VPN_TYPE=headscale
HEADSCALE_SERVER_URL=https://vpn.example.com
EOF
            check_command() {
                [[ "${1:-}" == "headscale" ]] && return 0
                return 1
            }
            check_port_open() { return 1; }
            headscale() {
                if [[ "${1:-}" == "preauthkeys" && "${2:-}" == "create" ]]; then
                    return 1
                fi
                return 0
            }

            output="${TMP_ROOT}/bridge-vpn-user-output.log"
            if create_vpn_user "alice" >"${output}" 2>&1; then
                exit 1
            fi

            grep -q "Could not generate Headscale pre-auth key for '\''alice'\''." "${output}"
            ! grep -q "VPN user '\''alice'\'' created successfully." "${output}"
            ! test -f "${VPN_USERS_DIR}/alice/preauth-key.txt"
            ! grep -q "^USER_alice_CREATED=" "${VPN_STATE_FILE}"
        '; then
        record_pass "AI Gateway Bridge vpn create_vpn_user 在 Headscale pre-auth key 生成失败时会拒绝宣告成功"
    else
        record_fail "AI Gateway Bridge vpn create_vpn_user 在 Headscale pre-auth key 生成失败时会拒绝宣告成功"
    fi

    rm -rf "${temp_root}"
}

test_vpn_deploy_contracts() {
    info "=== VPN 主部署状态一致性契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"

    local workdir="${temp_root}/root-vpn-deploy-flow"
    mkdir -p "${workdir}/scripts"
    cp "${SCRIPT_DIR}/scripts/vpn.sh" "${workdir}/scripts/vpn.sh"
    cp "${SCRIPT_DIR}/scripts/common.sh" "${workdir}/scripts/common.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        VPN_SH="${workdir}/scripts/vpn.sh" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$VPN_SH"
            detect_system() { return 0; }
            _vpn_check_prerequisites() { return 0; }
            show_menu() { MENU_RESULT=2; }
            setup_vpn_network() { return 0; }
            _vpn_deploy_headscale() { return 1; }
            setup_vpn_firewall() { return 0; }
            if deploy_vpn >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "Headscale deployment failed. Cannot continue with VPN deployment." "${output}"
            ! grep -q "VPN Deployment Complete" "${output}"
            ! grep -q "Enterprise VPN is now the FIRST gate" "${output}"
        '; then
        record_pass "Root deploy_vpn 在 VPN 服务部署失败时会返回失败且不打印完成摘要"
    else
        record_fail "Root deploy_vpn 在 VPN 服务部署失败时会返回失败且不打印完成摘要"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        VPN_SH="${workdir}/scripts/vpn.sh" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$VPN_SH"
            detect_system() { return 0; }
            _vpn_check_prerequisites() { return 0; }
            show_menu() { MENU_RESULT=2; }
            setup_vpn_network() { return 0; }
            _vpn_deploy_headscale() { return 0; }
            setup_vpn_firewall() { return 1; }
            if deploy_vpn >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "VPN firewall configuration failed. Cannot continue with VPN deployment." "${output}"
            ! grep -q "VPN Deployment Complete" "${output}"
            ! grep -q "Enterprise VPN is now the FIRST gate" "${output}"
        '; then
        record_pass "Root deploy_vpn 在防火墙配置失败时会返回失败且不打印完成摘要"
    else
        record_fail "Root deploy_vpn 在防火墙配置失败时会返回失败且不打印完成摘要"
    fi

    rm -rf "${temp_root}"
}

test_bridge_vpn_deploy_contracts() {
    info "=== AI Gateway Bridge VPN 主部署状态一致性契约 ==="

    local temp_root
    temp_root="$(mktemp -d)"

    local workdir="${temp_root}/bridge-vpn-deploy-flow"
    mkdir -p "${workdir}/scripts"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/vpn.sh" "${workdir}/scripts/vpn.sh"
    cp "${SCRIPT_DIR}/ai-gateway-bridge/scripts/common.sh" "${workdir}/scripts/common.sh"

    if BIFROST_TRACE_COMMON_LOAD=0 \
        VPN_SH="${workdir}/scripts/vpn.sh" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$VPN_SH"
            detect_system() { return 0; }
            _vpn_check_prerequisites() { return 0; }
            show_menu() { MENU_RESULT=2; }
            setup_vpn_network() { return 0; }
            _vpn_deploy_headscale() { return 1; }
            setup_vpn_firewall() { return 0; }
            if deploy_vpn >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "Headscale deployment failed. Cannot continue with VPN deployment." "${output}"
            ! grep -q "VPN Deployment Complete" "${output}"
            ! grep -q "Enterprise VPN is now the FIRST gate" "${output}"
        '; then
        record_pass "AI Gateway Bridge deploy_vpn 在 VPN 服务部署失败时会返回失败且不打印完成摘要"
    else
        record_fail "AI Gateway Bridge deploy_vpn 在 VPN 服务部署失败时会返回失败且不打印完成摘要"
    fi

    if BIFROST_TRACE_COMMON_LOAD=0 \
        VPN_SH="${workdir}/scripts/vpn.sh" \
        bash -c '
            set -euo pipefail
            output="$(mktemp)"
            trap "rm -f \"${output}\"" EXIT
            source "$VPN_SH"
            detect_system() { return 0; }
            _vpn_check_prerequisites() { return 0; }
            show_menu() { MENU_RESULT=2; }
            setup_vpn_network() { return 0; }
            _vpn_deploy_headscale() { return 0; }
            setup_vpn_firewall() { return 1; }
            if deploy_vpn >"${output}" 2>&1; then
                exit 1
            fi
            grep -q "VPN firewall configuration failed. Cannot continue with VPN deployment." "${output}"
            ! grep -q "VPN Deployment Complete" "${output}"
            ! grep -q "Enterprise VPN is now the FIRST gate" "${output}"
        '; then
        record_pass "AI Gateway Bridge deploy_vpn 在防火墙配置失败时会返回失败且不打印完成摘要"
    else
        record_fail "AI Gateway Bridge deploy_vpn 在防火墙配置失败时会返回失败且不打印完成摘要"
    fi

    rm -rf "${temp_root}"
}

# --- Test: Docker container test (if Docker available) ---
test_in_container() {
    if ! check_docker; then
        record_skip "Docker 容器测试（Docker 不可用）"
        return
    fi

    info "=== Docker 容器测试 ==="
    local docker_mount_dir="${SCRIPT_DIR}"
    local docker_pull_log=""
    local apt_log=""

    if command -v cygpath >/dev/null 2>&1; then
        docker_mount_dir="$(cygpath -m "${SCRIPT_DIR}")"
    fi

    cleanup_test_containers

    if ! MSYS_NO_PATHCONV=1 docker image inspect "${DOCKER_IMAGE}" >/dev/null 2>&1; then
        docker_pull_log="$(mktemp)"
        if ! MSYS_NO_PATHCONV=1 docker pull "${DOCKER_IMAGE}" >"${docker_pull_log}" 2>&1; then
            if is_external_network_failure "${docker_pull_log}"; then
                record_skip "Docker 容器测试（镜像拉取受环境网络限制）"
            else
                cat "${docker_pull_log}" >&2
                record_fail "容器镜像拉取失败"
            fi
            rm -f "${docker_pull_log}"
            cleanup_test_containers
            return
        fi
        rm -f "${docker_pull_log}"
    fi

    # Start container
    if ! MSYS_NO_PATHCONV=1 docker run -d --name "$CONTAINER_NAME" \
        -v "${docker_mount_dir}:/opt/bifrost:ro" \
        "$DOCKER_IMAGE" \
        sleep infinity; then
        record_fail "容器启动失败"
        cleanup_test_containers
        return
    fi

    # Install runtime dependencies in container
    apt_log="$(mktemp)"
    if ! MSYS_NO_PATHCONV=1 docker exec "$CONTAINER_NAME" apt-get update -qq >"${apt_log}" 2>&1; then
        if is_external_network_failure "${apt_log}"; then
            record_skip "Docker 容器测试（apt-get update 受环境网络限制）"
        else
            cat "${apt_log}" >&2
            record_fail "容器内 apt-get update"
        fi
        rm -f "${apt_log}"
        cleanup_test_containers
        return
    fi
    rm -f "${apt_log}"

    apt_log="$(mktemp)"
    if ! MSYS_NO_PATHCONV=1 docker exec "$CONTAINER_NAME" apt-get install -y -qq bash curl procps findutils gawk >"${apt_log}" 2>&1; then
        if is_external_network_failure "${apt_log}"; then
            record_skip "Docker 容器测试（apt-get install 受环境网络限制）"
        else
            cat "${apt_log}" >&2
            record_fail "容器内 apt-get install"
        fi
        rm -f "${apt_log}"
        cleanup_test_containers
        return
    fi
    rm -f "${apt_log}"

    # Test 1: bash -n in container
    if MSYS_NO_PATHCONV=1 docker exec "$CONTAINER_NAME" bash -n /opt/bifrost/install.sh; then
        record_pass "容器内 bash -n: install.sh"
    else
        record_fail "容器内 bash -n: install.sh"
    fi

    if MSYS_NO_PATHCONV=1 docker exec "$CONTAINER_NAME" bash -n /opt/bifrost/scripts/health-check.sh; then
        record_pass "容器内 bash -n: health-check.sh"
    else
        record_fail "容器内 bash -n: health-check.sh"
    fi

    # Test 2: Source common.sh and test detect_system
    if MSYS_NO_PATHCONV=1 docker exec "$CONTAINER_NAME" bash -c '
        source /opt/bifrost/scripts/common.sh 2>/dev/null
        detect_system
        echo "OS_ID=${OS_ID:-unknown}"
        [[ -n "${OS_ID:-}" ]]
    '; then
        record_pass "容器内 detect_system()"
    else
        record_fail "容器内 detect_system()"
    fi

    # Test 3: show_help
    if MSYS_NO_PATHCONV=1 docker exec "$CONTAINER_NAME" bash /opt/bifrost/install.sh --help 2>/dev/null | grep -q "Bifrost"; then
        record_pass "容器内 --help"
    else
        record_fail "容器内 --help"
    fi

    if [[ "$(MSYS_NO_PATHCONV=1 docker exec "$CONTAINER_NAME" bash /opt/bifrost/install.sh --help 2>/dev/null | sed -n '1p')" == "Bifrost v2.0 - 一键部署脚本" ]]; then
        record_pass "容器内 --help 首行干净"
    else
        record_fail "容器内 --help 首行被启动噪音污染"
    fi

    # Test 4: --version
    if MSYS_NO_PATHCONV=1 docker exec "$CONTAINER_NAME" bash /opt/bifrost/install.sh --version 2>/dev/null | grep -q "2.0.0"; then
        record_pass "容器内 --version (2.0.0)"
    else
        record_fail "容器内 --version"
    fi

    if [[ "$(MSYS_NO_PATHCONV=1 docker exec "$CONTAINER_NAME" bash /opt/bifrost/install.sh --version 2>/dev/null)" == "Bifrost v2.0.0" ]]; then
        record_pass "容器内 --version 输出干净"
    else
        record_fail "容器内 --version 输出被启动噪音污染"
    fi

    if MSYS_NO_PATHCONV=1 docker exec "$CONTAINER_NAME" bash /opt/bifrost/scripts/health-check.sh --help 2>/dev/null | grep -q "Standalone Health Check Script"; then
        record_pass "容器内 health-check --help"
    else
        record_fail "容器内 health-check --help"
    fi

    if MSYS_NO_PATHCONV=1 docker exec "$CONTAINER_NAME" bash -lc '
        status=0
        bash /opt/bifrost/scripts/health-check.sh --verbose >/tmp/health.out 2>/tmp/health.err || status=$?
        if [[ "$status" -ne 0 && "$status" -ne 1 && "$status" -ne 2 ]]; then
            cat /tmp/health.err >&2
            exit 1
        fi
        test -f /var/log/bifrost/health.json
        grep -q "\"bifrost_api\"" /var/log/bifrost/health.json
        grep -q "\"caddy\"" /var/log/bifrost/health.json
        grep -q "\"public_manage\"" /var/log/bifrost/health.json
    '; then
        record_pass "容器内 health-check smoke + report"
    else
        record_fail "容器内 health-check smoke + report"
    fi

    # Cleanup
    cleanup_test_containers
}

# --- Run tests ---
main() {
    echo "============================================"
    echo "  Bifrost - 测试套件"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================"
    echo ""

    case "$TEST_NAME" in
        syntax)     test_syntax ;;
        functions)  test_functions ;;
        configs)    test_configs ;;
        security)   test_security_contracts; test_bridge_security_contracts ;;
        ports)      test_ports ;;
        menu)       test_menu ;;
        mihomo)     test_mihomo_contracts; test_bridge_mihomo_contracts ;;
        xray)       test_xray_contracts; test_bridge_xray_contracts ;;
        deploy)     test_server_a_deploy_contracts; test_bridge_server_a_deploy_contracts; test_server_b_deploy_contracts; test_bridge_server_b_deploy_contracts; test_caddy_exposure_generation_contracts; test_install_deploy_entrypoint_contracts; test_dd_reinstall_contracts; test_bridge_dd_reinstall_contracts ;;
        dd)         test_dd_reinstall_contracts; test_bridge_dd_reinstall_contracts ;;
        keepalive)  test_keepalive_contracts; test_bridge_keepalive_contracts ;;
        vpn)        test_vpn_contracts; test_bridge_vpn_contracts; test_vpn_deploy_contracts; test_bridge_vpn_deploy_contracts ;;
        multi)      test_multi_server_contracts; test_bridge_multi_server_contracts ;;
        user)       test_user_management_contracts; test_bridge_user_management_contracts ;;
        whitelist)  test_whitelist_contracts; test_bridge_whitelist_contracts ;;
        monitoring) test_monitoring_contracts; test_bridge_monitoring_contracts ;;
        diagnostics) test_diagnostics_contracts; test_bridge_diagnostics_contracts ;;
        update)     test_update_contracts; test_bridge_update_contracts ;;
        backup)     test_backup_contracts; test_bridge_backup_contracts ;;
        uninstall)  test_uninstall_contracts; test_bridge_uninstall_contracts ;;
        supply)     test_supply_chain_contracts; test_bridge_supply_chain_contracts ;;
        panel)      test_server_b_panel_contracts; test_bridge_server_b_panel_contracts ;;
        docs)       test_docs ;;
        bifrost)    test_bifrost_api_contracts; test_bifrost_shell_contracts ;;
        distribution) test_distribution_contracts ;;
        marketplace_skeleton) test_marketplace_skeleton_contracts ;;
        docker)     test_in_container ;;
        all)
            test_syntax
            echo ""
            test_functions
            echo ""
            test_configs
            echo ""
            test_mihomo_contracts
            echo ""
            test_bridge_mihomo_contracts
            echo ""
            test_xray_contracts
            echo ""
            test_bridge_xray_contracts
            echo ""
            test_server_a_deploy_contracts
            echo ""
            test_bridge_server_a_deploy_contracts
            echo ""
            test_server_b_deploy_contracts
            echo ""
            test_bridge_server_b_deploy_contracts
            echo ""
            test_caddy_exposure_generation_contracts
            echo ""
            test_install_deploy_entrypoint_contracts
            echo ""
            test_dd_reinstall_contracts
            echo ""
            test_bridge_dd_reinstall_contracts
            echo ""
            test_security_contracts
            echo ""
            test_bridge_security_contracts
            echo ""
            test_keepalive_contracts
            echo ""
            test_bridge_keepalive_contracts
            echo ""
            test_vpn_contracts
            echo ""
            test_bridge_vpn_contracts
            echo ""
            test_vpn_deploy_contracts
            echo ""
            test_bridge_vpn_deploy_contracts
            echo ""
            test_multi_server_contracts
            echo ""
            test_bridge_multi_server_contracts
            echo ""
            test_user_management_contracts
            echo ""
            test_bridge_user_management_contracts
            echo ""
            test_whitelist_contracts
            echo ""
            test_bridge_whitelist_contracts
            echo ""
            test_monitoring_contracts
            echo ""
            test_bridge_monitoring_contracts
            echo ""
            test_diagnostics_contracts
            echo ""
            test_bridge_diagnostics_contracts
            echo ""
            test_update_contracts
            echo ""
            test_bridge_update_contracts
            echo ""
            test_backup_contracts
            echo ""
            test_bridge_backup_contracts
            echo ""
            test_uninstall_contracts
            echo ""
            test_bridge_uninstall_contracts
            echo ""
            test_supply_chain_contracts
            echo ""
            test_bridge_supply_chain_contracts
            echo ""
            test_server_b_panel_contracts
            echo ""
            test_bridge_server_b_panel_contracts
            echo ""
            test_ports
            echo ""
            test_menu
            echo ""
            test_docs
            echo ""
            test_bifrost_api_contracts
            echo ""
            test_bifrost_shell_contracts
            echo ""
            test_distribution_contracts
            echo ""
            test_marketplace_skeleton_contracts
            echo ""
            test_in_container
            ;;
        *)
            echo "用法: $0 [syntax|functions|configs|security|mihomo|xray|deploy|keepalive|multi|user|whitelist|monitoring|diagnostics|update|backup|uninstall|supply|panel|ports|menu|docs|bifrost|distribution|marketplace_skeleton|docker|all]"
            exit 1
            ;;
    esac

    echo ""
    echo "============================================"
    echo "  测试结果: ${PASS_COUNT} 通过, ${FAIL_COUNT} 失败, ${SKIP_COUNT} 跳过"
    echo "============================================"

    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        exit 1
    fi
}

main
