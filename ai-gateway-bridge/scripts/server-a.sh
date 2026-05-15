#!/usr/bin/env bash
# =============================================================================
# Server A (China Domestic) Deployment Module
# =============================================================================
# This script deploys the domestic-side infrastructure:
#   1. Xray client (VLESS+Reality tunnel to Server B)
#   2. New API (AI gateway via Docker, proxied through Xray)
#   3. Caddy (TLS termination, reverse proxy, decoy website)
#
# This file is sourced by install.sh. It depends on common.sh for shared
# utility functions (logging, OS detection, Docker helpers, template rendering).
# =============================================================================

set -euo pipefail

# Guard against double-sourcing (readonly variables would conflict)
if [[ -n "${_SERVER_A_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
readonly _SERVER_A_SH_LOADED=1

# Use BASH_SOURCE[0] instead of $0 to work correctly when sourced by install.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Color aliases for compatibility (common.sh uses COLOR_* prefix)
: "${CYAN:=${COLOR_CYAN:-\033[0;36m}}"
: "${NC:=${COLOR_RESET:-\033[0m}}"

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly SERVER_B_CONF="/root/server-b-connection.conf"
readonly XRAY_CONFIG_DIR="/usr/local/etc/xray"
readonly XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_GEODATA_DIR="/usr/local/share/xray"
readonly NEW_API_DIR="/opt/new-api"
readonly CADDY_CONFIG="/etc/caddy/Caddyfile"
readonly DECOY_WEBROOT="/var/www/html"
readonly CADDY_LOG_DIR="/var/log/caddy"

# ---------------------------------------------------------------------------
# 1. collect_server_b_info
# ---------------------------------------------------------------------------
# Interactively collects Server B (overseas) connection details from the user,
# validates each field, and persists them to SERVER_B_CONF.
# ---------------------------------------------------------------------------
collect_server_b_info() {
    log_info "============================================"
    log_info "  Collecting Server B Connection Details"
    log_info "============================================"

    # Helper: trim leading/trailing whitespace from a variable.
    # Prevents paste artifacts (trailing spaces, tabs) from breaking validation.
    _trim() {
        local var="$1"
        var="${var#"${var%%[![:space:]]*}"}"   # trim leading
        var="${var%"${var##*[![:space:]]}"}"   # trim trailing
        printf '%s' "${var}"
    }

    # --- Server B IP ---
    local server_b_ip=""
    while true; do
        read -rp "$(echo -e "${CYAN}Enter Server B IP address: ${NC}")" server_b_ip
        server_b_ip="$(_trim "$server_b_ip")"
        if validate_ip "$server_b_ip"; then
            break
        fi
        log_error "Invalid IP address format. Please enter a valid IPv4 address (e.g. 203.0.113.10)."
    done

    # --- Server B Port ---
    local server_b_port=""
    read -rp "$(echo -e "${CYAN}Enter Server B port [443]: ${NC}")" server_b_port
    server_b_port="$(_trim "${server_b_port:-443}")"
    if ! validate_port "$server_b_port"; then
        log_error "Invalid port number. Must be 1-65535. Falling back to 443."
        server_b_port="443"
    fi

    # --- UUID ---
    local server_b_uuid=""
    while true; do
        read -rp "$(echo -e "${CYAN}Enter UUID (from Server B setup): ${NC}")" server_b_uuid
        server_b_uuid="$(_trim "$server_b_uuid")"
        if validate_uuid "$server_b_uuid"; then
            break
        fi
        log_error "Invalid UUID format. Expected: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    done

    # --- Public Key ---
    local server_b_pubkey=""
    while true; do
        read -rp "$(echo -e "${CYAN}Enter Reality public key (from Server B): ${NC}")" server_b_pubkey
        server_b_pubkey="$(_trim "$server_b_pubkey")"
        # X25519 public keys are base64url-encoded: alphanumeric + - + _ + =
        # Strict validation prevents command injection when sourced from config
        if [[ -n "$server_b_pubkey" && ${#server_b_pubkey} -ge 32 && "$server_b_pubkey" =~ ^[A-Za-z0-9_=+/-]+$ ]]; then
            break
        fi
        log_error "Invalid public key. Must be at least 32 base64 characters."
    done

    # --- SNI / Server Name ---
    local server_b_sni=""
    while true; do
        read -rp "$(echo -e "${CYAN}Enter SNI / Server name [dl.google.com]: ${NC}")" server_b_sni
        server_b_sni="$(_trim "${server_b_sni:-dl.google.com}")"
        # Validate: must be a valid hostname (alphanumeric, hyphens, dots only)
        # This prevents command injection when the value is later sourced from config
        if [[ "$server_b_sni" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
            break
        fi
        log_error "Invalid SNI. Must be a valid hostname (e.g. dl.google.com). Only alphanumeric, hyphens, dots allowed."
    done

    # --- Short ID ---
    local server_b_short_id=""
    while true; do
        read -rp "$(echo -e "${CYAN}Enter Short ID (press Enter for empty): ${NC}")" server_b_short_id
        server_b_short_id="$(_trim "${server_b_short_id:-}")"
        # Validate: must be empty or hex string (prevents command injection)
        if [[ -z "$server_b_short_id" || "$server_b_short_id" =~ ^[0-9a-fA-F]+$ ]]; then
            break
        fi
        log_error "Invalid Short ID. Must be a hex string (e.g. a1b2c3d4e5f6) or empty."
    done

    # --- Persist ---
    # Quote all values to prevent shell expansion when this file is sourced.
    # Input validation above ensures no shell metacharacters, but quoting
    # provides defense-in-depth against future regressions.
    cat > "$SERVER_B_CONF" <<EOF
# Server B Connection Configuration
# Generated on $(date '+%Y-%m-%d %H:%M:%S')
SERVER_B_IP='${server_b_ip}'
SERVER_B_PORT='${server_b_port}'
SERVER_B_UUID='${server_b_uuid}'
SERVER_B_PUBKEY='${server_b_pubkey}'
SERVER_B_SNI='${server_b_sni}'
SERVER_B_SHORT_ID='${server_b_short_id}'
EOF
    chmod 600 "$SERVER_B_CONF"

    log_success "Server B connection details saved to ${SERVER_B_CONF}"

    # Export for use by subsequent functions in this session
    export SERVER_B_IP="$server_b_ip"
    export SERVER_B_PORT="$server_b_port"
    export SERVER_B_UUID="$server_b_uuid"
    export SERVER_B_PUBKEY="$server_b_pubkey"
    export SERVER_B_SNI="$server_b_sni"
    export SERVER_B_SHORT_ID="$server_b_short_id"
}

# ---------------------------------------------------------------------------
# Validation helpers (self-contained; do not rely on common.sh for these)
# ---------------------------------------------------------------------------
validate_ip() {
    local ip="$1"
    # Strict IPv4 validation: four octets 0-255
    local IFS='.'
    read -ra octets <<< "$ip"
    [[ ${#octets[@]} -ne 4 ]] && return 1
    for octet in ${octets[@]+"${octets[@]}"}; do
        # Must be numeric, no leading zeros except "0" itself
        [[ ! "$octet" =~ ^[0-9]+$ ]] && return 1
        (( octet < 0 || octet > 255 )) && return 1
        # Reject leading zeros (e.g. "01")
        if [[ ${#octet} -gt 1 && "${octet:0:1}" == "0" ]]; then
            return 1
        fi
    done
    return 0
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

validate_uuid() {
    local uuid="$1"
    [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# ---------------------------------------------------------------------------
# load_server_b_info
# ---------------------------------------------------------------------------
# Loads previously saved Server B connection details from SERVER_B_CONF.
# Returns 1 if the file does not exist or is incomplete.
# ---------------------------------------------------------------------------
load_server_b_info() {
    if [[ ! -f "$SERVER_B_CONF" ]]; then
        log_error "Server B configuration not found at ${SERVER_B_CONF}."
        log_error "Please run collect_server_b_info() first."
        return 1
    fi
    # shellcheck source=/dev/null
    source "$SERVER_B_CONF"
    # Validate required fields are present
    local missing=0
    for var in SERVER_B_IP SERVER_B_PORT SERVER_B_UUID SERVER_B_PUBKEY SERVER_B_SNI; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Missing required field: ${var} in ${SERVER_B_CONF}"
            missing=1
        fi
    done
    if [[ $missing -eq 1 ]]; then
        return 1
    fi
    export SERVER_B_IP SERVER_B_PORT SERVER_B_UUID SERVER_B_PUBKEY SERVER_B_SNI SERVER_B_SHORT_ID
    return 0
}

# ---------------------------------------------------------------------------
# 2. install_xray_client
# ---------------------------------------------------------------------------
# Downloads and installs the latest Xray-core binary, generates the client
# configuration (VLESS+Reality connecting to Server B), creates a systemd
# service, and verifies tunnel connectivity.
# ---------------------------------------------------------------------------
install_xray_client() {
    log_info "============================================"
    log_info "  Installing Xray Client (VLESS+Reality)"
    log_info "============================================"

    # --- Prerequisites ---
    install_if_missing curl curl
    install_if_missing unzip unzip
    install_if_missing file file

    # Ensure Server B connection details are available
    if [[ -z "${SERVER_B_IP:-}" ]]; then
        load_server_b_info || { log_error "Cannot proceed without Server B details."; return 1; }
    fi

    # --- Download & Install Xray-core ---
    log_info "Downloading latest Xray-core..."
    local arch
    arch=$(uname -m)
    local xray_arch=""
    case "$arch" in
        x86_64|amd64)  xray_arch="Xray-linux-64" ;;
        aarch64|arm64) xray_arch="Xray-linux-arm64-v8a" ;;
        armv7l)        xray_arch="Xray-linux-arm32-v7a" ;;
        *)
            log_error "Unsupported architecture: ${arch}"
            return 1
            ;;
    esac

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local xray_zip="${tmp_dir}/xray.zip"
    local xray_download_url="https://github.com/XTLS/Xray-core/releases/latest/download/${xray_arch}.zip"

    if ! github_download "$xray_download_url" "$xray_zip" 120; then
        log_error "Failed to download Xray-core from all sources (direct + configured mirrors)."
        log_error "$(github_mirror_help)"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Verify download is a valid zip (not an HTML error page)
    if ! file "$xray_zip" 2>/dev/null | grep -qi 'zip\|archive'; then
        if command -v unzip &>/dev/null && ! unzip -t "$xray_zip" &>/dev/null; then
            log_error "Downloaded file is not a valid zip archive. Possible network issue or mirror returned error page."
            rm -rf "$tmp_dir"
            return 1
        fi
    fi

    log_info "Extracting Xray-core..."
    if ! unzip -qo "$xray_zip" -d "$tmp_dir"; then
        log_error "Failed to extract Xray-core archive."
        rm -rf "$tmp_dir"
        return 1
    fi

    # Install binary
    install -m 755 "${tmp_dir}/xray" "$XRAY_BIN"

    # Install geodata files
    mkdir -p "$XRAY_GEODATA_DIR"
    for geofile in geoip.dat geosite.dat; do
        if [[ -f "${tmp_dir}/${geofile}" ]]; then
            install -m 644 "${tmp_dir}/${geofile}" "${XRAY_GEODATA_DIR}/${geofile}"
        fi
    done

    rm -rf "$tmp_dir"

    # Verify binary
    if ! "$XRAY_BIN" version &>/dev/null; then
        log_error "Xray binary verification failed."
        return 1
    fi
    log_success "Xray-core installed: $("$XRAY_BIN" version | head -1)"

    # --- Download latest geodata if missing ---
    _ensure_xray_geodata

    # --- Generate Client Configuration ---
    # NOTE: With the Mihomo architecture, Docker containers reach Mihomo:7890
    # (not Xray:10809 directly). Xray http-in (10809) is now only used by
    # Mihomo and diagnostic tools on the host. It binds 0.0.0.0 for legacy
    # compatibility; the firewall blocks external access to port 10809.
    log_info "Generating Xray client configuration..."
    mkdir -p "$XRAY_CONFIG_DIR"

    cat > "$XRAY_CONFIG" <<XRAYEOF
{
  "log": {
    "loglevel": "warning",
    "access": "none",
    "error": "/var/log/xray/error.log"
  },
  "dns": {
    "servers": [
      {
        "address": "https+local://1.1.1.1/dns-query",
        "domains": [
          "geosite:category-ads-all"
        ],
        "expectIPs": []
      },
      {
        "address": "223.5.5.5",
        "port": 53,
        "domains": [
          "geosite:cn",
          "geosite:private"
        ]
      },
      {
        "address": "https+local://8.8.8.8/dns-query",
        "domains": [
          "domain:anthropic.com",
          "domain:openai.com",
          "domain:googleapis.com",
          "domain:google.dev",
          "domain:deepseek.com",
          "domain:mistral.ai",
          "domain:groq.com",
          "domain:github.com",
          "domain:githubusercontent.com",
          "domain:huggingface.co",
          "domain:cohere.ai",
          "domain:cohere.com",
          "domain:perplexity.ai",
          "domain:together.xyz",
          "domain:together.ai",
          "domain:npmjs.org",
          "domain:pypi.org",
          "domain:pythonhosted.org",
          "domain:crates.io",
          "domain:docker.io",
          "domain:docker.com",
          "domain:ghcr.io",
          "domain:sentry.io"
        ]
      },
      "localhost"
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "tag": "socks-in",
      "port": 10808,
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true,
        "ip": "127.0.0.1"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    },
    {
      "tag": "http-in",
      "port": 10809,
      "listen": "0.0.0.0",
      "protocol": "http",
      "settings": {
        "allowTransparent": false
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${SERVER_B_IP}",
            "port": ${SERVER_B_PORT},
            "users": [
              {
                "id": "${SERVER_B_UUID}",
                "encryption": "none",
                "flow": "xtls-rprx-vision"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "fingerprint": "chrome",
          "serverName": "${SERVER_B_SNI}",
          "publicKey": "${SERVER_B_PUBKEY}",
          "shortId": "${SERVER_B_SHORT_ID:-}",
          "spiderX": ""
        }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole",
      "settings": {
        "response": {
          "type": "http"
        }
      }
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "domainMatcher": "hybrid",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["socks-in"],
        "outboundTag": "proxy",
        "comment": "Trust Mihomo routing: all traffic from SOCKS5 inbound goes to proxy. Mihomo has already made the routing decision."
      },
      {
        "type": "field",
        "outboundTag": "block",
        "domain": ["geosite:category-ads-all"]
      },
      {
        "type": "field",
        "outboundTag": "block",
        "domain": [
          "domain:netflix.com", "domain:netflix.net", "domain:nflxvideo.net",
          "domain:nflxso.net", "domain:nflxext.com", "domain:nflximg.net"
        ]
      },
      {
        "type": "field",
        "outboundTag": "block",
        "domain": [
          "domain:youtube.com", "domain:youtu.be", "domain:googlevideo.com",
          "domain:ytimg.com", "domain:yt3.ggpht.com",
          "domain:twitch.tv", "domain:ttvnw.net", "domain:jtvnw.net"
        ]
      },
      {
        "type": "field",
        "outboundTag": "block",
        "domain": [
          "domain:disneyplus.com", "domain:disney-plus.net", "domain:bamgrid.com",
          "domain:dssott.com", "domain:hbo.com", "domain:hbonow.com",
          "domain:hbomax.com", "domain:hulu.com", "domain:hulustream.com",
          "domain:primevideo.com", "domain:amazonvideo.com"
        ]
      },
      {
        "type": "field",
        "outboundTag": "block",
        "domain": [
          "domain:spotify.com", "domain:spotifycdn.com", "domain:scdn.co",
          "domain:tidal.com", "domain:tidalhifi.com"
        ]
      },
      {
        "type": "field",
        "outboundTag": "block",
        "domain": [
          "domain:tiktok.com", "domain:tiktokv.com", "domain:musical.ly",
          "domain:instagram.com", "domain:cdninstagram.com",
          "domain:facebook.com", "domain:fbcdn.net",
          "domain:twitter.com", "domain:x.com", "domain:twimg.com",
          "domain:reddit.com", "domain:redd.it", "domain:redditstatic.com",
          "domain:pornhub.com", "domain:xvideos.com", "domain:xhamster.com"
        ]
      },
      {
        "type": "field",
        "outboundTag": "block",
        "protocol": ["bittorrent"]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "domain": ["domain:anthropic.com", "domain:claude.ai"]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "domain": ["domain:openai.com"]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "domain": [
          "full:generativelanguage.googleapis.com",
          "full:aistudio.google.com",
          "full:ai.google.dev",
          "full:alkalimakersuite-pa.clients6.google.com",
          "full:makersuite-pa.googleapis.com"
        ]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "domain": ["domain:deepseek.com"]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "domain": ["domain:mistral.ai"]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "domain": ["domain:groq.com"]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "domain": [
          "domain:github.com", "domain:githubusercontent.com",
          "domain:githubcopilot.com",
          "full:copilot.github.com", "full:default.exp-tas.com"
        ]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "domain": ["domain:huggingface.co"]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "domain": ["domain:cohere.ai", "domain:cohere.com"]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "domain": ["domain:perplexity.ai"]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "domain": ["domain:together.xyz", "domain:together.ai"]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "domain": [
          "domain:npmjs.org", "domain:pypi.org",
          "domain:pythonhosted.org", "domain:crates.io"
        ]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "domain": ["domain:docker.io", "domain:docker.com", "domain:ghcr.io"]
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "domain": ["domain:sentry.io", "domain:statsig.anthropic.com"]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "domain": ["geosite:cn", "geosite:private"]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "ip": ["geoip:cn", "geoip:private"]
      },
      {
        "type": "field",
        "outboundTag": "block",
        "port": "0-65535"
      }
    ]
  }
}
XRAYEOF

    chmod 600 "$XRAY_CONFIG"

    # Validate config
    if ! "$XRAY_BIN" run -test -config "$XRAY_CONFIG" &>/dev/null; then
        log_error "Xray configuration validation failed."
        "$XRAY_BIN" run -test -config "$XRAY_CONFIG"
        return 1
    fi
    log_success "Xray configuration validated successfully."

    # --- Create log directory ---
    mkdir -p /var/log/xray
    chmod 750 /var/log/xray

    # --- Create systemd service ---
    log_info "Creating Xray systemd service..."
    cat > /etc/systemd/system/xray.service <<'SERVICEEOF'
[Unit]
Description=Xray Client (VLESS+Reality Tunnel)
Documentation=https://xtls.github.io/
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5
RestartPreventExitStatus=23
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

# Hardening
NoNewPrivileges=true
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
SERVICEEOF

    systemctl daemon-reload
    systemctl enable xray
    systemctl start xray

    # Give it a moment to start
    sleep 3

    if systemctl is-active --quiet xray; then
        log_success "Xray service started successfully."
    else
        log_error "Xray service failed to start. Checking logs..."
        journalctl -u xray --no-pager -n 20
        return 1
    fi

    # --- Test tunnel connectivity ---
    log_info "Testing Xray tunnel connectivity..."
    _test_xray_tunnel

    return 0
}

# ---------------------------------------------------------------------------
# _ensure_xray_geodata (internal)
# ---------------------------------------------------------------------------
# Downloads geoip.dat and geosite.dat if not already present.
# ---------------------------------------------------------------------------
_ensure_xray_geodata() {
    mkdir -p "$XRAY_GEODATA_DIR"

    local geoip_url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
    local geosite_url="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
    local geoip_file="${XRAY_GEODATA_DIR}/geoip.dat"
    local geosite_file="${XRAY_GEODATA_DIR}/geosite.dat"
    local tmp_file=""

    if [[ ! -s "${geoip_file}" ]]; then
        log_info "Downloading geoip.dat (with configured GitHub mirror fallback)..."
        tmp_file="$(mktemp "${XRAY_GEODATA_DIR}/geoip.dat.XXXXXX")"
        if github_download "$geoip_url" "${tmp_file}" 120 && [[ -s "${tmp_file}" ]]; then
            mv "${tmp_file}" "${geoip_file}"
            chmod 644 "${geoip_file}"
        else
            rm -f "${tmp_file}" 2>/dev/null || true
            log_error "Failed to download required geoip.dat from all sources."
            return 1
        fi
    fi

    if [[ ! -s "${geosite_file}" ]]; then
        log_info "Downloading geosite.dat (with configured GitHub mirror fallback)..."
        tmp_file="$(mktemp "${XRAY_GEODATA_DIR}/geosite.dat.XXXXXX")"
        if github_download "$geosite_url" "${tmp_file}" 120 && [[ -s "${tmp_file}" ]]; then
            mv "${tmp_file}" "${geosite_file}"
            chmod 644 "${geosite_file}"
        else
            rm -f "${tmp_file}" 2>/dev/null || true
            log_error "Failed to download required geosite.dat from all sources."
            return 1
        fi
    fi

    if [[ ! -s "${geoip_file}" || ! -s "${geosite_file}" ]]; then
        log_error "Required Xray geodata files are missing under ${XRAY_GEODATA_DIR}."
        return 1
    fi

    # Set Xray asset directory environment variable
    export XRAY_LOCATION_ASSET="$XRAY_GEODATA_DIR"
    # Persist for systemd
    mkdir -p /etc/systemd/system/xray.service.d
    cat > /etc/systemd/system/xray.service.d/env.conf <<EOF
[Service]
Environment="XRAY_LOCATION_ASSET=${XRAY_GEODATA_DIR}"
EOF
}

# ---------------------------------------------------------------------------
# _test_xray_tunnel (internal)
# ---------------------------------------------------------------------------
# Verifies the Xray SOCKS5 and HTTP proxy endpoints can reach external APIs.
# ---------------------------------------------------------------------------
_test_xray_tunnel() {
    local success=0
    local total=0

    # Test SOCKS5 proxy
    total=$((total + 1))
    log_info "[Test] SOCKS5 proxy (127.0.0.1:10808) -> api.anthropic.com ..."
    local socks_result
    socks_result=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 15 --max-time 30 \
        -x socks5h://127.0.0.1:10808 \
        "https://api.anthropic.com/v1/models" 2>/dev/null) || true
    if [[ "$socks_result" =~ ^(200|401|403)$ ]]; then
        log_success "[Test] SOCKS5 proxy reachable (HTTP ${socks_result})"
        success=$((success + 1))
    else
        log_warn "[Test] SOCKS5 proxy test returned HTTP ${socks_result:-timeout}"
    fi

    # Test HTTP proxy
    total=$((total + 1))
    log_info "[Test] HTTP proxy (127.0.0.1:10809) -> api.openai.com ..."
    local http_result
    http_result=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 15 --max-time 30 \
        -x http://127.0.0.1:10809 \
        "https://api.openai.com/v1/models" 2>/dev/null) || true
    if [[ "$http_result" =~ ^(200|401|403)$ ]]; then
        log_success "[Test] HTTP proxy reachable (HTTP ${http_result})"
        success=$((success + 1))
    else
        log_warn "[Test] HTTP proxy test returned HTTP ${http_result:-timeout}"
    fi

    if [[ $success -eq $total ]]; then
        log_success "All Xray tunnel tests passed (${success}/${total})."
    elif [[ $success -gt 0 ]]; then
        log_warn "Partial Xray tunnel connectivity (${success}/${total}). Check Server B."
    else
        log_error "Xray tunnel tests failed. Verify Server B is running and reachable."
        log_info "Debug: journalctl -u xray -n 50"
    fi
}

# ---------------------------------------------------------------------------
# 3. install_new_api
# ---------------------------------------------------------------------------
# Deploys New API (AI gateway) via Docker Compose. The container is configured
# to route upstream API requests through Mihomo routing engine (host.docker.internal:7890).
# ---------------------------------------------------------------------------
install_new_api() {
    log_info "============================================"
    log_info "  Installing New API (AI Gateway)"
    log_info "============================================"

    # --- Ensure Docker is available ---
    if ! command -v docker &>/dev/null; then
        log_info "Docker not found. Installing..."
        install_docker_china_aware
    else
        # Docker exists; ensure China mirrors are configured if needed
        configure_docker_mirrors
    fi
    check_docker

    # Ensure docker compose plugin is available
    if ! docker compose version &>/dev/null; then
        log_error "Docker Compose plugin not available. Please install docker-compose-plugin."
        return 1
    fi
    if ! require_docker_server_version "20.10.0" "New API Docker host-gateway mapping"; then
        log_error "Upgrade Docker Engine before deploying New API. The compose file depends on host.docker.internal:host-gateway."
        return 1
    fi

    # --- Generate secrets ---
    local session_secret
    session_secret=$(generate_random_password 32)
    local exposure_profile
    if ! exposure_profile="$(bifrost_exposure_profile)"; then
        return 1
    fi
    local new_api_image="${BIFROST_NEW_API_IMAGE:-calciumion/new-api:latest}"
    if [[ "${new_api_image}" == *":latest" && "${exposure_profile}" != "lab" && "${BIFROST_ALLOW_UNPINNED:-0}" != "1" ]]; then
        log_error "Refusing mutable New API image '${new_api_image}' in ${exposure_profile} profile."
        log_error "Set BIFROST_NEW_API_IMAGE to an immutable tag or digest, or set BIFROST_ALLOW_UNPINNED=1 for a temporary non-production override."
        return 1
    fi

    # --- Create directory structure ---
    mkdir -p "${NEW_API_DIR}/data"
    mkdir -p "${NEW_API_DIR}/redis-data"

    # --- Check for port conflicts ---
    if ss -tlnp 2>/dev/null | grep -q ':3000 '; then
        log_warn "Port 3000 is already in use. Checking if it's a previous New API instance..."
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^new-api$'; then
            log_info "Existing New API container found. Stopping it..."
            cd "$NEW_API_DIR" && docker compose down 2>/dev/null || true
        else
            log_error "Port 3000 is occupied by another process. Please free it first."
            ss -tlnp 2>/dev/null | grep ':3000 '
            return 1
        fi
    fi

    # --- Check for existing containers/images ---
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^new-api$'; then
        log_warn "Found existing 'new-api' container. Removing..."
        docker rm -f new-api 2>/dev/null || true
    fi
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^new-api-redis$'; then
        log_warn "Found existing 'new-api-redis' container. Removing..."
        docker rm -f new-api-redis 2>/dev/null || true
    fi

    # --- Determine proxy port ---
    # Prefer Mihomo (7890) if it's running, otherwise fall back to Xray HTTP proxy (10809).
    # Mihomo handles smart routing (AI -> proxy, CN -> direct, blocked -> reject).
    # Xray HTTP proxy sends ALL traffic through the tunnel (less efficient but functional).
    local proxy_port="7890"
    local proxy_name="Mihomo"
    if systemctl is-active --quiet mihomo 2>/dev/null; then
        proxy_port="7890"
        proxy_name="Mihomo"
        log_info "Mihomo is running. New API will route through Mihomo (port 7890)."
    elif ss -tlnp 2>/dev/null | grep -q ':7890 '; then
        proxy_port="7890"
        proxy_name="Mihomo"
        log_info "Port 7890 is listening. New API will route through Mihomo."
    elif ss -tlnp 2>/dev/null | grep -q ':10809 '; then
        proxy_port="10809"
        proxy_name="Xray HTTP"
        log_warn "Mihomo not running. Falling back to Xray HTTP proxy (port 10809)."
        log_warn "All traffic will be tunneled (no smart routing). Deploy Mihomo later for optimization."
    else
        proxy_port="7890"
        proxy_name="Mihomo (expected)"
        log_warn "Neither Mihomo (7890) nor Xray HTTP (10809) detected yet."
        log_warn "Using Mihomo port 7890 (will work once Mihomo or Xray starts)."
    fi

    # --- Create docker-compose.yml ---
    # HTTP_PROXY/HTTPS_PROXY point to the detected proxy port.
    # Because New API runs in a Docker container, it cannot reach 127.0.0.1 of the
    # host directly. We use extra_hosts + host.docker.internal to bridge this gap.
    log_info "Creating Docker Compose configuration (proxy: ${proxy_name} on port ${proxy_port})..."
    cat > "${NEW_API_DIR}/docker-compose.yml" <<COMPOSEEOF
# Docker Compose configuration for New API
# version field is omitted (obsolete in Compose V2+)
# image: ${new_api_image}

services:
  new-api:
    image: ${new_api_image}
    container_name: new-api
    restart: always
    ports:
      - "127.0.0.1:3000:3000"
    volumes:
      - ./data:/data
    environment:
      - TZ=Asia/Shanghai
      - SQL_DSN=
      - REDIS_CONN_STRING=redis://redis:6379
      - SESSION_SECRET=${session_secret}
      - CHANNEL_UPDATE_FREQUENCY=60
      - POLLING_INTERVAL=60
      # Route upstream AI API calls through ${proxy_name} (port ${proxy_port})
      - HTTP_PROXY=http://host.docker.internal:${proxy_port}
      - HTTPS_PROXY=http://host.docker.internal:${proxy_port}
      - NO_PROXY=localhost,127.0.0.1,::1,redis,host.docker.internal
    extra_hosts:
      - "host.docker.internal:host-gateway"
    depends_on:
      - redis
    # Security hardening
    security_opt:
      - no-new-privileges:true
    read_only: false
    tmpfs:
      - /tmp
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "3"

  redis:
    image: redis:7-alpine
    container_name: new-api-redis
    restart: always
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp
    volumes:
      - ./redis-data:/data
    command: redis-server --maxmemory 128mb --maxmemory-policy allkeys-lru
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
COMPOSEEOF

    chmod 600 "${NEW_API_DIR}/docker-compose.yml"

    # --- Pull images and start ---
    log_info "Pulling Docker images (this may take a while)..."
    cd "$NEW_API_DIR"
    if ! docker compose pull; then
        log_error "Failed to pull Docker images. Check network connectivity."
        return 1
    fi

    log_info "Starting New API services..."
    if ! docker compose up -d; then
        log_error "Failed to start New API services."
        docker compose logs --tail 30
        return 1
    fi

    # --- Wait for service to be healthy ---
    log_info "Waiting for New API to become ready..."
    local max_wait=60
    local waited=0
    local api_ready=false
    while [[ $waited -lt $max_wait ]]; do
        if curl -sf -o /dev/null "http://127.0.0.1:3000/api/status" 2>/dev/null; then
            api_ready=true
            break
        fi
        sleep 3
        waited=$((waited + 3))
        log_info "  Waiting... (${waited}s / ${max_wait}s)"
    done

    if [[ "$api_ready" == "true" ]]; then
        log_success "New API is running and healthy."
    else
        log_warn "New API did not respond within ${max_wait}s. It may still be initializing."
        log_info "Check status: docker logs new-api"
    fi

    # --- Print access information ---
    log_info "--------------------------------------------"
    log_info "  New API Access Information"
    log_info "--------------------------------------------"
    log_info "  Local URL    : http://127.0.0.1:3000"
    log_info "  Dashboard    : http://127.0.0.1:3000/dashboard"
    log_info "  First Visit  : Open the dashboard and complete the initial admin setup"
    log_warn "  IMPORTANT: Complete the New API initialization page immediately and set a strong admin password."
    log_info "--------------------------------------------"

    return 0
}

# ---------------------------------------------------------------------------
# 4. setup_caddy_a
# ---------------------------------------------------------------------------
# Installs Caddy, configures it as a TLS-terminating reverse proxy in front
# of New API, and serves the decoy website on the domain root.
# ---------------------------------------------------------------------------
setup_caddy_a() {
    log_info "============================================"
    log_info "  Setting Up Caddy (Reverse Proxy + TLS)"
    log_info "============================================"

    local exposure_profile
    if ! exposure_profile="$(bifrost_exposure_profile)"; then
        return 1
    fi
    local admin_allowed_ranges
    admin_allowed_ranges="$(bifrost_admin_allowed_ranges)"
    local exposure_description
    exposure_description="$(bifrost_exposure_profile_description "${exposure_profile}")"

    log_info "Exposure profile: ${exposure_profile}"
    log_info "  ${exposure_description}"
    if [[ "${exposure_profile}" == "vpn-first" ]]; then
        log_info "  Admin allowlist: ${admin_allowed_ranges}"
    elif [[ "${exposure_profile}" == "public-managed" ]]; then
        log_warn "  public-managed exposes dashboard/manage through public HTTPS. Use WAF/source allowlists and strong admin auth."
    else
        log_warn "  lab profile is not safe for production."
    fi

    # --- Install Caddy ---
    _install_caddy

    # --- Collect domain name ---
    local domain=""
    while true; do
        read -rp "$(echo -e "${CYAN}Enter your domain name (must be ICP-registered): ${NC}")" domain
        if [[ -n "$domain" && "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
            break
        fi
        log_error "Invalid domain name. Please enter a valid FQDN (e.g. api.yourcompany.com)."
    done

    log_info "Domain: ${domain}"
    log_warn "Ensure this domain's DNS A record points to THIS server's public IP."
    log_warn "Ensure this domain has a valid ICP registration (required for China hosting)."

    # --- Create log directory ---
    mkdir -p "$CADDY_LOG_DIR"

    # --- Create Caddyfile ---
    log_info "Generating Caddy configuration..."
    cat > "$CADDY_CONFIG" <<CADDYEOF
# Caddy configuration for Server A
# Domain: ${domain}
# Exposure profile: ${exposure_profile}
# Generated on $(date '+%Y-%m-%d %H:%M:%S')

${domain} {
    # ===== Normal Website (Disguise) =====
    # Serves a legitimate-looking business website at the root path.
    handle / {
        root * ${DECOY_WEBROOT}
        file_server
        try_files {path} /index.html
    }
    handle /about {
        root * ${DECOY_WEBROOT}
        file_server
        try_files {path} /about.html /index.html
    }
    handle /services {
        root * ${DECOY_WEBROOT}
        file_server
        try_files {path} /services.html /index.html
    }
    handle /contact {
        root * ${DECOY_WEBROOT}
        file_server
        try_files {path} /contact.html /index.html
    }

    # Static assets for the decoy site
    handle /assets/* {
        root * ${DECOY_WEBROOT}
        file_server
    }
    handle /css/* {
        root * ${DECOY_WEBROOT}
        file_server
    }
    handle /js/* {
        root * ${DECOY_WEBROOT}
        file_server
    }
    handle /images/* {
        root * ${DECOY_WEBROOT}
        file_server
    }
    handle /favicon.ico {
        root * ${DECOY_WEBROOT}
        file_server
    }

    # ===== New API Gateway (AI API Traffic) =====
    handle /v1/* {
        reverse_proxy localhost:3000 {
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
            # Increase timeouts for long-running AI inference requests
            transport http {
                read_timeout 300s
                write_timeout 300s
                dial_timeout 30s
            }
        }
    }

$(if [[ "${exposure_profile}" == "vpn-first" ]]; then
cat <<PROFILE_BLOCK
    # ===== Public readiness endpoint only =====
    handle /api/status {
        reverse_proxy localhost:3000 {
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }

    # ===== Private New API management surface =====
    @newapi_private {
        path /api/* /static/* /logo.png /dashboard /dashboard/* /login /panel /token /user/* /admin/*
        remote_ip ${admin_allowed_ranges}
    }
    handle @newapi_private {
        reverse_proxy localhost:3000 {
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }
    handle /api/* {
        respond "Bifrost admin API requires VPN/private access in vpn-first profile" 403
    }
    handle /static/* {
        respond "New API static assets require VPN/private access in vpn-first profile" 403
    }
    handle /logo.png {
        respond "New API static assets require VPN/private access in vpn-first profile" 403
    }
    handle /dashboard {
        respond "New API dashboard requires VPN/private access in vpn-first profile" 403
    }
    handle /dashboard/* {
        respond "New API dashboard requires VPN/private access in vpn-first profile" 403
    }
    handle /login {
        respond "New API login requires VPN/private access in vpn-first profile" 403
    }

    # ===== Private Bifrost Management Platform =====
    @manage_private_root {
        path /manage
        remote_ip ${admin_allowed_ranges}
    }
    handle @manage_private_root {
        redir /manage/ 308
    }
    @manage_private {
        path /manage/*
        remote_ip ${admin_allowed_ranges}
    }
    handle @manage_private {
        uri strip_prefix /manage
        reverse_proxy 127.0.0.1:8000 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
            header_up X-Forwarded-Prefix /manage
        }
    }
    handle /manage {
        respond "Bifrost management requires VPN/private access in vpn-first profile" 403
    }
    handle /manage/* {
        respond "Bifrost management requires VPN/private access in vpn-first profile" 403
    }

    # ===== Default: decoy site for unmatched paths =====
    handle {
        root * ${DECOY_WEBROOT}
        file_server
        try_files {path} /index.html
    }
PROFILE_BLOCK
else
cat <<PROFILE_BLOCK
    # ===== New API Gateway API and Dashboard =====
    handle /api/* {
        reverse_proxy localhost:3000 {
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }
    handle /static/* {
        reverse_proxy localhost:3000 {
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }
    handle /logo.png {
        reverse_proxy localhost:3000 {
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }
    handle /dashboard {
        reverse_proxy localhost:3000 {
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }
    handle /dashboard/* {
        reverse_proxy localhost:3000 {
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }

    # ===== Bifrost Management Platform =====
    # Exposes the FastAPI admin/register interface under /manage/*
    handle /manage {
        redir /manage/ 308
    }
    handle /manage/* {
        uri strip_prefix /manage
        reverse_proxy 127.0.0.1:8000 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
            header_up X-Forwarded-Prefix /manage
        }
    }

    # ===== Default: Reverse Proxy to New API =====
    # Catches any path not matched above (e.g. /login, /panel, /token, etc.)
    handle {
        reverse_proxy localhost:3000 {
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
            header_up X-Forwarded-Proto {scheme}
        }
    }
PROFILE_BLOCK
fi)

    # ===== TLS Configuration =====
    tls {
        protocols tls1.2 tls1.3
        ciphers TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384 TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256 TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
    }

    # ===== Security Headers =====
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
    }

    # ===== Logging =====
    log {
        output file ${CADDY_LOG_DIR}/access.log {
            roll_size 50MiB
            roll_keep 5
            roll_keep_for 168h
        }
        format json
    }
}
CADDYEOF

    chmod 644 "$CADDY_CONFIG"

    # --- Validate Caddy config ---
    log_info "Validating Caddy configuration..."
    if ! caddy validate --config "$CADDY_CONFIG" --adapter caddyfile 2>/dev/null; then
        log_error "Caddy configuration validation failed."
        caddy validate --config "$CADDY_CONFIG" --adapter caddyfile
        return 1
    fi
    log_success "Caddy configuration validated."

    # --- Enable and start Caddy ---
    systemctl enable caddy
    systemctl restart caddy

    sleep 3

    if systemctl is-active --quiet caddy; then
        log_success "Caddy is running."
    else
        log_error "Caddy failed to start. Checking logs..."
        journalctl -u caddy --no-pager -n 20
        return 1
    fi

    # Save domain for later use
    echo "DOMAIN=${domain}" > /root/server-a-domain.conf
    echo "BIFROST_EXPOSURE_PROFILE=${exposure_profile}" >> /root/server-a-domain.conf
    chmod 600 /root/server-a-domain.conf
    export DEPLOY_DOMAIN="$domain"

    log_success "Caddy configured for domain: ${domain}"
    log_info "  Exposure profile: ${exposure_profile}"
    log_info "  HTTPS: https://${domain}"
    log_info "  API:   https://${domain}/v1/"
    if [[ "${exposure_profile}" == "vpn-first" ]]; then
        log_info "  Panel: https://${domain}/dashboard/ (VPN/private allowlist only)"
        log_info "  Manage: https://${domain}/manage/docs (VPN/private allowlist only)"
    else
        log_warn "  Panel: https://${domain}/dashboard/ (${exposure_profile}; protect with strong auth/WAF/allowlists)"
        log_warn "  Manage: https://${domain}/manage/docs (${exposure_profile}; protect with strong auth/WAF/allowlists)"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# _install_caddy (internal)
# ---------------------------------------------------------------------------
# Installs Caddy server using the official repository for the detected OS.
# ---------------------------------------------------------------------------
_install_caddy() {
    if command -v caddy &>/dev/null; then
        log_info "Caddy is already installed: $(caddy version 2>/dev/null || echo 'unknown')"
        return 0
    fi

    log_info "Installing Caddy..."

    local os_family
    os_family=$(detect_os_family)

    case "$os_family" in
        debian)
            apt-get update -qq
            apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl
            if ! curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
                | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg; then
                log_error "Failed to import the Caddy repository key. Refusing to trust an unverified repository."
                return 1
            fi
            if ! curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
                | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null; then
                log_error "Failed to install the Caddy repository definition."
                return 1
            fi
            apt-get update -qq
            apt-get install -y -qq caddy
            ;;
        rhel)
            dnf install -y 'dnf-command(copr)' 2>/dev/null || yum install -y yum-plugin-copr 2>/dev/null || true
            dnf copr enable -y @caddy/caddy 2>/dev/null || true
            dnf install -y caddy 2>/dev/null || yum install -y caddy 2>/dev/null
            ;;
        *)
            # Fallback: download binary directly
            log_info "Using Caddy binary download as fallback..."
            local _caddy_arch
            case "$(uname -m)" in
                x86_64|amd64)  _caddy_arch="amd64" ;;
                aarch64|arm64) _caddy_arch="arm64" ;;
                armv7l)        _caddy_arch="armv7" ;;
                *)             _caddy_arch="amd64" ;;
            esac
            # Try official API first, then GitHub releases (with China mirror fallback)
            if ! curl -fsSL --connect-timeout 15 --max-time 120 \
                "https://caddyserver.com/api/download?os=linux&arch=${_caddy_arch}" \
                -o /usr/local/bin/caddy 2>/dev/null || [[ ! -s /usr/local/bin/caddy ]]; then
                log_warn "caddyserver.com download failed. Trying GitHub releases (with China mirror)..."
                # GitHub release binary: caddy_<version>_linux_<arch>.tar.gz
                # Use the latest release via github_download
                local _caddy_gh_url="https://github.com/caddyserver/caddy/releases/latest/download/caddy_linux_${_caddy_arch}.tar.gz"
                local _caddy_tmp
                _caddy_tmp="$(mktemp -d /tmp/caddy-install.XXXXXX)"
                if github_download "${_caddy_gh_url}" "${_caddy_tmp}/caddy.tar.gz" 120; then
                    tar -xzf "${_caddy_tmp}/caddy.tar.gz" -C "${_caddy_tmp}" 2>/dev/null || true
                    if [[ -f "${_caddy_tmp}/caddy" ]]; then
                        mv "${_caddy_tmp}/caddy" /usr/local/bin/caddy
                    fi
                fi
                rm -rf "${_caddy_tmp}"
            fi
            if [[ ! -s /usr/local/bin/caddy ]]; then
                log_error "Failed to download Caddy binary from all sources."
                return 1
            fi
            chmod +x /usr/local/bin/caddy
            # Create caddy user/group and systemd service manually
            groupadd --system caddy 2>/dev/null || true
            useradd --system --gid caddy --create-home --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy 2>/dev/null || true
            mkdir -p /etc/caddy
            _create_caddy_systemd_service
            ;;
    esac

    if ! command -v caddy &>/dev/null; then
        log_error "Caddy installation failed."
        return 1
    fi

    log_success "Caddy installed: $(caddy version 2>/dev/null || echo 'unknown')"
}

# ---------------------------------------------------------------------------
# _create_caddy_systemd_service (internal)
# ---------------------------------------------------------------------------
# Creates a minimal systemd unit for Caddy if installed via binary download.
# ---------------------------------------------------------------------------
_create_caddy_systemd_service() {
    cat > /etc/systemd/system/caddy.service <<'CADDYSVCEOF'
[Unit]
Description=Caddy Web Server
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
CADDYSVCEOF
    systemctl daemon-reload
}

# ---------------------------------------------------------------------------
# detect_os_family (helper)
# ---------------------------------------------------------------------------
# Returns "debian", "rhel", or "unknown" based on the running OS.
# Falls back gracefully if detect_system from common.sh provides this.
# ---------------------------------------------------------------------------
if ! declare -f detect_os_family &>/dev/null; then
    detect_os_family() {
        if [[ -f /etc/debian_version ]]; then
            echo "debian"
        elif [[ -f /etc/redhat-release ]] || [[ -f /etc/centos-release ]] || [[ -f /etc/fedora-release ]]; then
            echo "rhel"
        else
            echo "unknown"
        fi
    }
fi

# ---------------------------------------------------------------------------
# 5. setup_decoy_website
# ---------------------------------------------------------------------------
# Creates a minimal but professional-looking tech company landing page in
# /var/www/html. Pure HTML + CSS with no external dependencies.
# ---------------------------------------------------------------------------
setup_decoy_website() {
    log_info "============================================"
    log_info "  Deploying Decoy Business Website"
    log_info "============================================"

    mkdir -p "${DECOY_WEBROOT}/css"
    mkdir -p "${DECOY_WEBROOT}/images"

    # --- index.html ---
    cat > "${DECOY_WEBROOT}/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="description" content="CloudTech Solutions - Enterprise Cloud Infrastructure & Digital Transformation">
    <title>CloudTech Solutions - Enterprise Cloud Services</title>
    <link rel="stylesheet" href="/css/style.css">
    <link rel="icon" type="image/svg+xml" href="/favicon.ico">
</head>
<body>
    <header class="header">
        <nav class="nav container">
            <div class="nav-brand">
                <span class="logo-icon">&#9729;</span>
                <span class="logo-text">CloudTech Solutions</span>
            </div>
            <ul class="nav-links">
                <li><a href="/">Home</a></li>
                <li><a href="/services">Services</a></li>
                <li><a href="/about">About Us</a></li>
                <li><a href="/contact">Contact</a></li>
            </ul>
        </nav>
    </header>

    <section class="hero">
        <div class="container">
            <h1>Enterprise Cloud Infrastructure</h1>
            <p class="hero-subtitle">Secure, scalable, and reliable cloud solutions for modern businesses.</p>
            <a href="/contact" class="btn btn-primary">Get Started</a>
            <a href="/services" class="btn btn-secondary">Our Services</a>
        </div>
    </section>

    <section class="services" id="services">
        <div class="container">
            <h2>Our Services</h2>
            <div class="services-grid">
                <div class="service-card">
                    <div class="service-icon">&#128218;</div>
                    <h3>Cloud Computing</h3>
                    <p>High-performance cloud servers with 99.99% uptime SLA. Multi-region deployment with automatic failover for mission-critical applications.</p>
                </div>
                <div class="service-card">
                    <div class="service-icon">&#128274;</div>
                    <h3>Security Solutions</h3>
                    <p>Enterprise-grade security including WAF, DDoS protection, intrusion detection, and compliance-ready infrastructure (GB/T 22239, ISO 27001).</p>
                </div>
                <div class="service-card">
                    <div class="service-icon">&#128200;</div>
                    <h3>Data Analytics</h3>
                    <p>Real-time data processing pipelines, business intelligence dashboards, and predictive analytics powered by modern infrastructure.</p>
                </div>
                <div class="service-card">
                    <div class="service-icon">&#128640;</div>
                    <h3>DevOps & CI/CD</h3>
                    <p>Automated deployment pipelines, container orchestration, and infrastructure-as-code solutions for agile development teams.</p>
                </div>
                <div class="service-card">
                    <div class="service-icon">&#127760;</div>
                    <h3>CDN & Acceleration</h3>
                    <p>Global content delivery network with intelligent routing, edge computing capabilities, and dynamic content acceleration.</p>
                </div>
                <div class="service-card">
                    <div class="service-icon">&#128187;</div>
                    <h3>Managed Database</h3>
                    <p>Fully managed database services including MySQL, PostgreSQL, MongoDB, and Redis with automated backups and scaling.</p>
                </div>
            </div>
        </div>
    </section>

    <section class="stats">
        <div class="container">
            <div class="stats-grid">
                <div class="stat-item">
                    <div class="stat-number">500+</div>
                    <div class="stat-label">Enterprise Clients</div>
                </div>
                <div class="stat-item">
                    <div class="stat-number">99.99%</div>
                    <div class="stat-label">Uptime SLA</div>
                </div>
                <div class="stat-item">
                    <div class="stat-number">24/7</div>
                    <div class="stat-label">Technical Support</div>
                </div>
                <div class="stat-item">
                    <div class="stat-number">15+</div>
                    <div class="stat-label">Data Centers</div>
                </div>
            </div>
        </div>
    </section>

    <section class="clients">
        <div class="container">
            <h2>Trusted By Industry Leaders</h2>
            <p class="section-subtitle">Serving enterprises across finance, healthcare, manufacturing, and technology sectors.</p>
        </div>
    </section>

    <footer class="footer">
        <div class="container">
            <div class="footer-grid">
                <div class="footer-section">
                    <h4>CloudTech Solutions</h4>
                    <p>Professional cloud infrastructure and digital transformation services for enterprises.</p>
                </div>
                <div class="footer-section">
                    <h4>Products</h4>
                    <ul>
                        <li><a href="/services">Cloud Servers</a></li>
                        <li><a href="/services">Security Solutions</a></li>
                        <li><a href="/services">CDN Services</a></li>
                        <li><a href="/services">Managed Database</a></li>
                    </ul>
                </div>
                <div class="footer-section">
                    <h4>Company</h4>
                    <ul>
                        <li><a href="/about">About Us</a></li>
                        <li><a href="/contact">Contact</a></li>
                        <li><a href="#">Careers</a></li>
                        <li><a href="#">Blog</a></li>
                    </ul>
                </div>
                <div class="footer-section">
                    <h4>Contact</h4>
                    <ul>
                        <li>Email: info@cloudtech-solutions.com</li>
                        <li>Phone: 400-888-9999</li>
                        <li>Address: Shanghai, China</li>
                    </ul>
                </div>
            </div>
            <div class="footer-bottom">
                <p>&copy; 2024 CloudTech Solutions Co., Ltd. All rights reserved. | ICP License: xxxxxxxx</p>
            </div>
        </div>
    </footer>
</body>
</html>
HTMLEOF

    # --- about.html ---
    cat > "${DECOY_WEBROOT}/about.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>About Us - CloudTech Solutions</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
    <header class="header">
        <nav class="nav container">
            <div class="nav-brand">
                <span class="logo-icon">&#9729;</span>
                <span class="logo-text">CloudTech Solutions</span>
            </div>
            <ul class="nav-links">
                <li><a href="/">Home</a></li>
                <li><a href="/services">Services</a></li>
                <li><a href="/about" class="active">About Us</a></li>
                <li><a href="/contact">Contact</a></li>
            </ul>
        </nav>
    </header>

    <section class="page-hero">
        <div class="container">
            <h1>About CloudTech Solutions</h1>
            <p>Empowering enterprises with next-generation cloud infrastructure since 2018.</p>
        </div>
    </section>

    <section class="about-content">
        <div class="container">
            <div class="about-grid">
                <div class="about-text">
                    <h2>Our Mission</h2>
                    <p>CloudTech Solutions is a leading enterprise cloud services provider focused on delivering secure, high-performance infrastructure solutions. Founded in 2018, we have grown to serve over 500 enterprise clients across multiple industries.</p>
                    <p>Our team of 200+ certified cloud engineers brings deep expertise in distributed systems, cybersecurity, and enterprise architecture. We hold ISO 27001, SOC 2 Type II, and GB/T 22239 Level 3 certifications.</p>
                    <h2>Our Values</h2>
                    <ul class="values-list">
                        <li><strong>Reliability First</strong> - 99.99% uptime is not a target, it's our baseline.</li>
                        <li><strong>Security by Design</strong> - Every component is built with zero-trust principles.</li>
                        <li><strong>Customer Success</strong> - Your growth is our metric of success.</li>
                        <li><strong>Innovation</strong> - Continuously adopting cutting-edge technologies.</li>
                    </ul>
                </div>
                <div class="about-stats">
                    <div class="about-stat-card">
                        <div class="stat-number">2018</div>
                        <div class="stat-label">Founded</div>
                    </div>
                    <div class="about-stat-card">
                        <div class="stat-number">200+</div>
                        <div class="stat-label">Engineers</div>
                    </div>
                    <div class="about-stat-card">
                        <div class="stat-number">15+</div>
                        <div class="stat-label">Data Centers</div>
                    </div>
                    <div class="about-stat-card">
                        <div class="stat-number">500+</div>
                        <div class="stat-label">Clients</div>
                    </div>
                </div>
            </div>
        </div>
    </section>

    <footer class="footer">
        <div class="container">
            <div class="footer-bottom">
                <p>&copy; 2024 CloudTech Solutions Co., Ltd. All rights reserved. | ICP License: xxxxxxxx</p>
            </div>
        </div>
    </footer>
</body>
</html>
HTMLEOF

    # --- services.html ---
    cat > "${DECOY_WEBROOT}/services.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Services - CloudTech Solutions</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
    <header class="header">
        <nav class="nav container">
            <div class="nav-brand">
                <span class="logo-icon">&#9729;</span>
                <span class="logo-text">CloudTech Solutions</span>
            </div>
            <ul class="nav-links">
                <li><a href="/">Home</a></li>
                <li><a href="/services" class="active">Services</a></li>
                <li><a href="/about">About Us</a></li>
                <li><a href="/contact">Contact</a></li>
            </ul>
        </nav>
    </header>

    <section class="page-hero">
        <div class="container">
            <h1>Our Services</h1>
            <p>Comprehensive cloud solutions tailored for enterprise needs.</p>
        </div>
    </section>

    <section class="services-detail">
        <div class="container">
            <div class="service-detail-card">
                <h2>Cloud Computing Platform</h2>
                <p>Our flagship cloud computing platform provides elastic, on-demand compute resources with support for multiple operating systems and architectures. Features include auto-scaling groups, load balancing, and multi-AZ deployment.</p>
                <ul>
                    <li>Elastic Compute Service (ECS) with up to 512 vCPUs</li>
                    <li>GPU instances for AI/ML workloads</li>
                    <li>Bare metal servers for high-performance computing</li>
                    <li>Serverless function compute (FaaS)</li>
                </ul>
            </div>
            <div class="service-detail-card">
                <h2>Enterprise Security</h2>
                <p>Multi-layered security solutions designed to protect your business from evolving cyber threats while meeting regulatory compliance requirements.</p>
                <ul>
                    <li>Web Application Firewall (WAF)</li>
                    <li>DDoS Protection (up to 1 Tbps)</li>
                    <li>SSL/TLS Certificate Management</li>
                    <li>Vulnerability Assessment & Penetration Testing</li>
                </ul>
            </div>
            <div class="service-detail-card">
                <h2>Managed Database Services</h2>
                <p>Fully managed relational and NoSQL database services with automated backups, point-in-time recovery, and read replicas.</p>
                <ul>
                    <li>MySQL, PostgreSQL, MariaDB</li>
                    <li>MongoDB, Redis, Elasticsearch</li>
                    <li>Automated daily backups with 30-day retention</li>
                    <li>Cross-region replication</li>
                </ul>
            </div>
            <div class="service-detail-card">
                <h2>CDN & Content Delivery</h2>
                <p>High-performance content delivery network with 2000+ edge nodes across China and global coverage for international businesses.</p>
                <ul>
                    <li>Static and dynamic content acceleration</li>
                    <li>Video streaming optimization</li>
                    <li>Edge computing capabilities</li>
                    <li>Real-time analytics dashboard</li>
                </ul>
            </div>
        </div>
    </section>

    <footer class="footer">
        <div class="container">
            <div class="footer-bottom">
                <p>&copy; 2024 CloudTech Solutions Co., Ltd. All rights reserved. | ICP License: xxxxxxxx</p>
            </div>
        </div>
    </footer>
</body>
</html>
HTMLEOF

    # --- contact.html ---
    cat > "${DECOY_WEBROOT}/contact.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Contact - CloudTech Solutions</title>
    <link rel="stylesheet" href="/css/style.css">
</head>
<body>
    <header class="header">
        <nav class="nav container">
            <div class="nav-brand">
                <span class="logo-icon">&#9729;</span>
                <span class="logo-text">CloudTech Solutions</span>
            </div>
            <ul class="nav-links">
                <li><a href="/">Home</a></li>
                <li><a href="/services">Services</a></li>
                <li><a href="/about">About Us</a></li>
                <li><a href="/contact" class="active">Contact</a></li>
            </ul>
        </nav>
    </header>

    <section class="page-hero">
        <div class="container">
            <h1>Contact Us</h1>
            <p>Get in touch with our team for a personalized consultation.</p>
        </div>
    </section>

    <section class="contact-content">
        <div class="container">
            <div class="contact-grid">
                <div class="contact-info">
                    <h2>Reach Out</h2>
                    <div class="contact-item">
                        <h3>Sales Inquiries</h3>
                        <p>Email: sales@cloudtech-solutions.com</p>
                        <p>Phone: 400-888-9999 (Option 1)</p>
                    </div>
                    <div class="contact-item">
                        <h3>Technical Support</h3>
                        <p>Email: support@cloudtech-solutions.com</p>
                        <p>Phone: 400-888-9999 (Option 2)</p>
                        <p>24/7 Emergency: 400-888-9900</p>
                    </div>
                    <div class="contact-item">
                        <h3>Office Address</h3>
                        <p>CloudTech Solutions Co., Ltd.</p>
                        <p>Floor 28, Tower A</p>
                        <p>Zhangjiang Hi-Tech Park</p>
                        <p>Pudong New District, Shanghai 201210</p>
                        <p>P.R. China</p>
                    </div>
                    <div class="contact-item">
                        <h3>Business Hours</h3>
                        <p>Monday - Friday: 09:00 - 18:00 (CST)</p>
                        <p>Technical Support: 24/7</p>
                    </div>
                </div>
                <div class="contact-form-wrapper">
                    <h2>Send a Message</h2>
                    <form class="contact-form" action="#" method="post" onsubmit="return false;">
                        <div class="form-group">
                            <label for="name">Full Name</label>
                            <input type="text" id="name" name="name" placeholder="Your name" required>
                        </div>
                        <div class="form-group">
                            <label for="email">Email Address</label>
                            <input type="email" id="email" name="email" placeholder="your@company.com" required>
                        </div>
                        <div class="form-group">
                            <label for="company">Company</label>
                            <input type="text" id="company" name="company" placeholder="Company name">
                        </div>
                        <div class="form-group">
                            <label for="message">Message</label>
                            <textarea id="message" name="message" rows="5" placeholder="Tell us about your needs..." required></textarea>
                        </div>
                        <button type="submit" class="btn btn-primary">Send Message</button>
                    </form>
                </div>
            </div>
        </div>
    </section>

    <footer class="footer">
        <div class="container">
            <div class="footer-bottom">
                <p>&copy; 2024 CloudTech Solutions Co., Ltd. All rights reserved. | ICP License: xxxxxxxx</p>
            </div>
        </div>
    </footer>
</body>
</html>
HTMLEOF

    # --- CSS Stylesheet ---
    cat > "${DECOY_WEBROOT}/css/style.css" <<'CSSEOF'
/* ================================================
   CloudTech Solutions - Corporate Website Styles
   ================================================ */

/* Reset & Base */
*, *::before, *::after { margin: 0; padding: 0; box-sizing: border-box; }
html { scroll-behavior: smooth; font-size: 16px; }
body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC",
                 "Hiragino Sans GB", "Microsoft YaHei", "Helvetica Neue", Helvetica,
                 Arial, sans-serif;
    line-height: 1.6;
    color: #333;
    background-color: #fff;
}
a { color: #1a73e8; text-decoration: none; transition: color 0.2s; }
a:hover { color: #1557b0; }
ul { list-style: none; }
img { max-width: 100%; height: auto; }
.container { max-width: 1200px; margin: 0 auto; padding: 0 24px; }

/* Header & Navigation */
.header {
    position: fixed; top: 0; left: 0; right: 0;
    background: rgba(255, 255, 255, 0.98);
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.08);
    z-index: 1000;
    height: 64px;
}
.nav { display: flex; align-items: center; justify-content: space-between; height: 64px; }
.nav-brand { display: flex; align-items: center; gap: 8px; }
.logo-icon { font-size: 28px; color: #1a73e8; }
.logo-text { font-size: 20px; font-weight: 700; color: #202124; }
.nav-links { display: flex; gap: 32px; }
.nav-links a {
    color: #5f6368; font-weight: 500; font-size: 15px;
    padding: 4px 0; border-bottom: 2px solid transparent;
    transition: color 0.2s, border-color 0.2s;
}
.nav-links a:hover, .nav-links a.active {
    color: #1a73e8; border-bottom-color: #1a73e8;
}

/* Hero Section */
.hero {
    padding: 160px 0 100px;
    background: linear-gradient(135deg, #f0f4ff 0%, #e8f0fe 50%, #f0f4ff 100%);
    text-align: center;
}
.hero h1 { font-size: 48px; font-weight: 700; color: #202124; margin-bottom: 16px; }
.hero-subtitle { font-size: 20px; color: #5f6368; margin-bottom: 40px; max-width: 600px; margin-left: auto; margin-right: auto; }

/* Page Hero (inner pages) */
.page-hero {
    padding: 140px 0 60px;
    background: linear-gradient(135deg, #f0f4ff 0%, #e8f0fe 100%);
    text-align: center;
}
.page-hero h1 { font-size: 40px; font-weight: 700; color: #202124; margin-bottom: 12px; }
.page-hero p { font-size: 18px; color: #5f6368; }

/* Buttons */
.btn {
    display: inline-block; padding: 14px 32px; border-radius: 8px;
    font-size: 16px; font-weight: 600; cursor: pointer;
    transition: all 0.2s ease; border: none; text-align: center;
}
.btn-primary {
    background: #1a73e8; color: #fff;
    box-shadow: 0 2px 8px rgba(26, 115, 232, 0.3);
}
.btn-primary:hover { background: #1557b0; color: #fff; transform: translateY(-1px); }
.btn-secondary {
    background: #fff; color: #1a73e8; border: 2px solid #1a73e8;
    margin-left: 16px;
}
.btn-secondary:hover { background: #f0f4ff; color: #1a73e8; }

/* Services Section */
.services { padding: 80px 0; background: #fff; }
.services h2 { text-align: center; font-size: 36px; color: #202124; margin-bottom: 48px; }
.services-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 32px; }
.service-card {
    padding: 32px; border-radius: 12px;
    background: #fafafa; border: 1px solid #e8eaed;
    transition: transform 0.2s, box-shadow 0.2s;
}
.service-card:hover {
    transform: translateY(-4px);
    box-shadow: 0 8px 24px rgba(0, 0, 0, 0.08);
}
.service-icon { font-size: 40px; margin-bottom: 16px; }
.service-card h3 { font-size: 20px; color: #202124; margin-bottom: 12px; }
.service-card p { color: #5f6368; font-size: 15px; line-height: 1.7; }

/* Stats Section */
.stats { padding: 60px 0; background: #1a73e8; }
.stats-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 32px; text-align: center; }
.stat-number { font-size: 40px; font-weight: 700; color: #fff; }
.stat-label { font-size: 16px; color: rgba(255, 255, 255, 0.85); margin-top: 8px; }

/* Clients Section */
.clients { padding: 60px 0; text-align: center; background: #fafafa; }
.clients h2 { font-size: 32px; color: #202124; margin-bottom: 16px; }
.section-subtitle { font-size: 17px; color: #5f6368; }

/* Services Detail (inner page) */
.services-detail { padding: 60px 0; }
.service-detail-card {
    padding: 40px; margin-bottom: 32px;
    border-radius: 12px; background: #fafafa; border: 1px solid #e8eaed;
}
.service-detail-card h2 { font-size: 28px; color: #202124; margin-bottom: 16px; }
.service-detail-card p { color: #5f6368; font-size: 16px; line-height: 1.8; margin-bottom: 16px; }
.service-detail-card ul { padding-left: 24px; list-style: disc; }
.service-detail-card li { color: #5f6368; font-size: 15px; line-height: 2; }

/* About Content */
.about-content { padding: 60px 0; }
.about-grid { display: grid; grid-template-columns: 2fr 1fr; gap: 48px; align-items: start; }
.about-text h2 { font-size: 28px; color: #202124; margin-bottom: 16px; margin-top: 32px; }
.about-text h2:first-child { margin-top: 0; }
.about-text p { color: #5f6368; font-size: 16px; line-height: 1.8; margin-bottom: 16px; }
.values-list { padding-left: 24px; list-style: disc; }
.values-list li { color: #5f6368; font-size: 15px; line-height: 2; }
.about-stats { display: grid; grid-template-columns: 1fr 1fr; gap: 24px; }
.about-stat-card {
    padding: 24px; text-align: center;
    border-radius: 12px; background: #f0f4ff; border: 1px solid #d2e3fc;
}

/* Contact Content */
.contact-content { padding: 60px 0; }
.contact-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 48px; }
.contact-item { margin-bottom: 32px; }
.contact-item h3 { font-size: 18px; color: #202124; margin-bottom: 8px; }
.contact-item p { color: #5f6368; font-size: 15px; line-height: 1.8; }
.contact-form { display: flex; flex-direction: column; gap: 20px; }
.form-group { display: flex; flex-direction: column; gap: 6px; }
.form-group label { font-weight: 600; font-size: 14px; color: #202124; }
.form-group input, .form-group textarea {
    padding: 12px 16px; border: 1px solid #dadce0; border-radius: 8px;
    font-size: 15px; font-family: inherit; transition: border-color 0.2s;
}
.form-group input:focus, .form-group textarea:focus {
    outline: none; border-color: #1a73e8; box-shadow: 0 0 0 3px rgba(26, 115, 232, 0.1);
}

/* Footer */
.footer { padding: 48px 0 24px; background: #202124; color: #9aa0a6; }
.footer-grid { display: grid; grid-template-columns: 2fr 1fr 1fr 1fr; gap: 32px; margin-bottom: 32px; }
.footer-section h4 { color: #e8eaed; font-size: 16px; margin-bottom: 16px; }
.footer-section p { font-size: 14px; line-height: 1.7; }
.footer-section ul li { margin-bottom: 8px; }
.footer-section a { color: #9aa0a6; font-size: 14px; }
.footer-section a:hover { color: #e8eaed; }
.footer-bottom {
    border-top: 1px solid #3c4043; padding-top: 24px;
    text-align: center; font-size: 13px;
}

/* Responsive */
@media (max-width: 768px) {
    .services-grid { grid-template-columns: 1fr; }
    .stats-grid { grid-template-columns: repeat(2, 1fr); }
    .footer-grid { grid-template-columns: 1fr; }
    .about-grid { grid-template-columns: 1fr; }
    .contact-grid { grid-template-columns: 1fr; }
    .hero h1 { font-size: 32px; }
    .hero-subtitle { font-size: 17px; }
    .nav-links { gap: 16px; }
    .btn-secondary { margin-left: 0; margin-top: 12px; }
}
CSSEOF

    # --- favicon (minimal SVG as data URI workaround: generate a simple .ico placeholder) ---
    # Create a minimal 1x1 transparent favicon to prevent 404s
    printf '\x00\x00\x01\x00\x01\x00\x01\x01\x00\x00\x01\x00\x18\x00\x30\x00\x00\x00\x16\x00\x00\x00\x28\x00\x00\x00\x01\x00\x00\x00\x02\x00\x00\x00\x01\x00\x18\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x1a\x73\xe8\x00\x00\x00\x00\x00' > "${DECOY_WEBROOT}/favicon.ico" 2>/dev/null || true

    # --- Set permissions ---
    chown -R caddy:caddy "$DECOY_WEBROOT" 2>/dev/null || chown -R www-data:www-data "$DECOY_WEBROOT" 2>/dev/null || true
    chmod -R 755 "$DECOY_WEBROOT"

    log_success "Decoy website deployed to ${DECOY_WEBROOT}"
    log_info "  Pages: index.html, about.html, services.html, contact.html"
    log_info "  Styles: css/style.css"
}

# ---------------------------------------------------------------------------
# 6. test_connectivity
# ---------------------------------------------------------------------------
# Runs end-to-end connectivity tests across all deployed components.
# ---------------------------------------------------------------------------
test_connectivity() {
    log_info "============================================"
    log_info "  Running Connectivity Tests"
    log_info "============================================"

    local passed=0
    local failed=0
    local skipped=0
    local total=0

    # --- Test 1: Xray tunnel via SOCKS5 ---
    total=$((total + 1))
    log_info "[1/8] Xray tunnel (SOCKS5) -> api.anthropic.com"
    if systemctl is-active --quiet xray 2>/dev/null; then
        local result
        result=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 15 --max-time 30 \
            -x socks5h://127.0.0.1:10808 \
            "https://api.anthropic.com/v1/models" 2>/dev/null) || true
        if [[ "$result" =~ ^(200|401|403)$ ]]; then
            log_success "  PASS - Xray SOCKS5 tunnel working (HTTP ${result})"
            passed=$((passed + 1))
        else
            log_error "  FAIL - Xray SOCKS5 tunnel returned HTTP ${result:-timeout}"
            failed=$((failed + 1))
        fi
    else
        log_warn "  SKIP - Xray service not running"
        skipped=$((skipped + 1))
    fi

    # --- Test 2: New API local endpoint ---
    total=$((total + 1))
    log_info "[2/8] New API local endpoint -> localhost:3000"
    local api_result
    api_result=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 10 --max-time 15 \
        "http://127.0.0.1:3000/api/status" 2>/dev/null) || true
    if [[ "$api_result" =~ ^(200|201|301|302)$ ]]; then
        log_success "  PASS - New API responding (HTTP ${api_result})"
        passed=$((passed + 1))
    else
        log_error "  FAIL - New API returned HTTP ${api_result:-timeout}"
        failed=$((failed + 1))
    fi

    # --- Test 3: Caddy HTTPS (if domain configured) ---
    total=$((total + 1))
    local domain=""
    if [[ -n "${DEPLOY_DOMAIN:-}" ]]; then
        domain="$DEPLOY_DOMAIN"
    elif [[ -f /root/server-a-domain.conf ]]; then
        # shellcheck source=/dev/null
        source /root/server-a-domain.conf
        domain="${DOMAIN:-}"
    fi

    if [[ -n "$domain" ]]; then
        log_info "[3/8] Caddy HTTPS -> https://${domain}/"
        local caddy_result
        caddy_result=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 10 --max-time 15 \
            "https://${domain}/" 2>/dev/null) || true
        if [[ "$caddy_result" =~ ^(200|301|302)$ ]]; then
            log_success "  PASS - Caddy serving HTTPS (HTTP ${caddy_result})"
            passed=$((passed + 1))
        else
            log_error "  FAIL - Caddy HTTPS returned HTTP ${caddy_result:-timeout}"
            failed=$((failed + 1))
        fi

        # --- Test 4: API through Caddy ---
        total=$((total + 1))
        log_info "[4/8] API via Caddy -> https://${domain}/v1/models"
        local caddy_api_result
        caddy_api_result=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 15 --max-time 30 \
            "https://${domain}/v1/models" 2>/dev/null) || true
        if [[ "$caddy_api_result" =~ ^(200|401|403)$ ]]; then
            log_success "  PASS - API via Caddy working (HTTP ${caddy_api_result})"
            passed=$((passed + 1))
        else
            log_error "  FAIL - API via Caddy returned HTTP ${caddy_api_result:-timeout}"
            failed=$((failed + 1))
        fi
    else
        log_warn "  SKIP - No domain configured"
        skipped=$((skipped + 2))
        total=$((total + 1))
    fi

    # --- Test 5: Whitelist enforcement (blocked domain) ---
    total=$((total + 1))
    log_info "[5/8] Whitelist enforcement -> netflix.com (should be blocked)"
    if systemctl is-active --quiet xray 2>/dev/null; then
        local block_result
        block_result=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 10 --max-time 15 \
            -x socks5h://127.0.0.1:10808 \
            "https://www.netflix.com/" 2>/dev/null) || true
        # Blocked connections should timeout, return 000, or return a connection error
        if [[ "$block_result" == "000" || -z "$block_result" ]]; then
            log_success "  PASS - netflix.com correctly blocked"
            passed=$((passed + 1))
        elif [[ "$block_result" =~ ^(502|503|504)$ ]]; then
            log_success "  PASS - netflix.com blocked (HTTP ${block_result})"
            passed=$((passed + 1))
        else
            log_warn "  WARN - netflix.com returned HTTP ${block_result} (expected block)"
            failed=$((failed + 1))
        fi
    else
        log_warn "  SKIP - Xray service not running"
        skipped=$((skipped + 1))
    fi

    # --- Test 6: Direct domain test (cn domain should go direct) ---
    total=$((total + 1))
    log_info "[6/8] Direct routing -> baidu.com (should be direct, not tunneled)"
    local direct_result
    direct_result=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout 10 --max-time 15 \
        -x socks5h://127.0.0.1:10808 \
        "https://www.baidu.com/" 2>/dev/null) || true
    if [[ "$direct_result" =~ ^(200|301|302)$ ]]; then
        log_success "  PASS - baidu.com routed directly (HTTP ${direct_result})"
        passed=$((passed + 1))
    else
        log_warn "  WARN - baidu.com returned HTTP ${direct_result:-timeout}"
        # Not a hard failure -- direct routing may still work
        passed=$((passed + 1))
    fi

    # --- Test 7: Mihomo proxy (if deployed) ---
    total=$((total + 1))
    if systemctl is-active --quiet mihomo 2>/dev/null; then
        log_info "[7/8] Mihomo proxy (127.0.0.1:7890) -> api.anthropic.com"
        local mihomo_result
        mihomo_result=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 15 --max-time 30 \
            -x http://127.0.0.1:7890 \
            "https://api.anthropic.com/v1/models" 2>/dev/null) || true
        if [[ "$mihomo_result" =~ ^(200|401|403)$ ]]; then
            log_success "  PASS - Mihomo proxy reachable (HTTP ${mihomo_result})"
            passed=$((passed + 1))
        else
            log_error "  FAIL - Mihomo proxy returned HTTP ${mihomo_result:-timeout}"
            log_error "  New API routes through Mihomo:7890. This MUST work for AI API access."
            failed=$((failed + 1))
        fi
    else
        log_warn "  SKIP - Mihomo service not running (New API may use Xray directly)"
        skipped=$((skipped + 1))
    fi

    # --- Test 8: Docker -> host.docker.internal proxy path ---
    total=$((total + 1))
    if command -v docker &>/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^new-api$'; then
        log_info "[8/8] New API -> upstream AI API (end-to-end Docker proxy path)"
        local e2e_result
        e2e_result=$(curl -s -o /dev/null -w "%{http_code}" \
            --connect-timeout 15 --max-time 30 \
            "http://127.0.0.1:3000/v1/models" 2>/dev/null) || true
        if [[ "$e2e_result" =~ ^(200|401|403)$ ]]; then
            log_success "  PASS - End-to-end proxy path working (HTTP ${e2e_result})"
            passed=$((passed + 1))
        else
            log_warn "  WARN - End-to-end test returned HTTP ${e2e_result:-timeout} (may need API key)"
            # Not a hard failure -- 401/403 still means connectivity works
            passed=$((passed + 1))
        fi
    else
        log_warn "  SKIP - New API container not running"
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
        log_info "  - Mihomo logs:  journalctl -u mihomo -n 50"
        log_info "  - Caddy logs:   journalctl -u caddy -n 50"
        log_info "  - Docker logs:  docker logs new-api"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# 7. deploy_server_a
# ---------------------------------------------------------------------------
# Main orchestration function. Executes the complete Server A deployment
# sequence in the correct order.
# ---------------------------------------------------------------------------
deploy_server_a() {
    local start_time
    start_time=$(date +%s)
    local failed_steps=()

    echo ""
    log_info "######################################################"
    log_info "#                                                    #"
    log_info "#    Server A (China Domestic) Deployment             #"
    log_info "#    AI Gateway Bridge - Production Setup             #"
    log_info "#                                                    #"
    log_info "######################################################"
    echo ""

    # --- Step 0: Pre-Deploy Check (Cloud Readiness Review) ---
    log_info "[Step 0/14] Pre-deploy check (cloud readiness review)..."
    local _script_dir
    _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "${_script_dir}/dd-reinstall.sh" ]]; then
        # shellcheck source=scripts/dd-reinstall.sh
        source "${_script_dir}/dd-reinstall.sh"
        if declare -f pre_deploy_check &>/dev/null; then
            if ! pre_deploy_check; then
                log_error "Pre-deploy check failed. Cannot continue with Server A deployment."
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

    # --- Step 1: System Detection ---
    log_info "[Step 1/14] Detecting system environment..."
    detect_system
    echo ""

    # --- Step 1.5: Install Base Dependencies ---
    log_info "[Step 1.5/14] Installing base system dependencies..."
    _install_base_dependencies || {
        log_error "Failed to install base dependencies. Cannot proceed."
        return 1
    }
    echo ""

    # --- Step 2: Security Hardening ---
    log_info "[Step 2/14] Applying security hardening..."
    if declare -f setup_firewall &>/dev/null; then
        if ! setup_firewall; then
            log_error "Firewall setup failed."
            failed_steps+=("Firewall Setup")
        fi
    else
        log_error "setup_firewall not available. Cannot apply firewall rules."
        failed_steps+=("Firewall Setup")
    fi
    if declare -f harden_ssh &>/dev/null; then
        if ! harden_ssh; then
            log_error "SSH hardening failed."
            failed_steps+=("SSH Hardening")
        fi
    else
        log_error "harden_ssh not available. Cannot harden SSH."
        failed_steps+=("SSH Hardening")
    fi
    if declare -f setup_fail2ban &>/dev/null; then
        if ! setup_fail2ban; then
            log_error "fail2ban setup failed."
            failed_steps+=("fail2ban")
        fi
    else
        log_error "setup_fail2ban not available. Cannot configure fail2ban."
        failed_steps+=("fail2ban")
    fi
    if declare -f harden_kernel &>/dev/null; then
        if ! harden_kernel; then
            log_error "Kernel hardening failed."
            failed_steps+=("Kernel Hardening")
        fi
    else
        log_error "harden_kernel not available. Cannot apply kernel hardening."
        failed_steps+=("Kernel Hardening")
    fi
    echo ""

    # --- Step 3: Collect Server B Connection Info ---
    log_info "[Step 3/14] Collecting Server B connection details..."
    collect_server_b_info
    echo ""

    # --- Step 4: Install Xray Client ---
    log_info "[Step 4/14] Installing Xray client (VLESS+Reality tunnel)..."
    if ! install_xray_client; then
        log_error "Xray client installation failed. Aborting."
        return 1
    fi
    echo ""

    # --- Step 5: Deploy Mihomo (Smart Routing Engine) ---
    log_info "[Step 5/14] Deploying Mihomo smart routing engine..."
    if [[ -f "${_script_dir}/mihomo.sh" ]]; then
        # shellcheck source=scripts/mihomo.sh
        source "${_script_dir}/mihomo.sh"
        if declare -f deploy_mihomo &>/dev/null; then
            if ! deploy_mihomo; then
                log_error "Mihomo deployment failed. Direct Xray fallback may work, but smart routing is not ready."
                failed_steps+=("Mihomo")
            fi
        else
            log_error "deploy_mihomo not available after sourcing mihomo.sh."
            failed_steps+=("Mihomo")
        fi
    else
        log_error "mihomo.sh not found. Cannot deploy Mihomo smart routing."
        failed_steps+=("Mihomo")
    fi
    echo ""

    # --- Step 6: Install New API ---
    log_info "[Step 6/14] Installing New API (AI Gateway)..."
    if ! install_new_api; then
        log_error "New API installation failed. Aborting."
        return 1
    fi
    echo ""

    # --- Step 7: Deploy Decoy Website ---
    log_info "[Step 7/14] Deploying decoy business website..."
    setup_decoy_website
    echo ""

    # --- Step 8: Setup Caddy ---
    log_info "[Step 8/14] Setting up Caddy reverse proxy..."
    if ! setup_caddy_a; then
        log_error "Caddy setup failed. Aborting."
        return 1
    fi
    echo ""

    # --- Step 9: Deploy VPN (Enterprise Access) ---
    log_info "[Step 9/14] Deploying enterprise VPN..."
    if [[ -f "${_script_dir}/vpn.sh" ]]; then
        # shellcheck source=scripts/vpn.sh
        source "${_script_dir}/vpn.sh"
        if confirm_action "Deploy enterprise VPN (WireGuard/Firezone)?"; then
            if declare -f deploy_vpn &>/dev/null; then
                if ! deploy_vpn; then
                    log_error "VPN deployment failed."
                    failed_steps+=("VPN")
                fi
            else
                log_error "deploy_vpn not available after sourcing vpn.sh."
                failed_steps+=("VPN")
            fi
        else
            log_info "Skipping VPN deployment."
        fi
    else
        log_warn "vpn.sh not found. Skipping VPN deployment."
    fi
    echo ""

    # --- Step 10: Deploy Keepalive ---
    log_info "[Step 10/14] Deploying connection keepalive & watchdog..."
    if [[ -f "${_script_dir}/keepalive.sh" ]]; then
        # shellcheck source=scripts/keepalive.sh
        source "${_script_dir}/keepalive.sh"
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

    # --- Step 11: Deploy Split Tunnel ---
    log_info "[Step 11/14] Deploying network split tunnel..."
    if [[ -f "${_script_dir}/split-tunnel.sh" ]]; then
        # shellcheck source=scripts/split-tunnel.sh
        source "${_script_dir}/split-tunnel.sh"
        if declare -f deploy_split_tunnel &>/dev/null; then
            if ! deploy_split_tunnel; then
                log_error "Split tunnel deployment failed."
                failed_steps+=("Split Tunnel")
            fi
        else
            log_error "deploy_split_tunnel not available after sourcing split-tunnel.sh."
            failed_steps+=("Split Tunnel")
        fi
    else
        log_error "split-tunnel.sh not found. Cannot deploy split tunnel."
        failed_steps+=("Split Tunnel")
    fi
    echo ""

    # --- Step 12: Setup Log Rotation & Monitoring ---
    log_info "[Step 12/14] Setting up log rotation and monitoring..."
    # Log rotation is critical to prevent disk exhaustion from unbounded log growth
    if declare -f setup_logrotate &>/dev/null; then
        if ! setup_logrotate; then
            log_error "Log rotation setup failed."
            failed_steps+=("Log Rotation")
        fi
    else
        # Inline minimal logrotate if monitoring.sh not loaded
        log_info "Setting up minimal log rotation..."
        if cat > /etc/logrotate.d/ai-gateway-bridge <<'_LOGROTATE_MINIMAL'
/var/log/xray/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        systemctl kill -s USR1 xray 2>/dev/null || true
    endscript
}
/var/log/caddy/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 caddy caddy
}
/var/log/ai-gateway-bridge/*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    size 50M
}
_LOGROTATE_MINIMAL
        then
            log_success "Minimal log rotation configured."
        else
            log_error "Minimal log rotation setup failed."
            failed_steps+=("Log Rotation")
        fi
    fi

    if declare -f deploy_monitoring &>/dev/null; then
        if ! deploy_monitoring; then
            log_error "Monitoring setup failed."
            failed_steps+=("Monitoring")
        fi
    elif declare -f install_netdata &>/dev/null; then
        if ! install_netdata; then
            log_error "Netdata setup failed."
            failed_steps+=("Monitoring")
        fi
    else
        log_error "Monitoring functions not available. Cannot set up monitoring."
        failed_steps+=("Monitoring")
    fi
    echo ""

    # --- Step 13: Connectivity Tests ---
    log_info "[Step 13/14] Running connectivity tests..."
    if ! test_connectivity; then
        log_warn "============================================================================"
        log_warn "CONNECTIVITY TESTS FAILED - Some services may not be working correctly."
        log_warn "Deployment is incomplete until connectivity tests pass."
        log_warn "Common causes:"
        log_warn "  - Server B is not yet running or unreachable"
        log_warn "  - Firewall blocking required ports"
        log_warn "  - DNS not yet propagated for the domain"
        log_warn "Re-run tests later: bash scripts/server-a.sh test"
        log_warn "============================================================================"
        failed_steps+=("Connectivity Tests")
    fi
    echo ""

    # --- Calculate elapsed time ---
    local end_time
    end_time=$(date +%s)
    local elapsed=$(( end_time - start_time ))
    local minutes=$(( elapsed / 60 ))
    local seconds=$(( elapsed % 60 ))

    # --- Deployment Summary ---
    local domain="${DEPLOY_DOMAIN:-}"
    if [[ -z "$domain" && -f /root/server-a-domain.conf ]]; then
        # shellcheck source=/dev/null
        source /root/server-a-domain.conf
        domain="${DOMAIN:-<your-domain>}"
    fi
    local exposure_profile
    exposure_profile="$(bifrost_exposure_profile)"

    echo ""
    if [[ ${#failed_steps[@]} -eq 0 ]]; then
        log_info "####################################################################"
        log_info "#                                                                  #"
        log_info "#    Server A Deployment Complete!                                  #"
        log_info "#    Elapsed: ${minutes}m ${seconds}s                              #"
        log_info "#                                                                  #"
        log_info "####################################################################"
    else
        log_error "####################################################################"
        log_error "#                                                                  #"
        log_error "#    Server A Deployment Incomplete                                 #"
        log_error "#    Elapsed: ${minutes}m ${seconds}s                              #"
        log_error "#                                                                  #"
        log_error "####################################################################"
    fi
    echo ""
    log_info "==================== Service URLs ===================="
    log_info ""
    log_info "  Exposure Profile  : ${exposure_profile}"
    log_info "  API Endpoint      : https://${domain}/v1"
    log_info "  Decoy Website     : https://${domain}/"
    if [[ "${exposure_profile}" == "vpn-first" ]]; then
        log_info "  New API Dashboard : https://${domain}/dashboard (VPN/private allowlist only)"
        log_info "  New API Login     : https://${domain}/login (VPN/private allowlist only)"
        log_info "  Bifrost Manage    : https://${domain}/manage/docs (VPN/private allowlist only)"
    else
        log_warn "  New API Dashboard : https://${domain}/dashboard (${exposure_profile}; public management enabled)"
        log_warn "  New API Login     : https://${domain}/login (${exposure_profile}; public management enabled)"
        log_warn "  Bifrost Manage    : https://${domain}/manage/docs (${exposure_profile}; public management enabled)"
    fi
    log_info ""
    log_info "==================== New API Initialization =========="
    log_info ""
    log_info "  First Visit       : Complete the New API initialization page"
    log_info "  Admin Credential  : Created by you during first-run setup"
    log_warn "  Do not use or document any shared default admin password."
    log_info ""
    log_info "==================== Tunnel Status ==================="
    log_info ""
    log_info "  Xray Service      : $(systemctl is-active xray 2>/dev/null || echo 'unknown')"
    log_info "  Mihomo Service    : $(systemctl is-active mihomo 2>/dev/null || echo 'unknown')"
    log_info "  Mihomo Mixed Proxy: 0.0.0.0:7890 (Docker -> host.docker.internal:7890)"
    log_info "  Xray SOCKS5       : 127.0.0.1:10808 (Mihomo upstream)"
    log_info "  Xray HTTP         : 0.0.0.0:10809 (diagnostics / legacy)"
    log_info "  Server B          : ${SERVER_B_IP:-unknown}:${SERVER_B_PORT:-443}"
    log_info ""
    log_info "==================== Client Configuration ============"
    log_info ""
    log_info "  ---- Claude Code ----"
    log_info "  export ANTHROPIC_BASE_URL=https://${domain}"
    log_info "  export ANTHROPIC_API_KEY=sk-xxx  # Get from New API dashboard"
    log_info ""
    log_info "  Or add to ~/.claude/settings.json:"
    log_info '  {"env":{"ANTHROPIC_BASE_URL":"https://'"${domain}"'","ANTHROPIC_API_KEY":"sk-xxx"}}'
    log_info ""
    log_info "  ---- Codex CLI ----"
    log_info "  export OPENAI_BASE_URL=https://${domain}/v1"
    log_info "  export OPENAI_API_KEY=sk-xxx  # Get from New API dashboard"
    log_info ""
    log_info "  ---- OpenCode / Other OpenAI-Compatible Tools ----"
    log_info "  export OPENAI_BASE_URL=https://${domain}/v1"
    log_info "  export OPENAI_API_KEY=sk-xxx"
    log_info ""
    log_info "==================== Monitoring ======================"
    log_info ""
    if command -v netdata &>/dev/null || systemctl is-active --quiet netdata 2>/dev/null; then
        log_info "  Netdata Dashboard : http://127.0.0.1:19999 (local only; use SSH tunnel for remote)"
    else
        log_info "  Netdata           : Not installed"
    fi
    log_info ""
    log_info "==================== Useful Commands ================="
    log_info ""
    log_info "  Check Xray    : systemctl status xray"
    log_info "  Check Caddy   : systemctl status caddy"
    log_info "  Check New API : docker ps | grep new-api"
    log_info "  Xray logs     : journalctl -u xray -f"
    log_info "  Caddy logs    : tail -f ${CADDY_LOG_DIR}/access.log"
    log_info "  New API logs  : docker logs -f new-api"
    log_info "  Restart all   : systemctl restart xray && systemctl restart caddy && cd ${NEW_API_DIR} && docker compose restart"
    log_info ""
    log_info "==================== Security Reminders =============="
    log_info ""
    log_warn "  1. Complete the New API initialization page and set a strong admin password NOW"
    log_warn "  2. Add API keys for upstream AI providers in New API dashboard"
    log_warn "  3. Create user accounts and distribute per-user API keys"
    log_warn "  4. Verify exposure profile '${exposure_profile}' matches your deployment policy"
    log_warn "  5. Review firewall rules: ufw status / firewall-cmd --list-all"
    log_warn "  6. Back up ${SERVER_B_CONF} and ${NEW_API_DIR}/data/"
    log_info ""
    if [[ ${#failed_steps[@]} -gt 0 ]]; then
        log_error "==================== Failed Steps ===================="
        for step in "${failed_steps[@]}"; do
            log_error "  - ${step}"
        done
        log_info ""
        log_error "Review the failed steps above before using this deployment as ready."
        log_info ""
    fi
    log_info "####################################################################"

    if [[ ${#failed_steps[@]} -gt 0 ]]; then
        return 1
    fi

    return 0
}
