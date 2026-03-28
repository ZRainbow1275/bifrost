#!/usr/bin/env bash
###############################################################################
# Bifrost - Diagnostics Module
#
# Comprehensive diagnostic suite for troubleshooting the Bifrost.
# Checks system health, service status, network connectivity, DNS leaks,
# speed tests, and GFW detection patterns.
#
# Functions:
#   run_full_diagnostic()       - System + services + network + DNS + speed
#   test_gfw_detection()        - Timing analysis + packet loss for GFW signals
#   generate_diagnostic_report() - Export full report as JSON
#
# Usage:
#   bash scripts/diagnostics.sh              # Interactive menu
#   bash scripts/diagnostics.sh full         # Full diagnostic
#   bash scripts/diagnostics.sh gfw          # GFW detection test
#   bash scripts/diagnostics.sh report       # Generate JSON report
#
# Dependencies: scripts/common.sh, curl, jq (optional)
###############################################################################

set -euo pipefail

# Guard against double-sourcing (readonly variables would conflict)
if [[ -n "${_DIAGNOSTICS_SH_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
readonly _DIAGNOSTICS_SH_LOADED=1

# Resolve the directory this script resides in
_DIAG_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DIAG_PROJECT_DIR="$(cd "${_DIAG_SCRIPT_DIR}/.." && pwd)"

# Source common utilities
if [[ -f "${_DIAG_SCRIPT_DIR}/common.sh" ]]; then
    # shellcheck source=scripts/common.sh
    source "${_DIAG_SCRIPT_DIR}/common.sh"
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
    log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
    log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
    log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
    log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
    die() { log_error "$@"; exit 1; }
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

# Color fallbacks
: "${BLUE:=\033[0;34m}"
: "${RED:=\033[0;31m}"
: "${GREEN:=\033[0;32m}"
: "${YELLOW:=\033[1;33m}"
: "${CYAN:=${COLOR_CYAN:-\033[0;36m}}"
: "${NC:=${COLOR_RESET:-\033[0m}}"
: "${BOLD:=${COLOR_BOLD:-\033[1m}}"

# =============================================================================
# Constants
# =============================================================================
: "${BIFROST_REPORT_DIR:=/var/log/bifrost}"
REPORT_DIR="${BIFROST_REPORT_DIR}"
PROXY_SOCKS="socks5://127.0.0.1:10808"
PROXY_HTTP="http://127.0.0.1:10809"

# AI API endpoints to test
declare -A TEST_ENDPOINTS=(
    ["Anthropic"]="https://api.anthropic.com"
    ["OpenAI"]="https://api.openai.com"
    ["Google_Gemini"]="https://generativelanguage.googleapis.com"
    ["DeepSeek"]="https://api.deepseek.com"
    ["GitHub"]="https://api.github.com"
    ["HuggingFace"]="https://huggingface.co"
)

# DNS servers to test for leak detection
declare -A DNS_SERVERS=(
    ["Cloudflare"]="1.1.1.1"
    ["Google"]="8.8.8.8"
    ["Quad9"]="9.9.9.9"
    ["AliDNS"]="223.5.5.5"
    ["TencentDNS"]="119.29.29.29"
)

# =============================================================================
# Diagnostic result collectors
# =============================================================================
# We collect results as associative arrays for JSON export
declare -A DIAG_SYSTEM=()
declare -A DIAG_SERVICES=()
declare -A DIAG_NETWORK=()
declare -A DIAG_DNS=()
declare -A DIAG_SPEED=()
declare -A DIAG_GFW=()
DIAG_TIMESTAMP=""
DIAG_OVERALL="healthy"

###############################################################################
# _resolve_report_dir()
#
# Resolve a writable report directory. Falls back to /tmp/bifrost when the
# default report directory is unavailable in non-root/local verification flows.
###############################################################################
_resolve_report_dir() {
    if mkdir -p "${REPORT_DIR}" 2>/dev/null; then
        printf '%s' "${REPORT_DIR}"
        return 0
    fi

    local fallback_dir="${TMPDIR:-/tmp}/bifrost"
    mkdir -p "${fallback_dir}"
    printf '%s' "${fallback_dir}"
}

###############################################################################
# _record_result()
#
# Record a diagnostic result to a category.
###############################################################################
_record_result() {
    local category="${1:?}"
    local key="${2:?}"
    local value="${3:-}"

    case "${category}" in
        system)   DIAG_SYSTEM["${key}"]="${value}" ;;
        services) DIAG_SERVICES["${key}"]="${value}" ;;
        network)  DIAG_NETWORK["${key}"]="${value}" ;;
        dns)      DIAG_DNS["${key}"]="${value}" ;;
        speed)    DIAG_SPEED["${key}"]="${value}" ;;
        gfw)      DIAG_GFW["${key}"]="${value}" ;;
    esac
}

###############################################################################
# _json_escape()
#
# Escape a string value so it can be embedded safely in JSON output.
###############################################################################
_json_escape() {
    local value="${1-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "${value}"
}

