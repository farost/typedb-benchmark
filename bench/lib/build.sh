#!/usr/bin/env bash
# Produce an extracted server tree at $extract_dir. Three input shapes,
# tried in order:
#
#   build.sh --archive <archive_path>           <extract_dir>
#       Just extract a pre-built .tar.gz/.zip; no bazel involvement.
#       Use this for `local_archive` modes.
#
#   build.sh --repo <server_type> <repo_dir>    <extract_dir>
#       Build in-place with `bazel build //:assemble-all-<arch>-targz` and
#       extract the resulting archive. Use this for both `local_repo` modes
#       (working tree may have uncommitted edits) and remote modes (the
#       caller has already cloned + checked out into <repo_dir>).
#
# Idempotent: skips extraction if $extract_dir/typedb is already executable.
# Pass --force to invalidate the cache.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

force=0
if [ "${1:-}" = "--force" ]; then
    force=1; shift
fi

mode="$1"; shift
case "$mode" in
    --archive)
        archive="$1"; extract_dir="$2"
        server_type=""  # not needed; archive contents are self-describing
        ;;
    --repo)
        server_type="$1"; repo_dir="$2"; extract_dir="$3"
        ;;
    *)
        error "build.sh: usage:"
        error "  build.sh [--force] --archive <archive_path> <extract_dir>"
        error "  build.sh [--force] --repo <server_type> <repo_dir> <extract_dir>"
        exit 2
        ;;
esac

# If the cache is already good, bail early.
if [ "$force" -eq 0 ] && [ -x "$extract_dir/typedb" ]; then
    log "Using cached extract: $extract_dir"
    exit 0
fi

# When building from a repo, run bazel and locate the resulting archive.
if [ "$mode" = "--repo" ]; then
    arch="$(host_arch)"
    target="//:assemble-all-${arch}-targz"

    rev="(uncommitted)"
    if git -C "$repo_dir" rev-parse HEAD >/dev/null 2>&1; then
        rev="$(git -C "$repo_dir" rev-parse --short HEAD)"
    fi
    step "Building $server_type from $repo_dir@$rev ($target)"
    ( cd "$repo_dir" && bazel build "$target" )

    case "$server_type" in
        typedb)         archive="$repo_dir/bazel-bin/typedb-all-${arch}.tar.gz" ;;
        typedb-cluster) archive="$repo_dir/bazel-bin/typedb-cluster-all-${arch}.tar.gz" ;;
        *) error "unknown server_type: $server_type"; exit 1 ;;
    esac
fi

if [ ! -s "$archive" ]; then
    error "no archive at $archive"
    exit 1
fi

log "Extracting $archive -> $extract_dir"
rm -rf "$extract_dir"
mkdir -p "$extract_dir"
case "$archive" in
    *.tar.gz|*.tgz) tar --strip-components=1 -xf "$archive" -C "$extract_dir" ;;
    *.zip)
        local_stash="${extract_dir}.stash"
        rm -rf "$local_stash"; mkdir -p "$local_stash"
        unzip -q "$archive" -d "$local_stash"
        # zip archives have a single top-level dir we need to flatten
        shopt -s dotglob
        mv "$local_stash"/*/* "$extract_dir/"
        shopt -u dotglob
        rm -rf "$local_stash"
        ;;
    *) error "don't know how to extract $archive"; exit 1 ;;
esac

if [ ! -x "$extract_dir/typedb" ]; then
    error "Extract did not produce a typedb launcher at $extract_dir/typedb"
    exit 1
fi
log "  launcher: $extract_dir/typedb"
