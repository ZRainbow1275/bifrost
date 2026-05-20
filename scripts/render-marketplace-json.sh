#!/usr/bin/env bash
# =============================================================================
# render-marketplace-json.sh
#
# Render .claude-plugin/marketplace.json into the bifrost-internal-plugins
# bare git repo, by:
#   1. clone bare -> temp worktree
#   2. enumerate annotated tags of the form plugins/<name>/v<X.Y.Z>
#   3. verify each tag's plugins/<name>/.claude-plugin/plugin.json version
#      matches the tag semver, and that manifest.yaml is well-formed
#   4. emit .claude-plugin/marketplace.json per spec.md section 4.1
#   5. emit LICENSE / NOTICE per spec.md section 5.3
#   6. commit + push back to bare (skips if no diff = idempotent)
#   7. on production: also write /var/lib/dist/plugins/state.json and copy
#      LICENSE.md / NOTICE.md as emergency sidecar (skipped if dir missing)
#
# Usage:
#   render-marketplace-json.sh <repo-slug> <bare-path>
#
# Environment overrides (test hooks):
#   DIST_PLUGINS_DIR     - override /var/lib/dist/plugins
#   RENDER_TIMESTAMP     - override $(date -Iseconds) for byte-stable testing
#   RENDER_SCRIPT_VERSION - override v1.0.0
#
# Exit codes (spec.md section 4.2):
#   0 - success (including no-op when there is no diff)
#   2 - usage error
#   3 - schema / version mismatch
#   4 - git operation failed
#   5 - manifest.yaml validation failed
# =============================================================================
set -euo pipefail

LOG_PREFIX="[render-marketplace]"
log()  { echo "${LOG_PREFIX} $*"; }
warn() { echo "${LOG_PREFIX} WARN: $*" >&2; }
die()  { echo "${LOG_PREFIX} ERROR: $*" >&2; exit "${2:-1}"; }

