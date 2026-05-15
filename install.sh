#!/usr/bin/env bash
# =============================================================================
# Bifrost - 一键部署脚本
# 国内外 AI 服务桥接解决方案
#
# 架构: 员工设备 → WireGuard VPN → 国内服务器A (VPN Gateway + Caddy + New API + Mihomo + Xray Client)
#    ↕ VLESS+Reality 加密隧道
#        海外服务器B (Xray Server + 3x-ui + Caddy)
#    ↕
#        AI API (Claude/GPT/Gemini/DeepSeek...)
#
# 支持系统: Ubuntu 22.04+, Debian 12+, CentOS 9+, Rocky 9+, AlmaLinux 9+
# 用途: 为中小企业 (30-100人) 提供安全的 AI 工具访问
# =============================================================================

set -euo pipefail

# --- Constants ---
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_VERSION="2.0.0"
readonly PROJECT_NAME="Bifrost"
readonly CONFIG_DIR="/opt/bifrost"
readonly LOG_DIR="/var/log/bifrost"

# --- Source modules ---
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/scripts/common.sh"

run_flow_command() {
    local failure_message="$1"
    shift
    "$@" && return 0
    local status=$?
    log_error "${failure_message}"
    return "${status}"
}

run_cli_command() {
    local failure_message="$1"
    shift
    "$@" && exit 0
    local status=$?
    log_error "${failure_message}"
    exit "${status}"
}

# --- Main Menu ---
show_main_menu() {
    print_banner "${PROJECT_NAME} v${SCRIPT_VERSION}"
    echo ""
    log_info "欢迎使用 ${PROJECT_NAME} 一键部署脚本"
    log_info "本工具将帮助你快速搭建国内外 AI 服务桥接环境"
    echo ""

    print_section "系统信息"
    detect_system
    print_system_summary
    echo ""

    print_section "请选择操作"
    local options=(
        "部署海外服务器 (Server B) — Xray 服务端 + 3x-ui + AI 网关"
        "部署国内服务器 (Server A) — Xray 客户端 + New API + Caddy"
        "仅执行安全加固"
        "仅部署监控系统 (Netdata)"
        "白名单管理"
        "系统健康检查"
        "查看连接信息"
        "DD 系统重装 (云环境就绪审查)"
        "企业 VPN 部署 (WireGuard/OpenVPN)"
        "DPI 防护部署 (反深包检测)"
        "Mihomo 智能路由部署"
        "连接保活部署 (Keepalive + Watchdog)"
        "网络分流部署 (Split Tunnel)"
        "备份与恢复管理"
        "组件更新管理"
        "多节点 Server B 管理"
        "用户管理 (VPN + API)"
        "管理平台部署 (Bifrost API 注册/监控)"
        "深度诊断 (网络/服务/GFW检测)"
        "卸载所有组件"
        "退出"
    )
    show_menu "主菜单" options

    case "${MENU_RESULT}" in
        1) deploy_server_b_flow ;;
        2) deploy_server_a_flow ;;
        3) security_only_flow ;;
        4) monitoring_only_flow ;;
        5) whitelist_flow ;;
        6) health_check_flow ;;
        7) show_connection_info ;;
        8) dd_reinstall_flow ;;
        9) vpn_flow ;;
        10) anti_dpi_flow ;;
        11) mihomo_flow ;;
        12) keepalive_flow ;;
        13) split_tunnel_flow ;;
        14) backup_flow ;;
        15) update_flow ;;
        16) multi_server_flow ;;
        17) user_management_flow ;;
        18) bifrost_api_flow ;;
        19) diagnostics_flow ;;
        20) uninstall_flow ;;
        21) log_info "再见！"; exit 0 ;;
        *) log_error "无效选择"; show_main_menu ;;
    esac
}

