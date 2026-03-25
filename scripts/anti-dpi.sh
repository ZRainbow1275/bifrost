#!/usr/bin/env bash
# ==============================================================================
# Bifrost - Deep Packet Inspection (DPI) Anti-Detection Module
# ==============================================================================
# Description : Implements multiple layers of anti-DPI defense for the
#               VLESS+Reality tunnel, including:
#               - Reality dest pool management with TLS 1.3 + H2 validation
#               - Automated dest rotation (random selection + Xray live reload)
#               - uTLS fingerprint spoofing (chrome/firefox/edge/safari/randomized)
#               - Mux + padding for traffic analysis resistance
#               - Active probing defense via Xray fallback chains
#               - Cron-based weekly dest rotation
#
# Usage       : source "$(dirname "${BASH_SOURCE[0]}")/anti-dpi.sh"
#               deploy_anti_dpi    # Full orchestration
#
# Project     : Bifrost
# License     : MIT
# ==============================================================================

set -euo pipefail

# Guard against double-sourcing (readonly variables would conflict)
if [[ -n "${_ANTI_DPI_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
readonly _ANTI_DPI_SH_LOADED=1

# Source shared utilities
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ==============================================================================
# Constants
# ==============================================================================

readonly ANTI_DPI_BASE_DIR="/opt/bifrost"
[[ -v DEST_POOL_FILE ]]   || readonly DEST_POOL_FILE="${ANTI_DPI_BASE_DIR}/dest-pool.txt"
# Guarded — may already be defined by server-b.sh or server-a.sh
[[ -v XRAY_CONFIG_DIR ]]  || readonly XRAY_CONFIG_DIR="/usr/local/etc/xray"
[[ -v XRAY_CONFIG_FILE ]] || readonly XRAY_CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"
[[ -v XRAY_LOG_DIR ]]     || readonly XRAY_LOG_DIR="/var/log/xray"
readonly ROTATE_CRON_SCRIPT="/opt/bifrost/rotate-dest.sh"
readonly ROTATE_LOG_FILE="/var/log/bifrost-rotate.log"
readonly ANTI_DPI_STATE_DIR="/opt/bifrost/.anti-dpi-state"

# Project-relative config path for the bundled dest-pool file
readonly _ANTI_DPI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly _ANTI_DPI_PROJECT_ROOT="$(cd "${_ANTI_DPI_SCRIPT_DIR}/.." && pwd)"
readonly BUNDLED_DEST_POOL="${_ANTI_DPI_PROJECT_ROOT}/configs/anti-dpi/dest-pool.txt"
readonly BUNDLED_ROTATE_SCRIPT="${_ANTI_DPI_PROJECT_ROOT}/configs/anti-dpi/rotate-dest.sh"

# TLS 1.3 required cipher suites for validation
readonly -a TLS13_CIPHERS=(
    "TLS_AES_128_GCM_SHA256"
    "TLS_AES_256_GCM_SHA384"
    "TLS_CHACHA20_POLY1305_SHA256"
)

# Supported uTLS fingerprint identifiers (Xray-core compatible)
readonly -a UTLS_FINGERPRINTS=(
    "chrome"
    "firefox"
    "edge"
    "safari"
    "randomized"
    "random"
    "ios"
    "android"
    "360"
    "qq"
)

# ==============================================================================
# Internal Helpers
# ==============================================================================

# ------------------------------------------------------------------------------
# _ensure_anti_dpi_dirs: Create all required directories
# ------------------------------------------------------------------------------
_ensure_anti_dpi_dirs() {
    mkdir -p "${ANTI_DPI_BASE_DIR}" "${ANTI_DPI_STATE_DIR}"
    chmod 700 "${ANTI_DPI_STATE_DIR}"
}

# ------------------------------------------------------------------------------
# _save_anti_dpi_state: Persist a key=value pair for anti-DPI state
# Arguments: $1 - key, $2 - value
# ------------------------------------------------------------------------------
_save_anti_dpi_state() {
    local key="$1"
    local value="$2"
    _ensure_anti_dpi_dirs

    local state_file="${ANTI_DPI_STATE_DIR}/state.env"
    if [[ -f "${state_file}" ]]; then
        sed -i "/^${key}=/d" "${state_file}"
    fi
    echo "${key}=${value}" >> "${state_file}"
    chmod 600 "${state_file}"
}

# ------------------------------------------------------------------------------
# _load_anti_dpi_state: Read a value by key from anti-DPI state
# Arguments: $1 - key
# Returns: value via stdout, empty if not found
# ------------------------------------------------------------------------------
_load_anti_dpi_state() {
    local key="$1"
    local state_file="${ANTI_DPI_STATE_DIR}/state.env"
    if [[ -f "${state_file}" ]]; then
        grep "^${key}=" "${state_file}" 2>/dev/null | head -1 | cut -d'=' -f2-
    fi
}

# ------------------------------------------------------------------------------
# _require_jq: Ensure jq is installed (required for JSON config manipulation)
# ------------------------------------------------------------------------------
_require_jq() {
    if ! command -v jq &>/dev/null; then
        log_info "Installing jq (required for JSON config manipulation)..."
        install_if_missing jq jq
    fi
}

# ------------------------------------------------------------------------------
# _require_xray: Verify Xray binary exists and return its path
# Returns: xray binary path via stdout
# ------------------------------------------------------------------------------
_require_xray() {
    local xray_bin=""
    if command -v xray &>/dev/null; then
        xray_bin="$(command -v xray)"
    elif [[ -x /usr/local/bin/xray ]]; then
        xray_bin="/usr/local/bin/xray"
    elif [[ -x /usr/bin/xray ]]; then
        xray_bin="/usr/bin/xray"
    else
        die "Xray binary not found. Deploy Xray server first."
    fi
    echo "${xray_bin}"
}

# ------------------------------------------------------------------------------
# _validate_xray_config: Test Xray config file syntax
# Arguments: $1 - config file path (optional, defaults to XRAY_CONFIG_FILE)
# Returns: 0 if valid, 1 if invalid
# ------------------------------------------------------------------------------
_validate_xray_config() {
    local config="${1:-${XRAY_CONFIG_FILE}}"
    local xray_bin
    xray_bin="$(_require_xray)"

    if "${xray_bin}" run -test -config "${config}" &>/dev/null; then
        return 0
    else
        log_error "Xray configuration validation failed for: ${config}"
        "${xray_bin}" run -test -config "${config}" 2>&1 || true
        return 1
    fi
}

# ------------------------------------------------------------------------------
# _graceful_restart_xray: Restart Xray with config validation and rollback
# Returns: 0 on success, 1 on failure (with automatic rollback)
# ------------------------------------------------------------------------------
_graceful_restart_xray() {
    local backup_config="${XRAY_CONFIG_FILE}.pre-rotate.bak"

    # Create backup before restart attempt
    if [[ -f "${XRAY_CONFIG_FILE}" ]]; then
        cp -a "${XRAY_CONFIG_FILE}" "${backup_config}"
    fi

    # Validate config before restart
    if ! _validate_xray_config; then
        log_error "Config validation failed. Restoring backup..."
        if [[ -f "${backup_config}" ]]; then
            cp -a "${backup_config}" "${XRAY_CONFIG_FILE}"
            log_warn "Restored previous configuration from backup."
        fi
        return 1
    fi

    # Attempt graceful restart
    log_info "Restarting Xray service..."
    systemctl restart xray.service

    # Wait up to 10 seconds for the service to stabilize
    local waited=0
    while [[ ${waited} -lt 10 ]]; do
        if systemctl is-active --quiet xray.service 2>/dev/null; then
            log_success "Xray service restarted successfully."
            # Clean up backup on success
            rm -f "${backup_config}"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    # Restart failed -- rollback
    log_error "Xray failed to start after restart. Rolling back config..."
    if [[ -f "${backup_config}" ]]; then
        cp -a "${backup_config}" "${XRAY_CONFIG_FILE}"
        systemctl restart xray.service
        sleep 3
        if systemctl is-active --quiet xray.service 2>/dev/null; then
            log_warn "Rollback successful. Previous config restored and Xray running."
        else
            log_error "CRITICAL: Rollback also failed. Manual intervention required."
            journalctl -u xray --no-pager -n 30 2>/dev/null || true
        fi
    fi
    return 1
}

# ==============================================================================
# 1. setup_reality_dest_pool()
# ==============================================================================
# Populate the dest pool file with vetted destinations.
# Each destination is validated for TLS 1.3 and HTTP/2 support.
# The pool file uses the format: dest_host:dest_port # description
# ==============================================================================
setup_reality_dest_pool() {
    log_info "=========================================="
    log_info " Setting up Reality destination pool"
    log_info "=========================================="

    _ensure_anti_dpi_dirs
    install_if_missing curl curl
    install_if_missing openssl openssl

    # Copy bundled pool file as the base, or create from defaults
    if [[ -f "${BUNDLED_DEST_POOL}" ]]; then
        log_info "Using bundled dest pool from project configs..."
        cp -a "${BUNDLED_DEST_POOL}" "${DEST_POOL_FILE}.candidate"
    else
        log_warn "Bundled dest pool not found. Creating default pool..."
        _generate_default_dest_pool "${DEST_POOL_FILE}.candidate"
    fi

    # Validate each destination in the candidate pool
    local valid_count=0
    local total_count=0
    local validated_file="${DEST_POOL_FILE}.validated"
    : > "${validated_file}"

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ -z "${line}" ]] && continue
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue

        total_count=$((total_count + 1))
        local dest_entry
        dest_entry="$(echo "${line}" | awk '{print $1}')"
        local dest_host
        dest_host="$(echo "${dest_entry}" | cut -d':' -f1)"
        local dest_port
        dest_port="$(echo "${dest_entry}" | cut -d':' -f2)"
        dest_port="${dest_port:-443}"

        log_info "Validating [${total_count}]: ${dest_host}:${dest_port}..."

        if _validate_dest_tls13_h2 "${dest_host}" "${dest_port}"; then
            echo "${line}" >> "${validated_file}"
            valid_count=$((valid_count + 1))
            log_success "  PASS: ${dest_host}:${dest_port} (TLS 1.3 + H2)"
        else
            log_warn "  FAIL: ${dest_host}:${dest_port} (skipped - does not meet TLS 1.3 + H2 requirements)"
        fi
    done < "${DEST_POOL_FILE}.candidate"

    # Ensure we have a minimum viable pool
    if [[ ${valid_count} -lt 3 ]]; then
        log_error "Only ${valid_count}/${total_count} destinations passed validation."
        log_error "Minimum 3 valid destinations required for rotation safety."
        log_warn "Falling back to known-good defaults..."
        _generate_fallback_pool "${validated_file}"
        valid_count=$(grep -cve '^\s*$' -e '^\s*#' "${validated_file}" 2>/dev/null || echo "0")
    fi

    # Install the validated pool
    mv -f "${validated_file}" "${DEST_POOL_FILE}"
    chmod 644 "${DEST_POOL_FILE}"
    rm -f "${DEST_POOL_FILE}.candidate"

    _save_anti_dpi_state "DEST_POOL_SIZE" "${valid_count}"
    _save_anti_dpi_state "DEST_POOL_LAST_VALIDATED" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    log_success "Dest pool installed: ${DEST_POOL_FILE} (${valid_count} validated destinations)"
}

