#!/usr/bin/env bash
# ==============================================================================
# AI Gateway Bridge - Server Security Hardening Module
# ==============================================================================
# This script is sourced by install.sh and provides functions for:
#   - SSH hardening
#   - Firewall setup (ufw / firewalld)
#   - fail2ban deployment
#   - Port auditing
#   - Kernel hardening (sysctl)
#   - Automatic security updates
#   - Security tool installation (rkhunter, Lynis)
#   - Security audit execution
#   - Full security hardening orchestration
#
# All functions are idempotent — safe to run multiple times.
# ==============================================================================

set -euo pipefail

# Guard against double-sourcing (readonly variables would conflict)
if [[ -n "${_SECURITY_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
readonly _SECURITY_SH_LOADED=1

# Source shared utilities (colors, logging, OS detection, helpers)
# Use BASH_SOURCE[0] instead of $0 to work correctly when sourced by install.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ==============================================================================
# Global State
# ==============================================================================

# Persistent state file for cross-function data sharing (e.g., custom SSH port)
: "${SECURITY_STATE_DIR:=/etc/ai-gateway-bridge}"
: "${SECURITY_STATE_FILE:=${SECURITY_STATE_DIR}/.security-state}"
: "${LYNIS_LOG_DIR:=/var/log}"
: "${LYNIS_REPORT_FILE:=${LYNIS_LOG_DIR}/lynis-report.txt}"
: "${LYNIS_DATA_FILE:=${LYNIS_LOG_DIR}/lynis-report.dat}"
: "${LYNIS_CRON_FILE:=/etc/cron.monthly/lynis-audit}"
: "${SSHD_CONFIG_PATH:=/etc/ssh/sshd_config}"
: "${SSH_ADMIN_DIR:=/root/.ssh}"
: "${SSH_AUTHORIZED_KEYS_FILE:=${SSH_ADMIN_DIR}/authorized_keys}"
: "${SSHD_BACKUP_DIR:=$(dirname "${SSHD_CONFIG_PATH}")}"
: "${FAIL2BAN_FILTER_DIR:=/etc/fail2ban/filter.d}"
: "${FAIL2BAN_JAIL_FILE:=/etc/fail2ban/jail.local}"
: "${FAIL2BAN_SERVICE_NAME:=fail2ban}"
: "${AUTO_UPGRADES_CONFIG_FILE:=/etc/apt/apt.conf.d/50unattended-upgrades}"
: "${AUTO_UPGRADES_PERIODIC_FILE:=/etc/apt/apt.conf.d/20auto-upgrades}"
: "${DNF_AUTOMATIC_CONFIG_FILE:=/etc/dnf/automatic.conf}"
: "${DNF_AUTOMATIC_TIMER_NAME:=dnf-automatic.timer}"
: "${RKHUNTER_CONF_FILE:=/etc/rkhunter.conf}"
: "${RKHUNTER_CRON_FILE:=/etc/cron.weekly/rkhunter-scan}"
: "${SYSCTL_HARDENING_CONF_FILE:=/etc/sysctl.d/99-ai-gateway-hardening.conf}"

# ------------------------------------------------------------------------------
# _ensure_state_dir: Create the state directory if it does not exist
# ------------------------------------------------------------------------------
_ensure_state_dir() {
    if [[ ! -d "${SECURITY_STATE_DIR}" ]]; then
        mkdir -p "${SECURITY_STATE_DIR}"
        chmod 700 "${SECURITY_STATE_DIR}"
    fi
}

# ------------------------------------------------------------------------------
# _save_state: Persist a key=value pair to the state file
# Arguments:
#   $1 - key name
#   $2 - value
# ------------------------------------------------------------------------------
_save_state() {
    local key="$1"
    local value="$2"
    _ensure_state_dir

    if [[ -f "${SECURITY_STATE_FILE}" ]]; then
        # Remove existing key (idempotent update)
        sed -i "/^${key}=/d" "${SECURITY_STATE_FILE}"
    fi
    echo "${key}=${value}" >> "${SECURITY_STATE_FILE}"
    chmod 600 "${SECURITY_STATE_FILE}"
}

# ------------------------------------------------------------------------------
# _load_state: Read a value by key from the state file
# Arguments:
#   $1 - key name
# Returns: the value via stdout, empty string if not found
# ------------------------------------------------------------------------------
_load_state() {
    local key="$1"
    if [[ -f "${SECURITY_STATE_FILE}" ]]; then
        grep "^${key}=" "${SECURITY_STATE_FILE}" 2>/dev/null | head -1 | cut -d'=' -f2-
    fi
}

# ------------------------------------------------------------------------------
# _get_ssh_port: Resolve the SSH port from state, sshd_config, or default 22
# Returns: port number via stdout
# ------------------------------------------------------------------------------
_get_ssh_port() {
    local port
    port="$(_load_state "SSH_PORT")"
    if [[ -z "${port}" ]]; then
        # Try to read from current sshd_config
        port=$(grep -E "^Port\s+" "${SSHD_CONFIG_PATH}" 2>/dev/null | awk '{print $2}' | head -1)
    fi
    echo "${port:-22}"
}

# ------------------------------------------------------------------------------
# _detect_firewall: Detect which firewall manager is available
# Returns: "ufw" | "firewalld" | "none" via stdout
# ------------------------------------------------------------------------------
_detect_firewall() {
    if command -v ufw &>/dev/null; then
        echo "ufw"
    elif command -v firewall-cmd &>/dev/null; then
        echo "firewalld"
    else
        echo "none"
    fi
}

# ------------------------------------------------------------------------------
# _generate_random_port: Generate a random high port in range [10000, 65000]
# Returns: port number via stdout
# ------------------------------------------------------------------------------
_generate_random_port() {
    local min=10000
    local max=65000
    local range=$((max - min + 1))
    local port
    port=$((RANDOM % range + min))
    # Ensure not in use
    while ss -tlnp 2>/dev/null | grep -q ":${port} "; do
        port=$((RANDOM % range + min))
    done
    echo "${port}"
}

# ------------------------------------------------------------------------------
# _set_sshd_option: Set or update a single sshd_config option idempotently
# Arguments:
#   $1 - option name (e.g., PasswordAuthentication)
#   $2 - option value (e.g., no)
#   $3 - config file path (default: /etc/ssh/sshd_config)
# ------------------------------------------------------------------------------
_set_sshd_option() {
    local option="$1"
    local value="$2"
    local config="${3:-${SSHD_CONFIG_PATH}}"

    if grep -qE "^\s*#?\s*${option}\s+" "${config}"; then
        # Option exists (possibly commented) — replace it
        sed -i "s/^\s*#*\s*${option}\s.*/${option} ${value}/" "${config}"
    else
        # Option does not exist — append it
        echo "${option} ${value}" >> "${config}"
    fi
}

# ==============================================================================
# 1. harden_ssh
# ==============================================================================
# ------------------------------------------------------------------------------
# _open_ssh_port_in_firewall: Open the new SSH port and keep the old one alive
# until the operator confirms the new port works.
# Arguments:
#   $1 - firewall type
#   $2 - new SSH port
#   $3 - current SSH port
# ------------------------------------------------------------------------------
_open_ssh_port_in_firewall() {
    local fw_type="$1"
    local ssh_port="$2"
    local current_port="$3"

    case "${fw_type}" in
        ufw)
            ufw allow "${ssh_port}/tcp" comment "SSH (hardened)" || {
                log_error "Failed to open new SSH port ${ssh_port}/tcp in ufw."
                return 1
            }
            if [[ "${current_port}" != "${ssh_port}" ]]; then
                ufw allow "${current_port}/tcp" comment "SSH (old - remove after verification)" || {
                    log_error "Failed to keep old SSH port ${current_port}/tcp open in ufw during cutover."
                    return 1
                }
            fi
            ;;
        firewalld)
            firewall-cmd --permanent --add-port="${ssh_port}/tcp" || {
                log_error "Failed to open new SSH port ${ssh_port}/tcp in firewalld."
                return 1
            }
            if [[ "${current_port}" != "${ssh_port}" ]]; then
                firewall-cmd --permanent --add-port="${current_port}/tcp" || {
                    log_error "Failed to keep old SSH port ${current_port}/tcp open in firewalld during cutover."
                    return 1
                }
            fi
            firewall-cmd --reload || {
                log_error "Failed to reload firewalld after opening SSH ports."
                return 1
            }
            ;;
        none)
            log_warn "No firewall detected. Ensure port ${ssh_port} is accessible via your cloud provider's security group."
            ;;
        *)
            log_error "Unsupported firewall type: ${fw_type}"
            return 1
            ;;
    esac

    return 0
}

# ------------------------------------------------------------------------------
# _restart_ssh_service: Restart the active SSH daemon and require the restart to
# succeed for the same service that will be checked afterward.
# ------------------------------------------------------------------------------
_restart_ssh_service() {
    local ssh_service=""

    if systemctl is-active --quiet sshd 2>/dev/null; then
        ssh_service="sshd"
        systemctl restart sshd || {
            log_error "Failed to restart sshd service."
            return 1
        }
    elif systemctl is-active --quiet ssh 2>/dev/null; then
        ssh_service="ssh"
        systemctl restart ssh || {
            log_error "Failed to restart ssh service."
            return 1
        }
    else
        log_warn "Could not detect sshd service name. Attempting both 'sshd' and 'ssh'..."
        if systemctl restart sshd 2>/dev/null; then
            ssh_service="sshd"
        elif systemctl restart ssh 2>/dev/null; then
            ssh_service="ssh"
        else
            log_error "Failed to restart SSH daemon. Please restart manually."
            return 1
        fi
    fi

    if ! systemctl is-active --quiet "${ssh_service}" 2>/dev/null; then
        log_error "SSH daemon ${ssh_service} is not active after restart."
        return 1
    fi

    return 0
}

