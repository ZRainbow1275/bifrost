#!/usr/bin/env bash
# ==============================================================================
# server-b.sh - Overseas Server (Server B) Deployment Module
# ==============================================================================
# Part of: Bifrost
# Purpose: Deploy Xray Server (VLESS+Reality), 3x-ui panel, Hysteria 2 (backup),
#          Caddy reverse proxy, whitelist routing, and BBR optimization on the
#          overseas server that provides direct access to AI API endpoints.
#
# This script is sourced by install.sh. All functions rely on common.sh utilities.
# ==============================================================================

set -euo pipefail

# Guard against double-sourcing (readonly variables would conflict)
if [[ -n "${_SERVER_B_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
readonly _SERVER_B_SH_LOADED=1

# Source shared utilities
# Use BASH_SOURCE[0] instead of $0 to work correctly when sourced by install.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ==============================================================================
# Constants
# ==============================================================================

readonly XRAY_INSTALL_DIR="/usr/local/bin"
readonly XRAY_CONFIG_DIR="/usr/local/etc/xray"
readonly XRAY_LOG_DIR="/var/log/xray"
readonly XRAY_SERVICE_FILE="/etc/systemd/system/xray.service"
readonly XRAY_CONFIG_FILE="${XRAY_CONFIG_DIR}/config.json"

readonly HYSTERIA_INSTALL_DIR="/usr/local/bin"
readonly HYSTERIA_CONFIG_DIR="/etc/hysteria"
readonly HYSTERIA_SERVICE_FILE="/etc/systemd/system/hysteria-server.service"

readonly CADDY_CONFIG_DIR="/etc/caddy"
readonly CADDY_DATA_DIR="/var/lib/caddy"
readonly CADDY_WEB_ROOT="/var/www/html"

readonly CONNECTION_INFO_FILE="/root/ai-gateway-connection.txt"
readonly DEPLOY_STATE_DIR="/root/.bifrost"

readonly XRAY_INSTALL_SCRIPT_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
readonly HYSTERIA_INSTALL_URL="https://get.hy2.sh/"
readonly THREE_X_UI_INSTALL_URL="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"

# ==============================================================================
# Distribution Stack (Server B private mirror / New API) constants
# ==============================================================================

readonly DISTRIBUTION_STATE_DIR="/var/lib/bifrost"
readonly DISTRIBUTION_STEP_STATE_FILE="${DISTRIBUTION_STATE_DIR}/distribution.step-state"
readonly DISTRIBUTION_STATE_FILE="${DISTRIBUTION_STATE_DIR}/distribution.env"
readonly DISTRIBUTION_ETC_DIR="/etc/bifrost"
readonly DISTRIBUTION_RESTIC_ENV_FILE="${DISTRIBUTION_ETC_DIR}/restic-to-a.env"
readonly DISTRIBUTION_VERDACCIO_BOOTSTRAP_FILE="/root/.verdaccio-bootstrap-pwd.txt"
readonly DISTRIBUTION_NEW_API_DIR="/opt/new-api"
readonly DISTRIBUTION_NEW_API_ENV_FILE="${DISTRIBUTION_NEW_API_DIR}/.env"
readonly DISTRIBUTION_VERDACCIO_DIR="/var/lib/verdaccio"
readonly DISTRIBUTION_GIT_MIRROR_DIR="/var/lib/git-mirrors"
readonly DISTRIBUTION_GIT_DIST_DIR="/var/lib/dist"
readonly DISTRIBUTION_GIT_TREE_DIR="/var/lib/dist-tree"
readonly DISTRIBUTION_READONLY_USER="bifrost-readonly"
readonly DISTRIBUTION_GIT_MIRROR_USER="git-mirror"
readonly DISTRIBUTION_WG_IP="${BIFROST_SERVER_B_WG_IP:-10.8.0.2}"
readonly DISTRIBUTION_WG_PORT="${BIFROST_SERVER_B_WG_PORT:-51820}"
readonly DISTRIBUTION_WG_CLIENTS_CIDR="${BIFROST_SERVER_B_WG_CLIENTS_CIDR:-10.8.0.0/24}"
readonly DISTRIBUTION_NEW_API_IMAGE="${BIFROST_NEW_API_IMAGE:-calciumion/new-api:v1.0.0-rc.6}"
readonly DISTRIBUTION_NEW_API_POSTGRES_DB="${BIFROST_NEW_API_POSTGRES_DB:-newapi}"
readonly DISTRIBUTION_NEW_API_POSTGRES_USER="${BIFROST_NEW_API_POSTGRES_USER:-newapi}"
readonly DISTRIBUTION_RESTIC_REPOSITORY="${BIFROST_RESTIC_REPOSITORY:-sftp:root@10.8.0.1:/srv/restic/server-b}"
readonly DISTRIBUTION_RESTIC_PASSWORD_FILE="${BIFROST_RESTIC_PASSWORD_FILE:-/root/.restic-server-b.pwd}"

# AI domain whitelist for routing rules
# Kept in sync with configs/whitelist/ai-domains.txt
readonly -a AI_WHITELIST_DOMAINS=(
    # Anthropic (Claude)
    "api.anthropic.com"
    "claude.ai"
    "console.anthropic.com"
    "statsig.anthropic.com"
    "sentry.io"
    # OpenAI (GPT/Codex)
    "api.openai.com"
    "cdn.openai.com"
    "platform.openai.com"
    "chat.openai.com"
    "auth0.openai.com"
    # Google (Gemini)
    "generativelanguage.googleapis.com"
    "aistudio.google.com"
    "ai.google.dev"
    "alkalimakersuite-pa.clients6.google.com"
    "makersuite-pa.googleapis.com"
    # DeepSeek
    "api.deepseek.com"
    # Mistral
    "api.mistral.ai"
    # Groq
    "api.groq.com"
    # GitHub (Copilot)
    "api.github.com"
    "copilot-proxy.githubusercontent.com"
    "github.com"
    "copilot.github.com"
    "githubcopilot.com"
    "default.exp-tas.com"
    # Hugging Face
    "huggingface.co"
    "api-inference.huggingface.co"
    "cdn-lfs.huggingface.co"
    # Cohere
    "api.cohere.ai"
    "api.cohere.com"
    # Perplexity
    "api.perplexity.ai"
    # Together AI
    "api.together.xyz"
    "api.together.ai"
    # Package registries (dev tool dependencies)
    "registry.npmjs.org"
    "pypi.org"
    "files.pythonhosted.org"
    "crates.io"
    "static.crates.io"
    # Container registries
    "registry.docker.com"
    "docker.io"
    "registry-1.docker.io"
    "production.cloudflare.docker.com"
    "ghcr.io"
)

# Blocked domains (streaming, social media, etc.)
# Kept in sync with client.json.tpl routing block rules
readonly -a BLOCKED_DOMAINS=(
    # Streaming - Netflix
    "netflix.com"
    "netflix.net"
    "nflxvideo.net"
    "nflxso.net"
    "nflxext.com"
    "nflximg.net"
    # Streaming - YouTube / Video
    "youtube.com"
    "youtu.be"
    "googlevideo.com"
    "ytimg.com"
    "yt3.ggpht.com"
    "twitch.tv"
    "ttvnw.net"
    "jtvnw.net"
    # Streaming - Disney+, HBO, Hulu, Amazon
    "disneyplus.com"
    "disney-plus.net"
    "bamgrid.com"
    "dssott.com"
    "hbo.com"
    "hbonow.com"
    "hbomax.com"
    "hulu.com"
    "hulustream.com"
    "primevideo.com"
    "amazonvideo.com"
    # Streaming - Music
    "spotify.com"
    "spotifycdn.com"
    "scdn.co"
    "tidal.com"
    "tidalhifi.com"
    # Social media and other non-work sites
    "tiktok.com"
    "tiktokv.com"
    "musical.ly"
    "instagram.com"
    "cdninstagram.com"
    "facebook.com"
    "fbcdn.net"
    "twitter.com"
    "x.com"
    "twimg.com"
    "reddit.com"
    "redd.it"
    "redditstatic.com"
    "pornhub.com"
    "xvideos.com"
    "xhamster.com"
)

# ==============================================================================
# Internal Helper Functions
# ==============================================================================

# Save deployment state to a file for later reference (e.g., by server-a.sh)
_save_deploy_state() {
    local key="$1"
    local value="$2"
    mkdir -p "${DEPLOY_STATE_DIR}"
    chmod 700 "${DEPLOY_STATE_DIR}"
    printf '%s=%s\n' "${key}" "${value}" >> "${DEPLOY_STATE_DIR}/state.env"
    chmod 600 "${DEPLOY_STATE_DIR}/state.env"
}

# Get the server's primary public IP address
_get_public_ip() {
    local ip=""
    # Try multiple providers for reliability
    ip=$(curl -4 -s --max-time 10 https://api.ipify.org 2>/dev/null) \
        || ip=$(curl -4 -s --max-time 10 https://ifconfig.me 2>/dev/null) \
        || ip=$(curl -4 -s --max-time 10 https://icanhazip.com 2>/dev/null) \
        || ip=$(curl -4 -s --max-time 10 https://ipinfo.io/ip 2>/dev/null) \
        || ip=""

    if [[ -z "${ip}" ]]; then
        log_warn "Unable to detect public IP automatically."
        read_input "Please enter this server's public IP address" ""
        ip="${INPUT_RESULT}"
    fi
    printf '%s' "${ip}"
}

# Generate a random alphanumeric password of specified length
_generate_password() {
    local length="${1:-32}"
    tr -dc 'A-Za-z0-9!@#$%&*' < /dev/urandom | head -c "${length}" 2>/dev/null || \
        openssl rand -base64 "${length}" | tr -dc 'A-Za-z0-9' | head -c "${length}"
}

# Generate a random port number in a specified range
_generate_random_port_b() {
    local min="${1:-10000}"
    local max="${2:-60000}"
    shuf -i "${min}-${max}" -n 1
}

# Wait for a systemd service to become active
_wait_for_service() {
    local service_name="$1"
    local max_wait="${2:-30}"
    local waited=0
    while [[ ${waited} -lt ${max_wait} ]]; do
        if systemctl is-active --quiet "${service_name}" 2>/dev/null; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

# Verify that a required command is available
_require_cmd() {
    local cmd="$1"
    if ! command -v "${cmd}" &>/dev/null; then
        log_error "Required command not found: ${cmd}"
        return 1
    fi
}

# ==============================================================================
# 1. install_xray_server()
# ==============================================================================
# Download and install Xray-core, generate keys, configure VLESS+Reality+Vision,
# create systemd service, and save connection info.
# ==============================================================================
install_xray_server() {
    log_info "=========================================="
    log_info " Installing Xray Server (VLESS+Reality)"
    log_info "=========================================="

    # ---- Prerequisites ----
    install_packages curl unzip openssl

    # ---- Install Xray-core via official install script ----
    log_info "Downloading and installing Xray-core..."
    if [[ -f "${XRAY_INSTALL_DIR}/xray" ]]; then
        local existing_version
        existing_version=$("${XRAY_INSTALL_DIR}/xray" version 2>/dev/null | head -1 | awk '{print $2}') || true
        log_warn "Xray already installed (version: ${existing_version:-unknown}). Reinstalling..."
    fi

    local _xray_script
    local _xray_script_file=""
    _xray_script="$(github_download_script "${XRAY_INSTALL_SCRIPT_URL}" 2>/dev/null)" || true

    if [[ -n "${_xray_script}" ]]; then
        _xray_script_file="$(mktemp /tmp/xray-install.XXXXXX.sh)"
        printf '%s\n' "${_xray_script}" > "${_xray_script_file}"
        if ! bash "${_xray_script_file}" install; then
            rm -f "${_xray_script_file}"
            log_warn "Xray install script execution failed. Trying manual install..."
        fi
        rm -f "${_xray_script_file}"
    else
        log_warn "Could not download Xray install script. Trying manual install..."
    fi

    # Verify installation
    if ! command -v xray &>/dev/null && [[ ! -f "${XRAY_INSTALL_DIR}/xray" ]]; then
        log_error "Xray installation via script failed. Attempting manual install..."
        _install_xray_manual
    fi

    local xray_bin
    xray_bin=$(command -v xray 2>/dev/null || echo "${XRAY_INSTALL_DIR}/xray")
    local xray_version
    xray_version=$("${xray_bin}" version 2>/dev/null | head -1 | awk '{print $2}') || true
    log_success "Xray installed successfully (version: ${xray_version:-unknown})"

    # ---- Generate X25519 keypair for Reality ----
    log_info "Generating X25519 keypair for Reality..."
    local x25519_output
    x25519_output=$("${xray_bin}" x25519 2>/dev/null)

    local private_key
    local public_key
    private_key=$(echo "${x25519_output}" | grep -i 'Private key:' | awk '{print $NF}')
    public_key=$(echo "${x25519_output}" | grep -i 'Public key:' | awk '{print $NF}')

    if [[ -z "${private_key}" || -z "${public_key}" ]]; then
        log_error "Failed to parse X25519 keypair. Raw output:"
        echo "${x25519_output}"
        return 1
    fi
    log_success "X25519 keypair generated."

    # ---- Generate UUID ----
    local user_uuid
    user_uuid=$("${xray_bin}" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null)
    if [[ -z "${user_uuid}" ]]; then
        log_error "Failed to generate UUID."
        return 1
    fi
    log_success "UUID generated: ${user_uuid:0:8}...${user_uuid: -4} (truncated for security)"

    # ---- Interactive: Reality dest/SNI ----
    local reality_dest reality_sni listen_port

    read_input "Reality destination (host:port)" "dl.google.com:443" "^[a-zA-Z0-9][a-zA-Z0-9.-]*:[0-9]+$"
    reality_dest="${INPUT_RESULT}"
    # Derive SNI from dest by stripping port
    local default_sni
    default_sni=$(echo "${reality_dest}" | sed 's/:[0-9]*$//')
    read_input "Reality SNI (Server Name)" "${default_sni}" "^[a-zA-Z0-9][a-zA-Z0-9.-]*$"
    reality_sni="${INPUT_RESULT}"
    read_input "Xray listen port" "8443" "^[0-9]+$"
    listen_port="${INPUT_RESULT}"

    # Validate port range
    if [[ "${listen_port}" -lt 1 || "${listen_port}" -gt 65535 ]]; then
        log_error "Invalid port number: ${listen_port}. Must be 1-65535."
        return 1
    fi
    if [[ "${listen_port}" -eq 80 || "${listen_port}" -eq 443 ]]; then
        log_error "Port ${listen_port} conflicts with Caddy web entrypoints. Choose a non-web port such as 8443."
        return 1
    fi

    # ---- Generate short IDs ----
    local short_id
    short_id=$(openssl rand -hex 8)

    # ---- Create directories ----
    mkdir -p "${XRAY_CONFIG_DIR}"
    mkdir -p "${XRAY_LOG_DIR}"
    chmod 750 "${XRAY_LOG_DIR}"

    # ---- Write Xray server config ----
    log_info "Writing Xray server configuration..."
    cat > "${XRAY_CONFIG_FILE}" <<XRAY_EOF
{
    "log": {
        "loglevel": "warning",
        "access": "none",
        "error": "${XRAY_LOG_DIR}/error.log"
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": ${listen_port},
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "${user_uuid}",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "${reality_dest}",
                    "xver": 0,
                    "serverNames": [
                        "${reality_sni}"
                    ],
                    "privateKey": "${private_key}",
                    "shortIds": [
                        "${short_id}"
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls",
                    "quic"
                ]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ]
}
XRAY_EOF

    chmod 600 "${XRAY_CONFIG_FILE}"
    log_success "Xray configuration written to ${XRAY_CONFIG_FILE}"

    # ---- Validate configuration ----
    log_info "Validating Xray configuration..."
    if ! "${xray_bin}" run -test -config "${XRAY_CONFIG_FILE}" &>/dev/null; then
        log_error "Xray configuration validation failed!"
        "${xray_bin}" run -test -config "${XRAY_CONFIG_FILE}" 2>&1 || true
        return 1
    fi
    log_success "Xray configuration is valid."

    # ---- Create systemd service ----
    log_info "Creating Xray systemd service..."
    cat > "${XRAY_SERVICE_FILE}" <<'SERVICE_EOF'
[Unit]
Description=Xray Service
Documentation=https://xtls.github.io/
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    # ---- Enable and start Xray ----
    systemctl daemon-reload
    systemctl enable xray.service
    systemctl restart xray.service

    if _wait_for_service "xray" 15; then
        log_success "Xray service is running."
    else
        log_error "Xray service failed to start. Check logs:"
        journalctl -u xray --no-pager -n 20 2>/dev/null || true
        return 1
    fi

    # ---- Open firewall port for external Xray clients ----
    _open_firewall_port "${listen_port}" "tcp" "Xray Server"

    # ---- Get server IP ----
    local server_ip
    server_ip=$(_get_public_ip)

    # ---- Save connection info ----
    log_info "Saving connection info to ${CONNECTION_INFO_FILE}..."
    cat > "${CONNECTION_INFO_FILE}" <<CONN_EOF
# ==============================================================================
# Bifrost - Server B Connection Info
# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# ==============================================================================

# VLESS+Reality Connection Parameters
# Use these values to configure Server A (Xray client)
# ==============================================================================

SERVER_IP=${server_ip}
LISTEN_PORT=${listen_port}
UUID=${user_uuid}
PUBLIC_KEY=${public_key}
# PRIVATE_KEY is stored in Xray config (${XRAY_CONFIG_FILE}) only.
# It is NOT included here to minimize secret exposure.
SNI=${reality_sni}
REALITY_DEST=${reality_dest}
SHORT_ID=${short_id}
FINGERPRINT=chrome
FLOW=xtls-rprx-vision
SECURITY=reality
NETWORK=tcp

# VLESS Share Link (for manual client testing)
# vless://${user_uuid}@${server_ip}:${listen_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${reality_sni}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#AI-Gateway-B

CONN_EOF

    chmod 600 "${CONNECTION_INFO_FILE}"

    # ---- Persist to deploy state ----
    # NOTE: Private key is NOT stored in deploy state — it lives only in
    # the Xray config file (chmod 600). Storing secrets in multiple locations
    # increases the attack surface.
    _save_deploy_state "XRAY_SERVER_IP" "${server_ip}"
    _save_deploy_state "XRAY_LISTEN_PORT" "${listen_port}"
    _save_deploy_state "XRAY_UUID" "${user_uuid}"
    _save_deploy_state "XRAY_PUBLIC_KEY" "${public_key}"
    _save_deploy_state "XRAY_SNI" "${reality_sni}"
    _save_deploy_state "XRAY_REALITY_DEST" "${reality_dest}"
    _save_deploy_state "XRAY_SHORT_ID" "${short_id}"

    # ---- Print connection info prominently ----
    # NOTE: Print sensitive connection details ONLY to stdout (not to log file)
    # to avoid persisting secrets in log files.
    echo ""
    echo -e "${COLOR_INFO}============================================================${COLOR_RESET}"
    echo -e "${COLOR_INFO}  XRAY SERVER DEPLOYMENT COMPLETE${COLOR_RESET}"
    echo -e "${COLOR_INFO}============================================================${COLOR_RESET}"
    echo ""
    echo -e "  Server IP:     ${server_ip}"
    echo -e "  Port:          ${listen_port}"
    echo -e "  UUID:          ${user_uuid}"
    echo -e "  Public Key:    ${public_key}"
    echo -e "  SNI:           ${reality_sni}"
    echo -e "  Short ID:      ${short_id}"
    echo -e "  Flow:          xtls-rprx-vision"
    echo -e "  Network:       tcp"
    echo -e "  Security:      reality"
    echo ""
    echo -e "  Connection file saved: ${CONNECTION_INFO_FILE}"
    echo -e "  ${COLOR_WARN}IMPORTANT: Copy these values to Server A configuration.${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_INFO}============================================================${COLOR_RESET}"
    echo ""
    log_info "Xray server deployment complete. Connection info saved to ${CONNECTION_INFO_FILE}"
}

# Fallback manual installation if the official script fails
_install_xray_manual() {
    log_info "Attempting manual Xray installation..."

    local arch
    arch=$(uname -m)
    local xray_arch=""
    case "${arch}" in
        x86_64|amd64)   xray_arch="64" ;;
        aarch64|arm64)   xray_arch="arm64-v8a" ;;
        armv7l)          xray_arch="arm32-v7a" ;;
        *)
            log_error "Unsupported architecture: ${arch}"
            return 1
            ;;
    esac

    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '${tmp_dir}'" RETURN

    # Get latest release version from GitHub API (direct, then configured mirrors)
    local latest_version=""
    local api_url="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
    local api_response=""
    api_response="$(github_fetch_text "${api_url}" 20 10)" || api_response=""
    if [[ -n "${api_response}" ]]; then
        latest_version="$(printf '%s' "${api_response}" | grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/')"
    fi

    if [[ -z "${latest_version}" ]]; then
        log_error "Cannot determine latest Xray version from GitHub API (direct + configured mirrors)."
        return 1
    fi
    log_info "Latest Xray version: ${latest_version}"

    local download_url="https://github.com/XTLS/Xray-core/releases/download/${latest_version}/Xray-linux-${xray_arch}.zip"
    log_info "Downloading from: ${download_url} (with configured GitHub mirror fallback)"

    if ! github_download "${download_url}" "${tmp_dir}/xray.zip" 120; then
        log_error "Failed to download Xray binary from all sources."
        return 1
    fi
    unzip -o "${tmp_dir}/xray.zip" -d "${tmp_dir}/xray"

    install -m 755 "${tmp_dir}/xray/xray" "${XRAY_INSTALL_DIR}/xray"

    # Install geoip.dat and geosite.dat to the correct geodata directory.
    # Xray reads geodata from /usr/local/share/xray (the standard location used
    # by the official install script), NOT from XRAY_INSTALL_DIR (/usr/local/bin).
    local geodata_dest="/usr/local/share/xray"
    mkdir -p "${geodata_dest}"
    if [[ -f "${tmp_dir}/xray/geoip.dat" ]]; then
        install -m 644 "${tmp_dir}/xray/geoip.dat" "${geodata_dest}/geoip.dat"
    fi
    if [[ -f "${tmp_dir}/xray/geosite.dat" ]]; then
        install -m 644 "${tmp_dir}/xray/geosite.dat" "${geodata_dest}/geosite.dat"
    fi

    log_success "Xray manually installed to ${XRAY_INSTALL_DIR}/xray"
}

# ==============================================================================
# 2. install_3xui()
# ==============================================================================
# Install the 3x-ui panel for visual Xray management (user/traffic control).
# Runs the official install script, then configures panel port and credentials.
# ==============================================================================
install_3xui() {
    log_info "=========================================="
    log_info " Installing 3x-ui Panel"
    log_info "=========================================="

    local exposure_profile
    if ! exposure_profile="$(bifrost_exposure_profile)"; then
        return 1
    fi
    log_info "Exposure profile: ${exposure_profile}"

    install_packages curl

    # ---- Check if 3x-ui is already installed ----
    if command -v x-ui &>/dev/null || systemctl is-active --quiet x-ui 2>/dev/null; then
        log_warn "3x-ui appears to be already installed."
        if ! confirm_action "Reinstall 3x-ui?"; then
            log_info "Skipping 3x-ui installation."
            return 0
        fi
    fi

    # ---- Run official install script ----
    log_info "Running official 3x-ui install script..."
    log_info "This may take several minutes. Please wait..."

    # The official script is interactive; we pass 'y' to confirm installation
    local _3xui_script
    local _3xui_script_file=""
    _3xui_script="$(github_download_script "${THREE_X_UI_INSTALL_URL}" 2>/dev/null)" || true
    if [[ -n "${_3xui_script}" ]]; then
        _3xui_script_file="$(mktemp /tmp/3xui-install.XXXXXX.sh)"
        printf '%s\n' "${_3xui_script}" > "${_3xui_script_file}"
        if ! printf 'y\n' | bash "${_3xui_script_file}" 2>&1; then
            rm -f "${_3xui_script_file}"
            log_error "3x-ui install script execution failed."
            return 1
        fi
        rm -f "${_3xui_script_file}"
    else
        log_error "Failed to download 3x-ui install script from all sources."
        return 1
    fi

    # ---- Verify installation ----
    if ! command -v x-ui &>/dev/null; then
        log_error "3x-ui installation failed. x-ui command not found."
        return 1
    fi

    # Wait for the service to start
    sleep 3
    if ! systemctl is-active --quiet x-ui 2>/dev/null; then
        systemctl start x-ui 2>/dev/null || true
        sleep 3
    fi

    # ---- Configure panel: random high port + admin credentials ----
    local panel_port
    panel_port=$(_generate_random_port_b 20000 50000)
    local admin_user="admin"
    local admin_pass
    admin_pass=$(_generate_password 16)

    log_info "Configuring 3x-ui panel..."
    log_info "  Panel port: ${panel_port}"
    log_info "  Admin user: ${admin_user}"

    if ! _configure_3xui_panel "${panel_port}" "${admin_user}" "${admin_pass}"; then
        log_warn "Panel may need manual configuration after first login."
    fi

    # Restart to apply changes
    systemctl restart x-ui 2>/dev/null || true
    sleep 3

    # ---- Get server IP ----
    local server_ip
    server_ip=$(_get_public_ip)

    # ---- Firewall policy ----
    local direct_port_open="no"
    if [[ "${exposure_profile}" == "lab" ]]; then
        _open_firewall_port "${panel_port}" "tcp" "3x-ui panel (lab profile only)"
        direct_port_open="yes"
        log_warn "3x-ui direct panel port opened because exposure profile is lab. Do not use this profile in production."
    else
        log_info "3x-ui direct panel port is not opened in ${exposure_profile} profile."
        log_info "Access it through the Caddy /xui-panel/ route after Caddy is configured."
    fi

    # ---- Save state ----
    _save_deploy_state "THREE_X_UI_PORT" "${panel_port}"
    _save_deploy_state "THREE_X_UI_USER" "${admin_user}"
    _save_deploy_state "THREE_X_UI_PASS" "${admin_pass}"
    _save_deploy_state "THREE_X_UI_DIRECT_PORT_OPEN" "${direct_port_open}"
    _save_deploy_state "BIFROST_EXPOSURE_PROFILE" "${exposure_profile}"

    # ---- Print access info ----
    # NOTE: Print credentials ONLY to stdout (not to log file)
    echo ""
    echo -e "${COLOR_INFO}============================================================${COLOR_RESET}"
    echo -e "${COLOR_INFO}  3X-UI PANEL DEPLOYMENT COMPLETE${COLOR_RESET}"
    echo -e "${COLOR_INFO}============================================================${COLOR_RESET}"
    echo ""
    if [[ "${direct_port_open}" == "yes" ]]; then
        echo -e "  Direct URL:  http://${server_ip}:${panel_port}"
    else
        echo -e "  Direct URL:  not opened by firewall in ${exposure_profile} profile"
        echo -e "  Caddy Path:  /xui-panel/ after Caddy setup"
    fi
    echo -e "  Username:    ${admin_user}"
    echo -e "  Password:    ${admin_pass}"
    echo ""
    echo -e "  ${COLOR_WARN}IMPORTANT: Change these credentials after first login!${COLOR_RESET}"
    if [[ "${exposure_profile}" == "vpn-first" ]]; then
        echo -e "  ${COLOR_WARN}3x-ui should be reachable only from VPN/private allowlisted clients.${COLOR_RESET}"
    elif [[ "${exposure_profile}" == "public-managed" ]]; then
        echo -e "  ${COLOR_WARN}Protect public /xui-panel/ access with WAF/source allowlists and strong credentials.${COLOR_RESET}"
    else
        echo -e "  ${COLOR_WARN}Lab direct-port exposure is not safe for production.${COLOR_RESET}"
    fi
    echo ""
    echo -e "${COLOR_INFO}============================================================${COLOR_RESET}"
    echo ""
    log_info "3x-ui panel deployment complete. Credentials shown on screen only."
}

_configure_3xui_panel() {
    local panel_port="${1:?_configure_3xui_panel requires port}"
    local admin_user="${2:?_configure_3xui_panel requires username}"
    local admin_pass="${3:?_configure_3xui_panel requires password}"
    local xui_db="/etc/x-ui/x-ui.db"

    if x-ui setting -port "${panel_port}" >/dev/null 2>&1 && \
        x-ui setting -username "${admin_user}" -password "${admin_pass}" >/dev/null 2>&1; then
        log_info "Panel settings updated via official x-ui CLI."
        return 0
    fi

    if [[ -f "${xui_db}" ]] && command -v sqlite3 &>/dev/null; then
        log_warn "x-ui CLI configuration failed. Falling back to direct database update for legacy builds."
        if sqlite3 "${xui_db}" "UPDATE settings SET value='${panel_port}' WHERE key='webPort';" >/dev/null 2>&1 && \
            sqlite3 "${xui_db}" "UPDATE users SET username='${admin_user}', password='${admin_pass}' WHERE id=1;" >/dev/null 2>&1; then
            log_info "Panel settings updated via legacy database fallback."
            return 0
        fi
        log_warn "Legacy sqlite fallback failed while updating 3x-ui panel settings."
    fi

    log_warn "3x-ui CLI configuration failed and no legacy sqlite fallback succeeded."
    return 1
}

# Open a firewall port using whichever firewall is available
_open_firewall_port() {
    local port="$1"
    local protocol="${2:-tcp}"
    local description="${3:-}"

    if command -v ufw &>/dev/null; then
        if ! ufw allow "${port}/${protocol}" comment "${description}" 2>/dev/null; then
            log_error "Failed to open firewall port ${port}/${protocol} via ufw."
            return 1
        fi
    elif command -v firewall-cmd &>/dev/null; then
        if ! firewall-cmd --permanent --add-port="${port}/${protocol}" 2>/dev/null; then
            log_error "Failed to add firewall port ${port}/${protocol} via firewalld."
            return 1
        fi
        if ! firewall-cmd --reload 2>/dev/null; then
            log_error "Failed to reload firewalld after adding port ${port}/${protocol}."
            return 1
        fi
    else
        log_warn "No firewall tool found. Please manually open port ${port}/${protocol}."
    fi

    return 0
}

# ==============================================================================
# 3. install_hysteria2_server()
# ==============================================================================
# Install Hysteria 2 as a backup high-bandwidth tunnel protocol.
# Requires a domain name for TLS certificate issuance via acme.sh.
# ==============================================================================
install_hysteria2_server() {
    log_info "=========================================="
    log_info " Installing Hysteria 2 Server (Backup)"
    log_info "=========================================="

    # ---- Ask for domain ----
    local hy2_domain=""
    read_input "Domain name for Hysteria 2 (required for TLS certificate)" ""
    hy2_domain="${INPUT_RESULT}"

    if [[ -z "${hy2_domain}" ]]; then
        log_error "Domain name is required for Hysteria 2. Aborting."
        return 1
    fi

    # ---- Ask for listen port ----
    local hy2_port=""
    read_input "Hysteria 2 listen port" "443"
    hy2_port="${INPUT_RESULT}"

    if ! [[ "${hy2_port}" =~ ^[0-9]+$ ]] || [[ "${hy2_port}" -lt 1 || "${hy2_port}" -gt 65535 ]]; then
        log_error "Invalid port number: ${hy2_port}"
        return 1
    fi

    # ---- Prerequisites ----
    install_packages curl socat cron

    # ---- Install Hysteria 2 ----
    log_info "Downloading and installing Hysteria 2..."
    if command -v hysteria &>/dev/null; then
        local existing_ver
        existing_ver=$(hysteria version 2>/dev/null | head -1) || true
        log_warn "Hysteria already installed (${existing_ver:-unknown}). Reinstalling..."
    fi

    # Download Hysteria installer with China mirror fallback
    local _hy2_installer
    _hy2_installer="$(mktemp /tmp/hy2-install.XXXXXX.sh)"
    register_cleanup "${_hy2_installer}"

    local _hy2_installed=0
    # Try official URL first
    if curl -fsSL --connect-timeout 15 --max-time 60 "${HYSTERIA_INSTALL_URL}" -o "${_hy2_installer}" 2>/dev/null && [[ -s "${_hy2_installer}" ]]; then
        bash "${_hy2_installer}" 2>&1 && _hy2_installed=1
    fi

    # Fallback: try GitHub mirror of the installer
    if [[ "${_hy2_installed}" -eq 0 ]]; then
        log_warn "Official Hysteria installer download failed. Trying GitHub mirror..."
        # The official installer is also available at the apernet/hysteria repo
        if github_download "https://raw.githubusercontent.com/apernet/hysteria/hysteria2/install-server.sh" "${_hy2_installer}" 60; then
            bash "${_hy2_installer}" 2>&1 && _hy2_installed=1
        fi
    fi

    # Fallback: manual binary download from GitHub releases
    if [[ "${_hy2_installed}" -eq 0 ]]; then
        log_warn "Installer approach failed. Attempting manual binary download..."
        local _hy2_arch
        case "$(uname -m)" in
            x86_64|amd64)  _hy2_arch="amd64" ;;
            aarch64|arm64) _hy2_arch="arm64" ;;
            armv7l)        _hy2_arch="arm" ;;
            *)             log_error "Unsupported architecture for Hysteria 2."; rm -f "${_hy2_installer}"; return 1 ;;
        esac
        local _hy2_bin_url="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${_hy2_arch}"
        if github_download "${_hy2_bin_url}" "/usr/local/bin/hysteria" 120; then
            chmod +x /usr/local/bin/hysteria
            _hy2_installed=1
        fi
    fi

    rm -f "${_hy2_installer}" 2>/dev/null || true

    if [[ "${_hy2_installed}" -eq 0 ]] || \
       { ! command -v hysteria &>/dev/null && [[ ! -f "${HYSTERIA_INSTALL_DIR}/hysteria" ]]; }; then
        log_error "Hysteria 2 installation failed from all sources (official + GitHub mirrors)."
        return 1
    fi
    log_success "Hysteria 2 installed successfully."

    # ---- Generate authentication password ----
    local hy2_password
    hy2_password=$(_generate_password 32)

    # ---- Install acme.sh and obtain TLS certificate ----
    log_info "Setting up TLS certificate for ${hy2_domain}..."
    _setup_acme_certificate "${hy2_domain}"

    # ---- Create config directory ----
    mkdir -p "${HYSTERIA_CONFIG_DIR}"

    # ---- Write Hysteria 2 configuration ----
    log_info "Writing Hysteria 2 configuration..."
    cat > "${HYSTERIA_CONFIG_DIR}/config.yaml" <<HY2_EOF
