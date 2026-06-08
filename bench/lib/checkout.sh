#!/usr/bin/env bash
# Clone a repo at a specific commit into the workspace, idempotently.
#
# Usage: checkout.sh <repo_url> <commit> <dest_dir>
#
# - If dest_dir doesn't exist: clone fresh.
# - If dest_dir exists and HEAD already at commit: no-op.
# - If dest_dir exists at a different commit: fetch + checkout.
#
# GITHUB_TOKEN env var is used to rewrite SSH urls if SSH key auth isn't
# available — useful on a fresh GCP VM where you only have a PAT.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

repo_url="$1"
commit="$2"
dest="$3"

# Rewrite SSH urls to HTTPS+token when the operator only has a PAT.
# Avoids dealing with ssh-agent on ephemeral cloud VMs.
if [ -n "${GITHUB_TOKEN:-}" ]; then
    case "$repo_url" in
        git@github.com:*)
            repo_url="https://x-access-token:${GITHUB_TOKEN}@github.com/${repo_url#git@github.com:}"
            ;;
        https://github.com/*)
            repo_url="${repo_url/https:\/\//https://x-access-token:${GITHUB_TOKEN}@}"
            ;;
    esac
fi

mkdir -p "$(dirname "$dest")"

if [ -d "$dest/.git" ]; then
    log "Reusing existing checkout: $dest"
    current="$(git -C "$dest" rev-parse HEAD 2>/dev/null || echo none)"
    if [ "$current" = "$commit" ]; then
        log "  already at $commit"
        exit 0
    fi
    log "  HEAD=$current, fetching to reach $commit"
    git -C "$dest" remote set-url origin "$repo_url" 2>/dev/null || true
    git -C "$dest" fetch --quiet origin "$commit" 2>/dev/null \
        || git -C "$dest" fetch --quiet origin
    git -C "$dest" checkout --quiet "$commit"
else
    log "Cloning $repo_url -> $dest"
    git clone --quiet "$repo_url" "$dest"
    git -C "$dest" checkout --quiet "$commit"
fi

log "  at $(git -C "$dest" log -1 --format='%h %s')"
