#!/usr/bin/env bash
set -euo pipefail

SERVER_A="${BIFROST_SERVER_A_HOST:-10.8.0.1}"
SERVER_B="${BIFROST_SERVER_B_HOST:-10.8.0.2}"
DOMAIN="${BIFROST_DOMAIN:-uuhfn.cloud}"
DRY_RUN=1

usage() {
    cat <<'EOF'
Usage:
  scripts/e2e-distribution-rehearsal.sh [--execute]

Environment:
  BIFROST_SERVER_A_HOST  Server A SSH host or wg IP (default: 10.8.0.1)
  BIFROST_SERVER_B_HOST  Server B SSH host or wg IP (default: 10.8.0.2)
  BIFROST_DOMAIN         Public domain (default: uuhfn.cloud)

Default mode is dry-run. Use --execute only during a scheduled cutover window.
EOF
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

echo "Rehearsal command list completed."
