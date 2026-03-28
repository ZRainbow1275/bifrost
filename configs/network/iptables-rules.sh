#!/usr/bin/env bash
###############################################################################
# Bifrost - Complete iptables Ruleset
#
# Implements network segmentation and split-tunneling firewall rules:
#
#   Network Segments:
#     10.8.0.0/24   - VPN clients (WireGuard/OpenVPN)
#     172.16.0.0/24 - Service network (Xray, Caddy, New API)
#     172.17.0.0/16 - Docker default bridge network
#
#   Traffic Flow Rules:
#     VPN clients   -> Service network  : ACCEPT (authenticated users)
#     Docker        -> Mihomo proxy     : ACCEPT (container routing)
#     External      -> Service network  : DROP   (no direct access)
#     Service       -> Internet         : ACCEPT (outbound via proxy)
#     Loopback      -> Loopback         : ACCEPT (local services)
#
#   Additionally:
#     - NAT/MASQUERADE for Docker and VPN egress
#     - Rate limiting on SSH and ICMP
#     - Connection tracking for established sessions
#     - Logging of dropped packets for debugging
#
# Usage:
#   bash /opt/bifrost/iptables-rules.sh [apply|save|restore|status]
#
# This script is invoked by scripts/split-tunnel.sh during deployment.
###############################################################################

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

# Network segments
readonly VPN_SUBNET="10.8.0.0/24"
readonly SERVICE_SUBNET="172.16.0.0/24"
readonly DOCKER_SUBNET="172.17.0.0/16"

# Service ports
readonly SSH_PORT="${IPTABLES_SSH_PORT:-22}"
readonly XRAY_PORT="${IPTABLES_XRAY_PORT:-443}"
readonly CADDY_HTTP_PORT=80
readonly CADDY_HTTPS_PORT=443
readonly NEW_API_PORT=3000
readonly MIHOMO_SOCKS_PORT=7891
readonly MIHOMO_MIXED_PORT=7890
readonly MIHOMO_HTTP_PORT=7890  # Same as mixed-port; Mihomo uses a single port for HTTP+SOCKS5
readonly MIHOMO_DNS_PORT=1053
readonly NETDATA_PORT=19999
readonly XUI_PORT="${IPTABLES_XUI_PORT:-2053}"

# Rate limiting
readonly SSH_RATE_LIMIT="10/minute"
readonly SSH_RATE_BURST=20
readonly ICMP_RATE_LIMIT="10/second"
readonly ICMP_RATE_BURST=20

# Interfaces (auto-detected if empty)
readonly VPN_INTERFACE="${IPTABLES_VPN_IFACE:-}"
readonly DOCKER_INTERFACE="${IPTABLES_DOCKER_IFACE:-docker0}"

# Persistent rules file
readonly RULES_SAVE_FILE="/etc/iptables/bifrost.rules"
readonly ALLOW_IPTABLES_TAKEOVER="${BIFROST_ALLOW_IPTABLES_TAKEOVER:-0}"

# Log prefix for dropped packets
readonly LOG_PREFIX="AI-GW-DROP: "
readonly LOG_RATE_LIMIT="5/minute"

# =============================================================================
# Helper Functions
# =============================================================================

log_fw() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [iptables] $*"
}

