#!/usr/bin/env bash
###############################################################################
# AI Gateway Bridge - Standalone Health Check Script
#
# This script is called by cron every 5 minutes to monitor the health of
# all AI Gateway Bridge components. It performs the following checks:
#
#   1. Xray service status
#   2. Tunnel connectivity (curl through proxy to api.anthropic.com)
#   3. New API container status (Server A)
#   4. 3x-ui service status (Server B)
#   5. Disk space (alert if < 10% free)
#   6. Memory usage (alert if > 90%)
#   7. CPU load (alert if > 90%)
#   8. Log file sizes
#
# Output:
#   - JSON status report: /var/log/ai-gateway-bridge/health.json
#   - Alerts on failure: /var/log/ai-gateway-bridge/alerts.log
#
# Usage:
#   /opt/ai-gateway-bridge/health-check.sh
#   (typically invoked by cron, not manually)
###############################################################################

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
LOG_DIR="/var/log/ai-gateway-bridge"
HEALTH_JSON="${LOG_DIR}/health.json"
ALERTS_LOG="${LOG_DIR}/alerts.log"
PROXY_SOCKS="socks5://127.0.0.1:10808"
TEST_URL="https://api.anthropic.com"
DISK_THRESHOLD=10    # Alert if free disk space < 10%
MEMORY_THRESHOLD=90  # Alert if memory usage > 90%
CPU_THRESHOLD=90     # Alert if CPU load > 90% (1-min avg vs core count)
LOG_SIZE_WARN_MB=500 # Warn if any log file exceeds 500MB

# Ensure log directory exists
mkdir -p "${LOG_DIR}"

# Timestamp
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LOCAL_TIME="$(date '+%Y-%m-%d %H:%M:%S %Z')"

# =============================================================================
# Helper functions
# =============================================================================
# Overall status tracking
OVERALL_STATUS="healthy"
declare -a ALERT_MESSAGES=()

record_alert() {
    local level="${1}"  # CRITICAL, WARNING, INFO
    local component="${2}"
    local message="${3}"

    ALERT_MESSAGES+=("${level}|${component}|${message}")

    if [[ "${level}" == "CRITICAL" ]]; then
        OVERALL_STATUS="critical"
    elif [[ "${level}" == "WARNING" && "${OVERALL_STATUS}" != "critical" ]]; then
        OVERALL_STATUS="degraded"
    fi

    # Append to alerts log
    echo "[${TIMESTAMP}] [${level}] [${component}] ${message}" >> "${ALERTS_LOG}"
}

# Check if a systemd service is active
check_service() {
    local service_name="${1}"
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet "${service_name}" 2>/dev/null; then
            echo "running"
        elif systemctl is-enabled --quiet "${service_name}" 2>/dev/null; then
            echo "stopped"
        else
            echo "not_installed"
        fi
    else
        # Fallback: check via process name
        if pgrep -x "${service_name}" >/dev/null 2>&1; then
            echo "running"
        else
            echo "unknown"
        fi
    fi
}

# =============================================================================
# Check 1: Xray Service Status
# =============================================================================
check_xray() {
    local status
    status="$(check_service "xray")"

    case "${status}" in
        running)
            XRAY_STATUS="running"
            XRAY_PID="$(pgrep -x xray 2>/dev/null | head -1 || echo "unknown")"
            ;;
        stopped)
            XRAY_STATUS="stopped"
            XRAY_PID="null"
            record_alert "CRITICAL" "xray" "Xray service is stopped but enabled. Attempting restart..."
            # Try to restart
            if systemctl restart xray 2>/dev/null; then
                sleep 3
                if systemctl is-active --quiet xray 2>/dev/null; then
                    record_alert "INFO" "xray" "Xray service auto-restarted successfully."
                    XRAY_STATUS="recovered"
                    XRAY_PID="$(pgrep -x xray 2>/dev/null | head -1 || echo "unknown")"
                else
                    record_alert "CRITICAL" "xray" "Xray service failed to restart."
                fi
            fi
            ;;
        not_installed)
            XRAY_STATUS="not_installed"
            XRAY_PID="null"
            ;;
        *)
            XRAY_STATUS="unknown"
            XRAY_PID="null"
            ;;
    esac
}

