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
    # Surface remote-url-set failures (mismatched remote, perms drift, etc.)
    # rather than silently leaving origin pointing at a stale URL.
    if ! err="$(git -C "$dest" remote set-url origin "$repo_url" 2>&1)"; then
        error "could not set origin URL on $dest: $err"
        exit 1
    fi
    # Try the cheap single-commit fetch first. If it fails (e.g. remote
    # doesn't support commit-fetch, or commit not yet on remote), fall back
    # to a full fetch. EITHER failure exits with a clear error — no silent
    # fallback, no swallowed stderr (this is the bug that hid GITHUB_TOKEN
    # loss between sessions).
    if ! commit_fetch_err="$(git -C "$dest" fetch origin "$commit" 2>&1)"; then
        log "  single-commit fetch failed: $commit_fetch_err"
        log "  retrying with default fetch"
        if ! full_fetch_err="$(git -C "$dest" fetch origin 2>&1)"; then
            error "fetch from origin failed for $dest"
            error "  single-commit error: $commit_fetch_err"
            error "  full-fetch error:    $full_fetch_err"
            error "  likely missing GITHUB_TOKEN (env) or auth/network problem"
            exit 1
        fi
    fi
    # --force: the bzlmod pinning step below edits MODULE.bazel in the working
    # tree on every checkout, so a reused checkout is always dirty. Discard
    # that edit (it is re-applied for the new commit right after).
    if ! co_err="$(git -C "$dest" checkout --quiet --force "$commit" 2>&1)"; then
        error "could not checkout $commit in $dest: $co_err"
        error "  commit may not exist on the remote, or fetch was incomplete"
        exit 1
    fi
else
    log "Cloning $repo_url -> $dest"
    if ! clone_err="$(git clone --quiet "$repo_url" "$dest" 2>&1)"; then
        error "clone of $repo_url to $dest failed: $clone_err"
        error "  likely missing GITHUB_TOKEN (env) or auth/network problem"
        exit 1
    fi
    if ! co_err="$(git -C "$dest" checkout --quiet "$commit" 2>&1)"; then
        error "could not checkout $commit after clone: $co_err"
        exit 1
    fi
fi

# Assert HEAD actually moved to the requested commit. Catches any silent
# failure that slipped past the per-step error checks above (the trap that
# silently kept the harness on 99268086 for hours).
actual="$(git -C "$dest" rev-parse HEAD)"
if [ "$actual" != "$commit" ]; then
    error "HEAD=$actual after checkout, expected=$commit"
    error "  $dest is NOT at the configured commit — refusing to proceed"
    exit 1
fi

log "  at $(git -C "$dest" log -1 --format='%h %s')"

# ---------------------------------------------------------------------------
# Pin transitive bzlmod deps to the versions MODULE.bazel declares. Without
# these, bzlmod resolves protobuf/rules_java/etc. UPWARD to newer versions
# whose bzl surfaces don't line up (typical symptom on the newer feature-
# branch commits: `no such package '@@abseil-cpp+//absl/log'` because
# protobuf@35 references absl/log that the transitively-resolved older
# abseil doesn't have).
#
# Idempotent — checks for our marker before appending.
# ---------------------------------------------------------------------------
MODULE_FILE="$dest/MODULE.bazel"
BENCH_PIN_MARKER="# ---- bench harness: single_version_override pins ----"
if [ -f "$MODULE_FILE" ] && ! grep -qF "$BENCH_PIN_MARKER" "$MODULE_FILE"; then
    log "  appending single_version_override pins to $MODULE_FILE"
    cat >> "$MODULE_FILE" <<PINS

$BENCH_PIN_MARKER
single_version_override(module_name = "protobuf", version = "29.3")
single_version_override(module_name = "rules_java", version = "8.6.2")
single_version_override(module_name = "platforms", version = "0.0.10")
single_version_override(module_name = "bazel_skylib", version = "1.7.1")
single_version_override(module_name = "rules_jvm_external", version = "6.6")
single_version_override(module_name = "rules_python", version = "1.0.0")
single_version_override(module_name = "rules_kotlin", version = "2.0.0")
PINS
fi
