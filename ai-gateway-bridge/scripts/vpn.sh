#!/usr/bin/env bash
# =============================================================================
# AI Gateway Bridge - Enterprise VPN Module
# =============================================================================
# Description : Deploy and manage enterprise VPN as the first security gate.
#               Employees MUST connect to VPN before accessing ANY service.
#
#               Provides two deployment options:
#                 Option A: Firezone (Docker + WireGuard + Admin Portal)
#                 Option B: Headscale (Self-hosted Tailscale control server)
#
#               Common features:
#                 - VPN subnet: 10.8.0.0/24
#                 - Service subnet: 172.16.0.0/24
#                 - Network isolation (VPN -> services ALLOW, external DENY)
#                 - User lifecycle management (create/list/revoke)
#
# Architecture: Employee -> WireGuard(10.8.0.0/24) -> Server A ->
#                 { New API (VPN-only), Mihomo -> Xray -> Server B,
#                   Monitoring (VPN-only) }
#
# Usage       : source "$(dirname "${BASH_SOURCE[0]}")/vpn.sh"
#
# Project     : AI Gateway Bridge
# License     : MIT
# =============================================================================

set -euo pipefail

# Guard against double-sourcing (readonly variables would conflict)
if [[ -n "${_VPN_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
readonly _VPN_SH_LOADED=1

# Source shared utilities
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# =============================================================================
# Constants
# =============================================================================

# Network configuration
readonly VPN_SUBNET="10.8.0.0/24"
readonly VPN_GATEWAY="10.8.0.1"
readonly VPN_SUBNET_MASK="255.255.255.0"
readonly SERVICE_SUBNET="172.16.0.0/24"
readonly SERVICE_GATEWAY="172.16.0.1"

# WireGuard
readonly WG_PORT=51820
readonly WG_INTERFACE="wg0"

# Firezone
readonly FIREZONE_DIR="/opt/firezone"
readonly FIREZONE_COMPOSE="${FIREZONE_DIR}/docker-compose.yml"
readonly FIREZONE_ENV="${FIREZONE_DIR}/.env"
readonly FIREZONE_ADMIN_PORT=13000
readonly FIREZONE_API_PORT=13100

# Headscale
readonly HEADSCALE_DIR="/opt/headscale"
readonly HEADSCALE_CONFIG="${HEADSCALE_DIR}/config.yaml"
readonly HEADSCALE_DB="${HEADSCALE_DIR}/db.sqlite"
readonly HEADSCALE_SOCKET="${HEADSCALE_DIR}/headscale.sock"
readonly HEADSCALE_PORT=8080
readonly HEADSCALE_METRICS_PORT=9090
readonly HEADSCALE_REPO="juanfont/headscale"

# State
readonly VPN_STATE_DIR="/etc/ai-gateway-bridge/vpn"
readonly VPN_STATE_FILE="${VPN_STATE_DIR}/vpn-state"
readonly VPN_USERS_DIR="${VPN_STATE_DIR}/users"
readonly VPN_KEYS_DIR="${VPN_STATE_DIR}/keys"

# Templates (resolved relative to project root)
readonly VPN_TPL_DIR="${PROJECT_ROOT}/configs/vpn"

# =============================================================================
# Section 1 : State Management
# =============================================================================

# Ensure VPN state directories exist with correct permissions.
_vpn_ensure_dirs() {
    local dirs=("${VPN_STATE_DIR}" "${VPN_USERS_DIR}" "${VPN_KEYS_DIR}")
    for d in ${dirs[@]+"${dirs[@]}"}; do
        if [[ ! -d "${d}" ]]; then
            mkdir -p "${d}"
            chmod 700 "${d}"
        fi
    done
}

# Save a key=value pair to the VPN state file.
_vpn_save_state() {
    local key="${1:?_vpn_save_state requires key}"
    local value="${2:?_vpn_save_state requires value}"
    _vpn_ensure_dirs

    if [[ -f "${VPN_STATE_FILE}" ]]; then
        sed -i "/^${key}=/d" "${VPN_STATE_FILE}"
    fi
    echo "${key}=${value}" >> "${VPN_STATE_FILE}"
    chmod 600 "${VPN_STATE_FILE}"
}

# Load a value by key from the VPN state file.
_vpn_load_state() {
    local key="${1:?_vpn_load_state requires key}"
    if [[ -f "${VPN_STATE_FILE}" ]]; then
        grep "^${key}=" "${VPN_STATE_FILE}" 2>/dev/null | head -1 | cut -d'=' -f2-
    fi
}

# =============================================================================
# Section 2 : Prerequisites
# =============================================================================

# Validate the system meets VPN deployment requirements.
_vpn_check_prerequisites() {
    log_info "Checking VPN deployment prerequisites..."

    # Must be root
    require_root

    # Check OS support
    if [[ "${OS_ID}" == "unknown" ]]; then
        detect_system
    fi

    case "${OS_ID}" in
        ubuntu|debian|rocky|alma|centos|fedora)
            log_info "OS ${OS_ID} ${OS_VER} is supported."
            ;;
        *)
            log_warn "OS '${OS_ID}' is not officially tested. Proceeding with caution."
            ;;
    esac

    # Check kernel WireGuard module support
    if ! modprobe wireguard 2>/dev/null; then
        log_warn "WireGuard kernel module not loaded. Will attempt to install."
    else
        log_success "WireGuard kernel module is available."
    fi

    # Check available memory (minimum 512MB recommended)
    if [[ -n "${MEM_TOTAL_MB}" ]] && (( MEM_TOTAL_MB < 512 )); then
        log_warn "System has only ${MEM_TOTAL_MB}MB RAM. Minimum 512MB recommended for VPN."
    fi

    # Check disk space (minimum 2GB recommended)
    if [[ -n "${DISK_AVAIL_GB}" ]] && (( DISK_AVAIL_GB < 2 )); then
        log_warn "Only ${DISK_AVAIL_GB}GB disk space available. Minimum 2GB recommended."
    fi

    log_success "Prerequisites check completed."
}

# Resolve the Headscale version to install.
# Priority: explicit environment override -> latest GitHub release tag.
_vpn_headscale_resolve_version() {
    local configured_version="${BIFROST_HEADSCALE_VERSION:-}"
    local release_json=""
    local release_tag=""

    if [[ -n "${configured_version}" ]]; then
        echo "${configured_version#v}"
        return 0
    fi

    release_json="$(github_fetch_text "https://api.github.com/repos/${HEADSCALE_REPO}/releases/latest" 20 10)" || release_json=""
    release_tag="$(printf '%s' "${release_json}" | grep -oE '"tag_name":\s*"v?[^"]+"' | head -1 | sed -E 's/.*"v?([^"]+)"/\1/')"
    if [[ -z "${release_tag}" ]]; then
        log_error "Failed to resolve the latest Headscale release from GitHub."
        log_error "$(github_mirror_help)"
        log_error "You can pin a version explicitly with BIFROST_HEADSCALE_VERSION=<version>."
        return 1
    fi

    echo "${release_tag}"
}

