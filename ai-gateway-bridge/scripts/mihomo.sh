#!/usr/bin/env bash
# =============================================================================
# AI Gateway Bridge - Mihomo Routing Engine
# =============================================================================
# Description : Deploys Mihomo (Meta) as the central routing engine on Server A.
#               Mihomo handles ALL routing decisions (AI -> proxy, streaming ->
#               reject, CN -> direct, MATCH -> REJECT whitelist mode).
#               Xray is reduced to a pure VLESS+Reality transport.
#
# Architecture:
#   New API (Docker)
#     -> HTTP_PROXY=host.docker.internal:7890
#       -> Mihomo (mixed-port 7890, routing engine)
#         -> Xray (SOCKS5 127.0.0.1:10808, VLESS+Reality upstream)
#           -> Tunnel -> Server B -> Internet
#
# Usage       : source scripts/mihomo.sh   (sourced by install.sh)
#               Or run directly: bash scripts/mihomo.sh deploy
#
# Dependencies: scripts/common.sh
# =============================================================================

set -euo pipefail

# Guard against double-sourcing (readonly variables would conflict)
if [[ -n "${_MIHOMO_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
readonly _MIHOMO_SH_LOADED=1

# Resolve the directory this script resides in
_MIHOMO_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MIHOMO_PROJECT_DIR="$(cd "${_MIHOMO_SCRIPT_DIR}/.." && pwd)"

# Source common utilities
if [[ -f "${_MIHOMO_SCRIPT_DIR}/common.sh" ]]; then
    # shellcheck source=scripts/common.sh
    source "${_MIHOMO_SCRIPT_DIR}/common.sh"
else
    echo "[FATAL] common.sh not found at ${_MIHOMO_SCRIPT_DIR}/common.sh" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly MIHOMO_BIN="/usr/local/bin/mihomo"
readonly MIHOMO_CONFIG_DIR="/etc/mihomo"
readonly MIHOMO_CONFIG="${MIHOMO_CONFIG_DIR}/config.yaml"
readonly MIHOMO_RULESET_DIR="${MIHOMO_CONFIG_DIR}/ruleset"
readonly MIHOMO_CACHE_DIR="/var/lib/mihomo"
readonly MIHOMO_LOG_DIR="/var/log/mihomo"
readonly MIHOMO_GEODATA_DIR="${MIHOMO_CONFIG_DIR}"
readonly MIHOMO_SERVICE_NAME="mihomo"

readonly MIHOMO_TEMPLATE="${_MIHOMO_PROJECT_DIR}/configs/mihomo/config.yaml.tpl"
readonly MIHOMO_AI_RULESET_SRC="${_MIHOMO_PROJECT_DIR}/configs/mihomo/ruleset/ai-domains.yaml"
readonly MIHOMO_STREAMING_RULESET_SRC="${_MIHOMO_PROJECT_DIR}/configs/mihomo/ruleset/streaming-block.yaml"

# Upstream Xray SOCKS5 endpoint (Mihomo forwards proxy traffic here)
readonly XRAY_UPSTREAM_ADDR="127.0.0.1"
readonly XRAY_UPSTREAM_PORT="10808"

# Mihomo mixed-port (HTTP+SOCKS5) for Docker containers
readonly MIHOMO_MIXED_PORT="7890"
readonly MIHOMO_SOCKS_PORT="7891"
readonly MIHOMO_API_PORT="9090"
readonly MIHOMO_API_SECRET=""

# Server B connection config (shared with server-a.sh)
readonly _MIHOMO_SERVER_B_CONF="/root/server-b-connection.conf"

# GitHub release API
readonly MIHOMO_REPO="MetaCubeX/mihomo"
readonly MIHOMO_RELEASE_API="https://github.com/${MIHOMO_REPO}/releases"

# GeoIP/GeoSite download URLs (MetaCubeX maintained)
readonly GEOIP_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.dat"
readonly GEOSITE_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat"
readonly COUNTRY_MMDB_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/country.mmdb"
readonly ASN_MMDB_URL="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/GeoLite2-ASN.mmdb"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Detect system architecture and return the Mihomo binary suffix.
# Returns: arch string suitable for Mihomo release filename.
_mihomo_detect_arch() {
    local arch
    arch="$(uname -m)"
    case "${arch}" in
        x86_64|amd64)    echo "linux-amd64" ;;
        aarch64|arm64)   echo "linux-arm64" ;;
        armv7l|armv7)    echo "linux-armv7" ;;
        i386|i686)       echo "linux-386" ;;
        *)
            log_error "Unsupported architecture for Mihomo: ${arch}"
            return 1
            ;;
    esac
}

# Parse the latest release tag from GitHub API.
_mihomo_latest_version() {
    local api_url="https://api.github.com/repos/${MIHOMO_REPO}/releases/latest"
    local tag=""
    local api_response

    # Try direct GitHub API first, then configured mirrors
    api_response="$(github_fetch_text "${api_url}" 20 10)" || true
    if [[ -n "${api_response}" ]]; then
        tag=$(echo "${api_response}" | grep '"tag_name"' | head -1 | sed -E 's/.*"tag_name":\s*"([^"]+)".*/\1/')
    fi

    if [[ -z "${tag}" ]]; then
        log_error "Failed to fetch latest Mihomo version from GitHub API (direct + configured mirrors)."
        return 1
    fi
    echo "${tag}"
}

# Load Server B connection details (reuses server-a.sh pattern).
_mihomo_load_server_b() {
    if [[ -n "${SERVER_B_IP:-}" && -n "${SERVER_B_UUID:-}" ]]; then
        return 0
    fi

    if [[ ! -f "${_MIHOMO_SERVER_B_CONF}" ]]; then
        log_error "Server B configuration not found at ${_MIHOMO_SERVER_B_CONF}."
        log_error "Please run Server A deployment (collect_server_b_info) first."
        return 1
    fi

    # shellcheck source=/dev/null
    source "${_MIHOMO_SERVER_B_CONF}"

    local missing=0
    for var in SERVER_B_IP SERVER_B_PORT SERVER_B_UUID SERVER_B_PUBKEY SERVER_B_SNI; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Missing required field: ${var} in ${_MIHOMO_SERVER_B_CONF}"
            missing=1
        fi
    done

    if [[ ${missing} -eq 1 ]]; then
        return 1
    fi

    export SERVER_B_IP SERVER_B_PORT SERVER_B_UUID SERVER_B_PUBKEY SERVER_B_SNI SERVER_B_SHORT_ID
    return 0
}

