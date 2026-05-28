#!/usr/bin/env bash
# =============================================================================
# Bifrost - Shared Utility Library
# =============================================================================
# Description : Common functions shared across all deployment scripts.
#               Provides logging, OS detection, package management, Docker
#               helpers, interactive menus, network/file/security/service
#               utilities, progress indicators, and error handling.
#
# Usage       : source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
#
# Project     : Bifrost (国内外 AI 服务桥接一键部署方案)
# License     : MIT
# =============================================================================

# ----- Strict mode & guard against double-sourcing -----
set -euo pipefail

if [[ -n "${_COMMON_SH_LOADED:-}" ]]; then
    return 0
fi
readonly _COMMON_SH_LOADED=1

# =============================================================================
# Section 1 : Global Constants & Paths
# =============================================================================

# Resolve the directory this script (common.sh) resides in and the project root.
# Note: We use _COMMON_SCRIPT_DIR instead of SCRIPT_DIR to avoid conflicts
# when this file is sourced by install.sh which may define its own SCRIPT_DIR.
readonly _COMMON_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${_COMMON_SCRIPT_DIR}/.." && pwd)"

readonly LOG_FILE="/var/log/bifrost/bifrost.log"
readonly BACKUP_DIR="/var/backups/bifrost"
readonly BIFROST_EXPOSURE_PROFILE_DEFAULT="vpn-first"
readonly BIFROST_ADMIN_ALLOWED_RANGES_DEFAULT="127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,fd00::/8"
readonly BIFROST_ENV_FILE="${BIFROST_ENV_FILE:-/etc/bifrost.env}"

# Ensure the log file is actually appendable; fall back to /tmp if not writable.
_LOG_FILE_FALLBACK="${LOG_FILE}"
if ! mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || ! touch "${LOG_FILE}" 2>/dev/null; then
    _LOG_FILE_FALLBACK="/tmp/bifrost.log"
    mkdir -p "$(dirname "${_LOG_FILE_FALLBACK}")" 2>/dev/null || true
    touch "${_LOG_FILE_FALLBACK}" 2>/dev/null || true
fi
readonly EFFECTIVE_LOG_FILE="${_LOG_FILE_FALLBACK}"

# Deployment exposure profiles are shared by Server A and Server B so
# management-plane policy stays consistent across generated configs.
bifrost_exposure_profile() {
    local profile="${BIFROST_EXPOSURE_PROFILE:-${BIFROST_EXPOSURE:-${BIFROST_EXPOSURE_PROFILE_DEFAULT}}}"
    profile="${profile,,}"
    profile="${profile//_/-}"

    case "${profile}" in
        vpn-first|public-managed|lab)
            printf '%s\n' "${profile}"
            ;;
        *)
            log_error "Invalid BIFROST_EXPOSURE_PROFILE='${profile}'. Expected: vpn-first, public-managed, or lab."
            return 1
            ;;
    esac
}

bifrost_admin_allowed_ranges() {
    local ranges="${BIFROST_ADMIN_ALLOWED_RANGES:-${BIFROST_ADMIN_ALLOWED_CIDRS:-${BIFROST_ADMIN_ALLOWED_RANGES_DEFAULT}}}"
    ranges="${ranges//,/ }"
    printf '%s\n' "${ranges}"
}

bifrost_exposure_profile_description() {
    local profile="$1"
    case "${profile}" in
        vpn-first)
            printf '%s\n' "Production default: admin surfaces require VPN/private/source-allowlisted access."
            ;;
        public-managed)
            printf '%s\n' "Explicit compatibility mode: management is exposed through public HTTPS and must be protected by strong auth/WAF/allowlists."
            ;;
        lab)
            printf '%s\n' "Non-production lab mode: permissive exposure for testing only."
            ;;
        *)
            printf '%s\n' "Unknown exposure profile."
            return 1
            ;;
    esac
}

bifrost_env_load() {
    # shellcheck source=/dev/null
    [[ -f "${BIFROST_ENV_FILE}" ]] && source "${BIFROST_ENV_FILE}"
    return 0
}

bifrost_env_set() {
    local key="$1"
    local value="$2"

    if [[ -z "${key}" || -z "${value}" ]]; then
        log_error "bifrost_env_set: key and value are required"
        return 1
    fi

    if [[ ! "${key}" =~ ^[A-Z0-9_]+$ ]]; then
        log_error "bifrost_env_set: invalid key '${key}'"
        return 1
    fi

    if [[ ! -f "${BIFROST_ENV_FILE}" ]]; then
        install -m 600 -o root -g root /dev/null "${BIFROST_ENV_FILE}"
    fi

    if grep -qE "^${key}=" "${BIFROST_ENV_FILE}"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${BIFROST_ENV_FILE}"
    else
        printf '%s=%s\n' "${key}" "${value}" >> "${BIFROST_ENV_FILE}"
    fi
    chmod 600 "${BIFROST_ENV_FILE}"
}

bifrost_env_get() {
    local key="$1"
    [[ -f "${BIFROST_ENV_FILE}" ]] || return 1
    grep -E "^${key}=" "${BIFROST_ENV_FILE}" | tail -n1 | cut -d= -f2-
}

# =============================================================================
# Section 2 : Color & Formatting
# =============================================================================

# Detect terminal capability once; disable colors when piped / no tty.
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    readonly COLOR_RESET="\033[0m"
    readonly COLOR_RED="\033[0;31m"
    readonly COLOR_GREEN="\033[0;32m"
    readonly COLOR_YELLOW="\033[0;33m"
    readonly COLOR_BLUE="\033[0;34m"
    readonly COLOR_MAGENTA="\033[0;35m"
    readonly COLOR_CYAN="\033[0;36m"
    readonly COLOR_WHITE="\033[1;37m"
    readonly COLOR_BOLD="\033[1m"
    readonly COLOR_DIM="\033[2m"
    readonly COLOR_UNDERLINE="\033[4m"
    readonly HAS_COLOR=1
else
    readonly COLOR_RESET=""
    readonly COLOR_RED=""
    readonly COLOR_GREEN=""
    readonly COLOR_YELLOW=""
    readonly COLOR_BLUE=""
    readonly COLOR_MAGENTA=""
    readonly COLOR_CYAN=""
    readonly COLOR_WHITE=""
    readonly COLOR_BOLD=""
    readonly COLOR_DIM=""
    readonly COLOR_UNDERLINE=""
    readonly HAS_COLOR=0
fi

# Semantic aliases
readonly COLOR_INFO="${COLOR_BLUE}"
readonly COLOR_WARN="${COLOR_YELLOW}"
readonly COLOR_ERROR="${COLOR_RED}"
readonly COLOR_SUCCESS="${COLOR_GREEN}"

