#!/usr/bin/env bash
# ==============================================================================
# sync-sni-to-a.sh - Sync Server B Reality SNI to Server A's Xray client config.
#
# Usage:
#   sync-sni-to-a.sh --new-sni <hostname>
#
# Run on Server A directly, or remotely from Server B:
#   ssh root@server-a "bash /opt/bifrost/scripts/sync-sni-to-a.sh --new-sni <hostname>"
# ==============================================================================

set -euo pipefail

XRAY_CONFIG="${XRAY_CONFIG:-/etc/xray/config.json}"
NEW_SNI=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --new-sni)
            NEW_SNI="${2:-}"
            shift 2
            ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# *//'
            exit 0
            ;;
        *)
            echo "Unknown arg: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "${NEW_SNI}" ]]; then
    echo "ERROR: --new-sni is required" >&2
    exit 1
fi

if [[ ! "${NEW_SNI}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,251}[A-Za-z0-9]$ ]]; then
    echo "ERROR: --new-sni must be a hostname-like value" >&2
    exit 1
fi

if [[ ! -f "${XRAY_CONFIG}" ]]; then
    echo "ERROR: ${XRAY_CONFIG} not found" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required" >&2
    exit 1
fi

BACKUP="${XRAY_CONFIG}.bak.$(date +%s)"
TMP="${XRAY_CONFIG}.tmp.$$"
cp -a "${XRAY_CONFIG}" "${BACKUP}"

jq --arg sni "${NEW_SNI}" '
    (.outbounds[] |
        select(.streamSettings.security == "reality") |
        .streamSettings.realitySettings
    ) |= (.serverName = $sni)
' "${XRAY_CONFIG}" > "${TMP}"

if ! jq empty "${TMP}" >/dev/null 2>&1; then
    echo "ERROR: jq produced invalid JSON" >&2
    rm -f "${TMP}"
    exit 1
fi

xray_bin="$(command -v xray 2>/dev/null || echo /usr/local/bin/xray)"
if [[ -x "${xray_bin}" ]] && ! "${xray_bin}" run -test -config "${TMP}" >/dev/null 2>&1; then
    echo "ERROR: xray config validation failed" >&2
    rm -f "${TMP}"
    exit 1
fi

mv -f "${TMP}" "${XRAY_CONFIG}"
chmod 600 "${XRAY_CONFIG}"

systemctl restart xray.service

for _ in 1 2 3 4 5; do
    if systemctl is-active --quiet xray.service; then
        echo "OK: xray restarted with SNI=${NEW_SNI} (backup: ${BACKUP})"
        exit 0
    fi
    sleep 1
done

echo "WARN: xray not active after restart. Rolling back." >&2
cp -a "${BACKUP}" "${XRAY_CONFIG}"
systemctl restart xray.service
exit 1