###############################################################################
# _append_assoc_json_section()
#
# Render an associative-array-backed diagnostics section as a JSON object.
###############################################################################
_append_assoc_json_section() {
    local section_name="${1:?}"
    local assoc_name="${2:?}"
    local -n assoc_ref="${assoc_name}"
    local json_fragment="\"$(_json_escape "${section_name}")\":{"
    local first=true

    for key in "${!assoc_ref[@]}"; do
        if [[ "${first}" == "true" ]]; then
            first=false
        else
            json_fragment+=","
        fi
        json_fragment+="\"$(_json_escape "${key}")\":\"$(_json_escape "${assoc_ref[${key}]}")\""
    done

    json_fragment+="}"
    printf '%s' "${json_fragment}"
}

###############################################################################
# _write_report_json()
#
# Persist a JSON report and fail if the rendered payload cannot be validated
# or written successfully.
###############################################################################
_write_report_json() {
    local json_payload="${1:?}"
    local report_file="${2:?}"

    if command_exists jq; then
        if ! printf '%s\n' "${json_payload}" | jq '.' > "${report_file}" 2>/dev/null; then
            log_error "Failed to validate rendered diagnostic JSON."
            return 1
        fi
    else
        if ! printf '%s\n' "${json_payload}" > "${report_file}"; then
            log_error "Failed to write diagnostic report to ${report_file}."
            return 1
        fi
    fi

    if [[ ! -s "${report_file}" ]]; then
        log_error "Diagnostic report was not written correctly: ${report_file}"
        return 1
    fi
}

###############################################################################
# _reset_diagnostic_results()
#
# Clear previous run state so reports never mix stale observations with new
# evidence from the current execution.
###############################################################################
_reset_diagnostic_results() {
    DIAG_SYSTEM=()
    DIAG_SERVICES=()
    DIAG_NETWORK=()
    DIAG_DNS=()
    DIAG_SPEED=()
    DIAG_GFW=()
}

###############################################################################
# _diag_system()
#
# Collect system information: OS, CPU, memory, disk, uptime, kernel.
###############################################################################
_diag_system() {
    log_step "System Information"

    # OS
    local os_name="unknown"
    if [[ -f /etc/os-release ]]; then
        os_name="$(. /etc/os-release && echo "${PRETTY_NAME:-${ID} ${VERSION_ID}}")"
    fi
    _record_result system "os" "${os_name}"
    echo -e "  OS:           ${os_name}"

    # Kernel
    local kernel
    kernel="$(uname -r)"
    _record_result system "kernel" "${kernel}"
    echo -e "  Kernel:       ${kernel}"

    # Architecture
    local arch
    arch="$(uname -m)"
    _record_result system "arch" "${arch}"
    echo -e "  Architecture: ${arch}"

    # Uptime
    local uptime_str="unknown"
    if command_exists uptime; then
        uptime_str="$(uptime -p 2>/dev/null || uptime 2>/dev/null | awk -F',' '{print $1}' | awk -F'up' '{print $2}' | xargs || echo 'unknown')"
    fi
    _record_result system "uptime" "${uptime_str}"
    echo -e "  Uptime:       ${uptime_str}"

    # CPU
    local cpu_cores="1"
    if command_exists nproc; then
        cpu_cores="$(nproc)"
    fi
    local cpu_model
    cpu_model="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)" || cpu_model="unknown"
    local load_avg
    load_avg="$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')" || load_avg="unknown"
    _record_result system "cpu_cores" "${cpu_cores}"
    _record_result system "cpu_model" "${cpu_model}"
    _record_result system "load_avg" "${load_avg}"
    echo -e "  CPU:          ${cpu_cores} cores (${cpu_model})"
    echo -e "  Load Avg:     ${load_avg}"

    # Memory
    if command_exists free; then
        local mem_info
        mem_info="$(free -m 2>/dev/null | grep '^Mem:' || true)"
        local mem_total mem_used mem_avail
        mem_total="$(echo "${mem_info}" | awk '{print $2}')"
        mem_used="$(echo "${mem_info}" | awk '{print $3}')"
        mem_avail="$(echo "${mem_info}" | awk '{print $7}')"
        local mem_pct=0
        if (( mem_total > 0 )); then
            mem_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))
        fi
        _record_result system "mem_total_mb" "${mem_total}"
        _record_result system "mem_used_mb" "${mem_used}"
        _record_result system "mem_avail_mb" "${mem_avail}"
        _record_result system "mem_usage_pct" "${mem_pct}"

        local mem_color="${GREEN}"
        if (( mem_pct > 90 )); then
            mem_color="${RED}"
            DIAG_OVERALL="degraded"
        elif (( mem_pct > 75 )); then
            mem_color="${YELLOW}"
        fi
        echo -e "  Memory:       ${mem_used}MB / ${mem_total}MB (${mem_color}${mem_pct}%${NC}) avail=${mem_avail}MB"
    fi

    # Disk
    local disk_info=""
    if command_exists df; then
        disk_info="$(df -hP / 2>/dev/null | tail -1 || true)"
    fi
    if [[ -n "${disk_info}" ]]; then
        local disk_size disk_used disk_avail disk_pct
        disk_size="$(echo "${disk_info}" | awk '{print $(NF-4)}')"
        disk_used="$(echo "${disk_info}" | awk '{print $(NF-3)}')"
        disk_avail="$(echo "${disk_info}" | awk '{print $(NF-2)}')"
        disk_pct="$(echo "${disk_info}" | awk '{print $(NF-1)}' | tr -d '%')"
        _record_result system "disk_size" "${disk_size}"
        _record_result system "disk_used" "${disk_used}"
        _record_result system "disk_avail" "${disk_avail}"
        _record_result system "disk_usage_pct" "${disk_pct}"

        local disk_color="${GREEN}"
        if [[ "${disk_pct}" =~ ^[0-9]+$ ]]; then
            if (( disk_pct > 90 )); then
                disk_color="${RED}"
                DIAG_OVERALL="degraded"
            elif (( disk_pct > 75 )); then
                disk_color="${YELLOW}"
            fi
        else
            disk_color="${YELLOW}"
        fi
        echo -e "  Disk /:       ${disk_used} / ${disk_size} (${disk_color}${disk_pct}%${NC}) avail=${disk_avail}"
    fi

    # Virtualization
    local virt_type="unknown"
    if command_exists systemd-detect-virt; then
        virt_type="$(systemd-detect-virt 2>/dev/null || echo 'none')"
    fi
    _record_result system "virtualization" "${virt_type}"
    echo -e "  Virt:         ${virt_type}"

    # Public IP
    local pub_ip="unknown"
    if command_exists curl; then
        pub_ip="$(curl -4 -s --connect-timeout 5 --max-time 8 'https://ifconfig.me' 2>/dev/null | tr -d '[:space:]')" || pub_ip="unknown"
    fi
    _record_result system "public_ip" "${pub_ip}"
    echo -e "  Public IP:    ${pub_ip}"
}

