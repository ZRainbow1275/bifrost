#!/usr/bin/env bash
# =============================================================================
# AI Gateway Bridge - VPN Network Isolation Rules (iptables)
# =============================================================================
# This script configures iptables rules to enforce VPN-only access to
# internal services. It is called by vpn.sh:setup_vpn_firewall().
#
# Expected environment variables (set by vpn.sh):
#   PRIMARY_IFACE   - Primary network interface (e.g., eth0)
#   VPN_SUBNET      - VPN client subnet (10.8.0.0/24)
#   SERVICE_SUBNET  - Internal service subnet (172.16.0.0/24)
#   WG_INTERFACE    - WireGuard interface name (wg0)
#
# Architecture:
#   Internet --[BIFROST_WG_PORT/udp]--> WireGuard --> VPN Clients (10.8.0.0/24)
#                                                |
#                                                v
#                                        Services (172.16.0.0/24)
#                                          - New API (:3000)
#                                          - Monitoring (:19999)
#                                          - Admin Portal (:13000)
#
#   Internet --[direct]--> Services = BLOCKED
#
# All rules are idempotent (safe to run multiple times).
# =============================================================================

set -euo pipefail

[[ -f /etc/bifrost.env ]] && source /etc/bifrost.env
WG_PORT="${BIFROST_WG_PORT:-51820}"

# =============================================================================
# Validate required environment variables
# =============================================================================

: "${PRIMARY_IFACE:?ERROR: PRIMARY_IFACE environment variable is required}"
: "${VPN_SUBNET:?ERROR: VPN_SUBNET environment variable is required}"
: "${SERVICE_SUBNET:?ERROR: SERVICE_SUBNET environment variable is required}"
: "${WG_INTERFACE:?ERROR: WG_INTERFACE environment variable is required}"
# DOCKER_SUBNET is optional; when set, Docker containers may reach proxy ports.
DOCKER_SUBNET="${DOCKER_SUBNET:-172.17.0.0/16}"

echo "[iptables-vpn] Applying VPN network isolation rules..."
echo "[iptables-vpn] PRIMARY_IFACE=${PRIMARY_IFACE}"
echo "[iptables-vpn] VPN_SUBNET=${VPN_SUBNET}"
echo "[iptables-vpn] SERVICE_SUBNET=${SERVICE_SUBNET}"
echo "[iptables-vpn] WG_INTERFACE=${WG_INTERFACE}"

# =============================================================================
# Section 1 : Clean up previous VPN rules (idempotent)
# =============================================================================

echo "[iptables-vpn] Cleaning up existing VPN chains..."

# Remove references from built-in chains first
iptables -D FORWARD -j VPN_FORWARD 2>/dev/null || true
iptables -D INPUT -j VPN_INPUT 2>/dev/null || true
iptables -t nat -D POSTROUTING -j VPN_NAT 2>/dev/null || true

# Flush and delete custom chains
for chain in VPN_FORWARD VPN_INPUT; do
    iptables -F "${chain}" 2>/dev/null || true
    iptables -X "${chain}" 2>/dev/null || true
done

for chain in VPN_NAT; do
    iptables -t nat -F "${chain}" 2>/dev/null || true
    iptables -t nat -X "${chain}" 2>/dev/null || true
done

echo "[iptables-vpn] Previous rules cleaned."

# =============================================================================
# Section 2 : NAT Rules (POSTROUTING)
# =============================================================================

echo "[iptables-vpn] Configuring NAT rules..."

iptables -t nat -N VPN_NAT

# Masquerade VPN traffic going to the internet via primary interface
iptables -t nat -A VPN_NAT \
    -s "${VPN_SUBNET}" \
    -o "${PRIMARY_IFACE}" \
    -j MASQUERADE \
    -m comment --comment "VPN: masquerade outbound traffic"

# Masquerade VPN traffic going to the service subnet
iptables -t nat -A VPN_NAT \
    -s "${VPN_SUBNET}" \
    -d "${SERVICE_SUBNET}" \
    -j MASQUERADE \
    -m comment --comment "VPN: masquerade VPN-to-services traffic"

# Attach to POSTROUTING
iptables -t nat -A POSTROUTING -j VPN_NAT

echo "[iptables-vpn] NAT rules applied."