# ------------------------------------------------------------------------------
# _validate_dest_tls13_h2: Check if a host:port supports TLS 1.3 and H2 (ALPN)
# Arguments: $1 - hostname, $2 - port (default 443)
# Returns: 0 if both TLS 1.3 and H2 are supported, 1 otherwise
# ------------------------------------------------------------------------------
_validate_dest_tls13_h2() {
    local host="$1"
    local port="${2:-443}"

    # Timeout for slow/unreachable hosts
    local timeout=10

    # Use openssl s_client to probe TLS handshake
    local tls_output
    tls_output=$(echo "" | timeout "${timeout}" openssl s_client \
        -connect "${host}:${port}" \
        -tls1_3 \
        -alpn h2,http/1.1 \
        -servername "${host}" \
        2>&1) || true

    # Check 1: TLS 1.3 negotiated
    if ! echo "${tls_output}" | grep -qi "TLSv1\.3"; then
        # Some openssl versions report "Protocol  : TLSv1.3" differently
        if ! echo "${tls_output}" | grep -qi "Protocol.*1\.3"; then
            log_warn "    TLS 1.3 not negotiated for ${host}:${port}"
            return 1
        fi
    fi

    # Check 2: H2 ALPN negotiated
    if ! echo "${tls_output}" | grep -qi "ALPN.*h2"; then
        # Fallback check: some openssl versions display it differently
        if ! echo "${tls_output}" | grep -qi "Next protocol.*h2"; then
            log_warn "    H2 ALPN not negotiated for ${host}:${port}"
            return 1
        fi
    fi

    # Check 3: Valid certificate (connection succeeded)
    if echo "${tls_output}" | grep -qi "verify error"; then
        # Not a hard fail -- some CAs are just not in system store
        # As long as TLS1.3+H2 works, the dest is usable for Reality
        log_warn "    Certificate verify warning for ${host}:${port} (non-blocking)"
    fi

    return 0
}