###############################################################################
# _diag_services()
#
# Check status of all Bifrost services.
###############################################################################
_diag_services() {
    log_step "Service Status"

    local services=("xray" "caddy" "mihomo" "x-ui" "netdata" "fail2ban")

    for svc in ${services[@]+"${services[@]}"}; do
        local status="not_installed"
        local details=""

        if command_exists systemctl; then
            if systemctl is-active --quiet "${svc}" 2>/dev/null; then
                status="running"
                # Get PID and memory usage
                local pid
                pid="$(systemctl show "${svc}" --property=MainPID --value 2>/dev/null)" || pid=""
                if [[ -n "${pid}" && "${pid}" != "0" ]]; then
                    local mem_kb
                    mem_kb="$(ps -p "${pid}" -o rss= 2>/dev/null | tr -d ' ')" || mem_kb="0"
                    local mem_mb=$(( mem_kb / 1024 ))
                    details="pid=${pid}, mem=${mem_mb}MB"
                fi
            elif systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
                status="stopped"
                DIAG_OVERALL="degraded"
            fi
        fi

        _record_result services "${svc}" "${status}"

        local color="${NC}"
        case "${status}" in
            running) color="${GREEN}" ;;
            stopped) color="${RED}" ;;
            not_installed) color="${YELLOW}" ;;
        esac

        printf "  %-15s ${color}%-15s${NC} %s\n" "${svc}" "${status}" "${details}"
    done

    # Docker containers
    if command_exists docker && docker info &>/dev/null; then
        echo ""
        echo "  Docker Containers:"
        local found_container=false
        for name in "new-api" "newapi" "one-api" "oneapi"; do
            if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qw "${name}"; then
                local c_status
                c_status="$(docker inspect --format '{{.State.Status}}' "${name}" 2>/dev/null)" || c_status="unknown"
                local c_uptime
                c_uptime="$(docker inspect --format '{{.State.StartedAt}}' "${name}" 2>/dev/null | cut -d'T' -f1)" || c_uptime=""
                _record_result services "docker_${name}" "${c_status}"

                local c_color="${NC}"
                if [[ "${c_status}" == "running" ]]; then
                    c_color="${GREEN}"
                else
                    c_color="${RED}"
                    DIAG_OVERALL="degraded"
                fi

                printf "    %-15s ${c_color}%-15s${NC} started=%s\n" "${name}" "${c_status}" "${c_uptime}"
                found_container=true
            fi
        done
        if [[ "${found_container}" == "false" ]]; then
            echo "    (no AI Gateway containers found)"
        fi
    fi
}

