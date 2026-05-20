#!/usr/bin/env bash
# =============================================================================
# check-upstream-schema.sh
#
# Daily watchdog for Anthropic claude-code LICENSE changes (ADR-4 fallback
# trigger). Compares sha256 of upstream LICENSE.md against a baseline shipped
# at /etc/bifrost-api/marketplace/upstream-license-baseline.sha256 (initialised
# by scripts/server-b.sh _distribution_init_upstream_schema_baseline).
#
# Output (always one line on stdout, AC-12 assertion):
#   LICENSE-OK <sha256> <iso8601>            -- unchanged
#   LICENSE-BASELINE-INIT <sha256> <iso8601> -- baseline file was empty/missing
#   UPSTREAM-CHANGED <old-sha> -> <new-sha> <iso8601> -- license drift detected
#
# Side effects:
#   - Writes upstream_alert / upstream_last_check_ts into
#     /var/lib/dist/plugins/state.json (atomic replace)
#   - On first run, writes baseline file if absent
#
# Exit codes:
#   0 -- success (including UPSTREAM-CHANGED; downstream consumes state.json)
#   2 -- usage error (no args expected; reserved)
#   3 -- network / curl error (caller decides whether to alert)
#
# Environment overrides (testing):
#   UPSTREAM_LICENSE_URL          (default: github raw URL)
#   BASELINE_SHA256_FILE          (default: /etc/bifrost-api/marketplace/...)
#   STATE_FILE                    (default: /var/lib/dist/plugins/state.json)
# =============================================================================
set -euo pipefail

UPSTREAM_LICENSE_URL="${UPSTREAM_LICENSE_URL:-https://github.com/anthropics/claude-code/raw/main/LICENSE.md}"
BASELINE_SHA256_FILE="${BASELINE_SHA256_FILE:-/etc/bifrost-api/marketplace/upstream-license-baseline.sha256}"
STATE_FILE="${STATE_FILE:-/var/lib/dist/plugins/state.json}"

ts="$(date -Iseconds)"

# Fetch upstream LICENSE; tolerate transient failure via exit 3 but still record
# the failure into state.json so the panel can show a stale-check badge.
current_sha256=""
if ! current_sha256=$(curl -fsSL --max-time 30 "${UPSTREAM_LICENSE_URL}" | sha256sum | awk '{print $1}'); then
    echo "LICENSE-CHECK-FAILED curl_or_network_error ${ts}" >&2
    # Best-effort: leave state.json untouched if jq missing or file missing.
    if command -v jq >/dev/null 2>&1 && [[ -f "${STATE_FILE}" ]]; then
        tmp="$(mktemp)"
        jq --arg ts "${ts}" '.upstream_last_check_ts = $ts | .upstream_last_check_status = "network_error"' \
            "${STATE_FILE}" > "${tmp}" && mv "${tmp}" "${STATE_FILE}" || rm -f "${tmp}"
    fi
    exit 3
fi

# Validate sha256 shape (64 hex chars) before treating as legitimate.
if [[ ! "${current_sha256}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "LICENSE-CHECK-FAILED bad_sha256 ${ts}" >&2
    exit 3
fi

baseline_sha256=""
if [[ -f "${BASELINE_SHA256_FILE}" ]]; then
    baseline_sha256="$(tr -d '[:space:]' < "${BASELINE_SHA256_FILE}" || true)"
fi

upstream_alert=false
if [[ -z "${baseline_sha256}" ]]; then
    # First run on this host (or baseline file got wiped). Initialise it; not an alert.
    install -d -m 0750 "$(dirname "${BASELINE_SHA256_FILE}")"
    printf '%s\n' "${current_sha256}" > "${BASELINE_SHA256_FILE}"
    chmod 0644 "${BASELINE_SHA256_FILE}"
    echo "LICENSE-BASELINE-INIT ${current_sha256} ${ts}"
    upstream_alert=false
elif [[ "${current_sha256}" == "${baseline_sha256}" ]]; then
    echo "LICENSE-OK ${current_sha256} ${ts}"
    upstream_alert=false
else
    echo "UPSTREAM-CHANGED ${baseline_sha256} -> ${current_sha256} ${ts}"
    upstream_alert=true
fi

# Update state.json atomically (best-effort; the render service is the
# authoritative writer for state.json so we only touch the upstream_* fields).
if command -v jq >/dev/null 2>&1; then
    if [[ ! -f "${STATE_FILE}" ]]; then
        # Render service hasn't run yet; seed a minimal file so the panel still
        # surfaces the upstream_alert badge.
        install -d -m 0755 "$(dirname "${STATE_FILE}")"
        printf '{"upstream_alert":false}\n' > "${STATE_FILE}"
        chmod 0644 "${STATE_FILE}"
    fi
    tmp="$(mktemp)"
    if jq --argjson a "${upstream_alert}" --arg ts "${ts}" \
        '.upstream_alert = $a | .upstream_last_check_ts = $ts | .upstream_last_check_status = "ok"' \
        "${STATE_FILE}" > "${tmp}"; then
        mv "${tmp}" "${STATE_FILE}"
    else
        rm -f "${tmp}"
        echo "WARN: failed to update state.json (jq error); upstream_alert=${upstream_alert}" >&2
    fi
else
    echo "WARN: jq not installed; state.json not updated (upstream_alert=${upstream_alert})" >&2
fi

exit 0