# --- Flow: Deploy Server B (Overseas) ---
deploy_server_b_flow() {
    print_banner "部署海外服务器 (Server B)"
    echo ""
    log_info "Server B 将部署以下组件："
    echo "  1. 云环境就绪审查 (预部署检查)"
    echo "  2. 系统安全加固 (防火墙/SSH/fail2ban/内核加固)"
    echo "  3. Xray 服务端 (VLESS+Reality)"
    echo "  4. 3x-ui 管理面板 (可选)"
    echo "  5. Hysteria 2 备用隧道 (可选)"
    echo "  6. Caddy 反向代理 + 伪装网站"
    echo "  7. BBR 拥塞控制优化"
    echo "  8. DPI 防护 (反深包检测)"
    echo "  9. 连接保活 (Keepalive + Watchdog)"
    echo "  10. Netdata 监控"
    echo ""

    if ! confirm_action "确认开始部署 Server B？" "y"; then
        show_main_menu
        return
    fi

    require_root

    # Create config directory
    mkdir -p "${CONFIG_DIR}" "${LOG_DIR}"

    # Source and run server-b deployment
    # shellcheck source=scripts/security.sh
    source "${SCRIPT_DIR}/scripts/security.sh"
    # shellcheck source=scripts/server-b.sh
    source "${SCRIPT_DIR}/scripts/server-b.sh"
    # shellcheck source=scripts/monitoring.sh
    source "${SCRIPT_DIR}/scripts/monitoring.sh"

    if ! deploy_server_b; then
        echo ""
        print_section "部署失败"
        log_error "Server B 部署未完成，请先处理上方失败步骤后再继续。"
        return 1
    fi

    echo ""
    print_section "部署完成"
    log_success "Server B 部署成功！"
    log_info "请保存上方显示的连接信息，部署 Server A 时需要使用"
    log_info "连接信息已保存到: /root/ai-gateway-connection.txt"
    echo ""
    log_warn "重要提醒："
    echo "  1. 请在新终端测试 SSH 连接是否正常"
    echo "  2. 请记录 Xray 连接参数（UUID、PublicKey 等）"
    echo "  3. 接下来请在国内服务器上运行本脚本选择 '部署国内服务器'"
}

