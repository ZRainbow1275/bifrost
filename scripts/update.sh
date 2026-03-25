#!/usr/bin/env bash
###############################################################################
# Bifrost - Component Update Module
#
# Safely updates all Bifrost components to their latest versions.
#
# Functions:
#   update_xray()      - Update Xray-core to latest release
#   update_mihomo()    - Update Mihomo (Clash.Meta) to latest release
#   update_new_api()   - Update New API Docker container (docker pull)
#   update_geoip()     - Update GeoIP/GeoSite databases for routing
#   check_updates()    - Compare installed vs latest versions (dry run)
#   update_all()       - Update all components in safe dependency order
#
# Usage:
#   bash scripts/update.sh              # Interactive menu
#   bash scripts/update.sh check        # Check for updates
#   bash scripts/update.sh xray         # Update Xray only
#   bash scripts/update.sh mihomo       # Update Mihomo only
#   bash scripts/update.sh new-api      # Update New API only
#   bash scripts/update.sh geoip        # Update GeoIP databases
#   bash scripts/update.sh all          # Update everything
#
# Dependencies: scripts/common.sh, curl, jq
###############################################################################

set -euo pipefail

# Guard against double-sourcing (readonly variables would conflict)
if [[ -n "${_UPDATE_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
readonly _UPDATE_SH_LOADED=1

# Resolve the directory this script resides in
_UPD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_UPD_PROJECT_DIR="$(cd "${_UPD_SCRIPT_DIR}/.." && pwd)"

# Source common utilities
if [[ -f "${_UPD_SCRIPT_DIR}/common.sh" ]]; then
    # shellcheck source=scripts/common.sh
    source "${_UPD_SCRIPT_DIR}/common.sh"
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
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_GEODATA_DIR="/usr/local/share/xray"
XRAY_INSTALL_SCRIPT_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
XRAY_RELEASES_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"

MIHOMO_BIN="/usr/local/bin/mihomo"
MIHOMO_CONFIG_DIR="/etc/mihomo"
MIHOMO_RELEASES_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"

GEOIP_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
GEOSITE_URL="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

NEW_API_IMAGES=("justsong/new-api" "calciumion/new-api")
NEW_API_CONTAINER_NAMES=("new-api" "newapi" "one-api" "oneapi")

# =============================================================================
# Internal helpers
# =============================================================================

###############################################################################
# _get_github_latest_version()
#
# Query GitHub API for the latest release tag of a repository.
#
# Arguments:
#   $1 - GitHub API releases URL (e.g., https://api.github.com/repos/OWNER/REPO/releases/latest)
# Returns: version string via stdout (e.g., "1.8.24"), empty on failure.
###############################################################################
_get_github_latest_version() {
    local api_url="${1:?}"
    local version=""

    if command_exists curl && command_exists jq; then
        version="$(curl -s --connect-timeout 10 --max-time 20 "${api_url}" 2>/dev/null \
            | jq -r '.tag_name // empty' 2>/dev/null)" || version=""
    elif command_exists curl; then
        # Fallback without jq: extract tag_name from JSON manually
        version="$(curl -s --connect-timeout 10 --max-time 20 "${api_url}" 2>/dev/null \
            | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -1)" || version=""
    fi

    # If direct API request failed, try via ghproxy.net mirror (China fallback)
    if [[ -z "${version}" ]] && command_exists curl; then
        log_warn "GitHub API unreachable directly. Trying mirror for version lookup..."
        if command_exists jq; then
            version="$(curl -s --connect-timeout 10 --max-time 20 "https://ghproxy.net/${api_url}" 2>/dev/null \
                | jq -r '.tag_name // empty' 2>/dev/null)" || version=""
        else
            version="$(curl -s --connect-timeout 10 --max-time 20 "https://ghproxy.net/${api_url}" 2>/dev/null \
                | grep -oP '"tag_name"\s*:\s*"\K[^"]+' | head -1)" || version=""
        fi
    fi

    # Strip leading 'v' if present
    version="${version#v}"
    echo "${version}"
}

###############################################################################
# _get_installed_xray_version()
#
# Returns the currently installed Xray version, or "not_installed".
###############################################################################
_get_installed_xray_version() {
    if [[ -x "${XRAY_BIN}" ]]; then
        local ver
        ver="$("${XRAY_BIN}" version 2>/dev/null | head -1 | awk '{print $2}')" || ver=""
        ver="${ver#v}"
        echo "${ver:-unknown}"
    else
        echo "not_installed"
    fi
}

###############################################################################
# _get_installed_mihomo_version()
#
# Returns the currently installed Mihomo version, or "not_installed".
###############################################################################
_get_installed_mihomo_version() {
    if [[ -x "${MIHOMO_BIN}" ]]; then
        local ver
        ver="$("${MIHOMO_BIN}" -v 2>/dev/null | head -1 | grep -oP 'v?\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)" || ver=""
        echo "${ver:-unknown}"
    else
        echo "not_installed"
    fi
}

