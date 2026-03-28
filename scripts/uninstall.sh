#!/usr/bin/env bash
###############################################################################
# Bifrost - Uninstall Script
#
# Completely removes all Bifrost components from the server.
# Includes triple confirmation for safety.
#
# Components removed:
#   - Xray (client or server)
#   - Caddy web server
#   - New API Docker container and images
#   - 3x-ui panel
#   - Netdata monitoring
#   - fail2ban configuration
#   - Cron jobs
#   - Configuration files
#   - Log files
#   - Sysctl hardening parameters
#   - Restores original SSH config and firewall rules
#
# Usage:
#   bash scripts/uninstall.sh
#
# Dependencies: scripts/common.sh
###############################################################################

set -euo pipefail

# Guard against double-sourcing (readonly variables would conflict)
if [[ -n "${_UNINSTALL_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
readonly _UNINSTALL_SH_LOADED=1

# Resolve the directory this script resides in
# Use _UNI_SCRIPT_DIR to avoid conflict with readonly SCRIPT_DIR from install.sh
_UNI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_UNI_PROJECT_DIR="$(cd "${_UNI_SCRIPT_DIR}/.." && pwd)"

# Source common utilities
if [[ -f "${_UNI_SCRIPT_DIR}/common.sh" ]]; then
    # shellcheck source=scripts/common.sh
    source "${_UNI_SCRIPT_DIR}/common.sh"
else
    # Minimal fallback
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
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

# Color fallbacks
: "${RED:=\033[0;31m}"
: "${GREEN:=\033[0;32m}"
: "${YELLOW:=\033[1;33m}"
: "${BLUE:=\033[0;34m}"
: "${BOLD:=${COLOR_BOLD:-\033[1m}}"
: "${NC:=${COLOR_RESET:-\033[0m}}"

# Paths (use := to avoid overwriting readonly vars set by install.sh)
: "${INSTALL_DIR:=/opt/bifrost}"
: "${LOG_DIR:=/var/log/bifrost}"
: "${ANTI_DPI_ROTATE_CRON_SCRIPT:=/opt/bifrost/rotate-dest.sh}"
: "${RKHUNTER_CRON_FILE:=/etc/cron.weekly/rkhunter-scan}"
: "${LYNIS_CRON_FILE:=/etc/cron.monthly/lynis-audit}"

# Track what was removed for final summary
declare -a REMOVED_ITEMS=()
declare -a SKIPPED_ITEMS=()
declare -a FAILED_ITEMS=()

add_removed()  { REMOVED_ITEMS+=("$1"); }
add_skipped()  { SKIPPED_ITEMS+=("$1"); }
add_failed()   { FAILED_ITEMS+=("$1"); }

###############################################################################
# Triple confirmation
###############################################################################
confirm_uninstall() {
    echo ""
    echo -e "${RED}${BOLD}================================================================${NC}"
    echo -e "${RED}${BOLD}  WARNING: Bifrost Complete Uninstall${NC}"
    echo -e "${RED}${BOLD}================================================================${NC}"
    echo ""
    echo "This will permanently remove ALL Bifrost components:"
    echo ""
    echo "  - Xray proxy service (client/server)"
    echo "  - Caddy web server and configuration"
    echo "  - New API Docker container and images"
    echo "  - 3x-ui management panel"
    echo "  - Netdata monitoring agent"
    echo "  - fail2ban custom configuration"
    echo "  - All configuration files in /opt/bifrost/"
    echo "  - All log files in /var/log/bifrost/"
    echo "  - All related cron jobs"
    echo "  - Kernel hardening sysctl parameters"
    echo ""
    echo -e "${YELLOW}This action CANNOT be undone.${NC}"
    echo ""

    # Confirmation 1
    echo -e "${RED}Confirmation 1/3:${NC}"
    if ! confirm_action "Are you sure you want to uninstall Bifrost?"; then
        log_info "Uninstall cancelled at step 1."
        exit 0
    fi

    # Confirmation 2
    echo ""
    echo -e "${RED}Confirmation 2/3:${NC}"
    echo "Type 'UNINSTALL' (all caps) to confirm:"
    read -r confirmation_text
    if [[ "${confirmation_text}" != "UNINSTALL" ]]; then
        log_info "Uninstall cancelled at step 2. You typed: '${confirmation_text}'"
        exit 0
    fi

    # Confirmation 3
    echo ""
    echo -e "${RED}Confirmation 3/3 (Final):${NC}"
    if ! confirm_action "FINAL WARNING: This will remove everything. Proceed?"; then
        log_info "Uninstall cancelled at step 3."
        exit 0
    fi

    echo ""
    log_step "Triple confirmation passed. Starting uninstall..."
    echo ""
}

###############################################################################
# Stop and disable services
###############################################################################
stop_services() {
    log_step "[1/9] Stopping and disabling services..."

    local services=("xray" "caddy" "x-ui" "netdata" "fail2ban")

    for svc in ${services[@]+"${services[@]}"}; do
        if command_exists systemctl; then
            if systemctl is-active --quiet "${svc}" 2>/dev/null; then
                log_info "Stopping ${svc}..."
                systemctl stop "${svc}" 2>/dev/null && add_removed "Service stopped: ${svc}" || add_failed "Failed to stop: ${svc}"
            fi
            if systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
                log_info "Disabling ${svc}..."
                systemctl disable "${svc}" 2>/dev/null && add_removed "Service disabled: ${svc}" || add_failed "Failed to disable: ${svc}"
            fi
        elif command_exists service; then
            service "${svc}" stop 2>/dev/null && add_removed "Service stopped: ${svc}" || true
        fi
    done

    # Stop New API Docker container
    if command_exists docker; then
        for container_name in "new-api" "newapi" "one-api" "oneapi"; do
            if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qw "${container_name}"; then
                log_info "Stopping Docker container: ${container_name}..."
                docker stop "${container_name}" 2>/dev/null || true
                add_removed "Docker container stopped: ${container_name}"
            fi
        done
    fi

    log_info "Services stopped."
}

###############################################################################
# Remove Docker containers and images (New API)
###############################################################################
remove_docker_resources() {
    log_step "[2/9] Removing Docker containers and images..."

    if ! command_exists docker; then
        add_skipped "Docker not installed - skipping container removal"
        return
    fi

    # Remove New API containers
    for container_name in "new-api" "newapi" "one-api" "oneapi"; do
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qw "${container_name}"; then
            log_info "Removing container: ${container_name}..."
            docker rm -f "${container_name}" 2>/dev/null && add_removed "Docker container removed: ${container_name}" || add_failed "Failed to remove container: ${container_name}"
        fi
    done

    # Remove New API images
    local images_to_remove=("justsong/new-api" "quantumnous/new-api" "calciumion/new-api")
    for image in ${images_to_remove[@]+"${images_to_remove[@]}"}; do
        local image_ids
        image_ids="$(docker images "${image}" -q 2>/dev/null)"
        if [[ -n "${image_ids}" ]]; then
            log_info "Removing Docker image: ${image}..."
            echo "${image_ids}" | xargs docker rmi -f 2>/dev/null && add_removed "Docker image removed: ${image}" || add_failed "Failed to remove image: ${image}"
        fi
    done

    # Remove Docker volumes associated with New API
    for vol_name in "new-api-data" "newapi-data" "one-api-data"; do
        if docker volume ls --format '{{.Name}}' 2>/dev/null | grep -qw "${vol_name}"; then
            log_info "Removing Docker volume: ${vol_name}..."
            docker volume rm "${vol_name}" 2>/dev/null && add_removed "Docker volume removed: ${vol_name}" || add_failed "Failed to remove volume: ${vol_name}"
        fi
    done

    # Remove docker-compose files
    local compose_dirs=("/opt/new-api" "/opt/bifrost/new-api" "${INSTALL_DIR}/docker")
    for dir in ${compose_dirs[@]+"${compose_dirs[@]}"}; do
        if [[ -d "${dir}" ]]; then
            log_info "Removing compose directory: ${dir}..."
            rm -rf "${dir}" && add_removed "Directory removed: ${dir}" || add_failed "Failed to remove: ${dir}"
        fi
    done

    log_info "Docker resources cleaned up."
}

###############################################################################
# Remove installed packages / binaries
###############################################################################
remove_packages() {
    log_step "[3/9] Removing installed packages and binaries..."

    # Remove Xray
    if [[ -f /usr/local/bin/xray ]]; then
        log_info "Removing Xray binary..."
        rm -f /usr/local/bin/xray
        rm -rf /usr/local/share/xray
        rm -f /etc/systemd/system/xray.service
        rm -f /etc/systemd/system/xray@.service
        add_removed "Xray binary and service files"
    else
        add_skipped "Xray binary not found"
    fi

    # Remove Caddy
    if command_exists caddy; then
        log_info "Removing Caddy..."
        if command_exists apt-get; then
            apt-get purge -y caddy 2>/dev/null || true
        elif command_exists dnf; then
            dnf remove -y caddy 2>/dev/null || true
        elif command_exists yum; then
            yum remove -y caddy 2>/dev/null || true
        fi
        # Also remove if installed as binary
        rm -f /usr/bin/caddy /usr/local/bin/caddy 2>/dev/null || true
        add_removed "Caddy web server"
    else
        add_skipped "Caddy not installed"
    fi

    # Remove 3x-ui
    if [[ -f /usr/local/x-ui/x-ui ]]; then
        log_info "Removing 3x-ui..."
        # 3x-ui has its own uninstall
        if [[ -f /usr/local/x-ui/x-ui ]]; then
            /usr/local/x-ui/x-ui setting -remove 2>/dev/null || true
        fi
        rm -rf /usr/local/x-ui
        rm -f /etc/systemd/system/x-ui.service
        add_removed "3x-ui panel"
    else
        add_skipped "3x-ui not installed"
    fi

    # Remove Netdata
    if command_exists netdata; then
        log_info "Removing Netdata..."
        # Use official uninstaller if available
        if [[ -f /usr/libexec/netdata/netdata-uninstaller.sh ]]; then
            /usr/libexec/netdata/netdata-uninstaller.sh --yes --force 2>/dev/null || true
        elif [[ -f /opt/netdata/usr/libexec/netdata/netdata-uninstaller.sh ]]; then
            /opt/netdata/usr/libexec/netdata/netdata-uninstaller.sh --yes --force 2>/dev/null || true
        else
            # Manual removal
            if command_exists apt-get; then
                apt-get purge -y netdata 2>/dev/null || true
            elif command_exists dnf; then
                dnf remove -y netdata 2>/dev/null || true
            fi
        fi
        add_removed "Netdata monitoring agent"
    else
        add_skipped "Netdata not installed"
    fi

    # Reload systemd after removing service files
    if command_exists systemctl; then
        systemctl daemon-reload 2>/dev/null || true
    fi

    log_info "Packages and binaries removed."
}

###############################################################################
# Remove configuration files
###############################################################################
remove_configs() {
    log_step "[4/9] Removing configuration files..."

    # Xray config
    local xray_config_dirs=("/usr/local/etc/xray" "/etc/xray")
    for dir in ${xray_config_dirs[@]+"${xray_config_dirs[@]}"}; do
        if [[ -d "${dir}" ]]; then
            log_info "Removing Xray config: ${dir}..."
            rm -rf "${dir}"
            add_removed "Xray config: ${dir}"
        fi
    done

    # Caddy config
    local caddy_config_dirs=("/etc/caddy" "/var/lib/caddy" "/root/.config/caddy" "/root/.local/share/caddy")
    for dir in ${caddy_config_dirs[@]+"${caddy_config_dirs[@]}"}; do
        if [[ -d "${dir}" ]]; then
            log_info "Removing Caddy config: ${dir}..."
            rm -rf "${dir}"
            add_removed "Caddy config: ${dir}"
        fi
    done

    # fail2ban custom configs (only remove our additions, not the whole package)
    if [[ -f /etc/fail2ban/jail.local ]]; then
        if grep -q "bifrost" /etc/fail2ban/jail.local 2>/dev/null; then
            log_info "Removing custom fail2ban jail.local..."
            rm -f /etc/fail2ban/jail.local
            add_removed "fail2ban jail.local (custom)"
        else
            add_skipped "fail2ban jail.local (not ours, preserving)"
        fi
    fi
    rm -f /etc/fail2ban/filter.d/caddy-auth.conf 2>/dev/null && add_removed "fail2ban caddy-auth filter" || true
    rm -f /etc/fail2ban/filter.d/caddy-botsearch.conf 2>/dev/null && add_removed "fail2ban caddy-botsearch filter" || true

    # Sysctl hardening
    if [[ -f /etc/sysctl.d/99-ai-gateway-hardening.conf ]]; then
        log_info "Removing kernel hardening parameters..."
        rm -f /etc/sysctl.d/99-ai-gateway-hardening.conf
        sysctl --system >/dev/null 2>&1 || true
        add_removed "Sysctl hardening parameters"
    else
        add_skipped "Sysctl hardening config not found"
    fi

    # Logrotate config
    if [[ -f /etc/logrotate.d/bifrost ]]; then
        log_info "Removing logrotate configuration..."
        rm -f /etc/logrotate.d/bifrost
        add_removed "Logrotate config"
    fi

    # Netdata config
    local netdata_config_dirs=("/etc/netdata" "/opt/netdata/etc/netdata")
    for dir in ${netdata_config_dirs[@]+"${netdata_config_dirs[@]}"}; do
        if [[ -d "${dir}" ]]; then
            log_info "Removing Netdata config: ${dir}..."
            rm -rf "${dir}"
            add_removed "Netdata config: ${dir}"
        fi
    done

    # Main install directory
    if [[ -d "${INSTALL_DIR}" ]]; then
        log_info "Removing install directory: ${INSTALL_DIR}..."
        rm -rf "${INSTALL_DIR}"
        add_removed "Install directory: ${INSTALL_DIR}"
    fi

    # Decoy website
    if [[ -d "/var/www/html/decoy" ]]; then
        log_info "Removing decoy website..."
        rm -rf "/var/www/html/decoy"
        add_removed "Decoy website: /var/www/html/decoy"
    fi

    log_info "Configuration files removed."
}

###############################################################################
# Remove log files
###############################################################################
remove_logs() {
    log_step "[5/9] Removing log files..."

    local log_dirs=("${LOG_DIR}" "/var/log/xray" "/var/log/caddy")

    for dir in ${log_dirs[@]+"${log_dirs[@]}"}; do
        if [[ -d "${dir}" ]]; then
            log_info "Removing log directory: ${dir}..."
            rm -rf "${dir}"
            add_removed "Log directory: ${dir}"
        fi
    done

    log_info "Log files removed."
}

###############################################################################
# Remove cron jobs
###############################################################################
remove_cron_jobs() {
    log_step "[6/9] Removing cron jobs..."

    local cron_patterns=(
        "# bifrost-daily-backup"
        "# bifrost-health-check"
        "# bifrost: dest rotation"
        "${ANTI_DPI_ROTATE_CRON_SCRIPT}"
    )
    local cron_pattern=""

    local current_crontab
    current_crontab="$(crontab -l 2>/dev/null)" || current_crontab=""

    if [[ -n "${current_crontab}" ]]; then
        local new_crontab="${current_crontab}"
        local found_any=false

        for cron_pattern in ${cron_patterns[@]+"${cron_patterns[@]}"}; do
            if echo "${new_crontab}" | grep -qF "${cron_pattern}"; then
                new_crontab="$(printf '%s\n' "${new_crontab}" | grep -vF "${cron_pattern}" || true)"
                found_any=true
                add_removed "Cron entry: ${cron_pattern}"
            fi
        done

        if [[ "${found_any}" == "true" ]]; then
            printf '%s\n' "${new_crontab}" | crontab -
            log_info "Cron jobs removed."
        else
            add_skipped "No Bifrost cron jobs found"
        fi
    else
        add_skipped "No crontab exists"
    fi

    local system_cron_file=""
    for system_cron_file in "${RKHUNTER_CRON_FILE}" "${LYNIS_CRON_FILE}"; do
        if [[ -f "${system_cron_file}" ]]; then
            rm -f "${system_cron_file}" && \
                add_removed "Cron file: ${system_cron_file}" || \
                add_failed "Failed to remove cron file: ${system_cron_file}"
        fi
    done
}

###############################################################################
# Restore original SSH config
###############################################################################
restore_ssh_config() {
    log_step "[7/9] Restoring original SSH configuration..."

    local ssh_config="/etc/ssh/sshd_config"
    local backup_pattern="${ssh_config}.bak.*"

    # Find the most recent backup
    local latest_backup=""
    # shellcheck disable=SC2086
    for f in ${backup_pattern}; do
        if [[ -f "${f}" ]]; then
            if [[ -z "${latest_backup}" || "${f}" -nt "${latest_backup}" ]]; then
                latest_backup="${f}"
            fi
        fi
    done

    # Also check for our specific backup
    if [[ -f "${ssh_config}.bak.bifrost" ]]; then
        latest_backup="${ssh_config}.bak.bifrost"
    fi

    if [[ -n "${latest_backup}" && -f "${latest_backup}" ]]; then
        log_info "Found SSH config backup: ${latest_backup}"
        if confirm_action "Restore original SSH config from backup?"; then
            cp "${latest_backup}" "${ssh_config}"
            # Restart SSH service
            if command_exists systemctl; then
                systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
            fi
            add_removed "SSH config restored from backup"
            log_info "SSH configuration restored."

            # Clean up backups
            rm -f "${ssh_config}".bak.bifrost 2>/dev/null || true
        else
            add_skipped "SSH config restore (user declined)"
        fi
    else
        log_info "No SSH config backup found. Current config left unchanged."
        add_skipped "SSH config (no backup found)"
    fi
}

###############################################################################
# Restore original firewall rules
###############################################################################
restore_firewall() {
    log_step "[8/9] Restoring firewall configuration..."

    # UFW (Debian/Ubuntu)
    if command_exists ufw; then
        log_info "Detected ufw firewall."

        # Check for backup
        if [[ -f "/etc/ufw/ufw.conf.bak.bifrost" ]]; then
            if confirm_action "Restore original ufw rules from backup?"; then
                ufw --force reset 2>/dev/null || true
                # Restore backed up rules
                if [[ -f "/etc/ufw/user.rules.bak.bifrost" ]]; then
                    cp "/etc/ufw/user.rules.bak.bifrost" "/etc/ufw/user.rules"
                fi
                if [[ -f "/etc/ufw/user6.rules.bak.bifrost" ]]; then
                    cp "/etc/ufw/user6.rules.bak.bifrost" "/etc/ufw/user6.rules"
                fi
                ufw --force enable 2>/dev/null || true
                add_removed "UFW rules restored from backup"
            else
                add_skipped "UFW restore (user declined)"
            fi
        else
            log_info "No ufw backup found. Resetting to defaults..."
            if confirm_action "Reset ufw to default rules (allow SSH, deny incoming)?"; then
                ufw --force reset 2>/dev/null || true
                ufw default deny incoming 2>/dev/null || true
                ufw default allow outgoing 2>/dev/null || true
                ufw allow ssh 2>/dev/null || true
                ufw --force enable 2>/dev/null || true
                add_removed "UFW reset to defaults"
            else
                add_skipped "UFW reset (user declined)"
            fi
        fi

    # firewalld (CentOS/RHEL)
    elif command_exists firewall-cmd; then
        log_info "Detected firewalld."

        if [[ -d "/etc/firewalld/zones.bak.bifrost" ]]; then
            if confirm_action "Restore original firewalld zones from backup?"; then
                cp -r /etc/firewalld/zones.bak.bifrost/* /etc/firewalld/zones/ 2>/dev/null || true
                firewall-cmd --reload 2>/dev/null || true
                add_removed "Firewalld zones restored from backup"
            else
                add_skipped "Firewalld restore (user declined)"
            fi
        else
            log_info "No firewalld backup found. Removing custom rules..."
            # Remove custom services and reload
            for port_proto in "10808/tcp" "10809/tcp" "19999/tcp"; do
                firewall-cmd --permanent --remove-port="${port_proto}" 2>/dev/null || true
            done
            firewall-cmd --reload 2>/dev/null || true
            add_removed "Firewalld custom rules removed"
        fi

    else
        log_info "No firewall management tool detected (ufw/firewalld)."
        add_skipped "Firewall (no management tool found)"
    fi

    log_info "Firewall configuration handled."
}

###############################################################################
# Print summary
###############################################################################
print_summary() {
    log_step "[9/9] Uninstall Summary"
    echo ""
    echo "============================================"
    echo "  Bifrost - Uninstall Complete"
    echo "============================================"
    echo ""

    if [[ ${#REMOVED_ITEMS[@]} -gt 0 ]]; then
        echo -e "${GREEN}Removed (${#REMOVED_ITEMS[@]} items):${NC}"
        for item in ${REMOVED_ITEMS[@]+"${REMOVED_ITEMS[@]}"}; do
            echo -e "  ${GREEN}[x]${NC} ${item}"
        done
        echo ""
    fi

    if [[ ${#SKIPPED_ITEMS[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Skipped (${#SKIPPED_ITEMS[@]} items):${NC}"
        for item in ${SKIPPED_ITEMS[@]+"${SKIPPED_ITEMS[@]}"}; do
            echo -e "  ${YELLOW}[-]${NC} ${item}"
        done
        echo ""
    fi

    if [[ ${#FAILED_ITEMS[@]} -gt 0 ]]; then
        echo -e "${RED}Failed (${#FAILED_ITEMS[@]} items):${NC}"
        for item in ${FAILED_ITEMS[@]+"${FAILED_ITEMS[@]}"}; do
            echo -e "  ${RED}[!]${NC} ${item}"
        done
        echo ""
    fi

    echo "============================================"
    echo ""

    if [[ ${#FAILED_ITEMS[@]} -eq 0 ]]; then
        log_info "Bifrost has been completely uninstalled."
    else
        log_warn "Uninstall completed with ${#FAILED_ITEMS[@]} failure(s). Check items above."
    fi

    echo ""
    log_info "Post-uninstall notes:"
    log_info "  - Docker daemon was NOT removed (may be used by other services)"
    log_info "  - System packages (curl, wget, jq, etc.) were NOT removed"
    log_info "  - fail2ban package was NOT removed (only custom configs were removed)"
    log_info "  - You may want to reboot the server to clear all state"
    echo ""
}

###############################################################################
# Main orchestration
# Also exported as uninstall_all() for use when sourced by install.sh
###############################################################################
uninstall_all() {
    # Require root
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "This script must be run as root."
        exit 1
    fi

    echo ""
    echo -e "${BLUE}${BOLD}Bifrost - Uninstall Script${NC}"
    echo ""

    # Triple confirmation
    confirm_uninstall

    # Execute uninstall steps
    stop_services
    echo ""
    remove_docker_resources
    echo ""
    remove_packages
    echo ""
    remove_configs
    echo ""
    remove_logs
    echo ""
    remove_cron_jobs
    echo ""
    restore_ssh_config
    echo ""
    restore_firewall
    echo ""

    # Print summary
    print_summary
}

# Run uninstall_all if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    uninstall_all "$@"
fi