# Print a large banner with project name.
# Usage: print_banner "Title Text"
print_banner() {
    local title="${1:-Bifrost}"
    local border
    border="$(printf '=%.0s' {1..62})"
    echo ""
    echo -e "${COLOR_CYAN}${border}${COLOR_RESET}"
    echo -e "${COLOR_CYAN}||${COLOR_RESET}  ${COLOR_BOLD}${title}${COLOR_RESET}"
    echo -e "${COLOR_CYAN}||${COLOR_RESET}  ${COLOR_DIM}国内外 AI 服务桥接一键部署方案${COLOR_RESET}"
    echo -e "${COLOR_CYAN}${border}${COLOR_RESET}"
    echo ""
}

# Print a section header.
# Usage: print_section "Section Title"
print_section() {
    local title="${1:?print_section requires a title}"
    echo ""
    echo -e "${COLOR_BOLD}${COLOR_MAGENTA}>>> ${title}${COLOR_RESET}"
    echo -e "${COLOR_DIM}$(printf -- '-%.0s' {1..50})${COLOR_RESET}"
}

# Print a numbered step inside a section.
# Usage: print_step 1 "Doing something..."
print_step() {
    local num="${1:?print_step requires a step number}"
    local msg="${2:?print_step requires a message}"
    echo -e "  ${COLOR_CYAN}[${num}]${COLOR_RESET} ${msg}"
}

# =============================================================================
# Section 3 : Logging
# =============================================================================

# Internal: write a formatted log line to stdout and the log file.
# Args: level color message...
_log() {
    local level="${1}"
    local color="${2}"
    shift 2
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local plain_msg="${ts} [${level}] $*"
    local color_msg="${color}${ts} [${level}]${COLOR_RESET} $*"

    # Stdout (colored if supported).
    echo -e "${color_msg}"

    # Logfile (plain text, no ANSI codes).
    echo "${plain_msg}" >> "${EFFECTIVE_LOG_FILE}" 2>/dev/null || true
}

log_info()    { _log "INFO"    "${COLOR_INFO}"    "$@"; }
log_warn()    { _log "WARN"    "${COLOR_WARN}"    "$@"; }
log_error()   { _log "ERROR"   "${COLOR_ERROR}"   "$@"; }
log_success() { _log "SUCCESS" "${COLOR_SUCCESS}"  "$@"; }

# Fatal error: log, then exit.
# Usage: die "something went wrong"
die() {
    log_error "$@"
    exit 1
}

# =============================================================================
# Section 4 : Error Handling & Cleanup
# =============================================================================

# Temp files registered for cleanup.
_CLEANUP_FILES=()
_CLEANUP_PIDS=()

# Register a file/dir for cleanup on exit.
register_cleanup() {
    _CLEANUP_FILES+=("$1")
}

# Register a background PID for cleanup.
register_cleanup_pid() {
    _CLEANUP_PIDS+=("$1")
}

# Trap handler: clean up temp files and background jobs.
_on_exit() {
    local exit_code=$?

    # Stop any spinner that may be running.
    _spinner_stop 2>/dev/null || true

    # Kill registered background PIDs.
    for pid in "${_CLEANUP_PIDS[@]+"${_CLEANUP_PIDS[@]}"}"; do
        kill "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
    done

    # Remove registered temp files.
    for f in "${_CLEANUP_FILES[@]+"${_CLEANUP_FILES[@]}"}"; do
        rm -rf "${f}" 2>/dev/null || true
    done

    if [[ ${exit_code} -ne 0 ]]; then
        log_error "Script exited with code ${exit_code}."
    fi
}
trap _on_exit EXIT

# Trap for ERR (provides file & line info).
_on_error() {
    local line="${1:-unknown}"
    local cmd="${2:-unknown}"
    log_error "Command '${cmd}' failed at line ${line}."
}
trap '_on_error ${LINENO} "${BASH_COMMAND}"' ERR

# =============================================================================
# Section 5 : OS / System Detection
# =============================================================================

# Exported variables filled by detect_system().
OS_ID=""
OS_VER=""
OS_CODENAME=""
ARCH=""
KERNEL=""
CPU_CORES=""
MEM_TOTAL_MB=""
DISK_AVAIL_GB=""
VIRT_TYPE=""
PUBLIC_IP=""
IS_ROOT=0
PKG_MGR=""
PKG_INSTALL=""

# Detect operating system, hardware, and set package-manager variables.
# Sets the global variables listed above.
detect_system() {
    log_info "Detecting system environment..."

    # ----- OS release -----
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VER="${VERSION_ID:-unknown}"
        OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-unknown}}"
    else
        OS_ID="unknown"
        OS_VER="unknown"
        OS_CODENAME="unknown"
    fi

    # Normalize to lowercase.
    OS_ID="${OS_ID,,}"

    # ----- Architecture -----
    ARCH="$(uname -m)"

    # ----- Kernel -----
    KERNEL="$(uname -r)"

    # ----- CPU -----
    if command -v nproc &>/dev/null; then
        CPU_CORES="$(nproc)"
    elif [[ -f /proc/cpuinfo ]]; then
        CPU_CORES="$(grep -c '^processor' /proc/cpuinfo)"
    else
        CPU_CORES="1"
    fi

    # ----- Memory (MB) -----
    if command -v free &>/dev/null; then
        MEM_TOTAL_MB="$(free -m | awk '/^Mem:/ {print $2}')"
    else
        MEM_TOTAL_MB="0"
    fi

    # ----- Disk available on / (GB) -----
    if command -v df &>/dev/null; then
        DISK_AVAIL_GB="$(df -BG / | awk 'NR==2 {gsub(/G/,"",$4); print $4}')"
    else
        DISK_AVAIL_GB="0"
    fi

    # ----- Virtualization -----
    if command -v systemd-detect-virt &>/dev/null; then
        VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || echo 'none')"
    else
        VIRT_TYPE="unknown"
    fi

    # ----- Public IP (best-effort, 5s timeout) -----
    PUBLIC_IP="$(get_public_ip)"

    # ----- Root check -----
    if [[ "$(id -u)" -eq 0 ]]; then
        IS_ROOT=1
    else
        IS_ROOT=0
    fi

    # ----- Package manager -----
    case "${OS_ID}" in
        ubuntu|debian|linuxmint|pop)
            PKG_MGR="apt"
            PKG_INSTALL="apt-get install -y"
            ;;
        centos|rhel|rocky|alma|ol)
            if command -v dnf &>/dev/null; then
                PKG_MGR="dnf"
                PKG_INSTALL="dnf install -y"
            else
                PKG_MGR="yum"
                PKG_INSTALL="yum install -y"
            fi
            ;;
        fedora)
            PKG_MGR="dnf"
            PKG_INSTALL="dnf install -y"
            ;;
        *)
            # Attempt auto-detect by available binary.
            if command -v apt-get &>/dev/null; then
                PKG_MGR="apt"
                PKG_INSTALL="apt-get install -y"
            elif command -v dnf &>/dev/null; then
                PKG_MGR="dnf"
                PKG_INSTALL="dnf install -y"
            elif command -v yum &>/dev/null; then
                PKG_MGR="yum"
                PKG_INSTALL="yum install -y"
            else
                PKG_MGR="unknown"
                PKG_INSTALL=""
            fi
            ;;
    esac

    log_info "OS=${OS_ID} ${OS_VER} (${OS_CODENAME}), Arch=${ARCH}, Kernel=${KERNEL}"
    log_info "CPU=${CPU_CORES} cores, RAM=${MEM_TOTAL_MB}MB, Disk(/)=${DISK_AVAIL_GB}GB, Virt=${VIRT_TYPE}"
    log_info "Public IP=${PUBLIC_IP}, Root=${IS_ROOT}, PkgMgr=${PKG_MGR}"
}