# ------------------------------------------------------------------------------
# _block_port_in_firewall: Block a TCP port and require the firewall action to
# succeed. Used by audit_ports() when the operator explicitly asks to close
# non-whitelisted listeners.
# Arguments:
#   $1 - firewall type
#   $2 - TCP port to block
# ------------------------------------------------------------------------------
_block_port_in_firewall() {
    local fw_type="$1"
    local port="$2"

    case "${fw_type}" in
        ufw)
            ufw deny "${port}/tcp" comment "Blocked by security audit" || {
                log_error "Failed to block port ${port}/tcp via ufw."
                return 1
            }
            ;;
        firewalld)
            firewall-cmd --permanent --zone=public \
                --add-rich-rule="rule family=\"ipv4\" port port=\"${port}\" protocol=\"tcp\" reject" || {
                log_error "Failed to block port ${port}/tcp via firewalld."
                return 1
            }
            ;;
        none)
            log_error "No firewall available to block port ${port}."
            return 1
            ;;
        *)
            log_error "Unsupported firewall type for port blocking: ${fw_type}"
            return 1
            ;;
    esac

    return 0
}

# ------------------------------------------------------------------------------
# _run_firewall_step: Execute a firewall-related command and require success.
# Arguments:
#   $1 - error message to log on failure
#   $@ - command to execute
# ------------------------------------------------------------------------------
_run_firewall_step() {
    local error_message="$1"
    shift

    "$@" || {
        log_error "${error_message}"
        return 1
    }

    return 0
}

# ------------------------------------------------------------------------------
# _run_checked_step: Execute a command and require success.
# Arguments:
#   $1 - error message to log on failure
#   $@ - command to execute
# ------------------------------------------------------------------------------
_run_checked_step() {
    local error_message="$1"
    shift

    "$@" || {
        log_error "${error_message}"
        return 1
    }

    return 0
}

# ==============================================================================
# 1. harden_ssh
# ==============================================================================
# Hardens the SSH daemon configuration:
#   - Backs up sshd_config
#   - Prompts for custom port
#   - Prompts for SSH public key
#   - Applies strict security settings
#   - Validates config before applying
#   - Opens new port in firewall BEFORE restarting sshd
#   - Restarts sshd
# ==============================================================================
harden_ssh() {
    log_info "=========================================="
    log_info "SSH Hardening"
    log_info "=========================================="

    local sshd_config="${SSHD_CONFIG_PATH}"
    local backup_file="${SSHD_BACKUP_DIR}/sshd_config.bak.$(date +%Y%m%d%H%M%S)"

    # ---- Prerequisite checks ----
    if [[ ! -f "${sshd_config}" ]]; then
        log_error "sshd_config not found at ${sshd_config}. Is OpenSSH server installed?"
        return 1
    fi

    # ---- Backup ----
    cp -p "${sshd_config}" "${backup_file}"
    log_info "Backup created: ${backup_file}"

    # ---- Ask for SSH port ----
    local default_port
    default_port="$(_generate_random_port)"
    local current_port
    current_port="$(_get_ssh_port)"

    log_info "Current SSH port: ${current_port}"
    read -rp "$(echo -e "${COLOR_YELLOW}Enter new SSH port [default: ${default_port}]:${COLOR_RESET} ")" user_port
    local ssh_port="${user_port:-${default_port}}"

    # Validate port range
    if ! [[ "${ssh_port}" =~ ^[0-9]+$ ]] || (( ssh_port < 1 || ssh_port > 65535 )); then
        log_error "Invalid port number: ${ssh_port}. Must be 1-65535."
        return 1
    fi

    log_info "SSH port will be set to: ${ssh_port}"
    _save_state "SSH_PORT" "${ssh_port}"

    # ---- Ask for SSH public key ----
    local authorized_keys_file="${SSH_AUTHORIZED_KEYS_FILE}"
    local ssh_dir="${SSH_ADMIN_DIR}"

    if [[ -f "${authorized_keys_file}" ]] && [[ -s "${authorized_keys_file}" ]]; then
        log_info "Existing authorized_keys found with the following keys:"
        while IFS= read -r line; do
            # Display key type + comment (last two fields) for readability
            if [[ -n "${line}" ]] && [[ "${line}" != \#* ]]; then
                local key_type key_comment
                key_type=$(echo "${line}" | awk '{print $1}')
                key_comment=$(echo "${line}" | awk '{print $NF}')
                log_info "  - ${key_type} ...${key_comment}"
            fi
        done < "${authorized_keys_file}"

        read -rp "$(echo -e "${COLOR_YELLOW}Do you want to add another SSH public key? [y/N]:${COLOR_RESET} ")" add_key
    else
        log_warn "No existing SSH keys found. You MUST add a public key since password authentication will be disabled."
        add_key="y"
    fi

    if [[ "${add_key,,}" == "y" || "${add_key,,}" == "yes" ]]; then
        log_info "Paste your SSH public key (starts with ssh-rsa, ssh-ed25519, ecdsa-sha2, etc.):"
        read -rp "> " ssh_pubkey

        if [[ -z "${ssh_pubkey}" ]]; then
            log_error "No key provided. Cannot proceed with password authentication disabled and no authorized key."
            log_info "Restoring backup: ${backup_file}"
            cp -p "${backup_file}" "${sshd_config}"
            return 1
        fi

        # Validate basic key format
        if ! echo "${ssh_pubkey}" | grep -qE "^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp|sk-ssh-ed25519|sk-ecdsa-sha2) "; then
            log_error "Invalid SSH public key format. Key must start with a valid key type prefix."
            log_info "Restoring backup: ${backup_file}"
            cp -p "${backup_file}" "${sshd_config}"
            return 1
        fi

        # Install the key
        mkdir -p "${ssh_dir}"
        chmod 700 "${ssh_dir}"

        # Avoid duplicates
        if [[ -f "${authorized_keys_file}" ]] && grep -qF "${ssh_pubkey}" "${authorized_keys_file}"; then
            log_info "Key already present in authorized_keys. Skipping."
        else
            echo "${ssh_pubkey}" >> "${authorized_keys_file}"
            chmod 600 "${authorized_keys_file}"
            log_info "SSH public key added to ${authorized_keys_file}"
        fi
    fi

    # ---- Final safety check: ensure at least one key exists before disabling passwords ----
    if [[ ! -f "${authorized_keys_file}" ]] || [[ ! -s "${authorized_keys_file}" ]]; then
        log_error "CRITICAL: No SSH keys found in ${authorized_keys_file}."
        log_error "Refusing to disable password authentication — you would be locked out."
        log_info "Restoring backup: ${backup_file}"
        cp -p "${backup_file}" "${sshd_config}"
        return 1
    fi

    # ---- Apply SSH configuration ----
    log_info "Applying SSH hardening settings..."

    _set_sshd_option "Port" "${ssh_port}"
    _set_sshd_option "PasswordAuthentication" "no"
    _set_sshd_option "PermitRootLogin" "prohibit-password"
    _set_sshd_option "PubkeyAuthentication" "yes"
    _set_sshd_option "KbdInteractiveAuthentication" "no"
    _set_sshd_option "ChallengeResponseAuthentication" "no"
    _set_sshd_option "AuthenticationMethods" "publickey"
    _set_sshd_option "MaxAuthTries" "3"
    _set_sshd_option "LoginGraceTime" "30"
    _set_sshd_option "X11Forwarding" "no"
    _set_sshd_option "AllowAgentForwarding" "no"
    _set_sshd_option "ClientAliveInterval" "300"
    _set_sshd_option "ClientAliveCountMax" "2"

    # ---- Validate configuration ----
    log_info "Validating sshd configuration..."
    if ! sshd -t -f "${sshd_config}"; then
        log_error "sshd configuration validation FAILED. Restoring backup."
        cp -p "${backup_file}" "${sshd_config}"
        return 1
    fi
    log_info "sshd configuration validation passed."

    # ---- Open new port in firewall BEFORE restarting sshd (CRITICAL SAFETY STEP) ----
    log_info "Opening SSH port ${ssh_port} in firewall before restarting sshd..."
    local fw_type
    fw_type="$(_detect_firewall)"
    if ! _open_ssh_port_in_firewall "${fw_type}" "${ssh_port}" "${current_port}"; then
        log_error "Firewall update failed before SSH restart. Restoring backup to avoid lockout."
        cp -p "${backup_file}" "${sshd_config}"
        return 1
    fi

    # ---- Create safety revert cron (auto-reverts SSH config if no new connection in 5 minutes) ----
    if [[ "${current_port}" != "${ssh_port}" ]]; then
        local revert_script="/tmp/ssh-revert-safety.sh"
        local revert_marker="/tmp/ssh-port-change-confirmed"
        rm -f "${revert_marker}" 2>/dev/null

        cat > "${revert_script}" <<REVERT_EOF
#!/usr/bin/env bash
# SSH Port Change Safety Revert Script
# This script automatically reverts the SSH port change if no confirmation is received
# within 5 minutes. It is a safety net against SSH lockout.

BACKUP_FILE="${backup_file}"
SSHD_CONFIG="${sshd_config}"
MARKER="${revert_marker}"

# Wait 5 minutes for confirmation
sleep 300

# If marker file exists, the user confirmed the new port works
if [[ -f "\${MARKER}" ]]; then
    rm -f "\${MARKER}" "\$0"
    exit 0
fi

# No confirmation received - revert!
echo "[SSH SAFETY] No confirmation received after 5 minutes. Reverting SSH config..."
if ! cp -p "\${BACKUP_FILE}" "\${SSHD_CONFIG}"; then
    echo "[SSH SAFETY] Failed to restore SSH config backup." >&2
    exit 1
fi

if systemctl restart sshd 2>/dev/null; then
    :
elif systemctl restart ssh 2>/dev/null; then
    :
else
    echo "[SSH SAFETY] Failed to restart SSH daemon after revert. Manual recovery required." >&2
    exit 1
fi
echo "[SSH SAFETY] SSH config reverted to backup. Old port ${current_port} should be active again."
rm -f "\$0"
REVERT_EOF
        chmod +x "${revert_script}"

        # Run the revert script in background
        nohup bash "${revert_script}" &>/dev/null &
        local revert_pid=$!
        log_info "Safety revert timer started (PID: ${revert_pid}). Will auto-revert in 5 minutes if not confirmed."
    fi

    # ---- Restart sshd ----
    log_info "Restarting sshd..."
    if ! _restart_ssh_service; then
        log_error "Failed to restart SSH daemon after applying hardened config. Restoring backup."
        cp -p "${backup_file}" "${sshd_config}"
        if ! _restart_ssh_service; then
            log_error "Failed to restart SSH daemon even after restoring backup. Please recover manually."
        fi
        return 1
    fi
    log_info "sshd restarted successfully on port ${ssh_port}."

    # ---- Print critical warning ----
    echo ""
    log_warn "============================================================================"
    log_warn "IMPORTANT: Test new SSH connection in a SEPARATE terminal before closing"
    log_warn "this session!"
    log_warn ""
    log_warn "  ssh -p ${ssh_port} root@<your-server-ip>"
    log_warn ""
    if [[ "${current_port}" != "${ssh_port}" ]]; then
        log_warn "SAFETY NET: SSH config will AUTO-REVERT in 5 minutes if not confirmed."
        log_warn "Once you verify the new port works, run this to confirm:"
        log_warn "  touch ${revert_marker}"
        log_warn ""
    fi
    log_warn "Manual revert if needed:"
    log_warn "  cp ${backup_file} ${sshd_config} && systemctl restart sshd"
    log_warn "============================================================================"
    echo ""

    log_info "SSH hardening complete."
}

# ==============================================================================
# 2. setup_firewall
# ==============================================================================
# Configures the system firewall:
#   - Detects ufw vs firewalld
#   - Sets default deny incoming, allow outgoing
#   - Opens required ports: SSH (custom), 443, 80, 19999 (localhost only)
#   - Enables the firewall
#   - Logs all rules applied
# ==============================================================================
setup_firewall() {
    log_info "=========================================="
    log_info "Firewall Setup"
    log_info "=========================================="

    local ssh_port
    ssh_port="$(_get_ssh_port)"
    local fw_type
    bifrost_env_load
    fw_type="${BIFROST_FIREWALL_BACKEND:-}"
    if [[ -z "${fw_type}" ]]; then
        fw_type="$(bifrost_env_get BIFROST_FIREWALL_BACKEND 2>/dev/null || true)"
    fi
    if [[ -z "${fw_type}" ]]; then
        fw_type="$(_detect_firewall)"
    fi

    log_info "Detected firewall: ${fw_type}"
    log_info "SSH port: ${ssh_port}"

    case "${fw_type}" in
        nftables)
            _setup_firewall_nftables "${ssh_port}" || return 1
            ;;
        ufw)
            _setup_firewall_ufw "${ssh_port}" || return 1
            ;;
        firewalld)
            _setup_firewall_firewalld "${ssh_port}" || return 1
            ;;
        none)
            log_warn "No firewall package detected. Installing ufw..."
            if command -v apt-get &>/dev/null; then
                _run_firewall_step "Failed to update apt package index while installing ufw." apt-get update -qq || return 1
                _run_firewall_step "Failed to install ufw." apt-get install -y -qq ufw || return 1
            elif command -v dnf &>/dev/null; then
                _run_firewall_step "Failed to install firewalld via dnf." dnf install -y -q firewalld || return 1
                _run_firewall_step "Failed to start firewalld after installation." systemctl enable --now firewalld || return 1
                _setup_firewall_firewalld "${ssh_port}" || return 1
                return 0
            elif command -v yum &>/dev/null; then
                _run_firewall_step "Failed to install firewalld via yum." yum install -y -q firewalld || return 1
                _run_firewall_step "Failed to start firewalld after installation." systemctl enable --now firewalld || return 1
                _setup_firewall_firewalld "${ssh_port}" || return 1
                return 0
            else
                log_error "Cannot install firewall. Unsupported package manager."
                return 1
            fi
            _setup_firewall_ufw "${ssh_port}" || return 1
            ;;
    esac

    log_info "Firewall setup complete."
    return 0
}