# =============================================================================
# Check 2: Tunnel Connectivity
# =============================================================================
check_tunnel() {
    TUNNEL_STATUS="unknown"
    TUNNEL_LATENCY="null"
    TUNNEL_HTTP_CODE="null"

    # Test connectivity through SOCKS5 proxy
    local start_time end_time http_code
    start_time="$(date +%s%N)"

    http_code="$(curl -s -o /dev/null -w '%{http_code}' \
        --proxy "${PROXY_SOCKS}" \
        --connect-timeout 15 \
        --max-time 30 \
        "${TEST_URL}" 2>/dev/null)" || http_code="000"

    end_time="$(date +%s%N)"

    TUNNEL_HTTP_CODE="${http_code}"

    if [[ "${http_code}" != "000" ]]; then
        TUNNEL_STATUS="connected"
        # Calculate latency in milliseconds
        TUNNEL_LATENCY="$(( (end_time - start_time) / 1000000 ))"
    else
        TUNNEL_STATUS="disconnected"
        record_alert "CRITICAL" "tunnel" "Tunnel connectivity test failed. Cannot reach ${TEST_URL} through proxy."

        # Check if Xray is running (tunnel depends on it)
        if [[ "${XRAY_STATUS:-unknown}" != "running" && "${XRAY_STATUS:-unknown}" != "recovered" ]]; then
            record_alert "WARNING" "tunnel" "Tunnel failure likely caused by Xray not running."
        fi
    fi
}

# =============================================================================
# Check 3: New API Container (Server A)
# =============================================================================
check_new_api() {
    NEW_API_STATUS="not_applicable"
    NEW_API_CONTAINER_ID="null"

    # Check if Docker is available
    if ! command -v docker >/dev/null 2>&1; then
        return
    fi

    # Look for New API container (common names: new-api, newapi)
    local container_name=""
    for name in "new-api" "newapi" "one-api" "oneapi"; do
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qw "${name}"; then
            container_name="${name}"
            break
        fi
    done

    if [[ -z "${container_name}" ]]; then
        # No New API container found - might be Server B
        return
    fi

    NEW_API_CONTAINER_ID="$(docker ps -a --filter "name=${container_name}" --format '{{.ID}}' 2>/dev/null | head -1)"

    if docker ps --filter "name=${container_name}" --filter "status=running" --format '{{.Names}}' 2>/dev/null | grep -qw "${container_name}"; then
        NEW_API_STATUS="running"

        # Test the API endpoint locally
        local api_code
        api_code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "http://127.0.0.1:3000/api/status" 2>/dev/null)" || api_code="000"

        if [[ "${api_code}" == "000" ]]; then
            NEW_API_STATUS="unhealthy"
            record_alert "WARNING" "new-api" "New API container running but /api/status unreachable (HTTP ${api_code})."
        fi
    else
        NEW_API_STATUS="stopped"
        record_alert "CRITICAL" "new-api" "New API container '${container_name}' is not running."

        # Try to restart
        if docker start "${container_name}" 2>/dev/null; then
            sleep 5
            if docker ps --filter "name=${container_name}" --filter "status=running" --format '{{.Names}}' 2>/dev/null | grep -qw "${container_name}"; then
                record_alert "INFO" "new-api" "New API container auto-restarted successfully."
                NEW_API_STATUS="recovered"
            else
                record_alert "CRITICAL" "new-api" "New API container failed to restart."
            fi
        fi
    fi
}

# =============================================================================
# Check 4: 3x-ui Service (Server B)
# =============================================================================
check_3xui() {
    XPANEL_STATUS="not_applicable"

    local status
    status="$(check_service "x-ui")"

    case "${status}" in
        running)
            XPANEL_STATUS="running"
            ;;
        stopped)
            XPANEL_STATUS="stopped"
            record_alert "WARNING" "3x-ui" "3x-ui panel service is stopped."
            # Try restart
            if systemctl restart x-ui 2>/dev/null; then
                sleep 3
                if systemctl is-active --quiet x-ui 2>/dev/null; then
                    record_alert "INFO" "3x-ui" "3x-ui service auto-restarted."
                    XPANEL_STATUS="recovered"
                fi
            fi
            ;;
        not_installed)
            # Not on this server - normal
            ;;
        *)
            ;;
    esac
}

# =============================================================================
# Check 5: Disk Space
# =============================================================================
check_disk() {
    DISK_STATUS="healthy"
    DISK_USAGE_PCT="0"
    DISK_FREE_GB="0"

    # Get root partition usage
    local disk_info
    disk_info="$(df -h / 2>/dev/null | tail -1)"

    if [[ -n "${disk_info}" ]]; then
        DISK_USAGE_PCT="$(echo "${disk_info}" | awk '{print $5}' | tr -d '%')"
        DISK_FREE_GB="$(echo "${disk_info}" | awk '{print $4}')"

        local free_pct=$(( 100 - DISK_USAGE_PCT ))
        if [[ "${free_pct}" -lt "${DISK_THRESHOLD}" ]]; then
            DISK_STATUS="critical"
            record_alert "CRITICAL" "disk" "Disk space critically low: ${free_pct}% free (${DISK_FREE_GB} available)."
        elif [[ "${free_pct}" -lt $(( DISK_THRESHOLD * 2 )) ]]; then
            DISK_STATUS="warning"
            record_alert "WARNING" "disk" "Disk space low: ${free_pct}% free (${DISK_FREE_GB} available)."
        fi
    fi
}