# =============================================================================
# Section 3 : FORWARD Rules
# =============================================================================

echo "[iptables-vpn] Configuring FORWARD rules..."

iptables -N VPN_FORWARD

# Allow established/related connections (stateful)
iptables -A VPN_FORWARD \
    -m conntrack --ctstate ESTABLISHED,RELATED \
    -j ACCEPT \
    -m comment --comment "VPN: allow established connections"

# VPN clients -> service subnet: ALLOW
iptables -A VPN_FORWARD \
    -s "${VPN_SUBNET}" \
    -d "${SERVICE_SUBNET}" \
    -j ACCEPT \
    -m comment --comment "VPN: allow VPN-to-services"

# VPN clients -> internet (for tunnel/proxy traffic): ALLOW
iptables -A VPN_FORWARD \
    -s "${VPN_SUBNET}" \
    -o "${PRIMARY_IFACE}" \
    -j ACCEPT \
    -m comment --comment "VPN: allow VPN-to-internet"

# Internet -> VPN clients (return traffic): ALLOW (stateful handles this,
# but explicit rule for clarity)
iptables -A VPN_FORWARD \
    -i "${PRIMARY_IFACE}" \
    -d "${VPN_SUBNET}" \
    -m conntrack --ctstate ESTABLISHED,RELATED \
    -j ACCEPT \
    -m comment --comment "VPN: allow return traffic to VPN clients"

# VPN client <-> VPN client: ALLOW (peer communication)
iptables -A VPN_FORWARD \
    -s "${VPN_SUBNET}" \
    -d "${VPN_SUBNET}" \
    -j ACCEPT \
    -m comment --comment "VPN: allow inter-client communication"

# ===== CRITICAL: Block external access to service subnet =====
# Any traffic NOT from the VPN subnet to the service subnet is DROPPED.
# LOG must come BEFORE DROP — iptables processes rules sequentially and
# DROP terminates the chain, so a LOG after DROP would never execute.

# Log blocked external-to-services traffic (rate-limited)
iptables -A VPN_FORWARD \
    -d "${SERVICE_SUBNET}" \
    -j LOG \
    --log-prefix "[VPN-FW-DROP] " \
    --log-level 4 \
    -m limit --limit 5/min --limit-burst 10 \
    -m comment --comment "VPN: log blocked external-to-services"

# Drop external access to service subnet
iptables -A VPN_FORWARD \
    -d "${SERVICE_SUBNET}" \
    -j DROP \
    -m comment --comment "VPN: BLOCK external-to-services"

# Attach to FORWARD chain
iptables -A FORWARD -j VPN_FORWARD

echo "[iptables-vpn] FORWARD rules applied."

# =============================================================================
# Section 4 : INPUT Rules (Service Port Protection)
# =============================================================================

echo "[iptables-vpn] Configuring INPUT rules..."

iptables -N VPN_INPUT

# --- Always allow loopback ---
iptables -A VPN_INPUT \
    -i lo \
    -j ACCEPT \
    -m comment --comment "VPN: allow loopback"

# --- Allow established connections ---
iptables -A VPN_INPUT \
    -m conntrack --ctstate ESTABLISHED,RELATED \
    -j ACCEPT \
    -m comment --comment "VPN: allow established INPUT"

# --- Public ports (accessible from anywhere) ---

# WireGuard endpoint
iptables -A VPN_INPUT \
    -p udp --dport "${WG_PORT}" \
    -j ACCEPT \
    -m comment --comment "VPN: WireGuard endpoint (public)"

# HTTPS (Caddy/reverse proxy)
iptables -A VPN_INPUT \
    -p tcp --dport 443 \
    -j ACCEPT \
    -m comment --comment "VPN: HTTPS endpoint (public)"

# HTTP (redirect to HTTPS)
iptables -A VPN_INPUT \
    -p tcp --dport 80 \
    -j ACCEPT \
    -m comment --comment "VPN: HTTP redirect (public)"

# SSH (keep existing SSH rules from security.sh)
# We do NOT override SSH rules here.

# --- VPN-only ports (accessible ONLY from VPN subnet) ---

