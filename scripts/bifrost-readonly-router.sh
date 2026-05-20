#!/usr/bin/env bash
set -euo pipefail

action="${1:-}"
shift || true

case "${action}" in
    logs:verdaccio)
        exec docker logs --tail 200 verdaccio
        ;;
    logs:new-api|logs:newapi)
        exec docker logs --tail 200 new-api
        ;;
    logs:git-mirror)
        # spec.md M16: keep a single logs:git-mirror arm whose INNER allowlist
        # gains bifrost-internal-plugins. No separate arm is added for it.
        repo="${1:-claude-for-legal-zh}"
        case "${repo}" in
            claude-for-legal-zh|bifrost-internal-plugins) ;;
            *)
                echo "forbidden" >&2
                exit 2
                ;;
        esac
        exec journalctl -u "git-mirror@${repo}" --no-pager -n 200
        ;;
    # ---------------------------------------------------------------------
    # spec.md §10 PR-2: marketplace read-only diagnostic arms. The actual
    # implementations (state.json reading, marketplace.json prettyprint,
    # journalctl wrappers) live on Server B; this router simply whitelists
    # the verbs so PR-4's bifrost-api can shell out safely via SSH.
    # ---------------------------------------------------------------------
    marketplace:status)
        if [[ -f /var/lib/dist/plugins/state.json ]]; then
            exec cat /var/lib/dist/plugins/state.json
        fi
        echo '{"error":"state.json missing; marketplace-render.service has not produced output yet"}' >&2
        exit 1
        ;;
    marketplace:list-json)
        bare="/var/lib/git-mirrors/bifrost-internal-plugins.git"
        if [[ -f "${bare}/HEAD" ]]; then
            # Prefer the rendered marketplace.json inside the bare repo's HEAD tree.
            exec git --git-dir="${bare}" show HEAD:.claude-plugin/marketplace.json
        fi
        echo '{"error":"bifrost-internal-plugins bare repo not yet initialised"}' >&2
        exit 1
        ;;
    marketplace:disk-report)
        exec du -sh /var/lib/git-mirrors/bifrost-internal-plugins.git \
            /var/lib/dist/plugins \
            /var/log/marketplace 2>/dev/null
        ;;
    logs:marketplace-render)
        exec journalctl -u marketplace-render.service --no-pager -n 200
        ;;
    logs:upstream-schema-check)
        exec journalctl -u upstream-schema-check.service --no-pager -n 200
        ;;
    logs:admin-audit)
        exec tail -n 200 /var/log/marketplace/admin-audit.log
        ;;
    disk:report)
        exec du -sh /var/lib/verdaccio /var/lib/new-api-pg /var/lib/new-api-redis /var/lib/git-mirrors /var/lib/dist 2>/dev/null
        ;;
    wg:age)
        exec wg show wg0 latest-handshakes
        ;;
    *)
        echo "forbidden" >&2
        exit 2
        ;;
esac