###############################################################################
# _diag_network()
#
# Test network connectivity:
#   - Direct internet access
#   - Proxy tunnel (SOCKS5 and HTTP)
#   - Each AI API endpoint (direct and via proxy)
###############################################################################
_diag_network() {
    log_step "Network Connectivity"

    # Basic internet
    echo -n "  Internet (direct):    "
    if ping -c 1 -W 5 8.8.8.8 &>/dev/null; then
        echo -e "${GREEN}OK${NC}"
        _record_result network "internet_direct" "ok"
    elif curl -s --connect-timeout 5 --max-time 10 -o /dev/null "https://www.baidu.com" 2>/dev/null; then
        echo -e "${GREEN}OK (via HTTP)${NC}"
        _record_result network "internet_direct" "ok_http"
    else
        echo -e "${RED}FAIL${NC}"
        _record_result network "internet_direct" "fail"
        DIAG_OVERALL="critical"
    fi

    # SOCKS5 proxy
    echo -n "  SOCKS5 proxy (10808): "
    local socks_code
    socks_code="$(curl -s -o /dev/null -w '%{http_code}' --proxy "${PROXY_SOCKS}" --connect-timeout 10 --max-time 20 "https://api.anthropic.com" 2>/dev/null)" || socks_code="000"
    if [[ "${socks_code}" != "000" ]]; then
        echo -e "${GREEN}OK (HTTP ${socks_code})${NC}"
        _record_result network "socks5_proxy" "ok_${socks_code}"
    else
        echo -e "${RED}FAIL${NC}"
        _record_result network "socks5_proxy" "fail"
        DIAG_OVERALL="degraded"
    fi

    # HTTP proxy
    echo -n "  HTTP proxy (10809):   "
    local http_code
    http_code="$(curl -s -o /dev/null -w '%{http_code}' --proxy "${PROXY_HTTP}" --connect-timeout 10 --max-time 20 "https://api.anthropic.com" 2>/dev/null)" || http_code="000"
    if [[ "${http_code}" != "000" ]]; then
        echo -e "${GREEN}OK (HTTP ${http_code})${NC}"
        _record_result network "http_proxy" "ok_${http_code}"
    else
        echo -e "${RED}FAIL${NC}"
        _record_result network "http_proxy" "fail"
    fi

    # AI API endpoints
    echo ""
    echo "  AI API Endpoints (via proxy):"
    for name in "${!TEST_ENDPOINTS[@]}"; do
        local url="${TEST_ENDPOINTS[${name}]}"
        printf "    %-20s " "${name}:"

        local start_ns end_ns endpoint_code endpoint_ms
        start_ns="$(date +%s%N 2>/dev/null)" || start_ns="$(date +%s)000000000"
        endpoint_code="$(curl -s -o /dev/null -w '%{http_code}' --proxy "${PROXY_SOCKS}" --connect-timeout 15 --max-time 30 "${url}" 2>/dev/null)" || endpoint_code="000"
        end_ns="$(date +%s%N 2>/dev/null)" || end_ns="$(date +%s)000000000"
        endpoint_ms=$(( (end_ns - start_ns) / 1000000 ))

        if [[ "${endpoint_code}" != "000" ]]; then
            local ep_color="${GREEN}"
            if (( endpoint_ms > 5000 )); then
                ep_color="${YELLOW}"
            fi
            echo -e "${ep_color}HTTP ${endpoint_code}${NC} (${endpoint_ms}ms)"
            _record_result network "endpoint_${name}" "ok_${endpoint_code}_${endpoint_ms}ms"
        else
            echo -e "${RED}UNREACHABLE${NC}"
            _record_result network "endpoint_${name}" "fail"
        fi
    done
}

###############################################################################
# _diag_dns()
#
# DNS leak test: resolve external hostnames and check which DNS servers
# the system is using. Detects if DNS queries are leaking outside the tunnel.
###############################################################################
_diag_dns() {
    log_step "DNS Leak Test"

    # Test 1: Check system DNS resolvers
    echo "  System DNS resolvers:"
    if [[ -f /etc/resolv.conf ]]; then
        local resolvers
        resolvers="$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}')"
        if [[ -n "${resolvers}" ]]; then
            echo "${resolvers}" | while IFS= read -r ns; do
                echo "    - ${ns}"
            done
            _record_result dns "system_resolvers" "$(echo "${resolvers}" | tr '\n' ',')"
        else
            echo "    (none found)"
            _record_result dns "system_resolvers" "none"
        fi
    fi

    # Test 2: DNS resolution timing for AI domains
    echo ""
    echo "  DNS resolution test:"
    local test_domains=("api.anthropic.com" "api.openai.com" "api.github.com" "generativelanguage.googleapis.com")

    for domain in ${test_domains[@]+"${test_domains[@]}"}; do
        printf "    %-45s " "${domain}:"

        if command_exists dig; then
            local start_ns end_ns
            start_ns="$(date +%s%N 2>/dev/null)" || start_ns="$(date +%s)000000000"
            local result
            result="$(dig +short "${domain}" 2>/dev/null | head -1)" || result=""
            end_ns="$(date +%s%N 2>/dev/null)" || end_ns="$(date +%s)000000000"
            local dns_ms=$(( (end_ns - start_ns) / 1000000 ))

            if [[ -n "${result}" ]]; then
                echo -e "${GREEN}${result}${NC} (${dns_ms}ms)"
                _record_result dns "resolve_${domain}" "${result}_${dns_ms}ms"
            else
                echo -e "${YELLOW}NXDOMAIN / empty${NC} (${dns_ms}ms)"
                _record_result dns "resolve_${domain}" "empty_${dns_ms}ms"
            fi
        elif command_exists nslookup; then
            if nslookup "${domain}" &>/dev/null; then
                echo -e "${GREEN}OK${NC}"
                _record_result dns "resolve_${domain}" "ok"
            else
                echo -e "${RED}FAIL${NC}"
                _record_result dns "resolve_${domain}" "fail"
            fi
        else
            echo -e "${YELLOW}SKIP (no dig/nslookup)${NC}"
        fi
    done

    # Test 3: DNS leak detection via external service
    echo ""
    echo "  DNS leak check (whoami.akamai.net):"
    if command_exists dig; then
        local leak_result
        leak_result="$(dig +short whoami.akamai.net 2>/dev/null)" || leak_result=""
        if [[ -n "${leak_result}" ]]; then
            echo "    Your DNS resolver IP: ${leak_result}"
            _record_result dns "leak_resolver_ip" "${leak_result}"
        else
            echo "    Could not determine DNS resolver IP"
            _record_result dns "leak_resolver_ip" "unknown"
        fi
    fi

    # Test 4: Check DNS through proxy vs direct
    echo ""
    echo "  DNS via proxy vs direct:"
    local direct_ip proxy_ip
    direct_ip="$(dig +short api.anthropic.com @8.8.8.8 2>/dev/null | head -1)" || direct_ip="unknown"
    printf "    Direct (8.8.8.8):   %s\n" "${direct_ip}"
    _record_result dns "direct_resolve" "${direct_ip}"

    if curl -s --proxy "${PROXY_SOCKS}" --connect-timeout 10 --max-time 15 "https://api.anthropic.com" -o /dev/null 2>/dev/null; then
        echo -e "    Proxy (SOCKS5):     ${GREEN}resolves (tunnel active)${NC}"
        _record_result dns "proxy_resolve" "ok"
    else
        echo -e "    Proxy (SOCKS5):     ${RED}fails${NC}"
        _record_result dns "proxy_resolve" "fail"
    fi
}

