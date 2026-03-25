#!/usr/bin/env bash
###############################################################################
# AI Gateway Bridge - User Management Module
#
# Manages user access for both VPN (Xray proxy) and API gateway (New API).
# Provides user creation with credentials, access revocation, listing, and
# exportable onboarding guides.
#
# Functions:
#   create_user()        - Create VPN credentials + API token + onboarding guide
#   disable_user()       - Revoke VPN access and API token
#   list_users()         - List all users with status and quota info
#   export_user_guide()  - Generate a markdown onboarding guide for a user
#
# Usage:
#   bash scripts/user-management.sh                     # Interactive menu
#   bash scripts/user-management.sh create <username>    # Create user
#   bash scripts/user-management.sh disable <username>   # Disable user
#   bash scripts/user-management.sh list                 # List users
#   bash scripts/user-management.sh guide <username>     # Export guide
#
# Dependencies: scripts/common.sh, jq, curl
###############################################################################

set -euo pipefail

# Guard against double-sourcing (readonly variables would conflict)
if [[ -n "${_USER_MANAGEMENT_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
readonly _USER_MANAGEMENT_SH_LOADED=1

# Resolve the directory this script resides in
_UM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_UM_PROJECT_DIR="$(cd "${_UM_SCRIPT_DIR}/.." && pwd)"

# Source common utilities
if [[ -f "${_UM_SCRIPT_DIR}/common.sh" ]]; then
    # shellcheck source=scripts/common.sh
    source "${_UM_SCRIPT_DIR}/common.sh"
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
USER_REGISTRY_DIR="/etc/ai-gateway-bridge/users"
USER_REGISTRY_FILE="/etc/ai-gateway-bridge/users/registry.conf"
USER_GUIDES_DIR="/etc/ai-gateway-bridge/users/guides"

XRAY_CONFIG="/usr/local/etc/xray/config.json"
NEW_API_BASE_URL="http://127.0.0.1:3000"
NEW_API_ADMIN_TOKEN_FILE="/etc/ai-gateway-bridge/.new-api-admin-token"

# Default quota (in USD) for new users -- maps to New API quota system
DEFAULT_QUOTA=100

# =============================================================================
# Internal helpers
# =============================================================================

###############################################################################
# _ensure_user_dirs()
#
# Create user management directories.
###############################################################################
_ensure_user_dirs() {
    mkdir -p "${USER_REGISTRY_DIR}" "${USER_GUIDES_DIR}"
    chmod 700 "${USER_REGISTRY_DIR}" "${USER_GUIDES_DIR}"

    if [[ ! -f "${USER_REGISTRY_FILE}" ]]; then
        {
            echo "# AI Gateway Bridge - User Registry"
            echo "# Format: USERNAME|UUID|EMAIL|STATUS|API_TOKEN_ID|CREATED|DISABLED"
            echo "#"
        } > "${USER_REGISTRY_FILE}"
        chmod 600 "${USER_REGISTRY_FILE}"
    fi
}

###############################################################################
# _user_exists()
#
# Check if a username exists in the registry.
###############################################################################
_user_exists() {
    local username="${1:?}"
    grep -v '^\s*#' "${USER_REGISTRY_FILE}" 2>/dev/null | grep -v '^\s*$' | cut -d'|' -f1 | grep -qFx "${username}"
}

###############################################################################
# _get_user_line()
#
# Retrieve the full registry line for a user.
###############################################################################
_get_user_line() {
    local username="${1:?}"
    grep -v '^\s*#' "${USER_REGISTRY_FILE}" 2>/dev/null | grep -v '^\s*$' | grep "^${username}|" | head -1
}

###############################################################################
# _parse_user_field()
#
# Parse a specific field from a user registry line.
# Fields: 1=USERNAME, 2=UUID, 3=EMAIL, 4=STATUS, 5=API_TOKEN_ID, 6=CREATED, 7=DISABLED
###############################################################################
_parse_user_field() {
    local line="${1:?}"
    local idx="${2:?}"
    echo "${line}" | cut -d'|' -f"${idx}"
}

###############################################################################
# _generate_uuid()
#
# Generate a UUID v4 for VPN credentials.
###############################################################################
_generate_uuid() {
    if command_exists uuidgen; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    elif command_exists openssl; then
        local hex
        hex="$(openssl rand -hex 16)"
        printf '%s-%s-4%s-%s-%s\n' \
            "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" "${hex:16:4}" "${hex:20:12}"
    else
        die "No UUID generator available."
    fi
}

###############################################################################
# _get_admin_token()
#
# Retrieve the New API admin token from the stored file or environment.
###############################################################################
_get_admin_token() {
    if [[ -f "${NEW_API_ADMIN_TOKEN_FILE}" ]]; then
        cat "${NEW_API_ADMIN_TOKEN_FILE}"
        return 0
    fi

    if [[ -n "${NEW_API_ADMIN_TOKEN:-}" ]]; then
        echo "${NEW_API_ADMIN_TOKEN}"
        return 0
    fi

    # Try to find it from environment or Docker
    if command_exists docker && docker info &>/dev/null; then
        for name in "new-api" "newapi" "one-api" "oneapi"; do
            local token
            token="$(docker exec "${name}" printenv ADMIN_TOKEN 2>/dev/null)" || token=""
            if [[ -n "${token}" ]]; then
                echo "${token}" > "${NEW_API_ADMIN_TOKEN_FILE}"
                chmod 600 "${NEW_API_ADMIN_TOKEN_FILE}"
                echo "${token}"
                return 0
            fi
        done
    fi

    echo ""
}

###############################################################################
# _add_xray_user()
#
# Add a VLESS user (client) to the Xray server config.
#
# Arguments:
#   $1 - UUID for the new user
#   $2 - Email identifier (e.g., user@bridge.local)
###############################################################################
_add_xray_user() {
    local uuid="${1:?}"
    local email="${2:?}"

    if [[ ! -f "${XRAY_CONFIG}" ]]; then
        log_warn "Xray config not found at ${XRAY_CONFIG}. Skipping VPN user creation."
        return 1
    fi

    if ! command_exists jq; then
        # Best-effort install
        if declare -f install_if_missing &>/dev/null; then
            install_if_missing jq jq 2>/dev/null || true
        fi
    fi
    if ! command_exists jq; then
        log_warn "jq not installed. Cannot modify Xray config. Add user manually."
        # Print UUID to stdout only, not to log file (credential)
        echo "UUID: ${uuid}"
        echo "Email: ${email}"
        return 1
    fi

    # Backup
    cp "${XRAY_CONFIG}" "${XRAY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

    # Check if user already exists
    if jq -e ".inbounds[]? | select(.protocol == \"vless\") | .settings.clients[]? | select(.id == \"${uuid}\")" "${XRAY_CONFIG}" &>/dev/null; then
        log_info "UUID ${uuid:0:8}... already exists in Xray config."
        return 0
    fi

    # Add the user to the first VLESS inbound
    local tmp_config
    tmp_config="$(mktemp)"

    if jq --arg uuid "${uuid}" --arg email "${email}" \
        '(.inbounds[] | select(.protocol == "vless") | .settings.clients) += [{"id": $uuid, "flow": "xtls-rprx-vision", "level": 0, "email": $email}]' \
        "${XRAY_CONFIG}" > "${tmp_config}" 2>/dev/null && [[ -s "${tmp_config}" ]]; then
        mv "${tmp_config}" "${XRAY_CONFIG}"
        log_success "VPN user added to Xray config: ${email}"
    else
        rm -f "${tmp_config}"
        log_error "Failed to add user to Xray config."
        return 1
    fi

    # Restart Xray
    if command_exists systemctl && systemctl is-active --quiet xray 2>/dev/null; then
        systemctl restart xray
        sleep 2
        if systemctl is-active --quiet xray 2>/dev/null; then
            log_success "Xray restarted with new user."
        else
            log_error "Xray failed to restart. Restoring backup..."
            local backup
            backup="$(ls -t "${XRAY_CONFIG}".bak.* 2>/dev/null | head -1)"
            if [[ -n "${backup}" ]]; then
                cp "${backup}" "${XRAY_CONFIG}"
                systemctl restart xray 2>/dev/null || true
            fi
            return 1
        fi
    fi

    return 0
}

###############################################################################
# _remove_xray_user()
#
# Remove a VLESS user from the Xray config by UUID.
#
# Arguments:
#   $1 - UUID to remove
###############################################################################
_remove_xray_user() {
    local uuid="${1:?}"

    if [[ ! -f "${XRAY_CONFIG}" ]]; then
        return 0
    fi

    if ! command_exists jq; then
        if declare -f install_if_missing &>/dev/null; then
            install_if_missing jq jq 2>/dev/null || true
        fi
    fi
    if ! command_exists jq; then
        log_warn "jq not installed. Remove UUID ${uuid} manually from ${XRAY_CONFIG}."
        return 1
    fi

    cp "${XRAY_CONFIG}" "${XRAY_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

    local tmp_config
    tmp_config="$(mktemp)"

    if jq --arg uuid "${uuid}" \
        '(.inbounds[] | select(.protocol == "vless") | .settings.clients) |= map(select(.id != $uuid))' \
        "${XRAY_CONFIG}" > "${tmp_config}" 2>/dev/null && [[ -s "${tmp_config}" ]]; then
        mv "${tmp_config}" "${XRAY_CONFIG}"
        log_success "VPN user (UUID: ${uuid}) removed from Xray config."
    else
        rm -f "${tmp_config}"
        log_warn "Failed to remove user from Xray config."
    fi

    if command_exists systemctl && systemctl is-active --quiet xray 2>/dev/null; then
        systemctl restart xray 2>/dev/null || true
        sleep 2
    fi
}

###############################################################################
# _create_api_token()
#
# Create an API token/key in New API for the user.
# Uses the New API REST endpoint.
#
# Arguments:
#   $1 - username
# Returns: token value via stdout, or empty on failure.
###############################################################################
_create_api_token() {
    local username="${1:?}"

    local admin_token
    admin_token="$(_get_admin_token)"

    if [[ -z "${admin_token}" ]]; then
        log_warn "New API admin token not found."
        log_info "Set it with: echo 'YOUR_TOKEN' > ${NEW_API_ADMIN_TOKEN_FILE}"
        return 1
    fi

    # Check if New API is reachable
    local api_status
    api_status="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "${NEW_API_BASE_URL}/api/status" 2>/dev/null)" || api_status="000"

    if [[ "${api_status}" == "000" ]]; then
        log_warn "New API is not reachable at ${NEW_API_BASE_URL}."
        return 1
    fi

    # Create a new token via the API
    # The New API (one-api/new-api) uses /api/token endpoint
    local token_name="user-${username}-$(date +%Y%m%d)"

    local response
    response="$(curl -s --connect-timeout 10 --max-time 15 \
        -X POST "${NEW_API_BASE_URL}/api/token/" \
        -H "Authorization: Bearer ${admin_token}" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"${token_name}\",
            \"remain_quota\": ${DEFAULT_QUOTA},
            \"expired_time\": -1,
            \"unlimited_quota\": false
        }" 2>/dev/null)" || response=""

    if [[ -z "${response}" ]]; then
        log_warn "Empty response from New API. Token creation may have failed."
        return 1
    fi

    # Parse response
    local success token_key token_id
    if command_exists jq; then
        success="$(echo "${response}" | jq -r '.success // false' 2>/dev/null)" || success="false"
        if [[ "${success}" == "true" ]]; then
            token_key="$(echo "${response}" | jq -r '.data.key // empty' 2>/dev/null)" || token_key=""
            token_id="$(echo "${response}" | jq -r '.data.id // empty' 2>/dev/null)" || token_id=""
        else
            local err_msg
            err_msg="$(echo "${response}" | jq -r '.message // "unknown error"' 2>/dev/null)" || err_msg="unknown"
            log_warn "New API token creation failed: ${err_msg}"
            return 1
        fi
    else
        # Fallback: try to extract key from response
        token_key="$(echo "${response}" | grep -oP '"key"\s*:\s*"\K[^"]+' | head -1)" || token_key=""
        token_id="$(echo "${response}" | grep -oP '"id"\s*:\s*\K[0-9]+' | head -1)" || token_id=""
    fi

    if [[ -n "${token_key}" ]]; then
        echo "${token_key}|${token_id}"
        return 0
    fi

    log_warn "Could not extract API token from response."
    return 1
}

###############################################################################
# _disable_api_token()
#
# Disable/delete an API token in New API by its ID.
#
# Arguments:
#   $1 - token ID
###############################################################################
_disable_api_token() {
    local token_id="${1:?}"

    local admin_token
    admin_token="$(_get_admin_token)"

    if [[ -z "${admin_token}" ]]; then
        log_warn "No admin token available. Cannot disable API token ${token_id}."
        return 1
    fi

    # Try to disable the token via API
    local response
    response="$(curl -s --connect-timeout 10 --max-time 15 \
        -X PUT "${NEW_API_BASE_URL}/api/token/" \
        -H "Authorization: Bearer ${admin_token}" \
        -H "Content-Type: application/json" \
        -d "{\"id\": ${token_id}, \"status\": 2}" 2>/dev/null)" || response=""

    if command_exists jq; then
        local success
        success="$(echo "${response}" | jq -r '.success // false' 2>/dev/null)" || success="false"
        if [[ "${success}" == "true" ]]; then
            log_success "API token ID ${token_id} disabled."
            return 0
        fi
    fi

    # Fallback: try to delete the token
    response="$(curl -s --connect-timeout 10 --max-time 15 \
        -X DELETE "${NEW_API_BASE_URL}/api/token/${token_id}" \
        -H "Authorization: Bearer ${admin_token}" 2>/dev/null)" || response=""

    # Log only success/failure status, not the full API response (may contain tokens)
    if [[ -n "${response}" ]]; then
        log_info "API token disable/delete completed (response received)."
    else
        log_warn "API token disable/delete: no response received."
    fi
}

###############################################################################
# create_user()
#
# Create a new user with both VPN and API access:
#   1. Generate a UUID for VPN (VLESS) access
#   2. Add the UUID to Xray server config
#   3. Create an API token in New API
#   4. Register the user in the local registry
#   5. Generate a personalized onboarding guide
#
# Arguments:
#   $1 - (optional) username. If empty, prompts interactively.
###############################################################################
create_user() {
    local username="${1:-}"

    log_step "Create New User"
    echo ""

    _ensure_user_dirs

    if [[ -z "${username}" ]]; then
        read -r -p "$(echo -e "${CYAN}Enter username (alphanumeric, lowercase): ${NC}")" username
    fi

    # Validate username
    if [[ -z "${username}" ]]; then
        die "Username cannot be empty."
    fi

    username="${username,,}"  # lowercase

    if ! [[ "${username}" =~ ^[a-z][a-z0-9_-]{1,30}$ ]]; then
        die "Invalid username. Must start with a letter, contain only lowercase letters/numbers/hyphens/underscores, 2-31 chars."
    fi

    if _user_exists "${username}"; then
        die "User '${username}' already exists."
    fi

    # Email (for Xray stats identification)
    local email=""
    read -r -p "$(echo -e "${CYAN}Enter user email (for identification) [${username}@bridge.local]: ${NC}")" email
    email="${email:-${username}@bridge.local}"

    echo ""

    # --- Detect if enterprise VPN (WireGuard) is deployed ---
    local vpn_deployed=false
    local wg_config_file=""
    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null || \
       [[ -f /etc/wireguard/wg0.conf ]]; then
        vpn_deployed=true
    fi

    local total_steps=4
    if ${vpn_deployed}; then
        total_steps=5
    fi

    # --- 1. Generate VPN UUID ---
    log_info "[1/${total_steps}] Generating VPN credentials..."
    local user_uuid
    user_uuid="$(_generate_uuid)"
    log_info "UUID: ${user_uuid:0:8}...${user_uuid: -4} (truncated for security)"

    # --- 2. Add to Xray config ---
    log_info "[2/${total_steps}] Adding to Xray VPN server..."
    local xray_ok=false
    if _add_xray_user "${user_uuid}" "${email}"; then
        xray_ok=true
    else
        log_warn "Xray user addition had issues (see above). VPN access may need manual setup."
    fi

    # --- 2.5: Create WireGuard peer (if VPN deployed) ---
    if ${vpn_deployed}; then
        log_info "[3/${total_steps}] Creating WireGuard VPN peer..."
        local _vpn_script_dir
        _vpn_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [[ -f "${_vpn_script_dir}/vpn.sh" ]]; then
            # shellcheck source=scripts/vpn.sh
            source "${_vpn_script_dir}/vpn.sh" 2>/dev/null || true
            if declare -f create_vpn_user &>/dev/null; then
                create_vpn_user "${username}" || log_warn "WireGuard peer creation failed (non-fatal)."
                # Check if WireGuard config was generated
                local vpn_users_dir="/etc/ai-gateway-bridge/vpn/users"
                if [[ -f "${vpn_users_dir}/${username}/wg-${username}.conf" ]]; then
                    wg_config_file="${vpn_users_dir}/${username}/wg-${username}.conf"
                    log_success "WireGuard config: ${wg_config_file}"
                fi
            else
                log_warn "create_vpn_user function not available. WireGuard peer not created."
                log_warn "Create WireGuard peer manually: bash scripts/vpn.sh create_user ${username}"
            fi
        else
            log_warn "vpn.sh not found. WireGuard peer not created."
        fi
    fi

    # --- 3. Create API token ---
    local api_step=3
    if ${vpn_deployed}; then api_step=4; fi
    log_info "[${api_step}/${total_steps}] Creating API gateway token..."
    local api_token_key=""
    local api_token_id=""
    local api_result
    api_result="$(_create_api_token "${username}")" || api_result=""

    if [[ -n "${api_result}" ]]; then
        api_token_key="$(echo "${api_result}" | cut -d'|' -f1)"
        api_token_id="$(echo "${api_result}" | cut -d'|' -f2)"
        log_success "API token created: sk-${api_token_key:0:8}..."
    else
        log_warn "API token creation failed. User can use VPN only, or token can be created later."
    fi

    # --- 4. Register in local registry ---
    local reg_step=$((api_step + 1))
    log_info "[${reg_step}/${total_steps}] Registering user..."
    local created_date
    created_date="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    echo "${username}|${user_uuid}|${email}|active|${api_token_id:-none}|${created_date}|" \
        >> "${USER_REGISTRY_FILE}"

    # Save credentials to a secure per-user file
    local user_creds_file="${USER_REGISTRY_DIR}/${username}.credentials"
    {
        echo "# AI Gateway Bridge - User Credentials"
        echo "# User: ${username}"
        echo "# Created: ${created_date}"
        echo "#"
        echo "USERNAME=${username}"
        echo "EMAIL=${email}"
        echo "VPN_UUID=${user_uuid}"
        echo "API_TOKEN_KEY=${api_token_key:-NOT_CREATED}"
        echo "API_TOKEN_ID=${api_token_id:-none}"
        if [[ -n "${wg_config_file}" ]]; then
            echo "WG_CONFIG=${wg_config_file}"
        fi
    } > "${user_creds_file}"
    chmod 600 "${user_creds_file}"

    # Generate onboarding guide
    _generate_user_guide "${username}" "${user_uuid}" "${api_token_key}" "${email}"

    # Summary
    echo ""
    echo "==========================================="
    echo -e "${BOLD}User '${username}' Created Successfully${NC}"
    echo "==========================================="
    echo "  Username:    ${username}"
    echo "  Email:       ${email}"
    echo "  VPN UUID:    ${user_uuid}"
    echo "  VPN Status:  $(if ${xray_ok}; then echo -e "${GREEN}active${NC}"; else echo -e "${YELLOW}pending${NC}"; fi)"
    if [[ -n "${wg_config_file}" ]]; then
        echo "  WireGuard:   ${wg_config_file}"
    elif ${vpn_deployed}; then
        echo "  WireGuard:   pending (create manually via VPN menu)"
    fi
    if [[ -n "${api_token_key}" ]]; then
        echo "  API Token:   sk-${api_token_key}"
    else
        echo "  API Token:   not created (create manually in New API panel)"
    fi
    echo "  Credentials: ${user_creds_file}"
    echo "  Guide:       ${USER_GUIDES_DIR}/${username}-guide.md"
    echo "==========================================="
    echo ""
    log_warn "Share the guide file with the user. Credentials file should remain on server."
}

###############################################################################
# disable_user()
#
# Revoke both VPN and API access for a user.
#
# Arguments:
#   $1 - (optional) username to disable
###############################################################################
disable_user() {
    local username="${1:-}"

    log_step "Disable User"

    _ensure_user_dirs

    if [[ -z "${username}" ]]; then
        # Interactive: list active users and let admin pick
        local -a active_users=()
        while IFS= read -r line; do
            [[ -z "${line}" || "${line}" =~ ^# ]] && continue
            local u_name u_status
            u_name="$(echo "${line}" | cut -d'|' -f1)"
            u_status="$(echo "${line}" | cut -d'|' -f4)"
            if [[ "${u_status}" == "active" ]]; then
                active_users+=("${u_name}")
            fi
        done < "${USER_REGISTRY_FILE}"

        if [[ ${#active_users[@]} -eq 0 ]]; then
            log_info "No active users to disable."
            return 0
        fi

        echo ""
        echo -e "${BOLD}Active users:${NC}"
        local idx=0
        for u in ${active_users[@]+"${active_users[@]}"}; do
            idx=$(( idx + 1 ))
            echo "  ${idx}) ${u}"
        done

        echo ""
        read -r -p "Select user to disable [1-${#active_users[@]}] (0 to cancel): " selection

        if [[ "${selection}" == "0" || -z "${selection}" ]]; then
            log_info "Cancelled."
            return 0
        fi

        if ! [[ "${selection}" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#active_users[@]} )); then
            log_error "Invalid selection."
            return 1
        fi

        username="${active_users[$(( selection - 1 ))]}"
    fi

    if ! _user_exists "${username}"; then
        log_error "User '${username}' not found."
        return 1
    fi

    local user_line
    user_line="$(_get_user_line "${username}")"
    local user_uuid user_status api_token_id
    user_uuid="$(_parse_user_field "${user_line}" 2)"
    user_status="$(_parse_user_field "${user_line}" 4)"
    api_token_id="$(_parse_user_field "${user_line}" 5)"

    if [[ "${user_status}" == "disabled" ]]; then
        log_warn "User '${username}' is already disabled."
        return 0
    fi

    echo ""
    log_warn "This will revoke ALL access for user '${username}':"
    log_warn "  - VPN access (UUID: ${user_uuid})"
    log_warn "  - API token (ID: ${api_token_id})"

    if ! confirm_action "Disable user '${username}'?"; then
        log_info "Cancelled."
        return 0
    fi

    # --- Revoke VPN access ---
    log_info "Revoking VPN access..."
    _remove_xray_user "${user_uuid}"

    # --- Revoke API token ---
    if [[ -n "${api_token_id}" && "${api_token_id}" != "none" ]]; then
        log_info "Disabling API token (ID: ${api_token_id})..."
        _disable_api_token "${api_token_id}" || log_warn "API token disable may have failed."
    fi

    # --- Update registry ---
    local disabled_date
    disabled_date="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local tmp_reg
    tmp_reg="$(mktemp)"

    while IFS= read -r line; do
        if [[ "${line}" == "${username}|"* ]]; then
            # Replace status and add disabled date
            local parts
            IFS='|' read -ra parts <<< "${line}"
            parts[3]="disabled"
            parts[6]="${disabled_date}"
            local new_line
            new_line="$(IFS='|'; echo "${parts[*]}")"
            echo "${new_line}" >> "${tmp_reg}"
        else
            echo "${line}" >> "${tmp_reg}"
        fi
    done < "${USER_REGISTRY_FILE}"

    mv "${tmp_reg}" "${USER_REGISTRY_FILE}"
    chmod 600 "${USER_REGISTRY_FILE}"

    log_success "User '${username}' has been disabled."
    log_info "  VPN: revoked"
    log_info "  API: revoked"
    log_info "  Status: disabled (${disabled_date})"
}

###############################################################################
# list_users()
#
# Display all users with their status, creation date, and API token info.
# Checks Xray stats for usage data when available.
###############################################################################
list_users() {
    log_step "User List"

    _ensure_user_dirs

    local count=0
    echo ""
    printf "  ${BOLD}%-15s %-25s %-10s %-12s %-20s${NC}\n" \
        "Username" "Email" "Status" "API Token" "Created"
    echo "  $(printf -- '-%.0s' {1..85})"

    while IFS= read -r line; do
        [[ -z "${line}" || "${line}" =~ ^# ]] && continue

        local u_name u_uuid u_email u_status u_token_id u_created u_disabled
        u_name="$(_parse_user_field "${line}" 1)"
        u_uuid="$(_parse_user_field "${line}" 2)"
        u_email="$(_parse_user_field "${line}" 3)"
        u_status="$(_parse_user_field "${line}" 4)"
        u_token_id="$(_parse_user_field "${line}" 5)"
        u_created="$(_parse_user_field "${line}" 6)"
        u_disabled="$(_parse_user_field "${line}" 7)"

        local status_display
        if [[ "${u_status}" == "active" ]]; then
            status_display="${GREEN}active${NC}"
        elif [[ "${u_status}" == "disabled" ]]; then
            status_display="${RED}disabled${NC}"
        else
            status_display="${YELLOW}${u_status}${NC}"
        fi

        local token_display
        if [[ -n "${u_token_id}" && "${u_token_id}" != "none" ]]; then
            token_display="ID:${u_token_id}"
        else
            token_display="-"
        fi

        printf "  %-15s %-25s " "${u_name}" "${u_email}"
        echo -ne "${status_display}"
        printf "%*s %-12s %-20s\n" "$(( 10 - ${#u_status} ))" "" "${token_display}" "${u_created:0:10}"

        count=$(( count + 1 ))
    done < "${USER_REGISTRY_FILE}"

    echo ""
    log_info "Total users: ${count}"

    # Show Xray traffic stats if available
    if command_exists "${XRAY_BIN:-xray}" 2>/dev/null || [[ -x "/usr/local/bin/xray" ]]; then
        local xray_api="127.0.0.1:10085"
        if curl -s "http://${xray_api}/" &>/dev/null 2>&1; then
            echo ""
            log_info "Traffic statistics (from Xray stats API):"
            # Query Xray stats API
            local stats
            stats="$(curl -s "http://${xray_api}/stats/query" 2>/dev/null)" || stats=""
            if [[ -n "${stats}" ]] && command_exists jq; then
                echo "${stats}" | jq -r '.stat[]? | select(.name | startswith("user>>>")) | "\(.name): \(.value // 0) bytes"' 2>/dev/null | while IFS= read -r stat_line; do
                    echo "  ${stat_line}"
                done
            else
                log_info "  Stats API not available or jq not installed."
            fi
        fi
    fi
}

###############################################################################
# _generate_user_guide()
#
# Generate a markdown onboarding guide for a specific user.
#
# Arguments:
#   $1 - username
#   $2 - UUID
#   $3 - API token key (may be empty)
#   $4 - email
###############################################################################
_generate_user_guide() {
    local username="${1:?}"
    local uuid="${2:?}"
    local api_token="${3:-}"
    local email="${4:-}"

    _ensure_user_dirs

    # Gather server info
    local server_ip
    server_ip="$(curl -4 -s --connect-timeout 5 --max-time 8 'https://ifconfig.me' 2>/dev/null | tr -d '[:space:]')" || server_ip="YOUR_SERVER_IP"

    local sni="www.microsoft.com"
    local server_port="443"
    local public_key=""

    # Try to extract from Xray config
    if [[ -f "${XRAY_CONFIG}" ]] && command_exists jq; then
        local xray_sni xray_port xray_pubkey
        xray_sni="$(jq -r '.outbounds[]? | select(.tag == "proxy") | .streamSettings.realitySettings.serverName // empty' "${XRAY_CONFIG}" 2>/dev/null)" || xray_sni=""
        xray_port="$(jq -r '.outbounds[]? | select(.tag == "proxy") | .settings.vnext[0].port // empty' "${XRAY_CONFIG}" 2>/dev/null)" || xray_port=""
        xray_pubkey="$(jq -r '.outbounds[]? | select(.tag == "proxy") | .streamSettings.realitySettings.publicKey // empty' "${XRAY_CONFIG}" 2>/dev/null)" || xray_pubkey=""

        [[ -n "${xray_sni}" ]] && sni="${xray_sni}"
        [[ -n "${xray_port}" ]] && server_port="${xray_port}"
        [[ -n "${xray_pubkey}" ]] && public_key="${xray_pubkey}"
    fi

    # Check if WireGuard VPN is deployed and user has a config
    local vpn_deployed=false
    local wg_config_file=""
    local vpn_users_dir="/etc/ai-gateway-bridge/vpn/users"
    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null || \
       [[ -f /etc/wireguard/wg0.conf ]]; then
        vpn_deployed=true
        if [[ -f "${vpn_users_dir}/${username}/wg-${username}.conf" ]]; then
            wg_config_file="${vpn_users_dir}/${username}/wg-${username}.conf"
        fi
    fi

    # Get domain for API URLs
    local api_domain="${server_ip}"
    if [[ -f /root/server-a-domain.conf ]]; then
        local _domain=""
        _domain="$(grep '^DOMAIN=' /root/server-a-domain.conf 2>/dev/null | cut -d= -f2)" || true
        if [[ -n "${_domain}" ]]; then
            api_domain="${_domain}"
        fi
    fi

    local guide_file="${USER_GUIDES_DIR}/${username}-guide.md"

    cat > "${guide_file}" <<GUIDE_EOF
# AI Gateway Bridge - User Onboarding Guide

Welcome, **${username}**! This guide helps you connect to the AI Gateway Bridge.

---

## Your Credentials

| Item | Value |
|------|-------|
| Username | ${username} |
| Email | ${email} |
$(if ${vpn_deployed}; then echo "| WireGuard VPN | See Step 1 below |"; fi)
| Proxy UUID | \`${uuid}\` |
$(if [[ -n "${api_token}" ]]; then echo "| API Token | \`sk-${api_token}\` |"; else echo "| API Token | Contact your admin |"; fi)

> **Keep these credentials private.** Do not share them publicly.

---

$(if ${vpn_deployed}; then
cat <<VPN_SECTION
## Step 1: Connect to Enterprise VPN (Required First)

You **must** connect to the company VPN before accessing any AI services.
The VPN uses WireGuard protocol for fast, secure connections.

### WireGuard Setup

1. Download WireGuard client for your platform:
   - **Windows:** https://www.wireguard.com/install/
   - **macOS:** App Store -> "WireGuard"
   - **iOS:** App Store -> "WireGuard"
   - **Android:** Google Play -> "WireGuard"
   - **Linux:** \`sudo apt install wireguard\` or \`sudo dnf install wireguard-tools\`

2. Get your configuration file from your admin:
$(if [[ -n "${wg_config_file}" ]]; then
echo "   Your config file is at: \`${wg_config_file}\` (ask admin to send securely)"
else
echo "   Ask your admin for the WireGuard config file (\`wg-${username}.conf\`)"
fi)

3. Import the config into WireGuard client:
   - Windows/macOS: Click "Import tunnel(s) from file"
   - Mobile: Scan QR code (ask admin) or import file
   - Linux: \`sudo cp wg-${username}.conf /etc/wireguard/ && sudo wg-quick up wg-${username}\`

4. Activate the tunnel and verify connection.

> **Important:** All AI services are only accessible through VPN.

---

VPN_SECTION
fi)

## $(if ${vpn_deployed}; then echo "Step 2: Proxy Access (Advanced)"; else echo "VPN Setup (Proxy Access)"; fi)

The proxy tunnel uses VLESS + Reality protocol. $(if ${vpn_deployed}; then echo "This is **optional** if you are connected via WireGuard VPN."; fi)

### Connection Details

- **Protocol:** VLESS
- **Server:** ${server_ip}
- **Port:** ${server_port}
- **UUID:** \`${uuid}\`
- **Encryption:** none
- **Flow:** xtls-rprx-vision
- **Network:** tcp
- **Security:** reality
- **SNI:** ${sni}
$(if [[ -n "${public_key}" ]]; then echo "- **Public Key:** \`${public_key}\`"; fi)
- **Fingerprint:** chrome

### Recommended Clients

| Platform | Client | Download |
|----------|--------|----------|
| Windows  | v2rayN | https://github.com/2dust/v2rayN/releases |
| macOS    | V2RayXS | https://github.com/tzmax/V2RayXS/releases |
| iOS      | Shadowrocket | App Store (\$2.99) |
| Android  | v2rayNG | https://github.com/2dust/v2rayNG/releases |
| Linux    | v2rayA | https://github.com/v2rayA/v2rayA/releases |

### v2rayN (Windows) Setup

1. Open v2rayN
2. Click **Servers** -> **Add VLESS server**
3. Fill in the details above
4. Enable the server and set system proxy

---

## API Usage

$(if [[ -n "${api_token}" ]]; then
cat <<API_SECTION
Use the API token to access AI services through the gateway.

### Base URL

\`\`\`
https://${api_domain}
\`\`\`

### Example: Chat Completion (OpenAI-compatible)

\`\`\`bash
curl https://${api_domain}/v1/chat/completions \\
  -H "Authorization: Bearer sk-${api_token}" \\
  -H "Content-Type: application/json" \\
  -d '{
    "model": "claude-3-5-sonnet-20241022",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
\`\`\`

### Client Configuration

#### Claude Code (Anthropic)

\`\`\`bash
export ANTHROPIC_BASE_URL=https://${api_domain}
export ANTHROPIC_API_KEY=sk-${api_token}
\`\`\`

Or add to \`~/.claude/settings.json\`:

\`\`\`json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://${api_domain}",
    "ANTHROPIC_API_KEY": "sk-${api_token}"
  }
}
\`\`\`

#### Codex CLI (OpenAI)

\`\`\`bash
export OPENAI_BASE_URL=https://${api_domain}/v1
export OPENAI_API_KEY=sk-${api_token}
\`\`\`

#### OpenCode / Other OpenAI-Compatible Tools

\`\`\`bash
export OPENAI_BASE_URL=https://${api_domain}/v1
export OPENAI_API_KEY=sk-${api_token}
\`\`\`

### Supported AI Services

- Anthropic Claude (claude-3-5-sonnet, claude-3-opus, etc.)
- OpenAI GPT (gpt-4o, gpt-4-turbo, etc.)
- Google Gemini (gemini-1.5-pro, gemini-1.5-flash)
- DeepSeek (deepseek-chat, deepseek-coder)
- And more...
API_SECTION
else
echo "Contact your administrator for API access credentials."
fi)

---

## Troubleshooting

1. **Cannot connect to VPN**
   - Check that the server IP and port are correct
   - Try a different client application
   - Contact your admin if the issue persists

2. **API requests fail**
   - Verify your API token is correct
   - Ensure the VPN is connected (if required)
   - Check the base URL

3. **Slow connection**
   - Try different VLESS client settings
   - Check your local internet connection
   - Contact admin to check server health

---

## Support

Contact your system administrator for:
- Password/credential reset
- Quota increase
- Technical support

---

*Generated on $(date '+%Y-%m-%d %H:%M:%S') by AI Gateway Bridge*
GUIDE_EOF

    chmod 640 "${guide_file}"
    log_success "User guide generated: ${guide_file}"
}

###############################################################################
# export_user_guide()
#
# Regenerate or display the onboarding guide for an existing user.
#
# Arguments:
#   $1 - username
###############################################################################
export_user_guide() {
    local username="${1:-}"

    _ensure_user_dirs

    if [[ -z "${username}" ]]; then
        read -r -p "$(echo -e "${CYAN}Enter username: ${NC}")" username
    fi

    if ! _user_exists "${username}"; then
        log_error "User '${username}' not found."
        return 1
    fi

    local user_line
    user_line="$(_get_user_line "${username}")"
    local uuid email
    uuid="$(_parse_user_field "${user_line}" 2)"
    email="$(_parse_user_field "${user_line}" 3)"

    # Read API token from credentials file if available
    local api_token=""
    local creds_file="${USER_REGISTRY_DIR}/${username}.credentials"
    if [[ -f "${creds_file}" ]]; then
        api_token="$(grep '^API_TOKEN_KEY=' "${creds_file}" 2>/dev/null | cut -d'=' -f2-)" || api_token=""
        if [[ "${api_token}" == "NOT_CREATED" ]]; then
            api_token=""
        fi
    fi

    _generate_user_guide "${username}" "${uuid}" "${api_token}" "${email}"

    local guide_file="${USER_GUIDES_DIR}/${username}-guide.md"
    echo ""
    echo "==========================================="
    log_success "Guide exported to: ${guide_file}"
    echo "==========================================="
    echo ""

    if confirm_action "Display the guide now?"; then
        echo ""
        cat "${guide_file}"
    fi
}

###############################################################################
# manage_users()
#
# Interactive menu for user management.
###############################################################################
manage_users() {
    while true; do
        echo ""
        echo -e "${BLUE}============================================${NC}"
        echo -e "${BLUE}  AI Gateway Bridge - User Management       ${NC}"
        echo -e "${BLUE}============================================${NC}"
        echo ""
        echo "  1) Create new user"
        echo "  2) Disable user"
        echo "  3) List all users"
        echo "  4) Export user onboarding guide"
        echo "  0) Exit"
        echo ""
        read -r -p "Select option [0-4]: " choice

        case "${choice}" in
            1) echo ""; create_user ;;
            2) echo ""; disable_user ;;
            3) echo ""; list_users ;;
            4) echo ""; export_user_guide ;;
            0|q|Q|exit)
                log_info "Exiting user management."
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
        create)
            create_user "${2:-}"
            ;;
        disable)
            disable_user "${2:-}"
            ;;
        list)
            list_users
            ;;
        guide)
            export_user_guide "${2:-}"
            ;;
        help|--help|-h)
            echo "AI Gateway Bridge - User Management"
            echo ""
            echo "Usage:"
            echo "  $0                      # Interactive menu"
            echo "  $0 create [username]    # Create new user"
            echo "  $0 disable [username]   # Disable user"
            echo "  $0 list                 # List all users"
            echo "  $0 guide [username]     # Export onboarding guide"
            echo "  $0 help                 # Show this help"
            ;;
        "")
            manage_users
            ;;
        *)
            log_error "Unknown command: $1"
            echo "Run '$0 help' for usage information."
            exit 1
            ;;
    esac
fi
