#!/usr/bin/env bash
# =============================================================================
# tests/test-render-marketplace.sh
#
# Standalone E2E test for scripts/render-marketplace-json.sh.
# Does NOT depend on docker - all it needs is git + bash + jq + python3.
#
# What it tests (all real assertions; nothing tautological):
#   1. Render against a real fake bare repo seeded with the checked-in seed
#      material at prompts/0519-1/marketplace-bootstrap/bifrost-internal-plugins/
#   2. Render exits 0
#   3. Bare repo received a new commit on main containing .claude-plugin/marketplace.json
#   4. The rendered JSON passes scripts/validate-marketplace-schema.sh (exit 0)
#   5. The rendered JSON's .name == "bifrost-internal" and .owner.name/.email exist
#   6. The rendered JSON's .plugins[0].source == "./plugins/hello-world-skill"
#      and .plugins[0].version == "0.1.0" (matching the tag we created)
#   7. The rendered JSON's .metadata.git_head_sha == the tag's commit SHA
#      (deterministic source provenance)
#   8. Second invocation is an idempotent no-op (bare HEAD unchanged)
#   9. Negative: a manifest.yaml whose version disagrees with the git tag
#      causes render to exit 3 (spec.md section 6.2 enforced)
#
# Exit:
#   0 if all checks pass, 1 otherwise (PASS / FAIL counts printed).
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEED_DIR="${SCRIPT_DIR}/prompts/0519-1/marketplace-bootstrap/bifrost-internal-plugins"
RENDER_SCRIPT="${SCRIPT_DIR}/scripts/render-marketplace-json.sh"
VALIDATE_SCRIPT="${SCRIPT_DIR}/scripts/validate-marketplace-schema.sh"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT+1)); printf '%b[PASS]%b %s\n' "$GREEN" "$NC" "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT+1)); printf '%b[FAIL]%b %s\n' "$RED" "$NC" "$*"; }
info() { printf '%b[TEST]%b %s\n' "$YELLOW" "$NC" "$*"; }

# Hard prerequisites: if any tool is missing, fail loudly (do NOT skip).
for bin in git jq python3 bash mktemp; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        fail "prerequisite missing: $bin"
    fi
done
for f in "$RENDER_SCRIPT" "$VALIDATE_SCRIPT" "$SEED_DIR/.claude-plugin/marketplace.json"; do
    if [[ ! -e "$f" ]]; then
        fail "required input missing: $f"
    fi
done
if [[ $FAIL_COUNT -gt 0 ]]; then
    echo "Cannot proceed; prerequisite checks failed."
    exit 1
fi

