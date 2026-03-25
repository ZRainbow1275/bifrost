#!/usr/bin/env bash
###############################################################################
# AI Gateway Bridge - Monitoring Deployment Script
#
# Deploys monitoring infrastructure:
#   - Netdata (lightweight system monitoring with Web UI)
#   - Health check script (cron-based tunnel and service monitoring)
#   - Log rotation for all project services
#
# Usage: source this file from install.sh or run directly
#   bash scripts/monitoring.sh
#
# Dependencies: scripts/common.sh
###############################################################################

set -euo pipefail

# Guard against double-sourcing (readonly variables would conflict)
if [[ -n "${_MONITORING_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
readonly _MONITORING_SH_LOADED=1

# Resolve the directory this script resides in
# Use _MON_SCRIPT_DIR to avoid conflict with readonly SCRIPT_DIR from install.sh
_MON_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MON_PROJECT_DIR="$(cd "${_MON_SCRIPT_DIR}/.." && pwd)"

# Source common utilities
if [[ -f "${_MON_SCRIPT_DIR}/common.sh" ]]; then
    # shellcheck source=scripts/common.sh
    source "${_MON_SCRIPT_DIR}/common.sh"
else
    # Minimal fallback if common.sh is not available
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
    log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
    log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
    log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
    confirm_action() {
        local prompt="${1:-Continue?}"
        read -r -p "${prompt} [y/N]: " response
        [[ "${response}" =~ ^[Yy]$ ]]
    }
fi

# Compatibility shims: define helpers that common.sh may not provide
# log_step -> uses log_info with a prefix, or print_section if available
if ! declare -f log_step >/dev/null 2>&1; then
    if declare -f print_section >/dev/null 2>&1; then
        log_step() { print_section "$*"; }
    else
        log_step() { log_info "[STEP] $*"; }
    fi
fi
# command_exists -> wraps common.sh's check_command
if ! declare -f command_exists >/dev/null 2>&1; then
    if declare -f check_command >/dev/null 2>&1; then
        command_exists() { check_command "$1"; }
    else
        command_exists() { command -v "$1" &>/dev/null; }
    fi
fi

# Project paths (use := to avoid overwriting readonly vars set by install.sh)
: "${INSTALL_DIR:=/opt/ai-gateway-bridge}"
: "${LOG_DIR:=/var/log/ai-gateway-bridge}"
HEALTH_CHECK_SCRIPT="${INSTALL_DIR}/health-check.sh"

###############################################################################
# install_netdata()
#
# Install Netdata with the official kickstart script in non-interactive mode.
# Configure for low resource usage:
#   - Update interval: 5 seconds
#   - Memory mode: ram (no disk persistence for metrics)
#   - Restrict access to localhost + allowed IPs
###############################################################################
install_netdata() {
    log_step "Installing Netdata monitoring agent..."

    # Check if Netdata is already installed
    if command_exists netdata; then
        log_warn "Netdata is already installed. Checking version..."
        netdata -v 2>/dev/null || true
        if ! confirm_action "Netdata is already installed. Reinstall/reconfigure?"; then
            log_info "Skipping Netdata installation."
            return 0
        fi
    fi

    # Install Netdata via official kickstart (non-interactive, stable channel)
    log_info "Downloading and running Netdata kickstart installer..."
    local _netdata_url="https://get.netdata.cloud/kickstart.sh"
    if command_exists curl; then
        if ! curl -fsSL --connect-timeout 15 --max-time 60 "${_netdata_url}" -o /tmp/netdata-kickstart.sh 2>/dev/null; then
            # Netdata kickstart is not on GitHub, but try via general CDN/mirror
            log_warn "Direct Netdata download failed. Trying alternative source..."
            if ! curl -fsSL --connect-timeout 15 --max-time 60 \
                "https://raw.githubusercontent.com/netdata/netdata/master/packaging/installer/kickstart.sh" \
                -o /tmp/netdata-kickstart.sh 2>/dev/null; then
                # Last resort: try GitHub mirror
                github_download "https://raw.githubusercontent.com/netdata/netdata/master/packaging/installer/kickstart.sh" \
                    /tmp/netdata-kickstart.sh 60 || {
                    log_error "Failed to download Netdata installer from all sources."
                    return 1
                }
            fi
        fi
    elif command_exists wget; then
        if ! wget -qO /tmp/netdata-kickstart.sh "${_netdata_url}" 2>/dev/null; then
            log_warn "wget Netdata download failed. Trying GitHub mirror..."
            # Try raw GitHub content via mirror (declare -f github_download to check availability)
            if declare -f github_download &>/dev/null; then
                github_download "https://raw.githubusercontent.com/netdata/netdata/master/packaging/installer/kickstart.sh" \
                    /tmp/netdata-kickstart.sh 60 || {
                    log_error "Failed to download Netdata installer from all sources."
                    return 1
                }
            else
                log_error "Failed to download Netdata installer and github_download helper not available."
                return 1
            fi
        fi
    else
        log_error "Neither curl nor wget found. Cannot download Netdata installer."
        return 1
    fi

    # Run the installer in non-interactive mode
    # --dont-wait: non-interactive
    # --stable-channel: use stable releases
    # --dont-start-it: we'll configure before starting
    bash /tmp/netdata-kickstart.sh \
        --dont-wait \
        --stable-channel \
        --dont-start-it \
        --disable-telemetry || {
        log_error "Netdata installation failed."
        rm -f /tmp/netdata-kickstart.sh
        return 1
    }
    rm -f /tmp/netdata-kickstart.sh

    log_info "Configuring Netdata for low resource usage..."

    # Determine Netdata config directory
    local netdata_conf_dir="/etc/netdata"
    if [[ ! -d "${netdata_conf_dir}" ]]; then
        netdata_conf_dir="/opt/netdata/etc/netdata"
    fi

    # Backup original config
    if [[ -f "${netdata_conf_dir}/netdata.conf" ]]; then
        cp "${netdata_conf_dir}/netdata.conf" "${netdata_conf_dir}/netdata.conf.bak.$(date +%Y%m%d%H%M%S)"
    fi

    # Write optimized configuration
    cat > "${netdata_conf_dir}/netdata.conf" <<'NETDATA_CONF'
# AI Gateway Bridge - Netdata Configuration
# Optimized for low resource usage on proxy servers

[global]
    # Update interval: 5 seconds (default is 1, using 5 to reduce CPU)
    update every = 5

    # Memory mode: ram - store metrics in RAM only, no disk I/O
    # Metrics will be lost on restart but saves significant disk I/O
    memory mode = ram

    # History: keep 1 hour of data in RAM at 5-second granularity
    # 3600 / 5 = 720 data points
    history = 720

    # Run as netdata user
    run as user = netdata

    # Disable cloud integration (we're running standalone)
    # Remove or set to yes if you want Netdata Cloud
    disconnect obsolete charts after secs = 3600

    # Reduce debug logging
    debug log = none
    error log = syslog
    access log = none

[web]
    # Bind to localhost only by default
    # Add specific IPs below for remote access
    bind to = 127.0.0.1

    # Default port
    default port = 19999

    # Allow connections from localhost and specified IPs
    # Modify this to include your admin IP addresses
    allow connections from = localhost 127.0.0.1 ::1 10.* 172.16.* 172.17.* 172.18.* 172.19.* 172.20.* 172.21.* 172.22.* 172.23.* 172.24.* 172.25.* 172.26.* 172.27.* 172.28.* 172.29.* 172.30.* 172.31.* 192.168.*

    # Allow dashboard access from the same IPs
    allow dashboard from = localhost 127.0.0.1 ::1 10.* 172.16.* 172.17.* 172.18.* 172.19.* 172.20.* 172.21.* 172.22.* 172.23.* 172.24.* 172.25.* 172.26.* 172.27.* 172.28.* 172.29.* 172.30.* 172.31.* 192.168.*

    # Allow badges from anywhere (for status pages)
    allow badges from = *

[plugins]
    # Disable plugins we don't need to save resources
    # Enable only essential system monitoring
    tc = no
    idlejitter = no
    cgroups = yes
    enable running new plugins = no
    check for new plugins every = 60
    apps = no
    charts.d = no
    fping = no
    node.d = no
    python.d = no
    go.d = yes

[health]
    # Enable health monitoring (alerts)
    enabled = yes

    # Increase the check interval to reduce CPU usage
    # Default is 1, we check every 10 seconds
    health check every = 10
NETDATA_CONF

    # Configure stream.conf to disable streaming (standalone mode)
    cat > "${netdata_conf_dir}/stream.conf" <<'STREAM_CONF'
# Netdata streaming configuration
# Streaming disabled - standalone monitoring mode

[stream]
    enabled = no
STREAM_CONF

    # Start and enable Netdata service
    log_info "Starting Netdata service..."
    if command_exists systemctl; then
        systemctl enable netdata 2>/dev/null || true
        systemctl restart netdata
    elif command_exists service; then
        service netdata restart
    fi

    # Verify Netdata is running
    sleep 2
    if curl -sf http://127.0.0.1:19999/api/v1/info >/dev/null 2>&1; then
        log_info "Netdata is running successfully on http://127.0.0.1:19999"
    else
        log_warn "Netdata may not have started correctly. Check: systemctl status netdata"
    fi

    log_info "Netdata installation and configuration complete."
    log_info "  Access locally: http://127.0.0.1:19999"
    log_info "  To allow remote access, update [web] bind to in ${netdata_conf_dir}/netdata.conf"
}

###############################################################################
# setup_health_check()
#
# Create a comprehensive health check script at /opt/ai-gateway-bridge/
# that monitors:
#   - Xray service status
#   - Tunnel connectivity (curl through SOCKS5 proxy)
#   - New API container health (if on Server A)
#   - 3x-ui service status (if on Server B)
#   - Disk and memory usage thresholds
#
# Registers the health check in cron to run every 5 minutes.
###############################################################################
setup_health_check() {
    log_step "Setting up health check script and cron job..."

    # Create install directory
    mkdir -p "${INSTALL_DIR}"
    mkdir -p "${LOG_DIR}"

    # Copy the standalone health-check.sh script
    if [[ -f "${_MON_SCRIPT_DIR}/health-check.sh" ]]; then
        cp "${_MON_SCRIPT_DIR}/health-check.sh" "${HEALTH_CHECK_SCRIPT}"
    else
        log_warn "health-check.sh not found in scripts directory. Creating from template..."
        # Generate a minimal health check if the standalone script is missing
        cat > "${HEALTH_CHECK_SCRIPT}" <<'HEALTH_EOF'
#!/usr/bin/env bash
# Minimal health check - see scripts/health-check.sh for the full version
set -euo pipefail
LOG_DIR="/var/log/ai-gateway-bridge"
mkdir -p "${LOG_DIR}"
echo "{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"ok\",\"note\":\"minimal check\"}" > "${LOG_DIR}/health.json"
HEALTH_EOF
    fi

    chmod +x "${HEALTH_CHECK_SCRIPT}"
    log_info "Health check script installed at: ${HEALTH_CHECK_SCRIPT}"

    # Add cron job (every 5 minutes)
    local cron_entry="*/5 * * * * ${HEALTH_CHECK_SCRIPT} >> ${LOG_DIR}/health-cron.log 2>&1"
    local cron_marker="# ai-gateway-bridge-health-check"

    # Check if cron job already exists
    if crontab -l 2>/dev/null | grep -qF "${cron_marker}"; then
        log_warn "Health check cron job already exists. Updating..."
        # Remove existing entry
        crontab -l 2>/dev/null | grep -vF "${cron_marker}" | crontab -
    fi

    # Add the cron job
    (crontab -l 2>/dev/null; echo "${cron_entry} ${cron_marker}") | crontab -

    log_info "Health check cron job registered (every 5 minutes)."
    log_info "  Script: ${HEALTH_CHECK_SCRIPT}"
    log_info "  Cron log: ${LOG_DIR}/health-cron.log"
    log_info "  Status output: ${LOG_DIR}/health.json"
    log_info "  Alerts: ${LOG_DIR}/alerts.log"
}

###############################################################################
# setup_logrotate()
#
# Configure log rotation for all project services:
#   - Xray logs (/var/log/xray/)
#   - Caddy logs (/var/log/caddy/)
#   - New API logs (Docker stdout, managed separately)
#   - AI Gateway Bridge logs (/var/log/ai-gateway-bridge/)
###############################################################################
setup_logrotate() {
    log_step "Configuring log rotation..."

    # Create logrotate configuration
    cat > /etc/logrotate.d/ai-gateway-bridge <<'LOGROTATE_CONF'
# AI Gateway Bridge - Log Rotation Configuration

# Xray proxy logs
/var/log/xray/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 nobody nogroup
    sharedscripts
    postrotate
        # Signal Xray to reopen log files
        if [ -f /var/run/xray.pid ]; then
            kill -USR1 $(cat /var/run/xray.pid) 2>/dev/null || true
        elif command -v systemctl >/dev/null 2>&1; then
            systemctl kill -s USR1 xray 2>/dev/null || true
        fi
    endscript
}

# Caddy web server logs
/var/log/caddy/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 caddy caddy
    sharedscripts
    postrotate
        # Caddy does not need a signal - it handles rotation via its own config.
        # But if using external log files, we signal it to reopen.
        if command -v systemctl >/dev/null 2>&1; then
            systemctl reload caddy 2>/dev/null || true
        fi
    endscript
}

# AI Gateway Bridge operational logs (health checks, alerts)
/var/log/ai-gateway-bridge/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    size 50M
}