# ------------------------------------------------------------------------------
# _generate_default_dest_pool: Write default destinations to a file
# Arguments: $1 - output file path
# ------------------------------------------------------------------------------
_generate_default_dest_pool() {
    local output="$1"
    cat > "${output}" <<'POOL_EOF'
# ==============================================================================
# Bifrost - Reality Destination Pool
# ==============================================================================
# Format: host:port  # description
#
# Requirements for each destination:
#   1. Must support TLS 1.3
#   2. Must support HTTP/2 (H2 ALPN)
#   3. Should be high-traffic, reputable sites (blends in with normal traffic)
#   4. Should have stable uptime and low latency from major regions
#   5. Should NOT be on common block lists
#
# These sites are used as the Reality "dest" -- the server mimics their TLS
# fingerprint. Traffic to these sites is never actually proxied; they are
# only used for the TLS handshake camouflage.
# ==============================================================================

dl.google.com:443             # Google Download - massive global CDN, stable TLS 1.3 + H2
www.microsoft.com:443         # Microsoft corporate - enterprise traffic, very common
www.apple.com:443             # Apple main site - trusted CA, H2, global CDN
www.samsung.com:443           # Samsung - large consumer electronics, global CDN
www.mozilla.org:443           # Mozilla Foundation - HTTPS pioneer, strong TLS config
addons.mozilla.org:443        # Mozilla Add-ons - high traffic, TLS 1.3 + H2
www.logitech.com:443          # Logitech - consumer electronics, Cloudflare CDN
www.amd.com:443               # AMD - semiconductor company, stable enterprise hosting
www.intel.com:443             # Intel - semiconductor giant, Akamai CDN
developer.android.com:443     # Android Developer - Google infrastructure, TLS 1.3 + H2
cloud.google.com:443          # Google Cloud - enterprise SaaS traffic pattern
www.asus.com:443              # ASUS - electronics manufacturer, Cloudflare CDN
POOL_EOF
}

# ------------------------------------------------------------------------------
# _generate_fallback_pool: Write minimal known-good fallback destinations
# Arguments: $1 - output file path (appends to existing)
# ------------------------------------------------------------------------------
_generate_fallback_pool() {
    local output="$1"
    cat >> "${output}" <<'FALLBACK_EOF'
# --- Fallback destinations (known-good, added automatically) ---
dl.google.com:443             # Google Download CDN (fallback)
www.microsoft.com:443         # Microsoft (fallback)
www.apple.com:443             # Apple (fallback)
www.mozilla.org:443           # Mozilla (fallback)
FALLBACK_EOF
}