###############################################################################
# _diag_speed()
#
# Basic speed test: measure download throughput through the proxy tunnel.
###############################################################################
_diag_speed() {
    log_step "Speed Test (via proxy)"

    # Small file download to measure latency and initial throughput
    local test_urls=(
        "https://speed.cloudflare.com/__down?bytes=1000000"
        "https://proof.ovh.net/files/1Mb.dat"
    )

    for url in ${test_urls[@]+"${test_urls[@]}"}; do
        local url_short
        url_short="$(echo "${url}" | awk -F/ '{print $3}')"
        printf "  %-35s " "${url_short}:"

        local start_ns end_ns
        start_ns="$(date +%s%N 2>/dev/null)" || start_ns="$(date +%s)000000000"

        local bytes_downloaded
        bytes_downloaded="$(curl -s --proxy "${PROXY_SOCKS}" --connect-timeout 15 --max-time 30 \
            -w '%{size_download}' -o /dev/null "${url}" 2>/dev/null)" || bytes_downloaded="0"

        end_ns="$(date +%s%N 2>/dev/null)" || end_ns="$(date +%s)000000000"
        local elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))

        if [[ "${bytes_downloaded}" -gt 0 && "${elapsed_ms}" -gt 0 ]]; then
            local speed_kbps=$(( bytes_downloaded * 1000 / elapsed_ms / 1024 ))
            local speed_mbps
            speed_mbps="$(awk "BEGIN {printf \"%.2f\", ${bytes_downloaded} * 8 / ${elapsed_ms} / 1000}" 2>/dev/null)" || speed_mbps="?"

            local color="${GREEN}"
            if (( speed_kbps < 100 )); then
                color="${RED}"
            elif (( speed_kbps < 500 )); then
                color="${YELLOW}"
            fi

            echo -e "${color}${speed_mbps} Mbps${NC} (${bytes_downloaded} bytes in ${elapsed_ms}ms)"
            _record_result speed "${url_short}" "${speed_mbps}Mbps_${elapsed_ms}ms"
        else
            echo -e "${RED}FAIL${NC} (no data received)"
            _record_result speed "${url_short}" "fail"
        fi
    done

    # Latency measurement to key endpoints
    echo ""
    echo "  Latency to AI endpoints (via proxy):"
    for name in "Anthropic" "OpenAI" "GitHub"; do
        local url="${TEST_ENDPOINTS[${name}]:-}"
        [[ -z "${url}" ]] && continue

        printf "    %-15s " "${name}:"

        local ttfb
        ttfb="$(curl -s -o /dev/null -w '%{time_starttransfer}' --proxy "${PROXY_SOCKS}" --connect-timeout 15 --max-time 30 "${url}" 2>/dev/null)" || ttfb=""

        if [[ -n "${ttfb}" && "${ttfb}" != "0.000000" ]]; then
            local ttfb_ms
            ttfb_ms="$(awk "BEGIN {printf \"%.0f\", ${ttfb} * 1000}" 2>/dev/null)" || ttfb_ms="?"

            local color="${GREEN}"
            if [[ "${ttfb_ms}" =~ ^[0-9]+$ ]]; then
                if (( ttfb_ms > 5000 )); then
                    color="${RED}"
                elif (( ttfb_ms > 2000 )); then
                    color="${YELLOW}"
                fi
            fi

            echo -e "${color}${ttfb_ms}ms${NC} TTFB"
            _record_result speed "latency_${name}" "${ttfb_ms}ms"
        else
            echo -e "${RED}FAIL${NC}"
            _record_result speed "latency_${name}" "fail"
        fi
    done
}

