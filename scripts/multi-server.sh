#!/usr/bin/env bash
###############################################################################
# Bifrost - Multi-Server Management Module
#
# Manages multiple overseas Server B instances for load balancing and failover.
# Server information is stored in Mihomo (Clash.Meta) proxy group config and
# a local registry file.
#
# Functions:
#   add_server_b()       - Collect Server B info and add to Mihomo proxy group
#   remove_server_b()    - Remove a Server B from the pool
#   list_servers()       - List all registered servers with status/latency
#   test_all_servers()   - Test connectivity and latency to all servers
#
# Usage:
#   bash scripts/multi-server.sh                # Interactive menu
#   bash scripts/multi-server.sh list            # List servers
#   bash scripts/multi-server.sh add             # Add a server
#   bash scripts/multi-server.sh remove <name>   # Remove a server
#   bash scripts/multi-server.sh test            # Test all servers
#
# Dependencies: scripts/common.sh, jq (optional), curl
###############################################################################

set -euo pipefail

# Guard against double-sourcing (readonly variables would conflict)
if [[ -n "${_MULTI_SERVER_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
readonly _MULTI_SERVER_SH_LOADED=1

# Resolve the directory this script resides in
_MS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MS_PROJECT_DIR="$(cd "${_MS_SCRIPT_DIR}/.." && pwd)"

# Source common utilities
if [[ -f "${_MS_SCRIPT_DIR}/common.sh" ]]; then
    # shellcheck source=scripts/common.sh
    source "${_MS_SCRIPT_DIR}/common.sh"
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
    log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
    log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
    log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
    log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
    die() { log_error "$@"; exit 1; }
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

# Color fallbacks
: "${BLUE:=\033[0;34m}"
: "${RED:=\033[0;31m}"
: "${GREEN:=\033[0;32m}"
: "${YELLOW:=\033[1;33m}"
: "${CYAN:=${COLOR_CYAN:-\033[0;36m}}"
: "${NC:=${COLOR_RESET:-\033[0m}}"
: "${BOLD:=${COLOR_BOLD:-\033[1m}}"

# =============================================================================
# Constants
# =============================================================================
# Guarded — may already be defined by server-a.sh or mihomo.sh
[[ -v SERVER_REGISTRY_DIR ]]       || readonly SERVER_REGISTRY_DIR="/etc/bifrost"
[[ -v SERVER_REGISTRY_FILE ]]      || readonly SERVER_REGISTRY_FILE="${SERVER_REGISTRY_DIR}/servers.conf"
[[ -v MIHOMO_CONFIG ]]             || readonly MIHOMO_CONFIG="/etc/mihomo/config.yaml"
[[ -v MIHOMO_FALLBACK_CONFIG ]]    || readonly MIHOMO_FALLBACK_CONFIG="/etc/clash/config.yaml"
[[ -v XRAY_CLIENT_CONFIG ]]        || readonly XRAY_CLIENT_CONFIG="/usr/local/etc/xray/config.json"

# =============================================================================
# Internal helpers
# =============================================================================

###############################################################################
# _ensure_registry()
#
# Ensure the server registry directory and file exist.
# The registry is a simple line-based format:
#   NAME|IP|PORT|UUID|PUBKEY|SNI|SHORTID|PROTOCOL|ADDED_DATE
###############################################################################
_ensure_registry() {
    if [[ ! -d "${SERVER_REGISTRY_DIR}" ]]; then
        mkdir -p "${SERVER_REGISTRY_DIR}"
        chmod 700 "${SERVER_REGISTRY_DIR}"
    fi
    if [[ ! -f "${SERVER_REGISTRY_FILE}" ]]; then
        {
            echo "# Bifrost - Server Registry"
            echo "# Format: NAME|IP|PORT|UUID|PUBKEY|SNI|SHORTID|PROTOCOL|ADDED_DATE"
            echo "#"
        } > "${SERVER_REGISTRY_FILE}"
        chmod 600 "${SERVER_REGISTRY_FILE}"
    fi
}

###############################################################################
# _get_server_count()
#
# Returns the number of registered servers (excluding comment lines).
###############################################################################
_get_server_count() {
    _ensure_registry
    grep -v '^\s*#' "${SERVER_REGISTRY_FILE}" | grep -v '^\s*$' | wc -l
}

###############################################################################
# _server_name_exists()
#
# Check if a server name already exists in the registry.
# Arguments: $1 - server name
# Returns: 0 if exists, 1 if not.
###############################################################################
_server_name_exists() {
    local name="${1:?}"
    _ensure_registry
    grep -v '^\s*#' "${SERVER_REGISTRY_FILE}" | grep -v '^\s*$' | cut -d'|' -f1 | grep -qFx "${name}"
}

###############################################################################
# _get_server_line()
#
# Retrieve the full registry line for a server by name.
# Arguments: $1 - server name
# Returns: the registry line via stdout, or empty.
###############################################################################
_get_server_line() {
    local name="${1:?}"
    _ensure_registry
    grep -v '^\s*#' "${SERVER_REGISTRY_FILE}" | grep -v '^\s*$' | grep "^${name}|" | head -1
}

###############################################################################
# _parse_server_field()
#
# Parse a specific field from a registry line.
# Arguments:
#   $1 - registry line
#   $2 - field index (1=NAME, 2=IP, 3=PORT, 4=UUID, 5=PUBKEY, 6=SNI, 7=SHORTID, 8=PROTOCOL, 9=DATE)
###############################################################################
_parse_server_field() {
    local line="${1:?}"
    local idx="${2:?}"
    echo "${line}" | cut -d'|' -f"${idx}"
}

###############################################################################
# _rewrite_registry_without_name()
#
# Rewrite the registry file without the specified server name.
###############################################################################
_rewrite_registry_without_name() {
    local server_name="${1:?}"
    local tmp_file
    tmp_file="$(mktemp)"
    grep -v "^${server_name}|" "${SERVER_REGISTRY_FILE}" > "${tmp_file}"
    mv "${tmp_file}" "${SERVER_REGISTRY_FILE}"
    chmod 600 "${SERVER_REGISTRY_FILE}"
}

###############################################################################
# _strip_mihomo_managed_section()
#
# Remove the managed Mihomo proxy section from the config file.
###############################################################################
_strip_mihomo_managed_section() {
    local config_file="${1:?}"
    local marker_start="# >>> AI-GATEWAY-BRIDGE MANAGED PROXIES - DO NOT EDIT >>>"
    local marker_end="# <<< AI-GATEWAY-BRIDGE MANAGED PROXIES <<<"

    if ! grep -qF "${marker_start}" "${config_file}" 2>/dev/null; then
        return 0
    fi

    local tmp_config
    tmp_config="$(mktemp)"
    local in_managed=false

    while IFS= read -r line; do
        if [[ "${line}" == *"${marker_start}"* ]]; then
            in_managed=true
            continue
        fi
        if [[ "${line}" == *"${marker_end}"* ]]; then
            in_managed=false
            continue
        fi
        if [[ "${in_managed}" == "false" ]]; then
            echo "${line}" >> "${tmp_config}"
        fi
    done < "${config_file}"

    mv "${tmp_config}" "${config_file}"
}

###############################################################################
# _reload_mihomo_runtime()
#
# Reload Mihomo/Clash if the service is running.
###############################################################################
_reload_mihomo_runtime() {
    if command_exists systemctl && systemctl is-active --quiet mihomo 2>/dev/null; then
        log_info "Restarting Mihomo..."
        if ! systemctl restart mihomo 2>/dev/null; then
            log_error "Failed to restart Mihomo after config update."
            return 1
        fi
        sleep 2
        if systemctl is-active --quiet mihomo 2>/dev/null; then
            log_success "Mihomo restarted with updated proxy pool."
            return 0
        fi
        log_error "Mihomo failed to start. Check: journalctl -u mihomo --no-pager -n 20"
        return 1
    fi

    if command_exists systemctl && systemctl is-active --quiet clash 2>/dev/null; then
        if ! systemctl restart clash 2>/dev/null; then
            log_error "Failed to restart Clash after config update."
            return 1
        fi
    fi

    return 0
}

###############################################################################
# _validate_ip()
#
# Basic IPv4 address validation.
###############################################################################
_validate_ip() {
    local ip="${1:-}"
    [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

###############################################################################
# _validate_port()
#
# Validate port number (1-65535).
###############################################################################
_validate_port() {
    local port="${1:-}"
    [[ "${port}" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

###############################################################################
# _validate_uuid()
#
# Basic UUID format validation.
###############################################################################
_validate_uuid() {
    local uuid="${1:-}"
    [[ "${uuid}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

###############################################################################
# _test_server_connectivity()
#
# Test connectivity to a specific server by attempting a TCP connection.
#
# Arguments:
#   $1 - IP address
#   $2 - Port
# Returns: latency in ms via stdout, "timeout" if unreachable.
###############################################################################
_test_server_connectivity() {
    local ip="${1:?}"
    local port="${2:?}"

    local start_ns end_ns

    # Method 1: Use curl timing
    if command_exists curl; then
        local result
        result="$(curl -o /dev/null -s -w '%{time_connect}' \
            --connect-timeout 10 --max-time 15 \
            "https://${ip}:${port}" 2>/dev/null)" || result=""

        if [[ -n "${result}" && "${result}" != "0.000000" ]]; then
            # Convert seconds to milliseconds
            local ms
            ms="$(awk "BEGIN {printf \"%.0f\", ${result} * 1000}" 2>/dev/null)" || ms=""
            if [[ -n "${ms}" && "${ms}" != "0" ]]; then
                echo "${ms}"
                return 0
            fi
        fi
    fi

    # Method 2: Use /dev/tcp with timing
    start_ns="$(date +%s%N 2>/dev/null)" || start_ns="$(date +%s)000000000"
    if (echo >/dev/tcp/"${ip}"/"${port}") &>/dev/null; then
        end_ns="$(date +%s%N 2>/dev/null)" || end_ns="$(date +%s)000000000"
        local diff_ms=$(( (end_ns - start_ns) / 1000000 ))
        echo "${diff_ms}"
        return 0
    fi

    # Method 3: Use nc (netcat)
    if command_exists nc; then
        start_ns="$(date +%s%N 2>/dev/null)" || start_ns="$(date +%s)000000000"
        if nc -z -w 10 "${ip}" "${port}" &>/dev/null; then
            end_ns="$(date +%s%N 2>/dev/null)" || end_ns="$(date +%s)000000000"
            local diff_ms=$(( (end_ns - start_ns) / 1000000 ))
            echo "${diff_ms}"
            return 0
        fi
    fi

    echo "timeout"
    return 1
}

###############################################################################
# _update_mihomo_config()
#
# Regenerate the Mihomo proxy group configuration to include all registered
# servers. Creates a VLESS proxy entry for each server and adds them to
# a "ServerB-Pool" proxy group with url-test strategy.
#
# Arguments:
#   $1 - action: "add" or "remove"
#   $2 - server name
###############################################################################
_update_mihomo_config() {
    local action="${1:?}"
    local server_name="${2:?}"
    local marker_start="# >>> AI-GATEWAY-BRIDGE MANAGED PROXIES - DO NOT EDIT >>>"
    local marker_end="# <<< AI-GATEWAY-BRIDGE MANAGED PROXIES <<<"

    local config_file="${MIHOMO_CONFIG}"
    if [[ ! -f "${config_file}" ]]; then
        config_file="${MIHOMO_FALLBACK_CONFIG}"
    fi

    if [[ ! -f "${config_file}" ]]; then
        log_error "Mihomo config not found at ${MIHOMO_CONFIG} or ${MIHOMO_FALLBACK_CONFIG}. Refusing to report proxy-pool success without a live route engine."
        return 1
    fi

    # Backup current config
    local backup
    backup="${config_file}.bak.$(date +%Y%m%d%H%M%S)"
    cp "${config_file}" "${backup}"

    # Read all active servers from registry
    local -a server_lines=()
    while IFS= read -r line; do
        [[ -z "${line}" || "${line}" =~ ^# ]] && continue
        server_lines+=("${line}")
    done < "${SERVER_REGISTRY_FILE}"

    if [[ ${#server_lines[@]} -eq 0 ]]; then
        if ! _strip_mihomo_managed_section "${config_file}"; then
            log_error "Failed to remove managed Mihomo proxy section. Restoring previous config."
            cp "${backup}" "${config_file}"
            return 1
        fi
        chmod 600 "${config_file}"
        if ! _reload_mihomo_runtime; then
            log_error "Mihomo reload failed after removing the managed proxy pool. Restoring previous config."
            cp "${backup}" "${config_file}"
            chmod 600 "${config_file}"
            _reload_mihomo_runtime || true
            return 1
        fi
        log_info "No servers in registry. Removed managed Mihomo proxy pool section."
        return 0
    fi

    # Generate YAML proxy entries
    local proxies_yaml=""
    local proxy_names=""
    for sline in ${server_lines[@]+"${server_lines[@]}"}; do
        local s_name s_ip s_port s_uuid s_pubkey s_sni s_shortid s_proto
        s_name="$(_parse_server_field "${sline}" 1)"
        s_ip="$(_parse_server_field "${sline}" 2)"
        s_port="$(_parse_server_field "${sline}" 3)"
        s_uuid="$(_parse_server_field "${sline}" 4)"
        s_pubkey="$(_parse_server_field "${sline}" 5)"
        s_sni="$(_parse_server_field "${sline}" 6)"
        s_shortid="$(_parse_server_field "${sline}" 7)"
        s_proto="$(_parse_server_field "${sline}" 8)"

        proxies_yaml+="  - name: \"${s_name}\"
    type: vless
    server: ${s_ip}
    port: ${s_port}
    uuid: ${s_uuid}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: ${s_sni}
    reality-opts:
      public-key: ${s_pubkey}
      short-id: ${s_shortid}
    client-fingerprint: chrome
"
        if [[ -n "${proxy_names}" ]]; then
            proxy_names+=", "
        fi
        proxy_names+="\"${s_name}\""
    done

    if grep -qF "${marker_start}" "${config_file}" 2>/dev/null; then
        # Replace the existing managed section
        local tmp_config
        tmp_config="$(mktemp)"

        local in_managed=false
        while IFS= read -r line; do
            if [[ "${line}" == *"${marker_start}"* ]]; then
                in_managed=true
                echo "${marker_start}" >> "${tmp_config}"
                # Write the new proxy entries
                echo "proxies:" >> "${tmp_config}"
                echo "${proxies_yaml}" >> "${tmp_config}"
                echo "" >> "${tmp_config}"
                echo "proxy-groups:" >> "${tmp_config}"
                echo "  - name: \"ServerB-Pool\"" >> "${tmp_config}"
                echo "    type: url-test" >> "${tmp_config}"
                echo "    proxies: [${proxy_names}]" >> "${tmp_config}"
                echo "    url: https://api.anthropic.com" >> "${tmp_config}"
                echo "    interval: 300" >> "${tmp_config}"
                echo "    tolerance: 100" >> "${tmp_config}"
                continue
            fi
            if [[ "${line}" == *"${marker_end}"* ]]; then
                in_managed=false
                echo "${marker_end}" >> "${tmp_config}"
                continue
            fi
            if [[ "${in_managed}" == "false" ]]; then
                echo "${line}" >> "${tmp_config}"
            fi
        done < "${config_file}"

        mv "${tmp_config}" "${config_file}"
    else
        # Append the managed section to the end of the file
        {
            echo ""
            echo "${marker_start}"
            echo "proxies:"
            echo "${proxies_yaml}"
            echo ""
            echo "proxy-groups:"
            echo "  - name: \"ServerB-Pool\""
            echo "    type: url-test"
            echo "    proxies: [${proxy_names}]"
            echo "    url: https://api.anthropic.com"
            echo "    interval: 300"
            echo "    tolerance: 100"
            echo "${marker_end}"
        } >> "${config_file}"
    fi

    chmod 600 "${config_file}"
    log_info "Mihomo config updated with ${#server_lines[@]} server(s)."

    if ! _reload_mihomo_runtime; then
        log_error "Mihomo reload failed after updating the proxy pool. Restoring previous config."
        cp "${backup}" "${config_file}"
        chmod 600 "${config_file}"
        _reload_mihomo_runtime || true
        return 1
    fi

    return 0
}

###############################################################################
# add_server_b()
#
# Interactively collect Server B connection details:
#   - Friendly name
#   - IP address
#   - Port
#   - UUID
#   - Reality public key
#   - SNI (Server Name Indication)
#   - Short ID
#   - Protocol (VLESS by default)
#
# Then register in the local server registry and update Mihomo config.
###############################################################################
add_server_b() {
    log_step "Add New Server B"
    echo ""

    _ensure_registry

    # --- Server Name ---
    local server_name=""
    while true; do
        read -r -p "$(echo -e "${CYAN}Enter a friendly name for this server (e.g., tokyo-01): ${NC}")" server_name
        if [[ -z "${server_name}" ]]; then
            log_warn "Name cannot be empty."
            continue
        fi
        # Validate: alphanumeric, hyphens, underscores only
        if ! [[ "${server_name}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            log_error "Name can only contain letters, numbers, hyphens, and underscores."
            continue
        fi
        if _server_name_exists "${server_name}"; then
            log_error "Server name '${server_name}' already exists. Choose a different name."
            continue
        fi
        break
    done

    # --- IP Address ---
    local server_ip=""
    while true; do
        read -r -p "$(echo -e "${CYAN}Enter Server B IP address: ${NC}")" server_ip
        if _validate_ip "${server_ip}"; then
            break
        fi
        log_error "Invalid IP address format. Please enter a valid IPv4 address."
    done

    # --- Port ---
    local server_port=""
    read -r -p "$(echo -e "${CYAN}Enter Server B port [443]: ${NC}")" server_port
    server_port="${server_port:-443}"
    if ! _validate_port "${server_port}"; then
        log_warn "Invalid port. Using default: 443"
        server_port="443"
    fi

    # --- UUID ---
    local server_uuid=""
    while true; do
        read -r -p "$(echo -e "${CYAN}Enter UUID (from Server B setup): ${NC}")" server_uuid
        if _validate_uuid "${server_uuid}"; then
            break
        fi
        log_error "Invalid UUID format. Expected: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    done

    # --- Public Key ---
    local server_pubkey=""
    while true; do
        read -r -p "$(echo -e "${CYAN}Enter Reality public key: ${NC}")" server_pubkey
        if [[ -n "${server_pubkey}" && ${#server_pubkey} -ge 32 ]]; then
            break
        fi
        log_error "Public key must be at least 32 characters."
    done

    # --- SNI ---
    local server_sni=""
    read -r -p "$(echo -e "${CYAN}Enter SNI domain [www.microsoft.com]: ${NC}")" server_sni
    server_sni="${server_sni:-www.microsoft.com}"

    # --- Short ID ---
    local server_shortid=""
    read -r -p "$(echo -e "${CYAN}Enter Short ID (hex string) [leave empty for auto]: ${NC}")" server_shortid
    if [[ -z "${server_shortid}" ]]; then
        server_shortid="$(openssl rand -hex 4 2>/dev/null || head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 8)"
    fi

    # --- Protocol ---
    local server_proto="vless"
    log_info "Protocol: VLESS+Reality (default)"

    # Summary
    echo ""
    echo "==========================================="
    echo -e "${BOLD}Server B Summary:${NC}"
    echo "  Name:       ${server_name}"
    echo "  IP:         ${server_ip}"
    echo "  Port:       ${server_port}"
    echo "  UUID:       ${server_uuid}"
    echo "  Public Key: ${server_pubkey}"
    echo "  SNI:        ${server_sni}"
    echo "  Short ID:   ${server_shortid}"
    echo "  Protocol:   ${server_proto}"
    echo "==========================================="
    echo ""

    if ! confirm_action "Add this server to the pool?"; then
        log_info "Server addition cancelled."
        return 0
    fi

    # Test connectivity before adding
    log_info "Testing connectivity to ${server_ip}:${server_port}..."
    local latency
    latency="$(_test_server_connectivity "${server_ip}" "${server_port}")" || latency="timeout"

    if [[ "${latency}" == "timeout" ]]; then
        log_warn "Cannot reach ${server_ip}:${server_port}. The server may be down or firewalled."
        if ! confirm_action "Add anyway (server may become available later)?"; then
            log_info "Server addition cancelled."
            return 0
        fi
    else
        log_success "Server reachable. Latency: ${latency}ms"
    fi

    # Register in the file
    local added_date
    added_date="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    echo "${server_name}|${server_ip}|${server_port}|${server_uuid}|${server_pubkey}|${server_sni}|${server_shortid}|${server_proto}|${added_date}" \
        >> "${SERVER_REGISTRY_FILE}"

    log_success "Server '${server_name}' registered in ${SERVER_REGISTRY_FILE}"

    # Update Mihomo config
    if ! _update_mihomo_config "add" "${server_name}"; then
        log_error "Failed to sync Mihomo proxy pool. Rolling back server '${server_name}' from the registry."
        _rewrite_registry_without_name "${server_name}"
        return 1
    fi

    log_success "Server '${server_name}' added to the proxy pool."
    log_info "Total servers: $(_get_server_count)"
}

###############################################################################
# remove_server_b()
#
# Remove a Server B from the pool.
# Can be called with a server name argument or interactively.
#
# Arguments:
#   $1 - (optional) server name to remove
###############################################################################
remove_server_b() {
    local target_name="${1:-}"

    _ensure_registry

    local count
    count="$(_get_server_count)"

    if (( count == 0 )); then
        log_warn "No servers registered."
        return 0
    fi

    if [[ -z "${target_name}" ]]; then
        # Interactive selection
        log_step "Remove Server B"
        echo ""
        echo -e "${BOLD}Registered servers:${NC}"

        local -a names=()
        local idx=0
        while IFS= read -r line; do
            [[ -z "${line}" || "${line}" =~ ^# ]] && continue
            idx=$(( idx + 1 ))
            local name ip port
            name="$(_parse_server_field "${line}" 1)"
            ip="$(_parse_server_field "${line}" 2)"
            port="$(_parse_server_field "${line}" 3)"
            names+=("${name}")
            printf "  %s%d)%s %s (%s:%s)\n" "${GREEN}" "${idx}" "${NC}" "${name}" "${ip}" "${port}"
        done < "${SERVER_REGISTRY_FILE}"

        echo ""
        read -r -p "Select server to remove [1-${#names[@]}] (0 to cancel): " selection

        if [[ "${selection}" == "0" || -z "${selection}" ]]; then
            log_info "Removal cancelled."
            return 0
        fi

        if ! [[ "${selection}" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#names[@]} )); then
            log_error "Invalid selection."
            return 1
        fi

        target_name="${names[$(( selection - 1 ))]}"
    fi

    if ! _server_name_exists "${target_name}"; then
        log_error "Server '${target_name}' not found in registry."
        return 1
    fi

    local server_line
    server_line="$(_get_server_line "${target_name}")"
    local s_ip s_port
    s_ip="$(_parse_server_field "${server_line}" 2)"
    s_port="$(_parse_server_field "${server_line}" 3)"

    echo ""
    log_warn "About to remove server: ${target_name} (${s_ip}:${s_port})"

    if (( count == 1 )); then
        log_warn "This is the LAST server in the pool. Removing it will leave no proxy servers."
    fi

    if ! confirm_action "Remove server '${target_name}'?"; then
        log_info "Removal cancelled."
        return 0
    fi

    # Remove from registry file
    _rewrite_registry_without_name "${target_name}"

    # Update Mihomo config
    if ! _update_mihomo_config "remove" "${target_name}"; then
        log_error "Failed to sync Mihomo proxy pool after removing '${target_name}'. Restoring registry entry."
        printf '%s\n' "${server_line}" >> "${SERVER_REGISTRY_FILE}"
        chmod 600 "${SERVER_REGISTRY_FILE}"
        return 1
    fi

    log_success "Server '${target_name}' removed from registry."

    log_info "Remaining servers: $(_get_server_count)"
}

###############################################################################
# list_servers()
#
# Display all registered Server B instances with their status and latency.
# Performs a live connectivity test for each server.
###############################################################################
list_servers() {
    log_step "Registered Server B Instances"

    _ensure_registry

    local count
    count="$(_get_server_count)"

    if (( count == 0 )); then
        log_info "No servers registered."
        log_info "Add one with: bash multi-server.sh add"
        return 0
    fi

    echo ""
    printf "  ${BOLD}%-15s %-16s %-6s %-12s %-25s %-12s${NC}\n" \
        "Name" "IP" "Port" "Protocol" "SNI" "Status"
    echo "  $(printf -- '-%.0s' {1..90})"

    while IFS= read -r line; do
        [[ -z "${line}" || "${line}" =~ ^# ]] && continue

        local name ip port uuid proto sni added_date
        name="$(_parse_server_field "${line}" 1)"
        ip="$(_parse_server_field "${line}" 2)"
        port="$(_parse_server_field "${line}" 3)"
        proto="$(_parse_server_field "${line}" 8)"
        sni="$(_parse_server_field "${line}" 6)"
        added_date="$(_parse_server_field "${line}" 9)"

        # Test connectivity
        local latency status_str
        latency="$(_test_server_connectivity "${ip}" "${port}" 2>/dev/null)" || latency="timeout"

        if [[ "${latency}" == "timeout" ]]; then
            status_str="${RED}DOWN${NC}"
        elif (( latency < 100 )); then
            status_str="${GREEN}OK ${latency}ms${NC}"
        elif (( latency < 300 )); then
            status_str="${YELLOW}SLOW ${latency}ms${NC}"
        else
            status_str="${RED}SLOW ${latency}ms${NC}"
        fi

        printf "  %-15s %-16s %-6s %-12s %-25s " \
            "${name}" "${ip}" "${port}" "${proto:-vless}" "${sni}"
        echo -e "${status_str}"
    done < "${SERVER_REGISTRY_FILE}"

    echo ""
    log_info "Total servers: ${count}"
}

###############################################################################
# test_all_servers()
#
# Comprehensive connectivity test for all registered servers.
# Tests include:
#   1. TCP port reachability + latency measurement
#   2. TLS handshake verification
#   3. Tunnel proxy test (if Xray is running)
###############################################################################
test_all_servers() {
    log_step "Testing All Server B Instances"

    _ensure_registry

    local count
    count="$(_get_server_count)"

    if (( count == 0 )); then
        log_info "No servers registered."
        return 0
    fi

    echo ""

    local total=0
    local pass=0
    local fail=0

    while IFS= read -r line; do
        [[ -z "${line}" || "${line}" =~ ^# ]] && continue

        local name ip port sni
        name="$(_parse_server_field "${line}" 1)"
        ip="$(_parse_server_field "${line}" 2)"
        port="$(_parse_server_field "${line}" 3)"
        sni="$(_parse_server_field "${line}" 6)"

        total=$(( total + 1 ))
        echo -e "${BOLD}--- ${name} (${ip}:${port}) ---${NC}"

        # Test 1: TCP connectivity
        echo -n "  TCP connect: "
        local latency
        latency="$(_test_server_connectivity "${ip}" "${port}" 2>/dev/null)" || latency="timeout"

        if [[ "${latency}" == "timeout" ]]; then
            echo -e "${RED}FAIL (timeout)${NC}"
            fail=$(( fail + 1 ))
            echo ""
            continue
        else
            echo -e "${GREEN}OK (${latency}ms)${NC}"
        fi

        # Test 2: TLS handshake
        echo -n "  TLS handshake (SNI=${sni}): "
        if command_exists openssl; then
            local tls_result
            tls_result="$(echo | openssl s_client -connect "${ip}:${port}" \
                -servername "${sni}" \
                -verify_return_error \
                2>&1 | head -20)" || tls_result=""

            if echo "${tls_result}" | grep -q "CONNECTED"; then
                local tls_ver
                tls_ver="$(echo "${tls_result}" | grep -oP 'Protocol\s*:\s*\K\S+' | head -1)" || tls_ver=""
                echo -e "${GREEN}OK${NC}${tls_ver:+ (${tls_ver})}"
            else
                echo -e "${YELLOW}WARN (may be expected with Reality)${NC}"
            fi
        else
            echo -e "${YELLOW}SKIP (openssl not available)${NC}"
        fi

        # Test 3: Proxy tunnel test (if Xray client is running locally)
        echo -n "  Proxy tunnel: "
        if command_exists systemctl && systemctl is-active --quiet xray 2>/dev/null; then
            local proxy_code
            proxy_code="$(curl -s -o /dev/null -w '%{http_code}' \
                --proxy 'socks5://127.0.0.1:10808' \
                --connect-timeout 15 --max-time 30 \
                "https://api.anthropic.com" 2>/dev/null)" || proxy_code="000"

            if [[ "${proxy_code}" != "000" ]]; then
                echo -e "${GREEN}OK (HTTP ${proxy_code})${NC}"
            else
                echo -e "${YELLOW}FAIL or not routing through this server${NC}"
            fi
        else
            echo -e "${YELLOW}SKIP (Xray client not running)${NC}"
        fi

        # Test 4: Ping/ICMP (informational only, may be blocked)
        echo -n "  ICMP ping: "
        if ping -c 1 -W 5 "${ip}" &>/dev/null; then
            local ping_ms
            ping_ms="$(ping -c 3 -W 5 "${ip}" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')" || ping_ms="?"
            echo -e "${GREEN}OK (avg ${ping_ms}ms)${NC}"
        else
            echo -e "${YELLOW}BLOCKED (normal for some servers)${NC}"
        fi

        pass=$(( pass + 1 ))
        echo ""
    done < "${SERVER_REGISTRY_FILE}"

    echo "==========================================="
    log_info "Test Summary: ${pass}/${total} servers reachable, ${fail} unreachable."

    if (( fail > 0 )); then
        log_warn "${fail} server(s) failed connectivity tests."
        log_info "Consider removing dead servers: bash multi-server.sh remove <name>"
    else
        log_success "All servers are reachable."
    fi
}

###############################################################################
# manage_servers()
#
# Interactive menu for multi-server management.
###############################################################################
manage_servers() {
    while true; do
        echo ""
        echo -e "${BLUE}============================================${NC}"
        echo -e "${BLUE}  Bifrost - Multi-Server Manager  ${NC}"
        echo -e "${BLUE}============================================${NC}"
        echo ""
        echo "  1) List all servers (with status)"
        echo "  2) Add a new Server B"
        echo "  3) Remove a Server B"
        echo "  4) Test all servers"
        echo "  0) Exit"
        echo ""
        read -r -p "Select option [0-4]: " choice

        case "${choice}" in
            1) echo ""; list_servers ;;
            2) echo ""; add_server_b ;;
            3) echo ""; remove_server_b ;;
            4) echo ""; test_all_servers ;;
            0|q|Q|exit)
                log_info "Exiting multi-server manager."
                break
                ;;
            *)
                log_warn "Invalid option: ${choice}"
                ;;
        esac
    done
}

# =============================================================================
# Main execution
# =============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        list)
            list_servers
            ;;
        add)
            add_server_b
            ;;
        remove)
            remove_server_b "${2:-}"
            ;;
        test)
            test_all_servers
            ;;
        help|--help|-h)
            echo "Bifrost - Multi-Server Manager"
            echo ""
            echo "Usage:"
            echo "  $0                   # Interactive menu"
            echo "  $0 list              # List all servers with status"
            echo "  $0 add               # Add a new Server B"
            echo "  $0 remove [name]     # Remove a Server B"
            echo "  $0 test              # Test all servers"
            echo "  $0 help              # Show this help"
            ;;
        "")
            manage_servers
            ;;
        *)
            log_error "Unknown command: $1"
            echo "Run '$0 help' for usage information."
            exit 1
            ;;
    esac
fi
