#!/usr/bin/env bash
###############################################################################
# AI Gateway Bridge - Split Tunneling & Network Segmentation Script
#
# Deploys network segmentation and split-tunneling infrastructure:
#   1. Network segments (VPN / Services / Docker subnets)
#   2. iptables segmentation rules (traffic flow control)
#   3. DNS split resolution (Mihomo fake-ip, DoH for AI/CN domains)
#
# Network Architecture:
#   10.8.0.0/24   - VPN clients (WireGuard/OpenVPN users)
#   172.16.0.0/24 - Service network (Xray, Caddy, New API, Mihomo)
#   172.17.0.0/16 - Docker default bridge (containers)
#
# Traffic Flow:
#   VPN clients   -> Service network  : ACCEPT (authenticated access)
#   Docker        -> Mihomo proxy     : ACCEPT (container routing)
#   External      -> Service network  : DROP   (no direct access)
#   AI traffic    -> DoH via tunnel   : Encrypted DNS over proxy
#   CN traffic    -> DoH direct       : Domestic DNS resolution
#
# Usage: source this file from install.sh or run directly
#   bash scripts/split-tunnel.sh
#
# Dependencies: scripts/common.sh, iptables, jq (optional for Mihomo config)
###############################################################################

set -euo pipefail

# Guard against double-sourcing (readonly variables would conflict)
if [[ -n "${_SPLIT_TUNNEL_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
readonly _SPLIT_TUNNEL_SH_LOADED=1

# Resolve the directory this script resides in
_ST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ST_PROJECT_DIR="$(cd "${_ST_SCRIPT_DIR}/.." && pwd)"

# Source common utilities
if [[ -f "${_ST_SCRIPT_DIR}/common.sh" ]]; then
    # shellcheck source=scripts/common.sh
    source "${_ST_SCRIPT_DIR}/common.sh"
else
    # Minimal fallback
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
    log_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
    log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
    log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
    log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
    die()         { log_error "$@"; exit 1; }
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
if ! declare -f install_if_missing >/dev/null 2>&1; then
    install_if_missing() {
        local cmd="${1}"
        local pkg="${2:-${cmd}}"
        if ! command -v "${cmd}" &>/dev/null; then
            log_info "Installing ${pkg}..."
            if command -v apt-get &>/dev/null; then
                DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkg}"
            elif command -v dnf &>/dev/null; then
                dnf install -y "${pkg}"
            elif command -v yum &>/dev/null; then
                yum install -y "${pkg}"
            else
                die "Cannot install '${pkg}': no supported package manager found."
            fi
        fi
    }
fi

# Project paths
: "${INSTALL_DIR:=/opt/ai-gateway-bridge}"
: "${LOG_DIR:=/var/log/ai-gateway-bridge}"

# Network segment constants (guarded — may already be defined by vpn.sh)
[[ -v VPN_SUBNET ]]      || readonly VPN_SUBNET="10.8.0.0/24"
[[ -v VPN_GATEWAY ]]     || readonly VPN_GATEWAY="10.8.0.1"
[[ -v SERVICE_SUBNET ]]  || readonly SERVICE_SUBNET="172.16.0.0/24"
[[ -v SERVICE_GATEWAY ]] || readonly SERVICE_GATEWAY="172.16.0.1"
[[ -v DOCKER_SUBNET ]]   || readonly DOCKER_SUBNET="172.17.0.0/16"

# Mihomo configuration paths (guarded — may already be defined by mihomo.sh)
[[ -v MIHOMO_CONFIG_DIR ]]  || readonly MIHOMO_CONFIG_DIR="/etc/mihomo"
[[ -v MIHOMO_CONFIG ]]      || readonly MIHOMO_CONFIG="${MIHOMO_CONFIG_DIR}/config.yaml"
[[ -v MIHOMO_RUNTIME_DIR ]] || readonly MIHOMO_RUNTIME_DIR="/var/lib/mihomo"

# iptables rules script
readonly IPTABLES_RULES_SRC="${_ST_PROJECT_DIR}/configs/network/iptables-rules.sh"
readonly IPTABLES_RULES_DEST="${INSTALL_DIR}/iptables-rules.sh"

###############################################################################
# setup_network_segments()
#
# Configures network segments for traffic isolation:
#   - 10.8.0.0/24  : VPN clients (WireGuard or OpenVPN)
#   - 172.16.0.0/24: Service network (bridge for internal services)
#   - 172.17.0.0/16: Docker default bridge (unchanged, documented)
#
# Creates the service bridge interface if it does not exist.
# Configures IP forwarding between segments.
###############################################################################
setup_network_segments() {
    log_step "Configuring network segments..."

    # Ensure ip command is available
    if ! command_exists ip; then
        die "'ip' command not found. Install iproute2."
    fi

    # -------------------------------------------------------------------------
    # Enable IP forwarding (required for inter-segment routing)
    # -------------------------------------------------------------------------
    log_info "Enabling IP forwarding..."
    sysctl -w net.ipv4.ip_forward=1 2>/dev/null || true

    # Persist IP forwarding
    if ! grep -qs "^net.ipv4.ip_forward\s*=\s*1" /etc/sysctl.d/98-ai-gateway-keepalive.conf 2>/dev/null && \
       ! grep -qs "^net.ipv4.ip_forward\s*=\s*1" /etc/sysctl.d/99-ai-gateway-hardening.conf 2>/dev/null; then
        echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/98-ai-gateway-keepalive.conf 2>/dev/null || \
            echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    fi

    # -------------------------------------------------------------------------
    # VPN Subnet (10.8.0.0/24) - handled by WireGuard/OpenVPN configuration
    # -------------------------------------------------------------------------
    log_info "VPN subnet: ${VPN_SUBNET} (gateway: ${VPN_GATEWAY})"
    log_info "  -> Configured by WireGuard (wg0) or OpenVPN (tun0) during VPN setup."

    # Check if VPN interface exists
    local vpn_iface=""
    for iface in wg0 wg1 tun0 tun1; do
        if ip link show "${iface}" &>/dev/null 2>&1; then
            vpn_iface="${iface}"
            local vpn_addr
            vpn_addr="$(ip -4 addr show "${iface}" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)"
            log_info "  -> Found VPN interface: ${iface} (${vpn_addr:-no address})"
            break
        fi
    done
    if [[ -z "${vpn_iface}" ]]; then
        log_warn "  -> No VPN interface found. VPN segment rules will be inactive until VPN is configured."
    fi

    # -------------------------------------------------------------------------
    # Service Subnet (172.16.0.0/24) - bridge interface for internal services
    # -------------------------------------------------------------------------
    log_info "Service subnet: ${SERVICE_SUBNET} (gateway: ${SERVICE_GATEWAY})"

    if ip link show br-aigw &>/dev/null 2>&1; then
        log_info "  -> Bridge 'br-aigw' already exists."
    else
        log_info "  -> Creating bridge interface 'br-aigw'..."

        # Create the bridge
        ip link add br-aigw type bridge 2>/dev/null || {
            log_warn "  -> Could not create bridge 'br-aigw'. Skipping (may already exist or require kernel module)."
        }

        if ip link show br-aigw &>/dev/null 2>&1; then
            ip addr add "${SERVICE_GATEWAY}/24" dev br-aigw 2>/dev/null || true
            ip link set br-aigw up

            log_success "  -> Bridge 'br-aigw' created with IP ${SERVICE_GATEWAY}/24"
        fi
    fi

    # Make bridge persistent via netplan or ifcfg
    _persist_bridge_config

    # -------------------------------------------------------------------------
    # Docker Subnet (172.17.0.0/16) - managed by Docker daemon
    # -------------------------------------------------------------------------
    log_info "Docker subnet: ${DOCKER_SUBNET}"
    if ip link show docker0 &>/dev/null 2>&1; then
        local docker_addr
        docker_addr="$(ip -4 addr show docker0 2>/dev/null | grep -oP 'inet \K[\d./]+' | head -1)"
        log_info "  -> Docker bridge 'docker0' exists (${docker_addr:-unknown})"
    else
        log_info "  -> Docker bridge not found. Will be created when Docker starts."
    fi

    log_success "Network segments configured."
}

# Internal: persist bridge configuration across reboots
_persist_bridge_config() {
    # Netplan-based systems (Ubuntu 18.04+)
    if command_exists netplan && [[ -d /etc/netplan ]]; then
        local netplan_file="/etc/netplan/90-ai-gateway-bridge.yaml"
        if [[ ! -f "${netplan_file}" ]]; then
            cat > "${netplan_file}" <<NETPLAN_EOF
# AI Gateway Bridge - Service network bridge
# Auto-generated by split-tunnel.sh
network:
  version: 2
  bridges:
    br-aigw:
      addresses:
        - ${SERVICE_GATEWAY}/24
      parameters:
        stp: false
        forward-delay: 0
NETPLAN_EOF
            chmod 600 "${netplan_file}"
            log_info "  -> Netplan config written to ${netplan_file}"
            # Apply netplan (non-disruptive for new interfaces)
            netplan apply 2>/dev/null || log_warn "  -> netplan apply produced warnings."
        fi
        return 0
    fi

    # NetworkManager-based systems (fallback for CentOS/Fedora)
    if command_exists nmcli; then
        if ! nmcli connection show br-aigw &>/dev/null 2>&1; then
            nmcli connection add type bridge ifname br-aigw \
                con-name br-aigw \
                ipv4.addresses "${SERVICE_GATEWAY}/24" \
                ipv4.method manual \
                bridge.stp no \
                connection.autoconnect yes 2>/dev/null || true
            log_info "  -> NetworkManager connection 'br-aigw' created."
        fi
        return 0
    fi

    # Fallback: create a systemd-networkd config
    if [[ -d /etc/systemd/network ]]; then
        local netdev_file="/etc/systemd/network/90-br-aigw.netdev"
        local network_file="/etc/systemd/network/90-br-aigw.network"

        if [[ ! -f "${netdev_file}" ]]; then
            cat > "${netdev_file}" <<NETDEV_EOF
[NetDev]
Name=br-aigw
Kind=bridge
NETDEV_EOF

            cat > "${network_file}" <<NETWORK_EOF
[Match]
Name=br-aigw

[Network]
Address=${SERVICE_GATEWAY}/24
NETWORK_EOF
            log_info "  -> systemd-networkd config written."
        fi
        return 0
    fi

    log_warn "  -> No persistent network manager found. Bridge config is runtime-only."
}

###############################################################################
# setup_iptables_segmentation()
#
# Deploys comprehensive iptables rules for network segmentation:
#   - VPN clients  -> Service network  : ACCEPT
#   - Docker       -> Mihomo proxy     : ACCEPT
#   - External     -> Service network  : DROP
#   - NAT/MASQUERADE for Docker and VPN egress
#   - Rate limiting on SSH and ICMP
#   - Connection tracking for established sessions
###############################################################################
setup_iptables_segmentation() {
    log_step "Deploying iptables segmentation rules..."

    # Ensure iptables is available
    if ! command_exists iptables; then
        log_info "Installing iptables..."
        install_if_missing iptables iptables
    fi

    # Create install directory
    mkdir -p "${INSTALL_DIR}"

    # Deploy the iptables rules script
    if [[ -f "${IPTABLES_RULES_SRC}" ]]; then
        cp "${IPTABLES_RULES_SRC}" "${IPTABLES_RULES_DEST}"
        log_info "Deployed iptables rules script from ${IPTABLES_RULES_SRC}"
    else
        log_error "iptables rules script not found at ${IPTABLES_RULES_SRC}"
        return 1
    fi
    chmod +x "${IPTABLES_RULES_DEST}"

    # Apply the rules
    log_info "Applying iptables rules..."
    if bash "${IPTABLES_RULES_DEST}" apply; then
        log_success "iptables segmentation rules applied."
    else
        log_error "Failed to apply iptables rules."
        return 1
    fi

    # Install iptables-persistent for rule persistence across reboots
    if command_exists apt-get; then
        if ! dpkg -l iptables-persistent &>/dev/null 2>&1; then
            log_info "Installing iptables-persistent for rule persistence..."
            echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections 2>/dev/null || true
            echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections 2>/dev/null || true
            DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent 2>/dev/null || {
                log_warn "Could not install iptables-persistent. Rules will need manual persistence."
            }
        fi
    elif command_exists dnf || command_exists yum; then
        # On RHEL-based systems, use iptables-services
        if ! systemctl list-unit-files iptables.service &>/dev/null 2>&1; then
            log_info "Installing iptables-services for rule persistence..."
            if command_exists dnf; then
                dnf install -y iptables-services 2>/dev/null || true
            else
                yum install -y iptables-services 2>/dev/null || true
            fi
            systemctl enable iptables 2>/dev/null || true
        fi
    fi

    # Create a systemd service to restore rules on boot
    cat > /etc/systemd/system/ai-gateway-iptables.service <<IPTSERVICE_EOF
[Unit]
Description=AI Gateway Bridge - iptables Rules Restoration
Documentation=https://github.com/ai-gateway-bridge
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=${IPTABLES_RULES_DEST} apply
ExecStop=${IPTABLES_RULES_DEST} flush
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
IPTSERVICE_EOF

    systemctl daemon-reload
    systemctl enable ai-gateway-iptables.service

    log_info "  Rules script: ${IPTABLES_RULES_DEST}"
    log_info "  Saved rules:  /etc/iptables/ai-gateway-bridge.rules"
    log_info "  Boot service: ai-gateway-iptables.service"
    log_info "  View status:  bash ${IPTABLES_RULES_DEST} status"
}

###############################################################################
# setup_dns_split()
#
# Configures DNS split resolution via Mihomo:
#   - fake-ip mode for transparent proxy DNS interception
#   - AI domain queries  -> DoH via tunnel (8.8.8.8, 1.1.1.1)
#   - CN domain queries  -> DoH direct (223.5.5.5 AliDNS, 119.29.29.29 DNSPod)
#   - Default fallback   -> DoH via tunnel
#
# Generates/patches the Mihomo config.yaml with DNS settings.
# If Mihomo is not installed, writes the config for future use.
###############################################################################
setup_dns_split() {
    log_step "Configuring DNS split resolution..."

    # Create Mihomo config directory
    mkdir -p "${MIHOMO_CONFIG_DIR}"
    mkdir -p "${MIHOMO_RUNTIME_DIR}"

    # Backup existing config
    if [[ -f "${MIHOMO_CONFIG}" ]]; then
        local backup="${MIHOMO_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
        cp "${MIHOMO_CONFIG}" "${backup}"
        log_info "Backed up existing Mihomo config to ${backup}"
    fi

    # Load AI domains for DNS routing
    local ai_domains_file="${_ST_PROJECT_DIR}/configs/whitelist/ai-domains.txt"
    local ai_domain_rules=""
    if [[ -f "${ai_domains_file}" ]]; then
        log_info "Loading AI domains from ${ai_domains_file}..."
        while IFS= read -r line; do
            # Skip comments and empty lines
            line="$(echo "${line}" | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
            [[ -z "${line}" ]] && continue
            # Extract domain (handle formats: domain, +.domain, *.domain)
            local domain
            domain="$(echo "${line}" | sed 's/^[+*]\.//')"
            ai_domain_rules="${ai_domain_rules}    - \"+.${domain}\"\n"
        done < "${ai_domains_file}"
    fi

    # Write Mihomo DNS split configuration
    # This is a focused DNS-and-routing config; the full proxy chain config
    # is generated by the server deployment scripts.
    cat > "${MIHOMO_CONFIG}" <<MIHOMO_EOF
# =============================================================================
# AI Gateway Bridge - Mihomo DNS Split & Routing Configuration
# Auto-generated by split-tunnel.sh
# =============================================================================

# ---- General Settings ----
mixed-port: 7893
socks-port: 7891
port: 7890
allow-lan: false
bind-address: "127.0.0.1"
mode: rule
log-level: warning
ipv6: false
external-controller: 127.0.0.1:9090

# ---- DNS Configuration ----
dns:
  enable: true
  listen: 0.0.0.0:53
  ipv6: false

  # fake-ip mode: Mihomo returns fake IPs for DNS queries and handles
  # the real resolution internally when traffic is proxied. This ensures
  # all DNS queries for proxied domains go through the tunnel.
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16

  # Domains that should NOT receive fake-ip responses
  # (must resolve to real IPs for local network services)
  fake-ip-filter:
    - "*.lan"
    - "*.local"
    - "*.localhost"
    - "*.internal"
    - "time.*.com"
    - "ntp.*.com"
    - "*.ntp.org.cn"
    - "+.pool.ntp.org"
    - "localhost.ptlogin2.qq.com"
    - "dns.msftncsi.com"
    - "www.msftncsi.com"
    - "www.msftconnecttest.com"

  # Nameserver groups
  default-nameserver:
    # Bootstrap DNS (must be IP, used to resolve DoH hostnames)
    - 223.5.5.5
    - 119.29.29.29

  nameserver:
    # Primary: DoH through tunnel (for global/AI domains)
    - "https://dns.google/dns-query"
    - "https://cloudflare-dns.com/dns-query"

  # China-specific DNS (direct, no proxy)
  nameserver-policy:
    # CN domains -> domestic DoH resolvers (direct, low latency)
    "geosite:cn,geosite:private":
      - "https://dns.alidns.com/dns-query"
      - "https://doh.pub/dns-query"
    # AI API domains -> global DoH resolvers (through tunnel)
    "geosite:google,geosite:github,+.anthropic.com,+.openai.com,+.googleapis.com,+.google.dev,+.deepseek.com,+.mistral.ai,+.groq.com,+.huggingface.co,+.cohere.ai,+.cohere.com,+.perplexity.ai,+.together.xyz,+.together.ai":
      - "https://dns.google/dns-query"
      - "https://cloudflare-dns.com/dns-query"

# ---- Proxy Definitions ----
proxies: []

# ---- Proxy Groups ----
proxy-groups:
  - name: "TUNNEL"
    type: select
    proxies:
      - DIRECT
    # NOTE: Add your Xray proxy here after deployment.
    # Example:
    # - name: "xray-vless"
    #   type: vless
    #   server: <server-b-ip>
    #   port: 443
    #   uuid: <uuid>
    #   ...

  - name: "AI-SERVICES"
    type: select
    proxies:
      - "TUNNEL"

  - name: "CN-DIRECT"
    type: select
    proxies:
      - DIRECT

# ---- Routing Rules ----
rules:
  # AI service domains -> through tunnel
  - DOMAIN-SUFFIX,anthropic.com,AI-SERVICES
  - DOMAIN-SUFFIX,openai.com,AI-SERVICES
  - DOMAIN-SUFFIX,googleapis.com,AI-SERVICES
  - DOMAIN-SUFFIX,google.dev,AI-SERVICES
  - DOMAIN-SUFFIX,deepseek.com,AI-SERVICES
  - DOMAIN-SUFFIX,mistral.ai,AI-SERVICES
  - DOMAIN-SUFFIX,groq.com,AI-SERVICES
  - DOMAIN-SUFFIX,huggingface.co,AI-SERVICES
  - DOMAIN-SUFFIX,cohere.ai,AI-SERVICES
  - DOMAIN-SUFFIX,cohere.com,AI-SERVICES
  - DOMAIN-SUFFIX,perplexity.ai,AI-SERVICES
  - DOMAIN-SUFFIX,together.xyz,AI-SERVICES
  - DOMAIN-SUFFIX,together.ai,AI-SERVICES
  - DOMAIN-SUFFIX,github.com,AI-SERVICES
  - DOMAIN-SUFFIX,githubusercontent.com,AI-SERVICES

  # Local and private networks -> direct
  - IP-CIDR,127.0.0.0/8,DIRECT
  - IP-CIDR,10.0.0.0/8,DIRECT
  - IP-CIDR,172.16.0.0/12,DIRECT
  - IP-CIDR,192.168.0.0/16,DIRECT
  - IP-CIDR,${VPN_SUBNET},DIRECT
  - IP-CIDR,${SERVICE_SUBNET},DIRECT

  # China domains and IPs -> direct
  - GEOSITE,cn,CN-DIRECT
  - GEOIP,CN,CN-DIRECT

  # Default -> through tunnel
  - MATCH,TUNNEL
MIHOMO_EOF

    # Restrict permissions — config may contain upstream connection details
    chmod 600 "${MIHOMO_CONFIG}"
    log_success "Mihomo DNS split config written to ${MIHOMO_CONFIG}"

    # Restart Mihomo if running
    if command_exists systemctl && systemctl is-active --quiet mihomo 2>/dev/null; then
        log_info "Restarting Mihomo to apply DNS split configuration..."
        systemctl restart mihomo
        sleep 2
        if systemctl is-active --quiet mihomo; then
            log_success "Mihomo restarted with DNS split configuration."
        else
            log_warn "Mihomo failed to restart. Check: journalctl -u mihomo"
        fi
    elif command_exists mihomo; then
        log_info "Mihomo is installed but not running as a service."
        log_info "Start with: mihomo -d ${MIHOMO_CONFIG_DIR}"
    else
        log_info "Mihomo is not installed yet. Config prepared for future deployment."
        log_info "Install Mihomo and start with: mihomo -d ${MIHOMO_CONFIG_DIR}"
    fi

    log_info "DNS split resolution summary:"
    log_info "  Mode:      fake-ip (198.18.0.0/16)"
    log_info "  AI domains -> DoH via tunnel (dns.google, cloudflare-dns.com)"
    log_info "  CN domains -> DoH direct (dns.alidns.com, doh.pub)"
    log_info "  Default    -> DoH via tunnel"
    log_info "  Listen:    0.0.0.0:53"
}

###############################################################################
# deploy_split_tunnel()
#
# Orchestration function that runs all split-tunneling setup steps in order.
###############################################################################
deploy_split_tunnel() {
    log_step "============================================"
    log_step "  AI Gateway Bridge - Split Tunnel Deployment"
    log_step "============================================"
    echo ""

    # Step 1: Configure network segments
    setup_network_segments
    echo ""

    # Step 2: Deploy iptables segmentation rules
    setup_iptables_segmentation
    echo ""

    # Step 3: Configure DNS split resolution
    setup_dns_split
    echo ""

    log_step "============================================"
    log_step "  Split Tunnel Deployment Complete"
    log_step "============================================"
    echo ""
    log_info "Summary:"
    log_info "  [OK] Network segments: VPN(${VPN_SUBNET}), Services(${SERVICE_SUBNET}), Docker(${DOCKER_SUBNET})"
    log_info "  [OK] iptables: VPN->Services ACCEPT, Docker->Mihomo ACCEPT, External->Services DROP"
    log_info "  [OK] DNS split: fake-ip mode, AI->DoH tunnel, CN->DoH direct"
    echo ""
    log_info "Network architecture:"
    log_info "  VPN Clients (${VPN_SUBNET})"
    log_info "       |"
    log_info "       v"
    log_info "  Service Network (${SERVICE_SUBNET}) [br-aigw]"
    log_info "       |"
    log_info "       +---> Mihomo DNS (fake-ip :53)"
    log_info "       +---> Caddy/New API (:443/:3000)"
    log_info "       +---> Xray tunnel -> Server B -> AI APIs"
    log_info "       |"
    log_info "  Docker Network (${DOCKER_SUBNET}) [docker0]"
    log_info "       |"
    log_info "       +---> New API container -> Mihomo proxy -> Xray tunnel"
    echo ""
    log_info "Management commands:"
    log_info "  iptables status: bash ${IPTABLES_RULES_DEST} status"
    log_info "  Mihomo config:   cat ${MIHOMO_CONFIG}"
    log_info "  Mihomo control:  curl http://127.0.0.1:9090"
    log_info "  Flush firewall:  bash ${IPTABLES_RULES_DEST} flush"
}

# =============================================================================
# Main execution - run deploy_split_tunnel if script is executed directly
# =============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Require root privileges
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "This script must be run as root."
        exit 1
    fi
    deploy_split_tunnel
fi