# Install WireGuard tools and kernel module.
_vpn_install_wireguard() {
    log_info "Installing WireGuard..."

    case "${PKG_MGR}" in
        apt)
            install_packages wireguard wireguard-tools qrencode
            ;;
        dnf)
            install_packages wireguard-tools qrencode
            # RHEL/Rocky/Alma may need EPEL + elrepo for kernel module
            if ! modprobe wireguard 2>/dev/null; then
                log_info "Installing WireGuard kernel module from elrepo..."
                install_packages epel-release elrepo-release
                install_packages kmod-wireguard
            fi
            ;;
        yum)
            install_packages epel-release
            install_packages wireguard-tools qrencode
            ;;
        *)
            die "Cannot install WireGuard: unsupported package manager '${PKG_MGR}'."
            ;;
    esac

    # Load the module
    modprobe wireguard || die "Failed to load WireGuard kernel module."

    # Ensure it loads on boot
    if [[ ! -f /etc/modules-load.d/wireguard.conf ]]; then
        echo "wireguard" > /etc/modules-load.d/wireguard.conf
    fi

    log_success "WireGuard installed successfully."
}

# =============================================================================
# Section 3 : Network Configuration
# =============================================================================

# Configure VPN and service network segments with routing and isolation.
# VPN subnet:     10.8.0.0/24  (employee VPN clients)
# Service subnet: 172.16.0.0/24 (internal services: New API, monitoring, etc.)
setup_vpn_network() {
    log_info "Configuring VPN network segments..."
    _vpn_ensure_dirs

    # ----- Enable IP forwarding -----
    local sysctl_conf="/etc/sysctl.d/99-vpn-forwarding.conf"
    cat > "${sysctl_conf}" <<'SYSCTL'
# AI Gateway Bridge - VPN IP Forwarding
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1

# Prevent IP spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Do not accept source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
SYSCTL
    sysctl -p "${sysctl_conf}" >/dev/null 2>&1
    log_info "IP forwarding enabled."

    # ----- Detect primary network interface -----
    local primary_iface
    primary_iface="$(ip -4 route show default | awk '{print $5}' | head -1)"
    if [[ -z "${primary_iface}" ]]; then
        die "Cannot detect primary network interface."
    fi
    log_info "Primary network interface: ${primary_iface}"
    _vpn_save_state "PRIMARY_IFACE" "${primary_iface}"

    # ----- Create service bridge network (Docker will use this) -----
    if ! ip link show br-services &>/dev/null; then
        ip link add br-services type bridge
        ip addr add "${SERVICE_GATEWAY}/24" dev br-services
        ip link set br-services up
        log_info "Created bridge network br-services (${SERVICE_SUBNET})."
    else
        log_info "Bridge network br-services already exists."
    fi

    # ----- Persist bridge via systemd-networkd or netplan -----
    local bridge_netdev="/etc/systemd/network/10-br-services.netdev"
    local bridge_network="/etc/systemd/network/10-br-services.network"

    mkdir -p /etc/systemd/network

    cat > "${bridge_netdev}" <<'NETDEV'
[NetDev]
Name=br-services
Kind=bridge
NETDEV

    cat > "${bridge_network}" <<NETWORK
[Match]
Name=br-services

[Network]
Address=${SERVICE_GATEWAY}/24

[Link]
RequiredForOnline=no
NETWORK

    # ----- NAT: VPN clients -> external (masquerade) -----
    # Actual iptables rules are applied by setup_vpn_firewall() and iptables-vpn.sh
    log_info "Network segmentation configured: VPN=${VPN_SUBNET}, Services=${SERVICE_SUBNET}"

    _vpn_save_state "VPN_SUBNET" "${VPN_SUBNET}"
    _vpn_save_state "SERVICE_SUBNET" "${SERVICE_SUBNET}"
    _vpn_save_state "NETWORK_CONFIGURED" "1"

    log_success "VPN network configuration complete."
}

# =============================================================================
# Section 4 : Firewall / iptables
# =============================================================================

# Configure iptables rules for VPN network isolation.
# - 51820/udp: WireGuard endpoint (allow from anywhere)
# - 443/tcp: HTTPS endpoint (allow from anywhere)
# - Service ports: ONLY accessible from VPN subnet (10.8.0.0/24)
# - External -> service ports: DENY
setup_vpn_firewall() {
    log_info "Configuring VPN firewall rules..."

    local primary_iface
    primary_iface="$(_vpn_load_state "PRIMARY_IFACE")"
    if [[ -z "${primary_iface}" ]]; then
        primary_iface="$(ip -4 route show default | awk '{print $5}' | head -1)"
    fi

    # ----- Install iptables if needed -----
    install_if_missing iptables iptables

    # Check for iptables-persistent
    if [[ "${PKG_MGR}" == "apt" ]]; then
        if ! dpkg -l | grep -q iptables-persistent; then
            echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
            echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
            install_packages iptables-persistent
        fi
    fi

    # ----- Apply VPN iptables rules from template -----
    local iptables_script="${VPN_TPL_DIR}/iptables-vpn.sh"
    if [[ -f "${iptables_script}" ]]; then
        log_info "Applying iptables rules from ${iptables_script}..."
        PRIMARY_IFACE="${primary_iface}" \
        VPN_SUBNET="${VPN_SUBNET}" \
        SERVICE_SUBNET="${SERVICE_SUBNET}" \
        WG_INTERFACE="${WG_INTERFACE}" \
            bash "${iptables_script}"
    else
        log_warn "iptables-vpn.sh not found at ${iptables_script}. Applying inline rules."
        _vpn_apply_inline_iptables "${primary_iface}"
    fi

    # ----- Persist rules -----
    if check_command iptables-save; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
        log_info "iptables rules persisted to /etc/iptables/rules.v4"
    fi

    # ----- Coexist with UFW (managed by security.sh) -----
    # Previously this disabled UFW entirely, which undid all security.sh hardening.
    # UFW and iptables can coexist: UFW manages INPUT/OUTPUT default policies while
    # VPN iptables rules use custom chains (VPN_FORWARD, VPN_NAT) that don't conflict.
    # security.sh already opens port 51820/udp for WireGuard.
    if check_command ufw && ufw status 2>/dev/null | grep -q "active"; then
        log_info "UFW is active. VPN iptables rules use custom chains and coexist with UFW."
        log_info "Ensuring WireGuard port is open in UFW..."
        ufw allow 51820/udp comment "WireGuard VPN" 2>/dev/null || true
    fi

    _vpn_save_state "FIREWALL_CONFIGURED" "1"
    log_success "VPN firewall configuration complete."
}