# --- Flow: Deploy Server A (China) ---
deploy_server_a_flow() {
    print_banner "部署国内服务器 (Server A)"
    echo ""
    log_info "Server A 将部署以下组件："
    echo "  1. 云环境就绪审查 (预部署检查)"
    echo "  2. 系统安全加固 (防火墙/SSH/fail2ban/内核加固)"
    echo "  3. Xray 客户端 (VLESS+Reality → 连接 Server B)"
    echo "  4. Mihomo 智能路由引擎"
    echo "  5. New API AI 网关 (Docker)"
    echo "  6. Caddy 反向代理 + 伪装网站"
    echo "  7. 企业 VPN (WireGuard/Firezone, 可选)"
    echo "  8. 连接保活 (Keepalive + Watchdog)"
    echo "  9. 网络分流 (Split Tunnel)"
    echo "  10. Netdata 监控"
    echo ""
    log_warn "前提条件："
    echo "  - Server B 已部署完成"
    echo "  - 已获取 Server B 的连接信息 (UUID/PublicKey/IP/Port)"
    echo "  - (推荐) 已准备 ICP 备案域名"
    echo ""

    if ! confirm_action "确认 Server B 已部署且连接信息已就绪？" "y"; then
        show_main_menu
        return
    fi

    require_root

    # Create config directory
    mkdir -p "${CONFIG_DIR}" "${LOG_DIR}"

    # Source and run server-a deployment
    # shellcheck source=scripts/security.sh
    source "${SCRIPT_DIR}/scripts/security.sh"
    # shellcheck source=scripts/server-a.sh
    source "${SCRIPT_DIR}/scripts/server-a.sh"
    # shellcheck source=scripts/monitoring.sh
    source "${SCRIPT_DIR}/scripts/monitoring.sh"

    if ! deploy_server_a; then
        echo ""
        print_section "部署失败"
        log_error "Server A 部署未完成，请先处理上方失败步骤后再继续。"
        return 1
    fi

    if [[ -f "${SCRIPT_DIR}/scripts/bifrost-api.sh" ]]; then
        echo ""
        if confirm_action "是否继续部署 Bifrost 管理平台 (/manage 注册/监控)？" "y"; then
            # shellcheck source=scripts/bifrost-api.sh
            source "${SCRIPT_DIR}/scripts/bifrost-api.sh"
            if ! deploy_bifrost_api; then
                echo ""
                print_section "部署失败"
                log_error "Bifrost 管理平台部署未完成，请先处理上方失败步骤。"
                return 1
            fi
        else
            log_info "已跳过 Bifrost 管理平台部署。后续可运行 ./install.sh --bifrost-api"
        fi
    fi

    echo ""
    print_section "部署完成"
    log_success "Server A 部署成功！"
    echo ""
    log_info "用户配置指南："
    echo ""
    echo "  === Claude Code ==="
    echo "  export ANTHROPIC_BASE_URL=https://your-domain.com"
    echo "  export ANTHROPIC_API_KEY=<从 New API 面板获取>"
    echo ""
    echo "  === Codex CLI ==="
    echo "  export OPENAI_BASE_URL=https://your-domain.com/v1"
    echo "  export OPENAI_API_KEY=<从 New API 面板获取>"
    echo ""
    echo "  === OpenCode / 其他 OpenAI 兼容工具 ==="
    echo "  export OPENAI_BASE_URL=https://your-domain.com/v1"
    echo "  export OPENAI_API_KEY=<从 New API 面板获取>"
    echo ""
    log_info "详细配置说明请参阅: docs/CLIENT-SETUP.md"
}

# --- Flow: Security Only ---
security_only_flow() {
    print_banner "安全加固"
    require_root

    # shellcheck source=scripts/security.sh
    source "${SCRIPT_DIR}/scripts/security.sh"

    print_section "选择加固模块"
    local sec_options=(
        "完整安全加固 (推荐)"
        "仅 SSH 加固"
        "仅防火墙配置"
        "仅 fail2ban 部署"
        "仅内核安全参数"
        "仅安全工具安装 (Lynis/rkhunter)"
        "运行安全审计"
        "返回主菜单"
    )
    show_menu "安全加固" sec_options

    case "${MENU_RESULT}" in
        1) run_flow_command "完整安全加固失败，请先处理上方错误。" full_security_hardening || return $? ;;
        2) run_flow_command "SSH 加固失败，请先处理上方错误。" harden_ssh || return $? ;;
        3) run_flow_command "防火墙配置失败，请先处理上方错误。" setup_firewall || return $? ;;
        4) run_flow_command "fail2ban 部署失败，请先处理上方错误。" setup_fail2ban || return $? ;;
        5) run_flow_command "内核安全参数配置失败，请先处理上方错误。" harden_kernel || return $? ;;
        6) run_flow_command "安全工具安装失败，请先处理上方错误。" install_security_tools || return $? ;;
        7) run_flow_command "安全审计执行失败，请先处理上方错误。" run_security_audit || return $? ;;
        8) show_main_menu; return ;;
    esac

    log_success "安全加固完成"
}

# --- Flow: Monitoring Only ---
monitoring_only_flow() {
    print_banner "监控部署"
    require_root

    # shellcheck source=scripts/monitoring.sh
    source "${SCRIPT_DIR}/scripts/monitoring.sh"

    if ! deploy_monitoring; then
        log_error "监控系统部署未完成，请先处理上方错误。"
        return 1
    fi

    log_success "监控系统部署完成"
    log_info "Netdata 面板: http://127.0.0.1:19999 (仅本地访问，如需远程请通过 SSH 隧道)"
}