###############################################################################
# _get_new_api_local_image_id()
#
# Returns the Docker image ID of the currently running New API container,
# or "not_found".
###############################################################################
_get_new_api_local_image_id() {
    if ! command_exists docker || ! docker info &>/dev/null; then
        echo "docker_unavailable"
        return
    fi

    for name in ${NEW_API_CONTAINER_NAMES[@]+"${NEW_API_CONTAINER_NAMES[@]}"}; do
        local image_id
        image_id="$(docker inspect --format '{{.Image}}' "${name}" 2>/dev/null)" || continue
        if [[ -n "${image_id}" ]]; then
            echo "${image_id}"
            return
        fi
    done
    echo "not_found"
}

###############################################################################
# _pre_update_check()
#
# Common pre-update validation:
#   - Require root
#   - Check internet connectivity
#   - Ensure curl is available
###############################################################################
_pre_update_check() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "Updates must be run as root. Use: sudo $0"
    fi

    if ! command_exists curl; then
        die "curl is required for updates but not found."
    fi

    # Quick connectivity check (try GitHub directly, then via mirror)
    if ! curl -s --connect-timeout 5 --max-time 10 -o /dev/null "https://api.github.com" 2>/dev/null; then
        if curl -s --connect-timeout 5 --max-time 10 -o /dev/null "https://ghproxy.net/https://api.github.com" 2>/dev/null; then
            log_info "GitHub API not directly reachable but accessible via mirror. Proceeding with mirror support."
        else
            log_warn "Cannot reach GitHub API (direct or mirror). Check internet connectivity."
            if ! confirm_action "Continue anyway?"; then
                return 1
            fi
        fi
    fi
}

###############################################################################
# update_xray()
#
# Update Xray-core to the latest release.
#
# Steps:
#   1. Check current version vs latest GitHub release
#   2. If already latest, skip (unless --force)
#   3. Download and run the official Xray install script
#   4. Preserve existing config (the install script doesn't touch it)
#   5. Restart Xray service
#   6. Verify the updated version
###############################################################################
update_xray() {
    log_step "Updating Xray-core..."

    local current_ver
    current_ver="$(_get_installed_xray_version)"

    if [[ "${current_ver}" == "not_installed" ]]; then
        log_warn "Xray is not installed. Use install.sh to deploy it first."
        return 1
    fi

    local latest_ver
    latest_ver="$(_get_github_latest_version "${XRAY_RELEASES_API}")"

    if [[ -z "${latest_ver}" ]]; then
        log_warn "Could not determine latest Xray version from GitHub."
        if ! confirm_action "Proceed with reinstall anyway?"; then
            return 1
        fi
    else
        log_info "Current version: ${current_ver}"
        log_info "Latest version:  ${latest_ver}"

        if [[ "${current_ver}" == "${latest_ver}" ]]; then
            log_success "Xray is already at the latest version (${current_ver}). No update needed."
            return 0
        fi
    fi

    if ! confirm_action "Update Xray from ${current_ver} to ${latest_ver:-latest}?"; then
        log_info "Xray update cancelled."
        return 0
    fi

    # Backup current binary
    if [[ -x "${XRAY_BIN}" ]]; then
        cp "${XRAY_BIN}" "${XRAY_BIN}.bak.$(date +%Y%m%d%H%M%S)"
        log_info "Current Xray binary backed up."
    fi

    # Download and run official installer
    log_info "Running Xray official install script..."
    local tmp_script
    tmp_script="$(mktemp /tmp/xray-install.XXXXXX.sh)"

    if ! github_download "${XRAY_INSTALL_SCRIPT_URL}" "${tmp_script}" 60; then
        rm -f "${tmp_script}"
        die "Failed to download Xray install script from all sources (direct + mirrors)."
    fi

    chmod +x "${tmp_script}"
    if ! bash "${tmp_script}"; then
        rm -f "${tmp_script}"
        log_error "Xray install script failed. Attempting to restore backup..."
        local latest_backup
        latest_backup="$(ls -t "${XRAY_BIN}".bak.* 2>/dev/null | head -1)"
        if [[ -n "${latest_backup}" ]]; then
            cp "${latest_backup}" "${XRAY_BIN}"
            chmod +x "${XRAY_BIN}"
            log_warn "Backup restored."
        fi
        return 1
    fi
    rm -f "${tmp_script}"

    # Restart Xray
    if command_exists systemctl && systemctl is-enabled --quiet xray 2>/dev/null; then
        log_info "Restarting Xray service..."
        systemctl restart xray
        sleep 2
        if systemctl is-active --quiet xray; then
            log_success "Xray service restarted successfully."
        else
            log_error "Xray failed to start after update."
            log_info "Check: journalctl -u xray --no-pager -n 30"
            return 1
        fi
    fi

    # Verify version
    local new_ver
    new_ver="$(_get_installed_xray_version)"
    log_success "Xray updated: ${current_ver} -> ${new_ver}"

    # Cascade restart: Mihomo depends on Xray as its upstream SOCKS5 proxy.
    # If Xray was restarted, Mihomo should be restarted to re-establish the connection.
    if command_exists systemctl && systemctl is-active --quiet mihomo 2>/dev/null; then
        log_info "Restarting Mihomo (depends on Xray upstream)..."
        systemctl restart mihomo 2>/dev/null || log_warn "Failed to restart Mihomo."
        sleep 2
        if systemctl is-active --quiet mihomo 2>/dev/null; then
            log_success "Mihomo restarted successfully."
        else
            log_warn "Mihomo failed to restart after Xray update. Check: journalctl -u mihomo --no-pager -n 30"
        fi
    fi
}