# Inline fallback iptables rules if the template script is missing.
_vpn_apply_inline_iptables() {
    local iface="${1:?requires primary interface}"

    # Flush existing VPN-related chains (idempotent)
    iptables -D FORWARD -j VPN_FORWARD 2>/dev/null || true
    iptables -F VPN_FORWARD 2>/dev/null || true
    iptables -X VPN_FORWARD 2>/dev/null || true
    iptables -t nat -D POSTROUTING -j VPN_NAT 2>/dev/null || true
    iptables -t nat -F VPN_NAT 2>/dev/null || true
    iptables -t nat -X VPN_NAT 2>/dev/null || true

    # --- NAT chain ---
    iptables -t nat -N VPN_NAT
    # Masquerade VPN traffic going to the internet
    iptables -t nat -A VPN_NAT -s "${VPN_SUBNET}" -o "${iface}" -j MASQUERADE
    # Masquerade VPN traffic going to services
    iptables -t nat -A VPN_NAT -s "${VPN_SUBNET}" -d "${SERVICE_SUBNET}" -j MASQUERADE
    iptables -t nat -A POSTROUTING -j VPN_NAT

    # --- FORWARD chain ---
    iptables -N VPN_FORWARD

    # Allow established/related connections
    iptables -A VPN_FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

    # VPN -> services: ALLOW
    iptables -A VPN_FORWARD -s "${VPN_SUBNET}" -d "${SERVICE_SUBNET}" -j ACCEPT

    # VPN -> internet (for tunnel traffic): ALLOW
    iptables -A VPN_FORWARD -s "${VPN_SUBNET}" -o "${iface}" -j ACCEPT

    # External -> service subnet: DENY (this is the key isolation rule)
    iptables -A VPN_FORWARD -d "${SERVICE_SUBNET}" -j DROP

    # Attach to main FORWARD chain
    iptables -A FORWARD -j VPN_FORWARD

    # --- INPUT chain (service ports VPN-only) ---
    # WireGuard: allow from anywhere
    iptables -A INPUT -p udp --dport "${WG_PORT}" -j ACCEPT

    # HTTPS: allow from anywhere
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT

    # SSH: keep existing rules (managed by security.sh)

    # Service ports: ONLY from VPN
    # New API (3000)
    iptables -A INPUT -p tcp --dport 3000 -s "${VPN_SUBNET}" -j ACCEPT
    iptables -A INPUT -p tcp --dport 3000 -j DROP

    # Monitoring - Netdata (19999)
    iptables -A INPUT -p tcp --dport 19999 -s "${VPN_SUBNET}" -j ACCEPT
    iptables -A INPUT -p tcp --dport 19999 -j DROP

    # Firezone admin portal (13000)
    iptables -A INPUT -p tcp --dport "${FIREZONE_ADMIN_PORT}" -s "${VPN_SUBNET}" -j ACCEPT
    iptables -A INPUT -p tcp --dport "${FIREZONE_ADMIN_PORT}" -j DROP

    # Headscale (8080)
    iptables -A INPUT -p tcp --dport "${HEADSCALE_PORT}" -s "${VPN_SUBNET}" -j ACCEPT
    iptables -A INPUT -p tcp --dport "${HEADSCALE_PORT}" -j DROP

    log_info "Inline iptables rules applied."
}

# =============================================================================
# Section 5 : WireGuard Server Key Generation
# =============================================================================

# Generate WireGuard server keypair if not already present.
_vpn_generate_server_keys() {
    _vpn_ensure_dirs

    local server_privkey="${VPN_KEYS_DIR}/server.key"
    local server_pubkey="${VPN_KEYS_DIR}/server.pub"

    if [[ -f "${server_privkey}" && -f "${server_pubkey}" ]]; then
        log_info "WireGuard server keys already exist."
        return 0
    fi

    log_info "Generating WireGuard server keypair..."
    wg genkey | tee "${server_privkey}" | wg pubkey > "${server_pubkey}"
    chmod 600 "${server_privkey}"
    chmod 644 "${server_pubkey}"

    # Only save the public key to state; the private key stays in its dedicated
    # file (chmod 600) and is never duplicated to the state file.
    _vpn_save_state "SERVER_PUBLIC_KEY" "$(cat "${server_pubkey}")"
    _vpn_save_state "SERVER_PRIVATE_KEY_FILE" "${server_privkey}"

    log_success "WireGuard server keys generated."
    log_info "Server public key: $(cat "${server_pubkey}")"
}

# =============================================================================
# Section 6 : Option A - Firezone Deployment
# =============================================================================

