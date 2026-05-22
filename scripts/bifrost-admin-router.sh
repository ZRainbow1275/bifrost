#!/usr/bin/env bash
# ==============================================================================
# bifrost-admin-router.sh - forced-command admin write router (PR-5a)
# ==============================================================================
# Part of: Bifrost - Server B internal Claude marketplace (spec.md section 6.3)
# Purpose: Server-side dispatcher for the write-side admin SSH channel.
#
# Invoked by sshd as the forced-command for user bifrost-admin via
# authorized_keys command="/usr/local/bin/bifrost-admin-router.sh ..." line.
# Reads a JSON envelope from stdin produced by bifrost-api (PR-5a router) and
# dispatches one of the whitelisted verbs:
#
#   upload      - extract tarball + create plugin tag + push to bare repo
#   tag-create  - create an annotated tag against an existing ref (no upload)
#   approve     - record an approve/reject decision in the audit log
#   curate      - mutate marketplace.json metadata (feature/deprecate/remove)
#   rerender    - touch packed-refs to fire marketplace-render.path
#
# Exit codes (mapped by bifrost-api PR-5a router; see spec.md section 7.2):
#   0  - success
#   2  - forbidden verb / parse failure
#   9  - tag / version conflict
#   *  - other failure (mapped to HTTP 502 client side)
#
# Every successful and failed dispatch writes a single-line JSON record to
# /var/log/marketplace/admin-audit.log followed by sync so audit trails
# survive subsequent SSH timeouts.
#
# Security stance (spec.md M11 + section 12):
#   - Whitelist only; case falls through to exit 2 for unknown verbs.
#   - No eval / exec sh / bash -c constructs.
#   - Heredoc / stdin-only IPC; no shell expansion of remote-supplied strings.
#   - git operations run with -c user.email=... to avoid polluting global git.
# ==============================================================================

set -euo pipefail

readonly AUDIT_LOG="/var/log/marketplace/admin-audit.log"
readonly BARE_REPO="/var/lib/git-mirrors/bifrost-internal-plugins.git"
readonly RENDER_TRIGGER_FILE="${BARE_REPO}/packed-refs"
readonly GIT_AUTHOR_NAME="bifrost-admin"
readonly GIT_AUTHOR_EMAIL="bifrost-admin@uuhfn.cloud"

# Build a compact JSON object with jq so caller-controlled fields never rely on
# shell string interpolation for escaping.
audit_json() {
    jq -cn "$@"
}

# Print a one-line JSON record to stderr (journalctl) and to the audit log.
# Args: action success(true|false) [extra-json-object]
audit_log() {
    local action="$1"
    local success="$2"
    local extra="${3:-{}}"
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local audit_id="${AUDIT_ID:-unknown}"
    local actor="${ACTOR:-unknown}"
    local line

    if ! line="$(jq -cn \
        --arg ts "${ts}" \
        --arg audit_id "${audit_id}" \
        --arg action "${action}" \
        --arg actor "${actor}" \
        --argjson success "${success}" \
        --argjson extra "${extra}" \
        '{ts:$ts,audit_id:$audit_id,action:$action,actor:$actor,success:$success}
         + ($extra | del(.ts,.audit_id,.action,.actor,.success))' 2>/dev/null)"; then
        line="$(jq -cn \
            --arg ts "${ts}" \
            --arg audit_id "${audit_id}" \
            --arg action "${action}" \
            --arg actor "${actor}" \
            '{ts:$ts,audit_id:$audit_id,action:$action,actor:$actor,success:false,err:"invalid audit extra JSON"}')"
    fi
    if [[ -w "${AUDIT_LOG}" || ( ! -e "${AUDIT_LOG}" && -w "$(dirname "${AUDIT_LOG}")" ) ]]; then
        printf '%s\n' "${line}" >> "${AUDIT_LOG}"
        sync "${AUDIT_LOG}" 2>/dev/null || true
    fi
    printf 'admin-audit %s\n' "${line}" >&2
}

