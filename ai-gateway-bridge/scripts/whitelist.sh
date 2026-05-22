#!/usr/bin/env bash
###############################################################################
# AI Gateway Bridge - Whitelist Management Script
#
# Manages the AI domain whitelist used by Xray routing rules.
# Provides an interactive menu to:
#   - View current whitelist
#   - Add new domains
#   - Remove domains
#   - Test domain accessibility through the tunnel
#   - Update Xray routing configuration after changes
#
# Usage:
#   bash scripts/whitelist.sh              # Interactive menu
#   bash scripts/whitelist.sh list         # List domains
#   bash scripts/whitelist.sh add <domain> # Add a domain
#   bash scripts/whitelist.sh remove <domain>
#   bash scripts/whitelist.sh test <domain>
#
# Dependencies: scripts/common.sh
###############################################################################

set -euo pipefail

# Guard against double-sourcing (readonly variables would conflict)
if [[ -n "${_WHITELIST_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
readonly _WHITELIST_SH_LOADED=1

# Resolve the directory this script resides in
# Use _WL_SCRIPT_DIR to avoid conflict with readonly SCRIPT_DIR from install.sh
_WL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_WL_PROJECT_DIR="$(cd "${_WL_SCRIPT_DIR}/.." && pwd)"

# Source common utilities
if [[ -f "${_WL_SCRIPT_DIR}/common.sh" ]]; then
    # shellcheck source=scripts/common.sh
    source "${_WL_SCRIPT_DIR}/common.sh"
else
    # Minimal fallback if common.sh is not available
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
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

# Color fallbacks for display functions (if not set by common.sh)
: "${CYAN:=\033[0;36m}"
: "${GREEN:=\033[0;32m}"
: "${NC:=${COLOR_RESET:-\033[0m}}"
: "${BLUE:=\033[0;34m}"
: "${RED:=\033[0;31m}"
: "${YELLOW:=\033[1;33m}"

# Paths
WHITELIST_FILE="${_WL_PROJECT_DIR}/configs/whitelist/ai-domains.txt"
INSTALLED_WHITELIST="/opt/ai-gateway-bridge/configs/whitelist/ai-domains.txt"
XRAY_CLIENT_CONFIG="/usr/local/etc/xray/config.json"
XRAY_SERVER_CONFIG="/usr/local/etc/xray/config.json"

# Proxy settings for testing (Xray client SOCKS5 inbound)
PROXY_SOCKS="socks5://127.0.0.1:10808"
PROXY_HTTP="http://127.0.0.1:10809"

###############################################################################
# load_whitelist()
#
# Read domains from the whitelist file, filtering out comments and empty lines.
# Returns: array of domain strings via stdout (one per line)
###############################################################################
load_whitelist() {
    local whitelist_path="${1:-${WHITELIST_FILE}}"

    if [[ ! -f "${whitelist_path}" ]]; then
        # Try the installed location
        if [[ -f "${INSTALLED_WHITELIST}" ]]; then
            whitelist_path="${INSTALLED_WHITELIST}"
        else
            log_error "Whitelist file not found: ${whitelist_path}"
            log_error "Expected at: ${WHITELIST_FILE} or ${INSTALLED_WHITELIST}"
            return 1
        fi
    fi

    # Read file, strip comments (lines starting with #), trim whitespace, skip empty lines
    grep -v '^\s*#' "${whitelist_path}" | grep -v '^\s*$' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | sort -u
}

###############################################################################
# _resolve_whitelist_target()
#
# Resolve the whitelist file path that should be modified.
###############################################################################
_resolve_whitelist_target() {
    local target_file="${WHITELIST_FILE}"

    if [[ ! -f "${target_file}" ]]; then
        if [[ -f "${INSTALLED_WHITELIST}" ]]; then
            target_file="${INSTALLED_WHITELIST}"
        else
            log_error "Whitelist file not found."
            log_error "Expected at: ${WHITELIST_FILE} or ${INSTALLED_WHITELIST}"
            return 1
        fi
    fi

    printf '%s' "${target_file}"
}

###############################################################################
# _stage_whitelist_add()
#
# Create a staged whitelist file containing the new domain entry.
###############################################################################
_stage_whitelist_add() {
    local source_file="${1:?}"
    local staged_file="${2:?}"
    local domain="${3:?}"

    cp "${source_file}" "${staged_file}" || return 1
    {
        echo ""
        echo "# Added manually on $(date '+%Y-%m-%d %H:%M:%S')"
        echo "${domain}"
    } >> "${staged_file}"
}

###############################################################################
# _stage_whitelist_remove()
#
# Create a staged whitelist file with the domain removed. If the domain was
# preceded by an auto-generated "Added manually" comment, remove that comment too.
###############################################################################
_stage_whitelist_remove() {
    local source_file="${1:?}"
    local staged_file="${2:?}"
    local domain="${3:?}"

    awk -v domain="${domain}" '
        BEGIN { pending_comment = "" }
        {
            if (pending_comment != "") {
                if ($0 == domain) {
                    pending_comment = ""
                    next
                }
                print pending_comment
                pending_comment = ""
            }

            if ($0 ~ /^# Added manually on /) {
                pending_comment = $0
                next
            }

            if ($0 == domain) {
                next
            }

            print
        }
        END {
            if (pending_comment != "") {
                print pending_comment
            }
        }
    ' "${source_file}" > "${staged_file}"
}

###############################################################################
# _apply_whitelist_change()
#
# Apply a staged whitelist update and roll it back if Xray routing sync fails.
###############################################################################
_apply_whitelist_change() {
    local target_file="${1:?}"
    local staged_file="${2:?}"
    local domain="${3:?}"
    local action="${4:?}"
    local success_message="${5:?}"

    local backup_file
    backup_file="$(mktemp)"

    if ! cp "${target_file}" "${backup_file}"; then
        rm -f "${staged_file}" "${backup_file}"
        log_error "Failed to create whitelist backup before applying '${action}' for '${domain}'."
        return 1
    fi

    if ! cp "${staged_file}" "${target_file}"; then
        rm -f "${staged_file}" "${backup_file}"
        log_error "Failed to stage whitelist change for '${domain}'."
        return 1
    fi

    if ! _update_xray_routing "${domain}" "${action}"; then
        log_error "Xray routing update failed. Restoring whitelist state..."
        if ! cp "${backup_file}" "${target_file}"; then
            log_error "Failed to restore whitelist backup: ${backup_file}"
        fi
        rm -f "${staged_file}" "${backup_file}"
        return 1
    fi

    rm -f "${staged_file}" "${backup_file}"
    log_info "${success_message}"
}

###############################################################################
# _derive_xray_domain_rule()
#
# Normalize a user-entered domain into the Xray rule form used in config.json.
###############################################################################
_derive_xray_domain_rule() {
    local domain="${1:?}"
    local base_domain="${domain}"

    if [[ "$(echo "${domain}" | tr -cd '.' | wc -c)" -gt 1 ]]; then
        base_domain="$(echo "${domain}" | sed 's/^[^.]*\.//' 2>/dev/null)"
    fi

    printf 'domain:%s' "${base_domain}"
}

###############################################################################
# add_domain()
#
# Add a domain to the whitelist file and update Xray routing configuration.
#
# Arguments:
#   $1 - Domain to add (e.g., "api.newservice.com")
###############################################################################
add_domain() {
    local domain="${1:-}"

    if [[ -z "${domain}" ]]; then
        log_error "No domain specified."
        echo "Usage: add_domain <domain>"
        return 1
    fi

    # Validate domain format (basic check)
    if ! echo "${domain}" | grep -qP '^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$'; then
        log_error "Invalid domain format: ${domain}"
        log_error "Expected format: subdomain.example.com"
        return 1
    fi

    local target_file
    target_file="$(_resolve_whitelist_target)" || return 1

    # Check if domain already exists
    if load_whitelist "${target_file}" | grep -qFx "${domain}"; then
        log_warn "Domain '${domain}' is already in the whitelist."
        return 0
    fi

    local staged_file
    staged_file="$(mktemp)"

    if ! _stage_whitelist_add "${target_file}" "${staged_file}" "${domain}"; then
        rm -f "${staged_file}"
        log_error "Failed to prepare whitelist update for '${domain}'."
        return 1
    fi

    _apply_whitelist_change "${target_file}" "${staged_file}" "${domain}" "add" \
        "Domain '${domain}' added to whitelist: ${target_file}"
}

###############################################################################
# remove_domain()
#
# Remove a domain from the whitelist file and update Xray routing.
#
# Arguments:
#   $1 - Domain to remove
###############################################################################
remove_domain() {
    local domain="${1:-}"

    if [[ -z "${domain}" ]]; then
        log_error "No domain specified."
        echo "Usage: remove_domain <domain>"
        return 1
    fi

    local target_file
    target_file="$(_resolve_whitelist_target)" || return 1

    # Check if domain exists in whitelist
    if ! load_whitelist "${target_file}" | grep -qFx "${domain}"; then
        log_warn "Domain '${domain}' is not in the whitelist."
        return 0
    fi

    # Confirm removal
    if ! confirm_action "Remove '${domain}' from the whitelist?"; then
        log_info "Removal cancelled."
        return 0
    fi

    local staged_file
    staged_file="$(mktemp)"

    if ! _stage_whitelist_remove "${target_file}" "${staged_file}" "${domain}"; then
        rm -f "${staged_file}"
        log_error "Failed to prepare whitelist removal for '${domain}'."
        return 1
    fi

    _apply_whitelist_change "${target_file}" "${staged_file}" "${domain}" "remove" \
        "Domain '${domain}' removed from whitelist."
}

###############################################################################
# list_domains()
#
# Display the current whitelist with formatting and domain count.
###############################################################################
list_domains() {
    log_step "Current AI Domain Whitelist"
    echo "==========================================="

    local domains
    domains="$(load_whitelist 2>/dev/null)" || {
        log_error "Could not load whitelist."
        return 1
    }

    local count=0
    local current_group=""

    # Read the raw file to preserve group comments
    local whitelist_path="${WHITELIST_FILE}"
    if [[ ! -f "${whitelist_path}" ]]; then
        if [[ -f "${INSTALLED_WHITELIST}" ]]; then
            whitelist_path="${INSTALLED_WHITELIST}"
        fi
    fi

    if [[ -f "${whitelist_path}" ]]; then
        while IFS= read -r line; do
            # Skip the file header block
            if [[ "${line}" =~ ^###+ ]]; then
                continue
            fi

            # Section header comments (lines starting with # =)
            if [[ "${line}" =~ ^#\ =+ ]]; then
                echo ""
                continue
            fi

            # Group label comments
            if [[ "${line}" =~ ^#\ .+ ]]; then
                echo -e "${CYAN}${line}${NC}"
                continue
            fi

            # Empty lines
            if [[ -z "${line}" || "${line}" =~ ^[[:space:]]*$ ]]; then
                continue
            fi

            # Domain line
            echo -e "  ${GREEN}+${NC} ${line}"
            ((count++)) || true
        done < "${whitelist_path}"
    fi

    echo ""
    echo "==========================================="
    log_info "Total domains: ${count}"
}

###############################################################################
# test_domain()
#
# Test if a specific domain is accessible through the proxy tunnel.
#
# Arguments:
#   $1 - Domain to test (e.g., "api.anthropic.com")
###############################################################################
test_domain() {
    local domain="${1:-}"

    if [[ -z "${domain}" ]]; then
        log_error "No domain specified."
        echo "Usage: test_domain <domain>"
        return 1
    fi

    log_step "Testing domain accessibility: ${domain}"
    echo ""

    # Test 1: Direct DNS resolution
    log_info "Test 1: DNS Resolution..."
    if command_exists dig; then
        local dns_result
        dns_result="$(dig +short "${domain}" 2>/dev/null | head -3)"
        if [[ -n "${dns_result}" ]]; then
            echo -e "  ${GREEN}[PASS]${NC} DNS resolves to: ${dns_result}"
        else
            echo -e "  ${YELLOW}[WARN]${NC} DNS resolution returned empty (may be normal for some CDN domains)"
        fi
    elif command_exists nslookup; then
        if nslookup "${domain}" >/dev/null 2>&1; then
            echo -e "  ${GREEN}[PASS]${NC} DNS resolution successful"
        else
            echo -e "  ${RED}[FAIL]${NC} DNS resolution failed"
        fi
    else
        echo -e "  ${YELLOW}[SKIP]${NC} No DNS tools available (dig/nslookup)"
    fi

    # Test 2: Direct HTTPS connection (may fail from China)
    log_info "Test 2: Direct HTTPS connection (without proxy)..."
    local http_code
    http_code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 "https://${domain}" 2>/dev/null)" || http_code="000"
    if [[ "${http_code}" != "000" ]]; then
        echo -e "  ${GREEN}[PASS]${NC} Direct connection: HTTP ${http_code}"
    else
        echo -e "  ${YELLOW}[INFO]${NC} Direct connection failed (expected if behind GFW)"
    fi

    # Test 3: Connection through SOCKS5 proxy
    log_info "Test 3: Connection through SOCKS5 proxy (port 10808)..."
    if curl -sf --proxy "${PROXY_SOCKS}" --connect-timeout 15 --max-time 30 "https://${domain}" -o /dev/null 2>/dev/null; then
        http_code="$(curl -s -o /dev/null -w '%{http_code}' --proxy "${PROXY_SOCKS}" --connect-timeout 15 --max-time 30 "https://${domain}" 2>/dev/null)" || http_code="000"
        echo -e "  ${GREEN}[PASS]${NC} Proxy connection: HTTP ${http_code}"
    else
        echo -e "  ${RED}[FAIL]${NC} Proxy connection failed"
        echo -e "  ${YELLOW}[HINT]${NC} Check: 1) Xray client running  2) Domain in whitelist  3) Tunnel connected"
    fi

    # Test 4: Connection through HTTP proxy
    log_info "Test 4: Connection through HTTP proxy (port 10809)..."
    if curl -sf --proxy "${PROXY_HTTP}" --connect-timeout 15 --max-time 30 "https://${domain}" -o /dev/null 2>/dev/null; then
        http_code="$(curl -s -o /dev/null -w '%{http_code}' --proxy "${PROXY_HTTP}" --connect-timeout 15 --max-time 30 "https://${domain}" 2>/dev/null)" || http_code="000"
        echo -e "  ${GREEN}[PASS]${NC} HTTP proxy connection: HTTP ${http_code}"
    else
        echo -e "  ${RED}[FAIL]${NC} HTTP proxy connection failed"
    fi

    # Test 5: Check if domain is in whitelist
    log_info "Test 5: Whitelist membership check..."
    local in_whitelist=false
    if load_whitelist 2>/dev/null | grep -qFx "${domain}"; then
        in_whitelist=true
        echo -e "  ${GREEN}[PASS]${NC} Domain '${domain}' is in the whitelist"
    else
        # Also check if a parent domain matches (e.g., api.openai.com matches openai.com in routing)
        local parent_domain
        parent_domain="$(echo "${domain}" | sed 's/^[^.]*\.//')"
        if load_whitelist 2>/dev/null | grep -qF "${parent_domain}"; then
            echo -e "  ${GREEN}[PASS]${NC} Parent domain '${parent_domain}' covers '${domain}' in whitelist"
            in_whitelist=true
        else
            echo -e "  ${RED}[FAIL]${NC} Domain '${domain}' is NOT in the whitelist"
            echo -e "  ${YELLOW}[HINT]${NC} Add it with: bash whitelist.sh add ${domain}"
        fi
    fi

    echo ""
    echo "==========================================="
    if [[ "${in_whitelist}" == "true" ]]; then
        log_info "Domain '${domain}' whitelist status: ALLOWED"
    else
        log_warn "Domain '${domain}' whitelist status: NOT ALLOWED"
    fi
}

###############################################################################
# _update_xray_routing()
#
# Internal function to update Xray routing rules after whitelist changes.
# Restarts Xray service to apply changes.
#
# Arguments:
#   $1 - Domain that was added/removed
#   $2 - Action: "add" or "remove"
###############################################################################
_update_xray_routing() {
    local domain="${1}"
    local action="${2}"
    local xray_domain_rule
    xray_domain_rule="$(_derive_xray_domain_rule "${domain}")"

    log_info "Updating Xray routing configuration..."

    # Best-effort install of jq for JSON config manipulation
    if ! command_exists jq; then
        if declare -f install_if_missing &>/dev/null; then
            install_if_missing jq jq 2>/dev/null || true
        fi
    fi

    # Check if jq is available for JSON manipulation
    if ! command_exists jq; then
        log_error "jq is not installed. Cannot auto-update Xray config."
        log_error "Refusing to change whitelist state without route-engine synchronization."
        return 1
    fi

    # Check if Xray config exists
    if [[ ! -f "${XRAY_CLIENT_CONFIG}" ]]; then
        log_error "Xray client config not found at ${XRAY_CLIENT_CONFIG}"
        log_error "Refusing to change whitelist state before Xray routing is available."
        return 1
    fi

    # Backup current config
    cp "${XRAY_CLIENT_CONFIG}" "${XRAY_CLIENT_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"

    if [[ "${action}" == "add" ]]; then
        # Check if a rule for this domain already exists
        if grep -q "\"${xray_domain_rule}\"" "${XRAY_CLIENT_CONFIG}" 2>/dev/null; then
            log_info "Xray routing rule for '${xray_domain_rule}' already exists."
        else
            # Add a new routing rule before the final block rule
            # We insert a new rule object for the custom domain
            local tmp_config
            tmp_config="$(mktemp)"

            if jq --arg domain "${xray_domain_rule}" --arg comment "Custom whitelist: ${domain}" \
                '.routing.rules = [.routing.rules[0:-1][], {"type":"field","outboundTag":"proxy","comment":$comment,"domain":[$domain]}, .routing.rules[-1]]' \
                "${XRAY_CLIENT_CONFIG}" > "${tmp_config}" 2>/dev/null \
               && [[ -s "${tmp_config}" ]]; then
                mv "${tmp_config}" "${XRAY_CLIENT_CONFIG}"
                log_info "Xray routing rule added for '${xray_domain_rule}'."
            else
                rm -f "${tmp_config}"
                log_error "Failed to update Xray config via jq for '${xray_domain_rule}'."
                return 1
            fi
        fi
    elif [[ "${action}" == "remove" ]]; then
        # Remove routing rules containing this domain
        local tmp_config
        tmp_config="$(mktemp)"

        if jq --arg rule "${xray_domain_rule}" \
            '.routing.rules = [.routing.rules[] | select(.domain == null or (.domain | index($rule) == null))]' \
            "${XRAY_CLIENT_CONFIG}" > "${tmp_config}" 2>/dev/null \
           && [[ -s "${tmp_config}" ]]; then
            mv "${tmp_config}" "${XRAY_CLIENT_CONFIG}"
            log_info "Xray routing rules for '${xray_domain_rule}' removed."
        else
            rm -f "${tmp_config}"
            log_error "Failed to update Xray config via jq for '${xray_domain_rule}'."
            return 1
        fi
    fi

    # Restart Xray to apply changes
    if command_exists systemctl && systemctl is-active --quiet xray 2>/dev/null; then
        log_info "Restarting Xray to apply routing changes..."
        systemctl restart xray
        sleep 2
        if systemctl is-active --quiet xray; then
            log_info "Xray restarted successfully with updated routing."
        else
            log_error "Xray failed to restart! Restoring backup config..."
            local latest_backup
            latest_backup="$(ls -t "${XRAY_CLIENT_CONFIG}".bak.* 2>/dev/null | head -1)"
            if [[ -n "${latest_backup}" ]]; then
                cp "${latest_backup}" "${XRAY_CLIENT_CONFIG}"
                systemctl restart xray
                log_error "Backup restored. Please check the config manually."
            fi
            return 1
        fi
    else
        log_warn "Xray service is not running. Changes will take effect on next start."
    fi
}

###############################################################################
# manage_whitelist()
#
# Interactive menu for whitelist management.
###############################################################################
manage_whitelist() {
    while true; do
        echo ""
        echo -e "${BLUE}============================================${NC}"
        echo -e "${BLUE}  AI Gateway Bridge - Whitelist Management  ${NC}"
        echo -e "${BLUE}============================================${NC}"
        echo ""
        echo "  1) List all whitelisted domains"
        echo "  2) Add a domain to whitelist"
        echo "  3) Remove a domain from whitelist"
        echo "  4) Test domain accessibility"
        echo "  5) Reload whitelist to Xray"
        echo "  0) Exit"
        echo ""
        read -r -p "Select option [0-5]: " choice

        case "${choice}" in
            1)
                echo ""
                list_domains
                ;;
            2)
                echo ""
                read -r -p "Enter domain to add (e.g., api.newservice.com): " new_domain
                if [[ -n "${new_domain}" ]]; then
                    add_domain "${new_domain}"
                else
                    log_warn "No domain entered."
                fi
                ;;
            3)
                echo ""
                read -r -p "Enter domain to remove: " del_domain
                if [[ -n "${del_domain}" ]]; then
                    remove_domain "${del_domain}"
                else
                    log_warn "No domain entered."
                fi
                ;;
            4)
                echo ""
                read -r -p "Enter domain to test (e.g., api.anthropic.com): " test_dom
                if [[ -n "${test_dom}" ]]; then
                    test_domain "${test_dom}"
                else
                    log_warn "No domain entered."
                fi
                ;;
            5)
                echo ""
                log_step "Reloading whitelist to Xray..."
                if command_exists systemctl && systemctl is-active --quiet xray 2>/dev/null; then
                    systemctl restart xray
                    sleep 2
                    if systemctl is-active --quiet xray; then
                        log_info "Xray restarted successfully."
                    else
                        log_error "Xray failed to restart. Check config: journalctl -u xray --no-pager -n 20"
                    fi
                else
                    log_warn "Xray is not running. Cannot reload."
                fi
                ;;
            0|q|Q|exit)
                log_info "Exiting whitelist management."
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
    # Parse command line arguments
    case "${1:-}" in
        list)
            list_domains
            ;;
        add)
            if [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 add <domain>"
                exit 1
            fi
            add_domain "$2"
            ;;
        remove)
            if [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 remove <domain>"
                exit 1
            fi
            remove_domain "$2"
            ;;
        test)
            if [[ -z "${2:-}" ]]; then
                log_error "Usage: $0 test <domain>"
                exit 1
            fi
            test_domain "$2"
            ;;
        help|--help|-h)
            echo "AI Gateway Bridge - Whitelist Management"
            echo ""
            echo "Usage:"
            echo "  $0              # Interactive menu"
            echo "  $0 list         # List all domains"
            echo "  $0 add <domain> # Add domain to whitelist"
            echo "  $0 remove <domain> # Remove domain from whitelist"
            echo "  $0 test <domain>   # Test domain connectivity"
            echo "  $0 help         # Show this help"
            ;;
        "")
            # No arguments - run interactive menu
            manage_whitelist
            ;;
        *)
            log_error "Unknown command: $1"
            echo "Run '$0 help' for usage information."
            exit 1
            ;;
    esac
fi