###############################################################################
# update_mihomo()
#
# Update Mihomo (Clash.Meta) to the latest release.
#
# Steps:
#   1. Detect architecture
#   2. Check current vs latest version
#   3. Download the correct binary for this platform
#   4. Replace binary, preserve config
#   5. Restart service
###############################################################################
update_mihomo() {
    log_step "Updating Mihomo (Clash.Meta)..."

    # Ensure jq is available (required for parsing GitHub release API response)
    if declare -f install_if_missing &>/dev/null; then
        install_if_missing jq jq
        install_if_missing curl curl
        install_if_missing gzip gzip
    elif ! command_exists jq; then
        log_error "jq is required for Mihomo update but not installed. Run: apt install jq / dnf install jq"
        return 1
    fi

    local current_ver
    current_ver="$(_get_installed_mihomo_version)"

    if [[ "${current_ver}" == "not_installed" ]]; then
        log_warn "Mihomo is not installed. Skipping."
        return 1
    fi

    local latest_ver
    latest_ver="$(_get_github_latest_version "${MIHOMO_RELEASES_API}")"

    if [[ -z "${latest_ver}" ]]; then
        log_warn "Could not determine latest Mihomo version."
        if ! confirm_action "Proceed with reinstall anyway?"; then
            return 1
        fi
    else
        log_info "Current version: ${current_ver}"
        log_info "Latest version:  ${latest_ver}"

        if [[ "${current_ver}" == "${latest_ver}" ]]; then
            log_success "Mihomo is already at the latest version (${current_ver}). No update needed."
            return 0
        fi
    fi

    if ! confirm_action "Update Mihomo from ${current_ver} to ${latest_ver:-latest}?"; then
        log_info "Mihomo update cancelled."
        return 0
    fi

    # Detect architecture
    local arch
    arch="$(uname -m)"
    local mihomo_arch=""
    case "${arch}" in
        x86_64)  mihomo_arch="linux-amd64" ;;
        aarch64) mihomo_arch="linux-arm64" ;;
        armv7l)  mihomo_arch="linux-armv7" ;;
        *)
            die "Unsupported architecture for Mihomo: ${arch}"
            ;;
    esac

    # Download the latest binary
    local download_url
    if [[ -n "${latest_ver}" ]]; then
        download_url="https://github.com/MetaCubeX/mihomo/releases/download/v${latest_ver}/mihomo-${mihomo_arch}-v${latest_ver}.gz"
    else
        # Get download URL from API (try direct, then mirror)
        download_url="$(curl -s --connect-timeout 10 --max-time 20 "${MIHOMO_RELEASES_API}" 2>/dev/null \
            | jq -r ".assets[] | select(.name | test(\"${mihomo_arch}\")) | select(.name | endswith(\".gz\")) | .browser_download_url" \
            | head -1)" || download_url=""
        if [[ -z "${download_url}" ]]; then
            log_warn "GitHub API unreachable. Trying mirror for Mihomo release info..."
            download_url="$(curl -s --connect-timeout 10 --max-time 20 "https://ghproxy.net/${MIHOMO_RELEASES_API}" 2>/dev/null \
                | jq -r ".assets[] | select(.name | test(\"${mihomo_arch}\")) | select(.name | endswith(\".gz\")) | .browser_download_url" \
                | head -1)" || download_url=""
        fi
    fi

    if [[ -z "${download_url}" ]]; then
        die "Could not determine Mihomo download URL for ${mihomo_arch}."
    fi

    log_info "Downloading from: ${download_url} (with China mirror fallback)"

    local tmp_dir
    tmp_dir="$(mktemp -d /tmp/mihomo-update.XXXXXX)"
    local tmp_gz="${tmp_dir}/mihomo.gz"

    if ! github_download "${download_url}" "${tmp_gz}" 120; then
        rm -rf "${tmp_dir}"
        die "Failed to download Mihomo binary from all sources (direct + mirrors)."
    fi

    # Decompress
    gzip -d "${tmp_gz}" 2>/dev/null || gunzip "${tmp_gz}" 2>/dev/null || {
        rm -rf "${tmp_dir}"
        die "Failed to decompress Mihomo binary."
    }

    local tmp_bin="${tmp_gz%.gz}"
    if [[ ! -f "${tmp_bin}" ]]; then
        # The decompressed file might have a different name
        tmp_bin="$(find "${tmp_dir}" -type f ! -name '*.gz' | head -1)"
    fi

    if [[ -z "${tmp_bin}" || ! -f "${tmp_bin}" ]]; then
        rm -rf "${tmp_dir}"
        die "Decompressed Mihomo binary not found."
    fi

    # Backup current binary
    if [[ -x "${MIHOMO_BIN}" ]]; then
        cp "${MIHOMO_BIN}" "${MIHOMO_BIN}.bak.$(date +%Y%m%d%H%M%S)"
    fi

    # Stop service before replacing binary
    if command_exists systemctl && systemctl is-active --quiet mihomo 2>/dev/null; then
        systemctl stop mihomo
    fi

    # Install new binary
    chmod +x "${tmp_bin}"
    mv "${tmp_bin}" "${MIHOMO_BIN}"
    rm -rf "${tmp_dir}"

    # Restart service
    if command_exists systemctl && systemctl is-enabled --quiet mihomo 2>/dev/null; then
        log_info "Restarting Mihomo service..."
        systemctl restart mihomo
        sleep 2
        if systemctl is-active --quiet mihomo; then
            log_success "Mihomo service restarted successfully."
        else
            log_error "Mihomo failed to start after update."
            log_info "Check: journalctl -u mihomo --no-pager -n 30"
            return 1
        fi
    fi

    local new_ver
    new_ver="$(_get_installed_mihomo_version)"
    log_success "Mihomo updated: ${current_ver} -> ${new_ver}"

    # Cascade restart: New API Docker container depends on Mihomo as its HTTP proxy.
    # Restarting Mihomo may briefly disrupt the proxy; restart New API to reconnect.
    if command_exists docker && docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^new-api$'; then
        log_info "Restarting New API container (depends on Mihomo proxy)..."
        local new_api_dir="/opt/new-api"
        if [[ -f "${new_api_dir}/docker-compose.yml" ]]; then
            (cd "${new_api_dir}" && docker compose restart new-api 2>/dev/null) || log_warn "Failed to restart New API container."
        else
            docker restart new-api 2>/dev/null || log_warn "Failed to restart New API container."
        fi
    fi
}