# ------------------------------------------------------------------------------
# _setup_firewall_ufw: Configure ufw
# Arguments:
#   $1 - SSH port
# ------------------------------------------------------------------------------
_setup_firewall_ufw() {
    local ssh_port="$1"

    log_info "[ufw] Resetting to defaults..."
    # Ensure ufw is not active during reset to avoid dropping our session
    _run_firewall_step "Failed to reset ufw to defaults." ufw --force reset || return 1

    log_info "[ufw] Setting default policies: deny incoming, allow outgoing"
    _run_firewall_step "Failed to set ufw default incoming policy to deny." ufw default deny incoming || return 1
    _run_firewall_step "Failed to set ufw default outgoing policy to allow." ufw default allow outgoing || return 1

    log_info "[ufw] Allowing SSH on port ${ssh_port}/tcp"
    _run_firewall_step "Failed to allow SSH port ${ssh_port}/tcp in ufw." ufw allow "${ssh_port}/tcp" comment "SSH" || return 1

    local exposure_profile
    exposure_profile="$(bifrost_exposure_profile)" || exposure_profile="vpn-first"
    if [[ "${exposure_profile}" == "public-managed" || "${exposure_profile}" == "lab" ]]; then
        log_info "[ufw] Allowing HTTPS (443/tcp) [profile=${exposure_profile}]"
        _run_firewall_step "Failed to allow HTTPS in ufw." ufw allow 443/tcp comment "HTTPS (${exposure_profile})" || return 1

        log_info "[ufw] Allowing HTTP (80/tcp) for certificate issuance [profile=${exposure_profile}]"
        _run_firewall_step "Failed to allow HTTP in ufw." ufw allow 80/tcp comment "HTTP (cert/${exposure_profile})" || return 1
    else
        log_info "[ufw] vpn-first profile: NOT opening 80/443 to public; Caddy binds to wg0 only"
    fi

    # Netdata — restrict to localhost by default; admin can add specific IPs later
    log_info "[ufw] Allowing Netdata (19999/tcp) on localhost only"
    _run_firewall_step "Failed to restrict Netdata to localhost in ufw (IPv4)." \
        ufw allow from 127.0.0.1 to any port 19999 proto tcp comment "Netdata (localhost)" || return 1
    _run_firewall_step "Failed to restrict Netdata to localhost in ufw (IPv6)." \
        ufw allow from ::1 to any port 19999 proto tcp comment "Netdata (localhost IPv6)" || return 1

    # WireGuard VPN port — required for enterprise VPN (deployed in later step).
    # Must be opened here so VPN deployment does not need to disable ufw.
    bifrost_env_load
    local wg_port="${BIFROST_WG_PORT:-51820}"
    log_info "[ufw] Allowing WireGuard (${wg_port}/udp)"
    _run_firewall_step "Failed to allow WireGuard port ${wg_port}/udp in ufw." ufw allow "${wg_port}/udp" comment "WireGuard VPN" || return 1

    # NOTE: Xray proxy ports (10808 SOCKS5, 10809 HTTP) are NOT opened here.
    # They are protected by the default deny incoming policy.
    # Port 10809 listens on 0.0.0.0 to allow Docker container access via
    # host.docker.internal, but the firewall blocks external access.
    # Do NOT add explicit deny rules for these ports as it would break
    # Docker container connectivity through iptables DOCKER chains.

    # Enable ufw non-interactively
    log_info "[ufw] Enabling firewall..."
    _run_firewall_step "Failed to enable ufw." ufw --force enable || return 1

    log_info "[ufw] Current rules:"
    _run_firewall_step "Failed to inspect current ufw rules." ufw status verbose || return 1
    _save_state "FIREWALL_TYPE" "ufw" || {
        log_error "Failed to persist firewall type state for ufw."
        return 1
    }

    return 0
}

# ------------------------------------------------------------------------------
# _setup_firewall_firewalld: Configure firewalld
# Arguments:
#   $1 - SSH port
# ------------------------------------------------------------------------------
_setup_firewall_firewalld() {
    local ssh_port="$1"

    log_info "[firewalld] Ensuring service is running..."
    _run_firewall_step "Failed to start or enable firewalld." systemctl enable --now firewalld || return 1

    local zone="public"

    log_info "[firewalld] Setting default zone to ${zone}"
    _run_firewall_step "Failed to set firewalld default zone to ${zone}." firewall-cmd --set-default-zone="${zone}" || return 1

    # Remove default SSH service (port 22) — we use a custom port
    log_info "[firewalld] Removing default SSH service..."
    if firewall-cmd --permanent --zone="${zone}" --query-service=ssh >/dev/null 2>&1; then
        _run_firewall_step "Failed to remove default SSH service from firewalld." \
            firewall-cmd --permanent --zone="${zone}" --remove-service=ssh || return 1
    else
        log_info "[firewalld] Default SSH service already absent in zone ${zone}"
    fi

    log_info "[firewalld] Allowing SSH on port ${ssh_port}/tcp"
    _run_firewall_step "Failed to allow SSH port ${ssh_port}/tcp in firewalld." \
        firewall-cmd --permanent --zone="${zone}" --add-port="${ssh_port}/tcp" || return 1

    local exposure_profile
    exposure_profile="$(bifrost_exposure_profile)" || exposure_profile="vpn-first"
    if [[ "${exposure_profile}" == "public-managed" || "${exposure_profile}" == "lab" ]]; then
        log_info "[firewalld] Allowing HTTPS (443/tcp) [profile=${exposure_profile}]"
        _run_firewall_step "Failed to allow HTTPS in firewalld." \
            firewall-cmd --permanent --zone="${zone}" --add-service=https || return 1

        log_info "[firewalld] Allowing HTTP (80/tcp) for certificate issuance [profile=${exposure_profile}]"
        _run_firewall_step "Failed to allow HTTP in firewalld." \
            firewall-cmd --permanent --zone="${zone}" --add-service=http || return 1
    else
        log_info "[firewalld] vpn-first profile: NOT opening 80/443 to public; Caddy binds to wg0 only"
    fi

    # Netdata — use rich rule to restrict to localhost
    log_info "[firewalld] Allowing Netdata (19999/tcp) on localhost only"
    _run_firewall_step "Failed to restrict Netdata to localhost in firewalld." \
        firewall-cmd --permanent --zone="${zone}" \
        --add-rich-rule='rule family="ipv4" source address="127.0.0.1" port port="19999" protocol="tcp" accept' || return 1

    # WireGuard VPN port — required for enterprise VPN (deployed in later step)
    bifrost_env_load
    local wg_port="${BIFROST_WG_PORT:-51820}"
    log_info "[firewalld] Allowing WireGuard (${wg_port}/udp)"
    _run_firewall_step "Failed to allow WireGuard port ${wg_port}/udp in firewalld." \
        firewall-cmd --permanent --zone="${zone}" --add-port="${wg_port}/udp" || return 1

    # Set default target to DROP for incoming connections not matching any rule
    log_info "[firewalld] Setting default target to DROP"
    _run_firewall_step "Failed to set firewalld default target to DROP." \
        firewall-cmd --permanent --zone="${zone}" --set-target=DROP || return 1

    log_info "[firewalld] Reloading rules..."
    _run_firewall_step "Failed to reload firewalld rules." firewall-cmd --reload || return 1

    log_info "[firewalld] Current rules:"
    _run_firewall_step "Failed to inspect current firewalld rules." firewall-cmd --zone="${zone}" --list-all || return 1
    _save_state "FIREWALL_TYPE" "firewalld" || {
        log_error "Failed to persist firewall type state for firewalld."
        return 1
    }

    return 0
}

