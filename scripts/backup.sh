#!/usr/bin/env bash
###############################################################################
# Bifrost - Backup & Restore Module
#
# Provides configuration backup with encryption, restore capabilities,
# automated daily backup via cron, and emergency IP rotation for Server B.
#
# Functions:
#   backup_config()          - Create encrypted tar.gz backup of all configs
#   restore_config()         - List and restore from available backups
#   setup_auto_backup()      - Register daily cron job for automatic backups
#   emergency_ip_rotation()  - Update Xray + Mihomo configs for new Server B IP
#
# Usage:
#   bash scripts/backup.sh                  # Interactive menu
#   bash scripts/backup.sh backup           # Create backup now
#   bash scripts/backup.sh restore          # List & restore
#   bash scripts/backup.sh auto             # Setup daily cron
#   bash scripts/backup.sh rotate-ip <IP>   # Emergency IP rotation
#
# Dependencies: scripts/common.sh, openssl, tar
###############################################################################

set -euo pipefail

# Guard against double-sourcing (readonly variables would conflict)
if [[ -n "${_BACKUP_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
readonly _BACKUP_SH_LOADED=1

# Resolve the directory this script resides in
_BAK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_BAK_PROJECT_DIR="$(cd "${_BAK_SCRIPT_DIR}/.." && pwd)"

# Source common utilities
if [[ -f "${_BAK_SCRIPT_DIR}/common.sh" ]]; then
    # shellcheck source=scripts/common.sh
    source "${_BAK_SCRIPT_DIR}/common.sh"
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
: "${NC:=${COLOR_RESET:-\033[0m}}"
: "${BOLD:=${COLOR_BOLD:-\033[1m}}"

# =============================================================================
# Constants
# =============================================================================
# Guarded — may already be defined by server-a.sh or mihomo.sh
[[ -v BACKUP_BASE_DIR ]]           || readonly BACKUP_BASE_DIR="/var/backups/bifrost"
[[ -v BACKUP_ENCRYPTION_KEY_FILE ]] || readonly BACKUP_ENCRYPTION_KEY_FILE="/root/.bifrost-backup-key"
[[ -v BACKUP_MAX_KEEP ]]           || readonly BACKUP_MAX_KEEP=7

# Config paths to back up
[[ -v XRAY_CONFIG_DIR ]]           || readonly XRAY_CONFIG_DIR="/usr/local/etc/xray"
[[ -v CADDY_CONFIG_DIR ]]          || readonly CADDY_CONFIG_DIR="/etc/caddy"
[[ -v MIHOMO_CONFIG_DIR ]]         || readonly MIHOMO_CONFIG_DIR="/etc/mihomo"
[[ -v NEW_API_DIR ]]               || readonly NEW_API_DIR="/opt/new-api"
[[ -v INSTALL_DIR ]]               || readonly INSTALL_DIR="/opt/bifrost"
[[ -v SECURITY_STATE_DIR ]]        || readonly SECURITY_STATE_DIR="/etc/bifrost"
[[ -v WHITELIST_INSTALLED ]]       || readonly WHITELIST_INSTALLED="/opt/bifrost/configs/whitelist"
[[ -v FAIL2BAN_CONFIG ]]           || readonly FAIL2BAN_CONFIG="/etc/fail2ban"
[[ -v SYSCTL_HARDENING ]]          || readonly SYSCTL_HARDENING="/etc/sysctl.d/99-ai-gateway-hardening.conf"
[[ -v SERVER_B_CONF ]]             || readonly SERVER_B_CONF="/root/server-b-connection.conf"
[[ -v CONNECTION_INFO ]]           || readonly CONNECTION_INFO="/root/ai-gateway-connection.txt"

###############################################################################
# _ensure_backup_dir()
#
# Create the backup directory with restrictive permissions.
###############################################################################
_ensure_backup_dir() {
    if [[ ! -d "${BACKUP_BASE_DIR}" ]]; then
        mkdir -p "${BACKUP_BASE_DIR}"
        chmod 700 "${BACKUP_BASE_DIR}"
    fi
}

###############################################################################
# _get_encryption_key()
#
# Retrieve or generate the encryption passphrase used for backup archives.
# The key is stored at /root/.bifrost-backup-key with mode 600.
# Returns: passphrase string via stdout.
###############################################################################
_get_encryption_key() {
    if [[ -f "${BACKUP_ENCRYPTION_KEY_FILE}" ]]; then
        cat "${BACKUP_ENCRYPTION_KEY_FILE}"
        return 0
    fi

    # Generate a new key
    local key=""
    if command_exists openssl; then
        key="$(openssl rand -base64 32 | tr -d '/+\n' | head -c 48)"
    elif [[ -r /dev/urandom ]]; then
        key="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48)"
    else
        die "No suitable random source for encryption key generation."
    fi

    echo "${key}" > "${BACKUP_ENCRYPTION_KEY_FILE}"
    chmod 600 "${BACKUP_ENCRYPTION_KEY_FILE}"
    log_info "Encryption key generated and stored at ${BACKUP_ENCRYPTION_KEY_FILE}" >&2
    log_warn "IMPORTANT: Keep this key safe. Without it you cannot restore backups." >&2

    echo "${key}"
}

###############################################################################
# _collect_config_paths()
#
# Build an array of existing config paths to include in the backup.
# Prints each valid path to stdout, one per line.
###############################################################################
_collect_config_paths() {
    local paths=(
        "${XRAY_CONFIG_DIR}"
        "${CADDY_CONFIG_DIR}"
        "${MIHOMO_CONFIG_DIR}"
        "${NEW_API_DIR}"
        "${INSTALL_DIR}"
        "${SECURITY_STATE_DIR}"
        "${FAIL2BAN_CONFIG}"
        "${SYSCTL_HARDENING}"
        "${SERVER_B_CONF}"
        "${CONNECTION_INFO}"
        # VPN / WireGuard configuration and keys
        "/etc/wireguard"
        "/etc/bifrost/vpn"
        # User registry (credentials, guides)
        "/etc/bifrost/users"
        # Server B deploy state (generated by server-b.sh)
        "/root/.bifrost"
        # Anti-DPI dest pool
        "/opt/bifrost/dest-pool.txt"
        # Backup encryption key (needed to restore backups)
        "${BACKUP_ENCRYPTION_KEY_FILE}"
    )

    for p in ${paths[@]+"${paths[@]}"}; do
        if [[ -e "${p}" ]]; then
            echo "${p}"
        fi
    done
}

###############################################################################
# _prune_old_backups()
#
# Remove backups older than BACKUP_MAX_KEEP, keeping only the N most recent.
###############################################################################
_prune_old_backups() {
    local keep="${1:-${BACKUP_MAX_KEEP}}"

    if [[ ! -d "${BACKUP_BASE_DIR}" ]]; then
        return 0
    fi

    local count
    count="$(find "${BACKUP_BASE_DIR}" -maxdepth 1 -name "backup-*.tar.gz.enc" -type f 2>/dev/null | wc -l)"

    if (( count <= keep )); then
        return 0
    fi

    local to_remove
    to_remove=$(( count - keep ))
    log_info "Pruning ${to_remove} old backup(s), keeping newest ${keep}..."

    # Remove oldest files first (sorted by modification time, oldest first)
    find "${BACKUP_BASE_DIR}" -maxdepth 1 -name "backup-*.tar.gz.enc" -type f -printf '%T@ %p\n' 2>/dev/null \
        | sort -n \
        | head -n "${to_remove}" \
        | awk '{print $2}' \
        | while IFS= read -r old_file; do
            rm -f "${old_file}"
            # Also remove the corresponding manifest if present
            rm -f "${old_file%.tar.gz.enc}.manifest"
            log_info "Removed old backup: $(basename "${old_file}")"
        done
}

###############################################################################
# _backup_stage_path()
#
# Copy one config path into the temporary staging tree while preserving its
# absolute path relative to /.
###############################################################################
_backup_stage_path() {
    local source_path="${1:?_backup_stage_path requires a source path}"
    local stage_root="${2:?_backup_stage_path requires a staging root}"
    local relative_path="${source_path#/}"
    local staged_path="${stage_root}/${relative_path}"

    mkdir -p "$(dirname "${staged_path}")"
    if ! cp -a "${source_path}" "${staged_path}" 2>/dev/null; then
        log_error "Failed to stage backup path: ${source_path}"
        return 1
    fi

    return 0
}

###############################################################################
# backup_config()
#
# Create an encrypted tar.gz archive of all Bifrost configs.
# Archives are stored under /var/backups/bifrost/ with a timestamp.
# Only the latest BACKUP_MAX_KEEP (default 7) backups are retained.
#
# Steps:
#   1. Collect all existing config paths
#   2. Create a tar.gz archive
#   3. Encrypt the archive with AES-256-CBC using the stored passphrase
#   4. Write a manifest listing included paths
#   5. Prune old backups beyond the retention limit
###############################################################################
backup_config() {
    log_step "Creating encrypted configuration backup..."

    # Ensure required tools are available
    if declare -f install_if_missing &>/dev/null; then
        install_if_missing tar tar
        install_if_missing openssl openssl
    else
        if ! command -v tar &>/dev/null; then
            log_error "tar is required for backup but not installed. Run: apt install tar / dnf install tar"
            return 1
        fi
        if ! command -v openssl &>/dev/null; then
            log_error "openssl is required for encrypted backup but not installed. Run: apt install openssl / dnf install openssl"
            return 1
        fi
    fi

    # Get encryption key
    local enc_key
    enc_key="$(_get_encryption_key)"

    _ensure_backup_dir

    # Collect paths after the key exists so the backup can include it.
    local -a config_paths=()
    while IFS= read -r path; do
        config_paths+=("${path}")
    done < <(_collect_config_paths)

    if [[ ${#config_paths[@]} -eq 0 ]]; then
        log_warn "No configuration files found to back up."
        return 1
    fi

    log_info "Found ${#config_paths[@]} config path(s) to back up."

    # Build archive name
    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    local hostname_short
    hostname_short="$(hostname -s 2>/dev/null || echo 'unknown')"
    local archive_name="backup-${hostname_short}-${timestamp}"
    local tar_path="${BACKUP_BASE_DIR}/${archive_name}.tar.gz"
    local enc_path="${BACKUP_BASE_DIR}/${archive_name}.tar.gz.enc"
    local manifest_path="${BACKUP_BASE_DIR}/${archive_name}.manifest"
    local staging_dir
    local staged_configs_dir
    local staged_metadata_dir
    staging_dir="$(mktemp -d /tmp/bifrost-backup.XXXXXX)"
    staged_configs_dir="${staging_dir}/configs"
    staged_metadata_dir="${staging_dir}/metadata"
    mkdir -p "${staged_configs_dir}" "${staged_metadata_dir}"

    # Stage config payload first so archive creation is atomic and verifiable.
    local source_path=""
    for source_path in ${config_paths[@]+"${config_paths[@]}"}; do
        _backup_stage_path "${source_path}" "${staged_configs_dir}" || {
            rm -rf "${staging_dir}"
            return 1
        }
    done

    # Export metadata with stable filenames so tests and restore previews are deterministic.
    if ! crontab -l > "${staged_metadata_dir}/crontab.txt" 2>/dev/null; then
        echo "# No crontab" > "${staged_metadata_dir}/crontab.txt"
    fi

    if command_exists docker && docker info &>/dev/null; then
        docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' > "${staged_metadata_dir}/docker-info.txt" 2>/dev/null || {
            rm -rf "${staging_dir}"
            die "Failed to export Docker metadata for backup."
        }

        local compose_dir=""
        for compose_dir in "${NEW_API_DIR}" "${INSTALL_DIR}/docker"; do
            if [[ -f "${compose_dir}/docker-compose.yml" ]]; then
                cp "${compose_dir}/docker-compose.yml" \
                    "${staged_metadata_dir}/docker-compose-$(basename "${compose_dir}").yml" 2>/dev/null || {
                    rm -rf "${staging_dir}"
                    die "Failed to stage docker-compose metadata from ${compose_dir}."
                }
            fi
        done
    else
        echo "# Docker not available" > "${staged_metadata_dir}/docker-info.txt"
    fi

    # Create tar archive once from the staged tree.
    log_info "Creating tar archive..."
    tar czf "${tar_path}" -C "${staging_dir}" configs metadata 2>/dev/null || {
        rm -rf "${staging_dir}"
        die "Failed to create backup archive."
    }
    rm -rf "${staging_dir}"

    if [[ ! -s "${tar_path}" ]]; then
        die "Backup archive is empty or missing after tar creation."
    fi

    # Encrypt the archive
    log_info "Encrypting backup with AES-256-CBC..."
    openssl enc -aes-256-cbc -salt -pbkdf2 -iter 100000 \
        -in "${tar_path}" \
        -out "${enc_path}" \
        -pass "pass:${enc_key}"

    if [[ ! -s "${enc_path}" ]]; then
        die "Encryption failed. Encrypted file is empty or missing."
    fi

    # Remove the unencrypted archive
    rm -f "${tar_path}"

    # Write manifest
    {
        echo "# Bifrost Backup Manifest"
        echo "# Created: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "# Host: $(hostname -f 2>/dev/null || hostname)"
        echo "# Archive: ${archive_name}.tar.gz.enc"
        echo "#"
        echo "# Included paths:"
        for p in ${config_paths[@]+"${config_paths[@]}"}; do
            echo "${p}"
        done
        echo "#"
        echo "# Included metadata:"
        echo "metadata/crontab.txt"
        echo "metadata/docker-info.txt"
        echo "metadata/docker-compose-*.yml (if present)"
    } > "${manifest_path}"
    chmod 600 "${manifest_path}"

    # Get archive size
    local size_human
    size_human="$(du -h "${enc_path}" | awk '{print $1}')"

    # Prune old backups
    _prune_old_backups "${BACKUP_MAX_KEEP}"

    log_success "Backup created successfully."
    log_info "  Archive: ${enc_path}"
    log_info "  Size:    ${size_human}"
    log_info "  Manifest: ${manifest_path}"
    log_info "  Key:     ${BACKUP_ENCRYPTION_KEY_FILE}"
    log_info "  Retention: ${BACKUP_MAX_KEEP} most recent backups"
}

###############################################################################
# restore_config()
#
# List available backups, let the user select one, decrypt and restore it.
# After restoration, restarts affected services.
#
# Steps:
#   1. List all encrypted backups with size and date
#   2. User selects a backup to restore
#   3. Decrypt the archive
#   4. Extract to a staging directory for review
#   5. Confirm and copy configs to their original locations
#   6. Restart affected services (Xray, Caddy, etc.)
###############################################################################
restore_config() {
    log_step "Configuration Restore"

    # Ensure required tools are available
    if declare -f install_if_missing &>/dev/null; then
        install_if_missing tar tar
        install_if_missing openssl openssl
    else
        if ! command -v tar &>/dev/null; then
            log_error "tar is required for restore but not installed."
            return 1
        fi
        if ! command -v openssl &>/dev/null; then
            log_error "openssl is required for decryption but not installed."
            return 1
        fi
    fi

    _ensure_backup_dir

    # List available backups
    local -a backup_files=()
    while IFS= read -r bfile; do
        backup_files+=("${bfile}")
    done < <(find "${BACKUP_BASE_DIR}" -maxdepth 1 -name "backup-*.tar.gz.enc" -type f 2>/dev/null | sort -r)

    if [[ ${#backup_files[@]} -eq 0 ]]; then
        log_warn "No backups found in ${BACKUP_BASE_DIR}."
        return 1
    fi

    echo ""
    echo -e "${BOLD}Available backups:${NC}"
    echo "==========================================="
    local idx=0
    for bfile in ${backup_files[@]+"${backup_files[@]}"}; do
        idx=$(( idx + 1 ))
        local fname
        fname="$(basename "${bfile}")"
        local fsize
        fsize="$(du -h "${bfile}" | awk '{print $1}')"
        local fdate
        fdate="$(stat -c '%y' "${bfile}" 2>/dev/null | cut -d. -f1)"
        if [[ -z "${fdate}" ]]; then
            fdate="$(date -r "${bfile}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'unknown')"
        fi

        # Check for manifest
        local manifest="${bfile%.tar.gz.enc}.manifest"
        local has_manifest="no"
        if [[ -f "${manifest}" ]]; then
            has_manifest="yes"
        fi

        printf "  %s%d)%s %-45s %s  %s  manifest=%s\n" \
            "${GREEN}" "${idx}" "${NC}" "${fname}" "${fsize}" "${fdate}" "${has_manifest}"
    done
    echo "==========================================="
    echo ""

    # Prompt for selection
    local selection
    read -r -p "Select backup to restore [1-${#backup_files[@]}] (0 to cancel): " selection

    if [[ "${selection}" == "0" || -z "${selection}" ]]; then
        log_info "Restore cancelled."
        return 0
    fi

    if ! [[ "${selection}" =~ ^[0-9]+$ ]] || (( selection < 1 || selection > ${#backup_files[@]} )); then
        log_error "Invalid selection: ${selection}"
        return 1
    fi

    local selected_file="${backup_files[$(( selection - 1 ))]}"
    local selected_name
    selected_name="$(basename "${selected_file}")"
    log_info "Selected: ${selected_name}"

    # Show manifest if available
    local manifest="${selected_file%.tar.gz.enc}.manifest"
    if [[ -f "${manifest}" ]]; then
        echo ""
        echo -e "${BOLD}Manifest contents:${NC}"
        cat "${manifest}"
        echo ""
    fi

    # Confirm restore
    echo ""
    log_warn "Restoring will OVERWRITE current configurations."
    if ! confirm_action "Proceed with restore from '${selected_name}'?"; then
        log_info "Restore cancelled."
        return 0
    fi

    # Get encryption key
    local enc_key
    if [[ -f "${BACKUP_ENCRYPTION_KEY_FILE}" ]]; then
        enc_key="$(cat "${BACKUP_ENCRYPTION_KEY_FILE}")"
    else
        log_warn "Encryption key file not found at ${BACKUP_ENCRYPTION_KEY_FILE}."
        read -r -s -p "Enter decryption passphrase: " enc_key
        echo ""
    fi

    if [[ -z "${enc_key}" ]]; then
        die "No encryption key provided. Cannot decrypt backup."
    fi

    # Create staging directory
    local staging_dir
    staging_dir="$(mktemp -d /tmp/ai-gateway-restore.XXXXXX)"
    log_info "Staging directory: ${staging_dir}"

    # Decrypt
    log_info "Decrypting backup..."
    local decrypted_tar="${staging_dir}/backup.tar.gz"
    if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
        -in "${selected_file}" \
        -out "${decrypted_tar}" \
        -pass "pass:${enc_key}" 2>/dev/null; then
        rm -rf "${staging_dir}"
        die "Decryption failed. Wrong key or corrupted archive."
    fi

    # Extract to staging
    log_info "Extracting archive to staging area..."
    tar xzf "${decrypted_tar}" -C "${staging_dir}" 2>/dev/null || {
        # Try without gzip (might be double-compressed)
        tar xf "${decrypted_tar}" -C "${staging_dir}" 2>/dev/null || {
            rm -rf "${staging_dir}"
            die "Failed to extract backup archive."
        }
    }
    rm -f "${decrypted_tar}"

    # Show extracted contents
    log_info "Extracted contents:"
    find "${staging_dir}" -type f | head -30 | while IFS= read -r f; do
        echo "  ${f#${staging_dir}/}"
    done

    echo ""
    if ! confirm_action "Copy restored configs to their original locations?"; then
        log_info "Restore aborted. Staging dir left at: ${staging_dir}"
        return 0
    fi

    # Copy files back to original locations
    log_info "Restoring configuration files..."

    # The archive may have the files under a 'configs/' prefix or at root paths
    # Try to detect the layout and restore accordingly
    if [[ -d "${staging_dir}/configs" ]]; then
        # Prefixed layout: configs/usr/local/etc/xray, etc.
        # Copy recursively, preserving paths relative to /
        cd "${staging_dir}/configs" || true
        find . -type f | while IFS= read -r relpath; do
            local dest="/${relpath#./}"
            local dest_dir
            dest_dir="$(dirname "${dest}")"
            mkdir -p "${dest_dir}"
            cp -a "${staging_dir}/configs/${relpath#./}" "${dest}" 2>/dev/null || {
                log_warn "Could not restore: ${dest}"
            }
        done
        cd - >/dev/null 2>&1 || true
    else
        # Direct layout: files are at their original absolute paths within staging
        find "${staging_dir}" -type f ! -name "backup.tar.gz" | while IFS= read -r fpath; do
            # Strip staging prefix to get original absolute path
            local relpath="${fpath#${staging_dir}}"
            if [[ "${relpath}" == /* ]]; then
                local dest_dir
                dest_dir="$(dirname "${relpath}")"
                mkdir -p "${dest_dir}"
                cp -a "${fpath}" "${relpath}" 2>/dev/null || {
                    log_warn "Could not restore: ${relpath}"
                }
            fi
        done
    fi

    # Cleanup staging
    rm -rf "${staging_dir}"

    # Restart affected services
    log_info "Restarting affected services..."
    local services_to_restart=("xray" "caddy" "mihomo" "x-ui")
    for svc in ${services_to_restart[@]+"${services_to_restart[@]}"}; do
        if command_exists systemctl && systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
            log_info "Restarting ${svc}..."
            systemctl restart "${svc}" 2>/dev/null || log_warn "Failed to restart ${svc}."
            sleep 1
            if systemctl is-active --quiet "${svc}" 2>/dev/null; then
                log_success "Service '${svc}' restarted successfully."
            else
                log_error "Service '${svc}' failed to start after restore."
            fi
        fi
    done

    # Restart Docker containers if applicable
    if command_exists docker && docker info &>/dev/null; then
        for container_name in "new-api" "newapi" "one-api" "oneapi"; do
            if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qw "${container_name}"; then
                log_info "Restarting Docker container: ${container_name}..."
                docker restart "${container_name}" 2>/dev/null || log_warn "Failed to restart ${container_name}."
            fi
        done
    fi

    log_success "Configuration restore completed."
}

_backup_ensure_crontab_available() {
    _backup_cron_scheduler_running() {
        if command_exists systemctl; then
            if systemctl is-active --quiet cron 2>/dev/null || systemctl is-active --quiet crond 2>/dev/null; then
                return 0
            fi
        fi

        if command_exists pgrep; then
            if pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1; then
                return 0
            fi
        fi

        return 1
    }

    _backup_start_cron_scheduler() {
        if command_exists systemctl; then
            if systemctl enable --now cron 2>/dev/null; then
                _backup_cron_scheduler_running && return 0
                log_error "cron service did not become active after systemctl enable --now cron."
                return 1
            fi
            if systemctl enable --now crond 2>/dev/null; then
                _backup_cron_scheduler_running && return 0
                log_error "crond service did not become active after systemctl enable --now crond."
                return 1
            fi
        fi

        if command_exists service; then
            if service cron start 2>/dev/null; then
                _backup_cron_scheduler_running && return 0
                log_error "cron service did not stay active after service cron start."
                return 1
            fi
            if service crond start 2>/dev/null; then
                _backup_cron_scheduler_running && return 0
                log_error "crond service did not stay active after service crond start."
                return 1
            fi
        fi

        log_error "Unable to start a cron scheduler service (cron/crond)."
        return 1
    }

    if command_exists crontab; then
        if _backup_cron_scheduler_running; then
            return 0
        fi

        log_warn "crontab is available but no active cron scheduler was detected. Attempting to start cron/crond..."
        _backup_start_cron_scheduler || return 1

        if ! _backup_cron_scheduler_running; then
            log_error "cron scheduler is still not active after bootstrap."
            return 1
        fi

        return 0
    fi

    log_warn "crontab command not found. Attempting to install cron scheduler..."
    if declare -f install_packages >/dev/null 2>&1; then
        case "${PKG_MGR:-unknown}" in
            apt)
                install_packages cron || return 1
                ;;
            dnf|yum)
                install_packages cronie || return 1
                ;;
            *)
                log_error "Unsupported package manager for cron bootstrap: ${PKG_MGR:-unknown}"
                return 1
                ;;
        esac
    fi

    if ! command_exists crontab; then
        log_error "crontab is still unavailable after attempted bootstrap."
        return 1
    fi

    _backup_start_cron_scheduler || return 1

    if ! _backup_cron_scheduler_running; then
        log_error "cron scheduler is still not active after bootstrap."
        return 1
    fi

    return 0
}

_backup_read_existing_crontab() {
    local crontab_output=""
    local stderr_file=""
    local status=0
    local stderr_text=""

    stderr_file="$(mktemp)"
    if crontab_output="$(crontab -l 2>"${stderr_file}")"; then
        rm -f "${stderr_file}"
        if [[ -n "${crontab_output}" ]]; then
            printf '%s\n' "${crontab_output}"
        fi
        return 0
    fi
    status=$?
    stderr_text="$(tr -d '\r' < "${stderr_file}")"
    rm -f "${stderr_file}"

    if [[ "${status}" -eq 1 ]] && { [[ -z "${stderr_text}" ]] || grep -qi 'no crontab' <<<"${stderr_text}"; }; then
        return 0
    fi

    log_error "Failed to read current crontab: ${stderr_text:-exit ${status}}"
    return "${status}"
}

###############################################################################
# setup_auto_backup()
#
# Register a daily cron job that runs backup_config() at 03:00 AM.
# The cron entry is idempotent -- calling this function multiple times
# will update the existing entry rather than duplicate it.
###############################################################################
setup_auto_backup() {
    log_step "Setting up automatic daily backup..."

    local script_path
    local backup_log_dir="${LOG_DIR:-/var/log/bifrost}"
    script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/backup.sh"

    if [[ ! -f "${script_path}" ]]; then
        # Fallback: use installed path
        script_path="/opt/bifrost/scripts/backup.sh"
    fi

    local cron_entry="0 3 * * * /usr/bin/env bash ${script_path} backup >> ${backup_log_dir}/backup-cron.log 2>&1"
    local cron_marker="# bifrost-daily-backup"

    # Ensure prerequisites exist before mutating crontab.
    _get_encryption_key > /dev/null
    if ! mkdir -p "${backup_log_dir}"; then
        log_error "Failed to create backup log directory: ${backup_log_dir}"
        return 1
    fi

    _backup_ensure_crontab_available || return 1

    # Remove existing entry if present (idempotent)
    local current_crontab
    current_crontab="$(_backup_read_existing_crontab)" || return 1

    if grep -qF "${cron_marker}" <<<"${current_crontab}"; then
        log_info "Existing backup cron job found. Updating..."
        current_crontab="$(printf '%s\n' "${current_crontab}" | grep -vF "${cron_marker}" || true)"
    fi

    # Add the cron job
    {
        if [[ -n "${current_crontab}" ]]; then
            printf '%s\n' "${current_crontab}"
        fi
        printf '%s %s\n' "${cron_entry}" "${cron_marker}"
    } | crontab -

    log_success "Daily backup cron job registered."
    log_info "  Schedule: Every day at 03:00 AM"
    log_info "  Script:   ${script_path}"
    log_info "  Log:      ${backup_log_dir}/backup-cron.log"
    log_info "  Storage:  ${BACKUP_BASE_DIR} (keep ${BACKUP_MAX_KEEP})"
    log_info "  Key:      ${BACKUP_ENCRYPTION_KEY_FILE}"
    echo ""
    log_info "Verify with: crontab -l | grep backup"
}

###############################################################################
# emergency_ip_rotation()
#
# When Server B's IP address changes (e.g., due to provider migration or
# IP block by GFW), this function updates all relevant configs:
#
#   1. Xray client config (outbound vnext address)
#   2. Mihomo config (proxy server address)
#   3. Server B connection info file
#   4. Restarts affected services
#
# Arguments:
#   $1 - New Server B IP address (required)
###############################################################################
emergency_ip_rotation() {
    local new_ip="${1:-}"

    # Best-effort install of jq for reliable JSON config updates
    if declare -f install_if_missing &>/dev/null && ! command_exists jq; then
        install_if_missing jq jq 2>/dev/null || log_warn "jq install failed. Will use sed fallback for config updates."
    fi

    if [[ -z "${new_ip}" ]]; then
        log_step "Emergency IP Rotation"
        echo ""
        log_info "Enter the new Server B IP address."
        read -r -p "New IP: " new_ip
    fi

    # Validate IP format
    if ! [[ "${new_ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die "Invalid IP address format: ${new_ip}. Expected IPv4 (e.g., 203.0.113.10)."
    fi

    log_step "Emergency IP Rotation: Updating to ${new_ip}"

    # Detect old IP from existing config
    local old_ip="unknown"
    local xray_config="${XRAY_CONFIG_DIR%/}/config.json"
    if [[ -f "${xray_config}" ]] && command_exists jq; then
        old_ip="$(jq -r '.outbounds[]? | select(.tag == "proxy") | .settings.vnext[0].address // empty' "${xray_config}" 2>/dev/null)" || old_ip="unknown"
    elif [[ -f "${xray_config}" ]]; then
        old_ip="$(grep -oP '"address"\s*:\s*"\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "${xray_config}" | head -1)" || old_ip="unknown"
    fi

    if [[ "${old_ip}" == "${new_ip}" ]]; then
        log_warn "New IP (${new_ip}) is the same as current IP. No changes needed."
        return 0
    fi

    log_info "Old Server B IP: ${old_ip}"
    log_info "New Server B IP: ${new_ip}"
    echo ""

    if ! confirm_action "Update all configs from ${old_ip} to ${new_ip}?"; then
        log_info "IP rotation cancelled."
        return 0
    fi

    # Create a backup before making changes
    log_info "Creating pre-rotation backup..."
    if ! backup_config; then
        log_error "Pre-rotation backup failed. Refusing to continue with IP rotation."
        return 1
    fi

    local changes_made=0

    # --- 1. Update Xray client config ---
    if [[ -f "${xray_config}" ]]; then
        log_info "[1/4] Updating Xray client config..."
        cp "${xray_config}" "${xray_config}.bak.$(date +%Y%m%d%H%M%S)"

        if command_exists jq; then
            local tmp_config
            tmp_config="$(mktemp)"
            if jq --arg new_ip "${new_ip}" \
                '(.outbounds[] | select(.tag == "proxy") | .settings.vnext[0].address) = $new_ip' \
                "${xray_config}" > "${tmp_config}" 2>/dev/null && [[ -s "${tmp_config}" ]]; then
                mv "${tmp_config}" "${xray_config}"
                log_success "Xray config updated: address -> ${new_ip}"
                changes_made=$(( changes_made + 1 ))
            else
                rm -f "${tmp_config}"
                log_warn "jq update failed, trying sed fallback..."
                if [[ "${old_ip}" != "unknown" ]]; then
                    sed -i "s/${old_ip}/${new_ip}/g" "${xray_config}"
                    log_success "Xray config updated via sed: ${old_ip} -> ${new_ip}"
                    changes_made=$(( changes_made + 1 ))
                else
                    log_error "Cannot determine old IP for sed replacement."
                fi
            fi
        elif [[ "${old_ip}" != "unknown" ]]; then
            sed -i "s/${old_ip}/${new_ip}/g" "${xray_config}"
            log_success "Xray config updated via sed: ${old_ip} -> ${new_ip}"
            changes_made=$(( changes_made + 1 ))
        else
            log_error "Neither jq nor old IP available for Xray config update."
        fi
    else
        log_warn "[1/4] Xray config not found at ${xray_config}. Skipping."
    fi

    # --- 2. Update Mihomo config ---
    local mihomo_config="${MIHOMO_CONFIG_DIR%/}/config.yaml"
    if [[ ! -f "${mihomo_config}" ]]; then
        mihomo_config="/etc/clash/config.yaml"
    fi

    if [[ -f "${mihomo_config}" ]]; then
        log_info "[2/4] Updating Mihomo/Clash config..."
        cp "${mihomo_config}" "${mihomo_config}.bak.$(date +%Y%m%d%H%M%S)"

        if [[ "${old_ip}" != "unknown" ]]; then
            sed -i "s/${old_ip}/${new_ip}/g" "${mihomo_config}"
            log_success "Mihomo config updated: ${old_ip} -> ${new_ip}"
            changes_made=$(( changes_made + 1 ))
        else
            # Try to find any IP-like pattern in server fields and replace
            # Look for patterns like "server: x.x.x.x" in YAML
            local mihomo_old_ip
            mihomo_old_ip="$(grep -oP 'server:\s*\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "${mihomo_config}" | head -1)" || mihomo_old_ip=""
            if [[ -n "${mihomo_old_ip}" ]]; then
                sed -i "s/${mihomo_old_ip}/${new_ip}/g" "${mihomo_config}"
                log_success "Mihomo config updated: ${mihomo_old_ip} -> ${new_ip}"
                changes_made=$(( changes_made + 1 ))
            else
                log_warn "Could not detect server IP in Mihomo config."
            fi
        fi
    else
        log_info "[2/4] Mihomo/Clash config not found. Skipping."
    fi

    # --- 3. Update Server B connection info file ---
    if [[ -f "${SERVER_B_CONF}" ]]; then
        log_info "[3/4] Updating Server B connection file..."
        cp "${SERVER_B_CONF}" "${SERVER_B_CONF}.bak.$(date +%Y%m%d%H%M%S)"

        if [[ "${old_ip}" != "unknown" ]]; then
            sed -i "s/${old_ip}/${new_ip}/g" "${SERVER_B_CONF}"
        fi
        # Also try updating the explicit SERVER_B_IP= line
        if grep -q "^SERVER_B_IP=" "${SERVER_B_CONF}" 2>/dev/null; then
            sed -i "s/^SERVER_B_IP=.*/SERVER_B_IP=${new_ip}/" "${SERVER_B_CONF}"
        fi
        log_success "Server B connection info updated."
        changes_made=$(( changes_made + 1 ))
    else
        log_info "[3/4] Server B connection file not found. Skipping."
    fi

    if [[ -f "${CONNECTION_INFO}" ]]; then
        cp "${CONNECTION_INFO}" "${CONNECTION_INFO}.bak.$(date +%Y%m%d%H%M%S)"
        if [[ "${old_ip}" != "unknown" ]]; then
            sed -i "s/${old_ip}/${new_ip}/g" "${CONNECTION_INFO}"
        fi
        log_info "Connection info file updated."
    fi

    if [[ ${changes_made} -le 0 ]]; then
        echo ""
        echo "==========================================="
        log_error "No configuration files were updated. IP rotation aborted."
        echo "==========================================="
        return 1
    fi

    # --- 4. Restart services ---
    log_info "[4/4] Restarting services..."
    local restart_ok=true

    if command_exists systemctl; then
        for svc in xray mihomo clash; do
            if systemctl is-active --quiet "${svc}" 2>/dev/null; then
                log_info "Restarting ${svc}..."
                if systemctl restart "${svc}" 2>/dev/null; then
                    sleep 2
                    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
                        log_success "${svc} restarted successfully."
                    else
                        log_error "${svc} failed to start after IP rotation."
                        restart_ok=false
                    fi
                else
                    log_error "Failed to restart ${svc}."
                    restart_ok=false
                fi
            fi
        done
    fi

    echo ""
    echo "==========================================="
    if [[ "${restart_ok}" != "true" ]]; then
        log_error "Some services failed to restart. Check logs."
        log_info "To rollback, restore the latest backup: bash backup.sh restore"
        echo "==========================================="
        return 1
    fi

    # Quick connectivity test
    log_info "Running quick connectivity test..."
    sleep 3
    local test_url="https://api.anthropic.com"
    local http_code
    http_code="$(curl -s -o /dev/null -w '%{http_code}' \
        --proxy 'socks5://127.0.0.1:10808' \
        --connect-timeout 15 --max-time 30 \
        "${test_url}" 2>/dev/null)" || http_code="000"

    if [[ "${http_code}" == "000" ]]; then
        log_error "Connectivity test failed (HTTP ${http_code}). Configuration was updated but tunnel verification failed."
        log_info "Check manually: curl --proxy socks5://127.0.0.1:10808 https://api.anthropic.com"
        log_info "To rollback, restore the latest backup: bash backup.sh restore"
        echo "==========================================="
        return 1
    fi

    log_success "Connectivity test passed. Tunnel is working with new IP."
    log_success "IP rotation complete. Updated ${changes_made} config(s)."
    log_info "  Old IP: ${old_ip}"
    log_info "  New IP: ${new_ip}"
    echo "==========================================="
}

###############################################################################
# manage_backups()
#
# Interactive menu for backup operations.
###############################################################################
manage_backups() {
    while true; do
        echo ""
        echo -e "${BLUE}============================================${NC}"
        echo -e "${BLUE}  Bifrost - Backup Management     ${NC}"
        echo -e "${BLUE}============================================${NC}"
        echo ""
        echo "  1) Create backup now"
        echo "  2) List & restore from backup"
        echo "  3) Setup automatic daily backup"
        echo "  4) Emergency IP rotation"
        echo "  5) List existing backups"
        echo "  0) Exit"
        echo ""
        read -r -p "Select option [0-5]: " choice

        case "${choice}" in
            1)
                echo ""
                backup_config
                ;;
            2)
                echo ""
                restore_config
                ;;
            3)
                echo ""
                setup_auto_backup
                ;;
            4)
                echo ""
                emergency_ip_rotation
                ;;
            5)
                echo ""
                _ensure_backup_dir
                local -a files=()
                while IFS= read -r f; do
                    files+=("${f}")
                done < <(find "${BACKUP_BASE_DIR}" -maxdepth 1 -name "backup-*.tar.gz.enc" -type f 2>/dev/null | sort -r)

                if [[ ${#files[@]} -eq 0 ]]; then
                    log_info "No backups found."
                else
                    echo -e "${BOLD}Existing backups (${#files[@]}):${NC}"
                    for f in ${files[@]+"${files[@]}"}; do
                        local sz
                        sz="$(du -h "${f}" | awk '{print $1}')"
                        printf "  %s  %s\n" "${sz}" "$(basename "${f}")"
                    done
                fi
                ;;
            0|q|Q|exit)
                log_info "Exiting backup management."
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
        backup)
            backup_config
            ;;
        restore)
            restore_config
            ;;
        auto)
            setup_auto_backup
            ;;
        rotate-ip)
            emergency_ip_rotation "${2:-}"
            ;;
        help|--help|-h)
            echo "Bifrost - Backup Management"
            echo ""
            echo "Usage:"
            echo "  $0                  # Interactive menu"
            echo "  $0 backup           # Create encrypted backup"
            echo "  $0 restore          # List & restore from backup"
            echo "  $0 auto             # Setup daily cron backup"
            echo "  $0 rotate-ip <IP>   # Emergency IP rotation"
            echo "  $0 help             # Show this help"
            ;;
        "")
            manage_backups
            ;;
        *)
            log_error "Unknown command: $1"
            echo "Run '$0 help' for usage information."
            exit 1
            ;;
    esac
fi