###############################################################################
# update_new_api()
#
# Update the New API Docker container by pulling the latest image.
#
# Steps:
#   1. Identify the running container and its image
#   2. docker pull the latest image
#   3. Compare image IDs to check for actual update
#   4. Recreate the container with the same settings
#   5. Start and verify
###############################################################################
update_new_api() {
    log_step "Updating New API Docker container..."

    if ! command_exists docker; then
        log_warn "Docker is not installed. Cannot update New API."
        return 1
    fi

    if ! docker info &>/dev/null; then
        log_warn "Docker daemon is not running."
        return 1
    fi

    # Find the running container
    local container_name=""
    local container_image=""
    for name in ${NEW_API_CONTAINER_NAMES[@]+"${NEW_API_CONTAINER_NAMES[@]}"}; do
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qw "${name}"; then
            container_name="${name}"
            container_image="$(docker inspect --format '{{.Config.Image}}' "${name}" 2>/dev/null)" || container_image=""
            break
        fi
    done

    if [[ -z "${container_name}" ]]; then
        log_warn "No New API container found (checked: ${NEW_API_CONTAINER_NAMES[*]})."
        return 1
    fi

    if [[ -z "${container_image}" ]]; then
        # Try default images
        for img in ${NEW_API_IMAGES[@]+"${NEW_API_IMAGES[@]}"}; do
            if docker images --format '{{.Repository}}' 2>/dev/null | grep -q "${img}"; then
                container_image="${img}:latest"
                break
            fi
        done
    fi

    if [[ -z "${container_image}" ]]; then
        container_image="${NEW_API_IMAGES[0]}:latest"
        log_warn "Could not detect image. Defaulting to: ${container_image}"
    fi

    log_info "Container: ${container_name}"
    log_info "Image:     ${container_image}"

    # Record current image ID for comparison
    local old_image_id
    old_image_id="$(docker inspect --format '{{.Image}}' "${container_name}" 2>/dev/null)" || old_image_id=""

    # Pull latest image
    log_info "Pulling latest image: ${container_image}..."
    if ! docker pull "${container_image}"; then
        log_error "Failed to pull image: ${container_image}"
        return 1
    fi

    # Check if the image actually changed
    local new_image_id
    new_image_id="$(docker inspect --format '{{.Id}}' "${container_image}" 2>/dev/null)" || new_image_id=""

    if [[ -n "${old_image_id}" && -n "${new_image_id}" && "${old_image_id}" == "${new_image_id}" ]]; then
        log_success "New API image is already up to date. No container restart needed."
        return 0
    fi

    log_info "New image detected. Recreating container..."

    if ! confirm_action "Recreate ${container_name} with updated image?"; then
        log_info "New API update cancelled. The new image has been pulled but the container was not updated."
        return 0
    fi

    # Check if docker-compose is available and a compose file exists
    local compose_file=""
    for dir in "/opt/new-api" "/opt/bifrost/new-api" "/opt/bifrost/docker"; do
        if [[ -f "${dir}/docker-compose.yml" ]]; then
            compose_file="${dir}/docker-compose.yml"
            break
        fi
        if [[ -f "${dir}/docker-compose.yaml" ]]; then
            compose_file="${dir}/docker-compose.yaml"
            break
        fi
    done

    if [[ -n "${compose_file}" ]] && docker compose version &>/dev/null; then
        log_info "Using docker compose to recreate container..."
        local compose_dir
        compose_dir="$(dirname "${compose_file}")"
        (cd "${compose_dir}" && docker compose pull && docker compose up -d --force-recreate)
    else
        # Manual container recreation: capture current run params
        log_info "Recreating container manually..."

        # Extract the container's environment, ports, volumes, and restart policy
        local env_args=""
        local port_args=""
        local volume_args=""
        local restart_policy=""

        # Environment variables
        while IFS= read -r env_line; do
            if [[ -n "${env_line}" && "${env_line}" != "null" ]]; then
                env_args+=" -e ${env_line}"
            fi
        done < <(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${container_name}" 2>/dev/null)

        # Port mappings
        while IFS= read -r port_line; do
            if [[ -n "${port_line}" && "${port_line}" != "null" ]]; then
                port_args+=" -p ${port_line}"
            fi
        done < <(docker inspect --format '{{range $p, $conf := .NetworkSettings.Ports}}{{range $conf}}{{.HostIp}}:{{.HostPort}}:{{$p}}{{"\n"}}{{end}}{{end}}' "${container_name}" 2>/dev/null | sed 's|/tcp||g; s|0.0.0.0:||g')

        # Volume mounts
        while IFS= read -r vol_line; do
            if [[ -n "${vol_line}" && "${vol_line}" != "null" ]]; then
                volume_args+=" -v ${vol_line}"
            fi
        done < <(docker inspect --format '{{range .Mounts}}{{.Source}}:{{.Destination}}{{"\n"}}{{end}}' "${container_name}" 2>/dev/null)

        # Restart policy
        restart_policy="$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "${container_name}" 2>/dev/null)" || restart_policy="unless-stopped"
        if [[ -z "${restart_policy}" || "${restart_policy}" == "no" ]]; then
            restart_policy="unless-stopped"
        fi

        # Stop and remove old container
        docker stop "${container_name}" 2>/dev/null || true
        docker rm "${container_name}" 2>/dev/null || true

        # Recreate container
        local run_cmd="docker run -d --name ${container_name} --restart=${restart_policy}"
        run_cmd+="${env_args}${port_args}${volume_args}"
        run_cmd+=" ${container_image}"

        log_info "Running: ${run_cmd}"
        eval "${run_cmd}" || {
            log_error "Failed to recreate container."
            return 1
        }
    fi

    # Wait for container to be healthy
    sleep 5
    if docker ps --filter "name=${container_name}" --filter "status=running" --format '{{.Names}}' 2>/dev/null | grep -qw "${container_name}"; then
        log_success "New API container updated and running."
    else
        log_error "New API container is not running after update."
        log_info "Check: docker logs ${container_name}"
        return 1
    fi

    # Quick health check
    local api_code
    api_code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "http://127.0.0.1:3000/api/status" 2>/dev/null)" || api_code="000"
    if [[ "${api_code}" != "000" ]]; then
        log_success "New API health check passed (HTTP ${api_code})."
    else
        log_warn "New API health check returned HTTP ${api_code}. The service may still be starting up."
    fi
}

