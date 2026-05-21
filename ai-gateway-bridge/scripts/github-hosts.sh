#!/usr/bin/env bash
# =============================================================================
# Bifrost - GitHub hosts repair helper
# =============================================================================
# Fixes intermittent GitHub TLS pull failures on cloud hosts by writing a
# Bifrost-managed /etc/hosts block for github.com and raw.githubusercontent.com.
# =============================================================================

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

readonly GITHUB_HOSTS_BEGIN="# BIFROST-GITHUB-HOSTS-BEGIN"
readonly GITHUB_HOSTS_END="# BIFROST-GITHUB-HOSTS-END"
readonly DEFAULT_BIFROST_REPO_URL="https://github.com/ZRainbow1275/bifrost.git"

github_hosts_usage() {
    cat <<'USAGE'
Bifrost GitHub hosts repair

Usage:
  ./scripts/github-hosts.sh
  ./install.sh --github-hosts-repair

Environment:
  BIFROST_HOSTS_FILE=/etc/hosts
      Override hosts file path for tests.
  BIFROST_GITHUB_HOSTS_RESOLVE_MODE=static
      Use BIFROST_GITHUB_IP and BIFROST_RAW_GITHUB_IP instead of DNS-over-HTTPS.
  BIFROST_GITHUB_IP=140.82.112.4
  BIFROST_RAW_GITHUB_IP=185.199.108.133
  BIFROST_GITHUB_HOSTS_SKIP_GIT_CHECK=1
      Skip git ls-remote verification.
  BIFROST_GITHUB_HOSTS_REPO_URL=https://github.com/ZRainbow1275/bifrost.git
USAGE
}

valid_ipv4_format() {
    local ip="$1"
    local IFS=.
    local -a octets=()

    read -r -a octets <<< "${ip}"
    [[ "${#octets[@]}" -eq 4 ]] || return 1

    local octet
    for octet in "${octets[@]}"; do
        [[ "${octet}" =~ ^[0-9]+$ ]] || return 1
        (( octet >= 0 && octet <= 255 )) || return 1
    done
}

public_ipv4() {
    local ip="$1"
    valid_ipv4_format "${ip}" || return 1

    local IFS=.
    local -a octets=()
    read -r -a octets <<< "${ip}"

    local first="${octets[0]}"
    local second="${octets[1]}"

    [[ "${first}" == "0" || "${first}" == "10" || "${first}" == "127" || "${first}" == "255" ]] && return 1
    [[ "${first}" == "169" && "${second}" == "254" ]] && return 1
    [[ "${first}" == "172" && "${second}" -ge 16 && "${second}" -le 31 ]] && return 1
    [[ "${first}" == "192" && "${second}" == "168" ]] && return 1

    return 0
}

extract_doh_ipv4_records() {
    grep -Eo '"data"[[:space:]]*:[[:space:]]*"([0-9]{1,3}\.){3}[0-9]{1,3}"' \
        | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' \
        || true
}

query_doh_provider() {
    local provider="$1"
    local domain="$2"
    local url=()

    case "${provider}" in
        alidns)
            url=("https://dns.alidns.com/resolve?name=${domain}&type=A")
            ;;
        cloudflare)
            url=("-H" "accept: application/dns-json" "https://cloudflare-dns.com/dns-query?name=${domain}&type=A")
            ;;
        google)
            url=("https://dns.google/resolve?name=${domain}&type=A")
            ;;
        *)
            return 1
            ;;
    esac

    local response
    response="$(curl -4 -fsSL --connect-timeout 5 --max-time 12 --retry 1 "${url[@]}" 2>/dev/null || true)"
    [[ -n "${response}" ]] || return 1

    local ip
    while IFS= read -r ip; do
        if public_ipv4 "${ip}"; then
            printf '%s\n' "${ip}"
            return 0
        fi
    done < <(printf '%s\n' "${response}" | extract_doh_ipv4_records)

    return 1
}

resolve_static_ip() {
    local result_var="$1"
    local domain="$2"
    local ip=""

    case "${domain}" in
        github.com)
            ip="${BIFROST_GITHUB_IP:-}"
            ;;
        raw.githubusercontent.com)
            ip="${BIFROST_RAW_GITHUB_IP:-}"
            ;;
        *)
            return 1
            ;;
    esac

    if ! public_ipv4 "${ip}"; then
        log_error "Static IP for ${domain} is invalid or private: ${ip:-<empty>}"
        return 1
    fi

    printf -v "${result_var}" '%s' "${ip}"
}

resolve_domain_ip() {
    local result_var="$1"
    local domain="$2"

    if [[ "${BIFROST_GITHUB_HOSTS_RESOLVE_MODE:-doh}" == "static" ]]; then
        resolve_static_ip "${result_var}" "${domain}"
        return $?
    fi

    if ! command -v curl >/dev/null 2>&1; then
        log_error "curl is required for DNS-over-HTTPS resolution. Install curl or use BIFROST_GITHUB_HOSTS_RESOLVE_MODE=static."
        return 1
    fi

    local provider
    local ip
    for provider in alidns cloudflare google; do
        log_info "Resolving ${domain} via ${provider} DNS-over-HTTPS..."
        if ip="$(query_doh_provider "${provider}" "${domain}")"; then
            printf -v "${result_var}" '%s' "${ip}"
            log_success "${domain} -> ${ip}"
            return 0
        fi
    done

    log_error "Unable to resolve a public IPv4 address for ${domain} through DNS-over-HTTPS."
    log_error "Use manual values if needed: BIFROST_GITHUB_HOSTS_RESOLVE_MODE=static BIFROST_GITHUB_IP=<ip> BIFROST_RAW_GITHUB_IP=<ip> ./scripts/github-hosts.sh"
    return 1
}