# =============================================================================
# Section 6 : Package Manager Abstraction
# =============================================================================

# Report processes that are likely holding apt/dpkg locks.
apt_lock_holders() {
    local -a lock_files=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/cache/apt/archives/lock
    )
    local -a pids=()
    local output pid

    if command -v fuser >/dev/null 2>&1; then
        output="$(fuser "${lock_files[@]}" 2>/dev/null || true)"
        for pid in ${output}; do
            if [[ "${pid}" =~ ^[0-9]+$ ]]; then
                pids+=("${pid}")
            fi
        done
    fi

    if [[ ${#pids[@]} -gt 0 ]]; then
        printf '%s\n' "${pids[@]}" | sort -n -u | while IFS= read -r pid; do
            local args
            args="$(ps -p "${pid}" -o args= 2>/dev/null | awk '{$1=$1; print}' || true)"
            printf '%s:%s\n' "${pid}" "${args:-unknown}"
        done
        return 0
    fi

    ps -eo pid=,comm=,args= 2>/dev/null | awk '
        $2 ~ /^(apt|apt-get|dpkg|unattended-upgr|unattended-upgrades|apt.systemd.daily|packagekitd)$/ {
            args = $3
            for (i = 4; i <= NF; i++) {
                args = args " " $i
            }
            print $1 ":" args
        }
    '
}

# Wait until apt/dpkg locks are released before package operations.
wait_for_apt_locks() {
    local timeout="${BIFROST_APT_LOCK_WAIT_SECONDS:-600}"
    local interval="${BIFROST_APT_LOCK_WAIT_INTERVAL:-5}"
    local elapsed=0
    local holders

    while true; do
        holders="$(apt_lock_holders || true)"
        if [[ -z "${holders//[[:space:]]/}" ]]; then
            return 0
        fi

        holders="${holders//$'\n'/, }"
        if (( elapsed >= timeout )); then
            log_error "APT/dpkg lock is still held after ${timeout}s: ${holders}"
            log_error "Wait for the package manager to finish, then rerun the command."
            return 1
        fi

        log_warn "APT/dpkg is busy (${holders}); waiting ${interval}s before package operation..."
        sleep "${interval}"
        elapsed=$((elapsed + interval))
    done
}

# Run apt-get after waiting for unattended-upgrades or other package managers.
run_apt_get() {
    wait_for_apt_locks || return 1
    DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}" apt-get "$@"
}

# Install one or more packages using the detected package manager.
# Automatically updates the index (apt) on first call.
# Usage: install_packages curl wget jq
install_packages() {
    if [[ -z "${PKG_MGR}" || "${PKG_MGR}" == "unknown" ]]; then
        die "No supported package manager detected. Cannot install packages."
    fi

    local pkgs=("$@")
    if [[ ${#pkgs[@]} -eq 0 ]]; then
        log_warn "install_packages called with no arguments."
        return 0
    fi

    log_info "Installing packages: ${pkgs[*]} (via ${PKG_MGR})..."

    case "${PKG_MGR}" in
        apt)
            # Refresh index on first call in this session.
            if [[ -z "${_APT_UPDATED:-}" ]]; then
                run_apt_get update -qq
                _APT_UPDATED=1
            fi
            run_apt_get install -y ${pkgs[@]+"${pkgs[@]}"}
            ;;
        dnf)
            dnf install -y ${pkgs[@]+"${pkgs[@]}"}
            ;;
        yum)
            yum install -y ${pkgs[@]+"${pkgs[@]}"}
            ;;
        *)
            die "Unsupported package manager: ${PKG_MGR}"
            ;;
    esac

    log_success "Packages installed: ${pkgs[*]}"
}

# =============================================================================
# Section 7 : Dependency / Command Check
# =============================================================================

# Check if a command is available in PATH.
# Usage: check_command curl
# Returns 0 if found, 1 otherwise.
check_command() {
    local cmd="${1:?check_command requires a command name}"
    command -v "${cmd}" &>/dev/null
}

# Install a package if the command it provides is missing.
# Usage: install_if_missing curl curl          (command, package)
#        install_if_missing jq jq
# If only one arg given, package name is assumed to equal the command.
install_if_missing() {
    local cmd="${1:?install_if_missing requires a command name}"
    local pkg="${2:-${cmd}}"

    if check_command "${cmd}"; then
        log_info "Dependency '${cmd}' already present."
        return 0
    fi

    log_warn "'${cmd}' not found. Installing package '${pkg}'..."
    install_packages "${pkg}"

    if ! check_command "${cmd}"; then
        die "Failed to install '${cmd}' via package '${pkg}'."
    fi

    log_success "'${cmd}' installed successfully."
}

# =============================================================================
# Section 8 : Docker Helpers
# =============================================================================

# Retrieve the Docker server version in normalized form.
# Returns the version via stdout, or "unknown" if it cannot be determined.
docker_server_version() {
    local docker_ver
    docker_ver="$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo 'unknown')"
    docker_ver="${docker_ver%%[-+~]*}"
    echo "${docker_ver:-unknown}"
}

# Compare two dotted versions.
# Returns 0 when current_version >= minimum_version.
version_gte() {
    local current_version="${1:?version_gte requires a current version}"
    local minimum_version="${2:?version_gte requires a minimum version}"

    [[ "$(printf '%s\n%s\n' "${minimum_version}" "${current_version}" | LC_ALL=C sort -V | head -n1)" == "${minimum_version}" ]]
}

# Require a minimum Docker server version for a specific feature.
# Returns 0 when the requirement is met, 1 otherwise.
require_docker_server_version() {
    local minimum_version="${1:?require_docker_server_version requires a minimum version}"
    local feature_name="${2:-this feature}"
    local docker_ver
    docker_ver="$(docker_server_version)"

    if [[ -z "${docker_ver}" || "${docker_ver}" == "unknown" ]]; then
        log_error "Unable to determine Docker server version. Cannot validate support for ${feature_name}."
        return 1
    fi

    if ! version_gte "${docker_ver}" "${minimum_version}"; then
        log_error "Docker ${minimum_version}+ is required for ${feature_name}. Current server version: ${docker_ver}."
        return 1
    fi

    return 0
}