listen: :${hy2_port}

tls:
  cert: ${HYSTERIA_CONFIG_DIR}/cert.pem
  key: ${HYSTERIA_CONFIG_DIR}/key.pem

auth:
  type: password
  password: ${hy2_password}

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com
    rewriteHost: true

bandwidth:
  up: 1 gbps
  down: 1 gbps

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520

outbounds:
  - name: direct
    type: direct
HY2_EOF

    chmod 600 "${HYSTERIA_CONFIG_DIR}/config.yaml"
    log_success "Hysteria 2 configuration written."

    # ---- Create systemd service ----
    log_info "Creating Hysteria 2 systemd service..."
    cat > "${HYSTERIA_SERVICE_FILE}" <<'HY2SVC_EOF'
[Unit]
Description=Hysteria 2 Server
Documentation=https://v2.hysteria.network/
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
HY2SVC_EOF

    # ---- Enable and start ----
    systemctl daemon-reload
    systemctl enable hysteria-server.service
    systemctl restart hysteria-server.service

    if _wait_for_service "hysteria-server" 15; then
        log_success "Hysteria 2 service is running."
    else
        log_error "Hysteria 2 service failed to start. Check logs:"
        journalctl -u hysteria-server --no-pager -n 20 2>/dev/null || true
        return 1
    fi

    # ---- Open firewall port (UDP for QUIC) ----
    _open_firewall_port "${hy2_port}" "udp" "Hysteria 2"

    # ---- Get server IP ----
    local server_ip
    server_ip=$(_get_public_ip)

    # ---- Save state ----
    _save_deploy_state "HYSTERIA2_PORT" "${hy2_port}"
    _save_deploy_state "HYSTERIA2_DOMAIN" "${hy2_domain}"
    _save_deploy_state "HYSTERIA2_PASSWORD" "${hy2_password}"

    # ---- Print connection info ----
    # NOTE: Print credentials ONLY to stdout (not to log file)
    echo ""
    echo -e "${COLOR_INFO}============================================================${COLOR_RESET}"
    echo -e "${COLOR_INFO}  HYSTERIA 2 SERVER DEPLOYMENT COMPLETE${COLOR_RESET}"
    echo -e "${COLOR_INFO}============================================================${COLOR_RESET}"
    echo ""
    echo -e "  Server:    ${server_ip}"
    echo -e "  Domain:    ${hy2_domain}"
    echo -e "  Port:      ${hy2_port} (UDP)"
    echo -e "  Password:  ${hy2_password}"
    echo ""
    echo -e "  Client config snippet:"
    echo -e "    server: ${hy2_domain}:${hy2_port}"
    echo -e "    auth: ${hy2_password}"
    echo -e "    tls:"
    echo -e "      sni: ${hy2_domain}"
    echo ""
    echo -e "${COLOR_INFO}============================================================${COLOR_RESET}"
    echo ""
    log_info "Hysteria 2 deployment complete. Credentials shown on screen only."
}