###############################################################################
# update_geoip()
#
# Update the GeoIP and GeoSite databases used by Xray for domain/IP routing.
# Downloads from Loyalsoldier's maintained rule sets on GitHub.
###############################################################################
update_geoip() {
    log_step "Updating GeoIP/GeoSite databases..."

    if [[ ! -d "${XRAY_GEODATA_DIR}" ]]; then
        log_warn "Xray geodata directory not found at ${XRAY_GEODATA_DIR}."
        if [[ -x "${XRAY_BIN}" ]]; then
            mkdir -p "${XRAY_GEODATA_DIR}"
        else
            log_warn "Xray is not installed. Skipping GeoIP update."
            return 1
        fi
    fi

    local geoip_file="${XRAY_GEODATA_DIR}/geoip.dat"
    local geosite_file="${XRAY_GEODATA_DIR}/geosite.dat"

    # Show current file dates
    if [[ -f "${geoip_file}" ]]; then
        local geoip_date
        geoip_date="$(stat -c '%y' "${geoip_file}" 2>/dev/null | cut -d. -f1)"
        if [[ -z "${geoip_date}" ]]; then
            geoip_date="$(date -r "${geoip_file}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'unknown')"
        fi
        log_info "Current geoip.dat date: ${geoip_date}"
    fi
    if [[ -f "${geosite_file}" ]]; then
        local geosite_date
        geosite_date="$(stat -c '%y' "${geosite_file}" 2>/dev/null | cut -d. -f1)"
        if [[ -z "${geosite_date}" ]]; then
            geosite_date="$(date -r "${geosite_file}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'unknown')"
        fi
        log_info "Current geosite.dat date: ${geosite_date}"
    fi

    # Backup current files
    for f in "${geoip_file}" "${geosite_file}"; do
        if [[ -f "${f}" ]]; then
            cp "${f}" "${f}.bak.$(date +%Y%m%d%H%M%S)"
        fi
    done

    # Download geoip.dat
    log_info "Downloading geoip.dat..."
    local tmp_geoip
    tmp_geoip="$(mktemp /tmp/geoip.XXXXXX.dat)"
    if github_download "${GEOIP_URL}" "${tmp_geoip}" 120 && [[ -s "${tmp_geoip}" ]]; then
        mv "${tmp_geoip}" "${geoip_file}"
        chmod 644 "${geoip_file}"
        log_success "geoip.dat updated ($(du -h "${geoip_file}" | awk '{print $1}'))."
    else
        rm -f "${tmp_geoip}"
        log_error "Failed to download geoip.dat."
    fi

    # Download geosite.dat
    log_info "Downloading geosite.dat..."
    local tmp_geosite
    tmp_geosite="$(mktemp /tmp/geosite.XXXXXX.dat)"
    if github_download "${GEOSITE_URL}" "${tmp_geosite}" 120 && [[ -s "${tmp_geosite}" ]]; then
        mv "${tmp_geosite}" "${geosite_file}"
        chmod 644 "${geosite_file}"
        log_success "geosite.dat updated ($(du -h "${geosite_file}" | awk '{print $1}'))."
    else
        rm -f "${tmp_geosite}"
        log_error "Failed to download geosite.dat."
    fi

    # Also update Mihomo's geodata directory (country.mmdb + its own geoip/geosite).
    # Mihomo uses MetaCubeX-maintained databases stored in /etc/mihomo/.
    if [[ -d "${MIHOMO_CONFIG_DIR}" ]]; then
        log_info "Updating Mihomo geodata (country.mmdb, geoip.dat, geosite.dat)..."
        local mihomo_country_url="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/country.mmdb"
        local mihomo_geoip_url="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.dat"
        local mihomo_geosite_url="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat"

        for entry in \
            "${mihomo_country_url}|${MIHOMO_CONFIG_DIR}/country.mmdb" \
            "${mihomo_geoip_url}|${MIHOMO_CONFIG_DIR}/geoip.dat" \
            "${mihomo_geosite_url}|${MIHOMO_CONFIG_DIR}/geosite.dat"
        do
            local url="${entry%%|*}"
            local dest="${entry##*|}"
            local fname
            fname="$(basename "${dest}")"
            local tmp_dl
            tmp_dl="$(mktemp /tmp/${fname}.XXXXXX)"
            if github_download "${url}" "${tmp_dl}" 120 && [[ -s "${tmp_dl}" ]]; then
                mv "${tmp_dl}" "${dest}"
                chmod 644 "${dest}"
                log_success "Mihomo ${fname} updated."
            else
                rm -f "${tmp_dl}"
                log_warn "Failed to download Mihomo ${fname}. Skipping."
            fi
        done

        # Reload Mihomo to apply new databases
        if command_exists systemctl && systemctl is-active --quiet mihomo 2>/dev/null; then
            log_info "Reloading Mihomo to apply updated geodata..."
            systemctl restart mihomo 2>/dev/null || log_warn "Failed to restart Mihomo after geodata update."
        fi
    fi

    # Restart Xray to use new databases
    if command_exists systemctl && systemctl is-active --quiet xray 2>/dev/null; then
        log_info "Restarting Xray to load updated databases..."
        systemctl restart xray
        sleep 2
        if systemctl is-active --quiet xray; then
            log_success "Xray restarted with updated GeoIP/GeoSite data."
        else
            log_error "Xray failed to restart after GeoIP update."
            return 1
        fi
    fi
}

