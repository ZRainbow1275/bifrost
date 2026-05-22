#!/usr/bin/env bash
###############################################################################
# AI Gateway Bridge - Service Watchdog Script
#
# Standalone watchdog that monitors critical services every 10 seconds:
#   - xray       (proxy tunnel core)
#   - mihomo     (smart routing / DNS, optional)
#   - caddy      (TLS reverse proxy)
#   - docker     (container runtime for New API)
#   - VPN tunnel (WireGuard/OpenVPN interface, optional)
#
# Behavior per service:
#   - If a monitored service is installed but not running, attempt auto-restart
#   - Track consecutive restart failures per service
#   - Log all events to structured JSON and plaintext alert log
#   - Report overall system health status
#
# This script is deployed as a systemd service (ai-gateway-watchdog.service)
# and runs as a continuous loop with a 10-second sleep interval.
#
# Exit codes:
#   0 - Clean shutdown (SIGTERM/SIGINT)
#   1 - Fatal initialization error
#
# Usage:
#   /opt/ai-gateway-bridge/watchdog.sh
#   (managed by systemd, not intended for manual use)
###############################################################################

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
readonly CHECK_INTERVAL=10       # seconds between check cycles
readonly MAX_RESTART_ATTEMPTS=3  # max consecutive restarts before giving up
readonly COOLDOWN_PERIOD=300     # seconds to wait after max restarts before retrying

readonly STATE_DIR="/var/lib/ai-gateway-bridge/watchdog"
readonly STATUS_FILE="/var/log/ai-gateway-bridge/watchdog.json"
readonly ALERT_LOG="/var/log/ai-gateway-bridge/alerts.log"
readonly WATCHDOG_LOG="/var/log/ai-gateway-bridge/watchdog.log"

# VPN interface detection: check these interface names
readonly VPN_INTERFACES=("wg0" "wg1" "tun0" "tun1")

# Optional webhook URL for critical alerts
readonly WEBHOOK_URL="${WATCHDOG_WEBHOOK_URL:-}"

# =============================================================================
# Initialization
# =============================================================================
mkdir -p "${STATE_DIR}"
mkdir -p "$(dirname "${STATUS_FILE}")"
mkdir -p "$(dirname "${WATCHDOG_LOG}")"

# Graceful shutdown flag
SHUTDOWN=false
trap 'SHUTDOWN=true' SIGTERM SIGINT

# =============================================================================
# Helper Functions
# =============================================================================

log_watchdog() {
    local level="${1}"
    local message="${2}"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] [${level}] ${message}" >> "${WATCHDOG_LOG}"

    if [[ "${level}" == "CRITICAL" || "${level}" == "WARNING" ]]; then
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${level}] [watchdog] ${message}" >> "${ALERT_LOG}"
    fi
}

send_webhook() {
    local level="${1}"
    local message="${2}"

    if [[ -z "${WEBHOOK_URL}" ]]; then
        return 0
    fi

    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local payload="{\"level\":\"${level}\",\"component\":\"watchdog\",\"message\":\"${message}\",\"timestamp\":\"${ts}\"}"

    curl -s -o /dev/null \
        --connect-timeout 5 \
        --max-time 10 \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${WEBHOOK_URL}" 2>/dev/null || true
}

# Read the restart failure count for a service
get_fail_count() {
    local service="${1}"
    local file="${STATE_DIR}/${service}.fails"
    if [[ -f "${file}" ]]; then
        cat "${file}" 2>/dev/null | tr -dc '0-9'
    else
        echo "0"
    fi
}

# Write the restart failure count for a service
set_fail_count() {
    local service="${1}"
    local count="${2}"
    echo "${count}" > "${STATE_DIR}/${service}.fails"
}

# Read the last restart attempt timestamp for a service
get_last_restart_time() {
    local service="${1}"
    local file="${STATE_DIR}/${service}.last_restart"
    if [[ -f "${file}" ]]; then
        cat "${file}" 2>/dev/null | tr -dc '0-9'
    else
        echo "0"
    fi
}

set_last_restart_time() {
    local service="${1}"
    date +%s > "${STATE_DIR}/${service}.last_restart"
}

# =============================================================================
# Service Check Functions
# =============================================================================

