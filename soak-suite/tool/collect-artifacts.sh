#!/usr/bin/env bash
# Bundle everything a post-mortem needs into one tar.gz.
#
# Includes:
#   - Per-machine runner.log, server.log for each node, chaos events
#   - Per-mode STATE, FAILURES.log, client.log, diagnostics.log
#   - config/topology.toml + config/topology.localhost.toml
#   - Any health-snapshot logs
#
# Usage:
#   tool/collect-artifacts.sh                                   # default paths + timestamp filename
#   tool/collect-artifacts.sh /var/lib/typedb-soak /tmp/out.tgz
#
# Run once per machine (each machine only has its own runner state); combine
# on the client machine after scp.
set -euo pipefail

WORKDIR_ROOT="${1:-/var/lib/typedb-soak}"
OUT="${2:-/tmp/soak-artifacts-$(hostname)-$(date -u +%Y%m%dT%H%M%SZ).tar.gz}"

if [ ! -d "$WORKDIR_ROOT" ]; then
    echo "ERROR: workdir root not found: $WORKDIR_ROOT" >&2
    exit 1
fi

echo "[collect] scanning $WORKDIR_ROOT"

# Gather relative paths to include. Cap large log tails to keep bundle small.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

MANIFEST="$STAGE/MANIFEST.txt"
echo "collected at $(date -u +%FT%TZ) from $(hostname)" > "$MANIFEST"
echo "workdir_root: $WORKDIR_ROOT" >> "$MANIFEST"

# STATE + FAILURES + short logs — copy in full.
find "$WORKDIR_ROOT" \( -name STATE -o -name FAILURES.log -o -name 'client.log' -o -name 'diagnostics.log' -o -name 'runner.log' \) 2>/dev/null | while read -r f; do
    rel="${f#$WORKDIR_ROOT/}"
    mkdir -p "$STAGE/$(dirname "$rel")"
    cp "$f" "$STAGE/$rel"
    echo "  full: $rel" >> "$MANIFEST"
done

# server.log per node — tail the last 5000 lines so the bundle stays small
# even after weeks of chaos.
find "$WORKDIR_ROOT" -name 'server.log' -not -path '*_state*' 2>/dev/null | while read -r f; do
    rel="${f#$WORKDIR_ROOT/}"
    mkdir -p "$STAGE/$(dirname "$rel")"
    tail -5000 "$f" > "$STAGE/$rel"
    echo "  tail-5000: $rel" >> "$MANIFEST"
done

# Any health/report logs.
find "$WORKDIR_ROOT/reports" -type f 2>/dev/null | while read -r f; do
    rel="${f#$WORKDIR_ROOT/}"
    mkdir -p "$STAGE/$(dirname "$rel")"
    cp "$f" "$STAGE/$rel"
    echo "  report: $rel" >> "$MANIFEST"
done

# Topology config (informational)
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ -d "$SUITE_DIR/config" ]; then
    mkdir -p "$STAGE/config"
    cp "$SUITE_DIR/config/"*.toml "$STAGE/config/" 2>/dev/null || true
    echo "  config: soak-suite/config/*.toml" >> "$MANIFEST"
fi

tar czf "$OUT" -C "$STAGE" .
size=$(du -h "$OUT" | awk '{print $1}')
echo "[collect] wrote $OUT ($size)"
echo "[collect] manifest:"
sed 's/^/  /' "$MANIFEST"