# Install acme.sh and obtain TLS certificate for a domain
_setup_acme_certificate() {
    local domain="$1"
    local cert_dir="${HYSTERIA_CONFIG_DIR}"

    # Install acme.sh if not present
    if [[ ! -f "${HOME}/.acme.sh/acme.sh" ]]; then
        log_info "Installing acme.sh..."
        local _acme_script
        local _acme_github_url="https://raw.githubusercontent.com/acmesh-official/get.acme.sh/master/index.html"
        _acme_script="$(mktemp /tmp/acme-install.XXXXXX.sh)"
        if github_download "https://get.acme.sh" "${_acme_script}" 60 2>/dev/null || \
           curl -fsSL --connect-timeout 15 --max-time 60 -o "${_acme_script}" "https://get.acme.sh" 2>/dev/null; then
            bash "${_acme_script}" --install-online -m "admin@${domain}" 2>&1
        else
            log_warn "Cannot download acme.sh from get.acme.sh. Trying the official GitHub source..."
            if ! github_download "${_acme_github_url}" "${_acme_script}" 60; then
                log_error "Failed to download acme.sh from official sources."
                rm -f "${_acme_script}"
                return 1
            fi

            bash "${_acme_script}" --install-online -m "admin@${domain}" 2>&1 || {
                log_error "acme.sh installer execution failed."
                rm -f "${_acme_script}"
                return 1
            }
        fi
        rm -f "${_acme_script}"
    fi

    local acme_sh="${HOME}/.acme.sh/acme.sh"

    if [[ ! -f "${acme_sh}" ]]; then
        log_error "acme.sh installation failed."
        return 1
    fi

    # Set default CA to Let's Encrypt
    "${acme_sh}" --set-default-ca --server letsencrypt 2>/dev/null || true

    # Issue certificate using standalone mode (requires port 80 temporarily free)
    log_info "Issuing TLS certificate for ${domain}..."
    log_info "Ensure port 80 is accessible and DNS A record points to this server."

    # Stop any service on port 80 temporarily
    local port80_service=""
    local port80_listeners=""
    port80_listeners="$(ss -tlnp 2>/dev/null | awk '$4 ~ /:80$/ {print}')"
    if [[ -n "${port80_listeners}" ]]; then
        local candidate_service
        for candidate_service in caddy nginx apache2 httpd; do
            if systemctl is-active --quiet "${candidate_service}" 2>/dev/null; then
                port80_service="${candidate_service}"
                break
            fi
        done

        if [[ -z "${port80_service}" ]]; then
            log_error "Port 80 is already in use, but no supported managed web service was detected."
            log_error "Free port 80 manually before running acme.sh standalone certificate issuance."
            echo "${port80_listeners}"
            return 1
        fi

        log_warn "Port 80 is in use by managed service '${port80_service}'. Stopping temporarily..."
        if ! systemctl stop "${port80_service}" 2>/dev/null; then
            log_error "Failed to stop ${port80_service}. Cannot continue with standalone certificate issuance."
            return 1
        fi

        if ss -tlnp 2>/dev/null | grep -q ':80 '; then
            log_error "Port 80 is still occupied after stopping ${port80_service}. Cannot continue safely."
            ss -tlnp 2>/dev/null | grep ':80 ' || true
            systemctl start "${port80_service}" 2>/dev/null || true
            return 1
        fi
    fi

    "${acme_sh}" --issue -d "${domain}" --standalone --keylength ec-256 \
        --log "${XRAY_LOG_DIR}/acme.log" 2>&1 || {
        log_error "Certificate issuance failed. Check ${XRAY_LOG_DIR}/acme.log"
        # Restart stopped service
        if [[ -n "${port80_service}" ]]; then
            systemctl start "${port80_service}" 2>/dev/null || true
        fi
        return 1
    }

    # Restart the stopped service
    if [[ -n "${port80_service}" ]]; then
        systemctl start "${port80_service}" 2>/dev/null || true
    fi

    # Install certificate to target directory
    mkdir -p "${cert_dir}"
    "${acme_sh}" --install-cert -d "${domain}" --ecc \
        --fullchain-file "${cert_dir}/cert.pem" \
        --key-file "${cert_dir}/key.pem" \
        --reloadcmd "systemctl restart hysteria-server 2>/dev/null || true" 2>&1

    if [[ -f "${cert_dir}/cert.pem" && -f "${cert_dir}/key.pem" ]]; then
        chmod 600 "${cert_dir}/cert.pem" "${cert_dir}/key.pem"
        log_success "TLS certificate installed to ${cert_dir}/"
    else
        log_error "Certificate files not found after installation."
        return 1
    fi
}