# Deploy Firezone (Docker-based WireGuard management with admin portal).
# Firezone provides: admin web UI, user management, MFA, OIDC, device management.
_vpn_deploy_firezone() {
    print_section "Deploying Firezone (Option A)"

    # ----- Ensure Docker is available -----
    if ! check_docker; then
        log_info "Docker not found. Installing..."
        install_docker
    fi

    # Check for Docker Compose
    if ! docker compose version &>/dev/null; then
        die "Docker Compose plugin is required for Firezone. Install docker-compose-plugin."
    fi

    # ----- Check for port conflicts -----
    local conflicting_ports=()
    if check_port_open "${WG_PORT}"; then
        conflicting_ports+=("${WG_PORT}/udp (WireGuard)")
    fi
    if check_port_open "${FIREZONE_ADMIN_PORT}"; then
        conflicting_ports+=("${FIREZONE_ADMIN_PORT}/tcp (Firezone Admin)")
    fi

    if [[ ${#conflicting_ports[@]} -gt 0 ]]; then
        log_error "Port conflicts detected:"
        for p in ${conflicting_ports[@]+"${conflicting_ports[@]}"}; do
            log_error "  - ${p}"
        done
        die "Resolve port conflicts before deploying Firezone."
    fi

    # ----- Check for existing Docker resources -----
    if docker ps -a --format '{{.Names}}' | grep -q "firezone"; then
        log_warn "Existing Firezone containers detected."
        if ! confirm_action "Remove existing Firezone containers and redeploy?"; then
            log_info "Firezone deployment cancelled."
            return 1
        fi
        log_info "Stopping existing Firezone containers..."
        cd "${FIREZONE_DIR}" && docker compose down 2>/dev/null || true
    fi

    if docker images --format '{{.Repository}}' | grep -q "firezone"; then
        log_info "Existing Firezone images found. They will be reused."
    fi

    # ----- Prepare directories -----
    mkdir -p "${FIREZONE_DIR}"
    chmod 700 "${FIREZONE_DIR}"

    # ----- Generate secrets -----
    local db_password
    db_password="$(generate_random_password 32)"
    local secret_key_base
    secret_key_base="$(generate_random_password 64)"
    local live_view_salt
    live_view_salt="$(generate_random_password 32)"
    local cookie_signing_salt
    cookie_signing_salt="$(generate_random_password 32)"
    local cookie_encryption_salt
    cookie_encryption_salt="$(generate_random_password 32)"

    # ----- Admin email -----
    local admin_email
    read_input "Enter Firezone admin email" "admin@company.com" "^[^@]+@[^@]+\.[^@]+$"
    admin_email="${INPUT_RESULT}"

    # ----- External URL -----
    local external_url
    read_input "Enter Firezone external URL (e.g., https://vpn.yourdomain.com)" "" "^https?://"
    external_url="${INPUT_RESULT}"

    # ----- Write Docker Compose -----
    local compose_tpl="${VPN_TPL_DIR}/firezone-compose.yml"
    if [[ -f "${compose_tpl}" ]]; then
        template_render "${compose_tpl}" "${FIREZONE_COMPOSE}" \
            "DB_PASSWORD=${db_password}" \
            "SECRET_KEY_BASE=${secret_key_base}" \
            "LIVE_VIEW_SIGNING_SALT=${live_view_salt}" \
            "COOKIE_SIGNING_SALT=${cookie_signing_salt}" \
            "COOKIE_ENCRYPTION_SALT=${cookie_encryption_salt}" \
            "ADMIN_EMAIL=${admin_email}" \
            "EXTERNAL_URL=${external_url}" \
            "VPN_SUBNET=${VPN_SUBNET}" \
            "WG_PORT=${WG_PORT}"
    else
        die "Firezone compose template not found at ${compose_tpl}."
    fi

    # ----- Deploy -----
    log_info "Starting Firezone containers..."
    cd "${FIREZONE_DIR}"

    spinner "Pulling Firezone images..." docker compose pull
    spinner "Starting Firezone..." docker compose up -d

    # ----- Wait for Firezone to become healthy -----
    log_info "Waiting for Firezone to start..."
    wait_for_port "${FIREZONE_ADMIN_PORT}" 120

    # ----- Create initial admin -----
    log_info "Creating Firezone admin account..."
    local admin_password
    admin_password="$(generate_random_password 24)"

    # Pass password via environment variable instead of CLI argument to avoid
    # exposure in `ps aux` process listing.
    FIREZONE_RESET_ADMIN_PASSWORD="${admin_password}" \
    docker compose exec -T \
        -e "FIREZONE_RESET_ADMIN_PASSWORD=${admin_password}" \
        firezone bin/create-or-reset-admin \
        --email "${admin_email}" \
        --password-env FIREZONE_RESET_ADMIN_PASSWORD 2>/dev/null || \
    docker compose exec -T firezone bin/create-or-reset-admin \
        --email "${admin_email}" \
        --password "${admin_password}" 2>/dev/null || \
    docker compose exec -T firezone /app/bin/firezone eval \
        "FzHttp.CLI.create_admin_user(\"${admin_email}\", \"${admin_password}\")" 2>/dev/null || \
    log_warn "Could not auto-create admin. You may need to create it manually."

    # ----- Save state -----
    _vpn_save_state "VPN_TYPE" "firezone"
    _vpn_save_state "FIREZONE_ADMIN_EMAIL" "${admin_email}"
    _vpn_save_state "FIREZONE_EXTERNAL_URL" "${external_url}"
    # NOTE: Passwords and DB credentials are NOT persisted to the state file.
    # They are shown once during deployment and the admin must save them.
    # The state file (chmod 600) should not contain plaintext passwords.

    # ----- Print summary (secrets to stdout only, NOT to log file) -----
    print_section "Firezone Deployment Complete"
    print_kv "Admin URL"      "${external_url}"
    print_kv "Admin Email"    "${admin_email}"
    echo -e "  Admin Password: ${admin_password}"
    print_kv "WireGuard Port" "${WG_PORT}/udp"
    print_kv "VPN Subnet"     "${VPN_SUBNET}"
    echo ""
    log_warn "IMPORTANT: Save the admin password above. It will NOT be shown again."
    log_warn "Change the admin password immediately after first login."

    log_success "Firezone deployment complete."
}

# =============================================================================
# Section 7 : Option B - Headscale Deployment
# =============================================================================

# Deploy Headscale (self-hosted Tailscale control server).
# Headscale provides: mesh VPN, ACL, DERP relay, user namespaces.
_vpn_deploy_headscale() {
    print_section "Deploying Headscale (Option B)"

    # ----- Check for port conflicts -----
    if check_port_open "${HEADSCALE_PORT}"; then
        die "Port ${HEADSCALE_PORT} is already in use. Resolve before deploying Headscale."
    fi

    # ----- Install Headscale -----
    log_info "Installing Headscale..."

    local headscale_version=""
    local arch_suffix

    headscale_version="$(_vpn_headscale_resolve_version)" || return 1

    case "${ARCH}" in
        x86_64|amd64) arch_suffix="amd64" ;;
        aarch64|arm64) arch_suffix="arm64" ;;
        *) die "Unsupported architecture for Headscale: ${ARCH}" ;;
    esac

    local headscale_tag="v${headscale_version}"
    local headscale_url="https://github.com/${HEADSCALE_REPO}/releases/download/${headscale_tag}/headscale_${headscale_version}_linux_${arch_suffix}.deb"
    local headscale_bin_url="https://github.com/${HEADSCALE_REPO}/releases/download/${headscale_tag}/headscale_${headscale_version}_linux_${arch_suffix}"

    if [[ "${PKG_MGR}" == "apt" ]]; then
        local tmp_deb
        tmp_deb="$(mktemp /tmp/headscale.XXXXXX.deb)"
        register_cleanup "${tmp_deb}"
        log_info "Downloading Headscale v${headscale_version} (with configured GitHub mirror fallback)..."
        if ! github_download "${headscale_url}" "${tmp_deb}" 120; then
            die "Failed to download Headscale package from all sources (direct + configured mirrors)."
        fi
        dpkg -i "${tmp_deb}" || apt-get install -f -y
    else
        # Upstream latest releases publish Linux binaries but not RPM packages.
        local tmp_bin
        tmp_bin="$(mktemp /tmp/headscale.XXXXXX.bin)"
        register_cleanup "${tmp_bin}"
        log_info "Downloading Headscale v${headscale_version} binary (with configured GitHub mirror fallback)..."
        if ! github_download "${headscale_bin_url}" "${tmp_bin}" 120; then
            die "Failed to download Headscale binary from all sources (direct + configured mirrors)."
        fi
        install -m 755 "${tmp_bin}" /usr/local/bin/headscale
    fi

    if ! check_command headscale; then
        die "Headscale installation failed."
    fi

    log_success "Headscale installed: $(headscale version 2>/dev/null || echo 'unknown')"

    # ----- Prepare directories -----
    mkdir -p "${HEADSCALE_DIR}" /var/lib/headscale /var/run/headscale
    chmod 700 "${HEADSCALE_DIR}"

    # ----- Server URL -----
    local server_url
    read_input "Enter Headscale server URL (e.g., https://vpn.yourdomain.com)" "" "^https?://"
    server_url="${INPUT_RESULT}"

    # ----- Base domain -----
    local base_domain
    base_domain="$(echo "${server_url}" | sed -E 's|https?://||' | cut -d'/' -f1 | cut -d':' -f1)"

    # ----- Generate config from template -----
    local config_tpl="${VPN_TPL_DIR}/headscale-config.yaml"
    if [[ -f "${config_tpl}" ]]; then
        template_render "${config_tpl}" "${HEADSCALE_CONFIG}" \
            "SERVER_URL=${server_url}" \
            "LISTEN_ADDR=0.0.0.0:${HEADSCALE_PORT}" \
            "METRICS_ADDR=127.0.0.1:${HEADSCALE_METRICS_PORT}" \
            "BASE_DOMAIN=${base_domain}" \
            "DB_PATH=${HEADSCALE_DB}" \
            "SOCKET_PATH=${HEADSCALE_SOCKET}" \
            "VPN_SUBNET_V4=10.8.0.0/24"
    else
        die "Headscale config template not found at ${config_tpl}."
    fi

    # ----- Create systemd service -----
    cat > /etc/systemd/system/headscale.service <<SERVICE
[Unit]
Description=Headscale - Self-hosted Tailscale control server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=headscale
Group=headscale
ExecStart=/usr/bin/headscale serve
Restart=always
RestartSec=5
LimitNOFILE=65535

# Security hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/headscale /var/run/headscale ${HEADSCALE_DIR}
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
SERVICE

    # ----- Create headscale user -----
    if ! id headscale &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin headscale
    fi
    chown -R headscale:headscale "${HEADSCALE_DIR}" /var/lib/headscale /var/run/headscale

    # ----- Start Headscale -----
    systemctl daemon-reload
    enable_service headscale
    restart_service headscale

    # ----- Create default namespace/user -----
    sleep 3
    if ! headscale users create "employees" 2>/dev/null; then
        if headscale users list 2>/dev/null | grep -Eq '(^|[[:space:]])employees([[:space:]]|$)'; then
            log_warn "User 'employees' already exists."
        else
            log_error "Failed to create default Headscale user 'employees'."
            return 1
        fi
    fi

    # ----- Generate API key -----
    local api_key=""
    api_key="$(headscale apikeys create --expiration 365d 2>/dev/null || true)"
    if [[ -z "${api_key}" ]]; then
        log_error "Failed to generate Headscale API key."
        return 1
    fi

    # ----- Save state -----
    _vpn_save_state "VPN_TYPE" "headscale"
    _vpn_save_state "HEADSCALE_SERVER_URL" "${server_url}"
    _vpn_save_state "HEADSCALE_API_KEY" "${api_key}"

    # ----- Print summary -----
    print_section "Headscale Deployment Complete"
    print_kv "Server URL"      "${server_url}"
    print_kv "Listen Address"  "0.0.0.0:${HEADSCALE_PORT}"
    print_kv "Metrics"         "127.0.0.1:${HEADSCALE_METRICS_PORT}"
    print_kv "Default User"    "employees"
    if [[ -n "${api_key}" ]]; then
        print_kv "API Key"     "${api_key}"
    fi
    echo ""
    log_warn "Employees need to install Tailscale client and connect using:"
    log_warn "  tailscale up --login-server ${server_url}"

    log_success "Headscale deployment complete."
}

