#!/usr/bin/env bash
###############################################################################
# AI Gateway Bridge - Heartbeat Probe Script
#
# Standalone script invoked by the ai-gateway-heartbeat systemd service.
# Sends periodic connectivity probes through the local SOCKS5 proxy to
# verify that the Xray tunnel is alive and AI API endpoints are reachable.
#
# Behavior:
#   - Sends an HTTPS HEAD request through the proxy every cycle
#   - Tracks consecutive failures in a state file
#   - Auto-restarts Xray after RESTART_THRESHOLD consecutive failures
#   - Sends alert (log + optional webhook) after ALERT_THRESHOLD failures
#   - Writes structured JSON status to HEARTBEAT_STATUS_FILE
#
# Exit codes:
#   0 - Probe succeeded (or recovered after restart)
#   1 - Probe failed but below alert threshold
#   2 - Alert threshold reached, notification sent
#
# Usage:
#   /opt/ai-gateway-bridge/heartbeat.sh
#   (invoked by systemd timer, not intended for manual use)
###############################################################################

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
readonly PROXY_ADDR="${HEARTBEAT_PROXY:-socks5://127.0.0.1:10808}"
readonly PROBE_TARGETS=(
    "https://api.anthropic.com"
    "https://api.openai.com"
    "https://generativelanguage.googleapis.com"
)
readonly CONNECT_TIMEOUT=10
readonly MAX_TIME=20

readonly STATE_DIR="/var/lib/ai-gateway-bridge"
readonly FAIL_COUNT_FILE="${STATE_DIR}/heartbeat-failures"
readonly HEARTBEAT_STATUS_FILE="/var/log/ai-gateway-bridge/heartbeat.json"
readonly ALERT_LOG="/var/log/ai-gateway-bridge/alerts.log"

readonly RESTART_THRESHOLD=3    # Auto-restart Xray after 3 consecutive failures
readonly ALERT_THRESHOLD=5      # Send alert after 5 consecutive failures

# Optional webhook URL for alerts (set via environment or config file)
readonly WEBHOOK_URL="${HEARTBEAT_WEBHOOK_URL:-}"

# =============================================================================
# Initialization
# =============================================================================
mkdir -p "${STATE_DIR}"
mkdir -p "$(dirname "${HEARTBEAT_STATUS_FILE}")"

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LOCAL_TIME="$(date '+%Y-%m-%d %H:%M:%S %Z')"

# Read current failure count
FAIL_COUNT=0
if [[ -f "${FAIL_COUNT_FILE}" ]]; then
    FAIL_COUNT="$(cat "${FAIL_COUNT_FILE}" 2>/dev/null | tr -dc '0-9')"
    FAIL_COUNT="${FAIL_COUNT:-0}"
fi

# =============================================================================
# Functions
# =============================================================================

# Send a single probe through the proxy.
# Returns 0 on success, 1 on failure.
# Sets PROBE_RESULT_CODE and PROBE_LATENCY_MS as side effects.
PROBE_RESULT_CODE=""
PROBE_LATENCY_MS=""

send_probe() {
    local target="${1}"
    local start_ns end_ns http_code

    start_ns="$(date +%s%N)"

    http_code="$(curl -s -o /dev/null -w '%{http_code}' \
        --proxy "${PROXY_ADDR}" \
        --connect-timeout "${CONNECT_TIMEOUT}" \
        --max-time "${MAX_TIME}" \
        -I \
        "${target}" 2>/dev/null)" || http_code="000"

    end_ns="$(date +%s%N)"

    PROBE_RESULT_CODE="${http_code}"
    PROBE_LATENCY_MS="$(( (end_ns - start_ns) / 1000000 ))"

    # Any non-000 response means the tunnel is working (even 4xx/5xx from the API)
    if [[ "${http_code}" != "000" ]]; then
        return 0
    fi
    return 1
}

# Write structured JSON status
write_status() {
    local status="${1}"
    local target="${2}"
    local http_code="${3}"
    local latency="${4}"
    local fail_count="${5}"

    cat > "${HEARTBEAT_STATUS_FILE}" <<STATUS_EOF
{
  "timestamp": "${TIMESTAMP}",
  "local_time": "${LOCAL_TIME}",
  "status": "${status}",
  "probe": {
    "target": "${target}",
    "http_code": "${http_code}",
    "latency_ms": ${latency},
    "proxy": "${PROXY_ADDR}"
  },
  "consecutive_failures": ${fail_count},
  "restart_threshold": ${RESTART_THRESHOLD},
  "alert_threshold": ${ALERT_THRESHOLD}
}
STATUS_EOF
    chmod 644 "${HEARTBEAT_STATUS_FILE}"
}