# --- Flow: Whitelist Management ---
whitelist_flow() {
    # shellcheck source=scripts/whitelist.sh
    source "${SCRIPT_DIR}/scripts/whitelist.sh"

    if ! manage_whitelist; then
        log_error "白名单管理执行失败，请先处理上方错误。"
        return 1
    fi
}

# --- Flow: Health Check ---
health_check_flow() {
    print_banner "系统健康检查"

    if [[ -f "${SCRIPT_DIR}/scripts/health-check.sh" ]]; then
        if ! bash "${SCRIPT_DIR}/scripts/health-check.sh" --verbose; then
            log_error "健康检查失败，请先处理上方错误。"
            return 1
        fi
    else
        log_error "健康检查脚本不存在"
        return 1
    fi
}

# --- Flow: Show Connection Info ---
show_connection_info() {
    print_banner "连接信息"

    if [[ -f /root/ai-gateway-connection.txt ]]; then
        print_section "Server B 连接信息"
        # Filter out the private key when displaying connection info
        grep -v '^PRIVATE_KEY=' /root/ai-gateway-connection.txt
        echo ""
        log_warn "PRIVATE_KEY 已隐藏 (仅存储在文件中，使用 cat /root/ai-gateway-connection.txt 查看)"
    else
        log_warn "未找到 Server B 连接信息文件"
    fi

    if [[ -f /root/server-b-connection.conf ]]; then
        print_section "Server B 连接配置"
        cat /root/server-b-connection.conf
    fi

    # Check New API
    if command -v docker &>/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "new-api"; then
        print_section "New API 状态"
        docker ps --filter name=new-api --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        echo ""
        log_info "New API 面板: http://localhost:3000"
    fi

    # Check Xray
    if systemctl is-active --quiet xray 2>/dev/null; then
        print_section "Xray 状态"
        log_success "Xray 服务运行中"
        systemctl status xray --no-pager -l 2>/dev/null | head -5
    fi

    # Check 3x-ui
    if systemctl is-active --quiet x-ui 2>/dev/null; then
        print_section "3x-ui 状态"
        log_success "3x-ui 服务运行中"
    fi

    echo ""
    log_info "按回车返回主菜单..."
    read -r
    show_main_menu
}

# --- Flow: DD Reinstall ---
dd_reinstall_flow() {
    print_banner "DD 系统重装 / 云环境就绪审查"
    require_root

    # shellcheck source=scripts/dd-reinstall.sh
    source "${SCRIPT_DIR}/scripts/dd-reinstall.sh"

    if ! pre_deploy_check; then
        log_error "预部署云环境审查未完成，请先处理上方错误。"
        return 1
    fi

    if declare -f cloud_review_blocks_deployment >/dev/null 2>&1 && cloud_review_blocks_deployment; then
        if declare -f cloud_review_is_report_only >/dev/null 2>&1 && cloud_review_is_report_only; then
            log_success "云环境 report-only 审查已完成；请先审阅报告，再用交互模式继续部署或选择 Full DD Reinstall。"
            return 0
        fi
        log_error "${CLOUD_REVIEW_DEPLOYMENT_BLOCK_REASON:-预部署云环境审查未完成，请先处理上方错误。}"
        return 1
    fi
}

# --- Flow: VPN ---
vpn_flow() {
    print_banner "企业 VPN 部署"
    require_root

    # shellcheck source=scripts/vpn.sh
    source "${SCRIPT_DIR}/scripts/vpn.sh"

    if ! deploy_vpn; then
        log_error "VPN 部署未完成，请先处理上方错误。"
        return 1
    fi
}

# --- Flow: Anti-DPI ---
anti_dpi_flow() {
    print_banner "DPI 防护部署"
    require_root

    # shellcheck source=scripts/anti-dpi.sh
    source "${SCRIPT_DIR}/scripts/anti-dpi.sh"

    if ! deploy_anti_dpi; then
        log_error "DPI 防护部署未完成，请先处理上方错误。"
        return 1
    fi
}