# =============================================================================
# 1. install_mihomo
# =============================================================================
# Downloads Mihomo (Meta) binary from GitHub, installs to /usr/local/bin,
# creates systemd service unit, downloads GeoIP + GeoSite databases.
# =============================================================================
install_mihomo() {
    log_info "============================================"
    log_info "  Installing Mihomo (Meta) Routing Engine"
    log_info "============================================"

    # --- Prerequisites ---
    install_if_missing curl curl
    install_if_missing unzip unzip
    install_if_missing gzip gzip

    # --- Detect architecture ---
    local mihomo_arch
    mihomo_arch="$(_mihomo_detect_arch)" || return 1
    log_info "Detected architecture: ${mihomo_arch}"

    # --- Fetch latest version ---
    local version
    version="$(_mihomo_latest_version)" || return 1
    log_info "Latest Mihomo version: ${version}"

    # --- Check if already installed at this version ---
    if [[ -x "${MIHOMO_BIN}" ]]; then
        local installed_version
        installed_version="$("${MIHOMO_BIN}" -v 2>/dev/null | head -1 | grep -oP 'v[\d.]+' || echo 'unknown')"
        if [[ "${installed_version}" == "${version}" ]]; then
            log_info "Mihomo ${version} is already installed. Skipping download."
        else
            log_info "Upgrading Mihomo from ${installed_version} to ${version}..."
            _mihomo_download_binary "${version}" "${mihomo_arch}"
        fi
    else
        _mihomo_download_binary "${version}" "${mihomo_arch}"
    fi

    # --- Create directories ---
    mkdir -p "${MIHOMO_CONFIG_DIR}" "${MIHOMO_RULESET_DIR}" "${MIHOMO_CACHE_DIR}" "${MIHOMO_LOG_DIR}"
    # Config dir contains API secret and upstream connection details — restrict access
    chmod 700 "${MIHOMO_CONFIG_DIR}"
    chmod 755 "${MIHOMO_CACHE_DIR}"

    # --- Download GeoIP + GeoSite databases ---
    _mihomo_download_geodata

    # --- Create systemd service ---
    _mihomo_create_service

    # --- Verify installation ---
    if [[ ! -x "${MIHOMO_BIN}" ]]; then
        die "Mihomo binary not found after installation."
    fi

    local ver_output
    ver_output="$("${MIHOMO_BIN}" -v 2>/dev/null | head -1)" || ver_output="unknown"
    log_success "Mihomo installed successfully: ${ver_output}"
}

# Internal: download and install the Mihomo binary.
_mihomo_download_binary() {
    local version="${1}"
    local mihomo_arch="${2}"

    # Mihomo release naming convention: mihomo-linux-amd64-v1.19.0.gz
    # The version tag may be like "v1.19.0" or "v1.19.0-alpha.1"
    local filename="mihomo-${mihomo_arch}-${version}.gz"
    local download_url="${MIHOMO_RELEASE_API}/download/${version}/${filename}"

    log_info "Downloading Mihomo from: ${download_url}"

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    register_cleanup "${tmp_dir}"

    local gz_file="${tmp_dir}/mihomo.gz"

    if ! github_download "${download_url}" "${gz_file}" 120; then
        # Fallback: try alpha naming pattern
        local alt_filename="mihomo-${mihomo_arch}-${version}.gz"
        local alt_url="${MIHOMO_RELEASE_API}/download/${version}/${alt_filename}"
        log_warn "Primary download failed. Trying alternative naming: ${alt_url}"
        if ! github_download "${alt_url}" "${gz_file}" 120; then
            log_error "Failed to download Mihomo binary from all sources (direct + mirrors)."
            rm -rf "${tmp_dir}"
            return 1
        fi
    fi

    # Extract gzip
    log_info "Extracting Mihomo binary..."
    if ! gzip -d "${gz_file}"; then
        log_error "Failed to decompress Mihomo archive."
        rm -rf "${tmp_dir}"
        return 1
    fi

    local extracted="${tmp_dir}/mihomo"
    if [[ ! -f "${extracted}" ]]; then
        # gzip removes the .gz extension, so the file should be at gz_file without .gz
        local decompressed="${gz_file%.gz}"
        if [[ -f "${decompressed}" ]]; then
            extracted="${decompressed}"
        else
            log_error "Decompressed binary not found."
            rm -rf "${tmp_dir}"
            return 1
        fi
    fi

    # Stop service before replacing binary
    if systemctl is-active --quiet "${MIHOMO_SERVICE_NAME}" 2>/dev/null; then
        log_info "Stopping Mihomo service before upgrade..."
        systemctl stop "${MIHOMO_SERVICE_NAME}" || true
    fi

    # Install binary
    install -m 755 "${extracted}" "${MIHOMO_BIN}"
    rm -rf "${tmp_dir}"

    log_success "Mihomo binary installed to ${MIHOMO_BIN}"
}