# ==============================================================================
# 2. rotate_dest()
# ==============================================================================
# Randomly select a destination from the pool, update the Xray server config
# with jq, validate, and graceful-restart. Designed to be called interactively
# or from the cron rotation script.
# ==============================================================================
rotate_dest() {
    log_info "=========================================="
    log_info " Rotating Reality destination"
    log_info "=========================================="

    _require_jq

    # ---- Verify pool file exists and has entries ----
    if [[ ! -f "${DEST_POOL_FILE}" ]]; then
        die "Dest pool file not found: ${DEST_POOL_FILE}. Run setup_reality_dest_pool first."
    fi

    # Read valid (non-comment, non-empty) lines into an array
    local -a pool_entries=()
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        pool_entries+=("$(echo "${line}" | awk '{print $1}')")
    done < "${DEST_POOL_FILE}"

    if [[ ${#pool_entries[@]} -eq 0 ]]; then
        die "Dest pool is empty: ${DEST_POOL_FILE}"
    fi

    # ---- Read current dest from Xray config ----
    if [[ ! -f "${XRAY_CONFIG_FILE}" ]]; then
        die "Xray config not found: ${XRAY_CONFIG_FILE}"
    fi

    local current_dest
    current_dest=$(jq -r '
        .inbounds[]
        | select(.streamSettings.security == "reality")
        | .streamSettings.realitySettings.dest
    ' "${XRAY_CONFIG_FILE}" 2>/dev/null | head -1) || true

    log_info "Current dest: ${current_dest:-<not set>}"
    log_info "Pool size: ${#pool_entries[@]} destinations"

    # ---- Select a random destination different from current ----
    local new_dest=""
    local new_host=""
    local attempts=0
    local max_attempts=20

    while [[ ${attempts} -lt ${max_attempts} ]]; do
        local idx=$((RANDOM % ${#pool_entries[@]}))
        local candidate="${pool_entries[${idx}]}"

        if [[ "${candidate}" != "${current_dest}" ]] || [[ ${#pool_entries[@]} -eq 1 ]]; then
            new_dest="${candidate}"
            break
        fi
        attempts=$((attempts + 1))
    done

    if [[ -z "${new_dest}" ]]; then
        # Exhausted attempts, just pick the first one different from current
        for entry in ${pool_entries[@]+"${pool_entries[@]}"}; do
            if [[ "${entry}" != "${current_dest}" ]]; then
                new_dest="${entry}"
                break
            fi
        done
        # If still empty (only one entry), use it anyway
        new_dest="${new_dest:-${pool_entries[0]}}"
    fi

    new_host="$(echo "${new_dest}" | cut -d':' -f1)"
    log_info "Selected new dest: ${new_dest}"
    log_info "Derived SNI: ${new_host}"

    # ---- Update Xray config with jq ----
    # We update both `dest` and `serverNames` in the realitySettings
    local tmp_config="${XRAY_CONFIG_FILE}.tmp.$$"

    jq --arg new_dest "${new_dest}" --arg new_sni "${new_host}" '
        (.inbounds[] |
            select(.streamSettings.security == "reality") |
            .streamSettings.realitySettings
        ) |= (
            .dest = $new_dest |
            .serverNames = [$new_sni]
        )
    ' "${XRAY_CONFIG_FILE}" > "${tmp_config}"

    # Verify jq output is valid JSON
    if ! jq empty "${tmp_config}" 2>/dev/null; then
        log_error "jq produced invalid JSON. Aborting rotation."
        rm -f "${tmp_config}"
        return 1
    fi

    # Install the new config
    mv -f "${tmp_config}" "${XRAY_CONFIG_FILE}"
    chmod 600 "${XRAY_CONFIG_FILE}"

    # ---- Validate and restart ----
    if _graceful_restart_xray; then
        _save_anti_dpi_state "LAST_DEST" "${new_dest}"
        _save_anti_dpi_state "LAST_ROTATION" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        local _rotation_count
        _rotation_count="$(_load_anti_dpi_state "ROTATION_COUNT")"
        _save_anti_dpi_state "ROTATION_COUNT" "$(( ${_rotation_count:-0} + 1 ))"
        log_success "Dest rotated: ${current_dest:-<none>} -> ${new_dest}"
    else
        log_error "Dest rotation failed. Previous config has been restored."
        return 1
    fi
}

# ==============================================================================
# 3. setup_utls_fingerprint()
# ==============================================================================
# Configure the uTLS client fingerprint on the Xray CLIENT config.
# Defaults to "chrome" (most common browser, best camouflage).
# Supports: chrome, firefox, edge, safari, randomized, random, ios, android.
#
# NOTE: This modifies the CLIENT-side config. On the server side, Reality
# automatically mirrors whatever fingerprint the client presents.
# ==============================================================================
setup_utls_fingerprint() {
    local fingerprint="${1:-chrome}"

    log_info "=========================================="
    log_info " Configuring uTLS fingerprint: ${fingerprint}"
    log_info "=========================================="

    _require_jq

    # ---- Validate fingerprint identifier ----
    local valid=0
    for fp in ${UTLS_FINGERPRINTS[@]+"${UTLS_FINGERPRINTS[@]}"}; do
        if [[ "${fp}" == "${fingerprint}" ]]; then
            valid=1
            break
        fi
    done

    if [[ ${valid} -eq 0 ]]; then
        log_error "Invalid fingerprint: ${fingerprint}"
        log_error "Supported values: ${UTLS_FINGERPRINTS[*]}"
        return 1
    fi

    # ---- Determine which config to modify ----
    # On Server B: update the template defaults
    # On a standalone client: update the live config
    local target_config="${XRAY_CONFIG_FILE}"
    if [[ ! -f "${target_config}" ]]; then
        die "Xray config not found: ${target_config}"
    fi

    # ---- Check if this is a client config (has realitySettings.fingerprint) ----
    local has_fingerprint
    has_fingerprint=$(jq '
        [.. | objects | select(has("fingerprint"))] | length
    ' "${target_config}" 2>/dev/null) || has_fingerprint="0"

    if [[ "${has_fingerprint}" == "0" ]]; then
        # Server-side config: update the server's Reality dest fingerprint tracking
        # The server does not have a "fingerprint" field itself, but we record
        # the recommended fingerprint for client distribution
        log_info "Server-side config detected. Recording recommended fingerprint for clients."
        _save_anti_dpi_state "RECOMMENDED_FINGERPRINT" "${fingerprint}"
        log_success "Recommended client fingerprint set to: ${fingerprint}"
        return 0
    fi

    # Client-side: update all fingerprint fields in realitySettings
    local tmp_config="${target_config}.tmp.$$"

    jq --arg fp "${fingerprint}" '
        (.. | objects | select(has("fingerprint")).fingerprint) |= $fp
    ' "${target_config}" > "${tmp_config}"

    if ! jq empty "${tmp_config}" 2>/dev/null; then
        log_error "jq produced invalid JSON while updating fingerprint."
        rm -f "${tmp_config}"
        return 1
    fi

    mv -f "${tmp_config}" "${target_config}"
    chmod 600 "${target_config}"

    # Validate and restart if it is a running Xray instance
    if systemctl is-active --quiet xray.service 2>/dev/null; then
        if _graceful_restart_xray; then
            log_success "uTLS fingerprint updated to '${fingerprint}' and Xray restarted."
        else
            log_error "Failed to restart Xray after fingerprint update."
            return 1
        fi
    else
        log_success "uTLS fingerprint updated to '${fingerprint}' in config."
        log_info "Xray is not currently running. Changes will apply on next start."
    fi

    _save_anti_dpi_state "UTLS_FINGERPRINT" "${fingerprint}"
}

# ==============================================================================
# 4. configure_mux_padding()
# ==============================================================================
# Add or update the mux configuration with padding enabled in the Xray config.
# Mux multiplexes multiple connections over a single TCP stream, and padding
# adds random bytes to resist traffic pattern analysis.
#
# This is applied to the CLIENT-side outbound (proxy) config.
# On the server side, mux is automatically handled if the client requests it.
# ==============================================================================
configure_mux_padding() {
    log_info "=========================================="
    log_info " Configuring Mux + Padding"
    log_info "=========================================="

    _require_jq

    local target_config="${XRAY_CONFIG_FILE}"
    if [[ ! -f "${target_config}" ]]; then
        die "Xray config not found: ${target_config}"
    fi

    # ---- Determine config type ----
    # Client configs have outbounds with "vnext" (VLESS client)
    # Server configs have inbounds with Reality
    local is_client
    is_client=$(jq '
        [.outbounds[]? | select(.settings.vnext != null)] | length
    ' "${target_config}" 2>/dev/null) || is_client="0"

    if [[ "${is_client}" == "0" ]]; then
        # Server-side: add mux inbound settings
        log_info "Server-side config detected. Enabling mux concurrency acceptance..."

        # On the server, mux is handled transparently by Xray when the client
        # sends mux-multiplexed traffic. No explicit server-side config needed
        # for basic mux. However, we can set sniffing to handle mux properly.
        log_info "Server-side mux is handled transparently by Xray."
        log_info "Ensuring sniffing is configured to work with mux..."

        local tmp_config="${target_config}.tmp.$$"
        jq '
            (.inbounds[] |
                select(.streamSettings.security == "reality") |
                .sniffing
            ) |= (
                .enabled = true |
                .destOverride = ["http", "tls", "quic"] |
                .routeOnly = false
            )
        ' "${target_config}" > "${tmp_config}"

        if ! jq empty "${tmp_config}" 2>/dev/null; then
            log_error "jq produced invalid JSON while updating server sniffing."
            rm -f "${tmp_config}"
            return 1
        fi

        mv -f "${tmp_config}" "${target_config}"
        chmod 600 "${target_config}"

        _save_anti_dpi_state "MUX_SERVER_SNIFFING" "enabled"
        log_success "Server-side sniffing configured for mux compatibility."
    else
        # Client-side: add mux with padding to the VLESS outbound
        log_info "Client-side config detected. Adding mux + padding to proxy outbound..."

        local tmp_config="${target_config}.tmp.$$"

        # Xray mux configuration with padding (XUDP-only mode)
        # - enabled: activate mux
        # - concurrency: -1 means XUDP-only mode (no TCP mux). This is REQUIRED
        #   when flow="xtls-rprx-vision" is set, because Vision handles TCP
        #   connections directly and is incompatible with TCP-level mux.
        #   Traditional mux (concurrency > 0) will cause Xray to error out.
        # - xudpConcurrency: UDP mux connections
        # - xudpProxyUDP443: "reject" to avoid QUIC fingerprinting issues
        # - padding: true to add random padding bytes against traffic analysis
        jq '
            (.outbounds[] | select(.settings.vnext != null)) |= (
                .mux = {
                    "enabled": true,
                    "concurrency": -1,
                    "xudpConcurrency": 16,
                    "xudpProxyUDP443": "reject",
                    "padding": true
                }
            )
        ' "${target_config}" > "${tmp_config}"

        if ! jq empty "${tmp_config}" 2>/dev/null; then
            log_error "jq produced invalid JSON while adding mux config."
            rm -f "${tmp_config}"
            return 1
        fi

        mv -f "${tmp_config}" "${target_config}"
        chmod 600 "${target_config}"

        # Restart if running
        if systemctl is-active --quiet xray.service 2>/dev/null; then
            if _graceful_restart_xray; then
                log_success "Mux + padding enabled and Xray restarted."
            else
                log_error "Failed to restart Xray after mux configuration."
                return 1
            fi
        else
            log_success "Mux + padding configured. Will apply on next Xray start."
        fi

        _save_anti_dpi_state "MUX_PADDING" "enabled"
        _save_anti_dpi_state "MUX_CONCURRENCY" "-1"
    fi
}

# ==============================================================================
# 5. setup_active_probe_defense()
# ==============================================================================
# Configure Xray server fallbacks to defend against active probing attacks.
# When a non-VLESS connection hits the Reality port (e.g., GFW active probe),
# the traffic is forwarded to fallback destinations that serve legitimate
# web content, making the server indistinguishable from a real HTTPS site.
#
# Fallback chain:
#   1. Default fallback -> local HTTPS page (or Caddy proxy)
#   2. ALPN "h2" fallback -> HTTP/2 handler
#   3. Path-based fallback -> different handlers per path
# ==============================================================================
setup_active_probe_defense() {
    log_info "=========================================="
    log_info " Configuring Active Probe Defense"
    log_info "=========================================="

    _require_jq

    local target_config="${XRAY_CONFIG_FILE}"
    if [[ ! -f "${target_config}" ]]; then
        die "Xray config not found: ${target_config}"
    fi

    # ---- Check if this is a server config ----
    local has_reality_inbound
    has_reality_inbound=$(jq '
        [.inbounds[] | select(.streamSettings.security == "reality")] | length
    ' "${target_config}" 2>/dev/null) || has_reality_inbound="0"

    if [[ "${has_reality_inbound}" == "0" ]]; then
        log_warn "No Reality inbound found in config. Active probe defense is server-side only."
        log_info "Skipping on client config."
        return 0
    fi

    # ---- Determine fallback targets ----
    # Check if Caddy is running locally for the best fallback experience
    local fallback_http_port=8080
    local fallback_h2_port=8443

    if systemctl is-active --quiet caddy.service 2>/dev/null; then
        log_info "Caddy detected. Using Caddy as fallback target for active probes."
        # Caddy typically listens on 80/443, we use its HTTP handler
        fallback_http_port=80
        fallback_h2_port=80
    else
        log_info "Caddy not detected. Setting up a minimal fallback web handler."
        _setup_fallback_web_handler "${fallback_http_port}"
    fi

    # ---- Add fallbacks to the Reality inbound ----
    local tmp_config="${target_config}.tmp.$$"

    jq --argjson http_port "${fallback_http_port}" --argjson h2_port "${fallback_h2_port}" '
        (.inbounds[] |
            select(.streamSettings.security == "reality")
        ) |= (
            .settings.fallbacks = [
                {
                    "alpn": "h2",
                    "dest": $h2_port,
                    "xver": 1
                },
                {
                    "dest": $http_port,
                    "xver": 1
                }
            ]
        )
    ' "${target_config}" > "${tmp_config}"

    if ! jq empty "${tmp_config}" 2>/dev/null; then
        log_error "jq produced invalid JSON while adding fallbacks."
        rm -f "${tmp_config}"
        return 1
    fi

    mv -f "${tmp_config}" "${target_config}"
    chmod 600 "${target_config}"

    # Validate and restart
    if _graceful_restart_xray; then
        _save_anti_dpi_state "ACTIVE_PROBE_DEFENSE" "enabled"
        _save_anti_dpi_state "FALLBACK_HTTP_PORT" "${fallback_http_port}"
        _save_anti_dpi_state "FALLBACK_H2_PORT" "${fallback_h2_port}"
        log_success "Active probe defense configured with fallbacks."
        log_info "  HTTP/1.1 fallback -> 127.0.0.1:${fallback_http_port}"
        log_info "  H2 fallback       -> 127.0.0.1:${fallback_h2_port}"
    else
        log_error "Failed to apply active probe defense configuration."
        return 1
    fi
}

# ------------------------------------------------------------------------------
# _setup_fallback_web_handler: Create a minimal Nginx/Python fallback if no
# web server is available. Serves a bland corporate-looking page.
# Arguments: $1 - port to listen on
# ------------------------------------------------------------------------------
_setup_fallback_web_handler() {
    local port="$1"

    # Check if something is already listening on the port
    if ss -tlnp 2>/dev/null | grep -qE ":${port}\b"; then
        log_info "Port ${port} already in use. Assuming existing web handler."
        return 0
    fi

    # Create a minimal HTML page
    local web_root="/var/www/anti-dpi-fallback"
    mkdir -p "${web_root}"

    cat > "${web_root}/index.html" <<'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
               display: flex; justify-content: center; align-items: center;
               min-height: 100vh; margin: 0; background: #f5f5f5; color: #333; }
        .container { text-align: center; max-width: 600px; padding: 2rem; }
        h1 { font-weight: 300; font-size: 2rem; margin-bottom: 1rem; }
        p { color: #666; line-height: 1.6; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Service Available</h1>
        <p>This server is operating normally. For authorized access, please contact the system administrator.</p>
    </div>
</body>
</html>
HTML_EOF

    # Use Python's built-in HTTP server as a lightweight fallback
    if command -v python3 &>/dev/null; then
        log_info "Starting Python HTTP fallback on port ${port}..."

        cat > /etc/systemd/system/anti-dpi-fallback.service <<SERVICE_EOF
[Unit]
Description=Anti-DPI Fallback Web Handler
After=network.target

[Service]
Type=simple
WorkingDirectory=${web_root}
ExecStart=/usr/bin/python3 -m http.server ${port} --bind 127.0.0.1
Restart=on-failure
RestartSec=5
User=nobody
Group=nogroup

[Install]
WantedBy=multi-user.target
SERVICE_EOF

        systemctl daemon-reload
        systemctl enable --now anti-dpi-fallback.service
        sleep 2

        if systemctl is-active --quiet anti-dpi-fallback.service; then
            log_success "Fallback web handler running on 127.0.0.1:${port}"
        else
            log_warn "Fallback web handler failed to start. Active probe defense may be degraded."
        fi
    else
        log_warn "python3 not found. Cannot create fallback web handler."
        log_warn "Install a web server (Caddy recommended) for proper active probe defense."
    fi
}

# ==============================================================================
# 6. setup_dest_rotation_cron()
# ==============================================================================
# Install a weekly cron job that rotates the Reality dest automatically.
# Uses the standalone rotate-dest.sh script for cron execution.
# ==============================================================================
setup_dest_rotation_cron() {
    log_info "=========================================="
    log_info " Setting up dest rotation cron job"
    log_info "=========================================="

    _ensure_anti_dpi_dirs

    # ---- Install the standalone rotation script ----
    if [[ -f "${BUNDLED_ROTATE_SCRIPT}" ]]; then
        log_info "Installing rotation script from project bundle..."
        cp -a "${BUNDLED_ROTATE_SCRIPT}" "${ROTATE_CRON_SCRIPT}"
    else
        log_info "Generating standalone rotation script..."
        _generate_rotate_script "${ROTATE_CRON_SCRIPT}"
    fi

    chmod 700 "${ROTATE_CRON_SCRIPT}"
    chown root:root "${ROTATE_CRON_SCRIPT}"

    # ---- Create cron entry ----
    # Schedule: every Sunday at 03:17 UTC (random-ish minute to avoid patterns)
    local cron_schedule="17 3 * * 0"
    local cron_line="${cron_schedule} ${ROTATE_CRON_SCRIPT} >> ${ROTATE_LOG_FILE} 2>&1"
    local cron_marker="# bifrost: dest rotation"

    # Remove any existing cron entry for this script
    crontab -l 2>/dev/null | grep -v "${ROTATE_CRON_SCRIPT}" | grep -v "${cron_marker}" | crontab - 2>/dev/null || true

    # Add the new entry
    (crontab -l 2>/dev/null; echo "${cron_marker}"; echo "${cron_line}") | crontab -

    # Verify installation
    if crontab -l 2>/dev/null | grep -q "${ROTATE_CRON_SCRIPT}"; then
        log_success "Cron job installed: ${cron_schedule} (weekly Sunday 03:17 UTC)"
        log_info "Rotation script: ${ROTATE_CRON_SCRIPT}"
        log_info "Rotation log: ${ROTATE_LOG_FILE}"
    else
        log_error "Failed to install cron job."
        return 1
    fi

    # ---- Create log rotation for the rotation log ----
    cat > /etc/logrotate.d/ai-gateway-dest-rotate <<LOGROTATE_EOF
${ROTATE_LOG_FILE} {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 640 root root
}
LOGROTATE_EOF

    _save_anti_dpi_state "CRON_SCHEDULE" "${cron_schedule}"
    _save_anti_dpi_state "CRON_INSTALLED" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    log_success "Dest rotation cron job and log rotation configured."
}

# ------------------------------------------------------------------------------
# _generate_rotate_script: Generate the standalone rotation script for cron
# This is a fallback if the bundled script is not available.
# Arguments: $1 - output path
# ------------------------------------------------------------------------------
_generate_rotate_script() {
    local output="$1"
    cat > "${output}" <<'SCRIPT_EOF'
#!/usr/bin/env bash
# Auto-generated by Bifrost anti-dpi module
# Standalone dest rotation script for cron execution
set -euo pipefail

DEST_POOL_FILE="/opt/bifrost/dest-pool.txt"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
LOG_PREFIX="[dest-rotate]"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} $*"; }

if [[ ! -f "${DEST_POOL_FILE}" ]]; then
    log "ERROR: Dest pool not found: ${DEST_POOL_FILE}"
    exit 1
fi

if [[ ! -f "${XRAY_CONFIG}" ]]; then
    log "ERROR: Xray config not found: ${XRAY_CONFIG}"
    exit 1
fi

if ! command -v jq &>/dev/null; then
    log "ERROR: jq not installed"
    exit 1
fi

mapfile -t POOL < <(grep -vE '^\s*#|^\s*$' "${DEST_POOL_FILE}" | awk '{print $1}')

if [[ ${#POOL[@]} -eq 0 ]]; then
    log "ERROR: Dest pool is empty"
    exit 1
fi

CURRENT=$(jq -r '.inbounds[] | select(.streamSettings.security == "reality") | .streamSettings.realitySettings.dest' "${XRAY_CONFIG}" 2>/dev/null | head -1)
log "Current dest: ${CURRENT:-<not set>}"

IDX=$((RANDOM % ${#POOL[@]}))
NEW_DEST="${POOL[${IDX}]}"
ATTEMPTS=0
while [[ "${NEW_DEST}" == "${CURRENT}" ]] && [[ ${#POOL[@]} -gt 1 ]] && [[ ${ATTEMPTS} -lt 20 ]]; do
    IDX=$((RANDOM % ${#POOL[@]}))
    NEW_DEST="${POOL[${IDX}]}"
    ATTEMPTS=$((ATTEMPTS + 1))
done

NEW_HOST=$(echo "${NEW_DEST}" | cut -d':' -f1)
log "New dest: ${NEW_DEST} (SNI: ${NEW_HOST})"

cp -a "${XRAY_CONFIG}" "${XRAY_CONFIG}.pre-rotate.bak"

jq --arg d "${NEW_DEST}" --arg s "${NEW_HOST}" '
    (.inbounds[] | select(.streamSettings.security == "reality") | .streamSettings.realitySettings) |=
    (.dest = $d | .serverNames = [$s])
' "${XRAY_CONFIG}" > "${XRAY_CONFIG}.tmp"

if ! jq empty "${XRAY_CONFIG}.tmp" 2>/dev/null; then
    log "ERROR: jq produced invalid JSON"
    rm -f "${XRAY_CONFIG}.tmp"
    exit 1
fi

XRAY_BIN=$(command -v xray 2>/dev/null || echo "/usr/local/bin/xray")
if ! "${XRAY_BIN}" run -test -config "${XRAY_CONFIG}.tmp" &>/dev/null; then
    log "ERROR: New config failed validation. Aborting."
    rm -f "${XRAY_CONFIG}.tmp"
    exit 1
fi

mv -f "${XRAY_CONFIG}.tmp" "${XRAY_CONFIG}"
chmod 600 "${XRAY_CONFIG}"

systemctl restart xray.service
sleep 3

if systemctl is-active --quiet xray.service; then
    log "SUCCESS: Rotated to ${NEW_DEST}"
    rm -f "${XRAY_CONFIG}.pre-rotate.bak"
else
    log "ERROR: Xray failed after rotation. Rolling back..."
    cp -a "${XRAY_CONFIG}.pre-rotate.bak" "${XRAY_CONFIG}"
    systemctl restart xray.service
    sleep 3
    if systemctl is-active --quiet xray.service; then
        log "WARN: Rollback successful."
    else
        log "CRITICAL: Rollback also failed. Manual intervention needed."
    fi
    exit 1
fi
SCRIPT_EOF
}

# ==============================================================================
# 7. deploy_anti_dpi() - Main Orchestrator
# ==============================================================================
# Full anti-DPI deployment orchestrating all defense layers:
#   1. Dest pool setup + validation
#   2. Dest rotation (initial)
#   3. uTLS fingerprint configuration
#   4. Mux + padding
#   5. Active probe defense (server-side)
#   6. Cron-based rotation
# ==============================================================================
deploy_anti_dpi() {
    print_banner "Anti-DPI Defense Deployment"

    log_info "This module will deploy multiple layers of DPI anti-detection:"
    echo "  1. Reality destination pool (TLS 1.3 + H2 validated)"
    echo "  2. Dest rotation (randomized selection)"
    echo "  3. uTLS fingerprint configuration"
    echo "  4. Mux + padding (traffic analysis resistance)"
    echo "  5. Active probe defense (fallback chain)"
    echo "  6. Automated weekly dest rotation (cron)"
    echo ""

    require_root

    # Verify prerequisites
    _require_jq
    local xray_bin
    xray_bin="$(_require_xray)"
    log_info "Xray binary: ${xray_bin} ($(${xray_bin} version 2>/dev/null | head -1 | awk '{print $2}'))"

    if [[ ! -f "${XRAY_CONFIG_FILE}" ]]; then
        die "Xray config not found at ${XRAY_CONFIG_FILE}. Deploy Xray server first."
    fi

    # ---- Step 1: Dest pool ----
    print_section "Step 1/6: Reality Destination Pool"
    setup_reality_dest_pool

    # ---- Step 2: Initial rotation ----
    print_section "Step 2/6: Initial Dest Rotation"
    rotate_dest

    # ---- Step 3: uTLS fingerprint ----
    print_section "Step 3/6: uTLS Fingerprint"

    # Interactive selection of fingerprint
    local fp_options=(
        "chrome (recommended - most common, best camouflage)"
        "firefox"
        "edge"
        "safari"
        "randomized (random per-connection)"
    )
    show_menu "Select uTLS fingerprint" fp_options

    local selected_fp
    case "${MENU_RESULT}" in
        1) selected_fp="chrome" ;;
        2) selected_fp="firefox" ;;
        3) selected_fp="edge" ;;
        4) selected_fp="safari" ;;
        5) selected_fp="randomized" ;;
        *) selected_fp="chrome" ;;
    esac

    setup_utls_fingerprint "${selected_fp}"

    # ---- Step 4: Mux + padding ----
    print_section "Step 4/6: Mux + Padding"
    configure_mux_padding

    # ---- Step 5: Active probe defense ----
    print_section "Step 5/6: Active Probe Defense"
    setup_active_probe_defense

    # ---- Step 6: Cron rotation ----
    print_section "Step 6/6: Automated Dest Rotation"
    setup_dest_rotation_cron

    # ---- Summary ----
    echo ""
    print_section "Anti-DPI Deployment Summary"
    print_kv "Dest Pool" "${DEST_POOL_FILE} ($(_load_anti_dpi_state 'DEST_POOL_SIZE') entries)"
    print_kv "Current Dest" "$(_load_anti_dpi_state 'LAST_DEST')"
    print_kv "Fingerprint" "${selected_fp}"
    print_kv "Mux+Padding" "$(_load_anti_dpi_state 'MUX_PADDING' || _load_anti_dpi_state 'MUX_SERVER_SNIFFING' || echo 'configured')"
    print_kv "Probe Defense" "$(_load_anti_dpi_state 'ACTIVE_PROBE_DEFENSE')"
    print_kv "Cron Schedule" "$(_load_anti_dpi_state 'CRON_SCHEDULE') (weekly)"
    print_kv "Rotation Log" "${ROTATE_LOG_FILE}"
    echo ""

    log_success "Anti-DPI defense deployment complete."
    log_info "All defense layers are active. The system will automatically rotate"
    log_info "destinations weekly. Manual rotation: bash ${ROTATE_CRON_SCRIPT}"
}

# ==============================================================================
# End of anti-dpi.sh
# ==============================================================================
log_info "anti-dpi.sh loaded successfully."