# --- Flow: Mihomo ---
mihomo_flow() {
    print_banner "Mihomo 智能路由部署"
    require_root

    # shellcheck source=scripts/mihomo.sh
    source "${SCRIPT_DIR}/scripts/mihomo.sh"

    if ! deploy_mihomo; then
        log_error "Mihomo 部署未完成，请先处理上方错误。"
        return 1
    fi
}

# --- Flow: Keepalive ---
keepalive_flow() {
    print_banner "连接保活部署"
    require_root

    # shellcheck source=scripts/keepalive.sh
    source "${SCRIPT_DIR}/scripts/keepalive.sh"

    if ! deploy_keepalive; then
        log_error "Keepalive 部署未完成，请先处理上方错误。"
        return 1
    fi
}

# --- Flow: Split Tunnel ---
split_tunnel_flow() {
    print_banner "网络分流部署"
    require_root

    # shellcheck source=scripts/split-tunnel.sh
    source "${SCRIPT_DIR}/scripts/split-tunnel.sh"

    if ! deploy_split_tunnel; then
        log_error "网络分流部署未完成，请先处理上方错误。"
        return 1
    fi
}

# --- Flow: Backup ---
backup_flow() {
    print_banner "备份与恢复管理"
    require_root

    # shellcheck source=scripts/backup.sh
    source "${SCRIPT_DIR}/scripts/backup.sh"

    if ! manage_backups; then
        log_error "备份与恢复管理执行失败，请先处理上方错误。"
        return 1
    fi
}

# --- Flow: Update ---
update_flow() {
    print_banner "组件更新管理"
    require_root

    # shellcheck source=scripts/update.sh
    source "${SCRIPT_DIR}/scripts/update.sh"

    if ! manage_updates; then
        log_error "组件更新管理执行失败，请先处理上方错误。"
        return 1
    fi
}

# --- Flow: Multi Server ---
multi_server_flow() {
    print_banner "多节点 Server B 管理"
    require_root

    # shellcheck source=scripts/multi-server.sh
    source "${SCRIPT_DIR}/scripts/multi-server.sh"

    if ! manage_servers; then
        log_error "多节点 Server B 管理执行失败，请先处理上方错误。"
        return 1
    fi
}

# --- Flow: User Management ---
user_management_flow() {
    print_banner "用户管理"
    require_root

    # shellcheck source=scripts/user-management.sh
    source "${SCRIPT_DIR}/scripts/user-management.sh"

    if ! manage_users; then
        log_error "用户管理执行失败，请先处理上方错误。"
        return 1
    fi
}

# --- Flow: Bifrost API Management Platform ---
bifrost_api_flow() {
    print_banner "管理平台部署 (Bifrost API)"
    require_root

    # shellcheck source=scripts/bifrost-api.sh
    source "${SCRIPT_DIR}/scripts/bifrost-api.sh"

    if ! deploy_bifrost_api; then
        log_error "Bifrost 管理平台部署未完成，请先处理上方错误。"
        return 1
    fi
}

# --- Flow: Diagnostics ---
diagnostics_flow() {
    print_banner "深度诊断"

    # shellcheck source=scripts/diagnostics.sh
    source "${SCRIPT_DIR}/scripts/diagnostics.sh"

    if ! manage_diagnostics; then
        log_error "深度诊断执行失败，请先处理上方错误。"
        return 1
    fi
}

# --- Flow: Uninstall ---
uninstall_flow() {
    print_banner "卸载"
    require_root

    # shellcheck source=scripts/uninstall.sh
    source "${SCRIPT_DIR}/scripts/uninstall.sh"

    if ! uninstall_all; then
        log_error "卸载未完成，请先处理上方错误。"
        return 1
    fi
}