###############################################################################
# test_gfw_detection()
#
# Test for signs of GFW (Great Firewall) interference:
#
#   1. TCP RST analysis: repeated connections to blocked endpoints to detect
#      TCP reset injection patterns.
#   2. Connection timing anomalies: measure variance in connection times to
#      detect throttling or DPI-based interference.
#   3. Packet loss measurement: compare loss rates to Chinese vs foreign hosts.
#   4. TLS fingerprint test: check if the Reality TLS handshake is being
#      fingerprinted or blocked.
###############################################################################
test_gfw_detection() {
    log_step "GFW Detection Analysis"
    echo ""

    local issues_found=0

    # Test 1: TCP RST detection (rapid connection attempts to known-blocked endpoints)
    echo -e "${BOLD}  [1/4] TCP RST Injection Detection${NC}"
    echo "  Testing rapid connections to known endpoints..."

    local blocked_endpoints=("google.com:443" "youtube.com:443" "twitter.com:443")
    local rst_count=0
    local total_attempts=0

    for endpoint in ${blocked_endpoints[@]+"${blocked_endpoints[@]}"}; do
        local host port
        host="${endpoint%:*}"
        port="${endpoint#*:}"

        local successes=0
        local failures=0

        for i in $(seq 1 5); do
            total_attempts=$(( total_attempts + 1 ))
            if (echo >/dev/tcp/"${host}"/"${port}") &>/dev/null; then
                successes=$(( successes + 1 ))
            else
                failures=$(( failures + 1 ))
            fi
        done

        if (( failures > 3 )); then
            echo -e "    ${host}:${port} - ${RED}${failures}/5 failed (likely blocked)${NC}"
            rst_count=$(( rst_count + failures ))
        elif (( failures > 0 )); then
            echo -e "    ${host}:${port} - ${YELLOW}${failures}/5 failed (intermittent)${NC}"
            rst_count=$(( rst_count + failures ))
        else
            echo -e "    ${host}:${port} - ${GREEN}all OK (not blocked from here)${NC}"
        fi
    done

    _record_result gfw "tcp_rst_failures" "${rst_count}/${total_attempts}"
    if (( rst_count > total_attempts / 2 )); then
        echo -e "  Result: ${RED}High RST rate detected - GFW likely active${NC}"
        issues_found=$(( issues_found + 1 ))
    elif (( rst_count > 0 )); then
        echo -e "  Result: ${YELLOW}Some connection failures detected${NC}"
    else
        echo -e "  Result: ${GREEN}No RST injection detected from this location${NC}"
    fi

    # Test 2: Connection timing analysis
    echo ""
    echo -e "${BOLD}  [2/4] Connection Timing Analysis${NC}"
    echo "  Measuring connection time variance..."

    local -a timings=()
    local target_host="api.anthropic.com"
    local target_port="443"

    for i in $(seq 1 5); do
        local t
        t="$(curl -s -o /dev/null -w '%{time_connect}' --connect-timeout 10 --max-time 15 "https://${target_host}" 2>/dev/null)" || t="10"
        local t_ms
        t_ms="$(awk "BEGIN {printf \"%.0f\", ${t} * 1000}" 2>/dev/null)" || t_ms="9999"
        timings+=("${t_ms}")
        printf "    Attempt %d: %sms\n" "${i}" "${t_ms}"
    done

    # Calculate mean and standard deviation
    if (( ${#timings[@]} > 0 )); then
        local sum=0 count=${#timings[@]}
        for t in ${timings[@]+"${timings[@]}"}; do
            sum=$(( sum + t ))
        done
        local mean=$(( sum / count ))

        local variance_sum=0
        for t in ${timings[@]+"${timings[@]}"}; do
            local diff=$(( t - mean ))
            variance_sum=$(( variance_sum + diff * diff ))
        done
        local variance=$(( variance_sum / count ))
        local stddev
        stddev="$(awk "BEGIN {printf \"%.0f\", sqrt(${variance})}" 2>/dev/null)" || stddev="0"

        echo "    Mean: ${mean}ms, StdDev: ${stddev}ms"
        _record_result gfw "timing_mean_ms" "${mean}"
        _record_result gfw "timing_stddev_ms" "${stddev}"

        if [[ "${stddev}" =~ ^[0-9]+$ ]] && (( stddev > 500 )); then
            echo -e "  Result: ${RED}High variance - possible DPI/throttling${NC}"
            issues_found=$(( issues_found + 1 ))
        elif [[ "${stddev}" =~ ^[0-9]+$ ]] && (( stddev > 200 )); then
            echo -e "  Result: ${YELLOW}Moderate variance${NC}"
        else
            echo -e "  Result: ${GREEN}Connection times stable${NC}"
        fi
    fi

    # Test 3: Packet loss comparison
    echo ""
    echo -e "${BOLD}  [3/4] Packet Loss Analysis${NC}"
    echo "  Comparing loss rates..."

    local targets=("223.5.5.5:China" "1.1.1.1:Cloudflare" "8.8.8.8:Google")
    for entry in ${targets[@]+"${targets[@]}"}; do
        local ip label
        ip="${entry%:*}"
        label="${entry#*:}"

        printf "    %-12s (%-10s): " "${ip}" "${label}"

        local ping_result
        if ! ping_result="$(ping -c 10 -W 3 "${ip}" 2>&1)"; then
            :
        fi

        local loss_pct
        loss_pct="$(echo "${ping_result}" | grep -oP '[0-9]+(?=% packet loss)' | head -1 || true)"

        local avg_ms
        avg_ms="$(echo "${ping_result}" | tail -1 | awk -F'/' '{print $5}' || true)"

        if [[ -z "${loss_pct}" ]]; then
            if echo "${ping_result}" | grep -qiE 'requires administrative privileges|access denied|usage:'; then
                echo -e "${YELLOW}SKIP${NC}, avg=? (ping flags unsupported in current shell)"
                _record_result gfw "packet_loss_${label}" "skip"
                continue
            fi
            loss_pct="100"
        fi

        avg_ms="${avg_ms:-?}"

        local color="${GREEN}"
        if [[ "${loss_pct}" =~ ^[0-9]+$ ]]; then
            if (( loss_pct > 50 )); then
                color="${RED}"
            elif (( loss_pct > 10 )); then
                color="${YELLOW}"
            fi
        fi

        echo -e "${color}${loss_pct}% loss${NC}, avg=${avg_ms}ms"
        _record_result gfw "packet_loss_${label}" "${loss_pct}%"
    done

    # Test 4: TLS fingerprint / Reality check
    echo ""
    echo -e "${BOLD}  [4/4] TLS/Reality Handshake Test${NC}"

    local xray_config="/usr/local/etc/xray/config.json"
    if [[ -f "${xray_config}" ]] && command_exists jq; then
        local server_b_ip server_b_port server_b_sni
        server_b_ip="$(jq -r '.outbounds[]? | select(.tag == "proxy") | .settings.vnext[0].address // empty' "${xray_config}" 2>/dev/null)" || server_b_ip=""
        server_b_port="$(jq -r '.outbounds[]? | select(.tag == "proxy") | .settings.vnext[0].port // empty' "${xray_config}" 2>/dev/null)" || server_b_port="443"
        server_b_sni="$(jq -r '.outbounds[]? | select(.tag == "proxy") | .streamSettings.realitySettings.serverName // empty' "${xray_config}" 2>/dev/null)" || server_b_sni=""

        if [[ -n "${server_b_ip}" ]]; then
            echo "    Server B: ${server_b_ip}:${server_b_port} (SNI: ${server_b_sni})"

            # TLS handshake test
            printf "    TLS handshake: "
            if command_exists openssl; then
                local tls_output
                tls_output="$(echo | timeout 10 openssl s_client -connect "${server_b_ip}:${server_b_port}" -servername "${server_b_sni}" 2>&1)" || tls_output=""

                if echo "${tls_output}" | grep -q "CONNECTED"; then
                    local proto
                    proto="$(echo "${tls_output}" | grep -oP 'Protocol\s*:\s*\K\S+')" || proto=""
                    echo -e "${GREEN}OK${NC} (${proto:-TLS})"
                    _record_result gfw "tls_handshake" "ok_${proto}"
                else
                    echo -e "${RED}FAIL${NC} (handshake rejected or timeout)"
                    _record_result gfw "tls_handshake" "fail"
                    issues_found=$(( issues_found + 1 ))
                fi
            else
                echo -e "${YELLOW}SKIP (openssl not available)${NC}"
            fi

            # Tunnel proxy actual test
            printf "    Tunnel proxy test: "
            local tunnel_code
            tunnel_code="$(curl -s -o /dev/null -w '%{http_code}' --proxy "${PROXY_SOCKS}" --connect-timeout 15 --max-time 30 "https://api.anthropic.com" 2>/dev/null)" || tunnel_code="000"
            if [[ "${tunnel_code}" != "000" ]]; then
                echo -e "${GREEN}OK (HTTP ${tunnel_code})${NC}"
                _record_result gfw "tunnel_test" "ok_${tunnel_code}"
            else
                echo -e "${RED}FAIL${NC}"
                _record_result gfw "tunnel_test" "fail"
                issues_found=$(( issues_found + 1 ))
            fi
        else
            echo "    Server B IP not found in Xray config."
        fi
    else
        echo "    Xray config not found or jq not installed."
    fi

    # Summary
    echo ""
    echo "==========================================="
    if (( issues_found >= 3 )); then
        echo -e "  ${RED}GFW interference: HIGH PROBABILITY${NC}"
        echo "  Multiple indicators suggest active DPI/blocking."
        _record_result gfw "overall" "high_probability"
    elif (( issues_found >= 1 )); then
        echo -e "  ${YELLOW}GFW interference: POSSIBLE${NC}"
        echo "  Some indicators detected. Monitor closely."
        _record_result gfw "overall" "possible"
    else
        echo -e "  ${GREEN}GFW interference: LOW / NOT DETECTED${NC}"
        echo "  No clear signs of blocking from this server."
        _record_result gfw "overall" "not_detected"
    fi
    echo "==========================================="
}

###############################################################################
# run_full_diagnostic()
#
# Execute all diagnostic checks in sequence:
#   System -> Services -> Network -> DNS -> Speed -> GFW
###############################################################################
run_full_diagnostic() {
    DIAG_TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    DIAG_OVERALL="healthy"
    _reset_diagnostic_results

    echo ""
    echo -e "${BOLD}${BLUE}============================================${NC}"
    echo -e "${BOLD}${BLUE}  Bifrost - Full Diagnostic       ${NC}"
    echo -e "${BOLD}${BLUE}============================================${NC}"
    echo -e "  Timestamp: ${DIAG_TIMESTAMP}"
    echo ""

    _diag_system
    echo ""
    _diag_services
    echo ""
    _diag_network
    echo ""
    _diag_dns
    echo ""
    _diag_speed
    echo ""
    test_gfw_detection

    echo ""
    echo -e "${BOLD}============================================${NC}"
    echo -e "${BOLD}  Overall Status: $(
        case "${DIAG_OVERALL}" in
            healthy)  echo -e "${GREEN}HEALTHY${NC}" ;;
            degraded) echo -e "${YELLOW}DEGRADED${NC}" ;;
            critical) echo -e "${RED}CRITICAL${NC}" ;;
            *)        echo "${DIAG_OVERALL}" ;;
        esac
    )${NC}"
    echo -e "${BOLD}============================================${NC}"
}

