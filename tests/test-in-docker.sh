#!/usr/bin/env bash
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
info() { echo -e "${YELLOW}[TEST]${NC} $*"; }

PASS_COUNT=0
FAIL_COUNT=0

record_pass() { ((PASS_COUNT++)); pass "$*"; }
record_fail() { ((FAIL_COUNT++)); fail "$*"; }

# --- Check Docker ---
check_docker() {
    if ! command -v docker &>/dev/null; then
        echo "Docker 未安装，跳过容器测试。仅运行本地测试。"
        return 1
    fi
    docker info &>/dev/null || { echo "Docker 未运行"; return 1; }
    return 0
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
        "scripts/common.sh:generate_uuid"
        "scripts/common.sh:generate_x25519_keypair"
        "scripts/common.sh:template_render"
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

    for arg in "${cli_args[@]}"; do
        if grep -q "\"${arg}\"\\|'${arg}'" "$install_sh"; then
            record_pass "CLI 参数: ${arg}"
        else
            record_fail "CLI 参数缺失: ${arg}"
        fi
    done
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

# --- Test: Docker container test (if Docker available) ---
test_in_container() {
    if ! check_docker; then
        info "跳过 Docker 容器测试 (Docker 不可用)"
        return
    fi

    info "=== Docker 容器测试 ==="

    # Start container
    docker run -d --name "$CONTAINER_NAME" \
        -v "${SCRIPT_DIR}:/opt/bifrost:ro" \
        "$DOCKER_IMAGE" \
        tail -f /dev/null

    # Install bash in container
    docker exec "$CONTAINER_NAME" apt-get update -qq
    docker exec "$CONTAINER_NAME" apt-get install -y -qq bash curl >/dev/null 2>&1

    # Test 1: bash -n in container
    if docker exec "$CONTAINER_NAME" bash -n /opt/bifrost/install.sh; then
        record_pass "容器内 bash -n: install.sh"
    else
        record_fail "容器内 bash -n: install.sh"
    fi

    # Test 2: Source common.sh and test detect_system
    if docker exec "$CONTAINER_NAME" bash -c '
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
    if docker exec "$CONTAINER_NAME" bash /opt/bifrost/install.sh --help 2>/dev/null | grep -q "Bifrost"; then
        record_pass "容器内 --help"
    else
        record_fail "容器内 --help"
    fi

    # Test 4: --version
    if docker exec "$CONTAINER_NAME" bash /opt/bifrost/install.sh --version 2>/dev/null | grep -q "2.0.0"; then
        record_pass "容器内 --version (2.0.0)"
    else
        record_fail "容器内 --version"
    fi

    # Cleanup
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
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
        ports)      test_ports ;;
        menu)       test_menu ;;
        docs)       test_docs ;;
        docker)     test_in_container ;;
        all)
            test_syntax
            echo ""
            test_functions
            echo ""
            test_configs
            echo ""
            test_ports
            echo ""
            test_menu
            echo ""
            test_docs
            echo ""
            test_in_container
            ;;
        *)
            echo "用法: $0 [syntax|functions|configs|ports|menu|docs|docker|all]"
            exit 1
            ;;
    esac

    echo ""
    echo "============================================"
    echo "  测试结果: ${PASS_COUNT} 通过, ${FAIL_COUNT} 失败"
    echo "============================================"

    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        exit 1
    fi
}

main