# --- Argument Parsing ---
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server-a)
                require_root
                source "${SCRIPT_DIR}/scripts/security.sh"
                source "${SCRIPT_DIR}/scripts/server-a.sh"
                source "${SCRIPT_DIR}/scripts/monitoring.sh"
                deploy_server_a || exit 1
                exit 0
                ;;
            --server-b)
                require_root
                source "${SCRIPT_DIR}/scripts/security.sh"
                source "${SCRIPT_DIR}/scripts/server-b.sh"
                source "${SCRIPT_DIR}/scripts/monitoring.sh"
                deploy_server_b || exit 1
                exit 0
                ;;
            --security)
                require_root
                source "${SCRIPT_DIR}/scripts/security.sh"
                run_cli_command "安全加固失败，请先处理上方错误。" full_security_hardening
                ;;
            --health-check)
                run_cli_command "健康检查失败，请先处理上方错误。" bash "${SCRIPT_DIR}/scripts/health-check.sh" --verbose
                ;;
            --uninstall)
                require_root
                source "${SCRIPT_DIR}/scripts/uninstall.sh"
                run_cli_command "卸载未完成，请先处理上方错误。" uninstall_all
                ;;
            --vpn)
                require_root
                source "${SCRIPT_DIR}/scripts/vpn.sh"
                run_cli_command "VPN 部署未完成，请先处理上方错误。" deploy_vpn
                ;;
            --anti-dpi)
                require_root
                source "${SCRIPT_DIR}/scripts/anti-dpi.sh"
                run_cli_command "DPI 防护部署未完成，请先处理上方错误。" deploy_anti_dpi
                ;;
            --mihomo)
                require_root
                source "${SCRIPT_DIR}/scripts/mihomo.sh"
                run_cli_command "Mihomo 部署未完成，请先处理上方错误。" deploy_mihomo
                ;;
            --keepalive)
                require_root
                source "${SCRIPT_DIR}/scripts/keepalive.sh"
                run_cli_command "Keepalive 部署未完成，请先处理上方错误。" deploy_keepalive
                ;;
            --split-tunnel)
                require_root
                source "${SCRIPT_DIR}/scripts/split-tunnel.sh"
                run_cli_command "网络分流部署未完成，请先处理上方错误。" deploy_split_tunnel
                ;;
            --backup)
                require_root
                source "${SCRIPT_DIR}/scripts/backup.sh"
                run_cli_command "备份与恢复管理执行失败，请先处理上方错误。" manage_backups
                ;;
            --update)
                require_root
                source "${SCRIPT_DIR}/scripts/update.sh"
                run_cli_command "组件更新管理执行失败，请先处理上方错误。" manage_updates
                ;;
            --multi-server)
                require_root
                source "${SCRIPT_DIR}/scripts/multi-server.sh"
                run_cli_command "多节点 Server B 管理执行失败，请先处理上方错误。" manage_servers
                ;;
            --user-mgmt)
                require_root
                source "${SCRIPT_DIR}/scripts/user-management.sh"
                run_cli_command "用户管理执行失败，请先处理上方错误。" manage_users
                ;;
            --bifrost-api)
                require_root
                source "${SCRIPT_DIR}/scripts/bifrost-api.sh"
                run_cli_command "Bifrost 管理平台部署未完成，请先处理上方错误。" deploy_bifrost_api
                ;;
            --diagnostics)
                source "${SCRIPT_DIR}/scripts/diagnostics.sh"
                run_cli_command "深度诊断执行失败，请先处理上方错误。" manage_diagnostics
                ;;
            --dd-reinstall|--cloud-review)
                require_root
                source "${SCRIPT_DIR}/scripts/dd-reinstall.sh"
                local review_args=()
                if [[ "$1" == "--cloud-review" ]]; then
                    review_args+=(--report-only)
                fi
                if [[ "${2:-}" == "--report-only" ]]; then
                    review_args+=(--report-only)
                    shift
                fi
                run_cli_command "预部署云环境审查未完成，请先处理上方错误。" pre_deploy_check "${review_args[@]+"${review_args[@]}"}"
                ;;
            --report-only)
                log_error "--report-only 只能与 --dd-reinstall 或 --cloud-review 一起使用。"
                show_help
                exit 1
                ;;
            --version)
                echo "${PROJECT_NAME} v${SCRIPT_VERSION}"
                exit 0
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done
}