_setup_firewall_nftables() {
    local ssh_port="$1"

    bifrost_env_load
    local wg_port="${BIFROST_WG_PORT:-51820}"
    local admin_ranges="${BIFROST_ADMIN_ALLOWED_RANGES:-${BIFROST_ADMIN_ALLOWED_CIDRS:-}}"
    if [[ -z "${admin_ranges}" ]]; then
        log_error "[nftables] BIFROST_ADMIN_ALLOWED_RANGES is required for strict mode"
        return 1
    fi

    log_info "[nftables] Installing nftables package..."
    if command -v apt-get >/dev/null 2>&1; then
        _run_firewall_step "Failed to install nftables." apt-get install -y nftables || return 1
    elif command -v dnf >/dev/null 2>&1; then
        _run_firewall_step "Failed to install nftables." dnf install -y nftables || return 1
    elif command -v yum >/dev/null 2>&1; then
        _run_firewall_step "Failed to install nftables." yum install -y nftables || return 1
    fi

    local tpl="${PROJECT_ROOT}/configs/nftables/nftables-a-strict.conf.tpl"
    local out="/etc/nftables.conf"
    if [[ ! -f "${tpl}" ]]; then
        log_error "[nftables] template not found: ${tpl}"
        return 1
    fi

    log_info "[nftables] Rendering strict Server A ruleset..."
    sed -e "s|{{SSH_PORT}}|${ssh_port}|g" \
        -e "s|{{WG_PORT}}|${wg_port}|g" \
        -e "s|{{ADMIN_RANGES}}|${admin_ranges}|g" \
        "${tpl}" > "${out}"
    chmod 600 "${out}"

    log_info "[nftables] Validating ruleset..."
    if ! nft -c -f "${out}"; then
        log_error "[nftables] ruleset validation failed"
        return 1
    fi

    _run_firewall_step "Failed to enable nftables." systemctl enable --now nftables || return 1
    _run_firewall_step "Failed to apply nftables ruleset." systemctl restart nftables || return 1
    _save_state "FIREWALL_TYPE" "nftables" || return 1
}

# ==============================================================================
# 3. setup_fail2ban
# ==============================================================================
# Deploys and configures fail2ban:
#   - Installs fail2ban if not present
#   - Creates /etc/fail2ban/jail.local with SSH and Caddy jails
#   - Creates custom Caddy auth failure filter
#   - Enables and starts fail2ban
#   - Displays status
# ==============================================================================
setup_fail2ban() {
    log_info "=========================================="
    log_info "fail2ban Setup"
    log_info "=========================================="

    # ---- Install fail2ban ----
    if ! command -v fail2ban-client &>/dev/null; then
        log_info "Installing fail2ban..."
        if command -v apt-get &>/dev/null; then
            _run_checked_step "Failed to update apt package index while installing fail2ban." apt-get update -qq || return 1
            _run_checked_step "Failed to install fail2ban via apt-get." apt-get install -y -qq fail2ban || return 1
        elif command -v dnf &>/dev/null; then
            _run_checked_step "Failed to install fail2ban via dnf." dnf install -y -q fail2ban || return 1
        elif command -v yum &>/dev/null; then
            _run_checked_step "Failed to install fail2ban via yum." yum install -y -q fail2ban || return 1
        else
            log_error "Cannot install fail2ban. Unsupported package manager."
            return 1
        fi
    else
        log_info "fail2ban already installed."
    fi

    local ssh_port
    ssh_port="$(_get_ssh_port)"
    local exposure_profile
    exposure_profile="$(bifrost_exposure_profile)" || exposure_profile="vpn-first"
    local caddy_jails_enabled="false"
    if [[ "${exposure_profile}" != "vpn-first" ]]; then
        caddy_jails_enabled="true"
    fi

    # ---- Create Caddy auth failure filter ----
    local caddy_filter_dir="${FAIL2BAN_FILTER_DIR}"
    local caddy_filter_file="${caddy_filter_dir}/caddy-auth.conf"

    log_info "Creating Caddy auth failure filter: ${caddy_filter_file}"
    mkdir -p "${caddy_filter_dir}" || {
        log_error "Failed to create fail2ban filter directory: ${caddy_filter_dir}"
        return 1
    }
    if ! cat > "${caddy_filter_file}" << 'FILTER_EOF'
# fail2ban filter for Caddy authentication failures
# Matches HTTP 401/403 responses in Caddy's JSON access log format
[Definition]

# Caddy JSON log format: {"request":{"remote_ip":"x.x.x.x",...},"status":401,...}
failregex = ^.*"remote_ip"\s*:\s*"<HOST>".*"status"\s*:\s*(?:401|403).*$
            ^.*"status"\s*:\s*(?:401|403).*"remote_ip"\s*:\s*"<HOST>".*$

# Caddy common log format fallback
            ^<HOST> - - \[.*\] ".*" (?:401|403) .*$

ignoreregex =
FILTER_EOF
    then
        log_error "Failed to write fail2ban filter: ${caddy_filter_file}"
        return 1
    fi

    # ---- Create Caddy bot search filter ----
    local botsearch_filter_file="${caddy_filter_dir}/caddy-botsearch.conf"

    log_info "Creating Caddy bot search filter: ${botsearch_filter_file}"
    if ! cat > "${botsearch_filter_file}" << 'BOTSEARCH_EOF'
# fail2ban filter for Caddy vulnerability scanners and bots
# Matches requests probing for common exploit paths
[Definition]

# Match requests for known scanner/exploit paths in Caddy JSON log
failregex = ^.*"remote_ip"\s*:\s*"<HOST>".*"uri"\s*:\s*"(?:/wp-login|/wp-admin|/xmlrpc|/\.env|/\.git|/phpmyadmin|/admin|/actuator|/solr|/vendor|/telescope|/console|/cgi-bin).*".*$

# Common log format fallback
            ^<HOST> - - \[.*\] "(?:GET|POST|HEAD) (?:/wp-login|/wp-admin|/xmlrpc|/\.env|/\.git|/phpmyadmin|/admin|/actuator|/solr|/vendor|/telescope|/console|/cgi-bin).*" .*$

ignoreregex =
BOTSEARCH_EOF
    then
        log_error "Failed to write fail2ban filter: ${botsearch_filter_file}"
        return 1
    fi

    # ---- Create jail.local ----
    local jail_file="${FAIL2BAN_JAIL_FILE}"

    log_info "Creating fail2ban jail configuration: ${jail_file}"
    mkdir -p "$(dirname "${jail_file}")" || {
        log_error "Failed to create fail2ban jail directory for ${jail_file}"
        return 1
    }
    if ! cat > "${jail_file}" << JAIL_EOF
# AI Gateway Bridge - fail2ban jail configuration
# Generated by security.sh — safe to regenerate (idempotent)

[DEFAULT]
# Ban duration: 1 hour
bantime  = 3600
# Detection window: 10 minutes
findtime = 600
# Max retries before ban
maxretry = 5
# Ban action: use firewall detected on this system
banaction = %(banaction_allports)s

[sshd]
enabled  = true
port     = ${ssh_port}
filter   = sshd
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
# Stricter settings for SSH: 3 attempts, 24-hour ban
maxretry = 3
bantime  = 86400
findtime = 600

[caddy-auth]
enabled  = ${caddy_jails_enabled}
port     = http,https
filter   = caddy-auth
backend  = polling
# Caddy JSON access log — adjust path if Caddy is configured differently
logpath  = /var/log/caddy/access.log
maxretry = 5
bantime  = 3600
findtime = 600

[caddy-botsearch]
enabled  = ${caddy_jails_enabled}
port     = http,https
filter   = caddy-botsearch
backend  = polling
logpath  = /var/log/caddy/access.log
# Stricter: 3 attempts = 24-hour ban for vulnerability scanners
maxretry = 3
bantime  = 86400
findtime = 600

[recidive]
enabled  = true
filter   = recidive
logpath  = /var/log/fail2ban.log
banaction = %(banaction_allports)s
# 7-day ban for repeat offenders
bantime  = 604800
# Look back over the past 24 hours
findtime = 86400
# 5 bans within findtime triggers recidive
maxretry = 5
JAIL_EOF
    then
        log_error "Failed to write fail2ban jail configuration: ${jail_file}"
        return 1
    fi

    # ---- Enable and start fail2ban ----
    log_info "Enabling and starting fail2ban..."
    _run_checked_step "Failed to enable ${FAIL2BAN_SERVICE_NAME} service." systemctl enable "${FAIL2BAN_SERVICE_NAME}" || return 1
    _run_checked_step "Failed to restart ${FAIL2BAN_SERVICE_NAME} service." systemctl restart "${FAIL2BAN_SERVICE_NAME}" || return 1
    if ! systemctl is-active --quiet "${FAIL2BAN_SERVICE_NAME}"; then
        log_error "${FAIL2BAN_SERVICE_NAME} service is not active after restart."
        return 1
    fi

    # Brief pause for jails to initialize
    sleep 2

    # ---- Display status ----
    log_info "fail2ban status:"
    fail2ban-client status || true

    if fail2ban-client status sshd &>/dev/null; then
        log_info "sshd jail status:"
        fail2ban-client status sshd || true
    fi

    log_info "fail2ban setup complete."
}

