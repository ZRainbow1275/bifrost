#!/usr/bin/env bash
# =============================================================================
# Bifrost - Cloud Readiness & DD Reinstall Preflight Module
# =============================================================================
# Description : Detects cloud provider integrations, reports platform agents
#               and dependencies for operator review, and optionally performs
#               a full DD reinstall using bin456789/reinstall.
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
# Project     : Bifrost (国内外 AI 服务桥接一键部署方案)
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

CLOUD_REVIEW_MODE_EFFECTIVE="interactive"
CLOUD_REVIEW_REPORT_ONLY_COMPLETED=0
CLOUD_REVIEW_DEPLOYMENT_BLOCK_REASON=""
CLOUD_REVIEW_REPORT_DIR_EFFECTIVE=""
CLOUD_REVIEW_TEXT_REPORT=""
CLOUD_REVIEW_JSON_REPORT=""
CLOUD_REVIEW_FILESTAMP=""
CLOUD_REVIEW_TIMESTAMP=""
CLOUD_REVIEW_INTEGRATIONS_FOUND=0
CLOUD_REVIEW_REVIEW_ACKNOWLEDGED=0
CLOUD_REVIEW_VERIFICATION_OK=0
CLOUD_REVIEW_VERIFICATION_WARNING_COUNT=0
CLOUD_REVIEW_KERNEL_VERSION="unknown"
CLOUD_REVIEW_KERNEL_PROFILE_STATUS="ok"
CLOUD_REVIEW_BBR_AVAILABLE="unknown"
CLOUD_REVIEW_BBR_ACTIVE="unknown"
CLOUD_REVIEW_CURRENT_CC="unknown"
CLOUD_REVIEW_AVAILABLE_CC="unknown"
CLOUD_REVIEW_CLOUD_INIT_ACTIVE="unknown"
CLOUD_REVIEW_MENU_PRESENTED=0
CLOUD_REVIEW_CONFIRMATION_PROMPTED=0
CLOUD_REVIEW_DD_REINSTALL_SELECTED=0
declare -a CLOUD_REVIEW_PROVIDER_REPOS=()
declare -a CLOUD_REVIEW_TRUST_FILES=()
declare -a CLOUD_REVIEW_PROVIDER_LISTENERS=()
declare -a CLOUD_REVIEW_WARNINGS=()

# =============================================================================
# Cloud Review Helpers
# =============================================================================

_cloud_review_reset_state() {
    DETECTED_PROVIDER="unknown"
    DETECTED_AGENTS_SERVICES=()
    DETECTED_AGENTS_PROCESSES=()
    DETECTED_AGENTS_PACKAGES=()
    DETECTED_AGENTS_PATHS=()
    DETECTED_AGENTS_CRONS=()

    CLOUD_REVIEW_MODE_EFFECTIVE="interactive"
    CLOUD_REVIEW_REPORT_ONLY_COMPLETED=0
    CLOUD_REVIEW_DEPLOYMENT_BLOCK_REASON=""
    CLOUD_REVIEW_REPORT_DIR_EFFECTIVE=""
    CLOUD_REVIEW_TEXT_REPORT=""
    CLOUD_REVIEW_JSON_REPORT=""
    CLOUD_REVIEW_FILESTAMP="$(date '+%Y%m%d_%H%M%S')"
    CLOUD_REVIEW_TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    CLOUD_REVIEW_INTEGRATIONS_FOUND=0
    CLOUD_REVIEW_REVIEW_ACKNOWLEDGED=0
    CLOUD_REVIEW_VERIFICATION_OK=0
    CLOUD_REVIEW_VERIFICATION_WARNING_COUNT=0
    CLOUD_REVIEW_KERNEL_VERSION="unknown"
    CLOUD_REVIEW_KERNEL_PROFILE_STATUS="ok"
    CLOUD_REVIEW_BBR_AVAILABLE="unknown"
    CLOUD_REVIEW_BBR_ACTIVE="unknown"
    CLOUD_REVIEW_CURRENT_CC="unknown"
    CLOUD_REVIEW_AVAILABLE_CC="unknown"
    CLOUD_REVIEW_CLOUD_INIT_ACTIVE="unknown"
    CLOUD_REVIEW_MENU_PRESENTED=0
    CLOUD_REVIEW_CONFIRMATION_PROMPTED=0
    CLOUD_REVIEW_DD_REINSTALL_SELECTED=0
    CLOUD_REVIEW_PROVIDER_REPOS=()
    CLOUD_REVIEW_TRUST_FILES=()
    CLOUD_REVIEW_PROVIDER_LISTENERS=()
    CLOUD_REVIEW_WARNINGS=()
}

cloud_review_is_report_only() {
    [[ "${CLOUD_REVIEW_REPORT_ONLY_COMPLETED:-0}" -eq 1 ]]
}

cloud_review_blocks_deployment() {
    [[ -n "${CLOUD_REVIEW_DEPLOYMENT_BLOCK_REASON:-}" ]]
}

_cloud_review_resolve_mode() {
    local cli_mode=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --report-only)
                cli_mode="report-only"
                ;;
            --interactive)
                cli_mode="interactive"
                ;;
            *)
                log_error "Unknown pre_deploy_check option: $1"
                return 1
                ;;
        esac
        shift
    done

    local mode="${cli_mode:-${BIFROST_CLOUD_REVIEW_MODE:-interactive}}"
    mode="${mode,,}"
    mode="${mode//_/-}"

    case "${mode}" in
        ""|interactive)
            printf '%s' "interactive"
            ;;
        report|report-only)
            printf '%s' "report-only"
            ;;
        *)
            log_error "Invalid BIFROST_CLOUD_REVIEW_MODE='${mode}'. Expected: interactive, report, or report-only."
            return 1
            ;;
    esac
}