###############################################################################
# check_updates()
#
# Dry-run: check current vs latest versions for all components without
# making any changes. Displays a summary table.
###############################################################################
check_updates() {
    log_step "Checking for updates..."
    echo ""

    local updates_available=0

    # --- Xray ---
    local xray_current xray_latest xray_status
    xray_current="$(_get_installed_xray_version)"
    if [[ "${xray_current}" == "not_installed" ]]; then
        xray_latest="-"
        xray_status="not installed"
    else
        xray_latest="$(_get_github_latest_version "${XRAY_RELEASES_API}")"
        if [[ -z "${xray_latest}" ]]; then
            xray_status="check failed"
        elif [[ "${xray_current}" == "${xray_latest}" ]]; then
            xray_status="up to date"
        else
            xray_status="UPDATE AVAILABLE"
            updates_available=$(( updates_available + 1 ))
        fi
    fi

    # --- Mihomo ---
    local mihomo_current mihomo_latest mihomo_status
    mihomo_current="$(_get_installed_mihomo_version)"
    if [[ "${mihomo_current}" == "not_installed" ]]; then
        mihomo_latest="-"
        mihomo_status="not installed"
    else
        mihomo_latest="$(_get_github_latest_version "${MIHOMO_RELEASES_API}")"
        if [[ -z "${mihomo_latest}" ]]; then
            mihomo_status="check failed"
        elif [[ "${mihomo_current}" == "${mihomo_latest}" ]]; then
            mihomo_status="up to date"
        else
            mihomo_status="UPDATE AVAILABLE"
            updates_available=$(( updates_available + 1 ))
        fi
    fi

    # --- New API (Docker) ---
    local newapi_status="not found"
    local newapi_current="-"
    local newapi_latest="-"
    if command_exists docker && docker info &>/dev/null; then
        for name in ${NEW_API_CONTAINER_NAMES[@]+"${NEW_API_CONTAINER_NAMES[@]}"}; do
            if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qw "${name}"; then
                local img
                img="$(docker inspect --format '{{.Config.Image}}' "${name}" 2>/dev/null)" || img=""
                if [[ -n "${img}" ]]; then
                    newapi_current="${img}"
                    # Check if there's a newer image available
                    local local_id remote_id
                    local_id="$(docker inspect --format '{{.Image}}' "${name}" 2>/dev/null)" || local_id=""
                    # Pull quietly to check for updates
                    if docker pull "${img}" 2>/dev/null | grep -q "Status: Image is up to date"; then
                        newapi_status="up to date"
                    else
                        newapi_status="UPDATE AVAILABLE"
                        updates_available=$(( updates_available + 1 ))
                    fi
                    newapi_latest="${img} (latest)"
                fi
                break
            fi
        done
    fi

    # --- GeoIP ---
    local geoip_status="unknown"
    local geoip_date="-"
    if [[ -f "${XRAY_GEODATA_DIR}/geoip.dat" ]]; then
        geoip_date="$(stat -c '%y' "${XRAY_GEODATA_DIR}/geoip.dat" 2>/dev/null | cut -d. -f1)"
        if [[ -z "${geoip_date}" ]]; then
            geoip_date="$(date -r "${XRAY_GEODATA_DIR}/geoip.dat" '+%Y-%m-%d' 2>/dev/null || echo 'unknown')"
        fi
        # Consider outdated if older than 7 days
        local geoip_epoch
        geoip_epoch="$(stat -c '%Y' "${XRAY_GEODATA_DIR}/geoip.dat" 2>/dev/null)" || geoip_epoch=0
        local now_epoch
        now_epoch="$(date +%s)"
        local age_days=$(( (now_epoch - geoip_epoch) / 86400 ))
        if (( age_days > 7 )); then
            geoip_status="STALE (${age_days} days old)"
            updates_available=$(( updates_available + 1 ))
        else
            geoip_status="recent (${age_days} days old)"
        fi
    else
        geoip_status="not found"
    fi

    # Print summary table
    echo "==========================================="
    printf "  ${BOLD}%-15s %-15s %-15s %-20s${NC}\n" "Component" "Current" "Latest" "Status"
    echo "-------------------------------------------"
    printf "  %-15s %-15s %-15s " "Xray" "${xray_current}" "${xray_latest:-?}"
    if [[ "${xray_status}" == *"AVAILABLE"* ]]; then
        echo -e "${YELLOW}${xray_status}${NC}"
    elif [[ "${xray_status}" == "up to date" ]]; then
        echo -e "${GREEN}${xray_status}${NC}"
    else
        echo "${xray_status}"
    fi

    printf "  %-15s %-15s %-15s " "Mihomo" "${mihomo_current}" "${mihomo_latest:-?}"
    if [[ "${mihomo_status}" == *"AVAILABLE"* ]]; then
        echo -e "${YELLOW}${mihomo_status}${NC}"
    elif [[ "${mihomo_status}" == "up to date" ]]; then
        echo -e "${GREEN}${mihomo_status}${NC}"
    else
        echo "${mihomo_status}"
    fi

    printf "  %-15s %-15s %-15s " "New API" "-" "-"
    if [[ "${newapi_status}" == *"AVAILABLE"* ]]; then
        echo -e "${YELLOW}${newapi_status}${NC}"
    elif [[ "${newapi_status}" == "up to date" ]]; then
        echo -e "${GREEN}${newapi_status}${NC}"
    else
        echo "${newapi_status}"
    fi

    printf "  %-15s %-15s %-15s " "GeoIP/Site" "${geoip_date}" "-"
    if [[ "${geoip_status}" == *"STALE"* ]]; then
        echo -e "${YELLOW}${geoip_status}${NC}"
    elif [[ "${geoip_status}" == "recent"* ]]; then
        echo -e "${GREEN}${geoip_status}${NC}"
    else
        echo "${geoip_status}"
    fi

    echo "==========================================="
    echo ""

    if (( updates_available > 0 )); then
        log_info "${updates_available} update(s) available."
        log_info "Run: bash update.sh all   to update everything."
    else
        log_success "All components are up to date."
    fi
}