# --- Help ---
show_help() {
    cat <<'HELP'
Bifrost v2.0 - 一键部署脚本

用法:
  ./install.sh                交互式菜单 (推荐)

基础部署:
  ./install.sh --server-b     非交互式部署海外服务器
  ./install.sh --server-a     非交互式部署国内服务器
  ./install.sh --security     仅执行安全加固
  ./install.sh --dd-reinstall [--report-only]
                            DD 系统重装 / 云环境就绪审查
  ./install.sh --cloud-review 无交互首轮云环境审查（只检测、导出报告、不进入 DD 菜单）

v2.0 模块部署:
  ./install.sh --vpn          部署企业 VPN (WireGuard/Firezone/Headscale)
  ./install.sh --anti-dpi     部署 DPI 防护 (dest 轮换/uTLS/Mux)
  ./install.sh --mihomo       部署 Mihomo 智能路由引擎
  ./install.sh --keepalive    部署连接保活 (Keepalive + Watchdog)
  ./install.sh --split-tunnel 部署网络分流 (Split Tunnel)
  ./install.sh --bifrost-api  部署管理平台 (Bifrost API 注册/监控)

运维管理:
  ./install.sh --backup       备份与恢复管理
  ./install.sh --update       组件更新管理
  ./install.sh --multi-server 多节点 Server B 管理
  ./install.sh --user-mgmt    用户管理 (VPN + API)
  ./install.sh --diagnostics  深度诊断 (网络/服务/GFW 检测)
  ./install.sh --health-check 运行健康检查
  ./install.sh --uninstall    卸载所有组件

其他:
  ./install.sh --version      显示版本
  ./install.sh --help         显示帮助

推荐部署顺序:
  0. (推荐先做) 首轮云审查: ./install.sh --cloud-review
     或: BIFROST_CLOUD_REVIEW_MODE=report ./install.sh --dd-reinstall
  0b. (可选) 交互式 DD / 审查: ./install.sh --dd-reinstall
  1. 海外服务器: ./install.sh --server-b + --anti-dpi
  2. 国内服务器: ./install.sh --server-a
  3. 管理平台:   ./install.sh --bifrost-api
  4. 部署 VPN:   ./install.sh --vpn
  5. 部署路由:   ./install.sh --mihomo
  6. 部署增强:   ./install.sh --keepalive --split-tunnel --backup
  7. 创建用户:   ./install.sh --user-mgmt

支持系统:
  Ubuntu 22.04 / 24.04 LTS
  Debian 12+
  CentOS 9 / Rocky Linux 9 / AlmaLinux 9

文档:
  docs/USAGE.md             使用说明 (含 v2 完整部署流程)
  docs/VPN-SETUP.md         企业 VPN 部署与员工入职指南
  docs/CLIENT-SETUP.md      客户端配置 (VPN + AI 工具)
  docs/TROUBLESHOOTING.md   疑难排查 (含 VPN/Mihomo/DPI/Keepalive)
  docs/SECURITY.md          安全说明

项目地址: https://github.com/ZRainbow1275/bifrost
HELP
}

# --- Entry Point ---
main() {
    # Ensure we're in the script directory
    cd "${SCRIPT_DIR}"

    if [[ $# -gt 0 ]]; then
        parse_args "$@"
    else
        # Interactive mode
        mkdir -p "${CONFIG_DIR}" "${LOG_DIR}" 2>/dev/null || true
        detect_system
        show_main_menu
    fi
}

main "$@"