# Internal: download GeoIP and GeoSite databases for Mihomo.
_mihomo_download_geodata() {
    log_info "Downloading GeoIP/GeoSite databases for Mihomo..."

    local geodata_files=(
        "${GEOIP_URL}|${MIHOMO_GEODATA_DIR}/geoip.dat"
        "${GEOSITE_URL}|${MIHOMO_GEODATA_DIR}/geosite.dat"
        "${COUNTRY_MMDB_URL}|${MIHOMO_GEODATA_DIR}/country.mmdb"
        "${ASN_MMDB_URL}|${MIHOMO_GEODATA_DIR}/GeoLite2-ASN.mmdb"
    )

    for entry in ${geodata_files[@]+"${geodata_files[@]}"}; do
        local url="${entry%%|*}"
        local dest="${entry##*|}"
        local filename
        filename="$(basename "${dest}")"
        local require_fresh_download=0

        if [[ -s "${dest}" ]]; then
            # Check if file is older than 7 days
            local age_days
            age_days="$(( ($(date +%s) - $(stat -c %Y "${dest}" 2>/dev/null || echo 0)) / 86400 ))"
            if [[ ${age_days} -lt 7 ]]; then
                log_info "GeoData '${filename}' is up-to-date (${age_days} days old). Skipping."
                continue
            fi
            log_info "GeoData '${filename}' is ${age_days} days old. Updating..."
        else
            log_info "GeoData '${filename}' is missing or empty. A fresh download is required."
            require_fresh_download=1
        fi

        log_info "Downloading ${filename} (with China mirror fallback)..."
        local tmp_file
        tmp_file="$(mktemp "${dest}.tmp.XXXXXX")"
        if github_download "${url}" "${tmp_file}" 120 && [[ -s "${tmp_file}" ]]; then
            mv "${tmp_file}" "${dest}"
            log_success "Downloaded: ${filename}"
        else
            rm -f "${tmp_file}" 2>/dev/null || true
            if (( require_fresh_download )); then
                log_error "Failed to download required ${filename} from all sources."
                return 1
            fi
            log_warn "Failed to download ${filename} from all sources. Routing may use cached data."
        fi
    done
}

# Internal: create systemd service unit for Mihomo.
_mihomo_create_service() {
    log_info "Creating Mihomo systemd service..."

    cat > /etc/systemd/system/${MIHOMO_SERVICE_NAME}.service <<'SERVICEEOF'
[Unit]
Description=Mihomo (Meta) - Routing Engine for AI Gateway Bridge
Documentation=https://wiki.metacubex.one
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
LimitNPROC=500
LimitNOFILE=1048576

CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE

ExecStartPre=/usr/local/bin/mihomo -t -d /etc/mihomo
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
ExecReload=/bin/kill -HUP $MAINPID

Restart=on-failure
RestartSec=5s

StandardOutput=journal
StandardError=journal
SyslogIdentifier=mihomo

[Install]
WantedBy=multi-user.target
SERVICEEOF

    systemctl daemon-reload
    log_success "Mihomo systemd service created."
}

# =============================================================================
# 2. configure_mihomo
# =============================================================================
# Generates the Mihomo config.yaml from the template, substituting Server B
# connection details and deployment-specific values. Installs rulesets.
# =============================================================================
configure_mihomo() {
    log_info "============================================"
    log_info "  Configuring Mihomo Routing Engine"
    log_info "============================================"

    # --- Load Server B connection details ---
    _mihomo_load_server_b || return 1

    # --- Install rulesets ---
    generate_mihomo_rulesets

    # --- Install ruleset files from project configs ---
    log_info "Installing ruleset files..."
    if [[ -f "${MIHOMO_AI_RULESET_SRC}" ]]; then
        cp -f "${MIHOMO_AI_RULESET_SRC}" "${MIHOMO_RULESET_DIR}/ai-domains.yaml"
        log_info "Installed: ai-domains.yaml"
    else
        log_warn "AI domains ruleset source not found: ${MIHOMO_AI_RULESET_SRC}"
        log_info "Generating AI domains ruleset from whitelist..."
        generate_mihomo_rulesets
    fi

    if [[ -f "${MIHOMO_STREAMING_RULESET_SRC}" ]]; then
        cp -f "${MIHOMO_STREAMING_RULESET_SRC}" "${MIHOMO_RULESET_DIR}/streaming-block.yaml"
        log_info "Installed: streaming-block.yaml"
    else
        log_warn "Streaming block ruleset source not found: ${MIHOMO_STREAMING_RULESET_SRC}"
    fi

    # --- Generate API secret ---
    local api_secret
    api_secret="$(generate_random_password 24)"

    # --- Render config from template ---
    log_info "Rendering Mihomo configuration..."

    if [[ -f "${MIHOMO_TEMPLATE}" ]]; then
        template_render "${MIHOMO_TEMPLATE}" "${MIHOMO_CONFIG}" \
            "MIHOMO_MIXED_PORT=${MIHOMO_MIXED_PORT}" \
            "MIHOMO_SOCKS_PORT=${MIHOMO_SOCKS_PORT}" \
            "MIHOMO_API_PORT=${MIHOMO_API_PORT}" \
            "MIHOMO_API_SECRET=${api_secret}" \
            "XRAY_UPSTREAM_ADDR=${XRAY_UPSTREAM_ADDR}" \
            "XRAY_UPSTREAM_PORT=${XRAY_UPSTREAM_PORT}" \
            "SERVER_B_IP=${SERVER_B_IP}" \
            "SERVER_B_PORT=${SERVER_B_PORT}" \
            "SERVER_B_UUID=${SERVER_B_UUID}" \
            "SERVER_B_PUBKEY=${SERVER_B_PUBKEY}" \
            "SERVER_B_SNI=${SERVER_B_SNI}" \
            "SERVER_B_SHORT_ID=${SERVER_B_SHORT_ID:-}"
    else
        log_warn "Template not found: ${MIHOMO_TEMPLATE}"
        log_info "Generating Mihomo config directly..."
        _mihomo_generate_config_direct "${api_secret}"
    fi

    # Restrict config file permissions — contains API secret and upstream details
    chmod 600 "${MIHOMO_CONFIG}"

    # --- Validate configuration ---
    log_info "Validating Mihomo configuration..."
    if "${MIHOMO_BIN}" -t -d "${MIHOMO_CONFIG_DIR}" &>/dev/null; then
        log_success "Mihomo configuration is valid."
    else
        log_error "Mihomo configuration validation failed!"
        "${MIHOMO_BIN}" -t -d "${MIHOMO_CONFIG_DIR}" 2>&1 || true
        return 1
    fi

    # --- Enable and start service ---
    enable_service "${MIHOMO_SERVICE_NAME}"
    restart_service "${MIHOMO_SERVICE_NAME}"

    # --- Update Docker proxy if New API was deployed with Xray fallback port ---
    _mihomo_update_docker_proxy

    # --- Print connection info ---
    # NOTE: Print API secret ONLY to stdout (not to log file) to avoid
    # persisting secrets in /var/log/ai-gateway-bridge/ai-gateway-bridge.log.
    log_success "Mihomo routing engine configured successfully."
    log_info "  Mixed proxy (HTTP+SOCKS5): 0.0.0.0:${MIHOMO_MIXED_PORT}"
    log_info "  SOCKS5 proxy:              127.0.0.1:${MIHOMO_SOCKS_PORT}"
    log_info "  RESTful API:               127.0.0.1:${MIHOMO_API_PORT}"
    echo -e "  API Secret:                ${api_secret}"
    log_info ""
    log_info "Docker containers should use:"
    log_info "  HTTP_PROXY=http://host.docker.internal:${MIHOMO_MIXED_PORT}"
    log_info "  HTTPS_PROXY=http://host.docker.internal:${MIHOMO_MIXED_PORT}"
}

