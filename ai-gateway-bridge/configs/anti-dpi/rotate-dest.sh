#!/usr/bin/env bash
# ==============================================================================
# AI Gateway Bridge - Standalone Dest Rotation Script (Cron)
# ==============================================================================
# Description : Rotates the Xray Reality destination ("dest") to a randomly
#               selected entry from the validated dest pool. Designed for
#               unattended cron execution with full error handling, config
#               validation, atomic replacement, and automatic rollback.
#
# Usage       : /opt/ai-gateway-bridge/rotate-dest.sh
#               (called weekly by cron, or manually for on-demand rotation)
#
# Cron entry  : 17 3 * * 0 /opt/ai-gateway-bridge/rotate-dest.sh >> /var/log/ai-gateway-bridge-rotate.log 2>&1
#
# Exit codes  :
#   0 - Rotation successful
#   1 - Fatal error (pool missing, jq missing, config invalid)
#   2 - Rotation failed but rollback succeeded
#   3 - Both rotation and rollback failed (manual intervention required)
#
# Project     : AI Gateway Bridge
# License     : MIT
# ==============================================================================

set -euo pipefail

# ==============================================================================
# Configuration
# ==============================================================================

readonly DEST_POOL_FILE="/opt/ai-gateway-bridge/dest-pool.txt"
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly XRAY_CONFIG_BACKUP="${XRAY_CONFIG}.pre-rotate.bak"
readonly XRAY_CONFIG_TMP="${XRAY_CONFIG}.rotate-tmp.$$"
readonly STATE_DIR="/opt/ai-gateway-bridge/.anti-dpi-state"
readonly STATE_FILE="${STATE_DIR}/state.env"
readonly LOCK_FILE="/var/run/ai-gateway-dest-rotate.lock"

readonly LOG_PREFIX="[dest-rotate]"

# Maximum time (seconds) to wait for Xray to become active after restart
readonly RESTART_TIMEOUT=15

# Maximum time (seconds) to hold the lock before considering it stale
readonly LOCK_TIMEOUT=300

# ==============================================================================
# Logging
# ==============================================================================

log_msg() {
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') ${LOG_PREFIX} $*"
}

log_info()    { log_msg "INFO  $*"; }
log_warn()    { log_msg "WARN  $*"; }
log_error()   { log_msg "ERROR $*"; }
log_success() { log_msg "OK    $*"; }

# ==============================================================================
# Locking (prevent concurrent rotations)
# ==============================================================================

acquire_lock() {
    # Check for stale lock
    if [[ -f "${LOCK_FILE}" ]]; then
        local lock_age
        lock_age=$(( $(date +%s) - $(stat -c %Y "${LOCK_FILE}" 2>/dev/null || echo "0") ))
        if [[ ${lock_age} -gt ${LOCK_TIMEOUT} ]]; then
            log_warn "Stale lock detected (age: ${lock_age}s). Removing."
            rm -f "${LOCK_FILE}"
        else
            log_error "Another rotation is in progress (lock age: ${lock_age}s). Exiting."
            exit 1
        fi
    fi

    # Atomic lock creation
    if ! (set -o noclobber; echo $$ > "${LOCK_FILE}") 2>/dev/null; then
        log_error "Failed to acquire lock. Another process may be running."
        exit 1
    fi
}

release_lock() {
    rm -f "${LOCK_FILE}"
}

# ==============================================================================
# Cleanup trap
# ==============================================================================

cleanup() {
    local exit_code=$?
    rm -f "${XRAY_CONFIG_TMP}"
    release_lock
    exit ${exit_code}
}

trap cleanup EXIT INT TERM

# ==============================================================================
# State management
# ==============================================================================

save_state() {
    local key="$1"
    local value="$2"
    mkdir -p "${STATE_DIR}"
    if [[ -f "${STATE_FILE}" ]]; then
        sed -i "/^${key}=/d" "${STATE_FILE}"
    fi
    echo "${key}=${value}" >> "${STATE_FILE}"
    chmod 600 "${STATE_FILE}"
}

load_state() {
    local key="$1"
    if [[ -f "${STATE_FILE}" ]]; then
        grep "^${key}=" "${STATE_FILE}" 2>/dev/null | head -1 | cut -d'=' -f2-
    fi
}