_cloud_review_provider_label() {
    if [[ "${DETECTED_PROVIDER}" != "unknown" && -n "${DETECTED_PROVIDER}" ]]; then
        printf '%s' "${DETECTED_PROVIDER}"
    else
        printf '%s' "Unknown / Bare Metal"
    fi
}

_cloud_review_json_escape() {
    local value="${1-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "${value}"
}

_cloud_review_json_array() {
    local arr_name="${1:?}"
    local -n arr_ref="${arr_name}"
    local json="["
    local first=1
    local item

    for item in "${arr_ref[@]+"${arr_ref[@]}"}"; do
        if [[ ${first} -eq 0 ]]; then
            json+=","
        fi
        first=0
        json+="\"$(_cloud_review_json_escape "${item}")\""
    done

    json+="]"
    printf '%s' "${json}"
}

_cloud_review_write_json_payload() {
    local json_payload="${1:?}"
    local report_file="${2:?}"

    if check_command jq; then
        if ! printf '%s\n' "${json_payload}" | jq '.' > "${report_file}" 2>/dev/null; then
            log_error "Failed to validate rendered cloud review JSON."
            return 1
        fi
    else
        if ! printf '%s\n' "${json_payload}" > "${report_file}"; then
            log_error "Failed to write cloud review JSON report to ${report_file}."
            return 1
        fi
    fi

    if [[ ! -s "${report_file}" ]]; then
        log_error "Cloud review JSON report was not written correctly: ${report_file}"
        return 1
    fi
}

_cloud_review_append_warning() {
    local message="${1:?}"
    CLOUD_REVIEW_WARNINGS+=("${message}")
}

_cloud_review_resolve_report_file() {
    local extension="${1:?}"
    local explicit_path="${2:-}"
    local default_dir="${BIFROST_CLOUD_REVIEW_REPORT_DIR:-$(dirname "${LOG_FILE}")}"
    local fallback_dir="${TMPDIR:-/tmp}/$(basename "$(dirname "${LOG_FILE}")")"
    local target=""

    if [[ -n "${explicit_path}" ]]; then
        target="${explicit_path}"
    else
        target="${default_dir}/cloud-readiness-review-${CLOUD_REVIEW_FILESTAMP}.${extension}"
    fi

    local target_dir
    target_dir="$(dirname "${target}")"
    if mkdir -p "${target_dir}" 2>/dev/null; then
        printf '%s' "${target}"
        return 0
    fi

    if [[ -n "${explicit_path}" || -n "${BIFROST_CLOUD_REVIEW_REPORT_DIR:-}" ]]; then
        log_error "Cloud review report path is not writable: ${target_dir}"
        return 1
    fi

    mkdir -p "${fallback_dir}"
    printf '%s' "${fallback_dir}/cloud-readiness-review-${CLOUD_REVIEW_FILESTAMP}.${extension}"
}

_cloud_review_overall_status() {
    if cloud_review_is_report_only; then
        printf '%s' "report-only"
    elif [[ ${CLOUD_REVIEW_REVIEW_ACKNOWLEDGED} -ne 1 ]]; then
        printf '%s' "review-required"
    elif [[ ${CLOUD_REVIEW_VERIFICATION_OK} -ne 1 ]]; then
        printf '%s' "verification-failed"
    elif [[ ${CLOUD_REVIEW_VERIFICATION_WARNING_COUNT} -gt 0 ]]; then
        printf '%s' "review-with-warnings"
    else
        printf '%s' "ready"
    fi
}