# Check if Docker Engine is installed and the daemon is running.
# Returns 0 if healthy, 1 otherwise.
check_docker() {
    if ! check_command docker; then
        log_warn "Docker is not installed."
        return 1
    fi

    if ! docker info &>/dev/null; then
        log_warn "Docker daemon is not running or current user lacks permissions."
        return 1
    fi

    local docker_ver
    docker_ver="$(docker_server_version)"
    log_info "Docker version: ${docker_ver}"
    return 0
}

# Install Docker CE using the official convenience script.
# Supports Debian/Ubuntu/CentOS/Fedora/RHEL and derivatives.
install_docker() {
    if check_docker; then
        log_info "Docker is already installed and running."
        # Still configure mirrors if in China
        if declare -f configure_docker_mirrors &>/dev/null; then
            configure_docker_mirrors
        fi
        return 0
    fi

    # Prefer the China-aware installer if available (defined later in this file)
    if declare -f install_docker_china_aware &>/dev/null; then
        install_docker_china_aware
        return $?
    fi

    log_info "Installing Docker CE..."

    # Ensure prerequisites for the install script.
    install_if_missing curl curl

    local tmp_script
    tmp_script="$(mktemp /tmp/get-docker.XXXXXX.sh)"
    register_cleanup "${tmp_script}"

    if ! curl -fsSL --connect-timeout 15 --max-time 60 https://get.docker.com -o "${tmp_script}" 2>/dev/null; then
        log_warn "Failed to download Docker install script from get.docker.com."
        die "Cannot install Docker: download failed."
    fi
    chmod +x "${tmp_script}"
    bash "${tmp_script}"

    # Enable & start.
    systemctl enable docker
    systemctl start docker

    if ! check_docker; then
        die "Docker installation completed but the daemon is not healthy."
    fi

    # Install docker-compose plugin if not present.
    if ! docker compose version &>/dev/null; then
        log_info "Installing Docker Compose plugin..."
        case "${PKG_MGR}" in
            apt)
                install_packages docker-compose-plugin
                ;;
            dnf|yum)
                install_packages docker-compose-plugin
                ;;
        esac
    fi

    log_success "Docker CE installed successfully."
}

# =============================================================================
# Section 9 : Interactive Menu Helpers
# =============================================================================

