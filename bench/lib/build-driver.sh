#!/usr/bin/env bash
# Build a typedb-driver wheel from a local checkout and echo its path.
#
# Usage: build-driver.sh <typedb-driver checkout> <python-major.minor>
#
#   typedb-driver checkout: absolute path to a clone of typedb/typedb-driver
#   python-major.minor:     e.g. "3.12" — used to pick `assemble-pip3X`
#
# Output (stdout): absolute path to the built .whl
# Output (stderr): build progress
#
# Idempotent on the bazel side (the assemble-pip rule caches itself), so
# re-runs against an unchanged tree are seconds. To force a rebuild,
# `bazel clean` in the driver repo or change source files.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

repo="$1"
py_ver="$2"

if [ ! -d "$repo/python" ]; then
    error "expected $repo/python/ — is this a typedb-driver checkout?"
    exit 1
fi

# Strip the dot from `3.12` -> `312`. The bazel target uses two digits today
# (`assemble-pip39`, etc.); we fall back to the active python's major.minor.
suffix="$(echo "$py_ver" | tr -d '.')"
target="//python:assemble-pip${suffix}"

step "Building typedb-driver wheel from $repo ($target)"
( cd "$repo" && bazel build "$target" >&2 )

# assemble_pip drops the wheel under bazel-bin/python/assemble-pip<suffix>.dist/.
# The filename includes the version + platform tag — glob for it.
dist_dir="$repo/bazel-bin/python/assemble-pip${suffix}.dist"
wheel="$(ls "$dist_dir"/typedb_driver-*.whl 2>/dev/null | head -n1)"
if [ -z "$wheel" ]; then
    error "no wheel found under $dist_dir (expected typedb_driver-*.whl)"
    error "bazel-bin contents:"
    ls "$repo/bazel-bin/python/" >&2 || true
    exit 1
fi
log "Built: $wheel" >&2
echo "$wheel"
