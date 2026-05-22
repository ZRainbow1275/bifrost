#!/usr/bin/env bash
set -euo pipefail

repo_slug="${1:-}"
if [[ -z "${repo_slug}" ]]; then
    echo "Usage: git-mirror-sync.sh <repo-slug>" >&2
    exit 2
fi

case "${repo_slug}" in
    claude-for-legal-zh)
        upstream="${BIFROST_GIT_MIRROR_CLAUDE_FOR_LEGAL_ZH:-https://github.com/CSlawyer1985/claude-for-legal-ZH.git}"
        ;;
    *)
        echo "Unknown repo slug: ${repo_slug}" >&2
        exit 2
        ;;
esac

bare="/var/lib/git-mirrors/${repo_slug}.git"
tree="/var/lib/dist-tree/${repo_slug}"
releases="/var/lib/dist/${repo_slug}/releases"

install -d -m 0755 "$(dirname "${bare}")" "${tree}" "${releases}"

if [[ ! -d "${bare}/refs" ]]; then
    git clone --mirror "${upstream}" "${bare}"
fi

cd "${bare}"
default_branch="$(git symbolic-ref --short HEAD 2>/dev/null || true)"
default_branch="${default_branch:-main}"

head_before="$(git rev-parse "${default_branch}" 2>/dev/null || echo none)"
git remote update --prune
head_after="$(git rev-parse "${default_branch}" 2>/dev/null || git rev-parse HEAD)"

git --bare update-server-info

if [[ "${head_before}" == "${head_after}" && -f "${releases}/latest.tar.gz" ]]; then
    exit 0
fi

if [[ ! -d "${tree}/.git" ]]; then
    rm -rf "${tree}"
    git clone "${bare}" "${tree}"
fi

cd "${tree}"
git fetch origin
git reset --hard "origin/${default_branch}" 2>/dev/null || git reset --hard "${head_after}"
git clean -fdx

stamp="$(date +%Y%m%d)"
tarball="${releases}/${repo_slug}-${stamp}.tar.gz"
git archive --format=tar.gz --prefix="${repo_slug}/" -o "${tarball}" HEAD
cp -f "${tarball}" "${releases}/latest.tar.gz"
find "${releases}" -maxdepth 1 -name "${repo_slug}-*.tar.gz" -mtime +14 -delete
