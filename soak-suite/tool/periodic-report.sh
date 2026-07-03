#!/usr/bin/env bash
# Long-running observer: every $INTERVAL seconds, appends a health-snapshot
# to $LOG. Intended to run alongside a week+ soak so you can `tail -F` from
# home and know the run is healthy without attaching tmux.
#
# Usage:
#   tool/periodic-report.sh                              # defaults: 300s, /var/lib/typedb-soak/reports/health.log
#   INTERVAL=60 tool/periodic-report.sh                  # every minute
#   LOG=/tmp/health.log tool/periodic-report.sh          # custom log
#   CLIENT_WORKDIR=/other/path tool/periodic-report.sh   # non-default workdir
set -euo pipefail

INTERVAL="${INTERVAL:-300}"
LOG="${LOG:-/var/lib/typedb-soak/reports/health.log}"
CLIENT_WORKDIR="${CLIENT_WORKDIR:-/var/lib/typedb-soak/client}"
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$(dirname "$LOG")"

echo "[periodic-report] starting: interval=${INTERVAL}s log=$LOG workdir=$CLIENT_WORKDIR"

while true; do
    {
        "$SUITE_DIR/tool/health-snapshot.sh" "$CLIENT_WORKDIR" 2>&1
        echo
    } >> "$LOG"
    sleep "$INTERVAL"
done