###############################################################################
# update_all()
#
# Update all components in a safe dependency order:
#   1. GeoIP databases (no service dependency)
#   2. Xray (core proxy, restart needed)
#   3. Mihomo (if installed)
#   4. New API (Docker container, independent)
#
# Each update step catches failures and continues to the next.
###############################################################################
update_all() {
    log_step "Updating all Bifrost components..."
    echo ""
    log_info "Update order: GeoIP -> Xray -> Mihomo -> New API"
    echo ""

    if ! confirm_action "Proceed with updating all components?"; then
        log_info "Update cancelled."
        return 0
    fi

    _pre_update_check || return 1

    local total_ok=0
    local total_fail=0
    local total_skip=0

    # 1. GeoIP (no dependency)
    echo ""
    if update_geoip; then
        total_ok=$(( total_ok + 1 ))
    else
        total_fail=$(( total_fail + 1 ))
    fi

    # 2. Xray
    echo ""
    local xray_ver
    xray_ver="$(_get_installed_xray_version)"
    if [[ "${xray_ver}" == "not_installed" ]]; then
        log_info "Xray not installed. Skipping."
        total_skip=$(( total_skip + 1 ))
    elif update_xray; then
        total_ok=$(( total_ok + 1 ))
    else
        total_fail=$(( total_fail + 1 ))
    fi

    # 3. Mihomo
    echo ""
    local mihomo_ver
    mihomo_ver="$(_get_installed_mihomo_version)"
    if [[ "${mihomo_ver}" == "not_installed" ]]; then
        log_info "Mihomo not installed. Skipping."
        total_skip=$(( total_skip + 1 ))
    elif update_mihomo; then
        total_ok=$(( total_ok + 1 ))
    else
        total_fail=$(( total_fail + 1 ))
    fi

    # 4. New API (Docker)
    echo ""
    if ! command_exists docker; then
        log_info "Docker not available. Skipping New API."
        total_skip=$(( total_skip + 1 ))
    elif update_new_api; then
        total_ok=$(( total_ok + 1 ))
    else
        total_fail=$(( total_fail + 1 ))
    fi

    # Summary
    echo ""
    echo "==========================================="
    log_info "Update Summary:"
    log_info "  Successful: ${total_ok}"
    log_info "  Failed:     ${total_fail}"
    log_info "  Skipped:    ${total_skip}"
    echo "==========================================="

    if (( total_fail > 0 )); then
        log_warn "Some updates failed. Check output above for details."
        return 1
    fi

    log_success "All updates completed successfully."
}