# Check and optionally restart a systemd service.
# Arguments: service_name [process_name]
# Returns: "running" | "restarted" | "failed" | "cooldown" | "not_installed"
check_and_restart_service() {
    local service="${1}"
    local process_name="${2:-${service}}"

    # Check if service is installed
    if ! systemctl list-unit-files "${service}.service" &>/dev/null 2>&1; then
        # Fallback: check if binary exists
        if ! command -v "${process_name}" &>/dev/null; then
            echo "not_installed"
            return 0
        fi
    fi

    # Check if running
    if systemctl is-active --quiet "${service}" 2>/dev/null; then
        # Reset failure count on healthy check
        set_fail_count "${service}" 0
        echo "running"
        return 0
    fi

    # Also check by process name as fallback
    if pgrep -x "${process_name}" &>/dev/null; then
        set_fail_count "${service}" 0
        echo "running"
        return 0
    fi

    # Service is down - check if we should attempt restart
    local fail_count
    fail_count="$(get_fail_count "${service}")"

    if [[ "${fail_count}" -ge "${MAX_RESTART_ATTEMPTS}" ]]; then
        # Check cooldown period
        local last_restart now elapsed
        last_restart="$(get_last_restart_time "${service}")"
        now="$(date +%s)"
        elapsed=$(( now - last_restart ))

        if [[ "${elapsed}" -lt "${COOLDOWN_PERIOD}" ]]; then
            echo "cooldown"
            return 0
        fi

        # Cooldown expired, reset counter and retry
        log_watchdog "INFO" "Cooldown expired for ${service}. Resetting failure counter and retrying."
        set_fail_count "${service}" 0
        fail_count=0
    fi

    # Attempt restart
    log_watchdog "WARNING" "Service '${service}' is down (attempt $(( fail_count + 1 ))/${MAX_RESTART_ATTEMPTS}). Restarting..."

    local restart_ok=false
    if systemctl restart "${service}" 2>/dev/null; then
        sleep 3
        if systemctl is-active --quiet "${service}" 2>/dev/null; then
            restart_ok=true
        fi
    fi

    set_last_restart_time "${service}"

    if [[ "${restart_ok}" == "true" ]]; then
        set_fail_count "${service}" 0
        log_watchdog "INFO" "Service '${service}' restarted successfully."
        echo "restarted"
        return 0
    fi

    # Restart failed
    fail_count=$(( fail_count + 1 ))
    set_fail_count "${service}" "${fail_count}"

    if [[ "${fail_count}" -ge "${MAX_RESTART_ATTEMPTS}" ]]; then
        local msg="Service '${service}' failed ${fail_count} restart attempts. Entering cooldown (${COOLDOWN_PERIOD}s). Manual intervention required."
        log_watchdog "CRITICAL" "${msg}"
        send_webhook "CRITICAL" "${msg}"
    else
        log_watchdog "WARNING" "Service '${service}' restart attempt ${fail_count}/${MAX_RESTART_ATTEMPTS} failed."
    fi

    echo "failed"
    return 0
}

# Check Docker daemon health
check_docker_service() {
    if ! command -v docker &>/dev/null; then
        echo "not_installed"
        return 0
    fi

    # Check if dockerd is running
    if docker info &>/dev/null 2>&1; then
        set_fail_count "docker" 0
        echo "running"
        return 0
    fi

    # Docker daemon is down
    check_and_restart_service "docker" "dockerd"
}

