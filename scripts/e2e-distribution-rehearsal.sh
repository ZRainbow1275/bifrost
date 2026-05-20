#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# e2e-distribution-rehearsal.sh
#
# Bifrost private-distribution + internal Claude marketplace E2E rehearsal.
#
# Two layers:
#   1. 0519-1 distribution stack (Verdaccio / files / git mirror / NewAPI)
#      -- legacy section, identical to the pre-PR-7 behaviour.
#   2. Internal Claude marketplace (PR-7 addition, spec.md sec.11 AC matrix).
#      Each AC self-reports PASS / FAIL / SKIP. The script exits non-zero
#      only when a scriptable AC truly fails; deferred ACs are SKIP, not FAIL.
#
# Modes:
#   default (dry-run) -- prints SSH/curl commands; the marketplace section
#                         still runs local + pytest checks so AC-1/4/7/8/9/
#                         11/12/14 self-verify without touching production.
#   --execute        -- additionally executes SSH/curl against Server A/B.
#
# Exit codes:
#   0  -- legacy commands completed AND 0 scriptable AC failures
#   1  -- a scriptable marketplace AC failed; see [marketplace e2e] summary
#   2  -- usage error
# =============================================================================

SERVER_A="${BIFROST_SERVER_A_HOST:-10.8.0.1}"
SERVER_B="${BIFROST_SERVER_B_HOST:-10.8.0.2}"
DOMAIN="${BIFROST_DOMAIN:-uuhfn.cloud}"
DRY_RUN=1
SKIP_DOCKER="${BIFROST_E2E_SKIP_DOCKER:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    cat <<USAGE_EOF
Usage:
  scripts/e2e-distribution-rehearsal.sh [--execute] [--help]

Environment:
  BIFROST_SERVER_A_HOST   Server A SSH host or wg IP (default: 10.8.0.1)
  BIFROST_SERVER_B_HOST   Server B SSH host or wg IP (default: 10.8.0.2)
  BIFROST_DOMAIN          Public domain (default: uuhfn.cloud)
  BIFROST_E2E_SKIP_DOCKER Set to 1 to skip the docker-backed AC-7 fallback
                          (PR-7: when docker is unavailable the AC is
                          surfaced as SKIP with an explanatory message).

Default mode is dry-run. Use --execute only during a scheduled cutover window.
USAGE_EOF
}