###############################################################################
# manage_updates()
#
# Interactive menu for update operations.
###############################################################################
manage_updates() {
    while true; do
        echo ""
        echo -e "${BLUE}============================================${NC}"
        echo -e "${BLUE}  Bifrost - Update Manager        ${NC}"
        echo -e "${BLUE}============================================${NC}"
        echo ""
        echo "  1) Check for updates (dry run)"
        echo "  2) Update Xray"
        echo "  3) Update Mihomo"
        echo "  4) Update New API (Docker)"
        echo "  5) Update GeoIP/GeoSite databases"
        echo "  6) Update ALL components"
        echo "  0) Exit"
        echo ""
        read -r -p "Select option [0-6]: " choice

        case "${choice}" in
            1) echo ""; check_updates ;;
            2) echo ""; _pre_update_check && update_xray ;;
            3) echo ""; _pre_update_check && update_mihomo ;;
            4) echo ""; _pre_update_check && update_new_api ;;
            5) echo ""; _pre_update_check && update_geoip ;;
            6) echo ""; update_all ;;
            0|q|Q|exit)
                log_info "Exiting update manager."
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
        check)
            check_updates
            ;;
        xray)
            _pre_update_check && update_xray
            ;;
        mihomo)
            _pre_update_check && update_mihomo
            ;;
        new-api|newapi)
            _pre_update_check && update_new_api
            ;;
        geoip)
            _pre_update_check && update_geoip
            ;;
        all)
            update_all
            ;;
        help|--help|-h)
            echo "Bifrost - Update Manager"
            echo ""
            echo "Usage:"
            echo "  $0              # Interactive menu"
            echo "  $0 check        # Check for updates (dry run)"
            echo "  $0 xray         # Update Xray"
            echo "  $0 mihomo       # Update Mihomo"
            echo "  $0 new-api      # Update New API (Docker)"
            echo "  $0 geoip        # Update GeoIP databases"
            echo "  $0 all          # Update all components"
            echo "  $0 help         # Show this help"
            ;;
        "")
            manage_updates
            ;;
        *)
            log_error "Unknown command: $1"
            echo "Run '$0 help' for usage information."
            exit 1
            ;;
    esac
fi