# =============================================================================
# Section 8 : User Management
# =============================================================================

# Create a VPN user with configuration and New API token.
# Generates: WireGuard config, QR code, setup instructions.
create_vpn_user() {
    local username="${1:-}"

    if [[ -z "${username}" ]]; then
        read_input "Enter username for new VPN user" "" "^[a-zA-Z0-9_-]+$"
        username="${INPUT_RESULT}"
    fi

    log_info "Creating VPN user: ${username}"

    # Check if user already exists
    local user_dir="${VPN_USERS_DIR}/${username}"
    if [[ -d "${user_dir}" ]]; then
        log_error "User '${username}' already exists."
        if ! confirm_action "Regenerate configuration for '${username}'?"; then
            return 1
        fi
        log_info "Regenerating configuration for '${username}'..."
    fi

    mkdir -p "${user_dir}"
    chmod 700 "${user_dir}"

    local vpn_type
    vpn_type="$(_vpn_load_state "VPN_TYPE")"

    case "${vpn_type}" in
        firezone)
            _create_firezone_user "${username}" "${user_dir}" || return 1
            ;;
        headscale)
            _create_headscale_user "${username}" "${user_dir}" || return 1
            ;;
        *)
            # Standalone WireGuard (direct management)
            _create_wireguard_user "${username}" "${user_dir}" || return 1
            ;;
    esac

    # ----- Generate New API token for the user -----
    local api_token=""
    if check_command curl && check_port_open 3000; then
        log_info "Generating New API token for ${username}..."
        api_token="$(generate_random_password 48)"
        # The actual token registration depends on New API's admin API
        # Store the generated token for the admin to register manually if needed
        echo "${api_token}" > "${user_dir}/api-token.txt"
        chmod 600 "${user_dir}/api-token.txt"
        log_info "API token generated and saved to ${user_dir}/api-token.txt"
    else
        log_warn "New API is not running. API token not generated."
        log_warn "Create a token manually and place it in ${user_dir}/api-token.txt"
    fi

    # ----- Generate setup guide for the user -----
    _generate_user_setup_guide "${username}" "${user_dir}" "${api_token}"

    _vpn_save_state "USER_${username}_CREATED" "$(date -Iseconds)"

    print_section "User '${username}' Created"
    print_kv "Config Dir" "${user_dir}"
    print_kv "VPN Type"   "${vpn_type:-wireguard}"
    if [[ -f "${user_dir}/wg-${username}.conf" ]]; then
        print_kv "WG Config"  "${user_dir}/wg-${username}.conf"
    fi
    if [[ -f "${user_dir}/qrcode.txt" ]]; then
        print_kv "QR Code"    "${user_dir}/qrcode.txt"
    fi
    echo ""

    log_success "VPN user '${username}' created successfully."
}

# Create a WireGuard user (standalone, non-Firezone).
_create_wireguard_user() {
    local username="${1}"
    local user_dir="${2}"

    # Generate client keypair
    local client_privkey client_pubkey
    client_privkey="$(wg genkey)"
    client_pubkey="$(echo "${client_privkey}" | wg pubkey)"
    local preshared_key
    preshared_key="$(wg genpsk)"

    echo "${client_privkey}" > "${user_dir}/private.key"
    echo "${client_pubkey}" > "${user_dir}/public.key"
    echo "${preshared_key}" > "${user_dir}/preshared.key"
    chmod 600 "${user_dir}/private.key" "${user_dir}/preshared.key"

    # Assign IP address (next available in 10.8.0.x)
    local client_ip
    client_ip="$(_vpn_next_ip)"

    _vpn_save_state "USER_${username}_IP" "${client_ip}"
    _vpn_save_state "USER_${username}_PUBKEY" "${client_pubkey}"

    # Load server keys
    local server_pubkey
    server_pubkey="$(_vpn_load_state "SERVER_PUBLIC_KEY")"
    if [[ -z "${server_pubkey}" ]]; then
        server_pubkey="$(cat "${VPN_KEYS_DIR}/server.pub" 2>/dev/null || echo '')"
    fi

    local server_endpoint
    server_endpoint="${PUBLIC_IP}:${WG_PORT}"

    # Generate client config from template
    local client_conf="${user_dir}/wg-${username}.conf"
    local conf_tpl="${VPN_TPL_DIR}/wg-client.conf.tpl"

    if [[ -f "${conf_tpl}" ]]; then
        template_render "${conf_tpl}" "${client_conf}" \
            "CLIENT_PRIVATE_KEY=${client_privkey}" \
            "CLIENT_ADDRESS=${client_ip}/32" \
            "DNS_SERVERS=10.8.0.1" \
            "SERVER_PUBLIC_KEY=${server_pubkey}" \
            "PRESHARED_KEY=${preshared_key}" \
            "SERVER_ENDPOINT=${server_endpoint}" \
            "ALLOWED_IPS=10.8.0.0/24,172.16.0.0/24" \
            "PERSISTENT_KEEPALIVE=25"
    else
        # Inline fallback
        cat > "${client_conf}" <<CONF
[Interface]
PrivateKey = ${client_privkey}
Address = ${client_ip}/32
DNS = 10.8.0.1

[Peer]
PublicKey = ${server_pubkey}
PresharedKey = ${preshared_key}
Endpoint = ${server_endpoint}
AllowedIPs = 10.8.0.0/24, 172.16.0.0/24
PersistentKeepalive = 25
CONF
    fi

    chmod 600 "${client_conf}"

    # Generate QR code
    if check_command qrencode; then
        qrencode -t ansiutf8 < "${client_conf}" > "${user_dir}/qrcode.txt"
        qrencode -t png -o "${user_dir}/qrcode.png" < "${client_conf}"
        log_info "QR code generated for mobile import."
    fi

    # Add peer to WireGuard server
    if ip link show "${WG_INTERFACE}" &>/dev/null; then
        wg set "${WG_INTERFACE}" \
            peer "${client_pubkey}" \
            preshared-key "${user_dir}/preshared.key" \
            allowed-ips "${client_ip}/32"
        log_info "Peer added to ${WG_INTERFACE}."

        # Persist to server config
        _vpn_update_server_config
    else
        log_warn "WireGuard interface ${WG_INTERFACE} not active. Peer added to state only."
    fi
}

