#!/usr/bin/env bash
# =============================================================================
# validate-marketplace-schema.sh
#
# Validate a marketplace.json file against the Anthropic plugin-marketplaces
# protocol fragment used by bifrost-internal (spec.md section 4.1, C1+C2+C3
# closed).
#
# Usage:
#   scripts/validate-marketplace-schema.sh <path-to-marketplace.json>
#
# Exit codes:
#   0 - schema OK
#   1 - schema violation (reason printed to stderr)
#   2 - usage error / file missing
#   3 - jq unavailable and pure-bash fallback insufficient
# =============================================================================
set -euo pipefail

LOG_PREFIX="[validate-marketplace]"
err() { echo "${LOG_PREFIX} ERROR: $*" >&2; }
ok()  { echo "${LOG_PREFIX} OK: $*"; }

if [[ $# -ne 1 ]]; then
    err "usage: $0 <path-to-marketplace.json>"
    exit 2
fi

target="$1"
if [[ ! -f "$target" ]]; then
    err "file not found: $target"
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    err "jq is required for schema validation (install jq or run with --pure-bash; --pure-bash NYI)"
    exit 3
fi

# 1. file must parse as JSON
if ! jq empty "$target" >/dev/null 2>&1; then
    err "not valid JSON: $target"
    exit 1
fi

# 2. top-level required keys
for key in name owner plugins; do
    if ! jq -e "has(\"${key}\")" "$target" >/dev/null; then
        err "missing top-level key: ${key}"
        exit 1
    fi
done

# 3. owner is object with name + email
if [[ "$(jq -r '.owner | type' "$target")" != "object" ]]; then
    err "owner must be an object (got $(jq -r '.owner | type' "$target")) - spec.md C2"
    exit 1
fi
for sub in name email; do
    if ! jq -e ".owner | has(\"${sub}\")" "$target" >/dev/null; then
        err "owner.${sub} missing"
        exit 1
    fi
done

# 4. plugins is array, non-empty (PR-1 always has the sample plugin)
if [[ "$(jq -r '.plugins | type' "$target")" != "array" ]]; then
    err "plugins must be an array"
    exit 1
fi
plugin_count="$(jq -r '.plugins | length' "$target")"
if [[ "$plugin_count" -lt 1 ]]; then
    err "plugins[] is empty - PR-1 must seed at least hello-world-skill"
    exit 1
fi

# 5. per-plugin: name + source; source either a string OR an object with a
#    'source' discriminator (NOT 'type' - spec.md C2)
i=0
while [[ "$i" -lt "$plugin_count" ]]; do
    p="$(jq -c ".plugins[$i]" "$target")"
    if ! echo "$p" | jq -e 'has("name")' >/dev/null; then
        err "plugins[$i].name missing"
        exit 1
    fi
    if ! echo "$p" | jq -e 'has("source")' >/dev/null; then
        err "plugins[$i].source missing (name=$(echo "$p" | jq -r '.name'))"
        exit 1
    fi
    src_type="$(echo "$p" | jq -r '.source | type')"
    case "$src_type" in
        string)
            src_val="$(echo "$p" | jq -r '.source')"
            # accepted: relative path ./..., bare-relative path without ./, owner/repo on GitHub
            # explicitly REJECT git+https://... (spec.md C3)
            if [[ "$src_val" =~ ^git\+ ]]; then
                err "plugins[$i].source rejects git+ URL prefix (spec.md C3): $src_val"
                exit 1
            fi
            ;;
        object)
            # discriminator key MUST be 'source' (spec.md C2 - not 'type')
            if echo "$p" | jq -e '.source | has("type")' >/dev/null; then
                err "plugins[$i].source uses key 'type' as discriminator - must be 'source' (spec.md C2)"
                exit 1
            fi
            if ! echo "$p" | jq -e '.source | has("source")' >/dev/null; then
                err "plugins[$i].source object missing 'source' discriminator key"
                exit 1
            fi
            disc="$(echo "$p" | jq -r '.source.source')"
            case "$disc" in
                git-subdir)
                    for k in url subdir; do
                        if ! echo "$p" | jq -e ".source | has(\"${k}\")" >/dev/null; then
                            err "plugins[$i].source (git-subdir) missing key: ${k}"
                            exit 1
                        fi
                    done
                    url_val="$(echo "$p" | jq -r '.source.url')"
                    if [[ "$url_val" =~ ^git\+ ]]; then
                        err "plugins[$i].source.url rejects git+ URL prefix (spec.md C3): $url_val"
                        exit 1
                    fi
                    ;;
                github)
                    if ! echo "$p" | jq -e '.source | has("repo")' >/dev/null; then
                        err "plugins[$i].source (github) missing key: repo"
                        exit 1
                    fi
                    ;;
                url)
                    if ! echo "$p" | jq -e '.source | has("url")' >/dev/null; then
                        err "plugins[$i].source (url) missing key: url"
                        exit 1
                    fi
                    url_val="$(echo "$p" | jq -r '.source.url')"
                    if [[ "$url_val" =~ ^git\+ ]]; then
                        err "plugins[$i].source.url rejects git+ URL prefix (spec.md C3): $url_val"
                        exit 1
                    fi
                    ;;
                npm)
                    if ! echo "$p" | jq -e '.source | has("package")' >/dev/null; then
                        err "plugins[$i].source (npm) missing key: package"
                        exit 1
                    fi
                    ;;
                *)
                    err "plugins[$i].source.source unknown discriminator: ${disc}"
                    exit 1
                    ;;
            esac
            ;;
        *)
            err "plugins[$i].source must be string or object (got ${src_type})"
            exit 1
            ;;
    esac
    i=$((i + 1))
done

# 6. forbidden fields anywhere under plugins[] - tarball_url / tarball_sha256
#    were custom in spec v1 and removed by C2 (protocol doesn't consume them
#    for git-subdir sources). They still MAY appear under metadata.* but never
#    at the top of a plugin entry.
if jq -e '.plugins[] | has("tarball_url") or has("tarball_sha256")' "$target" >/dev/null 2>&1; then
    err "plugins[] entries contain top-level tarball_url/tarball_sha256 (spec.md C2)"
    exit 1
fi

ok "$target conforms to spec.md section 4.1 (name=$(jq -r .name "$target"), plugins=$plugin_count)"
exit 0