# New API (port 3000)
iptables -A VPN_INPUT \
    -p tcp --dport 3000 \
    -s "${VPN_SUBNET}" \
    -j ACCEPT \
    -m comment --comment "VPN: New API (VPN-only)"
iptables -A VPN_INPUT \
    -p tcp --dport 3000 \
    -j DROP \
    -m comment --comment "VPN: New API BLOCK external"

# Monitoring - Netdata (port 19999)
iptables -A VPN_INPUT \
    -p tcp --dport 19999 \
    -s "${VPN_SUBNET}" \
    -j ACCEPT \
    -m comment --comment "VPN: Netdata monitoring (VPN-only)"
iptables -A VPN_INPUT \
    -p tcp --dport 19999 \
    -j DROP \
    -m comment --comment "VPN: Netdata BLOCK external"

# Firezone admin portal (port 13000)
iptables -A VPN_INPUT \
    -p tcp --dport 13000 \
    -s "${VPN_SUBNET}" \
    -j ACCEPT \
    -m comment --comment "VPN: Firezone admin (VPN-only)"
iptables -A VPN_INPUT \
    -p tcp --dport 13000 \
    -j DROP \
    -m comment --comment "VPN: Firezone admin BLOCK external"

# Headscale control (port 8080)
iptables -A VPN_INPUT \
    -p tcp --dport 8080 \
    -s "${VPN_SUBNET}" \
    -j ACCEPT \
    -m comment --comment "VPN: Headscale (VPN-only)"
iptables -A VPN_INPUT \
    -p tcp --dport 8080 \
    -j DROP \
    -m comment --comment "VPN: Headscale BLOCK external"

# Prometheus metrics (port 9090)
iptables -A VPN_INPUT \
    -p tcp --dport 9090 \
    -s "${VPN_SUBNET}" \
    -j ACCEPT \
    -m comment --comment "VPN: Prometheus metrics (VPN-only)"
iptables -A VPN_INPUT \
    -p tcp --dport 9090 \
    -j DROP \
    -m comment --comment "VPN: Prometheus metrics BLOCK external"

# Grafana (port 3001)
iptables -A VPN_INPUT \
    -p tcp --dport 3001 \
    -s "${VPN_SUBNET}" \
    -j ACCEPT \
    -m comment --comment "VPN: Grafana (VPN-only)"
iptables -A VPN_INPUT \
    -p tcp --dport 3001 \
    -j DROP \
    -m comment --comment "VPN: Grafana BLOCK external"

# STUN/DERP for Headscale (port 3478)
iptables -A VPN_INPUT \
    -p udp --dport 3478 \
    -j ACCEPT \
    -m comment --comment "VPN: STUN/DERP (public for NAT traversal)"

# --- Proxy ports: VPN/localhost/Docker only, block external ---
# Xray HTTP proxy (port 10809) - binds 0.0.0.0 for Docker access
iptables -A VPN_INPUT \
    -p tcp --dport 10809 \
    -s 127.0.0.0/8 \
    -j ACCEPT \
    -m comment --comment "VPN: Xray HTTP proxy (localhost)"
iptables -A VPN_INPUT \
    -p tcp --dport 10809 \
    -s "${VPN_SUBNET}" \
    -j ACCEPT \
    -m comment --comment "VPN: Xray HTTP proxy (VPN-only)"
iptables -A VPN_INPUT \
    -p tcp --dport 10809 \
    -s "${DOCKER_SUBNET}" \
    -j ACCEPT \
    -m comment --comment "VPN: Xray HTTP proxy (Docker containers)"
iptables -A VPN_INPUT \
    -p tcp --dport 10809 \
    -j DROP \
    -m comment --comment "VPN: Xray HTTP proxy BLOCK external"

# Mihomo mixed proxy (port 7890) - binds 0.0.0.0 for Docker access
iptables -A VPN_INPUT \
    -p tcp --dport 7890 \
    -s 127.0.0.0/8 \
    -j ACCEPT \
    -m comment --comment "VPN: Mihomo mixed proxy (localhost)"
iptables -A VPN_INPUT \
    -p tcp --dport 7890 \
    -s "${VPN_SUBNET}" \
    -j ACCEPT \
    -m comment --comment "VPN: Mihomo mixed proxy (VPN-only)"