# Create a Firezone-managed user.
_create_firezone_user() {
    local username="${1}"
    local user_dir="${2}"

    if [[ -d "${FIREZONE_DIR}" ]] && docker compose -f "${FIREZONE_COMPOSE}" ps 2>/dev/null | grep -q "firezone"; then
        log_info "Creating user in Firezone..."

        local user_email="${username}@company.local"
        local user_password
        user_password="$(generate_random_password 16)"

        # Create user via Firezone CLI — try env-based password first to avoid
        # exposure in `ps aux`, fall back to CLI argument if not supported.
        docker compose -f "${FIREZONE_COMPOSE}" exec -T \
            -e "FIREZONE_USER_PASSWORD=${user_password}" \
            firezone bin/create-or-reset-admin \
            --email "${user_email}" \
            --password-env FIREZONE_USER_PASSWORD 2>/dev/null || \
        docker compose -f "${FIREZONE_COMPOSE}" exec -T firezone \
            bin/create-or-reset-admin \
            --email "${user_email}" \
            --password "${user_password}" 2>/dev/null || \
        log_warn "Could not create user via CLI. Create manually in admin portal."

        echo "email=${user_email}" > "${user_dir}/firezone-user.txt"
        echo "password=${user_password}" >> "${user_dir}/firezone-user.txt"
        chmod 600 "${user_dir}/firezone-user.txt"

        _vpn_save_state "USER_${username}_EMAIL" "${user_email}"
    else
        log_warn "Firezone is not running. Creating standalone WireGuard config."
        _create_wireguard_user "${username}" "${user_dir}"
    fi
}

# Create a Headscale-managed user.
_create_headscale_user() {
    local username="${1}"
    local user_dir="${2}"

    if check_command headscale; then
        log_info "Creating Headscale pre-auth key for ${username}..."

        # Create a pre-auth key (one-time use, expires in 24h)
        local preauth_key=""
        preauth_key="$(headscale preauthkeys create \
            --user employees \
            --reusable=false \
            --expiration 24h \
            2>/dev/null || true)"

        if [[ -n "${preauth_key}" ]]; then
            echo "${preauth_key}" > "${user_dir}/preauth-key.txt"
            chmod 600 "${user_dir}/preauth-key.txt"

            local server_url
            server_url="$(_vpn_load_state "HEADSCALE_SERVER_URL")"

            # Do NOT save pre-auth key to state file — it is stored in the
            # user's dedicated file (chmod 600) and expires in 24h.
            _vpn_save_state "USER_${username}_PREAUTH_FILE" "${user_dir}/preauth-key.txt"

            # Print pre-auth key ONLY to stdout (not to log file) to avoid
            # persisting secrets in /var/log/ai-gateway-bridge/ai-gateway-bridge.log.
            echo "Pre-auth key created. User should run:"
            echo "  tailscale up --login-server ${server_url} --authkey ${preauth_key}"
        else
            log_error "Could not generate Headscale pre-auth key for '${username}'."
            log_error "Refusing to mark VPN user as created without a usable login credential."
            return 1
        fi
    else
        log_warn "Headscale CLI not found. Cannot create user."
        return 1
    fi
}

# Generate setup instructions for a user.
_generate_user_setup_guide() {
    local username="${1}"
    local user_dir="${2}"
    local api_token="${3:-}"

    local vpn_type
    vpn_type="$(_vpn_load_state "VPN_TYPE")"
    vpn_type="${vpn_type:-wireguard}"

    local guide_file="${user_dir}/SETUP-GUIDE.txt"

    cat > "${guide_file}" <<GUIDE
================================================================================
AI Gateway Bridge - VPN Setup Guide for: ${username}
================================================================================
Generated: $(date -Iseconds)

STEP 1: Install VPN Client
--------------------------
GUIDE

    case "${vpn_type}" in
        firezone|wireguard|"")
            cat >> "${guide_file}" <<'GUIDE'
- Windows: Download WireGuard from https://www.wireguard.com/install/
- macOS:   Install from App Store or: brew install wireguard-tools
- Linux:   sudo apt install wireguard (Ubuntu/Debian)
           sudo dnf install wireguard-tools (Fedora/RHEL)
- iOS:     Install "WireGuard" from App Store
- Android: Install "WireGuard" from Google Play
GUIDE
            ;;
        headscale)
            cat >> "${guide_file}" <<'GUIDE'
- All platforms: Install Tailscale from https://tailscale.com/download
GUIDE
            ;;
    esac

    cat >> "${guide_file}" <<GUIDE

STEP 2: Import VPN Configuration
---------------------------------
GUIDE

    case "${vpn_type}" in
        firezone|wireguard|"")
            cat >> "${guide_file}" <<GUIDE
- Desktop: Open WireGuard -> Import tunnel from file -> select wg-${username}.conf
- Mobile:  Open WireGuard -> scan QR code (qrcode.png or display qrcode.txt)
GUIDE
            ;;
        headscale)
            local server_url
            server_url="$(_vpn_load_state "HEADSCALE_SERVER_URL")"
            local preauth_key=""
            if [[ -f "${user_dir}/preauth-key.txt" ]]; then
                preauth_key="$(cat "${user_dir}/preauth-key.txt")"
            fi
            cat >> "${guide_file}" <<GUIDE
Run the following command on your device:
  tailscale up --login-server ${server_url} --authkey ${preauth_key}
GUIDE
            ;;
    esac

    cat >> "${guide_file}" <<GUIDE

STEP 3: Verify Connection
--------------------------
After connecting, verify:
  ping 10.8.0.1     (should respond - VPN gateway)
  ping 172.16.0.1   (should respond - service gateway)

STEP 4: Configure AI Tools
---------------------------
Set the following environment variables:

  export ANTHROPIC_BASE_URL=https://api.company-internal.com/v1
  export OPENAI_BASE_URL=https://api.company-internal.com/v1
GUIDE

    if [[ -n "${api_token}" ]]; then
        cat >> "${guide_file}" <<GUIDE

Your API Token: ${api_token}
  export ANTHROPIC_API_KEY=${api_token}
  export OPENAI_API_KEY=${api_token}
GUIDE
    fi

    cat >> "${guide_file}" <<'GUIDE'

IMPORTANT NOTES
----------------
- You MUST be connected to the VPN to access ANY company AI services.
- Do not share your VPN configuration or API token with anyone.
- If your config is compromised, contact your IT admin immediately.
- The VPN only routes company traffic (10.8.0.0/24 and 172.16.0.0/24).
  Your regular internet traffic is NOT affected.
================================================================================
GUIDE

    # Restrict permissions — guide may contain API tokens and VPN config details
    chmod 600 "${guide_file}"
    log_info "Setup guide generated: ${guide_file}"
}

# Get the next available IP in the VPN subnet.
_vpn_next_ip() {
    local base="10.8.0"
    local start=2  # .1 is the gateway, start from .2

    # Find the highest assigned IP
    local max_ip="${start}"
    if [[ -f "${VPN_STATE_FILE}" ]]; then
        local existing_ips
        existing_ips="$(grep "^USER_.*_IP=" "${VPN_STATE_FILE}" 2>/dev/null | cut -d'=' -f2 | sort -t'.' -k4 -n)"
        if [[ -n "${existing_ips}" ]]; then
            local last_octet
            last_octet="$(echo "${existing_ips}" | tail -1 | cut -d'.' -f4)"
            if (( last_octet >= max_ip )); then
                max_ip=$((last_octet + 1))
            fi
        fi
    fi

    if (( max_ip > 254 )); then
        die "VPN subnet exhausted. Maximum 253 clients (10.8.0.2 - 10.8.0.254)."
    fi

    echo "${base}.${max_ip}"
}