# Record alert to log and optionally send webhook notification
send_alert() {
    local level="${1}"
    local message="${2}"

    echo "[${TIMESTAMP}] [${level}] [heartbeat] ${message}" >> "${ALERT_LOG}"

    # Send webhook if configured
    if [[ -n "${WEBHOOK_URL}" ]]; then
        local payload
        payload="{\"level\":\"${level}\",\"component\":\"heartbeat\",\"message\":\"${message}\",\"timestamp\":\"${TIMESTAMP}\",\"consecutive_failures\":${FAIL_COUNT}}"

        curl -s -o /dev/null \
            --connect-timeout 5 \
            --max-time 10 \
            -H "Content-Type: application/json" \
            -d "${payload}" \
            "${WEBHOOK_URL}" 2>/dev/null || true
    fi
}

# Attempt to restart Xray service
restart_xray() {
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart xray 2>/dev/null && return 0
    fi
    # Fallback: kill and relaunch
    if command -v xray >/dev/null 2>&1; then
        pkill -x xray 2>/dev/null || true
        sleep 1
        xray run -config /usr/local/etc/xray/config.json &>/dev/null &
        disown
        sleep 2
        pgrep -x xray >/dev/null 2>&1 && return 0
    fi
    return 1
}

# =============================================================================
# Main Probe Logic
# =============================================================================

PROBE_SUCCESS=false
PROBE_TARGET=""

for target in ${PROBE_TARGETS[@]+"${PROBE_TARGETS[@]}"}; do
    if send_probe "${target}"; then
        PROBE_SUCCESS=true
        PROBE_TARGET="${target}"
        break
    fi
    PROBE_TARGET="${target}"
done

if [[ "${PROBE_SUCCESS}" == "true" ]]; then
    # Reset failure counter on success
    if [[ "${FAIL_COUNT}" -gt 0 ]]; then
        send_alert "INFO" "Heartbeat recovered after ${FAIL_COUNT} consecutive failures. Target: ${PROBE_TARGET} (HTTP ${PROBE_RESULT_CODE}, ${PROBE_LATENCY_MS}ms)"
    fi
    echo "0" > "${FAIL_COUNT_FILE}"
    write_status "healthy" "${PROBE_TARGET}" "${PROBE_RESULT_CODE}" "${PROBE_LATENCY_MS}" 0
    exit 0
fi

# Probe failed
FAIL_COUNT=$(( FAIL_COUNT + 1 ))
echo "${FAIL_COUNT}" > "${FAIL_COUNT_FILE}"

write_status "failing" "${PROBE_TARGET}" "${PROBE_RESULT_CODE}" "${PROBE_LATENCY_MS:-0}" "${FAIL_COUNT}"

# Auto-restart on threshold
if [[ "${FAIL_COUNT}" -eq "${RESTART_THRESHOLD}" ]]; then
    send_alert "WARNING" "Heartbeat failed ${FAIL_COUNT} times consecutively. Auto-restarting Xray..."
    if restart_xray; then
        send_alert "INFO" "Xray restarted by heartbeat auto-recovery."
        # Give Xray time to establish tunnel, then re-probe
        sleep 5
        if send_probe "${PROBE_TARGETS[0]}"; then
            echo "0" > "${FAIL_COUNT_FILE}"
            write_status "recovered" "${PROBE_TARGETS[0]}" "${PROBE_RESULT_CODE}" "${PROBE_LATENCY_MS}" 0
            send_alert "INFO" "Heartbeat recovered after Xray restart."
            exit 0
        fi
    else
        send_alert "CRITICAL" "Failed to restart Xray during heartbeat auto-recovery."
    fi
fi

# Alert on threshold
if [[ "${FAIL_COUNT}" -ge "${ALERT_THRESHOLD}" ]]; then
    send_alert "CRITICAL" "Heartbeat failed ${FAIL_COUNT} times consecutively (threshold: ${ALERT_THRESHOLD}). Tunnel appears DOWN. Manual intervention required."
    exit 2
fi

exit 1