iptables -A VPN_INPUT \
    -p tcp --dport 7890 \
    -s "${DOCKER_SUBNET}" \
    -j ACCEPT \
    -m comment --comment "VPN: Mihomo mixed proxy (Docker containers)"
iptables -A VPN_INPUT \
    -p tcp --dport 7890 \
    -j DROP \
    -m comment --comment "VPN: Mihomo mixed proxy BLOCK external"

# Mihomo SOCKS5 proxy (port 7891)
iptables -A VPN_INPUT \
    -p tcp --dport 7891 \
    -s 127.0.0.0/8 \
    -j ACCEPT \
    -m comment --comment "VPN: Mihomo SOCKS5 (localhost)"
iptables -A VPN_INPUT \
    -p tcp --dport 7891 \
    -s "${VPN_SUBNET}" \
    -j ACCEPT \
    -m comment --comment "VPN: Mihomo SOCKS5 (VPN-only)"
iptables -A VPN_INPUT \
    -p tcp --dport 7891 \
    -s "${DOCKER_SUBNET}" \
    -j ACCEPT \
    -m comment --comment "VPN: Mihomo SOCKS5 (Docker containers)"
iptables -A VPN_INPUT \
    -p tcp --dport 7891 \
    -j DROP \
    -m comment --comment "VPN: Mihomo SOCKS5 BLOCK external"

# --- Log rejected INPUT (rate-limited) ---
iptables -A VPN_INPUT \
    -j LOG \
    --log-prefix "[VPN-IN-DROP] " \
    --log-level 4 \
    -m limit --limit 5/min --limit-burst 10 \
    -m comment --comment "VPN: log dropped input packets"

# --- Default DROP for VPN_INPUT chain ---
# CRITICAL: Without this, unmatched packets fall through to the parent INPUT
# chain. If no other firewall (UFW/firewalld) sets default DROP, proxy ports
# bound on 0.0.0.0 (10809, 7890) would be reachable from the internet.
iptables -A VPN_INPUT \
    -j DROP \
    -m comment --comment "VPN: default DROP for unmatched input"

# Attach to INPUT chain
iptables -A INPUT -j VPN_INPUT

echo "[iptables-vpn] INPUT rules applied."

# =============================================================================
# Section 5 : WireGuard Interface Rules
# =============================================================================

echo "[iptables-vpn] Configuring WireGuard interface rules..."

# Allow all traffic on the WireGuard interface (already decrypted/authenticated)
iptables -A INPUT \
    -i "${WG_INTERFACE}" \
    -j ACCEPT \
    -m comment --comment "VPN: accept all from WG interface"

iptables -A OUTPUT \
    -o "${WG_INTERFACE}" \
    -j ACCEPT \
    -m comment --comment "VPN: accept all to WG interface"

echo "[iptables-vpn] WireGuard interface rules applied."

# =============================================================================
# Section 6 : Connection Tracking Optimization
# =============================================================================

echo "[iptables-vpn] Optimizing connection tracking..."

# Increase conntrack table size for enterprise use (30-100 users)
if [[ -f /proc/sys/net/netfilter/nf_conntrack_max ]]; then
    echo 65536 > /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || true
fi

# Reduce timeout for established connections (default is too high)
if [[ -f /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established ]]; then
    echo 3600 > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established 2>/dev/null || true
fi

echo "[iptables-vpn] Connection tracking optimized."

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "[iptables-vpn] ============================================"
echo "[iptables-vpn] VPN Network Isolation Rules Applied"
echo "[iptables-vpn] ============================================"
echo "[iptables-vpn] PUBLIC ports  : ${WG_PORT}/udp (WG), 443/tcp (HTTPS), 80/tcp (HTTP)"
echo "[iptables-vpn] VPN-ONLY ports: 3000 (API), 19999 (Netdata), 13000 (Firezone)"
echo "[iptables-vpn]                 8080 (Headscale), 9090 (Prometheus), 3001 (Grafana)"
echo "[iptables-vpn] BLOCKED       : External -> Service subnet (${SERVICE_SUBNET})"
echo "[iptables-vpn] NAT           : VPN (${VPN_SUBNET}) -> Internet via ${PRIMARY_IFACE}"
echo "[iptables-vpn] ============================================"
echo "[iptables-vpn] Done."
