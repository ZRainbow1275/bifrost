#!/usr/bin/env bash
set -euo pipefail

env_file="${BIFROST_RESTIC_ENV_FILE:-/etc/bifrost/restic-to-a.env}"
if [[ -f "${env_file}" ]]; then
    # shellcheck disable=SC1090
    source "${env_file}"
fi

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is required}"
: "${RESTIC_PASSWORD_FILE:?RESTIC_PASSWORD_FILE is required}"

if [[ ! -f "${RESTIC_PASSWORD_FILE}" ]]; then
    echo "RESTIC_PASSWORD_FILE does not exist: ${RESTIC_PASSWORD_FILE}" >&2
    exit 2
fi

restic backup \
    /var/lib/verdaccio \
    /var/lib/new-api-pg \
    /var/lib/new-api-redis \
    /var/lib/git-mirrors \
    /var/lib/dist
