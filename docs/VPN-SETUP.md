# Enterprise VPN Setup Guide

Bifrost - VPN as the First Security Gate

---

## Overview

The VPN is the **FIRST and mandatory gate** in the Bifrost architecture. All employees **MUST** connect to the VPN before accessing any internal service.

### Architecture

```
Employee Device
    |
    | WireGuard (UDP 51820)
    v
VPN Gateway (10.8.0.1)
    |
    +---> New API (:3000)         [VPN-only access]
    +---> Mihomo -> Xray -> Server B  [AI API proxy]
    +---> Monitoring (:19999)     [VPN-only access]
    +---> Admin Portal (:13000)   [VPN-only access]
```

### Network Segments

| Segment | Subnet | Purpose |
|---------|--------|---------|
| VPN Clients | `10.8.0.0/24` | Employee VPN addresses |
| Internal Services | `172.16.0.0/24` | New API, monitoring, admin portals |
| WireGuard Endpoint | `<Server-IP>:51820/udp` | Public VPN entry point |

---

## Part 1: Administrator Guide

### Prerequisites

- Server running Ubuntu 22.04+, Debian 12+, CentOS 9+, or Rocky 9+
- Root access
- Minimum 1 CPU core, 512MB RAM, 2GB disk
- Port 51820/UDP reachable from the internet
- A domain name (recommended) for TLS on admin portal

### Quick Deployment

```bash
# Clone the project
git clone <repository-url> /opt/bifrost
cd /opt/bifrost

# Run VPN deployment
sudo bash scripts/vpn.sh deploy
```

The interactive wizard will guide you through:

1. **Prerequisites check** - OS, kernel, memory, disk
2. **VPN type selection** - Firezone (recommended) or Headscale
3. **Network configuration** - Subnets, IP forwarding, bridge networks
4. **VPN server deployment** - Docker containers or systemd service
5. **Firewall configuration** - iptables rules for network isolation

### Option A: Firezone (Recommended)

Firezone provides a Docker-based WireGuard management platform with a web admin portal.

**Best for:** Teams wanting a GUI for user/device management, MFA, and OIDC integration.

**Components deployed:**

- PostgreSQL database (internal, not exposed)
- Firezone application (admin portal on port 13000, VPN-only)
- WireGuard kernel interface (port 51820/UDP, public)

**Post-deployment:**

1. Access the admin portal: `https://vpn.yourdomain.com:13000`
   (Must be connected via VPN or from the server itself)
2. Log in with the admin credentials shown during deployment
3. **Change the admin password immediately**
4. Configure OIDC if you have an identity provider (Okta, Azure AD, etc.)

### Option B: Headscale

Headscale is a self-hosted Tailscale control server providing mesh VPN with ACL.

**Best for:** Teams wanting mesh networking, where devices can communicate directly without going through a central gateway.

**Components deployed:**

- Headscale server (systemd service)
- Embedded DERP relay for NAT traversal
- SQLite database

**Post-deployment:**

1. Create user namespaces: `headscale users create engineering`
2. Generate pre-auth keys: `headscale preauthkeys create --user engineering --expiration 24h`
3. Share keys with employees (they use Tailscale client)

### User Management

#### Create a new VPN user

```bash
sudo bash scripts/vpn.sh create_user john.doe
```

This generates:
- WireGuard configuration file
- QR code for mobile import
- New API token
- Personalized setup guide

All files are stored in `/etc/bifrost/vpn/users/<username>/`.

#### List all users

```bash
sudo bash scripts/vpn.sh list_users
```

#### Revoke a user

```bash
sudo bash scripts/vpn.sh revoke_user john.doe
```

This will:
- Remove the WireGuard peer from the server
- Securely delete all configuration files (shred)
- Mark the user as revoked in the state file

#### Check VPN status

```bash
sudo bash scripts/vpn.sh status
```

Shows: VPN type, connected peers, port status, network configuration.

### Firewall Rules

The VPN deployment configures iptables with three categories:

**Public ports (accessible from anywhere):**

| Port | Protocol | Service |
|------|----------|---------|
| 51820 | UDP | WireGuard endpoint |
| 443 | TCP | HTTPS (Caddy) |
| 80 | TCP | HTTP redirect |

**VPN-only ports (accessible only from 10.8.0.0/24):**