# ==============================================================================
# Prerequisite checks
# ==============================================================================

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check dest pool file
    if [[ ! -f "${DEST_POOL_FILE}" ]]; then
        log_error "Dest pool file not found: ${DEST_POOL_FILE}"
        log_error "Run 'deploy_anti_dpi' from the main installer to create it."
        exit 1
    fi

    # Check Xray config
    if [[ ! -f "${XRAY_CONFIG}" ]]; then
        log_error "Xray config not found: ${XRAY_CONFIG}"
        exit 1
    fi

    # Check jq
    if ! command -v jq &>/dev/null; then
        log_error "jq is not installed. Install it: apt install jq / yum install jq"
        exit 1
    fi

    # Check Xray binary
    if ! command -v xray &>/dev/null && [[ ! -x /usr/local/bin/xray ]]; then
        log_error "Xray binary not found."
        exit 1
    fi

    # Check systemd
    if ! command -v systemctl &>/dev/null; then
        log_error "systemctl not found. This script requires systemd."
        exit 1
    fi

    log_info "All prerequisites satisfied."
}

# ==============================================================================
# Pool loading
# ==============================================================================

load_pool() {
    local -n _pool_ref="$1"
    _pool_ref=()

    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ -z "${line}" ]] && continue
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue

        # Extract host:port (first whitespace-delimited token)
        local entry
        entry="$(echo "${line}" | awk '{print $1}')"

        # Basic validation: must contain a colon and port
        if [[ "${entry}" =~ ^[a-zA-Z0-9._-]+:[0-9]+$ ]]; then
            _pool_ref+=("${entry}")
        else
            log_warn "Skipping malformed pool entry: ${entry}"
        fi
    done < "${DEST_POOL_FILE}"

    if [[ ${#_pool_ref[@]} -eq 0 ]]; then
        log_error "Dest pool is empty after parsing: ${DEST_POOL_FILE}"
        exit 1
    fi

    log_info "Loaded ${#_pool_ref[@]} destinations from pool."
}

# ==============================================================================
# Current dest extraction
# ==============================================================================

get_current_dest() {
    local current
    current=$(jq -r '
        .inbounds[]
        | select(.streamSettings.security == "reality")
        | .streamSettings.realitySettings.dest
    ' "${XRAY_CONFIG}" 2>/dev/null | head -1) || true

    echo "${current}"
}

# ==============================================================================
# Random dest selection (different from current)
# ==============================================================================

select_random_dest() {
    local -n _pool="$1"
    local current="$2"

    local new_dest=""
    local attempts=0
    local max_attempts=30

    while [[ ${attempts} -lt ${max_attempts} ]]; do
        local idx=$(( RANDOM % ${#_pool[@]} ))
        local candidate="${_pool[${idx}]}"

        if [[ "${candidate}" != "${current}" ]] || [[ ${#_pool[@]} -eq 1 ]]; then
            new_dest="${candidate}"
            break
        fi
        attempts=$((attempts + 1))
    done

    # Fallback: linear scan for any entry != current
    if [[ -z "${new_dest}" ]]; then
        for entry in ${_pool[@]+"${_pool[@]}"}; do
            if [[ "${entry}" != "${current}" ]]; then
                new_dest="${entry}"
                break
            fi
        done
    fi

    # Last resort: use first entry even if same as current (single-entry pool)
    new_dest="${new_dest:-${_pool[0]}}"
    echo "${new_dest}"
}

# ==============================================================================
# Config update via jq
# ==============================================================================

update_config() {
    local new_dest="$1"
    local new_host
    new_host="$(echo "${new_dest}" | cut -d':' -f1)"

    log_info "Updating config: dest=${new_dest}, SNI=${new_host}"

    # Create backup
    cp -a "${XRAY_CONFIG}" "${XRAY_CONFIG_BACKUP}"

    # Apply jq transformation
    jq --arg new_dest "${new_dest}" --arg new_sni "${new_host}" '
        (.inbounds[] |
            select(.streamSettings.security == "reality") |
            .streamSettings.realitySettings
        ) |= (
            .dest = $new_dest |
            .serverNames = [$new_sni]
        )
    ' "${XRAY_CONFIG}" > "${XRAY_CONFIG_TMP}"

    # Validate jq output is well-formed JSON
    if ! jq empty "${XRAY_CONFIG_TMP}" 2>/dev/null; then
        log_error "jq produced invalid JSON output."
        rm -f "${XRAY_CONFIG_TMP}"
        return 1
    fi

    # Validate Xray can parse the new config
    local xray_bin
    xray_bin="$(command -v xray 2>/dev/null || echo '/usr/local/bin/xray')"

    if ! "${xray_bin}" run -test -config "${XRAY_CONFIG_TMP}" &>/dev/null; then
        log_error "Xray config validation failed for new config."
        "${xray_bin}" run -test -config "${XRAY_CONFIG_TMP}" 2>&1 || true
        rm -f "${XRAY_CONFIG_TMP}"
        return 1
    fi

    # Atomic-ish replacement (mv is atomic on same filesystem)
    mv -f "${XRAY_CONFIG_TMP}" "${XRAY_CONFIG}"
    chmod 600 "${XRAY_CONFIG}"

    log_info "Config file updated successfully."
    return 0
}

# ==============================================================================
# Xray restart with health check
# ==============================================================================

restart_xray() {
    log_info "Restarting Xray service..."
    systemctl restart xray.service

    local waited=0
    while [[ ${waited} -lt ${RESTART_TIMEOUT} ]]; do
        if systemctl is-active --quiet xray.service 2>/dev/null; then
            log_success "Xray is active after ${waited}s."
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    log_error "Xray did not become active within ${RESTART_TIMEOUT}s."
    journalctl -u xray --no-pager -n 15 2>/dev/null || true
    return 1
}

# ==============================================================================
# Rollback
# ==============================================================================

rollback() {
    log_warn "Initiating rollback..."

    if [[ ! -f "${XRAY_CONFIG_BACKUP}" ]]; then
        log_error "No backup file found for rollback: ${XRAY_CONFIG_BACKUP}"
        return 1
    fi

    cp -a "${XRAY_CONFIG_BACKUP}" "${XRAY_CONFIG}"
    log_info "Config restored from backup."

    if restart_xray; then
        log_warn "Rollback successful. Previous config restored and Xray running."
        rm -f "${XRAY_CONFIG_BACKUP}"
        return 0
    else
        log_error "CRITICAL: Rollback failed. Xray is not running."
        log_error "Manual intervention required. Backup at: ${XRAY_CONFIG_BACKUP}"
        return 1
    fi
}

# ==============================================================================
# Main execution
# ==============================================================================

main() {
    log_info "===== Dest rotation started ====="

    acquire_lock
    check_prerequisites

    # Load pool
    local -a pool=()
    load_pool pool

    # Get current dest
    local current_dest
    current_dest="$(get_current_dest)"
    log_info "Current dest: ${current_dest:-<not set>}"

    # Select new random dest
    local new_dest
    new_dest="$(select_random_dest pool "${current_dest}")"
    log_info "Selected new dest: ${new_dest}"

    if [[ "${new_dest}" == "${current_dest}" ]]; then
        log_warn "New dest is same as current (single-entry pool). Rotation is a no-op."
        log_info "===== Dest rotation completed (no change) ====="
        exit 0
    fi

    # Update config
    if ! update_config "${new_dest}"; then
        log_error "Config update failed. No changes made."
        exit 1
    fi

    # Restart Xray
    if restart_xray; then
        # Success: record state and clean up
        save_state "LAST_DEST" "${new_dest}"
        save_state "LAST_ROTATION" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

        local count
        count="$(load_state 'ROTATION_COUNT')"
        count="${count:-0}"
        save_state "ROTATION_COUNT" "$(( count + 1 ))"

        rm -f "${XRAY_CONFIG_BACKUP}"
        log_success "Rotation complete: ${current_dest:-<none>} -> ${new_dest}"
        local new_host
        new_host="$(echo "${new_dest}" | cut -d':' -f1)"
        log_warn "SERVER A SNI SYNC REQUIRED: new SNI is '${new_host}'"
        log_warn "Run on Server A: bash /opt/bifrost/scripts/sync-sni-to-a.sh --new-sni '${new_host}'"

        if [[ -d /etc/anti-dpi/post-rotate.d ]]; then
            local hook
            for hook in /etc/anti-dpi/post-rotate.d/*.sh; do
                [[ -x "${hook}" ]] || continue
                log_info "Running post-rotate hook: ${hook}"
                "${hook}" "${new_host}" "${new_dest}" || log_warn "Hook ${hook} exited non-zero"
            done
        fi
        log_info "===== Dest rotation finished successfully ====="
        exit 0
    else
        # Restart failed -- rollback
        log_error "Xray restart failed after config update."
        if rollback; then
            log_warn "Rollback succeeded. Previous dest restored."
            log_info "===== Dest rotation finished with rollback ====="
            exit 2
        else
            log_error "CRITICAL: Both rotation and rollback failed."
            log_error "===== Dest rotation finished with CRITICAL FAILURE ====="
            exit 3
        fi
    fi
}

# ==============================================================================
# Entry point
# ==============================================================================

main "$@"