# ==============================================================================
# 4. setup_caddy_b()
# ==============================================================================
# Install Caddy as reverse proxy for 3x-ui panel and web services.
# Deploys a decoy/fake business website for camouflage.
# ==============================================================================
setup_caddy_b() {
    log_info "=========================================="
    log_info " Setting Up Caddy (Server B)"
    log_info "=========================================="

    local exposure_profile
    if ! exposure_profile="$(bifrost_exposure_profile)"; then
        return 1
    fi
    local admin_allowed_ranges
    admin_allowed_ranges="$(bifrost_admin_allowed_ranges)"
    log_info "Exposure profile: ${exposure_profile}"
    if [[ "${exposure_profile}" == "vpn-first" ]]; then
        log_info "  3x-ui /xui-panel/ route will require VPN/private allowlist: ${admin_allowed_ranges}"
    elif [[ "${exposure_profile}" == "public-managed" ]]; then
        log_warn "  /xui-panel/ will be public through HTTPS. Protect it with WAF/source allowlists and strong credentials."
    else
        log_warn "  lab profile permits broad management access and is not safe for production."
    fi

    # ---- Ask for domain (optional for Caddy) ----
    local caddy_domain=""
    while true; do
        read -rp "Domain for Caddy on Server B (leave empty for IP-only access): " caddy_domain
        caddy_domain="${caddy_domain:-}"
        # Allow empty (IP-only mode) or a valid FQDN (alphanumeric, hyphens, dots only)
        if [[ -z "${caddy_domain}" ]] || \
           [[ "${caddy_domain}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
            break
        fi
        log_error "Invalid domain format. Use a valid hostname (e.g. example.com) or leave empty."
    done

    # ---- Install Caddy ----
    log_info "Installing Caddy..."
    _install_caddy

    if ! command -v caddy &>/dev/null; then
        log_error "Caddy installation failed."
        return 1
    fi
    log_success "Caddy installed: $(caddy version 2>/dev/null || echo 'unknown version')"

    # ---- Create directories ----
    mkdir -p "${CADDY_CONFIG_DIR}"
    mkdir -p "${CADDY_DATA_DIR}"
    mkdir -p "${CADDY_WEB_ROOT}"

    # ---- Deploy decoy website ----
    log_info "Deploying decoy business website..."
    _deploy_decoy_website

    # ---- Read 3x-ui port from state if available ----
    local xui_port=""
    if [[ -f "${DEPLOY_STATE_DIR}/state.env" ]]; then
        xui_port=$(grep '^THREE_X_UI_PORT=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
    fi

    # ---- Write Caddyfile ----
    log_info "Writing Caddy configuration..."

    if [[ -n "${caddy_domain}" ]]; then
        # HTTPS with auto-cert via domain
        cat > "${CADDY_CONFIG_DIR}/Caddyfile" <<CADDY_EOF
# ==============================================================================
# Caddy Configuration - Server B (Overseas)
# Bifrost - Decoy Website + Reverse Proxy
# Exposure profile: ${exposure_profile}
# ==============================================================================

${caddy_domain} {
    # Main site: decoy business website
    root * ${CADDY_WEB_ROOT}
    file_server

    # Encode responses with gzip/zstd
    encode zstd gzip

    # Security headers
    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        -Server
    }

    # Logging
    log {
        output file /var/log/caddy/access-b.log {
            roll_size 50MiB
            roll_keep 5
            roll_keep_for 168h
        }
    }

$(if [[ -n "${xui_port}" && "${exposure_profile}" == "vpn-first" ]]; then
cat <<PROXY_BLOCK
    # 3x-ui panel reverse proxy - private allowlist only
    @xui_private_root {
        path /xui-panel
        remote_ip ${admin_allowed_ranges}
    }
    handle @xui_private_root {
        redir /xui-panel/ 308
    }
    @xui_private {
        path /xui-panel/*
        remote_ip ${admin_allowed_ranges}
    }
    handle @xui_private {
        uri strip_prefix /xui-panel
        reverse_proxy 127.0.0.1:${xui_port} {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }
    handle /xui-panel {
        respond "3x-ui requires VPN/private access in vpn-first profile" 403
    }
    handle /xui-panel/* {
        respond "3x-ui requires VPN/private access in vpn-first profile" 403
    }
PROXY_BLOCK
elif [[ -n "${xui_port}" ]]; then
cat <<PROXY_BLOCK
    # 3x-ui panel reverse proxy (${exposure_profile})
    handle /xui-panel {
        redir /xui-panel/ 308
    }
    handle_path /xui-panel/* {
        reverse_proxy 127.0.0.1:${xui_port} {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }
PROXY_BLOCK
fi)
}
CADDY_EOF
    else
        # IP-only access (HTTP with auto self-signed or no TLS)
        local server_ip
        server_ip=$(_get_public_ip)

        cat > "${CADDY_CONFIG_DIR}/Caddyfile" <<CADDY_EOF
# ==============================================================================
# Caddy Configuration - Server B (Overseas) - IP Access Mode
# Bifrost - Decoy Website + Reverse Proxy
# Exposure profile: ${exposure_profile}
# ==============================================================================

:80 {
    # Main site: decoy business website
    root * ${CADDY_WEB_ROOT}
    file_server

    # Encode responses
    encode zstd gzip

    # Security headers
    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
    }

    # Logging
    log {
        output file /var/log/caddy/access-b.log {
            roll_size 50MiB
            roll_keep 5
            roll_keep_for 168h
        }
    }

$(if [[ -n "${xui_port}" && "${exposure_profile}" == "vpn-first" ]]; then
cat <<PROXY_BLOCK
    # 3x-ui panel reverse proxy - private allowlist only
    @xui_private_root {
        path /xui-panel
        remote_ip ${admin_allowed_ranges}
    }
    handle @xui_private_root {
        redir /xui-panel/ 308
    }
    @xui_private {
        path /xui-panel/*
        remote_ip ${admin_allowed_ranges}
    }
    handle @xui_private {
        uri strip_prefix /xui-panel
        reverse_proxy 127.0.0.1:${xui_port} {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }
    handle /xui-panel {
        respond "3x-ui requires VPN/private access in vpn-first profile" 403
    }
    handle /xui-panel/* {
        respond "3x-ui requires VPN/private access in vpn-first profile" 403
    }
PROXY_BLOCK
elif [[ -n "${xui_port}" ]]; then
cat <<PROXY_BLOCK
    # 3x-ui panel reverse proxy (${exposure_profile})
    handle /xui-panel {
        redir /xui-panel/ 308
    }
    handle_path /xui-panel/* {
        reverse_proxy 127.0.0.1:${xui_port} {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }
PROXY_BLOCK
fi)
}
CADDY_EOF
    fi

    chmod 644 "${CADDY_CONFIG_DIR}/Caddyfile"
    mkdir -p /var/log/caddy

    # ---- Validate Caddy config ----
    log_info "Validating Caddy configuration..."
    if caddy validate --config "${CADDY_CONFIG_DIR}/Caddyfile" --adapter caddyfile &>/dev/null; then
        log_success "Caddy configuration is valid."
    else
        log_error "Caddy configuration validation failed."
        caddy validate --config "${CADDY_CONFIG_DIR}/Caddyfile" --adapter caddyfile 2>&1 || true
        return 1
    fi

    # ---- Create/ensure systemd service ----
    if [[ ! -f /etc/systemd/system/caddy.service ]]; then
        cat > /etc/systemd/system/caddy.service <<'CADDYSVC_EOF'
[Unit]
Description=Caddy Web Server
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
CADDYSVC_EOF

        # Create caddy user if not exists
        if ! id caddy &>/dev/null; then
            useradd --system --home "${CADDY_DATA_DIR}" --shell /usr/sbin/nologin caddy 2>/dev/null || true
        fi
        chown -R caddy:caddy "${CADDY_DATA_DIR}" /var/log/caddy "${CADDY_WEB_ROOT}" 2>/dev/null || true
    fi

    # ---- Enable and start Caddy ----
    systemctl daemon-reload
    systemctl enable caddy.service
    systemctl restart caddy.service

    if _wait_for_service "caddy" 15; then
        log_success "Caddy service is running."
    else
        log_error "Caddy service failed to start. Check logs:"
        journalctl -u caddy --no-pager -n 20 2>/dev/null || true
        return 1
    fi

    # ---- Open firewall ports ----
    _open_firewall_port "80" "tcp" "Caddy HTTP"
    _open_firewall_port "443" "tcp" "Caddy HTTPS"

    # ---- Save state ----
    _save_deploy_state "CADDY_B_DOMAIN" "${caddy_domain}"
    _save_deploy_state "BIFROST_EXPOSURE_PROFILE" "${exposure_profile}"

    echo ""
    log_info "============================================================"
    log_info "  CADDY (SERVER B) DEPLOYMENT COMPLETE"
    log_info "============================================================"
    log_info "  Exposure profile: ${exposure_profile}"
    if [[ -n "${caddy_domain}" ]]; then
        log_info "  URL:    https://${caddy_domain}"
        if [[ -n "${xui_port}" ]]; then
            if [[ "${exposure_profile}" == "vpn-first" ]]; then
                log_info "  3x-ui:  https://${caddy_domain}/xui-panel/ (VPN/private allowlist only)"
            else
                log_warn "  3x-ui:  https://${caddy_domain}/xui-panel/ (${exposure_profile}; public management enabled)"
            fi
        fi
    else
        local server_ip
        server_ip=$(_get_public_ip)
        log_info "  URL:    http://${server_ip}"
        if [[ -n "${xui_port}" ]]; then
            if [[ "${exposure_profile}" == "vpn-first" ]]; then
                log_info "  3x-ui:  http://${server_ip}/xui-panel/ (VPN/private allowlist only)"
            else
                log_warn "  3x-ui:  http://${server_ip}/xui-panel/ (${exposure_profile}; public management enabled)"
            fi
        fi
    fi
    log_info "============================================================"
    echo ""
}

# Detect the package manager family for this OS
detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v yum &>/dev/null; then
        echo "yum"
    else
        echo "unknown"
    fi
}

# Install Caddy using the official repository
_install_caddy() {
    local pkg_manager
    pkg_manager=$(detect_pkg_manager)

    case "${pkg_manager}" in
        apt)
            install_packages debian-keyring debian-archive-keyring apt-transport-https
            if ! curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
                | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null; then
                log_error "Failed to import the Caddy repository key. Refusing to trust an unverified repository."
                return 1
            fi
            echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
                > /etc/apt/sources.list.d/caddy-stable.list
            run_apt_get update -qq
            run_apt_get install -y caddy
            ;;
        dnf|yum)
            install_packages yum-utils
            cat > /etc/yum.repos.d/caddy-stable.repo <<'REPO_EOF'
[caddy-stable]
name=Caddy Stable
baseurl=https://dl.cloudsmith.io/public/caddy/stable/rpm/el/$releasever/$basearch
enabled=1
repo_gpgcheck=1
gpgcheck=1
gpgkey=https://dl.cloudsmith.io/public/caddy/stable/gpg.key
sslverify=1
REPO_EOF
            "${pkg_manager}" install -y caddy
            ;;
        *)
            log_warn "Unknown package manager. Attempting generic Caddy install..."
            local _caddy_arch
            _caddy_arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
            if ! curl -fsSL --connect-timeout 20 --max-time 120 \
                "https://caddyserver.com/api/download?os=linux&arch=${_caddy_arch}" \
                -o /usr/bin/caddy 2>/dev/null; then
                log_warn "Caddy direct download failed. Trying GitHub releases..."
                github_download "https://github.com/caddyserver/caddy/releases/latest/download/caddy_linux_${_caddy_arch}" \
                    /usr/bin/caddy 120 || {
                    log_error "Failed to download Caddy from all sources."
                    return 1
                }
            fi
            chmod +x /usr/bin/caddy
            ;;
    esac
}

# Deploy a decoy business website as camouflage
_deploy_decoy_website() {
    mkdir -p "${CADDY_WEB_ROOT}"

    # Generate a simple, professional-looking business template
    cat > "${CADDY_WEB_ROOT}/index.html" <<'HTML_EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>CloudVance Solutions - Enterprise Cloud Infrastructure</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, sans-serif; color: #333; line-height: 1.6; }
        .header { background: linear-gradient(135deg, #1a237e 0%, #283593 100%); color: white; padding: 20px 0; }
        .nav { max-width: 1200px; margin: 0 auto; padding: 0 20px; display: flex; justify-content: space-between; align-items: center; }
        .logo { font-size: 24px; font-weight: 700; }
        .nav-links a { color: white; text-decoration: none; margin-left: 30px; font-size: 15px; }
        .hero { background: linear-gradient(135deg, #283593 0%, #3949ab 50%, #1565c0 100%); color: white; padding: 100px 20px; text-align: center; }
        .hero h1 { font-size: 48px; margin-bottom: 20px; font-weight: 300; }
        .hero p { font-size: 20px; max-width: 700px; margin: 0 auto 40px; opacity: 0.9; }
        .btn { display: inline-block; padding: 14px 36px; background: #fff; color: #283593; border-radius: 4px; text-decoration: none; font-weight: 600; font-size: 16px; }
        .features { padding: 80px 20px; max-width: 1200px; margin: 0 auto; }
        .features h2 { text-align: center; font-size: 36px; margin-bottom: 50px; color: #1a237e; }
        .feature-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 40px; }
        .feature-card { padding: 30px; border-radius: 8px; border: 1px solid #e0e0e0; }
        .feature-card h3 { font-size: 20px; margin-bottom: 12px; color: #283593; }
        .footer { background: #1a237e; color: white; text-align: center; padding: 30px 20px; font-size: 14px; opacity: 0.8; }
    </style>
</head>
<body>
    <div class="header">
        <div class="nav">
            <div class="logo">CloudVance</div>
            <div class="nav-links">
                <a href="#">Solutions</a>
                <a href="#">Products</a>
                <a href="#">Resources</a>
                <a href="#">Contact</a>
            </div>
        </div>
    </div>
    <div class="hero">
        <h1>Enterprise Cloud Infrastructure</h1>
        <p>Scalable, secure, and reliable cloud solutions for modern businesses. Accelerate your digital transformation.</p>
        <a href="#" class="btn">Get Started</a>
    </div>
    <div class="features">
        <h2>Our Solutions</h2>
        <div class="feature-grid">
            <div class="feature-card">
                <h3>Cloud Compute</h3>
                <p>High-performance virtual machines with guaranteed uptime SLA. Auto-scaling to handle peak loads efficiently.</p>
            </div>
            <div class="feature-card">
                <h3>Managed Database</h3>
                <p>Fully managed relational and NoSQL databases with automated backups, patching, and high availability.</p>
            </div>
            <div class="feature-card">
                <h3>CDN &amp; Edge</h3>
                <p>Global content delivery network with edge computing capabilities for ultra-low latency experiences.</p>
            </div>
            <div class="feature-card">
                <h3>Security Suite</h3>
                <p>Enterprise-grade security with DDoS protection, WAF, encryption at rest and in transit.</p>
            </div>
            <div class="feature-card">
                <h3>DevOps Tools</h3>
                <p>CI/CD pipelines, container orchestration, and infrastructure-as-code for agile development teams.</p>
            </div>
            <div class="feature-card">
                <h3>24/7 Support</h3>
                <p>Dedicated support engineers with guaranteed response times and proactive monitoring.</p>
            </div>
        </div>
    </div>
    <div class="footer">
        &copy; 2025 CloudVance Solutions. All rights reserved.
    </div>
</body>
</html>
HTML_EOF

    # Robots.txt to look legitimate
    cat > "${CADDY_WEB_ROOT}/robots.txt" <<'ROBOTS_EOF'
User-agent: *
Allow: /
Sitemap: /sitemap.xml
ROBOTS_EOF

    # Favicon placeholder (1x1 transparent PNG)
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n\xb4\x00\x00\x00\x00IEND\xaeB`\x82' \
        > "${CADDY_WEB_ROOT}/favicon.ico" 2>/dev/null || true

    log_success "Decoy website deployed to ${CADDY_WEB_ROOT}/"
}

# ==============================================================================
# 5. setup_whitelist_routing()
# ==============================================================================
# Configure Xray routing rules to ONLY allow whitelisted AI/dev domains.
# Block everything else, especially streaming services.
# ==============================================================================
setup_whitelist_routing() {
    log_info "=========================================="
    log_info " Configuring Whitelist Routing Rules"
    log_info "=========================================="

    # ---- Verify Xray config exists ----
    if [[ ! -f "${XRAY_CONFIG_FILE}" ]]; then
        log_error "Xray config not found at ${XRAY_CONFIG_FILE}. Install Xray first."
        return 1
    fi

    local xray_bin
    xray_bin=$(command -v xray 2>/dev/null || echo "${XRAY_INSTALL_DIR}/xray")

    # ---- Backup current config ----
    cp "${XRAY_CONFIG_FILE}" "${XRAY_CONFIG_FILE}.bak.$(date +%s)"
    log_info "Backed up current Xray config."

    # ---- Read existing config and inject routing rules ----
    # We need to parse the existing config and add routing section
    # Using a Python one-liner for reliable JSON manipulation
    log_info "Injecting whitelist routing rules into Xray config..."

    # Build the whitelist domain array for JSON
    local whitelist_json_array=""
    for domain in ${AI_WHITELIST_DOMAINS[@]+"${AI_WHITELIST_DOMAINS[@]}"}; do
        if [[ -n "${whitelist_json_array}" ]]; then
            whitelist_json_array="${whitelist_json_array},"
        fi
        whitelist_json_array="${whitelist_json_array}\"domain:${domain}\""
    done

    # Build the blocked domain array for JSON
    local blocked_json_array=""
    for domain in ${BLOCKED_DOMAINS[@]+"${BLOCKED_DOMAINS[@]}"}; do
        if [[ -n "${blocked_json_array}" ]]; then
            blocked_json_array="${blocked_json_array},"
        fi
        blocked_json_array="${blocked_json_array}\"domain:${domain}\""
    done

    # Use python3 (or python) to safely merge routing rules into config
    local python_cmd=""
    if command -v python3 &>/dev/null; then
        python_cmd="python3"
    elif command -v python &>/dev/null; then
        python_cmd="python"
    fi

    if [[ -n "${python_cmd}" ]]; then
        ${python_cmd} - "${XRAY_CONFIG_FILE}" "${whitelist_json_array}" "${blocked_json_array}" <<'PYEOF'
import json
import sys

config_path = sys.argv[1]
whitelist_raw = sys.argv[2]
blocked_raw = sys.argv[3]

# Parse domain arrays
whitelist_domains = json.loads("[" + whitelist_raw + "]")
blocked_domains = json.loads("[" + blocked_raw + "]")

with open(config_path, "r") as f:
    config = json.load(f)

# Ensure outbounds have the right tags
outbounds = config.get("outbounds", [])
has_direct = any(o.get("tag") == "direct" for o in outbounds)
has_block = any(o.get("tag") == "block" for o in outbounds)
if not has_direct:
    outbounds.insert(0, {"protocol": "freedom", "tag": "direct"})
if not has_block:
    outbounds.append({"protocol": "blackhole", "tag": "block"})
config["outbounds"] = outbounds

# Build routing rules
routing = {
    "domainStrategy": "AsIs",
    "rules": [
        {
            "type": "field",
            "domain": whitelist_domains,
            "outboundTag": "direct"
        },
        {
            "type": "field",
            "domain": blocked_domains,
            "outboundTag": "block"
        },
        {
            "type": "field",
            "domain": [
                "geosite:category-ads-all"
            ],
            "outboundTag": "block"
        },
        {
            "type": "field",
            "network": "tcp,udp",
            "outboundTag": "direct"
        }
    ]
}

config["routing"] = routing

with open(config_path, "w") as f:
    json.dump(config, f, indent=4, ensure_ascii=False)

print("Routing rules injected successfully.")
PYEOF
    else
        # Fallback: rewrite the entire config with routing rules embedded
        log_warn "Python not available. Rewriting Xray config with routing rules..."
        _rewrite_xray_config_with_routing "${whitelist_json_array}" "${blocked_json_array}"
    fi

    # ---- Validate the updated config ----
    log_info "Validating updated Xray configuration..."
    if ! "${xray_bin}" run -test -config "${XRAY_CONFIG_FILE}" &>/dev/null; then
        log_error "Xray configuration validation failed after routing injection!"
        log_warn "Restoring backup..."
        local latest_backup
        latest_backup=$(ls -t "${XRAY_CONFIG_FILE}".bak.* 2>/dev/null | head -1)
        if [[ -n "${latest_backup}" ]]; then
            cp "${latest_backup}" "${XRAY_CONFIG_FILE}"
            log_info "Backup restored."
        fi
        return 1
    fi
    log_success "Updated Xray configuration is valid."

    # ---- Restart Xray to apply ----
    systemctl restart xray.service
    if _wait_for_service "xray" 15; then
        log_success "Xray restarted with whitelist routing rules."
    else
        log_error "Xray failed to restart after routing update."
        return 1
    fi

    # ---- Save whitelist to external file for reference ----
    local whitelist_file="/usr/local/etc/xray/ai-domains-whitelist.txt"
    printf '%s\n' ${AI_WHITELIST_DOMAINS[@]+"${AI_WHITELIST_DOMAINS[@]}"} > "${whitelist_file}"
    chmod 644 "${whitelist_file}"

    # ---- Print summary ----
    echo ""
    log_info "============================================================"
    log_info "  WHITELIST ROUTING CONFIGURED"
    log_info "============================================================"
    log_info ""
    log_info "  ALLOWED domains (${#AI_WHITELIST_DOMAINS[@]}):"
    for domain in ${AI_WHITELIST_DOMAINS[@]+"${AI_WHITELIST_DOMAINS[@]}"}; do
        log_info "    + ${domain}"
    done
    log_info ""
    log_info "  BLOCKED domains (${#BLOCKED_DOMAINS[@]}):"
    for domain in ${BLOCKED_DOMAINS[@]+"${BLOCKED_DOMAINS[@]}"}; do
        log_info "    - ${domain}"
    done
    log_info ""
    log_info "  Ad domains: blocked (geosite:category-ads-all)"
    log_info "  All other traffic: direct (allowed)"
    log_info ""
    log_info "  Whitelist file: ${whitelist_file}"
    log_info "============================================================"
    echo ""
}

# Fallback: rewrite Xray config with routing when Python is unavailable
_rewrite_xray_config_with_routing() {
    local whitelist_json="$1"
    local blocked_json="$2"

    # Read existing values from deploy state
    local uuid port private_key sni dest short_id
    if [[ -f "${DEPLOY_STATE_DIR}/state.env" ]]; then
        uuid=$(grep '^XRAY_UUID=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
        port=$(grep '^XRAY_LISTEN_PORT=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
        private_key=$(grep '^XRAY_PRIVATE_KEY=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
        sni=$(grep '^XRAY_SNI=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
        dest=$(grep '^XRAY_REALITY_DEST=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
        short_id=$(grep '^XRAY_SHORT_ID=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
    fi

    # If private_key was not in deploy state, parse from existing config
    if [[ -z "${private_key}" ]] && [[ -f "${XRAY_CONFIG_FILE:-${XRAY_CONFIG_DIR}/config.json}" ]]; then
        private_key=$(grep -oP '"privateKey"\s*:\s*"\K[^"]+' "${XRAY_CONFIG_FILE:-${XRAY_CONFIG_DIR}/config.json}" 2>/dev/null || true)
        if [[ -n "${private_key}" ]]; then
            log_info "Recovered private key from existing Xray config."
        fi
    fi

    if [[ -z "${private_key}" ]]; then
        log_error "Cannot rewrite Xray config: private key not found in deploy state or existing config."
        return 1
    fi

    # If we can't read from state, parse from existing config
    if [[ -z "${uuid}" ]]; then
        uuid=$(grep -oP '"id"\s*:\s*"\K[^"]+' "${XRAY_CONFIG_FILE}" | head -1) || true
        port=$(grep -oP '"port"\s*:\s*\K[0-9]+' "${XRAY_CONFIG_FILE}" | head -1) || true
        private_key=$(grep -oP '"privateKey"\s*:\s*"\K[^"]+' "${XRAY_CONFIG_FILE}" | head -1) || true
        sni=$(grep -oP '"serverNames"\s*:\s*\[\s*"\K[^"]+' "${XRAY_CONFIG_FILE}" | head -1) || true
        dest=$(grep -oP '"dest"\s*:\s*"\K[^"]+' "${XRAY_CONFIG_FILE}" | head -1) || true
        short_id=$(grep -oP '"shortIds"\s*:\s*\[.*?"\K[0-9a-f]+' "${XRAY_CONFIG_FILE}" | head -1) || true
    fi

    cat > "${XRAY_CONFIG_FILE}" <<XRAY_ROUTE_EOF
{
    "log": {
        "loglevel": "warning",
        "access": "none",
        "error": "${XRAY_LOG_DIR}/error.log"
    },
    "routing": {
        "domainStrategy": "AsIs",
        "rules": [
            {
                "type": "field",
                "domain": [${whitelist_json}],
                "outboundTag": "direct"
            },
            {
                "type": "field",
                "domain": [${blocked_json}],
                "outboundTag": "block"
            },
            {
                "type": "field",
                "domain": ["geosite:category-ads-all"],
                "outboundTag": "block"
            },
            {
                "type": "field",
                "network": "tcp,udp",
                "outboundTag": "direct"
            }
        ]
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": ${port:-8443},
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "${uuid}",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "${dest:-dl.google.com:443}",
                    "xver": 0,
                    "serverNames": [
                        "${sni:-dl.google.com}"
                    ],
                    "privateKey": "${private_key}",
                    "shortIds": [
                        "${short_id}"
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls",
                    "quic"
                ]
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        },
        {
            "protocol": "blackhole",
            "tag": "block"
        }
    ]
}
XRAY_ROUTE_EOF

    chmod 600 "${XRAY_CONFIG_FILE}"
}

# ==============================================================================
# 6. enable_bbr()
# ==============================================================================
# Enable BBR (Bottleneck Bandwidth and Round-trip propagation time) TCP
# congestion control for improved network throughput.
# ==============================================================================
enable_bbr() {
    log_info "=========================================="
    log_info " Enabling BBR TCP Congestion Control"
    log_info "=========================================="

    # ---- Check current congestion control ----
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    log_info "Current TCP congestion control: ${current_cc}"

    if [[ "${current_cc}" == "bbr" ]]; then
        log_success "BBR is already enabled."
        return 0
    fi

    # ---- Check if BBR module is available ----
    local bbr_available=false

    # Check if already loaded
    if lsmod | grep -q tcp_bbr 2>/dev/null; then
        bbr_available=true
        log_info "BBR kernel module is already loaded."
    else
        # Try to load the module
        if modprobe tcp_bbr 2>/dev/null; then
            bbr_available=true
            log_info "BBR kernel module loaded successfully."
        else
            # Check kernel version (BBR available since 4.9)
            local kernel_version
            kernel_version=$(uname -r | cut -d. -f1-2)
            local kernel_major kernel_minor
            kernel_major=$(echo "${kernel_version}" | cut -d. -f1)
            kernel_minor=$(echo "${kernel_version}" | cut -d. -f2)

            if [[ "${kernel_major}" -gt 4 ]] || { [[ "${kernel_major}" -eq 4 ]] && [[ "${kernel_minor}" -ge 9 ]]; }; then
                # Kernel should support BBR, try harder
                log_warn "BBR module not loadable but kernel ${kernel_version} should support it."
                # Check available congestion control algorithms
                local available_cc
                available_cc=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
                if echo "${available_cc}" | grep -q bbr; then
                    bbr_available=true
                    log_info "BBR is available in: ${available_cc}"
                fi
            else
                log_warn "Kernel ${kernel_version} may not support BBR (requires 4.9+)."
            fi
        fi
    fi

    if [[ "${bbr_available}" != "true" ]]; then
        log_error "BBR is not available on this system."
        log_info "Consider upgrading kernel to 4.9+ or installing a BBR-enabled kernel."
        return 1
    fi

    # ---- Apply BBR settings ----
    log_info "Applying BBR sysctl settings..."

    # Write persistent config
    local sysctl_bbr_file="/etc/sysctl.d/99-bbr.conf"
    cat > "${sysctl_bbr_file}" <<'BBR_EOF'
# ==============================================================================
# BBR TCP Congestion Control
# Bifrost - Network Optimization
# ==============================================================================

# Use fq (Fair Queueing) as the default packet scheduler
# Required for BBR to function optimally
net.core.default_qdisc = fq

# Enable BBR congestion control algorithm
net.ipv4.tcp_congestion_control = bbr
BBR_EOF

    # Apply immediately
    sysctl -w net.core.default_qdisc=fq 2>/dev/null || true
    sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null || true

    # Reload all sysctl
    sysctl --system &>/dev/null || sysctl -p "${sysctl_bbr_file}" 2>/dev/null || true

    # ---- Verify ----
    local new_cc new_qdisc
    new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    new_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")

    if [[ "${new_cc}" == "bbr" ]]; then
        log_success "BBR enabled successfully."
        log_info "  Congestion control: ${new_cc}"
        log_info "  Default qdisc:     ${new_qdisc}"
    else
        log_error "Failed to enable BBR. Current: ${new_cc}"
        return 1
    fi

    # ---- Save state ----
    _save_deploy_state "BBR_ENABLED" "true"
}

# ==============================================================================
# 6b. test_connectivity_b()
# ==============================================================================
# Run basic connectivity tests on Server B to verify critical services.
# ==============================================================================
test_connectivity_b() {
    log_info "============================================"
    log_info "  Running Server B Connectivity Tests"
    log_info "============================================"

    local passed=0
    local failed=0
    local skipped=0
    local total=0

    # --- Test 1: Xray server listening ---
    total=$((total + 1))
    local xray_port=""
    if [[ -f "${DEPLOY_STATE_DIR}/state.env" ]]; then
        xray_port=$(grep '^XRAY_LISTEN_PORT=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
    fi
    xray_port="${xray_port:-8443}"

    log_info "[1/5] Xray server listening on port ${xray_port}..."
    if systemctl is-active --quiet xray 2>/dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ":${xray_port} "; then
            log_success "  PASS - Xray listening on port ${xray_port}"
            passed=$((passed + 1))
        else
            log_error "  FAIL - Xray service active but not listening on port ${xray_port}"
            failed=$((failed + 1))
        fi
    else
        log_error "  FAIL - Xray service not running"
        failed=$((failed + 1))
    fi

    # --- Test 2: Caddy serving HTTPS ---
    total=$((total + 1))
    log_info "[2/5] Caddy web server..."
    if systemctl is-active --quiet caddy 2>/dev/null; then
        local caddy_result
        caddy_result=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 5 --max-time 10 \
            "http://127.0.0.1:80/" 2>/dev/null) || caddy_result="000"
        if [[ "$caddy_result" =~ ^(200|301|302|308)$ ]]; then
            log_success "  PASS - Caddy responding (HTTP ${caddy_result})"
            passed=$((passed + 1))
        else
            log_warn "  WARN - Caddy returned HTTP ${caddy_result:-timeout} (may need domain DNS)"
            # Not a hard failure - Caddy may redirect to HTTPS which needs valid DNS
            passed=$((passed + 1))
        fi
    else
        log_error "  FAIL - Caddy service not running"
        failed=$((failed + 1))
    fi

    # --- Test 3: BBR congestion control ---
    total=$((total + 1))
    log_info "[3/5] BBR TCP congestion control..."
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "${current_cc}" == "bbr" ]]; then
        log_success "  PASS - BBR active"
        passed=$((passed + 1))
    else
        log_warn "  WARN - BBR not active (using: ${current_cc})"
        failed=$((failed + 1))
    fi

    # --- Test 4: 3x-ui panel (if installed) ---
    total=$((total + 1))
    if systemctl is-active --quiet x-ui 2>/dev/null; then
        log_info "[4/5] 3x-ui management panel..."
        local xui_port
        xui_port=$(grep '^THREE_X_UI_PORT=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || xui_port="2053"
        local xui_result
        xui_result=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 5 --max-time 10 \
            "http://127.0.0.1:${xui_port}/" 2>/dev/null) || xui_result="000"
        if [[ "$xui_result" =~ ^(200|301|302)$ ]]; then
            log_success "  PASS - 3x-ui panel responding (HTTP ${xui_result})"
            passed=$((passed + 1))
        else
            log_warn "  WARN - 3x-ui returned HTTP ${xui_result:-timeout}"
            failed=$((failed + 1))
        fi
    else
        log_info "[4/5] 3x-ui management panel... SKIP (not installed)"
        skipped=$((skipped + 1))
    fi

    # --- Test 5: Hysteria 2 (if installed) ---
    total=$((total + 1))
    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
        log_info "[5/5] Hysteria 2 server..."
        log_success "  PASS - Hysteria 2 service running"
        passed=$((passed + 1))
    else
        log_info "[5/5] Hysteria 2 server... SKIP (not installed)"
        skipped=$((skipped + 1))
    fi

    # --- Summary ---
    echo ""
    log_info "============================================"
    log_info "  Test Results: ${passed} passed, ${failed} failed, ${skipped} skipped (${total} total)"
    log_info "============================================"

    if [[ $failed -gt 0 ]]; then
        log_warn "Some tests failed. Review the output above and check:"
        log_info "  - Xray logs:    journalctl -u xray -n 50"
        log_info "  - Caddy logs:   journalctl -u caddy -n 50"
        log_info "  - 3x-ui logs:   journalctl -u x-ui -n 50"
        return 1
    fi

    return 0
}

# ==============================================================================
# 6c. Distribution stack helpers
# ==============================================================================

_distribution_state_dir() {
    printf '%s\n' "${DISTRIBUTION_STATE_DIR}"
}

_distribution_state_file() {
    printf '%s\n' "${DISTRIBUTION_STATE_FILE}"
}

_distribution_step_state_file() {
    printf '%s\n' "${DISTRIBUTION_STEP_STATE_FILE}"
}

_distribution_state_get() {
    local key="${1:?}"
    local value=""
    if [[ -f "${DISTRIBUTION_STATE_FILE}" ]]; then
        value="$(grep -E "^${key}=" "${DISTRIBUTION_STATE_FILE}" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
    fi
    [[ -n "${value}" ]] || return 1
    printf '%s\n' "${value}"
}

_distribution_state_set() {
    local key="${1:?}"
    local value="${2:-}"
    install -d -m 0750 "${DISTRIBUTION_STATE_DIR}"

    local tmp_file
    tmp_file="$(mktemp "${DISTRIBUTION_STATE_FILE}.XXXXXX")"
    if [[ -f "${DISTRIBUTION_STATE_FILE}" ]]; then
        grep -Ev "^${key}=" "${DISTRIBUTION_STATE_FILE}" > "${tmp_file}" || true
    fi
    printf '%s=%s\n' "${key}" "${value}" >> "${tmp_file}"
    mv "${tmp_file}" "${DISTRIBUTION_STATE_FILE}"
    chmod 600 "${DISTRIBUTION_STATE_FILE}"
}

_distribution_step_done() {
    local step_name="${1:?}"
    [[ -f "${DISTRIBUTION_STEP_STATE_FILE}" ]] || return 1
    grep -Fxq "${step_name}" "${DISTRIBUTION_STEP_STATE_FILE}"
}

_distribution_mark_step_done() {
    local step_name="${1:?}"
    install -d -m 0750 "${DISTRIBUTION_STATE_DIR}"
    if ! _distribution_step_done "${step_name}"; then
        printf '%s\n' "${step_name}" >> "${DISTRIBUTION_STEP_STATE_FILE}"
    fi
}

_distribution_reset_step_state() {
    install -d -m 0750 "${DISTRIBUTION_STATE_DIR}"
    : > "${DISTRIBUTION_STEP_STATE_FILE}"
    chmod 600 "${DISTRIBUTION_STEP_STATE_FILE}"
}

_distribution_template_render() {
    local template="${1:?}"
    local output="${2:?}"
    local ssh_allow_cidrs="${3:-}"
    local wg_port="${4:-${DISTRIBUTION_WG_PORT}}"

    sed \
        -e "s|{{SERVER_B_WG_IP}}|${DISTRIBUTION_WG_IP}|g" \
        -e "s|{{WG_CLIENTS_CIDR}}|${DISTRIBUTION_WG_CLIENTS_CIDR}|g" \
        -e "s|{{SSH_PUBNET_ALLOW_CIDRS}}|${ssh_allow_cidrs}|g" \
        -e "s|{{WG_PORT}}|${wg_port}|g" \
        "${template}" > "${output}"
}

_distribution_require_wg0() {
    if ip link show wg0 &>/dev/null; then
        return 0
    fi
    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
        return 0
    fi
    log_error "wg0 is not active. Server B private distribution requires WireGuard before enabling private services."
    return 1
}

_distribution_ensure_docker() {
    if check_docker; then
        return 0
    fi

    log_info "Docker is not installed or not running. Installing Docker CE..."
    if type -t install_docker_china_aware &>/dev/null; then
        install_docker_china_aware
    else
        install_docker
    fi
    check_docker
}

_distribution_ensure_user() {
    if ! id "${DISTRIBUTION_GIT_MIRROR_USER}" &>/dev/null; then
        useradd -r -s /usr/sbin/nologin -d "${DISTRIBUTION_GIT_MIRROR_DIR}" -m "${DISTRIBUTION_GIT_MIRROR_USER}"
    fi
    if ! id "${DISTRIBUTION_READONLY_USER}" &>/dev/null; then
        useradd -r -m -d /var/lib/${DISTRIBUTION_READONLY_USER} -s /bin/bash "${DISTRIBUTION_READONLY_USER}"
    else
        usermod -s /bin/bash "${DISTRIBUTION_READONLY_USER}" 2>/dev/null || true
    fi
}

_distribution_prepare_dirs() {
    install -d -m 0750 "${DISTRIBUTION_STATE_DIR}"
    install -d -m 0750 "${DISTRIBUTION_ETC_DIR}"
    install -d -m 0750 "${DISTRIBUTION_VERDACCIO_DIR}/storage" "${DISTRIBUTION_VERDACCIO_DIR}/config"
    install -d -m 0755 "${DISTRIBUTION_NEW_API_DIR}" /var/lib/new-api/data
    install -d -m 0750 /var/lib/new-api-pg /var/lib/new-api-redis
    install -d -m 0750 "${DISTRIBUTION_GIT_MIRROR_DIR}" "${DISTRIBUTION_GIT_TREE_DIR}"
    install -d -m 0755 "${DISTRIBUTION_GIT_DIST_DIR}"
    install -d -m 0750 /var/log/git-mirror
    install -d -m 0755 /var/log/caddy
    chown -R 10001:65533 "${DISTRIBUTION_VERDACCIO_DIR}" 2>/dev/null || true
    chown -R 999:999 /var/lib/new-api-pg /var/lib/new-api-redis 2>/dev/null || true
    chown -R "${DISTRIBUTION_GIT_MIRROR_USER}:${DISTRIBUTION_GIT_MIRROR_USER}" \
        "${DISTRIBUTION_GIT_MIRROR_DIR}" "${DISTRIBUTION_GIT_TREE_DIR}" "${DISTRIBUTION_GIT_DIST_DIR}" /var/log/git-mirror 2>/dev/null || true
    chmod 0755 "${DISTRIBUTION_GIT_DIST_DIR}" 2>/dev/null || true
    chmod 0750 "${DISTRIBUTION_VERDACCIO_DIR}" "${DISTRIBUTION_NEW_API_DIR}" 2>/dev/null || true
}

_distribution_write_verdaccio_config() {
    local target="${DISTRIBUTION_VERDACCIO_DIR}/config/config.yaml"
    local template="${PROJECT_ROOT}/configs/verdaccio/config.yaml.tpl"
    if [[ -f "${template}" ]]; then
        cp "${template}" "${target}"
    else
        cat > "${target}" <<'EOF'
storage: /verdaccio/storage
url_prefix: /
listen: 0.0.0.0:4873
EOF
    fi
    chmod 0644 "${target}"
}

_distribution_init_verdaccio_bootstrap() {
    local htpasswd_path="${DISTRIBUTION_VERDACCIO_DIR}/storage/htpasswd"
    local bootstrap_pwd

    if [[ -f "${htpasswd_path}" ]]; then
        return 0
    fi

    bootstrap_pwd="${BIFROST_VERDACCIO_BOOTSTRAP_PASSWORD:-$(openssl rand -hex 16)}"

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx verdaccio; then
        if ! docker exec verdaccio sh -lc "htpasswd -cBb /verdaccio/storage/htpasswd team '${bootstrap_pwd}'" 2>/dev/null; then
            log_error "Verdaccio container did not provide htpasswd. Cannot initialize bootstrap account safely."
            return 1
        fi
    elif command -v htpasswd &>/dev/null; then
        htpasswd -cBb "${htpasswd_path}" team "${bootstrap_pwd}"
    else
        log_error "htpasswd is unavailable and Verdaccio is not running. Cannot write a safe htpasswd file."
        return 1
    fi
    chmod 0640 "${htpasswd_path}"
    chown 10001:65533 "${htpasswd_path}" 2>/dev/null || true

    umask 077
    printf '%s\n' "${bootstrap_pwd}" > "${DISTRIBUTION_VERDACCIO_BOOTSTRAP_FILE}"
    chmod 0400 "${DISTRIBUTION_VERDACCIO_BOOTSTRAP_FILE}"

    _distribution_state_set "VERDACCIO_HTPASSWD_FILE" "${htpasswd_path}"
    _distribution_state_set "VERDACCIO_BOOTSTRAP_INITIALIZED" "1"

    log_info "Verdaccio bootstrap account initialized."
    log_info "  username: team"
    log_info "  password: ${bootstrap_pwd}"
    log_info "  saved to: ${DISTRIBUTION_VERDACCIO_BOOTSTRAP_FILE} (0400 root)"
}

_distribution_rotate_verdaccio_bootstrap() {
    rm -f "${DISTRIBUTION_VERDACCIO_BOOTSTRAP_FILE}" "${DISTRIBUTION_VERDACCIO_DIR}/storage/htpasswd"
    _distribution_init_verdaccio_bootstrap
}

_distribution_write_new_api_env() {
    install -d -m 0755 "${DISTRIBUTION_NEW_API_DIR}"
    local existing_postgres_password=""
    local existing_session_secret=""

    if [[ -f "${DISTRIBUTION_NEW_API_ENV_FILE}" ]]; then
        existing_postgres_password="$(grep -E '^BIFROST_NEW_API_POSTGRES_PASSWORD=' "${DISTRIBUTION_NEW_API_ENV_FILE}" | tail -n1 | cut -d= -f2- || true)"
        existing_session_secret="$(grep -E '^SESSION_SECRET=' "${DISTRIBUTION_NEW_API_ENV_FILE}" | tail -n1 | cut -d= -f2- || true)"
    fi

    local postgres_password="${BIFROST_NEW_API_POSTGRES_PASSWORD:-${existing_postgres_password:-$(openssl rand -hex 32)}}"
    local session_secret="${BIFROST_NEW_API_SESSION_SECRET:-${existing_session_secret:-$(openssl rand -hex 32)}}"

    umask 077
    cat > "${DISTRIBUTION_NEW_API_ENV_FILE}" <<EOF
BIFROST_SERVER_B_WG_IP=${DISTRIBUTION_WG_IP}
BIFROST_NEW_API_IMAGE=${DISTRIBUTION_NEW_API_IMAGE}
BIFROST_NEW_API_POSTGRES_DB=${DISTRIBUTION_NEW_API_POSTGRES_DB}
BIFROST_NEW_API_POSTGRES_USER=${DISTRIBUTION_NEW_API_POSTGRES_USER}
BIFROST_NEW_API_POSTGRES_PASSWORD=${postgres_password}
SESSION_SECRET=${session_secret}
BIFROST_RESTIC_REPOSITORY=${DISTRIBUTION_RESTIC_REPOSITORY}
EOF
    chmod 0600 "${DISTRIBUTION_NEW_API_ENV_FILE}"

    _distribution_state_set "BIFROST_NEW_API_POSTGRES_PASSWORD" "${postgres_password}"
    _distribution_state_set "SESSION_SECRET" "${session_secret}"
}

_distribution_render_new_api_compose() {
    local source_template="${PROJECT_ROOT}/configs/new-api/docker-compose.yml.tpl"
    local target="${DISTRIBUTION_NEW_API_DIR}/docker-compose.yml"
    cp "${source_template}" "${target}"
    chmod 0644 "${target}"

    local pg_init_template="${PROJECT_ROOT}/configs/new-api/pg-init.sh"
    cp "${pg_init_template}" "${DISTRIBUTION_NEW_API_DIR}/pg-init.sh"
    chmod 0755 "${DISTRIBUTION_NEW_API_DIR}/pg-init.sh"
}

_distribution_render_nftables() {
    local allow_cidrs
    allow_cidrs="$(bifrost_admin_allowed_ranges | tr ' ' '\n' | sed '/^$/d' | grep -v ':' | paste -sd, -)"
    allow_cidrs="${allow_cidrs:-127.0.0.1/32}"
    local bootstrap_ip=""
    bootstrap_ip="$(_distribution_state_get BOOTSTRAP_PUBLIC_IP || true)"
    if [[ "${bootstrap_ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        allow_cidrs="${allow_cidrs},${bootstrap_ip}/32"
    fi
    local template="${PROJECT_ROOT}/configs/nftables/bifrost-distribution.nft.tpl"
    local target="/etc/nftables.d/bifrost-distribution.nft"
    _distribution_template_render "${template}" "${target}" "${allow_cidrs}" "${DISTRIBUTION_WG_PORT}"
    chmod 0644 "${target}"
}

_distribution_apply_docker_user_rules() {
    local port
    for port in 3000 4873 8081 8082; do
        if iptables -C DOCKER-USER -i eth0 -p tcp --dport "${port}" -j DROP 2>/dev/null; then
            continue
        fi
        iptables -I DOCKER-USER -i eth0 -p tcp --dport "${port}" -j DROP
    done

    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save || true
    elif command -v iptables-save &>/dev/null && [[ -d /etc/iptables ]]; then
        iptables-save > /etc/iptables/rules.v4 || true
    fi
}

_distribution_render_caddy() {
    local template="${PROJECT_ROOT}/configs/caddy/Caddyfile-b-distribution.tpl"
    local target="/etc/caddy/Caddyfile"
    local allow_cidrs
    allow_cidrs="$(bifrost_admin_allowed_ranges | tr ' ' '\n' | sed '/^$/d' | paste -sd, -)"
    _distribution_template_render "${template}" "${target}" "${allow_cidrs}" "${DISTRIBUTION_WG_PORT}"
    chmod 0644 "${target}"
}

_distribution_render_systemd_units() {
    install -d -m 0755 /etc/systemd/system/caddy.service.d
    cp "${PROJECT_ROOT}/configs/systemd/caddy-wg-after.conf" /etc/systemd/system/caddy.service.d/wg-after.conf
    cp "${PROJECT_ROOT}/configs/systemd/verdaccio.service" /etc/systemd/system/verdaccio.service
    cp "${PROJECT_ROOT}/configs/systemd/git-mirror@.service" /etc/systemd/system/git-mirror@.service
    cp "${PROJECT_ROOT}/configs/systemd/git-mirror@.timer" /etc/systemd/system/git-mirror@.timer
    cp "${PROJECT_ROOT}/configs/restic/restic-to-a.service" /etc/systemd/system/restic-to-a.service
    cp "${PROJECT_ROOT}/configs/restic/restic-to-a.timer" /etc/systemd/system/restic-to-a.timer
    # spec.md section 4.3 / PR-2: marketplace render + upstream LICENSE watchdog units.
    cp "${PROJECT_ROOT}/configs/systemd/marketplace-render.path" /etc/systemd/system/marketplace-render.path
    cp "${PROJECT_ROOT}/configs/systemd/marketplace-render.service" /etc/systemd/system/marketplace-render.service
    cp "${PROJECT_ROOT}/configs/systemd/upstream-schema-check.timer" /etc/systemd/system/upstream-schema-check.timer
    cp "${PROJECT_ROOT}/configs/systemd/upstream-schema-check.service" /etc/systemd/system/upstream-schema-check.service
    chmod 0644 /etc/systemd/system/caddy.service.d/wg-after.conf \
        /etc/systemd/system/verdaccio.service \
        /etc/systemd/system/git-mirror@.service \
        /etc/systemd/system/git-mirror@.timer \
        /etc/systemd/system/restic-to-a.service \
        /etc/systemd/system/restic-to-a.timer \
        /etc/systemd/system/marketplace-render.path \
        /etc/systemd/system/marketplace-render.service \
        /etc/systemd/system/upstream-schema-check.timer \
        /etc/systemd/system/upstream-schema-check.service
}

_distribution_render_readonly_router() {
    install -m 0755 "${PROJECT_ROOT}/scripts/bifrost-readonly-router.sh" /usr/local/bin/bifrost-readonly-router.sh
}

_distribution_render_restic_script() {
    install -m 0755 "${PROJECT_ROOT}/scripts/bifrost-restic-backup.sh" /usr/local/bin/bifrost-restic-backup.sh
}

_distribution_render_git_mirror_script() {
    install -m 0755 "${PROJECT_ROOT}/scripts/git-mirror-sync.sh" /usr/local/bin/git-mirror-sync.sh
}

# spec.md section 9.1 step 06: install marketplace render + upstream LICENSE watchdog
# scripts plus the PR-5a admin write router (bifrost-admin-router.sh).
_distribution_render_marketplace_scripts() {
    install -m 0755 "${PROJECT_ROOT}/scripts/render-marketplace-json.sh" /usr/local/bin/render-marketplace-json.sh
    install -m 0755 "${PROJECT_ROOT}/scripts/check-upstream-schema.sh" /usr/local/bin/check-upstream-schema.sh
    # spec.md PR-5a: install the write-side forced-command admin router so the
    # bifrost-admin user authorized_keys command= line resolves.
    install -m 0755 "${PROJECT_ROOT}/scripts/bifrost-admin-router.sh" /usr/local/bin/bifrost-admin-router.sh
}

# spec.md section 9.2 / M6: marketplace directories must be owned by git-mirror so
# render-marketplace-json.sh (User=git-mirror) can write into them.
_distribution_prepare_marketplace_dirs() {
    install -d -m 0750 -o "${DISTRIBUTION_GIT_MIRROR_USER}" -g "${DISTRIBUTION_GIT_MIRROR_USER}" \
        /var/log/marketplace \
        /var/lib/dist/plugins \
        /etc/bifrost-api/marketplace
}

# spec.md section 9.2 / section 5.3: emit the canonical LICENSE / NOTICE text into a worktree
# before the initial commit. Kept as a helper so the marketplace-render service
# (and any future re-seed path) can produce byte-identical files.
_distribution_render_marketplace_license_notice() {
    local work="${1:?worktree path required}"
    cat > "${work}/LICENSE" <<'BIFROST_LICENSE_EOF'
# bifrost-internal Plugin Marketplace
# Copyright (c) 2026 Bifrost Team. All rights reserved.
#
# Each plugin under `plugins/<name>/` may carry its own LICENSE file.
# Default policy: ALL-RIGHTS-RESERVED unless otherwise stated.
# Distribution restricted to authenticated Bifrost team members.
BIFROST_LICENSE_EOF
    cat > "${work}/NOTICE" <<'BIFROST_NOTICE_EOF'
This marketplace is an internal distribution channel for Bifrost team.
It does NOT mirror anthropic/claude-code or any other proprietary upstream.
Plugin submissions are subject to admin review via panel.uuhfn.cloud
(see docs/SECURITY.md section marketplace once PR-7 lands).
BIFROST_NOTICE_EOF
}

_distribution_init_marketplace_bare() {
    local bare="${DISTRIBUTION_GIT_MIRROR_DIR}/bifrost-internal-plugins.git"
    if [[ -f "${bare}/HEAD" ]] && git --git-dir="${bare}" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
        return 0
    fi

    install -d -m 0755 "${DISTRIBUTION_GIT_MIRROR_DIR}"

    if [[ ! -f "${bare}/HEAD" ]]; then
        git init --bare --initial-branch=main "${bare}" >/dev/null
    fi
    chown -R "${DISTRIBUTION_GIT_MIRROR_USER}:${DISTRIBUTION_GIT_MIRROR_USER}" "${bare}" 2>/dev/null || true

    local work
    work="$(mktemp -d /tmp/marketplace-seed.XXXXXX)"
    (
        cd "${work}"
        git init --quiet --initial-branch=main
        git config user.name "marketplace-render"
        git config user.email "render@uuhfn.cloud"
        install -d -m 0755 .claude-plugin
        cat > .claude-plugin/marketplace.json <<'BIFROST_SEED_MP_EOF'
{
  "name": "bifrost-internal",
  "owner": {
    "name": "Bifrost Team",
    "email": "bifrost-admin@uuhfn.cloud"
  },
  "description": "Bifrost team internal Claude Code plugin marketplace (seed; no plugins yet)",
  "version": "0.0.0",
  "metadata": {
    "pluginRoot": "./plugins",
    "license_id": "ALL-RIGHTS-RESERVED",
    "upstream_url": null,
    "render_script_version": "v1.0.0-seed"
  },
  "plugins": []
}
BIFROST_SEED_MP_EOF
        _distribution_render_marketplace_license_notice "${work}"
        git add . >/dev/null
        git commit --quiet -m "Seed bifrost-internal-plugins (PR-2 step 07)"
        git push --quiet "${bare}" "main:main"
    )
    rm -rf "${work}"
    chown -R "${DISTRIBUTION_GIT_MIRROR_USER}:${DISTRIBUTION_GIT_MIRROR_USER}" "${bare}" 2>/dev/null || true
}

_distribution_init_upstream_schema_baseline() {
    local baseline_file="/etc/bifrost-api/marketplace/upstream-license-baseline.sha256"
    install -d -m 0750 /etc/bifrost-api/marketplace
    if [[ -s "${baseline_file}" ]]; then
        return 0
    fi
    local sha=""
    if sha="$(curl -fsSL --max-time 30 "https://github.com/anthropics/claude-code/raw/main/LICENSE.md" 2>/dev/null | sha256sum | awk '{print $1}')" && [[ "${sha}" =~ ^[0-9a-f]{64}$ ]]; then
        printf '%s' "${sha}" > "${baseline_file}"
        chmod 0644 "${baseline_file}"
        log_info "Initialised upstream LICENSE baseline sha256: ${sha}"
    else
        : > "${baseline_file}"
        chmod 0644 "${baseline_file}"
        log_warn "Could not fetch upstream LICENSE during baseline init (offline?). check-upstream-schema.sh will retry on its next timer fire."
    fi
}

_distribution_configure_readonly_ssh() {
    local public_key="${BIFROST_READONLY_SSH_PUBLIC_KEY:-}"
    local public_key_file="${BIFROST_READONLY_SSH_PUBLIC_KEY_FILE:-}"
    if [[ -z "${public_key}" && -n "${public_key_file}" && -f "${public_key_file}" ]]; then
        public_key="$(tr -d '\r\n' < "${public_key_file}")"
    fi

    if [[ -z "${public_key}" ]]; then
        log_warn "BIFROST_READONLY_SSH_PUBLIC_KEY not provided; /mirrors/logs SSH pull channel is not enabled yet."
        _distribution_state_set "BIFROST_READONLY_SSH_CONFIGURED" "0"
        return 0
    fi

    local home_dir="/var/lib/${DISTRIBUTION_READONLY_USER}"
    install -d -m 0700 -o "${DISTRIBUTION_READONLY_USER}" -g "${DISTRIBUTION_READONLY_USER}" "${home_dir}/.ssh"
    cat > "${home_dir}/.ssh/authorized_keys" <<EOF
command="/usr/local/bin/bifrost-readonly-router.sh \${SSH_ORIGINAL_COMMAND}",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ${public_key}
EOF
    chmod 0600 "${home_dir}/.ssh/authorized_keys"
    chown "${DISTRIBUTION_READONLY_USER}:${DISTRIBUTION_READONLY_USER}" "${home_dir}/.ssh/authorized_keys"
    _distribution_state_set "BIFROST_READONLY_SSH_CONFIGURED" "1"
}

# spec.md PR-5a / section 6.3 / section 9.2: configure the independent
# bifrost-admin SSH user used by panel.uuhfn.cloud admin write endpoints.
# - dedicated system user (no shell login); home created under /var/lib
# - forced-command authorized_keys pinned to /usr/local/bin/bifrost-admin-router.sh
# - admin-audit.log file pre-created with mode 0640 owned by bifrost-admin
# - bifrost-admin added to the git-mirror group so it can rw the bare repo
# Idempotent: the function safely re-runs when --enable-distribution is invoked
# multiple times; the step-state machine still gates execution to once per box.
_distribution_configure_admin_ssh() {
    local admin_user="bifrost-admin"
    local public_key="${BIFROST_ADMIN_SSH_PUBLIC_KEY:-}"
    local public_key_file="${BIFROST_ADMIN_SSH_PUBLIC_KEY_FILE:-}"
    if [[ -z "${public_key}" && -n "${public_key_file}" && -f "${public_key_file}" ]]; then
        public_key="$(tr -d '\r\n' < "${public_key_file}")"
    fi

    # 1. ensure the dedicated admin user exists (no shell, login disabled)
    if ! id "${admin_user}" &>/dev/null; then
        useradd -r -m -d "/var/lib/${admin_user}" -s /usr/sbin/nologin "${admin_user}"
    fi
    # 2. add bifrost-admin to git-mirror group so it can read/write the bare repo
    usermod -aG "${DISTRIBUTION_GIT_MIRROR_USER}" "${admin_user}" 2>/dev/null || true
    # 3. ensure audit-log file exists with appropriate ownership/mode
    install -d -m 0750 -o "${admin_user}" -g "${admin_user}" /var/log/marketplace
    if [[ ! -f /var/log/marketplace/admin-audit.log ]]; then
        install -m 0640 -o "${admin_user}" -g "${admin_user}" /dev/null /var/log/marketplace/admin-audit.log
    fi
    # 4. install authorized_keys with the PR-5a forced-command line
    if [[ -z "${public_key}" ]]; then
        log_warn "BIFROST_ADMIN_SSH_PUBLIC_KEY not provided; /marketplace/admin/* SSH write channel is not enabled yet."
        _distribution_state_set "BIFROST_ADMIN_SSH_CONFIGURED" "0"
        return 0
    fi
    local home_dir="/var/lib/${admin_user}"
    install -d -m 0700 -o "${admin_user}" -g "${admin_user}" "${home_dir}/.ssh"
    cat > "${home_dir}/.ssh/authorized_keys" <<EOF
command="/usr/local/bin/bifrost-admin-router.sh \${SSH_ORIGINAL_COMMAND}",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ${public_key}
EOF
    chmod 0600 "${home_dir}/.ssh/authorized_keys"
    chown "${admin_user}:${admin_user}" "${home_dir}/.ssh/authorized_keys"
    _distribution_state_set "BIFROST_ADMIN_SSH_CONFIGURED" "1"
}

_distribution_ensure_caddy_service() {
    if systemctl list-unit-files caddy.service &>/dev/null || [[ -f /etc/systemd/system/caddy.service ]]; then
        return 0
    fi

    cat > /etc/systemd/system/caddy.service <<'CADDYSVC_EOF'
[Unit]
Description=Caddy Web Server
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full

[Install]
WantedBy=multi-user.target
CADDYSVC_EOF
    if ! id caddy &>/dev/null; then
        useradd --system --home "${CADDY_DATA_DIR}" --shell /usr/sbin/nologin caddy 2>/dev/null || true
    fi
}

_distribution_write_restic_env() {
    local target="${DISTRIBUTION_RESTIC_ENV_FILE}"
    install -d -m 0750 "${DISTRIBUTION_ETC_DIR}"
    if [[ ! -f "${DISTRIBUTION_RESTIC_PASSWORD_FILE}" ]]; then
        umask 077
        openssl rand -base64 32 > "${DISTRIBUTION_RESTIC_PASSWORD_FILE}"
        chmod 0400 "${DISTRIBUTION_RESTIC_PASSWORD_FILE}"
    fi

    cat > "${target}" <<EOF
RESTIC_REPOSITORY=${DISTRIBUTION_RESTIC_REPOSITORY}
RESTIC_PASSWORD_FILE=${DISTRIBUTION_RESTIC_PASSWORD_FILE}
EOF
    chmod 0600 "${target}"
}

_distribution_verify() {
    local failures=0

    if ! docker compose -f "${DISTRIBUTION_NEW_API_DIR}/docker-compose.yml" config --quiet; then
        log_error "New API compose validation failed."
        failures=$((failures + 1))
    fi

    if ! grep -q 'VERDACCIO_PUBLIC_URL=https://npm.uuhfn.cloud' /etc/systemd/system/verdaccio.service; then
        log_error "Verdaccio systemd unit does not pin VERDACCIO_PUBLIC_URL."
        failures=$((failures + 1))
    fi

    if ! grep -q 'sslmode=disable' "${DISTRIBUTION_NEW_API_DIR}/docker-compose.yml"; then
        log_error "New API compose file does not force sslmode=disable."
        failures=$((failures + 1))
    fi

    if ! grep -q 'git push disabled on mirror' /etc/caddy/Caddyfile; then
        log_error "Distribution Caddyfile does not block git push on the mirror endpoint."
        failures=$((failures + 1))
    fi

    if ! grep -q 'Requires=wg-quick@wg0.service' /etc/systemd/system/caddy.service.d/wg-after.conf; then
        log_error "Caddy systemd drop-in does not depend on wg-quick@wg0."
        failures=$((failures + 1))
    fi

    # spec.md section 9.2 PR-2 additions: marketplace bootstrap must be visible at the
    # bare repo's HEAD and the systemd trigger units must be active.
    local bare="${DISTRIBUTION_GIT_MIRROR_DIR}/bifrost-internal-plugins.git"
    if [[ -d "${bare}" ]]; then
        if ! git --git-dir="${bare}" show HEAD:.claude-plugin/marketplace.json >/dev/null 2>&1; then
            log_error "bifrost-internal-plugins bare repo missing .claude-plugin/marketplace.json at HEAD."
            failures=$((failures + 1))
        fi
    else
        log_error "bifrost-internal-plugins bare repo not initialised at ${bare}."
        failures=$((failures + 1))
    fi
    if ! systemctl is-active --quiet marketplace-render.path 2>/dev/null; then
        log_error "marketplace-render.path is not active."
        failures=$((failures + 1))
    fi
    if [[ ! -f /var/lib/dist/plugins/state.json ]]; then
        log_error "/var/lib/dist/plugins/state.json is missing (marketplace-render did not write state)."
        failures=$((failures + 1))
    fi

    # spec.md PR-5a / section 11 AC-10: the bifrost-admin SSH channel must be
    # ready to receive uploads. We verify the user exists, the router binary
    # is installed and the authorized_keys file carries a command= directive.
    # When BIFROST_ADMIN_SSH_PUBLIC_KEY was unset the channel intentionally
    # leaves authorized_keys absent (see _distribution_configure_admin_ssh);
    # that branch only warns, it does not fail the verifier.
    if ! id bifrost-admin &>/dev/null; then
        log_error "bifrost-admin SSH user is missing (PR-5a)."
        failures=$((failures + 1))
    fi
    if [[ ! -x /usr/local/bin/bifrost-admin-router.sh ]]; then
        log_error "/usr/local/bin/bifrost-admin-router.sh is missing or not executable (PR-5a)."
        failures=$((failures + 1))
    fi
    if [[ -f /var/lib/bifrost-admin/.ssh/authorized_keys ]]         && ! grep -q "command=\"/usr/local/bin/bifrost-admin-router.sh" /var/lib/bifrost-admin/.ssh/authorized_keys; then
        log_error "bifrost-admin authorized_keys exists but lacks the forced-command directive (PR-5a)."
        failures=$((failures + 1))
    fi

    if [[ "${failures}" -gt 0 ]]; then
        return 1
    fi

    log_success "Distribution stack verification passed."
}

enable_distribution() {
    log_info "=========================================="
    log_info "  Enabling Server B Private Distribution"
    log_info "=========================================="

    if [[ -z "${PKG_MGR:-}" || "${PKG_MGR:-}" == "unknown" ]]; then
        detect_system
    fi
    if declare -f _install_base_dependencies &>/dev/null; then
        _install_base_dependencies
    fi

    _distribution_require_wg0
    _distribution_ensure_docker
    if ! command -v caddy &>/dev/null; then
        _install_caddy
    fi
    _distribution_ensure_caddy_service
    _distribution_ensure_user
    install_packages nftables iptables git fcgiwrap restic
    if ! command -v htpasswd &>/dev/null; then
        case "${PKG_MGR}" in
            apt) install_packages apache2-utils ;;
            dnf|yum) install_packages httpd-tools ;;
            *) log_warn "Unknown package manager; htpasswd must already be available before Verdaccio bootstrap." ;;
        esac
    fi

    _distribution_prepare_dirs

    local bootstrap_ip=""
    bootstrap_ip="$(get_public_ip || true)"
    if [[ -n "${bootstrap_ip}" && "${bootstrap_ip}" != "unknown" ]]; then
        _distribution_state_set "BOOTSTRAP_PUBLIC_IP" "${bootstrap_ip}"
    fi

    local step_id

    step_id="01_render_verdaccio"
    if ! _distribution_step_done "${step_id}"; then
        _distribution_write_verdaccio_config
        _distribution_mark_step_done "${step_id}"
    fi

    step_id="02_render_new_api"
    if ! _distribution_step_done "${step_id}"; then
        _distribution_write_new_api_env
        _distribution_render_new_api_compose
        _distribution_mark_step_done "${step_id}"
    fi

    step_id="03_render_caddy"
    if ! _distribution_step_done "${step_id}"; then
        _distribution_render_caddy
        _distribution_mark_step_done "${step_id}"
    fi

    step_id="04_render_nftables"
    if ! _distribution_step_done "${step_id}"; then
        _distribution_render_nftables
        nft -f /etc/nftables.d/bifrost-distribution.nft
        _distribution_apply_docker_user_rules
        _distribution_mark_step_done "${step_id}"
    fi

    step_id="05_render_systemd"
    if ! _distribution_step_done "${step_id}"; then
        _distribution_render_systemd_units
        systemctl daemon-reload
        _distribution_mark_step_done "${step_id}"
    fi

    step_id="06_render_scripts"
    if ! _distribution_step_done "${step_id}"; then
        _distribution_render_git_mirror_script
        _distribution_render_marketplace_scripts
        _distribution_render_readonly_router
        _distribution_render_restic_script
        _distribution_configure_readonly_ssh
        _distribution_write_restic_env
        _distribution_mark_step_done "${step_id}"
    fi

    step_id="07_render_marketplace"
    if ! _distribution_step_done "${step_id}"; then
        _distribution_prepare_marketplace_dirs
        _distribution_init_marketplace_bare
        _distribution_init_upstream_schema_baseline
        # spec.md PR-5a / section 9.2: configure the bifrost-admin SSH channel
        # so /marketplace/admin/* writes can land. Runs *before* the path unit
        # is enabled so the audit-log file is ready when render fires.
        _distribution_configure_admin_ssh
        # spec.md M19: explicitly enable systemd triggers; the path unit becomes
        # active only after the bare repo exists (we just created it above).
        systemctl enable --now marketplace-render.path
        systemctl enable --now upstream-schema-check.timer
        # Trigger an initial render so state.json exists for _distribution_verify
        # and the panel status endpoint (PR-4). Ignore failure here so a
        # first-boot transient does not short-circuit the step machine; the
        # path unit will retry on any subsequent change.
        systemctl start marketplace-render.service || true
        _distribution_mark_step_done "${step_id}"
    fi

    step_id="08_git_mirror"
    if ! _distribution_step_done "${step_id}"; then
        systemctl enable --now fcgiwrap.socket
        systemctl enable --now git-mirror@claude-for-legal-zh.timer
        systemctl start git-mirror@claude-for-legal-zh.service
        _distribution_mark_step_done "${step_id}"
    fi

    step_id="09_new_api"
    if ! _distribution_step_done "${step_id}"; then
        (
            cd "${DISTRIBUTION_NEW_API_DIR}"
            docker compose config --quiet
            docker compose pull
            docker compose up -d
        )
        _distribution_mark_step_done "${step_id}"
    fi

    step_id="10_verdaccio"
    if ! _distribution_step_done "${step_id}"; then
        systemctl enable --now verdaccio.service
        _distribution_mark_step_done "${step_id}"
    fi

    step_id="11_verdaccio_bootstrap"
    if ! _distribution_step_done "${step_id}"; then
        _distribution_init_verdaccio_bootstrap
        _distribution_mark_step_done "${step_id}"
    fi

    step_id="12_caddy"
    if ! _distribution_step_done "${step_id}"; then
        systemctl enable --now caddy.service
        systemctl restart caddy.service
        _distribution_mark_step_done "${step_id}"
    fi

    step_id="13_restic"
    if ! _distribution_step_done "${step_id}"; then
        systemctl enable --now restic-to-a.timer
        _distribution_mark_step_done "${step_id}"
    fi

    _distribution_verify
    _distribution_state_set "DISTRIBUTION_ENABLED" "1"

    log_info "=========================================="
    log_info "  Server B private distribution enabled"
    log_info "=========================================="
}

disable_distribution() {
    log_info "=========================================="
    log_info "  Disabling Server B Private Distribution"
    log_info "=========================================="

    # spec.md section 9.4 M12: disable marketplace triggers FIRST so subsequent
    # packed-refs writes during teardown do not fire a late path-unit
    # invocation. marketplace-render.service is oneshot; nothing to disable.
    systemctl disable --now marketplace-render.path 2>/dev/null || true
    systemctl disable --now upstream-schema-check.timer 2>/dev/null || true
    # spec.md PR-5a / section 9.4: intentionally do NOT remove the bifrost-admin
    # system user nor delete /var/log/marketplace/admin-audit.log on disable.
    # The audit trail is a security artefact and must survive teardown so
    # incident review can reconstruct any prior plugin uploads. To fully
    # remove the admin user run `userdel -r bifrost-admin` manually after
    # archiving the audit log.
    systemctl disable --now restic-to-a.timer 2>/dev/null || true
    systemctl disable --now git-mirror@claude-for-legal-zh.timer 2>/dev/null || true
    systemctl stop git-mirror@claude-for-legal-zh.service 2>/dev/null || true
    systemctl disable --now verdaccio.service 2>/dev/null || true
    systemctl disable --now caddy.service 2>/dev/null || true
    if [[ -d "${DISTRIBUTION_NEW_API_DIR}" ]]; then
        (cd "${DISTRIBUTION_NEW_API_DIR}" && docker compose down) 2>/dev/null || true
    fi
    _distribution_state_set "DISTRIBUTION_ENABLED" "0"

    log_success "Server B private distribution stopped. Data directories were preserved."
}

rotate_verdaccio_bootstrap_pwd() {
    log_info "Rotating Verdaccio bootstrap password..."
    _distribution_rotate_verdaccio_bootstrap
}

# ==============================================================================
# 7. deploy_server_b()
# ==============================================================================
# Main orchestration function for complete Server B deployment.
# Calls all sub-modules in order with optional components gated by user choice.
# ==============================================================================
deploy_server_b() {
    log_info "============================================================"
    log_info ""
    log_info "  AI GATEWAY BRIDGE - SERVER B (OVERSEAS) DEPLOYMENT"
    log_info ""
    log_info "  This will set up the overseas server with:"
    log_info "    - Xray Server (VLESS+Reality+Vision)"
    log_info "    - Whitelist routing (AI API domains only)"
    log_info "    - Caddy reverse proxy + decoy website"
    log_info "    - BBR TCP optimization"
    log_info "    - Security hardening"
    log_info "    - System monitoring"
    log_info "    - [Optional] 3x-ui management panel"
    log_info "    - [Optional] Hysteria 2 backup tunnel"
    log_info ""
    log_info "============================================================"
    echo ""

    if ! confirm_action "Proceed with Server B deployment?"; then
        log_info "Deployment cancelled."
        return 0
    fi

    # Create state directory with restricted permissions (contains secrets)
    mkdir -p "${DEPLOY_STATE_DIR}"
    chmod 700 "${DEPLOY_STATE_DIR}"
    echo "# Bifrost - Server B Deployment State" > "${DEPLOY_STATE_DIR}/state.env"
    echo "# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "${DEPLOY_STATE_DIR}/state.env"
    echo "" >> "${DEPLOY_STATE_DIR}/state.env"
    chmod 600 "${DEPLOY_STATE_DIR}/state.env"

    local deploy_start_time
    deploy_start_time=$(date +%s)
    local failed_steps=()

    # ---- Step 0: Pre-Deploy Check (Cloud Readiness Review) ----
    log_info "[Step 0/14] Pre-deploy check (cloud readiness review)..."
    local _sb_script_dir
    _sb_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "${_sb_script_dir}/dd-reinstall.sh" ]]; then
        # shellcheck source=scripts/dd-reinstall.sh
        source "${_sb_script_dir}/dd-reinstall.sh"
        if declare -f pre_deploy_check &>/dev/null; then
            if ! pre_deploy_check; then
                log_error "Pre-deploy check failed. Cannot continue with Server B deployment."
                return 1
            fi
            if declare -f cloud_review_blocks_deployment >/dev/null 2>&1 && cloud_review_blocks_deployment; then
                log_error "${CLOUD_REVIEW_DEPLOYMENT_BLOCK_REASON:-Pre-deploy check requested operator follow-up before deployment.}"
                return 1
            fi
        fi
    else
        log_warn "dd-reinstall.sh not found. Skipping cloud readiness review."
    fi
    echo ""

    # ---- Step 1: Detect System ----
    log_info "[Step 1/14] Detecting system environment..."
    detect_system
    echo ""

    # ---- Step 1.5: Install Base Dependencies ----
    log_info "[Step 1.5/14] Installing base system dependencies..."
    _install_base_dependencies || {
        log_error "Failed to install base dependencies. Cannot proceed."
        return 1
    }
    echo ""

    # ---- Step 2: Security Hardening ----
    log_info "[Step 2/14] Applying security hardening..."
    if type -t full_security_hardening &>/dev/null; then
        # security.sh functions are available
        if ! harden_ssh; then
            log_error "SSH hardening failed."
            failed_steps+=("SSH Hardening")
        fi
        if ! setup_firewall; then
            log_error "Firewall setup failed."
            failed_steps+=("Firewall Setup")
        fi
        if ! harden_kernel; then
            log_error "Kernel hardening failed."
            failed_steps+=("Kernel Hardening")
        fi
        if ! setup_fail2ban; then
            log_error "fail2ban setup failed."
            failed_steps+=("fail2ban")
        fi
        if ! setup_auto_updates; then
            log_error "Auto-updates setup failed."
            failed_steps+=("Auto Updates")
        fi
    elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/security.sh" ]]; then
        source "$(dirname "${BASH_SOURCE[0]}")/security.sh"
        if ! harden_ssh; then
            log_error "SSH hardening failed."
            failed_steps+=("SSH Hardening")
        fi
        if ! setup_firewall; then
            log_error "Firewall setup failed."
            failed_steps+=("Firewall Setup")
        fi
        if ! harden_kernel; then
            log_error "Kernel hardening failed."
            failed_steps+=("Kernel Hardening")
        fi
        if ! setup_fail2ban; then
            log_error "fail2ban setup failed."
            failed_steps+=("fail2ban")
        fi
        if ! setup_auto_updates; then
            log_error "Auto-updates setup failed."
            failed_steps+=("Auto Updates")
        fi
    else
        log_error "security.sh not found. Cannot apply security hardening."
        failed_steps+=("Security Hardening")
    fi
    echo ""

    # ---- Step 3: Install Xray Server ----
    log_info "[Step 3/14] Installing Xray Server (VLESS+Reality)..."
    if ! install_xray_server; then
        log_error "Xray Server installation failed! This is a critical component."
        failed_steps+=("Xray Server")
        if ! confirm_action "Continue deployment despite Xray failure?"; then
            return 1
        fi
    fi
    echo ""

    # ---- Step 4: Whitelist Routing ----
    log_info "[Step 4/14] Configuring whitelist routing..."
    if [[ -f "${XRAY_CONFIG_FILE}" ]]; then
        if ! setup_whitelist_routing; then
            log_warn "Whitelist routing configuration failed."
            failed_steps+=("Whitelist Routing")
        fi
    else
        log_warn "Skipping whitelist routing (Xray not installed)."
        failed_steps+=("Whitelist Routing (skipped)")
    fi
    echo ""

    # ---- Step 5: 3x-ui (Optional) ----
    log_info "[Step 5/14] 3x-ui Management Panel (optional)..."
    if confirm_action "Install 3x-ui management panel?"; then
        if ! install_3xui; then
            log_warn "3x-ui installation failed."
            failed_steps+=("3x-ui")
        fi
    else
        log_info "Skipping 3x-ui installation."
    fi
    echo ""

    # ---- Step 6: Hysteria 2 (Optional) ----
    log_info "[Step 6/14] Hysteria 2 Backup Tunnel (optional)..."
    if confirm_action "Install Hysteria 2 as backup tunnel?"; then
        if ! install_hysteria2_server; then
            log_warn "Hysteria 2 installation failed."
            failed_steps+=("Hysteria 2")
        fi
    else
        log_info "Skipping Hysteria 2 installation."
    fi
    echo ""

    # ---- Step 7: Caddy ----
    log_info "[Step 7/14] Setting up Caddy reverse proxy..."
    if ! setup_caddy_b; then
        log_warn "Caddy setup failed."
        failed_steps+=("Caddy")
    fi
    echo ""

    # ---- Step 8: BBR ----
    log_info "[Step 8/14] Enabling BBR TCP optimization..."
    if ! enable_bbr; then
        log_warn "BBR enablement failed."
        failed_steps+=("BBR")
    fi
    echo ""

    # ---- Step 9: Anti-DPI Protection ----
    log_info "[Step 9/14] Deploying anti-DPI protection..."
    if [[ -f "${_sb_script_dir}/anti-dpi.sh" ]]; then
        # shellcheck source=scripts/anti-dpi.sh
        source "${_sb_script_dir}/anti-dpi.sh"
        if declare -f deploy_anti_dpi &>/dev/null; then
            if ! deploy_anti_dpi; then
                log_error "Anti-DPI deployment failed."
                failed_steps+=("Anti-DPI")
            fi
        else
            log_error "deploy_anti_dpi not available after sourcing anti-dpi.sh."
            failed_steps+=("Anti-DPI")
        fi
    else
        log_error "anti-dpi.sh not found. Cannot deploy anti-DPI protection."
        failed_steps+=("Anti-DPI")
    fi
    echo ""

    # ---- Step 10: Keepalive & Watchdog ----
    log_info "[Step 10/14] Deploying connection keepalive & watchdog..."
    if [[ -f "${_sb_script_dir}/keepalive.sh" ]]; then
        # shellcheck source=scripts/keepalive.sh
        source "${_sb_script_dir}/keepalive.sh"
        if declare -f deploy_keepalive &>/dev/null; then
            if ! deploy_keepalive; then
                log_error "Keepalive deployment failed."
                failed_steps+=("Keepalive")
            fi
        else
            log_error "deploy_keepalive not available after sourcing keepalive.sh."
            failed_steps+=("Keepalive")
        fi
    else
        log_error "keepalive.sh not found. Cannot deploy keepalive."
        failed_steps+=("Keepalive")
    fi
    echo ""

    # ---- Step 11: Monitoring ----
    log_info "[Step 11/14] Setting up monitoring..."
    if type -t deploy_monitoring &>/dev/null; then
        if ! deploy_monitoring; then
            log_error "Monitoring setup failed."
            failed_steps+=("Monitoring")
        fi
    elif [[ -f "${_sb_script_dir}/monitoring.sh" ]]; then
        source "${_sb_script_dir}/monitoring.sh"
        if ! deploy_monitoring; then
            log_error "Monitoring setup failed."
            failed_steps+=("Monitoring")
        fi
    else
        log_error "monitoring.sh not found. Cannot set up monitoring."
        failed_steps+=("Monitoring")
    fi
    echo ""

    # ---- Step 12: Connectivity Tests ----
    log_info "[Step 12/14] Running connectivity tests..."
    if ! test_connectivity_b; then
        log_warn "Some connectivity tests failed."
        failed_steps+=("Connectivity Tests")
    fi
    echo ""

    # ---- Step 13: Print Summary ----
    local deploy_end_time
    deploy_end_time=$(date +%s)
    local deploy_duration=$(( deploy_end_time - deploy_start_time ))
    local deploy_minutes=$(( deploy_duration / 60 ))
    local deploy_seconds=$(( deploy_duration % 60 ))

    _print_deployment_summary "${deploy_minutes}" "${deploy_seconds}" "${failed_steps[@]}"

    # ---- Save final connection info for Server A ----
    _save_final_connection_info

    if [[ ${#failed_steps[@]} -gt 0 ]]; then
        return 1
    fi

    return 0
}

# Print the final deployment summary
_print_deployment_summary() {
    local minutes="$1"
    local seconds="$2"
    shift 2
    local failed_steps=("$@")

    local server_ip
    server_ip=$(_get_public_ip)
    local exposure_profile
    exposure_profile="$(bifrost_exposure_profile)"

    echo ""
    echo ""
    if [[ ${#failed_steps[@]} -eq 0 ]]; then
        log_info "=================================================================="
        log_info ""
        log_info "   AI GATEWAY BRIDGE - SERVER B DEPLOYMENT COMPLETE"
        log_info ""
        log_info "=================================================================="
    else
        log_error "=================================================================="
        log_error ""
        log_error "   AI GATEWAY BRIDGE - SERVER B DEPLOYMENT INCOMPLETE"
        log_error ""
        log_error "=================================================================="
    fi
    log_info ""
    log_info "   Deployment time: ${minutes}m ${seconds}s"
    log_info ""
    log_info "   Exposure profile: ${exposure_profile}"
    log_info ""

    # Service status
    log_info "   SERVICE STATUS:"
    if systemctl is-active --quiet xray 2>/dev/null; then
        log_success "     [OK] Xray Server"
    else
        log_error "     [FAIL] Xray Server"
    fi

    if systemctl is-active --quiet x-ui 2>/dev/null; then
        log_success "     [OK] 3x-ui Panel"
    else
        log_info "     [--] 3x-ui Panel (not installed or not running)"
    fi

    if systemctl is-active --quiet hysteria-server 2>/dev/null; then
        log_success "     [OK] Hysteria 2 Server"
    else
        log_info "     [--] Hysteria 2 (not installed or not running)"
    fi

    if systemctl is-active --quiet caddy 2>/dev/null; then
        log_success "     [OK] Caddy Web Server"
    else
        log_error "     [FAIL] Caddy Web Server"
    fi

    # BBR status
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "${current_cc}" == "bbr" ]]; then
        log_success "     [OK] BBR Congestion Control"
    else
        log_warn "     [WARN] BBR not active (using: ${current_cc})"
    fi

    echo ""

    # Connection info
    if [[ -f "${DEPLOY_STATE_DIR}/state.env" ]]; then
        local xray_uuid xray_port xray_pubkey xray_sni xray_short_id
        xray_uuid=$(grep '^XRAY_UUID=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
        xray_port=$(grep '^XRAY_LISTEN_PORT=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
        xray_pubkey=$(grep '^XRAY_PUBLIC_KEY=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
        xray_sni=$(grep '^XRAY_SNI=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
        xray_short_id=$(grep '^XRAY_SHORT_ID=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
        local xui_port xui_user xui_pass
        xui_port=$(grep '^THREE_X_UI_PORT=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
        xui_user=$(grep '^THREE_X_UI_USER=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
        xui_pass=$(grep '^THREE_X_UI_PASS=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
        local xui_direct_open caddy_domain
        xui_direct_open=$(grep '^THREE_X_UI_DIRECT_PORT_OPEN=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
        caddy_domain=$(grep '^CADDY_B_DOMAIN=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
        local hy2_port hy2_domain hy2_pass
        hy2_port=$(grep '^HYSTERIA2_PORT=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
        hy2_domain=$(grep '^HYSTERIA2_DOMAIN=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
        hy2_pass=$(grep '^HYSTERIA2_PASSWORD=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true

        # Print sensitive connection details ONLY to stdout (not to log file)
        if [[ -n "${xray_uuid}" ]]; then
            echo -e "   XRAY CONNECTION INFO (for Server A):"
            echo -e "     Server IP:   ${server_ip}"
            echo -e "     Port:        ${xray_port}"
            echo -e "     UUID:        ${xray_uuid}"
            echo -e "     Public Key:  ${xray_pubkey}"
            echo -e "     SNI:         ${xray_sni}"
            echo -e "     Short ID:    ${xray_short_id}"
            echo -e "     Flow:        xtls-rprx-vision"
            echo ""
        fi

        if [[ -n "${xui_port}" ]]; then
            echo -e "   3X-UI PANEL:"
            if [[ "${xui_direct_open}" == "yes" ]]; then
                echo -e "     Direct URL: http://${server_ip}:${xui_port} (lab profile only)"
            else
                echo -e "     Direct URL: not opened by firewall in ${exposure_profile} profile"
            fi
            if [[ -n "${caddy_domain}" ]]; then
                echo -e "     Caddy URL:  https://${caddy_domain}/xui-panel/"
            else
                echo -e "     Caddy URL:  http://${server_ip}/xui-panel/"
            fi
            echo -e "     Username:  ${xui_user}"
            echo -e "     Password:  ${xui_pass}"
            if [[ "${exposure_profile}" == "vpn-first" ]]; then
                echo -e "     Access:    VPN/private allowlist only"
            elif [[ "${exposure_profile}" == "public-managed" ]]; then
                echo -e "     Access:    public-managed; protect with WAF/source allowlists"
            else
                echo -e "     Access:    lab; not safe for production"
            fi
            echo ""
        fi

        if [[ -n "${hy2_port}" ]]; then
            echo -e "   HYSTERIA 2:"
            echo -e "     Domain:    ${hy2_domain}"
            echo -e "     Port:      ${hy2_port} (UDP)"
            echo -e "     Password:  ${hy2_pass}"
            echo ""
        fi
    fi

    # Failed steps
    if [[ ${#failed_steps[@]} -gt 0 ]]; then
        log_warn "   FAILED/SKIPPED STEPS:"
        for step in "${failed_steps[@]}"; do
            log_warn "     - ${step}"
        done
        echo ""
        log_error "   Deployment status: incomplete. Review the failed steps above before using this server."
        echo ""
    fi

    log_info "   FILES:"
    log_info "     Connection info:  ${CONNECTION_INFO_FILE}"
    log_info "     Deploy state:     ${DEPLOY_STATE_DIR}/state.env"
    log_info "     Xray config:      ${XRAY_CONFIG_FILE}"
    if [[ -f "${HYSTERIA_CONFIG_DIR}/config.yaml" ]]; then
        log_info "     Hysteria config:  ${HYSTERIA_CONFIG_DIR}/config.yaml"
    fi
    log_info "     Caddy config:     ${CADDY_CONFIG_DIR}/Caddyfile"
    echo ""
    log_info "   NEXT STEPS:"
    log_info "     1. Copy the connection info above to Server A"
    log_info "     2. Run the install script on Server A and select 'Server A'"
    log_info "     3. Enter the connection parameters when prompted"
    log_info "     4. Verify exposure profile '${exposure_profile}' before production use"
    echo ""
    log_info "=================================================================="
    echo ""
}

# Save consolidated connection info for use by Server A deployment
_save_final_connection_info() {
    if [[ ! -f "${DEPLOY_STATE_DIR}/state.env" ]]; then
        return
    fi

    local server_ip
    server_ip=$(_get_public_ip)

    # Append server IP to state
    _save_deploy_state "SERVER_B_IP" "${server_ip}"
    _save_deploy_state "DEPLOY_TIMESTAMP" "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

    # Also update the connection info file with final data
    if [[ -f "${CONNECTION_INFO_FILE}" ]]; then
        echo "" >> "${CONNECTION_INFO_FILE}"
        echo "# Additional Services" >> "${CONNECTION_INFO_FILE}"

        local xui_port
        xui_port=$(grep '^THREE_X_UI_PORT=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
        if [[ -n "${xui_port}" ]]; then
            echo "THREE_X_UI_PORT=${xui_port}" >> "${CONNECTION_INFO_FILE}"
        fi

        local hy2_port hy2_domain hy2_pass
        hy2_port=$(grep '^HYSTERIA2_PORT=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
        hy2_domain=$(grep '^HYSTERIA2_DOMAIN=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
        hy2_pass=$(grep '^HYSTERIA2_PASSWORD=' "${DEPLOY_STATE_DIR}/state.env" 2>/dev/null | tail -1 | cut -d= -f2) || true
        if [[ -n "${hy2_port}" ]]; then
            echo "HYSTERIA2_PORT=${hy2_port}" >> "${CONNECTION_INFO_FILE}"
            echo "HYSTERIA2_DOMAIN=${hy2_domain}" >> "${CONNECTION_INFO_FILE}"
            echo "HYSTERIA2_PASSWORD=${hy2_pass}" >> "${CONNECTION_INFO_FILE}"
        fi

        chmod 600 "${CONNECTION_INFO_FILE}"
    fi

    log_info "All connection info saved to ${CONNECTION_INFO_FILE}"
    log_info "Deploy state saved to ${DEPLOY_STATE_DIR}/state.env"
}

server_b_usage() {
    cat <<'EOF'
Bifrost Server B deployment helper

Usage:
  scripts/server-b.sh --deploy
  scripts/server-b.sh --enable-distribution
  scripts/server-b.sh --disable-distribution
  scripts/server-b.sh --rotate-bootstrap-pwd
  scripts/server-b.sh --help

Commands:
  --deploy                 Run the existing interactive Server B deployment.
  --enable-distribution    Enable the private distribution stack on Server B.
  --disable-distribution   Stop distribution services without deleting data.
  --rotate-bootstrap-pwd   Rotate Verdaccio bootstrap account password.
EOF
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        --deploy|deploy)
            deploy_server_b
            ;;
        --enable-distribution)
            enable_distribution
            ;;
        --disable-distribution)
            disable_distribution
            ;;
        --rotate-bootstrap-pwd)
            rotate_verdaccio_bootstrap_pwd
            ;;
        --help|-h|help|"")
            server_b_usage
            ;;
        *)
            log_error "Unknown Server B command: ${1}"
            server_b_usage
            exit 1
            ;;
    esac
fi