# All temp dirs go under one root for clean teardown.
TMPROOT="$(mktemp -d -t test-render-marketplace.XXXXXX)"
cleanup() {
    rm -rf "$TMPROOT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Helper: seed a fresh bare + tagged worktree.
seed_bare() {
    local out_bare="$1"
    local wt
    wt="$(mktemp -d -p "$TMPROOT" wt.XXXXXX)"
    git init --bare --initial-branch=main "$out_bare" >/dev/null 2>&1
    git clone --quiet "$out_bare" "$wt" 2>/dev/null
    cp -r "$SEED_DIR/." "$wt/"
    rm -f "$wt/.claude-plugin/marketplace.json"
    (
        cd "$wt"
        git config user.name test-render
        git config user.email render@test.local
        git add . >/dev/null 2>&1
        git commit --quiet -m "seed"
        git tag -a plugins/hello-world-skill/v0.1.0 -m "v0.1.0" >/dev/null
        git push --quiet origin main --tags >/dev/null 2>&1
    )
    rm -rf "$wt"
}

# === Test 1: render produces a valid marketplace.json on the bare ===
info "Case 1: render against fresh bare with one tag"
BARE1="$TMPROOT/bare1.git"
seed_bare "$BARE1"
TAG_SHA="$(git -C "$BARE1" rev-parse "plugins/hello-world-skill/v0.1.0^{commit}" 2>/dev/null || true)"
if [[ -z "$TAG_SHA" ]]; then
    fail "could not resolve tag commit SHA on bare1"
else
    pass "seeded bare1 with tag commit SHA $TAG_SHA"
fi

RENDER_OUT="$TMPROOT/render1.log"
if RENDER_TIMESTAMP=2026-05-20T12:00:00+00:00 \
   bash "$RENDER_SCRIPT" bifrost-internal-plugins "$BARE1" >"$RENDER_OUT" 2>&1; then
    pass "render exited 0"
else
    fail "render exited non-zero (log: $RENDER_OUT)"
    cat "$RENDER_OUT" >&2
fi

VERIFY1="$TMPROOT/verify1"
git clone --quiet "$BARE1" "$VERIFY1" 2>/dev/null
RENDERED_JSON="$VERIFY1/.claude-plugin/marketplace.json"

if [[ -f "$RENDERED_JSON" ]]; then
    pass "bare has .claude-plugin/marketplace.json after render"
else
    fail "bare missing .claude-plugin/marketplace.json"
fi

if bash "$VALIDATE_SCRIPT" "$RENDERED_JSON" >/dev/null 2>&1; then
    pass "rendered JSON passes validate-marketplace-schema.sh"
else
    fail "rendered JSON failed schema validator (run: bash $VALIDATE_SCRIPT $RENDERED_JSON)"
fi

J_NAME="$(jq -r '.name' "$RENDERED_JSON" 2>/dev/null)"
[[ "$J_NAME" == "bifrost-internal" ]] && pass ".name == bifrost-internal" || fail ".name was '$J_NAME' (expected bifrost-internal)"

J_OWNER_TYPE="$(jq -r '.owner | type' "$RENDERED_JSON" 2>/dev/null)"
[[ "$J_OWNER_TYPE" == "object" ]] && pass ".owner is an object (spec.md C2)" || fail ".owner is '$J_OWNER_TYPE' (expected object)"

J_OWNER_EMAIL="$(jq -r '.owner.email' "$RENDERED_JSON" 2>/dev/null)"
[[ "$J_OWNER_EMAIL" == "bifrost-admin@uuhfn.cloud" ]] && pass ".owner.email correct" || fail ".owner.email was '$J_OWNER_EMAIL'"

J_PLUGIN_COUNT="$(jq -r '.plugins | length' "$RENDERED_JSON" 2>/dev/null)"
[[ "$J_PLUGIN_COUNT" == "1" ]] && pass ".plugins has 1 entry" || fail ".plugins has $J_PLUGIN_COUNT entries (expected 1)"

J_PLUGIN_SRC="$(jq -r '.plugins[0].source' "$RENDERED_JSON" 2>/dev/null)"
[[ "$J_PLUGIN_SRC" == "./plugins/hello-world-skill" ]] && pass ".plugins[0].source uses relative path (spec.md 4.1)" || fail ".plugins[0].source was '$J_PLUGIN_SRC'"

J_PLUGIN_VER="$(jq -r '.plugins[0].version' "$RENDERED_JSON" 2>/dev/null)"
[[ "$J_PLUGIN_VER" == "0.1.0" ]] && pass ".plugins[0].version == 0.1.0 (matches tag)" || fail ".plugins[0].version was '$J_PLUGIN_VER'"

J_PLUGIN_TAG="$(jq -r '.plugins[0].metadata.tag' "$RENDERED_JSON" 2>/dev/null)"
[[ "$J_PLUGIN_TAG" == "plugins/hello-world-skill/v0.1.0" ]] && pass ".plugins[0].metadata.tag set correctly" || fail ".plugins[0].metadata.tag was '$J_PLUGIN_TAG'"

J_SOURCE_PROVENANCE="$(jq -r '.metadata.git_head_sha' "$RENDERED_JSON" 2>/dev/null)"
if [[ "$J_SOURCE_PROVENANCE" == "$TAG_SHA" ]]; then
    pass ".metadata.git_head_sha == tag commit SHA (deterministic source provenance)"
else
    fail ".metadata.git_head_sha was '$J_SOURCE_PROVENANCE' (expected $TAG_SHA)"
fi

if jq -e '.plugins[] | has("tarball_url") or has("tarball_sha256")' "$RENDERED_JSON" >/dev/null 2>&1; then
    fail "rendered JSON has forbidden tarball_url/tarball_sha256 (spec.md C2)"
else
    pass "rendered JSON has no forbidden tarball_* fields"
fi

if jq -r '.plugins[].source | tostring' "$RENDERED_JSON" 2>/dev/null | grep -q '^git+'; then
    fail "rendered JSON contains git+ URL prefix (spec.md C3)"
else
    pass "rendered JSON has no git+ URL prefix"
fi

# === Test 2: idempotency ===
info "Case 2: second invocation against unchanged bare should be no-op"
SHA_BEFORE="$(git -C "$BARE1" rev-parse main)"
RENDER_OUT2="$TMPROOT/render2.log"
if RENDER_TIMESTAMP=2026-05-20T12:00:00+00:00 \
   bash "$RENDER_SCRIPT" bifrost-internal-plugins "$BARE1" >"$RENDER_OUT2" 2>&1; then
    pass "second render exited 0"
else
    fail "second render exited non-zero"
fi
SHA_AFTER="$(git -C "$BARE1" rev-parse main)"
if [[ "$SHA_BEFORE" == "$SHA_AFTER" ]]; then
    pass "bare main unchanged after second render (idempotent)"
else
    fail "bare main changed: $SHA_BEFORE -> $SHA_AFTER (spec.md 4.2 step 6 violated)"
fi
if grep -q "no diff; skipping commit" "$RENDER_OUT2"; then
    pass "render logged 'no diff' on second invocation"
else
    fail "render did not log 'no diff' on idempotent invocation (log: $RENDER_OUT2)"
fi

# === Test 3: negative - manifest version mismatch must exit 3 ===
info "Case 3: manifest.yaml version != git tag should exit 3"
BARE3="$TMPROOT/bare3.git"
WT3="$TMPROOT/wt3"
git init --bare --initial-branch=main "$BARE3" >/dev/null 2>&1
git clone --quiet "$BARE3" "$WT3" 2>/dev/null
cp -r "$SEED_DIR/." "$WT3/"
rm -f "$WT3/.claude-plugin/marketplace.json"
(
    cd "$WT3"
    git config user.name test-render
    git config user.email render@test.local
    git add . >/dev/null 2>&1
    git commit --quiet -m "seed-mismatch"
    # Tag claims v0.2.5 but manifest stays at 0.1.0
    git tag -a plugins/hello-world-skill/v0.2.5 -m "v0.2.5" >/dev/null
    git push --quiet origin main --tags >/dev/null 2>&1
)
NEG_OUT="$TMPROOT/render-neg.log"
bash "$RENDER_SCRIPT" bifrost-internal-plugins "$BARE3" >"$NEG_OUT" 2>&1
NEG_RC=$?
if [[ "$NEG_RC" == "3" ]]; then
    pass "version-mismatch render exited 3 (spec.md 6.2 enforced)"
else
    fail "version-mismatch render exited $NEG_RC (expected 3); log: $(tr '\n' ' ' <"$NEG_OUT" | head -c 200)"
fi
WT3_VERIFY="$TMPROOT/wt3-verify"
git clone --quiet "$BARE3" "$WT3_VERIFY" 2>/dev/null
if [[ ! -f "$WT3_VERIFY/.claude-plugin/marketplace.json" ]]; then
    pass "bare untouched on negative case (no marketplace.json leaked through)"
else
    fail "bare was modified despite render failure (spec.md 4.2 atomicity violated)"
fi

# === Test 4: usage error ===
info "Case 4: render with wrong arg count should exit 2"
bash "$RENDER_SCRIPT" only-one-arg >/dev/null 2>&1
RC4=$?
[[ "$RC4" == "2" ]] && pass "wrong arg count exit 2" || fail "wrong arg count exit $RC4 (expected 2)"

# === Summary ===
echo
echo "================================================"
echo "  test-render-marketplace: $PASS_COUNT pass, $FAIL_COUNT fail"
echo "================================================"
if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
exit 0