# Display a numbered selection menu and return the chosen index (1-based).
# Usage:
#   local options=("Option A" "Option B" "Option C")
#   show_menu "Choose one" options
#   echo "You chose index: ${MENU_RESULT}"
# Sets MENU_RESULT to the selected 1-based index.
MENU_RESULT=""
show_menu() {
    local title="${1:?show_menu requires a title}"
    local -n _opts="${2:?show_menu requires an options array name}"

    echo ""
    echo -e "${COLOR_BOLD}${title}${COLOR_RESET}"
    echo -e "${COLOR_DIM}$(printf -- '-%.0s' {1..40})${COLOR_RESET}"

    local i
    for i in "${!_opts[@]}"; do
        echo -e "  ${COLOR_CYAN}$((i + 1)))${COLOR_RESET} ${_opts[${i}]}"
    done

    echo ""
    local choice
    while true; do
        read -r -p "$(echo -e "${COLOR_BOLD}Enter selection [1-${#_opts[@]}]: ${COLOR_RESET}")" choice
        if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#_opts[@]} )); then
            MENU_RESULT="${choice}"
            return 0
        fi
        echo -e "${COLOR_WARN}Invalid selection. Please enter a number between 1 and ${#_opts[@]}.${COLOR_RESET}"
    done
}

# Yes/No confirmation prompt.
# Usage: confirm_action "Proceed with deployment?" && do_deploy
# Default answer when user presses Enter can be set via $2: "y" or "n" (default "n").
confirm_action() {
    local prompt="${1:?confirm_action requires a prompt}"
    local default="${2:-n}"

    local yn_hint
    if [[ "${default,,}" == "y" ]]; then
        yn_hint="[Y/n]"
    else
        yn_hint="[y/N]"
    fi

    local answer
    while true; do
        read -r -p "$(echo -e "${COLOR_BOLD}${prompt} ${yn_hint}: ${COLOR_RESET}")" answer
        answer="${answer:-${default}}"
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     echo -e "${COLOR_WARN}Please answer y or n.${COLOR_RESET}" ;;
        esac
    done
}

# Read user input with an optional default and optional validation regex.
# Usage:
#   read_input "Enter domain" "example.com" "^[a-zA-Z0-9.-]+$"
#   echo "Domain: ${INPUT_RESULT}"
# Sets INPUT_RESULT.
INPUT_RESULT=""
read_input() {
    local prompt="${1:?read_input requires a prompt}"
    local default="${2:-}"
    local pattern="${3:-}"

    local display_default=""
    if [[ -n "${default}" ]]; then
        display_default=" ${COLOR_DIM}(default: ${default})${COLOR_RESET}"
    fi

    local value
    while true; do
        read -r -p "$(echo -e "${COLOR_BOLD}${prompt}${display_default}: ${COLOR_RESET}")" value
        value="${value:-${default}}"

        if [[ -z "${value}" ]]; then
            echo -e "${COLOR_WARN}Input cannot be empty.${COLOR_RESET}"
            continue
        fi

        if [[ -n "${pattern}" ]] && ! [[ "${value}" =~ ${pattern} ]]; then
            echo -e "${COLOR_WARN}Input does not match required format: ${pattern}${COLOR_RESET}"
            continue
        fi

        INPUT_RESULT="${value}"
        return 0
    done
}

# =============================================================================
# Section 10 : Network Helpers
# =============================================================================

# Check if a TCP port is currently open (listening) on localhost.
# Usage: check_port_open 443
check_port_open() {
    local port="${1:?check_port_open requires a port number}"

    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep -qE ":${port}\b"
    elif command -v netstat &>/dev/null; then
        netstat -tlnp 2>/dev/null | grep -qE ":${port}\b"
    else
        # Fallback: try connecting to the port.
        (echo >/dev/tcp/127.0.0.1/"${port}") &>/dev/null
    fi
}

# Wait until a TCP port becomes reachable, with timeout.
# Usage: wait_for_port 8080 30   (port, max_seconds)
wait_for_port() {
    local port="${1:?wait_for_port requires a port number}"
    local timeout="${2:-30}"

    log_info "Waiting for port ${port} (timeout: ${timeout}s)..."

    local elapsed=0
    while (( elapsed < timeout )); do
        if check_port_open "${port}"; then
            log_success "Port ${port} is now open (after ${elapsed}s)."
            return 0
        fi
        sleep 1
        (( elapsed++ )) || true
    done

    log_error "Timed out waiting for port ${port} after ${timeout}s."
    return 1
}

# Retrieve the server's public IPv4 address.
# Tries multiple providers with short timeouts.
get_public_ip() {
    local ip=""
    local providers=(
        "https://ifconfig.me"
        "https://api.ipify.org"
        "https://ipinfo.io/ip"
        "https://icanhazip.com"
    )

    for url in ${providers[@]+"${providers[@]}"}; do
        ip="$(curl -4 -s --connect-timeout 5 --max-time 8 "${url}" 2>/dev/null | tr -d '[:space:]')" || true
        # Basic IPv4 validation.
        if [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "${ip}"
            return 0
        fi
    done

    echo "unknown"
    return 1
}

# Check general internet connectivity by pinging well-known hosts.
# Returns 0 if at least one host is reachable.
check_connectivity() {
    local hosts=("1.1.1.1" "8.8.8.8" "223.5.5.5")
    for h in ${hosts[@]+"${hosts[@]}"}; do
        if ping -c 1 -W 3 "${h}" &>/dev/null; then
            return 0
        fi
    done

    # Fallback: try curl.
    if curl -s --connect-timeout 5 --max-time 8 -o /dev/null "https://www.baidu.com"; then
        return 0
    fi

    return 1
}

# =============================================================================
# Section 11 : File Helpers
# =============================================================================

# Create a timestamped backup of a file.
# Usage: backup_file /etc/ssh/sshd_config
# Returns the path of the backup file in BACKUP_RESULT.
BACKUP_RESULT=""
backup_file() {
    local file="${1:?backup_file requires a file path}"

    if [[ ! -f "${file}" ]]; then
        log_warn "Cannot backup '${file}': file does not exist."
        BACKUP_RESULT=""
        return 1
    fi

    mkdir -p "${BACKUP_DIR}"

    local basename
    basename="$(basename "${file}")"
    local ts
    ts="$(date '+%Y%m%d_%H%M%S')"
    local dest="${BACKUP_DIR}/${basename}.${ts}.bak"

    cp -a "${file}" "${dest}"
    log_info "Backed up '${file}' -> '${dest}'"
    BACKUP_RESULT="${dest}"
}

# sed wrapper that creates a backup before in-place editing.
# Usage: safe_sed "s/old/new/g" /path/to/file
safe_sed() {
    local expression="${1:?safe_sed requires a sed expression}"
    local file="${2:?safe_sed requires a file path}"

    backup_file "${file}" || true
    sed -i "${expression}" "${file}"
    log_info "Applied sed '${expression}' to '${file}'"
}

# Replace {{VAR}} placeholders in a template file and write the result.
# Usage: template_render input.tpl output.conf VAR1=value1 VAR2=value2
template_render() {
    local input="${1:?template_render requires an input template file}"
    local output="${2:?template_render requires an output file path}"
    shift 2

    if [[ ! -f "${input}" ]]; then
        die "Template file not found: ${input}"
    fi

    local content
    content="$(cat "${input}")"

    local kv key value
    for kv in "$@"; do
        key="${kv%%=*}"
        value="${kv#*=}"
        # Escape special characters in value for sed.
        local escaped_value
        escaped_value="$(printf '%s' "${value}" | sed -e 's/[\\/&]/\\&/g')"
        content="$(printf '%s' "${content}" | sed "s/{{${key}}}/${escaped_value}/g")"
    done

    echo "${content}" > "${output}"
    log_info "Rendered template '${input}' -> '${output}'"
}

# =============================================================================
# Section 12 : Security Helpers
# =============================================================================

# Generate a UUID v4.
generate_uuid() {
    if check_command uuidgen; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        # Pure-bash fallback (pseudo-random, adequate for non-crypto uses).
        local hex
        hex="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
        printf '%s-%s-4%s-%s-%s\n' \
            "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" "${hex:16:4}" "${hex:20:12}"
    fi
}

# Generate a cryptographically random password.
# Usage: generate_random_password [length]   (default: 32)
generate_random_password() {
    local length="${1:-32}"

    if check_command openssl; then
        openssl rand -base64 $((length * 3 / 4 + 1)) | tr -d '/+\n' | head -c "${length}"
        echo
    elif [[ -r /dev/urandom ]]; then
        tr -dc 'A-Za-z0-9!@#%^*_-' < /dev/urandom | head -c "${length}"
        echo
    else
        die "No suitable random source available for password generation."
    fi
}

# Generate an x25519 keypair using the Xray binary.
# Requires xray to be installed at /usr/local/bin/xray or in PATH.
# Sets X25519_PRIVATE_KEY and X25519_PUBLIC_KEY.
X25519_PRIVATE_KEY=""
X25519_PUBLIC_KEY=""
generate_x25519_keypair() {
    local xray_bin=""

    if check_command xray; then
        xray_bin="xray"
    elif [[ -x /usr/local/bin/xray ]]; then
        xray_bin="/usr/local/bin/xray"
    elif [[ -x /usr/bin/xray ]]; then
        xray_bin="/usr/bin/xray"
    else
        die "Xray binary not found. Install Xray first to generate x25519 keypairs."
    fi

    log_info "Generating x25519 keypair via '${xray_bin}'..."

    local output
    output="$("${xray_bin}" x25519 2>&1)"

    X25519_PRIVATE_KEY="$(echo "${output}" | grep -i 'private' | awk '{print $NF}')"
    X25519_PUBLIC_KEY="$(echo "${output}" | grep -i 'public' | awk '{print $NF}')"

    if [[ -z "${X25519_PRIVATE_KEY}" || -z "${X25519_PUBLIC_KEY}" ]]; then
        die "Failed to parse x25519 keypair from xray output: ${output}"
    fi

    log_success "x25519 keypair generated. Public key: ${X25519_PUBLIC_KEY}"
}

# =============================================================================
# Section 13 : Service Helpers
# =============================================================================

# Enable a systemd service to start on boot.
# Usage: enable_service nginx
enable_service() {
    local svc="${1:?enable_service requires a service name}"
    log_info "Enabling service '${svc}'..."
    systemctl enable "${svc}"
    log_success "Service '${svc}' enabled."
}

# Restart a systemd service.
# Usage: restart_service nginx
restart_service() {
    local svc="${1:?restart_service requires a service name}"
    log_info "Restarting service '${svc}'..."
    systemctl restart "${svc}"

    # Brief pause to let the service settle, then check.
    sleep 2
    if systemctl is-active --quiet "${svc}"; then
        log_success "Service '${svc}' is active."
    else
        log_error "Service '${svc}' failed to start."
        systemctl status "${svc}" --no-pager -l || true
        return 1
    fi
}

# Check and display the status of a systemd service.
# Returns 0 if active, 1 otherwise.
# Usage: check_service_status nginx
check_service_status() {
    local svc="${1:?check_service_status requires a service name}"

    if systemctl is-active --quiet "${svc}"; then
        log_info "Service '${svc}': $(systemctl is-active "${svc}")"
        return 0
    else
        log_warn "Service '${svc}': $(systemctl is-active "${svc}" 2>/dev/null || echo 'not found')"
        return 1
    fi
}

# =============================================================================
# Section 14 : Progress / Spinner
# =============================================================================

_SPINNER_PID=""

# Internal: spinner animation loop (runs in background).
_spinner_loop() {
    local msg="${1:-Working...}"
    local frames=('/' '-' '\' '|')
    local i=0

    # Hide cursor.
    tput civis 2>/dev/null || true

    while true; do
        printf "\r  ${COLOR_CYAN}%s${COLOR_RESET} %s " "${frames[i]}" "${msg}"
        i=$(( (i + 1) % ${#frames[@]} ))
        sleep 0.15
    done
}

# Internal: stop the running spinner.
_spinner_stop() {
    local had_spinner=0
    if [[ -n "${_SPINNER_PID}" ]]; then
        had_spinner=1
        kill "${_SPINNER_PID}" 2>/dev/null || true
        wait "${_SPINNER_PID}" 2>/dev/null || true
        _SPINNER_PID=""
    fi

    # Restore cursor and clear the spinner line only when a spinner actually ran
    # on an interactive terminal. This avoids polluting `--help` / `--version`
    # stdout with carriage-return padding via the EXIT trap.
    if [[ "${had_spinner}" -eq 1 && -t 1 ]]; then
        tput cnorm 2>/dev/null || true
        printf "\r%*s\r" 80 ""
    fi
}

# Start a spinner with a message.  Must call spinner_stop to clear it.
# Usage:
#   spinner_start "Installing packages..."
#   long_running_command
#   spinner_stop
spinner_start() {
    local msg="${1:-Working...}"

    # Stop any previously running spinner.
    _spinner_stop 2>/dev/null || true

    _spinner_loop "${msg}" &
    _SPINNER_PID=$!
    register_cleanup_pid "${_SPINNER_PID}"
    disown "${_SPINNER_PID}" 2>/dev/null || true
}

spinner_stop() {
    _spinner_stop
}

# Execute a command with a spinner shown while it runs.
# Usage: spinner "Downloading..." curl -fsSL https://example.com -o file
spinner() {
    local msg="${1:?spinner requires a message}"
    shift

    spinner_start "${msg}"
    local rc=0
    "$@" || rc=$?
    spinner_stop

    return ${rc}
}

# =============================================================================
# Section 15 : Require-Root Guard
# =============================================================================

# Abort if not running as root.
require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "This script must be run as root. Use: sudo $0"
    fi
}

# =============================================================================
# Section 16 : Miscellaneous Utilities
# =============================================================================

# Retry a command up to N times with a delay between attempts.
# Usage: retry 3 5 curl -fsSL https://example.com
#   -> retry up to 3 times, sleep 5s between attempts.
retry() {
    local max_attempts="${1:?retry requires max_attempts}"
    local delay="${2:?retry requires delay in seconds}"
    shift 2

    local attempt=1
    while (( attempt <= max_attempts )); do
        if "$@"; then
            return 0
        fi
        log_warn "Attempt ${attempt}/${max_attempts} failed. Retrying in ${delay}s..."
        sleep "${delay}"
        (( attempt++ )) || true
    done

    log_error "All ${max_attempts} attempts failed for command: $*"
    return 1
}

# Compare two semver strings.  Returns via exit code:
#   0 if v1 == v2,  1 if v1 > v2,  2 if v1 < v2
# Usage: semver_compare "1.20.0" "1.19.3"
semver_compare() {
    local v1="${1:?}" v2="${2:?}"

    if [[ "${v1}" == "${v2}" ]]; then
        return 0
    fi

    local IFS=.
    local -a a1=($v1) a2=($v2)

    local i
    for (( i = 0; i < 3; i++ )); do
        local n1="${a1[i]:-0}"
        local n2="${a2[i]:-0}"
        if (( n1 > n2 )); then
            return 1
        elif (( n1 < n2 )); then
            return 2
        fi
    done

    return 0
}

# Pretty-print a key-value line (for summaries).
# Usage: print_kv "OS" "Ubuntu 22.04"
print_kv() {
    local key="${1:?}"
    local val="${2:?}"
    printf "  ${COLOR_BOLD}%-18s${COLOR_RESET} %s\n" "${key}:" "${val}"
}

# Print a system summary table (call after detect_system).
print_system_summary() {
    print_section "System Summary"
    print_kv "OS"           "${OS_ID} ${OS_VER} (${OS_CODENAME})"
    print_kv "Architecture" "${ARCH}"
    print_kv "Kernel"       "${KERNEL}"
    print_kv "CPU Cores"    "${CPU_CORES}"
    print_kv "Memory"       "${MEM_TOTAL_MB} MB"
    print_kv "Disk Avail /" "${DISK_AVAIL_GB} GB"
    print_kv "Virtualization" "${VIRT_TYPE}"
    print_kv "Public IP"    "${PUBLIC_IP}"
    print_kv "Root"         "$(if [[ ${IS_ROOT} -eq 1 ]]; then echo 'yes'; else echo 'no'; fi)"
    print_kv "Pkg Manager"  "${PKG_MGR}"
    echo ""
}

# =============================================================================
# Section 17 : China Network Helpers (GitHub / Docker Hub mirrors)
# =============================================================================

# Detect if the current machine is likely inside mainland China.
# Uses heuristic: try to reach a China-only site faster than a global site.
# Caches the result for the session in _IS_IN_CHINA.
_IS_IN_CHINA=""
is_in_china() {
    if [[ -n "${_IS_IN_CHINA}" ]]; then
        [[ "${_IS_IN_CHINA}" == "1" ]]
        return $?
    fi

    # Heuristic 1: if we can reach baidu.com fast but github.com times out, we're in China
    if curl -s --connect-timeout 3 --max-time 5 -o /dev/null "https://www.baidu.com" 2>/dev/null; then
        if ! curl -s --connect-timeout 3 --max-time 5 -o /dev/null "https://github.com" 2>/dev/null; then
            _IS_IN_CHINA="1"
            log_info "China network environment detected (GitHub unreachable). Using mirror URLs."
            return 0
        fi
    fi

    _IS_IN_CHINA="0"
    return 1
}

# Return newline-delimited GitHub mirror prefixes.
# Override with BIFROST_GITHUB_MIRROR_PREFIXES="https://mirror1,https://mirror2".
github_mirror_prefixes() {
    local configured="${BIFROST_GITHUB_MIRROR_PREFIXES:-}"
    local defaults=$'https://ghproxy.net\nhttps://mirror.ghproxy.com\nhttps://gh-proxy.com'
    local prefixes="${configured:-${defaults}}"

    printf '%s\n' "${prefixes}" \
        | tr ',; ' '\n\n\n' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' \
        | awk '!seen[$0]++'
}

# Return a concise remediation hint for GitHub mirror overrides.
github_mirror_help() {
    echo "Override GitHub mirrors with BIFROST_GITHUB_MIRROR_PREFIXES='https://mirror1.example,https://mirror2.example' and retry."
}

# Return newline-delimited candidate URLs for a GitHub asset/API URL.
github_url_candidates() {
    local url="${1:?github_url_candidates requires a URL}"
    local prefix=""

    printf '%s\n' "${url}"

    while IFS= read -r prefix; do
        [[ -n "${prefix}" ]] || continue
        printf '%s\n' "${prefix%/}/${url}"
    done < <(github_mirror_prefixes)

    if [[ "${url}" == *"raw.githubusercontent.com"* ]]; then
        local jsdelivr_url=""
        jsdelivr_url="$(printf '%s' "${url}" | sed -E 's|https://raw.githubusercontent.com/([^/]+)/([^/]+)/([^/]+)/(.*)|https://cdn.jsdelivr.net/gh/\1/\2@\3/\4|')"
        [[ -n "${jsdelivr_url}" ]] && printf '%s\n' "${jsdelivr_url}"
    fi
}

# Download a GitHub asset/API URL to disk, with configurable mirror fallback.
# Usage: github_download "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip" "/tmp/xray.zip"
github_download() {
    local url="${1:?github_download requires a URL}"
    local dest="${2:?github_download requires a destination path}"
    local max_time="${3:-120}"
    local candidate_url=""
    local attempt_index=0

    while IFS= read -r candidate_url; do
        [[ -n "${candidate_url}" ]] || continue

        if [[ "${attempt_index}" -gt 0 ]]; then
            log_info "Trying GitHub mirror URL: ${candidate_url}"
        fi

        if curl -fsSL --connect-timeout 15 --max-time "${max_time}" --retry 2 --retry-delay 3 -o "${dest}" "${candidate_url}" 2>/dev/null; then
            if [[ -s "${dest}" ]]; then
                if [[ "${attempt_index}" -gt 0 ]]; then
                    log_success "Downloaded via configured GitHub mirror: ${candidate_url}"
                fi
                return 0
            fi
        fi

        rm -f "${dest}" 2>/dev/null || true

        if [[ "${attempt_index}" -eq 0 ]]; then
            log_warn "Direct GitHub download failed: ${url}"
        fi

        attempt_index=$(( attempt_index + 1 ))
    done < <(github_url_candidates "${url}" | awk '!seen[$0]++')

    log_error "All GitHub download attempts failed for: ${url}"
    log_error "$(github_mirror_help)"
    return 1
}

# Fetch text content from a GitHub URL, with configurable mirror fallback.
# Returns the body on stdout and writes diagnostics to stderr.
github_fetch_text() {
    local url="${1:?github_fetch_text requires a URL}"
    local max_time="${2:-60}"
    local connect_timeout="${3:-10}"
    local candidate_url=""
    local response=""
    local attempt_index=0

    while IFS= read -r candidate_url; do
        [[ -n "${candidate_url}" ]] || continue

        if [[ "${attempt_index}" -gt 0 ]]; then
            log_info "Trying GitHub mirror fetch: ${candidate_url}" >&2
        fi

        response="$(curl -fsSL --connect-timeout "${connect_timeout}" --max-time "${max_time}" "${candidate_url}" 2>/dev/null)" || response=""
        if [[ -n "${response}" ]]; then
            printf '%s' "${response}"
            return 0
        fi

        if [[ "${attempt_index}" -eq 0 ]]; then
            log_warn "Direct GitHub fetch failed: ${url}" >&2
        fi

        attempt_index=$(( attempt_index + 1 ))
    done < <(github_url_candidates "${url}" | awk '!seen[$0]++')

    log_error "All GitHub fetch attempts failed for: ${url}" >&2
    log_error "$(github_mirror_help)" >&2
    return 1
}

# Download a GitHub raw/script and pipe to stdout (for bash <(curl ...) pattern).
# Usage: github_download_script "https://raw.githubusercontent.com/..." | bash
# Returns the content on stdout.
github_download_script() {
    local url="${1:?github_download_script requires a URL}"

    local tmp_script
    tmp_script="$(mktemp /tmp/gh-script.XXXXXX.sh)"

    if github_download "${url}" "${tmp_script}" 60 >&2; then
        cat "${tmp_script}"
        rm -f "${tmp_script}"
        return 0
    fi

    rm -f "${tmp_script}"
    return 1
}

# Clone a GitHub repository with configurable mirror fallback.
github_clone_repo() {
    local repo_url="${1:?github_clone_repo requires a repository URL}"
    local dest="${2:?github_clone_repo requires a destination path}"
    local candidate_url=""
    local attempt_index=0

    while IFS= read -r candidate_url; do
        [[ -n "${candidate_url}" ]] || continue

        if [[ "${attempt_index}" -gt 0 ]]; then
            log_info "Trying GitHub mirror clone: ${candidate_url}"
        fi

        if git clone --quiet "${candidate_url}" "${dest}" 2>/dev/null; then
            if [[ "${attempt_index}" -gt 0 ]]; then
                log_success "Cloned via configured GitHub mirror: ${candidate_url}"
            fi
            return 0
        fi

        rm -rf "${dest}" 2>/dev/null || true

        if [[ "${attempt_index}" -eq 0 ]]; then
            log_warn "Direct GitHub clone failed: ${repo_url}"
        fi

        attempt_index=$(( attempt_index + 1 ))
    done < <(github_url_candidates "${repo_url}" | awk '!seen[$0]++')

    log_error "All GitHub clone attempts failed for: ${repo_url}"
    log_error "$(github_mirror_help)"
    return 1
}

# Configure Docker daemon to use China mirror registries.
# Only applies if in China and no mirrors are already configured.
# Usage: configure_docker_mirrors
configure_docker_mirrors() {
    local daemon_json="/etc/docker/daemon.json"

    # Only configure if in China
    if ! is_in_china; then
        return 0
    fi

    # Skip if mirrors already configured
    if [[ -f "${daemon_json}" ]] && grep -q "registry-mirrors" "${daemon_json}" 2>/dev/null; then
        log_info "Docker registry mirrors already configured. Skipping."
        return 0
    fi

    log_info "Configuring Docker Hub mirrors for China network..."

    mkdir -p /etc/docker

    if [[ -f "${daemon_json}" ]]; then
        # Merge with existing config using a simple approach
        backup_file "${daemon_json}" || true
        # If file exists but has no mirrors, add them
        if command -v python3 &>/dev/null; then
            python3 -c "
import json, sys
try:
    with open('${daemon_json}') as f:
        cfg = json.load(f)
except:
    cfg = {}
cfg['registry-mirrors'] = [
    'https://docker.1ms.run',
    'https://docker.xuanyuan.me',
    'https://dockerpull.org'
]
with open('${daemon_json}', 'w') as f:
    json.dump(cfg, f, indent=2)
" 2>/dev/null || {
                # Fallback: just overwrite if python fails
                cat > "${daemon_json}" <<'DAEMON_EOF'
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me",
    "https://dockerpull.org"
  ]
}
DAEMON_EOF
            }
        else
            cat > "${daemon_json}" <<'DAEMON_EOF'
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me",
    "https://dockerpull.org"
  ]
}
DAEMON_EOF
        fi
    else
        cat > "${daemon_json}" <<'DAEMON_EOF'
{
  "registry-mirrors": [
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me",
    "https://dockerpull.org"
  ]
}
DAEMON_EOF
    fi

    # Reload Docker daemon if running
    if systemctl is-active --quiet docker 2>/dev/null; then
        systemctl daemon-reload
        systemctl restart docker
        log_success "Docker daemon restarted with China mirror registries."
    else
        log_info "Docker mirrors configured. Will take effect when Docker starts."
    fi
}

# Download Docker install script with China mirror support.
# The official get.docker.com script has its own China mirror for apt/yum repos,
# but we need to be able to download the script itself.
install_docker_china_aware() {
    if check_docker; then
        log_info "Docker is already installed and running."
        configure_docker_mirrors
        return 0
    fi

    log_info "Installing Docker CE..."
    install_if_missing curl curl

    local tmp_script
    tmp_script="$(mktemp /tmp/get-docker.XXXXXX.sh)"
    register_cleanup "${tmp_script}"

    # Try official URL first, then mirrors
    if ! github_download "https://get.docker.com" "${tmp_script}" 60; then
        # get.docker.com is not on GitHub, try direct with China-friendly alternatives
        if ! curl -fsSL --connect-timeout 15 --max-time 60 -o "${tmp_script}" "https://get.docker.com" 2>/dev/null; then
            # Last resort: use Rancher China mirror of the Docker install script
            log_info "Trying Rancher China mirror for Docker install script..."
            if ! curl -fsSL --connect-timeout 15 --max-time 60 -o "${tmp_script}" "https://releases.rancher.com/install-docker/24.0.sh" 2>/dev/null; then
                die "Failed to download Docker install script from all sources (get.docker.com + Rancher mirror)."
            fi
        fi
    fi

    chmod +x "${tmp_script}"

    # If in China, use Aliyun mirror for Docker packages
    if is_in_china; then
        log_info "Using China mirrors for Docker package installation..."
        bash "${tmp_script}" --mirror Aliyun
    else
        bash "${tmp_script}"
    fi

    # Enable & start
    systemctl enable docker
    systemctl start docker

    if ! check_docker; then
        die "Docker installation completed but the daemon is not healthy."
    fi

    # Configure Docker Hub mirrors
    configure_docker_mirrors

    # Install docker-compose plugin if not present
    if ! docker compose version &>/dev/null; then
        log_info "Installing Docker Compose plugin..."
        case "${PKG_MGR}" in
            apt)
                install_packages docker-compose-plugin
                ;;
            dnf|yum)
                install_packages docker-compose-plugin
                ;;
        esac
    fi

    log_success "Docker CE installed successfully (with China mirrors if applicable)."
}