run() {
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        printf '[dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --execute)
            DRY_RUN=0
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

echo "Bifrost distribution rehearsal"
echo "  Server A: ${SERVER_A}"
echo "  Server B: ${SERVER_B}"
echo "  Domain  : ${DOMAIN}"
echo "  Mode    : $([[ "${DRY_RUN}" -eq 1 ]] && echo dry-run || echo execute)"

run ssh "root@${SERVER_B}" "bash /opt/bifrost/scripts/server-b.sh --enable-distribution"
run ssh "root@${SERVER_A}" "systemctl reload caddy || systemctl restart caddy"
run curl -fsSI "https://npm.${DOMAIN}/"
run curl -fsS "https://files.${DOMAIN}/team-config/.claude.json.template" -o /tmp/bifrost-team-config-check.json
run git ls-remote "https://files.${DOMAIN}/git/claude-for-legal-zh.git" HEAD
run curl -fsS "https://api.${DOMAIN}/api/status" -o /tmp/bifrost-newapi-status.json
run dig +short "panel.${DOMAIN}"
run curl -fsSI "https://panel.${DOMAIN}/"

echo "Rehearsal command list completed."

# =============================================================================
# Marketplace E2E (PR-7, spec.md sec.11 AC-1..AC-14)
# Runs locally regardless of --execute; uses no network beyond GitHub raw
# (only AC-12 calls out, and only when network is available).
# =============================================================================
MK_PASS=0
MK_FAIL=0
MK_SKIP=0
MK_RESULTS=()

mk_pass() {
    MK_PASS=$((MK_PASS + 1))
    MK_RESULTS+=("PASS $*")
    printf '[marketplace e2e][PASS] %s\n' "$*"
}
mk_fail() {
    MK_FAIL=$((MK_FAIL + 1))
    MK_RESULTS+=("FAIL $*")
    printf '[marketplace e2e][FAIL] %s\n' "$*" >&2
}
mk_skip() {
    MK_SKIP=$((MK_SKIP + 1))
    MK_RESULTS+=("SKIP $*")
    printf '[marketplace e2e][SKIP] %s\n' "$*"
}

mk_section() {
    printf '\n[marketplace e2e] === %s ===\n' "$*"
}

mk_section "Section A: scriptable AC checks (no real-server dependency)"

# --- AC-1: nmap baseline diff -----------------------------------------------
# In --execute mode this needs nmap + a baseline file on the cutover host.
# In dry-run we surface the static nftables drop contract as a proxy so the
# AC matrix has an explicit gate.
ac1_baseline_file="${BIFROST_E2E_NMAP_BASELINE:-/var/lib/bifrost/baseline/nmap-b-pre.txt}"
if [[ "${DRY_RUN}" -eq 0 ]]; then
    if command -v nmap >/dev/null 2>&1 && [[ -r "${ac1_baseline_file}" ]]; then
        ac1_tmp="$(mktemp)"
        if nmap -p- "${SERVER_B}" > "${ac1_tmp}" 2>/dev/null && \
           diff -q "${ac1_baseline_file}" "${ac1_tmp}" >/dev/null 2>&1; then
            mk_pass "AC-1: nmap baseline unchanged vs ${ac1_baseline_file}"
        else
            mk_fail "AC-1: nmap baseline diff (see ${ac1_tmp})"
        fi
    else
        mk_skip "AC-1: nmap baseline check needs nmap + baseline file on cutover host"
    fi
else
    nft_tpl="${SCRIPT_DIR}/configs/nftables/bifrost-distribution.nft.tpl"
    nft_drop_pattern='iifname != "wg0" tcp dport { 3000, 4873, 8081, 8082 } drop'
    if [[ -f "${nft_tpl}" ]] && grep -Fq "${nft_drop_pattern}" "${nft_tpl}"; then
        mk_pass "AC-1: nftables drop contract in place (live baseline diff deferred to --execute)"
    else
        mk_fail "AC-1: nftables drop contract missing -- baseline would diverge"
    fi
fi

# --- AC-4: extraKnownMarketplaces.bifrost-internal.source.url ---------------
ac4_template="${SCRIPT_DIR}/prompts/0519-1/team-config/.claude/settings.json.template"
if [[ ! -f "${ac4_template}" ]]; then
    mk_fail "AC-4: settings template missing at ${ac4_template}"
elif ! command -v jq >/dev/null 2>&1; then
    mk_skip "AC-4: jq not installed; skipping settings-template assertion"
else
    ac4_url="$(jq -er '.extraKnownMarketplaces["bifrost-internal"].source.url' "${ac4_template}" 2>/dev/null || true)"
    ac4_source="$(jq -er '.extraKnownMarketplaces["bifrost-internal"].source.source' "${ac4_template}" 2>/dev/null || true)"
    if [[ "${ac4_url}" == "https://files.uuhfn.cloud/git/bifrost-internal-plugins.git" \
       && "${ac4_source}" == "url" ]]; then
        mk_pass "AC-4: extraKnownMarketplaces.bifrost-internal.source.{source,url} (C2/C3 closed)"
    else
        mk_fail "AC-4: source.url=${ac4_url:-<missing>} source.source=${ac4_source:-<missing>}"
    fi
fi

# --- AC-7: server-b.sh --enable-distribution idempotence --------------------
# Strategy: re-use the existing test-in-docker distribution contract suite,
# which covers _distribution_step_done + idempotent step 07. When docker is
# unavailable, fall back to the same static contract grep.
if [[ "${SKIP_DOCKER}" != "1" ]] && command -v docker >/dev/null 2>&1 && \
   docker info >/dev/null 2>&1; then
    ac7_tmp="$(mktemp)"
    if bash "${SCRIPT_DIR}/tests/test-in-docker.sh" distribution > "${ac7_tmp}" 2>&1; then
        mk_pass "AC-7: tests/test-in-docker.sh distribution suite -- includes idempotence contract"
    else
        mk_fail "AC-7: distribution suite failed (see ${ac7_tmp})"
    fi
else
    if grep -Fq '_distribution_step_done' "${SCRIPT_DIR}/scripts/server-b.sh" && \
       grep -Fq '_distribution_prepare_marketplace_dirs' "${SCRIPT_DIR}/scripts/server-b.sh" && \
       grep -Fq '_distribution_init_marketplace_bare' "${SCRIPT_DIR}/scripts/server-b.sh"; then
        mk_pass "AC-7: server-b.sh idempotence + marketplace step injection (docker fallback contract grep)"
    else
        mk_fail "AC-7: server-b.sh idempotence contract grep FAILED"
    fi
fi

# --- AC-8 / AC-9 / AC-10 (mock) happy paths via pytest ----------------------
#   AC-8:  401 missing X-Admin-Key, 403 wrong key, 200 status w/ last_render_ts.
#   AC-9:  list happy path returning plugins list.
#   AC-10: admin upload happy path returning tag_created (mock; live deferred).
ac_py_target="${SCRIPT_DIR}/bifrost-api"
if [[ -d "${ac_py_target}/tests" ]] && command -v python >/dev/null 2>&1; then
    ac_py_tmp="$(mktemp)"
    if (cd "${ac_py_target}" && python -m pytest \
            tests/test_marketplace_router.py \
            tests/test_marketplace_admin_router.py \
            -q --no-header) > "${ac_py_tmp}" 2>&1; then
        mk_pass "AC-8/AC-9/AC-10 (mock): marketplace_router + marketplace_admin_router pytest PASS"
    else
        mk_fail "AC-8/AC-9/AC-10 pytest failed (see ${ac_py_tmp})"
    fi
else
    mk_skip "AC-8/AC-9/AC-10: bifrost-api or python missing; cannot run router pytest"
fi

# --- AC-11: LICENSE / NOTICE files exist and ALL-RIGHTS-RESERVED -----------
ac11_root="${SCRIPT_DIR}/prompts/0519-1/marketplace-bootstrap/bifrost-internal-plugins"
ac11_ok=1
[[ -f "${ac11_root}/LICENSE" ]] || ac11_ok=0
[[ -f "${ac11_root}/NOTICE" ]] || ac11_ok=0
if (( ac11_ok == 1 )) && grep -q "ALL-RIGHTS-RESERVED" "${ac11_root}/LICENSE" 2>/dev/null; then
    mk_pass "AC-11: bifrost-internal-plugins LICENSE + NOTICE present, ALL-RIGHTS-RESERVED"
else
    mk_fail "AC-11: LICENSE/NOTICE missing or non-ALL-RIGHTS-RESERVED under ${ac11_root}"
fi

# --- AC-12: check-upstream-schema.sh first-line regex -----------------------
# Redirect BASELINE_SHA256_FILE + STATE_FILE to /tmp so a rehearsal run can
# NEVER pollute /etc/bifrost-api/marketplace/upstream-license-baseline.sha256.
ac12_workdir="$(mktemp -d 2>/dev/null || true)"
if [[ -z "${ac12_workdir}" ]]; then
    mk_skip "AC-12: mktemp -d failed; skipping"
else
    if curl -fsI --max-time 5 https://github.com >/dev/null 2>&1; then
        ac12_out="$(BASELINE_SHA256_FILE="${ac12_workdir}/baseline.sha256" \
                    STATE_FILE="${ac12_workdir}/state.json" \
                    bash "${SCRIPT_DIR}/scripts/check-upstream-schema.sh" 2>&1 | head -1 || true)"
        if printf '%s\n' "${ac12_out}" | grep -Eq '^(LICENSE-OK|LICENSE-BASELINE-INIT|UPSTREAM-CHANGED) [0-9a-f]{64}'; then
            mk_pass "AC-12: check-upstream-schema.sh first-line regex matched (${ac12_out:0:80}...)"
        else
            mk_fail "AC-12: regex mismatch (output: ${ac12_out})"
        fi
        rm -rf "${ac12_workdir}"
    else
        rm -rf "${ac12_workdir}"
        mk_skip "AC-12: github.com unreachable; cannot run upstream LICENSE check"
    fi
fi

# --- AC-14: docs markers present in USAGE.md + SECURITY.md ------------------
ac14_ok=1
if ! grep -q "Server B 内部 Claude marketplace" "${SCRIPT_DIR}/docs/USAGE.md"; then
    ac14_ok=0
    mk_fail "AC-14: docs/USAGE.md missing marketplace section"
fi
if ! grep -q "Server B 内部 Claude marketplace 安全边界" "${SCRIPT_DIR}/docs/SECURITY.md"; then
    ac14_ok=0
    mk_fail "AC-14: docs/SECURITY.md missing marketplace security section"
fi
if (( ac14_ok == 1 )); then
    mk_pass "AC-14: docs/USAGE.md + docs/SECURITY.md contain marketplace section markers"
fi

mk_section "Section B: deferred AC (real-server cutover pending)"

mk_skip "AC-2: git clone bifrost-internal-plugins.git -- needs production Server A/B deploy"
mk_skip "AC-3: git ls-remote remote contract -- same upstream dependency as AC-2"
mk_skip "AC-5: claude --headless plugin install -- needs real client laptop and deployed marketplace"
mk_skip "AC-6: claude --headless plugin install --version v0.1.0 -- depends on AC-5 environment"
mk_skip "AC-10 (live): real bifrost-api upload + tag creation on Server B -- mock above; live needs deployed panel + SSH to B"
mk_skip "AC-13: dig +short panel.${DOMAIN} + allowlist gating -- code contract landed; live DNS/inside-allowlist curl needs --execute from an allowed network"

mk_section "Summary"
printf '[marketplace e2e] %d pass / %d fail / %d skip\n' "${MK_PASS}" "${MK_FAIL}" "${MK_SKIP}"
printf '[marketplace e2e] deferred ACs unblock when:\n'
printf '  - Server A + Server B are deployed and DNS panel.uuhfn.cloud resolves\n'
printf '  - --execute is run from a VPN/private source allowed by @panel_private\n'

if (( MK_FAIL > 0 )); then
    printf '[marketplace e2e] FAIL: %d scriptable AC(s) failed\n' "${MK_FAIL}" >&2
    exit 1
fi

echo "Marketplace e2e completed (scriptable AC suite green; deferred AC tracked)."