# =============================================================================
# Check 6: Memory Usage
# =============================================================================
check_memory() {
    MEMORY_STATUS="healthy"
    MEMORY_USAGE_PCT="0"
    MEMORY_TOTAL_MB="0"
    MEMORY_USED_MB="0"

    if command -v free >/dev/null 2>&1; then
        local mem_info
        mem_info="$(free -m 2>/dev/null | grep -i '^mem:')"

        if [[ -n "${mem_info}" ]]; then
            MEMORY_TOTAL_MB="$(echo "${mem_info}" | awk '{print $2}')"
            MEMORY_USED_MB="$(echo "${mem_info}" | awk '{print $3}')"
            local available_mb
            available_mb="$(echo "${mem_info}" | awk '{print $7}')"

            if [[ "${MEMORY_TOTAL_MB}" -gt 0 ]]; then
                # Calculate usage based on (total - available) / total
                local used_effective=$(( MEMORY_TOTAL_MB - available_mb ))
                MEMORY_USAGE_PCT=$(( used_effective * 100 / MEMORY_TOTAL_MB ))
            fi

            if [[ "${MEMORY_USAGE_PCT}" -gt "${MEMORY_THRESHOLD}" ]]; then
                MEMORY_STATUS="critical"
                record_alert "CRITICAL" "memory" "Memory usage critical: ${MEMORY_USAGE_PCT}% (${MEMORY_USED_MB}MB / ${MEMORY_TOTAL_MB}MB)."
            elif [[ "${MEMORY_USAGE_PCT}" -gt $(( MEMORY_THRESHOLD - 10 )) ]]; then
                MEMORY_STATUS="warning"
                record_alert "WARNING" "memory" "Memory usage high: ${MEMORY_USAGE_PCT}% (${MEMORY_USED_MB}MB / ${MEMORY_TOTAL_MB}MB)."
            fi
        fi
    fi
}

# =============================================================================
# Check 7: CPU Load
# =============================================================================
check_cpu() {
    CPU_STATUS="healthy"
    CPU_LOAD_1MIN="0"
    CPU_LOAD_5MIN="0"
    CPU_LOAD_15MIN="0"
    CPU_CORES="1"

    if [[ -f /proc/loadavg ]]; then
        read -r CPU_LOAD_1MIN CPU_LOAD_5MIN CPU_LOAD_15MIN _ _ < /proc/loadavg
    elif command -v uptime >/dev/null 2>&1; then
        local uptime_out
        uptime_out="$(uptime)"
        CPU_LOAD_1MIN="$(echo "${uptime_out}" | awk -F'load average:' '{print $2}' | awk -F, '{print $1}' | tr -d ' ')"
        CPU_LOAD_5MIN="$(echo "${uptime_out}" | awk -F'load average:' '{print $2}' | awk -F, '{print $2}' | tr -d ' ')"
        CPU_LOAD_15MIN="$(echo "${uptime_out}" | awk -F'load average:' '{print $2}' | awk -F, '{print $3}' | tr -d ' ')"
    fi

    # Get number of CPU cores
    if [[ -f /proc/cpuinfo ]]; then
        CPU_CORES="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"
    elif command -v nproc >/dev/null 2>&1; then
        CPU_CORES="$(nproc)"
    fi

    # Calculate CPU load percentage (1-min avg / cores * 100)
    local cpu_pct
    cpu_pct="$(awk "BEGIN {printf \"%.0f\", (${CPU_LOAD_1MIN} / ${CPU_CORES}) * 100}" 2>/dev/null)" || cpu_pct="0"

    if [[ "${cpu_pct}" -gt "${CPU_THRESHOLD}" ]]; then
        CPU_STATUS="critical"
        record_alert "CRITICAL" "cpu" "CPU load critical: ${CPU_LOAD_1MIN} (${cpu_pct}% of ${CPU_CORES} cores)."
    elif [[ "${cpu_pct}" -gt $(( CPU_THRESHOLD - 15 )) ]]; then
        CPU_STATUS="warning"
        record_alert "WARNING" "cpu" "CPU load high: ${CPU_LOAD_1MIN} (${cpu_pct}% of ${CPU_CORES} cores)."
    fi
}