# Update the WireGuard server configuration with all current peers.
_vpn_update_server_config() {
    local server_privkey
    server_privkey="$(cat "${VPN_KEYS_DIR}/server.key" 2>/dev/null || _vpn_load_state "SERVER_PRIVATE_KEY")"

    local primary_iface
    primary_iface="$(_vpn_load_state "PRIMARY_IFACE")"
    primary_iface="${primary_iface:-eth0}"

    local wg_conf="/etc/wireguard/${WG_INTERFACE}.conf"
    mkdir -p /etc/wireguard

    cat > "${wg_conf}" <<CONF
# AI Gateway Bridge - WireGuard Server Configuration
# Auto-generated: $(date -Iseconds)

[Interface]
PrivateKey = ${server_privkey}
Address = ${VPN_GATEWAY}/24
ListenPort = ${WG_PORT}

# NAT and forwarding
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${primary_iface} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${primary_iface} -j MASQUERADE
CONF

    # Add all registered peers
    if [[ -f "${VPN_STATE_FILE}" ]]; then
        local users
        users="$(grep "^USER_.*_PUBKEY=" "${VPN_STATE_FILE}" 2>/dev/null || true)"
        while IFS='=' read -r key pubkey; do
            local user_name
            user_name="$(echo "${key}" | sed 's/^USER_//;s/_PUBKEY$//')"
            local user_ip
            user_ip="$(_vpn_load_state "USER_${user_name}_IP")"
            local psk_file="${VPN_USERS_DIR}/${user_name}/preshared.key"

            cat >> "${wg_conf}" <<PEER

# User: ${user_name}
[Peer]
PublicKey = ${pubkey}
AllowedIPs = ${user_ip}/32
PEER
            if [[ -f "${psk_file}" ]]; then
                echo "PresharedKey = $(cat "${psk_file}")" >> "${wg_conf}"
            fi
        done <<< "${users}"
    fi

    chmod 600 "${wg_conf}"
    log_info "WireGuard server config updated: ${wg_conf}"
}

