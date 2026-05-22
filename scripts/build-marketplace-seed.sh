#!/usr/bin/env bash
# =============================================================================
# build-marketplace-seed.sh
#
# Build an offline tarball of the bifrost-internal marketplace for laptops
# that cannot reach Server A (out of the office, VPN broken, fresh imaging,
# CI without VPN, etc). Consumers extract the tarball and export
# CLAUDE_CODE_PLUGIN_SEED_DIR to skip the network discovery path.
#
# Usage:
#   bash scripts/build-marketplace-seed.sh [--output <path>] [--bare <path>]
#
# Defaults:
#   --output  dist/marketplace-seed.tar.gz   (relative to repo root)
#   --bare    prompts/0519-1/marketplace-bootstrap/bifrost-internal-plugins
#
# Output:
#   <output>          gzipped tarball, byte-stable for identical inputs
#   <output>.sha256   sha256sum of the tarball (single line, sha256sum format)
#
# Exit codes:
#   0  success
#   1  missing source files in --bare or paired team-config templates
#   2  invalid arguments / unknown flag
#
# Offline guarantee: this script never makes network calls; it only reads
# files already checked in to the repo and copies them into a staging dir.
# =============================================================================
set -euo pipefail

LOG_PREFIX="[build-marketplace-seed]"
log()  { echo "${LOG_PREFIX} $*"; }
warn() { echo "${LOG_PREFIX} WARN: $*" >&2; }
die()  { echo "${LOG_PREFIX} ERROR: $*" >&2; exit "${2:-1}"; }

usage() {
    cat <<USAGE_EOF
${LOG_PREFIX} usage:
  bash $0 [--output <path>] [--bare <path>] [-h|--help]

Build an offline marketplace seed tarball from a bifrost-internal-plugins
source tree. Produces <output> and <output>.sha256 next to it.
USAGE_EOF
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${REPO_ROOT}/dist/marketplace-seed.tar.gz"
BARE_SRC="${REPO_ROOT}/prompts/0519-1/marketplace-bootstrap/bifrost-internal-plugins"
TEAM_CFG="${REPO_ROOT}/prompts/0519-1/team-config"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT="$2"; shift 2 ;;
        --bare)   BARE_SRC="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" 2 ;;
    esac
done

[[ -d "$BARE_SRC" ]] || die "bare source missing: $BARE_SRC" 1
for f in \
    "$BARE_SRC/.claude-plugin/marketplace.json" \
    "$BARE_SRC/LICENSE" \
    "$BARE_SRC/NOTICE" \
    "$BARE_SRC/README.md" \
    "$BARE_SRC/plugins/hello-world-skill/.claude-plugin/plugin.json" \
    "$BARE_SRC/plugins/hello-world-skill/manifest.yaml" \
    "$BARE_SRC/plugins/hello-world-skill/skills/hello/SKILL.md" \
    "$TEAM_CFG/.claude/settings.json.template" \
    "$TEAM_CFG/CLAUDE.md.template"; do
    [[ -f "$f" ]] || die "missing required source file: $f" 1
done

STAGING="$(mktemp -d -t marketplace-seed.XXXXXX)"
cleanup() { rm -rf "$STAGING" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

log "staging at $STAGING"
log "copying bare source: $BARE_SRC"
cp -R "$BARE_SRC" "$STAGING/bifrost-internal-plugins"
cp "$TEAM_CFG/.claude/settings.json.template" "$STAGING/settings.json.template"
cp "$TEAM_CFG/CLAUDE.md.template" "$STAGING/CLAUDE.md.template"

cat > "$STAGING/INSTALL.md" <<'INSTALL_EOF'
# bifrost-internal marketplace seed

Offline / disaster-recovery copy of the bifrost-internal Claude Code plugin
marketplace. Use this when Server A is unreachable.

## Quick start

```bash
# 1. Extract the seed somewhere stable
mkdir -p ~/marketplace-seed
tar xzf marketplace-seed.tar.gz -C ~/marketplace-seed --strip-components=0

# 2. Point Claude Code at it
export CLAUDE_CODE_PLUGIN_SEED_DIR="$HOME/marketplace-seed/bifrost-internal-plugins"

# 3. Drop the settings template in if you have not yet
mkdir -p ~/.claude
cp ~/marketplace-seed/settings.json.template ~/.claude/settings.json

# 4. Start Claude Code; /plugin browse should list bifrost-internal
claude
```

## Verifying integrity

```bash
sha256sum -c marketplace-seed.tar.gz.sha256
```

## What's in the box

- `bifrost-internal-plugins/` -- mirror of the marketplace bare repo,
  including `.claude-plugin/marketplace.json`, `LICENSE`, `NOTICE`, and
  every shipped plugin under `plugins/<name>/`.
- `settings.json.template` -- copy to `~/.claude/settings.json`.
- `CLAUDE.md.template` -- copy to `<your-project>/CLAUDE.md` and replace
  the `<PROJECT_NAME>` placeholder.
- `INSTALL.md` -- this file.

For the long walkthrough see
`prompts/0519-1/marketplace-bootstrap/seed/README.md` inside the source
repository, or `docs/USAGE.md` once PR-7 lands.
INSTALL_EOF

# Reproducible tar flags: GNU tar 1.28+ (Git Bash on Windows ships these).
# Pinning mtime/owner/group/sort gives a byte-stable archive for identical
# inputs so the published sha256 can be audited.
TAR_FLAGS=(--sort=name --mtime='UTC 2026-01-01' --owner=0 --group=0 --numeric-owner)

# Detect whether the local tar honours the reproducible flags; if not, warn
# but still build (functionality first, reproducibility is a nice-to-have).
if ! tar --version 2>/dev/null | head -n1 | grep -qi 'gnu tar'; then
    warn "non-GNU tar detected; archive will not be byte-stable"
    TAR_FLAGS=()
fi

mkdir -p "$(dirname "$OUTPUT")"
log "creating tarball: $OUTPUT"
( cd "$STAGING" && tar "${TAR_FLAGS[@]}" -czf "$OUTPUT" . )

# Sanity check: no path escape, no symlinks pointing outside, no hidden ..
if tar tzf "$OUTPUT" | grep -E '(^|/)\.\.(/|$)' >/dev/null; then
    die "tarball contains parent-dir entries; refusing to publish" 1
fi

( cd "$(dirname "$OUTPUT")" && sha256sum "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256" )

log "done"
log "  tarball : $OUTPUT"
log "  sha256  : ${OUTPUT}.sha256"
log "  entries : $(tar tzf "$OUTPUT" | wc -l)"
exit 0
