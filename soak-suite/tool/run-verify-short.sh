#!/usr/bin/env bash
# Short verification (default 30 min) — proves the fleet is wired up correctly
# and produces a pass/fail report. Run BEFORE the long soak on a fresh deploy.
#
# Prereqs (must already be set up):
#   - All 4 machines (M1/M2/M3 + client) reachable + configured (see README §GCP).
#   - Runners already brought up via tool/bootstrap.sh on M1/M2/M3.
#
# What it does:
#   1. Starts the 3 client processes with --duration-secs $DURATION (default 1800).
#   2. Runs tool/periodic-report.sh in the background (every 60s during the short run).
#   3. Waits for all 3 clients to exit, then runs tool/verify-report.sh.
#   4. Exits 0 (PASS) / 2 (FAIL / count_mismatch present) / other (error).
#
# Usage:
#   tool/run-verify-short.sh                   # 30 min
#   DURATION=900 tool/run-verify-short.sh      # 15 min quick smoke
#   DURATION=7200 tool/run-verify-short.sh     # 2 hr extended
set -euo pipefail

DURATION="${DURATION:-1800}"
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT_WORKDIR="${CLIENT_WORKDIR:-/var/lib/typedb-soak/client}"
TOPOLOGY="${TOPOLOGY:-$SUITE_DIR/config/topology.toml}"

command -v tmux >/dev/null || { echo "tmux required"; exit 1; }

echo "[verify-short] duration=${DURATION}s client_workdir=$CLIENT_WORKDIR"
echo "[verify-short] topology=$TOPOLOGY"

mkdir -p "$CLIENT_WORKDIR" "$CLIENT_WORKDIR/../reports"

# 1. Launch the 3 clients with the duration cap.
DURATION="$DURATION" TOPOLOGY="$TOPOLOGY" WORKDIR_ROOT="$CLIENT_WORKDIR" \
    "$SUITE_DIR/tool/start-clients.sh" --duration "$DURATION"

# 2. Fire the periodic reporter (60s cadence for a short run).
REPORT_LOG="/var/lib/typedb-soak/reports/health-verify-short.log"
INTERVAL=60 LOG="$REPORT_LOG" CLIENT_WORKDIR="$CLIENT_WORKDIR" \
    "$SUITE_DIR/tool/periodic-report.sh" &
REPORTER_PID=$!
trap 'kill "$REPORTER_PID" 2>/dev/null || true' EXIT

echo "[verify-short] reporter PID=$REPORTER_PID → $REPORT_LOG"
echo "[verify-short] tmux sessions: soak-1n / soak-3n / soak-3n-chaos"
echo "[verify-short] tail health with: tail -F $REPORT_LOG"

# 3. Wait for clients (poll tmux sessions).
deadline=$(( $(date +%s) + DURATION + 300 ))   # +5 min slack for shutdown
while [ "$(date +%s)" -lt "$deadline" ]; do
    if ! tmux ls 2>/dev/null | grep -qE '^soak-(1n|3n|3n-chaos):'; then
        break
    fi
    sleep 10
done

if tmux ls 2>/dev/null | grep -qE '^soak-(1n|3n|3n-chaos):'; then
    echo "[verify-short] WARNING: some sessions still alive past deadline. Killing."
    "$SUITE_DIR/tool/stop-clients.sh" || true
fi

# 4. Final report + pass/fail exit.
echo
echo "[verify-short] === verification report ==="
"$SUITE_DIR/tool/verify-report.sh" "$TOPOLOGY" "$CLIENT_WORKDIR" "$DURATION" 30
rc=$?

# 5. Bundle artifacts on the client machine (post-mortem hedge).
"$SUITE_DIR/tool/collect-artifacts.sh" "$(dirname "$CLIENT_WORKDIR")" \
    "/var/lib/typedb-soak/reports/verify-short-$(date -u +%Y%m%dT%H%M%SZ).tar.gz" || true

exit "$rc"