_cloud_review_write_text_report() {
    local report_file="${1:?}"
    local json_file="${2:?}"
    local overall_status
    local deployment_ready="no"
    overall_status="$(_cloud_review_overall_status)"
    if [[ ${CLOUD_REVIEW_REVIEW_ACKNOWLEDGED} -eq 1 && ${CLOUD_REVIEW_VERIFICATION_OK} -eq 1 && ${CLOUD_REVIEW_REPORT_ONLY_COMPLETED} -ne 1 ]]; then
        deployment_ready="yes"
    fi

    {
        echo "Bifrost Cloud Readiness Review"
        echo "Generated At (UTC): ${CLOUD_REVIEW_TIMESTAMP}"
        echo "Mode: ${CLOUD_REVIEW_MODE_EFFECTIVE}"
        echo "Overall Status: ${overall_status}"
        echo "Deployment Ready: ${deployment_ready}"
        echo "Cloud Provider: $(_cloud_review_provider_label)"
        echo "Integrations Found: ${CLOUD_REVIEW_INTEGRATIONS_FOUND}"
        echo "Review Acknowledged: ${CLOUD_REVIEW_REVIEW_ACKNOWLEDGED}"
        echo "Verification OK: ${CLOUD_REVIEW_VERIFICATION_OK}"
        echo "Verification Warning Count: ${CLOUD_REVIEW_VERIFICATION_WARNING_COUNT}"
        echo "Report Only Completed: ${CLOUD_REVIEW_REPORT_ONLY_COMPLETED}"
        echo "Menu Presented: ${CLOUD_REVIEW_MENU_PRESENTED}"
        echo "Confirmation Prompted: ${CLOUD_REVIEW_CONFIRMATION_PROMPTED}"
        echo "DD Reinstall Selected: ${CLOUD_REVIEW_DD_REINSTALL_SELECTED}"
        echo "Text Report: ${report_file}"
        echo "JSON Report: ${json_file}"
        echo ""
        echo "Review Boundary"
        echo "- Report-only: inventory plus report export only; no DD menu, no confirmation prompt, no provider-managed component changes."
        echo "- Review & acknowledge: inventory plus operator acknowledgement; still no provider-managed component changes."
        echo "- Full DD Reinstall: separate destructive path that wipes the OS after explicit operator confirmation."
        echo ""
        echo "Detected Cloud Integrations"
        if (( ${#DETECTED_AGENTS_SERVICES[@]} == 0 && ${#DETECTED_AGENTS_PROCESSES[@]} == 0 && ${#DETECTED_AGENTS_PACKAGES[@]} == 0 && ${#DETECTED_AGENTS_PATHS[@]} == 0 && ${#DETECTED_AGENTS_CRONS[@]} == 0 )); then
            echo "- none"
        else
            local item
            for item in "${DETECTED_AGENTS_SERVICES[@]+"${DETECTED_AGENTS_SERVICES[@]}"}"; do
                echo "- service: ${item}"
            done
            for item in "${DETECTED_AGENTS_PROCESSES[@]+"${DETECTED_AGENTS_PROCESSES[@]}"}"; do
                echo "- process: ${item}"
            done
            for item in "${DETECTED_AGENTS_PACKAGES[@]+"${DETECTED_AGENTS_PACKAGES[@]}"}"; do
                echo "- package: ${item}"
            done
            for item in "${DETECTED_AGENTS_PATHS[@]+"${DETECTED_AGENTS_PATHS[@]}"}"; do
                echo "- path: ${item}"
            done
            for item in "${DETECTED_AGENTS_CRONS[@]+"${DETECTED_AGENTS_CRONS[@]}"}"; do
                echo "- cron: ${item}"
            done
        fi
        echo ""
        echo "Provider Repositories / Trust Material"
        if (( ${#CLOUD_REVIEW_PROVIDER_REPOS[@]} == 0 && ${#CLOUD_REVIEW_TRUST_FILES[@]} == 0 )); then
            echo "- none"
        else
            local repo_entry
            for repo_entry in "${CLOUD_REVIEW_PROVIDER_REPOS[@]+"${CLOUD_REVIEW_PROVIDER_REPOS[@]}"}"; do
                echo "- repo: ${repo_entry}"
            done
            for repo_entry in "${CLOUD_REVIEW_TRUST_FILES[@]+"${CLOUD_REVIEW_TRUST_FILES[@]}"}"; do
                echo "- trust-file: ${repo_entry}"
            done
        fi
        echo ""
        echo "Verification Signals"
        echo "- kernel_version: ${CLOUD_REVIEW_KERNEL_VERSION}"
        echo "- kernel_profile_status: ${CLOUD_REVIEW_KERNEL_PROFILE_STATUS}"
        echo "- bbr_available: ${CLOUD_REVIEW_BBR_AVAILABLE}"
        echo "- bbr_active: ${CLOUD_REVIEW_BBR_ACTIVE}"
        echo "- current_congestion_control: ${CLOUD_REVIEW_CURRENT_CC}"
        echo "- available_congestion_controls: ${CLOUD_REVIEW_AVAILABLE_CC}"
        echo "- cloud_init_active: ${CLOUD_REVIEW_CLOUD_INIT_ACTIVE}"
        if (( ${#CLOUD_REVIEW_PROVIDER_LISTENERS[@]} > 0 )); then
            local listener
            for listener in "${CLOUD_REVIEW_PROVIDER_LISTENERS[@]+"${CLOUD_REVIEW_PROVIDER_LISTENERS[@]}"}"; do
                echo "- provider_listener: ${listener}"
            done
        fi
        if (( ${#CLOUD_REVIEW_WARNINGS[@]} > 0 )); then
            echo ""
            echo "Warnings"
            local warning
            for warning in "${CLOUD_REVIEW_WARNINGS[@]+"${CLOUD_REVIEW_WARNINGS[@]}"}"; do
                echo "- ${warning}"
            done
        fi
        echo ""
        echo "Next Steps"
        if cloud_review_is_report_only; then
            echo "- Review this report against cloud console metadata, cloud-init, SSH key recovery, security groups, monitoring, audit, and backup dependencies."
            echo "- Rerun the gate without report-only mode before any deployment or DD reinstall."
        elif [[ ${CLOUD_REVIEW_INTEGRATIONS_FOUND} -eq 1 && ${CLOUD_REVIEW_REVIEW_ACKNOWLEDGED} -ne 1 ]]; then
            echo "- Complete the interactive review and acknowledgement step before deployment."
        fi
        echo "- Use Full DD Reinstall only on disposable or first-build hosts after confirming console access, rollback path, and backup integrity."
    } > "${report_file}"

    if [[ ! -s "${report_file}" ]]; then
        log_error "Cloud review text report was not written correctly: ${report_file}"
        return 1
    fi
}

_cloud_review_write_json_report() {
    local report_file="${1:?}"
    local text_file="${2:?}"
    local overall_status
    local deployment_ready_json="false"
    local integrations_found_json="false"
    local review_ack_json="false"
    local verification_ok_json="false"
    local report_only_json="false"
    local menu_presented_json="false"
    local confirmation_json="false"
    local dd_selected_json="false"
    local cloud_init_json="false"

    overall_status="$(_cloud_review_overall_status)"
    if [[ ${CLOUD_REVIEW_REVIEW_ACKNOWLEDGED} -eq 1 && ${CLOUD_REVIEW_VERIFICATION_OK} -eq 1 && ${CLOUD_REVIEW_REPORT_ONLY_COMPLETED} -ne 1 ]]; then
        deployment_ready_json="true"
    fi
    if [[ ${CLOUD_REVIEW_INTEGRATIONS_FOUND} -eq 1 ]]; then
        integrations_found_json="true"
    fi
    if [[ ${CLOUD_REVIEW_REVIEW_ACKNOWLEDGED} -eq 1 ]]; then
        review_ack_json="true"
    fi
    if [[ ${CLOUD_REVIEW_VERIFICATION_OK} -eq 1 ]]; then
        verification_ok_json="true"
    fi
    if [[ ${CLOUD_REVIEW_REPORT_ONLY_COMPLETED} -eq 1 ]]; then
        report_only_json="true"
    fi
    if [[ ${CLOUD_REVIEW_MENU_PRESENTED} -eq 1 ]]; then
        menu_presented_json="true"
    fi
    if [[ ${CLOUD_REVIEW_CONFIRMATION_PROMPTED} -eq 1 ]]; then
        confirmation_json="true"
    fi
    if [[ ${CLOUD_REVIEW_DD_REINSTALL_SELECTED} -eq 1 ]]; then
        dd_selected_json="true"
    fi
    if [[ "${CLOUD_REVIEW_CLOUD_INIT_ACTIVE}" == "true" ]]; then
        cloud_init_json="true"
    fi

    local json="{"
    json+="\"timestamp\":\"$(_cloud_review_json_escape "${CLOUD_REVIEW_TIMESTAMP}")\","
    json+="\"mode\":\"$(_cloud_review_json_escape "${CLOUD_REVIEW_MODE_EFFECTIVE}")\","
    json+="\"overall_status\":\"$(_cloud_review_json_escape "${overall_status}")\","
    json+="\"deployment_ready\":${deployment_ready_json},"
    json+="\"report_only\":${report_only_json},"
    json+="\"provider\":{\"id\":\"$(_cloud_review_json_escape "${DETECTED_PROVIDER}")\",\"label\":\"$(_cloud_review_json_escape "$(_cloud_review_provider_label)")\"},"
    json+="\"review_gate\":{\"integrations_found\":${integrations_found_json},\"review_acknowledged\":${review_ack_json},\"verification_ok\":${verification_ok_json},\"menu_presented\":${menu_presented_json},\"confirmation_prompted\":${confirmation_json},\"dd_reinstall_selected\":${dd_selected_json},\"deployment_block_reason\":\"$(_cloud_review_json_escape "${CLOUD_REVIEW_DEPLOYMENT_BLOCK_REASON}")\"},"
    json+="\"integrations\":{\"services\":$(_cloud_review_json_array DETECTED_AGENTS_SERVICES),\"processes\":$(_cloud_review_json_array DETECTED_AGENTS_PROCESSES),\"packages\":$(_cloud_review_json_array DETECTED_AGENTS_PACKAGES),\"paths\":$(_cloud_review_json_array DETECTED_AGENTS_PATHS),\"crons\":$(_cloud_review_json_array DETECTED_AGENTS_CRONS)},"
    json+="\"provider_repositories\":$(_cloud_review_json_array CLOUD_REVIEW_PROVIDER_REPOS),"
    json+="\"trust_files\":$(_cloud_review_json_array CLOUD_REVIEW_TRUST_FILES),"
    json+="\"verification\":{\"warning_count\":${CLOUD_REVIEW_VERIFICATION_WARNING_COUNT},\"kernel_version\":\"$(_cloud_review_json_escape "${CLOUD_REVIEW_KERNEL_VERSION}")\",\"kernel_profile_status\":\"$(_cloud_review_json_escape "${CLOUD_REVIEW_KERNEL_PROFILE_STATUS}")\",\"bbr_available\":\"$(_cloud_review_json_escape "${CLOUD_REVIEW_BBR_AVAILABLE}")\",\"bbr_active\":\"$(_cloud_review_json_escape "${CLOUD_REVIEW_BBR_ACTIVE}")\",\"current_congestion_control\":\"$(_cloud_review_json_escape "${CLOUD_REVIEW_CURRENT_CC}")\",\"available_congestion_controls\":\"$(_cloud_review_json_escape "${CLOUD_REVIEW_AVAILABLE_CC}")\",\"cloud_init_active\":${cloud_init_json},\"provider_listeners\":$(_cloud_review_json_array CLOUD_REVIEW_PROVIDER_LISTENERS),\"warnings\":$(_cloud_review_json_array CLOUD_REVIEW_WARNINGS)},"
    json+="\"reports\":{\"text\":\"$(_cloud_review_json_escape "${text_file}")\",\"json\":\"$(_cloud_review_json_escape "${report_file}")\"},"
    json+="\"boundaries\":{\"review_only\":\"Inventory plus report export only; no DD menu, no confirmation prompt, no provider-managed component changes.\",\"review_acknowledge\":\"Operator acknowledgement clears the deployment gate without changing provider-managed components.\",\"full_dd_reinstall\":\"Separate destructive OS wipe path that requires explicit operator confirmation.\"}"
    json+="}"

    _cloud_review_write_json_payload "${json}" "${report_file}"
}

_cloud_review_write_reports() {
    local text_file json_file
    text_file="$(_cloud_review_resolve_report_file "txt" "${BIFROST_CLOUD_REVIEW_REPORT_PATH:-}")" || return 1
    json_file="$(_cloud_review_resolve_report_file "json" "${BIFROST_CLOUD_REVIEW_REPORT_JSON_PATH:-}")" || return 1

    CLOUD_REVIEW_REPORT_DIR_EFFECTIVE="$(dirname "${text_file}")"
    CLOUD_REVIEW_TEXT_REPORT="${text_file}"
    CLOUD_REVIEW_JSON_REPORT="${json_file}"

    _cloud_review_write_text_report "${text_file}" "${json_file}" || return 1
    _cloud_review_write_json_report "${json_file}" "${text_file}" || return 1
    chmod 600 "${text_file}" "${json_file}" 2>/dev/null || true

    if [[ -z "${BIFROST_CLOUD_REVIEW_REPORT_PATH:-}" ]]; then
        ln -sf "$(basename "${text_file}")" "${CLOUD_REVIEW_REPORT_DIR_EFFECTIVE}/cloud-readiness-review.txt" 2>/dev/null || cp -f "${text_file}" "${CLOUD_REVIEW_REPORT_DIR_EFFECTIVE}/cloud-readiness-review.txt" 2>/dev/null || true
    fi
    if [[ -z "${BIFROST_CLOUD_REVIEW_REPORT_JSON_PATH:-}" ]]; then
        ln -sf "$(basename "${json_file}")" "${CLOUD_REVIEW_REPORT_DIR_EFFECTIVE}/cloud-readiness-review.json" 2>/dev/null || cp -f "${json_file}" "${CLOUD_REVIEW_REPORT_DIR_EFFECTIVE}/cloud-readiness-review.json" 2>/dev/null || true
    fi
}

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
                    local current_crontab=""
                    current_crontab="$(crontab -l 2>/dev/null)" || current_crontab=""
                    if grep -qF "${value}" <<<"${current_crontab}"; then
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
          ${#DETECTED_AGENTS_PACKAGES[@]} + ${#DETECTED_AGENTS_PATHS[@]} + \
          ${#DETECTED_AGENTS_CRONS[@]} == 0 )); then
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

    print_section "Detected Cloud Integrations (${total} items)"

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
    log_warn "These components may provide cloud console monitoring, security, audit, SSH key, " \
             "metadata, backup, or recovery functions."
    log_warn "Bifrost inventories them for manual review only. Provider-managed services, files, packages, and trust material remain unchanged."
}

# =============================================================================
# Section 3 : Cloud Integration Review
# =============================================================================

# -----------------------------------------------------------------------------
# remove_cloud_agents:
#   Backward-compatible, non-destructive review entry point.
#   It reports detected cloud integrations and requires manual policy review.
#
#   Returns: 0 on success
# -----------------------------------------------------------------------------
remove_cloud_agents() {
    local total=$(( ${#DETECTED_AGENTS_SERVICES[@]} + ${#DETECTED_AGENTS_PROCESSES[@]} + \
                    ${#DETECTED_AGENTS_PACKAGES[@]} + ${#DETECTED_AGENTS_PATHS[@]} + \
                    ${#DETECTED_AGENTS_CRONS[@]} ))

    if (( total == 0 )); then
        log_info "No cloud provider integration components were detected."
        return 0
    fi

    print_section "Cloud Integration Manual Review Required"
    log_warn "${total} cloud-provider integration component(s) were detected."
    log_warn "This run is inventory and review only. Provider-managed services, packages, files, and trust material remain unchanged."
    log_warn "Review cloud console dependencies, security groups, SSH key injection, monitoring alerts, backups, and compliance policy before any manual change."
    echo ""

    if (( ${#DETECTED_AGENTS_SERVICES[@]} > 0 )); then
        echo -e "  ${COLOR_BOLD}Services requiring review:${COLOR_RESET}"
        for svc in ${DETECTED_AGENTS_SERVICES[@]+"${DETECTED_AGENTS_SERVICES[@]}"}; do
            local status
            status="$(systemctl is-active "${svc}" 2>/dev/null || echo 'unknown')"
            echo -e "    - ${COLOR_YELLOW}${svc}${COLOR_RESET} [${status}]"
        done
    fi

    if (( ${#DETECTED_AGENTS_PROCESSES[@]} > 0 )); then
        echo -e "  ${COLOR_BOLD}Processes requiring review:${COLOR_RESET}"
        for proc in ${DETECTED_AGENTS_PROCESSES[@]+"${DETECTED_AGENTS_PROCESSES[@]}"}; do
            echo -e "    - ${COLOR_YELLOW}${proc}${COLOR_RESET}"
        done
    fi

    if (( ${#DETECTED_AGENTS_PACKAGES[@]} > 0 )); then
        echo -e "  ${COLOR_BOLD}Packages requiring review:${COLOR_RESET}"
        for pkg in ${DETECTED_AGENTS_PACKAGES[@]+"${DETECTED_AGENTS_PACKAGES[@]}"}; do
            echo -e "    - ${COLOR_YELLOW}${pkg}${COLOR_RESET}"
        done
    fi

    if (( ${#DETECTED_AGENTS_PATHS[@]} > 0 )); then
        echo -e "  ${COLOR_BOLD}Paths requiring review:${COLOR_RESET}"
        for agent_path in ${DETECTED_AGENTS_PATHS[@]+"${DETECTED_AGENTS_PATHS[@]}"}; do
            echo -e "    - ${COLOR_YELLOW}${agent_path}${COLOR_RESET}"
        done
    fi

    if (( ${#DETECTED_AGENTS_CRONS[@]} > 0 )); then
        echo -e "  ${COLOR_BOLD}Cron entries requiring review:${COLOR_RESET}"
        for cron_pattern in ${DETECTED_AGENTS_CRONS[@]+"${DETECTED_AGENTS_CRONS[@]}"}; do
            echo -e "    - ${COLOR_YELLOW}${cron_pattern}${COLOR_RESET}"
        done
    fi

    echo ""
    _remove_provider_repos

    log_success "Cloud integration review report complete. No provider component was modified."
    return 0
}

# -----------------------------------------------------------------------------
# _remove_provider_repos:
#   Report cloud-provider-specific APT/YUM repositories and trust material.
# -----------------------------------------------------------------------------
_remove_provider_repos() {
    print_step 5 "Reviewing provider package repositories..."
    local repo_found=0

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
                    repo_found=1
                    _add_unique CLOUD_REVIEW_PROVIDER_REPOS "${found_file}"
                    log_warn "  APT repo requires manual review: ${found_file}"
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
                    repo_found=1
                    _add_unique CLOUD_REVIEW_PROVIDER_REPOS "${found_file}"
                    log_warn "  YUM repo requires manual review: ${found_file}"
                fi
            done
        done
    fi

    # GPG keys associated with cloud providers
    if [[ -d /etc/apt/trusted.gpg.d ]]; then
        for key_file in /etc/apt/trusted.gpg.d/*alibaba* /etc/apt/trusted.gpg.d/*tencent* \
                        /etc/apt/trusted.gpg.d/*huawei*; do
            if [[ -f "${key_file}" ]]; then
                repo_found=1
                _add_unique CLOUD_REVIEW_TRUST_FILES "${key_file}"
                log_warn "  GPG key requires manual review: ${key_file}"
            fi
        done
    fi

    if [[ ${repo_found} -eq 0 ]]; then
        log_success "  No provider package repositories or trust files detected."
    else
        log_warn "  Provider repositories and trust files were not changed automatically."
    fi
}

# =============================================================================
# Section 4 : DD Reinstall Offering
# =============================================================================

# -----------------------------------------------------------------------------
# offer_dd_reinstall:
#   Present the user with a menu to choose preflight handling:
#     1. Review detected cloud integrations and acknowledge dependencies
#     2. Full DD reinstall - wipe and reinstall OS via bin456789/reinstall
#     3. Skip - keep current system as-is
#
#   The DD reinstall uses the cnb.cool mirror for faster downloads in China.
#
#   Returns: 0 on success, 1 if skipped
# -----------------------------------------------------------------------------
offer_dd_reinstall() {
    print_section "Cloud Readiness Review Options"
    CLOUD_REVIEW_MENU_PRESENTED=1
    echo ""
    echo -e "  ${COLOR_DIM}Your server has cloud provider integrations that need operator review.${COLOR_RESET}"
    echo -e "  ${COLOR_DIM}Review & Acknowledge keeps the current system unchanged and only clears the deployment gate after operator review.${COLOR_RESET}"
    echo -e "  ${COLOR_DIM}Full DD Reinstall is the separate destructive path for first-build or disposable-host scenarios only.${COLOR_RESET}"
    echo ""

    local options=(
        "Review & Acknowledge - inventory cloud integrations, write report, no system changes"
        "Full DD Reinstall - destructive OS wipe & reinstall (requires reboot)"
        "Stop Here - keep current system as-is"
    )
    show_menu "Choose preflight action" options

    case "${MENU_RESULT}" in
        1)
            if _do_light_clean; then
                return 0
            fi
            return 1
            ;;
        2)
            if _do_dd_reinstall; then
                return 0
            fi
            return 1
            ;;
        3)
            log_info "Stopping after cloud integration review. Current system remains unchanged."
            return 1
            ;;
    esac
}

# -----------------------------------------------------------------------------
# _do_light_clean:
#   Execute the non-destructive cloud integration review path.
# -----------------------------------------------------------------------------
_do_light_clean() {
    print_section "Interactive Review & Acknowledge"

    remove_cloud_agents
    echo ""

    CLOUD_REVIEW_CONFIRMATION_PROMPTED=1
    if ! confirm_action "I have reviewed cloud console, SSH key, security group, monitoring, audit, backup, cloud-init, and metadata dependencies. Continue?" "n"; then
        log_info "Cloud integration review was not acknowledged."
        return 1
    fi

    log_success "Cloud integration review acknowledged. No provider component was modified."
    return 0
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
    CLOUD_REVIEW_DD_REINSTALL_SELECTED=1

    echo ""
    log_warn "============================================================"
    log_warn "  WARNING: THIS WILL COMPLETELY WIPE THE CURRENT SYSTEM"
    log_warn "  All data, configurations, and installed software will be lost."
    log_warn "  The server will reboot into a fresh OS installation."
    log_warn "============================================================"
    echo ""

    CLOUD_REVIEW_CONFIRMATION_PROMPTED=1
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
#   Cloud readiness and integration-state review:
#     1. Report known cloud-provider processes without treating them as failures
#     2. Report cloud-provider kernel variants
#     3. Report BBR congestion-control availability
#     4. Report cloud-init and metadata dependency implications
#
#   Returns: 0 when review completes
# -----------------------------------------------------------------------------
verify_clean_system() {
    log_info "Verifying cloud readiness and integration state..."
    local warnings=0

    # --- Check 1: Known provider integration processes ---
    print_step 1 "Reviewing known provider integration processes..."
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
            local process_message="Provider integration process detected: ${proc} (PID: $(pgrep -x "${proc}" | head -1))"
            log_warn "  ${process_message}"
            _cloud_review_append_warning "${process_message}"
            proc_found=1
            (( warnings++ )) || true
        fi
    done

    if [[ ${proc_found} -eq 0 ]]; then
        log_success "  No known provider integration processes detected."
    fi

    # --- Check 2: Kernel profile ---
    print_step 2 "Checking kernel profile..."
    local kernel_version
    kernel_version="$(uname -r)"
    CLOUD_REVIEW_KERNEL_VERSION="${kernel_version}"

    local kernel_ok=1
    if [[ "${kernel_version}" == *"tlinux"* ]] || [[ "${kernel_version}" == *"tencent"* ]]; then
        log_warn "  Tencent TLinux kernel detected: ${kernel_version}"
        log_warn "  Review compatibility with BBR, Docker networking, and cloud console recovery before DD reinstall."
        _cloud_review_append_warning "Tencent TLinux kernel detected: ${kernel_version}"
        kernel_ok=0
        CLOUD_REVIEW_KERNEL_PROFILE_STATUS="tencent-kernel"
        (( warnings++ )) || true
    elif [[ "${kernel_version}" == *"aliyun"* ]] || [[ "${kernel_version}" == *"alinux"* ]]; then
        log_warn "  Alibaba Alinux kernel detected: ${kernel_version}"
        log_warn "  Review compatibility with BBR, Docker networking, and cloud console recovery before DD reinstall."
        _cloud_review_append_warning "Alibaba Alinux kernel detected: ${kernel_version}"
        kernel_ok=0
        CLOUD_REVIEW_KERNEL_PROFILE_STATUS="alibaba-kernel"
        (( warnings++ )) || true
    elif [[ "${kernel_version}" == *"hwcloud"* ]] || [[ "${kernel_version}" == *"huawei"* ]]; then
        log_warn "  Huawei Cloud kernel detected: ${kernel_version}"
        _cloud_review_append_warning "Huawei Cloud kernel detected: ${kernel_version}"
        kernel_ok=0
        CLOUD_REVIEW_KERNEL_PROFILE_STATUS="huawei-kernel"
        (( warnings++ )) || true
    fi

    if [[ ${kernel_ok} -eq 1 ]]; then
        CLOUD_REVIEW_KERNEL_PROFILE_STATUS="ok"
        log_success "  Kernel profile: ${kernel_version}"
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
    if [[ ${bbr_available} -eq 1 ]]; then
        CLOUD_REVIEW_BBR_AVAILABLE="true"
    else
        CLOUD_REVIEW_BBR_AVAILABLE="false"
    fi

    # Check current congestion control
    local current_cc
    current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'unknown')"
    CLOUD_REVIEW_CURRENT_CC="${current_cc}"

    if [[ ${bbr_available} -eq 1 ]]; then
        if [[ "${current_cc}" == "bbr" ]]; then
            CLOUD_REVIEW_BBR_ACTIVE="true"
            log_success "  BBR is active: ${current_cc}"
        else
            CLOUD_REVIEW_BBR_ACTIVE="false"
            log_warn "  BBR is available but not active (current: ${current_cc})"
            log_info "  Will be enabled during deployment via sysctl configuration."
        fi
    else
        CLOUD_REVIEW_BBR_ACTIVE="false"
        log_warn "  BBR is NOT available on this kernel."
        log_warn "  Kernel version: ${kernel_version}"
        log_warn "  BBR requires kernel >= 4.9. Deployment can continue, but throughput may be lower."
        _cloud_review_append_warning "BBR is not available on kernel ${kernel_version}"
        (( warnings++ )) || true
    fi

    # --- Check 4: Available congestion control algorithms ---
    local available_cc
    available_cc="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo 'unknown')"
    CLOUD_REVIEW_AVAILABLE_CC="${available_cc}"
    log_info "  Available algorithms: ${available_cc}"

    # --- Check 5: Provider integration listeners ---
    print_step 4 "Reviewing provider integration listeners..."
    local provider_listeners=0

    if check_command ss; then
        while IFS= read -r line; do
            local listen_proc
            listen_proc="$(echo "${line}" | awk '{print $NF}')"
            for proc in ${known_agent_processes[@]+"${known_agent_processes[@]}"}; do
                if [[ "${listen_proc}" == *"${proc}"* ]]; then
                    local listener_message="Provider integration listener: ${line}"
                    log_warn "  ${listener_message}"
                    _add_unique CLOUD_REVIEW_PROVIDER_LISTENERS "${line}"
                    _cloud_review_append_warning "${listener_message}"
                    provider_listeners=1
                    (( warnings++ )) || true
                    break
                fi
            done
        done < <(ss -tlnp 2>/dev/null | tail -n +2)
    fi

    if [[ ${provider_listeners} -eq 0 ]]; then
        log_success "  No provider integration listeners found."
    fi

    # --- Check 6: cloud-init status ---
    print_step 5 "Checking cloud-init status..."
    if systemctl is-active cloud-init &>/dev/null 2>&1; then
        CLOUD_REVIEW_CLOUD_INIT_ACTIVE="true"
        log_warn "  cloud-init is active. It may manage SSH keys, hostname, routes, metadata, and bootstrap tasks."
        log_warn "  Verify DD/reinstall plans preserve console access, SSH key recovery, and required vendor-data behavior."
        _cloud_review_append_warning "cloud-init is active and may manage SSH keys, metadata, routes, and bootstrap tasks."
        (( warnings++ )) || true
    else
        CLOUD_REVIEW_CLOUD_INIT_ACTIVE="false"
        log_info "  cloud-init is not active or not installed."
    fi

    # --- Summary ---
    echo ""
    CLOUD_REVIEW_VERIFICATION_WARNING_COUNT="${warnings}"
    if (( warnings == 0 )); then
        log_success "Cloud readiness review passed: no warnings found."
    else
        log_warn "Cloud readiness review found ${warnings} warning(s)."
        log_warn "Deployment can continue after operator review; Bifrost did not modify provider components."
    fi
    return 0
}

# =============================================================================
# Section 6 : Pre-Deploy Check (Main Entry Point)
# =============================================================================

# -----------------------------------------------------------------------------
# pre_deploy_check:
#   Main orchestration function to be called at the start of deployment.
#   Runs the full cloud-readiness review pipeline:
#     1. Detect cloud provider
#     2. Scan for provider integrations
#     3. If integrations are found, either export a report-only review or require review acknowledgment / DD reinstall confirmation
#     4. Verify cloud readiness state
#
#   Designed to be called from install.sh before deploying any components.
#
#   Returns: 0 when the requested review completed. Interactive mode returns
#            nonzero if the deployment gate is not cleared.
# -----------------------------------------------------------------------------
pre_deploy_check() {
    local review_mode
    review_mode="$(_cloud_review_resolve_mode "$@")" || return 1
    _cloud_review_reset_state
    CLOUD_REVIEW_MODE_EFFECTIVE="${review_mode}"

    print_section "Pre-Deployment System Check"
    echo ""
    log_info "Checking cloud provider integrations and system readiness..."
    print_kv "Review Mode" "${CLOUD_REVIEW_MODE_EFFECTIVE}"
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

    # Step 2: Scan for cloud integrations
    local integrations_found=0
    local review_acknowledged=1
    local verification_ok=0
    if detect_preinstalled_agents; then
        integrations_found=1
    fi
    CLOUD_REVIEW_INTEGRATIONS_FOUND="${integrations_found}"

    # Step 3: Require review acknowledgment if cloud integrations were found
    if [[ ${integrations_found} -eq 1 ]]; then
        echo ""
        if [[ "${CLOUD_REVIEW_MODE_EFFECTIVE}" == "report-only" ]]; then
            log_info "Report-only mode selected: inventory and readiness verification will run without the DD menu or operator confirmation."
            if ! remove_cloud_agents; then
                log_error "Cloud integration review report could not be generated."
                return 1
            fi
            review_acknowledged=0
        else
            if ! offer_dd_reinstall; then
                review_acknowledged=0
                log_error "Cloud integration review was not acknowledged. Deployment must stop."
            fi
        fi
        echo ""
    else
        log_success "No cloud provider integrations detected. System is ready for deployment."
    fi
    CLOUD_REVIEW_REVIEW_ACKNOWLEDGED="${review_acknowledged}"

    # Step 4: Verify readiness state
    echo ""
    if verify_clean_system; then
        verification_ok=1
    else
        log_error "Cloud readiness verification detected unresolved issues. Deployment must stop."
    fi
    CLOUD_REVIEW_VERIFICATION_OK="${verification_ok}"

    if [[ "${CLOUD_REVIEW_MODE_EFFECTIVE}" == "report-only" ]]; then
        CLOUD_REVIEW_REPORT_ONLY_COMPLETED=1
        CLOUD_REVIEW_DEPLOYMENT_BLOCK_REASON="Report-only cloud readiness review completed. Inspect the generated report and rerun without report-only mode before deployment or DD reinstall."
    fi

    if ! _cloud_review_write_reports; then
        log_error "Failed to persist cloud readiness review reports."
        return 1
    fi

    print_kv "Review Report" "${CLOUD_REVIEW_TEXT_REPORT}"
    print_kv "Review JSON" "${CLOUD_REVIEW_JSON_REPORT}"
    local default_report_dir="${BIFROST_CLOUD_REVIEW_REPORT_DIR:-$(dirname "${LOG_FILE}")}"
    if [[ "${CLOUD_REVIEW_REPORT_DIR_EFFECTIVE}" != "${default_report_dir}" && -z "${BIFROST_CLOUD_REVIEW_REPORT_PATH:-}" && -z "${BIFROST_CLOUD_REVIEW_REPORT_JSON_PATH:-}" ]]; then
        log_warn "Default report directory ${default_report_dir} was not writable; used fallback ${CLOUD_REVIEW_REPORT_DIR_EFFECTIVE}"
    fi
    echo ""

    if cloud_review_is_report_only; then
        log_warn "Report-only review complete. Deployment remains blocked until an operator reviews the report and reruns the gate without report-only mode."
        echo ""
        return 0
    fi

    echo ""
    if [[ ${review_acknowledged} -ne 1 || ${verification_ok} -ne 1 ]]; then
        log_error "Pre-deployment check failed. Resolve the issues above before deployment."
        echo ""
        return 1
    fi

    log_success "Pre-deployment check complete. Proceeding with deployment..."
    echo ""

    return 0
}

# =============================================================================
# End of dd-reinstall.sh
# =============================================================================
log_info "dd-reinstall.sh loaded successfully."
