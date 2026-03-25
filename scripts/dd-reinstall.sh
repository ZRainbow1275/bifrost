#!/usr/bin/env bash
# =============================================================================
# AI Gateway Bridge - Cloud Agent Cleanup & DD Reinstall Module
# =============================================================================
# Description : Detects cloud provider, identifies and removes pre-installed
#               monitoring agents / security daemons / telemetry, and
#               optionally performs a full DD reinstall using bin456789/reinstall.
#
# Usage       : source "$(dirname "${BASH_SOURCE[0]}")/dd-reinstall.sh"
#               pre_deploy_check      # Call at the start of deployment
#
# Targets     : Chinese cloud providers (Tencent, Alibaba, Huawei, JD, Baidu,
#               UCloud, Volcengine, Kingsoft, QingCloud, CTyun) and
#               international providers (AWS, GCP, Azure, Vultr, DigitalOcean,
#               Linode, OVH, Hetzner, Bandwagon, DMIT, RackNerd).
#
# Database    : configs/cloud-agents.conf
# Project     : AI Gateway Bridge (国内外 AI 服务桥接一键部署方案)
# License     : MIT
# =============================================================================

set -euo pipefail

# Guard against double-sourcing (readonly variables would conflict)
if [[ -n "${_DD_REINSTALL_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
readonly _DD_REINSTALL_SH_LOADED=1

# Source shared utilities (colors, logging, OS detection, helpers)
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# =============================================================================
# Constants
# =============================================================================

readonly CLOUD_AGENTS_CONF="${PROJECT_ROOT}/configs/cloud-agents.conf"
readonly DD_REINSTALL_SCRIPT_URL="https://cnb.cool/bin456789/reinstall/-/git/raw/main/reinstall.sh"
readonly DD_REINSTALL_FALLBACK_URL="https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh"

# State tracking
DETECTED_PROVIDER=""
declare -a DETECTED_AGENTS_SERVICES=()
declare -a DETECTED_AGENTS_PROCESSES=()
declare -a DETECTED_AGENTS_PACKAGES=()
declare -a DETECTED_AGENTS_PATHS=()
declare -a DETECTED_AGENTS_CRONS=()

# =============================================================================
# Section 1 : Cloud Provider Detection
# =============================================================================

# -----------------------------------------------------------------------------
# detect_cloud_provider:
#   Detect the cloud provider via multiple methods:
#     1. dmidecode (BIOS/system manufacturer/product)
#     2. /sys/class/dmi/id/ sysfs entries
#     3. Metadata API endpoints (provider-specific)
#     4. Filesystem markers (agent paths, hostnames, etc.)
#
#   Sets: DETECTED_PROVIDER (lowercase provider name)
#   Returns: 0 if detected, 1 if unknown
# -----------------------------------------------------------------------------
detect_cloud_provider() {
    log_info "Detecting cloud provider..."
    DETECTED_PROVIDER=""

    local manufacturer="" product="" bios_vendor="" sys_vendor=""

    # ----- Method 1: DMI / SMBIOS data (dmidecode) -----
    if check_command dmidecode; then
        manufacturer="$(dmidecode -s system-manufacturer 2>/dev/null || true)"
        product="$(dmidecode -s system-product-name 2>/dev/null || true)"
        bios_vendor="$(dmidecode -s bios-vendor 2>/dev/null || true)"
    fi

    # ----- Method 2: sysfs DMI entries (no dmidecode required) -----
    if [[ -z "${manufacturer}" && -f /sys/class/dmi/id/sys_vendor ]]; then
        sys_vendor="$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || true)"
        manufacturer="${sys_vendor}"
    fi
    if [[ -z "${product}" && -f /sys/class/dmi/id/product_name ]]; then
        product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
    fi
    if [[ -z "${bios_vendor}" && -f /sys/class/dmi/id/bios_vendor ]]; then
        bios_vendor="$(cat /sys/class/dmi/id/bios_vendor 2>/dev/null || true)"
    fi

    # Normalize to lowercase for matching
    manufacturer="${manufacturer,,}"
    product="${product,,}"
    bios_vendor="${bios_vendor,,}"

    local dmi_combined="${manufacturer} ${product} ${bios_vendor}"

    # ----- Match by DMI strings -----
    if [[ "${dmi_combined}" == *"tencent"* ]] || [[ "${dmi_combined}" == *"qcloud"* ]]; then
        DETECTED_PROVIDER="tencent"
    elif [[ "${dmi_combined}" == *"alibaba"* ]] || [[ "${dmi_combined}" == *"aliyun"* ]]; then
        DETECTED_PROVIDER="alibaba"
    elif [[ "${dmi_combined}" == *"huawei"* ]] || [[ "${dmi_combined}" == *"hwcloud"* ]]; then
        DETECTED_PROVIDER="huawei"
    elif [[ "${dmi_combined}" == *"jdcloud"* ]] || [[ "${dmi_combined}" == *"jd.com"* ]]; then
        DETECTED_PROVIDER="jd"
    elif [[ "${dmi_combined}" == *"baidu"* ]] || [[ "${dmi_combined}" == *"baiducloud"* ]]; then
        DETECTED_PROVIDER="baidu"
    elif [[ "${dmi_combined}" == *"ucloud"* ]]; then
        DETECTED_PROVIDER="ucloud"
    elif [[ "${dmi_combined}" == *"volcengine"* ]] || [[ "${dmi_combined}" == *"bytedance"* ]]; then
        DETECTED_PROVIDER="volcengine"
    elif [[ "${dmi_combined}" == *"kingsoft"* ]] || [[ "${dmi_combined}" == *"ksyun"* ]]; then
        DETECTED_PROVIDER="kingsoft"
    elif [[ "${dmi_combined}" == *"qingcloud"* ]]; then
        DETECTED_PROVIDER="qingcloud"
    elif [[ "${dmi_combined}" == *"ctyun"* ]] || [[ "${dmi_combined}" == *"chinatelecom"* ]]; then
        DETECTED_PROVIDER="ctyun"
    elif [[ "${dmi_combined}" == *"amazon"* ]] || [[ "${dmi_combined}" == *"aws"* ]] || [[ "${dmi_combined}" == *"xen"* && "${dmi_combined}" == *"ec2"* ]]; then
        DETECTED_PROVIDER="aws"
    elif [[ "${dmi_combined}" == *"google"* ]]; then
        DETECTED_PROVIDER="gcp"
    elif [[ "${dmi_combined}" == *"microsoft"* ]] || [[ "${dmi_combined}" == *"hyper-v"* ]]; then
        DETECTED_PROVIDER="azure"
    elif [[ "${dmi_combined}" == *"vultr"* ]]; then
        DETECTED_PROVIDER="vultr"
    elif [[ "${dmi_combined}" == *"digitalocean"* ]]; then
        DETECTED_PROVIDER="digitalocean"
    elif [[ "${dmi_combined}" == *"linode"* ]] || [[ "${dmi_combined}" == *"akamai"* ]]; then
        DETECTED_PROVIDER="linode"
    elif [[ "${dmi_combined}" == *"hetzner"* ]]; then
        DETECTED_PROVIDER="hetzner"
    elif [[ "${dmi_combined}" == *"ovh"* ]]; then
        DETECTED_PROVIDER="ovh"
    fi

    # ----- Method 3: Metadata API detection (if DMI was inconclusive) -----
    if [[ -z "${DETECTED_PROVIDER}" ]]; then
        _detect_via_metadata_api
    fi

    # ----- Method 4: Filesystem markers -----
    if [[ -z "${DETECTED_PROVIDER}" ]]; then
        _detect_via_filesystem_markers
    fi

    # ----- Report result -----
    if [[ -n "${DETECTED_PROVIDER}" ]]; then
        log_success "Cloud provider detected: ${DETECTED_PROVIDER}"
        return 0
    else
        log_warn "Could not determine cloud provider (may be bare metal or unknown VPS)."
        DETECTED_PROVIDER="unknown"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# _detect_via_metadata_api:
#   Probe provider-specific metadata endpoints.
#   Sets DETECTED_PROVIDER if a probe succeeds.
# -----------------------------------------------------------------------------
_detect_via_metadata_api() {
    local timeout=3

    # Tencent Cloud metadata
    if curl -s --connect-timeout "${timeout}" --max-time "${timeout}" \
        "http://metadata.tencentyun.com/latest/meta-data/" &>/dev/null; then
        DETECTED_PROVIDER="tencent"
        return 0
    fi

    # Alibaba Cloud metadata
    if curl -s --connect-timeout "${timeout}" --max-time "${timeout}" \
        "http://100.100.100.200/latest/meta-data/" &>/dev/null; then
        DETECTED_PROVIDER="alibaba"
        return 0
    fi

    # Huawei Cloud metadata
    if curl -s --connect-timeout "${timeout}" --max-time "${timeout}" \
        "http://169.254.169.254/openstack/latest/meta_data.json" &>/dev/null; then
        # Huawei uses OpenStack metadata — further check for Huawei-specific data
        local huawei_check
        huawei_check="$(curl -s --connect-timeout "${timeout}" --max-time "${timeout}" \
            "http://169.254.169.254/openstack/latest/meta_data.json" 2>/dev/null || true)"
        if [[ "${huawei_check}" == *"hwcloud"* ]] || [[ "${huawei_check}" == *"huawei"* ]]; then
            DETECTED_PROVIDER="huawei"
            return 0
        fi
    fi

    # JD Cloud metadata
    if curl -s --connect-timeout "${timeout}" --max-time "${timeout}" \
        "http://169.254.169.254/metadata/latest/local-ipv4" &>/dev/null; then
        local jd_check
        jd_check="$(curl -s --connect-timeout "${timeout}" --max-time "${timeout}" \
            "http://169.254.169.254/metadata/latest/" 2>/dev/null || true)"
        if [[ "${jd_check}" == *"jdcloud"* ]] || [[ "${jd_check}" == *"jd.com"* ]]; then
            DETECTED_PROVIDER="jd"
            return 0
        fi
    fi

    # Baidu Cloud metadata
    if curl -s --connect-timeout "${timeout}" --max-time "${timeout}" \
        "http://169.254.169.254/1.0/meta-data/" &>/dev/null; then
        local baidu_check
        baidu_check="$(curl -s --connect-timeout "${timeout}" --max-time "${timeout}" \
            "http://169.254.169.254/1.0/meta-data/local-hostname" 2>/dev/null || true)"
        if [[ "${baidu_check}" == *"bcc"* ]] || [[ "${baidu_check}" == *"baidu"* ]]; then
            DETECTED_PROVIDER="baidu"
            return 0
        fi
    fi

    # Volcengine metadata
    if curl -s --connect-timeout "${timeout}" --max-time "${timeout}" \
        "http://100.96.0.96/volcstack/latest/meta-data/" &>/dev/null; then
        DETECTED_PROVIDER="volcengine"
        return 0
    fi

    # AWS metadata (IMDSv1 fallback, then IMDSv2 token)
    if curl -s --connect-timeout "${timeout}" --max-time "${timeout}" \
        "http://169.254.169.254/latest/meta-data/ami-id" &>/dev/null; then
        DETECTED_PROVIDER="aws"
        return 0
    fi
    # AWS IMDSv2
    local imds_token
    imds_token="$(curl -s --connect-timeout "${timeout}" --max-time "${timeout}" \
        -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || true)"
    if [[ -n "${imds_token}" ]]; then
        if curl -s --connect-timeout "${timeout}" --max-time "${timeout}" \
            -H "X-aws-ec2-metadata-token: ${imds_token}" \
            "http://169.254.169.254/latest/meta-data/ami-id" &>/dev/null; then
            DETECTED_PROVIDER="aws"
            return 0
        fi
    fi

    # GCP metadata
    if curl -s --connect-timeout "${timeout}" --max-time "${timeout}" \
        -H "Metadata-Flavor: Google" \
        "http://metadata.google.internal/computeMetadata/v1/" &>/dev/null; then
        DETECTED_PROVIDER="gcp"
        return 0
    fi

    # Azure IMDS
    if curl -s --connect-timeout "${timeout}" --max-time "${timeout}" \
        -H "Metadata: true" \
        "http://169.254.169.254/metadata/instance?api-version=2021-02-01" &>/dev/null; then
        DETECTED_PROVIDER="azure"
        return 0
    fi

    # Vultr metadata
    if curl -s --connect-timeout "${timeout}" --max-time "${timeout}" \
        "http://169.254.169.254/v1.json" 2>/dev/null | grep -q "instanceid"; then
        DETECTED_PROVIDER="vultr"
        return 0
    fi

    # DigitalOcean metadata
    if curl -s --connect-timeout "${timeout}" --max-time "${timeout}" \
        "http://169.254.169.254/metadata/v1/id" &>/dev/null; then
        DETECTED_PROVIDER="digitalocean"
        return 0
    fi

    # Linode metadata
    if curl -s --connect-timeout "${timeout}" --max-time "${timeout}" \
        "http://169.254.169.254/v1.0" &>/dev/null; then
        local linode_check
        linode_check="$(curl -s --connect-timeout "${timeout}" --max-time "${timeout}" \
            "http://169.254.169.254/v1.0" 2>/dev/null || true)"
        if [[ "${linode_check}" == *"linode"* ]]; then
            DETECTED_PROVIDER="linode"
            return 0
        fi
    fi

    return 1
}

# -----------------------------------------------------------------------------
# _detect_via_filesystem_markers:
#   Check for well-known agent paths to infer the provider.
#   Sets DETECTED_PROVIDER if a unique marker is found.
# -----------------------------------------------------------------------------
_detect_via_filesystem_markers() {
    # Tencent Cloud markers
    if [[ -d /usr/local/qcloud ]]; then
        DETECTED_PROVIDER="tencent"
        return 0
    fi

    # Alibaba Cloud markers
    if [[ -d /usr/local/aegis ]] || [[ -d /usr/local/cloudmonitor ]] || [[ -f /usr/sbin/aliyun-service ]]; then
        DETECTED_PROVIDER="alibaba"
        return 0
    fi

    # Huawei Cloud markers
    if [[ -d /usr/local/hostguard ]] || [[ -d /opt/cloud/telescope ]]; then
        DETECTED_PROVIDER="huawei"
        return 0
    fi

    # JD Cloud markers
    if [[ -d /usr/local/jdog ]] || [[ -d /opt/jdog ]]; then
        DETECTED_PROVIDER="jd"
        return 0
    fi

    # Baidu Cloud markers
    if [[ -d /usr/local/hosteye ]] || [[ -d /opt/bcm ]]; then
        DETECTED_PROVIDER="baidu"
        return 0
    fi

    # UCloud markers
    if [[ -d /opt/ucloud ]]; then
        DETECTED_PROVIDER="ucloud"
        return 0
    fi

    # Volcengine markers
    if [[ -d /opt/volcengine ]]; then
        DETECTED_PROVIDER="volcengine"
        return 0
    fi

    # Kingsoft Cloud markers
    if [[ -d /opt/kingsoft ]]; then
        DETECTED_PROVIDER="kingsoft"
        return 0
    fi

    # QingCloud markers
    if [[ -d /opt/qingcloud ]]; then
        DETECTED_PROVIDER="qingcloud"
        return 0
    fi

    # CTyun markers
    if [[ -d /opt/ctyun ]]; then
        DETECTED_PROVIDER="ctyun"
        return 0
    fi

    # AWS markers
    if [[ -d /var/lib/amazon ]] || [[ -f /usr/bin/amazon-ssm-agent ]]; then
        DETECTED_PROVIDER="aws"
        return 0
    fi

    # GCP markers
    if [[ -f /usr/bin/google_guest_agent ]] || [[ -d /opt/google-cloud-ops-agent ]]; then
        DETECTED_PROVIDER="gcp"
        return 0
    fi

    # Azure markers
    if [[ -f /usr/sbin/waagent ]] || [[ -d /var/lib/waagent ]]; then
        DETECTED_PROVIDER="azure"
        return 0
    fi

    # Vultr markers
    if [[ -f /usr/local/bin/vultr-agent ]] || [[ -d /opt/vultr ]]; then
        DETECTED_PROVIDER="vultr"
        return 0
    fi

    # DigitalOcean markers
    if [[ -d /opt/digitalocean ]]; then
        DETECTED_PROVIDER="digitalocean"
        return 0
    fi

    # Linode markers
    if [[ -d /opt/linode ]]; then
        DETECTED_PROVIDER="linode"
        return 0
    fi

    # Hostname-based heuristic (last resort)
    local hostname_str
    hostname_str="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || true)"
    hostname_str="${hostname_str,,}"

    if [[ "${hostname_str}" == *"tencent"* ]] || [[ "${hostname_str}" == *"qcloud"* ]]; then
        DETECTED_PROVIDER="tencent"
    elif [[ "${hostname_str}" == *"alibaba"* ]] || [[ "${hostname_str}" == *"aliyun"* ]]; then
        DETECTED_PROVIDER="alibaba"
    elif [[ "${hostname_str}" == *"huawei"* ]]; then
        DETECTED_PROVIDER="huawei"
    elif [[ "${hostname_str}" == *"jd"* ]]; then
        DETECTED_PROVIDER="jd"
    fi

    [[ -n "${DETECTED_PROVIDER}" ]]
}

# =============================================================================
# Section 2 : Pre-installed Agent Detection
# =============================================================================

# -----------------------------------------------------------------------------
# detect_preinstalled_agents:
#   Scan for all known cloud provider agents on the system.
#   Checks services, processes, packages, and file paths from the config.
#
#   Uses: configs/cloud-agents.conf
#   Sets: DETECTED_AGENTS_SERVICES, DETECTED_AGENTS_PROCESSES,
#          DETECTED_AGENTS_PACKAGES, DETECTED_AGENTS_PATHS
#   Returns: 0 if any agents found, 1 if clean
# -----------------------------------------------------------------------------
detect_preinstalled_agents() {
    log_info "Scanning for pre-installed cloud agents..."

    # Reset detection arrays
    DETECTED_AGENTS_SERVICES=()
    DETECTED_AGENTS_PROCESSES=()
    DETECTED_AGENTS_PACKAGES=()
    DETECTED_AGENTS_PATHS=()
    DETECTED_AGENTS_CRONS=()

    if [[ ! -f "${CLOUD_AGENTS_CONF}" ]]; then
        log_warn "Cloud agents config not found: ${CLOUD_AGENTS_CONF}"
        log_warn "Falling back to hardcoded detection for major providers..."
        _detect_agents_hardcoded
        _report_detected_agents
        return $(( ${#DETECTED_AGENTS_SERVICES[@]} + ${#DETECTED_AGENTS_PROCESSES[@]} + ${#DETECTED_AGENTS_PATHS[@]} == 0 ? 1 : 0 ))
    fi

    # Determine which provider sections to scan
    local -a providers_to_scan=()
    if [[ "${DETECTED_PROVIDER}" != "unknown" && -n "${DETECTED_PROVIDER}" ]]; then
        providers_to_scan+=("${DETECTED_PROVIDER}")
    fi
    # Always scan 'generic' section
    providers_to_scan+=("generic")

    local current_section=""
    local should_scan=0

    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Skip empty lines and comments
        [[ -z "${line}" ]] && continue
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue

        # Trim whitespace
        line="$(echo "${line}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

        # Section header
        if [[ "${line}" =~ ^\[([a-zA-Z0-9_]+)\]$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            should_scan=0
            for p in ${providers_to_scan[@]+"${providers_to_scan[@]}"}; do
                if [[ "${current_section}" == "${p}" ]]; then
                    should_scan=1
                    break
                fi
            done
            continue
        fi

        # Skip if not in a section we care about
        [[ ${should_scan} -eq 0 ]] && continue

        # Parse key=value
        if [[ "${line}" =~ ^([a-z]+)=(.+)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"

            case "${key}" in
                service)
                    if systemctl list-unit-files "${value}.service" &>/dev/null 2>&1 || \
                       systemctl is-active "${value}" &>/dev/null 2>&1 || \
                       systemctl cat "${value}.service" &>/dev/null 2>&1; then
                        # Verify the unit actually exists (list-unit-files can succeed even on missing units)
                        if systemctl status "${value}" &>/dev/null 2>&1 || \
                           [[ -f "/etc/systemd/system/${value}.service" ]] || \
                           [[ -f "/usr/lib/systemd/system/${value}.service" ]] || \
                           [[ -f "/lib/systemd/system/${value}.service" ]]; then
                            _add_unique DETECTED_AGENTS_SERVICES "${value}"
                        fi
                    fi
                    ;;
                process)
                    if pgrep -x "${value}" &>/dev/null || pgrep -f "${value}" &>/dev/null; then
                        _add_unique DETECTED_AGENTS_PROCESSES "${value}"
                    fi
                    ;;
                package)
                    if _is_package_installed "${value}"; then
                        _add_unique DETECTED_AGENTS_PACKAGES "${value}"
                    fi
                    ;;
                path)
                    # Support glob patterns in path values
                    local expanded_path
                    for expanded_path in ${value}; do
                        if [[ -e "${expanded_path}" ]]; then
                            _add_unique DETECTED_AGENTS_PATHS "${expanded_path}"
                        fi
                    done
                    ;;
                cron)
                    if crontab -l 2>/dev/null | grep -qF "${value}"; then
                        _add_unique DETECTED_AGENTS_CRONS "${value}"
                    fi
                    # Also check system crontabs
                    if grep -rlF "${value}" /etc/cron.d/ /etc/cron.daily/ /etc/cron.hourly/ \
                       /var/spool/cron/ 2>/dev/null | head -1 | grep -q .; then
                        _add_unique DETECTED_AGENTS_CRONS "${value}"
                    fi
                    ;;
            esac
        fi
    done < "${CLOUD_AGENTS_CONF}"

    # Additionally scan ALL provider sections if provider is unknown
    if [[ "${DETECTED_PROVIDER}" == "unknown" ]]; then
        log_info "Provider unknown — performing full scan across all known providers..."
        _detect_agents_all_providers
    fi

    _report_detected_agents

    if (( ${#DETECTED_AGENTS_SERVICES[@]} + ${#DETECTED_AGENTS_PROCESSES[@]} + \
          ${#DETECTED_AGENTS_PACKAGES[@]} + ${#DETECTED_AGENTS_PATHS[@]} == 0 )); then
        log_success "No known cloud agents detected. System appears clean."
        return 1
    fi

    return 0
}

# -----------------------------------------------------------------------------
# _detect_agents_all_providers:
#   When provider is unknown, scan every section in the config file.
# -----------------------------------------------------------------------------
_detect_agents_all_providers() {
    local current_section=""

    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -z "${line}" ]] && continue
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        line="$(echo "${line}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

        if [[ "${line}" =~ ^\[([a-zA-Z0-9_]+)\]$ ]]; then
            current_section="${BASH_REMATCH[1]}"
            continue
        fi

        if [[ "${line}" =~ ^([a-z]+)=(.+)$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"

            case "${key}" in
                service)
                    if [[ -f "/etc/systemd/system/${value}.service" ]] || \
                       [[ -f "/usr/lib/systemd/system/${value}.service" ]] || \
                       [[ -f "/lib/systemd/system/${value}.service" ]]; then
                        _add_unique DETECTED_AGENTS_SERVICES "${value}"
                        [[ "${DETECTED_PROVIDER}" == "unknown" ]] && DETECTED_PROVIDER="${current_section}"
                    fi
                    ;;
                process)
                    if pgrep -x "${value}" &>/dev/null; then
                        _add_unique DETECTED_AGENTS_PROCESSES "${value}"
                        [[ "${DETECTED_PROVIDER}" == "unknown" ]] && DETECTED_PROVIDER="${current_section}"
                    fi
                    ;;
                path)
                    for expanded_path in ${value}; do
                        if [[ -e "${expanded_path}" ]]; then
                            _add_unique DETECTED_AGENTS_PATHS "${expanded_path}"
                            [[ "${DETECTED_PROVIDER}" == "unknown" ]] && DETECTED_PROVIDER="${current_section}"
                        fi
                    done
                    ;;
            esac
        fi
    done < "${CLOUD_AGENTS_CONF}"
}

# -----------------------------------------------------------------------------
# _detect_agents_hardcoded:
#   Fallback: detect major providers' agents without the config file.
# -----------------------------------------------------------------------------
_detect_agents_hardcoded() {
    log_info "Running hardcoded agent detection..."

    # --- Tencent ---
    local -a tencent_services=(tat_agent sgagent barad_agent YunJing)
    local -a tencent_paths=(/usr/local/qcloud)
    # --- Alibaba ---
    local -a alibaba_services=(aegis AliYunDun AliYunDunUpdate cloudmonitor aliyun)
    local -a alibaba_paths=(/usr/local/aegis /usr/local/cloudmonitor /usr/local/share/aliyun-assist)
    # --- Huawei ---
    local -a huawei_services=(hostguard telescope uniagent)
    local -a huawei_paths=(/usr/local/hostguard /usr/local/telescope /opt/cloud/hostguard)
    # --- JD ---
    local -a jd_services=(jdog jdog-monitor ifrit)
    local -a jd_paths=(/usr/local/jdog /opt/jdog)
    # --- Baidu ---
    local -a baidu_services=(hosteye bcm-agent)
    local -a baidu_paths=(/usr/local/hosteye /opt/bcm)

    local svc path
    for svc in ${tencent_services[@]+"${tencent_services[@]}"} ${alibaba_services[@]+"${alibaba_services[@]}"} ${huawei_services[@]+"${huawei_services[@]}"} \
               ${jd_services[@]+"${jd_services[@]}"} ${baidu_services[@]+"${baidu_services[@]}"}; do
        if systemctl is-active "${svc}" &>/dev/null 2>&1 || \
           [[ -f "/etc/systemd/system/${svc}.service" ]] || \
           [[ -f "/lib/systemd/system/${svc}.service" ]]; then
            _add_unique DETECTED_AGENTS_SERVICES "${svc}"
        fi
    done

    for path in ${tencent_paths[@]+"${tencent_paths[@]}"} ${alibaba_paths[@]+"${alibaba_paths[@]}"} ${huawei_paths[@]+"${huawei_paths[@]}"} \
                ${jd_paths[@]+"${jd_paths[@]}"} ${baidu_paths[@]+"${baidu_paths[@]}"}; do
        if [[ -e "${path}" ]]; then
            _add_unique DETECTED_AGENTS_PATHS "${path}"
        fi
    done
}

# -----------------------------------------------------------------------------
# _add_unique: Add a value to a named array only if not already present.
# Arguments: $1=array_name, $2=value
# -----------------------------------------------------------------------------
_add_unique() {
    local -n arr_ref="${1}"
    local val="${2}"

    for existing in "${arr_ref[@]+"${arr_ref[@]}"}"; do
        if [[ "${existing}" == "${val}" ]]; then
            return 0
        fi
    done

    arr_ref+=("${val}")
}

# -----------------------------------------------------------------------------
# _is_package_installed: Check if a package is installed via dpkg or rpm.
# Arguments: $1=package_name
# Returns: 0 if installed, 1 otherwise
# -----------------------------------------------------------------------------
_is_package_installed() {
    local pkg="${1}"

    if check_command dpkg; then
        dpkg -l "${pkg}" 2>/dev/null | grep -q "^ii" && return 0
    fi
    if check_command rpm; then
        rpm -q "${pkg}" &>/dev/null && return 0
    fi

    return 1
}

# -----------------------------------------------------------------------------
# _report_detected_agents: Print a summary of detected agents.
# -----------------------------------------------------------------------------
_report_detected_agents() {
    local total=$(( ${#DETECTED_AGENTS_SERVICES[@]} + ${#DETECTED_AGENTS_PROCESSES[@]} + \
                    ${#DETECTED_AGENTS_PACKAGES[@]} + ${#DETECTED_AGENTS_PATHS[@]} + \
                    ${#DETECTED_AGENTS_CRONS[@]} ))

    if (( total == 0 )); then
        return 0
    fi

    print_section "Detected Cloud Agents (${total} items)"

    if (( ${#DETECTED_AGENTS_SERVICES[@]} > 0 )); then
        echo -e "  ${COLOR_BOLD}Services:${COLOR_RESET}"
        for svc in ${DETECTED_AGENTS_SERVICES[@]+"${DETECTED_AGENTS_SERVICES[@]}"}; do
            local status
            status="$(systemctl is-active "${svc}" 2>/dev/null || echo 'unknown')"
            echo -e "    - ${COLOR_YELLOW}${svc}${COLOR_RESET} [${status}]"
        done
    fi

    if (( ${#DETECTED_AGENTS_PROCESSES[@]} > 0 )); then
        echo -e "  ${COLOR_BOLD}Processes:${COLOR_RESET}"
        for proc in ${DETECTED_AGENTS_PROCESSES[@]+"${DETECTED_AGENTS_PROCESSES[@]}"}; do
            echo -e "    - ${COLOR_YELLOW}${proc}${COLOR_RESET}"
        done
    fi

    if (( ${#DETECTED_AGENTS_PACKAGES[@]} > 0 )); then
        echo -e "  ${COLOR_BOLD}Packages:${COLOR_RESET}"
        for pkg in ${DETECTED_AGENTS_PACKAGES[@]+"${DETECTED_AGENTS_PACKAGES[@]}"}; do
            echo -e "    - ${COLOR_YELLOW}${pkg}${COLOR_RESET}"
        done
    fi

    if (( ${#DETECTED_AGENTS_PATHS[@]} > 0 )); then
        echo -e "  ${COLOR_BOLD}Paths:${COLOR_RESET}"
        for p in ${DETECTED_AGENTS_PATHS[@]+"${DETECTED_AGENTS_PATHS[@]}"}; do
            echo -e "    - ${COLOR_YELLOW}${p}${COLOR_RESET}"
        done
    fi

    if (( ${#DETECTED_AGENTS_CRONS[@]} > 0 )); then
        echo -e "  ${COLOR_BOLD}Cron entries:${COLOR_RESET}"
        for c in ${DETECTED_AGENTS_CRONS[@]+"${DETECTED_AGENTS_CRONS[@]}"}; do
            echo -e "    - ${COLOR_YELLOW}${c}${COLOR_RESET}"
        done
    fi

    echo ""
    log_warn "These agents may: report system activity to the cloud provider, consume " \
             "resources, interfere with custom deployments, or re-enable themselves after removal."
}

# =============================================================================
# Section 3 : Cloud Agent Removal
# =============================================================================

# -----------------------------------------------------------------------------
# remove_cloud_agents:
#   Stop, disable, and remove all detected cloud agents.
#   Operates on the arrays populated by detect_preinstalled_agents().
#
#   Steps:
#     1. Stop & disable systemd services
#     2. Kill remaining processes
#     3. Remove packages (apt/yum/dnf)
#     4. Remove files and directories
#     5. Remove cron entries
#     6. Remove provider-specific apt/yum repositories
#     7. Clean package manager cache
#
#   Returns: 0 on success
# -----------------------------------------------------------------------------
remove_cloud_agents() {
    local total=$(( ${#DETECTED_AGENTS_SERVICES[@]} + ${#DETECTED_AGENTS_PROCESSES[@]} + \
                    ${#DETECTED_AGENTS_PACKAGES[@]} + ${#DETECTED_AGENTS_PATHS[@]} + \
                    ${#DETECTED_AGENTS_CRONS[@]} ))

    if (( total == 0 )); then
        log_info "No agents to remove."
        return 0
    fi

    log_info "Removing ${total} detected cloud agent components..."

    # --- Step 1: Stop and disable services ---
    if (( ${#DETECTED_AGENTS_SERVICES[@]} > 0 )); then
        print_step 1 "Stopping and disabling services..."
        for svc in ${DETECTED_AGENTS_SERVICES[@]+"${DETECTED_AGENTS_SERVICES[@]}"}; do
            log_info "  Stopping: ${svc}"
            systemctl stop "${svc}" 2>/dev/null || true
            systemctl disable "${svc}" 2>/dev/null || true
            # Mask to prevent re-enablement
            systemctl mask "${svc}" 2>/dev/null || true
            log_success "  Stopped & masked: ${svc}"
        done
    fi

    # --- Step 2: Kill remaining processes ---
    if (( ${#DETECTED_AGENTS_PROCESSES[@]} > 0 )); then
        print_step 2 "Killing remaining agent processes..."
        for proc in ${DETECTED_AGENTS_PROCESSES[@]+"${DETECTED_AGENTS_PROCESSES[@]}"}; do
            if pgrep -x "${proc}" &>/dev/null || pgrep -f "${proc}" &>/dev/null; then
                log_info "  Killing: ${proc}"
                pkill -9 -x "${proc}" 2>/dev/null || true
                pkill -9 -f "${proc}" 2>/dev/null || true
                # Wait briefly for processes to die
                sleep 1
                if pgrep -x "${proc}" &>/dev/null; then
                    log_warn "  Process '${proc}' still alive after SIGKILL — may need reboot."
                else
                    log_success "  Killed: ${proc}"
                fi
            fi
        done
    fi

    # --- Step 3: Remove packages ---
    if (( ${#DETECTED_AGENTS_PACKAGES[@]} > 0 )); then
        print_step 3 "Removing packages..."
        for pkg in ${DETECTED_AGENTS_PACKAGES[@]+"${DETECTED_AGENTS_PACKAGES[@]}"}; do
            log_info "  Removing package: ${pkg}"
            case "${PKG_MGR}" in
                apt)
                    DEBIAN_FRONTEND=noninteractive apt-get purge -y "${pkg}" 2>/dev/null || true
                    ;;
                dnf)
                    dnf remove -y "${pkg}" 2>/dev/null || true
                    ;;
                yum)
                    yum remove -y "${pkg}" 2>/dev/null || true
                    ;;
            esac
        done
    fi

    # --- Step 4: Remove files and directories ---
    if (( ${#DETECTED_AGENTS_PATHS[@]} > 0 )); then
        print_step 4 "Removing agent files and directories..."
        for agent_path in ${DETECTED_AGENTS_PATHS[@]+"${DETECTED_AGENTS_PATHS[@]}"}; do
            if [[ -e "${agent_path}" ]]; then
                log_info "  Removing: ${agent_path}"
                rm -rf "${agent_path}"
                log_success "  Removed: ${agent_path}"
            fi
        done
    fi

    # --- Step 5: Remove cron entries ---
    if (( ${#DETECTED_AGENTS_CRONS[@]} > 0 )); then
        print_step 5 "Removing cron entries..."
        for cron_pattern in ${DETECTED_AGENTS_CRONS[@]+"${DETECTED_AGENTS_CRONS[@]}"}; do
            # Remove from user crontab
            if crontab -l 2>/dev/null | grep -qF "${cron_pattern}"; then
                crontab -l 2>/dev/null | grep -vF "${cron_pattern}" | crontab - 2>/dev/null || true
                log_info "  Removed from user crontab: ${cron_pattern}"
            fi
            # Remove from system crontabs
            local cron_file
            for cron_file in /etc/cron.d/* /etc/cron.daily/* /etc/cron.hourly/*; do
                if [[ -f "${cron_file}" ]] && grep -qF "${cron_pattern}" "${cron_file}" 2>/dev/null; then
                    rm -f "${cron_file}"
                    log_info "  Removed cron file: ${cron_file}"
                fi
            done
        done
    fi

    # --- Step 6: Remove provider-specific repositories ---
    _remove_provider_repos

    # --- Step 7: Clean package manager cache ---
    print_step 6 "Cleaning package manager cache..."
    case "${PKG_MGR}" in
        apt)
            apt-get autoremove -y 2>/dev/null || true
            apt-get autoclean 2>/dev/null || true
            ;;
        dnf)
            dnf autoremove -y 2>/dev/null || true
            dnf clean all 2>/dev/null || true
            ;;
        yum)
            yum autoremove -y 2>/dev/null || true
            yum clean all 2>/dev/null || true
            ;;
    esac

    # --- Step 8: Reload systemd ---
    systemctl daemon-reload 2>/dev/null || true

    log_success "Cloud agent removal complete."
    return 0
}

# -----------------------------------------------------------------------------
# _remove_provider_repos:
#   Remove cloud-provider-specific APT/YUM repositories to prevent
#   agents from being reinstalled via package updates.
# -----------------------------------------------------------------------------
_remove_provider_repos() {
    print_step 5 "Removing provider package repositories..."

    # APT repositories
    if [[ -d /etc/apt/sources.list.d ]]; then
        local -a apt_patterns=(
            "*aegis*" "*alibaba*" "*aliyun*"
            "*tencent*" "*qcloud*"
            "*huawei*" "*hwcloud*"
            "*jdcloud*"
            "*baidu*" "*bce*"
            "*ucloud*"
            "*volcengine*" "*bytedance*"
            "*kingsoft*" "*ksyun*"
        )
        for pattern in ${apt_patterns[@]+"${apt_patterns[@]}"}; do
            local found_file
            for found_file in /etc/apt/sources.list.d/${pattern}; do
                if [[ -f "${found_file}" ]]; then
                    rm -f "${found_file}"
                    log_info "  Removed APT repo: ${found_file}"
                fi
            done
        done
    fi

    # YUM repositories
    if [[ -d /etc/yum.repos.d ]]; then
        local -a yum_patterns=(
            "*aegis*" "*alibaba*" "*aliyun*"
            "*tencent*" "*qcloud*"
            "*huawei*" "*hwcloud*"
            "*jdcloud*"
            "*baidu*" "*bce*"
            "*ucloud*"
            "*volcengine*" "*bytedance*"
            "*kingsoft*" "*ksyun*"
        )
        for pattern in ${yum_patterns[@]+"${yum_patterns[@]}"}; do
            local found_file
            for found_file in /etc/yum.repos.d/${pattern}; do
                if [[ -f "${found_file}" ]]; then
                    rm -f "${found_file}"
                    log_info "  Removed YUM repo: ${found_file}"
                fi
            done
        done
    fi

    # GPG keys associated with cloud providers
    if [[ -d /etc/apt/trusted.gpg.d ]]; then
        for key_file in /etc/apt/trusted.gpg.d/*alibaba* /etc/apt/trusted.gpg.d/*tencent* \
                        /etc/apt/trusted.gpg.d/*huawei*; do
            if [[ -f "${key_file}" ]]; then
                rm -f "${key_file}"
                log_info "  Removed GPG key: ${key_file}"
            fi
        done
    fi
}

# =============================================================================
# Section 4 : DD Reinstall Offering
# =============================================================================

# -----------------------------------------------------------------------------
# offer_dd_reinstall:
#   Present the user with a menu to choose cleanup level:
#     1. Light clean  — remove agents only (no OS reinstall)
#     2. Full DD reinstall — wipe and reinstall OS via bin456789/reinstall
#     3. Skip — do nothing
#
#   The DD reinstall uses the cnb.cool mirror for faster downloads in China.
#
#   Returns: 0 on success, 1 if skipped
# -----------------------------------------------------------------------------
offer_dd_reinstall() {
    print_section "Cloud Agent Cleanup Options"
    echo ""
    echo -e "  ${COLOR_DIM}Your server has pre-installed cloud provider agents.${COLOR_RESET}"
    echo -e "  ${COLOR_DIM}These may monitor your traffic, consume resources, or interfere with deployment.${COLOR_RESET}"
    echo ""

    local options=(
        "Light Clean — Remove detected agents only (safe, no reboot)"
        "Full DD Reinstall — Wipe & reinstall clean OS (bin456789/reinstall, requires reboot)"
        "Skip — Keep current system as-is"
    )
    show_menu "Choose cleanup level" options

    case "${MENU_RESULT}" in
        1)
            _do_light_clean
            return 0
            ;;
        2)
            _do_dd_reinstall
            return 0
            ;;
        3)
            log_info "Skipping cleanup. Proceeding with current system."
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# _do_light_clean:
#   Execute the light cleanup path: remove agents, verify, continue.
# -----------------------------------------------------------------------------
_do_light_clean() {
    print_section "Light Clean Mode"

    if ! confirm_action "Remove all detected cloud agents? Services will be stopped and masked." "y"; then
        log_info "Cleanup cancelled."
        return 1
    fi

    remove_cloud_agents

    # Re-scan to verify
    log_info "Verifying cleanup..."
    if detect_preinstalled_agents 2>/dev/null; then
        log_warn "Some agents may still be present. A reboot may help complete removal."
        log_warn "You can re-run this script after reboot to verify."
    else
        log_success "All detected agents have been removed."
    fi
}

# -----------------------------------------------------------------------------
# _do_dd_reinstall:
#   Execute the full DD reinstall path using bin456789/reinstall.
#   - Downloads the reinstall script from cnb.cool mirror (primary) or
#     GitHub (fallback).
#   - Presents OS selection menu.
#   - Confirms with user before executing (irreversible).
#   - Triggers reboot.
# -----------------------------------------------------------------------------
_do_dd_reinstall() {
    print_section "Full DD Reinstall"

    echo ""
    log_warn "============================================================"
    log_warn "  WARNING: THIS WILL COMPLETELY WIPE THE CURRENT SYSTEM"
    log_warn "  All data, configurations, and installed software will be lost."
    log_warn "  The server will reboot into a fresh OS installation."
    log_warn "============================================================"
    echo ""

    if ! confirm_action "Are you ABSOLUTELY sure you want to DD reinstall?" "n"; then
        log_info "DD reinstall cancelled."
        return 1
    fi

    # Double confirmation for safety
    echo ""
    log_warn "Type 'YES I AM SURE' to confirm (case-sensitive):"
    local confirmation
    read -r confirmation
    if [[ "${confirmation}" != "YES I AM SURE" ]]; then
        log_info "Confirmation not received. DD reinstall cancelled."
        return 1
    fi

    # Ensure required tools
    install_if_missing curl curl
    install_if_missing wget wget

    # Select target OS
    local os_options=(
        "Debian 12 (Bookworm) — Recommended"
        "Debian 11 (Bullseye)"
        "Ubuntu 24.04 LTS (Noble)"
        "Ubuntu 22.04 LTS (Jammy)"
        "CentOS 9 Stream"
        "Rocky Linux 9"
        "AlmaLinux 9"
        "Custom (enter manually)"
    )
    show_menu "Select target OS for DD reinstall" os_options

    local dd_args=""
    case "${MENU_RESULT}" in
        1) dd_args="debian 12" ;;
        2) dd_args="debian 11" ;;
        3) dd_args="ubuntu 24.04" ;;
        4) dd_args="ubuntu 22.04" ;;
        5) dd_args="centos 9" ;;
        6) dd_args="rocky 9" ;;
        7) dd_args="alma 9" ;;
        8)
            read_input "Enter OS name and version (e.g., 'debian 12')" ""
            dd_args="${INPUT_RESULT}"
            ;;
    esac

    # Optional: set root password
    local root_password=""
    if confirm_action "Set a custom root password? (otherwise use script default)" "n"; then
        read_input "Enter root password" "" ".{8,}"
        root_password="${INPUT_RESULT}"
    fi

    # Download the reinstall script
    log_info "Downloading DD reinstall script..."
    local dd_script
    dd_script="$(mktemp /tmp/reinstall.XXXXXX.sh)"
    register_cleanup "${dd_script}"

    local download_success=0

    # Primary: cnb.cool mirror (faster in China)
    if curl -fsSL --connect-timeout 10 --max-time 60 \
       "${DD_REINSTALL_SCRIPT_URL}" -o "${dd_script}" 2>/dev/null; then
        download_success=1
        log_success "Downloaded from cnb.cool mirror."
    fi

    # Fallback: GitHub
    if [[ ${download_success} -eq 0 ]]; then
        log_warn "cnb.cool mirror unavailable, trying GitHub..."
        if curl -fsSL --connect-timeout 10 --max-time 60 \
           "${DD_REINSTALL_FALLBACK_URL}" -o "${dd_script}" 2>/dev/null; then
            download_success=1
            log_success "Downloaded from GitHub."
        fi
    fi

    if [[ ${download_success} -eq 0 ]]; then
        die "Failed to download DD reinstall script from any source."
    fi

    chmod +x "${dd_script}"

    # Build the command
    local -a dd_cmd=(bash "${dd_script}" ${dd_args})
    if [[ -n "${root_password}" ]]; then
        dd_cmd+=(--password "${root_password}")
    fi

    # Final confirmation
    echo ""
    log_warn "About to execute: ${dd_cmd[*]}"
    log_warn "The server will reboot after this step. You will lose SSH connection."
    echo ""

    if ! confirm_action "Last chance — proceed with DD reinstall?" "n"; then
        log_info "DD reinstall cancelled."
        return 1
    fi

    # Execute
    log_info "Starting DD reinstall..."
    ${dd_cmd[@]+"${dd_cmd[@]}"}

    # If we get here, something may have gone wrong (the script usually reboots)
    log_warn "DD reinstall script completed without rebooting."
    log_warn "You may need to reboot manually: reboot"
}

# =============================================================================
# Section 5 : System Verification
# =============================================================================

# -----------------------------------------------------------------------------
# verify_clean_system:
#   Post-cleanup verification to ensure:
#     1. No known cloud agents are running
#     2. The kernel is standard (not cloud-provider-modified)
#     3. BBR congestion control is available
#     4. No suspicious listening ports from agent processes
#
#   Returns: 0 if system is clean, 1 if issues found
# -----------------------------------------------------------------------------
verify_clean_system() {
    log_info "Verifying system cleanliness..."
    local issues=0

    # --- Check 1: No known agent processes ---
    print_step 1 "Checking for remaining agent processes..."
    local -a known_agent_processes=(
        # Tencent
        "tat_agent" "sgagent" "barad_agent" "YDService" "YDLive" "YDEdr"
        # Alibaba
        "AliYunDun" "AliYunDunMonitor" "AliYunDunUpdate" "AliSecGuard"
        "CmsGoAgent" "cloudmonitor" "AliYunAssistService" "aliyun-service"
        "AliHids" "AliNet" "logtail"
        # Huawei
        "hostguard" "hostwatch" "telescope" "uniagent"
        # JD
        "jdog-monitor" "jdog-watchdog" "jdog-kunpeng" "ifrit-agent" "jcs-agent-core"
        # Baidu
        "hosteye" "bcm-agent" "bce-agent"
        # UCloud
        "uma" "ucloud-monitor" "uhost-agent"
        # Volcengine
        "volc-monitor" "MonitorAgent" "volc-security-agent" "volc-agent"
        # AWS
        "amazon-ssm-agent" "amazon-cloudwatch-agent"
        # GCP
        "google_guest_agent" "google_osconfig_agent"
        # Azure
        "waagent"
        # Vultr
        "vultr-agent"
        # DigitalOcean
        "do-agent" "droplet-agent"
    )

    local proc_found=0
    for proc in ${known_agent_processes[@]+"${known_agent_processes[@]}"}; do
        if pgrep -x "${proc}" &>/dev/null; then
            log_warn "  Agent process still running: ${proc} (PID: $(pgrep -x "${proc}" | head -1))"
            proc_found=1
            (( issues++ )) || true
        fi
    done

    if [[ ${proc_found} -eq 0 ]]; then
        log_success "  No known agent processes detected."
    fi

    # --- Check 2: Kernel integrity ---
    print_step 2 "Checking kernel..."
    local kernel_version
    kernel_version="$(uname -r)"

    # Check for cloud-provider-patched kernels
    local kernel_ok=1
    if [[ "${kernel_version}" == *"tlinux"* ]] || [[ "${kernel_version}" == *"tencent"* ]]; then
        log_warn "  Tencent TLinux kernel detected: ${kernel_version}"
        log_warn "  Consider DD reinstall for a standard kernel."
        kernel_ok=0
        (( issues++ )) || true
    elif [[ "${kernel_version}" == *"aliyun"* ]] || [[ "${kernel_version}" == *"alinux"* ]]; then
        log_warn "  Alibaba Alinux kernel detected: ${kernel_version}"
        log_warn "  Consider DD reinstall for a standard kernel."
        kernel_ok=0
        (( issues++ )) || true
    elif [[ "${kernel_version}" == *"hwcloud"* ]] || [[ "${kernel_version}" == *"huawei"* ]]; then
        log_warn "  Huawei Cloud kernel detected: ${kernel_version}"
        kernel_ok=0
        (( issues++ )) || true
    fi

    if [[ ${kernel_ok} -eq 1 ]]; then
        log_success "  Standard kernel: ${kernel_version}"
    fi

    # --- Check 3: BBR availability ---
    print_step 3 "Checking BBR congestion control..."
    local bbr_available=0

    # Check if BBR module is loaded or available
    if lsmod 2>/dev/null | grep -q "tcp_bbr"; then
        bbr_available=1
    elif modprobe tcp_bbr 2>/dev/null; then
        bbr_available=1
    fi

    # Check current congestion control
    local current_cc
    current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'unknown')"

    if [[ ${bbr_available} -eq 1 ]]; then
        if [[ "${current_cc}" == "bbr" ]]; then
            log_success "  BBR is active: ${current_cc}"
        else
            log_warn "  BBR is available but not active (current: ${current_cc})"
            log_info "  Will be enabled during deployment via sysctl configuration."
        fi
    else
        log_warn "  BBR is NOT available on this kernel."
        log_warn "  Kernel version: ${kernel_version}"
        log_warn "  BBR requires kernel >= 4.9. Consider upgrading the kernel or DD reinstall."
        (( issues++ )) || true
    fi

    # --- Check 4: Available congestion control algorithms ---
    local available_cc
    available_cc="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo 'unknown')"
    log_info "  Available algorithms: ${available_cc}"

    # --- Check 5: Suspicious listening ports ---
    print_step 4 "Checking for suspicious listening ports..."
    local suspicious_ports=0

    if check_command ss; then
        # Look for processes listening on non-standard ports that match known agent names
        local -a suspicious_listeners
        while IFS= read -r line; do
            local listen_proc
            listen_proc="$(echo "${line}" | awk '{print $NF}')"
            for proc in ${known_agent_processes[@]+"${known_agent_processes[@]}"}; do
                if [[ "${listen_proc}" == *"${proc}"* ]]; then
                    log_warn "  Suspicious listener: ${line}"
                    suspicious_ports=1
                    (( issues++ )) || true
                    break
                fi
            done
        done < <(ss -tlnp 2>/dev/null | tail -n +2)
    fi

    if [[ ${suspicious_ports} -eq 0 ]]; then
        log_success "  No suspicious agent listeners found."
    fi

    # --- Check 6: cloud-init status ---
    print_step 5 "Checking cloud-init status..."
    if systemctl is-active cloud-init &>/dev/null 2>&1; then
        log_warn "  cloud-init is still active. It may re-install agents on reboot."
        log_info "  Consider masking: systemctl mask cloud-init cloud-config cloud-final"
        (( issues++ )) || true
    else
        log_success "  cloud-init is not active."
    fi

    # --- Summary ---
    echo ""
    if (( issues == 0 )); then
        log_success "System verification passed: no issues found."
        return 0
    else
        log_warn "System verification found ${issues} issue(s)."
        log_warn "The system may still work for deployment, but consider addressing the above."
        return 1
    fi
}

# =============================================================================
# Section 6 : Pre-Deploy Check (Main Entry Point)
# =============================================================================

# -----------------------------------------------------------------------------
# pre_deploy_check:
#   Main orchestration function to be called at the start of deployment.
#   Runs the full detection-and-cleanup pipeline:
#     1. Detect cloud provider
#     2. Scan for pre-installed agents
#     3. If agents found, offer cleanup/DD reinstall menu
#     4. Verify system cleanliness
#
#   Designed to be called from install.sh before deploying any components.
#
#   Returns: 0 (always — issues are warned, not fatal)
# -----------------------------------------------------------------------------
pre_deploy_check() {
    print_section "Pre-Deployment System Check"
    echo ""
    log_info "Checking for cloud provider agents and system readiness..."
    echo ""

    # Ensure we have system detection data
    if [[ -z "${OS_ID}" ]]; then
        detect_system
    fi

    require_root

    # Step 1: Detect cloud provider
    detect_cloud_provider || true

    echo ""
    if [[ "${DETECTED_PROVIDER}" != "unknown" ]]; then
        print_kv "Cloud Provider" "${DETECTED_PROVIDER}"
    else
        print_kv "Cloud Provider" "Unknown / Bare Metal"
    fi
    echo ""

    # Step 2: Scan for agents
    local agents_found=0
    if detect_preinstalled_agents; then
        agents_found=1
    fi

    # Step 3: Offer cleanup if agents found
    if [[ ${agents_found} -eq 1 ]]; then
        echo ""
        offer_dd_reinstall || true
        echo ""
    else
        log_success "No cloud agents detected. System is ready for deployment."
    fi

    # Step 4: Verify system
    echo ""
    verify_clean_system || true

    echo ""
    log_info "Pre-deployment check complete. Proceeding with deployment..."
    echo ""

    return 0
}

# =============================================================================
# End of dd-reinstall.sh
# =============================================================================
log_info "dd-reinstall.sh loaded successfully."