# Bail with exit code + audit + readable stderr.
bail() {
    local code="$1"
    local action="$2"
    local message="$3"
    audit_log "${action}" "false" "$(audit_json --arg err "${message}" '{err:$err}')"
    printf 'admin-router: %s\n' "${message}" >&2
    exit "${code}"
}

validate_tarball_entries() {
    local tarball="$1"
    local entry

    while IFS= read -r entry; do
        [[ -z "${entry}" ]] && continue
        case "${entry}" in
            /*|..|../*|*/../*|*/..)
                return 1
                ;;
        esac
    done < <(tar -tzf "${tarball}") || return 1
}

verb="${1:-}"
shift || true

ENVELOPE_JSON=""
if [[ ! -t 0 ]]; then
    ENVELOPE_JSON="$(cat)"
fi

# Extract audit_id / actor from envelope when present (used in audit log lines).
AUDIT_ID="unknown"
ACTOR="unknown"
if [[ -n "${ENVELOPE_JSON}" ]]; then
    AUDIT_ID="$(jq -r '.audit_id // "unknown"' <<< "${ENVELOPE_JSON}" 2>/dev/null || echo unknown)"
    ACTOR="$(jq -r '.actor // "unknown"' <<< "${ENVELOPE_JSON}" 2>/dev/null || echo unknown)"
fi