# Internal: update Docker New API proxy port from Xray fallback (10809) to
# Mihomo (7890) if Mihomo was deployed AFTER Docker/New API.
# This fixes the data flow break when install order is Xray -> Docker -> Mihomo.
_mihomo_update_docker_proxy() {
    local compose_file="/opt/new-api/docker-compose.yml"

    if [[ ! -f "${compose_file}" ]]; then
        return 0
    fi

    # Check if docker-compose.yml is using the Xray fallback port (10809)
    if grep -q "host.docker.internal:10809" "${compose_file}" 2>/dev/null; then
        log_info "Detected New API Docker using Xray fallback port (10809)."
        log_info "Updating to Mihomo port (${MIHOMO_MIXED_PORT})..."

        # Backup before modifying
        cp "${compose_file}" "${compose_file}.bak.$(date +%Y%m%d%H%M%S)"

        # Replace 10809 with Mihomo port
        sed -i "s/host\.docker\.internal:10809/host.docker.internal:${MIHOMO_MIXED_PORT}/g" "${compose_file}"

        # Also update the comment about which proxy is being used
        sed -i "s/Xray HTTP (port 10809)/Mihomo (port ${MIHOMO_MIXED_PORT})/g" "${compose_file}"
        sed -i "s/Xray HTTP proxy (port 10809)/Mihomo (port ${MIHOMO_MIXED_PORT})/g" "${compose_file}"

        # Restart New API to pick up the new proxy
        if command -v docker &>/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^new-api$'; then
            log_info "Restarting New API container to use Mihomo proxy..."
            (cd /opt/new-api && docker compose up -d 2>/dev/null) || \
                docker restart new-api 2>/dev/null || \
                log_warn "Failed to restart New API. Restart manually: cd /opt/new-api && docker compose up -d"
        fi

        log_success "New API proxy updated: 10809 -> ${MIHOMO_MIXED_PORT}"
    else
        log_info "New API Docker proxy is already configured for Mihomo."
    fi
}

# Internal: generate config.yaml directly when template is not available.
# This is a fallback; the template method via template_render() is preferred.
_mihomo_generate_config_direct() {
    local api_secret="${1}"

    cat > "${MIHOMO_CONFIG}" <<CFGEOF
# =============================================================================
# Mihomo (Meta) Configuration - AI Gateway Bridge
# Generated on $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================
# Architecture:
#   Docker (New API) -> HTTP_PROXY -> Mihomo:${MIHOMO_MIXED_PORT}
#     -> routing decisions -> Xray SOCKS5 (127.0.0.1:${XRAY_UPSTREAM_PORT})
#       -> VLESS+Reality tunnel -> Server B -> Internet
# =============================================================================

# --- General Settings ---
mixed-port: ${MIHOMO_MIXED_PORT}
socks-port: ${MIHOMO_SOCKS_PORT}
allow-lan: false
bind-address: "127.0.0.1"
mode: rule
log-level: info
ipv6: false
unified-delay: true
tcp-concurrent: true
geodata-mode: true
geo-auto-update: true
geo-update-interval: 168
geodata-loader: standard
geox-url:
  geoip: "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.dat"
  geosite: "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat"
  mmdb: "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/country.mmdb"
  asn: "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/GeoLite2-ASN.mmdb"

find-process-mode: "off"
keep-alive-idle: 600
keep-alive-interval: 15

# --- External Controller (RESTful API) ---
external-controller: 127.0.0.1:${MIHOMO_API_PORT}
secret: "${api_secret}"

# --- Profile ---
profile:
  store-selected: true
  store-fake-ip: true

# --- DNS Configuration (fake-ip mode) ---
dns:
  enable: true
  listen: 0.0.0.0:1053
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - "*.lan"
    - "*.local"
    - "*.localhost"
    - "localhost.ptlogin2.qq.com"
    - "+.srv.nintendo.net"
    - "+.stun.playstation.net"
    - "+.msftconnecttest.com"
    - "+.msftncsi.com"
    - "WORKGROUP"
    - "time.*.com"
    - "time.*.gov"
    - "time.*.edu.cn"
    - "time.*.apple.com"
    - "time-ios.apple.com"
    - "time-macos.apple.com"
    - "ntp.*.com"
    - "+.pool.ntp.org"
    - "*.ntp.org.cn"
    - "time1.cloud.tencent.com"
    - "music.163.com"
    - "*.music.163.com"
    - "*.126.net"
    - "*.baidu.com"
    - "*.bdstatic.com"
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  nameserver:
    - "https://dns.alidns.com/dns-query#h3=true"
    - "https://doh.pub/dns-query"
  nameserver-policy:
    "geosite:cn,private":
      - "https://dns.alidns.com/dns-query#h3=true"
      - "https://doh.pub/dns-query"
    "geosite:geolocation-!cn":
      - "https://dns.cloudflare.com/dns-query#h3=true"
      - "https://dns.google/dns-query#h3=true"

# --- Sniffer ---
sniffer:
  enable: true
  force-dns-mapping: true
  parse-pure-ip: true
  override-destination: true
  sniff:
    HTTP:
      ports: [80, 8080-8880]
      override-destination: true
    TLS:
      ports: [443, 8443]
    QUIC:
      ports: [443, 8443]

# --- TUN (disabled, only proxy mode used) ---
tun:
  enable: false

# --- Proxies ---
# Xray SOCKS5 upstream: Mihomo forwards proxy-destined traffic to Xray,
# which handles VLESS+Reality transport to Server B.
proxies:
  - name: "xray-vless-reality"
    type: socks5
    server: ${XRAY_UPSTREAM_ADDR}
    port: ${XRAY_UPSTREAM_PORT}
    udp: true

# --- Proxy Groups ---
proxy-groups:
  - name: "AI-Proxy"
    type: url-test
    proxies:
      - "xray-vless-reality"
    url: "https://api.anthropic.com"
    interval: 300
    timeout: 5000
    lazy: true

  - name: "Fallback"
    type: fallback
    proxies:
      - "xray-vless-reality"
    url: "https://www.gstatic.com/generate_204"
    interval: 300
    timeout: 5000
    lazy: true

  - name: "DIRECT"
    type: select
    proxies:
      - DIRECT

  - name: "REJECT"
    type: select
    proxies:
      - REJECT

# --- Rule Providers ---
rule-providers:
  ai-domains:
    type: file
    behavior: classical
    path: ./ruleset/ai-domains.yaml
    interval: 86400

  streaming-block:
    type: file
    behavior: classical
    path: ./ruleset/streaming-block.yaml
    interval: 86400

# --- Rules ---
# Evaluation order: top to bottom, first match wins.
# Strategy: whitelist mode (MATCH -> REJECT).
rules:
  # 1. Internal/loopback traffic -> DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve
  - IP-CIDR,224.0.0.0/4,DIRECT,no-resolve
  - IP-CIDR6,::1/128,DIRECT,no-resolve
  - IP-CIDR6,fc00::/7,DIRECT,no-resolve
  - IP-CIDR6,fe80::/10,DIRECT,no-resolve

  # 2. Block ads
  - GEOSITE,category-ads-all,REJECT

  # 3. Block streaming services (from ruleset)
  - RULE-SET,streaming-block,REJECT

  # 4. AI services -> proxy (from ruleset)
  - RULE-SET,ai-domains,AI-Proxy

  # 5. China domestic -> DIRECT
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT,no-resolve

  # 6. Private/LAN -> DIRECT
  - GEOSITE,private,DIRECT
  - GEOIP,private,DIRECT,no-resolve

  # 7. MATCH (everything else) -> REJECT (whitelist mode)
  - MATCH,REJECT
CFGEOF

    log_info "Mihomo config generated directly at ${MIHOMO_CONFIG}"
}