# ==============================================================================
# 4. audit_ports
# ==============================================================================
# Audits listening ports against a whitelist:
#   - Lists all listening TCP ports via ss
#   - Compares against allowed whitelist
#   - Warns about unexpected ports
#   - Offers to block non-whitelisted ports
# ==============================================================================
audit_ports() {
    log_info "=========================================="
    log_info "Port Security Audit"
    log_info "=========================================="

    local ssh_port
    ssh_port="$(_get_ssh_port)"

    # Define whitelist: SSH (custom), HTTP, HTTPS, and other known service ports
    local -a whitelist_ports=("${ssh_port}" "80" "443" "19999")

    # Load any additional custom ports from state
    local custom_ports
    custom_ports="$(_load_state "CUSTOM_WHITELIST_PORTS")"
    if [[ -n "${custom_ports}" ]]; then
        IFS=',' read -ra extra_ports <<< "${custom_ports}"
        whitelist_ports+=(${extra_ports[@]+"${extra_ports[@]}"})
    fi

    log_info "Whitelisted ports: ${whitelist_ports[*]}"
    log_info ""
    log_info "Current listening TCP ports:"
    echo "------------------------------------------------------------"
    ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || {
        log_error "Neither ss nor netstat available. Cannot audit ports."
        return 1
    }
    echo "------------------------------------------------------------"
    echo ""

    # Parse listening ports
    local -a listening_ports=()
    local -a unknown_ports=()

    while IFS= read -r line; do
        # Extract port from Local Address column (format: *:PORT or 0.0.0.0:PORT or [::]:PORT)
        local local_addr
        local port
        local_addr=$(echo "${line}" | awk '{print $4}')

        # Loopback-only listeners, such as systemd-resolved on 127.0.0.53:53,
        # are not externally exposed and should not be treated as port-audit
        # findings.
        if [[ "${local_addr}" == 127.* || "${local_addr}" == "[::1]:"* || "${local_addr}" == "::1:"* || "${local_addr}" == localhost:* ]]; then
            continue
        fi

        port="${local_addr##*:}"

        # Skip non-numeric
        if ! [[ "${port}" =~ ^[0-9]+$ ]]; then
            continue
        fi

        # Skip duplicates
        local already_found=false
        for p in ${listening_ports[@]+"${listening_ports[@]}"}; do
            if [[ "${p}" == "${port}" ]]; then
                already_found=true
                break
            fi
        done
        if [[ "${already_found}" == "true" ]]; then
            continue
        fi

        listening_ports+=("${port}")

        # Check against whitelist
        local whitelisted=false
        for wp in ${whitelist_ports[@]+"${whitelist_ports[@]}"}; do
            if [[ "${wp}" == "${port}" ]]; then
                whitelisted=true
                break
            fi
        done

        if [[ "${whitelisted}" == "false" ]]; then
            # Get the process name for context
            local proc_info
            proc_info=$(ss -tlnp 2>/dev/null | grep ":${port} " | awk '{print $6}' | head -1)
            unknown_ports+=("${port}|${proc_info}")
        fi
    done < <(ss -tlnp 2>/dev/null | tail -n +2)

    if [[ ${#unknown_ports[@]} -eq 0 ]]; then
        log_info "All listening ports are whitelisted. No issues found."
        return 0
    fi

    # ---- Warn about non-whitelisted ports ----
    log_warn "The following ports are NOT in the whitelist:"
    echo ""
    printf "  %-10s %s\n" "PORT" "PROCESS"
    printf "  %-10s %s\n" "----" "-------"
    for entry in ${unknown_ports[@]+"${unknown_ports[@]}"}; do
        local port="${entry%%|*}"
        local proc="${entry##*|}"
        printf "  %-10s %s\n" "${port}" "${proc:-unknown}"
    done
    echo ""

    # ---- Offer to close non-whitelisted ports ----
    read -rp "$(echo -e "${COLOR_YELLOW}Block these non-whitelisted ports via firewall? [y/N]:${COLOR_RESET} ")" block_choice

    if [[ "${block_choice,,}" == "y" || "${block_choice,,}" == "yes" ]]; then
        local fw_type
        fw_type="$(_detect_firewall)"
        local block_failures=0

        for entry in ${unknown_ports[@]+"${unknown_ports[@]}"}; do
            local port="${entry%%|*}"
            log_info "Blocking port ${port}..."
            if ! _block_port_in_firewall "${fw_type}" "${port}"; then
                block_failures=$((block_failures + 1))
            fi
        done

        if [[ "${fw_type}" == "firewalld" ]]; then
            if ! firewall-cmd --reload; then
                log_error "Failed to reload firewalld after blocking audited ports."
                block_failures=$((block_failures + 1))
            fi
        fi

        if (( block_failures > 0 )); then
            log_error "Failed to block ${block_failures} non-whitelisted port action(s). Review firewall state manually."
            return 1
        fi

        log_info "Non-whitelisted ports have been blocked."
    else
        log_info "Skipping port blocking. Please review manually."
    fi

    log_info "Port audit complete."
}

# ==============================================================================
# 5. harden_kernel
# ==============================================================================
# Applies kernel-level security hardening via sysctl:
#   - Writes /etc/sysctl.d/99-ai-gateway-hardening.conf
#   - Checks BBR kernel support before enabling
#   - Applies settings with sysctl --system
# ==============================================================================
harden_kernel() {
    log_info "=========================================="
    log_info "Kernel Security Hardening"
    log_info "=========================================="

    local sysctl_conf="${SYSCTL_HARDENING_CONF_FILE}"

    # ---- Check BBR support ----
    local bbr_available=false
    if [[ -f /proc/sys/net/ipv4/tcp_congestion_control ]]; then
        local available_algos
        available_algos=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")
        if echo "${available_algos}" | grep -q "bbr"; then
            bbr_available=true
            log_info "BBR congestion control is available in this kernel."
        else
            # Try to load the bbr module
            modprobe tcp_bbr 2>/dev/null || true
            available_algos=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || echo "")
            if echo "${available_algos}" | grep -q "bbr"; then
                bbr_available=true
                log_info "BBR module loaded successfully."
            else
                log_warn "BBR not available in this kernel. Skipping BBR settings."
            fi
        fi
    fi

    # ---- Write sysctl configuration ----
    log_info "Writing kernel hardening configuration: ${sysctl_conf}"

    cat > "${sysctl_conf}" << SYSCTL_EOF
# ==============================================================================
# AI Gateway Bridge - Kernel Security Hardening
# Generated by security.sh — safe to regenerate (idempotent)
# ==============================================================================

# --- TCP SYN flood protection ---
net.ipv4.tcp_syncookies = 1

# --- Reverse path filtering (anti-spoofing) ---
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# --- Disable ICMP redirects (prevent MITM routing attacks) ---
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# --- Disable source routing (prevent IP spoofing) ---
net.ipv4.conf.all.accept_source_route = 0

# --- Ignore broadcast ICMP (prevent smurf attacks) ---
net.ipv4.icmp_echo_ignore_broadcasts = 1

# --- Increase SYN backlog for high-traffic scenarios ---
net.ipv4.tcp_max_syn_backlog = 4096

# --- ASLR (Address Space Layout Randomization) — maximum randomization ---
kernel.randomize_va_space = 2

# --- Protect hardlinks and symlinks against privilege escalation ---
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
SYSCTL_EOF

    # ---- Append BBR settings if supported ----
    if [[ "${bbr_available}" == "true" ]]; then
        cat >> "${sysctl_conf}" << 'BBR_EOF'

# --- BBR congestion control (better throughput and lower latency) ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
BBR_EOF
        log_info "BBR congestion control settings added."
    else
        cat >> "${sysctl_conf}" << 'NOBBR_EOF'

# --- BBR congestion control ---
# BBR is not available on this kernel. To enable:
#   1. Upgrade to kernel >= 4.9
#   2. Run: modprobe tcp_bbr
#   3. Uncomment the lines below and run: sysctl --system
# # net.core.default_qdisc = fq
# # net.ipv4.tcp_congestion_control = bbr
NOBBR_EOF
    fi

    # ---- Apply settings ----
    log_info "Applying kernel parameters..."
    if sysctl --system; then
        log_info "Kernel parameters applied successfully."
    else
        log_error "Failed to apply some kernel parameters. Check dmesg for details."
        return 1
    fi

    # ---- Verify critical settings ----
    log_info "Verifying critical settings:"
    local -a verify_keys=(
        "net.ipv4.tcp_syncookies"
        "net.ipv4.conf.all.rp_filter"
        "kernel.randomize_va_space"
        "fs.protected_hardlinks"
        "fs.protected_symlinks"
    )
    if [[ "${bbr_available}" == "true" ]]; then
        verify_keys+=("net.ipv4.tcp_congestion_control")
    fi

    for key in ${verify_keys[@]+"${verify_keys[@]}"}; do
        local actual_value
        actual_value=$(sysctl -n "${key}" 2>/dev/null || echo "N/A")
        log_info "  ${key} = ${actual_value}"
    done

    log_info "Kernel hardening complete."
}

# ==============================================================================
# 6. setup_auto_updates
# ==============================================================================
# Configures automatic security updates:
#   - Debian/Ubuntu: unattended-upgrades (security updates only)
#   - CentOS/RHEL: dnf-automatic (security updates, timer enabled)
# ==============================================================================
setup_auto_updates() {
    log_info "=========================================="
    log_info "Automatic Security Updates"
    log_info "=========================================="

    if command -v apt-get &>/dev/null; then
        _setup_auto_updates_debian || return 1
    elif command -v dnf &>/dev/null; then
        _setup_auto_updates_rhel_dnf || return 1
    elif command -v yum &>/dev/null; then
        log_warn "yum detected without dnf. Installing dnf-automatic may require EPEL."
        _setup_auto_updates_rhel_dnf || return 1
    else
        log_error "Unsupported package manager. Cannot configure automatic updates."
        return 1
    fi

    log_info "Automatic security updates configured."
    return 0
}

# ------------------------------------------------------------------------------
# _setup_auto_updates_debian: Configure unattended-upgrades for Debian/Ubuntu
# ------------------------------------------------------------------------------
_setup_auto_updates_debian() {
    log_info "Configuring unattended-upgrades for Debian/Ubuntu..."

    # Install packages
    DEBIAN_FRONTEND=noninteractive apt-get update -qq || {
        log_error "Failed to update apt package index for unattended-upgrades."
        return 1
    }
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades apt-listchanges || {
        log_error "Failed to install unattended-upgrades packages."
        return 1
    }

    # Determine distro codename for proper origin matching
    local distro_id distro_codename
    distro_id=$(lsb_release -is 2>/dev/null || grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
    distro_codename=$(lsb_release -cs 2>/dev/null || grep "^VERSION_CODENAME=" /etc/os-release | cut -d= -f2 | tr -d '"')

    # Configure: security updates only
    local config_file="${AUTO_UPGRADES_CONFIG_FILE}"
    mkdir -p "$(dirname "${config_file}")" || {
        log_error "Failed to create unattended-upgrades config directory for ${config_file}"
        return 1
    }
    if ! cat > "${config_file}" << UNATTENDED_EOF
// AI Gateway Bridge - Unattended Upgrades Configuration
// Generated by security.sh — safe to regenerate (idempotent)
// Only security updates are enabled.

Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:${distro_codename}-security";
    "\${distro_id}ESMApps:${distro_codename}-apps-security";
    "\${distro_id}ESM:${distro_codename}-infra-security";
};

// Do not auto-remove unused dependencies (safety)
Unattended-Upgrade::Remove-Unused-Dependencies "false";

// Do not auto-reboot even if required
Unattended-Upgrade::Automatic-Reboot "false";

// Send email notification on errors (if mail is configured)
// Unattended-Upgrade::Mail "root";
// Unattended-Upgrade::MailReport "on-change";

// Log to syslog
Unattended-Upgrade::SyslogEnable "true";
UNATTENDED_EOF
    then
        log_error "Failed to write unattended-upgrades config: ${config_file}"
        return 1
    fi

    # Enable the periodic apt job
    local periodic_file="${AUTO_UPGRADES_PERIODIC_FILE}"
    mkdir -p "$(dirname "${periodic_file}")" || {
        log_error "Failed to create unattended-upgrades periodic config directory for ${periodic_file}"
        return 1
    }
    if ! cat > "${periodic_file}" << 'PERIODIC_EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
PERIODIC_EOF
    then
        log_error "Failed to write unattended-upgrades periodic config: ${periodic_file}"
        return 1
    fi

    # Verify configuration
    log_info "Validating unattended-upgrades configuration..."
    local dry_run_log
    dry_run_log="$(mktemp)" || {
        log_error "Failed to allocate temporary file for unattended-upgrades validation."
        return 1
    }
    if unattended-upgrades --dry-run --debug > "${dry_run_log}" 2>&1; then
        head -5 "${dry_run_log}" || true
        log_info "unattended-upgrades configured successfully."
    else
        head -20 "${dry_run_log}" || true
        rm -f "${dry_run_log}"
        log_error "unattended-upgrades dry run failed. Check /var/log/unattended-upgrades/."
        return 1
    fi
    rm -f "${dry_run_log}"

    return 0
}

# ------------------------------------------------------------------------------
# _setup_auto_updates_rhel_dnf: Configure dnf-automatic for CentOS/RHEL/Fedora
# ------------------------------------------------------------------------------
_setup_auto_updates_rhel_dnf() {
    log_info "Configuring dnf-automatic for RHEL/CentOS/Fedora..."

    # Install dnf-automatic
    _run_checked_step "Failed to install dnf-automatic." dnf install -y -q dnf-automatic || return 1

    # Configure for security updates only
    local config_file="${DNF_AUTOMATIC_CONFIG_FILE}"
    mkdir -p "$(dirname "${config_file}")" || {
        log_error "Failed to create dnf-automatic config directory for ${config_file}"
        return 1
    }

    if [[ -f "${config_file}" ]]; then
        log_info "Configuring ${config_file} for security-only updates..."

        # Set upgrade_type to security
        sed -i 's/^upgrade_type\s*=.*/upgrade_type = security/' "${config_file}" || {
            log_error "Failed to set dnf-automatic upgrade_type in ${config_file}."
            return 1
        }
        # Set apply_updates to yes
        sed -i 's/^apply_updates\s*=.*/apply_updates = yes/' "${config_file}" || {
            log_error "Failed to set dnf-automatic apply_updates in ${config_file}."
            return 1
        }
        # Ensure download_updates is yes
        sed -i 's/^download_updates\s*=.*/download_updates = yes/' "${config_file}" || {
            log_error "Failed to set dnf-automatic download_updates in ${config_file}."
            return 1
        }
    else
        # Create minimal config
        if ! cat > "${config_file}" << 'DNF_AUTO_EOF'
[commands]
upgrade_type = security
apply_updates = yes
download_updates = yes

[emitters]
emit_via = stdio

[email]
email_from = root@localhost
email_to = root

[base]
debuglevel = 1
DNF_AUTO_EOF
        then
            log_error "Failed to write dnf-automatic config: ${config_file}"
            return 1
        fi
    fi

    # Enable the timer
    log_info "Enabling dnf-automatic timer..."
    _run_checked_step "Failed to enable ${DNF_AUTOMATIC_TIMER_NAME}." \
        systemctl enable --now "${DNF_AUTOMATIC_TIMER_NAME}" || return 1

    # Verify timer is active
    if ! systemctl is-active --quiet "${DNF_AUTOMATIC_TIMER_NAME}"; then
        log_error "${DNF_AUTOMATIC_TIMER_NAME} failed to start."
        return 1
    fi
    log_info "dnf-automatic timer is active."
    systemctl status "${DNF_AUTOMATIC_TIMER_NAME}" --no-pager || true

    return 0
}

# ==============================================================================
# 7. install_security_tools
# ==============================================================================
# Installs and configures security auditing tools:
#   - rkhunter: rootkit hunter (weekly cron scan)
#   - Lynis: security auditing framework (monthly cron audit)
# ==============================================================================
install_security_tools() {
    log_info "=========================================="
    log_info "Security Tools Installation"
    log_info "=========================================="

    _install_rkhunter || return 1
    _install_lynis || return 1

    log_info "Security tools installation complete."
    return 0
}

# ------------------------------------------------------------------------------
# _install_rkhunter: Install and configure rkhunter
# ------------------------------------------------------------------------------
_install_rkhunter() {
    log_info "--- rkhunter (Rootkit Hunter) ---"

    if ! command -v rkhunter &>/dev/null; then
        log_info "Installing rkhunter..."
        if command -v apt-get &>/dev/null; then
            DEBIAN_FRONTEND=noninteractive apt-get update -qq || {
                log_error "Failed to update apt package index while installing rkhunter."
                return 1
            }
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends rkhunter || {
                log_error "Failed to install rkhunter via apt-get."
                return 1
            }
        elif command -v dnf &>/dev/null; then
            dnf install -y -q rkhunter || {
                # rkhunter may require EPEL on RHEL
                dnf install -y -q epel-release 2>/dev/null || {
                    log_error "Failed to install epel-release while bootstrapping rkhunter."
                    return 1
                }
                dnf install -y -q rkhunter || {
                    log_error "Failed to install rkhunter via dnf."
                    return 1
                }
            }
        elif command -v yum &>/dev/null; then
            yum install -y -q epel-release 2>/dev/null || {
                log_error "Failed to install epel-release while bootstrapping rkhunter."
                return 1
            }
            yum install -y -q rkhunter || {
                log_error "Failed to install rkhunter via yum."
                return 1
            }
        else
            log_error "Cannot install rkhunter. Unsupported package manager."
            return 1
        fi
    else
        log_info "rkhunter already installed."
    fi

    # Configure rkhunter
    local rkhunter_conf="${RKHUNTER_CONF_FILE}"
    if [[ -f "${rkhunter_conf}" ]]; then
        log_info "Configuring rkhunter..."

        # Allow SSH root login check to match our configuration
        sed -i 's/^ALLOW_SSH_ROOT_USER=.*/ALLOW_SSH_ROOT_USER=prohibit-password/' "${rkhunter_conf}" 2>/dev/null || {
            log_error "Failed to configure ALLOW_SSH_ROOT_USER in ${rkhunter_conf}."
            return 1
        }

        # Ubuntu packages may ship WEB_CMD="/bin/false"; rkhunter treats the
        # quotes as part of the path and reports an invalid relative pathname.
        if grep -qE '^#*[[:space:]]*WEB_CMD=' "${rkhunter_conf}" 2>/dev/null; then
            sed -i 's|^#*[[:space:]]*WEB_CMD=.*|WEB_CMD=/bin/false|' "${rkhunter_conf}" 2>/dev/null || {
                log_error "Failed to normalize WEB_CMD in ${rkhunter_conf}."
                return 1
            }
        else
            echo "WEB_CMD=/bin/false" >> "${rkhunter_conf}" || {
                log_error "Failed to append WEB_CMD to ${rkhunter_conf}."
                return 1
            }
        fi

        # Only whitelist lwp-request when it exists. Enabling a non-existent
        # SCRIPTWHITELIST path makes rkhunter fail before it can scan.
        if [[ -e /usr/bin/lwp-request ]]; then
            sed -i 's|^#*[[:space:]]*SCRIPTWHITELIST=/usr/bin/lwp-request|SCRIPTWHITELIST=/usr/bin/lwp-request|' "${rkhunter_conf}" 2>/dev/null || {
                log_error "Failed to configure SCRIPTWHITELIST in ${rkhunter_conf}."
                return 1
            }
        else
            sed -i 's|^[[:space:]]*SCRIPTWHITELIST=/usr/bin/lwp-request|#SCRIPTWHITELIST=/usr/bin/lwp-request|' "${rkhunter_conf}" 2>/dev/null || {
                log_error "Failed to disable missing SCRIPTWHITELIST in ${rkhunter_conf}."
                return 1
            }
        fi

        # Reduce false positives: allow /dev/.udev and similar
        if ! grep -q "ALLOWDEVFILE=/dev/.udev" "${rkhunter_conf}" 2>/dev/null; then
            echo "ALLOWDEVFILE=/dev/.udev/rules.d/root.rules" >> "${rkhunter_conf}" || {
                log_error "Failed to append ALLOWDEVFILE to ${rkhunter_conf}."
                return 1
            }
        fi
    fi

    # Update rkhunter database
    log_info "Updating rkhunter database..."
    rkhunter --update 2>/dev/null || log_warn "rkhunter update returned warnings (may be normal on first run)."
    rkhunter --propupd 2>/dev/null || true

    # Run initial scan (non-interactive, skip keypress)
    log_info "Running initial rkhunter scan (this may take a minute)..."
    local rkhunter_scan_log
    rkhunter_scan_log="$(mktemp)" || {
        log_error "Failed to allocate temporary file for rkhunter scan output."
        return 1
    }
    if rkhunter --check --skip-keypress --report-warnings-only > "${rkhunter_scan_log}" 2>&1; then
        tail -20 "${rkhunter_scan_log}" || true
    else
        tail -20 "${rkhunter_scan_log}" || true
        rm -f "${rkhunter_scan_log}"
        log_error "Initial rkhunter scan failed."
        return 1
    fi
    rm -f "${rkhunter_scan_log}"

    # ---- Setup weekly cron job ----
    local rkhunter_cron="${RKHUNTER_CRON_FILE}"
    log_info "Creating weekly rkhunter cron job: ${rkhunter_cron}"
    mkdir -p "$(dirname "${rkhunter_cron}")" || {
        log_error "Failed to create weekly rkhunter cron directory for ${rkhunter_cron}."
        return 1
    }
    if ! cat > "${rkhunter_cron}" << 'RKHUNTER_CRON_EOF'
#!/usr/bin/env bash
# AI Gateway Bridge - Weekly rkhunter scan
# Generated by security.sh

set -euo pipefail

RKHUNTER_BIN="${RKHUNTER_BIN:-/usr/bin/rkhunter}"
RKHUNTER_LOG_DIR="${RKHUNTER_LOG_DIR:-/var/log}"
LOG_FILE="${RKHUNTER_LOG_DIR}/rkhunter-weekly-$(date +%Y%m%d).log"

mkdir -p "${RKHUNTER_LOG_DIR}"

update_failed=0

# Update database
if ! "${RKHUNTER_BIN}" --update --nocolors > "${LOG_FILE}" 2>&1; then
    echo "[rkhunter-cron] database update failed; continuing with existing signatures." >> "${LOG_FILE}"
    update_failed=1
fi

# Run scan
if ! "${RKHUNTER_BIN}" --check --skip-keypress --nocolors --report-warnings-only >> "${LOG_FILE}" 2>&1; then
    echo "[rkhunter-cron] scan failed." >> "${LOG_FILE}"
    exit 1
fi

if [[ "${update_failed}" -ne 0 ]]; then
    exit 1
fi

# Rotate: keep last 12 weekly logs
find "${RKHUNTER_LOG_DIR}" -name "rkhunter-weekly-*.log" -mtime +90 -delete 2>/dev/null || true
RKHUNTER_CRON_EOF
    then
        log_error "Failed to write weekly rkhunter cron job: ${rkhunter_cron}."
        return 1
    fi
    chmod 755 "${rkhunter_cron}" || {
        log_error "Failed to chmod weekly rkhunter cron job: ${rkhunter_cron}."
        return 1
    }

    log_info "rkhunter installation and configuration complete."
    return 0
}

# ------------------------------------------------------------------------------
# _install_lynis: Install and configure Lynis
# ------------------------------------------------------------------------------
_install_lynis() {
    log_info "--- Lynis (Security Auditing) ---"

    if ! command -v lynis &>/dev/null; then
        log_info "Installing Lynis..."
        if command -v apt-get &>/dev/null; then
            # Try official repository first
            if ! apt-cache show lynis &>/dev/null 2>&1; then
                log_info "Adding Lynis official repository..."
                apt-get install -y -qq apt-transport-https ca-certificates curl gnupg || {
                    log_error "Failed to install Lynis repository bootstrap dependencies."
                    return 1
                }
                if ! curl -fsSL https://packages.cisofy.com/keys/cisofy-software-public.key | \
                    gpg --dearmor -o /usr/share/keyrings/cisofy-archive-keyring.gpg 2>/dev/null; then
                    log_error "Failed to import the Lynis repository key. Refusing to use an unverified repository."
                    return 1
                fi
                local codename
                codename=$(lsb_release -cs 2>/dev/null || grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
                echo "deb [signed-by=/usr/share/keyrings/cisofy-archive-keyring.gpg] https://packages.cisofy.com/community/lynis/deb/ stable main" \
                    > /etc/apt/sources.list.d/cisofy-lynis.list || {
                    log_error "Failed to write the Lynis apt repository list."
                    return 1
                }
                apt-get update -qq || {
                    log_error "Failed to refresh apt package index after adding the Lynis repository."
                    return 1
                }
            fi
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq lynis || {
                log_error "Failed to install Lynis via apt-get."
                return 1
            }
        elif command -v dnf &>/dev/null; then
            dnf install -y -q lynis || {
                dnf install -y -q epel-release 2>/dev/null || {
                    log_error "Failed to install epel-release while bootstrapping Lynis."
                    return 1
                }
                dnf install -y -q lynis || {
                    log_error "Failed to install Lynis via dnf."
                    return 1
                }
            }
        elif command -v yum &>/dev/null; then
            yum install -y -q epel-release 2>/dev/null || {
                log_error "Failed to install epel-release while bootstrapping Lynis."
                return 1
            }
            yum install -y -q lynis || {
                log_error "Failed to install Lynis via yum."
                return 1
            }
        else
            # Fallback: install from git (with China mirror support)
            log_info "Installing Lynis from GitHub..."
            local lynis_dir="/opt/lynis"
            if [[ -d "${lynis_dir}" ]]; then
                cd "${lynis_dir}" && git pull --quiet || {
                    log_error "Failed to update Lynis from Git."
                    return 1
                }
            else
                github_clone_repo "https://github.com/CISOfy/lynis.git" "${lynis_dir}" || return 1
            fi
            ln -sf "${lynis_dir}/lynis" /usr/local/bin/lynis || {
                log_error "Failed to expose Lynis binary at /usr/local/bin/lynis."
                return 1
            }
        fi
    else
        log_info "Lynis already installed."
    fi

    # Run initial audit
    local lynis_report="${LYNIS_REPORT_FILE}"
    log_info "Running initial Lynis audit (this may take several minutes)..."
    _run_lynis_audit_report "${lynis_report}" "Initial Lynis audit" || return 1

    # Display hardening index
    _display_lynis_summary "${lynis_report}"

    # ---- Setup monthly cron job ----
    local lynis_cron="${LYNIS_CRON_FILE}"
    log_info "Creating monthly Lynis cron job: ${lynis_cron}"
    mkdir -p "$(dirname "${lynis_cron}")" || {
        log_error "Failed to create monthly Lynis cron directory for ${lynis_cron}."
        return 1
    }
    if ! cat > "${lynis_cron}" << 'LYNIS_CRON_EOF'
#!/usr/bin/env bash
# AI Gateway Bridge - Monthly Lynis security audit
# Generated by security.sh

set -euo pipefail

REPORT_FILE="/var/log/lynis-report-$(date +%Y%m%d).txt"

# Run full audit
/usr/bin/lynis audit system --quick --no-colors --quiet > "${REPORT_FILE}" 2>&1

# Copy as latest report
cp "${REPORT_FILE}" /var/log/lynis-report.txt

# Rotate: keep last 6 monthly reports
find /var/log -name "lynis-report-*.txt" -mtime +180 -delete 2>/dev/null || true
LYNIS_CRON_EOF
    then
        log_error "Failed to write monthly Lynis cron job: ${lynis_cron}."
        return 1
    fi
    chmod 755 "${lynis_cron}" || {
        log_error "Failed to chmod monthly Lynis cron job: ${lynis_cron}."
        return 1
    }

    log_info "Lynis installation and configuration complete."
    return 0
}

# ------------------------------------------------------------------------------
# _display_lynis_summary: Parse and display Lynis audit summary
# Arguments:
#   $1 - path to Lynis report file
# ------------------------------------------------------------------------------
_display_lynis_summary() {
    local report_file="${1:-${LYNIS_REPORT_FILE}}"
    local lynis_data="${LYNIS_DATA_FILE}"

    if [[ ! -f "${lynis_data}" ]] && [[ ! -f "${report_file}" ]]; then
        log_warn "No Lynis report found."
        return 0
    fi

    local hardening_index="N/A"
    local warnings_count=0
    local suggestions_count=0

    # Parse from the dat file (machine-readable)
    if [[ -f "${lynis_data}" ]]; then
        hardening_index=$(grep "^hardening_index=" "${lynis_data}" 2>/dev/null | cut -d= -f2 | head -1)
        warnings_count=$(grep -c "^warning\[\]=" "${lynis_data}" 2>/dev/null || echo "0")
        suggestions_count=$(grep -c "^suggestion\[\]=" "${lynis_data}" 2>/dev/null || echo "0")
    fi

    # Fallback: parse from text report
    if [[ "${hardening_index}" == "N/A" || -z "${hardening_index}" ]] && [[ -f "${report_file}" ]]; then
        hardening_index=$(grep -i "Hardening index" "${report_file}" 2>/dev/null | grep -oP '\d+' | head -1 || echo "N/A")
        if [[ "${warnings_count}" -eq 0 ]]; then
            warnings_count=$(grep -ci "warning" "${report_file}" 2>/dev/null || echo "0")
        fi
        if [[ "${suggestions_count}" -eq 0 ]]; then
            suggestions_count=$(grep -ci "suggestion" "${report_file}" 2>/dev/null || echo "0")
        fi
    fi

    echo ""
    log_info "=========================================="
    log_info "Lynis Security Audit Summary"
    log_info "=========================================="
    log_info "  Hardening Index : ${hardening_index}"
    log_info "  Warnings        : ${warnings_count}"
    log_info "  Suggestions     : ${suggestions_count}"
    log_info "  Full Report     : ${report_file}"
    log_info "  Data File       : ${lynis_data}"
    log_info "=========================================="
    echo ""
}

# ------------------------------------------------------------------------------
# _run_lynis_audit_report: Execute Lynis audit and require a non-empty report
# Arguments:
#   $1 - destination report file
#   $2 - human-readable label for logging
# ------------------------------------------------------------------------------
_run_lynis_audit_report() {
    local report_path="$1"
    local audit_label="${2:-Lynis audit}"
    local audit_status=0

    mkdir -p "$(dirname "${report_path}")"

    if lynis audit system --quick --no-colors --quiet > "${report_path}" 2>&1; then
        :
    else
        audit_status=$?
        log_error "${audit_label} failed with exit code ${audit_status}. Review: ${report_path}"
        return 1
    fi

    if [[ ! -s "${report_path}" ]]; then
        log_error "${audit_label} produced no report at ${report_path}."
        return 1
    fi

    return 0
}

# ==============================================================================
# 8. run_security_audit
# ==============================================================================
# Runs a Lynis security audit and displays results:
#   - Executes lynis audit system
#   - Parses output for hardening index
#   - Displays summary: score, warnings, suggestions
#   - Saves full report to /var/log/lynis-report.txt
# ==============================================================================
run_security_audit() {
    log_info "=========================================="
    log_info "Security Audit (Lynis)"
    log_info "=========================================="

    if ! command -v lynis &>/dev/null; then
        log_warn "Lynis is not installed. Installing now..."
        _install_lynis
        return $?
    fi

    local report_file="${LYNIS_REPORT_FILE}"
    local timestamp
    timestamp=$(date +%Y%m%d%H%M%S)
    local timestamped_report="${LYNIS_LOG_DIR}/lynis-report-${timestamp}.txt"

    # Run audit
    log_info "Running Lynis security audit (this may take several minutes)..."
    _run_lynis_audit_report "${timestamped_report}" "Lynis security audit" || return 1

    # Copy as latest
    cp "${timestamped_report}" "${report_file}" || {
        log_error "Failed to copy Lynis report to ${report_file}."
        return 1
    }

    # Display summary
    _display_lynis_summary "${report_file}"

    log_info "Security audit complete. Full report: ${report_file}"
}

# ==============================================================================
# 9. full_security_hardening
# ==============================================================================
# Orchestration function — runs all hardening steps in the correct order:
#   1. Kernel hardening (no service dependency)
#   2. Firewall setup (before SSH hardening)
#   3. SSH hardening (depends on firewall)
#   4. fail2ban (depends on SSH port)
#   5. Auto-updates
#   6. Security tools (rkhunter, Lynis)
#   7. Port audit (after all services configured)
#   8. Security audit (final score)
# ==============================================================================
full_security_hardening() {
    log_info "=========================================="
    log_info "Full Security Hardening - Starting"
    log_info "=========================================="
    echo ""

    local total_steps=8
    local current_step=0
    local -a failed_steps=()
    local -a passed_steps=()

    # ---- Step 1: Kernel Hardening ----
    current_step=$((current_step + 1))
    log_info "[${current_step}/${total_steps}] Kernel Hardening..."
    if harden_kernel; then
        passed_steps+=("Kernel Hardening")
    else
        failed_steps+=("Kernel Hardening")
        log_warn "Kernel hardening encountered issues. Continuing..."
    fi
    echo ""

    # ---- Step 2: Firewall Setup ----
    current_step=$((current_step + 1))
    log_info "[${current_step}/${total_steps}] Firewall Setup..."
    if setup_firewall; then
        passed_steps+=("Firewall Setup")
    else
        failed_steps+=("Firewall Setup")
        log_warn "Firewall setup encountered issues. Continuing..."
    fi
    echo ""

    # ---- Step 3: SSH Hardening ----
    current_step=$((current_step + 1))
    log_info "[${current_step}/${total_steps}] SSH Hardening..."
    if harden_ssh; then
        passed_steps+=("SSH Hardening")
    else
        failed_steps+=("SSH Hardening")
        log_warn "SSH hardening encountered issues. Continuing..."
    fi
    echo ""

    # ---- Step 4: fail2ban ----
    current_step=$((current_step + 1))
    log_info "[${current_step}/${total_steps}] fail2ban Setup..."
    if setup_fail2ban; then
        passed_steps+=("fail2ban")
    else
        failed_steps+=("fail2ban")
        log_warn "fail2ban setup encountered issues. Continuing..."
    fi
    echo ""

    # ---- Step 5: Auto Updates ----
    current_step=$((current_step + 1))
    log_info "[${current_step}/${total_steps}] Automatic Security Updates..."
    if setup_auto_updates; then
        passed_steps+=("Auto Updates")
    else
        failed_steps+=("Auto Updates")
        log_warn "Auto-update setup encountered issues. Continuing..."
    fi
    echo ""

    # ---- Step 6: Security Tools ----
    current_step=$((current_step + 1))
    log_info "[${current_step}/${total_steps}] Security Tools (rkhunter, Lynis)..."
    if install_security_tools; then
        passed_steps+=("Security Tools")
    else
        failed_steps+=("Security Tools")
        log_warn "Security tools installation encountered issues. Continuing..."
    fi
    echo ""

    # ---- Step 7: Port Audit ----
    current_step=$((current_step + 1))
    log_info "[${current_step}/${total_steps}] Port Security Audit..."
    if audit_ports; then
        passed_steps+=("Port Audit")
    else
        failed_steps+=("Port Audit")
        log_warn "Port audit encountered issues. Continuing..."
    fi
    echo ""

    # ---- Step 8: Security Audit ----
    current_step=$((current_step + 1))
    log_info "[${current_step}/${total_steps}] Final Security Audit..."
    if run_security_audit; then
        passed_steps+=("Security Audit")
    else
        failed_steps+=("Security Audit")
        log_warn "Security audit encountered issues."
    fi
    echo ""

    # ---- Summary ----
    log_info "=========================================="
    log_info "Full Security Hardening - Summary"
    log_info "=========================================="

    local ssh_port
    ssh_port="$(_get_ssh_port)"
    local fw_type
    fw_type="$(_detect_firewall)"

    log_info "SSH Port         : ${ssh_port}"
    log_info "Firewall         : ${fw_type}"
    log_info ""

    if [[ ${#passed_steps[@]} -gt 0 ]]; then
        log_info "Passed steps (${#passed_steps[@]}/${total_steps}):"
        for step in ${passed_steps[@]+"${passed_steps[@]}"}; do
            log_info "  [OK] ${step}"
        done
    fi

    if [[ ${#failed_steps[@]} -gt 0 ]]; then
        log_warn "Failed steps (${#failed_steps[@]}/${total_steps}):"
        for step in ${failed_steps[@]+"${failed_steps[@]}"}; do
            log_warn "  [FAIL] ${step}"
        done
    fi

    echo ""

    # ---- Display Lynis hardening index as overall score ----
    local lynis_data="${LYNIS_DATA_FILE}"
    local hardening_index="N/A"
    if [[ -f "${lynis_data}" ]]; then
        hardening_index=$(grep "^hardening_index=" "${lynis_data}" 2>/dev/null | cut -d= -f2 | head -1)
    fi

    log_info "=========================================="
    log_info "Overall Security Score (Lynis): ${hardening_index:-N/A}"
    log_info "=========================================="

    if [[ "${hardening_index}" != "N/A" ]] && [[ -n "${hardening_index}" ]]; then
        if (( hardening_index >= 80 )); then
            log_info "Excellent hardening score!"
        elif (( hardening_index >= 65 )); then
            log_info "Good hardening score. Target for this project: >= 65."
        else
            log_warn "Hardening score below target (65). Review Lynis suggestions in /var/log/lynis-report.txt"
        fi
    fi

    echo ""
    log_info "Full report saved to: ${LYNIS_REPORT_FILE}"
    log_info "State file: ${SECURITY_STATE_FILE}"

    # ---- Critical SSH reminder ----
    log_warn "============================================================================"
    log_warn "REMINDER: If you changed the SSH port, test connectivity in a SEPARATE"
    log_warn "terminal BEFORE closing this session!"
    log_warn "  ssh -p ${ssh_port} root@<your-server-ip>"
    log_warn "============================================================================"

    # Return success only if no steps failed
    if [[ ${#failed_steps[@]} -eq 0 ]]; then
        return 0
    else
        return 1
    fi
}