# AI Gateway Bridge health JSON (keep only recent)
/var/log/ai-gateway-bridge/health.json {
    daily
    rotate 3
    compress
    missingok
    notifempty
    create 0644 root root
}
LOGROTATE_CONF

    log_info "Log rotation configured at /etc/logrotate.d/ai-gateway-bridge"

    # Create log directories if they don't exist
    mkdir -p /var/log/xray
    mkdir -p /var/log/caddy
    mkdir -p "${LOG_DIR}"

    # Set proper permissions
    chmod 750 /var/log/xray
    chmod 750 /var/log/caddy
    chmod 750 "${LOG_DIR}"

    # Test logrotate configuration
    if logrotate -d /etc/logrotate.d/ai-gateway-bridge 2>/dev/null; then
        log_info "Logrotate configuration syntax is valid."
    else
        log_warn "Logrotate dry-run produced warnings. Check /etc/logrotate.d/ai-gateway-bridge"
    fi

    log_info "Log rotation setup complete."
    log_info "  Xray logs: daily, keep 7 days"
    log_info "  Caddy logs: daily, keep 14 days"
    log_info "  Bridge logs: weekly or when > 50MB, keep 4 weeks"
}

###############################################################################
# deploy_monitoring()
#
# Orchestration function that runs all monitoring setup steps in order.
###############################################################################
deploy_monitoring() {
    log_step "============================================"
    log_step "  AI Gateway Bridge - Monitoring Deployment"
    log_step "============================================"
    echo ""

    # Step 1: Install Netdata
    install_netdata
    echo ""

    # Step 2: Setup health check
    setup_health_check
    echo ""

    # Step 3: Setup log rotation
    setup_logrotate
    echo ""

    log_step "============================================"
    log_step "  Monitoring Deployment Complete"
    log_step "============================================"
    echo ""
    log_info "Summary:"
    log_info "  [OK] Netdata installed and configured (http://127.0.0.1:19999)"
    log_info "  [OK] Health check script deployed (cron every 5 min)"
    log_info "  [OK] Log rotation configured for all services"
    echo ""
    log_info "Next steps:"
    log_info "  1. To allow remote Netdata access, update bind address in /etc/netdata/netdata.conf"
    log_info "  2. Open port 19999 in firewall if remote access is needed"
    log_info "  3. Check health status: cat ${LOG_DIR}/health.json"
    log_info "  4. Check alerts: cat ${LOG_DIR}/alerts.log"
}

# =============================================================================
# Main execution - run deploy_monitoring if script is executed directly
# =============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Require root privileges
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "This script must be run as root."
        exit 1
    fi
    deploy_monitoring
fi
