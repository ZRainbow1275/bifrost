# =============================================================================
# Bifrost - WireGuard Client Configuration Template
# =============================================================================
# This template is rendered per-user by vpn.sh:create_vpn_user().
#
# Template variables:
#   {{CLIENT_PRIVATE_KEY}}   - Client's WireGuard private key
#   {{CLIENT_ADDRESS}}       - Client's assigned VPN IP (e.g., 10.8.0.2/32)
#   {{DNS_SERVERS}}          - DNS servers (e.g., 10.8.0.1)
#   {{SERVER_PUBLIC_KEY}}    - Server's WireGuard public key
#   {{PRESHARED_KEY}}        - Per-peer preshared key (post-quantum defense)
#   {{SERVER_ENDPOINT}}      - Server IP:Port (e.g., 1.2.3.4:51820)
#   {{ALLOWED_IPS}}          - Routed subnets (10.8.0.0/24,172.16.0.0/24)
#   {{PERSISTENT_KEEPALIVE}} - Keepalive interval in seconds (25)
# =============================================================================
# SECURITY NOTICE: This file contains your private key.
# - Do NOT share this file with anyone.
# - Do NOT commit this file to version control.
# - If compromised, contact your IT admin immediately to revoke and reissue.
# =============================================================================

[Interface]
# Client private key (unique per device, never leaves this device)
PrivateKey = {{CLIENT_PRIVATE_KEY}}

# VPN IP address assigned to this client
Address = {{CLIENT_ADDRESS}}

# DNS servers used when VPN is active
# Routes DNS queries through the VPN gateway for internal resolution
DNS = {{DNS_SERVERS}}

# MTU optimized for WireGuard: Ethernet 1500 minus ~80 bytes WireGuard overhead.
# 1420 is the WireGuard recommended default for IPv4. If you experience
# fragmentation issues (e.g., double-NAT), try lowering to 1280 (IPv6 minimum).
MTU = 1420

[Peer]
# VPN server's public key (verifies server identity)
PublicKey = {{SERVER_PUBLIC_KEY}}

# Preshared key for additional symmetric encryption layer
# Provides post-quantum resistance on top of Curve25519
PresharedKey = {{PRESHARED_KEY}}

# VPN server endpoint (public IP and WireGuard port)
Endpoint = {{SERVER_ENDPOINT}}

# Networks routed through the VPN tunnel:
#   10.8.0.0/24   - VPN peer network (communicate with other VPN clients)
#   172.16.0.0/24  - Internal services (New API, monitoring, etc.)
# NOTE: Only company traffic is routed through VPN (split tunneling).
#       Your regular internet traffic goes through your normal connection.
AllowedIPs = {{ALLOWED_IPS}}

# Send keepalive packets every 25 seconds to maintain NAT mappings.
# Essential for clients behind NAT/firewalls.
PersistentKeepalive = {{PERSISTENT_KEEPALIVE}}
