#!/usr/bin/env bash
# Rewrite the `modes:` block of bench/config.yml for a master-vs-release
# campaign: cluster-master-{1n,3n} at one pin, cluster-beta2-{1n,3n} at the
# release pin. Everything above `modes:` is left untouched.
#
# Pins must be full 40-char commit SHAs (checkout.sh asserts HEAD equality,
# so tags won't pass). Both commits must be reachable on the configured repo
# (git@github.com:farost/typedb-cluster.git) — push branches there first.
#
# Usage:
#   bench/set-pins.sh <cluster-master-sha> <beta2-sha>
#
# After running: review with `git diff bench/config.yml`, then
#   bench/preflight.sh && bench/campaign.sh
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: $0 <cluster-master-sha> <beta2-sha>" >&2
    exit 2
fi
MASTER_SHA="$1"
BETA2_SHA="$2"

case "$MASTER_SHA" in
    *[!0-9a-f]*|?????????????????????????????????????????*) echo "ERROR: master pin is not a 40-hex sha: $MASTER_SHA" >&2; exit 2 ;;
esac
case "$BETA2_SHA" in
    *[!0-9a-f]*|?????????????????????????????????????????*) echo "ERROR: beta2 pin is not a 40-hex sha: $BETA2_SHA" >&2; exit 2 ;;
esac
if [ ${#MASTER_SHA} -ne 40 ] || [ ${#BETA2_SHA} -ne 40 ]; then
    echo "ERROR: pins must be full 40-char SHAs" >&2
    exit 2
fi

CONFIG="$(dirname "$0")/config.yml"
MODES_LINE="$(grep -n '^modes:' "$CONFIG" | head -1 | cut -d: -f1)"
if [ -z "$MODES_LINE" ]; then
    echo "ERROR: no 'modes:' block found in $CONFIG" >&2
    exit 1
fi

TMP="$CONFIG.tmp.$$"
head -n "$MODES_LINE" "$CONFIG" > "$TMP"
cat >> "$TMP" <<EOF
  # ----- typedb-cluster master (baseline) -----
  - name: cluster-master-1n
    description: "typedb-cluster master, 1 node — single-replica overhead"
    repo_url:    "git@github.com:farost/typedb-cluster.git"
    commit:      "$MASTER_SHA"
    local_archive: ""
    local_repo:    ""
    server_type: typedb-cluster
    nodes:       1

  - name: cluster-master-3n
    description: "typedb-cluster master, 3 nodes — full cluster on master baseline"
    repo_url:    "git@github.com:farost/typedb-cluster.git"
    commit:      "$MASTER_SHA"
    local_archive: ""
    local_repo:    ""
    server_type: typedb-cluster
    nodes:       3

  # ----- 3.12.0-beta-2 (Tighten recovery: fix maybe_replay and application queue) -----
  - name: cluster-beta2-1n
    description: "typedb-cluster 3.12.0-beta-2, 1 node"
    repo_url:    "git@github.com:farost/typedb-cluster.git"
    commit:      "$BETA2_SHA"
    local_archive: ""
    local_repo:    ""
    server_type: typedb-cluster
    nodes:       1

  - name: cluster-beta2-3n
    description: "typedb-cluster 3.12.0-beta-2, 3 nodes"
    repo_url:    "git@github.com:farost/typedb-cluster.git"
    commit:      "$BETA2_SHA"
    local_archive: ""
    local_repo:    ""
    server_type: typedb-cluster
    nodes:       3
EOF

mv "$TMP" "$CONFIG"
echo "pinned: cluster-master-{1n,3n} -> $MASTER_SHA"
echo "pinned: cluster-beta2-{1n,3n}  -> $BETA2_SHA"
echo
echo "Review:    git diff $(basename "$(dirname "$CONFIG")")/config.yml"
echo "Preflight: bench/preflight.sh   # verify each pin's commit subject before any reps"