# Check VPN interface status (WireGuard or OpenVPN)
check_vpn_service() {
    local found_interface=""

    for iface in ${VPN_INTERFACES[@]+"${VPN_INTERFACES[@]}"}; do
        if ip link show "${iface}" &>/dev/null 2>&1; then
            found_interface="${iface}"
            # Check if interface is UP
            if ip link show "${iface}" 2>/dev/null | grep -q "state UP\|state UNKNOWN"; then
                set_fail_count "vpn" 0
                echo "running"
                return 0
            fi
        fi
    done

    if [[ -z "${found_interface}" ]]; then
        # No VPN interface configured - not an error
        echo "not_installed"
        return 0
    fi

    # VPN interface exists but is down
    log_watchdog "WARNING" "VPN interface '${found_interface}' is down."

    # Try to bring up the interface
    if [[ "${found_interface}" =~ ^wg ]]; then
        # WireGuard
        if command -v wg-quick &>/dev/null; then
            log_watchdog "INFO" "Attempting to bring up WireGuard interface '${found_interface}'..."
            if wg-quick up "${found_interface}" 2>/dev/null; then
                sleep 2
                if ip link show "${found_interface}" 2>/dev/null | grep -q "state UP\|state UNKNOWN"; then
                    log_watchdog "INFO" "WireGuard interface '${found_interface}' restored."
                    set_fail_count "vpn" 0
                    echo "restarted"
                    return 0
                fi
            fi
        fi
    elif [[ "${found_interface}" =~ ^tun ]]; then
        # OpenVPN - restart the service
        check_and_restart_service "openvpn" "openvpn"
        return 0
    fi

    local fail_count
    fail_count="$(get_fail_count "vpn")"
    fail_count=$(( fail_count + 1 ))
    set_fail_count "vpn" "${fail_count}"

    if [[ "${fail_count}" -ge "${MAX_RESTART_ATTEMPTS}" ]]; then
        local msg="VPN interface '${found_interface}' failed ${fail_count} recovery attempts."
        log_watchdog "CRITICAL" "${msg}"
        send_webhook "CRITICAL" "${msg}"
    fi

    echo "failed"
    return 0
}

# =============================================================================
# Status Report Generation
# =============================================================================

generate_status_report() {
    local xray_status="${1}"
    local mihomo_status="${2}"
    local caddy_status="${3}"
    local docker_status="${4}"
    local vpn_status="${5}"

    local overall="healthy"
    local services_down=0

    for status in "${xray_status}" "${caddy_status}" "${docker_status}"; do
        case "${status}" in
            failed|cooldown)
                overall="critical"
                services_down=$(( services_down + 1 ))
                ;;
            restarted)
                if [[ "${overall}" != "critical" ]]; then
                    overall="degraded"
                fi
                ;;
        esac
    done

    # Mihomo and VPN are optional - only mark degraded, not critical
    for status in "${mihomo_status}" "${vpn_status}"; do
        case "${status}" in
            failed|cooldown)
                if [[ "${overall}" != "critical" ]]; then
                    overall="degraded"
                fi
                ;;
        esac
    done

    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local local_ts
    local_ts="$(date '+%Y-%m-%d %H:%M:%S %Z')"

    cat > "${STATUS_FILE}" <<STATUS_EOF
{
  "timestamp": "${ts}",
  "local_time": "${local_ts}",
  "overall_status": "${overall}",
  "check_interval_sec": ${CHECK_INTERVAL},
  "services": {
    "xray": {
      "status": "${xray_status}",
      "fail_count": $(get_fail_count "xray")
    },
    "mihomo": {
      "status": "${mihomo_status}",
      "fail_count": $(get_fail_count "mihomo")
    },
    "caddy": {
      "status": "${caddy_status}",
      "fail_count": $(get_fail_count "caddy")
    },
    "docker": {
      "status": "${docker_status}",
      "fail_count": $(get_fail_count "docker")
    },
    "vpn": {
      "status": "${vpn_status}",
      "fail_count": $(get_fail_count "vpn")
    }
  },
  "services_down": ${services_down}
}
STATUS_EOF
    chmod 644 "${STATUS_FILE}"
}

# =============================================================================
# Main Loop
# =============================================================================

log_watchdog "INFO" "Watchdog started. Check interval: ${CHECK_INTERVAL}s, Max restarts: ${MAX_RESTART_ATTEMPTS}, Cooldown: ${COOLDOWN_PERIOD}s"

while [[ "${SHUTDOWN}" == "false" ]]; do
    xray_status="$(check_and_restart_service "xray" "xray")"
    mihomo_status="$(check_and_restart_service "mihomo" "mihomo")"
    caddy_status="$(check_and_restart_service "caddy" "caddy")"
    docker_status="$(check_docker_service)"
    vpn_status="$(check_vpn_service)"

    generate_status_report \
        "${xray_status}" \
        "${mihomo_status}" \
        "${caddy_status}" \
        "${docker_status}" \
        "${vpn_status}"

    # Sleep in small increments to respond to SIGTERM quickly
    local_elapsed=0
    while [[ "${local_elapsed}" -lt "${CHECK_INTERVAL}" && "${SHUTDOWN}" == "false" ]]; do
        sleep 1
        local_elapsed=$(( local_elapsed + 1 ))
    done
done

log_watchdog "INFO" "Watchdog shutting down gracefully."
exit 0