###############################################################################
# generate_diagnostic_report()
#
# Generate a comprehensive JSON diagnostic report combining all checks.
# The report is saved to /var/log/bifrost/diagnostic-report.json.
###############################################################################
generate_diagnostic_report() {
    log_step "Generating diagnostic report..."

    # Run all diagnostics (output goes to terminal too)
    run_full_diagnostic

    local report_dir
    report_dir="$(_resolve_report_dir)"

    local report_file="${report_dir}/diagnostic-report-$(date +%Y%m%d_%H%M%S).json"
    local latest_link="${report_dir}/diagnostic-report.json"

    # Build JSON manually (works without jq)
    local json="{"
    json+="\"timestamp\":\"$(_json_escape "${DIAG_TIMESTAMP}")\","
    json+="\"overall_status\":\"$(_json_escape "${DIAG_OVERALL}")\","
    json+="\"hostname\":\"$(_json_escape "$(hostname -f 2>/dev/null || hostname)")\","
    json+="$(_append_assoc_json_section "system" DIAG_SYSTEM),"
    json+="$(_append_assoc_json_section "services" DIAG_SERVICES),"
    json+="$(_append_assoc_json_section "network" DIAG_NETWORK),"
    json+="$(_append_assoc_json_section "dns" DIAG_DNS),"
    json+="$(_append_assoc_json_section "speed" DIAG_SPEED),"
    json+="$(_append_assoc_json_section "gfw_detection" DIAG_GFW)"
    json+="}"

    if ! _write_report_json "${json}" "${report_file}"; then
        return 1
    fi

    # Restrict permissions — report may contain service details, IPs, and config info
    if ! chmod 600 "${report_file}"; then
        log_error "Failed to restrict permissions on ${report_file}"
        return 1
    fi

    # Create/update symlink to latest report
    if ! ln -sf "${report_file}" "${latest_link}"; then
        log_error "Failed to update latest diagnostic report link: ${latest_link}"
        return 1
    fi

    echo ""
    log_success "Diagnostic report saved."
    log_info "  Report: ${report_file}"
    log_info "  Latest: ${latest_link}"
    log_info "  View:   cat ${latest_link} | jq ."
    if [[ "${report_dir}" != "${REPORT_DIR}" ]]; then
        log_warn "Default report directory ${REPORT_DIR} was not writable; used fallback ${report_dir}"
    fi
}