ensure_hosts_file_writable() {
    local hosts_file="$1"

    if [[ "${hosts_file}" == "/etc/hosts" && "$(id -u)" -ne 0 ]]; then
        log_error "This repair modifies /etc/hosts. Run as root: sudo ./install.sh --github-hosts-repair"
        return 1
    fi

    local hosts_dir
    hosts_dir="$(dirname "${hosts_file}")"
    mkdir -p "${hosts_dir}"

    if [[ ! -e "${hosts_file}" ]]; then
        install -m 0644 /dev/null "${hosts_file}"
    fi

    if [[ ! -w "${hosts_file}" ]]; then
        log_error "Hosts file is not writable: ${hosts_file}"
        return 1
    fi
}

write_github_hosts_block() {
    local hosts_file="$1"
    local github_ip="$2"
    local raw_github_ip="$3"

    local backup_file="${hosts_file}.bifrost-github.$(date +%Y%m%d-%H%M%S).bak"
    cp -p "${hosts_file}" "${backup_file}"

    local tmp_file
    tmp_file="$(mktemp)"
    awk -v begin="${GITHUB_HOSTS_BEGIN}" -v end="${GITHUB_HOSTS_END}" '
        $0 == begin { skipping = 1; next }
        $0 == end { skipping = 0; next }
        skipping != 1 { print }
    ' "${hosts_file}" > "${tmp_file}"

    {
        printf '\n%s\n' "${GITHUB_HOSTS_BEGIN}"
        printf '# Generated by Bifrost at %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
        printf '%s github.com\n' "${github_ip}"
        printf '%s raw.githubusercontent.com\n' "${raw_github_ip}"
        printf '%s\n' "${GITHUB_HOSTS_END}"
    } >> "${tmp_file}"

    cat "${tmp_file}" > "${hosts_file}"
    rm -f "${tmp_file}"

    log_success "Updated ${hosts_file}"
    log_info "Backup saved: ${backup_file}"
}

hosts_file_contains_mapping() {
    local hosts_file="$1"
    local expected_ip="$2"
    local expected_domain="$3"

    awk -v expected_ip="${expected_ip}" -v expected_domain="${expected_domain}" '
        $1 == expected_ip {
            for (i = 2; i <= NF; i++) {
                if ($i == expected_domain) {
                    found = 1
                }
            }
        }
        END { exit(found ? 0 : 1) }
    ' "${hosts_file}"
}

verify_hosts_block() {
    local hosts_file="$1"
    local github_ip="$2"
    local raw_github_ip="$3"

    hosts_file_contains_mapping "${hosts_file}" "${github_ip}" "github.com" \
        || { log_error "github.com mapping was not written to ${hosts_file}"; return 1; }
    hosts_file_contains_mapping "${hosts_file}" "${raw_github_ip}" "raw.githubusercontent.com" \
        || { log_error "raw.githubusercontent.com mapping was not written to ${hosts_file}"; return 1; }

    if [[ "${hosts_file}" == "/etc/hosts" ]]; then
        getent hosts github.com || log_warn "getent could not resolve github.com after hosts update."
        getent hosts raw.githubusercontent.com || log_warn "getent could not resolve raw.githubusercontent.com after hosts update."
    fi

    log_success "Hosts mappings verified."
}

verify_git_access() {
    if [[ "${BIFROST_GITHUB_HOSTS_SKIP_GIT_CHECK:-0}" == "1" ]]; then
        log_warn "Skipping git verification because BIFROST_GITHUB_HOSTS_SKIP_GIT_CHECK=1."
        return 0
    fi

    if ! command -v git >/dev/null 2>&1; then
        log_warn "git is not installed; hosts file was repaired, but repository access was not verified."
        return 0
    fi

    local repo_url="${BIFROST_GITHUB_HOSTS_REPO_URL:-${DEFAULT_BIFROST_REPO_URL}}"
    log_info "Verifying GitHub access: git ls-remote --heads ${repo_url} main"
    if GIT_TERMINAL_PROMPT=0 git ls-remote --heads "${repo_url}" main >/dev/null 2>&1; then
        log_success "GitHub repository access verified."
        return 0
    fi

    log_error "GitHub hosts block was written, but git verification still failed."
    log_error "If this is Tencent Cloud line instability, use the Windows upload fallback in the runbook once, then rerun this command."
    return 1
}

repair_github_hosts() {
    local hosts_file="${BIFROST_HOSTS_FILE:-/etc/hosts}"
    local github_ip=""
    local raw_github_ip=""

    print_section "GitHub Hosts Repair"
    log_info "Hosts file: ${hosts_file}"

    ensure_hosts_file_writable "${hosts_file}"
    resolve_domain_ip github_ip "github.com"
    resolve_domain_ip raw_github_ip "raw.githubusercontent.com"
    write_github_hosts_block "${hosts_file}" "${github_ip}" "${raw_github_ip}"
    verify_hosts_block "${hosts_file}" "${github_ip}" "${raw_github_ip}"
    verify_git_access
}

main() {
    case "${1:-}" in
        "" )
            repair_github_hosts
            ;;
        --help|-h)
            github_hosts_usage
            ;;
        *)
            log_error "Unknown argument: $1"
            github_hosts_usage
            exit 1
            ;;
    esac
}

main "$@"
