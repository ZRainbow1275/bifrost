#!/usr/bin/env bash
###############################################################################
# AI Gateway Bridge - Keepalive & Reliability Deployment Script
#
# Deploys connection keepalive and service reliability infrastructure:
#   1. TCP keepalive kernel parameters (sysctl)
#   2. Xray sockopt keepalive configuration (jq-based config patching)
#   3. Heartbeat probe service (systemd timer, 30s interval)
#   4. Service watchdog (continuous monitoring every 10s)
#
# These components work together to ensure tunnel stability for 30-100
# concurrent users in production. The keepalive system addresses:
#   - NAT mapping timeout on Chinese carrier networks (30-120s)
#   - Silent connection drops from middlebox interference
#   - Service crashes requiring immediate auto-recovery
#
# Usage: source this file from install.sh or run directly
#   bash scripts/keepalive.sh
#
# Dependencies: scripts/common.sh, jq
###############################################################################

set -euo pipefail

# Guard against double-sourcing (readonly variables would conflict)
if [[ -n "${_KEEPALIVE_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
readonly _KEEPALIVE_SH_LOADED=1

# Resolve the directory this script resides in
_KA_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_KA_PROJECT_DIR="$(cd "${_KA_SCRIPT_DIR}/.." && pwd)"

# Source common utilities
if [[ -f "${_KA_SCRIPT_DIR}/common.sh" ]]; then
    # shellcheck source=scripts/common.sh
    source "${_KA_SCRIPT_DIR}/common.sh"
else
    # Minimal fallback if common.sh is not available
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
    log_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
    log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
    log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
    log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
    die()         { log_error "$@"; exit 1; }
    confirm_action() {
        local prompt="${1:-Continue?}"
        read -r -p "${prompt} [y/N]: " response
        [[ "${response}" =~ ^[Yy]$ ]]
    }
fi

# Compatibility shims
if ! declare -f log_step >/dev/null 2>&1; then
    if declare -f print_section >/dev/null 2>&1; then
        log_step() { print_section "$*"; }
    else
        log_step() { log_info "[STEP] $*"; }
    fi
fi
if ! declare -f command_exists >/dev/null 2>&1; then
    if declare -f check_command >/dev/null 2>&1; then
        command_exists() { check_command "$1"; }
    else
        command_exists() { command -v "$1" &>/dev/null; }
    fi
fi
if ! declare -f install_if_missing >/dev/null 2>&1; then
    install_if_missing() {
        local cmd="${1}"
        local pkg="${2:-${cmd}}"
        if ! command -v "${cmd}" &>/dev/null; then
            log_info "Installing ${pkg}..."
            if command -v apt-get &>/dev/null; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkg}"
            elif command -v dnf &>/dev/null; then
                dnf install -y "${pkg}"
            elif command -v yum &>/dev/null; then
                yum install -y "${pkg}"
            else
                die "Cannot install '${pkg}': no supported package manager found."
            fi
        fi
    }
fi

# Project paths
: "${INSTALL_DIR:=/opt/ai-gateway-bridge}"
: "${LOG_DIR:=/var/log/ai-gateway-bridge}"

readonly KEEPALIVE_SYSCTL_SRC="${_KA_PROJECT_DIR}/configs/keepalive/keepalive-sysctl.conf"
readonly KEEPALIVE_SYSCTL_DEST="/etc/sysctl.d/98-ai-gateway-keepalive.conf"
# Guarded — may already be defined by server-a.sh or server-b.sh
[[ -v XRAY_CONFIG ]] || readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly HEARTBEAT_SRC="${_KA_PROJECT_DIR}/configs/keepalive/heartbeat.sh"
readonly WATCHDOG_SRC="${_KA_PROJECT_DIR}/configs/keepalive/watchdog.sh"
readonly HEARTBEAT_DEST="${INSTALL_DIR}/heartbeat.sh"
readonly WATCHDOG_DEST="${INSTALL_DIR}/watchdog.sh"

###############################################################################
# setup_tcp_keepalive()
#
# Deploy kernel-level TCP keepalive parameters via sysctl:
#   - tcp_keepalive_time  = 30   (start probes after 30s idle)
#   - tcp_keepalive_intvl = 10   (10s between probes)
#   - tcp_keepalive_probes = 3   (3 failed probes = dead connection)
#   - tcp_fastopen = 3           (TFO for client + server)
#   - tcp_mtu_probing = 1        (active PMTU discovery)
#
# Copies the sysctl conf from configs/keepalive/ and applies immediately.
###############################################################################
setup_tcp_keepalive() {
    log_step "Configuring TCP keepalive kernel parameters..."

    # Backup existing sysctl file if present
    if [[ -f "${KEEPALIVE_SYSCTL_DEST}" ]]; then
        local backup="${KEEPALIVE_SYSCTL_DEST}.bak.$(date +%Y%m%d%H%M%S)"
        cp "${KEEPALIVE_SYSCTL_DEST}" "${backup}"
        log_info "Backed up existing sysctl config to ${backup}"
    fi

    # Deploy the sysctl configuration
    if [[ -f "${KEEPALIVE_SYSCTL_SRC}" ]]; then
        cp "${KEEPALIVE_SYSCTL_SRC}" "${KEEPALIVE_SYSCTL_DEST}"
        log_info "Deployed keepalive sysctl config from ${KEEPALIVE_SYSCTL_SRC}"
    else
        log_warn "Sysctl config source not found at ${KEEPALIVE_SYSCTL_SRC}. Writing inline."
        cat > "${KEEPALIVE_SYSCTL_DEST}" <<'SYSCTL_EOF'
# AI Gateway Bridge - TCP Keepalive Parameters
# Auto-generated by keepalive.sh

# Keepalive: 30s idle -> probe every 10s -> 3 failures = dead
net.ipv4.tcp_keepalive_time = 30
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3

# TCP Fast Open (client + server)
net.ipv4.tcp_fastopen = 3

# Active MTU probing (bypass PMTU black holes)
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1024
SYSCTL_EOF
    fi

    chmod 644 "${KEEPALIVE_SYSCTL_DEST}"

    # Apply immediately
    log_info "Applying sysctl parameters..."
    if sysctl -p "${KEEPALIVE_SYSCTL_DEST}" 2>&1; then
        log_success "TCP keepalive parameters applied."
    else
        log_warn "Some sysctl parameters may not have applied cleanly. Check kernel support."
    fi

    # Verify key parameters
    log_info "Verification:"
    log_info "  tcp_keepalive_time  = $(sysctl -n net.ipv4.tcp_keepalive_time 2>/dev/null || echo 'N/A')"
    log_info "  tcp_keepalive_intvl = $(sysctl -n net.ipv4.tcp_keepalive_intvl 2>/dev/null || echo 'N/A')"
    log_info "  tcp_keepalive_probes= $(sysctl -n net.ipv4.tcp_keepalive_probes 2>/dev/null || echo 'N/A')"
    log_info "  tcp_fastopen        = $(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 'N/A')"
    log_info "  tcp_mtu_probing     = $(sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo 'N/A')"
}

###############################################################################
# setup_xray_keepalive()
#
# Patches the Xray JSON configuration to add sockopt keepalive settings
# to all inbound and outbound entries. Uses jq for safe JSON manipulation.
#
# Adds to each inbound/outbound streamSettings:
#   "sockopt": {
#     "tcpKeepAliveIdle": 30,
#     "tcpKeepAliveInterval": 10,
#     "mark": 255,
#     "tcpFastOpen": true,
#     "tcpMptcp": false
#   }
#
# If sockopt already exists, merges (preserves existing keys).
###############################################################################
setup_xray_keepalive() {
    log_step "Configuring Xray sockopt keepalive..."

    # Ensure jq is available
    install_if_missing jq jq

    # Validate Xray config exists
    if [[ ! -f "${XRAY_CONFIG}" ]]; then
        log_warn "Xray config not found at ${XRAY_CONFIG}. Skipping Xray keepalive setup."
        log_info "Run this again after Xray is installed and configured."
        return 0
    fi

    # Validate JSON syntax
    if ! jq empty "${XRAY_CONFIG}" 2>/dev/null; then
        log_error "Xray config at ${XRAY_CONFIG} is not valid JSON. Skipping."
        return 1
    fi

    # Backup before modification
    local backup="${XRAY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    cp "${XRAY_CONFIG}" "${backup}"
    log_info "Backed up Xray config to ${backup}"

    # Define the sockopt keepalive object
    local sockopt_patch
    sockopt_patch='{
        "tcpKeepAliveIdle": 30,
        "tcpKeepAliveInterval": 10,
        "mark": 255,
        "tcpFastOpen": true,
        "tcpMptcp": false
    }'

    # Patch inbounds: add/merge sockopt to each inbound's streamSettings
    local patched_config
    patched_config="$(jq --argjson sockopt "${sockopt_patch}" '
        # Patch inbounds
        if .inbounds then
            .inbounds |= map(
                if .streamSettings then
                    .streamSettings.sockopt = (
                        (.streamSettings.sockopt // {}) + $sockopt
                    )
                else
                    .streamSettings = { "sockopt": $sockopt }
                end
            )
        else
            .
        end
        |
        # Patch outbounds
        if .outbounds then
            .outbounds |= map(
                # Only add sockopt to proxy outbounds, skip "freedom" and "blackhole"
                if (.protocol // "") == "freedom" or (.protocol // "") == "blackhole" then
                    .
                elif .streamSettings then
                    .streamSettings.sockopt = (
                        (.streamSettings.sockopt // {}) + $sockopt
                    )
                elif (.protocol // "") != "" then
                    .streamSettings = { "sockopt": $sockopt }
                else
                    .
                end
            )
        else
            .
        end
    ' "${XRAY_CONFIG}")" || {
        log_error "jq patching failed. Restoring backup."
        cp "${backup}" "${XRAY_CONFIG}"
        return 1
    }

    # Write patched config
    echo "${patched_config}" > "${XRAY_CONFIG}"
    chmod 600 "${XRAY_CONFIG}"

    # Validate the patched config
    if ! jq empty "${XRAY_CONFIG}" 2>/dev/null; then
        log_error "Patched Xray config is invalid JSON. Restoring backup."
        cp "${backup}" "${XRAY_CONFIG}"
        return 1
    fi

    # Test with Xray if available
    local xray_bin=""
    if command -v xray &>/dev/null; then
        xray_bin="xray"
    elif [[ -x /usr/local/bin/xray ]]; then
        xray_bin="/usr/local/bin/xray"
    fi

    if [[ -n "${xray_bin}" ]]; then
        if "${xray_bin}" run -test -config "${XRAY_CONFIG}" &>/dev/null; then
            log_success "Xray config validation passed with sockopt keepalive."
        else
            log_error "Xray config validation failed after patching. Restoring backup."
            cp "${backup}" "${XRAY_CONFIG}"
            # Verify restore
            if "${xray_bin}" run -test -config "${XRAY_CONFIG}" &>/dev/null; then
                log_info "Original config restored and validated."
            fi
            return 1
        fi
    else
        log_info "Xray binary not found. Skipping config validation (JSON syntax is valid)."
    fi

    # Restart Xray to apply changes
    if command -v systemctl &>/dev/null && systemctl is-active --quiet xray 2>/dev/null; then
        log_info "Restarting Xray to apply keepalive settings..."
        systemctl restart xray
        sleep 2
        if systemctl is-active --quiet xray; then
            log_success "Xray restarted with keepalive sockopt."
        else
            log_error "Xray failed to restart. Restoring backup and restarting..."
            cp "${backup}" "${XRAY_CONFIG}"
            systemctl restart xray 2>/dev/null || true
            return 1
        fi
    fi

    log_success "Xray sockopt keepalive configured."
}

###############################################################################
# setup_heartbeat_service()
#
# Deploys a systemd service + timer that sends connectivity probes every 30s
# through the proxy to verify tunnel liveness.
#
# Features:
#   - Probes multiple AI API endpoints through SOCKS5 proxy
#   - Auto-restarts Xray after 3 consecutive probe failures
#   - Sends alert (log + optional webhook) after 5 consecutive failures
#   - Writes structured JSON status to /var/log/ai-gateway-bridge/heartbeat.json
###############################################################################
setup_heartbeat_service() {
    log_step "Deploying heartbeat probe service..."

    # Create directories
    mkdir -p "${INSTALL_DIR}"
    mkdir -p "${LOG_DIR}"
    mkdir -p /var/lib/ai-gateway-bridge

    # Deploy heartbeat script
    if [[ -f "${HEARTBEAT_SRC}" ]]; then
        cp "${HEARTBEAT_SRC}" "${HEARTBEAT_DEST}"
        log_info "Deployed heartbeat script from ${HEARTBEAT_SRC}"
    else
        log_error "Heartbeat script source not found at ${HEARTBEAT_SRC}"
        return 1
    fi
    chmod +x "${HEARTBEAT_DEST}"

    # Create systemd service unit
    cat > /etc/systemd/system/ai-gateway-heartbeat.service <<HBSERVICE_EOF
[Unit]
Description=AI Gateway Bridge - Heartbeat Probe
Documentation=https://github.com/ai-gateway-bridge
After=network-online.target xray.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${HEARTBEAT_DEST}
StandardOutput=journal
StandardError=journal

# Resource limits
MemoryMax=64M
CPUQuota=10%

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${LOG_DIR} /var/lib/ai-gateway-bridge
PrivateTmp=true
HBSERVICE_EOF

    # Create systemd timer (30-second interval)
    cat > /etc/systemd/system/ai-gateway-heartbeat.timer <<HBTIMER_EOF
[Unit]
Description=AI Gateway Bridge - Heartbeat Probe Timer (every 30s)
Documentation=https://github.com/ai-gateway-bridge

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=5s
RandomizedDelaySec=0

[Install]
WantedBy=timers.target
HBTIMER_EOF

    # Enable and start the timer
    systemctl daemon-reload
    systemctl enable ai-gateway-heartbeat.timer
    systemctl start ai-gateway-heartbeat.timer

    log_success "Heartbeat service deployed."
    log_info "  Script:  ${HEARTBEAT_DEST}"
    log_info "  Timer:   ai-gateway-heartbeat.timer (every 30s)"
    log_info "  Status:  ${LOG_DIR}/heartbeat.json"
    log_info "  Alerts:  ${LOG_DIR}/alerts.log"
    log_info "  Logs:    journalctl -u ai-gateway-heartbeat"
}

###############################################################################
# setup_watchdog()
#
# Deploys a continuous systemd service that monitors all critical services
# every 10 seconds:
#   - xray    (proxy tunnel core)
#   - mihomo  (smart routing, optional)
#   - caddy   (TLS reverse proxy)
#   - docker  (container runtime)
#   - VPN     (WireGuard/OpenVPN interface, optional)
#
# Auto-restarts failed services with exponential backoff and cooldown.
# Writes JSON status to /var/log/ai-gateway-bridge/watchdog.json
###############################################################################
setup_watchdog() {
    log_step "Deploying service watchdog..."

    # Create directories
    mkdir -p "${INSTALL_DIR}"
    mkdir -p "${LOG_DIR}"
    mkdir -p /var/lib/ai-gateway-bridge/watchdog

    # Deploy watchdog script
    if [[ -f "${WATCHDOG_SRC}" ]]; then
        cp "${WATCHDOG_SRC}" "${WATCHDOG_DEST}"
        log_info "Deployed watchdog script from ${WATCHDOG_SRC}"
    else
        log_error "Watchdog script source not found at ${WATCHDOG_SRC}"
        return 1
    fi
    chmod +x "${WATCHDOG_DEST}"

    # Create systemd service unit
    cat > /etc/systemd/system/ai-gateway-watchdog.service <<WDSERVICE_EOF
[Unit]
Description=AI Gateway Bridge - Service Watchdog
Documentation=https://github.com/ai-gateway-bridge
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${WATCHDOG_DEST}
Restart=always
RestartSec=10
WatchdogSec=60

StandardOutput=journal
StandardError=journal

# Resource limits
MemoryMax=64M
CPUQuota=5%

# Security hardening
NoNewPrivileges=false
ProtectSystem=full
ReadWritePaths=${LOG_DIR} /var/lib/ai-gateway-bridge

[Install]
WantedBy=multi-user.target
WDSERVICE_EOF

    # Enable and start the watchdog service
    systemctl daemon-reload
    systemctl enable ai-gateway-watchdog.service
    systemctl start ai-gateway-watchdog.service

    sleep 2
    if systemctl is-active --quiet ai-gateway-watchdog.service; then
        log_success "Watchdog service is running."
    else
        log_warn "Watchdog service may not have started. Check: journalctl -u ai-gateway-watchdog"
    fi

    log_info "  Script:  ${WATCHDOG_DEST}"
    log_info "  Service: ai-gateway-watchdog.service"
    log_info "  Status:  ${LOG_DIR}/watchdog.json"
    log_info "  Logs:    journalctl -u ai-gateway-watchdog -f"
}

###############################################################################
# deploy_keepalive()
#
# Orchestration function that runs all keepalive setup steps in order.
###############################################################################
deploy_keepalive() {
    log_step "============================================"
    log_step "  AI Gateway Bridge - Keepalive Deployment"
    log_step "============================================"
    echo ""

    # Step 1: TCP keepalive kernel parameters
    setup_tcp_keepalive
    echo ""

    # Step 2: Xray sockopt keepalive
    setup_xray_keepalive
    echo ""

    # Step 3: Heartbeat probe service
    setup_heartbeat_service
    echo ""

    # Step 4: Service watchdog
    setup_watchdog
    echo ""

    log_step "============================================"
    log_step "  Keepalive Deployment Complete"
    log_step "============================================"
    echo ""
    log_info "Summary:"
    log_info "  [OK] TCP keepalive: 30s idle / 10s interval / 3 probes"
    log_info "  [OK] TCP Fast Open: enabled (client + server)"
    log_info "  [OK] MTU probing: enabled (bypass PMTU black holes)"
    log_info "  [OK] Xray sockopt: keepalive injected into config"
    log_info "  [OK] Heartbeat: probing every 30s, auto-restart on 3 failures"
    log_info "  [OK] Watchdog: monitoring 5 services every 10s"
    echo ""
    log_info "Status files:"
    log_info "  Heartbeat: ${LOG_DIR}/heartbeat.json"
    log_info "  Watchdog:  ${LOG_DIR}/watchdog.json"
    log_info "  Alerts:    ${LOG_DIR}/alerts.log"
    echo ""
    log_info "Management commands:"
    log_info "  systemctl status ai-gateway-heartbeat.timer"
    log_info "  systemctl status ai-gateway-watchdog"
    log_info "  journalctl -u ai-gateway-heartbeat --since '5 min ago'"
    log_info "  journalctl -u ai-gateway-watchdog -f"
}

# =============================================================================
# Main execution - run deploy_keepalive if script is executed directly
# =============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Require root privileges
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "This script must be run as root."
        exit 1
    fi
    deploy_keepalive
fi