# =============================================================================
# Section 18 : Base Dependency Installation
# =============================================================================

# Install base system dependencies required by nearly all deployment scripts.
# This function should be called early in deploy_server_a() and deploy_server_b()
# to ensure fundamental tools are available before any module-specific logic runs.
#
# Tools installed:
#   - curl      : HTTP client (downloads, API calls, connectivity checks)
#   - wget      : Fallback HTTP client
#   - jq        : JSON processor (Xray config manipulation, API responses)
#   - unzip     : Archive extraction (Xray-core, Mihomo releases)
#   - tar       : Archive creation/extraction (backups, Mihomo geodata)
#   - gzip      : Compression (Mihomo binary, log rotation)
#   - openssl   : TLS/crypto (key generation, cert verification, backup encryption)
#   - file      : File type detection (verify downloaded archives)
#   - gnupg/gpg : Repository key management (Caddy, Docker)
#   - ca-certificates : TLS root certificates
#   - lsof      : Port/process inspection (diagnostics, conflict checks)
#   - socat     : Socket relay (used by acme.sh, Hysteria cert issuance)
#
# Usage: _install_base_dependencies
_install_base_dependencies() {
    log_info "Installing base system dependencies..."

    # Ensure detect_system has been called so PKG_MGR is set
    if [[ -z "${PKG_MGR:-}" || "${PKG_MGR}" == "unknown" ]]; then
        detect_system
    fi

    # Map of command -> package name (package name may differ across distros)
    # For each tool, check if already present before installing.
    local -a base_packages=()

    # --- Core network tools ---
    if ! check_command curl; then
        base_packages+=(curl)
    fi
    if ! check_command wget; then
        base_packages+=(wget)
    fi

    # --- JSON/data processing ---
    if ! check_command jq; then
        base_packages+=(jq)
    fi

    # --- Archive tools ---
    if ! check_command unzip; then
        base_packages+=(unzip)
    fi
    if ! check_command tar; then
        base_packages+=(tar)
    fi
    if ! check_command gzip; then
        base_packages+=(gzip)
    fi

    # --- Crypto/TLS ---
    if ! check_command openssl; then
        base_packages+=(openssl)
    fi

    # --- File inspection ---
    if ! check_command file; then
        base_packages+=(file)
    fi

    # --- GPG for repo key management ---
    if ! check_command gpg; then
        case "${PKG_MGR}" in
            apt) base_packages+=(gnupg) ;;
            dnf|yum) base_packages+=(gnupg2) ;;
        esac
    fi

    # --- TLS root certificates ---
    case "${PKG_MGR}" in
        apt)
            if ! dpkg -s ca-certificates &>/dev/null 2>&1; then
                base_packages+=(ca-certificates)
            fi
            ;;
        dnf|yum)
            if ! rpm -q ca-certificates &>/dev/null 2>&1; then
                base_packages+=(ca-certificates)
            fi
            ;;
    esac

    # --- Process/port inspection ---
    if ! check_command lsof; then
        base_packages+=(lsof)
    fi

    # --- Socket relay (acme.sh, Hysteria) ---
    if ! check_command socat; then
        base_packages+=(socat)
    fi

    # --- Install all missing packages in a single batch ---
    if [[ ${#base_packages[@]} -gt 0 ]]; then
        log_info "Missing base packages: ${base_packages[*]}"
        install_packages "${base_packages[@]}"
    else
        log_info "All base dependencies already installed."
    fi

    # --- Verify critical tools are now available ---
    local critical_tools=(curl jq unzip openssl tar)
    local missing_critical=()
    for tool in "${critical_tools[@]}"; do
        if ! check_command "${tool}"; then
            missing_critical+=("${tool}")
        fi
    done

    if [[ ${#missing_critical[@]} -gt 0 ]]; then
        log_error "Critical tools still missing after install: ${missing_critical[*]}"
        log_error "Please install them manually before proceeding."
        return 1
    fi

    log_success "Base dependencies verified: ${critical_tools[*]}"
    return 0
}

# =============================================================================
# End of common.sh
# =============================================================================
if [[ "${BIFROST_TRACE_COMMON_LOAD:-0}" == "1" ]]; then
    log_info "common.sh loaded successfully."
fi