# List all VPN users.
list_vpn_users() {
    print_section "VPN Users"

    local vpn_type
    vpn_type="$(_vpn_load_state "VPN_TYPE")"

    if [[ ! -d "${VPN_USERS_DIR}" ]]; then
        log_info "No users found."
        return 0
    fi

    local count=0
    local header_printed=0

    for user_dir in "${VPN_USERS_DIR}"/*/; do
        if [[ ! -d "${user_dir}" ]]; then
            continue
        fi

        local username
        username="$(basename "${user_dir}")"

        if (( header_printed == 0 )); then
            printf "  ${COLOR_BOLD}%-20s %-16s %-12s %-24s${COLOR_RESET}\n" \
                "USERNAME" "VPN IP" "STATUS" "CREATED"
            printf "  ${COLOR_DIM}%-20s %-16s %-12s %-24s${COLOR_RESET}\n" \
                "--------" "------" "------" "-------"
            header_printed=1
        fi

        local user_ip
        user_ip="$(_vpn_load_state "USER_${username}_IP")"
        user_ip="${user_ip:-N/A}"

        local created
        created="$(_vpn_load_state "USER_${username}_CREATED")"
        created="${created:-unknown}"

        local status="active"
        local revoked
        revoked="$(_vpn_load_state "USER_${username}_REVOKED")"
        if [[ -n "${revoked}" ]]; then
            status="revoked"
        fi

        printf "  %-20s %-16s %-12s %-24s\n" \
            "${username}" "${user_ip}" "${status}" "${created}"

        (( count++ )) || true
    done

    echo ""
    log_info "Total users: ${count}"

    # If using Headscale, also show Headscale nodes
    if [[ "${vpn_type}" == "headscale" ]] && check_command headscale; then
        echo ""
        log_info "Headscale registered nodes:"
        headscale nodes list 2>/dev/null || log_warn "Could not list Headscale nodes."
    fi
}

# Revoke a VPN user's access.
revoke_vpn_user() {
    local username="${1:-}"

    if [[ -z "${username}" ]]; then
        read_input "Enter username to revoke" "" "^[a-zA-Z0-9_-]+$"
        username="${INPUT_RESULT}"
    fi

    local user_dir="${VPN_USERS_DIR}/${username}"
    if [[ ! -d "${user_dir}" ]]; then
        die "User '${username}' not found."
    fi

    log_info "Revoking VPN access for: ${username}"

    if ! confirm_action "Are you sure you want to revoke VPN access for '${username}'?"; then
        log_info "Revocation cancelled."
        return 0
    fi

    local vpn_type
    vpn_type="$(_vpn_load_state "VPN_TYPE")"

    case "${vpn_type}" in
        firezone)
            # Remove from Firezone
            if docker compose -f "${FIREZONE_COMPOSE}" ps 2>/dev/null | grep -q "firezone"; then
                local user_email
                user_email="$(_vpn_load_state "USER_${username}_EMAIL")"
                if [[ -n "${user_email}" ]]; then
                    log_info "Removing user from Firezone..."
                    docker compose -f "${FIREZONE_COMPOSE}" exec -T firezone \
                        bin/delete-user --email "${user_email}" 2>/dev/null || \
                    log_warn "Could not remove user from Firezone. Remove manually."
                fi
            fi
            ;;
        headscale)
            # Remove from Headscale
            if check_command headscale; then
                log_info "Removing user nodes from Headscale..."
                local node_ids
                node_ids="$(headscale nodes list -o json 2>/dev/null | \
                    jq -r ".[] | select(.user.name==\"${username}\") | .id" 2>/dev/null || echo '')"
                for nid in ${node_ids}; do
                    headscale nodes delete --identifier "${nid}" --force 2>/dev/null || true
                done
            fi
            ;;
        *)
            # Remove WireGuard peer
            local user_pubkey
            user_pubkey="$(_vpn_load_state "USER_${username}_PUBKEY")"
            if [[ -n "${user_pubkey}" ]] && ip link show "${WG_INTERFACE}" &>/dev/null; then
                wg set "${WG_INTERFACE}" peer "${user_pubkey}" remove
                log_info "WireGuard peer removed from ${WG_INTERFACE}."
                _vpn_update_server_config
            fi
            ;;
    esac

    # Mark as revoked in state
    _vpn_save_state "USER_${username}_REVOKED" "$(date -Iseconds)"

    # Securely remove user config files
    if [[ -d "${user_dir}" ]]; then
        # Overwrite sensitive files before deletion
        find "${user_dir}" -type f -name "*.key" -exec shred -u {} \; 2>/dev/null || true
        find "${user_dir}" -type f -name "*.conf" -exec shred -u {} \; 2>/dev/null || true
        find "${user_dir}" -type f -name "api-token.txt" -exec shred -u {} \; 2>/dev/null || true
        rm -rf "${user_dir}"
    fi

    log_success "VPN access revoked for '${username}'. Configuration files securely deleted."
}

# =============================================================================
# Section 9 : Deployment Orchestrator
# =============================================================================

# Main VPN deployment orchestrator.
# Guides the admin through the complete VPN setup process.
deploy_vpn() {
    print_banner "AI Gateway Bridge - Enterprise VPN Setup"

    log_info "This will deploy the enterprise VPN as the FIRST security gate."
    log_info "All employees MUST connect to VPN before accessing ANY service."
    echo ""

    # ----- Prerequisites -----
    print_section "Step 1/5: Prerequisites"
    if ! detect_system; then
        log_error "Failed to detect system environment. Cannot continue with VPN deployment."
        return 1
    fi
    if ! _vpn_check_prerequisites; then
        log_error "VPN prerequisites check failed. Cannot continue with VPN deployment."
        return 1
    fi

    # ----- Choose VPN type -----
    print_section "Step 2/5: Select VPN Solution"
    local vpn_options=(
        "Firezone (Docker + WireGuard + Admin Portal) -- Recommended for most teams"
        "Headscale (Self-hosted Tailscale + DERP + ACL) -- For advanced mesh networking"
    )
    show_menu "Select VPN deployment type" vpn_options
    local vpn_choice="${MENU_RESULT}"

    # ----- Network configuration -----
    print_section "Step 3/5: Network Configuration"
    if ! setup_vpn_network; then
        log_error "VPN network configuration failed. Cannot continue with VPN deployment."
        return 1
    fi

    # ----- Deploy VPN server -----
    print_section "Step 4/5: VPN Server Deployment"

    case "${vpn_choice}" in
        1)
            if ! _vpn_install_wireguard; then
                log_error "WireGuard installation failed. Cannot continue with VPN deployment."
                return 1
            fi
            if ! _vpn_generate_server_keys; then
                log_error "WireGuard server key generation failed. Cannot continue with VPN deployment."
                return 1
            fi
            if ! _vpn_deploy_firezone; then
                log_error "Firezone deployment failed. Cannot continue with VPN deployment."
                return 1
            fi
            ;;
        2)
            if ! _vpn_deploy_headscale; then
                log_error "Headscale deployment failed. Cannot continue with VPN deployment."
                return 1
            fi
            ;;
        *)
            die "Invalid VPN choice: ${vpn_choice}"
            ;;
    esac

    # ----- Firewall -----
    print_section "Step 5/5: Firewall Configuration"
    if ! setup_vpn_firewall; then
        log_error "VPN firewall configuration failed. Cannot continue with VPN deployment."
        return 1
    fi

    # ----- Final summary -----
    print_section "VPN Deployment Complete"
    local vpn_type
    vpn_type="$(_vpn_load_state "VPN_TYPE")"
    print_kv "VPN Type"       "${vpn_type}"
    print_kv "VPN Subnet"     "${VPN_SUBNET}"
    print_kv "Service Subnet" "${SERVICE_SUBNET}"
    print_kv "WireGuard Port" "${WG_PORT}/udp"
    print_kv "Server IP"      "${PUBLIC_IP}"
    echo ""
    log_info "Next steps:"
    log_info "  1. Create VPN users:  vpn.sh create_user <username>"
    log_info "  2. Distribute configs to employees"
    log_info "  3. Verify employees can connect and access services"
    echo ""

    log_success "Enterprise VPN is now the FIRST gate. No service access without VPN."
}

# =============================================================================
# Section 10 : VPN Management Menu
# =============================================================================

# Interactive VPN management menu.
vpn_management_menu() {
    print_banner "VPN Management"

    local vpn_type
    vpn_type="$(_vpn_load_state "VPN_TYPE")"
    if [[ -z "${vpn_type}" ]]; then
        log_warn "No VPN deployment detected."
        if confirm_action "Deploy VPN now?"; then
            deploy_vpn
            return $?
        fi
        return 0
    fi

    print_kv "Active VPN" "${vpn_type}"
    echo ""

    local options=(
        "Create new VPN user"
        "List VPN users"
        "Revoke VPN user"
        "Show VPN status"
        "Restart VPN service"
        "Reconfigure firewall"
        "Back to main menu"
    )
    show_menu "VPN Management" options

    case "${MENU_RESULT}" in
        1) create_vpn_user ;;
        2) list_vpn_users ;;
        3) revoke_vpn_user ;;
        4) _vpn_show_status ;;
        5) _vpn_restart ;;
        6) setup_vpn_firewall ;;
        7) return 0 ;;
        *) log_error "Invalid choice." ;;
    esac
}

# Show VPN service status.
_vpn_show_status() {
    print_section "VPN Status"

    local vpn_type
    vpn_type="$(_vpn_load_state "VPN_TYPE")"
    print_kv "VPN Type" "${vpn_type:-not deployed}"

    case "${vpn_type}" in
        firezone)
            if [[ -d "${FIREZONE_DIR}" ]]; then
                log_info "Firezone containers:"
                cd "${FIREZONE_DIR}" && docker compose ps 2>/dev/null || log_warn "Cannot get Firezone status."
            fi
            ;;
        headscale)
            check_service_status headscale || true
            if check_command headscale; then
                echo ""
                log_info "Headscale nodes:"
                headscale nodes list 2>/dev/null || true
            fi
            ;;
        *)
            if ip link show "${WG_INTERFACE}" &>/dev/null; then
                log_info "WireGuard interface:"
                wg show "${WG_INTERFACE}" 2>/dev/null || true
            else
                log_warn "WireGuard interface ${WG_INTERFACE} is not active."
            fi
            ;;
    esac

    echo ""
    log_info "Network status:"
    print_kv "IP Forward" "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 'unknown')"
    print_kv "WG Port" "$(if check_port_open ${WG_PORT}; then echo 'OPEN'; else echo 'CLOSED'; fi)"

    # Show connected peers
    if ip link show "${WG_INTERFACE}" &>/dev/null; then
        echo ""
        log_info "Connected peers:"
        wg show "${WG_INTERFACE}" latest-handshakes 2>/dev/null | while read -r pubkey handshake; do
            if (( handshake > 0 )); then
                local age=$(( $(date +%s) - handshake ))
                if (( age < 180 )); then
                    echo "  [ONLINE]  ${pubkey:0:20}... (last handshake: ${age}s ago)"
                else
                    echo "  [OFFLINE] ${pubkey:0:20}... (last handshake: ${age}s ago)"
                fi
            fi
        done
    fi
}

# Restart VPN service.
_vpn_restart() {
    local vpn_type
    vpn_type="$(_vpn_load_state "VPN_TYPE")"

    case "${vpn_type}" in
        firezone)
            log_info "Restarting Firezone..."
            cd "${FIREZONE_DIR}" && docker compose restart
            ;;
        headscale)
            restart_service headscale
            ;;
        *)
            log_info "Restarting WireGuard..."
            if check_command wg-quick; then
                wg-quick down "${WG_INTERFACE}" 2>/dev/null || true
                wg-quick up "${WG_INTERFACE}"
            else
                ip link set "${WG_INTERFACE}" down 2>/dev/null || true
                ip link set "${WG_INTERFACE}" up 2>/dev/null || true
            fi
            ;;
    esac

    log_success "VPN service restarted."
}

# =============================================================================
# Section 11 : CLI Entry Point
# =============================================================================

# When called directly (not sourced), handle CLI arguments.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        deploy)
            deploy_vpn
            ;;
        create_user|create-user)
            detect_system
            create_vpn_user "${2:-}"
            ;;
        list_users|list-users|list)
            list_vpn_users
            ;;
        revoke_user|revoke-user|revoke)
            detect_system
            revoke_vpn_user "${2:-}"
            ;;
        status)
            detect_system
            _vpn_show_status
            ;;
        restart)
            detect_system
            _vpn_restart
            ;;
        menu)
            detect_system
            vpn_management_menu
            ;;
        *)
            echo "Usage: $0 {deploy|create_user|list_users|revoke_user|status|restart|menu}"
            echo ""
            echo "Commands:"
            echo "  deploy               Full VPN deployment (interactive)"
            echo "  create_user [name]   Create a new VPN user"
            echo "  list_users           List all VPN users"
            echo "  revoke_user [name]   Revoke a user's VPN access"
            echo "  status               Show VPN status"
            echo "  restart              Restart VPN service"
            echo "  menu                 Interactive management menu"
            exit 1
            ;;
    esac
fi