| Port | Protocol | Service |
|------|----------|---------|
| 3000 | TCP | New API |
| 19999 | TCP | Netdata monitoring |
| 13000 | TCP | Firezone admin portal |
| 8080 | TCP | Headscale control |
| 9090 | TCP | Prometheus metrics |
| 3001 | TCP | Grafana |

**Blocked:**

- All external traffic to the service subnet (172.16.0.0/24)
- All non-whitelisted ports

### Verifying Firewall Rules

```bash
# List all VPN-related iptables rules
sudo iptables -L VPN_INPUT -n -v
sudo iptables -L VPN_FORWARD -n -v
sudo iptables -t nat -L VPN_NAT -n -v

# Test: from an external IP, port 3000 should be unreachable
# Test: from a VPN client (10.8.0.x), port 3000 should be reachable
```

### Reconfiguring Firewall

```bash
# Reapply all firewall rules
sudo bash scripts/vpn.sh menu
# Select "Reconfigure firewall"

# Or directly:
sudo PRIMARY_IFACE=eth0 VPN_SUBNET=10.8.0.0/24 SERVICE_SUBNET=172.16.0.0/24 WG_INTERFACE=wg0 \
    bash configs/vpn/iptables-vpn.sh
```

---

## Part 2: Employee Guide

### What is the VPN?

The company VPN creates a secure, encrypted tunnel between your device and the company's AI services. You **must** connect to the VPN before using any AI tools (Claude, GPT, Copilot, etc.).

### Step 1: Install WireGuard Client

