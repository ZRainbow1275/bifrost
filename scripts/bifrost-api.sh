#!/usr/bin/env bash
# =============================================================================
# Bifrost API - Management Platform Deployment Module
# =============================================================================
# Deploys and manages the Bifrost API service, which wraps NewAPI's REST API
# to provide user registration, model monitoring, and channel management.
#
# Functions:
#   deploy_bifrost_api()   - Build and deploy the Bifrost API container
#   manage_bifrost_api()   - Interactive management menu
#
# Usage:
#   bash scripts/bifrost-api.sh                # Interactive menu
#   bash scripts/bifrost-api.sh deploy         # Deploy/update
#   bash scripts/bifrost-api.sh status         # Show status
#   bash scripts/bifrost-api.sh logs           # View logs
#   bash scripts/bifrost-api.sh restart        # Restart service
#   bash scripts/bifrost-api.sh uninstall      # Remove service
#
# Dependencies: scripts/common.sh, Docker, Docker Compose (v2 plugin)
# =============================================================================

set -euo pipefail

# Guard against double-sourcing (readonly variables would conflict)
if [[ -n "${_BIFROST_API_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
readonly _BIFROST_API_SH_LOADED=1

# Resolve the directory this script resides in
_BA_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_BA_PROJECT_DIR="$(cd "${_BA_SCRIPT_DIR}/.." && pwd)"

# Source common utilities
if [[ -f "${_BA_SCRIPT_DIR}/common.sh" ]]; then
    # shellcheck source=scripts/common.sh
    source "${_BA_SCRIPT_DIR}/common.sh"
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
    log_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
    log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
    log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
    log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
    die() { log_error "$@"; exit 1; }
    confirm_action() {
        local prompt="${1:-Continue?}"
        read -r -p "${prompt} [y/N]: " response
        [[ "${response}" =~ ^[Yy]$ ]]
    }
fi

# Compatibility shims
if ! declare -f check_command >/dev/null 2>&1; then
    check_command() { command -v "$1" &>/dev/null; }
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
readonly BIFROST_API_DIR="${_BA_PROJECT_DIR}/bifrost-api"
readonly BIFROST_API_CONTAINER="bifrost-api"
readonly BIFROST_API_PORT=8000
readonly NEW_API_CONTAINER="new-api"
readonly NEW_API_ADMIN_TOKEN_FILE="/etc/bifrost/.new-api-admin-token"

# =============================================================================
# Internal helpers
# =============================================================================

###############################################################################
# _ba_get_admin_token()
#
# Retrieve the NewAPI admin token from file, environment, or Docker container.
# Returns the token on stdout, or empty string if not found.
###############################################################################
_ba_get_admin_token() {
    # 1. Try stored file
    if [[ -f "${NEW_API_ADMIN_TOKEN_FILE}" ]]; then
        cat "${NEW_API_ADMIN_TOKEN_FILE}"
        return 0
    fi

    # 2. Try environment variable (support both NEWAPI_ADMIN_TOKEN and NEW_API_ADMIN_TOKEN)
    if [[ -n "${NEWAPI_ADMIN_TOKEN:-${NEW_API_ADMIN_TOKEN:-}}" ]]; then
        echo "${NEWAPI_ADMIN_TOKEN:-${NEW_API_ADMIN_TOKEN}}"
        return 0
    fi

    # 3. Try extracting from Docker container
    if check_command docker && docker info &>/dev/null; then
        local name token
        for name in "new-api" "newapi" "one-api" "oneapi"; do
            token="$(docker exec "${name}" printenv ADMIN_TOKEN 2>/dev/null)" || token=""
            if [[ -n "${token}" ]]; then
                # Cache for future use
                mkdir -p "$(dirname "${NEW_API_ADMIN_TOKEN_FILE}")" 2>/dev/null || true
                echo "${token}" > "${NEW_API_ADMIN_TOKEN_FILE}" 2>/dev/null || true
                chmod 600 "${NEW_API_ADMIN_TOKEN_FILE}" 2>/dev/null || true
                echo "${token}"
                return 0
            fi
        done
    fi

    return 1
}

###############################################################################
# _ba_check_newapi()
#
# Verify that NewAPI is running and accessible.
# Returns 0 if running, 1 otherwise.
###############################################################################
_ba_check_newapi() {
    # Check if the NewAPI container exists and is running
    if check_command docker && docker info &>/dev/null; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${NEW_API_CONTAINER}$"; then
            return 0
        fi
    fi

    # Fallback: check if port 3000 is responding
    if check_command curl; then
        if curl -s --connect-timeout 5 --max-time 10 "http://127.0.0.1:3000/api/status" &>/dev/null; then
            return 0
        fi
    fi

    return 1
}

###############################################################################
# _ba_wait_for_health()
#
# Wait for the Bifrost API health endpoint to respond successfully.
# Args:
#   $1 - max wait time in seconds (default: 30)
# Returns 0 on success, 1 on timeout.
###############################################################################
_ba_wait_for_health() {
    local max_wait="${1:-30}"
    local interval=2
    local elapsed=0

    log_info "Waiting for Bifrost API to become healthy (timeout: ${max_wait}s)..."

    while (( elapsed < max_wait )); do
        if curl -sf --connect-timeout 3 --max-time 5 \
            "http://127.0.0.1:${BIFROST_API_PORT}/health" &>/dev/null; then
            return 0
        fi
        sleep "${interval}"
        elapsed=$(( elapsed + interval ))
    done

    return 1
}

# =============================================================================
# Public functions
# =============================================================================

###############################################################################
# deploy_bifrost_api()
#
# Main deployment function for the Bifrost API service.
# Steps:
#   1. Check Docker availability
#   2. Verify NewAPI is running
#   3. Obtain NewAPI admin token
#   4. Generate Bifrost admin key
#   5. Create .env configuration
#   6. Build and start the container
#   7. Wait for health check
#   8. Print access information
###############################################################################
deploy_bifrost_api() {
    echo ""
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}  Bifrost API - Deploy Management Platform  ${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""

    # --- Step 1: Check Docker ---
    log_info "[1/7] Checking Docker availability..."
    if ! check_command docker; then
        die "Docker is not installed. Please install Docker first."
    fi
    if ! docker info &>/dev/null; then
        die "Docker daemon is not running. Please start Docker first."
    fi
    if ! docker compose version &>/dev/null; then
        die "Docker Compose plugin is required. Install docker-compose-plugin."
    fi
    if ! require_docker_server_version "20.10.0" "Bifrost API Docker host-gateway mapping"; then
        return 1
    fi
    log_success "Docker and Compose are available."

    # --- Step 2: Check NewAPI ---
    log_info "[2/7] Checking NewAPI status..."
    if ! _ba_check_newapi; then
        log_error "NewAPI is not running."
        log_info "Ensure the NewAPI container '${NEW_API_CONTAINER}' is running on port 3000."
        log_info "Deploy NewAPI first using the Server A deployment menu."
        return 1
    fi
    log_success "NewAPI is running."

    # --- Step 3: Get NewAPI admin token ---
    log_info "[3/7] Retrieving NewAPI admin token..."
    local admin_token=""
    admin_token="$(_ba_get_admin_token)" || admin_token=""

    if [[ -z "${admin_token}" ]]; then
        log_warn "Could not auto-detect NewAPI admin token."
        read -r -p "$(echo -e "${CYAN}Enter NewAPI admin token: ${NC}")" admin_token
        admin_token="$(echo "${admin_token}" | tr -d '[:space:]')"
        if [[ -z "${admin_token}" ]]; then
            die "NewAPI admin token is required for Bifrost API to function."
        fi
        # Cache the token
        mkdir -p "$(dirname "${NEW_API_ADMIN_TOKEN_FILE}")" 2>/dev/null || true
        echo "${admin_token}" > "${NEW_API_ADMIN_TOKEN_FILE}" 2>/dev/null || true
        chmod 600 "${NEW_API_ADMIN_TOKEN_FILE}" 2>/dev/null || true
    fi
    log_success "NewAPI admin token obtained."

    # --- Step 4: Generate Bifrost admin key ---
    log_info "[4/7] Generating Bifrost API admin key..."
    local bifrost_admin_key=""
    local env_file="${BIFROST_API_DIR}/.env"
    local public_base_url=""
    local allow_self_register="true"
    local default_quota="100"
    local max_register_per_day="50"
    local rate_limit_per_minute="30"
    local cors_allow_origins=""

    # Reuse existing key if .env already exists
    if [[ -f "${env_file}" ]]; then
        bifrost_admin_key="$(grep '^BIFROST_ADMIN_KEY=' "${env_file}" 2>/dev/null | cut -d'=' -f2-)" || bifrost_admin_key=""
        public_base_url="$(grep '^BIFROST_PUBLIC_BASE_URL=' "${env_file}" 2>/dev/null | cut -d'=' -f2-)" || public_base_url=""
        allow_self_register="$(grep '^BIFROST_ALLOW_SELF_REGISTER=' "${env_file}" 2>/dev/null | cut -d'=' -f2-)" || allow_self_register="true"
        default_quota="$(grep '^BIFROST_DEFAULT_QUOTA=' "${env_file}" 2>/dev/null | cut -d'=' -f2-)" || default_quota="100"
        max_register_per_day="$(grep '^BIFROST_MAX_REGISTER_PER_DAY=' "${env_file}" 2>/dev/null | cut -d'=' -f2-)" || max_register_per_day="50"
        rate_limit_per_minute="$(grep '^BIFROST_RATE_LIMIT_PER_MINUTE=' "${env_file}" 2>/dev/null | cut -d'=' -f2-)" || rate_limit_per_minute="30"
        cors_allow_origins="$(grep '^BIFROST_CORS_ALLOW_ORIGINS=' "${env_file}" 2>/dev/null | cut -d'=' -f2-)" || cors_allow_origins=""
    fi

    if [[ -z "${bifrost_admin_key}" ]]; then
        if declare -f generate_random_password &>/dev/null; then
            bifrost_admin_key="$(generate_random_password 32)"
        elif check_command openssl; then
            bifrost_admin_key="$(openssl rand -base64 24 | tr -d '/+\n' | head -c 32)"
        elif [[ -r /dev/urandom ]]; then
            bifrost_admin_key="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32)"
        else
            die "Cannot generate random key: no suitable random source available."
        fi
    fi
    log_success "Admin key ready."

    # --- Step 5: Create .env file ---
    log_info "[5/7] Writing environment configuration..."
    if [[ -z "${public_base_url}" ]] && [[ -f /root/server-a-domain.conf ]]; then
        # shellcheck source=/root/server-a-domain.conf
        source /root/server-a-domain.conf
        if [[ -n "${DOMAIN:-}" ]]; then
            public_base_url="https://${DOMAIN}"
        fi
    fi

    while true; do
        local prompt_suffix=""
        if [[ -n "${public_base_url}" ]]; then
            prompt_suffix=" [${public_base_url}]"
        fi

        read -r -p "$(echo -e "${CYAN}Enter public AI gateway URL for users${prompt_suffix}: ${NC}")" public_base_url_input
        public_base_url_input="${public_base_url_input:-${public_base_url}}"
        public_base_url_input="$(echo "${public_base_url_input}" | tr -d '[:space:]')"
        public_base_url_input="${public_base_url_input%/}"

        if [[ "${public_base_url_input}" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
            public_base_url="${public_base_url_input}"
            break
        fi

        log_error "Invalid public URL. Example: https://ai.your-company.com"
    done

    cat > "${env_file}" <<ENV_EOF
# Bifrost API - Environment Configuration
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')

# NewAPI base URL from the container's perspective
BIFROST_NEWAPI_BASE_URL=http://host.docker.internal:3000

# NewAPI admin token
BIFROST_NEWAPI_ADMIN_TOKEN=${admin_token}

# Bifrost API admin key (for X-Admin-Key header)
BIFROST_ADMIN_KEY=${bifrost_admin_key}

# Public AI gateway URL returned to registered users
BIFROST_PUBLIC_BASE_URL=${public_base_url}

# Registration settings
BIFROST_ALLOW_SELF_REGISTER=${allow_self_register}
BIFROST_DEFAULT_QUOTA=${default_quota}
BIFROST_MAX_REGISTER_PER_DAY=${max_register_per_day}
BIFROST_RATE_LIMIT_PER_MINUTE=${rate_limit_per_minute}

# Persist registration counters across container restarts
BIFROST_REGISTRATION_STATE_FILE=/data/registration-state.json

# Leave empty for same-origin only access
BIFROST_CORS_ALLOW_ORIGINS=${cors_allow_origins}
BIFROST_CORS_ALLOW_CREDENTIALS=false
ENV_EOF
    chmod 600 "${env_file}"
    log_success "Environment file created: ${env_file}"

    # --- Step 6: Build and start ---
    log_info "[6/7] Building and starting Bifrost API..."

    # Check for port conflict
    if check_command ss; then
        if ss -tlnp 2>/dev/null | grep -qE ":${BIFROST_API_PORT}\b"; then
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${BIFROST_API_CONTAINER}$"; then
                log_info "Existing Bifrost API container detected. Updating..."
                (cd "${BIFROST_API_DIR}" && docker compose down 2>/dev/null) || true
            else
                log_warn "Port ${BIFROST_API_PORT} is in use by another process."
                if ! confirm_action "Continue anyway (will fail if port is not freed)?"; then
                    return 1
                fi
            fi
        fi
    fi

    cd "${BIFROST_API_DIR}"

    if ! docker compose build; then
        log_error "Failed to build Bifrost API image."
        return 1
    fi

    if ! docker compose up -d; then
        log_error "Failed to start Bifrost API container."
        docker compose logs --tail 30
        return 1
    fi

    # --- Step 7: Health check ---
    log_info "[7/7] Verifying deployment..."
    if ! _ba_wait_for_health 45; then
        log_error "Bifrost API health check timed out. Refusing to print deployment summary before the service is reachable."
        log_info "Check logs with: docker compose -f ${BIFROST_API_DIR}/docker-compose.yml logs"
        return 1
    fi
    log_success "Bifrost API is healthy and running."

    # --- Print access information ---
    echo ""
    echo "==========================================="
    echo -e "${BOLD}Bifrost API - Deployment Complete${NC}"
    echo "==========================================="
    echo ""
    echo "  API Base URL:    http://127.0.0.1:${BIFROST_API_PORT}"
    echo "  API Docs:        http://127.0.0.1:${BIFROST_API_PORT}/docs"
    echo "  Health Check:    http://127.0.0.1:${BIFROST_API_PORT}/health"
    echo ""
    echo "  Public API URL:  ${public_base_url}/v1"
    echo ""
    echo "  Admin Key:       ${bifrost_admin_key}"
    echo ""
    echo "  If Caddy is configured with /manage/ proxy:"
    echo "    API Docs:      ${public_base_url}/manage/docs"
    echo "    Registration:  ${public_base_url}/manage/register"
    echo ""
    echo "  Management Commands:"
    echo "    View logs:     cd ${BIFROST_API_DIR} && docker compose logs -f"
    echo "    Restart:       cd ${BIFROST_API_DIR} && docker compose restart"
    echo "    Stop:          cd ${BIFROST_API_DIR} && docker compose down"
    echo ""
    echo -e "  ${YELLOW}IMPORTANT: Save the admin key above. It is required${NC}"
    echo -e "  ${YELLOW}for management API calls (X-Admin-Key header).${NC}"
    echo "==========================================="
    echo ""
}

###############################################################################
# _ba_show_status()
#
# Display the current status of the Bifrost API service.
###############################################################################
_ba_show_status() {
    echo ""
    echo -e "${BLUE}--- Bifrost API Status ---${NC}"
    echo ""

    # Container status
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${BIFROST_API_CONTAINER}$"; then
        local status
        status="$(docker inspect --format '{{.State.Status}}' "${BIFROST_API_CONTAINER}" 2>/dev/null)" || status="unknown"
        local uptime
        uptime="$(docker inspect --format '{{.State.StartedAt}}' "${BIFROST_API_CONTAINER}" 2>/dev/null)" || uptime="unknown"

        echo -e "  Container:  ${GREEN}${status}${NC}"
        echo "  Started:    ${uptime}"
        echo ""

        # Docker resource usage
        docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" \
            "${BIFROST_API_CONTAINER}" 2>/dev/null || true
    else
        echo -e "  Container:  ${RED}not running${NC}"
        # Check if container exists but is stopped
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${BIFROST_API_CONTAINER}$"; then
            echo -e "  Note:       Container exists but is stopped. Use 'restart' to start it."
        else
            echo -e "  Note:       Container not found. Use 'deploy' to create it."
        fi
    fi

    echo ""

    # Health check
    if curl -sf --connect-timeout 3 --max-time 5 \
        "http://127.0.0.1:${BIFROST_API_PORT}/health" 2>/dev/null; then
        echo ""
        echo -e "  Health:     ${GREEN}OK${NC}"
    else
        echo -e "  Health:     ${RED}unreachable${NC}"
    fi
    echo ""
}

###############################################################################
# _ba_show_logs()
#
# Display recent logs from the Bifrost API container.
###############################################################################
_ba_show_logs() {
    if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${BIFROST_API_CONTAINER}$"; then
        log_error "Bifrost API container not found."
        return 1
    fi

    log_info "Showing Bifrost API logs (Ctrl+C to exit)..."
    echo ""
    docker logs -f --tail 100 "${BIFROST_API_CONTAINER}"
}

###############################################################################
# _ba_restart()
#
# Restart the Bifrost API service.
###############################################################################
_ba_restart() {
    if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${BIFROST_API_CONTAINER}$"; then
        log_error "Bifrost API container not found. Deploy it first."
        return 1
    fi

    log_info "Restarting Bifrost API..."
    if ! (cd "${BIFROST_API_DIR}" && docker compose restart); then
        log_error "Failed to restart Bifrost API container."
        return 1
    fi

    if _ba_wait_for_health 30; then
        log_success "Bifrost API restarted successfully."
    else
        log_error "Bifrost API restart health check timed out."
        return 1
    fi
}

###############################################################################
# _ba_uninstall()
#
# Remove the Bifrost API container and optionally the configuration.
###############################################################################
_ba_uninstall() {
    echo ""
    log_warn "This will stop and remove the Bifrost API container."

    if ! confirm_action "Proceed with uninstall?"; then
        log_info "Uninstall cancelled."
        return 0
    fi

    # Stop and remove container
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${BIFROST_API_CONTAINER}$"; then
        log_info "Stopping and removing Bifrost API container..."
        if ! (cd "${BIFROST_API_DIR}" && docker compose down --rmi local 2>/dev/null) && \
           ! docker rm -f "${BIFROST_API_CONTAINER}" 2>/dev/null; then
            log_error "Failed to remove Bifrost API container."
            return 1
        fi
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${BIFROST_API_CONTAINER}$"; then
            log_error "Bifrost API container still exists after removal attempt."
            return 1
        fi
        log_success "Container removed."
    else
        log_info "No container to remove."
    fi

    # Ask about .env file
    local env_file="${BIFROST_API_DIR}/.env"
    if [[ -f "${env_file}" ]]; then
        if confirm_action "Remove configuration file (.env)?"; then
            if ! rm -f "${env_file}"; then
                log_error "Failed to remove configuration file: ${env_file}"
                return 1
            fi
            log_success "Configuration file removed."
        else
            log_info "Configuration file preserved at: ${env_file}"
        fi
    fi

    echo ""
    log_success "Bifrost API uninstalled."
}

###############################################################################
# manage_bifrost_api()
#
# Interactive management menu for the Bifrost API service.
###############################################################################
manage_bifrost_api() {
    while true; do
        echo ""
        echo -e "${BLUE}============================================${NC}"
        echo -e "${BLUE}  Bifrost API - Management Platform         ${NC}"
        echo -e "${BLUE}============================================${NC}"
        echo ""
        echo "  1) Deploy / Update Management Platform"
        echo "  2) View Status"
        echo "  3) View Logs"
        echo "  4) Restart Service"
        echo "  5) Uninstall"
        echo "  0) Return"
        echo ""
        read -r -p "Select option [0-5]: " choice

        case "${choice}" in
            1) echo ""; deploy_bifrost_api ;;
            2) echo ""; _ba_show_status ;;
            3) echo ""; _ba_show_logs ;;
            4) echo ""; _ba_restart ;;
            5) echo ""; _ba_uninstall ;;
            0|q|Q|exit)
                log_info "Returning to main menu."
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
        deploy)
            deploy_bifrost_api
            ;;
        status)
            _ba_show_status
            ;;
        logs)
            _ba_show_logs
            ;;
        restart)
            _ba_restart
            ;;
        uninstall)
            _ba_uninstall
            ;;
        help|--help|-h)
            echo "Bifrost API - Management Platform Deployment"
            echo ""
            echo "Usage:"
            echo "  $0                # Interactive menu"
            echo "  $0 deploy         # Deploy or update"
            echo "  $0 status         # Show status"
            echo "  $0 logs           # View logs (follow)"
            echo "  $0 restart        # Restart service"
            echo "  $0 uninstall      # Remove service"
            echo "  $0 help           # Show this help"
            ;;
        "")
            manage_bifrost_api
            ;;
        *)
            log_error "Unknown command: $1"
            echo "Run '$0 help' for usage information."
            exit 1
            ;;
    esac
fi