detect_conflicting_firewall_owners() {
    if iptables -S INPUT 2>/dev/null | grep -q -- '-A INPUT -j VPN_INPUT'; then
        return 0
    fi
    if iptables -S FORWARD 2>/dev/null | grep -q -- '-A FORWARD -j VPN_FORWARD'; then
        return 0
    fi
    if iptables -L VPN_INPUT -n >/dev/null 2>&1; then
        return 0
    fi
    if iptables -L VPN_FORWARD -n >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

mihomo_tcp_ports() {
    printf '%s\n' "${MIHOMO_SOCKS_PORT}" "${MIHOMO_HTTP_PORT}" "${MIHOMO_MIXED_PORT}" | awk '!seen[$0]++'
}

ensure_firewall_takeover_allowed() {
    if [[ "${ALLOW_IPTABLES_TAKEOVER}" == "1" ]]; then
        return 0
    fi

    if detect_conflicting_firewall_owners; then
        log_fw "ERROR: Existing VPN iptables chains detected (VPN_INPUT/VPN_FORWARD)."
        log_fw "ERROR: Refusing to take over the firewall because this would remove VPN isolation rules."
        log_fw "ERROR: Remove the VPN firewall first, or rerun with BIFROST_ALLOW_IPTABLES_TAKEOVER=1 if takeover is intentional."
        return 1
    fi

    return 0
}

# Detect the primary public-facing network interface
detect_wan_interface() {
    ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'
}

# Detect VPN interface
detect_vpn_interface() {
    if [[ -n "${VPN_INTERFACE}" ]]; then
        echo "${VPN_INTERFACE}"
        return 0
    fi

    for iface in wg0 wg1 tun0 tun1; do
        if ip link show "${iface}" &>/dev/null 2>&1; then
            echo "${iface}"
            return 0
        fi
    done

    echo ""
}

# Flush all existing rules (clean slate)
flush_rules() {
    ensure_firewall_takeover_allowed || return 1
    log_fw "Flushing all iptables rules..."

    # Flush all chains in filter, nat, mangle tables
    for table in filter nat mangle; do
        iptables -t "${table}" -F 2>/dev/null || true
        iptables -t "${table}" -X 2>/dev/null || true
    done

    # Reset default policies to ACCEPT temporarily
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
}

# =============================================================================
# Rule Application
# =============================================================================

apply_rules() {
    ensure_firewall_takeover_allowed || return 1
    local wan_iface
    wan_iface="$(detect_wan_interface)"
    local vpn_iface
    vpn_iface="$(detect_vpn_interface)"

    if [[ -z "${wan_iface}" ]]; then
        log_fw "WARNING: Could not detect WAN interface. Using 'eth0' as fallback."
        wan_iface="eth0"
    fi

    log_fw "WAN interface: ${wan_iface}"
    log_fw "VPN interface: ${vpn_iface:-none}"
    log_fw "Docker interface: ${DOCKER_INTERFACE}"

    # -------------------------------------------------------------------------
    # Step 0: Disable UFW if active (this script takes over firewall management)
    # -------------------------------------------------------------------------
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
        log_fw "Disabling UFW (split-tunnel iptables takes over firewall management)..."
        ufw disable 2>/dev/null || true
    fi

    # -------------------------------------------------------------------------
    # Step 1: Flush existing rules
    # -------------------------------------------------------------------------
    flush_rules

    # -------------------------------------------------------------------------
    # Step 2: Create custom chains
    # -------------------------------------------------------------------------
    log_fw "Creating custom chains..."

    iptables -N AI_GW_INPUT 2>/dev/null || true
    iptables -N AI_GW_FORWARD 2>/dev/null || true
    iptables -N AI_GW_LOG_DROP 2>/dev/null || true

    # Log-and-drop chain
    iptables -A AI_GW_LOG_DROP -m limit --limit "${LOG_RATE_LIMIT}" -j LOG \
        --log-prefix "${LOG_PREFIX}" --log-level 4
    iptables -A AI_GW_LOG_DROP -j DROP

    # -------------------------------------------------------------------------
    # Step 3: Default policies
    # -------------------------------------------------------------------------
    log_fw "Setting default policies (DROP INPUT/FORWARD, ACCEPT OUTPUT)..."

    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT

    # -------------------------------------------------------------------------
    # Step 4: Loopback - always allow
    # -------------------------------------------------------------------------
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT

    # -------------------------------------------------------------------------
    # Step 5: Established and related connections
    # -------------------------------------------------------------------------
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # Drop invalid packets
    iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
    iptables -A FORWARD -m conntrack --ctstate INVALID -j DROP

    # -------------------------------------------------------------------------
    # Step 6: SSH with rate limiting
    # -------------------------------------------------------------------------
    log_fw "Configuring SSH access (port ${SSH_PORT}) with rate limiting..."

    iptables -A INPUT -p tcp --dport "${SSH_PORT}" \
        -m conntrack --ctstate NEW \
        -m limit --limit "${SSH_RATE_LIMIT}" --limit-burst "${SSH_RATE_BURST}" \
        -j ACCEPT

    # -------------------------------------------------------------------------
    # Step 7: ICMP with rate limiting
    # -------------------------------------------------------------------------
    iptables -A INPUT -p icmp --icmp-type echo-request \
        -m limit --limit "${ICMP_RATE_LIMIT}" --limit-burst "${ICMP_RATE_BURST}" \
        -j ACCEPT
    iptables -A INPUT -p icmp --icmp-type echo-reply -j ACCEPT
    iptables -A INPUT -p icmp --icmp-type destination-unreachable -j ACCEPT
    iptables -A INPUT -p icmp --icmp-type time-exceeded -j ACCEPT

    # -------------------------------------------------------------------------
    # Step 8: Service ports (external access)
    # -------------------------------------------------------------------------
    log_fw "Opening service ports..."

    # Caddy (HTTP/HTTPS) - public facing
    iptables -A INPUT -p tcp --dport "${CADDY_HTTP_PORT}" -j ACCEPT
    iptables -A INPUT -p tcp --dport "${CADDY_HTTPS_PORT}" -j ACCEPT

    # Xray port (if different from Caddy HTTPS)
    if [[ "${XRAY_PORT}" -ne "${CADDY_HTTPS_PORT}" ]]; then
        iptables -A INPUT -p tcp --dport "${XRAY_PORT}" -j ACCEPT
    fi

    # 3x-ui panel - restrict to VPN and service subnet
    iptables -A INPUT -p tcp --dport "${XUI_PORT}" -s "${VPN_SUBNET}" -j ACCEPT
    iptables -A INPUT -p tcp --dport "${XUI_PORT}" -s "${SERVICE_SUBNET}" -j ACCEPT
    iptables -A INPUT -p tcp --dport "${XUI_PORT}" -s 127.0.0.0/8 -j ACCEPT

    # Netdata monitoring - localhost and internal only
    iptables -A INPUT -p tcp --dport "${NETDATA_PORT}" -s 127.0.0.0/8 -j ACCEPT
    iptables -A INPUT -p tcp --dport "${NETDATA_PORT}" -s "${VPN_SUBNET}" -j ACCEPT
    iptables -A INPUT -p tcp --dport "${NETDATA_PORT}" -s "${SERVICE_SUBNET}" -j ACCEPT

    # WireGuard VPN endpoint - must be accessible from external networks
    iptables -A INPUT -p udp --dport 51820 -j ACCEPT

    # -------------------------------------------------------------------------
    # Step 9: VPN client access to services
    # -------------------------------------------------------------------------
    if [[ -n "${vpn_iface}" ]]; then
        log_fw "Configuring VPN client access (${vpn_iface} / ${VPN_SUBNET})..."

        # VPN clients can access service network
        iptables -A INPUT -i "${vpn_iface}" -s "${VPN_SUBNET}" -j ACCEPT

        # VPN -> Service subnet forwarding
        iptables -A FORWARD -i "${vpn_iface}" -s "${VPN_SUBNET}" \
            -d "${SERVICE_SUBNET}" -j ACCEPT

        # VPN -> Internet (through proxy)
        iptables -A FORWARD -i "${vpn_iface}" -s "${VPN_SUBNET}" -j ACCEPT
    fi

    # -------------------------------------------------------------------------
    # Step 10: Docker -> Mihomo proxy access
    # -------------------------------------------------------------------------
    log_fw "Configuring Docker -> Mihomo proxy access..."

    # Docker containers can reach Mihomo proxy ports
    local mihomo_port=""
    while IFS= read -r mihomo_port; do
        iptables -A INPUT -i "${DOCKER_INTERFACE}" -s "${DOCKER_SUBNET}" \
            -p tcp --dport "${mihomo_port}" -j ACCEPT
    done < <(mihomo_tcp_ports)

    # Docker containers can use Mihomo DNS
    iptables -A INPUT -i "${DOCKER_INTERFACE}" -s "${DOCKER_SUBNET}" \
        -p udp --dport "${MIHOMO_DNS_PORT}" -j ACCEPT
    iptables -A INPUT -i "${DOCKER_INTERFACE}" -s "${DOCKER_SUBNET}" \
        -p tcp --dport "${MIHOMO_DNS_PORT}" -j ACCEPT

    # Docker containers can access New API port (inter-container)
    iptables -A INPUT -i "${DOCKER_INTERFACE}" -s "${DOCKER_SUBNET}" \
        -p tcp --dport "${NEW_API_PORT}" -j ACCEPT

    # Docker FORWARD rules
    iptables -A FORWARD -i "${DOCKER_INTERFACE}" -o "${wan_iface}" -j ACCEPT
    iptables -A FORWARD -i "${wan_iface}" -o "${DOCKER_INTERFACE}" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # -------------------------------------------------------------------------
    # Step 11: Block external access to service network
    # -------------------------------------------------------------------------
    log_fw "Blocking external access to service/internal networks..."

    # New API - only accessible from localhost, Docker, VPN, and service network
    # NOTE: ACCEPT rules must precede the blanket DROP below to avoid being shadowed
    iptables -A INPUT -p tcp --dport "${NEW_API_PORT}" -s 127.0.0.0/8 -j ACCEPT
    iptables -A INPUT -p tcp --dport "${NEW_API_PORT}" -s "${DOCKER_SUBNET}" -j ACCEPT
    iptables -A INPUT -p tcp --dport "${NEW_API_PORT}" -s "${VPN_SUBNET}" -j ACCEPT
    iptables -A INPUT -p tcp --dport "${NEW_API_PORT}" -s "${SERVICE_SUBNET}" -j ACCEPT
    iptables -A INPUT -p tcp --dport "${NEW_API_PORT}" -j AI_GW_LOG_DROP

    # Mihomo ports - only localhost, Docker, and VPN
    for port in $(mihomo_tcp_ports); do
        iptables -A INPUT -p tcp --dport "${port}" -s 127.0.0.0/8 -j ACCEPT
        iptables -A INPUT -p tcp --dport "${port}" -s "${VPN_SUBNET}" -j ACCEPT
        iptables -A INPUT -p tcp --dport "${port}" -s "${SERVICE_SUBNET}" -j ACCEPT
        iptables -A INPUT -p tcp --dport "${port}" -j AI_GW_LOG_DROP
    done

    # Drop external traffic destined for internal subnets (after service-specific ACCEPT rules)
    iptables -A INPUT -i "${wan_iface}" -d "${SERVICE_SUBNET}" -j AI_GW_LOG_DROP
    iptables -A INPUT -i "${wan_iface}" -d "${VPN_SUBNET}" -j AI_GW_LOG_DROP

    # -------------------------------------------------------------------------
    # Step 12: NAT / MASQUERADE
    # -------------------------------------------------------------------------
    log_fw "Configuring NAT/MASQUERADE..."

    # Masquerade Docker traffic going to WAN
    iptables -t nat -A POSTROUTING -s "${DOCKER_SUBNET}" \
        -o "${wan_iface}" -j MASQUERADE

    # Masquerade VPN client traffic going to WAN
    if [[ -n "${vpn_iface}" ]]; then
        iptables -t nat -A POSTROUTING -s "${VPN_SUBNET}" \
            -o "${wan_iface}" -j MASQUERADE
    fi

    # -------------------------------------------------------------------------
    # Step 13: Final default drop with logging
    # -------------------------------------------------------------------------
    iptables -A INPUT -j AI_GW_LOG_DROP
    iptables -A FORWARD -j AI_GW_LOG_DROP

    log_fw "iptables rules applied successfully."
}

# =============================================================================
# Save / Restore / Status
# =============================================================================

save_rules() {
    local save_dir
    save_dir="$(dirname "${RULES_SAVE_FILE}")"
    mkdir -p "${save_dir}"

    iptables-save > "${RULES_SAVE_FILE}"
    chmod 600 "${RULES_SAVE_FILE}"
    log_fw "Rules saved to ${RULES_SAVE_FILE}"

    # Also install iptables-persistent if available
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save 2>/dev/null || true
        log_fw "Rules also saved via netfilter-persistent."
    fi
}

restore_rules() {
    if [[ ! -f "${RULES_SAVE_FILE}" ]]; then
        log_fw "ERROR: No saved rules found at ${RULES_SAVE_FILE}"
        return 1
    fi

    iptables-restore < "${RULES_SAVE_FILE}"
    log_fw "Rules restored from ${RULES_SAVE_FILE}"
}

show_status() {
    echo "=== Filter Table ==="
    iptables -L -n -v --line-numbers 2>/dev/null
    echo ""
    echo "=== NAT Table ==="
    iptables -t nat -L -n -v --line-numbers 2>/dev/null
    echo ""
    echo "=== Custom Chains ==="
    iptables -L AI_GW_INPUT -n -v 2>/dev/null || echo "(AI_GW_INPUT not found)"
    iptables -L AI_GW_FORWARD -n -v 2>/dev/null || echo "(AI_GW_FORWARD not found)"
    iptables -L AI_GW_LOG_DROP -n -v 2>/dev/null || echo "(AI_GW_LOG_DROP not found)"
}

# =============================================================================
# Main
# =============================================================================

main() {
    local action="${1:-apply}"

    case "${action}" in
        apply)
            apply_rules
            save_rules
            ;;
        save)
            save_rules
            ;;
        restore)
            restore_rules
            ;;
        status)
            show_status
            ;;
        flush)
            flush_rules
            log_fw "All rules flushed. Default policies set to ACCEPT."
            ;;
        *)
            echo "Usage: $0 {apply|save|restore|status|flush}"
            exit 1
            ;;
    esac
}

main "$@"