if [[ $# -ne 2 ]]; then
    die "usage: $0 <repo-slug> <bare-path>" 2
fi
REPO_SLUG="$1"
BARE_PATH="$2"

if [[ ! -d "$BARE_PATH" ]]; then
    die "bare path does not exist: $BARE_PATH" 4
fi
if [[ ! -f "$BARE_PATH/HEAD" ]]; then
    die "not a git repository (no HEAD): $BARE_PATH" 4
fi

RENDER_TIMESTAMP="${RENDER_TIMESTAMP:-$(date -Iseconds)}"
RENDER_SCRIPT_VERSION="${RENDER_SCRIPT_VERSION:-v1.0.0}"
DIST_PLUGINS_DIR="${DIST_PLUGINS_DIR:-/var/lib/dist/plugins}"

WORK="$(mktemp -d -t render-marketplace.XXXXXX)"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

log "render starting: repo=$REPO_SLUG bare=$BARE_PATH work=$WORK"

if ! git clone --quiet "$BARE_PATH" "$WORK" 2>"$WORK.cloneerr"; then
    warn "clone error: $(cat "$WORK.cloneerr" 2>/dev/null)"
    die "git clone bare -> worktree failed" 4
fi
rm -f "$WORK.cloneerr"

cd "$WORK"

DEFAULT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
log "default branch: $DEFAULT_BRANCH"

# --- helpers ---

_extract_yaml_scalar() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || { echo ""; return; }
    local line
    line="$(grep -E "^${key}:" "$file" | head -n1 || true)"
    [[ -z "$line" ]] && { echo ""; return; }
    line="${line#${key}:}"
    line="${line# }"
    line="${line%$'\r'}"
    if [[ "$line" =~ ^\"(.*)\"$ ]]; then
        line="${BASH_REMATCH[1]}"
    fi
    echo "$line"
}

# Convert newline-separated lines into a compact JSON array. Always emits "[]" for empty input.
_lines_to_json_array() {
    local lines="$1"
    if [[ -z "$lines" ]]; then
        echo "[]"
        return
    fi
    printf '%s
' "$lines" | grep -v '^$' | jq -R . | jq -sc .
}

_extract_yaml_list_under() {
    local file="$1" parent="$2" key="$3"
    [[ -f "$file" ]] || return
    python3 - "$file" "$parent" "$key" <<'PYEOF' 2>/dev/null || true
import sys, re
path, parent, key = sys.argv[1], sys.argv[2], sys.argv[3]
in_parent = False
in_key = False
for raw in open(path, encoding="utf-8", errors="replace"):
    line = raw.rstrip("\n").rstrip("\r")
    if re.match(r"^[A-Za-z_]", line):
        in_parent = line.startswith(parent + ":")
        in_key = False
        continue
    if in_parent and re.match(r"^  [A-Za-z_]", line):
        in_key = line.startswith("  " + key + ":")
        continue
    if in_parent and in_key:
        m = re.match(r"^    -\s*(.*)$", line)
        if m:
            val = m.group(1).strip()
            if val[:1] == val[-1:] and val[:1] in ('"',):
                val = val[1:-1]
            print(val)
PYEOF
}

# --- enumerate plugin tags (latest semver per plugin name) ---
declare -A PLUGIN_LATEST_TAG=()
declare -A PLUGIN_LATEST_VER=()

declare -a ALL_TAGS=()
while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    ALL_TAGS+=("$tag")
done < <(git tag --list 'plugins/*/v*' || true)

declare -A SEEN_PLUGINS=()
if [[ ${#ALL_TAGS[@]} -gt 0 ]]; then
    for tag in "${ALL_TAGS[@]}"; do
        if [[ ! "$tag" =~ ^plugins/([A-Za-z0-9._-]+)/v([0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?)$ ]]; then
            warn "ignoring malformed tag: $tag"
            continue
        fi
        pname="${BASH_REMATCH[1]}"
        SEEN_PLUGINS["$pname"]=1
    done
fi

for pname in "${!SEEN_PLUGINS[@]}"; do
    latest_tag="$(printf '%s\n' "${ALL_TAGS[@]}" | grep -E "^plugins/${pname}/v[0-9]" | sort -V | tail -n1)"
    [[ -z "$latest_tag" ]] && continue
    pver="${latest_tag##plugins/${pname}/v}"
    PLUGIN_LATEST_TAG["$pname"]="$latest_tag"
    PLUGIN_LATEST_VER["$pname"]="$pver"
done

if [[ ${#PLUGIN_LATEST_TAG[@]} -eq 0 ]]; then
    if [[ -d "plugins" ]]; then
        log "no tags found; using HEAD plugins/* with manifest.yaml versions"
        for pdir in plugins/*/; do
            [[ -d "$pdir" ]] || continue
            pname="$(basename "$pdir")"
            ver_from_manifest="$(_extract_yaml_scalar "${pdir}manifest.yaml" version)"
            if [[ -z "$ver_from_manifest" ]]; then
                warn "skipping $pname: cannot read manifest.yaml version"
                continue
            fi
            PLUGIN_LATEST_TAG["$pname"]=""
            PLUGIN_LATEST_VER["$pname"]="$ver_from_manifest"
        done
    fi
fi

# --- validate each plugin (version match across tag / manifest / plugin.json) ---
for pname in "${!PLUGIN_LATEST_VER[@]}"; do
    pver="${PLUGIN_LATEST_VER[$pname]}"
    ptag="${PLUGIN_LATEST_TAG[$pname]}"
    pdir="plugins/${pname}"

    if [[ -n "$ptag" ]]; then
        if ! git checkout --quiet "$ptag" -- "$pdir"; then
            die "git checkout failed for tag $ptag" 4
        fi
    fi

    manifest="${pdir}/manifest.yaml"
    plugin_json="${pdir}/.claude-plugin/plugin.json"

    if [[ ! -f "$manifest" ]]; then
        die "missing $manifest" 5
    fi
    if [[ ! -f "$plugin_json" ]]; then
        die "missing $plugin_json" 5
    fi

    manifest_ver="$(_extract_yaml_scalar "$manifest" version)"
    if [[ -z "$manifest_ver" ]]; then
        die "cannot read version from $manifest" 5
    fi
    if [[ "$manifest_ver" != "$pver" ]]; then
        die "version mismatch: tag/HEAD=$pver manifest.yaml=$manifest_ver (spec.md section 6.2)" 3
    fi

    pj_ver="$(jq -r '.version // empty' "$plugin_json" 2>/dev/null || true)"
    if [[ -z "$pj_ver" ]]; then
        die "cannot read .version from $plugin_json" 5
    fi
    if [[ "$pj_ver" != "$pver" ]]; then
        die "version mismatch: tag/HEAD=$pver plugin.json=$pj_ver (spec.md section 6.2)" 3
    fi

    log "validated plugin: $pname v$pver"
done

git checkout --quiet "$DEFAULT_BRANCH" -- . 2>/dev/null || true

# --- render marketplace.json ---
# git_head_sha encodes the *source* revision the render is based on so that
# repeated renders against unchanged source produce byte-identical JSON
# (idempotency, spec.md section 4.2 step 6). We pick the SHA of the latest
# plugin tag if any exists, otherwise fall back to the earliest commit that
# touched plugins/ (which is stable across re-renders).
GIT_HEAD_SHA=""
if [[ ${#PLUGIN_LATEST_TAG[@]} -gt 0 ]]; then
    max_tag="$(printf '%s
' "${PLUGIN_LATEST_TAG[@]}" | grep -v '^$' | sort | tail -n1)"
    if [[ -n "$max_tag" ]]; then
        GIT_HEAD_SHA="$(git rev-parse "${max_tag}^{commit}" 2>/dev/null || true)"
    fi
fi
if [[ -z "$GIT_HEAD_SHA" ]]; then
    GIT_HEAD_SHA="$(git log --format=%H -- plugins/ 2>/dev/null | tail -n1)"
fi
if [[ -z "$GIT_HEAD_SHA" ]]; then
    GIT_HEAD_SHA="0000000000000000000000000000000000000000"
fi

mkdir -p .claude-plugin

plugins_tmp="$(mktemp)"
sorted_names="$(printf '%s\n' "${!PLUGIN_LATEST_VER[@]}" | sort)"

{
    echo "["
    first=1
    for pname in $sorted_names; do
        pver="${PLUGIN_LATEST_VER[$pname]}"
        ptag="${PLUGIN_LATEST_TAG[$pname]}"
        manifest="plugins/${pname}/manifest.yaml"
        description="$(_extract_yaml_scalar "$manifest" description)"
        license_id="$(_extract_yaml_scalar "$manifest" license_id)"
        [[ -z "$license_id" ]] && license_id="ALL-RIGHTS-RESERVED"

        skills_lines="$(_extract_yaml_list_under "$manifest" permissions declared_skills | sort -u)"
        hooks_lines="$(_extract_yaml_list_under "$manifest" permissions declared_hooks | sort -u)"
        mcp_lines="$(_extract_yaml_list_under "$manifest" permissions declared_mcp_servers | sort -u)"

        skills_json="$(_lines_to_json_array "$skills_lines")"
        hooks_json="$(_lines_to_json_array "$hooks_lines")"
        mcp_json="$(_lines_to_json_array "$mcp_lines")"

        [[ $first -eq 0 ]] && echo ","
        first=0

        jq -nc \
            --arg name "$pname" \
            --arg source "./plugins/${pname}" \
            --arg desc "$description" \
            --arg ver "$pver" \
            --arg license "$license_id" \
            --arg tag "$ptag" \
            --argjson skills "$skills_json" \
            --argjson hooks "$hooks_json" \
            --argjson mcp "$mcp_json" \
            '{
                name: $name,
                source: $source,
                description: $desc,
                version: $ver,
                author: { name: "Bifrost Team", email: "bifrost-admin@uuhfn.cloud" },
                license: $license,
                keywords: ["internal"],
                strict: true,
                metadata: {
                    manifest_version: $ver,
                    license_id: $license,
                    declared_skills: $skills,
                    declared_hooks: $hooks,
                    declared_mcp_servers: $mcp,
                    tag: $tag
                }
            }'
    done
    echo
    echo "]"
} > "$plugins_tmp"

target_json=".claude-plugin/marketplace.json"
jq -n \
    --arg ts "$RENDER_TIMESTAMP" \
    --arg sver "$RENDER_SCRIPT_VERSION" \
    --arg sha "$GIT_HEAD_SHA" \
    --slurpfile plugins "$plugins_tmp" \
    '{
        name: "bifrost-internal",
        owner: { name: "Bifrost Team", email: "bifrost-admin@uuhfn.cloud" },
        description: "Bifrost team internal Claude Code plugin marketplace (team-only distribution, no upstream mirror)",
        version: "1.0.0",
        metadata: {
            pluginRoot: "./plugins",
            license_id: "ALL-RIGHTS-RESERVED",
            upstream_url: null,
            rendered_at: $ts,
            render_script_version: $sver,
            git_head_sha: $sha
        },
        plugins: $plugins[0]
    }' > "${target_json}.tmp"

rm -f "$plugins_tmp"
mv "${target_json}.tmp" "$target_json"

# --- LICENSE / NOTICE per spec.md section 5.3 ---
cat > LICENSE <<'LIC_EOF'
# bifrost-internal Plugin Marketplace
# Copyright (c) 2026 Bifrost Team. All rights reserved.
#
# Each plugin under `plugins/<name>/` may carry its own LICENSE file.
# Default policy: ALL-RIGHTS-RESERVED unless otherwise stated.
# Distribution restricted to authenticated Bifrost team members.
LIC_EOF

cat > NOTICE <<'NOT_EOF'
This marketplace is an internal distribution channel for Bifrost team.
It does NOT mirror anthropic/claude-code or any other proprietary upstream.
Plugin submissions are subject to admin review via panel.uuhfn.cloud
(see docs/SECURITY.md section marketplace).
NOT_EOF

# --- commit + push (idempotent) ---
git -c user.name=marketplace-render -c user.email=render@uuhfn.cloud add .

if git diff --cached --quiet; then
    log "no diff; skipping commit (idempotent no-op)"
else
    commit_msg="render @ ${RENDER_TIMESTAMP}"
    if ! git -c user.name=marketplace-render -c user.email=render@uuhfn.cloud \
            commit --quiet -m "$commit_msg"; then
        die "git commit failed" 4
    fi
    if ! git push --quiet origin "$DEFAULT_BRANCH" 2>"$WORK.pusherr"; then
        warn "push error: $(cat "$WORK.pusherr" 2>/dev/null)"
        die "git push origin $DEFAULT_BRANCH failed (bare untouched at last good ref)" 4
    fi
    rm -f "$WORK.pusherr"
    log "pushed commit to bare: $commit_msg"
fi

# --- production sidecar (skipped if DIST_PLUGINS_DIR absent: tests / pre-deploy) ---
if [[ -d "$DIST_PLUGINS_DIR" ]]; then
    final_sha="$(git rev-parse HEAD)"
    plugin_count="${#PLUGIN_LATEST_VER[@]}"
    state_tmp="$(mktemp)"
    if [[ -f "$DIST_PLUGINS_DIR/state.json" ]]; then
        jq --arg ts "$RENDER_TIMESTAMP" \
           --arg sha "$final_sha" \
           --argjson pc "$plugin_count" \
           --arg sver "$RENDER_SCRIPT_VERSION" \
           '.last_render_ts = $ts
            | .latest_git_head = $sha
            | .plugin_count = $pc
            | .render_script_version = $sver
            | (.upstream_alert //= false)' \
           "$DIST_PLUGINS_DIR/state.json" > "$state_tmp"
    else
        jq -n --arg ts "$RENDER_TIMESTAMP" \
              --arg sha "$final_sha" \
              --argjson pc "$plugin_count" \
              --arg sver "$RENDER_SCRIPT_VERSION" \
              '{
                  last_render_ts: $ts,
                  latest_git_head: $sha,
                  plugin_count: $pc,
                  upstream_alert: false,
                  render_script_version: $sver
              }' > "$state_tmp"
    fi
    mv "$state_tmp" "$DIST_PLUGINS_DIR/state.json"
    cp LICENSE "$DIST_PLUGINS_DIR/LICENSE.md" 2>/dev/null || true
    cp NOTICE  "$DIST_PLUGINS_DIR/NOTICE.md" 2>/dev/null || true
    log "updated sidecar at $DIST_PLUGINS_DIR (state.json + LICENSE.md + NOTICE.md)"
else
    log "sidecar dir $DIST_PLUGINS_DIR absent; skipping (test mode or pre-deploy)"
fi

log "render complete; worktree will be cleaned up by trap"
exit 0