case "${verb}" in
    upload)
        plugin="${1:-}"
        version="${2:-}"
        if [[ -z "${plugin}" || -z "${version}" ]]; then
            bail 2 "upload" "missing plugin/version positional args"
        fi
        tarball_b64="$(jq -r '.tarball_b64 // empty' <<< "${ENVELOPE_JSON}")"
        if [[ -z "${tarball_b64}" ]]; then
            bail 2 "upload" "envelope missing tarball_b64"
        fi
        work="$(mktemp -d)"
        trap 'rm -rf "${work}"' EXIT
        cd "${work}"
        printf '%s' "${tarball_b64}" | base64 -d > plugin.tar.gz \
            || bail 1 "upload" "tarball base64 decode failed"
        validate_tarball_entries "${work}/plugin.tar.gz" \
            || bail 2 "upload" "tarball contains unsafe absolute or parent-relative paths"
        git clone --quiet "${BARE_REPO}" repo \
            || bail 1 "upload" "git clone bare failed"
        cd repo
        if git tag --list "plugins/${plugin}/v${version}" | grep -q .; then
            bail 9 "upload" "tag plugins/${plugin}/v${version} already exists"
        fi
        install -d "plugins/${plugin}"
        tar --no-same-owner --no-same-permissions -xzf "${work}/plugin.tar.gz" -C "plugins/${plugin}" \
            || bail 1 "upload" "tarball extract failed"
        git add -A "plugins/${plugin}"
        if ! git diff --cached --quiet; then
            git -c user.email="${GIT_AUTHOR_EMAIL}" -c user.name="${GIT_AUTHOR_NAME}" \
                commit --quiet -m "Upload plugins/${plugin} v${version} (audit ${AUDIT_ID})" \
                || bail 1 "upload" "git commit failed"
        fi
        git -c user.email="${GIT_AUTHOR_EMAIL}" -c user.name="${GIT_AUTHOR_NAME}" \
            tag -a "plugins/${plugin}/v${version}" \
            -m "Plugin ${plugin} v${version} (audit ${AUDIT_ID})" \
            || bail 1 "upload" "git tag failed"
        git push --quiet origin HEAD:main --tags \
            || bail 1 "upload" "git push failed"
        audit_log "upload" "true" \
            "$(audit_json --arg plugin "${plugin}" --arg version "${version}" --arg tag "plugins/${plugin}/v${version}" \
                '{plugin:$plugin,version:$version,tag:$tag}')"
        printf '{"tag":"plugins/%s/v%s"}\n' "${plugin}" "${version}"
        exit 0
        ;;

    tag-create)
        plugin="${1:-}"
        version="${2:-}"
        target_ref="${3:-HEAD}"
        if [[ -z "${plugin}" || -z "${version}" ]]; then
            bail 2 "tag-create" "missing plugin/version positional args"
        fi
        work="$(mktemp -d)"
        trap 'rm -rf "${work}"' EXIT
        cd "${work}"
        git clone --quiet "${BARE_REPO}" repo \
            || bail 1 "tag-create" "git clone bare failed"
        cd repo
        if git tag --list "plugins/${plugin}/v${version}" | grep -q .; then
            bail 9 "tag-create" "tag plugins/${plugin}/v${version} already exists"
        fi
        git -c user.email="${GIT_AUTHOR_EMAIL}" -c user.name="${GIT_AUTHOR_NAME}" \
            tag -a "plugins/${plugin}/v${version}" "${target_ref}" \
            -m "Plugin ${plugin} v${version} (audit ${AUDIT_ID})" \
            || bail 1 "tag-create" "git tag failed"
        git push --quiet origin "plugins/${plugin}/v${version}" \
            || bail 1 "tag-create" "git push failed"
        audit_log "tag-create" "true" \
            "$(audit_json --arg plugin "${plugin}" --arg version "${version}" --arg target "${target_ref}" \
                '{plugin:$plugin,version:$version,target:$target}')"
        exit 0
        ;;

    approve)
        plugin="${1:-}"
        version="${2:-}"
        decision="${3:-}"
        if [[ -z "${plugin}" || -z "${version}" || -z "${decision}" ]]; then
            bail 2 "approve" "missing plugin/version/decision positional args"
        fi
        case "${decision}" in
            approve|reject) ;;
            *) bail 2 "approve" "invalid decision: ${decision}" ;;
        esac
        audit_log "approve" "true" \
            "$(audit_json --arg plugin "${plugin}" --arg version "${version}" --arg decision "${decision}" \
                '{plugin:$plugin,version:$version,decision:$decision}')"
        exit 0
        ;;

    curate)
        plugin="${1:-}"
        action="${2:-}"
        if [[ -z "${plugin}" || -z "${action}" ]]; then
            bail 2 "curate" "missing plugin/action positional args"
        fi
        case "${action}" in
            feature|deprecate|remove) ;;
            *) bail 2 "curate" "invalid action: ${action}" ;;
        esac
        work="$(mktemp -d)"
        trap 'rm -rf "${work}"' EXIT
        cd "${work}"
        git clone --quiet "${BARE_REPO}" repo \
            || bail 1 "curate" "git clone bare failed"
        cd repo
        jq --arg p "${plugin}" --arg a "${action}" \
            '.metadata = (.metadata // {}) | .metadata.curate = (.metadata.curate // {}) | .metadata.curate[$p] = $a' \
            .claude-plugin/marketplace.json > .claude-plugin/marketplace.json.tmp \
            || bail 1 "curate" "jq mutation failed"
        mv .claude-plugin/marketplace.json.tmp .claude-plugin/marketplace.json
        git add .claude-plugin/marketplace.json
        if git diff --cached --quiet; then
            audit_log "curate" "true" \
                "$(audit_json --arg plugin "${plugin}" --arg action "${action}" \
                    '{plugin:$plugin,action:$action,noop:true}')"
            exit 0
        fi
        git -c user.email="${GIT_AUTHOR_EMAIL}" -c user.name="${GIT_AUTHOR_NAME}" \
            commit --quiet -m "Curate ${plugin}: ${action} (audit ${AUDIT_ID})" \
            || bail 1 "curate" "git commit failed"
        git push --quiet origin HEAD:main \
            || bail 1 "curate" "git push failed"
        audit_log "curate" "true" \
            "$(audit_json --arg plugin "${plugin}" --arg action "${action}" \
                '{plugin:$plugin,action:$action}')"
        exit 0
        ;;

    rerender)
        if [[ ! -f "${RENDER_TRIGGER_FILE}" ]]; then
            bail 1 "rerender" "render trigger file missing: ${RENDER_TRIGGER_FILE}"
        fi
        touch -c "${RENDER_TRIGGER_FILE}" \
            || bail 1 "rerender" "touch packed-refs failed"
        audit_log "rerender" "true"
        exit 0
        ;;

    *)
        audit_log "${verb:-empty}" "false" "$(audit_json '{err:"forbidden verb"}')"
        printf 'forbidden\n' >&2
        exit 2
        ;;
esac