###############################################################################
# manage_diagnostics()
#
# Interactive menu for diagnostics.
###############################################################################
manage_diagnostics() {
    while true; do
        echo ""
        echo -e "${BLUE}============================================${NC}"
        echo -e "${BLUE}  Bifrost - Diagnostics           ${NC}"
        echo -e "${BLUE}============================================${NC}"
        echo ""
        echo "  1) Run full diagnostic"
        echo "  2) GFW detection test only"
        echo "  3) Generate JSON report"
        echo "  4) View latest report"
        echo "  0) Exit"
        echo ""
        read -r -p "Select option [0-4]: " choice

        case "${choice}" in
            1) echo ""; run_full_diagnostic ;;
            2) echo ""; test_gfw_detection ;;
            3) echo ""; generate_diagnostic_report ;;
            4)
                echo ""
                local latest
                latest="$(_resolve_report_dir)/diagnostic-report.json"
                if [[ -f "${latest}" ]]; then
                    if command_exists jq; then
                        jq '.' "${latest}"
                    else
                        cat "${latest}"
                    fi
                else
                    log_info "No diagnostic report found. Run option 3 first."
                fi
                ;;
            0|q|Q|exit)
                log_info "Exiting diagnostics."
                break
                ;;
            *)
                log_warn "Invalid option: ${choice}"
                ;;
        esac
    done
}

# =============================================================================
# Main execution
# =============================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        full)
            run_full_diagnostic
            ;;
        gfw)
            test_gfw_detection
            ;;
        report)
            generate_diagnostic_report
            ;;
        help|--help|-h)
            echo "Bifrost - Diagnostics"
            echo ""
            echo "Usage:"
            echo "  $0              # Interactive menu"
            echo "  $0 full         # Run full diagnostic"
            echo "  $0 gfw          # GFW detection test"
            echo "  $0 report       # Generate JSON report"
            echo "  $0 help         # Show this help"
            ;;
        "")
            manage_diagnostics
            ;;
        *)
            log_error "Unknown command: $1"
            echo "Run '$0 help' for usage information."
            exit 1
            ;;
    esac
fi