# =============================================================================
# Check 8: Log File Sizes
# =============================================================================
check_logs() {
    LOGS_STATUS="healthy"
    declare -a LARGE_LOGS=()

    local log_dirs=("/var/log/xray" "/var/log/caddy" "${LOG_DIR}")

    for dir in ${log_dirs[@]+"${log_dirs[@]}"}; do
        if [[ -d "${dir}" ]]; then
            while IFS= read -r -d '' logfile; do
                local size_mb
                size_mb="$(du -m "${logfile}" 2>/dev/null | awk '{print $1}')"
                if [[ -n "${size_mb}" && "${size_mb}" -gt "${LOG_SIZE_WARN_MB}" ]]; then
                    LARGE_LOGS+=("${logfile}:${size_mb}MB")
                    record_alert "WARNING" "logs" "Large log file: ${logfile} (${size_mb}MB)"
                    LOGS_STATUS="warning"
                fi
            done < <(find "${dir}" -maxdepth 2 -type f -name "*.log" -print0 2>/dev/null)
        fi
    done
}

# =============================================================================
# Generate JSON report
# =============================================================================
generate_report() {
    # Build alerts JSON array
    local alerts_json="[]"
    if [[ ${#ALERT_MESSAGES[@]} -gt 0 ]]; then
        alerts_json="["
        local first=true
        for alert in ${ALERT_MESSAGES[@]+"${ALERT_MESSAGES[@]}"}; do
            local level component message
            IFS='|' read -r level component message <<< "${alert}"
            if [[ "${first}" == "true" ]]; then
                first=false
            else
                alerts_json+=","
            fi
            # Escape special characters in message for JSON
            message="$(echo "${message}" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')"
            alerts_json+="{\"level\":\"${level}\",\"component\":\"${component}\",\"message\":\"${message}\"}"
        done
        alerts_json+="]"
    fi

    # Build large logs JSON array
    local large_logs_json="[]"
    if [[ ${#LARGE_LOGS[@]} -gt 0 ]]; then
        large_logs_json="["
        local first=true
        for entry in ${LARGE_LOGS[@]+"${LARGE_LOGS[@]}"}; do
            if [[ "${first}" == "true" ]]; then
                first=false
            else
                large_logs_json+=","
            fi
            large_logs_json+="\"${entry}\""
        done
        large_logs_json+="]"
    fi

    # Write JSON report
    cat > "${HEALTH_JSON}" <<REPORT_EOF
{
  "timestamp": "${TIMESTAMP}",
  "local_time": "${LOCAL_TIME}",
  "overall_status": "${OVERALL_STATUS}",
  "checks": {
    "xray": {
      "status": "${XRAY_STATUS:-unknown}",
      "pid": "${XRAY_PID:-null}"
    },
    "tunnel": {
      "status": "${TUNNEL_STATUS:-unknown}",
      "test_url": "${TEST_URL}",
      "http_code": "${TUNNEL_HTTP_CODE:-null}",
      "latency_ms": ${TUNNEL_LATENCY:-null}
    },
    "new_api": {
      "status": "${NEW_API_STATUS:-not_applicable}",
      "container_id": "${NEW_API_CONTAINER_ID:-null}"
    },
    "3x_ui": {
      "status": "${XPANEL_STATUS:-not_applicable}"
    },
    "disk": {
      "status": "${DISK_STATUS:-unknown}",
      "usage_percent": ${DISK_USAGE_PCT:-0},
      "free": "${DISK_FREE_GB:-unknown}"
    },
    "memory": {
      "status": "${MEMORY_STATUS:-unknown}",
      "usage_percent": ${MEMORY_USAGE_PCT:-0},
      "total_mb": ${MEMORY_TOTAL_MB:-0},
      "used_mb": ${MEMORY_USED_MB:-0}
    },
    "cpu": {
      "status": "${CPU_STATUS:-unknown}",
      "load_1min": ${CPU_LOAD_1MIN:-0},
      "load_5min": ${CPU_LOAD_5MIN:-0},
      "load_15min": ${CPU_LOAD_15MIN:-0},
      "cores": ${CPU_CORES:-1}
    },
    "logs": {
      "status": "${LOGS_STATUS:-unknown}",
      "large_files": ${large_logs_json}
    }
  },
  "alerts": ${alerts_json},
  "alert_count": ${#ALERT_MESSAGES[@]}
}
REPORT_EOF

    # Restrict permissions — report contains service details and network info
    chmod 600 "${HEALTH_JSON}"
}

# =============================================================================
# Main execution
# =============================================================================
main() {
    # Run all checks
    check_xray
    check_tunnel
    check_new_api
    check_3xui
    check_disk
    check_memory
    check_cpu
    check_logs

    # Generate JSON report
    generate_report

    # Output summary to stdout (for cron log)
    echo "[${TIMESTAMP}] Health check complete: status=${OVERALL_STATUS}, alerts=${#ALERT_MESSAGES[@]}"

    # Exit with non-zero code if there are critical issues
    if [[ "${OVERALL_STATUS}" == "critical" ]]; then
        exit 2
    elif [[ "${OVERALL_STATUS}" == "degraded" ]]; then
        exit 1
    fi

    exit 0
}

main "$@"