| Platform | Instructions |
|----------|-------------|
| **Windows** | Download from [wireguard.com/install](https://www.wireguard.com/install/) |
| **macOS** | `brew install wireguard-tools` or install from the App Store |
| **Linux (Ubuntu/Debian)** | `sudo apt install wireguard` |
| **Linux (Fedora/RHEL)** | `sudo dnf install wireguard-tools` |
| **iOS** | Install "WireGuard" from the App Store |
| **Android** | Install "WireGuard" from Google Play |

> **For Headscale deployments:** Install the Tailscale client instead from [tailscale.com/download](https://tailscale.com/download).

### Step 2: Import Configuration

Your IT admin will provide you with a configuration file (`wg-yourname.conf`) and optionally a QR code.

**Desktop (Windows/macOS/Linux):**

1. Open the WireGuard application
2. Click "Import tunnel(s) from file" (or "Add Tunnel" > "Import")
3. Select the `.conf` file provided by your admin
4. Click "Activate" to connect

**Mobile (iOS/Android):**

1. Open the WireGuard app
2. Tap "+" to add a tunnel
3. Choose "Create from QR code"
4. Scan the QR code provided by your admin
5. Give it a name (e.g., "Company VPN")
6. Tap to activate

**Headscale users:**

```bash
# Run this command with the details provided by your admin
tailscale up --login-server https://vpn.yourcompany.com --authkey YOUR_PREAUTH_KEY
```

### Step 3: Verify Connection

After connecting, verify the VPN is working:

```bash
# Should respond (VPN gateway)
ping 10.8.0.1

# Should respond (service gateway)
ping 172.16.0.1
```

On Windows, open Command Prompt or PowerShell and run the same commands.

### Step 4: Configure AI Tools

Set the following environment variables to route AI tool traffic through the company gateway:

**Linux/macOS (add to `~/.bashrc` or `~/.zshrc`):**

```bash
export ANTHROPIC_BASE_URL=https://api.yourcompany-internal.com/v1
export OPENAI_BASE_URL=https://api.yourcompany-internal.com/v1
export ANTHROPIC_API_KEY=your-token-from-admin
export OPENAI_API_KEY=your-token-from-admin
```

**Windows (PowerShell):**

```powershell
[Environment]::SetEnvironmentVariable("ANTHROPIC_BASE_URL", "https://api.yourcompany-internal.com/v1", "User")
[Environment]::SetEnvironmentVariable("OPENAI_BASE_URL", "https://api.yourcompany-internal.com/v1", "User")
[Environment]::SetEnvironmentVariable("ANTHROPIC_API_KEY", "your-token-from-admin", "User")
[Environment]::SetEnvironmentVariable("OPENAI_API_KEY", "your-token-from-admin", "User")
```

### What the VPN Routes

The VPN uses **split tunneling** -- only company traffic goes through the VPN:

| Destination | Routed through VPN? |
|-------------|-------------------|
| `10.8.0.0/24` (VPN peers) | Yes |
| `172.16.0.0/24` (internal services) | Yes |
| Everything else (internet, YouTube, etc.) | **No** (uses your normal connection) |

This means your regular internet browsing, streaming, and other activities are **not affected** by the VPN.

---

## Part 3: Troubleshooting

### VPN Won't Connect

1. **Check the WireGuard endpoint is reachable:**
   ```bash
   # Should NOT timeout (UDP, so no response is expected, but no firewall block)
   nc -u -z -w3 <server-ip> 51820
   ```

2. **Check your configuration file:** Ensure the `Endpoint`, `PublicKey`, and `AllowedIPs` are correct.

3. **Check if your network blocks UDP 51820:** Some corporate/hotel networks block non-standard UDP ports. Try a different network.

4. **Check system logs on the server:**
   ```bash
   sudo journalctl -u wg-quick@wg0 --no-pager -n 50
   sudo dmesg | grep wireguard
   ```

### Connected but Cannot Access Services

1. **Verify VPN IP assignment:**
   ```bash
   # Should show your 10.8.0.x address
   ip addr show wg0        # Linux
   ifconfig utun*           # macOS
   ```

2. **Check routing:**
   ```bash
   # Should route through the VPN
   ip route get 172.16.0.1
   traceroute 172.16.0.1
   ```

3. **Check DNS resolution:**
   ```bash
   nslookup api.internal 10.8.0.1
   ```

4. **Check firewall on server:**
   ```bash
   sudo iptables -L VPN_INPUT -n -v --line-numbers
   ```

### Slow VPN Performance

1. **Check MTU:** The default MTU is 1280. If you experience fragmentation issues:
   ```
   # In your WireGuard config, try adjusting:
   MTU = 1420
   ```

2. **Check server load:**
   ```bash
   sudo bash scripts/vpn.sh status
   ```

3. **Check WireGuard handshake timing:**
   ```bash
   sudo wg show wg0
   ```
   If "latest handshake" is more than 3 minutes old, the tunnel may be unhealthy.

### Regenerating Configuration

If your configuration is compromised or corrupted:

1. Contact your IT admin
2. Admin will revoke the old configuration: `sudo bash scripts/vpn.sh revoke_user yourname`
3. Admin will create a new configuration: `sudo bash scripts/vpn.sh create_user yourname`
4. Import the new configuration file

---

## Part 4: Security Considerations

### For Administrators

- **Rotate admin credentials** regularly (every 90 days)
- **Audit user list** monthly -- revoke access for departed employees immediately
- **Monitor VPN logs** for unauthorized access attempts
- **Keep WireGuard updated** -- kernel module and tools
- **Backup VPN state** directory: `/etc/bifrost/vpn/`
- **Use OIDC/SSO** with Firezone for enterprise authentication
- **Enable MFA** in Firezone admin portal
- Each user gets a **unique preshared key** for post-quantum resistance

### For Employees

- **Never share** your VPN configuration file or API token
- **Do not copy** the configuration to shared or public computers
- **Report immediately** if your device is lost, stolen, or compromised
- **Keep WireGuard client updated** on all devices
- The VPN connection is **required** -- services are not accessible without it

### Network Isolation Guarantees

1. **External access to services is blocked** at the iptables level
2. **VPN authentication** is required (WireGuard cryptokey routing)
3. **Per-user keys** enable individual revocation
4. **Preshared keys** provide an additional symmetric encryption layer
5. **Service subnet** (172.16.0.0/24) is not routable from the internet
6. **All dropped packets are logged** for security auditing

---

## File Reference

| File | Purpose |
|------|---------|
| `scripts/vpn.sh` | Main VPN deployment and management script |
| `configs/vpn/firezone-compose.yml` | Docker Compose for Firezone |
| `configs/vpn/headscale-config.yaml` | Headscale server configuration |
| `configs/vpn/wg-client.conf.tpl` | WireGuard client config template |
| `configs/vpn/iptables-vpn.sh` | Network isolation iptables rules |
| `docs/VPN-SETUP.md` | This document |
