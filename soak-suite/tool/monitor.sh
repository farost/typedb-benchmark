#!/usr/bin/env bash
# Cheap operator dashboard. Refreshes every 5s. Reads each mode's STATE +
# tail of FAILURES.log and prints a single-pane summary.
set -euo pipefail

WORKDIR_ROOT="${1:-/var/lib/typedb-soak/client}"

while true; do
  clear
  echo "soak monitor — $(date -u +%FT%TZ) — workdir=$WORKDIR_ROOT"
  echo "================================================================"
  shopt -s nullglob
  for state in "$WORKDIR_ROOT"/mode_*/STATE; do
    mode="$(basename "$(dirname "$state")")"
    echo
    echo "[$mode]"
    if command -v jq >/dev/null 2>&1; then
      jq -r '
        "  expected      = \(.expected)
  commits_ok    = \(.total_commits_ok)
  commits_err   = \(.total_commits_err)
  verifies_err  = \(.total_verifies_err)
  reconciles    = \(.total_reconciliations)
  last_ok_at    = \(.last_ok_at // "n/a")"' "$state"
    else
      cat "$state"
    fi
    failures="$(dirname "$state")/FAILURES.log"
    if [[ -s "$failures" ]]; then
      n="$(wc -l < "$failures")"
      echo "  failures      = $n (last 3:)"
      tail -n 3 "$failures" | sed 's/^/    /'
    else
      echo "  failures      = 0"
    fi
  done
  sleep 5
done