# =============================================================================
# 3. generate_mihomo_rulesets
# =============================================================================
# Converts the project's ai-domains.txt whitelist to Mihomo YAML ruleset
# format. Also ensures streaming-block.yaml is present.
# =============================================================================
generate_mihomo_rulesets() {
    log_info "Generating Mihomo rulesets..."

    local whitelist_file="${_MIHOMO_PROJECT_DIR}/configs/whitelist/ai-domains.txt"
    local installed_whitelist="/opt/ai-gateway-bridge/configs/whitelist/ai-domains.txt"

    # Find the whitelist source
    local source_file=""
    if [[ -f "${whitelist_file}" ]]; then
        source_file="${whitelist_file}"
    elif [[ -f "${installed_whitelist}" ]]; then
        source_file="${installed_whitelist}"
    else
        log_error "AI domains whitelist not found."
        log_error "Expected at: ${whitelist_file} or ${installed_whitelist}"
        return 1
    fi

    mkdir -p "${MIHOMO_RULESET_DIR}"

    # --- Convert ai-domains.txt to Mihomo classical ruleset YAML ---
    log_info "Converting ai-domains.txt to Mihomo ruleset format..."

    local output_file="${MIHOMO_RULESET_DIR}/ai-domains.yaml"
    local domain_count=0

    {
        echo "# AI Gateway Bridge - AI Domain Ruleset for Mihomo"
        echo "# Auto-generated from configs/whitelist/ai-domains.txt"
        echo "# Generated on $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# Format: Mihomo classical ruleset"
        echo "payload:"

        while IFS= read -r line; do
            # Skip comments and empty lines
            line="$(echo "${line}" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
            [[ -z "${line}" ]] && continue
            [[ "${line}" =~ ^# ]] && continue

            # Determine match type:
            # - If domain has a subdomain prefix (e.g., api.openai.com), use DOMAIN
            # - If it's a base domain (e.g., claude.ai), use DOMAIN-SUFFIX
            local dot_count
            dot_count="$(echo "${line}" | tr -cd '.' | wc -c)"

            if [[ ${dot_count} -le 1 ]]; then
                # Base domain (e.g., claude.ai) -> DOMAIN-SUFFIX to match all subdomains
                echo "  - DOMAIN-SUFFIX,${line}"
            else
                # Specific subdomain (e.g., api.openai.com) -> exact DOMAIN match
                echo "  - DOMAIN,${line}"
            fi

            ((domain_count++)) || true
        done < "${source_file}"
    } > "${output_file}"

    log_success "AI domains ruleset generated: ${output_file} (${domain_count} domains)"

    # --- Ensure streaming-block.yaml exists ---
    local streaming_file="${MIHOMO_RULESET_DIR}/streaming-block.yaml"
    if [[ ! -f "${streaming_file}" ]]; then
        if [[ -f "${MIHOMO_STREAMING_RULESET_SRC}" ]]; then
            cp -f "${MIHOMO_STREAMING_RULESET_SRC}" "${streaming_file}"
            log_info "Installed streaming-block.yaml from project configs."
        else
            log_warn "streaming-block.yaml not found in project configs. Generating default..."
            _mihomo_generate_default_streaming_ruleset "${streaming_file}"
        fi
    fi
}

# Internal: generate a default streaming block ruleset if the source file is missing.
_mihomo_generate_default_streaming_ruleset() {
    local output_file="${1}"

    cat > "${output_file}" <<'STREAMEOF'
# AI Gateway Bridge - Streaming Services Block Ruleset
# Auto-generated default. Edit configs/mihomo/ruleset/streaming-block.yaml to customize.
payload:
  # Netflix
  - DOMAIN-SUFFIX,netflix.com
  - DOMAIN-SUFFIX,netflix.net
  - DOMAIN-SUFFIX,nflxvideo.net
  - DOMAIN-SUFFIX,nflxso.net
  - DOMAIN-SUFFIX,nflxext.com
  - DOMAIN-SUFFIX,nflximg.net
  # YouTube
  - DOMAIN-SUFFIX,youtube.com
  - DOMAIN-SUFFIX,youtu.be
  - DOMAIN-SUFFIX,googlevideo.com
  - DOMAIN-SUFFIX,ytimg.com
  - DOMAIN-SUFFIX,yt3.ggpht.com
  # Twitch
  - DOMAIN-SUFFIX,twitch.tv
  - DOMAIN-SUFFIX,ttvnw.net
  - DOMAIN-SUFFIX,jtvnw.net
  # Disney+
  - DOMAIN-SUFFIX,disneyplus.com
  - DOMAIN-SUFFIX,disney-plus.net
  - DOMAIN-SUFFIX,bamgrid.com
  - DOMAIN-SUFFIX,dssott.com
  # HBO
  - DOMAIN-SUFFIX,hbo.com
  - DOMAIN-SUFFIX,hbonow.com
  - DOMAIN-SUFFIX,hbomax.com
  # Hulu
  - DOMAIN-SUFFIX,hulu.com
  - DOMAIN-SUFFIX,hulustream.com
  # Amazon Prime Video
  - DOMAIN-SUFFIX,primevideo.com
  - DOMAIN-SUFFIX,amazonvideo.com
  # Spotify
  - DOMAIN-SUFFIX,spotify.com
  - DOMAIN-SUFFIX,spotifycdn.com
  - DOMAIN-SUFFIX,scdn.co
  # Tidal
  - DOMAIN-SUFFIX,tidal.com
  - DOMAIN-SUFFIX,tidalhifi.com
  # Social Media
  - DOMAIN-SUFFIX,tiktok.com
  - DOMAIN-SUFFIX,tiktokv.com
  - DOMAIN-SUFFIX,musical.ly
  - DOMAIN-SUFFIX,instagram.com
  - DOMAIN-SUFFIX,cdninstagram.com
  - DOMAIN-SUFFIX,facebook.com
  - DOMAIN-SUFFIX,fbcdn.net
  - DOMAIN-SUFFIX,twitter.com
  - DOMAIN-SUFFIX,x.com
  - DOMAIN-SUFFIX,twimg.com
  - DOMAIN-SUFFIX,reddit.com
  - DOMAIN-SUFFIX,redd.it
  - DOMAIN-SUFFIX,redditstatic.com
  # Adult
  - DOMAIN-SUFFIX,pornhub.com
  - DOMAIN-SUFFIX,xvideos.com
  - DOMAIN-SUFFIX,xhamster.com
STREAMEOF

    log_info "Default streaming-block.yaml generated."
}

# =============================================================================
# 4. add_mihomo_node
# =============================================================================
# Adds a new upstream server (Xray SOCKS5 endpoint) to Mihomo's proxy list
# and proxy groups. Supports adding multiple upstream servers for load
# balancing or failover.
#
# Arguments:
#   $1 - Node name (e.g., "xray-server-2")
#   $2 - SOCKS5 address (e.g., "127.0.0.1")
#   $3 - SOCKS5 port (e.g., "10810")
# =============================================================================
add_mihomo_node() {
    local node_name="${1:-}"
    local node_addr="${2:-}"
    local node_port="${3:-}"

    if [[ -z "${node_name}" || -z "${node_addr}" || -z "${node_port}" ]]; then
        log_error "Usage: add_mihomo_node <name> <address> <port>"
        log_error "Example: add_mihomo_node 'xray-server-2' '127.0.0.1' '10810'"
        return 1
    fi

    # Reject shell/YAML/meta characters before feeding values into yq/sed.
    # These values are later interpolated into expressions and config blocks.
    if [[ ! "${node_name}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
        log_error "Invalid node name: ${node_name}"
        log_error "Node name may only contain letters, digits, dot, underscore, colon, and hyphen."
        return 1
    fi

    if [[ ! "${node_addr}" =~ ^[A-Za-z0-9._:-]+$ ]]; then
        log_error "Invalid node address: ${node_addr}"
        log_error "Node address may only contain letters, digits, dot, underscore, colon, and hyphen."
        return 1
    fi

    # Validate port
    if ! [[ "${node_port}" =~ ^[0-9]+$ ]] || (( node_port < 1 || node_port > 65535 )); then
        log_error "Invalid port: ${node_port}"
        return 1
    fi

    if [[ ! -f "${MIHOMO_CONFIG}" ]]; then
        log_error "Mihomo config not found at ${MIHOMO_CONFIG}. Run configure_mihomo first."
        return 1
    fi

    # Check dependencies
    install_if_missing yq yq 2>/dev/null || true
    if ! check_command yq; then
        log_error "yq is required for safe Mihomo config edits. Install yq and retry."
        return 1
    fi

    # Backup current config
    backup_file "${MIHOMO_CONFIG}" || true

    log_info "Adding node '${node_name}' (${node_addr}:${node_port}) to Mihomo config..."

    # Check if node already exists
    if grep -q "name: \"${node_name}\"" "${MIHOMO_CONFIG}" 2>/dev/null; then
        log_warn "Node '${node_name}' already exists in Mihomo config."
        return 0
    fi

    # Add proxy entry
    if ! yq -i ".proxies += [{\"name\": \"${node_name}\", \"type\": \"socks5\", \"server\": \"${node_addr}\", \"port\": ${node_port}, \"udp\": true}]" \
        "${MIHOMO_CONFIG}"; then
        log_error "Failed to add proxy entry to Mihomo config."
        if [[ -n "${BACKUP_RESULT:-}" && -f "${BACKUP_RESULT}" ]]; then
            cp -f "${BACKUP_RESULT}" "${MIHOMO_CONFIG}"
            log_info "Backup restored."
        fi
        return 1
    fi

    # Add to AI-Proxy group
    if ! yq -i '(.proxy-groups[] | select(.name == "AI-Proxy") | .proxies) += ["'"${node_name}"'"]' \
        "${MIHOMO_CONFIG}"; then
        log_error "Failed to add node to AI-Proxy group."
        if [[ -n "${BACKUP_RESULT:-}" && -f "${BACKUP_RESULT}" ]]; then
            cp -f "${BACKUP_RESULT}" "${MIHOMO_CONFIG}"
            log_info "Backup restored."
        fi
        return 1
    fi

    # Add to Fallback group
    if ! yq -i '(.proxy-groups[] | select(.name == "Fallback") | .proxies) += ["'"${node_name}"'"]' \
        "${MIHOMO_CONFIG}"; then
        log_error "Failed to add node to Fallback group."
        if [[ -n "${BACKUP_RESULT:-}" && -f "${BACKUP_RESULT}" ]]; then
            cp -f "${BACKUP_RESULT}" "${MIHOMO_CONFIG}"
            log_info "Backup restored."
        fi
        return 1
    fi

    # Validate configuration
    if "${MIHOMO_BIN}" -t -d "${MIHOMO_CONFIG_DIR}" &>/dev/null; then
        log_success "Node '${node_name}' added successfully."

        # Reload Mihomo
        if systemctl is-active --quiet "${MIHOMO_SERVICE_NAME}" 2>/dev/null; then
            systemctl reload "${MIHOMO_SERVICE_NAME}" 2>/dev/null || restart_service "${MIHOMO_SERVICE_NAME}"
            log_info "Mihomo reloaded with new node."
        fi
    else
        log_error "Configuration validation failed after adding node!"
        log_error "Restoring backup..."
        if [[ -n "${BACKUP_RESULT:-}" && -f "${BACKUP_RESULT}" ]]; then
            cp -f "${BACKUP_RESULT}" "${MIHOMO_CONFIG}"
            log_info "Backup restored."
        fi
        return 1
    fi
}

# =============================================================================
# 5. test_mihomo
# =============================================================================
# Tests the Mihomo routing engine: service status, port availability,
# proxy connectivity, and routing rule verification.
# =============================================================================
test_mihomo() {
    log_info "============================================"
    log_info "  Testing Mihomo Routing Engine"
    log_info "============================================"

    local pass_count=0
    local fail_count=0
    local total_tests=0

    _test_result() {
        local name="${1}"
        local result="${2}"  # "pass" or "fail"
        local detail="${3:-}"
        ((total_tests++)) || true
        if [[ "${result}" == "pass" ]]; then
            ((pass_count++)) || true
            echo -e "  ${COLOR_GREEN}[PASS]${COLOR_RESET} ${name} ${detail:+-- ${detail}}"
        else
            ((fail_count++)) || true
            echo -e "  ${COLOR_RED}[FAIL]${COLOR_RESET} ${name} ${detail:+-- ${detail}}"
        fi
    }

    # --- Test 1: Binary exists ---
    echo ""
    log_info "Test 1: Mihomo binary"
    if [[ -x "${MIHOMO_BIN}" ]]; then
        local ver
        ver="$("${MIHOMO_BIN}" -v 2>/dev/null | head -1)" || ver="unknown"
        _test_result "Binary exists" "pass" "${ver}"
    else
        _test_result "Binary exists" "fail" "Not found at ${MIHOMO_BIN}"
    fi

    # --- Test 2: Configuration valid ---
    log_info "Test 2: Configuration validation"
    if [[ -f "${MIHOMO_CONFIG}" ]]; then
        if "${MIHOMO_BIN}" -t -d "${MIHOMO_CONFIG_DIR}" &>/dev/null; then
            _test_result "Config valid" "pass"
        else
            _test_result "Config valid" "fail" "Validation error"
        fi
    else
        _test_result "Config valid" "fail" "Config file not found"
    fi

    # --- Test 3: Service status ---
    log_info "Test 3: Service status"
    if systemctl is-active --quiet "${MIHOMO_SERVICE_NAME}" 2>/dev/null; then
        _test_result "Service running" "pass"
    else
        _test_result "Service running" "fail" "$(systemctl is-active "${MIHOMO_SERVICE_NAME}" 2>/dev/null || echo 'not found')"
    fi

    # --- Test 4: Mixed port listening ---
    log_info "Test 4: Port availability"
    if check_port_open "${MIHOMO_MIXED_PORT}"; then
        _test_result "Mixed-port ${MIHOMO_MIXED_PORT}" "pass"
    else
        _test_result "Mixed-port ${MIHOMO_MIXED_PORT}" "fail" "Not listening"
    fi

    # --- Test 5: SOCKS port listening ---
    if check_port_open "${MIHOMO_SOCKS_PORT}"; then
        _test_result "SOCKS-port ${MIHOMO_SOCKS_PORT}" "pass"
    else
        _test_result "SOCKS-port ${MIHOMO_SOCKS_PORT}" "fail" "Not listening"
    fi

    # --- Test 6: API port listening ---
    if check_port_open "${MIHOMO_API_PORT}"; then
        _test_result "API-port ${MIHOMO_API_PORT}" "pass"
    else
        _test_result "API-port ${MIHOMO_API_PORT}" "fail" "Not listening"
    fi

    # --- Test 7: Xray upstream connectivity ---
    log_info "Test 5: Upstream Xray connectivity"
    if check_port_open "${XRAY_UPSTREAM_PORT}"; then
        _test_result "Xray SOCKS5 upstream (${XRAY_UPSTREAM_PORT})" "pass"
    else
        _test_result "Xray SOCKS5 upstream (${XRAY_UPSTREAM_PORT})" "fail" "Xray not running?"
    fi

    # --- Test 8: Proxy connectivity (AI domain via Mihomo) ---
    log_info "Test 6: Proxy connectivity through Mihomo"
    local proxy_url="http://127.0.0.1:${MIHOMO_MIXED_PORT}"

    # Test AI domain (should be proxied)
    local http_code
    http_code="$(curl -s -o /dev/null -w '%{http_code}' --proxy "${proxy_url}" \
        --connect-timeout 15 --max-time 30 "https://api.anthropic.com" 2>/dev/null)" || http_code="000"
    if [[ "${http_code}" != "000" ]]; then
        _test_result "AI domain (api.anthropic.com)" "pass" "HTTP ${http_code}"
    else
        _test_result "AI domain (api.anthropic.com)" "fail" "Connection timeout/refused"
    fi

    # Test blocked domain (should be rejected)
    http_code="$(curl -s -o /dev/null -w '%{http_code}' --proxy "${proxy_url}" \
        --connect-timeout 10 --max-time 15 "https://www.netflix.com" 2>/dev/null)" || http_code="000"
    if [[ "${http_code}" == "000" || "${http_code}" == "502" || "${http_code}" == "503" ]]; then
        _test_result "Blocked domain (netflix.com)" "pass" "Correctly rejected (HTTP ${http_code})"
    else
        _test_result "Blocked domain (netflix.com)" "fail" "Should be blocked but got HTTP ${http_code}"
    fi

    # Test CN domain (should be direct)
    http_code="$(curl -s -o /dev/null -w '%{http_code}' --proxy "${proxy_url}" \
        --connect-timeout 10 --max-time 15 "https://www.baidu.com" 2>/dev/null)" || http_code="000"
    if [[ "${http_code}" != "000" ]]; then
        _test_result "CN domain (baidu.com)" "pass" "HTTP ${http_code} (direct)"
    else
        _test_result "CN domain (baidu.com)" "fail" "Connection failed"
    fi

    # --- Test 9: GeoData files ---
    log_info "Test 7: GeoData files"
    for gf in geoip.metadb geosite.dat country.mmdb; do
        if [[ -f "${MIHOMO_GEODATA_DIR}/${gf}" ]]; then
            local size
            size="$(stat -c %s "${MIHOMO_GEODATA_DIR}/${gf}" 2>/dev/null || echo 0)"
            if [[ ${size} -gt 1000 ]]; then
                _test_result "GeoData: ${gf}" "pass" "$(numfmt --to=iec ${size} 2>/dev/null || echo "${size} bytes")"
            else
                _test_result "GeoData: ${gf}" "fail" "File too small (${size} bytes)"
            fi
        else
            _test_result "GeoData: ${gf}" "fail" "Not found"
        fi
    done

    # --- Summary ---
    echo ""
    echo "==========================================="
    log_info "Test Results: ${pass_count}/${total_tests} passed, ${fail_count} failed"

    if [[ ${fail_count} -eq 0 ]]; then
        log_success "All Mihomo tests passed!"
        return 0
    else
        log_warn "Some tests failed. Check the output above for details."
        return 1
    fi
}

# =============================================================================
# 6. deploy_mihomo
# =============================================================================
# Orchestrator: runs the complete Mihomo deployment sequence.
#   1. Install Mihomo binary + GeoData
#   2. Configure (render config, install rulesets)
#   3. Test
# =============================================================================
deploy_mihomo() {
    log_info "============================================"
    log_info "  Deploying Mihomo Routing Engine"
    log_info "============================================"
    log_info ""
    log_info "Architecture:"
    log_info "  Docker(New API) -> HTTP_PROXY=host.docker.internal:${MIHOMO_MIXED_PORT}"
    log_info "    -> Mihomo(${MIHOMO_MIXED_PORT}) -> routing decisions"
    log_info "      -> Xray(SOCKS5 ${XRAY_UPSTREAM_ADDR}:${XRAY_UPSTREAM_PORT})"
    log_info "        -> VLESS+Reality -> Server B -> Internet"
    log_info ""

    # Step 1: Install binary and geodata
    print_section "Step 1/3: Install Mihomo"
    install_mihomo || { log_error "Mihomo installation failed."; return 1; }

    # Step 2: Configure routing
    print_section "Step 2/3: Configure Routing"
    configure_mihomo || { log_error "Mihomo configuration failed."; return 1; }

    # Step 3: Test
    print_section "Step 3/3: Verify Deployment"
    test_mihomo || log_warn "Some tests failed; deployment may still be functional."

    log_success "============================================"
    log_success "  Mihomo deployment complete!"
    log_success "============================================"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Configure Docker containers with:"
    log_info "     HTTP_PROXY=http://host.docker.internal:${MIHOMO_MIXED_PORT}"
    log_info "     HTTPS_PROXY=http://host.docker.internal:${MIHOMO_MIXED_PORT}"
    log_info "  2. Ensure Xray client is running (SOCKS5 on ${XRAY_UPSTREAM_PORT})"
    log_info "  3. Verify with: test_mihomo"
    log_info ""
}

# =============================================================================
# Main execution (when run directly, not sourced)
# =============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        install)
            require_root
            detect_system
            install_mihomo
            ;;
        configure)
            require_root
            detect_system
            configure_mihomo
            ;;
        rulesets)
            require_root
            generate_mihomo_rulesets
            ;;
        add-node)
            require_root
            add_mihomo_node "${2:-}" "${3:-}" "${4:-}"
            ;;
        test)
            test_mihomo
            ;;
        deploy)
            require_root
            detect_system
            deploy_mihomo
            ;;
        help|--help|-h)
            echo "AI Gateway Bridge - Mihomo Routing Engine"
            echo ""
            echo "Usage:"
            echo "  $0 install     # Install Mihomo binary + GeoData"
            echo "  $0 configure   # Generate config + start service"
            echo "  $0 rulesets    # Regenerate rulesets from whitelist"
            echo "  $0 add-node <name> <addr> <port>  # Add upstream node"
            echo "  $0 test        # Test routing engine"
            echo "  $0 deploy      # Full deployment (install+configure+test)"
            echo "  $0 help        # Show this help"
            ;;
        "")
            # No args -> interactive prompt
            echo ""
            log_info "Mihomo Routing Engine - Select an operation:"
            local options=(
                "Full Deployment (install + configure + test)"
                "Install Mihomo binary only"
                "Configure routing only"
                "Regenerate rulesets"
                "Add upstream node"
                "Test routing"
                "Exit"
            )
            show_menu "Mihomo Operations" options

            case "${MENU_RESULT}" in
                1) require_root; detect_system; deploy_mihomo ;;
                2) require_root; detect_system; install_mihomo ;;
                3) require_root; detect_system; configure_mihomo ;;
                4) require_root; generate_mihomo_rulesets ;;
                5)
                    read -rp "Node name: " _n
                    read -rp "Address: " _a
                    read -rp "Port: " _p
                    require_root
                    add_mihomo_node "${_n}" "${_a}" "${_p}"
                    ;;
                6) test_mihomo ;;
                7) exit 0 ;;
            esac
            ;;
        *)
            log_error "Unknown command: $1"
            echo "Run '$0 help' for usage information."
            exit 1
            ;;
    esac
fi
